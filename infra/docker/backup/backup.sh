#!/bin/sh
# Резервное копирование (16 §8.1–§8.3; OPS-001…OPS-004; RUNBOOK §4). Образ optomstroy/backup.
#   backup.sh once        — один прогон: дамп БД → месячная копия → globals (вс) → базовая копия PITR (если
#                           BACKUP_PITR=on) → фото → выгрузка вне сервера → очистка → ping
#   backup.sh daemon      — бесконечный цикл: раз в 20 с сверка времени с BACKUP_SCHEDULE (cron, 5 полей); при
#                           BACKUP_PITR=on рядом — цикл WAL: спул → gzip → age (раз в 20 с), выгрузка WAL вне сервера
#                           раз в 5 минут
#   backup.sh base        — базовая копия PITR сейчас (pg_basebackup; после включения BACKUP_PITR, RUNBOOK §4.8)
#   backup.sh wal-ship    — один проход спула WAL сейчас
#   backup.sh wal-upload  — выгрузка WAL вне сервера сейчас: всё с начала последней успешной выгрузки (RUNBOOK §4.8)
#   backup.sh health      — healthcheck сервиса (compose.prod.yml): код 0 — healthy; причина отказа — в выводе
#   backup.sh store-caddy|commit-caddy|discard-caddy <метка> — архив тома caddy_data от bin/backup-caddy.sh (хост)
#   backup.sh cron-test "<выражение>" "<мин> <час> <день> <мес> <день_недели>" — самопроверка разбора cron
# Переменные (16 §4.3): PGHOST, PGUSER (роль pos_backup), PGDATABASE, PGPASSWORD_FILE, BACKUP_SCHEDULE,
# BACKUP_KEEP_DAYS (30), BACKUP_REMOTE (КОРЕНЬ внешнего хранилища rclone, например offsite:optomstroy/prod; пусто —
# без выгрузки), BACKUP_AGE_RECIPIENT (обязательна: без шифрования ничего не пишется), BACKUP_PITR (on|off,
# непрерывная копия WAL; 15 ADR-035), RCLONE_CONFIG, HEALTHCHECKS_PING_URL_FILE. Значения секретов не печатаются.
#
# Раскладка /backups (том backups — отдельный диск, RUNBOOK §2.2) и вне сервера (BACKUP_REMOTE):
#   <БД>_<UTC>.dump.age        ежедневный дамп; локально BACKUP_KEEP_DAYS суток            → <корень>/db
#   globals_<UTC>.sql.age      роли и членство (по воскресеньям, без паролей); 90 суток    → <корень>/db
#   monthly/<БД>_<UTC>.dump.age первый дамп месяца (жёсткая ссылка); 3 месяца после
#                              суточного срока, BACKUP_KEEP_DAYS + 93 суток (OPS-001)       → <корень>/monthly
#   media/                     накопительная копия фото, без удаления (D-30)               (с /data/media) → <корень>/media
#   caddy_data/*.tar.age       сертификаты общего caddy (bin/backup-caddy.sh); 30 суток    → <корень>/caddy_data
#   pitr/<sysid>/base/base_<UTC>.tar.gz.age + .info   базовая копия кластера (pg_basebackup, ежедневно после дампа)
#                              и её сведения (начало/конец, сегменты WAL, размер tar до сжатия — без данных);
#                              BACKUP_KEEP_DAYS суток, самая новая не удаляется никогда     → <корень>/pitr
#   pitr/<sysid>/wal/<сегмент>.gz.age  архив WAL (сжат, зашифрован); хранится, пока нужен самой старой
#                              оставшейся базовой копии                                     → <корень>/pitr (раз в 5 мин)
#   pitr/<sysid>/wal/<сегмент>.gz.age.sha256  SHA-256 сегмента до сжатия (сверка повтора архивации, wal_ship;
#                              по ней содержимое не восстановить); удаляется вместе с сегментом, вне сервера не уходит
#   .offsite_ok                время последней полностью успешной ночной выгрузки (healthcheck)
#   .wal_offsite_ok            время НАЧАЛА последней полностью успешной выгрузки WAL: всё, зашифрованное раньше, уже
#                              вне сервера (wal_upload; healthcheck)
#   .wal_upload.lock           замок выгрузки WAL вне сервера (wal_upload и шаг WAL ночной выгрузки — по очереди)
#   .pitr_since                время включения непрерывной копии (отсчёт для healthcheck)
# <sysid> — system_identifier кластера PostgreSQL: новый кластер (новый сервер, переустановка) пишет в свой каталог,
# имена сегментов WAL разных кластеров не сталкиваются ни на диске, ни вне сервера.
# Вне сервера только `rclone copy --immutable` (без удаления и перезаписи, SEC-111): хранение там — правилом
# жизненного цикла хранилища (RUNBOOK §4.3). Каждый прогон выгружает весь каталог — копия, не выгруженная прошлой
# ночью (хранилище было недоступно), уходит следующей.
set -eu

BACKUPS="${BACKUPS_DIR:-/backups}"   # переопределяется только самопроверкой (infra/docker/scripts/test_lib.sh)
MEDIA_SRC="/data/media"
MONTHLY_EXTRA_DAYS=93                # 3 месяца × 31 сутки после суточного срока (16 §8.1, OPS-001; 07 DATA-298 «до ~120 дней»)
GLOBALS_KEEP_DAYS=90                 # 16 §8.1
CADDY_KEEP_DAYS=30
# Непрерывная копия WAL (PITR; 15 ADR-035; 16 §8.1 «RPO при PITR ≤ 15 мин»).
WAL_SPOOL="${WAL_SPOOL_DIR:-/walspool}"   # спул archive_command (docker/postgres/scripts/wal-archive.sh), диск базы
PITR_ROOT="$BACKUPS/pitr"
WAL_SHIP_EVERY_SEC=20                # спул → архив: сегмент лежит незашифрованным не дольше ~20 с
WAL_UPLOAD_EVERY_SEC=300             # архив WAL → вне сервера раз в 5 мин (потеря при гибели сервера ≤ ~6 мин)
WAL_UPLOAD_MARGIN_SEC=900            # окно выгрузки WAL: с начала прошлой успешной выгрузки минус 15 мин запаса…
WAL_UPLOAD_MIN_WINDOW_SEC=7200       # …и не меньше 2 ч
WAL_LOCK="$BACKUPS/.wal_upload.lock" # замок выгрузки WAL вне сервера (wal_lock_take)
WAL_LOCK_WAIT_SEC=1800               # ночная выгрузка ждёт выгрузку WAL цикла не дольше 30 мин
WAL_LOCK_STALE_MIN=180               # каталог-замок (без flock, только вне образа) старше 3 ч — брошен
WAL_SPOOL_MAX_MIN=10                 # healthcheck: файл в спуле старше — цикл WAL стоит
WAL_OFFSITE_MAX_MIN=30               # healthcheck: выгрузка WAL вне сервера старше — unhealthy
BASE_MAX_MIN=1560                    # healthcheck: базовая копия старше 26 ч — unhealthy (как ежедневный дамп)
PITR_SYSID=""
PITR_CUR=""

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

