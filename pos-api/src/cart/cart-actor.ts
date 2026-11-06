import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import {
  bySubjectKind,
  isBuyerLike,
  isSubjectKind,
  type SubjectKind,
  switchSubjectKind,
} from '../common/auth/subject-kind.js';
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

/**
 * Показ остатков (08 §3.6, 10 CUST-022): staff — `full`; customer и планшет магазина (`kiosk`, 10 KIOSK-007) — `status`
 * или `quantity` (`app_settings.customer_stock_display`).
 */
export type StockDisplay = 'full' | 'status' | 'quantity';

export const LOW_STOCK_THRESHOLD_DEFAULT = '5';

/** Кто работает с корзиной и по каким правилам (вычисляется на запрос / вызов порта). */
export interface CartActor {
  readonly userId: string;
  /** Активная роль (R1 — одна, 08 §2.2). */
  readonly role: string;
  readonly roles: readonly string[];
  /**
   * Ветка покупателя (ядро §24.2): режим клиента-покупателя `customer` или планшет магазина `kiosk` — покупатель без
   * привязки (без скидок, клиента, отложенных корзин; 11 SEC-137 (6)).
   */
  readonly isCustomer: boolean;
  /**
   * Вид субъекта (06 ARCH-065; `SubjectKind`): `kiosk` — планшет магазина (склад планшета закреплён, без клиента).
   * Задаёт `CartActorResolver` всегда; не задан — актор, собранный вне резолвера (вид по `isCustomer`).
   */
  readonly subjectKind?: SubjectKind;
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

/** Планшет магазина (`kind=kiosk`, ADR-115): склад планшета закреплён, клиента в корзине нет (10 KIOSK-009). */
export function isKioskActor(a: Pick<CartActor, 'subjectKind'>): boolean {
  return a.subjectKind !== undefined && bySubjectKind(a.subjectKind, { staff: false, customer: false, kiosk: true });
}

/**
 * Контекст корзины из субъекта запроса (`req.principal`) или актора порта (`SalesActor`): права — каталог RBAC
 * (11 §4.3, deny by default), режим клиента — `kind=customer` (при `CUSTOMER_SELF_SERVICE=false` → `403`, 10 CASH-006),
 * показ остатков клиенту — `customer_stock_display` (ядро §24.2). Вид субъекта — исчерпывающе (06 ARCH-065): планшет
 * магазина `kind=kiosk` — ветка покупателя без привязки (`isCustomer = true`), но правило «режим клиента выключен» к
 * нему не относится — только `KIOSK_MODE` (06 ARCH-067; иначе `403 KIOSK_DISABLED`); вид вне перечня — `403`.
 */
@Injectable()
export class CartActorResolver {
  constructor(
    private readonly permissions: PermissionCatalog,
    private readonly settings: SettingsReader,
    @Inject(APP_CONFIG)
    private readonly config: Pick<AppConfig, 'CUSTOMER_SELF_SERVICE'> & Partial<Pick<AppConfig, 'KIOSK_MODE'>>,
    @Inject(DRIZZLE) private readonly db: DbExecutor,
  ) {}

  async fromPrincipal(principal: Principal | undefined, requestId?: string | null): Promise<CartActor> {
    if (!principal) throw new ProblemException('UNAUTHENTICATED', { detail: 'Требуется вход.' });
    if (!isSubjectKind(principal.kind)) {
      throw new ProblemException('FORBIDDEN', { detail: 'Недостаточно прав для операции.' });
    }
    return this.build({
      userId: principal.userId,
      roles: principal.roles,
      subjectKind: withCustomerRole(principal.kind, principal.roles),
      status: principal.status,
      sessionId: principal.sessionId ?? null,
      deviceId: principal.deviceId ?? null,
      requestId: requestId ?? null,
    });
  }

  async fromSalesActor(actor: SalesActor): Promise<CartActor> {
    if (actor.userId === null) throw new Error('cart: операция корзины требует пользователя (SalesActor.userId)');
    // Вид — `SalesActor.subjectKind` (актор планшета задаёт его всегда); построители до ADR-115 — по `isCustomer`.
    const declared = actor.subjectKind ?? (actor.isCustomer ? 'customer' : 'staff');
    return this.build({
      userId: actor.userId,
      roles: actor.roles,
      subjectKind: withCustomerRole(declared, actor.roles),
      sessionId: actor.sessionId ?? null,
      deviceId: actor.deviceId ?? null,
      requestId: actor.requestId ?? null,
    });
  }

  private async build(i: {
    userId: string;
    roles: readonly string[];
    subjectKind: SubjectKind;
    status?: 'active' | 'pending_activation';
    sessionId: string | null;
    deviceId: string | null;
    requestId: string | null;
  }): Promise<CartActor> {
    switchSubjectKind(i.subjectKind, {
      staff: () => undefined,
      customer: () => {
        if (!this.config.CUSTOMER_SELF_SERVICE) {
          throw new ProblemException('FORBIDDEN', { detail: 'Режим клиента выключен.' });
        }
      },
      kiosk: () => {
        if (this.config.KIOSK_MODE !== true) {
          throw new ProblemException('KIOSK_DISABLED', {
            detail: 'Сервис временно недоступен. Обратитесь к продавцу.',
          });
        }
      },
    });
    const isCustomer = isBuyerLike(i.subjectKind);
    const [display, threshold] = await Promise.all([
      isCustomer ? this.settings.get('customer_stock_display') : Promise.resolve('full'),
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
      role: i.roles[0] ?? (isCustomer ? 'customer' : ''),
      roles: i.roles,
      isCustomer,
      subjectKind: i.subjectKind,
      // Вид — для кодов, привязанных к виду (11 SEC-138: `kiosk.*` засчитываются только при kind=kiosk).
      permissions: this.permissions.effectivePermissions({
        roles: i.roles,
        kind: i.subjectKind,
        ...(i.status ? { status: i.status } : {}),
      }),
      stockDisplay: isCustomer ? (display === 'quantity' ? 'quantity' : 'status') : 'full',
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

  /** `SalesActor` для портов (кредитное решение, проверка наличия и т. п.); вид субъекта — дальше по цепочке. */
  toSalesActor(a: CartActor): SalesActor {
    return {
      userId: a.userId,
      roles: a.roles,
      isCustomer: a.isCustomer,
      ...(a.subjectKind ? { subjectKind: a.subjectKind } : {}),
      sessionId: a.sessionId,
      deviceId: a.deviceId,
      requestId: a.requestId,
    };
  }
}

/**
 * Роль `customer` при виде `staff` — ветка покупателя, как до ADR-115 (вид `customer` или роль `customer`); покупатель
 * и планшет магазина — как есть.
 */
function withCustomerRole(kind: SubjectKind, roles: readonly string[]): SubjectKind {
  return switchSubjectKind<SubjectKind>(kind, {
    staff: () => (roles.includes('customer') ? 'customer' : 'staff'),
    customer: () => 'customer',
    kiosk: () => 'kiosk',
  });
}
