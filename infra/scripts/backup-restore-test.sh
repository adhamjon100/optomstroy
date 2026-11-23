#!/usr/bin/env bash
# Проверка восстановления резервной копии (restore-drill; 16 §8.1 «Проверка восстановления», §8.5 абзац «Ежемесячная
# проверка»; 11 SEC-110; RUNBOOK §4.4). Рабочую БД НЕ трогает: зашифрованный дамп восстанавливается во ВРЕМЕННЫЙ
# PostgreSQL во временной внутренней сети Docker (без опубликованных портов), затем всё временное удаляется.
#
# Запускает держатель приватного ключа age (на сервер ключ приносится на время проверки — со съёмного носителя;
# скрипт не копирует ключ на диск: файл монтируется в одноразовый контейнер только для чтения, OPS-004):
#   sudo /opt/optomstroy/prod/bin/backup-restore-test.sh --identity /media/<носитель>/optomstroy-backup.key
#        [--dump /srv/optomstroy/prod/backups/[monthly/]<файл>.dump.age] [--ping-url-file <файл с URL Healthchecks>] [--keep]
# Можно запускать и на машине восстановления с Docker: --dump <файл> --backup-image optomstroy/backup:<тег>.
#
# Шаги: временная сеть (internal) → временный postgres той же версии, что в рабочем контуре → расшифровка age и
# pg_restore потоком (незашифрованный дамп на диск не пишется) → проверки: pg_restore без ошибок, журнал миграций
# pos_meta.schema_migrations не пуст, ключевые таблицы есть, расширения pg_trgm/unaccent/pgcrypto есть → вывод
# числа строк ключевых таблиц (сверка с контрольными значениями — запись в журнале эксплуатации) → уборка.
# Шаг PITR (на сервере контура при BACKUP_PITR=on или с --pitr; RUNBOOK §4.8): в отдельной базе учений
# optomstroy_pitr_drill кластера контура (рабочая база не меняется) — метка A, момент T, метка B → закрытие сегмента WAL
# и ожидание его в архиве → базовая копия, закончившаяся раньше T, и архив WAL восстанавливаются во ВРЕМЕННЫЙ том и
# временный PostgreSQL без сети и без архивации (archive_mode=off — в архив контура он не пишет) с теми же
# настройками восстановления, что restore-db.sh --to-time → promote → метка A есть, B нет, линия времени новая.
# С --pitr-latest — настройки restore-db.sh --to-latest (весь архив, без цели): метки A и B обе есть, линия новая.
# Коды выхода: 0 — копия восстанавливается; 1 — проверка не пройдена или ошибка; 2 — неверные параметры.
set -euo pipefail
set +x
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
  cat <<'EOF'
Параметры:
  --identity FILE       приватный ключ age (обязателен; на сервере не хранится)
  --dump FILE           зашифрованный дамп *.dump.age (по умолчанию — самый новый в /srv/optomstroy/<контур>/backups)
  --backup-image IMG    образ с age и pg_restore (по умолчанию optomstroy/backup:<BACKUP_TAG из .env>)
  --pg-image IMG        образ временного PostgreSQL (по умолчанию — из compose.prod.yml, иначе postgres:17.10)
  --ping-url-file FILE  файл с URL проверки Healthchecks «restore-drill» (успех — ping, ошибка — /fail)
  --keep                не удалять временный PostgreSQL (для ручного разбора; удалить — команда в выводе)
  --pitr | --no-pitr    шаг PITR: по умолчанию — на сервере контура при BACKUP_PITR=on (нужны базовая копия и
                        работающий сервис backup); --no-pitr — пропустить, --pitr — обязательно
  --pitr-latest         шаг PITR обязательно и до конца архива (как restore-db.sh --to-latest): A и B — обе есть
  --prod-dir DIR        каталог проекта (по умолчанию — каталог над bin/, иначе /opt/optomstroy/prod)
  -h, --help            эта справка
EOF
}

