import { Inject, Injectable } from '@nestjs/common';
import { and, asc, eq, isNull, sql } from 'drizzle-orm';
import type { DbExecutor } from '../common/audit/db-executor.js';
import { DRIZZLE } from '../common/db/database.module.js';
import { roles, userRoles } from '../db/schema/index.js';
import type { RoleCode, UserRoleRow } from './users.types.js';

/**
 * `user_roles` (07 §5.7; B-AR-03): история назначений не удаляется (`revoked_at`), активная роль — одна
 * (`user_roles_one_active_uq`, R1). INSERT/UPDATE порождают аудит БД `user.role_changed` (`trg_user_roles_audit`).
 * Увеличение `users.permissions_version` — UsersRepository.bumpPermissionsVersion в той же транзакции.
 */
@Injectable()
export class UserRolesRepository {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  /** Коды активных ролей пользователя (в R1 — не более одной). */
  async activeRoleCodes(userId: string, ex: DbExecutor = this.db): Promise<RoleCode[]> {
    const rows = await ex
      .select({ code: roles.code })
      .from(userRoles)
      .innerJoin(roles, eq(roles.id, userRoles.roleId))
      .where(and(eq(userRoles.userId, userId), isNull(userRoles.revokedAt)))
      .orderBy(asc(roles.sortOrder));
    return rows.map((r) => r.code);
  }

  async roleIdByCode(code: RoleCode, ex: DbExecutor = this.db): Promise<string | undefined> {
    const rows = await ex.select({ id: roles.id }).from(roles).where(eq(roles.code, code)).limit(1);
    return rows[0]?.id;
  }

  /**
   * Назначает единственную активную роль: отзывает текущую (если другая) и вставляет новую строку. Та же роль
   * → без изменений (`changed: false`). Выполняется в переданной транзакции либо в собственной.
   */
  async assignRole(
    userId: string,
    code: RoleCode,
    grantedByUserId: string | null,
    ex?: DbExecutor,
  ): Promise<{ readonly row: UserRoleRow; readonly changed: boolean }> {
    const run = async (tx: DbExecutor) => {
      const roleId = await this.roleIdByCode(code, tx);
      if (!roleId) throw new Error(`user_roles.assignRole: роль ${code} отсутствует в roles (seed 0002)`);
      const active = await tx
        .select()
        .from(userRoles)
        .where(and(eq(userRoles.userId, userId), isNull(userRoles.revokedAt)))
        .for('update');
      const same = active.find((r) => r.roleId === roleId);
      if (same) return { row: same, changed: false };
      if (active.length > 0) {
        await tx
          .update(userRoles)
          .set({ revokedAt: sql`now()`, updatedAt: sql`now()` })
          .where(and(eq(userRoles.userId, userId), isNull(userRoles.revokedAt)));
      }
      const inserted = await tx.insert(userRoles).values({ userId, roleId, grantedByUserId }).returning();
      const row = inserted[0];
      if (!row) throw new Error('user_roles.assignRole: INSERT не вернул строку');
      return { row, changed: true };
    };
    return ex ? run(ex) : this.db.transaction((tx) => run(tx));
  }

  /** Отзыв всех активных ролей (удаление учётной записи, блокировка по регламенту). Возвращает число строк. */
  async revokeAll(userId: string, ex: DbExecutor = this.db): Promise<number> {
    const rows = await ex
      .update(userRoles)
      .set({ revokedAt: sql`now()`, updatedAt: sql`now()` })
      .where(and(eq(userRoles.userId, userId), isNull(userRoles.revokedAt)))
      .returning({ id: userRoles.id });
    return rows.length;
  }
}
