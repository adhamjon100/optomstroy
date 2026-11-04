/**
 * Демо-каталог по прототипу экрана выбора товаров (15 ADR-114; `docs/specification/visual/prototype/Main.dc.html`:
 * `CATS`, `P`, `IMG`, `favs`) для веб-демо (`demo/web/backend`, ADR-113) и демо Windows. **Тестовые данные**, не
 * реальная интеграция; `pos-api/src` не меняется — только скрипт разработки, как `pos_fake_onec.ts`.
 *
 * Спецификация — `demo/catalog/design-catalog.json` (правится вручную): дерево 8 корней / 33 подкатегории в порядке
 * макета, 26 товаров макета без изменений (названия, артикулы, цены, остатки; «Сантехника» — ровно 12 товаров макета) и
 * наполнители без марок, фото макета `demo/catalog/photos/*.png` (sha256 в спецификации).
 *
 * Каталог строится через ПУБЛИЧНЫЙ API генератора `SyntheticCatalog` (конструктор, `ref()`, `units`, `warehouses`,
 * `priceLists`, `categories`, `merge()`) и `ean13`: пустой генератор (`skuCount: 0`, `seed = refSeed`) → его дерево
 * ROOTS удаляется → папки, товары, характеристики, упаковки «Коробка (N шт)», штрихкоды EAN-13 «23…»/«24…», цены
 * трёх видов (1,0 / 0,9 / 0,82 розничной) и остатки — одним `merge()`. Классы передаются параметром (`deps`): у
 * модуля нет импортов времени выполнения, поэтому его собирает esbuild (backend.js браузера, построитель снимка), а
 * Node 24 (снятие типов) и tsx запускают как есть.
 *
 * Зеркальные закрытые константы генератора (`dataVersion(1)`, ссылки свойств «Цвет»/«Размер», коэффициенты видов цен,
 * имена единиц и складов) сверяет `checkGeneratorMirror()` с выводом `new SyntheticCatalog({ skuCount: 40, seed: 1 })`:
 * расхождение останавливает сборку снимка.
 *
 * Чего генератор и `CatalogApplier` не пишут — `applyDesignCatalogSettings()` (SQL после загрузки каталога; повторная
 * синхронизация эти поля не трогает): `categories.sort_order` (порядок макета не алфавитный), порог «мало»
 * `low_stock_threshold` (в макете 4 шт — «В наличии», 3 — «Мало»), избранное сотрудников стенда (в макете
 * `favs = {p1}`). Картинки категорий — `registerCategoryImage()`: строка `product_images` с `category_id` и
 * `categories.image_id` (API отдаёт её как `Category.imageUrl`); файлы WebP пишет вызывающий (`ImageStore`).
 */
import type { SyntheticCatalog } from '../src/integrations/onec/synthetic-catalog.js';
import type {
  OnecBarcodeItem,
  OnecCatalogItem,
  OnecNomenclatureItem,
  OnecPackagingItem,
  OnecPriceRow,
  OnecStockRow,
  OnecVariantItem,
} from '../src/integrations/onec/onec-catalog.types.js';

// ------------------------------------------------------------------ спецификация (demo/catalog/design-catalog.json)

export type DesignStockPlace = 'main' | 'wh2' | 'showroom';
export type DesignUnit = 'шт' | 'м' | 'кг' | 'м2';

export interface DesignSubcategorySpec {
  readonly id: string;
  readonly name: string;
  readonly sortOrder: number;
  /** Имя фото из `photos[]` или `null` (в макете картинки есть только у подкатегорий «Сантехники»). */
  readonly image: string | null;
}

export interface DesignCategorySpec extends DesignSubcategorySpec {
  readonly subs: readonly DesignSubcategorySpec[];
}

