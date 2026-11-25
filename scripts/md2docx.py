#!/usr/bin/env python3
"""Word-копии (.docx) документов заказчику и программисту 1С из Markdown (подмножество).

Источник истины — файл .md; Word выпускается из него этим скриптом и руками не правится.
Нужен только python-docx (≥ 1.1; lxml ставится вместе с ним).

Поддерживается то, что встречается в docs/customer/*.md и docs/integration/*.md:
  - заголовки «#» (название документа), «##», «###», «####»;
  - абзацы (строки подряд склеиваются через пробел), «---» (пропускается), цитата «> …»;
  - списки «- …» и «1. …»; вложенный уровень — отступ от двух пробелов; строка с отступом без маркера
    и строка сразу после пункта (без пустой строки) продолжают пункт;
  - таблицы GFM: строка-разделитель «|---|» пропускается, «\\|» — символ «|», «|» внутри `кода` ячейку не делит;
  - блоки кода «```» — моноширинный шрифт, строки как есть (табуляция — два пробела);
  - внутри строки: **жирный**, `код`; экранирование «\\*», «\\|» и др. вне кода;
  - строка <sub>…</sub> — мелким шрифтом; строки <sub>, начинающиеся со «Служебно», в Word НЕ попадают
    (служебные ссылки — только для разработчиков).

Вид:
  обычный — короткий документ заказчику: название — стиль «Title», колонтитул справа серым,
    внизу по центру «Стр. N из M»;
  --title-page — длинный документ (как Word «Требования к API 1С» 2026-10-24): титульный лист без колонтитулов
    (ОПТОМСТРОЙ POS, название, подзаголовок — жирные строки сразу после «#», строка --title-note), «Содержание» —
    поле TOC со ссылками на разделы «##» и «###» (номера страниц Word подставит по F9 → «Обновить целиком»),
    каждый раздел «##» — с новой страницы, внизу справа «Стр. N из M».

Проверка --verify (после каждого выпуска): текст Word — абзацы и строки таблиц («ячейка | ячейка») — сравнивается
с текстом .md без разметки (1) блок в блок и (2) построчно: каждая строка .md есть в Word, в том же порядке.
Колонтитулы и поля (номера страниц) не сравниваются. При расхождении печатает первые отличия, код выхода 1.

Запуск (из корня репозитория; Python — python -I -X utf8):
  python -I -X utf8 scripts/md2docx.py <in.md> <out.docx> "<колонтитул>" [--title-page] [--title-note "<строка>"]
      [--date ГГГГ-ММ-ДД]
  python -I -X utf8 scripts/md2docx.py --verify <in.md> <out.docx> [--title-page] [--title-note "<строка>"]

Выпуск 2026-11-25 — стенд как продукт, без демо (с --date 2026-11-25):
  docs/customer/STATUS_GOTOVNOSTI.md    -> docs/customer/Optomstroy_Status_gotovnosti.docx
      "Оптомстрой POS · что готово и что дальше · 25.11.2026"

Выпуск 2026-11-24 — P-004: телефон, QR от банка через наш сервер, SMS, тестовый сервер (оба — с --date 2026-11-24;
у --verify — те же --title-page и --title-note):
  docs/customer/STATUS_GOTOVNOSTI.md    -> docs/customer/Optomstroy_Status_gotovnosti.docx
      "Оптомстрой POS · что готово и что дальше · 24.11.2026"
  docs/customer/Voprosy_zakazchiku.md   -> docs/customer/Voprosy_zakazchiku.docx
      "Оптомстрой POS — вопросы заказчику" --title-page
      --title-note "Дата: 24.11.2026 · 132 вопроса и 18 просьб · начните с вопросов 126–132 (новое от 23.11.2026), затем вопрос 125 и раздел 1 «Срочно» (вопросы 1–14)"

Выпуск 2026-11-20 — отмена P-003, 1С снова главная система (все — с --date 2026-11-20; у --verify — те же
--title-page и --title-note, что при выпуске):
  docs/customer/SERVER_REQUIREMENTS.md  -> docs/customer/Optomstroy_Trebovaniya_k_serveru.docx
      "Оптомстрой POS · требования к серверу · версия 1.5 от 20.11.2026"
  docs/customer/STATUS_GOTOVNOSTI.md    -> docs/customer/Optomstroy_Status_gotovnosti.docx
      "Оптомстрой POS · что готово и что дальше · 20.11.2026"
  docs/customer/Voprosy_zakazchiku.md   -> docs/customer/Voprosy_zakazchiku.docx
      "Оптомстрой POS — вопросы заказчику" --title-page
      --title-note "Дата: 20.11.2026 · 125 вопросов и 18 просьб · начните с вопроса 125, затем раздел 1 «Срочно» (вопросы 1–14)"
  docs/integration/1C_NIGHTLY_EXCHANGE_TZ.md -> docs/integration/Optomstroy_TZ_1C_nightly_v2.docx
      "Оптомстрой POS · ТЗ программисту 1С: ночной обмен · версия 2.3 · ОТОЗВАНО 20.11.2026"
  docs/integration/1C_API_requirements.md -> docs/integration/Optomstroy_TZ_API_1C.docx
      "Оптомстрой POS — требования к API 1С, версия 1.2.1" --title-page
      --title-note "Версия 1.2.1 от 20.11.2026 (требования версии 1.2 от 04.11.2026) · заказчик: Оптомстрой · исполнитель API: программист 1С заказчика"
Прежний выпуск 2026-11-19 (сервер во Франкфурте): требования к серверу 1.4, состояние на 19.11.2026, ТЗ ночного обмена
2.3 (действующее тогда), справочник API 1С 1.2 с титулом «справочник к ТЗ ночного обмена 2.3».

Код выхода: 0 — файл выпущен (или текст совпадает); 1 — расхождения при --verify; 2 — ошибка запуска.
"""
from __future__ import annotations

