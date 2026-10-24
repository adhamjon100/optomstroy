import { Inject, Injectable } from '@nestjs/common';
import { eq } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { appPins } from '../../db/schema/index.js';

export type AppPinRow = typeof appPins.$inferSelect;

/**
 * `app_pins` (07 §5.13; D-48): хэш Argon2id, версия pepper, счётчик неверных попыток подряд и блокировка.
 * Модуль auth читает строку и ведёт счётчики при проверке PIN (step-up, unlock); установку/смену PIN
 * (`POST /me/pin`) выполняет модуль profile (RM-D-004).
 */
@Injectable()
export class AppPinsRepository {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async find(userId: string, ex: DbExecutor = this.db, forUpdate = false): Promise<AppPinRow | undefined> {
    const q = ex.select().from(appPins).where(eq(appPins.userId, userId)).limit(1);
    const rows = forUpdate ? await q.for('update') : await q;
    return rows[0];
  }

  async exists(userId: string, ex: DbExecutor = this.db): Promise<boolean> {
    const rows = await ex.select({ u: appPins.userId }).from(appPins).where(eq(appPins.userId, userId)).limit(1);
    return rows.length === 1;
  }

  async setAttempts(
    userId: string,
    failedAttempts: number,
    lockedUntil: Date | null,
    at: Date,
    ex: DbExecutor = this.db,
  ): Promise<void> {
    await ex.update(appPins).set({ failedAttempts, lockedUntil, updatedAt: at }).where(eq(appPins.userId, userId));
  }

  async rehash(
    userId: string,
    v: { readonly pinHash: string; readonly pepperVersion: number },
    at: Date,
    ex: DbExecutor = this.db,
  ): Promise<void> {
    await ex
      .update(appPins)
      .set({ pinHash: v.pinHash, pepperVersion: v.pepperVersion, updatedAt: at })
      .where(eq(appPins.userId, userId));
  }
}
