import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { AuditContext } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import { DRIZZLE, type Database } from '../../common/db/database.module.js';
import { Money } from '../../common/money/money.js';
import { customerDisplayName } from '../../common/presenters/customer-name.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import type { PermissionCode } from '../../common/rbac/permissions.generated.js';
import {
  loadTxUserRefs,
  PAYMENT_KINDS,
  presentTransaction,
  selectTransactions,
} from '../../transactions/transactions.sql.js';
import { presentPayment, referencedUsers } from '../app/payment-presenter.js';
import { PaymentsLookups } from '../infra/payments-lookups.js';
import { PaymentsRepository, type PaymentRow } from '../infra/payments.repository.js';
import { QrProviders } from '../qr/qr-providers.js';

const DAY_MS = 86_400_000;
const BISHKEK_OFFSET_MS = 6 * 3_600_000;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Статусы заказа блока «Ожидают оплаты» (ядро §22.5, §23 п. 7; 10 CASH §14.1). */
export const AWAITING_ORDER_STATUSES = ['submitting', 'pending_approval', 'approved', 'awaiting_payment'] as const;
/** Открытый платёж блока «Ожидают оплаты» (10 CASH §14.1): `manual_confirm` — в блоке «Требуют разбора». */
export const AWAITING_PAYMENT_STATUSES = ['cash_pending', 'qr_pending', 'qr_shown', 'qr_expired'] as const;
const QR_PENDING_STATUSES = ['qr_pending', 'qr_shown', 'qr_expired'] as const;

export interface DashboardViewer {
  readonly userId: string;
  readonly roles: readonly string[];
  readonly perms: ReadonlySet<PermissionCode>;
  readonly audit: AuditContext;
}

function inList(values: readonly string[]) {
  return sql.join(
    values.map((v) => sql`${v}`),
    sql.raw(', '),
  );
}

function money(v: string | null | undefined): { amount: string; currency: 'KGS' } {
  return Money.of(v ?? '0').toJSON();
}

interface CustomerBrief extends Record<string, unknown> {
  id: string;
  name: string;
  customer_type: string;
  onec_code: string | null;
  is_retail_default: boolean;
  credit_allowed: boolean;
  has_debt: boolean | null;
  is_overdue: boolean | null;
}

/** Ролевое представление `Customer` в списках дашборда — без сумм долга, только флаги (08 §3.7, §4.10.1). */
function presentCustomerBrief(c: CustomerBrief, isFavorite?: boolean): Record<string, unknown> {
  return {
    id: c.id,
    name: c.name,
    displayName: customerDisplayName(c.name),
    customerType: c.customer_type,
    ...(c.onec_code ? { onecCode: c.onec_code } : {}),
    isRetailDefault: c.is_retail_default,
    creditAllowed: c.credit_allowed,
    hasDebt: c.has_debt === true,
    isOverdue: c.is_overdue === true,
    ...(isFavorite !== undefined ? { isFavorite } : {}),
  };
}

const CUSTOMER_BRIEF = sql.raw(`c.id, c.name, c.customer_type::text AS customer_type, c.onec_code, c.is_retail_default,
  c.credit_allowed, (rv.balance > 0) AS has_debt, (rv.overdue_amount > 0) AS is_overdue`);

/**
 * Дашборд кассира `GET /pos/dashboard` (08 §4.10.1; 10 CASH §14.1, CASH-010…CASH-018, TXN-009; ядро §22.5, §23 п. 7;
 * 13 RM-G-004). Поля по правам — allowlist 11 SEC-031, SEC-036: `qrPending[]`, `manualConfirm[]` и платёжные строки
 * `recentTransactions[]` — только `payment.read.all` (без него — счётчики); `overdue[]` —
 * `customer.receivables.read.summary` (аудит `receivables.overdue_viewed` при непустом); `favoriteCustomers[]` —
 * `favorites.customers.manage`. Суммы смены — из журнала `transactions` (сверка: дашборд = Σ журнала за день).
 */
