import { Inject, Injectable, Logger } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { AuditContext } from '../common/audit/audit-context.js';
import { type AuditEntry, AuditService } from '../common/audit/audit.service.js';
import type { DbExecutor, DbTransaction } from '../common/audit/db-executor.js';
import { CLOCK, type Clock } from '../common/auth/clock.js';
import { OtpHmacService } from '../common/crypto/otp-hmac.service.js';
import { DRIZZLE } from '../common/db/database.module.js';
import { ProblemException } from '../common/problem-details/problem.exception.js';
import { SettingsReader } from '../common/settings/settings-reader.js';
import type { PosDatabase } from '../db/database.js';
import {
  assertCartTransition,
  checkManualDiscount,
  hundredthsToPercent,
  percentToHundredths,
  SalesDomainError,
  toProblemException,
} from '../sales-domain/index.js';
import { type CartActor, CartActorResolver, can } from './cart-actor.js';
import { bishkekTime, dec, fieldError, rows } from './cart-common.js';
import { cartDto, parkedSummaryDto } from './cart-dto.js';
import { discountStateOf, type EvaluatedCart, evaluateCart } from './cart-evaluator.js';
import type { DiscountRequest, PutItemRequest, ReceiverInput } from './cart-requests.js';
import { type CartItemRow, type CartPatch, CartRepository, type CartRow } from './cart.repository.js';
import { CatalogPricingService } from './catalog-pricing.service.js';
import { customerDto, loadCustomers } from './customer-view.js';

/** Максимум строк корзины (ядро §20.2 п. 9; 10 CART-024; 08 rule `max_items`). */
export const CART_MAX_ITEMS = 200;
export const PARKED_TTL_DAYS_DEFAULT = 7;
export const PARKED_PAGE_DEFAULT = 50;
const CURSOR_DOMAIN = 'pos-api:cart-parked-cursor:v1';

type CartDto = Record<string, unknown>;

interface Mutation {
  /** Изменения заголовка (UPDATE с `row_version + 1` и кэшами); пустой объект — только инкремент версии. */
  readonly patch?: CartPatch;
  /** `false` — состояние уже такое (идемпотентный повтор): версия не меняется. */
  readonly changed: boolean;
  /** События аудита (пишутся последними операторами транзакции, 07 §9.3). */
  readonly audits?: (e: EvaluatedCart) => AuditEntry[];
}

export interface StepUpCheck {
  /** Проверка `X-Step-Up-Token` для операции; возвращает фактор для `audit_logs.step_up_method`. */
  (operation: string): Promise<'pin' | 'otp'>;
}

/**
 * Корзина (08 §4.7; 10 §7; RM-F-001, RM-F-012, RM-F-015): сервер — источник истины (D-23, D-32), одна `active` на
 * пользователя, оптимистическая блокировка `rowVersion` (`409 VERSION_CONFLICT` с `current: Cart`), отложенные
 * корзины, ручная скидка в лимите роли, режим клиента-покупателя (ядро §24.2). Каждый ответ — полная `Cart` с
 * пересчётом цен/остатков и `warnings[]`. Корзина ничего не резервирует (INV-024).
 */
@Injectable()
export class CartService {
  private readonly logger = new Logger('cart');

  constructor(
    @Inject(DRIZZLE) private readonly db: PosDatabase,
    readonly repo: CartRepository,
    readonly pricing: CatalogPricingService,
    readonly actors: CartActorResolver,
    private readonly audit: AuditService,
    private readonly settings: SettingsReader,
    private readonly hmac: OtpHmacService,
    @Inject(CLOCK) private readonly clock: Clock,
  ) {}

  transaction<T>(fn: (tx: DbTransaction) => Promise<T>): Promise<T> {
    return this.db.transaction(fn);
  }

  /** Без транзакции (чтение и проверки с долгим внешним вызовом — `/check` 1С до 6 с — без удержания блокировок). */
  run<T>(fn: (ex: DbExecutor) => Promise<T>): Promise<T> {
    return fn(this.db);
  }

  // =========================================================================================== чтение и сборка

  /** Пересчитанная корзина (цены, скидки, конфликты) — в той же транзакции, что и изменение. */
  async evaluate(
    ex: DbExecutor,
    a: CartActor,
    cart: CartRow,
    opts: {
      readonly items?: readonly CartItemRow[];
      readonly limitPercent?: string;
      readonly manualPercentOverride?: string;
      readonly cashRounding?: 'none' | 'to_som';
    } = {},
  ): Promise<{ e: EvaluatedCart; customer: Record<string, unknown> | null }> {
    const items = opts.items ?? (await this.repo.items(ex, cart.id));
    // Последовательно: в транзакции один клиент PostgreSQL (параллельные запросы на нём недопустимы).
    const quotes = await this.pricing.lineQuotes(ex, {
      priceListId: cart.price_list_id,
      warehouseId: cart.warehouse_id,
      items: items.map((it) => ({ variantId: it.variant_id, packagingId: it.packaging_id })),
    });
    const customers = cart.customer_id ? await loadCustomers(ex, [cart.customer_id]) : new Map<string, never>();
    const limit =
      opts.limitPercent !== undefined
        ? opts.limitPercent
        : ((await this.actors.discountLimit(a.role, ex))?.maxPercent ?? '0');
    const c = cart.customer_id ? customers.get(cart.customer_id) : undefined;
    const e = evaluateCart({
      cart,
      items,
      quotes,
      discount: discountStateOf(cart, limit, a.isCustomer),
      customerDiscountPercent: c?.discount_percent ?? null,
      ...(opts.manualPercentOverride !== undefined ? { manualPercentOverride: opts.manualPercentOverride } : {}),
      ...(opts.cashRounding ? { cashRounding: opts.cashRounding } : {}),
    });
    return { e, customer: c ? customerDto(c, a.role, a.isCustomer) : null };
  }

