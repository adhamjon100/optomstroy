#!/usr/bin/env python3
"""T-MNY-034 (12; 10 MNY-004, T-NFR-046): MV-01…MV-30 есть в обоих наборах — backend и Flutter.

Набор стороны = ID общего файла `contracts/test-vectors/money.v1.json` (его исполняют
`pos-api/src/common/money/money-vectors.spec.ts` и `pos-app/test/core/utils/money_vectors_test.dart` — проверяется,
что оба теста читают файл) ∪ ID `MV-NN`, упомянутые в тестах стороны. Векторы только одной стороны (форматирование и
отображение на клиенте) перечислены в CLIENT_ONLY с причиной. Ревью F-trace-13.

Запуск из корня: python -I -X utf8 scripts/check_money_vectors.py  → код 0 (полно) / 1 (пропуски).
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VECTORS = ROOT / 'contracts/test-vectors/money.v1.json'
API_RUNNER = ROOT / 'pos-api/src/common/money/money-vectors.spec.ts'
APP_RUNNER = ROOT / 'pos-app/test/core/utils/money_vectors_test.dart'
API_TESTS = (ROOT / 'pos-api/test', ROOT / 'pos-api/src')
APP_TESTS = (ROOT / 'pos-app/test', ROOT / 'pos-app/integration_test')
EXPECTED = {f'MV-{i:02d}' for i in range(1, 31)}
MV = re.compile(r'MV-(\d{2})(?!\d)')

# Векторы, которые по смыслу проверяются только клиентом (10 §18.1, колонка «Функция»).
CLIENT_ONLY = {
    'MV-06': 'baseToPacks — разложение остатка на упаковки для отображения (клиент)',
    'MV-23': 'parseQty «1 200,5» — разбор ввода с пробелом-разрядом и запятой (клиент; API принимает только Quantity)',
    'MV-25': 'formatMoney — форматирование суммы «16 007,50 сом» (клиент)',
}


def ids_in_json() -> set[str]:
    found: set[str] = set()

    def walk(v: object) -> None:
        if isinstance(v, dict):
            for k, x in v.items():
                if k == 'id' and isinstance(x, str) and MV.fullmatch(x):
                    found.add(x)
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)

    walk(json.loads(VECTORS.read_text(encoding='utf8')))
    return found


def ids_in_tests(roots: tuple[Path, ...], suffixes: tuple[str, ...]) -> set[str]:
    out: set[str] = set()
    for r in roots:
        if not r.exists():
            continue
        for p in r.rglob('*'):
            if p.is_file() and p.name.endswith(suffixes) and 'node_modules' not in p.parts:
                out.update(f'MV-{m}' for m in MV.findall(p.read_text(encoding='utf8', errors='ignore')))
    return out


def main() -> int:
    errors: list[str] = []
    shared = ids_in_json()
    for runner in (API_RUNNER, APP_RUNNER):
        if not runner.is_file() or 'money.v1.json' not in runner.read_text(encoding='utf8', errors='ignore'):
            errors.append(f'{runner.relative_to(ROOT).as_posix()}: не исполняет общий файл векторов')
    api = shared | ids_in_tests(API_TESTS, ('.spec.ts', '-spec.ts'))
    app = shared | ids_in_tests(APP_TESTS, ('_test.dart',))
    api_missing = sorted(EXPECTED - api - set(CLIENT_ONLY))
    app_missing = sorted(EXPECTED - app)
    print(f'общий файл: {len(shared & EXPECTED)}/30 ({", ".join(sorted(EXPECTED - shared)) or "все"} — вне файла)')
    server = EXPECTED - set(CLIENT_ONLY)
    print(f'backend: {len(api & server)}/{len(server)} (без векторов только клиента: {", ".join(sorted(CLIENT_ONLY))})')
    print(f'Flutter: {len(app & EXPECTED)}/30')
    if api_missing:
        errors.append('backend без вектора: ' + ', '.join(api_missing))
    if app_missing:
        errors.append('Flutter без вектора: ' + ', '.join(app_missing))
    for e in errors:
        print(f'ERROR: {e}', file=sys.stderr)
    print('check_money_vectors: ' + ('OK' if not errors else f'ошибок {len(errors)}'))
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
