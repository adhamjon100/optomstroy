// Каталог веб-демо по прототипу экрана выбора товаров (WP-DATA-WEB 2026-10-31; 15 ADR-114, ADR-113).
//
//   node --test demo/web/backend/test/design-catalog.test.mjs
//
// 1. Спецификация demo/catalog/design-catalog.json = данные прототипа docs/specification/visual/prototype/Main.dc.html
//    (CATS, P, IMG, favs): дерево и его порядок, 26 товаров макета (названия, артикулы, цены, остатки, «новые»),
//    «Сантехника» — ровно 12 товаров макета; фото — байты ассетов макета (sha256), без перекодирования.
// 2. Правила демо: у каждой подкатегории есть товары (приложение скрывает пустые), артикулы уникальны, у «Сантехники»
//    больше всех товаров среди корней — каталог сотрудника при первом входе открывается на корне с наибольшим
//    productCount (решение владельца 2026-10-31), то есть на «Сантехнике», как в макете.
// 3. Сборка pos-api/scripts/design_catalog.ts на SyntheticCatalog из .build/pos-api-dist: состав, зеркальные константы
//    генератора, ссылки не пересекаются с синтетикой seed 1 (нужна сборка tsc — build-backend.mjs; иначе пропуск).
// 4. После сборки сайта (site/backend + снимок): воркер со снимком — /catalog/categories: 8 корней в порядке макета с
//    imageUrl, у «Сантехники» 9 подкатегорий с imageUrl; её 12 товаров с основным фото и уровнями остатка макета
//    (порог «мало» 4); SL1001 — в избранном сотрудника стенда (нет сайта — пропуск).
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { test } from 'node:test';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';
import { DIST, ROOT, SCRIPTS } from '../lib/paths.mjs';
import { DEMO_DATA, STAFF } from '../demo-config.mjs';

const SPEC_FILE = `${ROOT}/demo/catalog/design-catalog.json`;
const PROTO = `${ROOT}/docs/specification/visual/prototype`;
const spec = JSON.parse(readFileSync(SPEC_FILE, 'utf8'));
const sha256 = (b) => createHash('sha256').update(b).digest('hex');
const dc = await import(pathToFileURL(`${SCRIPTS}/design_catalog.ts`).href);

/** Литерал `const NAME = …;` из скрипта прототипа (объекты данных, без кода). */
function protoLiteral(html, name, close) {
  const start = html.indexOf(`const ${name} = `);
  assert.ok(start >= 0, `в прототипе нет const ${name}`);
  const from = start + `const ${name} = `.length;
  const end = html.indexOf(`\n${close};`, from);
  assert.ok(end > from, `const ${name}: нет конца литерала`);
  // JSON: объекты другого контекста vm — к обычным (deepStrictEqual сравнивает и прототипы).
  return JSON.parse(JSON.stringify(vm.runInNewContext(`(${html.slice(from, end + 1 + close.length)})`)));
}
const html = readFileSync(`${PROTO}/Main.dc.html`, 'utf8');
const CATS = protoLiteral(html, 'CATS', ']');
const P = protoLiteral(html, 'P', ']');
const IMG = protoLiteral(html, 'IMG', '}');
const FAVS = Object.keys(vm.runInNewContext(`(${/favs:\s*(\{[^}]*\})/.exec(html)[1]})`));

const rootOf = (id) => spec.categories.find((c) => c.id === id);
const photoOf = (name) => spec.photos.find((p) => p.name === name);
const tyiyn = (price) => Number(price.replace('.', '')); // money-double: allow — целые тыйыны из строки «0.00» для сравнения с P.price

test('1. дерево категорий = CATS прототипа: 8 корней и 33 подкатегории в порядке макета, «Крепеж» через «е»', () => {
  assert.deepEqual(
    spec.categories.map((c) => [c.id, c.name, c.subs.map((s) => [s.id, s.name])]),
    CATS.map((c) => [c.id, c.name, c.subs.map(([id, name]) => [id, name])]),
  );
  assert.equal(spec.categories.reduce((n, c) => n + c.subs.length, 0), 33);
  for (const list of [spec.categories, ...spec.categories.map((c) => c.subs)]) {
    const so = list.map((x) => x.sortOrder);
    assert.deepEqual(so, [...so].sort((a, b) => a - b), 'sortOrder возрастает в порядке макета');
    assert.equal(new Set(so).size, so.length, 'sortOrder без повторов');
  }
  assert.equal(rootOf('fasteners').name, 'Крепеж и фурнитура');
});

