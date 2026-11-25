import type {
  OnecBarcodeItem,
  OnecCatalogItem,
  OnecNomenclatureItem,
  OnecPackagingItem,
  OnecPriceListItem,
  OnecPriceRow,
  OnecStockRow,
  OnecUnitItem,
  OnecVariantItem,
  OnecWarehouseItem,
} from '../../integrations/onec/onec-catalog.types.js';
import {
  type OnecOsApiClient,
  type OsApiCharacteristic,
  type OsApiItem,
  type OsApiList,
  type OsApiUnit,
  osApiRef,
} from '../../integrations/onec/onec-osapi.client.js';
import {
  OSAPI_UNREPRESENTABLE,
  OsApiCatalogIndex,
  osApiDate,
  osApiDerivedRef,
  osApiMoney,
  osApiQty,
} from '../../integrations/onec/onec-osapi.mapping.js';
import type { CatalogFullSource, CatalogReadKind, CatalogReadPage } from './catalog-source.js';

/**
 * Источник каталога `ONEC_MODE=os_api` (ADR-126): полные выгрузки HTTP-сервиса 1С «ОС_API» (`/items`,
 * `/characteristics`, `/units`, `/barcodes`, `/warehouses`, `/price-types`, `/prices?priceType=`, `/stock`)
 * переводятся в формат элементов `/changes` (onec-catalog.types.ts) — конвейер применения тот же, что у OData.
 *
 * - Пагинации у ОС_API нет: выгрузка читается целиком, `readPages` отдаёт её порциями `pageSize` из памяти
 *   (`nextSkip` — номер элемента). Продолжение после обрыва (повтор задания) обычно читает выгрузку ЗАНОВО (кэш
 *   уже истёк), а запросы ОС_API без `УПОРЯДОЧИТЬ` (Module.bsl:189-212, 254-262, 285-292) порядка не гарантируют —
 *   поэтому каждый набор сортируется по ссылке (упаковки и варианты — по паре «товар, ссылка»), и номер позиции
 *   в новой выгрузке указывает на то же место, если сами данные не менялись.
 * - Ленты изменений нет: каталог — полной перечиткой по расписанию (как `odata_only`), `versions/fetchByKeys` нет —
 *   инкремент выполняется полной перечиткой. Неизменённые строки не перезаписываются (`source_hash`, SYNC-013).
 * - Удалённые: `deleted=true` → `deletionMark` (применение помечает/скрывает); склады и фото ОС_API отдаёт уже без
 *   помеченных — исчезнувшие помечает сверка полной загрузки (SYNC-006, `count` ниже).
 * - Базовые единицы (`Справочник.КлассификаторЕдиницИзмерения`) отдельным списком ОС_API не отдаёт — они собираются
 *   из `baseUnitId`/`baseUnitName` товаров `/items`.
 * - Характеристики и упаковки КАТЕГОРИИ (`ownerType = category`) разворачиваются по товарам категории с производной
 *   ссылкой (`osApiDerivedRef`); владельцы `unitSet`/`other` не представимы в модели и пропускаются. Цены и
 *   штрихкоды на таких единицах (и на упаковке, которой нет в `/units`) тоже пропускаются намеренно: упаковки в
 *   реплике нет; число пропущенных — одно предупреждение в журнал за прогон, не ошибка применения.
 * - Виды цен — `ONEC_OSAPI_PRICE_TYPES` (пусто — все не удалённые), склады остатков — `ONEC_OSAPI_WAREHOUSES`
 *   (пусто — все, одним запросом `/stock`).
 *
 * Выгрузки кэшируются на `cacheTtlMs` (по умолчанию 60 с): сущности одного прогона по расписанию (`categories`,
 * `products`, `variants`… читают одни и те же `/items`) не дёргают 1С повторно. Одновременные запросы одной
 * выгрузки объединяются.
 */