import argparse
import datetime as dt
import re
import sys
from pathlib import Path

try:
    from docx import Document
    from docx.enum.style import WD_STYLE_TYPE
    from docx.enum.table import WD_TABLE_ALIGNMENT
    from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
    from docx.oxml import OxmlElement
    from docx.oxml.ns import qn
    from docx.shared import Cm, Pt, RGBColor
except ImportError:  # pragma: no cover
    print("нужен python-docx: pip install python-docx", file=sys.stderr)
    sys.exit(2)

REPO = Path(__file__).resolve().parent.parent
BRAND = "ОПТОМСТРОЙ POS"
TOC_TITLE = "Содержание"
TEXT_WIDTH_CM = 17.0

# Вид документа. short — как документы заказчику 2026-11-18; long — как Word «Требования к API 1С» 2026-10-24.
THEMES = {
    "short": {
        "body_pt": 10.5, "table_pt": 9.5, "table_small_pt": 9.5, "code_pt": 8, "sub_pt": 8,
        "para_before": 0, "para_after": 4, "line": 1.05,
        # стиль: (размер, цвет, отступ до, отступ после), пт
        "text": None, "head": {"Title": (17, "1F1F1F", 0, 4), "Heading 1": (13.5, "1F1F1F", 10, 4),
                                "Heading 2": (11.5, "1F1F1F", 10, 4), "Heading 3": (10.5, "1F1F1F", 10, 4)},
        "head_fill": "E7E6E6", "border": None, "cell_mar": None,
        "margins_cm": (1.8, 2.0), "hf_color": "595959", "header_align": "right", "footer_align": "center",
    },
    "long": {
        "body_pt": 11, "table_pt": 9.5, "table_small_pt": 8.5, "code_pt": 8, "sub_pt": 8,
        "para_before": 3, "para_after": 5, "line": 1.15,
        "text": "1B1F2A", "head": {"Heading 1": (16, "B04E00", 12, 8), "Heading 2": (13, "1B1F2A", 13, 6),
                                   "Heading 3": (11.5, "3A4150", 10, 4)},
        "head_fill": "FCE6D0", "border": "BFC4CC", "cell_mar": (50, 90),
        "margins_cm": (2.0, 2.0), "hf_color": "7A808C", "header_align": "left", "footer_align": "right",
    },
}
ACCENT = "FF8700"
CODE_FILL, CODE_LINE, CODE_TEXT = "F4F5F7", "D5D9E0", "2B2F3A"
SUBTITLE_COLOR = "4A505C"

# Порядок дочерних элементов по схеме WordprocessingML: при нарушенном порядке Word может не открыть файл.
PPR_AFTER_PBDR = ("w:shd", "w:tabs", "w:suppressAutoHyphens", "w:kinsoku", "w:wordWrap", "w:overflowPunct",
                  "w:topLinePunct", "w:autoSpaceDE", "w:autoSpaceDN", "w:bidi", "w:adjustRightInd",
                  "w:snapToGrid", "w:spacing", "w:ind", "w:contextualSpacing", "w:mirrorIndents",
                  "w:suppressOverlap", "w:jc", "w:textDirection", "w:textAlignment", "w:textboxTightWrap",
                  "w:outlineLvl", "w:divId", "w:cnfStyle", "w:rPr", "w:sectPr", "w:pPrChange")
PPR_AFTER_SHD = PPR_AFTER_PBDR[1:]
RPR_AFTER_SPACING = ("w:w", "w:kern", "w:position", "w:sz", "w:szCs", "w:highlight", "w:u", "w:effect",
                     "w:bdr", "w:shd", "w:fitText", "w:vertAlign", "w:rtl", "w:cs", "w:em", "w:lang",
                     "w:eastAsianLayout", "w:specVanish", "w:oMath")
TBLPR_AFTER_BORDERS = ("w:shd", "w:tblLayout", "w:tblCellMar", "w:tblLook", "w:tblCaption",
                       "w:tblDescription", "w:tblPrChange")
TBLPR_AFTER_CELLMAR = ("w:tblLook", "w:tblCaption", "w:tblDescription", "w:tblPrChange")
TCPR_AFTER_SHD = ("w:noWrap", "w:tcMar", "w:textDirection", "w:tcFitText", "w:vAlign", "w:hideMark",
                  "w:headers", "w:cellIns", "w:cellDel", "w:cellMerge", "w:tcPrChange")


# ---------------------------------------------------------------- разбор Markdown на блоки

LIST_RE = re.compile(r"^(\s*)([-*+]|\d+[.)])\s+(.*)$")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)$")
RULE_RE = re.compile(r"^(?:-{3,}|\*{3,}|_{3,})$")
ESCAPABLE = r"[!-/:-@\[-`{-~]"  # ASCII-пунктуация (CommonMark, экранирование «\»)


