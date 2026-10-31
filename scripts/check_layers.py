#!/usr/bin/env python3
"""Проверка правил слоёв Flutter-клиента по импортам (RM-C-002).

Правила — docs/reviews/B_architecture_review.md §5.1 (по 06 §6.1, L-1…L-10).
Скрипт заменяет custom_lint-плагин, пока набор генераторов на Dart 3.10.7
несовместим с custom_lint (pos-app/NOTES.md §1, §4). Проверяются правила,
которые выражаются через импорты:

  FL-01 domain_pure            features/*/domain/**, core/error/** — без фреймворков и чужих слоёв
  FL-02 presentation_no_data   features/*/presentation/** — без data, dio, drift, secure storage, core/{network,database,storage,hardware}
  FL-03 feature_public_api     межфичевые импорты — только domain/** и <b>_providers.dart владельца и только по DAG 06 §6.1
  FL-04 core_no_features       core/** — без features/**, design_system/**
  FL-05 design_system_isolated design_system/** — без features/**, core/{network,database,storage,sync}/**, dio, drift
  FL-06 composition_root       features/<f>/data/** импортирует только своя data и app/di/overrides.dart (*_bindings.dart)
  FL-07 providers_contract     features/<b>/<b>_providers.dart — без своей data/** и presentation/**
  FL-11 no_cycles              граф импортов между фичами ацикличен
  AP-01 app_is_root            (дополнительно) features/**, core/**, design_system/** не импортируют app/** —
                               app/ — композиционный корень (06 §6.10), обратная зависимость дала бы цикл
  DM-01 demo_isolated          (ADR-113, 06 §6.10) app/demo/** (точка входа веб-демо) импортируется и экспортируется
                               только из app/demo/** — в том числе условным импортом; lib/main.dart и остальной lib/
                               его не достают, в сборки Windows и Android демо-код не попадает. Сам app/demo/** —
                               второй композиционный корень: опирается только на app/demo/**, app/bootstrap.dart,
                               core/** и пакеты (без features/**, design_system/** и прочего app/**).
                               Директивы `part` и `part of` проверяются так же, как import и export

FL-08 (литералы цветов/строк), FL-09 (ручная правка сгенерированного) и FL-10
(double для денег) — не про импорты; они — следующая итерация (custom_lint/AST).
Тесты (test/**) из проверки исключены (§5.1). Сгенерированные файлы
(*.g.dart, *.freezed.dart, lib/core/l10n/app_localizations*.dart) не проверяются.

Запуск (из корня репозитория):
  python -I -X utf8 scripts/check_layers.py              # проверить pos-app/lib
  python -I -X utf8 scripts/check_layers.py --self-test  # проверить сами правила на синтетических примерах
  python -I -X utf8 scripts/check_layers.py --root <lib>  # другой каталог lib/

Коды выхода: 0 — нарушений нет; 1 — есть нарушения (или self-test не прошёл); 2 — ошибка запуска.
"""

from __future__ import annotations

import argparse
import posixpath
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_LIB = ROOT / "pos-app" / "lib"
PACKAGE = "optomstroy"  # pos-app/pubspec.yaml: name

# DAG фич 06 §6.1 (кто может импортировать domain / <b>_providers.dart кого).
FEATURE_DAG: dict[str, frozenset[str]] = {
    "auth": frozenset(),
    "customers": frozenset(),
    "notifications": frozenset(),
    "sync_status": frozenset(),
    "admin": frozenset(),
    "splash": frozenset(),
    "cart": frozenset({"customers"}),
    "catalog": frozenset({"cart"}),
    "product_details": frozenset({"catalog", "cart"}),
    "favorites": frozenset({"catalog", "customers"}),
    "orders": frozenset({"customers"}),
    "cashier": frozenset({"orders", "customers"}),
    "checkout": frozenset({"cart", "customers", "orders", "cashier"}),
    "transactions": frozenset({"orders", "cashier", "customers"}),
    "returns": frozenset({"orders", "cashier", "customers"}),
    "reports": frozenset({"transactions"}),
    "registration": frozenset({"auth"}),
    "profile": frozenset({"auth"}),
    "settings": frozenset({"auth", "profile"}),
}

