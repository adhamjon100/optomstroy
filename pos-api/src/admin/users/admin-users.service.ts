import { Inject, Injectable } from '@nestjs/common';
import { applyAuditGucs, auditContextFromRequest } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { AuthStateCache } from '../../common/auth/auth-state.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { OtpHmacService } from '../../common/crypto/otp-hmac.service.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { SessionsRepository } from '../../users/sessions.repository.js';
import { UserProfilesRepository } from '../../users/user-profiles.repository.js';
import { UserRolesRepository } from '../../users/user-roles.repository.js';
import { UsersRepository } from '../../users/users.repository.js';
import { principalOf } from './shared/principal.js';
import { type AdminUserDto, toAdminUserDto } from './admin-user.mapper.js';
import type {
  AdminUsersBlockDto,
  AdminUsersListQuery,
  AdminUsersPinResetDto,
  AdminUsersRolesSetDto,
  AdminUsersUpdateDto,
} from './admin-users.dto.js';
import { type AdminUserRecord, AdminUsersRepository } from './admin-users.repository.js';
import { AdminAuthzService } from './shared/admin-authz.service.js';
import { AdminCursorCodec } from './shared/cursor.js';
import { verifiedStepUp } from './shared/step-up.guard.js';
import {
  canAssignRole,
  canBlock,
  canLogoutAll,
  canResetPin,
  canUpdateProfile,
  isAdminActor,
  type PolicyActor,
  type PolicyTarget,
} from './shared/target-policy.js';

type Req = RequestWithContext & { ip?: string };

export function policyTarget(r: Pick<AdminUserRecord, 'id' | 'kind' | 'status' | 'role'>): PolicyTarget {
  return { id: r.id, kind: r.kind, status: r.status, roles: r.role ? [r.role] : [] };
}

function reasonRequired(reason: string | undefined): string {
  const r = reason?.trim() ?? '';
  if (r.length < 5) {
    throw new ProblemException('VALIDATION_FAILED', {
      status: 400,
      detail: 'Укажите причину (не короче 5 символов).',
      errors: [
        { field: 'reason', rule: 'reason_required', message: 'Причина обязательна (≥ 5 символов, 11 SEC-076).' },
      ],
    });
  }
  return r;
}

/**
 * Администрирование пользователей (08 §4.18.1–§4.18.3, §4.18.9; RM-D-006): список/карточка, изменение ФИО,
 * роли, блокировка, отзыв сессий, сброс PIN. Права — RbacGuard (permissions.yaml, deny by default), step-up —
 * AdminStepUpGuard, ограничения целей — target-policy.ts (11 SEC-040, SEC-043; ядро §21 п. 3). Каждое изменение —
 * одна транзакция READ COMMITTED: `applyAuditGucs` первым оператором, аудит — последним (07 §9.3).
 */
