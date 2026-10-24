import { randomUUID } from 'node:crypto';
import type pg from 'pg';
import { PgBoss } from 'pg-boss';
import pino from 'pino';
import { QUEUES } from '../../src/common/jobs/contracts/queues.js';
import { PG_BOSS_SCHEMA } from '../../src/common/jobs/pg-boss.service.js';
import { FakeExchangePlan } from '../../src/integrations/onec/fake-exchange-plan.js';
import { FakeOnecGateway } from '../../src/integrations/onec/fake-onec.gateway.js';
import { ONEC_CHANGE_TYPES } from '../../src/integrations/onec/onec-catalog.types.js';
import { orderStatusChangedJob } from '../../src/jobs/orders/orders-worker.wiring.js';
import { ensurePaymentsQueues } from '../../src/jobs/payments/payments-jobs.js';
import { defaultChangeHandlers } from '../../src/jobs/sync/sync-worker.wiring.js';
import type { ApplyScope } from '../../src/sync/apply/apply.types.js';
import { CatalogApplier } from '../../src/sync/apply/catalog-applier.js';
import {
  type ChangeJobPublisher,
  ChangeJobPublisherUnavailableError,
  PgBossChangeJobPublisher,
} from '../../src/sync/apply/change-job-publisher.js';
import { CustomerOrderChangeHandler } from '../../src/sync/apply/customer-order.change-handler.js';
import { DeferredDocumentsHandler } from '../../src/sync/apply/deferred-documents.handler.js';
import { OnecChangesService } from '../../src/sync/apply/onec-changes.service.js';
import { QrPaymentStatusChangeHandler, toPayload } from '../../src/sync/apply/qr-payment-status.handler.js';
import { createRunTracker } from '../../src/sync/apply/run-tracker.js';
import { type CatalogFixture, startCatalogFixture } from '../support/catalog-fixture.js';
import { EmbeddedPg } from '../support/embedded-pg.js';

/**
 * Элементы `/changes` вне каталога, которые раньше пропускались, а ack снимал их регистрацию в 1С (разбор расхождений
 * пп. 8, 28, 40, 68, 69; 05 §6.2 уточнение п. 3; ядро §22.8): события QR → задача `payments.onec-qr-status`, заказы
 * клиентов → `orders.onec-status-changed` (обе — в транзакции сообщения), ПКО и поступления — осознанно отложены до
 * Q-012 (`deferred`). Данные — фикстуры `contracts/onec/fixtures` (сообщение 5121) и синтетика (тестовые данные).
 */
const silent = pino({ level: 'silent' });
let server: EmbeddedPg;
let dbNo = 0;
const open: CatalogFixture[] = [];
const bosses: PgBoss[] = [];

/** externalId заказа и платежа QR из фикстуры `changes.documents.page2.200.json`. */
const FIXTURE_ORDER_ID = '0192f5a0-7c2e-7d3b-9a1f-3c4d5e6f7a8b';
const FIXTURE_QR_ID = '0192f5a1-2b3c-7d4e-8f50-6a7b8c9d0e1f';

async function fresh(): Promise<CatalogFixture> {
  const f = await startCatalogFixture({
    pg: server,
    database: `foreign_${++dbNo}`,
    skuCount: 0,
    includeFixtures: false,
    skipLoad: true,
  });
  open.push(f);
  return f;
}

async function startBoss(f: CatalogFixture): Promise<PgBoss> {
  const boss = new PgBoss({ connectionString: f.url, schema: PG_BOSS_SCHEMA, supervise: false, schedule: false });
  boss.on('error', () => undefined);
  await boss.start();
  bosses.push(boss);
  return boss;
}

function service(pool: pg.Pool, gw: FakeOnecGateway, publisher: ChangeJobPublisher): OnecChangesService {
  return new OnecChangesService(pool, gw, new CatalogApplier(), createRunTracker(pool), silent, {
    reconcileWithHealth: false,
    handlers: defaultChangeHandlers({ salesHistoryMonths: 12, publisher, log: silent }),
  });
}

async function jobs(pool: pg.Pool, queue: string): Promise<Record<string, unknown>[]> {
  const r = await pool.query<{ data: Record<string, unknown> }>(
    `SELECT data FROM ${PG_BOSS_SCHEMA}.job WHERE name = $1 ORDER BY created_on`,
    [queue],
  );
  return r.rows.map((x) => x.data);
}

