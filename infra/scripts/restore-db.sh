#!/usr/bin/env bash
# Восстановление базы контура из зашифрованной копии (16 §8.5, §15.3; RUNBOOK §4.5, §4.8). Разрушающая операция.
# Контур — по каталогу bin/: рабочий (/opt/optomstroy/prod) или тестовая копия (/opt/optomstroy/test; туда же
# можно восстановить копию рабочей базы — RUNBOOK §10.3, только по согласованию с заказчиком, Q-027).
#
# Из ежедневной копии (дамп; данные после момента копии теряются, RPO ≤ 24 ч, 16 §8.1):
#   sudo /opt/optomstroy/<контур>/bin/restore-db.sh --identity /media/<носитель>/optomstroy-backup.key \
#        [--dump /srv/optomstroy/<контур>/backups/<файл>.dump.age]
# На момент времени (непрерывная копия WAL, BACKUP_PITR=on; 15 ADR-035; RUNBOOK §4.8):
#   sudo /opt/optomstroy/<контур>/bin/restore-db.sh --identity /media/<носитель>/optomstroy-backup.key \
#        --to-time 'ГГГГ-ММ-ДД ЧЧ:ММ[:СС]' [--sysid <system_identifier>] [--base <base_….info>] [--wal-hours 24]
#   Время — по часовому поясу контура (TZ в .env, по умолчанию Asia/Bishkek); восстанавливается всё, что
#   зафиксировано не позже этого момента. Весь кластер (каталог данных) заменяется базовой копией + архивом WAL;
#   прежний каталог данных сохраняется рядом (pgdata.pre-pitr-<UTC>) до ручного удаления.
# До конца архива (гибель сервера или диска базы: всё, что успело в архив, — момент угадывать не нужно):
#   sudo /opt/optomstroy/<контур>/bin/restore-db.sh --identity /media/<носитель>/optomstroy-backup.key \
#        --to-latest [--sysid <system_identifier>] [--base <base_….info>]
#   --sysid — кластер, из копий которого восстанавливать (каталог backups/pitr/<sysid>); обязателен, если там
#   несколько кластеров (новый сервер: прежний — из внешнего хранилища, новый пустой — после install.sh).
#
# Ключ age приносит его держатель на время восстановления (на сервере не хранится, OPS-004); скрипт монтирует его
# в одноразовый контейнер только для чтения и на диск не копирует. Незашифрованная копия на диск копий не пишется.
# Шаги дампа: проверка копии целиком (age -d в никуда — ключ и целостность) → подтверждение вводом имени базы →
# страховочная копия текущей базы (если получается) → остановка api, worker, backup → пустая база (владелец
# pos_migrate, права на базу — как в initdb 10-roles.sh, без CREATE у pos_app) → pg_restore потоком → проверка
# владельцев и прав роли pos_app → владелец схемы pgboss — pos_migrate (копии контуров до 2026-11-19, RUNBOOK §3.6),
# у pos_app нет CREATE на базу (07 DATA-012) → ANALYZE → migrate (если образ новее копии; ставит и проверяет схему
# pg-boss) → запуск сервисов и проверка готовности.
# Шаги --to-time / --to-latest: выбор кластера (pitr_select_cluster) и базовой копии, закончившейся раньше момента
# (--to-latest — самой новой) → проверка ключа на ней (расшифровка и распаковка целиком, размер до сжатия) →
# подтверждение → страховочная копия (без очистки PITR) → закрытие текущего сегмента WAL и ожидание его архивации
# (если работает тот же кластер) → проверка архива (базовая копия и её первый сегмент на месте, дыры в WAL) и места →
# остановка api, worker, backup и postgres → прежний каталог данных — в pgdata.pre-pitr-<UTC> → базовая копия и
# нужные сегменты WAL в новый каталог (restore_command; --to-time — recovery_target_time и promote, --to-latest —
# без цели: весь архив, затем promote сам) → запуск postgres, восстановление и promote (новая линия времени) →
# снятие настроек восстановления, пароли ролей из secrets/ → те же проверки владельцев → migrate → запуск
# сервисов → новая базовая копия.
# Копия без владельцев и прав (формат backup.sh до 2026-11-18) не принимается — нужна ручная выдача прав (DevOps).
# Коды выхода: 0 — восстановлено; 1 — ошибка (сообщение говорит, в каком состоянии остался контур); 2 — параметры.
set -euo pipefail
set +x
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

IDENTITY="" DUMP="" ASSUME_YES=0 TO_TIME="" TO_LATEST=0 BASE_INFO="" SYSID="" WAL_HOURS=24 WAL_HOURS_SET=0
while [ $# -gt 0 ]; do
  opt="$1" val=""
  case "$opt" in
    --identity|--dump|--prod-dir|--to-time|--base|--sysid|--wal-hours)
      [ $# -ge 2 ] || { printf 'нет значения для %s\n' "$opt" >&2; exit 2; }
      val="$2"; shift 2 ;;
    *) shift ;;
  esac
  case "$opt" in
    --identity) IDENTITY="$val" ;;
    --dump) DUMP="$val" ;;
    --prod-dir) PROD_DIR="$val" ;;
    --to-time) TO_TIME="$val" ;;
    --to-latest) TO_LATEST=1 ;;
    --base) BASE_INFO="$val" ;;
    --sysid) SYSID="$val" ;;
    --wal-hours) WAL_HOURS="$val"; WAL_HOURS_SET=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'неизвестный параметр: %s (см. --help)\n' "$opt" >&2; exit 2 ;;
  esac
