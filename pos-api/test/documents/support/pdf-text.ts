import { inflateSync } from 'node:zlib';

/**
 * Минимальный разбор PDF, сформированного pdfkit (**только для тестов**; `pdf-parse` в зависимостях нет): объекты,
 * размеры страниц (`MediaBox`), встроенные шрифты и текст. Текст восстанавливается по операторам `Tf`/`TJ`/`Tj`
 * потоков содержимого и CMap `ToUnicode` шрифтов (pdfkit кодирует глифы шестнадцатеричными кодами Identity-H).
 * Каждый текстовый объект (`BT … ET`) — отдельная строка; неразрывный пробел нормализуется в обычный.
 */
export interface ParsedPdf {
  readonly pages: readonly { readonly width: number; readonly height: number }[];
  readonly fonts: readonly string[];
  readonly lines: readonly string[];
  readonly text: string;
}

interface PdfObject {
  readonly num: number;
  readonly dict: string;
  readonly stream: Buffer | null;
}

/** Неразрывный пробел (U+00A0) — разделитель тысяч в суммах. */
const NBSP = String.fromCharCode(0xa0);

function parseObjects(buf: Buffer): Map<number, PdfObject> {
  const s = buf.toString('latin1');
  const out = new Map<number, PdfObject>();
  const re = /(\d+) 0 obj\b/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(s))) {
    const start = m.index + m[0].length;
    const end = s.indexOf('endobj', start);
    if (end < 0) break;
    const body = s.slice(start, end);
    const si = body.indexOf('stream');
    let dict = body;
    let stream: Buffer | null = null;
    if (si >= 0 && /^stream\r?\n/.test(body.slice(si))) {
      dict = body.slice(0, si);
      const dataStart = start + si + (body.slice(si).startsWith('stream\r\n') ? 8 : 7);
      const dataEnd = s.lastIndexOf('endstream', end);
      // Длина потока — из /Length словаря (прямое число). Срезать «все» хвостовые 0x0A/0x0D нельзя: сжатые данные
      // сами могут оканчиваться таким байтом (≈ 1 % потоков) — inflate тогда падал «unexpected end of file»
      // (нестабильность documents.e2e, ревью F раунд 2). Без /Length — снимается ровно один EOL перед endstream.
      const len = /\/Length (\d+)\b(?!\s+\d+\s+R)/.exec(dict);
      let raw = len ? buf.subarray(dataStart, dataStart + Number(len[1])) : buf.subarray(dataStart, dataEnd);
      if (!len) {
        if (raw.length > 0 && raw[raw.length - 1] === 0x0a) raw = raw.subarray(0, raw.length - 1);
        if (raw.length > 0 && raw[raw.length - 1] === 0x0d) raw = raw.subarray(0, raw.length - 1);
      }
      stream = /\/FlateDecode/.test(dict) ? inflateSync(raw) : raw;
    }
    out.set(Number(m[1]), { num: Number(m[1]), dict, stream });
    re.lastIndex = end;
  }
  return out;
}

function hexToString(hex: string): string {
  let r = '';
  for (let i = 0; i + 4 <= hex.length; i += 4) r += String.fromCharCode(parseInt(hex.slice(i, i + 4), 16));
  return r;
}

function parseCMap(text: string): Map<number, string> {
  const map = new Map<number, string>();
  for (const block of text.matchAll(/beginbfrange([\s\S]*?)endbfrange/g)) {
    for (const line of block[1].matchAll(/<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]+)>\s*(\[[^\]]*\]|<[0-9a-fA-F]+>)/g)) {
      const lo = parseInt(line[1], 16);
      const hi = parseInt(line[2], 16);
      const dst = line[3];
      if (dst.startsWith('[')) {
        const items = [...dst.matchAll(/<([0-9a-fA-F]+)>/g)].map((x) => hexToString(x[1]));
        for (let c = lo; c <= hi; c += 1) map.set(c, items[c - lo] ?? '');
      } else {
        const base = parseInt(dst.slice(1, -1), 16);
        for (let c = lo; c <= hi; c += 1) map.set(c, String.fromCharCode(base + (c - lo)));
      }
    }
  }
  for (const block of text.matchAll(/beginbfchar([\s\S]*?)endbfchar/g)) {
    for (const line of block[1].matchAll(/<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]+)>/g)) {
      map.set(parseInt(line[1], 16), hexToString(line[2]));
    }
  }
  return map;
}

