import { Inject, Injectable } from '@nestjs/common';
import { and, eq, sql } from 'drizzle-orm';
import type { DbExecutor } from '../common/audit/db-executor.js';
import { DRIZZLE } from '../common/db/database.module.js';
import { userProfiles } from '../db/schema/index.js';
import type { UserProfileRow } from './users.types.js';

export interface CreateProfileInput {
  readonly userId: string;
  readonly fullName: string;
  readonly birthYear?: number | null;
  readonly activitySphere?: string | null;
  readonly displayName?: string | null;
  readonly locale?: string;
  readonly homeWarehouseId?: string | null;
}

export type ProfilePatch = Partial<
  Pick<
    UserProfileRow,
    'fullName' | 'birthYear' | 'activitySphere' | 'displayName' | 'locale' | 'settings' | 'homeWarehouseId'
  >
>;

/** `user_profiles` (07 §5.2): профиль приложения (не карточка клиента 1С — 09 §7.7). Оптимистичная блокировка — `row_version`. */
@Injectable()
export class UserProfilesRepository {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async findByUserId(userId: string, ex: DbExecutor = this.db): Promise<UserProfileRow | undefined> {
    const rows = await ex.select().from(userProfiles).where(eq(userProfiles.userId, userId)).limit(1);
    return rows[0];
  }

  async create(input: CreateProfileInput, ex: DbExecutor = this.db): Promise<UserProfileRow> {
    const rows = await ex
      .insert(userProfiles)
      .values({
        userId: input.userId,
        fullName: input.fullName,
        birthYear: input.birthYear ?? null,
        activitySphere: input.activitySphere ?? null,
        displayName: input.displayName ?? null,
        homeWarehouseId: input.homeWarehouseId ?? null,
        ...(input.locale ? { locale: input.locale } : {}),
      })
      .returning();
    const row = rows[0];
    if (!row) throw new Error('user_profiles.create: INSERT не вернул строку');
    return row;
  }

  /**
   * Обновление с проверкой `row_version` (если задан `expectedRowVersion`): несовпадение → `undefined`
   * (вызывающий отвечает 409 VERSION_CONFLICT). `row_version` увеличивается на 1.
   */
  async update(
    userId: string,
    patch: ProfilePatch,
    expectedRowVersion?: number,
    ex: DbExecutor = this.db,
  ): Promise<UserProfileRow | undefined> {
    const where =
      expectedRowVersion === undefined
        ? eq(userProfiles.userId, userId)
        : and(eq(userProfiles.userId, userId), eq(userProfiles.rowVersion, expectedRowVersion));
    const rows = await ex
      .update(userProfiles)
      .set({ ...patch, rowVersion: sql`${userProfiles.rowVersion} + 1`, updatedAt: sql`now()` })
      .where(where)
      .returning();
    return rows[0];
  }

  async setBiometricsEnabled(userId: string, enabled: boolean, ex: DbExecutor = this.db): Promise<void> {
    await ex
      .update(userProfiles)
      .set({ biometricsEnabled: enabled, rowVersion: sql`${userProfiles.rowVersion} + 1`, updatedAt: sql`now()` })
      .where(eq(userProfiles.userId, userId));
  }
}
