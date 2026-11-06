import { randomUUID } from 'node:crypto';
import { type ExecutionContext, Logger } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { SignJWT } from 'jose';
import { expectTypeOf } from 'vitest';
import { userKindEnum } from '../../db/schema/enums.js';
import { PgAuthStateReader } from '../../users/auth-state.reader.js';
import type { UserRow } from '../../users/users.types.js';
import type { DbExecutor } from '../audit/db-executor.js';
import { USER_KIND_VALUES } from '../enums.js';
import type { Principal } from '../http/request-context.js';
import type { SalesActor } from '../ports/sales-context.js';
import { ProblemException } from '../problem-details/problem.exception.js';
import { PermissionCatalog } from '../rbac/permission-catalog.js';
import { AuthGuard } from './auth.guard.js';
import { type AuthSnapshot, AuthStateCache, type AuthStateReader, type AuthUserState } from './auth-state.js';
import { FixedClock } from './clock.js';
import { JWT_AUDIENCE, JWT_ISSUER, JwtService, JwtVerificationError, type TokenKind } from './jwt.service.js';
import { parseJwtKeyRing } from './jwt-keys.js';
import type { AuthenticatedPrincipal } from './principal.js';
import {
  assertNeverSubjectKind,
  bySubjectKind,
  isBuyerLike,
  isSelfServiceCustomer,
  isSubjectKind,
  SUBJECT_KINDS,
  type SubjectKind,
  switchSubjectKind,
  toSubjectKind,
  UnknownSubjectKindError,
} from './subject-kind.js';

/**
 * 06 ARCH-065 (AC-ARCH-065 (1)), ADR-115 п. 2, 11 SEC-137 (6): классификация субъекта `staff | customer | kiosk` с
 * отказом по умолчанию; вид `kiosk` проходит access-JWT, снимок AuthGuard и `Principal` (08 §2.2, 09 §8.1).
 */
const UNKNOWN: readonly unknown[] = [
  'integration',
  'Kiosk',
  'KIOSK',
  '',
  ' kiosk',
  'admin',
  null,
  undefined,
  1,
  {},
  ['kiosk'],
];

