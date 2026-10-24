import { Inject, Injectable } from '@nestjs/common';
import { type SQL, sql } from 'drizzle-orm';
import type { AuditContext } from '../../common/audit/audit-context.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import type { CustomerViewer } from '../common/customer-access.js';
import { CustomerAccessService } from '../common/customer-access.js';
import { CustomerFinanceService } from '../common/customer-finance.js';
import { CustomerCursorCodec, forbidden, invalid } from '../common/customer-http.js';
import { moneyDto } from '../common/customer-projector.js';

export const HISTORY_LIMIT_DEFAULT = 50;
export const HISTORY_LIMIT_MAX = 200;
/** Период истории по умолчанию (10 CUST-005, AC-CUST-005: 90 дней [НЕ ПОДТВЕРЖДЕНО, Q-176]). */
export const HISTORY_DEFAULT_DAYS = 90;
/** Максимальный период журналов (ядро §19.4, RM-G-011): 366 дней. */
export const MAX_RANGE_MS = 366 * 86_400_000;
const BISHKEK_OFFSET_MS = 6 * 3_600_000;

export type HistorySource = 'pos' | 'onec' | 'all';

export interface CustomerHistoryQuery {
  readonly from?: Date;
  readonly to?: Date;
  readonly source: HistorySource;
  readonly limit: number;
  readonly cursor?: string;
}

interface HistoryRow extends Record<string, unknown> {
  kind: 'order' | 'shipment';
  id: string;
  number: string;
  ts: string;
  total: string;
  status: string;
}

/** `historyFrom` (ядро §19.2): сегодня по Бишкеку минус `SALES_HISTORY_MONTHS` месяцев (`YYYY-MM-DD`). */
export function historyFromDate(months: number, now: Date = new Date()): string {
  const today = new Date(now.getTime() + BISHKEK_OFFSET_MS).toISOString().slice(0, 10);
  const [y, m, d] = today.split('-').map((x) => Number(x)) as [number, number, number];
  const total = y * 12 + (m - 1) - months;
  const yy = Math.floor(total / 12);
  const mm = total % 12;
  const last = new Date(Date.UTC(yy, mm + 1, 0)).getUTCDate();
  return new Date(Date.UTC(yy, mm, Math.min(d, last))).toISOString().slice(0, 10);
}

/**
 * История покупок клиента `GET /customers/{id}/orders` (08 §4.11.4; SCR-33; 10 CUST-005; RM-G-001, RM-G-011;
 * перенос из `orders` этапа F — GQ-FND-08): заказы POS (кроме черновиков) и проведённые реализации 1С из проекции
 * `shipments` (`sync_entity=sales_history`, глубина `SALES_HISTORY_MONTHS`, ядро §17.3). Реализация по заказу POS
 * (`shipments.order_id`) отдельной строкой не показывается — это тот же заказ (GQ-CUS-03). Порядок — дата документа
 * (новые сверху), keyset `(дата, id)` с HMAC. `summary` — по фильтру периода и источника без отменённых заказов;
 * `historyFrom` — граница истории 1С в POS.
 *
 * Доступ: `customer.history.read` (`cashier`, `senior_seller`, `admin`, `owner`), `seller` → 403; `customer` — своя
 * карточка при `confirmed`, иначе 404 (11 SEC-030 (в)). Аудит `customer.debt_viewed` (объём `history`) — для
 * сотрудников; просмотр клиентом своей истории не пишется.
 */
