import { Inject, Injectable, Logger } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { applyAuditGucs, systemActor } from '../../common/audit/audit-context.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { DRIZZLE, type Database } from '../../common/db/database.module.js';
import { isUuid } from '../../common/ids/uuid.js';
import { Money } from '../../common/money/money.js';
import { ORDER_STATUS_PORT, type OrderStatusPort, SYSTEM_ACTOR } from '../../common/ports/index.js';
import type { QrCancelReason, QrStatusResult } from '../../integrations/payments/payment-provider.js';
import type { OnecQrStatusPayload, QrPollOutcome } from '../../jobs/payments/payments-jobs.js';
import { decideProviderReport, type ProviderDecision } from '../../sales-domain/payment/payment-status.js';
import { isProviderQr } from '../app/payment-presenter.js';
import { PaymentStateWriter } from '../app/payment-state.writer.js';
import { PaymentNotifier } from '../infra/payment-notifier.js';
import { type PaymentPatch, type PaymentRow, PaymentsRepository } from '../infra/payments.repository.js';
import { withTimeout } from './with-timeout.js';
import { QrProviders } from './qr-providers.js';

/** Опрос — пока платёж в `qr_shown`, не дольше `expiresAt` + 60 с (06 §7.4; 10 PAY-023; RM-F-016 п. 5). */
export const QR_POLL_GRACE_MS = 60_000;
/** Отмена QR без известного срока (`qr_expires_at` пуст) повторяется не дольше часа после аннулирования. */
const CANCEL_RETRY_FALLBACK_MS = 60 * 60_000;
/**
 * Повторы отмены QR в 1С (05 SYNC-078: «при ошибке вызов повторяется (1, 2, 5 мин) до `expiresAt`»): задержка по
 * времени, прошедшему с аннулирования, — 1 мин, затем 2 мин, далее каждые 5 мин.
 */
export function qrCancelRetryDelaySeconds(elapsedMs: number): number {
  if (elapsedMs < 60_000) return 60;
  if (elapsedMs < 180_000) return 120;
  return 300;
}
/** `qr_provider_status_raw` для аннулированного платежа: итог отмены QR в 1С. */
const CANCEL_DONE = new Set(['cancelled', 'paid', 'cancel_failed']);

const STOP: QrPollOutcome = { continue: false, delaySeconds: 0, status: null };

export interface ProviderReportInput {
  readonly state: QrStatusResult['state'];
  readonly reference: string | null;
  readonly paidAmount: string | null;
  readonly paidAt: string | null;
  readonly bankReference: string | null;
  readonly documentRef: string | null;
  readonly documentType: string | null;
  readonly raw: string | null;
}

/**
 * Статус QR-оплаты от 1С (`QR_PROVIDER=onec`, RM-F-016; ядро §24.4; 07 §6.4 правило 10; 08 §6.1):
 * - опрос `GET /pos/v1/payments/{externalId}/status` (job `payments.qr_onec_poll`, `GET /payments/{id}?refreshStatus`)
 *   и элемент плана обмена (`payments.onec-qr-status`) применяются одинаково и идемпотентно — побеждает первое;
 * - сумма и референс совпали → `qr_shown → received` (`confirmationKind=webhook`); сумма ≠ → `manual_confirm`
 *   (`amount_mismatch`, `bank_amount`); референс не последнего выпуска → `unknown_reference`; оплата после истечения →
 *   `qr_expired → manual_confirm` (`late_payment`, ядро §23 п. 4);
 * - «не оплачено / срок истёк» от 1С статус не меняет до `qr_expires_at`, далее таймер → `qr_expired` (08 §6.1);
 * - у аннулированного QR-платежа QR отменяется в 1С (`POST /pos/v1/payments/{externalId}/qr/cancel`); ответ
 *   «уже оплачено» — уведомление на разбор (10 PAY-052, PAY-029).
 */
