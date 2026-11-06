/**
 * Таблица соответствия ключей `app_settings` (snake_case, 07 §5.59) → полей API (camelCase) в части, публикуемой
 * в `GET /settings/public` (08 §4.18.6 «Таблица соответствия…», колонка «Публичный»; 08 §4.23.1; ядро §19.2).
 *
 * Правило проекции (ядро §19.2): каждый сегмент ключа через точку переводится в camelCase отдельно
 * (`receivables.max_age_minutes` → `receivables.maxAgeMinutes`). `apiField` — проекция ключа (как в
 * `/admin/settings`), `publicFields` — куда значение попадает в ответе `/settings/public` (для флагов функций — поле
 * `features.*`). Сверка с таблицей 08 — test/settings (скрипт сверки: 0 расхождений, RM-D-015 критерий 3).
 */

/** camelCase-проекция ключа `app_settings`: `sync_interval.stock` → `syncInterval.stock`. */
export function camelProjection(key: string): string {
  return key
    .split('.')
    .map((seg) => seg.replace(/_([a-z0-9])/g, (_m, c: string) => c.toUpperCase()))
    .join('.');
}

export interface PublicAppSettingKey {
  /** Ключ `app_settings` (07 §5.59). */
  readonly key: string;
  /** camelCase-проекция ключа (08 §4.18.6, колонка «Поле API»). */
  readonly apiField: string;
  /** Поля ответа `GET /settings/public`, в которые попадает значение (08 §4.18.6, колонка «Публичный»). */
  readonly publicFields: readonly string[];
}

/** Ключи `app_settings`, отдаваемые публично (ровно строки 08 §4.18.6 с «Публичный: да»). */
export const PUBLIC_APP_SETTING_KEYS: readonly PublicAppSettingKey[] = [
  { key: 'low_stock_threshold', apiField: 'lowStockThreshold', publicFields: ['lowStockThreshold'] },
  { key: 'returns_enabled', apiField: 'returnsEnabled', publicFields: ['features.returnsFromPos'] },
  { key: 'delivery_slots', apiField: 'deliverySlots', publicFields: ['deliverySlots'] },
  { key: 'min_app_version', apiField: 'minAppVersion', publicFields: ['minAppVersion'] },
  { key: 'recommended_app_version', apiField: 'recommendedAppVersion', publicFields: ['recommendedAppVersion'] },
  { key: 'privacy_contact', apiField: 'privacyContact', publicFields: ['privacyContact'] },
  { key: 'qr.enabled', apiField: 'qr.enabled', publicFields: ['features.qrWebhook', 'features.qrProvider'] },
  { key: 'customer_stock_display', apiField: 'customerStockDisplay', publicFields: ['customerStockDisplay'] },
  { key: 'support_contacts', apiField: 'supportContacts', publicFields: ['supportContacts'] },
  // Планшет магазина (08 §4.18.6, §4.23.1; 07 §5.59 «Ключи планшета магазина»; ADR-115): публичны только тайминги.
  { key: 'kiosk_idle_seconds', apiField: 'kioskIdleSeconds', publicFields: ['kiosk.idleSeconds'] },
  {
    key: 'kiosk_idle_warning_seconds',
    apiField: 'kioskIdleWarningSeconds',
    publicFields: ['kiosk.idleWarningSeconds'],
  },
  { key: 'kiosk_done_seconds', apiField: 'kioskDoneSeconds', publicFields: ['kiosk.doneSeconds'] },
];

export interface PublicEnvSetting {
  /** Переменная окружения (только env, не ключ `app_settings` — ядро §19.2). */
  readonly env: 'CUSTOMER_SELF_SERVICE' | 'DEBT_PAYMENTS_FROM_POS' | 'QR_PROVIDER' | 'KIOSK_MODE';
  /** Поле блока `env` в `/admin/settings` (08 §4.18.6). */
  readonly apiField: string;
  readonly publicFields: readonly string[];
}

/** Значения env, публикуемые в `features` (08 §4.18.6 строки «— (не ключ; env …)» с «Публичный: да»). */
export const PUBLIC_ENV_SETTINGS: readonly PublicEnvSetting[] = [
  { env: 'CUSTOMER_SELF_SERVICE', apiField: 'env.customerSelfService', publicFields: ['features.customerSelfService'] },
  {
    env: 'DEBT_PAYMENTS_FROM_POS',
    apiField: 'env.debtPaymentsFromPos',
    publicFields: ['features.debtPaymentsFromPos'],
  },
  { env: 'QR_PROVIDER', apiField: 'env.qrProvider', publicFields: ['features.qrProvider'] },
  // Режим «Планшет магазина» — только env, по умолчанию false; от CUSTOMER_SELF_SERVICE не зависит (ADR-115).
  { env: 'KIOSK_MODE', apiField: 'env.kioskMode', publicFields: ['features.storeTablet'] },
];

