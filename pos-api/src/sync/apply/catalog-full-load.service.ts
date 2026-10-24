import type pg from 'pg';
import type { Logger } from 'pino';
import type { SyncEntity, SyncTrigger } from '../../common/enums.js';
import type { OnecCatalogItem } from '../../integrations/onec/onec-catalog.types.js';
import type { ApplyRunTracker, ApplyScope, CatalogTable, EntityCounts } from './apply.types.js';
import { type ApplyState, type CatalogApplier, newApplyState } from './catalog-applier.js';
import {
  type CatalogChangePublisher,
  newCatalogChangeSink,
  publishCatalogChanges,
} from './catalog-change-publisher.js';
import { refreshCatalogDerived } from './catalog-derived.js';
import type { CatalogFullSource, CatalogReadKind } from './catalog-source.js';
import {
  applyPriceRows,
  applyStockRows,
  finishPriceSlice,
  finishStockSlice,
  newSliceTracker,
  type SliceTracker,
} from './catalog-slices.js';
import { bump, flushErrors } from './replica-writer.js';

/** Сущности каталога, которые умеет загружать сервис (07 §6.2). */
export const CATALOG_LOAD_ENTITIES = [
  'units',
  'categories',
  'products',
  'variants',
  'attributes',
  'barcodes',
  'warehouses',
  'prices',
  'stock',
] as const satisfies readonly SyncEntity[];
export type CatalogLoadEntity = (typeof CATALOG_LOAD_ENTITIES)[number];

/** Порядок полной загрузки каталога (05 SYNC-001; packagings — в `products`, price_lists — в `prices`). */
export const CATALOG_LOAD_ORDER: readonly CatalogLoadEntity[] = [
  'units',
  'categories',
  'products',
  'variants',
  'attributes',
  'barcodes',
  'warehouses',
  'prices',
  'stock',
];

/** Что читает прогон сущности и какие таблицы-реплики сверяются/помечаются (07 §6.2). */
const ENTITY_READS: Readonly<Record<CatalogLoadEntity, readonly { kind: CatalogReadKind; table: CatalogTable }[]>> = {
  units: [{ kind: 'units', table: 'units' }],
  categories: [{ kind: 'categories', table: 'categories' }],
  products: [
    { kind: 'products', table: 'products' },
    { kind: 'packagings', table: 'packagings' },
  ],
  variants: [{ kind: 'variants', table: 'product_variants' }],
  // Свойства приходят в составе товаров и характеристик (ТЧ ДополнительныеРеквизиты) — отдельного чтения нет.
  attributes: [],
  barcodes: [{ kind: 'barcodes', table: 'barcodes' }],
  warehouses: [{ kind: 'warehouses', table: 'warehouses' }],
  prices: [{ kind: 'price_lists', table: 'price_lists' }],
  stock: [],
};

export type CatalogLoadMode = 'full' | 'reconcile' | 'incremental';

export interface CatalogLoadRequest {
  readonly entity: CatalogLoadEntity;
  /**
   * `full` — полная перечитка + пометка не встреченных (SYNC-006) при успешной сверке количества;
   * `reconcile` — то же, неизменённое не перезаписывается (SYNC-009); `incremental` — фаза 0: ключи и DataVersion,
   * дочитывание изменённых, отсутствующие в 1С → `deletion_mark` (SYNC-012). Для `prices`/`stock` — полный срез.
   */
  readonly mode: CatalogLoadMode;
  readonly source: CatalogFullSource;
  readonly trigger?: SyncTrigger;
  /** Прогон уже создан вызывающим (обработчик `SyncJobProcessor`) — сервис его не завершает. */
  readonly runId?: string;
  /** Для `prices`: только эти виды цен (ссылки 1С); иначе — все не помеченные. */
  readonly priceListRefs?: readonly string[];
  /** Для `stock`: только эти склады (ссылки 1С). */
  readonly warehouseRefs?: readonly string[];
}

export interface CatalogLoadResult {
  readonly entity: CatalogLoadEntity;
  readonly runId: string;
  readonly status: 'success' | 'partial';
  readonly counts: EntityCounts | undefined;
  /** Счётчики других сущностей, затронутых прогоном (свойства при загрузке товаров и т. п.). */
  readonly sideCounts: Readonly<Partial<Record<SyncEntity, EntityCounts>>>;
  readonly pages: number;
}