describe('SubjectKind: исчерпывающая классификация с отказом по умолчанию (06 ARCH-065)', () => {
  it('перечень видов = users.kind: contracts/enums.json (USER_KIND_VALUES) и enum БД user_kind (Drizzle)', () => {
    expect([...SUBJECT_KINDS]).toEqual(['staff', 'customer', 'kiosk']);
    expect([...SUBJECT_KINDS]).toEqual([...USER_KIND_VALUES]);
    expect([...SUBJECT_KINDS]).toEqual([...userKindEnum.enumValues]);
  });

  it('типы вида субъекта совпадают с SubjectKind (claim, Principal, снимок AuthGuard, SalesActor, строка users)', () => {
    expectTypeOf<TokenKind>().toEqualTypeOf<SubjectKind>();
    expectTypeOf<AuthenticatedPrincipal['kind']>().toEqualTypeOf<SubjectKind>();
    expectTypeOf<Principal['kind']>().toEqualTypeOf<SubjectKind | 'integration'>();
    expectTypeOf<AuthUserState['kind']>().toEqualTypeOf<SubjectKind>();
    expectTypeOf<NonNullable<SalesActor['subjectKind']>>().toEqualTypeOf<SubjectKind>();
    expectTypeOf<UserRow['kind']>().toEqualTypeOf<SubjectKind>();
    expectTypeOf<(typeof USER_KIND_VALUES)[number]>().toEqualTypeOf<SubjectKind>();
  });

  it('toSubjectKind / isSubjectKind: три вида — как есть', () => {
    for (const k of SUBJECT_KINDS) {
      expect(isSubjectKind(k)).toBe(true);
      expect(toSubjectKind(k)).toBe(k);
    }
  });

  it.each(UNKNOWN.map((v) => [JSON.stringify(v) ?? String(v), v]))(
    'AC-ARCH-065 (1): неизвестный вид %s → исключение UnknownSubjectKindError, доступа нет',
    (_label, value) => {
      expect(isSubjectKind(value)).toBe(false);
      expect(() => toSubjectKind(value)).toThrow(UnknownSubjectKindError);
      const kind = value as SubjectKind;
      const branch = vi.fn(() => true);
      expect(() => switchSubjectKind(kind, { staff: branch, customer: branch, kiosk: branch })).toThrow(
        UnknownSubjectKindError,
      );
      expect(branch).not.toHaveBeenCalled();
      expect(() => bySubjectKind(kind, { staff: 1, customer: 2, kiosk: 3 })).toThrow(UnknownSubjectKindError);
      expect(() => isBuyerLike(kind)).toThrow(UnknownSubjectKindError);
      expect(() => isSelfServiceCustomer(kind)).toThrow(UnknownSubjectKindError);
      expect(() => assertNeverSubjectKind(kind as never)).toThrow(UnknownSubjectKindError);
    },
  );

  it('сообщение отказа не содержит значение произвольного формата (11 SEC-062)', () => {
    const phone = '+996555000111';
    expect(() => toSubjectKind(phone)).toThrow(/строка вне формата/);
    try {
      toSubjectKind(phone);
    } catch (e) {
      expect((e as Error).message).not.toContain('555000111');
    }
    expect(() => toSubjectKind('robot')).toThrow(/«robot»/);
  });

  it('switchSubjectKind вызывает ровно одну ветку своего вида; bySubjectKind — значение из полной таблицы', () => {
    for (const k of SUBJECT_KINDS) {
      const calls: string[] = [];
      const result = switchSubjectKind(k, {
        staff: () => (calls.push('staff'), 'S'),
        customer: () => (calls.push('customer'), 'C'),
        kiosk: () => (calls.push('kiosk'), 'K'),
      });
      expect(calls).toEqual([k]);
      expect(result).toBe({ staff: 'S', customer: 'C', kiosk: 'K' }[k]);
      expect(bySubjectKind(k, { staff: 3, customer: 5, kiosk: 1 })).toBe({ staff: 3, customer: 5, kiosk: 1 }[k]);
    }
  });

  it('isBuyerLike: customer и kiosk; isSelfServiceCustomer: только customer (планшет — не режим клиента, ARCH-067)', () => {
    expect(SUBJECT_KINDS.map((k) => [k, isBuyerLike(k), isSelfServiceCustomer(k)])).toEqual([
      ['staff', false, false],
      ['customer', true, true],
      ['kiosk', true, false],
    ]);
  });
});

