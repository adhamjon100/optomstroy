import { type Clock, systemClock } from '../../common/auth/clock.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { generateProviderMessageId } from '../../common/crypto/index.js';
import type { PosDatabase } from '../../db/database.js';
import {
  type DeliveryReport,
  isAcceptedOutcome,
  type SendOutcome,
  type SendResult,
  type SmsGateway,
  type SmsTemplateKey,
} from '../../integrations/sms/sms-gateway.js';
import { SMS_METRICS, type SmsTelemetry } from '../../integrations/sms/sms-telemetry.js';
import { maskPhone } from '../../common/logging/redaction.js';
import { NOOP_SMS_DELIVERY_LISTENER, type SmsDeliveryListener } from './sms-delivery.listener.js';
import type { SmsJobPublisher } from './sms-job-publisher.js';
import type { SmsOutboxRepository, SmsOutboxRow } from './sms-outbox.repository.js';
import {
  DLR_POLL_DELAYS_SEC,
  DLR_PUSH_FALLBACK_DELAYS_SEC,
  SMS_QUEUES,
  type SmsDlrPollJob,
  type SmsSendJob,
} from './sms-queues.js';
import type { SmsTextSealer } from './sms-text-sealer.js';

/** Задержки повтора при `status=9` (09 §6.4: «повтор с тем же id… 5, 10, 10 с, не более 3 повторов»). */
export const STATUS9_RETRY_DELAYS_MS: readonly number[] = [5_000, 10_000, 10_000];
/** Задержки повтора после таймаута/сетевой ошибки/невалидного XML (с тем же `id`, до `SMSPRO_RETRY_MAX`). */
export const TRANSPORT_RETRY_DELAYS_MS: readonly number[] = [5_000, 10_000, 10_000];
/** HTTP 5xx: «повторять 1–2 раза с тем же id и с алертом», затем `PERMANENT` (09 §6.4). */
export const HTTP_5XX_RETRY_DELAYS_MS: readonly number[] = [5_000, 10_000];
/** Пауза перед повторным `/dr` при `status=5` («дождаться ответа на предыдущий запрос с этим ID»). */
const DR_BUSY_DELAY_MS = 5_000;
/** Страховка от бесконечного цикла (сумма всех допустимых попыток + новый id). */
const MAX_LOOP = 24;

export interface SmsSendProcessorConfig {
  readonly sender: string;
  readonly testFlag: boolean;
  /** `SMSPRO_RETRY_MAX` — транспортные повторы (таймаут, сеть, невалидный XML). */
  readonly retryMax: number;
  readonly dlrMode: 'poll' | 'push';
}

export interface SmsSendProcessorDeps {
  readonly db: PosDatabase;
  readonly repo: SmsOutboxRepository;
  readonly gateway: SmsGateway;
  readonly sealer: SmsTextSealer;
  readonly publisher: SmsJobPublisher;
  readonly telemetry: SmsTelemetry;
  readonly config: SmsSendProcessorConfig;
  readonly listener?: SmsDeliveryListener;
  readonly clock?: Clock;
  readonly sleep?: (ms: number) => Promise<void>;
}

export interface SmsSendJobResult {
  readonly smsOutboxId: string;
  readonly status: 'sent' | 'failed' | 'skipped';
  readonly outcome?: SendOutcome | null;
  readonly error?: string;
  readonly attempts?: number;
  /** Число смен `id` транзакции (после `status=10` и `/dr status=4`). */
  readonly regeneratedIds?: number;
}

const defaultSleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