@Injectable()
export class QrStatusService {
  private readonly logger = new Logger('payments.qr');

  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    @Inject(CLOCK) private readonly clock: Clock,
    @Inject(ORDER_STATUS_PORT) private readonly orders: OrderStatusPort,
    private readonly repo: PaymentsRepository,
    private readonly writer: PaymentStateWriter,
    private readonly providers: QrProviders,
    private readonly notifier: PaymentNotifier,
  ) {}

  /** Один опрос платежа (job `payments.qr_onec_poll`). `timeoutMs` — таймаут вызова 1С. */
  async pollOnce(paymentId: string, timeoutMs = this.config.ONEC_TIMEOUT_MS): Promise<QrPollOutcome> {
    const p = await this.repo.findById(this.db, paymentId);
    const provider = this.providers.dynamic;
    if (!p || !provider || p.method !== 'qr_bakai' || p.qrProvider !== 'onec' || !isProviderQr(p)) return STOP;
    const now = this.clock.now();
    if (p.status === 'voided') return this.cancelVoided(p, now);
    // Опрос только пока QR показан (RM-F-016 п. 5, PAY-023); позднюю оплату после истечения доставляет план
    // обмена (`payments.onec-qr-status`) или явный `refreshStatus` (ревью F-orders-1c-6).
    if (p.status !== 'qr_shown') return STOP;
    const horizon = (p.qrExpiresAt ?? now).getTime() + QR_POLL_GRACE_MS;
    if (now.getTime() > horizon) {
      if (p.status === 'qr_shown') await this.expire(p.id);
      return STOP;
    }
    let report: QrStatusResult;
    try {
      report = await withTimeout(timeoutMs, (signal) => provider.status(p.id, { signal }));
    } catch (err) {
      this.logger.warn({ err, paymentId: p.id }, 'payments.qr.poll_failed');
      if (p.status === 'qr_shown' && p.qrExpiresAt && now >= p.qrExpiresAt) await this.expire(p.id);
      return this.next(p.id);
    }
    await this.applyReport(p.id, {
      state: report.state,
      reference: report.providerRef,
      paidAmount: report.paidAmount,
      paidAt: report.paidAt,
      bankReference: report.bankReference,
      documentRef: report.documentRef,
      documentType: null,
      raw: report.providerStatusRaw,
    });
    return this.next(p.id);
  }

  /** `GET /payments/{id}?refreshStatus=true` (08 §4.9.2): синхронный опрос; 1С недоступна → `false` (STALE_DATA). */
  async refresh(paymentId: string): Promise<boolean> {
    const p = await this.repo.findById(this.db, paymentId);
    const provider = this.providers.dynamic;
    if (!p || !provider || !isProviderQr(p) || (p.status !== 'qr_shown' && p.status !== 'qr_expired')) return true;
    try {
      const report = await withTimeout(this.config.ONEC_SYNC_CHECK_TIMEOUT_MS, (signal) =>
        provider.status(p.id, { signal }),
      );
      await this.applyReport(p.id, {
        state: report.state,
        reference: report.providerRef,
        paidAmount: report.paidAmount,
        paidAt: report.paidAt,
        bankReference: report.bankReference,
        documentRef: report.documentRef,
        documentType: null,
        raw: report.providerStatusRaw,
      });
      return true;
    } catch (err) {
      this.logger.warn({ err, paymentId }, 'payments.qr.refresh_failed');
      return false;
    }
  }

  /** Элемент плана обмена `QrPaymentStatus` (job `payments.onec-qr-status`). */
  async applyOnecQrStatus(payload: OnecQrStatusPayload): Promise<string> {
    if (!isUuid(payload.externalId)) return 'ignored_bad_external_id';
    const p = await this.repo.findById(this.db, payload.externalId);
    if (!p || p.method !== 'qr_bakai') return 'ignored_unknown_payment';
    return this.applyReport(p.id, {
      state: payload.status,
      reference: payload.reference,
      paidAmount: payload.paidAmount,
      paidAt: payload.paidAt,
      bankReference: payload.bankReference,
      documentRef: payload.documentRef ?? null,
      documentType: payload.documentType ?? null,
      raw: payload.status,
    });
  }

  /** Ответ «уже оплачено» на отмену прежнего QR при перевыпуске (PAY-025): обычный отчёт об оплате. */
  async applyPaidReport(
    paymentId: string,
    r: { reference: string | null; paidAmount: string | null; paidAt: string | null; bankReference: string | null },
  ): Promise<string> {
    return this.applyReport(paymentId, {
      state: 'paid',
      reference: r.reference,
      paidAmount: r.paidAmount,
      paidAt: r.paidAt,
      bankReference: r.bankReference,
      documentRef: null,
      documentType: null,
      raw: 'paid',
    });
  }

  /** `qr_shown` с наступившим `qr_expires_at` → `qr_expired` (job `payments.qr_expire`, таймер 07 §6.4). */
  async expireDue(): Promise<number> {
    const ids = await this.repo.dueForExpiry(this.db, this.clock.now(), 200);
    let n = 0;
    for (const id of ids) if (await this.expire(id)) n += 1;
    return n;
  }

  pollCandidates(): Promise<string[]> {
    return this.providers.dynamic ? this.repo.pollCandidates(this.db, 500) : Promise.resolve([]);
  }

  /**
   * Отмена QR в 1С (после аннулирования платежа: смена способа, ручной void, отмена заказа). Итог — в
   * `qr_provider_status_raw` (`cancelled` | `paid` | `cancel_failed`); недоступность 1С — повтор задачей.
   */
  async cancelAtProvider(paymentId: string, reason: QrCancelReason): Promise<'done' | 'retry'> {
    const p = await this.repo.findById(this.db, paymentId);
    const provider = this.providers.dynamic;
    if (!p || !provider || !isProviderQr(p) || p.status !== 'voided') return 'done';
    if (CANCEL_DONE.has(p.qrProviderStatusRaw ?? '')) return 'done';
    let result: Awaited<ReturnType<typeof provider.cancel>>;
    try {
      result = await withTimeout(this.config.ONEC_SYNC_CHECK_TIMEOUT_MS, (signal) =>
        provider.cancel(p.id, reason, { signal }),
      );
    } catch (err) {
      const retryable = (err as { retryable?: unknown }).retryable !== false;
      this.logger.warn({ err, paymentId, retryable }, 'payments.qr.cancel_failed');
      if (retryable) return 'retry';
      await this.markCancel(p, 'cancel_failed', {});
      return 'done';
    }
    if (result.state === 'paid') {
      // Факт оплаты фиксирует тот путь, который первым записал `qr_provider_status_raw = 'paid'` под блокировкой
      // строки (опрос / план обмена — applyReport, отмена — здесь); второй путь не пишет журнал и уведомления (RC-9).
      const claimed = await this.markCancel(p, 'paid', {
        bankReference: result.bankReference,
        bankAmount: positiveOrNull(result.paidAmount),
      });
      if (!claimed) return 'done';
      await this.reportPaidAfterVoid(p, {
        bankReference: result.bankReference,
        paidAmount: positiveOrNull(result.paidAmount),
        source: 'qr_cancel',
      });
      return 'done';
    }
    await this.markCancel(p, 'cancelled', {});
    return 'done';
  }

  /**
   * Фоновая отмена QR в 1С после аннулирования (PAY-052, SYNC-078: «аннулирование в POS не ждёт ответа 1С»): любые
   * ошибки, в том числе БД, только журналируются — без unhandled rejection (ревью F-orders-1c-8); повтор подберёт
   * опрос (`pollCandidates` включает аннулированные платежи с незавершённой отменой).
   */
  cancelInBackground(paymentId: string, reason: QrCancelReason): void {
    this.cancelAtProvider(paymentId, reason).catch((err: unknown) => {
      this.logger.warn({ err, paymentId, reason }, 'payments.qr.cancel_background_failed');
    });
  }

  // ------------------------------------------------------------------------------------------------- внутреннее

  /**
   * Оплата по аннулированному QR (05 §6.7.3, SYNC-078, AC-SYNC-078; 10 PAY-029, PAY-052; ревью F-orders-1c-4): статус
   * платежа не меняется; запись журнала синхронизации (`sync_errors`, payment_docs) и уведомления кассирам,
   * администраторам, аннулировавшему кассиру и автору заказа. Повторное сообщение — без второй записи и без повторных
   * уведомлений (ревью F, RC-9): вызывает только путь, записавший `qr_provider_status_raw = 'paid'` (markCancel /
   * applyReport под блокировкой строки); запись журнала сериализована advisory-блокировкой платежа (у `sync_errors`
   * нет уникального ключа), уведомления — только если запись журнала сделана этим вызовом (или запись не удалась).
   */
  private async reportPaidAfterVoid(
    p: PaymentRow,
    d: { readonly bankReference: string | null; readonly paidAmount: string | null; readonly source: string },
  ): Promise<void> {
    const message = `QR_PAID_AFTER_VOID: оплата по аннулированному QR платежа ${p.publicNumber} — оформите в 1С возврат или аванс`;
    let logged = true;
    try {
      // Код `QR_PAID_AFTER_VOID` (07 §6.1.1, CHECK — миграция 0013, ADR-103; OpenAPI 1.2.0 `SyncErrorCode`).
      // Одна запись на платёж: проверка по обоим вариантам — новому коду и строкам, записанным до миграции как
      // `OTHER` + `payload.code = 'QR_PAID_AFTER_VOID'` (07 §5.53, FIX-F-06; такие строки остаются).
      logged = await this.db.transaction(async (tx) => {
        await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtextextended(${`qr_paid_after_void:${p.id}`}, 0))`);
        const ins = await tx.execute(sql`
        INSERT INTO sync_errors (entity, local_id, error_code, message, payload, severity)
        SELECT 'payment_docs', ${p.id}::uuid, 'QR_PAID_AFTER_VOID', ${message.slice(0, 2000)},
               ${JSON.stringify({
                 code: 'QR_PAID_AFTER_VOID',
                 paymentId: p.id,
                 orderId: p.orderId,
                 amount: p.amount,
                 paidAmount: d.paidAmount,
                 bankReference: d.bankReference,
                 qrReference: p.qrProviderRef,
                 voidReason: p.voidReason,
                 source: d.source,
               })}::jsonb, 'error'
         WHERE NOT EXISTS (SELECT 1 FROM sync_errors
                            WHERE local_id = ${p.id}::uuid AND entity = 'payment_docs'
                              AND (error_code = 'QR_PAID_AFTER_VOID'
                                   OR (error_code = 'OTHER' AND payload ->> 'code' = 'QR_PAID_AFTER_VOID')))
        RETURNING id`);
        return ins.rows.length > 0;
      });
    } catch (err) {
      // Журнал не записан — уведомления всё равно уходят (вторичный канал не должен потерять факт оплаты).
      this.logger.error({ err, paymentId: p.id }, 'payments.qr.paid_after_void.sync_error_failed');
    }
    if (!logged) return;
    const notice = {
      paymentId: p.id,
      orderId: p.orderId,
      severity: 'error' as const,
      title: 'Оплата по аннулированному QR',
      body: `По платежу ${p.publicNumber} поступила оплата после аннулирования QR — оформите в 1С возврат или аванс.`,
      event: 'voided_paid',
    };
    await this.notifier.notifyRole('cashier', notice);
    await this.notifier.notifyRole('admin', notice);
    for (const userId of new Set([p.voidedByUserId, p.createdByUserId].filter((x): x is string => x !== null))) {
      await this.notifier.notify({ ...notice, userId });
    }
  }

  private async next(paymentId: string): Promise<QrPollOutcome> {
    const p = await this.repo.findById(this.db, paymentId);
    if (!p) return STOP;
    const now = this.clock.now().getTime();
    const horizon = (p.qrExpiresAt?.getTime() ?? now) + QR_POLL_GRACE_MS;
    const cont = p.status === 'qr_shown' && now <= horizon;
    return { continue: cont, delaySeconds: this.config.QR_ONEC_POLL_SECONDS, status: p.status };
  }

  private async cancelVoided(p: PaymentRow, now: Date): Promise<QrPollOutcome> {
    if (CANCEL_DONE.has(p.qrProviderStatusRaw ?? '')) return STOP;
    const reason: QrCancelReason =
      p.voidReason === 'method_changed'
        ? 'method_changed'
        : p.voidReason === 'order_cancelled'
          ? 'order_cancelled'
          : 'voided';
    const r = await this.cancelAtProvider(p.id, reason);
    if (r !== 'retry') return STOP;
    // Повторы — до `expiresAt` QR (после него QR не принимает оплату); без срока — час после аннулирования.
    const voidedAt = p.voidedAt?.getTime() ?? now.getTime();
    const deadline = p.qrExpiresAt?.getTime() ?? voidedAt + CANCEL_RETRY_FALLBACK_MS;
    if (now.getTime() >= deadline) {
      const cur = await this.repo.findById(this.db, p.id);
      if (cur) await this.markCancel(cur, 'cancel_failed', {});
      return STOP;
    }
    return { continue: true, delaySeconds: qrCancelRetryDelaySeconds(now.getTime() - voidedAt), status: 'voided' };
  }

  /**
   * Итог отмены QR в `qr_provider_status_raw` под блокировкой строки платежа. `paid` — факт оплаты: уже записанный
   * (опросом, планом обмена или параллельной отменой) не перезаписывается ни повторно, ни итогом `cancelled` /
   * `cancel_failed`. Возвращает `true`, если запись сделал этот вызов (ревью F, RC-9).
   */
  private async markCancel(
    p: PaymentRow,
    raw: 'cancelled' | 'paid' | 'cancel_failed',
    patch: PaymentPatch,
  ): Promise<boolean> {
    return this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, systemActor('payments'));
      const cur = await this.repo.findById(tx, p.id, true);
      if (!cur || cur.status !== 'voided') return false;
      if (cur.qrProviderStatusRaw === 'paid') return false;
      const moved = await this.repo.transition(tx, p.id, 'voided', null, {
        qrProviderStatusRaw: raw,
        qrStatusCheckedAt: this.clock.now(),
        ...(patch.bankReference ? { bankReference: patch.bankReference } : {}),
        ...(patch.bankAmount ? { bankAmount: patch.bankAmount } : {}),
      });
      return moved !== null;
    });
  }

  /** Таймер: `qr_shown → qr_expired` (без `review_reason`, наступил `qr_expires_at`). */
  private async expire(paymentId: string): Promise<boolean> {
    return this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, systemActor('payments'));
      const p = await this.repo.findById(tx, paymentId, true);
      const now = this.clock.now();
      if (!p || p.status !== 'qr_shown' || p.reviewReason !== null || !p.qrExpiresAt || p.qrExpiresAt > now) {
        return false;
      }
      await this.writer.move(tx, p, 'qr_expired', 'timer', {});
      return true;
    });
  }

  /** Применить отчёт провайдера к платежу (идемпотентно; блокировка заказ → платёж). */
  private async applyReport(paymentId: string, r: ProviderReportInput): Promise<string> {
    const outcome = await this.db.transaction(async (tx) => {
      const audit = systemActor('payments');
      await applyAuditGucs(tx, audit);
      const pre = await this.repo.findById(tx, paymentId);
      if (!pre) return { result: 'ignored_unknown_payment' } as const;
      const order = pre.orderId ? await this.orders.lockForPayment(tx, pre.orderId) : null;
      const p = await this.repo.findById(tx, paymentId, true);
      if (!p) return { result: 'ignored_unknown_payment' } as const;
      const now = this.clock.now();
      const paid = r.paidAmount !== null ? Money.of(r.paidAmount) : null;
      const decision: ProviderDecision = decideProviderReport(p.status, Money.of(p.amount).toTyiyn(), {
        state: r.state,
        paidTyiyn: paid ? paid.toTyiyn() : null,
        referenceKnown: r.reference !== null && r.reference === p.qrProviderRef,
        // История референсов (перевыпуск, PAY-025; ревью F-orders-1c-5).
        referencePrevious:
          r.reference !== null && r.reference !== p.qrProviderRef && p.qrRefHistory.includes(r.reference),
      });
      const seen: PaymentPatch = {
        qrStatusCheckedAt: now,
        qrProviderStatusRaw: r.raw ? r.raw.slice(0, 100) : null,
      };
      if (decision.kind === 'transition' && decision.to === 'received') {
        if (!order) return { result: 'ignored_no_order' } as const;
        const res = await this.writer.receive(tx, {
          payment: p,
          order,
          actorKind: 'provider',
          salesActor: SYSTEM_ACTOR,
          patch: {
            ...seen,
            receivedByUserId: null,
            receivedAt: r.paidAt ? new Date(r.paidAt) : now,
            bankAmount: positiveOrNull(r.paidAmount),
            bankReference: r.bankReference,
            ...(r.documentRef && isUuid(r.documentRef) ? { onecRef: r.documentRef } : {}),
            ...(r.documentType ? { onecDocType: r.documentType } : {}),
          },
          journal: 'payment_received',
          journalDetails: { confirmationKind: 'webhook', provider: 'onec', reference: r.reference },
          audit: {
            ctx: audit,
            action: 'payment.received',
            after: {
              confirmationKind: 'webhook',
              provider: 'onec',
              reference: r.reference,
              bankReference: r.bankReference,
            },
          },
        });
        return { result: 'received', payment: res.payment } as const;
      }
      if (decision.kind === 'transition' && decision.to === 'manual_confirm') {
        const moved = await this.writer.move(tx, p, 'manual_confirm', 'provider', {
          ...seen,
          reviewReason: decision.reviewReason,
          bankAmount: positiveOrNull(r.paidAmount),
          bankReference: r.bankReference,
        });
        return { result: `manual_confirm:${decision.reviewReason}`, payment: moved } as const;
      }
      if (decision.kind === 'transition' && decision.to === 'qr_expired') {
        // 05 §6.7.3: QR отменён в 1С или банком без запроса backend — QR больше не принимает оплату: срок QR
        // наступает сейчас (`qr_expires_at = now`), переход по таймеру автомата 07 §6.4 (ревью F-orders-1c-7).
        if (decision.cause === 'provider_cancelled') {
          const moved = await this.writer.move(tx, p, 'qr_expired', 'timer', {
            ...seen,
            qrExpiresAt: now,
          });
          return { result: 'qr_expired', payment: moved } as const;
        }
        // 08 §6.1: «срок истёк» от 1С статус не меняет до qr_expires_at; далее — таймер.
        if (p.qrExpiresAt && p.qrExpiresAt <= now) {
          const moved = await this.writer.move(tx, p, 'qr_expired', 'timer', seen);
          return { result: 'qr_expired', payment: moved } as const;
        }
        await this.repo.transition(tx, p.id, p.status, null, seen);
        return { result: 'pending' } as const;
      }
      if (decision.kind === 'review_only' && p.status === 'voided' && r.state === 'paid') {
        // Оплата по аннулированному QR (план обмена / опрос): статус не меняется, факт — в полях QR и журнале.
        if (p.qrProviderStatusRaw === 'paid') return { result: 'unchanged' } as const;
        const marked = await this.repo.transition(tx, p.id, 'voided', null, {
          qrStatusCheckedAt: now,
          qrProviderStatusRaw: 'paid',
          bankAmount: positiveOrNull(r.paidAmount),
          bankReference: r.bankReference,
        });
        return {
          result: 'voided_paid',
          payment: marked ?? p,
          bankReference: r.bankReference,
          paidAmount: r.paidAmount,
        } as const;
      }
      if (decision.kind === 'review_only') {
        return { result: 'review_only', payment: p } as const;
      }
      if (p.status === 'qr_shown' || p.status === 'qr_expired') {
        await this.repo.transition(tx, p.id, p.status, null, seen);
      }
      if (p.status === 'qr_shown' && p.qrExpiresAt && p.qrExpiresAt <= now && p.reviewReason === null) {
        const moved = await this.writer.move(tx, p, 'qr_expired', 'timer', {});
        return { result: 'qr_expired', payment: moved } as const;
      }
      return { result: 'unchanged' } as const;
    });
    await this.afterReport(outcome);
    return outcome.result;
  }

  private async afterReport(o: {
    readonly result: string;
    readonly payment?: PaymentRow;
    readonly bankReference?: string | null;
    readonly paidAmount?: string | null;
  }): Promise<void> {
    const p = o.payment;
    if (!p) return;
    if (o.result === 'voided_paid') {
      await this.reportPaidAfterVoid(p, {
        bankReference: o.bankReference ?? null,
        paidAmount: positiveOrNull(o.paidAmount),
        source: 'status_report',
      });
    } else if (o.result === 'received') {
      await this.notifier.notify({
        userId: p.createdByUserId,
        paymentId: p.id,
        orderId: p.orderId,
        severity: 'info',
        title: 'Оплата по QR получена',
        body: `Платёж ${p.publicNumber} оплачен.`,
        event: 'received',
      });
    } else if (o.result.startsWith('manual_confirm')) {
      await this.notifier.notify({
        userId: p.createdByUserId,
        paymentId: p.id,
        orderId: p.orderId,
        severity: 'warning',
        title: 'Платёж требует разбора',
        body: `Оплата по платежу ${p.publicNumber} требует проверки кассиром (${p.reviewReason ?? 'разбор'}).`,
        event: `manual_confirm:${p.reviewReason ?? ''}`,
      });
    } else if (o.result === 'review_only') {
      this.logger.warn({ paymentId: p.id, status: p.status }, 'payments.qr.paid_while_not_awaiting');
      await this.notifier.notify({
        userId: p.createdByUserId,
        paymentId: p.id,
        orderId: p.orderId,
        severity: 'warning',
        title: 'Поступление по QR требует разбора',
        body: `По платежу ${p.publicNumber} 1С сообщила об оплате в статусе «${p.status}».`,
        event: `review_only:${p.status}`,
      });
    }
  }
}

function positiveOrNull(v: string | null | undefined): string | null {
  if (v === null || v === undefined) return null;
  const m = Money.of(v);
  return m.compare(Money.ZERO) > 0 ? m.toString() : null;
}