def split_row(line: str) -> list[str]:
    """Строка таблицы GFM → ячейки; «\\|» — символ «|»; «|» внутри `кода` ячейку не делит."""
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|") and not s.endswith("\\|"):
        s = s[:-1]
    cells, cur, in_code, i = [], "", False, 0
    while i < len(s):
        ch = s[i]
        if ch == "\\" and i + 1 < len(s) and s[i + 1] == "|":
            cur += "|"
            i += 2
            continue
        if ch == "`":
            in_code = not in_code
        if ch == "|" and not in_code:
            cells.append(cur.strip())
            cur = ""
        else:
            cur += ch
        i += 1
    cells.append(cur.strip())
    return cells


def is_separator(cells: list[str]) -> bool:
    return bool(cells) and all(re.fullmatch(r":?-{2,}:?", c.replace(" ", "")) for c in cells)


def parse_md(text: str) -> list[tuple]:
    """Блоки: ('title', t) ('heading', 2..4, t) ('para', t) ('bullet', lvl, t) ('number', lvl, n, t)
    ('quote', t) ('sub', t) ('table', rows) ('code', lang, lines). Служебные <sub> не попадают."""
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    blocks: list[tuple] = []
    buf: list[str] = []
    i, n = 0, len(lines)

    def flush() -> None:
        if buf:
            blocks.append(("para", " ".join(buf)))
            buf.clear()

    def special(raw: str) -> bool:
        s = raw.strip()
        return (not s or s.startswith(("```", "|", ">", "<sub>")) or bool(HEADING_RE.match(s))
                or bool(RULE_RE.fullmatch(s)) or bool(LIST_RE.match(raw)))

    while i < n:
        raw = lines[i]
        s = raw.strip()
        if s.startswith("```"):
            flush()
            lang, code = s[3:].strip(), []
            i += 1
            while i < n and not lines[i].strip().startswith("```"):
                code.append(lines[i].rstrip().replace("\t", "  "))
                i += 1
            blocks.append(("code", lang, code))
            i += 1
            continue
        if not s:
            flush()
            i += 1
            continue
        if s.startswith("<sub>"):
            flush()
            inner = re.sub(r"</?sub>", "", s).strip()
            if not inner.startswith("Служебно"):
                blocks.append(("sub", inner))
            i += 1
            continue
        if RULE_RE.fullmatch(s):
            flush()
            i += 1
            continue
        if s.startswith("|"):
            flush()
            rows = []
            while i < n and lines[i].strip().startswith("|"):
                rows.append(split_row(lines[i]))
                i += 1
            if len(rows) >= 2 and is_separator(rows[1]):
                rows = [rows[0]] + rows[2:]
            blocks.append(("table", rows))
            continue
        m = HEADING_RE.match(s)
        if m:
            flush()
            level, title = len(m.group(1)), m.group(2).strip()
            blocks.append(("title", title) if level == 1 else ("heading", min(level, 4), title))
            i += 1
            continue
        m = LIST_RE.match(raw)
        if m:
            flush()
            level = 1 if len(m.group(1).expandtabs(4)) >= 2 else 0
            parts = [m.group(3).strip()]
            i += 1
            while i < n and not special(lines[i]):  # продолжение пункта (с отступом или «ленивое»)
                parts.append(lines[i].strip())
                i += 1
            item = " ".join(parts)
            marker = m.group(2)
            if marker[0].isdigit():
                blocks.append(("number", level, marker[:-1], item))
            else:
                blocks.append(("bullet", level, item))
            continue
        if s.startswith(">"):
            flush()
            blocks.append(("quote", s[1:].strip()))
            i += 1
            continue
        buf.append(s)
        i += 1
    flush()
    return blocks


def front_matter(blocks: list[tuple]) -> tuple[str, list[str], list[tuple]]:
    """Для --title-page: название, подзаголовки (жирные строки сразу после «#») и остальные блоки."""
    title, subtitles, rest = "", [], list(blocks)
    if rest and rest[0][0] == "title":
        title = rest.pop(0)[1]
        while rest and rest[0][0] == "para" and re.fullmatch(r"\*\*[^*]+\*\*", rest[0][1]) \
                and len(rest[0][1]) <= 200:
            subtitles.append(rest.pop(0)[1])
    return title, subtitles, rest


# ---------------------------------------------------------------- строка: жирный, код, экранирование

def inline_segments(text: str) -> list[tuple[str, bool, bool]]:
    """Текст → [(кусок, жирный, код)]. Внутри `кода` всё буквально; вне — «**» и «\\x»."""
    segs: list[tuple[str, bool, bool]] = []
    bold, buf, i = False, "", 0
    while i < len(text):
        ch = text[i]
        if ch == "`":
            j = text.find("`", i + 1)
            if j != -1:
                if buf:
                    segs.append((buf, bold, False))
                    buf = ""
                segs.append((text[i + 1:j], bold, True))
                i = j + 1
                continue
        if text.startswith("**", i):
            if buf:
                segs.append((buf, bold, False))
                buf = ""
            bold = not bold
            i += 2
            continue
        if ch == "\\" and i + 1 < len(text) and re.match(ESCAPABLE, text[i + 1]):
            buf += text[i + 1]
            i += 2
            continue
        buf += ch
        i += 1
    if buf:
        segs.append((buf, bold, False))
    return segs


