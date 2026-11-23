import { randomUUID } from 'node:crypto';
import type { BlockList } from 'node:net';
import { Inject, Injectable, Logger, Optional } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { type AuditContext, applyAuditGucs, systemActor } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { DRIZZLE, type Database } from '../../common/db/database.module.js';
import { ipAllowed, normalizeClientIp, parseIpAllowlist } from '../../common/http/ip-allowlist.js';
import { Money } from '../../common/money/money.js';
import { ONEC_OUTBOX_WRITER, SalesPortRegistry } from '../../common/ports/index.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { rateLimitedProblem } from '../../common/rate-limit/http-rate-limit.js';
import { RateLimitService } from '../../common/rate-limit/rate-limit.service.js';
import { verifyWebhookSignature } from '../../integrations/payments/bank/webhook-signature.js';
import { PaymentNotifier } from '../infra/payment-notifier.js';
import { PaymentsRepository } from '../infra/payments.repository.js';
import { rows } from '../infra/sql-executor.js';
import type { ReportOutcome } from '../qr/qr-status.service.js';
import { QrStatusService } from '../qr/qr-status.service.js';

/** Код провайдера в `payment_webhook_events.provider` и `payments.qr_provider` (ADR-123 п. 3: исторический `bakai`). */
export const BANK_PROVIDER_CODE = 'bakai';

/** RL-WEBHOOK (08 §2.9): 600 запросов в минуту с одного IP источника; счётчик — PostgreSQL (`webhook_ip_1m`). */
export const WEBHOOK_RATE_LIMIT_PER_MINUTE = 600;
/** Переопределение лимита RL-WEBHOOK (тесты; по умолчанию — 08 §2.9). */
export const WEBHOOK_RATE_LIMIT = Symbol('WEBHOOK_RATE_LIMIT');

/**
 * Уведомление кассирам и администраторам о зачислении банка по неизвестному референсу QR (08 §6 «Сопоставление»,
 * POS-053; `notification_kind = system`). Ключ дедупликации — операция банка (или событие), поэтому вебхук и сверка
 * по одной операции не дублируют уведомление.
 */
export async function notifyUnknownReference(
  notifier: PaymentNotifier,
  d: { readonly key: string; readonly reference: string | null; readonly amount: string | null },
): Promise<void> {
  const n = {
    severity: 'warning' as const,
    title: 'Оплата QR по неизвестному референсу',
    body:
      `Банк зачислил ${d.amount ?? '—'} KGS по референсу ${d.reference ?? '—'}, платёж не найден. ` +
      'Сверьте с выпиской и подтвердите платёж вручную или оформите деньги в 1С.',
    dedupeKey: `qr_unknown_reference:${d.key}`,
  };
  await notifier.notifySystemRole('cashier', n);
  await notifier.notifySystemRole('admin', n);
}

const MONEY_RE = /^\d{1,12}\.\d{2}$/;
const EVENT_TYPES = new Set(['payment.succeeded', 'payment.failed', 'payment.expired']);

/** Тело вебхука банка (08 §6, OpenAPI `PaymentsQrWebhookEvent`) — проектное предположение `[НЕ ПОДТВЕРЖДЕНО: Q-382]`. */
export interface BankWebhookEvent {
  readonly eventId: string;
  readonly eventType: 'payment.succeeded' | 'payment.failed' | 'payment.expired';
  readonly reference: string;
  readonly operationId: string | null;
  readonly merchantOrderId: string | null;
  readonly amount: string;
  readonly currency: 'KGS';
  readonly paidAt: string | null;
}

export interface BankWebhookInput {
  readonly rawBody: Buffer;
  readonly signature: string | undefined;
  readonly timestamp: string | undefined;
  /** IP отправителя (`req.ip` с учётом доверенного прокси); у песочницы — `127.0.0.1`. */
  readonly ip: string | null;
  readonly requestId?: string | null;
}

export interface BankWebhookAck {
  readonly received: true;
  readonly status?: 'unknown_reference';
}

export interface BankWebhookResult {
  readonly ack: BankWebhookAck;
  /** Итог для журнала и ответа служебного маршрута песочницы: `received`, `manual_confirm:<reason>`, `duplicate`… */
  readonly result: string;
  readonly paymentId: string | null;
}

