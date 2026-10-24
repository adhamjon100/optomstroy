import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { DbExecutor } from '../common/audit/db-executor.js';
import { DRIZZLE } from '../common/db/database.module.js';
import type { CartStatus } from '../common/enums.js';
import { rows } from './cart-common.js';

/** Строка `carts` (07 §5.35 + 0009: получатель, причина подтверждения скидки). */
export interface CartRow {
  readonly id: string;
  readonly owner_user_id: string;
  readonly created_by_user_id: string;
  readonly customer_id: string | null;
  readonly warehouse_id: string;
  readonly price_list_id: string;
  readonly status: CartStatus;
  readonly name: string | null;
  /** `NUMERIC(5,2)` строкой. */
  readonly requested_discount_percent: string;
  readonly discount_approved_by_user_id: string | null;
  readonly discount_approved_at: Date | null;
  readonly discount_override_reason: string | null;
  readonly receiver_kind: 'customer' | 'other_person';
  readonly receiver_name: string | null;
  readonly receiver_phone_e164: string | null;
  readonly restored_from_order_id: string | null;
  /**
   * Номер и причина отказа 1С заказа `restored_from_order_id` (OpenAPI 1.2.0 `Cart.restoredFromOrder`; 08 §3.8
   * «Уточнения CheckoutPreview и Cart» п. 4; FQ-CART-05 (fe)) — подзапрос к `orders`; `null` — корзина не восстановлена.
   */
  readonly restored_order_number?: string | null;
  readonly restored_order_reason?: string | null;
  readonly converted_order_id: string | null;
  readonly parked_at: Date | null;
  readonly resumed_at: Date | null;
  readonly cleared_at: Date | null;
  readonly expires_at: Date | null;
  readonly last_price_check_at: Date | null;
  readonly row_version: number;
  readonly created_at: Date;
  readonly updated_at: Date;
}

/** Строка `cart_items` (07 §5.36); количества и цены — NUMERIC-строки. */
export interface CartItemRow {
  readonly id: string;
  readonly cart_id: string;
  readonly variant_id: string;
  readonly packaging_id: string | null;
  readonly quantity: string;
  readonly base_quantity: string;
  readonly price_snapshot: string;
  readonly stock_snapshot: string | null;
  readonly price_changed: boolean;
  readonly stock_insufficient: boolean;
  readonly line_no: number;
  readonly added_at: Date;
}

const CART_COLUMNS =
  sql.raw(`id, owner_user_id, created_by_user_id, customer_id, warehouse_id, price_list_id, status::text AS status,
  name, requested_discount_percent::text AS requested_discount_percent, discount_approved_by_user_id, discount_approved_at,
  discount_override_reason, receiver_kind::text AS receiver_kind, receiver_name, receiver_phone_e164,
  restored_from_order_id, converted_order_id, parked_at, resumed_at, cleared_at, expires_at, last_price_check_at,
  row_version, created_at, updated_at,
  (SELECT o.public_number FROM orders o WHERE o.id = carts.restored_from_order_id) AS restored_order_number,
  (SELECT o.submit_error_message FROM orders o WHERE o.id = carts.restored_from_order_id) AS restored_order_reason`);

const ITEM_COLUMNS = sql.raw(`id, cart_id, variant_id, packaging_id, quantity::text AS quantity,
  base_quantity::text AS base_quantity, price_snapshot::text AS price_snapshot, stock_snapshot::text AS stock_snapshot,
  price_changed, stock_insufficient, line_no, added_at`);

/** Изменяемые поля заголовка корзины (UPDATE всегда увеличивает `row_version` ровно на 1 — триггер 07 §8.3). */
export interface CartPatch {
  readonly customer_id?: string | null;
  readonly warehouse_id?: string;
  readonly price_list_id?: string;
  readonly status?: CartStatus;
  readonly name?: string | null;
  readonly requested_discount_percent?: string;
  readonly discount_approved_by_user_id?: string | null;
  readonly discount_approved_at?: Date | null;
  readonly discount_override_reason?: string | null;
  readonly receiver_kind?: 'customer' | 'other_person';
  readonly receiver_name?: string | null;
  readonly receiver_phone_e164?: string | null;
  readonly owner_user_id?: string;
  readonly converted_order_id?: string | null;
  readonly parked_at?: Date | null;
  readonly resumed_at?: Date | null;
  readonly cleared_at?: Date | null;
  readonly expires_at?: Date | null;
  readonly last_price_check_at?: Date | null;
  readonly items_count_cache?: number;
  readonly subtotal_cache?: string;
}

