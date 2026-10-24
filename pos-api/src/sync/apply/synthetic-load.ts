import type pg from 'pg';
import pino, { type Logger } from 'pino';
import type { SyncTrigger } from '../../common/enums.js';
import {
  SyntheticCatalog,
  type SyntheticCatalogOptions,
  type SyntheticCatalogStats,
} from '../../integrations/onec/synthetic-catalog.js';
import type { ApplyRunTracker } from './apply.types.js';
import { CatalogApplier } from './catalog-applier.js';
import { type CatalogLoadResult, CatalogFullLoadService } from './catalog-full-load.service.js';
import { SyntheticCatalogSource } from './catalog-source.js';
import { createRunTracker } from './run-tracker.js';

export interface SyntheticLoadOptions {
  /** Готовый каталог (например, `FakeOnecGateway.catalog`) или параметры генератора. */
  readonly catalog: SyntheticCatalog | SyntheticCatalogOptions;
  /** Размер страницы полной загрузки (по умолчанию 1000 — как `ONEC_SYNC_PAGE_SIZE`). */
  readonly pageSize?: number;
  readonly log?: Logger;
  readonly runs?: ApplyRunTracker;
  readonly trigger?: SyncTrigger;
}

export interface SyntheticLoadResult {
  readonly catalog: SyntheticCatalog;
  readonly stats: SyntheticCatalogStats;
  readonly results: readonly CatalogLoadResult[];
  readonly generateMs: number;
  readonly loadMs: number;
}

/**
 * Полная загрузка синтетического каталога через конвейер применения (тот же код, что для 1С): units → categories →
 * products (+packagings) → variants → attributes → barcodes → warehouses → prices (+price_lists) → stock.
 * **Тестовые данные** — для бенчмарка поиска (RM-E-005), фикстур тестов и загрузки «на фикстурах» (RM-E-011).
 */
export async function loadSyntheticCatalog(pool: pg.Pool, options: SyntheticLoadOptions): Promise<SyntheticLoadResult> {
  const t0 = performance.now();
  const catalog = options.catalog instanceof SyntheticCatalog ? options.catalog : new SyntheticCatalog(options.catalog);
  const generateMs = performance.now() - t0;
  const log = options.log ?? pino({ level: 'silent' });
  const service = new CatalogFullLoadService(pool, new CatalogApplier(), options.runs ?? createRunTracker(pool), log);
  const t1 = performance.now();
  const results = await service.loadAll(
    new SyntheticCatalogSource(catalog, options.pageSize ?? 1000),
    'full',
    options.trigger ?? 'manual',
  );
  return { catalog, stats: catalog.stats(), results, generateMs, loadMs: performance.now() - t1 };
}