@Injectable()
export class PosDashboardService {
  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    private readonly payments: PaymentsRepository,
    private readonly lookups: PaymentsLookups,
    private readonly providers: QrProviders,
    private readonly audit: AuditService,
  ) {}

  async get(
    viewer: DashboardViewer,
    q: Record<string, unknown>,
    now: Date = new Date(),
  ): Promise<Record<string, unknown>> {
    const { date, dayStart, dayEnd } = this.parseDate(q.date, now);
    const warehouseId = await this.warehouse(viewer, q.warehouseId);
    const seesPayments = viewer.perms.has('payment.read.all');
    const whOrder = warehouseId ? sql`AND o.warehouse_id = ${warehouseId}::uuid` : sql.raw('');
    const whTxn = warehouseId ? sql`AND (t.order_id IS NULL OR o.warehouse_id = ${warehouseId}::uuid)` : sql.raw('');
    const from = dayStart.toISOString();
    const to = dayEnd.toISOString();

    const totalsRow = (
      await this.db.execute<{
        cash: string;
        qr: string;
        credit: string;
        orders_count: number;
        payments_count: number;
      }>(sql`
        SELECT
          coalesce(sum(t.amount) FILTER (WHERE t.kind IN ('payment_received','manual_qr_confirm')
                                           AND t.payment_method = 'cash'), 0)::numeric(16,2)::text AS cash,
          coalesce(sum(t.amount) FILTER (WHERE t.kind IN ('payment_received','manual_qr_confirm')
                                           AND t.payment_method = 'qr_bakai'), 0)::numeric(16,2)::text AS qr,
          (coalesce(sum(t.amount) FILTER (WHERE t.kind = 'order_created' AND t.payment_method = 'credit'), 0)
           - coalesce(sum(abs(t.amount)) FILTER (WHERE t.kind = 'order_cancelled' AND t.payment_method = 'credit'), 0)
          )::numeric(16,2)::text AS credit,
          (count(*) FILTER (WHERE t.kind = 'order_created'))::int AS orders_count,
          (count(*) FILTER (WHERE t.kind IN ('payment_received','manual_qr_confirm')))::int AS payments_count
          FROM transactions t LEFT JOIN orders o ON o.id = t.order_id
         WHERE t.occurred_at >= ${from}::timestamptz AND t.occurred_at < ${to}::timestamptz ${whTxn}`)
    ).rows[0];

    const awaiting = await this.awaitingPayment(from, to, whOrder);

    const qrIds = (
      await this.db.execute<{ id: string }>(sql`
        SELECT p.id FROM payments p LEFT JOIN orders o ON o.id = p.order_id
         WHERE p.method = 'qr_bakai' AND p.status::text IN (${inList(QR_PENDING_STATUSES)})
           AND p.created_at >= ${from}::timestamptz AND p.created_at < ${to}::timestamptz ${whOrder}
         ORDER BY p.created_at DESC`)
    ).rows.map((r) => r.id);
    const manualIds = (
      await this.db.execute<{ id: string }>(sql`
        SELECT p.id FROM payments p LEFT JOIN orders o ON o.id = p.order_id
         WHERE p.status = 'manual_confirm' ${whOrder}
         ORDER BY p.created_at DESC`)
    ).rows.map((r) => r.id);

    const out: Record<string, unknown> = {
      date,
      totals: {
        cash: money(totalsRow?.cash),
        qr: money(totalsRow?.qr),
        credit: money(totalsRow?.credit),
        ordersCount: Number(totalsRow?.orders_count ?? 0), // money-double: allow — число заказов
        paymentsCount: Number(totalsRow?.payments_count ?? 0), // money-double: allow — число платежей
      },
      awaitingPayment: awaiting,
      qrPendingCount: qrIds.length,
      manualConfirmCount: manualIds.length,
    };
    if (seesPayments) {
      out.qrPending = await this.presentPayments(qrIds.slice(0, 20), viewer);
      out.manualConfirm = await this.presentPayments(manualIds.slice(0, 20), viewer);
    }
    if (viewer.perms.has('customer.receivables.read.summary')) {
      const overdue = await this.overdue();
      out.overdue = overdue;
      if (overdue.length > 0) {
        await this.audit.write(viewer.audit, {
          action: 'receivables.overdue_viewed',
          entityType: 'customer',
          after: { count: overdue.length, source: 'pos.dashboard' },
        });
      }
    }
    if (viewer.perms.has('favorites.customers.manage')) out.favoriteCustomers = await this.favorites(viewer.userId);
    out.recentTransactions = await this.recent(viewer, dayStart, dayEnd, seesPayments);
    out.sync = await this.syncInfo();
    out.notificationsUnread = Number(
      (
        await this.db.execute<{ n: number }>(sql`
          SELECT count(*)::int AS n FROM notifications
           WHERE user_id = ${viewer.userId}::uuid AND read_at IS NULL AND (expires_at IS NULL OR expires_at > now())`)
      ).rows[0]?.n ?? 0,
    ); // money-double: allow — число уведомлений
    return out;
  }

  /** `date` — день по Бишкеку (по умолчанию сегодня); границы дня в UTC. */
  private parseDate(raw: unknown, now: Date): { date: string; dayStart: Date; dayEnd: Date } {
    const s: unknown = Array.isArray(raw) ? (raw as unknown[])[0] : raw;
    let date: string;
    if (s === undefined || s === '') {
      date = new Date(now.getTime() + BISHKEK_OFFSET_MS).toISOString().slice(0, 10);
    } else if (typeof s === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(s) && !Number.isNaN(Date.parse(`${s}T00:00:00Z`))) {
      date = s;
    } else {
      throw new ProblemException('VALIDATION_FAILED', {
        status: 400,
        detail: 'Запрос не прошёл проверку.',
        errors: [{ field: 'date', rule: 'date', message: 'Ожидается дата YYYY-MM-DD.' }],
      });
    }
    const dayStart = new Date(Date.parse(`${date}T00:00:00Z`) - BISHKEK_OFFSET_MS);
    return { date, dayStart, dayEnd: new Date(dayStart.getTime() + DAY_MS) };
  }

  /** `warehouseId` — явный; иначе склад пользователя (`user_profiles.home_warehouse_id`); нет — все склады. */
  private async warehouse(viewer: DashboardViewer, raw: unknown): Promise<string | null> {
    const s: unknown = Array.isArray(raw) ? (raw as unknown[])[0] : raw;
    if (typeof s === 'string' && s !== '') {
      if (!UUID_RE.test(s)) {
        throw new ProblemException('VALIDATION_FAILED', {
          status: 400,
          detail: 'Запрос не прошёл проверку.',
          errors: [{ field: 'warehouseId', rule: 'uuid', message: 'Ожидается UUID.' }],
        });
      }
      return s.toLowerCase();
    }
    const r = await this.db.execute<{ id: string | null }>(sql`
      SELECT home_warehouse_id AS id FROM user_profiles WHERE user_id = ${viewer.userId}::uuid`);
    return r.rows[0]?.id ?? null;
  }

  /**
   * «Ожидают оплаты» (≤ 20): заказы дня в `submitting | pending_approval | approved | awaiting_payment` со способом
   * `cash`/`qr_bakai`, `paid_amount < total` и **открытым** платежом (`cash_pending | qr_pending | qr_shown |
   * qr_expired`); заказ без открытого платежа в блок не попадает (ядро §23 п. 7, §22.5; T-CASH-008).
   */
  private async awaitingPayment(from: string, to: string, whOrder: ReturnType<typeof sql>) {
    const rows = (
      await this.db.execute<
        CustomerBrief & {
          order_id: string;
          public_number: string;
          status: string;
          onec_sync_state: string;
          warehouse_id: string;
          subtotal: string;
          discount_total: string;
          total: string;
          payment_method: string;
          paid_amount: string;
          is_paid: boolean;
          created_at: Date;
          items_count: number;
          payments_count: number;
          open_payment_id: string;
          open_payment_status: string;
        }
      >(sql`
        SELECT o.id AS order_id, o.public_number, o.status::text AS status, o.onec_sync_state::text AS onec_sync_state,
               o.warehouse_id, o.subtotal::text AS subtotal, o.discount_total::text AS discount_total,
               o.total::text AS total, o.payment_method::text AS payment_method, o.paid_amount::text AS paid_amount,
               o.is_paid, o.created_at,
               (SELECT count(*)::int FROM order_items oi WHERE oi.order_id = o.id) AS items_count,
               (SELECT count(*)::int FROM payments px WHERE px.order_id = o.id) AS payments_count,
               op.id AS open_payment_id, op.status::text AS open_payment_status,
               ${CUSTOMER_BRIEF}
          FROM orders o
          JOIN LATERAL (
                SELECT p.id, p.status FROM payments p
                 WHERE p.order_id = o.id AND p.status::text IN (${inList(AWAITING_PAYMENT_STATUSES)})
                 ORDER BY p.created_at DESC LIMIT 1) op ON true
          JOIN customers c ON c.id = o.customer_id
          LEFT JOIN receivables rv ON rv.customer_id = c.id
         WHERE o.status::text IN (${inList(AWAITING_ORDER_STATUSES)})
           AND o.payment_method IN ('cash', 'qr_bakai') AND o.paid_amount < o.total
           AND o.created_at >= ${from}::timestamptz AND o.created_at < ${to}::timestamptz ${whOrder}
         ORDER BY o.created_at DESC, o.id DESC LIMIT 20`)
    ).rows;
    return rows.map((o) => ({
      id: o.order_id,
      publicNumber: o.public_number,
      status: o.status,
      onecSyncState: o.onec_sync_state,
      customer: presentCustomerBrief(o),
      warehouseId: o.warehouse_id,
      itemsCount: Number(o.items_count), // money-double: allow — число строк
      subtotal: money(o.subtotal),
      discountTotal: money(o.discount_total),
      total: money(o.total),
      cashRounding: '0.00',
      totalToPay: money(o.total),
      paymentMethod: o.payment_method,
      paidAmount: money(o.paid_amount),
      isPaid: o.is_paid,
      paymentsSummary: {
        count: Number(o.payments_count), // money-double: allow — число платежей
        openPaymentId: o.open_payment_id,
        openPaymentStatus: o.open_payment_status,
      },
      audit: { createdAt: new Date(o.created_at).toISOString() },
    }));
  }

  private async presentPayments(ids: readonly string[], viewer: DashboardViewer): Promise<Record<string, unknown>[]> {
    const list: PaymentRow[] = [];
    for (const id of ids) {
      const p = await this.payments.findById(this.db, id);
      if (p) list.push(p);
    }
    if (list.length === 0) return [];
    const users = await this.lookups.userRefs(this.db, list.flatMap(referencedUsers));
    const staticPayload = list.some((p) => p.method === 'qr_bakai') ? await this.providers.staticPayload() : null;
    return list.map(
      (p) =>
        presentPayment(p, {
          showQr: viewer.perms.has('payment.qr.show'),
          showExternalRef: viewer.perms.has('payment.read.all'),
          staticPayload,
          users,
        }) as unknown as Record<string, unknown>,
    );
  }

  /** Топ-10 просрочек из снимков 1С (`receivables`, D-24) с датой снимка (CASH-018). */
  private async overdue(): Promise<Record<string, unknown>[]> {
    const rows = (
      await this.db.execute<
        CustomerBrief & { overdue_amount: string; overdue_days: number | null; onec_snapshot_at: Date }
      >(sql`
        SELECT ${CUSTOMER_BRIEF}, rv.overdue_amount::text AS overdue_amount, rv.overdue_days, rv.onec_snapshot_at
          FROM receivables rv JOIN customers c ON c.id = rv.customer_id
         WHERE rv.overdue_amount > 0 AND NOT c.deletion_mark
         ORDER BY rv.overdue_amount DESC, c.id LIMIT 10`)
    ).rows;
    return rows.map((r) => ({
      customer: presentCustomerBrief(r),
      overdueAmount: money(r.overdue_amount),
      overdueDays: Number(r.overdue_days ?? 0), // money-double: allow — число дней
      asOf: new Date(r.onec_snapshot_at).toISOString(),
    }));
  }

  /** Избранные клиенты (≤ 12, ядро §19.2) — без сумм, флаги `hasDebt`/`isOverdue`. */
  private async favorites(userId: string): Promise<Record<string, unknown>[]> {
    const rows = (
      await this.db.execute<CustomerBrief>(sql`
        SELECT ${CUSTOMER_BRIEF}
          FROM favorites_customers f JOIN customers c ON c.id = f.customer_id
          LEFT JOIN receivables rv ON rv.customer_id = c.id
         WHERE f.user_id = ${userId}::uuid
         ORDER BY f.created_at DESC, c.id LIMIT 12`)
    ).rows;
    return rows.map((c) => presentCustomerBrief(c, true));
  }

  /**
   * «Недавние операции» (TXN-009): 10 последних за день — свои (автор операции или заказа) у ролей с кассовыми
   * операциями; у `admin`/`owner` (без кассовых операций, ядро §17.2) — по точке (GQ-TXR-09). Без `payment.read.all`
   * строки платежей не выдаются (платёжные суммы — allowlist 11 SEC-031).
   */
  private async recent(
    viewer: DashboardViewer,
    dayStart: Date,
    dayEnd: Date,
    seesPayments: boolean,
  ): Promise<Record<string, unknown>[]> {
    const cashOps = viewer.perms.has('payment.cash.receive') || viewer.perms.has('payment.qr.show');
    const rows = await selectTransactions(
      this.db,
      {
        from: dayStart,
        to: new Date(dayEnd.getTime() - 1),
        ...(cashOps ? { ownerUserId: viewer.userId } : {}),
        ...(seesPayments ? {} : { excludeKinds: PAYMENT_KINDS }),
      },
      'occurredAt:desc',
      10,
    );
    const page = rows.slice(0, 10);
    const users = await loadTxUserRefs(
      this.db,
      page.map((r) => r.actor_user_id),
    );
    return page.map((r) => presentTransaction(r, users));
  }

  /** Свежесть данных 1С (SRC-C-112): снимки долга и остатки; общий статус — по `sync_state` (05 §7.6.1). */
  private async syncInfo(): Promise<Record<string, unknown>> {
    const r = (
      await this.db.execute<{
        receivables_as_of: Date | null;
        stock_as_of: Date | null;
        failing: number;
        degraded: number;
      }>(sql`
        SELECT (SELECT max(onec_snapshot_at) FROM receivables) AS receivables_as_of,
               (SELECT last_success_at FROM sync_state WHERE entity = 'stock') AS stock_as_of,
               (SELECT count(*)::int FROM sync_state WHERE consecutive_errors >= 3) AS failing,
               (SELECT count(*)::int FROM sync_state
                 WHERE consecutive_errors > 0
                    OR (last_success_at IS NOT NULL
                        AND last_success_at < now() - make_interval(secs => max_age_warning_sec))) AS degraded`)
    ).rows[0];
    const overall = (r?.failing ?? 0) > 0 ? 'failed' : (r?.degraded ?? 0) > 0 ? 'degraded' : 'ok';
    return {
      receivablesAsOf: r?.receivables_as_of ? new Date(r.receivables_as_of).toISOString() : null,
      stockAsOf: r?.stock_as_of ? new Date(r.stock_as_of).toISOString() : null,
      overall,
    };
  }
}
