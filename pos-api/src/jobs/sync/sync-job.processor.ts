import type pg from 'pg';
import type { Logger } from 'pino';
import {
  isSyncEntity,
  isSyncMode,
  isSyncTrigger,
  type SyncEntity,
  type SyncMode,
  type SyncTrigger,
} from '../../common/enums.js';
import { isOnecAuthFailure } from '../../integrations/onec/onec-error.js';
import { OnecApiCompatibility, OnecApiPausedError } from '../../sync/alerts/onec-api-compat.js';
import { OnecAuthPause } from '../../sync/alerts/onec-auth-pause.js';
import { SyncAlertService } from '../../sync/alerts/sync-alerts.service.js';
import type { SyncJobPayload } from '../../sync/scheduler/sync-queues.js';
import { SyncAlreadyRunningError, type SyncRunRegistry } from '../../sync/scheduler/sync-run.registry.js';
import { writeSyncError } from '../sync-errors.writer.js';
import { type SyncEntityHandler, SyncRunError } from './sync-handler.js';

/** Метаданные job pg-boss, нужные процессору. */
export interface SyncJobMeta {
  readonly id: string;
  readonly retryCount: number;
  readonly retryLimit?: number;
}

export type SyncJobOutcome =
  | { readonly status: 'completed'; readonly runId: string; readonly implemented: boolean }
  | { readonly status: 'skipped'; readonly code: 'SYNC_ALREADY_RUNNING'; readonly activeRunId?: string }
  /** Пауза чтения после 401/403 (05 §6.5): к 1С не обращались; ручной прогон завершён `failed` с причиной. */
  | { readonly status: 'skipped'; readonly code: 'ONEC_AUTH_PAUSED'; readonly until: string; readonly runId?: string }
  /**
   * Обмен приостановлен из-за несовместимой версии API расширения (05 ONEC-095, F13): к 1С не обращались (или цикл
   * `/changes` остановился на `/health`); ручной прогон завершён `failed` с причиной, `consecutive_errors` не растёт.
   */
  | { readonly status: 'skipped'; readonly code: 'ONEC_API_PAUSED'; readonly reason: string; readonly runId?: string }
  /** 1С отклонила авторизацию: прогон `failed`, без повторов pg-boss (05 §6.5), пауза и тревога администратору. */
  | { readonly status: 'failed'; readonly code: 'ONEC_AUTH_FAILED'; readonly runId: string };

/**
 * Выполнение job синхронизации сущности (очереди `sync.<entity>`, `sync.manual`, `sync.reconcile`):
 * singleton (строка `sync_runs`) → обработчик → итог прогона и `sync_state`; ошибка → `sync_runs.failed`,
 * `sync_errors` и исключение для pg-boss (повтор с backoff, после `retryLimit` — dead-letter).
 * Плановый запуск при идущем прогоне не ошибка: job завершается с `SYNC_ALREADY_RUNNING` (SYNC-023).
 */
export class SyncJobProcessor {
  private readonly authPause: OnecAuthPause | null;
  private readonly apiPause: Pick<OnecApiCompatibility, 'active'> | null;

  /**
   * `authPause` — пауза чтения после 401/403 (05 §6.5); по умолчанию — отметка `sync_node_state.auth_error_at` того же
   * пула с тревогой администратору; `null` — без паузы. `apiPause` — пауза обмена по несовместимой версии API
   * расширения (05 ONEC-095; 05 SYNC-028: «при `paused` cron-job завершается без обращения к 1С»); по умолчанию —
   * отметка `sync_state.paused` того же пула; `null` — без проверки.
   */
  constructor(
    private readonly registry: SyncRunRegistry,
    private readonly handlerFor: (entity: SyncEntity) => SyncEntityHandler,
    private readonly db: Pick<pg.Pool, 'query'>,
    private readonly log: Logger,
    authPause?: OnecAuthPause | null,
    apiPause?: Pick<OnecApiCompatibility, 'active'> | null,
  ) {
    this.authPause =
      authPause !== undefined
        ? authPause
        : new OnecAuthPause(db, { alerts: new SyncAlertService(db, log.child({ component: 'sync.alerts' })), log });
    this.apiPause = apiPause !== undefined ? apiPause : new OnecApiCompatibility(db, { log });
  }

