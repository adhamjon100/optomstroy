import { AuthPolicyService } from '../../src/auth/common/auth-policy.js';
import { AuthHttpRateLimiter } from '../../src/auth/common/http-rate-limits.js';
import { normalizeKgPhone, phoneMasked } from '../../src/auth/common/phone.js';
import { maskIp } from '../../src/auth/common/request.js';
import type { OtpChallengeRow, OtpChallengesRepository } from '../../src/auth/otp/otp-challenges.repository.js';
import { OtpCircuitBreaker } from '../../src/auth/otp/otp-circuit-breaker.js';
import { OtpService } from '../../src/auth/otp/otp.service.js';
import { permissionForOperation, STEP_UP_OPERATIONS, tokenScope } from '../../src/auth/step-up/step-up.operations.js';
import type { DbExecutor } from '../../src/common/audit/db-executor.js';
import { FixedClock } from '../../src/common/auth/clock.js';
import { loadAppConfig } from '../../src/common/config/app-config.js';
import { OtpHmacService } from '../../src/common/crypto/otp-hmac.service.js';
import { generateOtpCode } from '../../src/common/crypto/random.js';
import { parseSecretRing } from '../../src/common/crypto/secret-ring.js';
import type { SettingsReader } from '../../src/common/settings/settings-reader.js';

const BASE_ENV = { APP_ENV: 'dev', MIN_APP_VERSION: 'android=1.0.0', DATABASE_URL: 'postgres://x:y@127.0.0.1:1/none' };
const config = (extra: Record<string, string> = {}) => loadAppConfig({ ...BASE_ENV, ...extra });

describe('auth: нормализация телефона КР (09 §3.4; 08 §2.14; 12 T-AUTH-026)', () => {
  it.each([
    ['+996700123456', '+996700123456'],
    ['996700123456', '+996700123456'],
    ['0700123456', '+996700123456'],
    ['700123456', '+996700123456'],
    ['+996 (700) 12-34-56', '+996700123456'],
    ['+996 555 123 456', '+996555123456'],
    ['+996 220 123 456', '+996220123456'],
    ['+996 990 123 456', '+996990123456'],
  ])('%s → %s', (input, out) => {
    expect(normalizeKgPhone(input)).toBe(out);
  });

  it.each([
    '+79161234567',
    '+996312123456',
    '+996412123456',
    '+99670012345',
    '+9967001234567',
    '',
    'abc',
    '8 700 123 456',
  ])('отвергается: %s', (input) => {
    expect(normalizeKgPhone(input)).toBeNull();
  });

  it('не строка и слишком длинная строка → null; маска +996 7** *** *56', () => {
    expect(normalizeKgPhone(700123456)).toBeNull();
    expect(normalizeKgPhone('+996700123456'.padEnd(40, ' '))).toBeNull();
    expect(phoneMasked('+996700123456')).toBe('+996 7** *** *56');
    expect(maskIp('212.42.100.12')).toBe('212.***.***.12');
    expect(maskIp('2001:db8::1')).toBe('2001:****');
    expect(maskIp(null)).toBeUndefined();
  });
});

describe('auth: генерация кода (12 T-AUTH-012; D-10)', () => {
  it('100 000 кодов: ровно 6 цифр, ведущие нули сохраняются, распределение цифр без смещения (χ², α = 0,01)', () => {
    const counts = new Array<number>(10).fill(0);
    let leadingZero = 0;
    for (let i = 0; i < 100_000; i++) {
      const c = generateOtpCode();
      expect(c).toMatch(/^\d{6}$/);
      if (c.startsWith('0')) leadingZero += 1;
      for (const ch of c) counts[Number(ch)] = (counts[Number(ch)] ?? 0) + 1;
    }
    expect(leadingZero).toBeGreaterThan(8_000);
    const expected = 600_000 / 10;
    const chi2 = counts.reduce((acc, n) => acc + (n - expected) ** 2 / expected, 0);
    expect(chi2).toBeLessThan(21.666); // χ²(0.99; df = 9)
  });
});

