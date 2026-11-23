#!/usr/bin/env bash
# Ротация секретов серверного контура (16 §4.3, §15.6; infra/env/README.md §4; RUNBOOK §7). Значения не печатаются:
# новые генерирует openssl, внешние вводит человек заказчика со скрытым вводом (оператор подсказывает команду и
# значения не получает) или передаёт файлом. Контур — по каталогу: /opt/optomstroy/prod/bin или /opt/optomstroy/test/bin.
#
#   sudo /opt/optomstroy/<контур>/bin/rotate-secret.sh <команда> [--yes]
#
# Команды:
#   jwt            новый ключ подписи JWT с новым JWT_KEY_ID; прежний публичный ключ остаётся в наборе jwt_public.json,
#                  чтобы выданные access-токены (AUTH_ACCESS_TTL_SECONDS, 15 мин) проверялись до истечения
#   jwt-prune      убрать из набора все ключи, кроме активного (через ≥ AUTH_ACCESS_TTL_SECONDS после jwt;
#                  при компрометации — сразу, с --force: токены старого kid отклоняются, D-12)
#   otp-pepper     новая версия pepper OTP: файл становится набором {"<версия>":"…"}, OTP_HMAC_SECRET_VERSION+1
#   pin-pepper     новая версия pepper PIN (PIN не сбрасываются): PIN_PEPPER_VERSION+1
#   db-app         новый пароль роли pos_app (ALTER ROLE + secrets/database_url)
#   db-migrator    новый пароль роли pos_migrate (ALTER ROLE + secrets/db_migrator_password)
#   db-superuser   новый пароль суперпользователя образа POSTGRES_USER (ALTER ROLE + secrets/pg_password)
#   db-backup      новый пароль роли pos_backup сервиса backup (ALTER ROLE + secrets/db_backup_password)
#   set <имя> [--from-file ПУТЬ]
#                  записать секрет внешней системы: smspro_login, smspro_password, onec_hs_user, onec_hs_password,
#                  onec_hs_token (HTTP-сервис 1С — три файла), onec_user, onec_password (OData — пара; режимы
#                  extension и odata_only), onec_ca.pem, healthchecks_url, rclone.conf,
#                  healthchecks_metrics_url (проверка metrics_check.sh на хосте, RUNBOOK §6.4);
#                  без --from-file значение вводится со скрытым вводом
# После каждой команды затронутые сервисы пересоздаются (docker compose up -d --force-recreate): новый файл
# секрета виден контейнеру только после пересоздания.
set -euo pipefail
set +x
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

CMD="${1:-}"
[ -n "$CMD" ] || { usage; exit 2; }
shift
NAME="" FROM_FILE="" ASSUME_YES=0 FORCE=0
if [ "$CMD" = "set" ]; then
  NAME="${1:-}"
  [ -n "$NAME" ] || { printf 'set: укажите имя секрета\n' >&2; exit 2; }
  shift
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --from-file) [ $# -ge 2 ] || { printf 'нет значения для --from-file\n' >&2; exit 2; }; FROM_FILE="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --force) FORCE=1; shift ;;
    --prod-dir) [ $# -ge 2 ] || { printf 'нет значения для --prod-dir\n' >&2; exit 2; }; PROD_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'неизвестный параметр: %s\n' "$1" >&2; exit 2 ;;
  esac
done

need_root
need_cmd awk sed grep openssl date
check_docker
resolve_dirs "$HERE"
[ -f "$ENV_FILE" ] && [ -d "$SECRETS_DIR" ] || die "в $PROD_DIR нет установленного контура"
install -d -m 700 -o "$OPS_USER" -g "$OPS_USER" "$STATE_DIR"
if [ "$CMD" != "set" ]; then
  # Для set проверка — после записи: секреты 1С вводятся по одному, промежуточный неполный набор допустим.
  check_secrets
  compose_init
fi

confirm() {
  if [ "$ASSUME_YES" -eq 1 ]; then return 0; fi
  [ -t 0 ] || die "нужно подтверждение: запустите в терминале или с --yes"
  local a=""
  read -r -p "$1 [y/N]: " a
  case "$a" in y|Y|yes|да|Да) return 0 ;; *) die "отменено оператором" ;; esac
}

journal() { # запись в журнал эксплуатации контура (без значений)
  printf '%s rotate %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$STATE_DIR/secrets.log"
  chmod 600 "$STATE_DIR/secrets.log"
}

recreate() { # $@ — сервисы
  log "пересоздание: $*"
  dc up -d --no-deps --force-recreate "$@"
}

