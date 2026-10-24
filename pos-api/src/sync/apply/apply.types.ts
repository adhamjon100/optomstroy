import type pg from 'pg';
import type { SyncEntity, SyncMode, SyncTrigger } from '../../common/enums.js';
import type { SyncErrorCode } from '../../jobs/sync-errors.writer.js';
import type { CatalogChangeSink } from './catalog-change-publisher.js';

/** Таблицы-реплики каталога, которые пишет конвейер (07 §5.B; 07 §6.2 — соответствие прогонам). */
export type CatalogTable =
  | 'units'
  | 'warehouses'
  | 'price_lists'
  | 'categories'
  | 'products'
  | 'product_attributes'
  | 'product_variants'
  | 'variant_attribute_values'
  | 'packagings'
  | 'barcodes'
  | 'prices'
  | 'stock_balances';

/** Прогон (`sync_entity`), который пишет таблицу (07 §6.2; ядро §20.2 п. 7: packagings — в `products`, price_lists — в `prices`). */
export const TABLE_ENTITY: Readonly<Record<CatalogTable, SyncEntity>> = {
  units: 'units',
  warehouses: 'warehouses',
  price_lists: 'prices',
  categories: 'categories',
  products: 'products',
  product_attributes: 'attributes',
  product_variants: 'variants',
  variant_attribute_values: 'attributes',
  packagings: 'products',
  barcodes: 'barcodes',
  prices: 'prices',
  stock_balances: 'stock',
};

/** Счётчики по таблице (`sync_runs.counts`, 05 SYNC-037). */
export interface TableCounts {
  fetched: number;
  inserted: number;
  updated: number;
  /** Без изменений (`source_hash` совпал) — строка не перезаписывалась (05 SYNC-013). */
  skipped: number;
  markedDeleted: number;
  errors: number;
}

export function emptyCounts(): TableCounts {
  return { fetched: 0, inserted: 0, updated: 0, skipped: 0, markedDeleted: 0, errors: 0 };
}

/** Итог по сущности прогона: суммы по таблицам + разбивка. */
export interface EntityCounts extends TableCounts {
  tables: Partial<Record<CatalogTable, TableCounts>>;
  sourceTotal?: number; // money-double: allow — число записей ($count), не деньги
  localTotal?: number; // money-double: allow — число записей, не деньги
}

/** Запись ошибки позиции (`sync_errors`, DATA-152) — без ПДн (05 SYNC-039). */
export interface ItemError {
  readonly entity: SyncEntity;
  readonly errorCode: SyncErrorCode;
  readonly message: string;
  readonly severity: 'warning' | 'error';
  readonly onecRef?: string | null;
  readonly onecCode?: string | null;
  readonly localId?: string | null;
  readonly payload?: Readonly<Record<string, unknown>>;
}

/**
 * Учёт прогонов `sync_runs` для конвейера (05 SYNC-011: прогон на каждую затронутую сущность сообщения).
 * Реализация по умолчанию — `RegistryRunTracker` поверх `SyncRunRegistry` (singleton, `sync_state`).
 */
export interface ApplyRunTracker {
  start(req: {
    entity: SyncEntity;
    mode: SyncMode;
    trigger: SyncTrigger;
    cursorFrom?: string;
    endpoint?: string;
  }): Promise<string>;
  finish(req: {
    runId: string;
    entity: SyncEntity;
    status: 'success' | 'partial' | 'failed';
    counts: Readonly<Record<string, unknown>>;
    errorSummary?: string;
    /** Код ошибки неудачного прогона: при `status='failed'` трекер пишет строку `sync_errors` (RM-E-002 п. 2). */
    errorCode?: SyncErrorCode;
    cursorTo?: string;
  }): Promise<void>;
}

/**
 * Область применения: соединение в транзакции, прогоны по сущностям, время синхронизации. Создаёт вызывающий
 * (`OnecChangesService` — одна транзакция на сообщение; `CatalogFullLoadService` — транзакция на страницу).
 */
export interface ApplyScope {
  readonly client: pg.PoolClient;
  /** `sync_runs.id` для сущности (создаётся лениво при первой строке сущности). */
  runIdFor(entity: SyncEntity): Promise<string>;
  /** `synced_at` строк (момент применения). */
  readonly syncedAt: Date;
  /** Момент данных 1С для срезов остатков/цен (`onec_snapshot_at`). */
  readonly snapshotAt?: Date;
  /** Счётчики по сущностям (накапливаются вызывающим). */
  readonly counts: Map<SyncEntity, EntityCounts>;
  /** Ошибки позиций (накапливаются; пишутся в `sync_errors` в той же транзакции). */
  readonly errors: ItemError[];
  /**
   * Варианты с изменённой ценой/остатком (05 SYNC-070): публикуются задачами `catalog.*-changed` перед COMMIT
   * транзакции применения (`publishCatalogChanges`). Нет — изменения не собираются.
   */
  readonly catalogChanges?: CatalogChangeSink;
}

/**
 * Обработчик типов элементов `/changes`, которые не относятся к каталогу (клиенты — этап G, документы — F,
 * файлы картинок — RM-E-003, события QR — RM-F-016). Вызывается в транзакции сообщения; исключение откатывает
 * сообщение (ack не уходит). Регистрация — `SYNC_APPLY_CHANGE_HANDLERS` / параметр `OnecChangesService`.
 */
export interface ChangeItemHandler {
  /** Типы элементов (`type`), например `Catalog_НоменклатураПрисоединенныеФайлы`; для `ObjectDeletion` — `objectType`. */
  readonly types: readonly string[];
  /** Сущность `sync_entity` прогона, к которому относятся элементы (или `undefined` — без прогона, напр. QR). */
  entityOf(item: Readonly<Record<string, unknown>>): SyncEntity | undefined;
  apply(scope: ApplyScope, items: readonly Readonly<Record<string, unknown>>[]): Promise<void>;
  /**
   * `true` — применение типов осознанно отложено до решения заказчика (ПКО и поступления — Q-012): элементы
   * считаются в `ChangesPullResult.deferred`, после подключения обработки нужна разовая перерегистрация
   * (`npm run onec:reregister`, 05 §6.2 п. 3).
   */
  readonly deferred?: boolean;
}