pg_bin() { # $1 — pg_dump | pg_dumpall | pg_basebackup | psql (Alpine: /usr/libexec/postgresql17)
  command -v "$1" 2>/dev/null || { [ -x "/usr/libexec/postgresql17/$1" ] && echo "/usr/libexec/postgresql17/$1"; } || return 1
}

# pg_env: пароль роли pos_backup из файла секрета (один раз на процесс; значение не печатается).
pg_env() {
  if [ -n "${PGPASSWORD_FILE:-}" ] && [ -z "${PGPASSWORD:-}" ]; then
    PGPASSWORD="$(tr -d '\r\n' < "$PGPASSWORD_FILE")"
    export PGPASSWORD
  fi
}

# pg_sql "<SQL>" → строки результата без заголовков (psql -At) под ролью pos_backup.
pg_sql() {
  pg_psql="$(pg_bin psql)" || return 1
  PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}" "$pg_psql" -X -v ON_ERROR_STOP=1 -q -A -t -c "$1"
}

pitr_on() { [ "${BACKUP_PITR:-on}" = on ]; }

# wal_name_ok <имя>: сегмент WAL (24 шестнадцатеричных символа), .history, .backup или .partial.
wal_name_ok() {
  printf '%s\n' "$1" | grep -Eq '^([0-9A-F]{24}(\.partial|\.[0-9A-F]{8}\.backup)?|[0-9A-F]{8}\.history)$'
}

# pitr_resolve: PITR_SYSID (system_identifier кластера) и PITR_CUR (/backups/pitr/<sysid>); 1 — БД недоступна.
# Спрашивается у базы при КАЖДОМ вызове, не запоминается на время жизни daemon: кластер, пересозданный при
# работающем backup (новый initdb), пишет в свой каталог, а не в каталог прежнего под теми же именами сегментов.
# Вызовы редкие: wal_ship — раз за проход, только при непустом спуле (archive_timeout=60 — около раза в минуту);
# base_backup и pitr_prune — раз в сутки.
pitr_resolve() {
  pg_env
  PITR_SYSID="$(pg_sql "SELECT system_identifier FROM pg_control_system()" 2>/dev/null)" || PITR_SYSID=""
  case "$PITR_SYSID" in ''|*[!0-9]*) PITR_SYSID=""; PITR_CUR=""; return 1 ;; esac
  PITR_CUR="$PITR_ROOT/$PITR_SYSID"
}

ping_hc() {
  # $1 — суффикс Healthchecks ("" — успех, "/fail" — ошибка, "/start" — начало)
  if [ -n "${HEALTHCHECKS_PING_URL_FILE:-}" ] && [ -s "${HEALTHCHECKS_PING_URL_FILE}" ]; then
    url="$(tr -d '\r\n' < "$HEALTHCHECKS_PING_URL_FILE")"
    wget -q -T 10 -O /dev/null "${url}$1" 2>/dev/null || log warn "healthchecks: ping не доставлен"
  fi
}

# remote_root → BACKUP_REMOTE без завершающего «/»; прежняя запись «…/db» (RUNBOOK до 2026-11-19) понимается как корень.
remote_root() {
  r="${BACKUP_REMOTE%/}"
  case "$r" in
    */db) log warn "BACKUP_REMOTE оканчивается на /db — теперь это корень хранилища (db, monthly, media добавляются сами); используется ${r%/db}"
          r="${r%/db}" ;;
  esac
  printf '%s' "$r"
}

# monthly_link <файл дампа>: первый дамп календарного месяца (UTC, по имени <БД>_ГГГГММДДTчччмммсссZ.dump.age) —
# жёсткая ссылка в monthly/ (копия, если ссылки не поддерживаются). Повтор за тот же месяц ничего не делает.
monthly_link() {
  f="$1"
  name="$(basename "$f")"
  stamp="${name##*_}"
  ym="$(printf '%s' "$stamp" | cut -c1-6)"
  case "$ym" in [0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) log warn "месячная копия: неожиданное имя $name"; return 0 ;; esac
  mkdir -p "$BACKUPS/monthly"
  for m in "$BACKUPS/monthly/"*_"$ym"[0-3][0-9]T*Z.dump.age; do
    [ -e "$m" ] && return 0
  done
  ln "$f" "$BACKUPS/monthly/$name" 2>/dev/null || cp -p "$f" "$BACKUPS/monthly/$name"
  log info "месячная копия: $name"
}