describe('auth: эффективная политика (env + app_settings, RM-D-001 п.1)', () => {
  const fakeSettings = (values: Record<string, unknown>, failing = false): SettingsReader =>
    ({
      get: (key: string) => (failing ? Promise.reject(new Error('db down')) : Promise.resolve(values[key])),
    }) as unknown as SettingsReader;

  it('значения по умолчанию D-10/D-12 из env', () => {
    const p = new AuthPolicyService(config()).base();
    expect(p.otp).toMatchObject({
      ttlSeconds: 300,
      maxAttempts: 5,
      resendCooldownSeconds: 60,
      maxPerPhone15m: 3,
      maxPerPhone24h: 10,
      maxPerIp10m: 20,
      maxPerIp24h: 100,
      maxPerDevice10m: 5,
      maxPerDevice24h: 20,
      globalPerMinute: 60,
      lockAfterLockedCodes: 3,
      phonePauseMinutes: 30,
      replayWindowSeconds: 60,
      codeLength: 6,
    });
    expect(p.session).toMatchObject({
      refreshTtlStaffDays: 7,
      refreshTtlCustomerDays: 30,
      idleStaffHours: 24,
      idleCustomerDays: 14,
      graceSeconds: 30,
      idleLockMinutes: 30,
      maxSessionsStaff: 3,
      maxSessionsCustomer: 5,
      registrationTokenTtlSeconds: 900,
      stepUpTtlSeconds: 900,
      pinMaxAttempts: 5,
    });
  });

  it('app_settings otp.ttl_seconds / otp.max_attempts / session.staff_refresh_days переопределяют env в коридоре', async () => {
    const svc = new AuthPolicyService(
      config(),
      fakeSettings({ 'otp.ttl_seconds': 240, 'otp.max_attempts': '4', 'session.staff_refresh_days': 5 }),
    );
    const p = await svc.effective();
    expect(p.otp.ttlSeconds).toBe(240);
    expect(p.otp.maxAttempts).toBe(4);
    expect(p.session.refreshTtlStaffDays).toBe(5);
  });

  it('значения вне коридора 09 и ошибка БД → env', async () => {
    const out = await new AuthPolicyService(
      config(),
      fakeSettings({ 'otp.ttl_seconds': 3600, 'otp.max_attempts': 1.5, 'session.staff_refresh_days': 'x' }),
    ).effective();
    expect(out.otp.ttlSeconds).toBe(300);
    expect(out.otp.maxAttempts).toBe(5);
    expect(out.session.refreshTtlStaffDays).toBe(7);
    const down = await new AuthPolicyService(config(), fakeSettings({}, true)).effective();
    expect(down.otp.ttlSeconds).toBe(300);
    const none = await new AuthPolicyService(config()).effective();
    expect(none.otp.maxAttempts).toBe(5);
  });
});

/** In-memory `otp_challenges` для проверки веток `OtpService.check` (09 §4.3 порядок; §5.3; §5.6). */
class FakeChallenges {
  readonly rows = new Map<string, OtpChallengeRow>();
  async findById(id: string): Promise<OtpChallengeRow | undefined> {
    return Promise.resolve(this.rows.get(id));
  }
  async update(id: string, patch: Partial<OtpChallengeRow>, at: Date): Promise<OtpChallengeRow | undefined> {
    const r = this.rows.get(id);
    if (!r) return undefined;
    const next = { ...r, ...patch, updatedAt: at };
    this.rows.set(id, next);
    return Promise.resolve(next);
  }
  async recentDelivered(): Promise<OtpChallengeRow[]> {
    return Promise.resolve([...this.rows.values()].sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime()));
  }
}