/**
 * Вебхук банка о зачислении `POST /payments/qr/webhook` (08 §4.9.5, §6; ADR-123; 11 SEC-135). Порядок проверок:
 * 0) RL-WEBHOOK (08 §2.9): не больше `WEBHOOK_RATE_LIMIT_PER_MINUTE` запросов в минуту с одного IP — иначе
 *    `429 RATE_LIMITED` (до записи журнала: поток отказов не растит `payment_webhook_events` и аудит без предела);
 * 1) IP отправителя в `QR_WEBHOOK_ALLOWED_IPS` — иначе `403 FORBIDDEN` (обязательная проверка в pos-api, ядро §18.2
 *    п. 13), аудит `payment.webhook_rejected`;
 * 2) подпись `X-Signature = HMAC-SHA256(secret, X-Timestamp + "." + rawBody)` по **сырому** телу, `X-Timestamp` ±5 мин —
 *    иначе `401 WEBHOOK_SIGNATURE_INVALID`, платёж не меняется, аудит и строка `payment_webhook_events`
 *    (`signature_valid=false`, ключ `rejected:<uuid>` — не занимает `eventId` настоящего события);
 * 3) тело — `PaymentsQrWebhookEvent`, иначе `400 VALIDATION_FAILED`;
 * 4) идемпотентность — `UNIQUE (provider, provider_event_id)` `payment_webhook_events`: повтор `eventId` → 200 без
 *    побочных эффектов; новое событие записывается **в одной транзакции** с переходом платежа;
 * 5) сопоставление по референсу QR (текущему или из истории перевыпусков), затем по `merchantOrderId`; дальше — тот же
 *    автомат, что для отчёта 1С (`QrStatusService.applyReportIn`, ADR-073 без изменений): совпали сумма и референс →
 *    `received` (+ документ оплаты в `onec_outbox`), сумма ≠ → `manual_confirm` (`amount_mismatch`), оплата после
 *    истечения → `late_payment`, референс заменённого QR → `late_payment`, чужой референс → `unknown_reference`;
 *    неизвестный референс → `200 {received, status: unknown_reference}` + строка без `payment_id` (видна в отчёте
 *    `qr-reconciliation`, `unknownOperations`) + уведомление кассирам и администраторам (`system`) после COMMIT.
 * Обработка синхронная: запись события, переход платежа и документ оплаты в `onec_outbox` — одна транзакция запроса;
 * после COMMIT — уведомления и пинок outbox.
 * Бизнес-расхождения — не ошибка (200). Тело события в журнал не пишется (NFR-LOG-001), только `eventId`, референс,
 * сумма и итог.
 */
