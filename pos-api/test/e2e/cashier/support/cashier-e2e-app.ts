import { randomUUID } from 'node:crypto';
import pino from 'pino';
import { expect } from 'vitest';
import { AdminModule } from '../../../../src/admin/admin.module.js';
import { CustomersModule } from '../../../../src/customers/customers.module.js';
import type { OnecConfirmedPayload, OnecFailedPayload } from '../../../../src/common/jobs/contracts/queues.js';
import { CustomerOnecResultsHandler } from '../../../../src/customers/jobs/customer-onec-results.handler.js';
import { OutboxDispatcher } from '../../../../src/jobs/outbox/outbox-dispatcher.js';
import { ReturnsModule } from '../../../../src/returns/returns.module.js';
import { OnecOutboxDelivery } from '../../../../src/sync/outbox/onec-outbox.delivery.js';
import { schedulerConfigFromEnv } from '../../../../src/sync/scheduler/scheduler.config.js';
import { TransactionsModule } from '../../../../src/transactions/transactions.module.js';
import { CashierTestApp } from '../../../support/cashier-fixture.js';
import { F_MODULES, type PosActor, type PosFixtureOptions } from '../../../support/pos-fixture.js';

/**
 * Модули приложения для сквозных сценариев этапа G (интеграция backend G, RM-G-009): все модули этапа F (корзина,
 * заказы, платежи с дашбордом кассира, уведомления, документы) и этапа G — `customers` (поиск, карточка, история,
 * долги и решение о продаже в долг, скидки, избранное, привязки), `transactions`, `returns`, `admin` (аудит, отчёты,
 * лимиты скидок, настройки, пользователи). Все порты `common/ports` привязаны реальными реализациями — заглушек нет.
 */
export const G_E2E_MODULES = [...F_MODULES, CustomersModule, TransactionsModule, ReturnsModule, AdminModule];

/**
 * Стенд сквозных сценариев кассира — **тестовые данные**: `CashierTestApp` (embedded PostgreSQL 17, синтетический
 * каталог через конвейер 1С, синтетика кассира в фейке 1С `ScriptedOnecGateway`) с полным набором модулей F+G и
 * диспетчером outbox «как pos-worker» (`OnecOutboxDelivery` → фейк 1С; события `customers.onec-*` применяются
 * обработчиком модуля customers).
 */
export class CashierE2eApp extends CashierTestApp {
  readonly published: { name: string; data: Record<string, unknown> }[] = [];
  dispatcher!: OutboxDispatcher;
  results!: CustomerOnecResultsHandler;
  private handled = 0;

  override async start(opts: PosFixtureOptions = {}): Promise<this> {
    // pg-boss нужен модулям приложения (публикация job: SMS приглашений admin, события outbox); воркеров в процессе
    // теста нет — доставку outbox выполняет `drainOutbox()`.
    await super.start({
      ...opts,
      env: { QR_PROVIDER: 'none', ...(opts.env ?? {}) },
      modules: opts.modules ?? G_E2E_MODULES,
    });
    const log = pino({ level: 'silent' });
    this.results = new CustomerOnecResultsHandler(this.db, log);
    this.dispatcher = new OutboxDispatcher(
      this.pool,
      new OnecOutboxDelivery(this.onec, { timeoutMs: 2_000 }),
      {
        send: (name: string, data: object) => {
          this.published.push({ name, data: data as Record<string, unknown> });
          return Promise.resolve(randomUUID());
        },
      },
      schedulerConfigFromEnv(this.config, {}).outbox,
      'test-cashier-e2e-worker',
      log,
    );
    return this;
  }

  /** Тик диспетчера outbox и применение опубликованных `customers.onec-*` (как pos-worker). */
  async drainOutbox(): Promise<void> {
    await this.pool.query(
      `UPDATE onec_outbox SET next_attempt_at = now() - interval '1 second' WHERE status = 'pending'`,
    );
    await this.dispatcher.tick();
    while (this.handled < this.published.length) {
      const p = this.published[this.handled++];
      if (p.name === 'customers.onec-confirmed')
        await this.results.onConfirmed(p.data as unknown as OnecConfirmedPayload);
      if (p.name === 'customers.onec-failed') await this.results.onFailed(p.data as unknown as OnecFailedPayload);
    }
  }

  /** Корзина актора: вариант × количество, клиент (если задан). */
  async cartFor(
    actor: PosActor,
    variant: { readonly variantId: string; readonly unitId: string },
    customerId: string | null,
    qty = '1',
  ): Promise<CartView> {
    const c0 = (await this.req('get', '/cart', actor)).body as CartView;
    const put = await this.req('put', `/cart/items/${variant.variantId}`, actor).send({
      quantity: { value: qty, unitId: variant.unitId, packagingId: null },
      rowVersion: c0.rowVersion,
      mode: 'set',
    });
    expect(put.status, JSON.stringify(put.body)).toBe(200);
    if (customerId !== null) {
      const cur = (await this.req('get', '/cart', actor)).body as CartView;
      const set = await this.req('post', '/cart/customer', actor).send({ customerId, rowVersion: cur.rowVersion });
      expect(set.status, JSON.stringify(set.body)).toBe(200);
    }
    return (await this.req('get', '/cart', actor)).body as CartView;
  }

  /** `POST /orders` по корзине актора (Idempotency-Key — новый; step-up и доп. поля — опционально). */
  order(
    actor: PosActor,
    cart: CartView,
    variant: { readonly variantId: string; readonly unitId: string },
    paymentMethod: 'cash' | 'qr_bakai' | 'credit',
    qty = '1',
    extra: Record<string, unknown> = {},
    stepUp?: string,
  ) {
    return this.req('post', '/orders', actor, { idem: true, ...(stepUp ? { stepUp } : {}) }).send({
      cartId: cart.id,
      cartRowVersion: cart.rowVersion,
      receiver: { kind: 'customer' },
      delivery: { method: 'pickup' },
      paymentMethod,
      items: [{ variantId: variant.variantId, quantity: { value: qty, unitId: variant.unitId, packagingId: null } }],
      ...extra,
    });
  }
}

export interface CartView {
  readonly id: string;
  readonly rowVersion: number;
  readonly total: { readonly amount: string };
}
