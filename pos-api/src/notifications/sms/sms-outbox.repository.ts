import { Inject, Injectable } from '@nestjs/common';
import { and, eq, inArray, sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { smsOutbox } from '../../db/schema/index.js';
import type { SendOutcome, SmsTemplateKey } from '../../integrations/sms/sms-gateway.js';

export type SmsOutboxRow = typeof smsOutbox.$inferSelect;
export type SmsStatus = SmsOutboxRow['status'];

/** Финальные статусы `sms_status` (07 §6: `queued → sent → delivered | failed | expired`; `queued → failed`). */
export const FINAL_SMS_STATUSES: readonly SmsStatus[] = ['delivered', 'failed', 'expired'];

export interface InsertSmsOutbox {
  readonly phoneE164: string;
  readonly templateKey: SmsTemplateKey;
  readonly provider: 'smspro' | 'fake';
  readonly providerMessageId: string;
  readonly otpChallengeId?: string | null;
  /** Сквозной `X-Request-Id` запроса, породившего отправку (11 SEC-064; миграция 0003 — SMS-Q-06). */
  readonly requestId?: string | null;
}

export interface AttemptRecord {
  readonly outcome: SendOutcome;
  readonly providerStatus: number | null;
  readonly smsParts: number;
  readonly phonesRecognized: number;
  readonly latencyMs: number;
}

/** Признаки недоступности канала по журналу (межпроцессный аналог circuit-breaker'а, 09 §6.8). */
export interface SmsCircuitSignals {
  /** Последний `CONFIG_ERROR`/`INSUFFICIENT_FUNDS` в окне `SMSPRO_CB_OPEN_MINUTES` без последующего принятия. */
  readonly trip: { readonly outcome: 'CONFIG_ERROR' | 'INSUFFICIENT_FUNDS'; readonly at: Date } | null;
  /** Попыток за последнюю минуту и из них `RETRYABLE`. */
  readonly lastMinute: { readonly total: number; readonly retryable: number }; // money-double: allow — счётчик строк/событий (count), не деньги
}

/**
 * Журнал `sms_outbox` (07 §5.61, 09 §6.9): без текста и кода; `provider_message_id` — `<id>` SMSPro, UNIQUE,
 * создаётся до HTTP-вызова (SMS-006). Все методы принимают исполнитель транзакции (`DbExecutor`) последним.
 */
@Injectable()
export class SmsOutboxRepository {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async insert(input: InsertSmsOutbox, ex: DbExecutor = this.db): Promise<SmsOutboxRow> {
    const [row] = await ex
      .insert(smsOutbox)
      .values({
        phoneE164: input.phoneE164,
        templateKey: input.templateKey,
        provider: input.provider,
        providerMessageId: input.providerMessageId,
        otpChallengeId: input.otpChallengeId ?? null,
        requestId: input.requestId?.slice(0, 200) ?? null,
        status: 'queued',
      })
      .returning();
    return row;
  }

  async findById(id: string, ex: DbExecutor = this.db): Promise<SmsOutboxRow | undefined> {
    const [row] = await ex.select().from(smsOutbox).where(eq(smsOutbox.id, id)).limit(1);
    return row;
  }

  async findByProviderMessageId(
    providerMessageId: string,
    ex: DbExecutor = this.db,
  ): Promise<SmsOutboxRow | undefined> {
    const [row] = await ex.select().from(smsOutbox).where(eq(smsOutbox.providerMessageId, providerMessageId)).limit(1);
    return row;
  }

  /** Результат одной HTTP-попытки (диагностика §6.9): `attempts + 1`, код и класс исхода, части, задержка. */
  async recordAttempt(id: string, a: AttemptRecord, ex: DbExecutor = this.db): Promise<void> {
    await ex
      .update(smsOutbox)
      .set({
        attempts: sql`${smsOutbox.attempts} + 1`,
        outcome: a.outcome,
        providerStatusCode: a.providerStatus,
        smsParts: a.smsParts,
        phonesRecognized: a.phonesRecognized,
        latencyMs: Math.max(0, Math.round(a.latencyMs)),
      })
      .where(eq(smsOutbox.id, id));
  }

  /** Новый `id` транзакции после `status=10` + `/dr status=4` (SMS-013): прежний `id` у вендора заблокирован. */
  async replaceProviderMessageId(id: string, providerMessageId: string, ex: DbExecutor = this.db): Promise<void> {
    await ex.update(smsOutbox).set({ providerMessageId }).where(eq(smsOutbox.id, id));
  }

  /** Принято шлюзом (`status=0`/`11`): `queued → sent`. Строку, уже закрытую отчётом о доставке, не трогает. */
  async markSent(
    id: string,
    at: Date,
    finalOutcome: SendOutcome,
    ex: DbExecutor = this.db,
  ): Promise<SmsOutboxRow | undefined> {
    const [row] = await ex
      .update(smsOutbox)
      .set({ status: 'sent', sentAt: at, error: null, outcome: finalOutcome })
      .where(and(eq(smsOutbox.id, id), eq(smsOutbox.status, 'queued')))
      .returning();
    return row;
  }

  /** Итог отправки — неудача (`queued → failed`); `error` — машинная причина без секретов. */
  async markFailed(
    id: string,
    error: string,
    finalOutcome: SendOutcome | null,
    ex: DbExecutor = this.db,
  ): Promise<SmsOutboxRow | undefined> {
    const [row] = await ex
      .update(smsOutbox)
      .set({ status: 'failed', error: error.slice(0, 200), ...(finalOutcome ? { outcome: finalOutcome } : {}) })
      .where(and(eq(smsOutbox.id, id), eq(smsOutbox.status, 'queued')))
      .returning();
    return row;
  }

  /**
   * Отчёт о доставке (09 §6.5, §6.9): `report` 3 → `delivered` (+`delivered_at`), 2/4/5 → `failed`, 7 → `expired`,
   * 0/1/6 — статус не меняется (`sent`), обновляется `delivery_status`. Идемпотентно: повтор того же `report`
   * и отчёт по уже закрытой строке ничего не меняют (`undefined`).
   */
  async applyDeliveryReport(
    id: string,
    r: { readonly report: number; readonly deliveredAt: Date },
    ex: DbExecutor = this.db,
  ): Promise<SmsOutboxRow | undefined> {
    const status: SmsStatus | undefined =
      r.report === 3 ? 'delivered' : r.report === 7 ? 'expired' : [2, 4, 5].includes(r.report) ? 'failed' : undefined;
    const [row] = await ex
      .update(smsOutbox)
      .set({
        deliveryStatus: String(r.report),
        ...(status ? { status } : {}),
        ...(status === 'delivered' ? { deliveredAt: r.deliveredAt } : {}),
        ...(status === 'failed' ? { error: `dlr_report_${r.report}` } : {}),
      })
      .where(
        and(
          eq(smsOutbox.id, id),
          inArray(smsOutbox.status, ['queued', 'sent']),
          sql`${smsOutbox.deliveryStatus} IS DISTINCT FROM ${String(r.report)}`,
        ),
      )
      .returning();
    return row;
  }

  /** Признаки для межпроцессного «circuit open» (время — БД, `updated_at`/`sent_at`). */
  async circuitSignals(openMinutes: number, ex: DbExecutor = this.db): Promise<SmsCircuitSignals> {
    const res = await ex.execute<{
      trip_outcome: string | null;
      trip_at: Date | string | null;
      total: string | number;
      retryable: string | number;
    }>(sql`
      WITH trip AS (
        SELECT outcome, updated_at FROM sms_outbox
        WHERE outcome IN ('CONFIG_ERROR', 'INSUFFICIENT_FUNDS')
          AND updated_at > now() - make_interval(mins => ${openMinutes})
        ORDER BY updated_at DESC LIMIT 1
      ), recovered AS (
        SELECT 1 FROM sms_outbox, trip
        WHERE sms_outbox.sent_at IS NOT NULL AND sms_outbox.sent_at > trip.updated_at LIMIT 1
      ), last_min AS (
        SELECT count(*) AS total, count(*) FILTER (WHERE outcome = 'RETRYABLE') AS retryable
        FROM sms_outbox WHERE attempts > 0 AND updated_at > now() - interval '1 minute'
      )
      SELECT
        CASE WHEN EXISTS (SELECT 1 FROM recovered) THEN NULL ELSE (SELECT outcome FROM trip) END AS trip_outcome,
        CASE WHEN EXISTS (SELECT 1 FROM recovered) THEN NULL ELSE (SELECT updated_at FROM trip) END AS trip_at,
        last_min.total, last_min.retryable
      FROM last_min`);
    const r = res.rows[0];
    const tripOutcome = tripOutcomeOf(r?.trip_outcome);
    const trip = tripOutcome && r?.trip_at ? { outcome: tripOutcome, at: new Date(r.trip_at) } : null;
    return { trip, lastMinute: { total: Number(r?.total ?? 0), retryable: Number(r?.retryable ?? 0) } }; // money-double: allow — счётчик строк/событий (count), не деньги
  }
}

function tripOutcomeOf(v: string | null | undefined): 'CONFIG_ERROR' | 'INSUFFICIENT_FUNDS' | undefined {
  return v === 'CONFIG_ERROR' || v === 'INSUFFICIENT_FUNDS' ? v : undefined;
}
