#!/usr/bin/env bash
# scripts/check_no_double_money.sh — запрет плавающей точки в деньгах и количествах (13 §6.1 п. 7; 12 C-08,
# T-MNY-030; 10 MNY-002, D-19; ревью C-MN-05; E: EQ-FINT-05, R2-N-01). Деньги: клиент — int тыйыны (`Money`),
# сервер — NUMERIC-строки + decimal.js (`common/money`); количества: клиент — int milli (`Qty`), сервер — `Quantity`.
#
# Проверки (0 совпадений = успех):
#   1. pos-app/lib (кроме design_system/** — геометрия UI законно double — и сгенерированных файлов):
#      ни одного `double`, `num`-денег, `.toDouble()`, `RealColumn`/`real()` drift;
#   2. pos-app/lib целиком (включая design_system): нет переменных/полей/параметров double|num с «денежным» или
#      «количественным» именем (price, amount, total, money, tyiyn, discount, qty, quantity, balance, subtotal,
#      creditLimit, cost);
#   3. pos-api/src (кроме *.spec.ts и сгенерированных): нет полей/параметров `: number` и приведений `as number`
#      с денежным/количественным именем; нет parseFloat(), Number(<деньги>), унарного `+<деньги>`, Decimal.toNumber();
#      нет SQL-приведения денежного/количественного столбца к float/real/double precision;
#   4. pos-api/migrations/*.sql: денежные/количественные столбцы не объявлены как real/float/double precision.
#
# Исключение — ТОЛЬКО строка с пометкой `money-double: allow — <причина>` (причина обязательна: что это за число
# и почему не деньги — счётчик строк, число знаков, метрика). Пометка без причины — сама нарушение. Белого списка
# имён нет намеренно: имя `total`/`prices` может быть и счётчиком, и деньгами — решает пометка у конкретной строки.
#
# Запуск (из корня репозитория): bash scripts/check_no_double_money.sh [--self-test]
#   CHECK_ROOT=<каталог> — проверить другой корень (с pos-app/lib и pos-api/src).
#   --self-test — положительный и отрицательный контроль правил на временном дереве (репозиторий не читается).
# Код выхода: 0 — нарушений нет; 1 — найдены нарушения (или самопроверка не прошла); 2 — нет каталогов.
set -u

NAMES='(price|amount|total|money|tyiyn|discount|qty|quantity|balance|subtotal|credit_?limit|cost)'
# Пометка-исключение с непустой причиной: «money-double: allow — причина» (тире «—» или «-»).
ALLOW_OK='money-double: allow[[:space:]]+(—|-)[[:space:]]*[^[:space:]].{2,}'

run_checks() { # $1 — корень; печатает нарушения; код 0/1/2
  local root="$1"
  local APP="$root/pos-app/lib" API="$root/pos-api/src" MIG="$root/pos-api/migrations"
  [ -d "$APP" ] && [ -d "$API" ] || { echo "check_no_double_money: нет $APP или $API" >&2; return 2; }
  local found=0

  report() { # $1 — правило, $2 — строки grep
    local rule="$1" lines="$2" bad
    [ -z "$lines" ] && return 0
    # Пометка без причины не освобождает строку и сама считается нарушением.
    bad="$(printf '%s\n' "$lines" | grep -vE "$ALLOW_OK" || true)"
    [ -z "$bad" ] && return 0
    echo "НАРУШЕНИЕ [$rule]:"
    printf '%s\n' "$bad" | sed 's/^/  /'
    found=1
  }

  dart_files() { # файлы pos-app/lib без сгенерированных; $1 — исключить design_system (1/0)
    if [ "$1" = 1 ]; then
      find "$APP" -type f -name '*.dart' ! -name '*.g.dart' ! -name '*.freezed.dart' \
        ! -path '*/l10n/app_localizations*.dart' ! -path '*/design_system/*' | sort
    else
      find "$APP" -type f -name '*.dart' ! -name '*.g.dart' ! -name '*.freezed.dart' \
        ! -path '*/l10n/app_localizations*.dart' | sort
    fi
  }

  local files files_all api_files mig_files r
  # 1. Код денег/количеств и данных клиента — без плавающей точки вообще.
  files="$(dart_files 1)"
  # shellcheck disable=SC2086
  r="$(grep -HnE '(^|[^A-Za-z0-9_])(double|num)([^A-Za-z0-9_]|$)|\.toDouble\(|RealColumn|[^A-Za-z0-9_]real\(\)' $files 2>/dev/null \
    | grep -vE '^\S+:[0-9]+:\s*(//|///|\*)' || true)"
  report "app: double/num/RealColumn вне design_system" "$r"

  # 2. Денежные/количественные имена с типом double|num — нигде в pos-app/lib.
  files_all="$(dart_files 0)"
  # shellcheck disable=SC2086
  r="$(grep -HniE "(double|num)\??\s+[A-Za-z_]*${NAMES}[A-Za-z_]*\s*[=;,)]" $files_all 2>/dev/null || true)"
  report "app: double|num с денежным/количественным именем" "$r"

  # 3. Backend: number/as number для денег и количеств, parseFloat, Number(<деньги>), +<деньги>, toNumber(), SQL float.
  api_files="$(find "$API" -type f -name '*.ts' ! -name '*.spec.ts' ! -name '*.generated.ts' ! -name 'enums.ts' | sort)"
  # Унарный плюс: `= +price`, `return +price`, `=> +r.price`, `(+row.amount)` — префикс-объект необязателен
  # (ревью E RC-2: голый идентификатор и стрелочная функция раньше проходили).
  local ident='[A-Za-z_$][A-Za-z0-9_$.?!]*'
  # shellcheck disable=SC2086
  r="$(grep -HniE "${NAMES}[A-Za-z_]*\??\s*:\s*number\b|${NAMES}[A-Za-z_]*\)?\s+as\s+number\b|parseFloat\(|Number\([^)]*${NAMES}|([=(,:?[]|=>|return)\s*\+\s*(${ident})?${NAMES}|\.toNumber\(\)|${NAMES}[a-z_]*\"?\)?\s*::\s*(float[48]?|real|double precision)\b" $api_files 2>/dev/null \
    | grep -vE '^\S+:[0-9]+:\s*(//|\*)' || true)"
  report "api: number/parseFloat/+x/toNumber/SQL float для денег и количеств" "$r"

  # 4. Схема БД: денежные/количественные столбцы — только NUMERIC.
  if [ -d "$MIG" ]; then
    mig_files="$(find "$MIG" -type f -name '*.sql' | sort)"
    if [ -n "$mig_files" ]; then
      # shellcheck disable=SC2086
      r="$(grep -HniE "^\s*\"?[a-z_]*${NAMES}[a-z_]*\"?\s+(real|float[48]?|double precision)\b" $mig_files 2>/dev/null \
        | grep -vE '^\S+:[0-9]+:\s*--' || true)"
      report "db: real/float/double precision для денег и количеств" "$r"
    fi
  fi

  if [ "$found" -ne 0 ]; then
    echo "check_no_double_money: НАЙДЕНЫ нарушения (MNY-002): деньги — Money/NUMERIC, количества — Qty/Quantity."
    return 1
  fi
  local n_app n_api
  n_app=$(printf '%s\n' "$files_all" | grep -c . || true)
  n_api=$(printf '%s\n' "$api_files" | grep -c . || true)
  echo "check_no_double_money: OK — 0 совпадений (pos-app/lib: $n_app файлов, pos-api/src: $n_api файлов)"
  return 0
}

