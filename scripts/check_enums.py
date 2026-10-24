#!/usr/bin/env python3
"""RM-B-009: сверка contracts/enums.json с документами-владельцами словарей.

Что проверяется (код выхода 0 — расхождений нет, 1 — есть, 2 — ошибка запуска):
  1. enums.json валиден по contracts/enums.schema.json (JSON Schema 2020-12);
  2. dbEnums  == таблица 07_DATA_MODEL §6.1 (имена, порядок типов и значений, число типов = «Итого N типов»);
  3. checkLists == таблица 07 §6.1.1 (каждая строка с перечнем значений покрыта либо явно исключена);
  4. problemCodes == таблица 08 §2.4 (код, HTTP-статусы, порядок) и совпадает по составу со скелетом 08 §8;
  5. sync_error_code == абзац «Коды журнала синхронизации» 08 §2.4 (порядок) и строка 07 §6.1.1 (состав);
  6. apiEnums: warning_code == абзац «Предупреждения» 08 §2.4; problem_resource == 08 §2.4 и §8;
     credit_reason == 08 (все перечни `creditReason` ∈ …) и ядро R0 §23 п.5;
  7. генератор scripts/gen_enums.py детерминирован: два прогона в разные временные каталоги дают
     побайтно одинаковые enums.ts и enums.dart.

Сетевых запросов нет. Запуск: python -I -X utf8 scripts/check_enums.py [--root D:/optomstroy] [--enums FILE] [--no-gen] [-v]
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

DOC07 = "docs/specification/07_DATA_MODEL.md"
DOC08 = "docs/specification/08_API_SPECIFICATION.md"
KERNEL = "docs/research/R0_DECISION_KERNEL.md"
ENUMS = "contracts/enums.json"
SCHEMA = "contracts/enums.schema.json"
GEN = "scripts/gen_enums.py"

TICK = re.compile(r"`([^`]+)`")
NOT_USED = re.compile(r"значение `([^`]+)` не используется")


# ---------------------------------------------------------------- markdown helpers
def section(text: str, start_prefix: str, end_prefix: str) -> list[str]:
    """Строки между заголовком, начинающимся с start_prefix, и заголовком end_prefix."""
    lines = text.splitlines()
    out: list[str] | None = None
    for line in lines:
        if out is None:
            if line.startswith(start_prefix):
                out = []
            continue
        if line.startswith(end_prefix):
            return out
        out.append(line)
    raise ValueError(f"раздел не найден или не закрыт: {start_prefix!r} … {end_prefix!r}")


def split_row(line: str) -> list[str]:
    """Ячейки строки markdown-таблицы; экранированный `\\|` внутри ячейки не делит её."""
    body = line.strip()
    if body.startswith("|"):
        body = body[1:]
    if body.endswith("|") and not body.endswith("\\|"):
        body = body[:-1]
    return [c.strip() for c in re.split(r"(?<!\\)\|", body)]


def table_rows(lines: list[str]) -> list[list[str]]:
    rows = []
    for line in lines:
        s = line.strip()
        if not s.startswith("|") or re.match(r"^\|\s*:?-{3,}", s):
            continue
        rows.append(split_row(s))
    return rows[1:] if rows else rows  # без строки заголовка


def unescape(s: str) -> str:
    return s.replace("\\|", "|")


def pipe_values(token: str) -> list[str]:
    return [v.strip() for v in unescape(token).split("|") if v.strip()]


def strip_parens(s: str) -> str:
    prev = None
    while prev != s:
        prev = s
        s = re.sub(r"\([^()]*\)", "", s)
    return s


LEADING_LIST = re.compile(r"^`[^`]+`(?:\s*\([^()]*\))?(?:\s*,\s*`[^`]+`(?:\s*\([^()]*\))?)*")


def leading_values(cell: str) -> list[str] | None:
    """Перечень вида `a`, `b` (пояснение), `c` … в начале ячейки; None — если ячейка не перечень."""
    m = LEADING_LIST.match(cell.strip())
    if not m:
        return None
    return TICK.findall(strip_parens(m.group(0)))


# ---------------------------------------------------------------- parsers (07)
def parse_07_db_enums(text07: str) -> tuple[list[dict], int]:
    lines = section(text07, "### 6.1.", "#### 6.1.1.")
    declared = None
    for line in lines:
        m = re.search(r"Итого \*\*(\d+) типов\*\*", line)
        if m:
            declared = int(m.group(1))
    if declared is None:
        raise ValueError("07 §6.1: не найдено «Итого **N типов**»")
    out = []
    for cells in table_rows(lines):
        if len(cells) < 4 or not cells[0].startswith("`"):
            continue
        name = TICK.findall(cells[0])[0]
        vals_tok = TICK.findall(cells[1])
        if not vals_tok:
            raise ValueError(f"07 §6.1: у типа {name} нет значений")
        out.append({"name": name, "values": pipe_values(vals_tok[0]), "notUsed": NOT_USED.findall(cells[1])})
    return out, declared


def parse_07_check_rows(text07: str) -> list[dict]:
    lines = section(text07, "#### 6.1.1.", "### 6.2.")
    out = []
    for cells in table_rows(lines):
        if len(cells) < 4:
            continue
        cols = TICK.findall(strip_parens(cells[0]))
        if not cols:
            raise ValueError(f"07 §6.1.1: не распознано поле в строке {cells[0]!r}")
        out.append({"key": cols[0], "columns": cols, "values": leading_values(cells[1]),
                    "notUsed": NOT_USED.findall(cells[1])})
    return out


# ---------------------------------------------------------------- parsers (08, kernel)
def parse_08_problem_codes(text08: str) -> list[dict]:
    lines = section(text08, "### 2.4.", "### 2.5.")
    out = []
    for cells in table_rows(lines):
        if len(cells) < 4 or not cells[0].startswith("`"):
            continue
        code = TICK.findall(cells[0])[0]
        http = [int(x) for x in re.findall(r"\b([1-5]\d\d)\b", cells[1])]
        out.append({"code": code, "http": http})
    return out


def para_08(text08: str, marker: str) -> str:
    for line in section(text08, "### 2.4.", "### 2.5."):
        if line.startswith(marker):
            return line
    raise ValueError(f"08 §2.4: абзац {marker!r} не найден")


def parse_08_sync_codes(text08: str) -> tuple[list[str], int]:
    p = para_08(text08, "**Коды журнала синхронизации")
    m = re.search(r"Канонический перечень \((\d+) значений\):(.*?)Совпадение имён", p)
    if not m:
        raise ValueError("08 §2.4: не найден «Канонический перечень (N значений)»")
    codes = [t for t in TICK.findall(m.group(2)) if re.fullmatch(r"[A-Z][A-Z0-9_]*", t)]
    return codes, int(m.group(1))


def parse_08_warning_codes(text08: str) -> list[str]:
    p = para_08(text08, "**Предупреждения (не ошибки).**")
    pat = re.compile(r"(?:: |; )`([A-Z][A-Z0-9_]*)`(?: `\[[^\]]+\]`)?(?: \([^()]*\))? —")
    return pat.findall(p)


def parse_08_problem_resource(text08: str) -> tuple[list[str], list[str]]:
    sec = "\n".join(section(text08, "### 2.4.", "### 2.5."))
    m = re.search(r"`resource` ∈ `([^`]+)`", sec)
    if not m:
        raise ValueError("08 §2.4: перечень `resource` ∈ … не найден")
    m2 = re.search(r"resource: \{ type: string, enum: \[([^\]]+)\] \}", text08)
    if not m2:
        raise ValueError("08 §8: enum resource не найден")
    return pipe_values(m.group(1)), [v.strip() for v in m2.group(1).split(",")]


def parse_08_skeleton_codes(text08: str) -> list[str]:
    m = re.search(r"code:\s*\n\s*type: string\s*\n\s*enum: \[(.*?)\]", text08, re.S)
    if not m:
        raise ValueError("08 §8: enum Problem.code не найден")
    return [v.strip() for v in m.group(1).replace("\n", " ").split(",") if v.strip()]


def parse_credit_reason(text08: str, kernel: str) -> tuple[list[list[str]], list[str], list[str]]:
    lists08 = [pipe_values(t) for t in re.findall(r"`creditReason` ∈ `([^`]+)`", text08)]
    if not lists08:
        raise ValueError("08: перечни `creditReason` ∈ … не найдены")
    para = next((ln for ln in text08.splitlines() if ln.startswith("**`paymentChecks.creditReason`**")), None)
    m_old = para and re.search(r"Значения прежней редакции ((?:`[^`]+`(?:, )?)+) не используются", para)
    if not m_old:
        raise ValueError("08 §3.8: перечень «Значения прежней редакции … не используются» не найден")
    sec23 = "\n".join(section(kernel, "## 23.", "## 24."))
    m = re.search(r"Полный перечень `creditReason`: `([^`]+)`", sec23)
    if not m:
        raise ValueError("ядро §23 п.5: перечень creditReason не найден")
    return lists08, pipe_values(m.group(1)), TICK.findall(m_old.group(1))


# ---------------------------------------------------------------- comparison
class Report:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.ok: list[str] = []

    def eq(self, label: str, got, exp) -> None:
        if got == exp:
            self.ok.append(label)
        else:
            self.errors.append(f"{label}: enums.json={got!r} ≠ документ={exp!r}")

    def fail(self, msg: str) -> None:
        self.errors.append(msg)


def by_name(items: list[dict], key: str = "name") -> dict:
    return {i[key]: i for i in items}


def run_checks(root: Path, run_gen: bool, enums_path: Path | None = None) -> Report:
    rep = Report()
    text07 = (root / DOC07).read_text(encoding="utf-8")
    text08 = (root / DOC08).read_text(encoding="utf-8")
    kernel = (root / KERNEL).read_text(encoding="utf-8")
    enums_path = enums_path or (root / ENUMS)
    data = json.loads(enums_path.read_text(encoding="utf-8"))
    schema = json.loads((root / SCHEMA).read_text(encoding="utf-8"))

    # 1. JSON Schema
    import jsonschema

    validator = jsonschema.Draft202012Validator(schema)
    schema_errors = sorted(validator.iter_errors(data), key=lambda e: list(e.absolute_path))
    for e in schema_errors:
        rep.fail(f"schema: /{'/'.join(map(str, e.absolute_path))}: {e.message}")
    if not schema_errors:
        rep.ok.append("schema")

    all_names = [e["name"] for grp in ("dbEnums", "checkLists", "apiEnums") for e in data.get(grp, [])]
    dup = sorted({n for n in all_names if all_names.count(n) > 1})
    if dup:
        rep.fail(f"имена enum повторяются: {dup}")
    for grp in ("dbEnums", "checkLists", "apiEnums"):
        for e in data.get(grp, []):
            if len(set(e["values"])) != len(e["values"]):
                rep.fail(f"{grp}.{e['name']}: повтор значений")
            bad = sorted(set(e["values"]) & set(e.get("notUsed", [])))
            if bad:
                rep.fail(f"{grp}.{e['name']}: значения из notUsed присутствуют в values: {bad}")

    # 2. 07 §6.1
    doc_enums, declared = parse_07_db_enums(text07)
    rep.eq("07 §6.1: число типов в таблице = «Итого N типов»", len(doc_enums), declared)
    rep.eq("07 §6.1: список типов (порядок)", [e["name"] for e in data["dbEnums"]], [e["name"] for e in doc_enums])
    jmap = by_name(data["dbEnums"])
    for d in doc_enums:
        j = jmap.get(d["name"])
        if j is not None:
            rep.eq(f"07 §6.1 {d['name']}", j["values"], d["values"])
            rep.eq(f"07 §6.1 {d['name']}: неиспользуемые значения", j.get("notUsed", []), d["notUsed"])

    # 3. 07 §6.1.1
    rows = parse_07_check_rows(text07)
    excluded = {x["column"] for x in data["checkListExclusions"]}
    covered: dict[str, dict] = {}
    for c in data["checkLists"]:
        covered[c["columns"][0]] = c
    doc_keys = {r["key"] for r in rows}
    for r in rows:
        k = r["key"]
        if k in excluded:
            if k in covered:
                rep.fail(f"07 §6.1.1 {k}: одновременно в checkLists и в checkListExclusions")
            else:
                rep.ok.append(f"07 §6.1.1 {k}: исключено (не перечень значений)")
            continue
        if r["values"] is None:
            rep.fail(f"07 §6.1.1 {k}: строка без перечня значений не покрыта checkListExclusions")
            continue
        c = covered.get(k)
        if c is None:
            rep.fail(f"07 §6.1.1 {k}: перечень есть в документе, нет в enums.json")
            continue
        rep.eq(f"07 §6.1.1 {k}: поля", c["columns"], r["columns"])
        if c["name"] == "sync_error_code":
            rep.eq(f"07 §6.1.1 {k}: состав", sorted(c["values"]), sorted(r["values"]))
        else:
            rep.eq(f"07 §6.1.1 {k}", c["values"], r["values"])
        rep.eq(f"07 §6.1.1 {k}: неиспользуемые значения", c.get("notUsed", []), r["notUsed"])
    for k in sorted(set(covered) - doc_keys):
        rep.fail(f"checkLists.{covered[k]['name']}: поля {k} нет в 07 §6.1.1")
    for k in sorted(excluded - doc_keys):
        rep.fail(f"checkListExclusions: поля {k} нет в 07 §6.1.1")
    rep.eq("07 §6.1.1: порядок перечней", [c["columns"][0] for c in data["checkLists"]],
           [r["key"] for r in rows if r["key"] not in excluded and r["key"] in covered])
    # подмножество: роль приглашения ⊂ role_code
    inv = next((c for c in data["checkLists"] if c["columns"][0] == "user_invitations.role"), None)
    if inv and not set(inv["values"]) <= set(jmap.get("role_code", {"values": []})["values"]):
        rep.fail("user_invitations.role не подмножество role_code")

    # 4. 08 §2.4 Problem.code
    doc_codes = parse_08_problem_codes(text08)
    rep.eq("08 §2.4: коды (порядок)", [p["code"] for p in data["problemCodes"]], [p["code"] for p in doc_codes])
    pmap = by_name(data["problemCodes"], "code")
    for d in doc_codes:
        j = pmap.get(d["code"])
        if j is not None:
            rep.eq(f"08 §2.4 {d['code']} HTTP", j["http"], d["http"])
    rep.eq("08 §8: состав enum Problem.code", sorted(pmap), sorted(parse_08_skeleton_codes(text08)))

    # 5. коды журнала синхронизации
    sync08, n_declared = parse_08_sync_codes(text08)
    sync_json = next((c for c in data["checkLists"] if c["name"] == "sync_error_code"), None)
    if sync_json is None:
        rep.fail("checkLists.sync_error_code отсутствует")
    else:
        rep.eq("08 §2.4 коды журнала синхронизации (порядок)", sync_json["values"], sync08)
        rep.eq("08 §2.4 коды журнала: число = «(N значений)»", len(sync08), n_declared)

    # 6. API-перечни
    amap = by_name(data["apiEnums"])
    rep.eq("08 §2.4 warning_code", amap.get("warning_code", {}).get("values"), parse_08_warning_codes(text08))
    res24, res8 = parse_08_problem_resource(text08)
    rep.eq("08 §2.4 problem_resource", amap.get("problem_resource", {}).get("values"), res24)
    rep.eq("08 §8 problem_resource", amap.get("problem_resource", {}).get("values"), res8)
    lists08, kernel_cr, old_cr = parse_credit_reason(text08, kernel)
    cr = amap.get("credit_reason", {}).get("values")
    rep.eq("08 §3.8 credit_reason: значения прежней редакции", amap.get("credit_reason", {}).get("notUsed", []), old_cr)
    rep.eq("ядро §23 п.5 credit_reason", cr, kernel_cr)
    for i, lst in enumerate(lists08, 1):
        rep.eq(f"08 `creditReason` ∈ … (вхождение {i})", cr, lst)
    pc_overlap = sorted(set(amap.get("warning_code", {}).get("values", [])) & set(pmap))
    if pc_overlap != ["QR_UNAVAILABLE"]:
        rep.fail(f"ожидалось единственное пересечение WarningCode∩ProblemCode = QR_UNAVAILABLE (08 §2.4), получено {pc_overlap}")

    # 7. детерминизм генератора
    if run_gen:
        outs = []
        with tempfile.TemporaryDirectory() as t1, tempfile.TemporaryDirectory() as t2:
            for d in (t1, t2):
                r = subprocess.run([sys.executable, "-I", "-X", "utf8", str(root / GEN),
                                    "--input", str(enums_path), "--out", d],
                                   capture_output=True, text=True, encoding="utf-8")
                if r.returncode != 0:
                    rep.fail(f"gen_enums.py завершился с кодом {r.returncode}: {r.stderr.strip()}")
                    return rep
                outs.append({n: (Path(d) / n).read_bytes() for n in ("enums.ts", "enums.dart")})
        for n in ("enums.ts", "enums.dart"):
            if outs[0][n] != outs[1][n]:
                rep.fail(f"генератор недетерминирован: {n} различается между прогонами")
            else:
                rep.ok.append(f"генератор: {n} идентичен в двух прогонах ({len(outs[0][n])} байт)")
    return rep


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument("--enums", help="проверить другой файл вместо contracts/enums.json (для отрицательных тестов)")
    ap.add_argument("--no-gen", action="store_true", help="не проверять детерминизм генератора")
    ap.add_argument("-v", "--verbose", action="store_true", help="печатать и успешные проверки")
    a = ap.parse_args()
    try:
        rep = run_checks(Path(a.root), not a.no_gen, Path(a.enums) if a.enums else None)
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as e:
        print(f"ОШИБКА ЗАПУСКА: {e}", file=sys.stderr)
        return 2
    if a.verbose:
        for s in rep.ok:
            print(f"OK   {s}")
    for s in rep.errors:
        print(f"FAIL {s}")
    print(f"check_enums: проверок пройдено {len(rep.ok)}, расхождений {len(rep.errors)}")
    return 1 if rep.errors else 0


if __name__ == "__main__":
    sys.exit(main())
