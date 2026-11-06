import { Inject, Injectable } from '@nestjs/common';
import { and, eq } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { storeTablets, userProfiles } from '../../db/schema/index.js';

/**
 * Планшет магазина текущего запроса (`req.kiosk`; 06 §7.4 п. (1) «действующая строка `store_tablets` кладётся в
 * контекст запроса»): строка `store_tablets` со статусом `active` технического пользователя `kind=kiosk` и его
 * профиль. Имя и склад планшета хранятся в `user_profiles` (07 §5.65), в `store_tablets` не дублируются.
 */
export interface KioskTabletContext {
  /** `store_tablets.id`. */
  readonly tabletId: string;
  /** `users.id` технического пользователя (`kind=kiosk`). */
  readonly userId: string;
  /** `store_tablets.device_id` (`devices.id`). */
  readonly deviceId: string;
  /** Имя планшета — `user_profiles.full_name`. */
  readonly name: string;
  /**
   * Склад планшета — только `user_profiles.home_warehouse_id` (ADR-115 п. 23): `null` — не задан; запасного склада
   * нет (ветки каталога и корзины отвечают `403`, `reason: kiosk_warehouse_unavailable`).
   */
  readonly warehouseId: string | null;
}

/** Запрос после `KioskAccessGuard`: у субъекта `kind=kiosk` — действующий планшет. */
export type KioskRequest = RequestWithContext & { kiosk?: KioskTabletContext };

/** Планшет из контекста запроса (заполняет `KioskAccessGuard`); у сотрудника и покупателя — `undefined`. */
export function kioskTabletOf(req: RequestWithContext): KioskTabletContext | undefined {
  return (req as KioskRequest).kiosk;
}

/**
 * Чтение планшета по техническому пользователю (`store_tablets_user_id_uq` — один планшет на пользователя). Только
 * строка `status='active'` с профилем; отключённый или неполный планшет — `null` (запрос отклоняется).
 */
@Injectable()
export class KioskTabletReader {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async findActiveByUserId(userId: string, ex: DbExecutor = this.db): Promise<KioskTabletContext | null> {
    const rows = await ex
      .select({
        tabletId: storeTablets.id,
        userId: storeTablets.userId,
        deviceId: storeTablets.deviceId,
        name: userProfiles.fullName,
        warehouseId: userProfiles.homeWarehouseId,
      })
      .from(storeTablets)
      .innerJoin(userProfiles, eq(userProfiles.userId, storeTablets.userId))
      .where(and(eq(storeTablets.userId, userId), eq(storeTablets.status, 'active')))
      .limit(1);
    return rows[0] ?? null;
  }
}