  async view(ex: DbExecutor, a: CartActor, cart: CartRow, revalidate = true): Promise<CartDto> {
    const { e, customer } = await this.evaluate(ex, a, cart);
    return cartDto(e, a, { customer, revalidate });
  }

  /** `409 VERSION_CONFLICT` с актуальной корзиной в `current` (08 §2.4, §4.7.2). */
  async assertVersion(ex: DbExecutor, a: CartActor, cart: CartRow, expected: number): Promise<void> {
    if (cart.row_version === expected) return;
    throw new ProblemException('VERSION_CONFLICT', {
      detail: 'Корзина изменена на другом устройстве.',
      current: await this.view(ex, a, cart),
    });
  }

  // =========================================================================================== активная корзина

  /** Активная корзина пользователя под блокировкой (создаётся при отсутствии) с актуальной привязкой клиента. */
  async ensureActive(tx: DbExecutor, a: CartActor): Promise<CartRow> {
    let cart = await this.repo.findActive(tx, a.userId, true);
    if (!cart) {
      const warehouseId = await this.repo.defaultWarehouse(tx, a.userId);
      const customerId = a.isCustomer ? await this.repo.confirmedCustomerOf(tx, a.userId) : null;
      const priceListId = await this.pricing.resolveFor(tx, {
        userId: a.userId,
        role: a.role,
        isCustomer: a.isCustomer,
        customerId,
      });
      if (!warehouseId || !priceListId) {
        // Реплика каталога 1С ещё не загружена (нет активного склада / вида цены по умолчанию, RM-E-011): это не
        // «необработанная ошибка» (INTERNAL, 08 §2.4), а временная недоступность данных 1С — 503 с причиной и
        // Retry-After (ревью F-trace-11, FQ-INT-01; код для 08 §4.7.1 — вопрос FIX-F-07).
        this.logger.warn({ event: 'cart.catalog_not_loaded', userId: a.userId, warehouseId, priceListId });
        throw new ProblemException('ONEC_UNAVAILABLE', {
          detail: 'Каталог ещё загружается из 1С: нет склада или вида цены. Повторите позже.',
          reason: 'catalog_not_loaded',
          retryAfter: 60,
        });
      }
      await this.repo.insert(tx, {
        ownerUserId: a.userId,
        createdByUserId: a.userId,
        deviceKey: a.deviceId,
        customerId,
        warehouseId,
        priceListId,
        status: 'active',
      });
      cart = await this.repo.findActive(tx, a.userId, true);
      if (!cart) throw new ProblemException('INTERNAL', { detail: 'Не удалось создать корзину.' });
    }
    return this.syncBinding(tx, a, cart);
  }

  /**
   * Привязка корзины: `customer` — своя `confirmed`-карточка 1С (иначе без клиента, цены по умолчанию; 08 §4.7 «Корзина
   * клиента-покупателя»); вид цены — по клиенту и роли (INV-030). Изменение → UPDATE с инкрементом версии.
   */
  private async syncBinding(tx: DbExecutor, a: CartActor, cart: CartRow): Promise<CartRow> {
    const customerId = a.isCustomer ? await this.repo.confirmedCustomerOf(tx, a.userId) : cart.customer_id;
    const priceListId =
      (await this.pricing.resolveFor(tx, { userId: a.userId, role: a.role, isCustomer: a.isCustomer, customerId })) ??
      cart.price_list_id;
    const patch: { customer_id?: string | null; price_list_id?: string; requested_discount_percent?: string } = {};
    if (customerId !== cart.customer_id) patch.customer_id = customerId;
    if (priceListId !== cart.price_list_id) patch.price_list_id = priceListId;
    if (a.isCustomer && dec(cart.requested_discount_percent).gt(0)) patch.requested_discount_percent = '0';
    if (Object.keys(patch).length === 0) return cart;
    return (await this.repo.update(tx, cart.id, cart.row_version, patch)) ?? cart;
  }

