#!/usr/bin/env bash
# Обновление серверного контура «Оптомстрой POS» до новой версии и откат (16 §10.1–§10.4; RUNBOOK §3).
#
# Обновление — из каталога НОВОГО релиза (git-копия тега или распакованный архив), от root; сначала тестовая копия
# (16 §10.3 шаг 1), затем рабочий контур:
#   sudo bash infra/scripts/update.sh --contour test [--tag <версия>] [--yes]
#   sudo bash infra/scripts/update.sh [--tag <версия>] [--yes]
# Откат на версию до последнего обновления:
#   sudo /opt/optomstroy/<контур>/bin/update.sh --rollback [--yes] [--code-only]
# --rollback сверяет журнал миграций базы с состоянием до обновления (state/last_update, MIGRATIONS_BEFORE): новых
# миграций нет — откат по тегу образов (migrate прежней версии подтверждает журнал); обновление применило миграции —
# отказ: мигратор прежней версии их не знает (MIGRATION_MISSING_FILE), откат базы — восстановление копии, сделанной
# перед обновлением (restore-db.sh), порядок — в сообщении и RUNBOOK §3.4. --code-only — прежний откат только кода
# при expand-миграциях (16 §10.4 строка 1): база не откатывается, сервисы поднимаются без migrate (--no-deps).
#
# Порядок обновления: проверки → образы новой версии (сборка или загрузка; caddy и postgres — тоже ДО остановки,
# сервис работает) → роль pos_backup, владелец схемы pgboss (RUNBOOK §3.6; идемпотентно) → остановка worker
# (16 §10.3 шаг 2) → резервная копия (шаг 3; без неё обновление не продолжается) и журнал миграций до обновления →
# снимок комплекта и .env для отката → новый комплект, теги в .env, новые переменные шаблона → миграции migrate
# (шаг 5) → пересоздание сервисов (шаг 6) и общего caddy, если его файлы изменились (только рабочий контур) →
# проверка готовности → базовая копия PITR, если её ещё нет (BACKUP_PITR=on) → запись в state/releases.log.
# Сбой на любом шаге между остановкой worker и успешной миграцией (обработчик EXIT): комплект и .env возвращаются из
# снимка, worker старой версии запускается снова, запись «aborted: <шаг>» — в releases.log (16 §10.4).
# При ошибке проверки после запуска скрипт НЕ откатывает сам: печатает подсказку отката (--rollback) — решение
# принимает человек по журналам (RUNBOOK §3.4).
#
# Коды выхода: 0 — готово; 1 — ошибка (контур оставлен в состоянии, описанном в сообщении); 2 — неверные параметры.
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
  --contour prod|test  контур (по умолчанию prod; из установленного bin/ — по APP_ENV в .env)
  --tag TAG            новая версия (тег optomstroy/api и optomstroy/backup); по умолчанию <версия pos-api>-<git sha>
  --backup-tag TAG     отдельный тег optomstroy/backup (по умолчанию = --tag)
  --load-images DIR    загрузить образы из DIR/*.tar (docker load) вместо сборки и скачивания (caddy, postgres — тоже)
  --src DIR            корень нового релиза (по умолчанию — репозиторий, в котором лежит скрипт)
  --prod-dir DIR       каталог проекта (по умолчанию /opt/optomstroy/<контур>)
  --rollback           вернуть версию и комплект, действовавшие до последнего обновления (если обновление не
                       применило миграций; иначе — отказ и порядок восстановления копии, RUNBOOK §3.4)
  --code-only          с --rollback: откатить только образы и комплект, даже если миграции применены (только
                       expand-миграции, 16 §10.4; база не откатывается, сервисы — без migrate)
  --overwrite-snapshot перезаписать снимок отката, хотя прошлое обновление не завершилось записью «ok»
  --yes                не спрашивать подтверждение
  -h, --help           эта справка
EOF
}

TAG="" BACKUP_TAG_NEW="" LOAD_DIR="" ROLLBACK=0 ASSUME_YES=0 OVERWRITE_SNAPSHOT=0 CODE_ONLY=0
while [ $# -gt 0 ]; do
  opt="$1" val=""
  case "$opt" in
    --tag|--backup-tag|--load-images|--src|--prod-dir|--contour)
      [ $# -ge 2 ] || { printf 'нет значения для %s\n' "$opt" >&2; exit 2; }
      val="$2"; shift 2 ;;
    *) shift ;;
  esac
  case "$opt" in
    --contour) CONTOUR="$val" ;;
    --tag) TAG="$val" ;;
    --backup-tag) BACKUP_TAG_NEW="$val" ;;
    --load-images) LOAD_DIR="$val" ;;
    --src) SRC_DIR="$val" ;;
    --prod-dir) PROD_DIR="$val" ;;
    --rollback) ROLLBACK=1 ;;
    --code-only) CODE_ONLY=1 ;;
    --overwrite-snapshot) OVERWRITE_SNAPSHOT=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'неизвестный параметр: %s (см. --help)\n' "$opt" >&2; exit 2 ;;
  esac
done
case "${CONTOUR:-prod}" in prod|test) ;; *) printf -- '--contour: prod или test\n' >&2; exit 2 ;; esac
[ "$CODE_ONLY" -eq 0 ] || [ "$ROLLBACK" -eq 1 ] || { printf -- '--code-only — только вместе с --rollback\n' >&2; exit 2; }

need_root
need_cmd awk sed grep find install cmp openssl date
check_docker
resolve_dirs "$HERE"
[ -f "$ENV_FILE" ] && [ -f "$PROD_DIR/compose.prod.yml" ] \
  || die "в $PROD_DIR нет установленного контура (.env, compose.prod.yml) — сначала install.sh"
install -d -m 700 -o "$OPS_USER" -g "$OPS_USER" "$STATE_DIR"
SNAP="$STATE_DIR/kit-prev"
LAST="$STATE_DIR/last_update"

confirm() {
  if [ "$ASSUME_YES" -eq 1 ]; then return 0; fi
  [ -t 0 ] || die "нужно подтверждение: запустите в терминале или с --yes"
  local a=""
  read -r -p "$1 [y/N]: " a
  case "$a" in y|Y|yes|да|Да) return 0 ;; *) die "отменено оператором" ;; esac
}

record() { # $1 — текст записи журнала релизов (без секретов)
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$STATE_DIR/releases.log"
  chmod 600 "$STATE_DIR/releases.log"
}

pg_major() { # $1 — compose-файл → мажорная версия образа postgres
  sed -n 's/^[[:space:]]*image:[[:space:]]*postgres:\([0-9][0-9]*\).*/\1/p' "$1" | head -n 1
}