done
MODE=dump
PITR_KIND=""
if [ -n "$TO_TIME" ] && [ "$TO_LATEST" -eq 1 ]; then
  printf -- '--to-time и --to-latest взаимоисключающие\n' >&2; exit 2
fi
if [ -n "$TO_TIME" ] || [ "$TO_LATEST" -eq 1 ]; then
  MODE=pitr
  PITR_KIND=time
  [ "$TO_LATEST" -eq 0 ] || PITR_KIND=latest
  [ -z "$DUMP" ] || { printf -- '--dump и --to-time/--to-latest взаимоисключающие\n' >&2; exit 2; }
  case "$WAL_HOURS" in ''|*[!0-9]*) printf -- '--wal-hours: целое число часов\n' >&2; exit 2 ;; esac
  case "$SYSID" in
    '') ;;
    *[!0-9]*) printf -- '--sysid: system_identifier — только цифры (имя каталога backups/pitr/<sysid>)\n' >&2; exit 2 ;;
  esac
elif [ -n "$BASE_INFO" ] || [ -n "$SYSID" ]; then
  printf -- '--base и --sysid — только вместе с --to-time или --to-latest\n' >&2; exit 2
fi

need_root
need_cmd awk sed date find df
check_docker
resolve_dirs "$HERE"
[ -f "$ENV_FILE" ] && [ -f "$PROD_DIR/compose.prod.yml" ] || die "в $PROD_DIR нет установленного контура"
check_secrets
compose_init

[ -n "$IDENTITY" ] && [ -s "$IDENTITY" ] || { usage >&2; die "--identity: нужен файл приватного ключа age"; }
IDENTITY="$(cd "$(dirname "$IDENTITY")" && pwd)/$(basename "$IDENTITY")"

BACKUP_IMAGE="optomstroy/backup:$(env_get "$ENV_FILE" BACKUP_TAG)"
image_exists "$BACKUP_IMAGE" || die "образа $BACKUP_IMAGE нет"
PGU="$(env_get "$ENV_FILE" POSTGRES_USER)"
PGD="$(env_get "$ENV_FILE" POSTGRES_DB)"
case "$PGD" in ''|[!a-z_]*|*[!a-z0-9_]*) die "POSTGRES_DB: ожидается имя из [a-z0-9_]" ;; esac
NET="$BACKEND_NET"

if [ "$MODE" = dump ]; then
  if [ -z "$DUMP" ]; then
    DUMP="$(ls -1t "$DATA_DIR/backups"/*.dump.age 2>/dev/null | head -n 1 || true)"
    [ -n "$DUMP" ] || die "в $DATA_DIR/backups нет копий — укажите --dump"
  fi
  [ -s "$DUMP" ] || die "--dump: файл не найден или пуст"
  DUMP="$(cd "$(dirname "$DUMP")" && pwd)/$(basename "$DUMP")"
  SOURCE_NAME="$(basename "$DUMP")"
else
  PITR_HOST_DIR="$DATA_DIR/backups/pitr"
  if [ "$PITR_KIND" = time ]; then
    CONTOUR_TZ="$(env_get "$ENV_FILE" TZ)"
    CONTOUR_TZ="${CONTOUR_TZ:-Asia/Bishkek}"
    [ "$CONTOUR_TZ" = UTC ] || [ -f "/usr/share/zoneinfo/$CONTOUR_TZ" ] \
      || die "часового пояса $CONTOUR_TZ (TZ в .env) нет в /usr/share/zoneinfo — установите tzdata (apt-get install tzdata)"
    TARGET_UTC="$(pitr_to_utc "$TO_TIME" "$CONTOUR_TZ")" \
      || die "--to-time: ожидается 'ГГГГ-ММ-ДД ЧЧ:ММ' или 'ГГГГ-ММ-ДД ЧЧ:ММ:СС' (время $CONTOUR_TZ), получено «$TO_TIME»"
    [ "$TARGET_UTC" \< "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" ] || die "--to-time: момент $TO_TIME ещё не наступил"
    TARGET_TEXT="$TO_TIME ($CONTOUR_TZ) = $TARGET_UTC"
  else
    # До конца архива: базовая копия — самая новая; WAL — весь, без предела по времени (--wal-hours не нужен).
    TARGET_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    TARGET_TEXT="конец архива WAL"
    [ "$WAL_HOURS_SET" -eq 0 ] || warn "--wal-hours с --to-latest не нужен — восстанавливается весь архив"
  fi
  if [ -n "$BASE_INFO" ]; then
    case "$BASE_INFO" in *.tar.gz.age) BASE_INFO="${BASE_INFO%.tar.gz.age}.info" ;; esac
    [ -f "$BASE_INFO" ] || die "--base: нет файла сведений $BASE_INFO"
    BASE_INFO="$(cd "$(dirname "$BASE_INFO")" && pwd)/$(basename "$BASE_INFO")"
    [ "$(pitr_info_get "$BASE_INFO" end_utc)" \< "$TARGET_UTC" ] \
      || die "--base: копия закончилась позже момента восстановления — восстановиться раньше её конца нельзя"
    if [ -n "$SYSID" ] && [ "$(pitr_info_get "$BASE_INFO" system_identifier)" != "$SYSID" ]; then
      die "--base и --sysid: копия $(basename "$BASE_INFO") — кластера $(pitr_info_get "$BASE_INFO" system_identifier), а не $SYSID"
    fi
  else
    # Кластер — явно (--sysid) или единственный в pitr/. Несколько (новый сервер: прежний из внешнего хранилища и
    # новый пустой после install.sh) — отказ: выбор только по времени восстановил бы новый пустой кластер.
    sel_rc=0
    SEL="$(pitr_select_cluster "$PITR_HOST_DIR" "$SYSID")" || sel_rc=$?
    case "$sel_rc" in
      0) SYSID="$SEL" ;;
      3) die "в $PITR_HOST_DIR несколько кластеров PostgreSQL:
