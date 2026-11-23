import { Inject, Injectable, Logger, Optional } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { applyAuditGucs, systemActor } from '../../common/audit/audit-context.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { DRIZZLE, type Database } from '../../common/db/database.module.js';
import { Money } from '../../common/money/money.js';
import { BANK_QR_API, type BankOperation, type BankQrApi } from '../../integrations/payments/bank/bank-qr-api.js';
import { PaymentNotifier } from '../infra/payment-notifier.js';
import { PaymentsRepository } from '../infra/payments.repository.js';
import { rows } from '../infra/sql-executor.js';
import { QrStatusService, type ReportOutcome } from '../qr/qr-status.service.js';
import { BANK_PROVIDER_CODE, notifyUnknownReference } from './bank-webhook.service.js';

/** Сдвиг Бишкека (UTC+6). */
const BISHKEK_OFFSET_MS = 6 * 3600_000;

/** Вчерашний календарный день Бишкека относительно `now` (`YYYY-MM-DD`). */
export function previousBishkekDay(now: Date): string {
  return new Date(now.getTime() + BISHKEK_OFFSET_MS - 24 * 3600_000).toISOString().slice(0, 10);
}

export interface QrReconciliationDiscrepancy {
  readonly kind:
    | 'unknown_reference'
    | 'amount_mismatch'
    | 'missing_in_bank'
    | 'applied_late'
    | 'paid_after_void'
    | 'duplicate_payment';
  readonly operationId: string | null;
  readonly reference: string | null;
  readonly paymentId: string | null;
  readonly bankAmount: string | null;
  readonly amount: string | null;
}

export interface QrReconciliationSummary {
  readonly day: string;
  readonly bankOperations: number;
  readonly matched: number;
  /** Оплаты, которые сверка применила к платежам (вебхук не дошёл): `received` / `manual_confirm`. */
  readonly applied: number;
  /**
   * Полученные за день QR-платежи без динамического QR банка (статический QR или `manualOnly` — запасной путь при
   * `QR_UNAVAILABLE`, подтверждение кассиром по выписке): по референсу их с операцией банка не сопоставить, поэтому
   * они считаются отдельно и расхождением `missing_in_bank` не являются (уведомления нет).
   */
  readonly manualWithoutBankQr: number;
  readonly discrepancies: readonly QrReconciliationDiscrepancy[];
}

/** `processing_error` строки сверки для второй операции банка по одному платежу. */
export const DUPLICATE_PAYMENT = 'duplicate_payment';

interface OperationResult {
  readonly kind: 'matched' | 'applied' | 'discrepancy';
  readonly paymentId: string | null;
  readonly amount: string | null;
  readonly discrepancy: QrReconciliationDiscrepancy | null;
}

/**
 * Ежедневная сверка QR (ADR-123; 10 PAY-029; 08 §6 «Fallback без вебхука»; 12 T-PAY-020): операции зачисления банка
 * за день (`BankQrApi.listOperations`) против `payments`:
 * - операция по QR платежа `qr_shown`/`qr_expired` (вебхук не дошёл) — применяется тем же автоматом, что вебхук
 *   (`received` / `manual_confirm` с `review_reason`), запись `payment_webhook_events` с ключом `recon:<операция>`;
 * - операция по аннулированному QR — `QR_PAID_AFTER_VOID` (журнал и уведомления, статус не меняется);
 * - платёж `received`, а сумма его операции другая — расхождение `amount_mismatch` (уведомление администраторам);
 * - **вторая операция по одному платежу** (например, оплачены прежний QR до перевыпуска и новый) — расхождение
 *   `duplicate_payment`: у платежа `received`/`manual_confirm` уже учтена другая операция (`payments.bank_reference`
 *   или применившее переход событие `payment_webhook_events`), либо за день на платёж пришли две операции и больше;
 *   строка `recon:<операция>` с `processing_error = duplicate_payment`, уведомление администраторам и кассирам;
 * - операция с неизвестным референсом — `unknown_reference` (строка `payment_webhook_events` без `payment_id`, отчёт
 *   `qr-reconciliation` → `unknownOperations`, уведомление кассирам и администраторам, `system`);
 * - платёж с динамическим QR банка `received` за день без операции банка — `missing_in_bank`; платежи без
 *   динамического QR (статический, `manualOnly`) — отдельный счётчик `manualWithoutBankQr` без уведомления.
 * Идемпотентна: повтор за тот же день не применяет оплату второй раз (ключ `recon:<операция>`) и не повторяет
 * уведомления (ключ дедупликации). Отчёт для людей — `GET /admin/reports/qr-reconciliation` (08 §4.18.8).
 */