restore_snapshot() { # вернуть комплект и .env из снимка (до миграции ничего в БД не менялось)
  restore_kit_files "$SNAP" "$PROD_DIR"
  install -m 600 -o "$OPS_USER" -g "$OPS_USER" "$SNAP/.env" "$ENV_FILE"
  compose_init
}

check_health() { # 0 — api и worker healthy, /health/ready ok|degraded, общий caddy и backup запущены
  local ok=0 ready
  wait_healthy api 300 || ok=1
  wait_healthy worker 180 || ok=1
  ready="$(api_ready_status)"
  case "$ready" in
    ok) log "/health/ready: ok" ;;
    degraded) log "/health/ready: degraded (устаревшая синхронизация; без подключённой 1С — ожидаемо, RUNBOOK §8.1)" ;;
    *) warn "/health/ready: $ready"; ok=1 ;;
  esac
  case "$(edge_state)" in running) ;; *) warn "общий caddy ($EDGE_PROJECT) не запущен — bin/dc-edge logs caddy"; ok=1 ;; esac
  case "$(container_state backup)" in
    healthy|starting|running) ;;
    unhealthy) warn "backup: unhealthy — копия до обновления сделана; проверьте выгрузку вне сервера (RUNBOOK §4.1, §6.3)" ;;
    *) warn "backup не запущен"; ok=1 ;;
  esac
  return "$ok"
}

