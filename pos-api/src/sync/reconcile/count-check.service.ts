import type pg from 'pg';
import type { Logger } from 'pino';
import type { SyncEntity, SyncTrigger } from '../../common/enums.js';
import { writeSyncError } from '../../jobs/sync-errors.writer.js';
import type { CatalogFullSource, CatalogReadKind } from '../apply/catalog-source.js';
import type { SyncAlertService } from '../alerts/sync-alerts.service.js';
import { SyncAlreadyRunningError, type SyncRunRegistry } from '../scheduler/sync-run.registry.js';

/**
 * Таблицы сверки `$count` по сущностям фазы 0 (05 SYNC-068; ядро §20.2 п. 7): `products` — две таблицы
 * (`products`, `packagings`), `prices` — только справочная часть (`price_lists`). `customers`, `discounts` —
 * сверяются, когда их источник поддержит `$count` (этап G): сейчас `CatalogFullSource` их не читает.
 */
export const COUNT_CHECK_TABLES: Readonly<
  Partial<Record<SyncEntity, readonly { readonly kind: CatalogReadKind; readonly table: string }[]>>
> = {
  categories: [{ kind: 'categories', table: 'categories' }],
  products: [
    { kind: 'products', table: 'products' },
    { kind: 'packagings', table: 'packagings' },
  ],
  variants: [{ kind: 'variants', table: 'product_variants' }],
  units: [{ kind: 'units', table: 'units' }],
  barcodes: [{ kind: 'barcodes', table: 'barcodes' }],
  warehouses: [{ kind: 'warehouses', table: 'warehouses' }],
  prices: [{ kind: 'price_lists', table: 'price_lists' }],
};

export const COUNT_CHECK_ENTITIES = Object.keys(COUNT_CHECK_TABLES) as SyncEntity[];

export interface CountCheckTableResult {
  readonly table: string;
  readonly sourceTotal: number; // money-double: allow — число записей ($count), не деньги
  readonly localTotal: number; // money-double: allow — число записей, не деньги
  readonly diff: number;
}

export interface CountCheckEntityResult {
  readonly entity: SyncEntity;
  /** `skipped` — источник не умеет `$count` или идёт другой прогон сущности (singleton). */
  readonly status: 'success' | 'partial' | 'failed' | 'skipped';
  readonly runId?: string;
  readonly tables: readonly CountCheckTableResult[];
  readonly reason?: string;
}

export interface CountCheckReport {
  readonly startedAt: string;
  readonly finishedAt: string;
  readonly source: string;
  readonly mismatches: number;
  readonly entities: readonly CountCheckEntityResult[];
}

/**
 * Сверка количества записей 1С ↔ backend (05 SYNC-003, SYNC-068; RM-E-002): `GET …/$count` источника против
 * `local_total` (живые строки с `onec_ref`, `deletion_mark=false`; служебные варианты `is_default` без `onec_ref`
 * не считаются) по каждой таблице. Прогон `sync_runs` сущности: `mode=reconcile`, `success` либо `partial` при
 * расхождении (+ `sync_errors` `COUNT_MISMATCH` с таблицей и разницей, уведомление `sync_error` администратору).
 * Данные не загружаются и не помечаются — поэтому прогон не меняет `sync_state` (свежесть и счётчик ошибок).
 */
export class CountCheckService {
  constructor(
    private readonly db: Pick<pg.Pool, 'query'>,
    private readonly registry: SyncRunRegistry,
    private readonly source: CatalogFullSource | null,
    private readonly log: Logger,
    private readonly alerts?: SyncAlertService,
  ) {}