export interface OsApiCatalogSourceOptions {
  /** `ONEC_OSAPI_PRICE_TYPES`: UUID видов цен; пусто — все не удалённые. */
  readonly priceTypes?: readonly string[];
  /** `ONEC_OSAPI_WAREHOUSES`: UUID складов остатков; пусто — все. */
  readonly warehouses?: readonly string[];
  /** Порция `readPages`/срезов (`ONEC_SYNC_PAGE_SIZE`). */
  readonly pageSize?: number;
  readonly cacheTtlMs?: number;
  readonly now?: () => Date;
  /** Журнал предупреждений (пропущенные строки на непредставимых единицах); нет — молча. */
  readonly log?: { warn(obj: object, msg: string): void };
}

export const OSAPI_CACHE_TTL_MS = 60_000;

type Endpoint = 'items' | 'characteristics' | 'units' | 'barcodes' | 'warehouses' | 'priceTypes';

export class OsApiCatalogSource implements CatalogFullSource {
  readonly name = 'osapi';
  private readonly priceTypes: ReadonlySet<string>;
  private readonly warehouseRefs: readonly string[];
  private readonly pageSize: number;
  private readonly ttl: number;
  private readonly now: () => Date;
  private readonly log: OsApiCatalogSourceOptions['log'];
  private readonly cache = new Map<Endpoint, { at: number; value: Promise<OsApiList<unknown>> }>();
  /** Последний листинг набора (для `count` той же выгрузки, что была применена). */
  private readonly lastListing = new Map<CatalogReadKind, readonly OnecCatalogItem[]>();
  private snapshot: Date | undefined;

  constructor(
    readonly client: OnecOsApiClient,
    opts: OsApiCatalogSourceOptions = {},
  ) {
    this.priceTypes = new Set((opts.priceTypes ?? []).map((r) => osApiRef(r)).filter((r): r is string => !!r));
    this.warehouseRefs = (opts.warehouses ?? []).map((r) => osApiRef(r)).filter((r): r is string => !!r);
    this.pageSize = Math.max(1, opts.pageSize ?? 1000);
    this.ttl = opts.cacheTtlMs ?? OSAPI_CACHE_TTL_MS;
    this.now = opts.now ?? (() => new Date());
    this.log = opts.log;
  }

  snapshotAt(): Date | undefined {
    return this.snapshot;
  }

  async *read(kind: CatalogReadKind): AsyncIterable<readonly OnecCatalogItem[]> {
    for await (const page of this.readPages(kind, 0)) yield page.items;
  }

  async *readPages(kind: CatalogReadKind, startSkip: number): AsyncIterable<CatalogReadPage> {
    const all = await this.listing(kind);
    this.lastListing.set(kind, all);
    for (let i = Math.max(0, startSkip); i < all.length; i += this.pageSize) {
      const items = all.slice(i, i + this.pageSize);
      yield { items, nextSkip: i + items.length };
    }
  }

  /** Число живых объектов набора — по той же выгрузке, что применена последней (SYNC-003/SYNC-006). */
  async count(kind: CatalogReadKind): Promise<number> {
    const all = this.lastListing.get(kind) ?? (await this.listing(kind));
    if (kind === 'barcodes') return new Set(all.map((i) => i.ref)).size;
    return all.filter((i) => !('deletionMark' in i && i.deletionMark)).length;
  }

  /** Срез цен: `GET /prices?priceType=` по каждому виду (∩ `ONEC_OSAPI_PRICE_TYPES`, если задан). */
  async *priceSlice(priceListRefs: readonly string[]): AsyncIterable<readonly OnecPriceRow[]> {
    this.snapshot = this.now();
    const index = await this.index();
    const refs = priceListRefs
      .map((r) => osApiRef(r))
      .filter((r): r is string => !!r && (this.priceTypes.size === 0 || this.priceTypes.has(r)));
    let skipped = 0;
    for (const pl of refs) {
      const body = await this.client.prices(pl);
      const listRef = osApiRef(body.priceTypeId) ?? pl;
      const rows: OnecPriceRow[] = [];
      for (const p of body.items) {
        const productRef = osApiRef(p.itemId);
        if (!productRef) continue;
        const pack = p.unitKind === 'package' ? index.packagingRef(p.itemId, p.unitId, p.unitKind) : null;
        if (pack === OSAPI_UNREPRESENTABLE) {
          skipped++;
          continue;
        }
        rows.push({
          priceListRef: listRef,
          productRef,
          variantRef: index.variantRef(p.itemId, p.characteristicId),
          packagingRef: pack,
          price: osApiMoney(p.price),
          period: osApiDate(p.since),
        });
      }
      yield* chunk(rows, this.pageSize);
    }
    this.warnSkipped('prices', skipped);
  }

