import type { Logger } from 'pino';

/**
 * Заглушки периодических задач этапа C (только журнал). Реальная логика:
 * `onec.changes` — RM-E-001/RM-E-002 (05 SYNC-011, ack после полного применения, `sync_node_state`);
 * `sync.count_check` — RM-E-002 (сверка `$count`, `partial` + `COUNT_MISMATCH`, 07 §8.4);
 * `sync.post_vacuum` — RM-E-005 (`VACUUM (ANALYZE)` таблиц поиска, 07 §10.5);
 * `outbox.reconcile-aggregates` — этап F (07 §8.2: повторная публикация `*.onec-confirmed|failed`).
 */
export function stubJob(log: Logger, queue: string, stage: string): (data: unknown, jobId: string) => Promise<void> {
  return (data, jobId) => {
    log.info({ queue, jobId, data }, `job.stub: ${queue} — заглушка (реализация — ${stage})`);
    return Promise.resolve();
  };
}