describe('OtpService.check — ветви проверки кода (unit, 100 % веток; RM-D-001 п.1)', () => {
  const clock = new FixedClock(new Date('2026-10-22T08:00:00Z'));
  const hmac = new OtpHmacService(parseSecretRing('OTP_HMAC_SECRET', 'x'.repeat(40), 1, 'prod'));
  const repo = new FakeChallenges();
  const policy = new AuthPolicyService(config());
  const svc = new OtpService(
    {} as never,
    clock,
    config(),
    {} as never,
    policy,
    repo as unknown as OtpChallengesRepository,
    hmac,
    {} as never,
    new OtpCircuitBreaker(clock),
    {} as never,
  );
  const tx = {} as DbExecutor;
  const DEV = '6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b';
  let seq = 0;

  function challenge(patch: Partial<OtpChallengeRow> = {}): { id: string; code: string } {
    seq += 1;
    const id = `0192f3a1-6c3e-7a1b-9f00-${String(seq).padStart(12, '0')}`;
    const code = '004512';
    const now = clock.now();
    repo.rows.set(id, {
      id,
      phoneE164: '+996700000001',
      userId: null,
      purpose: 'login_or_register',
      codeHmac: hmac.codeHmac(id, code),
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
    });
    return { id, code };
  }
  const check = (
    id: string,
    code: string,
    opts: { device?: string; purpose?: 'step_up'; userId?: string; replay?: boolean } = {},
  ) =>
    svc.check(tx, {
      challengeId: id,
      code,
      deviceKey: opts.device ?? DEV,
      purpose: opts.purpose ?? 'login_or_register',
      ...(opts.userId ? { userId: opts.userId } : {}),
      allowReplay: opts.replay ?? true,
    });

  it('T-SEC-004: нет челленджа / другое назначение / чужой пользователь → not_found', async () => {
    expect((await check('0192f3a1-6c3e-7a1b-9f00-ffffffffffff', '000000')).kind).toBe('not_found');
    const c = challenge();
    expect((await check(c.id, c.code, { purpose: 'step_up' })).kind).toBe('not_found');
    const s = challenge({ purpose: 'step_up', userId: '0192f3a1-6c3e-7a1b-9f00-aaaaaaaaaaaa' });
    expect(
      (await check(s.id, s.code, { purpose: 'step_up', userId: '0192f3a1-6c3e-7a1b-9f00-bbbbbbbbbbbb' })).kind,
    ).toBe('not_found');
  });

  it('чужое устройство → device_mismatch, попытка учтена; на max-й — locked', async () => {
    const c = challenge({ attempts: 3 });
    expect((await check(c.id, c.code, { device: '00000000-0000-4000-8000-000000000000' })).kind).toBe(
      'device_mismatch',
    );
    expect(repo.rows.get(c.id)?.attempts).toBe(4);
    await check(c.id, c.code, { device: '00000000-0000-4000-8000-000000000000' });
    expect(repo.rows.get(c.id)?.status).toBe('locked');
    const v = challenge({ status: 'verified', verifiedAt: clock.now(), attempts: 1 });
    expect((await check(v.id, v.code, { device: '00000000-0000-4000-8000-000000000000' })).kind).toBe(
      'device_mismatch',
    );
    expect(repo.rows.get(v.id)?.attempts).toBe(1);
  });

  it('потреблённый: повтор ≤ 60 с с верным кодом → replay; > 60 с, повтор повтора, неверный код, без allowReplay → expired', async () => {
    const at = clock.now();
    const c = challenge({ status: 'verified', verifiedAt: at });
    expect((await check(c.id, c.code)).kind).toBe('replay');
    expect((await check(c.id, '999999')).kind).toBe('expired');
    expect((await check(c.id, c.code, { replay: false })).kind).toBe('expired');
    const r = challenge({ status: 'verified', verifiedAt: at, replayedAt: at });
    expect((await check(r.id, r.code)).kind).toBe('expired');
    const old = challenge({ status: 'verified', verifiedAt: new Date(at.getTime() - 61_000) });
    expect((await check(old.id, old.code)).kind).toBe('expired');
  });

  it('locked / superseded / expired / failed_delivery и истёкший по часам', async () => {
    const l = challenge({ status: 'locked' });
    const lr = await check(l.id, l.code);
    expect(lr.kind).toBe('locked');
    for (const status of ['superseded', 'expired', 'failed_delivery'] as const) {
      const c = challenge({ status });
      expect((await check(c.id, c.code)).kind).toBe('expired');
    }
    const e = challenge({ expiresAt: new Date(clock.now().getTime() - 1) });
    expect((await check(e.id, e.code)).kind).toBe('expired');
    expect(repo.rows.get(e.id)?.status).toBe('expired');
    const exhausted = challenge({ attempts: 5 });
    expect((await check(exhausted.id, exhausted.code)).kind).toBe('locked');
    expect(repo.rows.get(exhausted.id)?.status).toBe('locked');
  });

  it('неверный код: attemptsLeft убывает; 5-я неверная → lockedNow; верный → ok, verified', async () => {
    const c = challenge();
    for (let i = 1; i <= 4; i++) {
      const r = await check(c.id, '111111');
      expect(r).toEqual({ kind: 'invalid', attemptsLeft: 5 - i, lockedNow: false });
    }
    expect(await check(c.id, '111111')).toEqual({ kind: 'invalid', attemptsLeft: 0, lockedNow: true });
    expect(repo.rows.get(c.id)?.status).toBe('locked');
    const ok = challenge({ attempts: 2 });
    const r = await check(ok.id, ok.code);
    expect(r.kind).toBe('ok');
    expect(repo.rows.get(ok.id)).toMatchObject({ status: 'verified', attempts: 3 });
  });

  it('toProblem: коды и статусы 08 §2.4', () => {
    expect(OtpService.toProblem({ kind: 'not_found' }).getStatus()).toBe(404);
    expect(OtpService.toProblem({ kind: 'device_mismatch' }).code).toBe('DEVICE_MISMATCH');
    expect(OtpService.toProblem({ kind: 'expired' }).getStatus()).toBe(422);
    const locked = OtpService.toProblem({ kind: 'locked', retryAfter: 42 });
    expect(locked.getStatus()).toBe(423);
    expect(locked.headers['Retry-After']).toBe('42');
    const inv = OtpService.toProblem({ kind: 'invalid', attemptsLeft: 2, lockedNow: false });
    expect(inv.extensions.attemptsLeft).toBe(2);
  });

  it('T-SEC-007: тестовый режим: только dev/staging, allowlist и валидный AUTH_OTP_TEST_CODE', () => {
    const mk = (env: Record<string, string>) =>
      new OtpService(
        {} as never,
        clock,
        config(env),
        {} as never,
        policy,
        {} as never,
        hmac,
        {} as never,
        {} as never,
        {} as never,
      );
    const on = {
      AUTH_OTP_TEST_MODE: 'true',
      AUTH_OTP_TEST_CODE: '246810',
      AUTH_OTP_TEST_PHONES: '+996700000001,+996700000002',
    };
    expect(mk(on).isTestPhone('+996700000002')).toBe(true);
    expect(mk(on).isTestPhone('+996700000003')).toBe(false);
    expect(mk({ ...on, AUTH_OTP_TEST_MODE: 'false' }).isTestPhone('+996700000001')).toBe(false);
    expect(mk({ ...on, AUTH_OTP_TEST_CODE: '12ab' }).isTestPhone('+996700000001')).toBe(false);
    expect(() => config({ ...on, APP_ENV: 'prod', PUBLIC_BASE_URL: 'https://x.kg' })).toThrow(/AUTH_OTP_TEST_MODE/);
    // ADR-109: AUTH_OTP_TEST_PHONES=* — любой номер только при APP_ENV=dev; в staging и prod конфигурация не принимается
    const any = { ...on, AUTH_OTP_TEST_PHONES: '*' };
    expect(mk(any).isTestPhone('+996555123456')).toBe(true);
    expect(mk(any).isTestPhone('+996220000030')).toBe(true);
    expect(mk({ ...any, AUTH_OTP_TEST_MODE: 'false' }).isTestPhone('+996555123456')).toBe(false);
    expect(() => config({ ...any, APP_ENV: 'staging', PUBLIC_BASE_URL: 'https://stage.x.kg' })).toThrow(
      /AUTH_OTP_TEST_PHONES/,
    );
    expect(() => config({ ...any, APP_ENV: 'prod', PUBLIC_BASE_URL: 'https://x.kg' })).toThrow(/AUTH_OTP_/);
  });
});