  /** Срез остатков: `GET /stock` (все склады) или `?warehouse=` по каждому складу; `available` = `free` 1С. */
  async *stockSlice(warehouseRefs?: readonly string[]): AsyncIterable<readonly OnecStockRow[]> {
    this.snapshot = this.now();
    const index = await this.index();
    const asked = (warehouseRefs ?? []).map((r) => osApiRef(r)).filter((r): r is string => !!r);
    const configured = new Set(this.warehouseRefs);
    const targets: (string | undefined)[] =
      asked.length > 0
        ? asked.filter((r) => configured.size === 0 || configured.has(r))
        : this.warehouseRefs.length > 0
          ? [...this.warehouseRefs]
          : [undefined];
    for (const wh of targets) {
      const body = await this.client.stock(wh);
      const rows: OnecStockRow[] = [];
      for (const s of body.items) {
        const productRef = osApiRef(s.itemId);
        const warehouseRef = osApiRef(s.warehouseId);
        if (!productRef || !warehouseRef) continue;
        if (wh && warehouseRef !== wh) continue;
        rows.push({
          warehouseRef,
          productRef,
          variantRef: index.variantRef(s.itemId, s.characteristicId),
          onHand: osApiQty(s.quantity),
          reserved: s.reserved === undefined || s.reserved === null ? '0.000' : osApiQty(s.reserved),
          available: s.free === undefined || s.free === null ? null : osApiQty(s.free),
        });
      }
      yield* chunk(rows, this.pageSize);
    }
  }

  // ------------------------------------------------------------------ наборы

  /** Набор в детерминированном порядке (см. выше: продолжение после обрыва по номеру позиции). */
  private async listing(kind: CatalogReadKind): Promise<OnecCatalogItem[]> {
    const list = await this.unsortedListing(kind);
    const owner = (i: OnecCatalogItem): string => ('ownerRef' in i && typeof i.ownerRef === 'string' ? i.ownerRef : '');
    return list.sort((a, b) => cmp(owner(a), owner(b)) || cmp(a.ref, b.ref));
  }

  private async unsortedListing(kind: CatalogReadKind): Promise<OnecCatalogItem[]> {
    switch (kind) {
      case 'units':
        return units(await this.items());
      case 'warehouses':
        return (await this.get('warehouses', () => this.client.warehouses())).items.flatMap(warehouse);
      case 'price_lists':
        return (await this.get('priceTypes', () => this.client.priceTypes())).items
          .flatMap(priceList)
          .filter((p) => this.priceTypes.size === 0 || this.priceTypes.has(p.ref));
      case 'categories':
        return (await this.items()).filter((i) => i.isGroup).flatMap((i) => nomenclature(i));
      case 'products':
        return (await this.items()).filter((i) => !i.isGroup).flatMap((i) => nomenclature(i));
      case 'packagings':
        return packagings(await this.items(), await this.units());
      case 'variants':
        return variants(await this.items(), await this.characteristics());
      case 'barcodes': {
        const index = await this.index();
        const list = await this.get('barcodes', () => this.client.barcodes());
        let skipped = 0;
        const out = list.items.flatMap((b): OnecBarcodeItem[] => {
          const value = typeof b.barcode === 'string' ? b.barcode.trim() : '';
          const productRef = osApiRef(b.itemId);
          if (!value || !productRef) return [];
          const packagingRef = index.packagingRef(b.itemId, b.unitId);
          if (packagingRef === OSAPI_UNREPRESENTABLE) {
            skipped++;
            return [];
          }
          return [
            {
              type: 'InformationRegister_ШтрихкодыНоменклатуры',
              ref: value,
              barcode: value,
              productRef,
              variantRef: index.variantRef(b.itemId, b.characteristicId),
              packagingRef,
              barcodeType: null,
            },
          ];
        });
        this.warnSkipped('barcodes', skipped);
        return out;
      }
    }
  }

