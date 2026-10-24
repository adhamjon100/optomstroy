import { Inject, Injectable } from '@nestjs/common';
import { and, eq, isNull, sql } from 'drizzle-orm';
import type { DbExecutor } from '../common/audit/db-executor.js';
import { DRIZZLE } from '../common/db/database.module.js';
import { users } from '../db/schema/index.js';
import type { UserKind, UserRow, UserStatusValue } from './users.types.js';

export interface CreateUserInput {
  readonly phoneE164: string;
  readonly kind: UserKind;
  readonly status: UserStatusValue;
  readonly phoneVerifiedAt?: Date | null;
  readonly invitationId?: string | null;
}

/**
 * `users` (07 §5.1) — только доступ к данным, без HTTP и правил (их применяют auth/registration/admin).
 * Изменение `status`/`phone_e164` порождает аудит уровня БД (`trg_users_audit`) — вызывающий задаёт контекст
 * `applyAuditGucs(tx, …)` в начале транзакции.
 */
@Injectable()
export class UsersRepository {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async findById(id: string, ex: DbExecutor = this.db): Promise<UserRow | undefined> {
    const rows = await ex.select().from(users).where(eq(users.id, id)).limit(1);
    return rows[0];
  }

  /** Действующая (не удалённая) учётная запись по номеру E.164 (`users_phone_e164_uq` — частичный UNIQUE). */
  async findByPhone(phoneE164: string, ex: DbExecutor = this.db): Promise<UserRow | undefined> {
    const rows = await ex
      .select()
      .from(users)
      .where(and(eq(users.phoneE164, phoneE164), isNull(users.deletedAt)))
      .limit(1);
    return rows[0];
  }

  async create(input: CreateUserInput, ex: DbExecutor = this.db): Promise<UserRow> {
    const rows = await ex
      .insert(users)
      .values({
        phoneE164: input.phoneE164,
        kind: input.kind,
        status: input.status,
        phoneVerifiedAt: input.phoneVerifiedAt ?? null,
        invitationId: input.invitationId ?? null,
      })
      .returning();
    const row = rows[0];
    if (!row) throw new Error('users.create: INSERT не вернул строку');
    return row;
  }

  /** Смена статуса; `blocked` — с `blocked_at/blocked_by_user_id/block_reason`, иначе эти поля очищаются. */
  async setStatus(
    id: string,
    status: UserStatusValue,
    meta: { readonly blockedByUserId?: string | null; readonly blockReason?: string | null; readonly at?: Date } = {},
    ex: DbExecutor = this.db,
  ): Promise<UserRow | undefined> {
    const at = meta.at ?? new Date();
    const blocked = status === 'blocked';
    const rows = await ex
      .update(users)
      .set({
        status,
        blockedAt: blocked ? at : null,
        blockedByUserId: blocked ? (meta.blockedByUserId ?? null) : null,
        blockReason: blocked ? (meta.blockReason ?? null) : null,
        updatedAt: at,
      })
      .where(eq(users.id, id))
      .returning();
    return rows[0];
  }

  /**
   * `permissions_version++` (09 §8.7: назначение/снятие роли, блокировка, активация, лимиты скидок роли) —
   * действующие access-токены получат `TOKEN_STALE` (кэш AuthGuard ≤ 60 с). Возвращает новую версию.
   */
  async bumpPermissionsVersion(id: string, ex: DbExecutor = this.db): Promise<number | undefined> {
    const rows = await ex
      .update(users)
      .set({ permissionsVersion: sql`${users.permissionsVersion} + 1`, updatedAt: sql`now()` })
      .where(eq(users.id, id))
      .returning({ v: users.permissionsVersion });
    return rows[0]?.v;
  }

  async touchLastLogin(id: string, at: Date = new Date(), ex: DbExecutor = this.db): Promise<void> {
    await ex.update(users).set({ lastLoginAt: at, updatedAt: at }).where(eq(users.id, id));
  }

  async markPhoneVerified(id: string, at: Date = new Date(), ex: DbExecutor = this.db): Promise<void> {
    await ex.update(users).set({ phoneVerifiedAt: at, updatedAt: at }).where(eq(users.id, id));
  }
}
