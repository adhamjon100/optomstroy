import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { Controller, Get, type INestApplication, Module, Post } from '@nestjs/common';
import { ApiExcludeController } from '@nestjs/swagger';
import { parse as parseYaml } from 'yaml';
import pg from 'pg';
import request from 'supertest';
import { createApp } from '../../src/bootstrap/create-app.js';
import { PgBossService } from '../../src/common/jobs/pg-boss.service.js';
import { Public } from '../../src/common/rbac/rbac.decorators.js';
import { ADR_083_ALLOWED_MUTATIONS } from '../../src/common/read-only/read-only.allowlist.js';
import { loadMigratorEnv } from '../../src/db/migrator-config.js';
import { run as runMigrate } from '../../src/migrate.js';
import { EmbeddedPg } from '../support/embedded-pg.js';
import { LogCapture, testConfig } from '../support/test-app.js';

/**
 * Smoke-набор тестового контура (RM-C-012; 16 §10.5 — минимум без мутаций). Два режима:
 *
 * 1. **Контур** (`SMOKE_BASE_URL` задан, например `https://localhost`): запросы идут через pos-proxy (Caddy) к
 *    контейнерам `infra/compose.test.yml`. Доверие к внутреннему CA Caddy — через `NODE_EXTRA_CA_CERTS`
 *    (`make test-smoke`, job `test-contour` CI). Проверяются и свойства proxy: HTTPS-редирект, заголовки, 404.
 * 2. **В процессе** (по умолчанию): PostgreSQL 17 — сервис CI (`E2E_DATABASE_URL` = строка подключения
 *    суперпользователя; создаётся и удаляется отдельная БД) или embedded (`test/support/embedded-pg.ts`, без
 *    Docker); миграции — настоящим мигратором `src/migrate.ts` (RM-C-006), дважды (второй прогон — 0 изменений).
 *
 * Тесты не создают и не меняют бизнес-данные: только чтение и отказные сценарии.
 */
const BASE_URL = process.env.SMOKE_BASE_URL?.replace(/\/+$/, '');
const HTTP_BASE_URL = process.env.SMOKE_HTTP_BASE_URL?.replace(/\/+$/, '') ?? BASE_URL?.replace(/^https:/, 'http:');
const ADMIN_DATABASE_URL = process.env.E2E_DATABASE_URL;
const VIA_PROXY = BASE_URL !== undefined && BASE_URL !== '';
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const CLIENT = { 'X-App-Version': '99.0.0', 'X-Platform': 'android' } as const;

interface SmokeResponse {
  readonly status: number;
  readonly headers: Readonly<Record<string, string | undefined>>;
  readonly body: unknown;
}
type SmokeGet = (path: string, headers?: Readonly<Record<string, string>>) => Promise<SmokeResponse>;

function parseBody(contentType: string | undefined, text: string): unknown {
  if (contentType !== undefined && /json/.test(contentType) && text !== '') return JSON.parse(text) as unknown;
  return text;
}

/** HTTP-клиент режима «контур»: fetch к pos-proxy без автоматического следования редиректам. */
function proxyClient(base: string): SmokeGet {
  return async (path, headers = {}) => {
    const res = await fetch(`${base}${path}`, { headers, redirect: 'manual' });
    const text = await res.text();
    const h: Record<string, string> = {};
    res.headers.forEach((v, k) => (h[k] = v));
    return { status: res.status, headers: h, body: parseBody(res.headers.get('content-type') ?? undefined, text) };
  };
}

/** HTTP-клиент режима «в процессе»: supertest к Nest-приложению. */
function inProcessClient(app: INestApplication): SmokeGet {
  return async (path, headers = {}) => {
    const res = await request(app.getHttpServer() as Parameters<typeof request>[0])
      .get(path)
      .set(headers);
    return { status: res.status, headers: res.headers, body: res.body as unknown };
  };
}

/** Изолированная БД режима «в процессе»: сервис postgres:17 CI или embedded PostgreSQL 17. */
class SmokeDatabase {
  private embedded: EmbeddedPg | undefined;
  private readonly name = `pos_smoke_${randomBytes(4).toString('hex')}`;
  private adminUrl = '';

