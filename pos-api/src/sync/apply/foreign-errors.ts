import type pg from 'pg';
import type { SyncEntity } from '../../common/enums.js';
import type { SyncErrorCode } from '../../jobs/sync-errors.writer.js';

/** Ошибка позиции элемента `/changes`, который применяет модуль-владелец (без прогона `sync_runs`). */
export interface ForeignItemError {
  readonly entity: SyncEntity;
  readonly errorCode: SyncErrorCode;
  readonly severity: 'warning' | 'error';
  readonly message: string;
  readonly onecRef?: string | null;
  readonly localId?: string | null;
  readonly payload?: Readonly<Record<string, unknown>>;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** GUID контракта (нижний регистр) или `null`. */
export function uuidOrNull(v: unknown): string | null {
  return typeof v === 'string' && UUID_RE.test(v) ? v : null;
}

/**
 * Запись `sync_errors` в транзакции сообщения **без** `sync_run_id` (как ошибки файлов картинок, 05 §6.2
 * уточнение п. 4): прогон сущности-владельца (`order_status`, `payment_docs`) может быть занят собственным опросом, и
 * его захват в транзакции сообщения откатывал бы всё сообщение (SYNC-023). Без ПДн (05 SYNC-039).
 */
export async function writeForeignErrors(client: pg.PoolClient, errors: readonly ForeignItemError[]): Promise<void> {
  if (errors.length === 0) return;
  await client.query(
    `INSERT INTO sync_errors (sync_run_id, entity, onec_ref, local_id, error_code, message, payload, severity)
     SELECT NULL, x.entity, x.onec_ref, x.local_id, x.error_code, x.message, x.payload, x.severity
       FROM jsonb_to_recordset($1::jsonb) AS x(entity sync_entity, onec_ref uuid, local_id uuid, error_code text,
            message text, payload jsonb, severity text)`,
    [
      JSON.stringify(
        errors.slice(0, 1000).map((e) => ({
          entity: e.entity,
          onec_ref: uuidOrNull(e.onecRef),
          local_id: uuidOrNull(e.localId),
          error_code: e.errorCode,
          message: e.message.slice(0, 2000),
          payload: e.payload ?? null,
          severity: e.severity,
        })),
      ),
    ],
  );
}