def plain(text: str) -> str:
    """Текст строки без разметки — независимая от inline_segments реализация (для --verify)."""
    out = []
    for part in re.split(r"(`[^`]*`)", text):
        if len(part) >= 2 and part.startswith("`") and part.endswith("`"):
            out.append(part[1:-1])
        else:
            out.append(re.sub(r"\\(" + ESCAPABLE + ")", r"\1", part.replace("**", "")))
    return "".join(out)


# ---------------------------------------------------------------- оформление (python-docx + XML)

def el(tag: str, **attrs: str):
    e = OxmlElement(tag)
    for k, v in attrs.items():
        e.set(qn(k.replace("_", ":", 1)), str(v))
    return e


def set_rfonts(rpr, name: str) -> None:
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = el("w:rFonts")
        rpr.insert(0, rfonts)
    for attr in ("w:asciiTheme", "w:hAnsiTheme", "w:eastAsiaTheme", "w:cstheme"):
        if rfonts.get(qn(attr)) is not None:
            del rfonts.attrib[qn(attr)]
    for attr in ("w:ascii", "w:hAnsi", "w:cs", "w:eastAsia"):
        rfonts.set(qn(attr), name)


def style_font(style, name="Calibri", size=None, bold=None, color=None) -> None:
    style.font.name = name
    set_rfonts(style.element.get_or_add_rPr(), name)
    if size is not None:
        style.font.size = Pt(size)
    if bold is not None:
        style.font.bold = bold
    if color is not None:
        style.font.color.rgb = RGBColor.from_string(color)


def para_border(p, side: str, sz: int, color: str, space: int) -> None:
    ppr = p._p.get_or_add_pPr()
    pbdr = ppr.find(qn("w:pBdr"))
    if pbdr is None:
        pbdr = el("w:pBdr")
        ppr.insert_element_before(pbdr, *PPR_AFTER_PBDR)
    pbdr.append(el(f"w:{side}", w_val="single", w_sz=sz, w_space=space, w_color=color))


def para_shade(p, fill: str) -> None:
    ppr = p._p.get_or_add_pPr()
    ppr.insert_element_before(el("w:shd", w_val="clear", w_color="auto", w_fill=fill), *PPR_AFTER_SHD)


def add_field(paragraph, instr: str, size=None, color=None) -> None:
    """Простое поле Word (PAGE, NUMPAGES): начало, код, разделитель, значение «1», конец — отдельными runs."""
    instr_el = el("w:instrText", xml_space="preserve")
    instr_el.text = f" {instr} "
    for part in (el("w:fldChar", w_fldCharType="begin"), instr_el, el("w:fldChar", w_fldCharType="separate"),
                 None, el("w:fldChar", w_fldCharType="end")):
        run = paragraph.add_run("1" if part is None else None)
        if part is not None:
            run._r.append(part)
        if size:
            run.font.size = Pt(size)
        if color:
            run.font.color.rgb = RGBColor.from_string(color)


def add_inline(paragraph, text: str, size=None, base_bold=False, color=None, body_pt=10.5) -> None:
    """Куски inline_segments → runs: жирный — bold, код — Consolas на 1 пт меньше."""
    for chunk, bold, code in inline_segments(text):
        run = paragraph.add_run(chunk)
        run.bold = bold or base_bold or None
        if code:
            run.font.name = "Consolas"
            set_rfonts(run._r.get_or_add_rPr(), "Consolas")
            run.font.size = Pt((size or body_pt) - 1)
        elif size:
            run.font.size = Pt(size)
        if color:
            run.font.color.rgb = RGBColor.from_string(color)


