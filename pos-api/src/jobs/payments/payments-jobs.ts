import type { PgBoss, Queue } from 'pg-boss';
import { QUEUES } from '../../common/jobs/contracts/queues.js';

/**
 * Фоновые задачи платежей (06 §7.5; ядро v1.9 §24.4; 05 SYNC-077…079) — обработчики в модуле `payments`
 * (`QrStatusService`), регистрация — здесь:
 * - `payments.qr_onec_poll {paymentId}` — опрос статуса QR у 1С каждые `QR_ONEC_POLL_SECONDS`, пока платёж
 *   `qr_shown` (и до `expiresAt` + 60 с — поздняя оплата), одна задача на платёж (`singletonKey` = id платежа,
 *   политика `short`: не более одной ожидающей); также отмена QR в 1С у аннулированного платежа;
 * - `payments.qr_expire` — `qr_shown` с наступившим `qr_expires_at` → `qr_expired` (каждую минуту);
 * - `payments.onec-qr-status` — элемент `QrPaymentStatus` плана обмена (`/changes`, публикует `sync`).
 */
export const PAYMENTS_QUEUES = [
  QUEUES.paymentsQrOnecPoll,
  QUEUES.paymentsQrExpire,
  QUEUES.paymentsOnecQrStatus,
] as const;

/** Payload `payments.qr_onec_poll`. */
export interface QrOnecPollPayload {
  readonly paymentId: string;
}

/**
 * Payload `payments.onec-qr-status` (элемент `QrPaymentStatus` из `/changes`, 05 ONEC-077, §6.7.2; публикует
 * `QrPaymentStatusChangeHandler` модуля `sync` в транзакции сообщения). Поля — схема контракта
 * `QrPaymentStatusChange` (`externalId`, `status`, `reference`, `paidAmount`, `paidAt`, `bankReference`,
 * `documentRef`). `amount` и `documentType` в элементе плана обмена не передаются (есть только в ответе
 * `GET /pos/v1/payments/{externalId}/status`) — необязательны (разбор расхождений п. 69). Контракт очереди в
 * common/jobs/contracts не объявлен (FQ-PAY-05).
 */
export interface OnecQrStatusPayload {
  readonly externalId: string;
  readonly status: 'pending' | 'paid' | 'expired' | 'cancelled';
  readonly reference: string | null;
  readonly amount?: string | null;
  readonly paidAmount: string | null;
  readonly paidAt: string | null;
  readonly bankReference: string | null;
  readonly documentRef?: string | null;
  readonly documentType?: string | null;
}

/** Итог одного опроса: продолжать ли цепочку и через сколько секунд. */
export interface QrPollOutcome {
  readonly continue: boolean;
  readonly delaySeconds: number;
  readonly status: string | null;
}

export interface PaymentsJobHandlers {
  pollQr(paymentId: string): Promise<QrPollOutcome>;
  expireDue(): Promise<number>;
  applyOnecQrStatus(payload: OnecQrStatusPayload): Promise<string>;
  /** Платежи, для которых нужно возобновить опрос/отмену после перезапуска процесса. */
  pollCandidates(): Promise<readonly string[]>;
}

/** Минимальный клиент для `send … { db }` (задача в транзакции бизнес-операции). */
export interface BossDb {
  executeSql(text: string, values?: unknown[]): Promise<{ rows: unknown[] }>;
}

export async function ensurePaymentsQueues(boss: PgBoss): Promise<void> {
  const specs: readonly { readonly name: string; readonly options: Omit<Queue, 'name'> }[] = [
    {
      name: QUEUES.paymentsQrOnecPoll,
      options: { policy: 'short', retryLimit: 2, retryDelay: 5, expireInSeconds: 120 },
    },
    { name: QUEUES.paymentsQrExpire, options: { policy: 'singleton', retryLimit: 1, expireInSeconds: 120 } },
    { name: QUEUES.paymentsOnecQrStatus, options: { policy: 'standard', retryLimit: 5, retryDelay: 10 } },
  ];
  for (const s of specs) {
    const existing = await boss.getQueue(s.name);
    if (!existing) {
      try {
        await boss.createQueue(s.name, s.options);
      } catch (e) {
        // Гонка двух процессов: очередь создана параллельно — не ошибка.
        if (!(await boss.getQueue(s.name))) throw e;
      }
    }
  }
}

/** Поставить следующий опрос QR платежа (`startAfter` секунд). Дубль ожидающей задачи pg-boss отбрасывает. */
export async function schedulePaymentPoll(
  boss: PgBoss,
  paymentId: string,
  delaySeconds: number,
  db?: BossDb,
): Promise<void> {
  await boss.send(QUEUES.paymentsQrOnecPoll, { paymentId } satisfies QrOnecPollPayload, {
    singletonKey: paymentId,
    startAfter: Math.max(0, Math.round(delaySeconds)), // money-double: allow — секунды, не сумма
    ...(db ? { db } : {}),
  });
}

export interface RegisterPaymentsJobsOptions {
  /** Интервал опроса очередей pg-boss, секунды (минимум pg-boss — 0.5). */
  readonly pollingIntervalSeconds: number; // money-double: allow — секунды
  readonly log: { warn(obj: object, msg: string): void; info(obj: object, msg: string): void };
}

/**
 * Регистрация обработчиков на экземпляре pg-boss процесса, исполняющего задачи (`WORKERS_ENABLED=true`): pos-worker
 * или pos-api в минимальной конфигурации (16 §4.3, Q-135). Расписание `payments.qr_expire` — каждую минуту
 * (применяет процесс с `schedule: true`). После регистрации возобновляется опрос незавершённых QR-платежей.
 */
export async function registerPaymentsJobs(
  boss: PgBoss,
  handlers: PaymentsJobHandlers,
  opts: RegisterPaymentsJobsOptions,
): Promise<void> {
  await ensurePaymentsQueues(boss);
  const work = { pollingIntervalSeconds: opts.pollingIntervalSeconds, batchSize: 1 };
  await boss.work<QrOnecPollPayload>(QUEUES.paymentsQrOnecPoll, work, async ([job]) => {
    if (!job?.data?.paymentId) return undefined;
    const outcome = await handlers.pollQr(job.data.paymentId);
    if (outcome.continue) await schedulePaymentPoll(boss, job.data.paymentId, outcome.delaySeconds);
    return outcome;
  });
  await boss.work(QUEUES.paymentsQrExpire, work, async () => ({ expired: await handlers.expireDue() }));
  await boss.work<OnecQrStatusPayload>(QUEUES.paymentsOnecQrStatus, work, async ([job]) => {
    if (!job?.data?.externalId) return undefined;
    return { result: await handlers.applyOnecQrStatus(job.data) };
  });
  await boss
    .schedule(QUEUES.paymentsQrExpire, '* * * * *', {}, { singletonKey: 'payments.qr_expire' })
    .catch((err: unknown) => opts.log.warn({ err }, 'payments.qr_expire: расписание не установлено'));
  for (const id of await handlers.pollCandidates()) await schedulePaymentPoll(boss, id, 0);
  opts.log.info({ queues: PAYMENTS_QUEUES }, 'payments.jobs.registered');
}