export interface DesignProductSpec {
  readonly cat: string;
  readonly sub: string;
  readonly name: string;
  readonly sku: string;
  /** Розничная цена, сом: `^\d+\.\d{2}$`. */
  readonly price: string;
  readonly unit: DesignUnit;
  /** Остаток по складам; `'unknown'` — строки остатка нет («Остаток неизвестен»). */
  readonly stock: Readonly<Partial<Record<DesignStockPlace, number | 'unknown'>>>;
  readonly photo: string | null;
  /** Товар макета (`P`), а не наполнитель. */
  readonly design: boolean;
  readonly isNew?: boolean;
  readonly variants?: { readonly axis: 'color' | 'size'; readonly values: readonly string[] };
  /** Коэффициенты упаковок «Коробка (N …)». */
  readonly packs?: readonly number[];
}

export interface DesignPhotoSpec {
  readonly name: string;
  /** Путь относительно `demo/catalog/`. */
  readonly file: string;
  /** Исходник в отслеживаемой копии макета (путь от корня репозитория). */
  readonly source: string;
  readonly sha256: string;
  readonly role: string;
}

export interface DesignCatalogSpec {
  readonly profile: string;
  readonly refSeed: number;
  readonly lowStockThreshold: number;
  readonly warehouses: Readonly<Record<DesignStockPlace, string>>;
  /** Артикулы избранного сотрудников стенда. */
  readonly favorites: readonly string[];
  readonly categories: readonly DesignCategorySpec[];
  readonly photos: readonly DesignPhotoSpec[];
  readonly products: readonly DesignProductSpec[];
}

/** Классы генератора: из `../src` (tsx), из `pos-api-dist` (сборка веб-демо). */
export interface DesignCatalogDeps {
  readonly SyntheticCatalog: typeof SyntheticCatalog;
  readonly ean13: (body12: string) => string;
}

/** Клиент БД: `pg.Client`/`pg.Pool` или pg-shim веб-демо. */
export interface DesignSqlClient {
  query(text: string, values?: readonly unknown[]): Promise<{ readonly rows: readonly Record<string, unknown>[] }>;
}

// ------------------------------------------------------------------ зеркальные константы генератора

/** `dataVersion(1)` генератора: 8 байт BE, счётчик 1 → base64. */
const V1 = 'AAAAAQAAAAA=';
/** Ссылки синтетических свойств генератора (одинаковы при любом seed). */
const PROPS = {
  color: { ref: '5e5e0000-0a77-4000-8000-000000000001', name: 'Цвет' },
  size: { ref: '5e5e0000-0a77-4000-8000-000000000002', name: 'Размер' },
} as const;
/** Коэффициенты видов цен к розничной, десятитысячные доли: «Розничная», «Оптовая» −10 %, «Крупный опт» −18 %. */
const PRICE_FACTORS = [10_000n, 9_000n, 8_200n] as const;
const PACK_UNIT = 'упак';
const UNITS: readonly DesignUnit[] = ['шт', 'м', 'кг', 'м2'];
const PLACES: readonly DesignStockPlace[] = ['main', 'wh2', 'showroom'];
const NOMENCLATURE = 'Catalog_Номенклатура';

// ------------------------------------------------------------------ деньги и количества без плавающей точки

/** `'8450.00'` → тыйыны. */
function tyiyn(price: string): bigint {
  const m = /^(\d+)\.(\d{2})$/.exec(price);
  if (!m) throw new Error(`design_catalog: цена «${price}» не в формате 0.00`);
  return BigInt(m[1] + m[2]);
}

/** Тыйыны → `^\d+\.\d{2}$`. */
function money(t: bigint): string {
  const s = t.toString().padStart(3, '0');
  return `${s.slice(0, -2)}.${s.slice(-2)}`;
}

/** Число из JSON (`140.5`) → строка количества `^\d+\.\d{3}$` по его десятичной записи (без арифметики float). */
function qtyText(n: number): string {
  const m = /^(\d+)(?:\.(\d{1,3}))?$/.exec(String(n));
  if (!m) throw new Error(`design_catalog: количество «${n}» — не более 3 знаков после запятой, ≥ 0`);
  return `${m[1]}.${(m[2] ?? '').padEnd(3, '0')}`;
}