  /** Одно предупреждение за прогон: строки на единицах, которых в модели нет (не ошибка, данные 1С такие). */
  private warnSkipped(entity: 'prices' | 'barcodes', skipped: number): void {
    if (skipped === 0) return;
    this.log?.warn(
      { entity, skipped },
      'osapi.unrepresentable_unit: строки на единицах вне модели (упаковка набора единиц/иного владельца или нет в /units) пропущены',
    );
  }

  private async items(): Promise<readonly OsApiItem[]> {
    return (await this.get('items', () => this.client.items())).items;
  }
  private async characteristics(): Promise<readonly OsApiCharacteristic[]> {
    return (await this.get('characteristics', () => this.client.characteristics())).items;
  }
  private async units(): Promise<readonly OsApiUnit[]> {
    return (await this.get('units', () => this.client.units())).items;
  }

  private async index(): Promise<OsApiCatalogIndex> {
    return new OsApiCatalogIndex(await this.items(), await this.characteristics(), await this.units());
  }

  /** Выгрузка из кэша (TTL) или новый запрос; ошибка запроса из кэша убирается сразу. */
  private get<T>(key: Endpoint, load: () => Promise<OsApiList<T>>): Promise<OsApiList<T>> {
    const at = this.now().getTime();
    const hit = this.cache.get(key);
    if (hit && at - hit.at < this.ttl) return hit.value as Promise<OsApiList<T>>;
    const value = load();
    this.cache.set(key, { at, value });
    value.catch(() => {
      if (this.cache.get(key)?.value === value) this.cache.delete(key);
    });
    return value;
  }
}