# rotate_local <суток>: ежедневные дампы старше срока, месячные — старше срока + 93 суток, globals — 90 суток,
# архивы caddy_data — 30 суток, незавершённые *.partial — старше суток. Копии вне сервера не удаляются никогда.
rotate_local() {
  keep="$1"
  find "$BACKUPS" -maxdepth 1 -type f -name '*.dump.age' -mtime +"$keep" -exec rm -f {} + 2>/dev/null || true
  if [ -d "$BACKUPS/monthly" ]; then
    find "$BACKUPS/monthly" -maxdepth 1 -type f -name '*.dump.age' -mtime +"$((keep + MONTHLY_EXTRA_DAYS))" -exec rm -f {} + 2>/dev/null || true
  fi
  find "$BACKUPS" -maxdepth 1 -type f -name 'globals_*.sql.age' -mtime +"$GLOBALS_KEEP_DAYS" -exec rm -f {} + 2>/dev/null || true
  if [ -d "$BACKUPS/caddy_data" ]; then
    find "$BACKUPS/caddy_data" -maxdepth 1 -type f -name '*.tar.age' -mtime +"$CADDY_KEEP_DAYS" -exec rm -f {} + 2>/dev/null || true
  fi
  find "$BACKUPS" -maxdepth 4 -type f -name '*.partial' -mmin +1440 -exec rm -f {} + 2>/dev/null || true
  # Страховочная копия restore-db.sh (BACKUP_SKIP_PRUNE=1): базовая копия, уже выбранная для восстановления, и её
  # сегменты WAL могут быть у края срока хранения — очистка PITR в этом прогоне не выполняется (дампы — как обычно).
  if [ "${BACKUP_SKIP_PRUNE:-0}" = 1 ]; then
    log info "очистка PITR пропущена (страховочная копия restore-db.sh: выбранная базовая копия и её WAL нужны восстановлению)"
  else
    pitr_prune "$keep"
  fi
}

# encrypt_partial <файл>: stdin → age → <файл>.partial (незашифрованные данные на диск не пишутся). Переименование
# в <файл> — только после проверки кода ВСЕГО конвейера (commit_partial): age успешно шифрует и оборванный поток.
encrypt_partial() {
  age -r "$BACKUP_AGE_RECIPIENT" -o "$1.partial"
}

# commit_partial <файл> <код конвейера>: 0 → <файл>.partial становится <файл>; иначе .partial удаляется.
commit_partial() {
  if [ "$2" -eq 0 ] && [ -s "$1.partial" ]; then
    mv "$1.partial" "$1"
    return 0
  fi
  rm -f "$1.partial"
  return 1
}

# media_copy: накопительная копия фото на диск копий (без удаления; служебные файлы и корзина images.gc — мимо).
media_copy() {
  [ -d "$MEDIA_SRC" ] || return 0
  rclone copy "$MEDIA_SRC" "$BACKUPS/media" --immutable --exclude '.*' --exclude '.*/**' --log-level ERROR
}

# offsite_upload: всё, что должно быть вне сервера, за один проход; при успехе — отметка .offsite_ok.
offsite_upload() {
  root="$(remote_root)"
  rc=0
  rclone copy "$BACKUPS" "$root/db" --include '/*.age' --immutable --log-level ERROR || rc=1
  if [ -d "$BACKUPS/monthly" ]; then
    rclone copy "$BACKUPS/monthly" "$root/monthly" --include '/*.age' --immutable --log-level ERROR || rc=1
  fi
  if [ -d "$MEDIA_SRC" ]; then
    rclone copy "$MEDIA_SRC" "$root/media" --immutable --exclude '.*' --exclude '.*/**' --log-level ERROR || rc=1
  fi
  if [ -d "$BACKUPS/caddy_data" ]; then
    rclone copy "$BACKUPS/caddy_data" "$root/caddy_data" --include '/*.age' --immutable --log-level ERROR || rc=1
  fi
  # Базовые копии и их сведения — все; WAL — страховочная сверка всего архива старше часа (каталог хранилища
  # перечисляется целиком). Свежие сегменты и всё накопленное за перебой связи выгружает wal_upload с последней
  # успешной выгрузки; окно после долгого перебоя длиннее часа, поэтому оба шага — под одним замком (wal_lock_take):
  # один объект не пишут два rclone сразу. Контрольные суммы *.sha256 вне сервера не выгружаются.
  if [ -d "$PITR_ROOT" ]; then
    rclone copy "$PITR_ROOT" "$root/pitr" --include '/*/base/*.age' --include '/*/base/*.info' --immutable \
      --log-level ERROR || rc=1
    if wal_lock_take "$WAL_LOCK_WAIT_SEC"; then
      rclone copy "$PITR_ROOT" "$root/pitr" --include '/*/wal/*.age' --min-age 1h --immutable --log-level ERROR || rc=1
      wal_lock_drop
    else
      log error "WAL вне сервера: выгрузка цикла WAL идёт дольше $((WAL_LOCK_WAIT_SEC / 60)) мин — ночная сверка WAL пропущена"
      rc=1
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    date -u +%s > "$BACKUPS/.offsite_ok.tmp" && mv "$BACKUPS/.offsite_ok.tmp" "$BACKUPS/.offsite_ok"
  fi
  return "$rc"
}