const pad = (n: number, w: number): string => String(n).padStart(w, '0');

// ------------------------------------------------------------------ раскладка ссылок

interface FolderSlot {
  readonly path: string;
  readonly spec: DesignSubcategorySpec;
  readonly index: number;
  readonly parent: string | null;
}

interface ProductSlot {
  readonly spec: DesignProductSpec;
  readonly index: number;
}

/** Номера папок и товаров по порядку спецификации: ссылки `ref('category'|'product', N)` детерминированы. */
function layout(spec: DesignCatalogSpec): { folders: FolderSlot[]; products: ProductSlot[] } {
  const folders: FolderSlot[] = [];
  let ci = 0;
  for (const c of spec.categories) {
    ci += 1;
    folders.push({ path: c.id, spec: c, index: ci, parent: null });
    for (const s of c.subs) {
      ci += 1;
      folders.push({ path: `${c.id}/${s.id}`, spec: s, index: ci, parent: c.id });
    }
  }
  return { folders, products: spec.products.map((p, i) => ({ spec: p, index: i + 1 })) };
}

// ------------------------------------------------------------------ проверка спецификации

/** Ошибки спецификации (пустой список — можно строить). */
export function validateDesignSpec(spec: DesignCatalogSpec): string[] {
  const errs: string[] = [];
  if (!spec.profile) errs.push('profile пуст');
  if (!Number.isInteger(spec.refSeed) || spec.refSeed < 2) errs.push('refSeed — целое ≥ 2 (seed 1 — синтетика тестов)');
  if (!Number.isInteger(spec.lowStockThreshold) || spec.lowStockThreshold < 0)
    errs.push('lowStockThreshold — целое ≥ 0');
  for (const k of PLACES) if (!spec.warehouses?.[k]) errs.push(`warehouses.${k} не задан`);
  const photos = new Map<string, DesignPhotoSpec>();
  for (const p of spec.photos) {
    if (photos.has(p.name)) errs.push(`фото ${p.name} повторяется`);
    photos.set(p.name, p);
    if (p.file !== `photos/${p.name}.png`) errs.push(`фото ${p.name}: file ${p.file} ≠ photos/${p.name}.png`);
    if (!/^[0-9a-f]{64}$/.test(p.sha256)) errs.push(`фото ${p.name}: sha256 не hex`);
  }
  const used = new Set<string>();
  const usePhoto = (name: string | null, owner: string, role: string): void => {
    if (name === null) return;
    const p = photos.get(name);
    if (!p) errs.push(`${owner}: нет фото ${name} в photos[]`);
    else if (p.role !== role) errs.push(`${owner}: фото ${name} с ролью ${p.role}, ожидалась ${role}`);
    if (used.has(name)) errs.push(`фото ${name} назначено дважды`);
    used.add(name);
  };
  const subs = new Map<string, number>();
  const roots = new Set<string>();
  for (const c of spec.categories) {
    if (roots.has(c.id)) errs.push(`категория ${c.id} повторяется`);
    roots.add(c.id);
    if (!c.name || !Number.isInteger(c.sortOrder)) errs.push(`категория ${c.id}: name/sortOrder`);
    usePhoto(c.image, `категория ${c.id}`, `category:${c.id}`);
    const own = new Set<string>();
    for (const s of c.subs) {
      if (own.has(s.id)) errs.push(`подкатегория ${c.id}/${s.id} повторяется`);
      own.add(s.id);
      if (!s.name || !Number.isInteger(s.sortOrder)) errs.push(`подкатегория ${c.id}/${s.id}: name/sortOrder`);
      usePhoto(s.image, `подкатегория ${c.id}/${s.id}`, `category:${c.id}/${s.id}`);
      subs.set(`${c.id}/${s.id}`, 0);
    }
  }
  const skus = new Set<string>();
  const addSku = (sku: string, owner: string): void => {
    const k = sku.toUpperCase();
    if (skus.has(k)) errs.push(`${owner}: артикул ${sku} повторяется`);
    skus.add(k);
  };
  for (const p of spec.products) {
    const who = `товар ${p.sku}`;
    addSku(p.sku, who);
    if (!p.name) errs.push(`${who}: нет названия`);
    if (!/^\d+\.\d{2}$/.test(p.price) || tyiyn(p.price) <= 0n) errs.push(`${who}: цена ${p.price}`);
    if (!UNITS.includes(p.unit)) errs.push(`${who}: единица ${p.unit}`);
    const key = `${p.cat}/${p.sub}`;
    if (!subs.has(key)) errs.push(`${who}: нет подкатегории ${key}`);
    else subs.set(key, (subs.get(key) ?? 0) + 1);
    for (const [k, q] of Object.entries(p.stock)) {
      if (!PLACES.includes(k as DesignStockPlace)) errs.push(`${who}: склад ${k}`);
      if (q !== 'unknown') {
        try {
          qtyText(q);
        } catch (e) {
          errs.push(`${who}: ${(e as Error).message}`);
        }
      }
    }
    if (p.variants) {
      if (!['color', 'size'].includes(p.variants.axis) || p.variants.values.length < 2) errs.push(`${who}: variants`);
      if (new Set(p.variants.values).size !== p.variants.values.length)
        errs.push(`${who}: значения вариантов повторяются`);
      p.variants.values.forEach((_v, j) => addSku(`${p.sku}-${j + 1}`, `${who} (вариант)`));
    }
    for (const f of p.packs ?? []) if (!Number.isInteger(f) || f < 2) errs.push(`${who}: упаковка ${f}`);
    usePhoto(p.photo, who, `product:${p.sku}`);
  }
  for (const [k, n] of subs) if (n === 0) errs.push(`подкатегория ${k} без товаров (приложение скрывает пустые)`);
  for (const sku of spec.favorites)
    if (!spec.products.some((p) => p.sku === sku)) errs.push(`избранное: нет товара ${sku}`);
  for (const name of photos.keys()) if (!used.has(name)) errs.push(`фото ${name} ни к чему не привязано`);
  return errs;
}

