import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { notifications } from '../../db/schema/index.js';

/**
 * Уведомление администратору при отзыве согласия `personal_data` (08 §4.3.7: отзыв переводит аккаунт в `blocked`
 * «с подтверждением и уведомлением администратора»; D PR-06, бэклог E_spec_sync.md §3). In-app `notifications`
 * (`kind=system`, D-41) каждому активному `admin`, кроме самого пользователя, — в транзакции отзыва. Тело без ПДн
 * (ни телефона, ни ФИО: SEC-030, 11 §10.3), перехода нет (`payload.target = null`; цели перечислены в контракте
 * `Notification.payload.target`), идентификатор учётной записи — `payload.userId` для поиска в SCR-45.
 * Повтор (тот же отзыв) не плодит уведомлений: `dedupe_key` по записи согласия.
 */
@Injectable()
export class ConsentRevocationNotifier {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async personalDataRevoked(userId: string, consentId: string, ex: DbExecutor = this.db): Promise<number> {
    const res = await ex.execute<{ id: string }>(sql`
      SELECT DISTINCT u.id
        FROM users u
        JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL
        JOIN roles r ON r.id = ur.role_id AND r.code = 'admin'
       WHERE u.status = 'active' AND u.deleted_at IS NULL AND u.id <> ${userId}::uuid
       ORDER BY u.id`);
    const admins = res.rows.map((r) => r.id);
    if (admins.length === 0) return 0;
    const rows = await ex
      .insert(notifications)
      .values(
        admins.map((adminId) => ({
          userId: adminId,
          kind: 'system' as const,
          severity: 'warning',
          titleRu: 'Отозвано согласие на обработку персональных данных',
          bodyRu:
            'Пользователь отозвал согласие на обработку персональных данных, учётная запись заблокирована. ' +
            'Подробности — в журнале аудита и карточке пользователя.',
          payload: { target: null, userId, reason: 'consent_personal_data_revoked' },
          dedupeKey: `consent.personal_data.revoked:${consentId}`,
        })),
      )
      .onConflictDoNothing()
      .returning({ id: notifications.id });
    return rows.length;
  }
}
