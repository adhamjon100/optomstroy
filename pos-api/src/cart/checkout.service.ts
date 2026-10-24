import { Inject, Injectable, Logger } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { DbExecutor } from '../common/audit/db-executor.js';
import { CLOCK, type Clock } from '../common/auth/clock.js';
import { APP_CONFIG, type AppConfig } from '../common/config/app-config.js';
import { OtpHmacService } from '../common/crypto/otp-hmac.service.js';
import type { PaymentMethod } from '../common/enums.js';
import {
  type CartReader,
  type CheckoutCartSnapshot,
  type CheckoutConflict,
  type CheckoutValidation,
  type CheckoutValidationInput,
  CREDIT_DECISION_SERVICE,
  type CreditDecisionService,
  INVENTORY_CHECK_PORT,
  type InventoryCheckPort,
  type SalesActor,
  type SalesTx,
} from '../common/ports/index.js';
import { ProblemException } from '../common/problem-details/problem.exception.js';
import { SettingsReader } from '../common/settings/settings-reader.js';
import {
  allowedPaymentMethods,
  assertCartTransition,
  type CartLineConflict,
  checkManualDiscount,
  hundredthsToPercent,
  type ManualDiscountDecision,
  percentToHundredths,
  SalesDomainError,
} from '../sales-domain/index.js';
import { type CartActor, CartActorResolver, can } from './cart-actor.js';
import { iso, moneyDto, qty3, rows } from './cart-common.js';
import { cartDto } from './cart-dto.js';
import { conflictDto, type EvaluatedCart, type EvaluatedLine } from './cart-evaluator.js';
import type { PreviewRequest } from './cart-requests.js';
import { type CartRow, CartRepository } from './cart.repository.js';
import { assertDomain, CartService, requiresRoleExt } from './cart.service.js';
import { type OnecCheckResult, OnecCheckService } from './onec-check.service.js';
import { signPreviewToken, verifyPreviewToken } from './preview-token.js';

/** Срок действия предпросмотра (08 §3.8: `previewToken` — 5 мин). */
export const PREVIEW_TTL_MS = 5 * 60_000;

interface CheckoutInput {
  readonly paymentMethod: PaymentMethod;
  readonly manualDiscountPercent: string | null;
  readonly discountOverride: { readonly reason: string } | null;
  readonly creditOverride: { readonly reason: string } | null;
  readonly stepUpVerified: boolean;
  /** `true` — строгие коды (POST /orders, `strict=true`): отказ по долгу и роли — ошибкой, а не полем. */
  readonly strict: boolean;
  readonly mode: 'preview' | 'order';
  readonly syncCheckWithOnec: boolean;
}

interface CheckoutOutcome {
  readonly e: EvaluatedCart;
  readonly customer: Record<string, unknown> | null;
  readonly conflicts: readonly CartLineConflict[];
  readonly discount: ManualDiscountDecision;
  readonly needsOverride: readonly ('discount' | 'credit')[];
  readonly allowed: readonly PaymentMethod[];
  readonly paymentChecks: Record<string, unknown>;
  readonly credit: { readonly allowed: boolean; readonly overrideUsed: boolean } | null;
  readonly onecCheck: OnecCheckResult;
  readonly warnings: { readonly code: 'STALE_DATA' | 'QR_UNAVAILABLE'; readonly message: string }[];
  /** Подтверждение скидки сверх лимита, применённое к этому расчёту (`null` — скидка в лимите роли). */
  readonly discountApproval: DiscountApproval | null;
}

/** Кто и почему подтвердил скидку сверх лимита (10 DISC-010): в этом запросе (`session`) или ранее в корзине. */
interface DiscountApproval {
  readonly userId: string;
  readonly reason: string;
  readonly source: 'session' | 'cart';
}

/**
 * `CheckoutPolicy` (06 §7.4, ревью B-AR-07): единственная процедура проверок оформления — её вызывают
 * `POST /cart/checkout-preview` (нестрогий режим: конфликты и отказ по долгу — в теле `200`) и `POST /orders` через
 * порт `CartReader.validateForCheckout` (строгий режим: отказы — кодами 08). Проверки: пустая корзина (`CART_EMPTY`),
 * цены/остатки/доступность (конфликты, ядро §19.2 — все одним ответом; остатки — также через сервис этапа E
 * `InventoryCheckPort`), лимит ручной скидки роли (DISC-003/010), способы оплаты (API-179, CUST-024), порядок продажи
 * в долг PAY-031 (ядро §22.4, §23 п. 5 — `CreditDecisionService`), режим клиента (ядро §24.2), `/check` 1С (6 с).
 */