$SEL
Укажите, из копий какого восстанавливать: --sysid <system_identifier> или --base <…/base/base_….info>.
Новый сервер: прежний кластер — тот, чей WAL кончается временем гибели прежнего сервера; новый (первая базовая копия
install.sh) — пустой. Момент --to-time — не позже последнего сегмента WAL прежнего кластера (RUNBOOK §4.8)." ;;
      4) die "--sysid $SYSID: в $PITR_HOST_DIR/$SYSID/base нет базовых копий (ls $PITR_HOST_DIR)" ;;
      *) die "выбор кластера в $PITR_HOST_DIR не удался (код $sel_rc)" ;;
    esac
    BASE_INFO="$(pitr_pick_base "$PITR_HOST_DIR" "$TARGET_UTC" "$SYSID")"
    [ -n "$BASE_INFO" ] || die "нет базовой копии${SYSID:+ кластера $SYSID}, закончившейся раньше $TARGET_TEXT в $PITR_HOST_DIR.
Самая ранняя доступна: $(ls -1 "$PITR_HOST_DIR"/${SYSID:-*}/base/base_*.info 2>/dev/null | sed 's#.*/##' | sort | head -n 1 || true).
Копия вне сервера: rclone copy <BACKUP_REMOTE>/pitr $PITR_HOST_DIR (RUNBOOK §4.8). Иначе — ежедневная копия (--dump)."
  fi
  BASE_FILE="$(dirname "$BASE_INFO")/$(pitr_info_get "$BASE_INFO" file)"
  [ -s "$BASE_FILE" ] || die "нет файла базовой копии $BASE_FILE"
  WAL_DIR="$(cd "$(dirname "$BASE_INFO")/.." && pwd)/wal"
  [ -d "$WAL_DIR" ] || die "нет архива WAL $WAL_DIR"
  START_WAL="$(pitr_info_get "$BASE_INFO" start_wal)"
  printf '%s\n' "$START_WAL" | grep -Eq '^[0-9A-F]{24}$' || die "в $BASE_INFO нет start_wal"
  BASE_SYSID="$(pitr_info_get "$BASE_INFO" system_identifier)"
  BASE_SYSID="${BASE_SYSID:-$(basename "$(dirname "$WAL_DIR")")}"
  if [ "$PITR_KIND" = time ]; then
    SOURCE_NAME="$(basename "$BASE_FILE") → $TARGET_UTC"
  else
    SOURCE_NAME="$(basename "$BASE_FILE") → конец архива"
  fi
  PG_IMAGE="$(compose_image "$PROD_DIR/compose.prod.yml" postgres)"
  [ -n "$PG_IMAGE" ] && image_exists "$PG_IMAGE" || die "нет образа postgres контура ($PG_IMAGE) — docker load"
fi

if [ "$(container_state postgres)" != "healthy" ]; then
  dc up -d postgres
  if ! wait_healthy postgres 240; then
    [ "$MODE" = pitr ] || die "postgres не запускается — bin/dc logs postgres (восстановление невозможно до исправления)"
    warn "postgres не запускается — восстановление на момент времени продолжится без страховочной копии"
  fi
fi

# restore_container <команда sh>: одноразовый контейнер образа backup в сети backend; ключ, дамп и пароль
# суперпользователя — bind-mount только для чтения (файлы принадлежат другим пользователям — DAC_READ_SEARCH).
SU_CRED_FILE="$SECRETS_DIR/pg_password"   # check-secrets: allow (путь файла секрета, значение не читается скриптом)
restore_container() {
  docker run --rm --network "$NET" --user 0:0 --read-only --tmpfs /tmp \
    --cap-drop ALL --cap-add DAC_READ_SEARCH --security-opt no-new-privileges:true \
    -e PGHOST=postgres -e PGUSER="$PGU" -e PGDATABASE="$PGD" \
    -v "$IDENTITY:/run/restore/identity:ro" -v "${DUMP:-$BASE_FILE}:/run/restore/dump.age:ro" \
    -v "$SU_CRED_FILE:/run/restore/su_cred:ro" \
    --entrypoint /bin/sh "$BACKUP_IMAGE" -c "set -eu; set -o pipefail; PGPASSWORD=\"\$(tr -d '\r\n' < /run/restore/su_cred)\"; export PGPASSWORD; $1"
}

