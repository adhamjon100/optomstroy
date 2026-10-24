import { Inject, Injectable } from '@nestjs/common';
import { and, eq, sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { userInvitations } from '../../db/schema/index.js';
import type { RoleCode } from '../../users/users.types.js';
import type { KeysetPosition } from '../users/shared/cursor.js';

export type InvitationRow = typeof userInvitations.$inferSelect;

/** Строка приглашения с данными пригласившего (для `Invitation.createdBy`, `UserRef` 08 §3.5). */
export interface InvitationRecord extends InvitationRow {
  readonly inviterDisplayName: string | null;
  readonly inviterRole: RoleCode | null;
}

export interface CreateInvitationInput {
  readonly id?: string;
  readonly phoneE164: string;
  readonly role: RoleCode;
  readonly fullName: string;
  readonly invitedByUserId: string;
  readonly expiresAt: Date;
  readonly status?: 'pending' | 'accepted';
  readonly acceptedUserId?: string | null;
  readonly acceptedAt?: Date | null;
}

interface RawInvitation {
  id: string;
  phone_e164: string;
  role: RoleCode;
  full_name: string;
  invited_by_user_id: string;
  status: InvitationRow['status'];
  expires_at: Date | string;
  accepted_user_id: string | null;
  accepted_at: Date | string | null;
  revoked_at: Date | string | null;
  note: string | null;
  created_at: Date | string;
  updated_at: Date | string;
  inviter_display_name: string | null;
  inviter_role: RoleCode | null;
  [k: string]: unknown;
}

const d = (v: Date | string): Date => (v instanceof Date ? v : new Date(v));
const dn = (v: Date | string | null): Date | null => (v === null ? null : d(v));

/** `user_invitations` (07 §5.3, DATA-102): один `pending` на номер (`user_invitations_phone_pending_uq`). */
@Injectable()
export class AdminInvitationsRepository {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async list(after: KeysetPosition | undefined, limit: number, ex: DbExecutor = this.db): Promise<InvitationRecord[]> {
    const keyset = after
      ? sql`WHERE (inv.created_at, inv.id) < (${after.createdAt}::timestamptz, ${after.id}::uuid)`
      : sql``;
    const res = await ex.execute<RawInvitation>(sql`
      SELECT inv.*, coalesce(p.display_name, p.full_name) AS inviter_display_name, r.code AS inviter_role
        FROM user_invitations inv
        LEFT JOIN user_profiles p ON p.user_id = inv.invited_by_user_id
        LEFT JOIN user_roles ur ON ur.user_id = inv.invited_by_user_id AND ur.revoked_at IS NULL
        LEFT JOIN roles r ON r.id = ur.role_id
        ${keyset}
       ORDER BY inv.created_at DESC, inv.id DESC
       LIMIT ${limit}`);
    return res.rows.map(toRecord);
  }

  async findRecord(id: string, ex: DbExecutor = this.db): Promise<InvitationRecord | undefined> {
    const res = await ex.execute<RawInvitation>(sql`
      SELECT inv.*, coalesce(p.display_name, p.full_name) AS inviter_display_name, r.code AS inviter_role
        FROM user_invitations inv
        LEFT JOIN user_profiles p ON p.user_id = inv.invited_by_user_id
        LEFT JOIN user_roles ur ON ur.user_id = inv.invited_by_user_id AND ur.revoked_at IS NULL
        LEFT JOIN roles r ON r.id = ur.role_id
       WHERE inv.id = ${id}::uuid`);
    const row = res.rows[0];
    return row ? toRecord(row) : undefined;
  }

  async lock(id: string, ex: DbExecutor): Promise<InvitationRow | undefined> {
    const rows = await ex.select().from(userInvitations).where(eq(userInvitations.id, id)).for('update').limit(1);
    return rows[0];
  }

  /** Действующая строка `pending` номера (не обязательно в сроке — срок проверяет вызывающий). */
  async findPendingForPhone(phoneE164: string, ex: DbExecutor): Promise<InvitationRow | undefined> {
    const rows = await ex
      .select()
      .from(userInvitations)
      .where(and(eq(userInvitations.phoneE164, phoneE164), eq(userInvitations.status, 'pending')))
      .for('update')
      .limit(1);
    return rows[0];
  }

  async create(input: CreateInvitationInput, ex: DbExecutor): Promise<InvitationRow> {
    const rows = await ex
      .insert(userInvitations)
      .values({
        ...(input.id ? { id: input.id } : {}),
        phoneE164: input.phoneE164,
        role: input.role,
        fullName: input.fullName,
        invitedByUserId: input.invitedByUserId,
        expiresAt: input.expiresAt,
        status: input.status ?? 'pending',
        acceptedUserId: input.acceptedUserId ?? null,
        acceptedAt: input.acceptedAt ?? null,
      })
      .returning();
    const row = rows[0];
    if (!row) throw new Error('user_invitations.create: INSERT не вернул строку');
    return row;
  }

  async setStatus(id: string, status: 'revoked' | 'expired', ex: DbExecutor): Promise<InvitationRow | undefined> {
    const rows = await ex
      .update(userInvitations)
      .set({
        status,
        ...(status === 'revoked' ? { revokedAt: sql`now()` } : {}),
        updatedAt: sql`now()`,
      })
      .where(and(eq(userInvitations.id, id), eq(userInvitations.status, 'pending')))
      .returning();
    return rows[0];
  }
}

function toRecord(r: RawInvitation): InvitationRecord {
  return {
    id: r.id,
    phoneE164: r.phone_e164,
    role: r.role,
    fullName: r.full_name,
    invitedByUserId: r.invited_by_user_id,
    status: r.status,
    expiresAt: d(r.expires_at),
    acceptedUserId: r.accepted_user_id,
    acceptedAt: dn(r.accepted_at),
    revokedAt: dn(r.revoked_at),
    note: r.note,
    createdAt: d(r.created_at),
    updatedAt: d(r.updated_at),
    inviterDisplayName: r.inviter_display_name,
    inviterRole: r.inviter_role,
  };
}
