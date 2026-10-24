#!/usr/bin/env python3
"""RM-B-004: проверка контракта HTTP-сервиса расширения 1С «OptomstroyPOS».

Что проверяется (код выхода 1 при любой ошибке, 0 — если ошибок нет):

1. Набор операций `/pos/v1/*` (метод + шаблон пути) в
   contracts/onec/onec-http-service.v1.yaml совпадает с таблицей методов
   05_ONEC_INTEGRATION §6.3 (разбор markdown): 0 лишних, 0 недостающих.
   Дополнительно для каждой операции проверяются:
   - query-параметры из шаблона URL 05 §6.3;
   - HTTP-коды и коды `POS_E_*` из столбца «Ответы»;
   - девять атрибутов ONEC-071 (`x-idempotency`, `x-retry`, `x-access`, `x-error-codes` и др.).
2. Каждое упоминание `/pos/v1/...` в тексте 05 §6 входит в канонический набор.
   Имена параметров пути при этом не сравниваются.
3. Перечень кодов ошибок `ErrorCode` равен кодам 05 §6.5.
   Перечень `IssueCode` равен кодам `issues[].code` из 05 §6.4.
4. Фикстуры contracts/onec/fixtures/*.json:
   - есть поле `"_note": "тестовые данные"`;
   - операция и HTTP-код есть в контракте;
   - тело проходит JSON Schema соответствующего ответа или запроса.
     Проверка строгая: поля, не описанные в схеме, запрещены.
   - каждая операция с JSON-ответом 2xx покрыта хотя бы одной фикстурой.
5. contracts/onec/odata-allowlist.yaml: каждая коллекция либо подтверждена `$metadata`,
   либо помечена "[ТИПОВО]"/"[НЕ ПОДТВЕРЖДЕНО]" с непустым `fallback`.
   Каждая OData-коллекция, упомянутая в 05 §5, входит в allow-list или в `excluded`.
6. Сверка таблицы методов 18_ONEC_API_REQUEST §4.0 с 05 §6.3. Только информационно: при
   расхождении прав 05 (ядро v1.9 §24.3).

Запуск из корня репозитория: `python -I -X utf8 scripts/check_onec_paths.py`.
Сетевых запросов нет; зависимости — PyYAML, jsonschema.
"""
from __future__ import annotations

import copy
import json
import re
import sys
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parent.parent
SPEC_05 = ROOT / "docs" / "specification" / "05_ONEC_INTEGRATION.md"
SPEC_18 = ROOT / "docs" / "specification" / "18_ONEC_API_REQUEST.md"
CONTRACT = ROOT / "contracts" / "onec" / "onec-http-service.v1.yaml"
ALLOWLIST = ROOT / "contracts" / "onec" / "odata-allowlist.yaml"
FIXTURES = ROOT / "contracts" / "onec" / "fixtures"

HTTP_METHODS = ("get", "post", "put", "patch", "delete")
REQUIRED_OP_ATTRS = (
    "operationId", "summary", "description", "tags",
    "x-onec-requirements", "x-priority", "x-idempotency", "x-retry", "x-access", "x-error-codes",
)
FIXTURE_KEYS = {"_note", "description", "operation", "kind", "status", "headers", "body"}
FIXTURE_NOTE = "тестовые данные"
STATUS_VALUES = {"[ПОДТВЕРЖДЕНО: $metadata]", "[ТИПОВО]", "[НЕ ПОДТВЕРЖДЕНО]"}
ODATA_NAME_RE = re.compile(
    r"(?<![A-Za-zА-Яа-яЁё_])((?:Catalog|Document|InformationRegister|AccumulationRegister|"
    r"ChartOfCharacteristicTypes|AccountingRegister)_[А-Яа-яЁёA-Za-z0-9_]+)"
)
POS_PATH_RE = re.compile(r"(?:\b(GET|POST|PUT|PATCH|DELETE)\s+)?(/pos/v1/[A-Za-z0-9_{}/\-]*[A-Za-z0-9_}])")

errors: list[str] = []
infos: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)
    print(f"  FAIL {msg}")


def ok(msg: str) -> None:
    print(f"  ok   {msg}")


def info(msg: str) -> None:
    infos.append(msg)
    print(f"  info {msg}")


# ----------------------------------------------------------------------------- markdown