FL01_PACKAGES = (
    "flutter",
    "flutter_riverpod",
    "riverpod",
    "riverpod_annotation",
    "hooks_riverpod",
    "dio",
    "drift",
    "drift_flutter",
    "go_router",
    "flutter_secure_storage",
    "json_annotation",
)
FL01_PREFIXES = ("dart:ui",)
FL01_CORE = ("network", "database", "storage", "sync", "hardware", "connectivity", "di", "session")
FL02_PACKAGES = ("dio", "drift", "drift_flutter", "flutter_secure_storage")
FL02_CORE = ("network", "database", "storage", "hardware")
FL05_PACKAGES = ("dio", "drift", "drift_flutter")
FL05_CORE = ("network", "database", "storage", "sync")
DM01_DEMO = "app/demo/"
DM01_DEMO_MAY_IMPORT = ("app/demo/", "core/")  # префиксы путей
DM01_DEMO_MAY_IMPORT_FILES = ("app/bootstrap.dart",)

GENERATED = (
    re.compile(r".*\.g\.dart$"),
    re.compile(r".*\.freezed\.dart$"),
    re.compile(r"^core/l10n/app_localizations.*\.dart$"),
)

# import/export и part/part of (ревью R-02: `part 'demo/x.dart';` включает файл app/demo/** в библиотеку снаружи так
# же, как импорт). `part` — только перед строкой URI или `of`, чтобы не ловить идентификатор (`part = ...`).
DIRECTIVE = re.compile(r"""^\s*(import|export|part(?=\s*(?:of\b|['"])))\b(.*?);""", re.MULTILINE | re.DOTALL)
STRING = re.compile(r"""(['"])(.*?)\1""")


@dataclass(frozen=True)
class Target:
    """Цель импорта: внутренний путь (относительно lib/) или внешний пакет/dart:."""

    internal: str | None  # 'features/cart/domain/cart.dart'
    package: str | None  # 'dio' или 'dart:ui'


@dataclass(frozen=True)
class Violation:
    rule: str
    file: str
    line: int
    uri: str
    reason: str

    def __str__(self) -> str:
        return f"{self.rule} lib/{self.file}:{self.line}: '{self.uri}' — {self.reason}"


def parse_directives(source: str) -> list[tuple[int, str]]:
    """Возвращает (номер строки, uri) для import/export/part/part of, включая условные импорты."""
    found: list[tuple[int, str]] = []
    no_comments = re.sub(r"//[^\n]*", lambda m: " " * len(m.group(0)), source)
    no_comments = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), no_comments, flags=re.DOTALL)
    for match in DIRECTIVE.finditer(no_comments):
        line = no_comments.count("\n", 0, match.start()) + 1
        for string in STRING.finditer(match.group(2)):
            found.append((line, string.group(2)))
    return found


def resolve(file: str, uri: str) -> Target:
    if uri.startswith("dart:"):
        return Target(None, uri)
    if uri.startswith("package:"):
        rest = uri[len("package:") :]
        name, _, path = rest.partition("/")
        if name == PACKAGE:
            return Target(posixpath.normpath(path), None)
        return Target(None, name)
    joined = posixpath.normpath(posixpath.join(posixpath.dirname(file), uri))
    return Target(joined, None)


def _feature(path: str) -> tuple[str, str] | None:
    """('cart', 'domain/...') для features/cart/domain/..., иначе None."""
    parts = path.split("/")
    if len(parts) >= 3 and parts[0] == "features":
        return parts[1], "/".join(parts[2:])
    return None


def _layer(rest: str) -> str:
    return rest.split("/", 1)[0] if "/" in rest else ""


def _in_core(path: str, subdirs: tuple[str, ...]) -> bool:
    parts = path.split("/")
    return len(parts) >= 2 and parts[0] == "core" and parts[1] in subdirs


def _pkg_matches(package: str | None, names: tuple[str, ...]) -> bool:
    return package is not None and package in names


