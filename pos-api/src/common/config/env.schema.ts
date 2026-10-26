import { z } from 'zod';
import { parsePlatformVersions, VersionListFormatError } from '../app-version/version-policy.js';

/**
 * Схема переменных окружения pos-api / pos-worker (RM-C-005, RM-C-009).
 * Имена и значения по умолчанию — канонический перечень 16_DEPLOYMENT_PLAN §4.3 (пример `.env.example`);
 * имён вне 16 §4.3 в коде нет (RM-C-009 п. 3). Секреты задаются только через `X_FILE` (см. env-file.loader.ts):
 * ключ схемы — имя без суффикса (`DATABASE_URL` ← `DATABASE_URL_FILE`).
 *
 * Не входят в схему (не читаются процессом api/worker): уровень compose/образов/хоста — `API_TAG`, `BACKUP_TAG`,
 * `POSTGRES_USER`, `POSTGRES_DB`, `POSTGRES_PASSWORD_FILE`, `BACKUP_*`, `RCLONE_CONFIG_FILE`, `PGPASSWORD_FILE`,
 * `WG_*`; R2 — `FACE_SCAN_*` (16 §4.3 «Граница R1 / R2»).
 *
 * Обязательность на этапе C: `DATABASE_URL`, `MIN_APP_VERSION`, а при `APP_ENV=staging|prod` — `PUBLIC_BASE_URL`.
 * Секреты и параметры, которые начнут читать модули этапов D–F (JWT, OTP, SMSPro, 1С), объявлены
 * необязательными; модуль-потребитель проверяет их наличие при своей инициализации.
 */

const bool = (def: boolean) => z.stringbool().default(def);
const int = (def: number, min = 0, max = Number.MAX_SAFE_INTEGER) =>
  z.coerce.number().int().min(min).max(max).default(def);
const str = (def: string) => z.string().default(def);
const optStr = () => z.string().optional();
/** Секрет: значение приходит из файла `<ИМЯ>_FILE`. */
const secret = () => z.string().min(1).optional();
const cron = (def: string) =>
  z
    .string()
    .regex(/^\S+(\s+\S+){4,5}$/, 'ожидается cron-выражение из 5–6 полей')
    .default(def);

const platformVersions = z.string().superRefine((v, ctx) => {
  try {
    parsePlatformVersions(v);
  } catch (e) {
    ctx.addIssue({ code: 'custom', message: e instanceof VersionListFormatError ? e.message : 'неверный формат' });
  }
});

export const APP_ENVS = ['dev', 'staging', 'prod'] as const;
export const LOG_LEVELS = ['fatal', 'error', 'warn', 'info', 'debug', 'trace', 'silent'] as const;