@Injectable()
export class CheckoutService implements CartReader {
  private readonly logger = new Logger('cart.checkout');

  constructor(
    private readonly carts: CartService,
    private readonly repo: CartRepository,
    private readonly actors: CartActorResolver,
    private readonly onec: OnecCheckService,
    private readonly hmac: OtpHmacService,
    private readonly settings: SettingsReader,
    @Inject(INVENTORY_CHECK_PORT) private readonly inventory: InventoryCheckPort,
    @Inject(CREDIT_DECISION_SERVICE) private readonly creditDecision: CreditDecisionService,
    @Inject(APP_CONFIG) private readonly config: Pick<AppConfig, 'QR_PROVIDER'>,
    @Inject(CLOCK) private readonly clock: Clock,
  ) {}

  // =========================================================================================== POST /cart/checkout-preview

  async preview(a: CartActor, r: PreviewRequest): Promise<Record<string, unknown>> {
    if (a.isCustomer && r.manualDiscountPercent !== null && percentToHundredths(r.manualDiscountPercent) > 0n) {
      throw new ProblemException('FORBIDDEN', { detail: 'Ручная скидка в режиме клиента недоступна.' });
    }
    return this.carts.run(async (tx) => {
      const cart = await this.loadOwnActive(tx, a, r.cartId, false);
      await this.carts.assertVersion(tx, a, cart, r.cartRowVersion);
      const o = await this.evaluateCheckout(tx, a, cart, {
        paymentMethod: r.paymentMethod,
        manualDiscountPercent: r.manualDiscountPercent,
        discountOverride: null,
        creditOverride: r.creditOverride,
        stepUpVerified: false,
        strict: r.strict,
        mode: 'preview',
        syncCheckWithOnec: r.syncCheckWithOnec,
      });
      const now = this.clock.now();
      const validUntil = new Date(now.getTime() + PREVIEW_TTL_MS);
      const lineOf = new Map<string, EvaluatedLine>();
      for (const l of o.e.lines) if (!lineOf.has(l.item.variant_id)) lineOf.set(l.item.variant_id, l);
      const total = o.e.priced.total.toString();
      // Отказ по долгу, который нельзя снять override (нет `credit.sale.approve`, fail-closed до этапа G), — заказ
      // не создать (10 ORD-007, ORD-006; ревью F-money-rules-8): POST /orders ответит 422 CREDIT_*.
      const creditRefused = r.paymentMethod === 'credit' && o.credit?.allowed !== true;
      const canCreateOrder =
        can(a, 'order.create') &&
        o.conflicts.length === 0 &&
        o.needsOverride.length === 0 &&
        !creditRefused &&
        o.allowed.includes(r.paymentMethod);
      return {
        cartId: cart.id,
        cartRowVersion: cart.row_version,
        ok: o.conflicts.length === 0,
        conflicts: o.conflicts.map((c) => conflictDto(c, lineOf.get(c.variantId), a)),
        items: o.e.lines
          .filter((l) => l.priced !== null)
          .map((l) => ({
            lineNo: l.item.line_no,
            variantId: l.item.variant_id,
            productId: l.quote.productId,
            productName: l.quote.productName,
            ...(l.quote.variantName ? { variantName: l.quote.variantName } : {}),
            ...(l.quote.sku ? { sku: l.quote.sku } : {}),
            quantity: {
              value: qty3(l.item.quantity),
              unitId: l.quote.unitId,
              packagingId: l.item.packaging_id,
              baseValue: qty3(l.item.base_quantity),
            },
            baseQuantity: qty3(l.item.base_quantity),
            unitPrice: moneyDto(l.priced!.unitPrice.toString()),
            discountPercent: o.discount.appliedPercent,
            discountAmount: moneyDto(l.priced!.discountAmount.toString()),
            lineTotal: moneyDto(l.priced!.lineTotal.toString()),
          })),
        subtotal: moneyDto(o.e.priced.subtotal.toString()),
        discountPercent: o.discount.appliedPercent,
        discountTotal: moneyDto(o.e.priced.discountTotal.toString()),
        customerDiscountTotal: moneyDto(o.e.priced.customerDiscountTotal.toString()),
        total: moneyDto(total),
        cashRounding: o.e.priced.cashRoundingDelta.toString(),
        totalToPay: moneyDto(o.e.priced.totalToPay.toString()),
        paymentMethod: r.paymentMethod,
        paymentChecks: o.paymentChecks,
        permissions: {
          canCreateOrder,
          canApplyDiscount: !a.isCustomer && can(a, 'discount.apply.within_limit'),
          discountLimitPercent: o.discount.limitPercent,
          canSellOnCredit: !a.isCustomer && can(a, 'credit.sale.create'),
          needsOverride: o.needsOverride,
          allowedPaymentMethods: o.allowed,
        },
        onecCheck: { performed: o.onecCheck.performed, at: iso(o.onecCheck.at), result: o.onecCheck.result },
        validUntil: validUntil.toISOString(),
        previewToken: signPreviewToken(this.hmac, {
          cartId: cart.id,
          cartRowVersion: cart.row_version,
          total,
          paymentMethod: r.paymentMethod,
          validUntil: validUntil.toISOString(),
          onecCheckAt: iso(o.onecCheck.at),
          onecResult: o.onecCheck.result,
        }),
        warnings: o.warnings,
      };
    });
  }

