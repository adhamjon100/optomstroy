import { Inject, Injectable, Logger } from '@nestjs/common';
import { type AuditContext, applyAuditGucs } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { AuthStateCache } from '../../common/auth/auth-state.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import type { AmrValue } from '../../common/auth/jwt.service.js';
import { generateOpaqueToken, sha256 } from '../../common/crypto/random.js';
import { DRIZZLE, type Database } from '../../common/db/database.module.js';
import { maskPhone } from '../../common/logging/redaction.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { toRbacRole } from '../../common/audit/audit-context.js';
import { DevicesRepository } from '../../users/devices.repository.js';
import { TokenDenylistRepository } from '../../users/token-denylist.repository.js';
import { UserProfilesRepository } from '../../users/user-profiles.repository.js';
import { UserRolesRepository } from '../../users/user-roles.repository.js';
import { UsersRepository } from '../../users/users.repository.js';
import type { RoleCode, SessionRow, UserRow } from '../../users/users.types.js';
import { AuthPolicyService, REGISTRATION_TOKEN_TTL_SECONDS } from '../common/auth-policy.js';
import { type OtpChallengeRow, OtpChallengesRepository } from '../otp/otp-challenges.repository.js';
import { type OtpCheck, OtpService } from '../otp/otp.service.js';
import type { EmergencyChallenge } from '../otp/emergency-challenges.repository.js';
import { AppPinsRepository } from '../pin/app-pins.repository.js';
import { PinVerifier } from '../pin/pin-verifier.service.js';
import { SessionIssuer, nextIdleExpiry, type LoginDeviceInfo } from '../sessions/session-issuer.service.js';
import { EmergencyLoginService } from './emergency-login.service.js';
import { SessionStore } from '../sessions/session-store.js';
import { biometricsPlatform, type MeDto, MeSnapshotBuilder } from './me-snapshot.js';
import { InvitationsReader } from './invitations.reader.js';
import { RegistrationTokenService } from './registration-token.service.js';

export interface VerifyInput {
  readonly challengeId: string;
  readonly code: string;
  readonly deviceKey: string;
  readonly device: LoginDeviceInfo;
  readonly ip: string | null;
  readonly userAgent: string | null;
  readonly audit: AuditContext;
}

export interface AuthenticatedBody {
  readonly status: 'authenticated' | 'pending_activation';
  readonly accessToken: string;
  readonly accessExpiresIn: number;
  readonly refreshToken: string;
  readonly refreshExpiresAt: string;
  readonly tokenType: 'Bearer';
  readonly sid: string;
  readonly user: MeDto;
  readonly biometricRefreshOffered: boolean;
  readonly roleSource?: 'invitation';
  readonly nextStep?: 'set_pin' | 'none';
}

export interface RegistrationRequiredBody {
  readonly status: 'registration_required';
  readonly registrationToken: string;
  readonly registrationExpiresIn: number;
  readonly phoneMasked: string;
}

export type VerifyBody = AuthenticatedBody | RegistrationRequiredBody;

type TxResult =
  | { readonly kind: 'error'; readonly check: Exclude<OtpCheck, { kind: 'ok' } | { kind: 'replay' }> }
  | { readonly kind: 'blocked' }
  | { readonly kind: 'body'; readonly body: VerifyBody; readonly memo: IssuedMemo };

/**
 * Выданный по челленджу токен (для отзыва при сетевом повторе verify, 09 §5.6): `jti` хранится в
 * `otp_challenges.issued_jti` (миграция 0003; DQ-03 / auth A-15, FX-11) — переживает рестарт и общий для реплик.
 */
interface IssuedMemo {
  readonly jti: string;
  readonly expiresAt: Date;
  readonly kind: 'access' | 'registration';
}

/** Запас срока строки denylist сверх расчётного `exp` токена (срок считается от `verified_at`). */
const DENY_MARGIN_MS = 60_000;

/**
 * `POST /auth/otp/verify` (RM-D-001, RM-D-017; 09 §4.3, §5.6; 08 §4.1.2; ядро §24.2): проверка кода и ветвление
 * **только после** верного кода: (1) аккаунт `active`/`pending_activation` → сессия и токены; (2) `blocked`/
 * `deleted` → 403 FORBIDDEN; (3) аккаунта нет, есть действующее приглашение → учётная запись `staff` с ролью и ФИО
 * приглашения, приглашение `accepted`, токены, `roleSource=invitation`, `nextStep=set_pin`; (4) иначе →
 * `registration_token` (регистрация клиента). Сетевой повтор того же кода ≤ 60 с — новая ротация той же сессии.
 */