@Injectable()
export class AdminUsersService {
  private readonly cursor: AdminCursorCodec;

  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly repo: AdminUsersRepository,
    private readonly users: UsersRepository,
    private readonly roles: UserRolesRepository,
    private readonly profiles: UserProfilesRepository,
    private readonly sessions: SessionsRepository,
    private readonly audit: AuditService,
    private readonly authz: AdminAuthzService,
    private readonly authState: AuthStateCache,
    hmac: OtpHmacService,
  ) {
    this.cursor = new AdminCursorCodec(hmac, 'admin_users');
  }

  async list(req: Req, q: AdminUsersListQuery) {
    const viewer = principalOf(req);
    const limit = q.limit ?? 50;
    const after = this.cursor.decode(q.cursor);
    const rows = await this.repo.list({ q: q.q, role: q.role, status: q.status, kind: q.kind }, after, limit + 1);
    const page = rows.slice(0, limit);
    const last = page[page.length - 1];
    const admin = isAdminActor(viewer);
    return {
      items: page.map((r) => toAdminUserDto(r, admin)),
      nextCursor:
        rows.length > limit && last
          ? this.cursor.encode({ createdAt: last.createdAt.toISOString(), id: last.id })
          : null,
      hasMore: rows.length > limit,
      asOf: this.clock.now().toISOString(),
    };
  }

  async get(req: Req, id: string): Promise<AdminUserDto> {
    const viewer = principalOf(req);
    return toAdminUserDto(await this.load(id), isAdminActor(viewer));
  }

  /** `PATCH /admin/users/{id}`: только `fullName` с проверкой `rowVersion` (08 §4.18.1). */
  async update(req: Req, id: string, body: AdminUsersUpdateDto): Promise<AdminUserDto> {
    const actor = principalOf(req);
    const record = await this.load(id);
    await this.authz.enforce(req, canUpdateProfile(actor, policyTarget(record)), 'users.manage', id);
    const ctx = auditContextFromRequest(req);
    await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      await this.repo.lockUser(id, tx);
      const profile = await this.profiles.findByUserId(id, tx);
      const current = profile?.rowVersion ?? 0;
      if (current !== body.rowVersion) throw this.versionConflict(record, current);
      if (body.fullName === undefined || body.fullName === profile?.fullName) return;
      if (profile) {
        const updated = await this.profiles.update(id, { fullName: body.fullName }, body.rowVersion, tx);
        if (!updated) throw this.versionConflict(record, current);
      } else {
        await this.profiles.create({ userId: id, fullName: body.fullName }, tx);
      }
      await this.audit.write(
        ctx,
        {
          action: 'user.updated',
          entityType: 'user',
          entityId: id,
          before: { fullName: profile?.fullName ?? null },
          after: { fullName: body.fullName },
          stepUpMethod: verifiedStepUp(req)?.method ?? null,
        },
        tx,
      );
    });
    return toAdminUserDto(await this.load(id), isAdminActor(actor));
  }

  /**
   * `PUT /admin/users/{id}/roles` (08 §4.18.2): полная замена набора ролей (R1 — одна роль), `permissions_version++`
   * (старые access → `TOKEN_STALE`), уведомление цели, аудит `user.role_changed` с причиной. Повтор того же набора →
   * 200 без изменений. Клиент → сотрудник (SEC-136 п. 4): `kind=staff`, сессии клиента отзываются (SEC-014).
   */
  async setRoles(req: Req, id: string, body: AdminUsersRolesSetDto): Promise<AdminUserDto> {
    const actor = principalOf(req);
    const record = await this.load(id);
    const role = body.roles[0];
    await this.authz.enforce(req, canAssignRole(actor, policyTarget(record), role), 'users.roles.assign', id);
    if (record.role === role && record.kind === 'staff') return toAdminUserDto(record, isAdminActor(actor));
    const reason = reasonRequired(body.reason);
    const ctx = auditContextFromRequest(req);
    const revoked = await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      const user = await this.repo.lockUser(id, tx);
      if (!user) throw notFound();
      if (!(await this.repo.bumpRowVersion(id, body.rowVersion, tx))) {
        throw this.versionConflict(record, record.rowVersion);
      }
      const before = await this.roles.activeRoleCodes(id, tx);
      await this.roles.assignRole(id, role, actor.userId, tx);
      let revokedIds: string[] = [];
      if (user.kind !== 'staff') {
        await this.repo.setKind(id, 'staff', tx);
        revokedIds = await this.sessions.revokeAllForUser(id, 'role_changed', {}, tx);
      }
      const version = await this.users.bumpPermissionsVersion(id, tx);
      await this.repo.notify(
        [id],
        {
          title: 'Роль изменена',
          body: 'Администратор изменил вашу роль. Права обновятся автоматически.',
          dedupeKey: `user.role_changed:${id}:${version ?? 0}`,
          payload: { roles: [role] },
        },
        tx,
      );
      await this.audit.write(
        ctx,
        {
          action: 'user.role_changed',
          entityType: 'user',
          entityId: id,
          before: { roles: before, kind: user.kind },
          after: { roles: [role], kind: 'staff', permissionsVersion: version, revokedSessions: revokedIds.length },
          reason,
          stepUpMethod: verifiedStepUp(req)?.method ?? null,
        },
        tx,
      );
      return revokedIds;
    });
    this.invalidate(id, revoked);
    return toAdminUserDto(await this.load(id), isAdminActor(actor));
  }

  /**
   * `POST /admin/users/{id}/block` (08 §4.18.3): `blocked:true` → `status=blocked`, все сессии отозваны
   * (`revoke_reason=blocked`), действующие приглашения номера аннулированы, `permissions_version++`;
   * `blocked:false` → `active`. Повтор с тем же значением → 200 без изменений. Причина обязательна (SEC-076).
   */
  async block(req: Req, id: string, body: AdminUsersBlockDto): Promise<AdminUserDto> {
    const actor = principalOf(req);
    const record = await this.load(id);
    await this.authz.enforce(req, canBlock(actor, policyTarget(record)), 'users.manage', id);
    const target = body.blocked ? 'blocked' : 'active';
    if (body.blocked ? record.status === 'blocked' : record.status !== 'blocked') {
      return toAdminUserDto(record, isAdminActor(actor));
    }
    const reason = reasonRequired(body.reason);
    const ctx = auditContextFromRequest(req);
    const revoked = await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      const user = await this.repo.lockUser(id, tx);
      if (!user) throw notFound();
      await this.users.setStatus(
        id,
        target,
        body.blocked
          ? { blockedByUserId: actor.userId, blockReason: reason, at: this.clock.now() }
          : { at: this.clock.now() },
        tx,
      );
      let revokedIds: string[] = [];
      let invitations: string[] = [];
      if (body.blocked) {
        revokedIds = await this.sessions.revokeAllForUser(id, 'blocked', {}, tx);
        if (user.phoneE164) invitations = await this.repo.revokePendingInvitationsForPhone(user.phoneE164, tx);
        await this.users.bumpPermissionsVersion(id, tx);
      }
      await this.audit.write(
        ctx,
        {
          action: body.blocked ? 'user.blocked' : 'user.unblocked',
          entityType: 'user',
          entityId: id,
          before: { status: user.status },
          after: { status: target, revokedSessions: revokedIds.length, revokedInvitations: invitations.length },
          reason,
          stepUpMethod: verifiedStepUp(req)?.method ?? null,
        },
        tx,
      );
      return revokedIds;
    });
    this.invalidate(id, revoked);
    return toAdminUserDto(await this.load(id), isAdminActor(actor));
  }

  /** `POST /admin/users/{id}/logout-all` (08 §4.18.3): отзыв всех сессий цели; аудит `session.revoked`. */
  async logoutAll(req: Req, id: string): Promise<void> {
    const actor = principalOf(req);
    const record = await this.load(id);
    await this.authz.enforce(req, canLogoutAll(actor, policyTarget(record)), 'session.revoke.any', id);
    const ctx = auditContextFromRequest(req);
    const revoked = await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      const ids = await this.sessions.revokeAllForUser(id, 'admin', {}, tx);
      await this.audit.write(
        ctx,
        {
          action: 'session.revoked',
          entityType: 'user',
          entityId: id,
          after: { scope: 'all', revokedSessions: ids.length, by: 'admin' },
          reason: 'logout-all администратором',
          stepUpMethod: verifiedStepUp(req)?.method ?? null,
        },
        tx,
      );
      return ids;
    });
    this.invalidate(id, revoked);
  }

  /**
   * `DELETE /admin/users/{id}/pin` (08 §4.18.9): `app_pins` удаляется (снимаются счётчик и `PIN_LOCKED`); сессии не
   * отзываются; повтор → 204 (аудит `auth.pin.reset` — только при фактическом удалении).
   */
  async resetPin(req: Req, id: string, body: AdminUsersPinResetDto): Promise<void> {
    const actor = principalOf(req);
    const record = await this.load(id);
    await this.authz.enforce(req, canResetPin(actor, policyTarget(record)), 'users.pin.reset', id);
    const ctx = auditContextFromRequest(req);
    await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      const deleted = await this.repo.deletePin(id, tx);
      if (!deleted) return;
      await this.audit.write(
        ctx,
        {
          action: 'auth.pin.reset',
          entityType: 'user',
          entityId: id,
          after: { pinSet: false },
          reason: body.reason.trim(),
          stepUpMethod: verifiedStepUp(req)?.method ?? null,
        },
        tx,
      );
    });
  }

  async load(id: string): Promise<AdminUserRecord> {
    const r = await this.repo.findRecord(id);
    if (!r) throw notFound();
    return r;
  }

  private versionConflict(record: AdminUserRecord, current: number): ProblemException {
    return new ProblemException('VERSION_CONFLICT', {
      detail: 'Данные пользователя изменились. Обновите карточку.',
      current: { rowVersion: current, roles: record.role ? [record.role] : [], status: record.status },
    });
  }

  private invalidate(userId: string, sessionIds: readonly string[]): void {
    this.authState.invalidateUser(userId);
    for (const sid of sessionIds) this.authState.invalidateSession(sid);
  }
}

function notFound(): ProblemException {
  return new ProblemException('NOT_FOUND', { detail: 'Пользователь не найден.' });
}

export type { PolicyActor };
