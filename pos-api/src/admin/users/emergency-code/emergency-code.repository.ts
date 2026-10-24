import { Injectable } from '@nestjs/common';
import { and, eq, sql } from 'drizzle-orm';
import type { DbExecutor } from '../../../common/audit/db-executor.js';
import { otpChallenges } from '../../../db/schema/index.js';

export interface InsertEmergencyChallenge {
  readonly id: string;
  readonly userId: string;
  readonly phoneE164: string;
  readonly codeHmac: Buffer;
  readonly salt: Buffer;
  readonly pepperVersion: number;
  readonly expiresAt: Date;
  readonly requestId: string | null;
  /** Выдавший администратор — `otp_challenges.issued_by_user_id` (миграция 0003; DQ-03 / adm A-08). */
  readonly issuedByUserId: string;
}

export interface IssueWindowStats {
  readonly count: number;
  /** Секунд до выхода самой старой выдачи из 24-часового окна (0 — окно пусто). */
  readonly retryAfterSec: number;
}

const ISSUED = 'auth.emergency_code.issued';

/**
 * Данные аварийного кода входа. Отметка «выдан администратором» — `otp_challenges.issued_by_user_id` (миграция 0003,
 * 09 §17 п. 19(а); CHECK: только челлендж входа без `sms_outbox`); запись аудита `auth.emergency_code.issued`
 * (`entity_id` = цель, `after.challengeId`) пишется в той же транзакции. Лимиты выдачи (3 на цель / 20 на
 * администратора за скользящие 24 ч) считаются по аудиту (append-only, время БД).
 */
@Injectable()
export class EmergencyCodeRepository {
  /** Выдачи за скользящие 24 ч (время БД): на цель (`entity_id`) либо администратором (`actor_user_id`). */
  async issuedInLastDay(
    by: { readonly targetUserId: string } | { readonly actorUserId: string },
    ex: DbExecutor,
  ): Promise<IssueWindowStats> {
    const filter =
      'targetUserId' in by
        ? sql`entity_type = 'user' AND entity_id = ${by.targetUserId}::uuid`
        : sql`actor_user_id = ${by.actorUserId}::uuid`;
    const res = await ex.execute<{ n: string | number; retry: string | number | null }>(sql`
      SELECT count(*) AS n,
             ceil(extract(epoch FROM (min(occurred_at) + interval '24 hours' - clock_timestamp())))::int AS retry
        FROM audit_logs
       WHERE action = ${ISSUED} AND result = 'ok' AND level = 'app'
         AND occurred_at > clock_timestamp() - interval '24 hours' AND ${filter}`);
    const row = res.rows[0];
    return { count: Number(row?.n ?? 0), retryAfterSec: Math.max(0, Number(row?.retry ?? 0)) };
  }

  /** Предыдущий живой челлендж входа номера → `superseded` (08 §4.18.10; `otp_challenges_active_uq`). */
  async supersedeLive(phoneE164: string, ex: DbExecutor): Promise<string[]> {
    const rows = await ex
      .update(otpChallenges)
      .set({ status: 'superseded', updatedAt: sql`now()` })
      .where(
        and(
          eq(otpChallenges.phoneE164, phoneE164),
          eq(otpChallenges.purpose, 'login_or_register'),
          eq(otpChallenges.status, 'sent'),
        ),
      )
      .returning({ id: otpChallenges.id });
    return rows.map((r) => r.id);
  }

  async insert(input: InsertEmergencyChallenge, ex: DbExecutor): Promise<void> {
    await ex.insert(otpChallenges).values({
      id: input.id,
      phoneE164: input.phoneE164,
      userId: input.userId,
      purpose: 'login_or_register',
      codeHmac: input.codeHmac,
      salt: input.salt,
      pepperVersion: input.pepperVersion,
      expiresAt: input.expiresAt,
      attempts: 0,
      status: 'sent',
      smsOutboxId: null,
      deviceKey: null,
      ip: null,
      requestId: input.requestId,
      issuedByUserId: input.issuedByUserId,
    });
  }
}
