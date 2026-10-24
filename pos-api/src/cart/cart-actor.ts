import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { APP_CONFIG, type AppConfig } from '../common/config/app-config.js';
import type { DbExecutor } from '../common/audit/db-executor.js';
import { DRIZZLE } from '../common/db/database.module.js';
import type { Principal } from '../common/http/request-context.js';
import type { SalesActor } from '../common/ports/index.js';
import { ProblemException } from '../common/problem-details/problem.exception.js';
import { PermissionCatalog } from '../common/rbac/permission-catalog.js';
import type { PermissionCode } from '../common/rbac/permissions.generated.js';
import { SettingsReader } from '../common/settings/settings-reader.js';
import type { RoleDiscountLimit } from '../sales-domain/index.js';
import { rows } from './cart-common.js';

/** Показ остатков (08 §3.6, 10 CUST-022): staff — `full`; customer — `status` или `quantity` (`app_settings`). */
export type StockDisplay = 'full' | 'status' | 'quantity';

export const LOW_STOCK_THRESHOLD_DEFAULT = '5';

/** Кто работает с корзиной и по каким правилам (вычисляется на запрос / вызов порта). */
export interface CartActor {
  readonly userId: string;
  /** Активная роль (R1 — одна, 08 §2.2). */
  readonly role: string;
  readonly roles: readonly string[];
  /** Режим клиента-покупателя (ядро §24.2). */
  readonly isCustomer: boolean;
  readonly permissions: ReadonlySet<PermissionCode>;
  readonly stockDisplay: StockDisplay;
  /** Порог «мало» в базовых единицах (`app_settings.low_stock_threshold`). */
  readonly lowStockThreshold: string;
  readonly sessionId: string | null;
  readonly deviceId: string | null;
  readonly requestId: string | null;
}

export function can(a: CartActor, code: PermissionCode): boolean {
  return a.permissions.has(code);
}

/**
 * Контекст корзины из субъекта запроса (`req.principal`) или актора порта (`SalesActor`): права — каталог RBAC
 * (11 §4.3, deny by default), режим клиента — `kind=customer` (при `CUSTOMER_SELF_SERVICE=false` → `403`, 10 CASH-006),
 * показ остатков клиенту — `customer_stock_display` (ядро §24.2).
 */
@Injectable()
export class CartActorResolver {
  constructor(
    private readonly permissions: PermissionCatalog,
    private readonly settings: SettingsReader,
    @Inject(APP_CONFIG) private readonly config: Pick<AppConfig, 'CUSTOMER_SELF_SERVICE'>,
    @Inject(DRIZZLE) private readonly db: DbExecutor,
  ) {}

  async fromPrincipal(principal: Principal | undefined, requestId?: string | null): Promise<CartActor> {
    if (!principal) throw new ProblemException('UNAUTHENTICATED', { detail: 'Требуется вход.' });
    return this.build({
      userId: principal.userId,
      roles: principal.roles,
      isCustomer: principal.kind === 'customer' || principal.roles.includes('customer'),
      status: principal.status,
      sessionId: principal.sessionId ?? null,
      deviceId: principal.deviceId ?? null,
      requestId: requestId ?? null,
    });
  }

  async fromSalesActor(actor: SalesActor): Promise<CartActor> {
    if (actor.userId === null) throw new Error('cart: операция корзины требует пользователя (SalesActor.userId)');
    return this.build({
      userId: actor.userId,
      roles: actor.roles,
      isCustomer: actor.isCustomer || actor.roles.includes('customer'),
      sessionId: actor.sessionId ?? null,
      deviceId: actor.deviceId ?? null,
      requestId: actor.requestId ?? null,
    });
  }

  private async build(i: {
    userId: string;
    roles: readonly string[];
    isCustomer: boolean;
    status?: 'active' | 'pending_activation';
    sessionId: string | null;
    deviceId: string | null;
    requestId: string | null;
  }): Promise<CartActor> {
    if (i.isCustomer && !this.config.CUSTOMER_SELF_SERVICE) {
      throw new ProblemException('FORBIDDEN', { detail: 'Режим клиента выключен.' });
    }
    const [display, threshold] = await Promise.all([
      i.isCustomer ? this.settings.get('customer_stock_display') : Promise.resolve('full'),
      this.settings.get('low_stock_threshold'),
    ]);
    const thresholdText =
      typeof threshold === 'number' && Number.isInteger(threshold) && threshold >= 0
        ? String(threshold)
        : typeof threshold === 'string' && /^\d{1,9}$/.test(threshold)
          ? threshold
          : LOW_STOCK_THRESHOLD_DEFAULT;
    return {
      userId: i.userId,
      role: i.roles[0] ?? (i.isCustomer ? 'customer' : ''),
      roles: i.roles,
      isCustomer: i.isCustomer,
      permissions: this.permissions.effectivePermissions({
        roles: i.roles,
        ...(i.status ? { status: i.status } : {}),
      }),
      stockDisplay: i.isCustomer ? (display === 'quantity' ? 'quantity' : 'status') : 'full',
      lowStockThreshold: thresholdText,
      sessionId: i.sessionId,
      deviceId: i.deviceId,
      requestId: i.requestId,
    };
  }

  /** Лимит ручной скидки роли (`role_discount_limits`, 07 §5.34; ядро §22.10 — только по ролям). */
  async discountLimit(role: string, ex: DbExecutor = this.db): Promise<RoleDiscountLimit | null> {
    const r = await rows<{ max: string; can_approve: boolean; approve_max: string | null }>(
      ex,
      sql`SELECT max_percent::text AS max, can_approve_over_limit AS can_approve, approve_max_percent::text AS approve_max
            FROM role_discount_limits WHERE role::text = ${role}`,
    );
    const row = r[0];
    if (!row) return null;
    return { maxPercent: row.max, canApproveOverLimit: row.can_approve, approveMaxPercent: row.approve_max };
  }

  /** `SalesActor` для портов (кредитное решение и т. п.). */
  toSalesActor(a: CartActor): SalesActor {
    return {
      userId: a.userId,
      roles: a.roles,
      isCustomer: a.isCustomer,
      sessionId: a.sessionId,
      deviceId: a.deviceId,
      requestId: a.requestId,
    };
  }
}
