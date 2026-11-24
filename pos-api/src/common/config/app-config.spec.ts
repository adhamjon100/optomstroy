import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ConfigError, loadAppConfig } from './app-config.js';
import { resolveEnvWithFiles } from './env-file.loader.js';
import { ENV_KEYS, SECRET_ENV_KEYS } from './env.schema.js';

const BASE = {
  MIN_APP_VERSION: 'android=1.2.0,windows=1.2.0',
  DATABASE_URL: 'postgres://env:env@127.0.0.1:5432/env',
};

function expectConfigError(fn: () => unknown): ConfigError {
  try {
    fn();
  } catch (e) {
    expect(e).toBeInstanceOf(ConfigError);
    return e as ConfigError;
  }
  throw new Error('ожидалась ConfigError');
}

describe('загрузчик env (*_FILE, zod) — RM-C-009', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'pos-api-env-'));
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it('X_FILE имеет приоритет над X; завершающий перевод строки файла отбрасывается', () => {
    const file = join(dir, 'database_url');
    writeFileSync(file, 'postgres://file:file@db:5432/pos\n');
    const config = loadAppConfig({ ...BASE, DATABASE_URL_FILE: file });
    expect(config.DATABASE_URL).toBe('postgres://file:file@db:5432/pos');
  });

  it('без X_FILE используется X; пустая строка = «не задано»', () => {
    expect(loadAppConfig({ ...BASE, DATABASE_URL_FILE: '' }).DATABASE_URL).toBe(BASE.DATABASE_URL);
  });

  it('значения по умолчанию — из 16 §4.3', () => {
    const c = loadAppConfig(BASE);
    expect(c.APP_ENV).toBe('dev');
    expect(c.LOG_LEVEL).toBe('info');
    expect(c.APP_READ_ONLY).toBe(false);
    expect(c.CUSTOMER_SELF_SERVICE).toBe(true);
    expect(c.RECEIVABLES_MAX_AGE_MIN).toBe(60);
    expect(c.QR_PROVIDER).toBe('onec');
    expect(c.OUTBOX_MAX_ATTEMPTS).toBe(20);
    expect(c.SYNC_STOCK_CRON).toBe('*/10 * * * *');
    expect(c.SMS_OTP_TEMPLATE).toBe('Kod: {code}. Optomstroy');
  });

  it('API_HOST / API_PORT / POS_SHUTDOWN_ON_STDIN_EOF: по умолчанию 0.0.0.0:3000 и выключено (Docker-комплект без изменений)', () => {
    const c = loadAppConfig(BASE);
    expect([c.API_HOST, c.API_PORT, c.POS_SHUTDOWN_ON_STDIN_EOF]).toEqual(['0.0.0.0', 3000, false]);
    // Пустые строки — «не задано» (как в .env с пустым значением).
    const e = loadAppConfig({ ...BASE, API_HOST: '', API_PORT: ' ', POS_SHUTDOWN_ON_STDIN_EOF: '' });
    expect([e.API_HOST, e.API_PORT, e.POS_SHUTDOWN_ON_STDIN_EOF]).toEqual(['0.0.0.0', 3000, false]);
  });

  it('Windows: API_HOST=127.0.0.1, API_PORT в пределах 1…65535, POS_SHUTDOWN_ON_STDIN_EOF=1|true', () => {
    const c = loadAppConfig({ ...BASE, API_HOST: '127.0.0.1', API_PORT: '3301', POS_SHUTDOWN_ON_STDIN_EOF: '1' });
    expect([c.API_HOST, c.API_PORT, c.POS_SHUTDOWN_ON_STDIN_EOF]).toEqual(['127.0.0.1', 3301, true]);
    expect(loadAppConfig({ ...BASE, API_HOST: '::1', API_PORT: '65535' }).API_PORT).toBe(65535);
    expect(loadAppConfig({ ...BASE, API_PORT: '1', POS_SHUTDOWN_ON_STDIN_EOF: 'true' }).POS_SHUTDOWN_ON_STDIN_EOF).toBe(
      true,
    );
    expect(loadAppConfig({ ...BASE, POS_SHUTDOWN_ON_STDIN_EOF: 'false' }).POS_SHUTDOWN_ON_STDIN_EOF).toBe(false);
  });

  it('API_HOST не IP-литерал, API_PORT вне 1…65535 или не целое, POS_SHUTDOWN_ON_STDIN_EOF не булево → отказ в старте', () => {
    for (const [key, value] of [
      ['API_HOST', 'localhost'],
      ['API_HOST', '127.0.0.256'],
      ['API_PORT', '0'],
      ['API_PORT', '65536'],
      ['API_PORT', '3000.5'],
      ['API_PORT', 'http'],
      ['POS_SHUTDOWN_ON_STDIN_EOF', 'maybe'],
    ] as const) {
      const err = expectConfigError(() => loadAppConfig({ ...BASE, [key]: value }));
      expect(err.problems.join('\n'), `${key}=${value}`).toContain(key);
    }
  });

  it('T-BIO-023 (6), DEPLOY-055: вход по лицу — по умолчанию off/24/off; AUTH_BIO_WEAK_REAUTH_HOURS вне 1…24 → отказ в старте', () => {
    const c = loadAppConfig(BASE);
    expect([c.AUTH_BIO_ALLOW_WEAK, c.AUTH_BIO_WEAK_REAUTH_HOURS, c.AUTH_WINDOWS_HELLO_KEY]).toEqual(['off', 24, 'off']);
    for (const hours of ['48', '25', '0', '-1']) {
      const err = expectConfigError(() => loadAppConfig({ ...BASE, AUTH_BIO_WEAK_REAUTH_HOURS: hours }));
      expect(err.problems.join('\n')).toContain('AUTH_BIO_WEAK_REAUTH_HOURS');
    }
    const ok = loadAppConfig({
      ...BASE,
      AUTH_BIO_ALLOW_WEAK: 'customer',
      AUTH_BIO_WEAK_REAUTH_HOURS: '1',
      AUTH_WINDOWS_HELLO_KEY: 'personal',
    });
    expect([ok.AUTH_BIO_ALLOW_WEAK, ok.AUTH_BIO_WEAK_REAUTH_HOURS, ok.AUTH_WINDOWS_HELLO_KEY]).toEqual([
      'customer',
      1,
      'personal',
    ]);
    expect(loadAppConfig({ ...BASE, AUTH_BIO_ALLOW_WEAK: 'all' }).AUTH_BIO_ALLOW_WEAK).toBe('all');
    const bad = expectConfigError(() =>
      loadAppConfig({ ...BASE, AUTH_BIO_ALLOW_WEAK: 'staff', AUTH_WINDOWS_HELLO_KEY: 'on' }),
    ).problems.join('\n');
    expect(bad).toContain('AUTH_BIO_ALLOW_WEAK');
    expect(bad).toContain('AUTH_WINDOWS_HELLO_KEY');
  });

  it('T-SMS-017 (09 SMS-025): SMS_OTP_TEMPLATE без {code} → ошибка конфигурации; свой шаблон с {code} принимается', () => {
    const err = expectConfigError(() => loadAppConfig({ ...BASE, SMS_OTP_TEMPLATE: 'Ваш код готов' }));
    expect(err.message).toContain('SMS_OTP_TEMPLATE');
    expect(loadAppConfig({ ...BASE, SMS_OTP_TEMPLATE: '{code} — код Optomstroy' }).SMS_OTP_TEMPLATE).toBe(
      '{code} — код Optomstroy',
    );
  });

  it('нет обязательной переменной → понятная ошибка с именем переменной (без значений)', () => {
    const err = expectConfigError(() => loadAppConfig({ MIN_APP_VERSION: BASE.MIN_APP_VERSION }));
    expect(err.message).toContain('DATABASE_URL (или DATABASE_URL_FILE): обязательная переменная не задана');
    expect(err.message).toMatch(/^Конфигурация окружения невалидна/);
    const err2 = expectConfigError(() => loadAppConfig({ DATABASE_URL: BASE.DATABASE_URL }));
    expect(err2.problems.join('\n')).toContain('MIN_APP_VERSION');
  });

  it('нечитаемый *_FILE → ошибка с именем переменной, без пути и содержимого', () => {
    const err = expectConfigError(() => loadAppConfig({ ...BASE, DATABASE_URL_FILE: join(dir, 'missing') }));
    expect(err.message).toContain('DATABASE_URL_FILE: не удалось прочитать файл секрета (ENOENT)');
    expect(err.message).not.toContain(dir);
  });

  it('неверные значения: формат MIN_APP_VERSION, булево, enum', () => {
    const err = expectConfigError(() =>
      loadAppConfig({ ...BASE, MIN_APP_VERSION: 'android=1.2', APP_READ_ONLY: 'maybe', APP_ENV: 'production' }),
    );
    const text = err.problems.join('\n');
    expect(text).toContain('MIN_APP_VERSION');
    expect(text).toContain('APP_READ_ONLY');
    expect(text).toContain('APP_ENV');
    expect(text).not.toContain(BASE.DATABASE_URL);
  });

  it('APP_ENV=prod: тестовые режимы и fake запрещены (OPS-027), PUBLIC_BASE_URL обязателен', () => {
    const err = expectConfigError(() =>
      loadAppConfig({
        ...BASE,
        APP_ENV: 'prod',
        ONEC_MODE: 'fixtures',
        SMS_PROVIDER: 'fake',
        AUTH_OTP_TEST_MODE: 'true',
        AUTH_OTP_TEST_PHONES: '+996700000001',
        LOG_LEVEL: 'debug',
        CORS_ALLOWED_ORIGINS: '*',
      }),
    );
    const text = err.problems.join('\n');
    for (const name of [
      'PUBLIC_BASE_URL',
      'ONEC_MODE',
      'SMS_PROVIDER',
      'AUTH_OTP_TEST_MODE',
      'AUTH_OTP_TEST_PHONES',
      'LOG_LEVEL',
      'CORS_ALLOWED_ORIGINS',
    ]) {
      expect(text).toContain(name);
    }
    const dbFile = join(dir, 'database_url_prod');
    writeFileSync(dbFile, BASE.DATABASE_URL);
    const ok = loadAppConfig({
      MIN_APP_VERSION: BASE.MIN_APP_VERSION,
      DATABASE_URL_FILE: dbFile,
      APP_ENV: 'prod',
      PUBLIC_BASE_URL: 'https://api.optomstroy.kg',
      ONEC_MODE: 'extension',
      SMS_PROVIDER: 'smspro',
    });
    expect(ok.APP_ENV).toBe('prod');
  });

  it('C-MJ-01: вне dev секреты из SECRET_ENV_KEYS прямым значением → отказ в старте (16 §4.3 п. 3)', () => {
    for (const env of ['staging', 'prod'] as const) {
      const err = expectConfigError(() =>
        loadAppConfig({
          ...BASE,
          APP_ENV: env,
          PUBLIC_BASE_URL: 'https://api.optomstroy.kg',
          ONEC_MODE: 'extension',
          JWT_PRIVATE_KEY: 'direct-key-value', // check-secrets: allow — фиктивное значение теста C-MJ-01
          PIN_PEPPER: 'direct-pepper', // check-secrets: allow — фиктивное значение теста C-MJ-01
        }),
      );
      const text = err.problems.join('\n');
      for (const k of ['DATABASE_URL', 'JWT_PRIVATE_KEY', 'PIN_PEPPER']) expect(text).toContain(`${k}_FILE`);
      expect(text).not.toContain('direct-key-value');
      expect(text).not.toContain(BASE.DATABASE_URL);
    }
    // dev: прямое значение — допустимый fallback
    expect(loadAppConfig({ ...BASE, JWT_PRIVATE_KEY: 'k' }).JWT_PRIVATE_KEY).toBe('k');
    // staging: тот же секрет из файла принимается
    const keyFile = join(dir, 'jwt_private_key');
    const dbFile = join(dir, 'database_url_staging');
    writeFileSync(keyFile, 'from-file');
    writeFileSync(dbFile, BASE.DATABASE_URL);
    const c = loadAppConfig({
      MIN_APP_VERSION: BASE.MIN_APP_VERSION,
      APP_ENV: 'staging',
      PUBLIC_BASE_URL: 'https://staging.optomstroy.kg',
      DATABASE_URL_FILE: dbFile,
      JWT_PRIVATE_KEY_FILE: keyFile,
    });
    expect(c.JWT_PRIVATE_KEY).toBe('from-file');
  });

  it('C-MJ-02: ONEC_ODATA_WRITE_ENABLED=true только при odata_only и с обоими секретами pos_odata_write', () => {
    const text = expectConfigError(() =>
      loadAppConfig({ ...BASE, ONEC_MODE: 'extension', QR_PROVIDER: 'none', ONEC_ODATA_WRITE_ENABLED: 'true' }),
    ).problems.join('\n');
    expect(text).toContain('ONEC_ODATA_WRITE_ENABLED: true допустимо только при ONEC_MODE=odata_only');
    expect(text).toContain('ONEC_ODATA_WRITE_USER');
    expect(text).toContain('ONEC_ODATA_WRITE_PASSWORD');
    const missingPassword = expectConfigError(() =>
      loadAppConfig({
        ...BASE,
        ONEC_MODE: 'odata_only',
        QR_PROVIDER: 'none',
        ONEC_ODATA_WRITE_ENABLED: 'true',
        ONEC_ODATA_WRITE_USER: 'pos_odata_write',
      }),
    ).problems.join('\n');
    expect(missingPassword).toContain('ONEC_ODATA_WRITE_PASSWORD');
    expect(missingPassword).not.toContain('ONEC_ODATA_WRITE_USER:');
    const ok = loadAppConfig({
      ...BASE,
      ONEC_MODE: 'odata_only',
      QR_PROVIDER: 'none',
      ONEC_ODATA_WRITE_ENABLED: 'true',
      ONEC_ODATA_WRITE_USER: 'pos_odata_write',
      ONEC_ODATA_WRITE_PASSWORD: 'p',
    });
    expect(ok.ONEC_ODATA_WRITE_ENABLED).toBe(true);
  });

  it('C-MN-03: OPENAPI_PUBLIC=true и http-адрес SMSPro запрещены при APP_ENV=prod; на тестовом контуре допустимы', () => {
    const text = expectConfigError(() =>
      loadAppConfig({
        ...BASE,
        APP_ENV: 'prod',
        PUBLIC_BASE_URL: 'https://api.optomstroy.kg',
        ONEC_MODE: 'extension',
        OPENAPI_PUBLIC: 'true',
        SMSPRO_BASE_URL: 'http://smspro.nikita.kg/api',
      }),
    ).problems.join('\n');
    expect(text).toContain('OPENAPI_PUBLIC');
    expect(text).toContain('SMSPRO_BASE_URL');
    expect(loadAppConfig({ ...BASE, OPENAPI_PUBLIC: 'true' }).OPENAPI_PUBLIC).toBe(true);
  });

  it('межпеременные правила: вебхук QR только при bakai; C-2 требует allowlist IP', () => {
    const text = expectConfigError(() =>
      loadAppConfig({
        ...BASE,
        QR_WEBHOOK_ENABLED: 'true',
        ONEC_INBOUND_ENABLED: 'true',
        ONEC_MODE: 'extension',
        QR_PROVIDER: 'none',
      }),
    ).problems.join('\n');
    expect(text).toContain('QR_WEBHOOK_ENABLED');
    expect(text).toContain('QR_WEBHOOK_ALLOWED_IPS');
    expect(text).toContain('ONEC_INBOUND_ALLOWED_IPS');
  });

  it('вебхук QR: только открытый ключ без секрета → отказ в старте с пояснением про Q-382', () => {
    const text = expectConfigError(() =>
      loadAppConfig({
        ...BASE,
        QR_PROVIDER: 'bank',
        QR_WEBHOOK_ENABLED: 'true',
        QR_WEBHOOK_ALLOWED_IPS: '127.0.0.1',
        QR_WEBHOOK_PUBLIC_KEY: '-----BEGIN PUBLIC KEY-----\nTEST\n-----END PUBLIC KEY-----',
      }),
    ).problems.join('\n');
    expect(text).toContain('QR_WEBHOOK_SECRET');
    expect(text).toContain('QR_WEBHOOK_PUBLIC_KEY_FILE');
    expect(text).toContain('Q-382');
  });

  it('resolveEnvWithFiles: читает только известные ключи, отмечает источник «файл»', () => {
    const r = resolveEnvWithFiles(['A', 'B'], { A_FILE: '/x', A: 'direct', B: 'b', C: 'c' }, () => 'from-file\r\n');
    expect(r.values).toEqual({ A: 'from-file', B: 'b' });
    expect(r.fromFile).toEqual(['A']);
  });

  it('секретные ключи схемы задаются в 16 §4.3 как <ИМЯ>_FILE', () => {
    for (const k of SECRET_ENV_KEYS) expect(ENV_KEYS).toContain(k);
  });
});
