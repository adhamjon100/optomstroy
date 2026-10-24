import type pg from 'pg';
import type { SyncEntity, SyncMode, SyncRunStatus, SyncTrigger } from '../../common/enums.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';

/**
 * Singleton прогона на сущность (05 SYNC-023, AC-SYNC-023): «одна активная job на сущность» обеспечивает
 * частичный уникальный индекс `sync_runs_singleton_uq ON sync_runs (entity) WHERE status IN ('queued','running')`
 * (0001_init.sql, DATA-150). Вторая попытка получает `SYNC_ALREADY_RUNNING` (08 §2.4 → HTTP 409).
 * Блокировка живёт в PostgreSQL (D-44), поэтому действует между процессами api и worker.
 */
export class SyncAlreadyRunningError extends ProblemException {
  constructor(
    readonly entity: SyncEntity,
    readonly activeRunId: string | undefined,
  ) {
    super('SYNC_ALREADY_RUNNING', {
      status: 409,
      detail: `Синхронизация «${entity}» уже выполняется`,
      entity,
      ...(activeRunId ? { runId: activeRunId } : {}),
    });
    this.name = 'SyncAlreadyRunningError';
  }
}

export const SYNC_RUNS_SINGLETON_INDEX = 'sync_runs_singleton_uq';

type Queryable = Pick<pg.Pool, 'query'>;

export interface AcquireRequest {
  readonly entity: SyncEntity;
  readonly mode: SyncMode;
  readonly trigger: SyncTrigger;
  /** Строка, созданная при ручном запуске (`queued`); при повторе job строка может быть уже завершена. */
  readonly runId?: string;
  readonly userId?: string;
  readonly jobId?: string;
}

export interface FinishRequest {
  readonly runId: string;
  readonly entity: SyncEntity;
  readonly status: Extract<SyncRunStatus, 'success' | 'partial' | 'failed'>;
  readonly counts?: Readonly<Record<string, unknown>>;
  readonly errorSummary?: string;
  /**
   * `false` — прогон выполнила заглушка (этап C): `sync_state.last_success_*` не сдвигается, чтобы проба
   * свежести (`/health/ready`, NFR-SYNC-001) не считала данные свежими без реальной загрузки.
   */
  readonly implemented: boolean;
  /**
   * `false` — прогон не влияет на `sync_state` (сверка `$count` без загрузки данных, RM-E-002): строка `sync_runs`
   * завершается, а `consecutive_errors`/`last_success_*` сущности не меняются. По умолчанию `true`.
   */
  readonly updateState?: boolean;
}

/** Итог прогона после записи в `sync_state` (для алертов SYNC-038). */
export interface RunFinishedEvent {
  readonly runId: string;
  readonly entity: SyncEntity;
  readonly status: FinishRequest['status'];
  /** `sync_state.consecutive_errors` после записи (undefined — `updateState=false`). */
  readonly consecutiveErrors?: number;
}

/** Необязательные обработчики реестра (алерты `sync_error`, RM-E-002). Ошибка обработчика прогон не роняет. */
export interface SyncRunRegistryHooks {
  onFinished?(e: RunFinishedEvent): Promise<void>;
}

/** Значения по умолчанию для строки `sync_state` (NOT NULL), если её ещё нет. */
export interface SyncStateDefaults {
  (entity: SyncEntity): { readonly scheduleCron: string; readonly maxAgeWarningSec: number };
}

export function isSingletonViolation(e: unknown): boolean {
  const err = e as { code?: string; constraint?: string } | null;
  return err?.code === '23505' && err.constraint === SYNC_RUNS_SINGLETON_INDEX;
}

export class SyncRunRegistry {
  constructor(
    private readonly db: Queryable,
    private readonly staleRunSeconds: number,
    private readonly stateDefaults: SyncStateDefaults,
    private readonly hooks: SyncRunRegistryHooks = {},
  ) {}

  /** Ручной/внешний запуск: строка `queued` (сразу занимает singleton). Ошибка — `SyncAlreadyRunningError`. */
  async enqueue(req: Omit<AcquireRequest, 'runId' | 'jobId'>): Promise<string> {
    return this.insertWithStaleRecovery(req, 'queued');
  }

  /**
   * Начало прогона в worker: `queued → running` для строки ручного запуска либо новая строка `running`.
   * Ошибка — `SyncAlreadyRunningError` (идёт другой прогон той же сущности).
   */
  async acquire(req: AcquireRequest): Promise<string> {
    if (req.runId) {
      const r = await this.db.query<{ id: string }>(
        `UPDATE sync_runs SET status = 'running', started_at = now(), worker_job_id = $2, updated_at = now()
          WHERE id = $1 AND status = 'queued' RETURNING id`,
        [req.runId, req.jobId ?? null],
      );
      if (r.rows[0]) return r.rows[0].id;
      // Строка уже завершена (повтор job после ошибки) или снята как потерянная — новый прогон «retry».
      return this.insertWithStaleRecovery({ ...req, trigger: 'retry' }, 'running');
    }
    return this.insertWithStaleRecovery(req, 'running');
  }

  /** Отметка «жив» для долгих прогонов (обновляет `updated_at`, не даёт признать прогон потерянным). */
  async touch(runId: string, counts?: Readonly<Record<string, unknown>>): Promise<void> {
    await this.db.query(
      `UPDATE sync_runs SET updated_at = now(), counts = COALESCE($2::jsonb, counts) WHERE id = $1 AND status = 'running'`,
      [runId, counts ? JSON.stringify(counts) : null],
    );
  }

