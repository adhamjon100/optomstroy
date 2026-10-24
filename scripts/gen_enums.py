#!/usr/bin/env python3
"""RM-B-009: генератор TS и Dart из contracts/enums.json.

Запуск:
    python -I -X utf8 scripts/gen_enums.py <out_dir> [--input contracts/enums.json]
    python -I -X utf8 scripts/gen_enums.py --out <out_dir>

Пишет <out_dir>/enums.ts и <out_dir>/enums.dart. Вывод детерминирован: порядок — как в enums.json,
без отметок времени, перевод строки LF, UTF-8 без BOM; в заголовке — sha256 канонической формы входа
(json.dumps с sort_keys), поэтому окончания строк файла-источника на хеш не влияют.
Целевые места в репозитории (pos-api/src/common/enums.ts, pos-app/lib/core/enums.dart) — задачи
RM-C-005 и RM-C-004; на этапе B генерация выполняется во временный каталог.
Код выхода: 0 — успех, 1 — ошибка входных данных, 2 — ошибка запуска.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

DART_RESERVED = {
    # ключевые слова и встроенные идентификаторы Dart 3
    "abstract", "as", "assert", "async", "await", "base", "break", "case", "catch", "class", "const",
    "continue", "covariant", "default", "deferred", "do", "dynamic", "else", "enum", "export", "extends",
    "extension", "external", "factory", "false", "final", "finally", "for", "Function", "get", "hide",
    "if", "implements", "import", "in", "interface", "is", "late", "library", "mixin", "new", "null",
    "of", "on", "operator", "part", "required", "rethrow", "return", "sealed", "set", "show", "static",
    "super", "switch", "sync", "this", "throw", "true", "try", "typedef", "var", "void", "when",
    "while", "with", "yield",
    # члены enum и сгенерированного класса
    "values", "index", "name", "hashCode", "runtimeType", "toString", "noSuchMethod", "value",
    "httpStatuses", "tryParse",
}

NAME_RE = re.compile(r"^[a-z][a-z0-9]*(_[a-z0-9]+)*$")
VALUE_RE = re.compile(r"^[A-Za-z][A-Za-z0-9]*(_[A-Za-z0-9]+)*$")


class InputError(Exception):
    pass


# ---------------------------------------------------------------- naming
def pascal(name: str) -> str:
    return "".join(p[:1].upper() + p[1:] for p in name.split("_"))


def upper_snake(name: str) -> str:
    return name.upper()


def dart_member(value: str) -> str:
    parts = value.lower().split("_")
    ident = parts[0] + "".join(p[:1].upper() + p[1:] for p in parts[1:])
    if ident in DART_RESERVED:
        ident += "Value"
    return ident


def comment_safe(s: str) -> str:
    return s.replace("*/", "*\\/").replace("\r", " ").replace("\n", " ")


# ---------------------------------------------------------------- model
def load(path: Path) -> tuple[dict, str]:
    raw = path.read_text(encoding="utf-8")
    data = json.loads(raw)
    canon = json.dumps(data, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return data, hashlib.sha256(canon.encode("utf-8")).hexdigest()


def build_model(data: dict) -> list[dict]:
    """Единый список перечней в порядке вывода: dbEnums, checkLists, apiEnums, problem_code."""
    items: list[dict] = []
    for e in data["dbEnums"]:
        items.append({"group": "db", "name": e["name"], "values": e["values"],
                      "doc": [f"{e['name']} — 07 §6.1 (CREATE TYPE). Источник: {e['source']}.",
                              f"Используется: {e['usage']}."]
                      + ([f"Не используются: {', '.join(e['notUsed'])}."] if e.get("notUsed") else [])})
    for e in data["checkLists"]:
        items.append({"group": "check", "name": e["name"], "values": e["values"], "columns": e["columns"],
                      "doc": [f"{e['name']} — 07 §6.1.1 (CHECK). Поля: {', '.join(e['columns'])}.",
                              f"Источник: {e['source']}."]
                      + ([f"Не используются: {', '.join(e['notUsed'])}."] if e.get("notUsed") else [])})
    for e in data["apiEnums"]:
        items.append({"group": "api", "name": e["name"], "values": e["values"],
                      "doc": [f"{e['name']} — {e['source']}."]
                      + ([f"Не используются: {', '.join(e['notUsed'])}."] if e.get("notUsed") else [])})
    items.append({"group": "problem", "name": "problem_code",
                  "values": [p["code"] for p in data["problemCodes"]],
                  "http": [p["http"] for p in data["problemCodes"]],
                  "doc": ["problem_code — Problem.code, 08 §2.4 (владелец словаря, ядро §18.1).",
                          "Клиент ветвится только по code и HTTP-статусу; неизвестный code — как INTERNAL того же класса."]})

    errors: list[str] = []
    seen_names: set[str] = set()
    seen_types: set[str] = set()
    for it in items:
        n = it["name"]
        if not NAME_RE.match(n):
            errors.append(f"{n}: недопустимое имя перечня")
        if n in seen_names:
            errors.append(f"{n}: имя перечня повторяется")
        seen_names.add(n)
        t = pascal(n)
        if t in seen_types:
            errors.append(f"{n}: имя типа {t} повторяется")
        seen_types.add(t)
        if not it["values"]:
            errors.append(f"{n}: пустой перечень")
        if len(set(it["values"])) != len(it["values"]):
            errors.append(f"{n}: значения повторяются")
        members: dict[str, str] = {}
        for v in it["values"]:
            if not VALUE_RE.match(v):
                errors.append(f"{n}: недопустимое значение {v!r}")
                continue
            m = dart_member(v)
            if m in members:
                errors.append(f"{n}: значения {members[m]!r} и {v!r} дают одинаковый идентификатор Dart {m!r}")
            members[m] = v
    if errors:
        raise InputError("; ".join(errors))
    return items


# ---------------------------------------------------------------- TypeScript
GROUP_TITLES = {
    "db": "07 §6.1 — типы PostgreSQL (CREATE TYPE … AS ENUM)",
    "check": "07 §6.1.1 — CHECK-перечни текстовых полей",
    "api": "08 §2.4, §3.8 — перечни контракта API",
    "problem": "08 §2.4 — коды ошибок Problem.code",
}


def gen_ts(items: list[dict], version: str, digest: str) -> str:
    out: list[str] = [
        "// GENERATED FILE — DO NOT EDIT.",
        f"// Source: contracts/enums.json (optomstroy-pos-enums {version}, sha256 {digest})",
        "// Generator: scripts/gen_enums.py (RM-B-009). Owners: 07 §6.1/§6.1.1, 08 §2.4/§3.8 (R0 §18.1).",
        "/* eslint-disable */",
        "",
        f"export const ENUMS_CONTRACT_VERSION = '{version}' as const;",
        "",
    ]
    group = None
    for it in items:
        if it["group"] != group:
            group = it["group"]
            out += [f"// ===== {GROUP_TITLES[group]} =====", ""]
        T = pascal(it["name"])
        C = upper_snake(it["name"]) + "_VALUES"
        out.append("/**")
        out += [f" * {comment_safe(d)}" for d in it["doc"]]
        out.append(" */")
        out.append(f"export const {C} = [")
        out += [f"  '{v}'," for v in it["values"]]
        out.append("] as const;")
        out.append(f"export type {T} = (typeof {C})[number];")
        out.append(f"export function is{T}(value: unknown): value is {T} {{")
        out.append(f"  return typeof value === 'string' && ({C} as readonly string[]).includes(value);")
        out.append("}")
        out.append("")
    # HTTP-статусы кодов ошибок
    prob = next(i for i in items if i["group"] == "problem")
    out.append("/** HTTP-статусы для каждого Problem.code (08 §2.4, столбец «HTTP»). */")
    out.append("export const PROBLEM_CODE_HTTP_STATUS: { readonly [K in ProblemCode]: readonly number[] } = {")
    for code, http in zip(prob["values"], prob["http"]):
        out.append(f"  {code}: [{', '.join(str(h) for h in http)}],")
    out.append("};")
    out.append("")
    # реестры
    out.append("/** Реестр типов PostgreSQL: имя типа → значения в порядке CREATE TYPE (07 §6.1; тест pg_enum, DATA-200). */")
    out.append("export const DB_ENUMS = {")
    for it in items:
        if it["group"] == "db":
            out.append(f"  {it['name']}: {upper_snake(it['name'])}_VALUES,")
    out.append("} as const;")
    out.append("")
    out.append("/** Реестр CHECK-перечней: поле таблицы → допустимые значения (07 §6.1.1). */")
    out.append("export const CHECK_LISTS = {")
    for it in items:
        if it["group"] == "check":
            for col in it["columns"]:
                out.append(f"  '{col}': {upper_snake(it['name'])}_VALUES,")
    out.append("} as const;")
    out.append("")
    return "\n".join(out)


# ---------------------------------------------------------------- Dart
def gen_dart(items: list[dict], version: str, digest: str) -> str:
    out: list[str] = [
        "// GENERATED FILE — DO NOT EDIT.",
        f"// Source: contracts/enums.json (optomstroy-pos-enums {version}, sha256 {digest})",
        "// Generator: scripts/gen_enums.py (RM-B-009). Owners: 07 §6.1/§6.1.1, 08 §2.4/§3.8 (R0 §18.1).",
        "// ignore_for_file: lines_longer_than_80_chars",
        "",
        f"const String enumsContractVersion = '{version}';",
        "",
    ]
    group = None
    for it in items:
        if it["group"] != group:
            group = it["group"]
            out += [f"// ===== {GROUP_TITLES[group]} =====", ""]
        T = pascal(it["name"])
        is_problem = it["group"] == "problem"
        out += [f"/// {comment_safe(d)}" for d in it["doc"]]
        out.append(f"enum {T} {{")
        n = len(it["values"])
        for idx, v in enumerate(it["values"]):
            end = ";" if idx == n - 1 else ","
            if is_problem:
                http = ", ".join(str(h) for h in it["http"][idx])
                out.append(f"  {dart_member(v)}('{v}', [{http}]){end}")
            else:
                out.append(f"  {dart_member(v)}('{v}'){end}")
        out.append("")
        if is_problem:
            out.append(f"  const {T}(this.value, this.httpStatuses);")
        else:
            out.append(f"  const {T}(this.value);")
        out.append("")
        out.append("  /// Значение в API и БД — ровно как в документе-владельце.")
        out.append("  final String value;")
        if is_problem:
            out.append("")
            out.append("  /// Допустимые HTTP-статусы ответа с этим кодом (08 §2.4).")
            out.append("  final List<int> httpStatuses;")
        out.append("")
        out.append(f"  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).")
        out.append(f"  static {T}? tryParse(String? value) {{")
        out.append(f"    for (final item in {T}.values) {{")
        out.append("      if (item.value == value) return item;")
        out.append("    }")
        out.append("    return null;")
        out.append("  }")
        out.append("}")
        out.append("")
    out.append("/// Реестр типов PostgreSQL: имя типа → значения в порядке CREATE TYPE (07 §6.1).")
    out.append("const Map<String, List<String>> dbEnumValues = {")
    for it in items:
        if it["group"] == "db":
            vals = ", ".join(f"'{v}'" for v in it["values"])
            out.append(f"  '{it['name']}': [{vals}],")
    out.append("};")
    out.append("")
    out.append("/// Реестр CHECK-перечней: поле таблицы → допустимые значения (07 §6.1.1).")
    out.append("const Map<String, List<String>> checkListValues = {")
    for it in items:
        if it["group"] == "check":
            vals = ", ".join(f"'{v}'" for v in it["values"])
            for col in it["columns"]:
                out.append(f"  '{col}': [{vals}],")
    out.append("};")
    out.append("")
    return "\n".join(out)


def write(path: Path, text: str) -> None:
    path.write_bytes(text.encode("utf-8"))


def main() -> int:
    repo = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(description="Генерация enums.ts и enums.dart из contracts/enums.json")
    ap.add_argument("out_dir", nargs="?", help="каталог вывода")
    ap.add_argument("--out", dest="out_opt", help="каталог вывода (альтернатива позиционному аргументу)")
    ap.add_argument("--input", default=str(repo / "contracts" / "enums.json"))
    a = ap.parse_args()
    out_dir = a.out_opt or a.out_dir
    if not out_dir:
        ap.error("не указан каталог вывода")
    try:
        data, digest = load(Path(a.input))
        items = build_model(data)
        version = data["version"]
        out = Path(out_dir)
        out.mkdir(parents=True, exist_ok=True)
        write(out / "enums.ts", gen_ts(items, version, digest))
        write(out / "enums.dart", gen_dart(items, version, digest))
    except InputError as e:
        print(f"gen_enums: ошибка входных данных: {e}", file=sys.stderr)
        return 1
    except (OSError, KeyError, json.JSONDecodeError) as e:
        print(f"gen_enums: ошибка: {e!r}", file=sys.stderr)
        return 2
    print(f"gen_enums: {len(items)} перечней → {out / 'enums.ts'}, {out / 'enums.dart'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