IDENTITY="" DUMP="" BACKUP_IMAGE="" PG_IMAGE="" PING_FILE="" KEEP=0 PITR_MODE=auto PITR_KIND=time
while [ $# -gt 0 ]; do
  opt="$1" val=""
  case "$opt" in
    --identity|--dump|--backup-image|--pg-image|--ping-url-file|--prod-dir)
      [ $# -ge 2 ] || { printf 'нет значения для %s\n' "$opt" >&2; exit 2; }
      val="$2"; shift 2 ;;
    *) shift ;;
  esac
  case "$opt" in
    --identity) IDENTITY="$val" ;;
    --dump) DUMP="$val" ;;
    --backup-image) BACKUP_IMAGE="$val" ;;
    --pg-image) PG_IMAGE="$val" ;;
    --ping-url-file) PING_FILE="$val" ;;
    --prod-dir) PROD_DIR="$val" ;;
    --keep) KEEP=1 ;;
    --pitr) PITR_MODE=on ;;
    --pitr-latest) PITR_MODE=on; PITR_KIND=latest ;;
    --no-pitr) PITR_MODE=off ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'неизвестный параметр: %s (см. --help)\n' "$opt" >&2; exit 2 ;;
  esac
done

need_root
need_cmd awk sed date
check_docker
resolve_dirs "$HERE"

ping_hc() { # $1 — "" (успех) или "/fail"
  local url
  if [ -n "$PING_FILE" ] && [ -s "$PING_FILE" ]; then
    url="$(tr -d '\r\n' < "$PING_FILE")"
    if command -v curl >/dev/null 2>&1; then
      curl -fsS -m 10 -o /dev/null "${url}$1" || warn "Healthchecks: ping не доставлен"
    elif command -v wget >/dev/null 2>&1; then
      wget -q -T 10 -O /dev/null "${url}$1" || warn "Healthchecks: ping не доставлен"
    fi
  fi
}

fail() { ping_hc /fail; die "$*"; }

[ -n "$IDENTITY" ] || { usage >&2; exit 2; }
[ -f "$IDENTITY" ] && [ -s "$IDENTITY" ] || fail "--identity: файл ключа не найден или пуст"
IDENTITY="$(cd "$(dirname "$IDENTITY")" && pwd)/$(basename "$IDENTITY")"
case "$IDENTITY" in
  "$PROD_DIR"/*|"$DATA_DIR"/*)
    warn "ключ age лежит в каталоге контура — приватный ключ на сервере не хранится (OPS-004): после проверки уберите его" ;;
esac

if [ -z "$DUMP" ]; then
  DUMP="$(ls -1t "$DATA_DIR/backups"/*.dump.age 2>/dev/null | head -n 1 || true)"
  [ -n "$DUMP" ] || fail "в $DATA_DIR/backups нет копий *.dump.age — укажите --dump"
fi
[ -f "$DUMP" ] && [ -s "$DUMP" ] || fail "--dump: файл не найден или пуст"
DUMP="$(cd "$(dirname "$DUMP")" && pwd)/$(basename "$DUMP")"

if [ -z "$BACKUP_IMAGE" ]; then
  [ -f "$ENV_FILE" ] || fail "нет $ENV_FILE — укажите --backup-image optomstroy/backup:<тег>"
  BACKUP_IMAGE="optomstroy/backup:$(env_get "$ENV_FILE" BACKUP_TAG)"
fi
image_exists "$BACKUP_IMAGE" || fail "образа $BACKUP_IMAGE нет (docker load или сборка infra/docker/backup)"
if [ -z "$PG_IMAGE" ]; then
  PG_IMAGE="$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(postgres:[0-9][0-9.]*\).*/\1/p' "$PROD_DIR/compose.prod.yml" 2>/dev/null | head -n 1)"
  PG_IMAGE="${PG_IMAGE:-postgres:17.10}"
fi

