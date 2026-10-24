import { Inject, Injectable, Logger, Optional } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { DbExecutor } from '../common/audit/db-executor.js';
import { CLOCK, type Clock } from '../common/auth/clock.js';
import { APP_CONFIG, type AppConfig } from '../common/config/app-config.js';
import { DRIZZLE } from '../common/db/database.module.js';
import type { PaymentMethod } from '../common/enums.js';
import { isOnecError } from '../integrations/onec/onec-error.js';
import { ONEC_GATEWAY, type OnecGateway, type OnecJsonObject } from '../integrations/onec/onec-gateway.js';
import { qty3, rows } from './cart-common.js';
import type { CartItemRow, CartRow } from './cart.repository.js';
import type { LineQuote } from './catalog-pricing.service.js';

export interface OnecCheckResult {
  readonly performed: boolean;
  readonly at: Date | null;
  readonly result: 'ok' | 'unavailable' | 'rejected';
}

/** Повторное использование результата `/check` (05 SYNC-071: `POST /orders` в пределах 60 с не повторяет проверку). */
export const ONEC_CHECK_REUSE_MS = 60_000;

/**
 * Синхронная проверка корзины в 1С `POST /pos/v1/check` (05 §6; 08 §4.7.7 `onecCheck`; RM-F-012 —
 * `ONEC_SYNC_CHECK_TIMEOUT_MS` = 6000). Таймаут, сбой сети, 503/423 → `unavailable` (оформление не блокируется:
 * `POST /orders` → `202`, ядро §22.3); бизнес-отказ 4xx → `rejected`. Корзина при этом не меняется (без побочных
 * эффектов). Порт 1С — `ONEC_GATEWAY` (необязательный: без него проверка не выполняется).
 */
@Injectable()
export class OnecCheckService {
  private readonly logger = new Logger('cart.onec_check');
  private readonly cache = new Map<string, { at: Date; result: OnecCheckResult }>();

  constructor(
    @Inject(APP_CONFIG) private readonly config: Pick<AppConfig, 'ONEC_SYNC_CHECK_TIMEOUT_MS'>,
    @Inject(CLOCK) private readonly clock: Clock,
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    @Optional() @Inject(ONEC_GATEWAY) private readonly onec?: OnecGateway | null,
  ) {}

  async check(i: {
    readonly cart: CartRow;
    readonly items: readonly CartItemRow[];
    readonly quotes: readonly LineQuote[];
    readonly paymentMethod: PaymentMethod;
    readonly requestId?: string | null;
  }): Promise<OnecCheckResult> {
    if (!this.onec) return { performed: false, at: null, result: 'unavailable' };
    const key = `${i.cart.id}:${i.cart.row_version}:${i.paymentMethod}`;
    const now = this.clock.now();
    const hit = this.cache.get(key);
    if (hit && now.getTime() - hit.at.getTime() < ONEC_CHECK_REUSE_MS) return hit.result;
    const refs = await this.refs(i.cart);
    const request: OnecJsonObject = {
      customerRef: refs.customer,
      priceListRef: refs.priceList,
      warehouseRef: refs.warehouse,
      paymentMethod: i.paymentMethod,
      calculateDiscounts: false,
      lines: i.items.map((it, idx) => {
        const q = i.quotes[idx];
        return {
          productRef: q?.productOnecRef ?? null,
          variantRef: q?.variantOnecRef ?? null,
          packagingRef: q?.packagingOnecRef ?? null,
          quantity: qty3(it.quantity),
        };
      }),
    };
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.config.ONEC_SYNC_CHECK_TIMEOUT_MS);
    let result: OnecCheckResult;
    try {
      const res = await Promise.race([
        this.onec.checkCart(request, {
          signal: controller.signal,
          ...(i.requestId ? { requestId: i.requestId } : {}),
        }),
        new Promise<never>((_, reject) =>
          controller.signal.addEventListener('abort', () => reject(new Error('ONEC_CHECK_TIMEOUT')), { once: true }),
        ),
      ]);
      result = { performed: true, at: now, result: res.status >= 200 && res.status < 300 ? 'ok' : 'rejected' };
    } catch (e) {
      const unavailable = !isOnecError(e) || e.retryable || e.status === 0 || e.status >= 500;
      result = { performed: true, at: now, result: unavailable ? 'unavailable' : 'rejected' };
      this.logger.warn(
        {
          event: 'cart.onec_check.failed',
          cartId: i.cart.id,
          result: result.result,
          code: isOnecError(e) ? e.code : 'TIMEOUT',
        },
        'cart.onec_check.failed',
      );
    } finally {
      clearTimeout(timer);
    }
    this.cache.set(key, { at: now, result });
    if (this.cache.size > 1000) {
      for (const [k, v] of this.cache) if (now.getTime() - v.at.getTime() >= ONEC_CHECK_REUSE_MS) this.cache.delete(k);
    }
    return result;
  }

  private async refs(
    cart: CartRow,
  ): Promise<{ customer: string | null; priceList: string | null; warehouse: string | null }> {
    const r = await rows<{ customer: string | null; price_list: string | null; warehouse: string | null }>(
      this.db,
      sql`SELECT (SELECT onec_ref::text FROM customers WHERE id = ${cart.customer_id}::uuid) AS customer,
                 (SELECT onec_ref::text FROM price_lists WHERE id = ${cart.price_list_id}::uuid) AS price_list,
                 (SELECT onec_ref::text FROM warehouses WHERE id = ${cart.warehouse_id}::uuid) AS warehouse`,
    );
    return {
      customer: r[0]?.customer ?? null,
      priceList: r[0]?.price_list ?? null,
      warehouse: r[0]?.warehouse ?? null,
    };
  }
}
