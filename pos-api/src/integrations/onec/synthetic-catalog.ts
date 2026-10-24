import type {
  OnecAttributeValue,
  OnecBarcodeItem,
  OnecCatalogItem,
  OnecNomenclatureItem,
  OnecPackagingItem,
  OnecPriceListItem,
  OnecPriceRow,
  OnecPriceSettingItem,
  OnecStockRow,
  OnecUnitItem,
  OnecVariantItem,
  OnecWarehouseItem,
} from './onec-catalog.types.js';

/**
 * Детерминированный синтетический каталог «как из 1С» (RM-E-001, RM-E-005 бенчмарк на 50 000 SKU, RM-E-011 на
 * фикстурах). **Тестовые данные**: реальных товаров, цен и клиентов нет; бренды — общеизвестные марки сантехники,
 * артикулы и штрихкоды выдуманы. Штрихкоды — EAN-13 с префиксом `2` (внутренняя нумерация GS1, «restricted
 * circulation»), поэтому не совпадают с реальными товарами; контрольная цифра верна.
 *
 * Одинаковые параметры (`seed`, `skuCount`, …) дают побайтно одинаковый каталог; ссылки — UUID вида
 * `SSSSSSSS-KKKK-4000-8000-IIIIIIIIIIII` (seed, вид объекта, порядковый номер) в нижнем регистре.
 */
export interface SyntheticCatalogOptions {
  /** Число товаров (SKU = номенклатура без групп). */
  readonly skuCount: number;
  /** Зерно генератора (по умолчанию 1). */
  readonly seed?: number;
  /** Складов (по умолчанию 3). */
  readonly warehouses?: number;
  /** Видов цен (по умолчанию 3: «Розничная», «Оптовая», «Крупный опт»). */
  readonly priceLists?: number; // money-double: allow — число видов цен генератора, не деньги
  /** Доля товаров с характеристиками (по умолчанию 0.2), у каждого 2–4 варианта. */
  readonly variantShare?: number;
  /** Доля товаров с упаковками (по умолчанию 0.3). */
  readonly packagingShare?: number;
  /** Доля товаров с пометкой удаления (по умолчанию 0.01). */
  readonly deletedShare?: number;
  /** Доля пар «вариант × склад» с остатком (по умолчанию 0.7). */
  readonly stockShare?: number;
}

export interface SyntheticCatalogStats {
  readonly units: number;
  readonly categories: number;
  readonly products: number;
  readonly productsDeleted: number;
  readonly variants: number;
  readonly sellableVariants: number;
  readonly packagings: number;
  readonly barcodes: number;
  readonly warehouses: number;
  readonly priceLists: number; // money-double: allow — число видов цен генератора, не деньги
  readonly prices: number; // money-double: allow — число строк цен генератора, не деньги
  readonly stockRows: number;
  readonly attributes: number;
}

/** Изменения «следующей версии» 1С (инкремент). */
export interface SyntheticMutation {
  /** Переименовать N товаров (новый `dataVersion`, новое содержимое). */
  readonly renameProducts?: number;
  /** Пометить на удаление N товаров. */
  readonly deleteProducts?: number;
  /** Добавить N новых товаров (с вариантом по умолчанию, ценами и штрихкодом). */
  readonly addProducts?: number;
  /** Изменить цену N строк среза (с документом `УстановкаЦенНоменклатуры`). */
  readonly repricePrices?: number; // money-double: allow — число переоценённых строк генератора, не деньги
  /** Изменить остаток N строк среза. */
  readonly restockRows?: number;
  /** «Перезаписать без изменений» N товаров: новый `dataVersion`, содержимое то же (SYNC-013). */
  readonly touchProducts?: number;
}

/** Результат мутации: ключи изменённых объектов (для регистрации в плане обмена фейка). */
export interface SyntheticMutationResult {
  /** `type:ref` изменённых элементов `/changes`. */
  readonly changedKeys: readonly string[];
  readonly priceListRefs: readonly string[];
  readonly stockWarehouseRefs: readonly string[];
}

/** Якорные товары (одинаковы при любом seed) — для тестов поиска RM-E-005 («смеситель фрап», «Frap F4252»). */
export const SYNTHETIC_ANCHORS = [
  { name: 'Смеситель для кухни Frap F4252 хром', sku: 'F4252', root: 0 },
  { name: 'Смеситель для ванны Frap F3241 с душем', sku: 'F3241', root: 0 },
  { name: 'Смеситель для раковины Gappo G1017-8', sku: 'G1017-8', root: 0 },
  { name: 'Унитаз-компакт Santek Бореал белый', sku: 'SB-1WH', root: 1 },
  { name: 'Труба ППР 20 мм PN20 Valtec', sku: 'VTP-20', root: 2 },
] as const;

