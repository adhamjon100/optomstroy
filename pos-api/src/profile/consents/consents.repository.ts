import { Inject, Injectable } from '@nestjs/common';
import { and, desc, eq, isNull, sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import type { ConsentKind } from '../../common/enums.js';
import { consents } from '../../db/schema/index.js';

export type ConsentRow = typeof consents.$inferSelect;

export interface InsertConsentInput {
  readonly userId: string;
  readonly kind: ConsentKind;
  readonly version: string;
  readonly textSha256: Buffer;
  readonly grantedAt: Date;
  /** `devices.id` — только для `biometrics_device` (07 §5.14). */
  readonly deviceRowId?: string | null;
  readonly ip?: string | null;
  readonly appVersion?: string | null;
  readonly otpChallengeId?: string | null;
}

/**
 * `consents` (07 §5.14, DATA-113): append-only по смыслу — отзыв ставит `revoked_at`, строки не удаляются
 * (доказательство согласия хранится 3 года после удаления пользователя). Активная запись на `(user, kind, device)`
 * одна (`consents_active_uq`, NULLS NOT DISTINCT).
 */
@Injectable()
export class ConsentsRepository {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async listForUser(userId: string, ex: DbExecutor = this.db): Promise<ConsentRow[]> {
    return ex.select().from(consents).where(eq(consents.userId, userId)).orderBy(desc(consents.grantedAt));
  }

  async findActive(
    userId: string,
    kind: ConsentKind,
    deviceRowId: string | null,
    ex: DbExecutor = this.db,
    forUpdate = false,
  ): Promise<ConsentRow | undefined> {
    const q = ex
      .select()
      .from(consents)
      .where(
        and(
          eq(consents.userId, userId),
          eq(consents.kind, kind),
          deviceRowId === null ? isNull(consents.deviceId) : eq(consents.deviceId, deviceRowId),
          isNull(consents.revokedAt),
        ),
      )
      .limit(1);
    const rows = forUpdate ? await q.for('update') : await q;
    return rows[0];
  }

  async insert(input: InsertConsentInput, ex: DbExecutor = this.db): Promise<ConsentRow> {
    const rows = await ex
      .insert(consents)
      .values({
        userId: input.userId,
        kind: input.kind,
        version: input.version,
        textSha256: input.textSha256,
        grantedAt: input.grantedAt,
        deviceId: input.deviceRowId ?? null,
        ip: input.ip ?? null,
        appVersion: input.appVersion ?? null,
        otpChallengeId: input.otpChallengeId ?? null,
      })
      .returning();
    const row = rows[0];
    if (!row) throw new Error('consents.insert: INSERT не вернул строку');
    return row;
  }

  async revoke(id: string, at: Date, ex: DbExecutor = this.db): Promise<ConsentRow | undefined> {
    const rows = await ex
      .update(consents)
      .set({ revokedAt: at, updatedAt: sql`now()` })
      .where(and(eq(consents.id, id), isNull(consents.revokedAt)))
      .returning();
    return rows[0];
  }
}
