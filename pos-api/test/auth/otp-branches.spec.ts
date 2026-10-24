import { AuthPolicyService } from '../../src/auth/common/auth-policy.js';
import { AuthHttpRateLimiter } from '../../src/auth/common/http-rate-limits.js';
import type { OtpChallengeRow, OtpChallengesRepository } from '../../src/auth/otp/otp-challenges.repository.js';
import { OtpCircuitBreaker } from '../../src/auth/otp/otp-circuit-breaker.js';
import { type OtpProvider, SmsOtpProvider } from '../../src/auth/otp/otp.provider.js';
import { type IssueOtpInput, OtpService } from '../../src/auth/otp/otp.service.js';
import type { SmsOutboxRepository } from '../../src/auth/otp/sms-outbox.repository.js';
import type { PinCheck } from '../../src/auth/pin/pin-verifier.service.js';
import { StepUpService } from '../../src/auth/step-up/step-up.service.js';
import type { StepUpTokenVerifier } from '../../src/auth/step-up/step-up-token.verifier.js';
import type { AuditContext } from '../../src/common/audit/audit-context.js';
import type { AuthenticatedPrincipal } from '../../src/common/auth/principal.js';
import { FixedClock } from '../../src/common/auth/clock.js';
import { type AppConfig, loadAppConfig } from '../../src/common/config/app-config.js';
import { OtpHmacService } from '../../src/common/crypto/otp-hmac.service.js';
import { parseSecretRing } from '../../src/common/crypto/secret-ring.js';
import type {
  RateLimitDecision,
  RateLimitResult,
  RateLimitScope,
} from '../../src/common/rate-limit/rate-limit.service.js';
import type { SendResult, SmsGateway } from '../../src/integrations/sms/sms-gateway.js';

/**
 * RM-D-001 п. 1 («100 % веток политики»; ревью D-MN-06): unit-тесты ветвей политики, которые e2e-наборы не
 * достигают, — OtpService.issue (тестовый режим, `blocked()` провайдера, гонка peek/consume, лимиты без IP,
 * ошибки аудита), SmsOtpProvider (ретраи, исключения шлюза, CONFIG_ERROR/INSUFFICIENT_FUNDS, `<test>`-флаг),
 * StepUpService.request (валидация, PIN locked_now, OTP-шаги и итоги проверки).
 */
const BASE_ENV = { APP_ENV: 'dev', MIN_APP_VERSION: 'android=1.0.0', DATABASE_URL: 'postgres://x:y@127.0.0.1:1/none' };
const config = (extra: Record<string, string> = {}) => loadAppConfig({ ...BASE_ENV, ...extra });
const DEV = '6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b';
const PHONE = '+996700000001';
const AUDIT: AuditContext = { requestId: 'req-1' };

function row(patch: Partial<OtpChallengeRow>): OtpChallengeRow {
  const now = new Date('2026-10-22T08:00:00Z');
  return {
    id: '0192f3a1-6c3e-7a1b-9f00-000000000001',
    phoneE164: PHONE,
    userId: null,
    purpose: 'login_or_register',
    codeHmac: Buffer.alloc(32),
    salt: Buffer.alloc(16),
    pepperVersion: 1,
    expiresAt: new Date(now.getTime() + 300_000),
    attempts: 0,
    status: 'sent',
    verifiedAt: null,
    replayedAt: null,
    registrationTokenHash: null,
    registrationTokenExpiresAt: null,
    smsOutboxId: null,
    deviceKey: DEV,
    ip: null,
    requestId: null,
    createdAt: now,
    updatedAt: now,
    issuedByUserId: null,
    lockedAt: null,
    issuedJti: null,
    ...patch,
  };
}