  /** Изменение активной корзины: блокировка, изменение строк, один UPDATE заголовка (+1 версия, кэши), аудит. */
  private async mutate(
    a: CartActor,
    ctx: AuditContext,
    fn: (tx: DbTransaction, cart: CartRow) => Promise<Mutation>,
  ): Promise<CartDto> {
    return this.transaction(async (tx) => {
      const cart = await this.ensureActive(tx, a);
      const m = await fn(tx, cart);
      if (!m.changed) return this.view(tx, a, cart);
      const virtual = { ...cart, ...(m.patch ?? {}) } as CartRow;
      const { e, customer } = await this.evaluate(tx, a, virtual);
      const updated = await this.repo.update(tx, cart.id, cart.row_version, {
        ...(m.patch ?? {}),
        items_count_cache: e.lines.length,
        subtotal_cache: e.priced.subtotal.toString(),
      });
      if (!updated)
        throw new ProblemException('VERSION_CONFLICT', { detail: 'Корзина изменена на другом устройстве.' });
      await this.refreshFlags(tx, e);
      const ev: EvaluatedCart = { ...e, cart: updated };
      for (const entry of m.audits?.(ev) ?? []) await this.audit.write(ctx, entry, tx);
      return cartDto(ev, a, { customer });
    });
  }

  /** Флаги строк после сверки (`price_changed`, `stock_insufficient`, `stock_snapshot`) — без изменения версии. */
  async refreshFlags(tx: DbExecutor, e: EvaluatedCart): Promise<void> {
    await this.repo.setItemFlags(
      tx,
      e.lines.map((l) => ({
        id: l.item.id,
        priceChanged: l.conflicts.some((c) => c.kind === 'price_changed'),
        stockInsufficient: l.conflicts.some((c) => c.kind === 'stock_insufficient'),
        stockSnapshot: l.quote.available,
      })),
    );
  }

  // =========================================================================================== маршруты

  /** `GET /cart` — всегда 200; при отсутствии активной корзины создаётся пустая (08 §4.7.1). */
  get(a: CartActor, revalidate: boolean): Promise<CartDto> {
    return this.transaction(async (tx) => this.view(tx, a, await this.ensureActive(tx, a), revalidate));
  }

  /** `PUT /cart/items/{variantId}` (08 §4.7.2; 10 CART-002/003/024/025, INV-001…INV-010, INV-052). */
  putItem(a: CartActor, ctx: AuditContext, variantId: string, r: PutItemRequest): Promise<CartDto> {
    return this.mutate(a, ctx, async (tx, cart) => {
      const items = await this.repo.items(tx, cart.id);
      const existing = items.find((it) => it.variant_id === variantId && it.packaging_id === r.packagingId);
      const value = dec(r.value);
      if (r.mode === 'set') {
        if (value.isZero() && !existing) return { changed: false };
        if (
          existing &&
          dec(existing.quantity).eq(value) &&
          (r.priceSnapshot === null || dec(existing.price_snapshot).eq(dec(r.priceSnapshot)))
        ) {
          return { changed: false };
        }
      }
      await this.assertVersion(tx, a, cart, r.rowVersion);
      if (r.mode === 'set' && value.isZero()) {
        await this.repo.deleteItems(tx, cart.id, variantId, r.packagingId);
        return { changed: true };
      }
      if (r.mode === 'increment' && value.isZero()) return { changed: false };
      const [quote] = await this.pricing.lineQuotes(tx, {
        priceListId: cart.price_list_id,
        warehouseId: cart.warehouse_id,
        items: [{ variantId, packagingId: r.packagingId }],
      });
      if (!quote || !quote.found) throw unavailable(variantId);
      if (!quote.packagingValid)
        fieldError('quantity.packagingId', 'packaging_mismatch', 'Упаковка не относится к товару.');
      if (!quote.sellable || quote.unitPrice === null) throw unavailable(variantId);
      const okUnit =
        r.packagingId === null
          ? r.unitId === quote.baseUnitId
          : r.unitId === quote.packaging?.unitId || r.unitId === quote.baseUnitId;
      if (!okUnit) fieldError('quantity.unitId', 'unit_mismatch', 'Единица не совпадает с единицей строки.');
      const quantity = r.mode === 'increment' && existing ? dec(existing.quantity).plus(value) : value;
      if (r.packagingId !== null && !quantity.isInteger()) {
        fieldError('quantity.value', 'qty_precision', 'Количество упаковок должно быть целым.');
      }
      if (r.packagingId === null && quantity.decimalPlaces() > quote.qtyPrecision) {
        fieldError(
          'quantity.value',
          'qty_precision',
          `Для единицы «${quote.unitCode}» допустимо не более ${quote.qtyPrecision} знаков после запятой.`,
        );
      }
      const base = r.packagingId !== null ? quantity.times(dec(quote.packagingFactor ?? '1')) : quantity;
      const baseText = base.toFixed(3);
      if (quote.minQty !== null && base.lt(dec(quote.minQty))) {
        throw new ProblemException('QTY_BELOW_MIN', {
          detail: `Минимальная партия — ${dec(quote.minQty).toFixed()} ${quote.unitCode}.`,
          conflicts: [{ variantId, kind: 'qty_below_min', requested: baseText, factor: quote.minQty }],
        });
      }
      if (quote.multiplicity !== null && !base.mod(dec(quote.multiplicity)).isZero()) {
        throw new ProblemException('QTY_NOT_MULTIPLE', {
          detail: `Количество должно быть кратно ${dec(quote.multiplicity).toFixed()} ${quote.unitCode}.`,
          conflicts: [{ variantId, kind: 'qty_not_multiple', requested: baseText, factor: quote.multiplicity }],
        });
      }
      if (!existing && items.length >= CART_MAX_ITEMS) {
        fieldError('quantity', 'max_items', `Слишком много позиций: не более ${CART_MAX_ITEMS} строк в корзине.`);
      }
      const oldBase = existing ? dec(existing.base_quantity) : dec('0');
      if (base.gt(oldBase) && quote.available === null) {
        throw new ProblemException('STOCK_INSUFFICIENT', {
          detail: 'Остаток неизвестен — добавление запрещено.',
          reason: 'stock_unknown',
          conflicts: [
            {
              variantId,
              kind: 'stock_insufficient',
              available: null,
              stockLevel: 'unknown',
              reason: 'stock_unknown',
            },
          ],
        });
      }
      if (existing) {
        await this.repo.updateItem(tx, existing.id, {
          quantity: quantity.toFixed(3),
          baseQuantity: baseText,
          ...(r.priceSnapshot !== null ? { priceSnapshot: r.priceSnapshot } : {}),
          stockSnapshot: quote.available,
        });
      } else {
        const lineNo = items.reduce((m, it) => Math.max(m, it.line_no), 0) + 1;
        await this.repo.insertItems(tx, cart.id, [
          {
            variantId,
            packagingId: r.packagingId,
            quantity: quantity.toFixed(3),
            baseQuantity: baseText,
            priceSnapshot: r.priceSnapshot ?? quote.unitPrice,
            stockSnapshot: quote.available,
            lineNo,
          },
        ]);
      }
      return { changed: true };
    });
  }