  async finish(req: FinishRequest): Promise<void> {
    await this.db.query(
      `UPDATE sync_runs
          SET status = $2::sync_run_status, finished_at = now(),
              duration_ms = LEAST(2147483647, GREATEST(0, (extract(epoch FROM now() - COALESCE(started_at, created_at)) * 1000)::bigint))::int,
              counts = $3::jsonb, error_summary = $4, updated_at = now()
        WHERE id = $1`,
      [req.runId, req.status, JSON.stringify(req.counts ?? {}), req.errorSummary?.slice(0, 2000) ?? null],
    );
    if (req.updateState === false) {
      await this.notify({ runId: req.runId, entity: req.entity, status: req.status });
      return;
    }
    const d = this.stateDefaults(req.entity);
    const success = req.status !== 'failed';
    const st = await this.db.query<{ consecutive_errors: number }>(
      `INSERT INTO sync_state AS s (entity, schedule_cron, max_age_warning_sec, last_run_id,
              last_success_run_id, last_success_at, consecutive_errors, last_error_at, last_error)
       VALUES ($1, $2, $3, $4,
              CASE WHEN $5 AND $6 THEN $4::uuid END, CASE WHEN $5 AND $6 THEN now() END,
              CASE WHEN $5 THEN 0 ELSE 1 END, CASE WHEN $5 THEN NULL ELSE now() END, CASE WHEN $5 THEN NULL ELSE $7 END)
       ON CONFLICT (entity) DO UPDATE SET
              last_run_id = EXCLUDED.last_run_id,
              last_success_run_id = CASE WHEN $5 AND $6 THEN EXCLUDED.last_run_id ELSE s.last_success_run_id END,
              last_success_at = CASE WHEN $5 AND $6 THEN now() ELSE s.last_success_at END,
              consecutive_errors = CASE WHEN $5 THEN 0 ELSE s.consecutive_errors + 1 END,
              last_error_at = CASE WHEN $5 THEN s.last_error_at ELSE now() END,
              last_error = CASE WHEN $5 THEN s.last_error ELSE $7 END,
              updated_at = now()
       RETURNING consecutive_errors`,
      [
        req.entity,
        d.scheduleCron,
        d.maxAgeWarningSec,
        req.runId,
        success,
        req.implemented,
        req.errorSummary?.slice(0, 2000) ?? null,
      ],
    );
    await this.notify({
      runId: req.runId,
      entity: req.entity,
      status: req.status,
      ...(st.rows[0] ? { consecutiveErrors: Number(st.rows[0].consecutive_errors) } : {}),
    });
  }

  private async notify(e: RunFinishedEvent): Promise<void> {
    if (!this.hooks.onFinished) return;
    try {
      await this.hooks.onFinished(e);
    } catch {
      // Алерт — побочный эффект: его сбой не меняет итог прогона (запись уже сделана).
    }
  }

  /** Снятие прогона, который так и не начался (job не поставлена): `failed` без учёта в `sync_state`. */
  async abandon(runId: string, reason: string): Promise<void> {
    await this.db.query(
      `UPDATE sync_runs SET status = 'failed', finished_at = now(), updated_at = now(), error_summary = $2
        WHERE id = $1 AND status IN ('queued','running')`,
      [runId, reason.slice(0, 2000)],
    );
  }

  /** Активный прогон сущности (для ответа `SYNC_ALREADY_RUNNING` и экрана SCR-43). */
  async active(entity: SyncEntity): Promise<{ id: string; status: SyncRunStatus } | undefined> {
    const r = await this.db.query<{ id: string; status: SyncRunStatus }>(
      `SELECT id, status FROM sync_runs WHERE entity = $1 AND status IN ('queued','running') LIMIT 1`,
      [entity],
    );
    return r.rows[0];
  }

  private async insertWithStaleRecovery(
    req: Omit<AcquireRequest, 'runId'>,
    status: 'queued' | 'running',
  ): Promise<string> {
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const r = await this.db.query<{ id: string }>(
          `INSERT INTO sync_runs (entity, mode, "trigger", triggered_by_user_id, status, started_at, worker_job_id)
           VALUES ($1, $2, $3, $4, $5::sync_run_status, CASE WHEN $5 = 'running' THEN now() END, $6)
           RETURNING id`,
          [req.entity, req.mode, req.trigger, req.userId ?? null, status, req.jobId ?? null],
        );
        const id = r.rows[0]?.id;
        if (!id) throw new Error('sync_runs: INSERT не вернул id');
        return id;
      } catch (e) {
        if (!isSingletonViolation(e)) throw e;
        if (attempt === 0 && (await this.releaseStale(req.entity))) continue;
        throw new SyncAlreadyRunningError(req.entity, (await this.active(req.entity))?.id);
      }
    }
    throw new SyncAlreadyRunningError(req.entity, undefined);
  }

  /** Прогон без обновления дольше `staleRunSeconds` (процесс worker упал) → `failed`, singleton освобождается. */
  private async releaseStale(entity: SyncEntity): Promise<boolean> {
    const r = await this.db.query(
      `UPDATE sync_runs SET status = 'failed', finished_at = now(), updated_at = now(),
              error_summary = 'прогон признан потерянным: нет обновлений дольше порога (worker остановлен?)'
        WHERE entity = $1 AND status IN ('queued','running') AND updated_at < now() - make_interval(secs => $2)`,
      [entity, this.staleRunSeconds],
    );
    return (r.rowCount ?? 0) > 0;
  }
}
