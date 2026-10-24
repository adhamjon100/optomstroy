import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { sql } from 'drizzle-orm';
import request from 'supertest';
import { PermissionCatalog } from '../../src/common/rbac/permission-catalog.js';
import { SettingsReader } from '../../src/common/settings/settings-reader.js';
import { PUBLIC_SETTINGS_FEATURES, PUBLIC_SETTINGS_TOP_LEVEL } from '../../src/settings/public-settings.map.js';
import { type Actor, LinksTestApp } from '../customers/support/links-app.js';
import { validateAgainst } from './support/openapi-check.js';

/** Строки, которых не должно быть в публичных настройках (секреты, OTP/лимиты, внутренние адреса — 08 §4.23.1). */
const FORBIDDEN_FRAGMENTS = [
  /secret/i,
  /password|pwd/i,
  /otp/i,
  /smspro/i,
  /DATABASE_URL|postgres:\/\//i,
  /jwt|BEGIN [A-Z ]*KEY/i,
  /pepper/i,
  /127\.0\.0\.1|localhost/i,
  /ttlSeconds|maxAttempts|rateLimit/i,
];

describe('RM-D-015 GET /settings/public (08 §4.23.1, API-157; embedded PG17 + seeds/0001_defaults.sql)', () => {
  const t = new LinksTestApp();
  const http = () => request(t.app.getHttpServer());
  const get = (a: Actor, headers: Record<string, string> = {}) => {
    let r = http()
      .get('/api/v1/settings/public')
      .set('Authorization', `Bearer ${a.token}`)
      .set('X-Device-Id', a.deviceKey);
    for (const [k, v] of Object.entries(headers)) r = r.set(k, v);
    return r;
  };

  beforeAll(async () => {
    await t.start('public_settings', {
      CUSTOMER_SELF_SERVICE: 'true',
      DEBT_PAYMENTS_FROM_POS: 'true',
      QR_PROVIDER: 'onec',
      RECOMMENDED_APP_VERSION: 'android=1.3.0,windows=1.3.0',
    });
    // Системные значения по умолчанию (RM-C-006) + ключи, которые заполняет администратор.
    const seed = readFileSync(fileURLToPath(new URL('../../seeds/0001_defaults.sql', import.meta.url)), 'utf8');
    await t.fdb.pool.query(seed);
    await t.db.execute(sql`
      UPDATE app_settings SET value = '[{"from":"10:00","to":"14:00"},{"from":"14:00","to":"18:00"},{"from":"bad","to":"x"}]'::jsonb
       WHERE key = 'delivery_slots'`);
    await t.db.execute(sql`
      INSERT INTO app_settings (key, value, value_type, description_ru) VALUES
        ('support_contacts', '[{"kind":"phone","value":"+996700000005","label":"Поддержка"},{"kind":"fax","value":"1"}]'::jsonb,
         'json', 'Контакты поддержки (тест)')`);
    t.app.get(SettingsReader).invalidate();
  });

  afterAll(async () => {
    await t.stop();
  });

  it('критерий 1: все интерактивные роли и pending_activation → 200 с ровно перечисленными полями (схема контракта)', async () => {
    const actors: Actor[] = [];
    for (const role of ['seller', 'cashier', 'senior_seller', 'admin', 'owner', 'customer'] as const) {
      actors.push(await t.actor({ role }));
    }
    actors.push(await t.actor({ kind: 'customer', role: null, status: 'pending_activation' }));
    for (const a of actors) {
      const r = await get(a);
      expect(r.status, String(a.role)).toBe(200);
      expect(Object.keys(r.body).sort()).toEqual([...PUBLIC_SETTINGS_TOP_LEVEL].sort());
      expect(Object.keys(r.body.features).sort()).toEqual([...PUBLIC_SETTINGS_FEATURES].sort());
      expect(validateAgainst('PublicSettings', r.body)).toEqual([]);
    }
    const r = await get(actors[0]);
    expect(r.body).toEqual({
      deliverySlots: [
        { from: '10:00', to: '14:00' },
        { from: '14:00', to: '18:00' },
      ],
      supportContacts: [{ kind: 'phone', value: '+996700000005', label: 'Поддержка' }],
      privacyContact: null,
      lowStockThreshold: 5,
      minAppVersion: 'android=1.2.0,windows=1.2.0',
      recommendedAppVersion: 'android=1.3.0,windows=1.3.0',
      customerStockDisplay: 'status',
      features: {
        customerSelfService: true,
        returnsFromPos: true,
        qrProvider: 'onec',
        qrWebhook: false,
        debtPaymentsFromPos: true,
      },
    });
  });

  it('критерий 1: без Bearer → 401 UNAUTHENTICATED; integration-роль не имеет settings.public.read (→ 403)', async () => {
    const r = await http().get('/api/v1/settings/public');
    expect(r.status).toBe(401);
    expect(r.body.code).toBe('UNAUTHENTICATED');
    const catalog = t.app.get(PermissionCatalog);
    expect(catalog.effectivePermissions({ roles: ['integration'], status: 'active' }).has('settings.public.read')).toBe(
      false,
    );
    expect(catalog.effectivePermissions({ roles: [], status: 'pending_activation' }).has('settings.public.read')).toBe(
      true,
    );
  });

  it('критерий 1: секретов и ключей вне перечня нет', async () => {
    const a = await t.actor({ role: 'admin' });
    const text = JSON.stringify((await get(a)).body);
    for (const re of FORBIDDEN_FRAGMENTS) expect(text, String(re)).not.toMatch(re);
  });

  it('ETag + Cache-Control: private, max-age=300; If-None-Match → 304; изменение ключа меняет ETag', async () => {
    const a = await t.actor({ role: 'seller' });
    const first = await get(a);
    expect(first.headers['cache-control']).toBe('private, max-age=300');
    const etag = first.headers.etag;
    expect(etag).toMatch(/^W\/".+"$/);
    const notModified = await get(a, { 'If-None-Match': etag });
    expect(notModified.status).toBe(304);
    expect(notModified.text ?? '').toBe('');
    expect(notModified.headers.etag).toBe(etag);

    await t.db.execute(sql`UPDATE app_settings SET value = '"quantity"'::jsonb WHERE key = 'customer_stock_display'`);
    await t.db.execute(
      sql`UPDATE app_settings SET value = '"privacy@example.kg"'::jsonb WHERE key = 'privacy_contact'`,
    );
    t.app.get(SettingsReader).invalidate();
    const changed = await get(a, { 'If-None-Match': etag });
    expect(changed.status).toBe(200);
    expect(changed.headers.etag).not.toBe(etag);
    expect(changed.body.customerStockDisplay).toBe('quantity');
    expect(changed.body.privacyContact).toBe('privacy@example.kg');
  });

  it('features по app_settings: returns_enabled=false → returnsFromPos=false; qr.enabled=false → qrProvider=none', async () => {
    await t.db.execute(sql`UPDATE app_settings SET value = 'false'::jsonb WHERE key = 'returns_enabled'`);
    await t.db.execute(sql`
      INSERT INTO app_settings (key, value, value_type, description_ru)
      VALUES ('qr.enabled', 'false'::jsonb, 'boolean', 'QR (тест)')`);
    t.app.get(SettingsReader).invalidate();
    const a = await t.actor({ role: 'customer' });
    const r = await get(a);
    expect(r.body.features).toMatchObject({ returnsFromPos: false, qrProvider: 'none', qrWebhook: false });
  });

  it('критерий 2 (часть): CUSTOMER_SELF_SERVICE — не ключ app_settings (seed не создаёт customer_self_service)', async () => {
    const res = await t.db.execute<{ key: string }>(
      sql`SELECT key FROM app_settings WHERE key LIKE '%self_service%' OR key LIKE 'feature.%'`,
    );
    expect(res.rows).toEqual([]);
  });

  it('критерий 3 (часть): интервалы синхронизации в app_settings — только sync_interval.<entity>', async () => {
    const res = await t.db.execute<{ key: string }>(sql`SELECT key FROM app_settings WHERE key LIKE 'sync%'`);
    expect(res.rows.length).toBeGreaterThan(0);
    for (const { key } of res.rows) expect(key).toMatch(/^sync_interval\.[a-z_]+$/);
  });
});
