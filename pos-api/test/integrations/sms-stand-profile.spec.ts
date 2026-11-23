import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse as parseYaml } from 'yaml';
import { ConfigError, loadAppConfig } from '../../src/common/config/app-config.js';
import { DEMO_OTP_TEST_CODE } from '../../src/common/config/env.schema.js';

/**
 * ADR-124 (SMS только через наш сервер; на стенде — без трат) и ADR-125 (тестовый стенд на Windows-комплекте):
 * - профиль стенда `infra/env/stand.env.example` поверх `prod.env.example` и `test.env.example` (как собирает
 *   `infra/windows/scripts/install.ps1 -Stand`) — валидная конфигурация pos-api;
 * - AC-ADR-124 (3): при `SMS_PROVIDER=smspro` тестовый код (в т. ч. 246810) не принимается — отказ в старте;
 * - код демо 246810 при `APP_ENV=staging` — отказ в старте;
 * - AC-ADR-124 (1): в docker compose секрет OTP подключён к api и worker из одного файла (Windows-комплект —
 *   `infra/windows/tests/scripts.tests.ps1`, раздел 7a).
 * 12: T-DEPLOY-029 (профиль стенда и секрет OTP у api и worker), T-SMS-021 (тестовый код при smspro — отказ в старте).
 */
const REPO = fileURLToPath(new URL('../../../', import.meta.url));

/** Разбор шаблона `.env` так же, как `Read-OpsEnvTemplate` Windows-комплекта (комментарий — после « #»). */
function readEnvTemplate(rel: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const raw of readFileSync(join(REPO, rel), 'utf8').split(/\r?\n/)) {
    if (/^\s*#/.test(raw)) continue;
    const m = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(raw);
    if (!m) continue;
    let v = m[2].trimStart();
    if (v.startsWith('"') || v.startsWith("'")) {
      const q = v[0];
      v = v.slice(1);
      const i = v.indexOf(q);
      if (i >= 0) v = v.slice(0, i);
    } else {
      const i = v.indexOf(' #');
      if (i >= 0) v = v.slice(0, i);
      v = v.trimEnd();
    }
    out[m[1]] = v;
  }
  return out;
}

/** Имена уровня compose/копий (Get-OpsEnvTemplatePairs их убирает; pos-api их не читает). */
const COMPOSE_LEVEL = [
  'API_TAG',
  'BACKUP_TAG',
  'POSTGRES_USER',
  'POSTGRES_DB',
  'BACKUP_KEEP_DAYS',
  'BACKUP_REMOTE',
  'BACKUP_SCHEDULE',
  'BACKUP_AGE_RECIPIENT',
  'BACKUP_PITR',
  'CADDY_SITE_ADDRESS',
  'CADDY_TLS',
  'CADDY_TEST_SITE_ADDRESS',
  'PG_SHARED_BUFFERS',
  'PG_MEM_LIMIT',
  'API_MEM_LIMIT',
  'WORKER_MEM_LIMIT',
];

const SECRETS_DIR = mkdtempSync(join(tmpdir(), 'pos-api-stand-profile-'));
const DATABASE_URL_FILE = join(SECRETS_DIR, 'database_url');
writeFileSync(DATABASE_URL_FILE, 'postgres://u:p@127.0.0.1:1/none\n'); // check-secrets: allow — фиктивная строка теста
afterAll(() => rmSync(SECRETS_DIR, { recursive: true, force: true }));

/** Настройки стенда, как их пишет install.ps1 -Stand в config\api.env (без секретов; код — шесть случайных цифр). */
function standEnv(): Record<string, string> {
  const merged: Record<string, string> = {
    ...readEnvTemplate('infra/env/prod.env.example'),
    ...readEnvTemplate('infra/env/test.env.example'),
    ...readEnvTemplate('infra/env/stand.env.example'),
  };
  for (const k of COMPOSE_LEVEL) delete merged[k];
  for (const k of Object.keys(merged)) if (merged[k] === '') delete merged[k];
  return {
    ...merged,
    MIN_APP_VERSION: 'android=1.2.0,windows=1.2.0',
    JWT_KEY_ID: 'test-20261124',
    AUTH_OTP_TEST_CODE: '135790',
    DATABASE_URL_FILE,
  };
}

function problemsOf(env: Record<string, string>): string {
  try {
    loadAppConfig(env);
  } catch (e) {
    expect(e).toBeInstanceOf(ConfigError);
    return (e as ConfigError).problems.join('\n');
  }
  throw new Error('ожидалась ConfigError');
}

