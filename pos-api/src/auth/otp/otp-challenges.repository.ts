import { Inject, Injectable } from '@nestjs/common';
import { and, desc, eq, ne, sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { otpChallenges } from '../../db/schema/index.js';

export type OtpChallengeRow = typeof otpChallenges.$inferSelect;
export type OtpChallengeInsert = typeof otpChallenges.$inferInsert;
export type OtpPurpose = OtpChallengeRow['purpose'];
export type OtpStatus = OtpChallengeRow['status'];

/**
 * `otp_challenges` (07 §5.11; 09 §5.2): только HMAC кода (`code_hmac`) и `pepper_version`, без открытого кода.
 * Метки времени пишутся из `CLOCK` вызывающего (подмена часов в тестах — 12 T-AUTH-004).
 */
@Injectable()
export class OtpChallengesRepository {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async insert(values: OtpChallengeInsert, ex: DbExecutor = this.db): Promise<OtpChallengeRow> {
    const rows = await ex.insert(otpChallenges).values(values).returning();
    const row = rows[0];
    if (!row) throw new Error('otp_challenges.insert: INSERT не вернул строку');
    return row;
  }

  async findById(id: string, ex: DbExecutor = this.db, forUpdate = false): Promise<OtpChallengeRow | undefined> {
    const q = ex.select().from(otpChallenges).where(eq(otpChallenges.id, id)).limit(1);
    const rows = forUpdate ? await q.for('update') : await q;
    return rows[0];
  }

  /**
   * Перевод в `locked` ставит `locked_at = at` (миграция 0003; от него считается пауза номера 09 §5.4 — DQ-03),
   * если вызывающий не передал своё значение.
   */
  async update(
    id: string,
    patch: Partial<Omit<OtpChallengeInsert, 'id'>>,
    at: Date,
    ex: DbExecutor = this.db,
  ): Promise<OtpChallengeRow | undefined> {
    const lock = patch.status === 'locked' && patch.lockedAt === undefined ? { lockedAt: at } : {};
    const rows = await ex
      .update(otpChallenges)
      .set({ ...patch, ...lock, updatedAt: at })
      .where(eq(otpChallenges.id, id))
      .returning();
    return rows[0];
  }

  /** Последние челленджи номера и назначения (новые первыми), без `failed_delivery` (09 §6.8: не учитываются). */
  async recentDelivered(
    phoneE164: string,
    purpose: OtpPurpose,
    limit: number,
    ex: DbExecutor = this.db,
  ): Promise<OtpChallengeRow[]> {
    return ex
      .select()
      .from(otpChallenges)
      .where(
        and(
          eq(otpChallenges.phoneE164, phoneE164),
          eq(otpChallenges.purpose, purpose),
          ne(otpChallenges.status, 'failed_delivery'),
        ),
      )
      .orderBy(desc(otpChallenges.createdAt))
      .limit(limit);
  }

  /**
   * Перед выпуском нового кода: действующий (`status='sent'`) челлендж номера и назначения переводится в
   * `superseded` (или `expired`, если срок вышел) — частичный UNIQUE `otp_challenges_active_uq` (07 §5.11)
   * допускает один `sent` на `(phone_e164, purpose)` (см. D_spec_questions A-05).
   */
  async retireActive(phoneE164: string, purpose: OtpPurpose, at: Date, ex: DbExecutor = this.db): Promise<number> {
    const rows = await ex
      .update(otpChallenges)
      .set({
        status: sql`CASE WHEN ${otpChallenges.expiresAt} <= ${at.toISOString()}::timestamptz
                         THEN 'expired'::otp_status ELSE 'superseded'::otp_status END`,
        updatedAt: at,
      })
      .where(
        and(
          eq(otpChallenges.phoneE164, phoneE164),
          eq(otpChallenges.purpose, purpose),
          eq(otpChallenges.status, 'sent'),
        ),
      )
      .returning({ id: otpChallenges.id });
    return rows.length;
  }

  /** Блокировка номера на время транзакции (сериализация cooldown/лимитов одного номера). */
  async lockPhone(phoneE164: string, purpose: OtpPurpose, ex: DbExecutor): Promise<void> {
    await ex.execute(sql`SELECT pg_advisory_xact_lock(hashtextextended(${`otp:${purpose}:${phoneE164}`}, 0))`);
  }
}
