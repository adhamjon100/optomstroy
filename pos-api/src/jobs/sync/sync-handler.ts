import type { Logger } from 'pino';
import type { SyncEntity, SyncMode, SyncTrigger } from '../../common/enums.js';
import type { SyncErrorCode } from '../sync-errors.writer.js';

/** Контекст прогона, который получает обработчик сущности. */
export interface SyncRunContext {
  readonly runId: string;
  readonly entity: SyncEntity;
  readonly mode: SyncMode;
  readonly trigger: SyncTrigger;
  readonly jobId: string;
  readonly attempt: number;
  readonly log: Logger;
  /** Прогресс долгого прогона (`sync_runs.counts`) и отметка «жив». */
  touch(counts?: Readonly<Record<string, unknown>>): Promise<void>;
}

export interface SyncHandlerResult {
  readonly status?: 'success' | 'partial';
  readonly counts?: Readonly<Record<string, unknown>>;
  /** `false` — заглушка: прогон не загружал данные (свежесть `sync_state` не сдвигается). */
  readonly implemented: boolean;
}

/** Обработчик сущности: реальная загрузка из 1С — RM-E-001/RM-E-002 (этап E), документы — этап F. */
export interface SyncEntityHandler {
  run(ctx: SyncRunContext): Promise<SyncHandlerResult>;
}

/** Ошибка прогона с кодом словаря `sync_errors.error_code` (07 §6.1.1). */
export class SyncRunError extends Error {
  constructor(
    readonly code: SyncErrorCode,
    message: string,
  ) {
    super(message);
    this.name = 'SyncRunError';
  }
}

/** Заглушка этапа C: только логирует; данные не загружаются. */
export class StubSyncHandler implements SyncEntityHandler {
  run(ctx: SyncRunContext): Promise<SyncHandlerResult> {
    ctx.log.info(
      { entity: ctx.entity, mode: ctx.mode, trigger: ctx.trigger, runId: ctx.runId, jobId: ctx.jobId },
      'sync.stub: обработчик сущности — заглушка (загрузка из 1С — этап E/F)',
    );
    return Promise.resolve({ implemented: false, counts: {} });
  }
}
