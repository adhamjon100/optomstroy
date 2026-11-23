import { Inject, Injectable, Logger } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { applyAuditGucs, systemActor } from '../../common/audit/audit-context.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE, type Database } from '../../common/db/database.module.js';
import type { OnecConfirmedPayload, OnecFailedPayload } from '../../common/jobs/contracts/queues.js';
import { Money } from '../../common/money/money.js';
import { ONEC_OUTBOX_WRITER, type OnecOutboxWriter } from '../../common/ports/index.js';
import { PaymentNotifier } from '../infra/payment-notifier.js';
import { PaymentsLookups } from '../infra/payments-lookups.js';
import type { PaymentRow } from '../infra/payments.repository.js';
import { rows } from '../infra/sql-executor.js';

/** Момент → `YYYY-MM-DDTHH:MM:SS+06:00` (контракт 1С `DateTime`, ONEC-058; Бишкек без летнего времени). */
function onecDateTime(d: Date): string {
  return `${new Date(d.getTime() + 6 * 3600_000).toISOString().slice(0, 19)}+06:00`;
}

/**
 * Документ оплаты в 1С по QR банка через наш сервер (ADR-123 п. 1, п. 7; 05 §6.7.3; 10 PAY-012): при переходе
 * платежа `qr_bakai` с `qr_provider='bakai'` в `received` (вебхук банка, опрос статуса, сверка или `confirm-manual`)
 * в **той же транзакции** ставится элемент `onec_outbox` `payment/create` → `POST /pos/v1/payments` (контракт 1С
 * `PaymentCreateRequest`, `kind=qr_bakai`, `bankReference` — операция банка).
 *
 * Без двойных документов: (1) одна строка на платёж — уникальность `(aggregate_type, aggregate_id, operation)`,
 * повтор возвращает существующую; (2) `externalId` = `payments.id` — идемпотентность метода 1С (повтор → 200
 * «уже существует», ONEC-043); (3) при `QR_PROVIDER=onec` документ создаёт интеграция 1С с банком, строка outbox не
 * ставится (05 §6.7.3 п. (5)); (4) наличные — по-прежнему ветка «иначе» 10 PAY-012 (Q-012), здесь не трогаются.
 * Если интеграция банка в 1С сама проводит поступления по счёту магазина — она не должна создавать второй документ
 * по нашим QR (`[НЕ ПОДТВЕРЖДЕНО: Q-383]`).
 *
 * Порядок: элемент зависит от `order/create` заказа (`depends_on_outbox_id`, 05 SYNC-042) — платёж уходит после
 * заказа; пустые `orderRef`/`customerRef` дополняются при доставке ссылками 1С заказа (`OnecOutboxDelivery`).
 */
@Injectable()
export class PaymentOnecDocument {
  private readonly logger = new Logger('payments.onec');

  constructor(
    @Inject(ONEC_OUTBOX_WRITER) private readonly outbox: OnecOutboxWriter,
    private readonly lookups: PaymentsLookups,
    @Inject(DRIZZLE) private readonly db: Database,
    private readonly notifier: PaymentNotifier,
  ) {}