class Builder:
    def __init__(self, theme: dict, header_text: str, title_page: bool):
        self.t = theme
        self.title_page = title_page
        self.doc = Document()
        self.bookmark_id = 0
        self.body_started = False
        self._setup(header_text)

    def inline(self, paragraph, text: str, **kw) -> None:
        add_inline(paragraph, text, body_pt=self.t["body_pt"], **kw)

    # -- документ, стили, колонтитулы
    def _setup(self, header_text: str) -> None:
        t, doc = self.t, self.doc
        sec = doc.sections[0]
        sec.page_width, sec.page_height = Cm(21.0), Cm(29.7)
        tb, lr = t["margins_cm"]
        sec.top_margin = sec.bottom_margin = Cm(tb)
        sec.left_margin = sec.right_margin = Cm(lr)
        if self.title_page:
            sec.header_distance = sec.footer_distance = Cm(1.0)

        defaults = doc.styles.element.find(qn("w:docDefaults")).find(qn("w:rPrDefault")).find(qn("w:rPr"))
        set_rfonts(defaults, "Calibri")
        lang = defaults.find(qn("w:lang"))
        if lang is not None:
            lang.set(qn("w:val"), "ru-RU")
            lang.set(qn("w:eastAsia"), "ru-RU")

        normal = doc.styles["Normal"]
        style_font(normal, size=t["body_pt"], color=t["text"])
        rpr = normal.element.get_or_add_rPr()
        if rpr.find(qn("w:lang")) is None:
            rpr.append(el("w:lang", w_val="ru-RU", w_eastAsia="ru-RU"))
        pf = normal.paragraph_format
        pf.space_before = Pt(t["para_before"])
        pf.space_after = Pt(t["para_after"])
        pf.line_spacing = t["line"]
        for name, (size, color, before, after) in t["head"].items():
            st = doc.styles[name]
            style_font(st, size=size, bold=True, color=color)
            st.paragraph_format.space_before = Pt(before)
            st.paragraph_format.space_after = Pt(after)
            st.paragraph_format.keep_with_next = True
        for name in ("List Bullet", "List Bullet 2"):
            style_font(doc.styles[name], size=t["body_pt"])
        if self.title_page:
            for name, indent in (("toc 1", 0.0), ("toc 2", 0.39)):
                st = doc.styles.add_style(name, WD_STYLE_TYPE.PARAGRAPH)
                # встроенный стиль Word «TOC 1/2»: по нему Word оформит содержание и при обновлении поля (F9)
                st.style_id = name.upper().replace(" ", "")
                st.element.attrib.pop(qn("w:customStyle"), None)
                st.base_style = normal
                st.paragraph_format.space_before = Pt(0)
                st.paragraph_format.space_after = Pt(4 if name == "toc 1" else 2)
                st.paragraph_format.left_indent = Cm(indent)

        hf = t["hf_color"]
        hp = sec.header.paragraphs[0]
        hp.alignment = WD_ALIGN_PARAGRAPH.RIGHT if t["header_align"] == "right" else WD_ALIGN_PARAGRAPH.LEFT
        hr = hp.add_run(header_text)
        hr.font.size = Pt(8)
        hr.font.color.rgb = RGBColor.from_string(hf)
        if self.title_page:
            para_border(hp, "bottom", 4, CODE_LINE, 4)
            sec.different_first_page_header_footer = True
        fp = sec.footer.paragraphs[0]
        fp.alignment = WD_ALIGN_PARAGRAPH.CENTER if t["footer_align"] == "center" else WD_ALIGN_PARAGRAPH.RIGHT
        for part in ("Стр. ", "PAGE", " из ", "NUMPAGES"):
            if part in ("PAGE", "NUMPAGES"):
                add_field(fp, part, size=8, color=hf)
            else:
                r = fp.add_run(part)
                r.font.size = Pt(8)
                r.font.color.rgb = RGBColor.from_string(hf)

    # -- титульный лист и содержание
    def title_page_and_toc(self, title: str, subtitles: list[str], note: str, toc: list[tuple[int, str, str]]):
        doc = self.doc
        p = doc.add_paragraph()
        p.paragraph_format.space_before = Pt(120)
        p = doc.add_paragraph()
        p.paragraph_format.space_after = Pt(12)
        r = p.add_run(BRAND)
        r.bold = True
        r.font.size = Pt(13)
        r.font.color.rgb = RGBColor.from_string(ACCENT)
        rpr = r._r.get_or_add_rPr()
        rpr.insert_element_before(el("w:spacing", w_val=40), *RPR_AFTER_SPACING)
        p = doc.add_paragraph()
        p.paragraph_format.space_after = Pt(12)
        p.paragraph_format.line_spacing = 1.0
        para_border(p, "bottom", 18, ACCENT, 8)
        r = p.add_run(title)
        r.bold = True
        r.font.size = Pt(24)
        for s in subtitles:
            p = doc.add_paragraph()
            p.paragraph_format.space_after = Pt(6)
            self.inline(p, s, size=12, color=SUBTITLE_COLOR)
        if note:
            p = doc.add_paragraph()
            p.paragraph_format.space_before = Pt(12)
            p.paragraph_format.space_after = Pt(6)
            self.inline(p, note, color=SUBTITLE_COLOR)
        doc.add_paragraph().add_run().add_break(WD_BREAK.PAGE)
        p = doc.add_paragraph()
        p.paragraph_format.space_after = Pt(10)
        r = p.add_run(TOC_TITLE)
        r.bold = True
        r.font.size = Pt(16)
        r.font.color.rgb = RGBColor.from_string(self.t["head"]["Heading 1"][1])
        for idx, (level, text, anchor) in enumerate(toc):
            p = doc.add_paragraph(style="toc 1" if level == 2 else "toc 2")
            if idx == 0:
                r = p.add_run()
                r._r.append(el("w:fldChar", w_fldCharType="begin"))
                r = p.add_run()
                instr = el("w:instrText", xml_space="preserve")
                instr.text = ' TOC \\o "1-2" \\h \\z \\u '
                r._r.append(instr)
                r = p.add_run()
                r._r.append(el("w:fldChar", w_fldCharType="separate"))
            link = el("w:hyperlink", w_anchor=anchor, w_history="1")
            for chunk, bold, code in inline_segments(text):
                rr = el("w:r")
                if code:
                    rpr = el("w:rPr")
                    rpr.append(el("w:rFonts", w_ascii="Consolas", w_hAnsi="Consolas", w_cs="Consolas",
                                  w_eastAsia="Consolas"))
                    rr.append(rpr)
                tt = el("w:t", xml_space="preserve")
                tt.text = chunk
                rr.append(tt)
                link.append(rr)
            p._p.append(link)
            if idx == len(toc) - 1:
                r = p.add_run()
                r._r.append(el("w:fldChar", w_fldCharType="end"))
        doc.add_paragraph().add_run().add_break(WD_BREAK.PAGE)

    # -- блоки текста
    def heading(self, level: int, text: str, anchor: str | None = None) -> None:
        p = self.doc.add_paragraph(style={2: "Heading 1", 3: "Heading 2"}.get(level, "Heading 3"))
        if self.title_page and level == 2 and self.body_started:
            p.paragraph_format.page_break_before = True
        if anchor:
            self.bookmark_id += 1
            p._p.append(el("w:bookmarkStart", w_id=self.bookmark_id, w_name=anchor))
        self.inline(p, text)
        if anchor:
            p._p.append(el("w:bookmarkEnd", w_id=self.bookmark_id))
        self.body_started = True

    def title(self, text: str) -> None:
        self.inline(self.doc.add_paragraph(style="Title"), text)

    def para(self, text: str) -> None:
        self.inline(self.doc.add_paragraph(), text)
        self.body_started = True

    def bullet(self, level: int, text: str) -> None:
        p = self.doc.add_paragraph(style="List Bullet 2" if level else "List Bullet")
        p.paragraph_format.space_after = Pt(2)
        self.inline(p, text)
        self.body_started = True

    def number(self, level: int, num: str, text: str) -> None:
        p = self.doc.add_paragraph()
        pf = p.paragraph_format
        pf.left_indent = Cm(0.63 * (level + 1))
        pf.first_line_indent = Cm(-0.63)
        pf.space_after = Pt(2)
        pf.tab_stops.add_tab_stop(Cm(0.63 * (level + 1)))
        p.add_run(num + ".\t")
        self.inline(p, text)
        self.body_started = True

    def quote(self, text: str) -> None:
        p = self.doc.add_paragraph()
        p.paragraph_format.left_indent = Cm(0.5)
        if self.title_page:
            para_border(p, "left", 12, ACCENT, 8)
        self.inline(p, text)
        self.body_started = True

    def sub(self, text: str) -> None:
        self.inline(self.doc.add_paragraph(), text, size=self.t["sub_pt"])
        self.body_started = True

    def code(self, lines: list[str]) -> None:
        lines = lines or [""]
        keep = len(lines) <= 20
        for idx, line in enumerate(lines):
            p = self.doc.add_paragraph()
            pf = p.paragraph_format
            pf.space_before = Pt(3 if idx == 0 else 0)
            pf.space_after = Pt(6 if idx == len(lines) - 1 else 0)
            pf.line_spacing = 1.0
            pf.left_indent = pf.right_indent = Cm(0.21)
            pf.keep_together = True
            pf.keep_with_next = keep and idx < len(lines) - 1
            if idx == 0:
                para_border(p, "top", 4, CODE_LINE, 2)
            if idx == len(lines) - 1:
                para_border(p, "bottom", 4, CODE_LINE, 2)
            para_shade(p, CODE_FILL)
            r = p.add_run(line if line else " ")
            r.font.name = "Consolas"
            set_rfonts(r._r.get_or_add_rPr(), "Consolas")
            r.font.size = Pt(self.t["code_pt"])
            r.font.color.rgb = RGBColor.from_string(CODE_TEXT)
        self.body_started = True

    def table(self, rows: list[list[str]]) -> None:
        t = self.t
        ncols = max(len(r) for r in rows)
        rows = [r + [""] * (ncols - len(r)) for r in rows]
        size = t["table_small_pt"] if ncols >= 5 else t["table_pt"]
        widths = column_widths(rows, size)
        table = self.doc.add_table(rows=len(rows), cols=ncols)
        table.style = "Table Grid"
        table.alignment = WD_TABLE_ALIGNMENT.CENTER
        table.autofit = False
        tblpr = table._tbl.tblPr
        if t["border"]:
            borders = el("w:tblBorders")
            for side in ("top", "left", "bottom", "right", "insideH", "insideV"):
                borders.append(el(f"w:{side}", w_val="single", w_sz=4, w_space=0, w_color=t["border"]))
            tblpr.insert_element_before(borders, *TBLPR_AFTER_BORDERS)
        if t["cell_mar"]:
            tb, lr = t["cell_mar"]
            mar = el("w:tblCellMar")
            for side, v in (("top", tb), ("left", lr), ("bottom", tb), ("right", lr)):
                mar.append(el(f"w:{side}", w_w=v, w_type="dxa"))
            tblpr.insert_element_before(mar, *TBLPR_AFTER_CELLMAR)
        for c, gc in enumerate(table._tbl.tblGrid.findall(qn("w:gridCol"))):
            gc.set(qn("w:w"), str(int(widths[c] * 567)))
        for r_idx, row in enumerate(rows):
            cells = table.rows[r_idx].cells
            for c in range(ncols):
                cell = cells[c]
                cell.width = Cm(widths[c])
                p = cell.paragraphs[0]
                p.paragraph_format.space_after = Pt(1 if self.title_page else 0)
                p.paragraph_format.space_before = Pt(1 if self.title_page else 0)
                p.paragraph_format.line_spacing = 1.0
                self.inline(p, row[c], size=size, base_bold=(r_idx == 0))
                if r_idx == 0:
                    tcpr = cell._tc.get_or_add_tcPr()
                    tcpr.insert_element_before(el("w:shd", w_val="clear", w_color="auto", w_fill=t["head_fill"]),
                                               *TCPR_AFTER_SHD)
        trpr = table.rows[0]._tr.get_or_add_trPr()
        trpr.append(el("w:tblHeader", w_val="true"))
        self.doc.add_paragraph().paragraph_format.space_after = Pt(2)
        self.body_started = True


