// Сверка собранного веб-демо с прототипом экрана выбора товаров (T-UI-116; ADR-114; plan WP-QA).
//
//   node demo/web/tools/design-compare.mjs [--port 8095–8099] [--cdp <порт>] [--out <каталог>] [--storage idb|opfs]
//        [--vp 1440x900,1280x800,1920x1080,1024x768,1366x768,1536x864] [--states initial,heating,…] [--phone 777000907]
//        [--opsz 14|auto] [--keep-profile]
//   node demo/web/tools/design-compare.mjs --app-png <файл.png> [--state initial] [--out <каталог>] [--cdp <порт>]
//
// Прототип: docs/specification/visual/prototype/Main.dc.html — отдаётся из рабочего дерева перехватом CDP Fetch на
// вымышленном адресе http://design.proto/ (свой сервер и порт не нужны). Запрос Google Fonts закрывается локальным
// pos-app/assets/fonts/Inter/Inter-Variable.ttf; любые другие внешние запросы вкладки прототипа отклоняются — сети нет.
// Оптический размер: прототип запрашивает Google Fonts css2 «Inter:wght@…» без оси opsz — Google отдаёт начертание с
// opsz 14 (по умолчанию шрифта), как статические Inter приложения. Локальный вариативный файл по умолчанию рисуется
// так же (`font-optical-sizing: none` → opsz 14); `--opsz auto` — прежний эталон (opsz = кегль: H1 30/800, цены 18/800 и
// «Оптомстрой» 21/700 уже на 2–5 px). Сверено по снимку прототипа с Google Fonts (ревью V-06).
// Приложение: собранный сайт demo/web/site через tools/serve-site.mjs (заголовки как на Netlify), вход старшего
// продавца 907 В ИНТЕРФЕЙСЕ (номер → код 246810 → PIN 715382 дважды, как smoke.mjs), Chrome --headless=new, DPR 1.
//
// Состояния (обе стороны проходятся одинаковыми действиями пользователя):
//   initial  — первая посадка (у приложения — стартовая категория после входа; ждём «Сантехника»);
//   heating  — плитка «Отопление»;      sinks   — карточка ленты «Раковины»;   right1 — стрелка ленты вправо ×1;
//   list     — вид «Список»;            compact — вид «Компакт»;               filters — «Фильтры» открыты;
//   search   — поиск «90» из «Сантехники»; toast — «+ Добавить» у «Биде…» (снимок сразу); cart2 — корзина с 2 строками.
// На 1024×768, 1366×768 и 1536×864 — только initial (перенос строки управления, колонки сетки, высота ячейки 340 / 360
// по ценам ряда — ревью V-01).
//
// Что сравнивается (на каждый вид и состояние):
//   1) якоря: видимые прямоугольники элементов. Затравка — DOM-прямоугольник прототипа и прямоугольник семантики Flutter
//      приложения; видимая граница ищется ОДИНАКОВО на обоих снимках (сканирование от фона внутрь — рамка/заливка), у
//      текстов — рамка «чернил» (пиксели, отличные от фона). Допуск ±1 px;
//   2) цвета ровных заливок (точка внутри якоря, у верхней рамки) — ΔE2000 ≤ 1; «чернила» текста (самый далёкий от фона
//      пиксель) — для сведения;
//   3) средняя абсолютная разность областей (колонка, лента, строка управления, первый ряд карточек) вне масок — ≤ 4/255;
//      «первый ряд карточек» — только там, где колонок сетки столько же, сколько у прототипа (1024 — 4, 1280 — 5);
//   4) сетка «Сетка» при другом числе колонок (`tokens.json` 1.4.0, 03 §7.3 ред. 1.27; 12 T-UI-116 ред. 1.22;
//      сознательное отличие 15 ADR-114, уточнение 2026-11-18 (2)): 1366 / 1440 / 1536 / 1920 → 5 / 5 / 5 / 6 вместо
//      6 / 6 / 7 / 9 прототипа. Ожидание — `expectedGrid` (пределы `breakpoint.*.productColumnsMax`, карточка от 176 и не
//      шире 280, зазор 14, поля 8 / 24, колонка категорий 144, область шире предела — по центру; ячейка 340 или 360 —
//      «цена / шт» хотя бы одной карточки ряда не помещается при ширине своей карточки, 03 §9.11). Карточки первого ряда
//      приложения (по месту, слева направо) — к расчёту (левый край, верх ряда, ширина, высота ячейки); их блоки (фото,
//      название, «Арт.», наличие, цена, «/ шт», звезда, кнопка) — смещением от своей карточки против той же карточки
//      прототипа, перестроенного на число колонок приложения (снимок `<состояние>-proto-grid.png`; та же вёрстка карточки
//      при ширине карточки приложения). Допуск — ±1 px на каждый край (карточки стоят на дробных координатах: ширина как
//      разность краёв дала бы до 2 px сглаживания); карточки прототипа с номером ≥ колонок приложения — «сознательное отличие ADR-114 /
//      12 ред. 1.22» (не провал); средняя разница области «первый ряд карточек» на этих окнах не оценивается (запись в
//      `notes`; справочно — `regionsInfo` против перестроенного прототипа). «Список» и «Компакт» — как прежде.
// Маски (сознательные отличия ADR-114 п. 7 / паритет): «☰», индикатор синхронизации, часы и дата, имя и роль, знак
// логотипа (решение 3: оранжевый официальный), бейдж колокола, вкладка «ДЕМО», «‹‹», подборка «Недавние».
// Полосы «DEV · TEST DATA» в веб-демо нет (ADR-114 п. 9 (5)) — инструмент это проверяет и смещение не вычитает.
//
// Итог: <out>/<вид>/<состояние>-{proto,app,side,diff}.png, <out>/metrics.json, <out>/metrics.md (таблица).
// По умолчанию <out> = .tmp/design-compare/<время>. Свои сервер и браузер — по PID, профиль Chrome удаляется.
// Выкладку не делает и ничего не скачивает.
import { execFileSync, spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import net from 'node:net';
import { dirname, extname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { crc32, deflateSync, inflateSync } from 'node:zlib';

const HERE = dirname(fileURLToPath(import.meta.url)).replace(/\\/g, '/');
const WEB = resolve(HERE, '..').replace(/\\/g, '/');
const ROOT = resolve(WEB, '../..').replace(/\\/g, '/');
const PROTO_DIR = `${ROOT}/docs/specification/visual/prototype`;
const PROTO_ORIGIN = 'http://design.proto';
const FONT_TTF = `${ROOT}/pos-app/assets/fonts/Inter/Inter-Variable.ttf`;
const CHROME = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ================================================================ сетка товаров приложения (03 §7.3 ред. 1.27)
const TOKENS = JSON.parse(readFileSync(`${ROOT}/contracts/design-tokens/tokens.json`, 'utf8'));
/** Ширина колонки категорий сотрудника на данных демо, lp (03 §7.3, таблица «Окно, lp … колонка 144»; у прототипа —
 * 143,3 по ширине плиток). */
export const CATALOG_COLUMN = 144;
/** Поля карточки сетки внутри обводки по горизонтали (прототип `padding: 10px 12px 12px`; 03 §9.11) и обводка 1 + 1. */
const CARD_INNER_X = 24 + 2;
/** Класс окна по ширине (`breakpoint.*.min` / `maxExclusive` из `tokens.json`). */
export function windowClassOf(vpW, tokens = TOKENS) {
  for (const [name, b] of Object.entries(tokens.breakpoint)) if (vpW >= b.min && (b.maxExclusive == null || vpW < b.maxExclusive)) return name;
  return null;
}
/** Сетка «Сетка» SCR-10/12 сотрудника в окне шириной vpW (03 §7.3 ред. 1.27, `CatalogProductView`):
 * W = окно − колонка − поля 8 / 24; колонок = max(2, min(предел класса окна, floor((W + 14) / (176 + 14)))); карточка =
 * min(280, (W − зазоры) / колонок); область шире предела × 280 + зазоры — по центру зоны справа от колонки (полосы
 * поровну с учётом несимметричных полей, как `_bands`). Ячейка — 340, или 360, если «цена · 4 · / шт» хотя бы одной
 * карточки ряда шире карточки без полей и обводок (`kProductCardGridPriceWraps`); `prices` — ширины цены и единицы
 * карточек ряда по порядку (DOM прототипа: те же товары в том же порядке). `top` — верх ряда (блоки над сеткой — как
 * у прототипа), без него `boxes` пуст. */
export function expectedGrid(vpW, { top = null, prices = [], column = CATALOG_COLUMN, tokens = TOKENS } = {}) {
  const cat = tokens.catalog;
  const pad = cat.mainPadding;
  const gap = cat.gridGap;
  const cls = windowClassOf(vpW, tokens);
  const cap = tokens.breakpoint[cls].productColumnsMax;
  const cardMax = tokens.layout.gridCardMaxWidth;
  const W = vpW - column - pad.left - pad.right;
  const cols = Math.max(tokens.layout.gridMinColumns, Math.min(cap, Math.floor((W + gap) / (cat.gridMinCard + gap))));
  const areaMax = cap * cardMax + (cap - 1) * gap;
  const extra = Math.max(0, vpW - column - (areaMax + pad.left + pad.right));
  const start = Math.min(extra, Math.max(0, extra / 2 + (pad.right - pad.left) / 2));
  const cardW = Math.min(cardMax, (Math.min(W, areaMax) - (cols - 1) * gap) / cols);
  const left = column + start + pad.left;
  const wraps = prices.slice(0, cols).map((p) => !!p && p.unit > 0 && p.price + 4 + p.unit > cardW - CARD_INNER_X);
  const cellH = wraps.some(Boolean) ? cat.gridCardHeightWrapped : cat.gridCardHeight;
  const boxes = top == null ? [] : Array.from({ length: cols }, (_, i) => [left + i * (cardW + gap), top, cardW, cellH]);
  return { vpW, cls, cap, W, cols, gap, cardW, left, centred: extra > 0, areaWidth: cols * cardW + (cols - 1) * gap, wraps, cellH, boxes };
}

// ================================================================ PNG (без зависимостей: 8 бит, без чересстрочности)
export function pngDecode(buf) {
  if (buf.readUInt32BE(0) !== 0x89504e47) throw new Error('не PNG');
  let off = 8;
  let w = 0;
  let h = 0;
  let bd = 0;
  let ct = 0;
  let il = 0;
  let pal = null;
  let trns = null;
  const idat = [];
  while (off < buf.length) {
    const len = buf.readUInt32BE(off);
    const type = buf.toString('latin1', off + 4, off + 8);
    const data = buf.subarray(off + 8, off + 8 + len);
    off += 12 + len;
    if (type === 'IHDR') [w, h, bd, ct, il] = [data.readUInt32BE(0), data.readUInt32BE(4), data[8], data[9], data[12]];
    else if (type === 'PLTE') pal = data;
    else if (type === 'tRNS') trns = data;
    else if (type === 'IDAT') idat.push(data);
    else if (type === 'IEND') break;
  }
  if (bd !== 8 || il) throw new Error(`PNG: нужна глубина 8 без чересстрочности (bitDepth ${bd}, interlace ${il})`);
  const ch = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[ct];
  const raw = inflateSync(Buffer.concat(idat));
  const stride = w * ch;
  const out = Buffer.alloc(w * h * 4);
  let prev = Buffer.alloc(stride);
  let cur = Buffer.alloc(stride);
  for (let y = 0; y < h; y++) {
    const base = y * (stride + 1);
    const ft = raw[base];
    for (let i = 0; i < stride; i++) {
      const x = raw[base + 1 + i];
      const a = i >= ch ? cur[i - ch] : 0;
      const b = prev[i];
      const c = i >= ch ? prev[i - ch] : 0;
      let v = x;
      if (ft === 1) v = x + a;
      else if (ft === 2) v = x + b;
      else if (ft === 3) v = x + ((a + b) >> 1);
      else if (ft === 4) {
        const p = a + b - c;
        const pa = Math.abs(p - a);
        const pb = Math.abs(p - b);
        const pc = Math.abs(p - c);
        v = x + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c);
      }
      cur[i] = v & 255;
    }
    for (let xx = 0; xx < w; xx++) {
      const o = (y * w + xx) * 4;
      const s = xx * ch;
      if (ct === 6) cur.copy(out, o, s, s + 4);
      else if (ct === 2) [out[o], out[o + 1], out[o + 2], out[o + 3]] = [cur[s], cur[s + 1], cur[s + 2], 255];
      else if (ct === 0) [out[o], out[o + 1], out[o + 2], out[o + 3]] = [cur[s], cur[s], cur[s], 255];
      else if (ct === 4) [out[o], out[o + 1], out[o + 2], out[o + 3]] = [cur[s], cur[s], cur[s], cur[s + 1]];
      else if (ct === 3) {
        const k = cur[s];
        [out[o], out[o + 1], out[o + 2], out[o + 3]] = [pal[k * 3], pal[k * 3 + 1], pal[k * 3 + 2], trns && k < trns.length ? trns[k] : 255];
      }
    }
    [prev, cur] = [cur, prev];
  }
  return { width: w, height: h, data: out };
}
export function pngEncode(img) {
  const { width: w, height: h, data } = img;
  const stride = w * 4;
  const raw = Buffer.alloc((stride + 1) * h);
  for (let y = 0; y < h; y++) {
    const o = y * (stride + 1);
    raw[o] = 1; // Sub
    for (let i = 0; i < stride; i++) raw[o + 1 + i] = (data[y * stride + i] - (i >= 4 ? data[y * stride + i - 4] : 0)) & 255;
  }
  const chunk = (type, body) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(body.length);
    const tb = Buffer.concat([Buffer.from(type, 'latin1'), body]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(tb) >>> 0);
    return Buffer.concat([len, tb, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw, { level: 6 })), chunk('IEND', Buffer.alloc(0))]);
}
const newImg = (w, h, fill = [255, 255, 255, 255]) => {
  const data = Buffer.alloc(w * h * 4);
  for (let i = 0; i < w * h; i++) data.set(fill, i * 4);
  return { width: w, height: h, data };
};
export const px = (img, x, y) => {
  const xi = Math.min(img.width - 1, Math.max(0, Math.round(x)));
  const yi = Math.min(img.height - 1, Math.max(0, Math.round(y)));
  const o = (yi * img.width + xi) * 4;
  return [img.data[o], img.data[o + 1], img.data[o + 2]];
};
const blit = (dst, src, dx, dy) => {
  for (let y = 0; y < src.height && dy + y < dst.height; y++) src.data.copy(dst.data, ((dy + y) * dst.width + dx) * 4, y * src.width * 4, (y * src.width + Math.min(src.width, dst.width - dx)) * 4);
};
export const hex = (c) => `#${c.map((v) => v.toString(16).padStart(2, '0')).join('').toUpperCase()}`;
const rgbOf = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));

