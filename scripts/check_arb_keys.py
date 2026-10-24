#!/usr/bin/env python3
"""RM-B-007: проверка словаря строк UI (ARB) contracts/l10n/app_{ru,ky,en}.arb.

Проверки (13_IMPLEMENTATION_ROADMAP §3.2, строка RM-B-007; 03 §16.2; 12 T-DS-080):
  1. каждый ARB — валидный JSON (UTF-8, объект верхнего уровня), без дублей имён ключей;
  2. `@@locale` совпадает с суффиксом имени файла;
  3. ключ сообщения — `snake_case`; у каждого ключа есть `@key` с непустым `description`;
     нет «висячих» `@key` без сообщения;
  4. каждый ключ имеет префикс экрана/области из 02 §7 (строка «Распределение ключей по
     префиксам») или общий префикс 03 §16.5 (`ds_*`, `error_*`, `warning_*`, `status_*`,
     `payment_review_*`, `sync_error_*`, `role_*`, `auth_error_*`), либо является общим
     ключом плюрализации из таблицы 03 §16.3;
  5. корректный ICU-синтаксис значения (сбалансированные фигурные скобки, аргументы
     `{name}`, `{name, plural, ...}` и `{name, select, ...}` с вариантом `other`;
     экранирование апострофом по `use-escaping: true`, 03 §16.1);
  6. набор плейсхолдеров в значении совпадает с `@key.placeholders`; тип допустим;
     переменная plural имеет тип int/num;
  7. наборы ключей и плейсхолдеров (имена и типы) `ky`/`en` совпадают с `ru`.

Дополнительно печатается информационный отчёт покрытия обязательных общих ключей 03
(`status_*` по таблице 03 §9.39, числа ключей `error_*` и `role_*` по 03 §16.5); по
умолчанию он не влияет на код выхода (`--strict-coverage` — влияет).

Запуск:  python -I -X utf8 scripts/check_arb_keys.py [--root D:/optomstroy]
         python -I -X utf8 scripts/check_arb_keys.py --self-test
Код выхода: 0 — ошибок нет; 1 — найдены ошибки; 2 — не найдены входные файлы/разделы ТЗ.
Сетевых запросов нет; вывод детерминирован.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

LOCALES = ("ru", "ky", "en")
TEMPLATE_LOCALE = "ru"
KEY_RE = re.compile(r"^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$")
IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
PLURAL_SELECTORS = {"zero", "one", "two", "few", "many", "other"}
PLACEHOLDER_TYPES = {"String", "int", "num", "double", "DateTime", "Object"}
NUMERIC_TYPES = {"int", "num", "double"}


# --------------------------------------------------------------------------- ICU


class IcuError(ValueError):
    pass


class _IcuParser:
    """Минимальный парсер сообщений ICU в объёме Flutter gen-l10n (use-escaping: true).

    Поддерживается: текст, `{name}`, `{name, plural, sel{...} ...}`,
    `{name, select, sel{...} ...}`, экранирование `'...'` и `''`.
    Результат — словарь {имя аргумента: множество видов ('simple'|'plural'|'select')}.
    """

    def __init__(self, text: str):
        self.s = text
        self.i = 0
        self.args: dict[str, set[str]] = {}

    def error(self, msg: str) -> IcuError:
        return IcuError(f"{msg} (позиция {self.i}: …{self.s[max(0, self.i - 15):self.i + 15]!r}…)")

    def parse(self) -> dict[str, set[str]]:
        self._message(depth=0)
        if self.i != len(self.s):
            raise self.error("лишняя закрывающая '}'")
        return self.args

    def _message(self, depth: int) -> None:
        s = self.s
        while self.i < len(s):
            ch = s[self.i]
            if ch == "'":
                # '' — литеральный апостроф; '...' — экранированный фрагмент
                if self.i + 1 < len(s) and s[self.i + 1] == "'":
                    self.i += 2
                    continue
                end = s.find("'", self.i + 1)
                if end < 0:
                    raise self.error("незакрытый экранирующий апостроф")
                self.i = end + 1
                continue
            if ch == "{":
                self._argument()
                continue
            if ch == "}":
                if depth == 0:
                    raise self.error("лишняя закрывающая '}'")
                return
            self.i += 1
        if depth > 0:
            raise self.error("не закрыта '{'")

    def _ws(self) -> None:
        while self.i < len(self.s) and self.s[self.i] in " \t\r\n":
            self.i += 1

    def _ident(self, what: str) -> str:
        m = IDENT_RE.match(self.s, self.i)
        if not m:
            raise self.error(f"ожидался {what}")
        self.i = m.end()
        return m.group(0)

    def _expect(self, ch: str) -> None:
        if self.i >= len(self.s) or self.s[self.i] != ch:
            raise self.error(f"ожидался символ {ch!r}")
        self.i += 1

    def _argument(self) -> None:
        self._expect("{")
        self._ws()
        name = self._ident("идентификатор аргумента")
        self._ws()
        if self.i < len(self.s) and self.s[self.i] == "}":
            self.i += 1
            self.args.setdefault(name, set()).add("simple")
            return
        self._expect(",")
        self._ws()
        kind = self._ident("тип аргумента (plural|select)")
        if kind not in ("plural", "select"):
            raise self.error(f"неподдерживаемый тип аргумента {kind!r}")
        self._ws()
        self._expect(",")
        selectors: list[str] = []
        while True:
            self._ws()
            if self.i >= len(self.s):
                raise self.error(f"не закрыт аргумент {kind} '{name}'")
            if self.s[self.i] == "}":
                self.i += 1
                break
            if self.s[self.i] == "=":
                self.i += 1
                m = re.compile(r"\d+").match(self.s, self.i)
                if not m:
                    raise self.error("после '=' ожидается число")
                self.i = m.end()
                sel = "=" + m.group(0)
                if kind == "select":
                    raise self.error("селектор '=N' недопустим в select")
            else:
                sel = self._ident("селектор варианта")
                if kind == "plural" and sel not in PLURAL_SELECTORS:
                    raise self.error(f"недопустимая категория plural {sel!r}")
            if sel in selectors:
                raise self.error(f"повтор варианта {sel!r} в '{name}'")
            selectors.append(sel)
            self._ws()
            self._expect("{")
            self._message(depth=1)
            self._expect("}")
        if not selectors:
            raise self.error(f"у {kind} '{name}' нет вариантов")
        if "other" not in selectors:
            raise self.error(f"у {kind} '{name}' нет обязательного варианта 'other'")
        self.args.setdefault(name, set()).add(kind)


def parse_icu(text: str) -> dict[str, set[str]]:
    """Разбирает сообщение ICU; возвращает {аргумент: виды}. Бросает IcuError."""
    if not isinstance(text, str):
        raise IcuError("значение не строка")
    return _IcuParser(text).parse()


# ---------------------------------------------------------------- источники ТЗ


def _section(text: str, start_re: str, end_re: str) -> str:
    m = re.search(start_re, text, re.M)
    if not m:
        raise LookupError(start_re)
    rest = text[m.end():]
    e = re.search(end_re, rest, re.M)
    return rest[: e.start()] if e else rest


def load_allowed_prefixes(spec_dir: Path) -> tuple[set[str], set[str], set[str]]:
    """Возвращает (префиксы 02 §7, общие префиксы 03 §16.5, ключи таблицы 03 §16.3)."""
    t02 = (spec_dir / "02_SCREEN_SPECIFICATION.md").read_text(encoding="utf-8")
    t03 = (spec_dir / "03_UX_UI_DESIGN_SYSTEM.md").read_text(encoding="utf-8")
    s7 = _section(t02, r"^## 7\. Сводный словарь строк UI", r"^## ")
    m = re.search(r"Распределение ключей по префиксам[^:]*\):(.*)", s7)
    if not m:
        raise LookupError("02 §7: строка «Распределение ключей по префиксам»")
    screen = set(re.findall(r"`([a-z0-9]+_)` — \d+", m.group(1)))
    if not screen:
        raise LookupError("02 §7: префиксы не распознаны")
    s165 = _section(t03, r"^### 16\.5\.", r"^### ")
    m = re.search(r"Владелец правил и ключей ARB \(([^)]*)\)", s165)
    if not m:
        raise LookupError("03 §16.5: перечень «Владелец правил и ключей ARB»")
    common = {p[:-1] for p in re.findall(r"`([a-z_]+_\*)`", m.group(1))}
    s163 = _section(t03, r"^### 16\.3\.", r"^### ")
    plural_keys = set(re.findall(r"^\| `([a-z0-9_]+)` \|", s163, re.M))
    plural_keys |= set(re.findall(r"полная форма — `([a-z0-9_]+)`", s163))
    return screen, common, plural_keys


def load_status_keys_03(spec_dir: Path) -> list[str]:
    t03 = (spec_dir / "03_UX_UI_DESIGN_SYSTEM.md").read_text(encoding="utf-8")
    s = _section(t03, r"^### 9\.39\.", r"^### ")
    keys: list[str] = []
    for k in re.findall(r"`(status_[a-z0-9_]+)`", s):
        if k not in keys:
            keys.append(k)
    return keys


def expected_counts_03(spec_dir: Path) -> dict[str, int]:
    t03 = (spec_dir / "03_UX_UI_DESIGN_SYSTEM.md").read_text(encoding="utf-8")
    s165 = _section(t03, r"^### 16\.5\.", r"^### ")
    out: dict[str, int] = {}
    m = re.search(r"всего (\d+) ключей", s165)
    if m:
        out["error_"] = int(m.group(1))
    m = re.search(r"`role_\*` \((\d+)\)", s165)
    if m:
        out["role_"] = int(m.group(1))
    return out


# -------------------------------------------------------------------- проверки


def _load_json_no_dupes(path: Path, errors: list[str]) -> dict | None:
    dupes: list[str] = []

    def hook(pairs):
        seen: dict = {}
        for k, v in pairs:
            if k in seen:
                dupes.append(k)
            seen[k] = v
        return seen

    try:
        raw = path.read_bytes()
        text = raw.decode("utf-8")
    except (OSError, UnicodeDecodeError) as e:
        errors.append(f"{path.name}: не прочитан как UTF-8: {e}")
        return None
    if text.startswith("\ufeff"):
        errors.append(f"{path.name}: BOM недопустим")
        text = text[1:]
    try:
        data = json.loads(text, object_pairs_hook=hook)
    except json.JSONDecodeError as e:
        errors.append(f"{path.name}: невалидный JSON: {e}")
        return None
    if not isinstance(data, dict):
        errors.append(f"{path.name}: верхний уровень — не объект")
        return None
    for d in sorted(set(dupes)):
        errors.append(f"{path.name}: дубль ключа {d!r}")
    return data


def check_locale_file(name: str, data: dict, locale: str, allowed: tuple[set[str], set[str], set[str]] | None,
                      errors: list[str]) -> dict[str, dict[str, str]]:
    """Проверяет один ARB; возвращает {ключ: {плейсхолдер: тип}}."""
    result: dict[str, dict[str, str]] = {}
    if data.get("@@locale") != locale:
        errors.append(f"{name}: @@locale={data.get('@@locale')!r}, ожидается {locale!r}")
    screen, common, plural_keys = allowed if allowed else (set(), set(), set())
    msg_keys = [k for k in data if not k.startswith("@")]
    meta_keys = [k for k in data if k.startswith("@") and not k.startswith("@@")]
    for mk in meta_keys:
        if mk[1:] not in data:
            errors.append(f"{name}: метаданные {mk!r} без сообщения")
    for k in msg_keys:
        v = data[k]
        if not KEY_RE.match(k):
            errors.append(f"{name}: ключ {k!r} не snake_case")
        if allowed is not None:
            ok = (any(k.startswith(p) for p in screen) or any(k.startswith(p) for p in common)
                  or k in plural_keys)
            if not ok:
                errors.append(f"{name}: ключ {k!r} без префикса экрана (02 §7) или общего префикса (03 §16)")
        meta = data.get("@" + k)
        if not isinstance(meta, dict):
            errors.append(f"{name}: у ключа {k!r} нет объекта '@{k}'")
            meta = {}
        desc = meta.get("description")
        if not isinstance(desc, str) or not desc.strip():
            errors.append(f"{name}: у ключа {k!r} нет description")
        if not isinstance(v, str):
            errors.append(f"{name}: значение {k!r} — не строка")
            continue
        if not v.strip():
            errors.append(f"{name}: пустое значение {k!r}")
        try:
            args = parse_icu(v)
        except IcuError as e:
            errors.append(f"{name}: {k}: ошибка ICU: {e}")
            args = None
        ph = meta.get("placeholders", {})
        if not isinstance(ph, dict):
            errors.append(f"{name}: {k}: placeholders — не объект")
            ph = {}
        types: dict[str, str] = {}
        for pn, pv in ph.items():
            if not IDENT_RE.fullmatch(pn):
                errors.append(f"{name}: {k}: недопустимое имя плейсхолдера {pn!r}")
            t = pv.get("type") if isinstance(pv, dict) else None
            if t not in PLACEHOLDER_TYPES:
                errors.append(f"{name}: {k}: плейсхолдер {pn!r} — недопустимый тип {t!r}")
            types[pn] = t if isinstance(t, str) else "?"
        if args is not None:
            used, declared = set(args), set(types)
            for pn in sorted(used - declared):
                errors.append(f"{name}: {k}: плейсхолдер {{{pn}}} не описан в @{k}.placeholders")
            for pn in sorted(declared - used):
                errors.append(f"{name}: {k}: плейсхолдер {pn!r} описан, но не используется в значении")
            for pn, kinds in args.items():
                if "plural" in kinds and types.get(pn) not in NUMERIC_TYPES:
                    errors.append(f"{name}: {k}: переменная plural {pn!r} должна быть int/num, а не {types.get(pn)!r}")
        result[k] = types
    return result


def run_checks(l10n_dir: Path, spec_dir: Path | None, strict_coverage: bool) -> int:
    errors: list[str] = []
    allowed = None
    if spec_dir is not None:
        try:
            allowed = load_allowed_prefixes(spec_dir)
        except (OSError, LookupError) as e:
            print(f"ОШИБКА: не прочитаны разделы ТЗ для префиксов: {e}")
            return 2
    parsed: dict[str, dict[str, dict[str, str]]] = {}
    raw: dict[str, dict] = {}
    for loc in LOCALES:
        p = l10n_dir / f"app_{loc}.arb"
        if not p.is_file():
            print(f"ОШИБКА: нет файла {p}")
            return 2
        data = _load_json_no_dupes(p, errors)
        if data is None:
            continue
        raw[loc] = data
        parsed[loc] = check_locale_file(p.name, data, loc, allowed, errors)

    if TEMPLATE_LOCALE in parsed:
        base = parsed[TEMPLATE_LOCALE]
        for loc in LOCALES:
            if loc == TEMPLATE_LOCALE or loc not in parsed:
                continue
            other = parsed[loc]
            for k in sorted(set(base) - set(other)):
                errors.append(f"app_{loc}.arb: нет ключа {k!r} из app_ru.arb")
            for k in sorted(set(other) - set(base)):
                errors.append(f"app_{loc}.arb: лишний ключ {k!r} (нет в app_ru.arb)")
            for k in sorted(set(base) & set(other)):
                if base[k] != other[k]:
                    errors.append(f"app_{loc}.arb: {k}: плейсхолдеры {other[k]} ≠ ru {base[k]}")

    # --- отчёт
    print("== check_arb_keys: RM-B-007")
    for loc in LOCALES:
        if loc in parsed:
            n_ph = sum(1 for v in parsed[loc].values() if v)
            print(f"app_{loc}.arb: ключей {len(parsed[loc])}, с плейсхолдерами {n_ph}")
    if TEMPLATE_LOCALE in parsed:
        prefixes: dict[str, int] = {}
        for k in parsed[TEMPLATE_LOCALE]:
            p = k.split("_", 1)[0] + "_"
            prefixes[p] = prefixes.get(p, 0) + 1
        print("префиксы ru: " + ", ".join(f"{p} {n}" for p, n in sorted(prefixes.items())))
        n_plural = sum(1 for v in raw[TEMPLATE_LOCALE].values() if isinstance(v, str) and ", plural," in v)
        print(f"сообщений с ICU plural: {n_plural}")

    cov_problems: list[str] = []
    if spec_dir is not None and TEMPLATE_LOCALE in parsed:
        keys = set(parsed[TEMPLATE_LOCALE])
        try:
            st = load_status_keys_03(spec_dir)
            exp = expected_counts_03(spec_dir)
        except (OSError, LookupError):
            st, exp = [], {}
        missing_st = [k for k in st if k not in keys]
        print(f"покрытие status_* (03 §9.39): {len(st) - len(missing_st)}/{len(st)}")
        if missing_st:
            cov_problems.append("нет строк status_* по 03 §9.39: " + ", ".join(missing_st))
        for pref, n in sorted(exp.items()):
            have = sum(1 for k in keys if k.startswith(pref)) if pref != "role_" else sum(
                1 for k in keys if k.startswith("role_") and not k.endswith("_summary"))
            print(f"покрытие {pref}* (03 §16.5): {have}/{n}")
            if have < n:
                cov_problems.append(f"{pref}*: {have} из {n} по 03 §16.5")
        for c in cov_problems:
            print(f"ПОКРЫТИЕ (инфо): {c}")

    if strict_coverage:
        errors.extend(f"покрытие: {c}" for c in cov_problems)
    for e in errors:
        print(f"ОШИБКА: {e}")
    print(f"итог: ошибок {len(errors)}")
    return 1 if errors else 0


# ------------------------------------------------------------------ self-test


def self_test() -> int:
    good = [
        ("Привет", {}),
        ("Код: {requestId}", {"requestId": {"simple"}}),
        ("{count, plural, one{{count} товар} few{{count} товара} many{{count} товаров} other{{count} товара}}",
         {"count": {"plural", "simple"}}),
        ("{count, plural, =0{Нет} other{{count} шт}}", {"count": {"plural", "simple"}}),
        ("{s, select, a{A} other{B}}", {"s": {"select"}}),
        ("It''s '{literal}'", {}),
        ("Просрочено {amount} · {days, plural, one{{days} день} other{{days} дня}}",
         {"amount": {"simple"}, "days": {"plural", "simple"}}),
    ]
    bad = [
        "Не закрыта {count",
        "Лишняя }",
        "{count, plural, one{x}}",            # нет other
        "{count, plural, single{x} other{y}}",  # недопустимая категория
        "{count, plural, one{x} one{y} other{z}}",  # повтор
        "{count, selectordinal, one{x} other{y}}",
        "{s, select, =1{x} other{y}}",
        "{ }",
        "'незакрытый",
        "{count, plural, one{x} other{y}",
    ]
    fails = 0
    for text, exp in good:
        try:
            got = parse_icu(text)
            if got != exp:
                print(f"FAIL good {text!r}: {got} != {exp}")
                fails += 1
        except IcuError as e:
            print(f"FAIL good {text!r}: {e}")
            fails += 1
    for text in bad:
        try:
            parse_icu(text)
            print(f"FAIL bad принят: {text!r}")
            fails += 1
        except IcuError:
            pass
    print(f"self-test ICU: корректных {len(good)}, некорректных {len(bad)}, провалов {fails}")
    return 1 if fails else 0


def main(argv: list[str] | None = None) -> int:
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", type=Path, default=here.parent, help="корень репозитория")
    ap.add_argument("--l10n-dir", type=Path, default=None, help="каталог ARB (по умолчанию <root>/contracts/l10n)")
    ap.add_argument("--no-spec", action="store_true", help="не читать ТЗ (без проверки префиксов и покрытия)")
    ap.add_argument("--strict-coverage", action="store_true", help="нехватка обязательных общих ключей 03 — ошибка")
    ap.add_argument("--self-test", action="store_true", help="самопроверка ICU-парсера")
    a = ap.parse_args(argv)
    if a.self_test:
        return self_test()
    l10n = a.l10n_dir or (a.root / "contracts" / "l10n")
    spec = None if a.no_spec else (a.root / "docs" / "specification")
    return run_checks(l10n, spec, a.strict_coverage)


if __name__ == "__main__":
    sys.exit(main())
