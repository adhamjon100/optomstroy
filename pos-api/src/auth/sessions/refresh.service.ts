import { Inject, Injectable, Logger } from '@nestjs/common';
import { type AuditContext, applyAuditGucs, toRbacRole } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { AuthStateCache } from '../../common/auth/auth-state.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import type { AmrValue } from '../../common/auth/jwt.service.js';
import { generateOpaqueToken, sha256 } from '../../common/crypto/random.js';
import { DRIZZLE, type Database } from '../../common/db/database.module.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { DevicesRepository } from '../../users/devices.repository.js';
import { SessionsRepository } from '../../users/sessions.repository.js';
import { UserProfilesRepository } from '../../users/user-profiles.repository.js';
import { UserRolesRepository } from '../../users/user-roles.repository.js';
import { UsersRepository } from '../../users/users.repository.js';
import type { DeviceRow, SessionRevokeReason, SessionRow, UserRow } from '../../users/users.types.js';
import { AuthPolicyService, type SessionPolicy } from '../common/auth-policy.js';
import { AppPinsRepository } from '../pin/app-pins.repository.js';
import { type PinCheck, PinVerifier } from '../pin/pin-verifier.service.js';
import { AuthHttpRateLimiter } from '../common/http-rate-limits.js';
import { contractAmr, firstFactor, nextIdleExpiry, SessionIssuer } from './session-issuer.service.js';
import { SessionStore } from './session-store.js';

export type RotationMode = 'refresh' | 'unlock_pin' | 'unlock_biometric';

export interface RotateInput {
  readonly refreshToken: string;
  readonly deviceKey: string;
  readonly mode: RotationMode;
  readonly pin?: string;
  readonly biometricInvalidated?: boolean;
  readonly ip: string | null;
  readonly audit: AuditContext;
}

export interface TokenPairBody {
  readonly accessToken: string;
  readonly accessExpiresIn: number;
  readonly refreshToken: string;
  readonly refreshExpiresAt: string;
  readonly sid: string;
  readonly permissionsVersion: number;
  readonly amr?: readonly AmrValue[];
}

/** Как найден предъявленный refresh (09 §8.3). */
type Path = 'current' | 'grace' | 'replay' | 'reuse';

type Failure =
  | { readonly kind: 'revoked'; readonly reason?: string }
  | { readonly kind: 'unlock_required'; readonly reason?: string }
  | { readonly kind: 'validation'; readonly rule: string; readonly field: string; readonly message: string }
  | { readonly kind: 'pin'; readonly check: Exclude<PinCheck, { kind: 'ok' }> };

type TxResult = { readonly ok: true; readonly body: TokenPairBody } | { readonly ok: false; readonly failure: Failure };

/**
 * Ротация refresh (RM-D-003; 09 §8.3, §8.8; 08 §4.1.3, §4.1.8; RFC 9700 §4.14.2) для `/auth/refresh` и
 * `/auth/unlock`: CAS-ротация; окно грации 30 с (однократно, пока текущий токен не использовался); поздний повтор
 * (`refresh_replay`) — без отзыва семьи: `UNLOCK_REQUIRED` при наличии PIN (разблокировка PIN выдаёт новую
 * ротацию), иначе отзыв только этой сессии; повторное использование (`reuse_detected`) — отзыв всей семьи и аудит;
 * чужой `X-Device-Id` — отзыв сессии (`device_mismatch`); staff на Windows без `unlocked_until > now` →
 * `UNLOCK_REQUIRED` (D-48). Ошибки бросаются после COMMIT (отзыв и счётчики PIN сохраняются).
 */
