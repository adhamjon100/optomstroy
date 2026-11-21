#!/usr/bin/env bash
# Первичная установка серверного контура «Оптомстрой POS» на сервер заказчика (Linux + Docker; 16 §3.1, §11, §14.1
# шаги 1, 3, 4, 6, 8; инструкция — docs/ops/RUNBOOK.md §2, тестовая копия — §10). Повторный запуск безопасен
# (идемпотентен): существующие .env, секреты, данные и образы не перезаписываются, уже сделанные шаги пропускаются.
#
# Запуск — из каталога релиза (git-копия тега или распакованный архив репозитория), от root:
#   рабочий контур:
#   sudo bash infra/scripts/install.sh --domain api.<домен> --acme-email <e-mail> --age-recipient age1… \
#        [--tag <версия>] [--min-app-version android=X.Y.Z,windows=X.Y.Z] \
#        [--admin-phone +996XXXXXXXXX --admin-name "Фамилия Имя"] [--load-images <каталог с *.tar>]
#   тестовая копия на том же сервере (после рабочего контура; 16 §11):
#   sudo bash infra/scripts/install.sh --contour test --domain api-test.<домен> --age-recipient age1… \
#        --test-phones +996XXXXXXXXX[,+996…] [--tag <версия>]
#
# Что делает: проверяет ОС, Docker, диск, память и порты → группа optomstroy-secrets (GID 10100) и пользователь
# optomstroy → каталоги /opt/optomstroy/<контур> и /srv/optomstroy/<контур> → комплект и .env из
# infra/env/prod.env.example (+ test.env.example) → секреты openssl (значения не печатаются); в рабочем контуре —
# логин и пароль SMSPro, которые человек заказчика вводит сам (ввод скрыт) или создаёт заранее (RUNBOOK §2.4) →
# образы (сборка или загрузка) → сети → postgres → миграции → все сервисы → общий caddy (проект optomstroy-edge,
# порты 80/443) → проверка готовности → первая резервная копия (с базовой копией PITR, если BACKUP_PITR=on) → копия
# сертификатов caddy и метрики сервера (metrics_check.sh) по таймерам systemd →
# приглашение первого администратора (docs/ops/first_admin.md).
# Чего НЕ делает: не ставит Docker и пакеты ОС, не меняет firewall, DNS, часовой пояс, чужие службы и базы (16 §6.3) —
# это шаг 1 плана 16 §14.1 по согласованию с заказчиком. Отдельный диск для копий монтирует администратор (RUNBOOK §2.2).
# Сервер вне магазина (дата-центр): туннель WireGuard к 1С, firewall и пояс — вручную по RUNBOOK §11 (шаблоны
# infra/host/wireguard/); проверка — bin/host-net-check.sh (только читает).
#
# Коды выхода: 0 — готово; 1 — ошибка (сообщение без значений секретов); 2 — неверные параметры.
set -euo pipefail
set +x
umask 027

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
  cat <<'EOF'
