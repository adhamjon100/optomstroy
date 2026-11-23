#!/usr/bin/env bash
# Общие функции скриптов серверных контуров «Оптомстрой POS» (install.sh, update.sh, rotate-secret.sh,
# backup-restore-test.sh, restore-db.sh, backup-caddy.sh, dc, dc-edge). Подключается через `.`; сам ничего не выполняет.
# Основание: 16 §4.1–§4.4 (состав, секреты), §8 (бэкапы), §10 (обновления), §11 (тестовый контур), §14 (первичное
# развёртывание); процедуры — docs/ops/RUNBOOK.md. Значения секретов эти функции НЕ печатают: в выводе только имена
# файлов и переменных. Трассировка (set -x) запрещена — она показала бы значения.
#
# Контуры на одном сервере (16 §11):
#   prod — рабочий: проект optomstroy-prod, /opt/optomstroy/prod, данные /srv/optomstroy/prod;
#   test — тестовая копия: проект optomstroy-test, /opt/optomstroy/test, данные /srv/optomstroy/test;
#   edge — общий caddy (проект optomstroy-edge, единственный владелец портов 80/443), файлы — в каталоге prod.
# Раскладка каталога контура (16 §4.2):
#   /opt/optomstroy/<контур>  — каталог проекта compose: compose.*.yml, docker/postgres/initdb/, .env (600),
#                               secrets/ (700; файлы 640, группа optomstroy-secrets), bin/ (эти скрипты), state/ (700);
#                               у prod дополнительно compose.edge*.yml и caddy/ (Caddyfile.edge, sites/*.caddy)
#   /srv/optomstroy/<контур>  — данные: pgdata/ (999:999, 700), media/ (10001:10001, 755), backups/ (10002:10002, 700;
#                               для prod — отдельный диск, RUNBOOK §2.2), walspool/ (999:10002, 2770 — спул WAL на
#                               диске базы, RUNBOOK §4.8)
# Пути данных зашиты в compose.prod.yml / compose.staging.yml (volumes … device:); другой диск монтируется в /srv/optomstroy.

set +x

# ---------- Константы (совпадают с compose-файлами и образами; проверяет check_compose_prod.py) ----------
OPS_USER="optomstroy"
SECRETS_GROUP="optomstroy-secrets"   # check-secrets: allow (имя группы ОС, не секрет)
SECRETS_GID=10100
APP_UID=10001
BACKUP_UID=10002
PG_UID=999
DEFAULT_PROD_DIR="/opt/optomstroy/prod"
DATA_DIR="/srv/optomstroy/prod"
DEFAULT_TEST_DIR="/opt/optomstroy/test"
TEST_DATA_DIR="/srv/optomstroy/test"
EDGE_PROJECT="optomstroy-edge"
# Минимальная мажорная версия плагина Docker Compose (v1 `docker-compose` не поддерживается; плагин сейчас 5.x).
COMPOSE_MIN_MAJOR=2

# Секреты базового файла compose.prod.yml (все обязательны; rclone.conf может быть пустым, в тестовом контуре —
# и smspro_*: там SMS_PROVIDER=fake, указатели SMSPRO_*_FILE в compose.staging.yml пустые).
BASE_SECRETS="pg_password database_url db_migrator_password db_backup_password jwt_private.pem jwt_public.json otp_pepper pin_pepper smspro_login smspro_password rclone.conf"
# Создаются install.sh на сервере (openssl), значения не выводятся.
GENERATED_SECRETS="pg_password db_migrator_password db_backup_password database_url jwt_private.pem jwt_public.json otp_pepper pin_pepper"
# Вводит человек заказчика на сервере сам (учётные данные внешних систем; 09 §6.12, SRC-B-122; RUNBOOK §2.4).
OPERATOR_SECRETS="smspro_login smspro_password"
# Дополнения 1С: HTTP-сервис расширения (пользователь pos_hs, ключ X-POS-Client-Key) — набор целиком или ничего;
# OData (pos_integration, только чтение; режим extension — полная загрузка, срезы цен и остатков, список фото;
# odata_only — всё чтение) — пара целиком или ничего.
ONEC_HS_SECRETS="onec_hs_user onec_hs_password onec_hs_token"
ONEC_ODATA_SECRETS="onec_user onec_password"
ONEC_CA_SECRET="onec_ca.pem"   # check-secrets: allow (имя файла, не значение)
HEALTHCHECKS_SECRET="healthchecks_url"

# Файлы комплекта, которые копируются из infra/ релиза в каталог проекта (пути относительно infra/).
KIT_FILES="compose.prod.yml compose.prod.onec.yml compose.prod.onec-odata.yml compose.prod.onec-ca.yml compose.prod.healthchecks.yml compose.staging.yml docker/postgres/initdb/10-roles.sh docker/postgres/scripts/wal-archive.sh"
# Общий caddy (проект optomstroy-edge) — только в каталоге рабочего контура.
EDGE_KIT_FILES="compose.edge.yml compose.edge.test.yml caddy/Caddyfile.edge caddy/sites/prod.caddy caddy/sites/test.caddy"
KIT_SCRIPTS="lib.sh dc dc-edge install.sh update.sh rotate-secret.sh backup-restore-test.sh restore-db.sh backup-caddy.sh metrics_check.sh host-net-check.sh"
# Метка блока переноса владельца схемы pgboss в restore-db.sh (единый текст с RUNBOOK §3.6; update.sh берёт его оттуда).
PGBOSS_BLOCK_MARKER="# Схема очередей pgboss"
# Отдельная база учений PITR в кластере контура (backup-restore-test.sh): метки пишутся не в рабочую базу.
PITR_DRILL_DB="optomstroy_pitr_drill"

# Ключевые таблицы для сверки после восстановления (16 §8.5, критерий drill).
KEY_TABLES="products product_variants customers orders payments audit_logs"

# ---------- Вывод ----------
log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '[%s] ВНИМАНИЕ: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die()  { printf '[%s] ОШИБКА: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; exit 1; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "запустите через sudo: нужны права root (каталоги, владельцы, docker)"
  fi
}

need_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "не найдена команда: $c"
  done
}

# ---------- Контур и каталоги ----------
# contour_init prod|test: имя проекта, каталог по умолчанию, данные, сети, ожидаемое APP_ENV.
contour_init() {
  CONTOUR="$1"
  case "$CONTOUR" in
    prod)
      PROJECT="optomstroy-prod"; CONTOUR_DIR_DEFAULT="$DEFAULT_PROD_DIR"; EXPECTED_APP_ENV="prod" ;;
    test)
      PROJECT="optomstroy-test"; CONTOUR_DIR_DEFAULT="$DEFAULT_TEST_DIR"; DATA_DIR="$TEST_DATA_DIR"
      EXPECTED_APP_ENV="staging" ;;
    *) die "контур: prod или test (получено: ${CONTOUR:-пусто})" ;;
  esac
  EDGE_NET="optomstroy_${CONTOUR}_edge"
  BACKEND_NET="optomstroy_${CONTOUR}_backend"
  # Имя контейнера api, к которому обращается общий caddy (Compose: <проект>-<сервис>-1; caddy/sites/*.caddy).
  API_CONTAINER="${PROJECT}-api-1"
}

# contour_of_env <.env> → prod | test | пусто (по APP_ENV).
contour_of_env() {
  case "$(env_get "$1" APP_ENV)" in
    prod) echo prod ;;
    staging) echo test ;;
    *) echo "" ;;
  esac
}