// ------------------------------------------------------------------ сборка каталога

/** Каталог по спецификации — экземпляр `SyntheticCatalog` для `FakeOnecGateway({ catalog })` и `catalogProducts()`. */
export function buildDesignCatalog(spec: DesignCatalogSpec, deps: DesignCatalogDeps): SyntheticCatalog {
  const errs = validateDesignSpec(spec);
  if (errs.length) throw new Error(`design_catalog: спецификация с ошибками: ${errs.slice(0, 5).join('; ')}`);
  const cat = new deps.SyntheticCatalog({ skuCount: 0, seed: spec.refSeed });
  cat.categories.splice(0); // дерево генератора (ROOTS: Смесители, Санфаянс, …) — не наше
  const unitBy = new Map(cat.units.map((u) => [u.description, u]));
  const packUnit = unitBy.get(PACK_UNIT);
  if (!packUnit) throw new Error(`design_catalog: у генератора нет единицы «${PACK_UNIT}»`);
  const whBy = new Map(cat.warehouses.map((w) => [w.description, w.ref]));
  const wh = (k: DesignStockPlace): string => {
    const ref = whBy.get(spec.warehouses[k]);
    if (!ref) throw new Error(`design_catalog: у генератора нет склада «${spec.warehouses[k]}»`);
    return ref;
  };
  if (cat.priceLists.length < PRICE_FACTORS.length) throw new Error('design_catalog: у генератора меньше 3 видов цен');

  const items: OnecCatalogItem[] = [];
  const prices: OnecPriceRow[] = [];
  const stock: OnecStockRow[] = [];
  const { folders, products } = layout(spec);
  const folderRef = new Map<string, string>();
  for (const f of folders) {
    const ref = cat.ref('category', f.index);
    folderRef.set(f.path, ref);
    const folder: OnecNomenclatureItem = {
      type: NOMENCLATURE,
      ref,
      dataVersion: V1,
      deletionMark: false,
      isFolder: true,
      code: `DG${pad(f.index, 6)}`,
      description: f.spec.name,
      fullName: null,
      sku: null,
      parentRef: f.parent === null ? null : (folderRef.get(f.parent) ?? null),
      baseUnitRef: null,
      kindRef: null,
      descriptionText: null,
      imageFileRef: null,
      isWeighted: null,
      attributes: [],
    };
    items.push(folder);
  }
  let vi = 0;
  let ki = 0;
  for (const { spec: p, index: pi } of products) {
    const unit = unitBy.get(p.unit);
    if (!unit) throw new Error(`design_catalog: у генератора нет единицы «${p.unit}»`);
    const ref = cat.ref('product', pi);
    const product: OnecNomenclatureItem = {
      type: NOMENCLATURE,
      ref,
      dataVersion: V1,
      deletionMark: false,
      isFolder: false,
      code: `DP${pad(pi, 6)}`,
      description: p.name,
      fullName: `${p.name} (${unit.description})`,
      sku: p.sku,
      parentRef: folderRef.get(`${p.cat}/${p.sub}`) ?? null,
      baseUnitRef: unit.ref,
      kindRef: null,
      descriptionText: 'Тестовые данные демо.',
      imageFileRef: null,
      isWeighted: false,
      attributes: [],
    };
    items.push(product);
    const variants = (p.variants?.values ?? []).map((value, j): OnecVariantItem => {
      vi += 1;
      const prop = PROPS[p.variants!.axis];
      return {
        type: 'Catalog_ХарактеристикиНоменклатуры',
        ref: cat.ref('variant', vi),
        dataVersion: V1,
        deletionMark: false,
        code: `DV${pad(vi, 7)}`,
        description: value,
        ownerRef: ref,
        ownerType: NOMENCLATURE,
        sku: `${p.sku}-${j + 1}`,
        attributes: [
          { propertyRef: prop.ref, name: prop.name, valueType: 'Edm.String', valueRef: null, valueText: value },
        ],
      };
    });
    items.push(...variants);
    const packs = (p.packs ?? []).map((f): { item: OnecPackagingItem; factor: bigint } => {
      ki += 1;
      return {
        factor: BigInt(f),
        item: {
          type: 'Catalog_УпаковкиЕдиницыИзмерения',
          ref: cat.ref('packaging', ki),
          dataVersion: V1,
          deletionMark: false,
          description: `Коробка (${f} ${unit.description})`,
          ownerRef: ref,
          ownerType: NOMENCLATURE,
          unitRef: packUnit.ref,
          factor: `${f}.000`,
        },
      };
    });
    items.push(...packs.map((x) => x.item));
    const sellable: (string | null)[] = variants.length ? variants.map((v) => v.ref) : [null];
    const retail = tyiyn(p.price);
    for (const vr of sellable) {
      cat.priceLists.slice(0, PRICE_FACTORS.length).forEach((pl, i) => {
        const price = (retail * PRICE_FACTORS[i] + 5_000n) / 10_000n;
        prices.push({ priceListRef: pl.ref, productRef: ref, variantRef: vr, packagingRef: null, price: money(price) });
        // Цена за упаковку — только в оптовых видах цен (как у генератора).
        if (i > 0) {
          for (const pk of packs) {
            prices.push({
              priceListRef: pl.ref,
              productRef: ref,
              variantRef: vr,
              packagingRef: pk.item.ref,
              price: money(price * pk.factor),
            });
          }
        }
      });
      for (const k of PLACES) {
        const q = p.stock[k];
        if (q === undefined || q === 'unknown') continue;
        const t = qtyText(q);
        stock.push({
          warehouseRef: wh(k),
          productRef: ref,
          variantRef: vr,
          onHand: t,
          reserved: '0.000',
          available: t,
        });
      }
    }
    const codes: { value: string; variantRef: string | null; packagingRef: string | null }[] = [
      ...sellable.map((vr, i) => ({ value: ean13Of(deps, '23', pi, i), variantRef: vr, packagingRef: null })),
      ...packs.map((pk, i) => ({
        value: ean13Of(deps, '24', pi, i),
        variantRef: variants[0]?.ref ?? null,
        packagingRef: pk.item.ref,
      })),
    ];
    const barcodes = codes.map((b): OnecBarcodeItem => ({
      type: 'InformationRegister_ШтрихкодыНоменклатуры',
      ref: b.value,
      barcode: b.value,
      productRef: ref,
      variantRef: b.variantRef,
      packagingRef: b.packagingRef,
      barcodeType: 'EAN13',
    }));
    items.push(...barcodes);
  }
  cat.merge(items, prices, stock);
  return cat;
}

