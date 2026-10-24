#!/usr/bin/env python3
"""check_enum_triangle.py — треугольник «contracts/enums.json ↔ DDL ↔ OpenAPI» (B-AR-10 (г)).

Владелец значений — 07 §6.1/§6.1.1 (enum-ы и CHECK-перечни) и 08 §2.4 (коды ошибок); contracts/enums.json — их
машиночитаемая проекция (сверку с документами делает scripts/check_enums.py). Этот скрипт проверяет, что три
производных артефакта не разошлись между собой:

  [1] 45 enum-типов enums.json.dbEnums  = CREATE TYPE … AS ENUM в pos-api/migrations/0001_init.sql
      (состав, имена, порядок значений);
  [2] те же типы = enum-схемы OpenAPI (PascalCase-имя, значения и порядок; `null` у nullable-enum игнорируется);
      типы, которые API не выставляет, перечислены в INTERNAL_TYPES с причиной — прочие отсутствия = ошибка;
  [3] CHECK-перечни enums.json.checkLists = CHECK (<col> IN (…)) DDL соответствующих столбцов (состав; порядок
      в CHECK не значим и выводится информационно); CHECK, переопределённый последующей миграцией
      (`ALTER TABLE … ADD CONSTRAINT … CHECK (<col> IN (…))`, например 0003), берётся из последней (ADR-088);
      столбцы, которых нет в DDL как обычных столбцов (ключи app_settings и т. п.), — информационно;
  [4] enums.json.problemCodes = ProblemCode OpenAPI (состав и порядок, 08 §2.4).

Запуск: python -I -X utf8 scripts/check_enum_triangle.py [-v]. Без сети. Код выхода: 0 — расхождений нет;
1 — есть расхождения; 2 — ошибка входных файлов.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENUMS = ROOT / "contracts" / "enums.json"
DDL = ROOT / "pos-api" / "migrations" / "0001_init.sql"
OPENAPI = ROOT / "contracts" / "openapi" / "pos-api.v1.yaml"
LATER_DDL: list[str] = []  # тексты миграций после 0001 (заполняет main)

# Типы БД, которые API намеренно не выставляет (внутренние состояния сервера; review B §2.5).
INTERNAL_TYPES = {
    "otp_status": "статус OTP-вызова — внутреннее состояние auth (08 отдаёт только коды ошибок OTP_*)",
    "attribute_value_type": "тип значения атрибута 1С — служебное поле реплики каталога",
    "image_status": "очередь загрузки фото — служебное поле product_images",
    "idempotency_status": "состояние ключа идемпотентности — только сервер (08 §2.7)",
    "audit_level": "уровень записи аудита app/db — внутреннее поле audit_logs",
    "print_job_status": "очередь печати — внутреннее поле print_jobs (опциональная таблица)",
    "sms_status": "статус SMS-отправки — внутреннее поле sms_outbox",
}


def pascal(name: str) -> str:
    return "".join(p[:1].upper() + p[1:] for p in name.split("_"))


def main() -> int:
    verbose = "-v" in sys.argv[1:]
    try:
        import yaml  # type: ignore
    except ImportError:
        print("ERROR: нужен pyyaml", file=sys.stderr)
        return 2
    for p in (ENUMS, DDL, OPENAPI):
        if not p.is_file():
            print(f"ERROR: нет файла {p}", file=sys.stderr)
            return 2
    enums = json.loads(ENUMS.read_text(encoding="utf-8"))
    ddl = DDL.read_text(encoding="utf-8")
    global LATER_DDL
    LATER_DDL = [p.read_text(encoding="utf-8") for p in sorted(DDL.parent.glob("[0-9][0-9][0-9][0-9]_*.sql"))
                 if p.name > DDL.name]
    api = yaml.safe_load(OPENAPI.read_text(encoding="utf-8"))
    schemas = api["components"]["schemas"]

    errors: list[str] = []
    infos: list[str] = []

    def ok(msg: str) -> None:
        if verbose:
            print(f"ok   {msg}")

    # [1] enums.json ↔ CREATE TYPE
    print("[1] enums.json.dbEnums ↔ CREATE TYPE … AS ENUM (0001_init.sql)")
    ddl_types: dict[str, list[str]] = {}
    for m in re.finditer(r"CREATE TYPE\s+(\w+)\s+AS ENUM\s*\(([^)]*)\)", ddl):
        ddl_types[m.group(1)] = re.findall(r"'((?:[^']|'')*)'", m.group(2))
    json_types = {e["name"]: e["values"] for e in enums["dbEnums"]}
    if list(json_types) != list(ddl_types):
        miss = [t for t in json_types if t not in ddl_types]
        extra = [t for t in ddl_types if t not in json_types]
        if miss or extra:
            errors.append(f"[1] состав типов: нет в DDL {miss}, лишние в DDL {extra}")
        else:
            errors.append("[1] порядок объявления типов в DDL отличается от enums.json")
    for t, vals in json_types.items():
        if t in ddl_types and ddl_types[t] != vals:
            errors.append(f"[1] {t}: enums.json {vals} ≠ DDL {ddl_types[t]}")
        elif t in ddl_types:
            ok(f"{t}: {len(vals)} значений")
    print(f"  типов: enums.json {len(json_types)}, DDL {len(ddl_types)}")

    # [2] enums.json ↔ OpenAPI
    print("[2] enums.json.dbEnums ↔ enum-схемы OpenAPI (PascalCase)")
    exposed = 0
    for t, vals in json_types.items():
        name = pascal(t)
        sch = schemas.get(name)
        if sch is None:
            if t in INTERNAL_TYPES:
                infos.append(f"[2] {t}: в API не выставляется — {INTERNAL_TYPES[t]}")
            else:
                errors.append(f"[2] {t}: нет схемы {name} в OpenAPI и тип не помечен внутренним")
            continue
        if t in INTERNAL_TYPES:
            errors.append(f"[2] {t}: помечен внутренним, но схема {name} есть в OpenAPI — обновите INTERNAL_TYPES")
        api_vals = [v for v in (sch.get("enum") or []) if v is not None]
        if api_vals != vals:
            errors.append(f"[2] {name}: OpenAPI {api_vals} ≠ enums.json {vals}")
        else:
            exposed += 1
            ok(f"{name} = {t}")
    print(f"  выставлено в API: {exposed}; внутренних: {len(INTERNAL_TYPES)}")

    # [3] checkLists ↔ DDL CHECK
    print("[3] enums.json.checkLists ↔ CHECK (… IN (…)) DDL")
    tables: dict[str, str] = {}
    for m in re.finditer(r"CREATE TABLE IF NOT EXISTS (\w+) \((.*?)\n\s*\);", ddl, re.S):
        tables[m.group(1)] = m.group(2)
    checked = 0
    for cl in enums["checkLists"]:
        for col in cl["columns"]:
            if "." not in col:
                infos.append(f"[3] {cl['name']}: «{col}» — не столбец таблицы")
                continue
            t, c = col.split(".", 1)
            body = tables.get(t)
            if body is None or not re.search(rf"^\s+{re.escape(c)}\s", body, re.M):
                infos.append(f"[3] {cl['name']}: {col} — не обычный столбец DDL (ключ/поле JSON), сверка значений не выполняется")
                continue
            found = None
            for m in re.finditer(rf"\b{re.escape(c)}\s+IN\s*\(([^)]*)\)", body):
                found = re.findall(r"'((?:[^']|'')*)'", m.group(1))
                break
            # Последующие expand-миграции (0003…) переопределяют CHECK через ADD CONSTRAINT … CHECK (<col> IN (…));
            # действует последнее определение в порядке имён файлов (как применяет мигратор, 07 §12; ADR-088).
            for later in LATER_DDL:
                for m in re.finditer(
                        rf"ALTER TABLE\s+(?:public\.)?{re.escape(t)}\s+ADD CONSTRAINT\s+\w+\s+CHECK\s*\(\s*"
                        rf"{re.escape(c)}\s+IN\s*\(([^)]*)\)", later, re.S):
                    found = re.findall(r"'((?:[^']|'')*)'", m.group(1))
            if found is None:
                infos.append(f"[3] {cl['name']}: {col} — CHECK … IN (…) в DDL не найден (перечень проверяет сервис)")
                continue
            checked += 1
            if set(found) != set(cl["values"]) or len(found) != len(cl["values"]):
                errors.append(f"[3] {col}: enums.json {cl['values']} ≠ DDL {found}")
            elif found != cl["values"]:
                infos.append(f"[3] {col}: состав совпадает, порядок в CHECK другой (для CHECK порядок не значим)")
            else:
                ok(f"{col}: {len(found)} значений")
    print(f"  сверено столбцов с CHECK: {checked}")

    # [4] problemCodes ↔ ProblemCode
    print("[4] enums.json.problemCodes ↔ ProblemCode (OpenAPI)")
    pj = [p["code"] for p in enums["problemCodes"]]
    pa = schemas.get("ProblemCode", {}).get("enum") or []
    if pj != pa:
        errors.append(f"[4] ProblemCode: только в enums.json {sorted(set(pj) - set(pa))}, только в OpenAPI "
                      f"{sorted(set(pa) - set(pj))}{'; порядок различается' if set(pj) == set(pa) else ''}")
    print(f"  кодов: enums.json {len(pj)}, OpenAPI {len(pa)}")

    for i in infos:
        print(f"info {i}")
    for e in errors:
        print(f"FAIL {e}")
    print(f"ИТОГ: {'OK' if not errors else 'РАСХОЖДЕНИЯ'} — ошибок {len(errors)}, информационных {len(infos)}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