function cmp(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

function* chunk<T>(rows: readonly T[], size: number): Generator<readonly T[]> {
  for (let i = 0; i < rows.length; i += size) yield rows.slice(i, i + size);
}

function text(v: unknown): string | null {
  if (typeof v !== 'string') return null;
  const s = v.trim();
  return s === '' ? null : s;
}

function warehouse(w: { id: string | null; name: string }): OnecWarehouseItem[] {
  const ref = osApiRef(w.id);
  if (!ref) return [];
  // ОС_API отдаёт склады без помеченных на удаление (Module.bsl:163-164); групп у структурных единиц нет.
  return [
    {
      type: 'Catalog_Склады',
      ref,
      dataVersion: '',
      deletionMark: false,
      isFolder: false,
      code: null,
      description: w.name,
    },
  ];
}

function priceList(p: { id: string | null; name: string; deleted: boolean }): OnecPriceListItem[] {
  const ref = osApiRef(p.id);
  if (!ref) return [];
  // Валюты и признаков продажи/НДС ОС_API не отдаёт: вид цены считается KGS, как у OData (05 §5.3).
  return [
    {
      type: 'Catalog_ВидыЦен',
      ref,
      dataVersion: '',
      deletionMark: p.deleted === true,
      code: null,
      description: p.name,
      currency: null,
      usedForSales: null,
      priceIncludesVat: null,
    },
  ];
}

function nomenclature(i: OsApiItem): OnecNomenclatureItem[] {
  const ref = osApiRef(i.id);
  if (!ref) return [];
  return [
    {
      type: 'Catalog_Номенклатура',
      ref,
      dataVersion: i.isGroup ? '' : (osApiDate(i.changedAt) ?? ''),
      deletionMark: i.deleted === true,
      isFolder: i.isGroup === true,
      code: text(i.code),
      description: i.name,
      fullName: i.isGroup ? null : text(i.fullName),
      sku: i.isGroup ? null : text(i.sku),
      parentRef: osApiRef(i.parentId),
      baseUnitRef: i.isGroup ? null : osApiRef(i.baseUnitId),
      kindRef: null,
      descriptionText: null,
      imageFileRef: null,
      // Бренда ОС_API не отдаёт — текущий `products.brand` сохраняется (как у OData).
      brandUnknown: true,
      isWeighted: i.isGroup ? null : typeof i.weighted === 'boolean' ? i.weighted : null,
      attributes: [],
    },
  ];
}

/** Базовые единицы — из товаров (`baseUnitId`, `baseUnitName`), без повторов. */
function units(items: readonly OsApiItem[]): OnecUnitItem[] {
  const out = new Map<string, OnecUnitItem>();
  for (const i of items) {
    if (i.isGroup) continue;
    const ref = osApiRef(i.baseUnitId);
    if (!ref || out.has(ref)) continue;
    out.set(ref, {
      type: 'Catalog_КлассификаторЕдиницИзмерения',
      ref,
      dataVersion: '',
      deletionMark: false,
      code: null,
      description: text(i.baseUnitName) ?? '',
    });
  }
  return [...out.values()];
}

/** Упаковки: владелец-товар — как есть (единица = базовая единица товара); владелец-категория — по товарам. */
function packagings(items: readonly OsApiItem[], list: readonly OsApiUnit[]): OnecPackagingItem[] {
  const index = new OsApiCatalogIndex(items);
  const out: OnecPackagingItem[] = [];
  const make = (u: OsApiUnit, ref: string, itemRef: string): OnecPackagingItem => ({
    type: 'Catalog_УпаковкиЕдиницыИзмерения',
    ref,
    dataVersion: '',
    deletionMark: u.deleted === true,
    description: u.name,
    ownerRef: itemRef,
    ownerType: 'Catalog_Номенклатура',
    unitRef: osApiRef(index.items.get(itemRef)?.baseUnitId),
    factor: osApiQty(u.ratio),
  });
  for (const u of list) {
    const id = osApiRef(u.id);
    const owner = osApiRef(u.ownerId);
    if (!id || !owner) continue;
    if (u.ownerType === 'item') out.push(make(u, id, owner));
    else if (u.ownerType === 'category') {
      for (const itemRef of index.byCategory.get(owner) ?? []) {
        out.push(make(u, osApiDerivedRef('unit', id, itemRef), itemRef));
      }
    }
  }
  return out;
}

/** Характеристики: владелец-товар — как есть; владелец-категория — по товарам категории с `hasCharacteristics`. */
function variants(items: readonly OsApiItem[], list: readonly OsApiCharacteristic[]): OnecVariantItem[] {
  const index = new OsApiCatalogIndex(items);
  const out: OnecVariantItem[] = [];
  const make = (c: OsApiCharacteristic, ref: string, itemRef: string): OnecVariantItem => ({
    type: 'Catalog_ХарактеристикиНоменклатуры',
    ref,
    dataVersion: '',
    deletionMark: c.deleted === true,
    code: null,
    description: c.name,
    ownerRef: itemRef,
    ownerType: 'Catalog_Номенклатура',
    sku: text(c.sku),
    attributes: [],
  });
  for (const c of list) {
    const id = osApiRef(c.id);
    const owner = osApiRef(c.ownerId);
    if (!id || !owner) continue;
    if (c.ownerType === 'item') out.push(make(c, id, owner));
    else if (c.ownerType === 'category') {
      for (const itemRef of index.byCategory.get(owner) ?? []) {
        if (index.items.get(itemRef)?.hasCharacteristics !== true) continue;
        out.push(make(c, osApiDerivedRef('characteristic', id, itemRef), itemRef));
      }
    }
  }
  return out;
}