/** EAN-13 «PP NNNNNNNN II»: префикс 23 — товар/вариант, 24 — упаковка (генератор: 21/22 — не пересекаются). */
function ean13Of(deps: DesignCatalogDeps, prefix: string, productNo: number, i: number): string {
  return deps.ean13(`${prefix}${pad(productNo, 8)}${pad(i, 2)}`);
}

/** Порядок макета: `onec_ref` папки → `categories.sort_order`. */
export function categoryOrder(
  spec: DesignCatalogSpec,
  catalog: SyntheticCatalog,
): { onecRef: string; sortOrder: number; path: string }[] {
  return layout(spec).folders.map((f) => ({
    onecRef: catalog.ref('category', f.index),
    sortOrder: f.spec.sortOrder,
    path: f.path,
  }));
}

export interface DesignPhotoPlanItem {
  readonly onecRef: string;
  /** Артикул товара или путь категории `plumbing/toilets`. */
  readonly owner: string;
  readonly photo: string;
  readonly file: string;
  readonly sha256: string;
}

/** Фото: товары (`<onec_ref>.png` → `ImageDirectoryImporter`) и категории (`registerCategoryImage`). */
export function photoPlan(
  spec: DesignCatalogSpec,
  catalog: SyntheticCatalog,
): { products: DesignPhotoPlanItem[]; categories: DesignPhotoPlanItem[] } {
  const byName = new Map(spec.photos.map((p) => [p.name, p]));
  const item = (onecRef: string, owner: string, name: string): DesignPhotoPlanItem => {
    const p = byName.get(name);
    if (!p) throw new Error(`design_catalog: нет фото ${name}`);
    return { onecRef, owner, photo: name, file: p.file, sha256: p.sha256 };
  };
  const { folders, products } = layout(spec);
  return {
    products: products
      .filter((x) => x.spec.photo !== null)
      .map((x) => item(catalog.ref('product', x.index), x.spec.sku, x.spec.photo!)),
    categories: folders
      .filter((f) => f.spec.image !== null)
      .map((f) => item(catalog.ref('category', f.index), f.path, f.spec.image!)),
  };
}

