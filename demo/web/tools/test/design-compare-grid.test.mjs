// Сетка товаров в сверке с прототипом (12 T-UI-116 ред. 1.22; 03 §7.3 ред. 1.27; `tokens.json` 1.4.0): расчёт
// `expectedGrid`, первый ряд приложения по месту и сравнение `compareState` при другом числе колонок — без браузера,
// на синтетических снимках.
//   node --test demo/web/tools/test/design-compare-grid.test.mjs
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';

import { CATALOG_COLUMN, appFirstRow, compareState, expectedGrid, pngEncode, windowClassOf } from '../design-compare.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../../../..');
const TOKENS = JSON.parse(readFileSync(join(ROOT, 'contracts/design-tokens/tokens.json'), 'utf8'));
const OUT = mkdtempSync(join(tmpdir(), 'design-compare-grid-'));
after(() => rmSync(OUT, { recursive: true, force: true }));

test('expectedGrid: таблица 03 §7.3 ред. 1.27 (сотрудник, колонка 144)', () => {
  // окно → [класс, колонок, карточка (округлённо)]
  const table = {
    600: ['medium', 2, 205], 720: ['medium', 2, 265], 820: ['medium', 3, 205], 960: ['medium', 4, 186],
    1024: ['expanded', 4, 202], 1280: ['expanded', 5, 210], 1366: ['expanded', 5, 227], 1440: ['expanded', 5, 242], 1536: ['expanded', 5, 261],
    1920: ['large', 6, 279], 2133: ['large', 6, 280], 2560: ['large', 6, 280], 2880: ['large', 6, 280], 3840: ['large', 6, 280],
  };
  for (const [w, [cls, cols, card]] of Object.entries(table)) {
    const g = expectedGrid(Number(w));
    assert.equal(g.cls, cls, `класс окна ${w}`);
    assert.equal(g.cols, cols, `колонок при ${w}`);
    assert.equal(Math.round(g.cardW), card, `карточка при ${w}`);
  }
  assert.equal(CATALOG_COLUMN, 144);
  assert.equal(expectedGrid(1440).W, 1264);
  assert.equal(windowClassOf(1599), 'expanded');
  assert.equal(windowClassOf(1600), 'large');
});

test('expectedGrid: окна прототипа — 4 / 5 как у прототипа, 5 / 5 / 5 / 6 вместо 6 / 6 / 7 / 9 (12 T-UI-116 ред. 1.22)', () => {
  // прототип: repeat(auto-fill, minmax(176px, 1fr)), зазор 14, без предела
  const proto = (w) => Math.floor((w - 144 - 32 + 14) / (176 + 14));
  const want = { 1024: [4, 4], 1280: [5, 5], 1366: [5, 6], 1440: [5, 6], 1536: [5, 7], 1920: [6, 9] };
  for (const [w, [app, pr]] of Object.entries(want)) {
    assert.equal(expectedGrid(Number(w)).cols, app, `приложение ${w}`);
    assert.equal(proto(Number(w)), pr, `прототип ${w}`);
  }
});

test('expectedGrid: пределы берутся из tokens.json (breakpoint.*.productColumnsMax)', () => {
  const t = structuredClone(TOKENS);
  t.breakpoint.expanded.productColumnsMax = 7;
  t.breakpoint.large.productColumnsMax = 9;
  // значения ред. 1.25 — как у прототипа
  assert.equal(expectedGrid(1536, { tokens: t }).cols, 7);
  assert.equal(expectedGrid(1920, { tokens: t }).cols, 9);
  assert.equal(Math.round(expectedGrid(1920, { tokens: t }).cardW), 181); // (1744 − 8 × 14) / 9
});

