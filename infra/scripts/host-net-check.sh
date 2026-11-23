#!/usr/bin/env bash
# Проверка сети и времени хоста — прежде всего для сервера вне магазина (дата-центр, сценарий C-1: туннель WireGuard к
# 1С; 16 §3.3, §7 H-5, H-11, §12.2, §15.1; DEPLOY-008, DEPLOY-020, DEPLOY-021, DEPLOY-035; RUNBOOK §2.6, §11). Только
# читает: ничего не меняет (firewall, туннель и пояс настраивает DevOps вручную по RUNBOOK §11 с согласия заказчика,
# 16 §6.3); подсказки команд в замечаниях — текст, скрипт их не выполняет.
# Запуск — после установки и после изменений сети:
#   sudo /opt/optomstroy/prod/bin/host-net-check.sh [--wg-if wg0] [--ssh-port 22] [--prod-dir <каталог>]
# Проверки (замечание — код со значением, без ключей и паролей):
#   TZ_HOST            часовой пояс сервера не равен TZ из .env (Asia/Bishkek): журналы хоста — по поясу сервера;
#   NTP                время не синхронизировано;
#   LISTEN_UNEXPECTED  наружу (не loopback) слушает что-то кроме TCP 80/443, SSH и UDP-порта WireGuard
#                      (клиенты DHCP 68 и DHCPv6 546 допустимы);
#   FIREWALL           ufw не активен — проверить правила хоста вручную (H-5: Docker обходит ufw для своих портов);
#   AAAA               у имени сайта есть IPv6-запись: без настройки IPv6 в Docker api видит адрес моста, а не клиента
#                      (лимиты по IP и правило /health/ready ломаются) — запись не публиковать или настроить IPv6;
#   при туннеле (есть интерфейс --wg-if):
#   WG_SERVICE         служба wg-quick@<интерфейс> не включена (туннель не поднимется после перезагрузки);
#   WG_CONF_PERMS      /etc/wireguard/<интерфейс>.conf не 600 root;
#   WG_PORT_CLOSED     UDP-порт туннеля не разрешён в ufw;
#   WG_ALLOWEDIPS_WIDE у пира в AllowedIPs 0.0.0.0/0;
#   WG_ROUTE           адрес из ONEC_BASE_URL идёт не через туннель;
#   WG_HANDSHAKE_STALE рукопожатия пира 1С не было или оно старше 3 минут (сигнал метрик metrics_check.sh — тоже
#                      в любое время: 1С нужна весь день);
#   ONEC_HTTPS         публикация 1С по HTTPS с хоста не отвечает (ожидается 401 без ключа клиента: сервис опубликован).
# Коды выхода: 0 — замечаний нет; 1 — есть замечания или проверка не выполнена; 2 — неверные параметры.
set -euo pipefail
set +x
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

WG_IF="$WG_IF_DEFAULT"
SSH_PORT=22
while [ $# -gt 0 ]; do
  case "$1" in
    --wg-if) [ $# -ge 2 ] || { printf 'нет значения для --wg-if\n' >&2; exit 2; }; WG_IF="$2"; shift 2 ;;
    --ssh-port) [ $# -ge 2 ] || { printf 'нет значения для --ssh-port\n' >&2; exit 2; }; SSH_PORT="$2"; shift 2 ;;
    --prod-dir) [ $# -ge 2 ] || { printf 'нет значения для --prod-dir\n' >&2; exit 2; }; PROD_DIR="$2"; shift 2 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'неизвестный параметр: %s\n' "$1" >&2; exit 2 ;;
  esac
done
case "$SSH_PORT" in ''|*[!0-9]*) printf -- '--ssh-port: число\n' >&2; exit 2 ;; esac
case "$WG_IF" in ''|*[!A-Za-z0-9_.-]*) printf -- '--wg-if: имя интерфейса\n' >&2; exit 2 ;; esac

need_root
need_cmd awk ss ip date sort
resolve_dirs "$HERE"
[ -f "$ENV_FILE" ] || die "в $PROD_DIR нет установленного контура"

problems=""
problem() { problems="$problems $1"; warn "$1 — $2"; }
fine() { log "в норме: $*"; }

