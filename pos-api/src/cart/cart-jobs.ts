import { createHash } from 'node:crypto';
import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { PgBoss, Queue } from 'pg-boss';
import type { DbExecutor } from '../common/audit/db-executor.js';
import { CLOCK, type Clock } from '../common/auth/clock.js';
import { DRIZZLE } from '../common/db/database.module.js';
import { type CatalogChangedPayload, QUEUES } from '../common/jobs/contracts/queues.js';
import { NOTIFICATIONS_PORT, type NotificationsPort } from '../common/ports/index.js';
import { rows } from './cart-common.js';
import { discountStateOf, evaluateCart } from './cart-evaluator.js';
import { CartRepository } from './cart.repository.js';
import { CatalogPricingService } from './catalog-pricing.service.js';

/** Корзины, затронутые изменением реплики, обрабатываются пачками (не держим долгую транзакцию). */
const CART_BATCH = 200;

/**
 * Фоновые задачи модуля `cart` (06 §5.2 «Предупреждения», §7.5; 05 SYNC-070; 10 CART-013/014/033):
 * - `catalog.prices-changed` / `catalog.stock-changed` `{variantIds}` — пометка строк корзин `active`/`parked`
 *   (`price_changed`, `stock_insufficient`, `stock_snapshot`) и уведомления владельцу `cart_price_changed` /
 *   `cart_stock_changed` (через `NOTIFICATIONS_PORT`, дедупликация по корзине и составу изменений). Заголовок `carts`
 *   не меняется (иначе `row_version` клиента устареет без действий пользователя — FQ-CART-07);
 * - `cart.parked_expire` (ежечасно) — уведомление автору отложенной корзины за сутки до `expires_at`
 *   (`notification_kind=system`, однократно) и перевод истёкших `parked → cleared` (CART-033, DATA-205).
 * Обработчики идемпотентны. Регистрация в pg-boss — `registerCartJobs` (вызывает композиционный корень worker).
 */
@Injectable()
export class CartJobsHandler {
  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    private readonly repo: CartRepository,
    private readonly pricing: CatalogPricingService,
    @Inject(NOTIFICATIONS_PORT) private readonly notifications: NotificationsPort,
    @Inject(CLOCK) private readonly clock: Clock,
  ) {}

  async catalogChanged(
    kind: 'prices' | 'stock',
    payload: CatalogChangedPayload,
  ): Promise<{ carts: number; notified: number }> {
    const variantIds = [...new Set(payload.variantIds ?? [])].filter((v) => /^[0-9a-f-]{36}$/i.test(v));
    if (variantIds.length === 0) return { carts: 0, notified: 0 };
    const carts = await rows<{ id: string }>(
      this.db,
      sql`SELECT DISTINCT c.id FROM carts c JOIN cart_items i ON i.cart_id = c.id
           WHERE c.status IN ('active', 'parked') AND i.variant_id = ANY(${sql.param(variantIds)}::uuid[])
           LIMIT ${CART_BATCH * 50}`,
    );
    let notified = 0;
    for (const { id } of carts) {
      const cart = await this.repo.findById(this.db, id);
      if (!cart || (cart.status !== 'active' && cart.status !== 'parked')) continue;
      const items = await this.repo.items(this.db, cart.id);
      const quotes = await this.pricing.lineQuotes(this.db, {
        priceListId: cart.price_list_id,
        warehouseId: cart.warehouse_id,
        items: items.map((it) => ({ variantId: it.variant_id, packagingId: it.packaging_id })),
      });
      const e = evaluateCart({
        cart,
        items,
        quotes,
        discount: discountStateOf(cart, cart.requested_discount_percent, false),
        customerDiscountPercent: null,
      });
      const newly: string[] = [];
      for (const l of e.lines) {
        const flag =
          kind === 'prices'
            ? l.conflicts.some((c) => c.kind === 'price_changed')
            : l.conflicts.some((c) => c.kind === 'stock_insufficient');
        const was = kind === 'prices' ? l.item.price_changed : l.item.stock_insufficient;
        if (flag && !was && variantIds.includes(l.item.variant_id)) newly.push(l.item.variant_id);
      }
      await this.repo.setItemFlags(
        this.db,
        e.lines.map((l) => ({
          id: l.item.id,
          priceChanged: l.conflicts.some((c) => c.kind === 'price_changed'),
          stockInsufficient: l.conflicts.some((c) => c.kind === 'stock_insufficient'),
          ...(kind === 'stock' ? { stockSnapshot: l.quote.available } : {}),
        })),
      );
      if (newly.length === 0) continue;
      const sorted = [...new Set(newly)].sort();
      const digest = createHash('sha256').update(sorted.join(',')).digest('hex').slice(0, 16);
      const r = await this.notifications.notify(null, {
        userId: cart.owner_user_id,
        kind: kind === 'prices' ? 'cart_price_changed' : 'cart_stock_changed',
        severity: 'warning',
        title: kind === 'prices' ? 'Цены в корзине изменились' : 'Остатки по корзине изменились',
        body:
          kind === 'prices'
            ? `Изменилась цена позиций: ${sorted.length}. Проверьте корзину перед оформлением.`
            : `Недостаточно на складе позиций: ${sorted.length}. Проверьте корзину перед оформлением.`,
        payload: { cartId: cart.id, cartStatus: cart.status, variantIds: sorted },
        dedupeKey: `${kind === 'prices' ? 'cart_price_changed' : 'cart_stock_changed'}:${cart.id}:${digest}`,
      });
      if (r.created) notified += 1;
    }
    return { carts: carts.length, notified };
  }

  async parkedExpire(): Promise<{ notified: number; cleared: number }> {
    const now = this.clock.now();
    const soon = await rows<{ id: string; owner_user_id: string; name: string | null; expires_at: Date }>(
      this.db,
      sql`SELECT id, owner_user_id, name, expires_at FROM carts
           WHERE status = 'parked' AND expires_at > ${now}::timestamptz
             AND expires_at <= ${new Date(now.getTime() + 86_400_000)}::timestamptz
           ORDER BY expires_at LIMIT ${CART_BATCH}`,
    );
    let notified = 0;
    for (const c of soon) {
      const r = await this.notifications.notify(null, {
        userId: c.owner_user_id,
        kind: 'system',
        severity: 'info',
        title: 'Отложенная корзина скоро будет удалена',
        body: `Отложенная корзина «${c.name ?? 'без имени'}» хранится до ${new Date(c.expires_at).toISOString()}.`,
        payload: { target: 'cart_parked', cartId: c.id },
        dedupeKey: `cart_parked_expire:${c.id}`,
        expiresAt: c.expires_at,
      });
      if (r.created) notified += 1;
    }
    const cleared = await rows<{ id: string }>(
      this.db,
      sql`UPDATE carts SET status = 'cleared', cleared_at = ${now}::timestamptz, row_version = row_version + 1,
                 updated_at = now()
           WHERE status = 'parked' AND expires_at <= ${now}::timestamptz
           RETURNING id`,
    );
    return { notified, cleared: cleared.length };
  }
}

