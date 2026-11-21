#!/usr/bin/env bash
# Метрики сервера контура (16 §8.4, §9 «Метрики минимум» и «Outbox в 1С»; 16 OPS-014; 12 T-OPS-008; RUNBOOK §6.4).
# Запуск — таймер systemd optomstroy-metrics.timer каждые 10 минут (ставят install.sh и update.sh рабочего контура)
# или вручную:
#   sudo /opt/optomstroy/prod/bin/metrics_check.sh [--ping-url-file <файл>]
# Пороги (16 §9; срабатывание — код метрики со значением):
#   DISK_USAGE      заполнение файловой системы каталога базы, копий или Docker > 80 %;
#   MEM_AVAILABLE   доступная память (MemAvailable) < 10 %;
#   LOAD15          load average за 15 минут > числа CPU;
#   READY_SLOW      ответ GET /health/ready через общий caddy дольше 2 с; READY_FAILED — 503 или нет ответа;
#   CERT_DAYS       до конца сертификата сайта контура меньше 20 дней;
#   при подключённой 1С (ONEC_BASE_URL задан; без 1С эти счётчики растут ожидаемо, RUNBOOK §8.1):
#   SYNC_FAILED_24H неудачных прогонов синхронизации за сутки ≥ 3;
#   OUTBOX_FAILED   записей onec_outbox в failed/dead дольше 15 минут > 0; OUTBOX_PENDING — pending старше 30 минут > 0;
#   при туннеле WireGuard к 1С (сервер вне магазина, сценарий C-1; есть интерфейс wg0; RUNBOOK §11):
#   WG_HANDSHAKE_STALE последнее рукопожатие пира 1С старше 3 минут — сигнал в любое время: 1С нужна весь день
#                   (заказы, оплаты, возвраты — сразу, остатки и цены — каждые 5–30 минут; 15 ADR-120).
# Размер базы и прочие значения — только в вывод (журнал: journalctl -u optomstroy-metrics).
# Сигнал — Healthchecks self-hosted (16 §9): файл secrets/healthchecks_metrics_url (своя проверка «metrics», период
# 10 минут; не тот uuid, что у worker и backup). Есть нарушения — POST <url>/fail с кодами и значениями (без ПДн:
# 16 §9 «Содержимое алертов»), нет — ping <url>. Файла нет — только вывод и код выхода.
# Коды выхода: 0 — всё в норме; 1 — есть нарушения или проверка не выполнена; 2 — неверные параметры.
set -euo pipefail
set +x
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

DISK_MAX_PCT=80
MEM_MIN_PCT=10
READY_MAX_MS=2000
CERT_MIN_DAYS=20
SYNC_FAILED_MAX=3

PING_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ping-url-file) [ $# -ge 2 ] || { printf 'нет значения для --ping-url-file\n' >&2; exit 2; }; PING_FILE="$2"; shift 2 ;;
    --prod-dir) [ $# -ge 2 ] || { printf 'нет значения для --prod-dir\n' >&2; exit 2; }; PROD_DIR="$2"; shift 2 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'неизвестный параметр: %s\n' "$1" >&2; exit 2 ;;
  esac
done

need_root
need_cmd awk df date nproc
check_docker
resolve_dirs "$HERE"
[ -f "$ENV_FILE" ] || die "в $PROD_DIR нет установленного контура"
PING_FILE="${PING_FILE:-$SECRETS_DIR/healthchecks_metrics_url}"
check_secrets
compose_init

alerts=""
notes=""
alert() { alerts="$alerts $1"; }
note() { notes="$notes $1"; }

# --- Диски: файловые системы базы, копий и Docker (каждая один раз) ---
seen=" "
for d in "$DATA_DIR/pgdata" "$DATA_DIR/backups" "$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"; do
  [ -e "$d" ] || continue
  line="$(df -P "$d" | awk 'NR == 2 { sub(/%$/, "", $5); print $6, $5 }')"
  mp="${line% *}"
  pct="${line##* }"
  case "$seen" in *" $mp "*) continue ;; esac
  seen="$seen$mp "
  note "disk:$mp=${pct}%"
  case "$pct" in ''|*[!0-9]*) alert "DISK_USAGE:$mp=unknown" ;; *) [ "$pct" -le "$DISK_MAX_PCT" ] || alert "DISK_USAGE:$mp=${pct}%" ;; esac
done

# --- Память и нагрузка ---
mem="$(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { if (t > 0) printf "%d", a * 100 / t }' /proc/meminfo)"
note "mem_available=${mem:-?}%"
[ -z "$mem" ] || [ "$mem" -ge "$MEM_MIN_PCT" ] || alert "MEM_AVAILABLE=${mem}%"
load15="$(awk '{ print $3 }' /proc/loadavg)"
cpus="$(nproc)"
note "load15=$load15/cpu=$cpus"
if awk -v l="$load15" -v c="$cpus" 'BEGIN { exit !(l + 0 > c + 0) }'; then alert "LOAD15=$load15>$cpus"; fi

