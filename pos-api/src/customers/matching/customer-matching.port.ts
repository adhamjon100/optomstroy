import type { DbExecutor } from '../../common/audit/db-executor.js';

/**
 * Порт `CustomerMatching` (RM-D-005; 09 §7.8 «Поиск клиента 1С по подтверждённому номеру», D-08): поиск карточек
 * `customers` по **подтверждённому** телефону E.164. Используется в двух точках — регистрация клиента
 * (`POST /registration/complete` → `CustomerLinksService.proposeForUser`) и дедупликация при `POST /customers`
 * (RM-G-001, `CUSTOMER_DUPLICATE_SUSPECTED`).
 *
 * Источники: локальная реплика `customers` / `customer_contacts` и, если порт 1С подключён, синхронный запрос
 * `OnecGateway.findCustomersByPhone` (`GET /pos/v1/customers?phone=`, таймаут `ONEC_SYNC_CHECK_TIMEOUT_MS` = 6 с —
 * ТЗ для 1С 4.9; разбор 98 п. 58). При недоступности 1С (ошибка, таймаут) — только реплика (`onec = 'unavailable'`). Номер телефона в журналы не пишется (AC-ONEC-088, 11 SEC-062).
 */
export const CUSTOMER_MATCHING = Symbol('CustomerMatching');

/**
 * Как найдено совпадение:
 * - `primary` — основной телефон карточки (`customers.primary_phone_e164` или контакт `is_primary`);
 * - `secondary` — второй контакт карточки (`phones_norm` / `customer_contacts`), типично для ЮЛ с несколькими
 *   контактами — самоподтверждение не допускается (11 SEC-130);
 * - `onec` — карточку вернула 1С, а реплика с этим телефоном её не знает (новая/устаревшая реплика).
 */
export type MatchKind = 'primary' | 'secondary' | 'onec';

export interface MatchCandidate {
  /** `customers.id` (для карточки, найденной только в 1С, — строка реплики, созданная по ответу 1С). */
  readonly customerId: string;
  readonly matchKind: MatchKind;
  readonly onecRef: string | null;
}

/** Состояние обращения к 1С: `ok` — ответ получен; `unavailable` — ошибка/таймаут; `disabled` — порт не подключён. */
export type OnecLookupState = 'ok' | 'unavailable' | 'disabled';

export interface CustomerMatchResult {
  /** Кандидаты без повторов, порядок стабильный (основной телефон первым, далее по `customers.id`). */
  readonly candidates: readonly MatchCandidate[];
  readonly onec: OnecLookupState;
}

export interface FindByPhoneOptions {
  /** `X-Request-Id` для вызова 1С. */
  readonly requestId?: string;
  /** Исполнитель для чтения реплики и записи строки реплики по ответу 1С (транзакция вызывающего). */
  readonly executor?: DbExecutor;
  /** `false` — только реплика (например, внутри длинной транзакции). По умолчанию — 1С, если порт подключён. */
  readonly useOnec?: boolean;
}

export interface CustomerMatching {
  /** Поиск по подтверждённому телефону E.164 (`+996XXXXXXXXX`); иной формат → `RangeError`. */
  findByPhone(phoneE164: string, options?: FindByPhoneOptions): Promise<CustomerMatchResult>;
}

/** Телефон КР в E.164 (07 `customers_primary_phone_e164_chk`). */
export const KG_E164 = /^\+996\d{9}$/;
