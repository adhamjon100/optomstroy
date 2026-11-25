import 'reflect-metadata';
import { randomUUID } from 'node:crypto';
import pg from 'pg';
import type {
  OutboxDeliveryPort,
  OutboxDeliveryResult,
  OutboxRoute,
  OutboxRow,
} from '../../src/jobs/outbox/outbox-delivery.port.js';
import { OutboxDispatcher } from '../../src/jobs/outbox/outbox-dispatcher.js';
import { outboxPayloadHash } from '../../src/sync/outbox/onec-outbox.writer.js';
import { schedulerConfigFromEnv } from '../../src/sync/scheduler/scheduler.config.js';
import { EmbeddedPg } from '../support/embedded-pg.js';
import { testConfig } from '../support/test-app.js';
import { capturedLogger } from './helpers.js';

/**
 * Канал записи с маршрутами (ОС_API, `ONEC_OSAPI_WRITE_ORDERS=true`, решение владельца 25.11.2026) на PostgreSQL 17:
 * диспетчер захватывает только `order/create`; отмены, оплаты, клиенты остаются `pending` без попыток; заказ нового
 * клиента не ждёт `customer/create`, который канал не доставит никогда; исход `parked` — `pending` без
 * `next_attempt_at`, `NO_WRITE_CHANNEL`, попытка не засчитана, одна запись `sync_errors` (warning), без `dead`.
 */
class RoutedDelivery implements OutboxDeliveryPort {
  readonly configured = true;
  readonly routes: readonly OutboxRoute[] = ['order/create'];
  readonly needsOrderCustomerPhone = true;
  readonly calls: OutboxRow[] = [];
  readonly park = new Set<string>();
  /** Парковка с повторной проверкой (ОС_API `OSAPI_MANUAL`, `recheckAfterMs`). */
  readonly recheck = new Set<string>();
  readonly transient = new Set<string>();
  deliver(row: OutboxRow): Promise<OutboxDeliveryResult> {
    this.calls.push(row);
    if (this.park.has(row.id)) {
      return Promise.resolve({ kind: 'parked', message: 'клиент заказа не определён — ждёт оформления в 1С (тест)' });
    }
    if (this.recheck.has(row.id)) {
      return Promise.resolve({
        kind: 'parked',
        message: 'склад заказа в 1С не определить (тест)',
        recheckAfterMs: 3_600_000,
      });
    }
    if (this.transient.has(row.id)) return Promise.resolve({ kind: 'transient', message: 'таймаут 1С (тест)' });
    return Promise.resolve({ kind: 'sent', onecRef: row.externalId, onecNumber: 'ОС-1', onecStatus: null });
  }
}

