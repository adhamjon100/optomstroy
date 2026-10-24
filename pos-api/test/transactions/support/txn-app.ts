import { randomUUID } from 'node:crypto';
import { expect } from 'vitest';
import { AUDIT_QUERY_PORT } from '../../../src/common/ports/index.js';
import { ReturnsModule } from '../../../src/returns/returns.module.js';
import { TransactionsModule } from '../../../src/transactions/transactions.module.js';
import { CashierTestApp } from '../../support/cashier-fixture.js';
import { InMemoryAuditQuery } from '../../support/cashier-ports.fakes.js';
import { F_MODULES, type PosActor, type PosFixtureOptions } from '../../support/pos-fixture.js';

/**
 * Стенд агента G-be-txn-returns (**тестовые данные**): `CashierTestApp` (embedded PostgreSQL 17, синтетика кассира в
 * фейке 1С) с модулями этапа F (корзина, заказы, платежи с дашбордом и guard оплаты долга, уведомления, документы) и
 * модулями G `transactions`, `returns`. Порт `AUDIT_QUERY_PORT` (реализация — агент G-be-admin-reports) заменён
 * `InMemoryAuditQuery`; журнал `transactions` — реальный (`TransactionJournal`).
 */
export class TxnTestApp extends CashierTestApp {
  readonly auditQuery = new InMemoryAuditQuery();

  async startTxn(opts: PosFixtureOptions = {}): Promise<this> {
    await this.start({
      ...opts,
      env: { QR_PROVIDER: 'none', ...(opts.env ?? {}) },
      modules: opts.modules ?? [...F_MODULES, TransactionsModule, ReturnsModule],
    });
    this.replacePort(AUDIT_QUERY_PORT, this.auditQuery);
    return this;
  }

  /** Заказ через API: корзина сервера → `POST /orders` (201/202). Возвращает тело ответа заказа. */
  async orderViaApi(
    actor: PosActor,
    o: { readonly method: 'cash' | 'qr_bakai'; readonly quantity?: string; readonly customerId?: string } = {
      method: 'cash',
    },
  ): Promise<OrderViaApi> {
    const [v] = await this.saleableVariants(1);
    const before = await this.req('get', '/cart', actor);
    expect(before.status, JSON.stringify(before.body)).toBe(200);
    let rowVersion = (before.body as { rowVersion: number }).rowVersion;
    if (o.customerId) {
      const c = await this.req('post', '/cart/customer', actor).send({ customerId: o.customerId, rowVersion });
      expect(c.status, JSON.stringify(c.body)).toBe(200);
      rowVersion = (c.body as { rowVersion: number }).rowVersion;
    }
    const qty = o.quantity ?? '1';
    const put = await this.req('put', `/cart/items/${v.variantId}`, actor).send({
      quantity: { value: qty, unitId: v.unitId, packagingId: null },
      rowVersion,
    });
    expect(put.status, JSON.stringify(put.body)).toBe(200);
    const cart = (await this.req('get', '/cart', actor)).body as { id: string; rowVersion: number };
    const idemKey = randomUUID();
    const body = {
      cartId: cart.id,
      cartRowVersion: cart.rowVersion,
      receiver: { kind: 'customer' },
      delivery: { method: 'pickup' },
      paymentMethod: o.method,
      items: [{ variantId: v.variantId, quantity: { value: qty, unitId: v.unitId, packagingId: null } }],
    };
    const res = await this.req('post', '/orders', actor, { idem: idemKey }).send(body);
    expect([201, 202], JSON.stringify(res.body)).toContain(res.status);
    const b = res.body as {
      id: string;
      publicNumber: string;
      total: { amount: string };
      payments?: { id: string }[];
    };
    return {
      id: b.id,
      publicNumber: b.publicNumber,
      total: b.total.amount,
      paymentId: b.payments?.[0]?.id ?? null,
      idemKey,
      body,
    };
  }

  /** Повтор `POST /orders` с тем же `Idempotency-Key` и телом (TXN-005): id заказа ответа. */
  async orderViaApiReplay(actor: PosActor, o: OrderViaApi): Promise<string> {
    const res = await this.req('post', '/orders', actor, { idem: o.idemKey }).send(o.body);
    expect([201, 202], JSON.stringify(res.body)).toContain(res.status);
    return (res.body as { id: string }).id;
  }
}

export interface OrderViaApi {
  readonly id: string;
  readonly publicNumber: string;
  readonly total: string;
  readonly paymentId: string | null;
  readonly idemKey: string;
  readonly body: Readonly<Record<string, unknown>>;
}