psql_super() { # SQL из stdin под суперпользователем внутри контейнера postgres
  dc exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 --no-psqlrc -qAt -U "$POSTGRES_USER" -d "${1:-$POSTGRES_DB}"' sh "$@"
}

# wal_mtime_utc <файл> → время изменения (у сегмента архива — время шифрования) в UTC.
wal_mtime_utc() { date -u -d "@$(stat -c %Y "$1")" '+%Y-%m-%dT%H:%M:%SZ'; }

RUN_SYSID=""
if [ "$MODE" = pitr ] && [ "$(container_state postgres)" = healthy ]; then
  RUN_SYSID="$(printf 'SELECT system_identifier FROM pg_control_system();\n' | psql_super postgres 2>/dev/null || true)"
  case "$RUN_SYSID" in *[!0-9]*) RUN_SYSID="" ;; esac
fi

BASE_RAW=""
if [ "$MODE" = dump ]; then
  log "1/8 Проверка копии целиком: $(basename "$DUMP") ($(wc -c < "$DUMP") байт)"
  restore_container 'age -d -i /run/restore/identity /run/restore/dump.age > /dev/null' \
    || die "копия не расшифровывается (неверный ключ или повреждённый файл) — рабочая база не тронута"
else
  log "1/8 Базовая копия $(basename "$BASE_FILE") (конец $(pitr_info_get "$BASE_INFO" end_utc), WAL с $START_WAL); восстановление: $TARGET_TEXT"
  log "кластер копии $BASE_SYSID, работающий кластер ${RUN_SYSID:-не отвечает}"
  if [ -n "$RUN_SYSID" ] && [ "$RUN_SYSID" != "$BASE_SYSID" ]; then
    warn "кластер будет заменён ДРУГИМ кластером ($RUN_SYSID → $BASE_SYSID): так и нужно на новом сервере (RUNBOOK §4.8); иначе проверьте --sysid/--base"
  fi
  # Расшифровка и распаковка целиком: ключ, целостность age и gzip, размер до сжатия (оценка места, шаг 3).
  BASE_RAW="$(restore_container 'age -d -i /run/restore/identity /run/restore/dump.age | gzip -dc | wc -c' | tr -dc 0-9)" \
    || die "базовая копия не расшифровывается или не распаковывается (неверный ключ или повреждённый файл) — рабочая база не тронута"
  [ -n "$BASE_RAW" ] || die "размер базовой копии не получен — рабочая база не тронута"
fi
log "ключ подходит, файл цел"

log "2/8 Подтверждение"
if [ "$ASSUME_YES" -eq 0 ]; then
  [ -t 0 ] || die "нужно подтверждение в терминале (или --yes)"
  if [ "$MODE" = dump ]; then
    printf 'ВНИМАНИЕ: база %s будет удалена и восстановлена из %s.\nДанные после момента копии будут потеряны. Введите имя базы для подтверждения: ' "$PGD" "$(basename "$DUMP")"
  else
    other=""
    if [ -n "$RUN_SYSID" ] && [ "$RUN_SYSID" != "$BASE_SYSID" ]; then
      other="Кластер будет заменён ДРУГИМ кластером: работающий $RUN_SYSID → кластер копии $BASE_SYSID.\n"
    fi
    if [ "$PITR_KIND" = time ]; then
      printf "ВНИМАНИЕ: кластер PostgreSQL контура %s (база %s; кластер копии %s, работающий %s) будет заменён состоянием на %s (%s).\n${other}Всё, что зафиксировано позже, будет потеряно; прежний каталог данных останется в %s/pgdata.pre-pitr-*.\nВведите имя базы для подтверждения: " \
        "$CONTOUR" "$PGD" "$BASE_SYSID" "${RUN_SYSID:-не отвечает}" "$TO_TIME" "$CONTOUR_TZ" "$DATA_DIR"
    else
      last_now="$(ls -1 "$WAL_DIR" 2>/dev/null | sed -n 's/^\([0-9A-F]\{24\}\)\.gz\.age$/\1/p' | sort | tail -n 1)"
      last_at="нет"
      [ -z "$last_now" ] || last_at="$(wal_mtime_utc "$WAL_DIR/$last_now.gz.age")"
      printf "ВНИМАНИЕ: кластер PostgreSQL контура %s (база %s; кластер копии %s, работающий %s) будет заменён последним состоянием из архива (сейчас последний сегмент %s, зашифрован %s UTC; если работает тот же кластер, текущий сегмент перед остановкой тоже уйдёт в архив).\n${other}Всё, что не успело в архив, будет потеряно; прежний каталог данных останется в %s/pgdata.pre-pitr-*.\nВведите имя базы для подтверждения: " \
        "$CONTOUR" "$PGD" "$BASE_SYSID" "${RUN_SYSID:-не отвечает}" "${last_now:-нет}" "$last_at" "$DATA_DIR"
    fi
  fi
  read -r answer
  [ "$answer" = "$PGD" ] || die "отменено: имя базы не совпало — рабочая база не тронута"
fi

