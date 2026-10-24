import type { Logger } from 'pino';
import type { OnecChangesService } from '../../sync/apply/onec-changes.service.js';
import type { SyncAlertService } from '../../sync/alerts/sync-alerts.service.js';
import type { ImagesGcService } from '../../sync/images/images-gc.service.js';
import type { CountCheckService } from '../../sync/reconcile/count-check.service.js';
import type { AppConfig } from '../../common/config/app-config.js';
import type { SyncEntityHandler } from './sync-handler.js';

/** Обработчик очереди pg-boss без собственного прогона `sync_runs` (тикеры `onec.changes`, `sync.count_check`). */
export type SyncQueueJob = (job: { readonly id: string; readonly data: unknown }) => Promise<unknown>;

/**
 * Порт фото (RM-E-003, D-30): реализацию даёт модуль фото (`src/sync/images`); здесь — только контракт
 * обработчика сущности `images` для `SyncJobProcessor` (раз в сутки по `SYNC_IMAGES_CRON` + ручной запуск).
 * DI-токен — для модулей Nest, которые захотят переопределить обработчик.
 */
export const SYNC_IMAGES_HANDLER = 'SyncImagesHandler' as const;
export type SyncImagesHandler = SyncEntityHandler;

/**
 * Плановый цикл `onec.changes` (05 SYNC-011; ядро §22.8): одна job на узел; ошибка → исключение (ack не отправлен,
 * следующий цикл повторит сообщение). После цикла — проверка алертов `consecutive_errors` (SYNC-038).
 */
export function onecChangesJob(changes: OnecChangesService, alerts: SyncAlertService, log: Logger): SyncQueueJob {
  return async (job) => {
    try {
      const r = await changes.pullOnce({ trigger: 'schedule', requestId: job.id });
      return {
        status: r.status,
        messageNumber: r.messageNumber ?? null,
        items: r.items,
        errors: r.errors,
        entities: Object.keys(r.runIds),
      };
    } catch (e) {
      log.warn({ err: e, jobId: job.id }, 'onec.changes.job_failed');
      throw e;
    } finally {
      await alerts.sweep().catch((err: unknown) => log.error({ err }, 'sync.alert.sweep_failed'));
    }
  };
}

/**
 * `sync.count_check` (05 SYNC-068; 16 §4.3 `SYNC_COUNT_CHECK_CRON`): ночная сверка `$count` в фазе 0
 * (`odata_only`; `fixtures` — на синтетике). В режиме расширения сверка количества не выполняется (добор
 * неподтверждённых элементов outbox — этап F).
 */
export function countCheckJob(
  onecMode: AppConfig['ONEC_MODE'],
  countCheck: CountCheckService,
  log: Logger,
): SyncQueueJob {
  return async (job) => {
    if (onecMode === 'extension') {
      log.info({ jobId: job.id }, 'sync.count_check.skipped: режим extension — сверка $count только в фазе 0');
      return { status: 'skipped', reason: 'extension_mode' };
    }
    return countCheck.run({ trigger: 'schedule' });
  };
}

/**
 * `images.gc` (EQ-IMG-10; 07 §5.23): ежесуточная очистка осиротевших файлов фото — пометка кандидатов, удаление
 * помеченных в следующем цикле (`ImagesGcService`). Результат — output job pg-boss.
 */
export function imagesGcJob(gc: Pick<ImagesGcService, 'run'>): SyncQueueJob {
  return () => gc.run();
}
