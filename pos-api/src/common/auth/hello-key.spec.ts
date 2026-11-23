import { generateKeyPairSync, sign } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import {
  HELLO_CHALLENGE_PREFIX,
  HELLO_CHALLENGE_TTL_MS,
  HELLO_PERSONAL_WINDOW_MS,
  helloChallengeString,
  helloKeyAllowedFor,
  parseHelloPublicKey,
  verifyHelloSignature,
} from './hello-key.js';

/**
 * Правила и криптография ключа Windows Hello (W2; 15 ADR-116; 08 §4.1.8, §4.1.10, §4.3.6; 07 §5.66; 11 SEC-146) —
 * модульная часть 12 T-BIO-035 (форма ключа `hello_key_format`) и T-SEC-076 (подпись чужим ключом и изменённой
 * строки). Тестовые пары RSA создаются в процессе теста.
 */
function rsa(bits = 2048, publicExponent = 65537) {
  const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: bits, publicExponent });
  return {
    spki: publicKey.export({ type: 'spki', format: 'der' }).toString('base64url'),
    der: publicKey.export({ type: 'spki', format: 'der' }),
    sign: (msg: string) => sign('sha256', Buffer.from(msg, 'utf8'), privateKey).toString('base64url'),
  };
}

describe('hello-key (W2): переменная, challenge, открытый ключ, подпись', () => {
  const key = rsa();

  it('AUTH_WINDOWS_HELLO_KEY: off — никому; personal и all — сотруднику и покупателю; планшету — никогда (09 BIO-037)', () => {
    const table = (['off', 'personal', 'all'] as const).map((mode) => [
      mode,
      helloKeyAllowedFor(mode, 'staff'),
      helloKeyAllowedFor(mode, 'customer'),
      helloKeyAllowedFor(mode, 'kiosk'),
    ]);
    expect(table).toEqual([
      ['off', false, false, false],
      ['personal', true, true, false],
      ['all', true, true, false],
    ]);
    expect(() => helloKeyAllowedFor('all', 'integration' as never)).toThrow();
  });

  it('challenge: префикс назначения + base64url 32 байт (шаблон контракта), 120 с; окно personal — 30 дней', () => {
    const s = helloChallengeString(Buffer.alloc(32, 0xff));
    expect(s).toMatch(/^optomstroy-hello-unlock\/v1:[A-Za-z0-9_-]{43}$/);
    expect(s.startsWith(HELLO_CHALLENGE_PREFIX)).toBe(true);
    expect(HELLO_CHALLENGE_TTL_MS).toBe(120_000);
    expect(HELLO_PERSONAL_WINDOW_MS).toBe(30 * 86_400_000);
  });

  it('открытый ключ: RSA 2048 и 4096 с 65537 — DER; RSA-1024, экспонента 3, EC, RSA-PSS, мусор, не base64url — null', () => {
    expect(parseHelloPublicKey(key.spki)?.equals(key.der)).toBe(true);
    expect(parseHelloPublicKey(rsa(4096).spki)).not.toBeNull();
    expect(parseHelloPublicKey(rsa(3072).spki)).not.toBeNull();
    expect(parseHelloPublicKey(rsa(1024).spki)).toBeNull();
    expect(parseHelloPublicKey(rsa(2048, 3).spki)).toBeNull();
    const ec = generateKeyPairSync('ec', { namedCurve: 'P-256' }).publicKey.export({ type: 'spki', format: 'der' });
    expect(parseHelloPublicKey(ec.toString('base64url'))).toBeNull();
    const pss = generateKeyPairSync('rsa-pss', { modulusLength: 2048 }).publicKey.export({
      type: 'spki',
      format: 'der',
    });
    expect(parseHelloPublicKey(pss.toString('base64url'))).toBeNull();
    expect(parseHelloPublicKey('A'.repeat(400))).toBeNull();
    expect(parseHelloPublicKey(`${key.spki}=`)).toBeNull();
    expect(parseHelloPublicKey(`${key.spki.slice(0, 100)}+${key.spki.slice(101)}`)).toBeNull();
  });

  it('подпись RSASSA-PKCS1-v1_5 / SHA-256 над UTF-8 строки challenge: верная — true; чужой ключ, изменённая строка, мусор — false', () => {
    const challenge = helloChallengeString(Buffer.alloc(32, 7));
    expect(verifyHelloSignature(key.der, challenge, key.sign(challenge))).toBe(true);
    expect(verifyHelloSignature(key.der, challenge, rsa().sign(challenge))).toBe(false);
    expect(verifyHelloSignature(key.der, challenge, key.sign(`${challenge}x`))).toBe(false);
    expect(verifyHelloSignature(key.der, challenge, key.sign(challenge.slice(HELLO_CHALLENGE_PREFIX.length)))).toBe(
      false,
    );
    expect(verifyHelloSignature(key.der, challenge, 'не base64url')).toBe(false);
    expect(verifyHelloSignature(key.der, challenge, 'A'.repeat(342))).toBe(false);
    expect(verifyHelloSignature(Buffer.from('битый ключ'), challenge, key.sign(challenge))).toBe(false);
  });
});