/** Поля верхнего уровня ответа (08 §4.23.1, API-157: «ровно перечисленные поля»). */
export const PUBLIC_SETTINGS_TOP_LEVEL = [
  'deliverySlots',
  'supportContacts',
  'privacyContact',
  'lowStockThreshold',
  'minAppVersion',
  'recommendedAppVersion',
  'customerStockDisplay',
  'kiosk',
  'features',
] as const;

export const PUBLIC_SETTINGS_FEATURES = [
  'customerSelfService',
  'returnsFromPos',
  'qrProvider',
  'qrWebhook',
  'debtPaymentsFromPos',
  'storeTablet',
] as const;

/** Поля объекта `kiosk` ответа (08 §4.23.1; общие для всех планшетов настройки автосброса, Р-09 (а)). */
export const PUBLIC_SETTINGS_KIOSK = ['idleSeconds', 'idleWarningSeconds', 'doneSeconds'] as const;

/** Целочисленный ключ планшета магазина: значение по умолчанию в коде и допустимые границы (08 §4.18.6). */
export interface KioskIntegerSetting {
  readonly default: number;
  readonly min: number;
  readonly max: number;
}

/**
 * Ключи планшета магазина (07 §5.59 «Ключи планшета магазина»; 08 §4.18.6; P-002 §13; ADR-115): значения по
 * умолчанию — **в коде** (seed `seeds/0001` не меняется, ключ создаёт первая запись из SCR-46), границы — 08 §4.18.6
 * [НЕ ПОДТВЕРЖДЕНО — предложение 08]. Значения общие для всех планшетов (Р-09 (а)); `kiosk_working_hours` — строка,
 * пусто — алерт «планшет не на связи» выключен (Q-341).
 */
export const KIOSK_INTEGER_SETTINGS = {
  kiosk_idle_seconds: { default: 120, min: 30, max: 1800 },
  kiosk_idle_warning_seconds: { default: 15, min: 5, max: 120 },
  kiosk_done_seconds: { default: 60, min: 10, max: 600 },
  kiosk_otp_per_hour: { default: 30, min: 1, max: 1000 },
  kiosk_otp_per_day: { default: 200, min: 1, max: 10_000 },
} as const satisfies Readonly<Record<string, KioskIntegerSetting>>;

export type KioskIntegerSettingKey = keyof typeof KIOSK_INTEGER_SETTINGS;

/** `kiosk_working_hours` по умолчанию — пусто (алерт выключен; 07 §5.59). */
export const KIOSK_WORKING_HOURS_DEFAULT = '';

/** Значение ключа планшета из `app_settings`: целое в границах 08 §4.18.6, иначе значение по умолчанию (не 500). */
export function kioskIntegerSetting(key: KioskIntegerSettingKey, raw: unknown): number {
  const s = KIOSK_INTEGER_SETTINGS[key];
  return typeof raw === 'number' && Number.isSafeInteger(raw) && raw >= s.min && raw <= s.max ? raw : s.default;
}

/** Дни недели формата `kiosk_working_hours` (07 §5.59), понедельник — 0. */
export const KIOSK_WEEKDAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'] as const;

/** Интервал часов работы магазина: дни недели (0 — понедельник) и время, минуты от полуночи по Asia/Bishkek. */
export interface KioskWorkingInterval {
  readonly days: readonly number[];
  readonly fromMinutes: number;
  readonly toMinutes: number;
}

const WORKING_PART = /^([a-z]{3})(?:-([a-z]{3}))? ([01]\d|2[0-3]):([0-5]\d)-([01]\d|2[0-3]):([0-5]\d)$/;

/**
 * Разбор `kiosk_working_hours` (07 §5.59): диапазоны через `;`, каждый — `день[-день] ЧЧ:ММ-ЧЧ:ММ`, дни
 * `mon tue wed thu fri sat sun` (диапазон дней — по порядку недели), начало раньше конца, например
 * `mon-sat 08:00-20:00;sun 09:00-15:00`. Пустая строка — `[]` (алерт «планшет не на связи» выключен); иная строка —
 * `null` (`VALIDATION_FAILED`, rule `format`).
 */
export function parseKioskWorkingHours(value: string): KioskWorkingInterval[] | null {
  const text = value.trim();
  if (text === '') return [];
  const out: KioskWorkingInterval[] = [];
  for (const part of text.split(';').map((p) => p.trim())) {
    const m = WORKING_PART.exec(part);
    if (!m) return null;
    const from = (KIOSK_WEEKDAYS as readonly string[]).indexOf(m[1] ?? '');
    const to = m[2] === undefined ? from : (KIOSK_WEEKDAYS as readonly string[]).indexOf(m[2]);
    if (from < 0 || to < 0 || to < from) return null;
    const fromMinutes = Number(m[3]) * 60 + Number(m[4]);
    const toMinutes = Number(m[5]) * 60 + Number(m[6]);
    if (fromMinutes >= toMinutes) return null;
    out.push({ days: KIOSK_WEEKDAYS.map((_d, i) => i).filter((i) => i >= from && i <= to), fromMinutes, toMinutes });
  }
  return out;
}
