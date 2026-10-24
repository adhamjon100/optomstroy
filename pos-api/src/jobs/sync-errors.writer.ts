import type pg from 'pg';
import type { SyncEntity } from '../common/enums.js';

/** Словарь `sync_errors.error_code` (07 §6.1.1, 15 кодов; CHECK — 0001_init.sql, `QR_PAID_AFTER_VOID` — 0013, ADR-103). */
export const SYNC_ERROR_CODES = [
  'NOT_FOUND_LOCAL',
  'BARCODE_CONFLICT',
  'VALIDATION',
  'ONEC_REJECTED',
  'ONEC_UNAVAILABLE',
  'IMAGE_DOWNLOAD',
  'HASH_MISMATCH',
  'COUNT_MISMATCH',
  'DUPLICATE_SUSPECTED',
  'OUTBOX_UNCONFIRMED',
  'PAYMENT_DOC_VOIDED',
  'ORDER_MATCH_AMBIGUOUS',
  'NO_WRITE_CHANNEL',
  'QR_PAID_AFTER_VOID',
  'OTHER',
] as const;
export type SyncErrorCode = (typeof SYNC_ERROR_CODES)[number];

export interface SyncErrorRecord {
  readonly entity: SyncEntity;
  readonly errorCode: SyncErrorCode;
  readonly message: string;
  readonly severity: 'warning' | 'error';
  readonly syncRunId?: string;
  readonly outboxId?: string;
  readonly payload?: Readonly<Record<string, unknown>>;
}

/** Запись `sync_errors` (DATA-152). Сообщение усекается; секретов и ПДн в нём быть не должно (SEC-061). */
export async function writeSyncError(
  db: Pick<pg.ClientBase, 'query'> | Pick<pg.Pool, 'query'>,
  rec: SyncErrorRecord,
): Promise<void> {
  await db.query(
    `INSERT INTO sync_errors (sync_run_id, outbox_id, entity, error_code, message, payload, severity)
     VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7)`,
    [
      rec.syncRunId ?? null,
      rec.outboxId ?? null,
      rec.entity,
      rec.errorCode,
      rec.message.slice(0, 2000),
      rec.payload ? JSON.stringify(rec.payload) : null,
      rec.severity,
    ],
  );
}
