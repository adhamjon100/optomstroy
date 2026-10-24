import { Inject, Injectable, Logger } from '@nestjs/common';
import { type AuditContext, applyAuditGucs } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { DRIZZLE, type Database } from '../../common/db/database.module.js';
import { Money } from '../../common/money/money.js';
import type { QrIssued } from '../../integrations/payments/payment-provider.js';
import type { PaymentActor } from '../../sales-domain/payment/payment-status.js';
import type { WarningDto } from '../app/payment-presenter.js';
import { PaymentStateWriter } from '../app/payment-state.writer.js';
import { PaymentsLookups } from '../infra/payments-lookups.js';
import { type PaymentRow, PaymentsRepository } from '../infra/payments.repository.js';
import { PaymentsJobsBridge } from '../jobs/payments-jobs.bridge.js';
import { QrProviders } from './qr-providers.js';
import { QrStatusService } from './qr-status.service.js';
import { withTimeout } from './with-timeout.js';

export const QR_UNAVAILABLE_WARNING: WarningDto = {
  code: 'QR_UNAVAILABLE',
  message: 'QR не сформирован: 1С недоступна или отказала. Повторите или подтвердите оплату вручную.',
};

export interface QrIssueCommand {
  readonly paymentId: string;
  /** `manualOnly: true` — статический QR и ручное подтверждение (запасной путь, 08 API-185). */
  readonly manualOnly: boolean;
  readonly actorUserId: string | null;
  readonly audit: AuditContext;
}

export interface QrIssueResult {
  readonly payment: PaymentRow | null;
  readonly warnings: readonly WarningDto[];
}

const ISSUABLE = new Set(['qr_pending', 'qr_shown', 'qr_expired']);

/**
 * Выдача и перевыпуск QR (RM-F-003, RM-F-016; 08 §4.8.1, §4.8.6, API-183, API-185; 10 PAY-021…PAY-025, PAY-053):
 * запрос к провайдеру — **после COMMIT, вне транзакции** (08 API-183), с таймаутом `ONEC_SYNC_CHECK_TIMEOUT_MS`;
 * затем короткая транзакция записывает QR на **тот же** `payment_id` (`qr_pending|qr_expired → qr_shown`, у
 * показанного — новые payload/референс/срок). Отказ или недоступность 1С — не HTTP-ошибка: платёж остаётся в
 * прежнем состоянии (`qr_pending` без QR / прежний QR) + `warnings[QR_UNAVAILABLE]`.
 */
