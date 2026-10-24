import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parse } from 'yaml';
import { OtpController } from '../../src/auth/otp/otp.controller.js';
import type { IssuedChallenge } from '../../src/auth/otp/otp.service.js';
import type { AuthHttpRequest } from '../../src/auth/common/request.js';
import { FixedClock } from '../../src/common/auth/clock.js';
import { loadAppConfig } from '../../src/common/config/app-config.js';

/**
 * D AU-03 (бэклог E_spec_sync.md §3): подсказка кода `devCode` в ответе `POST /auth/otp/request`.
 *
 * ТЗ: 09 §4.6 «`devCode` в R1 не возвращается» (ADR-096) — поля нет в OpenAPI `AuthOtpRequestResponse`; 09 §5.8 —
 * тестовый режим (`AUTH_OTP_TEST_MODE`) только при `APP_ENV ∈ {dev, staging}`, в `prod` сервер не стартует. Поэтому
 * проверяется инвариант для обоих режимов: тело ответа — ровно поля контракта, без `devCode` и без кода, что бы ни
 * вернул сервис выпуска; в `prod` тестовый режим включить нельзя. E2e того же для dev + тестового номера —
 * test/e2e/auth/otp.e2e-spec.ts (T-SEC-007).
 */
const CONTRACT = fileURLToPath(new URL('../../../contracts/openapi/pos-api.v1.yaml', import.meta.url));
const DEV = '6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b';
const TEST_PHONE = '+996700000001';
const TEST_CODE = '246810';

function contractOtpResponseKeys(): string[] {
  const doc = parse(readFileSync(CONTRACT, 'utf8')) as {
    components: { schemas: Record<string, { properties?: Record<string, unknown> }> };
  };
  return Object.keys(doc.components.schemas.AuthOtpRequestResponse?.properties ?? {}).sort();
}

/** Контроллер со стабами: `issue` «протекает» кодом — ответ всё равно собирается только из полей контракта. */
function controller(leak: Record<string, unknown>) {
  const issued: IssuedChallenge & Record<string, unknown> = {
    challengeId: '0192f3a1-6c3e-7a1b-9f00-000000000001',
    resendAfterSec: 60,
    otpTtlSec: 300,
    codeLength: 6,
    phoneMasked: '+996 7** *** *01',
    expiresAt: new Date('2026-10-22T08:05:00Z'),
    ...leak,
  };
  return new OtpController(
    new FixedClock(new Date('2026-10-22T08:00:00Z')),
    { issue: () => Promise.resolve(issued) } as never,
    {} as never,
    { findByPhone: () => Promise.resolve(undefined) } as never,
    {} as never,
    {} as never,
    {} as never,
    { publicIp: () => undefined } as never,
    { claim: () => Promise.resolve({ kind: 'none' }) } as never,
  );
}

const req = { headers: { 'x-device-id': DEV }, ip: '10.0.0.7', id: 'req-au03' } as unknown as AuthHttpRequest;
const BASE = { MIN_APP_VERSION: 'android=1.0.0', DATABASE_URL: 'postgres://x:y@127.0.0.1:1/none' };

describe('AU-03: devCode в ответе OTP не отдаётся ни в dev/staging (тестовый режим), ни в prod', () => {
  it('контракт: AuthOtpRequestResponse без devCode (09 §4.6, R1)', () => {
    const keys = contractOtpResponseKeys();
    expect(keys).toEqual(['challengeId', 'codeLength', 'deliveryHint', 'otpTtlSec', 'phoneMasked', 'resendAfterSec']);
    expect(keys).not.toContain('devCode');
  });

  it('dev + AUTH_OTP_TEST_MODE: конфигурация допустима, тело — ровно поля контракта, кода нет', async () => {
    const cfg = loadAppConfig({
      ...BASE,
      APP_ENV: 'dev',
      AUTH_OTP_TEST_MODE: 'true',
      AUTH_OTP_TEST_CODE: TEST_CODE,
      AUTH_OTP_TEST_PHONES: TEST_PHONE,
    });
    expect(cfg.AUTH_OTP_TEST_MODE).toBe(true);
    const body = await controller({ code: TEST_CODE, devCode: TEST_CODE }).request(req, { phone: TEST_PHONE } as never);
    expect(Object.keys(body).sort()).toEqual(contractOtpResponseKeys());
    expect(body).not.toHaveProperty('devCode');
    expect(JSON.stringify(body)).not.toContain(TEST_CODE);
  });

  it('prod: тестовый режим запрещён при старте (09 §5.8, OPS-027); тело ответа той же формы, без devCode', async () => {
    const prod = {
      ...BASE,
      APP_ENV: 'prod',
      PUBLIC_BASE_URL: 'https://pos.example.kg',
      SMS_PROVIDER: 'smspro',
      SMSPRO_BASE_URL: 'https://smspro.example.kg',
      ONEC_MODE: 'extension',
    };
    expect(() => loadAppConfig({ ...prod, AUTH_OTP_TEST_MODE: 'true' })).toThrow(/AUTH_OTP_TEST_MODE/);
    expect(() => loadAppConfig({ ...prod, AUTH_OTP_TEST_CODE: TEST_CODE })).toThrow(/AUTH_OTP_TEST_CODE/);
    expect(() => loadAppConfig({ ...prod, AUTH_OTP_TEST_PHONES: TEST_PHONE })).toThrow(/AUTH_OTP_TEST_PHONES/);
    const body = await controller({ devCode: '000000' }).request(req, { phone: '+996700123456' } as never);
    expect(Object.keys(body).sort()).toEqual(contractOtpResponseKeys());
    expect(body).not.toHaveProperty('devCode');
  });
});