/**
 * Обработчик задания `sms.send` (pos-worker; 09 §4.2, §6.4, §6.8; SMS-012…SMS-015, SMS-021):
 * - `status=9` → повтор с **тем же** `id` через 5, 10, 10 с, затем `PERMANENT`;
 * - таймаут / сеть / невалидный XML → повтор с тем же `id` до `SMSPRO_RETRY_MAX` (дедупликация вендора: если первая
 *   отправка была принята, повтор вернёт `status=10`);
 * - `status=10` после нашего повтора → `/dr` по этому `id`: отчёт есть → `ACCEPTED` (вторая SMS не уходит);
 *   `status=4` («не найден») → новая отправка с **новым** `id`; иначе — неудача + алерт;
 * - HTTP 5xx → 1–2 повтора с алертом, затем `PERMANENT`;
 * - `CONFIG_ERROR` / `INSUFFICIENT_FUNDS` / `INVALID_PHONE` / `PERMANENT` → без повтора;
 * - breaker открыт → `RETRYABLE` без сети → итог `failed` (`circuit_open`).
 * Итог: `sms_outbox` `queued → sent | failed` и `SmsDeliveryListener.onSendSettled` в одной транзакции; после
 * принятия ставятся опросы `/dr` (30 с, 2 мин, 10 мин; при push — страховочный через 10 мин).
 * Задание идемпотентно: строка не в `queued` — пропуск; повтор после падения процесса считается «нашим повтором».
 */
export class SmsSendProcessor {
  private readonly listener: SmsDeliveryListener;
  private readonly clock: Clock;
  private readonly sleep: (ms: number) => Promise<void>;

  constructor(private readonly d: SmsSendProcessorDeps) {
    this.listener = d.listener ?? NOOP_SMS_DELIVERY_LISTENER;
    this.clock = d.clock ?? systemClock;
    this.sleep = d.sleep ?? defaultSleep;
  }