def check_import(file: str, line: int, uri: str) -> list[Violation]:
    target = resolve(file, uri)
    out: list[Violation] = []

    def add(rule: str, reason: str) -> None:
        out.append(Violation(rule, file, line, uri, reason))

    src_feature = _feature(file)
    dst = target.internal

    # FL-01 domain_pure
    is_domain = (src_feature is not None and _layer(src_feature[1]) == "domain") or file.startswith("core/error/")
    if is_domain:
        if _pkg_matches(target.package, FL01_PACKAGES) or (
            target.package is not None and target.package.startswith(FL01_PREFIXES)
        ):
            add("FL-01", "domain не зависит от фреймворков (flutter, riverpod, dio, drift, go_router, secure storage, json_annotation)")
        if dst is not None:
            dst_feature = _feature(dst)
            if dst_feature is not None and _layer(dst_feature[1]) in ("data", "presentation"):
                add("FL-01", "domain не импортирует data/presentation")
            if _in_core(dst, FL01_CORE) or dst.startswith("design_system/"):
                add("FL-01", "domain не импортирует core/{network,database,storage,sync,hardware,connectivity,di,session} и design_system")

    # FL-02 presentation_no_data
    if src_feature is not None and _layer(src_feature[1]) == "presentation":
        if _pkg_matches(target.package, FL02_PACKAGES):
            add("FL-02", "presentation не использует dio/drift/secure storage напрямую")
        if dst is not None:
            dst_feature = _feature(dst)
            if dst_feature is not None and _layer(dst_feature[1]) == "data":
                add("FL-02", "presentation не импортирует data (только провайдеры-интерфейсы)")
            if _in_core(dst, FL02_CORE):
                add("FL-02", "presentation не импортирует core/{network,database,storage,hardware}")

    # FL-03 feature_public_api
    if src_feature is not None and dst is not None:
        dst_feature = _feature(dst)
        if dst_feature is not None and dst_feature[0] != src_feature[0]:
            a, b = src_feature[0], dst_feature[0]
            public = _layer(dst_feature[1]) == "domain" or dst_feature[1] == f"{b}_providers.dart"
            if not public:
                add("FL-03", f"фича {a} импортирует непубличную часть фичи {b} (разрешены domain/** и {b}_providers.dart)")
            elif b not in FEATURE_DAG.get(a, frozenset()):
                add("FL-03", f"ребро {a} → {b} отсутствует в DAG фич 06 §6.1")

    # FL-04 core_no_features
    if file.startswith("core/") and dst is not None:
        if dst.startswith("features/") or dst.startswith("design_system/"):
            add("FL-04", "core не знает о features и design_system")

    # FL-05 design_system_isolated
    if file.startswith("design_system/"):
        if _pkg_matches(target.package, FL05_PACKAGES):
            add("FL-05", "design_system не использует dio/drift")
        if dst is not None and (dst.startswith("features/") or _in_core(dst, FL05_CORE)):
            add("FL-05", "design_system не импортирует features и core/{network,database,storage,sync}")

    # FL-06 composition_root
    if dst is not None:
        dst_feature = _feature(dst)
        if dst_feature is not None and _layer(dst_feature[1]) == "data":
            own_data = src_feature is not None and src_feature[0] == dst_feature[0] and _layer(src_feature[1]) == "data"
            root = file == "app/di/overrides.dart" and dst.endswith("_bindings.dart")
            if not (own_data or root):
                add("FL-06", "features/<f>/data/** импортирует только своя data и app/di/overrides.dart (*_bindings.dart)")

    # FL-07 providers_contract
    if src_feature is not None and src_feature[1] == f"{src_feature[0]}_providers.dart" and dst is not None:
        dst_feature = _feature(dst)
        if dst_feature is not None and dst_feature[0] == src_feature[0] and _layer(dst_feature[1]) in ("data", "presentation"):
            add("FL-07", "публичный файл провайдеров не связывает реализации (без data/presentation)")

    # AP-01 app_is_root (дополнительно)
    if dst is not None and dst.startswith("app/") and not file.startswith("app/") and file != "main.dart":
        add("AP-01", "app/ — композиционный корень; features/core/design_system его не импортируют")

    # DM-01 demo_isolated (ADR-113, 06 §6.10)
    if dst is not None:
        src_demo = file.startswith(DM01_DEMO)
        if dst.startswith(DM01_DEMO) and not src_demo:
            add("DM-01", "демо-код app/demo/** импортируется только из app/demo/** (lib/main.dart и остальной lib/ его не достают)")
        if src_demo and not (dst.startswith(DM01_DEMO_MAY_IMPORT) or dst in DM01_DEMO_MAY_IMPORT_FILES):
            add("DM-01", "app/demo/** опирается только на app/demo/**, app/bootstrap.dart и core/** (без features/**, design_system/** и прочего app/**)")

    return out


