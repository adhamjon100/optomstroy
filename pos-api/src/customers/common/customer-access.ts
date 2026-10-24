import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import type { CustomerLinkStatus } from '../../common/enums.js';
import type { Principal } from '../../common/http/request-context.js';
import type { CustomerFieldPolicy, SalesActor } from '../../common/ports/index.js';
import { PermissionCatalog } from '../../common/rbac/permission-catalog.js';
import { forbidden, notFound } from './customer-http.js';

/** Субъект запроса к данным клиентов: права, вид DTO и признак режима клиента-покупателя. */
export interface CustomerViewer {
  readonly userId: string;
  readonly isCustomer: boolean;
  readonly roles: readonly string[];
  readonly permissions: ReadonlySet<string>;
  readonly policy: CustomerFieldPolicy;
  /**
   * Широкий поиск (ядро §19.4, 11 SEC-042): от 4 цифр телефона / 2 букв имени, по коду и ИНН — у ролей с
   * `customer.receivables.read.summary`; без него (`seller`) — только полный номер или код клиента.
   */
  readonly wideSearch: boolean;
  readonly principal: Principal;
}

/** Последняя привязка пользователя-клиента к карточке (`customer_links`). */
export interface CustomerLinkRef {
  readonly customerId: string;
  readonly status: CustomerLinkStatus;
  readonly linkId: string;
}

/**
 * Права на данные клиента (08 §3.7; 10 CUST-001, DEBT-004; 11 §4.3–§4.4, SEC-030 (в), SEC-031): одна функция
 * политики полей на все ответы модуля `customers` (`GET /customers*`, `/search/customers`, `/favorites/customers`,
 * порт `CustomerReader`). Вид DTO — по роли (`seller` / `cashier`·`senior_seller` / `admin`·`owner` / `customer`),
 * суммы и детализация долга, история, избранное — по кодам прав `PermissionCatalog` (deny by default).
 * GQ-FND-01: «`customer.finance.read`» ядра = `customer.receivables.read.summary` каталога прав.
 */
@Injectable()
export class CustomerAccessService {
  constructor(
    private readonly catalog: PermissionCatalog,
    @Inject(APP_CONFIG) private readonly config: Pick<AppConfig, 'CUSTOMER_SELF_SERVICE'>,
    @Inject(DRIZZLE) private readonly db: DbExecutor,
  ) {}

  viewer(principal: Principal | undefined): CustomerViewer {
    if (!principal) forbidden();
    const permissions = this.catalog.effectivePermissions(principal) as ReadonlySet<string>;
    const isCustomer = principal.kind === 'customer' || principal.roles.includes('customer');
    return {
      userId: principal.userId,
      isCustomer,
      roles: principal.roles,
      permissions,
      policy: policyFor(principal.roles, permissions, isCustomer),
      wideSearch: !isCustomer && permissions.has('customer.receivables.read.summary'),
      principal,
    };
  }

  /** Полномочия субъекта порта (`SalesActor`) — те же правила, что у HTTP (по ролям, без статуса сессии). */
  policyForActor(actor: Pick<SalesActor, 'roles' | 'isCustomer'>): CustomerFieldPolicy {
    const permissions = this.catalog.effectivePermissions({ roles: actor.roles }) as ReadonlySet<string>;
    return policyFor(actor.roles, permissions, actor.isCustomer || actor.roles.includes('customer'));
  }

  /** Есть ли у субъекта порта право `code` (по ролям). */
  actorCan(actor: Pick<SalesActor, 'roles'>, code: string): boolean {
    return (this.catalog.effectivePermissions({ roles: actor.roles }) as ReadonlySet<string>).has(code);
  }

  /** Режим клиента выключен (`CUSTOMER_SELF_SERVICE=false`, 10 CASH-006) → `403 FORBIDDEN`. */
  assertSelfService(v: CustomerViewer): void {
    if (v.isCustomer && !this.config.CUSTOMER_SELF_SERVICE) forbidden();
  }

  /** Последняя привязка пользователя (`confirmed` — приоритетнее прочих). */
  async linkOf(userId: string, ex: DbExecutor = this.db): Promise<CustomerLinkRef | null> {
    const r = await ex.execute<{ id: string; customer_id: string; status: CustomerLinkStatus }>(sql`
      SELECT id, customer_id, status::text AS status FROM customer_links
       WHERE user_id = ${userId}::uuid
       ORDER BY (status = 'confirmed') DESC, updated_at DESC, id DESC
       LIMIT 1`);
    const row = r.rows[0];
    return row ? { customerId: row.customer_id, status: row.status, linkId: row.id } : null;
  }

  /**
   * Доступ к карточке `customerId`: сотрудник с `customer.read.basic` — любая существующая (`deleted_at IS NULL`);
   * `customer` — только своя при `customer_links.status = 'confirmed'`, иначе `404` (08 AC-API-179, не `403`).
   * Возвращает `linkId` для режима клиента.
   */
  async assertCardAccess(v: CustomerViewer, customerId: string, ex: DbExecutor = this.db): Promise<string | null> {
    this.assertSelfService(v);
    if (v.isCustomer) {
      const link = await this.linkOf(v.userId, ex);
      if (!link || link.status !== 'confirmed' || link.customerId !== customerId) notFound();
      await this.assertExists(customerId, ex);
      return link.linkId;
    }
    if (!v.permissions.has('customer.read.basic')) forbidden();
    await this.assertExists(customerId, ex);
    return null;
  }

  async assertExists(customerId: string, ex: DbExecutor = this.db): Promise<void> {
    const r = await ex.execute<{ id: string }>(
      sql`SELECT id FROM customers WHERE id = ${customerId}::uuid AND deleted_at IS NULL`,
    );
    if (!r.rows[0]) notFound();
  }
}

/** Политика полей по ролям и правам (08 §3.7, таблица; `CustomerFieldPolicy` порта `CustomerReader`). */
export function policyFor(
  roles: readonly string[],
  permissions: ReadonlySet<string>,
  isCustomer: boolean,
): CustomerFieldPolicy {
  if (isCustomer) {
    const own = permissions.has('customer.self.receivables.read');
    return {
      view: 'self',
      fullContacts: true,
      receivableAmounts: own,
      receivableDetail: own,
      history: permissions.has('customer.self.read'),
      favorites: false,
      serviceFields: false,
    };
  }
  const summary = permissions.has('customer.receivables.read.summary');
  const view: CustomerFieldPolicy['view'] =
    roles.includes('admin') || roles.includes('owner') ? 'admin' : summary ? 'cashier' : 'seller';
  return {
    view,
    fullContacts: view !== 'seller',
    receivableAmounts: summary,
    receivableDetail: permissions.has('customer.receivables.read.detail'),
    history: permissions.has('customer.history.read'),
    favorites: permissions.has('favorites.customers.manage'),
    serviceFields: true,
  };
}
