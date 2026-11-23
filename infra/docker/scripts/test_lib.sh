#!/usr/bin/env bash
# Самопроверка функций комплекта без Docker и без root (регрессия находок ревью комплекта 2026-11-18):
#   infra/scripts/lib.sh   — check_docker (плагин Compose 2.x и новее, в том числе 5.x; v1 и пусто — отказ),
#                            разбор .env как у Compose (`X=   # c` → «# c»), env_set/env_normalize_empty/env_apply_lines,
#                            наборы секретов 1С (HTTP-сервис — три файла, OData — пара; частичный набор — отказ),
#                            порядок файлов compose_init (тестовая копия — compose.staging.yml последним);
#   infra/docker/backup/backup.sh — месячные копии и сроки хранения, корень BACKUP_REMOTE, метки архива caddy_data,
#                            расписание по умолчанию после ночных заданий синхронизации; непрерывная копия WAL: спул → архив со
#                            сверкой SHA-256 и system_identifier на каждом проходе, выгрузка WAL с последней успешной
#                            (догон после перебоя), замок выгрузки, base_bytes базовой копии, очистка, healthcheck;
#   PITR в lib.sh — выбор кластера и копии, дыры в WAL, настройки --to-time/--to-latest, место; тестовая копия — замены
#                            test.env.example для новых имён; откат — предупреждение о спуле;
#   сервер вне магазина (RUNBOOK §11) — ip_in_cidr, url_hostname, host_ipv4, wg_peer_handshake_age (заглушка wg, ключи
#                            не печатаются), in_time_window (заглушка date), сигнал WG_HANDSHAKE_STALE в любое время
#                            (не в ночном окне), host-net-check.sh только читает и разбирает `ufw status` с LC_ALL=C; копии и база
#                            на одном физическом диске — path_disks/common_disks/backups_disk_gate (заглушки findmnt,
#                            lsblk, stat; ошибка без --allow-same-disk; RUNBOOK §2.2, Q-374).
# Запуск: bash infra/docker/scripts/test_lib.sh   (Linux, macOS, Git Bash; нужны GNU touch -d и find)
# Код выхода: 0 — все проверки прошли; 1 — есть отказы (строки FAIL).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fails=0
ok() { pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
expect_eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: получено «$2», ожидалось «$3»"; fi; }

# shellcheck source=../../scripts/lib.sh
. "$ROOT/infra/scripts/lib.sh"
log() { :; }
warn() { :; }

# ---------- check_docker: минимальная версия плагина Compose (находка: 5.x отвергался) ----------
STUB_VERSION=""
docker() {
  case "${1:-} ${2:-}" in
    "info "*) return 0 ;;
    "compose version") printf '%s\n' "$STUB_VERSION"; return 0 ;;
  esac
  return 1
}
for v in 2.29.1 v2.40.3 5.8.0 v5.8.0; do
  STUB_VERSION="$v"
  if ( check_docker ) >/dev/null 2>&1; then ok; else bad "check_docker отклонил Compose $v"; fi
done
for v in 1.29.2 v1.27.4 "" abc; do
  STUB_VERSION="$v"
  if ( check_docker ) >/dev/null 2>&1; then bad "check_docker принял Compose «$v»"; else ok; fi
done
unset -f docker

# ---------- .env: разбор как у Compose, запись, исправление пустых строк с комментарием ----------
f="$TMP/env"
cat > "$f" <<'EOF'
A=
B=   # комментарий
C=value # комментарий
D="quoted value"   # c
E='single'
F=v#не-комментарий
G=  spaced
EOF
expect_eq "env_get A" "$(env_get "$f" A)" ""
expect_eq "env_get B (как Compose)" "$(env_get "$f" B)" "# комментарий"
expect_eq "env_get C" "$(env_get "$f" C)" "value"
expect_eq "env_get D" "$(env_get "$f" D)" "quoted value"
expect_eq "env_get E" "$(env_get "$f" E)" "single"
expect_eq "env_get F" "$(env_get "$f" F)" "v#не-комментарий"
expect_eq "env_get G" "$(env_get "$f" G)" "spaced"
cp "$f" "$TMP/env2"
env_set "$TMP/env2" C ""
expect_eq "env_set пустого убирает комментарий" "$(grep '^C=' "$TMP/env2")" "C="
env_set "$TMP/env2" B x
expect_eq "env_set непустого сохраняет комментарий" "$(grep '^B=' "$TMP/env2")" "B=x   # комментарий"
expect_eq "env_get после env_set" "$(env_get "$TMP/env2" B)" "x"
env_set "$TMP/env2" NEW abc
expect_eq "env_set добавляет строку" "$(grep '^NEW=' "$TMP/env2")" "NEW=abc"
cp "$f" "$TMP/env3"
env_normalize_empty "$TMP/env3"
expect_eq "env_normalize_empty" "$(grep '^B=' "$TMP/env3")" "B="
expect_eq "env_normalize_empty не трогает C" "$(grep '^C=' "$TMP/env3")" "C=value # комментарий"
expect_eq "env_normalize_empty — список" "$ENV_NORMALIZED" " B"
printf 'C="a b"\nA=1\n# Z=комментарий\nZ=9\n' > "$TMP/over"
cp "$f" "$TMP/env4"
env_apply_lines "$TMP/over" "$TMP/env4"
expect_eq "env_apply_lines C" "$(env_get "$TMP/env4" C)" "a b"
expect_eq "env_apply_lines A" "$(env_get "$TMP/env4" A)" "1"
expect_eq "env_apply_lines Z (новая)" "$(env_get "$TMP/env4" Z)" "9"
expect_eq "env_apply_lines число строк A" "$(grep -c '^A=' "$TMP/env4")" "1"
printf 'APP_ENV=prod\nAUTH_OTP_TEST_PHONES=   # пусто\n' > "$TMP/env5"
CONTOUR=prod
contour_init prod
if msg="$( ( validate_env "$TMP/env5" ) 2>&1 )"; then
  bad "validate_env пропустил «ИМЯ=   # комментарий»"
else
  case "$msg" in *AUTH_OTP_TEST_PHONES*) ok ;; *) bad "validate_env: нет имени переменной в сообщении: $msg" ;; esac
fi

# ---------- секреты 1С: HTTP-сервис (3) и OData (2) — каждый целиком или ничего ----------
PROD_DIR="$TMP/prod"
SECRETS_DIR="$PROD_DIR/secrets"   # check-secrets: allow (путь каталога)
mkdir -p "$SECRETS_DIR"
for s in $BASE_SECRETS; do printf 'x' > "$SECRETS_DIR/$s"; done
: > "$SECRETS_DIR/rclone.conf"
contour_init prod
args() { compose_init; printf '%s\n' "${COMPOSE_ARGS[@]}" | grep '\.yml$' | sed 's#.*/##' | tr '\n' ' '; }
if ( check_secrets ) >/dev/null 2>&1; then ok; else bad "check_secrets: без 1С должен проходить"; fi
expect_eq "compose_init без 1С" "$(args)" "compose.prod.yml "
for s in $ONEC_HS_SECRETS; do printf 'x' > "$SECRETS_DIR/$s"; done
if ( check_secrets ) >/dev/null 2>&1; then ok; else bad "check_secrets: полный набор HTTP-сервиса"; fi
expect_eq "compose_init HTTP-сервис" "$(args)" "compose.prod.yml compose.prod.onec.yml "
rm "$SECRETS_DIR/onec_hs_token"
if ( check_secrets ) >/dev/null 2>&1; then bad "check_secrets пропустил 2 из 3 секретов HTTP-сервиса"; else ok; fi
if ( compose_init ) >/dev/null 2>&1; then bad "compose_init пропустил частичный набор HTTP-сервиса"; else ok; fi
rm "$SECRETS_DIR/onec_hs_user" "$SECRETS_DIR/onec_hs_password"
for s in $ONEC_ODATA_SECRETS; do printf 'x' > "$SECRETS_DIR/$s"; done
if ( check_secrets ) >/dev/null 2>&1; then ok; else bad "check_secrets: только пара OData (odata_only)"; fi
expect_eq "compose_init только OData" "$(args)" "compose.prod.yml compose.prod.onec-odata.yml "
rm "$SECRETS_DIR/onec_password"
if ( check_secrets ) >/dev/null 2>&1; then bad "check_secrets пропустил половину пары OData"; else ok; fi
rm "$SECRETS_DIR/onec_user"
: > "$SECRETS_DIR/smspro_login"
if ( check_secrets ) >/dev/null 2>&1; then bad "check_secrets: пустой smspro_login в рабочем контуре"; else ok; fi
contour_init test
if ( check_secrets ) >/dev/null 2>&1; then ok; else bad "check_secrets: пустой smspro_login в тестовой копии допустим"; fi
printf 'x' > "$SECRETS_DIR/healthchecks_url"
expect_eq "compose_init тестовой копии (staging последним)" "$(args)" "compose.prod.yml compose.prod.healthchecks.yml compose.staging.yml "
expect_eq "имя контейнера api теста" "$API_CONTAINER" "optomstroy-test-api-1"
contour_init prod
expect_eq "имя контейнера api рабочего" "$API_CONTAINER" "optomstroy-prod-api-1"

