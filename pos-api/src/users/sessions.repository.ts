import { Inject, Injectable } from '@nestjs/common';
import { and, desc, eq, gt, isNull, ne, sql } from 'drizzle-orm';
import type { DbExecutor } from '../common/audit/db-executor.js';
import { DRIZZLE } from '../common/db/database.module.js';
import { newId } from '../common/ids/uuid.js';
import { sessions } from '../db/schema/index.js';
import type { SessionAmr, SessionKind, SessionRevokeReason, SessionRow, StepUpMethod } from './users.types.js';

export interface CreateSessionInput {
  readonly userId: string;
  /** `devices.id` (не `device_key`). */
  readonly deviceId: string;
  /** Семья refresh-токенов; по умолчанию — новая (= id первой сессии семьи не требуется). */
  readonly familyId?: string;
  /** SHA-256 refresh-токена (09 §8.2) — сам токен в БД не хранится. */
  readonly refreshHash: Buffer;
  readonly kind?: SessionKind;
  readonly expiresAt: Date;
  readonly idleExpiresAt: Date;
  readonly amr?: readonly SessionAmr[];
  readonly createdFromChallengeId?: string | null;
  readonly ipLast?: string | null;
  readonly userAgent?: string | null;
  readonly unlockedUntil?: Date | null;
}

export interface RotateSessionInput {
  /** Ожидаемый текущий хэш (compare-and-swap: параллельная ротация того же токена проиграет). */
  readonly expectedRefreshHash: Buffer;
  readonly newRefreshHash: Buffer;
  readonly idleExpiresAt: Date;
  readonly ipLast?: string | null;
  readonly amr?: readonly SessionAmr[];
  readonly unlockedUntil?: Date | null;
}

/**
 * `sessions` (07 §5.9; 09 §8.2–§8.3): только доступ к данным. Политику (сроки, окно грации, reuse-detection,
 * лимит устройств) применяет модуль auth/sessions (RM-D-003). `id` = claim `sid`.
 */
@Injectable()
export class SessionsRepository {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async create(input: CreateSessionInput, ex: DbExecutor = this.db): Promise<SessionRow> {
    const rows = await ex
      .insert(sessions)
      .values({
        userId: input.userId,
        deviceId: input.deviceId,
        familyId: input.familyId ?? newId(),
        refreshHash: input.refreshHash,
        kind: input.kind ?? 'standard',
        expiresAt: input.expiresAt,
        idleExpiresAt: input.idleExpiresAt,
        amr: [...(input.amr ?? ['sms'])],
        createdFromChallengeId: input.createdFromChallengeId ?? null,
        ipLast: input.ipLast ?? null,
        userAgent: input.userAgent ?? null,
        unlockedUntil: input.unlockedUntil ?? null,
      })
      .returning();
    const row = rows[0];
    if (!row) throw new Error('sessions.create: INSERT не вернул строку');
    return row;
  }

  async findById(id: string, ex: DbExecutor = this.db): Promise<SessionRow | undefined> {
    const rows = await ex.select().from(sessions).where(eq(sessions.id, id)).limit(1);
    return rows[0];
  }

  /** Сессия по хэшу действующего refresh (`sessions_refresh_hash_uq`). `forUpdate` — блокировка строки в транзакции. */
  async findByRefreshHash(hash: Buffer, ex: DbExecutor = this.db, forUpdate = false): Promise<SessionRow | undefined> {
    const q = ex.select().from(sessions).where(eq(sessions.refreshHash, hash)).limit(1);
    const rows = forUpdate ? await q.for('update') : await q;
    return rows[0];
  }

  /** Сессия, где хэш — предыдущий refresh (кандидат на reuse-detection или окно грации 09 §8.3). */
  async findByPrevRefreshHash(hash: Buffer, ex: DbExecutor = this.db): Promise<SessionRow | undefined> {
    const rows = await ex.select().from(sessions).where(eq(sessions.prevRefreshHash, hash)).limit(1);
    return rows[0];
  }

  /** Сессия, где хэш — вытесненный ротацией в окне грации/повтором verify (`superseded_refresh_hash`). */
  async findBySupersededHash(hash: Buffer, ex: DbExecutor = this.db): Promise<SessionRow | undefined> {
    const rows = await ex.select().from(sessions).where(eq(sessions.supersededRefreshHash, hash)).limit(1);
    return rows[0];
  }