  async process(job: SyncJobMeta, raw: unknown): Promise<SyncJobOutcome> {
    const payload = parsePayload(raw);
    const attempt = job.retryCount + 1;
    const base = { entity: payload.entity, mode: payload.mode, trigger: payload.trigger, jobId: job.id, attempt };
    // 05 §6.5, ТЗ А.1: после 401/403 чтение из 1С — не раньше чем через 15 мин (все сущности читают 1С).
    const pause = await this.authPause?.active();
    if (pause) return this.skipPaused(payload, job, pause.until, base);
    // 05 ONEC-095 / SYNC-028: обмен приостановлен (несовместимая версия API расширения) — к 1С не обращаемся.
    const apiPaused = await this.apiPause?.active(payload.entity);
    if (apiPaused) return this.skipApiPaused(payload, job, apiPaused.reason, base);
    let runId: string;
    try {
      runId = await this.registry.acquire({
        entity: payload.entity,
        mode: payload.mode,
        trigger: job.retryCount > 0 && payload.trigger === 'schedule' ? 'retry' : payload.trigger,
        jobId: job.id,
        ...(payload.runId ? { runId: payload.runId } : {}),
        ...(payload.userId ? { userId: payload.userId } : {}),
      });
    } catch (e) {
      if (e instanceof SyncAlreadyRunningError) {
        this.log.info(
          { ...base, code: e.code, activeRunId: e.activeRunId },
          'sync.job.skipped: прогон сущности уже идёт',
        );
        return {
          status: 'skipped',
          code: 'SYNC_ALREADY_RUNNING',
          ...(e.activeRunId ? { activeRunId: e.activeRunId } : {}),
        };
      }
      throw e;
    }

    const runLog = this.log.child({
      runId,
      entity: payload.entity,
      jobId: job.id,
      ...(payload.requestId ? { requestId: payload.requestId } : {}),
    });
    runLog.info({ mode: payload.mode, trigger: payload.trigger, attempt }, 'sync.run.started');
    try {
      const result = await this.handlerFor(payload.entity).run({
        runId,
        entity: payload.entity,
        mode: payload.mode,
        trigger: payload.trigger,
        jobId: job.id,
        attempt,
        log: runLog,
        touch: (counts) => this.registry.touch(runId, counts),
      });
      await this.registry.finish({
        runId,
        entity: payload.entity,
        status: result.status ?? 'success',
        counts: { ...result.counts, ...(result.implemented ? {} : { stub: true }) },
        implemented: result.implemented,
      });
      runLog.info({ status: result.status ?? 'success', implemented: result.implemented }, 'sync.run.finished');
      return { status: 'completed', runId, implemented: result.implemented };
    } catch (e) {
      if (e instanceof OnecApiPausedError) {
        // Цикл `/changes` ручного прогона остановился на `/health` (ONEC-095): не ошибка прогона и не повтор.
        await this.registry
          .finish({
            runId,
            entity: payload.entity,
            status: 'failed',
            errorSummary: e.reason,
            implemented: false,
            updateState: false,
          })
          .catch((err: unknown) => runLog.error({ err }, 'sync.run.finish_failed'));
        runLog.warn({ reason: e.reason }, 'sync.job.api_paused: обмен с 1С приостановлен (версия API)');
        return { status: 'skipped', code: 'ONEC_API_PAUSED', reason: e.reason, runId };
      }
      const message = e instanceof Error ? e.message : String(e);
      // 401/403: повтор не поможет до исправления учётных данных — без ретраев SYNC-029 (05 §6.5).
      const auth = isOnecAuthFailure(e);
      const code = auth ? 'ONEC_REJECTED' : e instanceof SyncRunError ? e.code : 'OTHER';
      const last = auth || job.retryLimit === undefined || job.retryCount >= job.retryLimit;
      // 05 SYNC-029 (б): `consecutive_errors` растёт на 1 за прогон, т. е. только после последней попытки job;
      // промежуточные попытки (а) завершают строку `sync_runs` как `failed`, не трогая `sync_state` и алерты.
      await this.registry
        .finish({
          runId,
          entity: payload.entity,
          status: 'failed',
          errorSummary: message,
          implemented: false,
          updateState: last,
        })
        .catch((err: unknown) => runLog.error({ err }, 'sync.run.finish_failed'));
      await writeSyncError(this.db, {
        entity: payload.entity,
        syncRunId: runId,
        errorCode: code,
        message,
        severity: 'error',
        payload: { jobId: job.id, attempt, ...(auth ? { authFailure: true } : {}) },
      }).catch((err: unknown) => runLog.error({ err }, 'sync.error.write_failed'));
      if (auth) {
        await this.authPause?.record(e, { entity: payload.entity });
        runLog.error({ err: e, attempt, code }, 'sync.job.auth_failed: 1С отклонила авторизацию — без повторов');
        return { status: 'failed', code: 'ONEC_AUTH_FAILED', runId };
      }
      if (last) {
        runLog.error(
          { err: e, attempt, retryLimit: job.retryLimit, code },
          'sync.job.dead_letter: попытки исчерпаны, job уходит в dead-letter',
        );
      } else {
        runLog.warn({ err: e, attempt, retryLimit: job.retryLimit, code }, 'sync.run.failed: будет повтор');
      }
      throw e;
    }
  }

