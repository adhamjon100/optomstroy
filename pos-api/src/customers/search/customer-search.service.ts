import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { AuditContext } from '../../common/audit/audit-context.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import type { CustomerViewer } from '../common/customer-access.js';
import { CustomerFinanceService } from '../common/customer-finance.js';
import { CustomerCursorCodec, invalid } from '../common/customer-http.js';
import { MATCH_TYPE_SQL, parseCustomerQuery, sellerScopeError } from '../common/customer-match.js';
import { projectCustomer } from '../common/customer-projector.js';
import { loadCustomerRows } from '../common/customer-rows.js';
import { PhoneLookupSignal } from './phone-lookup.signal.js';

export const SEARCH_CUSTOMERS_LIMIT_DEFAULT = 20;
export const SEARCH_CUSTOMERS_LIMIT_MAX = 50;
const CURSOR_SCOPE = 'search.customers';

export interface CustomerSearchQuery {
  readonly q: string;
  readonly favorite: boolean;
  readonly includeReceivable: boolean;
  readonly limit: number;
  readonly cursor?: string;
}

/**
 * `GET /search/customers` (08 §4.5.4; OpenAPI `search_customers_list`; RM-G-001, RM-G-011; перенос из `cart` этапа F —
 * GQ-FND-08): глубина поиска по роли (`parseCustomerQuery`), только живые карточки (без пометки удаления и без
 * «Розничного покупателя» — 10 CUST-018), порядок — приоритет совпадения, имя, id (keyset с HMAC). Элементы —
 * ролевое представление `Customer` + `matchType`; по умолчанию без сумм долга (`ReceivableBadge`), суммы — только при
 * `customer.receivables.read.summary` и `include=receivable` (для `seller` параметр игнорируется) с аудитом
 * `customer.debt_viewed` по каждой карточке с суммами. Поиск продавца по телефону — сигнал `customer.phone_lookup`.
 */
@Injectable()
export class CustomerSearchService {
  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    private readonly cursors: CustomerCursorCodec,
    private readonly finance: CustomerFinanceService,
    private readonly phoneLookups: PhoneLookupSignal,
  ) {}

  async search(
    v: CustomerViewer,
    ctx: AuditContext,
    q: CustomerSearchQuery,
  ): Promise<{ items: Record<string, unknown>[]; nextCursor: string | null; hasMore: boolean }> {
    const m = parseCustomerQuery(q.q, v.wideSearch);
    const after = this.cursors.decode(q.cursor, CURSOR_SCOPE);
    let keyset = sql``;
    if (after) {
      const [prio, name, id] = after;
      if (typeof prio !== 'number' || typeof name !== 'string' || typeof id !== 'string') {
        invalid('cursor', 'cursor', 'Курсор недействителен — запросите список заново.');
      }
      keyset = sql`AND (prio, name, id) > (${prio}, ${name}, ${id}::uuid)`;
    }
    const fav = q.favorite
      ? sql`AND EXISTS (SELECT 1 FROM favorites_customers f WHERE f.customer_id = c.id AND f.user_id = ${v.userId}::uuid)`
      : sql``;
    const res = await this.db.execute<{ id: string; prio: number; name: string; match: string }>(sql`
      WITH m AS (
        SELECT c.id, c.name, ${m.prio} AS prio
          FROM customers c
         WHERE NOT c.deletion_mark AND c.deleted_at IS NULL AND NOT c.is_retail_default ${fav})
      SELECT id, prio, name, ${MATCH_TYPE_SQL(sql`prio`)} AS match
        FROM m WHERE prio IS NOT NULL ${keyset}
       ORDER BY prio, name, id LIMIT ${q.limit + 1}`);
    if (m.sellerNeedsCode && res.rows.length === 0 && !after) sellerScopeError();
    if (!v.wideSearch && m.byPhone) await this.phoneLookups.record(ctx, v.userId);
    const page = res.rows.slice(0, q.limit);
    const rows = await loadCustomerRows(
      this.db,
      page.map((r) => r.id),
      v.policy.favorites ? v.userId : null,
    );
    const matchById = new Map(page.map((r) => [r.id, r.match]));
    const withAmounts = q.includeReceivable && v.policy.receivableAmounts && !v.isCustomer;
    const items: Record<string, unknown>[] = [];
    for (const row of rows) {
      const receivable = withAmounts ? await this.finance.receivableSummary(row) : null;
      if (receivable) {
        await this.finance.debtViewed(ctx, row.id, {
          scope: 'summary',
          snapshotAt: receivable.asOf ?? null,
          via: 'search',
        });
      }
      items.push({ ...projectCustomer(row, v.policy, { receivable }), matchType: matchById.get(row.id) });
    }
    const hasMore = res.rows.length > q.limit;
    const last = page.at(-1);
    return {
      items,
      nextCursor: hasMore && last ? this.cursors.encode(CURSOR_SCOPE, [last.prio, last.name, last.id]) : null,
      hasMore,
    };
  }
}