# edge_refresh: после смены комплекта рабочего контура — общий caddy (сети, перенос прежнего caddy, пересоздание,
# если файлы Caddy изменились). Тестовая копия общий caddy не трогает: его файлы — в каталоге рабочего контура.
edge_refresh() {
  [ "$CONTOUR" = prod ] || return 0
  if [ "${KIT_EDGE_CHANGED:-0}" -eq 1 ]; then
    log "файлы общего caddy изменились — пересоздание caddy (admin off: конфигурация читается только при старте)"
    edge_up --force-recreate
  else
    edge_up
  fi
}

# =====================================================================================================
if [ "$ROLLBACK" -eq 1 ]; then
  [ -f "$LAST" ] && [ -d "$SNAP" ] || die "нет данных о последнем обновлении ($LAST, $SNAP) — откат вручную по RUNBOOK §3.4"
  prev_api="$(env_get "$LAST" OLD_API_TAG)"
  prev_backup="$(env_get "$LAST" OLD_BACKUP_TAG)"
  cur_api="$(env_get "$ENV_FILE" API_TAG)"
  valid_tag "$prev_api" && valid_tag "$prev_backup" || die "в $LAST нет корректных прежних тегов"
  image_exists "optomstroy/api:$prev_api" || die "образа optomstroy/api:$prev_api нет — загрузите его (docker load) и повторите"
  image_exists "optomstroy/backup:$prev_backup" || die "образа optomstroy/backup:$prev_backup нет — загрузите его и повторите"
  check_secrets
  compose_init
  # Применило ли обновление миграции: журнал базы сейчас против журнала до обновления (update.sh, шаг 3).
  mig_before="$(env_get "$LAST" MIGRATIONS_BEFORE)"
  mig_now="$(pg_migration_journal)" || die "журнал миграций не прочитан (postgres не запущен?) — bin/dc ps; откат не начат"
  pre_dump="$(env_get "$LAST" PRE_UPDATE_DUMP)"
  mig_started="$(env_get "$LAST" MIGRATE_STARTED_AT)"
  if journal_valid "$mig_before"; then
    mig_new="$(journal_added "$mig_before" "$mig_now")"
    mig_lost="$(journal_added "$mig_now" "$mig_before")"
  else
    mig_new="?" mig_lost=""
  fi
  ROLLBACK_MODE=tag
  if [ -n "$mig_new" ] || [ -n "$mig_lost" ]; then
    ROLLBACK_MODE=code-only
    if [ "$CODE_ONLY" -eq 0 ]; then
      if [ "$mig_new" = "?" ]; then
        why="в $LAST нет журнала миграций до обновления (обновление сделано update.sh до 2026-11-19) — применило ли оно миграции, неизвестно"
      else
        why="обновление применило миграции ${mig_new:-—}${mig_lost:+ (а версий $mig_lost в журнале теперь нет)}: мигратор $prev_api их не знает (MIGRATION_MISSING_FILE), а база после отката тега осталась бы новее кода"
      fi
      tz="$(env_get "$ENV_FILE" TZ)"
      when=""
      if [ -n "$mig_started" ]; then
        when="$(TZ="${tz:-Asia/Bishkek}" date -d "$mig_started" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
      fi
      die "откат по тегу не выполнен: $why.
Откат вместе с базой (RUNBOOK §3.4):
  1) sudo $PROD_DIR/bin/update.sh --rollback --code-only      — образы и комплект $prev_api, база не трогается;
  2) восстановление базы на момент перед миграцией (данные после него теряются):
     sudo $PROD_DIR/bin/restore-db.sh --identity <ключ age> --dump $DATA_DIR/backups/${pre_dump:-<копия перед обновлением>}${when:+
     или, при BACKUP_PITR=on, точнее — на момент запуска миграций: sudo $PROD_DIR/bin/restore-db.sh --identity <ключ age> --to-time '$when'}
     (restore-db.sh запустит migrate версии $prev_api — журнал совпадёт с файлами).