describe('OutboxDispatcher: маршруты канала и парковка NO_WRITE_CHANNEL (ОС_API, запись заказов черновиком)', () => {
  const db = new EmbeddedPg();
  const logs = capturedLogger();
  let pool: pg.Pool;
  const delivery = new RoutedDelivery();
  let d: OutboxDispatcher;

  async function insert(
    aggregateType: 'customer' | 'order' | 'payment',
    operation: 'create' | 'cancel' = 'create',
    dependsOn: string | null = null,
  ): Promise<string> {
    const id = randomUUID();
    const r = await pool.query<{ id: string }>(
      `INSERT INTO onec_outbox (aggregate_type, aggregate_id, external_id, operation, payload, payload_hash, status,
                                next_attempt_at, depends_on_outbox_id, priority)
       VALUES ($1::outbox_aggregate, $2::uuid, $2::text, $3, '{}'::jsonb, $5::bytea, 'pending', now(), $4::uuid, 10)
       RETURNING id`,
      [aggregateType, id, operation, dependsOn, outboxPayloadHash({})],
    );
    return r.rows[0].id;
  }

  type Row = { status: string; attempts: number; parked: boolean; code: string | null; last_error: string | null };
  async function row(id: string): Promise<Row> {
    const r = await pool.query<Row>(
      `SELECT status::text AS status, attempts, next_attempt_at IS NULL AS parked, last_error_code AS code, last_error
         FROM onec_outbox WHERE id = $1`,
      [id],
    );
    return r.rows[0];
  }

  beforeAll(async () => {
    await db.start();
    await db.createDatabase('pos_outbox_routes');
    await db.migrate('pos_outbox_routes', ['0001_init.sql', '0002_rbac_seed.sql']);
    pool = new pg.Pool({ connectionString: db.url('pos_outbox_routes'), max: 4 });
    d = new OutboxDispatcher(
      pool,
      delivery,
      { send: () => Promise.resolve(randomUUID()) },
      schedulerConfigFromEnv(testConfig()).outbox,
      'routes-worker',
      logs.log,
    );
  });

  afterAll(async () => {
    await pool?.end();
    await db.stop();
  });

  it('захват только order/create; заказ нового клиента не ждёт customer/create; прочие — pending без попыток', async () => {
    const cust = await insert('customer');
    const ord = await insert('order', 'create', cust);
    const cancel = await insert('order', 'cancel');
    const pay = await insert('payment', 'create', ord);

    const t1 = await d.tick();
    expect(t1).toMatchObject({ claimed: 1, sent: 1, retried: 0, failed: 0, dead: 0 });
    expect(delivery.calls.map((c) => c.id)).toEqual([ord]);
    expect(await row(ord)).toMatchObject({ status: 'sent', attempts: 1 });
    // Телефон клиента читается (заказа в orders нет — null, поле не добавляется).
    expect(delivery.calls[0].customerPhone).toBeUndefined();
    for (const id of [cust, cancel, pay]) {
      expect(await row(id)).toMatchObject({ status: 'pending', attempts: 0, parked: false, code: null });
    }
    // Следующие тики: ничего не захватывается (оплата ждёт маршрут, которого у канала нет).
    expect(await d.tick()).toMatchObject({ claimed: 0 });
    expect(await d.tick()).toMatchObject({ claimed: 0 });
    expect(delivery.calls).toHaveLength(1);
  });

  it('parked → pending без next_attempt_at, NO_WRITE_CHANNEL, попытка не засчитана, одна sync_errors warning, без dead', async () => {
    const ord = await insert('order');
    delivery.park.add(ord);
    const t = await d.tick();
    expect(t).toMatchObject({ claimed: 1, sent: 0, retried: 0, failed: 0, dead: 0 });
    const r = await row(ord);
    expect(r).toMatchObject({ status: 'pending', attempts: 0, parked: true, code: 'NO_WRITE_CHANNEL' });
    expect(r.last_error).toBe('клиент заказа не определён — ждёт оформления в 1С (тест)');
    const errs = await pool.query<{ error_code: string; severity: string; entity: string }>(
      `SELECT error_code, severity::text AS severity, entity::text AS entity FROM sync_errors WHERE outbox_id = $1`,
      [ord],
    );
    expect(errs.rows).toEqual([{ error_code: 'NO_WRITE_CHANNEL', severity: 'warning', entity: 'order_status' }]);
    expect(logs.entries('outbox.parked: в 1С не отправлено — ждёт оформления в 1С (NO_WRITE_CHANNEL)')).toHaveLength(1);
    // Повторных попыток нет: тики строку не берут, syncDependencies парковку NO_WRITE_CHANNEL не снимает.
    expect(await d.tick()).toMatchObject({ claimed: 0 });
    await d.syncDependencies();
    expect(await row(ord)).toMatchObject({ status: 'pending', parked: true, attempts: 0 });
    // Видно в «ждут оформления в 1С» (sync-status manualOrders).
    const manual = await pool.query<{ n: number }>(
      `SELECT count(*)::int AS n FROM onec_outbox WHERE aggregate_type = 'order' AND operation = 'create'
          AND status = 'pending' AND next_attempt_at IS NULL AND last_error_code = 'NO_WRITE_CHANNEL'`,
    );
    expect(manual.rows[0].n).toBe(1);
  });

  async function due(id: string): Promise<void> {
    await pool.query(`UPDATE onec_outbox SET next_attempt_at = now() - interval '1 second' WHERE id = $1`, [id]);
  }
  async function parkErrors(id: string): Promise<{ resolved: boolean; resolution: string | null }[]> {
    const r = await pool.query<{ resolved: boolean; resolution: string | null }>(
      `SELECT resolved_at IS NOT NULL AS resolved, resolution FROM sync_errors
        WHERE outbox_id = $1 AND error_code = 'NO_WRITE_CHANNEL' ORDER BY created_at`,
      [id],
    );
    return r.rows;
  }

  it('парковка ОС_API с повторной проверкой: через час строка берётся снова; та же причина — без новой sync_errors; причина устранена — sent, парковка закрыта', async () => {
    const ord = await insert('order');
    delivery.recheck.add(ord);
    expect(await d.tick()).toMatchObject({ claimed: 1, sent: 0, dead: 0 });
    const wait = await pool.query<{ sec: number; attempts: number; code: string }>(
      `SELECT extract(epoch FROM next_attempt_at - now())::float8 AS sec, attempts, last_error_code AS code
         FROM onec_outbox WHERE id = $1`,
      [ord],
    );
    expect(wait.rows[0].attempts).toBe(0);
    expect(wait.rows[0].code).toBe('NO_WRITE_CHANNEL');
    expect(wait.rows[0].sec).toBeGreaterThan(3500);
    expect(wait.rows[0].sec).toBeLessThan(3700);
    // До срока строка не берётся.
    expect(await d.tick()).toMatchObject({ claimed: 0 });
    // Срок наступил, причина та же: снова парковка, попытки не тратятся, журнал не засоряется.
    await due(ord);
    expect(await d.tick()).toMatchObject({ claimed: 1, sent: 0 });
    expect(await row(ord)).toMatchObject({ status: 'pending', attempts: 0, parked: false, code: 'NO_WRITE_CHANNEL' });
    expect(await parkErrors(ord)).toEqual([{ resolved: false, resolution: null }]);
    // Причину устранили (задан клиент по умолчанию, склад привязан): строка уходит сама, предупреждение закрыто.
    delivery.recheck.delete(ord);
    await due(ord);
    expect(await d.tick()).toMatchObject({ claimed: 1, sent: 1 });
    expect(await row(ord)).toMatchObject({ status: 'sent', attempts: 1 });
    expect(await parkErrors(ord)).toEqual([
      { resolved: true, resolution: 'Парковка снята: заказ снова передаётся в 1С' },
    ]);
  });

  it('вышедшая из парковки строка старше OUTBOX_MAX_AGE_HOURS при временной ошибке не уходит в dead: возраст — от выхода', async () => {
    const ord = await insert('order');
    await pool.query(`UPDATE onec_outbox SET created_at = now() - interval '3 days' WHERE id = $1`, [ord]);
    delivery.recheck.add(ord);
    await d.tick();
    expect(await row(ord)).toMatchObject({ status: 'pending', code: 'NO_WRITE_CHANNEL' });
    delivery.recheck.delete(ord);
    delivery.transient.add(ord);
    await due(ord);
    expect(await d.tick()).toMatchObject({ claimed: 1, retried: 1, dead: 0 });
    expect(await row(ord)).toMatchObject({ status: 'pending', attempts: 1, code: 'ONEC_UNAVAILABLE' });
    expect((await parkErrors(ord))[0].resolved).toBe(true);
    // Следующая временная ошибка — возраст считается от закрытия парковки (sync_errors.resolved_at), а не от создания.
    await due(ord);
    expect(await d.tick()).toMatchObject({ claimed: 1, retried: 1, dead: 0 });
    delivery.transient.delete(ord);
  });
});