@Injectable()
export class RefreshService {
  private readonly logger = new Logger('auth');

  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly policy: AuthPolicyService,
    private readonly sessions: SessionsRepository,
    private readonly store: SessionStore,
    private readonly users: UsersRepository,
    private readonly roles: UserRolesRepository,
    private readonly devices: DevicesRepository,
    private readonly profiles: UserProfilesRepository,
    private readonly pins: AppPinsRepository,
    private readonly pinVerifier: PinVerifier,
    private readonly issuer: SessionIssuer,
    private readonly cache: AuthStateCache,
    private readonly audit: AuditService,
    private readonly limiter: AuthHttpRateLimiter,
  ) {}

  async rotate(input: RotateInput): Promise<TokenPairBody> {
    const result = await this.db.transaction(async (tx): Promise<TxResult> => {
      await applyAuditGucs(tx, { ...input.audit, system: 'auth' });
      return this.rotateInTx(input, tx);
    });
    if (result.ok) return result.body;
    throw toProblem(result.failure);
  }

  private async rotateInTx(input: RotateInput, tx: DbExecutor): Promise<TxResult> {
    const p = (await this.policy.effective()).session;
    const now = this.clock.now();
    const hash = sha256(input.refreshToken);
    let path: Path = 'current';
    let s = await this.sessions.findByRefreshHash(hash, tx, true);
    if (!s) {
      s = await this.store.findByPrevHashForUpdate(hash, tx);
      if (s) path = this.classifyPrevious(s, p, now);
      else {
        s = await this.store.findBySupersededHashForUpdate(hash, tx);
        if (s) path = 'reuse';
      }
    }
    if (!s) return fail({ kind: 'revoked' });
    if (s.revokedAt !== null) return fail({ kind: 'revoked' });

    const user = await this.users.findById(s.userId, tx);
    const device = await this.devices.findById(s.deviceId, tx);
    if (!user || !device) return fail({ kind: 'revoked' });
    const ctx: AuditContext = { ...input.audit, actorUserId: user.id, sessionId: s.id };

    if (s.expiresAt.getTime() <= now.getTime() || s.idleExpiresAt.getTime() <= now.getTime()) {
      await this.revoke(s, 'expired', ctx, tx, false);
      return fail({ kind: 'revoked', reason: 'expired' });
    }
    if (device.deviceKey !== input.deviceKey) {
      await this.revoke(s, 'device_mismatch', ctx, tx, true);
      return fail({ kind: 'revoked', reason: 'device_mismatch' });
    }
    if (user.status !== 'active' && user.status !== 'pending_activation') {
      return fail({ kind: 'revoked', reason: 'blocked' });
    }
    if (path === 'reuse') {
      const ids = await this.sessions.revokeFamily(s.familyId, 'reuse_detected', tx);
      for (const id of ids) this.cache.invalidateSession(id);
      this.logger.warn({ event: 'auth.refresh.reuse_detected', sid: s.id, familyId: s.familyId }, 'reuse_detected');
      await this.audit.write(
        ctx,
        {
          action: 'session.reuse_detected',
          entityType: 'session',
          entityId: s.id,
          result: 'denied',
          severity: 'critical',
          after: { familyId: s.familyId, revokedSessions: ids.length, mode: input.mode },
        },
        tx,
      );
      return fail({ kind: 'revoked', reason: 'reuse_detected' });
    }

    // Вид токена ↔ эндпоинт (08 §4.1.3, §4.1.8; ядро §19.3).
    if (input.mode === 'refresh' && s.kind === 'biometric') {
      return fail({
        kind: 'validation',
        rule: 'use_unlock',
        field: 'refreshToken',
        message: 'Используйте POST /auth/unlock',
      });
    }
    if (input.mode === 'unlock_biometric' && (s.kind !== 'biometric' || device.platform === 'windows')) {
      return fail({
        kind: 'validation',
        rule: 'method',
        field: 'method',
        message: 'Биометрическая разблокировка недоступна',
      });
    }

    const pinSet = await this.pins.exists(user.id, tx);
    if (path === 'replay' && input.mode !== 'unlock_pin') {
      this.logger.warn({ event: 'auth.refresh.replay', sid: s.id, mode: input.mode }, 'auth.refresh.replay');
      if (input.mode === 'refresh' && pinSet && s.kind === 'standard') {
        return fail({ kind: 'unlock_required', reason: 'refresh_replay' });
      }
      // Без PIN (customer) или биометрическая семья: отзыв только этой сессии, без алерта (09 §8.3);
      // `revoke_reason = refresh_replay` — миграция 0003 (09 §17 п. 19(а); DQ-03 / auth A-08).
      await this.revoke(s, 'refresh_replay', ctx, tx, false);
      return fail({ kind: 'revoked', reason: 'refresh_replay' });
    }

    const windowsStaff = user.kind === 'staff' && device.platform === 'windows';
    if (
      input.mode === 'refresh' &&
      windowsStaff &&
      (s.unlockedUntil === null || s.unlockedUntil.getTime() <= now.getTime())
    ) {
      return fail({ kind: 'unlock_required', reason: 'idle_lock' });
    }

    // Первый фактор — из `sessions.amr` (`admin_code` у входа по аварийному коду, 09 §6.13 п. 3; миграция 0003).
    let stored = [...s.amr] as AmrValue[];
    if (input.mode === 'unlock_pin') {
      if (input.pin === undefined) {
        return fail({ kind: 'validation', rule: 'required', field: 'pin', message: 'PIN обязателен' });
      }
      // RL-PIN (08 §2.9): 30 попыток / 10 мин на `userId + deviceId` — тот же ключ, что у step-up по PIN.
      await this.limiter.pin(user.id, input.deviceKey);
      const check = await this.pinVerifier.verify(user.id, input.pin, tx);
      if (check.kind !== 'ok') {
        await this.audit.write(
          ctx,
          {
            action: check.kind === 'locked_now' ? 'auth.pin.locked' : 'auth.unlock',
            entityType: 'session',
            entityId: s.id,
            result: 'denied',
            ...(check.kind === 'locked_now' ? { severity: 'warning' as const } : {}),
            after: { method: 'pin', reason: check.kind },
          },
          tx,
        );
        return fail({ kind: 'pin', check });
      }
      stored = [firstFactor(stored), 'pin'];
      if (input.biometricInvalidated === true) await this.invalidateBiometrics(user, device, ctx, tx);
    } else if (input.mode === 'unlock_biometric') {
      stored = [firstFactor(stored), 'bio'];
    }
    const amr = stored;

    const refreshToken = generateOpaqueToken();
    const unlock = input.mode !== 'refresh';
    const patch = {
      newRefreshHash: sha256(refreshToken),
      now,
      idleExpiresAt: nextIdleExpiry(s, user.kind, p, now),
      ...(unlock ? { unlockedUntil: new Date(now.getTime() + p.idleLockMinutes * 60_000) } : {}),
      ...(unlock ? { amr: stored } : {}),
      ip: input.ip,
    };
    const rotated =
      path === 'current'
        ? await this.store.rotate(s.id, hash, patch, tx)
        : await this.store.rotateAside(s.id, patch, tx);
    if (!rotated) return fail({ kind: 'revoked' });
    if (input.mode === 'refresh' && windowsStaff) {
      // 09 §8.8: активность продлевает разблокировку — успешный refresh в пределах unlocked_until тоже.
      await this.store.touchActivity(rotated.id, now, p.idleLockMinutes, input.ip, tx);
    }
    const roles = await this.roles.activeRoleCodes(user.id, tx);
    const access = await this.issuer.access(user, roles, rotated, input.deviceKey, amr);
    if (unlock) {
      await this.audit.write(
        { ...ctx, actorRole: toRbacRole(roles[0]) },
        {
          action: 'auth.unlock',
          entityType: 'session',
          entityId: s.id,
          after: { method: input.mode === 'unlock_pin' ? 'pin' : 'biometric', path },
        },
        tx,
      );
    } else {
      this.logger.log({ event: 'auth.refresh', sid: s.id, path }, 'auth.refresh');
    }
    return {
      ok: true,
      body: {
        accessToken: access.token,
        accessExpiresIn: this.issuer.accessTtlSeconds,
        refreshToken,
        refreshExpiresAt: rotated.expiresAt.toISOString(),
        sid: rotated.id,
        permissionsVersion: user.permissionsVersion,
        // Схема ответа (contracts/openapi AuthTokenPair.amr): только sms|bio|pin — `admin_code` не выводится.
        ...(unlock ? { amr: contractAmr(amr) } : {}),
      },
    };
  }

  /**
   * Предъявлен предыдущий токен (`prev_refresh_hash`): «использовался ли текущий» — `last_used_at IS NOT NULL`
   * (ротация обнуляет отметку; её ставит запрос с access, выданным при ротации). Не использовался: в окне грации и грация не тратилась →
   * `grace`; вне окна → `replay` (09 §8.3 «refresh_replay»); иначе (использовался или грация уже потрачена,
   * 12 T-SESS-006) → `reuse`.
   */
  private classifyPrevious(s: SessionRow, p: SessionPolicy, now: Date): Path {
    const rotatedAt = s.rotatedAt?.getTime() ?? 0;
    // После ротации `last_used_at = NULL`; не NULL — текущий токен уже использован (refresh или access).
    const used = s.lastUsedAt !== null;
    if (used || s.graceUsedAt !== null) return 'reuse';
    return now.getTime() - rotatedAt <= p.graceSeconds * 1000 ? 'grace' : 'replay';
  }

  private async revoke(
    s: SessionRow,
    reason: SessionRevokeReason,
    ctx: AuditContext,
    tx: DbExecutor,
    auditIt: boolean,
  ): Promise<void> {
    if (await this.sessions.revoke(s.id, reason, tx)) {
      this.cache.invalidateSession(s.id);
      if (auditIt) {
        await this.audit.write(
          ctx,
          { action: 'session.revoked', entityType: 'session', entityId: s.id, result: 'denied', after: { reason } },
          tx,
        );
      }
    }
  }

  /** `biometricInvalidated=true` (08 §4.1.8; ядро §18.2 п. 8, §21 п. 2(в)): отзыв биометрической семьи устройства. */
  private async invalidateBiometrics(
    user: UserRow,
    device: DeviceRow,
    ctx: AuditContext,
    tx: DbExecutor,
  ): Promise<void> {
    const ids = await this.sessions.revokeAllForUser(
      user.id,
      'biometric_invalidated',
      { kind: 'biometric', deviceId: device.id },
      tx,
    );
    for (const id of ids) this.cache.invalidateSession(id);
    await this.devices.setBiometricEnrolled(device.id, null, tx);
    const others = await this.store.listActiveWithDevices(user.id, this.clock.now(), tx);
    if (!others.some((r) => r.session.kind === 'biometric'))
      await this.profiles.setBiometricsEnabled(user.id, false, tx);
    await this.audit.write(
      ctx,
      {
        action: 'auth.biometrics.disabled',
        entityType: 'device',
        entityId: device.id,
        after: { reason: 'biometric_invalidated', revokedSessions: ids.length },
      },
      tx,
    );
  }
}

function fail(failure: Failure): TxResult {
  return { ok: false, failure };
}

function toProblem(f: Failure): ProblemException {
  switch (f.kind) {
    case 'revoked':
      return new ProblemException('SESSION_REVOKED', {
        detail:
          f.reason === 'reuse_detected'
            ? 'Для безопасности мы завершили все сессии. Войдите снова.'
            : 'Сессия завершена. Войдите снова.',
        ...(f.reason ? { reason: f.reason } : {}),
      });
    case 'unlock_required':
      return new ProblemException('UNLOCK_REQUIRED', {
        detail: 'Разблокируйте приложение PIN-кодом.',
        ...(f.reason ? { reason: f.reason } : {}),
      });
    case 'validation':
      return new ProblemException('VALIDATION_FAILED', {
        status: 400,
        detail: 'Запрос не прошёл проверку.',
        errors: [{ field: f.field, message: f.message, rule: f.rule }],
      });
    case 'pin':
      return PinVerifier.toProblem(f.check);
  }
}
