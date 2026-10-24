import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { AppVersionPolicy } from '../../src/common/app-version/app-version.policy.js';
import { SettingsReader } from '../../src/common/settings/settings-reader.js';
import { etagMatches } from '../../src/settings/public-settings.controller.js';
import {
  camelProjection,
  PUBLIC_APP_SETTING_KEYS,
  PUBLIC_ENV_SETTINGS,
  PUBLIC_SETTINGS_FEATURES,
  PUBLIC_SETTINGS_TOP_LEVEL,
} from '../../src/settings/public-settings.map.js';
import { PublicSettingsService } from '../../src/settings/public-settings.service.js';
import { FakeSettingsTable, testConfig } from '../support/test-app.js';
import { validateAgainst } from './support/openapi-check.js';

function serviceWith(env: Record<string, string>, values: Record<string, unknown> = {}): PublicSettingsService {
  const table = new FakeSettingsTable();
  for (const [k, v] of Object.entries(values)) table.values.set(k, v);
  const reader = new SettingsReader(table.pool as never);
  const config = testConfig(env);
  return new PublicSettingsService(reader, new AppVersionPolicy(config, reader), config);
}

describe('RM-D-015 PublicSettingsService (unit): флаги env и значения по умолчанию', () => {
  it('критерий 2: features.customerSelfService отражает env CUSTOMER_SELF_SERVICE (по умолчанию true)', async () => {
    expect((await serviceWith({}).read()).features.customerSelfService).toBe(true);
    expect((await serviceWith({ CUSTOMER_SELF_SERVICE: 'false' }).read()).features.customerSelfService).toBe(false);
    expect((await serviceWith({ CUSTOMER_SELF_SERVICE: 'true' }).read()).features.customerSelfService).toBe(true);
    // Ключ app_settings с тем же смыслом игнорируется: флаг — только env (ядро §19.2).
    const ignored = serviceWith({ CUSTOMER_SELF_SERVICE: 'false' }, { customer_self_service: true });
    expect((await ignored.read()).features.customerSelfService).toBe(false);
  });

  it('debtPaymentsFromPos — env; qrProvider — env QR_PROVIDER, none при qr.enabled=false; qrWebhook — bakai и qr.enabled', async () => {
    expect((await serviceWith({ DEBT_PAYMENTS_FROM_POS: 'true' }).read()).features.debtPaymentsFromPos).toBe(true);
    expect((await serviceWith({}).read()).features).toMatchObject({ qrProvider: 'onec', qrWebhook: false });
    expect((await serviceWith({ QR_PROVIDER: 'none' }).read()).features.qrProvider).toBe('none');
    expect((await serviceWith({}, { 'qr.enabled': false }).read()).features.qrProvider).toBe('none');
    const bakai = await serviceWith({ QR_PROVIDER: 'bakai' }, { 'qr.enabled': true }).read();
    expect(bakai.features).toMatchObject({ qrProvider: 'bakai', qrWebhook: true });
  });

  it('пустая app_settings → значения по умолчанию 08 §4.18.6; ответ проходит схему контракта', async () => {
    const body = await serviceWith({}).read();
    expect(body).toMatchObject({
      deliverySlots: [],
      supportContacts: [],
      privacyContact: null,
      lowStockThreshold: 5,
      minAppVersion: 'android=1.2.0,windows=1.2.0',
      recommendedAppVersion: null,
      customerStockDisplay: 'status',
    });
    expect(validateAgainst('PublicSettings', body)).toEqual([]);
  });

  it('неверные значения ключей заменяются значениями по умолчанию (не 500)', async () => {
    const body = await serviceWith(
      {},
      {
        low_stock_threshold: -3,
        customer_stock_display: 'everything',
        delivery_slots: 'not-an-array',
        support_contacts: [{ kind: 'phone' }, null],
        returns_enabled: 'yes',
        privacy_contact: '   ',
        min_app_version: 'android=1.5.0',
      },
    ).read();
    expect(body).toMatchObject({
      lowStockThreshold: 5,
      customerStockDisplay: 'status',
      deliverySlots: [],
      supportContacts: [],
      privacyContact: null,
      minAppVersion: 'android=1.5.0',
      features: { returnsFromPos: true },
    });
  });

  it('If-None-Match: точное, слабое, список и *', () => {
    expect(etagMatches('W/"abc"', 'W/"abc"')).toBe(true);
    expect(etagMatches('"abc"', 'W/"abc"')).toBe(true);
    expect(etagMatches('"x", W/"abc"', 'W/"abc"')).toBe(true);
    expect(etagMatches('*', 'W/"abc"')).toBe(true);
    expect(etagMatches('W/"abd"', 'W/"abc"')).toBe(false);
    expect(etagMatches(undefined, 'W/"abc"')).toBe(false);
  });

  it('самопроверка валидатора схем: лишнее поле, неверный enum и пропуск обязательного — ошибки', () => {
    expect(validateAgainst('PublicSettings', { extra: 1 })).not.toEqual([]);
    expect(
      validateAgainst('RegistrationCustomerMatch', { status: 'weird', linkId: null, customer: null, nextStep: 'none' }),
    ).not.toEqual([]);
    expect(
      validateAgainst('RegistrationCustomerMatch', { status: 'none', customer: null, nextStep: 'none' }),
    ).not.toEqual([]);
  });
});