test('1. товары макета (P) — без изменений: названия, артикулы, цены, остатки, «новые»; «Сантехника» — ровно 12 товаров макета', () => {
  const design = spec.products.filter((p) => p.design);
  assert.equal(design.length, P.length);
  for (const d of P) {
    const p = spec.products.find((x) => x.sku === d.sku);
    assert.ok(p, `нет товара макета ${d.sku}`);
    assert.equal(p.design, true, `${d.sku}: design`);
    assert.deepEqual([p.cat, p.sub, p.name, p.unit], [d.cat, d.sub, d.name, 'шт'], `${d.sku}: категория, название, единица`);
    assert.equal(tyiyn(p.price), d.price, `${d.sku}: цена`);
    assert.equal(p.stock.main, d.qty, `${d.sku}: остаток на «Основном складе»`);
    assert.equal(!!p.isNew, !!d.isNew, `${d.sku}: «новый»`);
    assert.ok(!p.variants && !p.packs, `${d.sku}: без характеристик и упаковок, как в макете`);
  }
  const plumbing = spec.products.filter((p) => p.cat === 'plumbing');
  assert.deepEqual(plumbing.map((p) => p.sku).sort(), P.filter((d) => d.cat === 'plumbing').map((d) => d.sku).sort());
  assert.equal(plumbing.length, 12);
  // уровни остатка макета при пороге «мало» 4: 3 — «мало», 4 — «в наличии», 0 — «нет»
  assert.equal(spec.lowStockThreshold, 4);
  assert.deepEqual([P.find((d) => d.sku === 'SP300').stock, P.find((d) => d.sku === 'RV9090').stock, P.find((d) => d.sku === 'TR600').stock], ['low', 'in', 'out']);
  assert.deepEqual(spec.favorites, FAVS.map((id) => P.find((d) => d.id === id).sku), 'избранное = favs макета');
});

test('1. фото = ассеты макета: 8 корней, 9 подкатегорий «Сантехники», 12 товаров «Сантехники»; файлы и sha256 совпадают', () => {
  assert.equal(spec.photos.length, 29);
  for (const c of spec.categories) {
    assert.equal(photoOf(c.image)?.source, `docs/specification/visual/prototype/${IMG.cat[c.id].slice(2)}`, `корень ${c.id}`);
    for (const s of c.subs) {
      if (c.id === 'plumbing') assert.equal(photoOf(s.image)?.source, `docs/specification/visual/prototype/${IMG.sub[s.id].slice(2)}`, `подкатегория ${s.id}`);
      else assert.equal(s.image, null, `${c.id}/${s.id}: в макете без картинки`);
    }
  }
  for (const d of P) {
    const p = spec.products.find((x) => x.sku === d.sku);
    if (d.img) assert.equal(photoOf(p.photo)?.source, `docs/specification/visual/prototype/${IMG.p[d.img].slice(2)}`, `товар ${d.sku}`);
    else assert.equal(p.photo, null, `товар ${d.sku}: в макете без фото`);
  }
  assert.ok(spec.products.filter((p) => !p.design).every((p) => p.photo === null), 'наполнители без фото');
  for (const ph of spec.photos) {
    const file = readFileSync(`${ROOT}/demo/catalog/${ph.file}`);
    assert.equal(sha256(file), ph.sha256, `${ph.file}: sha256`);
    assert.ok(file.equals(readFileSync(`${ROOT}/${ph.source}`)), `${ph.file} — побайтно ассет макета ${ph.source}`);
    assert.equal(file.subarray(1, 4).toString('latin1'), 'PNG', `${ph.file}: PNG`);
  }
});

