import { parsePlatformVersions, formatVersionHeader } from '../../common/app-version/version-policy.js';
import { SYNC_ENTITY_VALUES } from '../../common/enums.js';
import { camelProjection } from '../../settings/public-settings.map.js';

/**
 * Таблица соответствия ключей `app_settings` (snake_case, 07 §5.59) → полей `/admin/settings` (08 §4.18.6;
 * contracts/openapi `AdminSettingsValues`; ядро §19.2). Все строки таблицы 08 — с отметкой «запись».
 *
 * Имя поля — camelCase-проекция ключа по сегментам (`receivables.max_age_minutes` → `receivables.maxAgeMinutes`);
 * у `sync_interval.<entity>` второй сегмент — значение enum `sync_entity` (07 §6.1) и не переводится
 * (`syncInterval.sales_history`, как в контракте). Сверка с контрактом — test/admin/admin-settings.admin-spec.ts.
 */

export type AppSettingValueType = 'boolean' | 'integer' | 'string' | 'json' | 'money';

export type SettingRule =
  | { readonly kind: 'integer'; readonly min: number; readonly max?: number }
  | { readonly kind: 'boolean' }
  | { readonly kind: 'enum'; readonly values: readonly string[] }
  | { readonly kind: 'money' }
  | { readonly kind: 'versions'; readonly nullable: boolean }
  | { readonly kind: 'text'; readonly nullable: boolean; readonly maxLength: number }
  | { readonly kind: 'slots' }
  | { readonly kind: 'contacts' }
  | { readonly kind: 'strings'; readonly maxItems: number; readonly maxLength: number }
  | { readonly kind: 'object' };

export interface AdminSettingKey {
  /** Ключ `app_settings` (07 §5.59). */
  readonly key: string;
  /** Поле `AdminSettingsValues` (08 §4.18.6, колонка «Поле API»). */
  readonly apiField: string;
  /** `app_settings.value_type` для новой строки (07 §5.59 CHECK). */
  readonly valueType: AppSettingValueType;
  readonly rule: SettingRule;
  /** `app_settings.description_ru` для новой строки (ключи вне seed создаются при первой записи). */
  readonly descriptionRu: string;
}

/** Поле API ключа: проекция по сегментам; сущность `sync_interval.<entity>` — без перевода (enum). */
export function adminApiField(key: string): string {
  if (key.startsWith('sync_interval.')) return `syncInterval.${key.slice('sync_interval.'.length)}`;
  return camelProjection(key);
}

const int = (min: number, max?: number): SettingRule => ({
  kind: 'integer',
  min,
  ...(max !== undefined ? { max } : {}),
});

const ROWS: readonly Omit<AdminSettingKey, 'apiField'>[] = [
  { key: 'low_stock_threshold', valueType: 'integer', rule: int(0), descriptionRu: 'Порог «мало», базовых единиц' },
  { key: 'cart_stale_minutes', valueType: 'integer', rule: int(0), descriptionRu: 'Возраст снимка корзины, мин' },
  {
    key: 'parked_cart_ttl_days',
    valueType: 'integer',
    rule: int(1, 30),
    descriptionRu: 'Срок хранения отложенной корзины, дней',
  },
  { key: 'overpay_allowed', valueType: 'boolean', rule: { kind: 'boolean' }, descriptionRu: 'Допуск переплаты долга' },
  {
    key: 'return_approval_threshold',
    valueType: 'money',
    rule: { kind: 'money' },
    descriptionRu: 'Порог суммы заявки на возврат для подтверждения',
  },
  {
    key: 'returns_enabled',
    valueType: 'boolean',
    rule: { kind: 'boolean' },
    descriptionRu: 'Заявки на возврат из приложения включены',
  },
  {
    key: 'cash_rounding',
    valueType: 'string',
    rule: { kind: 'enum', values: ['none', 'to_som'] },
    descriptionRu: 'Округление наличных: none | to_som',
  },
  { key: 'delivery_slots', valueType: 'json', rule: { kind: 'slots' }, descriptionRu: 'Интервалы доставки' },
  {
    key: 'receivables.max_age_minutes',
    valueType: 'integer',
    rule: int(5, 1440),
    descriptionRu: 'Максимальный возраст снимка долга, мин',
  },
  {
    key: 'min_app_version',
    valueType: 'string',
    rule: { kind: 'versions', nullable: false },
    descriptionRu: 'Минимальная версия приложения по платформам',
  },
  {
    key: 'recommended_app_version',
    valueType: 'string',
    rule: { kind: 'versions', nullable: true },
    descriptionRu: 'Рекомендуемая версия приложения по платформам',
  },
  {
    key: 'secure_screens',
    valueType: 'json',
    rule: { kind: 'strings', maxItems: 500, maxLength: 50 },
    descriptionRu: 'Экраны с запретом снимков',
  },
  {
    key: 'privacy_contact',
    valueType: 'string',
    rule: { kind: 'text', nullable: true, maxLength: 300 },
    descriptionRu: 'Контакт по вопросам персональных данных',
  },
  ...SYNC_ENTITY_VALUES.map((e) => ({
    key: `sync_interval.${e}`,
    valueType: 'integer' as const,
    rule: int(60, 86_400),
    descriptionRu: `Интервал синхронизации «${e}», сек`,
  })),
  { key: 'otp.ttl_seconds', valueType: 'integer', rule: int(180, 600), descriptionRu: 'Срок действия OTP, сек' },
  { key: 'otp.max_attempts', valueType: 'integer', rule: int(1), descriptionRu: 'Попыток ввода OTP' },
  {
    key: 'session.staff_refresh_days',
    valueType: 'integer',
    rule: int(1),
    descriptionRu: 'Срок refresh-сессии сотрудника, дней',
  },
  { key: 'consent_texts', valueType: 'json', rule: { kind: 'object' }, descriptionRu: 'Версии текстов согласий' },
  { key: 'category_icons', valueType: 'json', rule: { kind: 'object' }, descriptionRu: 'Иконки категорий' },
  { key: 'attribute_codes', valueType: 'json', rule: { kind: 'object' }, descriptionRu: 'Коды атрибутов' },
  {
    key: 'print.default_paper',
    valueType: 'string',
    rule: { kind: 'enum', values: ['a4', 'thermal80'] },
    descriptionRu: 'Формат печати по умолчанию',
  },
  { key: 'qr.enabled', valueType: 'boolean', rule: { kind: 'boolean' }, descriptionRu: 'QR-оплата включена' },
  {
    key: 'customer_stock_display',
    valueType: 'string',
    rule: { kind: 'enum', values: ['status', 'quantity'] },
    descriptionRu: 'Что видит клиент о наличии: status | quantity',
  },
  { key: 'support_contacts', valueType: 'json', rule: { kind: 'contacts' }, descriptionRu: 'Контакты поддержки' },
];