# pepper_rotate <файл секрета> <ИМЯ_ВЕРСИИ> — набор версий {"N":"…"} (16 §4.3 «Уточнения по реализации» п. 1).
pepper_rotate() {
  local name="$1" var="$2" cur next old new
  cur="$(env_get "$ENV_FILE" "$var")"
  case "$cur" in ''|*[!0-9]*) die "$var в .env должна быть числом" ;; esac
  next=$((cur + 1))
  old="$(cat "$SECRETS_DIR/$name")"
  new="$(openssl rand -hex 32)"
  case "$old" in
    \{*\})
      grep -q "\"$cur\":" "$SECRETS_DIR/$name" || die "secrets/$name: в наборе нет текущей версии $cur"
      printf '%s,"%s":"%s"}\n' "${old%\}}" "$next" "$new" | write_secret "$name"
      ;;
    *)
      case "$old" in *[!A-Za-z0-9+/=._-]*) die "secrets/$name: неожиданный формат — ротация вручную (RUNBOOK §7.2)" ;; esac
      printf '{"%s":"%s","%s":"%s"}\n' "$cur" "$old" "$next" "$new" | write_secret "$name"
      ;;
  esac
  old=""
  new=""
  env_set "$ENV_FILE" "$var" "$next"
  log "$name: версия $cur → $next (прежняя версия оставлена в наборе)"
}

# alter_role_password <роль> <пароль> — SQL под суперпользователем (psql_super_quiet, lib.sh). Параметры сессии
# выключают журналирование и pg_stat_statements, чтобы текст ALTER ROLE с паролем не сохранился.
alter_role_password() { # $1 — роль, $2 — пароль (hex; без кавычек внутри)
  case "$2" in *[!0-9a-f]*) die "внутренняя ошибка: пароль не hex" ;; esac
  printf "SET log_statement = 'none';\nSET log_min_duration_statement = -1;\nSET pg_stat_statements.track_utility = off;\nALTER ROLE \"%s\" PASSWORD '%s';\n" "$1" "$2" | psql_super_quiet
}