  /** Своя активная корзина `cartId` (чужая/несуществующая — `404`; оформленная/отложенная — `409 ORDER_STATE_INVALID`). */
  private async loadOwnActive(
    ex: DbExecutor,
    a: CartActor,
    cartId: string | undefined,
    forUpdate: boolean,
  ): Promise<CartRow> {
    const active = await this.carts.ensureActive(ex, a);
    if (cartId === undefined || active.id === cartId) {
      return forUpdate ? ((await this.repo.findById(ex, active.id, true)) ?? active) : active;
    }
    const other = await this.repo.findById(ex, cartId);
    if (!other || other.owner_user_id !== a.userId)
      throw new ProblemException('NOT_FOUND', { detail: 'Корзина не найдена.' });
    throw new ProblemException('ORDER_STATE_INVALID', {
      detail: 'Корзина недоступна для оформления.',
      resource: 'cart',
      reason: `cart_${other.status}`,
      currentStatus: other.status,
    });
  }

  // =========================================================================================== CheckoutPolicy

  private async evaluateCheckout(
    ex: DbExecutor,
    a: CartActor,
    cart: CartRow,
    i: CheckoutInput,
  ): Promise<CheckoutOutcome> {
    const items = await this.repo.items(ex, cart.id);
    if (items.length === 0) throw new ProblemException('CART_EMPTY', { detail: 'Корзина пуста.' });
    const strict = i.strict || i.mode === 'order';
    const canCredit = !a.isCustomer && can(a, 'credit.sale.create');
    const allowed = allowedPaymentMethods({
      isCustomerMode: a.isCustomer,
      qrProvider: this.config.QR_PROVIDER,
      canSellOnCredit: canCredit,
    });
    if (i.paymentMethod === 'qr_bakai' && a.isCustomer && this.config.QR_PROVIDER === 'none') {
      throw new ProblemException('VALIDATION_FAILED', {
        status: 422,
        detail: 'Оплата QR сейчас недоступна.',
        errors: [
          { field: 'paymentMethod', rule: 'payment_method_unavailable', message: 'Оплата QR сейчас недоступна.' },
        ],
      });
    }
    // Шаг 1 (а) PAY-031: право роли на продажу в долг.
    const creditForbidden = i.paymentMethod === 'credit' && !canCredit;
    if (creditForbidden && strict) {
      throw new ProblemException('FORBIDDEN', {
        detail: 'Продажа в долг недоступна для вашей роли.',
        creditReason: 'forbidden_role',
      });
    }
    // Ручная скидка: лимит роли владельца; сверх лимита — подтверждение из своей сессии (DISC-010).
    const requested = a.isCustomer
      ? '0.00'
      : hundredthsToPercent(
          percentToHundredths(i.manualDiscountPercent ?? cart.requested_discount_percent, 'manualDiscountPercent'),
        );
    // Ручная скидка клиента-покупателя (> 0) отклоняется вызывающими до расчёта (`preview`, `validateForCheckout`).
    const limit = await this.actors.discountLimit(a.role, ex);
    const needsOverride: ('discount' | 'credit')[] = [];
    let discount: ManualDiscountDecision;
    const approver = await this.approverLimit(ex, a, cart, i, requested);
    try {
      discount = checkManualDiscount({
        requestedPercent: requested,
        isCustomer: a.isCustomer,
        initiatorLimit: limit,
        ...(approver ? { override: { approverLimit: approver.approverLimit, reason: approver.reason } } : {}),
      });
    } catch (e) {
      if (!(e instanceof SalesDomainError) || e.code !== 'DISCOUNT_LIMIT_EXCEEDED' || strict) {
        assertDomain(() => {
          throw e;
        }, requiresRoleExt(a.role));
      }
      needsOverride.push('discount');
      discount = {
        appliedPercent: requested,
        limitPercent: hundredthsToPercent(percentToHundredths(limit?.maxPercent ?? '0')),
        overrideApplied: false,
      };
    }
    const discountApproval: DiscountApproval | null =
      discount.overrideApplied && approver
        ? { userId: approver.userId, reason: approver.reason, source: approver.source }
        : null;
    // Округление наличных (Q-016 открыт; 07 DATA-216: в R1 поля дельты округления в orders/payments нет): заказ и
    // платёж создаются без округления, поэтому и предпросмотр показывает `totalToPay = total` при любом значении
    // `app_settings.cash_rounding` — суммы предпросмотра и заказа совпадают (10 ORD-007/ORD-008; ревью
    // F-money-rules-4). Включение `to_som` — expand-миграцией после решения Q-016 (F_spec_questions FIX-F-04).
    const cashRounding = 'none' as const;
    if (i.paymentMethod === 'cash') await this.warnIfCashRoundingRequested(cart.id);
    const { e, customer } = await this.carts.evaluate(ex, a, cart, {
      items,
      manualPercentOverride: discount.appliedPercent,
      cashRounding,
    });
    const conflicts = await this.withInventory(a, cart, e);
    // Продажа в долг: порядок PAY-031 (ядро §22.4 в редакции §23 п. 5).
    let paymentChecks: Record<string, unknown> = { creditAllowed: false, creditReason: null, receivablesStale: false };
    let credit: CheckoutOutcome['credit'] = null;
    if (i.paymentMethod === 'credit') {
      if (creditForbidden) {
        paymentChecks = { creditAllowed: false, creditReason: 'forbidden_role', receivablesStale: false };
      } else {
        await this.assertIdentified(ex, cart);
        let override: { reason: string } | null = null;
        if (i.creditOverride) {
          if (!can(a, 'credit.sale.approve')) {
            throw new ProblemException('FORBIDDEN', {
              detail: 'Нет права подтверждать продажу в долг при блокировке.',
            });
          }
          if (i.mode === 'order' && !i.stepUpVerified) {
            throw new ProblemException('STEP_UP_REQUIRED', {
              detail: 'Требуется подтверждение операции.',
              stepUp: { operation: 'credit.sale.approve', allowedMethods: ['pin', 'otp'] },
            });
          }
          override = i.creditOverride;
        }
        const r = await this.creditDecision.check(ex, {
          actor: this.actors.toSalesActor(a),
          customerId: cart.customer_id,
          total: e.priced.total.toString(),
          override,
        });
        if (r.allowed) {
          credit = { allowed: true, overrideUsed: r.overrideUsed };
          paymentChecks = {
            creditAllowed: true,
            creditReason: null,
            ...(r.limitRemaining !== null ? { limitRemaining: moneyDto(r.limitRemaining) } : {}),
            receivablesAsOf: iso(r.receivablesAsOf),
            receivablesStale: false,
          };
        } else {
          if (r.code === 'CUSTOMER_NOT_IDENTIFIED' || strict) {
            throw new ProblemException(r.code, {
              detail: r.detail,
              creditReason: r.creditReason,
              ...(r.limitRemaining !== undefined && r.limitRemaining !== null
                ? { limitRemaining: moneyDto(r.limitRemaining) }
                : {}),
            });
          }
          credit = { allowed: false, overrideUsed: false };
          paymentChecks = {
            creditAllowed: false,
            creditReason: r.code === 'FORBIDDEN' ? 'forbidden_role' : r.creditReason,
            ...(r.limitRemaining !== undefined && r.limitRemaining !== null
              ? { limitRemaining: moneyDto(r.limitRemaining) }
              : {}),
            receivablesAsOf: iso(r.receivablesAsOf ?? null),
            receivablesStale: r.code === 'RECEIVABLES_STALE',
          };
          if ((r.code === 'CREDIT_BLOCKED' || r.code === 'CREDIT_LIMIT_EXCEEDED') && can(a, 'credit.sale.approve')) {
            needsOverride.push('credit');
          }
        }
      }
    }
    const onecCheck = i.syncCheckWithOnec
      ? await this.onec.check({
          cart,
          items,
          quotes: e.lines.map((l) => l.quote),
          paymentMethod: i.paymentMethod,
          requestId: a.requestId,
        })
      : { performed: false, at: null, result: 'unavailable' as const };
    const warnings: CheckoutOutcome['warnings'] = [];
    if (onecCheck.performed && onecCheck.result === 'unavailable') {
      warnings.push({ code: 'STALE_DATA', message: '1С недоступна: проверка выполнена по данным реплики.' });
    }
    return {
      e,
      customer,
      conflicts,
      discount,
      needsOverride,
      allowed,
      paymentChecks,
      credit,
      onecCheck,
      warnings,
      discountApproval,
    };
  }

