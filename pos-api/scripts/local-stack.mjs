#!/usr/bin/env node
/**
 * Локальный стек без Docker (ядро R0 §0; RM-C-012 п. 4, RM-C-014): одноразовый PostgreSQL 17 (`embedded-postgres`)
 * → `node dist/migrate.js` → `node dist/migrate.js --seed` → `node dist/main.js` (порт 3000) настоящими процессами.
 *
 *   node scripts/local-stack.mjs smoke              # e2e smoke настоящего процесса API, затем остановка (код 0/1)
 *   node scripts/local-stack.mjs serve [--ready-file <path>] [--ttl <sec>] [--exit-on-stdin-end] [--auth-fixtures]
 *                                                   # поднять стек и держать до Ctrl+C / SIGTERM / --ttl
 *   node scripts/local-stack.mjs auth-smoke         # этап D: сквозные сценарии входа на настоящих процессах (код 0/1)
 *   node scripts/local-stack.mjs catalog-smoke [--catalog-fixtures=N]
 *                                                   # этап E: синхронизация через FakeOnecGateway → каталог, поиск,
 *                                                   # остатки, избранное, офлайн-API на настоящих процессах (код 0/1)
 *   node scripts/local-stack.mjs serve --auth-fixtures --catalog-fixtures[=N]
 *                                                   # этап E (Flutter): + каталог фикстур 1С и N синтетических SKU
 *   node scripts/local-stack.mjs pos-smoke [--catalog-fixtures=N]
 *                                                   # этап F: корзина → заказ → outbox → «Заказ клиента» в фейке 1С →
 *                                                   # QR через 1С → оплата → товарный чек PDF; 503/dead-letter/ручной
 *                                                   # повтор; QR_PROVIDER=none; режим клиента (код 0/1)
 *   node scripts/local-stack.mjs serve --pos-fixtures [--catalog-fixtures[=N]] [--qr-provider onec|none]
 *                         [--qr-paid-after-polls N]  # этап F (Flutter): + pos-worker + управляемый фейк 1С (HTTP)
 *   node scripts/local-stack.mjs cashier-smoke [--catalog-fixtures=N]
 *                                                   # этап G: синхронизация клиентов/долгов/реализаций/скидок из фейка
 *                                                   # 1С (режим кассира) → поиск, карточка, долг, история; продажа в
 *                                                   # долг заблокирована → разрешение старшего (step-up) → оплата →
 *                                                   # транзакции → аудит (цепочка); клиент → outbox → 1С; возврат
 *                                                   # draft → submit → accept/reject; отчёты = данные; режим клиента
 *   node scripts/local-stack.mjs serve --cashier-fixtures [--catalog-fixtures[=N]] [--qr-provider onec|none]
 *                                                   # этап G (Flutter): как --pos-fixtures + фейк 1С в режиме кассира
 *                                                   # и загруженный мир кассира (клиенты с долгами/просрочкой/лимитом,
 *                                                   # история, скидки, возвраты)
 *
 * `--cashier-fixtures` (только dev, этап G; включает `--pos-fixtures`): фейк HTTP-сервиса 1С запускается с `--cashier`
 * (синтетика кассира `SyntheticCashier`: 10 сценарных клиентов + 20 обычных, реализации за `SALES_HISTORY_MONTHS`,
 * оплаты, возвраты, правила скидок; **тестовые данные**). После старта pos-api и pos-worker синхронизирующий
 * администратор (`AUTH_FIXTURES.syncAdmin`, PIN `CASHIER_SYNC_ADMIN_PIN`) со step-up запускает `POST /sync/runs`
 * `customers` (план обмена: клиенты, соглашения, скидки, реализации) и `receivables` (снимки долга) — те же
 * обработчики pos-worker, что в эксплуатации. Сценарные клиенты (телефон → ситуация): +996700123456 — долг в лимите
 * (`AUTH_FIXTURES.cashierCustomerLinked`: регистрация покупателя даёт `proposed` к этой карточке синтетики; это не
 * телефон фикстуры `customers-search.200` — тот у `AUTH_FIXTURES.customerLinked`), +996700223344 — просрочка
 * 8 000,00 (продажа в долг → `CREDIT_BLOCKED overdue`), +996555000103 — без долга, +996555000104 — лимит почти
 * исчерпан (`CREDIT_LIMIT_EXCEEDED`), +996555000105 — лимит в 1С не задан, +996555000106 — без отсрочки
 * (`credit_not_allowed`), +996555000107 — неполный снимок, +996555000108 — «устаревший», +996555000109 — покупатель
 * с историей и возвратом, +996555000110 — аванс. Руководитель (`owner`, integration_test SCR-48) — +996777000909.
 * «Отгрузка» заказа для заявки на возврат (integration_test pos-app) — `POST http://127.0.0.1:8092/__stack/ship/{orderId}`
 * (`LOCAL_STACK_CONTROL_PORT`). Управление: `GET /__fake/cashier/state`,
 * `POST /__fake/cashier/returns/{externalId}/status`, `POST /__fake/cashier/customers/{ref}` (заголовок
 * scripts/pos_fake_onec.ts).
 *
 * `--pos-fixtures` (только dev, этап F; включает `--auth-fixtures` и `--catalog-fixtures`, если не заданы): отдельный
 * процесс управляемого фейка HTTP-сервиса расширения 1С (`scripts/pos_fake_onec.ts`, порт `LOCAL_STACK_ONEC_PORT`,
 * по умолчанию 8091; фикстуры `contracts/onec/fixtures` — **тестовые данные, не реальная интеграция**), pos-api и
 * pos-worker (`node dist/worker.js`, `WORKERS_ENABLED=true`) с `ONEC_MODE=extension` → фейк (боевой HTTP-адаптер
 * `OnecExtensionGateway`), `QR_PROVIDER=onec` (или `--qr-provider none`), `QR_ONEC_POLL_SECONDS=2`. Фейк принимает
 * заказы («Заказ клиента», идемпотентно по externalId), QR оплачивается на N-м опросе воркера
 * (`--qr-paid-after-polls`, по умолчанию 2; 0 — только вручную) или управляющим вызовом. Управляющие вызовы
 * (dev-only: фейк не стартует без APP_ENV=dev|test; полный список — заголовок scripts/pos_fake_onec.ts):
 *   POST http://127.0.0.1:8091/__fake/qr/<paymentId>/pay                       — оплатить QR сейчас
 *   POST http://127.0.0.1:8091/__fake/orders/mode {"mode":"unavailable","failNext":1}  — 503 на одну попытку
 *   POST http://127.0.0.1:8091/__fake/orders/<orderId>/status {"status":"КВыполнению"}
 *   GET  http://127.0.0.1:8091/__fake/state                                    — заказы, QR, журнал вызовов
 * Пользователи (OTP — `AUTH_FIXTURES.otpCode`): admin +996777000901, приглашение seller +996777000902, кассир
 * +996777000906 и старший продавец +996777000907 (созданы сразу; PIN — первым POST /me/pin), клиент — регистрацией.
 *
 * `--catalog-fixtures[=N]` (только dev, этап E): после migrate/seed отдельный процесс
 * `node --import tsx scripts/load_catalog_fixtures.ts --sku N` выполняет полную синхронизацию каталога через
 * `FakeOnecGateway` (фикстуры `contracts/onec/fixtures` + N синтетических SKU, по умолчанию 500; тот же конвейер
 * `CatalogFullLoadService`, что в pos-worker; прогоны — в `sync_runs`) и разовый импорт **синтетических** фото в
 * `MEDIA_DIR` (временный каталог стека). Фото отдаёт мини-прокси «как Caddy» на `http://127.0.0.1:8080`
 * (`LOCAL_STACK_PROXY_PORT`): `/images/{sha}/{thumb|card|full}` — файлы из `MEDIA_DIR` с
 * `Cache-Control: public, max-age=31536000, immutable`, остальное (`/api/*`, `/health*`) — в pos-api :3000. Клиент,
 * которому нужны фото, ходит на :8080 (`/api/v1` там же); на :3000 фото — заглушки (404). **На фикстурах, не реальная
 * интеграция**: данных заказчика нет.
 *
 * `--auth-fixtures` (только dev, этап D, RM-D-011/RM-D-012): тестовый режим OTP 09 §5.8 (`AUTH_OTP_TEST_MODE`,
 * номера `AUTH_FIXTURES.*`, код `AUTH_FIXTURES.otpCode` — SMS не отправляется) и строки-фикстуры: администратор
 * (`admin`, без PIN) и приглашение продавца (`seller`, ФИО «Тестов Продавец»). Номер `customerLinked` читается из
 * фикстуры 1С `customers-search.200` (`body[0].phone`, сейчас +996700000001; совпадение по последним 9 цифрам) →
 * регистрация даёт `customerMatch.status=proposed` (SCR-06).
 *
 * Требует `npm run build` (dist/). Окружение API: APP_ENV=dev, ONEC_MODE=fixtures, SMS_PROVIDER=fake,
 * MIN_APP_VERSION=android=1.0.0,windows=1.0.0 (переопределяется переменной LOCAL_STACK_MIN_APP_VERSION).
 * Строка подключения (с одноразовым паролем) передаётся процессам только через DATABASE_URL_FILE во временном
 * каталоге ОС (конвенция *_FILE, RM-C-009) и удаляется вместе с кластером. В репозиторий ничего не пишется.
 */
import { spawn } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import {
  copyFileSync,
  createReadStream,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { createServer as createHttpServer, request as httpRequest } from 'node:http';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import EmbeddedPostgres from 'embedded-postgres';
import pg from 'pg';

const API_DIR = fileURLToPath(new URL('..', import.meta.url));
const API_PORT = 3000;
const BASE_URL = `http://127.0.0.1:${API_PORT}`;
const MIN_APP_VERSION = process.env.LOCAL_STACK_MIN_APP_VERSION ?? 'android=1.0.0,windows=1.0.0';
const DB_NAME = 'pos_local';
/** Порт мини-прокси «как Caddy» (фото + API) режима `--catalog-fixtures`. */
const PROXY_PORT = Number(process.env.LOCAL_STACK_PROXY_PORT ?? 8080);
/** Порт управляющего HTTP стенда кассира (`serve --cashier-fixtures`, только dev). */
const CONTROL_PORT = Number(process.env.LOCAL_STACK_CONTROL_PORT ?? 8092);
const PROXY_URL = `http://127.0.0.1:${PROXY_PORT}`;
/** LC_CTYPE БД с классификацией кириллицы (FTS/pg_trgm поиска, EQ-SRCH-01) — как en_US.utf8 образа postgres:17. */
const DB_CTYPE = process.platform === 'win32' ? 'en-US' : 'C.UTF-8';
/** Порт управляемого фейка 1С этапа F (`--pos-fixtures`, pos-smoke). */
const ONEC_FAKE_PORT = Number(process.env.LOCAL_STACK_ONEC_PORT ?? 8091);
const ONEC_FAKE_URL = `http://127.0.0.1:${ONEC_FAKE_PORT}`;
/** Синтетических SKU по умолчанию для `--catalog-fixtures` / catalog-smoke. */
const CATALOG_SKU_DEFAULT = 500;

/**
 * Телефон карточки 1С из фикстуры `contracts/onec/fixtures/customers-search.200.json` (`body[0].phone`, тестовые
 * данные): `ONEC_MODE=fixtures` отвечает на `GET /customers?phone=` этой фикстурой, поэтому номер клиента auth-smoke
 * берётся из неё, а не дублируется (после замены ПДн в фикстурах копия устарела — RR-1).
 */
function fixtureCustomerPhone() {
  const path = join(API_DIR, '..', 'contracts', 'onec', 'fixtures', 'customers-search.200.json');
  const phone = JSON.parse(readFileSync(path, 'utf8'))?.body?.[0]?.phone;
  if (typeof phone !== 'string' || !/^\+996\d{9}$/.test(phone)) {
    throw new Error(`фикстура customers-search.200: body[0].phone не E.164 KG (${path})`);
  }
  return phone;
}

/** Тестовые значения этапа D (не секреты; только APP_ENV=dev, 09 §5.8). Номера — синтетические +99677700090N. */
const AUTH_FIXTURES = Object.freeze({
  otpCode: '246810',
  admin: '+996777000901',
  invitedStaff: '+996777000902',
  customer: '+996777000903',
  invitedByAdmin: '+996777000904',
  customerSmoke: '+996777000905',
  /** Клиент с карточкой 1С по фикстуре `customers-search.200` (auth-smoke, `ONEC_MODE=fixtures`). */
  customerLinked: fixtureCustomerPhone(),
  /**
   * Этап G (`--cashier-fixtures`): клиент кассира «долг в лимите» — `CASHIER_SCENARIO_PHONES.debtWithinLimit`
   * синтетики (src/integrations/onec/synthetic-cashier.ts; фейк 1С с `--cashier` ищет по ней, не по фикстуре).
   */
  cashierCustomerLinked: '+996700123456',
  cashier: '+996777000906',
  seniorSeller: '+996777000907',
  /** Этап G: администратор стенда кассира — запускает синхронизацию клиентов/долгов (`--cashier-fixtures`). */
  syncAdmin: '+996777000908',
  /** Этап G (Flutter-интеграция, `--cashier-fixtures`): руководитель (`owner`) — отчёты SCR-48 (тестовые данные). */
  owner: '+996777000909',
  invitedStaffName: 'Тестов Продавец',
});

/** PIN администратора синхронизации стенда кассира (только dev, тестовое значение, не секрет). */
const CASHIER_SYNC_ADMIN_PIN = '930517';

/**
 * Ссылки сценарных клиентов синтетики кассира (копия `CASHIER_SCENARIOS`, src/integrations/onec/synthetic-cashier.ts —
 * .mjs не импортирует TypeScript; **тестовые данные**).
 */
const CASHIER_REFS = Object.freeze({
  debtWithinLimit: 'c3d4e5f6-0000-4000-8000-000000000001',
  overdue: 'c3d4e5f6-0000-4000-8000-000000000002',
  noDebt: 'c3d4e5f6-0000-4000-8000-000000000003',
  buyer: 'c3d4e5f6-0000-4000-8000-000000000009',
});

function authFixtureEnv() {
  const phones = Object.entries(AUTH_FIXTURES)
    .filter(([k]) => k !== 'otpCode' && k !== 'invitedStaffName')
    .map(([, v]) => v);
  // --otp-any-phone (демо, ADR-109): тестовый код подходит для любого номера — только APP_ENV=dev этого стека.
  const anyPhone = process.argv.includes('--otp-any-phone');
  return {
    AUTH_OTP_TEST_MODE: 'true',
    AUTH_OTP_TEST_PHONES: anyPhone ? '*' : phones.join(','),
    AUTH_OTP_TEST_CODE: AUTH_FIXTURES.otpCode,
    // Один «терминал» прогоняет все сценарии подряд (integration_test, auth-smoke): лимиты устройства и номера
    // подняты только на этом локальном стеке; сами лимиты проверяют e2e test/e2e/auth (значения 09 §5.4).
    OTP_MAX_SENDS_PER_DEVICE_10M: '100',
    OTP_MAX_SENDS_PER_DEVICE_24H: '500',
    OTP_MAX_SENDS_PER_PHONE_15M: '20',
    OTP_MAX_SENDS_PER_PHONE_24H: '100',
  };
}

const args = process.argv.slice(2);
const mode = args[0] ?? 'smoke';
const opt = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};

const log = (msg) => process.stdout.write(`[local-stack] ${msg}\n`);

function freePort() {
  return new Promise((resolve, reject) => {
    const s = createServer();
    s.once('error', reject);
    s.listen(0, '127.0.0.1', () => {
      const a = s.address();
      s.close(() => resolve(typeof a === 'object' && a ? a.port : 0));
    });
  });
}

function portIsFree(port) {
  return new Promise((resolve) => {
    const s = createServer();
    s.once('error', () => resolve(false));
    s.listen(port, '0.0.0.0', () => s.close(() => resolve(true)));
  });
}

class Stack {
  dir = mkdtempSync(join(tmpdir(), 'pos-local-stack-'));
  password = randomBytes(18).toString('base64url');
  pgPort = 0;
  server = undefined;
  api = undefined;
  apiLog = join(this.dir, 'api.log');
  /** Хранилище фото (`MEDIA_DIR`, 16 §4.3): `images/{sha256}/{thumb|card|full}.webp`. */
  mediaDir = join(this.dir, 'media');
  proxy = undefined;
  /** Переменные API тестового режима OTP (`--auth-fixtures`, auth-smoke). */
  authEnv = {};
  /** Этап F: процесс pos-worker, фейк 1С и окружение `ONEC_MODE=extension` → фейк. */
  worker = undefined;
  workerLog = join(this.dir, 'worker.log');
  fakeOnec = undefined;
  fakeOnecLog = join(this.dir, 'fake-onec.log');
  posEnv = {};