Только откат кода при expand-миграциях (16 §10.4, база остаётся новее): --rollback --code-only."
    fi
  fi
  if [ "$ROLLBACK_MODE" = tag ]; then
    confirm "Откатить api/worker/backup ($CONTOUR) с $cur_api на $prev_api? Новых миграций обновление не применило — база совместима"
  else
    confirm "Откатить ТОЛЬКО КОД ($CONTOUR) с $cur_api на $prev_api? Миграции ${mig_new:-?} остаются в базе (только expand, 16 §10.4)"
  fi
  restore_kit_files "$SNAP" "$PROD_DIR"
  # В .env возвращаются только теги: прочие правки оператора после обновления сохраняются.
  env_set "$ENV_FILE" API_TAG "$prev_api"
  env_set "$ENV_FILE" BACKUP_TAG "$prev_backup"
  check_secrets
  compose_init
  ensure_network "$EDGE_NET"
  if [ "$ROLLBACK_MODE" = tag ]; then
    # migrate прежней версии проходит: журнал совпадает с её файлами (0 изменений). postgres — тоже по прежнему
    # комплекту (например, без непрерывной копии WAL, если её не было).
    dc up -d postgres api worker backup
  else
    # --no-deps: migrate старой версии не запускается — журнал миграций уже содержит версии нового релиза, и старый
    # мигратор отказал бы (MIGRATION_MISSING_FILE). Пока БД новее образа, сервисы поднимаются только так (RUNBOOK §3.4).
    dc up -d --no-deps postgres api worker backup
  fi
  edge_refresh
  # Судим по возвращённому compose.prod.yml (archive_command), а не по wal-archive.sh: файлы, добавленные новым
  # релизом, restore_kit_files не удаляет — скрипт остаётся и после отката к версии без непрерывной копии.
  if walspool_orphaned "$PROD_DIR" "$DATA_DIR"; then
    warn "в $DATA_DIR/walspool остались сегменты WAL, а версия $prev_api непрерывной копии не ведёт — RUNBOOK §4.8 (выключение)"
  fi
  if check_health; then
    record "rollback $CONTOUR $cur_api -> $prev_api ok ($ROLLBACK_MODE)"
    log "откат выполнен: $prev_api ($ROLLBACK_MODE). Дальше — prod-smoke без мутаций (16 §10.9) и запись в журнале эксплуатации."
    if [ "$ROLLBACK_MODE" = code-only ]; then
      log "Пока схема БД новее образа, запускайте сервисы так: sudo $PROD_DIR/bin/dc up -d --no-deps api worker backup"
    fi
    exit 0
  fi
  record "rollback $CONTOUR $cur_api -> $prev_api failed ($ROLLBACK_MODE)"
  die "после отката сервисы не готовы — bin/dc logs api worker; при разрушающей миграции — восстановление из копии (RUNBOOK §4.5)"
fi

# =====================================================================================================
log "1/8 Проверки (контур $CONTOUR, проект $PROJECT)"
[ -n "${SRC_DIR:-}" ] && [ -f "$SRC_DIR/infra/compose.prod.yml" ] \
  || die "не найден новый релиз: запустите infra/scripts/update.sh из его каталога или укажите --src"
TEMPLATE="$SRC_DIR/infra/env/prod.env.example"
[ -f "$TEMPLATE" ] || die "нет шаблона $TEMPLATE"
# Тестовая копия: новые имена берутся из prod.env.example с заменами test.env.example (env_apply_test_for_added).
TEST_TEMPLATE="$SRC_DIR/infra/env/test.env.example"
[ "$CONTOUR" = prod ] || [ -f "$TEST_TEMPLATE" ] || die "нет шаблона $TEST_TEMPLATE"
OLD_API="$(env_get "$ENV_FILE" API_TAG)"
OLD_BACKUP="$(env_get "$ENV_FILE" BACKUP_TAG)"
if [ -z "$TAG" ]; then
  TAG="$(default_release_tag "$SRC_DIR" "$CONTOUR" "$(env_get "$ENV_FILE" ONEC_MODE)")"
  [ -n "$TAG" ] || die "не удалось определить тег релиза (нет git) — укажите --tag"
  if src_is_dirty "$SRC_DIR"; then
    die "в каталоге релиза есть незакоммиченные изменения — обновляйтесь с чистого тега или укажите --tag явно"
  fi
