#!/usr/bin/env python3
"""RM-B-008: сверка матрицы прав contracts/rbac/permissions.yaml с ТЗ, seed-миграцией и OpenAPI.

Что проверяется (код выхода 0 — расхождений нет, 1 — есть расхождения, 2 — ошибка запуска):
  A. OpenAPI (contracts/openapi/pos-api.v1.yaml, если файл собран; иначе paths всех parts/*.yaml):
     у каждой операции есть x-permissions (решение RM-B-003: массив; устаревшее x-permission тоже
     читается), каждый код есть в permissions.yaml и не зарезервирован (R2); пустой список — только у
     публичных путей 11 §4.3.1 / SEC-013 (security: [] или схема без субъекта — webhookSignature); /integrations/onec/* —
     ровно [sync.exchange]; x-step-up: true — хотя бы один код со step_up; x-roles — каждая роль
     держит хотя бы один код операции.
  B. Словарь: коды permissions.yaml == таблица 11 §4.3 (82 кода: №1–81 и 42a) в обе стороны, совпадают
     номер, модуль и признак step-up (колонка «Step-up» начинается с «S!»); step_up_scope == таблица
     областей 11 §4.1 п.7.
  C. Роли: roles == enum role_code 07 §14.2 == роли 11 §4.2 (без статуса pending_activation);
     name_ru — 07 §5.4; is_assignable=false ровно у customer, integration и kiosk (07 §5.4, ADR-115).
  D. Матрица: grants == матрица 11 §4.4 (ячейка не «—» → право выдано) с явно перечисленными
     особыми строками и решениями NOTES.md (customer → customer.self.*); инварианты SEC-036, SEC-138, T-SEC-019,
     ядро §17.2, §21 п.3, §22.11, §23 п.3, §24.2; псевдо-набор pending_activation == 11 §4.2.
  E. Seed: seed-миграции RBAC pos-api/migrations/NNNN_*rbac_seed.sql — 0002_rbac_seed.sql (элементы yaml без
     since) и дельты (элементы с since: "NNNN"; пара — по позднейшему концу, NOTES.md §2 п.19, ADR-115 п. 14):
     каждый файл содержит ровно свои роли, коды (с requires_step_up), пары role_permissions (с constraint_json)
     и контрольные списки DO-блока; объединение файлов == permissions.yaml.

Сетевых запросов нет. Запуск:
  python -I -X utf8 scripts/check_api_permissions.py [--root D:/optomstroy] [--openapi FILE]
      [--require-operations] [--no-seed]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    print("ERROR: нужен пакет pyyaml", file=sys.stderr)
    sys.exit(2)

DOC07 = "docs/specification/07_DATA_MODEL.md"
DOC11 = "docs/specification/11_SECURITY_PRIVACY.md"
RBAC = "contracts/rbac/permissions.yaml"
SEED_DIR = "pos-api/migrations"
SEED_BASE = "0002"  # 0002_rbac_seed.sql — элементы yaml без since (файл применён и заморожен, ADR-115 п. 14)
SEED_FILE_RE = re.compile(r"^(\d{4})_(?:[a-z0-9_]+_)?rbac_seed\.sql$")  # 0002_rbac_seed.sql, 0023_kiosk_rbac_seed.sql
OPENAPI_BUILT = "contracts/openapi/pos-api.v1.yaml"
OPENAPI_PARTS = "contracts/openapi/parts"

TICK = re.compile(r"`([^`]+)`")
CODE_RE = re.compile(r"^[a-z_]+(\.[a-z_]+)+$")  # 07 §5.5 CHECK permissions.code
HTTP_METHODS = ("get", "put", "post", "delete", "patch", "head", "options", "trace")
CONSTRAINT_KEYS = {"own", "maxPercentFrom"}  # примеры constraint_json 07 §5.6
# Блок B: число кодов 11 §4.3 («Всего 82 кода», строки 1–81 и 42a; №77–81 — ADR-115) — независимая константа.
EXPECTED_CODES = 82
# Блок C: роли с is_assignable=false (07 §5.4): customer — назначает система при регистрации, integration — токен
# без пользователя, kiosk — технический пользователь планшета, только POST /admin/store-tablets (SEC-136, SEC-142).
NON_ASSIGNABLE = ("customer", "integration", "kiosk")

# Публичные пути без access JWT (11 §4.3.1 «без access JWT», SEC-013, SEC-019); параметры нормализованы в {}.
# /auth/unlock/challenge — challenge ключа Windows Hello (08 §4.1.10; 11 SEC-013, §4.3.1; ADR-116).
PUBLIC_PATHS = {
    "/auth/otp/request", "/auth/otp/verify", "/auth/otp/challenges/{}", "/auth/refresh", "/auth/unlock",
    "/auth/unlock/challenge",
    "/registration/complete", "/images/{}/{}", "/payments/qr/webhook", "/integrations/smspro/dlr",
    "/health", "/health/ready", "/openapi.json",
}
# Путь, у которого допустимы и security: [], и код (dev/staging без JWT, prod — system.openapi.read; SEC-019).
PUBLIC_WITH_CODE = {"/openapi.json"}
AUTH_SCHEMES = {"bearerAuth", "stepUpToken", "integrationToken"}  # схемы с аутентифицированным субъектом (08 §8, §4.21)

# Решения NOTES.md §2: ячейка `customer` матрицы 11 §4.4 не «—», но клиенту выдаётся «self»-код
# (11 §4.3.1: GET /customers/{id}, GET /customers/{id}/orders — `customer.self.read`; SEC-032, строка
# «Долг: детализация» и «Привязки: просмотр» 11 §4.4 — `customer.self.receivables.read`/`customer.self.read`).
CUSTOMER_REDIRECT = {
    "customer.read.basic": "customer.self.read",
    "customer.history.read": "customer.self.read",
    "customer.link.read": "customer.self.read",
    "customer.receivables.read.summary": "customer.self.receivables.read",
    "customer.receivables.read.detail": "customer.self.receivables.read",
}
# Коды без строки в матрице 11 §4.4: выдаются только роли, названной в их описании 11 §4.3 (№61, №62).
NO_ROW_CODES = {"customer.self.read": {"customer"}, "customer.self.receivables.read": {"customer"}}


class Report:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.info: list[str] = []

    def err(self, block: str, msg: str) -> None:
        self.errors.append(f"[{block}] {msg}")

    def warn(self, block: str, msg: str) -> None:
        self.warnings.append(f"[{block}] {msg}")

    def note(self, block: str, msg: str) -> None:
        self.info.append(f"[{block}] {msg}")


# ---------------------------------------------------------------- markdown helpers
def lines_between(text: str, start_prefix: str, end_prefix: str) -> list[str]:
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
    body = line.strip()
    if body.startswith("|"):
        body = body[1:]
    if body.endswith("|") and not body.endswith("\\|"):
        body = body[:-1]
    return [c.strip() for c in re.split(r"(?<!\\)\|", body)]


def granted_cell(cell: str) -> bool:
    c = cell.strip()
    return bool(c) and not c.startswith("—") and not c.startswith("-")


# ---------------------------------------------------------------- sources
def parse_dictionary(doc11: str) -> list[dict]:
    rows = []
    for line in lines_between(doc11, "### 4.3. ", "#### 4.3.1."):
        if not re.match(r"^\| \d+a? \| `", line):
            continue
        c = split_row(line)
        code = TICK.findall(c[1])[0]
        module = re.sub(r"\s+", " ", c[3].replace("`", "")).strip()
        rows.append({"no": c[0], "code": code, "module": module, "step_up": c[4].startswith("S!")})
    return rows


def parse_scopes(doc11: str) -> dict[str, str]:
    lines = doc11.splitlines()
    start = next(i for i, l in enumerate(lines) if "**Области `scope` токена step-up**" in l)
    scope_of: dict[str, str] = {}
    table_started = False
    for line in lines[start + 1:]:
        s = line.strip()
        if s.startswith("|"):
            table_started = True
            if s.startswith("| `"):
                c = split_row(s)
                area = TICK.findall(c[0])[0]
                for code in TICK.findall(c[1]):
                    if CODE_RE.match(code):
                        if code in scope_of:
                            raise ValueError(f"код {code} в двух областях step-up")
                        scope_of[code] = area
        elif table_started and s:
            break
    return scope_of


def parse_roles_11(doc11: str) -> list[str]:
    """Коды ролей таблицы 11 §4.2 без строк «не роль» (статус pending_activation)."""
    roles = []
    for line in lines_between(doc11, "### 4.2. ", "### 4.3. "):
        if not line.startswith("| `"):
            continue
        c = split_row(line)
        if "не роль" in c[0]:
            continue
        roles.append(TICK.findall(c[0])[0])
    return roles


def parse_pseudo_set(doc11: str) -> set[str]:
    for line in lines_between(doc11, "### 4.2. ", "### 4.3. "):
        if line.startswith("| `pending_activation`"):
            text = line.split("псевдо-набор:", 1)[1]
            text = text.split("; пути", 1)[0]
            return {t for t in TICK.findall(text) if CODE_RE.match(t) and "/" not in t}
    raise ValueError("строка pending_activation не найдена в 11 §4.2")


def parse_role_enum_07(doc07: str) -> list[str]:
    m = re.search(r"CREATE TYPE role_code\s+AS ENUM \(([^)]*)\)", doc07)
    if not m:
        raise ValueError("CREATE TYPE role_code не найден в 07")
    return re.findall(r"'([a-z_]+)'", m.group(1))


def parse_role_names_07(doc07: str) -> list[str]:
    for line in lines_between(doc07, "#### 5.4. `roles`", "#### 5.5. "):
        if line.startswith("| name_ru "):
            return re.findall(r"«([^»]+)»", line)
    raise ValueError("строка name_ru не найдена в 07 §5.4")


def parse_matrix(doc11: str) -> tuple[list[str], list[tuple[str, dict[str, str]]]]:
    lines = lines_between(doc11, "### 4.4. ", "### 4.5. ")
    header, rows = None, []
    for line in lines:
        if not line.startswith("|"):
            if header is not None and rows:
                break
            continue
        c = split_row(line)
        if header is None:
            header = [h.strip("` ") for h in c]
            continue
        if set(line.replace("|", "").strip()) <= {"-", " "}:
            continue
        rows.append((c[0], dict(zip(header[1:], c[1:]))))
    if header is None:
        raise ValueError("таблица матрицы 11 §4.4 не найдена")
    return header[1:], rows


# ---------------------------------------------------------------- B, C: dictionary and roles
def check_dictionary(rep: Report, rb: dict, doc11: str) -> None:
    dic = parse_dictionary(doc11)
    scopes = parse_scopes(doc11)
    if len(dic) != EXPECTED_CODES:
        rep.err("B", f"в 11 §4.3 найдено {len(dic)} кодов, ожидалось {EXPECTED_CODES}")
    by_code = {d["code"]: d for d in dic}
    perms = rb["permissions"]
    seen = set()
    for p in perms:
        code = p.get("code")
        if not isinstance(code, str) or not CODE_RE.match(code):
            rep.err("B", f"код {code!r} не соответствует формату 07 §5.5")
            continue
        if code in seen:
            rep.err("B", f"код {code} повторяется в permissions.yaml")
        seen.add(code)
        for key in ("description", "step_up"):
            if key not in p:
                rep.err("B", f"{code}: нет поля {key}")
        d = by_code.get(code)
        if d is None:
            rep.err("B", f"{code}: нет в словаре 11 §4.3")
            continue
        if str(p.get("number")) != d["no"]:
            rep.err("B", f"{code}: number={p.get('number')!r}, в 11 §4.3 — {d['no']}")
        if p.get("module") != d["module"]:
            rep.err("B", f"{code}: module={p.get('module')!r}, в 11 §4.3 — {d['module']!r}")
        if bool(p.get("step_up")) != d["step_up"]:
            rep.err("B", f"{code}: step_up={p.get('step_up')}, в 11 §4.3 — {'S!' if d['step_up'] else '—'}")
        if p.get("step_up_scope") != scopes.get(code):
            if not (p.get("reserved") and p.get("step_up_scope") is None):
                rep.err("B", f"{code}: step_up_scope={p.get('step_up_scope')!r}, в 11 §4.1 п.7 — {scopes.get(code)!r}")
        if p.get("step_up") and not p.get("reserved") and code not in scopes:
            rep.err("B", f"{code}: S!-код вне областей step-up 11 §4.1 п.7")
    for code in by_code:
        if code not in seen:
            rep.err("B", f"{code} (11 §4.3 №{by_code[code]['no']}) отсутствует в permissions.yaml")
    for code in scopes:
        if code in by_code and not by_code[code]["step_up"]:
            rep.err("B", f"{code}: в области step-up 11 §4.1 п.7, но в 11 §4.3 без S!")
    rep.note("B", f"словарь 11 §4.3: {len(dic)} кодов; S!: {sum(d['step_up'] for d in dic)}; "
                  f"в областях step-up: {len(scopes)}")


def check_roles(rep: Report, rb: dict, doc07: str, doc11: str) -> None:
    enum07 = parse_role_enum_07(doc07)
    names07 = parse_role_names_07(doc07)
    roles11 = parse_roles_11(doc11)
    codes = [r.get("code") for r in rb["roles"]]
    if codes != enum07:
        rep.err("C", f"roles {codes} != enum role_code 07 {enum07}")
    if sorted(roles11) != sorted(enum07):
        rep.err("C", f"роли 11 §4.2 {roles11} != enum role_code 07 {enum07}")
    for i, r in enumerate(rb["roles"]):
        code = r.get("code")
        if i < len(names07) and r.get("name_ru") != names07[i]:
            rep.err("C", f"{code}: name_ru={r.get('name_ru')!r}, в 07 §5.4 — {names07[i]!r}")
        expect_assignable = code not in NON_ASSIGNABLE
        if r.get("is_assignable") is not expect_assignable:
            rep.err("C", f"{code}: is_assignable={r.get('is_assignable')}, по 07 §5.4 — {expect_assignable}")
        if r.get("is_system") is not True:
            rep.err("C", f"{code}: is_system должен быть true (системные роли seed, 07 §5.4)")
        if r.get("sort_order") != i + 1:
            rep.err("C", f"{code}: sort_order={r.get('sort_order')}, ожидается {i + 1} (порядок enum)")
    rep.note("C", f"роли: {', '.join(codes)}")


# ---------------------------------------------------------------- D: matrix and invariants
def expected_from_matrix(rep: Report, doc11: str, known: set[str]) -> dict[str, set[str]]:
    roles, rows = parse_matrix(doc11)
    exp: dict[str, set[str]] = {r: set() for r in roles}
    mentioned: set[str] = set()
    reports = {"reports.sales.read", "reports.receivables.read", "reports.qr_reconciliation.read"}
    for label, cells in rows:
        if label.startswith("Чтение заказов"):
            mentioned |= {"order.read.own", "order.read.all"}
            for r, cell in cells.items():
                if not granted_cell(cell):
                    continue
                exp[r].add("order.read.all" if "all" in cell else "order.read.own")
            continue
        if label.startswith("Транзакции ("):
            mentioned |= {"transactions.read.own", "transactions.read.all"}
            for r, cell in cells.items():
                if granted_cell(cell):
                    exp[r].add("transactions.read.all" if "all" in cell else "transactions.read.own")
            continue
        if label.startswith("Чужие отложенные ("):
            mentioned |= {"cart.parked.read.all", "cart.parked.resume.any"}
            for r, cell in cells.items():
                if granted_cell(cell):
                    exp[r].add("cart.parked.read.all")
                    if "только чтение" not in cell:
                        exp[r].add("cart.parked.resume.any")
            continue
        if label.startswith("Настройки приложения ("):
            mentioned |= {"settings.app.read", "settings.app.update"}
            for r, cell in cells.items():
                if granted_cell(cell):
                    exp[r].add("settings.app.read")
                    if "update" in cell:
                        exp[r].add("settings.app.update")
            continue
        if label.startswith("Отчёты ("):
            mentioned |= reports
            for r, cell in cells.items():
                if granted_cell(cell):
                    exp[r] |= reports
            continue
        if label.startswith("Квитанция об оплате долга"):
            continue  # составная строка: проверяется отдельно (order.documents.print + payment.read.*)
        code = next((t for t in TICK.findall(label) if t in known), None)
        if code is None:
            rep.err("D", f"строка матрицы 11 §4.4 без известного кода: {label[:80]!r}")
            continue
        mentioned.add(code)
        for r, cell in cells.items():
            if granted_cell(cell):
                exp[r].add(code)
    for code, holders in NO_ROW_CODES.items():
        if code in mentioned:
            rep.err("D", f"{code}: ожидался без строки в 11 §4.4, но строка есть — пересмотрите NO_ROW_CODES")
        for r in holders:
            exp[r].add(code)
        mentioned.add(code)
    for code in sorted(known - mentioned):
        rep.err("D", f"{code}: нет строки в матрице 11 §4.4 и нет решения в NOTES.md")
    for code, repl in CUSTOMER_REDIRECT.items():
        if code in exp.get("customer", set()):
            exp["customer"].discard(code)
            exp["customer"].add(repl)
        else:
            rep.warn("D", f"решение customer → {repl} для {code} больше не нужно: в 11 §4.4 ячейка «—»")
    # Составная строка «Квитанция об оплате долга»: ✓ → print + payment.read.*.
    for label, cells in rows:
        if label.startswith("Квитанция об оплате долга"):
            for r, cell in cells.items():
                if granted_cell(cell):
                    have = exp[r]
                    if "order.documents.print" not in have or not ({"payment.read.all", "payment.read.own"} & have):
                        rep.err("D", f"{r}: «Квитанция» ✓, но нет order.documents.print + payment.read.* в матрице")
    return exp


def check_matrix(rep: Report, rb: dict, doc11: str) -> None:
    known = {p["code"] for p in rb["permissions"] if isinstance(p.get("code"), str)}
    reserved = {p["code"] for p in rb["permissions"] if p.get("reserved")}
    by_code = {p["code"]: p for p in rb["permissions"] if isinstance(p.get("code"), str)}
    roles = [r["code"] for r in rb["roles"]]
    grants: dict[str, list[str]] = rb.get("grants") or {}
    if set(grants) != set(roles):
        rep.err("D", f"grants: роли {sorted(grants)} != roles {sorted(roles)}")
    g = {}
    for r in roles:
        lst = grants.get(r) or []
        if len(lst) != len(set(lst)):
            rep.err("D", f"{r}: повторяющиеся коды в grants")
        for c in lst:
            if c not in known:
                rep.err("D", f"{r}: код {c} отсутствует в permissions")
            if c in reserved:
                rep.err("D", f"{r}: выдан зарезервированный (R2) код {c}")
        g[r] = set(lst)

    exp = expected_from_matrix(rep, doc11, known)
    for r in roles:
        e = exp.get(r)
        if e is None:
            rep.err("D", f"колонки {r} нет в матрице 11 §4.4")
            continue
        for c in sorted(e - g[r]):
            rep.err("D", f"{r}: по 11 §4.4 выдан {c}, в grants нет")
        for c in sorted(g[r] - e):
            if r == "customer" and c in CUSTOMER_REDIRECT:
                rep.err("D", f"{r}: в grants есть {c}; по решению NOTES.md §2 клиенту — {CUSTOMER_REDIRECT[c]}")
            else:
                rep.err("D", f"{r}: в grants есть {c}, по 11 §4.4 — «—»")

    def holders(code: str) -> set[str]:
        return {r for r in roles if code in g[r]}

    inv = [
        (not any(c.startswith("payment.") for c in g["admin"]), "admin без payment.* (SEC-036, ядро §17.2)"),
        (not ({"credit.sale.create", "credit.sale.approve"} & g["admin"]), "admin без credit.sale.* (SEC-036)"),
        ("discount.approve.over_limit" in g["admin"], "admin c discount.approve.over_limit (SEC-036)"),
        (not ({"users.manage", "settings.app.update", "settings.discount_limits.update"} & g["owner"]),
         "owner без users.manage и settings.*.update (SEC-036)"),
        (not ({"payment.cash.receive", "payment.qr.show", "payment.qr.confirm_manual", "payment.void",
               "payment.debt.receive", "credit.sale.create", "credit.sale.approve"} & g["owner"]),
         "owner без кассовых прав (D-15, SEC-036)"),
        (holders("customer.link.resolve") == {"admin"}, "customer.link.resolve — только admin (ядро §22.12)"),
        (holders("return.approve") == {"senior_seller", "admin"}, "return.approve — senior_seller, admin (§22.11)"),
        (holders("payment.void") == {"cashier", "senior_seller"}, "payment.void — cashier, senior_seller (§23 п.3)"),
        (holders("credit.sale.approve") == {"senior_seller"}, "credit.sale.approve — только senior_seller"),
        (holders("sync.exchange") == {"integration"} and g["integration"] == {"sync.exchange"},
         "integration — только sync.exchange (SEC-038)"),
        (holders("users.emergency_code.issue") == {"admin"}, "users.emergency_code.issue — только admin"),
        (holders("invitations.manage") == {"admin"}, "invitations.manage — только admin (SEC-136)"),
        (holders("users.roles.assign") == {"admin", "owner"}, "users.roles.assign — admin, owner (§21 п.3)"),
        (holders("session.revoke.any") == {"admin", "owner"}, "session.revoke.any — admin, owner (§21 п.3)"),
        (holders("customer.link.self_resolve") == {"customer"}, "customer.link.self_resolve — только customer"),
        (holders("customer.self.read") == {"customer"} and holders("customer.self.receivables.read") == {"customer"},
         "customer.self.* — только customer"),
        (not ({"credit.sale.create", "credit.sale.approve", "discount.apply.within_limit",
               "discount.approve.over_limit", "payment.cash.receive", "payment.debt.receive", "search.customers",
               "transactions.read.own", "transactions.read.all", "catalog.prices.read.all"} & g["customer"]),
         "customer без долга, ручной скидки, приёма оплаты, поиска клиентов, транзакций (ядро §24.2, SEC-037)"),
        (holders("catalog.cost_price.read") == {"owner"}, "catalog.cost_price.read — только owner"),
        (all(holders(c) == set() for c in reserved), "зарезервированные коды никому не выданы"),
        # Планшет магазина (ADR-115 п. 13, п. 14; 11 §4.2, §4.4, SEC-138).
        (all(holders(c) == {"kiosk"} for c in ("kiosk.order.submit", "kiosk.self.read", "kiosk.self.exit")),
         "kiosk.order.submit, kiosk.self.* — только kiosk (SEC-138)"),
        (not ({"order.create", "profile.manage.own", "session.manage.own"} & g.get("kiosk", set())),
         "kiosk без order.create, profile.manage.own, session.manage.own (SEC-138, ADR-115 п. 13)"),
        (not any(by_code.get(c, {}).get("step_up") for c in g.get("kiosk", set())),
         "kiosk без кодов S! (у планшета нет телефона и PIN — step-up невозможен, 11 §4.2)"),
        (holders("kiosk.manage") == {"admin"}, "kiosk.manage — только admin (ADR-115 п. 14)"),
        (holders("kiosk.read") == {"admin", "owner"}, "kiosk.read — admin, owner (ADR-115 п. 14)"),
    ]
    for ok, text in inv:
        if not ok:
            rep.err("D", f"инвариант нарушен: {text}")

    cons = rb.get("constraints") or {}
    for r, m in cons.items():
        if r not in g:
            rep.err("D", f"constraints: неизвестная роль {r}")
            continue
        for c, cj in (m or {}).items():
            if c not in g[r]:
                rep.err("D", f"constraints.{r}.{c}: код не выдан роли")
            if not isinstance(cj, dict) or not cj or set(cj) - CONSTRAINT_KEYS:
                rep.err("D", f"constraints.{r}.{c}: ключи {cj!r} вне {sorted(CONSTRAINT_KEYS)} (07 §5.6)")
    for r in roles:
        if "discount.apply.within_limit" in g[r]:
            if (cons.get(r) or {}).get("discount.apply.within_limit", {}).get("maxPercentFrom") != "role_discount_limits":
                rep.err("D", f"{r}: discount.apply.within_limit без maxPercentFrom=role_discount_limits")

    pseudo = set((rb.get("pseudo_sets") or {}).get("pending_activation") or [])
    expected_pseudo = parse_pseudo_set(doc11)
    if pseudo != expected_pseudo:
        rep.err("D", f"pseudo_sets.pending_activation {sorted(pseudo)} != 11 §4.2 {sorted(expected_pseudo)}")
    rep.note("D", "grants: " + ", ".join(f"{r}={len(g[r])}" for r in roles) +
             f"; пар: {sum(len(v) for v in g.values())}")


# ---------------------------------------------------------------- E: seed
def sql_unq(s: str) -> str:
    return s.replace("''", "'")


def block(sql: str, start: str, end: str) -> list[str]:
    """Строки от `start` до `end`; пусто, если раздела нет (дельта seed без ролей или без кодов)."""
    i = sql.find(start)
    if i < 0:
        return []
    j = sql.find(end, i)
    if j < 0:
        raise ValueError(f"в seed нет {end!r} после {start!r}")
    return sql[i:j].splitlines()


def since_of(item: dict) -> str:
    return str(item.get("since") or SEED_BASE)


def expected_seed_parts(rep: Report, rb: dict) -> dict[str, dict]:
    """Ожидаемое содержимое seed-миграций по yaml: since → роли, коды, пары (пара — по позднейшему концу)."""
    rsince = {r["code"]: since_of(r) for r in rb["roles"]}
    psince = {p["code"]: since_of(p) for p in rb["permissions"]}
    for code, s in [*rsince.items(), *psince.items()]:
        if not re.fullmatch(r"\d{4}", s) or s < SEED_BASE:
            rep.err("E", f"{code}: since={s!r} — нужен номер seed-миграции «NNNN» не раньше {SEED_BASE}")
    cons = rb.get("constraints") or {}
    parts: dict[str, dict] = {}

    def part(s: str) -> dict:
        return parts.setdefault(s, {"roles": [], "perms": [], "pairs": []})

    part(SEED_BASE)
    for r in rb["roles"]:
        part(rsince[r["code"]])["roles"].append(
            {k: r[k] for k in ("code", "name_ru", "is_system", "is_assignable", "sort_order")})
    for p in rb["permissions"]:
        part(psince[p["code"]])["perms"].append((p["code"], p["description"], bool(p["step_up"])))
    for r in rb["roles"]:
        for c in rb["grants"].get(r["code"]) or []:
            s = max(rsince[r["code"]], psince.get(c, SEED_BASE))
            part(s)["pairs"].append((r["code"], c, (cons.get(r["code"]) or {}).get(c)))
    return parts


def parse_seed(sql: str) -> dict:
    s = r"'((?:[^']|'')*)'"
    roles = []
    for line in block(sql, "INSERT INTO roles", "ON CONFLICT DO NOTHING;"):
        m = re.match(rf"^\s*\({s}::role_code, {s}, (true|false), (true|false), (\d+)\),?$", line)
        if m:
            roles.append({"code": m[1], "name_ru": sql_unq(m[2]), "is_system": m[3] == "true",
                          "is_assignable": m[4] == "true", "sort_order": int(m[5])})
    perms = []
    for line in block(sql, "INSERT INTO permissions", "ON CONFLICT DO NOTHING;"):
        m = re.match(rf"^\s*\({s}, {s}, (true|false)\),?$", line)
        if m:
            perms.append((m[1], sql_unq(m[2]), m[3] == "true"))
    pairs = []
    for line in block(sql, "INSERT INTO role_permissions", "ON CONFLICT DO NOTHING;"):
        m = re.match(rf"^\s*\({s}, {s}, (?:NULL::jsonb|{s}::jsonb)\),?$", line)
        if m:
            pairs.append((m[1], m[2], json.loads(sql_unq(m[3])) if m[3] is not None else None))
    out: dict = {"roles": roles, "perms": perms, "pairs": pairs, "do": None}
    i = sql.find("DO $$")
    if i >= 0:
        do = sql[i:]

        def region(anchor: str, stop: str) -> str:
            a = do.find(anchor)
            return "" if a < 0 else do[a:do.find(stop, a)]

        out["do"] = {
            "roles": re.findall(r"'([a-z_]+)'", region("INTO missing_roles", "WHERE NOT EXISTS")),
            "perms": re.findall(r"^\s*'([a-z_.]+)',?$", region("INTO missing_perms", "WHERE NOT EXISTS"), re.M),
            "pairs": re.findall(r"^\s*\('([a-z_]+)', '([a-z_.]+)'\),?$",
                                region("INTO missing_pairs", "AS e(role_code"), re.M),
            "raise": "RAISE EXCEPTION" in do,
        }
    out["inserts"] = len(re.findall(r"^INSERT INTO ", sql, re.M))
    out["conflicts"] = len(re.findall(r"^ON CONFLICT DO NOTHING;$", sql, re.M))
    return out


def check_seed(rep: Report, rb: dict, root: Path) -> None:
    files: dict[str, Path] = {}
    for f in sorted((root / SEED_DIR).glob("*.sql")):
        m = SEED_FILE_RE.match(f.name)
        if not m:
            continue
        if m[1] in files:
            rep.err("E", f"два seed-файла RBAC с номером {m[1]}: {files[m[1]].name}, {f.name}")
        files[m[1]] = f
    if SEED_BASE not in files:
        raise ValueError(f"нет {SEED_DIR}/{SEED_BASE}_rbac_seed.sql")
    parts = expected_seed_parts(rep, rb)
    for s in sorted(set(parts) - set(files)):
        rep.err("E", f"в permissions.yaml есть элементы since: \"{s}\", но файла {SEED_DIR}/{s}_*rbac_seed.sql нет "
                     "(python -I -X utf8 scripts/gen_rbac_seed.py)")
    for s in sorted(set(files) - set(parts)):
        rep.err("E", f"{files[s].name}: seed RBAC без элементов permissions.yaml с since: \"{s}\"")
    notes, tot = [], [0, 0, 0]
    for s in sorted(set(parts) & set(files)):
        name, want = files[s].name, parts[s]
        got = parse_seed(files[s].read_text(encoding="utf-8"))
        if got["roles"] != want["roles"]:
            rep.err("E", f"{name}: roles != permissions.yaml (since {s}): {got['roles']} vs {want['roles']}")
        if got["perms"] != want["perms"]:
            a, b = set(got["perms"]), set(want["perms"])
            rep.err("E", f"{name}: permissions != yaml (since {s}): только в seed {sorted(a - b)[:5]}, "
                         f"только в yaml {sorted(b - a)[:5]}")
        if got["pairs"] != want["pairs"]:
            a = {(x, y, json.dumps(z, sort_keys=True)) for x, y, z in got["pairs"]}
            b = {(x, y, json.dumps(z, sort_keys=True)) for x, y, z in want["pairs"]}
            rep.err("E", f"{name}: role_permissions != yaml (since {s}): только в seed {sorted(a - b)[:5]}, "
                         f"только в yaml {sorted(b - a)[:5]}")
        do = got["do"]
        if do is None:
            rep.err("E", f"{name}: нет контрольного DO-блока")
        else:
            if do["roles"] != [r["code"] for r in want["roles"]]:
                rep.err("E", f"{name}: контрольный список ролей DO-блока != yaml")
            if do["perms"] != [p[0] for p in want["perms"]]:
                rep.err("E", f"{name}: контрольный список кодов DO-блока != yaml")
            if do["pairs"] != [(x, y) for x, y, _ in want["pairs"]]:
                rep.err("E", f"{name}: контрольный список пар DO-блока != yaml")
            if not do["raise"]:
                rep.err("E", f"{name}: DO-блок без RAISE EXCEPTION")
        if got["inserts"] == 0 or got["inserts"] != got["conflicts"]:
            rep.err("E", f"{name}: каждый INSERT seed должен быть ON CONFLICT DO NOTHING "
                         f"(INSERT {got['inserts']}, ON CONFLICT {got['conflicts']})")
        n = (len(got["roles"]), len(got["perms"]), len(got["pairs"]))
        tot = [tot[0] + n[0], tot[1] + n[1], tot[2] + n[2]]
        notes.append(f"{name}: roles={n[0]}, permissions={n[1]}, role_permissions={n[2]}")
    if len(files) > 1:
        notes.append(f"итого: roles={tot[0]}, permissions={tot[1]}, role_permissions={tot[2]}")
    rep.note("E", "seed: " + "; ".join(notes))


# ---------------------------------------------------------------- A: OpenAPI
def norm_path(p: str) -> str:
    p = re.sub(r"^/api/v1(?=/)", "", p)
    return re.sub(r"\{[^}]+\}", "{}", p)


def load_openapi(root: Path, override: str | None) -> tuple[str, dict, list]:
    if override:
        f = Path(override)
        doc = yaml.safe_load(f.read_text(encoding="utf-8")) or {}
        return str(f), doc.get("paths") or {}, doc.get("security") or []
    built = root / OPENAPI_BUILT
    if built.exists():
        doc = yaml.safe_load(built.read_text(encoding="utf-8")) or {}
        return OPENAPI_BUILT, doc.get("paths") or {}, doc.get("security") or []
    parts = sorted((root / OPENAPI_PARTS).glob("*.yaml"))
    paths: dict = {}
    security: list = []
    for f in parts:
        doc = yaml.safe_load(f.read_text(encoding="utf-8")) or {}
        if "security" in doc:
            security = doc.get("security") or []
        for p, item in (doc.get("paths") or {}).items():
            if p in paths:
                raise ValueError(f"путь {p} определён в двух частях OpenAPI")
            paths[p] = item
    return f"{OPENAPI_PARTS}/*.yaml ({len(parts)} файлов)", paths, security


def is_public_security(sec: list) -> bool:
    if sec == []:
        return True
    schemes = {k for req in sec if isinstance(req, dict) for k in req}
    return bool(schemes) and not (schemes & AUTH_SCHEMES)


def check_openapi(rep: Report, rb: dict, root: Path, override: str | None, require_ops: bool) -> None:
    src, paths, global_sec = load_openapi(root, override)
    by_code = {p["code"]: p for p in rb["permissions"]}
    grants = {r: set(v or []) for r, v in (rb.get("grants") or {}).items()}
    n_ops = 0
    for path, item in paths.items():
        if not isinstance(item, dict):
            continue
        np = norm_path(path)
        for method in HTTP_METHODS:
            op = item.get(method)
            if not isinstance(op, dict):
                continue
            n_ops += 1
            where = f"{method.upper()} {path}"
            raw = op.get("x-permissions", None)
            legacy = op.get("x-permission", None)
            if raw is None and legacy is None:
                rep.err("A", f"{where}: нет x-permissions")
                continue
            if raw is None:
                raw = [legacy] if isinstance(legacy, str) else legacy
                rep.warn("A", f"{where}: устаревшее x-permission — привести к x-permissions (NOTES RM-B-003 §5 п.1)")
            if not isinstance(raw, list) or not all(isinstance(c, str) for c in raw):
                rep.err("A", f"{where}: x-permissions должен быть массивом строк")
                continue
            for c in raw:
                if c not in by_code:
                    rep.err("A", f"{where}: код {c} отсутствует в permissions.yaml")
                elif by_code[c].get("reserved"):
                    rep.err("A", f"{where}: зарезервированный (R2) код {c} в контракте R1")
            sec = op.get("security", global_sec)
            public = is_public_security(sec)
            if not raw:
                if np not in PUBLIC_PATHS:
                    rep.err("A", f"{where}: пустой x-permissions у непубличного пути (deny by default, SEC-028)")
                elif not public:
                    rep.err("A", f"{where}: публичный путь 11 §4.3.1 с security, требующей токен")
            elif public and np not in PUBLIC_WITH_CODE:
                rep.err("A", f"{where}: security без аутентификации субъекта, но x-permissions={raw}")
            if np.startswith("/integrations/onec/") and raw != ["sync.exchange"]:
                rep.err("A", f"{where}: /integrations/onec/* — ровно [sync.exchange] (SEC-038)")
            if "sync.exchange" in raw and not np.startswith("/integrations/onec/"):
                rep.err("A", f"{where}: sync.exchange вне /integrations/onec/*")
            if op.get("x-step-up") is True and not any(by_code.get(c, {}).get("step_up") for c in raw):
                rep.err("A", f"{where}: x-step-up: true, но ни один код {raw} не S!")
            xr = op.get("x-roles")
            if isinstance(xr, list) and raw:
                for r in xr:
                    if r not in grants:
                        rep.err("A", f"{where}: x-roles содержит неизвестную роль {r}")
                    elif not (grants[r] & set(raw)):
                        rep.err("A", f"{where}: роль {r} в x-roles не держит ни одного из {raw}")
                holders = sorted(r for r, gs in grants.items() if gs & set(raw) and r not in xr)
                if holders:
                    rep.warn("A", f"{where}: роли {holders} держат код операции, но не в x-roles (условие?)")
    rep.note("A", f"источник: {src}; операций: {n_ops}")
    if n_ops == 0:
        msg = "операций в OpenAPI нет (части модулей ещё не добавлены) — проверка A выполнена на пустом наборе"
        (rep.err if require_ops else rep.warn)("A", msg)


# ---------------------------------------------------------------- main
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument("--openapi", help="проверить этот файл OpenAPI вместо собранного/частей")
    ap.add_argument("--require-operations", action="store_true", help="0 операций в OpenAPI — ошибка")
    ap.add_argument("--no-seed", action="store_true", help="не сверять seed RBAC (0002 и дельты)")
    args = ap.parse_args()
    root = Path(args.root)
    rep = Report()
    try:
        rb = yaml.safe_load((root / RBAC).read_text(encoding="utf-8"))
        doc07 = (root / DOC07).read_text(encoding="utf-8")
        doc11 = (root / DOC11).read_text(encoding="utf-8")
        for key in ("roles", "permissions", "grants"):
            if not isinstance(rb.get(key), (list if key != "grants" else dict)):
                raise ValueError(f"permissions.yaml: раздел {key} отсутствует или неверного типа")
        check_dictionary(rep, rb, doc11)
        check_roles(rep, rb, doc07, doc11)
        check_matrix(rep, rb, doc11)
        if not args.no_seed:
            check_seed(rep, rb, root)
        check_openapi(rep, rb, root, args.openapi, args.require_operations)
    except (OSError, ValueError, KeyError, StopIteration, yaml.YAMLError) as e:
        print(f"ERROR: {type(e).__name__}: {e}", file=sys.stderr)
        return 2
    for line in rep.info:
        print(f"INFO  {line}")
    for line in rep.warnings:
        print(f"WARN  {line}")
    for line in rep.errors:
        print(f"ERROR {line}")
    print(f"ИТОГ: ошибок {len(rep.errors)}, предупреждений {len(rep.warnings)}")
    return 1 if rep.errors else 0


if __name__ == "__main__":
    sys.exit(main())
