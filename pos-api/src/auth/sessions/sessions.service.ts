import { Inject, Injectable } from '@nestjs/common';
import { type AuditContext, applyAuditGucs } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { AuthStateCache } from '../../common/auth/auth-state.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import type { AuthenticatedPrincipal } from '../../common/auth/principal.js';
import { DRIZZLE, type Database } from '../../common/db/database.module.js';
import { isUuid } from '../../common/ids/uuid.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { SessionsRepository } from '../../users/sessions.repository.js';
import { TokenDenylistRepository } from '../../users/token-denylist.repository.js';
import type { DeviceRow, SessionRow } from '../../users/users.types.js';
import { maskIp } from '../common/request.js';
import type { VerifiedStepUp } from '../step-up/step-up.service.js';
import { SessionStore } from './session-store.js';

/** DTO `Session` (OpenAPI `components.schemas.Session`; 08 §4.1.6). */
export interface SessionDto {
  readonly id: string;
  readonly deviceId: string;
  readonly deviceName?: string;
  readonly platform: DeviceRow['platform'];
  readonly appVersion?: string;
  readonly kind: SessionRow['kind'];
  readonly createdAt: string;
  readonly lastUsedAt?: string;
  readonly ipLast?: string;
  readonly isCurrent: boolean;
}

function toDto(s: SessionRow, d: DeviceRow, currentSid: string): SessionDto {
  const name = d.displayName ?? d.model ?? undefined;
  return {
    id: s.id,
    deviceId: d.deviceKey,
    ...(name ? { deviceName: name.slice(0, 60) } : {}),
    platform: d.platform,
    ...(d.appVersion ? { appVersion: d.appVersion } : {}),
    kind: s.kind,
    createdAt: s.issuedAt.toISOString(),
    ...((s.lastUsedAt ?? s.rotatedAt) ? { lastUsedAt: (s.lastUsedAt ?? s.rotatedAt)!.toISOString() } : {}),
    ...(maskIp(s.ipLast) ? { ipLast: maskIp(s.ipLast) } : {}),
    isCurrent: s.id === currentSid,
  };
}

/**
 * Выход и управление своими сессиями (RM-D-003; 09 §8.4, §8.6; 08 §4.1.4–§4.1.6): отзыв `sid`, `jti` access —
 * в `token_denylist` до `exp` и в локальный denylist AuthStateCache (действует сразу в процессе; другие реплики —
 * ≤ 60 с через кэш снимков); `logout-all` — все сессии, включая биометрические, без `permissionsVersion++`.
 */
@Injectable()
export class SessionsService {
  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly sessions: SessionsRepository,
    private readonly store: SessionStore,
    private readonly denylist: TokenDenylistRepository,
    private readonly cache: AuthStateCache,
    private readonly audit: AuditService,
  ) {}

  /** `POST /auth/logout`: текущая сессия и биометрическая семья этого устройства; повтор → 204. */
  async logout(p: AuthenticatedPrincipal, audit: AuditContext, reason?: string): Promise<void> {
    await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, audit);
      const current = await this.store.findWithDevice(p.sessionId, tx);
      const revoked = (await this.sessions.revoke(p.sessionId, 'logout', tx)) ? [p.sessionId] : [];
      if (current) {
        revoked.push(
          ...(await this.sessions.revokeAllForUser(
            p.userId,
            'logout',
            { kind: 'biometric', deviceId: current.device.id },
            tx,
          )),
        );
      }
      await this.denyAccess(p, 'logout', tx);
      for (const id of revoked) this.cache.invalidateSession(id);
      await this.audit.write(
        audit,
        {
          action: 'auth.logout',
          entityType: 'session',
          entityId: p.sessionId,
          after: { revokedSessions: revoked.length, ...(reason ? { clientReason: reason.slice(0, 100) } : {}) },
        },
        tx,
      );
    });
  }

  /** `POST /auth/logout-all` (step-up `session.logout_all`): все сессии пользователя, включая текущую. */
  async logoutAll(p: AuthenticatedPrincipal, stepUp: VerifiedStepUp, audit: AuditContext): Promise<void> {
    await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, audit);
      const ids = await this.sessions.revokeAllForUser(p.userId, 'logout_all', {}, tx);
      await this.denyAccess(p, 'logout_all', tx);
      await this.denylist.add(
        {
          jti: stepUp.jti,
          tokenKind: 'step_up',
          expiresAt: stepUp.expiresAt,
          reason: 'logout_all',
          sessionId: p.sessionId,
        },
        tx,
      );
      await this.audit.write(
        audit,
        {
          action: 'auth.logout_all',
          entityType: 'user',
          entityId: p.userId,
          stepUpMethod: stepUp.method,
          after: { revokedSessions: ids.length },
        },
        tx,
      );
    });
    this.cache.invalidateUser(p.userId);
    this.cache.denyJti(stepUp.jti, stepUp.expiresAt);
  }

  async list(p: AuthenticatedPrincipal): Promise<{ items: SessionDto[] }> {
    const rows = await this.store.listActiveWithDevices(p.userId, this.clock.now());
    return { items: rows.map((r) => toDto(r.session, r.device, p.sessionId)) };
  }

  /** Своя сессия по id или 404 (чужая/неизвестная не раскрывается). */
  async findOwn(p: AuthenticatedPrincipal, sessionId: string): Promise<{ session: SessionRow; device: DeviceRow }> {
    const found = isUuid(sessionId) ? await this.store.findWithDevice(sessionId.toLowerCase()) : undefined;
    if (!found || found.session.userId !== p.userId) {
      throw new ProblemException('NOT_FOUND', { detail: 'Сессия не найдена.' });
    }
    return found;
  }

  /** `DELETE /auth/sessions/{id}` для сессии другого устройства (step-up проверен вызывающим). */
  async revokeOther(
    p: AuthenticatedPrincipal,
    target: SessionRow,
    stepUp: VerifiedStepUp,
    audit: AuditContext,
  ): Promise<void> {
    if (target.userId !== p.userId) throw new ProblemException('NOT_FOUND', { detail: 'Сессия не найдена.' });
    await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, audit);
      const changed = await this.sessions.revoke(target.id, 'logout', tx);
      if (changed) {
        await this.audit.write(
          audit,
          {
            action: 'session.revoked',
            entityType: 'session',
            entityId: target.id,
            stepUpMethod: stepUp.method,
            after: { reason: 'logout', by: 'owner' },
          },
          tx,
        );
      }
    });
    this.cache.invalidateSession(target.id);
  }

  async rename(p: AuthenticatedPrincipal, sessionId: string, deviceName: string): Promise<SessionDto> {
    const { session, device } = await this.findOwn(p, sessionId);
    if (session.revokedAt !== null) throw new ProblemException('NOT_FOUND', { detail: 'Сессия не найдена.' });
    const name = deviceName.trim();
    await this.store.renameDevice(device.id, name, this.clock.now());
    return toDto(session, { ...device, displayName: name }, p.sessionId);
  }

  private async denyAccess(p: AuthenticatedPrincipal, reason: 'logout' | 'logout_all', tx: DbExecutor): Promise<void> {
    if (p.tokenExpiresAt.getTime() > this.clock.now().getTime()) {
      await this.denylist.add(
        { jti: p.jti, tokenKind: 'access', expiresAt: p.tokenExpiresAt, reason, sessionId: p.sessionId },
        tx,
      );
    }
    this.cache.denyJti(p.jti, p.tokenExpiresAt);
  }
}
