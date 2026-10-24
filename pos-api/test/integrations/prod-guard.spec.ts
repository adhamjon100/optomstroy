import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ConfigError, loadAppConfig } from '../../src/common/config/app-config.js';
import { createOnecGateway } from '../../src/integrations/onec/onec-gateway.factory.js';
import { FakeSmsGateway } from '../../src/integrations/sms/fake-sms.gateway.js';
import { createSmsGateway } from '../../src/integrations/sms/sms-gateway.factory.js';
import { SmsProXmlGateway } from '../../src/integrations/sms/smspro-xml.gateway.js';

const POS_API_DIR = fileURLToPath(new URL('../../', import.meta.url));

/** Секрет-файл строки подключения: вне dev секреты задаются только через *_FILE (16 §4.3 п. 3; ревью C-MJ-01). */
const SECRETS_DIR = mkdtempSync(join(tmpdir(), 'pos-api-prod-guard-'));
const DATABASE_URL_FILE = join(SECRETS_DIR, 'database_url');
writeFileSync(DATABASE_URL_FILE, 'postgres://u:p@127.0.0.1:1/none\n'); // check-secrets: allow — фиктивная строка теста
afterAll(() => rmSync(SECRETS_DIR, { recursive: true, force: true }));

/** Корректная prod-конфигурация (без секретов; только то, что нужно схеме env). */
const PROD_OK = {
  APP_ENV: 'prod',
  PUBLIC_BASE_URL: 'https://api.optomstroy.kg',
  MIN_APP_VERSION: 'android=1.2.0,windows=1.2.0',
  DATABASE_URL_FILE,
  ONEC_MODE: 'extension',
  SMS_PROVIDER: 'smspro',
};

function problemsOf(env: Record<string, string>): string {
  try {
    loadAppConfig(env);
  } catch (e) {
    expect(e).toBeInstanceOf(ConfigError);
    return (e as ConfigError).problems.join('\n');
  }
  throw new Error('ожидалась ConfigError');
}

