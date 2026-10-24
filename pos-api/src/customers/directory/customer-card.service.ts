import { Inject, Injectable } from '@nestjs/common';
import type { AuditContext } from '../../common/audit/audit-context.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import type { AuthenticatedPrincipal } from '../../common/auth/principal.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { CustomerLinksService } from '../links/customer-links.service.js';
import { CustomerAccessService, type CustomerViewer } from '../common/customer-access.js';
import { CustomerFinanceService, salesActorOf } from '../common/customer-finance.js';
import { notFound } from '../common/customer-http.js';
import { projectCustomer } from '../common/customer-projector.js';
import { loadContacts, loadCustomerRows } from '../common/customer-rows.js';

export const CARD_INCLUDES = ['receivable', 'discounts', 'links', 'contacts'] as const;
export type CardInclude = (typeof CARD_INCLUDES)[number];

/**
 * Карточка клиента `GET /customers/{id}` (08 §4.11.3; OpenAPI `customers_get`; 10 CUST-001…CUST-004; RM-G-001,
 * RM-G-014): ролевое представление `CustomerView*`; `customer` — только своя карточка при `confirmed`, иначе 404.
 * `include` (каждая часть дополнительно фильтруется правами):
 * - `receivable` — `ReceivableSummary` при праве на суммы (`customer.receivables.read.summary`; `customer` —
 *   `customer.self.receivables.read`), аудит `customer.debt_viewed` (объём `summary`) при каждом ответе с суммами;
 * - `discounts` — `CustomersDiscountsResponse` при `discount.rules.read`;
 * - `links` — привязки (`admin`/`owner` — все, `customer` — своя);
 * - `contacts` — контакты карточки ролям с полными контактами.
 * Адреса (`addresses[]`) — ролям с полными контактами всегда (контакты `kind = address`).
 */
@Injectable()
export class CustomerCardService {
  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    private readonly access: CustomerAccessService,
    private readonly finance: CustomerFinanceService,
    private readonly links: CustomerLinksService,
  ) {}

  async card(
    v: CustomerViewer,
    ctx: AuditContext,
    customerId: string,
    include: readonly CardInclude[],
    requestId: string | null,
  ): Promise<Record<string, unknown>> {
    await this.access.assertCardAccess(v, customerId);
    return this.render(v, ctx, customerId, include, requestId);
  }

  /** Представление карточки после проверки доступа (общая часть `GET /customers/{id}` и `POST /customers`). */
  async render(
    v: CustomerViewer,
    ctx: AuditContext,
    customerId: string,
    include: readonly CardInclude[],
    requestId: string | null,
  ): Promise<Record<string, unknown>> {
    const [row] = await loadCustomerRows(this.db, [customerId], v.policy.favorites ? v.userId : null);
    if (!row) notFound();
    const contacts = v.policy.fullContacts ? await loadContacts(this.db, row.id) : [];
    const receivable =
      include.includes('receivable') && v.policy.receivableAmounts ? await this.finance.receivableSummary(row) : null;
    const discounts =
      include.includes('discounts') && v.permissions.has('discount.rules.read')
        ? await this.finance.discountsBlock(row, salesActorOf(v, requestId), v.policy.receivableAmounts)
        : null;
    let links: Record<string, unknown>[] | null = null;
    if (include.includes('links') && (v.policy.view === 'admin' || v.policy.view === 'self')) {
      const res = await this.links.listLinks(v.principal as AuthenticatedPrincipal, row.id);
      links = res.items.map(({ user: _user, ...link }) => ({ ...link }));
    }
    if (receivable)
      await this.finance.debtViewed(ctx, row.id, {
        scope: 'summary',
        snapshotAt: receivable.asOf ?? null,
        via: 'card',
      });
    return projectCustomer(row, v.policy, {
      receivable,
      discounts,
      links,
      contacts: include.includes('contacts') ? contacts : null,
      addresses: contacts.filter((c) => c.kind === 'address').map((c) => c.value),
    });
  }
}