const ROOTS: readonly { name: string; children: readonly string[]; unit: number; nouns: readonly string[] }[] = [
  {
    name: 'Смесители',
    children: ['Для кухни', 'Для ванны', 'Для раковины', 'Душевые системы', 'Комплектующие'],
    unit: 0,
    nouns: ['Смеситель для кухни', 'Смеситель для ванны', 'Смеситель для раковины', 'Душевая система', 'Лейка душевая'],
  },
  {
    name: 'Санфаянс',
    children: ['Унитазы', 'Раковины', 'Биде', 'Инсталляции'],
    unit: 0,
    nouns: [
      'Унитаз-компакт',
      'Раковина накладная',
      'Раковина с пьедесталом',
      'Инсталляция для унитаза',
      'Биде подвесное',
    ],
  },
  {
    name: 'Трубы и фитинги',
    children: ['Трубы ППР', 'Фитинги ППР', 'Металлопласт', 'Канализация'],
    unit: 1,
    nouns: ['Труба ППР', 'Муфта ППР', 'Уголок ППР', 'Тройник ППР', 'Труба канализационная'],
  },
  {
    name: 'Отопление',
    children: ['Радиаторы', 'Котлы', 'Насосы', 'Терморегуляция'],
    unit: 0,
    nouns: ['Радиатор биметаллический', 'Котёл газовый', 'Насос циркуляционный', 'Термоголовка', 'Кран шаровой'],
  },
  {
    name: 'Инструмент',
    children: ['Электроинструмент', 'Ручной инструмент', 'Расходники'],
    unit: 0,
    nouns: ['Дрель ударная', 'Перфоратор', 'Набор ключей', 'Круг отрезной', 'Сверло по бетону'],
  },
  {
    name: 'Электрика',
    children: ['Кабель', 'Розетки и выключатели', 'Автоматы'],
    unit: 1,
    nouns: ['Кабель ВВГнг', 'Провод ПВС', 'Розетка двойная', 'Выключатель одноклавишный', 'Автомат дифференциальный'],
  },
  {
    name: 'Сухие смеси',
    children: ['Штукатурки', 'Плиточный клей', 'Наливные полы'],
    unit: 2,
    nouns: ['Штукатурка гипсовая', 'Клей плиточный', 'Наливной пол', 'Шпаклёвка финишная', 'Затирка для швов'],
  },
  {
    name: 'Плитка',
    children: ['Настенная', 'Напольная', 'Керамогранит'],
    unit: 3,
    nouns: ['Плитка настенная', 'Плитка напольная', 'Керамогранит', 'Бордюр керамический', 'Мозаика'],
  },
  {
    name: 'Крепёж',
    children: ['Саморезы', 'Дюбели', 'Анкеры'],
    unit: 0,
    nouns: ['Саморез по дереву', 'Дюбель-гвоздь', 'Анкер клиновой', 'Шуруп универсальный', 'Болт с гайкой'],
  },
  {
    name: 'Ванны и душевые',
    children: ['Ванны акриловые', 'Душевые кабины', 'Поддоны'],
    unit: 0,
    nouns: ['Ванна акриловая', 'Душевая кабина', 'Душевой поддон', 'Шторка для ванны', 'Карниз для ванны'],
  },
];

/** Единицы (код ОКЕИ, обозначение): 0 — шт, 1 — м, 2 — кг, 3 — м2, 4 — упак, 5 — л, 6 — компл, 7 — рул. */
const UNITS: readonly (readonly [string, string])[] = [
  ['796', 'шт'],
  ['006', 'м'],
  ['166', 'кг'],
  ['055', 'м2'],
  ['778', 'упак'],
  ['112', 'л'],
  ['839', 'компл'],
  ['736', 'рул'],
];
const PACK_UNIT = 4;

const BRANDS: readonly (readonly [string, string])[] = [
  ['Frap', 'F'],
  ['Gappo', 'G'],
  ['Haiba', 'HB'],
  ['Ledeme', 'L'],
  ['Kaiser', 'K'],
  ['Valtec', 'VT'],
  ['Santek', 'S'],
  ['Rubineta', 'RB'],
];
const COLORS = ['хром', 'белый', 'чёрный матовый', 'бронза', 'золото', 'графит'];
const SIZES = ['1/2"', '3/4"', '1"', '20 мм', '25 мм', '32 мм', '40 мм'];
const COUNTRIES = ['Китай', 'Россия', 'Турция', 'Германия', 'Кыргызстан'];
const MATERIALS = ['латунь', 'нержавеющая сталь', 'пластик', 'керамика', 'чугун'];
const WAREHOUSE_NAMES = ['Основной склад', 'Склад №2', 'Шоурум', 'Склад №4', 'Склад №5', 'Склад №6'];
const PRICE_LIST_NAMES = ['Розничная', 'Оптовая', 'Крупный опт', 'Дилерская', 'Специальная'];
/** Коэффициенты видов цен к розничной, в десятитысячных долях (опт −10 %, крупный опт −18 %, …). */
const PRICE_FACTORS = [10_000n, 9_000n, 8_200n, 7_800n, 7_500n];