/**
 * Полная загрузка / сверка / инкремент фазы 0 одной сущности каталога (05 §7.1–§7.2; RM-E-001):
 * каждая страница — отдельная транзакция upsert по `onec_ref` (SYNC-002), неизменённое пропускается (SYNC-013),
 * не встреченные в полной загрузке объекты помечаются `deletion_mark` только при совпадении количества (SYNC-003,
 * SYNC-006; при `partial` — нет). Срезы цен/остатков: страница — транзакция, удаление исчезнувших цен и обнуление
 * исчезнувших остатков — после всех страниц, если срез прочитан полностью.
 */
export class CatalogFullLoadService {
  constructor(
    private readonly pool: pg.Pool,
    private readonly applier: CatalogApplier,
    private readonly runs: ApplyRunTracker,
    private readonly log: Logger,
    private readonly now: () => Date = () => new Date(),
    /** Публикатор `catalog.prices-changed|stock-changed` (05 SYNC-070); нет — корзины не уведомляются. */
    private readonly catalogChanges?: CatalogChangePublisher,
  ) {}

  /** Полная загрузка всего каталога в порядке зависимостей (05 SYNC-001). */
  async loadAll(
    source: CatalogFullSource,
    mode: Exclude<CatalogLoadMode, 'incremental'> = 'full',
    trigger: SyncTrigger = 'manual',
  ): Promise<CatalogLoadResult[]> {
    const out: CatalogLoadResult[] = [];
    for (const entity of CATALOG_LOAD_ORDER) out.push(await this.run({ entity, mode, source, trigger }));
    return out;
  }

  async run(req: CatalogLoadRequest): Promise<CatalogLoadResult> {
    const trigger = req.trigger ?? 'manual';
    const ownRun = req.runId === undefined;
    const sideRuns = new Map<SyncEntity, string>();
    const mainRun =
      req.runId ?? (await this.runs.start({ entity: req.entity, mode: req.mode, trigger, endpoint: req.source.name }));
    const counts = new Map<SyncEntity, EntityCounts>();
    const runIdFor = async (entity: SyncEntity): Promise<string> => {
      if (entity === req.entity) return mainRun;
      let id = sideRuns.get(entity);
      if (!id) {
        id = await this.runs.start({
          entity,
          mode: req.mode === 'incremental' ? 'incremental' : 'full',
          trigger: 'dependency',
          endpoint: req.source.name,
        });
        sideRuns.set(entity, id);
      }
      return id;
    };
    let pages: number;
    let status: 'success' | 'partial' = 'success';
    try {
      if (req.entity === 'prices') pages = await this.loadPrices(req, runIdFor, counts);
      else if (req.entity === 'stock') pages = await this.loadStock(req, runIdFor, counts);
      else if (req.mode === 'incremental') pages = await this.loadIncremental(req, runIdFor, counts);
      else pages = await this.loadFull(req, runIdFor, counts);
      const c = counts.get(req.entity);
      if (c && c.errors > 0) status = 'partial';
      if (c?.sourceTotal !== undefined && c.localTotal !== undefined && c.sourceTotal !== c.localTotal)
        status = 'partial';
    } catch (e) {
      if (ownRun) {
        await this.runs
          .finish({
            runId: mainRun,
            entity: req.entity,
            status: 'failed',
            counts: { ...(counts.get(req.entity) ?? {}) },
            errorSummary: errText(e),
          })
          .catch(() => undefined);
      }
      for (const [entity, id] of sideRuns) {
        await this.runs
          .finish({
            runId: id,
            entity,
            status: 'failed',
            counts: { ...(counts.get(entity) ?? {}) },
            errorSummary: errText(e),
          })
          .catch(() => undefined);
      }
      throw e;
    }
    if (ownRun) {
      await this.runs.finish({
        runId: mainRun,
        entity: req.entity,
        status,
        counts: { ...(counts.get(req.entity) ?? {}) },
        cursorTo: `pages:${pages}`,
      });
    }
    for (const [entity, id] of sideRuns) {
      const c = counts.get(entity);
      await this.runs.finish({
        runId: id,
        entity,
        status: c && c.errors > 0 ? 'partial' : 'success',
        counts: { ...(c ?? {}) },
      });
    }
    const side: Partial<Record<SyncEntity, EntityCounts>> = {};
    for (const [e, c] of counts) if (e !== req.entity) side[e] = c;
    this.log.info(
      { entity: req.entity, mode: req.mode, status, pages, counts: counts.get(req.entity) },
      'sync.catalog.loaded',
    );
    return { entity: req.entity, runId: mainRun, status, counts: counts.get(req.entity), sideCounts: side, pages };
  }

  // ------------------------------------------------------------------ справочники