def column_widths(rows: list[list[str]], size_pt: float) -> list[float]:
    """Ширины колонок, см: по длине текста, не уже самого длинного слова (как генератор 2026-10-24)."""
    ncols = len(rows[0])
    per_char = 0.0195 * size_pt  # ≈ средняя ширина знака Calibri/Consolas, см на 1 пт
    texts = [[plain(r[c]) for r in rows] for c in range(ncols)]
    lens = []
    for vals in texts:
        max_len = max(min(len(v), 60) for v in vals)
        avg = sum(min(len(v), 120) for v in vals) / len(vals)
        lens.append(max(4.0, 0.4 * max_len + 0.6 * avg))
    total = sum(lens)
    min_w = []
    for vals in texts:
        words = [w for v in vals for w in re.split(r"[\s/]+", v)]
        longest = max([4] + [min(len(w), 34) for w in words])
        min_w.append(min(TEXT_WIDTH_CM * 0.38, longest * per_char + 0.35))
    sum_min = sum(min_w)
    if sum_min >= TEXT_WIDTH_CM:
        return [w * TEXT_WIDTH_CM / sum_min for w in min_w]
    want = [max(0.0, TEXT_WIDTH_CM * lens[c] / total - min_w[c]) for c in range(ncols)]
    sum_want = sum(want) or 1.0
    rest = TEXT_WIDTH_CM - sum_min
    return [min_w[c] + rest * want[c] / sum_want for c in range(ncols)]


