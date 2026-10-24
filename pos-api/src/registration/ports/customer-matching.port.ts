import type { CustomerMatchNextStep, CustomerMatchView } from '../../profile/customer-link.reader.js';

/**
 * Порт автоматической привязки клиента к карточке 1С по подтверждённому телефону (09 §7.8–§7.9, REG-039;
 * 08 §4.2.1; ядро §22.12). Реализация — `CustomerLinksService.proposeForUser` модуля `customers` (RM-D-005,
 * `src/customers/links/**`; сигнатура совпадает): поиск по реплике и, если 1С доступна, синхронный HS-запрос
 * (таймаут 5 с), запись `customer_links` (`proposed` / `conflict` + уведомление админу), `nextStep` по 11 SEC-130.
 *
 * Подключение (владелец интеграции customers/app.module): провайдер `{ provide: CUSTOMER_MATCHING_PORT,
 * useExisting: CustomerLinksService }` в **глобальном** модуле (registration не импортирует `customers`, граф 06 §7.4
 * без новых рёбер). Пока порт не зарегистрирован, `POST /registration/complete` отвечает `customerMatch {status: none}`
 * и пишет предупреждение `registration.customer_match_unavailable` (поиск не выполняется).
 */
export const CUSTOMER_MATCHING_PORT = Symbol('CUSTOMER_MATCHING_PORT');

/** contracts/openapi `RegistrationCustomerMatchSummary` (поле `customerMatch` ответа 201). */
export interface CustomerMatchSummary {
  readonly status: 'none' | 'proposed' | 'confirmed' | 'conflict';
  readonly linkId: string | null;
  readonly nextStep: CustomerMatchNextStep;
}

export interface RegistrationMatchInput {
  /** Новый пользователь `kind=customer`. */
  readonly userId: string;
  /** Телефон, подтверждённый OTP (из `otp_challenges`, не из формы). */
  readonly phoneE164: string;
  readonly requestId?: string;
}

export interface CustomerMatchingPort {
  /**
   * Вызывается **после** фиксации регистрации (вне её транзакции: 1С может отвечать до 5 с). 0 совпадений → `none`
   * (карточка 1С не создаётся, SRC-B-144); 1 → `proposed`; ≥ 2 → `conflict`. Исключение порта регистрацию не
   * отменяет: registration отвечает `none` и пишет предупреждение `registration.customer_match_failed`.
   */
  proposeForUser(input: RegistrationMatchInput): Promise<CustomerMatchSummary>;
}

export const NO_MATCH: CustomerMatchSummary = Object.freeze({ status: 'none', linkId: null, nextStep: 'none' });

export function summaryOf(view: CustomerMatchView): CustomerMatchSummary {
  if (view.status === 'rejected' || view.status === 'none') return NO_MATCH;
  return { status: view.status, linkId: view.linkId, nextStep: view.nextStep };
}
