/**
 * Счётчики прогона для `sync_runs.counts` (05 SYNC-037: `fetched, inserted, updated, marked_deleted, skipped,
 * errors, source_total, local_total`): из `EntityCounts` конвейера apply — без разбивки по таблицам на верхнем
 * уровне (разбивка — в `tables`).
 */
export function runCounts(c: unknown): Record<string, unknown> {
  if (!c || typeof c !== 'object') return {};
  const src = c as Record<string, unknown>;
  const out: Record<string, unknown> = {};
  for (const k of [
    'fetched',
    'inserted',
    'updated',
    'skipped',
    'markedDeleted',
    'errors',
    'sourceTotal',
    'localTotal',
    'tables',
  ]) {
    if (src[k] !== undefined) out[k] = src[k];
  }
  return out;
}