# --- Время: пояс сервера и NTP (16 H-11, DEPLOY-021) ---
want_tz="$(env_get "$ENV_FILE" TZ)"
want_tz="${want_tz:-Asia/Bishkek}"
if command -v timedatectl >/dev/null 2>&1; then
  host_tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  if [ "$host_tz" = "$want_tz" ]; then
    fine "часовой пояс сервера $host_tz"
  else
    problem "TZ_HOST=${host_tz:-?}" "ожидается $want_tz: sudo timedatectl set-timezone $want_tz (по согласованию, RUNBOOK §11.2)"
  fi
  if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo no)" = yes ]; then
    fine "время синхронизировано (NTP)"
  else
    problem "NTP=no" "время не синхронизировано: TLS, OTP и журналы зависят от времени"
  fi
else
  problem "TZ_HOST=unknown" "нет timedatectl — проверьте пояс и NTP вручную"
fi

# --- Туннель: есть ли интерфейс и его порт (нужен для списка допустимых портов) ---
wg_up=""
wg_port=""
if ip link show "$WG_IF" >/dev/null 2>&1; then
  need_cmd wg
  wg_up=1
  wg_port="$(wg show "$WG_IF" listen-port 2>/dev/null || true)"
fi

# --- Порты: наружу только 80/443 (caddy), SSH и UDP туннеля (DEPLOY-008, DEPLOY-020) ---
listen="$(ss -Htuln 2>/dev/null || true)"
extra="$(awk -v at=" 80 443 $SSH_PORT " -v au=" 68 546 ${wg_port:-none} " '
  {
    proto = $1; la = $5; n = split(la, p, ":"); port = p[n]
    addr = substr(la, 1, length(la) - length(port) - 1)
    if (addr ~ /^127\./ || addr ~ /^\[::1\]/ || addr == "::1" || addr ~ /%lo$/) next
    if (proto == "tcp" && index(at, " " port " ")) next
    if (proto == "udp" && index(au, " " port " ")) next
    print proto "/" port
  }' <<<"$listen" | sort -u | tr '\n' ',')"
extra="${extra%,}"
if [ -z "$listen" ]; then
  problem "LISTEN_UNEXPECTED=unknown" "ss не вернул список сокетов — проверьте вручную: sudo ss -tulpn"
elif [ -z "$extra" ]; then
  fine "наружу слушают только 80, 443, SSH ${SSH_PORT}${wg_port:+ и UDP $wg_port}"
else
  problem "LISTEN_UNEXPECTED=$extra" "лишние слушающие порты: sudo ss -tulpn — закрыть или ограничить firewall (H-5)"
fi
if command -v iptables >/dev/null 2>&1; then
  du_rules="$(iptables -S DOCKER-USER 2>/dev/null | grep -v '^-N ' || true)"
  if [ -n "$du_rules" ]; then
    log "DOCKER-USER: $(wc -l <<<"$du_rules" | tr -d ' ') правил(а) — просмотр: sudo iptables -S DOCKER-USER"
  else
    log "DOCKER-USER: правил нет или цепочки нет (Docker не запущен?) — sudo iptables -S DOCKER-USER"
  fi
fi

# --- Firewall хоста: ufw (порты Docker идут мимо ufw — поэтому выше проверяются фактические сокеты) ---
ufw_out=""
# Вывод ufw переводится (gettext; sudo сохраняет LANG/LC_*): разбор — только в локали C.
if command -v ufw >/dev/null 2>&1; then ufw_out="$(LC_ALL=C ufw status 2>/dev/null || true)"; fi
ufw_on=""
if grep -q '^Status: active' <<<"$ufw_out"; then
  ufw_on=1
  fine "ufw активен"
else
  problem "FIREWALL=ufw-inactive" "ufw не активен: правила хоста (SSH — через туннель или с адресов администраторов, UDP туннеля, 80/443 только IPv4) — RUNBOOK §11.3"
fi

# --- IPv6-записи сайтов контура (рабочего и тестовой копии) ---
for key in CADDY_SITE_ADDRESS CADDY_TEST_SITE_ADDRESS; do
  site="$(env_get "$ENV_FILE" "$key")"
  [ -n "$site" ] || continue
  if command -v dig >/dev/null 2>&1; then
    aaaa="$(dig +short AAAA "$site" 2>/dev/null || true)"
  else
    aaaa="$(getent ahostsv6 "$site" 2>/dev/null | awk '{ print $1 }' || true)"
  fi
  aaaa="$(grep -E '^[0-9A-Fa-f:]+$' <<<"$aaaa" | grep -v '^::ffff:' | sort -u | tr '\n' ' ' || true)"
  if [ -z "$aaaa" ]; then
    fine "у $site нет IPv6-записи"
  else
    problem "AAAA=$site" "есть IPv6-запись: без IPv6 в Docker api видит адрес моста вместо адреса клиента — запись убрать или настроить IPv6 Docker (RUNBOOK §11.3)"
  fi
