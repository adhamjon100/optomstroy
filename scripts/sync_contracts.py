#!/usr/bin/env python3
"""Копирует контракты в pos-app и проверяет идентичность копий (RM-C-002).

Источник истины — contracts/ (этап B). Копии в pos-app руками не правятся
(правило FL-09 «generated_readonly», docs/reviews/B_architecture_review.md §5.1).

Сейчас синхронизируется:
  contracts/l10n/app_*.arb  ->  pos-app/lib/l10n/app_*.arb   (RM-B-007 -> RM-C-002, побайтно)
  contracts/l10n/app_*.arb  ->  pos-app/lib/l10n/gen_input/app_*.arb
      (вход flutter gen-l10n: плейсхолдеры — зарезервированные слова Dart,
       например `new`, переименованы в `<имя>Value`; см. GEN_INPUT_DIR)

Запуск (из корня репозитория):
  python -I -X utf8 scripts/sync_contracts.py           # скопировать
  python -I -X utf8 scripts/sync_contracts.py --check   # только сверить

Коды выхода: 0 — копии идентичны (или скопированы); 1 — расхождение (--check)
или нет исходных файлов; 2 — ошибка аргументов.
Сравнение побайтовое; лишние app_*.arb в приёмнике считаются расхождением
(при копировании удаляются). Сетевых запросов нет, сторонних модулей нет.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class Mapping:
    """Пара «каталог-источник → каталог-копия» с маской файлов."""

    name: str
    source: Path
    target: Path
    pattern: str


MAPPINGS: tuple[Mapping, ...] = (
    Mapping(
        name="l10n",
        source=ROOT / "contracts" / "l10n",
        target=ROOT / "pos-app" / "lib" / "l10n",
        pattern="app_*.arb",
    ),
)

# --- Вход для flutter gen-l10n ------------------------------------------------
# gen-l10n превращает плейсхолдеры ARB в имена параметров Dart. Зарезервированное
# слово Dart (например `new` в `cart_line_price_changed`) ломает генерацию
# («'new' can't be used as an identifier»). Копия lib/l10n остаётся побайтно
# равной contracts/l10n, а gen-l10n читает lib/l10n/gen_input/ — ту же копию,
# где такие плейсхолдеры переименованы в `<имя>Value` (pos-app/NOTES.md §3).
# Когда контракт исправят (RM-B-007, build_arb.py), преобразование станет
# тождественным.
GEN_INPUT_DIR = ROOT / "pos-app" / "lib" / "l10n" / "gen_input"

# Зарезервированные слова Dart, которые нельзя использовать как идентификатор
# (контекстные слова вроде `base`, `get`, `on` допустимы).
DART_RESERVED = frozenset(
    "assert break case catch class const continue default do else enum extends "
    "false final finally for if in is new null rethrow return super switch this "
    "throw true try var void while with".split()
)


def gen_input_text(src_text: str) -> tuple[str, list[str]]:
    """Возвращает ARB для gen-l10n и список переименований «ключ:старое->новое»."""
    data = json.loads(src_text)
    renames: list[str] = []
    for key in [k for k in data if not k.startswith("@")]:
        meta = data.get(f"@{key}")
        if not isinstance(meta, dict) or not isinstance(meta.get("placeholders"), dict):
            continue
        bad = [name for name in meta["placeholders"] if name in DART_RESERVED]
        if not bad:
            continue
        message = data[key]
        placeholders = {}
        for name, spec in meta["placeholders"].items():
            new_name = f"{name}Value" if name in bad else name
            placeholders[new_name] = spec
        for name in bad:
            message = re.sub(r"\{(\s*)" + re.escape(name) + r"(\s*[,}])", r"{\g<1>" + name + r"Value\g<2>", message)
            renames.append(f"{key}:{name}->{name}Value")
        meta["placeholders"] = placeholders
        data[key] = message
    return json.dumps(data, ensure_ascii=False, indent=2) + "\n", renames


def gen_input_problems(mapping: Mapping) -> list[str]:
    """Сверяет lib/l10n/gen_input/*.arb с преобразованием исходных ARB."""
    if mapping.name != "l10n":
        return []
    problems: list[str] = []
    sources = {p.name: p for p in sorted(mapping.source.glob(mapping.pattern))}
    present = {p.name: p for p in sorted(GEN_INPUT_DIR.glob(mapping.pattern))} if GEN_INPUT_DIR.is_dir() else {}
    for name, src in sources.items():
        expected, _ = gen_input_text(src.read_text(encoding="utf-8"))
        dst = present.get(name)
        if dst is None:
            problems.append(f"gen_input: нет файла {_rel(GEN_INPUT_DIR / name)}")
        elif dst.read_bytes() != expected.encode("utf-8"):
            problems.append(f"gen_input: {_rel(dst)} не совпадает с преобразованием {_rel(src)}")
    for name in sorted(set(present) - set(sources)):
        problems.append(f"gen_input: лишний файл {_rel(present[name])}")
    return problems


def write_gen_input(mapping: Mapping) -> None:
    if mapping.name != "l10n":
        return
    GEN_INPUT_DIR.mkdir(parents=True, exist_ok=True)
    names = set()
    for src in sorted(mapping.source.glob(mapping.pattern)):
        names.add(src.name)
        text, renames = gen_input_text(src.read_text(encoding="utf-8"))
        dst = GEN_INPUT_DIR / src.name
        if not dst.exists() or dst.read_bytes() != text.encode("utf-8"):
            dst.write_bytes(text.encode("utf-8"))
            print(f"  gen_input: записан {_rel(dst)}")
        for item in renames:
            print(f"  gen_input: {src.name}: плейсхолдер {item} (зарезервированное слово Dart)")
    for extra in sorted(GEN_INPUT_DIR.glob(mapping.pattern)):
        if extra.name not in names:
            extra.unlink()
            print(f"  gen_input: удалён лишний {_rel(extra)}")


def _digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def check(mapping: Mapping) -> list[str]:
    """Возвращает список расхождений (пустой — копия идентична)."""
    problems: list[str] = []
    sources = {p.name: p for p in sorted(mapping.source.glob(mapping.pattern))}
    if not sources:
        return [f"{mapping.name}: нет исходных файлов {_rel(mapping.source)}/{mapping.pattern}"]
    targets = (
        {p.name: p for p in sorted(mapping.target.glob(mapping.pattern))}
        if mapping.target.is_dir()
        else {}
    )
    for name, src in sources.items():
        dst = targets.get(name)
        if dst is None:
            problems.append(f"{mapping.name}: нет копии {_rel(mapping.target / name)}")
        elif _digest(src) != _digest(dst):
            problems.append(f"{mapping.name}: копия отличается от источника: {_rel(dst)} != {_rel(src)}")
    for name in sorted(set(targets) - set(sources)):
        problems.append(f"{mapping.name}: лишний файл без источника: {_rel(targets[name])}")
    return problems


def sync(mapping: Mapping) -> int:
    """Копирует файлы источника и удаляет лишние копии. Возвращает число изменений."""
    sources = sorted(mapping.source.glob(mapping.pattern))
    if not sources:
        raise FileNotFoundError(f"нет исходных файлов {_rel(mapping.source)}/{mapping.pattern}")
    mapping.target.mkdir(parents=True, exist_ok=True)
    changed = 0
    names = set()
    for src in sources:
        names.add(src.name)
        dst = mapping.target / src.name
        if not dst.exists() or _digest(src) != _digest(dst):
            shutil.copyfile(src, dst)
            print(f"  скопирован {_rel(src)} -> {_rel(dst)}")
            changed += 1
    for extra in sorted(mapping.target.glob(mapping.pattern)):
        if extra.name not in names:
            extra.unlink()
            print(f"  удалён лишний {_rel(extra)}")
            changed += 1
    return changed


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="только сверить копии с contracts/, ничего не менять")
    args = parser.parse_args(argv)

    if args.check:
        problems: list[str] = []
        for mapping in MAPPINGS:
            copy_problems = check(mapping)
            gen_problems = gen_input_problems(mapping)
            problems.extend(copy_problems + gen_problems)
            count = len(list(mapping.source.glob(mapping.pattern)))
            if not copy_problems:
                print(f"OK {mapping.name}: {count} файл(ов) идентичны ({_rel(mapping.source)} == {_rel(mapping.target)})")
            if mapping.name == "l10n" and not gen_problems:
                print(f"OK {mapping.name}: {_rel(GEN_INPUT_DIR)} соответствует преобразованию источника")
        for problem in problems:
            print(f"ОШИБКА {problem}")
        return 1 if problems else 0

    total = 0
    for mapping in MAPPINGS:
        try:
            changed = sync(mapping)
        except FileNotFoundError as exc:
            print(f"ОШИБКА {mapping.name}: {exc}")
            return 1
        write_gen_input(mapping)
        total += changed
        print(f"{mapping.name}: изменений {changed}")
    remaining = [p for m in MAPPINGS for p in check(m) + gen_input_problems(m)]
    for problem in remaining:
        print(f"ОШИБКА {problem}")
    return 1 if remaining else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