# resolve_dirs <каталог скрипта>: CONTOUR, PROD_DIR (каталог проекта контура), SRC_DIR (корень релиза, если скрипт
# запущен из infra/scripts релиза), EDGE_DIR (каталог проекта optomstroy-edge = каталог рабочего контура).
# Приоритет PROD_DIR: --prod-dir → каталог над bin/, если там compose.prod.yml и .env → каталог контура по умолчанию.
# Контур: --contour (CONTOUR уже задан) → APP_ENV в .env найденного каталога → prod.
resolve_dirs() {
  local here="$1" found=""
  if [ -z "${PROD_DIR:-}" ] && [ -f "$here/../compose.prod.yml" ] && [ -f "$here/../.env" ]; then
    PROD_DIR="$(cd "$here/.." && pwd)"
  fi
  if [ -n "${PROD_DIR:-}" ] && [ -f "$PROD_DIR/.env" ]; then
    found="$(contour_of_env "$PROD_DIR/.env")"
  fi
  if [ -z "${CONTOUR:-}" ]; then
    CONTOUR="${found:-prod}"
  elif [ -n "$found" ] && [ "$found" != "$CONTOUR" ]; then
    die "каталог ${PROD_DIR} — контур $found, а указан --contour $CONTOUR"
  fi
  contour_init "$CONTOUR"
  PROD_DIR="${PROD_DIR:-$CONTOUR_DIR_DEFAULT}"
  if [ -z "${SRC_DIR:-}" ] && [ -f "$here/../compose.prod.yml" ] && [ -f "$here/../../pos-api/package.json" ]; then
    SRC_DIR="$(cd "$here/../.." && pwd)"
  fi
  case "$PROD_DIR" in
    /*) ;;
    *) die "каталог проекта должен быть абсолютным путём" ;;
  esac
  case "$PROD_DIR" in
    *[[:space:]]*) die "в пути каталога проекта не должно быть пробелов" ;;
  esac
  SECRETS_DIR="$PROD_DIR/secrets"   # check-secrets: allow (путь каталога)
  STATE_DIR="$PROD_DIR/state"
  ENV_FILE="$PROD_DIR/.env"
  if [ "$CONTOUR" = prod ]; then
    EDGE_DIR="$PROD_DIR"
  else
    EDGE_DIR="${EDGE_DIR:-$DEFAULT_PROD_DIR}"
  fi
}

# ---------- .env: чтение и запись без source (значения не исполняются) ----------
# Разбор — как у Docker Compose (compose-go dotenv): после «=» пробелы слева отбрасываются; значение в кавычках —
# до закрывающей кавычки; без кавычек — до « #» (пробел и решётка), затем пробелы справа. Поэтому строка
# `X=   # комментарий` для Compose — значение «# комментарий», а не пусто: в шаблонах комментарий пустой
# переменной стоит отдельной строкой выше (env_normalize_empty чинит старые .env).
# env_get <файл> <ИМЯ> → значение; пусто, если строки нет.
env_get() {
  awk -v k="$2" '
    index($0, k "=") == 1 {
      v = substr($0, length(k) + 2)
      sub(/^[ \t]+/, "", v)
      q = substr(v, 1, 1)
      if (q == "\"" || q == "\047") {
        v = substr(v, 2); i = index(v, q); if (i > 0) v = substr(v, 1, i - 1)
      } else {
        i = index(v, " #"); if (i > 0) v = substr(v, 1, i - 1)
        sub(/[ \t\r]+$/, "", v)
      }
      print v; exit
    }' "$1"
}

# env_keys <файл> → имена активных строк ИМЯ=… (по одному в строке).
env_keys() {
  awk '/^[ \t]*#/ { next } match($0, /^[A-Za-z_][A-Za-z0-9_]*=/) { print substr($0, 1, RLENGTH - 1) }' "$1"
}

# env_set <файл> <ИМЯ> <значение>: заменяет значение; встроенный комментарий сохраняется только при непустом
# значении (у пустого Compose прочитал бы комментарий как значение); нет строки — добавляет.
# Допустимы только «простые» значения (теги, URL, e-mail, списки версий) — без пробелов и кавычек.
env_set() {
  local file="$1" key="$2" val="$3" tmp
  case "$val" in
    *[!A-Za-z0-9._:/@,=+-]*) die "env_set: недопустимые символы в значении $key" ;;
  esac
  tmp="$(mktemp "$file.XXXXXX")"
  awk -v k="$key" -v v="$val" '
    BEGIN { done = 0 }
    index($0, k "=") == 1 && !done {
      rest = substr($0, length(k) + 2); c = ""
      if (v != "" && match(rest, /[ \t]+#/)) c = substr(rest, RSTART)
      print k "=" v c; done = 1; next
    }
    { print }
    END { if (!done) print k "=" v }' "$file" > "$tmp"
  chmod 600 "$tmp"
  chown --reference="$file" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file"
}

# env_set_if_empty <файл> <ИМЯ> <значение>: только если значение пусто (повторный запуск ничего не меняет).
env_set_if_empty() {
  if [ -z "$(env_get "$1" "$2")" ] && [ -n "$3" ]; then
    env_set "$1" "$2" "$3"
    log ".env: задана $2"
  fi
}

# env_normalize_empty <файл>: `ИМЯ=<пробелы># …` → `ИМЯ=` (пустое значение без комментария; права и владелец
# сохраняются). ENV_NORMALIZED — список исправленных имён.
env_normalize_empty() {
  local file="$1" tmp
  ENV_NORMALIZED="$(awk '/^[A-Za-z_][A-Za-z0-9_]*=[ \t]+#/ { sub(/=.*/, ""); printf " %s", $0 }' "$file")"
  [ -n "$ENV_NORMALIZED" ] || return 0
  tmp="$(mktemp "$file.XXXXXX")"
  sed -E 's/^([A-Za-z_][A-Za-z0-9_]*)=[[:space:]]+#.*$/\1=/' "$file" > "$tmp"
  chmod 600 "$tmp"
  chown --reference="$file" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file"
  log ".env: у пустых переменных убран встроенный комментарий (Compose читал его как значение):$ENV_NORMALIZED"
}

# env_apply_lines <файл с строками ИМЯ=…> <.env>: заменяет строки .env строками файла целиком (значения с пробелами
# и кавычками допустимы — строка переносится как есть); нет строки — добавляет. Для шаблона тестового контура.
env_apply_lines() {
  local src="$1" file="$2" tmp
  tmp="$(mktemp "$file.XXXXXX")"
  awk '
    NR == FNR {
      if ($0 ~ /^[ \t]*#/) next
      if (match($0, /^[A-Za-z_][A-Za-z0-9_]*=/)) { k = substr($0, 1, RLENGTH - 1); line[k] = $0; order[++n] = k }
      next
    }
    match($0, /^[A-Za-z_][A-Za-z0-9_]*=/) {
      k = substr($0, 1, RLENGTH - 1)
      if (k in line) { print line[k]; used[k] = 1; next }
    }
    { print }
    END { for (i = 1; i <= n; i++) if (!(order[i] in used)) print line[order[i]] }' "$src" "$file" > "$tmp"
  chmod 600 "$tmp"
  chown --reference="$file" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file"
}

# ---------- Секреты ----------
# write_secret <имя>: содержимое — из stdin; права 640, владелец optomstroy, группа optomstroy-secrets.
write_secret() {
  local name="$1" tmp
  tmp="$(umask 077 && mktemp "$SECRETS_DIR/.$name.XXXXXX")"
  cat > "$tmp"
  chown "$OPS_USER:$SECRETS_GID" "$tmp"
  chmod 640 "$tmp"
  mv -f "$tmp" "$SECRETS_DIR/$name"
}

# gen_hex_secret <имя> <байт>: создаёт, только если файла нет или он пуст.
gen_hex_secret() {
  if [ ! -s "$SECRETS_DIR/$1" ]; then
    openssl rand -hex "$2" | write_secret "$1"
    log "секрет создан: secrets/$1 (значение не выводится)"
  fi
}

# jwt_public_entry <kid> <файл закрытого ключа> → JSON-объект {"<kid>":"<PEM публичного ключа>"} в stdout.
jwt_public_entry() {
  openssl pkey -in "$2" -pubout 2>/dev/null \
    | awk -v kid="$1" 'BEGIN { printf "{\"%s\":\"", kid } { printf "%s\\n", $0 } END { print "\"}" }'
}

valid_kid() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# fix_secret_perms: каталог 700 (optomstroy), файлы 640 (optomstroy:optomstroy-secrets).
fix_secret_perms() {
  chown "$OPS_USER:$OPS_USER" "$SECRETS_DIR"
  chmod 700 "$SECRETS_DIR"
  find "$SECRETS_DIR" -maxdepth 1 -type f ! -name '.*' -exec chown "$OPS_USER:$SECRETS_GID" {} + -exec chmod 640 {} +
}

# count_present <список имён> → число непустых файлов в secrets/.
count_present() {
  local n=0 s
  for s in $1; do
    if [ -s "$SECRETS_DIR/$s" ]; then n=$((n + 1)); fi
  done
  echo "$n"
}

# set_state <список имён> → none | full | partial (набор секретов дополнения: целиком или ничего).
set_state() {
  local n total
  n="$(count_present "$1")"
  total="$(set -- $1; echo $#)"
  if [ "$n" -eq 0 ]; then echo none
  elif [ "$n" -eq "$total" ]; then echo full
  else echo partial
  fi
}

# may_be_empty <имя> → 0, если файл секрета может быть пустым (rclone.conf; smspro_* в тестовом контуре).
may_be_empty() {
  case "$1" in
    rclone.conf) return 0 ;;
    smspro_login|smspro_password) [ "${CONTOUR:-prod}" = test ] ;;
    *) return 1 ;;
  esac
}

# check_secrets: обязательные файлы есть; 1С — набор HTTP-сервиса целиком или ничего, пара OData — целиком или ничего.
check_secrets() {
  local s missing=""
  for s in $BASE_SECRETS; do
    if may_be_empty "$s"; then
      [ -f "$SECRETS_DIR/$s" ] || missing="$missing $s"
    elif [ ! -s "$SECRETS_DIR/$s" ]; then
      missing="$missing $s"
    fi
  done
  [ -z "$missing" ] || die "нет обязательных секретов в $SECRETS_DIR:$missing"   # check-secrets: allow (имена файлов)
  [ "$(set_state "$ONEC_HS_SECRETS")" != partial ] \
    || die "секреты HTTP-сервиса 1С заданы частично ($(count_present "$ONEC_HS_SECRETS") из 3: $ONEC_HS_SECRETS) — добавьте недостающие или уберите все (RUNBOOK §8.4)"
  [ "$(set_state "$ONEC_ODATA_SECRETS")" != partial ] \
    || die "пара секретов OData 1С задана частично ($ONEC_ODATA_SECRETS) — нужны обе или ни одной (RUNBOOK §8.4)"
}

# ---------- docker compose ----------
# compose_init: COMPOSE_ARGS — базовый файл, дополнения по наличию секретов (16 §4.4 «пусто — не монтировать») и
# для тестового контура compose.staging.yml ПОСЛЕДНИМ (имя проекта, сети, тома и APP_ENV=staging — из него).
compose_init() {
  COMPOSE_ARGS=(--project-directory "$PROD_DIR" -f "$PROD_DIR/compose.prod.yml")
  case "$(set_state "$ONEC_HS_SECRETS")" in
    full) COMPOSE_ARGS+=(-f "$PROD_DIR/compose.prod.onec.yml") ;;
    partial) die "секреты HTTP-сервиса 1С заданы частично — RUNBOOK §8.4" ;;
  esac
  case "$(set_state "$ONEC_ODATA_SECRETS")" in
    full) COMPOSE_ARGS+=(-f "$PROD_DIR/compose.prod.onec-odata.yml") ;;
    partial) die "пара секретов OData 1С задана частично — RUNBOOK §8.4" ;;
  esac
  if [ -s "$SECRETS_DIR/$ONEC_CA_SECRET" ]; then
    COMPOSE_ARGS+=(-f "$PROD_DIR/compose.prod.onec-ca.yml")
  fi
  if [ -s "$SECRETS_DIR/$HEALTHCHECKS_SECRET" ]; then
    COMPOSE_ARGS+=(-f "$PROD_DIR/compose.prod.healthchecks.yml")
  fi
  if [ "$CONTOUR" = test ]; then
    COMPOSE_ARGS+=(-f "$PROD_DIR/compose.staging.yml")
  fi
}

dc() {
  docker compose "${COMPOSE_ARGS[@]}" "$@"
}

# compose_overlays_text → человекочитаемый список подключённых дополнений (для журнала).
compose_overlays_text() {
  local a out=""
  for a in "${COMPOSE_ARGS[@]}"; do
    case "$a" in
      */compose.prod.*.yml|*/compose.staging.yml) out="$out $(basename "$a")" ;;
    esac
  done
  echo "${out:- нет}"
}

