import { sql } from 'drizzle-orm';
import { applyAuditGucs, systemActor } from '../../common/audit/audit-context.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import type { OnecConfirmedPayload, OnecFailedPayload } from '../../common/jobs/contracts/queues.js';
import type { PosDatabase } from '../../db/database.js';
import { UNREFERENCED_STUB_GUARD } from '../../sync/customers/customer-stub.js';

export type CustomerResultOutcome = 'applied' | 'skipped';

/** Журнал (pino-совместимый). */
export interface CustomerResultsLog {
  info(obj: object, msg?: string): void;
  warn(obj: object, msg?: string): void;
}

interface OutboxRowDb extends Record<string, unknown> {
  aggregate_type: string;
  aggregate_id: string;
  operation: string;
  status: string;
  onec_ref: string | null;
  onec_response: Record<string, unknown> | null;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function str(v: unknown): string | null {
  return typeof v === 'string' && v.trim() !== '' ? v.trim() : null;
}

/**
 * Обработчики событий результата outbox для агрегата `customer` (06 §7.4 п. (б); 07 §8.2, §5.28 «писатели столбцов»;
 * 10 CUST-014, CUST-015; 05 SYNC-049) — отдельная транзакция на событие, идемпотентно по `outboxId`:
 * - `customers.onec-confirmed`: 1С создала (201) или вернула существующую по `externalId` (200) карточку →
 *   `customers.onec_ref` (Ref партнёра), `onec_code`, `onec_counterparty_ref`, `onec_status = confirmed`; остальные
 *   поля карточки перезапишет синхронизация `customers` (элемент партнёра с `externalId`). Если ссылка уже занята
 *   другой строкой реплики — карточка POS помечается `duplicate` (слияние строк в R1 не выполняется, GQ-CUS-02);
 * - `customers.onec-failed`: `409 POS_E_DUPLICATE` (1С нашла другого клиента с этим телефоном) → `onec_status =
 *   duplicate` (кассир выбирает существующего клиента, SYNC-049); иной отказ данных → `rejected`.
 * Обработчик не меняет статус строки outbox (`sent → confirmed` — по синхронизации, 07 §6.5 `confirmed_by_sync`).
 */
export class CustomerOnecResultsHandler {
  constructor(
    private readonly db: PosDatabase,
    private readonly log: CustomerResultsLog,
  ) {}