describe('APP_ENV=prod отвергает тестовые режимы (RM-C-008 п. 2; 16 §4.3, OPS-027, 09 §5.8)', () => {
  it('базовая prod-конфигурация валидна', () => {
    expect(loadAppConfig(PROD_OK).APP_ENV).toBe('prod');
  });

  it.each([
    ['ONEC_MODE', 'fixtures'],
    ['SMS_PROVIDER', 'fake'],
    ['AUTH_OTP_TEST_MODE', 'true'],
    ['AUTH_OTP_TEST_PHONES', '+996700000001'],
  ])('каждое нарушение по отдельности: %s=%s → ConfigError с именем переменной', (name, value) => {
    const text = problemsOf({ ...PROD_OK, [name]: value });
    expect(text).toContain(name);
    expect(text).toContain('APP_ENV=prod');
    expect(text.split('\n')).toHaveLength(1);
  });

  it('пустой AUTH_OTP_TEST_PHONES при prod допустим («не задано»); dev/staging принимают все тестовые режимы', () => {
    expect(loadAppConfig({ ...PROD_OK, AUTH_OTP_TEST_PHONES: '' }).AUTH_OTP_TEST_PHONES).toBeUndefined();
    for (const appEnv of ['dev', 'staging']) {
      const c = loadAppConfig({
        ...PROD_OK,
        APP_ENV: appEnv,
        ONEC_MODE: 'fixtures',
        SMS_PROVIDER: 'fake',
        AUTH_OTP_TEST_MODE: 'true',
        AUTH_OTP_TEST_PHONES: '+996700000001',
      });
      expect(c.ONEC_MODE).toBe('fixtures');
      expect(c.SMS_PROVIDER).toBe('fake');
    }
  });

  it('T-SEC-007: второй рубеж: фабрики и FakeSmsGateway отвергают prod, даже если конфигурация собрана в обход схемы', () => {
    const db = { query: () => Promise.reject(new Error('не должно вызываться')) };
    expect(() => new FakeSmsGateway(db, { appEnv: 'prod' })).toThrow(ConfigError);
    const smsCfg = loadAppConfig({ ...PROD_OK, SMSPRO_SENDER: 'Optomstroy' });
    expect(() => createSmsGateway({ ...smsCfg, SMS_PROVIDER: 'fake' }, { db })).toThrow(
      /fake запрещён при APP_ENV=prod/,
    );
    expect(() => createSmsGateway({ ...smsCfg, SMS_PROVIDER: undefined })).toThrow(/SMS_PROVIDER: обязателен/);
    expect(() => createOnecGateway({ ...smsCfg, ONEC_MODE: 'fixtures' })).toThrow(/fixtures запрещён/);
  });

  it('SmsProXmlGateway: требует учётные данные и https; запросы — только через транспорт (сети в тесте нет)', async () => {
    const cfg = loadAppConfig({ ...PROD_OK, SMSPRO_SENDER: 'Optomstroy' });
    expect(() => new SmsProXmlGateway(cfg)).toThrow(/SMSPRO_LOGIN_FILE/);
    expect(
      () =>
        new SmsProXmlGateway({
          ...cfg,
          SMSPRO_LOGIN: 'test-login',
          SMSPRO_PASSWORD: ['x', 'y'].join('-'),
          SMSPRO_BASE_URL: 'http://smspro.invalid/api',
        }),
    ).toThrow(/https/);
    const fetchSpy = vi.spyOn(globalThis, 'fetch');
    const calls: string[] = [];
    // Локальный транспорт (D_spec_questions SMS-Q-14): ответ «тестовое сообщение принято» (status=11), без сети.
    const transport = {
      post: (url: string, body: string) => {
        calls.push(`${new URL(url).pathname} ${body.length > 0 ? 'xml' : 'empty'}`);
        return Promise.resolve({
          status: 200,
          body: '<?xml version="1.0" encoding="UTF-8"?><response xmlns="http://Giper.mobi/schema/Message"><id>AbCdEf123456</id><status>11</status><phones>1</phones><smscnt>1</smscnt></response>',
        });
      },
    };
    try {
      const gw = new SmsProXmlGateway(
        { ...cfg, SMSPRO_LOGIN: 'test-login', SMSPRO_PASSWORD: ['x', 'y'].join('-') },
        { transport },
      );
      expect(gw.hasCredentials).toBe(true);
      const sent = await gw.send({
        transactionId: 'AbCdEf123456',
        sender: 'Optomstroy',
        text: 't',
        phone: '996700123456',
        test: true,
      });
      expect(sent.outcome).toBe('ACCEPTED_TEST');
      expect(calls).toEqual(['/api/message xml']);
      expect(fetchSpy).not.toHaveBeenCalled();
      expect(JSON.stringify(gw)).not.toContain('test-login');
    } finally {
      fetchSpy.mockRestore();
    }
  });

  it('pos-api не стартует: APP_ENV=prod + ONEC_MODE=fixtures + SMS_PROVIDER=fake → код 1 и понятная ошибка', () => {
    const res = spawnSync(process.execPath, ['--import', 'tsx', 'src/main.ts'], {
      cwd: POS_API_DIR,
      env: {
        PATH: process.env.PATH,
        SystemRoot: process.env.SystemRoot,
        ...PROD_OK,
        ONEC_MODE: 'fixtures',
        SMS_PROVIDER: 'fake',
        AUTH_OTP_TEST_MODE: 'true',
        AUTH_OTP_TEST_PHONES: '+996700000001',
      },
      encoding: 'utf8',
      timeout: 90_000,
    });
    expect(res.status).toBe(1);
    expect(res.stderr).toContain('Конфигурация окружения невалидна — сервис не запущен');
    for (const name of ['ONEC_MODE', 'SMS_PROVIDER', 'AUTH_OTP_TEST_MODE', 'AUTH_OTP_TEST_PHONES']) {
      expect(res.stderr).toContain(name);
    }
    expect(res.stderr).not.toContain('+996700000001'); // значения в вывод не попадают
  });
});