describe('ADR-125: профиль тестового стенда (infra/env/stand.env.example)', () => {
  it('prod → test → stand: конфигурация стенда валидна (staging, фикстуры 1С, песочница банка, SMS без трат)', () => {
    const c = loadAppConfig(standEnv());
    expect(c.APP_ENV).toBe('staging');
    expect(c.PUBLIC_BASE_URL).toBe('https://api-test.37.114.51.144.sslip.io');
    expect(c.ONEC_MODE).toBe('fixtures');
    expect(c.QR_PROVIDER).toBe('bank');
    expect(c.BANK_QR_ADAPTER).toBe('sandbox');
    expect(c.SMS_PROVIDER).toBe('fake');
    expect(c.SMSPRO_LOGIN).toBeUndefined();
    expect(c.SMSPRO_PASSWORD).toBeUndefined();
    expect(c.AUTH_OTP_TEST_MODE).toBe(true);
    const phones = (c.AUTH_OTP_TEST_PHONES ?? '').split(',').map((p) => p.trim());
    expect(phones.length).toBeGreaterThan(0);
    for (const p of phones) expect(p).toMatch(/^\+99670000000\d$/); // вымышленные номера (ADR-119)
  });

  it('в шаблоне стенда нет секретов и кода: указателей *_FILE и AUTH_OTP_TEST_CODE нет', () => {
    const t = readEnvTemplate('infra/env/stand.env.example');
    expect(Object.keys(t).filter((k) => k.endsWith('_FILE'))).toEqual([]);
    expect(t.AUTH_OTP_TEST_CODE ?? '').toBe('');
  });
});

describe('ADR-124: тестовый код OTP — только dev, демо и стенд с fake', () => {
  it('AC-ADR-124 (3): SMS_PROVIDER=smspro + тестовый режим или код → отказ в старте (staging и dev)', () => {
    for (const APP_ENV of ['staging', 'dev']) {
      const text = problemsOf({ ...standEnv(), APP_ENV, SMS_PROVIDER: 'smspro', SMSPRO_SENDER: 'Optomstroy' });
      expect(text).toContain('AUTH_OTP_TEST_MODE');
      expect(text).toContain('AUTH_OTP_TEST_CODE');
      expect(text).toContain('SMS_PROVIDER=smspro');
      expect(text).not.toContain('135790'); // значения в сообщения не попадают
    }
    const onlyCode = problemsOf({
      ...standEnv(),
      SMS_PROVIDER: 'smspro',
      SMSPRO_SENDER: 'Optomstroy',
      AUTH_OTP_TEST_MODE: 'false',
      AUTH_OTP_TEST_CODE: DEMO_OTP_TEST_CODE,
    });
    expect(onlyCode).toContain('AUTH_OTP_TEST_CODE');
  });

  it('код демо 246810 при APP_ENV=staging — отказ в старте; при dev — допустим (демо, ADR-109)', () => {
    expect(problemsOf({ ...standEnv(), AUTH_OTP_TEST_CODE: DEMO_OTP_TEST_CODE })).toMatch(
      /AUTH_OTP_TEST_CODE: код демо/,
    );
    const dev = loadAppConfig({ ...standEnv(), APP_ENV: 'dev', AUTH_OTP_TEST_CODE: DEMO_OTP_TEST_CODE });
    expect(dev.AUTH_OTP_TEST_CODE).toBe(DEMO_OTP_TEST_CODE);
  });

  it('стенд с настоящим шлюзом (после секретов SMSPro и «да» пользователя): без тестового кода, с allowlist — валиден', () => {
    const c = loadAppConfig({
      ...standEnv(),
      SMS_PROVIDER: 'smspro',
      SMSPRO_SENDER: 'Optomstroy',
      SMSPRO_TEST_FLAG: 'false',
      AUTH_OTP_TEST_MODE: 'false',
      AUTH_OTP_TEST_CODE: '',
      AUTH_OTP_TEST_PHONES: '',
      SMS_STAGING_ALLOWED_PHONES: '+996700000001',
    });
    expect(c.SMS_PROVIDER).toBe('smspro');
    expect(c.AUTH_OTP_TEST_MODE).toBe(false);
    expect(c.AUTH_OTP_TEST_CODE).toBeUndefined();
    expect(c.SMS_STAGING_ALLOWED_PHONES).toBe('+996700000001');
  });
});

describe('AC-ADR-124 (1): docker compose — секрет OTP у api и worker из одного файла', () => {
  it('compose.prod.yml: api и worker — OTP_HMAC_SECRET_FILE=/run/secrets/otp_pepper и секрет otp_pepper', () => {
    const doc = parseYaml(readFileSync(join(REPO, 'infra/compose.prod.yml'), 'utf8'), { merge: true }) as {
      services: Record<string, { environment?: Record<string, string>; secrets?: string[] }>;
      secrets: Record<string, unknown>; // check-secrets: allow — тип раздела secrets compose, не значение
    };
    for (const svc of ['api', 'worker']) {
      const s = doc.services[svc];
      expect(s.environment?.OTP_HMAC_SECRET_FILE).toBe('/run/secrets/otp_pepper');
      expect(s.secrets).toContain('otp_pepper');
    }
    expect(doc.secrets.otp_pepper).toBeDefined();
  });
});
