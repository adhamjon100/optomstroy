import { type Clock, systemClock } from '../../common/auth/clock.js';
import { maskPhone } from '../../common/logging/redaction.js';
import type { PosDatabase } from '../../db/database.js';
import type { DeliveryReport, SmsGateway } from '../../integrations/sms/sms-gateway.js';
import { SMS_METRICS, type SmsTelemetry } from '../../integrations/sms/sms-telemetry.js';
import type { PushReportEntry } from '../../integrations/sms/smspro-xml.js';
import { NOOP_SMS_DELIVERY_LISTENER, type SmsDeliveryListener } from './sms-delivery.listener.js';
import type { SmsOutboxRepository, SmsOutboxRow } from './sms-outbox.repository.js';
import type { SmsDlrPollJob } from './sms-queues.js';

export interface SmsDlrServiceDeps {
  readonly db: PosDatabase;
  readonly repo: SmsOutboxRepository;
  readonly gateway: Pick<SmsGateway, 'queryDeliveryReport'>;
  readonly telemetry: SmsTelemetry;
  readonly listener?: SmsDeliveryListener;
  readonly clock?: Clock;
}

export interface DlrPollResult {
  readonly smsOutboxId: string;
  readonly skipped?: 'not_found' | 'not_sent' | 'in_flight' | 'busy' | 'error';
  readonly providerStatus?: number;
  readonly report?: number;
  readonly changed?: boolean;
}

export interface DlrPushResult {
  readonly applied: number;
  readonly duplicates: number;
  readonly unknown: number;
}

/**
 * Отчёты о доставке (09 §6.5, SMS-016/SMS-017; AC-AUTH-032/033):
 * - опрос `POST /api/dr` (с `phone` всегда) по расписанию 30 с / 2 мин / 10 мин; параллельные запросы с одним `id`
 *   не отправляются (`status=5` вендора) — защита в процессе (`inFlight`) и `singletonKey` заданий;
 * - push-отчёты: только известные `dr/id` и только номер этой строки (иначе — «неизвестный», метрика
 *   `sms_dlr_unknown_id_total`); повтор того же отчёта ничего не меняет (идемпотентно).
 * Маппинг `report` → `sms_outbox.status` — `SmsOutboxRepository.applyDeliveryReport`.
 */
export class SmsDlrService {
  private readonly listener: SmsDeliveryListener;
  private readonly clock: Clock;
  private readonly inFlight = new Set<string>();

  constructor(private readonly d: SmsDlrServiceDeps) {
    this.listener = d.listener ?? NOOP_SMS_DELIVERY_LISTENER;
    this.clock = d.clock ?? systemClock;
  }

  async poll(job: SmsDlrPollJob): Promise<DlrPollResult> {
    const row = await this.d.repo.findById(job.smsOutboxId);
    if (!row) return { smsOutboxId: job.smsOutboxId, skipped: 'not_found' };
    if (row.status !== 'sent') return { smsOutboxId: row.id, skipped: 'not_sent' };
    const id = row.providerMessageId;
    if (this.inFlight.has(id)) return { smsOutboxId: row.id, skipped: 'in_flight' };
    this.inFlight.add(id);
    let res;
    try {
      res = await this.d.gateway.queryDeliveryReport(id, row.phoneE164);
    } catch (e) {
      this.d.telemetry.logger.warn({
        event: 'sms.dr.error',
        transactionId: id,
        error: e instanceof Error ? e.message : 'unknown',
        round: job.round,
      });
      return { smsOutboxId: row.id, skipped: 'error' };
    } finally {
      this.inFlight.delete(id);
    }
    if (res.status === 5) return { smsOutboxId: row.id, skipped: 'busy', providerStatus: 5 };
    if (res.status !== 0) {
      if (res.status !== 4) {
        this.d.telemetry.alerts.raise({
          kind: 'sms_dlr_error',
          severity: 'warning',
          message: `SMSPro /api/dr: status=${res.status}`,
          details: { transactionId: id, providerStatus: res.status },
        });
      }
      return { smsOutboxId: row.id, providerStatus: res.status };
    }
    const report = pickReport(row, res.reports);
    if (!report) return { smsOutboxId: row.id, providerStatus: 0 };
    const changed = await this.apply(row, report);
    return { smsOutboxId: row.id, providerStatus: 0, report: report.report, changed };
  }

  async applyPush(entries: readonly PushReportEntry[]): Promise<DlrPushResult> {
    let applied = 0;
    let duplicates = 0;
    let unknown = 0;
    for (const entry of entries) {
      const row = await this.d.repo.findByProviderMessageId(entry.id);
      const report = row ? pickReport(row, entry.reports, true) : undefined;
      if (!row || !report) {
        unknown += 1;
        this.d.telemetry.metrics.inc(SMS_METRICS.dlrUnknownIdTotal);
        continue;
      }
      this.d.telemetry.metrics.inc(SMS_METRICS.deliveryReportTotal, { report: report.report });
      if (await this.apply(row, report)) applied += 1;
      else duplicates += 1;
    }
    this.d.telemetry.logger.log({ event: 'sms.dlr.push', entries: entries.length, applied, duplicates, unknown });
    return { applied, duplicates, unknown };
  }

  private async apply(row: SmsOutboxRow, report: DeliveryReport): Promise<boolean> {
    const deliveredAt = report.rcvTime ? new Date(report.rcvTime) : this.clock.now();
    return this.d.db.transaction(async (tx) => {
      const updated = await this.d.repo.applyDeliveryReport(row.id, { report: report.report, deliveredAt }, tx);
      if (!updated) return false;
      if (this.listener.onDeliveryReport) {
        await this.listener.onDeliveryReport(
          { smsOutboxId: row.id, otpChallengeId: row.otpChallengeId, report: report.report, state: report.state },
          tx,
        );
      }
      this.d.telemetry.logger.log({
        event: 'sms.dlr',
        transactionId: row.providerMessageId,
        phoneMasked: maskPhone(row.phoneE164),
        report: report.report,
        state: report.state,
        status: updated.status,
      });
      return true;
    });
  }
}

/** Отчёт по номеру строки (`996XXXXXXXXX`); при `strict` (push) — только совпадающий номер. */
function pickReport(row: SmsOutboxRow, reports: readonly DeliveryReport[], strict = false): DeliveryReport | undefined {
  const number = row.phoneE164.replace(/^\+/, '');
  const exact = reports.find((r) => r.number.replace(/^\+/, '') === number);
  if (exact || strict) return exact;
  return reports.length === 1 ? reports[0] : undefined;
}
