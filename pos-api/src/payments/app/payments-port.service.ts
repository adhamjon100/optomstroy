import { Inject, Injectable } from '@nestjs/common';
import { type AuditContext, toRbacRole } from '../../common/audit/audit-context.js';
import { DRIZZLE, type Database } from '../../common/db/database.module.js';
import { Money } from '../../common/money/money.js';
import type {
  InitialPaymentInput,
  PaymentsPort,
  PaymentSummary,
  QrAfterCommitResult,
  SalesActor,
  SalesTx,
} from '../../common/ports/index.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { PermissionCatalog } from '../../common/rbac/permission-catalog.js';
import {
  assertPaymentTransition,
  initialPaymentStatus,
  PAYMENT_VOID_ON_ORDER_CANCEL,
} from '../../sales-domain/payment/payment-status.js';
import { PaymentsLookups } from '../infra/payments-lookups.js';
import { type PaymentRow, PaymentsRepository } from '../infra/payments.repository.js';
import { PaymentsJobsBridge } from '../jobs/payments-jobs.bridge.js';
import { QrIssuer } from '../qr/qr-issuer.service.js';
import { QrProviders } from '../qr/qr-providers.js';
import { isProviderQr, toOrderSummary, toSummary } from './payment-presenter.js';
import { PaymentStateWriter } from './payment-state.writer.js';

/** Контекст аудита для вызова через порт (`SalesActor` без HTTP-запроса). */
export function auditContextOf(actor: SalesActor): AuditContext {
  return {
    actorUserId: actor.userId,
    actorRole: toRbacRole(actor.roles[0]),
    sessionId: actor.sessionId ?? null,
    deviceId: actor.deviceId ?? null,
    requestId: actor.requestId ?? null,
    ...(actor.userId === null ? { system: 'payments' } : {}),
  };
}

/**
 * Реализация `PaymentsPort` (06 §7.4: `InitialPaymentPort` + `OrderPaymentsReadPort`) для модуля `orders`:
 * - `createInitial` — начальный платёж в транзакции `POST /orders` (ядро §22.3): `initiated → cash_pending |
 *   qr_pending | credit` (07 §6.4), `qr_provider` фиксируется из `QR_PROVIDER`; для `credit` повторно
 *   проверяется шаг 1 PAY-031 по данным БД (роль, идентифицированный клиент, `credit_allowed`) — шаги 2–3 (снимок
 *   долга, override) решает `CreditDecisionService` у вызывающего до создания заказа;
 * - `afterCommit` — QR после COMMIT (08 API-183; при `payment.qr.show`), отказ 1С → `warnings[QR_UNAVAILABLE]`;
 * - `voidOpenForOrderCancel` — системное аннулирование неполученных платежей (PAY-050), отмена QR в 1С —
 *   задачей после COMMIT.
 */