/**
 * Скрипт сверки (RM-D-015 критерий 3): таблица соответствия 08 §4.18.6 ↔ public-settings.map.ts ↔ ответ.
 * Каждый ключ ответа — camelCase-проекция ключа app_settings (или env-флаг) по таблице 08; 0 расхождений.
 */
describe('RM-D-015 сверка с таблицей 08 §4.18.6 (колонка «Публичный»)', () => {
  interface Row {
    readonly key: string;
    readonly apiField: string;
    readonly publicCell: string;
  }

  const spec = readFileSync(
    fileURLToPath(new URL('../../../docs/specification/08_API_SPECIFICATION.md', import.meta.url)),
    'utf8',
  );
  const start = spec.indexOf('**Таблица соответствия ключей `app_settings`');
  const after = spec.slice(start).split(/\r?\n/).slice(1);
  const first = after.findIndex((l) => l.startsWith('|'));
  const tableLines: string[] = [];
  for (const l of after.slice(first)) {
    if (!l.startsWith('|')) break;
    tableLines.push(l);
  }
  const rows: Row[] = tableLines
    .slice(2)
    .map((l) => l.split(/(?<!\\)\|/).map((c) => c.trim()))
    .map((cells) => ({ keyCell: cells[1] ?? '', apiCell: cells[2] ?? '', publicCell: cells[5] ?? '' }))
    .map((c) => ({
      key:
        /^`([^`]+)`/.exec(c.keyCell)?.[1] ??
        (/env `([A-Z_]+)`/.exec(c.keyCell)?.[1] ? `env:${/env `([A-Z_]+)`/.exec(c.keyCell)![1]}` : ''),
      apiField: /`([^`]+)`/.exec(c.apiCell)?.[1] ?? '',
      publicCell: c.publicCell,
    }));
  const publicRows = rows.filter((r) => r.publicCell.startsWith('да'));
  /** Поля ответа из ячейки «Публичный»: все `features.*`, иначе — первое имя в скобках (`lowStockThreshold`). */
  const publicFieldsOf = (cell: string) => {
    const tokens = [...cell.matchAll(/`([a-zA-Z.]+)`/g)].map((m) => m[1]);
    const features = tokens.filter((x) => x.startsWith('features.'));
    return features.length > 0 ? features : tokens.slice(0, 1);
  };

  it('таблица 08 найдена и разобрана (≥ 20 строк, ≥ 10 публичных)', () => {
    expect(rows.length).toBeGreaterThanOrEqual(20);
    expect(publicRows.length).toBeGreaterThanOrEqual(10);
  });

  it('ключи app_settings: «Поле API» = camelCase-проекция ключа; публичные поля совпадают с map (0 расхождений)', () => {
    const discrepancies: string[] = [];
    for (const r of rows.filter((x) => !x.key.startsWith('env:') && x.key !== '')) {
      if (r.key.includes('<entity>')) {
        if (camelProjection(r.key) !== r.apiField)
          discrepancies.push(`${r.key}: проекция ${camelProjection(r.key)} ≠ ${r.apiField}`);
        continue;
      }
      if (camelProjection(r.key) !== r.apiField)
        discrepancies.push(`${r.key}: проекция ${camelProjection(r.key)} ≠ ${r.apiField}`);
    }
    const specPublic = publicRows.filter((r) => !r.key.startsWith('env:'));
    for (const r of specPublic) {
      const mapped = PUBLIC_APP_SETTING_KEYS.find((m) => m.key === r.key);
      if (!mapped) {
        discrepancies.push(`${r.key}: публичный в 08, нет в map`);
        continue;
      }
      if (mapped.apiField !== r.apiField) discrepancies.push(`${r.key}: apiField ${mapped.apiField} ≠ ${r.apiField}`);
      const fields = publicFieldsOf(r.publicCell);
      if (JSON.stringify([...mapped.publicFields].sort()) !== JSON.stringify([...fields].sort())) {
        discrepancies.push(`${r.key}: публичные поля ${mapped.publicFields.join(',')} ≠ ${fields.join(',')}`);
      }
    }
    for (const m of PUBLIC_APP_SETTING_KEYS) {
      if (!specPublic.some((r) => r.key === m.key)) discrepancies.push(`${m.key}: в map, но не публичный в 08`);
    }
    expect(discrepancies).toEqual([]);
  });

  it('env-флаги: CUSTOMER_SELF_SERVICE, DEBT_PAYMENTS_FROM_POS, QR_PROVIDER — публичные только в features (0 расхождений)', () => {
    const discrepancies: string[] = [];
    const specEnv = publicRows.filter((r) => r.key.startsWith('env:'));
    for (const r of specEnv) {
      const env = r.key.slice(4);
      const mapped = PUBLIC_ENV_SETTINGS.find((m) => m.env === env);
      if (!mapped) {
        discrepancies.push(`${env}: публичный в 08, нет в map`);
        continue;
      }
      if (mapped.apiField !== r.apiField) discrepancies.push(`${env}: ${mapped.apiField} ≠ ${r.apiField}`);
      const fields = publicFieldsOf(r.publicCell);
      if (JSON.stringify([...mapped.publicFields]) !== JSON.stringify(fields)) {
        discrepancies.push(`${env}: ${mapped.publicFields.join(',')} ≠ ${fields.join(',')}`);
      }
    }
    expect(specEnv.map((r) => r.key.slice(4)).sort()).toEqual(PUBLIC_ENV_SETTINGS.map((m) => m.env).sort());
    expect(discrepancies).toEqual([]);
  });

  it('каждое поле ответа объяснено таблицей: верхний уровень и features ⊆ publicFields (map) — 0 «лишних» ключей', () => {
    const covered = new Set([
      ...PUBLIC_APP_SETTING_KEYS.flatMap((m) => m.publicFields),
      ...PUBLIC_ENV_SETTINGS.flatMap((m) => m.publicFields),
    ]);
    const response = [
      ...PUBLIC_SETTINGS_TOP_LEVEL.filter((k) => k !== 'features'),
      ...PUBLIC_SETTINGS_FEATURES.map((f) => `features.${f}`),
    ];
    expect(response.filter((f) => !covered.has(f))).toEqual([]);
    expect([...covered].filter((f) => !response.includes(f))).toEqual([]);
    // Интервалы синхронизации — только форма sync_interval.<entity>, не публичны.
    expect(PUBLIC_APP_SETTING_KEYS.some((m) => m.key.startsWith('sync'))).toBe(false);
    expect(rows.filter((r) => r.key.startsWith('sync')).map((r) => r.key)).toEqual(['sync_interval.<entity>']);
  });
});