self_test() {
  local tmp failed=0 out
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  mk() { # $1 — относительный путь, $2 — содержимое
    mkdir -p "$(dirname "$tmp/$1")"
    printf '%s\n' "$2" >"$tmp/$1"
  }
  base() { # чистое дерево: негативные образцы (нарушений быть не должно)
    rm -rf "${tmp:?}/pos-app" "${tmp:?}/pos-api"
    mk pos-app/lib/core/money.dart 'final class Money { final int tyiyn; const Money(this.tyiyn); }'
    mk pos-app/lib/design_system/box.dart 'const double gap = 8;'
    mk pos-app/lib/features/a.dart 'final int count = 1;'
    mk pos-api/src/money.ts "$(printf '%s\n' \
      "export const price: string = '10.00';" \
      "export const totalEstimate: number = 0; // money-double: allow — число строк (count), не деньги" \
      "const sql = 'SELECT similarity(a, b)::float8 AS score';" \
      "export const label = 'итого: ' + total;"       "export const joined = prefix + price;"       "export const keyed = (r: { id: string }) => r.id + amountSuffix;")"
    mk pos-api/migrations/0001.sql "$(printf '%s\n' 'CREATE TABLE p (' '  price numeric(14,2) NOT NULL,' '  score real' ');')"
  }
  expect() { # $1 — ожидаемый код (0/1), $2 — описание
    out="$(run_checks "$tmp" 2>&1)"
    local code=$?
    if [ "$code" -eq "$1" ]; then echo "  ok   $2"; else
      echo "  FAIL $2 (код $code, ожидался $1)"
      printf '%s\n' "$out" | sed 's/^/       /'
      failed=1
    fi
  }
  base
  expect 0 "чистое дерево: счётчик с пометкой и причиной, score::float8, конкатенация строк — не нарушения"
  local -a positives=(
    "pos-app/lib/features/b.dart|final double price = 1.5;"
    "pos-app/lib/features/b.dart|final x = row.amount.toDouble();"
    "pos-app/lib/design_system/c.dart|num totalSum = 0;"
    "pos-api/src/b.ts|export interface L { amount: number }"
    "pos-api/src/b.ts|const p = parseFloat(s);"
    "pos-api/src/b.ts|const p = Number(row.price);"
    "pos-api/src/b.ts|const p = +row.price;"
    "pos-api/src/b.ts|return +line.amount;"
    "pos-api/src/b.ts|export function f(price: string) { return +price; }"
    "pos-api/src/b.ts|const g = (amount: string) => +amount * 2;"
    "pos-api/src/b.ts|const h = (r: { price: string }) => +r.price;"
    "pos-api/src/b.ts|const s = [+total, 1];"
    "pos-api/src/b.ts|const q = (row.qty as number) * 2;"
    "pos-api/src/b.ts|const v = new Decimal(s).toNumber();"
    "pos-api/src/b.ts|const sql = 'SELECT price::float8 FROM prices';"
    "pos-api/src/b.ts|const sql = 'SELECT sum(amount)::double precision FROM payments';"
    "pos-api/migrations/0002.sql|  amount double precision NOT NULL,"
    "pos-api/src/b.ts|export const total: number = 0; // money-double: allow"
    "pos-api/src/b.ts|export const total: number = 0; // money-double: allow — "
  )
  local p path body
  for p in "${positives[@]}"; do
    base
    path="${p%%|*}"
    body="${p#*|}"
    mk "$path" "$body"
    expect 1 "находка: $path: $body"
  done
  [ "$failed" -eq 0 ] && echo "check_no_double_money --self-test: OK" || echo "check_no_double_money --self-test: FAIL"
  return "$failed"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi
ROOT="${CHECK_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
run_checks "$ROOT"
exit $?
