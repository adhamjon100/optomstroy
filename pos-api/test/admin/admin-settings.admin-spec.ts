import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { parse } from 'yaml';
import {
  ADMIN_SETTING_KEYS,
  ADMIN_SETTINGS_ENV_FIELDS,
  checkSettingValue,
} from '../../src/admin/settings/admin-settings.map.js';
import { SettingsReader } from '../../src/common/settings/settings-reader.js';
import { type Actor, AdminTestApp } from './support/admin-app.js';

/**
 * RM-D-015 п. 2 и 08 §4.18.6 (API-117, API-164; ядро §19.2): `GET/PUT /admin/settings` на embedded PostgreSQL 17
 * с seed `seeds/0001_defaults.sql`. Запись ключа `CUSTOMER_SELF_SERVICE` через API → VALIDATION_FAILED
 * (`read_only_setting`), интервалы — только `syncInterval.<entity>`, step-up, rowVersion, аудит before/after.
 */
interface Schema {
  properties?: Record<string, unknown>;
}

function contractSchema(name: string): Schema {
  const file = fileURLToPath(new URL('../../../contracts/openapi/pos-api.v1.yaml', import.meta.url));
  const doc = parse(readFileSync(file, 'utf8')) as { components: { schemas: Record<string, Schema> } };
  const s = doc.components.schemas[name];
  if (!s) throw new Error(`нет схемы ${name}`);
  return s;
}

/** `errors[]` тела Problem. */
const errs = (body: unknown): { field: string; rule: string }[] =>
  (body as { errors?: { field: string; rule: string }[] }).errors ?? [];

const SEED = fileURLToPath(new URL('../../seeds/0001_defaults.sql', import.meta.url));

