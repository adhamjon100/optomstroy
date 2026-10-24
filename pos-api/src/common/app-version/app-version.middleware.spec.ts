import { Controller, Get, Post } from '@nestjs/common';
import type { NestExpressApplication } from '@nestjs/platform-express';
import request from 'supertest';
import { createTestApp, FakeSettingsTable, testConfig } from '../../../test/support/test-app.js';
import { Public } from '../rbac/rbac.decorators.js';
import { SETTINGS_CACHE_TTL_MS } from '../settings/settings-reader.js';
import { compareSemVer, formatVersionHeader, parsePlatformVersions, parseSemVer } from './version-policy.js';

@Public()
@Controller()
class ProbeController {
  @Get('catalog/products')
  list(): { ok: true } {
    return { ok: true };
  }

  @Post('auth/otp/request')
  otp(): { ok: true } {
    return { ok: true };
  }

  @Get('health')
  health(): { status: 'ok' } {
    return { status: 'ok' };
  }
}

describe('version-policy (semver, platform=semver)', () => {
  it('сравнивает по SemVer 2.0.0 и игнорирует build-метаданные', () => {
    const v = (s: string) => parseSemVer(s)!;
    expect(compareSemVer(v('1.4.2+87'), v('1.4.2'))).toBe(0);
    expect(compareSemVer(v('1.2.0'), v('1.10.0'))).toBe(-1);
    expect(compareSemVer(v('1.2.0-rc.1'), v('1.2.0'))).toBe(-1);
    expect(compareSemVer(v('1.2.0-rc.2'), v('1.2.0-rc.10'))).toBe(-1);
    expect(parseSemVer('1.2')).toBeNull();
  });

  it('разбирает и форматирует список версий по платформам', () => {
    const p = parsePlatformVersions('android=1.2.0, windows=1.3.0');
    expect(p).toEqual({ android: '1.2.0', windows: '1.3.0' });
    expect(formatVersionHeader(p, 'android')).toBe('android=1.2.0');
    expect(formatVersionHeader(p, undefined)).toBe('android=1.2.0,windows=1.3.0');
    expect(formatVersionHeader(p, 'ios')).toBeUndefined();
    expect(() => parsePlatformVersions('android=1.2')).toThrow();
    expect(() => parsePlatformVersions('web=1.2.0')).toThrow();
    expect(() => parsePlatformVersions('android=1.2.0,android=1.3.0')).toThrow();
  });
});