def find_cycles(edges: dict[str, set[str]]) -> list[list[str]]:
    """Простые циклы графа фич (DFS)."""
    cycles: list[list[str]] = []
    seen: set[tuple[str, ...]] = set()

    def dfs(node: str, stack: list[str]) -> None:
        for nxt in sorted(edges.get(node, ())):
            if nxt in stack:
                cycle = stack[stack.index(nxt) :]
                key = tuple(sorted(cycle))
                if key not in seen:
                    seen.add(key)
                    cycles.append(cycle + [nxt])
            elif len(stack) < 50:
                dfs(nxt, stack + [nxt])

    for start in sorted(edges):
        dfs(start, [start])
    return cycles


def check_sources(files: dict[str, str]) -> tuple[list[Violation], int]:
    """files: путь относительно lib/ -> текст. Возвращает (нарушения, число импортов)."""
    violations: list[Violation] = []
    edges: dict[str, set[str]] = {}
    count = 0
    for path in sorted(files):
        if any(p.match(path) for p in GENERATED):
            continue
        for line, uri in parse_directives(files[path]):
            count += 1
            violations.extend(check_import(path, line, uri))
            src_feature = _feature(path)
            target = resolve(path, uri)
            if src_feature and target.internal:
                dst_feature = _feature(target.internal)
                if dst_feature and dst_feature[0] != src_feature[0]:
                    edges.setdefault(src_feature[0], set()).add(dst_feature[0])
    for cycle in find_cycles(edges):
        violations.append(Violation("FL-11", f"features/{cycle[0]}", 0, " → ".join(cycle), "цикл импортов между фичами"))
    return violations, count


def load_lib(lib: Path) -> dict[str, str]:
    return {p.relative_to(lib).as_posix(): p.read_text(encoding="utf-8") for p in sorted(lib.rglob("*.dart"))}


