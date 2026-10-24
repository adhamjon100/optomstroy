import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { isAdminRateLimited } from '../../src/admin/shared/admin-rate-limit.js';
import { type Actor, AdminTestApp } from './support/admin-app.js';

/**
 * RL-ADMIN (08 §2.9: `/admin/*`, `POST /sync/*`, `POST /orders/{id}/onec-link` — 120 / мин на `userId`; DQ-01,
 * D_spec_questions adm A-11). Счётчик — `rate_limit_counters` (`admin_user_1m`, миграция 0003). В тесте лимит 3.
 */
describe('RL-ADMIN: лимит админ-раздела на пользователя (08 §2.9)', () => {
  const t = new AdminTestApp();
  let admin: Actor;
  let other: Actor;

  beforeAll(async () => {
    await t.start('admin_rate_limit', { adminRateLimit: 3 });
    admin = await t.actor('admin');
    other = await t.actor('admin');
  });

  afterAll(async () => {
    await t.stop();
  });

  it('группа маршрутов (08 §2.9, RC-10): /admin/* любым методом, POST /sync/*, чтение журналов sync, onec-link, confirm/reject привязки, openapi.json в production; прочее — нет', () => {
    expect(isAdminRateLimited('GET', '/api/v1/admin/users?limit=5')).toBe(true);
    expect(isAdminRateLimited('DELETE', '/admin/invitations/1')).toBe(true);
    expect(isAdminRateLimited('POST', '/api/v1/sync/runs')).toBe(true);
    expect(isAdminRateLimited('GET', '/api/v1/sync/status')).toBe(false);
    expect(isAdminRateLimited('POST', '/api/v1/orders/0192f3a1-6c3e-7a1b-9f00-000000000001/onec-link')).toBe(true);
    expect(isAdminRateLimited('POST', '/api/v1/orders')).toBe(false);
    expect(isAdminRateLimited('GET', '/api/v1/administrator')).toBe(false);
    expect(isAdminRateLimited('GET', '/api/v1/me')).toBe(false);
    const id = '0192f3a1-6c3e-7a1b-9f00-000000000001';
    expect(isAdminRateLimited('GET', '/api/v1/sync/runs?entity=products')).toBe(true);
    expect(isAdminRateLimited('GET', `/api/v1/sync/runs/${id}`)).toBe(true);
    expect(isAdminRateLimited('GET', `/api/v1/sync/runs/${id}/errors`)).toBe(true);
    expect(isAdminRateLimited('GET', `/api/v1/sync/runs/${id}/other`)).toBe(false);
    expect(isAdminRateLimited('GET', '/api/v1/sync/outbox/')).toBe(true);
    expect(isAdminRateLimited('POST', `/api/v1/customers/${id}/links/${id}/confirm`)).toBe(true);
    expect(isAdminRateLimited('POST', `/api/v1/customers/${id}/links/${id}/REJECT`)).toBe(true);
    expect(isAdminRateLimited('GET', `/api/v1/customers/${id}/links`)).toBe(false);
    expect(isAdminRateLimited('GET', '/openapi.json')).toBe(true);
    expect(isAdminRateLimited('GET', '/api/v1/openapi.json', { openapiPublic: false })).toBe(true);
    expect(isAdminRateLimited('GET', '/openapi.json', { openapiPublic: true })).toBe(false);
    expect(isAdminRateLimited('PUT', '/api/v1/sync/runs')).toBe(false);
  });

  it('3 запроса в окне — 200; 4-й → 429 RATE_LIMITED с Retry-After и X-RateLimit-*; другой пользователь не затронут; новое окно — снова 200', async () => {
    const now = t.clock.now().getTime();
    t.clock.set(new Date(Math.ceil(now / 60_000) * 60_000 + 1_000));
    for (let i = 0; i < 3; i++) expect((await t.req('get', '/admin/users', admin)).status).toBe(200);
    const denied = await t.req('get', '/admin/users', admin);
    expect(denied.status).toBe(429);
    expect(denied.body).toMatchObject({ code: 'RATE_LIMITED' });
    expect(Number(denied.headers['retry-after'])).toBeGreaterThan(0);
    expect(Number(denied.headers['retry-after'])).toBeLessThanOrEqual(60);
    expect(denied.headers['x-ratelimit-limit']).toBe('3');
    expect(denied.headers['x-ratelimit-remaining']).toBe('0');
    expect((await t.req('get', '/admin/users', other)).status).toBe(200);
    const rows = await t.fdb.pool.query<{ subject: string; count: number }>(
      `SELECT subject, count FROM rate_limit_counters WHERE scope = 'admin_user_1m' ORDER BY subject`,
    );
    expect(rows.rows).toEqual(
      expect.arrayContaining([
        { subject: admin.userId, count: 3 },
        { subject: other.userId, count: 1 },
      ]),
    );
    t.clock.advance(60_000);
    expect((await t.req('get', '/admin/users', admin)).status).toBe(200);
  });

  it('регистр пути не обходит лимит (ревью E-security-1): /ADMIN/users, /Admin/Users, POST /SYNC/runs расходуют admin_user_1m', async () => {
    expect(isAdminRateLimited('GET', '/api/v1/ADMIN/users')).toBe(true);
    expect(isAdminRateLimited('GET', '/API/V1/Admin/Users')).toBe(true);
    expect(isAdminRateLimited('POST', '/api/v1/SYNC/runs')).toBe(true);
    expect(isAdminRateLimited('POST', '/api/v1/ORDERS/0192f3a1-6c3e-7a1b-9f00-000000000001/ONEC-LINK')).toBe(true);
    const u = await t.actor('admin');
    const now = t.clock.now().getTime();
    t.clock.set(new Date(Math.ceil(now / 60_000) * 60_000 + 1_000));
    const statuses: number[] = [];
    for (const path of ['/ADMIN/users', '/Admin/Users', '/admin/USERS', '/ADMIN/users'])
      statuses.push((await t.req('get', path, u)).status);
    expect(statuses).toEqual([200, 200, 200, 429]);
    const rows = await t.fdb.pool.query<{ count: number }>(
      `SELECT count FROM rate_limit_counters WHERE scope = 'admin_user_1m' AND subject = $1 ORDER BY window_start DESC LIMIT 1`,
      [u.userId],
    );
    expect(rows.rows[0]?.count).toBe(3);
  });

  it('анонимный запрос лимитом не учитывается (401 раньше лимита)', async () => {
    const r = await t.req('get', '/admin/users');
    expect(r.status).toBe(401);
    const n = await t.fdb.pool.query<{ n: number }>(
      `SELECT coalesce(sum(count), 0)::int AS n FROM rate_limit_counters WHERE scope = 'admin_user_1m' AND subject = 'unknown'`,
    );
    expect(n.rows[0].n).toBe(0);
  });
});
