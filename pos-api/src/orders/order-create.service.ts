import { Inject, Injectable, Logger, Optional } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { StepUpTokenVerifier } from '../auth/step-up/step-up-token.verifier.js';
import { type AuditContext, applyAuditGucs, auditContextFromRequest } from '../common/audit/audit-context.js';
import { AuditService } from '../common/audit/audit.service.js';
import { CLOCK, type Clock } from '../common/auth/clock.js';
import type { AuthenticatedPrincipal } from '../common/auth/principal.js';
import { APP_CONFIG, type AppConfig } from '../common/config/app-config.js';
import { DRIZZLE, type Database } from '../common/db/database.module.js';
import type { PaymentMethod } from '../common/enums.js';
import type { RequestWithContext } from '../common/http/request-context.js';
import { getIdempotencyState } from '../common/idempotency/idempotency.context.js';
import { IdempotencyService } from '../common/idempotency/idempotency.service.js';
import { newId } from '../common/ids/uuid.js';
import { Money, Quantity } from '../common/money/money.js';
import {
  CART_READER,
  type CartReader,
  type CheckoutValidation,
  type CreateOrderCommand,
  type CreateOrderResult,
  CREDIT_DECISION_SERVICE,
  type CreditDecisionService,
  NOTIFICATIONS_PORT,
  type NotificationsPort,
  ONEC_OUTBOX_WRITER,
  type OnecOutboxWriter,
  type OrderCreator,
  PAYMENTS_PORT,
  type PaymentsPort,
  PortNotBoundError,
} from '../common/ports/index.js';
import { ProblemException } from '../common/problem-details/problem.exception.js';
import { PermissionCatalog } from '../common/rbac/permission-catalog.js';
import {
  initialPaymentIdempotencyKey,
  isSoftDuplicate,
  orderCompositionHash,
} from '../sales-domain/idempotency/sales-idempotency.js';
import { assertPaymentMethodAllowed } from '../sales-domain/pricing/payment-methods.js';
import { toProblemException } from '../sales-domain/problem.js';
import { buildOnecOrderPayload, customerCreateDependency } from './onec-order-payload.js';
import { creditRecheckRefusal, notifyCreditBlocked, recheckCreditInTx } from './order-credit-recheck.js';
import type { OrderViewer } from './order-access.js';
import { insertOrderTransaction } from './order-projection.js';
import { OrderViewService } from './order-view.service.js';
import { confirmedCustomerId, findOrder, insertHistory } from './order.repository.js';
import {
  type CreateOrderBody,
  forbiddenFieldError,
  forbiddenMoneyFields,
  parseCreateOrderBody,
  validationFailed,
} from './orders.request.js';
import { idempotencyExecutor } from './sql-executor.js';

type Warning = { readonly code: string; readonly message: string };

/** Нормализованная команда создания (HTTP и порт `OrderCreator`). */
interface CreateInput {
  readonly idempotencyKey: string;
  readonly cartId?: string;
  readonly cartRowVersion: number;
  readonly customerId?: string | null;
  readonly paymentMethod: PaymentMethod;
  readonly manualDiscountPercent?: string;
  readonly discountOverride: { readonly reason: string } | null;
  readonly creditOverride: { readonly reason: string } | null;
  readonly receiver: {
    readonly kind: 'customer' | 'other_person';
    readonly name: string | null;
    readonly phone: string | null;
  };
  readonly delivery: {
    readonly method: 'pickup' | 'delivery';
    readonly address: string | null;
    readonly recipientPhone: string | null;
    readonly courierComment: string | null;
    readonly desiredDate: string | null;
    readonly timeFrom: string | null;
    readonly timeTo: string | null;
  };
  readonly printOptions: Readonly<Record<string, boolean>> | null;
  readonly comment: string | null;
  readonly confirmDuplicate: boolean;
  /** `previewToken` последнего `checkout-preview` (08 §4.8.1, 10 ORD-020): сверка итога; `null` — не передан. */
  readonly previewToken: string | null;
  /** `items[]` тела: должны совпасть с корзиной (`VERSION_CONFLICT`); порт `OrderCreator` их не передаёт. */
  readonly items:
    readonly { readonly variantId: string; readonly packagingId: string | null; readonly quantity: string }[] | null;
}

interface CreateContext {
  readonly viewer: OrderViewer;
  readonly auditCtx: AuditContext;
  readonly req: object | null;
  readonly stepUpMethod: 'pin' | 'otp' | null;
  readonly stepUpVerified: boolean;
}

export interface CreateHttpResult {
  readonly httpStatus: 201 | 202;
  readonly orderId: string;
  readonly body: Record<string, unknown>;
}

const RETAIL_CUSTOMER_SQL = sql`SELECT id FROM customers WHERE is_retail_default LIMIT 1`;

/** Коды отказа в продаже в долг (аудит `credit.sale_blocked`). */
const CREDIT_REFUSALS: ReadonlySet<string> = new Set(['CREDIT_BLOCKED', 'CREDIT_LIMIT_EXCEEDED', 'RECEIVABLES_STALE']);