case "$CMD" in
  jwt)
    old_kid="$(env_get "$ENV_FILE" JWT_KEY_ID)"
    new_kid="$CONTOUR-$(date +%Y%m%d%H%M)"
    [ "$new_kid" != "$old_kid" ] || die "новый kid совпал с текущим — повторите через минуту"
    confirm "Выпустить новый ключ подписи JWT ($old_kid → $new_kid)? api и worker будут пересозданы"
    tmp_key="$(mktemp "$SECRETS_DIR/.jwt_new.XXXXXX")"
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$tmp_key" 2>/dev/null
    old_set="$(cat "$SECRETS_DIR/jwt_public.json")"
    new_entry="$(jwt_public_entry "$new_kid" "$tmp_key")"
    printf '%s,%s\n' "${old_set%\}}" "${new_entry#\{}" | write_secret jwt_public.json
    write_secret jwt_private.pem < "$tmp_key"
    rm -f "$tmp_key"
    env_set "$ENV_FILE" JWT_KEY_ID "$new_kid"
    date -u '+%s' > "$STATE_DIR/jwt_rotated_at"
    check_secret_consistency
    recreate api worker
    journal "jwt $old_kid -> $new_kid"
    log "готово. Через 15 минут (AUTH_ACCESS_TTL_SECONDS) уберите прежний ключ: rotate-secret.sh jwt-prune"
    ;;
  jwt-prune)
    kid="$(env_get "$ENV_FILE" JWT_KEY_ID)"
    ttl="$(env_get "$ENV_FILE" AUTH_ACCESS_TTL_SECONDS)"
    ttl="${ttl:-900}"
    if [ -f "$STATE_DIR/jwt_rotated_at" ] && [ "$FORCE" -eq 0 ]; then
      age_s=$(( $(date -u '+%s') - $(cat "$STATE_DIR/jwt_rotated_at") ))
      [ "$age_s" -ge "$ttl" ] || die "с ротации прошло $age_s с < $ttl с — выданные токены ещё действуют (или --force при компрометации)"
    fi
    confirm "Оставить в наборе только активный ключ $kid? Токены других kid будут отклоняться"
    jwt_public_entry "$kid" "$SECRETS_DIR/jwt_private.pem" | write_secret jwt_public.json
    check_secret_consistency
    recreate api worker
    journal "jwt-prune keep $kid"
    ;;
  otp-pepper)
    confirm "Новая версия pepper OTP? api и worker будут пересозданы; действующие коды доживут свой срок"
    pepper_rotate otp_pepper OTP_HMAC_SECRET_VERSION
    recreate api worker
    journal "otp-pepper"
    ;;
  pin-pepper)
    confirm "Новая версия pepper PIN? api и worker будут пересозданы; PIN сотрудников сохраняются"
    pepper_rotate pin_pepper PIN_PEPPER_VERSION
    recreate api worker
    journal "pin-pepper"
    ;;
  db-app)
    confirm "Новый пароль роли pos_app? api и worker будут пересозданы (кратковременный перерыв)"
    url="$(cat "$SECRETS_DIR/database_url")"
    rest="${url#*@}"
    [ "$rest" != "$url" ] || die "secrets/database_url: неожиданный формат"
    pw="$(openssl rand -hex 24)"
    alter_role_password pos_app "$pw"
    printf 'postgres://pos_app:%s@%s\n' "$pw" "$rest" | write_secret database_url
    pw=""
    url=""
    check_secret_consistency
    recreate api worker
    journal "db-app"
    ;;
  db-migrator)
    confirm "Новый пароль роли pos_migrate? (используется только migrate при обновлениях)"
    pw="$(openssl rand -hex 24)"
    alter_role_password pos_migrate "$pw"
    printf '%s\n' "$pw" | write_secret db_migrator_password
    pw=""
    journal "db-migrator"
    ;;
  db-superuser)
    su_role="$(env_get "$ENV_FILE" POSTGRES_USER)"
    confirm "Новый пароль суперпользователя $su_role? (нужен только обслуживанию: restore-db.sh и ротации ролей)"
    pw="$(openssl rand -hex 24)"
    alter_role_password "$su_role" "$pw"
    printf '%s\n' "$pw" | write_secret pg_password
    pw=""
    journal "db-superuser"
    ;;
  db-backup)
    confirm "Новый пароль роли pos_backup? backup будет пересоздан"
    pw="$(openssl rand -hex 24)"
    alter_role_password pos_backup "$pw"
    printf '%s\n' "$pw" | write_secret db_backup_password
    pw=""
    recreate backup
    journal "db-backup"
    ;;
  set)
    case "$NAME" in
      smspro_login|smspro_password) services="api worker" ;;
      onec_hs_user|onec_hs_password|onec_hs_token|onec_user|onec_password|onec_ca.pem) services="api worker" ;;
      healthchecks_url) services="worker backup" ;;
      healthchecks_metrics_url) services="" ;;   # читает bin/metrics_check.sh на хосте — контейнеры не пересоздаются
      rclone.conf) services="backup" ;;
      *) die "set: неизвестное имя $NAME (см. --help)" ;;
    esac
    if [ -n "$FROM_FILE" ]; then
      [ -s "$FROM_FILE" ] || die "--from-file: файл пуст или не найден"
      write_secret "$NAME" < "$FROM_FILE"
      log "secrets/$NAME записан из файла (исходный файл удалите или храните офлайн)"
    else
      [ -t 0 ] || die "set: значение вводится в терминале (или --from-file)"
      value=""
      read -r -s -p "Новое значение $NAME (ввод скрыт): " value
      printf '\n'
      [ -n "$value" ] || die "пустое значение"
      printf '%s' "$value" | write_secret "$NAME"
      value=""
    fi
    fix_secret_perms
    # Секреты 1С вводятся по одному: пока набор неполный, сервисы не пересоздаются (частичный набор — ошибка старта).
    case "$NAME" in
      onec_hs_user|onec_hs_password|onec_hs_token) group="$ONEC_HS_SECRETS" ;;
      onec_user|onec_password) group="$ONEC_ODATA_SECRETS" ;;
      *) group="" ;;
    esac
    if [ -n "$group" ] && [ "$(set_state "$group")" = partial ]; then
      journal "set $NAME"
      log "secrets/$NAME записан; набор ($group) ещё не полный — сервисы пересоздаются после ввода всех его файлов"
      exit 0
    fi
    check_secrets
    compose_init
    log "дополнения compose:$(compose_overlays_text)"
    # Новый секрет 1С может включить дополнение — сервисы пересоздаются с актуальным набором файлов.
    # shellcheck disable=SC2086
    [ -z "$services" ] || recreate $services
    journal "set $NAME"
    ;;
  *)
    usage
    exit 2
    ;;
esac
log "ротация $CMD завершена; запишите её в журнал эксплуатации (без значений)"