const PATCH_CASTS: Readonly<Record<keyof CartPatch, string>> = {
  customer_id: 'uuid',
  warehouse_id: 'uuid',
  price_list_id: 'uuid',
  status: 'cart_status',
  name: 'text',
  requested_discount_percent: 'numeric',
  discount_approved_by_user_id: 'uuid',
  discount_approved_at: 'timestamptz',
  discount_override_reason: 'text',
  receiver_kind: 'receiver_kind',
  receiver_name: 'text',
  receiver_phone_e164: 'text',
  owner_user_id: 'uuid',
  converted_order_id: 'uuid',
  parked_at: 'timestamptz',
  resumed_at: 'timestamptz',
  cleared_at: 'timestamptz',
  expires_at: 'timestamptz',
  last_price_check_at: 'timestamptz',
  items_count_cache: 'integer',
  subtotal_cache: 'numeric',
};

export interface NewCart {
  readonly ownerUserId: string;
  readonly createdByUserId: string;
  /** `X-Device-Id` (= `devices.device_key`); `carts.device_id` — `devices.id` этого пользователя (если найден). */
  readonly deviceKey: string | null;
  readonly customerId: string | null;
  readonly warehouseId: string;
  readonly priceListId: string;
  readonly status: 'active' | 'parked';
  readonly name?: string | null;
  readonly requestedDiscountPercent?: string;
  readonly restoredFromOrderId?: string | null;
  readonly parkedAt?: Date | null;
  readonly expiresAt?: Date | null;
}

export interface NewItem {
  readonly variantId: string;
  readonly packagingId: string | null;
  readonly quantity: string;
  readonly baseQuantity: string;
  readonly priceSnapshot: string;
  readonly stockSnapshot: string | null;
  readonly lineNo: number;
}

/**
 * Доступ к `carts`/`cart_items` (07 §5.35–§5.36). Оптимистическая блокировка — `row_version` (+1 в каждом UPDATE
 * заголовка); строки корзины меняются только вместе с заголовком в одной транзакции. Денормализация
 * `items_count_cache`/`subtotal_cache` обновляется сервисом при каждом изменении состава.
 */
@Injectable()
export class CartRepository {
  constructor(@Inject(DRIZZLE) readonly db: DbExecutor) {}

  async findActive(ex: DbExecutor, ownerUserId: string, forUpdate = false): Promise<CartRow | null> {
    const r = await rows<CartRow>(
      ex,
      sql`SELECT ${CART_COLUMNS} FROM carts WHERE owner_user_id = ${ownerUserId}::uuid AND status = 'active'
           ${forUpdate ? sql`FOR UPDATE` : sql``}`,
    );
    return r[0] ?? null;
  }

  async findById(ex: DbExecutor, id: string, forUpdate = false): Promise<CartRow | null> {
    const r = await rows<CartRow>(
      ex,
      sql`SELECT ${CART_COLUMNS} FROM carts WHERE id = ${id}::uuid ${forUpdate ? sql`FOR UPDATE` : sql``}`,
    );
    return r[0] ?? null;
  }

  async findRestored(ex: DbExecutor, orderId: string, ownerUserId: string): Promise<CartRow | null> {
    const r = await rows<CartRow>(
      ex,
      sql`SELECT ${CART_COLUMNS} FROM carts
           WHERE restored_from_order_id = ${orderId}::uuid AND owner_user_id = ${ownerUserId}::uuid
             AND status IN ('active', 'parked')
           ORDER BY created_at DESC LIMIT 1`,
    );
    return r[0] ?? null;
  }