@Injectable()
export class QrReconciliationService {
  private readonly logger = new Logger('payments.qr_reconcile');

  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly repo: PaymentsRepository,
    private readonly qrStatus: QrStatusService,
    private readonly notifier: PaymentNotifier,
    @Optional() @Inject(BANK_QR_API) private readonly bank?: BankQrApi | null,
  ) {}

  /** Сверка нужна только при QR банка через наш сервер. */
  get enabled(): boolean {
    return this.config.QR_PROVIDER === 'bank' && !!this.bank;
  }

  /** Сверка за день (`YYYY-MM-DD`, по умолчанию — вчера по Бишкеку). */
  async reconcileDay(day: string = previousBishkekDay(this.clock.now())): Promise<QrReconciliationSummary> {
    if (!this.enabled || !this.bank) {
      return { day, bankOperations: 0, matched: 0, applied: 0, manualWithoutBankQr: 0, discrepancies: [] };
    }
    const ops = await this.bank.listOperations(day);
    const discrepancies: QrReconciliationDiscrepancy[] = [];
    let matched = 0;
    let applied = 0;
    /** Операции дня по платежу: две и больше — повторная оплата (страховка поверх проверки каждой операции). */
    const byPayment = new Map<string, { op: BankOperation; duplicate: boolean; amount: string | null }[]>();
    for (const op of ops) {
      const r = await this.reconcileOperation(op);
      if (r.paymentId) {
        const list = byPayment.get(r.paymentId) ?? [];
        list.push({ op, duplicate: r.discrepancy?.kind === 'duplicate_payment', amount: r.amount });
        byPayment.set(r.paymentId, list);
      }
      if (r.kind === 'matched') matched += 1;
      else if (r.kind === 'applied') applied += 1;
      if (r.discrepancy) discrepancies.push(r.discrepancy);
    }
    for (const [paymentId, list] of byPayment) {
      if (list.length < 2 || list.some((x) => x.duplicate)) continue;
      // Ни одна операция не признана повторной (например, платёж подтверждён кассиром без события банка): все
      // операции после первой — расхождение `duplicate_payment`.
      for (const x of list.slice(1)) {
        await this.db.transaction(async (tx) => {
          await applyAuditGucs(tx, systemActor('payments.qr_reconcile'));
          await this.record(tx, `recon:${x.op.operationId}`, x.op, paymentId, DUPLICATE_PAYMENT);
        });
        discrepancies.push({
          kind: 'duplicate_payment',
          operationId: x.op.operationId,
          reference: x.op.reference,
          paymentId,
          bankAmount: x.op.amount,
          amount: x.amount,
        });
      }
    }
    let manualWithoutBankQr = 0;
    for (const p of await this.repo.receivedQrOfDay(this.db, BANK_PROVIDER_CODE, day)) {
      if (byPayment.has(p.id)) continue;
      if (!p.dynamicQr) {
        manualWithoutBankQr += 1;
        continue;
      }
      discrepancies.push({
        kind: 'missing_in_bank',
        operationId: p.bankReference,
        reference: p.qrRef,
        paymentId: p.id,
        bankAmount: null,
        amount: p.amount,
      });
    }
    const summary = { day, bankOperations: ops.length, matched, applied, manualWithoutBankQr, discrepancies };
    for (const d of discrepancies) await this.notifyDiscrepancy(day, d);
    this.logger.log(
      { day, bankOperations: ops.length, matched, applied, manualWithoutBankQr, discrepancies: discrepancies.length },
      'payments.qr_reconcile.done',
    );
    return summary;
  }

  private async reconcileOperation(op: BankOperation): Promise<OperationResult> {
    const key = `recon:${op.operationId}`;
    const done: { outcome: ReportOutcome | null } = { outcome: null };
    const res = await this.db.transaction(async (tx): Promise<OperationResult> => {
      await applyAuditGucs(tx, systemActor('payments.qr_reconcile'));
      const paymentId = await this.repo.findByQrReference(tx, BANK_PROVIDER_CODE, op.reference);
      // Уже учтённая операция: вебхук с тем же референсом операции или прежний прогон сверки.
      const known = await rows<{ payment_id: string | null; provider_event_id: string }>(
        tx,
        sql`SELECT payment_id, provider_event_id FROM payment_webhook_events
             WHERE provider = ${BANK_PROVIDER_CODE} AND signature_valid
               AND (provider_event_id = ${key} OR payload ->> 'operationId' = ${op.operationId})
             LIMIT 1`,
      );
      const p = paymentId ? await this.repo.findById(tx, paymentId) : null;
      const amount = p?.amount ?? null;
      const out = (kind: OperationResult['kind'], d: QrReconciliationDiscrepancy['kind'] | null): OperationResult => ({
        kind,
        paymentId,
        amount,
        discrepancy: d
          ? { kind: d, operationId: op.operationId, reference: op.reference, paymentId, bankAmount: op.amount, amount }
          : null,
      });
      if (!p) {
        if (known.length === 0) await this.record(tx, key, op, null, 'unknown_reference');
        return out('discrepancy', 'unknown_reference');
      }
      if (p.status === 'received' || p.status === 'manual_confirm') {
        if ((await this.ownOperation(tx, p.id, p.bankReference, op.operationId)) === 'other') {
          // Деньги по платежу уже учтены другой операцией банка — вторая оплата (PAY-029).
          await this.record(tx, key, op, p.id, DUPLICATE_PAYMENT);
          return out('discrepancy', 'duplicate_payment');
        }
        // Своя операция платежа. Если её ещё никто не записал (подтверждение кассиром без вебхука) — строка сверки,
        // чтобы следующая операция по этому платежу была распознана как повторная.
        if (known.length === 0) await this.record(tx, key, op, p.id, null);
        if (p.status === 'manual_confirm') return out('matched', null);
        const same = Money.of(p.amount).compare(Money.of(op.amount)) === 0;
        return same ? out('matched', null) : out('discrepancy', 'amount_mismatch');
      }
      // Событие уже применено (разбор у кассира) — сверка не дублирует переход.
      if (known.length > 0) return out('matched', null);
      const o = await this.qrStatus.applyReportIn(tx, p.id, {
        state: 'paid',
        reference: op.reference,
        paidAmount: op.amount,
        paidAt: op.paidAt,
        bankReference: op.operationId,
        documentRef: null,
        documentType: null,
        raw: 'reconciliation',
      });
      done.outcome = o;
      await this.record(tx, key, op, p.id, o.result === 'received' ? null : o.result);
      if (o.result === 'voided_paid') return out('discrepancy', 'paid_after_void');
      return out('applied', 'applied_late');
    });
    if (done.outcome) await this.qrStatus.notifyOutcome(done.outcome);
    if (res.discrepancy?.kind === 'unknown_reference') {
      await notifyUnknownReference(this.notifier, { key: op.operationId, reference: op.reference, amount: op.amount });
    }
    return res;
  }

  /**
   * Чья операция банка для платежа `received`/`manual_confirm`: `own` — операция, по которой платёж получен или
   * поставлен на разбор (`payments.bank_reference` или событие `payment_webhook_events` этого платежа, применившее
   * переход: `processing_error` пуст или `manual_confirm:*`), либо у платежа нет ни одной учтённой операции банка
   * (подтверждение кассиром по выписке — сопоставить не с чем); `other` — у платежа учтена другая операция.
   */
  private async ownOperation(
    tx: DbExecutor,
    paymentId: string,
    bankReference: string | null,
    operationId: string,
  ): Promise<'own' | 'other'> {
    if (bankReference !== null && bankReference === operationId) return 'own';
    const applied = await rows<{ operation_id: string }>(
      tx,
      sql`SELECT DISTINCT payload ->> 'operationId' AS operation_id FROM payment_webhook_events
           WHERE provider = ${BANK_PROVIDER_CODE} AND signature_valid AND payment_id = ${paymentId}::uuid
             AND payload ->> 'operationId' IS NOT NULL
             AND (processing_error IS NULL OR processing_error LIKE 'manual_confirm:%')`,
    );
    if (applied.some((x) => x.operation_id === operationId)) return 'own';
    return applied.length > 0 ? 'other' : 'own';
  }

  /** Строка `payment_webhook_events` от сверки (ключ `recon:<операция>`; повтор — без изменений). */
  private async record(
    tx: DbExecutor,
    key: string,
    op: BankOperation,
    paymentId: string | null,
    error: string | null,
  ): Promise<void> {
    await tx.execute(sql`
      INSERT INTO payment_webhook_events (provider, provider_event_id, payment_id, signature_valid, payload,
                                          processed_at, processing_error)
      VALUES (${BANK_PROVIDER_CODE}, ${key}, ${paymentId}::uuid, true,
              ${JSON.stringify({ source: 'reconciliation', ...op })}::jsonb, now(), ${error})
      ON CONFLICT (provider, provider_event_id) DO NOTHING`);
  }

  private async notifyDiscrepancy(day: string, d: QrReconciliationDiscrepancy): Promise<void> {
    // Неизвестный референс — уведомление кассирам и администраторам сразу после транзакции операции
    // (`notifyUnknownReference`); поздняя оплата и оплата после аннулирования — уведомления автомата.
    if (!d.paymentId || d.kind === 'applied_late' || d.kind === 'paid_after_void') return;
    if (d.kind === 'duplicate_payment') {
      const notice = {
        paymentId: d.paymentId,
        orderId: null,
        severity: 'error' as const,
        title: 'Сверка QR: повторная оплата',
        body:
          `Сверка QR за ${day}: по платежу пришла ещё одна операция банка ${d.operationId ?? '—'} ` +
          `(${d.bankAmount ?? '—'} KGS) — деньги зачислены дважды, оформите в 1С возврат или аванс.`,
        event: `qr_reconcile:duplicate_payment:${d.operationId ?? ''}`,
      };
      await this.notifier.notifyRole('admin', notice);
      await this.notifier.notifyRole('cashier', notice);
      return;
    }
    const titles: Record<string, string> = {
      amount_mismatch: 'Сверка QR: сумма банка не совпала',
      missing_in_bank: 'Сверка QR: нет операции банка',
    };
    await this.notifier.notifyRole('admin', {
      paymentId: d.paymentId,
      orderId: null,
      severity: 'warning',
      title: titles[d.kind] ?? 'Сверка QR: расхождение',
      body: `Сверка QR за ${day}: ${d.kind} (банк ${d.bankAmount ?? '—'}, платёж ${d.amount ?? '—'}).`,
      event: `qr_reconcile:${day}:${d.kind}`,
    });
  }
}
