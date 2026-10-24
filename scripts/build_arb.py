#!/usr/bin/env python3
"""RM-B-007: сборка словаря строк UI (ARB) из markdown-таблиц ТЗ.

Источники (владельцы — ядро R0 §19.1, §18.1):
  * 02_SCREEN_SPECIFICATION.md §7 «Сводный словарь строк UI» — экранные строки
    (таблица «Ключ ARB | Русский текст | Экран | Примечание»);
  * 03_UX_UI_DESIGN_SYSTEM.md §16 — правила ARB и общие ключи: пары `ключ` «текст»
    в §16.2 и §16.5, коды ошибок `CODE` («текст») в §16.5 (→ `error_<code>`), таблица
    плюрализации §16.3; ключи `auth_error_*` из §13.3, на который ссылается §16.5;
  * 07_DATA_MODEL.md §5.4 `roles.name_ru` — тексты ключей `role_<code>`, которых нет в 03 (B-AR-11).
    При конфликте имени ключа приоритет у 03 (ядро §19.1), кроме явных исключений
    `KERNEL_OVERRIDES` (текст 03 противоречит более позднему решению ядра).

Результат: contracts/l10n/app_ru.arb (шаблон, `@key.description` + `placeholders`),
app_ky.arb и app_en.arb — каркас с теми же ключами и плейсхолдерами; значение — копия
русского текста, в description пометка «TODO перевод» (D-38, Q-007).

Запуск:  python -I -X utf8 scripts/build_arb.py [--root D:/optomstroy] [--check] [--report]
  --check   ничего не пишет; код выхода 1, если файлы на диске отличаются от сборки;
  --report  печатает подробный журнал решений (конфликты, пропуски, преобразования).
Код выхода: 0 — успех; 1 — расхождение (--check) или ошибка разбора; 2 — нет входных файлов.
Вывод детерминирован (ключи отсортированы, без меток времени). Сетевых запросов нет.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

LOCALES = ("ru", "ky", "en")
INT_PLACEHOLDERS = {"count", "n", "seconds", "minutes"}  # 02 §7 преамбула: int; прочие — String
TODO_PREFIX = "TODO перевод: значение — копия ru (каркас D-38, Q-007). "
GENERATED_BY = "scripts/build_arb.py (RM-B-007) из 02 §7 и 03 §16; файл не редактировать вручную"

# Шаблон `sync_entity_<code>` 02 §7 (SCR-43/44): «17 значений `sync_entity` (ядро §6, §17.3)».
# Текст ячейки перечисляет 17 подписей; код enum сопоставлен по смыслу. Набор кодов
# сверяется с ядром при сборке (см. load_sync_entity_enum).
SYNC_ENTITY_LABELS = {
    "Остатки": "stock",
    "Цены": "prices",
    "Статусы заказов": "order_status",
    "Товары": "products",
    "Варианты": "variants",
    "Категории": "categories",
    "Штрихкоды": "barcodes",
    "Единицы": "units",
    "Склады": "warehouses",
    "Клиенты": "customers",
    "Долги": "receivables",
    "Скидки": "discounts",
    "История продаж": "sales_history",
    "Платёжные документы": "payment_docs",
    "Документы возвратов": "return_docs",
    "Характеристики": "attributes",
    "Фото": "images",
}

# Исключения из правила «приоритет 03»: текст 03 устарел относительно решения ядра,
# с которым выровнен текст 02 §7. Ключ → обоснование.
KERNEL_OVERRIDES = {
    "ds_onec_down": "ядро §22.4: при недоступности 1С продажа в долг разрешена по свежему полному "
                    "снимку долга; текст 03 §16.5 «продажа в долг недоступна» противоречит ядру, "
                    "текст 02 §7 (ссылка на ядро §22.4 в 02 SCR-90) выровнен с ним",
    "error_qr_unavailable": "ядро v1.9 §24.4: в R1 основной вариант QR_PROVIDER=onec — QR формирует 1С, а не банк; "
                            "текст 03 §16.5 «Банк недоступен» неверен для этого варианта, нейтральный текст 02 §7 "
                            "подходит для onec и bakai (B-AR-11, docs/reviews/B_architecture_review.md)",
}

# Названия ролей `role_<code>` (03 §16.5: 7 ключей, правило 03 §16.2 «Роли — role_<code>»): текст 03 задан только
# для role_senior_seller; остальные берутся из словаря ролей 07 §5.4 (`roles.name_ru`, тот же текст, что seed
# 0002_rbac_seed.sql) — это данные справочника, а не новый текст (B-AR-11).
ROLE_NAMES_SOURCE = "07 §5.4 roles.name_ru"

# Полная форма `unit_pcs_full` 03 §16.3 задана без `other` и без обёртки аргумента;
# ICU требует `other` — по образцу всех строк 03 §16.3 other = форма few.
UNIT_PCS_FULL_OTHER = "few"


def _load_checker():
    sys.dont_write_bytecode = True  # не оставлять __pycache__ рядом со скриптами
    path = Path(__file__).resolve().with_name("check_arb_keys.py")
    spec = importlib.util.spec_from_file_location("check_arb_keys", path)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


CHECK = _load_checker()


# ------------------------------------------------------------------ разбор md


def section(text: str, start_re: str, end_re: str = r"^#{2,3} ") -> str:
    m = re.search(start_re, text, re.M)
    if not m:
        raise LookupError(f"раздел не найден: {start_re}")
    rest = text[m.end():]
    e = re.search(end_re, rest, re.M)
    return rest[: e.start()] if e else rest


def split_row(line: str) -> list[str]:
    cells = re.split(r"(?<!\\)\|", line.strip())
    return [c.strip().replace("\\|", "|") for c in cells[1:-1]]


def parse_md_table(sec: str, header: list[str]) -> list[tuple[int, list[str]]]:
    lines = sec.split("\n")
    for i, ln in enumerate(lines):
        if ln.startswith("|") and split_row(ln) == header:
            break
    else:
        raise LookupError(f"таблица с заголовком {header} не найдена")
    rows: list[tuple[int, list[str]]] = []
    for j in range(i + 2, len(lines)):
        ln = lines[j]
        if not ln.startswith("|"):
            break
        cells = split_row(ln)
        if len(cells) != len(header):
            raise ValueError(f"строка таблицы {j - i}: {len(cells)} ячеек вместо {len(header)}: {ln[:120]}")
        rows.append((j - i - 1, cells))
    return rows


GUILLEMET = r"«((?:[^«»]|«[^«»]*»)*)»"
PAIR_RE = re.compile(r"`([a-z][a-z0-9_]*)` " + GUILLEMET)
CODE_PAIR_RE = re.compile(r"`([A-Z][A-Z0-9_]+)` \(" + GUILLEMET)
KEY_CELL_RE = re.compile(r"^`([a-z0-9_<>]+)`$")
TRAILING_NOTE_RE = re.compile(r"\s*\(([^()]*`[^()]*)\)\s*$")
THREE_FORMS_RE = re.compile(
    r"^(?P<pre>.*?)\{(?P<v>[A-Za-z_]\w*)\} (?P<a>[^\s/{}]+) / (?P<b>[^\s/{}]+) / (?P<c>[^\s/{}]+)(?P<post>.*)$")


class Entry:
    __slots__ = ("key", "text", "desc", "source")

    def __init__(self, key: str, text: str, desc: str, source: str):
        self.key, self.text, self.desc, self.source = key, text, desc, source


def three_forms_to_icu(text: str) -> str | None:
    """«… {count} товар / товара / товаров …» → ICU plural (one/few/many, other = few, как в 03 §16.3)."""
    m = THREE_FORMS_RE.match(text)
    if not m:
        return None
    pre, v, post = m.group("pre"), m.group("v"), m.group("post")
    if "{" in pre and "plural" in pre:
        return None

    def br(word: str) -> str:
        return f"{pre}{{{v}}} {word}{post}"

    a, b, c = m.group("a"), m.group("b"), m.group("c")
    return f"{{{v}, plural, one{{{br(a)}}} few{{{br(b)}}} many{{{br(c)}}} other{{{br(b)}}}}}"


def load_sync_entity_enum(kernel: str) -> set[str]:
    m = re.search(r"^- `sync_entity`: `([^\n]*)`$", kernel, re.M)
    if not m:
        raise LookupError("ядро §6: перечень sync_entity")
    codes = {c.strip() for c in m.group(1).split("|")}
    m2 = re.search(r"`sync_entity` \+ ((?:`[a-z_]+`(?:, )?)+)", kernel)
    if m2:
        codes |= set(re.findall(r"`([a-z_]+)`", m2.group(1)))
    return codes


def collect(root: Path, log: list[str]) -> dict[str, Entry]:
    spec = root / "docs" / "specification"
    t02 = (spec / "02_SCREEN_SPECIFICATION.md").read_text(encoding="utf-8")
    t03 = (spec / "03_UX_UI_DESIGN_SYSTEM.md").read_text(encoding="utf-8")
    kernel = (root / "docs" / "research" / "R0_DECISION_KERNEL.md").read_text(encoding="utf-8")

    entries: dict[str, Entry] = {}

    # ---- 02 §7
    s7 = section(t02, r"^## 7\. Сводный словарь строк UI", r"^## ")
    rows = parse_md_table(s7, ["Ключ ARB", "Русский текст", "Экран", "Примечание"])
    log.append(f"02 §7: строк таблицы {len(rows)}")
    n_templates = n_plural3 = n_notes = 0
    sync_codes = load_sync_entity_enum(kernel)
    for _, (kcell, text, screen, note) in rows:
        km = KEY_CELL_RE.match(kcell)
        if not km:
            raise ValueError(f"02 §7: ячейка ключа не распознана: {kcell!r}")
        key = km.group(1)
        desc_base = f"Экран: {screen}. {note}. Источник: 02 §7"
        if "<" in key:
            n_templates += 1
            if key == "sync_entity_<code>":
                labels = [x.strip() for x in text.split(",")]
                if set(labels) != set(SYNC_ENTITY_LABELS) or len(labels) != len(SYNC_ENTITY_LABELS):
                    raise ValueError("02 §7 sync_entity_<code>: подписи не совпадают с SYNC_ENTITY_LABELS")
                if set(SYNC_ENTITY_LABELS.values()) != sync_codes:
                    raise ValueError(f"sync_entity: коды сопоставления ≠ ядро §6/§17.3: {sorted(sync_codes)}")
                for lab in labels:
                    code = SYNC_ENTITY_LABELS[lab]
                    k = f"sync_entity_{code}"
                    entries[k] = Entry(k, lab, f"Экран: {screen}. Подпись сущности синхронизации, "
                                       f"enum sync_entity = `{code}` (ядро §6, §17.3); развёрнуто из шаблона "
                                       f"`sync_entity_<code>`. {note}. Источник: 02 §7", "02")
                log.append(f"шаблон {key}: развёрнут в {len(labels)} ключей по enum ядра")
            else:
                log.append(f"шаблон {key}: пропущен — конкретные имена/тексты в 02 §7 не заданы ({text[:60]})")
            continue
        m = TRAILING_NOTE_RE.search(text)
        if m:
            n_notes += 1
            desc_base = f"Экран: {screen}. {note}; примечание к тексту: {m.group(1)}. Источник: 02 §7"
            log.append(f"{key}: служебное примечание из текста перенесено в description: ({m.group(1)})")
            text = text[: m.start()]
        icu = three_forms_to_icu(text)
        if icu is not None:
            n_plural3 += 1
            log.append(f"{key}: формы «{text}» → ICU plural")
            desc_base += "; формы «a / b / c» 02 §7 преобразованы в ICU plural (03 §16.3)"
            text = icu
        if key in entries:
            raise ValueError(f"02 §7: дубль ключа {key}")
        entries[key] = Entry(key, text, desc_base, "02")
    log.append(f"02 §7: шаблонов {n_templates}, примечаний из текста {n_notes}, 3-формных плюралей {n_plural3}")

    # ---- 03 (§16.2, §16.5 пары; §16.5 коды ошибок; §16.3 плюрали; §13.3 auth_error_*)
    found03: list[tuple[str, str, str]] = []  # (key, text, where)
    s162 = section(t03, r"^### 16\.2\.")
    s163 = section(t03, r"^### 16\.3\.")
    s165 = section(t03, r"^### 16\.5\.")
    s133 = section(t03, r"^### 13\.3\.")
    for k, t in PAIR_RE.findall(s162):
        found03.append((k, t, "03 §16.2"))
    for k, t in PAIR_RE.findall(s165):
        found03.append((k, t, "03 §16.5"))
    for code, t in CODE_PAIR_RE.findall(s165):
        found03.append(("error_" + code.lower(), t, f"03 §16.5 (код {code})"))
    for k, t in PAIR_RE.findall(s133):
        if k.startswith("auth_error_"):
            found03.append((k, t, "03 §13.3"))
    for ln in s163.split("\n"):
        if not ln.startswith("| `"):
            continue
        k_cell, v_cell = split_row(ln)[:2]
        k = k_cell.strip("`")
        vm = re.match(r"`([^`]*)`(.*)$", v_cell)
        if not vm:
            raise ValueError(f"03 §16.3: значение не распознано: {v_cell}")
        found03.append((k, vm.group(1), "03 §16.3" + (f"; {vm.group(2).strip(' —')}" if vm.group(2).strip() else "")))
        fm = re.search(r"полная форма — `([a-z0-9_]+)`: `([^`]*)`", v_cell)
        if fm:
            forms = dict(re.findall(r"(one|few|many|other)\{([^{}]*)\}", fm.group(2)))
            if "other" not in forms:
                forms["other"] = forms[UNIT_PCS_FULL_OTHER]
                log.append(f"{fm.group(1)}: в 03 §16.3 нет варианта other — добавлен other = {UNIT_PCS_FULL_OTHER} "
                           f"(обязателен в ICU)")
            body = " ".join(f"{c}{{{forms[c]}}}" for c in ("one", "few", "many", "other") if c in forms)
            found03.append((fm.group(1), f"{{count, plural, {body}}}",
                            "03 §16.3; полная форма для screen reader; other добавлен сборкой (ICU)"))

    seen03: dict[str, tuple[str, str]] = {}
    for k, t, where in found03:
        if k in seen03:
            if seen03[k][0] != t:
                raise ValueError(f"03: ключ {k} с разными текстами: «{seen03[k][0]}» ({seen03[k][1]}) / «{t}» ({where})")
            continue
        seen03[k] = (t, where)
    log.append(f"03 §16/§13.3: ключей с текстом {len(seen03)}")

    n_same = n_conflict = n_new = 0
    for k in sorted(seen03):
        t, where = seen03[k]
        if k in entries:
            e = entries[k]
            if e.text == t:
                n_same += 1
                e.desc += f"; текст совпадает с {where}"
                continue
            if k in KERNEL_OVERRIDES:
                log.append(f"КОНФЛИКТ {k}: оставлен текст 02 «{e.text}» вместо {where} «{t}» — {KERNEL_OVERRIDES[k]}")
                e.desc += f"; текст 02 оставлен вместо {where} «{t}»: {KERNEL_OVERRIDES[k]}"
                n_conflict += 1
                continue
            n_conflict += 1
            log.append(f"КОНФЛИКТ {k}: 02 «{e.text}» → {where} «{t}» (приоритет 03, ядро §19.1)")
            e.desc += f"; текст из {where} (приоритет 03, ядро §19.1), в 02 §7 было «{e.text}»"
            e.text, e.source = t, "03"
        else:
            n_new += 1
            entries[k] = Entry(k, t, f"Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: {where}", "03")
    log.append(f"03 → ARB: совпало с 02 {n_same}, конфликтов {n_conflict}, новых ключей {n_new}")

    # ---- role_<code> из 07 §5.4 (B-AR-11)
    t07 = (spec / "07_DATA_MODEL.md").read_text(encoding="utf-8")
    s54 = section(t07, r"^#### 5\.4\. `roles`", r"^#### ")
    code_row = next((ln for ln in s54.splitlines() if ln.startswith("| code |")), None)
    name_row = next((ln for ln in s54.splitlines() if ln.startswith("| name_ru |")), None)
    if code_row is None or name_row is None:
        raise LookupError("07 §5.4: нет строк code/name_ru таблицы roles")
    codes = re.findall(r"[a-z_]+", split_row(code_row)[4].replace("\\|", " "))
    names = re.findall(r"«([^»]+)»", split_row(name_row)[4])
    if len(codes) != len(names) or not codes:
        raise LookupError(f"07 §5.4: кодов ролей {len(codes)}, названий {len(names)}")
    n_roles = 0
    for code, name in zip(codes, names):
        k = f"role_{code}"
        if k in entries:
            if entries[k].text != name:
                log.append(f"КОНФЛИКТ {k}: оставлен текст {entries[k].source} «{entries[k].text}», в {ROLE_NAMES_SOURCE} «{name}»")
            continue
        entries[k] = Entry(k, name, f"Название роли (общий ключ 03 §16.5, правило 03 §16.2 role_<code>). "
                                    f"Текст — {ROLE_NAMES_SOURCE} (B-AR-11)", "07")
        n_roles += 1
    log.append(f"07 §5.4 → ARB: ключей role_* добавлено {n_roles}")
    return entries


# ------------------------------------------------------------------ сборка ARB


def placeholders_for(key: str, text: str) -> dict[str, dict[str, str]]:
    try:
        args = CHECK.parse_icu(text)
    except CHECK.IcuError as e:
        raise ValueError(f"{key}: некорректный ICU «{text}»: {e}") from e
    out: dict[str, dict[str, str]] = {}
    for name in sorted(args):
        typ = "int" if (name in INT_PLACEHOLDERS or "plural" in args[name]) else "String"
        out[name] = {"type": typ}
    return out


def build(entries: dict[str, Entry]) -> dict[str, str]:
    docs: dict[str, dict] = {loc: {"@@locale": loc, "@@x-generated-by": GENERATED_BY} for loc in LOCALES}
    for k in sorted(entries):
        e = entries[k]
        ph = placeholders_for(k, e.text)
        meta = {"description": e.desc}
        if ph:
            meta["placeholders"] = ph
        docs["ru"][k] = e.text
        docs["ru"]["@" + k] = meta
        for loc in ("ky", "en"):
            m2 = {"description": TODO_PREFIX + e.desc}
            if ph:
                m2["placeholders"] = json.loads(json.dumps(ph))
            docs[loc][k] = e.text
            docs[loc]["@" + k] = m2
    return {loc: json.dumps(docs[loc], ensure_ascii=False, indent=2) + "\n" for loc in LOCALES}


def main(argv: list[str] | None = None) -> int:
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser(description="RM-B-007: сборка ARB из 02 §7 и 03 §16")
    ap.add_argument("--root", type=Path, default=here.parent)
    ap.add_argument("--out", type=Path, default=None, help="каталог ARB (по умолчанию <root>/contracts/l10n)")
    ap.add_argument("--check", action="store_true", help="сравнить с файлами на диске, не записывая")
    ap.add_argument("--report", action="store_true", help="печатать журнал решений полностью")
    a = ap.parse_args(argv)
    out = a.out or (a.root / "contracts" / "l10n")
    log: list[str] = []
    try:
        entries = collect(a.root, log)
        texts = build(entries)
    except FileNotFoundError as e:
        print(f"ОШИБКА: нет входного файла: {e}")
        return 2
    except (LookupError, ValueError) as e:
        print(f"ОШИБКА разбора: {e}")
        return 1

    summary = [ln for ln in log if not ln.startswith(("КОНФЛИКТ", "шаблон")) and ": формы" not in ln
               and "служебное примечание" not in ln]
    for ln in (log if a.report else summary):
        print(ln)
    for ln in log:
        if not a.report and (ln.startswith(("КОНФЛИКТ", "шаблон"))):
            print(ln)
    n02 = sum(1 for e in entries.values() if e.source == "02")
    n03 = sum(1 for e in entries.values() if e.source == "03")
    n07 = sum(1 for e in entries.values() if e.source == "07")
    print(f"итог: ключей {len(entries)} (текст 02 §7: {n02}, текст 03: {n03}, названия ролей 07 §5.4: {n07})")

    if a.check:
        diff = []
        for loc in LOCALES:
            p = out / f"app_{loc}.arb"
            cur = p.read_text(encoding="utf-8") if p.is_file() else None
            if cur != texts[loc]:
                diff.append(p.name)
        if diff:
            print("РАСХОЖДЕНИЕ с файлами на диске: " + ", ".join(diff))
            return 1
        print("--check: файлы на диске совпадают со сборкой")
        return 0
    out.mkdir(parents=True, exist_ok=True)
    for loc in LOCALES:
        (out / f"app_{loc}.arb").write_text(texts[loc], encoding="utf-8", newline="\n")
        print(f"записан {out / f'app_{loc}.arb'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