export const ADMIN_SETTING_KEYS: readonly AdminSettingKey[] = ROWS.map((r) => ({
  ...r,
  apiField: adminApiField(r.key),
}));

export const ADMIN_SETTING_BY_FIELD: ReadonlyMap<string, AdminSettingKey> = new Map(
  ADMIN_SETTING_KEYS.map((k) => [k.apiField, k]),
);

/**
 * Поля блока `env` (`AdminSettingsEnv`) — только чтение (ядро §19.2; изменяются только на сервере). Попытка записать
 * их в `settings` → 400 `read_only_setting` (AC-API-164: `customerSelfService`). `minAppVersion` и
 * `recommendedAppVersion` есть в обоих блоках: в `settings` это ключи `app_settings` (запись разрешена).
 */
export const ADMIN_SETTINGS_ENV_FIELDS = [
  'customerSelfService',
  'debtPaymentsFromPos',
  'qrProvider',
  'qrTtlMinutes',
  'qrOnecPollSeconds',
  'receivablesMaxAgeMin',
  'minAppVersion',
  'recommendedAppVersion',
  'otpTtlSeconds',
  'otpResendCooldownSeconds',
  'otpMaxVerifyAttempts',
  'otpGlobalPerMin',
  'otpLockAfterLockedCodes',
  'otpPhonePauseMinutes',
  'sessionIdleLockMinutes',
  'authBackgroundLockMinutes',
  'smsSenderName',
] as const;

export type SettingCheck =
  | { readonly ok: true; readonly value: unknown }
  | { readonly ok: false; readonly status: 400 | 422; readonly rule: string; readonly message: string };

const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/;
const MONEY = /^-?\d{1,12}\.\d{2}$/;
const CONTACT_KINDS = ['phone', 'telegram', 'email'];

const type = (message: string): SettingCheck => ({ ok: false, status: 400, rule: 'type', message });
const fail = (rule: string, message: string): SettingCheck => ({ ok: false, status: 422, rule, message });
const isPlainObject = (v: unknown): v is Record<string, unknown> =>
  v !== null && typeof v === 'object' && !Array.isArray(v);

/**
 * Проверка значения поля (08 §4.18.6 «Ошибки»): несоответствие типа схемы → 400 (rule `type`); значение вне
 * перечня / диапазона / формата → 422 (`enum`, `min`, `max`, `pattern`, `maxLength`, `maxItems`, `format`).
 * Успех — значение для `app_settings.value` (нормализованное: версии — канонической строкой, контакты — с trim).
 */
