import { randomUUID } from 'node:crypto';
import { OtpHmacService } from '../../src/common/crypto/otp-hmac.service.js';
import { PIN_ARGON2_PARAMS, PinFormatError, PinHasher } from '../../src/common/crypto/pin-hasher.service.js';
import {
  constantTimeEqual,
  generateAlphanumericId,
  generateOpaqueToken,
  generateOtpCode,
  generateProviderMessageId,
  sha256,
} from '../../src/common/crypto/random.js';
import { parseSecretRing, SecretConfigError } from '../../src/common/crypto/secret-ring.js';
import { testSecret } from './support/keys.js';

describe('common/crypto: PinHasher (Argon2id + PIN_PEPPER + pepper_version) — D-48, 09 §9.6, 07 §5.13', () => {
  const v1 = testSecret();
  const v2 = testSecret();
  const ring1 = parseSecretRing('PIN_PEPPER', v1, 1, 'prod');
  const hasher = new PinHasher(ring1);
  const userId = randomUUID();

  it('hash → PHC argon2id m=19456,t=2,p=1; PIN в хэше отсутствует; verify — верный PIN ok, неверный — нет', async () => {
    const h = await hasher.hash('482913', userId);
    expect(h.pepperVersion).toBe(1);
    expect(h.pinLength).toBe(6);
    expect(h.pinHash).toMatch(/^\$argon2id\$v=19\$m=19456,t=2,p=1\$[A-Za-z0-9+/]+\$[A-Za-z0-9+/]{43}$/);
    expect(h.pinHash).not.toContain('482913');
    expect(PIN_ARGON2_PARAMS).toMatchObject({ memoryCost: 19_456, timeCost: 2, parallelism: 1 });
    expect(await hasher.verify('482913', userId, h.pinHash, 1)).toEqual({ ok: true, needsRehash: false });
    expect((await hasher.verify('482914', userId, h.pinHash, 1)).ok).toBe(false);
    // соль случайная: два хэша одного PIN различаются
    expect((await hasher.hash('482913', userId)).pinHash).not.toBe(h.pinHash);
  });

  it('привязка к user_id и pepper: другой пользователь или другой pepper → false', async () => {
    const h = await hasher.hash('1357', userId);
    expect((await hasher.verify('1357', randomUUID(), h.pinHash, 1)).ok).toBe(false);
    const otherPepper = new PinHasher(parseSecretRing('PIN_PEPPER', testSecret(), 1, 'prod'));
    expect((await otherPepper.verify('1357', userId, h.pinHash, 1)).ok).toBe(false);
  });

  it('ротация pepper: хэш версии 1 проверяется при текущей версии 2 и помечается needsRehash', async () => {
    const h1 = await hasher.hash('246810', userId);
    const rotated = new PinHasher(parseSecretRing('PIN_PEPPER', JSON.stringify({ '1': v1, '2': v2 }), 2, 'prod'));
    expect(rotated.currentPepperVersion).toBe(2);
    expect(await rotated.verify('246810', userId, h1.pinHash, 1)).toEqual({ ok: true, needsRehash: true });
    const h2 = await rotated.hash('246810', userId);
    expect(h2.pepperVersion).toBe(2);
    expect(await rotated.verify('246810', userId, h2.pinHash, 2)).toEqual({ ok: true, needsRehash: false });
    // версия удалена из набора → проверка невозможна (false, без исключения)
    expect((await hasher.verify('246810', userId, h2.pinHash, 2)).ok).toBe(false);
  });

  it('формат PIN 4–6 цифр; мусор в хэше → false без исключения', async () => {
    await expect(hasher.hash('123', userId)).rejects.toThrow(PinFormatError);
    await expect(hasher.hash('1234567', userId)).rejects.toThrow(PinFormatError);
    await expect(hasher.hash('12a4', userId)).rejects.toThrow(PinFormatError);
    expect((await hasher.verify('1234', userId, 'not-a-hash', 1)).ok).toBe(false);
    expect((await hasher.verify('12', userId, 'not-a-hash', 1)).ok).toBe(false);
  });
});