describe('admin/settings: GET/PUT /admin/settings (RM-D-015 п. 2; 08 §4.18.6)', () => {
  const t = new AdminTestApp();
  let admin: Actor;
  let owner: Actor;
  const su = async () => t.stepUp(admin, 'settings.app.update');
  const put = async (body: unknown, stepUp?: string) =>
    t.req('put', '/admin/settings', admin, { stepUp: stepUp ?? (await su()) }).send(body as object);
  const rowVersion = async () => (await t.req('get', '/admin/settings', admin)).body.rowVersion as number;

  beforeAll(async () => {
    await t.start('admin_settings_e2e');
    await t.q(readFileSync(SEED, 'utf8'));
    admin = await t.actor('admin');
    owner = await t.actor('owner');
  });

  afterAll(async () => {
    await t.stop();
  });

  it('таблица соответствия = контракт: AdminSettingsValues и AdminSettingsEnv (0 расхождений)', () => {
    const values = Object.keys(contractSchema('AdminSettingsValues').properties ?? {}).sort();
    expect(ADMIN_SETTING_KEYS.map((k) => k.apiField).sort()).toEqual(values);
    const env = Object.keys(contractSchema('AdminSettingsEnv').properties ?? {}).sort();
    expect([...ADMIN_SETTINGS_ENV_FIELDS].sort()).toEqual(env);
    // ключ CUSTOMER_SELF_SERVICE — только env (ядро §19.2): ни ключа app_settings, ни поля settings
    expect(ADMIN_SETTING_KEYS.some((k) => k.key.includes('self_service'))).toBe(false);
    expect(values).not.toContain('customerSelfService');
    // интервалы — только sync_interval.<entity> (ядро §17.7), прежней формы sync.intervals нет
    expect(
      ADMIN_SETTING_KEYS.filter((k) => k.key.startsWith('sync')).every((k) => k.key.startsWith('sync_interval.')),
    ).toBe(true);
  });

  it('RBAC и step-up: GET — admin/owner; PUT — только admin со step-up settings.app.update; без Bearer → 401', async () => {
    for (const role of ['seller', 'cashier', 'senior_seller', 'customer'] as const) {
      const a = await t.actor(role);
      const r = await t.req('get', '/admin/settings', a);
      expect([r.status, r.body.code], role).toEqual([403, 'FORBIDDEN']);
    }
    const ownerGet = await t.req('get', '/admin/settings', owner);
    expect(ownerGet.status).toBe(200);
    expect(ownerGet.headers['cache-control']).toBe('no-store');
    const ownerPut = await t
      .req('put', '/admin/settings', owner, { stepUp: await t.stepUp(owner, 'settings.app.update') })
      .send({ settings: { lowStockThreshold: 3 }, rowVersion: 0 });
    expect([ownerPut.status, ownerPut.body.code]).toEqual([403, 'FORBIDDEN']);
    const noStepUp = await t.req('put', '/admin/settings', admin).send({ settings: {}, rowVersion: 0 });
    expect(noStepUp.status).toBe(403);
    expect(noStepUp.body).toMatchObject({ code: 'STEP_UP_REQUIRED', stepUp: { operation: 'settings.app.update' } });
    const wrongScope = await put({ settings: {}, rowVersion: 0 }, await t.stepUp(admin, 'users.manage'));
    expect(wrongScope.body.code).toBe('STEP_UP_REQUIRED');
    expect((await t.req('get', '/admin/settings')).status).toBe(401);
  });

  it('GET: ключи seed в camelCase, null у ненулевого поля не выводится, env только для чтения, без секретов', async () => {
    const r = await t.req('get', '/admin/settings', admin);
    expect(r.status).toBe(200);
    expect(Object.keys(r.body).sort()).toEqual(['env', 'rowVersion', 'settings']);
    expect(r.body.settings).toMatchObject({
      lowStockThreshold: 5,
      cartStaleMinutes: 15,
      parkedCartTtlDays: 7,
      overpayAllowed: false,
      returnApprovalThreshold: { amount: '10000.00', currency: 'KGS' },
      returnsEnabled: true,
      cashRounding: 'none',
      deliverySlots: [],
      'receivables.maxAgeMinutes': 60,
      privacyContact: null,
      customerStockDisplay: 'status',
    });
    expect(r.body.settings).not.toHaveProperty('minAppVersion'); // null — действует env MIN_APP_VERSION
    expect(r.body.settings).not.toHaveProperty('syncInterval.stock'); // null — расписание env SYNC_*_CRON
    const allowed = Object.keys(contractSchema('AdminSettingsValues').properties ?? {});
    expect(Object.keys(r.body.settings).filter((k) => !allowed.includes(k))).toEqual([]);
    const envAllowed = Object.keys(contractSchema('AdminSettingsEnv').properties ?? {});
    expect(Object.keys(r.body.env).filter((k) => !envAllowed.includes(k))).toEqual([]);
    expect(r.body.env).toMatchObject({
      customerSelfService: true,
      qrProvider: 'onec',
      minAppVersion: 'android=1.0.0,windows=1.0.0',
      recommendedAppVersion: null,
      otpTtlSeconds: 300,
      sessionIdleLockMinutes: 30,
      authBackgroundLockMinutes: 5,
    });
    expect(JSON.stringify(r.body)).not.toMatch(/password|secret|pepper|BEGIN/i);
    const seeded = await t.q<{ s: string }>(
      `SELECT sum(row_version)::text AS s FROM app_settings WHERE key = ANY($1::text[])`,
      [ADMIN_SETTING_KEYS.map((k) => k.key)],
    );
    expect(r.body.rowVersion).toBe(Number(seeded[0]?.s));
  });

  it('AC-API-164 / RM-D-015 п. 2: customerSelfService → 400 read_only_setting; sync.intervals → 400 unknown_setting; syncInterval.stock 300 → 200', async () => {
    const v = await rowVersion();
    const ro = await put({ settings: { customerSelfService: false }, rowVersion: v });
    expect(ro.status).toBe(400);
    expect(ro.body).toMatchObject({ code: 'VALIDATION_FAILED' });
    expect(ro.body.errors).toEqual([
      expect.objectContaining({ field: 'settings.customerSelfService', rule: 'read_only_setting' }),
    ]);
    const snake = await put({ settings: { customer_self_service: false }, rowVersion: v });
    expect(snake.body.errors[0]).toMatchObject({ rule: 'unknown_setting' });
    const old = await put({ settings: { 'sync.intervals': { stock: 300 } }, rowVersion: v });
    expect(old.status).toBe(400);
    expect(old.body.errors[0]).toMatchObject({ field: 'settings.sync.intervals', rule: 'unknown_setting' });
    const envOnly = await put({ settings: { otpTtlSeconds: 200, qrProvider: 'none' }, rowVersion: v });
    expect(errs(envOnly.body).map((e) => e.rule)).toEqual(['read_only_setting', 'read_only_setting']);
    expect(await t.q(`SELECT key FROM app_settings WHERE key LIKE '%self_service%'`)).toEqual([]);

    const ok = await put({ settings: { 'syncInterval.stock': 300 }, rowVersion: v });
    expect(ok.status).toBe(200);
    expect(ok.body.settings['syncInterval.stock']).toBe(300);
    expect(ok.body.rowVersion).toBe(v + 1);
    const [row] = await t.q<{ value: unknown; updated_by_user_id: string }>(
      `SELECT value, updated_by_user_id FROM app_settings WHERE key = 'sync_interval.stock'`,
    );
    expect(row).toEqual({ value: 300, updated_by_user_id: admin.userId });
    const audit = (await t.auditRows('settings.changed')).filter((a) => a.level === 'app');
    expect(audit.at(-1)).toMatchObject({
      actor_user_id: admin.userId,
      step_up_method: 'pin',
      before: { 'syncInterval.stock': null },
      after: { 'syncInterval.stock': 300 },
      reason: 'Изменение настроек системы (SCR-46): syncInterval.stock',
    });
    // аудит БД по строке (trg_app_settings_audit)
    expect((await t.auditRows('settings.changed')).some((a) => a.level === 'db')).toBe(true);
  });

  it('схема тела → 400 (type, additional_properties, rowVersion); перечни и диапазоны → 422; смешанные → 400', async () => {
    const v = await rowVersion();
    const typed = await put({ settings: { lowStockThreshold: '5', overpayAllowed: 'yes' }, rowVersion: v });
    expect(typed.status).toBe(400);
    expect(errs(typed.body).map((e) => `${e.field}:${e.rule}`)).toEqual([
      'settings.lowStockThreshold:type',
      'settings.overpayAllowed:type',
    ]);
    expect((await put({ settings: {} })).status).toBe(400); // нет rowVersion
    const extra = await put({ settings: {}, rowVersion: v, env: {} });
    expect(extra.body.errors[0]).toMatchObject({ field: 'env', rule: 'additional_properties' });
    expect((await put({ settings: [1], rowVersion: v })).status).toBe(400);

    const ranges = await put({
      settings: {
        customerStockDisplay: 'all',
        parkedCartTtlDays: 31,
        'otp.ttlSeconds': 100,
        'receivables.maxAgeMinutes': 2,
        'syncInterval.prices': 59,
        cashRounding: 'to_tyiyn',
        minAppVersion: 'android=abc',
        deliverySlots: [{ from: '25:00', to: '14:00' }],
        returnApprovalThreshold: { amount: '-1.00', currency: 'KGS' },
      },
      rowVersion: v,
    });
    expect(ranges.status).toBe(422);
    expect(ranges.body.code).toBe('VALIDATION_FAILED');
    expect(errs(ranges.body).map((e) => `${e.field}:${e.rule}`)).toEqual([
      'settings.customerStockDisplay:enum',
      'settings.parkedCartTtlDays:max',
      'settings.otp.ttlSeconds:min',
      'settings.receivables.maxAgeMinutes:min',
      'settings.syncInterval.prices:min',
      'settings.cashRounding:enum',
      'settings.minAppVersion:format',
      'settings.deliverySlots:pattern',
      'settings.returnApprovalThreshold:min',
    ]);
    const mixed = await put({ settings: { customerStockDisplay: 'all', foo: 1 }, rowVersion: v });
    expect(mixed.status).toBe(400);
    expect(mixed.body.errors).toEqual([expect.objectContaining({ rule: 'unknown_setting' })]);
    expect(await rowVersion()).toBe(v); // ничего не записано
  });

  it('rowVersion: устаревшая → 409 VERSION_CONFLICT с current.rowVersion; повтор того же тела → 200 без изменений', async () => {
    const v = await rowVersion();
    const first = await put({ settings: { customerStockDisplay: 'quantity', lowStockThreshold: 3 }, rowVersion: v });
    expect(first.status).toBe(200);
    expect(first.body.rowVersion).toBe(v + 2);
    const auditBefore = (await t.auditRows('settings.changed')).length;
    const replay = await put({ settings: { customerStockDisplay: 'quantity', lowStockThreshold: 3 }, rowVersion: v });
    expect(replay.status).toBe(200);
    expect(replay.body.rowVersion).toBe(v + 2);
    expect((await t.auditRows('settings.changed')).length).toBe(auditBefore);
    const stale = await put({ settings: { lowStockThreshold: 4 }, rowVersion: v });
    expect(stale.status).toBe(409);
    expect(stale.body).toMatchObject({ code: 'VERSION_CONFLICT', current: { rowVersion: v + 2 } });
    const [row] = await t.q<{ value: unknown }>(`SELECT value FROM app_settings WHERE key = 'low_stock_threshold'`);
    expect(row?.value).toBe(3);
  });

  it('новый ключ (нет строки seed) создаётся; версии нормализуются; кэш SettingsReader сбрасывается сразу', async () => {
    const reader = t.app.get(SettingsReader);
    expect(await reader.get('support_contacts')).toBeUndefined(); // в кэше «нет ключа»
    expect(await reader.get('customer_stock_display')).toBe('quantity');
    const v = await rowVersion();
    const r = await put({
      settings: {
        supportContacts: [{ kind: 'phone', value: ' +996700000005 ', label: 'Поддержка' }],
        minAppVersion: 'android=1.2.0, windows=1.2.0',
        recommendedAppVersion: null,
        privacyContact: '  privacy@example.kg ',
        customerStockDisplay: 'status',
        'print.defaultPaper': 'thermal80',
      },
      rowVersion: v,
    });
    expect(r.status).toBe(200);
    expect(r.body.settings).toMatchObject({
      supportContacts: [{ kind: 'phone', value: '+996700000005', label: 'Поддержка' }],
      minAppVersion: 'android=1.2.0,windows=1.2.0',
      recommendedAppVersion: null,
      privacyContact: 'privacy@example.kg',
      customerStockDisplay: 'status',
      'print.defaultPaper': 'thermal80',
    });
    const rows = await t.q<{ key: string; value_type: string; row_version: number }>(
      `SELECT key, value_type, row_version FROM app_settings
        WHERE key IN ('support_contacts', 'print.default_paper', 'recommended_app_version') ORDER BY key`,
    );
    expect(rows).toEqual([
      { key: 'print.default_paper', value_type: 'string', row_version: 1 },
      { key: 'recommended_app_version', value_type: 'string', row_version: 1 },
      { key: 'support_contacts', value_type: 'json', row_version: 1 },
    ]);
    // recommended_app_version: строки не было, null записан как «не задано»
    expect(r.body.rowVersion).toBe(v + 3 + 3);
    expect(await reader.get('support_contacts')).toEqual([
      { kind: 'phone', value: '+996700000005', label: 'Поддержка' },
    ]);
    expect(await reader.get('customer_stock_display')).toBe('status');
    expect(await reader.get('min_app_version')).toBe('android=1.2.0,windows=1.2.0');
  });

  it('checkSettingValue: нулевые/ненулевые поля, Money, контакты, массивы строк, объекты json', () => {
    const rule = (field: string) => {
      const def = ADMIN_SETTING_KEYS.find((k) => k.apiField === field);
      if (!def) throw new Error(field);
      return def.rule;
    };
    expect(checkSettingValue(rule('minAppVersion'), null)).toMatchObject({ ok: false, status: 400, rule: 'type' });
    expect(checkSettingValue(rule('minAppVersion'), '')).toMatchObject({ ok: false, status: 422 });
    expect(checkSettingValue(rule('privacyContact'), '   ')).toEqual({ ok: true, value: null });
    expect(checkSettingValue(rule('privacyContact'), 'x'.repeat(301))).toMatchObject({ rule: 'maxLength' });
    expect(checkSettingValue(rule('returnApprovalThreshold'), { amount: '1.5', currency: 'KGS' })).toMatchObject({
      status: 422,
      rule: 'money_format',
    });
    expect(checkSettingValue(rule('returnApprovalThreshold'), { amount: '1.50', currency: 'USD' })).toMatchObject({
      rule: 'enum',
    });
    expect(checkSettingValue(rule('returnApprovalThreshold'), { amount: '1.50', currency: 'KGS', x: 1 })).toMatchObject(
      { status: 400, rule: 'additional_properties' },
    );
    expect(checkSettingValue(rule('supportContacts'), [{ kind: 'fax', value: '1' }])).toMatchObject({ rule: 'enum' });
    expect(checkSettingValue(rule('supportContacts'), [{ kind: 'email', value: '' }])).toMatchObject({
      rule: 'maxLength',
    });
    expect(checkSettingValue(rule('supportContacts'), [{ kind: 'email', value: 'a', label: 5 }])).toMatchObject({
      status: 400,
    });
    expect(checkSettingValue(rule('secureScreens'), ['SCR-21', 'x'.repeat(51)])).toMatchObject({ rule: 'maxLength' });
    expect(checkSettingValue(rule('secureScreens'), Array(501).fill('S'))).toMatchObject({ rule: 'maxItems' });
    expect(checkSettingValue(rule('secureScreens'), [1])).toMatchObject({ status: 400 });
    expect(checkSettingValue(rule('consentTexts'), { personal_data: '2026-10-01' })).toMatchObject({ ok: true });
    expect(checkSettingValue(rule('consentTexts'), [])).toMatchObject({ status: 400 });
    expect(checkSettingValue(rule('deliverySlots'), [{ from: '10:00' }])).toMatchObject({ status: 400 });
    expect(checkSettingValue(rule('deliverySlots'), Array(501).fill({ from: '10:00', to: '11:00' }))).toMatchObject({
      rule: 'maxItems',
    });
    expect(checkSettingValue(rule('otp.maxAttempts'), 1.5)).toMatchObject({ status: 400, rule: 'type' });
    expect(checkSettingValue(rule('qr.enabled'), 1)).toMatchObject({ status: 400 });
    expect(checkSettingValue(rule('cashRounding'), 1)).toMatchObject({ status: 400 });
  });
});