@Injectable()
export class BankWebhookService {
  private readonly logger = new Logger('payments.webhook');
  private readonly allowList: BlockList | null;
  private readonly rateLimitPerMinute: number;

  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly repo: PaymentsRepository,
    private readonly qrStatus: QrStatusService,
    private readonly audit: AuditService,
    private readonly registry: SalesPortRegistry,
    private readonly notifier: PaymentNotifier,
    @Optional() private readonly rateLimit?: RateLimitService,
    @Optional() @Inject(WEBHOOK_RATE_LIMIT) rateLimitPerMinute?: number,
  ) {
    this.allowList = parseIpAllowlist(config.QR_WEBHOOK_ALLOWED_IPS, 'QR_WEBHOOK_ALLOWED_IPS');
    this.rateLimitPerMinute = rateLimitPerMinute ?? WEBHOOK_RATE_LIMIT_PER_MINUTE;
  }

  /** Маршрут вебхука зарегистрирован (ADR-123): `QR_PROVIDER=bank` и `QR_WEBHOOK_ENABLED=true`. */
  get enabled(): boolean {
    return this.config.QR_PROVIDER === 'bank' && this.config.QR_WEBHOOK_ENABLED;
  }

  async receive(input: BankWebhookInput): Promise<BankWebhookResult> {
    if (!this.enabled) throw new ProblemException('NOT_FOUND', { detail: 'Ресурс не найден.' });
    const ip = normalizeClientIp(input.ip);
    const ctx: AuditContext = { ...systemActor('payments.webhook', input.requestId ?? undefined), ip: ip || null };
    await this.checkRateLimit(ip);
    if (!this.allowList || !ipAllowed(this.allowList, ip)) {
      await this.reject(ctx, 'ip_not_allowed', null);
      throw new ProblemException('FORBIDDEN', { detail: 'Недостаточно прав для операции.' });
    }
    const secret = this.config.QR_WEBHOOK_SECRET;
    const check = secret
      ? verifyWebhookSignature({
          secret,
          rawBody: input.rawBody,
          signature: input.signature,
          timestamp: input.timestamp,
          nowMs: this.clock.now().getTime(),
        })
      : ({ ok: false, reason: 'missing' } as const);
    if (!check.ok) {
      await this.reject(ctx, `signature_${check.reason}`, input.rawBody);
      throw new ProblemException('WEBHOOK_SIGNATURE_INVALID', { detail: 'Подпись не прошла проверку.' });
    }
    const event = parseEvent(input.rawBody);
    return this.apply(event, ctx);
  }

  /** Подписанное событие: запись `payment_webhook_events` и переход платежа — одна транзакция. */
  private async apply(event: BankWebhookEvent, ctx: AuditContext): Promise<BankWebhookResult> {
    const done: { outcome: ReportOutcome | null } = { outcome: null };
    const res = await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      const ins = await rows<{ id: string }>(
        tx,
        sql`INSERT INTO payment_webhook_events (provider, provider_event_id, signature_valid, payload, source_ip)
            VALUES (${BANK_PROVIDER_CODE}, ${event.eventId}, true, ${JSON.stringify(eventLogView(event))}::jsonb,
                    ${ctx.ip ?? null}::inet)
            ON CONFLICT (provider, provider_event_id) DO NOTHING
            RETURNING id`,
      );
      if (!ins[0]) {
        const prev = await rows<{ payment_id: string | null }>(
          tx,
          sql`SELECT payment_id FROM payment_webhook_events
               WHERE provider = ${BANK_PROVIDER_CODE} AND provider_event_id = ${event.eventId}`,
        );
        const pid = prev[0]?.payment_id ?? null;
        return { result: 'duplicate', paymentId: pid, unknown: pid === null } as const;
      }
      const eventRowId = ins[0].id;
      const paymentId =
        (await this.repo.findByQrReference(tx, BANK_PROVIDER_CODE, event.reference)) ??
        (event.merchantOrderId
          ? await this.repo.findQrByOrderNumber(tx, BANK_PROVIDER_CODE, event.merchantOrderId)
          : null);
      let result: string;
      if (!paymentId) {
        result = 'unknown_reference';
      } else if (event.eventType === 'payment.failed') {
        result = 'ignored_failed';
      } else {
        const outcome = await this.qrStatus.applyReportIn(tx, paymentId, {
          state: event.eventType === 'payment.succeeded' ? 'paid' : 'expired',
          reference: event.reference,
          paidAmount: event.eventType === 'payment.succeeded' ? event.amount : null,
          paidAt: event.paidAt,
          bankReference: event.operationId ?? event.reference,
          documentRef: null,
          documentType: null,
          raw: event.eventType,
        });
        done.outcome = outcome;
        result = outcome.result;
      }
      await tx.execute(sql`
        UPDATE payment_webhook_events
           SET payment_id = ${paymentId}::uuid, processed_at = now(),
               processing_error = ${result === 'received' ? null : result.slice(0, 200)}, updated_at = now()
         WHERE id = ${eventRowId}::uuid`);
      await this.audit.write(
        ctx,
        {
          action: 'payment.webhook_received',
          entityType: 'payment',
          entityId: paymentId,
          after: {
            eventId: event.eventId,
            eventType: event.eventType,
            reference: event.reference,
            amount: event.amount,
            result,
          },
          ...(paymentId ? {} : { result: 'error' as const, severity: 'warning' as const }),
        },
        tx,
      );
      return { result, paymentId, unknown: paymentId === null } as const;
    });
    if (done.outcome) await this.qrStatus.notifyOutcome(done.outcome);
    if (res.result === 'unknown_reference') {
      await notifyUnknownReference(this.notifier, {
        key: event.operationId ?? `event:${event.eventId}`,
        reference: event.reference,
        amount: event.amount,
      });
    }
    if (res.result === 'received') await this.kickOutbox();
    this.logger.log(
      { eventId: event.eventId, reference: event.reference, amount: event.amount, result: res.result },
      'payments.webhook.processed',
    );
    return {
      ack: res.unknown ? { received: true, status: 'unknown_reference' } : { received: true },
      result: res.result,
      paymentId: res.paymentId,
    };
  }

  /** RL-WEBHOOK: счётчик `rate_limit_counters` (`webhook_ip_1m`, ключ — IP источника). */
  private async checkRateLimit(ip: string): Promise<void> {
    if (!this.rateLimit) return;
    const r = await this.rateLimit.consume([
      { scope: 'webhook_ip_1m', subject: ip || 'unknown', limit: this.rateLimitPerMinute },
    ]);
    if (r.allowed) return;
    this.logger.warn({ ip }, 'payments.webhook.rate_limited');
    throw rateLimitedProblem(this.rateLimitPerMinute, Math.max(1, r.retryAfterSec));
  }

  private async reject(ctx: AuditContext, reason: string, rawBody: Buffer | null): Promise<void> {
    this.logger.warn({ reason, ip: ctx.ip }, 'payments.webhook.rejected');
    try {
      await this.db.transaction(async (tx) => {
        await applyAuditGucs(tx, ctx);
        if (rawBody !== null) {
          // Только для отправителей из allowlist (проверка IP — раньше): тело — маской (08 §6 «Логи»).
          await tx.execute(sql`
            INSERT INTO payment_webhook_events (provider, provider_event_id, signature_valid, payload, source_ip,
                                                processed_at, processing_error)
            VALUES (${BANK_PROVIDER_CODE}, ${`rejected:${randomUUID()}`}, false,
                    ${JSON.stringify({ bytes: rawBody.length, reason })}::jsonb, ${ctx.ip ?? null}::inet, now(),
                    ${reason})`);
        }
        await this.audit.write(
          ctx,
          {
            action: 'payment.webhook_rejected',
            entityType: 'payment',
            entityId: null,
            after: { reason },
            result: 'denied',
            severity: 'warning',
          },
          tx,
        );
      });
    } catch (err) {
      this.logger.error({ err, reason }, 'payments.webhook.reject_log_failed');
    }
  }

  private async kickOutbox(): Promise<void> {
    if (!this.registry.isBound(ONEC_OUTBOX_WRITER)) return;
    try {
      await this.registry.get(ONEC_OUTBOX_WRITER).kickAfterCommit();
    } catch (err) {
      this.logger.warn({ err }, 'payments.webhook.outbox_kick_failed');
    }
  }
}

