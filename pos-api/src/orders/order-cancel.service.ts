import { Inject, Injectable, Logger } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { StepUpTokenVerifier } from '../auth/step-up/step-up-token.verifier.js';
import { applyAuditGucs, auditContextFromRequest } from '../common/audit/audit-context.js';
import { AuditService } from '../common/audit/audit.service.js';
import type { AuthenticatedPrincipal } from '../common/auth/principal.js';
import { DRIZZLE, type Database } from '../common/db/database.module.js';
import type { RequestWithContext } from '../common/http/request-context.js';
import { IdempotencyService } from '../common/idempotency/idempotency.service.js';
import { Money } from '../common/money/money.js';
import {
  CART_READER,
  type CartReader,
  NOTIFICATIONS_PORT,
  type NotificationsPort,
  ONEC_OUTBOX_WRITER,
  type OnecOutboxWriter,
  PAYMENTS_PORT,
  type PaymentsPort,
  PortNotBoundError,
} from '../common/ports/index.js';
import { ProblemException } from '../common/problem-details/problem.exception.js';
import { assertOrderTransition, decideOrderCancel } from '../sales-domain/order/order-status.js';
import { isSalesDomainError, SalesDomainError } from '../sales-domain/domain-error.js';
import { toProblemException } from '../sales-domain/problem.js';
import { insertOrderTransaction, OrderProjector } from './order-projection.js';
import { OrderViewService } from './order-view.service.js';
import { findOrder, findOrderOutbox, insertHistory } from './order.repository.js';
import { parseCancelBody, validationFailed } from './orders.request.js';
import { idempotencyExecutor } from './sql-executor.js';

/**
 * `POST /orders/{id}/cancel` (08 §4.8.4; 10 ORD-050…ORD-053 — владелец; ядро §22.9; 07 §6.3). Решение —
 * `decideOrderCancel` (sales-domain): (а) немедленная отмена заказа `submitting`, документ 1С которого не создан
 * (outbox `create` в `pending`/`dead` → `cancelled`), неполученные платежи → `voided`, состав → корзина (ORD-027);
 * (б) запрос отмены — outbox `cancel` (`POST /pos/v1/orders/{uuid}/cancel`), статус меняет только 1С.
 * `order.cancel.own` — без step-up; `order.cancel.request.any` — со step-up. Платёж `manual_confirm` → `409
 * PAYMENT_STATE_INVALID` (`open_payment_exists`). Транзакция `order_cancelled` — только при фактической отмене.
 */