# ---------- Общий caddy (проект optomstroy-edge; 16 §4.4 прим. 4, §11) ----------
# edge_init: EDGE_ARGS — compose.edge.yml и, если в .env рабочего контура задан CADDY_TEST_SITE_ADDRESS,
# compose.edge.test.yml (сайт тестовой копии). Переменные подстановки — из .env каталога рабочего контура.
edge_init() {
  [ -f "$EDGE_DIR/compose.edge.yml" ] || die "нет $EDGE_DIR/compose.edge.yml — сначала установите рабочий контур (install.sh)"
  EDGE_ARGS=(--project-directory "$EDGE_DIR" -f "$EDGE_DIR/compose.edge.yml")
  if [ -n "$(env_get "$EDGE_DIR/.env" CADDY_TEST_SITE_ADDRESS)" ]; then
    EDGE_ARGS+=(-f "$EDGE_DIR/compose.edge.test.yml")
  fi
}

dce() {
  docker compose "${EDGE_ARGS[@]}" "$@"
}

# ensure_network <имя>: внешняя сеть edge-контура (bridge с выходом наружу). Сети не принадлежат ни одному проекту:
# их создают скрипты, поэтому `down` одного проекта не рвёт связь caddy с другим.
ensure_network() {
  if ! docker network inspect "$1" >/dev/null 2>&1; then
    docker network create --driver bridge "$1" >/dev/null
    log "создана сеть $1"
  fi
}

# ensure_edge_networks: сети, нужные общему caddy (prod всегда, test — если подключён сайт тестовой копии).
ensure_edge_networks() {
  ensure_network optomstroy_prod_edge
  if [ -n "$(env_get "$EDGE_DIR/.env" CADDY_TEST_SITE_ADDRESS)" ]; then
    ensure_network optomstroy_test_edge
  fi
}

# edge_state → running | exited | … | missing (контейнер caddy проекта optomstroy-edge).
edge_state() {
  local id
  id="$(docker ps -aq --filter "label=com.docker.compose.project=$EDGE_PROJECT" --filter label=com.docker.compose.service=caddy | head -n 1)"
  if [ -z "$id" ]; then echo missing; return 0; fi
  docker inspect --format '{{.State.Status}}' "$id" 2>/dev/null || echo missing
}

# migrate_legacy_caddy: комплект до 2026-11-19 держал caddy в проекте optomstroy-prod. Контейнер удаляется (иначе
# занятые 80/443 не дадут запустить общий caddy), сертификаты тома optomstroy-prod_caddy_data переносятся в том
# optomstroy-edge_caddy_data (лимиты Let's Encrypt, 16 §4.2). Повторный запуск ничего не делает.
migrate_legacy_caddy() {
  local old img
  old="$(docker ps -aq --filter label=com.docker.compose.project=optomstroy-prod --filter label=com.docker.compose.service=caddy)"
  if [ -n "$old" ]; then
    docker rm -f $old >/dev/null
    log "удалён прежний caddy проекта optomstroy-prod (порты 80/443 переходят к optomstroy-edge)"
  fi
  if docker volume inspect optomstroy-prod_caddy_data >/dev/null 2>&1 \
     && ! docker volume inspect "${EDGE_PROJECT}_caddy_data" >/dev/null 2>&1; then
    img="$(compose_image "$EDGE_DIR/compose.edge.yml" caddy)"
    docker volume create "${EDGE_PROJECT}_caddy_data" >/dev/null
    docker run --rm --network none -v optomstroy-prod_caddy_data:/from:ro -v "${EDGE_PROJECT}_caddy_data:/to" \
      --entrypoint /bin/sh "$img" -c 'cp -a /from/. /to/' \
      || die "не удалось перенести сертификаты в ${EDGE_PROJECT}_caddy_data — прежний том сохранён (RUNBOOK §6.3)"
    log "сертификаты перенесены: optomstroy-prod_caddy_data → ${EDGE_PROJECT}_caddy_data (прежний том можно удалить позже)"
  fi
}

# edge_up [--force-recreate]: сети, перенос прежнего caddy, запуск общего caddy.
edge_up() {
  edge_init
  ensure_edge_networks
  migrate_legacy_caddy
  dce up -d "$@" caddy
}

check_docker() {
  need_cmd docker
  docker info >/dev/null 2>&1 || die "Docker Engine не запущен или недоступен (systemctl status docker)"
  local v major
  v="$(docker compose version --short 2>/dev/null || true)"
  v="${v#v}"
  major="${v%%.*}"
  case "$major" in
    ''|*[!0-9]*) die "нужен плагин Docker Compose (docker compose) ${COMPOSE_MIN_MAJOR}.x или новее (не docker-compose v1); найдено: ${v:-нет}" ;;
  esac
  [ "$major" -ge "$COMPOSE_MIN_MAJOR" ] \
    || die "нужен плагин Docker Compose ${COMPOSE_MIN_MAJOR}.x или новее (не docker-compose v1); найдено: $v"
}

# check_buildx: сборка образов на сервере требует BuildKit (Dockerfile: `# syntax=`, `COPY --chmod`).
check_buildx() {
  docker buildx version >/dev/null 2>&1 \
    || die "нужен BuildKit (пакет docker-buildx-plugin): Dockerfile используют # syntax= и COPY --chmod; или --load-images"
}

# container_state <сервис> → healthy | unhealthy | starting | running | exited | … | missing
container_state() {
  local id
  id="$(dc ps -q "$1" 2>/dev/null | head -n 1)"
  if [ -z "$id" ]; then echo missing; return 0; fi
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || echo missing
}

# wait_healthy <сервис> <секунд>: 0 — healthy; 1 — не дождались (последнее состояние — в журнале).
wait_healthy() {
  local svc="$1" deadline st
  deadline=$(( $(date +%s) + $2 ))
  while :; do
    st="$(container_state "$svc")"
    if [ "$st" = "healthy" ]; then
      log "$svc: healthy"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      warn "$svc: не стал healthy за $2 с (состояние: $st); журнал — bin/dc logs --tail 100 $svc"
      return 1
    fi
    sleep 5
  done
}

# api_ready_status → ok | degraded | failed (GET /health/ready изнутри контейнера api; 08 §4.19.1).
api_ready_status() {
  local body st
  body="$(dc exec -T api wget -qO- -T 5 http://127.0.0.1:3000/health/ready 2>/dev/null || true)"
  st="$(printf '%s' "$body" | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p' | head -n 1)"
  echo "${st:-failed}"
}

# psql_super_quiet: SQL из stdin под суперпользователем внутри контейнера postgres (локальный сокет), без вывода.
# Сессия не журналирует операторы (log_statement, pg_stat_statements) — текст ALTER ROLE с паролем не сохраняется.
psql_super_quiet() {
  dc exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 --no-psqlrc -q -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null
}

# psql_super_at [<база>]: SQL из stdin под суперпользователем, вывод строк без заголовков (psql -At).
psql_super_at() {
  dc exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 --no-psqlrc -qAt -U "$POSTGRES_USER" -d "${1:-$POSTGRES_DB}"' sh "$@"
}

# pg_sync_backup_role: роль pos_backup — вход по паролю из secrets/db_backup_password, чтение всех данных
# (pg_read_all_data: схемы pgboss и pos_meta не покрыты GRANT миграций) и REPLICATION для базовой копии PITR
# (pg_basebackup; читает тот же объём данных, что pg_read_all_data) + строка pg_hba для репликации (pg_ensure_
# replication_hba). Идемпотентно; нужно для кластеров, созданных initdb до 2026-11-19 (тогда pos_backup была без
# пароля, а копию делал суперпользователь) и до 2026-11-19 (вечер; без REPLICATION).
pg_sync_backup_role() {
  local pw
  pw="$(tr -d '\r\n' < "$SECRETS_DIR/db_backup_password")"
  case "$pw" in ''|*[!0-9a-f]*) die "secrets/db_backup_password: ожидается hex-значение (создаёт install.sh)" ;; esac
  printf "SET log_statement = 'none';\nSET log_min_duration_statement = -1;\nSET pg_stat_statements.track_utility = off;\nALTER ROLE pos_backup LOGIN REPLICATION PASSWORD '%s';\nGRANT pg_read_all_data TO pos_backup;\n" "$pw" \
    | psql_super_quiet
  pw=""
  pg_ensure_replication_hba
  log "роль pos_backup: вход по secrets/db_backup_password, pg_read_all_data, REPLICATION (значение не выводится)"
}

# pg_ensure_replication_hba: строка `host replication pos_backup all scram-sha-256` в конце pg_hba.conf кластера
# (образ postgres заканчивает файл строкой `host all all all …`, а «all» не покрывает подключения репликации) и
# перечитывание конфигурации. Повторный запуск ничего не меняет. Тот же текст пишет initdb 10-roles.sh.
pg_ensure_replication_hba() {
  local out
  out="$(dc exec -T postgres sh -c 'f="$PGDATA/pg_hba.conf"
    if grep -Eq "^[[:space:]]*host[[:space:]]+replication[[:space:]]+pos_backup[[:space:]]" "$f"; then echo present; exit 0; fi
    printf "%s\n" "# optomstroy: базовая копия PITR — pg_basebackup роли pos_backup (RUNBOOK §4.8)" \
      "host replication pos_backup all scram-sha-256" >> "$f" && echo added')" \
    || die "pg_hba.conf: строка репликации pos_backup не добавлена — bin/dc logs postgres"
  case "$out" in
    *added*)
      printf 'SELECT pg_reload_conf();\n' | psql_super_quiet
      log "pg_hba.conf: добавлена строка репликации pos_backup (базовая копия PITR), конфигурация перечитана" ;;
    *present*) ;;
    *) die "pg_hba.conf: неожиданный ответ проверки строки репликации" ;;
  esac
}

