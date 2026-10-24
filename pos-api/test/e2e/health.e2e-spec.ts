import { randomUUID } from 'node:crypto';
import type { INestApplication } from '@nestjs/common';
import pg from 'pg';
import request from 'supertest';
import { createApp } from '../../src/bootstrap/create-app.js';
import { PgIdempotencyStore } from '../../src/common/idempotency/idempotency.repository.js';
import { IdempotencyService } from '../../src/common/idempotency/idempotency.service.js';
import type { IdempotencyScope } from '../../src/common/idempotency/idempotency.store.js';
import { requestFingerprint } from '../../src/common/idempotency/fingerprint.js';
import { PgBossService } from '../../src/common/jobs/pg-boss.service.js';
import { SettingsReader } from '../../src/common/settings/settings-reader.js';
import { AppVersionPolicy } from '../../src/common/app-version/app-version.policy.js';
import { EmbeddedPg } from '../support/embedded-pg.js';
import { LogCapture, testConfig } from '../support/test-app.js';

/**
 * e2e на PostgreSQL 17 (embedded): миграции 0001+0002 → API → /health/ready (БД + pg-boss), репозиторий
 * idempotency_keys и приоритет app_settings.min_app_version над env. Запуск: `npm run test:e2e -- health`.
 */
describe('e2e: health / idempotency_keys / app_settings на PostgreSQL 17', () => {
  const db = new EmbeddedPg();
  let app: INestApplication;
  let pool: pg.Pool;

  beforeAll(async () => {
    await db.start();
    await db.createDatabase('pos_e2e');
    await db.migrate('pos_e2e', ['0001_init.sql', '0002_rbac_seed.sql']);
    pool = new pg.Pool({ connectionString: db.url('pos_e2e'), max: 2 });
    // Пул самого теста: разрыв соединений в T-FAIL-012 — не необработанное исключение.
    pool.on('error', () => undefined);
    app = await createApp(testConfig({ DATABASE_URL: db.url('pos_e2e'), OPENAPI_PUBLIC: 'true' }), {
      logStream: new LogCapture(),
    });
    await app.get(PgBossService).start();
  });

  afterAll(async () => {
    await app?.close();
    await pool?.end();
    await db.stop();
  });

  it('GET /health → 200; GET /health/ready → 200 {status: ok, checks.db/worker = ok}', async () => {
    expect((await request(app.getHttpServer()).get('/health')).status).toBe(200);
    const ready = await request(app.getHttpServer()).get('/health/ready');
    expect(ready.status).toBe(200);
    expect(ready.body).toEqual({ status: 'ok', checks: { db: 'ok', worker: 'ok', sync: { stale: false } } });
  });

  it('pg-boss создал свою схему в той же БД (без Redis, D-44)', async () => {
    const r = await pool.query<{ n: string }>(
      `SELECT count(*)::text AS n FROM information_schema.schemata WHERE schema_name = 'pgboss'`,
    );
    expect(r.rows[0]?.n).toBe('1');
  });

  it('PgIdempotencyStore на реальной таблице idempotency_keys (CHECK, PK, просрочка)', async () => {
    const service = new IdempotencyService(new PgIdempotencyStore(pool));
    const scope: IdempotencyScope = {
      key: '3b241101-e2bb-4255-8caf-4136c566a962',
      subjectKey: `reg:${'a'.repeat(64)}`,
      userId: null,
      route: 'POST /registration/complete',
    };
    const h1 = requestFingerprint({}, { phone: 'x' });
    const h2 = requestFingerprint({}, { phone: 'y' });
    expect(await service.begin(scope, h1)).toEqual({ kind: 'proceed' });
    await expect(service.begin(scope, h1)).rejects.toMatchObject({ code: 'IDEMPOTENCY_IN_PROGRESS' });
    await service.complete(scope, 201, { userId: 'u1' });
    expect(await service.begin(scope, h1)).toEqual({ kind: 'replay', status: 201, body: { userId: 'u1' } });
    await expect(service.begin(scope, h2)).rejects.toMatchObject({ code: 'IDEMPOTENCY_KEY_REUSED' });

    await pool.query(`UPDATE idempotency_keys SET expires_at = now() - interval '1 second' WHERE key = $1`, [
      scope.key,
    ]);
    expect(await service.begin(scope, h2)).toEqual({ kind: 'proceed' });
    await service.release(scope);
    const left = await pool.query(`SELECT count(*)::int AS n FROM idempotency_keys WHERE key = $1`, [scope.key]);
    expect(left.rows[0].n).toBe(0);
  });

  it('app_settings.min_app_version имеет приоритет над env и действует без перезапуска API', async () => {
    const call = () =>
      request(app.getHttpServer()).get('/api/v1/nope').set('X-App-Version', '1.5.0').set('X-Platform', 'android');
    expect((await call()).status).toBe(404); // env: android=1.2.0 → проверка пройдена, маршрута нет
    await pool.query(
      `INSERT INTO app_settings (key, value, value_type, description_ru)
       VALUES ('min_app_version', to_jsonb('android=2.0.0,windows=2.0.0'::text), 'string', 'e2e')
       ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`,
    );
    app.get(SettingsReader).invalidate();
    await app.get(AppVersionPolicy).refresh();
    const res = await call();
    expect(res.status).toBe(426);
    expect(res.headers['x-min-app-version']).toBe('android=2.0.0');
    await pool.query(`DELETE FROM app_settings WHERE key = 'min_app_version'`);
    app.get(SettingsReader).invalidate();
    await app.get(AppVersionPolicy).refresh();
  });

  // 12 T-FAIL-012 (P1): PostgreSQL недоступна — /health/ready → 503, API — 5xx problem+json без деталей БД; после
  // возвращения БД — восстановление без ручных действий. Недоступность моделируется запретом подключений к базе и
  // разрывом открытых соединений (кластер embedded PostgreSQL при stop() удаляется — перезапуск того же нельзя).
  it('T-FAIL-012: БД недоступна → /health/ready 503, API 5xx без деталей; БД вернулась → 200 без перезапуска API', async () => {
    const su = new pg.Client({ connectionString: db.url('postgres') });
    await su.connect();
    try {
      await su.query(`ALTER DATABASE pos_e2e ALLOW_CONNECTIONS false`);
      await su.query(`SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'pos_e2e'`);
      const ready = await request(app.getHttpServer()).get('/health/ready');
      expect(ready.status).toBe(503);
      expect(ready.body.status).toBe('failed');
      expect(ready.body.checks?.db).not.toBe('ok');
      // Запрос API, которому нужна БД (публичный OTP-вход): ошибка сервера, тело problem+json без внутренних деталей.
      const api = await request(app.getHttpServer())
        .post('/api/v1/auth/otp/request')
        .set('X-Device-Id', randomUUID())
        .set('X-App-Version', '1.5.0')
        .set('X-Platform', 'android')
        .send({ phone: '+996555000111', purpose: 'login_or_register' });
      // 12 T-FAIL-012 ждёт 503, но закрытый перечень кодов 08 §2.4 (API-005) не содержит кода недоступности БД:
      // ответ — 500 INTERNAL с кодом обращения (08 §2.4, API-006); расхождение — F_spec_questions FIX-F-19.
      expect([500, 503], JSON.stringify(api.body)).toContain(api.status);
      expect(String(api.headers['content-type'])).toContain('application/problem+json');
      const text = JSON.stringify(api.body);
      for (const leak of ['pos_e2e', 'ALLOW_CONNECTIONS', 'postgres', 'ECONN', 'at ', 'stack']) {
        expect(text, leak).not.toContain(leak);
      }
    } finally {
      await su.query(`ALTER DATABASE pos_e2e ALLOW_CONNECTIONS true`);
      await su.end();
    }
    // Восстановление без ручных действий: пул переподключается сам (readiness — не позднее 20 с).
    let status = 0;
    for (let i = 0; i < 40 && status !== 200; i++) {
      status = (await request(app.getHttpServer()).get('/health/ready')).status;
      if (status !== 200) await new Promise((r) => setTimeout(r, 500));
    }
    expect(status).toBe(200);
  });
});
