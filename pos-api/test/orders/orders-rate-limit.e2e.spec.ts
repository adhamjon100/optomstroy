import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import YAML from 'yaml';
import { ADMIN_RATE_LIMIT, AdminRateLimitModule, isAdminRateLimited } from '../../src/admin/shared/admin-rate-limit.js';
import { OrdersModule } from '../../src/orders/orders.module.js';
import { OrdersTestApp } from './support/orders-fixture.js';

const CONTRACT = fileURLToPath(new URL('../../../contracts/openapi/pos-api.v1.yaml', import.meta.url));
const SAMPLE_ID = '0192f3a1-6c3e-7a1b-9f00-000000000001';

/**
 * RL-ADMIN для `POST /orders/{id}/onec-link` (08 §2.9 «RL-ADMIN: `/admin/*`, `POST /sync/*`, `POST /orders/{id}/onec-link`»;
 * F_spec_sync §3, FQ-ORD-13) — **тестовые данные**: embedded PostgreSQL 17, `OrdersModule` + `AdminRateLimitModule`
 * (как в `AppModule`) с лимитом 3 в минуту. Счётчик — `rate_limit_counters` (`admin_user_1m`), общий с `/admin/*`.
 * Состав группы сверяется с `x-rate-limit-group: RL-ADMIN` контракта.
 */
describe('RL-ADMIN: POST /orders/{id}/onec-link (08 §2.9, FQ-ORD-13)', () => {
  const t = new OrdersTestApp();

  beforeAll(async () => {
    await t.start({
      modules: [
        OrdersModule,
        { module: AdminRateLimitModule, providers: [{ provide: ADMIN_RATE_LIMIT, useValue: 3 }] },
      ],
      fakePorts: true,
      jobs: false,
    });
  });
  afterAll(async () => {
    await t.stop();
  });

  it('маршруты isAdminRateLimited = x-rate-limit-group: RL-ADMIN контракта (RC-10); onec-link — в обоих', () => {
    const doc = YAML.parse(readFileSync(CONTRACT, 'utf8')) as {
      paths: Record<string, Record<string, { 'x-rate-limit-group'?: string }>>;
    };
    const extra: string[] = [];
    const notLimited: string[] = [];
    for (const [path, ops] of Object.entries(doc.paths)) {
      for (const [method, op] of Object.entries(ops)) {
        if (typeof op !== 'object' || op === null || !('responses' in op)) continue;
        const inContract = op['x-rate-limit-group'] === 'RL-ADMIN';
        const limited = isAdminRateLimited(method.toUpperCase(), `/api/v1${path.replace(/\{[^}]+\}/g, SAMPLE_ID)}`);
        if (limited && !inContract) extra.push(`${method.toUpperCase()} ${path}`);
        if (inContract && !limited) notLimited.push(`${method.toUpperCase()} ${path}`);
      }
    }
    // Интерцептор не ограничивает операции других групп.
    expect(extra).toEqual([]);
    expect(notLimited).not.toContain('POST /orders/{id}/onec-link');
    // Состав RL-ADMIN 08 §2.9 = `x-rate-limit-group: RL-ADMIN` контракта — точное совпадение (ревью закрытия F,
    // RC-10; `GET /openapi.json` — RL-ADMIN в production, RL-PUBLIC-IP при `OPENAPI_PUBLIC=true`, §4.19.2).
    expect(notLimited).toEqual([]);
    expect(isAdminRateLimited('GET', '/openapi.json', { openapiPublic: true })).toBe(false);
    expect(isAdminRateLimited('GET', '/api/v1/sync/status')).toBe(false);
    expect(isAdminRateLimited('POST', `/api/v1/orders/${SAMPLE_ID}/onec-link`)).toBe(true);
  });

  it('3 запроса в окне доходят до обработчика; 4-й → 429 RATE_LIMITED с Retry-After; другой пользователь не затронут', async () => {
    // Окно — календарная минута: начинать не в последние 10 с минуты, чтобы 4 запроса попали в одно окно.
    const sec = new Date().getUTCSeconds();
    if (sec >= 50) await new Promise((r) => setTimeout(r, (61 - sec) * 1000));
    const senior = await t.actor({ role: 'senior_seller' });
    const other = await t.actor({ role: 'admin' });
    const body = { onecNumber: 'УТ-0001234', reason: 'документ оформлен вручную в 1С' };
    const link = (who: typeof senior) =>
      t.req('post', `/orders/${randomUUID()}/onec-link`, who, { idem: true }).send(body);
    // Без step-up обработчик отвечает 403 STEP_UP_REQUIRED — запрос прошёл RL-ADMIN и расходует счётчик.
    for (let i = 0; i < 3; i++) {
      const r = await link(senior);
      expect(r.status, JSON.stringify(r.body)).not.toBe(429);
    }
    const denied = await link(senior);
    expect(denied.status, JSON.stringify(denied.body)).toBe(429);
    expect(denied.body).toMatchObject({ code: 'RATE_LIMITED' });
    expect(Number(denied.headers['retry-after'])).toBeGreaterThan(0);
    expect(denied.headers['x-ratelimit-limit']).toBe('3');
    expect((await link(other)).status).not.toBe(429);
    const rows = await t.q<{ subject: string; count: number }>(
      `SELECT subject, count FROM rate_limit_counters WHERE scope = 'admin_user_1m' AND subject = $1`,
      [senior.userId],
    );
    expect(rows[0]?.count).toBeGreaterThanOrEqual(3);
    // Чтение заказов (RL-READ) RL-ADMIN не расходует.
    expect(isAdminRateLimited('GET', `/api/v1/orders/${SAMPLE_ID}`)).toBe(false);
  });
});
