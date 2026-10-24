import { randomUUID } from 'node:crypto';
import { AuthPolicyService } from '../../src/auth/common/auth-policy.js';
import type { AppPinRow, AppPinsRepository } from '../../src/auth/pin/app-pins.repository.js';
import { PIN_LOCK_DAYS, PinVerifier } from '../../src/auth/pin/pin-verifier.service.js';
import type { DbExecutor } from '../../src/common/audit/db-executor.js';
import { FixedClock } from '../../src/common/auth/clock.js';
import { loadAppConfig } from '../../src/common/config/app-config.js';
import { PinHasher } from '../../src/common/crypto/pin-hasher.service.js';
import { parseSecretRing } from '../../src/common/crypto/secret-ring.js';

/** In-memory `app_pins`. */
class FakePins {
  readonly rows = new Map<string, AppPinRow>();
  async find(userId: string): Promise<AppPinRow | undefined> {
    return Promise.resolve(this.rows.get(userId));
  }
  async setAttempts(userId: string, failedAttempts: number, lockedUntil: Date | null): Promise<void> {
    const r = this.rows.get(userId);
    if (r) this.rows.set(userId, { ...r, failedAttempts, lockedUntil });
    return Promise.resolve();
  }
  async rehash(userId: string, v: { pinHash: string; pepperVersion: number }): Promise<void> {
    const r = this.rows.get(userId);
    if (r) this.rows.set(userId, { ...r, ...v });
    return Promise.resolve();
  }
}

/** D-48, 09 §9.6, BIO-020: серверная проверка PIN — 401 PIN_INVALID (attemptsLeft), 5-я неверная подряд → PIN_LOCKED. */
describe('PinVerifier (RM-D-003 п.6; D-48)', () => {
  const clock = new FixedClock(new Date('2026-10-22T08:00:00Z'));
  const config = loadAppConfig({
    APP_ENV: 'dev',
    MIN_APP_VERSION: 'android=1.0.0',
    DATABASE_URL: 'postgres://x:y@h:1/d',
  });
  const v1 = 'a'.repeat(40);
  const v2 = 'b'.repeat(40);
  const hasher = new PinHasher(parseSecretRing('PIN_PEPPER', v1, 1, 'prod'));
  const pins = new FakePins();
  const verifier = new PinVerifier(clock, pins as unknown as AppPinsRepository, hasher, new AuthPolicyService(config));
  const tx = {} as DbExecutor;

  async function seed(pin: string, h: PinHasher = hasher): Promise<string> {
    const userId = randomUUID();
    const r = await h.hash(pin, userId);
    pins.rows.set(userId, {
      userId,
      pinHash: r.pinHash,
      pepperVersion: r.pepperVersion,
      pinLength: r.pinLength,
      failedAttempts: 0,
      lockedUntil: null,
      changedAt: clock.now(),
      createdAt: clock.now(),
      updatedAt: clock.now(),
    });
    return userId;
  }

  it('PIN не задан → not_set (403 FORBIDDEN reason pin_not_set)', async () => {
    const r = await verifier.verify(randomUUID(), '1234', tx);
    expect(r.kind).toBe('not_set');
    const p = PinVerifier.toProblem(r as Exclude<typeof r, { kind: 'ok' }>);
    expect(p.getStatus()).toBe(403);
    expect(p.extensions.reason).toBe('pin_not_set');
  });

  it('1–4-я неверная → invalid attemptsLeft 4…1; 5-я → locked_now (423); далее locked даже с верным PIN', async () => {
    const userId = await seed('482913');
    for (let i = 1; i <= 4; i++) {
      expect(await verifier.verify(userId, '000000', tx)).toEqual({ kind: 'invalid', attemptsLeft: 5 - i });
    }
    const fifth = await verifier.verify(userId, '000000', tx);
    expect(fifth.kind).toBe('locked_now');
    const p = PinVerifier.toProblem(fifth as Exclude<typeof fifth, { kind: 'ok' }>);
    expect(p.getStatus()).toBe(423);
    expect(p.code).toBe('PIN_LOCKED');
    expect(pins.rows.get(userId)?.lockedUntil?.getTime()).toBe(clock.now().getTime() + PIN_LOCK_DAYS * 86_400_000);
    expect((await verifier.verify(userId, '482913', tx)).kind).toBe('locked');
    await verifier.resetAfterOtpLogin(userId, tx);
    expect((await verifier.verify(userId, '482913', tx)).kind).toBe('ok');
  });

  it('верный PIN обнуляет счётчик «подряд»; PIN_INVALID → 401 с attemptsLeft', async () => {
    const userId = await seed('5719');
    await verifier.verify(userId, '0000', tx);
    await verifier.verify(userId, '0000', tx);
    expect((await verifier.verify(userId, '5719', tx)).kind).toBe('ok');
    expect(pins.rows.get(userId)?.failedAttempts).toBe(0);
    const bad = await verifier.verify(userId, '0000', tx);
    expect(bad).toEqual({ kind: 'invalid', attemptsLeft: 4 });
    const p = PinVerifier.toProblem(bad as Exclude<typeof bad, { kind: 'ok' }>);
    expect(p.getStatus()).toBe(401);
    expect(p.code).toBe('PIN_INVALID');
    expect(p.extensions.attemptsLeft).toBe(4);
  });

  it('ротация PIN_PEPPER: хэш старой версии принимается и перехэшируется текущей', async () => {
    const ring = parseSecretRing('PIN_PEPPER', JSON.stringify({ '1': v1, '2': v2 }), 2, 'prod');
    const rotated = new PinVerifier(
      clock,
      pins as unknown as AppPinsRepository,
      new PinHasher(ring),
      new AuthPolicyService(config),
    );
    const userId = await seed('246810'); // версия 1
    expect((await rotated.verify(userId, '246810', tx)).kind).toBe('ok');
    expect(pins.rows.get(userId)?.pepperVersion).toBe(2);
    expect((await rotated.verify(userId, '246810', tx)).kind).toBe('ok');
  });
});
