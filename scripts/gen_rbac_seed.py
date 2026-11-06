#!/usr/bin/env python3
"""gen_rbac_seed.py — генератор seed-миграций RBAC pos-api/migrations/0002_rbac_seed.sql и дельт (0023…) из contracts/rbac/permissions.yaml.

B-AR-10 (а) (docs/reviews/B_architecture_review.md): единственный источник ролей, словаря permissions и матрицы
роль × право — contracts/rbac/permissions.yaml (проекция 11 §4.3–§4.4). Seed-миграции не правятся вручную: они
генерируются этим скриптом. CI (RM-C-011, contracts-lint) запускает режим --check.

Дельты (P-002, ADR-115 п. 14; contracts/rbac/NOTES.md §2 п.19). 0002_rbac_seed.sql применена на всех базах, её
контрольная сумма записана в журнал мигратора (pos-api/src/db/migrator.ts) — файл заморожен. Элементы yaml с
`since: "NNNN"` (роли и коды) генерируются в дельта-миграцию NNNN (таблица DELTAS), остальные — в 0002 байт-в-байт
как раньше. Пара роль → код относится к миграции позднейшего из двух концов (since роли или кода). Элементы с since
стоят в конце своих списков: порядок ролей = sort_order = порядок enum role_code, новые значения enum — в конце.

Запуск (из корня репозитория, без сети):
    python -I -X utf8 scripts/gen_rbac_seed.py            # записать дельты (0002 — только если файла нет)
    python -I -X utf8 scripts/gen_rbac_seed.py --check    # код 1, если файл на диске отличается от генерации
    python -I -X utf8 scripts/gen_rbac_seed.py --stdout   # вывести сгенерированный SQL всех файлов

Коды выхода: 0 — успех/совпадает; 1 — расхождение (--check), нарушение инварианта permissions.yaml или попытка
изменить замороженную миграцию; 2 — ошибка использования (нет файла, не установлен pyyaml).
Формат 0002 повторяет исходную генерацию RM-B-008 (порядок ролей — как в roles, кодов — как в permissions,
пар — grants по ролям в порядке permissions), поэтому повторная генерация детерминирована байт-в-байт. Файлы
пишутся атомарно (временный файл без суффикса .sql в том же каталоге, затем rename): стенды embedded-pg применяют
каждый *.sql каталога migrations/ (pos-api/test/support/embedded-pg.ts).
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "contracts" / "rbac" / "permissions.yaml"
MIGRATIONS = ROOT / "pos-api" / "migrations"
BASE = "0002"
DST = MIGRATIONS / "0002_rbac_seed.sql"
SEED_FILE_RE = re.compile(r"^\d{4}_(?:[a-z0-9_]+_)?rbac_seed\.sql$")
SINCE_RE = re.compile(r"^\d{4}$")

# Применённые seed-миграции: генератор не перезаписывает их, даже если yaml изменился (MIGRATION_CHECKSUM_MISMATCH).
# Дельта добавляется сюда, когда её миграция выпущена (применена вне dev/test).
FROZEN = {BASE}

# Дельта-миграции seed: since → имя файла и строки шапки (основание). Новая дельта — новая строка и новый номер
# миграции (следующий свободный, 07 §12.1); прежние дельты не меняются.
DELTAS: dict[str, dict] = {
    "0023": {
        "file": "0023_kiosk_rbac_seed.sql",
        "title": [
            "0023_kiosk_rbac_seed.sql — дельта seed RBAC: роль `kiosk` планшета магазина и коды №77–81 (P-002 ред. 5,",
            "ADR-115 п. 14; задача TAB-1-01, часть «RBAC»).",
        ],
        "basis": [
            "Источник: contracts/rbac/permissions.yaml (версия 2), элементы с since: \"0023\" — проекция 11_SECURITY_PRIVACY",
            "§4.2 (роль kiosk), §4.3 (№77–81), §4.4 (колонка kiosk; kiosk.read — admin, owner; kiosk.manage — admin).",
            "Таблицы и колонки — 07_DATA_MODEL §5.4 roles, §5.5 permissions, §5.6 role_permissions.",
            "Требует 0021_kiosk_enum_values.sql: значение 'kiosk' enum role_code зафиксировано раньше этой транзакции",
            "(07 §12.2, DATA-305). Применённая 0002_rbac_seed.sql (7 ролей, 77 кодов, 231 пара) не меняется (07 §12.1,",
            "ADR-115 п. 14). role_discount_limits для kiosk не создаётся (лимит 0 — 07 §5.34), app_settings — не здесь.",
            "Права kiosk.order.submit, kiosk.self.read, kiosk.self.exit засчитываются только при kind=kiosk — это",
            "проверяет код (11 SEC-138), а не seed.",
        ],
    },
}


class SpecError(Exception):
    pass


def sq(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def cj(obj) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(", ", ": "))


def load(path: Path) -> dict:
    try:
        import yaml  # type: ignore
    except ImportError:  # pragma: no cover
        print("ERROR: нужен pyyaml (pip install pyyaml)", file=sys.stderr)
        sys.exit(2)
    if not path.is_file():
        print(f"ERROR: нет файла {path}", file=sys.stderr)
        sys.exit(2)
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def since_of(item: dict) -> str:
    return item.get("since") or BASE


def validate(doc: dict) -> tuple[list, list, dict, dict]:
    roles = doc.get("roles") or []
    perms = doc.get("permissions") or []
    grants = doc.get("grants") or {}
    constraints = doc.get("constraints") or {}
    role_codes = [r["code"] for r in roles]
    perm_codes = [p["code"] for p in perms]
    errors = []
    if len(set(role_codes)) != len(role_codes):
        errors.append("roles: повторяющиеся коды")
    if len(set(perm_codes)) != len(perm_codes):
        errors.append("permissions: повторяющиеся коды")
    for n, r in enumerate(roles, 1):
        if r.get("sort_order") != n:
            errors.append(f"roles: {r['code']}: sort_order {r.get('sort_order')} ≠ {n} (порядок enum role_code)")
        if r.get("is_system") is not True:
            errors.append(f"roles: {r['code']}: is_system должен быть true (07 §5.4)")
    for section, items in (("roles", roles), ("permissions", perms)):
        prev = BASE
        for it in items:
            s = it.get("since")
            if s is not None:
                if not isinstance(s, str) or not SINCE_RE.match(s):
                    errors.append(f"{section}: {it['code']}: since={s!r} — нужен номер миграции строкой, например \"0023\"")
                    continue
                if s <= BASE or s not in DELTAS:
                    errors.append(f"{section}: {it['code']}: since {s} — нет дельты в DELTAS gen_rbac_seed.py")
                    continue
            if since_of(it) < prev:
                errors.append(f"{section}: {it['code']}: элемент 0002/ранней дельты после элемента дельты {prev} "
                              "(элементы с since — в конце списка, по возрастанию)")
            prev = max(prev, since_of(it))
    pos = {c: i for i, c in enumerate(perm_codes)}
    reserved = {p["code"] for p in perms if p.get("reserved")}
    if set(grants) != set(role_codes):
        errors.append(f"grants: роли {sorted(set(grants) ^ set(role_codes))} не совпадают с roles")
    for r, codes in grants.items():
        codes = codes or []
        if len(set(codes)) != len(codes):
            errors.append(f"grants.{r}: повторяющиеся коды")
        for c in codes:
            if c not in pos:
                errors.append(f"grants.{r}: неизвестный код {c}")
            elif c in reserved:
                errors.append(f"grants.{r}: код {c} помечен reserved (R2) и не выдаётся")
        if [c for c in codes if c in pos] != sorted((c for c in codes if c in pos), key=pos.get):
            errors.append(f"grants.{r}: порядок кодов не совпадает с порядком permissions (11 §4.3)")
    for r, cmap in constraints.items():
        if r not in grants:
            errors.append(f"constraints.{r}: роли нет в grants")
            continue
        for c in (cmap or {}):
            if c not in (grants[r] or []):
                errors.append(f"constraints.{r}.{c}: ограничитель для невыданного кода")
    if errors:
        raise SpecError("\n".join(errors))
    return roles, perms, grants, constraints


def split(doc: dict) -> dict[str, dict]:
    """Элементы yaml по seed-миграциям: since → {roles, perms, pairs[(role, code, constraint)]}."""
    roles, perms, grants, constraints = validate(doc)
    rsince = {r["code"]: since_of(r) for r in roles}
    psince = {p["code"]: since_of(p) for p in perms}
    parts: dict[str, dict] = {s: {"roles": [], "perms": [], "pairs": []} for s in [BASE, *DELTAS]}
    for r in roles:
        parts[rsince[r["code"]]]["roles"].append(r)
    for p in perms:
        parts[psince[p["code"]]]["perms"].append(p)
    for r in roles:
        code = r["code"]
        cmap = constraints.get(code) or {}
        for c in grants.get(code) or []:
            parts[max(rsince[code], psince[c])]["pairs"].append((code, c, cmap.get(c)))
    return parts


def render_base(roles: list, perms: list, pairs: list) -> str:
    """0002_rbac_seed.sql — формат RM-B-008 без изменений (файл заморожен, см. FROZEN)."""
    s: list[str] = []
    a = s.append
    a("-- 0002_rbac_seed.sql — RM-B-008: seed ролей, словаря permissions и матрицы роль × право.")
    a("--")
    a("-- Источник: contracts/rbac/permissions.yaml (проекция 11_SECURITY_PRIVACY §4.3–§4.4; ядро R0 v1.9 §3, §17.2,")
    a("-- §21 п.3, §22, §23, §24.2). Таблицы и колонки — 07_DATA_MODEL §5.4 roles, §5.5 permissions,")
    a("-- §5.6 role_permissions (§5.7 user_roles seed не заполняет: пользователей миграция не создаёт).")
    a("-- Требует 0001_init.sql: enum role_code, функция uuid_generate_v7() (DEFAULT для id), уникальные")
    a("-- roles_code_uq, permissions_code_uq, PK role_permissions (role_id, permission_id).")
    a("--")
    a("-- Идемпотентно: каждая вставка — ON CONFLICT DO NOTHING; повторное применение не меняет данных.")
    a("-- Существующие строки не обновляются: изменение состава прав — только новой миграцией (11 SEC-027).")
    a("-- role_discount_limits и app_settings здесь не заполняются (не входят в RM-B-008; см. contracts/rbac/NOTES.md).")
    a("-- СГЕНЕРИРОВАНО scripts/gen_rbac_seed.py из permissions.yaml — вручную не править (B-AR-10);")
    a("-- проверка дрейфа — gen_rbac_seed.py --check, сверка с 11 и OpenAPI — scripts/check_api_permissions.py.")
    a("")
    a("-- 1. Роли (07 §5.4; ядро §3.1, §24.2). customer и integration вручную не назначаются (is_assignable=false).")
    a("INSERT INTO roles (code, name_ru, is_system, is_assignable, sort_order) VALUES")
    a(",\n".join(
        f"  ({sq(r['code'])}::role_code, {sq(r['name_ru'])}, true, {'true' if r['is_assignable'] else 'false'}, {r['sort_order']})"
        for r in roles))
    a("ON CONFLICT DO NOTHING;")
    a("")
    a(f"-- 2. Словарь permissions (07 §5.5): {len(perms)} кодов 11 §4.3 (№1–76 и 42a), requires_step_up = «S!» колонки Step-up.")
    a("--    customer.update (№28) и reports.export (№60) — R2: в словаре есть, ролям не выдаются.")
    a("INSERT INTO permissions (code, description_ru, requires_step_up) VALUES")
    a(",\n".join(
        f"  ({sq(p['code'])}, {sq(p['description'])}, {'true' if p['step_up'] else 'false'})" for p in perms))
    a("ON CONFLICT DO NOTHING;")
    a("")
    a("-- 3. Матрица роль × право (07 §5.6; 11 §4.4). constraint_json: {\"own\": true} — только свои объекты;")
    a("--    {\"maxPercentFrom\": \"role_discount_limits\"} — лимит скидки роли. Прочие условия — в коде (NOTES.md).")
    a("INSERT INTO role_permissions (role_id, permission_id, constraint_json)")
    a("SELECT r.id, p.id, g.constraint_json")
    a("FROM (VALUES")
    a(",\n".join(f"  ({sq(r)}, {sq(c)}, {sq(cj(v)) + '::jsonb' if v else 'NULL::jsonb'})" for r, c, v in pairs))
    a(") AS g (role_code, permission_code, constraint_json)")
    a("JOIN roles r ON r.code = g.role_code::role_code")
    a("JOIN permissions p ON p.code = g.permission_code")
    a("ON CONFLICT DO NOTHING;")
    a("")
    a(f"-- 4. Контроль: все {len(roles)} ролей, {len(perms)} кодов и {len(pairs)} пар матрицы присутствуют (опечатка в коде")
    a("--    или роли в VALUES иначе молча выпала бы из JOIN). Лишние строки, добавленные последующими")
    a("--    миграциями, не считаются ошибкой — проверяется только «ожидаемое ⊆ фактическое».")
    a("DO $$")
    a("DECLARE")
    a("  missing_roles integer;")
    a("  missing_perms integer;")
    a("  missing_pairs integer;")
    a("BEGIN")
    a("  SELECT count(*) INTO missing_roles")
    a("  FROM unnest(ARRAY[" + ", ".join(sq(r["code"]) for r in roles) + "]) AS e(code)")
    a("  WHERE NOT EXISTS (SELECT 1 FROM roles r WHERE r.code::text = e.code);")
    a("")
    a("  SELECT count(*) INTO missing_perms")
    a("  FROM unnest(ARRAY[")
    a(",\n".join("    " + sq(p["code"]) for p in perms))
    a("  ]) AS e(code)")
    a("  WHERE NOT EXISTS (SELECT 1 FROM permissions p WHERE p.code = e.code);")
    a("")
    a("  SELECT count(*) INTO missing_pairs")
    a("  FROM (VALUES")
    a(",\n".join(f"    ({sq(r)}, {sq(c)})" for r, c, _ in pairs))
    a("  ) AS e(role_code, permission_code)")
    a("  WHERE NOT EXISTS (")
    a("    SELECT 1 FROM role_permissions rp")
    a("    JOIN roles r ON r.id = rp.role_id")
    a("    JOIN permissions p ON p.id = rp.permission_id")
    a("    WHERE r.code::text = e.role_code AND p.code = e.permission_code);")
    a("")
    a("  IF missing_roles > 0 OR missing_perms > 0 OR missing_pairs > 0 THEN")
    a("    RAISE EXCEPTION 'rbac seed incomplete: % roles, % permissions, % role_permissions pairs missing',")
    a("      missing_roles, missing_perms, missing_pairs;")
    a("  END IF;")
    a("END $$;")
    return "\n".join(s) + "\n"


def numbers(perms: list) -> str:
    nums = [str(p["number"]) for p in perms]
    if all(n.isdigit() for n in nums) and [int(n) for n in nums] == list(range(int(nums[0]), int(nums[0]) + len(nums))):
        return f"№{nums[0]}–{nums[-1]}" if len(nums) > 1 else f"№{nums[0]}"
    return ", ".join(f"№{n}" for n in nums)


def render_delta(since: str, part: dict, totals: tuple[int, int, int]) -> str:
    """Дельта seed NNNN: только элементы с since = NNNN и пары, у которых позднейший конец — NNNN."""
    meta = DELTAS[since]
    roles, perms, pairs = part["roles"], part["perms"], part["pairs"]
    if not (roles or perms or pairs):
        raise SpecError(f"дельта {since}: в permissions.yaml нет элементов с since: \"{since}\" — уберите её из DELTAS")
    s: list[str] = []
    a = s.append
    for line in meta["title"]:
        a(f"-- {line}")
    a("--")
    for line in meta["basis"]:
        a(f"-- {line}")
    a("--")
    a("-- Идемпотентно: каждая вставка — ON CONFLICT DO NOTHING; повторное применение не меняет данных.")
    a("-- Существующие строки не обновляются: изменение состава прав — только новой миграцией (11 SEC-027).")
    a("-- Явного BEGIN/COMMIT нет: транзакцию задаёт мигратор (одна транзакция на файл, 07 §12.1).")
    a("-- СГЕНЕРИРОВАНО scripts/gen_rbac_seed.py из permissions.yaml — вручную не править (B-AR-10);")
    a("-- проверка дрейфа — gen_rbac_seed.py --check, сверка с 11 и OpenAPI — scripts/check_api_permissions.py.")
    n = 0
    if roles:
        n += 1
        na = [r["code"] for r in roles if not r["is_assignable"]]
        a("")
        a(f"-- {n}. Роли (07 §5.4; 11 §4.2): {', '.join(r['code'] for r in roles)} — sort_order по порядку enum role_code (07 §14.2).")
        if na:
            a(f"--    Вручную не назначаются (is_assignable=false): {', '.join(na)}.")
        a("INSERT INTO roles (code, name_ru, is_system, is_assignable, sort_order) VALUES")
        a(",\n".join(
            f"  ({sq(r['code'])}::role_code, {sq(r['name_ru'])}, true, {'true' if r['is_assignable'] else 'false'}, {r['sort_order']})"
            for r in roles))
        a("ON CONFLICT DO NOTHING;")
    if perms:
        n += 1
        a("")
        a(f"-- {n}. Словарь permissions (07 §5.5): коды 11 §4.3 {numbers(perms)} (кодов: {len(perms)}),"
          " requires_step_up = «S!» колонки Step-up.")
        a("INSERT INTO permissions (code, description_ru, requires_step_up) VALUES")
        a(",\n".join(
            f"  ({sq(p['code'])}, {sq(p['description'])}, {'true' if p['step_up'] else 'false'})" for p in perms))
        a("ON CONFLICT DO NOTHING;")
    if pairs:
        n += 1
        by_role: dict[str, int] = {}
        for r, _, _ in pairs:
            by_role[r] = by_role.get(r, 0) + 1
        a("")
        a(f"-- {n}. Матрица роль × право (07 §5.6; 11 §4.4), пар: {len(pairs)} — "
          + ", ".join(f"{r}: {k}" for r, k in by_role.items()) + ".")
        a("--    constraint_json — как в 0002 ({\"own\": true}, {\"maxPercentFrom\": …}); прочие условия — в коде (NOTES.md).")
        a("INSERT INTO role_permissions (role_id, permission_id, constraint_json)")
        a("SELECT r.id, p.id, g.constraint_json")
        a("FROM (VALUES")
        a(",\n".join(f"  ({sq(r)}, {sq(c)}, {sq(cj(v)) + '::jsonb' if v else 'NULL::jsonb'})" for r, c, v in pairs))
        a(") AS g (role_code, permission_code, constraint_json)")
        a("JOIN roles r ON r.code = g.role_code::role_code")
        a("JOIN permissions p ON p.code = g.permission_code")
        a("ON CONFLICT DO NOTHING;")
    n += 1
    a("")
    a(f"-- {n}. Контроль: роли ({len(roles)}), коды ({len(perms)}) и пары ({len(pairs)}) этой миграции присутствуют — опечатка")
    a("--    в коде или роли в VALUES иначе молча выпала бы из JOIN. Проверяется только «ожидаемое ⊆ фактическое»: строки")
    a(f"--    0002 и следующих миграций не мешают. Итог после миграции: ролей {totals[0]}, кодов {totals[1]}, пар {totals[2]}.")
    a("DO $$")
    a("DECLARE")
    a("  missing_roles integer := 0;")
    a("  missing_perms integer := 0;")
    a("  missing_pairs integer := 0;")
    a("BEGIN")
    if roles:
        a("  SELECT count(*) INTO missing_roles")
        a("  FROM unnest(ARRAY[" + ", ".join(sq(r["code"]) for r in roles) + "]) AS e(code)")
        a("  WHERE NOT EXISTS (SELECT 1 FROM roles r WHERE r.code::text = e.code);")
        a("")
    if perms:
        a("  SELECT count(*) INTO missing_perms")
        a("  FROM unnest(ARRAY[")
        a(",\n".join("    " + sq(p["code"]) for p in perms))
        a("  ]) AS e(code)")
        a("  WHERE NOT EXISTS (SELECT 1 FROM permissions p WHERE p.code = e.code);")
        a("")
    if pairs:
        a("  SELECT count(*) INTO missing_pairs")
        a("  FROM (VALUES")
        a(",\n".join(f"    ({sq(r)}, {sq(c)})" for r, c, _ in pairs))
        a("  ) AS e(role_code, permission_code)")
        a("  WHERE NOT EXISTS (")
        a("    SELECT 1 FROM role_permissions rp")
        a("    JOIN roles r ON r.id = rp.role_id")
        a("    JOIN permissions p ON p.id = rp.permission_id")
        a("    WHERE r.code::text = e.role_code AND p.code = e.permission_code);")
        a("")
    a("  IF missing_roles > 0 OR missing_perms > 0 OR missing_pairs > 0 THEN")
    a(f"    RAISE EXCEPTION 'rbac seed {since} incomplete: % roles, % permissions, % role_permissions pairs missing',")
    a("      missing_roles, missing_perms, missing_pairs;")
    a("  END IF;")
    a("END $$;")
    return "\n".join(s) + "\n"


def render_all(doc: dict) -> dict[str, tuple[Path, str]]:
    """since → (путь файла, SQL) для 0002 и всех дельт DELTAS."""
    parts = split(doc)
    base = parts[BASE]
    out = {BASE: (DST, render_base(base["roles"], base["perms"], base["pairs"]))}
    tr, tp, tg = len(base["roles"]), len(base["perms"]), len(base["pairs"])
    for since in sorted(DELTAS):
        part = parts[since]
        tr, tp, tg = tr + len(part["roles"]), tp + len(part["perms"]), tg + len(part["pairs"])
        out[since] = (MIGRATIONS / DELTAS[since]["file"], render_delta(since, part, (tr, tp, tg)))
    return out


def write_atomic(path: Path, text: str) -> None:
    tmp = path.with_name(f".{path.name}.tmp")  # без суффикса .sql: стенды embedded-pg его не применят
    tmp.write_bytes(text.encode("utf-8"))
    os.replace(tmp, path)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--check", action="store_true", help="сравнить с файлами на диске (код 1 при расхождении)")
    g.add_argument("--stdout", action="store_true", help="напечатать SQL вместо записи")
    args = ap.parse_args()
    try:
        files = render_all(load(SRC))
    except SpecError as e:
        print(f"ERROR: permissions.yaml нарушает инварианты:\n{e}", file=sys.stderr)
        return 1
    expected = {p.name for p, _ in files.values()}
    if args.stdout:
        for p, out in files.values():
            sys.stdout.buffer.write(f"-- >>> {p.relative_to(ROOT).as_posix()}\n".encode("utf-8") + out.encode("utf-8"))
        return 0
    rc = 0
    current = {s: (p.read_text(encoding="utf-8") if p.is_file() else None) for s, (p, _) in files.items()}
    # Замороженная миграция разошлась с генерацией — в режиме записи не пишется ни один файл.
    blocked = any(s in FROZEN and current[s] is not None and current[s] != out for s, (_, out) in files.items())
    for since, (path, out) in files.items():
        rel = path.relative_to(ROOT).as_posix()
        cur = current[since]
        if cur == out:
            print(f"OK: {rel} совпадает с генерацией из contracts/rbac/permissions.yaml ({len(out.encode('utf-8'))} байт)")
            continue
        if args.check or blocked:
            diff = list(difflib.unified_diff((cur or "").splitlines(), out.splitlines(), "на диске", "генерация",
                                             lineterm="", n=1))
            print(f"DRIFT: {rel} отличается от генерации ({len(diff)} строк diff); первые 40:", file=sys.stderr)
            print("\n".join(diff[:40]), file=sys.stderr)
            if since in FROZEN:
                print(f"{rel} — применённая миграция (FROZEN), её менять нельзя: новые роли, коды и пары вносите в yaml "
                      "с since новой дельты (NOTES.md §2 п.19); файлы не записаны", file=sys.stderr)
            elif blocked:
                print(f"{rel} не записан: расходится замороженная миграция (см. выше)", file=sys.stderr)
            else:
                print("Исправление: python -I -X utf8 scripts/gen_rbac_seed.py (правка — только в permissions.yaml)",
                      file=sys.stderr)
            rc = 1
            continue
        write_atomic(path, out)
        print(f"OK: записан {rel} ({len(out.encode('utf-8'))} байт)")
    orphans = sorted(f.name for f in MIGRATIONS.glob("*.sql") if SEED_FILE_RE.match(f.name) and f.name not in expected)
    for name in orphans:
        print(f"DRIFT: pos-api/migrations/{name} — seed RBAC без дельты в DELTAS gen_rbac_seed.py", file=sys.stderr)
        rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
