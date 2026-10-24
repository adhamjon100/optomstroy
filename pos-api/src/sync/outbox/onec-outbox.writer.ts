import { createHash } from 'node:crypto';
import { Injectable, Logger, Optional } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { OutboxAggregate, OutboxStatus } from '../../common/enums.js';
import { canonicalJson } from '../../common/idempotency/fingerprint.js';
import { QUEUES } from '../../common/jobs/contracts/queues.js';
import { PgBossService } from '../../common/jobs/pg-boss.service.js';
import type { OnecOutboxWriter, OutboxEnqueueInput, OutboxItemView, SalesTx } from '../../common/ports/index.js';
import { assertOutboxTransition } from '../../sales-domain/outbox/outbox-status.js';

/** Приоритеты захвата (07 §8.2: `customer (10)` → `order (50)` → `payment (100)`). */
export const OUTBOX_PRIORITY: Readonly<Record<OutboxAggregate, number>> = {
  customer: 10,
  order: 50,
  payment: 100,
  return_request: 100,
};

interface OutboxRowDb extends Record<string, unknown> {
  id: string;
  status: OutboxStatus;
  attempts: number;
  onec_ref: string | null;
}

function toView(r: OutboxRowDb): OutboxItemView {
  return { outboxId: r.id, status: r.status, attempts: Number(r.attempts), onecRef: r.onec_ref };
}

/** SHA-256 канонического JSON тела (`onec_outbox.payload_hash`, 07 §5.55). */
export function outboxPayloadHash(payload: Readonly<Record<string, unknown>>): Buffer {
  return createHash('sha256').update(canonicalJson(payload), 'utf8').digest();
}

/**
 * `OnecOutboxWriter` (06 §7.4 `OutboxService.enqueue`; 07 §5.55, §6.5, §8.2; ядро §22.1, §23 п. 1): запись задачи
 * 1С **в транзакции агрегата**, переходы — только по автомату `sales-domain/outbox/outbox-status.ts`. `external_id` =
 * UUID агрегата (CHECK `onec_outbox_external_is_aggregate_chk`), повтор пары (агрегат, операция) возвращает
 * существующую строку. Пробуждение диспетчера — `outbox.dispatch` после COMMIT (без ожидания тикера).
 */
@Injectable()
export class OnecOutboxWriterService implements OnecOutboxWriter {
  private readonly logger = new Logger('outbox.writer');

  constructor(@Optional() private readonly boss?: PgBossService) {}

  async enqueue(tx: SalesTx, input: OutboxEnqueueInput): Promise<OutboxItemView> {
    const payloadJson = JSON.stringify(input.payload);
    const hash = outboxPayloadHash(input.payload);
    const priority = input.priority ?? OUTBOX_PRIORITY[input.aggregateType];
    const ins = await tx.execute<OutboxRowDb>(sql`
      INSERT INTO onec_outbox (aggregate_type, aggregate_id, external_id, operation, payload, payload_hash, status,
                               next_attempt_at, depends_on_outbox_id, priority, requested_by_user_id, warehouse_id)
      VALUES (${input.aggregateType}::outbox_aggregate, ${input.aggregateId}::uuid, ${input.aggregateId}::text,
              ${input.operation}, ${payloadJson}::jsonb, ${hash}, 'pending', now(),
              ${input.dependsOnOutboxId ?? null}::uuid, ${priority}, ${input.requestedByUserId ?? null}::uuid,
              ${input.warehouseId ?? null}::uuid)
      ON CONFLICT (aggregate_type, aggregate_id, operation) DO NOTHING
      RETURNING id, status::text AS status, attempts, onec_ref::text AS onec_ref`);
    if (ins.rows[0]) return toView(ins.rows[0]);
    const existing = await this.lock(tx, input);
    if (!existing) throw new Error(`onec_outbox: строка ${input.aggregateType}/${input.operation} не найдена`);
    return existing;
  }