// ================================================================ цвет: sRGB → Lab, ΔE2000
function lab([r, g, b]) {
  const lin = (v) => ((v /= 255) <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
  const [R, G, B] = [lin(r), lin(g), lin(b)];
  const X = (0.4124564 * R + 0.3575761 * G + 0.1804375 * B) / 0.95047;
  const Y = 0.2126729 * R + 0.7151522 * G + 0.072175 * B;
  const Z = (0.0193339 * R + 0.119192 * G + 0.9503041 * B) / 1.08883;
  const f = (t) => (t > 216 / 24389 ? Math.cbrt(t) : (24389 / 27 * t + 16) / 116);
  return [116 * f(Y) - 16, 500 * (f(X) - f(Y)), 200 * (f(Y) - f(Z))];
}
export function deltaE2000(c1, c2) {
  const [L1, a1, b1] = lab(c1);
  const [L2, a2, b2] = lab(c2);
  const rad = Math.PI / 180;
  const C1 = Math.hypot(a1, b1);
  const C2 = Math.hypot(a2, b2);
  const Cm = (C1 + C2) / 2;
  const G = 0.5 * (1 - Math.sqrt(Cm ** 7 / (Cm ** 7 + 25 ** 7)));
  const a1p = (1 + G) * a1;
  const a2p = (1 + G) * a2;
  const C1p = Math.hypot(a1p, b1);
  const C2p = Math.hypot(a2p, b2);
  const h = (a, b) => (a === 0 && b === 0 ? 0 : (Math.atan2(b, a) / rad + 360) % 360);
  const h1p = h(a1p, b1);
  const h2p = h(a2p, b2);
  const dL = L2 - L1;
  const dC = C2p - C1p;
  let dh = 0;
  if (C1p * C2p !== 0) dh = Math.abs(h2p - h1p) <= 180 ? h2p - h1p : h2p - h1p > 180 ? h2p - h1p - 360 : h2p - h1p + 360;
  const dH = 2 * Math.sqrt(C1p * C2p) * Math.sin((dh / 2) * rad);
  const Lm = (L1 + L2) / 2;
  const Cmp = (C1p + C2p) / 2;
  let hm = h1p + h2p;
  if (C1p * C2p !== 0) hm = Math.abs(h1p - h2p) <= 180 ? (h1p + h2p) / 2 : h1p + h2p < 360 ? (h1p + h2p + 360) / 2 : (h1p + h2p - 360) / 2;
  const T = 1 - 0.17 * Math.cos((hm - 30) * rad) + 0.24 * Math.cos(2 * hm * rad) + 0.32 * Math.cos((3 * hm + 6) * rad) - 0.2 * Math.cos((4 * hm - 63) * rad);
  const dTheta = 30 * Math.exp(-(((hm - 275) / 25) ** 2));
  const RC = 2 * Math.sqrt(Cmp ** 7 / (Cmp ** 7 + 25 ** 7));
  const SL = 1 + (0.015 * (Lm - 50) ** 2) / Math.sqrt(20 + (Lm - 50) ** 2);
  const SC = 1 + 0.045 * Cmp;
  const SH = 1 + 0.015 * Cmp * T;
  const RT = -Math.sin(2 * dTheta * rad) * RC;
  return Math.sqrt((dL / SL) ** 2 + (dC / SC) ** 2 + (dH / SH) ** 2 + RT * (dC / SC) * (dH / SH));
}

// ================================================================ видимые границы на снимке
const dist = (a, b) => Math.max(Math.abs(a[0] - b[0]), Math.abs(a[1] - b[1]), Math.abs(a[2] - b[2]));
const clampRect = (img, [x, y, w, h]) => {
  const x0 = Math.max(0, Math.floor(x));
  const y0 = Math.max(0, Math.floor(y));
  return [x0, y0, Math.max(0, Math.min(img.width, Math.ceil(x + w)) - x0), Math.max(0, Math.min(img.height, Math.ceil(y + h)) - y0)];
};
/** Видимая коробка элемента с рамкой или заливкой: от затравки [x,y,w,h] — расширение pad, фон берётся в углу окна,
 * края — первый пиксель, отличный от фона больше чем на tol (5: ловит и рамку 1 px с дробной координатой), при сканировании снаружи внутрь по средней строке/столбцу
 * (и по строкам/столбцам на ¼ и ¾ — берётся крайний). `masks` — строки и столбцы сканирования, пересекающие маску в окне
 * (вкладка «ДЕМО» у правого края окна над крайней карточкой сетки), пропускаются, пока остаётся хотя бы одна. */
export function visibleBox(img, seed, { pad = 6, tol = 5, bg = null, masks = null } = {}) {
  if (!seed) return null;
  const [x0, y0, w, h] = clampRect(img, [seed[0] - pad, seed[1] - pad, seed[2] + 2 * pad, seed[3] + 2 * pad]);
  if (w < 3 || h < 3) return null;
  const back = bg ?? px(img, x0, y0);
  const hits = (x, y, ww, hh) => !!masks?.some((m) => m[0] < x + ww && m[0] + m[2] > x && m[1] < y + hh && m[1] + m[3] > y);
  const free = (list, pred) => (list.filter(pred).length ? list.filter(pred) : list);
  const rows = free([0.25, 0.5, 0.75].map((f) => y0 + Math.round(h * f)), (y) => !hits(x0, y, w, 1));
  const cols = free([0.25, 0.5, 0.75].map((f) => x0 + Math.round(w * f)), (x) => !hits(x, y0, 1, h));
  let L = Infinity;
  let R = -Infinity;
  let T = Infinity;
  let B = -Infinity;
  for (const y of rows) {
    for (let x = x0; x < x0 + w; x++) if (dist(px(img, x, y), back) > tol) { L = Math.min(L, x); break; }
    for (let x = x0 + w - 1; x >= x0; x--) if (dist(px(img, x, y), back) > tol) { R = Math.max(R, x + 1); break; }
  }
  for (const x of cols) {
    for (let y = y0; y < y0 + h; y++) if (dist(px(img, x, y), back) > tol) { T = Math.min(T, y); break; }
    for (let y = y0 + h - 1; y >= y0; y--) if (dist(px(img, x, y), back) > tol) { B = Math.max(B, y + 1); break; }
  }
  if (!Number.isFinite(L) || !Number.isFinite(T)) return null;
  return [L, T, R - L, B - T];
}
/** Коробка кнопки по заливке: цвет берётся у левого края затравки (поле кнопки без текста), края — где заливка
 * кончается по строке центра и по столбцу на 15 % ширины (вне текста и скругления). Для кнопок, у которых цель касания
 * больше видимой части, а рядом — разделители строк (у visibleBox окно ловит разделитель). */
export function fillBox(img, seed, { tol = 10 } = {}) {
  if (!seed) return null;
  const cy = Math.round(seed[1] + seed[3] / 2);
  const sx = Math.round(seed[0] + Math.max(6, seed[2] * 0.15));
  const fill = px(img, sx, cy);
  let L = sx;
  let R = sx;
  let T = cy;
  let Bt = cy;
  while (L > 0 && dist(px(img, L - 1, cy), fill) <= tol) L--;
  while (R < img.width - 1 && dist(px(img, R + 1, cy), fill) <= tol && R - L < seed[2] + 40) R++;
  while (T > 0 && dist(px(img, sx, T - 1), fill) <= tol) T--;
  while (Bt < img.height - 1 && dist(px(img, sx, Bt + 1), fill) <= tol && Bt - T < seed[3] + 40) Bt++;
  // по строке центра у заливки может стоять текст справа от 15 % — правый край ищем с правой стороны затравки
  const rx = Math.round(seed[0] + seed[2] - Math.max(6, seed[2] * 0.15));
  if (dist(px(img, rx, cy), fill) <= tol) {
    R = rx;
    while (R < img.width - 1 && dist(px(img, R + 1, cy), fill) <= tol && R - L < seed[2] + 40) R++;
  }
  return [L, T, R - L + 1, Bt - T + 1];
}
/** Рамка «чернил»: все пиксели окна, отличные от фона (угол окна) больше чем на tol. */
export function inkBox(img, win, { tol = 40, bg = null } = {}) {
  if (!win) return null;
  const [x0, y0, w, h] = clampRect(img, win);
  if (w < 1 || h < 1) return null;
  const back = bg ?? px(img, x0, y0);
  let L = Infinity;
  let R = -Infinity;
  let T = Infinity;
  let B = -Infinity;
  let far = null;
  let farD = -1;
  for (let y = y0; y < y0 + h; y++)
    for (let x = x0; x < x0 + w; x++) {
      const p = px(img, x, y);
      const d = dist(p, back);
      if (d > tol) {
        L = Math.min(L, x);
        R = Math.max(R, x + 1);
        T = Math.min(T, y);
        B = Math.max(B, y + 1);
        if (d > farD) [farD, far] = [d, p];
      }
    }
  if (!Number.isFinite(L)) return null;
  return { box: [L, T, R - L, B - T], ink: far ? hex(far) : null, bg: hex(back) };
}
/** Средняя абсолютная разность (0…255) по RGB в прямоугольнике вне масок. */
export function regionMad(a, b, rect, masks = []) {
  const [x0, y0, w, h] = clampRect(a, rect);
  let sum = 0;
  let n = 0;
  for (let y = y0; y < y0 + h; y++)
    for (let x = x0; x < x0 + w; x++) {
      if (masks.some((m) => x >= m[0] && x < m[0] + m[2] && y >= m[1] && y < m[1] + m[3])) continue;
      const p = px(a, x, y);
      const q = px(b, x, y);
      sum += Math.abs(p[0] - q[0]) + Math.abs(p[1] - q[1]) + Math.abs(p[2] - q[2]);
      n += 3;
    }
  return n ? Math.round((sum / n) * 100) / 100 : null;
}
/** Сравнение рядом: прототип | приложение | тепловая карта разности (маски — штриховка). */
export function sideBySide(a, b, masks = []) {
  const w = Math.max(a.width, b.width);
  const h = Math.max(a.height, b.height);
  const gap = 12;
  const out = newImg(w * 3 + gap * 2, h, [40, 44, 60, 255]);
  blit(out, a, 0, 0);
  blit(out, b, w + gap, 0);
  const d = diffImage(a, b, masks);
  blit(out, d, (w + gap) * 2, 0);
  return { side: out, diff: d };
}
export function diffImage(a, b, masks = []) {
  const w = Math.min(a.width, b.width);
  const h = Math.min(a.height, b.height);
  const out = newImg(w, h);
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++) {
      const o = (y * w + x) * 4;
      const p = px(a, x, y);
      const q = px(b, x, y);
      const gray = Math.round((q[0] * 0.3 + q[1] * 0.59 + q[2] * 0.11) * 0.25 + 190);
      const d = dist(p, q);
      let c = [gray, gray, gray];
      if (masks.some((m) => x >= m[0] && x < m[0] + m[2] && y >= m[1] && y < m[1] + m[3])) c = (x + y) % 8 < 4 ? [150, 170, 210] : [205, 215, 235];
      else if (d > 96) c = [200, 0, 0];
      else if (d > 48) c = [240, 90, 20];
      else if (d > 16) c = [250, 200, 40];
      out.data.set([...c, 255], o);
    }
  return out;
}

