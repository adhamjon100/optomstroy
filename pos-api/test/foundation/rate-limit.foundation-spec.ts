import { FixedClock } from '../../src/common/auth/clock.js';
import { OtpHmacService } from '../../src/common/crypto/otp-hmac.service.js';
import { parseSecretRing } from '../../src/common/crypto/secret-ring.js';
import {
  RATE_LIMIT_SCOPES,
  RATE_LIMIT_WINDOWS,
  RateLimitService,
} from '../../src/common/rate-limit/rate-limit.service.js';
import { FoundationDb } from './support/foundation-db.js';
import { testSecret } from './support/keys.js';

describe('common/rate-limit: счётчики в PostgreSQL rate_limit_counters (D-44; 07 §5.12; 09 §5.4)', () => {
  const fdb = new FoundationDb();
  const clock = new FixedClock(new Date('2026-10-22T10:05:00Z'));
  const hmac = new OtpHmacService(parseSecretRing('OTP_HMAC_SECRET', testSecret(), 1, 'prod'));
  let rl: RateLimitService;

  beforeAll(async () => {
    await fdb.start('foundation_rl');
    rl = new RateLimitService(fdb.db, clock);
  });

  afterAll(async () => {
    await fdb.stop();
  });

  it('3 отправки / 15 мин на номер: 1–3 разрешены, 4-я → отказ с Retry-After до конца окна; телефон хранится HMAC', async () => {
    const subject = hmac.pseudonym('phone', '+996700111222');
    const rule = { scope: 'otp_phone_15m' as const, subject, limit: 3 };
    for (let i = 1; i <= 3; i++) {
      const r = await rl.consume([rule]);
      expect(r.allowed).toBe(true);
      expect(r.decisions[0]).toMatchObject({ count: i, remaining: 3 - i, retryAfterSec: 0 });
    }
    const denied = await rl.consume([rule]);
    expect(denied).toMatchObject({ allowed: false, deniedScope: 'otp_phone_15m', retryAfterSec: 600 });
    expect(denied.decisions[0]).toMatchObject({ count: 3, remaining: 0 });
    const rows = await fdb.pool.query(`SELECT subject, count, window_start, window_end FROM rate_limit_counters`);
    expect(rows.rows).toHaveLength(1);
    expect(rows.rows[0].subject).toBe(subject);
    expect(rows.rows[0].count).toBe(3);
    expect((rows.rows[0].window_start as Date).toISOString()).toBe('2026-10-22T10:00:00.000Z');
    expect((rows.rows[0].window_end as Date).toISOString()).toBe('2026-10-22T10:15:00.000Z');
    // следующее окно — счётчик с нуля
    clock.advance(10 * 60_000);
    expect((await rl.consume([rule])).decisions[0]?.count).toBe(1);
  });

  it('набор правил атомарен: если одно правило исчерпано, остальные счётчики не увеличиваются', async () => {
    const phone = { scope: 'otp_phone_24h' as const, subject: hmac.pseudonym('phone', '+996700333444'), limit: 10 };
    const ip = { scope: 'otp_ip_1h' as const, subject: '203.0.113.9', limit: 2 };
    expect((await rl.consume([phone, ip])).allowed).toBe(true);
    expect((await rl.consume([phone, ip])).allowed).toBe(true);
    const r = await rl.consume([phone, ip]);
    expect(r.allowed).toBe(false);
    expect(r.deniedScope).toBe('otp_ip_1h');
    const peek = await rl.peek([phone, ip]);
    expect(peek.decisions.map((d) => d.count)).toEqual([2, 2]);
  });

  it('конкуренция: 25 параллельных consume при лимите 5 → ровно 5 разрешены', async () => {
    const rule = { scope: 'step_up_user_1h' as const, subject: '0199f1c2-0000-7000-8000-00000000abcd', limit: 5 };
    const results = await Promise.all(Array.from({ length: 25 }, () => rl.consume([rule])));
    expect(results.filter((r) => r.allowed)).toHaveLength(5);
    expect((await rl.peek([rule])).decisions[0]?.count).toBe(5);
  });

  it('reset текущего окна, очистка строк старше window_end + 1 сутки', async () => {
    const rule = { scope: 'login_ip_1h' as const, subject: '198.51.100.1', limit: 1 };
    expect((await rl.consume([rule])).allowed).toBe(true);
    expect((await rl.consume([rule])).allowed).toBe(false);
    await rl.reset('login_ip_1h', '198.51.100.1');
    expect((await rl.consume([rule])).allowed).toBe(true);
    const before = Number((await fdb.pool.query(`SELECT count(*) FROM rate_limit_counters`)).rows[0].count);
    clock.advance(2 * 24 * 3600_000);
    const purged = await rl.purgeExpired();
    expect(purged).toBeGreaterThan(0);
    const after = Number((await fdb.pool.query(`SELECT count(*) FROM rate_limit_counters`)).rows[0].count);
    expect(after).toBe(before - purged);
  });

  it('DQ-01 (миграция 0003): области RateLimitService = CHECK rate_limit_counters_scope_chk; каждая принимается БД', async () => {
    const def = await fdb.pool.query<{ def: string }>(
      `SELECT pg_get_constraintdef(oid) AS def FROM pg_constraint WHERE conname = 'rate_limit_counters_scope_chk'`,
    );
    const inCheck = [...def.rows[0].def.matchAll(/'([a-z0-9_]+)'::text/g)].map((m) => m[1]).sort();
    expect(inCheck).toEqual([...RATE_LIMIT_SCOPES].sort());
    for (const scope of ['otp_ip_10m', 'otp_ip_24h', 'otp_device_10m', 'otp_global_1m'] as const) {
      expect(RATE_LIMIT_WINDOWS[scope]).toBe(scope.endsWith('24h') ? 86_400 : scope.endsWith('1m') ? 60 : 600);
    }
    for (const scope of RATE_LIMIT_SCOPES) {
      const r = await rl.consume([{ scope, subject: `dq01-${scope}`, limit: 1 }]);
      expect(r.allowed).toBe(true);
      expect((await rl.consume([{ scope, subject: `dq01-${scope}`, limit: 1 }])).deniedScope).toBe(scope);
    }
  });

  it('валидация: сырой телефон в subject, неизвестная область, limit < 1 → RangeError', async () => {
    await expect(rl.consume([{ scope: 'otp_phone_15m', subject: '+996700111222', limit: 3 }])).rejects.toThrow(/HMAC/);
    await expect(rl.consume([{ scope: 'otp_bogus_1m' as never, subject: 'x', limit: 3 }])).rejects.toThrow(RangeError);
    await expect(rl.consume([{ scope: 'otp_ip_1h', subject: 'x', limit: 0 }])).rejects.toThrow(RangeError);
  });
});