// ------------------------------------------------------------------ SQL после загрузки каталога

/**
 * Порядок категорий макета, порог «мало» и избранное сотрудников стенда. Идемпотентно (повтор ничего не меняет).
 * `client` — одно соединение (транзакция порога: `SET LOCAL app.system = 'migration'`, как у seed — аудит
 * «settings.changed» без актора). → число изменённых строк.
 */
export async function applyDesignCatalogSettings(
  client: DesignSqlClient,
  spec: DesignCatalogSpec,
  catalog: SyntheticCatalog,
  { staffPhones = [] }: { readonly staffPhones?: readonly string[] } = {},
): Promise<{ sortOrder: number; lowStockThreshold: number; favorites: number }> {
  const order = categoryOrder(spec, catalog);
  const so = await client.query(
    `UPDATE categories c SET sort_order = v.sort_order, updated_at = now()
       FROM unnest($1::uuid[], $2::int[]) AS v(ref, sort_order)
      WHERE c.onec_ref = v.ref AND c.sort_order IS DISTINCT FROM v.sort_order
      RETURNING c.id`,
    [order.map((o) => o.onecRef), order.map((o) => o.sortOrder)],
  );
  await client.query('BEGIN');
  let threshold: number;
  try {
    await client.query(`SET LOCAL app.system = 'migration'`);
    const th = await client.query(
      `UPDATE app_settings SET value = to_jsonb($1::int), row_version = row_version + 1, updated_at = now()
        WHERE key = 'low_stock_threshold' AND value IS DISTINCT FROM to_jsonb($1::int)
        RETURNING key`,
      [spec.lowStockThreshold],
    );
    threshold = th.rows.length;
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  }
  const fav = staffPhones.length
    ? await client.query(
        `INSERT INTO favorites_products (user_id, product_id)
         SELECT u.id, p.id FROM users u CROSS JOIN products p
          WHERE u.phone_e164 = ANY($1::text[]) AND u.deleted_at IS NULL AND p.sku = ANY($2::text[]) AND NOT p.deletion_mark
         ORDER BY u.phone_e164, p.sku
         ON CONFLICT DO NOTHING
         RETURNING user_id`,
        [[...staffPhones], [...spec.favorites]],
      )
    : { rows: [] };
  return { sortOrder: so.rows.length, lowStockThreshold: threshold, favorites: fav.rows.length };
}

