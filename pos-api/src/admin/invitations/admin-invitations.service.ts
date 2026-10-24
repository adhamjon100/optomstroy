import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { applyAuditGucs, auditContextFromRequest } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { AuthStateCache } from '../../common/auth/auth-state.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { OtpHmacService } from '../../common/crypto/otp-hmac.service.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { newId } from '../../common/ids/uuid.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { UserProfilesRepository } from '../../users/user-profiles.repository.js';
import { UserRolesRepository } from '../../users/user-roles.repository.js';
import { UsersRepository } from '../../users/users.repository.js';
import type { RoleCode } from '../../users/users.types.js';
import { AdminUsersRepository } from '../users/admin-users.repository.js';
import { AdminAuthzService } from '../users/shared/admin-authz.service.js';
import { AdminCursorCodec } from '../users/shared/cursor.js';
import { principalOf } from '../users/shared/principal.js';
import { verifiedStepUp } from '../users/shared/step-up.guard.js';
import { canInviteRole } from '../users/shared/target-policy.js';
import { type InvitationDto, toInvitationDto } from './admin-invitations.dto.js';
import { AdminInvitationsRepository, type InvitationRow } from './admin-invitations.repository.js';

type Req = RequestWithContext & { ip?: string };

export interface InviteInput {
  readonly phone: string;
  readonly roles: readonly string[];
  readonly fullName?: string | null;
  readonly expiresAt?: string | null;
}

/** Откуда пришёл запрос: `/admin/invitations` (`invitation.created`) или `POST /admin/users` (`user.invited`). */
export type InviteSource = 'invitations' | 'users';

export type InviteOutcome =
  | { readonly kind: 'created'; readonly invitationId: string }
  | { readonly kind: 'applied'; readonly invitationId: string; readonly userId: string };

/** Причина при немедленной активации (обязательна для `user.role_changed`, 11 SEC-076). */
const ACTIVATION_REASON = 'активация по приглашению администратора';

/**
 * Приглашения сотрудников (08 §4.18.4; D-07 в редакции ядра §24.2; 11 SEC-136, SEC-040; 09 REG-022):
 * - создаёт только `admin` (`invitations.manage` либо `users.manage` для `POST /admin/users`) со step-up;
 * - роль — только `seller`/`cashier`/`senior_seller` (SEC-136 п. 2), `owner` → 403 `owner_role_reserved`;
 * - номер учётной записи `pending_activation` → приглашение применяется сразу: `active`, `kind=staff`, роль
 *   приглашения, `permissions_version++`, приглашение `accepted` (каноническая активация — 11 №50, SEC-033);
 * - номер действующего `customer` или сотрудника → 409 `PHONE_ALREADY_REGISTERED` (SEC-136 п. 4: клиент не
 *   становится сотрудником автоматически — роль меняет `PUT /admin/users/{id}/roles`);
 * - действующее `pending`-приглашение на номер → 409 `PHONE_ALREADY_REGISTERED` (`reason: invitation_pending`,
 *   12 T-REG-017; истёкшее переводится в `expired`).
 * Принятие приглашения при первом OTP-входе выполняет модуль auth (RM-D-017).
 */