@Injectable()
export class LoginService {
  private readonly logger = new Logger('auth');

  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly policy: AuthPolicyService,
    private readonly otp: OtpService,
    private readonly challenges: OtpChallengesRepository,
    private readonly users: UsersRepository,
    private readonly roles: UserRolesRepository,
    private readonly profiles: UserProfilesRepository,
    private readonly devices: DevicesRepository,
    private readonly invitations: InvitationsReader,
    private readonly issuer: SessionIssuer,
    private readonly store: SessionStore,
    private readonly regTokens: RegistrationTokenService,
    private readonly me: MeSnapshotBuilder,
    private readonly pins: PinVerifier,
    private readonly denylist: TokenDenylistRepository,
    private readonly cache: AuthStateCache,
    private readonly audit: AuditService,
    private readonly emergency: EmergencyLoginService,
    private readonly appPins: AppPinsRepository,
  ) {}

  async verify(input: VerifyInput): Promise<VerifyBody> {
    const result = await this.db.transaction(async (tx): Promise<TxResult> => {
      await applyAuditGucs(tx, { ...input.audit, system: 'auth' });
      const check = await this.otp.check(tx, {
        challengeId: input.challengeId,
        code: input.code,
        deviceKey: input.deviceKey,
        purpose: 'login_or_register',
        allowReplay: true,
      });
      if (check.kind !== 'ok' && check.kind !== 'replay') {
        await this.auditFailure(check, input, tx);
        return { kind: 'error', check };
      }
      const res =
        check.kind === 'replay'
          ? await this.replay(check.challenge, input, tx)
          : await this.branch(check.challenge, input, tx);
      if (res.kind === 'body') {
        await this.challenges.update(check.challenge.id, { issuedJti: res.memo.jti }, this.clock.now(), tx);
      }
      return res;
    });
    if (result.kind === 'error') throw OtpService.toProblem(result.check);
    if (result.kind === 'blocked') {
      throw new ProblemException('FORBIDDEN', {
        detail: 'Доступ заблокирован. Обратитесь к администратору.',
        reason: 'blocked',
      });
    }
    this.logger.log(
      { event: 'otp.verified', challengeId: input.challengeId, branch: result.body.status, deviceId: input.deviceKey },
      'otp.verified',
    );
    return result.body;
  }

  private async branch(ch: OtpChallengeRow, input: VerifyInput, tx: DbExecutor): Promise<TxResult> {
    const now = this.clock.now();
    const user = await this.users.findByPhone(ch.phoneE164, tx);
    const emergency = await this.emergency.forChallenge(ch.id, ch.smsOutboxId, tx);
    if (user && (user.status === 'blocked' || user.status === 'deleted')) {
      await this.audit.write(
        input.audit,
        {
          action: 'auth.otp.verified',
          entityType: 'otp_challenge',
          entityId: ch.id,
          result: 'denied',
          after: { purpose: ch.purpose, branch: 'blocked' },
        },
        tx,
      );
      return { kind: 'blocked' };
    }
    if (emergency) {
      // Аварийный код — только для активного сотрудника-владельца кода (09 §6.13 п. 3; 11 SEC-131): ни регистрации,
      // ни приглашения, ни входа другого аккаунта по этому номеру.
      if (!user || user.id !== emergency.userId || user.kind !== 'staff' || user.status !== 'active') {
        await this.audit.write(
          input.audit,
          {
            action: 'auth.otp.verified',
            entityType: 'otp_challenge',
            entityId: ch.id,
            result: 'denied',
            after: { purpose: ch.purpose, branch: 'emergency_target_invalid' },
          },
          tx,
        );
        return { kind: 'blocked' };
      }
      return this.login(user, ch, input, tx, { invitation: false, emergency });
    }
    if (user && (user.status === 'active' || user.status === 'pending_activation')) {
      return this.login(user, ch, input, tx, { invitation: false });
    }
    if (!user) {
      const invitation = await this.invitations.findActive(ch.phoneE164, now, tx);
      if (invitation) {
        const created = await this.users.create(
          {
            phoneE164: ch.phoneE164,
            kind: 'staff',
            status: 'active',
            phoneVerifiedAt: now,
            invitationId: invitation.id,
          },
          tx,
        );
        await this.roles.assignRole(created.id, invitation.role, invitation.invitedByUserId, tx);
        await this.profiles.create({ userId: created.id, fullName: invitation.fullName }, tx);
        await this.invitations.markAccepted(invitation.id, created.id, now, tx);
        return this.login(created, ch, input, tx, {
          invitation: true,
          invitationId: invitation.id,
          role: invitation.role,
        });
      }
    }
    // Аккаунта нет (или `pending` без завершённой регистрации), приглашения нет → регистрация клиента.
    const reg = await this.regTokens.issue(ch, input.deviceKey, tx);
    await this.audit.write(
      input.audit,
      {
        action: 'auth.otp.verified',
        entityType: 'otp_challenge',
        entityId: ch.id,
        after: { purpose: ch.purpose, branch: 'registration_required' },
      },
      tx,
    );
    return {
      kind: 'body',
      body: {
        status: 'registration_required',
        registrationToken: reg.token,
        registrationExpiresIn: reg.expiresIn,
        phoneMasked: maskPhone(ch.phoneE164),
      },
      memo: { jti: reg.jti, expiresAt: reg.expiresAt, kind: 'registration' },
    };
  }

  private async login(
    user: UserRow,
    ch: OtpChallengeRow,
    input: VerifyInput,
    tx: DbExecutor,
    origin: { invitation: boolean; invitationId?: string; role?: RoleCode; emergency?: EmergencyChallenge },
  ): Promise<TxResult> {
    const now = this.clock.now();
    // 09 §6.13 п. 3: PIN установлен и не заблокирован → второй фактор — разблокировка PIN (`unlocked_until=now()`);
    // заблокирован или сброшен — достаточно кода. Блок PIN снимается входом, как при OTP (BIO-020).
    const pinBefore = origin.emergency ? await this.appPins.find(user.id, tx) : undefined;
    const requireUnlock =
      pinBefore !== undefined && !(pinBefore.lockedUntil !== null && pinBefore.lockedUntil.getTime() > now.getTime());
    await this.pins.resetAfterOtpLogin(user.id, tx);
    if (user.phoneVerifiedAt === null) await this.users.markPhoneVerified(user.id, now, tx);
    await this.users.touchLastLogin(user.id, now, tx);
    const roles = await this.roles.activeRoleCodes(user.id, tx);
    const issued = await this.issuer.createLoginSession(
      {
        user,
        roles,
        deviceKey: input.deviceKey,
        device: input.device,
        ip: input.ip,
        userAgent: input.userAgent,
        challengeId: ch.id,
        ...(origin.emergency ? { emergency: { requireUnlock } } : {}),
      },
      tx,
    );
    for (const sid of issued.revokedSessionIds) this.cache.invalidateSession(sid);
    const body = await this.authenticatedBody(
      user,
      roles,
      issued.session,
      issued.refreshToken,
      issued.access.token,
      input,
      tx,
      origin.invitation,
    );
    const ctx: AuditContext = {
      ...input.audit,
      actorUserId: user.id,
      actorRole: toRbacRole(roles[0]),
      sessionId: issued.session.id,
    };
    await this.audit.write(
      ctx,
      {
        action: 'auth.otp.verified',
        entityType: 'otp_challenge',
        entityId: ch.id,
        after: { purpose: ch.purpose, branch: origin.invitation ? 'invitation' : body.status },
      },
      tx,
    );
    if (origin.invitation) {
      await this.audit.write(
        { ...input.audit, system: 'auth' },
        {
          action: 'user.created',
          entityType: 'user',
          entityId: user.id,
          after: {
            kind: 'staff',
            status: 'active',
            roles: [origin.role],
            roleSource: 'invitation',
            invitationId: origin.invitationId,
          },
        },
        tx,
      );
    }
    await this.audit.write(
      ctx,
      {
        action: 'auth.login',
        entityType: 'session',
        entityId: issued.session.id,
        after: {
          amr: [origin.emergency ? 'admin_code' : 'sms'],
          platform: input.device.platform,
          sessionLimitRevoked: issued.revokedSessionIds.length,
          ...(origin.emergency ? { unlockRequired: requireUnlock } : {}),
        },
      },
      tx,
    );
    if (origin.emergency) {
      // 11 §7.2.1: `auth.emergency_code.used` — sid, device_id, amr=admin_code; без кода и HMAC (SEC-078).
      await this.audit.write(
        { ...ctx, deviceId: input.deviceKey },
        {
          action: 'auth.emergency_code.used',
          entityType: 'user',
          entityId: user.id,
          severity: 'warning',
          after: {
            challengeId: ch.id,
            sid: issued.session.id,
            deviceId: input.deviceKey,
            amr: ['admin_code'],
            issuedByUserId: origin.emergency.issuedByUserId,
            unlockRequired: requireUnlock,
          },
        },
        tx,
      );
      this.logger.warn(
        { event: 'security.alert', alert: 'auth.emergency_code.used', userId: user.id, sid: issued.session.id },
        'auth.emergency_code.used',
      );
    }
    return { kind: 'body', body, memo: { jti: issued.access.jti, expiresAt: issued.access.expiresAt, kind: 'access' } };
  }

  /**
   * Сетевой повтор verify (09 §5.6; RM-D-001 п. 4; 12 T-AUTH-005): тот же код, тот же `X-Device-Id`, ≤ 60 с после
   * потребления, повтора ещё не было, сессия челленджа не отозвана и не использовалась → новая ротация той же
   * сессии (тот же `sid`/`family_id`), прежний refresh вытесняется, прежний access — в denylist; для ветки
   * регистрации — новый `registration_token`. Иначе → OTP_EXPIRED.
   */
  private async replay(ch: OtpChallengeRow, input: VerifyInput, tx: DbExecutor): Promise<TxResult> {
    const now = this.clock.now();
    const expired: TxResult = { kind: 'error', check: { kind: 'expired' } };
    const created = await this.store.findCreatedFromChallenge(ch.id, tx);
    if (created.length === 1) {
      const s = created[0];
      // «Ещё ни разу не использовалась»: не было ни refresh (`rotated_at`), ни запросов с access (`last_used_at`).
      if (
        s.revokedAt !== null ||
        s.rotatedAt !== null ||
        s.lastUsedAt !== null ||
        s.expiresAt.getTime() <= now.getTime()
      ) {
        return expired;
      }
      const user = await this.users.findById(s.userId, tx);
      if (!user || (user.status !== 'active' && user.status !== 'pending_activation')) return expired;
      const p = (await this.policy.effective()).session;
      const refreshToken = generateOpaqueToken();
      const rotated = await this.store.rotateAside(
        s.id,
        { newRefreshHash: sha256(refreshToken), now, idleExpiresAt: nextIdleExpiry(s, user.kind, p, now) },
        tx,
      );
      if (!rotated) return expired;
      // Повторный повтор отсекает replayed_at (09 §5.6: ротация по повтору — однократно).
      await this.challenges.update(ch.id, { replayedAt: now }, now, tx);
      await this.deny(this.priorIssued(ch, 'access'), s.id, tx);
      const roles = await this.roles.activeRoleCodes(user.id, tx);
      const amr = [...s.amr] as AmrValue[];
      const access = await this.issuer.access(user, roles, rotated, input.deviceKey, amr);
      const fromInvitation = user.invitationId !== null && user.createdAt.getTime() >= ch.createdAt.getTime();
      const body = await this.authenticatedBody(
        user,
        roles,
        rotated,
        refreshToken,
        access.token,
        input,
        tx,
        fromInvitation,
      );
      await this.audit.write(
        { ...input.audit, actorUserId: user.id, actorRole: toRbacRole(roles[0]), sessionId: s.id },
        { action: 'auth.login', entityType: 'session', entityId: s.id, after: { amr, replay: true } },
        tx,
      );
      return { kind: 'body', body, memo: { jti: access.jti, expiresAt: access.expiresAt, kind: 'access' } };
    }
    if (created.length === 0 && ch.registrationTokenHash !== null) {
      const user = await this.users.findByPhone(ch.phoneE164, tx);
      if (user) return expired; // регистрация уже завершена этим токеном
      await this.challenges.update(ch.id, { replayedAt: now }, now, tx);
      await this.deny(this.priorIssued(ch, 'registration'), null, tx);
      const reg = await this.regTokens.issue(ch, input.deviceKey, tx);
      await this.audit.write(
        input.audit,
        {
          action: 'auth.otp.verified',
          entityType: 'otp_challenge',
          entityId: ch.id,
          after: { purpose: ch.purpose, branch: 'registration_required', replay: true },
        },
        tx,
      );
      return {
        kind: 'body',
        body: {
          status: 'registration_required',
          registrationToken: reg.token,
          registrationExpiresIn: reg.expiresIn,
          phoneMasked: maskPhone(ch.phoneE164),
        },
        memo: { jti: reg.jti, expiresAt: reg.expiresAt, kind: 'registration' },
      };
    }
    return expired;
  }

  private async authenticatedBody(
    user: UserRow,
    roles: readonly RoleCode[],
    session: SessionRow,
    refreshToken: string,
    accessToken: string,
    input: VerifyInput,
    tx: DbExecutor,
    fromInvitation: boolean,
  ): Promise<AuthenticatedBody> {
    const device = await this.devices.findById(session.deviceId, tx);
    const me = await this.me.build(
      user,
      roles,
      {
        session,
        ...(device ? { device } : {}),
        deviceKey: input.deviceKey,
        amr: ['sms'],
        biometricClass: input.device.biometricClass,
      },
      tx,
    );
    const pending = user.status === 'pending_activation';
    const pinMissingStaff = user.kind === 'staff' && !me.security.pinSet;
    const platform = biometricsPlatform(input.device.platform, input.device.biometricClass);
    return {
      status: pending ? 'pending_activation' : 'authenticated',
      accessToken,
      accessExpiresIn: this.issuer.accessTtlSeconds,
      refreshToken,
      refreshExpiresAt: session.expiresAt.toISOString(),
      tokenType: 'Bearer',
      sid: session.id,
      user: me,
      biometricRefreshOffered: !pending && !pinMissingStaff && (platform === 'android_class3' || platform === 'ios'),
      ...(pending ? {} : { nextStep: pinMissingStaff ? ('set_pin' as const) : ('none' as const) }),
      ...(fromInvitation && !pending ? { roleSource: 'invitation' as const } : {}),
    };
  }

  /** Токен, выданный при потреблении челленджа (`issued_jti`; срок — от `verified_at`). */
  private priorIssued(ch: OtpChallengeRow, kind: IssuedMemo['kind']): IssuedMemo | undefined {
    if (ch.issuedJti === null || ch.verifiedAt === null) return undefined;
    const ttlSec = kind === 'access' ? this.issuer.accessTtlSeconds : REGISTRATION_TOKEN_TTL_SECONDS;
    return { jti: ch.issuedJti, kind, expiresAt: new Date(ch.verifiedAt.getTime() + ttlSec * 1000 + DENY_MARGIN_MS) };
  }

  private async deny(prior: IssuedMemo | undefined, sessionId: string | null, tx: DbExecutor): Promise<void> {
    if (!prior || prior.expiresAt.getTime() <= this.clock.now().getTime()) return;
    await this.denylist.add(
      { jti: prior.jti, tokenKind: prior.kind, expiresAt: prior.expiresAt, reason: 'revoked', sessionId },
      tx,
    );
    this.cache.denyJti(prior.jti, prior.expiresAt);
  }

  private async auditFailure(
    check: Exclude<OtpCheck, { kind: 'ok' } | { kind: 'replay' }>,
    input: VerifyInput,
    tx: DbExecutor,
  ): Promise<void> {
    if (check.kind === 'not_found') return;
    const locked = (check.kind === 'invalid' && check.lockedNow) || check.kind === 'locked';
    this.logger.warn(
      { event: locked ? 'otp.locked' : `otp.${check.kind}`, challengeId: input.challengeId, deviceId: input.deviceKey },
      'otp.verify_failed',
    );
    if (check.kind === 'locked') return; // уже заблокирован ранее — событие записано при блокировке
    await this.audit.write(
      input.audit,
      {
        action: locked ? 'auth.otp.locked' : 'auth.otp.failed',
        entityType: 'otp_challenge',
        entityId: input.challengeId,
        result: 'denied',
        severity: locked ? 'warning' : 'info',
        after: { reason: check.kind, ...(check.kind === 'invalid' ? { attemptsLeft: check.attemptsLeft } : {}) },
      },
      tx,
    );
  }
}