# ---------- backup.sh: месячные копии, сроки хранения, корень хранилища ----------
(
  B="$TMP/backups"
  mkdir -p "$B/caddy_data"
  export BACKUPS_DIR="$B" BACKUP_SH_LIB=1
  # shellcheck source=../backup/backup.sh
  . "$ROOT/infra/docker/backup/backup.sh"
  set +e
  log() { :; }
  mk() { : > "$B/$1"; touch -d "$2 days ago" "$B/$1"; }
  mk db_20260731T233000Z.dump.age 125
  mk db_20260815T233000Z.dump.age 100
  mk db_20260930T233000Z.dump.age 50
  mk db_20261002T233000Z.dump.age 48
  mk db_20261101T233000Z.dump.age 18
  mk db_20261118T233000Z.dump.age 1
  for d in db_20260731T233000Z db_20260815T233000Z db_20260930T233000Z db_20261002T233000Z db_20261101T233000Z db_20261118T233000Z; do
    monthly_link "$B/$d.dump.age"
  done
  got="$(cd "$B/monthly" && ls | tr '\n' ' ')"
  [ "$got" = "db_20260731T233000Z.dump.age db_20260815T233000Z.dump.age db_20260930T233000Z.dump.age db_20261002T233000Z.dump.age db_20261101T233000Z.dump.age " ] \
    || echo "FAIL monthly_link (первая копия каждого месяца UTC): $got"
  mk globals_20260801T000000Z.sql.age 95
  mk globals_20261101T000000Z.sql.age 10
  : > "$B/caddy_data/caddy_data_20261001T000000Z.tar.age"; touch -d "40 days ago" "$B/caddy_data/caddy_data_20261001T000000Z.tar.age"
  : > "$B/caddy_data/caddy_data_20261115T000000Z.tar.age"
  mk old.dump.age.partial 2
  mk new.dump.age.partial 0
  rotate_local 30
  got="$(cd "$B" && ls *.age *.partial 2>/dev/null | tr '\n' ' ')"
  [ "$got" = "db_20261101T233000Z.dump.age db_20261118T233000Z.dump.age globals_20261101T000000Z.sql.age new.dump.age.partial " ] \
    || echo "FAIL rotate_local (суточные, globals, partial): $got"
  got="$(cd "$B/monthly" && ls | tr '\n' ' ')"
  [ "$got" = "db_20260815T233000Z.dump.age db_20260930T233000Z.dump.age db_20261002T233000Z.dump.age db_20261101T233000Z.dump.age " ] \
    || echo "FAIL rotate_local (месячные: срок 30 + 93 сут): $got"
  got="$(cd "$B/caddy_data" && ls | tr '\n' ' ')"
  [ "$got" = "caddy_data_20261115T000000Z.tar.age " ] || echo "FAIL rotate_local (caddy_data 30 сут): $got"
  # Выгрузка вне сервера — весь каталог: копия, не выгруженная в ночь сбоя, уходит следующей ночью; .offsite_ok — только
  # после полностью успешной выгрузки (имитация rclone: копирует *.age верхнего уровня, если хранилище «доступно»).
  R="$TMP/remote"; mkdir -p "$R/db"; rm -f "$B/.offsite_ok"; MEDIA_SRC="$TMP/no-media"
  rclone() { [ "$REMOTE_UP" = 1 ] || return 1; case "$3" in */db) cp -p "$2"/*.age "$R/db/" ;; esac; return 0; }   # rclone copy ИСТ НАЗН …
  BACKUP_REMOTE="offsite:optomstroy/prod"
  : > "$B/db_20261119T233000Z.dump.age"; REMOTE_UP=0
  offsite_upload && echo "FAIL offsite_upload: сбой хранилища не замечен"
  [ -e "$B/.offsite_ok" ] && echo "FAIL .offsite_ok после сбоя выгрузки"
  : > "$B/db_20261120T233000Z.dump.age"; REMOTE_UP=1
  offsite_upload || echo "FAIL offsite_upload: доступное хранилище"
  [ -e "$R/db/db_20261119T233000Z.dump.age" ] && [ -e "$R/db/db_20261120T233000Z.dump.age" ] \
    || echo "FAIL offsite_upload: невыгруженная в прошлую ночь копия не догружена"
  [ -s "$B/.offsite_ok" ] || echo "FAIL .offsite_ok не записан после успешной выгрузки"
  unset -f rclone
  BACKUP_REMOTE="offsite:optomstroy/prod/db"; [ "$(remote_root)" = "offsite:optomstroy/prod" ] || echo "FAIL remote_root …/db"
  BACKUP_REMOTE="offsite:optomstroy/prod/"; [ "$(remote_root)" = "offsite:optomstroy/prod" ] || echo "FAIL remote_root /"
  caddy_target 20261119T060000Z >/dev/null || echo "FAIL caddy_target: верная метка"
  ( caddy_target "../x" ) >/dev/null 2>&1 && echo "FAIL caddy_target: неверная метка принята"
  cron_match "30 5 * * *" "30 5 19 11 4" || echo "FAIL cron_match 05:30"
  cron_match "30 5 * * *" "0 3 19 11 4" && echo "FAIL cron_match 03:00"
  grep -q 'schedule="${BACKUP_SCHEDULE:-30 5 \* \* \*}"' "$ROOT/infra/docker/backup/backup.sh" \
    || echo "FAIL backup.sh: расписание по умолчанию — 05:30 (после ночных заданий синхронизации 02:30–04:00)"
  true
) > "$TMP/backup.out" 2>&1 || true
if grep -q '^FAIL' "$TMP/backup.out"; then
  while IFS= read -r line; do bad "${line#FAIL }"; done < <(grep '^FAIL' "$TMP/backup.out")
else
  ok
fi

# ---------- wal-archive.sh (archive_command): без перезаписи, повтор того же файла, сбой — ненулевой код ----------
(
  W="$TMP/walarch"; mkdir -p "$W/pg_wal" "$W/spool"
  # Git Bash (Windows): `sync ФАЙЛ` открывает файл только для чтения, а Windows сбрасывает буферы лишь дескриптора с
  # правом записи — «Permission denied». Здесь — `sync` без аргументов (сброс всего); на Linux проверяется настоящий.
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      mkdir -p "$TMP/shim"
      printf '#!/bin/sh\nexec /usr/bin/sync\n' > "$TMP/shim/sync"
      chmod +x "$TMP/shim/sync"
      PATH="$TMP/shim:$PATH" ;;
  esac
  A="$ROOT/infra/docker/postgres/scripts/wal-archive.sh"
  printf 'segment-one' > "$W/pg_wal/000000010000000000000001"
  printf 'segment-two' > "$W/pg_wal/000000010000000000000002"
  cd "$W"
  WAL_SPOOL_DIR="$W/spool" sh "$A" pg_wal/000000010000000000000001 000000010000000000000001 \
    || echo "FAIL wal-archive: первая архивация"
  cmp -s "$W/pg_wal/000000010000000000000001" "$W/spool/000000010000000000000001" || echo "FAIL wal-archive: содержимое спула"
  [ -z "$(ls -A "$W/spool" | grep '^\.')" ] || echo "FAIL wal-archive: остался временный файл"
  WAL_SPOOL_DIR="$W/spool" sh "$A" pg_wal/000000010000000000000001 000000010000000000000001 \
    || echo "FAIL wal-archive: повтор того же сегмента должен давать 0"
  cp "$W/pg_wal/000000010000000000000002" "$W/pg_wal/other"
  if WAL_SPOOL_DIR="$W/spool" sh "$A" pg_wal/other 000000010000000000000001 2>/dev/null; then
    echo "FAIL wal-archive: перезаписал существующий сегмент другим содержимым"
  fi
  cmp -s "$W/pg_wal/000000010000000000000001" "$W/spool/000000010000000000000001" || echo "FAIL wal-archive: спул испорчен"
  if WAL_SPOOL_DIR="$W/no-spool" sh "$A" pg_wal/000000010000000000000002 000000010000000000000002 2>/dev/null; then
    echo "FAIL wal-archive: нет спула — должен быть ненулевой код"
  fi
  if WAL_SPOOL_DIR="$W/spool" sh "$A" pg_wal/000000010000000000000002 ../x 2>/dev/null; then
    echo "FAIL wal-archive: имя с / принято"
  fi
  if WAL_SPOOL_DIR="$W/spool" sh "$A" pg_wal/missing 000000010000000000000003 2>/dev/null; then
    echo "FAIL wal-archive: нет исходного файла — должен быть ненулевой код"
  fi
  echo "END"; true
) > "$TMP/walarch.out" 2>&1 || true

# ---------- backup.sh: спул → архив, выбор и очистка архива PITR, healthcheck ----------
(
  B="$TMP/pitrb"; S="$TMP/pitrs"; mkdir -p "$B" "$S"
  export BACKUPS_DIR="$B" BACKUP_SH_LIB=1 WAL_SPOOL_DIR="$S"
  # shellcheck source=../backup/backup.sh
  . "$ROOT/infra/docker/backup/backup.sh"
  set +e
  log() { :; }
  age() { # имитация age: -r R -o OUT (шифрование = копия), -d -i K FILE (расшифровка = чтение)
    if [ "$1" = -r ]; then cat > "$4"; else cat "$4"; fi
  }
  BACKUP_AGE_RECIPIENT="age1test"
  # system_identifier — у «базы» на каждом проходе (pitr_resolve не запоминает его на время жизни daemon)
  SYSID_NOW=7000000000000000001
  pg_sql() { case "$1" in *system_identifier*) printf '%s\n' "$SYSID_NOW" ;; *) return 1 ;; esac; }
  PITR_SYSID=7000000000000000001
  for n in 000000010000000000000003 000000010000000000000004 00000002.history; do printf 'x%s' "$n" > "$S/$n"; done
  printf 'foreign' > "$S/notes.txt"
  wal_ship || echo "FAIL wal_ship: код"
  W="$B/pitr/$PITR_SYSID/wal"
  for n in 000000010000000000000003 000000010000000000000004 00000002.history; do
    [ -s "$W/$n.gz.age" ] || echo "FAIL wal_ship: нет $n.gz.age"
    [ ! -e "$S/$n" ] || echo "FAIL wal_ship: $n не удалён из спула"
    [ "$(gzip -dc "$W/$n.gz.age")" = "x$n" ] || echo "FAIL wal_ship: содержимое $n"
    [ "$(cat "$W/$n.gz.age.sha256")" = "$(printf 'x%s' "$n" | sha256sum | cut -d' ' -f1)" ] \
      || echo "FAIL wal_ship: контрольная сумма $n"
  done
  [ -e "$S/notes.txt" ] || echo "FAIL wal_ship: посторонний файл удалён"
  # То же имя, другое содержимое (откат диска базы, пересозданный кластер): остаётся в спуле, код 1, архив цел.
  printf 'dup' > "$S/000000010000000000000003"
  wal_ship && echo "FAIL wal_ship: другое содержимое под именем сегмента из архива — код 0"
  [ -e "$S/000000010000000000000003" ] || echo "FAIL wal_ship: другое содержимое удалено из спула без сверки"
  [ "$(gzip -dc "$W/000000010000000000000003.gz.age")" = "x000000010000000000000003" ] || echo "FAIL wal_ship: архив перезаписан"
  # Повтор архивации с тем же содержимым: копия спула удаляется.
  printf 'x000000010000000000000003' > "$S/000000010000000000000003"
  wal_ship || echo "FAIL wal_ship: повтор архивации того же содержимого — код"
  [ ! -e "$S/000000010000000000000003" ] || echo "FAIL wal_ship: повтор того же содержимого не удалён из спула"
  # Архив без контрольной суммы (записан до 2026-11-19): прежнее поведение — копия спула удаляется.
  printf 'old' | gzip -c > "$W/000000010000000000000006.gz.age"
  printf 'any' > "$S/000000010000000000000006"
  wal_ship || echo "FAIL wal_ship: архив без суммы — код"
  [ ! -e "$S/000000010000000000000006" ] || echo "FAIL wal_ship: архив без суммы — копия спула не удалена"
  rm -f "$W/000000010000000000000006.gz.age"
  # Кластер пересоздан при работающем backup: следующий проход пишет в каталог нового system_identifier.
  SYSID_NOW=7100000000000000002
  printf 'x-new' > "$S/000000010000000000000001"
  wal_ship || echo "FAIL wal_ship: новый кластер — код"
  [ -s "$B/pitr/7100000000000000002/wal/000000010000000000000001.gz.age" ] \
    || echo "FAIL wal_ship: сегмент нового кластера не в pitr/<новый sysid> (system_identifier запомнен)"
  [ ! -e "$W/000000010000000000000001.gz.age" ] || echo "FAIL wal_ship: сегмент нового кластера в каталоге прежнего"
  rm -rf "$B/pitr/7100000000000000002"
  SYSID_NOW=7000000000000000001
  pitr_resolve || echo "FAIL pitr_resolve: код"
  [ "$PITR_SYSID" = 7000000000000000001 ] || echo "FAIL pitr_resolve: $PITR_SYSID"
  rm -f "$S/notes.txt"
  wal_name_ok 000000010000000A000000FF || echo "FAIL wal_name_ok: сегмент"
  wal_name_ok 000000010000000000000003.00000028.backup || echo "FAIL wal_name_ok: .backup"
  wal_name_ok 000000010000000000000003.partial || echo "FAIL wal_name_ok: .partial"
  wal_name_ok 0000000100000000000003 && echo "FAIL wal_name_ok: короткое имя"
  wal_name_ok 00000001000000000000000g && echo "FAIL wal_name_ok: строчная буква"
  got="$(printf '%s\n' 000000010000000000000002.gz.age 000000020000000000000002.partial.gz.age \
           000000010000000000000003.gz.age 00000002.history.gz.age 000000010000000000000002.00000028.backup.gz.age x \
         | wal_older_than 000000020000000000000003 | tr '\n' ' ')"
  [ "$got" = "000000010000000000000002.gz.age 000000020000000000000002.partial.gz.age 000000010000000000000002.00000028.backup.gz.age " ] \
    || echo "FAIL wal_older_than: $got"
  # Очистка: три базовые копии (самая старая — за сроком), WAL до начала самой старой оставшейся удаляется.
  D="$B/pitr/$PITR_SYSID/base"; mkdir -p "$D"
  mkbase() { : > "$D/base_$1.tar.gz.age"; printf 'file=base_%s.tar.gz.age\nstart_wal=%s\nend_utc=%s\n' "$1" "$2" "$3" > "$D/base_$1.info"; touch -d "$4 days ago" "$D/base_$1.tar.gz.age" "$D/base_$1.info"; }
  mkbase 20261001T053000Z 000000010000000000000001 2026-10-01T05:31:00Z 40
  mkbase 20261110T053000Z 000000010000000000000003 2026-11-10T05:31:00Z 9
  mkbase 20261118T053000Z 000000010000000000000004 2026-11-18T05:31:00Z 1
  : > "$W/000000010000000000000001.gz.age"; : > "$W/000000010000000000000002.gz.age"; : > "$W/00000001.history.gz.age"
  : > "$W/000000010000000000000001.gz.age.sha256"
  : > "$W/000000010000000000000009.gz.age.sha256"; touch -d "2 days ago" "$W/000000010000000000000009.gz.age.sha256"
  : > "$W/00000001000000000000000A.gz.age.sha256"   # свежая сумма без сегмента (архив пишется) — остаётся
  # Страховочная копия restore-db.sh (BACKUP_SKIP_PRUNE=1): архив PITR не чистится.
  BACKUP_SKIP_PRUNE=1 rotate_local 30
  [ -e "$D/base_20261001T053000Z.info" ] && [ -e "$W/000000010000000000000001.gz.age" ] \
    || echo "FAIL rotate_local: BACKUP_SKIP_PRUNE=1 — архив PITR очищен"
  pitr_prune 30
  [ ! -e "$D/base_20261001T053000Z.info" ] || echo "FAIL pitr_prune: копия старше срока не удалена"
  [ -e "$D/base_20261110T053000Z.tar.gz.age" ] || echo "FAIL pitr_prune: копия в сроке удалена"
  got="$(cd "$W" && ls | LC_ALL=C sort | tr '\n' ' ')"
  [ "$got" = "00000001.history.gz.age 000000010000000000000003.gz.age 000000010000000000000003.gz.age.sha256 000000010000000000000004.gz.age 000000010000000000000004.gz.age.sha256 00000001000000000000000A.gz.age.sha256 00000002.history.gz.age 00000002.history.gz.age.sha256 " ] \
    || echo "FAIL pitr_prune WAL (сегменты и их суммы; сумма без сегмента — через сутки): $got"
  rm -f "$W/00000001000000000000000A.gz.age.sha256"
  touch -d "60 days ago" "$D"/* ; pitr_prune 30
  [ -e "$D/base_20261118T053000Z.info" ] || echo "FAIL pitr_prune: самая новая копия кластера удалена"
  [ ! -e "$D/base_20261110T053000Z.info" ] || echo "FAIL pitr_prune: старая копия не удалена"
  # Прежний кластер без базовых копий: WAL старше срока удаляется, каталог — тоже.
  O="$B/pitr/6999999999999999999/wal"; mkdir -p "$O"; : > "$O/000000010000000000000009.gz.age"; touch -d "40 days ago" "$O/000000010000000000000009.gz.age"
  pitr_prune 30
  [ ! -d "$B/pitr/6999999999999999999" ] || echo "FAIL pitr_prune: каталог прежнего кластера не убран"
  # healthcheck
  pgrep() { return 0; }
  ROW="$PITR_SYSID on ok"
  pg_sql() { printf '%s\n' "$ROW"; }
  BACKUP_PITR=on; BACKUP_REMOTE=""
  date -u +%s > "$B/.pitr_since"
  [ "$(health)" = ok ] || echo "FAIL health: норма → $(health)"
  ROW="$PITR_SYSID on failing"; health >/dev/null && echo "FAIL health: сбой архивации не замечен"
  ROW="$PITR_SYSID off ok"; health >/dev/null && echo "FAIL health: archive_mode=off при BACKUP_PITR=on не замечен"
  ROW=""; health >/dev/null && echo "FAIL health: недоступная БД не замечена"
  ROW="$PITR_SYSID on ok"
  printf 'old' > "$S/000000010000000000000005"; touch -d "20 minutes ago" "$S/000000010000000000000005"
  health >/dev/null && echo "FAIL health: стоящий спул не замечен"
  rm -f "$S/000000010000000000000005"
  touch -d "30 hours ago" "$B/.pitr_since" "$D"/*
  health >/dev/null && echo "FAIL health: базовая копия старше 26 ч не замечена"
  touch "$D/base_20261118T053000Z.info"
  [ "$(health)" = ok ] || echo "FAIL health: свежая базовая копия → $(health)"
  BACKUP_REMOTE="offsite:x"
  health >/dev/null && echo "FAIL health: нет выгрузки WAL вне сервера при BACKUP_REMOTE"
  date -u +%s > "$B/.wal_offsite_ok"
  [ "$(health)" = ok ] || echo "FAIL health: выгрузка WAL свежая → $(health)"
  BACKUP_PITR=off; ROW="$PITR_SYSID off failing"
  [ "$(health)" = ok ] || echo "FAIL health: BACKUP_PITR=off — проверки WAL не нужны → $(health)"
  echo "END"; true
) > "$TMP/pitrb.out" 2>&1 || true

# ---------- backup.sh: выгрузка WAL вне сервера с последней успешной (догон после перебоя), замок, base_bytes ----------
(
  B="$TMP/wub"; R="$TMP/wur"; mkdir -p "$B/pitr/7000/wal" "$R"
  export BACKUPS_DIR="$B" BACKUP_SH_LIB=1 WAL_SPOOL_DIR="$TMP/wus"
  # shellcheck source=../backup/backup.sh
  . "$ROOT/infra/docker/backup/backup.sh"
  set +e
  log() { :; }
  # Имитация rclone copy ИСТ НАЗН …: *.age из ИСТ/*/wal (шаг WAL) с фильтром --max-age Ns по времени изменения,
  # как у rclone; хранилище «недоступно» — код 1. Последний --max-age — в файле для проверки окна.
  rclone() {
    [ "$REMOTE_UP" = 1 ] || return 1
    local src="$2" age="" prev="" a f rel
    for a in "$@"; do [ "$prev" = --max-age ] && age="${a%s}"; prev="$a"; done
    printf '%s\n' "$age" > "$TMP/wu.maxage"
    sleep "${RCLONE_SLEEP:-0}"
    for f in "$src"/*/wal/*.age; do
      [ -f "$f" ] || continue
      if [ -n "$age" ] && [ "$(stat -c %Y "$f")" -lt $(( $(date +%s) - age )) ]; then continue; fi
      rel="${f#"$src"/}"; mkdir -p "$R/$(dirname "$rel")"; cp -p "$f" "$R/$rel"
    done
  }
  BACKUP_REMOTE="offsite:optomstroy/prod"
  W="$B/pitr/7000/wal"
  mkseg() { : > "$W/$1.gz.age"; touch -d "$2" "$W/$1.gz.age"; }
  # Прошлая успешная выгрузка — 4 ч назад; дальше хранилище недоступно 4 ч, сегменты шифровались всё это время.
  echo $(( $(date +%s) - 4 * 3600 )) > "$B/.wal_offsite_ok"
  mkseg 000000010000000000000010 "300 minutes ago"   # выгружен до перебоя (раньше отметки − 15 мин)
  mkseg 000000010000000000000011 "210 minutes ago"
  mkseg 000000010000000000000012 "150 minutes ago"
  mkseg 000000010000000000000013 "60 minutes ago"
  mkseg 000000010000000000000014 "1 minute ago"
  REMOTE_UP=0; prev="$(cat "$B/.wal_offsite_ok")"
  wal_upload; rc=$?
  [ "$rc" -eq 1 ] || echo "FAIL wal_upload: хранилище недоступно — код $rc, ожидался 1"
  [ "$(cat "$B/.wal_offsite_ok")" = "$prev" ] || echo "FAIL wal_upload: отметка сдвинулась после сбоя"
  REMOTE_UP=1; t0="$(date -u +%s)"; RCLONE_SLEEP=2   # выгрузка идёт 2 с: отметка — начало, а не конец прохода
  wal_upload || echo "FAIL wal_upload: хранилище вернулось — код"
  t1="$(( t0 + 1 ))"; RCLONE_SLEEP=0
  for n in 11 12 13 14; do
    [ -e "$R/7000/wal/0000000100000000000000$n.gz.age" ] \
      || echo "FAIL wal_upload: сегмент ${n} (перебой длиннее 2 ч) не выгружен первым же проходом после перебоя"
  done
  [ ! -e "$R/7000/wal/000000010000000000000010.gz.age" ] || echo "FAIL wal_upload: окно шире нужного (сегмент до отметки − 15 мин)"
  m="$(cat "$B/.wal_offsite_ok")"
  [ "$m" -ge "$t0" ] && [ "$m" -le "$t1" ] || echo "FAIL wal_upload: отметка ($m) — не время начала прохода ($t0…$t1)"
  w="$(cat "$TMP/wu.maxage")"
  [ "$w" -ge $(( 4 * 3600 + 900 - 5 )) ] && [ "$w" -le $(( 4 * 3600 + 900 + 5 )) ] || echo "FAIL wal_upload: окно $w с, ожидалось ≈ 4 ч + 15 мин"
  # Отметка минуту назад — окно не меньше 2 ч.
  echo $(( $(date +%s) - 60 )) > "$B/.wal_offsite_ok"
  wal_upload; [ "$(cat "$TMP/wu.maxage")" = 7200 ] || echo "FAIL wal_upload: нижняя граница окна — $(cat "$TMP/wu.maxage"), ожидалось 7200"
  # Отметки нет (первая выгрузка, новый диск копий) или она испорчена — весь архив, без --max-age.
  for bad in "" "garbage"; do
    rm -rf "${R:?}/7000"
    if [ -z "$bad" ]; then rm -f "$B/.wal_offsite_ok"; else echo "$bad" > "$B/.wal_offsite_ok"; fi
    wal_upload || echo "FAIL wal_upload: без отметки «$bad» — код"
    [ -z "$(cat "$TMP/wu.maxage")" ] || echo "FAIL wal_upload: без отметки «$bad» передан --max-age"
    [ -e "$R/7000/wal/000000010000000000000010.gz.age" ] || echo "FAIL wal_upload: без отметки «$bad» выгружен не весь архив"
    case "$(cat "$B/.wal_offsite_ok")" in ''|*[!0-9]*) echo "FAIL wal_upload: отметка после выгрузки без отметки «$bad»" ;; esac
  done
  # Замок: пока его держит ночная выгрузка (другой процесс) — код 75, отметка не двигается; ночная выгрузка ждёт
  # замок не дольше WAL_LOCK_WAIT_SEC и без него шаг WAL не делает.
  hold_lock() {
    if command -v flock >/dev/null 2>&1; then
      ( exec 8>>"$WAL_LOCK"; flock 8; sleep 4 ) &
      sleep 1
    else
      mkdir "$WAL_LOCK.d"
    fi
  }
  drop_lock() { if command -v flock >/dev/null 2>&1; then wait; else rmdir "$WAL_LOCK.d"; fi; }
  hold_lock
  prev="$(cat "$B/.wal_offsite_ok")"
  wal_upload; rc=$?
  [ "$rc" -eq 75 ] || echo "FAIL wal_upload: замок занят — код $rc, ожидался 75"
  [ "$(cat "$B/.wal_offsite_ok")" = "$prev" ] || echo "FAIL wal_upload: отметка сдвинулась при занятом замке"
  WAL_LOCK_WAIT_SEC=0; rm -f "$B/.offsite_ok"; MEDIA_SRC="$TMP/no-media"
  offsite_upload && echo "FAIL offsite_upload: шаг WAL без замка — код 0"
  [ ! -e "$B/.offsite_ok" ] || echo "FAIL offsite_upload: .offsite_ok при пропущенном шаге WAL"
  drop_lock
  offsite_upload || echo "FAIL offsite_upload: замок свободен — код"
  wal_upload || echo "FAIL wal_upload: замок снят — код"
  [ ! -e "$WAL_LOCK.d" ] || echo "FAIL wal_upload: каталог-замок не снят"
  if ! command -v flock >/dev/null 2>&1; then
    # Без flock (вне образа): брошенный каталог-замок старше 3 ч снимается.
    mkdir "$WAL_LOCK.d"; touch -d "4 hours ago" "$WAL_LOCK.d"
    wal_upload || echo "FAIL wal_upload: брошенный замок не снят"
  fi
  # base_backup: размер tar до сжатия (base_bytes) — через именованный канал, поток в архиве не искажён.
  age() { if [ "$1" = -r ]; then cat > "$4"; else cat "$4"; fi; }
  BACKUP_AGE_RECIPIENT="age1test"
  pg_bin() { echo stub; }
  pg_sql() { case "$1" in *system_identifier*) echo 7000 ;; *pg_walfile_name*) echo 000000010000000000000015 ;; *) return 1 ;; esac; }
  pg_base_stream() { head -c 123457 /dev/zero; }
  base_backup 20261119T053000Z || echo "FAIL base_backup: код"
  info="$B/pitr/7000/base/base_20261119T053000Z.info"
  expect_line() { grep -qx "$2" "$info" || echo "FAIL base_backup .info: нет «$2» ($1)"; }
  expect_line "размер до сжатия" "base_bytes=123457"
  expect_line "кластер" "system_identifier=7000"
  expect_line "первый сегмент" "start_wal=000000010000000000000015"
  [ "$(gzip -dc "$B/pitr/7000/base/base_20261119T053000Z.tar.gz.age" | wc -c | tr -d ' ')" = 123457 ] \
    || echo "FAIL base_backup: копия искажена (tee → gzip)"
  [ -z "$(ls -A "$B/pitr/7000/base" | grep '^\.')" ] || echo "FAIL base_backup: остались служебные файлы: $(ls -A "$B/pitr/7000/base")"
  echo "END"; true
) > "$TMP/walup.out" 2>&1 || true

# ---------- lib.sh: PITR (момент, выбор копии и WAL, настройки), журнал миграций, pgboss, pg_hba ----------
(
  set +e
  P="$TMP/pitrl/pitr"; mkdir -p "$P/7000/base" "$P/7000/wal" "$P/8000/base"
  expect() { [ "$2" = "$3" ] || echo "FAIL $1: «$2» ≠ «$3»"; }
  expect "pitr_to_utc +06" "$(pitr_to_utc '2026-11-19 14:30' '<+06>-6')" "2026-11-19T08:30:00Z"
  expect "pitr_to_utc с секундами" "$(pitr_to_utc '2026-11-19 00:05:07' '<+06>-6')" "2026-11-18T18:05:07Z"
  if [ -f /usr/share/zoneinfo/Asia/Bishkek ]; then
    expect "pitr_to_utc Asia/Bishkek" "$(pitr_to_utc '2026-11-19 14:30' Asia/Bishkek)" "2026-11-19T08:30:00Z"
  fi
  pitr_to_utc '2026-11-19T14:30' UTC >/dev/null && echo "FAIL pitr_to_utc: формат с T принят"
  pitr_to_utc '2026-02-30 10:00' UTC >/dev/null && echo "FAIL pitr_to_utc: 30 февраля принято"
  pitr_to_utc '19.11.2026 10:00' UTC >/dev/null && echo "FAIL pitr_to_utc: чужой формат принят"
  pitr_to_utc '2026-11-19 10:00' 'Nowhere/City'; expect "pitr_to_utc: нет пояса — код 3" "$?" "3"
  mk() { : > "$P/$1/base/base_$2.tar.gz.age"; printf 'file=base_%s.tar.gz.age\nstart_wal=%s\nend_utc=%s\n' "$2" "$3" "$4" > "$P/$1/base/base_$2.info"; }
  mk 7000 20261117T053000Z 000000010000000000000010 2026-11-17T05:31:40Z
  mk 7000 20261118T053000Z 000000010000000000000020 2026-11-18T05:31:40Z
  mk 8000 20261119T053000Z 000000010000000000000002 2026-11-19T05:31:40Z
  rm -f "$P/7000/base/base_20261117T053000Z.tar.gz.age.x"
  expect "pitr_pick_base до первой копии" "$(pitr_pick_base "$P" 2026-11-17T05:31:00Z)" ""
  expect "pitr_pick_base между копиями" "$(pitr_pick_base "$P" 2026-11-18T05:31:00Z)" "$P/7000/base/base_20261117T053000Z.info"
  expect "pitr_pick_base самая новая" "$(pitr_pick_base "$P" 2026-11-19T09:00:00Z)" "$P/8000/base/base_20261119T053000Z.info"
  expect "pitr_pick_base по кластеру" "$(pitr_pick_base "$P" 2026-11-19T09:00:00Z 7000)" "$P/7000/base/base_20261118T053000Z.info"
  rm -f "$P/8000/base/base_20261119T053000Z.tar.gz.age"
  expect "pitr_pick_base без файла копии" "$(pitr_pick_base "$P" 2026-11-19T09:00:00Z)" "$P/7000/base/base_20261118T053000Z.info"
  W="$P/7000/wal"
  for n in 00000001000000000000001F 000000010000000000000020 000000010000000000000021 000000020000000000000021 \
           000000010000000000000022 00000002.history 000000010000000000000020.00000028.backup; do
    : > "$W/$n.gz.age"; touch -d "2026-11-18 10:00:00 UTC" "$W/$n.gz.age"
  done
  touch -d "2026-11-20 10:00:00 UTC" "$W/000000010000000000000022.gz.age" "$W/00000002.history.gz.age"
  got="$(pitr_wal_list "$W" 000000010000000000000020 "$(date -u -d '2026-11-19 00:00:00 UTC' +%s)" | tr '\n' ' ')"
  expect "pitr_wal_list" "$got" "000000010000000000000020 000000010000000000000021 00000002.history 000000020000000000000021 "
  conf="$(pitr_recovery_conf 2026-11-19T08:30:00Z)"
  case "$conf" in *"recovery_target_time = '2026-11-19 08:30:00+00'"*) ;; *) echo "FAIL pitr_recovery_conf: время" ;; esac
  case "$conf" in *"recovery_target_action = 'promote'"*) ;; *) echo "FAIL pitr_recovery_conf: promote" ;; esac
  case "$conf" in *"restore_command = 'cp pitr_restore_wal/%f \"%p\"'"*) ;; *) echo "FAIL pitr_recovery_conf: restore_command" ;; esac
  case "$PITR_RESET_SQL" in *"RESET restore_command"*"RESET recovery_target_time"*"pg_reload_conf"*) ;; *) echo "FAIL PITR_RESET_SQL" ;; esac
  # До конца архива (restore-db.sh --to-latest): без цели — ни recovery_target_time, ни recovery_target_action.
  conf="$(pitr_recovery_conf latest)"
  case "$conf" in *"recovery_target_time ="*|*recovery_target_action*|*"recovery_target ="*|*recovery_target_lsn*|*recovery_target_xid*|*recovery_target_name*)
    echo "FAIL pitr_recovery_conf latest: есть цель восстановления" ;; esac
  case "$conf" in *"restore_command = 'cp pitr_restore_wal/%f \"%p\"'"*) ;; *) echo "FAIL pitr_recovery_conf latest: restore_command" ;; esac
  case "$conf" in *"recovery_target_timeline = 'latest'"*) ;; *) echo "FAIL pitr_recovery_conf latest: линия времени" ;; esac
  # Выбор кластера: два кластера с копиями (новый сервер) — без --sysid отказ (код 3) со строкой по каждому.
  out="$(pitr_select_cluster "$P")"; rc=$?
  expect "pitr_select_cluster: два кластера — код" "$rc" "3"
  expect "pitr_select_cluster: строк о кластерах" "$(printf '%s\n' "$out" | grep -c '^[78]000: базовые копии')" "2"
  case "$out" in *"7000: базовые копии 2026-11-17T05:31:40Z … 2026-11-18T05:31:40Z (UTC)"*) ;; *) echo "FAIL pitr_cluster_line: $out" ;; esac
  expect "pitr_select_cluster --sysid" "$(pitr_select_cluster "$P" 7000)" "7000"
  pitr_select_cluster "$P" 9999 >/dev/null; expect "pitr_select_cluster: неизвестный --sysid — код" "$?" "4"
  # Копия нового кластера (8000) новее, но с --sysid берётся только прежний.
  mk 8000 20261119T053000Z 000000010000000000000002 2026-11-19T05:31:40Z
  expect "pitr_pick_base: без кластера — новее (8000)" "$(pitr_pick_base "$P" 2026-11-19T09:00:00Z)" "$P/8000/base/base_20261119T053000Z.info"
  expect "pitr_pick_base: --sysid 7000 не берёт копию 8000" "$(pitr_pick_base "$P" 2026-11-19T09:00:00Z "$(pitr_select_cluster "$P" 7000)")" \
    "$P/7000/base/base_20261118T053000Z.info"
  rm -rf "$P/8000"
  expect "pitr_select_cluster: один кластер" "$(pitr_select_cluster "$P")" "7000"
  # Дыры в архиве WAL (restore-db.sh --to-latest / --to-time).
  gaps() { printf '%s\n' "$@" > "$TMP/gl"; pitr_wal_gaps "$TMP/gl"; }
  gaps 000000010000000000000003 000000010000000000000004 000000010000000000000005 00000002.history >/dev/null \
    || echo "FAIL pitr_wal_gaps: непрерывный архив"
  got="$(gaps 000000010000000000000003 000000010000000000000004 000000010000000000000006 000000010000000000000007)"
  expect "pitr_wal_gaps: дыра" "$got" "000000010000000000000004 000000010000000000000006"
  gaps 0000000100000000000000FE 0000000100000000000000FF 000000010000000100000000 000000010000000100000001 >/dev/null \
    || echo "FAIL pitr_wal_gaps: переход xlogid (…FF → …0100000000) — не дыра"
  got="$(gaps 0000000100000000000000FF 000000010000000100000001)"
  expect "pitr_wal_gaps: дыра на переходе xlogid" "$got" "0000000100000000000000FF 000000010000000100000001"
  # Линии времени: TL2 ответвилась на 03; после неё нужна именно TL2 — сегмент 04 только на TL1 дыру не закрывает.
  gaps 000000010000000000000002 000000010000000000000003 000000010000000000000004 000000010000000000000005 \
       000000020000000000000003 000000020000000000000004 00000002.history >/dev/null \
    || echo "FAIL pitr_wal_gaps: переключение линии времени — не дыра (мёртвая ветвь TL1 дальше TL2)"
  got="$(gaps 000000010000000000000002 000000010000000000000003 000000010000000000000004 000000020000000000000003 000000020000000000000005)"
  expect "pitr_wal_gaps: дыра на последней линии времени" "$got" "000000020000000000000003 000000020000000000000005"
  # Место на диске базы: размер до сжатия × 1,1 + (сегменты + 2) × 16 МиБ.
  printf 'file=x.tar.gz.age\nbase_bytes=1000000\n' > "$TMP/i1.info"
  printf 'file=x.tar.gz.age\n' > "$TMP/i2.info"
  expect "pitr_bytes_needed base_bytes" "$(pitr_bytes_needed "$TMP/i1.info" 3)" "$(( 1100000 + 5 * 16777216 ))"
  expect "pitr_bytes_needed измеренный размер" "$(pitr_bytes_needed "$TMP/i2.info" 0 2000000)" "$(( 2200000 + 2 * 16777216 ))"
  pitr_bytes_needed "$TMP/i2.info" 3 >/dev/null; expect "pitr_bytes_needed без размера — код" "$?" "2"
  pitr_bytes_needed "$TMP/none.info" 3 >/dev/null; expect "pitr_bytes_needed без .info — код" "$?" "1"
  # restore-db.sh: страховочная копия без очистки PITR; журнал postgres — без `| grep -q` (pipefail + SIGPIPE).
  grep -q 'dc run --rm -e BACKUP_SKIP_PRUNE=1 backup once' "$ROOT/infra/scripts/restore-db.sh" \
    || echo "FAIL restore-db.sh: страховочная копия без BACKUP_SKIP_PRUNE=1"
  ! grep -nE '^[^#]*dc logs[^#]*\|[^#]*grep -[A-Za-z]*q' "$ROOT/infra/scripts/restore-db.sh" \
    || echo "FAIL restore-db.sh: dc logs | grep -q (при pipefail может «не найти» строку)"
  # Откат к версии без непрерывной копии: предупреждение о сегментах в спуле — по compose.prod.yml.
  K="$TMP/kit"; mkdir -p "$K/prod/docker/postgres/scripts" "$K/data/walspool"
  : > "$K/prod/docker/postgres/scripts/wal-archive.sh"            # осталось от нового релиза
  printf 'services:\n  postgres:\n    command: [ "postgres" ]\n' > "$K/prod/compose.prod.yml"
  walspool_orphaned "$K/prod" "$K/data" && echo "FAIL walspool_orphaned: пустой спул"
  : > "$K/data/walspool/000000010000000000000001"
  walspool_orphaned "$K/prod" "$K/data" || echo "FAIL walspool_orphaned: прежний compose без archive_command, сегменты в спуле"
  printf 'services:\n  postgres:\n    command: [ "postgres", "-c", "archive_command=sh x %%p %%f" ]\n' > "$K/prod/compose.prod.yml"
  walspool_orphaned "$K/prod" "$K/data" && echo "FAIL walspool_orphaned: compose ведёт архивацию"
  # Тестовая копия: новые имена из prod.env.example — с заменами test.env.example; заданные значения не трогаются.
  grep -v '^BACKUP_PITR=' "$ROOT/infra/env/prod.env.example" > "$TMP/envt"
  env_apply_lines "$ROOT/infra/env/test.env.example" "$TMP/envt"
  grep -v '^BACKUP_PITR=' "$TMP/envt" > "$TMP/envt2"; mv "$TMP/envt2" "$TMP/envt"
  env_set "$TMP/envt" LOG_LEVEL debug
  env_merge_template "$ROOT/infra/env/prod.env.example" "$TMP/envt"
  expect "env_merge_template: добавлено" "$ENV_ADDED" " BACKUP_PITR"
  env_apply_test_for_added "$ROOT/infra/env/test.env.example" "$TMP/envt"
  expect "env_apply_test_for_added: BACKUP_PITR теста" "$(env_get "$TMP/envt" BACKUP_PITR)" "off"
  expect "env_apply_test_for_added: строк BACKUP_PITR" "$(grep -c '^BACKUP_PITR=' "$TMP/envt")" "1"
  expect "env_apply_test_for_added: заданное значение не тронуто" "$(env_get "$TMP/envt" LOG_LEVEL)" "debug"
  ENV_ADDED=""; env_apply_test_for_added "$ROOT/infra/env/test.env.example" "$TMP/envt"
  expect "env_apply_test_for_added: без новых имён" "$(env_get "$TMP/envt" LOG_LEVEL)" "debug"
  # validate_env тестовой копии: BACKUP_PITR=on — предупреждение (не отказ).
  for kv in API_TAG=t1 BACKUP_TAG=t1 PUBLIC_BASE_URL=https://api-test.example.kg MIN_APP_VERSION=android=1.0.0 JWT_KEY_ID=k1 \
            BACKUP_AGE_RECIPIENT=age1test CADDY_SITE_ADDRESS=api-test.example.kg AUTH_OTP_TEST_CODE=123456 LOG_LEVEL=info; do
    env_set "$TMP/envt" "${kv%%=*}" "${kv#*=}"
  done
  CONTOUR=test; contour_init test
  warn() { printf 'WARN %s\n' "$*" >> "$TMP/warn.log"; }
  rm -f "$TMP/warn.log"
  ( validate_env "$TMP/envt" ) >/dev/null 2>&1 || echo "FAIL validate_env тестовой копии (BACKUP_PITR=off) отклонён"
  grep -q BACKUP_PITR "$TMP/warn.log" 2>/dev/null && echo "FAIL validate_env: предупреждение при BACKUP_PITR=off в тесте"
  env_set "$TMP/envt" BACKUP_PITR on
  ( validate_env "$TMP/envt" ) >/dev/null 2>&1 || echo "FAIL validate_env: BACKUP_PITR=on в тесте — отказ вместо предупреждения"
  grep -q BACKUP_PITR "$TMP/warn.log" 2>/dev/null || echo "FAIL validate_env: нет предупреждения BACKUP_PITR=on в тестовой копии"
  warn() { :; }
  CONTOUR=prod; contour_init prod
  # журнал миграций (update.sh --rollback)
  expect "journal_added нет новых" "$(journal_added 0001,0002 0001,0002)" ""
  expect "journal_added новые" "$(journal_added 0001,0002 0001,0002,0003,0004)" "0003,0004"
  expect "journal_added из пустого" "$(journal_added - 0001)" "0001"
  expect "journal_added пропавшие" "$(journal_added 0001,0002,0003 0001,0002)" ""
  expect "journal_added пропавшие (обратный)" "$(journal_added 0001,0002 0001,0002,0003)" "0003"
  journal_valid "0001,0024" || echo "FAIL journal_valid: верный"
  journal_valid "-" || echo "FAIL journal_valid: пустой журнал"
  journal_valid "" && echo "FAIL journal_valid: пустая строка (ошибка запроса) принята"
  journal_valid "1,2" && echo "FAIL journal_valid: неверный формат принят"
  # pgboss: блок update.sh = restore-db.sh = RUNBOOK §3.6 (тот же текст сверяет pos-api migrate-seed.db-spec.ts п. 13)
  norm() { sed 's/--.*$//' | tr -s ' \t\n' '   ' | sed 's/^ //; s/ $//'; }
  blk="$(pgboss_transfer_sql "$ROOT/infra/scripts/restore-db.sh")"
  rb="$(awk 'index($0, "### 3.6.") == 1 { s = 1 } s && /<<.SQL.$/ { i = 1; next } i && $0 == "SQL" { exit } i { print }' "$ROOT/docs/ops/RUNBOOK.md")"
  [ -n "$blk" ] || echo "FAIL pgboss_transfer_sql: блок не найден в restore-db.sh"
  [ "$(printf '%s' "$blk" | norm)" = "$(printf '%s' "$rb" | norm)" ] || echo "FAIL pgboss_transfer_sql: блок restore-db.sh ≠ RUNBOOK §3.6"
  case "$blk" in *"ALTER SCHEMA pgboss OWNER TO pos_migrate"*) ;; *) echo "FAIL pgboss_transfer_sql: нет ALTER SCHEMA" ;; esac
  # psql_* вызываются в конвейере (подоболочка) — переданное фиксируется в файлах.
  psql_super_quiet() { cat > "$TMP/sent.sql"; echo x >> "$TMP/sent.count"; }
  psql_super_at() { cat >/dev/null; echo pos_migrate; }
  pg_transfer_pgboss_owner "$ROOT/infra/scripts/restore-db.sh" >/dev/null || echo "FAIL pg_transfer_pgboss_owner: код"
  [ "$(cat "$TMP/sent.sql")" = "$blk" ] || echo "FAIL pg_transfer_pgboss_owner: отправлен не блок restore-db.sh"
  psql_super_at() { cat >/dev/null; echo pos_app; }
  ( pg_transfer_pgboss_owner "$ROOT/infra/scripts/restore-db.sh" ) >/dev/null 2>&1 && echo "FAIL pg_transfer_pgboss_owner: владелец не pos_migrate — должен быть отказ"
  # pg_hba: строка репликации добавляется один раз (как 10-roles.sh)
  H="$TMP/pghba"; mkdir -p "$H"; printf 'local all all trust\nhost all all all scram-sha-256\n' > "$H/pg_hba.conf"
  dc() { shift 3; PGDATA="$H" "$@"; }   # dc exec -T postgres sh -c '…' → тот же sh -c локально
  rm -f "$TMP/sent.count"
  pg_ensure_replication_hba; pg_ensure_replication_hba
  expect "pg_hba: строк репликации" "$(grep -c '^host replication pos_backup all scram-sha-256$' "$H/pg_hba.conf")" "1"
  expect "pg_hba: перечитываний" "$(wc -l < "$TMP/sent.count" | tr -d ' ')" "1"
  case "$(cat "$TMP/sent.sql")" in *pg_reload_conf*) ;; *) echo "FAIL pg_hba: нет pg_reload_conf" ;; esac
  expect "pg_hba: последняя строка" "$(tail -n 1 "$H/pg_hba.conf")" "host replication pos_backup all scram-sha-256"
  grep -q 'host replication pos_backup all scram-sha-256' "$ROOT/infra/docker/postgres/initdb/10-roles.sh" \
    || echo "FAIL 10-roles.sh: другая строка pg_hba"
  # BACKUP_PITR в .env: on|off, иное — отказ
  cp "$ROOT/infra/env/prod.env.example" "$TMP/env6"
  for kv in API_TAG=t1 BACKUP_TAG=t1 PUBLIC_BASE_URL=https://api.example.kg MIN_APP_VERSION=android=1.0.0 JWT_KEY_ID=k1 \
            BACKUP_AGE_RECIPIENT=age1test CADDY_SITE_ADDRESS=api.example.kg CADDY_TLS=ops@example.kg; do
    env_set "$TMP/env6" "${kv%%=*}" "${kv#*=}"
  done
  CONTOUR=prod; contour_init prod
  ( validate_env "$TMP/env6" ) >/dev/null 2>&1 || echo "FAIL validate_env: заполненный шаблон (BACKUP_PITR=on) отклонён"
  env_set "$TMP/env6" BACKUP_PITR maybe
  msg="$( ( validate_env "$TMP/env6" ) 2>&1 )" && echo "FAIL validate_env: BACKUP_PITR=maybe принят"
  case "$msg" in *BACKUP_PITR*) ;; *) echo "FAIL validate_env: в отказе нет BACKUP_PITR: $msg" ;; esac
  # 1С подключена, режим extension: HTTP-сервис без пары OData — предупреждение (полная загрузка, срезы цен и остатков,
  # список фото читаются через OData; 2026-11-20, откат P-003), с парой — без предупреждений 1С.
  env_set "$TMP/env6" BACKUP_PITR on
  env_set "$TMP/env6" ONEC_BASE_URL https://10.77.0.2/ut11
  warn() { printf 'WARN %s\n' "$*" >> "$TMP/warn1c.log"; }
  for s in $ONEC_HS_SECRETS; do printf 'x' > "$SECRETS_DIR/$s"; done
  rm -f "$TMP/warn1c.log"
  ( validate_env "$TMP/env6" ) >/dev/null 2>&1 || echo "FAIL validate_env: extension без пары OData — отказ вместо предупреждения"
  grep -q 'ONEC_MODE=extension без пары секретов OData' "$TMP/warn1c.log" 2>/dev/null \
    || echo "FAIL validate_env: нет предупреждения extension без пары OData"
  for s in $ONEC_ODATA_SECRETS; do printf 'x' > "$SECRETS_DIR/$s"; done
  rm -f "$TMP/warn1c.log"
  ( validate_env "$TMP/env6" ) >/dev/null 2>&1 || echo "FAIL validate_env: extension с обоими наборами 1С отклонён"
  grep -qE 'OData|HTTP-сервиса 1С' "$TMP/warn1c.log" 2>/dev/null && echo "FAIL validate_env: предупреждение 1С при полном наборе"
  for s in $ONEC_HS_SECRETS $ONEC_ODATA_SECRETS; do rm -f "$SECRETS_DIR/$s"; done
  warn() { :; }
  echo "END"; true
) > "$TMP/pitrl.out" 2>&1 || true

# ---------- lib.sh: сервер вне магазина — туннель WireGuard к 1С (сценарий C-1, RUNBOOK §11; без root и без wg) ----------
yn() { if "$@"; then echo y; else echo n; fi; }
expect_eq "ip_in_cidr /32" "$(yn ip_in_cidr 10.77.0.2 10.77.0.2/32)" y
expect_eq "ip_in_cidr соседний адрес" "$(yn ip_in_cidr 10.77.0.3 10.77.0.2/32)" n
expect_eq "ip_in_cidr /24 и /0" "$(yn ip_in_cidr 192.168.1.10 192.168.1.0/24)$(yn ip_in_cidr 8.8.8.8 0.0.0.0/0)" yy
expect_eq "ip_in_cidr IPv6 и (none)" "$(yn ip_in_cidr 10.77.0.2 fd00::/64)$(yn ip_in_cidr 10.77.0.2 '(none)')" nn
expect_eq "ip_in_cidr не IPv4" \
  "$(yn ip_in_cidr 300.1.1.1 10.0.0.0/8)$(yn ip_in_cidr 10..0.1 10.0.0.0/8)$(yn ip_in_cidr 10.0.0.1. 10.0.0.0/8)" nnn
expect_eq "url_hostname" "$(url_hostname https://10.77.0.2/ut11)|$(url_hostname https://u@1c.local:8443/b/x)|$(url_hostname https://1c.local)" \
  "10.77.0.2|1c.local|1c.local"
expect_eq "host_ipv4 IPv4 без DNS" "$(host_ipv4 10.77.0.2)" "10.77.0.2"
# Сигнал WG_HANDSHAKE_STALE — ровно один и в любое время: 1С нужна весь день (15 ADR-120, отмена P-003 2026-11-20).
# Вне комментариев в metrics_check.sh нет проверки окна (in_time_window, SYNC_NIGHT_WINDOW).
expect_eq "metrics_check.sh: WG_HANDSHAKE_STALE ровно один" \
  "$(grep -v '^[[:space:]]*#' "$ROOT/infra/scripts/metrics_check.sh" | grep -c 'alert "WG_HANDSHAKE_STALE' || true)" 1
expect_eq "metrics_check.sh: WG_HANDSHAKE_STALE без ночного окна" \
  "$(grep -v '^[[:space:]]*#' "$ROOT/infra/scripts/metrics_check.sh" | grep -nE 'in_time_window|SYNC_NIGHT_WINDOW' || true)" ""
# host-net-check.sh только читает: вне комментариев и строк в кавычках нет команд, меняющих firewall, туннель, пояс и
# службы (подсказки в тексте замечаний допустимы — они не выполняются).
expect_eq "host-net-check.sh только читает" "$(grep -v '^[[:space:]]*#' "$ROOT/infra/scripts/host-net-check.sh" \
  | sed -e 's/"[^"]*"//g' -e "s/'[^']*'//g" \
  | grep -En 'ufw +(allow|deny|reject|limit|enable|disable|delete|insert|reset|default)|systemctl +(enable|disable|start|stop|restart|reload|mask)|wg +(set|setconf|addconf|syncconf)|wg-quick +(up|down|save)|timedatectl +set|iptables +-[AIDFPNXRZ]|ip +(link|addr|address|route) +(add|del|delete|set|change|replace|flush)' \
  || true)" ""
# Вывод `ufw status` переводится (gettext): каждый вызов в host-net-check.sh — с LC_ALL=C, иначе на сервере с русской
# локалью ложный FIREWALL=ufw-inactive и пропуск WG_PORT_CLOSED.
expect_eq "host-net-check.sh: ufw status только с LC_ALL=C" "$(grep -v '^[[:space:]]*#' "$ROOT/infra/scripts/host-net-check.sh" \
  | grep -E 'ufw +status' | grep -Ev 'LC_ALL=C +ufw +status' || true)" ""
(
  NOW_HM=03:00
  date() { case "${1:-}" in +%H:%M) echo "$NOW_HM" ;; *) command date "$@" ;; esac; }
  w() { NOW_HM="$1"; if in_time_window "$2" UTC; then echo y; else echo n; fi; }
  [ "$(w 03:00 01:00-06:00)$(w 00:59 01:00-06:00)$(w 06:00 01:00-06:00)$(w 01:00 01:00-06:00)" = ynny ] \
    || echo "FAIL in_time_window: ночное окно 01:00-06:00"
  [ "$(w 23:30 22:00-02:00)$(w 01:59 22:00-02:00)$(w 12:00 22:00-02:00)" = yyn ] || echo "FAIL in_time_window: через полночь"
  [ "$(w 12:00 bad)$(w 12:00 25:00-26:00)$(w 12:00 '')" = yyy ] || echo "FAIL in_time_window: неверный формат — не сигнал"
  NOW="$(command date +%s)"
  wg() {
    case "$3" in
      allowed-ips) printf 'KS=\t10.77.0.2/32 192.168.1.10/32\nKA=\t10.77.0.10/32\nKN=\t(none)\n' ;;
      latest-handshakes) printf 'KS=\t%s\nKA=\t0\nKN=\t0\n' "$((NOW - 40))" ;;
    esac
  }
  age="$(wg_peer_handshake_age wg0 192.168.1.10)"
  [ "$age" -ge 40 ] && [ "$age" -le 45 ] || echo "FAIL wg_peer_handshake_age: LAN-адрес 1С за роутером — $age"
  age="$(wg_peer_handshake_age wg0 10.77.0.2)"
  case "$age" in *KS*|*KA*) echo "FAIL wg_peer_handshake_age печатает ключ пира" ;; esac
  [ "$age" -ge 40 ] && [ "$age" -le 45 ] || echo "FAIL wg_peer_handshake_age: адрес магазина в туннеле — $age"
  [ "$(wg_peer_handshake_age wg0 10.77.0.10)" = never ] || echo "FAIL wg_peer_handshake_age: рукопожатия не было — не never"
  [ -z "$(wg_peer_handshake_age wg0 10.77.0.99)" ] || echo "FAIL wg_peer_handshake_age: нет пира — не пусто"
  echo "END"; true
) > "$TMP/wgnet.out" 2>&1 || true

# ---------- lib.sh: копии и база на одном физическом диске (path_disks, common_disks; RUNBOOK §2.2) ----------
(
  findmnt() {   # findmnt -no SOURCE -T <путь>
    case "$4" in
      /srv/lvm/backups) echo /dev/mapper/vg-backups ;;
      /srv/lvm/pgdata) echo /dev/nvme0n1p2 ;;
      /srv/two/backups) echo /dev/sdb1 ;;
      /srv/two/pgdata) echo /dev/sda2 ;;
      /srv/raid/backups) echo /dev/md1 ;;
      /srv/raid/pgdata) echo /dev/md0 ;;
      /srv/btrfs/backups) echo '/dev/nvme0n1p2[/@backups]' ;;
      /srv/nfs/backups) echo 'nas:/export/backups' ;;
    esac
  }
  lsblk() {     # lsblk -nrso NAME,TYPE <устройство>: само устройство и всё под ним до физических дисков
    case "$3" in
      /dev/mapper/vg-backups) printf 'vg-backups lvm\nnvme0n1p3 part\nnvme0n1 disk\n' ;;
      /dev/nvme0n1p2) printf 'nvme0n1p2 part\nnvme0n1 disk\n' ;;
      /dev/sdb1) printf 'sdb1 part\nsdb disk\n' ;;
      /dev/sda2) printf 'sda2 part\nsda disk\n' ;;
      /dev/md1) printf 'md1 raid1\nsda3 part\nsda disk\nsdb3 part\nsdb disk\n' ;;
      /dev/md0) printf 'md0 raid1\nsda2 part\nsda disk\nsdb2 part\nsdb disk\n' ;;
      *) return 1 ;;
    esac
  }
  shared() { common_disks "$(path_disks "/srv/$1/backups")" "$(path_disks "/srv/$1/pgdata")"; }
  [ "$(shared lvm)" = nvme0n1 ] || echo "FAIL path_disks: том LVM и раздел одного NVMe — «$(shared lvm)»"
  [ -z "$(shared two)" ] || echo "FAIL path_disks: два разных диска — «$(shared two)»"
  [ "$(shared raid)" = "sda sdb" ] || echo "FAIL path_disks: два RAID 1 на одной паре дисков — «$(shared raid)»"
  [ "$(path_disks /srv/btrfs/backups)" = nvme0n1 ] || echo "FAIL path_disks: подтом btrfs — «$(path_disks /srv/btrfs/backups)»"
  [ -z "$(path_disks /srv/nfs/backups)" ] || echo "FAIL path_disks: сетевая ФС — не пусто"
  [ -z "$(path_disks /srv/unknown/backups)" ] || echo "FAIL path_disks: источник не найден — не пусто"
  [ -z "$(PATH=/nonexistent; unset -f findmnt lsblk; path_disks /srv/lvm/backups)" ] \
    || echo "FAIL path_disks: без findmnt и lsblk — не пусто"
  [ -z "$(common_disks "" "sda")" ] || echo "FAIL common_disks: пустой список — не пусто"
  # backups_disk_gate (install.sh шаг 3, рабочий контур; 14 Q-374): та же ФС или общий физический диск — ошибка без
  # --allow-same-disk, с ним — предупреждение; разные диски и «не определить» — без вывода.
  stat() { case "$3" in /srv/same/*) echo 2049 ;; *) printf '%s\n' "$3" ;; esac; }   # stat -c %d <путь>
  warn() { printf 'ВНИМАНИЕ: %s\n' "$*" >&2; }   # в начале файла warn заглушён
  gate() {
    local out rc=0
    out="$(backups_disk_gate "/srv/$1/backups" "/srv/$1/pgdata" "$2" 2>&1)" || rc=$?
    case "$out" in *ОШИБКА*) out=die ;; *ВНИМАНИЕ*) out=warn ;; '') out=- ;; *) out=other ;; esac
    printf '%s:%s ' "$rc" "$out"
  }
  got="$(gate same 0)$(gate same 1)$(gate lvm 0)$(gate lvm 1)$(gate raid 0)$(gate two 0)$(gate unknown 0)"
  [ "$got" = "1:die 0:warn 1:die 0:warn 1:die 0:- 0:- " ] \
    || echo "FAIL backups_disk_gate: та же ФС / том LVM / RAID на тех же дисках / разные диски / не определить — «$got»"
  echo "END"; true
) > "$TMP/disks.out" 2>&1 || true

# Блок без строки END оборвался раньше конца (ошибка самого блока) — его проверки не выполнены целиком.
for f in walarch pitrb walup pitrl wgnet disks; do
  if grep -q '^FAIL' "$TMP/$f.out"; then
    while IFS= read -r line; do bad "${line#FAIL }"; done < <(grep '^FAIL' "$TMP/$f.out")
  elif ! grep -qx 'END' "$TMP/$f.out"; then
    bad "блок $f оборвался до конца: $(tail -n 3 "$TMP/$f.out" | tr '\n' ' ')"
  else
    ok
  fi
done

printf 'test_lib.sh: проверок %s, отказов %s\n' "$((pass + fails))" "$fails"
[ "$fails" -eq 0 ]