  /** `DELETE /cart/items/{variantId}` (08 §4.7.3): с `packagingId` — строка этой упаковки, без — все строки варианта. */
  deleteItem(
    a: CartActor,
    ctx: AuditContext,
    variantId: string,
    packagingId: string | null | undefined,
  ): Promise<CartDto> {
    return this.mutate(a, ctx, async (tx, cart) => {
      const n = await this.repo.deleteItems(tx, cart.id, variantId, packagingId);
      return { changed: n > 0 };
    });
  }

  /** `DELETE /cart?rowVersion=` (08 §4.7.3; 10 CART-011): `active → cleared`, новая пустая `active`; аудит `cart.cleared`. */
  clear(a: CartActor, ctx: AuditContext, rowVersion: number): Promise<CartDto> {
    return this.transaction(async (tx) => {
      const cart = await this.ensureActive(tx, a);
      const items = await this.repo.items(tx, cart.id);
      if (items.length === 0) return this.view(tx, a, cart);
      await this.assertVersion(tx, a, cart, rowVersion);
      const { e } = await this.evaluate(tx, a, cart, { items });
      assertDomain(() => assertCartTransition('active', 'cleared', 'clear'));
      await this.repo.update(tx, cart.id, cart.row_version, { status: 'cleared', cleared_at: this.clock.now() });
      const fresh = await this.newActiveLike(tx, a, cart);
      await this.audit.write(
        ctx,
        {
          action: 'cart.cleared',
          entityType: 'cart',
          entityId: cart.id,
          after: { cartId: cart.id, itemsCount: items.length, total: e.priced.total.toString(), parked: false },
        },
        tx,
      );
      return this.view(tx, a, fresh);
    });
  }

  /** Новая пустая `active` того же склада (после очистки/откладывания). */
  private async newActiveLike(tx: DbExecutor, a: CartActor, prev: CartRow): Promise<CartRow> {
    const customerId = a.isCustomer ? await this.repo.confirmedCustomerOf(tx, a.userId) : null;
    const priceListId =
      (await this.pricing.resolveFor(tx, { userId: a.userId, role: a.role, isCustomer: a.isCustomer, customerId })) ??
      prev.price_list_id;
    const row = await this.repo.insert(tx, {
      ownerUserId: a.userId,
      createdByUserId: a.userId,
      deviceKey: a.deviceId,
      customerId,
      warehouseId: prev.warehouse_id,
      priceListId,
      status: 'active',
    });
    return row ?? (await this.ensureActive(tx, a));
  }

  /** `PATCH /cart {warehouseId}` (08 §4.7.8; ядро §19.2; INV-025): пересчёт доступности строк, позиции не удаляются. */
  updateWarehouse(a: CartActor, ctx: AuditContext, warehouseId: string, rowVersion: number): Promise<CartDto> {
    return this.mutate(a, ctx, async (tx, cart) => {
      if (cart.warehouse_id === warehouseId) return { changed: false };
      await this.assertVersion(tx, a, cart, rowVersion);
      const w = await rows<{ is_active: boolean; deletion_mark: boolean; allow_sales: boolean }>(
        tx,
        sql`SELECT is_active, deletion_mark, allow_sales FROM warehouses WHERE id = ${warehouseId}::uuid`,
      );
      const row = w[0];
      if (!row || !row.is_active || row.deletion_mark) {
        throw new ProblemException('NOT_FOUND', { detail: 'Склад не найден или неактивен.' });
      }
      if (!row.allow_sales) throw new ProblemException('FORBIDDEN', { detail: 'Склад недоступен для продажи.' });
      return { changed: true, patch: { warehouse_id: warehouseId } };
    });
  }

