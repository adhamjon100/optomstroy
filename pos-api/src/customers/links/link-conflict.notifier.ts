import { Inject, Injectable } from '@nestjs/common';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { notifications } from '../../db/schema/index.js';
import { CustomerLinksRepository } from './customer-links.repository.js';

/**
 * «Задача администратору» при `conflict` (09 §7.8 п. 3, SRC-B-146; 13 RM-D-005 критерий 2): in-app уведомление
 * (`notifications`, D-41) каждому активному `admin`. Тело без ПДн (телефона и наименований нет), переход —
 * `payload.target = customer_link` → SCR-45 «Привязки клиентов» (08 §3.13, ядро §19.2). Дедупликация — по
 * пользователю-клиенту: повторный поиск не плодит уведомлений, пока прежнее не удалено.
 */
@Injectable()
export class LinkConflictNotifier {
  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    private readonly links: CustomerLinksRepository,
  ) {}

  async notifyConflict(subjectUserId: string, linkIds: readonly string[], ex: DbExecutor = this.db): Promise<number> {
    const admins = await this.links.activeAdminIds(ex);
    if (admins.length === 0) return 0;
    const rows = await ex
      .insert(notifications)
      .values(
        admins.map((adminId) => ({
          userId: adminId,
          kind: 'system' as const,
          severity: 'warning',
          titleRu: 'Конфликт привязки клиента',
          bodyRu: 'Номер клиента найден у нескольких карточек 1С. Выберите карточку или отклоните привязки.',
          payload: { target: 'customer_link', userId: subjectUserId, linkIds: [...linkIds] },
          dedupeKey: `customer_link.conflict:${subjectUserId}`,
        })),
      )
      .onConflictDoNothing()
      .returning({ id: notifications.id });
    return rows.length;
  }
}