/** Ссылки синтетических свойств (одинаковы при любом seed — у справочника свойств своя нумерация). */
const PROPS = {
  color: { ref: '5e5e0000-0a77-4000-8000-000000000001', name: 'Цвет' },
  size: { ref: '5e5e0000-0a77-4000-8000-000000000002', name: 'Размер' },
  country: { ref: '5e5e0000-0a77-4000-8000-000000000003', name: 'Страна' },
  material: { ref: '5e5e0000-0a77-4000-8000-000000000004', name: 'Материал' },
  warranty: { ref: '5e5e0000-0a77-4000-8000-000000000005', name: 'Гарантия, лет' },
} as const;

/** Коды видов объектов в ссылке (второй блок UUID). */
const KIND = {
  unit: 0x0001,
  category: 0x0002,
  product: 0x0003,
  variant: 0x0004,
  packaging: 0x0005,
  warehouse: 0x0006,
  priceList: 0x0007,
  propValue: 0x0008,
  priceDoc: 0x0009,
} as const;

/** EAN-13 с верной контрольной цифрой для 12 цифр тела. */
export function ean13(body12: string): string {
  if (!/^\d{12}$/.test(body12)) throw new Error('ean13: нужно 12 цифр');
  let sum = 0;
  for (let i = 0; i < 12; i++) sum += Number(body12[i]) * (i % 2 === 0 ? 1 : 3);
  return body12 + String((10 - (sum % 10)) % 10);
}

/** Проверка контрольной цифры EAN-13. */
export function isValidEan13(code: string): boolean {
  return /^\d{13}$/.test(code) && ean13(code.slice(0, 12)) === code;
}

/** mulberry32 — быстрый детерминированный PRNG. */
export function prng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function hex(n: number, width: number): string {
  return n.toString(16).padStart(width, '0').slice(-width);
}

function dataVersion(counter: number): string {
  const b = Buffer.alloc(8);
  b.writeUInt32BE(counter >>> 0, 0);
  return b.toString('base64');
}

/** Тыйыны → строка денег `^\d+\.\d{2}$`. */
function money(tyiyn: bigint): string {
  const s = tyiyn.toString().padStart(3, '0');
  return `${s.slice(0, -2)}.${s.slice(-2)}`;
}

/** Тысячные → строка количества `^\d+\.\d{3}$`. */
function qty(milli: number): string {
  const s = String(milli).padStart(4, '0');
  return `${s.slice(0, -3)}.${s.slice(-3)}`;
}

/** Строка количества `^-?\d+\.\d{3}$` → тысячные (целые, без float). */
function parseMilli(v: string): number {
  const m = /^(-?)(\d+)(?:\.(\d{1,3}))?$/.exec(v);
  if (!m) throw new Error(`количество: ${v}`);
  const n = Number(m[2]) * 1000 + Number((m[3] ?? '').padEnd(3, '0'));
  return m[1] ? -n : n;
}

/** Ключ элемента плана обмена: `type:ref`. */
export function itemKey(item: { readonly type: string; readonly ref: string }): string {
  return `${item.type}:${item.ref}`;
}

interface ProductState {
  item: OnecNomenclatureItem;
  /** Характеристики товара (пусто — служебный вариант). */
  variants: OnecVariantItem[];
  packagings: OnecPackagingItem[];
  /** Розничная цена за базовую единицу по варианту (`null` — товар без характеристик). */
  retail: Map<string | null, bigint>;
}

/**
 * Синтетический каталог: справочники в формате `/changes` + срезы цен и остатков. Создаётся `generate()`;
 * `mutate()` порождает «следующую версию» (переименование, удаление, новые товары, цены, остатки).
 */
export class SyntheticCatalog {
  readonly seed: number;
  readonly units: OnecUnitItem[] = [];
  readonly categories: OnecNomenclatureItem[] = [];
  readonly warehouses: OnecWarehouseItem[] = [];
  readonly priceLists: OnecPriceListItem[] = [];
  readonly priceSettings: OnecPriceSettingItem[] = [];
  /** Прочие элементы `/changes` (например, файлы картинок из фикстур) — передаются как есть. */
  readonly extras: OnecCatalogItem[] = [];
  private readonly products: ProductState[] = [];
  private readonly productByRef = new Map<string, ProductState>();
  private readonly barcodeItems = new Map<string, OnecBarcodeItem>();
  /** Срез цен: ключ `priceList|variant|packaging` → строка. */
  private readonly priceRows = new Map<string, OnecPriceRow>();
  /** Срез остатков: ключ `warehouse|product|variant` → строка. */
  private readonly stockRows = new Map<string, OnecStockRow>();
  private readonly leafCategories: { ref: string; root: number }[] = [];
  private versionCounter = 1;
  private mutationNo = 0;
  private nextProductIndex = 0;
  private nextVariantIndex = 0;
  private nextPackagingIndex = 0;
  private readonly opts: Required<SyntheticCatalogOptions>;