@Injectable()
export class CustomerHistoryService {
  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    @Inject(APP_CONFIG) private readonly config: Pick<AppConfig, 'SALES_HISTORY_MONTHS'>,
    private readonly access: CustomerAccessService,
    private readonly cursors: CustomerCursorCodec,
    private readonly finance: CustomerFinanceService,
  ) {}

  async history(
    v: CustomerViewer,
    ctx: AuditContext,
    customerId: string,
    q: CustomerHistoryQuery,
  ): Promise<Record<string, unknown>> {
    if (!v.isCustomer && !v.permissions.has('customer.history.read')) forbidden();
    await this.access.assertCardAccess(v, customerId);
    // Курсор привязан к запрошенному периоду (не к вычисленным границам по умолчанию — они сдвигаются со временем).
    const scope = `history:${customerId}:${q.source}:${q.from?.toISOString() ?? ''}:${q.to?.toISOString() ?? ''}`;
    // Период (10 CUST-005: по умолчанию 90 дней [НЕ ПОДТВЕРЖДЕНО, Q-176]; OpenAPI `From`: ≤ 366 дней): без `to` —
    // сейчас, без `from` — `to − 90 дней`; ограничение 366 дней — и при одной заданной границе (ревью G-customers-1c-7).
    const to = q.to ?? new Date();
    const from = q.from ?? new Date(to.getTime() - HISTORY_DEFAULT_DAYS * 86_400_000);
    if (from > to || to.getTime() - from.getTime() > MAX_RANGE_MS) {
      invalid('from', 'date_range', 'Период: from ≤ to, не более 366 дней.');
    }
    q = { ...q, from, to };
    const after = this.cursors.decode(q.cursor, scope);
    if (after && (typeof after[0] !== 'string' || typeof after[1] !== 'string')) {
      invalid('cursor', 'cursor', 'Курсор недействителен — запросите список заново.');
    }
    const union = this.unionSql(customerId, q);
    const retail = await this.db.execute<{ r: boolean }>(
      sql`SELECT is_retail_default AS r FROM customers WHERE id = ${customerId}::uuid`,
    );
    // «Розничный покупатель» — без истории в карточке (10 CUST-018).
    const isRetail = retail.rows[0]?.r === true;
    const keyset = after
      ? sql`WHERE (h.ts, h.id) < (${after[0] as string}::timestamptz, ${after[1] as string}::uuid)`
      : sql``;
    const rows = isRetail
      ? []
      : (
          await this.db.execute<HistoryRow>(sql`
            SELECT h.kind, h.id, h.number, to_char(h.ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS ts,
                   h.total, h.status
              FROM (${union}) h ${keyset}
             ORDER BY h.ts DESC, h.id DESC
             LIMIT ${q.limit + 1}`)
        ).rows;
    const summary = isRetail
      ? { n: 0, sum_total: '0.00', last_at: null }
      : (
          await this.db.execute<{ n: number; sum_total: string | null; last_at: string | null }>(sql`
            SELECT count(*)::int AS n, coalesce(sum(h.total::numeric), 0)::numeric(14,2)::text AS sum_total,
                   to_char(max(h.ts) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS last_at
              FROM (${union}) h WHERE h.status <> 'cancelled'`)
        ).rows[0];
    if (!v.isCustomer) {
      await this.finance.debtViewed(ctx, customerId, {
        scope: 'history',
        snapshotAt: null,
        via: 'history',
        from: q.from?.toISOString() ?? null,
        to: q.to?.toISOString() ?? null,
        source: q.source,
      });
    }
    const hasMore = rows.length > q.limit;
    const page = rows.slice(0, q.limit);
    const last = page.at(-1);
    return {
      items: page.map((r) => ({
        kind: r.kind,
        id: r.id,
        number: r.number,
        date: r.ts,
        total: moneyDto(r.total),
        status: r.status,
        source: r.kind === 'order' ? 'pos' : 'onec',
        url: r.kind === 'order' ? `/api/v1/orders/${r.id}` : null,
      })),
      nextCursor: hasMore && last ? this.cursors.encode(scope, [last.ts, last.id]) : null,
      hasMore,
      summary: {
        count: Number(summary?.n ?? 0), // money-double: allow — число документов
        total: moneyDto(summary?.sum_total ?? '0.00'),
        lastOrderAt: summary?.last_at ?? null,
      },
      historyFrom: historyFromDate(this.config.SALES_HISTORY_MONTHS),
    };
  }

  /** Заказы POS ∪ реализации 1С без заказа POS: `(kind, id, number, ts, total, status)`. */
  private unionSql(customerId: string, q: CustomerHistoryQuery): SQL {
    const period = (col: SQL): SQL =>
      sql`${q.from ? sql`AND ${col} >= ${q.from.toISOString()}::timestamptz` : sql``}
          ${q.to ? sql`AND ${col} <= ${q.to.toISOString()}::timestamptz` : sql``}`;
    const orders = sql`
      SELECT 'order'::text AS kind, o.id, o.public_number AS number, o.created_at AS ts, o.total::text AS total,
             o.status::text AS status
        FROM orders o
       WHERE o.customer_id = ${customerId}::uuid AND o.status <> 'draft' ${period(sql`o.created_at`)}`;
    const shipments = sql`
      SELECT 'shipment'::text AS kind, s.id, coalesce(s.onec_code, '') AS number, s.onec_date AS ts,
             s.total::text AS total,
             CASE WHEN s.returned_total > 0 AND s.returned_total >= s.total THEN 'returned'
                  WHEN s.returned_total > 0 THEN 'partially_returned'
                  ELSE 'posted' END AS status
        FROM shipments s
       WHERE s.customer_id = ${customerId}::uuid AND s.posted AND NOT s.deletion_mark AND s.order_id IS NULL
             ${period(sql`s.onec_date`)}`;
    if (q.source === 'pos') return orders;
    if (q.source === 'onec') return shipments;
    return sql`${orders} UNION ALL ${shipments}`;
  }
}