log "3/8 Страховочная копия текущей базы"
# BACKUP_SKIP_PRUNE=1: прогон не чистит архив PITR — выбранная базовая копия и её WAL могут быть у края срока хранения.
if [ "$(container_state postgres)" = healthy ] && dc run --rm -e BACKUP_SKIP_PRUNE=1 backup once; then
  log "страховочная копия создана в $DATA_DIR/backups"
else
  warn "страховочную копию сделать не удалось (база повреждена?)"
  if [ "$ASSUME_YES" -eq 0 ]; then
    read -r -p "Продолжить восстановление без страховочной копии? [y/N]: " a
    case "$a" in y|Y|yes|да|Да) ;; *) die "отменено — рабочая база не тронута" ;; esac
  fi
fi

if [ "$MODE" = pitr ]; then
  # Последние изменения — в архив: текущий сегмент закрывается, ждём его в архиве (сервис backup ещё работает).
  # Только если работает тот же кластер: WAL другого (новый сервер) пишется в свой каталог и восстановлению не нужен.
  if [ "$(container_state postgres)" = healthy ] && [ "$RUN_SYSID" = "$BASE_SYSID" ]; then
    seg="$(printf 'SELECT pg_walfile_name(pg_switch_wal());\n' | psql_super postgres 2>/dev/null || true)"
    if printf '%s\n' "$seg" | grep -Eq '^[0-9A-F]{24}$'; then
      deadline=$(( $(date +%s) + 180 ))
      until [ -f "$WAL_DIR/$seg.gz.age" ]; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
          warn "сегмент $seg не появился в архиве за 180 с (сервис backup, BACKUP_PITR) — изменения последних минут могут не войти"
          break
        fi
        sleep 5
      done
    fi
  fi
  WAL_LIST="$(mktemp)"
  trap 'rm -f "$WAL_LIST"' EXIT
  if [ "$PITR_KIND" = time ]; then
    until_epoch=$(( $(date -u -d "$TARGET_UTC" +%s) + WAL_HOURS * 3600 ))
  else
    until_epoch=$(( $(date +%s) + 86400 ))   # весь архив
  fi
  pitr_wal_list "$WAL_DIR" "$START_WAL" "$until_epoch" > "$WAL_LIST"
  chmod 644 "$WAL_LIST"
  # Страховочная копия архив не чистит (BACKUP_SKIP_PRUNE), но проверка — не на совпадении: выбранная базовая копия
  # и её первый сегмент WAL должны быть на месте ДО остановки и переноса каталога данных.
  [ -f "$BASE_INFO" ] && [ -s "$BASE_FILE" ] \
    || die "базовая копия $(basename "$BASE_FILE") удалена во время страховочной копии — рабочая база не тронута"
  grep -qx "$START_WAL" "$WAL_LIST" \
    || die "в архиве $WAL_DIR нет первого сегмента $START_WAL базовой копии — рабочая база не тронута (другая копия: --base)"
  gap_rc=0
  GAP="$(pitr_wal_gaps "$WAL_LIST")" || gap_rc=$?
  if [ "$gap_rc" -ne 0 ]; then
    gap_prev="${GAP%% *}"
    gap_next="${GAP##* }"
    gap_at="$(wal_mtime_utc "$WAL_DIR/$gap_prev.gz.age")"
    warn "в архиве WAL дыра: после $gap_prev (зашифрован $gap_at UTC) следующий сегмент — $gap_next; восстановить можно только то, что до дыры"
    if [ "$PITR_KIND" = time ]; then
      # Все записи до дыры сделаны не позже шифрования последнего сегмента перед ней: момент позже — недостижим.
      [ "$TARGET_UTC" \< "$gap_at" ] \
        || die "момент $TARGET_UTC позже дыры в архиве WAL ($gap_prev, $gap_at UTC) — восстановиться на него нельзя. Рабочая база не тронута.
Возможно: момент не позже $gap_at UTC (--to-time) или всё до дыры (--to-latest)."
    else
      log "без цели восстановления PostgreSQL остановится на дыре молча — всё после $gap_prev ($gap_at UTC) будет потеряно"
      if [ "$ASSUME_YES" -eq 0 ]; then
        read -r -p "Восстановить до дыры (до $gap_at UTC)? [y/N]: " a
        case "$a" in y|Y|yes|да|Да) ;; *) die "отменено — рабочая база не тронута" ;; esac
      fi
    fi
    # Сегменты после дыры не нужны: восстановление до них не дойдёт (место на диске базы).
    gap_num="$(printf '%s' "$gap_prev" | cut -c9-24)"
    awk -v c="$gap_num" '/\.history$/ || ("" substr($0, 9, 16)) <= ("" c)' "$WAL_LIST" > "$WAL_LIST.cut"
    mv -f "$WAL_LIST.cut" "$WAL_LIST"
    chmod 644 "$WAL_LIST"
  fi
  segs="$(grep -c -v '\.history$' "$WAL_LIST" || true)"
  [ "${segs:-0}" -gt 0 ] || die "в архиве $WAL_DIR нет сегментов WAL после базовой копии — восстановление на момент невозможно"
  LAST_SEG="$(grep -v '\.history$' "$WAL_LIST" | tail -n 1)"
  LAST_AT="$(wal_mtime_utc "$WAL_DIR/$LAST_SEG.gz.age")"
  need="$(pitr_bytes_needed "$BASE_INFO" "$segs" "$BASE_RAW")" \
    || die "место для восстановления не оценить (нет размера базовой копии) — рабочая база не тронута"
  avail="$(df -P -B1 "$DATA_DIR" | awk 'NR == 2 { print $4 }')"
  [ "${avail:-0}" -gt "$need" ] \
    || die "на диске базы ($DATA_DIR) свободно $((avail / 1048576)) МиБ, нужно около $((need / 1048576)) МиБ (базовая копия $((BASE_RAW / 1048576)) МиБ до сжатия и $segs сегментов WAL) — рабочая база не тронута"
  if [ "$PITR_KIND" = time ]; then
    log "сегментов WAL для восстановления: $segs (с $START_WAL, зашифрованы не позже момента + ${WAL_HOURS} ч)"
  else
    log "сегментов WAL для восстановления: $segs (с $START_WAL до $LAST_SEG, зашифрован $LAST_AT UTC) — восстанавливается всё до конца архива"
  fi