  get adminUrl() {
    return `postgres://postgres:${encodeURIComponent(this.password)}@127.0.0.1:${this.pgPort}/postgres`;
  }

  get dbUrl() {
    return `postgres://postgres:${encodeURIComponent(this.password)}@127.0.0.1:${this.pgPort}/${DB_NAME}`;
  }

  async startDb() {
    this.pgPort = await freePort();
    this.server = new EmbeddedPostgres({
      databaseDir: join(this.dir, 'data'),
      user: 'postgres',
      password: this.password,
      port: this.pgPort,
      persistent: false,
      initdbFlags: ['--encoding=UTF8', '--locale=C'],
      postgresFlags: ['-c', 'listen_addresses=127.0.0.1', '-c', 'fsync=off', '-c', 'timezone=UTC'],
      onLog: () => undefined,
      onError: () => undefined,
    });
    await this.server.initialise();
    await this.server.start();
    const c = new pg.Client({ connectionString: this.adminUrl });
    await c.connect();
    try {
      const v = await c.query('SHOW server_version');
      log(`PostgreSQL ${v.rows[0].server_version} на 127.0.0.1:${this.pgPort}`);
      // builtin C.UTF-8: lower() корректен для кириллицы (07 §10.1), сортировка побайтовая; LC_CTYPE UTF-8 — FTS и
      // триграммы поиска по-русски (EQ-SRCH-01).
      await c.query(
        `CREATE DATABASE ${DB_NAME} TEMPLATE template0 ENCODING 'UTF8' LOCALE_PROVIDER builtin BUILTIN_LOCALE 'C.UTF-8' LC_COLLATE 'C' LC_CTYPE '${DB_CTYPE}'`,
      );
    } finally {
      await c.end();
    }
    writeFileSync(join(this.dir, 'database_url'), this.dbUrl, { mode: 0o600 });
    // Секреты HMAC OTP и перца PIN — одноразовые на стек, но общие для перезапусков pos-api и для pos-worker
    // (без них APP_ENV=dev берёт эфемерный секрет процесса и PIN не проходит после перезапуска API).
    writeFileSync(join(this.dir, 'pin_pepper'), randomBytes(32).toString('base64url'), { mode: 0o600 });
    writeFileSync(join(this.dir, 'otp_hmac_secret'), randomBytes(32).toString('base64url'), { mode: 0o600 });
  }

  env(extra = {}) {
    const env = { ...process.env };
    for (const k of Object.keys(env))
      if (/^(DATABASE_URL|DB_MIGRATOR_PASSWORD|APP_READ_ONLY|PIN_PEPPER|OTP_HMAC_SECRET)/.test(k)) delete env[k];
    return {
      ...env,
      APP_ENV: 'dev',
      LOG_LEVEL: 'info',
      DATABASE_URL_FILE: join(this.dir, 'database_url'),
      PIN_PEPPER_FILE: join(this.dir, 'pin_pepper'),
      OTP_HMAC_SECRET_FILE: join(this.dir, 'otp_hmac_secret'),
      MIN_APP_VERSION,
      ONEC_MODE: 'fixtures',
      MEDIA_DIR: this.mediaDir,
      SMS_PROVIDER: 'fake',
      OPENAPI_PUBLIC: 'true',
      ...this.authEnv,
      ...extra,
    };
  }

  runNode(script, scriptArgs = []) {
    return new Promise((resolve) => {
      const p = spawn(process.execPath, [script, ...scriptArgs], { cwd: API_DIR, env: this.env(), stdio: 'pipe' });
      let out = '';
      p.stdout.on('data', (d) => (out += d));
      p.stderr.on('data', (d) => (out += d));
      p.on('exit', (code) => resolve({ code, out }));
    });
  }

  async migrate(seed) {
    const r = await this.runNode('dist/migrate.js', seed ? ['--seed'] : []);
    for (const line of r.out.split('\n').filter((l) => l.trim() !== '')) {
      try {
        const j = JSON.parse(line);
        log(
          `migrate${seed ? ' --seed' : ''}: ${j.msg}${j.applied ? ` applied=${JSON.stringify(j.applied)}` : ''}${j.inserted ? ` inserted=${JSON.stringify(j.inserted)}` : ''}`,
        );
      } catch {
        log(`migrate: ${line}`);
      }
    }
    if (r.code !== 0) throw new Error(`dist/migrate.js${seed ? ' --seed' : ''} завершился с кодом ${r.code}`);
  }

  /** Фикстуры этапа D (dev): администратор без PIN и приглашение продавца (07 §5.3: приглашает только admin). */
  async insertAuthFixtures() {
    this.authEnv = authFixtureEnv();
    const c = new pg.Client({ connectionString: this.dbUrl });
    await c.connect();
    try {
      await c.query('BEGIN');
      const admin = await c.query(
        `INSERT INTO users (phone_e164, phone_verified_at, kind, status) VALUES ($1, now(), 'staff', 'active') RETURNING id`,
        [AUTH_FIXTURES.admin],
      );
      const adminId = admin.rows[0].id;
      await c.query(`INSERT INTO user_profiles (user_id, full_name) VALUES ($1, 'Тестов Администратор')`, [adminId]);
      await c.query(`INSERT INTO user_roles (user_id, role_id) SELECT $1, id FROM roles WHERE code = 'admin'`, [
        adminId,
      ]);
      await c.query(
        `INSERT INTO user_invitations (phone_e164, role, full_name, invited_by_user_id, expires_at)
         VALUES ($1, 'seller', $2, $3, now() + interval '7 days')`,
        [AUTH_FIXTURES.invitedStaff, AUTH_FIXTURES.invitedStaffName, adminId],
      );
      // Этап F: кассир и старший продавец (оплата, ручное подтверждение QR со step-up, ручной повтор outbox).
      for (const [phone, role, name] of [
        [AUTH_FIXTURES.cashier, 'cashier', 'Тестов Кассир'],
        [AUTH_FIXTURES.seniorSeller, 'senior_seller', 'Тестов Старший'],
      ]) {
        const u = await c.query(
          `INSERT INTO users (phone_e164, phone_verified_at, kind, status) VALUES ($1, now(), 'staff', 'active') RETURNING id`,
          [phone],
        );
        await c.query(`INSERT INTO user_profiles (user_id, full_name) VALUES ($1, $2)`, [u.rows[0].id, name]);
        await c.query(`INSERT INTO user_roles (user_id, role_id) SELECT $1, id FROM roles WHERE code = $2`, [
          u.rows[0].id,
          role,
        ]);
      }
      await c.query('COMMIT');
    } catch (e) {
      await c.query('ROLLBACK').catch(() => undefined);
      throw e;
    } finally {
      await c.end();
    }
    log('auth-fixtures: администратор (admin, без PIN) и приглашение seller созданы; тестовый режим OTP включён');
  }

  /** Этап G (dev): администратор синхронизации стенда кассира (`AUTH_FIXTURES.syncAdmin`, без PIN — задаётся входом). */
  async insertCashierFixtures() {
    const c = new pg.Client({ connectionString: this.dbUrl });
    await c.connect();
    try {
      await c.query('BEGIN');
      const u = await c.query(
        `INSERT INTO users (phone_e164, phone_verified_at, kind, status) VALUES ($1, now(), 'staff', 'active') RETURNING id`,
        [AUTH_FIXTURES.syncAdmin],
      );
      await c.query(`INSERT INTO user_profiles (user_id, full_name) VALUES ($1, 'Тестов Синхронизация')`, [
        u.rows[0].id,
      ]);
      await c.query(`INSERT INTO user_roles (user_id, role_id) SELECT $1, id FROM roles WHERE code = 'admin'`, [
        u.rows[0].id,
      ]);
      // Руководитель (owner, без PIN — задаётся первым входом): SCR-48 в integration_test pos-app.
      const o = await c.query(
        `INSERT INTO users (phone_e164, phone_verified_at, kind, status) VALUES ($1, now(), 'staff', 'active') RETURNING id`,
        [AUTH_FIXTURES.owner],
      );
      await c.query(`INSERT INTO user_profiles (user_id, full_name) VALUES ($1, 'Тестов Руководитель')`, [
        o.rows[0].id,
      ]);
      await c.query(`INSERT INTO user_roles (user_id, role_id) SELECT $1, id FROM roles WHERE code = 'owner'`, [
        o.rows[0].id,
      ]);
      await c.query('COMMIT');
    } catch (e) {
      await c.query('ROLLBACK').catch(() => undefined);
      throw e;
    } finally {
      await c.end();
    }
    log(
      `cashier-fixtures: администратор синхронизации ${AUTH_FIXTURES.syncAdmin} и руководитель ${AUTH_FIXTURES.owner} созданы (тестовые данные)`,
    );
  }

  /**
   * Этап E: полная синхронизация каталога через FakeOnecGateway (фикстуры 1С + `sku` синтетических SKU) и разовый
   * импорт синтетических фото — отдельным процессом (`scripts/load_catalog_fixtures.ts`, тот же конвейер, что pos-worker).
   */
  async loadCatalog(sku) {
    mkdirSync(this.mediaDir, { recursive: true });
    const r = await this.runNode('--import', ['tsx', 'scripts/load_catalog_fixtures.ts', '--sku', String(sku)]);
    for (const line of r.out.split('\n').filter((l) => l.trim() !== '')) log(`catalog: ${line.trim()}`);
    if (r.code !== 0) throw new Error(`load_catalog_fixtures завершился с кодом ${r.code}`);
    log(`catalog-fixtures: каталог (${sku} SKU + фикстуры 1С) и фото загружены — на фикстурах, не реальная интеграция`);
  }

  /** Мини-прокси «как Caddy» (infra/caddy/Caddyfile, блок `@image`): фото из MEDIA_DIR, остальное — в pos-api. */
  async startMediaProxy() {
    if (!(await portIsFree(PROXY_PORT))) throw new Error(`порт ${PROXY_PORT} занят (LOCAL_STACK_PROXY_PORT)`);
    const media = this.mediaDir;
    this.proxy = createHttpServer((req, res) => {
      const url = (req.url ?? '/').split('?')[0];
      if (url.startsWith('/images/')) {
        const m = /^\/images\/([0-9a-f]{64})\/(thumb|card|full)(\.webp)?$/.exec(url);
        const file = m ? join(media, 'images', m[1], `${m[2]}.webp`) : undefined;
        let size = -1;
        try {
          if (file) size = statSync(file).size;
        } catch {
          size = -1;
        }
        if (!m || (req.method !== 'GET' && req.method !== 'HEAD') || size < 0) {
          res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
          res.end('not found');
          return;
        }
        res.writeHead(200, {
          'Content-Type': 'image/webp',
          'Content-Length': String(size),
          'Cache-Control': 'public, max-age=31536000, immutable',
          ETag: `"${m[1]}-${m[2]}"`,
        });
        if (req.method === 'HEAD') res.end();
        else createReadStream(file).pipe(res);
        return;
      }
      const up = httpRequest(
        { host: '127.0.0.1', port: API_PORT, method: req.method, path: req.url, headers: req.headers },
        (pr) => {
          res.writeHead(pr.statusCode ?? 502, pr.headers);
          pr.pipe(res);
        },
      );
      up.on('error', () => {
        if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end('bad gateway');
      });
      req.pipe(up);
    });
    await new Promise((resolve) => this.proxy.listen(PROXY_PORT, '127.0.0.1', resolve));
    log(`media-proxy ${PROXY_URL}: /images/{sha}/{size} из MEDIA_DIR, прочее → ${BASE_URL}`);
  }

  async startApi(extra = {}) {
    if (!(await portIsFree(API_PORT))) throw new Error(`порт ${API_PORT} занят — остановите другой экземпляр pos-api`);
    const fd = openSync(this.apiLog, 'a');
    this.api = spawn(process.execPath, ['dist/main.js'], {
      cwd: API_DIR,
      env: this.env(extra),
      stdio: ['ignore', fd, fd],
    });
    const deadline = Date.now() + 60_000;
    for (;;) {
      if (this.api.exitCode !== null)
        throw new Error(`pos-api завершился с кодом ${this.api.exitCode} (журнал: ${this.apiLog})`);
      try {
        const r = await fetch(`${BASE_URL}/health/ready`);
        if (r.status === 200) break;
      } catch {
        // ещё стартует
      }
      if (Date.now() > deadline) throw new Error('pos-api не стал ready за 60 с');
      await new Promise((r) => setTimeout(r, 500));
    }
    log(
      `pos-api pid=${this.api.pid} готов: ${BASE_URL} (${Object.keys(extra).length ? JSON.stringify(extra) : 'обычный режим'})`,
    );
  }

  /**
   * Этап F: управляемый фейк HTTP-сервиса расширения 1С (отдельный процесс `scripts/pos_fake_onec.ts`) и окружение
   * pos-api/pos-worker `ONEC_MODE=extension` → фейк (секреты HS — файлы во временном каталоге стека, *_FILE).
   */
  async startFakeOnec(qrPaidAfterPolls = 2, cashier = null) {
    if (!(await portIsFree(ONEC_FAKE_PORT))) throw new Error(`порт ${ONEC_FAKE_PORT} занят (LOCAL_STACK_ONEC_PORT)`);
    const ready = join(this.dir, 'fake-onec.ready');
    const fd = openSync(this.fakeOnecLog, 'a');
    this.fakeOnec = spawn(
      process.execPath,
      [
        '--import',
        'tsx',
        'scripts/pos_fake_onec.ts',
        '--port',
        String(ONEC_FAKE_PORT),
        '--ready-file',
        ready,
        '--qr-paid-after-polls',
        String(qrPaidAfterPolls),
        ...(cashier ? ['--cashier', '--catalog-sku', String(cashier.sku ?? 0)] : []),
      ],
      { cwd: API_DIR, env: { ...process.env, APP_ENV: 'dev' }, stdio: ['pipe', fd, fd] },
    );
    const deadline = Date.now() + 60_000;
    for (;;) {
      if (this.fakeOnec.exitCode !== null) throw new Error(`фейк 1С завершился с кодом ${this.fakeOnec.exitCode}`);
      try {
        statSync(ready);
        break;
      } catch {
        // ещё стартует
      }
      if (Date.now() > deadline) throw new Error('фейк 1С не стартовал за 60 с');
      await new Promise((r) => setTimeout(r, 300));
    }
    writeFileSync(join(this.dir, 'onec_hs_user'), 'pos_hs', { mode: 0o600 });
    writeFileSync(join(this.dir, 'onec_hs_token'), randomBytes(16).toString('hex'), { mode: 0o600 });
    this.posEnv = {
      ONEC_MODE: 'extension',
      ONEC_BASE_URL: ONEC_FAKE_URL,
      ONEC_HS_PATH: 'ut11/hs',
      ONEC_HS_USER_FILE: join(this.dir, 'onec_hs_user'),
      ONEC_HS_TOKEN_FILE: join(this.dir, 'onec_hs_token'),
      ONEC_TIMEOUT_MS: '5000',
      ONEC_SYNC_CHECK_TIMEOUT_MS: '3000',
      QR_PROVIDER: 'onec',
      QR_ONEC_POLL_SECONDS: '2',
      SYNC_ORDER_STATUS_CRON: '* * * * *',
    };
    log(
      `fake-onec ${ONEC_FAKE_URL}/ut11/hs${cashier ? ' [режим кассира]' : ''} (тестовые данные; управляющие вызовы ${ONEC_FAKE_URL}/__fake/*)`,
    );
  }

  async startWorker(extra = {}) {
    const fd = openSync(this.workerLog, 'a');
    const start = (() => {
      try {
        return statSync(this.workerLog).size;
      } catch {
        return 0;
      }
    })();
    this.worker = spawn(process.execPath, ['dist/worker.js'], {
      cwd: API_DIR,
      env: this.env({ ...this.posEnv, ...extra, WORKERS_ENABLED: 'true' }),
      stdio: ['ignore', fd, fd],
    });
    const deadline = Date.now() + 90_000;
    for (;;) {
      if (this.worker.exitCode !== null)
        throw new Error(`pos-worker завершился с кодом ${this.worker.exitCode} (журнал: ${this.workerLog})`);
      let text;
      try {
        text = readFileSync(this.workerLog, 'utf8').slice(start);
      } catch {
        text = '';
      }
      if (text.includes('"worker.started"') && text.includes('payments.jobs.registered')) break;
      if (Date.now() > deadline) throw new Error(`pos-worker не стартовал за 90 с (журнал: ${this.workerLog})`);
      await new Promise((r) => setTimeout(r, 500));
    }
    log(`pos-worker pid=${this.worker.pid} готов (QR_PROVIDER=${extra.QR_PROVIDER ?? this.posEnv.QR_PROVIDER})`);
  }