@Injectable()
export class OrderCancelService {
  private readonly logger = new Logger('orders.cancel');
  private readonly projector: OrderProjector;

  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    @Inject(PAYMENTS_PORT) private readonly payments: PaymentsPort,
    @Inject(ONEC_OUTBOX_WRITER) private readonly outbox: OnecOutboxWriter,
    @Inject(CART_READER) private readonly cart: CartReader,
    @Inject(NOTIFICATIONS_PORT) notifications: NotificationsPort,
    private readonly audit: AuditService,
    private readonly idempotency: IdempotencyService,
    private readonly stepUp: StepUpTokenVerifier,
    private readonly views: OrderViewService,
  ) {
    this.projector = new OrderProjector(notifications, (msg, data) => this.logger.warn(data ?? {}, msg));
  }

  async cancel(
    principal: AuthenticatedPrincipal,
    req: RequestWithContext & { ip?: string },
    orderId: string,
    rawBody: unknown,
    stepUpToken: string | undefined,
  ): Promise<Record<string, unknown>> {
    const body = parseCancelBody(rawBody);
    const auditCtx = auditContextFromRequest(req);
    const viewer = await this.views.viewer(principal, typeof req.id === 'string' ? req.id : null);
    const { actor, permissions } = viewer;

    const decide = async () => {
      const o = await this.views.loadVisible(this.db, viewer, orderId);
      const payments = await this.views.paymentsOf(o.id);
      const review = payments.find((p) => p.status === 'manual_confirm');
      if (review) {
        throw new ProblemException('PAYMENT_STATE_INVALID', {
          detail: 'По заказу есть платёж на разборе: сначала подтвердите или аннулируйте его.',
          reason: 'open_payment_exists',
          openPaymentId: review.paymentId,
        });
      }
      const hasReceived =
        Money.of(o.paid_amount).compare(Money.ZERO) > 0 || payments.some((p) => p.status === 'received');
      const createOutbox = await findOrderOutbox(this.db, o.id, 'create');
      const decision = decideOrderCancel({
        status: o.status,
        hasOnecRef: o.onec_ref !== null,
        createOutbox: createOutbox ? { status: createOutbox.status, attempts: Number(createOutbox.attempts) } : null,
        hasReceivedPayments: hasReceived,
        isOwn: o.created_by_user_id === actor.userId,
        cancelAlreadyRequested: o.cancel_requested_at !== null,
        canCancelOwn: permissions.has('order.cancel.own'),
        canRequestAny: permissions.has('order.cancel.request.any'),
      });
      return { o, decision, hasReceived };
    };

    let first;
    try {
      first = await decide();
    } catch (e) {
      throw cancelProblem(e);
    }
    let stepUpMethod: 'pin' | 'otp' | null = null;
    if (first.decision.requiresStepUp) {
      stepUpMethod = (await this.stepUp.verify(stepUpToken, principal, { operation: 'order.cancel.request.any' }))
        .method;
    }
    const refundRequired = first.decision.kind === 'request' ? first.decision.refundIntentRequired : false;
    if (refundRequired && !body.refundIntent) {
      throw validationFailed([
        { field: 'refundIntent', rule: 'required', message: 'Укажите, что делать с полученными деньгами.' },
      ]);
    }

    const auditReason = `${body.reasonCode}: ${body.reason}`;
    let cancelledNow = false;
    try {
      await this.db.transaction(async (tx) => {
        await applyAuditGucs(tx, auditCtx);
        const o = await findOrder(tx, orderId, true);
        if (!o) throw new ProblemException('NOT_FOUND', { detail: 'Заказ не найден.' });
        const createOutbox = await this.outbox.lock(tx, {
          aggregateType: 'order',
          aggregateId: o.id,
          operation: 'create',
        });
        // Повторное решение под блокировкой: состояние могло измениться (воркер, параллельный запрос).
        const decision = decideOrderCancel({
          status: o.status,
          hasOnecRef: o.onec_ref !== null,
          createOutbox: createOutbox ? { status: createOutbox.status, attempts: createOutbox.attempts } : null,
          hasReceivedPayments: first.hasReceived || Money.of(o.paid_amount).compare(Money.ZERO) > 0,
          isOwn: o.created_by_user_id === actor.userId,
          cancelAlreadyRequested: o.cancel_requested_at !== null,
          canCancelOwn: permissions.has('order.cancel.own'),
          canRequestAny: permissions.has('order.cancel.request.any'),
        });
        if (decision.requiresStepUp && stepUpMethod === null) {
          throw StepUpTokenVerifier.required('order.cancel.request.any');
        }
        await tx.execute(sql`
          UPDATE orders SET cancel_reason = ${body.reason}, cancel_reason_code = ${body.reasonCode},
                 refund_intent = ${body.refundIntent ?? null},
                 cancel_requested_at = CASE WHEN ${decision.kind === 'request'}::boolean THEN now() ELSE cancel_requested_at END,
                 cancel_requested_by_user_id = ${actor.userId}::uuid,
                 row_version = row_version + 1, updated_at = now()
           WHERE id = ${o.id}::uuid`);

        if (decision.kind === 'cancel_now') {
          cancelledNow = true;
          if (createOutbox) await this.outbox.cancel(tx, createOutbox.outboxId);
          if (decision.outbox === 'cancel_create_and_enqueue_cancel') {
            // Была попытка с неизвестным результатом: защитная отмена в 1С (ядро §22.9, ORD-050).
            await this.outbox.enqueue(tx, {
              aggregateType: 'order',
              aggregateId: o.id,
              operation: 'cancel',
              payload: { reason: body.reason },
              requestedByUserId: actor.userId,
              warehouseId: o.warehouse_id,
            });
          }
          assertOrderTransition(o.status, 'cancelled', 'pos_user');
          await tx.execute(sql`
            UPDATE orders SET status = 'cancelled', cancelled_at = now(), onec_sync_state = 'unknown',
                   row_version = row_version + 1, updated_at = now()
             WHERE id = ${o.id}::uuid`);
          await insertHistory(tx, {
            orderId: o.id,
            from: o.status,
            to: 'cancelled',
            source: 'pos_user',
            actorUserId: actor.userId,
            reason: body.reason,
            requestId: auditCtx.requestId ?? null,
          });
          await this.voidOpenPayments(tx, o.id, actor);
          await this.restoreCart(tx, o.id, o.created_by_user_id);
          await insertOrderTransaction(tx, {
            kind: 'order_cancelled',
            orderId: o.id,
            customerId: o.customer_id,
            actorUserId: actor.userId,
            amount: o.total,
            paymentMethod: o.payment_method,
            statusSnapshot: 'cancelled',
            title: `Заказ ${o.public_number} отменён`,
            details: { reasonCode: body.reasonCode, via: decision.via },
            dedupeKey: `order_cancelled:${o.id}`,
          });
          if (o.created_by_user_id !== actor.userId) await this.projector.notifyOwner(tx, o, 'cancelled');
          await this.audit.write(
            auditCtx,
            {
              action: 'order.cancelled',
              entityType: 'order',
              entityId: o.id,
              before: { status: o.status },
              after: {
                status: 'cancelled',
                reasonCode: body.reasonCode,
                refundIntent: body.refundIntent ?? null,
                via: decision.via,
              },
              reason: auditReason,
              stepUpMethod,
            },
            tx,
          );
        } else {
          const createId = createOutbox?.outboxId ?? null;
          // Повторный запрос после отказа 1С (cancelRequested снят, 08 §4.8.4): строка `cancel` уже есть в
          // `failed`/`dead` (UNIQUE агрегат+операция) — переотправляется с новым телом, а не теряется молча
          // (ревью F-orders-1c-3; 07 §6.5 `manual_retry`).
          const prevCancel = await this.outbox.lock(tx, {
            aggregateType: 'order',
            aggregateId: o.id,
            operation: 'cancel',
          });
          if (prevCancel && (prevCancel.status === 'failed' || prevCancel.status === 'dead')) {
            await this.outbox.requeue(tx, {
              outboxId: prevCancel.outboxId,
              payload: { reason: body.reason },
              requestedByUserId: actor.userId,
            });
          } else {
            await this.outbox.enqueue(tx, {
              aggregateType: 'order',
              aggregateId: o.id,
              operation: 'cancel',
              payload: { reason: body.reason },
              dependsOnOutboxId: decision.outbox === 'enqueue_cancel_after_create' ? createId : null,
              requestedByUserId: actor.userId,
              warehouseId: o.warehouse_id,
            });
          }
          await this.audit.write(
            auditCtx,
            {
              action: 'order.cancel_requested',
              entityType: 'order',
              entityId: o.id,
              after: {
                status: o.status,
                reasonCode: body.reasonCode,
                refundIntent: body.refundIntent ?? null,
                paidAmount: o.paid_amount,
                via: decision.via,
              },
              reason: auditReason,
              stepUpMethod,
            },
            tx,
          );
        }
        const row = await findOrder(tx, o.id);
        if (!row) throw new Error('orders: заказ пропал');
        const out = await this.views.present(tx, viewer, row);
        await this.idempotency.recordInTransaction(idempotencyExecutor(tx), req, 200, out, o.id);
      });
    } catch (e) {
      throw cancelProblem(e);
    }
    await this.outbox.kickAfterCommit().catch(() => undefined);
    this.logger.log({ event: cancelledNow ? 'order.cancelled' : 'order.cancel_requested', orderId });
    return this.views.presentById(viewer, orderId);
  }

  private async voidOpenPayments(
    tx: Parameters<PaymentsPort['voidOpenForOrderCancel']>[0],
    orderId: string,
    actor: { userId: string | null; roles: readonly string[]; isCustomer: boolean },
  ): Promise<void> {
    try {
      await this.payments.voidOpenForOrderCancel(tx, { orderId, actor });
    } catch (e) {
      if (e instanceof PortNotBoundError) {
        this.logger.warn({ orderId }, 'orders.cancel.payments_port_not_bound');
        return;
      }
      throw e;
    }
  }

  private async restoreCart(
    tx: Parameters<CartReader['restoreFromOrder']>[0],
    orderId: string,
    ownerUserId: string,
  ): Promise<void> {
    try {
      await this.cart.restoreFromOrder(tx, { orderId, ownerUserId });
    } catch (e) {
      if (e instanceof PortNotBoundError) {
        this.logger.warn({ orderId }, 'orders.cancel.cart_port_not_bound');
        return;
      }
      throw e;
    }
  }
}

/**
 * Ошибка отмены → Problem. Домен называет «статус не допускает отмену» `not_cancellable`, контракт 08 §4.8.4 —
 * `reason: invalid_transition` (FQ-ORD-09): приводим к контракту.
 */
function cancelProblem(e: unknown): unknown {
  if (isSalesDomainError(e) && e.extensions.reason === 'not_cancellable') {
    return toProblemException(
      new SalesDomainError(e.code, e.detail, { ...e.extensions, reason: 'invalid_transition' }, e.status),
    );
  }
  return toProblemException(e);
}
