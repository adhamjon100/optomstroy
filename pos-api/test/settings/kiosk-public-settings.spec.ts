import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parse } from 'yaml';
import {
  ADMIN_SETTING_BY_FIELD,
  ADMIN_SETTING_KEYS,
  ADMIN_SETTINGS_ENV_FIELDS,
  checkSettingValue,
} from '../../src/admin/settings/admin-settings.map.js';
import { AdminSettingsService } from '../../src/admin/settings/admin-settings.service.js';
import { AppVersionPolicy } from '../../src/common/app-version/app-version.policy.js';
import { SettingsReader } from '../../src/common/settings/settings-reader.js';
import {
  KIOSK_INTEGER_SETTINGS,
  parseKioskWorkingHours,
  PUBLIC_APP_SETTING_KEYS,
  PUBLIC_ENV_SETTINGS,
  PUBLIC_SETTINGS_KIOSK,
} from '../../src/settings/public-settings.map.js';
import { PublicSettingsService } from '../../src/settings/public-settings.service.js';
import { FakeSettingsTable, testConfig } from '../support/test-app.js';
import { validateAgainst } from './support/openapi-check.js';

/**
 * Планшет магазина в настройках (P-002 §13; ADR-115; 08 §4.18.6, §4.23.1; 07 §5.59 «Ключи планшета магазина») —
 * без БД (FakeSettingsTable, тестовые значения):
 * - `GET /settings/public`: `features.storeTablet` = env `KIOSK_MODE` (по умолчанию `false`, от
 *   `CUSTOMER_SELF_SERVICE` не зависит — 12 T-KIOSK-033), объект `kiosk {idleSeconds, idleWarningSeconds,
 *   doneSeconds}` из ключей `kiosk_*` или значений по умолчанию кода (120, 15, 60 с); лимиты кодов и часы работы не
 *   отдаются;
 * - `/admin/settings`: шесть ключей `kiosk*` с границами 08 §4.18.6 и значениями по умолчанию кода, формат
 *   `kioskWorkingHours`, `env.kioskMode` — только чтение.
 */
function publicService(env: Record<string, string>, values: Record<string, unknown> = {}): PublicSettingsService {
  const table = new FakeSettingsTable();
  for (const [k, v] of Object.entries(values)) table.values.set(k, v);
  const reader = new SettingsReader(table.pool as never);
  const config = testConfig(env);
  return new PublicSettingsService(reader, new AppVersionPolicy(config, reader), config);
}

function adminService(env: Record<string, string> = {}): AdminSettingsService {
  const repo = { load: () => Promise.resolve([]) };
  return new AdminSettingsService({} as never, testConfig(env), repo as never, {} as never, {} as never);
}

function contractSchema(name: string): { properties?: Record<string, Record<string, unknown>> } {
  const file = fileURLToPath(new URL('../../../contracts/openapi/pos-api.v1.yaml', import.meta.url));
  const doc = parse(readFileSync(file, 'utf8')) as {
    components: { schemas: Record<string, { properties?: Record<string, Record<string, unknown>> }> };
  };
  const s = doc.components.schemas[name];
  if (!s) throw new Error(`нет схемы ${name}`);
  return s;
}

const KIOSK_KEYS = [
  'kiosk_idle_seconds',
  'kiosk_idle_warning_seconds',
  'kiosk_done_seconds',
  'kiosk_otp_per_hour',
  'kiosk_otp_per_day',
  'kiosk_working_hours',
];