  /**
   * Подтверждающий скидку сверх лимита: `discountOverride` текущей сессии (step-up проверен вызывающим) или ранее
   * подтверждённая корзина (`discount_approved_by_user_id` — лимит подтверждения его роли). Подтверждение корзины
   * действует **только для того процента, на который его дали** (`POST /cart/discount` с override записывает его в
   * `requested_discount_percent` и сбрасывает подтверждение при любой другой скидке): иной процент сверх лимита роли
   * требует `discountOverride` со step-up в этом запросе (10 DISC-010, DISC-012; ревью F-money-rules-2).
   */
  private async approverLimit(
    ex: DbExecutor,
    a: CartActor,
    cart: CartRow,
    i: CheckoutInput,
    requested: string,
  ): Promise<{
    approverLimit: NonNullable<Awaited<ReturnType<CartActorResolver['discountLimit']>>>;
    reason: string;
    userId: string;
    source: 'session' | 'cart';
  } | null> {
    if (a.isCustomer) return null;
    if (i.discountOverride && i.stepUpVerified && can(a, 'discount.approve.over_limit')) {
      const l = await this.actors.discountLimit(a.role, ex);
      return l && a.userId
        ? { approverLimit: l, reason: i.discountOverride.reason, userId: a.userId, source: 'session' }
        : null;
    }
    const approvedPercent = hundredthsToPercent(percentToHundredths(cart.requested_discount_percent));
    if (cart.discount_approved_by_user_id && approvedPercent === requested) {
      const r = await rows<{ role: string | null }>(
        ex,
        sql`SELECT (SELECT ro.code::text FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id
                     WHERE ur.user_id = ${cart.discount_approved_by_user_id}::uuid AND ur.revoked_at IS NULL
                     ORDER BY ur.granted_at DESC LIMIT 1) AS role`,
      );
      const role = r[0]?.role;
      const l = role ? await this.actors.discountLimit(role, ex) : null;
      return l
        ? {
            approverLimit: l,
            reason: cart.discount_override_reason ?? 'подтверждено',
            userId: cart.discount_approved_by_user_id,
            source: 'cart',
          }
        : null;
    }
    return null;
  }