  private async loadFull(
    req: CatalogLoadRequest,
    runIdFor: (e: SyncEntity) => Promise<string>,
    counts: Map<SyncEntity, EntityCounts>,
  ): Promise<number> {
    let pages = 0;
    for (const { kind, table } of ENTITY_READS[req.entity]) {
      const state = newApplyState();
      for await (const items of req.source.read(kind)) {
        pages += 1;
        await this.inTx(runIdFor, counts, async (scope) => {
          await this.applier.applyItems(scope, state, items, true);
          await refreshCatalogDerived(scope.client, state, { counters: false });
        });
      }
      await this.reconcileTable(req, kind, table, runIdFor, counts, state);
      if (state.dirty.counters)
        await this.inTx(runIdFor, counts, (scope) => refreshCatalogDerived(scope.client, state));
    }
    return pages;
  }

  /** Фаза 0 (SYNC-012): ключи + DataVersion → дочитать изменённые; ключей нет в 1С → `deletion_mark`. */
  private async loadIncremental(
    req: CatalogLoadRequest,
    runIdFor: (e: SyncEntity) => Promise<string>,
    counts: Map<SyncEntity, EntityCounts>,
  ): Promise<number> {
    const src = req.source;
    if (!src.versions || !src.fetchByKeys) return this.loadFull(req, runIdFor, counts);
    let pages = 0;
    for (const { kind, table } of ENTITY_READS[req.entity]) {
      const known = await this.knownVersions(req.entity, table);
      const changed = new Set<string>();
      const present = new Set<string>();
      const live = new Set<string>();
      for await (const page of src.versions(kind)) {
        pages += 1;
        for (const v of page) {
          present.add(v.key);
          if (!v.deletionMark) live.add(v.key);
          if (known.get(v.key) !== (v.dataVersion ?? '')) changed.add(v.key);
        }
      }
      const state = newApplyState();
      const changedKeys = [...changed];
      for (let i = 0; i < changedKeys.length; i += 1000) {
        const items: readonly OnecCatalogItem[] = await src.fetchByKeys(kind, changedKeys.slice(i, i + 1000));
        await this.inTx(runIdFor, counts, async (scope) => {
          await this.applier.applyItems(scope, state, items, true);
          await refreshCatalogDerived(scope.client, state);
        });
      }
      const missing = [...known.keys()].filter((k) => !present.has(k));
      if (missing.length > 0 && !(await this.listingComplete(req, kind, table, live.size, runIdFor, counts))) continue;
      if (missing.length > 0) {
        await this.inTx(runIdFor, counts, async (scope) => {
          // Версия ключа сбрасывается: если ключ снова появится в листинге (временный пропуск из-за сдвига
          // `$skip`), DataVersion «изменится» — объект будет дочитан и пометка снята (ревью E-onec-sync-3).
          await scope.client.query(
            `UPDATE sync_entity_versions SET data_version = NULL WHERE entity = $1 AND onec_key = ANY($2::text[])`,
            [req.entity, missing],
          );
          const r = await scope.client.query<{ id: string }>(
            `UPDATE ${table} SET deletion_mark = true, source_hash = 'deleted:' || source_hash, synced_at = $2
              WHERE onec_ref = ANY($1::uuid[]) AND NOT deletion_mark RETURNING id`,
            [missing, scope.syncedAt.toISOString()],
          );
          bump(scope, table, 'markedDeleted', r.rowCount ?? 0);
          if (table === 'products' || table === 'categories') {
            const st = newApplyState();
            if (table === 'categories') st.dirty.categories = true;
            for (const x of r.rows) st.dirty.products.add(x.id);
            if (table === 'products') {
              await scope.client.query(
                `UPDATE product_variants SET deletion_mark = true WHERE is_default AND product_id = ANY($1::uuid[]) AND NOT deletion_mark`,
                [r.rows.map((x) => x.id)],
              );
            }
            await refreshCatalogDerived(scope.client, st);
          }
        });
      }
    }
    return pages;
  }

  /**
   * Листинг версий полон? (05 SYNC-003/SYNC-006: пометка не встреченных — только при совпадении количества.)
   * Число живых ключей листинга сверяется с `$count` 1С; расхождение → `COUNT_MISMATCH`, прогон `partial`, пометки
   * удалённых нет (листинг `$top/$skip` без `$orderby` может пропустить ключ при изменениях в 1С во время чтения).
   * Источник без `$count` — проверка невозможна, пометка выполняется (восстановление — через сброс версии).
   */
  private async listingComplete(
    req: CatalogLoadRequest,
    kind: CatalogReadKind,
    table: CatalogTable,
    listed: number,
    runIdFor: (e: SyncEntity) => Promise<string>,
    counts: Map<SyncEntity, EntityCounts>,
  ): Promise<boolean> {
    const sourceTotal = req.source.count ? await req.source.count(kind) : undefined;
    if (sourceTotal === undefined || sourceTotal === listed) return true;
    await this.inTx(runIdFor, counts, (scope) => {
      scope.errors.push({
        entity: req.entity,
        errorCode: 'COUNT_MISMATCH',
        severity: 'error',
        message: `${table}: в 1С ${sourceTotal}, в листинге версий ${listed} — пометка удалённых не выполнена (SYNC-006)`,
        payload: { table, sourceTotal, localTotal: listed },
      });
      bump(scope, table, 'errors');
      return Promise.resolve();
    });
    return false;
  }

