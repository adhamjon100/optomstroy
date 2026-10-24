#!/bin/sh
# Резервное копирование БД (16 §8.2–§8.3; OPS-001…OPS-004). Образ optomstroy/backup.
#   backup.sh once      — один прогон: pg_dump -Fc → age → /backups → (rclone copy) → очистка → ping
#   backup.sh daemon    — бесконечный цикл: раз в минуту сверка времени с BACKUP_SCHEDULE (cron, 5 полей)
#   backup.sh cron-test "<выражение>" "<мин> <час> <день> <мес> <день_недели>" — самопроверка разбора cron
# Переменные (16 §4.3): PGHOST, PGUSER, PGDATABASE, PGPASSWORD_FILE, BACKUP_SCHEDULE ("0 3 * * *"),
# BACKUP_KEEP_DAYS (30), BACKUP_REMOTE (имя remote rclone, пусто — без выгрузки), BACKUP_AGE_RECIPIENT
# (обязательна: дамп без шифрования не создаётся), RCLONE_CONFIG (путь к rclone.conf), HEALTHCHECKS_PING_URL_FILE.
# Значения секретов не печатаются.
set -eu

log() { printf '{"time":"%s","service":"pos-backup","level":"%s","msg":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2"; }

# cron_match "<min> <hour> <dom> <mon> <dow>" "<m> <h> <d> <mo> <w>" → код 0, если время подходит.
# Поддержка: *, N, A-B, */S, A-B/S, списки через запятую; день недели 0–7 (0 и 7 — воскресенье);
# при ограниченных и дне месяца, и дне недели — совпадение по любому из них (как в cron).
cron_match() {
  printf '%s\n%s\n' "$1" "$2" | awk '
    function field_ok(expr, v, lo, hi,   parts, n, i, item, step, range, a, b, x) {
      n = split(expr, parts, ",")
      for (i = 1; i <= n; i++) {
        item = parts[i]; step = 1
        if (index(item, "/") > 0) { split(item, x, "/"); item = x[1]; step = x[2] + 0; if (step < 1) return -1 }
        if (item == "*") { a = lo; b = hi }
        else if (index(item, "-") > 0) { split(item, x, "-"); a = x[1] + 0; b = x[2] + 0 }
        else { a = item + 0; b = (step > 1) ? hi : a }
        if (item !~ /^(\*|[0-9]+(-[0-9]+)?)$/) return -1
        if (a < lo || b > hi || a > b) return -1
        if (v >= a && v <= b && (v - a) % step == 0) return 1
      }
      return 0
    }
    NR == 1 { ne = split($0, e, /[ \t]+/) }
    NR == 2 { split($0, t, /[ \t]+/) }
    END {
      if (ne != 5) exit 2
      lo[1] = 0; hi[1] = 59; lo[2] = 0; hi[2] = 23; lo[3] = 1; hi[3] = 31; lo[4] = 1; hi[4] = 12; lo[5] = 0; hi[5] = 7
      for (k = 1; k <= 5; k++) { r[k] = field_ok(e[k], t[k] + 0, lo[k], hi[k]); if (r[k] < 0) exit 2 }
      if (r[5] == 0 && t[5] + 0 == 0) r[5] = field_ok(e[5], 7, 0, 7)
      day = (e[3] != "*" && e[5] != "*") ? (r[3] || r[5]) : (r[3] && r[5])
      exit (r[1] && r[2] && r[4] && day) ? 0 : 1
    }'
}

pg_dump_bin() {
  command -v pg_dump 2>/dev/null || { [ -x /usr/libexec/postgresql17/pg_dump ] && echo /usr/libexec/postgresql17/pg_dump; } || return 1
}

ping_hc() {
  # $1 — суффикс Healthchecks ("" — успех, "/fail" — ошибка, "/start" — начало)
  if [ -n "${HEALTHCHECKS_PING_URL_FILE:-}" ] && [ -s "${HEALTHCHECKS_PING_URL_FILE}" ]; then
    url="$(tr -d '\r\n' < "$HEALTHCHECKS_PING_URL_FILE")"
    wget -q -T 10 -O /dev/null "${url}$1" 2>/dev/null || log warn "healthchecks: ping не доставлен"
  fi
}

run_once() {
  if [ -n "${PGPASSWORD_FILE:-}" ]; then
    PGPASSWORD="$(tr -d '\r\n' < "$PGPASSWORD_FILE")"
    export PGPASSWORD
  fi
  : "${PGHOST:?PGHOST не задана}" "${PGUSER:?PGUSER не задана}" "${PGDATABASE:?PGDATABASE не задана}"
  if [ -z "${BACKUP_AGE_RECIPIENT:-}" ]; then
    log error "BACKUP_AGE_RECIPIENT не задана: незашифрованный дамп не создаётся (16 §4.3, OPS-004)"
    ping_hc /fail
    return 1
  fi
  dump="$(pg_dump_bin)" || { log error "pg_dump не найден"; return 1; }
  ping_hc /start
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  out="/backups/${PGDATABASE}_${ts}.dump.age"
  tmp="${out}.partial"
  # pg_dump → age: незашифрованные данные на диск не пишутся. set -o pipefail в busybox sh есть.
  set -o pipefail
  if "$dump" --format=custom --no-owner --no-privileges | age -r "$BACKUP_AGE_RECIPIENT" -o "$tmp"; then
    mv "$tmp" "$out"
    log info "дамп создан: $(basename "$out") ($(wc -c < "$out") байт)"
  else
    rm -f "$tmp"
    log error "pg_dump/age завершились с ошибкой"
    ping_hc /fail
    return 1
  fi
  if [ -n "${BACKUP_REMOTE:-}" ]; then
    if rclone copy --no-traverse "$out" "${BACKUP_REMOTE%/}/" ; then
      log info "выгружен во внешнее хранилище (rclone copy, без удаления на стороне хранилища)"
    else
      log error "rclone copy завершился с ошибкой"
      ping_hc /fail
      return 1
    fi
  fi
  keep="${BACKUP_KEEP_DAYS:-30}"
  find /backups -maxdepth 1 -type f -name '*.dump.age' -mtime +"$keep" -exec rm -f {} + 2>/dev/null || true
  ping_hc ""
  return 0
}

case "${1:-daemon}" in
  once)
    run_once
    ;;
  daemon)
    schedule="${BACKUP_SCHEDULE:-0 3 * * *}"
    cron_match "$schedule" "0 0 1 1 0" || [ $? -eq 1 ] || { log error "BACKUP_SCHEDULE: неверное cron-выражение"; exit 2; }
    log info "расписание резервного копирования: ${schedule} (TZ=${TZ:-UTC})"
    last=""
    while :; do
      now="$(date +'%M %H %d %m %w')"
      set -- $now
      key="$1$2$3$4"
      if [ "$key" != "$last" ] && cron_match "$schedule" "$(( 1$1 - 100 )) $(( 1$2 - 100 )) $(( 1$3 - 100 )) $(( 1$4 - 100 )) $5"; then
        last="$key"
        run_once || log error "прогон резервного копирования не удался (следующая попытка — по расписанию)"
      fi
      sleep 20
    done
    ;;
  cron-test)
    cron_match "$2" "$3"
    ;;
  *)
    echo "использование: backup.sh once | daemon | cron-test <выражение> <время>" >&2
    exit 2
    ;;
esac