  async start(): Promise<string> {
    if (ADMIN_DATABASE_URL !== undefined && ADMIN_DATABASE_URL !== '') {
      this.adminUrl = ADMIN_DATABASE_URL;
    } else {
      this.embedded = new EmbeddedPg();
      await this.embedded.start();
      this.adminUrl = this.embedded.url('postgres');
    }
    // builtin C.UTF-8 (PG17): lower() корректен для кириллицы (norm_search/name_norm, 07 §10.1).
    await this.admin(
      `CREATE DATABASE ${this.name} TEMPLATE template0 ENCODING 'UTF8' LOCALE_PROVIDER builtin BUILTIN_LOCALE 'C.UTF-8' LC_COLLATE 'C' LC_CTYPE 'C'`,
    );
    const url = new URL(this.adminUrl);
    url.pathname = `/${this.name}`;
    return url.toString();
  }

  async stop(): Promise<void> {
    if (this.adminUrl !== '')
      await this.admin(`DROP DATABASE IF EXISTS ${this.name} WITH (FORCE)`).catch(() => undefined);
    await this.embedded?.stop();
  }

  private async admin(sql: string): Promise<void> {
    const c = new pg.Client({ connectionString: this.adminUrl });
    await c.connect();
    try {
      await c.query(sql);
    } finally {
      await c.end();
    }
  }
}

async function waitReady(get: SmokeGet, timeoutMs: number): Promise<SmokeResponse> {
  const deadline = Date.now() + timeoutMs;
  let last: SmokeResponse | undefined;
  for (;;) {
    try {
      last = await get('/health/ready');
      if (last.status === 200) return last;
    } catch {
      // proxy или api ещё поднимаются — повтор
    }
    if (Date.now() > deadline) return last ?? { status: 0, headers: {}, body: 'нет ответа' };
    await new Promise((r) => setTimeout(r, 2_000));
  }
}

/**
 * Пробные мутации для проверки APP_READ_ONLY на полном AppModule и реальной БД (RM-C-005 п. 4): на этапе C
 * мутирующих маршрутов в приложении ещё нет (они появляются на этапах D–F), поэтому контроллер — тестовый.
 */
@Public()
@ApiExcludeController() // тестовый контроллер не попадает в экспорт OpenAPI (сверка с контрактом ниже)
@Controller()
class ReadOnlyProbeController {
  @Post('orders') createOrder(): { ok: boolean } {
    return { ok: true };
  }
  /** GET-проба для политики версий N/N−1/N−2 (RM-C-015 п. 5): 2xx при допустимой версии. */
  @Get('version-probe') versionProbe(): { ok: boolean } {
    return { ok: true };
  }
}

@Module({ controllers: [ReadOnlyProbeController] })
class ReadOnlyProbeModule {}