  /** Клиент для долга: выбран, не «Розничный покупатель», есть карточка 1С (шаг 1 PAY-031, ядро §23 п. 5). */
  private async assertIdentified(ex: DbExecutor, cart: CartRow): Promise<void> {
    if (cart.customer_id) {
      const r = await rows<{ ok: boolean }>(
        ex,
        sql`SELECT (NOT is_retail_default AND onec_ref IS NOT NULL AND NOT deletion_mark) AS ok
              FROM customers WHERE id = ${cart.customer_id}::uuid`,
      );
      if (r[0]?.ok) return;
    }
    throw new ProblemException('CUSTOMER_NOT_IDENTIFIED', {
      detail: 'Для продажи в долг выберите клиента с карточкой 1С.',
    });
  }

  /** `cash_rounding=to_som` в R1 не применяется (Q-016): только журнал, чтобы расхождение настройки было видно. */
  private async warnIfCashRoundingRequested(cartId: string): Promise<void> {
    const v = await this.settings.get('cash_rounding');
    if (v === 'to_som') {
      this.logger.warn(
        { event: 'cart.cash_rounding.ignored', cartId },
        'cash_rounding=to_som не применяется в R1 (Q-016)',
      );
    }
  }

  /**
   * Перепроверка остатков и доступности сервисом этапа E (`InventoryCheckPort` → `InventoryService.check`): нехватки
   * и недоступные варианты, не найденные пересчётом корзины, добавляются к конфликтам (все — одним ответом).
   */
  private async withInventory(a: CartActor, cart: CartRow, e: EvaluatedCart): Promise<CartLineConflict[]> {
    const conflicts = [...e.conflicts];
    const lines = e.lines.filter((l) => l.quote.sellable && l.quote.unitId !== '');
    if (lines.length === 0) return conflicts;
    try {
      const r = await this.inventory.check(this.actors.toSalesActor(a), {
        warehouseId: cart.warehouse_id,
        priceListId: cart.price_list_id,
        items: lines.map((l) => ({
          variantId: l.item.variant_id,
          value: qty3(l.item.quantity),
          unitId: l.quote.unitId,
          packagingId: l.item.packaging_id,
        })),
      });
      const has = (v: string, kind: CartLineConflict['kind']) =>
        conflicts.some((c) => c.variantId === v && c.kind === kind);
      for (const v of r.unavailable) {
        if (!has(v, 'variant_unavailable')) conflicts.push({ variantId: v, kind: 'variant_unavailable' });
      }
      for (const s of r.shortages) {
        if (!has(s.variantId, 'stock_insufficient'))
          conflicts.push({ variantId: s.variantId, kind: 'stock_insufficient' });
      }
    } catch (err) {
      this.logger.warn({ event: 'cart.inventory_check.failed', cartId: cart.id, err }, 'cart.inventory_check.failed');
    }
    return conflicts;
  }

