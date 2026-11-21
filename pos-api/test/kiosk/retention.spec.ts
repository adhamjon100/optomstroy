import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { CartModule } from '../../src/cart/cart.module.js';
import { AuditService } from '../../src/common/audit/audit.service.js';
import { QUEUES } from '../../src/common/jobs/contracts/queues.js';
import { maskPhone } from '../../src/common/logging/redaction.js';
import { KIOSK_ACCESS_GUARD } from '../../src/kiosk/common/kiosk-access.guard.js';
import { KioskModule } from '../../src/kiosk/kiosk.module.js';
import { kioskNoticeSha256 } from '../../src/kiosk/otp/notice-catalog.js';
import { KIOSK_RECEIVER_PHONE_TTL_DAYS, OrdersRetentionService } from '../../src/orders/orders-retention.service.js';
import { OrdersModule } from '../../src/orders/orders.module.js';
import { ProfileModule } from '../../src/profile/profile.module.js';
import { ReturnsJobsBridge } from '../../src/returns/onec/returns-jobs.bridge.js';
import { ReturnsModule } from '../../src/returns/returns.module.js';
import { ReturnsRetentionService } from '../../src/returns/returns-retention.service.js';
import { PublicSettingsModule } from '../../src/settings/public-settings.module.js';
import { apiErrors } from '../customers/support/customers-app.js';
import type { PosActor, SaleableVariant } from '../support/pos-fixture.js';
import { type KioskTablet, KioskTestApp } from './support/kiosk-fixture.js';

/**
 * Маскирование номера покупателя в заявках с планшета через 90 дней (07 §13.3 «Планшет магазина», DATA-303; 11
 * PRIV-034, PRIV-016; 10 KIOSK-023, KIOSK-034; 08 §3.9 `Receiver.phoneMasked`; P-002 §14.5; ADR-115; задача TAB-1-10)
 * — **тестовые данные**: стенд `kiosk-fixture` (embedded PostgreSQL 17 со всеми миграциями, синтетический каталог).
 * Заявки — заказы стенда (`seedOrder`) с признаками канала `kiosk` (как после `POST /kiosk/orders`); «часы сдвинуты»
 * метками заказа (`created_at`, `shipped_at`, `cancelled_at`) относительно времени БД. Номер — вымышленный
 * `+996 555 008 101` (тестовые данные; формат маски — как у `+996 700 000 101` из 12 T-KIOSK-044: первая цифра
 * абонентского номера и две последние).
 * - T-KIOSK-044: выдана 91 день назад, отменена 91 день назад, не выдана и не отменена и создана 91 день назад —
 *   `receiver_phone_e164 = NULL`, `receiver_phone_masked = '+996 5** *** *01'`, в DTO `receiver.phone = null` и
 *   `receiver.phoneMasked`; выдана 89 дней назад — номер полный; повторный запуск ничего не меняет; аудит
 *   `retention.executed` без номеров; заказы других каналов и свежие заявки не трогаются; занятая строка пропускается;
 * - задание — в единственном обработчике `retention.daily` (`ReturnsJobsBridge.runDaily`): черновики возвратов и
 *   маскирование, сбой одной задачи не отменяет другую.
 */
type JobFn = (jobs: { data: unknown }[]) => Promise<unknown>;

interface ReceiverRow {
  receiver_phone_e164: string | null;
  receiver_phone_masked: string | null;
  row_version: number;
}

const PHONE = '+996555008101';
const MASK = '+996 5** *** *01';
const NOTICE = '2026-11-04';

/** pg-boss подменён (как test/returns/returns-jobs.bridge.spec.ts): очереди, обработчики, расписания. */
function fakeBoss() {
  const works: { name: string; fn: JobFn }[] = [];
  const queues = new Map<string, unknown>();
  const schedules: { name: string; cron: string }[] = [];
  const boss = {
    getQueue: (n: string) => Promise.resolve(queues.has(n) ? { name: n } : null),
    createQueue: (n: string, o: unknown) => {
      queues.set(n, o);
      return Promise.resolve();
    },
    work: (n: string, _o: unknown, fn: JobFn) => {
      works.push({ name: n, fn });
      return Promise.resolve('worker-id');
    },
    schedule: (name: string, cron: string) => {
      schedules.push({ name, cron });
      return Promise.resolve();
    },
  };
  return { boss, works, schedules };
}