def toc_entries(blocks: list[tuple]) -> list[tuple[int, str, str]]:
    out, k = [], 0
    for b in blocks:
        if b[0] == "heading" and b[1] in (2, 3):
            k += 1
            out.append((b[1], b[2], f"_TocMd{k:04d}"))
    return out


def build(md_path: Path, out_path: Path, header_text: str, title_page: bool, note: str, date: dt.date) -> int:
    blocks = parse_md(md_path.read_text(encoding="utf-8"))
    b = Builder(THEMES["long" if title_page else "short"], header_text, title_page)
    title = ""
    anchors: list[str] = []
    if title_page:
        title, subtitles, blocks = front_matter(blocks)
        toc = toc_entries(blocks)
        anchors = [a for _, _, a in toc]  # в порядке заголовков «##»/«###» — как в toc_entries
        b.title_page_and_toc(title, subtitles, note, toc)
    uneven = 0
    for blk in blocks:
        kind = blk[0]
        if kind == "title":
            title = title or blk[1]
            b.title(blk[1])
        elif kind == "heading":
            b.heading(blk[1], blk[2], anchors.pop(0) if anchors and blk[1] in (2, 3) else None)
        elif kind == "para":
            b.para(blk[1])
        elif kind == "bullet":
            b.bullet(blk[1], blk[2])
        elif kind == "number":
            b.number(blk[1], blk[2], blk[3])
        elif kind == "quote":
            b.quote(blk[1])
        elif kind == "sub":
            b.sub(blk[1])
        elif kind == "code":
            b.code(blk[2])
        elif kind == "table":
            uneven += sum(1 for r in blk[1] if len(r) != len(blk[1][0]))
            b.table(blk[1])
    cp = b.doc.core_properties
    cp.title = plain(title)
    cp.author = cp.last_modified_by = "Оптомстрой POS"
    cp.created = cp.modified = dt.datetime(date.year, date.month, date.day, 12, 0, 0)
    cp.revision = 1
    cp.language = "ru-RU"
    cp.comments = "Выпущено из " + rel(md_path)
    cp.subject = header_text
    out_path.parent.mkdir(parents=True, exist_ok=True)
    b.doc.save(str(out_path))
    print(f"{rel(out_path)}: блоков {len(blocks)}, таблиц {sum(1 for x in blocks if x[0] == 'table')}, "
          f"блоков кода {sum(1 for x in blocks if x[0] == 'code')}"
          + (f", строк таблиц с другим числом ячеек: {uneven}" if uneven else ""))
    return 0


def rel(path: Path) -> str:
    try:
        return path.resolve().relative_to(REPO).as_posix()
    except ValueError:
        return path.name


# ---------------------------------------------------------------- проверка текста .md ↔ .docx

def docx_blocks(path: Path) -> list[str]:
    """Абзацы и строки таблиц тела документа; текст полей (instrText) не берётся."""
    from docx import Document as _Doc
    body = _Doc(str(path)).element.body
    out: list[str] = []

    def ptext(p) -> str:
        parts = []
        for node in p.iter(qn("w:t"), qn("w:tab")):
            if node.tag == qn("w:tab"):
                if node.getparent().tag == qn("w:r"):
                    parts.append("\t")
            else:
                parts.append(node.text or "")
        return "".join(parts)

    def walk(container) -> None:
        for child in container.iterchildren():
            if child.tag == qn("w:p"):
                out.append(ptext(child))
            elif child.tag == qn("w:tbl"):
                for tr in child.iter(qn("w:tr")):
                    out.append(" | ".join("".join(ptext(p) for p in tc.iter(qn("w:p")))
                                          for tc in tr.iterchildren(qn("w:tc"))))
            elif child.tag == qn("w:sdt"):
                content = child.find(qn("w:sdtContent"))
                if content is not None:
                    walk(content)

    walk(body)
    return [x for x in out if x.strip()]