test('expectedGrid: ячейка 340 / 360 по ценам ряда, ряд и область по центру', () => {
  // карточка 241,6 без полей и обводок — 215,6: «10 450,00 сом · 4 · / шт» (128,9 + 4 + 25,1) помещается
  const fits = expectedGrid(1440, { top: 367, prices: [{ price: 128.9, unit: 25.1 }] });
  assert.equal(fits.cellH, TOKENS.catalog.gridCardHeight);
  assert.deepEqual(fits.wraps, [false]);
  const wraps = expectedGrid(1440, { top: 367, prices: [{ price: 128.9, unit: 25.1 }, { price: 190, unit: 25.1 }] });
  assert.equal(wraps.cellH, TOKENS.catalog.gridCardHeightWrapped);
  // карточка за пределами первого ряда приложения на высоту не влияет
  const later = expectedGrid(1440, { top: 367, prices: [0, 1, 2, 3, 4].map(() => ({ price: 100, unit: 25 })).concat([{ price: 400, unit: 25 }]) });
  assert.equal(later.cellH, 340);
  // без единицы не переносится
  assert.equal(expectedGrid(1440, { prices: [{ price: 400, unit: 0 }] }).cellH, 340);
  // ряд: левый край 144 + 8, шаг карточка + 14
  assert.equal(fits.boxes.length, 5);
  assert.deepEqual(fits.boxes[0], [152, 367, 241.6, 340]);
  assert.ok(Math.abs(fits.boxes[4][0] - (152 + 4 * 255.6)) < 1e-9);
  assert.equal(fits.centred, false);
  assert.equal(expectedGrid(1920).centred, false); // 1744 < 1750
  // 2133: область 1750 по центру зоны справа от колонки — от колонки до карточек и от карточек до края окна поровну
  // (полосы `_bands` — с учётом несимметричных полей 8 / 24)
  const c = expectedGrid(2133);
  assert.equal(c.centred, true);
  assert.equal(c.areaWidth, 6 * 280 + 5 * 14);
  const leftGap = c.left - 144;
  const rightGap = 2133 - (c.left + c.areaWidth);
  assert.ok(Math.abs(leftGap - rightGap) < 1e-9, `${leftGap} ≠ ${rightGap}`);
  assert.equal(c.left, 263.5);
});

test('appFirstRow: первый ряд карточек приложения по месту, без ленты и строк списка', () => {
  const n = (label, role, rect) => ({ label, role, tag: 'flt-semantics', rect });
  const nodes = [
    n('Унитазы', 'img', [283, 145, 118, 148]), // карточка ленты
    n('Биде напольное Sanita, …', 'img', [152, 367, 241.6, 340]),
    n('Ванна акриловая, …', 'img', [407.6, 367, 241.6, 340]),
    n('Ванна акриловая, …', 'img', [407.6, 367, 241.6, 340]), // дубль узла
    n('Поддон, …', 'img', [152, 721, 241.6, 340]), // второй ряд
    n('Логотип', 'img', [26, 17, 175, 35]),
    n('+ Добавить', 'button', [165, 650, 215, 48]),
  ];
  assert.deepEqual(appFirstRow(nodes), [[152, 367, 241.6, 340], [407.6, 367, 241.6, 340]]);
  assert.deepEqual(appFirstRow([]), []);
});

// ---- синтетические снимки 1440 × 900: прототип 6 колонок по 199, приложение 5 по 241,6
const BG = [244, 246, 250];
const BORDER = [227, 233, 242];
const SKU = [107, 116, 135];
const BTN = [217, 56, 15];
const img = (w, h) => {
  const data = Buffer.alloc(w * h * 4);
  for (let i = 0; i < w * h; i++) data.set([...BG, 255], i * 4);
  return { width: w, height: h, data };
};
const fill = (I, x, y, w, h, c) => {
  for (let yy = Math.round(y); yy < Math.round(y + h); yy++) for (let xx = Math.round(x); xx < Math.round(x + w); xx++) I.data.set([...c, 255], (yy * I.width + xx) * 4);
};
/** Карточка: обводка 1, белое поле, «Арт.» 60 × 10 на (14, 215), кнопка (ширина − 26) × 40 на (13, 287). */
const card = (I, x, y, w, h) => {
  fill(I, x, y, w, h, BORDER);
  fill(I, x + 1, y + 1, w - 2, h - 2, [255, 255, 255]);
  fill(I, x + 14, y + 215, 60, 10, SKU);
  fill(I, x + 13, y + 287, w - 26, 40, BTN);
};
const protoRect = (i) => [152 + i * 213, 367, 199, 340];
const blocks = (A, i, [x, y, w, h]) => {
  A[`card${i}:box`] = [x, y, w, h];
  A[`card${i}:sku`] = [x + 13, y + 212, w - 26, 15];
  A[`card${i}:button`] = [x + 13, y + 287, w - 26, 40];
  A[`card${i}:title`] = `Товар ${i}`;
};
function scene({ shift = 0, fab = null } = {}) {
  const P = img(1440, 900);
  const protoA = { __gridCols: 6 };
  for (let i = 0; i < 6; i++) {
    card(P, ...protoRect(i));
    blocks(protoA, i, protoRect(i));
  }
  const g = expectedGrid(1440, { top: 367, prices: [] });
  const P2 = img(1440, 900);
  const Q = img(1440, 900);
  const protoA2 = { __gridCols: 5 };
  const appA = {};
  const appRow = [];
  g.boxes.forEach((b, i) => {
    card(P2, ...b);
    blocks(protoA2, i, b);
    const a = [b[0] + (i === 2 ? shift : 0), b[1], b[2], b[3]];
    card(Q, ...a);
    appRow.push(a);
    appA[`card${i}:box`] = a;
    appA[`card${i}:button`] = [a[0] + 13, a[1] + 283, a[2] - 26, 48]; // цель касания 48
  });
  if (fab) fill(Q, ...fab, [14, 20, 86]); // вкладка «ДЕМО» у правого края окна
  const grid = { ...g, protoCols: 6, relayCols: 5, protoA2, protoPng2: pngEncode(P2), appRow };
  return { protoPng: pngEncode(P), appPng: pngEncode(Q), protoA, appA, grid };
}
const row = (res, k) => res.anchors.find((a) => a.anchor === k);

