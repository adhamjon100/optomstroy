#!/bin/sh
# Генерирует ОДНОРАЗОВЫЕ секреты тестового контура (RM-C-012) в каталог <out> (по умолчанию infra/secrets).
# Каталог исключён из git правилом `**/secrets/` (.gitignore). Значения не печатаются (16 §4.3; infra/env/README.md §3).
# Существующие файлы не перезаписываются: повторный запуск ничего не меняет (пароли в томе pgdata остаются валидными).
#
# Использование: sh infra/docker/scripts/gen-test-secrets.sh [<out>]
# Требуется: POSIX sh, openssl (есть на раннерах ubuntu-latest и в Git Bash).
# Имена файлов — 16 §4.4 (секреты compose); набор — только то, что монтирует infra/compose.test.yml.
set -eu

OUT="${1:-infra/secrets}"
DB_NAME="${POSTGRES_DB:-optomstroy_test}"
KID="${JWT_KEY_ID:-test-1}"

umask 077
mkdir -p "$OUT"

# Пароли — hex (без символов, требующих URL-кодирования в database_url).
gen_hex() {
  f="$OUT/$1"
  if [ ! -s "$f" ]; then
    openssl rand -hex "$2" > "$f"
    echo "создан: $f"
  fi
}

gen_hex pg_password 24            # суперпользователь образа postgres (инициализация, backup)
gen_hex db_migrator_password 24   # роль pos_migrate — владелец схемы (07 DATA-012; читает только migrate)
gen_hex otp_pepper 32             # HMAC OTP (api и worker — 16 §4.4, EQ-AUTH-08)
gen_hex pin_pepper 32             # pepper Argon2id PIN (только api)

# database_url: пользователь pos_app (роль приложения без DDL). Пароль pos_app нигде больше не хранится:
# initdb-скрипт postgres берёт его из этого же файла (infra/docker/postgres/initdb/10-roles.sh).
if [ ! -s "$OUT/database_url" ]; then
  app_pw="$(openssl rand -hex 24)"
  printf 'postgres://pos_app:%s@postgres:5432/%s\n' "$app_pw" "$DB_NAME" > "$OUT/database_url"
  app_pw=""
  echo "создан: $OUT/database_url"
fi

# Ключ подписи JWT ES256 (09: access JWT ES256; набор публичных ключей {kid: pem} — R0 §17.7).
if [ ! -s "$OUT/jwt_private.pem" ]; then
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$OUT/jwt_private.pem" 2>/dev/null
  echo "создан: $OUT/jwt_private.pem"
  rm -f "$OUT/jwt_public.json"
fi
if [ ! -s "$OUT/jwt_public.json" ]; then
  openssl pkey -in "$OUT/jwt_private.pem" -pubout 2>/dev/null \
    | awk -v kid="$KID" 'BEGIN { printf "{\"%s\":\"", kid } { printf "%s\\n", $0 } END { print "\"}" }' \
    > "$OUT/jwt_public.json"
  echo "создан: $OUT/jwt_public.json"
fi

# Права. Compose без Swarm монтирует file-секреты bind-mount'ом с владельцем и правами хоста, а процессы
# контейнеров работают под своими uid (api/worker/migrate — 10001, backup — 10002, postgres — 999). Поэтому
# ОДНОРАЗОВЫМ тестовым секретам даются права 644 (каталог 755). Для prod/staging на сервере — 600 и владелец
# по 16 §4.2 (infra/env/README.md §3); этот скрипт там не применяется.
chmod 755 "$OUT"
chmod 644 "$OUT"/*
echo "секреты тестового контура: $OUT (значения не выводятся)"