def expected_blocks(blocks: list[tuple]) -> list[str]:
    out: list[str] = []
    for blk in blocks:
        kind = blk[0]
        if kind in ("title", "para", "quote", "sub"):
            out.append(plain(blk[1]))
        elif kind == "heading":
            out.append(plain(blk[2]))
        elif kind == "bullet":
            out.append(plain(blk[2]))
        elif kind == "number":
            out.append(f"{blk[2]}.\t{plain(blk[3])}")
        elif kind == "code":
            out.extend(blk[2])
        elif kind == "table":
            ncols = max(len(r) for r in blk[1])
            out.extend(" | ".join(plain(c) for c in r + [""] * (ncols - len(r))) for r in blk[1])
    return [x for x in out if x.strip()]


def line_fragments(md_text: str) -> list[str]:
    """Каждая значимая строка .md без разметки — независимо от разбора на блоки."""
    frags, in_code = [], False
    for raw in md_text.replace("\r\n", "\n").split("\n"):
        s = raw.strip()
        if s.startswith("```"):
            in_code = not in_code
            continue
        if in_code:
            if s:
                frags.append(raw.rstrip().replace("\t", "  "))
            continue
        if not s or RULE_RE.fullmatch(s):
            continue
        if s.startswith("<sub>"):
            inner = re.sub(r"</?sub>", "", s).strip()
            if not inner.startswith("Служебно"):
                frags.append(plain(inner))
            continue
        if s.startswith("|"):
            cells = split_row(s)
            if not is_separator(cells):
                frags.extend(plain(c) for c in cells if c)
            continue
        s = re.sub(r"^#{1,6}\s+", "", s)
        s = re.sub(r"^([-*+]|\d+[.)])\s+", "", s)
        s = re.sub(r"^>\s?", "", s)
        frags.append(plain(s.strip()))
    return [f for f in frags if f.strip()]


def verify(md_path: Path, docx_path: Path, title_page: bool, note: str) -> int:
    md_text = md_path.read_text(encoding="utf-8")
    blocks = parse_md(md_text)
    front: list[str] = []
    title, subtitles = "", []
    if title_page:
        title, subtitles, blocks = front_matter(blocks)
        front = [BRAND, plain(title), *(plain(s) for s in subtitles)] + ([plain(note)] if note else [])
        front += [TOC_TITLE] + [plain(t) for _, t, _ in toc_entries(blocks)]
    want = front + expected_blocks(blocks)
    got = docx_blocks(docx_path)
    problems = 0
    if want != got:
        import difflib
        diff = list(difflib.unified_diff(want, got, "md", "docx", n=1, lineterm=""))
        problems += sum(1 for d in diff if d[:1] in "+-" and not d.startswith(("+++", "---")))
        print(f"блоки: md {len(want)}, docx {len(got)} — РАСХОЖДЕНИЕ")
        for line in diff[:40]:
            print("  " + line[:220])
    else:
        print(f"блоки: md {len(want)} = docx {len(got)}, текст совпадает")
    # построчно: каждая строка .md — в тексте Word (после титульного листа и содержания), по порядку
    body_text = "\n".join(got[len(front):])
    frags = line_fragments(md_text)
    if title_page:  # название и подзаголовки — на титульном листе (сверены блоками выше)
        head = [plain(title)] + [plain(x) for x in subtitles]
        while frags and head and frags[0] == head[0]:
            frags.pop(0)
            head.pop(0)
    pos, missing = 0, []
    for frag in frags:
        k = body_text.find(frag, pos)
        if k == -1:
            missing.append(frag)
            continue
        pos = k + len(frag)
    if missing:
        problems += len(missing)
        print(f"строки .md, которых нет в Word по порядку: {len(missing)}")
        for f in missing[:20]:
            print("  " + f[:200])
    else:
        print("строки .md: все есть в Word, порядок тот же")
    return 1 if problems else 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--verify", action="store_true", help="сверить текст готового .docx с .md")
    ap.add_argument("md", type=Path)
    ap.add_argument("docx", type=Path)
    ap.add_argument("header", nargs="?", default="", help="колонтитул (при выпуске)")
    ap.add_argument("--title-page", action="store_true", help="титульный лист и содержание (длинный документ)")
    ap.add_argument("--title-note", default="", help="строка на титульном листе (версия, стороны)")
    ap.add_argument("--date", default="", help="дата в свойствах файла, ГГГГ-ММ-ДД (по умолчанию — сегодня)")
    args = ap.parse_args(argv)
    if not args.md.is_file():
        print(f"нет файла {args.md}", file=sys.stderr)
        return 2
    if args.verify:
        if not args.docx.is_file():
            print(f"нет файла {args.docx}", file=sys.stderr)
            return 2
        return verify(args.md, args.docx, args.title_page, args.title_note)
    if not args.header:
        print("нужен колонтитул (третий аргумент)", file=sys.stderr)
        return 2
    try:
        date = dt.date.fromisoformat(args.date) if args.date else dt.date.today()
    except ValueError:
        print(f"неверная дата {args.date!r}", file=sys.stderr)
        return 2
    return build(args.md, args.docx, args.header, args.title_page, args.title_note, date)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
