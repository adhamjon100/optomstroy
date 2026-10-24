/**
 * Возраст последней успешной синхронизации для `/health/ready` (ядро R0 §16 п. 8; 08 §4.19.1 `checks.sync`).
 * ЗАГЛУШКА RM-C-005: реальная проба (по `sync_state`/`sync_runs`, порог — RM-C-007/RM-E-*) подменяет провайдер
 * токена SYNC_FRESHNESS_PROBE. Пока синхронизации нет, проба сообщает `stale: false` и `implemented: false`
 * (поле `implemented` в ответ API не выводится).
 */
export const SYNC_FRESHNESS_PROBE = Symbol('SYNC_FRESHNESS_PROBE');

export interface SyncFreshness {
  readonly stockAgeSec?: number;
  readonly stale: boolean;
  readonly implemented: boolean;
}

export interface SyncFreshnessProbe {
  check(): Promise<SyncFreshness>;
}

export class StubSyncFreshnessProbe implements SyncFreshnessProbe {
  check(): Promise<SyncFreshness> {
    return Promise.resolve({ stale: false, implemented: false });
  }
}
