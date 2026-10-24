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
];

export interface PublicEnvSetting {
  /** Переменная окружения (только env, не ключ `app_settings` — ядро §19.2). */
  readonly env: 'CUSTOMER_SELF_SERVICE' | 'DEBT_PAYMENTS_FROM_POS' | 'QR_PROVIDER';
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
  'features',
] as const;

export const PUBLIC_SETTINGS_FEATURES = [
  'customerSelfService',
  'returnsFromPos',
  'qrProvider',
  'qrWebhook',
  'debtPaymentsFromPos',
] as const;