  // =========================================================================================== CartReader (порт)

  async validateForCheckout(
    tx: SalesTx | null,
    actor: SalesActor,
    input: CheckoutValidationInput,
  ): Promise<CheckoutValidation> {
    const a = await this.actors.fromSalesActor(actor);
    const run = async (ex: DbExecutor): Promise<CheckoutValidation> => {
      const cart = await this.loadOwnActive(ex, a, input.cartId, tx !== null);
      if (input.expectedRowVersion !== undefined) await this.carts.assertVersion(ex, a, cart, input.expectedRowVersion);
      if (
        a.isCustomer &&
        input.manualDiscountPercent !== undefined &&
        percentToHundredths(input.manualDiscountPercent) > 0n
      ) {
        throw new ProblemException('FORBIDDEN', { detail: 'Ручная скидка в режиме клиента недоступна.' });
      }
      const o = await this.evaluateCheckout(ex, a, cart, {
        paymentMethod: input.paymentMethod ?? 'cash',
        manualDiscountPercent: input.manualDiscountPercent ?? null,
        discountOverride: input.discountOverride ?? null,
        creditOverride: input.creditOverride ?? null,
        stepUpVerified: input.stepUpVerified === true,
        strict: true,
        mode: 'order',
        syncCheckWithOnec: true,
      });
      if (o.conflicts.length === 0 && input.previewToken) {
        this.assertPreviewToken(input.previewToken, {
          cartId: cart.id,
          cartRowVersion: cart.row_version,
          paymentMethod: input.paymentMethod ?? 'cash',
          total: o.e.priced.total.toString(),
        });
      }
      return {
        ok: o.conflicts.length === 0,
        conflicts: o.conflicts.map((c): CheckoutConflict => ({
          ...conflictDto(
            c,
            o.e.lines.find((l) => l.item.variant_id === c.variantId),
            a,
          ),
          variantId: c.variantId,
          kind: c.kind,
        })),
        cart: this.snapshot(cart, o),
        allowedPaymentMethods: o.allowed,
        onecCheck: o.onecCheck,
        credit: o.credit,
        warnings: o.warnings,
      };
    };
    return tx ? run(tx) : this.carts.run(run);
  }

  /**
   * Сверка `previewToken` с серверным пересчётом (10 ORD-020, AC-ORD-020; 04 AC-FLOW-014-04; 08 §3.8, §4.8.1):
   * подделанный, повреждённый или просроченный токен, другая корзина/версия/способ оплаты или другой итог →
   * `422 PRICE_CHANGED` (заказ не создаётся, корзина сохраняется; клиент повторяет `checkout-preview`).
   */
  private assertPreviewToken(
    token: string,
    actual: { cartId: string; cartRowVersion: number; paymentMethod: PaymentMethod; total: string },
  ): void {
    const t = verifyPreviewToken(this.hmac, token, this.clock.now());
    const priceChanged = (reason: string, extra: Record<string, unknown> = {}) =>
      new ProblemException('PRICE_CHANGED', {
        detail: 'Итоги изменились после предпросмотра — обновите оформление.',
        reason,
        conflicts: [],
        ...extra,
      });
    if (!t) throw priceChanged('preview_token_invalid');
    if (t.cartId !== actual.cartId || t.cartRowVersion !== actual.cartRowVersion) {
      throw priceChanged('preview_cart_changed');
    }
    if (t.paymentMethod !== actual.paymentMethod) throw priceChanged('preview_payment_method_changed');
    if (t.total !== actual.total) {
      throw priceChanged('preview_total_changed', {
        previewTotal: moneyDto(t.total),
        total: moneyDto(actual.total),
      });
    }
  }