// ================================================================ CDP
export async function startBrowser({ cdp, profile, extraArgs = [] }) {
  mkdirSync(profile, { recursive: true });
  const proc = spawn(CHROME, ['--headless=new', `--remote-debugging-port=${cdp}`, `--user-data-dir=${profile}`, '--window-size=1440,900', '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-background-networking', '--disable-component-update', '--disable-sync', '--disable-default-apps', '--hide-scrollbars', '--force-color-profile=srgb', '--disable-lcd-text', '--disable-background-timer-throttling', '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows', '--lang=ru', ...extraArgs, 'about:blank'], { stdio: 'ignore' });
  let ver = null;
  for (let i = 0; i < 120 && !ver; i++) {
    try {
      ver = await (await fetch(`http://127.0.0.1:${cdp}/json/version`)).json();
    } catch {
      await sleep(250);
    }
  }
  if (!ver) throw new Error('CDP не поднялся');
  const ws = new WebSocket(ver.webSocketDebuggerUrl);
  await new Promise((r, j) => ((ws.onopen = r), (ws.onerror = j)));
  const pending = new Map();
  const handlers = new Set();
  let seq = 0;
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) {
      const p = pending.get(m.id);
      pending.delete(m.id);
      if (m.error) p.rej(new Error(`${p.method}: ${JSON.stringify(m.error)}`));
      else p.res(m.result);
      return;
    }
    for (const h of handlers) h(m);
  };
  const send = (method, params = {}, sessionId) =>
    new Promise((res, rej) => {
      const id = ++seq;
      pending.set(id, { res, rej, method });
      ws.send(JSON.stringify(sessionId ? { id, method, params, sessionId } : { id, method, params }));
    });
  return { proc, ws, send, handlers, version: ver.Browser };
}
export async function openTab(B, { w = 1440, h = 900 } = {}) {
  const { targetId } = await B.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await B.send('Target.attachToTarget', { targetId, flatten: true });
  const tab = { targetId, sid: sessionId, B, errors: [], exceptions: [] };
  B.handlers.add((m) => {
    if (m.sessionId !== sessionId) return;
    if (m.method === 'Runtime.exceptionThrown') tab.exceptions.push(String(m.params.exceptionDetails.exception?.description ?? m.params.exceptionDetails.text).slice(0, 400));
    if (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'error') tab.errors.push(m.params.args.map((a) => a.value ?? a.description ?? '').join(' ').slice(0, 400));
  });
  await Promise.all([B.send('Runtime.enable', {}, sessionId), B.send('Page.enable', {}, sessionId)]);
  await setViewport(tab, w, h);
  return tab;
}
export const setViewport = (tab, w, h) => tab.B.send('Emulation.setDeviceMetricsOverride', { width: w, height: h, deviceScaleFactor: 1, mobile: false }, tab.sid);
export async function ev(tab, expression, timeoutMs = 60000) {
  const r = await Promise.race([tab.B.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, tab.sid), sleep(timeoutMs).then(() => ({ timeout: true }))]);
  if (r.timeout) throw new Error(`timeout ${timeoutMs} мс: ${expression.slice(0, 100)}`);
  if (r.exceptionDetails) throw new Error(`${r.exceptionDetails.text} ${r.exceptionDetails.exception?.description ?? ''}`.slice(0, 600));
  return r.result.value;
}
export async function waitFor(tab, expr, timeoutMs, label) {
  const end = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < end) {
    try {
      const v = await ev(tab, expr, 10000);
      if (v) return v;
    } catch (e) {
      last = e;
    }
    await sleep(200);
  }
  throw new Error(`не дождались: ${label}${last ? ` (${String(last.message).slice(0, 200)})` : ''}`);
}
export async function capture(tab) {
  const r = await tab.B.send('Page.captureScreenshot', { format: 'png' }, tab.sid);
  return Buffer.from(r.data, 'base64');
}
export async function click(tab, x, y) {
  await tab.B.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y }, tab.sid);
  await tab.B.send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', clickCount: 1 }, tab.sid);
  await tab.B.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', clickCount: 1 }, tab.sid);
}
export const hover = (tab, x, y) => tab.B.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y }, tab.sid);
export async function key(tab, k, { code = k, vk = 0, modifiers = 0 } = {}) {
  await tab.B.send('Input.dispatchKeyEvent', { type: 'keyDown', key: k, code, windowsVirtualKeyCode: vk, modifiers }, tab.sid);
  await tab.B.send('Input.dispatchKeyEvent', { type: 'keyUp', key: k, code, windowsVirtualKeyCode: vk, modifiers }, tab.sid);
}
export const typeText = (tab, text) => tab.B.send('Input.insertText', { text }, tab.sid);
export const killTree = (pid) => {
  try {
    execFileSync('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore' });
  } catch {
    /* уже завершён */
  }
};
export const portFree = (p) =>
  new Promise((res) => {
    const s = net.createServer();
    s.once('error', () => res(false));
    s.listen(p, '127.0.0.1', () => s.close(() => res(true)));
  });

// ================================================================ прототип
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.png': 'image/png', '.css': 'text/css', '.svg': 'image/svg+xml', '.json': 'application/json' };
/** Вкладка прототипа: файлы — из docs/specification/visual/prototype, шрифт — локальный, остальное отклоняется. */
export async function protoTab(B, vp, { opsz = '14' } = {}) {
  const tab = await openTab(B, vp);
  const font = readFileSync(FONT_TTF).toString('base64');
  // opsz 14 — как Google Fonts css2 без оси opsz (см. шапку); `auto` — opsz по кеглю.
  const opszCss = opsz === 'auto' ? '' : '*,*::before,*::after{font-optical-sizing:none !important;}';
  const fontCss = Buffer.from(`@font-face{font-family:'Inter';font-style:normal;font-weight:100 900;font-display:swap;src:url(https://fonts.gstatic.com/local/InterVariable.ttf) format('truetype');}${opszCss}`).toString('base64');
  tab.blocked = [];
  B.handlers.add((m) => {
    if (m.sessionId !== tab.sid || m.method !== 'Fetch.requestPaused') return;
    const { requestId, request } = m.params;
    const u = request.url;
    const hdr = (t) => [{ name: 'Content-Type', value: t }, { name: 'Access-Control-Allow-Origin', value: '*' }];
    if (u.startsWith(`${PROTO_ORIGIN}/`)) {
      const p = decodeURIComponent(new URL(u).pathname).replace(/^\/+/, '');
      const f = resolve(PROTO_DIR, p).replace(/\\/g, '/');
      if (!f.startsWith(PROTO_DIR) || !existsSync(f)) return void B.send('Fetch.fulfillRequest', { requestId, responseCode: 404, responseHeaders: hdr('text/plain'), body: '' }, tab.sid);
      return void B.send('Fetch.fulfillRequest', { requestId, responseCode: 200, responseHeaders: hdr(MIME[extname(f)] ?? 'application/octet-stream'), body: readFileSync(f).toString('base64') }, tab.sid);
    }
    if (u.includes('fonts.googleapis.com')) return void B.send('Fetch.fulfillRequest', { requestId, responseCode: 200, responseHeaders: hdr('text/css'), body: fontCss }, tab.sid);
    if (u.includes('fonts.gstatic.com')) return void B.send('Fetch.fulfillRequest', { requestId, responseCode: 200, responseHeaders: hdr('font/ttf'), body: font }, tab.sid);
    tab.blocked.push(u.slice(0, 160));
    B.send('Fetch.failRequest', { requestId, errorReason: 'BlockedByClient' }, tab.sid);
  });
  await B.send('Fetch.enable', { patterns: [{ urlPattern: '*', requestStage: 'Request' }] }, tab.sid);
  return tab;
}
export async function protoLoad(tab, w, h) {
  await setViewport(tab, w, h);
  await tab.B.send('Page.navigate', { url: `${PROTO_ORIGIN}/Main.dc.html` }, tab.sid);
  await waitFor(tab, `!!document.querySelector('#dc-root h1') && document.fonts.status === 'loaded' && [...document.images].every((i) => i.complete)`, 30000, 'прототип загружен');
  await ev(tab, PROTO_MEASURE);
  await sleep(250);
}
const PQ = {
  tile: (n) => `[...document.querySelectorAll('nav button.tile')].find((b) => b.textContent.trim() === ${JSON.stringify(n)})`,
  sub: (n) => `[...document.querySelectorAll('main .strip button')].find((b) => b.textContent.trim() === ${JSON.stringify(n)})`,
  btn: (t) => `[...document.querySelectorAll('button')].find((b) => b.textContent.replace(/\\s+/g, ' ').trim() === ${JSON.stringify(t)})`,
  aria: (l) => `document.querySelector('button[aria-label="${l}"]')`,
  card: (p) => `[...document.querySelectorAll('article.card')].find((a) => a.textContent.includes(${JSON.stringify(p)}))`,
};
const pclick = (tab, js) => ev(tab, `(() => { const el = ${js}; if (!el) throw new Error('нет элемента: ' + ${JSON.stringify(js)}); el.click(); return true; })()`);
async function protoSearch(tab, text) {
  await ev(tab, `(() => { const i = document.querySelector('header input[type=search]'); i.focus();
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(i, ${JSON.stringify(text)});
    i.dispatchEvent(new Event('input', { bubbles: true })); return true; })()`);
  await sleep(300);
}
/** Действия состояния на прототипе (как у пользователя). Возвращает задержку перед снимком. */
export async function protoState(tab, state, w, h) {
  await protoLoad(tab, w, h);
  if (state === 'heating') await pclick(tab, PQ.tile('Отопление'));
  else if (state === 'sinks') await pclick(tab, PQ.sub('Раковины'));
  else if (state === 'right1') await pclick(tab, PQ.aria('Прокрутить подкатегории вправо'));
  else if (state === 'list') await pclick(tab, PQ.btn('Список'));
  else if (state === 'compact') await pclick(tab, PQ.btn('Компакт'));
  else if (state === 'filters') await pclick(tab, PQ.btn('Фильтры'));
  else if (state === 'search') await protoSearch(tab, '90');
  else if (state === 'toast') {
    await pclick(tab, `${PQ.card('Биде')}.querySelector('button.add')`);
    await sleep(150);
    return;
  } else if (state === 'cart2') {
    await pclick(tab, `${PQ.card('Биде')}.querySelector('button.add')`);
    await pclick(tab, `${PQ.card('Ванна')}.querySelector('button.add')`);
    await sleep(2600); // тост «Добавлено» прототипа (2,2 с) успевает уйти, как у приложения
    await pclick(tab, PQ.aria('Открыть корзину'));
  }
  await sleep(450);
}
/** Ожидание сетки приложения для состояния прототипа (protoA — якоря прототипа как есть) в окне шириной vpW: null, если
 * в состоянии нет карточек сетки или колонок столько же, сколько у прототипа (1024, 1280 — прежняя сверка). Иначе —
 * `expectedGrid` (верх ряда и цены — по прототипу) и прототип, перестроенный на те же колонки (`protoA2`, `protoPng2`). */