  /** Вставка корзины; для `active` при гонке (уже есть active) — `null` (частичный UNIQUE `carts_active_uq`). */
  async insert(ex: DbExecutor, c: NewCart): Promise<CartRow | null> {
    const r = await rows<CartRow>(
      ex,
      sql`INSERT INTO carts (owner_user_id, created_by_user_id, device_id, customer_id, warehouse_id, price_list_id,
                             status, name, requested_discount_percent, restored_from_order_id, parked_at, expires_at)
          VALUES (${c.ownerUserId}::uuid, ${c.createdByUserId}::uuid,
                  (SELECT d.id FROM devices d WHERE d.device_key = ${c.deviceKey} AND d.user_id = ${c.ownerUserId}::uuid LIMIT 1),
                  ${c.customerId}::uuid,
                  ${c.warehouseId}::uuid, ${c.priceListId}::uuid, ${c.status}::cart_status, ${c.name ?? null},
                  ${c.requestedDiscountPercent ?? '0'}::numeric, ${c.restoredFromOrderId ?? null}::uuid,
                  ${c.parkedAt ?? null}::timestamptz, ${c.expiresAt ?? null}::timestamptz)
          ON CONFLICT (owner_user_id) WHERE status = 'active' DO NOTHING
          RETURNING ${CART_COLUMNS}`,
    );
    return r[0] ?? null;
  }

  /** UPDATE заголовка с проверкой версии: `row_version = expected + 1`; `null` — версия не совпала. */
  async update(ex: DbExecutor, id: string, expectedVersion: number, patch: CartPatch): Promise<CartRow | null> {
    const sets = [sql`row_version = row_version + 1`, sql`updated_at = now()`];
    for (const [k, v] of Object.entries(patch) as [keyof CartPatch, unknown][]) {
      if (v === undefined) continue;
      sets.push(sql`${sql.identifier(k)} = ${v}::${sql.raw(PATCH_CASTS[k])}`);
    }
    const r = await rows<CartRow>(
      ex,
      sql`UPDATE carts SET ${sql.join(sets, sql`, `)}
           WHERE id = ${id}::uuid AND row_version = ${expectedVersion}
           RETURNING ${CART_COLUMNS}`,
    );
    return r[0] ?? null;
  }

  async items(ex: DbExecutor, cartId: string): Promise<CartItemRow[]> {
    return rows<CartItemRow>(
      ex,
      sql`SELECT ${ITEM_COLUMNS} FROM cart_items WHERE cart_id = ${cartId}::uuid ORDER BY line_no, id`,
    );
  }

  async itemsOf(ex: DbExecutor, cartIds: readonly string[]): Promise<Map<string, CartItemRow[]>> {
    const out = new Map<string, CartItemRow[]>();
    if (cartIds.length === 0) return out;
    const r = await rows<CartItemRow>(
      ex,
      sql`SELECT ${ITEM_COLUMNS} FROM cart_items WHERE cart_id = ANY(${sql.param([...cartIds])}::uuid[])
           ORDER BY cart_id, line_no, id`,
    );
    for (const it of r) {
      const list = out.get(it.cart_id) ?? [];
      list.push(it);
      out.set(it.cart_id, list);
    }
    return out;
  }

  async insertItems(ex: DbExecutor, cartId: string, items: readonly NewItem[]): Promise<void> {
    for (const it of items) {
      await ex.execute(
        sql`INSERT INTO cart_items (cart_id, variant_id, packaging_id, quantity, base_quantity, price_snapshot,
                                    stock_snapshot, line_no)
            VALUES (${cartId}::uuid, ${it.variantId}::uuid, ${it.packagingId}::uuid, ${it.quantity}::numeric,
                    ${it.baseQuantity}::numeric, ${it.priceSnapshot}::numeric, ${it.stockSnapshot}::numeric, ${it.lineNo})`,
      );
    }
  }

