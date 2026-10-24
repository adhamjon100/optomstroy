#!/usr/bin/env python3
"""RM-B-003 (критерий 2): сверка путей и методов contracts/openapi/pos-api.v1.yaml с ТЗ.

Источники обязательных операций (извлекаются из документов, не из списка в скрипте):
  K7    — ядро R0 §7: канонические пути (без методов — путь должен существовать с любым методом);
  K17   — ядро §17.4: методы канонических путей, новые пути, входящий обмен 1С C-2;
  K19   — ядро §19.2: таблица «API (08 — владелец; добавить/изменить в R1)»;
  K22   — ядро §22–§24: операции «МЕТОД /путь» (методы расширения 1С /pos/v1/* — не pos-api, пропускаются);
  C08   — заголовки карточек 08 §4.x.y («#### 4.x.y. `МЕТОД /путь` …»).
Альтернативы раскрываются: `/a/{x|y}.pdf`, `/a/b|c`, `GET/POST /a`. Параметры пути сравниваются
нормализованно (`{...}` → `{}`); для карточек 08 (владелец имён) дополнительно сверяются имена параметров.
Query-часть (`GET /orders?include=`) превращается в проверку: у операции есть query-параметр с этим именем.

Запрещено в контракте R1 (ошибка, если есть):
  * неканонические и R2-варианты 13 RM-B-003 / ядро §17.4, §19.2: DELETE /admin/users/{id}/sessions,
    /integrations/onec/heartbeat (любой метод), POST /registration/customer-match, PATCH /customers/{id}/contacts,
    POST /registration/face-scan/verify (только R2);
  * операции абзацев 08 §4.20 «Не в R1 (R2) по ядру §19.2» и «Эндпоинты R5 §5.2, не вошедшие в ядро §7».
Лишние операции (нет ни в ядре, ни в карточках 08) — ошибка. Дополнительно: лимит страницы — максимум 200
(ядро §19.2), сортировки `available:desc` и `sku:asc` у /catalog/products и /search/products.

Сетевых запросов нет. Код выхода: 0 — расхождений нет, 1 — есть расхождения, 2 — ошибка запуска.
  python -I -X utf8 scripts/check_api_paths.py [--root D:/optomstroy] [--openapi FILE] [-v]
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    print("ERROR: нужен пакет pyyaml", file=sys.stderr)
    sys.exit(2)

KERNEL = "docs/research/R0_DECISION_KERNEL.md"
DOC08 = "docs/specification/08_API_SPECIFICATION.md"
OPENAPI = "contracts/openapi/pos-api.v1.yaml"
METHODS = ("get", "put", "post", "delete", "options", "head", "patch", "trace")
METHOD_RE = r"(?:GET|POST|PUT|PATCH|DELETE)(?:/(?:GET|POST|PUT|PATCH|DELETE))*"
OP_TOKEN = re.compile(rf"^({METHOD_RE})\s+(/\S*)$")
TICK = re.compile(r"`([^`]+)`")

# 13 RM-B-003 критерий 2 и ядро §17.4 / §19.2 / 08 §4.2.3: неканонические и R2-варианты.
# Метод None — запрещён путь целиком (любой метод).
FORBIDDEN = [
    ("DELETE", "/admin/users/{id}/sessions", "13 RM-B-003, ядро §17.4: канон — POST /admin/users/{id}/logout-all"),
    (None, "/integrations/onec/heartbeat", "13 RM-B-003, ядро §17.4: канон — GET /integrations/onec/ping"),
    ("POST", "/registration/customer-match", "13 RM-B-003, ядро §17.4: только GET"),
    ("PATCH", "/customers/{id}/contacts", "13 RM-B-003, ядро §19.2: R2"),
    ("POST", "/registration/face-scan/verify", "13 RM-B-003, ядро §17.4, 08 §4.2.3: только R2"),
]


def norm(path: str) -> str:
    return re.sub(r"\{[^}]*\}", "{}", path)


def expand_path(path: str) -> list[str]:
    """Раскрывает альтернативы: {a|b} внутри сегмента и a|b в последнем сегменте."""
    m = re.search(r"\{([^{}]*\|[^{}]*)\}", path)
    if m:
        out: list[str] = []
        for alt in m.group(1).split("|"):
            out.extend(expand_path(path[:m.start()] + alt.strip() + path[m.end():]))
        return out
    head, _, last = path.rpartition("/")
    if "|" in last:
        return [f"{head}/{alt}" for alt in last.split("|")]
    return [path]


class Req:
    def __init__(self, method: str | None, path: str, source: str, query: list[str], exact: bool) -> None:
        self.method, self.path, self.source, self.query, self.exact = method, path, source, query, exact

    def key(self) -> tuple[str | None, str]:
        return (self.method, norm(self.path))


def parse_token(token: str, source: str, exact: bool = False, require_method: bool = True) -> list[Req]:
    token = token.strip().replace("\\|", "|")
    m = OP_TOKEN.match(token)
    if m:
        methods = m.group(1).split("/")
        raw = m.group(2)
    elif not require_method and token.startswith("/"):
        methods = [None]
        raw = token
    else:
        return []
    path, _, query = raw.partition("?")
    path = path.rstrip(".,;:")
    qnames = [q.split("=")[0] for q in query.split("&") if q.split("=")[0]] if query else []
    out = []
    for meth in methods:
        for p in expand_path(path):
            out.append(Req(meth, p, source, qnames, exact))
    return out


def section(lines: list[str], start_re: str, stop_re: str) -> list[str]:
    out: list[str] = []
    on = False
    for ln in lines:
        if re.match(start_re, ln):
            on = True
            continue
        if on and re.match(stop_re, ln):
            break
        if on:
            out.append(ln)
    if not out:
        raise ValueError(f"раздел не найден: {start_re}")
    return out


def is_onec_extension(token: str) -> bool:
    return "/pos/v1/" in token or token.startswith("/pos/v1")


def collect_kernel(text: str, rep: list[str]) -> list[Req]:
    lines = text.splitlines()
    reqs: list[Req] = []
    # §7: только список путей (абзац, начинающийся с `/auth/otp/request`).
    s7 = section(lines, r"^## 7\. ", r"^## 8\. ")
    plist = [ln for ln in s7 if ln.startswith("`/auth/otp/request`")]
    if len(plist) != 1:
        raise ValueError("ядро §7: не найден абзац со списком путей")
    for tok in TICK.findall(plist[0]):
        reqs += parse_token(tok, "ядро §7", require_method=False)
    # §17.4, §19.2: операции «МЕТОД /путь».
    for name, start, stop in (("ядро §17.4", r"^### 17\.4\. ", r"^### 17\.5\. "),
                              ("ядро §19.2", r"^### 19\.2\. ", r"^### 19\.3\. ")):
        for ln in section(lines, start, stop):
            for tok in TICK.findall(ln):
                if not is_onec_extension(tok):
                    reqs += parse_token(tok, name)
    # §22–§24: операции «МЕТОД /путь», кроме методов расширения 1С /pos/v1/*.
    for ln in section(lines, r"^## 22\. ", r"^## Журнал "):
        for tok in TICK.findall(ln):
            if not is_onec_extension(tok):
                reqs += parse_token(tok, "ядро §22–§24")
    rep.append(f"ядро: извлечено {len(reqs)} упоминаний операций/путей")
    return reqs


def collect_08(text: str, rep: list[str]) -> tuple[list[Req], list[Req]]:
    lines = text.splitlines()
    reqs: list[Req] = []
    cards = 0
    for ln in lines:
        m = re.match(r"^#### (4\.\d+\.\d+)\. (.*)$", ln)
        if not m:
            continue
        cards += 1
        for tok in TICK.findall(m.group(2)):
            reqs += parse_token(tok, f"08 §{m.group(1)}", exact=True)
    # Абзацы 08 §4.20 «Не в R1 (R2)» и «Эндпоинты R5 §5.2, не вошедшие» — запрещённые в контракте R1.
    banned: list[Req] = []
    s420 = section(lines, r"^### 4\.20\. ", r"^### 4\.21\. ")
    for ln in s420:
        if ln.startswith("**Не в R1 (R2)") or ln.startswith("Эндпоинты R5 §5.2"):
            src = "08 §4.20 «Не в R1 (R2)»" if ln.startswith("**Не") else "08 §4.20 «R5 §5.2, не вошедшие»"
            for tok in TICK.findall(ln):
                banned += parse_token(tok, src)
    rep.append(f"08: карточек §4.x.y — {cards}, операций в заголовках — {len(reqs)}; "
               f"исключённых операций в §4.20 — {len(banned)}")
    if cards < 100:
        raise ValueError(f"08: найдено только {cards} карточек §4.x.y — формат документа изменился?")
    return reqs, banned


def load_contract(path: Path) -> tuple[dict, dict[tuple[str, str], tuple[str, dict]]]:
    with path.open(encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    ops: dict[tuple[str, str], tuple[str, dict]] = {}
    for p, item in (doc.get("paths") or {}).items():
        for m in METHODS:
            if m in item:
                key = (m.upper(), norm(p))
                if key in ops:
                    raise ValueError(f"в контракте два пути с одной нормализованной формой: {ops[key][0]} и {p}")
                ops[key] = (p, item[m])
    return doc, ops


def deref(doc: dict, node):
    seen = 0
    while isinstance(node, dict) and "$ref" in node and seen < 20:
        cur = doc
        for tok in node["$ref"][2:].split("/"):
            cur = cur[tok]
        node, seen = cur, seen + 1
    return node


def query_params(doc: dict, path_item: dict, op: dict) -> dict[str, dict]:
    out = {}
    for prm in list(path_item.get("parameters") or []) + list(op.get("parameters") or []):
        prm = deref(doc, prm)
        if isinstance(prm, dict) and prm.get("in") == "query":
            out[prm["name"]] = prm
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument("--openapi", default=None)
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    root = Path(args.root)
    info: list[str] = []
    errors: list[str] = []
    try:
        kreqs = collect_kernel((root / KERNEL).read_text(encoding="utf-8"), info)
        creqs, banned = collect_08((root / DOC08).read_text(encoding="utf-8"), info)
        oa_path = Path(args.openapi) if args.openapi else root / OPENAPI
        doc, ops = load_contract(oa_path)
    except (OSError, ValueError, KeyError, yaml.YAMLError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    info.append(f"контракт {oa_path.name}: операций {len(ops)}, путей {len(doc.get('paths') or {})}")

    forbidden = [(m, norm(p), why) for m, p, why in FORBIDDEN]
    forbidden += [(r.method, norm(r.path), r.source) for r in banned]

    def is_forbidden(method: str | None, npath: str) -> str | None:
        for fm, fp, why in forbidden:
            # Путь ядра §7 без метода (method=None) исключается, только если запрещён путь целиком.
            if fp == npath and (fm is None or fm == method):
                return why
        return None

    # Санити: запрещённые варианты 13 RM-B-003 действительно упомянуты в документах (парсер жив).
    mentioned = {r.key() for r in kreqs + creqs}
    for fm, fp, _ in forbidden[:len(FORBIDDEN)]:
        if fm and (fm, fp) not in mentioned and fp != norm("/admin/users/{id}/sessions"):
            info.append(f"примечание: {fm} {fp} не найден в ядре/08 как «МЕТОД /путь» (проверяется по списку 13)")

    required: dict[tuple[str | None, str], list[Req]] = {}
    skipped: list[str] = []
    for r in kreqs + creqs:
        why = is_forbidden(r.method, norm(r.path))
        if why:
            skipped.append(f"{r.method or '*'} {r.path} ({r.source}) — исключено: {why}")
            continue
        required.setdefault(r.key(), []).append(r)

    by_path: dict[str, list[str]] = {}
    for (m, np) in ops:
        by_path.setdefault(np, []).append(m)

    covered: set[tuple[str, str]] = set()
    checked = 0
    for (method, npath), rs in sorted(required.items(), key=lambda kv: (kv[0][1], kv[0][0] or "")):
        srcs = ", ".join(sorted({r.source for r in rs}))
        if method is None:
            checked += 1
            if npath not in by_path:
                errors.append(f"нет пути {rs[0].path} (любой метод) — {srcs}")
            continue
        checked += 1
        if (method, npath) not in ops:
            errors.append(f"нет операции {method} {rs[0].path} — {srcs}")
            continue
        covered.add((method, npath))
        real_path, op = ops[(method, npath)]
        for r in rs:
            if r.exact and r.path != real_path:
                errors.append(f"{method} {real_path}: имена параметров пути расходятся с 08 ({r.source}: {r.path})")
            if r.query:
                qp = query_params(doc, doc["paths"][real_path], op)
                for q in r.query:
                    if q not in qp:
                        errors.append(f"{method} {real_path}: нет query-параметра {q!r} ({r.source})")
    # Пути без метода (ядро §7) покрывают все методы пути, если метод нигде не указан явно.
    bare = {np for (m, np) in required if m is None}

    for (m, np), (real_path, _) in sorted(ops.items(), key=lambda kv: (kv[0][1], kv[0][0])):
        why = is_forbidden(m, np)
        if why:
            errors.append(f"в контракте есть запрещённая операция {m} {real_path} — {why}")
        elif (m, np) not in covered:
            if np in bare and not any(k[1] == np and k[0] for k in required):
                info.append(f"{m} {real_path}: покрыт только путём ядра §7 без метода")
            else:
                errors.append(f"лишняя операция {m} {real_path}: нет ни в ядре (§7, §17.4, §19.2, §22–§24), "
                              f"ни в карточках 08 §4")

    # Значения ядра §19.2: лимит страницы ≤ 200; сортировки каталога.
    limit = (doc.get("components", {}).get("parameters", {}).get("Limit") or {}).get("schema", {})
    if limit.get("maximum") != 200:
        errors.append(f"components.parameters.Limit.schema.maximum = {limit.get('maximum')!r}, ядро §19.2 — 200")
    for (m, np), (real_path, op) in ops.items():
        qp = query_params(doc, doc["paths"][real_path], op)
        lim = deref(doc, qp.get("limit", {})).get("schema", {}) if "limit" in qp else None
        if lim is not None and isinstance(lim.get("maximum"), int) and lim["maximum"] > 200:
            errors.append(f"{m} {real_path}: limit.maximum = {lim['maximum']} > 200 (ядро §19.2)")
    for p in ("/catalog/products", "/search/products"):
        item = (doc.get("paths") or {}).get(p, {})
        op = item.get("get")
        if not op:
            continue  # отсутствие пути уже ошибка выше
        sort = query_params(doc, item, op).get("sort")
        schema = deref(doc, (sort or {}).get("schema", {})) if sort else {}
        values = set(schema.get("enum") or (deref(doc, schema.get("items", {})).get("enum") or []))
        for v in ("available:desc", "sku:asc"):
            if v not in values:
                errors.append(f"GET {p}: сортировка {v!r} не объявлена в enum параметра sort (ядро §19.2)")

    for ln in info:
        print(f"INFO: {ln}")
    if args.verbose:
        for ln in skipped:
            print(f"SKIP: {ln}")
    print(f"INFO: обязательных операций/путей: {checked}; исключено как R2/неканоническое: {len(skipped)}; "
          f"запрещённых шаблонов: {len(forbidden)}")
    for e in errors:
        print(f"ERROR: {e}")
    if errors:
        print(f"FAIL: расхождений: {len(errors)}")
        return 1
    print("OK: все обязательные пути и методы есть; запрещённых и лишних операций нет")
    return 0


if __name__ == "__main__":
    sys.exit(main())