export async function protoGrid(tab, protoA, vpW) {
  if (!protoA['card0:box'] || !protoA.__gridCols) return null;
  if (expectedGrid(vpW).cols === protoA.__gridCols) return null;
  const prices = [];
  for (let i = 0; protoA[`card${i}:box`]; i++) prices.push({ price: protoA[`card${i}:price`]?.[2] ?? 0, unit: protoA[`card${i}:unit`]?.[2] ?? 0 });
  const g = expectedGrid(vpW, { top: protoA['card0:box'][1], prices });
  const box = g.centred ? { width: g.areaWidth, shift: g.left - protoA['card0:box'][0] } : null;
  const got = await ev(tab, `window.__relayGrid(${g.cols}, ${JSON.stringify(box)})`);
  await sleep(250);
  const protoA2 = await ev(tab, 'window.__anchors()');
  const protoPng2 = await capture(tab);
  await ev(tab, 'window.__restoreGrid()');
  await sleep(100);
  return { ...g, protoCols: protoA.__gridCols, relayCols: got, protoA2, protoPng2 };
}
/** Прямоугольники прототипа (DOM, CSS px) по именам якорей — те же имена, что у приложения. */
const PROTO_MEASURE = `window.__anchors = function () {
  const R = (el) => { if (!el) return null; const r = el.getBoundingClientRect(); return [r.left, r.top, r.width, r.height].map((v) => Math.round(v * 10) / 10); };
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const css = (el, p) => (el ? getComputedStyle(el)[p] : null);
  const A = {};
  const header = $('header');
  A.header = R(header);
  A['logo.mark'] = R($('img', header.children[0]));
  A['logo.word'] = R($('span', header.children[0]));
  A.logo = R(header.children[0]);
  A['search.field'] = R($('label', header));
  A['cart.chip'] = R($('button[aria-label="Открыть корзину"]'));
  A.bell = R($('button[aria-label^="Уведомления"]'));
  const user = header.children[2].lastElementChild;
  A['user.avatar'] = R(user.children[0]);
  A['user.block'] = R(user);
  const nav = $('nav');
  A.column = R(nav);
  A['column.title'] = R($('h2', nav));
  const tiles = $$('button.tile', nav);
  tiles.forEach((b) => { A['tile:' + b.textContent.trim()] = R(b); });
  const main = $('main');
  A.title = R($('h1', main));
  const strip = $('.strip', main);
  if (strip) {
    A.ribbon = R(strip);
    const sr = strip.getBoundingClientRect();
    $$('button', strip).forEach((b) => { const r = b.getBoundingClientRect(); if (r.right > sr.left + 1 && r.left < sr.right - 1) A['sub:' + b.textContent.trim().replace(/\\s+/g, ' ')] = R(b); });
    A['ribbon.right'] = R($('button[aria-label="Прокрутить подкатегории вправо"]'));
    A['ribbon.left'] = R($('button[aria-label="Прокрутить подкатегории влево"]'));
  }
  const group = $('[role=group]', main);
  const toolbar = group.parentElement.parentElement;
  A.toolbar = R(toolbar);
  $$(':scope > button', toolbar.children[0]).forEach((b) => { A['chip:' + b.textContent.trim()] = R(b); });
  A.found = R($(':scope > span', toolbar.children[0]));
  A.segment = R(group);
  $$('button', group).forEach((b) => { A['seg:' + b.textContent.trim()] = R(b); });
  A.sort = R($('button[aria-label="Сортировка: сменить порядок"]'));
  A.filtersBtn = R(toolbar.children[1].lastElementChild);
  const fp = $('main input[type=checkbox]');
  if (fp) { A.filterPanel = R(fp.closest('label').parentElement); A['filter.check'] = R(fp); A['filter.reset'] = R(fp.closest('label').nextElementSibling); }
  const grid = $$('div', main).find((d) => getComputedStyle(d).display === 'grid' && d.querySelector('article'));
  if (grid) A.__gridCols = getComputedStyle(grid).gridTemplateColumns.split(' ').filter(Boolean).length;
  const cards = grid ? $$('article.card', grid) : [];
  const top = cards.length ? cards[0].getBoundingClientRect().top : 0;
  cards.forEach((a, i) => {
    const r = a.getBoundingClientRect(); if (Math.abs(r.top - top) > 2) return;
    const k = [...a.children]; const p = 'card' + i + ':';
    A[p + 'box'] = R(a); A[p + 'img'] = R(k[1]); A[p + 'name'] = R($('h3', a)); A[p + 'sku'] = R(k[3]); A[p + 'stock'] = R(k[4]);
    A[p + 'price'] = R(k[5].children[0]); A[p + 'unit'] = R(k[5].children[1]); A[p + 'button'] = R($$('button', a)[1]); A[p + 'star'] = R($$('button', a)[0]);
    A[p + 'title'] = $('h3', a).textContent;
  });
  const listWrap = $$('div', main).find((d) => getComputedStyle(d).flexDirection === 'column' && d.querySelector(':scope > article'));
  if (listWrap) $$(':scope > article', listWrap).slice(0, 3).forEach((a, i) => { const k = a.children; const p = 'row' + i + ':';
    A[p + 'box'] = R(a); A[p + 'img'] = R(k[0]); A[p + 'name'] = R(k[1].children[0]); A[p + 'sku'] = R(k[1].children[1]); A[p + 'stock'] = R(k[2]); A[p + 'price'] = R(k[3].children[0]); A[p + 'button'] = R(k[4]); A[p + 'title'] = k[1].children[0].textContent; });
  const ci = $('main [style*="min-width: 720px"]');
  if (ci) { A.compactTable = R(ci.parentElement); A.compactHead = R(ci.children[0]);
    [...ci.children].slice(1, 4).forEach((r, i) => { const c = [...r.children]; const p = 'crow' + i + ':'; A[p + 'box'] = R(r); A[p + 'sku'] = R(c[0]); A[p + 'name'] = R(c[1]); A[p + 'stock'] = R(c[2]); A[p + 'price'] = R(c[3]); A[p + 'button'] = R(c[4]); A[p + 'title'] = c[1].textContent; }); }
  const toast = $('[role=status]');
  if (toast) A.toast = R(toast);
  const aside = $('aside[aria-label="Корзина"]');
  if (aside) { const k = aside.children; A.drawer = R(aside); A['drawer.head'] = R(k[0]); A['drawer.title'] = R($('h2', k[0])); A['drawer.close'] = R($('button', k[0])); A['drawer.client'] = R(k[1]);
    $$(':scope > div[style*="border-bottom"]', k[2]).forEach((l, i) => { const p = 'line' + i + ':'; A[p + 'box'] = R(l); A[p + 'img'] = R(l.children[0]); A[p + 'name'] = R(l.children[1].children[0].children[0]); A[p + 'stepper'] = R(l.children[1].children[1].children[0]); A[p + 'sum'] = R(l.children[1].children[1].children[1]); A[p + 'title'] = l.children[1].children[0].children[0].textContent.trim(); });
    A['drawer.foot'] = R(k[3]); const fb = $$('button', k[3]); fb.forEach((b, i) => { A['drawer.btn' + i] = R(b); }); }
  A.__css = { page: css(document.body, 'backgroundColor'), header: css(header, 'backgroundColor'), h1: css($('h1', main), 'color') };
  A.__h1 = $('h1', main).textContent;
  return A;
};
// Сетка прототипа на N колонок приложения (12 T-UI-116 ред. 1.22): только для ожиданий блоков карточки при ширине
// карточки приложения; снимок прототипа как есть делается до перестройки, __restoreGrid возвращает разметку.
window.__relayGrid = async function (cols, box) {
  const main = document.querySelector('main');
  const grid = [...main.querySelectorAll('div')].find((d) => getComputedStyle(d).display === 'grid' && d.querySelector('article'));
  if (!grid) return false;
  window.__gridSaved = { el: grid, style: grid.getAttribute('style') };
  grid.style.gridTemplateColumns = 'repeat(' + cols + ', minmax(0, 1fr))';
  if (box) { grid.style.width = box.width + 'px'; grid.style.marginLeft = box.shift + 'px'; }
  await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  return getComputedStyle(grid).gridTemplateColumns.split(' ').filter(Boolean).length;
};
window.__restoreGrid = function () {
  const s = window.__gridSaved; if (!s) return false;
  if (s.style == null) s.el.removeAttribute('style'); else s.el.setAttribute('style', s.style);
  window.__gridSaved = null; return true;
}; true;`;

// ================================================================ приложение (сайт веб-демо)
export function startSite(port) {
  const proc = spawn(process.execPath, [`${HERE}/serve-site.mjs`, '--port', String(port), '--quiet'], { stdio: ['ignore', 'pipe', 'pipe'] });
  return proc;
}
export const appReady = (tab, ms = 120000) => waitFor(tab, `!!(window.__posDemo && __posDemo.isReady && window.PosDemoPage && PosDemoPage.boot.hidden && document.getElementById('pos-demo-fab'))`, ms, 'демо готово');
export const semanticsOn = async (tab) => {
  await waitFor(tab, `!!document.querySelector('flt-semantics-placeholder') || document.querySelectorAll('flt-semantics').length > 3`, 20000, 'семантика Flutter');
  await ev(tab, `(document.querySelector('flt-semantics-placeholder') && document.querySelector('flt-semantics-placeholder').click(), true)`);
  await waitFor(tab, `document.querySelectorAll('flt-semantics').length > 3`, 15000, 'семантика включена');
};
/** Узлы семантики Flutter: подпись (aria-label или текст листа), роль, прямоугольник, флаги. */
export const semNodes = (tab) =>
  ev(
    tab,
    `[...document.querySelectorAll('flt-semantics, flt-semantics *, input, textarea')].map((n) => { const r = n.getBoundingClientRect();
      const label = (n.getAttribute('aria-label') || n.getAttribute('placeholder') || n.textContent || '').replace(/\\s+/g, ' ').trim();
      return { label, tag: n.tagName.toLowerCase(), role: n.getAttribute('role') || '', pressed: n.getAttribute('aria-pressed'), checked: n.getAttribute('aria-checked'), selected: n.getAttribute('aria-selected'), current: n.getAttribute('aria-current'), disabled: n.getAttribute('aria-disabled'), heading: /^h\\d$/i.test(n.tagName) || n.getAttribute('role') === 'heading',
        rect: [r.left, r.top, r.width, r.height].map((v) => Math.round(v * 10) / 10) }; }).filter((n) => n.rect[2] > 1 && n.rect[3] > 1)`,
  );