  /** DataVersion, известные реплике (`sync_entity_versions` сущности, строки таблицы с `onec_ref`). */
  private async knownVersions(entity: SyncEntity, table: CatalogTable): Promise<Map<string, string>> {
    const r = await this.pool.query<{ k: string; dv: string | null }>(
      `SELECT t.onec_ref::text AS k, v.data_version AS dv FROM ${table} t
         LEFT JOIN sync_entity_versions v ON v.entity = $1 AND v.onec_key = t.onec_ref::text
        WHERE t.onec_ref IS NOT NULL`,
      [entity],
    );
    return new Map(r.rows.map((x) => [x.k, x.dv ?? '']));
  }

  /**
   * Сверка количества (SYNC-003) и пометка не встреченных (SYNC-006): если `source.count` = число живых строк,
   * увиденных в прогоне, — строки таблицы без отметки `seen_in_run_id` этого прогона → `deletion_mark=true`.
   */
  private async reconcileTable(
    req: CatalogLoadRequest,
    kind: CatalogReadKind,
    table: CatalogTable,
    runIdFor: (e: SyncEntity) => Promise<string>,
    counts: Map<SyncEntity, EntityCounts>,
    state: ApplyState,
  ): Promise<void> {
    const entity = req.entity;
    const runId = await runIdFor(entity);
    const keyCol = table === 'barcodes' ? 'value' : 'onec_ref::text';
    const seen = await this.pool.query<{ n: string }>(
      `SELECT count(*)::text AS n FROM ${table} t
        WHERE NOT t.deletion_mark AND ${table === 'barcodes' ? 'true' : 't.onec_ref IS NOT NULL'}
          AND EXISTS (SELECT 1 FROM sync_entity_versions v WHERE v.entity = $1 AND v.onec_key = t.${keyCol} AND v.seen_in_run_id = $2)`,
      [entity, runId],
    );
    const localTotal = Number(seen.rows[0]?.n ?? 0);
    const sourceTotal = req.source.count ? await req.source.count(kind) : undefined;
    const c = counts.get(entity);
    if (c) {
      c.localTotal = (c.localTotal ?? 0) + localTotal;
      if (sourceTotal !== undefined) c.sourceTotal = (c.sourceTotal ?? 0) + sourceTotal;
    }
    if (sourceTotal !== undefined && sourceTotal !== localTotal) {
      await this.inTx(runIdFor, counts, (scope) => {
        scope.errors.push({
          entity,
          errorCode: 'COUNT_MISMATCH',
          severity: 'error',
          message: `${table}: в 1С ${sourceTotal}, в реплике (увидено в прогоне) ${localTotal} — пометка удалённых не выполнена (SYNC-006)`,
          payload: { table, sourceTotal, localTotal },
        });
        bump(scope, table, 'errors');
        return Promise.resolve();
      });
      return;
    }
    await this.inTx(runIdFor, counts, async (scope) => {
      const r = await scope.client.query<{ id: string }>(
        `UPDATE ${table} t SET deletion_mark = true, source_hash = 'deleted:' || t.source_hash, synced_at = $3
          WHERE NOT t.deletion_mark AND ${table === 'barcodes' ? 'true' : 't.onec_ref IS NOT NULL'}
            AND NOT EXISTS (SELECT 1 FROM sync_entity_versions v
                             WHERE v.entity = $1 AND v.onec_key = t.${keyCol} AND v.seen_in_run_id = $2)
          RETURNING t.id`,
        [entity, runId, scope.syncedAt.toISOString()],
      );
      bump(scope, table, 'markedDeleted', r.rowCount ?? 0);
      if ((r.rowCount ?? 0) > 0) {
        if (table === 'categories') state.dirty.categories = true;
        if (table === 'products') {
          for (const x of r.rows) state.dirty.products.add(x.id);
          await scope.client.query(
            `UPDATE product_variants SET deletion_mark = true WHERE is_default AND product_id = ANY($1::uuid[]) AND NOT deletion_mark`,
            [r.rows.map((x) => x.id)],
          );
        }
        if (table === 'product_variants') {
          const o = await scope.client.query<{ product_id: string }>(
            `SELECT DISTINCT product_id FROM product_variants WHERE id = ANY($1::uuid[])`,
            [r.rows.map((x) => x.id)],
          );
          for (const x of o.rows) state.dirty.variantOwners.add(x.product_id);
        }
        await refreshCatalogDerived(scope.client, state);
      }
    });
  }