SELF_TEST: list[tuple[str, str, set[str]]] = [
    # (файл, импорт, ожидаемые правила)
    ("features/cart/domain/cart.dart", "package:flutter/material.dart", {"FL-01"}),
    ("features/cart/domain/cart.dart", "package:flutter_riverpod/flutter_riverpod.dart", {"FL-01"}),
    ("features/cart/domain/cart.dart", "package:dio/dio.dart", {"FL-01"}),
    ("features/cart/domain/cart.dart", "package:drift/drift.dart", {"FL-01"}),
    ("features/cart/domain/cart.dart", "package:freezed_annotation/freezed_annotation.dart", set()),
    ("features/cart/domain/cart.dart", "../data/cart_dto.dart", {"FL-01", "FL-06"}),
    ("features/cart/domain/cart.dart", "package:optomstroy/core/network/dio_client.dart", {"FL-01"}),
    ("features/cart/domain/cart.dart", "package:optomstroy/core/error/failure.dart", set()),
    ("core/error/failure.dart", "package:dio/dio.dart", {"FL-01"}),
    ("features/cart/presentation/screens/cart_screen.dart", "package:dio/dio.dart", {"FL-02"}),
    ("features/cart/presentation/screens/cart_screen.dart", "../../data/cart_repository_impl.dart", {"FL-02", "FL-06"}),
    ("features/cart/presentation/screens/cart_screen.dart", "package:optomstroy/core/database/app_database.dart", {"FL-02"}),
    ("features/cart/presentation/screens/cart_screen.dart", "package:optomstroy/core/di/core_providers.dart", set()),
    ("features/cart/presentation/screens/cart_screen.dart", "package:optomstroy/design_system/theme/app_theme.dart", set()),
    ("features/catalog/presentation/x.dart", "package:optomstroy/features/cart/cart_providers.dart", set()),
    ("features/catalog/presentation/x.dart", "package:optomstroy/features/cart/domain/cart.dart", set()),
    ("features/catalog/presentation/x.dart", "package:optomstroy/features/cart/presentation/w.dart", {"FL-03"}),
    ("features/cart/presentation/x.dart", "package:optomstroy/features/catalog/domain/product.dart", {"FL-03"}),
    ("features/auth/presentation/x.dart", "package:optomstroy/features/profile/domain/p.dart", {"FL-03"}),
    ("core/sync/outbox_queue.dart", "package:optomstroy/features/cart/domain/cart.dart", {"FL-04"}),
    ("core/utils/money.dart", "package:optomstroy/design_system/tokens/colors.dart", {"FL-04"}),
    ("design_system/components/x.dart", "package:optomstroy/features/cart/domain/cart.dart", {"FL-05"}),
    ("design_system/components/x.dart", "package:optomstroy/core/l10n/app_localizations.dart", set()),
    ("design_system/components/x.dart", "package:drift/drift.dart", {"FL-05"}),
    ("app/di/overrides.dart", "package:optomstroy/features/cart/data/cart_bindings.dart", set()),
    ("app/di/overrides.dart", "package:optomstroy/features/cart/data/cart_repository_impl.dart", {"FL-06"}),
    ("app/app.dart", "package:optomstroy/features/cart/data/cart_bindings.dart", {"FL-06"}),
    ("features/cart/data/cart_bindings.dart", "repositories/cart_repository_impl.dart", set()),
    ("features/cart/cart_providers.dart", "data/cart_repository_impl.dart", {"FL-06", "FL-07"}),
    ("features/cart/cart_providers.dart", "presentation/x.dart", {"FL-07"}),
    ("features/cart/cart_providers.dart", "domain/cart_repository.dart", set()),
    ("features/splash/presentation/s.dart", "package:optomstroy/app/router/routes.dart", {"AP-01"}),
    ("app/router/routes.dart", "package:optomstroy/features/splash/presentation/screens/splash_screen.dart", set()),
    # DM-01 demo_isolated — T-DEMO-001 (12 §3.22, ADR-113): в демо-код не входят снаружи…
    ("main.dart", "package:optomstroy/app/demo/main_web_demo.dart", {"DM-01"}),
    ("main.dart", "app/demo/demo_overrides.dart", {"DM-01"}),
    ("app/router/app_router.dart", "package:optomstroy/app/demo/demo_overrides.dart", {"DM-01"}),
    ("app/bootstrap.dart", "demo/demo_bridge.dart", {"DM-01"}),
    ("app/di/overrides.dart", "package:optomstroy/app/demo/demo_bridge_adapter.dart", {"DM-01"}),
    ("core/di/core_providers.dart", "package:optomstroy/app/demo/demo_bridge.dart", {"AP-01", "DM-01"}),
    ("features/catalog/data/x.dart", "package:optomstroy/app/demo/demo_bridge.dart", {"AP-01", "DM-01"}),
    ("app/demo_like.dart", "package:optomstroy/app/demo/demo_bridge.dart", {"DM-01"}),
    # …а сам демо-код не достаёт фичи, дизайн-систему и прочий app/**
    ("app/demo/demo_overrides.dart", "package:optomstroy/features/cart/cart_providers.dart", {"DM-01"}),
    ("app/demo/demo_overrides.dart", "package:optomstroy/features/cart/data/cart_bindings.dart", {"DM-01", "FL-06"}),
    ("app/demo/main_web_demo.dart", "package:optomstroy/design_system/theme/app_theme.dart", {"DM-01"}),
    ("app/demo/demo_overrides.dart", "package:optomstroy/app/di/overrides.dart", {"DM-01"}),
    ("app/demo/main_web_demo.dart", "package:optomstroy/app/app.dart", {"DM-01"}),
    ("app/demo/main_web_demo.dart", "package:optomstroy/main.dart", {"DM-01"}),
    ("app/demo/main_web_demo.dart", "../../features/auth/auth_providers.dart", {"DM-01"}),
    # разрешено: app/demo/**, app/bootstrap.dart, core/**, пакеты и dart:
    ("app/demo/main_web_demo.dart", "package:optomstroy/app/bootstrap.dart", set()),
    ("app/demo/main_web_demo.dart", "../bootstrap.dart", set()),
    ("app/demo/demo_overrides.dart", "package:optomstroy/core/di/core_providers.dart", set()),
    ("app/demo/demo_bridge.dart", "package:optomstroy/app/demo/demo_bridge_stub.dart", set()),
    ("app/demo/demo_bridge.dart", "demo_bridge_web.dart", set()),
    ("app/demo/demo_bridge_adapter.dart", "package:dio/dio.dart", set()),
    ("app/demo/demo_bridge_web.dart", "dart:js_interop", set()),
]

