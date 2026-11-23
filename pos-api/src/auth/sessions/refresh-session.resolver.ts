import { Injectable, Logger } from '@nestjs/common';
import type { AuditContext } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { AuthStateCache, KIOSK_REVOKED_REASON } from '../../common/auth/auth-state.js';
import { sha256 } from '../../common/crypto/random.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { DevicesRepository } from '../../users/devices.repository.js';
import { SessionsRepository } from '../../users/sessions.repository.js';
import { UsersRepository } from '../../users/users.repository.js';
import type { DeviceRow, SessionRevokeReason, SessionRow, UserRow } from '../../users/users.types.js';
import type { SessionPolicy } from '../common/auth-policy.js';
import { SessionStore } from './session-store.js';

/** Как найден предъявленный refresh (09 §8.3). */
export type RefreshPath = 'current' | 'grace' | 'replay' | 'reuse';

/**
 * Где предъявлен refresh — `after.mode` аудита `session.reuse_detected`: `/auth/refresh`, `/auth/unlock` по методу,
 * `POST /auth/unlock/challenge` (`unlock_challenge`, ADR-116).
 */
export type RefreshUse = 'refresh' | 'unlock_pin' | 'unlock_biometric' | 'unlock_hello_key' | 'unlock_challenge';

/** Отказ по самой сессии: `401 SESSION_REVOKED` (с `reason` или без) или `401 KIOSK_REVOKED` — см. `sessionProblem`. */
export type SessionRefusal =
  { readonly kind: 'revoked'; readonly reason?: string } | { readonly kind: 'kiosk_revoked' };

export interface RefreshLookup {
  readonly refreshToken: string;
  readonly deviceKey: string;
  readonly use: RefreshUse;
  readonly audit: AuditContext;
}

export type RefreshResolution =
  | {
      readonly ok: true;
      readonly s: SessionRow;
      readonly user: UserRow;
      readonly device: DeviceRow;
      /** Предъявлен текущий (`current`) или предыдущий (`grace`, `replay`) refresh; `reuse` уже отозвал семью. */
      readonly path: Exclude<RefreshPath, 'reuse'>;
      /** Контекст аудита: субъект и сессия предъявленного refresh. */
      readonly ctx: AuditContext;
    }
  | { readonly ok: false; readonly failure: SessionRefusal };

/**
 * Проверка предъявленного refresh — общая для `POST /auth/refresh`, `POST /auth/unlock` (RefreshService) и
 * `POST /auth/unlock/challenge` (HelloKeyChallengeService; 08 §4.1.10, доработка 2026-11-18 `[ВЫВОД исполнителя]`):
 * поиск сессии по текущему, предыдущему и вытесненному хэшу (09 §8.3), отзыв (`KIOSK_REVOKED` для `kiosk_revoked`,
 * 09 §8.9 п. 8 (а)), абсолютный и idle-сроки (отзыв `expired`), чужой `X-Device-Id` (отзыв `device_mismatch` с
 * аудитом), статус пользователя (`blocked`, без отзыва) и reuse-detection (отзыв семьи `reuse_detected`, аудит
 * `session.reuse_detected`). Отзывы выполняются в транзакции вызывающего; ответ (`sessionProblem`) — после COMMIT.
 * Дальнейшие правила (вид токена, поздний повтор, idle-блокировка, второй фактор) — у вызывающего.
 */
@Injectable()
export class RefreshSessionResolver {
  private readonly logger = new Logger('auth');

  constructor(
    private readonly sessions: SessionsRepository,
    private readonly store: SessionStore,
    private readonly users: UsersRepository,
    private readonly devices: DevicesRepository,
    private readonly cache: AuthStateCache,
    private readonly audit: AuditService,
  ) {}