describe(`smoke тестового контура (${VIA_PROXY ? `через pos-proxy ${BASE_URL}` : 'в процессе, PostgreSQL 17'})`, () => {
  let get: SmokeGet;
  let app: INestApplication | undefined;
  let db: SmokeDatabase | undefined;
  let databaseUrl = '';
  const migrateRuns: { applied: readonly string[] }[] = [];

  beforeAll(async () => {
    if (VIA_PROXY) {
      get = proxyClient(BASE_URL);
      return;
    }
    db = new SmokeDatabase();
    databaseUrl = await db.start();
    const migratorEnv = loadMigratorEnv({ APP_ENV: 'dev', LOG_LEVEL: 'silent', DATABASE_URL: databaseUrl });
    migrateRuns.push(await runMigrate(migratorEnv, { seed: true }));
    migrateRuns.push(await runMigrate(migratorEnv, { seed: true }));
    app = await createApp(testConfig({ DATABASE_URL: databaseUrl, OPENAPI_PUBLIC: 'true' }), {
      logStream: new LogCapture(),
    });
    await app.get(PgBossService).start();
    get = inProcessClient(app);
  });

  afterAll(async () => {
    await app?.close();
    await db?.stop();
  });

  it('GET /health → 200 {status: ok}', async () => {
    const res = await get('/health');
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ status: 'ok' });
  });

  it('GET /health/ready → 200: БД и pg-boss готовы (миграции применены, worker-очереди доступны)', async () => {
    const res = await waitReady(get, VIA_PROXY ? 90_000 : 30_000);
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    expect(res.body).toMatchObject({ checks: { db: 'ok', worker: 'ok' } });
    expect(['ok', 'degraded']).toContain((res.body as { status: string }).status);
  });

  it('X-Request-Id клиента сохраняется сквозь proxy и api (эхо 08 §2.3, RM-C-010; C-MJ-04)', async () => {
    const sent = '3f2b8c1e-5d4a-4b6c-9e7f-0a1b2c3d4e5f';
    const res = await get('/health', { 'X-Request-Id': sent });
    expect(res.headers['x-request-id']).toBe(sent);
    const api = await get('/api/v1/__smoke_unknown__', { ...CLIENT, 'X-Request-Id': sent });
    expect(api.headers['x-request-id']).toBe(sent);
    expect(api.body).toMatchObject({ requestId: sent, instance: `urn:request:${sent}` });
  });

  it('каждый ответ несёт X-Request-Id (UUID) и заголовки безопасности', async () => {
    const res = await get('/health');
    expect(res.headers['x-request-id']).toMatch(UUID_RE);
    expect(res.headers['x-content-type-options']).toBe('nosniff');
    expect(res.headers['strict-transport-security']).toContain('max-age=');
    expect(res.headers['x-powered-by']).toBeUndefined();
  });

  it('GET /api/v1/openapi.json → 200, документ OpenAPI 3.0 (OPENAPI_PUBLIC=true на тестовом контуре)', async () => {
    const res = await get('/api/v1/openapi.json');
    expect(res.status).toBe(200);
    expect((res.body as { openapi?: string }).openapi).toMatch(/^3\.0\./);
  });

  it('неизвестный маршрут API → 404 problem+json с code NOT_FOUND', async () => {
    const res = await get('/api/v1/__smoke_unknown__', CLIENT);
    expect(res.status).toBe(404);
    expect(res.headers['content-type']).toContain('application/problem+json');
    expect(res.body).toMatchObject({ code: 'NOT_FOUND' });
  });

  // 12: T-FAIL-006 (426 APP_UPDATE_REQUIRED + X-Min-App-Version — backend), T-SEC-041 (X-App-Version ниже минимума → 426)
  it('версия клиента ниже минимальной → 426 APP_UPDATE_REQUIRED и X-Min-App-Version', async () => {
    const res = await get('/api/v1/__smoke_unknown__', { 'X-App-Version': '0.0.1', 'X-Platform': 'android' });
    expect(res.status).toBe(426);
    expect(res.body).toMatchObject({ code: 'APP_UPDATE_REQUIRED' });
    expect(res.headers['x-min-app-version']).toMatch(/^android=\d+\.\d+\.\d+$/);
  });

  it('входящий обмен 1С выключен по умолчанию: /api/v1/integrations/onec/ping → 404 (16 §4.6)', async () => {
    const res = await get('/api/v1/integrations/onec/ping', CLIENT);
    expect(res.status).toBe(404);
  });

  it('защищённый маршрут без токена не отдаёт данные (deny by default, RBAC)', async () => {
    const res = await get('/api/v1/me', CLIENT);
    expect([401, 404]).toContain(res.status);
    expect(res.headers['content-type']).toContain('application/problem+json');
  });

  describe.runIf(!VIA_PROXY)('мигратор (RM-C-006) на пустой БД', () => {
    it('первый прогон применяет 0001 (DDL RM-B-005) и 0002 (seed RBAC RM-B-008), повторный — 0 изменений', () => {
      expect(migrateRuns[0]?.applied).toEqual(expect.arrayContaining(['0001_init.sql', '0002_rbac_seed.sql']));
      expect(migrateRuns[1]?.applied).toEqual([]);
    });

    it('роли и права из seed RBAC на месте', async () => {
      const pool = new pg.Pool({ connectionString: databaseUrl, max: 1 });
      try {
        const r = await pool.query<{ roles: number; perms: number }>(
          'SELECT (SELECT count(*) FROM roles)::int AS roles, (SELECT count(*) FROM role_permissions)::int AS perms',
        );
        expect(r.rows[0]?.roles).toBeGreaterThanOrEqual(6);
        expect(r.rows[0]?.perms).toBeGreaterThan(0);
      } finally {
        await pool.end();
      }
    });
  });

  describe.runIf(!VIA_PROXY)('APP_READ_ONLY=true на полном AppModule и PostgreSQL 17 (RM-C-005 п. 4, ADR-083)', () => {
    let roApp: INestApplication | undefined;

    beforeAll(async () => {
      roApp = await createApp(testConfig({ DATABASE_URL: databaseUrl, APP_READ_ONLY: 'true' }), {
        logStream: new LogCapture(),
        extraModules: [ReadOnlyProbeModule],
        readOnlyAllowlist: ADR_083_ALLOWED_MUTATIONS, // явная подстановка: по умолчанию перечень пуст (C-MJ-03)
      });
      await roApp.get(PgBossService).start();
    });

    afterAll(async () => {
      await roApp?.close();
    });

    // 12: T-FAIL-007 (режим «только чтение»: мутации → 503 APP_READ_ONLY, чтение работает)
    it('мутация вне перечня (POST /orders) → 503 APP_READ_ONLY; из перечня (POST /auth/otp/verify) доходит до валидации; GET — 200', async () => {
      const http = request(roApp?.getHttpServer() as Parameters<typeof request>[0]);
      const denied = await http.post('/api/v1/orders').set(CLIENT).send({});
      expect(denied.status).toBe(503);
      expect(denied.headers['content-type']).toContain('application/problem+json');
      expect(denied.body).toMatchObject({ code: 'APP_READ_ONLY' });
      // Этап D: маршрут реальный (auth OtpController) — read-only guard пропускает мутацию из перечня ADR-083, и
      // запрос доходит до валидации тела (пустое тело → 400 VALIDATION_FAILED, а не 503 APP_READ_ONLY).
      const allowed = await http.post('/api/v1/auth/otp/verify').set(CLIENT).send({});
      expect(allowed.status).toBe(400);
      expect(allowed.body).toMatchObject({ code: 'VALIDATION_FAILED' });
      expect((await http.get('/health/ready')).status).toBe(200);
    });

    it('RM-C-015 п. 5: MIN_APP_VERSION = N−1 (1.2.0) → N (1.3.0) и N−1 (1.2.0) получают 2xx, N−2 (1.1.0) — 426', async () => {
      const http = request(roApp?.getHttpServer() as Parameters<typeof request>[0]);
      const call = (version: string) =>
        http.get('/api/v1/version-probe').set({ 'X-App-Version': version, 'X-Platform': 'android' });
      expect((await call('1.3.0')).status).toBe(200);
      expect((await call('1.2.0+77')).status).toBe(200);
      const old = await call('1.1.0');
      expect(old.status).toBe(426);
      expect(old.body).toMatchObject({ code: 'APP_UPDATE_REQUIRED', minVersion: '1.2.0' });
      expect(old.headers['x-min-app-version']).toBe('android=1.2.0');
    });
  });

  describe.runIf(!VIA_PROXY)('экспорт OpenAPI ⊆ контракт (RM-C-005 п. 5 — замена openapi-diff, C-MJ-06)', () => {
    it('каждая операция /api/v1/openapi.json есть в contracts/openapi/pos-api.v1.yaml («только не реализовано»)', async () => {
      const res = await get('/api/v1/openapi.json');
      const exported = res.body as {
        info?: { version?: string };
        paths?: Record<string, Record<string, unknown>>;
      };
      const contract = parseYaml(
        readFileSync(fileURLToPath(new URL('../../../contracts/openapi/pos-api.v1.yaml', import.meta.url)), 'utf8'),
      ) as { info: { version: string }; paths: Record<string, Record<string, unknown>> };
      // Ревью E RC-3/RS-11: версия экспорта = info.version контракта.
      expect(exported.info?.version).toBe(contract.info.version);
      const norm = (p: string) => p.replace(/\{[^}]+\}/g, '{}');
      const contractOps = new Set(
        Object.entries(contract.paths).flatMap(([p, ops]) =>
          Object.keys(ops).map((m) => `${m.toUpperCase()} ${norm(p)}`),
        ),
      );
      const methods = new Set(['get', 'post', 'put', 'patch', 'delete']);
      const exportedOps = Object.entries(exported.paths ?? {}).flatMap(([p, ops]) =>
        Object.keys(ops)
          .filter((m) => methods.has(m))
          .map((m) => `${m.toUpperCase()} ${norm(p)}`),
      );
      // Служебные пути вне контракта /api/v1 (healthcheck и сам документ) не сравниваются.
      const extra = exportedOps.filter((op) => !contractOps.has(op) && !/ \/(health|openapi\.json)/.test(op));
      expect(extra).toEqual([]);
      expect(contractOps.size).toBeGreaterThan(100);
      // Этап F (интеграция): все операции контракта этапа F — в экспорте с теми же путями и методами; не входят в F
      // только оплата долга без заказа и её квитанция (этап G, RM-G-013) и вебхук банка (R2, RM-F-014).
      const stageF =
        /^[A-Z]+ \/(cart(\/|$)|orders(\/|$)|payments(\/|$)|notifications(\/|$)|search\/customers$|customers\/\{\}\/orders$)/;
      // Этап G (RM-G-013): оплата долга без заказа и квитанция зарегистрированы guard-ом (403/404) — вне F только вебхук.
      const notInF = new Set(['POST /payments/qr/webhook']);
      const exportedSet = new Set(exportedOps);
      const contractF = [...contractOps].filter((op) => stageF.test(op));
      expect(contractF.length).toBe(34);
      expect(contractF.filter((op) => !exportedSet.has(op) && !notInF.has(op))).toEqual([]);
      expect(exportedOps.filter((op) => notInF.has(op))).toEqual([]);
      // Этап G (интеграция backend G, RM-G-009 п. 1): все 26 операций контракта 1.2.0 этапа G — в экспорте.
      const stageG =
        /^[A-Z]+ \/(admin\/(audit-logs|discount-limits|reports\/)|customers\/\{\}(\/(discounts|receivables(\/refresh)?))?$|discounts\/|favorites\/customers|pos\/dashboard$|receivables\/|returns(\/|$)|transactions(\/|$))/;
      const contractG = [...contractOps].filter((op) => stageG.test(op));
      expect(contractG.length).toBe(26);
      expect(contractG.filter((op) => !exportedSet.has(op))).toEqual([]);
      // Экспорт = контракт: каждая операция контракта реализована и экспортирована, кроме вебхука банка (R2),
      // фото `/images/{sha}/{size}` (отдаёт pos-proxy из MEDIA_DIR, не pos-api — 16 §4.3, Caddyfile `@image`) и
      // входящего обмена `/integrations/onec/*` (только вариант C-2 `ONEC_INBOUND_ENABLED=true`, ПРЕДВАРИТЕЛЬНО:
      // Q-010, Q-011, Q-031; в R1 не регистрируется — 404).
      const notServedByApi = (op: string) =>
        notInF.has(op) || /^GET \/images\//.test(op) || /^[A-Z]+ \/integrations\/onec\//.test(op);
      expect([...contractOps].filter((op) => !exportedSet.has(op) && !notServedByApi(op))).toEqual([]);
    });
  });

  describe.runIf(VIA_PROXY)('pos-proxy (Caddy) тестового контура', () => {
    it('HTTP → HTTPS: редирект 301/308 на https', async () => {
      const res = await fetch(`${HTTP_BASE_URL}/health`, { redirect: 'manual' });
      expect([301, 302, 307, 308]).toContain(res.status);
      expect(res.headers.get('location') ?? '').toMatch(/^https:\/\//);
    });

    it('proxy скрывает Server и запрещает встраивание (X-Frame-Options: DENY)', async () => {
      const res = await get('/health');
      expect(res.headers.server).toBeUndefined();
      expect(res.headers['x-frame-options']).toBe('DENY');
    });

    it('всё вне /api/*, /health*, /images/* → 404 от proxy', async () => {
      expect((await get('/')).status).toBe(404);
      expect((await get('/openapi.json')).status).toBe(404);
    });

    it('readiness снаружи закрыт allow-list Caddy, кроме внутренних сетей (ARCH-006; C-MN-03)', async () => {
      // Smoke обращается к опубликованному порту с docker-хоста (адрес моста — private_ranges) → readiness доступен.
      expect((await get('/health/ready')).status).toBe(200);
    });
  });
});
