#!/usr/bin/env python3
"""RM-C-001: сверка дерева репозитория (уровни 1–2) с docs/repo_layout.md §2.

Замена `tree -L 2` (в Git Bash для Windows утилиты tree нет). Учитываются только файлы, которые
могут попасть в git: `git ls-files` + `git ls-files --others --exclude-standard`. Поэтому
игнорируемые (.dart_tool/, build/, node_modules/, .idea/, *.iml, pubspec.lock не игнорируется) не мешают.

Правила (repo_layout.md, начало и §2):
  - элемент уровня 1, которого нет в §2, — ошибка;
  - каталог уровня 1 должен входить в «Нормативный перечень каталогов уровня 1»;
  - каталог уровня 2, которого нет в §2, — ошибка;
  - файл уровня 2, которого нет в §2, — предупреждение (допускается, если его вводит задача 13);
    если в §2 у каталога уровня 1 не перечислено ни одного дочернего элемента
    (scripts/, resursi/, onec-extension/), его содержимое не сверяется;
  - элемент §2, которого ещё нет, — информация (его создаёт задача, указанная в комментарии).

Код выхода: 0 — ошибок нет, 1 — есть ошибки, 2 — ошибка запуска.
Запуск: python -I -X utf8 scripts/check_repo_layout.py [--root D:/optomstroy] [--tree]
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

LAYOUT = "docs/repo_layout.md"
CONNECTOR = re.compile(r"^(?P<indent>(?:│   |    )*)(?:├── |└── )(?P<name>\S+)(?:\s+#\s*(?P<comment>.*))?$")
LOCKS_AND_TOOLING = {"pubspec.lock", "package-lock.json", ".metadata"}


def parse_layout(text: str) -> tuple[dict[str, dict[str, str]], dict[str, str], set[str]]:
    """Возвращает (дети уровня 2 по каталогу уровня 1, комментарии уровня 1, нормативный перечень)."""
    sec2 = text.split("## 2.", 1)[1].split("## 3.", 1)[0]
    block = sec2.split("```", 2)[1]
    level1: dict[str, str] = {}
    level2: dict[str, dict[str, str]] = {}
    current = None
    for line in block.splitlines():
        m = CONNECTOR.match(line.rstrip())
        if not m:
            continue
        depth = len(m.group("indent")) // 4 + 1
        name = m.group("name").rstrip("/")
        comment = (m.group("comment") or "").strip()
        if depth == 1:
            current = name
            level1[name] = comment
            level2.setdefault(name, {})
        elif depth == 2 and current:
            level2[current][name] = comment
    norm_block = text.split("Нормативный перечень каталогов уровня 1", 1)[1].split("```", 2)[1]
    normative = set(norm_block.split())
    return level2, level1, normative


def git_paths(root: Path) -> list[str]:
    def run(args: list[str]) -> list[str]:
        res = subprocess.run(["git", "-C", str(root), *args], capture_output=True, check=True)
        return [p for p in res.stdout.decode("utf-8").split("\0") if p]

    paths = set(run(["ls-files", "-z", "--cached"])) | set(run(["ls-files", "-z", "--others", "--exclude-standard"]))
    return sorted(p for p in paths if (root / p).exists())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    ap.add_argument("--tree", action="store_true", help="напечатать фактическое дерево уровней 1–2")
    args = ap.parse_args()
    root: Path = args.root.resolve()
    try:
        level2_doc, level1_doc, normative = parse_layout((root / LAYOUT).read_text(encoding="utf-8"))
        paths = git_paths(root)
    except (OSError, IndexError, subprocess.CalledProcessError) as e:
        print(f"ошибка запуска: {e}", file=sys.stderr)
        return 2

    # Фактическое дерево: элемент -> признак каталога.
    actual1: dict[str, bool] = {}
    actual2: dict[str, dict[str, bool]] = {}
    for p in paths:
        parts = p.split("/")
        actual1[parts[0]] = actual1.get(parts[0], False) or len(parts) > 1
        if len(parts) > 1:
            actual2.setdefault(parts[0], {})
            actual2[parts[0]][parts[1]] = actual2[parts[0]].get(parts[1], False) or len(parts) > 2

    errors: list[str] = []
    warnings: list[str] = []
    infos: list[str] = []

    for name, is_dir in sorted(actual1.items()):
        if name not in level1_doc:
            errors.append(f"уровень 1: «{name}{'/' if is_dir else ''}» нет в {LAYOUT} §2")
        elif is_dir and name not in normative:
            errors.append(f"уровень 1: каталог «{name}/» нет в нормативном перечне")
    for name, comment in level1_doc.items():
        if name not in actual1:
            infos.append(f"ещё нет: {name} — {comment}")

    for d1, children in sorted(actual2.items()):
        doc_children = level2_doc.get(d1, {})
        for name, is_dir in sorted(children.items()):
            if name in doc_children:
                continue
            if not doc_children:
                continue  # содержимое каталога в §2 не детализировано
            if is_dir:
                errors.append(f"уровень 2: каталог «{d1}/{name}/» нет в {LAYOUT} §2")
            elif name not in LOCKS_AND_TOOLING:
                warnings.append(f"уровень 2: файл «{d1}/{name}» не перечислен в §2 (допустим, если его вводит задача 13)")
        for name, comment in doc_children.items():
            if d1 in actual2 and name not in actual2[d1]:
                infos.append(f"ещё нет: {d1}/{name} — {comment}")

    if args.tree:
        print(".")
        items1 = sorted(actual1.items())
        for i, (n1, is_dir) in enumerate(items1):
            last1 = i == len(items1) - 1
            print(f"{'└── ' if last1 else '├── '}{n1}{'/' if is_dir else ''}")
            items2 = sorted(actual2.get(n1, {}).items())
            for j, (n2, d2) in enumerate(items2):
                pad = "    " if last1 else "│   "
                print(f"{pad}{'└── ' if j == len(items2) - 1 else '├── '}{n2}{'/' if d2 else ''}")
        print()

    for s in infos:
        print(f"INFO  {s}")
    for s in warnings:
        print(f"WARN  {s}")
    for s in errors:
        print(f"ERROR {s}")
    print(f"check_repo_layout: файлов {len(paths)}; ошибок {len(errors)}, предупреждений {len(warnings)}, "
          f"ожидающих задач {len(infos)}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
