import type pg from 'pg';
import { RECEIVABLES_CLOCK_SKEW_MS } from '../../common/ports/receivables-snapshot.port.js';
import type { ParsedReceivables } from './onec-receivables.parser.js';

/** Соединение pg (клиент пула или клиент транзакции). */
export type PgQueryable = Pick<pg.ClientBase, 'query'>;

export interface SnapshotWriteResult {
  /** `false` — в БД уже снимок новее (`onec_snapshot_at` больше): ничего не изменено. */
  readonly applied: boolean;
}

/**
 * Запись снимка долга клиента (07 §5.31–§5.32; 05 SYNC-016, SYNC-073) **в текущей транзакции** `client`
 * (транзакцию открывает вызывающий). Снимок заменяется целиком:
 *
 * - `receivables` — upsert; снимок не «откатывается» назад: строка с более новым `onec_snapshot_at` (например,
 *   записанная параллельным прогоном синхронизации) не перезаписывается;
 * - `receivable_documents` — строки снимка upsert по `(customer_id, onec_ref)` с `superseded_at = NULL`; строки,
 *   которых в снимке нет, получают `superseded_at` (DELETE для `pos_app` запрещён — 06 EVO-007); `order_id` —
 *   заказ POS, чей документ 1С (`orders.onec_ref`) или реализация (`shipments.order_id`) указан в строке;
 * - условия соглашения из ответа 1С (`credit_allowed`, `credit_limit`, `credit_days` клиента — ONEC-047) —
 *   только при изменении, с `row_version + 1` (07 §8.3).
 */
export async function writeReceivablesSnapshot(
  client: PgQueryable,
  customerId: string,
  s: ParsedReceivables,
): Promise<SnapshotWriteResult> {
  const up = await client.query<{ customer_id: string }>(
    `INSERT INTO receivables (customer_id, balance, overdue_amount, overdue_days, oldest_due_date, onec_snapshot_at,
                              synced_at, source_hash)
     VALUES ($1::uuid, $2::numeric, $3::numeric, $4, $5::date, $6::timestamptz, now(), $7)
     ON CONFLICT (customer_id) DO UPDATE
        SET balance = EXCLUDED.balance, overdue_amount = EXCLUDED.overdue_amount,
            overdue_days = EXCLUDED.overdue_days, oldest_due_date = EXCLUDED.oldest_due_date,
            onec_snapshot_at = EXCLUDED.onec_snapshot_at, synced_at = now(), source_hash = EXCLUDED.source_hash,
            updated_at = now()
      WHERE receivables.onec_snapshot_at <= EXCLUDED.onec_snapshot_at
         -- Снимок «из будущего» (сбой часов 1С) не блокирует новые снимки (ревью G-credit-2).
         OR receivables.onec_snapshot_at > now() + make_interval(secs => $8::double precision)
     RETURNING customer_id`,
    [
      customerId,
      s.balance,
      s.overdueAmount,
      s.overdueDays,
      s.oldestDueDate,
      s.snapshotAt.toISOString(),
      s.sourceHash,
      RECEIVABLES_CLOCK_SKEW_MS / 1000,
    ],
  );
  if (up.rows.length === 0) return { applied: false };

  const refs = s.documents.map((d) => d.onecRef);
  await client.query(
    `UPDATE receivable_documents SET superseded_at = now(), updated_at = now()
      WHERE customer_id = $1::uuid AND superseded_at IS NULL AND NOT (onec_ref = ANY($2::uuid[]))`,
    [customerId, refs],
  );
  for (const d of s.documents) {
    await client.query(
      `INSERT INTO receivable_documents (customer_id, onec_ref, doc_type, kind, status, doc_number, doc_date, amount,
                                         paid, remaining, due_date, overdue_days, order_id, onec_snapshot_at,
                                         superseded_at, synced_at, source_hash)
       VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6, $7::date, $8::numeric, $9::numeric, $10::numeric, $11::date, $12,
               coalesce((SELECT o.id FROM orders o WHERE o.onec_ref = $2::uuid LIMIT 1),
                        (SELECT sh.order_id FROM shipments sh WHERE sh.onec_ref = $2::uuid LIMIT 1)),
               $13::timestamptz, NULL, now(), $14)
       ON CONFLICT (customer_id, onec_ref) DO UPDATE
          SET doc_type = EXCLUDED.doc_type, kind = EXCLUDED.kind, status = EXCLUDED.status,
              doc_number = EXCLUDED.doc_number, doc_date = EXCLUDED.doc_date, amount = EXCLUDED.amount,
              paid = EXCLUDED.paid, remaining = EXCLUDED.remaining, due_date = EXCLUDED.due_date,
              overdue_days = EXCLUDED.overdue_days, order_id = coalesce(EXCLUDED.order_id, receivable_documents.order_id),
              onec_snapshot_at = EXCLUDED.onec_snapshot_at, superseded_at = NULL, synced_at = now(),
              source_hash = EXCLUDED.source_hash, updated_at = now()`,
      [
        customerId,
        d.onecRef,
        d.docType,
        d.kind,
        d.status,
        d.number,
        d.date,
        d.amount,
        d.paid,
        d.remaining,
        d.dueDate,
        d.overdueDays,
        s.snapshotAt.toISOString(),
        s.sourceHash,
      ],
    );
  }
  await client.query(
    `UPDATE customers
        SET credit_allowed = $2, credit_limit = $3::numeric, credit_days = $4, row_version = row_version + 1,
            updated_at = now()
      WHERE id = $1::uuid
        AND (credit_allowed, credit_limit, credit_days) IS DISTINCT FROM ($2::boolean, $3::numeric, $4::smallint)`,
    [customerId, s.creditAllowed, s.creditLimit, s.creditDays],
  );
  return { applied: true };
}

/**
 * Транзакция записи снимка на отдельном соединении пула (вне транзакции вызывающего, 07 §8): `app.system` —
 * для триггеров аудита/версий уровня БД (изменение условий клиента записывается как системное).
 */
export async function writeReceivablesSnapshotTx(
  pool: Pick<pg.Pool, 'connect'>,
  customerId: string,
  s: ParsedReceivables,
  system = 'receivables',
): Promise<SnapshotWriteResult> {
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    await c.query(`SELECT set_config('app.system', $1, true)`, [system]);
    const r = await writeReceivablesSnapshot(c, customerId, s);
    await c.query('COMMIT');
    return r;
  } catch (e) {
    await c.query('ROLLBACK').catch(() => undefined);
    throw e;
  } finally {
    c.release();
  }
}