  async stopWorker() {
    if (!this.worker || this.worker.exitCode !== null) return;
    const p = this.worker;
    await new Promise((resolve) => {
      const t = setTimeout(() => p.kill('SIGKILL'), 15_000);
      p.once('exit', () => {
        clearTimeout(t);
        resolve();
      });
      p.kill('SIGTERM');
    });
    this.worker = undefined;
  }

  async stopApi() {
    if (!this.api || this.api.exitCode !== null) return;
    const p = this.api;
    await new Promise((resolve) => {
      const t = setTimeout(() => {
        p.kill('SIGKILL');
      }, 10_000);
      p.once('exit', () => {
        clearTimeout(t);
        resolve();
      });
      p.kill('SIGTERM');
    });
    this.api = undefined;
  }

  async stop() {
    if (this.control) {
      const cs = this.control;
      this.control = undefined;
      await new Promise((resolve) => {
        cs.close(() => resolve());
        cs.closeAllConnections();
      });
    }
    if (this.proxy) {
      const px = this.proxy;
      this.proxy = undefined;
      await new Promise((resolve) => {
        px.close(() => resolve());
        px.closeAllConnections();
      });
    }
    await this.stopApi().catch(() => undefined);
    await this.stopWorker().catch(() => undefined);
    if (this.fakeOnec && this.fakeOnec.exitCode === null) {
      const f = this.fakeOnec;
      await new Promise((resolve) => {
        const t = setTimeout(() => f.kill('SIGKILL'), 5_000);
        f.once('exit', () => {
          clearTimeout(t);
          resolve();
        });
        f.kill('SIGTERM');
        f.stdin?.end();
      });
    }
    await this.server?.stop().catch(() => undefined);
    // Журналы процессов (без секретов: строка подключения — только в файле database_url) — для разбора отказов.
    const keep = process.env.LOCAL_STACK_LOG_DIR;
    if (keep) {
      mkdirSync(keep, { recursive: true });
      for (const f of [this.apiLog, this.workerLog, this.fakeOnecLog]) {
        try {
          copyFileSync(f, join(keep, f.slice(this.dir.length + 1)));
        } catch {
          // журнала нет — процесс не запускался
        }
      }
    }
    rmSync(this.dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

async function http(method, path, headers = {}) {
  const r = await fetch(`${BASE_URL}${path}`, { method, headers });
  const text = await r.text();
  let body = text;
  try {
    body = JSON.parse(text);
  } catch {
    // не JSON
  }
  return { status: r.status, headers: r.headers, body };
}

async function smoke(stack) {
  const results = [];
  const check = (name, ok, detail) => {
    results.push(ok);
    log(`${ok ? 'PASS' : 'FAIL'} ${name} — ${detail}`);
  };

  // MIN_APP_VERSION для smoke: windows выше android — проверка «своя платформа → 426, другая — без 426».
  await stack.startApi({
    MIN_APP_VERSION: 'android=1.0.0,windows=1.2.0',
    RECOMMENDED_APP_VERSION: 'android=1.1.0,windows=1.3.0',
  });
  const W = (v) => ({ 'X-App-Version': v, 'X-Platform': 'windows' });
  const A = (v) => ({ 'X-App-Version': v, 'X-Platform': 'android' });
  let r = await http('GET', '/health');
  check('GET /health', r.status === 200 && r.body?.status === 'ok', `${r.status} ${JSON.stringify(r.body)}`);
  r = await http('GET', '/health/ready');
  check('GET /health/ready', r.status === 200 && r.body?.status === 'ok', `${r.status} ${JSON.stringify(r.body)}`);
  r = await http('GET', '/health', W('0.0.1'));
  check('/health не проверяет версию (RM-C-015 п. 4)', r.status === 200, `${r.status}`);
  r = await http('GET', '/health/ready', W('0.0.1'));
  check('/health/ready не проверяет версию (RM-C-015 п. 4)', r.status === 200, `${r.status}`);
  r = await http('GET', '/api/v1/catalog/categories', W('1.1.0'));
  check(
    'windows 1.1.0 < MIN windows=1.2.0 → 426 APP_UPDATE_REQUIRED + X-Min-App-Version',
    r.status === 426 &&
      r.body?.code === 'APP_UPDATE_REQUIRED' &&
      r.headers.get('x-min-app-version') === 'windows=1.2.0',
    `${r.status} code=${r.body?.code} X-Min-App-Version=${r.headers.get('x-min-app-version')}`,
  );
  r = await http('GET', '/api/v1/catalog/categories', A('1.1.0'));
  check(
    'android 1.1.0 ≥ MIN android=1.0.0 → не 426 (маршрута на этапе C нет → 404) + X-Min/X-Recommended',
    r.status !== 426 &&
      r.headers.get('x-min-app-version') === 'android=1.0.0' &&
      r.headers.get('x-recommended-app-version') === 'android=1.1.0',
    `${r.status} code=${r.body?.code} X-Min-App-Version=${r.headers.get('x-min-app-version')} X-Recommended-App-Version=${r.headers.get('x-recommended-app-version')}`,
  );
  r = await http('GET', '/api/v1/openapi.json', W('1.2.0'));
  check(
    'GET /api/v1/openapi.json (windows 1.2.0) → 200 + X-Min-App-Version + X-Request-Id',
    r.status === 200 &&
      r.headers.get('x-min-app-version') === 'windows=1.2.0' &&
      (r.headers.get('x-request-id') ?? '') !== '',
    `${r.status} openapi=${r.body?.openapi} X-Min-App-Version=${r.headers.get('x-min-app-version')} X-Request-Id=${r.headers.get('x-request-id')}`,
  );
  r = await http('GET', '/api/v1/me', W('1.2.0'));
  check('защищённый путь без токена → не 200 (deny by default)', r.status !== 200, `${r.status} code=${r.body?.code}`);
  await stack.stopApi();

  await stack.startApi({ APP_READ_ONLY: 'true' });
  r = await http('GET', '/health/ready');
  check('APP_READ_ONLY=true: GET /health/ready → 200', r.status === 200, `${r.status}`);
  r = await http('POST', '/api/v1/orders', {
    'X-App-Version': '1.0.0',
    'X-Platform': 'windows',
    'Content-Type': 'application/json',
  });
  check(
    'APP_READ_ONLY=true: POST /api/v1/orders → 503 APP_READ_ONLY или 404 (на этапе C мутирующих маршрутов нет)',
    (r.status === 503 && r.body?.code === 'APP_READ_ONLY') || r.status === 404,
    `${r.status} code=${r.body?.code}`,
  );
  await stack.stopApi();

  const failed = results.filter((x) => !x).length;
  log(`итог: ${results.length - failed}/${results.length} PASS`);
  return failed === 0;
}

/** JSON-запрос к API этапа D (заголовки клиента по 08 §2.2). Тела ответов целиком не логируются (токены). */
async function api(method, path, { token, deviceId, body, idem, stepUp } = {}) {
  const headers = { 'X-App-Version': '1.0.0', 'X-Platform': 'windows', 'Content-Type': 'application/json' };
  if (deviceId) headers['X-Device-Id'] = deviceId;
  if (token) headers.Authorization = `Bearer ${token}`;
  if (idem) headers['Idempotency-Key'] = randomUUID();
  if (stepUp) headers['X-Step-Up-Token'] = stepUp;
  const r = await fetch(`${BASE_URL}/api/v1${path}`, {
    method,
    headers,
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const text = await r.text();
  let json;
  try {
    json = text ? JSON.parse(text) : undefined;
  } catch {
    json = undefined;
  }
  return { status: r.status, body: json };
}

const SMOKE_DEVICE = { name: 'Касса (local-stack)', platform: 'windows', appVersion: '1.0.0', biometricClass: 'none' };
const SMOKE_CONSENTS = [{ kind: 'personal_data', version: '2026-10-01' }];

/** OTP-вход тестовым кодом: request → verify. */
async function otpLogin(phone, deviceId) {
  const req = await api('POST', '/auth/otp/request', {
    deviceId,
    body: { phone, purpose: 'login_or_register', locale: 'ru' },
  });
  if (req.status !== 202) return { req };
  const verify = await api('POST', '/auth/otp/verify', {
    deviceId,
    body: { challengeId: req.body.challengeId, code: AUTH_FIXTURES.otpCode, device: SMOKE_DEVICE },
  });
  return { req, verify };
}

/** Сквозные сценарии этапа D на настоящих процессах (RM-D-011/RM-D-012, API-уровень; номера маскируются). */
async function authSmoke() {
  const results = [];
  const check = (name, ok, detail) => {
    results.push(ok);
    log(`${ok ? 'PASS' : 'FAIL'} ${name} — ${detail}`);
  };
  const mask = (p) => `${p.slice(0, 5)}*****${p.slice(-2)}`;

  // 1. Клиент без приглашения: OTP → registration_required → /registration/complete (PIN) → /me.
  {
    const dev = randomUUID();
    const { req, verify } = await otpLogin(AUTH_FIXTURES.customer, dev);
    check(`клиент ${mask(AUTH_FIXTURES.customer)}: POST /auth/otp/request → 202`, req.status === 202, `${req.status}`);
    check(
      'клиент: POST /auth/otp/verify → 200 registration_required',
      verify?.status === 200 && verify.body?.status === 'registration_required',
      `${verify?.status} status=${verify?.body?.status}`,
    );
    const reg = await api('POST', '/registration/complete', {
      deviceId: dev,
      idem: true,
      body: {
        registrationToken: verify?.body?.registrationToken, // check-secrets: allow — имя поля/заголовка, не секрет
        fullName: 'Тестов Клиент',
        birthYear: 1990,
        security: { pin: '583920' },
        consents: SMOKE_CONSENTS,
        device: SMOKE_DEVICE,
      },
    });
    check(
      'клиент: POST /registration/complete → 201, customer active',
      reg.status === 201 && reg.body?.user?.kind === 'customer' && reg.body?.user?.status === 'active',
      `${reg.status} kind=${reg.body?.user?.kind} status=${reg.body?.user?.status} customerMatch=${reg.body?.customerMatch?.status} ${reg.body?.code ?? ''}`,
    );
    const me = await api('GET', '/me', { token: reg.body?.accessToken, deviceId: dev }); // check-secrets: allow — имя поля/заголовка, не секрет
    check(
      'клиент: GET /me → 200, pinSet=true',
      me.status === 200 && me.body?.security?.pinSet === true,
      `${me.status} pinSet=${me.body?.security?.pinSet}`,
    );
  }

  // 2. Клиент с карточкой 1С (фикстура customers-search.200) → customerMatch proposed (SCR-06).
  {
    const dev = randomUUID();
    const { verify } = await otpLogin(AUTH_FIXTURES.customerLinked, dev);
    const reg = await api('POST', '/registration/complete', {
      deviceId: dev,
      idem: true,
      body: {
        registrationToken: verify?.body?.registrationToken, // check-secrets: allow — имя поля/заголовка, не секрет
        fullName: 'Асанов Бакыт',
        birthYear: 1985,
        security: { pin: '739152' },
        consents: SMOKE_CONSENTS,
        device: SMOKE_DEVICE,
      },
    });
    const m = reg.body?.customerMatch;
    check(
      `клиент ${mask(AUTH_FIXTURES.customerLinked)} с карточкой 1С: 201, customerMatch=proposed (SCR-06)`,
      reg.status === 201 && m?.status === 'proposed',
      `${reg.status} customerMatch.status=${m?.status} nextStep=${m?.nextStep} ${reg.body?.code ?? ''}`,
    );
  }

  // 3. Приглашённый сотрудник: OTP → authenticated staff seller, nextStep=set_pin, без формы регистрации;
  //    до PIN — 403 pin_not_set; первый POST /me/pin без step-up → 204; затем GET /me.
  {
    const dev = randomUUID();
    const { verify } = await otpLogin(AUTH_FIXTURES.invitedStaff, dev);
    const b = verify?.body;
    check(
      `приглашённый ${mask(AUTH_FIXTURES.invitedStaff)}: verify → authenticated staff/seller, roleSource=invitation, nextStep=set_pin`,
      verify?.status === 200 &&
        b?.status === 'authenticated' &&
        b?.user?.kind === 'staff' &&
        (b?.user?.roles ?? []).includes('seller') &&
        b?.roleSource === 'invitation' &&
        b?.nextStep === 'set_pin',
      `${verify?.status} status=${b?.status} kind=${b?.user?.kind} roles=${JSON.stringify(b?.user?.roles)} roleSource=${b?.roleSource} nextStep=${b?.nextStep}`,
    );
    const blocked = await api('GET', '/customers?linkStatus=proposed', { token: b?.accessToken, deviceId: dev }); // check-secrets: allow — имя поля/заголовка, не секрет
    check(
      'приглашённый до PIN: прочие маршруты → 403 FORBIDDEN reason=pin_not_set',
      blocked.status === 403 && blocked.body?.reason === 'pin_not_set',
      `${blocked.status} code=${blocked.body?.code} reason=${blocked.body?.reason}`,
    );
    const pin = await api('POST', '/me/pin', { token: b?.accessToken, deviceId: dev, body: { newPin: '582914' } }); // check-secrets: allow — имя поля/заголовка, не секрет
    check(
      'приглашённый: первый POST /me/pin без step-up → 204',
      pin.status === 204,
      `${pin.status} ${pin.body?.code ?? ''}`,
    );
    const me = await api('GET', '/me', { token: b?.accessToken, deviceId: dev }); // check-secrets: allow — имя поля/заголовка, не секрет
    check(
      'приглашённый: GET /me → pinSet=true, ФИО приглашения',
      me.status === 200 &&
        me.body?.security?.pinSet === true &&
        me.body?.profile?.fullName === AUTH_FIXTURES.invitedStaffName,
      `${me.status} pinSet=${me.body?.security?.pinSet} fullName=${me.body?.profile?.fullName === AUTH_FIXTURES.invitedStaffName ? 'совпадает' : 'не совпадает'}`,
    );
  }

  // 4. Администратор: OTP → PIN → step-up(PIN) → POST /admin/invitations → вход приглашённого по OTP.
  {
    const dev = randomUUID();
    const { verify } = await otpLogin(AUTH_FIXTURES.admin, dev);
    const token = verify?.body?.accessToken; // check-secrets: allow — имя поля/заголовка, не секрет
    const pin = await api('POST', '/me/pin', { token, deviceId: dev, body: { newPin: '604817' } });
    const su = await api('POST', '/auth/step-up', {
      token,
      deviceId: dev,
      body: { method: 'pin', operation: 'invitations.manage', pin: '604817' },
    });
    check(
      'admin: OTP → POST /me/pin → POST /auth/step-up (pin) → stepUpToken',
      verify?.status === 200 && pin.status === 204 && su.status === 200 && typeof su.body?.stepUpToken === 'string',
      `verify=${verify?.status} pin=${pin.status} stepUp=${su.status} ${su.body?.code ?? ''}`,
    );
    const invite = { phone: AUTH_FIXTURES.invitedByAdmin, roles: ['cashier'], fullName: 'Тестов Кассир' };
    const noStep = await api('POST', '/admin/invitations', { token, deviceId: dev, idem: true, body: invite });
    check(
      'admin: POST /admin/invitations без X-Step-Up-Token → 403 STEP_UP_REQUIRED',
      noStep.status === 403 && noStep.body?.code === 'STEP_UP_REQUIRED',
      `${noStep.status} ${noStep.body?.code}`,
    );
    const inv = await api('POST', '/admin/invitations', {
      token,
      deviceId: dev,
      idem: true,
      stepUp: su.body?.stepUpToken,
      body: invite,
    });
    check(
      'admin: POST /admin/invitations (cashier) → 201',
      inv.status === 201,
      `${inv.status} ${inv.body?.code ?? ''}`,
    );
    const { verify: v2 } = await otpLogin(AUTH_FIXTURES.invitedByAdmin, randomUUID());
    check(
      'приглашённый администратором: OTP → staff/cashier, nextStep=set_pin',
      v2?.status === 200 && (v2.body?.user?.roles ?? []).includes('cashier') && v2.body?.nextStep === 'set_pin',
      `${v2?.status} roles=${JSON.stringify(v2?.body?.user?.roles)} nextStep=${v2?.body?.nextStep}`,
    );
  }

  // 5. Неверный код → OTP_INVALID; JWT alg=none → 401.
  {
    const dev = randomUUID();
    const req = await api('POST', '/auth/otp/request', {
      deviceId: dev,
      body: { phone: AUTH_FIXTURES.customerSmoke, purpose: 'login_or_register', locale: 'ru' },
    });
    const bad = await api('POST', '/auth/otp/verify', {
      deviceId: dev,
      body: { challengeId: req.body?.challengeId, code: '000000', device: SMOKE_DEVICE },
    });
    check(
      'неверный код → 422 OTP_INVALID с attemptsLeft',
      bad.status === 422 && bad.body?.code === 'OTP_INVALID',
      `${bad.status} ${bad.body?.code} attemptsLeft=${bad.body?.attemptsLeft}`,
    );
    const header = Buffer.from('{"alg":"none","typ":"JWT"}').toString('base64url');
    const payload = Buffer.from('{"sub":"x"}').toString('base64url');
    const r = await api('GET', '/me', { token: `${header}.${payload}.`, deviceId: dev });
    check(
      'JWT alg=none → 401 UNAUTHENTICATED',
      r.status === 401 && r.body?.code === 'UNAUTHENTICATED',
      `${r.status} ${r.body?.code}`,
    );
  }

  const failed = results.filter((x) => !x).length;
  log(`auth-smoke итог: ${results.length - failed}/${results.length} PASS`);
  return failed === 0;
}

/** Запрос к API этапа E с произвольными заголовками; возвращает статус, заголовки и JSON. */
async function apiE(method, path, { token, deviceId, body, headers = {}, base = BASE_URL } = {}) {
  const h = { 'X-App-Version': '1.0.0', 'X-Platform': 'windows', ...headers };
  if (body) h['Content-Type'] = 'application/json';
  if (deviceId) h['X-Device-Id'] = deviceId;
  if (token) h.Authorization = `Bearer ${token}`;
  if (method !== 'GET') h['Idempotency-Key'] = randomUUID();
  const r = await fetch(`${base}/api/v1${path}`, {
    method,
    headers: h,
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const text = await r.text();
  let json;
  try {
    json = text ? JSON.parse(text) : undefined;
  } catch {
    json = undefined;
  }
  return { status: r.status, headers: r.headers, body: json };
}

/** Сотрудник по OTP (тестовый код) + первый PIN без step-up → access-токен (этап D). */
async function staffSession(phone, pinValue) {
  const dev = randomUUID();
  const { verify } = await otpLogin(phone, dev);
  const token = verify?.body?.accessToken; // check-secrets: allow — имя поля/заголовка, не секрет
  const pin = await api('POST', '/me/pin', { token, deviceId: dev, body: { newPin: pinValue } }); // check-secrets: allow — имя поля/заголовка, не секрет
  return { token, deviceId: dev, ok: verify?.status === 200 && pin.status === 204, roles: verify?.body?.user?.roles };
}

/** Клиент: OTP → регистрация (PIN) → access-токен. */
async function customerSession(phone) {
  const dev = randomUUID();
  const { verify } = await otpLogin(phone, dev);
  const reg = await api('POST', '/registration/complete', {
    deviceId: dev,
    idem: true,
    body: {
      registrationToken: verify?.body?.registrationToken, // check-secrets: allow — имя поля/заголовка, не секрет
      fullName: 'Тестов Покупатель',
      birthYear: 1991,
      security: { pin: '583921' },
      consents: SMOKE_CONSENTS,
      device: SMOKE_DEVICE,
    },
  });
  return { token: reg.body?.accessToken, deviceId: dev, ok: reg.status === 201 }; // check-secrets: allow — имя поля/заголовка, не секрет
}

const MONEY_RE = /^\d{1,13}\.\d{2}$/;

/**
 * Этап E на настоящих процессах (RM-E-012, интеграция backend): синхронизация каталога через FakeOnecGateway (процесс
 * load_catalog_fixtures) → `/catalog/products` (ETag/304, цены строкой + KGS, курсор) → карточка и «Недавние» →
 * `/search/products` (артикул, FTS), `/search/barcode/{value}` → `/inventory/check` (3 варианта) → избранное
 * (двойной PUT идемпотентен, DELETE) → `/catalog/sync/{entity}` (выгрузка до hasMore=false = реплика, повтор с since)
 * → проекция остатков клиенту → фото через мини-прокси → `/sync/status`. **На фикстурах, не реальная интеграция.**
 */
async function catalogSmoke(stack, sku) {
  const results = [];
  const check = (name, ok, detail) => {
    results.push(Boolean(ok));
    log(`${ok ? 'PASS' : 'FAIL'} ${name} — ${detail}`);
  };
  const db = new pg.Client({ connectionString: stack.dbUrl });
  await db.connect();
  const q1 = async (sql, params = []) => (await db.query(sql, params)).rows[0];
  try {
    const runs = await db.query(
      `SELECT entity::text AS entity, status::text AS status FROM sync_runs WHERE entity::text <> 'images' ORDER BY started_at`,
    );
    check(
      'синхронизация через FakeOnecGateway: прогоны каталога sync_runs = success',
      runs.rows.length >= 8 && runs.rows.every((r) => r.status === 'success'),
      runs.rows.map((r) => `${r.entity}=${r.status}`).join(', '),
    );
    const live = await q1(`SELECT count(*)::int AS n FROM products WHERE NOT deletion_mark`);
    check(`реплика: живых товаров ≥ 95 % от ${sku} SKU`, live.n >= Math.floor(sku * 0.95), `products=${live.n}`);

    const seller = await staffSession(AUTH_FIXTURES.invitedStaff, '582914');
    const admin = await staffSession(AUTH_FIXTURES.admin, '604817');
    const customer = await customerSession(AUTH_FIXTURES.customer);
    check(
      'сессии: seller (приглашение), admin, customer (регистрация)',
      seller.ok && admin.ok && customer.ok,
      `seller=${seller.ok} roles=${JSON.stringify(seller.roles)} admin=${admin.ok} customer=${customer.ok}`,
    );
    const S = { token: seller.token, deviceId: seller.deviceId };

    let r = await apiE('GET', '/catalog/categories', S);
    const etag = r.headers.get('etag');
    check(
      'GET /catalog/categories → 200 + ETag',
      r.status === 200 && Array.isArray(r.body?.items) && !!etag,
      `${r.status} items=${r.body?.items?.length} etag=${etag ? 'есть' : 'нет'}`,
    );
    r = await apiE('GET', '/catalog/categories', { ...S, headers: { 'If-None-Match': etag ?? '' } });
    check('If-None-Match → 304', r.status === 304, `${r.status}`);

    r = await apiE('GET', '/catalog/products?limit=50', S);
    const items = r.body?.items ?? [];
    const priced = items.find((p) => p.price?.price?.amount);
    check(
      'GET /catalog/products?limit=50 → 200, страница + nextCursor, цены строкой "1234.50" + KGS',
      r.status === 200 &&
        items.length === 50 &&
        r.body?.hasMore === true &&
        !!r.body?.nextCursor &&
        priced &&
        MONEY_RE.test(priced.price.price.amount) &&
        priced.price.price.currency === 'KGS',
      `${r.status} items=${items.length} hasMore=${r.body?.hasMore} price=${JSON.stringify(priced?.price?.price)}`,
    );
    const r2 = await apiE(
      'GET',
      `/catalog/products?limit=50&cursor=${encodeURIComponent(r.body?.nextCursor ?? '')}`,
      S,
    );
    const overlap = (r2.body?.items ?? []).filter((x) => items.some((y) => y.id === x.id)).length;
    check(
      'курсор: вторая страница без повторов',
      r2.status === 200 && (r2.body?.items ?? []).length > 0 && overlap === 0,
      `${r2.status} items=${r2.body?.items?.length} повторов=${overlap}`,
    );

    const simple = items.filter((p) => !p.hasVariants && p.defaultVariantId && p.baseUnit?.id && p.price);
    const card = simple[0];
    r = await apiE('GET', `/catalog/products/${card?.id}`, S);
    check(
      'GET /catalog/products/{id} → 200 карточка',
      r.status === 200 && r.body?.id === card?.id,
      `${r.status} sku=${r.body?.sku}`,
    );
    let recentOk = false;
    for (let i = 0; i < 20 && !recentOk; i++) {
      const rr = await apiE('GET', '/catalog/products/recent', S);
      recentOk = rr.status === 200 && (rr.body?.items ?? []).some((x) => x.id === card?.id);
      if (!recentOk) await new Promise((res) => setTimeout(res, 150));
    }
    check(
      'просмотр карточки → «Недавние» (08 §4.4.3, @RecordsRecentView)',
      recentOk,
      `recent содержит товар: ${recentOk}`,
    );

    r = await apiE('GET', `/search/products?q=${encodeURIComponent('F4252')}`, S);
    check(
      'GET /search/products?q=F4252 → matchType=sku',
      r.status === 200 && r.body?.items?.[0]?.matchType === 'sku',
      `${r.status} first=${r.body?.items?.[0]?.sku} matchType=${r.body?.items?.[0]?.matchType}`,
    );
    r = await apiE('GET', `/search/products?q=${encodeURIComponent('смеситель фрап')}`, S);
    check(
      'GET /search/products?q=смеситель фрап → найдено (fts/trgm)',
      r.status === 200 && (r.body?.items ?? []).length > 0 && ['fts', 'trgm'].includes(r.body?.items?.[0]?.matchType),
      `${r.status} items=${r.body?.items?.length} matchType=${r.body?.items?.[0]?.matchType}`,
    );
    const bc = await q1(
      `SELECT b.value FROM barcodes b JOIN products p ON p.id = b.product_id
        WHERE NOT b.deletion_mark AND NOT p.deletion_mark AND b.packaging_id IS NULL ORDER BY b.value LIMIT 1`,
    );
    r = await apiE('GET', `/search/barcode/${encodeURIComponent(bc?.value ?? '0')}`, S);
    check(
      'GET /search/barcode/{value} → 200 товар и вариант',
      r.status === 200 && !!r.body?.product?.id && !!r.body?.variant?.id,
      `${r.status} barcodeType=${r.body?.barcodeType}`,
    );

    r = await apiE('GET', '/catalog/warehouses', S);
    const wh = (r.body?.items ?? [])[0];
    const three = simple.slice(0, 3);
    r = await apiE('POST', '/inventory/check', {
      ...S,
      body: {
        warehouseId: wh?.id,
        items: three.map((p) => ({ variantId: p.defaultVariantId, quantity: { value: '1', unitId: p.baseUnit.id } })),
      },
    });
    check(
      'POST /inventory/check (3 варианта) → 200 ok/shortages/unavailable',
      r.status === 200 &&
        typeof r.body?.ok === 'boolean' &&
        Array.isArray(r.body?.shortages) &&
        Array.isArray(r.body?.unavailable) &&
        three.length === 3,
      `${r.status} ok=${r.body?.ok} shortages=${r.body?.shortages?.length} unavailable=${r.body?.unavailable?.length}`,
    );

    const fav = three[1]?.id;
    const p1 = await apiE('PUT', `/favorites/products/${fav}`, S);
    const p2 = await apiE('PUT', `/favorites/products/${fav}`, S);
    r = await apiE('GET', '/favorites/products', S);
    const favCount = (r.body?.items ?? []).filter((x) => x.id === fav).length;
    check(
      'избранное: двойной PUT → 204/204, в списке один раз',
      p1.status === 204 && p2.status === 204 && favCount === 1,
      `${p1.status}/${p2.status} в списке=${favCount}`,
    );
    const d1 = await apiE('DELETE', `/favorites/products/${fav}`, S);
    r = await apiE('GET', '/favorites/products', S);
    check(
      'избранное: DELETE → 204, товара нет',
      d1.status === 204 && !(r.body?.items ?? []).some((x) => x.id === fav),
      `${d1.status}`,
    );

    let since;
    let pages = 0;
    let total = 0;
    let last;
    do {
      last = await apiE(
        'GET',
        `/catalog/sync/products?limit=200${since ? `&since=${encodeURIComponent(since)}` : ''}`,
        S,
      );
      pages += 1;
      total += (last.body?.items ?? []).length;
      since = last.body?.nextCursor ?? since;
    } while (last.status === 200 && last.body?.hasMore === true && pages < 100);
    const keys = last.body ? Object.keys(last.body).sort().join(',') : '';
    check(
      'GET /catalog/sync/products: выгрузка до hasMore=false = реплика (живые товары), ключи ответа ровно 5',
      last.status === 200 && total === live.n && keys === 'deleted,hasMore,items,nextCursor,serverTime',
      `${last.status} страниц=${pages} items=${total} БД=${live.n} ключи=${keys}`,
    );
    r = await apiE('GET', `/catalog/sync/products?limit=200&since=${encodeURIComponent(since ?? '')}`, S);
    check(
      'повтор с since последней страницы → 0 новых',
      r.status === 200 && (r.body?.items ?? []).length === 0 && r.body?.hasMore === false,
      `${r.status} items=${r.body?.items?.length}`,
    );
    r = await apiE('GET', '/catalog/sync/prices?limit=200', S);
    check(
      'GET /catalog/sync/prices (seller) → 200',
      r.status === 200 && Array.isArray(r.body?.items),
      `${r.status} items=${r.body?.items?.length}`,
    );

    r = await apiE('GET', '/catalog/products?limit=20', { token: customer.token, deviceId: customer.deviceId });
    const leaks = (r.body?.items ?? []).filter(
      (p) => p.stock && ('quantity' in p.stock || 'reserved' in p.stock || 'available' in p.stock),
    ).length;
    check(
      'customer (customer_stock_display=status): остатки без quantity/reserved/available',
      r.status === 200 && (r.body?.items ?? []).length > 0 && leaks === 0,
      `${r.status} items=${r.body?.items?.length} с количествами=${leaks}`,
    );

    const img = await q1(
      `SELECT encode(checksum_sha256, 'hex') AS sha FROM product_images WHERE status = 'ready' AND deleted_at IS NULL LIMIT 1`,
    );
    const ir = await fetch(`${PROXY_URL}/images/${img?.sha}/card`);
    const bytes = (await ir.arrayBuffer()).byteLength;
    check(
      'фото (синтетические) через мини-прокси: /images/{sha}/card → 200 image/webp, immutable',
      ir.status === 200 &&
        ir.headers.get('content-type') === 'image/webp' &&
        (ir.headers.get('cache-control') ?? '').includes('immutable') &&
        bytes > 0,
      `${ir.status} ${ir.headers.get('content-type')} ${ir.headers.get('cache-control')} ${bytes} байт`,
    );
    r = await apiE('GET', '/catalog/products?limit=200', S);
    const withImg = (r.body?.items ?? []).find((p) => p.primaryImage?.cardUrl);
    const viaApi = withImg ? await fetch(`${PROXY_URL}${withImg.primaryImage.cardUrl}`) : undefined;
    check(
      'primaryImage.cardUrl из API открывается через прокси (/images/{sha}/card)',
      viaApi?.status === 200,
      `${withImg?.primaryImage?.cardUrl ?? 'нет фото на странице'} → ${viaApi?.status}`,
    );
    r = await apiE('GET', '/sync/status', { token: admin.token, deviceId: admin.deviceId });
    check(
      'GET /sync/status (admin) → 200',
      r.status === 200 && Array.isArray(r.body?.entities),
      `${r.status} overall=${r.body?.overall} entities=${r.body?.entities?.length}`,
    );
  } finally {
    await db.end().catch(() => undefined);
  }
  const failed = results.filter((x) => !x).length;
  log(`catalog-smoke итог: ${results.length - failed}/${results.length} PASS (на фикстурах, не реальная интеграция)`);
  return failed === 0;
}

/** Запрос к API этапа F: JSON или двоичный ответ (PDF), заголовки клиента 08 §2.2. */
async function apiF(method, path, { token, deviceId, body, idem, stepUp, headers = {} } = {}) {
  const h = { 'X-App-Version': '1.0.0', 'X-Platform': 'windows', ...headers };
  if (body !== undefined) h['Content-Type'] = 'application/json';
  if (deviceId) h['X-Device-Id'] = deviceId;
  if (token) h.Authorization = `Bearer ${token}`;
  if (idem) h['Idempotency-Key'] = idem === true ? randomUUID() : idem;
  if (stepUp) h['X-Step-Up-Token'] = stepUp;
  const r = await fetch(`${BASE_URL}/api/v1${path}`, {
    method,
    headers: h,
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
  const buf = Buffer.from(await r.arrayBuffer());
  let json;
  try {
    json = buf.length ? JSON.parse(buf.toString('utf8')) : undefined;
  } catch {
    json = undefined;
  }
  return { status: r.status, headers: r.headers, body: json, buf };
}

/** Управляющий вызов фейка 1С (dev-only). */
async function fakeOnec(method, path, body) {
  const r = await fetch(`${ONEC_FAKE_URL}${path}`, {
    method,
    headers: { 'Content-Type': 'application/json' },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
  return { status: r.status, body: await r.json().catch(() => undefined) };
}

/** Повторять `fn`, пока результат не удовлетворит `ok` (или до таймаута); возвращает последний результат. */
async function until(fn, ok, timeoutMs = 60_000, stepMs = 500) {
  const deadline = Date.now() + timeoutMs;
  let last;
  for (;;) {
    last = await fn();
    if (ok(last)) return last;
    if (Date.now() > deadline) return last;
    await new Promise((r) => setTimeout(r, stepMs));
  }
}

/** Наполнить активную корзину актора: вариант × количество (сервер считает цены, клиент их не передаёт — D-23). */
async function fillCart(actor, variant, quantity) {
  const before = await apiF('GET', '/cart', actor);
  const put = await apiF('PUT', `/cart/items/${variant.variantId}`, {
    ...actor,
    body: {
      quantity: { value: quantity, unitId: variant.unitId, packagingId: null },
      rowVersion: before.body?.rowVersion,
      mode: 'set',
    },
  });
  const cart = await apiF('GET', '/cart', actor);
  return { put, cart: cart.body };
}

/** Повторный вход по OTP после перезапуска pos-api (ключ подписи dev-JWT — на процесс); PIN уже задан. */
async function relogin(phone) {
  const deviceId = randomUUID();
  let { req, verify } = await otpLogin(phone, deviceId);
  // Пауза повторной отправки кода на номер (09 §5.4, `otp_resend_cooldown`) — ждём `retryAfter` и повторяем.
  for (let i = 0; i < 2 && req?.status === 429; i++) {
    const wait = Number(req.body?.retryAfter ?? req.body?.retryAfterSeconds ?? 60);
    log(`relogin: 429 ${req.body?.code ?? ''} — пауза ${wait} с (otp_resend_cooldown)`);
    await new Promise((r) => setTimeout(r, (wait + 1) * 1000));
    ({ req, verify } = await otpLogin(phone, deviceId));
  }
  return { token: verify?.body?.accessToken, deviceId, ok: verify?.status === 200 }; // check-secrets: allow — имя поля, не секрет
}

const onecNumberOf = (order) => order?.onec?.number ?? null;

function orderBody(cart, variant, quantity, paymentMethod) {
  return {
    cartId: cart?.id,
    cartRowVersion: cart?.rowVersion,
    receiver: { kind: 'customer' },
    delivery: { method: 'pickup' },
    paymentMethod,
    items: [{ variantId: variant.variantId, quantity: { value: quantity, unitId: variant.unitId, packagingId: null } }],
  };
}

/**
 * Этап F на настоящих процессах (RM-F-009 backend, RM-F-010 «на фикстурах»): pos-api + pos-worker + управляемый фейк
 * HTTP-сервиса расширения 1С (`ONEC_MODE=extension` → `scripts/pos_fake_onec.ts`). Сценарии: корзина →
 * checkout-preview → POST /orders (повтор по ключу) → outbox → «Заказ клиента» в фейке 1С (идемпотентно по
 * externalId) → статус → оплата наличными → товарный чек PDF; QR через 1С (`QR_PROVIDER=onec`): создан → опрос
 * воркера → received → чек; 1С недоступна (503) → заказ `submitting` (`onecSyncState=pending`) → восстановление;
 * отказ 1С (422) → `submit_failed` + восстановление корзины (ORD-027, порт CartReader в pos-worker); dead-letter →
 * ручной повтор `POST /sync/outbox/{id}/retry`; `QR_PROVIDER=none` → ручное подтверждение со step-up; режим клиента.
 * **На фикстурах, не реальная интеграция.** Ускорение: ожидание повтора outbox (график 1, 2, 5… мин — константа
 * ТЗ) сокращается записью `next_attempt_at = now()` в БД стека (только тест).
 */
async function posSmoke(stack, sku) {
  const results = [];
  const check = (name, ok, detail) => {
    results.push(Boolean(ok));
    log(`${ok ? 'PASS' : 'FAIL'} ${name} — ${detail}`);
  };
  const db = new pg.Client({ connectionString: stack.dbUrl });
  await db.connect();
  const q = async (sql, params = []) => (await db.query(sql, params)).rows;
  const outboxOf = async (orderId) =>
    (
      await q(
        `SELECT id, status::text AS status, attempts, last_error_code FROM onec_outbox
          WHERE aggregate_type = 'order' AND aggregate_id = $1 AND operation = 'create'`,
        [orderId],
      )
    )[0];
  const kickOutbox = (orderId) =>
    q(`UPDATE onec_outbox SET next_attempt_at = now() WHERE aggregate_id = $1 AND status = 'pending'`, [orderId]);
  try {
    const variants = (
      await q(
        `SELECT v.id AS "variantId", p.base_unit_id AS "unitId", pr.price::text AS price
           FROM product_variants v
           JOIN products p ON p.id = v.product_id
           JOIN units u ON u.id = p.base_unit_id
           JOIN prices pr ON pr.variant_id = v.id AND pr.packaging_id IS NULL
            AND pr.price_list_id = (SELECT id FROM price_lists WHERE is_default AND NOT deletion_mark ORDER BY sort_order, id LIMIT 1)
           JOIN stock_balances sb ON sb.variant_id = v.id
            AND sb.warehouse_id = (SELECT id FROM warehouses WHERE is_active AND NOT deletion_mark
                                    ORDER BY is_default_for_pos DESC, sort_order, name, id LIMIT 1)
          WHERE NOT v.deletion_mark AND NOT p.deletion_mark AND p.is_sellable AND v.is_default = NOT p.has_variants
            AND sb.available > 10 AND pr.price > 0 AND u.qty_precision = 0
          ORDER BY p.name, v.id LIMIT 12`,
      )
    ).map((r) => ({ ...r }));
    check(
      `каталог (${sku} SKU + фикстуры 1С): ≥ 8 продаваемых вариантов`,
      variants.length >= 8,
      `вариантов=${variants.length}`,
    );

    const seller = await staffSession(AUTH_FIXTURES.invitedStaff, '582914');
    const cashier = await staffSession(AUTH_FIXTURES.cashier, '715382');
    const senior = await staffSession(AUTH_FIXTURES.seniorSeller, '826493');
    const customer = await customerSession(AUTH_FIXTURES.customer);
    check(
      'сессии: seller, cashier, senior_seller, customer',
      seller.ok && cashier.ok && senior.ok && customer.ok,
      `seller=${seller.ok} cashier=${cashier.ok} senior=${senior.ok} customer=${customer.ok}`,
    );
    const S = { token: seller.token, deviceId: seller.deviceId };
    const C = { token: cashier.token, deviceId: cashier.deviceId };
    const SS = { token: senior.token, deviceId: senior.deviceId };
    const K = { token: customer.token, deviceId: customer.deviceId };

    // 1. Корзина продавца → checkout-preview → POST /orders (cash) → повтор по ключу.
    const v0 = variants[0];
    let { put, cart } = await fillCart(S, v0, '3');
    check(
      'PUT /cart/items/{variantId} → 200, цена строки и итоги считает сервер (строки денег "1234.50")',
      put.status === 200 && /^\d+\.\d{2}$/.test(String(cart?.total?.amount ?? '')) && cart?.total?.currency === 'KGS',
      `${put.status} ${put.body?.code ?? ''} total=${JSON.stringify(cart?.total)}`,
    );
    let r = await apiF('POST', '/cart/checkout-preview', {
      ...S,
      body: {
        cartId: cart?.id,
        cartRowVersion: cart?.rowVersion,
        paymentMethod: 'cash',
        delivery: { method: 'pickup' },
        receiver: { kind: 'customer' },
      },
    });
    check(
      'POST /cart/checkout-preview → 200 + previewToken, /check 1С через фейк выполнен (onecCheck.result=ok)',
      r.status === 200 && typeof r.body?.previewToken === 'string' && r.body?.onecCheck?.result === 'ok',
      `${r.status} ${r.body?.code ?? ''} onecCheck=${JSON.stringify(r.body?.onecCheck)} allowed=${JSON.stringify(r.body?.permissions?.allowedPaymentMethods)}`,
    );
    const key1 = randomUUID();
    const body1 = orderBody(cart, v0, '3', 'cash');
    const o1 = await apiF('POST', '/orders', { ...S, idem: key1, body: body1 });
    check(
      'POST /orders (cash) → 201 (/check выполнен), status=submitting, onecSyncState=pending',
      o1.status === 201 && o1.body?.status === 'submitting' && o1.body?.onecSyncState === 'pending',
      `${o1.status} ${o1.body?.code ?? ''} status=${o1.body?.status} onecSyncState=${o1.body?.onecSyncState} total=${JSON.stringify(o1.body?.total)}`,
    );
    const replay = await apiF('POST', '/orders', { ...S, idem: key1, body: body1 });
    check(
      'повтор POST /orders с тем же Idempotency-Key → тот же заказ, Idempotent-Replayed: true',
      replay.status === o1.status &&
        replay.body?.id === o1.body?.id &&
        replay.headers.get('idempotent-replayed') === 'true',
      `${replay.status} id совпадает=${replay.body?.id === o1.body?.id} replayed=${replay.headers.get('idempotent-replayed')}`,
    );
    const orderId1 = o1.body?.id;
    let ord = await until(
      () => apiF('GET', `/orders/${orderId1}`, S),
      (x) => x.body?.status === 'awaiting_payment' && !!onecNumberOf(x.body),
      60_000,
    );
    check(
      'outbox → pos-worker → «Заказ клиента» в 1С (фейк): номер и ref 1С в заказе, status=awaiting_payment (проекция на sent)',
      ord.body?.status === 'awaiting_payment' && !!onecNumberOf(ord.body) && !!ord.body?.onec?.ref,
      `status=${ord.body?.status} onecSyncState=${ord.body?.onecSyncState} onec.number=${onecNumberOf(ord.body)}`,
    );
    let st = await fakeOnec('GET', '/__fake/state');
    const fo = (st.body?.orders ?? []).filter((x) => x.externalId === orderId1);
    const ob1 = await outboxOf(orderId1);
    check(
      'фейк 1С: ровно один документ с externalId = id заказа (идемпотентность по externalId)',
      fo.length === 1 && fo[0].number === onecNumberOf(ord.body) && ['sent', 'confirmed'].includes(ob1?.status),
      `документов=${fo.length} createCalls=${fo[0]?.createCalls} outbox=${ob1?.status}`,
    );
    // Повторная отправка того же документа (ручной повтор/таймаут ответа) не создаёт дубль.
    const dup = await fetch(`${ONEC_FAKE_URL}/ut11/hs/pos/v1/orders`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-POS-Client-Key': 'smoke' },
      body: JSON.stringify({ externalId: orderId1 }),
    });
    const dupBody = await dup.json();
    st = await fakeOnec('GET', '/__fake/state');
    check(
      'повторная отправка в 1С с тем же externalId → 200, тот же ref/номер, документ один',
      dup.status === 200 &&
        dupBody.number === onecNumberOf(ord.body) &&
        (st.body?.orders ?? []).filter((x) => x.externalId === orderId1).length === 1,
      `${dup.status} number=${dupBody.number}`,
    );

    // 2. Оплата наличными кассиром → товарный чек PDF.
    const total1 = ord.body?.total?.amount;
    const cashPay = (ord.body?.payments ?? []).find((p) => p.method === 'cash');
    r = await apiF('POST', `/orders/${orderId1}/payments`, {
      ...C,
      idem: true,
      body: { method: 'cash', receivedAmount: { amount: String(total1), currency: 'KGS' } },
    });
    check(
      'POST /orders/{id}/payments (cash, кассир) → received, заказ оплачен',
      [200, 201].includes(r.status) && r.body?.status === 'received' && r.body?.order?.isPaid === true,
      `${r.status} ${r.body?.code ?? ''} status=${r.body?.status} isPaid=${r.body?.order?.isPaid} начальный=${cashPay?.status}`,
    );
    r = await apiF('GET', `/orders/${orderId1}/documents/receipt.pdf`, C);
    check(
      'GET /orders/{id}/documents/receipt.pdf → 200 application/pdf, %PDF',
      r.status === 200 &&
        (r.headers.get('content-type') ?? '').startsWith('application/pdf') &&
        r.buf.subarray(0, 4).toString('latin1') === '%PDF',
      `${r.status} ${r.headers.get('content-type')} ${r.buf.length} байт`,
    );
    r = await apiF('GET', `/orders/${orderId1}/documents/invoice.pdf?format=thermal80`, C);
    check(
      'GET /orders/{id}/documents/invoice.pdf?format=thermal80 → 200 PDF (номер 1С есть)',
      r.status === 200 && r.buf.subarray(0, 4).toString('latin1') === '%PDF',
      `${r.status} ${r.buf.length} байт`,
    );
    await fakeOnec('POST', `/__fake/orders/${orderId1}/status`, { status: 'КВыполнению', approved: true });
    ord = await until(
      () => apiF('GET', `/orders/${orderId1}?refreshFromOnec=true`, S),
      (x) => ['approved', 'awaiting_shipment'].includes(x.body?.status) && x.body?.onecSyncState === 'linked',
      30_000,
      1000,
    );
    check(
      'смена статуса в 1С («К выполнению») → GET /orders/{id}?refreshFromOnec: статус проецирован, onecSyncState=linked',
      ['approved', 'awaiting_shipment'].includes(ord.body?.status) && ord.body?.onecSyncState === 'linked',
      `status=${ord.body?.status} onecSyncState=${ord.body?.onecSyncState}`,
    );

    // 3. QR через 1С (QR_PROVIDER=onec): создан → опрос воркера → received → товарный чек.
    const v1 = variants[1];
    ({ cart } = await fillCart(C, v1, '2'));
    const oq = await apiF('POST', '/orders', { ...C, idem: true, body: orderBody(cart, v1, '2', 'qr_bakai') });
    const qp = (oq.body?.payments ?? [])[0];
    check(
      'POST /orders (qr_bakai, QR_PROVIDER=onec) → платёж qr_shown, qr.provider=onec, autoConfirm=true',
      [201, 202].includes(oq.status) &&
        qp?.status === 'qr_shown' &&
        qp?.qr?.provider === 'onec' &&
        qp?.qr?.autoConfirm === true,
      `${oq.status} ${oq.body?.code ?? ''} payment=${qp?.status} provider=${qp?.qr?.provider} autoConfirm=${qp?.qr?.autoConfirm}`,
    );
    const paidQr = await until(
      () => apiF('GET', `/payments/${qp?.id}?wait=10`, C),
      (x) => x.body?.status === 'received',
      60_000,
      200,
    );
    st = await fakeOnec('GET', '/__fake/state');
    const fq = (st.body?.qr ?? []).find((x) => x.externalId === qp?.id);
    check(
      'pos-worker опрашивает статус QR у 1С (payments.qr_onec_poll) → оплачено → payment received (long-poll ?wait)',
      paidQr.body?.status === 'received' && (fq?.polls ?? 0) >= 2,
      `status=${paidQr.body?.status} опросов 1С=${fq?.polls} статус в фейке=${fq?.status}`,
    );
    const oqId = oq.body?.id;
    const oqPaid = await until(
      () => apiF('GET', `/orders/${oqId}`, C),
      (x) => x.body?.isPaid === true && !!onecNumberOf(x.body),
      60_000,
    );
    r = await apiF('GET', `/orders/${oqId}/documents/receipt.pdf`, C);
    check(
      'QR-заказ: isPaid=true, документ 1С создан; товарный чек PDF → 200',
      oqPaid.body?.isPaid === true &&
        !!onecNumberOf(oqPaid.body) &&
        r.status === 200 &&
        r.buf.subarray(0, 4).toString('latin1') === '%PDF',
      `isPaid=${oqPaid.body?.isPaid} status=${oqPaid.body?.status} onec.number=${onecNumberOf(oqPaid.body)} pdf=${r.status}`,
    );

    // 4. 1С недоступна (503) → submitting с баннером (onecSyncState=pending) → восстановление.
    await fakeOnec('POST', '/__fake/orders/mode', { mode: 'unavailable', failNext: 1 });
    const v2 = variants[2];
    ({ cart } = await fillCart(S, v2, '1'));
    const o503 = await apiF('POST', '/orders', { ...S, idem: true, body: orderBody(cart, v2, '1', 'cash') });
    const id503 = o503.body?.id;
    const ob503 = await until(
      () => outboxOf(id503),
      (x) => (x?.attempts ?? 0) >= 1 && x?.status === 'pending',
      60_000,
    );
    ord = await apiF('GET', `/orders/${id503}`, S);
    check(
      '1С 503: outbox pending (attempts=1, повтор по графику), заказ submitting, onecSyncState=pending (баннер)',
      ob503?.status === 'pending' &&
        ob503?.attempts >= 1 &&
        ord.body?.status === 'submitting' &&
        ord.body?.onecSyncState === 'pending',
      `outbox=${ob503?.status} attempts=${ob503?.attempts} error=${ob503?.last_error_code} order=${ord.body?.status}/${ord.body?.onecSyncState}`,
    );
    await kickOutbox(id503);
    ord = await until(
      () => apiF('GET', `/orders/${id503}`, S),
      (x) => x.body?.status === 'awaiting_payment',
      60_000,
    );
    check(
      '1С восстановилась → повтор outbox → документ создан, заказ awaiting_payment',
      ord.body?.status === 'awaiting_payment' && !!onecNumberOf(ord.body),
      `status=${ord.body?.status} onecSyncState=${ord.body?.onecSyncState} onec.number=${onecNumberOf(ord.body)}`,
    );

    // 5. Отказ 1С (422) → submit_failed, корзина восстановлена в pos-worker (ORD-027), уведомление.
    await fakeOnec('POST', '/__fake/orders/mode', { mode: 'reject', failNext: 1 });
    const v3 = variants[3];
    ({ cart } = await fillCart(S, v3, '2'));
    const o422 = await apiF('POST', '/orders', { ...S, idem: true, body: orderBody(cart, v3, '2', 'cash') });
    const id422 = o422.body?.id;
    ord = await until(
      () => apiF('GET', `/orders/${id422}`, S),
      (x) => x.body?.status === 'submit_failed',
      60_000,
    );
    const restored = await until(
      () => apiF('GET', '/cart', S),
      (x) => (x.body?.items ?? []).some((i) => i.variantId === v3.variantId),
      20_000,
    );
    const notes = await apiF('GET', '/notifications?limit=50', S);
    check(
      'отказ 1С (422) → submit_failed; корзина восстановлена pos-worker (CartReader, ORD-027); уведомление автору',
      ord.body?.status === 'submit_failed' &&
        (restored.body?.items ?? []).some((i) => i.variantId === v3.variantId) &&
        (notes.body?.items ?? []).length > 0,
      `status=${ord.body?.status} restoredFromOrderId=${restored.body?.restoredFromOrderId} уведомлений=${notes.body?.items?.length} unread=${notes.body?.unreadCount}`,
    );
    await apiF('DELETE', `/cart?rowVersion=${restored.body?.rowVersion}`, S);

    // 6. Dead-letter (OUTBOX_MAX_ATTEMPTS=2 на этом стеке) → ручной повтор старшим продавцом.
    await fakeOnec('POST', '/__fake/orders/mode', { mode: 'unavailable', failNext: 2 });
    const v4 = variants[4];
    ({ cart } = await fillCart(S, v4, '1'));
    const oDead = await apiF('POST', '/orders', { ...S, idem: true, body: orderBody(cart, v4, '1', 'cash') });
    const idDead = oDead.body?.id;
    await until(
      () => outboxOf(idDead),
      (x) => (x?.attempts ?? 0) >= 1,
      60_000,
    );
    await kickOutbox(idDead);
    const obDead = await until(
      () => outboxOf(idDead),
      (x) => x?.status === 'dead',
      60_000,
    );
    const list = await apiF('GET', '/sync/outbox?status=dead', SS);
    check(
      'dead-letter: после OUTBOX_MAX_ATTEMPTS попыток → dead; виден в GET /sync/outbox?status=dead (senior_seller)',
      obDead?.status === 'dead' && list.status === 200 && (list.body?.items ?? []).some((i) => i.id === obDead?.id),
      `outbox=${obDead?.status} attempts=${obDead?.attempts} list=${list.status} items=${list.body?.items?.length}`,
    );
    r = await apiF('POST', `/sync/outbox/${obDead?.id}/retry`, { ...SS, idem: true });
    ord = await until(
      () => apiF('GET', `/orders/${idDead}`, S),
      (x) => x.body?.status === 'awaiting_payment',
      60_000,
    );
    st = await fakeOnec('GET', '/__fake/state');
    check(
      'ручной повтор POST /sync/outbox/{id}/retry → 202 → документ создан (тот же externalId), заказ awaiting_payment',
      r.status === 202 &&
        ord.body?.status === 'awaiting_payment' &&
        (st.body?.orders ?? []).filter((x) => x.externalId === idDead).length === 1,
      `retry=${r.status} ${r.body?.code ?? ''} status=${ord.body?.status} onec.number=${onecNumberOf(ord.body)}`,
    );

    // 7. Режим клиента (QR_PROVIDER=onec): allowedPaymentMethods [cash, qr_bakai]; credit → 403; заказ cash.
    const v5 = variants[5];
    const kc = await fillCart(K, v5, '1');
    r = await apiF('POST', '/cart/checkout-preview', {
      ...K,
      body: {
        cartId: kc.cart?.id,
        cartRowVersion: kc.cart?.rowVersion,
        paymentMethod: 'cash',
        delivery: { method: 'pickup' },
        receiver: { kind: 'customer' },
      },
    });
    const allowed = r.body?.permissions?.allowedPaymentMethods ?? [];
    check(
      'режим клиента: PUT /cart/items → 200; checkout-preview allowedPaymentMethods = [cash, qr_bakai] (QR_PROVIDER=onec)',
      kc.put.status === 200 &&
        r.status === 200 &&
        allowed.includes('cash') &&
        allowed.includes('qr_bakai') &&
        !allowed.includes('credit'),
      `put=${kc.put.status} ${kc.put.body?.code ?? ''} preview=${r.status} ${r.body?.code ?? ''} allowed=${JSON.stringify(allowed)}`,
    );
    r = await apiF('POST', '/orders', { ...K, idem: true, body: orderBody(kc.cart, v5, '1', 'credit') });
    check(
      'режим клиента: POST /orders credit → 403 FORBIDDEN',
      r.status === 403,
      `${r.status} ${r.body?.code} ${r.body?.creditReason ?? r.body?.reason ?? ''}`,
    );
    r = await apiF('POST', '/orders', {
      ...K,
      idem: true,
      body: { ...orderBody(kc.cart, v5, '1', 'cash'), manualDiscountPercent: '5.00' },
    });
    check('режим клиента: ручная скидка в POST /orders → 403', r.status === 403, `${r.status} ${r.body?.code}`);
    const ko = await apiF('POST', '/orders', { ...K, idem: true, body: orderBody(kc.cart, v5, '1', 'cash') });
    ord = await until(
      () => apiF('GET', `/orders/${ko.body?.id}`, K),
      (x) => x.body?.status !== 'submitting' && !!onecNumberOf(x.body),
      60_000,
    );
    const kr = await apiF('GET', `/orders/${ko.body?.id}/documents/receipt.pdf`, K);
    check(
      'режим клиента: заказ cash → 201/202 → документ 1С; товарный чек клиенту → 403',
      [201, 202].includes(ko.status) &&
        ord.body?.status === 'awaiting_payment' &&
        !!onecNumberOf(ord.body) &&
        ord.body?.createdVia === 'customer' &&
        kr.status === 403,
      `${ko.status} ${ko.body?.code ?? ''} status=${ord.body?.status} receipt=${kr.status}`,
    );

    // 8. QR_PROVIDER=none: перезапуск pos-api и pos-worker → статический QR → ручное подтверждение со step-up.
    const callsBefore = (await fakeOnec('GET', '/__fake/state')).body?.calls ?? [];
    const qrCallsBefore = callsBefore.filter((c) => c.path.startsWith('/pos/v1/payments')).length;
    await stack.stopApi();
    await stack.stopWorker();
    await stack.startApi({ ...stack.posEnv, QR_PROVIDER: 'none' });
    await stack.startWorker({ QR_PROVIDER: 'none', OUTBOX_MAX_ATTEMPTS: '2' });
    const c2 = await relogin(AUTH_FIXTURES.cashier);
    const k2 = await relogin(AUTH_FIXTURES.customer);
    check(
      'после перезапуска: повторный вход по OTP (cashier, customer)',
      c2.ok && k2.ok,
      `cashier=${c2.ok} customer=${k2.ok}`,
    );
    Object.assign(C, { token: c2.token, deviceId: c2.deviceId });
    Object.assign(K, { token: k2.token, deviceId: k2.deviceId });
    const v6 = variants[6];
    ({ cart } = await fillCart(C, v6, '1'));
    const on = await apiF('POST', '/orders', { ...C, idem: true, body: orderBody(cart, v6, '1', 'qr_bakai') });
    const np = (on.body?.payments ?? [])[0];
    check(
      'QR_PROVIDER=none: POST /orders qr_bakai → платёж с qr.provider≠onec, autoConfirm=false',
      [201, 202].includes(on.status) && np && np.qr?.provider !== 'onec' && np.qr?.autoConfirm === false,
      `${on.status} ${on.body?.code ?? ''} payment=${np?.status} provider=${np?.qr?.provider} autoConfirm=${np?.qr?.autoConfirm}`,
    );
    const noStep = await apiF('POST', `/payments/${np?.id}/confirm-manual`, {
      ...C,
      idem: true,
      body: {
        bankReference: 'BK-SMOKE-1',
        receivedAmount: { amount: np?.amount?.amount ?? np?.amount, currency: 'KGS' },
      },
    });
    const su = await apiF('POST', '/auth/step-up', {
      ...C,
      body: { method: 'pin', operation: 'payment.qr.confirm_manual', pin: '715382' },
    });
    const conf = await apiF('POST', `/payments/${np?.id}/confirm-manual`, {
      ...C,
      idem: true,
      stepUp: su.body?.stepUpToken,
      body: {
        bankReference: 'BK-SMOKE-1',
        receivedAmount: { amount: np?.amount?.amount ?? np?.amount, currency: 'KGS' },
      },
    });
    check(
      'ручное подтверждение: без step-up → 403 STEP_UP_REQUIRED; со step-up (PIN) → received',
      noStep.status === 403 &&
        noStep.body?.code === 'STEP_UP_REQUIRED' &&
        su.status === 200 &&
        [200, 201].includes(conf.status) &&
        conf.body?.status === 'received',
      `noStep=${noStep.status} ${noStep.body?.code} stepUp=${su.status} ${su.body?.code ?? ''} confirm=${conf.status} ${conf.body?.code ?? ''} status=${conf.body?.status}`,
    );
    const callsAfter = (await fakeOnec('GET', '/__fake/state')).body?.calls ?? [];
    const qrCallsAfter = callsAfter.filter((c) => c.path.startsWith('/pos/v1/payments')).length;
    check(
      'QR_PROVIDER=none: обращений к методам QR 1С нет',
      qrCallsAfter === qrCallsBefore,
      `вызовов /pos/v1/payments до=${qrCallsBefore} после=${qrCallsAfter}`,
    );
    const kc2 = await fillCart(K, variants[7], '1');
    r = await apiF('POST', '/cart/checkout-preview', {
      ...K,
      body: {
        cartId: kc2.cart?.id,
        cartRowVersion: kc2.cart?.rowVersion,
        paymentMethod: 'cash',
        delivery: { method: 'pickup' },
        receiver: { kind: 'customer' },
      },
    });
    const allowed2 = r.body?.permissions?.allowedPaymentMethods ?? [];
    const kq = await apiF('POST', '/orders', {
      ...K,
      idem: true,
      body: orderBody(kc2.cart, variants[7], '1', 'qr_bakai'),
    });
    check(
      'режим клиента при QR_PROVIDER=none: allowedPaymentMethods=[cash]; qr_bakai → 422 payment_method_unavailable',
      r.status === 200 && allowed2.length === 1 && allowed2[0] === 'cash' && kq.status === 422,
      `preview=${r.status} allowed=${JSON.stringify(allowed2)} order=${kq.status} ${kq.body?.code} ${JSON.stringify(kq.body?.errors?.[0]?.rule ?? '')}`,
    );
  } finally {
    await db.end().catch(() => undefined);
  }
  const failed = results.filter((x) => !x).length;
  log(`pos-smoke итог: ${results.length - failed}/${results.length} PASS (на фикстурах, не реальная интеграция)`);
  return failed === 0;
}

/**
 * Этап G: загрузка мира кассира через настоящий pos-worker — администратор синхронизации (OTP → PIN → step-up
 * `sync.run.full`) запускает `POST /sync/runs` `customers` (план обмена фейка 1С в режиме кассира: клиенты, соглашения,
 * правила скидок, реализации, оплаты, документы возврата) и `receivables` (снимки долга активных клиентов) и ждёт их
 * завершения. **Тестовые данные, не реальная интеграция.**
 */
async function loadCashierWorld(stack) {
  const admin = await staffSession(AUTH_FIXTURES.syncAdmin, CASHIER_SYNC_ADMIN_PIN);
  if (!admin.ok) throw new Error('cashier-fixtures: вход администратора синхронизации не удался');
  const A = { token: admin.token, deviceId: admin.deviceId };
  const runs = {};
  for (const entity of ['customers', 'receivables']) {
    const su = await apiF('POST', '/auth/step-up', {
      ...A,
      body: { method: 'pin', operation: 'sync.run.full', pin: CASHIER_SYNC_ADMIN_PIN },
    });
    const start = await apiF('POST', '/sync/runs', {
      ...A,
      idem: true,
      stepUp: su.body?.stepUpToken,
      body: { entity, mode: 'incremental' },
    });
    if (start.status !== 202) {
      throw new Error(`cashier-fixtures: POST /sync/runs ${entity} → ${start.status} ${start.body?.code ?? ''}`);
    }
    const fin = await until(
      () => apiF('GET', `/sync/runs/${start.body.id}`, A),
      (x) => ['success', 'partial', 'failed'].includes(x.body?.status),
      180_000,
      1000,
    );
    runs[entity] = { status: fin.body?.status ?? null, counts: fin.body?.counts ?? null };
    log(`cashier-fixtures: sync ${entity} → ${fin.body?.status} ${JSON.stringify(fin.body?.counts ?? {})}`);
  }
  const db = new pg.Client({ connectionString: stack.dbUrl });
  await db.connect();
  try {
    const counts = (
      await db.query(
        `SELECT (SELECT count(*)::int FROM customers WHERE source = 'onec') AS customers,
                (SELECT count(*)::int FROM receivables) AS receivables,
                (SELECT count(*)::int FROM shipments) AS shipments,
                (SELECT count(*)::int FROM discount_rules) AS discounts`,
      )
    ).rows[0];
    log(
      `cashier-fixtures: клиентов 1С ${counts.customers}, снимков долга ${counts.receivables}, реализаций ${counts.shipments}, правил скидок ${counts.discounts} (тестовые данные)`,
    );
    return { runs, counts, admin: A };
  } finally {
    await db.end().catch(() => undefined);
  }
}

/**
 * Этап G (только dev, `serve --cashier-fixtures`, integration_test pos-app): «отгрузка» заказа [orderId] для заявки на
 * возврат — `orders.status = shipped` + реализация 1С (`shipments`/`shipment_items`, первая строка заказа), как
 * ускорение в `cashierSmoke`. Сама отгрузка — RM-F/1С; **тестовые данные, не реальная интеграция.** Вызов — управляющий
 * HTTP `POST /__stack/ship/{orderId}` ([startCashierControl]).
 */
async function shipOrderForTest(dbUrl, orderId) {
  const db = new pg.Client({ connectionString: dbUrl });
  await db.connect();
  try {
    await db.query('BEGIN');
    const upd = await db.query(`UPDATE orders SET status = 'shipped', shipped_at = now() WHERE id = $1 RETURNING id`, [
      orderId,
    ]);
    if (upd.rowCount !== 1) throw new Error('заказ не найден');
    const ship = await db.query(
      `INSERT INTO shipments (onec_ref, onec_code, onec_data_version, synced_at, source_hash, onec_doc_type, onec_date,
                              posted, order_id, customer_id, warehouse_id, total, discount_total, returned_total)
       SELECT gen_random_uuid(), 'РТ-E2E-' || left(o.id::text, 8), 'AAAAAQ==', now(), 'local-stack',
              'Document_РеализацияТоваровУслуг', now(), true, o.id, o.customer_id,
              (SELECT id FROM warehouses WHERE is_active AND NOT deletion_mark ORDER BY is_default_for_pos DESC, id LIMIT 1),
              o.total, 0, 0
         FROM orders o WHERE o.id = $1
       RETURNING id`,
      [orderId],
    );
    await db.query(
      `INSERT INTO shipment_items (shipment_id, onec_line_no, variant_id, product_name_snapshot, quantity, base_quantity,
                                   unit_price, line_total, discount_amount, returned_quantity, synced_at, source_hash)
       SELECT $1, 1, oi.variant_id, oi.product_name_snapshot, oi.quantity, oi.quantity, oi.unit_price, oi.line_total, 0, 0,
              now(), 'local-stack'
         FROM order_items oi WHERE oi.order_id = $2 ORDER BY oi.line_no LIMIT 1`,
      [ship.rows[0].id, orderId],
    );
    // Проекция отгрузки в строку заказа (`order_items.shipped_quantity` — как синхронизация реализации 1С): лимит
    // возврата SCR-39 = «отгружено − возвращено».
    await db.query(
      `UPDATE order_items SET shipped_quantity = quantity
        WHERE order_id = $1 AND line_no = (SELECT min(line_no) FROM order_items WHERE order_id = $1)`,
      [orderId],
    );
    await db.query('COMMIT');
    return ship.rows[0].id;
  } catch (e) {
    await db.query('ROLLBACK').catch(() => undefined);
    throw e;
  } finally {
    await db.end().catch(() => undefined);
  }
}

/**
 * Управляющий HTTP стенда кассира (только dev, `serve --cashier-fixtures`; `127.0.0.1:LOCAL_STACK_CONTROL_PORT`,
 * по умолчанию 8092; не проксируется в API): `POST /__stack/ship/{orderId}` → 200 `{orderId, shipmentId}` — «отгрузка»
 * заказа для заявки на возврат ([shipOrderForTest]); ошибка — 409 `{error}`.
 */
async function startCashierControl(stack) {
  if (!(await portIsFree(CONTROL_PORT))) throw new Error(`порт ${CONTROL_PORT} занят (LOCAL_STACK_CONTROL_PORT)`);
  stack.control = createHttpServer((req, res) => {
    const m = /^\/__stack\/ship\/([0-9a-f-]{36})$/i.exec((req.url ?? '/').split('?')[0]);
    const reply = (code, body) => {
      res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify(body));
    };
    if (req.method !== 'POST' || !m) return reply(404, { error: 'not found' });
    shipOrderForTest(stack.dbUrl, m[1]).then(
      (shipmentId) => {
        log(`control: заказ ${m[1]} «отгружен» (тестовые данные)`);
        reply(200, { orderId: m[1], shipmentId });
      },
      (e) => reply(409, { error: e instanceof Error ? e.message : String(e) }),
    );
  });
  await new Promise((resolve) => stack.control.listen(CONTROL_PORT, '127.0.0.1', resolve));
  log(`control http://127.0.0.1:${CONTROL_PORT}: POST /__stack/ship/{orderId} (только dev, тестовые данные)`);
}

/**
 * Этап G на настоящих процессах (интеграция backend этапа G, RM-G-009): pos-api + pos-worker + управляемый фейк
 * HTTP-сервиса 1С в режиме кассира. Мир кассира загружается синхронизацией (`loadCashierWorld`). Сценарии: поиск
 * клиента и область поиска продавца; долг (сводка, field-level), история, правила скидок; продажа в долг клиенту с
 * просрочкой → `CREDIT_BLOCKED` → разрешение старшего со step-up → оплата наличными → журнал транзакций → аудит и
 * проверка цепочки (`scripts/verify_audit_chain.ts`); создание клиента → outbox → pos-worker → 1С → `onec_ref`;
 * возврат draft → submit → accept / reject; отчёты сходятся с журналом и снимками; дашборд; режим клиента
 * (регистрация → `proposed` → самоподтверждение → своя карточка и долг; чужая — 404; кассовые операции — 403).
 * **На фикстурах, не реальная интеграция.** Ускорение: отгрузка заказа для возврата записывается в БД стека
 * (`orders.status = shipped` + реализация 1С) — только тест; сама отгрузка — RM-F/1С.
 */
async function cashierSmoke(stack, sku, world) {
  const results = [];
  const check = (name, ok, detail) => {
    results.push(Boolean(ok));
    log(`${ok ? 'PASS' : 'FAIL'} ${name} — ${detail}`);
  };
  const db = new pg.Client({ connectionString: stack.dbUrl });
  await db.connect();
  const q = async (sql, params = []) => (await db.query(sql, params)).rows;
  const idOf = async (ref) => (await q(`SELECT id FROM customers WHERE onec_ref = $1`, [ref]))[0]?.id ?? null;
  const fromIso = new Date(Date.now() - 86_400_000).toISOString();
  const toIso = new Date(Date.now() + 86_400_000).toISOString();
  const period = `from=${encodeURIComponent(fromIso)}&to=${encodeURIComponent(toIso)}`;
  try {
    const c = world.counts;
    check(
      'мир кассира: синхронизация customers и receivables pos-worker из плана обмена фейка 1С',
      world.runs.customers?.status === 'success' &&
        ['success', 'partial'].includes(world.runs.receivables?.status) &&
        c.customers >= 30 &&
        c.receivables >= 8 &&
        c.shipments >= 10 &&
        c.discounts >= 1,
      `customers=${world.runs.customers?.status} receivables=${world.runs.receivables?.status} counts=${JSON.stringify(c)}`,
    );
    const overdue = await idOf(CASHIER_REFS.overdue);
    const buyer = await idOf(CASHIER_REFS.buyer);
    const within = await idOf(CASHIER_REFS.debtWithinLimit);
    const variants = await q(
      `SELECT v.id AS "variantId", p.base_unit_id AS "unitId"
         FROM product_variants v
         JOIN products p ON p.id = v.product_id
         JOIN units u ON u.id = p.base_unit_id
         JOIN prices pr ON pr.variant_id = v.id AND pr.packaging_id IS NULL
          AND pr.price_list_id = (SELECT id FROM price_lists WHERE is_default AND NOT deletion_mark ORDER BY sort_order, id LIMIT 1)
         JOIN stock_balances sb ON sb.variant_id = v.id
          AND sb.warehouse_id = (SELECT id FROM warehouses WHERE is_active AND NOT deletion_mark
                                  ORDER BY is_default_for_pos DESC, sort_order, name, id LIMIT 1)
        WHERE NOT v.deletion_mark AND NOT p.deletion_mark AND p.is_sellable AND v.is_default = NOT p.has_variants
          AND sb.available > 10 AND pr.price > 0 AND pr.price <= 3000 AND u.qty_precision = 0
        ORDER BY p.name, v.id LIMIT 4`,
    );
    check(
      `каталог (${sku} SKU) и сценарные клиенты в реплике`,
      variants.length >= 2 && overdue && buyer && within,
      `вариантов=${variants.length} overdue=${overdue} buyer=${buyer} debtWithinLimit=${within}`,
    );

    const seller = await staffSession(AUTH_FIXTURES.invitedStaff, '582914');
    const cashier = await staffSession(AUTH_FIXTURES.cashier, '715382');
    const senior = await staffSession(AUTH_FIXTURES.seniorSeller, '826493');
    check(
      'сессии: seller, cashier, senior_seller',
      seller.ok && cashier.ok && senior.ok,
      `seller=${seller.ok} cashier=${cashier.ok} senior=${senior.ok}`,
    );
    const S = { token: seller.token, deviceId: seller.deviceId };
    const C = { token: cashier.token, deviceId: cashier.deviceId };
    const SS = { token: senior.token, deviceId: senior.deviceId };
    const A = world.admin;

    // 1. Поиск, долг, история, скидки.
    let r = await apiF('GET', '/search/customers?q=3344', C);
    const rs = await apiF('GET', '/search/customers?q=3344', S);
    check(
      'GET /search/customers: кассир — по 4 цифрам телефона; продавец — только полный номер (400 search_scope_role)',
      r.status === 200 &&
        (r.body?.items ?? []).some((x) => x.id === overdue) &&
        rs.status === 400 &&
        JSON.stringify(rs.body).includes('search_scope_role'),
      `cashier=${r.status} found=${(r.body?.items ?? []).length} seller=${rs.status} ${rs.body?.code ?? ''}`,
    );
    r = await apiF('GET', `/customers/${overdue}/receivables`, C);
    const rsel = await apiF('GET', `/customers/${overdue}/receivables`, S);
    check(
      'GET /customers/{id}/receivables: снимок 1С (просрочка 8000.00, свежий); seller → 403 (Q-017)',
      r.status === 200 &&
        r.body?.overdueAmount?.amount === '8000.00' &&
        r.body?.isStale === false &&
        rsel.status === 403,
      `cashier=${r.status} overdue=${JSON.stringify(r.body?.overdueAmount)} stale=${r.body?.isStale} seller=${rsel.status}`,
    );
    r = await apiF('GET', `/customers/${buyer}/orders?limit=200`, C);
    check(
      'GET /customers/{id}/orders: история из реализаций 1С (shipments) в глубине SALES_HISTORY_MONTHS',
      r.status === 200 && (r.body?.items ?? []).length > 0 && typeof r.body?.historyFrom === 'string',
      `${r.status} items=${(r.body?.items ?? []).length} historyFrom=${r.body?.historyFrom}`,
    );
    r = await apiF('GET', '/discounts/rules', C);
    check(
      'GET /discounts/rules: правила 1С и лимит роли',
      r.status === 200 && Array.isArray(r.body?.rules) && typeof r.body?.manualDiscountLimitPercent === 'string',
      `${r.status} rules=${(r.body?.rules ?? []).length} limit=${r.body?.manualDiscountLimitPercent}`,
    );

    // 2. Продажа в долг клиенту с просрочкой → CREDIT_BLOCKED; разрешение старшего со step-up; оплата наличными.
    const [v0, v1] = variants;
    let cart = (await fillCart(C, v0, '1')).cart;
    await apiF('POST', '/cart/customer', { ...C, body: { customerId: overdue, rowVersion: cart?.rowVersion } });
    cart = (await apiF('GET', '/cart', C)).body;
    r = await apiF('POST', '/orders', { ...C, idem: true, body: orderBody(cart, v0, '1', 'credit') });
    check(
      'POST /orders credit клиенту с просрочкой → 422 CREDIT_BLOCKED (creditReason=overdue), без 503',
      r.status === 422 && r.body?.code === 'CREDIT_BLOCKED' && r.body?.creditReason === 'overdue',
      `${r.status} ${r.body?.code} ${r.body?.creditReason ?? ''}`,
    );
    let sc = (await fillCart(SS, v1, '1')).cart;
    await apiF('POST', '/cart/customer', { ...SS, body: { customerId: overdue, rowVersion: sc?.rowVersion } });
    sc = (await apiF('GET', '/cart', SS)).body;
    const ob = { ...orderBody(sc, v1, '1', 'credit'), creditOverride: { reason: 'согласовано с руководителем' } };
    const noStep = await apiF('POST', '/orders', { ...SS, idem: true, body: ob });
    const su = await apiF('POST', '/auth/step-up', {
      ...SS,
      body: { method: 'pin', operation: 'credit.sale.approve', pin: '826493' },
    });
    const approved = await apiF('POST', '/orders', { ...SS, idem: true, stepUp: su.body?.stepUpToken, body: ob });
    const creditOrderId = approved.body?.id ?? null;
    const creditTx = creditOrderId
      ? await q(`SELECT kind::text AS kind FROM transactions WHERE order_id = $1`, [creditOrderId])
      : [];
    const approvedAudit = creditOrderId
      ? await q(`SELECT step_up_method FROM audit_logs WHERE action = 'credit.sale_approved' AND entity_id = $1`, [
          creditOrderId,
        ])
      : [];
    check(
      'разрешение старшего: без step-up → 403 STEP_UP_REQUIRED; со step-up (PIN) → заказ в долг, transactions credit_sale_approved, аудит credit.sale_approved (pin)',
      noStep.status === 403 &&
        noStep.body?.code === 'STEP_UP_REQUIRED' &&
        [201, 202].includes(approved.status) &&
        creditTx.some((x) => x.kind === 'credit_sale_approved') &&
        approvedAudit.length === 1 &&
        approvedAudit[0].step_up_method === 'pin',
      `noStep=${noStep.status} ${noStep.body?.code} order=${approved.status} ${approved.body?.code ?? ''} tx=${creditTx.map((x) => x.kind).join(',')} audit=${approvedAudit.length}`,
    );
    cart = (await apiF('GET', '/cart', C)).body;
    const cashOrder = await apiF('POST', '/orders', { ...C, idem: true, body: orderBody(cart, v0, '1', 'cash') });
    const cashId = cashOrder.body?.id ?? null;
    const pay = await apiF('POST', `/orders/${cashId}/payments`, {
      ...C,
      idem: true,
      body: { method: 'cash', receivedAmount: { amount: cashOrder.body?.total?.amount, currency: 'KGS' } },
    });
    check(
      'оплата: кассир меняет способ на наличные (FLOW-024.S2) → заказ → POST /orders/{id}/payments → received',
      [201, 202].includes(cashOrder.status) && [200, 201].includes(pay.status) && pay.body?.status === 'received',
      `order=${cashOrder.status} ${cashOrder.body?.code ?? ''} pay=${pay.status} ${pay.body?.status ?? pay.body?.code}`,
    );

    // 3. Создание клиента → outbox → pos-worker → 1С.
    const cc = await apiF('POST', '/customers', {
      ...C,
      idem: true,
      body: { name: 'Новый Клиент Кассы', customerType: 'individual', phones: ['+996555777001'] },
    });
    const newId = cc.body?.id ?? null;
    const row = await until(
      async () => (await q(`SELECT onec_status::text AS s, onec_ref FROM customers WHERE id = $1`, [newId]))[0] ?? null,
      (x) => x?.s === 'confirmed',
      90_000,
      1000,
    );
    const calls = (await fakeOnec('GET', '/__fake/state')).body?.calls ?? [];
    check(
      'POST /customers → 201 pending → outbox → pos-worker → POST /pos/v1/customers фейка 1С → onec_ref, confirmed',
      cc.status === 201 &&
        cc.body?.onecStatus === 'pending' &&
        row?.s === 'confirmed' &&
        row?.onec_ref !== null &&
        calls.some((x) => x.method === 'POST' && x.path === '/pos/v1/customers' && x.status === 201),
      `create=${cc.status} ${cc.body?.onecStatus ?? cc.body?.code} db=${row?.s} ref=${row?.onec_ref ?? null}`,
    );

    // 4. Возврат: draft → submit (step-up) → accept / reject старшим (step-up). Отгрузка — ускорение в БД стека.
    await q(`UPDATE orders SET status = 'shipped', shipped_at = now() WHERE id = $1`, [cashId]);
    const ship = await q(
      `INSERT INTO shipments (onec_ref, onec_code, onec_data_version, synced_at, source_hash, onec_doc_type, onec_date,
                              posted, order_id, customer_id, warehouse_id, total, discount_total, returned_total)
       SELECT gen_random_uuid(), 'РТ-SMOKE-1', 'AAAAAQ==', now(), 'local-stack', 'Document_РеализацияТоваровУслуг', now(),
              true, o.id, o.customer_id,
              (SELECT id FROM warehouses WHERE is_active AND NOT deletion_mark ORDER BY is_default_for_pos DESC, id LIMIT 1),
              o.total, 0, 0
         FROM orders o WHERE o.id = $1
       RETURNING id`,
      [cashId],
    );
    await q(
      `INSERT INTO shipment_items (shipment_id, onec_line_no, variant_id, product_name_snapshot, quantity, base_quantity,
                                   unit_price, line_total, discount_amount, returned_quantity, synced_at, source_hash)
       SELECT $1, 1, oi.variant_id, oi.product_name_snapshot, oi.quantity, oi.quantity, oi.unit_price, oi.line_total, 0, 0,
              now(), 'local-stack'
         FROM order_items oi WHERE oi.order_id = $2 ORDER BY oi.line_no LIMIT 1`,
      [ship[0]?.id, cashId],
    );
    const retBody = {
      orderId: cashId,
      reasonCode: 'defect',
      items: [{ orderLineNo: 1, quantity: { value: '1', unitId: v0.unitId, packagingId: null } }],
    };
    const submitReturn = async () => {
      const d = await apiF('POST', '/returns', { ...C, idem: true, body: retBody });
      const s1 = await apiF('POST', '/auth/step-up', {
        ...C,
        body: { method: 'pin', operation: 'return.submit', pin: '715382' },
      });
      const sub = await apiF('POST', `/returns/${d.body?.id}/submit`, {
        ...C,
        idem: true,
        stepUp: s1.body?.stepUpToken,
        body: { rowVersion: d.body?.rowVersion },
      });
      return { d, sub };
    };
    const first = await submitReturn();
    const s2 = await apiF('POST', '/auth/step-up', {
      ...SS,
      body: { method: 'pin', operation: 'return.approve', pin: '826493' },
    });
    const acc = await apiF('POST', `/returns/${first.sub.body?.id}/accept`, {
      ...SS,
      idem: true,
      stepUp: s2.body?.stepUpToken,
      body: { rowVersion: first.sub.body?.rowVersion },
    });
    const rejectFirst = await apiF('POST', `/returns/${first.sub.body?.id}/reject`, {
      ...SS,
      idem: true,
      stepUp: s2.body?.stepUpToken,
      body: { rowVersion: acc.body?.rowVersion, reason: 'Повторный осмотр: дефекта нет' },
    });
    check(
      'возврат 1: draft 201 → submit (step-up) submitted → accept старшим (step-up) accepted → reject (принят в POS) rejected',
      first.d.status === 201 &&
        first.sub.body?.status === 'submitted' &&
        acc.status === 200 &&
        acc.body?.status === 'accepted' &&
        rejectFirst.status === 200 &&
        rejectFirst.body?.status === 'rejected',
      `draft=${first.d.status} ${first.d.body?.code ?? ''} submit=${first.sub.status} ${first.sub.body?.code ?? first.sub.body?.status} ${first.sub.body?.reason ?? ''} accept=${acc.status} ${acc.body?.status ?? acc.body?.code} reject=${rejectFirst.status} ${rejectFirst.body?.status ?? rejectFirst.body?.code}`,
    );
    const second = await submitReturn();
    const rej = await apiF('POST', `/returns/${second.sub.body?.id}/reject`, {
      ...SS,
      idem: true,
      stepUp: s2.body?.stepUpToken,
      body: { rowVersion: second.sub.body?.rowVersion, reason: 'Товар без дефекта по результатам осмотра' },
    });
    const retTx = await q(
      `SELECT count(*)::int AS n FROM transactions WHERE kind = 'return_requested' AND return_request_id = ANY($1::uuid[])`,
      [[first.sub.body?.id, second.sub.body?.id].filter(Boolean)],
    );
    check(
      'возврат 2: submit → reject старшим; журнал: return_requested по каждой заявке; outbox в 1С нет (RETURNS_FROM_POS_ENABLED=false)',
      second.sub.body?.status === 'submitted' &&
        rej.status === 200 &&
        rej.body?.status === 'rejected' &&
        retTx[0]?.n === 2,
      `submit=${second.sub.status} reject=${rej.status} ${rej.body?.status ?? rej.body?.code} return_requested=${retTx[0]?.n}`,
    );

    // 5. Журнал транзакций, аудит (цепочка), отчёты, дашборд.
    r = await apiF('GET', `/transactions?${period}&limit=200`, A);
    const kinds = new Set((r.body?.items ?? []).map((x) => x.kind));
    check(
      'GET /transactions (admin): order_created, credit_sale_approved, payment_received, return_requested; summary',
      r.status === 200 &&
        ['order_created', 'credit_sale_approved', 'payment_received', 'return_requested'].every((k) => kinds.has(k)) &&
        r.body?.summary !== undefined,
      `${r.status} kinds=${[...kinds].sort().join(',')} summary=${JSON.stringify(r.body?.summary ?? null)}`,
    );
    const rsTx = await apiF('GET', `/transactions?${period}&limit=200`, S);
    check(
      'GET /transactions (seller): только свои, без summary',
      rsTx.status === 200 && rsTx.body?.summary === undefined && (rsTx.body?.items ?? []).length === 0,
      `${rsTx.status} items=${(rsTx.body?.items ?? []).length}`,
    );
    r = await apiF('GET', `/admin/audit-logs?${period}&limit=200`, A);
    const rows = r.body?.items ?? [];
    const found = {};
    for (const action of [
      'credit.sale_blocked',
      'credit.sale_approved',
      'payment.received',
      'customer.created',
      'return.submitted',
      'return.status_changed',
    ]) {
      const one = await apiF('GET', `/admin/audit-logs?${period}&action=${encodeURIComponent(action)}&limit=5`, A);
      found[action] = (one.body?.items ?? []).filter((x) => x.action === action && x.chainOk === true).length;
    }
    check(
      'GET /admin/audit-logs: credit.sale_blocked, credit.sale_approved, payment.received, customer.created, return.submitted, return.status_changed; chainOk у всех строк',
      r.status === 200 &&
        rows.length > 0 &&
        rows.every((x) => x.chainOk === true) &&
        Object.values(found).every((n) => n > 0),
      `${r.status} rows=${rows.length} chainOk=${rows.every((x) => x.chainOk === true)} found=${JSON.stringify(found)}`,
    );
    const verify = await stack.runNode('--import', ['tsx', 'scripts/verify_audit_chain.ts']);
    check(
      'scripts/verify_audit_chain.ts (DATABASE_URL_FILE) → код 0: цепочка и якоря аудита целы',
      verify.code === 0,
      `код ${verify.code}: ${verify.out.trim().split('\n').slice(-1)[0] ?? ''}`,
    );
    r = await apiF('GET', `/admin/reports/sales-summary?${period}`, A);
    const [dbSales] = await q(
      `SELECT coalesce(sum(t.amount), 0)::numeric(14,2)::text AS total, count(*)::int AS n
         FROM transactions t JOIN orders o ON o.id = t.order_id
        WHERE t.kind = 'order_created' AND o.status NOT IN ('draft', 'cancelled', 'submit_failed')
          AND o.created_at >= $1 AND o.created_at < $2`,
      [fromIso, toIso],
    );
    check(
      'GET /admin/reports/sales-summary: итог = Σ order_created журнала transactions (заказы периода без отмен)',
      r.status === 200 &&
        r.body?.totals?.ordersTotal?.amount === dbSales.total &&
        r.body?.totals?.ordersCount === dbSales.n,
      `${r.status} report=${r.body?.totals?.ordersTotal?.amount}/${r.body?.totals?.ordersCount} journal=${dbSales.total}/${dbSales.n}`,
    );
    r = await apiF('GET', '/admin/reports/receivables', A);
    const [dbRecv] = await q(
      `SELECT coalesce(sum(r.balance) FILTER (WHERE r.balance > 0), 0)::numeric(14,2)::text AS total
         FROM receivables r JOIN customers c ON c.id = r.customer_id WHERE NOT c.deletion_mark`,
    );
    check(
      'GET /admin/reports/receivables: итог = Σ положительных сальдо снимков 1С',
      r.status === 200 && r.body?.totalBalance?.amount === dbRecv.total,
      `${r.status} report=${r.body?.totalBalance?.amount} db=${dbRecv.total}`,
    );
    r = await apiF('GET', '/pos/dashboard', C);
    const rd = await apiF('GET', '/pos/dashboard', S);
    check(
      'GET /pos/dashboard: кассир → 200; продавец → 403',
      r.status === 200 && rd.status === 403,
      `cashier=${r.status} seller=${rd.status}`,
    );

    // 6. Режим клиента: регистрация по телефону клиента 1С → proposed → самоподтверждение → своя карточка и долг.
    const dev = randomUUID();
    const { verify: v } = await otpLogin(AUTH_FIXTURES.cashierCustomerLinked, dev);
    const reg = await api('POST', '/registration/complete', {
      deviceId: dev,
      idem: true,
      body: {
        registrationToken: v?.body?.registrationToken, // check-secrets: allow — имя поля, не секрет
        fullName: 'Асанов Бакыт',
        birthYear: 1988,
        security: { pin: '583921' },
        consents: SMOKE_CONSENTS,
        device: SMOKE_DEVICE,
      },
    });
    let K = { token: reg.body?.accessToken, deviceId: dev }; // check-secrets: allow — имя поля, не секрет
    const match = await apiF('GET', '/registration/customer-match', K);
    const conf = await apiF('POST', '/registration/customer-match/confirm', {
      ...K,
      body: { linkId: match.body?.linkId },
    });
    let own = await apiF('GET', `/customers/${within}`, K);
    if (own.status === 401) {
      const again = await relogin(AUTH_FIXTURES.cashierCustomerLinked);
      K = { token: again.token, deviceId: again.deviceId };
      own = await apiF('GET', `/customers/${within}`, K);
    }
    check(
      'режим клиента: регистрация по телефону клиента 1С → proposed → самоподтверждение → confirmed',
      reg.status === 201 &&
        match.body?.status === 'proposed' &&
        conf.status === 200 &&
        conf.body?.status === 'confirmed',
      `reg=${reg.status} ${reg.body?.code ?? ''} match=${match.status} ${match.body?.status} confirm=${conf.status} ${conf.body?.status ?? conf.body?.code}`,
    );
    const ownRecv = await apiF('GET', `/customers/${within}/receivables`, K);
    const foreign = await apiF('GET', `/customers/${overdue}`, K);
    const txK = await apiF('GET', `/transactions?${period}`, K);
    const dashK = await apiF('GET', '/pos/dashboard', K);
    check(
      'режим клиента: своя карточка и долг → 200; чужая карточка → 404; журнал транзакций и дашборд → 403',
      own.status === 200 &&
        ownRecv.status === 200 &&
        ownRecv.body?.customerId === within &&
        foreign.status === 404 &&
        txK.status === 403 &&
        dashK.status === 403,
      `own=${own.status} receivables=${ownRecv.status} foreign=${foreign.status} transactions=${txK.status} dashboard=${dashK.status}`,
    );
  } finally {
    await db.end().catch(() => undefined);
  }
  const failed = results.filter((x) => !x).length;
  log(`cashier-smoke итог: ${results.length - failed}/${results.length} PASS (на фикстурах, не реальная интеграция)`);
  return failed === 0;
}

/** `--catalog-fixtures` или `--catalog-fixtures=N` → N (по умолчанию 500); нет флага → undefined. */
function catalogFixturesArg() {
  const a = args.find((x) => x === '--catalog-fixtures' || x.startsWith('--catalog-fixtures='));
  if (!a) return undefined;
  const v = a.includes('=') ? Number(a.slice(a.indexOf('=') + 1)) : CATALOG_SKU_DEFAULT;
  if (!Number.isInteger(v) || v < 0) throw new Error('--catalog-fixtures=N: N — целое ≥ 0');
  return v;
}

async function main() {
  if (!['smoke', 'serve', 'auth-smoke', 'catalog-smoke', 'pos-smoke', 'cashier-smoke'].includes(mode)) {
    process.stderr.write(
      'usage: node scripts/local-stack.mjs smoke | auth-smoke | catalog-smoke [--catalog-fixtures=N] | pos-smoke [--catalog-fixtures=N] | cashier-smoke [--catalog-fixtures=N] | serve [--ready-file <path>] [--ttl <sec>] [--auth-fixtures] [--catalog-fixtures[=N]] [--pos-fixtures | --cashier-fixtures [--qr-provider onec|none] [--qr-paid-after-polls N]]\n',
    );
    process.exit(2);
  }
  let catalogSku;
  try {
    catalogSku = catalogFixturesArg();
  } catch (e) {
    process.stderr.write(`${e.message}\n`);
    process.exit(2);
  }
  const stack = new Stack();
  let stopping = false;
  const shutdown = async (code) => {
    if (stopping) return;
    stopping = true;
    await stack.stop();
    process.exit(code);
  };
  process.on('SIGINT', () => void shutdown(0));
  process.on('SIGTERM', () => void shutdown(0));
  try {
    await stack.startDb();
    await stack.migrate(false);
    await stack.migrate(true);
    await stack.migrate(true); // повтор — 0 изменений (RM-C-006 п. 4)
    if (mode === 'smoke') {
      const ok = await smoke(stack);
      await shutdown(ok ? 0 : 1);
      return;
    }
    if (mode === 'auth-smoke') {
      await stack.insertAuthFixtures();
      await stack.startApi();
      const ok = await authSmoke();
      await shutdown(ok ? 0 : 1);
      return;
    }
    if (mode === 'catalog-smoke') {
      const sku = catalogSku ?? CATALOG_SKU_DEFAULT;
      await stack.loadCatalog(sku);
      await stack.insertAuthFixtures();
      await stack.startApi();
      await stack.startMediaProxy();
      const ok = await catalogSmoke(stack, sku);
      await shutdown(ok ? 0 : 1);
      return;
    }
    if (mode === 'pos-smoke') {
      const sku = catalogSku ?? 200;
      await stack.loadCatalog(sku);
      await stack.insertAuthFixtures();
      await stack.startFakeOnec(2);
      await stack.startApi(stack.posEnv);
      await stack.startWorker({ OUTBOX_MAX_ATTEMPTS: '2' });
      const ok = await posSmoke(stack, sku);
      await shutdown(ok ? 0 : 1);
      return;
    }
    if (mode === 'cashier-smoke') {
      const sku = catalogSku ?? 200;
      await stack.loadCatalog(sku);
      await stack.insertAuthFixtures();
      await stack.insertCashierFixtures();
      await stack.startFakeOnec(2, { sku });
      await stack.startApi(stack.posEnv);
      await stack.startWorker();
      const world = await loadCashierWorld(stack);
      const ok = await cashierSmoke(stack, sku, world);
      await shutdown(ok ? 0 : 1);
      return;
    }
    const cashierFixtures = args.includes('--cashier-fixtures');
    const posFixtures = args.includes('--pos-fixtures') || cashierFixtures;
    const serveSku = catalogSku ?? (posFixtures ? CATALOG_SKU_DEFAULT : undefined);
    if (serveSku !== undefined) await stack.loadCatalog(serveSku);
    if (args.includes('--auth-fixtures') || posFixtures) await stack.insertAuthFixtures();
    if (cashierFixtures) await stack.insertCashierFixtures();
    if (posFixtures) {
      const qrProvider = opt('--qr-provider') ?? 'onec';
      if (!['onec', 'none'].includes(qrProvider)) throw new Error('--qr-provider: onec | none');
      await stack.startFakeOnec(
        Number(opt('--qr-paid-after-polls') ?? '2'),
        cashierFixtures ? { sku: serveSku ?? CATALOG_SKU_DEFAULT } : null,
      );
      stack.posEnv = { ...stack.posEnv, QR_PROVIDER: qrProvider };
      await stack.startApi(stack.posEnv);
      await stack.startWorker();
      if (cashierFixtures) {
        await loadCashierWorld(stack);
        await startCashierControl(stack);
      }
    } else {
      await stack.startApi();
    }
    if (serveSku !== undefined) await stack.startMediaProxy();
    const readyFile = opt('--ready-file');
    if (readyFile) writeFileSync(readyFile, `${BASE_URL}\n`);
    log(
      `READY ${BASE_URL}${stack.proxy ? ` (фото и API через ${PROXY_URL})` : ''} (журнал API: ${stack.apiLog}); Ctrl+C — остановка`,
    );
    if (posFixtures) {
      log(
        `POS-FIXTURES: pos-worker (журнал ${stack.workerLog}), фейк 1С ${ONEC_FAKE_URL}/ut11/hs, управление ${ONEC_FAKE_URL}/__fake/state (тестовые данные)`,
      );
    }
    if (cashierFixtures) {
      log(
        `CASHIER-FIXTURES: мир кассира загружен синхронизацией; сценарные клиенты — ${ONEC_FAKE_URL}/__fake/cashier/state; администратор синхронизации ${AUTH_FIXTURES.syncAdmin} (PIN ${CASHIER_SYNC_ADMIN_PIN}, тестовые данные)`,
      );
    }
    const ttl = Number(opt('--ttl') ?? '0');
    if (ttl > 0) setTimeout(() => void shutdown(0), ttl * 1000);
    if (args.includes('--exit-on-stdin-end')) {
      process.stdin.on('end', () => void shutdown(0));
      process.stdin.resume();
    } else {
      setInterval(() => undefined, 60_000);
    }
    stack.api.on('exit', (code) => {
      if (stopping) return; // штатная остановка (Ctrl+C, SIGTERM, --ttl)
      log(`pos-api неожиданно завершился (код ${code})`);
      void shutdown(1);
    });
  } catch (e) {
    process.stderr.write(`[local-stack] ОШИБКА: ${e instanceof Error ? e.message : String(e)}\n`);
    await shutdown(1);
  }
}

await main();