def section(text: str, start_re: str, end_re: str) -> str:
    """Текст от заголовка start_re (включительно) до заголовка end_re (не включая)."""
    m = re.search(start_re, text, re.M)
    if not m:
        raise SystemExit(f"FATAL: заголовок {start_re!r} не найден")
    rest = text[m.start():]
    e = re.search(end_re, rest[1:], re.M)
    return rest if not e else rest[: e.start() + 1]


def split_row(line: str) -> list[str]:
    """Ячейки строки markdown-таблицы; `\\|` внутри ячейки — экранированная черта."""
    body = line.strip()
    if body.startswith("|"):
        body = body[1:]
    if body.endswith("|"):
        body = body[:-1]
    return [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", body)]


def table_after(text: str, header_re: str) -> list[list[str]]:
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.startswith("|") and re.search(header_re, line):
            rows = []
            for row in lines[i + 2:]:
                if not row.startswith("|"):
                    break
                rows.append(split_row(row))
            return rows
    raise SystemExit(f"FATAL: таблица с заголовком {header_re!r} не найдена")


def strip_query(path: str) -> tuple[str, list[str]]:
    if "?" not in path:
        return path, []
    base, query = path.split("?", 1)
    names = [p.split("=", 1)[0] for p in query.split("&") if p]
    return base, names


def normalize(path: str) -> str:
    return re.sub(r"\{[^}]*\}", "{}", path)


def methods_table(rows: list[list[str]], path_col: int, resp_col: int | None):
    """[(row_ops, statuses, codes)], row_ops = [(METHOD, path, [query names])]."""
    result = []
    for cells in rows:
        method = cells[0].strip().upper()
        spans = re.findall(r"`([^`]+)`", cells[path_col])
        ops = []
        for k, span in enumerate(spans):
            span = span.strip()
            m = re.match(r"^(GET|POST|PUT|PATCH|DELETE)\s+(/pos/v1/\S+)$", span)
            if m:
                path, q = strip_query(m.group(2))
                ops.append((m.group(1), path, q))
            elif span.startswith("/pos/v1/") and k == 0:
                path, q = strip_query(span.split()[0])
                ops.append((method, path, q))
        if not ops:
            continue
        statuses, codes = set(), set()
        if resp_col is not None:
            statuses = set(re.findall(r"(?<![\d.§])([1-5]\d\d)(?![\d])", cells[resp_col]))
            codes = set(re.findall(r"POS_E_[A-Z_]+", cells[resp_col]))
        result.append((ops, statuses, codes))
    return result


# ----------------------------------------------------------------------------- contract


def load_yaml(path: Path):
    with path.open(encoding="utf-8") as f:
        return yaml.safe_load(f)


def resolve(doc: dict, node):
    while isinstance(node, dict) and "$ref" in node:
        ref = node["$ref"]
        if not ref.startswith("#/"):
            raise SystemExit(f"FATAL: внешний $ref не поддерживается: {ref}")
        cur = doc
        for part in ref[2:].split("/"):
            cur = cur[part]
        node = cur
    return node


def contract_ops(doc: dict) -> dict[tuple[str, str], dict]:
    ops = {}
    for path, item in (doc.get("paths") or {}).items():
        for method in HTTP_METHODS:
            if method in item:
                ops[(method.upper(), path)] = item[method]
    return ops


def to_jsonschema(node, strict: bool):
    """OpenAPI 3.0 Schema Object → JSON Schema 2020-12.

    Правила: `nullable` → anyOf с null; `$ref` на components/schemas → $defs.
    `discriminator` и `x-*` отбрасываются. В строгом режиме у объектов с `properties` и без
    `additionalProperties` дополнительные поля запрещены.
    """
    if isinstance(node, list):
        return [to_jsonschema(n, strict) for n in node]
    if not isinstance(node, dict):
        return node
    if "$ref" in node:
        return {"$ref": node["$ref"].replace("#/components/schemas/", "#/$defs/")}
    out = {}
    for key, val in node.items():
        if key.startswith("x-") or key in ("discriminator", "nullable", "example", "externalDocs", "xml"):
            continue
        if key == "properties":
            out[key] = {k: to_jsonschema(v, strict) for k, v in val.items()}
        elif key in ("items", "not"):
            out[key] = to_jsonschema(val, strict)
        elif key in ("allOf", "oneOf", "anyOf"):
            out[key] = [to_jsonschema(v, strict) for v in val]
        elif key == "additionalProperties" and isinstance(val, dict):
            out[key] = to_jsonschema(val, strict)
        else:
            out[key] = copy.deepcopy(val)
    if strict and "properties" in out and "additionalProperties" not in out:
        out["additionalProperties"] = False
    if node.get("nullable") is True:
        return {"anyOf": [out, {"type": "null"}]}
    return out


def build_validator(doc: dict, schema: dict, strict: bool) -> Draft202012Validator:
    defs = {name: to_jsonschema(s, strict) for name, s in doc["components"]["schemas"].items()}
    root = to_jsonschema(schema, strict)
    if not isinstance(root, dict):
        raise SystemExit("FATAL: схема не является объектом")
    root = dict(root)
    root["$defs"] = defs
    root["$schema"] = "https://json-schema.org/draft/2020-12/schema"
    Draft202012Validator.check_schema(root)
    return Draft202012Validator(root)


# ----------------------------------------------------------------------------- checks


def check_paths(doc: dict, spec05: str) -> list:
    print("[1] Набор операций /pos/v1/* — контракт против 05 §6.3")
    s63 = section(spec05, r"^### 6\.3\. ", r"^### 6\.4\. ")
    rows05 = methods_table(table_after(s63, r"^\|\s*Метод\s*\|\s*Шаблон URL"), 1, 4)
    canon = {}
    for row_ops, _, _ in rows05:
        for method, path, q in row_ops:
            canon[(method, path)] = q
    ops = contract_ops(doc)
    pos_ops = {k: v for k, v in ops.items() if k[1].startswith("/pos/v1/")}
    other = sorted(k for k in ops if not k[1].startswith("/pos/v1/"))
    missing = sorted(set(canon) - set(pos_ops))
    extra = sorted(set(pos_ops) - set(canon))
    print(f"  05 §6.3: {len(canon)} операций; контракт: {len(pos_ops)} операций /pos/v1/*")
    for m in missing:
        err(f"нет в контракте: {m[0]} {m[1]}")
    for e in extra:
        err(f"лишняя операция в контракте: {e[0]} {e[1]}")
    for o in other:
        err(f"путь вне /pos/v1/*: {o[0]} {o[1]}")
    if not missing and not extra and not other:
        ok(f"0 лишних, 0 недостающих ({len(canon)} операций, {len({p for _, p in canon})} путей)")

    for (method, path), qnames in sorted(canon.items()):
        op = pos_ops.get((method, path))
        if not op:
            continue
        params = [resolve(doc, p) for p in op.get("parameters", [])]
        have_q = {p["name"] for p in params if p.get("in") == "query"}
        for q in qnames:
            if q not in have_q:
                err(f"{method} {path}: нет query-параметра `{q}` из шаблона 05 §6.3")
        for p in params:
            if p.get("in") == "path" and "{" + p["name"] + "}" not in path:
                err(f"{method} {path}: параметр пути `{p['name']}` отсутствует в шаблоне")
        for name in re.findall(r"\{([^}]+)\}", path):
            if not any(p.get("in") == "path" and p["name"] == name for p in params):
                err(f"{method} {path}: параметр пути `{name}` не описан")
    ok("query- и path-параметры сверены с шаблонами 05 §6.3")
    return rows05


def check_operation_attrs(doc: dict, rows05: list) -> None:
    print("[2] Атрибуты операций (ONEC-071) и ответы из столбца «Ответы» 05 §6.3")
    ops = contract_ops(doc)
    codes_enum = set(doc["components"]["schemas"]["ErrorCode"]["enum"])
    has_global_security = bool(doc.get("security"))
    op_ids = set()
    for (method, path), op in sorted(ops.items()):
        for attr in REQUIRED_OP_ATTRS:
            if not op.get(attr):
                err(f"{method} {path}: нет атрибута `{attr}`")
        oid = op.get("operationId")
        if oid in op_ids:
            err(f"{method} {path}: повтор operationId `{oid}`")
        op_ids.add(oid)
        if not (has_global_security or op.get("security")):
            err(f"{method} {path}: не задана схема безопасности")
        resp = op.get("responses", {})
        if not any(str(c).startswith("2") for c in resp):
            err(f"{method} {path}: нет ответа 2xx")
        if "401" not in resp:
            err(f"{method} {path}: нет ответа 401 (ONEC-032)")
        for c in op.get("x-error-codes") or []:
            if c not in codes_enum:
                err(f"{method} {path}: код `{c}` из x-error-codes отсутствует в ErrorCode")
    for row_ops, statuses, codes in rows05:
        keys = [(m, p) for m, p, _ in row_ops if (m, p) in ops]
        if not keys:
            continue
        have_status = set().union(*[set(map(str, ops[k].get("responses", {}))) for k in keys])
        have_codes = set().union(*[set(ops[k].get("x-error-codes") or []) for k in keys])
        label = ", ".join(f"{m} {p}" for m, p in keys)
        for s in sorted(statuses - have_status):
            err(f"{label}: нет HTTP {s} из 05 §6.3")
        for c in sorted(codes - have_codes):
            err(f"{label}: нет кода {c} из 05 §6.3 в x-error-codes")
    ok(f"проверено {len(ops)} операций: атрибуты ONEC-071, 2xx/401, HTTP-коды и POS_E_* из 05 §6.3")


def check_mentions(spec05: str, rows05: list) -> None:
    print("[3] Упоминания /pos/v1/* в тексте 05 §6 входят в канонический набор")
    s6 = section(spec05, r"^## 6\. ", r"^## 7\. ")
    canon = {(m, normalize(p)) for row_ops, _, _ in rows05 for m, p, _ in row_ops}
    canon_paths = {p for _, p in canon}
    count = 0
    for m in POS_PATH_RE.finditer(s6):
        count += 1
        method, path = m.group(1), normalize(m.group(2))
        if path not in canon_paths:
            err(f"05 §6 упоминает путь вне таблицы §6.3: {m.group(0)}")
        elif method and (method, path) not in canon:
            err(f"05 §6 упоминает метод вне таблицы §6.3: {m.group(0)}")
    ok(f"{count} упоминаний /pos/v1/* в 05 §6 сверены (имена параметров пути нормализованы)")


def check_dictionaries(doc: dict, spec05: str) -> None:
    print("[4] Словари кодов: ErrorCode = 05 §6.5, IssueCode = 05 §6.4")
    s65 = section(spec05, r"^### 6\.5\. ", r"^### 6\.6\. ")
    codes05 = set()
    for cells in table_after(s65, r"^\|\s*HTTP\s*\|\s*`code`"):
        codes05 |= set(re.findall(r"POS_E_[A-Z_]+", cells[1]))
    enum = set(doc["components"]["schemas"]["ErrorCode"]["enum"])
    if codes05 != enum:
        err(f"ErrorCode расходится с 05 §6.5: нет {sorted(codes05 - enum)}, лишние {sorted(enum - codes05)}")
    else:
        ok(f"ErrorCode = 05 §6.5 ({len(enum)} кодов)")
    s64 = section(spec05, r"^### 6\.4\. ", r"^### 6\.5\. ")
    line = next((ln for ln in s64.splitlines() if ln.startswith("Коды `issues[].code`")), None)
    if line is None:
        err("в 05 §6.4 не найдена строка «Коды `issues[].code`»")
        return
    issues05 = {c for c in re.findall(r"`([A-Z][A-Z_]+)`", line)}
    issue_enum = set(doc["components"]["schemas"]["IssueCode"]["enum"])
    if issues05 != issue_enum:
        err(f"IssueCode расходится с 05 §6.4: нет {sorted(issues05 - issue_enum)}, лишние {sorted(issue_enum - issues05)}")
    else:
        ok(f"IssueCode = 05 §6.4 ({len(issue_enum)} кодов)")


def response_schema(doc: dict, op: dict, status: str):
    resp = op.get("responses", {}).get(status)
    if resp is None:
        return None, None
    resp = resolve(doc, resp)
    content = resp.get("content") or {}
    js = content.get("application/json")
    return resp, (js or {}).get("schema")


def check_fixtures(doc: dict) -> None:
    print("[5] Фикстуры contracts/onec/fixtures/*.json по схемам контракта (строгий режим)")
    ops = contract_ops(doc)
    files = sorted(FIXTURES.rglob("*.json"))
    if not files:
        err("фикстуры не найдены")
        return
    covered: set[tuple[str, str]] = set()
    cache: dict[int, Draft202012Validator] = {}
    for f in files:
        rel = f.relative_to(ROOT).as_posix()
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
        except (ValueError, UnicodeDecodeError) as e:
            err(f"{rel}: не JSON ({e})")
            continue
        if not isinstance(data, dict):
            err(f"{rel}: корень фикстуры — не объект")
            continue
        if data.get("_note") != FIXTURE_NOTE:
            err(f"{rel}: нет поля \"_note\": \"{FIXTURE_NOTE}\"")
        unknown = set(data) - FIXTURE_KEYS
        if unknown:
            err(f"{rel}: неизвестные ключи конверта {sorted(unknown)}")
        m = re.match(r"^(GET|POST|PUT|PATCH|DELETE) (\S+)$", str(data.get("operation", "")))
        if not m or (m.group(1), m.group(2)) not in ops:
            err(f"{rel}: операция `{data.get('operation')}` не найдена в контракте")
            continue
        key = (m.group(1), m.group(2))
        op = ops[key]
        kind = data.get("kind")
        if kind == "request":
            rb = resolve(doc, op.get("requestBody") or {})
            schema = ((rb.get("content") or {}).get("application/json") or {}).get("schema")
            if schema is None:
                err(f"{rel}: у операции нет JSON-тела запроса")
                continue
        elif kind == "response":
            status = str(data.get("status"))
            token = re.search(r"\.(\d{3})(?:\.|$)", f.stem)
            if token and token.group(1) != status:
                err(f"{rel}: код в имени файла {token.group(1)} не равен status {status}")
            resp, schema = response_schema(doc, op, status)
            if resp is None:
                err(f"{rel}: у операции нет ответа {status}")
                continue
            if schema is None:
                if data.get("body") is not None:
                    err(f"{rel}: ответ {status} не имеет JSON-тела, а body задан")
                continue
            for hname, hval in (data.get("headers") or {}).items():
                hdef = (resp.get("headers") or {}).get(hname)
                if hdef is None:
                    err(f"{rel}: заголовок {hname} не описан в ответе {status}")
                    continue
                hschema = resolve(doc, hdef).get("schema", {})
                for e in build_validator(doc, hschema, True).iter_errors(hval):
                    err(f"{rel}: заголовок {hname}: {e.message}")
            if status.startswith("2"):
                covered.add(key)
        else:
            err(f"{rel}: kind должен быть request или response")
            continue
        vid = id(schema)
        if vid not in cache:
            cache[vid] = build_validator(doc, schema, True)
        problems = sorted(cache[vid].iter_errors(data.get("body")), key=lambda e: list(e.absolute_path))
        for e in problems[:5]:
            where = "/".join(str(p) for p in e.absolute_path) or "(корень)"
            err(f"{rel}: body/{where}: {e.message[:200]}")
        if len(problems) > 5:
            err(f"{rel}: ещё {len(problems) - 5} нарушений")
    need = set()
    for key, op in ops.items():
        for status, resp in op.get("responses", {}).items():
            if str(status).startswith("2") and (resolve(doc, resp).get("content") or {}).get("application/json"):
                need.add(key)
    for key in sorted(need - covered):
        err(f"нет фикстуры успешного ответа для {key[0]} {key[1]}")
    ok(f"{len(files)} файлов проверено; операций с JSON-ответом 2xx: {len(need)}, покрыто: {len(need & covered)}")


def check_allowlist(spec05: str) -> None:
    print("[6] OData allow-list (ONEC-083; RM-B-004 п. 3)")
    data = load_yaml(ALLOWLIST)
    cols = data.get("collections") or []
    if not cols:
        err("allow-list пуст")
        return
    if set(data.get("statusValues") or []) != STATUS_VALUES:
        err(f"statusValues должны быть {sorted(STATUS_VALUES)}")
    names = set()
    confirmed = typical = 0
    for c in cols:
        name = c.get("name", "")
        if not ODATA_NAME_RE.fullmatch(name):
            err(f"коллекция `{name}`: имя не в нотации OData 1С")
        if name in names:
            err(f"коллекция `{name}`: повтор")
        names.add(name)
        status = c.get("status")
        if status not in STATUS_VALUES:
            err(f"{name}: status `{status}` вне {sorted(STATUS_VALUES)}")
        elif status == "[ПОДТВЕРЖДЕНО: $metadata]":
            confirmed += 1
            if not c.get("confirmedBy"):
                err(f"{name}: подтверждено, но confirmedBy пуст")
        else:
            typical += 1
            if c.get("confirmedBy"):
                err(f"{name}: confirmedBy заполнен при status {status}")
            if not str(c.get("fallback") or "").strip():
                err(f"{name}: status {status} без fallback")
        if c.get("access") != "read":
            err(f"{name}: access должен быть read (ONEC-052)")
        fields = c.get("fields") or []
        if not fields or len(fields) != len(set(fields)):
            err(f"{name}: fields пуст или с повторами")
        if not set(c.get("unconfirmedFields") or []) <= set(fields):
            err(f"{name}: unconfirmedFields не входят в fields")
        reqs = c.get("requirements") or []
        if not reqs or not all(re.fullmatch(r"ONEC-\d{3}", r) for r in reqs):
            err(f"{name}: requirements должны быть ONEC-NNN")
        if not set(c.get("operations") or []) <= {"list", "balance", "sliceLast"} or not c.get("operations"):
            err(f"{name}: operations вне list|balance|sliceLast")
    excluded = {e.get("name") for e in data.get("excluded") or []}
    for e in data.get("excluded") or []:
        if not str(e.get("reason") or "").strip():
            err(f"excluded `{e.get('name')}` без reason")
    s5 = section(spec05, r"^## 5\. ", r"^## 6\. ")
    mentioned = set(ODATA_NAME_RE.findall(s5))
    for n in sorted(mentioned - names - excluded):
        err(f"05 §5 упоминает OData-коллекцию `{n}`, её нет ни в collections, ни в excluded")
    for n in sorted(names - mentioned):
        info(f"коллекция `{n}` не названа в 05 §5 в нотации OData (выведена из имени объекта 1С)")
    ok(f"{len(cols)} коллекций: подтверждено $metadata — {confirmed}, [ТИПОВО]/[НЕ ПОДТВЕРЖДЕНО] с fallback — {typical}; "
       f"упомянутые в 05 §5: {len(mentioned)}, все покрыты")


def check_doc18(rows05: list) -> None:
    print("[7] Сверка 18 §4.0 с 05 §6.3 (информационно; при расхождении прав 05)")
    spec18 = SPEC_18.read_text(encoding="utf-8")
    s40 = section(spec18, r"^### 4\.0\. ", r"^### 4\.1\. ")
    rows18 = methods_table(table_after(s40, r"^\|\s*Метод\s*\|\s*Путь"), 1, 4)
    set18 = {(m, p) for row_ops, _, _ in rows18 for m, p, _ in row_ops}
    set05 = {(m, p) for row_ops, _, _ in rows05 for m, p, _ in row_ops}
    if set18 == set05:
        ok(f"набор операций 18 §4.0 совпадает с 05 §6.3 ({len(set18)})")
    for k in sorted(set05 - set18):
        info(f"есть в 05 §6.3, нет в 18 §4.0: {k[0]} {k[1]}")
    for k in sorted(set18 - set05):
        info(f"есть в 18 §4.0, нет в 05 §6.3: {k[0]} {k[1]}")


def main() -> int:
    for p in (SPEC_05, SPEC_18, CONTRACT, ALLOWLIST):
        if not p.exists():
            print(f"FATAL: нет файла {p}")
            return 2
    spec05 = SPEC_05.read_text(encoding="utf-8")
    doc = load_yaml(CONTRACT)
    if not str(doc.get("openapi", "")).startswith("3.0."):
        err(f"openapi должен быть 3.0.x, а не {doc.get('openapi')}")
    rows05 = check_paths(doc, spec05)
    check_operation_attrs(doc, rows05)
    check_mentions(spec05, rows05)
    check_dictionaries(doc, spec05)
    check_fixtures(doc)
    check_allowlist(spec05)
    check_doc18(rows05)
    print()
    if errors:
        print(f"ИТОГ: FAIL — ошибок: {len(errors)}, информационных замечаний: {len(infos)}")
        return 1
    print(f"ИТОГ: OK — ошибок: 0, информационных замечаний: {len(infos)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