/** Разбор и проверка тела (после проверки подписи). */
export function parseEvent(raw: Buffer): BankWebhookEvent {
  let v: unknown;
  try {
    v = JSON.parse(raw.toString('utf8'));
  } catch {
    throw invalid('body', 'json', 'Тело — не JSON.');
  }
  if (!v || typeof v !== 'object' || Array.isArray(v)) throw invalid('body', 'object', 'Ожидается объект.');
  const o = v as Record<string, unknown>;
  const str = (k: string, max: number, required: boolean): string | null => {
    const x = o[k];
    if (x === undefined || x === null) {
      if (required) throw invalid(k, 'required', 'Обязательное поле.');
      return null;
    }
    if (typeof x !== 'string' || x.trim() === '' || x.length > max) throw invalid(k, 'string', `Строка до ${max}.`);
    return x.trim();
  };
  const eventId = str('eventId', 128, true) as string;
  const eventType = str('eventType', 32, true) as string;
  if (!EVENT_TYPES.has(eventType)) throw invalid('eventType', 'enum', 'Неизвестный тип события.');
  const reference = str('reference', 64, true) as string;
  const amount = str('amount', 20, true) as string;
  if (!MONEY_RE.test(amount)) throw invalid('amount', 'money_format', 'Сумма строкой с двумя знаками.');
  const currency = str('currency', 3, true);
  if (currency !== 'KGS') throw invalid('currency', 'enum', 'Только KGS.');
  const paidAt = str('paidAt', 40, false);
  if (paidAt !== null && Number.isNaN(Date.parse(paidAt))) throw invalid('paidAt', 'date_time', 'ISO 8601.');
  return {
    eventId,
    eventType: eventType as BankWebhookEvent['eventType'],
    reference,
    operationId: str('operationId', 64, false),
    merchantOrderId: str('merchantOrderId', 64, false),
    amount: Money.of(amount).toString(),
    currency: 'KGS',
    paidAt,
  };
}

function invalid(field: string, rule: string, message: string): ProblemException {
  return new ProblemException('VALIDATION_FAILED', {
    status: 400,
    detail: 'Тело вебхука не прошло проверку.',
    errors: [{ field, rule, message }],
  });
}

/** Что сохраняется в `payment_webhook_events.payload`: без данных плательщика (NFR-LOG-001). */
function eventLogView(e: BankWebhookEvent): Record<string, unknown> {
  return {
    eventId: e.eventId,
    eventType: e.eventType,
    reference: e.reference,
    operationId: e.operationId,
    merchantOrderId: e.merchantOrderId,
    amount: e.amount,
    currency: e.currency,
    paidAt: e.paidAt,
  };
}
