import { Inject, Injectable } from '@nestjs/common';
import { and, eq, isNull, sql, type SQL } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { appPins, notifications, userInvitations, userProfiles, users } from '../../db/schema/index.js';
import type { RoleCode, UserKind, UserRow, UserStatusValue } from '../../users/users.types.js';
import type { KeysetPosition } from './shared/cursor.js';

/** Строка проекции `AdminUser` (08 §4.18.1) — данные, без правил видимости. */
export interface AdminUserRecord {
  readonly id: string;
  readonly kind: UserKind;
  readonly status: UserStatusValue;
  readonly phoneE164: string | null;
  readonly fullName: string | null;
  readonly displayName: string | null;
  readonly role: RoleCode | null;
  readonly permissionsVersion: number;
  readonly discountMaxPercent: string | null;
  readonly lastLoginAt: Date | null;
  readonly devicesCount: number;
  readonly createdAt: Date;
  readonly invitationStatus: string | null;
  readonly invitationCreatedAt: Date | null;
  /** `user_profiles.row_version` (0 — профиля нет). */
  readonly rowVersion: number;
}

export interface AdminUserFilter {
  readonly q?: string;
  readonly role?: RoleCode;
  readonly status?: UserStatusValue;
  readonly kind?: UserKind;
}

export interface NotificationInput {
  readonly title: string;
  readonly body: string;
  readonly dedupeKey: string;
  readonly severity?: 'info' | 'warning' | 'error';
  readonly payload?: Readonly<Record<string, unknown>>;
}

interface RawRecord {
  id: string;
  kind: UserKind;
  status: UserStatusValue;
  phone_e164: string | null;
  full_name: string | null;
  display_name: string | null;
  role: RoleCode | null;
  permissions_version: number | string;
  max_percent: string | null;
  last_login_at: Date | string | null;
  devices_count: number | string;
  created_at: Date | string;
  invitation_status: string | null;
  invitation_created_at: Date | string | null;
  row_version: number | string | null;
  [k: string]: unknown;
}

const toDate = (v: Date | string | null): Date | null => (v === null ? null : v instanceof Date ? v : new Date(v));

/**
 * Данные админ-раздела пользователей (`users`, `user_profiles`, `user_roles`, `devices`, `user_invitations`,
 * `role_discount_limits`, `app_pins`, `notifications`). Изменения пользователей/ролей — через репозитории
 * src/users; здесь — проекции и операции, которых в src/users нет (смена `kind`, сброс PIN, уведомления).
 */
@Injectable()
export class AdminUsersRepository {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async findRecord(id: string, ex: DbExecutor = this.db): Promise<AdminUserRecord | undefined> {
    const rows = await this.select(sql`u.id = ${id}::uuid`, undefined, 1, ex);
    return rows[0];
  }

  /** Список (08 §4.18.1): фильтры `q` (ФИО/телефон), `role`, `status`, `kind`; keyset `(created_at, id) DESC`. */
  async list(
    filter: AdminUserFilter,
    after: KeysetPosition | undefined,
    limit: number,
    ex: DbExecutor = this.db,
  ): Promise<AdminUserRecord[]> {
    const conds: SQL[] = [];
    if (filter.role) conds.push(sql`r.code = ${filter.role}::role_code`);
    if (filter.status) conds.push(sql`u.status = ${filter.status}::user_status`);
    if (filter.kind) conds.push(sql`u.kind = ${filter.kind}::user_kind`);
    const q = filter.q?.trim();
    if (q) {
      const digits = q.replace(/\D/g, '');
      const like = `%${q.replace(/[\\%_]/g, (m) => `\\${m}`)}%`;
      conds.push(
        digits.length >= 2 && /^[\d\s()+-]+$/.test(q)
          ? sql`u.phone_e164 LIKE ${`%${digits}%`}`
          : sql`(p.full_name ILIKE ${like} OR p.display_name ILIKE ${like})`,
      );
    }
    const where = conds.length > 0 ? sql.join(conds, sql` AND `) : sql`TRUE`;
    return this.select(where, after, limit, ex);
  }

  private async select(
    where: SQL,
    after: KeysetPosition | undefined,
    limit: number,
    ex: DbExecutor,
  ): Promise<AdminUserRecord[]> {
    const keyset = after ? sql`AND (u.created_at, u.id) < (${after.createdAt}::timestamptz, ${after.id}::uuid)` : sql``;
    const res = await ex.execute<RawRecord>(sql`
      SELECT u.id, u.kind, u.status, u.phone_e164, u.permissions_version, u.last_login_at, u.created_at,
             p.full_name, p.display_name, p.row_version,
             r.code AS role,
             rdl.max_percent::text AS max_percent,
             inv.status AS invitation_status, inv.created_at AS invitation_created_at,
             (SELECT count(*) FROM devices d WHERE d.user_id = u.id AND d.revoked_at IS NULL) AS devices_count
        FROM users u
        LEFT JOIN user_profiles p ON p.user_id = u.id
        LEFT JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL
        LEFT JOIN roles r ON r.id = ur.role_id
        LEFT JOIN role_discount_limits rdl ON rdl.role = r.code
        LEFT JOIN user_invitations inv ON inv.id = u.invitation_id
       WHERE u.deleted_at IS NULL AND ${where} ${keyset}
       ORDER BY u.created_at DESC, u.id DESC
       LIMIT ${limit}`);
    return res.rows.map((r) => ({
      id: r.id,
      kind: r.kind,
      status: r.status,
      phoneE164: r.phone_e164,
      fullName: r.full_name,
      displayName: r.display_name,
      role: r.role,
      permissionsVersion: Number(r.permissions_version),
      discountMaxPercent: r.max_percent,
      lastLoginAt: toDate(r.last_login_at),
      devicesCount: Number(r.devices_count),
      createdAt: toDate(r.created_at) ?? new Date(0),
      invitationStatus: r.invitation_status,
      invitationCreatedAt: toDate(r.invitation_created_at),
      rowVersion: r.row_version === null ? 0 : Number(r.row_version),
    }));
  }