  private snapshot(cart: CartRow, o: CheckoutOutcome): CheckoutCartSnapshot {
    const p = o.e.priced;
    return {
      cartId: cart.id,
      rowVersion: cart.row_version,
      ownerUserId: cart.owner_user_id,
      customerId: cart.customer_id,
      warehouseId: cart.warehouse_id,
      priceListId: cart.price_list_id,
      customerDiscountPercent: p.customerDiscountPercent,
      manualDiscountPercent: p.manualDiscountPercent,
      discountApprovedByUserId: o.discountApproval?.userId ?? null,
      discountOverrideReason: o.discountApproval?.reason ?? null,
      subtotal: p.subtotal.toString(),
      customerDiscountTotal: p.customerDiscountTotal.toString(),
      manualDiscountTotal: p.manualDiscountTotal.toString(),
      discountTotal: p.discountTotal.toString(),
      total: p.total.toString(),
      lines: o.e.lines
        .filter((l) => l.priced !== null)
        .map((l) => {
          const pl = l.priced!;
          return {
            lineNo: l.item.line_no,
            variantId: l.item.variant_id,
            productId: l.quote.productId,
            packagingId: l.item.packaging_id,
            quantity: qty3(l.item.quantity),
            baseQuantity: qty3(l.item.base_quantity),
            unitPrice: pl.unitPrice.toString(),
            lineSubtotal: pl.lineSubtotal.toString(),
            customerDiscountAmount: pl.customerDiscountAmount.toString(),
            manualDiscountAmount: pl.manualDiscountAmount.toString(),
            discountAmount: pl.discountAmount.toString(),
            lineTotal: pl.lineTotal.toString(),
            unitCode: l.quote.unitCode,
            packagingName: l.quote.packagingName,
            packagingFactor: l.quote.packagingFactor,
            productName: l.quote.productName,
            variantName: l.quote.variantName,
            sku: l.quote.sku,
            barcode: l.quote.barcode,
          };
        }),
    };
  }

  /** Активная корзина → `converted` при совпадении `row_version` (06 §4.5.2 T1, `SELECT … FOR UPDATE`). */
  async markConverted(
    tx: SalesTx,
    input: { readonly cartId: string; readonly expectedRowVersion: number; readonly orderId: string },
  ): Promise<void> {
    const cart = await this.repo.findById(tx, input.cartId, true);
    if (!cart) throw new ProblemException('NOT_FOUND', { detail: 'Корзина не найдена.' });
    if (cart.status === 'converted' && cart.converted_order_id === input.orderId) return;
    assertDomain(() => assertCartTransition(cart.status, 'converted', 'convert'));
    if (cart.row_version !== input.expectedRowVersion) {
      throw new ProblemException('VERSION_CONFLICT', { detail: 'Корзина изменена после предпросмотра.' });
    }
    const updated = await this.repo.update(tx, cart.id, cart.row_version, {
      status: 'converted',
      converted_order_id: input.orderId,
    });
    if (!updated) throw new ProblemException('VERSION_CONFLICT', { detail: 'Корзина изменена после предпросмотра.' });
  }