/**
 * Создание заказа из корзины — `POST /orders` (08 §4.8.1, владелец правила — ядро §22.3; 10 ORD-020…ORD-029;
 * RM-F-002, RM-F-012, RM-F-015). Документ 1С синхронно **не** создаётся:
 * 1) проверки `checkout-preview` и синхронный `/check` 1С (≤ `ONEC_SYNC_CHECK_TIMEOUT_MS`) — `CartReader`
 *    вне транзакции БД; 1С недоступна → ответ `202` + `warnings[STALE_DATA]` (проверка по снимку);
 * 2) одна короткая транзакция: `orders` (`draft → submitting`, `onec_sync_state=pending`), снимок `order_items`,
 *    начальный платёж (`PaymentsPort.createInitial`), `onec_outbox` (`order/create`, `pending`), история,
 *    `transactions (order_created)`, аудит `order.created`, корзина → `converted`, итог `Idempotency-Key`;
 * 3) после COMMIT — пробуждение `outbox.dispatch` и QR начального платежа (`PaymentsPort.afterCommit`).
 * Режим клиента (ядро §24.2): `created_via=customer` ставит сервер, клиент — своя подтверждённая карточка или
 * «Розничный покупатель», только `cash`/`qr_bakai`, без ручной скидки, долга и overrides.
 */
