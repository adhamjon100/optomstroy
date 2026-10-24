import type pg from 'pg';
import type { SyncEntity } from '../../common/enums.js';
import { writeSyncError } from '../../jobs/sync-errors.writer.js';
import { SyncRunRegistry, type SyncStateDefaults } from '../scheduler/sync-run.registry.js';
import type { ApplyRunTracker } from './apply.types.js';

/** Значения `sync_state` по умолчанию, если строки ещё нет (seed этапа C задаёт их из env). */
export const DEFAULT_STATE_DEFAULTS: SyncStateDefaults = (_entity: SyncEntity) => ({
  scheduleCron: '*/30 * * * *',
  maxAgeWarningSec: 3600,
});

/**
 * `ApplyRunTracker` поверх `SyncRunRegistry` (singleton прогона на сущность — `sync_runs_singleton_uq`,
 * SYNC-023; итог и `sync_state` — `finish`). Дополнительно пишет `cursor_from/cursor_to` (номер сообщения
 * плана обмена или `$skip` полной загрузки), `onec_endpoint` и `sync_state.last_cursor` (05 SYNC-037).
 * Занятый singleton → `SyncAlreadyRunningError` (409 `SYNC_ALREADY_RUNNING`).
 */
export class RegistryRunTracker implements ApplyRunTracker {
  constructor(
    private readonly registry: SyncRunRegistry,
    private readonly db: Pick<pg.Pool, 'query'>,
  ) {}

  async start(req: Parameters<ApplyRunTracker['start']>[0]): Promise<string> {
    const id = await this.registry.acquire({ entity: req.entity, mode: req.mode, trigger: req.trigger });
    if (req.cursorFrom !== undefined || req.endpoint !== undefined) {
      await this.db.query(`UPDATE sync_runs SET cursor_from = $2, onec_endpoint = $3 WHERE id = $1`, [
        id,
        req.cursorFrom ?? null,
        req.endpoint ?? null,
      ]);
    }
    return id;
  }

  async finish(req: Parameters<ApplyRunTracker['finish']>[0]): Promise<void> {
    if (req.cursorTo !== undefined) {
      await this.db.query(`UPDATE sync_runs SET cursor_to = $2 WHERE id = $1`, [req.runId, req.cursorTo]);
    }
    await this.registry.finish({
      runId: req.runId,
      entity: req.entity,
      status: req.status,
      counts: req.counts,
      ...(req.errorSummary !== undefined ? { errorSummary: req.errorSummary } : {}),
      implemented: true,
    });
    if (req.cursorTo !== undefined && req.status !== 'failed') {
      await this.db.query(`UPDATE sync_state SET last_cursor = $2 WHERE entity = $1`, [req.entity, req.cursorTo]);
    }
    if (req.status === 'failed' && req.errorCode !== undefined) {
      await writeSyncError(this.db, {
        entity: req.entity,
        syncRunId: req.runId,
        errorCode: req.errorCode,
        message: req.errorSummary ?? 'прогон завершился ошибкой',
        severity: 'error',
      });
    }
  }
}

/** Трекер по пулу (для CLI, тестов и сервисов без планировщика). */
export function createRunTracker(
  pool: Pick<pg.Pool, 'query'>,
  options: { staleRunSeconds?: number; stateDefaults?: SyncStateDefaults } = {},
): RegistryRunTracker {
  return new RegistryRunTracker(
    new SyncRunRegistry(pool, options.staleRunSeconds ?? 900, options.stateDefaults ?? DEFAULT_STATE_DEFAULTS),
    pool,
  );
}