  /** `POST /cart/customer` (08 §4.7.4; 10 CART-020, DISC-014): пересчёт вида цены и скидки клиента. */
  setCustomer(
    a: CartActor,
    ctx: AuditContext,
    r: { customerId: string; receiver: ReceiverInput | null; rowVersion: number },
  ): Promise<CartDto> {
    return this.mutate(a, ctx, async (tx, cart) => {
      if (a.isCustomer) {
        const own = await this.repo.confirmedCustomerOf(tx, a.userId);
        if (own !== r.customerId) {
          throw new ProblemException('FORBIDDEN', { detail: 'Можно выбрать только свою подтверждённую карточку.' });
        }
      } else {
        const c = await rows<{ ok: boolean }>(
          tx,
          sql`SELECT (NOT deletion_mark AND deleted_at IS NULL) AS ok FROM customers WHERE id = ${r.customerId}::uuid`,
        );
        if (!c[0]?.ok) throw new ProblemException('NOT_FOUND', { detail: 'Клиент не найден.' });
      }
      const receiver = r.receiver ?? { kind: 'customer' as const, name: null, phone: null };
      if (
        cart.customer_id === r.customerId &&
        cart.receiver_kind === receiver.kind &&
        cart.receiver_name === receiver.name &&
        cart.receiver_phone_e164 === receiver.phone
      ) {
        return { changed: false };
      }
      await this.assertVersion(tx, a, cart, r.rowVersion);
      const priceListId =
        (await this.pricing.resolveFor(tx, {
          userId: a.userId,
          role: a.role,
          isCustomer: a.isCustomer,
          customerId: r.customerId,
        })) ?? cart.price_list_id;
      return {
        changed: true,
        patch: {
          customer_id: r.customerId,
          price_list_id: priceListId,
          receiver_kind: receiver.kind,
          receiver_name: receiver.name,
          receiver_phone_e164: receiver.phone,
        },
      };
    });
  }

  /** `DELETE /cart/customer` (08 §4.7.4, ядро §17.4): клиент снят, цены — по виду цены по умолчанию. */
  unsetCustomer(a: CartActor, ctx: AuditContext): Promise<CartDto> {
    return this.mutate(a, ctx, async (tx, cart) => {
      // customer: корзина всегда связана со своей подтверждённой карточкой (08 §4.7) — снимать нечего.
      if (a.isCustomer) return { changed: false };
      if (cart.customer_id === null && cart.receiver_kind === 'customer') return { changed: false };
      const priceListId =
        (await this.pricing.resolveFor(tx, { userId: a.userId, role: a.role, isCustomer: false, customerId: null })) ??
        cart.price_list_id;
      return {
        changed: true,
        patch: {
          customer_id: null,
          price_list_id: priceListId,
          receiver_kind: 'customer',
          receiver_name: null,
          receiver_phone_e164: null,
        },
      };
    });
  }

  /**
   * `POST /cart/discount` (08 §4.7.5; 10 DISC-001…DISC-012): одна ручная скидка в % на документ в лимите роли
   * (`role_discount_limits`); сверх лимита — `override` из своей сессии (`discount.approve.over_limit` + step-up).
   * Аудит `discount.applied`, `discount.over_limit_approved`.
   */
  applyDiscount(a: CartActor, ctx: AuditContext, r: DiscountRequest, stepUp: StepUpCheck): Promise<CartDto> {
    if (a.isCustomer) {
      return Promise.reject(
        new ProblemException('FORBIDDEN', { detail: 'Ручная скидка в режиме клиента недоступна.' }),
      );
    }
    return (async () => {
      let stepUpMethod: 'pin' | 'otp' | null = null;
      if (r.override) {
        if (!can(a, 'discount.approve.over_limit')) {
          throw new ProblemException('FORBIDDEN', { detail: 'Нет права подтверждать скидку сверх лимита.' });
        }
        stepUpMethod = await stepUp('discount.approve.over_limit');
      }
      return this.mutate(a, ctx, async (tx, cart) => {
        const requested = assertDomain(() => hundredthsToPercent(percentToHundredths(r.percent, 'percent')));
        const sameApproval = r.override
          ? cart.discount_approved_by_user_id === a.userId && cart.discount_override_reason === r.override.reason
          : true;
        if (requested === normalize(cart.requested_discount_percent) && sameApproval) return { changed: false };
        await this.assertVersion(tx, a, cart, r.rowVersion);
        const limit = await this.actors.discountLimit(a.role, tx);
        const decision = assertDomain(
          () =>
            checkManualDiscount({
              requestedPercent: requested,
              isCustomer: false,
              initiatorLimit: limit,
              ...(r.override && limit ? { override: { approverLimit: limit, reason: r.override.reason } } : {}),
            }),
          requiresRoleExt(a.role),
        );
        const now = this.clock.now();
        return {
          changed: true,
          patch: {
            requested_discount_percent: decision.appliedPercent,
            discount_approved_by_user_id: decision.overrideApplied ? a.userId : null,
            discount_approved_at: decision.overrideApplied ? now : null,
            discount_override_reason: decision.overrideApplied && r.override ? r.override.reason : null,
          },
          audits: (e) => {
            const out: AuditEntry[] = [
              {
                action: 'discount.applied',
                entityType: 'cart',
                entityId: cart.id,
                after: {
                  cartId: cart.id,
                  percent: decision.appliedPercent,
                  limitPercent: decision.limitPercent,
                  discountTotal: e.priced.manualDiscountTotal.toString(),
                  total: e.priced.total.toString(),
                },
              },
            ];
            if (decision.overrideApplied && r.override) {
              out.push({
                action: 'discount.over_limit_approved',
                entityType: 'cart',
                entityId: cart.id,
                after: { cartId: cart.id, percent: decision.appliedPercent, approverUserId: a.userId },
                reason: r.override.reason,
                stepUpMethod,
              });
            }
            return out;
          },
        };
      });
    })();
  }

