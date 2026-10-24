import { CartModule } from '../../src/cart/cart.module.js';
import type { FixedClock } from '../../src/common/auth/clock.js';
import { type PosActor, PosTestApp } from '../support/pos-fixture.js';

/**
 * Помощники тестов корзины (F-be-cart) поверх стенда `pos-fixture` — **тестовые данные**. Приложение поднимается
 * только с `CartModule` (модули orders/payments/документов — других агентов); прочие порты — заглушки
 * (`fakePorts: true`: уведомления — `InMemoryNotifications`), `InventoryCheckPort` — адаптер этапа E.
 */
export async function startCartApp(
  opts: { env?: Record<string, string>; clock?: FixedClock; skuCount?: number } = {},
): Promise<PosTestApp> {
  return new PosTestApp().start({
    env: { QR_PROVIDER: 'none', ...opts.env },
    modules: [CartModule],
    fakePorts: true,
    jobs: false,
    ...(opts.clock ? { clock: opts.clock } : {}),
    ...(opts.skuCount ? { skuCount: opts.skuCount } : {}),
  });
}

export interface CartBody {
  id: string;
  status: string;
  rowVersion: number;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- тело ответа API в тестах
  items: Record<string, any>[];
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- тело ответа API в тестах
  warnings: Record<string, any>[];
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- тело ответа API в тестах
  [k: string]: any;
}

export async function getCart(t: PosTestApp, a: PosActor): Promise<CartBody> {
  const res = await t.req('get', '/cart', a);
  if (res.status !== 200) throw new Error(`GET /cart → ${res.status} ${JSON.stringify(res.body)}`);
  return res.body as CartBody;
}

/** `PUT /cart/items/{variantId}` mode=set с актуальной версией (ошибка — исключение). */
export async function setItem(
  t: PosTestApp,
  a: PosActor,
  v: { variantId: string; unitId: string },
  value: string,
  packagingId: string | null = null,
  unitId?: string,
): Promise<CartBody> {
  const cart = await getCart(t, a);
  const res = await t
    .req('put', `/cart/items/${v.variantId}`, a)
    .send({ quantity: { value, unitId: unitId ?? v.unitId, packagingId }, rowVersion: cart.rowVersion });
  if (res.status !== 200) throw new Error(`PUT item → ${res.status} ${JSON.stringify(res.body)}`);
  return res.body as CartBody;
}

/** Вариант с упаковкой товара (`packagings.product_id`), ценой в виде цены по умолчанию и остатком. */
export async function variantWithPackaging(t: PosTestApp): Promise<{
  variantId: string;
  unitId: string;
  packagingId: string;
  packagingUnitId: string;
  factor: string;
  price: string;
}> {
  const pl = await t.defaultPriceListId();
  const wh = await t.defaultWarehouseId();
  const r = await t.q<{
    variant_id: string;
    unit_id: string;
    packaging_id: string;
    pk_unit: string;
    factor: string;
    price: string;
  }>(
    `SELECT v.id AS variant_id, p.base_unit_id AS unit_id, k.id AS packaging_id, k.unit_id AS pk_unit,
            k.factor::text AS factor, pr.price::text AS price
       FROM product_variants v JOIN products p ON p.id = v.product_id
       JOIN packagings k ON k.product_id = p.id AND NOT k.deletion_mark
       JOIN prices pr ON pr.variant_id = v.id AND pr.price_list_id = $1 AND pr.packaging_id IS NULL
       JOIN stock_balances sb ON sb.variant_id = v.id AND sb.warehouse_id = $2 AND sb.available > 100
       JOIN units u ON u.id = p.base_unit_id
      WHERE NOT v.deletion_mark AND NOT p.deletion_mark AND p.is_sellable AND v.is_default = NOT p.has_variants
        AND p.multiplicity IS NULL AND p.min_qty IS NULL AND k.factor = round(k.factor) AND k.factor > 1
      ORDER BY p.name, v.id LIMIT 1`,
    [pl, wh],
  );
  const row = r[0];
  if (!row) throw new Error('нет варианта с упаковкой в синтетическом каталоге');
  return {
    variantId: row.variant_id,
    unitId: row.unit_id,
    packagingId: row.packaging_id,
    packagingUnitId: row.pk_unit,
    factor: row.factor,
    price: row.price,
  };
}
