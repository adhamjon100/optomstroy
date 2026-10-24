#!/usr/bin/env python3
"""RM-F-007 «Выходы»: таблица docs/errors_matrix.md «код → строка ARB → действие» (ревью F-trace-12).

Источники (без ручного дублирования):
- коды и HTTP-статусы ошибок — contracts/enums.json `problemCodes` (= 08 §2.4, `ProblemCode`);
- коды предупреждений — contracts/enums.json `apiEnums[warning_code]` (08 §2.4 «Предупреждения»);
- ключ ARB и действие UI — исчерпывающие `switch` в pos-app/lib/core/error/error_mapper.dart
  (`UiErrorMapper.forProblem`, `forWarning`), значения ключей — `ErrorKeys`;
- текст строки — pos-app/lib/l10n/app_ru.arb (копия contracts/l10n, 02 §7).

Запуск из корня:
  python -I -X utf8 scripts/gen_errors_matrix.py           # записать docs/errors_matrix.md
  python -I -X utf8 scripts/gen_errors_matrix.py --check   # сверить файл с источниками (код 1 — устарел/неполон)
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENUMS = ROOT / 'contracts/enums.json'
MAPPER = ROOT / 'pos-app/lib/core/error/error_mapper.dart'
ARB = ROOT / 'pos-app/lib/l10n/app_ru.arb'
OUT = ROOT / 'docs/errors_matrix.md'


def camel(code: str) -> str:
    head, *rest = code.lower().split('_')
    return head + ''.join(p.capitalize() for p in rest)


def switch_rows(src: str, fn: str, enum: str) -> dict[str, tuple[str, str]]:
    start = src.index(f'static UiError {fn}(')
    end = src.index('};', start)
    body = src[start:end]
    rx = re.compile(enum + r'\.(\w+)\s*=>\s*\w\(\s*ErrorKeys\.(\w+),\s*ErrorAction\.(\w+)\s*,?\s*\)', re.S)
    return {m.group(1): (m.group(2), m.group(3)) for m in rx.finditer(body)}


def build() -> tuple[str, list[str]]:
    errors: list[str] = []
    enums = json.loads(ENUMS.read_text(encoding='utf8'))
    problems: list[dict] = enums['problemCodes']
    warnings = next(e['values'] for e in enums['apiEnums'] if e.get('name') == 'warning_code')
    src = MAPPER.read_text(encoding='utf8')
    keys = dict(re.findall(r"static const String (\w+) = '([\w.]+)';", src))
    arb = json.loads(ARB.read_text(encoding='utf8'))
    prob_map = switch_rows(src, 'forProblem', 'ProblemCode')
    warn_map = switch_rows(src, 'forWarning', 'WarningCode')

    def row(code: str, http: str, mapped: tuple[str, str] | None) -> str:
        if mapped is None:
            errors.append(f'{code}: нет строки в UiErrorMapper')
            return f'| `{code}` | {http} | — | — | — |'
        key = keys.get(mapped[0])
        if key is None:
            errors.append(f'{code}: ErrorKeys.{mapped[0]} не объявлен')
            return f'| `{code}` | {http} | ? | — | `{mapped[1]}` |'
        text = arb.get(key)
        if not isinstance(text, str):
            errors.append(f'{code}: ключа {key} нет в app_ru.arb')
            text = '—'
        text = text.replace('|', '\\|').replace('\n', ' ')
        return f'| `{code}` | {http} | `{key}` | {text} | `{mapped[1]}` |'

    lines = [
        '# Ошибки API → строка ARB → действие клиента',
        '',
        'Выход RM-F-007 (13 §3.6). **Генерируется** `python -I -X utf8 scripts/gen_errors_matrix.py` из',
        '`contracts/enums.json` (08 §2.4: `problemCodes`, `warning_code`), `pos-app/lib/core/error/error_mapper.dart`',
        '(`UiErrorMapper`, `ErrorKeys`) и `pos-app/lib/l10n/app_ru.arb`; руками не править. Проверка актуальности —',
        '`--check` (код 1 — файл устарел или код без строки ARB/действия). Действия — `ErrorAction` (08 §2.4',
        '«Что делает клиент»).',
        '',
        '## Ошибки (`Problem.code`)',
        '',
        '| Код | HTTP | Ключ ARB | Текст (ru) | Действие |',
        '|---|---|---|---|---|',
    ]
    for p in problems:
        lines.append(row(p['code'], ', '.join(str(h) for h in p['http']), prob_map.get(camel(p['code']))))
    lines += [
        '',
        '## Предупреждения успешного ответа (`warnings[].code`)',
        '',
        '| Код | HTTP | Ключ ARB | Текст (ru) | Действие |',
        '|---|---|---|---|---|',
    ]
    for w in warnings:
        lines.append(row(w, '2xx', warn_map.get(camel(w))))
    extra = (set(prob_map) - {camel(p['code']) for p in problems}) | (set(warn_map) - {camel(w) for w in warnings})
    for x in sorted(extra):
        errors.append(f'{x}: в UiErrorMapper, но нет в contracts/enums.json')
    return '\n'.join(lines) + '\n', errors


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true')
    args = ap.parse_args()
    text, errors = build()
    if args.check:
        current = OUT.read_text(encoding='utf8') if OUT.is_file() else ''
        if current != text:
            errors.append(f'{OUT.relative_to(ROOT).as_posix()} устарел — перезапустите gen_errors_matrix.py')
    else:
        OUT.write_text(text, encoding='utf8')
    for e in errors:
        print(f'ERROR: {e}', file=sys.stderr)
    print(f'gen_errors_matrix: {"проверка" if args.check else "записано"}; ошибок {len(errors)}')
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