describe('GET /settings/public: планшет магазина (08 §4.23.1; ADR-115)', () => {
  it('T-KIOSK-033 features.storeTablet false: по умолчанию KIOSK_MODE=false; четыре сочетания с CUSTOMER_SELF_SERVICE', async () => {
    expect((await publicService({}).read()).features.storeTablet).toBe(false);
    for (const kiosk of ['true', 'false']) {
      for (const self of ['true', 'false']) {
        const f = (await publicService({ KIOSK_MODE: kiosk, CUSTOMER_SELF_SERVICE: self }).read()).features;
        expect({ storeTablet: f.storeTablet, customerSelfService: f.customerSelfService }, `${kiosk}/${self}`).toEqual({
          storeTablet: kiosk === 'true',
          customerSelfService: self === 'true',
        });
      }
    }
    // Флаг — только env (как customerSelfService, ядро §19.2): ключ app_settings с тем же смыслом игнорируется.
    const ignored = publicService({ KIOSK_MODE: 'false' }, { kiosk_mode: true, store_tablet: true });
    expect((await ignored.read()).features.storeTablet).toBe(false);
  });

  it('kiosk: значения по умолчанию кода 120 / 15 / 60 с; ключи app_settings; объект — при любом KIOSK_MODE; схема контракта', async () => {
    for (const mode of ['true', 'false']) {
      const body = await publicService({ KIOSK_MODE: mode }).read();
      expect(body.kiosk).toEqual({ idleSeconds: 120, idleWarningSeconds: 15, doneSeconds: 60 });
      expect(validateAgainst('PublicSettings', body)).toEqual([]);
    }
    const set = await publicService(
      { KIOSK_MODE: 'true' },
      { kiosk_idle_seconds: 300, kiosk_idle_warning_seconds: 20, kiosk_done_seconds: 30 },
    ).read();
    expect(set.kiosk).toEqual({ idleSeconds: 300, idleWarningSeconds: 20, doneSeconds: 30 });
    expect(Object.keys(set.kiosk).sort()).toEqual([...PUBLIC_SETTINGS_KIOSK].sort());
  });

  it('неверные значения ключей kiosk_* (вне границ 08 §4.18.6, не целые, не числа) → значения по умолчанию (не 500)', async () => {
    const bounds = await publicService(
      {},
      { kiosk_idle_seconds: 29, kiosk_idle_warning_seconds: 121, kiosk_done_seconds: 601 },
    ).read();
    expect(bounds.kiosk).toEqual({ idleSeconds: 120, idleWarningSeconds: 15, doneSeconds: 60 });
    const types = await publicService(
      {},
      { kiosk_idle_seconds: '300', kiosk_idle_warning_seconds: 10.5, kiosk_done_seconds: null },
    ).read();
    expect(types.kiosk).toEqual({ idleSeconds: 120, idleWarningSeconds: 15, doneSeconds: 60 });
    const edges = await publicService(
      {},
      { kiosk_idle_seconds: 30, kiosk_idle_warning_seconds: 120, kiosk_done_seconds: 600 },
    ).read();
    expect(edges.kiosk).toEqual({ idleSeconds: 30, idleWarningSeconds: 120, doneSeconds: 600 });
  });

  it('лимиты кодов и часы работы планшету не отдаются; публичны ровно три тайминга и KIOSK_MODE', async () => {
    const body = await publicService(
      { KIOSK_MODE: 'true' },
      { kiosk_otp_per_hour: 31, kiosk_otp_per_day: 201, kiosk_working_hours: 'mon-sat 08:00-20:00' },
    ).read();
    const text = JSON.stringify(body);
    expect(text).not.toMatch(/otp|workingHours|08:00|\b31\b|\b201\b/i);
    expect(PUBLIC_APP_SETTING_KEYS.filter((k) => k.key.startsWith('kiosk_')).map((k) => k.key)).toEqual([
      'kiosk_idle_seconds',
      'kiosk_idle_warning_seconds',
      'kiosk_done_seconds',
    ]);
    expect(PUBLIC_ENV_SETTINGS.find((e) => e.env === 'KIOSK_MODE')).toEqual({
      env: 'KIOSK_MODE',
      apiField: 'env.kioskMode',
      publicFields: ['features.storeTablet'],
    });
  });

  it('ETag меняется вместе с KIOSK_MODE и таймингом планшета (кэш клиента обновляется)', async () => {
    const off = await publicService({ KIOSK_MODE: 'false' }).readWithEtag();
    const on = await publicService({ KIOSK_MODE: 'true' }).readWithEtag();
    const idle = await publicService({ KIOSK_MODE: 'true' }, { kiosk_idle_seconds: 90 }).readWithEtag();
    expect(new Set([off.etag, on.etag, idle.etag]).size).toBe(3);
  });
});

