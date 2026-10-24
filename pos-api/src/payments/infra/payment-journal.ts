import { Injectable } from '@nestjs/common';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import type { PaymentMethod } from '../../common/enums.js';
import { transactionDedupeKey, transactionJournal } from '../../common/journal/index.js';
import { Money } from '../../common/money/money.js';
import type { PaymentRow } from './payments.repository.js';

export type PaymentJournalKind = 'payment_received' | 'payment_voided' | 'manual_qr_confirm';

const METHOD_RU: Readonly<Record<PaymentMethod, string>> = {
  cash: 'наличные',
  qr_bakai: 'QR',
  credit: 'в долг',
};

/**
 * Журнал `transactions` (07 §5.44, DATA-143): строка пишется **в той же транзакции**, что и переход платежа
 * (SRC-D-075; 10 PAY-006). Знак суммы: `+` — приход (`payment_received`, `manual_qr_confirm`), `−` — аннулирование
 * (`payment_voided`). `dedupe_key` = `kind:payment_id:occurred_at` — повтор той же записи не создаёт дубль.
 */
@Injectable()
export class PaymentJournal {
  async write(
    tx: DbExecutor,
    input: {
      readonly kind: PaymentJournalKind;
      readonly payment: PaymentRow;
      readonly orderPublicNumber: string | null;
      readonly actorUserId: string | null;
      readonly occurredAt: Date;
      readonly details?: Readonly<Record<string, unknown>>;
    },
  ): Promise<void> {
    const p = input.payment;
    const amount = input.kind === 'payment_voided' ? Money.ZERO.minus(Money.of(p.amount)) : Money.of(p.amount);
    const what = p.orderId ? `заказа ${input.orderPublicNumber ?? ''}`.trim() : 'долга';
    const title =
      input.kind === 'payment_voided'
        ? `Аннулирование платежа ${p.publicNumber} (${METHOD_RU[p.method]})`
        : input.kind === 'manual_qr_confirm'
          ? `Оплата ${what} подтверждена вручную (QR)`
          : `Оплата ${what} (${METHOD_RU[p.method]})`;
    // Запись — через общий журнал `TransactionJournal` (порт `TransactionsWriter`, common/journal; RM-G-004).
    await transactionJournal.record(tx, {
      kind: input.kind,
      source: 'pos',
      orderId: p.orderId,
      paymentId: p.id,
      customerId: p.customerId,
      actorUserId: input.actorUserId,
      amount: amount.toString(),
      paymentMethod: p.method,
      statusSnapshot: p.status,
      title,
      details: { paymentNumber: p.publicNumber, ...input.details },
      occurredAt: input.occurredAt,
      dedupeKey: transactionDedupeKey.payment(input.kind, p.id, input.occurredAt),
    });
  }
}
