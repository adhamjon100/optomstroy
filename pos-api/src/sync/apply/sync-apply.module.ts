import { Module } from '@nestjs/common';
import type pg from 'pg';
import pino, { type Logger } from 'pino';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { PG_POOL } from '../../common/db/database.module.js';
import { buildPinoOptions } from '../../common/logging/logger.config.js';
import { FakeOnecGateway } from '../../integrations/onec/fake-onec.gateway.js';
import { createOnecODataClient, createOnecTransport } from '../../integrations/onec/onec-adapters.js';
import { ONEC_GATEWAY, type OnecGateway } from '../../integrations/onec/onec-gateway.js';
import { OnecGatewayModule } from '../../integrations/onec/onec.module.js';
import type { ApplyRunTracker, ChangeItemHandler } from './apply.types.js';
import { CatalogApplier } from './catalog-applier.js';
import { CatalogFullLoadService } from './catalog-full-load.service.js';
import { type CatalogFullSource, SyntheticCatalogSource } from './catalog-source.js';
import { ODataCatalogSource } from './odata-catalog.source.js';
import { OnecChangesService } from './onec-changes.service.js';
import { createRunTracker } from './run-tracker.js';

/** DI-токен `ApplyRunTracker` (по умолчанию — `RegistryRunTracker` над `SyncRunRegistry`). */
export const SYNC_APPLY_RUN_TRACKER = 'SyncApplyRunTracker' as const;
/** DI-токен источника полной загрузки/срезов (`CatalogFullSource | null`): OData (фаза 0/срезы) или синтетика. */
export const CATALOG_FULL_SOURCE = 'CatalogFullSource' as const;
/** DI-токен обработчиков не-каталожных элементов `/changes` (`ChangeItemHandler[]`). */
export const SYNC_APPLY_CHANGE_HANDLERS = 'SyncApplyChangeHandlers' as const;
/** DI-токен pino-логгера конвейера. */
export const SYNC_APPLY_LOGGER = 'SyncApplyLogger' as const;

/**
 * Источник полной загрузки по `ONEC_MODE`: `fixtures` — синтетический каталог фейка (если включён режим
 * каталога), `odata_only`/`extension` — OData `pos_integration` (срезы цен/остатков в фазе 1 тоже читаются через
 * OData, 05 SYNC-014/015), если заданы `ONEC_BASE_URL` и `ONEC_USER_FILE`; иначе `null` (полная загрузка недоступна).
 */
export function createCatalogFullSource(config: AppConfig, gateway: OnecGateway): CatalogFullSource | null {
  if (gateway instanceof FakeOnecGateway) return gateway.catalog ? new SyntheticCatalogSource(gateway) : null;
  if (config.ONEC_BASE_URL && config.ONEC_USER !== undefined) {
    return new ODataCatalogSource(createOnecODataClient(config, createOnecTransport(config)));
  }
  return null;
}

/**
 * Конвейер применения данных 1С к репликам каталога (RM-E-001): `CatalogApplier`, `OnecChangesService`
 * (фаза 1, план обмена), `CatalogFullLoadService` (full/reconcile/фаза 0). Подключают модуль `sync`
 * (планировщик RM-E-002) и worker; требует `PG_POOL`, `APP_CONFIG` (глобальные модули каркаса).
 */
@Module({
  imports: [OnecGatewayModule],
  providers: [
    CatalogApplier,
    {
      provide: SYNC_APPLY_LOGGER,
      inject: [APP_CONFIG],
      useFactory: (c: AppConfig): Logger => pino(buildPinoOptions(c, 'pos-worker')).child({ component: 'sync.apply' }),
    },
    {
      provide: SYNC_APPLY_RUN_TRACKER,
      inject: [PG_POOL],
      useFactory: (pool: pg.Pool): ApplyRunTracker => createRunTracker(pool),
    },
    { provide: SYNC_APPLY_CHANGE_HANDLERS, useValue: [] as ChangeItemHandler[] },
    {
      provide: CATALOG_FULL_SOURCE,
      inject: [APP_CONFIG, ONEC_GATEWAY],
      useFactory: (c: AppConfig, g: OnecGateway) => createCatalogFullSource(c, g),
    },
    {
      provide: OnecChangesService,
      inject: [
        PG_POOL,
        ONEC_GATEWAY,
        CatalogApplier,
        SYNC_APPLY_RUN_TRACKER,
        SYNC_APPLY_LOGGER,
        APP_CONFIG,
        CATALOG_FULL_SOURCE,
        SYNC_APPLY_CHANGE_HANDLERS,
      ],
      useFactory: (
        pool: pg.Pool,
        gateway: OnecGateway,
        applier: CatalogApplier,
        runs: ApplyRunTracker,
        log: Logger,
        c: AppConfig,
        source: CatalogFullSource | null,
        handlers: ChangeItemHandler[],
      ) =>
        new OnecChangesService(pool, gateway, applier, runs, log, {
          pageSize: c.ONEC_SYNC_PAGE_SIZE,
          handlers,
          ...(source ? { slices: source } : {}),
        }),
    },
    {
      provide: CatalogFullLoadService,
      inject: [PG_POOL, CatalogApplier, SYNC_APPLY_RUN_TRACKER, SYNC_APPLY_LOGGER],
      useFactory: (pool: pg.Pool, applier: CatalogApplier, runs: ApplyRunTracker, log: Logger) =>
        new CatalogFullLoadService(pool, applier, runs, log),
    },
  ],
  exports: [CatalogApplier, OnecChangesService, CatalogFullLoadService, SYNC_APPLY_RUN_TRACKER, CATALOG_FULL_SOURCE],
})
export class SyncApplyModule {}