  /**
   * Ротация refresh (compare-and-swap по `refresh_hash`): `prev_refresh_hash ← refresh_hash`,
   * `refresh_hash ← new`. `undefined` — токен уже ротирован/сессия отозвана (вызывающий решает: грация или reuse).
   */
  async rotate(id: string, input: RotateSessionInput, ex: DbExecutor = this.db): Promise<SessionRow | undefined> {
    const rows = await ex
      .update(sessions)
      .set({
        prevRefreshHash: sql`${sessions.refreshHash}`,
        refreshHash: input.newRefreshHash,
        rotatedAt: sql`now()`,
        lastUsedAt: sql`now()`,
        idleExpiresAt: input.idleExpiresAt,
        ...(input.ipLast ? { ipLast: input.ipLast } : {}),
        ...(input.amr ? { amr: [...input.amr] } : {}),
        ...(input.unlockedUntil !== undefined ? { unlockedUntil: input.unlockedUntil } : {}),
        updatedAt: sql`now()`,
      })
      .where(and(eq(sessions.id, id), eq(sessions.refreshHash, input.expectedRefreshHash), isNull(sessions.revokedAt)))
      .returning();
    return rows[0];
  }

  /** Поля окна грации / повтора verify (09 §5.6, §8.3): `superseded_refresh_hash`, `grace_used_at`. */
  async markGrace(
    id: string,
    patch: { readonly supersededRefreshHash?: Buffer | null; readonly graceUsedAt?: Date | null },
    ex: DbExecutor = this.db,
  ): Promise<void> {
    await ex
      .update(sessions)
      .set({ ...patch, updatedAt: sql`now()` })
      .where(eq(sessions.id, id));
  }

  /** Отзыв одной сессии (если ещё не отозвана). true — отозвана этим вызовом. */
  async revoke(id: string, reason: SessionRevokeReason, ex: DbExecutor = this.db): Promise<boolean> {
    const rows = await ex
      .update(sessions)
      .set({ revokedAt: sql`now()`, revokeReason: reason, updatedAt: sql`now()` })
      .where(and(eq(sessions.id, id), isNull(sessions.revokedAt)))
      .returning({ id: sessions.id });
    return rows.length === 1;
  }

  /** Отзыв всей семьи (reuse-detection, 09 §8.3). Возвращает id отозванных сессий. */
  async revokeFamily(familyId: string, reason: SessionRevokeReason, ex: DbExecutor = this.db): Promise<string[]> {
    const rows = await ex
      .update(sessions)
      .set({ revokedAt: sql`now()`, revokeReason: reason, updatedAt: sql`now()` })
      .where(and(eq(sessions.familyId, familyId), isNull(sessions.revokedAt)))
      .returning({ id: sessions.id });
    return rows.map((r) => r.id);
  }

  /**
   * Отзыв всех активных сессий пользователя (logout-all, блокировка, смена ролей/телефона); `exceptSessionId` —
   * оставить текущую; `kind` — только семьи данного вида (например, `biometric` при инвалидации ключа).
   */
  async revokeAllForUser(
    userId: string,
    reason: SessionRevokeReason,
    opts: { readonly exceptSessionId?: string; readonly kind?: SessionKind; readonly deviceId?: string } = {},
    ex: DbExecutor = this.db,
  ): Promise<string[]> {
    const conds = [eq(sessions.userId, userId), isNull(sessions.revokedAt)];
    if (opts.exceptSessionId) conds.push(ne(sessions.id, opts.exceptSessionId));
    if (opts.kind) conds.push(eq(sessions.kind, opts.kind));
    if (opts.deviceId) conds.push(eq(sessions.deviceId, opts.deviceId));
    const rows = await ex
      .update(sessions)
      .set({ revokedAt: sql`now()`, revokeReason: reason, updatedAt: sql`now()` })
      .where(and(...conds))
      .returning({ id: sessions.id });
    return rows.map((r) => r.id);
  }

  /** Активные (не отозванные и не истёкшие на `now`) сессии пользователя, новые первыми. */
  async listActive(userId: string, now: Date = new Date(), ex: DbExecutor = this.db): Promise<SessionRow[]> {
    return ex
      .select()
      .from(sessions)
      .where(and(eq(sessions.userId, userId), isNull(sessions.revokedAt), gt(sessions.expiresAt, now)))
      .orderBy(desc(sessions.issuedAt));
  }

  async touch(id: string, ip: string | null, ex: DbExecutor = this.db): Promise<void> {
    await ex
      .update(sessions)
      .set({ lastUsedAt: sql`now()`, ...(ip ? { ipLast: ip } : {}), updatedAt: sql`now()` })
      .where(eq(sessions.id, id));
  }

  async setStepUp(id: string, until: Date, method: StepUpMethod, ex: DbExecutor = this.db): Promise<void> {
    await ex
      .update(sessions)
      .set({ stepUpUntil: until, stepUpMethod: method, updatedAt: sql`now()` })
      .where(eq(sessions.id, id));
  }

  async setUnlockedUntil(id: string, until: Date | null, ex: DbExecutor = this.db): Promise<void> {
    await ex
      .update(sessions)
      .set({ unlockedUntil: until, updatedAt: sql`now()` })
      .where(eq(sessions.id, id));
  }
}
