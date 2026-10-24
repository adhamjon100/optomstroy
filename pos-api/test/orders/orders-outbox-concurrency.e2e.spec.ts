import { randomUUID } from 'node:crypto';
import pino from 'pino';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type {
  OutboxDeliveryPort,
  OutboxDeliveryResult,
  OutboxRow,
} from '../../src/jobs/outbox/outbox-delivery.port.js';
import { OutboxDispatcher } from '../../src/jobs/outbox/outbox-dispatcher.js';
import { OrdersModule } from '../../src/orders/orders.module.js';
import { schedulerConfigFromEnv } from '../../src/sync/scheduler/scheduler.config.js';
import { OrdersTestApp } from './support/orders-fixture.js';

/** Доставка-заглушка: журнал (кто, когда начал/закончил), небольшая задержка — чтобы воркеры перекрывались. */
class RecordingDelivery implements OutboxDeliveryPort {
  readonly configured = true;
  readonly log: { externalId: string; aggregateType: string; startedAt: number; finishedAt: number }[] = [];
  private seq = 0;

  async deliver(row: OutboxRow): Promise<OutboxDeliveryResult> {
    const startedAt = ++this.seq;
    await new Promise((r) => setTimeout(r, 5));
    this.log.push({ externalId: row.externalId, aggregateType: row.aggregateType, startedAt, finishedAt: ++this.seq });
    return { kind: 'sent', onecRef: randomUUID() };
  }
}

/**
 * 12 T-SYNC-032 (P1, этап F; ревью F-trace-9): два воркера outbox на одной БД (`FOR UPDATE SKIP LOCKED`) — 50
 * сообщений, каждое отправлено ровно одним воркером ровно один раз, за цикл захватывается не больше
 * `OUTBOX_BATCH_SIZE` (20), `depends_on` соблюдён: заказ уходит только после доставки клиента (05 SYNC-042) —
 * **тестовые данные** (embedded PostgreSQL 17).
 */
describe('outbox: два воркера, SKIP LOCKED и depends_on (T-SYNC-032)', () => {
  const t = new OrdersTestApp();

  beforeAll(async () => {
    await t.start({ modules: [OrdersModule], fakePorts: true, jobs: false });
  });
  afterAll(async () => {
    await t.stop();
  });

  it('50 сообщений: каждое — одним воркером один раз; ≤ 20 за цикл; заказ — после своего клиента', async () => {
    const pairs: { customer: string; order: string }[] = [];
    for (let i = 0; i < 25; i++) {
      const customer = randomUUID();
      const order = randomUUID();
      const c = await t.q<{ id: string }>(
        `INSERT INTO onec_outbox (aggregate_type, aggregate_id, external_id, operation, payload, payload_hash, status,
                                  next_attempt_at, priority)
         VALUES ('customer', $1::uuid, $1::text, 'create', '{}'::jsonb, sha256('{}'::bytea), 'pending', now(), 10) RETURNING id`,
        [customer],
      );
      await t.q(
        `INSERT INTO onec_outbox (aggregate_type, aggregate_id, external_id, operation, payload, payload_hash, status,
                                  next_attempt_at, depends_on_outbox_id, priority)
         VALUES ('order', $1::uuid, $1::text, 'create', '{}'::jsonb, sha256('{}'::bytea), 'pending', now(), $2::uuid, 0)`,
        [order, c[0].id],
      );
      pairs.push({ customer, order });
    }
    const cfg = schedulerConfigFromEnv(t.config).outbox;
    expect(cfg.batchSize).toBe(20);
    const delivery = new RecordingDelivery();
    const publisher = { send: () => Promise.resolve(randomUUID()) };
    const log = pino({ level: 'silent' });
    const w1 = new OutboxDispatcher(t.pool, delivery, publisher, cfg, 'worker-1', log);
    const w2 = new OutboxDispatcher(t.pool, delivery, publisher, cfg, 'worker-2', log);
    const claims: number[] = [];
    for (let round = 0; round < 20; round++) {
      const [a, b] = await Promise.all([w1.tick(), w2.tick()]);
      claims.push(a.claimed, b.claimed);
      const left = await t.q<{ n: string }>(`SELECT count(*)::text AS n FROM onec_outbox WHERE status <> 'sent'`);
      if (left[0].n === '0') break;
    }
    expect(Math.max(...claims)).toBeLessThanOrEqual(20);
    // Каждое из 50 сообщений доставлено ровно один раз (ни одного дубля между воркерами).
    const ids = delivery.log.map((d) => d.externalId);
    expect(ids).toHaveLength(50);
    expect(new Set(ids).size).toBe(50);
    const rows = await t.q<{ status: string; attempts: number; locked_by: string | null }>(
      `SELECT status::text AS status, attempts, locked_by FROM onec_outbox`,
    );
    expect(rows.every((r) => r.status === 'sent' && r.attempts === 1)).toBe(true);
    // depends_on: доставка заказа начинается после завершения доставки его клиента.
    const at = new Map(delivery.log.map((d) => [d.externalId, d]));
    for (const p of pairs) {
      expect(at.get(p.order)!.startedAt, p.order).toBeGreaterThan(at.get(p.customer)!.finishedAt);
    }
    // Захватов ровно 50: строка, взятая одним воркером, другому не достаётся (SKIP LOCKED).
    expect(claims.reduce((x, y) => x + y, 0)).toBe(50);
  });
});