done

# --- Туннель WireGuard к 1С ---
onec_url="$(env_get "$ENV_FILE" ONEC_BASE_URL)"
if [ -z "$wg_up" ]; then
  log "интерфейса $WG_IF нет: туннель к 1С не настроен (1С в одной сети с сервером или ещё не подключена)"
else
  if command -v systemctl >/dev/null 2>&1; then
    if [ "$(systemctl is-enabled "wg-quick@$WG_IF" 2>/dev/null || true)" = enabled ]; then
      fine "служба wg-quick@$WG_IF включена"
    else
      problem "WG_SERVICE=wg-quick@$WG_IF" "туннель не поднимется после перезагрузки: sudo systemctl enable wg-quick@$WG_IF (RUNBOOK §11.2)"
    fi
  fi
  conf="/etc/wireguard/$WG_IF.conf"
  if [ -f "$conf" ]; then
    perms="$(stat -c '%a %U' "$conf" 2>/dev/null || true)"
    if [ "$perms" = "600 root" ]; then fine "$conf — 600 root"; else problem "WG_CONF_PERMS=${perms:-?}" "нужно 600 root (16 §12.2 «Ключи»)"; fi
  fi
  if [ -n "$ufw_on" ] && [ -n "$wg_port" ]; then
    if grep -Eq "(^|[[:space:]])$wg_port/udp([[:space:]].*)?ALLOW" <<<"$ufw_out"; then
      fine "UDP $wg_port разрешён в ufw"
    else
      problem "WG_PORT_CLOSED=$wg_port/udp" "магазин не сможет поднять туннель: правило ufw — RUNBOOK §11.3; проверьте и фильтр в панели провайдера"
    fi
  fi
  wg_allowed="$(wg show "$WG_IF" allowed-ips 2>/dev/null || true)"
  if grep -q '0\.0\.0\.0/0' <<<"$wg_allowed"; then
    problem "WG_ALLOWEDIPS_WIDE" "у пира в AllowedIPs 0.0.0.0/0 — на сервере у каждого пира только свой /32"
  fi
  if [ -z "$onec_url" ]; then
    log "ONEC_BASE_URL пуст: 1С ещё не подключена — рукопожатие и HTTPS не проверяются"
  else
    onec_ip="$(host_ipv4 "$(url_hostname "$onec_url")")"
    if [ -z "$onec_ip" ]; then
      problem "WG_ROUTE=unresolved" "имя из ONEC_BASE_URL не разрешается на хосте — используйте адрес в туннеле (RUNBOOK §8.4)"
    else
      route="$(ip route get "$onec_ip" 2>/dev/null || true)"
      if grep -q " dev $WG_IF " <<<"$route "; then
        fine "адрес 1С идёт через $WG_IF"
      else
        problem "WG_ROUTE=not-$WG_IF" "адрес из ONEC_BASE_URL идёт не через туннель — проверьте AllowedIPs пира 1С"
      fi
      age="$(wg_peer_handshake_age "$WG_IF" "$onec_ip")"
      if [ -n "$age" ] && [ "$age" != never ] && [ "$age" -le "$WG_MAX_HANDSHAKE_SEC" ]; then
        fine "рукопожатие пира 1С ${age} с назад"
      else
        problem "WG_HANDSHAKE_STALE=${age:-no-peer}" "туннель магазина не активен: компьютер 1С включён? служба WireGuardTunnel запущена? интернет магазина? (RUNBOOK §11.6)"
      fi
      if command -v curl >/dev/null 2>&1; then
        hs_path="$(env_get "$ENV_FILE" ONEC_HS_PATH)"
        url="${onec_url%/}/${hs_path:+${hs_path%/}/}pos/v1/health"
        cacert=()
        [ ! -s "$SECRETS_DIR/$ONEC_CA_SECRET" ] || cacert=(--cacert "$SECRETS_DIR/$ONEC_CA_SECRET")
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${cacert[@]}" "$url" 2>/dev/null || true)"
        case "$code" in
          401|200) fine "публикация 1С отвечает по HTTPS ($code)" ;;
          *) problem "ONEC_HTTPS=${code:-000}" "нет ответа или ошибка TLS: публикация, сертификат с адресом в SAN и onec_ca.pem (RUNBOOK §8.4, §11.4)" ;;
        esac
      fi
    fi
  fi
fi

if [ -n "$problems" ]; then
  log "сеть хоста: ЗАМЕЧАНИЯ:$problems"
else
  log "сеть хоста: замечаний нет"
fi
[ -z "$problems" ]
