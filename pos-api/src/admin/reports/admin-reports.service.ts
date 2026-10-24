import { Inject, Injectable } from '@nestjs/common';
import { type SQL, sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { Money } from '../../common/money/money.js';
import { SettingsReader } from '../../common/settings/settings-reader.js';
import type { QrStatusFilter, ReportPeriod, SalesGroupBy } from './admin-reports.request.js';

export interface MoneyDto {
  readonly amount: string;
  readonly currency: 'KGS';
}

const money = (v: string | null | undefined): MoneyDto => ({ amount: Money.of(v ?? '0').toString(), currency: 'KGS' });

/** Часовой пояс суток отчёта (разрез `day`; сутки торговой точки — Asia/Bishkek, как якоря аудита 07 §9.3). */
export const REPORT_TIME_ZONE = 'Asia/Bishkek';

/**
 * Заказы, учитываемые как продажи: все, кроме черновиков, отменённых и отклонённых 1С при создании
 * (`submit_failed` — документ в 1С не создан, продажи нет; GQ-ADM-04). Отменённые — отдельный счётчик.
 */
const NOT_SALE = sql.raw(`('draft','cancelled','submit_failed')`);

interface SalesAggRow extends Record<string, unknown> {
  key: string | null;
  orders_count: number;
  orders_total: string | null;
  paid_total: string | null;
  discount_total: string | null;
  cash_total: string | null;
  qr_total: string | null;
  credit_total: string | null;
  cancelled_count: number;
}

function salesTotals(r: SalesAggRow | undefined): Record<string, unknown> {
  return {
    ordersCount: Number(r?.orders_count ?? 0), // money-double: allow — число заказов, не деньги
    ordersTotal: money(r?.orders_total),
    paidTotal: money(r?.paid_total),
    byMethod: { cash: money(r?.cash_total), qr_bakai: money(r?.qr_total), credit: money(r?.credit_total) },
    discountTotal: money(r?.discount_total),
    cancelledCount: Number(r?.cancelled_count ?? 0), // money-double: allow — число заказов, не деньги
  };
}

/**
 * Отчёты руководителя R1 (08 §4.18.8; ядро §22.13 п. 3; RM-G-006): только данные POS (`source: pos`), без CSV,
 * без разбивки долга по срокам и топа должников (R2). Суммы — NUMERIC в БД, строки `Money` в ответе (D-19).
 *
 * - `sales-summary`: заказы POS, созданные в периоде (`orders.created_at` ∈ [from, to)); продажи — заказы вне
 *   `draft`/`cancelled`/`submit_failed`; `ordersTotal` — сумма `orders.total`, `byMethod` — та же сумма по способу
 *   оплаты заказа, `paidTotal` — полученные платежи этих заказов (`payments.status = received`), `discountTotal` —
 *   `orders.discount_total`; `cancelledCount` — отменённые заказы периода. Разрез `day` — сутки Asia/Bishkek,
 *   `seller` — автор заказа (`users.id`), `paymentMethod` — способ оплаты заказа.
 * - `receivables`: снимок долга 1С (`receivables`, D-24: долги только из 1С) по клиентам без пометки удаления;
 *   долг — положительное сальдо (аванс не уменьшает итог); `asOf` — самый старый снимок (консервативно), `isStale`
 *   — старше `receivables.max_age_minutes` (иначе env `RECEIVABLES_MAX_AGE_MIN`) или снимков нет.
 * - `qr-reconciliation`: QR-платежи (`method = qr_bakai`), созданные в периоде, кроме не показанных
 *   (`initiated`, `qr_pending`); `unmatched` — `manual_confirm` (требуют разбора, `reviewReason`) и `qr_shown`/
 *   `qr_expired` без подтверждения старше `QR_TTL_MINUTES` (RM-G-006 п. 3); `manual` — полученные ручным
 *   подтверждением; `webhook` — полученные автоматически (подтверждение 1С при `QR_PROVIDER=onec`, ядро §24.4).
 */
@Injectable()
export class AdminReportsService {
  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    @Inject(APP_CONFIG) private readonly config: Pick<AppConfig, 'RECEIVABLES_MAX_AGE_MIN' | 'QR_TTL_MINUTES'>,
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly settings: SettingsReader,
  ) {}

  now(): Date {
    return this.clock.now();
  }

  async salesSummary(period: ReportPeriod, groupBy: SalesGroupBy): Promise<Record<string, unknown>> {
    const key: SQL =
      groupBy === 'day'
        ? sql`to_char((o.created_at AT TIME ZONE ${REPORT_TIME_ZONE})::date, 'YYYY-MM-DD')`
        : groupBy === 'seller'
          ? sql`o.created_by_user_id::text`
          : sql`o.payment_method::text`;
    const agg = (keyExpr: SQL): SQL => sql`
      WITH base AS (
        SELECT o.id, o.status, o.created_at, o.created_by_user_id, o.payment_method, o.total, o.discount_total,
               (o.status NOT IN ${NOT_SALE}) AS is_sale,
               (SELECT coalesce(sum(p.amount), 0) FROM payments p
                 WHERE p.order_id = o.id AND p.status = 'received') AS paid
          FROM orders o
         WHERE o.status <> 'draft'
           AND o.created_at >= ${period.from.toISOString()}::timestamptz
           AND o.created_at < ${period.to.toISOString()}::timestamptz
      )
      SELECT ${keyExpr} AS key,
             count(*) FILTER (WHERE o.is_sale)::int AS orders_count,
             sum(o.total) FILTER (WHERE o.is_sale)::text AS orders_total,
             sum(o.paid) FILTER (WHERE o.is_sale)::text AS paid_total,
             sum(o.discount_total) FILTER (WHERE o.is_sale)::text AS discount_total,
             sum(o.total) FILTER (WHERE o.is_sale AND o.payment_method = 'cash')::text AS cash_total,
             sum(o.total) FILTER (WHERE o.is_sale AND o.payment_method = 'qr_bakai')::text AS qr_total,
             sum(o.total) FILTER (WHERE o.is_sale AND o.payment_method = 'credit')::text AS credit_total,
             count(*) FILTER (WHERE o.status = 'cancelled')::int AS cancelled_count
        FROM base o`;
    const rows = (await this.db.execute<SalesAggRow>(sql`${agg(key)} GROUP BY 1 ORDER BY 1`)).rows;
    const totals = (await this.db.execute<SalesAggRow>(agg(sql`NULL::text`))).rows[0];
    return {
      period: { from: period.from.toISOString(), to: period.to.toISOString() },
      rows: rows.map((r) => ({ key: r.key ?? '', ...salesTotals(r) })),
      totals: salesTotals(totals),
      source: 'pos',
    };
  }

  async receivables(asOfOnly: boolean): Promise<Record<string, unknown>> {
    const r = (
      await this.db.execute<{
        customers_count: number;
        overdue_count: number;
        total_balance: string | null;
        total_overdue: string | null;
        as_of: Date | string | null;
      }>(sql`
        SELECT count(*) FILTER (WHERE r.balance > 0)::int AS customers_count,
               count(*) FILTER (WHERE r.overdue_amount > 0)::int AS overdue_count,
               sum(r.balance) FILTER (WHERE r.balance > 0)::text AS total_balance,
               sum(r.overdue_amount) FILTER (WHERE r.overdue_amount > 0)::text AS total_overdue,
               min(r.onec_snapshot_at) AS as_of
          FROM receivables r JOIN customers c ON c.id = r.customer_id
         WHERE NOT c.deletion_mark`)
    ).rows[0];
    const asOf = r?.as_of ? new Date(r.as_of) : null;
    const maxAge = await this.maxAgeMinutes();
    const isStale = asOf === null || this.now().getTime() - asOf.getTime() > maxAge * 60_000;
    const head = { asOf: asOf ? asOf.toISOString() : null, isStale };
    if (asOfOnly) return head;
    return {
      ...head,
      totalBalance: money(r?.total_balance),
      totalOverdue: money(r?.total_overdue),
      customersCount: Number(r?.customers_count ?? 0), // money-double: allow — число клиентов, не деньги
      overdueCount: Number(r?.overdue_count ?? 0), // money-double: allow — число клиентов, не деньги
    };
  }

  async qrReconciliation(period: ReportPeriod, status: QrStatusFilter): Promise<Record<string, unknown>> {
    const staleBefore = new Date(this.now().getTime() - this.config.QR_TTL_MINUTES * 60_000).toISOString();
    const unmatched = sql`(p.status = 'manual_confirm'
        OR (p.status IN ('qr_shown', 'qr_expired') AND coalesce(p.qr_issued_at, p.created_at) < ${staleBefore}::timestamptz))`;
    const manual = sql`(p.status IN ('received', 'refunded') AND p.manual_confirmed_by_user_id IS NOT NULL)`;
    const base = sql`p.method = 'qr_bakai' AND p.status NOT IN ('initiated', 'qr_pending')
        AND p.created_at >= ${period.from.toISOString()}::timestamptz
        AND p.created_at < ${period.to.toISOString()}::timestamptz`;
    const filter = status === 'unmatched' ? sql` AND ${unmatched}` : status === 'manual' ? sql` AND ${manual}` : sql``;
    const rows = (
      await this.db.execute<{
        id: string;
        order_number: string | null;
        amount: string;
        bank_reference: string | null;
        status: string;
        review_reason: string | null;
        bank_amount: string | null;
        manual_by: string | null;
        manual_name: string | null;
        manual_role: string | null;
        confirmed_at: Date | string | null;
      }>(sql`
        SELECT p.id, o.public_number AS order_number, p.amount::text AS amount,
               coalesce(p.bank_reference, p.qr_provider_ref) AS bank_reference, p.status::text AS status,
               p.review_reason, p.bank_amount::text AS bank_amount, p.manual_confirmed_by_user_id AS manual_by,
               coalesce(up.display_name, up.full_name) AS manual_name,
               (SELECT ro.code::text FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id
                 WHERE ur.user_id = p.manual_confirmed_by_user_id AND ur.revoked_at IS NULL LIMIT 1) AS manual_role,
               CASE WHEN p.status IN ('received', 'refunded') THEN coalesce(p.manual_confirmed_at, p.received_at) END
                 AS confirmed_at
          FROM payments p
          LEFT JOIN orders o ON o.id = p.order_id
          LEFT JOIN user_profiles up ON up.user_id = p.manual_confirmed_by_user_id
         WHERE ${base}${filter}
         ORDER BY p.created_at DESC, p.id DESC`)
    ).rows;
    const summary = (
      await this.db.execute<{ webhook: number; manual: number; unmatched: number }>(sql`
        SELECT count(*) FILTER (WHERE p.status IN ('received', 'refunded')
                                  AND p.manual_confirmed_by_user_id IS NULL)::int AS webhook,
               count(*) FILTER (WHERE ${manual})::int AS manual,
               count(*) FILTER (WHERE ${unmatched})::int AS unmatched
          FROM payments p WHERE ${base}`)
    ).rows[0];
    return {
      period: { from: period.from.toISOString(), to: period.to.toISOString() },
      rows: rows.map((r) => {
        const received = r.status === 'received' || r.status === 'refunded';
        return {
          paymentId: r.id,
          orderNumber: r.order_number,
          amount: money(r.amount),
          bankReference: r.bank_reference,
          confirmationKind: received ? (r.manual_by ? 'manual' : 'webhook') : null,
          confirmedBy:
            received && r.manual_by
              ? {
                  id: r.manual_by,
                  displayName: r.manual_name ?? 'Сотрудник',
                  ...(r.manual_role ? { role: r.manual_role } : {}),
                }
              : null,
          confirmedAt: r.confirmed_at ? new Date(r.confirmed_at).toISOString() : null,
          status: r.status,
          reviewReason: r.review_reason,
          bankAmount: r.bank_amount === null ? null : money(r.bank_amount),
        };
      }),
      summary: {
        webhook: Number(summary?.webhook ?? 0), // money-double: allow — число платежей
        manual: Number(summary?.manual ?? 0), // money-double: allow — число платежей
        unmatched: Number(summary?.unmatched ?? 0), // money-double: allow — число платежей
      },
    };
  }

  /** `receivables.max_age_minutes` (app_settings, 5…1440) или env `RECEIVABLES_MAX_AGE_MIN` (08 §4.18.6). */
  private async maxAgeMinutes(): Promise<number> {
    const v = await this.settings.get('receivables.max_age_minutes');
    return typeof v === 'number' && Number.isInteger(v) && v > 0 ? v : this.config.RECEIVABLES_MAX_AGE_MIN;
  }
}
