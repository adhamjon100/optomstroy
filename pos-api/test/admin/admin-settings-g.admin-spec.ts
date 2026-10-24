import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { SettingsReader } from '../../src/common/settings/settings-reader.js';
import { type Actor, AdminTestApp } from './support/admin-app.js';

/**
 * Этап G (RM-G-006, RM-G-014 п. 4; ядро §21 п. 3, §24.2): ключи `/admin/settings`, которыми управляет этап G —
 * `customerStockDisplay` (показ остатков клиенту), `returnsEnabled`, `returnApprovalThreshold`,
 * `receivables.maxAgeMinutes`: `owner` — только просмотр, `admin` — изменение со step-up `settings.app.update` и
 * аудитом `settings.changed` (виден в `GET /admin/audit-logs`), недопустимые значения → VALIDATION_FAILED
 * (RM-D-015 п. 2), `CUSTOMER_SELF_SERVICE` — только чтение (env).
 */
const SEED = fileURLToPath(new URL('../../seeds/0001_defaults.sql', import.meta.url));

describe('admin/settings этапа G: остатки клиенту, возвраты, возраст снимка долга', () => {
  const t = new AdminTestApp();
  let admin: Actor;
  let owner: Actor;
  const version = async () => (await t.req('get', '/admin/settings', admin)).body.rowVersion as number;
  const put = async (a: Actor, settings: Record<string, unknown>, stepUp?: string | null) => {
    const rowVersion = await version();
    const token = stepUp === null ? undefined : (stepUp ?? (await t.stepUp(a, 'settings.app.update')));
    return t.req('put', '/admin/settings', a, token ? { stepUp: token } : {}).send({ settings, rowVersion });
  };

  beforeAll(async () => {
    await t.start('admin_settings_g_e2e', { audit: true });
    await t.q(readFileSync(SEED, 'utf8'));
    admin = await t.actor('admin');
    owner = await t.actor('owner');
  });

  afterAll(async () => {
    await t.stop();
  });

  it('GET: значения по умолчанию ключей G видны admin и owner; CUSTOMER_SELF_SERVICE — только в env', async () => {
    for (const a of [admin, owner]) {
      const r = await t.req('get', '/admin/settings', a);
      expect(r.status).toBe(200);
      expect(r.body.settings).toMatchObject({
        customerStockDisplay: 'status',
        returnsEnabled: true,
        returnApprovalThreshold: { amount: '10000.00', currency: 'KGS' },
        'receivables.maxAgeMinutes': 60,
      });
      expect(r.body.env).toMatchObject({ customerSelfService: true, debtPaymentsFromPos: false });
      expect(r.body.settings).not.toHaveProperty('customerSelfService');
    }
  });

  it('owner — только просмотр (ядро §21 п. 3): PUT со step-up → 403 FORBIDDEN, значения не меняются', async () => {
    const r = await put(owner, { customerStockDisplay: 'quantity' });
    expect([r.status, r.body.code]).toEqual([403, 'FORBIDDEN']);
    expect((await t.req('get', '/admin/settings', admin)).body.settings.customerStockDisplay).toBe('status');
  });

  it('admin: без step-up → 403 STEP_UP_REQUIRED; со step-up — изменение, аудит before/after, кэш сброшен', async () => {
    const noStep = await put(admin, { customerStockDisplay: 'quantity' }, null);
    expect(noStep.status).toBe(403);
    expect(noStep.body).toMatchObject({ code: 'STEP_UP_REQUIRED', stepUp: { operation: 'settings.app.update' } });
    const reader = t.app.get(SettingsReader);
    expect(await reader.get('customer_stock_display')).toBe('status');
    const ok = await put(admin, {
      customerStockDisplay: 'quantity',
      returnsEnabled: false,
      returnApprovalThreshold: { amount: '25000.00', currency: 'KGS' },
      'receivables.maxAgeMinutes': 30,
    });
    expect(ok.status).toBe(200);
    expect(ok.body.settings).toMatchObject({
      customerStockDisplay: 'quantity',
      returnsEnabled: false,
      returnApprovalThreshold: { amount: '25000.00', currency: 'KGS' },
      'receivables.maxAgeMinutes': 30,
    });
    expect(await reader.get('customer_stock_display')).toBe('quantity');
    expect(await reader.get('returns_enabled')).toBe(false);
    expect(await reader.get('receivables.max_age_minutes')).toBe(30);
    const audit = (await t.auditRows('settings.changed')).filter((a) => a.level === 'app').at(-1);
    expect(audit).toMatchObject({
      actor_user_id: admin.userId,
      step_up_method: 'pin',
      before: {
        customerStockDisplay: 'status',
        returnsEnabled: true,
        returnApprovalThreshold: { amount: '10000.00', currency: 'KGS' },
        'receivables.maxAgeMinutes': 60,
      },
      after: { customerStockDisplay: 'quantity', returnsEnabled: false, 'receivables.maxAgeMinutes': 30 },
    });
    // событие видно в журнале аудита (owner — полностью)
    const now = Date.now();
    const log = await t.req(
      'get',
      `/admin/audit-logs?action=settings.changed&from=${new Date(now - 3600_000).toISOString()}&to=${new Date(now + 60_000).toISOString()}`,
      owner,
    );
    expect(log.status).toBe(200);
    const row = (log.body.items as { after: Record<string, unknown>; stepUpMethod: string; chainOk: boolean }[]).find(
      (r) => r.stepUpMethod === 'pin',
    );
    expect(row).toMatchObject({ chainOk: true, after: { customerStockDisplay: 'quantity' } });
  });

  it('RM-D-015 п. 2: недопустимые значения ключей G → VALIDATION_FAILED; customerSelfService → 400 read_only_setting', async () => {
    const r422 = await put(admin, {
      customerStockDisplay: 'numbers',
      'receivables.maxAgeMinutes': 1441,
      returnApprovalThreshold: { amount: '1.5', currency: 'KGS' },
    });
    expect(r422.status).toBe(422);
    expect((r422.body.errors as { field: string; rule: string }[]).map((e) => `${e.field}:${e.rule}`)).toEqual([
      'settings.customerStockDisplay:enum',
      'settings.receivables.maxAgeMinutes:max',
      'settings.returnApprovalThreshold:money_format',
    ]);
    const r400 = await put(admin, { returnsEnabled: 'no' });
    expect([r400.status, r400.body.errors[0].rule]).toEqual([400, 'type']);
    const ro = await put(admin, { customerSelfService: false });
    expect([ro.status, ro.body.errors[0].rule]).toEqual([400, 'read_only_setting']);
    expect((await t.req('get', '/admin/settings', admin)).body.env.customerSelfService).toBe(true);
  });
});
