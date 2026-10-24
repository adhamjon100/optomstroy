import fc from 'fast-check';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { CartModule } from '../../src/cart/cart.module.js';
import { PAYMENTS_PORT } from '../../src/common/ports/index.js';
import { OrdersModule } from '../../src/orders/orders.module.js';
import type { PosActor, SaleableVariant } from '../support/pos-fixture.js';
import { DbPaymentsPort, OrdersTestApp } from './support/orders-fixture.js';

type Cart = { id: string; rowVersion: number };
type MoneyDto = { amount: string; currency: string };
type Line = { variantId: string; lineTotal: MoneyDto; discountAmount: MoneyDto; unitPrice: MoneyDto };

/**
 * Параметры fast-check (ревью RC-6): по умолчанию 60 прогонов с фиксированным seed — воспроизводимо в CI (≈ 10 с).
 * Ночной/ручной прогон: `ORDERS_PROPERTY_RUNS=<n>` и `ORDERS_PROPERTY_SEED=random` (или число) — seed печатается
 * fast-check при падении для воспроизведения.
 */
function propertyParams(): { numRuns: number; seed?: number; endOnFailure: true } {
  const runsRaw = process.env.ORDERS_PROPERTY_RUNS;
  // money-double: allow — число прогонов и seed, не деньги
  const numRuns = runsRaw && /^\d{1,5}$/.test(runsRaw) && Number(runsRaw) > 0 ? Number(runsRaw) : 60;
  const seedRaw = process.env.ORDERS_PROPERTY_SEED;
  if (seedRaw === 'random') return { numRuns, endOnFailure: true };
  const seed = seedRaw && /^-?\d{1,10}$/.test(seedRaw) ? Number(seedRaw) : 20261023;
  return { numRuns, seed, endOnFailure: true };
}

/**
 * Свойство «предпросмотр ≡ заказ» (12 T-ORD-007; 10 ORD-020; 07 §7.3–7.5) — property-based на **реальной** корзине
 * (`CartModule`, CheckoutPolicy) и `POST /orders` (ревью F-money-rules-9: свойство прежде проверялось только примерами
 * e2e). **Тестовые данные**: embedded PostgreSQL 17, синтетический каталог, случайные цены (до 2 знаков), количества,
 * скидка клиента 1С и ручная скидка в пределах лимита роли `cashier` (seed Q-015: 5 %). Для каждого набора:
 * суммы, скидки и строки созданного заказа совпадают с ответом `checkout-preview`, заказ создан по `previewToken`
 * (итог не разошёлся), Σ lineTotal = total = subtotal − discountTotal. Число прогонов — 60 (каждый — HTTP + БД;
 * см. `propertyParams`).
 */
