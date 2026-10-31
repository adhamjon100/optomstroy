// Таблица подмен модулей браузерного бэкенда (плагин esbuild lib/alias-plugin.mjs). Точка расширения для WP-B2:
// новая подмена — строка в одной из таблиц ниже и модуль в backend/alias/. Исходники pos-api не меняются.
//
// Пути модулей подмен — относительно backend/. Если файла подмены ещё нет (пакет WP-B2 не готов), строка с
// `optional: true` пропускается с пометкой в отчёте сборки, остальные — ошибка сборки.

/** Пакет npm → модуль подмены (точное совпадение спецификатора импорта). */
export const PACKAGE_ALIASES = {
  pg: { to: 'alias/pg-shim.mjs', why: 'node-postgres поверх одного PGlite (замок сессии, подсадка по белому списку, сторож)' },
  'pg-boss': { to: 'alias/pgboss-shim.mjs', why: 'тот же pg-boss 12.38 на адаптере fromPglite под замком pg-shim; обработчики задач — единицы работы' },
  '@node-rs/argon2': { to: 'alias/argon2.mjs', why: 'нативный модуль → Argon2id на @noble/hashes (та же строка PHC)' },
  sharp: { to: 'alias/sharp.mjs', why: 'нативный модуль; фото готовятся при сборке снимка' },
  bun: { to: 'alias/stubs.mjs', why: 'статический импорт адаптера pg-boss fromBunSql, в браузере не вызывается' },
  pino: { to: 'alias/pino.mjs', why: 'журнал в кольцевой буфер демо, без потоков и транспорта' },
  'nestjs-pino': { to: 'alias/nestjs-pino.mjs', why: 'мини-модуль LoggerModule/Logger/PinoLogger поверх alias/pino.mjs' },
};

/**
 * Файл скомпилированного pos-api (путь относительно .build/pos-api-dist) → модуль подмены. Совпадение — по
 * разрешённому пути импорта, а не по имени: подмена работает для любого импортёра внутри dist и для scripts/.
 * При сборке проверяется, что файл в dist существует и что подмена экспортирует все его имена.
 */
export const DIST_ALIASES = {
  'common/auth/jwt-keys.js': { to: 'alias/jwt-keys.mjs', why: 'ключ JWT эпохи из WebCrypto (Ed25519, запасной ES256)' },
  'integrations/onec/onec-http-transport.js': { to: 'alias/onec-transport.mjs', why: 'PosFakeOnec в процессе вместо node:http(s)' },
  'integrations/onec/onec-extension.gateway.js': {
    to: 'alias/onec-gateway.mjs',
    why: 'WP-B2: тот же шлюз, одна попытка GET (паузы повторов держали бы единицу работы секундами при «1С недоступна»)',
  },
  'payments/long-poll/payment-status-waiter.js': {
    to: 'alias/payment-waiter.mjs',
    why: 'WP-B2: тот же класс, ожидание long-poll отпускает «единицу работы»',
  },
  'sync/scheduler/sync-scheduler.js': {
    to: 'alias/sync-scheduler.mjs',
    why: 'WP-B2: тот же класс, пересчёт расписаний по таймеру (60 с) — отдельной единицей работы',
  },
  'customers/jobs/customer-onec-results.handler.js': {
    to: 'alias/customer-results.mjs',
    why: 'WP-B2: тот же класс, сверка результатов клиентов по таймеру (5 мин) — отдельной единицей работы',
  },
};

/**
 * Подмена одного импорта внутри пакета npm: importer — суффикс пути файла после `node_modules/`, spec — строка
 * импорта как в файле. Модуль подмены берёт оригинал через `nm:` (мимо этой таблицы).
 */
export const IMPORT_ALIASES = [
  {
    importer: '@noble/hashes/esm/argon2.js',
    spec: './utils.js',
    to: 'alias/noble-yield.mjs',
    why: 'WP-B2: nextTick @noble — микрозадача, Argon2 (~0,4 с) не отдавал цикл событий воркера; здесь — макрозадача (setImmediate на MessageChannel)',
  },
];

/**
 * Модули WP-B2 без строки в таблицах выше (их импортируют подмены и точка входа). Сборка проверяет, что они есть;
 * piggyback-allow.json дополнительно проверяется на формат (lib/checks.mjs checkPiggybackAllow).
 */
export const SUPPORT_MODULES = ['alias/work-gate.mjs', 'alias/piggyback-allow.json'];

/**
 * Необязательные пакеты, которых в браузерном бэкенде нет: загрузка бросает MODULE_NOT_FOUND (alias/missing.cjs),
 * как в Node без пакета. Достижимы только ленивыми require/import (Nest loadPackage, pg native) — проверено в WP-B0.
 * Proxy-заглушка здесь недопустима: Nest решил бы, что пакет установлен.
 */
export const MISSING_PACKAGES =
  /^(pg-native|pino-http|@nestjs\/microservices|@nestjs\/websockets|@fastify\/static|@nestjs\/platform-fastify|fastify|class-transformer\/storage)(\/.*)?$/;
