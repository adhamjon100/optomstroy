import type { PgBoss } from 'pg-boss';
import { type OnecConfirmedPayload, type OnecFailedPayload, QUEUES } from '../../common/jobs/contracts/queues.js';

/** Обработчики результата доставки документа оплаты в 1С (модуль `payments`, `PaymentOnecDocument`). */
export interface PaymentOnecResultsHandlers {
  onConfirmed(p: OnecConfirmedPayload): Promise<unknown>;
  onFailed(p: OnecFailedPayload): Promise<unknown>;
}

/**
 * `payments.onec-confirmed` / `payments.onec-failed` (06 §7.4 п. (б); ADR-123): документ оплаты QR банка, поставленный
 * в `onec_outbox` (`payment/create`), принят или отклонён 1С. Регистрирует pos-worker (`extraWorkers`, как
 * `orders.onec-*`); очереди создаёт планировщик (`sync/scheduler/queue-specs.ts`).
 */
export async function registerPaymentOnecResults(boss: PgBoss, h: PaymentOnecResultsHandlers): Promise<void> {
  const poll = { pollingIntervalSeconds: 2, batchSize: 1 }; // money-double: allow — секунды
  await boss.work<OnecConfirmedPayload>(QUEUES.paymentsOnecConfirmed, poll, async ([job]) =>
    job ? { outcome: await h.onConfirmed(job.data) } : undefined,
  );
  await boss.work<OnecFailedPayload>(QUEUES.paymentsOnecFailed, poll, async ([job]) =>
    job ? { outcome: await h.onFailed(job.data) } : undefined,
  );
}
