import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { FixedClock } from '../../src/common/auth/clock.js';
import { CustomerDiscountsModule } from '../../src/customers/discounts/discounts.module.js';
import { ReceivablesModule } from '../../src/customers/receivables/receivables.module.js';
import { CashierTestApp, type CashierWorld } from '../support/cashier-fixture.js';
import { F_MODULES, type PosActor } from '../support/pos-fixture.js';

/**
 * Время в правилах долга — с управляемыми часами `CLOCK` (**тестовые данные**, фейк 1С в режиме кассира):
 * - 12 T-DEBT-005 / 10 DEBT-005 / ядро §17.2: детализация долга — step-up при первом просмотре; повторно ≤ 15 мин —
 *   без нового step-up; через 16 мин — снова `STEP_UP_REQUIRED` (токен step-up живёт 15 мин, 08 §2.12);
 * - 08 §2.9 RL-RECV-REFRESH: не более одного обращения к 1С на клиента за 30 с — и после успешного, и после
 *   неудачного обращения; через 31 с — новое обращение.
 */
const clock = new FixedClock(new Date());
let t: CashierTestApp;
let w: CashierWorld;
const DETAIL = 'customer.receivables.read.detail';

beforeAll(async () => {
  t = await new CashierTestApp().start({
    env: { QR_PROVIDER: 'none', ONEC_SYNC_CHECK_TIMEOUT_MS: '1500' },
    modules: [...F_MODULES, ReceivablesModule, CustomerDiscountsModule],
    clock,
  });
  w = await t.seedCashierWorld();
  await t.q(`UPDATE receivables SET synced_at = now() - interval '1 hour'`);
}, 600_000);

afterAll(async () => {
  await t?.stop();
});

/** Новый access-токен той же сессии на текущий момент часов (access живёт меньше 16 мин). */
async function fresh(a: PosActor): Promise<PosActor> {
  const pv = (await t.q<{ v: number }>('SELECT permissions_version AS v FROM users WHERE id = $1', [a.userId]))[0].v;
  const { token } = await t.jwt.signAccess({
    sub: a.userId,
    kind: a.kind,
    roles: a.role ? [a.role] : [],
    permissionsVersion: pv,
    deviceId: a.deviceKey,
    sid: a.sessionId,
  });
  return { ...a, token };
}

const calls = () => t.onec.callsOf('getCustomerReceivables').length;

describe('step-up детализации долга: первый просмотр, ≤ 15 мин, > 15 мин (T-DEBT-005)', () => {
  it('первый — step-up; через 10 мин тем же step-up — без нового; через 16 мин — снова STEP_UP_REQUIRED; аудит каждого просмотра', async () => {
    const path = `/customers/${w.customers.buyer.id}/receivables?include=documents`;
    let a = await fresh(w.actors.cashier);
    expect((await t.req('get', path, a)).body).toMatchObject({
      code: 'STEP_UP_REQUIRED',
      stepUp: { operation: DETAIL },
    });
    const step = await t.stepUp(a, DETAIL);
    expect((await t.req('get', path, a, { stepUp: step })).status).toBe(200);
    clock.advance(10 * 60_000);
    a = await fresh(a);
    expect((await t.req('get', path, a, { stepUp: step })).status).toBe(200);
    clock.advance(6 * 60_000);
    a = await fresh(a);
    const expired = await t.req('get', path, a, { stepUp: step });
    expect(expired.status).toBe(403);
    expect(expired.body).toMatchObject({ code: 'STEP_UP_REQUIRED' });
    const again = await t.stepUp(a, DETAIL);
    expect((await t.req('get', path, a, { stepUp: again })).status).toBe(200);
    // Сводка без детализации step-up не требует никогда.
    expect((await t.req('get', `/customers/${w.customers.buyer.id}/receivables`, a)).status).toBe(200);
    const fin = await t.auditRows('customer.finance.view', w.customers.buyer.id);
    expect(fin.filter((r) => r.actor_user_id === a.userId)).toHaveLength(3);
  });
});

describe('RL-RECV-REFRESH: одно обращение к 1С на клиента за 30 с (08 §2.9)', () => {
  it('после успешного обновления: < 30 с — refreshed=false без 1С; через 31 с — новое обращение', async () => {
    const a = await fresh(w.actors.cashier);
    const id = w.customers.debtWithinLimit.id;
    const n = calls();
    expect((await t.req('post', `/customers/${id}/receivables/refresh`, a)).body).toMatchObject({ refreshed: true });
    clock.advance(20_000);
    expect((await t.req('post', `/customers/${id}/receivables/refresh`, a)).body).toMatchObject({ refreshed: false });
    expect(calls()).toBe(n + 1);
    clock.advance(31_000);
    expect((await t.req('post', `/customers/${id}/receivables/refresh`, a)).body).toMatchObject({ refreshed: true });
    expect(calls()).toBe(n + 2);
  });

  it('после неудачного обращения: < 30 с — 503 без 1С (Retry-After); через 31 с — новое обращение', async () => {
    const a = await fresh(w.actors.senior_seller);
    const id = w.customers.overdue.id;
    t.onec.always('getCustomerReceivables', { transport: true });
    try {
      const n = calls();
      expect((await t.req('post', `/customers/${id}/receivables/refresh`, a)).status).toBe(503);
      clock.advance(10_000);
      const blocked = await t.req('post', `/customers/${id}/receivables/refresh`, a);
      expect(blocked.status).toBe(503);
      expect(Number(blocked.headers['retry-after'])).toBe(20);
      expect(calls()).toBe(n + 1);
      clock.advance(21_000);
      expect((await t.req('post', `/customers/${id}/receivables/refresh`, a)).status).toBe(503);
      expect(calls()).toBe(n + 2);
    } finally {
      t.onec.always('getCustomerReceivables', null);
    }
  });
});