# pg_sync_role_passwords: пароли ролей pos_app (secrets/database_url), pos_migrate (db_migrator_password),
# суперпользователя POSTGRES_USER (pg_password) и pos_backup — из текущих секретов. Нужна после восстановления на
# момент времени и до конца архива (restore-db.sh --to-time, --to-latest): физическая копия кластера возвращает хэши
# паролей на момент копии, а
# секреты могли смениться позже (rotate-secret.sh db-*). Значения не выводятся и не журналируются.
pg_sync_role_passwords() {
  local app mig su sql user v
  app="$(sed -E -n 's#^postgres(ql)?://[^:@/]+:([^@]*)@.*$#\2#p' "$SECRETS_DIR/database_url" | head -n 1)"
  mig="$(tr -d '\r\n' < "$SECRETS_DIR/db_migrator_password")"
  su="$(tr -d '\r\n' < "$SECRETS_DIR/pg_password")"
  user="$(env_get "$ENV_FILE" POSTGRES_USER)"
  case "$user" in ''|*[!a-z0-9_]*) die "POSTGRES_USER: ожидается имя из [a-z0-9_]" ;; esac
  for v in "$app" "$mig" "$su"; do
    case "$v" in ''|*[!0-9a-f]*) die "секреты паролей БД: ожидается hex-значение (создают install.sh и rotate-secret.sh)" ;; esac
  done
  sql="SET log_statement = 'none';
SET log_min_duration_statement = -1;
SET pg_stat_statements.track_utility = off;
ALTER ROLE pos_app PASSWORD '$app';
ALTER ROLE pos_migrate PASSWORD '$mig';
ALTER ROLE \"$user\" PASSWORD '$su';"
  printf '%s\n' "$sql" | psql_super_quiet
  sql="" app="" mig="" su=""
  pg_sync_backup_role
  log "пароли ролей pos_app, pos_migrate, $user, pos_backup — из текущих secrets/ (значения не выводятся)"
}

# ensure_walspool: спул WAL на диске базы (archive_command пишет, сервис backup читает и удаляет; RUNBOOK §4.8).
# Владелец 999 (postgres), группа 10002 (backup), 2770: setgid — новые файлы получают группу backup.
ensure_walspool() {
  install -d -m 2770 -o "$PG_UID" -g "$BACKUP_UID" "$DATA_DIR/walspool"
}

# walspool_orphaned <каталог проекта> <каталог данных>: код 0, если в спуле WAL остались файлы, а установленный
# compose.prod.yml архивацию WAL не ведёт (откат update.sh --rollback к версии без непрерывной копии): сегменты
# больше никто не зашифрует. Судить по compose-файлу, а не по wal-archive.sh: restore_kit_files возвращает файлы
# снимка, но не удаляет файлы, добавленные новым релизом, — скрипт остаётся и после отката.
walspool_orphaned() {
  [ -n "$(find "$2/walspool" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | head -n 1)" ] || return 1
  ! grep -q 'archive_command' "$1/compose.prod.yml" 2>/dev/null
}

# ---------- Схема pgboss: перенос владельца (RUNBOOK §3.6) ----------
# pgboss_transfer_sql <restore-db.sh> → текст блока переноса владельца (here-doc после метки PGBOSS_BLOCK_MARKER).
# Один текст на три места: RUNBOOK §3.6 = restore-db.sh (сверяет pos-api/test/db/migrate-seed.db-spec.ts п. 13,
# там же блок выполняется на настоящем PostgreSQL) и update.sh (берёт его отсюда; сверяет test_lib.sh).
pgboss_transfer_sql() {
  awk -v m="$PGBOSS_BLOCK_MARKER" -v open="<<'SQL'" '
    index($0, m) == 1 { seen = 1; next }
    seen && !inside && length($0) >= length(open) && substr($0, length($0) - length(open) + 1) == open { inside = 1; next }
    inside && $0 == "SQL" { exit }
    inside { print }' "$1"
}

# pg_transfer_pgboss_owner <restore-db.sh>: идемпотентный перенос владельца схемы pgboss на pos_migrate для баз,
# созданных до 2026-11-19 (схему тогда создавали api/worker под pos_app; migrate нового релиза иначе отказывает с
# PGBOSS_FOREIGN_OWNER). Схемы нет — ничего не делает. Прежние api/worker продолжают работать (RUNBOOK §3.6).
pg_transfer_pgboss_owner() {
  local sql owner
  sql="$(pgboss_transfer_sql "$1")"
  case "$sql" in
    *"ALTER SCHEMA pgboss OWNER TO pos_migrate"*) ;;
    *) die "не найден блок переноса владельца pgboss в $1 (метка «$PGBOSS_BLOCK_MARKER»)" ;;
  esac
  printf '%s\n' "$sql" | psql_super_quiet
  owner="$(printf "SELECT coalesce((SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'pgboss'), '-');\n" | psql_super_at)"
  case "$owner" in
    pos_migrate) log "схема pgboss: владелец pos_migrate (RUNBOOK §3.6; повторный запуск ничего не меняет)" ;;
    -) log "схемы pgboss ещё нет — её поставит migrate" ;;
    *) die "схема pgboss: владелец не pos_migrate после переноса — RUNBOOK §3.6, вручную" ;;
  esac
}

# ---------- Журнал миграций (update.sh --rollback) ----------
# pg_migration_journal → версии pos_meta.schema_migrations через запятую по возрастанию; «-» — журнала нет или пуст.
# Два запроса: таблица в тексте запроса разбирается до выполнения, и CASE по to_regclass ошибку «relation does not
# exist» не обходит (найдено учением 2026-11-19 на PostgreSQL 17.10).
pg_migration_journal() {
  local j t
  t="$(printf "SELECT to_regclass('pos_meta.schema_migrations') IS NOT NULL;\n" | psql_super_at)" || return 1
  case "$t" in
    f) j="-" ;;
    t) j="$(printf "SELECT coalesce(string_agg(version, ',' ORDER BY version), '-') FROM pos_meta.schema_migrations;\n" | psql_super_at)" \
         || return 1 ;;
    *) return 1 ;;
  esac
  journal_valid "$j" || return 1
  printf '%s\n' "$j"
}

journal_valid() { # $1 — «-» или 0001,0002,…
  printf '%s\n' "$1" | grep -Eq '^(-|[0-9]{4}(,[0-9]{4})*)$'
}

# journal_added <до> <после> → версии, которых не было «до» (через запятую; пусто — нет новых).
journal_added() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = split(a, x, ","); for (i = 1; i <= n; i++) seen[x[i]] = 1
    m = split(b, y, ","); out = ""
    for (j = 1; j <= m; j++) if (y[j] != "-" && y[j] != "" && !(y[j] in seen)) out = out (out == "" ? "" : ",") y[j]
    print out }'
}

# ---------- Восстановление по архиву WAL (PITR; restore-db.sh --to-time / --to-latest, backup-restore-test.sh) ----------
# pitr_to_utc "<ГГГГ-ММ-ДД ЧЧ:ММ[:СС]>" <часовой пояс> → ГГГГ-ММ-ДДTЧЧ:ММ:ССZ; код 2 — неверный формат или дата;
# код 3 — часового пояса нет в /usr/share/zoneinfo (GNU date молча считал бы такое время UTC). Пояс — имя tzdata
# (Asia/Bishkek), UTC или строка POSIX в угловых скобках (<+06>-6).
pitr_to_utc() {
  local e
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]\ [0-2][0-9]:[0-5][0-9]) ;;
    [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]\ [0-2][0-9]:[0-5][0-9]:[0-5][0-9]) ;;
    *) return 2 ;;
  esac
  case "$2" in
    UTC|'<'*) ;;
    *) [ -f "/usr/share/zoneinfo/$2" ] || return 3 ;;
  esac
  e="$(TZ="$2" date -d "$1" +%s 2>/dev/null)" || return 2
  date -u -d "@$e" '+%Y-%m-%dT%H:%M:%SZ'
}

# pitr_info_get <файл .info> <ключ> → значение строки ключ=значение.
pitr_info_get() {
  sed -n "s/^$2=//p" "$1" | head -n 1
}

