import type { OutboxConfig } from './scheduler.config.js';

/**
 * Политика повторов `onec_outbox` при временной ошибке (ядро §22.1; 07 §6.5, §8.2):
 * после n-й неудачной попытки (`attempts` = n, счётчик увеличен при захвате) — пауза
 * `backoffMs[n-1]` (1, 2, 5, 15, 60 мин), далее каждые `backoffTailMs` (60 мин);
 * `dead` — при `attempts ≥ OUTBOX_MAX_ATTEMPTS` или возрасте строки > `OUTBOX_MAX_AGE_HOURS`.
 */
export function outboxBackoffMs(attempts: number, cfg: Pick<OutboxConfig, 'backoffMs' | 'backoffTailMs'>): number {
  const n = Math.max(1, Math.floor(attempts));
  return cfg.backoffMs[n - 1] ?? cfg.backoffTailMs;
}

export type OutboxDeadReason = 'max_attempts' | 'max_age';

export function outboxDeadReason(
  attempts: number,
  ageMs: number,
  cfg: Pick<OutboxConfig, 'maxAttempts' | 'maxAgeMs'>,
): OutboxDeadReason | null {
  if (attempts >= cfg.maxAttempts) return 'max_attempts';
  if (ageMs > cfg.maxAgeMs) return 'max_age';
  return null;
}