fi
valid_tag "$TAG" || die "--tag: допустимы буквы, цифры, . _ - (не latest)"
BACKUP_TAG_NEW="${BACKUP_TAG_NEW:-$TAG}"
valid_tag "$BACKUP_TAG_NEW" || die "--backup-tag: допустимы буквы, цифры, . _ - (не latest)"
old_pg="$(pg_major "$PROD_DIR/compose.prod.yml")"
new_pg="$(pg_major "$SRC_DIR/infra/compose.prod.yml")"
[ "$old_pg" = "$new_pg" ] \
  || die "новый релиз меняет мажорную версию PostgreSQL ($old_pg → $new_pg) — это отдельная процедура (dump/restore, Q-104), не update.sh"
# Повтор после прерванного обновления не должен затереть снимок настоящей прежней версии.
if [ -f "$LAST" ] && [ "$OVERWRITE_SNAPSHOT" -eq 0 ] && [ "$(env_get "$LAST" NEW_API_TAG)" = "$OLD_API" ] \
   && ! grep -q " update [^ ]* ->[ ]*$OLD_API ok\| update $CONTOUR [^ ]* -> $OLD_API ok" "$STATE_DIR/releases.log" 2>/dev/null; then
  die "прошлое обновление до $OLD_API не завершилось записью «ok» (state/releases.log): снимок отката хранит версию $(env_get "$LAST" OLD_API_TAG).
Сначала откат (sudo $PROD_DIR/bin/update.sh --rollback) или, если $OLD_API проверена, повтор с --overwrite-snapshot"
fi
# Секрет роли pos_backup (комплект с 2026-11-19): у контура, установленного раньше, его нет — создаётся здесь,
# пароль роли выставляется после смены комплекта (шаг 4).
if [ ! -s "$SECRETS_DIR/db_backup_password" ]; then
  gen_hex_secret db_backup_password 24
  fix_secret_perms
fi
check_secrets
compose_init
env_normalize_empty "$ENV_FILE"
validate_env "$ENV_FILE"
log "текущая версия: $OLD_API; новая: $TAG; дополнения compose:$(compose_overlays_text)"
[ "$TAG" != "$OLD_API" ] || warn "версия не меняется — будет переустановка $TAG (миграции: 0 изменений)"
confirm "Обновить $CONTOUR $OLD_API → $TAG? Простой API 1–3 минуты (16 §10.1), синхронизация на время обновления остановится"