export function checkSettingValue(rule: SettingRule, value: unknown): SettingCheck {
  switch (rule.kind) {
    case 'integer': {
      if (typeof value !== 'number' || !Number.isSafeInteger(value)) return type('Ожидается целое число');
      if (value < rule.min) return fail('min', `Не меньше ${rule.min}`);
      if (rule.max !== undefined && value > rule.max) return fail('max', `Не больше ${rule.max}`);
      return { ok: true, value };
    }
    case 'boolean':
      return typeof value === 'boolean' ? { ok: true, value } : type('Ожидается true или false');
    case 'enum':
      if (typeof value !== 'string') return type('Ожидается строка');
      return rule.values.includes(value) ? { ok: true, value } : fail('enum', `Допустимо: ${rule.values.join(', ')}`);
    case 'money': {
      if (!isPlainObject(value)) return type('Ожидается объект Money {amount, currency}');
      const extra = Object.keys(value).filter((k) => k !== 'amount' && k !== 'currency');
      if (extra.length > 0) return { ok: false, status: 400, rule: 'additional_properties', message: extra.join(', ') };
      if (typeof value.amount !== 'string' || typeof value.currency !== 'string')
        return type('amount и currency — строки');
      if (!MONEY.test(value.amount)) return fail('money_format', 'Сумма строкой с двумя знаками, например 10000.00');
      if (value.currency !== 'KGS') return fail('enum', 'Валюта: KGS');
      if (value.amount.startsWith('-')) return fail('min', 'Сумма не может быть отрицательной');
      return { ok: true, value: { amount: value.amount, currency: 'KGS' } };
    }
    case 'versions': {
      if (value === null) return rule.nullable ? { ok: true, value: null } : type('Значение обязательно');
      if (typeof value !== 'string') return type('Ожидается строка platform=semver,…');
      try {
        const parsed = parsePlatformVersions(value);
        const canonical = formatVersionHeader(parsed, undefined);
        if (canonical === undefined) return fail('format', 'Укажите хотя бы одну платформу');
        return { ok: true, value: canonical };
      } catch {
        return fail('format', 'Формат: android=1.2.0,windows=1.2.0');
      }
    }
    case 'text': {
      if (value === null) return rule.nullable ? { ok: true, value: null } : type('Значение обязательно');
      if (typeof value !== 'string') return type('Ожидается строка');
      const t = value.trim();
      if (t.length > rule.maxLength) return fail('maxLength', `Не длиннее ${rule.maxLength} символов`);
      return { ok: true, value: t === '' && rule.nullable ? null : t };
    }
    case 'slots': {
      if (!Array.isArray(value)) return type('Ожидается массив интервалов');
      if (value.length > 500) return fail('maxItems', 'Не больше 500 интервалов');
      const out: { from: string; to: string }[] = [];
      for (const s of value) {
        if (!isPlainObject(s) || typeof s.from !== 'string' || typeof s.to !== 'string') {
          return type('Интервал — объект {from, to}');
        }
        if (!HHMM.test(s.from) || !HHMM.test(s.to)) return fail('pattern', 'Время в формате ЧЧ:ММ');
        out.push({ from: s.from, to: s.to });
      }
      return { ok: true, value: out };
    }
    case 'contacts': {
      if (!Array.isArray(value)) return type('Ожидается массив контактов');
      if (value.length > 500) return fail('maxItems', 'Не больше 500 контактов');
      const out: { kind: string; value: string; label?: string }[] = [];
      for (const c of value) {
        if (!isPlainObject(c) || typeof c.kind !== 'string' || typeof c.value !== 'string') {
          return type('Контакт — объект {kind, value, label?}');
        }
        if (c.label !== undefined && typeof c.label !== 'string') return type('label — строка');
        if (!CONTACT_KINDS.includes(c.kind)) return fail('enum', `kind: ${CONTACT_KINDS.join(', ')}`);
        const v = c.value.trim();
        if (v === '' || v.length > 200) return fail('maxLength', 'value: 1…200 символов');
        const label = typeof c.label === 'string' ? c.label.trim() : '';
        if (label.length > 100) return fail('maxLength', 'label: не длиннее 100 символов');
        out.push({ kind: c.kind, value: v, ...(label !== '' ? { label } : {}) });
      }
      return { ok: true, value: out };
    }
    case 'strings': {
      if (!Array.isArray(value) || value.some((s) => typeof s !== 'string')) return type('Ожидается массив строк');
      if (value.length > rule.maxItems) return fail('maxItems', `Не больше ${rule.maxItems} элементов`);
      if ((value as string[]).some((s) => s.length > rule.maxLength)) {
        return fail('maxLength', `Элемент не длиннее ${rule.maxLength} символов`);
      }
      return { ok: true, value: [...(value as string[])] };
    }
    case 'object':
      return isPlainObject(value) ? { ok: true, value } : type('Ожидается объект');
  }
}