# ---------- Непрерывная копия WAL и базовые копии (PITR; RUNBOOK §4.8) ----------
# wal_ship: файлы спула (archive_command уже опубликовал их целиком) → gzip → age → pitr/<sysid>/wal/<имя>.gz.age;
# после успешного шифрования копия спула удаляется. До архива пишется <имя>.gz.age.sha256 — SHA-256 файла до сжатия:
# это не содержимое WAL и восстановить по нему ничего нельзя, правило «незашифрованный WAL на диск копий не
# попадает» сохраняется (сумма без архива безвредна — следующая попытка её перепишет). Имя сегмента однозначно задаёт
# содержимое только в обычной работе; после отката диска базы, запуска базовой копии без recovery.signal или
# пересоздания кластера при работающем backup под тем же именем приходит ДРУГОЕ содержимое (контракт archive_command,
# wal-archive.sh: тот же файл — 0, другой — отказ). Поэтому файл, уже лежащий в архиве:
#   - сумма совпала — повтор архивации после сбоя: копия спула удаляется;
#   - сумма другая — копия остаётся в спуле, ошибка в журнале, код 1; через 10 минут healthcheck wal-spool-stuck
#     (разбор — DevOps, RUNBOOK §6.3);
#   - суммы нет (архив записан до 2026-11-19) — как раньше: копия спула удаляется, предупреждение в журнале.
# Посторонний файл не трогается: он стареет в спуле, и healthcheck делает сервис unhealthy (разбор — RUNBOOK §6.3).
wal_ship() {
  [ -d "$WAL_SPOOL" ] || return 0
  ws_any=0
  for ws_f in "$WAL_SPOOL"/*; do
    if [ -f "$ws_f" ]; then ws_any=1; break; fi
  done
  [ "$ws_any" -eq 1 ] || return 0
  if [ -z "${BACKUP_AGE_RECIPIENT:-}" ]; then
    log error "WAL: BACKUP_AGE_RECIPIENT не задана — сегменты остаются в спуле (OPS-004)"
    return 1
  fi
  if ! pitr_resolve; then
    log error "WAL: system_identifier кластера не получен (БД недоступна) — сегменты остаются в спуле"
    return 1
  fi
  mkdir -p "$PITR_CUR/wal"
  set -o pipefail
  ws_rc=0
  for ws_f in "$WAL_SPOOL"/*; do
    [ -f "$ws_f" ] || continue
    ws_n="$(basename "$ws_f")"
    if ! wal_name_ok "$ws_n"; then
      log warn "WAL: в спуле посторонний файл $ws_n — не трогается (RUNBOOK §6.3)"
      continue
    fi
    ws_out="$PITR_CUR/wal/$ws_n.gz.age"
    ws_sum="$(sha256sum < "$ws_f" | cut -d' ' -f1)" || ws_sum=""
    case "$ws_sum" in *[!0-9a-f]*) ws_sum="" ;; esac
    if [ "${#ws_sum}" -ne 64 ]; then
      log error "WAL: $ws_n не прочитан (sha256sum) — остаётся в спуле, повтор через ${WAL_SHIP_EVERY_SEC} с"
      ws_rc=1
      continue
    fi
    if [ -e "$ws_out" ]; then
      if [ ! -f "$ws_out.sha256" ]; then
        rm -f "$ws_f"
        log warn "WAL: $ws_n уже в архиве (записан без контрольной суммы, до 2026-11-19) — копия спула удалена без сверки"
      elif [ "$(cat "$ws_out.sha256" 2>/dev/null)" = "$ws_sum" ]; then
        rm -f "$ws_f"
        log info "WAL: $ws_n уже в архиве с тем же содержимым (повтор архивации) — копия спула удалена"
      else
        log error "WAL: $ws_n уже в архиве с другим содержимым — копия остаётся в спуле (RUNBOOK §6.3)"
        ws_rc=1
      fi
      continue
    fi
    if ! { printf '%s\n' "$ws_sum" > "$ws_out.sha256.tmp" && mv "$ws_out.sha256.tmp" "$ws_out.sha256"; }; then
      rm -f "$ws_out.sha256.tmp"
      log error "WAL: контрольная сумма $ws_n не записана (диск копий) — остаётся в спуле, повтор через ${WAL_SHIP_EVERY_SEC} с"
      ws_rc=1
      continue
    fi
    ws_pipe=0
    gzip -c "$ws_f" | encrypt_partial "$ws_out" || ws_pipe=$?
    if commit_partial "$ws_out" "$ws_pipe"; then
      rm -f "$ws_f"
    else
      log error "WAL: $ws_n не зашифрован (gzip/age) — остаётся в спуле, повтор через ${WAL_SHIP_EVERY_SEC} с"
      ws_rc=1
    fi
  done
  return "$ws_rc"
}

# wal_lock_take <ждать, с>: замок выгрузки WAL вне сервера ($BACKUPS/.wal_upload.lock). Его берут wal_upload (цикл
# WAL daemon, `backup.sh wal-upload`) и шаг WAL ночной выгрузки offsite_upload (прогон по расписанию,
# `dc run --rm backup once`, страховочная копия restore-db.sh — другой контейнер на том же диске копий): окно
# выгрузки после перебоя связи бывает длиннее часа, и без замка два rclone писали бы один объект одновременно.
# flock (busybox образа) — замок снимает ядро, даже если процесс убит при остановке контейнера; без flock (только
# самопроверка вне образа) — каталог-замок, брошенный старше WAL_LOCK_STALE_MIN снимается. 0 — взят; 1 — занят.
wal_lock_take() {
  wlt_until=$(( $(date +%s) + $1 ))
  if command -v flock >/dev/null 2>&1; then
    # Проверка внешней командой: ошибка перенаправления у `exec` (специальная встроенная) завершила бы весь shell.
    touch "$WAL_LOCK" 2>/dev/null && [ -w "$WAL_LOCK" ] || return 1
    exec 9>>"$WAL_LOCK"
    while ! flock -n 9; do
      if [ "$(date +%s)" -ge "$wlt_until" ]; then
        exec 9>&-
        return 1
      fi
      sleep 5
    done
    return 0
  fi
  while ! mkdir "$WAL_LOCK.d" 2>/dev/null; do
    if [ -n "$(find "$WAL_LOCK.d" -maxdepth 0 -mmin +"$WAL_LOCK_STALE_MIN" 2>/dev/null)" ]; then
      log warn "WAL: брошенный замок выгрузки (старше $WAL_LOCK_STALE_MIN мин) снят"
      rmdir "$WAL_LOCK.d" 2>/dev/null || true
      mkdir "$WAL_LOCK.d" 2>/dev/null && return 0
    fi
    [ "$(date +%s)" -lt "$wlt_until" ] || return 1
    sleep 5
  done
  return 0
}

# wal_lock_drop: снять замок, взятый wal_lock_take.
wal_lock_drop() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>&-
  else
    rmdir "$WAL_LOCK.d" 2>/dev/null || true
  fi
}

# wal_upload: сегменты WAL вне сервера — всё, что зашифровано с начала последней ПОЛНОСТЬЮ успешной выгрузки (минус
# 15 минут запаса, окно не меньше 2 ч; отметки нет — первая выгрузка, новый диск копий — весь архив, без --max-age).
# Поэтому после перебоя связи или хранилища любой длительности всё накопленное уходит первым же успешным проходом, а
# не ночью. Отметка .wal_offsite_ok — время НАЧАЛА этого прохода (не конца: сегмент, зашифрованный, пока работал
# rclone, попадает в окно следующего прохода) и только после кода 0 rclone: сбой или частичная выгрузка отметку не
# двигают. Свежая отметка значит «всё, зашифрованное до неё, уже вне сервера», поэтому healthcheck
# wal-offsite-older-30m — сигнал дыры в копии вне сервера. Ночной offsite_upload (--min-age 1h) — страховочная сверка.
# --no-traverse: каталог хранилища не перечисляется, проверяется каждый выгружаемый файл (после перебоя в 3 ч —
# около 180 сегментов). Код: 0 — выгружено; 1 — сбой; 75 — выгружает другой процесс (замок; повтор через минуту).
wal_upload() {
  wu_start="$(date -u +%s)"
  if [ -d "$PITR_ROOT" ]; then
    wal_lock_take 0 || return 75
    wu_prev="$(cat "$BACKUPS/.wal_offsite_ok" 2>/dev/null || true)"
    case "$wu_prev" in ''|*[!0-9]*) wu_prev="" ;; esac
    if [ -n "$wu_prev" ] && [ "$wu_prev" -le "$wu_start" ]; then
      wu_win=$(( wu_start - wu_prev + WAL_UPLOAD_MARGIN_SEC ))
      [ "$wu_win" -ge "$WAL_UPLOAD_MIN_WINDOW_SEC" ] || wu_win="$WAL_UPLOAD_MIN_WINDOW_SEC"
      set -- --max-age "${wu_win}s"
    else
      set --
      log info "WAL: отметки прошлой выгрузки нет — вне сервера сверяется весь архив WAL"
    fi
    wu_rc=0
    rclone copy "$PITR_ROOT" "$(remote_root)/pitr" --include '/*/wal/*.age' "$@" --no-traverse --immutable \
      --log-level ERROR || wu_rc=1
    wal_lock_drop
    [ "$wu_rc" -eq 0 ] || return 1
  fi
  printf '%s\n' "$wu_start" > "$BACKUPS/.wal_offsite_ok.tmp" && mv "$BACKUPS/.wal_offsite_ok.tmp" "$BACKUPS/.wal_offsite_ok"
}

# pg_base_stream <метка>: tar базовой копии кластера в stdout. pg_basebackup по протоколу репликации (роль pos_backup:
# REPLICATION, строка pg_hba — initdb 10-roles.sh / lib.sh pg_sync_backup_role). -X fetch: WAL от начала до конца
# копии — в том же tar, копия восстанавливается и без архива; --checkpoint=fast — начать сразу. В stdout tar пишется
# только без потоковой WAL и без дополнительных табличных пространств (документация pg_basebackup 17).
pg_base_stream() {
  "$PG_BASEBACKUP" -h "$PGHOST" -U "$PGUSER" -D - -F tar -X fetch --checkpoint=fast --no-manifest -l "$1"
}

# base_backup [<метка UTC>]: pitr/<sysid>/base/base_<UTC>.tar.gz.age (pg_basebackup | gzip | age, без
# незашифрованного файла на диске) и base_<UTC>.info — сведения без данных: начало и конец (UTC, по часам контейнера
# — с запасом наружу), первый и последний сегмент WAL (pg_walfile_name до и после копии; первые 8 символов — линия
# времени), base_bytes — размер tar до сжатия. По ним restore-db.sh выбирает копию для момента восстановления и
# оценивает место на диске базы, а pitr_prune — какие сегменты WAL ещё нужны.
base_backup() {
  bb_ts="${1:-$(date -u +%Y%m%dT%H%M%SZ)}"
  if [ -z "${BACKUP_AGE_RECIPIENT:-}" ]; then
    log error "базовая копия: BACKUP_AGE_RECIPIENT не задана (OPS-004)"
    return 1
  fi
  pg_env
  if ! pitr_resolve; then
    log error "базовая копия: system_identifier кластера не получен (БД недоступна)"
    return 1
  fi
  PG_BASEBACKUP="$(pg_bin pg_basebackup)" || { log error "pg_basebackup не найден"; return 1; }
  bb_dir="$PITR_CUR/base"
  mkdir -p "$bb_dir" "$PITR_CUR/wal"
  bb_start_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  bb_start_wal="$(pg_sql "SELECT pg_walfile_name(pg_current_wal_lsn())")" || bb_start_wal=""
  if ! wal_name_ok "$bb_start_wal"; then
    log error "базовая копия: не получен текущий сегмент WAL"
    return 1
  fi
  bb_out="$bb_dir/base_${bb_ts}.tar.gz.age"
  bb_cnt="$bb_dir/.base_${bb_ts}.cnt"
  rm -f "$bb_cnt" "$bb_cnt.fifo"
  set -o pipefail
  bb_rc=0
  if mkfifo "$bb_cnt.fifo" 2>/dev/null; then
    # Размер tar до сжатия (base_bytes): wc читает копию потока из именованного канала (в POSIX sh нет >(…)); на
    # диск пишется только число. wait — только этого wc: у daemon в фоне ещё цикл WAL.
    wc -c < "$bb_cnt.fifo" > "$bb_cnt" &
    bb_wc=$!
    pg_base_stream "base_${bb_ts}" | tee "$bb_cnt.fifo" | gzip -c | encrypt_partial "$bb_out" || bb_rc=$?
    wait "$bb_wc" 2>/dev/null || true
  else
    log warn "базовая копия: mkfifo не удался — размер до сжатия (base_bytes) не записывается"
    pg_base_stream "base_${bb_ts}" | gzip -c | encrypt_partial "$bb_out" || bb_rc=$?
  fi
  bb_bytes="$(tr -dc 0-9 < "$bb_cnt" 2>/dev/null || true)"
  rm -f "$bb_cnt" "$bb_cnt.fifo"
  if ! commit_partial "$bb_out" "$bb_rc"; then
    log error "базовая копия не создана (pg_basebackup/gzip/age, код $bb_rc)"
    return 1
  fi
  bb_end_wal="$(pg_sql "SELECT pg_walfile_name(pg_current_wal_lsn())")" || bb_end_wal=""
  bb_end_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  {
    printf 'label=base_%s\n' "$bb_ts"
    printf 'system_identifier=%s\n' "$PITR_SYSID"
    printf 'file=base_%s.tar.gz.age\n' "$bb_ts"
    printf 'start_utc=%s\n' "$bb_start_utc"
    printf 'end_utc=%s\n' "$bb_end_utc"
    printf 'start_wal=%s\n' "$bb_start_wal"
    printf 'end_wal=%s\n' "$bb_end_wal"
    [ -z "$bb_bytes" ] || printf 'base_bytes=%s\n' "$bb_bytes"
  } > "$bb_dir/.base_${bb_ts}.info.tmp"
  mv "$bb_dir/.base_${bb_ts}.info.tmp" "$bb_dir/base_${bb_ts}.info"
  log info "базовая копия PITR: base_${bb_ts}.tar.gz.age ($(wc -c < "$bb_out") байт, до сжатия ${bb_bytes:-?}; WAL с $bb_start_wal)"
}

# pitr_prune <суток>: базовые копии старше срока (самая новая копия текущего кластера — никогда; если кластер не
# определён — базовые копии в этот раз не удаляются) и сегменты WAL, которые не нужны самой старой оставшейся
# базовой копии (сравнение по номеру сегмента без линии времени; .history хранятся всегда). Каталог прежнего
# кластера без базовых копий — WAL старше срока. Контрольные суммы *.gz.age.sha256 удаляются вместе с сегментом;
# сумма без сегмента (сбой между записью суммы и архива, сегмент так и не пришёл) — через сутки. Вне сервера ничего не
# удаляется (правило хранилища, RUNBOOK §4.3). Текущий кластер спрашивается у базы заново (pitr_resolve).
pitr_prune() {
  pp_keep="$1"
  [ -d "$PITR_ROOT" ] || return 0
  pitr_resolve || true
  for pp_sys in "$PITR_ROOT"/*; do
    [ -d "$pp_sys" ] || continue
    pp_newest="$(ls -1 "$pp_sys/base" 2>/dev/null | grep '^base_.*\.info$' | sort | tail -n 1)"
    if [ -n "$PITR_SYSID" ]; then
      for pp_info in "$pp_sys/base/"base_*.info; do
        [ -f "$pp_info" ] || continue
        if [ "$pp_sys" = "$PITR_ROOT/$PITR_SYSID" ] && [ "$(basename "$pp_info")" = "$pp_newest" ]; then
          continue
        fi
        if [ -n "$(find "$pp_info" -mtime +"$pp_keep" 2>/dev/null)" ]; then
          rm -f "${pp_info%.info}.tar.gz.age" "$pp_info"
        fi
      done
      # базовая копия без сведений (сбой между записью копии и .info) для восстановления не выбирается
      for pp_b in "$pp_sys/base/"base_*.tar.gz.age; do
        [ -f "$pp_b" ] || continue
        [ -f "${pp_b%.tar.gz.age}.info" ] || [ -z "$(find "$pp_b" -mmin +1440 2>/dev/null)" ] || rm -f "$pp_b"
      done
    fi
    [ -d "$pp_sys/wal" ] || continue
    find "$pp_sys/wal" -maxdepth 1 -type f -name '*.gz.age.sha256' -mmin +1440 2>/dev/null | while IFS= read -r pp_s; do
      [ -e "${pp_s%.sha256}" ] || rm -f "$pp_s"
    done
    pp_oldest="$(ls -1 "$pp_sys/base" 2>/dev/null | grep '^base_.*\.info$' | sort | head -n 1)"
    if [ -n "$pp_oldest" ]; then
      pp_cut="$(sed -n 's/^start_wal=//p' "$pp_sys/base/$pp_oldest" | head -n 1)"
      wal_name_ok "$pp_cut" || continue
      ls -1 "$pp_sys/wal" | wal_older_than "$pp_cut" | while IFS= read -r pp_w; do
        rm -f "$pp_sys/wal/$pp_w" "$pp_sys/wal/$pp_w.sha256"
      done
    else
      find "$pp_sys/wal" -maxdepth 1 -type f \( -name '*.gz.age' -o -name '*.gz.age.sha256' \) -mtime +"$pp_keep" \
        -exec rm -f {} + 2>/dev/null || true
      rmdir "$pp_sys/wal" "$pp_sys/base" "$pp_sys" 2>/dev/null || true
    fi
  done
}

# wal_older_than <сегмент>: из stdin (имена файлов архива *.gz.age) — сегменты, .partial и .backup с номером сегмента
# (символы 9–24 имени, без линии времени) меньше заданного; .history не выводятся никогда.
wal_older_than() {
  awk -v cut="$(printf '%s' "$1" | cut -c9-24)" '
    { n = $0; sub(/\.gz\.age$/, "", n) }
    n == $0 || n ~ /\.history$/ || length(n) < 24 { next }
    { s = substr(n, 9, 16); if (("" s) < ("" cut)) print $0 }'
}

# health: healthcheck сервиса backup (compose.prod.yml). Unhealthy, если: не жив цикл расписания; последняя ежедневная
# копия старше 26 ч (копий ещё нет — первый запуск — не ошибка); при BACKUP_REMOTE — ночная выгрузка (.offsite_ok)
# старше 26 ч. При BACKUP_PITR=on дополнительно: archive_mode у postgres не on (после смены BACKUP_PITR не
# пересоздан postgres); архивация WAL сбоит (pg_stat_archiver: last_failed_time новее last_archived_time); файл в спуле
# старше 10 минут; самая новая базовая копия кластера старше 26 ч (через 26 ч после включения); при BACKUP_REMOTE —
# выгрузка WAL (.wal_offsite_ok) старше 30 минут. Отметка .wal_offsite_ok обновляется только полностью успешным
# проходом wal_upload, окно которого начинается с прошлой отметки: свежая отметка значит «всё до неё — вне сервера»,
# и wal-offsite-older-30m — сигнал дыры в копии вне сервера (отдельная проверка «дыры» не нужна).
# Причины — одной строкой в выводе (docker inspect, RUNBOOK §6.3).
health() {
  hl_bad=""
  pgrep -f 'backup[.]sh daemon' >/dev/null 2>&1 || hl_bad="$hl_bad schedule-loop-not-running"
  if ls "$BACKUPS"/*.dump.age >/dev/null 2>&1; then
    [ -n "$(find "$BACKUPS" -maxdepth 1 -name '*.dump.age' -mmin -1560 | head -n 1)" ] || hl_bad="$hl_bad dump-older-26h"
    if [ -n "${BACKUP_REMOTE:-}" ]; then
      [ -n "$(find "$BACKUPS" -maxdepth 1 -name .offsite_ok -mmin -1560)" ] || hl_bad="$hl_bad offsite-older-26h"
    fi
  fi
  if pitr_on; then
    pg_env
    hl_row="$(PGCONNECT_TIMEOUT=5 pg_sql "SELECT s.system_identifier || ' ' || current_setting('archive_mode') || ' ' ||
      CASE WHEN a.last_failed_time IS NOT NULL AND (a.last_archived_time IS NULL OR a.last_failed_time > a.last_archived_time)
           THEN 'failing' ELSE 'ok' END
      FROM pg_control_system() s, pg_stat_archiver a" 2>/dev/null)" || hl_row=""
    # shellcheck disable=SC2086
    set -- $hl_row
    hl_sys=""
    if [ $# -ne 3 ]; then
      hl_bad="$hl_bad db-unreachable"
    else
      hl_sys="$1"
      [ "$2" = on ] || hl_bad="$hl_bad archive_mode-$2"
      [ "$3" = ok ] || hl_bad="$hl_bad wal-archiving-failing"
    fi
    if [ -n "$(find "$WAL_SPOOL" -maxdepth 1 -type f ! -name '.*' -mmin +"$WAL_SPOOL_MAX_MIN" 2>/dev/null | head -n 1)" ]; then
      hl_bad="$hl_bad wal-spool-stuck"
    fi
    if [ -n "$(find "$BACKUPS" -maxdepth 1 -name .pitr_since -mmin +"$BASE_MAX_MIN" 2>/dev/null)" ] && [ -n "$hl_sys" ]; then
      [ -n "$(find "$PITR_ROOT/$hl_sys/base" -maxdepth 1 -name 'base_*.info' -mmin -"$BASE_MAX_MIN" 2>/dev/null | head -n 1)" ] \
        || hl_bad="$hl_bad base-backup-older-26h"
    fi
    if [ -n "${BACKUP_REMOTE:-}" ] && [ -n "$(find "$BACKUPS" -maxdepth 1 -name .pitr_since -mmin +"$WAL_OFFSITE_MAX_MIN" 2>/dev/null)" ]; then
      [ -n "$(find "$BACKUPS" -maxdepth 1 -name .wal_offsite_ok -mmin -"$WAL_OFFSITE_MAX_MIN" 2>/dev/null)" ] \
        || hl_bad="$hl_bad wal-offsite-older-30m"
    fi
  fi
  if [ -n "$hl_bad" ]; then
    echo "unhealthy:$hl_bad"
    return 1
  fi
  echo "ok"
}

# wal_loop: фоновый цикл daemon при BACKUP_PITR=on — спул каждые 20 с, выгрузка WAL вне сервера каждые 5 минут
# (сбой выгрузки или занятый замок — повтор через минуту; всё накопленное уходит первым успешным проходом).
# Живёт, пока жив daemon (tini завершает контейнер вместе с ним).
wal_loop() {
  wl_last=0
  while :; do
    wal_ship || true
    if [ -n "${BACKUP_REMOTE:-}" ]; then
      wl_now="$(date +%s)"
      if [ $((wl_now - wl_last)) -ge "$WAL_UPLOAD_EVERY_SEC" ]; then
        wl_rc=0
        wal_upload || wl_rc=$?
        case "$wl_rc" in
          0) wl_last="$wl_now" ;;
          75) log info "WAL: выгрузку вне сервера сейчас выполняет ночной прогон — повтор через минуту"
              wl_last=$((wl_now - WAL_UPLOAD_EVERY_SEC + 60)) ;;
          *) log error "WAL: выгрузка вне сервера не удалась — повтор через минуту; после восстановления связи уйдёт всё накопленное (RUNBOOK §4.3, §4.8)"
             wl_last=$((wl_now - WAL_UPLOAD_EVERY_SEC + 60)) ;;
        esac
      fi
    fi
    sleep "$WAL_SHIP_EVERY_SEC"
  done
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
  dump="$(pg_bin pg_dump)" || { log error "pg_dump не найден"; return 1; }
  ping_hc /start
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  out="$BACKUPS/${PGDATABASE}_${ts}.dump.age"
  # pg_dump → age: незашифрованные данные на диск не пишутся. set -o pipefail в busybox sh есть.
  # Владельцы и права объектов (pos_migrate — владелец схемы, GRANT для pos_app/pos_readonly/pos_backup; 07 DATA-012)
  # сохраняются в дампе, как в 16 §8.3 (`pg_dump -Fc`): без них восстановленная рабочая БД недоступна роли pos_app.
  # Роль pos_backup читает всё через pg_read_all_data (initdb 10-roles.sh), суперпользователь копии не нужен.
  set -o pipefail
  rc=0
  "$dump" --format=custom | encrypt_partial "$out" || rc=$?
  if commit_partial "$out" "$rc"; then
    log info "дамп создан: $(basename "$out") ($(wc -c < "$out") байт)"
  else
    log error "pg_dump/age завершились с ошибкой"
    ping_hc /fail
    return 1
  fi
  # Дальше дамп уже есть: сбой любого шага ниже — ping /fail и код 1 в конце, но копия сохраняется.
  failed=""
  monthly_link "$out" || failed="$failed monthly"
  if [ "$(date +%u)" = "7" ]; then
    # Роли и членство в ролях, еженедельно (16 §8.2). Без паролей: pos_backup не суперпользователь, а пароли ролей
    # восстанавливаются из защищённой копии secrets/ (RUNBOOK §4.5).
    dumpall="$(pg_bin pg_dumpall)" || dumpall=""
    rc=1
    if [ -n "$dumpall" ]; then
      rc=0
      "$dumpall" --globals-only --no-role-passwords -l "$PGDATABASE" | encrypt_partial "$BACKUPS/globals_${ts}.sql.age" || rc=$?
    fi
    if commit_partial "$BACKUPS/globals_${ts}.sql.age" "$rc"; then
      log info "globals: globals_${ts}.sql.age"
    else
      log error "globals (pg_dumpall --globals-only) не сохранены"
      failed="$failed globals"
    fi
  fi
  # Базовая копия PITR — после дампа, после ночных заданий синхронизации (BACKUP_SCHEDULE, 05:30).
  if pitr_on; then
    base_backup "$ts" || failed="$failed pitr-base"
  fi
  if media_copy; then
    log info "фото: копия на диске копий обновлена (media/)"
  else
    log error "фото: копия на диске копий не обновлена (rclone copy, media/)"
    failed="$failed media"
  fi
  if [ -n "${BACKUP_REMOTE:-}" ]; then
    if offsite_upload; then
      log info "выгружено во внешнее хранилище: db, monthly, media, caddy_data (rclone copy --immutable, без удаления)"
    else
      log error "выгрузка во внешнее хранилище не удалась — повторится со следующим прогоном (RUNBOOK §4.3)"
      failed="$failed offsite"
    fi
  fi
  rotate_local "${BACKUP_KEEP_DAYS:-30}"
  if [ -n "$failed" ]; then
    log error "прогон завершён с ошибками:$failed (дамп БД сохранён)"
    ping_hc /fail
    return 1
  fi
  ping_hc ""
  return 0
}

# Сертификаты общего caddy (16 §8.2): bin/backup-caddy.sh на хосте читает том caddy_data одноразовым контейнером и
# передаёт tar в stdin `store-caddy <метка>` (шифруется сразу, на диск — только *.partial), затем по коду своего
# конвейера вызывает `commit-caddy <метка>` или `discard-caddy <метка>`. Метка — время UTC ГГГГММДДTччммссZ.
caddy_target() { # $1 — метка → путь архива; неверная метка — ошибка
  case "$1" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
    *) log error "caddy_data: неверная метка «$1»"; return 1 ;;
  esac
  printf '%s/caddy_data/caddy_data_%s.tar.age' "$BACKUPS" "$1"
}

store_caddy() {
  if [ -z "${BACKUP_AGE_RECIPIENT:-}" ]; then
    log error "BACKUP_AGE_RECIPIENT не задана: архив сертификатов не сохраняется (OPS-004)"
    return 1
  fi
  out="$(caddy_target "${1:-}")" || return 1
  mkdir -p "$BACKUPS/caddy_data"
  encrypt_partial "$out"
}

commit_caddy() {
  out="$(caddy_target "${1:-}")" || return 1
  if commit_partial "$out" 0; then
    log info "сертификаты caddy: $(basename "$out") ($(wc -c < "$out") байт)"
  else
    log error "сертификаты caddy: архив не сохранён"
    return 1
  fi
}

discard_caddy() {
  out="$(caddy_target "${1:-}")" || return 1
  rm -f "$out.partial"
  log error "сертификаты caddy: чтение тома не удалось, незавершённый архив удалён"
}

# Подключение как библиотеки — только для самопроверки (функции без запуска цикла).
if [ "${BACKUP_SH_LIB:-0}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

case "${1:-daemon}" in
  once)
    run_once
    ;;
  base)
    if ! pitr_on; then
      log error "BACKUP_PITR=off — базовая копия PITR не нужна (включение — RUNBOOK §4.8)"
      exit 2
    fi
    base_backup
    ;;
  wal-ship)
    wal_ship
    ;;
  wal-upload)
    # Ручной догон после перебоя связи (RUNBOOK §4.8): `dc exec backup backup.sh wal-upload`.
    if [ -z "${BACKUP_REMOTE:-}" ]; then
      log error "BACKUP_REMOTE пуст — выгружать WAL некуда (RUNBOOK §4.3)"
      exit 2
    fi
    wu_code=0
    wal_upload || wu_code=$?
    [ "$wu_code" -ne 75 ] || log warn "выгрузку WAL сейчас выполняет другой процесс (цикл WAL или ночной прогон) — повторите через минуту"
    exit "$wu_code"
    ;;
  health)
    health
    ;;
  store-caddy)
    store_caddy "${2:-}"
    ;;
  commit-caddy)
    commit_caddy "${2:-}"
    ;;
  discard-caddy)
    discard_caddy "${2:-}"
    ;;
  daemon)
    schedule="${BACKUP_SCHEDULE:-30 5 * * *}"
    cron_match "$schedule" "0 0 1 1 0" || [ $? -eq 1 ] || { log error "BACKUP_SCHEDULE: неверное cron-выражение"; exit 2; }
    log info "расписание резервного копирования: ${schedule} (TZ=${TZ:-UTC})"
    case "${BACKUP_PITR:-on}" in
      on)
        [ -e "$BACKUPS/.pitr_since" ] || date -u +%s > "$BACKUPS/.pitr_since"
        log info "непрерывная копия WAL включена (BACKUP_PITR=on): спул ${WAL_SPOOL}, вне сервера — раз в 5 минут"
        wal_loop &
        ;;
      off)
        rm -f "$BACKUPS/.pitr_since"
        log warn "непрерывная копия WAL выключена (BACKUP_PITR=off): потеря данных при сбое — до суток (RUNBOOK §4.8)"
        ;;
      *)
        log error "BACKUP_PITR: только on или off"
        exit 2
        ;;
    esac
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
    echo "использование: backup.sh once | daemon | base | wal-ship | wal-upload | health | store-caddy|commit-caddy|discard-caddy <метка> | cron-test <выражение> <время>" >&2
    exit 2
    ;;
esac
