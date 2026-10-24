import { Inject, Injectable } from '@nestjs/common';
import { type SQL, sql } from 'drizzle-orm';
import type { AuditContext } from '../../common/audit/audit-context.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import type { CustomerType } from '../../common/enums.js';
import type { CustomerViewer } from '../common/customer-access.js';
import { CustomerFinanceService } from '../common/customer-finance.js';
import { CustomerCursorCodec, forbidden, invalid } from '../common/customer-http.js';
import { parseCustomerQuery, sellerScopeError } from '../common/customer-match.js';
import { projectCustomer } from '../common/customer-projector.js';
import { LAST_ORDER_AT_SQL, loadCustomerRows } from '../common/customer-rows.js';
import { PhoneLookupSignal } from '../search/phone-lookup.signal.js';

export const CUSTOMERS_LIMIT_DEFAULT = 50;
export const CUSTOMERS_LIMIT_MAX = 200;

export type CustomersSort = 'name:asc' | 'lastOrderAt:desc';

export interface CustomersListQuery {
  readonly q?: string;
  readonly favorite?: boolean;
  readonly hasDebt?: boolean;
  readonly isOverdue?: boolean;
  readonly customerType?: CustomerType;
  readonly includeReceivable: boolean;
  readonly sort: CustomersSort;
  readonly limit: number;
  readonly cursor?: string;
}

/**
 * `GET /customers` без `linkStatus` (08 §4.11.1; OpenAPI `customers_list`; SCR-31 `/customers?q=&favorites=1&
 * withDebt=1`; RM-G-001): список клиентов с фильтрами `q` (правила глубины поиска по роли — как §4.5.4),
 * `favorite`, `hasDebt` (только `customer.receivables.read.summary`, иначе 403), `isOverdue`, `customerType`;
 * сортировка `name:asc` | `lastOrderAt:desc` (по сумме долга — нет), keyset с HMAC. Элементы — ролевой `Customer`
 * без сумм; `include=receivable` при праве — суммы с аудитом `customer.debt_viewed` по каждой карточке.
 * Без `q` список доступен ролям с широким поиском; `seller` обязан передать полный номер или код клиента
 * (иначе выборка всей базы обходила бы CUST-009) — `400 search_scope_role` (GQ-CUS-04).
 */
@Injectable()
export class CustomersListService {
  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    private readonly cursors: CustomerCursorCodec,
    private readonly finance: CustomerFinanceService,
    private readonly phoneLookups: PhoneLookupSignal,
  ) {}

  async list(
    v: CustomerViewer,
    ctx: AuditContext,
    q: CustomersListQuery,
  ): Promise<{ items: Record<string, unknown>[]; nextCursor: string | null; hasMore: boolean }> {
    if (q.hasDebt !== undefined && !v.policy.receivableAmounts) forbidden();
    const conds: SQL[] = [sql`c.deleted_at IS NULL`, sql`NOT c.deletion_mark`, sql`NOT c.is_retail_default`];
    let sellerNeedsCode = false;
    let byPhone = false;
    if (q.q !== undefined) {
      const m = parseCustomerQuery(q.q, v.wideSearch);
      conds.push(sql`${m.prio} IS NOT NULL`);
      sellerNeedsCode = m.sellerNeedsCode;
      byPhone = m.byPhone;
    } else if (!v.wideSearch) {
      sellerScopeError();
    }
    if (q.favorite === true) {
      conds.push(
        sql`EXISTS (SELECT 1 FROM favorites_customers f WHERE f.customer_id = c.id AND f.user_id = ${v.userId}::uuid)`,
      );
    }
    if (q.hasDebt !== undefined) conds.push(q.hasDebt ? sql`r.balance > 0` : sql`coalesce(r.balance, 0) <= 0`);
    if (q.isOverdue !== undefined) {
      conds.push(q.isOverdue ? sql`r.overdue_amount > 0` : sql`coalesce(r.overdue_amount, 0) <= 0`);
    }
    if (q.customerType) conds.push(sql`c.customer_type = ${q.customerType}::customer_type`);
    const scope = `customers:${q.sort}`;
    const after = this.cursors.decode(q.cursor, scope);
    const lastAt = sql`coalesce(${LAST_ORDER_AT_SQL}, '-infinity'::timestamptz)`;
    let order: SQL;
    let keyset: SQL = sql``;
    if (q.sort === 'name:asc') {
      order = sql`x.name, x.id`;
      if (after) {
        if (typeof after[0] !== 'string' || typeof after[1] !== 'string') this.badCursor();
        keyset = sql`WHERE (x.name, x.id) > (${after[0]}, ${after[1]}::uuid)`;
      }
    } else {
      order = sql`x.last_at DESC, x.id DESC`;
      if (after) {
        if (typeof after[0] !== 'string' || typeof after[1] !== 'string') this.badCursor();
        keyset = sql`WHERE (x.last_at, x.id) < (${after[0]}::timestamptz, ${after[1]}::uuid)`;
      }
    }
    const res = await this.db.execute<{ id: string; name: string; last_at: string }>(sql`
      SELECT x.id, x.name, x.last_at::text AS last_at FROM (
        SELECT c.id, c.name,
               ${q.sort === 'lastOrderAt:desc' ? lastAt : sql`'-infinity'::timestamptz`} AS last_at
          FROM customers c LEFT JOIN receivables r ON r.customer_id = c.id
         WHERE ${sql.join(conds, sql` AND `)}) x
       ${keyset}
       ORDER BY ${order}
       LIMIT ${q.limit + 1}`);
    if (sellerNeedsCode && res.rows.length === 0 && !after) sellerScopeError();
    // Сигнал скрейпинга `customer.phone_lookup` — общий с `GET /search/customers` (08 §4.5.4, §4.11.1 «q — правила как
    // §4.5.4»; 11 SEC-042, §7.2; ревью G-customers-1c-6 / G-security-6).
    if (!v.wideSearch && byPhone) await this.phoneLookups.record(ctx, v.userId);
    const page = res.rows.slice(0, q.limit);
    const rows = await loadCustomerRows(
      this.db,
      page.map((r) => r.id),
      v.policy.favorites ? v.userId : null,
    );
    const withAmounts = q.includeReceivable && v.policy.receivableAmounts;
    const items: Record<string, unknown>[] = [];
    for (const row of rows) {
      const receivable = withAmounts ? await this.finance.receivableSummary(row) : null;
      if (receivable)
        await this.finance.debtViewed(ctx, row.id, {
          scope: 'summary',
          snapshotAt: receivable.asOf ?? null,
          via: 'list',
        });
      items.push(projectCustomer(row, v.policy, { receivable }));
    }
    const hasMore = res.rows.length > q.limit;
    const last = page.at(-1);
    const key = (r: { id: string; name: string; last_at: string }): unknown[] =>
      q.sort === 'name:asc' ? [r.name, r.id] : [r.last_at, r.id];
    return {
      items,
      nextCursor: hasMore && last ? this.cursors.encode(scope, key(last)) : null,
      hasMore,
    };
  }

  private badCursor(): never {
    return invalid('cursor', 'cursor', 'Курсор недействителен — запросите список заново.');
  }
}
