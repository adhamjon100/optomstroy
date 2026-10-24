import { Inject, Injectable } from '@nestjs/common';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { type AmrValue, type IssuedToken, JwtService } from '../../common/auth/jwt.service.js';
import { generateOpaqueToken, sha256 } from '../../common/crypto/random.js';
import { DevicesRepository } from '../../users/devices.repository.js';
import { SessionsRepository } from '../../users/sessions.repository.js';
import type { DevicePlatform, DeviceRow, RoleCode, SessionAmr, SessionRow, UserRow } from '../../users/users.types.js';
import { AuthPolicyService, type SessionPolicy } from '../common/auth-policy.js';
import { SessionStore } from './session-store.js';

export interface LoginDeviceInfo {
  readonly name: string;
  readonly platform: DevicePlatform;
  readonly osVersion?: string;
  readonly appVersion: string;
  readonly biometricClass?: 'class3' | 'class2' | 'none' | 'windows_hello';
}

export interface LoginSessionInput {
  readonly user: UserRow;
  readonly roles: readonly RoleCode[];
  readonly deviceKey: string;
  readonly device: LoginDeviceInfo;
  readonly ip: string | null;
  readonly userAgent: string | null;
  readonly challengeId: string;
  /**
   * Вход по аварийному коду администратора (09 §6.13 п. 3): access-JWT с `amr=["admin_code"]`; при установленном
   * и не заблокированном PIN — `unlocked_until = now()` (первый запрос → 401 UNLOCK_REQUIRED, разблокировка PIN).
   */
  readonly emergency?: { readonly requireUnlock: boolean };
}

export interface IssuedSession {
  readonly session: SessionRow;
  readonly device: DeviceRow;
  readonly refreshToken: string;
  readonly access: IssuedToken;
  readonly revokedSessionIds: readonly string[];
}

/** Время жизни refresh и idle-срок по виду пользователя (09 §8.2; D-12): staff 7 дн / 24 ч, customer 30 дн / 14 дн. */
export function sessionTerms(
  kind: UserRow['kind'],
  p: SessionPolicy,
  now: Date,
): { expiresAt: Date; idleExpiresAt: Date } {
  const day = 24 * 3600_000;
  return kind === 'staff'
    ? {
        expiresAt: new Date(now.getTime() + p.refreshTtlStaffDays * day),
        idleExpiresAt: new Date(now.getTime() + p.idleStaffHours * 3600_000),
      }
    : {
        expiresAt: new Date(now.getTime() + p.refreshTtlCustomerDays * day),
        idleExpiresAt: new Date(now.getTime() + p.idleCustomerDays * day),
      };
}

/** Idle-срок не выходит за абсолютный срок сессии. */
export function nextIdleExpiry(session: SessionRow, kind: UserRow['kind'], p: SessionPolicy, now: Date): Date {
  const idle = sessionTerms(kind, p, now).idleExpiresAt;
  return idle.getTime() < session.expiresAt.getTime() ? idle : session.expiresAt;
}

/**
 * Выпуск сессий и access-JWT (RM-D-003; 09 §8.1–§8.2; D-12): устройство (`devices.device_key` = `X-Device-Id`),
 * сессия с refresh 256 бит (в БД только SHA-256), абсолютный/idle-срок по виду пользователя, лимит устройств
 * (09 §8.2: при превышении отзывается самая старая — `session_limit`), access-JWT 15 мин с `sid`, `deviceId`.
 */
@Injectable()
export class SessionIssuer {
  constructor(
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly jwt: JwtService,
    private readonly policy: AuthPolicyService,
    private readonly devices: DevicesRepository,
    private readonly sessions: SessionsRepository,
    private readonly store: SessionStore,
  ) {}