  /**
   * Восстановление состава заказа в новую корзину автора (10 ORD-027; 08 `Cart.restoredFromOrderId`): пустая
   * активная (или её отсутствие) — восстановленная `active`, иначе (или `forceParked`) — `parked` «Восстановлена из
   * заказа № …». Цены-снимки — цены заказа (предупреждение `price_changed` при изменении). Повтор — та же корзина.
   */
  async restoreFromOrder(
    tx: SalesTx,
    input: { readonly orderId: string; readonly ownerUserId: string; readonly forceParked?: boolean },
  ): Promise<{ readonly cartId: string; readonly status: 'active' | 'parked' }> {
    const existing = await this.repo.findRestored(tx, input.orderId, input.ownerUserId);
    if (existing) return { cartId: existing.id, status: existing.status === 'active' ? 'active' : 'parked' };
    const order = (
      await rows<{
        customer_id: string | null;
        warehouse_id: string;
        price_list_id: string;
        discount_percent: string;
        public_number: string;
      }>(
        tx,
        sql`SELECT customer_id, warehouse_id, price_list_id, discount_percent::text AS discount_percent, public_number
              FROM orders WHERE id = ${input.orderId}::uuid`,
      )
    )[0];
    if (!order) throw new ProblemException('NOT_FOUND', { detail: 'Заказ не найден.' });
    const lines = await rows<{
      variant_id: string;
      packaging_id: string | null;
      quantity: string;
      base_quantity: string;
      unit_price: string;
    }>(
      tx,
      sql`SELECT variant_id, packaging_id, quantity::text AS quantity, base_quantity::text AS base_quantity,
                 unit_price::text AS unit_price
            FROM order_items WHERE order_id = ${input.orderId}::uuid ORDER BY line_no`,
    );
    const active = await this.repo.findActive(tx, input.ownerUserId, true);
    let asActive = input.forceParked !== true;
    if (asActive && active) {
      const n = await this.repo.items(tx, active.id);
      if (n.length > 0) asActive = false;
      else
        await this.repo.update(tx, active.id, active.row_version, { status: 'cleared', cleared_at: this.clock.now() });
    }
    const now = this.clock.now();
    const ttl = await this.settings.get('parked_cart_ttl_days');
    const days = typeof ttl === 'number' && Number.isInteger(ttl) && ttl > 0 ? ttl : 7;
    const row = await this.repo.insert(tx, {
      ownerUserId: input.ownerUserId,
      createdByUserId: input.ownerUserId,
      deviceKey: null,
      customerId: order.customer_id,
      warehouseId: order.warehouse_id,
      priceListId: order.price_list_id,
      status: asActive ? 'active' : 'parked',
      name: asActive ? null : `Восстановлена из заказа № ${order.public_number}`.slice(0, 80),
      requestedDiscountPercent: order.discount_percent,
      restoredFromOrderId: input.orderId,
      parkedAt: asActive ? null : now,
      expiresAt: asActive ? null : new Date(now.getTime() + days * 86_400_000),
    });
    if (!row) throw new ProblemException('INTERNAL', { detail: 'Не удалось восстановить корзину.' });
    await this.repo.insertItems(
      tx,
      row.id,
      lines.map((l, idx) => ({
        variantId: l.variant_id,
        packagingId: l.packaging_id,
        quantity: l.quantity,
        baseQuantity: l.base_quantity,
        priceSnapshot: l.unit_price,
        stockSnapshot: null,
        lineNo: idx + 1,
      })),
    );
    return { cartId: row.id, status: asActive ? 'active' : 'parked' };
  }

  /**
   * Восстановленная из заказа корзина при техническом повторе / ручной привязке (10 ORD-027, ORD-034): не изменялась
   * (`row_version = 1`, `active`/`parked`) — `cleared` (`restored_superseded`); изменена или оформлена — `modified`.
   */
  async releaseRestored(
    tx: SalesTx,
    input: { readonly orderId: string; readonly ownerUserId: string },
  ): Promise<{ readonly outcome: 'none' | 'cleared' | 'modified'; readonly cartIds: readonly string[] }> {
    const found = await rows<{
      id: string;
      status: 'active' | 'parked' | 'converted' | 'cleared';
      row_version: number;
    }>(
      tx,
      sql`SELECT id, status::text AS status, row_version FROM carts
           WHERE restored_from_order_id = ${input.orderId}::uuid AND owner_user_id = ${input.ownerUserId}::uuid
           ORDER BY created_at FOR UPDATE`,
    );
    const open = found.filter((c) => c.status === 'active' || c.status === 'parked');
    if (found.some((c) => c.status === 'converted') || open.some((c) => Number(c.row_version) !== 1)) {
      return { outcome: 'modified', cartIds: found.map((c) => c.id) };
    }
    const now = this.clock.now();
    for (const c of open) {
      assertDomain(() => assertCartTransition(c.status, 'cleared', 'restored_superseded'));
      const updated = await this.repo.update(tx, c.id, Number(c.row_version), { status: 'cleared', cleared_at: now });
      if (!updated) return { outcome: 'modified', cartIds: found.map((x) => x.id) };
    }
    return { outcome: open.length > 0 ? 'cleared' : 'none', cartIds: open.map((c) => c.id) };
  }

  /** Корзина как DTO (для `current` в ответах конфликта версий из порта). */
  async cartView(ex: DbExecutor, a: CartActor, cart: CartRow): Promise<Record<string, unknown>> {
    const { e, customer } = await this.carts.evaluate(ex, a, cart);
    return cartDto(e, a, { customer });
  }
}