  async onConfirmed(p: OnecConfirmedPayload): Promise<CustomerResultOutcome> {
    return this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, systemActor('outbox'));
      const ob = await this.outbox(tx, p.outboxId);
      if (!ob || ob.aggregate_type !== 'customer' || ob.operation !== 'create') return 'skipped';
      if (ob.status !== 'sent' && ob.status !== 'confirmed') return 'skipped';
      const body = ob.onec_response ?? {};
      const ref = str(body.ref) ?? p.onecRef;
      if (!ref || !UUID_RE.test(ref)) return 'skipped';
      const cur = await tx.execute<{ id: string; onec_ref: string | null; onec_status: string }>(sql`
        SELECT id, onec_ref::text AS onec_ref, onec_status::text AS onec_status FROM customers
         WHERE id = ${ob.aggregate_id}::uuid FOR UPDATE`);
      const row = cur.rows[0];
      if (!row) return 'skipped';
      if (row.onec_ref !== null) return 'skipped';
      const taken = await tx.execute<{ id: string }>(
        sql`SELECT id FROM customers WHERE onec_ref = ${ref.toLowerCase()}::uuid AND id <> ${row.id}::uuid`,
      );
      if (taken.rows[0]) {
        // Ref занят строкой-заглушкой поиска дубля по телефону (окно «доставлено, результат не обработан»): это та же
        // карточка 1С — заглушка удаляется, Ref получает POS-клиент (05 SYNC-005; ревью G-customers-1c-2).
        const del = await tx.execute<{ id: string }>(
          sql`DELETE FROM customers s WHERE s.id = ${taken.rows[0].id}::uuid ${sql.raw(UNREFERENCED_STUB_GUARD)}
              RETURNING s.id`,
        );
        if (del.rows[0]) taken.rows.length = 0;
      }
      if (taken.rows[0]) {
        await tx.execute(
          sql`UPDATE customers SET onec_status = 'duplicate', updated_at = now() WHERE id = ${row.id}::uuid`,
        );
        this.log.warn(
          { event: 'customers.onec_confirmed.ref_taken', customerId: row.id, otherId: taken.rows[0].id },
          'ссылка 1С уже принадлежит другой карточке реплики — POS-клиент помечен duplicate',
        );
        return 'applied';
      }
      const code = str(body.code);
      const codeFree =
        code === null
          ? false
          : !(await tx.execute<{ id: string }>(sql`SELECT id FROM customers WHERE onec_code = ${code}`)).rows[0];
      const contractor = str(body.contractorRef);
      await tx.execute(sql`
        UPDATE customers
           SET onec_ref = ${ref.toLowerCase()}::uuid,
               onec_code = coalesce(${codeFree ? code : null}, onec_code),
               onec_counterparty_ref = coalesce(${contractor && UUID_RE.test(contractor) ? contractor.toLowerCase() : null}::uuid,
                                                onec_counterparty_ref),
               onec_status = 'confirmed', updated_at = now()
         WHERE id = ${row.id}::uuid`);
      this.log.info({ event: 'customers.onec_confirmed', customerId: row.id }, 'клиент POS подтверждён 1С');
      return 'applied';
    });
  }

  async onFailed(p: OnecFailedPayload): Promise<CustomerResultOutcome> {
    return this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, systemActor('outbox'));
      const ob = await this.outbox(tx, p.outboxId);
      if (!ob || ob.aggregate_type !== 'customer' || ob.operation !== 'create' || ob.status !== 'failed') {
        return 'skipped';
      }
      const code = str((ob.onec_response ?? {}).code);
      const status = code === 'POS_E_DUPLICATE' ? 'duplicate' : 'rejected';
      const r = await tx.execute(sql`
        UPDATE customers SET onec_status = ${status}::customer_onec_status, updated_at = now()
         WHERE id = ${ob.aggregate_id}::uuid AND onec_ref IS NULL AND onec_status = 'pending'`);
      this.log.warn(
        { event: 'customers.onec_failed', customerId: ob.aggregate_id, onecCode: code, status },
        '1С отклонила создание клиента',
      );
      return (r.rowCount ?? 0) > 0 ? 'applied' : 'skipped';
    });
  }

  /**
   * Сверщик потерянных результатов (07 §8.2 `outbox.reconcile-aggregates`, часть агрегата `customer`): строки outbox
   * `sent|confirmed` без `onec_ref` у клиента и `failed` с клиентом в `pending` — повторное применение.
   */
  async reconcile(): Promise<{ confirmed: number; failed: number }> {
    const rows = await this.db.execute<{
      id: string;
      status: string;
      aggregate_id: string;
      onec_ref: string | null;
    }>(sql`
      SELECT x.id, x.status::text AS status, x.aggregate_id, x.onec_ref::text AS onec_ref
        FROM onec_outbox x JOIN customers c ON c.id = x.aggregate_id
       WHERE x.aggregate_type = 'customer' AND x.operation = 'create' AND c.onec_status = 'pending'
         AND ((x.status IN ('sent','confirmed') AND c.onec_ref IS NULL) OR x.status = 'failed')
       ORDER BY x.updated_at LIMIT 200`);
    let confirmed = 0;
    let failed = 0;
    for (const r of rows.rows) {
      if (r.status === 'failed') {
        if (
          (await this.onFailed({
            outboxId: r.id,
            aggregateId: r.aggregate_id,
            errorCode: 'ONEC_REJECTED',
            attempt: 0,
          })) === 'applied'
        )
          failed += 1;
      } else if (r.onec_ref) {
        const out = await this.onConfirmed({
          outboxId: r.id,
          aggregateId: r.aggregate_id,
          onecRef: r.onec_ref,
          onecNumber: null,
          onecStatus: null,
          attempt: 0,
        });
        if (out === 'applied') confirmed += 1;
      }
    }
    return { confirmed, failed };
  }

  private async outbox(tx: DbExecutor, id: string): Promise<OutboxRowDb | undefined> {
    const r = await tx.execute<OutboxRowDb>(sql`
      SELECT aggregate_type::text AS aggregate_type, aggregate_id::text AS aggregate_id, operation, status::text AS status,
             onec_ref::text AS onec_ref, onec_response
        FROM onec_outbox WHERE id = ${id}::uuid`);
    return r.rows[0];
  }
}