  /**
   * `payments.onec-confirmed` (06 §7.4 п. (б)): 1С создала документ оплаты (или вернула существующий по `externalId`)
   * → ссылка в `payments.onec_ref` (платёж «отражён в 1С»). Повтор — без изменений. Ref уже записан у другого
   * платежа (1С вернула один документ на два платежа) — `ref_conflict`: запись `sync_errors`
   * (`DUPLICATE_SUSPECTED`, `payload.code = ONEC_REF_CONFLICT`, одна на платёж и Ref) и уведомление администраторам.
   */
  async onConfirmed(p: OnecConfirmedPayload): Promise<'linked' | 'unchanged' | 'ref_conflict'> {
    const res = await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, systemActor('outbox'));
      const r = await rows<{ id: string }>(
        tx,
        sql`UPDATE payments SET onec_ref = ${p.onecRef}::uuid, updated_at = now()
             WHERE id = ${p.aggregateId}::uuid AND onec_ref IS NULL
               AND NOT EXISTS (SELECT 1 FROM payments o WHERE o.onec_ref = ${p.onecRef}::uuid)
             RETURNING id`,
      );
      if (r[0]) return { outcome: 'linked' as const, otherId: null };
      // Ссылка не записана: повтор (у платежа уже есть onec_ref) — норма; иначе Ref 1С уже у другого платежа —
      // 1С вернула один документ на два платежа (ошибка 1С или фикстура с постоянным Ref). Молча не проглатываем:
      // запись журнала синхронизации (одна на платёж и Ref) и уведомление администраторам.
      const cur = await rows<{ onec_ref: string | null; other_id: string | null }>(
        tx,
        sql`SELECT p.onec_ref::text AS onec_ref,
                   (SELECT o.id::text FROM payments o WHERE o.onec_ref = ${p.onecRef}::uuid AND o.id <> p.id LIMIT 1)
                     AS other_id
              FROM payments p WHERE p.id = ${p.aggregateId}::uuid`,
      );
      const row = cur[0];
      if (!row || row.onec_ref !== null || row.other_id === null)
        return { outcome: 'unchanged' as const, otherId: null };
      const message = `Ссылка 1С ${p.onecRef} документа оплаты уже записана у другого платежа — платёж не отражён в 1С`;
      await tx.execute(
        sql`INSERT INTO sync_errors (entity, outbox_id, onec_ref, local_id, error_code, message, payload, severity)
            SELECT 'payment_docs', ${p.outboxId}::uuid, ${p.onecRef}::uuid, ${p.aggregateId}::uuid,
                   'DUPLICATE_SUSPECTED', ${message},
                   ${JSON.stringify({ code: 'ONEC_REF_CONFLICT', paymentId: p.aggregateId, otherPaymentId: row.other_id, onecRef: p.onecRef, onecNumber: p.onecNumber })}::jsonb,
                   'error'
             WHERE NOT EXISTS (SELECT 1 FROM sync_errors
                                WHERE entity = 'payment_docs' AND local_id = ${p.aggregateId}::uuid
                                  AND error_code = 'DUPLICATE_SUSPECTED' AND onec_ref = ${p.onecRef}::uuid)`,
      );
      return { outcome: 'ref_conflict' as const, otherId: row.other_id };
    });
    if (res.outcome !== 'ref_conflict') return res.outcome;
    this.logger.warn(
      { paymentId: p.aggregateId, otherPaymentId: res.otherId, onecRef: p.onecRef },
      'payments.onec.ref_conflict',
    );
    await this.notifier.notifyRole('admin', {
      paymentId: p.aggregateId,
      orderId: null,
      severity: 'error',
      title: 'Документ оплаты 1С: ссылка занята',
      body: `1С вернула для платежа документ ${p.onecNumber ?? p.onecRef}, уже записанный у другого платежа. Проверьте журнал синхронизации.`,
      event: `onec_ref_conflict:${p.onecRef}`,
    });
    return 'ref_conflict';
  }

  /** `payments.onec-failed`: 1С отклонила документ оплаты — уведомление администраторам (разбор, 07 §8.2). */
  async onFailed(p: OnecFailedPayload): Promise<void> {
    this.logger.warn({ paymentId: p.aggregateId, code: p.errorCode }, 'payments.onec.document_rejected');
    await this.notifier.notifyRole('admin', {
      paymentId: p.aggregateId,
      orderId: null,
      severity: 'error',
      title: 'Документ оплаты не принят 1С',
      body: `1С отклонила документ оплаты по QR (${p.errorCode}). Проверьте журнал синхронизации.`,
      event: `onec_failed:${p.outboxId}`,
    });
  }

  /** Нужен ли документ оплаты от сервера POS: только QR банка через наш сервер (ADR-123). */
  static applies(p: Pick<PaymentRow, 'method' | 'qrProvider'>): boolean {
    return p.method === 'qr_bakai' && p.qrProvider === 'bakai';
  }

  /** Поставить `payment/create` для полученного платежа (в транзакции перехода в `received`). */
  async enqueue(tx: DbExecutor, p: PaymentRow): Promise<void> {
    if (!PaymentOnecDocument.applies(p) || p.status !== 'received') return;
    const order = p.orderId ? await this.lookups.order(tx, p.orderId) : null;
    const dependency = p.orderId
      ? await this.outbox.lock(tx, { aggregateType: 'order', aggregateId: p.orderId, operation: 'create' })
      : null;
    const payload = {
      externalId: p.id,
      kind: 'qr_bakai',
      amount: Money.of(p.amount).toString(),
      currency: 'KGS',
      customerRef: order?.customerOnecRef ?? null,
      orderExternalId: p.orderId,
      orderRef: order?.onecRef ?? null,
      receivedAt: onecDateTime(p.receivedAt ?? new Date()),
      cashierUserCode: p.manualConfirmedByUserId ?? p.receivedByUserId ?? 'system',
      post: true,
      bankReference: p.bankReference ?? p.qrProviderRef,
      allocations: [],
    };
    await this.outbox.enqueue(tx, {
      aggregateType: 'payment',
      aggregateId: p.id,
      operation: 'create',
      payload,
      dependsOnOutboxId: dependency && dependency.status !== 'cancelled' ? dependency.outboxId : null,
      requestedByUserId: p.manualConfirmedByUserId ?? p.receivedByUserId ?? null,
    });
  }
}