describe('/admin/settings: ключи планшета магазина (08 §4.18.6; 07 §5.59)', () => {
  it('шесть ключей kiosk_* — поля контракта AdminSettingsValues, integer/string, значения по умолчанию кода', () => {
    const rows = ADMIN_SETTING_KEYS.filter((k) => k.key.startsWith('kiosk_'));
    expect(rows.map((k) => k.key)).toEqual(KIOSK_KEYS);
    const contract = contractSchema('AdminSettingsValues').properties ?? {};
    for (const r of rows) {
      expect(contract[r.apiField], r.apiField).toBeDefined();
      if (r.valueType === 'integer') {
        expect(r.rule).toEqual({
          kind: 'integer',
          min: contract[r.apiField]?.minimum,
          max: contract[r.apiField]?.maximum,
        });
      }
    }
    expect(Object.fromEntries(rows.map((r) => [r.apiField, r.codeDefault]))).toEqual({
      kioskIdleSeconds: 120,
      kioskIdleWarningSeconds: 15,
      kioskDoneSeconds: 60,
      kioskOtpPerHour: 30,
      kioskOtpPerDay: 200,
      kioskWorkingHours: '',
    });
    expect(rows.map((r) => r.valueType)).toEqual(['integer', 'integer', 'integer', 'integer', 'integer', 'string']);
    // Значения по умолчанию public и admin — один источник (KIOSK_INTEGER_SETTINGS).
    for (const [key, s] of Object.entries(KIOSK_INTEGER_SETTINGS)) {
      expect(ADMIN_SETTING_KEYS.find((k) => k.key === key)?.codeDefault, key).toBe(s.default);
    }
  });

  it('границы 08 §4.18.6: 30…1800, 5…120, 10…600, 1…1000, 1…10000 → min/max 422; не целое → 400 type', () => {
    const cases: [string, number, number][] = [
      ['kioskIdleSeconds', 30, 1800],
      ['kioskIdleWarningSeconds', 5, 120],
      ['kioskDoneSeconds', 10, 600],
      ['kioskOtpPerHour', 1, 1000],
      ['kioskOtpPerDay', 1, 10_000],
    ];
    for (const [field, min, max] of cases) {
      const rule = ADMIN_SETTING_BY_FIELD.get(field)?.rule;
      if (!rule) throw new Error(`нет поля ${field}`);
      expect(checkSettingValue(rule, min), field).toEqual({ ok: true, value: min });
      expect(checkSettingValue(rule, max), field).toEqual({ ok: true, value: max });
      expect(checkSettingValue(rule, min - 1), field).toMatchObject({ ok: false, status: 422, rule: 'min' });
      expect(checkSettingValue(rule, max + 1), field).toMatchObject({ ok: false, status: 422, rule: 'max' });
      expect(checkSettingValue(rule, '60'), field).toMatchObject({ ok: false, status: 400, rule: 'type' });
      expect(checkSettingValue(rule, 60.5), field).toMatchObject({ ok: false, status: 400, rule: 'type' });
    }
  });

  it('kioskWorkingHours — формат 07 §5.59: дни mon…sun, диапазоны через «;», начало раньше конца; пусто — алерт выключен', () => {
    const rule = ADMIN_SETTING_BY_FIELD.get('kioskWorkingHours')?.rule;
    if (!rule) throw new Error('нет поля kioskWorkingHours');
    for (const ok of ['', 'mon-sat 08:00-20:00;sun 09:00-15:00', 'mon 00:00-23:59', ' fri 10:00-18:00 ']) {
      expect(checkSettingValue(rule, ok), ok).toEqual({ ok: true, value: ok.trim() });
    }
    for (const bad of [
      'пн–сб 08:00–20:00',
      'mon-sat 20:00-08:00',
      'mon-sat 08:00-08:00',
      'sat-mon 08:00-20:00',
      'mon-sat 8:00-20:00',
      'mon-sat 08:00-24:00',
      'xyz 08:00-20:00',
      'mon-sat 08:00-20:00;',
      'mon-sat 08:00-20:00,sun 09:00-15:00',
    ]) {
      expect(checkSettingValue(rule, bad), bad).toMatchObject({ ok: false, status: 422, rule: 'format' });
    }
    expect(checkSettingValue(rule, `mon 08:00-20:00;${'sun 09:00-15:00;'.repeat(13)}sun 09:00-15:00`)).toMatchObject({
      ok: false,
      status: 422,
      rule: 'maxLength',
    });
    expect(checkSettingValue(rule, 8)).toMatchObject({ ok: false, status: 400, rule: 'type' });
    expect(parseKioskWorkingHours('mon-sat 08:00-20:00;sun 09:00-15:00')).toEqual([
      { days: [0, 1, 2, 3, 4, 5], fromMinutes: 480, toMinutes: 1200 },
      { days: [6], fromMinutes: 540, toMinutes: 900 },
    ]);
  });

  it('GET без строк kiosk_* — значения по умолчанию кода; env.kioskMode = KIOSK_MODE (только чтение); поля — в контракте', async () => {
    const off = await adminService().get();
    expect(off.settings).toEqual({
      kioskIdleSeconds: 120,
      kioskIdleWarningSeconds: 15,
      kioskDoneSeconds: 60,
      kioskOtpPerHour: 30,
      kioskOtpPerDay: 200,
      kioskWorkingHours: '',
    });
    expect(off.env.kioskMode).toBe(false);
    expect((await adminService({ KIOSK_MODE: 'true' }).get()).env.kioskMode).toBe(true);
    expect(ADMIN_SETTINGS_ENV_FIELDS).toContain('kioskMode');
    expect(ADMIN_SETTING_BY_FIELD.has('kioskMode')).toBe(false);
    const envContract = Object.keys(contractSchema('AdminSettingsEnv').properties ?? {});
    expect(Object.keys(off.env).filter((k) => !envContract.includes(k))).toEqual([]);
    const values = validateAgainst('AdminSettingsValues', off.settings);
    expect(values).toEqual([]);
  });

  it('PUT env.kioskMode → 400 read_only_setting (переключение — только env и перезапуск, 06 AC-ARCH-067)', async () => {
    const req = {
      headers: {},
      principal: {
        userId: '00000000-0000-7000-8000-000000000001',
        kind: 'staff',
        roles: ['admin'],
        status: 'active',
        sessionId: '00000000-0000-7000-8000-000000000002',
        deviceId: 'device',
        jti: 'jti',
        permissionsVersion: 1,
        amr: ['pin'],
        tokenExpiresAt: new Date(),
      },
    };
    await expect(
      adminService().update(req as never, { settings: { kioskMode: true }, rowVersion: 0 }),
    ).rejects.toMatchObject({
      code: 'VALIDATION_FAILED',
      extensions: { errors: [{ field: 'settings.kioskMode', rule: 'read_only_setting' }] },
    });
  });
});