  /** `POST /cart/park` (08 §4.7.6; 10 CART-030): `active → parked` + новая пустая `active`; аудит `cart.parked`. */
  park(
    a: CartActor,
    ctx: AuditContext,
    r: { name: string | null; rowVersion: number },
  ): Promise<{ parked: CartDto; active: CartDto }> {
    if (a.isCustomer) {
      return Promise.reject(
        new ProblemException('FORBIDDEN', { detail: 'Отложенные корзины в режиме клиента недоступны.' }),
      );
    }
    return this.transaction(async (tx) => {
      const cart = await this.ensureActive(tx, a);
      const items = await this.repo.items(tx, cart.id);
      if (items.length === 0)
        throw new ProblemException('CART_EMPTY', { detail: 'Корзина пуста — откладывать нечего.' });
      await this.assertVersion(tx, a, cart, r.rowVersion);
      const parked = await this.parkRow(tx, a, cart, items, r.name ?? (await this.defaultParkName(tx, cart)));
      const fresh = await this.newActiveLike(tx, a, cart);
      const { e, customer } = await this.evaluate(tx, a, parked, { items });
      await this.audit.write(
        ctx,
        {
          action: 'cart.parked',
          entityType: 'cart',
          entityId: cart.id,
          after: { cartId: cart.id, name: parked.name, itemsCount: items.length, total: e.priced.total.toString() },
        },
        tx,
      );
      return { parked: cartDto(e, a, { customer }), active: await this.view(tx, a, fresh) };
    });
  }

  private async parkRow(
    tx: DbExecutor,
    a: CartActor,
    cart: CartRow,
    items: readonly CartItemRow[],
    name: string,
  ): Promise<CartRow> {
    assertDomain(() => assertCartTransition('active', 'parked', 'park'));
    const now = this.clock.now();
    const { e } = await this.evaluate(tx, a, cart, { items });
    const updated = await this.repo.update(tx, cart.id, cart.row_version, {
      status: 'parked',
      name: name.slice(0, 80),
      parked_at: now,
      expires_at: new Date(now.getTime() + (await this.parkedTtlDays()) * 86_400_000),
      items_count_cache: items.length,
      subtotal_cache: e.priced.subtotal.toString(),
    });
    if (!updated) throw new ProblemException('VERSION_CONFLICT', { detail: 'Корзина изменена на другом устройстве.' });
    return updated;
  }

  private async defaultParkName(tx: DbExecutor, cart: CartRow): Promise<string> {
    let who = 'Без клиента';
    if (cart.customer_id) {
      const c = (await loadCustomers(tx, [cart.customer_id])).get(cart.customer_id);
      if (c) who = c.name;
    }
    const time = bishkekTime(this.clock.now());
    const head = who.length > 70 ? `${who.slice(0, 69)}…` : who;
    return `${head} · ${time}`;
  }

  private async parkedTtlDays(): Promise<number> {
    const v = await this.settings.get('parked_cart_ttl_days');
    return typeof v === 'number' && Number.isInteger(v) && v > 0 && v <= 365 ? v : PARKED_TTL_DAYS_DEFAULT;
  }