  constructor(options: SyntheticCatalogOptions) {
    if (!Number.isInteger(options.skuCount) || options.skuCount < 0) throw new Error('skuCount — целое ≥ 0');
    this.opts = {
      skuCount: options.skuCount,
      seed: options.seed ?? 1,
      warehouses: Math.max(1, Math.min(options.warehouses ?? 3, WAREHOUSE_NAMES.length)),
      priceLists: Math.max(1, Math.min(options.priceLists ?? 3, PRICE_LIST_NAMES.length)),
      variantShare: options.variantShare ?? 0.2,
      packagingShare: options.packagingShare ?? 0.3,
      deletedShare: options.deletedShare ?? 0.01,
      stockShare: options.stockShare ?? 0.7,
    };
    this.seed = this.opts.seed;
    this.generate();
  }

  ref(kind: keyof typeof KIND, index: number): string {
    return `${hex(this.seed, 8)}-${hex(KIND[kind], 4)}-4000-8000-${hex(index, 12)}`;
  }

  // ------------------------------------------------------------------ чтение

  /** Справочные элементы (в текущем состоянии) по виду. */
  nomenclature(): OnecNomenclatureItem[] {
    return [...this.categories, ...this.products.map((p) => p.item)];
  }

  productItems(): OnecNomenclatureItem[] {
    return this.products.map((p) => p.item);
  }

  variants(): OnecVariantItem[] {
    return this.products.flatMap((p) => p.variants);
  }

  packagings(): OnecPackagingItem[] {
    return this.products.flatMap((p) => p.packagings);
  }

  barcodes(): OnecBarcodeItem[] {
    return [...this.barcodeItems.values()];
  }

  /** Все элементы `/changes` каталога (справочники + штрихкоды) в порядке зависимостей. */
  allItems(): OnecCatalogItem[] {
    return [
      ...this.units,
      ...this.warehouses,
      ...this.priceLists,
      ...this.nomenclature(),
      ...this.variants(),
      ...this.packagings(),
      ...this.barcodes(),
      ...this.extras,
    ];
  }

  /** Элемент по ключу `type:ref` (текущее состояние) — для страниц `/changes` фейка. */
  itemByKey(key: string): OnecCatalogItem | undefined {
    return this.index().get(key);
  }

  private indexCache: Map<string, OnecCatalogItem> | undefined;
  private index(): Map<string, OnecCatalogItem> {
    if (!this.indexCache) {
      this.indexCache = new Map();
      for (const it of [...this.allItems(), ...this.priceSettings]) this.indexCache.set(itemKey(it), it);
    }
    return this.indexCache;
  }

  /** Срез цен (по видам цен или все). */
  priceSlice(priceListRefs?: readonly string[]): OnecPriceRow[] {
    const filter = priceListRefs ? new Set(priceListRefs) : undefined;
    return [...this.priceRows.values()].filter((r) => !filter || filter.has(r.priceListRef));
  }

  /** Срез остатков (по складам или все). */
  stockSlice(warehouseRefs?: readonly string[]): OnecStockRow[] {
    const filter = warehouseRefs ? new Set(warehouseRefs) : undefined;
    return [...this.stockRows.values()].filter((r) => !filter || filter.has(r.warehouseRef));
  }

  /** Карточка товара (`GET /pos/v1/catalog/{ref}`, ONEC-057) или `undefined`. */
  card(productRef: string): Record<string, unknown> | undefined {
    const p = this.productByRef.get(productRef);
    if (!p) return undefined;
    const variantRefs = new Set<string | null>([null, ...p.variants.map((v) => v.ref)]);
    return {
      product: p.item,
      variants: p.variants,
      packagings: p.packagings,
      barcodes: this.barcodes().filter((b) => b.productRef === productRef),
      prices: [...this.priceRows.values()]
        .filter((r) => r.productRef === productRef)
        .map((r) => ({
          priceListRef: r.priceListRef,
          variantRef: r.variantRef,
          packagingRef: r.packagingRef,
          price: r.price,
        })),
      stock: [...this.stockRows.values()]
        .filter((r) => r.productRef === productRef && variantRefs.has(r.variantRef))
        .map((r) => ({
          warehouseRef: r.warehouseRef,
          variantRef: r.variantRef,
          onHand: r.onHand,
          reserved: r.reserved,
          available: r.available ?? r.onHand,
        })),
      snapshotAt: '2026-10-21T14:00:00+06:00',
    };
  }