describe('common/crypto: OtpHmacService — 09 §5.2 (HMAC-SHA-256(OTP_HMAC_SECRET, challenge_id:code))', () => {
  const s1 = testSecret();
  const svc = new OtpHmacService(parseSecretRing('OTP_HMAC_SECRET', s1, 1, 'prod'));
  const challengeId = randomUUID();

  it('HMAC детерминирован, 32 байта; верный код → true; неверный код/челлендж → false', () => {
    const h = svc.codeHmac(challengeId, '004512');
    expect(h).toHaveLength(32);
    expect(svc.codeHmac(challengeId, '004512').equals(h)).toBe(true);
    expect(svc.verifyCode(challengeId, '004512', h, 1)).toBe(true);
    expect(svc.verifyCode(challengeId, '004513', h, 1)).toBe(false);
    expect(svc.verifyCode(randomUUID(), '004512', h, 1)).toBe(false);
    expect(svc.verifyCode(challengeId, '004512', h.subarray(0, 16), 1)).toBe(false);
    expect(svc.verifyCode(challengeId, '004512', h, 9)).toBe(false);
  });

  it('ротация: челлендж версии 1 проверяется после перехода на версию 2', () => {
    const h1 = svc.codeHmac(challengeId, '777777');
    const rotated = new OtpHmacService(
      parseSecretRing('OTP_HMAC_SECRET', JSON.stringify({ '1': s1, '2': testSecret() }), 2, 'prod'),
    );
    expect(rotated.verifyCode(challengeId, '777777', h1, 1)).toBe(true);
    expect(rotated.codeHmac(challengeId, '777777').equals(h1)).toBe(false);
  });

  it('псевдоним телефона для rate_limit_counters.subject: hex 64, без номера, домены разделены', () => {
    const p = svc.pseudonym('phone', '+996700123456');
    expect(p).toMatch(/^[0-9a-f]{64}$/);
    expect(p).not.toContain('700123456');
    expect(svc.pseudonym('phone', '+996700123456')).toBe(p);
    expect(svc.pseudonym('device', '+996700123456')).not.toBe(p);
  });
});

describe('common/crypto: CSPRNG-утилиты и секреты', () => {
  it('OTP — ровно 6 цифр с ведущими нулями; распределение первой цифры без явного смещения', () => {
    const counts = new Array<number>(10).fill(0);
    for (let i = 0; i < 20_000; i++) {
      const c = generateOtpCode();
      expect(c).toMatch(/^\d{6}$/);
      counts[Number(c[0])] += 1;
    }
    for (const n of counts) expect(n).toBeGreaterThan(1_600); // ожидание 2 000 ± ~7σ
  });

  it('id SMSPro — 12 символов [A-Za-z0-9]; уникальны; 256-бит токен — base64url 43 символа', () => {
    const ids = new Set<string>();
    for (let i = 0; i < 2_000; i++) {
      const id = generateProviderMessageId();
      expect(id).toMatch(/^[A-Za-z0-9]{12}$/);
      ids.add(id);
    }
    expect(ids.size).toBe(2_000);
    expect(generateAlphanumericId(20)).toMatch(/^[A-Za-z0-9]{20}$/);
    const t = generateOpaqueToken();
    expect(t).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(Buffer.from(t, 'base64url')).toHaveLength(32);
    expect(() => generateOpaqueToken(16)).toThrow(RangeError);
    expect(sha256(t)).toHaveLength(32);
  });

  it('constantTimeEqual: равные/разные/разной длины', () => {
    expect(constantTimeEqual('abc', 'abc')).toBe(true);
    expect(constantTimeEqual('abc', 'abd')).toBe(false);
    expect(constantTimeEqual('abc', 'abcd')).toBe(false);
    expect(constantTimeEqual(Buffer.from([1, 2]), Buffer.from([1, 2]))).toBe(true);
  });

  it('dev без PIN_PEPPER_FILE: эфемерный pepper подтверждает тот же PIN (регрессия A-12/RG-07)', async () => {
    const dev = new PinHasher(parseSecretRing('PIN_PEPPER', undefined, 1, 'dev'));
    const userId = randomUUID();
    const { pinHash } = await dev.hash('482913', userId);
    expect((await dev.verify('482913', userId, pinHash, 1)).ok).toBe(true);
    expect((await dev.verify('482914', userId, pinHash, 1)).ok).toBe(false);
  });

  it('секреты: короче 32 байт, нет текущей версии, не задан вне dev → ошибка; dev без файла → эфемерный', () => {
    expect(() => parseSecretRing('PIN_PEPPER', 'short', 1, 'prod')).toThrow(SecretConfigError);
    expect(() => parseSecretRing('PIN_PEPPER', JSON.stringify({ '1': testSecret() }), 2, 'prod')).toThrow(
      /нет текущей версии 2/,
    );
    expect(() => parseSecretRing('PIN_PEPPER', undefined, 1, 'staging')).toThrow(/обязателен при APP_ENV=staging/);
    expect(() => parseSecretRing('PIN_PEPPER', '{"x":"y"}', 1, 'prod')).toThrow(SecretConfigError);
    const dev = parseSecretRing('PIN_PEPPER', undefined, 3, 'dev');
    expect(dev.ephemeral).toBe(true);
    // base64url-строка 32 случайных байт (43 символа ASCII): валидный UTF-8 для Argon2 (D_spec_questions A-12/RG-07)
    expect(dev.get(3)?.toString('utf8')).toMatch(/^[A-Za-z0-9_-]{43}$/);
    // сообщение об ошибке не содержит значения секрета
    const secret = 'x'.repeat(10);
    try {
      parseSecretRing('OTP_HMAC_SECRET', secret, 1, 'prod');
    } catch (e) {
      expect(String(e)).not.toContain(secret);
    }
  });
});