/** Метаданные готового фото (`processImage` pos-api). */
export interface DesignImageMeta {
  readonly sha256: string;
  readonly originalMime: string;
  readonly originalBytes: number;
  readonly width: number;
  readonly height: number;
  readonly sizes: Readonly<Record<string, { readonly w: number; readonly h: number; readonly bytes: number }>>;
}

/**
 * Картинка категории: строка `product_images` (`category_id`, `source_ref = import:category:<ref>/<файл>` — не
 * UUID, поэтому HS-синхронизация фото её не снимает; `ready`, основная) и `categories.image_id`. Файлы
 * `images/{sha}/{thumb|card|full}.webp` к этому моменту уже записаны (`ImageStore.write`). Идемпотентно.
 */
export async function registerCategoryImage(
  client: DesignSqlClient,
  {
    categoryRef,
    fileName,
    image,
  }: { readonly categoryRef: string; readonly fileName: string; readonly image: DesignImageMeta },
): Promise<{ id: string } | null> {
  const sourceRef = `import:category:${categoryRef}/${fileName}`;
  const cat = await client.query(`SELECT id::text AS id FROM categories WHERE onec_ref = $1::uuid`, [categoryRef]);
  const categoryId = cat.rows[0]?.id as string | undefined;
  if (!categoryId) return null;
  // Одна основная картинка у категории (product_images_primary_uq): прежняя основная другого файла — не основная.
  await client.query(
    `UPDATE product_images SET is_primary = false, updated_at = now()
      WHERE category_id = $1::uuid AND is_primary AND deleted_at IS NULL AND source_ref <> $2`,
    [categoryId, sourceRef],
  );
  const r = await client.query(
    `INSERT INTO product_images (category_id, source_ref, source_version, checksum_sha256, storage_key, original_mime,
                                 original_bytes, width, height, sizes, sort_order, is_primary, status)
     VALUES ($1::uuid, $2, $3, decode($4, 'hex'), $5, $6, $7, $8, $9, $10::jsonb, 0, true, 'ready')
     ON CONFLICT (source_ref) WHERE deleted_at IS NULL DO UPDATE
        SET source_version = EXCLUDED.source_version, checksum_sha256 = EXCLUDED.checksum_sha256,
            storage_key = EXCLUDED.storage_key, original_mime = EXCLUDED.original_mime,
            original_bytes = EXCLUDED.original_bytes, width = EXCLUDED.width, height = EXCLUDED.height,
            sizes = EXCLUDED.sizes, is_primary = true, status = 'ready', error = NULL, updated_at = now()
      WHERE product_images.source_version IS DISTINCT FROM EXCLUDED.source_version OR NOT product_images.is_primary
            OR product_images.status <> 'ready'
     RETURNING id::text AS id`,
    [
      categoryId,
      sourceRef,
      `sha256:${image.sha256}`,
      image.sha256,
      `images/${image.sha256}`,
      image.originalMime,
      image.originalBytes,
      image.width,
      image.height,
      JSON.stringify(image.sizes),
    ],
  );
  const id =
    (r.rows[0]?.id as string | undefined) ??
    ((
      await client.query(`SELECT id::text AS id FROM product_images WHERE source_ref = $1 AND deleted_at IS NULL`, [
        sourceRef,
      ])
    ).rows[0]?.id as string | undefined);
  if (!id) return null;
  await client.query(
    `UPDATE categories SET image_id = $2::uuid, updated_at = now() WHERE id = $1::uuid AND image_id IS DISTINCT FROM $2::uuid`,
    [categoryId, id],
  );
  return { id };
}

