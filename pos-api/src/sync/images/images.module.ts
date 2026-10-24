import { Module } from '@nestjs/common';
import type pg from 'pg';
import pino, { type Logger } from 'pino';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { PG_POOL } from '../../common/db/database.module.js';
import { buildPinoOptions } from '../../common/logging/logger.config.js';
import { createOnecODataClient, createOnecTransport } from '../../integrations/onec/onec-adapters.js';
import { ONEC_GATEWAY, type OnecGateway } from '../../integrations/onec/onec-gateway.js';
import { OnecGatewayModule } from '../../integrations/onec/onec.module.js';
import type { ApplyRunTracker } from '../apply/apply.types.js';
import { createRunTracker } from '../apply/run-tracker.js';
import { ImageDirectoryImporter } from './image-directory-import.js';
import { ProductImageFilesHandler } from './image-files.handler.js';
import {
  GatewayImageSource,
  type ImageBytesSource,
  type ImageListSource,
  ODataImageListSource,
} from './image-sources.js';
import { ImageStore } from './image-store.js';
import { ImageSyncHandler } from './image-sync.handler.js';
import { ImageSyncService } from './image-sync.service.js';

/** DI-токены модуля фото (RM-E-003). */
export const IMAGE_STORE = 'ImageStore' as const;
export const IMAGE_BYTES_SOURCE = 'ImageBytesSource' as const;
export const IMAGE_LIST_SOURCE = 'ImageListSource' as const;
export const IMAGES_RUN_TRACKER = 'ImagesRunTracker' as const;
export const IMAGES_LOGGER = 'ImagesLogger' as const;

/** Источник байтов по `ONEC_MODE`: HS расширения / фейк; `odata_only` — нет (фото — разовой выгрузкой, SYNC-036). */
export function createImageBytesSource(gateway: OnecGateway): ImageBytesSource | null {
  return gateway.mode === 'odata_only' ? null : new GatewayImageSource(gateway);
}

/** Полный список файлов (OData `Catalog_НоменклатураПрисоединенныеФайлы`) — если заданы `ONEC_BASE_URL` и `ONEC_USER_FILE`. */
export function createImageListSource(config: AppConfig): ImageListSource | null {
  if (config.ONEC_MODE === 'fixtures' || !config.ONEC_BASE_URL || config.ONEC_USER === undefined) return null;
  return new ODataImageListSource(createOnecODataClient(config, createOnecTransport(config)));
}

/**
 * Фото товаров (RM-E-003; D-30; 05 ONEC-006, SYNC-035, SYNC-036): ежесуточный прогон `ImageSyncService`
 * (порт планировщика — `ImageSyncHandler`), обработчик `/changes` `ProductImageFilesHandler` (регистрируется в
 * `SYNC_APPLY_CHANGE_HANDLERS`), разовый импорт каталога `ImageDirectoryImporter`. Хранилище — `MEDIA_DIR`
 * (16 §4.3) `/images/{sha256}/{size}.webp`. Требует глобальные `PG_POOL`, `APP_CONFIG`.
 */
@Module({
  imports: [OnecGatewayModule],
  providers: [
    { provide: IMAGE_STORE, inject: [APP_CONFIG], useFactory: (c: AppConfig) => new ImageStore(c.MEDIA_DIR) },
    { provide: IMAGE_BYTES_SOURCE, inject: [ONEC_GATEWAY], useFactory: createImageBytesSource },
    { provide: IMAGE_LIST_SOURCE, inject: [APP_CONFIG], useFactory: createImageListSource },
    {
      provide: IMAGES_RUN_TRACKER,
      inject: [PG_POOL],
      useFactory: (pool: pg.Pool): ApplyRunTracker => createRunTracker(pool),
    },
    {
      provide: IMAGES_LOGGER,
      inject: [APP_CONFIG],
      useFactory: (c: AppConfig): Logger => pino(buildPinoOptions(c, 'pos-worker')).child({ component: 'sync.images' }),
    },
    {
      provide: ImageSyncService,
      inject: [PG_POOL, IMAGE_BYTES_SOURCE, IMAGE_STORE, IMAGES_RUN_TRACKER, IMAGES_LOGGER, APP_CONFIG],
      useFactory: (
        pool: pg.Pool,
        source: ImageBytesSource | null,
        store: ImageStore,
        runs: ApplyRunTracker,
        log: Logger,
        c: AppConfig,
      ) => new ImageSyncService(pool, source, store, runs, log, { concurrency: Math.min(2, c.ONEC_MAX_CONCURRENCY) }),
    },
    {
      provide: ImageSyncHandler,
      inject: [ImageSyncService, IMAGE_LIST_SOURCE],
      useFactory: (s: ImageSyncService, list: ImageListSource | null) => new ImageSyncHandler(s, list),
    },
    { provide: ProductImageFilesHandler, useFactory: () => new ProductImageFilesHandler() },
    {
      provide: ImageDirectoryImporter,
      inject: [PG_POOL, IMAGE_STORE, IMAGES_RUN_TRACKER, IMAGES_LOGGER],
      useFactory: (pool: pg.Pool, store: ImageStore, runs: ApplyRunTracker, log: Logger) =>
        new ImageDirectoryImporter(pool, store, runs, log),
    },
  ],
  exports: [ImageSyncService, ImageSyncHandler, ProductImageFilesHandler, ImageDirectoryImporter, IMAGE_STORE],
})
export class SyncImagesModule {}