/** Отказ `consume` по перечисленным областям (остальные правила набора — разрешены). */
function deniedBy(...denied: { scope: RateLimitScope; retryAfterSec: number }[]): RateLimitResult {
  const t = new Date('2026-10-22T08:00:00Z');
  const decisions: RateLimitDecision[] = [
    ...denied.map((d) => ({
      scope: d.scope,
      allowed: false,
      count: 5,
      limit: 5,
      remaining: 0,
      windowStart: t,
      windowEnd: t,
      retryAfterSec: d.retryAfterSec,
    })),
    {
      scope: 'otp_ip_24h',
      allowed: true,
      count: 1,
      limit: 100,
      remaining: 99,
      windowStart: t,
      windowEnd: t,
      retryAfterSec: 0,
    },
  ];
  return {
    allowed: false,
    decisions,
    retryAfterSec: Math.max(...denied.map((d) => d.retryAfterSec)),
    deniedScope: denied[0]?.scope,
  };
}

const allowed: RateLimitResult = { allowed: true, decisions: [], retryAfterSec: 0 };

describe('OtpService.issue — ветви политики (unit, D-MN-06)', () => {
  const clock = new FixedClock(new Date('2026-10-22T08:00:00Z'));
  const hmac = new OtpHmacService(parseSecretRing('OTP_HMAC_SECRET', 'x'.repeat(40), 1, 'prod'));

  function make(
    opts: {
      env?: Record<string, string>;
      recent?: OtpChallengeRow[];
      consume?: RateLimitResult;
      provider?: Partial<OtpProvider>;
      auditFails?: boolean;
    } = {},
  ) {
    const calls: string[] = [];
    const challenges = {
      lockPhone: () => Promise.resolve(),
      recentDelivered: () => Promise.resolve(opts.recent ?? []),
      retireActive: () => Promise.resolve(0),
      insert: (v: OtpChallengeRow) => {
        calls.push('insert');
        return Promise.resolve(v);
      },
      update: () => Promise.resolve(undefined),
    };
    const provider: OtpProvider = {
      prepare: () => Promise.resolve({ smsOutboxId: 'o1', transactionId: 't1' }),
      dispatch: () => calls.push('dispatch'),
      drain: () => Promise.resolve(),
      ...opts.provider,
    };
    const rateLimit = {
      consume: () => Promise.resolve(opts.consume ?? allowed),
    };
    const audit = {
      write: (_ctx: unknown, e: { action: string }) => {
        calls.push(e.action);
        return opts.auditFails && e.action === 'auth.otp.rate_limited'
          ? Promise.reject(new Error('audit down'))
          : Promise.resolve();
      },
    };
    const cfg = config(opts.env);
    const svc = new OtpService(
      { transaction: <T>(fn: (tx: unknown) => Promise<T>) => fn({}) } as never,
      clock,
      cfg,
      provider,
      new AuthPolicyService(cfg),
      challenges as unknown as OtpChallengesRepository,
      hmac,
      rateLimit as never,
      new OtpCircuitBreaker(clock),
      audit as never,
    );
    return { svc, calls };
  }

  const input = (patch: Partial<IssueOtpInput> = {}): IssueOtpInput => ({
    phoneE164: PHONE,
    purpose: 'login_or_register',
    deviceKey: DEV,
    ip: null,
    requestId: null,
    userId: null,
    audit: AUDIT,
    ...patch,
  });

  it('тестовый режим: без провайдера и без dispatch; allowlist пуст (AUTH_OTP_TEST_PHONES не задан) → обычный выпуск', async () => {
    const test = make({
      env: { AUTH_OTP_TEST_MODE: 'true', AUTH_OTP_TEST_CODE: '246810', AUTH_OTP_TEST_PHONES: PHONE },
    });
    await test.svc.issue(input({ requestId: 'r-1' }));
    expect(test.calls).not.toContain('dispatch');
    const noList = make({ env: { AUTH_OTP_TEST_MODE: 'true', AUTH_OTP_TEST_CODE: '246810' } });
    expect(noList.svc.isTestPhone(PHONE)).toBe(false);
    await noList.svc.issue(input());
    expect(noList.calls).toContain('dispatch');
  });

  it('тестовый режим на staging разрешён; на test/prod — нет (09 §5.8)', () => {
    const mk = (APP_ENV: string) =>
      new OtpService(
        {} as never,
        clock,
        { AUTH_OTP_TEST_MODE: true, AUTH_OTP_TEST_CODE: '246810', AUTH_OTP_TEST_PHONES: PHONE, APP_ENV } as AppConfig,
        {} as never,
        {} as never,
        {} as never,
        hmac,
        {} as never,
        {} as never,
        {} as never,
      );
    expect(mk('staging').isTestPhone(PHONE)).toBe(true);
    expect(mk('test').isTestPhone(PHONE)).toBe(false);
  });

  it('провайдер сообщает blocked() → 503 SMS_PROVIDER_ERROR до транзакции', async () => {
    const { svc, calls } = make({ provider: { blocked: () => Promise.resolve(true) } });
    await expect(svc.issue(input())).rejects.toMatchObject({ code: 'SMS_PROVIDER_ERROR' });
    expect(calls).toHaveLength(0);
    const open = make({ provider: { blocked: () => Promise.resolve(false) } });
    await expect(open.svc.issue(input())).resolves.toMatchObject({ codeLength: 6 });
  });

  it('DQ-01: отказ consume классифицируется по приоритету номер → IP/устройство → глобальный; квота не расходуется', async () => {
    // номер и устройство исчерпаны одновременно → OTP_RATE_LIMITED с Retry-After номера
    const phone = make({
      consume: deniedBy({ scope: 'otp_device_10m', retryAfterSec: 600 }, { scope: 'otp_phone_15m', retryAfterSec: 30 }),
    });
    const pe = await phone.svc.issue(input()).catch((e: unknown) => e);
    expect(pe).toMatchObject({ code: 'OTP_RATE_LIMITED' });
    expect((pe as { headers: Record<string, string> }).headers['Retry-After']).toBe('30');
    expect(phone.calls).not.toContain('insert');
    const ip = make({ consume: deniedBy({ scope: 'otp_ip_24h', retryAfterSec: 7200 }) });
    await expect(ip.svc.issue(input({ ip: '10.0.0.1' }))).rejects.toMatchObject({ code: 'RATE_LIMITED' });
    // глобальный лимит → нейтральный 503 и circuit-breaker
    const global = make({ consume: deniedBy({ scope: 'otp_global_1m', retryAfterSec: 20 }) });
    await expect(global.svc.issue(input())).rejects.toMatchObject({ code: 'SMS_PROVIDER_ERROR' });
    await expect(global.svc.issue(input())).rejects.toMatchObject({ code: 'SMS_PROVIDER_ERROR' });
    expect(global.calls.filter((c) => c === 'auth.otp.rate_limited')).toHaveLength(1);
  });

  it('лимит устройства без IP: правила IP не применяются; ошибка записи аудита отказа не меняет ответ', async () => {
    const { svc } = make({ consume: deniedBy({ scope: 'otp_device_10m', retryAfterSec: 600 }), auditFails: true });
    const err = await svc.issue(input({ requestId: 'r-2' })).catch((e: unknown) => e);
    expect(err).toMatchObject({ code: 'RATE_LIMITED' });
    expect((err as { headers: Record<string, string> }).headers['Retry-After']).toBe('600');
    const rules = svc.clientRules({ ip: null, deviceKey: DEV }, new AuthPolicyService(config()).base().otp);
    expect(rules.map((r) => r.scope)).toEqual(['otp_device_10m', 'otp_device_24h']);
    const withIp = svc.clientRules({ ip: '10.0.0.1', deviceKey: DEV }, new AuthPolicyService(config()).base().otp);
    expect(withIp.map((r) => [r.scope, r.limit])).toEqual([
      ['otp_ip_10m', 20],
      ['otp_ip_24h', 100],
      ['otp_device_10m', 5],
      ['otp_device_24h', 20],
    ]);
  });

  it('пауза номера не наступает, если не все последние коды заблокированы; cooldown истёк', async () => {
    const old = new Date(clock.now().getTime() - 120_000);
    const { svc } = make({
      recent: [row({ status: 'locked', createdAt: old }), row({ status: 'expired', createdAt: old })],
    });
    await expect(svc.issue(input())).resolves.toMatchObject({ resendAfterSec: 60 });
  });
});

