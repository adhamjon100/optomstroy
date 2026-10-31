// Демо-конфиг браузерного бэкенда веб-демо (WP-B3; plan §3.3 «Конфиг», §3.5; critic [3], [8], [15]).
// Как у `local-stack serve --cashier-fixtures --otp-any-phone`, но для одного процесса в Web Worker:
//   APP_ENV=dev, тестовый код OTP 246810 для любого номера (ADR-109), самообслуживание покупателей;
//   ONEC_MODE=extension с транспортом-имитатором (alias/onec-transport.mjs → PosFakeOnec), QR через «1С»;
//   SMS — фейк, адрес SMSPro — несуществующий (исходящая сеть и так запрещена, shims/net-guard.mjs);
//   MIN_APP_VERSION — версия pos-app/pubspec.yaml для android, windows и ios (web-сборка шлёт 0.1.0+1 с X-Platform
//   windows; без этого каждый запрос получал бы 426, critic [3]);
//   секреты OTP HMAC, PIN pepper, токен 1С HS и ключ JWT создаются в браузере на эпоху (demo_meta).
//
// Модуль без импортов: его читает и сборка (lib/epoch.mjs — параметры данных входят в ключ эпохи), и воркер.

/* global __POS_DEMO_BUILD_JSON__ */
/** Сведения сборки (build-backend.mjs, esbuild define): версия приложения, ключ эпохи. */
export const DEMO_BUILD =
  typeof __POS_DEMO_BUILD_JSON__ !== 'undefined'
    ? JSON.parse(__POS_DEMO_BUILD_JSON__)
    : { appVersion: '0.1.0+1', epochKey: 'dev-unbuilt', migrationBase: '0020', stateFormat: 1 };

/**
 * Параметры данных эпохи (входят в ключ эпохи — lib/epoch.mjs): изменить их — значит начать демо заново.
 * Каталог — настоящим конвейером из SyntheticCatalog seed 1, без подмеса фикстур (иначе «Основной склад» и
 * «Розничная» дублируются, plan §3.5); синтетика кассира SyntheticCashier seed 7 + extraCustomers обычных клиентов.
 */
export const DEMO_DATA = Object.freeze({
  catalog: Object.freeze({ skuCount: 500, seed: 1, includeFixtureCatalog: false }),
  cashier: Object.freeze({ seed: 7, extraCustomers: 20 }),
  /** Версия формата demo_meta (секреты, состояние имитатора 1С, сид). */
  stateFormat: 1,
});

/** Последняя миграция pos-api, входящая в ключ эпохи: более поздние применяет настоящий мигратор на тёплом старте. */
export const EPOCH_MIGRATION_BASE = '0020';

/** Сотрудники стенда (как insertAuthFixtures/insertCashierFixtures local-stack; номера опубликованы в demo/README.md). */
export const STAFF = Object.freeze([
  { phone: '+996777000901', role: 'admin', name: 'Тестов Администратор', hint: 'Администратор' },
  { phone: '+996777000906', role: 'cashier', name: 'Тестов Кассир', hint: 'Кассир' },
  { phone: '+996777000907', role: 'senior_seller', name: 'Тестов Старший', hint: 'Старший продавец' },
  { phone: '+996777000909', role: 'owner', name: 'Тестов Руководитель', hint: 'Руководитель' },
]);
/** Приглашение продавца (вход 902 → роль «Продавец» по приглашению). Срок продлевается на каждом холодном старте. */
export const INVITATION = Object.freeze({ phone: '+996777000902', role: 'seller', name: 'Тестов Продавец', days: 7, renewBelowDays: 3 });
/**
 * Служебные учётки сида истории (не показываются в подсказке входа): после сида блокируются.
 * Имена — «Демо-история …», чтобы в списках сотрудников, аудите и отчётах было ясно, кто это (critic [20]).
 */
export const SEED_ACCOUNTS = Object.freeze([
  { key: 'seller', phone: '+996777000981', role: 'seller', name: 'Демо-история · Продавец' },
  { key: 'cashier', phone: '+996777000986', role: 'cashier', name: 'Демо-история · Кассир' },
  { key: 'senior', phone: '+996777000987', role: 'senior_seller', name: 'Демо-история · Старший продавец' },
]);
/** Подсказка «Как войти» (ready.roles / ready.phones): порядок plan §3.6. */
export const LOGIN_HINTS = Object.freeze([
  { phone: '+996777000902', role: 'seller', title: 'Продавец (по приглашению)' },
  { phone: '+996777000907', role: 'senior_seller', title: 'Старший продавец' },
  { phone: '+996777000906', role: 'cashier', title: 'Кассир' },
  { phone: '+996777000901', role: 'admin', title: 'Администратор' },
  { phone: '+996777000909', role: 'owner', title: 'Руководитель' },
  { phone: '+996777000905', role: 'customer', title: 'Новый покупатель' },
  { phone: '+996777000903', role: 'customer', title: 'Новый покупатель' },
  { phone: '+996700000101', role: 'customer', title: 'Покупатель с карточкой «1С»' },
  { phone: '+996777000904', role: null, title: 'Свободный номер для приглашения' },
]);
export const OTP_TEST_CODE = '246810';