/** Заказ POS с id = externalId фикстуры (FK/триггеры отключены: проверяется только сопоставление по id). */
async function insertOrder(pool: pg.Pool, id: string): Promise<void> {
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    await c.query(`SET LOCAL session_replication_role = replica`);
    await c.query(
      `INSERT INTO orders (id, public_number, status, customer_id, created_by_user_id, warehouse_id, price_list_id,
                           subtotal, total, payment_method, delivery_method, onec_ref, onec_sync_state, submitted_at)
       VALUES ($1, 'POS-2026-000001', 'pending_approval', $2, $3, $4, $5, 16007.50, 16007.50, 'cash', 'pickup',
               'b2c3d4e5-0000-4000-8000-000000000010', 'pending', now())`,
      [id, randomUUID(), randomUUID(), randomUUID(), randomUUID()],
    );
    await c.query('COMMIT');
  } catch (e) {
    await c.query('ROLLBACK').catch(() => undefined);
    throw e;
  } finally {
    c.release();
  }
}

beforeAll(async () => {
  server = new EmbeddedPg();
  await server.start();
});

afterAll(async () => {
  for (const b of bosses) await b.stop({ graceful: false }).catch(() => undefined);
  for (const f of open) await f.stop();
  await server?.stop();
});

describe('состав плана обмена: каждый тип /changes применяется, откладывается осознанно или является каталогом', () => {
  it('ни один тип контракта (кроме ObjectDeletion) не остаётся без обработчика в составе по умолчанию', () => {
    const catalog = new Set([
      'Catalog_Номенклатура',
      'Catalog_ХарактеристикиНоменклатуры',
      'Catalog_УпаковкиЕдиницыИзмерения',
      'Catalog_КлассификаторЕдиницИзмерения',
      'Catalog_Склады',
      'Catalog_ВидыЦен',
      'InformationRegister_ШтрихкодыНоменклатуры',
      'Document_УстановкаЦенНоменклатуры',
      'ObjectDeletion',
    ]);
    const publisher: ChangeJobPublisher = { publish: () => Promise.resolve() };
    const covered = new Set(defaultChangeHandlers({ salesHistoryMonths: 12, publisher }).flatMap((h) => h.types));
    const missing = ONEC_CHANGE_TYPES.filter((t) => !catalog.has(t) && !covered.has(t));
    expect(missing).toEqual([]);
    // Отложенные до Q-012 — только ПКО и поступления.
    const deferred = defaultChangeHandlers({ salesHistoryMonths: 12, publisher })
      .filter((h) => h.deferred === true)
      .flatMap((h) => h.types);
    expect(deferred).toEqual(['Document_ПриходныйКассовыйОрдер', 'Document_ПоступлениеБезналичныхДенежныхСредств']);
  });
});

describe('onec.changes: заказы клиентов и события QR — задачами в транзакции сообщения (пп. 8, 68, 69)', () => {
  it('сообщение 5121: QR → payments.onec-qr-status (поля контракта), заказ POS → orders.onec-status-changed, ПКО — deferred, unhandled = 0', async () => {
    const f = await fresh();
    await insertOrder(f.pool, FIXTURE_ORDER_ID);
    const boss = await startBoss(f);
    const publisher = new PgBossChangeJobPublisher(async (b) => {
      await ensurePaymentsQueues(b);
      if (!(await b.getQueue(QUEUES.ordersOnecStatusChanged))) await b.createQueue(QUEUES.ordersOnecStatusChanged);
    });
    await publisher.attach(boss);
    const gw = new FakeOnecGateway();
    const r = await service(f.pool, gw, publisher).pullOnce();
    expect(r.status).toBe('applied');
    expect(r.messageNumber).toBe(5121);
    expect(r.unhandled).toBe(0);
    expect(r.deferred).toBe(1);
    expect(gw.calls.filter((c) => c.operation === 'ackChanges').map((c) => c.args[0])).toEqual([5121]);

    const qr = await jobs(f.pool, QUEUES.paymentsOnecQrStatus);
    expect(qr).toEqual([
      {
        externalId: FIXTURE_QR_ID,
        status: 'paid',
        reference: 'QR-7F3A9C21',
        paidAmount: '16007.50',
        paidAt: '2026-10-21T14:07:12+06:00',
        bankReference: 'BK-20261021-000123',
        documentRef: null,
      },
    ]);
    const orders = await jobs(f.pool, QUEUES.ordersOnecStatusChanged);
    expect(orders).toHaveLength(1);
    expect(orders[0]).toMatchObject({
      orderId: FIXTURE_ORDER_ID,
      document: {
        ref: 'b2c3d4e5-0000-4000-8000-000000000010',
        number: 'ОС00-004512',
        status: 'КВыполнению',
        approved: true,
        deletionMark: false,
        total: '16007.50',
        shipments: [],
      },
    });
  });

  it('заказ с externalId, которого нет в POS, — ошибка позиции NOT_FOUND_LOCAL (order_status) без задачи; сообщение подтверждается', async () => {
    const f = await fresh();
    const boss = await startBoss(f);
    const publisher = new PgBossChangeJobPublisher(async (b) => {
      await ensurePaymentsQueues(b);
      if (!(await b.getQueue(QUEUES.ordersOnecStatusChanged))) await b.createQueue(QUEUES.ordersOnecStatusChanged);
    });
    await publisher.attach(boss);
    const gw = new FakeOnecGateway();
    const r = await service(f.pool, gw, publisher).pullOnce();
    expect(r.status).toBe('applied');
    expect(await jobs(f.pool, QUEUES.ordersOnecStatusChanged)).toEqual([]);
    const errs = await f.pool.query<{ code: string; ref: string; run: string | null }>(
      `SELECT error_code AS code, onec_ref::text AS ref, sync_run_id::text AS run FROM sync_errors WHERE entity = 'order_status'`,
    );
    expect(errs.rows).toEqual([{ code: 'NOT_FOUND_LOCAL', ref: 'b2c3d4e5-0000-4000-8000-000000000010', run: null }]);
  });

  it('pg-boss не подключён: сообщение не применяется и не подтверждается; после подключения — то же сообщение, событие QR не потеряно', async () => {
    const f = await fresh();
    const publisher = new PgBossChangeJobPublisher(async (b) => {
      await ensurePaymentsQueues(b);
      if (!(await b.getQueue(QUEUES.ordersOnecStatusChanged))) await b.createQueue(QUEUES.ordersOnecStatusChanged);
    });
    const gw = new FakeOnecGateway();
    await expect(service(f.pool, gw, publisher).pullOnce()).rejects.toBeInstanceOf(ChangeJobPublisherUnavailableError);
    expect(gw.calls.filter((c) => c.operation === 'ackChanges')).toEqual([]);
    const node = await f.pool.query<{ n: string }>(`SELECT last_message_number::text AS n FROM sync_node_state`);
    expect(node.rows[0]?.n).toBe('0');

    await publisher.attach(await startBoss(f));
    const r = await service(f.pool, gw, publisher).pullOnce();
    expect(r.status).toBe('applied');
    expect(r.messageNumber).toBe(5121);
    expect((await jobs(f.pool, QUEUES.paymentsOnecQrStatus)).map((j) => j.externalId)).toEqual([FIXTURE_QR_ID]);
  });
});