fi

log "4/8 Остановка api, worker, backup (общий caddy отвечает 502 на /api/* этого контура)"
dc stop api worker backup

if [ "$MODE" = dump ]; then
log "5/8 Пустая база $PGD (владелец pos_migrate; права на базу — как в initdb)"
psql_super postgres >/dev/null <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$PGD' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "$PGD";
CREATE DATABASE "$PGD" OWNER pos_migrate TEMPLATE template0 ENCODING 'UTF8';
SQL
psql_super "$PGD" >/dev/null <<'SQL'
DO $$ BEGIN
  EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
  EXECUTE format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO pos_app', current_database());
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO pos_readonly, pos_backup', current_database());
  -- CREATE на базу у pos_app нет (07 DATA-012): схему pgboss ставит migrate под pos_migrate (CI-KI-03 закрыт).
END $$;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SQL

log "6/8 Восстановление потоком (age -d | pg_restore; несколько минут)"
restore_log="$(mktemp)"
rc=0
restore_container 'age -d -i /run/restore/identity /run/restore/dump.age | pg_restore --exit-on-error -d "$PGDATABASE"' \
  > "$restore_log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  tail -n 20 "$restore_log" >&2 || true
  rm -f "$restore_log"
  die "pg_restore завершился с ошибкой ($rc). База $PGD неполная, api/worker/backup остановлены.
Повторите с другой копией или страховочной (самая новая в $DATA_DIR/backups); эскалация — DevOps."
fi
rm -f "$restore_log"
else
if [ "$PITR_KIND" = time ]; then
  RECOVERY_CONF="$(pitr_recovery_conf "$TARGET_UTC")"
  # Отказ «recovery ended before configured recovery target» бывает только с целью (--to-time).
  FAIL_RE='recovery ended before configured recovery target|requested recovery stop point|PANIC|could not locate a valid checkpoint|startup process .* (exited|terminated)|is not a child of this server.s history|requested timeline .* (is not|does not)'
  fail_hint="Если «recovery ended before configured recovery target» — в архиве нет фиксаций после момента в пределах
--wal-hours $WAL_HOURS: увеличьте --wal-hours, выберите момент раньше или восстановите всё до конца архива (--to-latest)."
else
  RECOVERY_CONF="$(pitr_recovery_conf latest)"
  FAIL_RE='requested recovery stop point|PANIC|could not locate a valid checkpoint|startup process .* (exited|terminated)|is not a child of this server.s history|requested timeline .* (is not|does not)'
  fail_hint=""
fi
fail_hint="$fail_hint${fail_hint:+
}Если «is not a child of this server's history» — базовая копия с другой ветви линий времени (сделана после прошлого
восстановления на момент): укажите --base с копией нужной ветви (ls $(dirname "$BASE_INFO"))."

log "5/8 Каталог данных: базовая копия и WAL ($TARGET_TEXT; прежний каталог сохраняется)"
dc rm -f -s postgres >/dev/null
PRE_PITR="$DATA_DIR/pgdata.pre-pitr-$(date -u +%Y%m%dT%H%M%SZ)"
mv "$DATA_DIR/pgdata" "$PRE_PITR"
install -d -m 700 -o "$PG_UID" -g "$PG_UID" "$DATA_DIR/pgdata"
revert_hint="откат к состоянию до восстановления: sudo $PROD_DIR/bin/dc rm -f -s postgres && sudo rm -rf $DATA_DIR/pgdata && sudo mv $PRE_PITR $DATA_DIR/pgdata && sudo $PROD_DIR/bin/dc up -d"
pitr_restore_into "$IDENTITY" "$BASE_INFO" "$WAL_LIST" "$DATA_DIR/pgdata:/var/lib/postgresql/data" \
  /var/lib/postgresql/data "$RECOVERY_CONF" "$PG_IMAGE" "$BACKUP_IMAGE" \
  || die "каталог данных не подготовлен; $revert_hint"

if [ "$PITR_KIND" = time ]; then
  log "6/8 Восстановление до момента и promote (журнал: bin/dc logs postgres)"
else
  log "6/8 Восстановление до конца архива и promote (журнал: bin/dc logs postgres)"