describe('OtpService.check — оставшиеся ветви (unit, D-MN-06)', () => {
  const clock = new FixedClock(new Date('2026-10-22T08:00:00Z'));
  const hmac = new OtpHmacService(parseSecretRing('OTP_HMAC_SECRET', 'x'.repeat(40), 1, 'prod'));
  const cfg = config();

  it('update не вернул строку → ok с исходным челленджем; locked без истории — retryAfter от created_at челленджа', async () => {
    const id = '0192f3a1-6c3e-7a1b-9f00-000000000009';
    const code = '123456';
    const ch = row({ id, codeHmac: hmac.codeHmac(id, code) });
    const repo = {
      findById: () => Promise.resolve(ch),
      update: () => Promise.resolve(undefined),
      recentDelivered: () => Promise.resolve([]),
    };
    const svc = new OtpService(
      {} as never,
      clock,
      cfg,
      {} as never,
      new AuthPolicyService(cfg),
      repo as unknown as OtpChallengesRepository,
      hmac,
      {} as never,
      new OtpCircuitBreaker(clock),
      {} as never,
    );
    const args = { challengeId: id, code, deviceKey: DEV, purpose: 'login_or_register' as const, allowReplay: false };
    const ok = await svc.check({} as never, args);
    expect(ok).toMatchObject({ kind: 'ok', challenge: { id } });
    const lockedRepo = { ...repo, findById: () => Promise.resolve({ ...ch, status: 'locked' as const }) };
    const svc2 = new OtpService(
      {} as never,
      clock,
      cfg,
      {} as never,
      new AuthPolicyService(cfg),
      lockedRepo as unknown as OtpChallengesRepository,
      hmac,
      {} as never,
      new OtpCircuitBreaker(clock),
      {} as never,
    );
    const locked = await svc2.check({} as never, args);
    expect(locked).toMatchObject({ kind: 'locked' });
    expect((locked as { retryAfter: number }).retryAfter).toBe(60);
    // три последних кода номера заблокированы → retryAfter = пауза номера 30 мин (09 §5.4)
    const paused = {
      ...lockedRepo,
      recentDelivered: () => Promise.resolve([0, 1, 2].map(() => row({ status: 'locked' }))),
    };
    const svc3 = new OtpService(
      {} as never,
      clock,
      cfg,
      {} as never,
      new AuthPolicyService(cfg),
      paused as unknown as OtpChallengesRepository,
      hmac,
      {} as never,
      new OtpCircuitBreaker(clock),
      {} as never,
    );
    expect(((await svc3.check({} as never, args)) as { retryAfter: number }).retryAfter).toBe(30 * 60);
  });
});