export const envShape = {
  // --- Общие и платформа ---
  APP_ENV: z.enum(APP_ENVS).default('dev'),
  PUBLIC_BASE_URL: z.url().optional(),
  LOG_LEVEL: z.enum(LOG_LEVELS).default('info'),
  TZ: optStr(),
  WORKERS_ENABLED: bool(false),
  APP_READ_ONLY: bool(false),
  CORS_ALLOWED_ORIGINS: optStr(),
  OPENAPI_PUBLIC: bool(false),
  MIN_APP_VERSION: platformVersions,
  RECOMMENDED_APP_VERSION: platformVersions.optional(),
  CUSTOMER_SELF_SERVICE: bool(true),
  RECEIVABLES_MAX_AGE_MIN: int(60, 1),

  // --- База данных ---
  DATABASE_URL: z.string().regex(/^postgres(ql)?:\/\//, 'ожидается строка подключения postgres://…'),
  DB_MIGRATOR_PASSWORD: secret(),

  // --- Аутентификация, OTP, PIN ---
  JWT_PRIVATE_KEY: secret(),
  JWT_PUBLIC_KEY: secret(),
  JWT_KEY_ID: optStr(),
  OTP_HMAC_SECRET: secret(),
  OTP_HMAC_SECRET_VERSION: int(1, 1),
  PIN_PEPPER: secret(),
  PIN_PEPPER_VERSION: int(1, 1),
  SESSION_IDLE_LOCK_MINUTES: int(30, 1),
  AUTH_OTP_TEST_MODE: bool(false),
  AUTH_OTP_TEST_PHONES: optStr(),
  AUTH_OTP_TEST_CODE: optStr(),
  OTP_GLOBAL_PER_MIN: int(60, 1),
  OTP_PROVIDER: z.enum(['internal', 'smspro']).default('internal'),
  OTP_TTL_SECONDS: int(300, 30),
  OTP_RESEND_COOLDOWN_SECONDS: int(60, 1),
  OTP_MAX_VERIFY_ATTEMPTS: int(5, 1),
  OTP_MAX_SENDS_PER_PHONE_15M: int(3, 1),
  OTP_MAX_SENDS_PER_PHONE_24H: int(10, 1),
  OTP_MAX_SENDS_PER_IP_10M: int(20, 1),
  OTP_MAX_SENDS_PER_IP_24H: int(100, 1),
  OTP_MAX_SENDS_PER_DEVICE_10M: int(5, 1),
  OTP_MAX_SENDS_PER_DEVICE_24H: int(20, 1),
  OTP_LOCK_AFTER_LOCKED_CODES: int(3, 1),
  OTP_PHONE_PAUSE_MINUTES: int(30, 1),
  OTP_RESEND_ON_DLR_FAILED: bool(true),
  AUTH_ACCESS_TTL_SECONDS: int(900, 60),
  AUTH_REFRESH_TTL_STAFF_DAYS: int(7, 1),
  AUTH_REFRESH_TTL_CUSTOMER_DAYS: int(30, 1),
  AUTH_REFRESH_IDLE_STAFF_HOURS: int(24, 1),
  AUTH_REFRESH_IDLE_CUSTOMER_DAYS: int(14, 1),
  AUTH_REFRESH_GRACE_SECONDS: int(30, 0),
  AUTH_BACKGROUND_LOCK_MINUTES: int(5, 0),
  AUTH_BIO_AUTO_PROMPT: bool(true),
  AUTH_NOTIFY_OLD_PHONE: bool(false),
  PIN_MIN_LENGTH_STAFF: int(6, 4),
  PIN_MAX_ATTEMPTS: int(5, 1),

  // --- SMSPro ---
  SMS_PROVIDER: z.enum(['smspro', 'fake']).optional(),
  SMSPRO_BASE_URL: z.url().default('https://smspro.nikita.kg/api'),
  SMSPRO_LOGIN: secret(),
  SMSPRO_PASSWORD: secret(),
  SMSPRO_SENDER: optStr(),
  SMSPRO_TEST_FLAG: bool(false),
  SMS_STAGING_ALLOWED_PHONES: optStr(),
  SMSPRO_TIMEOUT_MS: int(15000, 1000),
  SMSPRO_RETRY_MAX: int(3, 0),
  SMSPRO_DLR_MODE: z.enum(['poll', 'push']).default('poll'),
  SMSPRO_DLR_ALLOWED_IPS: optStr(),
  SMSPRO_BALANCE_POLL_MINUTES: int(15, 1),
  SMSPRO_BALANCE_ALERT_SOM: int(300, 0),
  SMSPRO_CB_OPEN_MINUTES: int(5, 1),
  SMSPRO_DEF_PRECHECK: bool(false),
  // 09 SMS-025, 12 T-SMS-017: шаблон без `{code}` — ошибка конфигурации (иначе SMS ушла бы без кода).
  SMS_OTP_TEMPLATE: z
    .string()
    .includes('{code}', { message: 'шаблон должен содержать {code}' })
    .default('Kod: {code}. Optomstroy'),
  SMSPRO_OTP_API_KEY: secret(),

  // --- Регистрация, приглашения ---
  INVITATION_TTL_DAYS: int(30, 1),
  INVITE_SMS: bool(false),
  REGISTRATION_SECOND_OTP: bool(false),

  // --- 1С ---
  ONEC_MODE: z.enum(['extension', 'odata_only', 'fixtures']).default('fixtures'),
  ONEC_BASE_URL: z.url().optional(),
  ONEC_ODATA_PATH: str('odata/standard.odata'),
  ONEC_HS_PATH: optStr(),
  ONEC_USER: secret(),
  ONEC_PASSWORD: secret(),
  ONEC_HS_USER: secret(),
  ONEC_HS_PASSWORD: secret(),
  ONEC_HS_TOKEN: secret(),
  ONEC_CA_CERT: secret(),
  ONEC_TIMEOUT_MS: int(30000, 1000),
  ONEC_SYNC_CHECK_TIMEOUT_MS: int(6000, 500),
  ONEC_SYNC_PAGE_SIZE: int(1000, 200, 2000),
  ONEC_MAX_CONCURRENCY: int(2, 1),
  ONEC_ODATA_WRITE_ENABLED: bool(false),
  ONEC_ODATA_WRITE_USER: secret(),
  ONEC_ODATA_WRITE_PASSWORD: secret(),
  ONEC_INBOUND_ENABLED: bool(false),
  ONEC_INBOUND_ALLOWED_IPS: optStr(),
  MANUAL_ORDER_SLA_MIN: int(60, 1),

  // --- Синхронизация ---
  SYNC_STOCK_CRON: cron('*/10 * * * *'),
  SYNC_PRICES_CRON: cron('*/15 * * * *'),
  SYNC_ORDER_STATUS_CRON: cron('*/5 * * * *'),
  SYNC_MASTER_CRON: cron('*/30 * * * *'),
  SYNC_IMAGES_CRON: cron('30 2 * * *'),
  SYNC_RECONCILE_CRON: cron('0 4 * * 0'),
  SYNC_NIGHT_WINDOW: z
    .string()
    .regex(/^([01]\d|2[0-3]):[0-5]\d-([01]\d|2[0-3]):[0-5]\d$/, 'ожидается HH:MM-HH:MM')
    .default('01:00-06:00'),
  SALES_HISTORY_MONTHS: int(12, 1),
  SYNC_COUNT_CHECK_CRON: cron('30 3 * * *'),
  SYNC_ALERT_UNREACHABLE_MIN: int(10, 1),
  OUTBOX_MAX_ATTEMPTS: int(20, 1),
  OUTBOX_MAX_AGE_HOURS: int(24, 1),

  // --- Платежи, долги, возвраты ---
  DEBT_PAYMENTS_FROM_POS: bool(false),
  RETURNS_FROM_POS_ENABLED: bool(false),
  QR_PROVIDER: z.enum(['onec', 'none', 'bakai']).default('onec'),
  QR_ONEC_POLL_SECONDS: int(5, 1),
  QR_TTL_MINUTES: int(15, 1),
  QR_WEBHOOK_ENABLED: bool(false),
  QR_WEBHOOK_SECRET: secret(),
  QR_WEBHOOK_PUBLIC_KEY: secret(),
  QR_WEBHOOK_ALLOWED_IPS: optStr(),

  // --- Фото ---
  MEDIA_DIR: str('/data/media'),
  MEDIA_MAX_SOURCE_PX: int(1600, 100),

  // --- Мониторинг ---
  HEALTHCHECKS_PING_URL: secret(),
} as const;

/** Имена-ключи схемы (без суффикса `_FILE`) — для загрузчика *_FILE и проверки «имён вне 16 §4.3 нет». */
export const ENV_KEYS = Object.keys(envShape) as readonly (keyof typeof envShape)[];

/** Ключи, которые 16 §4.3 задаёт только как секрет-файл (`<ИМЯ>_FILE`). */
export const SECRET_ENV_KEYS = [
  'DATABASE_URL',
  'DB_MIGRATOR_PASSWORD',
  'JWT_PRIVATE_KEY',
  'JWT_PUBLIC_KEY',
  'OTP_HMAC_SECRET',
  'PIN_PEPPER',
  'SMSPRO_LOGIN',
  'SMSPRO_PASSWORD',
  'SMSPRO_OTP_API_KEY',
  'ONEC_USER',
  'ONEC_PASSWORD',
  'ONEC_HS_USER',
  'ONEC_HS_PASSWORD',
  'ONEC_HS_TOKEN',
  'ONEC_CA_CERT',
  'ONEC_ODATA_WRITE_USER',
  'ONEC_ODATA_WRITE_PASSWORD',
  'QR_WEBHOOK_SECRET',
  'QR_WEBHOOK_PUBLIC_KEY',
  'HEALTHCHECKS_PING_URL',
] as const satisfies readonly (keyof typeof envShape)[];

/**
 * Межпеременные правила отказа в старте (16 §4.3, OPS-027, 11 SEC-056, SEC-061, SEC-135; 05 ONEC-060).
 */
export const envSchema = z.object(envShape).superRefine((env, ctx) => {
  const fail = (path: string, message: string) => ctx.addIssue({ code: 'custom', path: [path], message });
  const prod = env.APP_ENV === 'prod';
  if (env.APP_ENV !== 'dev' && env.PUBLIC_BASE_URL === undefined) {
    fail('PUBLIC_BASE_URL', `обязательна при APP_ENV=${env.APP_ENV}`);
  }
  if (env.APP_ENV !== 'dev' && (env.AUTH_OTP_TEST_PHONES ?? '').split(',').some((p) => p.trim() === '*'))
    fail('AUTH_OTP_TEST_PHONES', 'значение «*» (любой номер) разрешено только при APP_ENV=dev (ADR-109)');
  if (prod) {
    if (env.ONEC_MODE === 'fixtures') fail('ONEC_MODE', 'fixtures запрещён при APP_ENV=prod (OPS-027)');
    if (env.SMS_PROVIDER === 'fake') fail('SMS_PROVIDER', 'fake запрещён при APP_ENV=prod (OPS-027)');
    if (env.AUTH_OTP_TEST_MODE) fail('AUTH_OTP_TEST_MODE', 'true запрещено при APP_ENV=prod (OPS-027)');
    if (env.AUTH_OTP_TEST_PHONES !== undefined)
      fail('AUTH_OTP_TEST_PHONES', 'должна быть пустой при APP_ENV=prod (OPS-027)');
    if (env.AUTH_OTP_TEST_CODE !== undefined)
      fail('AUTH_OTP_TEST_CODE', 'должна быть пустой при APP_ENV=prod (OPS-027)');
    if (env.SMSPRO_TEST_FLAG) fail('SMSPRO_TEST_FLAG', 'true запрещено при APP_ENV=prod');
    if (env.LOG_LEVEL === 'debug' || env.LOG_LEVEL === 'trace')
      fail('LOG_LEVEL', 'debug/trace запрещены при APP_ENV=prod (SEC-061)');
    if (env.CORS_ALLOWED_ORIGINS?.split(',').some((o) => o.trim() === '*')) {
      fail('CORS_ALLOWED_ORIGINS', '«*» запрещено при APP_ENV=prod (SEC-056)');
    }
    if (env.OPENAPI_PUBLIC) fail('OPENAPI_PUBLIC', 'true запрещено при APP_ENV=prod (16 §4.3: только тестовый контур)');
    if (env.SMSPRO_BASE_URL.startsWith('http://'))
      fail('SMSPRO_BASE_URL', 'http:// запрещён при APP_ENV=prod (SEC-056)');
  }
  // Временная запись через OData (05 ONEC-028; 16 §4.3): только при ONEC_MODE=odata_only и только с отдельной
  // учётной записью pos_odata_write из секретов; иначе — отказ в старте (ревью C-MJ-02).
  if (env.ONEC_ODATA_WRITE_ENABLED) {
    if (env.ONEC_MODE !== 'odata_only') {
      fail('ONEC_ODATA_WRITE_ENABLED', 'true допустимо только при ONEC_MODE=odata_only (05 ONEC-028, 16 §4.3)');
    }
    if (env.ONEC_ODATA_WRITE_USER === undefined)
      fail('ONEC_ODATA_WRITE_USER', 'обязательна (ONEC_ODATA_WRITE_USER_FILE) при ONEC_ODATA_WRITE_ENABLED=true');
    if (env.ONEC_ODATA_WRITE_PASSWORD === undefined)
      fail(
        'ONEC_ODATA_WRITE_PASSWORD',
        'обязательна (ONEC_ODATA_WRITE_PASSWORD_FILE) при ONEC_ODATA_WRITE_ENABLED=true',
      );
  }
  if (env.SMS_STAGING_ALLOWED_PHONES !== undefined && env.APP_ENV !== 'staging') {
    fail('SMS_STAGING_ALLOWED_PHONES', 'допускается только при APP_ENV=staging (09 §5.8)');
  }
  if (env.QR_WEBHOOK_ENABLED && env.QR_PROVIDER !== 'bakai') {
    fail('QR_WEBHOOK_ENABLED', 'true допустимо только при QR_PROVIDER=bakai (R2; 11 SEC-135)');
  }
  if (env.QR_WEBHOOK_ENABLED && env.QR_WEBHOOK_ALLOWED_IPS === undefined) {
    fail('QR_WEBHOOK_ALLOWED_IPS', 'обязательна при QR_WEBHOOK_ENABLED=true');
  }
  if (env.QR_PROVIDER === 'onec' && env.ONEC_MODE === 'odata_only') {
    fail('QR_PROVIDER', 'onec требует ONEC_MODE=extension (или fixtures на тестовом контуре)');
  }
  if (env.QR_PROVIDER === 'onec' && env.ONEC_INBOUND_ENABLED) {
    fail('QR_PROVIDER', 'onec несовместим с ONEC_INBOUND_ENABLED=true (вариант C-2, 05 ONEC-065)');
  }
  if (env.ONEC_INBOUND_ENABLED && env.ONEC_INBOUND_ALLOWED_IPS === undefined) {
    fail('ONEC_INBOUND_ALLOWED_IPS', 'обязательна при ONEC_INBOUND_ENABLED=true (05 ONEC-060)');
  }
  if (env.ONEC_INBOUND_ENABLED && env.ONEC_MODE !== 'extension') {
    fail('ONEC_INBOUND_ENABLED', 'true допустимо только при ONEC_MODE=extension');
  }
  if (env.SMSPRO_DLR_MODE === 'push' && env.SMSPRO_DLR_ALLOWED_IPS === undefined) {
    fail('SMSPRO_DLR_ALLOWED_IPS', 'обязательна при SMSPRO_DLR_MODE=push');
  }
});

export type Env = z.infer<typeof envSchema>;
