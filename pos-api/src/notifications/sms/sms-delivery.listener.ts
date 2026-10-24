import type { DbExecutor } from '../../common/audit/db-executor.js';
import type { DeliveryState, SendOutcome } from '../../integrations/sms/sms-gateway.js';

/**
 * Порт уведомления владельца OTP об итоге доставки (09 §6.8, SMS-021). Модуль `auth` (RM-D-001, `OtpService`)
 * реализует его и регистрирует под токеном `SMS_DELIVERY_LISTENER`: итог `sent` → challenge остаётся `sent`
 * (предыдущий — `superseded`), итог `failed` → challenge `failed_delivery` (не учитывается в лимите номера).
 * notifications не импортирует auth (MOD-022): связь — только через этот порт. Вызов — внутри транзакции,
 * обновляющей `sms_outbox` (параметр `tx`).
 */
export interface SmsSendSettledEvent {
  readonly smsOutboxId: string;
  readonly otpChallengeId: string | null;
  /** Итог жизненного цикла отправки. */
  readonly status: 'sent' | 'failed';
  /** Класс исхода последней попытки (`RETRYABLE` — ретраи исчерпаны или breaker открыт). */
  readonly outcome: SendOutcome | null;
  /** Машинная причина неудачи (`retry_exhausted`, `circuit_open`, `status_4`, …) — без секретов. */
  readonly error?: string;
}

export interface SmsDeliveryReportEvent {
  readonly smsOutboxId: string;
  readonly otpChallengeId: string | null;
  readonly report: number;
  readonly state: DeliveryState;
}

export interface SmsDeliveryListener {
  onSendSettled(event: SmsSendSettledEvent, tx: DbExecutor): Promise<void>;
  /** Отчёт о доставке (для `OTP_RESEND_ON_DLR_FAILED`: при `FAILED` — повторная отправка раньше cooldown). */
  onDeliveryReport?(event: SmsDeliveryReportEvent, tx: DbExecutor): Promise<void>;
}

export const SMS_DELIVERY_LISTENER = 'SmsDeliveryListener' as const;

export const NOOP_SMS_DELIVERY_LISTENER: SmsDeliveryListener = Object.freeze({
  onSendSettled: () => Promise.resolve(),
});