  /** `GET /cart/parked` (08 §4.7.6; 10 CART-031): `scope=own|all`, keyset по (`parked_at` DESC, `id` DESC). */
  async listParked(
    a: CartActor,
    q: { scope: 'own' | 'all'; limit: number; cursor: string | undefined },
  ): Promise<{ items: CartDto[]; nextCursor: string | null; hasMore: boolean }> {
    if (a.isCustomer)
      throw new ProblemException('FORBIDDEN', { detail: 'Отложенные корзины в режиме клиента недоступны.' });
    if (q.scope === 'all' && !can(a, 'cart.parked.read.all')) {
      throw new ProblemException('FORBIDDEN', { detail: 'Просмотр всех отложенных корзин недоступен для вашей роли.' });
    }
    const after = q.cursor !== undefined ? this.decodeCursor(q.cursor) : null;
    const now = this.clock.now();
    const list = await rows<{ id: string }>(
      this.db,
      sql`SELECT c.id FROM carts c
           WHERE c.status = 'parked' AND (c.expires_at IS NULL OR c.expires_at > ${now}::timestamptz)
             ${q.scope === 'own' ? sql`AND c.owner_user_id = ${a.userId}::uuid` : sql``}
             ${after ? sql`AND (c.parked_at, c.id) < (${after.parkedAt}::timestamptz, ${after.id}::uuid)` : sql``}
           ORDER BY c.parked_at DESC, c.id DESC LIMIT ${q.limit + 1}`,
    );
    const page = list.slice(0, q.limit);
    const carts = (await Promise.all(page.map((r) => this.repo.findById(this.db, r.id)))).filter(
      (c): c is CartRow => c !== null,
    );
    const owners = await this.userRefs(carts.map((c) => c.owner_user_id));
    const items = await this.repo.itemsOf(
      this.db,
      carts.map((c) => c.id),
    );
    const out: CartDto[] = [];
    for (const c of carts) {
      const { e, customer } = await this.evaluate(this.db, a, c, {
        items: items.get(c.id) ?? [],
        limitPercent: c.requested_discount_percent,
      });
      out.push(
        parkedSummaryDto(
          e,
          owners.get(c.owner_user_id) ?? { id: c.owner_user_id, displayName: 'Пользователь' },
          customer,
        ),
      );
    }
    const last = carts[carts.length - 1];
    const hasMore = list.length > q.limit;
    return {
      items: out,
      nextCursor: hasMore && last?.parked_at ? this.encodeCursor(last.parked_at, last.id) : null,
      hasMore,
    };
  }

  private async userRefs(
    ids: readonly string[],
  ): Promise<Map<string, { id: string; displayName: string; role?: string }>> {
    const uniq = [...new Set(ids)];
    if (uniq.length === 0) return new Map();
    const r = await rows<{ id: string; display_name: string | null; full_name: string | null; role: string | null }>(
      this.db,
      sql`SELECT u.id, p.display_name, p.full_name,
                 (SELECT ro.code::text FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id
                   WHERE ur.user_id = u.id AND ur.revoked_at IS NULL ORDER BY ur.granted_at DESC LIMIT 1) AS role
            FROM users u LEFT JOIN user_profiles p ON p.user_id = u.id
           WHERE u.id = ANY(${sql.param(uniq)}::uuid[])`,
    );
    return new Map(
      r.map((x) => [
        x.id,
        {
          id: x.id,
          displayName: x.display_name?.trim() || x.full_name?.trim() || 'Пользователь',
          ...(x.role ? { role: x.role } : {}),
        },
      ]),
    );
  }

  /** `parkedAt` — значение из БД как есть (драйвер Drizzle отдаёт `timestamptz` строкой с микросекундами). */
  private encodeCursor(parkedAt: Date | string, id: string): string {
    const at = typeof parkedAt === 'string' ? parkedAt : parkedAt.toISOString();
    const body = Buffer.from(JSON.stringify({ s: [at], id }), 'utf8').toString('base64url');
    return `${body}.${this.hmac.pseudonym(CURSOR_DOMAIN, body).slice(0, 32)}`;
  }

  private decodeCursor(cursor: string): { parkedAt: string; id: string } {
    const [body, mac] = cursor.split('.');
    const bad = (): never => fieldError('cursor', 'cursor', 'Курсор недействителен.');
    if (!body || !mac || this.hmac.pseudonym(CURSOR_DOMAIN, body).slice(0, 32) !== mac) return bad();
    try {
      const v = JSON.parse(Buffer.from(body, 'base64url').toString('utf8')) as { s?: unknown[]; id?: unknown };
      const at = v.s?.[0];
      if (typeof at !== 'string' || typeof v.id !== 'string') return bad();
      return { parkedAt: at, id: v.id };
    } catch {
      return bad();
    }
  }