Параметры:
  --contour prod|test      контур: рабочий (по умолчанию) или тестовая копия на том же сервере (16 §11)
  --domain NAME            имя сайта API (api.<домен>; для теста — api-test.<домен>); задаёт CADDY_SITE_ADDRESS и
                           PUBLIC_BASE_URL (для теста ещё CADDY_TEST_SITE_ADDRESS в .env рабочего контура)
  --acme-email EMAIL       e-mail для Let's Encrypt (CADDY_TLS; только рабочий контур)
  --age-recipient KEY      публичный ключ age для шифрования копий (BACKUP_AGE_RECIPIENT; age-keygen — на машине
                           держателя ключа, приватный ключ на сервер не кладётся)
  --tag TAG                тег образов optomstroy/api и optomstroy/backup (по умолчанию <версия pos-api>-<git sha>)
  --min-app-version LIST   MIN_APP_VERSION (по умолчанию версия из pos-app/pubspec.yaml для android и windows)
  --test-phones LIST       тестовая копия: номера для входа тестовым кодом (AUTH_OTP_TEST_PHONES, +996… через запятую)
  --admin-phone PHONE      телефон первого администратора (+996…); без него — вопрос в терминале или пропуск
  --admin-name NAME        ФИО первого администратора
  --admin-days N           срок приглашения, суток (1…30; по умолчанию INVITATION_TTL_DAYS)
  --skip-admin             не создавать приглашение администратора
  --load-images DIR        загрузить образы из DIR/*.tar (docker load) вместо сборки и скачивания — сервер без доступа
                           к npm и Docker Hub (в архиве: optomstroy/api, optomstroy/backup, caddy, postgres — RUNBOOK §2.4)
  --allow-same-disk        рабочий контур: разрешить копии на том же физическом диске, что и база (та же ФС, другой
                           раздел или том LVM) — только стенд или письменное исключение владельца (RUNBOOK §2.2, Q-374)
  --allow-small-ram        тестовая копия: продолжить при памяти сервера меньше 6 ГБ (16 §11 — тогда тест на другом хосте)
  --src DIR                корень релиза (по умолчанию — репозиторий, в котором лежит этот скрипт)
  --prod-dir DIR           каталог проекта (по умолчанию /opt/optomstroy/<контур>)
  --non-interactive        без вопросов: недостающие данные — ошибка
  --force-os               продолжить на непроверенной ОС (не Ubuntu 22.04/24.04, не Debian 12/13)
  -h, --help               эта справка
EOF
}

DOMAIN="" ACME_EMAIL="" AGE_RECIPIENT="" TAG="" MIN_APP="" ADMIN_PHONE="" ADMIN_NAME="" ADMIN_DAYS="" TEST_PHONES=""
SKIP_ADMIN=0 LOAD_DIR="" NON_INTERACTIVE=0 FORCE_OS=0 ALLOW_SAME_DISK=0 ALLOW_SMALL_RAM=0
while [ $# -gt 0 ]; do
  opt="$1" val=""
  case "$opt" in
    --domain|--acme-email|--age-recipient|--tag|--min-app-version|--admin-phone|--admin-name|--admin-days|\
    --load-images|--src|--prod-dir|--contour|--test-phones)
      [ $# -ge 2 ] || { printf 'нет значения для %s\n' "$opt" >&2; exit 2; }
      val="$2"; shift 2 ;;
    *) shift ;;
  esac
  case "$opt" in
    --contour) CONTOUR="$val" ;;
    --domain) DOMAIN="$val" ;;
    --acme-email) ACME_EMAIL="$val" ;;
    --age-recipient) AGE_RECIPIENT="$val" ;;
    --tag) TAG="$val" ;;
    --min-app-version) MIN_APP="$val" ;;
    --test-phones) TEST_PHONES="$val" ;;
    --admin-phone) ADMIN_PHONE="$val" ;;
    --admin-name) ADMIN_NAME="$val" ;;
    --admin-days) ADMIN_DAYS="$val" ;;
    --skip-admin) SKIP_ADMIN=1 ;;
    --load-images) LOAD_DIR="$val" ;;
    --allow-same-disk) ALLOW_SAME_DISK=1 ;;
    --allow-small-ram) ALLOW_SMALL_RAM=1 ;;
    --src) SRC_DIR="$val" ;;
    --prod-dir) PROD_DIR="$val" ;;
    --non-interactive) NON_INTERACTIVE=1 ;;
    --force-os) FORCE_OS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'неизвестный параметр: %s (см. --help)\n' "$opt" >&2; exit 2 ;;
  esac
done
if [ ! -t 0 ]; then NON_INTERACTIVE=1; fi
case "${CONTOUR:-prod}" in prod|test) ;; *) printf -- '--contour: prod или test\n' >&2; exit 2 ;; esac

resolve_dirs "$HERE"
[ -n "${SRC_DIR:-}" ] && [ -f "$SRC_DIR/infra/compose.prod.yml" ] \
  || die "не найден релиз: запустите скрипт из каталога репозитория (infra/scripts/install.sh) или укажите --src"
TEMPLATE="$SRC_DIR/infra/env/prod.env.example"
TEST_TEMPLATE="$SRC_DIR/infra/env/test.env.example"
[ -f "$TEMPLATE" ] || die "нет шаблона $TEMPLATE"
[ "$CONTOUR" = prod ] || [ -f "$TEST_TEMPLATE" ] || die "нет шаблона $TEST_TEMPLATE"

if [ -n "$DOMAIN" ]; then
  printf '%s' "$DOMAIN" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$' \
    || die "--domain: ожидается имя хоста, например api.example.kg (без https:// и пути)"
fi
if [ -n "$ACME_EMAIL" ]; then
  printf '%s' "$ACME_EMAIL" | grep -Eq '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' || die "--acme-email: неверный e-mail"
fi
if [ -n "$AGE_RECIPIENT" ]; then
  printf '%s' "$AGE_RECIPIENT" | grep -Eq '^age1[02-9ac-hj-np-z]{58}$' || die "--age-recipient: ожидается публичный ключ age1… (62 символа)"
fi
if [ -n "$TEST_PHONES" ]; then
  [ "$CONTOUR" = test ] || die "--test-phones — только для --contour test"
  printf '%s' "$TEST_PHONES" | grep -Eq '^\+996[0-9]{9}(,\+996[0-9]{9})*$' \
    || die "--test-phones: номера +996XXXXXXXXX через запятую, без пробелов («*» запрещено, ADR-109)"
fi
if [ -n "$TAG" ]; then valid_tag "$TAG" || die "--tag: допустимы буквы, цифры, . _ - (не latest)"; fi
if [ -n "$ADMIN_DAYS" ]; then
  case "$ADMIN_DAYS" in ''|*[!0-9]*) die "--admin-days: число 1…30" ;; esac
fi

# =====================================================================================================
log "1/12 Проверка сервера (контур $CONTOUR, проект $PROJECT)"
need_root
need_cmd awk sed grep find install cmp getent groupadd useradd openssl df id date mktemp stat
OS_ID="$(. /etc/os-release 2>/dev/null && echo "${ID:-}")"
OS_VER="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}")"
case "$OS_ID:$OS_VER" in
  ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) log "ОС: $OS_ID $OS_VER" ;;
  *)
    if [ "$FORCE_OS" -eq 1 ]; then
      warn "ОС $OS_ID $OS_VER не проверялась (продолжение по --force-os)"
    else
      die "ОС ${OS_ID:-?} ${OS_VER:-?} не проверялась; поддерживаются Ubuntu 22.04/24.04 и Debian 12/13 (или --force-os)"
    fi
    ;;
esac
case "$(uname -m)" in
  x86_64|aarch64) ;;
  *) die "архитектура $(uname -m) не поддерживается (нужна x86_64 или aarch64)" ;;
esac
check_docker
log "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'), Compose $(docker compose version --short)"

mem_mb="$(mem_total_mb)"
cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
[ "$mem_mb" -ge 2000 ] || die "памяти ${mem_mb} МБ — меньше минимума (4 GB, 16 §5)"
if [ "$CONTOUR" = test ]; then
  [ -f "$EDGE_DIR/compose.edge.yml" ] && [ -f "$EDGE_DIR/.env" ] \
    || die "тестовая копия ставится после рабочего контура: нет $EDGE_DIR (install.sh без --contour)"
  if [ "$mem_mb" -lt 6000 ] && [ "$ALLOW_SMALL_RAM" -eq 0 ]; then
    die "памяти ${mem_mb} МБ: рабочий контур и тестовая копия на одном сервере — от 6 ГБ (16 §11; рекомендуемый сервер — 8 ГБ); тест — на другом хосте или --allow-small-ram"
  fi
elif [ "$mem_mb" -lt 3500 ]; then
  warn "памяти ${mem_mb} МБ, минимум по 16 §5 — 4 GB; install.sh поставит профиль памяти 4 GB, но его может не хватить"
fi
[ "$cpus" -ge 2 ] || warn "процессоров: $cpus; минимум по 16 §5 — 2 vCPU"

free_gb() { # $1 — путь (ближайший существующий предок) → свободно, ГБ
  local p="$1"
  while [ ! -d "$p" ]; do p="$(dirname "$p")"; done
  df -Pk "$p" | awk 'NR == 2 { print int($4 / 1048576) }'
}
data_free="$(free_gb "$DATA_DIR")"
docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
docker_free="$(free_gb "$docker_root")"
if [ "$CONTOUR" = prod ]; then
  [ "$data_free" -ge 20 ] || die "свободно ${data_free} ГБ под $DATA_DIR — нужно не меньше 20 ГБ (16 §5: 80 ГБ SSD минимум)"
  [ "$data_free" -ge 60 ] || warn "свободно ${data_free} ГБ под $DATA_DIR; рекомендовано 160–250 ГБ с запасом на 2–3 года (16 §5)"
else
  [ "$data_free" -ge 10 ] || die "свободно ${data_free} ГБ под $DATA_DIR — тестовой копии нужно не меньше 10 ГБ"
fi
[ "$docker_free" -ge 5 ] || die "свободно ${docker_free} ГБ под $docker_root — для образов нужно не меньше 5 ГБ"
log "диск: под данные ${data_free} ГБ свободно, под образы ${docker_free} ГБ; память ${mem_mb} МБ; CPU ${cpus}"

if [ "$CONTOUR" = prod ]; then
  # 80/443 держит только общий caddy (optomstroy-edge); прежний caddy проекта optomstroy-prod — тоже наш.
  our_caddy="$(docker ps -q --filter label=com.docker.compose.service=caddy --filter "label=com.docker.compose.project=$EDGE_PROJECT")"
  our_caddy="$our_caddy$(docker ps -q --filter label=com.docker.compose.service=caddy --filter label=com.docker.compose.project=optomstroy-prod)"
  if [ -z "$our_caddy" ]; then
    if command -v ss >/dev/null 2>&1; then
      busy="$(ss -Hltn 2>/dev/null | awk '{ print $4 }' | grep -E '(^|[:.])(80|443)$' || true)"
      [ -z "$busy" ] || die "порты 80/443 уже заняты другой службой — освобождение только по согласованию с заказчиком (16 §6.3)"
    else
      warn "нет утилиты ss — свободность портов 80/443 не проверена"
    fi
  fi
fi
if command -v timedatectl >/dev/null 2>&1; then
  [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo no)" = "yes" ] \
    || warn "время не синхронизировано (timedatectl) — нужен NTP: TLS, OTP и журналы зависят от времени (16 §14.1 шаг 1)"
  # Контейнеры получают TZ из .env, а журналы хоста идут по поясу сервера (16 H-11, DEPLOY-021; таймер копии
  # сертификатов закреплён за Asia/Bishkek ниже). Сервер в дата-центре вне КР обычно приходит с UTC или поясом площадки.
  want_tz="$(env_get "$TEMPLATE" TZ)"
  [ ! -f "$ENV_FILE" ] || want_tz="$(env_get "$ENV_FILE" TZ)"
  want_tz="${want_tz:-Asia/Bishkek}"
  host_tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  [ "$host_tz" = "$want_tz" ] \
    || warn "часовой пояс сервера ${host_tz:-неизвестен}, ожидается $want_tz (16 H-11, DEPLOY-021): timedatectl set-timezone $want_tz — шаг 1 плана 16 §14.1, по согласованию (RUNBOOK §11.2); проверка — bin/host-net-check.sh"
fi

# =====================================================================================================
log "2/12 Группа $SECRETS_GROUP (GID $SECRETS_GID) и пользователь $OPS_USER"
if getent group "$SECRETS_GROUP" >/dev/null; then
  [ "$(getent group "$SECRETS_GROUP" | cut -d: -f3)" = "$SECRETS_GID" ] \
    || die "группа $SECRETS_GROUP существует с другим GID — нужен $SECRETS_GID (совпадает с compose.prod.yml group_add)"
else
  if getent group "$SECRETS_GID" >/dev/null; then
    die "GID $SECRETS_GID занят группой $(getent group "$SECRETS_GID" | cut -d: -f1) — согласуйте свободный GID и поменяйте его в compose.prod.yml и lib.sh"
  fi
  groupadd --system --gid "$SECRETS_GID" "$SECRETS_GROUP"
  log "создана группа $SECRETS_GROUP"
fi
if ! id "$OPS_USER" >/dev/null 2>&1; then
  useradd --system --user-group --home-dir "$(dirname "$PROD_DIR")" --no-create-home --shell /usr/sbin/nologin "$OPS_USER"
  log "создан системный пользователь $OPS_USER (без входа; администрирование — через sudo)"
fi

# =====================================================================================================
log "3/12 Каталоги"
parent="$(dirname "$PROD_DIR")"
[ -d "$parent" ] || install -d -m 755 -o root -g root "$parent"
install -d -m 750 -o "$OPS_USER" -g "$OPS_USER" "$PROD_DIR"
install -d -m 700 -o "$OPS_USER" -g "$OPS_USER" "$SECRETS_DIR" "$STATE_DIR"
install -d -m 750 -o "$APP_UID" -g "$APP_UID" "$PROD_DIR/onec-journal"
[ -d "$(dirname "$DATA_DIR")" ] || install -d -m 755 -o root -g root "$(dirname "$DATA_DIR")"
install -d -m 755 -o root -g root "$DATA_DIR"
install -d -m 700 -o "$PG_UID" -g "$PG_UID" "$DATA_DIR/pgdata"
install -d -m 755 -o "$APP_UID" -g "$APP_UID" "$DATA_DIR/media"
install -d -m 700 -o "$BACKUP_UID" -g "$BACKUP_UID" "$DATA_DIR/backups"
ensure_walspool   # спул WAL на диске базы (непрерывная копия, RUNBOOK §4.8)
if [ "$CONTOUR" = prod ]; then
  # Копии — на отдельном физическом диске (SERVER_REQUIREMENTS §1; RUNBOOK §2.2; 14 Q-374): потеря диска базы не должна
  # уносить копии. Та же файловая система или раздел / том LVM того же диска — ошибка без --allow-same-disk (lib.sh).
  backups_disk_gate "$DATA_DIR/backups" "$DATA_DIR/pgdata" "$ALLOW_SAME_DISK"
fi
PG_INITIALIZED=0
if [ -f "$DATA_DIR/pgdata/PG_VERSION" ]; then PG_INITIALIZED=1; fi
log "проект: $PROD_DIR; данные: $DATA_DIR (база уже создана: $([ "$PG_INITIALIZED" -eq 1 ] && echo да || echo нет))"

# =====================================================================================================
log "4/12 Комплект и .env"
install_kit "$SRC_DIR" "$PROD_DIR"
if [ ! -f "$ENV_FILE" ]; then
  install -m 600 -o "$OPS_USER" -g "$OPS_USER" "$TEMPLATE" "$ENV_FILE"
  if [ "$CONTOUR" = test ]; then
    env_apply_lines "$TEST_TEMPLATE" "$ENV_FILE"
    log ".env создан из prod.env.example и замен test.env.example (16 §11)"
  else
    log ".env создан из prod.env.example"
  fi
else
  chown "$OPS_USER:$OPS_USER" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  env_merge_template "$TEMPLATE" "$ENV_FILE"
  if [ "$CONTOUR" = test ]; then env_apply_test_for_added "$TEST_TEMPLATE" "$ENV_FILE"; fi
fi
env_normalize_empty "$ENV_FILE"

cur_api_tag="$(env_get "$ENV_FILE" API_TAG)"
if [ -n "$cur_api_tag" ] && [ -n "$TAG" ] && [ "$TAG" != "$cur_api_tag" ]; then
  die "контур уже установлен с API_TAG=$cur_api_tag; смена версии — infra/scripts/update.sh --tag $TAG"
fi
if [ -z "$cur_api_tag" ]; then
  if [ -z "$TAG" ]; then
    TAG="$(release_tag_from_src "$SRC_DIR")"
    [ -n "$TAG" ] || die "не удалось определить тег релиза (нет git) — укажите --tag <версия>"
    if src_is_dirty "$SRC_DIR"; then
      die "в каталоге релиза есть незакоммиченные изменения — соберите из чистого тега или укажите --tag явно"
    fi
  fi
  env_set "$ENV_FILE" API_TAG "$TAG"
  log ".env: API_TAG=$TAG"
fi
env_set_if_empty "$ENV_FILE" BACKUP_TAG "$(env_get "$ENV_FILE" API_TAG)"

cur_site="$(env_get "$ENV_FILE" CADDY_SITE_ADDRESS)"
if [ -n "$cur_site" ] && [ -n "$DOMAIN" ] && [ "$DOMAIN" != "$cur_site" ]; then
  die "в .env уже задан другой CADDY_SITE_ADDRESS; смена домена — вручную по RUNBOOK §2.6"
fi
if [ -n "$DOMAIN" ]; then
  env_set_if_empty "$ENV_FILE" CADDY_SITE_ADDRESS "$DOMAIN"
  env_set_if_empty "$ENV_FILE" PUBLIC_BASE_URL "https://$DOMAIN"
fi
if [ "$CONTOUR" = prod ]; then
  env_set_if_empty "$ENV_FILE" CADDY_TLS "$ACME_EMAIL"
else
  [ "$(env_get "$ENV_FILE" CADDY_SITE_ADDRESS)" != "$(env_get "$EDGE_DIR/.env" CADDY_SITE_ADDRESS)" ] \
    || die "имя сайта тестовой копии совпадает с рабочим (--domain api-test.<домен>, 16 §11)"
  env_set_if_empty "$ENV_FILE" AUTH_OTP_TEST_PHONES "$TEST_PHONES"
  if [ -z "$(env_get "$ENV_FILE" AUTH_OTP_TEST_CODE)" ]; then
    env_set "$ENV_FILE" AUTH_OTP_TEST_CODE "$(od -An -N4 -tu4 /dev/urandom | awk '{ printf "%06d", $1 % 1000000 }')"
    log ".env: создан AUTH_OTP_TEST_CODE (код входа тестовых номеров; смотреть: sudo grep AUTH_OTP_TEST_CODE $ENV_FILE)"
  fi
fi
env_set_if_empty "$ENV_FILE" BACKUP_AGE_RECIPIENT "$AGE_RECIPIENT"
if [ -z "$MIN_APP" ]; then
  app_ver="$(sed -n 's/^version:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' "$SRC_DIR/pos-app/pubspec.yaml" 2>/dev/null | head -n 1)"
  [ -z "$app_ver" ] || MIN_APP="android=$app_ver,windows=$app_ver"
fi
env_set_if_empty "$ENV_FILE" MIN_APP_VERSION "$MIN_APP"
if [ -z "$(env_get "$ENV_FILE" JWT_KEY_ID)" ]; then
  [ ! -s "$SECRETS_DIR/jwt_public.json" ] || die "JWT_KEY_ID пуст, а secrets/jwt_public.json уже есть — восстановите JWT_KEY_ID (RUNBOOK §7.1)"
  env_set "$ENV_FILE" JWT_KEY_ID "$CONTOUR-$(date +%Y%m%d)"
  log ".env: задан JWT_KEY_ID"
fi
apply_mem_profile "$ENV_FILE" "$mem_mb"
validate_env "$ENV_FILE"

# =====================================================================================================
log "5/12 Секреты (значения не выводятся)"
openssl version >/dev/null 2>&1 || die "openssl не работает"
if [ "$PG_INITIALIZED" -eq 1 ]; then
  for s in pg_password db_migrator_password database_url; do
    [ -s "$SECRETS_DIR/$s" ] \
      || die "база уже инициализирована, а secrets/$s нет — восстановите файл из защищённой копии (RUNBOOK §7), не генерируйте новый"
  done
fi
gen_hex_secret pg_password 24
gen_hex_secret db_migrator_password 24
# Пароль роли pos_backup: на новом кластере его применит initdb, на существующем — шаг 7 (pg_sync_backup_role).
gen_hex_secret db_backup_password 24
if [ ! -s "$SECRETS_DIR/database_url" ]; then
  app_pw="$(openssl rand -hex 24)"
  printf 'postgres://pos_app:%s@postgres:5432/%s\n' "$app_pw" "$(env_get "$ENV_FILE" POSTGRES_DB)" | write_secret database_url
  app_pw=""
  log "секрет создан: secrets/database_url (роль pos_app; значение не выводится)"
fi
gen_hex_secret otp_pepper 32
gen_hex_secret pin_pepper 32
if [ ! -s "$SECRETS_DIR/jwt_private.pem" ]; then
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 2>/dev/null | write_secret jwt_private.pem
  rm -f "$SECRETS_DIR/jwt_public.json"
  log "секрет создан: secrets/jwt_private.pem (ES256)"
fi
if [ ! -s "$SECRETS_DIR/jwt_public.json" ]; then
  jwt_public_entry "$(env_get "$ENV_FILE" JWT_KEY_ID)" "$SECRETS_DIR/jwt_private.pem" | write_secret jwt_public.json
  log "создан набор публичных ключей secrets/jwt_public.json"
fi
if [ "$CONTOUR" = test ]; then
  # SMS_PROVIDER=fake: учётные данные SMSPro рабочего контура не копируются (16 §11). Файлы нужны только потому,
  # что их монтирует compose.prod.yml; указатели SMSPRO_*_FILE в compose.staging.yml пустые.
  for s in $OPERATOR_SECRETS; do
    [ -f "$SECRETS_DIR/$s" ] || { : | write_secret "$s"; log "создан пустой secrets/$s (SMS в тестовой копии не отправляются)"; }
  done
else
  # Логин и пароль SMSPro вводит человек заказчика сам — здесь (ввод скрыт) или заранее командами RUNBOOK §2.4;
  # оператор установки значения не получает и не запрашивает (09 §6.12, SRC-B-122).
  for s in $OPERATOR_SECRETS; do
    if [ ! -s "$SECRETS_DIR/$s" ]; then
      if [ "$NON_INTERACTIVE" -eq 1 ]; then
        die "нет secrets/$s — человек заказчика создаёт его заранее (RUNBOOK §2.4) или вводит при запуске в терминале (ввод скрыт)"
      fi
      case "$s" in
        smspro_login) prompt="Логин SMSPro — вводит человек заказчика (ввод скрыт): " ;;
        smspro_password) prompt="Пароль SMSPro — вводит человек заказчика (ввод скрыт): " ;;
        *) prompt="Значение $s (ввод скрыт): " ;;
      esac
      value=""
      read -r -s -p "$prompt" value
      printf '\n'
      [ -n "$value" ] || die "пустое значение $s"
      printf '%s' "$value" | write_secret "$s"
      value=""
      log "секрет записан: secrets/$s"
    fi
  done
fi
if [ ! -f "$SECRETS_DIR/rclone.conf" ]; then
  : | write_secret rclone.conf
  log "создан пустой secrets/rclone.conf (внешняя копия не настроена — RUNBOOK §4.3)"
fi
fix_secret_perms
check_secrets
check_secret_consistency
compose_init
log "дополнения compose:$(compose_overlays_text)"

# =====================================================================================================
log "6/12 Образы"
if [ -n "$LOAD_DIR" ]; then
  [ -d "$LOAD_DIR" ] || die "--load-images: нет каталога $LOAD_DIR"
  for tarball in "$LOAD_DIR"/*.tar; do
    [ -f "$tarball" ] || continue
    log "docker load: $(basename "$tarball")"
    docker load -i "$tarball" >/dev/null
  done
fi
ensure_app_images "$SRC_DIR" "$(env_get "$ENV_FILE" API_TAG)" "$(env_get "$ENV_FILE" BACKUP_TAG)"
ensure_pulled "$(compose_image "$PROD_DIR/compose.prod.yml" postgres)"
if [ "$CONTOUR" = prod ]; then
  ensure_pulled "$(compose_image "$PROD_DIR/compose.edge.yml" caddy)"
fi

# =====================================================================================================
log "7/12 Сеть $EDGE_NET и PostgreSQL"
ensure_network "$EDGE_NET"
dc up -d postgres
wait_healthy postgres 240 || die "postgres не готов — bin/dc logs postgres (RUNBOOK §6)"
if [ "$PG_INITIALIZED" -eq 1 ]; then
  # Кластер создан раньше: initdb не перезапускается — пароль pos_backup и pg_read_all_data выдаются здесь (идемпотентно).
  pg_sync_backup_role
fi

# =====================================================================================================
log "8/12 Миграции и строки по умолчанию (migrate --seed, идемпотентно)"
if ! dc run --rm migrate; then
  die "миграции не применены — bin/dc logs migrate; сервисы api/worker не запускались (RUNBOOK §3.4)"
fi

# =====================================================================================================
log "9/12 Запуск сервисов, общий caddy и проверка готовности"
dc up -d
wait_healthy api 300 || die "api не стал healthy — bin/dc logs --tail 200 api (RUNBOOK §6)"
wait_healthy worker 180 || die "worker не стал healthy — bin/dc logs --tail 200 worker (RUNBOOK §6)"
case "$(container_state backup)" in
  healthy|starting|running) ;;
  *) die "backup не запущен — bin/dc logs backup" ;;
esac
if [ "$CONTOUR" = test ]; then
  site="$(env_get "$ENV_FILE" CADDY_SITE_ADDRESS)"
  prev_test_site="$(env_get "$EDGE_DIR/.env" CADDY_TEST_SITE_ADDRESS)"
  [ -z "$prev_test_site" ] || [ "$prev_test_site" = "$site" ] \
    || die "в $EDGE_DIR/.env уже задан другой CADDY_TEST_SITE_ADDRESS — смена имени вручную (RUNBOOK §10.4)"
  env_set "$EDGE_DIR/.env" CADDY_TEST_SITE_ADDRESS "$site"
  edge_up --force-recreate
elif [ "${KIT_EDGE_CHANGED:-0}" -eq 1 ] && [ "$(edge_state)" = running ]; then
  log "файлы общего caddy изменились — пересоздание (admin off: конфигурация читается только при старте)"
  edge_up --force-recreate
else
  edge_up
fi
case "$(edge_state)" in
  running) log "общий caddy ($EDGE_PROJECT): running" ;;
  *) die "общий caddy не запущен — sudo $EDGE_DIR/bin/dc-edge logs caddy (RUNBOOK §6.3)" ;;
esac
ready="$(api_ready_status)"
case "$ready" in
  ok) log "/health/ready: ok" ;;
  degraded) log "/health/ready: degraded — данные синхронизации устарели или их нет (ожидаемо, пока 1С не подключена; RUNBOOK §8.1)" ;;
  *) die "/health/ready: $ready — БД или очереди недоступны (RUNBOOK §6)" ;;
esac

# =====================================================================================================
log "10/12 Первая резервная копия"
if ls "$DATA_DIR/backups"/*.dump.age >/dev/null 2>&1; then
  log "копии уже есть — пропуск (расписание BACKUP_SCHEDULE)"
else
  dc run --rm backup once || die "резервная копия не создана — bin/dc logs backup; проверьте BACKUP_AGE_RECIPIENT (RUNBOOK §4)"
  log "первая зашифрованная копия создана в $DATA_DIR/backups"
fi

# =====================================================================================================
log "11/12 Копия сертификатов общего caddy и метрики сервера (таймеры systemd)"
if [ "$CONTOUR" = test ]; then
  log "тестовая копия: сертификаты общего caddy копирует рабочий контур — пропуск"
elif command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
  unit=/etc/systemd/system/optomstroy-caddy-backup
  cat > "$unit.service.tmp" <<EOF
[Unit]
Description=Оптомстрой POS: копия сертификатов общего caddy (RUNBOOK §4.1)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$PROD_DIR/bin/backup-caddy.sh
EOF
  cat > "$unit.timer.tmp" <<'EOF'
[Unit]
Description=Оптомстрой POS: ежедневная копия сертификатов общего caddy

[Timer]
OnCalendar=*-*-* 06:00:00 Asia/Bishkek
Persistent=true
RandomizedDelaySec=10min

[Install]
WantedBy=timers.target
EOF
  chmod 644 "$unit.service.tmp" "$unit.timer.tmp"
  mv -f "$unit.service.tmp" "$unit.service"
  mv -f "$unit.timer.tmp" "$unit.timer"
  systemctl daemon-reload
  systemctl enable --now optomstroy-caddy-backup.timer >/dev/null 2>&1 \
    || warn "таймер optomstroy-caddy-backup.timer не включён — systemctl status optomstroy-caddy-backup.timer"
  "$PROD_DIR/bin/backup-caddy.sh" || warn "первая копия сертификатов не сделана — sudo $PROD_DIR/bin/backup-caddy.sh (RUNBOOK §4.1)"
  # Метрики сервера каждые 10 минут (16 §8.4, §9 «Метрики минимум», OPS-014; RUNBOOK §6.4).
  ensure_timer optomstroy-metrics "Оптомстрой POS: метрики сервера (RUNBOOK §6.4)" "$PROD_DIR/bin/metrics_check.sh" '*:0/10' \
    && log "метрики сервера: таймер optomstroy-metrics.timer (каждые 10 минут; сигнал — secrets/healthchecks_metrics_url)"
else
  warn "systemd нет — копию сертификатов caddy и метрики запускайте по расписанию сами: $PROD_DIR/bin/backup-caddy.sh (ежедневно), $PROD_DIR/bin/metrics_check.sh (каждые 10 минут; RUNBOOK §4.1, §6.4)"
fi

# =====================================================================================================
log "12/12 Первый администратор (docs/ops/first_admin.md)"
if [ "$SKIP_ADMIN" -eq 0 ] && [ -z "$ADMIN_PHONE" ] && [ "$NON_INTERACTIVE" -eq 0 ]; then
  read -r -p "Телефон первого администратора (+996…; Enter — пропустить): " ADMIN_PHONE
  if [ -n "$ADMIN_PHONE" ] && [ -z "$ADMIN_NAME" ]; then
    read -r -p "ФИО администратора: " ADMIN_NAME
  fi
fi
if [ "$SKIP_ADMIN" -eq 1 ] || [ -z "$ADMIN_PHONE" ]; then
  log "приглашение администратора не создавалось; позже: sudo $PROD_DIR/bin/dc exec api node dist/admin/bootstrap/first-admin.cli.js --phone … --name \"…\""
else
  [ -n "$ADMIN_NAME" ] || die "для приглашения нужен --admin-name"
  admin_args=(--phone "$ADMIN_PHONE" --name "$ADMIN_NAME")
  if [ -n "$ADMIN_DAYS" ]; then admin_args+=(--days "$ADMIN_DAYS"); fi
  rc=0
  dc exec -T api node dist/admin/bootstrap/first-admin.cli.js "${admin_args[@]}" || rc=$?
  ADMIN_PHONE=""
  ADMIN_NAME=""
  admin_args=()
  case "$rc" in
    0) log "приглашение администратора: готово (вход — по SMS-коду на этот номер, затем установка PIN)" ;;
    3) warn "приглашение отклонено (номер занят или действует приглашение на другой номер) — docs/ops/first_admin.md §6" ;;
    2) warn "неверные данные приглашения (номер КР, ФИО 2…150 символов, срок 1…30) — повторите шаг командой выше" ;;
    *) warn "ошибка создания приглашения (код $rc) — bin/dc logs api; повтор безопасен" ;;
  esac
fi

printf '%s install %s %s ok (дополнения:%s)\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$CONTOUR" \
  "$(env_get "$ENV_FILE" API_TAG)" "$(compose_overlays_text)" >> "$STATE_DIR/releases.log"
chmod 600 "$STATE_DIR/releases.log"

site="$(env_get "$ENV_FILE" CADDY_SITE_ADDRESS)"
if [ "$CONTOUR" = test ]; then
  cat <<EOF

Тестовая копия установлена. Версия: $(env_get "$ENV_FILE" API_TAG). Каталог: $PROD_DIR. Данные: $DATA_DIR.
Дальше (docs/ops/RUNBOOK.md §10):
  1. Снаружи: curl -sI https://$site/health — 200 и валидный сертификат (A-запись $site → внешний IP сервера).
  2. Сборка pos-app для теста — с адресом https://$site/api/v1 (профиль staging); вход — номера AUTH_OTP_TEST_PHONES.
  3. 1С: только тестовая копия базы (ONEC_BASE_URL теста ≠ рабочей), RUNBOOK §8.4 с bin/ этого каталога.
Состояние: sudo $PROD_DIR/bin/dc ps; общий caddy: sudo $EDGE_DIR/bin/dc-edge ps
EOF
else
  cat <<EOF

Установка завершена. Версия: $(env_get "$ENV_FILE" API_TAG). Каталог проекта: $PROD_DIR. Данные: $DATA_DIR.
Дальше (docs/ops/RUNBOOK.md):
  1. Снаружи: curl -sI https://$site/health — 200 и валидный сертификат (A-запись $site → IP сервера, порт 443).
  2. Мониторинг: Uptime Kuma на другом хосте — https://$site/health каждые 60 с (16 §9); Healthchecks — RUNBOOK §6.4.
  3. Внешняя копия: BACKUP_REMOTE и secrets/rclone.conf (RUNBOOK §4.3); проверка восстановления — backup-restore-test.sh.
  4. Защищённая копия secrets/ и .env — у заказчика офлайн (16 §8.2); приватный ключ age — не на сервере.
  5. Устройства магазина — RUNBOOK §5; подключение 1С — RUNBOOK §8.4; тестовая копия — RUNBOOK §10.
  6. Сеть и время хоста: sudo $PROD_DIR/bin/host-net-check.sh (только читает); сервер вне магазина — RUNBOOK §11.
Состояние: sudo $PROD_DIR/bin/dc ps; общий caddy: sudo $PROD_DIR/bin/dc-edge ps
EOF
fi