# DM-01 на целых файлах: условный импорт, export и part (T-DEMO-001). (файл, текст, ожидаемые правила)
SELF_TEST_SOURCES: list[tuple[str, str, set[str]]] = [
    # part включает демо-код в библиотеку вне app/demo — как импорт (ревью R-02)
    ("app/bootstrap.dart", "part 'demo/x.dart';\n", {"DM-01"}),
    ("main.dart", "part 'package:optomstroy/app/demo/main_web_demo.dart';\n", {"DM-01"}),
    ("app/demo/x.dart", "part of '../bootstrap.dart';\n", set()),
    ("app/demo/x.dart", "part of '../app.dart';\n", {"DM-01"}),
    # `part` как идентификатор — не директива
    ("app/demo/x.dart", "var part = 'package:optomstroy/features/x/x.dart';\nvoid f() {\n  part = '../../features/y.dart';\n}\n", set()),
    (
        "main.dart",
        "import 'package:optomstroy/app/app.dart'\n    if (dart.library.js_interop) 'package:optomstroy/app/demo/main_web_demo.dart';\n",
        {"DM-01"},
    ),
    (
        "app/app.dart",
        "import 'package:optomstroy/core/network/dio_client.dart' if (dart.library.js_interop) 'demo/demo_bridge_web.dart';\n",
        {"DM-01"},
    ),
    ("app/di/overrides.dart", "export 'package:optomstroy/app/demo/demo_overrides.dart' show demoOverrides;\n", {"DM-01"}),
    (
        "app/demo/demo_bridge.dart",
        "import 'package:optomstroy/app/demo/demo_bridge_stub.dart'\n"
        "    if (dart.library.js_interop) 'package:optomstroy/app/demo/demo_bridge_web.dart' as platform;\n",
        set(),
    ),
    (
        "app/demo/demo_bridge.dart",
        "import 'demo_bridge_stub.dart' if (dart.library.js_interop) 'package:optomstroy/features/x/x_providers.dart';\n",
        {"DM-01"},
    ),
]


def self_test() -> int:
    failed = 0
    for file, uri, expected in SELF_TEST:
        got = {v.rule for v in check_import(file, 1, uri)}
        if got != expected:
            failed += 1
            print(f"ПРОВАЛ {file} <- {uri}: ожидалось {sorted(expected)}, получено {sorted(got)}")
    # FL-11: цикл cart -> catalog -> cart
    files = {
        "features/cart/domain/a.dart": "import 'package:optomstroy/features/catalog/domain/b.dart';",
        "features/catalog/domain/b.dart": "import 'package:optomstroy/features/cart/domain/a.dart';",
    }
    rules = {v.rule for v in check_sources(files)[0]}
    if "FL-11" not in rules:
        failed += 1
        print(f"ПРОВАЛ FL-11: цикл не найден, правила: {sorted(rules)}")
    # Разбор директив: многострочный и условный импорт, комментарии.
    parsed = parse_directives(
        "// import 'package:dio/dio.dart';\n"
        "import 'a.dart'\n    if (dart.library.io) 'b.dart' as x;\n"
        "export 'c.dart' show C;\n/* import 'd.dart'; */\n"
    )
    if [u for _, u in parsed] != ["a.dart", "b.dart", "c.dart"]:
        failed += 1
        print(f"ПРОВАЛ разбор директив: {parsed}")
    for file, source, expected in SELF_TEST_SOURCES:
        got = {v.rule for v in check_sources({file: source})[0]}
        if got != expected:
            failed += 1
            print(f"ПРОВАЛ {file} (исходник): ожидалось {sorted(expected)}, получено {sorted(got)}")
    total = len(SELF_TEST) + 2 + len(SELF_TEST_SOURCES)
    print(f"self-test: {total - failed}/{total} проверок пройдено")
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=DEFAULT_LIB, help="каталог lib/ приложения")
    parser.add_argument("--self-test", action="store_true", help="проверить правила на синтетических примерах")
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    lib: Path = args.root
    if not lib.is_dir():
        print(f"ОШИБКА: нет каталога {lib}")
        return 2
    files = load_lib(lib)
    violations, imports = check_sources(files)
    checked = sum(1 for p in files if not any(g.match(p) for g in GENERATED))
    for violation in violations:
        print(violation)
    print(f"check_layers: файлов {checked}, импортов {imports}, нарушений {len(violations)}")
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
