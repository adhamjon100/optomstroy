import 'reflect-metadata';
import { randomUUID } from 'node:crypto';
import pg from 'pg';
import type {
  OutboxDeliveryPort,
  OutboxDeliveryResult,
  OutboxRow,
} from '../../src/jobs/outbox/outbox-delivery.port.js';
import { type BlockedDependent, OutboxDispatcher } from '../../src/jobs/outbox/outbox-dispatcher.js';
import { outboxPayloadHash } from '../../src/sync/outbox/onec-outbox.writer.js';
import { schedulerConfigFromEnv } from '../../src/sync/scheduler/scheduler.config.js';
import { EmbeddedPg } from '../support/embedded-pg.js';
import { testConfig } from '../support/test-app.js';
import { capturedLogger } from './helpers.js';

/**
 * Зависимые элементы outbox (05 SYNC-042, SYNC-049; 07 §5.55, §8.2; known_issues G-KI-12) на PostgreSQL 17: основание
 * в `failed`/`dead`/`cancelled` → зависимый `pending` паркуется (`next_attempt_at = NULL`, причина в `last_error`,
 * попытки не тратятся, хук уведомления); основание снова в работе → парковка снимается, зависимый уходит после
 * доставки основания; парковка фазы 0 (`NO_WRITE_CHANNEL`) не трогается. Канал 1С — сценарий теста по id строки.
 */
class ByIdDelivery implements OutboxDeliveryPort {
  readonly configured = true;
  readonly calls: string[] = [];
  readonly modes = new Map<string, 'ok' | 'reject' | 'fatal'>();
  deliver(row: OutboxRow): Promise<OutboxDeliveryResult> {
    this.calls.push(row.id);
    const mode = this.modes.get(row.id) ?? 'ok';
    if (mode === 'reject') {
      return Promise.resolve({ kind: 'rejected', message: '409 POS_E_DUPLICATE: найден другой клиент (тест)' });
    }
    if (mode === 'fatal') return Promise.resolve({ kind: 'fatal', message: 'HTTP 401 от 1С (тест)' });
    return Promise.resolve({ kind: 'sent', onecRef: randomUUID(), onecNumber: null, onecStatus: null, response: {} });
  }
}