RUN_ID="$(date +%Y%m%d%H%M%S)-$$"
NET="optomstroy_restore_check_$RUN_ID"
PGC="optomstroy-restore-check-$RUN_ID"
DB="restore_check"
PITR_C="optomstroy-pitr-check-$RUN_ID"
PITR_VOL="optomstroy_pitr_check_$RUN_ID"
PITR_LIST=""
cleanup() {
  [ -z "$PITR_LIST" ] || rm -f "$PITR_LIST"
  if [ "$KEEP" -eq 1 ]; then
    log "временный PostgreSQL оставлен: docker exec -it $PGC psql -U postgres -d $DB"
    log "удалить: docker rm -f -v $PGC $PITR_C; docker network rm $NET; docker volume rm $PITR_VOL"
    return 0
  fi
  docker rm -f -v "$PGC" "$PITR_C" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker volume rm "$PITR_VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 1' INT TERM

started="$(date +%s)"
log "копия: $(basename "$DUMP") ($(wc -c < "$DUMP") байт); образ postgres: $PG_IMAGE; образ backup: $BACKUP_IMAGE"

docker network create --internal "$NET" >/dev/null
# Временный кластер: доверие без пароля допустимо — сеть internal, портов нет, контейнер удаляется после проверки.
docker run -d --name "$PGC" --network "$NET" --network-alias restore-pg \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -e POSTGRES_INITDB_ARGS="--encoding=UTF8 --locale=C.UTF-8" \
  --shm-size 256m --security-opt no-new-privileges:true \
  "$PG_IMAGE" -c shared_preload_libraries=pg_stat_statements -c fsync=off -c full_page_writes=off \
  >/dev/null

deadline=$(( $(date +%s) + 180 ))
until docker exec "$PGC" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; do
  [ "$(date +%s)" -lt "$deadline" ] || fail "временный PostgreSQL не запустился за 180 с (docker logs $PGC)"
  sleep 2
done

pg_tmp() { docker exec -i "$PGC" psql -v ON_ERROR_STOP=1 --no-psqlrc -qAt -U postgres "$@"; }
pg_tmp -d postgres -c "CREATE DATABASE $DB TEMPLATE template0 ENCODING 'UTF8'" >/dev/null
# Роли рабочего контура (07 DATA-012) — без входа: дамп содержит владельцев (pos_migrate) и права (GRANT роли
# pos_app и др.), восстановление проверяется в том же виде, в каком пойдёт в рабочую БД (RUNBOOK §4.5).
pg_tmp -d postgres >/dev/null <<'SQL'
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_migrate') THEN CREATE ROLE pos_migrate NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_app') THEN CREATE ROLE pos_app NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_readonly') THEN CREATE ROLE pos_readonly NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_backup') THEN CREATE ROLE pos_backup NOLOGIN; END IF;
END $$;
SQL

log "расшифровка и восстановление потоком (age -d | pg_restore)"
restore_log="$(mktemp)"
rc=0
# Одноразовый контейнер образа backup: только чтение, без возможностей кроме чтения файлов (ключ и дамп могут
# принадлежать другим пользователям), во временной internal-сети. Ключ — bind-mount :ro, на диск не копируется.
docker run --rm --network "$NET" --user 0:0 --read-only --tmpfs /tmp \
  --cap-drop ALL --cap-add DAC_READ_SEARCH --security-opt no-new-privileges:true \
  -v "$IDENTITY:/run/restore/identity:ro" -v "$DUMP:/run/restore/dump.age:ro" \
  --entrypoint /bin/sh "$BACKUP_IMAGE" -c '
    set -eu
    set -o pipefail
    age -d -i /run/restore/identity /run/restore/dump.age \
      | pg_restore -h restore-pg -U postgres -d restore_check
  ' > "$restore_log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  warn "pg_restore/age завершились с кодом $rc; последние строки журнала восстановления:"
  tail -n 20 "$restore_log" >&2 || true
  rm -f "$restore_log"
  fail "копия НЕ восстанавливается (неверный ключ, повреждённый файл или ошибки восстановления)"
