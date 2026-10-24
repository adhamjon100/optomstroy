import { createHmac, generateKeyPairSync, randomUUID } from 'node:crypto';
import { base64url, decodeJwt, decodeProtectedHeader, SignJWT, UnsecuredJWT } from 'jose';
import { FixedClock } from '../../src/common/auth/clock.js';
import { JwtKeyConfigError, parseJwtKeyRing } from '../../src/common/auth/jwt-keys.js';
import { type AccessTokenInput, JwtService, JwtVerificationError } from '../../src/common/auth/jwt.service.js';
import { issueTestJwt } from '../../scripts/issue_test_jwt.js';
import { TempJwtKeys } from '../integrations/support/jwt-test-auth.js';
import { pemPair, publicSet } from './support/keys.js';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function input(over: Partial<AccessTokenInput> = {}): AccessTokenInput {
  return {
    sub: randomUUID(),
    kind: 'staff',
    roles: ['seller'],
    permissionsVersion: 1,
    deviceId: randomUUID(),
    sid: randomUUID(),
    ...over,
  };
}

async function expectReject(p: Promise<unknown>, reason: string): Promise<void> {
  const err = await p.then(
    () => undefined,
    (e: unknown) => e,
  );
  expect(err).toBeInstanceOf(JwtVerificationError);
  expect((err as JwtVerificationError).reason).toBe(reason);
}

