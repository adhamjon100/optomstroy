import pino from 'pino';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { CartJobsHandler, registerCartJobs } from '../../src/cart/cart-jobs.js';
import { CartModule } from '../../src/cart/cart.module.js';
import { PgBossService } from '../../src/common/jobs/pg-boss.service.js';
import type { ApplyScope, EntityCounts } from '../../src/sync/apply/apply.types.js';
import {
  PgBossCatalogChangePublisher,
  newCatalogChangeSink,
  publishCatalogChanges,
} from '../../src/sync/apply/catalog-change-publisher.js';
import { applyPriceRows, applyStockRows } from '../../src/sync/apply/catalog-slices.js';
import type { SyncEntity } from '../../src/common/enums.js';
import { PosTestApp, type SaleableVariant } from '../support/pos-fixture.js';
import { setItem } from './cart-support.js';

/**
 * Сквозной путь «синхронизация 1С меняет цену/остаток → задача `catalog.*-changed` в транзакции применения →
 * обработчик корзин → флаг строки и одно уведомление владельцу» (05 SYNC-070, AC-SYNC-070; 06 §7.5; 12 T-NOTIF-002,
 * T-CART-006; ревью F-trace-3, FQ-INT-02) — **тестовые данные**: embedded PostgreSQL, pg-boss стенда, срез цен и
 * остатков применяется функциями конвейера этапа E (`applyPriceRows`, `applyStockRows`).
 */
describe('cart ← синхронизация каталога (catalog.prices-changed / catalog.stock-changed)', () => {
  let t: PosTestApp;
  let v: SaleableVariant;
  const log = pino({ level: 'silent' });
  const publisher = new PgBossCatalogChangePublisher(log);

  beforeAll(async () => {
    t = await new PosTestApp().start({ env: { QR_PROVIDER: 'none' }, modules: [CartModule], fakePorts: true });
    const boss = t.app.get(PgBossService, { strict: false }).instance!;
    await registerCartJobs(boss, t.app.get(CartJobsHandler, { strict: false }), {
      pollingIntervalSeconds: 0.5, // money-double: allow — секунды
      log: { warn: () => undefined, info: () => undefined },
    });
    publisher.attach(boss);
    [v] = await t.saleableVariants(1);
  });
  afterAll(async () => {
    await t?.stop();
  });

  /** Транзакция применения среза (как `CatalogFullLoadService.inTx`): запись реплики + публикация перед COMMIT. */
  async function applySlice(fn: (scope: ApplyScope) => Promise<void>) {
    const client = await t.pool.connect();
    try {
      await client.query('BEGIN');
      const counts = new Map<SyncEntity, EntityCounts>();
      const scope: ApplyScope & { catalogChanges: ReturnType<typeof newCatalogChangeSink> } = {
        client,
        runIdFor: () => Promise.resolve('00000000-0000-7000-8000-000000000000'),
        syncedAt: new Date(),
        counts,
        errors: [],
        catalogChanges: newCatalogChangeSink(),
      };
      await fn(scope);
      await publishCatalogChanges(publisher, client, scope.catalogChanges);
      await client.query('COMMIT');
      return scope.catalogChanges;
    } catch (e) {
      await client.query('ROLLBACK');
      throw e;
    } finally {
      client.release();
    }
  }

  async function until(check: () => Promise<boolean>, ms = 15_000): Promise<void> {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      if (await check()) return;
      await new Promise((r) => setTimeout(r, 200));
    }
    throw new Error('ожидание обработки задачи истекло');
  }

  it('новая цена варианта из корзины → флаг price_changed и одно уведомление cart_price_changed; повтор без изменений — без задачи', async () => {
    const s = await t.actor({ role: 'seller' });
    const cart = await setItem(t, s, v, '2');
    const refs = await t.q<{ pl: string; product: string; variant: string | null }>(
      `SELECT pl.onec_ref::text AS pl, p.onec_ref::text AS product,
              CASE WHEN p.has_variants THEN pv.onec_ref::text END AS variant
         FROM product_variants pv JOIN products p ON p.id = pv.product_id
         JOIN price_lists pl ON pl.id = $2::uuid
        WHERE pv.id = $1::uuid`,
      [v.variantId, await t.defaultPriceListId()],
    );
    const r = refs[0];
    const row = {
      priceListRef: r.pl,
      productRef: r.product,
      variantRef: r.variant,
      packagingRef: null,
      price: '7777.77',
    };
    const changed = await applySlice((scope) => applyPriceRows(scope, [row]));
    expect([...changed.prices]).toEqual([v.variantId]);
    await until(() =>
      Promise.resolve(t.fakes!.notifications.of(s.userId).some((n) => n.kind === 'cart_price_changed')),
    );
    const flags = await t.q<{ price_changed: boolean }>(`SELECT price_changed FROM cart_items WHERE cart_id = $1`, [
      cart.id,
    ]);
    expect(flags[0].price_changed).toBe(true);
    expect(t.fakes!.notifications.of(s.userId).filter((n) => n.kind === 'cart_price_changed')).toHaveLength(1);
    // Тот же срез повторно (source_hash не изменился) — строка не перезаписана, задачи нет.
    const again = await applySlice((scope) => applyPriceRows(scope, [row]));
    expect(again.prices.size).toBe(0);
  });

  it('изменение остатка варианта из корзины → уведомление cart_stock_changed', async () => {
    const s = await t.actor({ role: 'seller' });
    await setItem(t, s, v, '5');
    const refs = await t.q<{ wh: string; product: string; variant: string | null }>(
      `SELECT w.onec_ref::text AS wh, p.onec_ref::text AS product,
              CASE WHEN p.has_variants THEN pv.onec_ref::text END AS variant
         FROM product_variants pv JOIN products p ON p.id = pv.product_id JOIN warehouses w ON w.id = $2::uuid
        WHERE pv.id = $1::uuid`,
      [v.variantId, v.warehouseId],
    );
    const r = refs[0];
    const changed = await applySlice((scope) =>
      applyStockRows(scope, [
        {
          warehouseRef: r.wh,
          productRef: r.product,
          variantRef: r.variant,
          onHand: '1.000',
          reserved: '0.000',
          available: null,
        },
      ]),
    );
    expect([...changed.stock]).toEqual([v.variantId]);
    await until(() =>
      Promise.resolve(t.fakes!.notifications.of(s.userId).some((n) => n.kind === 'cart_stock_changed')),
    );
  });
});