describe('orders: свойство «предпросмотр ≡ заказ» (T-ORD-007, F-money-rules-9)', () => {
  const t = new OrdersTestApp();
  let cashier: PosActor;
  let pool: SaleableVariant[];

  beforeAll(async () => {
    await t.start({ modules: [CartModule, OrdersModule], fakePorts: true });
    t.replacePort(PAYMENTS_PORT, new DbPaymentsPort(t));
    cashier = await t.actor({ role: 'cashier' });
    pool = await t.saleableVariants(6);
    expect(pool.length).toBeGreaterThanOrEqual(3);
  });
  afterAll(async () => {
    await t.stop();
  });

  // Деньги — целые тыйыны (bigint), без двоичной плавающей точки (D-19).
  const cents = (n: number | bigint) => {
    const v = BigInt(n);
    return `${v / 100n}.${String(v % 100n).padStart(2, '0')}`;
  };
  const toCents = (m: MoneyDto) => {
    const [whole, frac = ''] = m.amount.split('.');
    return BigInt(whole) * 100n + BigInt(frac.padEnd(2, '0').slice(0, 2));
  };
  const sum = (xs: MoneyDto[]) => cents(xs.reduce((s, m) => s + toCents(m), 0n));

  async function current(): Promise<Cart> {
    const r = await t.req('get', '/cart', cashier);
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return r.body as Cart;
  }

  const caseArb = fc.record({
    lines: fc.uniqueArray(
      fc.record({
        idx: fc.integer({ min: 0, max: 5 }),
        qty: fc.integer({ min: 1, max: 9 }),
        priceCents: fc.integer({ min: 1, max: 2_500_000 }),
      }),
      { minLength: 1, maxLength: 3, selector: (l) => l.idx },
    ),
    customerPercentHundredths: fc.integer({ min: 0, max: 2_500 }),
    manualPercentHundredths: fc.integer({ min: 0, max: 500 }),
  });

  it('суммы и строки заказа = ответ checkout-preview; заказ создаётся по previewToken', async () => {
    await fc.assert(
      fc.asyncProperty(caseArb, async (c) => {
        const lines = c.lines.filter((l) => l.idx < pool.length);
        fc.pre(lines.length > 0);
        // Активная корзина — пустая (предыдущая оформлена в заказ); цены — по набору.
        for (const l of lines) await t.setPrice(pool[l.idx].variantId, cents(l.priceCents));
        for (const l of lines) {
          const v = pool[l.idx];
          const before = await current();
          const r = await t.req('put', `/cart/items/${v.variantId}`, cashier).send({
            quantity: { value: String(l.qty), unitId: v.unitId, packagingId: null },
            rowVersion: before.rowVersion,
          });
          expect(r.status, JSON.stringify(r.body)).toBe(200);
        }
        const customerId = await t.createOnecCustomer({ discountPercent: cents(c.customerPercentHundredths) });
        const c0 = await current();
        const bound = await t.req('post', '/cart/customer', cashier).send({ customerId, rowVersion: c0.rowVersion });
        expect(bound.status, JSON.stringify(bound.body)).toBe(200);
        const cart = await current();
        const manual = cents(c.manualPercentHundredths);
        const common = {
          cartId: cart.id,
          cartRowVersion: cart.rowVersion,
          paymentMethod: 'cash',
          receiver: { kind: 'customer' },
          delivery: { method: 'pickup' },
          manualDiscountPercent: manual,
        };
        const pv = await t.req('post', '/cart/checkout-preview', cashier).send(common);
        expect(pv.status, JSON.stringify(pv.body)).toBe(200);
        expect(pv.body.ok, JSON.stringify(pv.body)).toBe(true);
        const items = lines.map((l) => ({
          variantId: pool[l.idx].variantId,
          quantity: { value: String(l.qty), unitId: pool[l.idx].unitId, packagingId: null },
        }));
        const created = await t
          .req('post', '/orders', cashier, { idem: true })
          .send({ ...common, items, previewToken: pv.body.previewToken });
        expect([201, 202], JSON.stringify(created.body)).toContain(created.status);
        const id = (created.body as { id: string }).id;
        const order = await t.req('get', `/orders/${id}`, cashier);
        expect(order.status, JSON.stringify(order.body)).toBe(200);
        const o = order.body as Record<string, unknown> & { items: Line[] };
        const p = pv.body as Record<string, unknown> & { items: Line[] };
        for (const k of [
          'subtotal',
          'discountTotal',
          'customerDiscountTotal',
          'total',
          'totalToPay',
          'discountPercent',
        ])
          expect(o[k], k).toEqual(p[k]);
        expect(created.body.total).toEqual(p.total);
        const strip = (xs: Line[]) =>
          xs
            .map((x) => ({
              variantId: x.variantId,
              unitPrice: x.unitPrice,
              discountAmount: x.discountAmount,
              lineTotal: x.lineTotal,
            }))
            .sort((a, b) => a.variantId.localeCompare(b.variantId));
        expect(strip(o.items)).toEqual(strip(p.items));
        // Инварианты денег 07 §7.5 на сохранённом заказе.
        expect(sum(o.items.map((x) => x.lineTotal))).toBe((o.total as MoneyDto).amount);
        expect(cents(toCents(o.subtotal as MoneyDto) - toCents(o.discountTotal as MoneyDto))).toBe(
          (o.total as MoneyDto).amount,
        );
      }),
      propertyParams(),
    );
  });
});