  async run(opts: { trigger?: SyncTrigger; entities?: readonly SyncEntity[] } = {}): Promise<CountCheckReport> {
    const startedAt = new Date().toISOString();
    const out: CountCheckEntityResult[] = [];
    const source = this.source;
    for (const entity of opts.entities ?? COUNT_CHECK_ENTITIES) {
      const tables = COUNT_CHECK_TABLES[entity];
      if (!tables || !source?.count) {
        out.push({ entity, status: 'skipped', tables: [], reason: 'source_without_count' });
        continue;
      }
      out.push(await this.checkEntity(entity, tables, source, opts.trigger ?? 'schedule'));
    }
    const report: CountCheckReport = {
      startedAt,
      finishedAt: new Date().toISOString(),
      source: source?.name ?? 'none',
      mismatches: out.filter((e) => e.status === 'partial').length,
      entities: out,
    };
    this.log.info(
      {
        source: report.source,
        mismatches: report.mismatches,
        entities: out.map((e) => ({ entity: e.entity, status: e.status, tables: e.tables })),
      },
      'sync.count_check.report',
    );
    return report;
  }

  private async checkEntity(
    entity: SyncEntity,
    tables: readonly { kind: CatalogReadKind; table: string }[],
    source: CatalogFullSource,
    trigger: SyncTrigger,
  ): Promise<CountCheckEntityResult> {
    let runId: string;
    try {
      runId = await this.registry.acquire({ entity, mode: 'reconcile', trigger });
    } catch (e) {
      if (e instanceof SyncAlreadyRunningError) {
        return { entity, status: 'skipped', tables: [], reason: 'already_running' };
      }
      throw e;
    }
    const results: CountCheckTableResult[] = [];
    try {
      await this.db.query(`UPDATE sync_runs SET onec_endpoint = $2 WHERE id = $1`, [runId, `$count:${source.name}`]);
      for (const t of tables) {
        const sourceTotal = await source.count!(t.kind);
        if (sourceTotal === undefined) continue;
        const localTotal = await this.localTotal(t.table);
        results.push({ table: t.table, sourceTotal, localTotal, diff: sourceTotal - localTotal });
      }
      const bad = results.filter((r) => r.diff !== 0);
      for (const r of bad) {
        await writeSyncError(this.db, {
          entity,
          syncRunId: runId,
          errorCode: 'COUNT_MISMATCH',
          severity: 'error',
          message: `${r.table}: в 1С ${r.sourceTotal}, в POS ${r.localTotal} (разница ${r.diff})`,
          payload: { table: r.table, sourceTotal: r.sourceTotal, localTotal: r.localTotal, diff: r.diff },
        });
      }
      const status = bad.length > 0 ? 'partial' : 'success';
      const sum = (k: 'sourceTotal' | 'localTotal') => results.reduce((a, r) => a + r[k], 0);
      await this.registry.finish({
        runId,
        entity,
        status,
        counts: {
          fetched: 0,
          sourceTotal: sum('sourceTotal'),
          localTotal: sum('localTotal'),
          errors: bad.length,
          tables: results,
        },
        ...(bad.length > 0 ? { errorSummary: `COUNT_MISMATCH: ${bad.map((r) => r.table).join(', ')}` } : {}),
        implemented: false,
        updateState: false,
      });
      if (bad.length > 0) {
        await this.alerts
          ?.countMismatch({ entity, runId, tables: bad })
          .catch((err: unknown) => this.log.error({ err, entity, runId }, 'sync.alert.failed'));
      }
      return { entity, status, runId, tables: results };
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      await this.registry
        .finish({ runId, entity, status: 'failed', errorSummary: message, implemented: false, updateState: false })
        .catch(() => undefined);
      await writeSyncError(this.db, {
        entity,
        syncRunId: runId,
        errorCode: 'ONEC_UNAVAILABLE',
        severity: 'error',
        message: `сверка $count не выполнена: ${message}`,
      }).catch(() => undefined);
      this.log.warn({ err: e, entity, runId }, 'sync.count_check.failed');
      return { entity, status: 'failed', runId, tables: results, reason: message.slice(0, 200) };
    }
  }

  private async localTotal(table: string): Promise<number> {
    // Имя таблицы — только из COUNT_CHECK_TABLES (константа), не из ввода.
    const where = table === 'barcodes' ? 'NOT deletion_mark' : 'NOT deletion_mark AND onec_ref IS NOT NULL';
    const r = await this.db.query<{ n: string }>(`SELECT count(*)::text AS n FROM ${table} WHERE ${where}`);
    return Number(r.rows[0]?.n ?? 0);
  }
}