@Injectable()
export class AdminInvitationsService {
  private readonly cursor: AdminCursorCodec;

  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    @Inject(CLOCK) private readonly clock: Clock,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    private readonly repo: AdminInvitationsRepository,
    private readonly adminUsers: AdminUsersRepository,
    private readonly users: UsersRepository,
    private readonly roles: UserRolesRepository,
    private readonly profiles: UserProfilesRepository,
    private readonly audit: AuditService,
    private readonly authz: AdminAuthzService,
    private readonly authState: AuthStateCache,
    hmac: OtpHmacService,
  ) {
    this.cursor = new AdminCursorCodec(hmac, 'admin_invitations');
  }

  async list(limit = 50, cursor?: string) {
    const after = this.cursor.decode(cursor);
    const rows = await this.repo.list(after, limit + 1);
    const page = rows.slice(0, limit);
    const last = page[page.length - 1];
    const now = this.clock.now();
    return {
      items: page.map((r) => toInvitationDto(r, now)),
      nextCursor:
        rows.length > limit && last
          ? this.cursor.encode({ createdAt: last.createdAt.toISOString(), id: last.id })
          : null,
      hasMore: rows.length > limit,
      asOf: now.toISOString(),
    };
  }

  async get(id: string): Promise<InvitationDto> {
    const r = await this.repo.findRecord(id);
    if (!r) throw new ProblemException('NOT_FOUND', { detail: 'Приглашение не найдено.' });
    return toInvitationDto(r, this.clock.now());
  }

  /** Создание приглашения (общая часть `POST /admin/invitations` и `POST /admin/users`). */
  async invite(req: Req, input: InviteInput, source: InviteSource): Promise<InviteOutcome> {
    const actor = principalOf(req);
    const operation = source === 'users' ? 'users.manage' : 'invitations.manage';
    if (input.roles.length !== 1) {
      throw validation422('roles', 'max_items', 'В R1 приглашение содержит ровно одну роль.');
    }
    const role = input.roles[0] as RoleCode;
    await this.authz.enforce(req, canInviteRole(role), operation, null);
    const fullName = input.fullName?.trim();
    if (!fullName) throw validation422('fullName', 'required', 'Укажите ФИО сотрудника.');
    const now = this.clock.now();
    const expiresAt = input.expiresAt
      ? new Date(input.expiresAt)
      : new Date(now.getTime() + this.config.INVITATION_TTL_DAYS * 86_400_000);
    if (expiresAt.getTime() <= now.getTime()) {
      throw validation422('expiresAt', 'date_range', 'Срок приглашения должен быть в будущем.');
    }

    const ctx = auditContextFromRequest(req);
    const stepUpMethod = verifiedStepUp(req)?.method ?? null;
    const outcome = await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtext(${`admin.invite:${input.phone}`}))`);

      const existing = await this.users.findByPhone(input.phone, tx);
      if (existing && existing.status !== 'pending_activation') {
        throw new ProblemException('PHONE_ALREADY_REGISTERED', {
          detail:
            existing.kind === 'customer'
              ? 'Номер принадлежит клиенту. Роль сотрудника назначается через изменение ролей пользователя.'
              : 'Номер уже принадлежит сотруднику. Роли меняются через изменение ролей пользователя.',
          reason: existing.kind === 'customer' ? 'customer_account' : 'staff_account',
        });
      }
      const pending = await this.repo.findPendingForPhone(input.phone, tx);
      if (pending) {
        if (pending.expiresAt.getTime() > now.getTime()) {
          throw new ProblemException('PHONE_ALREADY_REGISTERED', {
            detail: 'На этот номер уже есть действующее приглашение.',
            reason: 'invitation_pending',
          });
        }
        await this.repo.setStatus(pending.id, 'expired', tx);
      }

      const invitationId = newId();
      if (!existing) {
        await this.repo.create(
          { id: invitationId, phoneE164: input.phone, role, fullName, invitedByUserId: actor.userId, expiresAt },
          tx,
        );
        await this.audit.write(
          ctx,
          {
            action: source === 'users' ? 'user.invited' : 'invitation.created',
            entityType: 'user_invitation',
            entityId: invitationId,
            after: { phone: input.phone, role, expiresAt: expiresAt.toISOString(), fullName },
            stepUpMethod,
          },
          tx,
        );
        return { kind: 'created', invitationId } as const;
      }

      // pending_activation → немедленная активация с ролью приглашения (11 №50, SEC-033; 08 §4.18.1, §4.18.4)
      const userId = existing.id;
      await this.adminUsers.lockUser(userId, tx);
      await this.repo.create(
        {
          id: invitationId,
          phoneE164: input.phone,
          role,
          fullName,
          invitedByUserId: actor.userId,
          expiresAt,
          status: 'accepted',
          acceptedUserId: userId,
          acceptedAt: now,
        },
        tx,
      );
      await this.activate(tx, userId, invitationId, role, fullName, actor.userId);
      await this.adminUsers.notify(
        [userId],
        {
          title: 'Учётная запись активирована',
          body: 'Администратор активировал вашу учётную запись сотрудника. Войдите снова и задайте PIN.',
          dedupeKey: `user.activated:${invitationId}`,
          payload: { invitationId },
        },
        tx,
      );
      await this.audit.write(
        ctx,
        {
          action: source === 'users' ? 'user.invited' : 'invitation.created',
          entityType: 'user_invitation',
          entityId: invitationId,
          after: { phone: input.phone, role, expiresAt: expiresAt.toISOString(), appliedToUserId: userId, fullName },
          stepUpMethod,
        },
        tx,
      );
      await this.audit.write(
        ctx,
        {
          action: 'user.activated',
          entityType: 'user',
          entityId: userId,
          before: { status: 'pending_activation', kind: existing.kind },
          after: { status: 'active', kind: 'staff', invitationId },
          stepUpMethod,
        },
        tx,
      );
      await this.audit.write(
        ctx,
        {
          action: 'user.role_changed',
          entityType: 'user',
          entityId: userId,
          before: { roles: [] },
          after: { roles: [role], roleSource: 'invitation' },
          reason: ACTIVATION_REASON,
          stepUpMethod,
        },
        tx,
      );
      return { kind: 'applied', invitationId, userId } as const;
    });
    if (outcome.kind === 'applied') this.authState.invalidateUser(outcome.userId);
    return outcome;
  }

  /** `DELETE /admin/invitations/{id}`: `pending` → `revoked`; повтор и иные статусы → 204 без изменений. */
  async revoke(req: Req, id: string): Promise<void> {
    const ctx = auditContextFromRequest(req);
    const stepUpMethod = verifiedStepUp(req)?.method ?? null;
    const now = this.clock.now();
    await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      const inv = await this.repo.lock(id, tx);
      if (!inv) throw new ProblemException('NOT_FOUND', { detail: 'Приглашение не найдено.' });
      if (inv.status !== 'pending') return;
      if (inv.expiresAt.getTime() <= now.getTime()) {
        await this.repo.setStatus(id, 'expired', tx);
        return;
      }
      await this.repo.setStatus(id, 'revoked', tx);
      await this.audit.write(
        ctx,
        {
          action: 'invitation.revoked',
          entityType: 'user_invitation',
          entityId: id,
          before: { status: 'pending' },
          after: { status: 'revoked', role: inv.role },
          stepUpMethod,
        },
        tx,
      );
    });
  }

  private async activate(
    tx: DbExecutor,
    userId: string,
    invitationId: string,
    role: RoleCode,
    fullName: string,
    grantedBy: string,
  ): Promise<void> {
    await this.users.setStatus(userId, 'active', {}, tx);
    await this.adminUsers.setKind(userId, 'staff', tx);
    await this.adminUsers.setInvitation(userId, invitationId, tx);
    await this.roles.assignRole(userId, role, grantedBy, tx);
    await this.users.bumpPermissionsVersion(userId, tx);
    const profile = await this.profiles.findByUserId(userId, tx);
    if (!profile) await this.profiles.create({ userId, fullName }, tx);
  }
}

export function validation422(field: string, rule: string, message: string): ProblemException {
  return new ProblemException('VALIDATION_FAILED', {
    status: 422,
    detail: message,
    errors: [{ field, rule, message }],
  });
}

export type { InvitationRow };