describe('common/auth JwtService (jose, EdDSA, kid-ротация) — RM-D-003 п. 4, 09 §8.1, API-041', () => {
  const k1 = pemPair();
  const k2 = pemPair();
  const clock = new FixedClock(new Date('2026-10-22T09:00:00Z'));
  const ring = parseJwtKeyRing({
    privateKeyPem: k1.privatePem,
    publicKeys: publicSet({ 'k-2026-10': k1 }),
    keyId: 'k-2026-10',
    appEnv: 'prod',
  });
  const jwt = new JwtService(ring, { accessTtlSeconds: 900 }, clock);

  it('подпись и проверка: EdDSA, kid, typ=JWT, claims sub/kind/roles/permissionsVersion/deviceId/sid/jti, TTL 900 с', async () => {
    const i = input({ permissionsVersion: 7 });
    const issued = await jwt.signAccess(i);
    const header = decodeProtectedHeader(issued.token);
    expect(header).toEqual({ alg: 'EdDSA', typ: 'JWT', kid: 'k-2026-10' });
    const raw = decodeJwt(issued.token);
    expect(Object.keys(raw).sort()).toEqual(
      [
        'amr',
        'aud',
        'deviceId',
        'exp',
        'iat',
        'iss',
        'jti',
        'kind',
        'permissionsVersion',
        'roles',
        'sid',
        'sub',
      ].sort(),
    );
    expect(raw.exp! - raw.iat!).toBe(900);
    expect(issued.jti).toMatch(UUID_RE);
    const c = await jwt.verifyAccess(issued.token);
    expect(c).toMatchObject({ ...i, jti: issued.jti, amr: ['sms'] });
  });

  it('T-SEC-009, T-SESS-001: alg=none (Unsecured JWT) → отказ alg_not_allowed', async () => {
    const i = input();
    const unsecured = new UnsecuredJWT({ ...i, jti: randomUUID() })
      .setIssuer('optomstroy-pos')
      .setAudience('optomstroy-api')
      .setSubject(i.sub)
      .setIssuedAt()
      .setExpirationTime('10m')
      .encode();
    await expectReject(jwt.verifyAccess(unsecured), 'alg_not_allowed');
    // alg=none с заголовком kid известного ключа и «подписью» из подлинного токена — тоже отказ
    const real = (await jwt.signAccess(i)).token.split('.');
    const forgedHeader = base64url.encode(JSON.stringify({ alg: 'none', typ: 'JWT', kid: 'k-2026-10' }));
    await expectReject(jwt.verifyAccess(`${forgedHeader}.${real[1]}.${real[2]}`), 'alg_not_allowed');
  });

  it('T-SEC-009: HS256 с открытым ключом в роли секрета (alg confusion) → отказ', async () => {
    const i = input();
    const token = await new SignJWT({ ...i })
      .setProtectedHeader({ alg: 'HS256', typ: 'JWT', kid: 'k-2026-10' })
      .setIssuer('optomstroy-pos')
      .setAudience('optomstroy-api')
      .setSubject(i.sub)
      .setJti(randomUUID())
      .setIssuedAt()
      .setExpirationTime('10m')
      .sign(new TextEncoder().encode(k1.publicPem));
    await expectReject(jwt.verifyAccess(token), 'alg_not_allowed');
    // Заголовок EdDSA, подпись HMAC — отказ подписи
    const [h, p] = (await jwt.signAccess(i)).token.split('.');
    const mac = createHmac('sha256', k1.publicPem).update(`${h}.${p}`).digest('base64url');
    await expectReject(jwt.verifyAccess(`${h}.${p}.${mac}`), 'signature');
  });

  it('T-SEC-009: чужая подпись (другой ключ с тем же kid) → signature; изменённый payload → signature', async () => {
    const foreignRing = parseJwtKeyRing({ privateKeyPem: k2.privatePem, keyId: 'k-2026-10', appEnv: 'prod' });
    const foreign = new JwtService(foreignRing, { accessTtlSeconds: 900 }, clock);
    await expectReject(jwt.verifyAccess((await foreign.signAccess(input())).token), 'signature');

    const [h, , s] = (await jwt.signAccess(input())).token.split('.');
    const tampered = base64url.encode(JSON.stringify({ ...input({ roles: ['owner'] }), jti: randomUUID() }));
    await expectReject(jwt.verifyAccess(`${h}.${tampered}.${s}`), 'signature');
  });

  it('истёкший токен → expired (FixedClock); допуск часов 5 с', async () => {
    const issued = await jwt.signAccess(input());
    clock.advance(900_000 + 4_000);
    await expect(jwt.verifyAccess(issued.token)).resolves.toBeDefined();
    clock.advance(2_000);
    await expectReject(jwt.verifyAccess(issued.token), 'expired');
    clock.set(new Date('2026-10-22T09:00:00Z'));
  });

  it('неизвестный kid и отсутствие kid → unknown_kid; чужие iss/aud → claims', async () => {
    const keys = new TempJwtKeys();
    try {
      const noKid = await issueTestJwt(
        { role: 'seller' },
        { APP_ENV: 'dev', JWT_PRIVATE_KEY_FILE: keys.privateKeyFile },
      );
      await expectReject(jwt.verifyAccess(noKid), 'unknown_kid');
    } finally {
      keys.dispose();
    }
    const otherKid = parseJwtKeyRing({ privateKeyPem: k1.privatePem, keyId: 'k-unknown', appEnv: 'prod' });
    await expectReject(
      jwt.verifyAccess((await new JwtService(otherKid, { accessTtlSeconds: 900 }, clock).signAccess(input())).token),
      'unknown_kid',
    );
    const i = input();
    const wrongAud = await new SignJWT({ ...i })
      .setProtectedHeader({ alg: 'EdDSA', typ: 'JWT', kid: 'k-2026-10' })
      .setIssuer('optomstroy-pos')
      .setAudience('someone-else')
      .setSubject(i.sub)
      .setJti(randomUUID())
      .setIssuedAt(Math.floor(clock.now().getTime() / 1000))
      .setExpirationTime(Math.floor(clock.now().getTime() / 1000) + 600)
      .sign(ring.signing!.key);
    await expectReject(jwt.verifyAccess(wrongAud), 'claims');
  });

  it('ротация kid: после смены JWT_KEY_ID токены прежнего ключа из набора принимаются до истечения', async () => {
    const oldToken = (await jwt.signAccess(input())).token;
    const rotated = parseJwtKeyRing({
      privateKeyPem: k2.privatePem,
      publicKeys: publicSet({ 'k-2026-10': k1, 'k-2026-11': k2 }),
      keyId: 'k-2026-11',
      appEnv: 'prod',
    });
    const jwt2 = new JwtService(rotated, { accessTtlSeconds: 900 }, clock);
    await expect(jwt2.verifyAccess(oldToken)).resolves.toBeDefined();
    const fresh = await jwt2.signAccess(input());
    expect(decodeProtectedHeader(fresh.token).kid).toBe('k-2026-11');
    // старый ключ удалён из набора → токены старого kid отвергаются
    const pruned = parseJwtKeyRing({
      privateKeyPem: k2.privatePem,
      publicKeys: publicSet({ 'k-2026-11': k2 }),
      keyId: 'k-2026-11',
      appEnv: 'prod',
    });
    await expectReject(new JwtService(pruned, { accessTtlSeconds: 900 }, clock).verifyAccess(oldToken), 'unknown_kid');
  });

  it('ES256 (P-256) поддерживается; alg в заголовке должен совпадать с типом ключа kid', async () => {
    const p = pemPair('p256');
    const r = parseJwtKeyRing({ privateKeyPem: p.privatePem, keyId: 'ec-1', appEnv: 'prod' });
    const svc = new JwtService(r, { accessTtlSeconds: 900 }, clock);
    const t = await svc.signAccess(input());
    expect(decodeProtectedHeader(t.token).alg).toBe('ES256');
    await expect(svc.verifyAccess(t.token)).resolves.toBeDefined();
    // токен EdDSA с kid ключа ES256 → alg_not_allowed
    const confused = parseJwtKeyRing({ privateKeyPem: k1.privatePem, keyId: 'ec-1', appEnv: 'prod' });
    const edToken = await new JwtService(confused, { accessTtlSeconds: 900 }, clock).signAccess(input());
    await expectReject(svc.verifyAccess(edToken.token), 'alg_not_allowed');
  });

  it('токены назначения: step_up/registration не принимаются как access и наоборот', async () => {
    const sub = randomUUID();
    const stepUp = await jwt.signPurpose('step_up', {
      sub,
      ttlSeconds: 900,
      claims: { sid: randomUUID(), scope: 'order.cancel', method: 'pin' },
    });
    const v = await jwt.verifyPurpose(stepUp.token, 'step_up');
    expect(v).toMatchObject({ purpose: 'step_up', sub, jti: stepUp.jti });
    expect(v.claims.scope).toBe('order.cancel');
    await expectReject(jwt.verifyAccess(stepUp.token), 'wrong_token_type');
    await expectReject(jwt.verifyPurpose(stepUp.token, 'registration'), 'wrong_token_type');
    const access = await jwt.signAccess(input());
    await expectReject(jwt.verifyPurpose(access.token, 'step_up'), 'wrong_token_type');
    await expect(jwt.signPurpose('step_up', { ttlSeconds: 60, claims: { exp: 1 } })).rejects.toThrow(/зарезервирован/);
  });

  it('схема claims: неизвестная роль, нецелый permissionsVersion, kind=integration → claims; мусор → malformed', async () => {
    const sign = (payload: Record<string, unknown>) =>
      new SignJWT(payload)
        .setProtectedHeader({ alg: 'EdDSA', typ: 'JWT', kid: 'k-2026-10' })
        .setIssuer('optomstroy-pos')
        .setAudience('optomstroy-api')
        .setSubject(randomUUID())
        .setJti(randomUUID())
        .setIssuedAt(Math.floor(clock.now().getTime() / 1000))
        .setExpirationTime(Math.floor(clock.now().getTime() / 1000) + 600)
        .sign(ring.signing!.key);
    const base = { kind: 'staff', roles: ['seller'], permissionsVersion: 1, deviceId: randomUUID(), sid: randomUUID() };
    await expectReject(jwt.verifyAccess(await sign({ ...base, roles: ['superuser'] })), 'claims');
    await expectReject(jwt.verifyAccess(await sign({ ...base, permissionsVersion: 1.5 })), 'claims');
    await expectReject(jwt.verifyAccess(await sign({ ...base, kind: 'integration' })), 'claims');
    await expectReject(jwt.verifyAccess('not-a-jwt'), 'malformed');
    await expectReject(jwt.verifyAccess(`${'a'.repeat(9000)}.b.c`), 'malformed');
  });

  it('конфигурация ключей: prod без ключей, несовпадение пары, нет текущего kid, RSA → ошибка старта; dev → эфемерный', () => {
    expect(() => parseJwtKeyRing({ appEnv: 'prod' })).toThrow(JwtKeyConfigError);
    expect(() => parseJwtKeyRing({ appEnv: 'staging' })).toThrow(/обязательны при APP_ENV=staging/);
    expect(() =>
      parseJwtKeyRing({ privateKeyPem: k1.privatePem, publicKeys: publicSet({ a: k2 }), keyId: 'a', appEnv: 'prod' }),
    ).toThrow(/не соответствует/);
    expect(() =>
      parseJwtKeyRing({ privateKeyPem: k1.privatePem, publicKeys: publicSet({ a: k1 }), keyId: 'b', appEnv: 'prod' }),
    ).toThrow(/нет текущего kid/);
    expect(() => parseJwtKeyRing({ privateKeyPem: k1.privatePem, appEnv: 'prod' })).toThrow(/JWT_KEY_ID/);
    expect(() => parseJwtKeyRing({ publicKeys: 'garbage', keyId: 'x', appEnv: 'prod' })).toThrow(/открытого ключа/);
    const rsa = generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey.export({ type: 'pkcs8', format: 'pem' });
    expect(() => parseJwtKeyRing({ privateKeyPem: rsa.toString(), keyId: 'r', appEnv: 'prod' })).toThrow(/Ed25519/);
    const dev = parseJwtKeyRing({ appEnv: 'dev' });
    expect(dev.ephemeral).toBe(true);
    expect(dev.signing?.kid).toBe('dev-ephemeral');
    // только проверка (pos-worker): набор без закрытого ключа — подпись невозможна
    const verifyOnly = new JwtService(
      parseJwtKeyRing({ publicKeys: publicSet({ 'k-2026-10': k1 }), appEnv: 'prod' }),
      { accessTtlSeconds: 900 },
      clock,
    );
    return expect(verifyOnly.signAccess(input())).rejects.toThrow(/ключ подписи не настроен/);
  });

  it('совместимость: токен scripts/issue_test_jwt.ts (тот же ключ и kid) проходит verifyAccess', async () => {
    const keys = new TempJwtKeys();
    try {
      const pem = (await import('node:fs')).readFileSync(keys.privateKeyFile, 'utf8');
      const r = parseJwtKeyRing({ privateKeyPem: pem, keyId: 'dev-test-1', appEnv: 'dev' });
      const svc = new JwtService(r, { accessTtlSeconds: 900 });
      const token = await issueTestJwt(
        { role: 'cashier', permissionsVersion: 2 },
        { APP_ENV: 'dev', JWT_PRIVATE_KEY_FILE: keys.privateKeyFile, JWT_KEY_ID: 'dev-test-1' },
      );
      const c = await svc.verifyAccess(token);
      expect(c.roles).toEqual(['cashier']);
      expect(c.permissionsVersion).toBe(2);
    } finally {
      keys.dispose();
    }
  });
});