# pitr_clusters <каталог pitr> → system_identifier кластеров, у которых есть базовые копии (по одному в строке).
pitr_clusters() {
  local d
  for d in "$1"/*/base; do
    ls "$d"/base_*.info >/dev/null 2>&1 || continue
    basename "$(dirname "$d")"
  done | grep -E '^[0-9]+$' | sort -u || true
}

# pitr_cluster_line <каталог pitr> <system_identifier> → «<sysid>: базовые копии <конец первой> … <конец последней>
# (UTC), последний сегмент WAL зашифрован <время UTC>» — чтобы отличить прежний кластер от нового (новый сервер).
pitr_cluster_line() {
  local d="$1/$2" first last wal
  first="$(for i in "$d"/base/base_*.info; do [ -f "$i" ] && pitr_info_get "$i" end_utc; done | sort | head -n 1)"
  last="$(for i in "$d"/base/base_*.info; do [ -f "$i" ] && pitr_info_get "$i" end_utc; done | sort | tail -n 1)"
  wal="$(find "$d/wal" -maxdepth 1 -type f -name '*.gz.age' -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1)"
  [ -z "$wal" ] || wal="$(date -u -d "@${wal%.*}" '+%Y-%m-%dT%H:%M:%SZ')"
  printf '%s: базовые копии %s … %s (UTC), последний сегмент WAL зашифрован %s\n' "$2" "${first:-?}" "${last:-?}" "${wal:-нет}"
}

# pitr_select_cluster <каталог pitr> [<system_identifier>] → кластер, из копий которого восстанавливать.
#   задан — он (код 4, если у него нет базовых копий); не задан — единственный кластер с базовыми копиями (пусто, если
#   копий нет вовсе); их несколько — код 3 и строки pitr_cluster_line по каждому в stdout: после установки на новый
#   сервер в pitr/ лежат прежний кластер (копия из внешнего хранилища) и новый пустой (первая базовая копия
#   install.sh), и выбор по одному времени восстановил бы пустой новый кластер (RUNBOOK §4.8).
pitr_select_cluster() {
  local all n c
  if [ -n "${2:-}" ]; then
    ls "$1/$2"/base/base_*.info >/dev/null 2>&1 || return 4
    printf '%s\n' "$2"
    return 0
  fi
  all="$(pitr_clusters "$1")"
  n="$(printf '%s\n' "$all" | grep -c . || true)"
  if [ "${n:-0}" -gt 1 ]; then
    for c in $all; do pitr_cluster_line "$1" "$c"; done
    return 3
  fi
  printf '%s\n' "$all"
}

# pitr_pick_base <каталог pitr> <момент UTC ГГГГ-ММ-ДДTЧЧ:ММ:ССZ> [<system_identifier>] → путь .info самой новой
# базовой копии, закончившейся раньше момента (конец копии — точка согласованности; раньше неё восстановиться
# нельзя); третий параметр — только копии этого кластера. Пусто — такой нет. Кластер выбирает вызывающий
# (pitr_select_cluster): без него копии разных кластеров сравнивались бы только по времени.
pitr_pick_base() {
  local i e
  for i in "$1"/${3:-*}/base/base_*.info; do
    [ -f "$i" ] || continue
    e="$(pitr_info_get "$i" end_utc)"
    [ -f "$(dirname "$i")/$(pitr_info_get "$i" file)" ] || continue
    printf '%s %s\n' "$e" "$i"
  done | awk -v t="$2" '$1 ~ /^[0-9][0-9][0-9][0-9]-/ && ("" $1) < ("" t)' | sort | tail -n 1 | cut -d' ' -f2-
}

# pitr_wal_list <каталог wal> <первый сегмент> <до, секунды эпохи> → имена (без .gz.age) для восстановления: все
# .history и сегменты с номером не меньше первого, зашифрованные не позже срока. Срок — момент восстановления плюс
# запас (restore-db.sh: 24 ч, --wal-hours): восстановлению нужна первая фиксация транзакции ПОСЛЕ момента, а ночью
# её может не быть часами; весь архив не распаковывается (каждый сегмент — 16 МиБ на диске базы).
pitr_wal_list() {
  local cut
  cut="$(printf '%s' "$2" | cut -c9-24)"
  {
    find "$1" -maxdepth 1 -type f -name '*.history.gz.age' -printf '%f\n' 2>/dev/null
    find "$1" -maxdepth 1 -type f -name '*.gz.age' ! -name '*.history.gz.age' ! -newermt "@$3" -printf '%f\n' 2>/dev/null
  } | awk -v cut="$cut" '
    { n = $0; sub(/\.gz\.age$/, "", n) }
    n ~ /^[0-9A-F]+\.history$/ { print n; next }
    n ~ /^[0-9A-F]+$/ && length(n) == 24 && ("" substr(n, 9, 16)) >= ("" cut) { print n }' | sort -u
}

# pitr_wal_gaps <список имён (pitr_wal_list)> [<сегментов на xlogid, по умолчанию 256>] → дыры в архиве WAL.
# Номер сегмента — xlogid × 256 + номер внутри (символы 9–16 и 17–24 имени; 256 — при размере сегмента 16 МиБ, как
# у PostgreSQL комплекта). Путь восстановления (recovery_target_timeline=latest): до первого сегмента последней линии
# времени — любая линия (на переключении номер есть у обеих), начиная с него — только последняя линия; номера
# мёртвой ветви старой линии дальше последнего сегмента новой не нужны. Непрерывно — код 0, вывода нет. Дыра — код 1
# и строка «<последний сегмент перед дырой> <первый сегмент после неё>». Без цели восстановления (--to-latest)
# PostgreSQL на первой дыре молча заканчивает восстановление — всё после неё было бы потеряно без сообщения.
pitr_wal_gaps() {
  awk -v per="${2:-256}" '
    function hex(s,   i, c, v) {
      v = 0
      for (i = 1; i <= length(s); i++) { c = index("0123456789ABCDEF", substr(s, i, 1)) - 1; if (c < 0) return -1; v = v * 16 + c }
      return v
    }
    function have(k) { return (k < first) ? (k in any) : (k in onmax) }
    function nm(k) { return (k < first) ? any[k] : onmax[k] }
    $0 ~ /^[0-9A-F]+$/ && length($0) == 24 {
      x = hex(substr($0, 9, 8)); s = hex(substr($0, 17, 8))
      if (x < 0 || s < 0) next
      n++; tl[n] = "" substr($0, 1, 8); num[n] = x * per + s; name[n] = $0
      if (n == 1 || tl[n] > maxt) maxt = tl[n]
    }
    END {
      if (n == 0) exit 0
      for (i = 1; i <= n; i++) {
        k = num[i]
        if (!(k in any)) any[k] = name[i]
        if (i == 1 || k < lo) lo = k
        if (tl[i] == maxt) {
          if (!(k in onmax)) onmax[k] = name[i]
          if (!seen || k < first) first = k
          if (!seen || k > hi) hi = k
          seen = 1
        }
      }
      for (k = lo; k <= hi; k++) {
        if (!have(k)) {
          for (j = k + 1; !have(j); j++) ;
          print nm(k - 1), nm(j)
          exit 1
        }
      }
    }' "$1"
}

# pitr_recovery_conf <момент UTC | latest> → строки postgresql.auto.conf для восстановления: WAL — из каталога
# pitr_restore_wal внутри PGDATA (готовит pitr_restore_into), последняя линия времени из архива.
#   момент — остановка перед первой фиксацией после него, затем promote (новая линия времени, запись разрешена);
#   latest — без цели восстановления (restore-db.sh --to-latest): PostgreSQL проигрывает весь WAL, который отдаёт
#            restore_command, и в конце архива сам переводит кластер в рабочий режим (recovery_target_action без цели
#            не действует). Фиксаций после момента для этого не нужно — в отличие от --to-time.
# restore-db.sh снимает настройки после восстановления (PITR_RESET_SQL).
pitr_recovery_conf() {
  if [ "$1" = latest ]; then
    printf '%s\n' \
      "# optomstroy PITR (restore-db.sh --to-latest): снимается после восстановления" \
      "restore_command = 'cp pitr_restore_wal/%f \"%p\"'" \
      "recovery_target_timeline = 'latest'"
    return 0
  fi
  printf '%s\n' \
    "# optomstroy PITR (restore-db.sh --to-time / backup-restore-test.sh): снимается после восстановления" \
    "restore_command = 'cp pitr_restore_wal/%f \"%p\"'" \
    "recovery_target_time = '$(printf '%s' "$1" | sed 's/T/ /; s/Z$/+00/')'" \
    "recovery_target_action = 'promote'" \
    "recovery_target_timeline = 'latest'"
}

# PITR_RESET_SQL: снять настройки восстановления после promote (ALTER SYSTEM переписывает postgresql.auto.conf).
PITR_RESET_SQL="ALTER SYSTEM RESET restore_command;
ALTER SYSTEM RESET recovery_target_time;
ALTER SYSTEM RESET recovery_target_action;
ALTER SYSTEM RESET recovery_target_timeline;
SELECT pg_reload_conf();"

# pitr_bytes_needed <.info> <число сегментов> [<размер распакованной базовой копии, байт>] → оценка места на диске
# базы (байт): распакованная базовая копия × 1,1 + (сегменты + 2) × 16 МиБ (+2 — RECOVERYXLOG и WAL после promote).
# Размер — третий параметр (restore-db.sh измеряет его при проверке ключа) или строка base_bytes в .info (backup.sh с
# 2026-11-19). Коэффициент к сжатой копии не годится: учение 2026-11-19 — около 7×, почти пустые сегменты в tar
# (-X fetch) сжимаются ещё сильнее. Код 1 — нет .info; код 2 — размер неизвестен (вызывающий измеряет его:
# pitr_base_raw_bytes).
pitr_bytes_needed() {
  local b="${3:-}"
  [ -s "$1" ] || return 1
  case "$b" in ''|*[!0-9]*) b="$(pitr_info_get "$1" base_bytes)" ;; esac
  case "$b" in ''|*[!0-9]*) return 2 ;; esac
  echo $(( b * 11 / 10 + ($2 + 2) * 16777216 ))
}

# pitr_base_raw_bytes <ключ age> <файл базовой копии> <образ backup> → размер tar до сжатия (байт): расшифровка и
# распаковка потоком в одноразовом контейнере без сети, только чтение (заодно проверяет ключ и целостность age и gzip).
pitr_base_raw_bytes() {
  docker run --rm --network none --user 0:0 --read-only --tmpfs /tmp --cap-drop ALL --cap-add DAC_READ_SEARCH \
      --security-opt no-new-privileges:true -v "$1:/run/restore/identity:ro" -v "$2:/run/restore/base.age:ro" \
      --entrypoint /bin/sh "$3" -c 'set -eu; set -o pipefail
        age -d -i /run/restore/identity /run/restore/base.age | gzip -dc | wc -c' | tr -dc 0-9
}

# pitr_restore_into <ключ age> <.info> <список WAL> <-v для каталога данных> <PGDATA в контейнере> <recovery conf>
#                   <образ postgres> <образ backup>
# Каталог данных восстановления: базовая копия (расшифровка — одноразовый контейнер backup под root только с чтением
# файлов, без сети; распаковка — контейнер postgres под uid 999, поток через канал: незашифрованная копия на диск
# копий не пишется) → настройки восстановления и recovery.signal → сегменты WAL по списку в PGDATA/pitr_restore_wal
# (каждый сегмент — отдельный tar в общем потоке, у распаковщика --ignore-zeros).
pitr_restore_into() {
  local identity="$1" info="$2" list="$3" vol="$4" pgd="$5" conf="$6" pgimg="$7" bkimg="$8" bdir base
  bdir="$(cd "$(dirname "$info")" && pwd)"
  base="$bdir/$(pitr_info_get "$info" file)"
  [ -s "$base" ] || die "нет файла базовой копии $(basename "$base")"
  docker run --rm --network none --user 0:0 --read-only --tmpfs /tmp --cap-drop ALL --cap-add DAC_READ_SEARCH \
      --security-opt no-new-privileges:true -v "$identity:/run/restore/identity:ro" -v "$base:/run/restore/base.age:ro" \
      --entrypoint age "$bkimg" -d -i /run/restore/identity /run/restore/base.age \
    | docker run --rm -i --network none --user 999:999 --cap-drop ALL --security-opt no-new-privileges:true \
      -v "$vol" -e "PITR_PGDATA=$pgd" -e "PITR_CONF=$conf" --entrypoint sh "$pgimg" -c '
        set -eu; umask 077
        mkdir -p "$PITR_PGDATA"; chmod 700 "$PITR_PGDATA"
        gzip -dc | tar -xf - -C "$PITR_PGDATA"
        [ -f "$PITR_PGDATA/backup_label" ] || { echo "в базовой копии нет backup_label" >&2; exit 1; }
        printf "%s\n" "$PITR_CONF" >> "$PITR_PGDATA/postgresql.auto.conf"
        : > "$PITR_PGDATA/recovery.signal"' \
    || die "базовая копия не распакована (ключ age, файл или место на диске)"
  docker run --rm --network none --user 0:0 --read-only --tmpfs /tmp:size=64m --cap-drop ALL --cap-add DAC_READ_SEARCH \
      --security-opt no-new-privileges:true -v "$identity:/run/restore/identity:ro" \
      -v "$(dirname "$bdir")/wal:/run/restore/wal:ro" -v "$list:/run/restore/list:ro" --entrypoint /bin/sh "$bkimg" -c '
        set -eu; set -o pipefail
        mkdir -p /tmp/w/pitr_restore_wal
        while IFS= read -r n; do
          age -d -i /run/restore/identity "/run/restore/wal/$n.gz.age" | gunzip > "/tmp/w/pitr_restore_wal/$n"
          tar -cf - -C /tmp/w "pitr_restore_wal/$n"
          rm -f "/tmp/w/pitr_restore_wal/$n"
        done < /run/restore/list' \
    | docker run --rm -i --network none --user 999:999 --cap-drop ALL --security-opt no-new-privileges:true \
      -v "$vol" -e "PITR_PGDATA=$pgd" --entrypoint sh "$pgimg" -c 'set -eu; umask 077; tar -xif - -C "$PITR_PGDATA"' \
    || die "сегменты WAL не распакованы (ключ age, архив или место на диске)"
}

# ensure_timer <имя> <описание> <команда> <OnCalendar>: служба и таймер systemd (идемпотентно). 1 — systemd нет.
ensure_timer() {
  local unit="/etc/systemd/system/$1"
  command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ] || return 1
  cat > "$unit.service.tmp" <<EOF
[Unit]
Description=$2
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$3
EOF
  cat > "$unit.timer.tmp" <<EOF
[Unit]
Description=$2 (таймер)

[Timer]
OnCalendar=$4
Persistent=true

[Install]
WantedBy=timers.target
EOF
  chmod 644 "$unit.service.tmp" "$unit.timer.tmp"
  mv -f "$unit.service.tmp" "$unit.service"
  mv -f "$unit.timer.tmp" "$unit.timer"
  systemctl daemon-reload
  systemctl enable --now "$1.timer" >/dev/null 2>&1 || warn "таймер $1.timer не включён — systemctl status $1.timer"
}

# ---------- Сервер вне магазина: туннель WireGuard к 1С (сценарий C-1; 16 §3.3, §12.2, §15.1; RUNBOOK §11) ----------
# Туннель — уровень хоста, вне compose (16 §4.3 «WG_*»): /etc/wireguard/wg0.conf (600), шаблон —
# infra/host/wireguard/wg0.conf.example. Функции только читают состояние (`wg show`), ключи пиров не печатают.
WG_IF_DEFAULT="wg0"
WG_MAX_HANDSHAKE_SEC=180   # PersistentKeepalive 25 с у магазина; 16 §15.1: «последний handshake < 3 мин»

# ip2int <IPv4> → целое; 1 — не IPv4.
ip2int() {
  case "$1" in ''|*[!0-9.]*|.*|*.|*..*) return 1 ;; esac
  local IFS=. o
  # shellcheck disable=SC2086
  set -- $1
  [ $# -eq 4 ] || return 1
  for o in "$@"; do
    [ "${#o}" -le 3 ] && [ "$((10#$o))" -le 255 ] || return 1
  done
  echo $(( (10#$1 << 24) + (10#$2 << 16) + (10#$3 << 8) + 10#$4 ))
}

# ip_in_cidr <IPv4> <сеть/биты> → 0, если адрес входит в сеть (без «/» — /32). IPv6 и «(none)» — 1.
ip_in_cidr() {
  local a b bits mask
  case "$2" in */*) bits="${2#*/}" ;; *) bits=32 ;; esac
  case "$bits" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bits" -le 32 ] || return 1
  a="$(ip2int "$1")" || return 1
  b="$(ip2int "${2%/*}")" || return 1
  if [ "$bits" -eq 0 ]; then mask=0; else mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF )); fi
  [ $(( a & mask )) -eq $(( b & mask )) ]
}

# url_hostname <URL> → имя хоста или IPv4 (без схемы, учётных данных, порта и пути; IPv6-литералы не поддерживаются).
url_hostname() {
  local h="${1#*://}"
  h="${h%%/*}"
  h="${h##*@}"
  printf '%s' "${h%:*}"
}

# host_ipv4 <имя или IPv4> → IPv4 (первый адрес getent); пусто — не разрешилось.
host_ipv4() {
  case "$1" in
    '') return 0 ;;
    *[!0-9.]*) getent ahostsv4 "$1" 2>/dev/null | awk 'NR == 1 { print $1 }' || true ;;
    *) printf '%s' "$1" ;;
  esac
}

# wg_peer_handshake_age <интерфейс> <IPv4> → секунды с последнего рукопожатия пира, в AllowedIPs которого входит
# адрес; «never» — рукопожатия не было; пусто — такого пира нет.
wg_peer_handshake_age() {
  local ifc="$1" ip="$2" key cidrs c peer="" ts
  while read -r key cidrs; do
    for c in $cidrs; do
      if ip_in_cidr "$ip" "$c"; then peer="$key"; break 2; fi
    done
  done < <(wg show "$ifc" allowed-ips 2>/dev/null | tr ',' ' ')
  [ -n "$peer" ] || return 0
  ts="$(wg show "$ifc" latest-handshakes 2>/dev/null | awk -v k="$peer" '$1 == k { print $2; exit }')"
  case "$ts" in
    ''|0|*[!0-9]*) echo never ;;
    *) echo $(( $(date +%s) - ts )) ;;
  esac
}

# in_time_window <ЧЧ:ММ-ЧЧ:ММ> <TZ> → 0, если сейчас внутри окна [начало, конец) (окно может переходить через
# полночь; формат как SYNC_NIGHT_WINDOW). Неверный формат — 0: сигнал лучше лишний, чем пропущенный.
# С 2026-11-20 скрипты комплекта её не вызывают (WG_HANDSHAKE_STALE — в любое время, 15 ADR-120); общая функция
# оставлена для проверок по расписанию, самопроверка — test_lib.sh.
in_time_window() {
  local w="$1" tz="${2:-Asia/Bishkek}" s e now
  case "$w" in [0-2][0-9]:[0-5][0-9]-[0-2][0-9]:[0-5][0-9]) ;; *) return 0 ;; esac
  s="${w%-*}"; e="${w#*-}"
  s=$(( 10#${s%:*} * 60 + 10#${s#*:} ))
  e=$(( 10#${e%:*} * 60 + 10#${e#*:} ))
  [ "$s" -lt 1440 ] && [ "$e" -lt 1440 ] || return 0
  now="$(TZ="$tz" date +%H:%M)"
  now=$(( 10#${now%:*} * 60 + 10#${now#*:} ))
  if [ "$s" -le "$e" ]; then
    [ "$now" -ge "$s" ] && [ "$now" -lt "$e" ]
  else
    [ "$now" -ge "$s" ] || [ "$now" -lt "$e" ]
  fi
}

# ---------- Один физический диск: копии и база (RUNBOOK §2.2) ----------
# Проверка install.sh по номеру устройства (`stat -c %d`) видит только одну и ту же файловую систему. Два раздела или
# два тома LVM одного диска её проходят, но от отказа диска не защищают — поэтому дополнительно сравниваются физические
# диски под файловыми системами (findmnt → lsblk --inverse, TYPE=disk; RAID и LVM — все диски под ними).
# path_disks <путь> → физические диски файловой системы пути через пробел (по алфавиту); пусто — не определить (нет
# findmnt или lsblk, сетевая ФС, ZFS и т. п.). У виртуального сервера разные виртуальные диски могут лежать на одном
# хранилище провайдера — это видно только из ответа провайдера.
path_disks() {
  local src
  command -v findmnt >/dev/null 2>&1 && command -v lsblk >/dev/null 2>&1 || return 0
  src="$(findmnt -no SOURCE -T "$1" 2>/dev/null | head -n 1 || true)"
  src="${src%%\[*}"   # btrfs: /dev/sda2[/@подтом]
  case "$src" in /dev/*) ;; *) return 0 ;; esac
  lsblk -nrso NAME,TYPE "$src" 2>/dev/null | awk '$2 == "disk" { print $1 }' | sort -u | tr '\n' ' ' | sed 's/ $//' || true
}

# common_disks "<диски>" "<диски>" → общие имена через пробел; пусто — общих нет или не определить.
common_disks() {
  local a b out=""
  for a in $1; do
    for b in $2; do
      if [ "$a" = "$b" ]; then out="$out${out:+ }$a"; fi
    done
  done
  printf '%s' "$out"
}

# backups_disk_gate <каталог копий> <каталог базы> <0|1 — --allow-same-disk>: проверка рабочего контура (install.sh
# шаг 3; SERVER_REQUIREMENTS §1; RUNBOOK §2.2; безопасное значение вопроса 14 Q-374 «рабочую систему на один диск не ставим»).
# Одна файловая система ИЛИ общий физический диск под ними (второй раздел, том LVM, другой массив RAID на тех же дисках)
# → ошибка; с --allow-same-disk → предупреждение (стенд или письменное исключение владельца). Диски не определить
# (path_disks пусто) → без вывода: разницу видит только ответ провайдера.
backups_disk_gate() {
  local backups="$1" pgdata="$2" allow="$3" shared why
  if [ "$(stat -c %d "$backups")" = "$(stat -c %d "$pgdata")" ]; then
    why="на том же диске (той же файловой системе), что и база"
  else
    shared="$(common_disks "$(path_disks "$backups")" "$(path_disks "$pgdata")")"
    [ -n "$shared" ] || return 0
    why="на другом разделе или томе того же физического диска, что и база ($shared): разные разделы одного диска от отказа диска не защищают"
  fi
  if [ "$allow" -eq 1 ]; then
    warn "копии $why (--allow-same-disk): при отказе диска теряются и база, и все копии на сервере — остаётся только копия вне сервера; только стенд или письменное исключение владельца (RUNBOOK §2.2, Q-374)"
  else
    die "$backups $why — смонтируйте отдельный физический диск копий (RUNBOOK §2.2); обход --allow-same-disk — только стенд или письменное исключение владельца (Q-374)"
  fi
}

# ---------- Образы ----------
image_exists() {
  docker image inspect "$1" >/dev/null 2>&1
}

# compose_image <compose-файл> <caddy|postgres> → точный образ из строки `image:` (caddy:X.Y.Z-alpine, postgres:17.N).
compose_image() {
  sed -n "s/^[[:space:]]*image:[[:space:]]*\\($2:[^[:space:]#]*\\).*/\\1/p" "$1" | head -n 1
}