  // ------------------------------------------------------------------ срезы

  private async loadPrices(
    req: CatalogLoadRequest,
    runIdFor: (e: SyncEntity) => Promise<string>,
    counts: Map<SyncEntity, EntityCounts>,
  ): Promise<number> {
    // Шаг 1 прогона prices — виды цен (05 SYNC-001: price_lists до prices).
    let pages =
      req.mode === 'incremental'
        ? await this.loadIncremental({ ...req }, runIdFor, counts)
        : await this.loadFull(req, runIdFor, counts);
    const lists = await this.pool.query<{ ref: string }>(
      `SELECT onec_ref::text AS ref FROM price_lists WHERE onec_ref IS NOT NULL AND NOT deletion_mark
          AND ($1::uuid[] IS NULL OR onec_ref = ANY($1::uuid[]))`,
      [req.priceListRefs ? [...req.priceListRefs] : null],
    );
    const refs = lists.rows.map((r) => r.ref);
    if (refs.length === 0) return pages;
    const tracker = newSliceTracker();
    pages += await this.slice(runIdFor, counts, tracker, req.source.priceSlice(refs), (scope, rows) =>
      applyPriceRows(scope, rows, tracker),
    );
    await this.inTx(runIdFor, counts, (scope) => finishPriceSlice(scope, tracker).then(() => undefined));
    return pages;
  }

  private async loadStock(
    req: CatalogLoadRequest,
    runIdFor: (e: SyncEntity) => Promise<string>,
    counts: Map<SyncEntity, EntityCounts>,
  ): Promise<number> {
    const tracker = newSliceTracker();
    const whs = await this.pool.query<{ id: string }>(
      `SELECT id FROM warehouses WHERE onec_ref IS NOT NULL AND ($1::uuid[] IS NULL OR onec_ref = ANY($1::uuid[]))`,
      [req.warehouseRefs ? [...req.warehouseRefs] : null],
    );
    for (const w of whs.rows) tracker.scopeIds.add(w.id);
    const pages = await this.slice(
      runIdFor,
      counts,
      tracker,
      req.source.stockSlice(req.warehouseRefs),
      (scope, rows) => applyStockRows(scope, rows, tracker),
      req.source,
    );
    await this.inTx(runIdFor, counts, (scope) => finishStockSlice(scope, tracker).then(() => undefined), req.source);
    return pages;
  }

  private async slice<T>(
    runIdFor: (e: SyncEntity) => Promise<string>,
    counts: Map<SyncEntity, EntityCounts>,
    tracker: SliceTracker,
    pages: AsyncIterable<readonly T[]>,
    apply: (scope: ApplyScope, rows: readonly T[]) => Promise<void>,
    source?: CatalogFullSource,
  ): Promise<number> {
    let n = 0;
    try {
      for await (const rows of pages) {
        n += 1;
        await this.inTx(runIdFor, counts, (scope) => apply(scope, rows), source);
      }
    } catch (e) {
      tracker.incomplete = true;
      throw e;
    }
    return n;
  }

  private async inTx(
    runIdFor: (e: SyncEntity) => Promise<string>,
    counts: Map<SyncEntity, EntityCounts>,
    fn: (scope: ApplyScope) => Promise<void>,
    source?: CatalogFullSource,
  ): Promise<void> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      const snapshot = source?.snapshotAt?.();
      const scope: ApplyScope = {
        client,
        runIdFor,
        syncedAt: this.now(),
        ...(snapshot ? { snapshotAt: snapshot } : {}),
        counts,
        errors: [],
        catalogChanges: newCatalogChangeSink(),
      };
      await fn(scope);
      await flushErrors(scope);
      await publishCatalogChanges(this.catalogChanges, client, scope.catalogChanges);
      await client.query('COMMIT');
    } catch (e) {
      await client.query('ROLLBACK').catch(() => undefined);
      throw e;
    } finally {
      client.release();
    }
  }
}

function errText(e: unknown): string {
  return (e instanceof Error ? e.message : String(e)).slice(0, 2000);
}
