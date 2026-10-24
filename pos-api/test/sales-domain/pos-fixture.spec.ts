import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { FixedClock } from '../../src/common/auth/clock.js';
import { INVENTORY_CHECK_PORT, SALES_PORT_TOKENS } from '../../src/common/ports/index.js';
import { type PosActor, PosTestApp, RETAIL_CUSTOMER_ID } from '../support/pos-fixture.js';

/**
 * Стенд этапа F (`test/support/pos-fixture.ts`) на embedded PostgreSQL 17 — **тестовые данные**: приложение
 * поднимается со всеми модулями F и портами, пользователи всех ролей аутентифицируются, step-up токен принимается
 * единым верификатором, seed лимитов скидок и «Розничного покупателя» применён, заказы в разных статусах проходят
 * CHECK/триггеры БД, порт `InventoryCheckPort` (адаптер этапа E) работает через реестр.
 */
describe('PosTestApp (pos-fixture)', () => {
  const t = new PosTestApp();
  const clock = new FixedClock(new Date());
  let a: Record<'seller' | 'cashier' | 'senior_seller' | 'admin' | 'owner' | 'customer', PosActor>;

  beforeAll(async () => {
    await t.start({ env: { QR_PROVIDER: 'none' }, clock });
    a = await t.actors();
  });
  afterAll(async () => {
    await t.stop();
  });

  it('seed: лимиты скидок по ролям (Q-015), «Розничный покупатель», вид цены по умолчанию', async () => {
    const limits = await t.q<{ role: string; max_percent: string }>(
      `SELECT role::text, max_percent::text FROM role_discount_limits ORDER BY role`,
    );
    expect(Object.fromEntries(limits.map((l) => [l.role, l.max_percent]))).toMatchObject({
      seller: '5.00',
      cashier: '5.00',
      senior_seller: '10.00',
      admin: '15.00',
      owner: '0.00',
      customer: '0.00',
    });
    const retail = await t.q<{ is_retail_default: boolean; credit_allowed: boolean }>(
      `SELECT is_retail_default, credit_allowed FROM customers WHERE id = $1`,
      [RETAIL_CUSTOMER_ID],
    );
    expect(retail[0]).toEqual({ is_retail_default: true, credit_allowed: false });
    expect(await t.defaultPriceListId()).toMatch(/^[0-9a-f-]{36}$/);
  });

  it('все роли аутентифицируются (GET /catalog/products), токен без субъекта — 401', async () => {
    for (const role of ['seller', 'cashier', 'senior_seller', 'admin', 'owner', 'customer'] as const) {
      const res = await t.req('get', '/catalog/products?limit=1', a[role]);
      expect(res.status, role).toBe(200);
    }
    expect((await t.req('get', '/catalog/products?limit=1')).status).toBe(401);
  });

  it('модули этапа F и порты подключены; InventoryCheckPort привязан адаптером этапа E', () => {
    for (const token of SALES_PORT_TOKENS) expect(t.app.get(token, { strict: false })).toBeDefined();
    expect(t.registry.isBound(INVENTORY_CHECK_PORT)).toBe(true);
    expect(t.config.QR_PROVIDER).toBe('none');
  });

  it('InventoryCheckPort: достаточно → ok; сверх остатка → shortages', async () => {
    const [v] = await t.saleableVariants(1);
    const port = t.registry.get(INVENTORY_CHECK_PORT);
    const actor = { userId: a.cashier.userId, roles: ['cashier'], isCustomer: false };
    const ok = await port.check(actor, {
      warehouseId: v.warehouseId,
      items: [{ variantId: v.variantId, value: '1', unitId: v.unitId, packagingId: null }],
    });
    expect(ok.ok).toBe(true);
    await t.setStock(v.variantId, '2', v.warehouseId);
    const short = await port.check(actor, {
      warehouseId: v.warehouseId,
      items: [{ variantId: v.variantId, value: '3', unitId: v.unitId, packagingId: null }],
    });
    expect(short.ok).toBe(false);
    expect(short.shortages[0]).toMatchObject({ variantId: v.variantId, available: '2.000' });
  });

  it('step-up токен принимается верификатором этапа D (тот же формат, что POST /auth/step-up)', async () => {
    const { StepUpTokenVerifier } = await import('../../src/auth/step-up/step-up-token.verifier.js');
    const { JwtService } = await import('../../src/common/auth/jwt.service.js');
    const { TokenDenylistRepository } = await import('../../src/users/token-denylist.repository.js');
    const verifier = new StepUpTokenVerifier(t.jwt, t.app.get(TokenDenylistRepository), clock);
    expect(t.jwt).toBeInstanceOf(JwtService);
    const token = await t.stepUp(a.cashier, 'payment.void');
    const principal = {
      userId: a.cashier.userId,
      kind: 'staff',
      roles: ['cashier'],
      sessionId: a.cashier.sessionId,
      deviceId: a.cashier.deviceKey,
      permissionsVersion: (
        await t.q<{ v: number }>('SELECT permissions_version AS v FROM users WHERE id = $1', [a.cashier.userId])
      )[0].v,
    };
    const v = await verifier.verify(token, principal as never, { operation: 'payment.void' });
    expect(v.method).toBe('pin');
    await expect(verifier.verify(token, principal as never, { operation: 'order.onec_link' })).rejects.toMatchObject({
      code: 'STEP_UP_REQUIRED',
    });
  });

  it('клиент 1С с долгом и лимитом; привязка клиента-пользователя', async () => {
    const id = await t.createOnecCustomer({
      creditAllowed: true,
      creditLimit: '100000.00',
      discountPercent: '5.00',
      receivables: { balance: '20000.00', overdue: '0.00', ageMinutes: 10 },
    });
    const r = await t.q<{ credit_limit: string; balance: string; overdue_amount: string; age: number }>(
      `SELECT c.credit_limit::text, r.balance::text, r.overdue_amount::text,
              extract(epoch FROM now() - r.onec_snapshot_at)::int / 60 AS age
         FROM customers c JOIN receivables r ON r.customer_id = c.id WHERE c.id = $1`,
      [id],
    );
    expect(r[0]).toMatchObject({ credit_limit: '100000.00', balance: '20000.00', overdue_amount: '0.00' });
    expect(r[0].age).toBeGreaterThanOrEqual(9);
    await t.linkCustomer(a.customer.userId, id, 'confirmed');
    const unknownOverdue = await t.createOnecCustomer({ receivables: { balance: '1.00', overdue: null } });
    expect(
      (
        await t.q<{ o: string | null }>(`SELECT overdue_amount AS o FROM receivables WHERE customer_id = $1`, [
          unknownOverdue,
        ])
      )[0]?.o,
    ).toBeNull();
  });

  it.each(['submitting', 'awaiting_payment', 'pending_approval', 'awaiting_shipment', 'submit_failed'] as const)(
    'seedOrder в статусе %s проходит CHECK и триггеры БД (Σ строк = итог)',
    async (status) => {
      const o = await t.seedOrder({
        createdBy: a.cashier,
        method: status === 'pending_approval' ? 'credit' : 'cash',
        status,
        discountPercent: '5',
      });
      const row = await t.q<{ status: string; total: string; sum: string; pay: string; ob: string; sync: string }>(
        `SELECT o.status::text, o.total::text, (SELECT sum(line_total)::text FROM order_items WHERE order_id = o.id) AS sum,
                (SELECT status::text FROM payments WHERE order_id = o.id) AS pay,
                (SELECT status::text FROM onec_outbox WHERE aggregate_id = o.id) AS ob, o.onec_sync_state::text AS sync
           FROM orders o WHERE o.id = $1`,
        [o.orderId],
      );
      expect(row[0]).toMatchObject({ status, total: o.total, sum: o.total });
      expect(row[0].ob).toBe(status === 'submitting' ? 'pending' : status === 'submit_failed' ? 'failed' : 'sent');
      expect(o.publicNumber).toMatch(/^POS-\d{4}-\d{6}$/);
    },
  );

  it('ONEC_GATEWAY в приложении — управляемый фейк; QR_PROVIDER=none', async () => {
    const { ONEC_GATEWAY } = await import('../../src/integrations/onec/onec-gateway.js');
    expect(t.app.get(ONEC_GATEWAY, { strict: false })).toBe(t.onec);
  });
});