# ensure_pulled <образ>: есть локально → ничего; иначе docker pull; нет сети — понятная ошибка ДО изменений контура.
ensure_pulled() {
  [ -n "$1" ] || die "внутренняя ошибка: не определён образ caddy/postgres в комплекте"
  image_exists "$1" && return 0
  log "docker pull $1"
  docker pull --quiet "$1" >/dev/null \
    || die "нет образа $1 и нет доступа к реестру — загрузите его (docker load, архив --load-images) и повторите"
}

# ensure_app_images <src> <api_tag> <backup_tag>: образ есть локально → пропуск; иначе сборка из исходников
# релиза (infra/docker/api/Dockerfile — стадия release, без фикстур 1С; infra/docker/backup).
ensure_app_images() {
  local src="$1" api_tag="$2" backup_tag="$3"
  if image_exists "optomstroy/api:$api_tag"; then
    log "образ optomstroy/api:$api_tag уже есть — сборка пропущена"
  else
    [ -n "$src" ] && [ -f "$src/infra/docker/api/Dockerfile" ] \
      || die "образа optomstroy/api:$api_tag нет, а исходники релиза не найдены (--src или docker load)"
    check_buildx
    log "сборка optomstroy/api:$api_tag (стадия release; несколько минут)"
    DOCKER_BUILDKIT=1 docker build --pull --target release -f "$src/infra/docker/api/Dockerfile" \
      -t "optomstroy/api:$api_tag" "$src"
  fi
  if image_exists "optomstroy/backup:$backup_tag"; then
    log "образ optomstroy/backup:$backup_tag уже есть — сборка пропущена"
  else
    [ -n "$src" ] && [ -f "$src/infra/docker/backup/Dockerfile" ] \
      || die "образа optomstroy/backup:$backup_tag нет, а исходники релиза не найдены (--src или docker load)"
    check_buildx
    log "сборка optomstroy/backup:$backup_tag"
    DOCKER_BUILDKIT=1 docker build --pull -t "optomstroy/backup:$backup_tag" "$src/infra/docker/backup"
  fi
}

