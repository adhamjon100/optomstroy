#!/usr/bin/env python3
"""gen_rbac_seed.py — генератор pos-api/migrations/0002_rbac_seed.sql из contracts/rbac/permissions.yaml.

B-AR-10 (а) (docs/reviews/B_architecture_review.md): единственный источник ролей, словаря permissions и матрицы
роль × право — contracts/rbac/permissions.yaml (проекция 11 §4.3–§4.4). Seed-миграция 0002 больше не правится
вручную: она генерируется этим скриптом. CI (RM-C-011, contracts-lint) запускает режим --check.

Запуск (из корня репозитория, без сети):
    python -I -X utf8 scripts/gen_rbac_seed.py            # перезаписать 0002_rbac_seed.sql
    python -I -X utf8 scripts/gen_rbac_seed.py --check    # код 1, если файл на диске отличается от генерации
    python -I -X utf8 scripts/gen_rbac_seed.py --stdout   # вывести сгенерированный SQL

Коды выхода: 0 — успех/совпадает; 1 — расхождение (--check) или нарушение инварианта permissions.yaml;
2 — ошибка использования (нет файла, не установлен pyyaml).
Формат вывода повторяет исходную генерацию RM-B-008 (порядок ролей — как в roles, кодов — как в permissions,
пар — grants по ролям в порядке permissions), поэтому повторная генерация детерминирована байт-в-байт.
"""
from __future__ import annotations

import argparse
import difflib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "contracts" / "rbac" / "permissions.yaml"
DST = ROOT / "pos-api" / "migrations" / "0002_rbac_seed.sql"


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


def render(doc: dict) -> str:
    roles, perms, grants, constraints = validate(doc)
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
    rows = []
    for r in roles:
        code = r["code"]
        cmap = constraints.get(code) or {}
        for c in grants.get(code) or []:
            v = cmap.get(c)
            rows.append(f"  ({sq(code)}, {sq(c)}, {sq(cj(v)) + '::jsonb' if v else 'NULL::jsonb'})")
    a(",\n".join(rows))
    a(") AS g (role_code, permission_code, constraint_json)")
    a("JOIN roles r ON r.code = g.role_code::role_code")
    a("JOIN permissions p ON p.code = g.permission_code")
    a("ON CONFLICT DO NOTHING;")
    a("")
    total = sum(len(grants.get(r["code"]) or []) for r in roles)
    a(f"-- 4. Контроль: все {len(roles)} ролей, {len(perms)} кодов и {total} пар матрицы присутствуют (опечатка в коде")
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
    a(",\n".join(f"    ({sq(r['code'])}, {sq(c)})" for r in roles for c in grants.get(r["code"]) or []))
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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--check", action="store_true", help="сравнить с файлом на диске (код 1 при расхождении)")
    g.add_argument("--stdout", action="store_true", help="напечатать SQL вместо записи")
    args = ap.parse_args()
    try:
        out = render(load(SRC))
    except SpecError as e:
        print(f"ERROR: permissions.yaml нарушает инварианты:\n{e}", file=sys.stderr)
        return 1
    rel = DST.relative_to(ROOT).as_posix()
    if args.stdout:
        sys.stdout.buffer.write(out.encode("utf-8"))
        return 0
    if args.check:
        cur = DST.read_text(encoding="utf-8") if DST.is_file() else ""
        if cur == out:
            print(f"OK: {rel} совпадает с генерацией из contracts/rbac/permissions.yaml ({len(out.encode('utf-8'))} байт)")
            return 0
        diff = list(difflib.unified_diff(cur.splitlines(), out.splitlines(), "на диске", "генерация", lineterm="", n=1))
        print(f"DRIFT: {rel} отличается от генерации ({len(diff)} строк diff); первые 40:", file=sys.stderr)
        print("\n".join(diff[:40]), file=sys.stderr)
        print("Исправление: python -I -X utf8 scripts/gen_rbac_seed.py (правка — только в permissions.yaml)", file=sys.stderr)
        return 1
    DST.write_bytes(out.encode("utf-8"))
    print(f"OK: записан {rel} ({len(out.encode('utf-8'))} байт)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