  /** Строка `users` под `FOR UPDATE` (сериализация админских изменений одной цели). */
  async lockUser(id: string, ex: DbExecutor): Promise<UserRow | undefined> {
    const rows = await ex
      .select()
      .from(users)
      .where(and(eq(users.id, id), isNull(users.deletedAt)))
      .for('update')
      .limit(1);
    return rows[0];
  }

  /** `customer` → `staff` при назначении роли сотрудника (11 SEC-136 п. 4). */
  async setKind(id: string, kind: UserKind, ex: DbExecutor): Promise<void> {
    await ex
      .update(users)
      .set({ kind, updatedAt: sql`now()` })
      .where(eq(users.id, id));
  }

  /** Привязка пользователя к принятому приглашению (`users.invitation_id`). */
  async setInvitation(id: string, invitationId: string, ex: DbExecutor): Promise<void> {
    await ex
      .update(users)
      .set({ invitationId, updatedAt: sql`now()` })
      .where(eq(users.id, id));
  }

  /**
   * Оптимистичная проверка `rowVersion` (`user_profiles.row_version`; без профиля — 0) с увеличением версии:
   * false — версия не совпала (409 VERSION_CONFLICT). Для пользователя без профиля версия не растёт.
   */
  async bumpRowVersion(userId: string, expected: number, ex: DbExecutor): Promise<boolean> {
    const rows = await ex
      .update(userProfiles)
      .set({ rowVersion: sql`${userProfiles.rowVersion} + 1`, updatedAt: sql`now()` })
      .where(and(eq(userProfiles.userId, userId), eq(userProfiles.rowVersion, expected)))
      .returning({ v: userProfiles.rowVersion });
    if (rows.length === 1) return true;
    if (expected !== 0) return false;
    const exists = await ex
      .select({ v: userProfiles.rowVersion })
      .from(userProfiles)
      .where(eq(userProfiles.userId, userId))
      .limit(1);
    return exists.length === 0;
  }

  /** Сброс PIN (08 §4.18.9): строка `app_pins` удаляется вместе со счётчиком попыток и `locked_until`. */
  async deletePin(userId: string, ex: DbExecutor): Promise<boolean> {
    const rows = await ex.delete(appPins).where(eq(appPins.userId, userId)).returning({ id: appPins.userId });
    return rows.length === 1;
  }

  async hasPin(userId: string, ex: DbExecutor = this.db): Promise<boolean> {
    const rows = await ex.select({ id: appPins.userId }).from(appPins).where(eq(appPins.userId, userId)).limit(1);
    return rows.length === 1;
  }

  /** Аннулирование действующих приглашений номера (блокировка пользователя, 08 §4.18.3). */
  async revokePendingInvitationsForPhone(phoneE164: string, ex: DbExecutor): Promise<string[]> {
    const rows = await ex
      .update(userInvitations)
      .set({ status: 'revoked', revokedAt: sql`now()`, updatedAt: sql`now()` })
      .where(and(eq(userInvitations.phoneE164, phoneE164), eq(userInvitations.status, 'pending')))
      .returning({ id: userInvitations.id });
    return rows.map((r) => r.id);
  }

  /** Активные владельцы (уведомления о выдаче аварийного кода, 09 §6.13). */
  async activeOwnerIds(ex: DbExecutor = this.db): Promise<string[]> {
    const res = await ex.execute<{ user_id: string }>(sql`
      SELECT ur.user_id FROM user_roles ur
        JOIN roles r ON r.id = ur.role_id
        JOIN users u ON u.id = ur.user_id
       WHERE r.code = 'owner' AND ur.revoked_at IS NULL AND u.status = 'active' AND u.deleted_at IS NULL`);
    return res.rows.map((r) => r.user_id);
  }

  /** In-app уведомления (`notifications`, kind `system`); повтор с тем же `dedupe_key` игнорируется. */
  async notify(userIds: readonly string[], n: NotificationInput, ex: DbExecutor): Promise<void> {
    const unique = [...new Set(userIds)];
    if (unique.length === 0) return;
    await ex
      .insert(notifications)
      .values(
        unique.map((userId) => ({
          userId,
          kind: 'system' as const,
          severity: n.severity ?? 'info',
          titleRu: n.title,
          bodyRu: n.body,
          payload: n.payload ?? {},
          dedupeKey: n.dedupeKey,
        })),
      )
      .onConflictDoNothing();
  }
}
