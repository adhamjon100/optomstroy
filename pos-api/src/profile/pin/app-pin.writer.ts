import { Inject, Injectable } from '@nestjs/common';
import { eq, sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { appPins } from '../../db/schema/index.js';

export interface SetPinInput {
  readonly userId: string;
  /** PHC-строка Argon2id (PinHasher.hash) — PIN в открытом виде сюда не попадает (D-48, 09 §9.6). */
  readonly pinHash: string;
  readonly pepperVersion: number;
  readonly pinLength: number;
  readonly changedAt: Date;
}

/**
 * Запись `app_pins` (07 §5.13; D-48) владельцем PIN: установка/смена (`/registration/complete`, `POST /me/pin`) и
 * удаление (`DELETE /me/pin`). Чтение, проверка PIN, счётчик попыток и блокировка — `AppPinsRepository`/`PinVerifier`
 * модуля auth («установку/смену PIN выполняет модуль profile», auth/pin). Новый PIN сбрасывает счётчик и блокировку.
 */
@Injectable()
export class AppPinWriter {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async upsert(input: SetPinInput, ex: DbExecutor = this.db): Promise<void> {
    await ex
      .insert(appPins)
      .values({
        userId: input.userId,
        pinHash: input.pinHash,
        pepperVersion: input.pepperVersion,
        pinLength: input.pinLength,
        failedAttempts: 0,
        lockedUntil: null,
        changedAt: input.changedAt,
      })
      .onConflictDoUpdate({
        target: appPins.userId,
        set: {
          pinHash: input.pinHash,
          pepperVersion: input.pepperVersion,
          pinLength: input.pinLength,
          failedAttempts: 0,
          lockedUntil: null,
          changedAt: input.changedAt,
          updatedAt: sql`now()`,
        },
      });
  }

  async delete(userId: string, ex: DbExecutor = this.db): Promise<boolean> {
    const rows = await ex.delete(appPins).where(eq(appPins.userId, userId)).returning({ userId: appPins.userId });
    return rows.length === 1;
  }
}
