import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { LogCapture, testConfig } from '../test/support/test-app.js';
import { DOMAIN_MODULES } from './app.module.js';
import { createApp } from './bootstrap/create-app.js';
import { HealthService } from './health/health.service.js';
import { StubSyncFreshnessProbe } from './health/sync-freshness.probe.js';

/**
 * Сборка реального AppModule без БД (DATABASE_URL указывает на закрытый порт): liveness работает,
 * readiness → 503 {status: failed}, /openapi.json — по OPENAPI_PUBLIC.
 */
describe('AppModule (каркас RM-C-005)', () => {
  let app: INestApplication;

  afterEach(async () => {
    await app?.close();
  });

  it('14 модулей D-06 подключены', () => {
    expect(DOMAIN_MODULES.map((m) => ('module' in m ? m.module : m).name)).toEqual([
      'AuthModule',
      'RegistrationModule',
      'ProfileModule',
      'CatalogModule',
      'CartModule',
      'OrdersModule',
      'PaymentsModule',
      'CustomersModule',
      'TransactionsModule',
      'ReturnsModule',
      'SyncModule',
      'AdminModule',
      'NotificationsModule',
      'HealthModule',
    ]);
  });

  it('T-SEC-028 (часть): GET /health → 200; GET /health/ready без БД → 503 {status: failed}; заголовки безопасности', async () => {
    app = await createApp(testConfig({ OPENAPI_PUBLIC: 'true' }), { logStream: new LogCapture() });
    const live = await request(app.getHttpServer()).get('/health');
    expect(live.status).toBe(200);
    expect(live.body).toMatchObject({ status: 'ok', apiVersion: '1.0' });
    expect(Date.parse(live.body.serverTime)).not.toBeNaN();
    expect(live.headers['cache-control']).toBe('no-store');
    expect(live.headers['x-content-type-options']).toBe('nosniff');
    expect(live.headers['x-powered-by']).toBeUndefined();
    expect(live.headers['x-request-id']).toMatch(/^[0-9a-f-]{36}$/);

    const ready = await request(app.getHttpServer()).get('/health/ready');
    expect(ready.status).toBe(503);
    expect(ready.body).toEqual({ status: 'failed' });
    expect(ready.headers['content-type']).toMatch(/^application\/json/);
  });

  it('/openapi.json: OPENAPI_PUBLIC=true — документ 3.0.3 с путями health (сервер /api/v1); ETag/304', async () => {
    app = await createApp(testConfig({ OPENAPI_PUBLIC: 'true' }), { logStream: new LogCapture() });
    const res = await request(app.getHttpServer()).get('/openapi.json');
    expect(res.status).toBe(200);
    expect(res.body.openapi).toBe('3.0.3');
    expect(res.body.servers[0].url).toBe('/api/v1');
    expect(res.body.paths['/health'].get.operationId).toBe('health_liveness_get');
    expect(res.body.paths['/health/ready'].get.operationId).toBe('health_readiness_get');
    expect(res.body.paths['/openapi.json'].get.operationId).toBe('health_openapi_get');
    const again = await request(app.getHttpServer())
      .get('/api/v1/openapi.json')
      .set('If-None-Match', String(res.headers.etag));
    expect(again.status).toBe(304);
  });

  it('T-SEC-028 (часть): /openapi.json: OPENAPI_PUBLIC=false без права system.openapi.read → 404 NOT_FOUND', async () => {
    app = await createApp(testConfig({ OPENAPI_PUBLIC: 'false' }), { logStream: new LogCapture() });
    const res = await request(app.getHttpServer()).get('/openapi.json');
    expect(res.status).toBe(404);
    expect(res.body.code).toBe('NOT_FOUND');
  });

  it('мутация без маршрута при APP_READ_ONLY=true — 404 (маршрута нет), с маршрутом — guard (см. read-only.guard.spec)', async () => {
    app = await createApp(testConfig({ APP_READ_ONLY: 'true' }), { logStream: new LogCapture() });
    // `/orders` реализован на этапе F (RM-F-002) — для «мутации без маршрута» берётся заведомо несуществующий путь.
    expect((await request(app.getHttpServer()).post('/api/v1/__no_such_route').send({})).status).toBe(404);
  });
});

describe('HealthService.readiness', () => {
  const ok = { query: () => Promise.resolve({ rows: [] }) };
  const down = { query: () => Promise.reject(new Error('down')) };
  const boss = (ready: boolean) => ({ isReady: () => Promise.resolve(ready) });

  it('БД и pg-boss доступны → ok; синхронизация — заглушка (stale=false)', async () => {
    const s = new HealthService(ok as never, boss(true) as never, new StubSyncFreshnessProbe());
    expect(await s.readiness()).toEqual({ status: 'ok', checks: { db: 'ok', worker: 'ok', sync: { stale: false } } });
  });

  it('нет БД или pg-boss → failed; устаревшая синхронизация → degraded', async () => {
    expect(
      await new HealthService(down as never, boss(true) as never, new StubSyncFreshnessProbe()).readiness(),
    ).toEqual({
      status: 'failed',
    });
    expect(
      await new HealthService(ok as never, boss(false) as never, new StubSyncFreshnessProbe()).readiness(),
    ).toEqual({
      status: 'failed',
    });
    const stale = { check: () => Promise.resolve({ stale: true, stockAgeSec: 4000, implemented: true }) };
    expect(await new HealthService(ok as never, boss(true) as never, stale).readiness()).toEqual({
      status: 'degraded',
      checks: { db: 'ok', worker: 'ok', sync: { stockAgeSec: 4000, stale: true } },
    });
  });
});