@Injectable()
export class OrderCreateService implements OrderCreator {
  private readonly logger = new Logger('orders.create');

  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    @Inject(CLOCK) private readonly clock: Clock,
    @Inject(CART_READER) private readonly cart: CartReader,
    @Inject(PAYMENTS_PORT) private readonly payments: PaymentsPort,
    @Inject(ONEC_OUTBOX_WRITER) private readonly outbox: OnecOutboxWriter,
    @Inject(CREDIT_DECISION_SERVICE) private readonly credit: CreditDecisionService,
    private readonly audit: AuditService,
    private readonly idempotency: IdempotencyService,
    private readonly stepUp: StepUpTokenVerifier,
    private readonly views: OrderViewService,
    private readonly catalog: PermissionCatalog,
    @Optional() @Inject(NOTIFICATIONS_PORT) private readonly notifications?: NotificationsPort,
  ) {}

  /** HTTP: `POST /orders` (контроллер). */
  async createHttp(
    principal: AuthenticatedPrincipal,
    req: RequestWithContext & { ip?: string },
    rawBody: unknown,
    stepUpToken: string | undefined,
  ): Promise<CreateHttpResult> {
    const auditCtx = auditContextFromRequest(req);
    const forbidden = forbiddenMoneyFields(rawBody);
    if (forbidden.length > 0) {
      await this.audit.write(auditCtx, {
        action: 'price.override_attempt',
        entityType: 'order',
        result: 'denied',
        severity: 'warning',
        after: { fields: forbidden, route: 'POST /orders' },
      });
      throw forbiddenFieldError(forbidden);
    }
    const body = parseCreateOrderBody(rawBody);
    const key = headerOf(req, 'idempotency-key');
    if (!key)
      throw validationFailed([
        {
          field: 'Idempotency-Key',
          rule: 'idempotency_key_required',
          message: 'Заголовок Idempotency-Key обязателен.',
        },
      ]);
    const viewer = await this.views.viewer(principal, typeof req.id === 'string' ? req.id : null);

    let stepUpMethod: 'pin' | 'otp' | null = null;
    if (body.discountOverride || body.creditOverride) {
      if (viewer.actor.isCustomer) throw forbidden403('Скидка и долг недоступны в режиме клиента.');
      if (body.discountOverride) {
        if (!viewer.permissions.has('discount.approve.over_limit'))
          throw forbidden403('Нет права подтверждать скидку сверх лимита.');
        stepUpMethod = (await this.stepUp.verify(stepUpToken, principal, { operation: 'discount.approve.over_limit' }))
          .method;
      }
      if (body.creditOverride) {
        if (!viewer.permissions.has('credit.sale.approve'))
          throw forbidden403('Нет права подтверждать продажу в долг.');
        stepUpMethod = (await this.stepUp.verify(stepUpToken, principal, { operation: 'credit.sale.approve' })).method;
      }
    }
    return this.create(toCreateInput(key, body), {
      viewer,
      auditCtx,
      req,
      stepUpMethod,
      stepUpVerified: stepUpMethod !== null,
    });
  }

  /** Порт `OrderCreator` (внутренние вызовы и тесты других агентов): step-up overrides проверил вызывающий. */
  async createFromCart(cmd: CreateOrderCommand): Promise<CreateOrderResult> {
    const permissions = this.catalog.effectivePermissions({ roles: cmd.actor.roles });
    const viewer: OrderViewer = {
      actor: cmd.actor,
      permissions,
      linkedCustomerId:
        cmd.actor.isCustomer && cmd.actor.userId ? await confirmedCustomerId(this.db, cmd.actor.userId) : null,
    };
    const r = await this.create(
      {
        idempotencyKey: cmd.idempotencyKey,
        cartRowVersion: cmd.cartRowVersion,
        customerId: cmd.customerId ?? null,
        paymentMethod: cmd.paymentMethod,
        ...(cmd.manualDiscountPercent !== undefined ? { manualDiscountPercent: cmd.manualDiscountPercent } : {}),
        discountOverride: cmd.discountOverride ?? null,
        creditOverride: cmd.creditOverride ?? null,
        receiver: {
          kind: cmd.receiver?.kind ?? 'customer',
          name: cmd.receiver?.name ?? null,
          phone: cmd.receiver?.phoneE164 ?? null,
        },
        delivery: {
          method: cmd.deliveryMethod,
          address: cmd.delivery?.address ?? null,
          recipientPhone: cmd.delivery?.phoneE164 ?? null,
          courierComment: cmd.delivery?.comment ?? null,
          desiredDate: cmd.delivery?.date ?? null,
          timeFrom: cmd.delivery?.timeFrom ?? null,
          timeTo: cmd.delivery?.timeTo ?? null,
        },
        printOptions: null,
        comment: cmd.comment ?? null,
        confirmDuplicate: cmd.confirmDuplicate ?? false,
        previewToken: null,
        items: null,
      },
      {
        viewer,
        auditCtx: { actorUserId: cmd.actor.userId, requestId: cmd.actor.requestId ?? null, system: null },
        req: null,
        stepUpMethod: null,
        stepUpVerified: Boolean(cmd.discountOverride || cmd.creditOverride),
      },
    );
    const payment = (r.body.payments as { id: string }[] | undefined)?.[0];
    return {
      httpStatus: r.httpStatus,
      orderId: r.orderId,
      publicNumber: String(r.body.publicNumber),
      status: 'submitting',
      paymentId: payment?.id ?? null,
      warnings: (r.body.warnings as Warning[] | undefined) ?? [],
    };
  }

  private async create(input: CreateInput, ctx: CreateContext): Promise<CreateHttpResult> {
    try {
      return await this.createUnsafe(input, ctx);
    } catch (e) {
      throw toProblemException(e);
    }
  }

  private async createUnsafe(input: CreateInput, ctx: CreateContext): Promise<CreateHttpResult> {
    const { actor, permissions } = ctx.viewer;
    const customerMode = actor.isCustomer;
    const qrProvider = this.config.QR_PROVIDER;

    // Режим клиента (ядро §24.2; 08 §4.8.1 «Режим клиента»; 10 CUST-023, CUST-024).
    if (customerMode) {
      if (input.paymentMethod === 'credit') {
        throw new ProblemException('FORBIDDEN', {
          detail: 'Продажа в долг недоступна в режиме клиента.',
          creditReason: 'forbidden_role',
        });
      }
      if (input.manualDiscountPercent !== undefined && !Money.of(input.manualDiscountPercent).isZero()) {
        throw forbidden403('Ручная скидка недоступна в режиме клиента.');
      }
      if (input.discountOverride || input.creditOverride)
        throw forbidden403('Подтверждения недоступны в режиме клиента.');
      if (input.customerId && input.customerId !== ctx.viewer.linkedCustomerId) {
        throw forbidden403('Заказ можно оформить только на свою карточку клиента.');
      }
    }
    assertPaymentMethodAllowed(input.paymentMethod, {
      isCustomerMode: customerMode,
      qrProvider,
      canSellOnCredit: permissions.has('credit.sale.create'),
    });

    // (1) Проверки корзины и синхронный /check 1С — вне транзакции БД (08 §4.8).
    let validation: CheckoutValidation;
    try {
      validation = await this.cart.validateForCheckout(null, actor, {
        ...(input.cartId ? { cartId: input.cartId } : {}),
        expectedRowVersion: input.cartRowVersion,
        paymentMethod: input.paymentMethod,
        ...(input.manualDiscountPercent !== undefined ? { manualDiscountPercent: input.manualDiscountPercent } : {}),
        discountOverride: input.discountOverride,
        creditOverride: input.creditOverride,
        stepUpVerified: ctx.stepUpVerified,
        previewToken: input.previewToken,
      });
    } catch (e) {
      // Отказ по долгу из CheckoutPolicy (строгий режим) — тоже `credit.sale_blocked` (11 §7.2).
      if (input.paymentMethod === 'credit' && e instanceof ProblemException && CREDIT_REFUSALS.has(e.code)) {
        await this.auditCreditBlocked(ctx.auditCtx, {
          customerId: input.customerId ?? null,
          total: null,
          code: e.code,
          creditReason: typeof e.extensions.creditReason === 'string' ? e.extensions.creditReason : null,
        });
      }
      throw e;
    }
    const snap = validation.cart;
    if (input.cartId && snap.cartId !== input.cartId) {
      throw new ProblemException('VERSION_CONFLICT', { detail: 'Корзина изменилась — обновите оформление.' });
    }
    if (snap.rowVersion !== input.cartRowVersion) {
      throw new ProblemException('VERSION_CONFLICT', {
        detail: 'Корзина изменилась — обновите оформление.',
        current: { cartId: snap.cartId, rowVersion: snap.rowVersion },
      });
    }
    if (snap.lines.length === 0) throw new ProblemException('CART_EMPTY', { detail: 'Корзина пуста.' });
    if (input.items && !sameItems(input.items, snap.lines)) {
      throw new ProblemException('VERSION_CONFLICT', {
        detail: 'Состав заказа не совпадает с корзиной — обновите оформление.',
        current: { cartId: snap.cartId, rowVersion: snap.rowVersion },
      });
    }
    if (!validation.ok) throw conflictsProblem(validation);
    if (validation.onecCheck.result === 'rejected') {
      throw new ProblemException('ONEC_REJECTED', { detail: '1С отклонила проверку заказа.' });
    }
    if (!validation.allowedPaymentMethods.includes(input.paymentMethod)) {
      throw validationFailed(
        [{ field: 'paymentMethod', rule: 'payment_method_unavailable', message: 'Способ оплаты недоступен.' }],
        422,
      );
    }

    // Клиент заказа: staff — клиент корзины (иначе «Розничный покупатель», ORD-004); customer — своя подтверждённая
    // карточка или «Розничный покупатель» (CUST-023). `customerId` тела — сверка с корзиной.
    const retailId = (await this.db.execute<{ id: string }>(RETAIL_CUSTOMER_SQL)).rows[0]?.id;
    if (!retailId) throw new Error('orders: нет системного клиента «Розничный покупатель» (seed)');
    const customerId = customerMode ? (ctx.viewer.linkedCustomerId ?? retailId) : (snap.customerId ?? retailId);
    if (!customerMode && input.customerId && input.customerId !== customerId) {
      throw new ProblemException('VERSION_CONFLICT', {
        detail: 'Клиент заказа не совпадает с клиентом корзины — обновите оформление.',
        current: { cartId: snap.cartId, rowVersion: snap.rowVersion },
      });
    }
    if (customerMode && !Money.of(snap.manualDiscountTotal).isZero()) {
      throw forbidden403('Ручная скидка недоступна в режиме клиента.');
    }

    // Долг (10 PAY-031, ядро §22.4): решение корзины, иначе — CreditDecisionService (fail-closed до этапа G).
    let creditOverrideUsed = false;
    if (input.paymentMethod === 'credit') {
      if (customerId === retailId) {
        throw new ProblemException('CUSTOMER_NOT_IDENTIFIED', { detail: 'Для продажи в долг выберите клиента.' });
      }
      if (validation.credit) {
        if (!validation.credit.allowed) {
          await this.auditCreditBlocked(ctx.auditCtx, { customerId, total: snap.total, code: 'CREDIT_BLOCKED' });
          throw new ProblemException('CREDIT_BLOCKED', { detail: 'Продажа в долг недоступна.' });
        }
        creditOverrideUsed = validation.credit.overrideUsed;
      } else {
        const d = await this.credit.check(null, {
          actor,
          customerId,
          total: snap.total,
          override: input.creditOverride,
        });
        if (!d.allowed) {
          await this.auditCreditBlocked(ctx.auditCtx, {
            customerId,
            total: snap.total,
            code: d.code,
            creditReason: d.creditReason ?? null,
            limitRemaining: d.limitRemaining ?? null,
            receivablesAsOf: d.receivablesAsOf ? d.receivablesAsOf.toISOString() : null,
          });
          throw new ProblemException(d.code, {
            detail: d.detail,
            ...(d.creditReason ? { creditReason: d.creditReason } : {}),
          });
        }
        creditOverrideUsed = d.overrideUsed;
      }
    }

    // Мягкая защита от дубля (08 §2.7, ORD-022): тот же состав у заказа автора за 60 с.
    const compositionHash = orderCompositionHash({
      customerId,
      paymentMethod: input.paymentMethod,
      total: snap.total,
      items: snap.lines.map((l) => ({
        variantId: l.variantId,
        packagingId: l.packagingId,
        quantity: Quantity.of(l.quantity).toString(),
      })),
    });
    if (!input.confirmDuplicate && actor.userId) {
      const dup = await this.recentDuplicate(actor.userId, compositionHash);
      if (dup) {
        throw new ProblemException('ORDER_STATE_INVALID', {
          detail: `Похожий заказ ${dup.publicNumber} создан минуту назад. Создать ещё один?`,
          resource: 'order',
          reason: 'possible_duplicate',
          possibleDuplicateOrderId: dup.orderId,
          // OpenAPI 1.2.0 (08 §4.8.1 «Уточнения POST /orders» п. 4; FQ-CHK-04): номер и момент создания для UI-21-029.
          possibleDuplicatePublicNumber: dup.publicNumber,
          possibleDuplicateCreatedAt: dup.createdAt.toISOString(),
        });
      }
    }

    const onecChecked = validation.onecCheck.performed && validation.onecCheck.result === 'ok';
    const httpStatus: 201 | 202 = onecChecked ? 201 : 202;
    const warnings: Warning[] = [];
    if (httpStatus === 202) {
      warnings.push({
        code: 'STALE_DATA',
        message: 'Проверка в 1С не выполнена: заказ проверен по последнему снимку.',
      });
    }
    for (const w of validation.warnings) if (!warnings.some((x) => x.code === w.code)) warnings.push(w);

    const accountReceiver =
      customerMode && input.receiver.kind === 'customer' && actor.userId
        ? await this.accountContact(actor.userId)
        : null;
    // Скидка сверх лимита — только если подтверждение **применилось** (корзина: `overrideApplied`, подтверждающий —
    // `discountApprovedByUserId`): из этого запроса (`discountOverride` со step-up) или ранее в корзине
    // (POST /cart/discount с override и step-up). Причина, `transactions.kind=discount_override` и аудит по заказу
    // (10 DISC-010, DISC-012, 08 §4.7.5; ревью F-money-rules-3). `discountOverride` для скидки в пределах лимита
    // инициатора подтверждением не считается (ревью G-credit-5).
    const discountApproverId = snap.discountApprovedByUserId;
    const discountOverride: { readonly reason: string; readonly approverUserId: string } | null = discountApproverId
      ? { reason: snap.discountOverrideReason ?? 'подтверждено в корзине', approverUserId: discountApproverId }
      : null;
    const createdVia = customerMode ? 'customer' : 'staff';
    const orderId = newId();
    const now = this.clock.now();

    // (2) Одна короткая транзакция (ядро §22.3): внешних вызовов внутри нет.
    const committed = await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx.auditCtx);
      if (input.paymentMethod === 'credit') {
        // Лимит в долг — повторно в транзакции создания под блокировкой клиента, без 1С (08 API-071, 07 §5.31,
        // DEBT-011; ревью G-credit-3): параллельные заказы в долг одного клиента не превышают лимит вместе.
        const re = await recheckCreditInTx(tx, this.credit, {
          actor,
          customerId,
          total: snap.total,
          override: input.creditOverride,
        });
        if (!re.allowed) return { refused: re } as const;
        creditOverrideUsed = re.overrideUsed;
      }
      // Разблокировка в долг записывается, только если она применилась (PAY-032, DEBT-010; ревью G-credit-5).
      const creditApproval = creditOverrideUsed ? input.creditOverride : null;
      const num = await tx.execute<{ n: string }>(sql`SELECT nextval('orders_number_seq')::text AS n`);
      const publicNumber = `POS-${now.getUTCFullYear()}-${num.rows[0].n.padStart(6, '0')}`;
      const creditDays =
        input.paymentMethod === 'credit'
          ? ((
              await tx.execute<{ d: number | null }>(
                sql`SELECT credit_days AS d FROM customers WHERE id = ${customerId}::uuid`,
              )
            ).rows[0]?.d ?? null)
          : null;
      await tx.execute(sql`
        INSERT INTO orders (id, public_number, cart_id, status, customer_id, customer_name_snapshot, created_by_user_id,
                            created_via, device_id, warehouse_id, price_list_id, subtotal, discount_percent,
                            customer_discount_percent, customer_discount_total, manual_discount_total, discount_total,
                            total, discount_approved_by_user_id, discount_approved_at, discount_reason, payment_method,
                            credit_approved_by_user_id, credit_approved_at, credit_reason, credit_due_date,
                            delivery_method, receiver_kind, receiver_name, receiver_phone_e164,
                            delivery_recipient_phone_e164, delivery_address, delivery_comment, delivery_date,
                            delivery_time_from, delivery_time_to, print_options, comment, onec_sync_state,
                            price_check_at, onec_check_result, idempotency_key)
        VALUES (${orderId}::uuid, ${publicNumber}, ${snap.cartId}::uuid, 'draft', ${customerId}::uuid,
                (SELECT name FROM customers WHERE id = ${customerId}::uuid), ${actor.userId}::uuid, ${createdVia},
                ${actor.deviceId ? sql`(SELECT id FROM devices WHERE device_key = ${actor.deviceId} AND user_id = ${actor.userId}::uuid LIMIT 1)` : sql`NULL`},
                ${snap.warehouseId}::uuid, ${snap.priceListId}::uuid, ${snap.subtotal}::numeric,
                ${snap.manualDiscountPercent}::numeric, ${snap.customerDiscountPercent}::numeric,
                ${snap.customerDiscountTotal}::numeric, ${snap.manualDiscountTotal}::numeric,
                ${snap.discountTotal}::numeric, ${snap.total}::numeric, ${discountApproverId}::uuid,
                CASE WHEN ${discountApproverId}::uuid IS NULL THEN NULL ELSE now() END,
                ${discountOverride?.reason ?? null}, ${input.paymentMethod}::payment_method,
                ${creditApproval ? actor.userId : null}::uuid,
                CASE WHEN ${creditApproval !== null}::boolean THEN now() END,
                ${creditApproval?.reason ?? null},
                CASE WHEN ${creditDays}::int IS NULL THEN NULL ELSE current_date + ${creditDays}::int END,
                ${input.delivery.method}::delivery_method, ${input.receiver.kind}::receiver_kind,
                ${input.receiver.name ?? accountReceiver?.name ?? null},
                ${input.receiver.phone ?? accountReceiver?.phone ?? null},
                ${input.delivery.recipientPhone}, ${input.delivery.address}, ${input.delivery.courierComment},
                ${input.delivery.desiredDate}::date, ${input.delivery.timeFrom}::time, ${input.delivery.timeTo}::time,
                ${JSON.stringify(input.printOptions ?? { invoice: true, waybill: true, receipt: true })}::jsonb,
                ${input.comment}, 'unknown',
                ${validation.onecCheck.at ? validation.onecCheck.at.toISOString() : null}::timestamptz,
                ${JSON.stringify({ performed: validation.onecCheck.performed, result: validation.onecCheck.result })}::jsonb,
                ${input.idempotencyKey})`);
      for (const l of snap.lines) {
        await tx.execute(sql`
          INSERT INTO order_items (order_id, line_no, variant_id, product_id, packaging_id, quantity, base_quantity,
                                   unit_code_snapshot, packaging_name_snapshot, packaging_factor_snapshot, unit_price,
                                   line_subtotal, discount_percent, customer_discount_amount, manual_discount_amount,
                                   discount_amount, line_total, product_name_snapshot, variant_name_snapshot,
                                   sku_snapshot, barcode_snapshot)
          VALUES (${orderId}::uuid, ${l.lineNo}, ${l.variantId}::uuid, ${l.productId}::uuid, ${l.packagingId}::uuid,
                  ${l.quantity}::numeric, ${l.baseQuantity}::numeric, ${l.unitCode}, ${l.packagingName},
                  ${l.packagingFactor}::numeric, ${l.unitPrice}::numeric, ${l.lineSubtotal}::numeric,
                  ${snap.manualDiscountPercent}::numeric, ${l.customerDiscountAmount}::numeric,
                  ${l.manualDiscountAmount}::numeric, ${l.discountAmount}::numeric, ${l.lineTotal}::numeric,
                  ${l.productName}, ${l.variantName}, ${l.sku}, ${l.barcode})`);
      }
      await tx.execute(sql`
        UPDATE orders SET status = 'submitting', submitted_at = now(), onec_sync_state = 'pending',
               row_version = row_version + 1, updated_at = now()
         WHERE id = ${orderId}::uuid`);
      await insertHistory(tx, {
        orderId,
        from: 'draft',
        to: 'submitting',
        source: 'pos_system',
        actorUserId: actor.userId,
        requestId: ctx.auditCtx.requestId ?? null,
      });

      const payment = await this.payments.createInitial(tx, {
        orderId,
        customerId,
        method: input.paymentMethod,
        amount: snap.total,
        actor,
        idempotencyKey: initialPaymentIdempotencyKey(input.idempotencyKey),
      });

      const payload = await buildOnecOrderPayload(tx, {
        orderId,
        publicNumber,
        createdAt: now,
        createdByUserId: actor.userId ?? 'system',
        createdVia,
        customerId,
        paymentMethod: input.paymentMethod,
        snapshot: snap,
        delivery: {
          method: input.delivery.method,
          address: input.delivery.address,
          receiverName: input.receiver.name ?? accountReceiver?.name ?? null,
          receiverPhone: input.delivery.recipientPhone ?? input.receiver.phone ?? accountReceiver?.phone ?? null,
          desiredDate: input.delivery.desiredDate,
          timeFrom: input.delivery.timeFrom,
          timeTo: input.delivery.timeTo,
          courierComment: input.delivery.courierComment,
        },
        comment: input.comment,
      });
      await this.outbox.enqueue(tx, {
        aggregateType: 'order',
        aggregateId: orderId,
        operation: 'create',
        payload,
        dependsOnOutboxId: await customerCreateDependency(tx, customerId),
        requestedByUserId: actor.userId,
        warehouseId: snap.warehouseId,
      });

      const itemsHash = orderCompositionHash({
        customerId,
        paymentMethod: input.paymentMethod,
        total: snap.total,
        items: snap.lines.map((l) => ({ variantId: l.variantId, packagingId: l.packagingId, quantity: l.quantity })),
      });
      await insertOrderTransaction(tx, {
        kind: 'order_created',
        orderId,
        customerId,
        actorUserId: actor.userId,
        amount: snap.total,
        paymentMethod: input.paymentMethod,
        statusSnapshot: 'submitting',
        title: `Заказ ${publicNumber} создан`,
        details: { publicNumber, createdVia, itemsCount: snap.lines.length },
        dedupeKey: `order_created:${orderId}`,
      });
      if (creditApproval) {
        await insertOrderTransaction(tx, {
          kind: 'credit_sale_approved',
          orderId,
          customerId,
          actorUserId: actor.userId,
          amount: snap.total,
          paymentMethod: 'credit',
          statusSnapshot: 'submitting',
          title: `Продажа в долг по заказу ${publicNumber} подтверждена`,
          details: { reason: creditApproval.reason, total: snap.total },
          dedupeKey: `credit_sale_approved:${orderId}`,
        });
      }
      if (discountOverride) {
        await insertOrderTransaction(tx, {
          kind: 'discount_override',
          orderId,
          customerId,
          actorUserId: discountOverride.approverUserId,
          amount: snap.manualDiscountTotal,
          paymentMethod: input.paymentMethod,
          statusSnapshot: 'submitting',
          title: `Скидка сверх лимита по заказу ${publicNumber}`,
          details: {
            percent: snap.manualDiscountPercent,
            amount: snap.manualDiscountTotal,
            reason: discountOverride.reason,
            approvedIn: input.discountOverride ? 'order' : 'cart',
          },
          dedupeKey: `discount_override:${orderId}`,
        });
      }

      await this.cart.markConverted(tx, { cartId: snap.cartId, expectedRowVersion: input.cartRowVersion, orderId });

      // Аудит — последним (07 §9.3, B-AR-08).
      await this.audit.write(
        ctx.auditCtx,
        {
          action: 'order.created',
          entityType: 'order',
          entityId: orderId,
          after: {
            publicNumber,
            itemsHash,
            total: snap.total,
            paymentMethod: input.paymentMethod,
            customerId,
            createdVia,
            deviceId: actor.deviceId ?? null,
            onecChecked,
          },
        },
        tx,
      );
      if (discountOverride) {
        await this.audit.write(
          ctx.auditCtx,
          {
            action: 'discount.over_limit_approved',
            entityType: 'order',
            entityId: orderId,
            after: {
              percent: snap.manualDiscountPercent,
              approverUserId: discountOverride.approverUserId,
              approvedIn: input.discountOverride ? 'order' : 'cart',
            },
            reason: padReason(discountOverride.reason),
            // Подтверждение из корзины: step-up выполнен и записан в аудит `POST /cart/discount`.
            stepUpMethod: input.discountOverride ? ctx.stepUpMethod : null,
          },
          tx,
        );
      }
      if (creditApproval) {
        await this.audit.write(
          ctx.auditCtx,
          {
            action: 'credit.sale_approved',
            entityType: 'order',
            entityId: orderId,
            after: { total: snap.total, customerId },
            reason: padReason(creditApproval.reason),
            stepUpMethod: ctx.stepUpMethod,
          },
          tx,
        );
      }

      const row = await findOrder(tx, orderId);
      if (!row) throw new Error('orders: заказ не найден после INSERT');
      const body = await this.views.present(tx, ctx.viewer, row, { warnings });
      if (ctx.req)
        await this.idempotency.recordInTransaction(idempotencyExecutor(tx), ctx.req, httpStatus, body, orderId);
      return { paymentId: payment.paymentId, body };
    });
    if (committed.refused) {
      const refusal = creditRecheckRefusal(committed.refused, customerId, snap.total);
      await this.auditCreditBlocked(ctx.auditCtx, refusal.audit);
      throw refusal.problem;
    }

    // (3) После COMMIT: «быстрая доставка» в 1С и QR начального платежа (ответ API их не ждёт от 1С-документа).
    await this.outbox.kickAfterCommit().catch((err: unknown) => this.logger.warn({ err }, 'orders.kick_failed'));
    if (input.paymentMethod === 'qr_bakai' && permissions.has('payment.qr.show')) {
      try {
        const qr = await this.payments.afterCommit(committed.paymentId, actor);
        for (const w of qr.warnings) if (!warnings.some((x) => x.code === w.code)) warnings.push(w);
      } catch (e) {
        if (!(e instanceof PortNotBoundError)) this.logger.warn({ err: e, orderId }, 'orders.qr_after_commit_failed');
        warnings.push({
          code: 'QR_UNAVAILABLE',
          message: 'QR не сформирован: повторите «Обновить QR» или ручное подтверждение.',
        });
      }
    }
    let body = committed.body;
    try {
      body = await this.views.presentById(ctx.viewer, orderId, { warnings });
      // Повтор с тем же ключом отдаёт текущее представление (с QR, выданным после COMMIT) — 08 §4.8.1, B-AR-04.
      const state = ctx.req ? getIdempotencyState(ctx.req) : undefined;
      if (state) await this.idempotency.complete(state.scope, httpStatus, body, orderId);
    } catch (e) {
      this.logger.warn({ err: e, orderId }, 'orders.present_after_commit_failed');
    }
    this.logger.log({ event: 'order.created', orderId, httpStatus, paymentMethod: input.paymentMethod });
    return { httpStatus, orderId, body };
  }

  private async recentDuplicate(
    userId: string,
    hash: string,
  ): Promise<{ readonly orderId: string; readonly publicNumber: string; readonly createdAt: Date } | null> {
    const r = await this.db.execute<{
      id: string;
      public_number: string;
      customer_id: string;
      payment_method: string;
      total: string;
      created_at: Date;
      items: { v: string; p: string | null; q: string }[];
    }>(sql`
      SELECT o.id, o.public_number, o.customer_id, o.payment_method::text AS payment_method, o.total::text AS total,
             o.created_at,
             (SELECT json_agg(json_build_object('v', i.variant_id, 'p', i.packaging_id, 'q', i.quantity::text))
                FROM order_items i WHERE i.order_id = o.id) AS items
        FROM orders o
       WHERE o.created_by_user_id = ${userId}::uuid AND o.status <> 'draft'
         AND o.created_at > now() - interval '60 seconds'
       ORDER BY o.created_at DESC LIMIT 5`);
    const now = this.clock.now();
    for (const o of r.rows) {
      const prevHash = orderCompositionHash({
        customerId: o.customer_id,
        paymentMethod: o.payment_method,
        total: o.total,
        items: (o.items ?? []).map((i) => ({
          variantId: i.v,
          packagingId: i.p,
          quantity: Quantity.of(i.q).toString(),
        })),
      });
      const createdAt = new Date(o.created_at);
      if (isSoftDuplicate({ compositionHash: prevHash, createdAt }, hash, now, false)) {
        return { orderId: o.id, publicNumber: o.public_number, createdAt };
      }
    }
    return null;
  }

  /**
   * Отказ в продаже в долг при `POST /orders` — аудит `credit.sale_blocked` (11 §7.2: «система; customer_id, сумма
   * долга, лимит, причина блокировки»; ревью F-security-5). Пишется отдельной командой вне транзакции заказа:
   * заказа нет, а сбой записи аудита не должен подменять ответ 422.
   */
  private async auditCreditBlocked(
    ctx: AuditContext,
    d: {
      readonly customerId: string | null;
      readonly total: string | null;
      readonly code: string;
      readonly creditReason?: string | null;
      readonly limitRemaining?: string | null;
      readonly receivablesAsOf?: string | null;
    },
  ): Promise<void> {
    try {
      await this.audit.write(ctx, {
        action: 'credit.sale_blocked',
        entityType: 'customer',
        entityId: d.customerId,
        result: 'denied',
        after: {
          customerId: d.customerId,
          total: d.total,
          // `code` вырезается санитайзером аудита (секреты OTP) — имя поля `refusalCode`.
          refusalCode: d.code,
          creditReason: d.creditReason ?? null,
          limitRemaining: d.limitRemaining ?? null,
          receivablesAsOf: d.receivablesAsOf ?? null,
        },
      });
    } catch (err) {
      this.logger.warn({ err, customerId: d.customerId }, 'orders.credit_blocked.audit_failed');
    }
    await notifyCreditBlocked(this.notifications, this.logger, {
      userId: ctx.actorUserId,
      customerId: d.customerId,
      code: d.code,
      creditReason: d.creditReason,
      requestId: ctx.requestId,
    });
  }

  private async accountContact(userId: string): Promise<{ name: string | null; phone: string | null }> {
    const r = await this.db.execute<{ name: string | null; phone: string | null }>(sql`
      SELECT p.full_name AS name, u.phone_e164 AS phone
        FROM users u LEFT JOIN user_profiles p ON p.user_id = u.id WHERE u.id = ${userId}::uuid`);
    return r.rows[0] ?? { name: null, phone: null };
  }
}