  /**
   * Пауза чтения: плановый запуск пропускается без строки `sync_runs` (как `SYNC_ALREADY_RUNNING`); ручной прогон,
   * строку которого уже создал `POST /sync/runs`, завершается `failed` с причиной — без роста `consecutive_errors`.
   */
  private async skipPaused(
    payload: ReturnType<typeof parsePayload>,
    job: SyncJobMeta,
    until: Date,
    base: Record<string, unknown>,
  ): Promise<SyncJobOutcome> {
    this.log.warn(
      { ...base, until: until.toISOString() },
      'sync.job.auth_paused: чтение из 1С приостановлено (401/403)',
    );
    const runId = await this.failManualRun(
      payload,
      job,
      `Чтение из 1С приостановлено до ${until.toISOString()}: 1С отклонила авторизацию (401/403). ` +
        'Проверьте учётные данные интеграции (05 §6.5).',
    );
    return { status: 'skipped', code: 'ONEC_AUTH_PAUSED', until: until.toISOString(), ...(runId ? { runId } : {}) };
  }

  /** Пауза обмена по версии API (ONEC-095): как `skipPaused`, причина — `sync_state.paused_reason`. */
  private async skipApiPaused(
    payload: ReturnType<typeof parsePayload>,
    job: SyncJobMeta,
    reason: string,
    base: Record<string, unknown>,
  ): Promise<SyncJobOutcome> {
    this.log.warn({ ...base, reason }, 'sync.job.api_paused: обмен с 1С приостановлен (версия API расширения)');
    const runId = await this.failManualRun(payload, job, reason);
    return { status: 'skipped', code: 'ONEC_API_PAUSED', reason, ...(runId ? { runId } : {}) };
  }

  /**
   * Ручной прогон при паузе: строку, созданную `POST /sync/runs`, — в `failed` с причиной (без роста
   * `consecutive_errors`). Плановый запуск (нет `runId`) и занятый singleton — без строки (`undefined`).
   */
  private async failManualRun(
    payload: ReturnType<typeof parsePayload>,
    job: SyncJobMeta,
    summary: string,
  ): Promise<string | undefined> {
    if (!payload.runId) return undefined;
    let runId: string;
    try {
      runId = await this.registry.acquire({
        entity: payload.entity,
        mode: payload.mode,
        trigger: payload.trigger,
        jobId: job.id,
        runId: payload.runId,
        ...(payload.userId ? { userId: payload.userId } : {}),
      });
    } catch (e) {
      if (e instanceof SyncAlreadyRunningError) return undefined;
      throw e;
    }
    await this.registry.finish({
      runId,
      entity: payload.entity,
      status: 'failed',
      errorSummary: summary,
      implemented: false,
      updateState: false,
    });
    return runId;
  }
}

function parsePayload(raw: unknown): SyncJobPayload & { entity: SyncEntity; mode: SyncMode; trigger: SyncTrigger } {
  const p = (raw ?? {}) as Partial<Record<keyof SyncJobPayload, unknown>>;
  if (!isSyncEntity(p.entity)) throw new Error(`sync job: неизвестная сущность ${String(p.entity)}`);
  const mode = isSyncMode(p.mode) ? p.mode : 'incremental';
  const trigger = isSyncTrigger(p.trigger) ? p.trigger : 'schedule';
  return {
    entity: p.entity,
    mode,
    trigger,
    ...(typeof p.runId === 'string' ? { runId: p.runId } : {}),
    ...(typeof p.userId === 'string' ? { userId: p.userId } : {}),
    ...(typeof p.requestId === 'string' ? { requestId: p.requestId } : {}),
  };
}