fi
since="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
dc up -d postgres
PG_CID="$(dc ps -q postgres 2>/dev/null | head -n 1 || true)"
deadline=$(( $(date +%s) + 7200 ))
while :; do
  r="$(printf 'SELECT pg_is_in_recovery();\n' | psql_super postgres 2>/dev/null || true)"
  [ "$r" = f ] && break
  # Журнал читается целиком и только потом ищется. Не `dc logs | grep -q`: grep выходит на первом совпадении,
  # docker compose получает SIGPIPE (141), и при pipefail конвейер «не находит» строку отказа — скрипт ждал бы 2 ч,
  # а postgres (restart: unless-stopped) раз за разом повторял бы восстановление.
  pg_log="$(dc logs --since "$since" postgres 2>/dev/null || true)"
  failed=0
  if grep -Eq "$FAIL_RE" <<<"$pg_log"; then failed=1; fi
  # Независимо от текста журнала: контейнер остановился или перезапускался — восстановление не удалось.
  if [ -n "$PG_CID" ]; then
    case "$(docker inspect --format '{{.State.Status}} {{.RestartCount}}' "$PG_CID" 2>/dev/null || true)" in
      ''|'created 0'|'running 0') ;;
      *) failed=1 ;;
    esac
  fi
  if [ "$failed" -eq 1 ]; then
    dc logs --since "$since" --tail 30 postgres >&2 || true
    dc stop postgres >/dev/null 2>&1 || true
    die "восстановление ($TARGET_TEXT) не удалось (журнал выше).
$fail_hint
api/worker/backup и postgres остановлены; $revert_hint"
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    die "восстановление идёт дольше 2 ч — bin/dc logs postgres; api/worker/backup остановлены; $revert_hint"
  fi
  sleep 5
done
pg_log="$(dc logs --since "$since" postgres 2>/dev/null || true)"
grep -E 'recovery stopping|redo done at|last completed transaction was at log time|selected new timeline|archive recovery complete' \
  <<<"$pg_log" | tail -n 5 || true
LAST_COMMIT="$(sed -n 's/.*last completed transaction was at log time //p' <<<"$pg_log" | tail -n 1 | tr -d '\r')"
printf '%s\n' "$PITR_RESET_SQL" | psql_super_quiet
rm -rf "$DATA_DIR/pgdata/pitr_restore_wal"
pg_sync_role_passwords
if [ "$PITR_KIND" = time ]; then
  log "кластер восстановлен на $TARGET_UTC и переведён в рабочий режим (новая линия времени); прежний каталог — $PRE_PITR"
else
  SOURCE_NAME="$(basename "$BASE_FILE") → конец архива (последняя фиксация ${LAST_COMMIT:-не найдена в журнале}; сегмент $LAST_SEG)"
  log "кластер восстановлен до конца архива: последняя фиксация ${LAST_COMMIT:-не найдена в журнале postgres} (сегмент $LAST_SEG, зашифрован $LAST_AT UTC); новая линия времени; прежний каталог — $PRE_PITR"
fi
fi
owner="$(printf "SELECT tableowner FROM pg_tables WHERE schemaname = 'public' AND tablename = 'products';\n" | psql_super "$PGD")"
grant="$(printf "SELECT has_table_privilege('pos_app', 'public.products', 'SELECT');\n" | psql_super "$PGD")"
if [ "$owner" != "pos_migrate" ] || [ "$grant" != "t" ]; then
  die "в восстановленной базе нет владельцев или прав роли pos_app (копия старого формата, --no-owner --no-privileges).