  async process(job: SmsSendJob): Promise<SmsSendJobResult> {
    const { repo, telemetry } = this.d;
    const row = await repo.findById(job.smsOutboxId);
    if (!row) {
      telemetry.logger.warn({ event: 'sms.job.unknown_outbox', smsOutboxId: job.smsOutboxId });
      return { smsOutboxId: job.smsOutboxId, status: 'skipped', error: 'not_found' };
    }
    if (row.status !== 'queued') {
      return { smsOutboxId: row.id, status: 'skipped', error: `already_${row.status}` };
    }
    let text: string;
    try {
      text = this.d.sealer.open(row.id, job.sealedText);
    } catch {
      return this.settleFailed(row, 'sealed_text_invalid', null, row.attempts, 0);
    }

    let transactionId = row.providerMessageId;
    // Попытка до падения процесса могла быть принята шлюзом: повтор с тем же id — «наш повтор» (09 §6.4, строка 10).
    let ambiguous = row.attempts > 0;
    let attempt = row.attempts;
    let status9 = 0;
    let transport = 0;
    let http5xx = 0;
    let regenerated = 0;
    const phone = row.phoneE164;
    const purpose = row.templateKey as SmsTemplateKey;

    for (let guard = 0; guard < MAX_LOOP; guard++) {
      attempt += 1;
      const r = await this.d.gateway.send({
        transactionId,
        sender: this.d.config.sender,
        text,
        phone,
        test: this.d.config.testFlag,
        purpose,
        smsOutboxId: row.id,
        attempt,
        ...(job.requestId ? { requestId: job.requestId } : {}),
      });
      if (r.failure === 'circuit_open') {
        attempt -= 1; // сетевого вызова не было
        return this.settleFailed(row, 'circuit_open', 'RETRYABLE', attempt, regenerated);
      }
      if (r.failure === 'invalid_request') {
        attempt -= 1;
        return this.settleFailed(row, 'invalid_request', r.outcome, attempt, regenerated);
      }
      await repo.recordAttempt(row.id, attemptRecord(r));

      if (isAcceptedOutcome(r.outcome)) return this.settleSent(row, r.outcome, attempt, regenerated);

      if (r.outcome === 'DUPLICATE_ID') {
        if (!ambiguous) {
          telemetry.alerts.raise({
            kind: 'smspro_duplicate_id',
            severity: 'critical',
            message: 'SMSPro: status=10 без нашего повтора — проверьте генерацию id транзакции',
            details: { transactionId },
          });
        }
        const resolved = await this.resolveDuplicate(transactionId, phone);
        if (resolved.kind === 'accepted') {
          return this.settleSent(row, 'ACCEPTED', attempt, regenerated, resolved.report);
        }
        if (resolved.kind === 'not_found' && regenerated === 0) {
          const fresh = generateProviderMessageId();
          await repo.replaceProviderMessageId(row.id, fresh);
          telemetry.logger.warn({
            event: 'sms.retry',
            reason: 'duplicate_id_not_found',
            transactionId,
            newTransactionId: fresh,
            attempt,
          });
          transactionId = fresh;
          regenerated += 1;
          ambiguous = false;
          status9 = 0;
          transport = 0;
          http5xx = 0;
          telemetry.metrics.inc(SMS_METRICS.retryTotal, { reason: 'new_id' });
          continue;
        }
        telemetry.alerts.raise({
          kind: 'smspro_duplicate_id',
          severity: 'critical',
          message: 'SMSPro: status=10, отчёт /dr не подтвердил отправку — SMS не отправлено',
          details: { transactionId, drStatus: resolved.kind === 'other' ? resolved.status : 4 },
        });
        return this.settleFailed(row, 'duplicate_id_unresolved', 'DUPLICATE_ID', attempt, regenerated);
      }

      if (r.outcome === 'RETRYABLE') {
        let delay: number | undefined;
        let reason: string;
        if (r.failure === 'timeout' || r.failure === 'network' || r.failure === 'bad_response') {
          ambiguous = true;
          reason = r.failure;
          if (transport < this.d.config.retryMax) {
            delay = TRANSPORT_RETRY_DELAYS_MS[Math.min(transport, TRANSPORT_RETRY_DELAYS_MS.length - 1)];
            transport += 1;
          }
        } else if (r.failure === 'http_5xx') {
          ambiguous = true;
          reason = 'http_5xx';
          if (http5xx < HTTP_5XX_RETRY_DELAYS_MS.length) {
            delay = HTTP_5XX_RETRY_DELAYS_MS[http5xx];
            http5xx += 1;
          } else {
            return this.settleFailed(row, 'http_5xx_repeated', 'PERMANENT', attempt, regenerated);
          }
        } else {
          reason = `status_${r.providerStatus ?? 'unknown'}`;
          if (status9 < STATUS9_RETRY_DELAYS_MS.length) {
            delay = STATUS9_RETRY_DELAYS_MS[status9];
            status9 += 1;
          } else {
            this.retryExhausted(transactionId, reason);
            return this.settleFailed(row, 'status_9_exhausted', 'PERMANENT', attempt, regenerated);
          }
        }
        if (delay === undefined) {
          this.retryExhausted(transactionId, reason);
          return this.settleFailed(row, 'retry_exhausted', 'RETRYABLE', attempt, regenerated);
        }
        telemetry.metrics.inc(SMS_METRICS.retryTotal, { reason });
        telemetry.logger.warn({ event: 'sms.retry', transactionId, reason, attempt, delayMs: delay });
        await this.sleep(delay);
        continue;
      }

      // PERMANENT, CONFIG_ERROR, INSUFFICIENT_FUNDS, INVALID_PHONE — без повтора (09 §6.4).
      return this.settleFailed(
        row,
        r.providerStatus !== null ? `status_${r.providerStatus}` : (r.failure ?? 'permanent'),
        r.outcome,
        attempt,
        regenerated,
      );
    }
    return this.settleFailed(row, 'retry_loop_guard', 'RETRYABLE', attempt, regenerated);
  }

  private retryExhausted(transactionId: string, reason: string): void {
    this.d.telemetry.alerts.raise({
      kind: 'smspro_retry_exhausted',
      severity: 'warning',
      message: `SMSPro: повторы исчерпаны (${reason}) — SMS не отправлено`,
      details: { transactionId, reason },
    });
  }