// ------------------------------------------------------------------ сверка с генератором

/**
 * Зеркальные константы этого модуля = вывод генератора (`new SyntheticCatalog({ skuCount: 40, seed: 1 })`):
 * `dataVersion(1)`, ссылки и имена свойств «Цвет»/«Размер», коэффициенты видов цен, единицы и склады спецификации.
 * → список расхождений (пусто — всё сходится).
 */
export function checkGeneratorMirror(deps: DesignCatalogDeps, spec?: DesignCatalogSpec): string[] {
  const errs: string[] = [];
  const g = new deps.SyntheticCatalog({ skuCount: 40, seed: 1 });
  const products = g.productItems();
  if (!products.length || products.some((p) => p.dataVersion !== V1))
    errs.push(`dataVersion товаров генератора ≠ ${V1}`);
  const props = new Map<string, string>();
  for (const v of g.variants()) for (const a of v.attributes ?? []) props.set(a.name, a.propertyRef);
  for (const p of Object.values(PROPS)) {
    if (!props.has(p.name)) errs.push(`у генератора нет свойства «${p.name}» среди характеристик (seed 1, 40 SKU)`);
    else if (props.get(p.name) !== p.ref) errs.push(`свойство «${p.name}»: генератор ${props.get(p.name)} ≠ ${p.ref}`);
  }
  const units = new Set(g.units.map((u) => u.description));
  for (const u of [...UNITS, PACK_UNIT]) if (!units.has(u)) errs.push(`у генератора нет единицы «${u}»`);
  if (g.priceLists.length < PRICE_FACTORS.length) errs.push('у генератора меньше 3 видов цен');
  // Коэффициенты: цена вида i = round(розничная × k_i) у товара без упаковок и характеристик.
  const rows = g.priceSlice();
  let checked = 0;
  for (const p of products) {
    const own = rows.filter((r) => r.productRef === p.ref && r.packagingRef === null && r.variantRef === null);
    if (own.length < PRICE_FACTORS.length) continue;
    const by = (i: number): bigint | undefined => {
      const r = own.find((x) => x.priceListRef === g.priceLists[i]?.ref);
      return r ? tyiyn(r.price) : undefined;
    };
    const retail = by(0);
    if (retail === undefined) continue;
    PRICE_FACTORS.forEach((f, i) => {
      const want = (retail * f + 5_000n) / 10_000n;
      if (by(i) !== want)
        errs.push(`вид цены ${i + 1} товара ${p.sku}: генератор ${String(by(i))} ≠ розничная × ${f}/10000 = ${want}`);
    });
    checked += 1;
    if (checked >= 5) break;
  }
  if (!checked) errs.push('коэффициенты видов цен не проверены: у генератора нет товара без характеристик с 3 ценами');
  if (spec) {
    const wh = new Set(g.warehouses.map((w) => w.description));
    for (const k of PLACES)
      if (!wh.has(spec.warehouses[k])) errs.push(`у генератора нет склада «${spec.warehouses[k]}»`);
  }
  return errs;
}