export function parsePdf(buf: Buffer): ParsedPdf {
  if (buf.subarray(0, 5).toString('latin1') !== '%PDF-') throw new Error('не PDF');
  const objs = parseObjects(buf);
  // Шрифты: объект шрифта → CMap ToUnicode; имя ресурса (/F1) → объект шрифта.
  const cmaps = new Map<number, Map<number, string>>();
  const fonts: string[] = [];
  for (const o of objs.values()) {
    const tu = /\/ToUnicode (\d+) 0 R/.exec(o.dict);
    if (tu) {
      const cm = objs.get(Number(tu[1]))?.stream;
      if (cm) cmaps.set(o.num, parseCMap(cm.toString('latin1')));
    }
    const bf = /\/BaseFont \/([A-Za-z0-9+\-_]+)/.exec(o.dict);
    if (bf && /\/Type \/Font/.test(o.dict)) fonts.push(bf[1]);
  }
  const resourceFont = new Map<string, number>();
  for (const o of objs.values()) {
    for (const fm of o.dict.matchAll(/\/Font\s*<<([^>]*)>>/g)) {
      for (const p of fm[1].matchAll(/\/([A-Za-z0-9]+)\s+(\d+) 0 R/g)) resourceFont.set(p[1], Number(p[2]));
    }
  }
  // Страницы — в порядке /Kids дерева /Pages.
  const pagesObj = [...objs.values()].find((o) => /\/Type \/Pages\b/.test(o.dict));
  const kids = pagesObj ? [...(/\/Kids \[([^\]]*)\]/.exec(pagesObj.dict)?.[1] ?? '').matchAll(/(\d+) 0 R/g)] : [];
  const pages: { width: number; height: number }[] = [];
  const lines: string[] = [];
  for (const k of kids) {
    const page = objs.get(Number(k[1]));
    if (!page) continue;
    const mb = /\/MediaBox \[\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*\]/.exec(page.dict);
    if (mb) pages.push({ width: Number(mb[3]) - Number(mb[1]), height: Number(mb[4]) - Number(mb[2]) });
    const contentRefs = /\/Contents (\d+) 0 R/.exec(page.dict);
    const content = contentRefs ? objs.get(Number(contentRefs[1]))?.stream?.toString('latin1') : undefined;
    if (!content) continue;
    let cmap = new Map<number, string>();
    let cur = '';
    const ops = /\/([A-Za-z0-9]+)\s+[\d.]+\s+Tf|\[((?:<[0-9a-fA-F]*>|[^\]])*)\]\s*TJ|<([0-9a-fA-F]*)>\s*Tj|\bET\b/g;
    const decode = (hex: string): string => {
      let r = '';
      for (let i = 0; i + 4 <= hex.length; i += 4) r += cmap.get(parseInt(hex.slice(i, i + 4), 16)) ?? '';
      return r;
    };
    let m: RegExpExecArray | null;
    while ((m = ops.exec(content))) {
      if (m[1] !== undefined) {
        cmap = cmaps.get(resourceFont.get(m[1]) ?? -1) ?? new Map();
      } else if (m[2] !== undefined) {
        for (const h of m[2].matchAll(/<([0-9a-fA-F]*)>/g)) cur += decode(h[1]);
      } else if (m[3] !== undefined) {
        cur += decode(m[3]);
      } else {
        if (cur !== '') lines.push(cur.split(NBSP).join(' '));
        cur = '';
      }
    }
  }
  return { pages, fonts, lines, text: lines.join('\n') };
}
