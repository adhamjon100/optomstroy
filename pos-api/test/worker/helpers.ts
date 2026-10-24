import { randomUUID } from 'node:crypto';
import { mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import pg from 'pg';
import pino, { type Logger } from 'pino';
import { buildPinoOptions } from '../../src/common/logging/logger.config.js';
import { outboxPayloadHash } from '../../src/sync/outbox/onec-outbox.writer.js';
import { LogCapture } from '../support/test-app.js';

export interface CapturedLogger {
  readonly log: Logger;
  readonly capture: LogCapture;
  /** Разобранные JSON-записи с указанным `msg`-префиксом. */
  entries(msgPrefix: string): Record<string, unknown>[];
}

/** pino worker'а (тот же формат, что в проде: buildPinoOptions(config, 'pos-worker')) с перехватом строк. */
export function capturedLogger(): CapturedLogger {
  const capture = new LogCapture();
  const log = pino(buildPinoOptions({ LOG_LEVEL: 'debug', APP_ENV: 'dev' }, 'pos-worker'), capture);
  return {
    log,
    capture,
    entries: (prefix) =>
      capture.lines
        .map((l) => JSON.parse(l) as Record<string, unknown>)
        .filter((e) => typeof e.msg === 'string' && e.msg.startsWith(prefix)),
  };
}

export async function waitFor<T>(
  probe: () => Promise<T | undefined | false>,
  { timeoutMs = 30_000, intervalMs = 100, what = 'условие' } = {},
): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const v = await probe();
    if (v !== undefined && v !== false) return v;
    if (Date.now() > deadline) throw new Error(`waitFor: не дождались — ${what}`);
    await new Promise((r) => setTimeout(r, intervalMs));
  }
}

export interface Deferred {
  readonly promise: Promise<void>;
  resolve(): void;
}

export function deferred(): Deferred {
  let resolve!: () => void;
  const promise = new Promise<void>((r) => (resolve = r));
  return { promise, resolve };
}

/** Вставка строки onec_outbox (агрегат — синтетический UUID; FK на агрегат в DDL нет). */
export async function insertOutbox(
  pool: pg.Pool,
  opts: {
    aggregateType?: string;
    payload?: object;
    createdAgoHours?: number;
    status?: string;
    leaseAgoSec?: number;
    attempts?: number;
    parked?: boolean;
  } = {},
): Promise<string> {
  const aggregateId = randomUUID();
  const r = await pool.query<{ id: string }>(
    `INSERT INTO onec_outbox (aggregate_type, aggregate_id, external_id, operation, payload, payload_hash, status,
            attempts, lease_until, locked_by, created_at, next_attempt_at)
     VALUES ($1::outbox_aggregate, $2::uuid, $2::text, 'create', $3::jsonb, $9::bytea, $4::outbox_status,
            $5, CASE WHEN $6::int IS NULL THEN NULL ELSE now() - make_interval(secs => $6::int) END,
            CASE WHEN $6::int IS NULL THEN NULL ELSE 'dead-worker' END,
            now() - make_interval(hours => $7::int), CASE WHEN $8::boolean THEN now() + interval '1 day' ELSE now() END)
     RETURNING id`,
    [
      opts.aggregateType ?? 'order',
      aggregateId,
      JSON.stringify(opts.payload ?? {}),
      opts.status ?? 'pending',
      opts.attempts ?? 0,
      opts.leaseAgoSec ?? null,
      opts.createdAgoHours ?? 0,
      opts.parked ?? false,
      // payload_hash — как OnecOutboxWriterService (SHA-256 канонического JSON): диспетчер сверяет его (DATA-228).
      outboxPayloadHash((opts.payload ?? {}) as Record<string, unknown>),
    ],
  );
  return r.rows[0].id;
}

/**
 * Уникальный каталог компиляции worker'а для одного прогона (ревью F, RR-5): `<root>/.dist-worker-entry-XXXXXX` — на
 * глубине `dist/` (пути к фикстурам и ресурсам вычисляются от него), поэтому одновременные прогоны `test:worker`
 * не перезаписывают и не удаляют каталог друг друга.
 */
export function makeWorkerCompileDir(root: string): string {
  return mkdtempSync(join(root, '.dist-worker-entry-'));
}