  stats(): SyntheticCatalogStats {
    const variants = this.variants().length;
    const sellable = this.products.reduce((n, p) => n + (p.variants.length === 0 ? 1 : p.variants.length), 0);
    return {
      units: this.units.length,
      categories: this.categories.length,
      products: this.products.length,
      productsDeleted: this.products.filter((p) => p.item.deletionMark).length,
      variants,
      sellableVariants: sellable,
      packagings: this.packagings().length,
      barcodes: this.barcodeItems.size,
      warehouses: this.warehouses.length,
      priceLists: this.priceLists.length,
      prices: this.priceRows.size,
      stockRows: this.stockRows.size,
      attributes: Object.keys(PROPS).length,
    };
  }

  // ------------------------------------------------------------------ генерация

  private nextVersion(): string {
    this.versionCounter += 1;
    return dataVersion(this.versionCounter);
  }

  private generate(): void {
    const rnd = prng(this.seed * 7919 + 17);
    UNITS.forEach(([code, name], i) =>
      this.units.push({
        type: 'Catalog_КлассификаторЕдиницИзмерения',
        ref: this.ref('unit', i + 1),
        dataVersion: dataVersion(1),
        deletionMark: false,
        code,
        description: name,
      }),
    );
    for (let i = 0; i < this.opts.warehouses; i++) {
      this.warehouses.push({
        type: 'Catalog_Склады',
        ref: this.ref('warehouse', i + 1),
        dataVersion: dataVersion(1),
        deletionMark: false,
        isFolder: false,
        code: String(i + 1).padStart(9, '0'),
        description: WAREHOUSE_NAMES[i] ?? `Склад ${i + 1}`,
      });
    }
    for (let i = 0; i < this.opts.priceLists; i++) {
      this.priceLists.push({
        type: 'Catalog_ВидыЦен',
        ref: this.ref('priceList', i + 1),
        dataVersion: dataVersion(1),
        deletionMark: false,
        code: String(i + 1).padStart(9, '0'),
        description: PRICE_LIST_NAMES[i] ?? `Вид цены ${i + 1}`,
        currency: 'KGS',
        usedForSales: true,
        priceIncludesVat: true,
      });
    }
    // Дерево категорий: корни → подкатегории → у части подкатегорий 2–3 вложенных («серия»).
    let catIndex = 0;
    const folder = (name: string, parentRef: string | null): OnecNomenclatureItem => {
      catIndex += 1;
      const item: OnecNomenclatureItem = {
        type: 'Catalog_Номенклатура',
        ref: this.ref('category', catIndex),
        dataVersion: dataVersion(1),
        deletionMark: false,
        isFolder: true,
        code: `G${String(catIndex).padStart(7, '0')}`,
        description: name,
        fullName: null,
        sku: null,
        parentRef,
        baseUnitRef: null,
        kindRef: null,
        descriptionText: null,
        imageFileRef: null,
        isWeighted: null,
        attributes: [],
      };
      this.categories.push(item);
      return item;
    };
    ROOTS.forEach((root, r) => {
      const rootItem = folder(root.name, null);
      root.children.forEach((child, c) => {
        const childItem = folder(child, rootItem.ref);
        if (c % 2 === 0) {
          const grand = 2 + Math.floor(rnd() * 2);
          for (let g = 0; g < grand; g++) {
            const gi = folder(`${child}: серия ${g + 1}`, childItem.ref);
            this.leafCategories.push({ ref: gi.ref, root: r });
          }
        } else {
          this.leafCategories.push({ ref: childItem.ref, root: r });
        }
      });
    });
    for (let i = 0; i < this.opts.skuCount; i++) this.addProduct(rnd, i < SYNTHETIC_ANCHORS.length ? i : undefined);
    // Стартовые срезы: deletion_mark — после генерации, чтобы выборка была детерминированной.
    const deleted = Math.floor(this.opts.skuCount * this.opts.deletedShare);
    for (let k = 0; k < deleted; k++) {
      const p =
        this.products[
          SYNTHETIC_ANCHORS.length + Math.floor(rnd() * Math.max(1, this.products.length - SYNTHETIC_ANCHORS.length))
        ];
      if (p) p.item = { ...p.item, deletionMark: true };
    }
  }