@Injectable()
export class QrIssuer {
  private readonly logger = new Logger('payments.qr');

  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly repo: PaymentsRepository,
    private readonly lookups: PaymentsLookups,
    private readonly providers: QrProviders,
    private readonly writer: PaymentStateWriter,
    private readonly audit: AuditService,
    private readonly jobs: PaymentsJobsBridge,
    private readonly qrStatus: QrStatusService,
  ) {}

  async issue(cmd: QrIssueCommand): Promise<QrIssueResult> {
    const p = await this.repo.findById(this.db, cmd.paymentId);
    if (!p || p.method !== 'qr_bakai' || !ISSUABLE.has(p.status)) return { payment: p, warnings: [] };
    const dynamic = cmd.manualOnly ? null : this.providers.dynamic;
    const manual = dynamic === null;
    // `QrCreateRequest.orderExternalId` обязателен (контракт 1С v1, ТЗ для 1С §6.14): динамический QR без заказа
    // не выпускается — явный отказ `QR_UNAVAILABLE` (ручной путь остаётся) до решения Q-152 (оплата долга без заказа).
    if (!manual && p.orderId === null) {
      this.logger.warn({ paymentId: p.id }, 'payments.qr.issue_refused: платёж без заказа — QR_UNAVAILABLE (Q-152)');
      return { payment: p, warnings: [QR_UNAVAILABLE_WARNING] };
    }
    const order = p.orderId ? await this.lookups.order(this.db, p.orderId) : null;
    // Перевыпуск при QR через 1С (10 PAY-025, 05 SYNC-078 «… или перевыпуске QR backend вызывает /qr/cancel»; ревью
    // F-orders-1c-5): прежний QR отменяется в 1С до запроса нового (тот же externalId); ошибка отмены не мешает
    // перевыпуску — прежний референс инвалидируется в backend (история референсов). Ответ «уже оплачен» — оплата
    // применяется к платежу как обычный отчёт 1С, новый QR не выдаётся.
    if (this.providers.dynamic && p.qrProvider === 'onec' && p.qrProviderRef && p.status !== 'qr_pending') {
      const paid = await this.cancelPreviousQr(p);
      if (paid) return { payment: (await this.repo.findById(this.db, p.id)) ?? p, warnings: [] };
    }
    let issued: QrIssued;
    try {
      const req = {
        paymentId: p.id,
        // Без заказа — только статический QR (запрос в 1С не уходит, см. отказ выше).
        orderExternalId: p.orderId ?? '',
        orderRef: order?.onecRef ?? null,
        customerRef: order?.customerOnecRef ?? null,
        amount: Money.of(p.amount).toString(),
        currency: 'KGS' as const,
        purpose: order ? `Оплата заказа ${order.publicNumber}` : `Оплата ${p.publicNumber}`,
        ttlSeconds: this.config.QR_TTL_MINUTES * 60,
        cashierUserCode: cmd.actorUserId ?? 'system',
      };
      issued =
        dynamic === null
          ? await this.providers.manual.issue(req)
          : await withTimeout(this.config.ONEC_SYNC_CHECK_TIMEOUT_MS, (signal) => dynamic.issue(req, { signal }));
    } catch (err) {
      this.logger.warn({ err, paymentId: p.id }, 'payments.qr.issue_failed: QR_UNAVAILABLE');
      return { payment: p, warnings: [QR_UNAVAILABLE_WARNING] };
    }
    const now = this.clock.now();
    const expiresAt = manual ? null : this.expiry(issued, now);
    const outcome = await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, cmd.audit);
      const cur = await this.repo.findById(tx, p.id, true);
      if (!cur || cur.method !== 'qr_bakai' || !ISSUABLE.has(cur.status)) return { payment: cur, applied: false };
      const reissue = cur.status !== 'qr_pending';
      const to = cur.status === 'qr_shown' ? null : 'qr_shown';
      const actor: PaymentActor = cur.status === 'qr_expired' ? 'user' : 'system';
      if (cur.qrProviderRef && cur.qrProviderRef !== (manual ? null : issued.providerRef)) {
        await this.repo.rememberQrRef(tx, cur.id, cur.qrProviderRef);
      }
      const moved = await this.writer.move(tx, cur, to, actor, {
        qrPayload: manual ? null : (issued.payload ?? null),
        qrProviderRef: manual ? null : issued.providerRef,
        qrExpiresAt: expiresAt,
        qrIssuedAt: now,
        qrStatusCheckedAt: manual ? null : now,
        qrProviderStatusRaw: (issued.providerStatusRaw ?? (manual ? 'manual' : null))?.slice(0, 100) ?? null,
      });
      if (reissue) {
        await this.audit.write(
          cmd.audit,
          {
            action: 'payment.qr_reissued',
            entityType: 'payment',
            entityId: cur.id,
            before: { status: cur.status, qrReference: cur.qrProviderRef, qrExpiresAt: cur.qrExpiresAt?.toISOString() },
            after: {
              status: moved.status,
              qrReference: moved.qrProviderRef,
              qrExpiresAt: moved.qrExpiresAt?.toISOString() ?? null,
              provider: manual ? 'manual' : 'onec',
            },
          },
          tx,
        );
      }
      return { payment: moved, applied: true };
    });
    if (!outcome.applied) {
      // Платёж успел выйти из состояния выдачи (оплачен/аннулирован): выданный динамический QR отменяется в 1С.
      if (!manual && outcome.payment?.status === 'voided') this.qrStatus.cancelInBackground(p.id, 'voided');
      return { payment: outcome.payment, warnings: [] };
    }
    if (!manual) await this.jobs.kickPoll(p.id);
    return { payment: outcome.payment, warnings: [] };
  }

  /** `true` — прежний QR уже оплачен (оплата применена к платежу), перевыпуск не нужен. */
  private async cancelPreviousQr(p: PaymentRow): Promise<boolean> {
    const provider = this.providers.dynamic;
    if (!provider) return false;
    try {
      const r = await withTimeout(this.config.ONEC_SYNC_CHECK_TIMEOUT_MS, (signal) =>
        provider.cancel(p.id, 'reissue', { signal }),
      );
      if (r.state !== 'paid') return false;
      await this.qrStatus.applyPaidReport(p.id, {
        reference: p.qrProviderRef,
        paidAmount: r.paidAmount,
        paidAt: r.paidAt,
        bankReference: r.bankReference,
      });
      return true;
    } catch (err) {
      this.logger.warn({ err, paymentId: p.id }, 'payments.qr.reissue_cancel_failed');
      return false;
    }
  }

  /** Срок QR: из ответа 1С, если он в будущем; иначе момент выдачи + `QR_TTL_MINUTES` (07 §5.40, 10 PAY-021). */
  private expiry(issued: QrIssued, now: Date): Date {
    const fromProvider = issued.expiresAt ? new Date(issued.expiresAt) : null;
    if (fromProvider && !Number.isNaN(fromProvider.getTime()) && fromProvider > now) return fromProvider;
    return new Date(now.getTime() + this.config.QR_TTL_MINUTES * 60_000);
  }
}
