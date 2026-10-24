import { Inject, Injectable } from '@nestjs/common';
import { type AuditContext, systemActor } from '../../common/audit/audit-context.js';
import { AuditService, type AuditStepUpMethod } from '../../common/audit/audit.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import type { PaymentStatus } from '../../common/enums.js';
import { Money } from '../../common/money/money.js';
import {
  ORDER_STATUS_PORT,
  type OrderPaymentView,
  type OrderStatusPort,
  type SalesActor,
} from '../../common/ports/index.js';
import {
  assertPaymentTransition,
  type PaymentActor,
  paymentStateInvalid,
} from '../../sales-domain/payment/payment-status.js';
import { PaymentJournal, type PaymentJournalKind } from '../infra/payment-journal.js';
import { type PaymentPatch, type PaymentRow, PaymentsRepository } from '../infra/payments.repository.js';

export interface ReceiveInput {
  readonly payment: PaymentRow;
  readonly order: OrderPaymentView;
  readonly actorKind: Extract<PaymentActor, 'user' | 'provider' | 'user_step_up'>;
  readonly salesActor: SalesActor;
  readonly patch: PaymentPatch;
  readonly journal: PaymentJournalKind;
  readonly journalDetails?: Readonly<Record<string, unknown>>;
  readonly audit: {
    readonly ctx: AuditContext;
    readonly action: 'payment.received' | 'payment.manual_qr_confirmed';
    readonly stepUpMethod?: AuditStepUpMethod | null;
    readonly reason?: string | null;
    readonly after?: Readonly<Record<string, unknown>>;
  };
}

/**
 * Переходы автомата `payment_status` с побочными записями (07 §6.4, правило 3): условный UPDATE строки платежа,
 * при `received` — `OrderStatusPort.applyReceived` (paid_amount, paid_at, проекция D-20), строка `transactions` и
 * `audit_logs` в той же транзакции (10 PAY-006; 11 SEC-073). Допустимость перехода — только доменная таблица
 * `PAYMENT_TRANSITIONS` (sales-domain/payment).
 */
@Injectable()
export class PaymentStateWriter {
  constructor(
    private readonly repo: PaymentsRepository,
    private readonly journal: PaymentJournal,
    private readonly audit: AuditService,
    @Inject(ORDER_STATUS_PORT) private readonly orders: OrderStatusPort,
    @Inject(CLOCK) private readonly clock: Clock,
  ) {}

  /** Переход `p.status → to` (или только поля при `to = null`); гонка → `409 PAYMENT_STATE_INVALID`. */
  async move(
    tx: DbExecutor,
    p: PaymentRow,
    to: PaymentStatus | null,
    actor: PaymentActor,
    patch: PaymentPatch = {},
  ): Promise<PaymentRow> {
    if (to !== null) assertPaymentTransition(p.status, to, actor);
    const r = await this.repo.transition(tx, p.id, p.status, to, patch);
    if (r) return r;
    const cur = await this.repo.findById(tx, p.id);
    throw paymentStateInvalid(
      cur?.status ?? p.status,
      'concurrent_change',
      'Статус платежа изменился, обновите данные.',
    );
  }

  /**
   * Системное аннулирование (без step-up, актор — система): смена способа оплаты до получения денег
   * (`method_changed`, ядро §23 п. 3; 10 PAY-052) или отмена заказа (`order_cancelled`, PAY-050).
   */
  async systemVoid(
    tx: DbExecutor,
    p: PaymentRow,
    reason: 'method_changed' | 'order_cancelled',
    ctx: {
      readonly orderPublicNumber: string | null;
      readonly initiatedBy: string | null;
      readonly requestId?: string | null;
    },
  ): Promise<PaymentRow> {
    const now = this.clock.now();
    const voided = await this.move(tx, p, 'voided', 'system', {
      voidedByUserId: null,
      voidedAt: now,
      voidReason: reason,
    });
    await this.journal.write(tx, {
      kind: 'payment_voided',
      payment: voided,
      orderPublicNumber: ctx.orderPublicNumber,
      actorUserId: null,
      occurredAt: now,
      details: { voidReason: reason, fromStatus: p.status },
    });
    await this.audit.write(
      systemActor('payments', ctx.requestId ?? undefined),
      {
        action: 'payment.voided',
        entityType: 'payment',
        entityId: p.id,
        before: { status: p.status },
        after: {
          status: 'voided',
          voidReason: reason,
          actor: 'system',
          initiatedByUserId: ctx.initiatedBy,
          qrReference: p.qrProviderRef,
        },
        reason,
      },
      tx,
    );
    return voided;
  }

  /** Деньги получены: платёж → `received`, заказ — `applyReceived`, журнал и аудит (07 §6.4 правило 3). */
  async receive(
    tx: DbExecutor,
    i: ReceiveInput,
  ): Promise<{ payment: PaymentRow; paidAmount: string; isPaid: boolean }> {
    const received = await this.move(tx, i.payment, 'received', i.actorKind, i.patch);
    await this.orders.applyReceived(tx, {
      orderId: i.order.orderId,
      amount: Money.of(received.amount).toString(),
      paymentId: received.id,
      actor: i.salesActor,
    });
    const occurredAt = received.receivedAt ?? this.clock.now();
    await this.journal.write(tx, {
      kind: i.journal,
      payment: received,
      orderPublicNumber: i.order.publicNumber,
      actorUserId: i.salesActor.userId,
      occurredAt,
      ...(i.journalDetails ? { details: i.journalDetails } : {}),
    });
    await this.audit.write(
      i.audit.ctx,
      {
        action: i.audit.action,
        entityType: 'payment',
        entityId: received.id,
        before: { status: i.payment.status },
        after: {
          status: 'received',
          orderId: i.order.orderId,
          amount: Money.of(received.amount).toString(),
          method: received.method,
          ...i.audit.after,
        },
        stepUpMethod: i.audit.stepUpMethod ?? null,
        reason: i.audit.reason ?? null,
      },
      tx,
    );
    const paid = Money.of(i.order.paidAmount).plus(Money.of(received.amount));
    const total = Money.of(i.order.total);
    return {
      payment: received,
      paidAmount: paid.toString(),
      isPaid: paid.compare(total) >= 0 && total.compare(Money.ZERO) > 0,
    };
  }
}