fi
rm -f "$restore_log"

log "проверки восстановленной базы"
last_mig="$(pg_tmp -d "$DB" -c "SELECT max(version) FROM pos_meta.schema_migrations" 2>/dev/null || true)"
[ -n "$last_mig" ] || fail "журнал миграций pos_meta.schema_migrations пуст или отсутствует"
for ext in pg_trgm unaccent pgcrypto; do
  [ "$(pg_tmp -d "$DB" -c "SELECT count(*) FROM pg_extension WHERE extname = '$ext'")" = "1" ] \
    || fail "в восстановленной базе нет расширения $ext"
done
printf '%-20s %s\n' "таблица" "строк"
for t in $KEY_TABLES; do
  exists="$(pg_tmp -d "$DB" -c "SELECT to_regclass('public.$t') IS NOT NULL")"
  [ "$exists" = "t" ] || fail "в восстановленной базе нет таблицы $t"
  printf '%-20s %s\n' "$t" "$(pg_tmp -d "$DB" -c "SELECT count(*) FROM public.$t")"
done
tables="$(pg_tmp -d "$DB" -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'")"
owner="$(pg_tmp -d "$DB" -c "SELECT tableowner FROM pg_tables WHERE schemaname = 'public' AND tablename = 'products'")"
grant="$(pg_tmp -d "$DB" -c "SELECT has_table_privilege('pos_app', 'public.products', 'SELECT')")"
if [ "$owner" != "pos_migrate" ] || [ "$grant" != "t" ]; then
  warn "в копии нет владельцев или прав ролей (копия сделана с --no-owner --no-privileges, до 2026-11-18): для рабочей БД"
  warn "после восстановления понадобится выдача прав вручную — restore-db.sh такую копию не примет (RUNBOOK §4.5)"
fi
elapsed=$(( $(date +%s) - started ))

# ---------- Шаг PITR: восстановление на момент времени (RUNBOOK §4.8) ----------
run_pitr=0
case "$PITR_MODE" in
  on) run_pitr=1 ;;
  auto) if [ -f "$ENV_FILE" ] && [ "$(env_get "$ENV_FILE" BACKUP_PITR)" != off ]; then run_pitr=1; fi ;;
