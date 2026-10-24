#!/usr/bin/env python3
"""RM-C-009 п. 2–3: сверка `.env.example` с каноническим перечнем 16_DEPLOYMENT_PLAN §4.3.

Правило 16 §4.3 («Проверка полноты», DEPLOY-014; «Граница R1 / R2»): каждое имя таблицы §4.3 с местом
`.env`, КРОМЕ перечня «R2 и условные», присутствует в `.env.example` активной строкой `ИМЯ=…`, и наоборот —
в `.env.example` нет активных имён вне этого множества (0 лишних, 0 недостающих). Секреты (`*_FILE`, место
«secret …») и имена уровня compose/хоста в `.env.example` не входят.

Дополнительно (RM-C-009 п. 3 «имён вне 16 §4.3 в коде нет»): ключи схемы env pos-api
(`pos-api/src/common/config/env.schema.ts`, объект `envShape`) должны быть именами таблицы §4.3 —
сами по себе или с суффиксом `_FILE` (конвенция *_FILE). Отключается флагом --no-code.

Код выхода: 0 — расхождений нет, 1 — есть расхождения, 2 — ошибка запуска (не найден файл/раздел).
Запуск: python -I -X utf8 scripts/check_env_example.py [--root D:/optomstroy] [--no-code] [--verbose]
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

SPEC = "docs/specification/16_DEPLOYMENT_PLAN.md"
EXAMPLE = ".env.example"
ENV_SCHEMA = "pos-api/src/common/config/env.schema.ts"

NAME_RE = re.compile(r"`([A-Z][A-Z0-9_]*)`")
# Имя переменной сразу в обратных кавычках (не `X=значение`): для перечня «R2 и условные».
EXACT_NAME_RE = re.compile(r"`([A-Z][A-Z0-9_]*[A-Z0-9])`")
ACTIVE_LINE_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=")


class SetupError(Exception):
    pass


def section_43(spec: str) -> str:
    start = spec.find("### 4.3.")
    end = spec.find("### 4.4.", start)
    if start < 0 or end < 0:
        raise SetupError(f"{SPEC}: не найден раздел 4.3")
    return spec[start:end]


def parse_table(sec: str) -> dict[str, str]:
    """Имя → колонка «Где» для каждой строки таблицы §4.3 (строки разделов и `WG_*` пропускаются)."""
    result: dict[str, str] = {}
    in_table = False
    for line in sec.splitlines():
        if line.startswith("| Переменная / секрет"):
            in_table = True
            continue
        if in_table and not line.startswith("|"):
            break
        if not in_table or line.startswith("|---"):
            continue
        cells = [c.strip() for c in line.split("|")[1:-1]]
        if len(cells) < 2 or not cells[0].startswith("`"):
            continue
        first = cells[0]
        if "*" in first:  # `WG_*` — уровень хоста, не переменная окружения процесса
            continue
        for name in NAME_RE.findall(first):
            result[name] = cells[1]
    if not result:
        raise SetupError(f"{SPEC} §4.3: таблица переменных не найдена или пуста")
    return result


def parse_r2_conditional(sec: str) -> set[str]:
    """Перечень «(2) R2 и условные — в .env.example R1 не включаются» (до фразы «Условные переменные валидируются»)."""
    start = sec.find("R2 и условные")
    if start < 0:
        raise SetupError(f"{SPEC} §4.3: не найден перечень «R2 и условные»")
    end = sec.find("Условные переменные валидируются", start)
    if end < 0:
        raise SetupError(f"{SPEC} §4.3: не найдена граница перечня «R2 и условные»")
    return set(EXACT_NAME_RE.findall(sec[start:end]))


def parse_spec_example(sec: str) -> set[str]:
    m = re.search(r"#### Пример `\.env\.example`.*?```dotenv\n(.*?)```", sec, re.S)
    if not m:
        raise SetupError(f"{SPEC} §4.3: не найден пример .env.example")
    return parse_active_names(m.group(1))[0]


def parse_active_names(text: str) -> tuple[set[str], list[str]]:
    names: set[str] = set()
    dups: list[str] = []
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        m = ACTIVE_LINE_RE.match(line)
        if m:
            if m.group(1) in names:
                dups.append(m.group(1))
            names.add(m.group(1))
    return names, dups


def parse_schema_keys(text: str) -> set[str]:
    m = re.search(r"export const envShape = \{(.*?)\n\} as const;", text, re.S)
    if not m:
        raise SetupError(f"{ENV_SCHEMA}: не найден объект envShape")
    return set(re.findall(r"^\s{2}([A-Z][A-Z0-9_]*):", m.group(1), re.M))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument("--no-code", action="store_true", help="не сверять ключи схемы env pos-api")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    root = Path(args.root)

    try:
        spec_path, example_path = root / SPEC, root / EXAMPLE
        for p in (spec_path, example_path):
            if not p.is_file():
                raise SetupError(f"не найден файл {p}")
        sec = section_43(spec_path.read_text(encoding="utf-8"))
        table = parse_table(sec)
        excluded = parse_r2_conditional(sec)
        spec_example = parse_spec_example(sec)
        actual, dups = parse_active_names(example_path.read_text(encoding="utf-8"))
    except SetupError as e:
        print(f"check_env_example: {e}", file=sys.stderr)
        return 2

    env_placed = {n for n, where in table.items() if "`.env`" in where}
    unknown_excluded = sorted(excluded - set(table))
    expected = env_placed - excluded

    errors: list[str] = []
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    for n in missing:
        errors.append(f"недостающая: {n} (16 §4.3, место `.env`) нет в {EXAMPLE}")
    for n in extra:
        reason = "нет в таблице 16 §4.3" if n not in table else (
            "в перечне «R2 и условные»" if n in excluded else f"место «{table[n]}», а не `.env`")
        errors.append(f"лишняя: {n} — {reason}")
    for n in dups:
        errors.append(f"повтор: {n} задана в {EXAMPLE} несколько раз")
    for n in unknown_excluded:
        errors.append(f"перечень «R2 и условные» 16 §4.3 называет {n}, которой нет в таблице")

    warnings: list[str] = []
    if spec_example != expected:
        warnings.append(
            "пример .env.example в 16 §4.3 расходится с таблицей: "
            f"нет {sorted(expected - spec_example)}, лишние {sorted(spec_example - expected)}")

    code_checked = 0
    if not args.no_code:
        schema_path = root / ENV_SCHEMA
        if schema_path.is_file():
            keys = parse_schema_keys(schema_path.read_text(encoding="utf-8"))
            code_checked = len(keys)
            for k in sorted(keys):
                if k not in table and f"{k}_FILE" not in table:
                    errors.append(f"код: {ENV_SCHEMA} читает {k} (или {k}_FILE) — имени нет в 16 §4.3")
        else:
            warnings.append(f"{ENV_SCHEMA} не найден — сверка кода пропущена")

    if args.verbose:
        print(f"таблица 16 §4.3: {len(table)} имён; место `.env`: {len(env_placed)}; "
              f"R2/условные: {len(excluded)}; ожидается в {EXAMPLE}: {len(expected)}")
        print("R2/условные:", ", ".join(sorted(excluded)))
    for w in warnings:
        print(f"WARN  {w}")
    for e in errors:
        print(f"ERROR {e}")
    print(f"check_env_example: ожидается {len(expected)}, в {EXAMPLE} {len(actual)}; "
          f"недостающих {len(missing)}, лишних {len(extra)}; ключей схемы pos-api проверено {code_checked}; "
          f"ошибок {len(errors)}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