@Injectable()
export class PaymentsPortService implements PaymentsPort {
  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    private readonly repo: PaymentsRepository,
    private readonly lookups: PaymentsLookups,
    private readonly writer: PaymentStateWriter,
    private readonly qrIssuer: QrIssuer,
    private readonly providers: QrProviders,
    private readonly jobs: PaymentsJobsBridge,
    private readonly catalog: PermissionCatalog,
  ) {}

  async createInitial(tx: SalesTx, input: InitialPaymentInput): Promise<PaymentSummary> {
    const existing = input.actor.userId
      ? await this.repo.findByIdempotencyKey(tx, input.idempotencyKey, input.actor.userId)
      : null;
    if (existing) return this.orderSummary(existing);
    const amount = Money.of(input.amount);
    if (amount.compare(Money.ZERO) <= 0) {
      throw new ProblemException('VALIDATION_FAILED', {
        status: 422,
        detail: 'Сумма платежа должна быть больше нуля.',
        errors: [{ field: 'amount', rule: 'positive', message: 'Сумма платежа должна быть больше нуля.' }],
      });
    }
    if (!input.actor.userId) throw new Error('PaymentsPort.createInitial: нужен пользователь-инициатор');
    if (input.method === 'credit') await this.assertCreditStepOne(tx, input);
    const status = initialPaymentStatus(input.method);
    assertPaymentTransition('initiated', status, 'system');
    const created = await this.repo.insert(tx, {
      orderId: input.orderId,
      customerId: input.customerId,
      method: input.method,
      qrProvider: input.method === 'qr_bakai' ? this.providers.mode : null,
      status,
      amount: amount.toString(),
      createdByUserId: input.actor.userId,
      idempotencyKey: input.idempotencyKey,
      requestId: input.actor.requestId ?? null,
    });
    return toSummary(created);
  }

  async afterCommit(paymentId: string, actor: SalesActor): Promise<QrAfterCommitResult> {
    const p = await this.repo.findById(this.db, paymentId);
    if (!p) throw new ProblemException('NOT_FOUND', { detail: 'Платёж не найден.' });
    const canShow = this.catalog.effectivePermissions({ roles: actor.roles }).has('payment.qr.show');
    if (p.method !== 'qr_bakai' || p.status !== 'qr_pending' || !canShow)
      return { payment: await this.orderSummary(p), warnings: [] };
    const r = await this.qrIssuer.issue({
      paymentId,
      manualOnly: false,
      actorUserId: actor.userId,
      audit: auditContextOf(actor),
    });
    return {
      payment: await this.orderSummary(r.payment ?? p),
      warnings: r.warnings
        .filter((w) => w.code === 'QR_UNAVAILABLE')
        .map((w) => ({ code: 'QR_UNAVAILABLE' as const, message: w.message })),
    };
  }

  async listForOrder(orderId: string, tx?: SalesTx | null): Promise<readonly PaymentSummary[]> {
    const list = await this.repo.listForOrder(tx ?? this.db, orderId);
    const staticPayload = list.some((p) => p.method === 'qr_bakai') ? await this.providers.staticPayload() : null;
    return list.map((p) => toOrderSummary(p, staticPayload));
  }

  /** Сводка платежа для `Order.payments[]` с `qr`/`receivedAmount`/`changeAmount` (FQ-ORD-04). */
  private async orderSummary(p: PaymentRow): Promise<PaymentSummary> {
    return toOrderSummary(p, p.method === 'qr_bakai' ? await this.providers.staticPayload() : null);
  }

  receivedTotal(tx: SalesTx | null, orderId: string): Promise<string> {
    return this.repo.receivedTotal(tx ?? this.db, orderId);
  }

  async voidOpenForOrderCancel(
    tx: SalesTx,
    input: { readonly orderId: string; readonly actor: SalesActor },
  ): Promise<readonly string[]> {
    const order = await this.lookups.order(tx, input.orderId);
    const ids: string[] = [];
    for (const p of await this.repo.listForOrder(tx, input.orderId)) {
      if (!PAYMENT_VOID_ON_ORDER_CANCEL.has(p.status)) continue;
      const locked = await this.repo.findById(tx, p.id, true);
      if (!locked || !PAYMENT_VOID_ON_ORDER_CANCEL.has(locked.status)) continue;
      const voided = await this.writer.systemVoid(tx, locked, 'order_cancelled', {
        orderPublicNumber: order?.publicNumber ?? null,
        initiatedBy: input.actor.userId,
        requestId: input.actor.requestId ?? null,
      });
      if (isProviderQr(voided)) await this.jobs.enqueuePollInTx(tx, voided.id);
      ids.push(voided.id);
    }
    return ids;
  }

  /** Шаг 1 PAY-031 (ядро §22.4, §23 п. 5) — защита от создания `credit` в обход решения. */
  private async assertCreditStepOne(tx: SalesTx, input: InitialPaymentInput): Promise<void> {
    const perms = this.catalog.effectivePermissions({ roles: input.actor.roles });
    if (input.actor.isCustomer || !perms.has('credit.sale.create')) {
      throw new ProblemException('FORBIDDEN', {
        detail: 'Продажа в долг недоступна для вашей роли.',
        creditReason: 'forbidden_role',
      });
    }
    const c = await this.lookups.creditCustomer(tx, input.customerId);
    if (!c.exists || c.isRetailDefault || !c.hasOnecRef) {
      throw new ProblemException('CUSTOMER_NOT_IDENTIFIED', { detail: 'Для продажи в долг выберите клиента из 1С.' });
    }
    if (!c.creditAllowed) {
      throw new ProblemException('CREDIT_BLOCKED', {
        detail: 'Соглашение клиента не допускает отсрочку.',
        creditReason: 'credit_not_allowed',
      });
    }
  }
}