  private addProduct(rnd: () => number, anchor?: number): ProductState {
    this.nextProductIndex += 1;
    const index = this.nextProductIndex;
    const a = anchor !== undefined ? SYNTHETIC_ANCHORS[anchor] : undefined;
    const rootIdx = a ? a.root : Math.floor(rnd() * ROOTS.length);
    const root = ROOTS[rootIdx];
    const leaves = this.leafCategories.filter((l) => l.root === rootIdx);
    const leaf = leaves[Math.floor(rnd() * leaves.length)];
    const [brand, prefix] = BRANDS[Math.floor(rnd() * BRANDS.length)];
    const model = `${prefix}${1000 + Math.floor(rnd() * 9000)}${rnd() < 0.2 ? `-${1 + Math.floor(rnd() * 9)}` : ''}`;
    const noun = root.nouns[Math.floor(rnd() * root.nouns.length)];
    const color = COLORS[Math.floor(rnd() * COLORS.length)];
    const name = a ? a.name : `${noun} ${brand} ${model} ${color}`;
    const sku = a ? a.sku : model;
    const unitIdx = root.unit;
    const baseUnit = this.units[unitIdx];
    const attributes: OnecAttributeValue[] = [
      {
        propertyRef: PROPS.country.ref,
        name: PROPS.country.name,
        valueType: 'Edm.String',
        valueRef: null,
        valueText: COUNTRIES[Math.floor(rnd() * COUNTRIES.length)],
      },
    ];
    if (rnd() < 0.6) {
      const m = Math.floor(rnd() * MATERIALS.length);
      attributes.push({
        propertyRef: PROPS.material.ref,
        name: PROPS.material.name,
        valueType: 'Catalog_ЗначенияСвойствОбъектов',
        valueRef: this.ref('propValue', 100 + m),
        valueText: MATERIALS[m],
      });
    }
    if (rnd() < 0.4) {
      attributes.push({
        propertyRef: PROPS.warranty.ref,
        name: PROPS.warranty.name,
        valueType: 'Edm.Double',
        valueRef: null,
        valueText: String(1 + Math.floor(rnd() * 5)),
      });
    }
    const item: OnecNomenclatureItem = {
      type: 'Catalog_Номенклатура',
      ref: this.ref('product', index),
      dataVersion: dataVersion(1),
      deletionMark: false,
      isFolder: false,
      code: String(index).padStart(8, '0'),
      description: name,
      fullName: `${name} (${baseUnit.description})`,
      sku,
      parentRef: leaf.ref,
      baseUnitRef: baseUnit.ref,
      kindRef: null,
      descriptionText: `${noun}. Производитель ${brand}. Синтетическое описание для теста.`,
      imageFileRef: null,
      isWeighted: false,
      attributes,
    };
    const state: ProductState = { item, variants: [], packagings: [], retail: new Map() };
    // Характеристики (цвет или размер).
    if (!a && rnd() < this.opts.variantShare) {
      const axis = unitIdx === 1 || rootIdx === 2 ? 'size' : 'color';
      const pool = axis === 'size' ? SIZES : COLORS;
      const n = 2 + Math.floor(rnd() * 3);
      const start = Math.floor(rnd() * pool.length);
      for (let v = 0; v < n; v++) {
        this.nextVariantIndex += 1;
        const value = pool[(start + v) % pool.length];
        const prop = PROPS[axis];
        state.variants.push({
          type: 'Catalog_ХарактеристикиНоменклатуры',
          ref: this.ref('variant', this.nextVariantIndex),
          dataVersion: dataVersion(1),
          deletionMark: false,
          code: String(this.nextVariantIndex).padStart(9, '0'),
          description: value,
          ownerRef: item.ref,
          ownerType: 'Catalog_Номенклатура',
          sku: rnd() < 0.5 ? `${sku}-${v + 1}` : null,
          attributes: [
            { propertyRef: prop.ref, name: prop.name, valueType: 'Edm.String', valueRef: null, valueText: value },
          ],
        });
      }
    }
    // Упаковки (коробка N шт; иногда вторая — «упаковка крупная»).
    if (rnd() < this.opts.packagingShare) {
      const factors = [4, 6, 10, 12, 20, 24, 50];
      const f = factors[Math.floor(rnd() * factors.length)];
      const packs = rnd() < 0.3 ? [f, f * 5] : [f];
      for (const factor of packs) {
        this.nextPackagingIndex += 1;
        state.packagings.push({
          type: 'Catalog_УпаковкиЕдиницыИзмерения',
          ref: this.ref('packaging', this.nextPackagingIndex),
          dataVersion: dataVersion(1),
          deletionMark: false,
          description: `Коробка (${factor} ${baseUnit.description})`,
          ownerRef: item.ref,
          ownerType: 'Catalog_Номенклатура',
          unitRef: this.units[PACK_UNIT].ref,
          factor: qty(factor * 1000),
        });
      }
    }
    // Розничная цена: 50…50 000 сом, шаг 50 тыйын; у вариантов — ±15 %.
    const base = BigInt(100 + Math.floor(rnd() * 99_900)) * 50n;
    const sellable: (string | null)[] = state.variants.length === 0 ? [null] : state.variants.map((v) => v.ref);
    for (const vr of sellable) {
      const k = BigInt(85 + Math.floor(rnd() * 31));
      state.retail.set(vr, vr === null ? base : (base * k) / 100n);
    }
    this.products.push(state);
    this.productByRef.set(item.ref, state);
    this.writePrices(state);
    this.writeBarcodes(state);
    this.writeStock(state, rnd);
    this.indexCache = undefined;
    return state;
  }