export interface RegisterCartJobsOptions {
  readonly pollingIntervalSeconds: number; // money-double: allow — секунды
  readonly log: { warn(obj: object, msg: string): void; info(obj: object, msg: string): void };
}

/**
 * Регистрация обработчиков `cart` в pg-boss процесса-исполнителя (`WORKERS_ENABLED=true`): очереди
 * `catalog.prices-changed`, `catalog.stock-changed`, `cart.parked_expire` (ежечасно). Вызывает композиционный корень
 * worker (src/worker.ts — владелец не F-be-cart).
 */
export async function registerCartJobs(boss: PgBoss, h: CartJobsHandler, opts: RegisterCartJobsOptions): Promise<void> {
  const specs: readonly { readonly name: string; readonly options: Omit<Queue, 'name'> }[] = [
    { name: QUEUES.catalogPricesChanged, options: { policy: 'standard', retryLimit: 3, retryDelay: 30 } },
    { name: QUEUES.catalogStockChanged, options: { policy: 'standard', retryLimit: 3, retryDelay: 30 } },
    { name: QUEUES.cartParkedExpire, options: { policy: 'singleton', retryLimit: 1, expireInSeconds: 600 } },
  ];
  for (const s of specs) {
    if (!(await boss.getQueue(s.name))) {
      try {
        await boss.createQueue(s.name, s.options);
      } catch (e) {
        if (!(await boss.getQueue(s.name))) throw e;
      }
    }
  }
  const work = { pollingIntervalSeconds: opts.pollingIntervalSeconds, batchSize: 1 };
  await boss.work<CatalogChangedPayload>(QUEUES.catalogPricesChanged, work, async ([job]) =>
    job ? h.catalogChanged('prices', job.data) : undefined,
  );
  await boss.work<CatalogChangedPayload>(QUEUES.catalogStockChanged, work, async ([job]) =>
    job ? h.catalogChanged('stock', job.data) : undefined,
  );
  await boss.work(QUEUES.cartParkedExpire, work, async () => h.parkedExpire());
  await boss
    .schedule(QUEUES.cartParkedExpire, '7 * * * *', {}, { singletonKey: 'cart.parked_expire' })
    .catch((err: unknown) => opts.log.warn({ err }, 'cart.parked_expire: расписание не установлено'));
  opts.log.info({ queues: specs.map((s) => s.name) }, 'cart.jobs.registered');
}
