import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { Controller, Delete, Get, Param, Patch, Post, Put } from '@nestjs/common';
import type { NestExpressApplication } from '@nestjs/platform-express';
import request from 'supertest';
import { createTestApp, testConfig } from '../../../test/support/test-app.js';
import { normalizeRouteTemplate, routeKey } from '../http/route-template.js';
import { Public } from '../rbac/rbac.decorators.js';
import { ADR_083_ALLOWED_MUTATIONS, DEFAULT_READ_ONLY_ALLOWLIST } from './read-only.allowlist.js';

/** Эндпоинты из AC-ADR-083 (реальные контроллеры появятся на этапах D–F). */
@Public()
@Controller()
class AcceptanceController {
  @Post('auth/otp/request') otpRequest() {
    return { ok: true };
  }
  @Post('auth/otp/verify') otpVerify() {
    return { ok: true };
  }
  @Post('auth/refresh') refresh() {
    return { ok: true };
  }
  @Delete('auth/sessions/:sessionId') revoke(@Param('sessionId') id: string) {
    return { id };
  }
  @Post('notifications/:id/read') read(@Param('id') id: string) {
    return { id };
  }
  @Post('admin/users/:id/block') block(@Param('id') id: string) {
    return { id };
  }
  @Post('orders') createOrder() {
    return { ok: true };
  }
  @Put('cart/items/:variantId') putItem(@Param('variantId') id: string) {
    return { id };
  }
  @Post('orders/:id/payments') pay(@Param('id') id: string) {
    return { id };
  }
  @Put('favorites/products/:id') fav(@Param('id') id: string) {
    return { id };
  }
  @Patch('admin/settings') settings() {
    return { ok: true };
  }
  @Get('catalog/products/:id') product(@Param('id') id: string) {
    return { id };
  }
}

const id = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55';

describe('ReadOnlyGuard (APP_READ_ONLY, ADR-083, 11 SEC-119)', () => {
  let app: NestExpressApplication;

  afterEach(async () => {
    await app?.close();
  });

  it('при APP_READ_ONLY=true: мутации из перечня ADR-083 проходят, остальные → 503 APP_READ_ONLY, GET → 200', async () => {
    app = await createTestApp({
      config: testConfig({ APP_READ_ONLY: 'true' }),
      controllers: [AcceptanceController],
      readOnlyAllowlist: ADR_083_ALLOWED_MUTATIONS, // явная подстановка (RM-C-005 п. 4)
    });
    const http = request(app.getHttpServer());

    for (const path of [
      '/api/v1/auth/otp/request',
      '/api/v1/auth/otp/verify',
      '/api/v1/auth/refresh',
      `/api/v1/notifications/${id}/read`,
      `/api/v1/admin/users/${id}/block`,
    ]) {
      const res = await http.post(path).send({});
      expect(res.status, path).toBe(201);
    }
    expect((await http.delete(`/api/v1/auth/sessions/${id}`)).status).toBe(200);

    const denied = [
      () => http.post('/api/v1/orders').send({}),
      () => http.put(`/api/v1/cart/items/${id}`).send({}),
      () => http.post(`/api/v1/orders/${id}/payments`).send({}),
      () => http.put(`/api/v1/favorites/products/${id}`).send({}),
      () => http.patch('/api/v1/admin/settings').send({}),
    ];
    for (const call of denied) {
      const res = await call();
      expect(res.status).toBe(503);
      expect(res.headers['content-type']).toMatch(/application\/problem\+json/);
      expect(res.body.code).toBe('APP_READ_ONLY');
    }
    expect((await http.get(`/api/v1/catalog/products/${id}`)).status).toBe(200);
  });

  it('при APP_READ_ONLY=false мутации обслуживаются как обычно', async () => {
    app = await createTestApp({ config: testConfig({ APP_READ_ONLY: 'false' }), controllers: [AcceptanceController] });
    expect((await request(app.getHttpServer()).post('/api/v1/orders').send({})).status).toBe(201);
  });

  it('по умолчанию перечень пуст (ADR-083 «Предложено», C-MJ-03) — действует SEC-119: все мутации → 503', async () => {
    expect(DEFAULT_READ_ONLY_ALLOWLIST).toEqual([]);
    app = await createTestApp({ config: testConfig({ APP_READ_ONLY: 'true' }), controllers: [AcceptanceController] });
    const http = request(app.getHttpServer());
    expect((await http.post('/api/v1/auth/otp/verify').send({})).status).toBe(503);
    expect((await http.post('/api/v1/auth/otp/request').send({})).status).toBe(503);
    expect((await http.get(`/api/v1/catalog/products/${id}`)).status).toBe(200);
  });

  it('конфигурация guard совпадает с таблицей ADR-083 п. (2) в 15_DECISION_LOG (0 расхождений)', () => {
    const log = readFileSync(
      fileURLToPath(new URL('../../../../docs/specification/15_DECISION_LOG.md', import.meta.url)),
      'utf8',
    );
    const start = log.indexOf('### ADR-083');
    const section = log.slice(start, log.indexOf('\n(3)', start));
    const fromDoc = new Set<string>();
    // Строки таблицы: «| группа | `POST /auth/…`; `POST …` |».
    for (const line of section.split('\n')) {
      if (!line.startsWith('| ')) continue;
      const cells = line.split('|');
      const last = cells[cells.length - 2] ?? '';
      // Пары в скобках «(… — R2, в R1 не регистрируется)» в перечень не входят.
      const withoutR2 = last.replace(/\([^)]*R2[^)]*\)/g, '');
      for (const m of withoutR2.matchAll(/`(POST|PUT|PATCH|DELETE) ([^`]+)`/g))
        fromDoc.add(routeKey(m[1] ?? '', m[2] ?? ''));
    }
    const fromConfig = new Set(ADR_083_ALLOWED_MUTATIONS.map((m) => routeKey(m.method, m.path)));
    expect(fromDoc.size).toBeGreaterThan(20);
    expect([...fromConfig].filter((k) => !fromDoc.has(k))).toEqual([]);
    expect([...fromDoc].filter((k) => !fromConfig.has(k))).toEqual([]);
  });

  it('нормализация шаблонов: Express `:id` ≡ OpenAPI `{id}`, префикс /api/v1 снимается', () => {
    expect(normalizeRouteTemplate('/api/v1/auth/sessions/:sessionId')).toBe('/auth/sessions/{}');
    expect(normalizeRouteTemplate('/auth/sessions/{sessionId}')).toBe('/auth/sessions/{}');
    expect(routeKey('post', '/api/v1/notifications/:id/read/')).toBe('POST /notifications/{}/read');
  });
});
