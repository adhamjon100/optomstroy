import type { FakeOnecGateway } from '../../integrations/onec/fake-onec.gateway.js';
import type { OnecCatalogItem, OnecPriceRow, OnecStockRow } from '../../integrations/onec/onec-catalog.types.js';
import type { SyntheticCatalog } from '../../integrations/onec/synthetic-catalog.js';

/**
 * Что читает полная загрузка (07 §6.2: прогон → таблицы). `products` = номенклатура без групп, `packagings` —
 * упаковки (в составе прогона `products`), `price_lists` — виды цен (первый шаг прогона `prices`).
 */
export type CatalogReadKind =
  'units' | 'warehouses' | 'price_lists' | 'categories' | 'products' | 'packagings' | 'variants' | 'barcodes';

/** Ключ объекта и его DataVersion (фаза 0, SYNC-012: лёгкий запрос `$select=Ref_Key,DataVersion,DeletionMark`). */
export interface OnecVersionKey {
  readonly key: string;
  readonly dataVersion: string | null;
  readonly deletionMark: boolean;
}

/** Срезы цен и остатков (05 SYNC-014, SYNC-015): в фазе 1 их нет в `/changes`. */
export interface CatalogSliceSource {
  /** Полный срез цен указанных видов цен (ссылки 1С), страницами. */
  priceSlice(priceListRefs: readonly string[]): AsyncIterable<readonly OnecPriceRow[]>;
  /** Полный срез остатков складов (все склады, если не указано), страницами. */
  stockSlice(warehouseRefs?: readonly string[]): AsyncIterable<readonly OnecStockRow[]>;
  /** Момент данных среза (для `onec_snapshot_at`), если источник его знает. */
  snapshotAt?(): Date | undefined;
}

/** Источник полной загрузки / сверки / инкремента фазы 0 (OData) — элементы в формате `/changes`. */
export interface CatalogFullSource extends CatalogSliceSource {
  readonly name: string;
  read(kind: CatalogReadKind): AsyncIterable<readonly OnecCatalogItem[]>;
  /** Число объектов в 1С (`$count`, SYNC-003) — `undefined`, если источник не умеет. */
  count?(kind: CatalogReadKind): Promise<number | undefined>;
  /** Ключи и DataVersion всех объектов (фаза 0). */
  versions?(kind: CatalogReadKind): AsyncIterable<readonly OnecVersionKey[]>;
  /** Объекты по ключам (дочитывание изменённых, фаза 0). */
  fetchByKeys?(kind: CatalogReadKind, keys: readonly string[]): Promise<readonly OnecCatalogItem[]>;
}

function* chunks<T>(list: readonly T[], size: number): Generator<readonly T[]> {
  for (let i = 0; i < list.length; i += size) yield list.slice(i, i + size);
}

async function* asyncChunks<T>(list: readonly T[], size: number): AsyncGenerator<readonly T[]> {
  for (const c of chunks(list, size)) yield await Promise.resolve(c);
}

/**
 * Источник на синтетическом каталоге / `FakeOnecGateway` (режим `fixtures`, RM-E-011 «на фикстурах»): элементы
 * в текущем состоянии каталога, страницами `pageSize`; ключи-версии — для проверки фазы 0.
 */
export class SyntheticCatalogSource implements CatalogFullSource {
  readonly name = 'synthetic';
  private readonly catalog: SyntheticCatalog;

  constructor(
    from: SyntheticCatalog | FakeOnecGateway,
    private readonly pageSize = 1000,
  ) {
    const c = 'exchange' in from ? from.catalog : from;
    if (!c) throw new Error('SyntheticCatalogSource: у FakeOnecGateway не включён режим каталога');
    this.catalog = c;
  }

  private items(kind: CatalogReadKind): OnecCatalogItem[] {
    const c = this.catalog;
    switch (kind) {
      case 'units':
        return c.units;
      case 'warehouses':
        return c.warehouses;
      case 'price_lists':
        return c.priceLists;
      case 'categories':
        return c.categories;
      case 'products':
        return c.productItems();
      case 'packagings':
        return c.packagings();
      case 'variants':
        return c.variants();
      case 'barcodes':
        return c.barcodes();
    }
  }

  read(kind: CatalogReadKind): AsyncIterable<readonly OnecCatalogItem[]> {
    return asyncChunks(this.items(kind), this.pageSize);
  }

  count(kind: CatalogReadKind): Promise<number> {
    return Promise.resolve(this.items(kind).filter((i) => !('deletionMark' in i && i.deletionMark)).length);
  }

  versions(kind: CatalogReadKind): AsyncIterable<readonly OnecVersionKey[]> {
    return asyncChunks(
      this.items(kind).map((i) => ({
        key: i.ref,
        dataVersion: 'dataVersion' in i ? i.dataVersion : null,
        deletionMark: 'deletionMark' in i ? i.deletionMark : false,
      })),
      this.pageSize,
    );
  }

  fetchByKeys(kind: CatalogReadKind, keys: readonly string[]): Promise<readonly OnecCatalogItem[]> {
    const want = new Set(keys);
    return Promise.resolve(this.items(kind).filter((i) => want.has(i.ref)));
  }

  priceSlice(priceListRefs: readonly string[]): AsyncIterable<readonly OnecPriceRow[]> {
    return asyncChunks(this.catalog.priceSlice(priceListRefs), this.pageSize);
  }

  stockSlice(warehouseRefs?: readonly string[]): AsyncIterable<readonly OnecStockRow[]> {
    return asyncChunks(this.catalog.stockSlice(warehouseRefs), this.pageSize);
  }
}