describe('SmsOtpProvider — ветви доставки (unit, D-MN-06)', () => {
  const clock = new FixedClock(new Date('2026-10-22T08:00:00Z'));

  function make(
    results: (SendResult | Error)[],
    cfg: Partial<AppConfig> = {},
    opts: { chStatus?: OtpChallengeRow['status'] | null; recordFails?: boolean; provider?: 'smspro' | 'fake' } = {},
  ) {
    const sent: { test: boolean; sender: string; attempt: number }[] = [];
    const updates: string[] = [];
    let i = 0;
    const gateway = {
      provider: opts.provider ?? 'smspro',
      send: (req: { test: boolean; sender: string; attempt: number }) => {
        sent.push({ test: req.test, sender: req.sender, attempt: req.attempt });
        const r = results[Math.min(i++, results.length - 1)];
        return r instanceof Error ? Promise.reject(r) : Promise.resolve(r);
      },
    } as unknown as SmsGateway;
    const outbox = {
      insertQueued: () => Promise.resolve({ id: 'o1' }),
      recordResult: () => (opts.recordFails ? Promise.reject(new Error('db')) : Promise.resolve()),
    } as unknown as SmsOutboxRepository;
    const challenges = {
      findById: () => Promise.resolve(opts.chStatus === null ? undefined : row({ status: opts.chStatus ?? 'sent' })),
      update: (_id: string, patch: { status: string }) => {
        updates.push(patch.status);
        return Promise.resolve(undefined);
      },
    } as unknown as OtpChallengesRepository;
    const breaker = new OtpCircuitBreaker(clock);
    const config = {
      APP_ENV: 'dev',
      SMS_OTP_TEMPLATE: 'Код {code}',
      SMSPRO_RETRY_MAX: 2,
      SMSPRO_CB_OPEN_MINUTES: 15,
      SMSPRO_TEST_FLAG: false,
      ...cfg,
    } as AppConfig;
    const p = new SmsOtpProvider(gateway, config, clock, outbox, challenges, breaker, { retryDelayMs: 0 });
    return { p, sent, updates, breaker };
  }
  const res = (outcome: SendResult['outcome'], extra: Partial<SendResult> = {}): SendResult => ({
    transactionId: 't1',
    outcome,
    providerStatus: 0,
    phonesRecognized: 1,
    smsParts: 1,
    latencyMs: 5,
    attempt: 1,
    ...extra,
  });
  const target = { challengeId: 'c1', phoneE164: PHONE, templateKey: 'otp_login' as const };

  async function run(m: ReturnType<typeof make>, onFailed?: () => Promise<void>) {
    const prepared = await m.p.prepare(target, '000000', clock.now(), {} as never);
    m.p.dispatch(prepared, target, '000000', onFailed ? { onFailed } : undefined);
    await m.p.onApplicationShutdown();
  }

  it('исключение шлюза → повтор → ACCEPTED; отправитель по умолчанию Optomstroy', async () => {
    const m = make([new Error('net'), res('ACCEPTED')]);
    await run(m);
    expect(m.sent.map((s) => s.attempt)).toEqual([1, 2]);
    expect(m.sent[0]?.sender).toBe('Optomstroy');
    expect(m.updates).toEqual([]);
  });

  it('все попытки RETRYABLE/исключения → failed_delivery, onFailed; без результата — outcome RETRYABLE', async () => {
    let failed = 0;
    const m = make([res('RETRYABLE', { providerStatus: null })]);
    await run(m, () => {
      failed += 1;
      return Promise.resolve();
    });
    expect(m.sent).toHaveLength(3);
    expect(m.updates).toEqual(['failed_delivery']);
    expect(failed).toBe(1);
    const thrown = make([new Error('down')]);
    await run(thrown);
    expect(thrown.updates).toEqual(['failed_delivery']);
  });

  it('CONFIG_ERROR / INSUFFICIENT_FUNDS → circuit-breaker с причиной; челлендж не sent — статус не меняется', async () => {
    const cfgErr = make([res('CONFIG_ERROR', { providerStatus: 2 })], {}, { chStatus: 'verified' });
    await run(cfgErr);
    expect(cfgErr.breaker.openReason).toBe('config_error');
    expect(cfgErr.updates).toEqual([]);
    const funds = make([res('INSUFFICIENT_FUNDS', { providerStatus: 4 })], {}, { chStatus: null });
    await run(funds);
    expect(funds.breaker.openReason).toBe('insufficient_funds');
    const rejected = make([res('REJECTED' as SendResult['outcome'])]);
    await run(rejected);
    expect(rejected.breaker.isOpen()).toBe(false);
  });

  it('<test>-флаг: SMSPRO_TEST_FLAG; staging+smspro вне allowlist → 1, в allowlist → 0; dev/fake → 0', async () => {
    const flag = make([res('ACCEPTED_TEST')], { SMSPRO_TEST_FLAG: true, SMSPRO_SENDER: 'OPTOM' });
    await run(flag);
    expect(flag.sent[0]).toMatchObject({ test: true, sender: 'OPTOM' });
    const stgOut = make([res('ACCEPTED')], { APP_ENV: 'staging', SMS_STAGING_ALLOWED_PHONES: '+996700000099, ' });
    await run(stgOut);
    expect(stgOut.sent[0]?.test).toBe(true);
    const stgIn = make([res('ACCEPTED')], { APP_ENV: 'staging', SMS_STAGING_ALLOWED_PHONES: PHONE });
    await run(stgIn);
    expect(stgIn.sent[0]?.test).toBe(false);
    const stgNoList = make([res('ACCEPTED')], { APP_ENV: 'staging' });
    await run(stgNoList);
    expect(stgNoList.sent[0]?.test).toBe(true);
    const fake = make([res('ACCEPTED')], { APP_ENV: 'staging' }, { provider: 'fake' });
    await run(fake);
    expect(fake.sent[0]?.test).toBe(false);
  });

  it('сбой записи итога → otp.delivery_error в логе, без необработанного отказа; пауза ретрая > 0', async () => {
    const m = make([res('ACCEPTED')], {}, { recordFails: true });
    await expect(run(m)).resolves.toBeUndefined();
    // не-Error в отказе → err: 'unknown' (имя ошибки, без содержимого)
    const odd = make([res('ACCEPTED')]);
    (odd.p as unknown as { outbox: { recordResult: () => Promise<void> } }).outbox.recordResult = () =>
      // eslint-disable-next-line @typescript-eslint/prefer-promise-reject-errors -- проверяется ветка не-Error
      Promise.reject('db down');
    await expect(run(odd)).resolves.toBeUndefined();
    const gateway = {
      provider: 'fake',
      send: () => Promise.resolve(res('RETRYABLE')),
    } as unknown as SmsGateway;
    const slow = new SmsOtpProvider(
      gateway,
      { SMS_OTP_TEMPLATE: '{code}', SMSPRO_RETRY_MAX: 1, SMSPRO_TEST_FLAG: false, APP_ENV: 'dev' } as AppConfig,
      clock,
      { insertQueued: () => Promise.resolve({ id: 'o' }), recordResult: () => Promise.resolve() } as never,
      { findById: () => Promise.resolve(undefined), update: () => Promise.resolve(undefined) } as never,
      new OtpCircuitBreaker(clock),
      { retryDelayMs: 1 },
    );
    const prepared = await slow.prepare(target, '1', clock.now(), {} as never);
    slow.dispatch(prepared, target, '1');
    await slow.drain();
    const dflt = new SmsOtpProvider(gateway, {} as AppConfig, clock, {} as never, {} as never, {} as never);
    expect(dflt).toBeInstanceOf(SmsOtpProvider);
  });
});