function headerOf(req: RequestWithContext, name: string): string | undefined {
  const v = req.headers[name];
  const s = Array.isArray(v) ? v[0] : v;
  return typeof s === 'string' && s !== '' ? s : undefined;
}

function forbidden403(detail: string): ProblemException {
  return new ProblemException('FORBIDDEN', { detail });
}

/** Причина в аудите ≥ 5 символов (11 SEC-076). */
function padReason(reason: string): string {
  return reason.length >= 5 ? reason : `причина: ${reason}`;
}

function toCreateInput(key: string, b: CreateOrderBody): CreateInput {
  return {
    idempotencyKey: key,
    cartId: b.cartId,
    cartRowVersion: b.cartRowVersion,
    customerId: b.customerId ?? null,
    paymentMethod: b.paymentMethod,
    ...(b.manualDiscountPercent !== undefined ? { manualDiscountPercent: b.manualDiscountPercent } : {}),
    discountOverride: b.discountOverride ?? null,
    creditOverride: b.creditOverride ?? null,
    receiver: { kind: b.receiver.kind, name: b.receiver.name ?? null, phone: b.receiver.phone ?? null },
    delivery: {
      method: b.delivery.method,
      address: b.delivery.address ?? null,
      recipientPhone: b.delivery.recipientPhone ?? null,
      courierComment: b.delivery.courierComment ?? null,
      desiredDate: b.delivery.desiredDate ?? null,
      timeFrom: b.delivery.timeFrom ?? null,
      timeTo: b.delivery.timeTo ?? null,
    },
    printOptions: b.printOptions ? { invoice: true, waybill: true, receipt: true, ...b.printOptions } : null,
    comment: b.comment ?? null,
    confirmDuplicate: b.confirmDuplicate ?? false,
    previewToken: b.previewToken ?? null,
    items: b.items.map((i) => ({
      variantId: i.variantId,
      packagingId: i.quantity.packagingId ?? null,
      quantity: i.quantity.value,
    })),
  };
}