valid_tag() {
  case "$1" in
    ''|latest|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# release_tag_from_src <src> → <версия pos-api>-<короткий sha> (git только читается); пусто, если не определить.
release_tag_from_src() {
  local src="$1" ver sha
  ver="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$src/pos-api/package.json" 2>/dev/null | head -n 1)"
  sha="$(git -C "$src" rev-parse --short=7 HEAD 2>/dev/null || true)"
  if [ -n "$ver" ] && [ -n "$sha" ]; then
    echo "$ver-$sha"
  fi
}

src_is_dirty() {
  [ -n "$(git -C "$1" status --porcelain --untracked-files=no 2>/dev/null || true)" ]
}

# mem_total_mb → объём памяти сервера, МБ.
mem_total_mb() {
  awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo
}

# apply_mem_profile <.env> <МБ>: на сервере меньше 7,5 ГБ — профиль памяти 4 GB (16 §4.4 прим. 2), только для пустых
# значений: настройки оператора и обновления (update.sh) их не перезаписывают.
apply_mem_profile() {
  local f="$1" mb="$2" before
  [ "$mb" -lt 7500 ] || return 0
  before="$(env_get "$f" PG_SHARED_BUFFERS)$(env_get "$f" PG_MEM_LIMIT)$(env_get "$f" API_MEM_LIMIT)$(env_get "$f" WORKER_MEM_LIMIT)"
  env_set_if_empty "$f" PG_SHARED_BUFFERS 512MB
  env_set_if_empty "$f" PG_MEM_LIMIT 1536M
  env_set_if_empty "$f" API_MEM_LIMIT 768M
  env_set_if_empty "$f" WORKER_MEM_LIMIT 768M
  [ -n "$before" ] || log ".env: профиль памяти 4 GB (памяти ${mb} МБ; 16 §4.4 прим. 2) — правка значений в .env, затем bin/dc up -d postgres api worker"
}

# ---------- Проверка .env контура ----------
# env_merge_template <шаблон> <.env>: добавляет в .env имена, которых там нет (новые переменные релиза), со
# значениями шаблона; существующие значения не трогает. Строка пустой переменной переносится без встроенного
# комментария. ENV_ADDED — список добавленных имён.
env_merge_template() {
  local tpl="$1" file="$2" k line
  ENV_ADDED=""
  for k in $(env_keys "$tpl"); do
    if ! env_keys "$file" | grep -qx "$k"; then
      if [ -z "$ENV_ADDED" ]; then
        printf '\n# --- добавлено %s из %s ---\n' "$(date '+%Y-%m-%d')" "$(basename "$tpl")" >> "$file"
      fi
      line="$(grep -m 1 "^$k=" "$tpl" | sed -E 's/^([A-Za-z_][A-Za-z0-9_]*)=[[:space:]]+#.*$/\1=/')"
      printf '%s\n' "$line" >> "$file"
      ENV_ADDED="$ENV_ADDED $k"
    fi
  done
  if [ -n "$ENV_ADDED" ]; then
    log ".env: добавлены новые переменные со значениями шаблона:$ENV_ADDED"
  fi
}

# env_apply_test_for_added <test.env.example> <.env>: тестовая копия — для имён, которые env_merge_template только что
# добавила из prod.env.example (ENV_ADDED), строки заменяются строками test.env.example целиком (как при создании
# .env, env_apply_lines; значения в кавычках переносятся как есть). Существующие значения не трогаются. Без этого
# новое имя с другим значением для теста (например, BACKUP_PITR: prod on, test off — 16 §11) пришло бы рабочим.
env_apply_test_for_added() {
  local tpl="$1" file="$2" tmp k got=""
  [ -n "${ENV_ADDED:-}" ] || return 0
  tmp="$(mktemp)"
  for k in $ENV_ADDED; do
    if grep -m 1 "^$k=" "$tpl" >> "$tmp"; then got="$got $k"; fi
  done
  if [ -s "$tmp" ]; then
    env_apply_lines "$tmp" "$file"
    log ".env тестовой копии: для новых имён применены замены $(basename "$tpl"):$got"
  fi
  rm -f "$tmp"
}