test('2. правила демо: спецификация без ошибок, подкатегории непусты, артикулы уникальны, «Сантехника» — больше всех товаров', () => {
  assert.deepEqual(dc.validateDesignSpec(spec), []);
  for (const k of ['profile', 'refSeed', 'lowStockThreshold']) assert.equal(spec[k], DEMO_DATA.catalog[k], `DEMO_DATA.catalog.${k}`);
  for (const c of spec.categories) for (const s of c.subs) assert.ok(spec.products.some((p) => p.cat === c.id && p.sub === s.id), `${c.id}/${s.id} пуста`);
  const skus = spec.products.flatMap((p) => [p.sku, ...(p.variants?.values ?? []).map((_v, j) => `${p.sku}-${j + 1}`)]).map((s) => s.toUpperCase());
  assert.equal(new Set(skus).size, skus.length);
  // стартовая категория: корень с наибольшим числом товаров (при равенстве — первый по sortOrder) = «Сантехника»
  const count = (id, pred = () => true) => spec.products.filter((p) => p.cat === id && pred(p)).length;
  const ranked = spec.categories.map((c) => ({ id: c.id, n: count(c.id), so: c.sortOrder })).sort((a, b) => b.n - a.n || a.so - b.so);
  assert.equal(ranked[0].id, 'plumbing', `больше всех товаров у ${ranked[0].id}: ${JSON.stringify(ranked)}`);
  assert.ok(ranked[0].n > ranked[1].n, 'без равенства с другим корнем');
  const inStock = (p) => typeof p.stock.main === 'number' && p.stock.main > 0;
  const rankedIn = spec.categories.map((c) => ({ id: c.id, n: count(c.id, inStock) })).sort((a, b) => b.n - a.n);
  assert.equal(rankedIn[0].id, 'plumbing', `и среди товаров в наличии: ${JSON.stringify(rankedIn)}`);
  assert.ok(rankedIn[0].n > rankedIn[1].n);
  // демонстрируемые состояния и данные тестов: характеристики, упаковки, дробные единицы, нет/мало/неизвестно
  assert.ok(spec.products.filter((p) => p.variants).length >= 5);
  assert.ok(spec.products.filter((p) => p.packs).length >= 8);
  assert.ok(spec.products.filter((p) => p.unit !== 'шт').length >= 4);
  assert.ok(spec.products.some((p) => p.stock.main === 'unknown'));
  assert.ok(spec.products.some((p) => p.stock.main === 0 && Object.values(p.stock).some((q) => typeof q === 'number' && q > 0)), 'нет на основном, есть на другом складе');
  assert.ok(spec.products.filter((p) => !p.variants && inStock(p) && tyiyn(p.price) <= 600000).length >= 30, 'товары для сценариев (простые, в наличии, ≤ 6 000 сом)');
  assert.ok(spec.products.filter((p) => /кран/i.test(p.name)).length >= 2, 'поиск «кран»');
  assert.ok(spec.products.some((p) => /унитаз/i.test(p.name)), 'поиск «унитаз»');
});

test('3. сборка каталога: состав, зеркальные константы генератора, порядок и план фото', { skip: !existsSync(`${DIST}/integrations/onec/synthetic-catalog.js`) && 'нет .build/pos-api-dist (build-backend.mjs)' }, async () => {
  const { SyntheticCatalog, ean13 } = await import(pathToFileURL(`${DIST}/integrations/onec/synthetic-catalog.js`).href);
  const deps = { SyntheticCatalog, ean13 };
  assert.deepEqual(dc.checkGeneratorMirror(deps, spec), []);
  const cat = dc.buildDesignCatalog(spec, deps);
  const st = cat.stats();
  const sellable = spec.products.reduce((n, p) => n + (p.variants ? p.variants.values.length : 1), 0);
  assert.equal(st.categories, 41);
  assert.equal(st.products, spec.products.length);
  assert.equal(st.productsDeleted, 0);
  assert.equal(st.sellableVariants, sellable);
  assert.equal(st.packagings, spec.products.reduce((n, p) => n + (p.packs?.length ?? 0), 0));
  assert.equal(st.barcodes, sellable + spec.products.reduce((n, p) => n + (p.packs?.length ?? 0), 0));
  // корни — в порядке макета; ссылки — refSeed 1031, не seed 1 синтетики тестов
  const roots = cat.categories.filter((c) => !c.parentRef).map((c) => c.description);
  assert.deepEqual(roots, CATS.map((c) => c.name));
  assert.ok(cat.categories.every((c) => c.ref.startsWith('00000407-')), 'refSeed 1031 = 0x407');
  const seed1 = new SyntheticCatalog({ skuCount: 40, seed: 1 });
  const refs1 = new Set([...seed1.allItems()].map((x) => x.ref));
  assert.ok(cat.allItems().every((x) => !refs1.has(x.ref)), 'ссылки не пересекаются с синтетикой seed 1');
  const order = dc.categoryOrder(spec, cat);
  assert.equal(order.length, 41);
  assert.deepEqual(order.filter((o) => !o.path.includes('/')).map((o) => o.sortOrder), spec.categories.map((c) => c.sortOrder));
  const plan = dc.photoPlan(spec, cat);
  assert.equal(plan.products.length, 12);
  assert.equal(plan.categories.length, 17);
  // цены трёх видов: 1,0 / 0,9 / 0,82 розничной (округление до тыйына), упаковки — только в оптовых
  const sl = cat.card(plan.products.find((x) => x.owner === 'SL1001').onecRef);
  assert.deepEqual(sl.prices.map((p) => p.price).sort(), ['6929.00', '7605.00', '8450.00']);
  assert.deepEqual(sl.stock.map((s) => s.available), ['24.000']);
  assert.equal(sl.barcodes.length, 1);
  const kt2 = cat.productItems().find((p) => p.sku === 'KT2');
  assert.equal(cat.stockSlice().filter((r) => r.productRef === kt2.ref).length, 0, 'KT2 — «Остаток неизвестен» (строки нет)');
});