# --- База: размер (в журнал); при подключённой 1С — синхронизация и outbox ---
if [ "$(container_state postgres)" = healthy ]; then
  size="$(printf 'SELECT pg_database_size(current_database());\n' | psql_super_at 2>/dev/null || true)"
  case "$size" in ''|*[!0-9]*) note "db_size=?" ;; *) note "db_size=$((size / 1048576))MiB" ;; esac
  row="$(printf "SELECT (SELECT count(*) FROM sync_runs WHERE status = 'failed' AND created_at > now() - interval '24 hours') || ' ' ||
    (SELECT count(*) FROM onec_outbox WHERE status IN ('failed', 'dead') AND updated_at < now() - interval '15 minutes') || ' ' ||
    (SELECT count(*) FROM onec_outbox WHERE status = 'pending' AND created_at < now() - interval '30 minutes');\n" \
    | psql_super_at 2>/dev/null || true)"
  # shellcheck disable=SC2086
  set -- $row
  if [ $# -eq 3 ]; then
    note "sync_failed_24h=$1 outbox_failed_15m=$2 outbox_pending_30m=$3"
    if [ -n "$(env_get "$ENV_FILE" ONEC_BASE_URL)" ]; then
      [ "$1" -lt "$SYNC_FAILED_MAX" ] || alert "SYNC_FAILED_24H=$1"
      [ "$2" -eq 0 ] || alert "OUTBOX_FAILED=$2"
      [ "$3" -eq 0 ] || alert "OUTBOX_PENDING=$3"
    fi
  else
    alert "DB_QUERY_FAILED"
  fi
else
  alert "POSTGRES_NOT_HEALTHY"
fi

# --- Туннель WireGuard к 1С (сервер вне магазина, сценарий C-1; 16 §12.2, §15.1; RUNBOOK §11.6) ---
# Нет интерфейса туннеля или 1С ещё не подключена — проверка пропускается (1С в одной сети с сервером).
# Рукопожатие пира 1С старше WG_MAX_HANDSHAKE_SEC — сигнал в любое время: 1С — главная система, сервер работает с ней
# весь день (заказы, оплаты, возвраты — сразу через очередь; остатки и цены — каждые 5–30 минут; ночью — задания
# SYNC_NIGHT_WINDOW; 15 ADR-120). Новых имён .env нет (16 §4.3).
onec_url="$(env_get "$ENV_FILE" ONEC_BASE_URL)"
if [ -n "$onec_url" ] && command -v wg >/dev/null 2>&1 && ip link show "$WG_IF_DEFAULT" >/dev/null 2>&1; then
  onec_ip="$(host_ipv4 "$(url_hostname "$onec_url")")"
  wg_age=""
  [ -z "$onec_ip" ] || wg_age="$(wg_peer_handshake_age "$WG_IF_DEFAULT" "$onec_ip")"
  note "wg_onec_handshake=${wg_age:-no-peer}"
  if [ -z "$wg_age" ] || [ "$wg_age" = never ] || [ "$wg_age" -gt "$WG_MAX_HANDSHAKE_SEC" ]; then
    alert "WG_HANDSHAKE_STALE=${wg_age:-no-peer}"
  fi
fi

# --- /health/ready и сертификат через общий caddy (как его видят клиенты; адрес — 127.0.0.1, имя сайта — SNI) ---
site="$(env_get "$ENV_FILE" CADDY_SITE_ADDRESS)"
if [ -n "$site" ] && command -v curl >/dev/null 2>&1; then
  res="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 10 --resolve "$site:443:127.0.0.1" \
    "https://$site/health/ready" 2>/dev/null || true)"
  code="${res%% *}"
  ms="$(printf '%s' "${res#* }" | awk '{ printf "%d", $1 * 1000 }')"
  note "ready=${code:-000}/${ms:-?}ms"
  case "$code" in
    200) [ "${ms:-0}" -le "$READY_MAX_MS" ] || alert "READY_SLOW=${ms}ms" ;;
    *) alert "READY_FAILED=${code:-000}" ;;
  esac
fi
if [ -n "$site" ] && command -v openssl >/dev/null 2>&1; then
  end="$(openssl s_client -connect 127.0.0.1:443 -servername "$site" </dev/null 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
  if [ -n "$end" ] && end_s="$(date -d "$end" +%s 2>/dev/null)"; then
    days=$(( (end_s - $(date +%s)) / 86400 ))
    note "cert_days=$days"
    [ "$days" -ge "$CERT_MIN_DAYS" ] || alert "CERT_DAYS=$days"
  else
    alert "CERT_UNREADABLE"
  fi
fi

if [ -n "$alerts" ]; then
  log "метрики: НАРУШЕНИЯ:$alerts |$notes"
else
  log "метрики: в норме |$notes"
fi
if [ -s "$PING_FILE" ]; then
  url="$(tr -d '\r\n' < "$PING_FILE")"
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$alerts" ]; then
      curl -fsS -m 10 -o /dev/null --data-raw "metrics:$alerts" "$url/fail" || warn "Healthchecks: сигнал не доставлен"
    else
      curl -fsS -m 10 -o /dev/null "$url" || warn "Healthchecks: сигнал не доставлен"
    fi
  else
    warn "curl не найден — сигнал Healthchecks не отправлен"
  fi
fi
[ -z "$alerts" ]