  private async resolveDuplicate(
    transactionId: string,
    phone: string,
  ): Promise<{ kind: 'accepted'; report: DeliveryReport } | { kind: 'not_found' } | { kind: 'other'; status: number }> {
    for (let i = 0; i < 2; i++) {
      let res;
      try {
        res = await this.d.gateway.queryDeliveryReport(transactionId, phone);
      } catch {
        return { kind: 'other', status: -1 };
      }
      const number = phone.replace(/^\+/, '');
      const report = res.reports.find((r) => r.number === number) ?? res.reports[0];
      if (res.status === 0 && report) return { kind: 'accepted', report };
      if (res.status === 4) return { kind: 'not_found' };
      if (res.status === 5 && i === 0) {
        await this.sleep(DR_BUSY_DELAY_MS);
        continue;
      }
      return { kind: 'other', status: res.status };
    }
    return { kind: 'other', status: 5 };
  }

  private async settleSent(
    row: SmsOutboxRow,
    outcome: SendOutcome,
    attempts: number,
    regeneratedIds: number,
    report?: DeliveryReport,
  ): Promise<SmsSendJobResult> {
    const now = this.clock.now();
    await this.d.db.transaction(async (tx) => {
      const updated = await this.d.repo.markSent(row.id, now, outcome, tx);
      if (!updated) return;
      await this.listener.onSendSettled(
        { smsOutboxId: row.id, otpChallengeId: row.otpChallengeId, status: 'sent', outcome },
        tx,
      );
      if (report) await this.applyReportInTx(updated, report, tx);
      if (outcome === 'ACCEPTED') await this.scheduleDlrPolls(row.id, tx);
    });
    this.d.telemetry.logger.log({
      event: 'sms.sent',
      smsOutboxId: row.id,
      phoneMasked: maskPhone(row.phoneE164),
      purpose: row.templateKey,
      outcome,
      attempts,
    });
    return { smsOutboxId: row.id, status: 'sent', outcome, attempts, regeneratedIds };
  }

  private async settleFailed(
    row: SmsOutboxRow,
    error: string,
    outcome: SendOutcome | null,
    attempts: number,
    regeneratedIds: number,
  ): Promise<SmsSendJobResult> {
    await this.d.db.transaction(async (tx) => {
      const updated = await this.d.repo.markFailed(row.id, error, outcome, tx);
      if (!updated) return;
      await this.listener.onSendSettled(
        { smsOutboxId: row.id, otpChallengeId: row.otpChallengeId, status: 'failed', outcome, error },
        tx,
      );
    });
    this.d.telemetry.logger.warn({
      event: 'sms.failed',
      smsOutboxId: row.id,
      phoneMasked: maskPhone(row.phoneE164),
      purpose: row.templateKey,
      outcome,
      error,
      attempts,
    });
    return { smsOutboxId: row.id, status: 'failed', outcome, error, attempts, regeneratedIds };
  }

  private async applyReportInTx(row: SmsOutboxRow, report: DeliveryReport, tx: DbExecutor): Promise<void> {
    const changed = await this.d.repo.applyDeliveryReport(
      row.id,
      { report: report.report, deliveredAt: report.rcvTime ? new Date(report.rcvTime) : this.clock.now() },
      tx,
    );
    if (changed && this.listener.onDeliveryReport) {
      await this.listener.onDeliveryReport(
        { smsOutboxId: row.id, otpChallengeId: row.otpChallengeId, report: report.report, state: report.state },
        tx,
      );
    }
  }

  private async scheduleDlrPolls(smsOutboxId: string, tx: DbExecutor): Promise<void> {
    const delays = this.d.config.dlrMode === 'push' ? DLR_PUSH_FALLBACK_DELAYS_SEC : DLR_POLL_DELAYS_SEC;
    for (const [round, startAfterSeconds] of delays.entries()) {
      const job: SmsDlrPollJob = { smsOutboxId, round };
      await this.d.publisher.publish(
        SMS_QUEUES.dlrPoll,
        job,
        { startAfterSeconds, singletonKey: `${smsOutboxId}:${round}` },
        tx,
      );
    }
  }
}

function attemptRecord(r: SendResult) {
  return {
    outcome: r.outcome,
    providerStatus: r.providerStatus,
    smsParts: r.smsParts,
    phonesRecognized: r.phonesRecognized,
    latencyMs: r.latencyMs,
  };
}
