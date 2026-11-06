import type { SmsTemplateKey } from '../../integrations/sms/sms-gateway.js';

/**
 * Текст SMS кода `kiosk_order` — заявка покупателя с планшета магазина (Р-21 (а), ответ владельца 2026-11-04; 09 §6.7,
 * SMS-036; ADR-115 п. 17): называет цель кода и предупреждает «никому не сообщайте», поэтому код заявки нельзя выдать
 * за код входа. Константа кода, а не переменная окружения: 65 символов при коде из 6 цифр, кириллица — одна часть
 * UCS-2 из 70 (длина постоянна, проверяется тестом `sms-texts.spec.ts`, а не при старте).
 */
export const KIOSK_ORDER_SMS_TEMPLATE = 'Оптомстрой: код {code} для заявки с планшета. Никому не сообщайте';

/**
 * Свой текст ключа шаблона `sms_outbox.template_key` (07 §5.61) или `null` — единый шаблон `SMS_OTP_TEMPLATE` (env,
 * 16 §4.3; по умолчанию `Kod: {code}. Optomstroy`). Таблица полная по типу (`Record`): новый ключ шаблона не
 * скомпилируется без решения о тексте. Тексты входа, step-up, смены номера и привязки не меняются (09 §6.7 «Другие
 * тексты» — предложение, в коде их нет).
 */
const OWN_TEXT: Readonly<Record<SmsTemplateKey, string | null>> = {
  otp_login: null,
  otp_step_up: null,
  otp_phone_change: null,
  otp_customer_link: null,
  otp_kiosk_order: KIOSK_ORDER_SMS_TEMPLATE,
};

/**
 * Текст SMS с кодом для ключа шаблона (09 §6.7): его собирают оба способа доставки — `SmsOtpProvider` (отправка
 * процессом pos-api) и `QueuedSmsOtpProvider` (текст шифруется в задании pg-boss). Код подставляется вместо `{code}`;
 * сам текст не пишется в журналы, аудит и `sms_outbox` (09 §6.9).
 */
export function textFor(templateKey: SmsTemplateKey, code: string, smsOtpTemplate: string): string {
  return (OWN_TEXT[templateKey] ?? smsOtpTemplate).replace('{code}', () => code);
}