/** `items[]` тела совпадает с корзиной `cartRowVersion` (вариант, упаковка, количество — без учёта порядка). */
export function sameItems(
  items: readonly { readonly variantId: string; readonly packagingId: string | null; readonly quantity: string }[],
  lines: readonly { readonly variantId: string; readonly packagingId: string | null; readonly quantity: string }[],
): boolean {
  if (items.length !== lines.length) return false;
  // Количество — 3 знака (08 §3.2 Quantity): сверка через Quantity, не Money (ревью F-money-rules-7).
  const key = (v: string, p: string | null, q: string) => `${v}|${p ?? ''}|${Quantity.of(q).toString()}`;
  const a = items.map((i) => key(i.variantId.toLowerCase(), i.packagingId?.toLowerCase() ?? null, i.quantity)).sort();
  const b = lines.map((l) => key(l.variantId.toLowerCase(), l.packagingId?.toLowerCase() ?? null, l.quantity)).sort();
  return a.every((x, i) => x === b[i]);
}

/** `422` со всеми конфликтами (ядро §19.2): код — по первому конфликту (`PRICE_CHANGED` / `STOCK_INSUFFICIENT` / …). */
function conflictsProblem(v: CheckoutValidation): ProblemException {
  const CODE: Record<
    string,
    'PRICE_CHANGED' | 'STOCK_INSUFFICIENT' | 'VARIANT_UNAVAILABLE' | 'QTY_NOT_MULTIPLE' | 'QTY_BELOW_MIN'
  > = {
    price_changed: 'PRICE_CHANGED',
    stock_insufficient: 'STOCK_INSUFFICIENT',
    variant_unavailable: 'VARIANT_UNAVAILABLE',
    qty_not_multiple: 'QTY_NOT_MULTIPLE',
    qty_below_min: 'QTY_BELOW_MIN',
  };
  const first = v.conflicts[0];
  return new ProblemException(first ? (CODE[first.kind] ?? 'PRICE_CHANGED') : 'PRICE_CHANGED', {
    detail: 'Корзина изменилась: проверьте цены и остатки.',
    conflicts: v.conflicts,
  });
}
