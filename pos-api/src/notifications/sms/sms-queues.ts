import type { Queue } from 'pg-boss';
import { QUEUES } from '../../common/jobs/contracts/queues.js';

/**
 * Очереди pg-boss SMS (06 §7.5: `sms.send` — `retryLimit=3`, DR-опрос по расписанию 30 с / 2 мин / 10 мин;
 * `sms.balance_poll`). Очередь опроса отчётов `sms.dlr_poll` в перечне 06 §7.5 / QUEUES отсутствует (там DR-опрос
 * описан внутри строки `sms.send`) — имя `[НОВОЕ ИМЯ]`, вопрос D_spec_questions SMS-Q-01.
 */
export const SMS_QUEUES = {
  send: QUEUES.smsSend,
  dlrPoll: 'sms.dlr_poll',
  balancePoll: QUEUES.smsBalancePoll,
} as const;

/** Payload `sms.send`. Текст SMS — только в зашифрованном виде (`SmsTextSealer`): в БД открытого кода нет. */
export interface SmsSendJob {
  readonly smsOutboxId: string;
  /** AES-256-GCM(текст), AAD = `smsOutboxId` (sms-text-sealer.ts). */
  readonly sealedText: string;
  readonly requestId?: string;
}

/** Payload `sms.dlr_poll`: номер раунда опроса (0-based) по расписанию `DLR_POLL_DELAYS_SEC`. */
export interface SmsDlrPollJob {
  readonly smsOutboxId: string;
  readonly round: number;
}

/** Расписание DR-опроса после принятия (09 §6.5, SMS-016): через 30 с, 2 мин, 10 мин. */
export const DLR_POLL_DELAYS_SEC: readonly number[] = [30, 120, 600];
/** При `SMSPRO_DLR_MODE=push` — один страховочный опрос через 10 мин, если push не пришёл. */
export const DLR_PUSH_FALLBACK_DELAYS_SEC: readonly number[] = [600];

/**
 * Параметры очередей. `sms.send`: повтор задания pg-boss — только на случай падения процесса (ретраи по кодам
 * §6.4 выполняются внутри обработчика с тем же `id`); `expireInSeconds` покрывает 4 попытки по
 * `SMSPRO_TIMEOUT_MS` + паузы 5/10/10 с.
 */
export const SMS_QUEUE_OPTIONS: Readonly<Record<string, Omit<Queue, 'name'>>> = {
  [SMS_QUEUES.send]: { retryLimit: 3, retryDelay: 30, expireInSeconds: 600, deleteAfterSeconds: 24 * 3600 },
  [SMS_QUEUES.dlrPoll]: { retryLimit: 1, retryDelay: 30, expireInSeconds: 120, deleteAfterSeconds: 24 * 3600 },
  [SMS_QUEUES.balancePoll]: { retryLimit: 0, expireInSeconds: 120, deleteAfterSeconds: 7 * 24 * 3600 },
};