/** QR: опросов «1С» до автооплаты (панель по умолчанию — 5 × 2 с ≈ 10 с); 0 — только кнопкой. */
export const QR_DEFAULTS = Object.freeze({ paidAfterPolls: 5, pollSeconds: 2 });

/**
 * Сброс PGlite на диск. После изменяющего запроса/команды панели — до ответа (critic [4]); фоновые изменения (задачи
 * pg-boss) — не чаще, чем раз в backgroundMs: IndexedDB переписывает текущий сегмент WAL (1 МБ) целиком на каждый
 * syncfs (WP-B0: ~30 МБ/мин при сбросе после каждого оператора).
 */
export const FLUSH = Object.freeze({ backgroundMs: { idb: 10_000, opfs: 2_000, memory: 0 }, opfsBusyRetryMs: 10_000 });

/** «2.3.4+5» → «2.3.4» (минимальная версия = версия сборки без номера сборки). */
export function minAppVersionFor(appVersion) {
  const v = String(appVersion || '0.1.0').split('+')[0].trim();
  if (!/^\d+\.\d+\.\d+$/.test(v)) throw new Error(`demo-config: версия приложения «${appVersion}» не в формате X.Y.Z(+N)`);
  return `android=${v},windows=${v},ios=${v}`;
}

/**
 * Переменные окружения pos-api для loadAppConfig (16 §4.3). secrets — { otpHmac, pinPepper, onecToken } эпохи.
 * overrides — только тесты (worker-harness: initExtra.env).
 */
export function demoEnv(secrets, { appVersion = DEMO_BUILD.appVersion, overrides = {} } = {}) {
  return {
    APP_ENV: 'dev',
    LOG_LEVEL: 'warn',
    TZ: 'Asia/Bishkek',
    DATABASE_URL: 'postgres://pglite/pos',
    MIN_APP_VERSION: minAppVersionFor(appVersion),
    WORKERS_ENABLED: 'true',
    CUSTOMER_SELF_SERVICE: 'true',
    RECEIVABLES_MAX_AGE_MIN: '60',
    MEDIA_DIR: '/vfs/media',
    // OTP: тестовый код для любого номера (только APP_ENV=dev, ADR-109); лимиты подняты, как в local-stack.
    OTP_HMAC_SECRET: secrets.otpHmac,
    PIN_PEPPER: secrets.pinPepper,
    AUTH_OTP_TEST_MODE: 'true',
    AUTH_OTP_TEST_PHONES: '*',
    AUTH_OTP_TEST_CODE: OTP_TEST_CODE,
    OTP_RESEND_COOLDOWN_SECONDS: '10',
    OTP_MAX_SENDS_PER_DEVICE_10M: '100',
    OTP_MAX_SENDS_PER_DEVICE_24H: '500',
    OTP_MAX_SENDS_PER_PHONE_15M: '30',
    OTP_MAX_SENDS_PER_PHONE_24H: '300',
    // SMS — фейк; адрес SMSPro — заведомо несуществующий (запрет сети воркера — shims/net-guard.mjs).
    SMS_PROVIDER: 'fake',
    SMSPRO_BASE_URL: 'https://smspro.invalid/api',
    // «1С» — PosFakeOnec в том же воркере (alias/onec-transport.mjs); адрес только разбирается на путь.
    ONEC_MODE: 'extension',
    ONEC_BASE_URL: 'https://fake-1c.invalid',
    ONEC_HS_PATH: 'ut11/hs',
    ONEC_HS_USER: 'pos_hs',
    ONEC_HS_TOKEN: secrets.onecToken,
    ONEC_TIMEOUT_MS: '5000',
    ONEC_SYNC_CHECK_TIMEOUT_MS: '3000',
    QR_PROVIDER: 'onec',
    QR_ONEC_POLL_SECONDS: String(QR_DEFAULTS.pollSeconds),
    ...overrides,
  };
}

/** Повторы GET шлюза 1С в демо: одна попытка (как WP-B2 alias/onec-gateway.mjs; critic [8]). */
export const ONEC_GATEWAY_RETRY = Object.freeze({ maxAttempts: 1 });