# validate_env <.env>: обязательные значения и запреты контура (16 §4.3, §11, OPS-027, DEPLOY-051…DEPLOY-055).
# Ошибки — только именами переменных, без значений.
validate_env() {
  local f="$1" k v bad="" names
  names="$(awk '/^[A-Za-z_][A-Za-z0-9_]*=[ \t]+#/ { sub(/=.*/, ""); printf " %s", $0 }' "$f")"
  [ -z "$names" ] || die "в $f у переменных:$names после «=» сразу комментарий — Compose прочитает его как значение (оставьте «ИМЯ=», комментарий — строкой выше)"
  for k in APP_ENV API_TAG BACKUP_TAG PUBLIC_BASE_URL MIN_APP_VERSION POSTGRES_USER POSTGRES_DB JWT_KEY_ID \
           SMS_PROVIDER ONEC_MODE BACKUP_AGE_RECIPIENT CADDY_SITE_ADDRESS; do
    [ -n "$(env_get "$f" "$k")" ] || bad="$bad $k"
  done
  if [ "$CONTOUR" = prod ] && [ -z "$(env_get "$f" CADDY_TLS)" ]; then bad="$bad CADDY_TLS"; fi
  [ -z "$bad" ] || die "в $f не заданы обязательные переменные:$bad"
  [ "$(env_get "$f" APP_ENV)" = "$EXPECTED_APP_ENV" ] || die "APP_ENV в контуре $CONTOUR — только $EXPECTED_APP_ENV"
  valid_tag "$(env_get "$f" API_TAG)" || die "API_TAG: нужен неизменяемый тег (буквы, цифры, . _ -; не latest)"
  valid_tag "$(env_get "$f" BACKUP_TAG)" || die "BACKUP_TAG: нужен неизменяемый тег (не latest)"
  valid_kid "$(env_get "$f" JWT_KEY_ID)" || die "JWT_KEY_ID: допустимы буквы, цифры, . _ -"
  case "$(env_get "$f" PUBLIC_BASE_URL)" in https://*) ;; *) die "PUBLIC_BASE_URL: нужен https://…" ;; esac
  case "$(env_get "$f" ONEC_MODE)" in
    extension|odata_only) ;;
    *) die "ONEC_MODE: на сервере extension или odata_only (fixtures — только CI-контур с образом test-fixtures, OPS-027)" ;;
  esac
  for k in OPENAPI_PUBLIC SMSPRO_TEST_FLAG; do
    [ "$CONTOUR" = test ] || [ "$(env_get "$f" "$k")" != "true" ] || die "$k=true запрещено в рабочем контуре (OPS-027)"
  done
  case "$(env_get "$f" LOG_LEVEL)" in
    debug|trace) [ "$CONTOUR" = test ] || die "LOG_LEVEL=debug|trace запрещён в рабочем контуре (SEC-061)" ;;
  esac
  case "$(env_get "$f" BACKUP_AGE_RECIPIENT)" in
    age1*) ;;
    *) die "BACKUP_AGE_RECIPIENT: нужен публичный ключ age (age1…); приватный ключ на сервер не кладётся" ;;
  esac
  # Пусто — как on (compose: ${BACKUP_PITR:-on}); update.sh добавляет строку из шаблона (тестовой копии — с заменой
  # test.env.example, env_apply_test_for_added).
  case "$(env_get "$f" BACKUP_PITR)" in
    on|'')
      [ "$CONTOUR" != test ] \
        || warn "BACKUP_PITR=on (или пусто) в тестовой копии — по 16 §11 и RUNBOOK §4.8 там off; включено намеренно — так и оставьте" ;;
    off) [ "$CONTOUR" = test ] \
           || warn "BACKUP_PITR=off — непрерывной копии WAL нет, при сбое теряется до суток (15 ADR-035; RUNBOOK §4.8)" ;;
    *) die "BACKUP_PITR: только on или off (RUNBOOK §4.8)" ;;
  esac
  case "$(env_get "$f" CADDY_SITE_ADDRESS)$(env_get "$f" CADDY_TEST_SITE_ADDRESS)" in
    *://*|*/*) die "CADDY_SITE_ADDRESS / CADDY_TEST_SITE_ADDRESS: только имя сайта без схемы и пути (api.<домен>)" ;;
  esac
  if [ "$CONTOUR" = prod ]; then
    [ "$(env_get "$f" SMS_PROVIDER)" = "smspro" ] || die "SMS_PROVIDER: в рабочем контуре только smspro (OPS-027)"
    [ "$(env_get "$f" AUTH_OTP_TEST_MODE)" != "true" ] || die "AUTH_OTP_TEST_MODE=true запрещено в рабочем контуре (OPS-027)"
    for k in AUTH_OTP_TEST_PHONES AUTH_OTP_TEST_CODE; do
      [ -z "$(env_get "$f" "$k")" ] || die "$k должна быть пустой в рабочем контуре (OPS-027)"
    done
    # Предупреждения: допустимо, но требует решения заказчика или ещё не готово.
    [ "$(env_get "$f" KIOSK_MODE)" != "true" ] \
      || warn "KIOSK_MODE=true — только по письменному разрешению заказчика (16 DEPLOY-053)"
    v="$(env_get "$f" AUTH_BIO_ALLOW_WEAK)"
    [ "$v" = "off" ] || warn "AUTH_BIO_ALLOW_WEAK=$v — только после записи T-BIO-026 (16 DEPLOY-055)"
    v="$(env_get "$f" AUTH_WINDOWS_HELLO_KEY)"
    [ "$v" = "off" ] || warn "AUTH_WINDOWS_HELLO_KEY=$v — только после записи T-BIO-031 (16 DEPLOY-055)"
    [ -n "$(env_get "$f" SMSPRO_SENDER)" ] || warn "SMSPRO_SENDER пуст — имя отправителя согласуется с SMSPro (Q-029)"
    [ -n "$(env_get "$f" BACKUP_REMOTE)" ] \
      || warn "BACKUP_REMOTE пуст — копии только на этом сервере; копия вне сервера обязательна (16 §8.1, RUNBOOK §4.3)"
  else
    # Тестовая копия (16 §11): своя 1С (копия или пусто), SMS не отправляются, вход — по тестовым номерам.
    [ "$(env_get "$f" SMS_PROVIDER)" = "fake" ] \
      || die "SMS_PROVIDER: в тестовой копии на сервере только fake (учётные данные SMSPro рабочего контура не копируются, 16 §11)"
    if [ "$(env_get "$f" AUTH_OTP_TEST_MODE)" = "true" ]; then
      [ -n "$(env_get "$f" AUTH_OTP_TEST_PHONES)" ] \
        || warn "AUTH_OTP_TEST_PHONES пуст — войти в тестовую копию нельзя (SMS не отправляются); номера — install.sh --test-phones"
      case "$(env_get "$f" AUTH_OTP_TEST_CODE)" in
        [0-9][0-9][0-9][0-9][0-9][0-9]) ;;
        *) die "AUTH_OTP_TEST_CODE: шесть цифр (создаёт install.sh тестового контура)" ;;
      esac
    fi
    case ",$(env_get "$f" AUTH_OTP_TEST_PHONES)," in *,\*,*) die "AUTH_OTP_TEST_PHONES: «*» разрешено только при APP_ENV=dev (ADR-109)" ;; esac
    if [ -n "$(env_get "$f" ONEC_BASE_URL)" ] && [ -f "$DEFAULT_PROD_DIR/.env" ] \
       && [ "$(env_get "$f" ONEC_BASE_URL)" = "$(env_get "$DEFAULT_PROD_DIR/.env" ONEC_BASE_URL)" ]; then
      die "ONEC_BASE_URL тестовой копии совпадает с рабочим — тестовая копия подключается только к тестовой копии 1С (16 §11)"
    fi
    [ -z "$(env_get "$f" BACKUP_REMOTE)" ] || warn "BACKUP_REMOTE в тестовой копии не нужен (16 §11: копии теста — только локально)"
  fi
  if [ -z "$(env_get "$f" ONEC_BASE_URL)" ]; then
    log "ONEC_BASE_URL пуст — 1С не подключена; синхронизация будет сообщать об ошибке конфигурации (RUNBOOK §8.1)"
    [ "$(env_get "$f" QR_PROVIDER)" != "onec" ] \
      || warn "QR_PROVIDER=onec без подключённой 1С — QR не будет формироваться; до приёмки методов QR — none (DEPLOY-051)"
  elif [ "$(env_get "$f" ONEC_MODE)" = "odata_only" ] && [ "$(set_state "$ONEC_ODATA_SECRETS")" != full ]; then
    warn "ONEC_MODE=odata_only без пары секретов OData (onec_user, onec_password) — синхронизация не запустится (RUNBOOK §8.4)"
  elif [ "$(env_get "$f" ONEC_MODE)" = "extension" ] && [ "$(set_state "$ONEC_HS_SECRETS")" != full ]; then
    warn "ONEC_BASE_URL задан, а секретов HTTP-сервиса 1С нет — синхронизация не запустится (RUNBOOK §8.4)"
  elif [ "$(env_get "$f" ONEC_MODE)" = "extension" ] && [ "$(set_state "$ONEC_ODATA_SECRETS")" != full ]; then
    warn "ONEC_MODE=extension без пары секретов OData (onec_user, onec_password) — полной загрузки справочников, срезов цен и остатков и списка фото не будет (RUNBOOK §8.4)"
  fi
  return 0
}

# check_secret_consistency: kid активного ключа есть в наборе; database_url — роль pos_app, хост postgres,
# база POSTGRES_DB (значения не печатаются).
check_secret_consistency() {
  local kid db url_user url_host url_db
  kid="$(env_get "$ENV_FILE" JWT_KEY_ID)"
  grep -q "\"$kid\":" "$SECRETS_DIR/jwt_public.json" \
    || die "secrets/jwt_public.json не содержит ключ активного JWT_KEY_ID (RUNBOOK §7.1)"
  openssl pkey -in "$SECRETS_DIR/jwt_private.pem" -noout 2>/dev/null \
    || die "secrets/jwt_private.pem не читается как закрытый ключ"
  db="$(env_get "$ENV_FILE" POSTGRES_DB)"
  url_user="$(sed -E -n 's#^postgres(ql)?://([^:@/]+):.*$#\2#p' "$SECRETS_DIR/database_url" | head -n 1)"
  url_host="$(sed -E -n 's#^postgres(ql)?://[^@]*@([^:/]+).*$#\2#p' "$SECRETS_DIR/database_url" | head -n 1)"
  url_db="$(sed -E -n 's#^postgres(ql)?://[^@]*@[^/]*/([^/?[:space:]]+).*$#\2#p' "$SECRETS_DIR/database_url" | head -n 1)"
  [ "$url_user" = "pos_app" ] || die "secrets/database_url: пользователь должен быть pos_app (07 DATA-012)"
  [ "$url_host" = "postgres" ] || die "secrets/database_url: хост должен быть postgres (сервис compose)"
  [ "$url_db" = "$db" ] || die "secrets/database_url: имя базы не совпадает с POSTGRES_DB в .env"
}

# ---------- Комплект ----------
# kit_files → файлы комплекта текущего контура (prod — с файлами общего caddy).
kit_files() {
  if [ "$CONTOUR" = prod ]; then echo "$KIT_FILES $EDGE_KIT_FILES"; else echo "$KIT_FILES"; fi
}

# install_kit <src> <prod_dir>: копирует файлы комплекта из <src>/infra в каталог проекта; KIT_EDGE_CHANGED=1,
# если изменились файлы общего caddy (Caddy с `admin off` перечитывает их только при пересоздании контейнера).
install_kit() {
  local src="$1" dst="$2" f s
  KIT_EDGE_CHANGED=0
  for f in $(kit_files); do
    [ -f "$src/infra/$f" ] || die "в исходниках нет infra/$f"
    case " $EDGE_KIT_FILES " in
      *" $f "*) cmp -s "$src/infra/$f" "$dst/$f" 2>/dev/null || KIT_EDGE_CHANGED=1 ;;
    esac
    install -D -m 644 -o root -g root "$src/infra/$f" "$dst/$f"
  done
  # initdb-скрипт и archive_command читает процесс postgres (uid 999), Caddyfile — процесс caddy: каталоги должны
  # быть проходимы.
  chmod 755 "$dst/docker" "$dst/docker/postgres" "$dst/docker/postgres/initdb" "$dst/docker/postgres/scripts"
  if [ "$CONTOUR" = prod ]; then chmod 755 "$dst/caddy" "$dst/caddy/sites"; fi
  for s in $KIT_SCRIPTS; do
    [ -f "$src/infra/scripts/$s" ] || die "в исходниках нет infra/scripts/$s"
    install -D -m 750 -o root -g root "$src/infra/scripts/$s" "$dst/bin/$s"
  done
  chmod 640 "$dst/bin/lib.sh"
}

# snapshot_kit <prod_dir> <каталог>: копия текущих файлов комплекта и .env (для отката update.sh --rollback).
snapshot_kit() {
  local src="$1" dst="$2" f
  rm -rf "$dst"
  mkdir -p "$dst"
  chmod 700 "$dst"
  for f in $(kit_files); do
    if [ -f "$src/$f" ]; then
      install -D -m 644 "$src/$f" "$dst/$f"
    fi
  done
  install -m 600 "$src/.env" "$dst/.env"
}

# restore_kit_files <снимок> <prod_dir>: вернуть файлы комплекта из снимка (без .env); KIT_EDGE_CHANGED=1, если
# файлы общего caddy отличались.
restore_kit_files() {
  local snap="$1" dst="$2" f
  KIT_EDGE_CHANGED=0
  for f in $(kit_files); do
    if [ -f "$snap/$f" ]; then
      case " $EDGE_KIT_FILES " in
        *" $f "*) cmp -s "$snap/$f" "$dst/$f" 2>/dev/null || KIT_EDGE_CHANGED=1 ;;
      esac
      install -D -m 644 -o root -g root "$snap/$f" "$dst/$f"
    fi
  done
}
