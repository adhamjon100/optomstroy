import { Inject, Injectable } from '@nestjs/common';
import { and, desc, eq, gt, isNull } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { userInvitations } from '../../db/schema/index.js';

export type InvitationRow = typeof userInvitations.$inferSelect;

/**
 * Чтение и принятие приглашения сотрудника при первом входе по OTP (ядро §24.2; 09 §4.3 «Первый вход по
 * приглашению»; 07 §5.3). Создание/отзыв приглашений — модуль admin (RM-D-006, RM-D-017).
 */
@Injectable()
export class InvitationsReader {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  /** Действующее приглашение номера: `status=pending`, не отозвано, `expires_at > now` (блокировка строки). */
  async findActive(phoneE164: string, now: Date, ex: DbExecutor = this.db): Promise<InvitationRow | undefined> {
    const rows = await ex
      .select()
      .from(userInvitations)
      .where(
        and(
          eq(userInvitations.phoneE164, phoneE164),
          eq(userInvitations.status, 'pending'),
          isNull(userInvitations.revokedAt),
          gt(userInvitations.expiresAt, now),
        ),
      )
      .orderBy(desc(userInvitations.createdAt))
      .limit(1)
      .for('update');
    return rows[0];
  }

  async markAccepted(id: string, userId: string, now: Date, ex: DbExecutor = this.db): Promise<void> {
    await ex
      .update(userInvitations)
      .set({ status: 'accepted', acceptedUserId: userId, acceptedAt: now, updatedAt: now })
      .where(eq(userInvitations.id, id));
  }
}
