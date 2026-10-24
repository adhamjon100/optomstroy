import { Inject, Injectable } from '@nestjs/common';
import { and, eq, isNull, sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { devices, sessions } from '../../db/schema/index.js';
import type { DeviceRow, SessionAmr, SessionRow } from '../../users/users.types.js';

export interface RotationPatch {
  readonly newRefreshHash: Buffer;
  readonly now: Date;
  readonly idleExpiresAt: Date;
  readonly unlockedUntil?: Date | null;
  readonly amr?: readonly SessionAmr[];
  readonly ip?: string | null;
}

/**
 * Операции политики сессий модуля auth над `sessions` (09 §8.2–§8.3, §5.6) с метками времени из `CLOCK`
 * (окно грации, «токен ещё не использовался» и idle-сроки сравниваются по одним часам — тесты с подменой часов,
 * 12 T-SESS-006/008/023). Базовые операции (create, revoke, list) — src/users SessionsRepository.
 */
@Injectable()
export class SessionStore {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async findByPrevHashForUpdate(hash: Buffer, ex: DbExecutor = this.db): Promise<SessionRow | undefined> {
    const rows = await ex.select().from(sessions).where(eq(sessions.prevRefreshHash, hash)).limit(1).for('update');
    return rows[0];
  }

  async findBySupersededHashForUpdate(hash: Buffer, ex: DbExecutor = this.db): Promise<SessionRow | undefined> {
    const rows = await ex
      .select()
      .from(sessions)
      .where(eq(sessions.supersededRefreshHash, hash))
      .limit(1)
      .for('update');
    return rows[0];
  }

  async findCreatedFromChallenge(challengeId: string, ex: DbExecutor = this.db): Promise<SessionRow[]> {
    return ex.select().from(sessions).where(eq(sessions.createdFromChallengeId, challengeId)).for('update');
  }

  async findWithDevice(
    sessionId: string,
    ex: DbExecutor = this.db,
  ): Promise<{ session: SessionRow; device: DeviceRow } | undefined> {
    const rows = await ex
      .select({ session: sessions, device: devices })
      .from(sessions)
      .innerJoin(devices, eq(devices.id, sessions.deviceId))
      .where(eq(sessions.id, sessionId))
      .limit(1);
    return rows[0];
  }

  async listActiveWithDevices(
    userId: string,
    now: Date,
    ex: DbExecutor = this.db,
  ): Promise<{ session: SessionRow; device: DeviceRow }[]> {
    return ex
      .select({ session: sessions, device: devices })
      .from(sessions)
      .innerJoin(devices, eq(devices.id, sessions.deviceId))
      .where(
        and(
          eq(sessions.userId, userId),
          isNull(sessions.revokedAt),
          sql`${sessions.expiresAt} > ${now.toISOString()}::timestamptz`,
          sql`${sessions.idleExpiresAt} > ${now.toISOString()}::timestamptz`,
        ),
      )
      .orderBy(sql`${sessions.issuedAt} DESC`);
  }

  /**
   * Обычная ротация (CAS по `refresh_hash`): `prev ← current`, `current ← new`, грация сбрасывается,
   * `last_used_at = NULL` (новый токен ещё не использовался; время ротации — `rotated_at`).
   */
  async rotate(
    id: string,
    expectedHash: Buffer,
    p: RotationPatch,
    ex: DbExecutor = this.db,
  ): Promise<SessionRow | undefined> {
    const rows = await ex
      .update(sessions)
      .set({
        prevRefreshHash: sql`${sessions.refreshHash}`,
        refreshHash: p.newRefreshHash,
        rotatedAt: p.now,
        // NULL = «выданный сейчас токен ещё не использовался» (09 §8.3); первый запрос с новым access или
        // следующий refresh отмечает использование (SessionActivityGuard / rotate).
        lastUsedAt: null,
        graceUsedAt: null,
        idleExpiresAt: p.idleExpiresAt,
        ...(p.unlockedUntil !== undefined ? { unlockedUntil: p.unlockedUntil } : {}),
        ...(p.amr ? { amr: [...p.amr] } : {}),
        ...(p.ip ? { ipLast: p.ip } : {}),
        updatedAt: p.now,
      })
      .where(and(eq(sessions.id, id), eq(sessions.refreshHash, expectedHash), isNull(sessions.revokedAt)))
      .returning();
    return rows[0];
  }

  /**
   * Ротация «вбок» — окно грации (09 §8.3), повтор verify (§5.6), `refresh_replay` + PIN: действующий токен
   * вытесняется в `superseded_refresh_hash` (его предъявление далее — reuse), выдаётся новый; `prev` не меняется.
   */
  async rotateAside(id: string, p: RotationPatch, ex: DbExecutor = this.db): Promise<SessionRow | undefined> {
    const rows = await ex
      .update(sessions)
      .set({
        supersededRefreshHash: sql`${sessions.refreshHash}`,
        refreshHash: p.newRefreshHash,
        graceUsedAt: p.now,
        lastUsedAt: null,
        idleExpiresAt: p.idleExpiresAt,
        ...(p.unlockedUntil !== undefined ? { unlockedUntil: p.unlockedUntil } : {}),
        ...(p.amr ? { amr: [...p.amr] } : {}),
        ...(p.ip ? { ipLast: p.ip } : {}),
        updatedAt: p.now,
      })
      .where(and(eq(sessions.id, id), isNull(sessions.revokedAt)))
      .returning();
    return rows[0];
  }

  /**
   * Активность access-токена (SessionActivityGuard): `last_used_at` (признак «текущий токен использовался» для
   * reuse-detection) и продление `unlocked_until` (09 §8.8: активность продлевает разблокировку Windows).
   */
  async touchActivity(
    id: string,
    now: Date,
    idleLockMinutes: number,
    ip: string | null,
    ex: DbExecutor = this.db,
  ): Promise<void> {
    const extended = new Date(now.getTime() + idleLockMinutes * 60_000).toISOString();
    await ex
      .update(sessions)
      .set({
        lastUsedAt: now,
        unlockedUntil: sql`CASE WHEN ${sessions.unlockedUntil} > ${now.toISOString()}::timestamptz
                                THEN ${extended}::timestamptz ELSE ${sessions.unlockedUntil} END`,
        ...(ip ? { ipLast: ip } : {}),
        updatedAt: now,
      })
      .where(and(eq(sessions.id, id), isNull(sessions.revokedAt)));
  }

  async renameDevice(deviceId: string, displayName: string, now: Date, ex: DbExecutor = this.db): Promise<void> {
    await ex.update(devices).set({ displayName, updatedAt: now }).where(eq(devices.id, deviceId));
  }
}