  async createLoginSession(input: LoginSessionInput, tx: DbExecutor): Promise<IssuedSession> {
    const p = (await this.policy.effective()).session;
    const now = this.clock.now();
    const device = await this.devices.upsert(
      {
        userId: input.user.id,
        deviceKey: input.deviceKey,
        platform: input.device.platform,
        model: input.device.name.trim().slice(0, 100),
        osVersion: input.device.osVersion ?? null,
        appVersion: input.device.appVersion,
        lastIp: input.ip,
      },
      tx,
    );
    const revoked = await this.enforceDeviceLimit(input.user, device.id, p, now, tx);
    const refreshToken = generateOpaqueToken();
    const terms = sessionTerms(input.user.kind, p, now);
    const session = await this.sessions.create(
      {
        userId: input.user.id,
        deviceId: device.id,
        refreshHash: sha256(refreshToken),
        kind: 'standard',
        expiresAt: terms.expiresAt,
        idleExpiresAt: terms.idleExpiresAt,
        // 09 §6.13 п. 3: вход по аварийному коду — `amr=["admin_code"]` (CHECK `sessions_amr_chk`, миграция 0003).
        amr: [input.emergency ? 'admin_code' : 'sms'],
        createdFromChallengeId: input.challengeId,
        ipLast: input.ip,
        userAgent: input.userAgent?.slice(0, 256) ?? null,
        unlockedUntil: input.emergency?.requireUnlock ? now : new Date(now.getTime() + p.idleLockMinutes * 60_000),
      },
      tx,
    );
    const access = await this.access(input.user, input.roles, session, input.deviceKey, [
      input.emergency ? 'admin_code' : 'sms',
    ]);
    return { session, device, refreshToken, access, revokedSessionIds: revoked };
  }

  /** Access-JWT для сессии: роли и `permissionsVersion` — текущие из БД (09 §8.7). */
  access(
    user: UserRow,
    roles: readonly RoleCode[],
    session: SessionRow,
    deviceKey: string,
    amr: readonly AmrValue[],
  ): Promise<IssuedToken> {
    return this.jwt.signAccess({
      sub: user.id,
      kind: user.kind,
      roles: roles.filter((r) => r !== 'integration'),
      permissionsVersion: user.permissionsVersion,
      deviceId: deviceKey,
      sid: session.id,
      amr: [...amr],
    });
  }

  get accessTtlSeconds(): number {
    return this.jwt.accessTtlSeconds;
  }

  /**
   * Повторный вход на том же устройстве завершает прежнюю стандартную сессию этого устройства (`logout`, 09 §4.5);
   * затем при числе активных устройств ≥ лимита отзываются самые старые (`session_limit`, 09 §8.2).
   */
  private async enforceDeviceLimit(
    user: UserRow,
    deviceRowId: string,
    p: SessionPolicy,
    now: Date,
    tx: DbExecutor,
  ): Promise<string[]> {
    const revoked: string[] = [];
    const active = (await this.store.listActiveWithDevices(user.id, now, tx)).filter(
      (r) => r.session.kind === 'standard',
    );
    const others: SessionRow[] = [];
    for (const r of active) {
      if (r.session.deviceId === deviceRowId) {
        if (await this.sessions.revoke(r.session.id, 'logout', tx)) revoked.push(r.session.id);
      } else {
        others.push(r.session);
      }
    }
    const max = user.kind === 'staff' ? p.maxSessionsStaff : p.maxSessionsCustomer;
    // others — новые первыми; оставляем max − 1 (новая сессия займёт последнее место).
    for (const s of others.slice(Math.max(0, max - 1))) {
      if (await this.sessions.revoke(s.id, 'session_limit', tx)) revoked.push(s.id);
    }
    return revoked;
  }
}

/** Значения `amr` схем ответа (contracts/openapi `AuthTokenPair.amr`, `Me.session.amr`: только sms|bio|pin). */
export type ContractAmr = Exclude<SessionAmr, 'admin_code'>;

/**
 * `amr` для тела ответа: `admin_code` (09 §6.13; хранится в `sessions.amr` и access-JWT) в enum контракта не входит
 * и не выводится — DQ-02 / EQ-AUTH (владелец 08 / OpenAPI).
 */
export function contractAmr(amr: readonly AmrValue[]): ContractAmr[] {
  return amr.filter((a): a is ContractAmr => a === 'sms' || a === 'pin' || a === 'bio');
}

/** Первый фактор сессии: `admin_code` (вход по аварийному коду) или `sms` (OTP). */
export function firstFactor(amr: readonly AmrValue[]): 'sms' | 'admin_code' {
  return amr.includes('admin_code') ? 'admin_code' : 'sms';
}