  private writePrices(p: ProductState): void {
    for (const [vr, retail] of p.retail) {
      this.priceLists.forEach((pl, i) => {
        const factor = PRICE_FACTORS[i] ?? 10_000n;
        const price = (retail * factor + 5_000n) / 10_000n;
        this.priceRows.set(`${pl.ref}|${vr ?? p.item.ref}|`, {
          priceListRef: pl.ref,
          productRef: p.item.ref,
          variantRef: vr,
          packagingRef: null,
          price: money(price),
        });
        // Цена за упаковку — только в оптовых видах цен.
        if (i > 0) {
          for (const pack of p.packagings) {
            const f = BigInt(Math.trunc(parseMilli(pack.factor) / 1000));
            this.priceRows.set(`${pl.ref}|${vr ?? p.item.ref}|${pack.ref}`, {
              priceListRef: pl.ref,
              productRef: p.item.ref,
              variantRef: vr,
              packagingRef: pack.ref,
              price: money(price * f),
            });
          }
        }
      });
    }
  }

  private writeBarcodes(p: ProductState): void {
    const productNo = Number.parseInt(p.item.ref.slice(-12), 16);
    const sellable: (string | null)[] = p.variants.length === 0 ? [null] : p.variants.map((v) => v.ref);
    sellable.forEach((vr, i) => {
      const value = ean13(`21${String(productNo).padStart(8, '0')}${String(i).padStart(2, '0')}`);
      this.barcodeItems.set(value, {
        type: 'InformationRegister_ШтрихкодыНоменклатуры',
        ref: value,
        barcode: value,
        productRef: p.item.ref,
        variantRef: vr,
        packagingRef: null,
        barcodeType: 'EAN13',
      });
    });
    p.packagings.forEach((pack, i) => {
      const value = ean13(`22${String(productNo).padStart(8, '0')}${String(i).padStart(2, '0')}`);
      this.barcodeItems.set(value, {
        type: 'InformationRegister_ШтрихкодыНоменклатуры',
        ref: value,
        barcode: value,
        productRef: p.item.ref,
        variantRef: p.variants[0]?.ref ?? null,
        packagingRef: pack.ref,
        barcodeType: 'EAN13',
      });
    });
  }

  private writeStock(p: ProductState, rnd: () => number): void {
    const fractional = p.item.baseUnitRef !== this.units[0].ref;
    const sellable: (string | null)[] = p.variants.length === 0 ? [null] : p.variants.map((v) => v.ref);
    for (const vr of sellable) {
      for (const w of this.warehouses) {
        if (rnd() >= this.opts.stockShare) continue;
        const onHand = fractional ? Math.floor(rnd() * 500_000) : Math.floor(rnd() * 500) * 1000;
        const reserved = rnd() < 0.2 ? Math.min(onHand, Math.floor(rnd() * 10) * 1000) : 0;
        const withAvailable = rnd() < 0.9;
        this.stockRows.set(`${w.ref}|${p.item.ref}|${vr ?? ''}`, {
          warehouseRef: w.ref,
          productRef: p.item.ref,
          variantRef: vr,
          onHand: qty(onHand),
          reserved: qty(reserved),
          available: withAvailable ? qty(onHand - reserved) : null,
        });
      }
    }
  }

  // ------------------------------------------------------------------ изменения «следующей версии»