describe('AppVersionMiddleware (RM-C-015)', () => {
  let app: NestExpressApplication;
  let settings: FakeSettingsTable;
  let now = 1_000_000;

  beforeEach(async () => {
    settings = new FakeSettingsTable();
    now = 1_000_000;
    app = await createTestApp({
      config: testConfig({ MIN_APP_VERSION: 'android=1.2.0,windows=1.2.0', RECOMMENDED_APP_VERSION: 'android=1.3.0' }),
      controllers: [ProbeController],
      settings,
      now: () => now,
    });
  });

  afterEach(async () => {
    await app.close();
  });

  it('версия ниже минимальной для своей платформы → 426 APP_UPDATE_REQUIRED с X-Min-App-Version', async () => {
    const res = await request(app.getHttpServer())
      .get('/api/v1/catalog/products')
      .set('X-App-Version', '1.1.9+40')
      .set('X-Platform', 'android');
    expect(res.status).toBe(426);
    expect(res.headers['content-type']).toMatch(/application\/problem\+json/);
    expect(res.headers['x-min-app-version']).toBe('android=1.2.0');
    expect(res.body).toMatchObject({ code: 'APP_UPDATE_REQUIRED', status: 426, minVersion: '1.2.0' });
  });

  it('C-MJ-08: storeUrl в теле 426 — из app_settings.app_store_url для платформы клиента (08 §2.4)', async () => {
    const call = (platform: string) =>
      request(app.getHttpServer())
        .get('/api/v1/catalog/products')
        .set('X-App-Version', '1.0.0')
        .set('X-Platform', platform);
    expect((await call('android')).body.storeUrl).toBeUndefined(); // ключ не задан — поле не передаётся
    settings.values.set('app_store_url', {
      android: 'https://play.google.com/store/apps/details?id=kg.optomstroy.pos',
      windows: 'http://insecure.example/pos.msix', // не https — игнорируется
    });
    now += SETTINGS_CACHE_TTL_MS + 1;
    await call('android'); // фоновое обновление кэша
    await new Promise((r) => setTimeout(r, 20));
    const android = await call('android');
    expect(android.status).toBe(426);
    expect(android.body).toMatchObject({
      code: 'APP_UPDATE_REQUIRED',
      minVersion: '1.2.0',
      storeUrl: 'https://play.google.com/store/apps/details?id=kg.optomstroy.pos',
    });
    const windows = await call('windows');
    expect(windows.status).toBe(426);
    expect(windows.body.storeUrl).toBeUndefined();
  });

  it('426 имеет приоритет над остальными проверками (мутация без прав тоже получает 426)', async () => {
    const res = await request(app.getHttpServer())
      .post('/api/v1/auth/otp/request')
      .set('X-App-Version', '1.0.0')
      .set('X-Platform', 'windows');
    expect(res.status).toBe(426);
  });

  it('та же версия для другой платформы (без минимума) → 200; заголовки версий на каждом 2xx', async () => {
    const res = await request(app.getHttpServer())
      .get('/api/v1/catalog/products')
      .set('X-App-Version', '1.1.9')
      .set('X-Platform', 'ios');
    expect(res.status).toBe(200);
    expect(res.headers['x-min-app-version']).toBeUndefined();

    const ok = await request(app.getHttpServer())
      .get('/api/v1/catalog/products')
      .set('X-App-Version', '1.2.0')
      .set('X-Platform', 'android');
    expect(ok.status).toBe(200);
    expect(ok.headers['x-min-app-version']).toBe('android=1.2.0');
    expect(ok.headers['x-recommended-app-version']).toBe('android=1.3.0');
  });

  it('без X-Platform — заголовок содержит все платформы; без версии — мягкий режим R1 (200)', async () => {
    const res = await request(app.getHttpServer()).get('/api/v1/catalog/products');
    expect(res.status).toBe(200);
    expect(res.headers['x-min-app-version']).toBe('android=1.2.0,windows=1.2.0');
    expect(res.headers['x-recommended-app-version']).toBe('android=1.3.0');
  });

  it('неизвестная платформа → 400 VALIDATION_FAILED (rule platform)', async () => {
    const res = await request(app.getHttpServer())
      .get('/api/v1/catalog/products')
      .set('X-App-Version', '1.2.0')
      .set('X-Platform', 'web');
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('VALIDATION_FAILED');
    expect(res.body.errors[0].rule).toBe('platform');
  });

  it('/health не проверяет версию', async () => {
    const res = await request(app.getHttpServer())
      .get('/health')
      .set('X-App-Version', '0.0.1')
      .set('X-Platform', 'android');
    expect(res.status).toBe(200);
  });

  it('политика N/N−1: при MIN_APP_VERSION = N−1 версии N и N−1 → 2xx, N−2 → 426', async () => {
    await app.close();
    app = await createTestApp({
      config: testConfig({ MIN_APP_VERSION: 'android=1.4.0' }),
      controllers: [ProbeController],
      settings,
    });
    const call = (v: string) =>
      request(app.getHttpServer()).get('/api/v1/catalog/products').set('X-App-Version', v).set('X-Platform', 'android');
    expect((await call('1.5.0')).status).toBe(200);
    expect((await call('1.4.0')).status).toBe(200);
    expect((await call('1.3.7')).status).toBe(426);
  });

  it('app_settings.min_app_version имеет приоритет над env и применяется без перезапуска (после TTL кэша)', async () => {
    const call = () =>
      request(app.getHttpServer())
        .get('/api/v1/catalog/products')
        .set('X-App-Version', '1.5.0')
        .set('X-Platform', 'android');
    expect((await call()).status).toBe(200);

    settings.values.set('min_app_version', 'android=2.0.0,windows=2.0.0');
    settings.values.set('recommended_app_version', { android: '2.1.0' });
    now += SETTINGS_CACHE_TTL_MS + 1;
    await call(); // запуск фонового обновления устаревшего кэша
    await new Promise((r) => setTimeout(r, 20));

    const res = await call();
    expect(res.status).toBe(426);
    expect(res.headers['x-min-app-version']).toBe('android=2.0.0');
    expect(res.headers['x-recommended-app-version']).toBe('android=2.1.0');
  });

  it('недоступность app_settings не ломает запросы — используется env', async () => {
    settings.failing = true;
    now += SETTINGS_CACHE_TTL_MS + 1;
    const res = await request(app.getHttpServer())
      .get('/api/v1/catalog/products')
      .set('X-App-Version', '1.2.0')
      .set('X-Platform', 'android');
    expect(res.status).toBe(200);
    expect(res.headers['x-min-app-version']).toBe('android=1.2.0');
  });
});