  async lock(
    tx: SalesTx,
    key: {
      readonly aggregateType: OutboxAggregate;
      readonly aggregateId: string;
      readonly operation: 'create' | 'cancel';
    },
  ): Promise<OutboxItemView | null> {
    const r = await tx.execute<OutboxRowDb>(sql`
      SELECT id, status::text AS status, attempts, onec_ref::text AS onec_ref FROM onec_outbox
       WHERE aggregate_type = ${key.aggregateType}::outbox_aggregate AND aggregate_id = ${key.aggregateId}::uuid
         AND operation = ${key.operation}
       FOR UPDATE`);
    return r.rows[0] ? toView(r.rows[0]) : null;
  }

  async cancel(tx: SalesTx, outboxId: string): Promise<void> {
    const cur = await this.lockById(tx, outboxId);
    assertOutboxTransition(cur.status, 'cancelled', 'aggregate_cancelled');
    await tx.execute(sql`
      UPDATE onec_outbox SET status = 'cancelled', cancelled_at = now(), next_attempt_at = NULL, lease_until = NULL,
             locked_by = NULL, updated_at = now()
       WHERE id = ${outboxId}::uuid`);
  }

  async requeue(
    tx: SalesTx,
    input: {
      readonly outboxId: string;
      readonly payload?: Readonly<Record<string, unknown>>;
      readonly requestedByUserId?: string | null;
    },
  ): Promise<OutboxItemView> {
    const cur = await this.lockById(tx, input.outboxId);
    assertOutboxTransition(cur.status, 'pending', 'manual_retry');
    const payloadJson = input.payload ? JSON.stringify(input.payload) : null;
    const hash = input.payload ? outboxPayloadHash(input.payload) : null;
    const r = await tx.execute<OutboxRowDb>(sql`
      UPDATE onec_outbox SET status = 'pending', attempts = 0, next_attempt_at = now(), lease_until = NULL,
             locked_by = NULL, dead_at = NULL,
             payload = COALESCE(${payloadJson}::jsonb, payload), payload_hash = COALESCE(${hash}, payload_hash),
             requested_by_user_id = COALESCE(${input.requestedByUserId ?? null}::uuid, requested_by_user_id),
             updated_at = now()
       WHERE id = ${input.outboxId}::uuid
      RETURNING id, status::text AS status, attempts, onec_ref::text AS onec_ref`);
    return toView(r.rows[0]);
  }

  async markSentManually(
    tx: SalesTx,
    input: { readonly outboxId: string; readonly onecRef: string; readonly onecNumber?: string | null },
  ): Promise<void> {
    const cur = await this.lockById(tx, input.outboxId);
    assertOutboxTransition(cur.status, 'sent', 'manual_link');
    await tx.execute(sql`
      UPDATE onec_outbox SET status = 'sent', onec_ref = ${input.onecRef}::uuid, sent_at = now(), dead_at = NULL,
             lease_until = NULL, locked_by = NULL, last_error = NULL, last_error_code = NULL,
             onec_response = jsonb_build_object('manualLink', true, 'number', ${input.onecNumber ?? null}::text),
             updated_at = now()
       WHERE id = ${input.outboxId}::uuid`);
  }

  async kickAfterCommit(): Promise<void> {
    const instance = this.boss?.instance;
    if (!instance) return;
    try {
      await instance.send(QUEUES.outboxDispatch, {});
    } catch (err) {
      // Не критично: тикер воркера подберёт строку (07 §8.2).
      this.logger.warn({ err }, 'outbox.kick_failed');
    }
  }

  private async lockById(tx: SalesTx, outboxId: string): Promise<OutboxItemView> {
    const r = await tx.execute<OutboxRowDb>(sql`
      SELECT id, status::text AS status, attempts, onec_ref::text AS onec_ref FROM onec_outbox
       WHERE id = ${outboxId}::uuid FOR UPDATE`);
    if (!r.rows[0]) throw new Error(`onec_outbox ${outboxId} не найден`);
    return toView(r.rows[0]);
  }
}