describe('обработчики элементов вне каталога (модульно)', () => {
  function scope(rows: { id: string }[] = []): { scope: ApplyScope; sql: string[] } {
    const sql: string[] = [];
    const client = {
      query: (text: string) => {
        sql.push(text);
        return Promise.resolve({ rows: text.includes('FROM orders') ? rows : [], rowCount: rows.length });
      },
    } as unknown as pg.PoolClient;
    return {
      sql,
      scope: {
        client,
        runIdFor: () => Promise.reject(new Error('прогон не должен открываться')),
        syncedAt: new Date(),
        counts: new Map(),
        errors: [],
      },
    };
  }

  it('QrPaymentStatus: отображение полей контракта; элемент не по формату — VALIDATION без публикации', async () => {
    const valid = {
      type: 'QrPaymentStatus',
      ref: FIXTURE_QR_ID,
      externalId: FIXTURE_QR_ID,
      status: 'expired',
      reference: 'QR-1',
      paidAmount: null,
      paidAt: null,
      bankReference: null,
    };
    expect(toPayload(valid)).toEqual({
      externalId: FIXTURE_QR_ID,
      status: 'expired',
      reference: 'QR-1',
      paidAmount: null,
      paidAt: null,
      bankReference: null,
      documentRef: null,
    });
    expect(toPayload({ ...valid, status: 'refunded' })).toBe('status');
    expect(toPayload({ ...valid, externalId: 'QR-1' })).toBe('externalId');
    expect(toPayload({ ...valid, paidAmount: 100 })).toBe('paidAmount');
    expect(toPayload({ ...valid, paidAt: '2026-10-21T14:07:12Z' })).toBe('paidAt');

    const published: unknown[] = [];
    const h = new QrPaymentStatusChangeHandler({
      publish: (_c, q, p) => {
        published.push([q, p]);
        return Promise.resolve();
      },
    });
    const s = scope();
    await h.apply(s.scope, [valid, { ...valid, status: 'refunded' }]);
    expect(published).toEqual([[QUEUES.paymentsOnecQrStatus, toPayload(valid)]]);
    expect(s.sql.filter((q) => q.includes('INSERT INTO sync_errors'))).toHaveLength(1);
  });

  it('Document_ЗаказКлиента: заказ вне POS (externalId=null) и удаление документа статус не меняют; не GUID — VALIDATION', async () => {
    const published: unknown[] = [];
    const h = new CustomerOrderChangeHandler({
      publish: (_c, q, p) => {
        published.push([q, p]);
        return Promise.resolve();
      },
    });
    const s = scope([{ id: FIXTURE_ORDER_ID }]);
    const base = {
      type: 'Document_ЗаказКлиента',
      ref: 'b2c3d4e5-0000-4000-8000-000000000010',
      dataVersion: 'v',
      deletionMark: true,
      number: 'ОС-1',
      date: '2026-10-21T13:40:00+06:00',
      status: 'Закрыт',
      approved: true,
      total: '10.00',
      shipments: [{ ref: 'b2c3d4e5-0000-4000-8000-000000000020', posted: true }],
    };
    await h.apply(s.scope, [
      { ...base, externalId: null },
      { ...base, externalId: 'не-guid' },
      { type: 'ObjectDeletion', objectType: 'Document_ЗаказКлиента', ref: base.ref },
      { ...base, externalId: FIXTURE_ORDER_ID },
    ]);
    expect(published).toEqual([
      [
        QUEUES.ordersOnecStatusChanged,
        {
          orderId: FIXTURE_ORDER_ID,
          document: {
            ref: base.ref,
            number: 'ОС-1',
            date: base.date,
            status: 'Закрыт',
            approved: true,
            deletionMark: true,
            total: '10.00',
            fulfillmentState: null,
            shipments: base.shipments,
          },
        },
      ],
    ]);
    expect(s.sql.filter((q) => q.includes('INSERT INTO sync_errors'))).toHaveLength(1);
  });

  it('orders.onec-status-changed: документ применяется процедурой опроса статусов (applyDocument) с разобранными фактами', async () => {
    const calls: unknown[] = [];
    const job = orderStatusChangedJob({
      applyDocument: (orderId, doc, runId) => {
        calls.push({ orderId, doc, runId });
        return Promise.resolve({ changed: true, confirmed: false, unknownStatus: false });
      },
    });
    await job({
      orderId: FIXTURE_ORDER_ID,
      document: {
        ref: 'b2c3d4e5-0000-4000-8000-000000000010',
        number: 'ОС-1',
        date: '2026-10-21T13:40:00+06:00',
        status: 'КВыполнению',
        approved: true,
        deletionMark: false,
        total: '16007.5',
        fulfillmentState: null,
        shipments: [{ posted: true }],
      },
    });
    expect(calls).toEqual([
      {
        orderId: FIXTURE_ORDER_ID,
        runId: null,
        doc: {
          ref: 'b2c3d4e5-0000-4000-8000-000000000010',
          number: 'ОС-1',
          date: '2026-10-21T13:40:00+06:00',
          status: 'КВыполнению',
          approved: true,
          deletionMark: false,
          total: '16007.50',
          hasShipment: true,
        },
      },
    ]);
    // Без обработчика статусов задача не «съедается» — повтор pg-boss.
    await expect(
      orderStatusChangedJob(undefined)({ orderId: FIXTURE_ORDER_ID, document: {} as never }),
    ).rejects.toThrow(/не подключён/);
  });

  it('ПКО и поступления: обработчик deferred не трогает БД', async () => {
    const s = scope();
    await new DeferredDocumentsHandler().apply(s.scope, [
      { type: 'Document_ПриходныйКассовыйОрдер', ref: randomUUID() },
      { type: 'ObjectDeletion', objectType: 'Document_ПоступлениеБезналичныхДенежныхСредств', ref: randomUUID() },
    ]);
    expect(s.sql).toEqual([]);
  });
});

describe('фейк плана обмена: рекомендуемый порядок типов ТЗ 5.3 п. 6 (п. 40)', () => {
  it('скидки → заказы → реализации → платёжные документы → возвраты → события QR', () => {
    const types = [
      'QrPaymentStatus',
      'Document_ВозвратТоваровОтКлиента',
      'Document_ПриходныйКассовыйОрдер',
      'Document_РеализацияТоваровУслуг',
      'Document_ЗаказКлиента',
      'Catalog_СкидкиНаценки',
    ];
    const items = types.map((type, i) => ({ type, ref: `0000000${i}-0000-4000-8000-000000000000` }));
    const plan = new FakeExchangePlan(null).addSource({
      allItems: () => items,
      itemByKey: (k) => items.find((it) => `${it.type}:${it.ref}` === k),
    });
    plan.registerAll();
    const page = plan.getChanges({ since: 0 });
    expect(page.items.map((it) => (it as { type: string }).type)).toEqual([
      'Catalog_СкидкиНаценки',
      'Document_ЗаказКлиента',
      'Document_РеализацияТоваровУслуг',
      'Document_ПриходныйКассовыйОрдер',
      'Document_ВозвратТоваровОтКлиента',
      'QrPaymentStatus',
    ]);
  });
});