  async resolve(input: RefreshLookup, p: SessionPolicy, now: Date, tx: DbExecutor): Promise<RefreshResolution> {
    const hash = sha256(input.refreshToken);
    let path: RefreshPath = 'current';
    let s = await this.sessions.findByRefreshHash(hash, tx, true);
    if (!s) {
      s = await this.store.findByPrevHashForUpdate(hash, tx);
      if (s) path = this.classifyPrevious(s, p, now);
      else {
        s = await this.store.findBySupersededHashForUpdate(hash, tx);
        if (s) path = 'reuse';
      }
    }
    if (!s) return refuse({ kind: 'revoked' });
    // Найден по любому из трёх хэшей (текущий, предыдущий, вытесненный), а сессия отозвана: отключение планшета,
    // аварийный выход или подключение заново (`kiosk_revoked`) → `401 KIOSK_REVOKED`; прочее — SESSION_REVOKED
    // (09 §8.9 п. 8 (а)). Причину `kiosk_revoked` пишет только жизненный цикл планшета (src/kiosk/lifecycle).
    if (s.revokedAt !== null) {
      return refuse(s.revokeReason === KIOSK_REVOKED_REASON ? { kind: 'kiosk_revoked' } : { kind: 'revoked' });
    }

    const user = await this.users.findById(s.userId, tx);
    const device = await this.devices.findById(s.deviceId, tx);
    if (!user || !device) return refuse({ kind: 'revoked' });
    const ctx: AuditContext = { ...input.audit, actorUserId: user.id, sessionId: s.id };

    if (s.expiresAt.getTime() <= now.getTime() || s.idleExpiresAt.getTime() <= now.getTime()) {
      await this.revoke(s, 'expired', ctx, tx, false);
      return refuse({ kind: 'revoked', reason: 'expired' });
    }
    if (device.deviceKey !== input.deviceKey) {
      await this.revoke(s, 'device_mismatch', ctx, tx, true);
      return refuse({ kind: 'revoked', reason: 'device_mismatch' });
    }
    if (user.status !== 'active' && user.status !== 'pending_activation') {
      return refuse({ kind: 'revoked', reason: 'blocked' });
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
          after: { familyId: s.familyId, revokedSessions: ids.length, mode: input.use },
        },
        tx,
      );
      return refuse({ kind: 'revoked', reason: 'reuse_detected' });
    }
    return { ok: true, s, user, device, path, ctx };
  }

  /** Отзыв одной сессии с причиной; `auditIt` — запись `session.revoked` (как при `device_mismatch`). */
  async revoke(
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

  /**
   * Предъявлен предыдущий токен (`prev_refresh_hash`): «использовался ли текущий» — `last_used_at IS NOT NULL`
   * (ротация обнуляет отметку; её ставит запрос с access, выданным при ротации). Не использовался: в окне грации и грация не тратилась →
   * `grace`; вне окна → `replay` (09 §8.3 «refresh_replay»); иначе (использовался или грация уже потрачена,
   * 12 T-SESS-006) → `reuse`.
   */
  private classifyPrevious(s: SessionRow, p: SessionPolicy, now: Date): RefreshPath {
    const rotatedAt = s.rotatedAt?.getTime() ?? 0;
    // После ротации `last_used_at = NULL`; не NULL — текущий токен уже использован (refresh или access).
    const used = s.lastUsedAt !== null;
    if (used || s.graceUsedAt !== null) return 'reuse';
    return now.getTime() - rotatedAt <= p.graceSeconds * 1000 ? 'grace' : 'replay';
  }
}

function refuse(failure: SessionRefusal): RefreshResolution {
  return { ok: false, failure };
}

/** Ответ на отказ по сессии (08 §2.4): `401 KIOSK_REVOKED` или `401 SESSION_REVOKED` с `reason`. */
export function sessionProblem(f: SessionRefusal): ProblemException {
  if (f.kind === 'kiosk_revoked') {
    return new ProblemException('KIOSK_REVOKED', { detail: 'Планшет отключён администратором.' });
  }
  return new ProblemException('SESSION_REVOKED', {
    detail:
      f.reason === 'reuse_detected'
        ? 'Для безопасности мы завершили все сессии. Войдите снова.'
        : 'Сессия завершена. Войдите снова.',
    ...(f.reason ? { reason: f.reason } : {}),
  });
}