describe('Вид kiosk в access-JWT и AuthGuard (08 §2.2; 09 §8.1; ADR-115)', () => {
  const ring = parseJwtKeyRing({ appEnv: 'dev' });
  const clock = new FixedClock(new Date());
  const jwt = new JwtService(ring, { accessTtlSeconds: 900 }, clock);
  const userId = randomUUID();
  const sessionId = randomUUID();
  const deviceId = randomUUID();

  class FakeReader implements AuthStateReader {
    constructor(private readonly user: AuthUserState | null) {}
    snapshot(): Promise<AuthSnapshot> {
      return Promise.resolve({
        user: this.user,
        session: {
          userId,
          revokedAt: null,
          expiresAt: new Date(clock.now().getTime() + 3_600_000),
          deviceKey: deviceId,
        },
        jtiDenied: false,
      });
    }
  }

  function guardWith(user: AuthUserState | null): AuthGuard {
    return new AuthGuard(new Reflector(), jwt, new AuthStateCache(new FakeReader(user), clock), clock);
  }

  class ProbeController {}
  function httpContext(req: object): ExecutionContext {
    const handler = (): undefined => undefined;
    return {
      getType: () => 'http',
      getHandler: () => handler,
      getClass: () => ProbeController,
      switchToHttp: () => ({ getRequest: () => req }),
    } as unknown as ExecutionContext;
  }

  async function token(kind: TokenKind, roles: string[]): Promise<string> {
    return (await jwt.signAccess({ sub: userId, kind, roles, permissionsVersion: 1, deviceId, sid: sessionId })).token;
  }

  it('access-JWT kind=kiosk, роль kiosk: подпись и проверка без потерь', async () => {
    const claims = await jwt.verifyAccess(await token('kiosk', ['kiosk']));
    expect(claims.kind).toBe('kiosk');
    expect(claims.roles).toEqual(['kiosk']);
  });

  it('kind вне SubjectKind: подпись отклоняется, чужой токен с kind=integration → JwtVerificationError claims', async () => {
    await expect(token('integration' as TokenKind, ['integration'])).rejects.toThrow();
    const signing = ring.signing!;
    const iat = Math.floor(clock.now().getTime() / 1000);
    const forged = await new SignJWT({
      kind: 'integration',
      roles: ['integration'],
      permissionsVersion: 1,
      deviceId,
      sid: sessionId,
      amr: ['sms'],
    })
      .setProtectedHeader({ alg: signing.alg, typ: 'JWT', kid: signing.kid })
      .setIssuer(JWT_ISSUER)
      .setAudience(JWT_AUDIENCE)
      .setSubject(userId)
      .setJti(randomUUID())
      .setIssuedAt(iat)
      .setExpirationTime(iat + 900)
      .sign(signing.key);
    await expect(jwt.verifyAccess(forged)).rejects.toThrow(new JwtVerificationError('claims'));
  });

  it('AuthGuard принимает токен планшета: principal.kind=kiosk; коды kiosk.* засчитываются по виду (SEC-138)', async () => {
    const req: { headers: Record<string, string>; principal?: Principal } = {
      headers: { authorization: `Bearer ${await token('kiosk', ['kiosk'])}`, 'x-device-id': deviceId },
    };
    await expect(
      guardWith({ status: 'active', kind: 'kiosk', permissionsVersion: 1 }).canActivate(httpContext(req)),
    ).resolves.toBe(true);
    const p = req.principal as AuthenticatedPrincipal;
    expect(p).toMatchObject({ userId, kind: 'kiosk', roles: ['kiosk'], status: 'active', sessionId, deviceId });
    const granted = new PermissionCatalog().effectivePermissions(p);
    expect(['kiosk.order.submit', 'kiosk.self.read', 'kiosk.self.exit'].every((c) => granted.has(c as never))).toBe(
      true,
    );
  });

  it.each([
    ['kiosk', 'customer'],
    ['customer', 'kiosk'],
    ['staff', 'kiosk'],
  ] as const)('claim kind=%s, users.kind=%s → 401 UNAUTHENTICATED (вид сверяется с БД)', async (claim, dbKind) => {
    const bearer = await token(claim, []);
    const req = { headers: { authorization: `Bearer ${bearer}`, 'x-device-id': deviceId } };
    const warn = vi.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);
    try {
      const err = await guardWith({ status: 'active', kind: dbKind, permissionsVersion: 1 })
        .canActivate(httpContext(req))
        .catch((e: unknown) => e);
      expect(err).toBeInstanceOf(ProblemException);
      expect((err as ProblemException).code).toBe('UNAUTHENTICATED');
      // журнал отказа — причина без токена и claims (11 SEC-062)
      expect(warn).toHaveBeenCalledWith(
        expect.objectContaining({ event: 'auth.rejected', reason: 'user_unknown' }),
        'auth.rejected',
      );
      expect(JSON.stringify(warn.mock.calls)).not.toContain(bearer);
    } finally {
      warn.mockRestore();
    }
  });
});

describe('PgAuthStateReader: вид пользователя через классификатор (отказ по умолчанию)', () => {
  const row = (user_kind: string | null) => ({
    user_status: 'active',
    user_kind,
    permissions_version: 1,
    session_user_id: randomUUID(),
    session_revoked_at: null,
    session_expires_at: new Date(),
    device_key: randomUUID(),
    jti_denied: false,
  });
  const readerFor = (r: ReturnType<typeof row>) =>
    new PgAuthStateReader({ execute: () => Promise.resolve({ rows: [r] }) } as unknown as DbExecutor);
  const q = { userId: randomUUID(), sessionId: randomUUID(), jti: randomUUID() };

  it.each(SUBJECT_KINDS)('users.kind=%s → снимок пользователя с этим видом', async (kind) => {
    const snap = await readerFor(row(kind)).snapshot(q);
    expect(snap.user).toEqual({ status: 'active', kind, permissionsVersion: 1 });
  });

  it.each(['integration', 'robot', null])(
    'users.kind=%s → пользователь не распознан (AuthGuard: 401)',
    async (kind) => {
      const snap = await readerFor(row(kind)).snapshot(q);
      expect(snap.user).toBeNull();
      expect(snap.session).not.toBeNull();
    },
  );
});
