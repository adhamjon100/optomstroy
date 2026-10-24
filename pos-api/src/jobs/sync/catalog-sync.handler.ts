import type { AppConfig } from '../../common/config/app-config.js';
import type { SyncEntity } from '../../common/enums.js';
import {
  CATALOG_LOAD_ENTITIES,
  type CatalogFullLoadService,
  type CatalogLoadEntity,
  type CatalogLoadMode,
} from '../../sync/apply/catalog-full-load.service.js';
import type { CatalogFullSource } from '../../sync/apply/catalog-source.js';
import { EXTENSION_POLLED_ENTITIES } from '../../sync/scheduler/sync-queues.js';
import {
  type SyncEntityHandler,
  type SyncHandlerResult,
  type SyncRunContext,
  StubSyncHandler,
} from './sync-handler.js';
import { runCounts } from './sync-counts.js';

export function isCatalogLoadEntity(e: SyncEntity): e is CatalogLoadEntity {
  return (CATALOG_LOAD_ENTITIES as readonly string[]).includes(e);
}

/**
 * Обработчик сущностей каталога (07 §6.2; RM-E-001 → RM-E-002): прогон `sync_runs`, уже созданный
 * `SyncJobProcessor`, выполняет `CatalogFullLoadService` (`full`/`reconcile` — полная перечитка со сверкой `$count`,
 * `incremental` — фаза 0 по ключам и DataVersion; `stock`/`prices` — полный срез). В режиме расширения инкремент
 * сущностей плана обмена делегируется циклу `onec.changes` (`planHandler`). Без источника (нет OData и
 * синтетического каталога) — заглушка: прогон завершается без загрузки, свежесть не сдвигается.
 */
export class CatalogSyncHandler implements SyncEntityHandler {
  private readonly stub = new StubSyncHandler();

  constructor(
    private readonly onecMode: AppConfig['ONEC_MODE'],
    private readonly fullLoad: CatalogFullLoadService,
    private readonly source: CatalogFullSource | null,
    private readonly planHandler?: SyncEntityHandler,
  ) {}

  async run(ctx: SyncRunContext): Promise<SyncHandlerResult> {
    if (!isCatalogLoadEntity(ctx.entity)) return this.stub.run(ctx);
    const mode: CatalogLoadMode = ctx.mode === 'manual' ? 'incremental' : ctx.mode;
    if (
      this.onecMode === 'extension' &&
      mode === 'incremental' &&
      !EXTENSION_POLLED_ENTITIES.includes(ctx.entity) &&
      this.planHandler
    ) {
      return this.planHandler.run(ctx);
    }
    if (!this.source) {
      ctx.log.warn(
        { entity: ctx.entity, mode },
        'sync.catalog.no_source: источник 1С для загрузки каталога не настроен — прогон без загрузки',
      );
      return this.stub.run(ctx);
    }
    const r = await this.fullLoad.run({
      entity: ctx.entity,
      mode,
      source: this.source,
      trigger: ctx.trigger,
      runId: ctx.runId,
    });
    return { status: r.status, implemented: true, counts: { ...runCounts(r.counts), pages: r.pages } };
  }
}