# =====================================================================================================
log "2/8 Образы новой версии (контур продолжает работать)"
if [ -n "$LOAD_DIR" ]; then
  [ -d "$LOAD_DIR" ] || die "--load-images: нет каталога $LOAD_DIR"
  for tarball in "$LOAD_DIR"/*.tar; do
    [ -f "$tarball" ] || continue
    log "docker load: $(basename "$tarball")"
    docker load -i "$tarball" >/dev/null
  done
fi
ensure_app_images "$SRC_DIR" "$TAG" "$BACKUP_TAG_NEW" "$(env_get "$ENV_FILE" ONEC_MODE)"
# Образы caddy и postgres нового комплекта — до остановки worker: без сети и без образа обновление не начинается.
ensure_pulled "$(compose_image "$SRC_DIR/infra/compose.prod.yml" postgres)"
if [ "$CONTOUR" = prod ]; then
  ensure_pulled "$(compose_image "$SRC_DIR/infra/compose.edge.yml" caddy)"
fi

# =====================================================================================================
log "3/8 Остановка синхронизации (worker) и резервная копия"
PHASE="backup"
SNAP_TAKEN=0
on_abort() {
  local rc=$?
  trap - EXIT
  [ "$rc" -ne 0 ] || return 0
  if [ "$SNAP_TAKEN" -eq 1 ]; then
    if ( restore_snapshot ) >/dev/null 2>&1; then
      ( compose_init ) >/dev/null 2>&1 && compose_init
      log "комплект и .env возвращены из снимка"
    else
      warn "снимок не восстановлен — sudo $PROD_DIR/bin/update.sh --rollback (RUNBOOK §3.4)"
    fi
  fi
  dc up -d --no-deps worker >/dev/null 2>&1 || warn "worker не запустился — bin/dc up -d --no-deps worker"
  record "update $CONTOUR $OLD_API -> $TAG aborted: $PHASE"
  warn "обновление прервано на шаге «$PHASE»: комплект и .env возвращены (если менялись), worker прежней версии запущен снова"
  exit "$rc"
}
trap on_abort EXIT
# Роль pos_backup — вход по secrets/db_backup_password и pg_read_all_data (идемпотентно; нужно новому сервису backup,
# прежнему не мешает): до копии, чтобы и повторный запуск после сбоя делал её той ролью, что задана комплектом.
PHASE="backup-role"
pg_sync_backup_role
# Владелец схемы pgboss — pos_migrate (базы, созданные до 2026-11-19; RUNBOOK §3.6): тот же блок, что в restore-db.sh
# нового релиза. Идемпотентно, прежние api и worker продолжают работать.
PHASE="pgboss-owner"
pg_transfer_pgboss_owner "$HERE/restore-db.sh"
PHASE="backup"
dc stop worker
if ! dc run --rm backup once; then
  trap - EXIT
  dc up -d --no-deps worker || true
  record "update $CONTOUR $OLD_API -> $TAG aborted: backup failed"
  die "резервная копия не создана — обновление отменено, worker запущен снова (bin/dc logs backup; RUNBOOK §4)"
fi
PRE_UPDATE_DUMP="$(ls -1t "$DATA_DIR/backups"/*.dump.age 2>/dev/null | head -n 1 || true)"
PRE_UPDATE_DUMP="$(basename "${PRE_UPDATE_DUMP:-}")"
log "резервная копия перед обновлением создана: $DATA_DIR/backups/$PRE_UPDATE_DUMP"
# Журнал миграций до обновления — для --rollback (применило ли обновление миграции).
PHASE="journal"
MIG_BEFORE="$(pg_migration_journal)" || die "журнал миграций (pos_meta.schema_migrations) не прочитан — bin/dc logs postgres"

# =====================================================================================================
log "4/8 Снимок для отката и новый комплект"
PHASE="snapshot"
snapshot_kit "$PROD_DIR" "$SNAP"
{
  printf 'OLD_API_TAG=%s\n' "$OLD_API"
  printf 'OLD_BACKUP_TAG=%s\n' "$OLD_BACKUP"
  printf 'NEW_API_TAG=%s\n' "$TAG"
  printf 'NEW_BACKUP_TAG=%s\n' "$BACKUP_TAG_NEW"
  printf 'STARTED_AT=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'PRE_UPDATE_DUMP=%s\n' "$PRE_UPDATE_DUMP"
  printf 'MIGRATIONS_BEFORE=%s\n' "$MIG_BEFORE"
} > "$LAST"
chmod 600 "$LAST"
SNAP_TAKEN=1
PHASE="kit"
install_kit "$SRC_DIR" "$PROD_DIR"
ensure_walspool
env_merge_template "$TEMPLATE" "$ENV_FILE"
if [ "$CONTOUR" = test ]; then env_apply_test_for_added "$TEST_TEMPLATE" "$ENV_FILE"; fi
env_normalize_empty "$ENV_FILE"
env_set "$ENV_FILE" API_TAG "$TAG"
env_set "$ENV_FILE" BACKUP_TAG "$BACKUP_TAG_NEW"
apply_mem_profile "$ENV_FILE" "$(mem_total_mb)"
PHASE="config"
if ! ( validate_env "$ENV_FILE" && check_secrets ); then
  trap - EXIT
  restore_snapshot
  dc up -d --no-deps worker || true
  record "update $CONTOUR $OLD_API -> $TAG aborted: config"
  die "новая конфигурация не прошла проверку — комплект и .env возвращены, worker запущен (заполните новые переменные и повторите)"
fi
compose_init
ensure_network "$EDGE_NET"

# =====================================================================================================
log "5/8 Миграции (migrate --seed)"
PHASE="migrate"
printf 'MIGRATE_STARTED_AT=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$LAST"
if ! dc run --rm migrate; then
  trap - EXIT
  restore_snapshot
  dc up -d --no-deps worker || true
  record "update $CONTOUR $OLD_API -> $TAG failed: migrate"
  die "миграция завершилась с ошибкой — .env и комплект возвращены, api старой версии не пересоздавался, worker запущен снова.
Транзакционная миграция откатилась сама (16 §10.4); миграция с пометкой -- no-transaction могла примениться частично —
проверьте bin/dc logs migrate и журнал pos_meta.schema_migrations, при повреждении — восстановление из копии (RUNBOOK §4.5)."
fi
# После успешной миграции автоматического возврата нет: дальше решает человек (--rollback, RUNBOOK §3.4).
trap - EXIT
MIG_AFTER="$(pg_migration_journal || echo '?')"
printf 'MIGRATIONS_AFTER=%s\n' "$MIG_AFTER" >> "$LAST"
if journal_valid "$MIG_AFTER" && [ -n "$(journal_added "$MIG_BEFORE" "$MIG_AFTER")" ]; then
  log "применены миграции: $(journal_added "$MIG_BEFORE" "$MIG_AFTER") — откат по тегу после этого невозможен без восстановления копии (RUNBOOK §3.4)"
fi

# =====================================================================================================
log "6/8 Пересоздание сервисов"
dc up -d --remove-orphans
edge_refresh

# =====================================================================================================
log "7/8 Проверка готовности"
if ! check_health; then
  record "update $CONTOUR $OLD_API -> $TAG failed: health"
  die "после обновления сервисы не готовы. Разберите журналы: sudo $PROD_DIR/bin/dc logs --tail 200 api worker
Откат на $OLD_API (БД не откатывается): sudo $PROD_DIR/bin/update.sh --rollback   (RUNBOOK §3.4)"
fi

# Непрерывная копия WAL (RUNBOOK §4.8): без базовой копии архив WAL бесполезен — первая делается сразу, не ночью.
if [ "$(env_get "$ENV_FILE" BACKUP_PITR)" != off ]; then
  sysid="$(printf 'SELECT system_identifier FROM pg_control_system();\n' | psql_super_at 2>/dev/null || true)"
  if [ -n "$sysid" ] && ls "$DATA_DIR/backups/pitr/$sysid/base"/base_*.info >/dev/null 2>&1; then
    log "непрерывная копия WAL: базовые копии есть (следующая — по расписанию BACKUP_SCHEDULE)"
  elif dc run --rm -T backup base; then
    log "непрерывная копия WAL: первая базовая копия создана ($DATA_DIR/backups/pitr)"
  else
    warn "первая базовая копия PITR не создана — bin/dc logs backup; повтор: sudo $PROD_DIR/bin/dc run --rm backup base (RUNBOOK §4.8)"
  fi
fi
if [ "$CONTOUR" = prod ]; then
  ensure_timer optomstroy-metrics "Оптомстрой POS: метрики сервера (RUNBOOK §6.4)" "$PROD_DIR/bin/metrics_check.sh" '*:0/10' \
    || warn "systemd нет — метрики сервера запускайте по расписанию сами: $PROD_DIR/bin/metrics_check.sh (RUNBOOK §6.4)"
fi

# =====================================================================================================
log "8/8 Журнал релизов"
record "update $CONTOUR $OLD_API -> $TAG ok (дополнения:$(compose_overlays_text))"
dc ps
cat <<EOF

Обновление выполнено ($CONTOUR): $OLD_API → $TAG. Синхронизация (worker) запущена.
Дальше: prod-smoke без мутаций данных (16 §10.9) и запись в журнале эксплуатации (версия, дата, кто, результат).
Откат, пока не выполнена contract-миграция следующего релиза: sudo $PROD_DIR/bin/update.sh --rollback
Старые образы не удаляются автоматически: после стабилизации — docker image rm optomstroy/api:<старая версия> (RUNBOOK §6.5).
EOF