test('compareState: 5 колонок против 6 — карточки к расчёту, блоки от своей карточки, шестая — сознательное отличие', () => {
  const s = scene();
  const res = compareState({ name: 'initial', ...s, masks: [], outDir: OUT, vp: '1440x900' });
  for (let i = 0; i < 5; i++) {
    assert.equal(row(res, `card${i}:box`).ok, true, `card${i}:box ${JSON.stringify(row(res, `card${i}:box`))}`);
    assert.equal(row(res, `card${i}:sku`).ok, true, `card${i}:sku ${JSON.stringify(row(res, `card${i}:sku`))}`);
    assert.equal(row(res, `card${i}:button`).ok, true, `card${i}:button ${JSON.stringify(row(res, `card${i}:button`))}`);
  }
  const sixth = row(res, 'card5:box');
  assert.equal(sixth.ok, null);
  assert.match(sixth.note, /сознательное отличие ADR-114 \/ 12 ред\. 1\.22/);
  assert.equal(row(res, 'card5:sku'), undefined);
  assert.equal(res.anchors.filter((a) => a.ok === false).length, 0);
  assert.equal('первый ряд карточек' in res.regions, false);
  assert.ok(res.notes.some((n) => /«первый ряд карточек» не оценивается/.test(n)));
  assert.equal(Object.keys(res.regionsInfo).length, 1);
  assert.equal(res.grid.cols, 5);
  assert.equal(res.grid.protoCols, 6);
  // заливки карточек — по прототипу на колонках приложения
  for (const c of res.colors.filter((x) => /^card\d+:(box|button)$/.test(x.sample))) assert.equal(c.dE, 0, c.sample);
});

test('compareState: сдвиг карточки приложения — провал коробки, блоки внутри своей карточки остаются в норме', () => {
  const s = scene({ shift: 3 });
  const res = compareState({ name: 'shift', ...s, masks: [], outDir: OUT, vp: '1440x900' });
  const box = row(res, 'card2:box');
  assert.equal(box.ok, false);
  // сдвиг 3 при дробном расчётном крае 663,2 (снимок — по целым пикселям)
  assert.ok(box.d[0] > 2 && box.d[0] < 3.5, `левый край ${box.d[0]}`);
  assert.ok(box.d[2] > 2 && box.d[2] < 3.5, `правый край ${box.d[2]}`);
  assert.equal(row(res, 'card2:sku').ok, true);
  assert.equal(row(res, 'card2:button').ok, true);
});

test('compareState: вкладка «ДЕМО» у крайней карточки — строка сканирования под маской пропускается', () => {
  // 1440: правый край пятой карточки 1416, вкладка 1416…1444 по высоте строки сканирования ¾ (625)
  const fab = [1416, 592, 24, 76];
  const s = scene({ fab });
  const masked = compareState({ name: 'fab', ...s, masks: [[1412, 588, 32, 84]], outDir: OUT, vp: '1440x900' });
  assert.equal(row(masked, 'card4:box').ok, true, JSON.stringify(row(masked, 'card4:box')));
  const bare = compareState({ name: 'fab-bare', ...s, masks: [], outDir: OUT, vp: '1440x900' });
  assert.equal(row(bare, 'card4:box').ok, false); // без маски окно ловит вкладку: правый край +6
});

test('compareState без сетки (колонок столько же, как 1024 / 1280): прежняя сверка с областью «первый ряд карточек»', () => {
  const s = scene();
  const res = compareState({ name: 'same', protoPng: s.protoPng, appPng: s.protoPng, protoA: s.protoA, appA: Object.fromEntries(Object.entries(s.protoA).filter(([, v]) => Array.isArray(v))), masks: [], outDir: OUT, vp: '1440x900' });
  assert.equal(res.grid, undefined);
  assert.equal(res.regions['первый ряд карточек'], 0);
  assert.ok(res.anchors.filter((a) => /^card\d+:box$/.test(a.anchor)).every((a) => a.ok === true && a.kind === 'box'));
});