esac
pitr_summary="пропущен"
if [ "$run_pitr" -eq 1 ]; then
  pitr_started="$(date +%s)"
  [ -f "$ENV_FILE" ] || fail "PITR: нужен установленный контур ($ENV_FILE)"
  check_secrets
  compose_init
  [ "$(container_state postgres)" = healthy ] || fail "PITR: postgres контура не healthy — bin/dc ps"
  case "$(container_state backup)" in
    healthy|running|starting) ;;
    *) fail "PITR: сервис backup не запущен — архив WAL не пополняется (bin/dc up -d backup)" ;;
  esac
  PGU="$(env_get "$ENV_FILE" POSTGRES_USER)"
  sysid="$(printf 'SELECT system_identifier FROM pg_control_system();\n' | psql_super_at postgres)"
  case "$sysid" in ''|*[!0-9]*) fail "PITR: system_identifier кластера не получен" ;; esac
  WAL_DIR="$DATA_DIR/backups/pitr/$sysid/wal"
  log "PITR: метки в базе учений $PITR_DRILL_DB (рабочая база не меняется)"
  if [ "$(printf "SELECT count(*) FROM pg_database WHERE datname = '%s';\n" "$PITR_DRILL_DB" | psql_super_at postgres)" != 1 ]; then
    printf 'CREATE DATABASE %s;\n' "$PITR_DRILL_DB" | psql_super_at postgres >/dev/null
  fi
  printf "CREATE TABLE IF NOT EXISTS drill_marker (id text PRIMARY KEY, at timestamptz NOT NULL DEFAULT clock_timestamp());\nDELETE FROM drill_marker WHERE at < now() - interval '90 days';\n" \
    | psql_super_at "$PITR_DRILL_DB" >/dev/null
  mark_a="pitr-$RUN_ID-a"
  mark_b="pitr-$RUN_ID-b"
  printf "INSERT INTO drill_marker (id) VALUES ('%s');\n" "$mark_a" | psql_super_at "$PITR_DRILL_DB" >/dev/null
  sleep 2
  target="$(printf "SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"');\n" | psql_super_at postgres)"
  sleep 2
  printf "INSERT INTO drill_marker (id) VALUES ('%s');\n" "$mark_b" | psql_super_at "$PITR_DRILL_DB" >/dev/null
  seg="$(printf 'SELECT pg_walfile_name(pg_switch_wal());\n' | psql_super_at postgres)"
  log "PITR: момент $target; ожидание сегмента $seg в архиве"
  deadline=$(( $(date +%s) + 180 ))
  until [ -f "$WAL_DIR/$seg.gz.age" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "PITR: сегмент $seg не попал в архив за 180 с (архивация WAL или сервис backup; RUNBOOK §6.3)"
    sleep 5
  done
  info="$(pitr_pick_base "$DATA_DIR/backups/pitr" "$target" "$sysid")"
  [ -n "$info" ] || fail "PITR: нет базовой копии кластера, закончившейся раньше $target (sudo $PROD_DIR/bin/dc run --rm backup base)"
  PITR_LIST="$(mktemp)"
  chmod 644 "$PITR_LIST"
  if [ "$PITR_KIND" = latest ]; then
    pitr_wal_list "$WAL_DIR" "$(pitr_info_get "$info" start_wal)" $(( $(date +%s) + 86400 )) > "$PITR_LIST"
    gap="$(pitr_wal_gaps "$PITR_LIST")" || fail "PITR: в архиве WAL дыра ($gap) — восстановление до конца архива остановилось бы на ней (RUNBOOK §4.8)"
    pitr_conf="$(pitr_recovery_conf latest)"
    want="1/1"
  else
    pitr_wal_list "$WAL_DIR" "$(pitr_info_get "$info" start_wal)" $(( $(date -u -d "$target" +%s) + 3600 )) > "$PITR_LIST"
    pitr_conf="$(pitr_recovery_conf "$target")"
    want="1/0"
  fi
  segs="$(grep -c -v '\.history$' "$PITR_LIST" || true)"
  # Размер базовой копии до сжатия — из .info (base_bytes); в копиях без него — расшифровка и распаковка потоком.
  need="$(pitr_bytes_needed "$info" "${segs:-0}")" \
    || need="$(pitr_bytes_needed "$info" "${segs:-0}" \
                 "$(pitr_base_raw_bytes "$IDENTITY" "$(dirname "$info")/$(pitr_info_get "$info" file)" "$BACKUP_IMAGE")")" \
    || fail "PITR: базовая копия $(pitr_info_get "$info" file) не расшифровывается (ключ age) — размер не оценить"
  droot="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
  avail="$(df -P -B1 "$droot" | awk 'NR == 2 { print $4 }')"
  [ "${avail:-0}" -gt "$need" ] || fail "PITR: в $droot свободно $((avail / 1048576)) МиБ, нужно около $((need / 1048576)) МиБ"
  log "PITR: базовая копия $(pitr_info_get "$info" file), сегментов WAL: $segs → временный том $PITR_VOL"
  docker volume create "$PITR_VOL" >/dev/null
  pitr_restore_into "$IDENTITY" "$info" "$PITR_LIST" "$PITR_VOL:/var/lib/postgresql/data" /var/lib/postgresql/data/pgdata \
    "$pitr_conf" "$PG_IMAGE" "$BACKUP_IMAGE"
  # Без сети и без архивации: восстановленный кластер с тем же system_identifier не пишет в архив контура.
  docker run -d --name "$PITR_C" --network none --user 999:999 --shm-size 256m --security-opt no-new-privileges:true \
    -v "$PITR_VOL:/var/lib/postgresql/data" -e PGDATA=/var/lib/postgresql/data/pgdata "$PG_IMAGE" \
    postgres -c archive_mode=off -c wal_level=replica -c shared_preload_libraries=pg_stat_statements -c timezone=UTC \
      -c fsync=off >/dev/null
  deadline=$(( $(date +%s) + 900 ))
  while :; do
    r="$(docker exec "$PITR_C" psql -X -qAt -U "$PGU" -d postgres -c 'SELECT pg_is_in_recovery()' 2>/dev/null || true)"
    [ "$r" = f ] && break
    if [ "$(docker inspect --format '{{.State.Status}}' "$PITR_C" 2>/dev/null)" != running ]; then
      docker logs --tail 30 "$PITR_C" >&2 || true
      fail "PITR: временный PostgreSQL остановился во время восстановления (журнал выше)"
    fi
    [ "$(date +%s)" -lt "$deadline" ] || fail "PITR: восстановление не закончилось за 15 минут (docker logs $PITR_C)"
    sleep 3
  done
  got="$(docker exec "$PITR_C" psql -X -qAt -U "$PGU" -d "$PITR_DRILL_DB" -c \
    "SELECT (SELECT count(*) FROM drill_marker WHERE id = '$mark_a') || '/' || (SELECT count(*) FROM drill_marker WHERE id = '$mark_b')")"
  if [ "$want" = 1/1 ]; then
    [ "$got" = "1/1" ] || fail "PITR (до конца архива): ожидалось «метки A и B есть» (1/1), получено ${got:-пусто}"
  else
    [ "$got" = "1/0" ] || fail "PITR: ожидалось «метка A есть, метки B нет» (1/0), получено ${got:-пусто}"
  fi
  tl_base="$(pitr_info_get "$info" start_wal | cut -c1-8)"
  tl_now="$(docker exec "$PITR_C" psql -X -qAt -U "$PGU" -d postgres -c 'SELECT substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8)')"
  [ -n "$tl_now" ] && [ "$tl_now" \> "$tl_base" ] || fail "PITR: после promote линия времени не сменилась ($tl_base → ${tl_now:-?})"
  if [ "$want" = 1/1 ]; then
    last_tx="$(docker logs "$PITR_C" 2>&1 | sed -n 's/.*last completed transaction was at log time //p' | tail -n 1 || true)"
    pitr_summary="ok: до конца архива (последняя фиксация ${last_tx:-?}), A и B есть, линия времени $tl_base → $tl_now, $(( $(date +%s) - pitr_started )) с"
    target="latest"
  else
    pitr_summary="ok: момент $target, A есть, B нет, линия времени $tl_base → $tl_now, $(( $(date +%s) - pitr_started )) с"
  fi
  log "PITR: $pitr_summary"
  if [ -d "$STATE_DIR" ]; then
    printf '%s pitr-test %s target=%s ok timeline=%s->%s seconds=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      "$(pitr_info_get "$info" file)" "$target" "$tl_base" "$tl_now" "$(( $(date +%s) - pitr_started ))" >> "$STATE_DIR/restore-tests.log"
  fi
fi

ping_hc ""
if [ -d "$STATE_DIR" ]; then
  printf '%s restore-test %s ok migrations=%s tables=%s seconds=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "$(basename "$DUMP")" "$last_mig" "$tables" "$elapsed" >> "$STATE_DIR/restore-tests.log"
  chmod 600 "$STATE_DIR/restore-tests.log"
fi
cat <<EOF

ПРОВЕРКА ПРОЙДЕНА: копия $(basename "$DUMP") расшифрована и восстановлена во временный PostgreSQL.
Последняя миграция: $last_mig; таблиц в public: $tables; время: ${elapsed} с (оценка RTO восстановления БД).
Восстановление на момент времени (PITR): $pitr_summary.
Запишите в журнал эксплуатации: дата, файл, числа строк выше, время, кто выполнял (16 §8.5 п. 9).
Ключ age уберите с сервера (съёмный носитель — извлечь).
EOF
