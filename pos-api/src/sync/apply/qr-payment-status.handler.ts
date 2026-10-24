import { QUEUES } from '../../common/jobs/contracts/queues.js';
import type { SyncEntity } from '../../common/enums.js';
import type { OnecQrStatusPayload } from '../../jobs/payments/payments-jobs.js';
import type { ApplyScope, ChangeItemHandler } from './apply.types.js';
import type { ChangeJobPublisher } from './change-job-publisher.js';
import { type ForeignItemError, uuidOrNull, writeForeignErrors } from './foreign-errors.js';

export const QR_PAYMENT_STATUS_TYPE = 'QrPaymentStatus';

const QR_STATUSES = new Set<OnecQrStatusPayload['status']>(['pending', 'paid', 'expired', 'cancelled']);
const MONEY_RE = /^-?\d+\.\d{2}$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+06:00$/;

function optText(v: unknown): string | null | undefined {
  if (v === null || v === undefined) return null;
  return typeof v === 'string' ? v : undefined;
}

/**
 * Элемент `QrPaymentStatus` плана обмена (запись `РегистрСведений.POS_ОплатыQR`; 05 §6.2, §6.7.2, ONEC-077, SYNC-077;
 * ядро v1.9 §24.4; разбор расхождений пп. 8, 68, 69) → задача `payments.onec-qr-status` модулю `payments` **в
 * транзакции сообщения**: регистрация в 1С снимается ack только после того, как событие сохранено для применения
 * (ядро §22.8). Применяет `QrStatusService.applyOnecQrStatus` по тем же правилам, что и опрос статуса QR: какой путь
 * первым зафиксировал оплату, тот и побеждает, повтор события — без второй записи (ТЗ для 1С 6.15).
 *
 * Поля payload — схема контракта `QrPaymentStatusChange`; элемент не по формату (не GUID `externalId`, статус вне
 * `QrStatus`, деньги/дата не по формату) не публикуется — ошибка позиции `sync_errors` (`payment_docs`, VALIDATION;
 * ТЗ 5.3 п. 12). Прогон `sync_runs` не открывается (`entityOf` → `undefined`). Сбой публикации откатывает сообщение.
 */
export class QrPaymentStatusChangeHandler implements ChangeItemHandler {
  readonly types: readonly string[] = [QR_PAYMENT_STATUS_TYPE];

  constructor(private readonly publisher: ChangeJobPublisher) {}

  entityOf(): SyncEntity | undefined {
    return undefined;
  }

  async apply(scope: ApplyScope, items: readonly Readonly<Record<string, unknown>>[]): Promise<void> {
    const errors: ForeignItemError[] = [];
    for (const it of items) {
      // Удаление записи регистра (ObjectDeletion objectType=QrPaymentStatus) статуса не несёт — не применяется.
      if (it.type !== QR_PAYMENT_STATUS_TYPE) continue;
      const parsed = toPayload(it);
      if (typeof parsed === 'string') {
        errors.push({
          entity: 'payment_docs',
          errorCode: 'VALIDATION',
          severity: 'warning',
          message: `событие QR /changes не по контракту (${parsed}) — не применено`,
          onecRef: uuidOrNull(it.externalId),
          payload: { type: QR_PAYMENT_STATUS_TYPE, field: parsed },
        });
        continue;
      }
      await this.publisher.publish(scope.client, QUEUES.paymentsOnecQrStatus, parsed);
    }
    await writeForeignErrors(scope.client, errors);
  }
}

/** Элемент → payload очереди или имя поля, нарушившего контракт. */
export function toPayload(it: Readonly<Record<string, unknown>>): OnecQrStatusPayload | string {
  const externalId = uuidOrNull(it.externalId);
  if (!externalId) return 'externalId';
  const status = it.status;
  if (typeof status !== 'string' || !QR_STATUSES.has(status as OnecQrStatusPayload['status'])) return 'status';
  const reference = optText(it.reference);
  if (reference === undefined) return 'reference';
  const paidAmount = optText(it.paidAmount);
  if (paidAmount === undefined || (paidAmount !== null && !MONEY_RE.test(paidAmount))) return 'paidAmount';
  const paidAt = optText(it.paidAt);
  if (paidAt === undefined || (paidAt !== null && !DATE_RE.test(paidAt))) return 'paidAt';
  const bankReference = optText(it.bankReference);
  if (bankReference === undefined) return 'bankReference';
  const documentRef = it.documentRef === undefined || it.documentRef === null ? null : uuidOrNull(it.documentRef);
  if (documentRef === null && it.documentRef !== undefined && it.documentRef !== null) return 'documentRef';
  return {
    externalId,
    status: status as OnecQrStatusPayload['status'],
    reference,
    paidAmount,
    paidAt,
    bankReference,
    documentRef,
  };
}