  async updateItem(
    ex: DbExecutor,
    itemId: string,
    p: { quantity: string; baseQuantity: string; priceSnapshot?: string; stockSnapshot: string | null },
  ): Promise<void> {
    await ex.execute(
      sql`UPDATE cart_items SET quantity = ${p.quantity}::numeric, base_quantity = ${p.baseQuantity}::numeric,
             ${p.priceSnapshot !== undefined ? sql`price_snapshot = ${p.priceSnapshot}::numeric, price_changed = false,` : sql``}
             stock_snapshot = ${p.stockSnapshot}::numeric, updated_at = now()
           WHERE id = ${itemId}::uuid`,
    );
  }

  async deleteItems(
    ex: DbExecutor,
    cartId: string,
    variantId: string,
    packagingId: string | null | undefined,
  ): Promise<number> {
    const res = await ex.execute(
      packagingId === undefined
        ? sql`DELETE FROM cart_items WHERE cart_id = ${cartId}::uuid AND variant_id = ${variantId}::uuid`
        : sql`DELETE FROM cart_items WHERE cart_id = ${cartId}::uuid AND variant_id = ${variantId}::uuid
                AND packaging_id IS NOT DISTINCT FROM ${packagingId}::uuid`,
    );
    return res.rowCount ?? 0;
  }

  /** Флаги строк после сверки цен/остатков (`price_changed`, `stock_insufficient`, снимок остатка). */
  async setItemFlags(
    ex: DbExecutor,
    flags: readonly { id: string; priceChanged: boolean; stockInsufficient: boolean; stockSnapshot?: string | null }[],
  ): Promise<void> {
    for (const f of flags) {
      await ex.execute(
        sql`UPDATE cart_items SET price_changed = ${f.priceChanged}, stock_insufficient = ${f.stockInsufficient},
               ${f.stockSnapshot !== undefined ? sql`stock_snapshot = ${f.stockSnapshot}::numeric,` : sql``} updated_at = now()
             WHERE id = ${f.id}::uuid
               AND (price_changed IS DISTINCT FROM ${f.priceChanged} OR stock_insufficient IS DISTINCT FROM ${f.stockInsufficient}
                    ${f.stockSnapshot !== undefined ? sql`OR stock_snapshot IS DISTINCT FROM ${f.stockSnapshot}::numeric` : sql``})`,
      );
    }
  }

  /** Склад корзины по умолчанию: настройки профиля → `home_warehouse_id` → `is_default_for_pos` → первый активный. */
  async defaultWarehouse(ex: DbExecutor, userId: string): Promise<string | null> {
    const r = await rows<{ id: string }>(
      ex,
      sql`WITH prof AS (
            SELECT CASE WHEN up.settings->>'defaultWarehouseId' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                        THEN (up.settings->>'defaultWarehouseId')::uuid END AS settings_wh,
                   up.home_warehouse_id
              FROM user_profiles up WHERE up.user_id = ${userId}::uuid)
          SELECT COALESCE(
            (SELECT x.id FROM warehouses x JOIN prof ON prof.settings_wh = x.id WHERE x.is_active AND NOT x.deletion_mark),
            (SELECT x.id FROM warehouses x JOIN prof ON prof.home_warehouse_id = x.id WHERE x.is_active AND NOT x.deletion_mark),
            (SELECT x.id FROM warehouses x WHERE x.is_default_for_pos AND x.is_active AND NOT x.deletion_mark
              ORDER BY x.sort_order, x.id LIMIT 1),
            (SELECT x.id FROM warehouses x WHERE x.is_active AND NOT x.deletion_mark ORDER BY x.sort_order, x.name, x.id LIMIT 1)
          ) AS id`,
    );
    return r[0]?.id ?? null;
  }

  /** Подтверждённая карточка 1С клиента-покупателя (`customer_links.status='confirmed'`, ядро §22.12). */
  async confirmedCustomerOf(ex: DbExecutor, userId: string): Promise<string | null> {
    const r = await rows<{ id: string }>(
      ex,
      sql`SELECT c.id FROM customer_links l JOIN customers c ON c.id = l.customer_id
           WHERE l.user_id = ${userId}::uuid AND l.status = 'confirmed' AND NOT c.deletion_mark AND c.deleted_at IS NULL
           ORDER BY l.confirmed_at DESC NULLS LAST, l.id LIMIT 1`,
    );
    return r[0]?.id ?? null;
  }
}