  /**
   * `POST /cart/parked/{id}/resume` (08 §4.7.6; 10 CART-032, CART-034): своя — `cart.manage.own`, чужая —
   * `cart.parked.resume.any` (иначе `404`, существование не раскрывается); непустая текущая — `409 active_not_empty`
   * или автосохранение при `replaceActive=true`; владельцем становится возобновивший; аудит `cart.resumed[_foreign]`.
   */
  resume(a: CartActor, ctx: AuditContext, id: string, replaceActive: boolean): Promise<CartDto> {
    if (a.isCustomer) {
      return Promise.reject(
        new ProblemException('FORBIDDEN', { detail: 'Отложенные корзины в режиме клиента недоступны.' }),
      );
    }
    return this.transaction(async (tx) => {
      const target = await this.repo.findById(tx, id, true);
      const foreign = target !== null && target.owner_user_id !== a.userId;
      if (!target || (foreign && !can(a, 'cart.parked.resume.any'))) throw notFound();
      if (target.status === 'active') {
        if (foreign) throw notFound();
        return this.view(tx, a, await this.syncBinding(tx, a, target));
      }
      assertDomain(() => assertCartTransition(target.status, 'active', 'resume'));
      const current = await this.repo.findActive(tx, a.userId, true);
      if (current) {
        const curItems = await this.repo.items(tx, current.id);
        if (curItems.length > 0) {
          if (!replaceActive) {
            throw new ProblemException('ORDER_STATE_INVALID', {
              detail: 'Текущая корзина не пуста: отложите её или очистите.',
              resource: 'cart',
              reason: 'active_not_empty',
              currentStatus: 'active',
            });
          }
          await this.parkRow(tx, a, current, curItems, `Автосохранение ${bishkekTime(this.clock.now())}`);
        } else {
          await this.repo.update(tx, current.id, current.row_version, {
            status: 'cleared',
            cleared_at: this.clock.now(),
          });
        }
      }
      const resumed = await this.repo.update(tx, target.id, target.row_version, {
        status: 'active',
        owner_user_id: a.userId,
        resumed_at: this.clock.now(),
        parked_at: null,
        expires_at: null,
      });
      if (!resumed)
        throw new ProblemException('VERSION_CONFLICT', { detail: 'Корзина изменена на другом устройстве.' });
      const synced = await this.syncBinding(tx, a, resumed);
      await this.audit.write(
        ctx,
        {
          action: foreign ? 'cart.resumed_foreign' : 'cart.resumed',
          entityType: 'cart',
          entityId: target.id,
          after: {
            cartId: target.id,
            ownerId: target.owner_user_id,
            resumedBy: a.userId,
            createdBy: target.created_by_user_id,
          },
        },
        tx,
      );
      return this.view(tx, a, synced);
    });
  }

  /**
   * `DELETE /cart/parked/{id}` (08 §4.7.9; ядро §19.2; 10 CART-035): мягкое удаление `parked → cleared`; чужая — по
   * праву `cart.parked.resume.any` (иначе `404`); повтор — `204`; не `parked` — `409 not_parked`; аудит `cart.cleared`.
   */
  deleteParked(a: CartActor, ctx: AuditContext, id: string): Promise<void> {
    if (a.isCustomer) {
      return Promise.reject(
        new ProblemException('FORBIDDEN', { detail: 'Отложенные корзины в режиме клиента недоступны.' }),
      );
    }
    return this.transaction(async (tx) => {
      const target = await this.repo.findById(tx, id, true);
      const foreign = target !== null && target.owner_user_id !== a.userId;
      if (!target || (foreign && !can(a, 'cart.parked.resume.any'))) throw notFound();
      if (target.status === 'cleared' && target.parked_at !== null) return;
      if (target.status !== 'parked') {
        throw new ProblemException('ORDER_STATE_INVALID', {
          detail: 'Удаляется только отложенная корзина; активная очищается через DELETE /cart.',
          resource: 'cart',
          reason: 'not_parked',
          currentStatus: target.status,
        });
      }
      assertDomain(() => assertCartTransition('parked', 'cleared', 'expire_or_delete'));
      const items = await this.repo.items(tx, target.id);
      const { e } = await this.evaluate(tx, a, target, { items, limitPercent: target.requested_discount_percent });
      await this.repo.update(tx, target.id, target.row_version, { status: 'cleared', cleared_at: this.clock.now() });
      await this.audit.write(
        ctx,
        {
          action: 'cart.cleared',
          entityType: 'cart',
          entityId: target.id,
          after: {
            cartId: target.id,
            ownerId: target.owner_user_id,
            parked: true,
            itemsCount: items.length,
            total: e.priced.total.toString(),
            ...(foreign ? { foreign: true } : {}),
          },
        },
        tx,
      );
    });
  }
}

function normalize(p: string): string {
  return hundredthsToPercent(percentToHundredths(p));
}

function notFound(): ProblemException {
  return new ProblemException('NOT_FOUND', { detail: 'Корзина не найдена.' });
}

function unavailable(variantId: string): ProblemException {
  return new ProblemException('VARIANT_UNAVAILABLE', {
    detail: 'Товар больше не продаётся.',
    conflicts: [{ variantId, kind: 'variant_unavailable' }],
  });
}

/**
 * `DISCOUNT_LIMIT_EXCEEDED.requiresRole` (08 §4.7.5): роль, способная подтвердить скидку сверх лимита из своей
 * сессии (10 DISC-010): для `seller`/`cashier` — `senior_seller`, для `senior_seller` — `admin`; у `admin` выше нет.
 */
export function requiresRoleExt(role: string): Readonly<Record<string, unknown>> {
  if (role === 'seller' || role === 'cashier') return { requiresRole: 'senior_seller' };
  if (role === 'senior_seller') return { requiresRole: 'admin' };
  return {};
}

/** Доменная ошибка → `ProblemException` (с дополнительными расширениями, например `requiresRole`). */
export function assertDomain<T>(fn: () => T, extra: Readonly<Record<string, unknown>> = {}): T {
  try {
    return fn();
  } catch (e) {
    if (e instanceof SalesDomainError && e.code === 'DISCOUNT_LIMIT_EXCEEDED') {
      throw toProblemException(new SalesDomainError(e.code, e.detail, { ...e.extensions, ...extra }, e.status));
    }
    throw toProblemException(e);
  }
}
