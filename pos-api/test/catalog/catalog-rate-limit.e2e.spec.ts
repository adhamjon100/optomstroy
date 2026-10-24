import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import request from 'supertest';
import YAML from 'yaml';
import {
  HTTP_RATE_LIMIT_ROUTES,
  HTTP_RATE_LIMITS_PER_MINUTE,
  type HttpRateLimitGroup,
  httpRateLimitGroup,
  MemoryWindowCounter,
} from '../../src/common/rate-limit/http-rate-limit.js';
import { type Actor, CatalogTestApp } from './support/catalog-app.js';

/**
 * Лимиты частоты RL-READ / RL-SEARCH / RL-CART (08 §2.9, хранилище memory; ревью E-security-2). Состав маршрутов —
 * `x-rate-limit-group` контракта. HTTP-часть — на приложении каталога с уменьшенными лимитами (тестовые данные).
 */
const CONTRACT = fileURLToPath(new URL('../../../contracts/openapi/pos-api.v1.yaml', import.meta.url));

describe('RL-READ / RL-SEARCH / RL-CART: состав групп и счётчик (08 §2.9)', () => {
  it('маршруты групп = x-rate-limit-group контракта; лимиты 600 / 120 / 300 в минуту', () => {
    const doc = YAML.parse(readFileSync(CONTRACT, 'utf8')) as {
      paths: Record<string, Record<string, { 'x-rate-limit-group'?: string }>>;
    };
    const fromContract: Record<string, string[]> = {};
    for (const [path, ops] of Object.entries(doc.paths)) {
      for (const [method, op] of Object.entries(ops)) {
        const g = typeof op === 'object' && op ? op['x-rate-limit-group'] : undefined;
        if (g === 'RL-READ' || g === 'RL-SEARCH' || g === 'RL-CART' || g === 'RL-FIN') {
          (fromContract[g] ??= []).push(`${method.toUpperCase()} ${path}`);
        }
      }
    }
    for (const g of Object.keys(HTTP_RATE_LIMIT_ROUTES) as HttpRateLimitGroup[]) {
      expect([...HTTP_RATE_LIMIT_ROUTES[g]].sort(), g).toEqual((fromContract[g] ?? []).sort());
    }
    expect(HTTP_RATE_LIMITS_PER_MINUTE).toEqual({ 'RL-READ': 600, 'RL-SEARCH': 120, 'RL-CART': 300, 'RL-FIN': 60 });
  });

  it('классификация: шаблоны, литерал важнее параметра, регистр и префикс /api/v1 не важны, прочее — без группы', () => {
    expect(httpRateLimitGroup('GET', '/api/v1/search/products?q=x')).toBe('RL-SEARCH');
    expect(httpRateLimitGroup('GET', '/API/V1/SEARCH/Products')).toBe('RL-SEARCH');
    expect(httpRateLimitGroup('GET', '/api/v1/search/barcode/4600000000001')).toBe('RL-SEARCH');
    expect(httpRateLimitGroup('GET', '/api/v1/catalog/products/0192f3a1-6c3e-7a1b-9f00-000000000001')).toBe('RL-READ');
    expect(httpRateLimitGroup('DELETE', '/api/v1/catalog/products/recent')).toBe('RL-READ');
    expect(httpRateLimitGroup('PUT', '/api/v1/favorites/products/abc')).toBe('RL-READ');
    expect(httpRateLimitGroup('POST', '/api/v1/inventory/check')).toBe('RL-CART');
    expect(httpRateLimitGroup('GET', '/api/v1/inventory/balances?variantIds=a')).toBe('RL-READ');
    expect(httpRateLimitGroup('POST', '/api/v1/orders')).toBe('RL-FIN');
    expect(httpRateLimitGroup('POST', '/api/v1/orders/0192f3a1-6c3e-7a1b-9f00-000000000001/cancel')).toBe('RL-FIN');
    expect(httpRateLimitGroup('POST', '/api/v1/payments/x/void')).toBe('RL-FIN');
    expect(httpRateLimitGroup('POST', '/api/v1/orders/x/onec-link')).toBeUndefined();
    expect(httpRateLimitGroup('POST', '/api/v1/catalog/products')).toBeUndefined();
    expect(httpRateLimitGroup('GET', '/api/v1/admin/users')).toBeUndefined();
    expect(httpRateLimitGroup('GET', '/api/v1/health')).toBeUndefined();
  });

  it('окно 1 мин: N разрешено, N+1 — отказ с Retry-After до конца окна; новое окно — снова разрешено', () => {
    const c = new MemoryWindowCounter();
    const t0 = 1_700_000_040_000; // 40 с от начала минуты
    expect(c.consume('k', 2, t0).allowed).toBe(true);
    expect(c.consume('k', 2, t0 + 1).allowed).toBe(true);
    const denied = c.consume('k', 2, t0 + 2);
    expect(denied).toMatchObject({ allowed: false, remaining: 0 });
    expect(denied.retryAfterSec).toBeGreaterThan(0);
    expect(denied.retryAfterSec).toBeLessThanOrEqual(60);
    expect(c.consume('other', 2, t0 + 3).allowed).toBe(true);
    expect(c.consume('k', 2, t0 + 60_000).allowed).toBe(true);
  });
});

describe('RL-SEARCH / RL-READ по HTTP (приложение каталога, лимиты уменьшены)', () => {
  const t = new CatalogTestApp();
  let customer: Actor;
  let other: Actor;
  const get = (a: Actor, path: string) =>
    request(t.app.getHttpServer())
      .get(`/api/v1${path}`)
      .set('Authorization', `Bearer ${a.token}`)
      .set('X-Device-Id', a.deviceKey);

  beforeAll(async () => {
    await t.start({ skuCount: 30, rateLimits: { 'RL-SEARCH': 3, 'RL-READ': 4 } });
    customer = await t.actor({ role: 'customer' });
    other = await t.actor({ role: 'customer' });
  });

  afterAll(async () => {
    await t.stop();
  });

  it('4-й поиск в минуту → 429 RATE_LIMITED c Retry-After и X-RateLimit-*; другой пользователь и другая группа не затронуты', async () => {
    const statuses: number[] = [];
    for (let i = 0; i < 3; i += 1) statuses.push((await get(customer, '/search/products?q=смеситель')).status);
    expect(statuses.every((s) => s === 200 || s === 404)).toBe(true);
    const denied = await get(customer, '/SEARCH/products?q=смеситель');
    expect(denied.status).toBe(429);
    expect(denied.body).toMatchObject({ code: 'RATE_LIMITED' });
    expect(Number(denied.headers['retry-after'])).toBeGreaterThan(0);
    expect(denied.headers['x-ratelimit-limit']).toBe('3');
    expect(denied.headers['x-ratelimit-remaining']).toBe('0');
    expect((await get(other, '/search/products?q=смеситель')).status).not.toBe(429);
    expect((await get(customer, '/catalog/products?limit=1')).status).toBe(200);
  });

  it('RL-READ: выкачка каталога ограничена (5-й запрос /catalog/* в минуту → 429)', async () => {
    const u = await t.actor({ role: 'customer' });
    const statuses: number[] = [];
    for (let i = 0; i < 5; i += 1) statuses.push((await get(u, '/catalog/products?limit=1')).status);
    expect(statuses).toEqual([200, 200, 200, 200, 429]);
  });
});