api/worker/backup остановлены. Нужна ручная выдача прав (DevOps) или другая копия."
fi
# Схема очередей pgboss (07 DATA-012; docs/ci.md CI-KI-03 закрыт 2026-11-19): в копиях контуров, поднятых раньше, её
# объектами владеет pos_app (схему создавал pg-boss при старте api/worker). Владелец переносится на pos_migrate, права
# pos_app — только USAGE и DML (то же, что RUNBOOK §3.6); иначе migrate откажет с PGBOSS_FOREIGN_OWNER. Без схемы
# pgboss (копия до первого старта api) блок ничего не делает — схему поставит migrate шага 7.
psql_super "$PGD" >/dev/null <<'SQL'
DO $$
DECLARE r record;
BEGIN
  IF to_regnamespace('pgboss') IS NULL THEN RETURN; END IF;
  ALTER SCHEMA pgboss OWNER TO pos_migrate;
  -- таблицы и представления; индексы, TOAST и последовательности столбцов переходят вместе с таблицей
  FOR r IN SELECT c.oid::regclass AS o,
                  CASE c.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' WHEN 'S' THEN 'SEQUENCE'
                                 WHEN 'f' THEN 'FOREIGN TABLE' ELSE 'TABLE' END AS kind
             FROM pg_class c
            WHERE c.relnamespace = 'pgboss'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
              AND c.relowner <> 'pos_migrate'::regrole
              AND (c.relkind <> 'S' OR NOT EXISTS (SELECT 1 FROM pg_depend d
                               WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid
                                 AND d.refclassid = 'pg_class'::regclass AND d.deptype IN ('a', 'i')))
            ORDER BY c.relkind = 'S' LOOP
    EXECUTE format('ALTER %s %s OWNER TO pos_migrate', r.kind, r.o);
  END LOOP;
  FOR r IN SELECT p.oid::regprocedure AS o FROM pg_proc p
            WHERE p.pronamespace = 'pgboss'::regnamespace AND p.proowner <> 'pos_migrate'::regrole LOOP
    EXECUTE format('ALTER ROUTINE %s OWNER TO pos_migrate', r.o);
  END LOOP;
  -- перечисления, домены, диапазоны и отдельные составные типы (тип строки таблицы и массивы — вместе с владельцем)
  FOR r IN SELECT t.oid::regtype AS o, CASE t.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END AS kind
             FROM pg_type t LEFT JOIN pg_class c ON c.oid = t.typrelid
            WHERE t.typnamespace = 'pgboss'::regnamespace AND t.typowner <> 'pos_migrate'::regrole
              AND (t.typtype IN ('e', 'd', 'r') OR c.relkind = 'c') LOOP
    EXECUTE format('ALTER %s %s OWNER TO pos_migrate', r.kind, r.o);
  END LOOP;
  GRANT USAGE ON SCHEMA pgboss TO pos_app;
  GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA pgboss TO pos_app;
  GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA pgboss TO pos_app;
  GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pgboss TO pos_app;
  ALTER DEFAULT PRIVILEGES FOR ROLE pos_migrate IN SCHEMA pgboss GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO pos_app;
  ALTER DEFAULT PRIVILEGES FOR ROLE pos_migrate IN SCHEMA pgboss GRANT USAGE, SELECT ON SEQUENCES TO pos_app;
  ALTER DEFAULT PRIVILEGES FOR ROLE pos_migrate IN SCHEMA pgboss GRANT EXECUTE ON FUNCTIONS TO pos_app;
END $$;
SQL
dbcreate="$(printf "SELECT has_database_privilege('pos_app', current_database(), 'CREATE');\n" | psql_super "$PGD")"
if [ "$dbcreate" != "f" ]; then
  die "у роли pos_app есть право CREATE на базу $PGD (отклонение 07 DATA-012). api/worker/backup остановлены.
Снимите его под суперпользователем (REVOKE CREATE ON DATABASE … FROM pos_app) и повторите с шага migrate (RUNBOOK §3.6)."
fi
printf 'ANALYZE;\n' | psql_super "$PGD" >/dev/null
log "база восстановлена; последняя миграция в копии: $(printf 'SELECT max(version) FROM pos_meta.schema_migrations;\n' | psql_super "$PGD")"

log "7/8 Миграции (если образ новее копии)"
dc run --rm migrate || die "migrate завершился с ошибкой после восстановления — bin/dc logs migrate; api/worker не запущены"

log "8/8 Запуск сервисов"
dc up -d
ok=0
wait_healthy api 300 || ok=1
wait_healthy worker 180 || ok=1
ready="$(api_ready_status)"
log "/health/ready: $ready"
case "$ready" in ok|degraded) ;; *) ok=1 ;; esac
install -d -m 700 -o "$OPS_USER" -g "$OPS_USER" "$STATE_DIR"
printf '%s restore-db %s %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$MODE" "$SOURCE_NAME" "$([ "$ok" -eq 0 ] && echo ok || echo failed)" \
  >> "$STATE_DIR/releases.log"
chmod 600 "$STATE_DIR/releases.log"
[ "$ok" -eq 0 ] || die "сервисы после восстановления не готовы — bin/dc logs --tail 200 api worker"
if [ "$MODE" = pitr ]; then
  # Новая линия времени: свежая базовая копия сразу (восстановление на моменты после этого — без старой копии).
  dc run --rm -T backup base >/dev/null 2>&1 \
    && log "новая базовая копия PITR создана" \
    || warn "новая базовая копия не создана — sudo $PROD_DIR/bin/dc run --rm backup base (RUNBOOK §4.8)"
fi
cat <<EOF

База восстановлена ($MODE: $SOURCE_NAME); сервисы запущены. Дальше (16 §8.5 п. 7–9, RUNBOOK §4.5, §4.8):
  - предупредите кассиров: заказы и корзины после момента восстановления потеряны; черновики на устройствах не
    переотправлять без проверки (смена эпохи данных server_epoch, 16 §8.5 п. 7, в текущей версии сервера не
    реализована — приложения о восстановлении не узнают; known_issues OPS-KI-04);
  - когда 1С подключена — ручной прогон синхронизации и сверка onec_outbox за окно потери с 1С;
  - prod-smoke без мутаций (16 §10.9) и запись в журнале эксплуатации: дата, копия, фактическое время, потери.
EOF
if [ "$MODE" = pitr ]; then
  cat <<EOF
  - прежний каталог данных: $PRE_PITR — удалить после проверки (sudo rm -rf $PRE_PITR), он занимает место на диске базы.
EOF
  if [ "$PITR_KIND" = latest ]; then
    cat <<EOF
  - восстановлено всё, что успело в архив: последняя фиксация ${LAST_COMMIT:-не найдена в журнале postgres}; окно потерь для
    кассиров и журнала эксплуатации — от неё до момента сбоя.
EOF
  fi
fi
echo "Ключ age уберите с сервера."