  mutate(m: SyntheticMutation): SyntheticMutationResult {
    this.mutationNo += 1;
    const rnd = prng(this.seed * 104_729 + this.mutationNo * 31);
    const changed = new Set<string>();
    const priceLists = new Set<string>();
    const warehouses = new Set<string>();
    const live = (): ProductState[] => this.products.filter((p) => !p.item.deletionMark);
    const pick = (n: number): ProductState[] => {
      const pool = live();
      const out: ProductState[] = [];
      const used = new Set<number>();
      for (let k = 0; k < n && used.size < pool.length; k++) {
        let i = Math.floor(rnd() * pool.length);
        while (used.has(i)) i = (i + 1) % pool.length;
        used.add(i);
        out.push(pool[i]);
      }
      return out;
    };
    for (const p of pick(m.renameProducts ?? 0)) {
      p.item = {
        ...p.item,
        dataVersion: this.nextVersion(),
        description: `${p.item.description} (обн. ${this.mutationNo})`,
      };
      changed.add(itemKey(p.item));
    }
    for (const p of pick(m.touchProducts ?? 0)) {
      p.item = { ...p.item, dataVersion: this.nextVersion() };
      changed.add(itemKey(p.item));
    }
    for (const p of pick(m.deleteProducts ?? 0)) {
      p.item = { ...p.item, dataVersion: this.nextVersion(), deletionMark: true };
      changed.add(itemKey(p.item));
    }
    for (let k = 0; k < (m.addProducts ?? 0); k++) {
      const p = this.addProduct(rnd);
      p.item = { ...p.item, dataVersion: this.nextVersion() };
      changed.add(itemKey(p.item));
      for (const v of p.variants) changed.add(itemKey(v));
      for (const pk of p.packagings) changed.add(itemKey(pk));
      for (const b of this.barcodes().filter((b) => b.productRef === p.item.ref)) changed.add(itemKey(b));
      for (const pl of this.priceLists) priceLists.add(pl.ref);
      for (const w of this.warehouses) warehouses.add(w.ref);
    }
    const priceKeys = [...this.priceRows.keys()];
    for (let k = 0; k < (m.repricePrices ?? 0) && priceKeys.length > 0; k++) {
      const key = priceKeys[Math.floor(rnd() * priceKeys.length)];
      const row = this.priceRows.get(key)!;
      const cur = BigInt(row.price.replace('.', ''));
      this.priceRows.set(key, { ...row, price: money(cur + 100n * BigInt(1 + Math.floor(rnd() * 20))) });
      priceLists.add(row.priceListRef);
    }
    if (priceLists.size > 0) {
      const docNo = this.priceSettings.length + 1;
      const doc: OnecPriceSettingItem = {
        type: 'Document_УстановкаЦенНоменклатуры',
        ref: this.ref('priceDoc', docNo),
        dataVersion: this.nextVersion(),
        deletionMark: false,
        number: `УЦ-${String(docNo).padStart(6, '0')}`,
        date: '2026-10-21T12:00:00+06:00',
        posted: true,
        priceListRefs: [...priceLists].sort(),
      };
      this.priceSettings.push(doc);
      changed.add(itemKey(doc));
    }
    const stockKeys = [...this.stockRows.keys()];
    for (let k = 0; k < (m.restockRows ?? 0) && stockKeys.length > 0; k++) {
      const key = stockKeys[Math.floor(rnd() * stockKeys.length)];
      const row = this.stockRows.get(key)!;
      const onHand = parseMilli(row.onHand) + 1000 * (1 + Math.floor(rnd() * 10));
      const reserved = parseMilli(row.reserved);
      this.stockRows.set(key, {
        ...row,
        onHand: qty(onHand),
        available: row.available === null ? null : qty(onHand - reserved),
      });
      warehouses.add(row.warehouseRef);
    }
    this.indexCache = undefined;
    return {
      changedKeys: [...changed],
      priceListRefs: [...priceLists].sort(),
      stockWarehouseRefs: [...warehouses].sort(),
    };
  }

  /** Добавить внешние элементы (фикстуры 1С) к каталогу: справочники и строки срезов. */
  merge(
    items: readonly OnecCatalogItem[],
    prices: readonly OnecPriceRow[] = [],
    stock: readonly OnecStockRow[] = [],
  ): void {
    for (const it of items) {
      switch (it.type) {
        case 'Catalog_КлассификаторЕдиницИзмерения':
          this.units.push(it);
          break;
        case 'Catalog_Склады':
          this.warehouses.push(it);
          break;
        case 'Catalog_ВидыЦен':
          this.priceLists.push(it);
          break;
        case 'Catalog_Номенклатура':
          if (it.isFolder) this.categories.push(it);
          else {
            const s: ProductState = { item: it, variants: [], packagings: [], retail: new Map() };
            this.products.push(s);
            this.productByRef.set(it.ref, s);
          }
          break;
        case 'Catalog_ХарактеристикиНоменклатуры':
          this.productByRef.get(it.ownerRef)?.variants.push(it);
          break;
        case 'Catalog_УпаковкиЕдиницыИзмерения':
          this.productByRef.get(it.ownerRef)?.packagings.push(it);
          break;
        case 'InformationRegister_ШтрихкодыНоменклатуры':
          this.barcodeItems.set(it.ref, it);
          break;
        default:
          this.extras.push(it);
          break;
      }
    }
    for (const r of prices)
      this.priceRows.set(`${r.priceListRef}|${r.variantRef ?? r.productRef}|${r.packagingRef ?? ''}`, r);
    for (const r of stock) this.stockRows.set(`${r.warehouseRef}|${r.productRef}|${r.variantRef ?? ''}`, r);
    this.indexCache = undefined;
  }
}