describe('StepUpService.request — ветви (unit, D-MN-06)', () => {
  const clock = new FixedClock(new Date('2026-10-22T08:00:00Z'));
  const principal = {
    kind: 'staff',
    userId: '0192f3a1-6c3e-7a1b-9f00-0000000000aa',
    sessionId: '0192f3a1-6c3e-7a1b-9f00-0000000000bb',
    deviceId: DEV,
    roles: ['admin'],
    status: 'active',
    permissionsVersion: 1,
    amr: ['sms'],
  } as unknown as AuthenticatedPrincipal;

  function make(
    opts: {
      pin?: PinCheck;
      phone?: string | null;
      otpCheck?: unknown;
      permitted?: boolean;
      auditFails?: boolean;
    } = {},
  ) {
    const actions: string[] = [];
    const tx = { execute: () => Promise.resolve({ rows: [] }) };
    const svc = new StepUpService(
      { transaction: <T>(fn: (t: unknown) => Promise<T>) => fn(tx) } as never,
      {
        signPurpose: () => Promise.resolve({ token: 'jwt', expiresAt: new Date(clock.now().getTime() + 900_000) }),
      } as never,
      {
        effectivePermissions: () => new Set(opts.permitted === false ? [] : ['users.manage', 'profile.manage.own']),
      } as never,
      { verify: () => Promise.resolve(opts.pin ?? { kind: 'ok' }) } as never,
      {
        issue: () =>
          Promise.resolve({ challengeId: 'c1', resendAfterSec: 60, otpTtlSec: 300, codeLength: 6, phoneMasked: 'x' }),
        check: () => Promise.resolve(opts.otpCheck ?? { kind: 'ok', challenge: row({}) }),
      } as never,
      { findById: () => Promise.resolve(opts.phone === null ? { phoneE164: null } : { phoneE164: PHONE }) } as never,
      { setStepUp: () => Promise.resolve() } as never,
      {} as StepUpTokenVerifier,
      new AuthHttpRateLimiter(clock),
      {
        write: (_c: unknown, e: { action: string }) => {
          actions.push(e.action);
          return opts.auditFails ? Promise.reject(new Error('audit down')) : Promise.resolve();
        },
      } as never,
    );
    return { svc, actions };
  }
  const req = (patch: Record<string, unknown>) =>
    ({
      principal,
      method: 'pin',
      operation: 'users.manage',
      ip: null,
      requestId: null,
      audit: AUDIT,
      ...patch,
    }) as never;

  it('операция вне прав → 403 operation_not_permitted (аудит failed); PIN не передан → 400 required', async () => {
    expect(StepUpService.required('users.manage').extensions).toMatchObject({
      stepUp: { operation: 'users.manage', allowedMethods: ['pin', 'otp'] },
    });
    const auditDown = make({ permitted: false, auditFails: true });
    await expect(auditDown.svc.request(req({ pin: '1234' }))).rejects.toMatchObject({ code: 'FORBIDDEN' });
    const denied = make({ permitted: false });
    await expect(denied.svc.request(req({ pin: '1234' }))).rejects.toMatchObject({ code: 'FORBIDDEN' });
    expect(denied.actions).toEqual(['auth.step_up.failed']);
    await expect(make().svc.request(req({}))).rejects.toMatchObject({ code: 'VALIDATION_FAILED' });
  });

  it('PIN: ok → токен; 5-я неверная (locked_now) → аудит auth.pin.locked и 423 PIN_LOCKED', async () => {
    const ok = make();
    await expect(ok.svc.request(req({ pin: '482913' }))).resolves.toMatchObject({ kind: 'token' });
    expect(ok.actions).toEqual(['auth.step_up.ok']);
    const locked = make({ pin: { kind: 'locked_now', until: new Date('2027-10-22T08:00:00Z') } });
    await expect(locked.svc.request(req({ pin: '000000' }))).rejects.toMatchObject({ code: 'PIN_LOCKED' });
    expect(locked.actions).toEqual(['auth.pin.locked']);
  });

  it('OTP: шаг 1 без номера → 403 no_phone; шаг 1 → 202; шаг 2 без challengeId/code → 400', async () => {
    await expect(make({ phone: null }).svc.request(req({ method: 'otp' }))).rejects.toMatchObject({
      code: 'FORBIDDEN',
    });
    await expect(make().svc.request(req({ method: 'otp' }))).resolves.toMatchObject({ kind: 'otp' });
    await expect(make().svc.request(req({ method: 'otp', code: '123456' }))).rejects.toMatchObject({
      code: 'VALIDATION_FAILED',
    });
    await expect(make().svc.request(req({ method: 'otp', challengeId: 'c1' }))).rejects.toMatchObject({
      code: 'VALIDATION_FAILED',
    });
  });

  it('OTP шаг 2: ok → токен; replay → OTP_EXPIRED без аудита; not_found → 404; invalid/lockedNow → auth.otp.locked', async () => {
    const step2 = { method: 'otp', challengeId: 'c1', code: '123456' };
    const ok = make();
    await expect(ok.svc.request(req(step2))).resolves.toMatchObject({ kind: 'token', body: { method: 'otp' } });
    const replay = make({ otpCheck: { kind: 'replay', challenge: row({}) } });
    await expect(replay.svc.request(req(step2))).rejects.toMatchObject({ code: 'OTP_EXPIRED' });
    expect(replay.actions).toEqual([]);
    const nf = make({ otpCheck: { kind: 'not_found' } });
    await expect(nf.svc.request(req(step2))).rejects.toMatchObject({ code: 'NOT_FOUND' });
    expect(nf.actions).toEqual([]);
    const lockedNow = make({ otpCheck: { kind: 'invalid', attemptsLeft: 0, lockedNow: true } });
    await expect(lockedNow.svc.request(req(step2))).rejects.toMatchObject({ code: 'OTP_INVALID' });
    expect(lockedNow.actions).toEqual(['auth.otp.locked']);
    const invalid = make({ otpCheck: { kind: 'invalid', attemptsLeft: 3, lockedNow: false } });
    await expect(invalid.svc.request(req(step2))).rejects.toMatchObject({ code: 'OTP_INVALID' });
    expect(invalid.actions).toEqual(['auth.step_up.failed']);
  });
});