describe('auth: in-memory лимиты 08 §2.9 и circuit-breaker', () => {
  it('RL-OTP-STATUS: 20 запросов на челлендж, 21-й → 429 RATE_LIMITED с retryAfter; окно сбрасывается', () => {
    const clock = new FixedClock(new Date('2026-10-22T08:00:00Z'));
    const l = new AuthHttpRateLimiter(clock);
    for (let i = 0; i < 20; i++) l.otpStatus('c1', 'd1');
    try {
      l.otpStatus('c1', 'd1');
      expect.unreachable();
    } catch (e) {
      expect(e).toMatchObject({ code: 'RATE_LIMITED' });
      expect((e as { extensions: { retryAfter: number } }).extensions.retryAfter).toBeGreaterThan(0);
    }
    clock.advance(10 * 60_000);
    expect(() => l.otpStatus('c1', 'd1')).not.toThrow();
    expect(() => l.publicIp(null)).not.toThrow();
  });

  it('ревью D-MN-03: переполнение ключами 1-минутной группы не сбрасывает 10-минутную группу (очистка по окну корзины)', () => {
    const clock = new FixedClock(new Date('2026-10-22T08:00:00Z'));
    const l = new AuthHttpRateLimiter(clock);
    for (let i = 0; i < 20; i++) l.otpStatus('c1', 'd1');
    expect(() => l.otpStatus('c1', 'd1')).toThrow();
    clock.advance(61_000);
    // атакующий перебирает X-Device-Id / IP: 50 000 ключей RL-PUBLIC-IP → срабатывает очистка
    for (let i = 0; i < 50_000; i++) l.publicIp(`10.0.${Math.floor(i / 250)}.${i % 250}`);
    expect(l.size).toBeGreaterThanOrEqual(50_000);
    expect(() => l.otpStatus('c1', 'd1')).toThrow(); // RL-OTP-STATUS по-прежнему исчерпан
    clock.advance(10 * 60_000);
    expect(() => l.otpStatus('c1', 'd1')).not.toThrow(); // окно истекло
  });

  it('DQ-01: RL-PIN и RL-OTP-VERIFY — через RateLimitService (pin_user_device_10m / otp_verify_ip_10m); без него — память', async () => {
    const clock = new FixedClock(new Date('2026-10-22T08:00:00Z'));
    const calls: { scope: string; subject: string; limit: number }[] = [];
    let deny = false;
    const rl = {
      consume: (rules: { scope: string; subject: string; limit: number }[]) => {
        calls.push(...rules);
        return Promise.resolve(
          deny
            ? { allowed: false, decisions: [], retryAfterSec: 0, deniedScope: rules[0].scope }
            : { allowed: true, decisions: [], retryAfterSec: 0 },
        );
      },
    };
    const l = new AuthHttpRateLimiter(clock, rl as never);
    await l.pin('u1', 'd1');
    await l.otpVerifyIp(null);
    expect(calls).toEqual([
      { scope: 'pin_user_device_10m', subject: 'u1:d1', limit: 30 },
      { scope: 'otp_verify_ip_10m', subject: 'unknown', limit: 60 },
    ]);
    deny = true;
    const err = await l.pin('u1', 'd1').catch((e: unknown) => e);
    expect(err).toMatchObject({ code: 'RATE_LIMITED' });
    expect((err as { extensions: { retryAfter: number } }).extensions.retryAfter).toBe(1);
    // без RateLimitService — то же правило в памяти процесса
    const mem = new AuthHttpRateLimiter(clock);
    for (let i = 0; i < 30; i++) await mem.pin('u1', 'd1');
    await expect(mem.pin('u1', 'd1')).rejects.toMatchObject({ code: 'RATE_LIMITED' });
    clock.advance(10 * 60_000);
    await expect(mem.pin('u1', 'd1')).resolves.toBeUndefined();
  });

  it('OtpCircuitBreaker: открыт на N минут, затем закрыт', () => {
    const clock = new FixedClock(new Date('2026-10-22T08:00:00Z'));
    const b = new OtpCircuitBreaker(clock);
    expect(b.isOpen()).toBe(false);
    b.open('global_limit', 5);
    expect(b.isOpen()).toBe(true);
    expect(b.openReason).toBe('global_limit');
    clock.advance(5 * 60_000);
    expect(b.isOpen()).toBe(false);
    expect(b.openReason).toBeUndefined();
  });
});

describe('step-up: операции и области (08 §2.12)', () => {
  it('25 значений operation; право — код 11 §4.3 или profile/session.manage.own; scope токена — [operation]', () => {
    expect(STEP_UP_OPERATIONS).toHaveLength(25);
    expect(permissionForOperation('profile.pin.set')).toBe('profile.manage.own');
    expect(permissionForOperation('session.logout_all')).toBe('session.manage.own');
    expect(permissionForOperation('session.revoke.any')).toBe('session.revoke.any');
    expect(permissionForOperation('payment.qr.confirm_manual')).toBe('payment.qr.confirm_manual');
    expect(tokenScope('profile.biometrics.toggle')).toEqual(['profile.biometrics.toggle']);
  });
});