describe('kiosk: маскирование номера покупателя в заявке с планшета (retention.daily)', () => {
  const t = new KioskTestApp();
  let v: SaleableVariant;
  let tab: KioskTablet;
  let cashier: PosActor;
  let seller: PosActor;
  let svc: OrdersRetentionService;

  /** Заявка с планшета: заказ стенда + признаки канала `kiosk`; метки времени — «сдвинутые часы» (дни назад). */
  async function kioskOrder(
    days: { readonly created: number; readonly shipped?: number; readonly cancelled?: number },
    phone = PHONE,
  ): Promise<string> {
    const o = await t.seedOrder({
      createdBy: tab,
      method: 'cash',
      status: days.shipped !== undefined ? 'awaiting_shipment' : 'submitting',
      items: [{ variantId: v.variantId, quantity: '1' }],
    });
    await t.q(
      `UPDATE orders SET created_via = 'kiosk', kiosk_customer_match = 'none', receiver_kind = 'customer',
              receiver_name = NULL, receiver_phone_e164 = $2, pd_notice_version = $3, pd_notice_sha256 = $4,
              created_at = now() - make_interval(days => $5::int),
              shipped_at = CASE WHEN $6::int IS NULL THEN NULL ELSE now() - make_interval(days => $6::int) END,
              cancelled_at = CASE WHEN $7::int IS NULL THEN NULL ELSE now() - make_interval(days => $7::int) END,
              status = CASE WHEN $6::int IS NOT NULL THEN 'shipped'::order_status
                            WHEN $7::int IS NOT NULL THEN 'cancelled'::order_status ELSE status END
        WHERE id = $1`,
      [o.orderId, phone, NOTICE, kioskNoticeSha256(NOTICE), days.created, days.shipped ?? null, days.cancelled ?? null],
    );
    return o.orderId;
  }

  async function receiverOf(orderId: string): Promise<ReceiverRow> {
    return (
      await t.q<ReceiverRow & Record<string, unknown>>(
        `SELECT receiver_phone_e164, receiver_phone_masked, row_version FROM orders WHERE id = $1`,
        [orderId],
      )
    )[0];
  }

  async function ordersAudit(): Promise<Record<string, unknown>[]> {
    return (await t.auditRows('retention.executed')).map((r) => r.after ?? {}).filter((a) => a.table === 'orders');
  }

  beforeAll(async () => {
    await t.start({
      env: { QR_PROVIDER: 'none', KIOSK_MODE: 'true' },
      skuCount: 30,
      modules: [CartModule, OrdersModule, ReturnsModule, ProfileModule, PublicSettingsModule, KioskModule],
      guards: [KIOSK_ACCESS_GUARD],
      fakePorts: true,
      jobs: false,
    });
    [v] = await t.saleableVariants(1);
    await t.setPrice(v.variantId, '100.00');
    tab = await t.tablet();
    cashier = await t.actor({ role: 'cashier' });
    seller = await t.actor({ role: 'seller' });
    svc = new OrdersRetentionService(t.db, new AuditService(t.db));
  });

  afterAll(async () => {
    await t.stop();
  });

  it('T-KIOSK-044 masking 91/91/91/89 days, idempotent rerun, DTO phoneMasked', async () => {
    expect(KIOSK_RECEIVER_PHONE_TTL_DAYS).toBe(90);
    const shipped91 = await kioskOrder({ created: 100, shipped: 91 });
    const cancelled91 = await kioskOrder({ created: 95, cancelled: 91 });
    const open91 = await kioskOrder({ created: 91 });
    const shipped89 = await kioskOrder({ created: 100, shipped: 89 });
    const fresh = await kioskOrder({ created: 1 });
    // Заказ сотрудника с получателем — другим человеком, отгружен 200 дней назад: другой канал, не трогается.
    const staff = await t.seedOrder({ createdBy: seller, method: 'cash' });
    await t.q(
      `UPDATE orders SET receiver_kind = 'other_person', receiver_name = 'Получатель (тест)', receiver_phone_e164 = $2,
              created_at = now() - interval '210 days', shipped_at = now() - interval '200 days'
        WHERE id = $1`,
      [staff.orderId, '+996555008102'],
    );
    const before = new Map<string, ReceiverRow>();
    for (const id of [shipped91, cancelled91, open91, shipped89, fresh, staff.orderId]) {
      before.set(id, await receiverOf(id));
    }
    const audit0 = (await ordersAudit()).length;

    const first = await svc.maskKioskReceiverPhones();
    expect(first.masked).toBe(3);
    expect(maskPhone(PHONE)).toBe(MASK);
    for (const id of [shipped91, cancelled91, open91]) {
      // CHECK orders_receiver_phone_e164_chk и orders_receiver_phone_masked_chk / _null_chk не нарушены (UPDATE прошёл).
      expect(await receiverOf(id)).toEqual({
        receiver_phone_e164: null,
        receiver_phone_masked: MASK,
        row_version: before.get(id)!.row_version + 1,
      });
    }
    // Выдана 89 дней назад (создана 100 дней назад — срок считается от выдачи) — номер полный.
    expect(await receiverOf(shipped89)).toEqual(before.get(shipped89));
    expect(await receiverOf(fresh)).toEqual(before.get(fresh));
    expect(await receiverOf(staff.orderId)).toEqual(before.get(staff.orderId));
    expect((await receiverOf(shipped89)).receiver_phone_e164).toBe(PHONE);

    // DTO заказа (08 §3.9): receiver.phone = null и receiver.phoneMasked; до маскирования поля phoneMasked нет.
    const dto = await t.req('get', `/orders/${shipped91}`, cashier);
    expect(dto.status, JSON.stringify(dto.body)).toBe(200);
    expect(dto.body).toMatchObject({
      createdVia: 'kiosk',
      receiver: { kind: 'customer', name: null, phone: null, phoneMasked: MASK },
    });
    expect(apiErrors('Receiver', dto.body.receiver)).toEqual([]);
    const list = await t.req('get', '/orders?createdVia=kiosk&limit=200', cashier);
    const item = (list.body.items as { id: string; receiver: Record<string, unknown> }[]).find((i) => i.id === open91);
    expect(item?.receiver).toEqual({ kind: 'customer', name: null, phone: null, phoneMasked: MASK });
    const full = await t.req('get', `/orders/${shipped89}`, cashier);
    expect(full.body.receiver).toEqual({ kind: 'customer', name: null, phone: PHONE });
    expect(apiErrors('Receiver', full.body.receiver)).toEqual([]);

    // Аудит retention.executed (PRIV-016): таблица, столбец, число строк — без номеров.
    const audit1 = await ordersAudit();
    expect(audit1).toHaveLength(audit0 + 1);
    expect(audit1.at(-1)).toEqual({
      table: 'orders',
      column: 'receiver_phone_e164',
      createdVia: 'kiosk',
      olderThanDays: 90,
      rows: 3,
    });
    expect(JSON.stringify(audit1)).not.toContain('555008');

    // Повторный запуск: ни одной изменённой строки, row_version прежний, новой записи аудита нет.
    const after1 = new Map<string, ReceiverRow>();
    for (const id of [shipped91, cancelled91, open91, shipped89]) after1.set(id, await receiverOf(id));
    expect(await svc.maskKioskReceiverPhones()).toEqual({ masked: 0 });
    for (const [id, row] of after1) expect(await receiverOf(id)).toEqual(row);
    expect(await ordersAudit()).toHaveLength(audit0 + 1);
  });

  it('T-KIOSK-044 row locked by another transaction is skipped and masked by the next run', async () => {
    const busy = await kioskOrder({ created: 120 }, '+996555008103');
    const c = await t.pool.connect();
    try {
      await c.query('BEGIN');
      await c.query(`SELECT 1 FROM orders WHERE id = $1 FOR UPDATE`, [busy]);
      expect(await svc.maskKioskReceiverPhones()).toEqual({ masked: 0 });
      expect((await receiverOf(busy)).receiver_phone_e164).toBe('+996555008103');
    } finally {
      await c.query('ROLLBACK').catch(() => undefined);
      c.release();
    }
    expect(await svc.maskKioskReceiverPhones()).toEqual({ masked: 1 });
    expect(await receiverOf(busy)).toMatchObject({
      receiver_phone_e164: null,
      receiver_phone_masked: '+996 5** *** *03',
    });
  });

  it('KIOSK-023 retention.daily: one boss.work, drafts purge and masking in one run, a failing task does not stop the other', async () => {
    const f = fakeBoss();
    const audit = new AuditService(t.db);
    const returns = new ReturnsRetentionService(t.db, audit);
    const bridge = new ReturnsJobsBridge(
      { WORKERS_ENABLED: true },
      {} as never,
      returns,
      { start: () => Promise.resolve(), instance: f.boss } as never,
      new OrdersRetentionService(t.db, audit),
    );
    bridge.onApplicationBootstrap();
    await expect.poll(() => f.schedules.length).toBe(1);
    const daily = f.works.filter((w) => w.name === QUEUES.retentionDaily);
    expect(daily).toHaveLength(1);
    expect(f.schedules[0]).toEqual({ name: QUEUES.retentionDaily, cron: '30 3 * * *' });
    const due = await kioskOrder({ created: 92 }, '+996555008104');
    expect(await daily[0].fn([])).toEqual({ deleted: 0, masked: 1 });
    expect(await receiverOf(due)).toMatchObject({
      receiver_phone_e164: null,
      receiver_phone_masked: '+996 5** *** *04',
    });

    // Сбой задачи возвратов: маскирование всё равно выполнено, задание завершается ошибкой (pg-boss повторит).
    const failing = new ReturnsJobsBridge(
      { WORKERS_ENABLED: true },
      {} as never,
      { purgeExpiredDrafts: () => Promise.reject(new Error('сбой задачи возвратов (тест)')) } as never,
      undefined,
      new OrdersRetentionService(t.db, audit),
    );
    const due2 = await kioskOrder({ created: 93 }, '+996555008105');
    await expect(failing.runDaily()).rejects.toThrow('сбой задачи возвратов (тест)');
    expect((await receiverOf(due2)).receiver_phone_masked).toBe('+996 5** *** *05');
    // Без задачи модуля orders (модульный тест моста) — только задача возвратов, как прежде.
    const bare = new ReturnsJobsBridge(
      { WORKERS_ENABLED: true },
      {} as never,
      { purgeExpiredDrafts: () => Promise.resolve({ deleted: 2 }) } as never,
    );
    expect(await bare.runDaily()).toEqual({ deleted: 2 });

    // Мост из контекста Nest (как в pos-worker): OrdersRetentionService — экспорт OrdersModule, внедрён в мост
    // ReturnsModule (06 MOD-024) — задача заявок с планшета в составе runDaily; экземпляр — тот же, что у OrdersModule.
    const due3 = await kioskOrder({ created: 94 }, '+996555008106');
    const wired = t.app.get(ReturnsJobsBridge, { strict: false });
    // + задача ключей Windows Hello (07 §13.3, ADR-116): HelloKeysRepository глобального UsersModule.
    expect(await wired.runDaily()).toEqual({ deleted: 0, masked: 1, helloChallenges: 0, helloKeys: 0 });
    expect((await receiverOf(due3)).receiver_phone_masked).toBe('+996 5** *** *06');
    expect((wired as unknown as { ordersRetention?: unknown }).ordersRetention).toBe(
      t.app.get(OrdersRetentionService, { strict: false }),
    );
  });
});