/** Центр наименьшего узла семантики, подпись которого удовлетворяет pred (строка — вхождение, RegExp — проверка). */
export async function semFind(tab, want, { exact = false, role = null } = {}) {
  const nodes = await semNodes(tab);
  const ok = (l) => (want instanceof RegExp ? want.test(l) : exact ? l === want : l.includes(want));
  const hits = nodes.filter((n) => ok(n.label) && (!role || n.role === role)).sort((a, b) => a.rect[2] * a.rect[3] - b.rect[2] * b.rect[3]);
  return hits[0] ?? null;
}
export async function semClick(tab, want, opts) {
  const n = await semFind(tab, want, opts);
  if (!n) throw new Error(`нет узла семантики «${want}»`);
  await click(tab, n.rect[0] + n.rect[2] / 2, n.rect[1] + n.rect[3] / 2);
  return n;
}
/** Вход в ИНТЕРФЕЙСЕ: номер → «Получить код» → 246810 → PIN дважды → согласие → «Начать работу». */
export async function uiLogin(tab, origin, { phone = '777000907', pin = '715382', storage = 'idb', log = () => {} } = {}) {
  await tab.B.send('Page.navigate', { url: `${origin}/?storage=${storage}&envcheck=0` }, tab.sid);
  await appReady(tab);
  await semanticsOn(tab);
  await waitFor(tab, `document.body.innerHTML.includes('Получить код')`, 30000, 'SCR-01');
  const field = await semFind(tab, 'Номер телефона');
  const submit = await semFind(tab, 'Получить код');
  // ввод кода с включённой семантикой не работает (OtpField) — перезагрузка: ввод по координатам
  await tab.B.send('Page.reload', {}, tab.sid);
  await appReady(tab);
  await sleep(1500);
  await click(tab, field.rect[0] + field.rect[2] / 2, field.rect[1] + field.rect[3] / 2);
  await sleep(500);
  await typeText(tab, phone);
  await sleep(600);
  await click(tab, submit.rect[0] + submit.rect[2] / 2, submit.rect[1] + submit.rect[3] / 2);
  await waitFor(tab, `PosDemoPage.bridge._stats.statuses['202'] >= 1`, 15000, 'otp/request 202');
  await sleep(1500);
  await typeText(tab, '246810');
  await waitFor(tab, `(PosDemoPage.bridge._stats.statuses['200'] || 0) >= 2`, 15000, 'otp/verify 200');
  await sleep(2500);
  await semanticsOn(tab);
  await waitFor(tab, `document.body.innerHTML.includes('PIN')`, 15000, 'экран PIN');
  const digits = async () => {
    for (const d of pin) {
      await semClick(tab, d, { exact: true });
      await sleep(180);
    }
  };
  await digits();
  await sleep(1200);
  if (await ev(tab, `document.body.innerHTML.includes('Повторите') || document.body.innerHTML.includes('ещё раз')`)) {
    await digits();
    await sleep(1200);
  }
  const consent = await semFind(tab, 'Я ознакомлен');
  if (consent) {
    await click(tab, consent.rect[0] + consent.rect[2] / 2, consent.rect[1] + consent.rect[3] / 2);
    await sleep(600);
  }
  const start = await semFind(tab, 'Начать работу');
  if (start) await click(tab, start.rect[0] + start.rect[2] / 2, start.rect[1] + start.rect[3] / 2);
  await waitFor(tab, `(PosDemoPage.bridge._stats.statuses['204'] || 0) >= 1`, 15000, 'POST /me/pin 204');
  log('вход выполнен');
  await sleep(3000);
  await semanticsOn(tab).catch(() => undefined);
  await waitIdle(tab);
}
/** Дождаться конца начальной загрузки каталога (полоса «Загружаем каталог… N %» сдвигает экран на 40) и покоя раскладки. */
export async function waitIdle(tab, ms = 120000) {
  const end = Date.now() + ms;
  let prev = null;
  while (Date.now() < end) {
    const nodes = await semNodes(tab).catch(() => []);
    const busy = nodes.some((n) => /Загружаем каталог/.test(n.label));
    const sig = JSON.stringify(nodes.filter((n) => n.tag === 'flt-semantics' && n.role).map((n) => n.rect));
    if (!busy && sig === prev) return true;
    prev = busy ? null : sig;
    await sleep(500);
  }
  throw new Error('не дождались покоя раскладки (загрузка каталога)');
}
export const hashOf = (tab) => ev(tab, 'location.hash');
export async function go(tab, path) {
  await ev(tab, `(location.hash = ${JSON.stringify(`#${path}`)}, true)`);
  await sleep(1200);
}

// ================================================================ сравнение якорей
/** Якорь приложения по имени — из узлов семантики (затравка; видимая коробка ищется по пикселям). */
export function appAnchors(nodes, protoA) {
  const A = {};
  // узел семантики (flt-semantics), а не вложенный span текста; при равенстве — наименьший
  const find = (pred) => nodes.filter(pred).sort((a, b) => (a.tag === 'flt-semantics' ? 0 : 1e9) - (b.tag === 'flt-semantics' ? 0 : 1e9) + a.rect[2] * a.rect[3] - b.rect[2] * b.rect[3])[0]?.rect ?? null;
  const starts = (s) => (n) => n.label === s || n.label.startsWith(`${s},`) || n.label.startsWith(`${s} `) || n.label.startsWith(`${s}:`);
  for (const k of Object.keys(protoA)) {
    if (k.startsWith('tile:')) A[k] = find((n) => starts(k.slice(5))(n) && n.rect[0] < 200);
    else if (k.startsWith('sub:')) A[k] = find((n) => starts(k.slice(4))(n) && n.rect[1] > 100 && n.rect[1] < 330 && n.rect[0] > 120);
    else if (k.startsWith('chip:')) A[k] = find(starts(k.slice(5)));
    else if (k.startsWith('seg:')) A[k] = find(starts(k.slice(4)));
  }
  A['column.title'] = find((n) => n.heading && /^Каталог/.test(n.label) && n.rect[0] < 200 && n.rect[1] < 140);
  A.title = find((n) => n.heading && n.rect[1] < 160 && n.rect[0] > 120);
  A.found = find((n) => /^Найдено/.test(n.label));
  A.sort = find((n) => /^(Сортировка|По названию|Сначала|По цене|По популярности|Новые сверху)/.test(n.label) && n.rect[1] > 250);
  A.filtersBtn = find((n) => /^Фильтры/.test(n.label));
  A['cart.chip'] = find((n) => /Открыть корзину/.test(n.label) && n.rect[1] < 70);
  A.bell = find((n) => /^Уведомлени/.test(n.label) && n.rect[1] < 70);
  A['search.field'] = find((n) => /^Поиск товара/.test(n.label) && n.rect[1] < 70);
  A['ribbon.right'] = find((n) => /вправо|Следующие|Прокрутить.*вправо/i.test(n.label));
  A['ribbon.left'] = find((n) => /влево|Предыдущие|Прокрутить.*влево/i.test(n.label));
  for (let i = 0; i < 9; i++) {
    const t = protoA[`card${i}:title`] ?? protoA[`row${i}:title`] ?? protoA[`crow${i}:title`];
    if (!t) continue;
    const pre = protoA[`card${i}:title`] ? `card${i}:` : protoA[`row${i}:title`] ? `row${i}:` : `crow${i}:`;
    A[`${pre}box`] = cardNode(nodes, t)?.rect ?? null;
    A[`${pre}button`] = find((n) => n.role === 'button' && /^(\+ ?Добавить|Добавить|В корзине|Ещё|Нет в наличии|Нет$|Выбрать вариант)/.test(n.label) && A[`${pre}box`] && n.rect[0] >= A[`${pre}box`][0] - 2 && n.rect[0] + n.rect[2] <= A[`${pre}box`][0] + A[`${pre}box`][2] + 2 && n.rect[1] >= A[`${pre}box`][1] - 2 && n.rect[1] + n.rect[3] <= A[`${pre}box`][1] + A[`${pre}box`][3] + 2);
  }
  A.logo = find((n) => /^Логотип/.test(n.label) && n.rect[1] < 70);
  A.toast = find((n) => /^Добавлено/.test(n.label) && n.rect[3] < 80);
  A.drawer = nodes.find((n) => n.tag === 'flt-semantics' && n.label === 'Корзина' && n.rect[3] > 500)?.rect ?? null;
  A['drawer.title'] = find((n) => n.heading && /^Корзина/.test(n.label));
  A['drawer.close'] = find((n) => n.role === 'button' && /^Закрыть корзину/.test(n.label));
  A['drawer.client'] = find((n) => n.role === 'button' && /^Клиент:/.test(n.label));
  A['drawer.btn0'] = find((n) => n.role === 'button' && /^Отложить/.test(n.label));
  A['drawer.btn1'] = find((n) => n.role === 'button' && /^Создать заказ/.test(n.label));
  const decs = nodes.filter((n) => n.role === 'button' && /^Уменьшить количество/.test(n.label) && n.rect[0] > 900).sort((a, b) => a.rect[1] - b.rect[1]);
  const incs = nodes.filter((n) => n.role === 'button' && /^Увеличить количество/.test(n.label) && n.rect[0] > 900).sort((a, b) => a.rect[1] - b.rect[1]);
  for (let i = 0; i < 4; i++) {
    const t = protoA[`line${i}:title`];
    if (!t) continue;
    A[`line${i}:box`] = find((n) => n.role === 'button' && /^Удалить/.test(n.label) && n.rect[0] > 900 && Math.abs(n.rect[1] - (decs[i]?.rect[1] ?? -999) + 48) < 30);
    A[`line${i}:img`] = find((n) => n.role === 'img' && n.rect[0] > 900 && decs[i] && n.rect[1] < decs[i].rect[1] && n.rect[1] > decs[i].rect[1] - 60);
    A[`line${i}:name`] = find((n) => n.label === t && n.rect[0] > 900);
    if (decs[i] && incs[i]) A[`line${i}:stepper`] = [decs[i].rect[0], decs[i].rect[1], incs[i].rect[0] + incs[i].rect[2] - decs[i].rect[0], decs[i].rect[3]];
  }
  return A;
}
/** Сравнение одного состояния: снимки → якоря, цвета, области, изображения. `grid` — сетка приложения при другом числе
 * колонок, чем у прототипа (`protoGrid` + `appRow` — первый ряд приложения по месту); null — прежняя сверка. */
export function compareState({ name, protoPng, appPng, protoA, appA, masks, outDir, vp, grid = null }) {
  const P = pngDecode(protoPng);
  const Q = pngDecode(appPng);
  writeFileSync(`${outDir}/${name}-proto.png`, protoPng);
  writeFileSync(`${outDir}/${name}-app.png`, appPng);
  const G = grid;
  const P2 = G ? pngDecode(G.protoPng2) : null;
  const A2 = G ? G.protoA2 : null;
  if (G) writeFileSync(`${outDir}/${name}-proto-grid.png`, G.protoPng2);
  const notes = [];
  const rows = [];
  const r1 = (v) => Math.round(v * 10) / 10;
  // ---- якоря: видимые коробки (у элементов с рамкой/заливкой) и «чернила» (у текста)
  const TEXT = new Set(['column.title', 'title', 'found', 'logo', 'drawer.title']);
  const isText = (k) => TEXT.has(k) || /:(name|sku|stock|price|unit|sum)$/.test(k);
  const isFill = (k) => /:button$|^drawer\.btn1$/.test(k);
  // центр (стрелки ленты, крестик drawer, степпер — у приложения цель 44/48 больше видимого круга), прямоугольник как есть
  // (тост, drawer, строка «Клиент» — узел семантики = контейнер), без пары у приложения (структура прототипа — справочно)
  const CENTER = /^(ribbon\.(left|right)|bell|drawer\.close|line\d+:stepper)$/;
  const RECT = /^(toast|drawer|drawer\.client)$/;
  const SKIP = /^(header|column|ribbon|toolbar|segment|user\.(avatar|block)|logo\.(mark|word)|compactTable|compactHead|drawer\.(head|foot)|filterPanel|filter\.(check|reset))$/;
  /** Видимая коробка / «чернила» пары: прототип — на снимке PI по DOM-прямоугольнику pr, приложение — по затравке ar. */
  const measure = (k, PI, pr, ar) => {
    if (isText(k)) {
      const grow = (r) => (r ? [r[0] - 3, r[1] - 3, r[2] + 6, r[3] + 6] : null);
      const p = inkBox(PI, grow(pr));
      // у приложения узел семантики выше текста (цель 48) — окно по высоте текста прототипа вокруг центра узла
      const a = inkBox(Q, ar ? [ar[0] - 3, ar[1] + ar[3] / 2 - pr[3] / 2 - 4, ar[2] + 6, pr[3] + 8] : null);
      return { kind: 'ink', p: p && { box: p.box, ink: p.ink }, a: a && { box: a.box, ink: a.ink } };
    }
    // залитые кнопки: цель касания приложения 44/48 больше видимой части, рядом разделители строк
    if (isFill(k)) return { kind: 'fill', p: { box: fillBox(PI, pr) }, a: { box: fillBox(Q, ar) } };
    return { kind: 'box', p: { box: visibleBox(PI, pr) }, a: { box: visibleBox(Q, ar) } };
  };
  const inkDEof = (p, a) => (p?.ink && a?.ink ? Math.round(deltaE2000(rgbOf(p.ink), rgbOf(a.ink)) * 100) / 100 : null);
  // строки сетки: края (левый, верхний, правый, нижний), каждый ±1 — карточки 241,6 / 260,8 … стоят на дробных
  // координатах, и у ширины, разности двух краёв, погрешность сглаживания до 2 px
  const edges = (a, e) => [a[0] - e[0], a[1] - e[1], a[0] + a[2] - (e[0] + e[2]), a[1] + a[3] - (e[1] + e[3])].map(r1);
  const GRID_NOTE = G ? `сознательное отличие ADR-114 / 12 ред. 1.22: колонок ${G.cols} вместо ${G.protoCols} прототипа` : '';
  for (const k of Object.keys(protoA)) {
    if (k.startsWith('__') || /:title$/.test(k) || !Array.isArray(protoA[k]) || SKIP.test(k)) continue;
    const gm = G ? /^card(\d+):(\w+)$/.exec(k) : null;
    if (gm) {
      // ---- сетка приложения (03 §7.3 ред. 1.27; 12 T-UI-116 ред. 1.22)
      const i = Number(gm[1]);
      if (i >= G.cols) {
        if (gm[2] === 'box') rows.push({ anchor: k, kind: 'grid', proto: protoA[k].map(r1), app: null, d: null, ok: null, grid: true, note: `${GRID_NOTE} (карточка ${i + 1} — во втором ряду приложения)`, protoDom: protoA[k], appSem: null });
        continue;
      }
      if (gm[2] === 'box') {
        // левый край, верх ряда, ширина карточки, высота ячейки — против расчёта; карточка приложения — i-я по месту
        const exp = G.boxes[i];
        const seed = G.appRow[i] ?? null;
        const a = seed ? visibleBox(Q, seed, { masks }) : null;
        const d = a ? edges(a, exp) : null;
        rows.push({ anchor: k, kind: 'grid', proto: exp.map(r1), app: a, d, ok: d ? d.every((v) => Math.abs(v) <= 1) : null, grid: true, protoDom: A2?.[k] ?? null, appSem: seed });
        continue;
      }
      // блоки карточки: смещение от своей карточки; прототип — перестроенный на колонки приложения (P2)
      const pr = A2?.[k] ?? null;
      const pbSeed = A2?.[`card${i}:box`] ?? null;
      const abSeed = appA[`card${i}:box`] ?? G.appRow[i] ?? null;
      if (!pr || !pbSeed || !abSeed) {
        rows.push({ anchor: k, kind: isText(k) ? 'ink' : isFill(k) ? 'fill' : 'box', proto: null, app: null, d: null, ok: null, grid: true, note: !pr ? 'нет у прототипа с колонками приложения' : 'нет карточки приложения', protoDom: pr, appSem: appA[k] ?? null });
        continue;
      }
      const pb = visibleBox(P2, pbSeed, { pad: 3 }) ?? pbSeed;
      const ab = visibleBox(Q, abSeed, { pad: 3, masks }) ?? abSeed;
      let ar = appA[k] ?? [ab[0] + (pr[0] - pb[0]), ab[1] + (pr[1] - pb[1]), pr[2], pr[3]];
      if (gm[2] === 'unit' && !appA[k]) {
        // «/ шт» после цены: окно — на разницу правых краёв цены от своих карточек
        const price = rows.find((x) => x.anchor === `card${i}:price`);
        if (price?.rel) ar = [ar[0] + price.rel.a[0] + price.rel.a[2] - (price.rel.p[0] + price.rel.p[2]), ar[1], ar[2], ar[3]];
      }
      // звезда — окно внутри белого круга 34 (у карточки шире прототипа фото доходит до угла звезды, и окно с полем 6
      // ловило светлый фон фото)
      const { kind, p, a } = gm[2] === 'star' ? { kind: 'box', p: { box: visibleBox(P2, pr, { pad: -6 }) }, a: { box: visibleBox(Q, ar, { pad: -6 }) } } : measure(k, P2, pr, ar);
      const rel = p?.box && a?.box ? { p: [p.box[0] - pb[0], p.box[1] - pb[1], p.box[2], p.box[3]], a: [a.box[0] - ab[0], a.box[1] - ab[1], a.box[2], a.box[3]] } : null;
      const d = rel ? edges(rel.a, rel.p) : null;
      rows.push({ anchor: k, kind, proto: p?.box ?? null, app: a?.box ?? null, d, ok: d ? d.every((v) => Math.abs(v) <= 1) : null, rel, grid: true, protoInk: p?.ink ?? null, appInk: a?.ink ?? null, inkDE: inkDEof(p, a), protoDom: pr, appSem: appA[k] ?? null });
      continue;
    }
    if (CENTER.test(k) || RECT.test(k)) {
      const pr = protoA[k];
      const ar = appA[k] ?? null;
      const c = (r) => (r ? [r1(r[0] + r[2] / 2), r1(r[1] + r[3] / 2)] : null);
      const pv = CENTER.test(k) ? c(pr) : pr.map(r1);
      const av = ar ? (CENTER.test(k) ? c(ar) : ar.map(r1)) : null;
      const d = pv && av ? pv.map((v, i) => r1(av[i] - v)) : null;
      rows.push({ anchor: k, kind: CENTER.test(k) ? 'center' : 'rect', proto: pv, app: av, d, ok: d ? d.every((v) => Math.abs(v) <= 1) : null, protoDom: pr, appSem: ar });
      continue;
    }
    const pr = protoA[k];
    let ar = appA[k] ?? null;
    // внутренние блоки карточки: окно — смещение блока прототипа относительно коробки карточки
    const m = /^(card\d+|row\d+|crow\d+|line\d+):(img|name|sku|stock|price|unit|star|stepper|sum)$/.exec(k);
    if (!ar && m && protoA[`${m[1]}:box`] && appA[`${m[1]}:box`]) {
      const pb = visibleBox(P, protoA[`${m[1]}:box`], { pad: 3 }) ?? protoA[`${m[1]}:box`];
      const ab = visibleBox(Q, appA[`${m[1]}:box`], { pad: 3 }) ?? appA[`${m[1]}:box`];
      ar = [ab[0] + (pr[0] - pb[0]), ab[1] + (pr[1] - pb[1]), pr[2], pr[3]];
      // «/ шт» стоит после цены: окно сдвигается на разницу правых краёв цены (иначе в окно попадает конец «сом»)
      const price = m[2] === 'unit' ? rows.find((x) => x.anchor === `${m[1]}:price`) : null;
      if (price?.proto && price?.app) ar[0] += price.app[0] + price.app[2] - (price.proto[0] + price.proto[2]);
    }
    const { kind, p, a } = measure(k, P, pr, ar);
    const d = p?.box && a?.box ? p.box.map((v, i) => r1(a.box[i] - v)) : null;
    rows.push({ anchor: k, kind, proto: p?.box ?? null, app: a?.box ?? null, d, ok: d ? d.every((v) => Math.abs(v) <= 1) : null, protoInk: p?.ink ?? null, appInk: a?.ink ?? null, inkDE: inkDEof(p, a), protoDom: pr, appSem: appA[k] ?? null });
  }
  if (G) {
    notes.push(`сетка приложения ${G.cols} колонок по ${r1(G.cardW)} (класс ${G.cls}, предел ${G.cap}; прототип — ${G.protoCols}), левый край ${r1(G.left)}, ячейка ${G.cellH}${G.centred ? ', область по центру' : ''}; карточки прототипа с номером ≥ ${G.cols} — ${GRID_NOTE.split(':')[0]}`);
    const rowH = A2?.['card0:box']?.[3];
    if (rowH != null && Math.abs(rowH - G.cellH) > 0.5) notes.push(`высота ряда прототипа на ${G.cols} колонок — ${r1(rowH)}, расчёт ячейки — ${G.cellH}`);
    if (G.relayCols !== G.cols) notes.push(`прототип перестроен на ${G.relayCols} колонок вместо ${G.cols}`);
    const rowN = Object.keys(protoA).filter((k) => /^card\d+:box$/.test(k)).length;
    if (G.appRow.length !== Math.min(G.cols, rowN)) notes.push(`в первом ряду приложения карточек ${G.appRow.length}, ожидалось ${Math.min(G.cols, rowN)}`);
  }
  // ---- цвета ровных заливок: точка (центр по x, 3 px ниже верхней видимой границы) и фон страницы/шапки
  const colors = [];
  const sample = (label, pPt, aPt, PI = P) => {
    if (!pPt || !aPt) return;
    const c1 = px(PI, pPt[0], pPt[1]);
    const c2 = px(Q, aPt[0], aPt[1]);
    colors.push({ sample: label, proto: hex(c1), app: hex(c2), dE: Math.round(deltaE2000(c1, c2) * 100) / 100, at: [Math.round(pPt[0]), Math.round(pPt[1])] });
  };
  sample('фон страницы', [P.width - 6, P.height - 6], [Q.width - 6, Q.height - 6]);
  if (protoA.header) sample('фон шапки', [protoA.header[0] + protoA.header[2] * 0.45, 6], [protoA.header[0] + protoA.header[2] * 0.45, 6]);
  for (const r of rows) {
    if ((r.kind !== 'box' && r.kind !== 'fill' && r.kind !== 'grid') || !r.proto || !r.app) continue;
    if (!/^(tile:|sub:|chip:|seg:|card\d+:(box|button)|row\d+:(box|button)|crow\d+:button|sort|filtersBtn|search\.field|cart\.chip|toast|filterPanel|drawer\.(btn\d|head|foot))/.test(r.anchor)) continue;
    const yOff = /:button$|^seg:|^chip:|^sort|^filtersBtn|^toast|^cart\.chip|^search\.field|^drawer\.btn/.test(r.anchor) ? 4 : 3;
    // карточки при другом числе колонок — заливки прототипа на снимке с колонками приложения
    sample(r.anchor, [r.proto[0] + r.proto[2] / 2, r.proto[1] + yOff], [r.app[0] + r.app[2] / 2, r.app[1] + yOff], r.grid ? P2 : P);
  }
  // ---- области (прямоугольники прототипа), вне масок
  const regions = {};
  const regionsInfo = {};
  const reg = (label, rect) => {
    if (rect) regions[label] = regionMad(P, Q, rect, masks);
  };
  reg('шапка', protoA.header);
  reg('колонка', protoA.column);
  reg('лента', protoA.ribbon && [protoA.ribbon[0] - 2, protoA.ribbon[1] - 2, protoA.ribbon[2] + 4, protoA.ribbon[3] + 4]);
  reg('строка управления', protoA.toolbar);
  const bounds = (rects) => {
    const x0 = Math.min(...rects.map((r) => r[0]));
    const y0 = Math.min(...rects.map((r) => r[1]));
    const x1 = Math.max(...rects.map((r) => r[0] + r[2]));
    const y1 = Math.max(...rects.map((r) => r[1] + r[3]));
    return [x0, y0, x1 - x0, Math.min(y1, P.height) - y0];
  };
  const firstRow = Object.keys(protoA).filter((k) => /^(card|row|crow)\d+:box$/.test(k)).map((k) => protoA[k]);
  if (G) {
    // 12 T-UI-116 ред. 1.22: при другом числе колонок средняя разница области сетки не оценивается
    notes.push('«первый ряд карточек» не оценивается (12 T-UI-116 ред. 1.22: колонки сетки — сознательное отличие); справочно — против прототипа с колонками приложения');
    const rowN = Math.min(G.cols, firstRow.length);
    if (rowN) regionsInfo['первый ряд карточек (прототип на колонках приложения, справочно)'] = regionMad(P2, Q, bounds(G.boxes.slice(0, rowN)), masks);
  } else if (firstRow.length) reg('первый ряд карточек', bounds(firstRow));
  if (protoA.drawer) reg('drawer корзины', protoA.drawer);
  if (protoA.toast) reg('тост', [protoA.toast[0] - 4, protoA.toast[1] - 4, protoA.toast[2] + 8, protoA.toast[3] + 8]);
  reg('весь кадр', [0, 0, P.width, P.height]);
  const { side, diff } = sideBySide(P, Q, masks);
  writeFileSync(`${outDir}/${name}-side.png`, pngEncode(side));
  writeFileSync(`${outDir}/${name}-diff.png`, pngEncode(diff));
  if (G) writeFileSync(`${outDir}/${name}-grid-side.png`, pngEncode(sideBySide(P2, Q, masks).side));
  const res = { vp, state: name, anchors: rows, colors, regions, masks, notes, size: { proto: [P.width, P.height], app: [Q.width, Q.height] } };
  if (G) {
    res.regionsInfo = regionsInfo;
    res.grid = { cls: G.cls, cap: G.cap, W: G.W, cols: G.cols, protoCols: G.protoCols, cardW: r1(G.cardW), left: r1(G.left), cellH: G.cellH, wraps: G.wraps, centred: G.centred, boxes: G.boxes.map((b) => b.map(r1)), appRow: G.appRow };
  }
  return res;
}

// ================================================================ основной прогон
async function main() {
  const argv = process.argv.slice(2);
  const arg = (k, d) => (argv.includes(k) ? argv[argv.indexOf(k) + 1] : d);
  const OUT = resolve(arg('--out', `${ROOT}/.tmp/design-compare/${new Date().toISOString().replace(/[:.]/g, '-')}`)).replace(/\\/g, '/');
  const STORAGE = arg('--storage', 'idb');
  const VPS = String(arg('--vp', '1440x900,1280x800,1920x1080,1024x768,1366x768,1536x864')).split(',').map((s) => s.split('x').map(Number));
  const OPSZ = String(arg('--opsz', '14'));
  const ALL = ['initial', 'heating', 'sinks', 'right1', 'list', 'compact', 'filters', 'search', 'toast', 'cart2'];
  const STATES = argv.includes('--states') ? String(arg('--states')).split(',') : ALL;
  const APP_PNG = arg('--app-png', null);
  mkdirSync(OUT, { recursive: true });
  process.env.TEMP ||= `${ROOT}/.tmp`;
  const t0 = Date.now();
  const log = (...a) => console.log(`${((Date.now() - t0) / 1000).toFixed(1).padStart(6)}s`, ...a);
  let cdp = null;
  for (let p = Number(arg('--cdp', 9463)); p < (argv.includes('--cdp') ? Number(arg('--cdp')) + 1 : 9480); p++) if (await portFree(p)) {
    cdp = p;
    break;
  }
  if (!cdp) throw new Error('нет свободного порта CDP');
  let port = null;
  if (!APP_PNG) {
    for (const p of argv.includes('--port') ? [Number(arg('--port'))] : [8095, 8096, 8097, 8098, 8099]) if (await portFree(p)) {
      port = p;
      break;
    }
    if (!port) throw new Error('нет свободного порта статики 8095–8099');
  }
  const PROFILE = `${ROOT}/.tmp/design-compare-profile-${Date.now()}`;
  const site = port ? startSite(port) : null;
  const ORIGIN = port ? `http://127.0.0.1:${port}` : null;
  const B = await startBrowser({ cdp, profile: PROFILE, extraArgs: ['--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1'] });
  const R = { startedAt: new Date().toISOString(), browser: B.version, origin: ORIGIN, results: [], checks: [], notes: [] };
  const check = (name, ok, evidence) => {
    R.checks.push({ name, ok: !!ok, evidence: evidence ?? null });
    log(`${ok ? 'OK  ' : 'FAIL'} ${name}${evidence !== undefined ? ` — ${JSON.stringify(evidence).slice(0, 300)}` : ''}`);
  };
  try {
    const P = await protoTab(B, { w: 1440, h: 900 }, { opsz: OPSZ });
    R.opsz = OPSZ;
    if (APP_PNG) {
      // эталон Windows (golden) или любой снимок приложения против состояния прототипа того же размера
      const img = pngDecode(readFileSync(APP_PNG));
      const state = arg('--state', 'initial');
      await protoState(P, state, img.width, img.height);
      const protoA = await ev(P, 'window.__anchors()');
      const protoPng = await capture(P);
      const dir = `${OUT}/${img.width}x${img.height}`;
      mkdirSync(dir, { recursive: true });
      // сетка при другом числе колонок (12 T-UI-116 ред. 1.22): коробки карточек — из expectedGrid, не из прототипа
      const grid = await protoGrid(P, protoA, img.width);
      // якоря приложения неизвестны (нет семантики) — затравка = прямоугольник прототипа (карточки сетки — расчёт)
      const appA = Object.fromEntries(Object.entries(protoA).filter(([k, v]) => Array.isArray(v) && !k.startsWith('__') && !(grid && /^card\d+:/.test(k))));
      if (grid) {
        const rowN = Object.keys(protoA).filter((k) => /^card\d+:box$/.test(k)).length;
        grid.appRow = grid.boxes.slice(0, Math.min(grid.cols, rowN));
        grid.appRow.forEach((b, i) => (appA[`card${i}:box`] = b));
      }
      const res = compareState({ name: `${state}-golden`, protoPng, appPng: readFileSync(APP_PNG), protoA, appA, masks: [], outDir: dir, vp: `${img.width}x${img.height}`, grid });
      R.results.push(res);
      R.notes.push(...res.notes.map((n) => `${res.vp} ${res.state}: ${n}`));
      log(`${res.vp} ${res.state}: якорей ${res.anchors.length}, вне ±1 — ${res.anchors.filter((x) => x.ok === false).length}; области ${JSON.stringify(res.regions)}`);
    } else {
      const A = await openTab(B, { w: 1440, h: 900 });
      await uiLogin(A, ORIGIN, { storage: STORAGE, log });
      R.landing = await hashOf(A);
      // полоса «DEV · TEST DATA» в веб-демо отсутствует: верх приложения (flutter-view) — у края окна
      R.devStrip = await ev(A, `(() => { const v = document.querySelector('flutter-view, flt-glass-pane'); const r = v ? v.getBoundingClientRect() : null; return { top: r ? r.top : null, text: document.body.innerText.includes('DEV · TEST DATA') }; })()`);
      // каталог id → для прямых переходов (поиск из «Сантехники»)
      const nodes0 = await semNodes(A);
      R.landingTitle = nodes0.filter((n) => n.rect[1] > 70 && n.rect[1] < 140 && n.rect[0] > 120).map((n) => n.label).slice(0, 4);
      log('посадка', R.landing, R.landingTitle);
      const santeh = /#\/catalog\/c\/([^?]+)/.exec(R.landing)?.[1] ?? null;
      for (const [w, h] of VPS) {
        const vp = `${w}x${h}`;
        const dir = `${OUT}/${vp}`;
        mkdirSync(dir, { recursive: true });
        await setViewport(A, w, h);
        await sleep(1200);
        for (const st of [1024, 1366, 1536].includes(w) ? STATES.filter((x) => x === 'initial') : STATES) {
          try {
            const tp = Date.now();
            await B.send('Page.bringToFront', {}, P.sid); // фоновая вкладка: таймеры и кадры троттлятся
            await protoState(P, st, w, h);
            const protoA = await ev(P, 'window.__anchors()');
            // drawer корзины открыт: страница под затемнением у приложения вне семантики (модальный барьер) — только drawer
            if (protoA.drawer) for (const k of Object.keys(protoA)) if (!k.startsWith('__') && !/^(drawer|line\d+:)/.test(k)) delete protoA[k];
            const protoPng = await capture(P);
            // другое число колонок сетки (1366 / 1440 / 1536 / 1920): прототип на колонках приложения — после снимка как есть
            const grid = await protoGrid(P, protoA, w);
            if (Date.now() - tp > 5000) log(`прототип: ${st} — ${((Date.now() - tp) / 1000).toFixed(1)} с`);
            await B.send('Page.bringToFront', {}, A.sid);
            A.note = null;
            await appState(A, st, { santeh, log });
            const appPng = await capture(A);
            const nodes = await semNodes(A);
            const appA = appAnchors(nodes, protoA);
            const masks = await appMasks(A, nodes, protoA);
            // «Найдено» сдвинуто подборкой «Недавние» (паритет): обе позиции — в маску областей
            if (protoA.found && appA.found && Math.abs(protoA.found[0] - appA.found[0]) > 2) masks.push(protoA.found.map(Math.round), appA.found.map(Math.round));
            if (grid) grid.appRow = appFirstRow(nodes);
            const res = compareState({ name: st, protoPng, appPng, protoA, appA, masks, outDir: dir, vp, grid });
            res.appHash = await hashOf(A);
            if (A.note) res.note = A.note;
            res.semantics = nodes.filter((n) => n.label).map((n) => `${n.label} @${n.rect.join(',')}`).slice(0, 400);
            R.results.push(res);
            R.notes.push(...res.notes.map((n) => `${vp} ${st}: ${n}`));
            const bad = res.anchors.filter((x) => x.ok === false).length;
            log(`${vp} ${st}: якорей ${res.anchors.length}, вне ±1 — ${bad}; области ${JSON.stringify(res.regions)}`);
            await appReset(A, st, { log });
          } catch (e) {
            R.results.push({ vp, state: st, error: String(e?.stack ?? e).slice(0, 1200) });
            log(`${vp} ${st}: ОШИБКА ${String(e?.message ?? e).slice(0, 300)}`);
            await appReset(A, st, { log }).catch(() => undefined);
          }
        }
      }
      R.appErrors = { console: A.errors.slice(0, 20), exceptions: A.exceptions.slice(0, 20) };
    }
    R.protoBlocked = P.blocked.slice(0, 20);
  } catch (e) {
    R.error = String(e?.stack ?? e);
    console.error(R.error);
  } finally {
    try {
      B.ws.close();
    } catch {
      /* ignore */
    }
    killTree(B.proc.pid);
    if (site) killTree(site.pid);
    await sleep(1500);
    if (!argv.includes('--keep-profile')) rmSync(PROFILE, { recursive: true, force: true, maxRetries: 5, retryDelay: 400 });
    R.finishedAt = new Date().toISOString();
    writeFileSync(`${OUT}/metrics.json`, JSON.stringify(R, null, 1));
    writeFileSync(`${OUT}/metrics.md`, report(R));
    log(`итог: ${OUT}/metrics.json, metrics.md; профиль ${existsSync(PROFILE) ? 'НЕ удалён' : 'удалён'}`);
    process.exit(R.error ? 1 : 0);
  }
}

/** Действия состояния в приложении — те же, что у пользователя прототипа. */
export async function appState(A, st, { santeh, log = () => {} }) {
  // исходная точка каждого состояния: «Сантехника», вид «Сетка», без поиска, лента в начале, корзина пуста (appReset).
  // Сначала «Все товары» (другой адрес): тот же адрес не перестраивает экран (ADR-110) — лента и поиск остались бы.
  const t = Date.now();
  await go(A, '/catalog?all=1');
  await go(A, `/catalog/c/${santeh}?view=grid`);
  await semanticsOn(A).catch(() => undefined);
  for (let i = 0; i < 60 && !cardNode(await semNodes(A), 'Биде напольное'); i++) await sleep(500);
  if (!cardNode(await semNodes(A), 'Биде напольное')) throw new Error(`нет карточек «Сантехники» (${await hashOf(A)})`);
  const t1 = Date.now();
  await waitIdle(A);
  if (Date.now() - t > 8000) log(`приложение: ${st} — подготовка ${((t1 - t) / 1000).toFixed(1)} с, покой ${((Date.now() - t1) / 1000).toFixed(1)} с`);
  await hover(A, 5, 5);
  if (st === 'heating') await semClick(A, /^Отопление/);
  else if (st === 'sinks') await semClick(A, /^Раковины/);
  else if (st === 'right1') {
    // стрелки приложения — по настоящему переполнению (ADR-114 п. 7): на 1920 лента помещается, стрелки нет
    if (await semFind(A, /^Прокрутить подкатегории вправо/)) await semClick(A, /^Прокрутить подкатегории вправо/);
    else A.note = 'стрелки «вправо» у приложения нет: лента без переполнения (у прототипа стрелка есть всегда)';
  }
  else if (st === 'list') await semClick(A, /^Список/);
  else if (st === 'compact') await semClick(A, /^Компакт/);
  else if (st === 'filters') await semClick(A, /^Фильтры/);
  else if (st === 'search') {
    const f = await semFind(A, /^Поиск товара/);
    await click(A, f.rect[0] + f.rect[2] / 2, f.rect[1] + f.rect[3] / 2);
    await sleep(400);
    await typeText(A, '90');
    await sleep(1500);
  } else if (st === 'toast') {
    await addTo(A, 'Биде напольное');
    // тост приложения — после ответа сервера (кнопка сначала показывает загрузку): ждём узел, затем конец появления
    for (let i = 0; i < 40 && !(await semFind(A, /^Добавлено/)); i++) await sleep(125);
    await sleep(350);
    return;
  } else if (st === 'cart2') {
    await addTo(A, 'Биде напольное');
    await sleep(900);
    await addTo(A, 'Ванна акриловая');
    await sleep(2600);
    await semClick(A, /Открыть корзину/);
  }
  await sleep(1400);
  await hover(A, 5, 5);
  await sleep(300);
  log(`приложение: ${st} → ${await hashOf(A)}`);
}
/** Узел карточки товара (сетка, список, компакт): flt-semantics-img с подписью catalog_card_a11y «{название}, …». */
export const cardNode = (nodes, title) => nodes.find((n) => n.role === 'img' && n.label.startsWith(title)) ?? null;
/** Первый ряд сетки приложения по месту (слева направо): узлы карточек (роль img, ячейка 150…300 × 300…420 правее
 * колонки категорий) с наименьшим верхом. Сверка сетки при другом числе колонок идёт по месту, а не по названию. */
export function appFirstRow(nodes) {
  const cards = nodes.filter((n) => n.role === 'img' && n.rect[0] > 120 && n.rect[2] >= 150 && n.rect[2] <= 300 && n.rect[3] >= 300 && n.rect[3] <= 420);
  if (!cards.length) return [];
  const top = Math.min(...cards.map((n) => n.rect[1]));
  const row = [];
  for (const n of cards.filter((c) => Math.abs(c.rect[1] - top) <= 2).sort((a, b) => a.rect[0] - b.rect[0])) if (!row.some((r) => Math.abs(r[0] - n.rect[0]) < 2)) row.push(n.rect);
  return row;
}
export async function addTo(A, title) {
  const nodes = await semNodes(A);
  const card = cardNode(nodes, title);
  if (!card) throw new Error(`нет карточки «${title}»`);
  const btn = nodes.filter((n) => n.role === 'button' && /^(\+ ?Добавить|Добавить)/.test(n.label) && n.rect[0] >= card.rect[0] - 2 && n.rect[0] + n.rect[2] <= card.rect[0] + card.rect[2] + 2 && n.rect[1] >= card.rect[1] - 2 && n.rect[1] + n.rect[3] <= card.rect[1] + card.rect[3] + 2)[0];
  if (!btn) throw new Error(`нет «+ Добавить» у «${title}»`);
  await click(A, btn.rect[0] + btn.rect[2] / 2, btn.rect[1] + btn.rect[3] / 2);
}
/** После состояния: закрыть drawer / очистить поиск / очистить корзину (через «Очистить» drawer). */
export async function appReset(A, st, { log = () => {} } = {}) {
  if (st === 'toast' || st === 'cart2') {
    await sleep(2200);
    if (st === 'toast') await semClick(A, /Открыть корзину/);
    await sleep(900);
    const clr = await semFind(A, /^Очистить/);
    if (clr) {
      await click(A, clr.rect[0] + clr.rect[2] / 2, clr.rect[1] + clr.rect[3] / 2);
      await sleep(700);
      const ok = (await semFind(A, /^Очистить корзину$|^Да, очистить|^Очистить$/, {})) ?? null;
      const nodes = await semNodes(A);
      const confirm = nodes.filter((n) => /^(Очистить|Да)/.test(n.label) && n.role === 'button').sort((a, b) => b.rect[1] - a.rect[1])[0] ?? ok;
      if (confirm) await click(A, confirm.rect[0] + confirm.rect[2] / 2, confirm.rect[1] + confirm.rect[3] / 2);
      await sleep(900);
    } else log('appReset: нет «Очистить» в drawer');
    await key(A, 'Escape', { vk: 27 });
    await sleep(600);
  }
  if (st === 'filters') {
    await semClick(A, /^Фильтры/).catch(() => undefined);
    await sleep(500);
  }
  if (st === 'search') {
    await key(A, 'Escape', { vk: 27 });
    await sleep(500);
    await hover(A, 5, 5);
  }
}
/** Маски: элементы приложения вне прототипа (паритет и решения ADR-114) + вкладка «ДЕМО». */
export async function appMasks(A, nodes, protoA = {}) {
  const masks = [];
  const add = (r, pad = 2) => r && masks.push([Math.floor(r[0] - pad), Math.floor(r[1] - pad), Math.ceil(r[2] + 2 * pad), Math.ceil(r[3] + 2 * pad)]);
  // только небольшие узлы flt-semantics (не контейнеры, у которых в textContent — вся шапка)
  const small = (n) => n.tag === 'flt-semantics' && n.rect[2] < 420 && n.rect[3] < 120;
  const pick = (re, pred = () => true) => nodes.filter((n) => small(n) && re.test(n.label) && pred(n)).forEach((n) => add(n.rect));
  pick(/^Меню разделов/, (n) => n.rect[1] < 70); // ☰ (паритет)
  pick(/^(обновл|синхрониз|офлайн|нет связи|нет сети|ошибка синхр)/i, (n) => n.rect[1] < 70); // SyncIndicator (GEN-195)
  pick(/^\d{1,2}:\d{2}/, (n) => n.rect[1] < 70); // часы и дата (требование владельца 2026-10-29)
  pick(/^Уведомлени/, (n) => n.rect[1] < 70); // бейдж колокола — число непрочитанных в данных
  pick(/^Недавние/, (n) => n.rect[1] > 200); // подборка «Недавние» (паритет, ADR-114 п. 7)
  pick(/^(Свернуть|Развернуть) каталог/); // «‹‹» / «››»
  pick(/^Профиль:/, (n) => n.rect[1] < 70); // имя и роль — другие тестовые данные
  pick(/^Логотип/, (n) => n.rect[1] < 70); // знак логотипа: официальный оранжевый (решение 3)
  for (const k of ['logo.mark', 'user.block', 'bell']) if (Array.isArray(protoA[k])) add(protoA[k]); // те же зоны прототипа
  const fab = await ev(A, `(() => { const e = document.getElementById('pos-demo-fab'); if (!e) return null; const r = e.getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; })()`);
  add(fab, 4); // вкладка «ДЕМО» страницы веб-демо
  return masks;
}

export function report(R) {
  const L = [];
  L.push(`# design-compare — ${R.startedAt}`, '', `Браузер: ${R.browser}; сайт: ${R.origin ?? '—'}; посадка: ${R.landing ?? '—'} ${JSON.stringify(R.landingTitle ?? [])}; полоса DEV: ${JSON.stringify(R.devStrip ?? null)}; opsz прототипа: ${R.opsz ?? '—'}`, '');
  if (R.notes?.length) L.push('Заметки:', '', ...R.notes.map((n) => `- ${n}`), '');
  for (const r of R.results) {
    L.push(`## ${r.vp} · ${r.state}`, '');
    if (r.error) {
      L.push('```', r.error, '```', '');
      continue;
    }
    L.push(`Снимки: \`${r.vp}/${r.state}-side.png\`, \`${r.vp}/${r.state}-diff.png\`${r.grid ? `, \`${r.vp}/${r.state}-grid-side.png\` (прототип на колонках приложения)` : ''}; адрес приложения: \`${r.appHash ?? ''}\``, '');
    if (r.note) L.push(`Примечание: ${r.note}`, '');
    if (r.grid) L.push(`Сетка (03 §7.3 ред. 1.27; 12 T-UI-116 ред. 1.22): ${r.grid.cols} колонок по ${r.grid.cardW} (прототип — ${r.grid.protoCols}), левый край ${r.grid.left}, ячейка ${r.grid.cellH}. Строки \`card*:box\` (вид grid) — против расчёта; блоки карточек — смещение от своей карточки (прототип на колонках приложения); Δ строк \`card*\` — по краям (левый, верхний, правый, нижний), каждый ±1.`, '');
    L.push('| якорь | вид | прототип x,y,w,h | приложение x,y,w,h | Δ | ±1 | чернила прот. / прил. (ΔE) | примечание |', '|---|---|---|---|---|---|---|---|');
    for (const a of r.anchors) L.push(`| ${a.anchor} | ${a.kind} | ${a.proto?.join(', ') ?? '—'} | ${a.app?.join(', ') ?? '—'} | ${a.d?.join(', ') ?? '—'} | ${a.ok === null ? '—' : a.ok ? 'да' : '**нет**'} | ${a.protoInk ? `${a.protoInk} / ${a.appInk ?? '—'} (${a.inkDE ?? '—'})` : ''} | ${a.note ?? ''} |`);
    L.push('', '| цвет | прототип | приложение | ΔE2000 |', '|---|---|---|---|');
    for (const c of r.colors) L.push(`| ${c.sample} | ${c.proto} | ${c.app} | ${c.dE <= 1 ? c.dE : `**${c.dE}**`} |`);
    L.push('', `Области (средняя |Δ|, 0…255, вне масок): ${Object.entries(r.regions).map(([k, v]) => `${k} ${v}`).join('; ')}`, '');
    if (r.regionsInfo && Object.keys(r.regionsInfo).length) L.push(`Справочно (не оценивается): ${Object.entries(r.regionsInfo).map(([k, v]) => `${k} ${v}`).join('; ')}`, '');
  }
  return L.join('\n');
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await main();
