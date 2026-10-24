import { Inject, Injectable, Logger } from '@nestjs/common';
import { applyAuditGucs } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { DRIZZLE, type Database } from '../../common/db/database.module.js';
import { getIdempotencyState } from '../../common/idempotency/idempotency.context.js';
import { IdempotencyService } from '../../common/idempotency/idempotency.service.js';
import { Money } from '../../common/money/money.js';
import { ORDER_STATUS_PORT, type OrderPaymentView, type OrderStatusPort } from '../../common/ports/index.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { assertOrderAcceptsPayment, orderStateInvalid } from '../../sales-domain/order/order-status.js';
import {
  assertPaymentTransition,
  type NewPaymentPlan,
  PAYMENT_USER_VOIDABLE,
  paymentStateInvalid,
  planConfirmManual,
  planNewPayment,
} from '../../sales-domain/payment/payment-status.js';
import { toProblemException } from '../../sales-domain/problem.js';
import type {
  MoneyInput,
  OrdersPaymentCreateRequest,
  PaymentsConfirmManualRequest,
  PaymentsVoidRequest,
} from '../api/payments.dto.js';
import type { PaymentsStepUp } from '../api/payments-step-up.guard.js';
import { PaymentJournal } from '../infra/payment-journal.js';
import { PaymentsLookups } from '../infra/payments-lookups.js';
import { type PaymentRow, PaymentsRepository } from '../infra/payments.repository.js';
import { idempotencyExecutor } from '../infra/sql-executor.js';
import { PaymentStatusWaiter } from '../long-poll/payment-status-waiter.js';
import { QrIssuer } from '../qr/qr-issuer.service.js';
import { QrProviders } from '../qr/qr-providers.js';
import { QrStatusService } from '../qr/qr-status.service.js';
import { type PaymentsCaller, seesAllOrders, seesAllPayments, toSalesActor } from './payments-caller.js';
import {
  type AllowedAction,
  allowedActions,
  isProviderQr,
  money,
  type MoneyDto,
  type PaymentDto,
  presentPayment,
  referencedUsers,
  type WarningDto,
} from './payment-presenter.js';
import { PaymentStateWriter } from './payment-state.writer.js';

export interface OrderPaymentResultDto extends PaymentDto {
  readonly order: { readonly paidAmount: MoneyDto; readonly isPaid: boolean };
}

export interface HttpResult<T> {
  readonly status: 200 | 201;
  readonly body: T;
}

const NOT_FOUND_ORDER = () => new ProblemException('NOT_FOUND', { detail: 'Заказ не найден.' });
const NOT_FOUND_PAYMENT = () => new ProblemException('NOT_FOUND', { detail: 'Платёж не найден.' });

function validation(field: string, rule: string, message: string, status: 400 | 422 = 400): ProblemException {
  return new ProblemException('VALIDATION_FAILED', { status, detail: message, errors: [{ field, rule, message }] });
}

/**
 * Доменная ошибка → Problem. Причина `open_payment_exists` и `openPaymentId` формирует домен (`planNewPayment`) по
 * контракту 08 — перевода имён нет (FQ-PAY-06).
 */
const domainToProblem = toProblemException;

interface AcceptPlan {
  readonly status: 200 | 201;
  readonly payment: PaymentRow;
  /** После COMMIT: выдать/перевыпустить QR на этом платеже. */
  readonly issueQr: boolean;
  /** После COMMIT: отменить QR в 1С у аннулированных системой платежей. */
  readonly cancelQr: readonly string[];
  readonly paidAmount: string;
  readonly isPaid: boolean;
}

/**
 * Сценарии HTTP модуля `payments` (08 §4.8.6, §4.9.2–§4.9.4; 10 §9; ядро §22.2, §22.5, §23 пп. 3–4, §24.4):
 * приём оплаты по заказу (наличные, QR, «Обновить QR», смена способа с системным аннулированием), чтение с
 * long-polling, ручное подтверждение QR и ручной void. Денежные операции записывают итог идемпотентности в своей
 * транзакции (B-AR-04).
 */