describe('OutboxDispatcher: зависимые элементы основания в failed/dead/cancelled (05 SYNC-042; G-KI-12)', () => {
  const db = new EmbeddedPg();
  const logs = capturedLogger();
  let pool: pg.Pool;
  const delivery = new ByIdDelivery();
  const blocked: BlockedDependent[] = [];
  let failHook = false;
  let d: OutboxDispatcher;

  async function insert(
    aggregateType: 'customer' | 'order' | 'payment',
    dependsOn: string | null = null,
    extra: { status?: string; parkedCode?: string } = {},
  ): Promise<string> {
    const id = randomUUID();
    const r = await pool.query<{ id: string }>(
      `INSERT INTO onec_outbox (aggregate_type, aggregate_id, external_id, operation, payload, payload_hash, status,
                                next_attempt_at, depends_on_outbox_id, last_error_code, priority)
       VALUES ($1::outbox_aggregate, $2::uuid, $2::text, 'create', '{}'::jsonb, $6::bytea, $3::outbox_status,
               CASE WHEN $5::text IS NULL THEN now() ELSE NULL END, $4::uuid, $5, 10)
       RETURNING id`,
      [aggregateType, id, extra.status ?? 'pending', dependsOn, extra.parkedCode ?? null, outboxPayloadHash({})],
    );
    return r.rows[0].id;
  }

  type Row = { status: string; attempts: number; parked: boolean; last_error: string | null };
  async function row(id: string): Promise<Row> {
    const r = await pool.query<Row>(
      `SELECT status::text AS status, attempts, next_attempt_at IS NULL AS parked, last_error FROM onec_outbox
        WHERE id = $1`,
      [id],
    );
    return r.rows[0];
  }

  beforeAll(async () => {
    await db.start();
    await db.createDatabase('pos_outbox_deps');
    await db.migrate('pos_outbox_deps', ['0001_init.sql', '0002_rbac_seed.sql']);
    pool = new pg.Pool({ connectionString: db.url('pos_outbox_deps'), max: 4 });
    d = new OutboxDispatcher(
      pool,
      delivery,
      { send: () => Promise.resolve(randomUUID()) },
      schedulerConfigFromEnv(testConfig()).outbox,
      'deps-worker',
      logs.log,
      {
        onDependencyBlocked: (items) => {
          if (failHook) return Promise.reject(new Error('сбой хука (тест)'));
          blocked.push(...items);
          return Promise.resolve();
        },
      },
    );
  });

  afterAll(async () => {
    await pool?.end();
    await db.stop();
  });

  it('отказ 1С по клиенту → заказ запаркован с причиной, без попыток; повтор клиента → парковка снята, заказ уходит после клиента', async () => {
    const cust = await insert('customer');
    const ord = await insert('order', cust);
    delivery.modes.set(cust, 'reject');
    const t1 = await d.tick();
    expect(t1).toMatchObject({ claimed: 1, failed: 1 });
    expect(await row(cust)).toMatchObject({ status: 'failed' });
    const parked = await row(ord);
    expect(parked).toMatchObject({ status: 'pending', attempts: 0, parked: true });
    expect(parked.last_error).toBe(
      `Ожидает элемент customer/create ${cust} в статусе failed: ONEC_REJECTED — 409 POS_E_DUPLICATE: найден другой ` +
        'клиент (тест). Отправка в 1С — после повтора и доставки основания (05 SYNC-042).',
    );
    expect(blocked).toHaveLength(1);
    expect(blocked[0]).toMatchObject({
      id: ord,
      aggregateType: 'order',
      operation: 'create',
      reason: parked.last_error,
      dependency: { id: cust, aggregateType: 'customer', operation: 'create', status: 'failed' },
    });
    expect(blocked[0].dependency.lastErrorCode).toBe('ONEC_REJECTED');
    expect(blocked[0].dependency.changedAt).toBeInstanceOf(Date);
    expect(logs.entries('outbox.dependency.parked')).toHaveLength(1);

    // Повторные тики: заказ не захватывается, хук не вызывается повторно.
    expect(await d.tick()).toMatchObject({ claimed: 0 });
    expect(await d.syncDependencies()).toEqual({ parked: 0, released: 0 });
    expect(blocked).toHaveLength(1);
    expect(delivery.calls).not.toContain(ord);

    // Ручной повтор клиента (POST /sync/outbox/{id}/retry): основание pending → парковка снята.
    delivery.modes.set(cust, 'ok');
    await pool.query(
      `UPDATE onec_outbox SET status = 'pending', attempts = 0, next_attempt_at = now(), updated_at = now() WHERE id = $1`,
      [cust],
    );
    const t2 = await d.tick();
    expect(t2).toMatchObject({ claimed: 1, sent: 1 });
    expect(await row(ord)).toMatchObject({ status: 'pending', attempts: 0, parked: false, last_error: null });
    expect(logs.entries('outbox.dependency.released')).toHaveLength(1);
    expect(await d.tick()).toMatchObject({ claimed: 1, sent: 1 });
    expect(await row(ord)).toMatchObject({ status: 'sent', attempts: 1 });
    expect(delivery.calls.indexOf(ord)).toBeGreaterThan(delivery.calls.lastIndexOf(cust));
  });

  it('dead основания (401) и cancelled — тоже парковка с причиной; без хука и при сбое хука — только журнал', async () => {
    const cust = await insert('customer');
    const ord = await insert('order', cust);
    const pay = await insert('payment', ord);
    delivery.modes.set(cust, 'fatal');
    failHook = true;
    try {
      expect(await d.tick()).toMatchObject({ dead: 1 });
    } finally {
      failHook = false;
    }
    const r = await row(ord);
    expect(r).toMatchObject({ status: 'pending', parked: true });
    expect(r.last_error).toContain(`customer/create ${cust} в статусе dead: OTHER — HTTP 401 от 1С (тест)`);
    // Платёж ждёт заказ (основание pending, не отказ) — не паркуется.
    expect(await row(pay)).toMatchObject({ status: 'pending', parked: false, last_error: null });
    expect(logs.entries('outbox.dependency.hook_failed')).toHaveLength(1);

    // Основание отозвано (cancelled, без текста ошибки) — зависимый паркуется; диспетчер без хуков.
    const bare = new OutboxDispatcher(
      pool,
      delivery,
      { send: () => Promise.resolve(randomUUID()) },
      schedulerConfigFromEnv(testConfig()).outbox,
      'deps-bare',
      logs.log,
    );
    const root = await insert('order');
    const dep = await insert('payment', root);
    await pool.query(`UPDATE onec_outbox SET status = 'cancelled', cancelled_at = now() WHERE id = $1`, [root]);
    expect(await bare.syncDependencies()).toEqual({ parked: 1, released: 0 });
    expect((await row(dep)).last_error).toBe(
      `Ожидает элемент order/create ${root} в статусе cancelled. Отправка в 1С — после повтора и доставки основания (05 SYNC-042).`,
    );
  });

  it('парковка фазы 0 (NO_WRITE_CHANNEL) не снимается; сбой БД — журнал, тик не падает', async () => {
    const root = await insert('customer', null, { status: 'sent' });
    const dep = await insert('order', root, { parkedCode: 'NO_WRITE_CHANNEL' });
    expect(await d.syncDependencies()).toEqual({ parked: 0, released: 0 });
    expect(await row(dep)).toMatchObject({ status: 'pending', parked: true });

    const broken = new OutboxDispatcher(
      { query: () => Promise.reject(new Error('БД недоступна (тест)')), connect: () => pool.connect() } as never,
      delivery,
      { send: () => Promise.resolve(randomUUID()) },
      schedulerConfigFromEnv(testConfig()).outbox,
      'deps-broken',
      logs.log,
    );
    expect(await broken.syncDependencies()).toEqual({ parked: 0, released: 0 });
    expect(logs.entries('outbox.dependency.sync_failed')).toHaveLength(1);
  });
});
