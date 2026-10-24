import type { SyncEntityHandler, SyncHandlerResult, SyncRunContext } from '../../jobs/sync/sync-handler.js';
import type { ImageListSource } from './image-sources.js';
import type { ImageSyncService } from './image-sync.service.js';

/**
 * Обработчик сущности `images` для `SyncJobProcessor` (очередь `sync.images`, cron `SYNC_IMAGES_CRON` —
 * по умолчанию `30 2 * * *`, раз в сутки ночью, 05 SYNC-011/SYNC-035): прогон `sync_runs` уже создан
 * процессором (singleton), сервис его не завершает. Полный список файлов (OData) — если источник настроен.
 * Регистрация в `WorkerRuntime`: `handlers: { images: new ImageSyncHandler(service, listSource) }`.
 */
export class ImageSyncHandler implements SyncEntityHandler {
  constructor(
    private readonly service: ImageSyncService,
    private readonly listSource: ImageListSource | null = null,
  ) {}

  async run(ctx: SyncRunContext): Promise<SyncHandlerResult> {
    const r = await this.service.run({
      runId: ctx.runId,
      trigger: ctx.trigger,
      mode: ctx.mode,
      listSource: this.listSource,
    });
    await ctx.touch({ ...r.counts });
    return {
      status: r.status,
      counts: { ...r.counts, sourceAvailable: r.sourceAvailable },
      implemented: true,
    };
  }
}
