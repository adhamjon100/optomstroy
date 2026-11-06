import { Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { AuditContext } from '../common/audit/audit-context.js';
import { AuditService } from '../common/audit/audit.service.js';
import type { DbExecutor } from '../common/audit/db-executor.js';
import { assertCartTransition } from '../sales-domain/index.js';
import { rows } from './cart-common.js';
import { assertDomain } from './cart.service.js';

/** Корзина технического пользователя планшета, закрытая шагом жизненного цикла планшета. */
export interface KioskCartClosed {
  readonly cartId: string;
  readonly itemsCount: number;
}

/** Причина закрытия (`after.reason` аудита `cart.cleared`): подключение заново (08 §4.18.15). */
export type KioskCartCloseReason = 'kiosk_reconnect';

/**
 * Закрытие корзин планшета магазина в транзакции вызывающего (экспорт модуля `cart` — MOD-024: `carts.status` пишет
 * только `cart`; ADR-115). Тот же шаг, что у сброса `POST /kiosk/reset` (`CartService.resetForKiosk`): переход
 * `active → cleared` (`assertCartTransition`, ядро §22), `cleared_at`, `row_version + 1`, аудит `cart.cleared` на
 * каждую закрытую корзину — без номера покупателя и кода, только `carts.id` и число позиций (11 §7.2). Новую пустую
 * корзину не создаёт: её создаёт первый `GET /cart` новой сессии (`ensureActive`, новый `id`).
 *
 * Применение — «Подключить заново» (`StoreTabletsService.reconnect`, 08 §4.18.15): технический пользователь
 * (`users.id`) тот же, поэтому корзина, оставшаяся после отключения, аварийного выхода или истёкшей сессии
 * посреди покупки, иначе вернулась бы следующему покупателю (04 FLOW-045.A1 «корзина прошлого покупателя не
 * показывается никогда»; P-002 §15). Порядок блокировок вызывающего — «коды `kiosk_order` → корзина»
 * (`gashKioskCodes` раньше), как у сброса и заявки.
 */
@Injectable()
export class KioskCartCloser {
  constructor(private readonly audit: AuditService) {}

  async closeActiveOfTablet(
    tx: DbExecutor,
    ctx: AuditContext,
    input: { readonly tabletUserId: string; readonly reason: KioskCartCloseReason; readonly now: Date },
  ): Promise<readonly KioskCartClosed[]> {
    assertDomain(() => assertCartTransition('active', 'cleared', 'clear'));
    const closed = await rows<{ id: string; items_count: number }>(
      tx,
      sql`UPDATE carts c
             SET status = 'cleared', cleared_at = ${input.now.toISOString()}::timestamptz,
                 row_version = c.row_version + 1, updated_at = now()
           WHERE c.owner_user_id = ${input.tabletUserId}::uuid AND c.status = 'active'
       RETURNING c.id::text AS id, (SELECT count(*)::int FROM cart_items i WHERE i.cart_id = c.id) AS items_count`,
    );
    const out: KioskCartClosed[] = [];
    for (const c of closed) {
      await this.audit.write(
        ctx,
        {
          action: 'cart.cleared',
          entityType: 'cart',
          entityId: c.id,
          after: { cartId: c.id, itemsCount: c.items_count, parked: false, reason: input.reason },
        },
        tx,
      );
      out.push({ cartId: c.id, itemsCount: c.items_count });
    }
    return out;
  }
}