@Injectable()
export class PaymentsService {
  private readonly logger = new Logger('payments');

  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    @Inject(CLOCK) private readonly clock: Clock,
    @Inject(ORDER_STATUS_PORT) private readonly orders: OrderStatusPort,
    private readonly repo: PaymentsRepository,
    private readonly lookups: PaymentsLookups,
    private readonly writer: PaymentStateWriter,
    private readonly journal: PaymentJournal,
    private readonly audit: AuditService,
    private readonly idempotency: IdempotencyService,
    private readonly providers: QrProviders,
    private readonly qrIssuer: QrIssuer,
    private readonly qrStatus: QrStatusService,
    private readonly waiter: PaymentStatusWaiter,
  ) {}

  // ------------------------------------------------------------------------------------- POST /orders/{id}/payments

  async acceptForOrder(
    caller: PaymentsCaller,
    orderId: string,
    body: OrdersPaymentCreateRequest,
    idempotencyKey: string,
    req: object,
  ): Promise<HttpResult<OrderPaymentResultDto>> {
    const method = body.method;
    this.checkAcceptRequest(caller, body);
    let plan: AcceptPlan;
    try {
      plan = await this.db.transaction(async (tx) => {
        await applyAuditGucs(tx, caller.audit);
        const order = await this.orders.lockForPayment(tx, orderId);
        if (!order || !(await this.ownsOrder(tx, caller, order))) throw NOT_FOUND_ORDER();
        if (method === 'credit' || order.paymentMethod === 'credit') {
          throw orderStateInvalid(
            order.status,
            'payment_method_mismatch',
            'Долг задаётся только при создании заказа: отмените заказ и оформите новый.',
          );
        }
        assertOrderAcceptsPayment(order.status, order.isPaid);
        const open = await this.repo.findOpenForOrder(tx, orderId);
        const plan0: NewPaymentPlan = planNewPayment(
          open ? { id: open.id, method: open.method, status: open.status } : null,
          method,
        );
        const result =
          method === 'cash'
            ? await this.acceptCash(tx, caller, order, open, plan0, body, idempotencyKey)
            : await this.acceptQr(tx, caller, order, open, plan0, body, idempotencyKey);
        await this.idempotency.recordInTransaction(
          idempotencyExecutor(tx),
          req,
          result.status,
          await this.orderResult(result.payment, caller, result.paidAmount, result.isPaid, []),
          result.payment.id,
        );
        return result;
      });
    } catch (e) {
      throw domainToProblem(e);
    }

    for (const id of plan.cancelQr) this.qrStatus.cancelInBackground(id, 'method_changed');
    let payment = plan.payment;
    let warnings: readonly WarningDto[] = [];
    if (plan.issueQr) {
      const issued = await this.qrIssuer.issue({
        paymentId: payment.id,
        manualOnly: body.manualOnly === true,
        actorUserId: caller.userId,
        audit: caller.audit,
      });
      payment = issued.payment ?? payment;
      warnings = issued.warnings;
    }
    const final = await this.orderResult(payment, caller, plan.paidAmount, plan.isPaid, warnings);
    if (plan.issueQr) await this.updateStoredResult(req, plan.status, final, payment.id);
    return { status: plan.status, body: final };
  }

  /** Права по способу (08 §4.8.6; 11 §4.4) и форма тела — до транзакции. */
  private checkAcceptRequest(caller: PaymentsCaller, body: OrdersPaymentCreateRequest): void {
    if (body.method === 'cash') {
      if (!caller.perms.has('payment.cash.receive')) {
        throw new ProblemException('FORBIDDEN', {
          detail: 'Приём наличных выполняет кассир.',
          reason: 'payment_method_not_permitted',
        });
      }
      if (body.reissueQr || body.manualOnly) {
        throw validation('method', 'not_applicable', 'reissueQr и manualOnly применимы только к оплате QR.');
      }
      return;
    }
    if (body.method === 'qr_bakai') {
      if (!caller.perms.has('payment.qr.show')) {
        throw new ProblemException('FORBIDDEN', {
          detail: 'Показ QR для вашей роли недоступен.',
          reason: 'payment_method_not_permitted',
        });
      }
      if (body.receivedAmount !== undefined) {
        throw validation('receivedAmount', 'not_applicable', 'receivedAmount — только для оплаты наличными.');
      }
      if (caller.isCustomer) {
        if (body.manualOnly) {
          throw new ProblemException('FORBIDDEN', {
            detail: 'Ручное подтверждение оплаты выполняет магазин.',
            reason: 'manual_only_not_permitted',
          });
        }
        if (this.providers.mode === 'none') {
          throw validation('method', 'payment_method_unavailable', 'Оплата QR сейчас недоступна.', 422);
        }
      }
    }
  }

  private async acceptCash(
    tx: DbExecutor,
    caller: PaymentsCaller,
    order: OrderPaymentView,
    open: PaymentRow | null,
    plan: NewPaymentPlan,
    body: OrdersPaymentCreateRequest,
    idempotencyKey: string,
  ): Promise<AcceptPlan> {
    const cancelQr: string[] = [];
    let payment: PaymentRow;
    let status: 200 | 201 = 201;
    const due = this.dueAmount(order);
    if (plan.kind === 'reuse' && open) {
      payment = open;
      status = 200;
    } else {
      if (plan.kind === 'void_and_create' && open) {
        this.assertReceivedAmount(body.receivedAmount, due);
        const voided = await this.writer.systemVoid(tx, open, 'method_changed', {
          orderPublicNumber: order.publicNumber,
          initiatedBy: caller.userId,
          requestId: caller.requestId,
        });
        if (isProviderQr(voided)) cancelQr.push(voided.id);
      }
      payment = await this.repo.insert(tx, {
        orderId: order.orderId,
        customerId: order.customerId,
        method: 'cash',
        qrProvider: null,
        status: 'cash_pending',
        amount: due.toString(),
        createdByUserId: caller.userId ?? order.createdByUserId,
        idempotencyKey,
        requestId: caller.requestId,
      });
    }
    const amount = Money.of(payment.amount);
    const received = this.assertReceivedAmount(body.receivedAmount, amount);
    const now = this.clock.now();
    const res = await this.writer.receive(tx, {
      payment,
      order,
      actorKind: 'user',
      salesActor: toSalesActor(caller),
      patch: {
        receivedByUserId: caller.userId,
        receivedAt: now,
        receivedAmount: received ? received.toString() : null,
        changeAmount: received ? received.minus(amount).toString() : null,
      },
      journal: 'payment_received',
      journalDetails: {
        confirmationKind: 'cash',
        receivedAmount: received?.toString() ?? null,
        changeAmount: received ? received.minus(amount).toString() : null,
        ...(body.comment ? { comment: body.comment } : {}),
      },
      audit: {
        ctx: caller.audit,
        action: 'payment.received',
        after: {
          confirmationKind: 'cash',
          receivedAmount: received?.toString() ?? null,
          changeAmount: received ? received.minus(amount).toString() : null,
          voidedPaymentId: plan.kind === 'void_and_create' ? plan.voidPaymentId : null,
        },
      },
    });
    return { status, payment: res.payment, issueQr: false, cancelQr, paidAmount: res.paidAmount, isPaid: res.isPaid };
  }

  private async acceptQr(
    tx: DbExecutor,
    caller: PaymentsCaller,
    order: OrderPaymentView,
    open: PaymentRow | null,
    plan: NewPaymentPlan,
    body: OrdersPaymentCreateRequest,
    idempotencyKey: string,
  ): Promise<AcceptPlan> {
    const base = { paidAmount: Money.of(order.paidAmount).toString(), isPaid: order.isPaid };
    if (plan.kind === 'reuse' && open) {
      if (open.status === 'manual_confirm') {
        throw new ProblemException('PAYMENT_STATE_INVALID', {
          detail: 'Платёж на разборе: подтвердите его по выписке или аннулируйте.',
          reason: 'open_payment_exists',
          openPaymentId: open.id,
          currentStatus: open.status,
        });
      }
      // qr_pending → формирование; qr_expired → «Обновить QR»; qr_shown → перевыпуск по reissueQr/manualOnly,
      // иначе — текущее представление (повтор показа, B-AR-04).
      const issue =
        open.status === 'qr_pending' ||
        open.status === 'qr_expired' ||
        (open.status === 'qr_shown' && (body.reissueQr === true || body.manualOnly === true));
      return { status: 200, payment: open, issueQr: issue, cancelQr: [], ...base };
    }
    if (body.reissueQr) {
      throw paymentStateInvalid(
        open?.status ?? 'initiated',
        'transition_not_allowed',
        'Нет QR-платежа для перевыпуска.',
      );
    }
    const cancelQr: string[] = [];
    if (plan.kind === 'void_and_create' && open) {
      const voided = await this.writer.systemVoid(tx, open, 'method_changed', {
        orderPublicNumber: order.publicNumber,
        initiatedBy: caller.userId,
        requestId: caller.requestId,
      });
      if (isProviderQr(voided)) cancelQr.push(voided.id);
    }
    assertPaymentTransition('initiated', 'qr_pending', 'system');
    const payment = await this.repo.insert(tx, {
      orderId: order.orderId,
      customerId: order.customerId,
      method: 'qr_bakai',
      qrProvider: this.providers.mode,
      status: 'qr_pending',
      amount: this.dueAmount(order).toString(),
      createdByUserId: caller.userId ?? order.createdByUserId,
      idempotencyKey,
      requestId: caller.requestId,
    });
    return { status: 201, payment, issueQr: true, cancelQr, ...base };
  }

  private dueAmount(order: OrderPaymentView): Money {
    const due = Money.of(order.total).minus(Money.of(order.paidAmount));
    if (due.compare(Money.ZERO) <= 0) throw orderStateInvalid(order.status, 'already_paid', 'Заказ уже оплачен.');
    return due;
  }

  private assertReceivedAmount(input: MoneyInput | undefined, due: Money): Money | null {
    if (!input) return null;
    const received = Money.fromApi(input.amount);
    if (received.compare(due) < 0) {
      throw validation(
        'receivedAmount',
        'received_less_than_due',
        `Получено меньше суммы к оплате (${due.toString()}).`,
        422,
      );
    }
    return received;
  }

  // --------------------------------------------------------------------------------- GET /orders/{id}/payments

  async listForOrder(caller: PaymentsCaller, orderId: string): Promise<{ items: PaymentDto[] }> {
    const order = await this.lookups.order(this.db, orderId);
    if (!order || !(await this.ownsOrder(this.db, caller, order))) throw NOT_FOUND_ORDER();
    const list = await this.repo.listForOrder(this.db, orderId);
    return { items: await this.presentMany(list, caller, []) };
  }

  // --------------------------------------------------------------------------------------- GET /payments/{id}

  async get(
    caller: PaymentsCaller,
    paymentId: string,
    opts: { readonly waitSeconds?: number; readonly refreshStatus?: boolean; readonly signal: AbortSignal },
  ): Promise<PaymentDto & { allowedActions: AllowedAction[] }> {
    let p = await this.visiblePayment(caller, paymentId);
    const warnings: WarningDto[] = [];
    if (opts.refreshStatus && (p.status === 'qr_shown' || p.status === 'qr_expired') && isProviderQr(p)) {
      const ok = await this.qrStatus.refresh(p.id);
      if (!ok) warnings.push({ code: 'STALE_DATA', message: '1С недоступна: показан последний известный статус.' });
      p = (await this.repo.findById(this.db, p.id)) ?? p;
    }
    if (opts.waitSeconds !== undefined && caller.userId) {
      const release = this.waiter.acquire(p.id, caller.userId, opts.waitSeconds);
      // `null` — предел одновременных ожиданий исчерпан: ответ сразу текущим статусом (ревью F-security-4).
      if (release) {
        try {
          const deadline = new Date(this.clock.now().getTime() + opts.waitSeconds * 1000);
          await this.waiter.waitForChange(p.id, p.status, deadline, opts.signal, async () => {
            const cur = await this.repo.findById(this.db, paymentId);
            return cur?.status ?? null;
          });
        } finally {
          release();
        }
        p = (await this.repo.findById(this.db, p.id)) ?? p;
      }
    }
    const [dto] = await this.presentMany([p], caller, warnings);
    return { ...dto, allowedActions: allowedActions(p, caller.perms, caller.isCustomer) };
  }

  /**
   * `payment.read.all` — любой; `payment.read.own` — платёж своего заказа (`ownsOrder`) или созданный собой; иначе 404.
   */
  private async visiblePayment(caller: PaymentsCaller, paymentId: string): Promise<PaymentRow> {
    const p = await this.repo.findById(this.db, paymentId);
    if (!p) throw NOT_FOUND_PAYMENT();
    if (seesAllPayments(caller)) return p;
    if (p.createdByUserId === caller.userId) return p;
    if (p.orderId) {
      const order = await this.lookups.order(this.db, p.orderId);
      if (order && (await this.ownsOrder(this.db, caller, order))) return p;
    }
    throw NOT_FOUND_PAYMENT();
  }

  /**
   * «Свой» заказ (11 §4.4 `own`, SEC-030): `order.read.all` — любой; иначе созданный субъектом; покупателю с
   * подтверждённой привязкой — также заказы его карточки (10 CUST-025; QR и перевыпуск — CUST-024; RM-G-014).
   */
  private async ownsOrder(
    tx: DbExecutor,
    caller: PaymentsCaller,
    order: { readonly customerId: string; readonly createdByUserId: string },
  ): Promise<boolean> {
    if (seesAllOrders(caller) || order.createdByUserId === caller.userId) return true;
    if (!caller.isCustomer || caller.userId === null) return false;
    return (await this.lookups.confirmedCustomerId(tx, caller.userId)) === order.customerId;
  }

  // ------------------------------------------------------------------------- POST /payments/{id}/confirm-manual

  async confirmManual(
    caller: PaymentsCaller,
    paymentId: string,
    body: PaymentsConfirmManualRequest,
    stepUp: PaymentsStepUp,
    req: object,
  ): Promise<PaymentDto> {
    const bankAmount = Money.fromApi(body.receivedAmount.amount);
    if (bankAmount.compare(Money.ZERO) <= 0) {
      throw validation('receivedAmount', 'positive', 'Сумма по выписке должна быть больше нуля.');
    }
    const receivedAt = body.receivedAt ? new Date(body.receivedAt) : this.clock.now();
    const reason =
      body.comment && body.comment.trim().length >= 5 ? body.comment.trim() : `Выписка: ${body.bankReference}`;
    try {
      const out = await this.db.transaction(async (tx) => {
        await applyAuditGucs(tx, caller.audit);
        const pre = await this.repo.findById(tx, paymentId);
        if (!pre) throw NOT_FOUND_PAYMENT();
        const order = pre.orderId ? await this.orders.lockForPayment(tx, pre.orderId) : null;
        const p = await this.repo.findById(tx, paymentId, true);
        if (!p) throw NOT_FOUND_PAYMENT();
        if (p.method !== 'qr_bakai') {
          throw paymentStateInvalid(p.status, 'transition_not_allowed', 'Ручное подтверждение — только для QR-оплаты.');
        }
        const plan = planConfirmManual(p.status);
        const now = this.clock.now();
        const equal = bankAmount.equals(Money.of(p.amount));
        let cur = p;
        let warnings: WarningDto[] = [];
        if (!equal) {
          // 08 §4.9.3: иная сумма — 200, платёж в manual_confirm (amount_mismatch), заказ не закрывается.
          cur =
            p.status === 'qr_shown'
              ? await this.writer.move(tx, p, 'manual_confirm', 'user_step_up', {
                  reviewReason: 'amount_mismatch',
                  bankAmount: bankAmount.toString(),
                  bankReference: body.bankReference,
                  manualConfirmedByUserId: caller.userId,
                  manualConfirmedAt: now,
                  manualReason: body.comment ?? null,
                })
              : await this.writer.move(tx, p, null, 'user_step_up', {
                  reviewReason: 'amount_mismatch',
                  bankAmount: bankAmount.toString(),
                  bankReference: body.bankReference,
                  manualReason: body.comment ?? null,
                });
          warnings = [
            {
              code: 'PAYMENT_AMOUNT_MISMATCH',
              message: `Сумма по выписке ${bankAmount.toString()} не равна сумме платежа ${Money.of(p.amount).toString()}.`,
            },
          ];
          await this.audit.write(
            caller.audit,
            {
              action: 'payment.manual_qr_confirmed',
              entityType: 'payment',
              entityId: p.id,
              before: { status: p.status },
              after: {
                status: cur.status,
                outcome: 'amount_mismatch',
                bankAmount: bankAmount.toString(),
                amount: Money.of(p.amount).toString(),
                bankReference: body.bankReference,
              },
              stepUpMethod: stepUp.method,
              reason,
            },
            tx,
          );
        } else {
          if (!order) throw NOT_FOUND_PAYMENT();
          for (const step of plan.steps) {
            if (step.to === 'manual_confirm') {
              cur = await this.writer.move(tx, cur, 'manual_confirm', 'user_step_up', {
                reviewReason: plan.reviewReason,
                manualConfirmedByUserId: caller.userId,
                manualConfirmedAt: now,
                bankReference: body.bankReference,
                bankAmount: bankAmount.toString(),
              });
            }
          }
          const res = await this.writer.receive(tx, {
            payment: cur,
            order,
            actorKind: 'user_step_up',
            salesActor: toSalesActor(caller),
            patch: {
              receivedByUserId: caller.userId,
              receivedAt,
              bankAmount: bankAmount.toString(),
              bankReference: body.bankReference,
              manualConfirmedByUserId: caller.userId,
              manualConfirmedAt: now,
              manualReason: body.comment ?? null,
            },
            journal: 'manual_qr_confirm',
            journalDetails: {
              confirmationKind: 'manual',
              bankReference: body.bankReference,
              reviewReason: cur.reviewReason,
            },
            audit: {
              ctx: caller.audit,
              action: 'payment.manual_qr_confirmed',
              stepUpMethod: stepUp.method,
              reason,
              after: {
                confirmationKind: 'manual',
                bankReference: body.bankReference,
                reviewReason: cur.reviewReason,
                deviceId: caller.deviceId,
              },
            },
          });
          cur = res.payment;
        }
        const [dto] = await this.presentMany([cur], caller, warnings, tx);
        await this.idempotency.recordInTransaction(idempotencyExecutor(tx), req, 200, dto, cur.id);
        return dto;
      });
      return out;
    } catch (e) {
      throw domainToProblem(e);
    }
  }

  // ---------------------------------------------------------------------------------- POST /payments/{id}/void

  async voidByUser(
    caller: PaymentsCaller,
    paymentId: string,
    body: PaymentsVoidRequest,
    stepUp: PaymentsStepUp,
    req: object,
  ): Promise<PaymentDto> {
    let voided: PaymentRow;
    let dto: PaymentDto;
    try {
      ({ voided, dto } = await this.db.transaction(async (tx) => {
        await applyAuditGucs(tx, caller.audit);
        const pre = await this.repo.findById(tx, paymentId);
        if (!pre) throw NOT_FOUND_PAYMENT();
        const order = pre.orderId ? await this.lookups.order(tx, pre.orderId) : null;
        if (pre.orderId) await this.orders.lockForPayment(tx, pre.orderId);
        const p = await this.repo.findById(tx, paymentId, true);
        if (!p) throw NOT_FOUND_PAYMENT();
        if (!PAYMENT_USER_VOIDABLE.has(p.status)) {
          throw paymentStateInvalid(
            p.status,
            p.status === 'received'
              ? 'received_void_forbidden'
              : p.status === 'credit'
                ? 'credit_terminal'
                : 'not_voidable',
            p.status === 'received'
              ? 'Полученный платёж аннулировать нельзя: оформите исправление или возврат в 1С.'
              : 'Платёж в этом статусе аннулировать нельзя.',
          );
        }
        const now = this.clock.now();
        const v = await this.writer.move(tx, p, 'voided', 'user_step_up', {
          voidedByUserId: caller.userId,
          voidedAt: now,
          voidReason: body.reasonCode,
        });
        await this.journal.write(tx, {
          kind: 'payment_voided',
          payment: v,
          orderPublicNumber: order?.publicNumber ?? null,
          actorUserId: caller.userId,
          occurredAt: now,
          details: { voidReason: body.reasonCode, fromStatus: p.status },
        });
        await this.audit.write(
          caller.audit,
          {
            action: 'payment.voided',
            entityType: 'payment',
            entityId: p.id,
            before: { status: p.status },
            after: { status: 'voided', voidReason: body.reasonCode, qrReference: p.qrProviderRef },
            stepUpMethod: stepUp.method,
            reason: `${body.reasonCode}: ${body.reason}`,
          },
          tx,
        );
        const [d] = await this.presentMany([v], caller, [], tx);
        await this.idempotency.recordInTransaction(idempotencyExecutor(tx), req, 200, d, v.id);
        return { voided: v, dto: d };
      }));
    } catch (e) {
      throw domainToProblem(e);
    }
    if (isProviderQr(voided)) this.qrStatus.cancelInBackground(voided.id, 'voided');
    return dto;
  }

  // ------------------------------------------------------------------------------------------------- общее

  private async orderResult(
    p: PaymentRow,
    caller: PaymentsCaller,
    paidAmount: string,
    isPaid: boolean,
    warnings: readonly WarningDto[],
  ): Promise<OrderPaymentResultDto> {
    const [dto] = await this.presentMany([p], caller, warnings);
    return { ...dto, order: { paidAmount: money(paidAmount), isPaid } };
  }

  private async presentMany(
    list: readonly PaymentRow[],
    caller: PaymentsCaller,
    warnings: readonly WarningDto[],
    tx: DbExecutor = this.db,
  ): Promise<PaymentDto[]> {
    const users = await this.lookups.userRefs(tx, list.flatMap(referencedUsers));
    const staticPayload = list.some((p) => p.method === 'qr_bakai') ? await this.providers.staticPayload() : null;
    const transactionIds =
      caller.perms.has('transactions.read.all') || caller.perms.has('transactions.read.own')
        ? await this.lookups.transactionIds(
            tx,
            list.map((p) => p.id),
          )
        : undefined;
    return list.map((p) =>
      presentPayment(p, {
        showQr: caller.perms.has('payment.qr.show'),
        customerMode: caller.isCustomer,
        showExternalRef: seesAllPayments(caller),
        staticPayload,
        users,
        warnings,
        ...(transactionIds ? { transactionIds } : {}),
      }),
    );
  }

  /** Итог с QR, выданным после COMMIT: повтор с тем же ключом возвращает текущее представление (B-AR-04). */
  private async updateStoredResult(req: object, status: number, body: unknown, resourceId: string): Promise<void> {
    const state = getIdempotencyState(req);
    if (!state) return;
    try {
      await this.idempotency.complete(state.scope, status, body, resourceId);
    } catch (err) {
      this.logger.warn({ err }, 'payments.idempotency.update_failed');
    }
  }
}