// ---------------------------------------------------------------- 4. собранный сайт
const SITE = `${ROOT}/demo/web/site`;
const built = existsSync(`${SITE}/backend/build.json`) && existsSync(`${SITE}/demo/snapshot/manifest.json`);
test('4. воркер со снимком: корни с картинками в порядке макета, подкатегории «Сантехники», её 12 товаров с фото, избранное', { skip: !built && 'сайт не собран (build-backend.mjs)', timeout: 240_000 }, async () => {
  const { startWorkerBackend } = await import('./harness/worker-harness.mjs');
  const be = await startWorkerBackend({ strict: true, initOpts: { seed: false, catchUp: false, buildId: 'design-catalog-test' } });
  try {
    assert.equal(be.ready.timings.snapshot?.used, true, `снимок не взят: ${be.ready.timings.snapshot?.reason}`);
    const H = { 'X-Device-Id': crypto.randomUUID(), 'X-App-Version': be.ready.appVersion ?? '0.1.0+1', 'X-Platform': 'windows', 'Accept-Language': 'ru' };
    const call = (method, url, body, extra = {}) => be.api(method, `/api/v1${url}`, { headers: { ...H, ...extra }, body });
    const senior = STAFF.find((s) => s.role === 'senior_seller').phone;
    const rq = await call('POST', '/auth/otp/request', { phone: senior, purpose: 'login_or_register', locale: 'ru' });
    const vr = await call('POST', '/auth/otp/verify', { challengeId: rq.json?.challengeId, code: '246810', device: { name: 'Node (design-catalog)', platform: 'windows', appVersion: H['X-App-Version'] } });
    H.Authorization = `Bearer ${vr.json?.accessToken}`;
    await call('POST', '/me/pin', { newPin: '715382' }, { 'Idempotency-Key': crypto.randomUUID() });

    const cats = (await call('GET', '/catalog/categories')).json?.items ?? [];
    assert.deepEqual(cats.map((c) => c.name), CATS.map((c) => c.name), 'корни в порядке макета');
    assert.ok(cats.every((c) => /^\/images\/[0-9a-f]{64}\/card$/.test(c.imageUrl ?? '')), 'у каждого корня imageUrl');
    const top = [...cats].sort((a, b) => b.productCount - a.productCount || a.sortOrder - b.sortOrder)[0];
    assert.equal(top.name, 'Сантехника', 'стартовая категория (наибольший productCount) — «Сантехника»');
    const plumbing = cats.find((c) => c.name === 'Сантехника');
    assert.equal(plumbing.productCount, 12);
    const subs = plumbing.children ?? (await call('GET', `/catalog/categories?parentId=${plumbing.id}`)).json?.items ?? [];
    assert.deepEqual(subs.map((s) => s.name), CATS.find((c) => c.id === 'plumbing').subs.map(([, n]) => n));
    assert.ok(subs.every((s) => /^\/images\/[0-9a-f]{64}\/card$/.test(s.imageUrl ?? '')), 'у подкатегорий «Сантехники» imageUrl');
    const heating = cats.find((c) => c.name === 'Отопление');
    assert.ok((heating.children ?? []).every((s) => s.imageUrl === null), 'у подкатегорий «Отопления» картинок нет (как в макете)');

    const items = (await call('GET', `/catalog/products?categoryId=${plumbing.id}&includeSubcategories=true&limit=50`)).json?.items ?? [];
    const want = P.filter((d) => d.cat === 'plumbing');
    assert.deepEqual(items.map((p) => p.sku).sort(), want.map((d) => d.sku).sort());
    const level = { in: 'in_stock', low: 'low', out: 'out' };
    for (const d of want) {
      const p = items.find((x) => x.sku === d.sku);
      assert.equal(p.name, d.name);
      assert.ok(/^\/images\/[0-9a-f]{64}\/card$/.test(p.primaryImage?.cardUrl ?? p.primaryImage?.url ?? ''), `${d.sku}: основное фото ${JSON.stringify(p.primaryImage)}`);
      assert.equal(tyiyn(String(p.price?.price?.amount ?? p.price?.amount)), d.price, `${d.sku}: цена`);
      assert.equal(p.stock?.stockLevel, level[d.stock], `${d.sku}: уровень остатка`);
    }
    assert.equal(items.find((x) => x.sku === 'SL1001').isFavorite, true, 'SL1001 в избранном сотрудника стенда');
  } finally {
    await be.close();
  }
});
