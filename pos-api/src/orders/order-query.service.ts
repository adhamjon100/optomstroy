import { timingSafeEqual } from 'node:crypto';
import { Inject, Injectable, Logger } from '@nestjs/common';
import { type SQL, sql } from 'drizzle-orm';
import { APP_CONFIG, type AppConfig } from '../common/config/app-config.js';
import { OtpHmacService } from '../common/crypto/otp-hmac.service.js';
import { DRIZZLE, type Database } from '../common/db/database.module.js';
import { isOrderStatus, isPaymentMethod, ORDER_STATUS_VALUES, type OrderStatus } from '../common/enums.js';
import { NOTIFICATIONS_PORT, type NotificationsPort } from '../common/ports/index.js';
import { ProblemException } from '../common/problem-details/problem.exception.js';
import { ONEC_GATEWAY, type OnecGateway } from '../integrations/onec/onec-gateway.js';
import type { OrderViewer } from './order-access.js';
import { loadCustomers, loadUserRefs, presentOrderSummary } from './order-presenter.js';
import { OrderProjector, parseOnecOrderDocument } from './order-projection.js';
import { type OrderInclude, OrderViewService } from './order-view.service.js';
import { orderColumnsSql, type OrderRow, pgArray } from './order.repository.js';
import { validationFailed } from './orders.request.js';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const LIMIT_DEFAULT = 50;
const LIMIT_MAX = 200;
const MAX_RANGE_MS = 366 * 86_400_000;
const SORTS = {
  'createdAt:desc': sql.raw('o.created_at DESC, o.id DESC'),
  'total:desc': sql.raw('o.total DESC, o.id DESC'),
  'status:asc': sql.raw('o.status ASC, o.created_at DESC, o.id DESC'),
} as const;
type SortKey = keyof typeof SORTS;

function str(v: unknown): string | undefined {
  if (Array.isArray(v)) return str(v[0]);
  return typeof v === 'string' && v !== '' ? v : undefined;
}

function bad(field: string, rule: string, message: string): ProblemException {
  return validationFailed([{ field, rule, message }]);
}

function parseUuidParam(v: unknown, field: string): string | undefined {
  const s = str(v);
  if (s === undefined) return undefined;
  if (!UUID_RE.test(s)) throw bad(field, 'uuid', 'Ожидается UUID.');
  return s.toLowerCase();
}

function parseDate(v: unknown, field: string): Date | undefined {
  const s = str(v);
  if (s === undefined) return undefined;
  const d = new Date(s);
  if (Number.isNaN(d.getTime())) throw bad(field, 'date_time', 'Ожидается дата-время ISO-8601.');
  return d;
}

export interface OrdersListQuery {
  readonly statuses: OrderStatus[] | null;
  readonly customerId?: string;
  readonly createdBy?: string;
  readonly from?: Date;
  readonly to?: Date;
  readonly paymentMethod?: string;
  readonly isPaid?: boolean;
  readonly q?: string;
  readonly idempotencyKey?: string;
  readonly statusCounts: boolean;
  readonly limit: number;
  readonly offset: number;
  readonly sort: SortKey;
}

/**
 * Чтение заказов: `GET /orders` (фильтры, `mine`/все по правам, `include=statusCounts`, `totalEstimate`, поиск по
 * ключу идемпотентности — 08 §4.8.2, ядро §19.2, §22.6), `GET /orders/{id}` (+ `refreshFromOnec`, 08 §4.8.3) и
 * история заказов POS клиента `GET /customers/{id}/orders` (08 §4.11.4; продажи 1С — RM-G-001).
 */
@Injectable()
export class OrderQueryService {
  private readonly logger = new Logger('orders.query');
  private readonly projector: OrderProjector;

  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    @Inject(ONEC_GATEWAY) private readonly onec: OnecGateway,
    @Inject(NOTIFICATIONS_PORT) notifications: NotificationsPort,
    private readonly views: OrderViewService,
    private readonly hmac: OtpHmacService,
  ) {
    this.projector = new OrderProjector(notifications, (msg, data) => this.logger.warn(data ?? {}, msg));
  }

  parseListQuery(q: Record<string, unknown>, viewer: OrderViewer): OrdersListQuery {
    let statuses: OrderStatus[] | null = null;
    const rawStatus = q.status;
    if (rawStatus !== undefined && rawStatus !== '') {
      const parts = (Array.isArray(rawStatus) ? rawStatus : [rawStatus]).flatMap((v) => String(v).split(','));
      if (parts.length > 11 || parts.some((p) => !isOrderStatus(p.trim()))) {
        throw bad('status', 'enum', 'Значения вне перечня order_status.');
      }
      statuses = [...new Set(parts.map((p) => p.trim() as OrderStatus))];
    }
    const createdBy = parseUuidParam(q.createdBy, 'createdBy');
    if (createdBy && !viewer.permissions.has('order.read.all')) {
      throw new ProblemException('FORBIDDEN', {
        detail: 'Фильтр по автору доступен только при праве чтения всех заказов.',
      });
    }
    const from = parseDate(q.from, 'from');
    const to = parseDate(q.to, 'to');
    if (from && to && (from > to || to.getTime() - from.getTime() > MAX_RANGE_MS)) {
      throw bad('from', 'date_range', 'Период: from ≤ to, не более 366 дней.');
    }
    const pm = str(q.paymentMethod);
    if (pm !== undefined && !isPaymentMethod(pm)) throw bad('paymentMethod', 'enum', 'Значение вне перечня.');
    const isPaidRaw = str(q.isPaid);
    if (isPaidRaw !== undefined && isPaidRaw !== 'true' && isPaidRaw !== 'false') {
      throw bad('isPaid', 'type', 'Ожидается true или false.');
    }
    const include = str(q.include);
    if (include !== undefined && include !== 'statusCounts') throw bad('include', 'enum', 'Допустимо: statusCounts.');
    const limitRaw = str(q.limit);
    const limit = limitRaw === undefined ? LIMIT_DEFAULT : Number(limitRaw);
    if (!Number.isInteger(limit) || limit < 1 || limit > LIMIT_MAX)
      throw bad('limit', 'range', `Целое 1…${LIMIT_MAX}.`);
    const sort = (str(q.sort) ?? 'createdAt:desc') as SortKey;
    if (!Object.hasOwn(SORTS, sort))
      throw bad('sort', 'sort_field', 'Допустимо: createdAt:desc, total:desc, status:asc.');
    const qs = str(q.q);
    if (qs !== undefined && qs.length > 64) throw bad('q', 'max_length', 'Не длиннее 64 символов.');
    return {
      statuses,
      ...(parseUuidParam(q.customerId, 'customerId') ? { customerId: parseUuidParam(q.customerId, 'customerId') } : {}),
      ...(createdBy ? { createdBy } : {}),
      ...(from ? { from } : {}),
      ...(to ? { to } : {}),
      ...(pm ? { paymentMethod: pm } : {}),
      ...(isPaidRaw !== undefined ? { isPaid: isPaidRaw === 'true' } : {}),
      ...(qs ? { q: qs } : {}),
      ...(parseUuidParam(q.idempotencyKey, 'idempotencyKey')
        ? { idempotencyKey: parseUuidParam(q.idempotencyKey, 'idempotencyKey') }
        : {}),
      statusCounts: include === 'statusCounts',
      limit,
      offset: this.decodeCursor(q.cursor, sort),
      sort,
    };
  }

  /** Условия видимости и фильтров (без `status` — для `statusCounts`). */
  private where(viewer: OrderViewer, f: OrdersListQuery, withStatus: boolean): SQL {
    const parts: SQL[] = [sql`o.status <> 'draft'`];
    if (!viewer.permissions.has('order.read.all')) {
      const me = viewer.actor.userId;
      parts.push(
        viewer.linkedCustomerId
          ? sql`(o.created_by_user_id = ${me}::uuid OR o.customer_id = ${viewer.linkedCustomerId}::uuid)`
          : sql`o.created_by_user_id = ${me}::uuid`,
      );
    }
    if (withStatus && f.statuses) parts.push(sql`o.status::text = ANY(${pgArray(f.statuses)}::text[])`);
    if (f.customerId) parts.push(sql`o.customer_id = ${f.customerId}::uuid`);
    if (f.createdBy) parts.push(sql`o.created_by_user_id = ${f.createdBy}::uuid`);
    if (f.from) parts.push(sql`o.created_at >= ${f.from.toISOString()}::timestamptz`);
    if (f.to) parts.push(sql`o.created_at <= ${f.to.toISOString()}::timestamptz`);
    if (f.paymentMethod) parts.push(sql`o.payment_method = ${f.paymentMethod}::payment_method`);
    if (f.isPaid !== undefined) parts.push(sql`o.is_paid = ${f.isPaid}::boolean`);
    if (f.q) {
      const like = `%${f.q.replace(/[%_\\]/g, (c) => `\\${c}`)}%`;
      parts.push(sql`(o.public_number ILIKE ${like} OR o.onec_number ILIKE ${like})`);
    }
    if (f.idempotencyKey) {
      // Только заказы текущего пользователя (ядро §22.6, 08 §2.7).
      parts.push(sql`o.idempotency_key = ${f.idempotencyKey} AND o.created_by_user_id = ${viewer.actor.userId}::uuid`);
    }
    return sql.join(parts, sql.raw(' AND '));
  }

  async list(viewer: OrderViewer, f: OrdersListQuery): Promise<Record<string, unknown>> {
    const where = this.where(viewer, f, true);
    const rows = (
      await this.db.execute<OrderRow & { items_count: number }>(sql`
        SELECT ${orderColumnsSql}, (SELECT count(*)::int FROM order_items c WHERE c.order_id = o.id) AS items_count
          FROM orders o WHERE ${where}
         ORDER BY ${SORTS[f.sort]} LIMIT ${f.limit + 1} OFFSET ${f.offset}`)
    ).rows;
    const countRow = (await this.db.execute<{ n: number }>(sql`SELECT count(*)::int AS n FROM orders o WHERE ${where}`))
      .rows[0];
    const hasMore = rows.length > f.limit;
    const page = rows.slice(0, f.limit);
    const customers = await loadCustomers(
      this.db,
      page.map((o) => o.customer_id),
    );
    const users = await loadUserRefs(
      this.db,
      page.map((o) => o.created_by_user_id),
    );
    const items: Record<string, unknown>[] = [];
    for (const o of page) {
      items.push(
        presentOrderSummary(o, {
          actor: viewer.actor,
          permissions: viewer.permissions,
          customer: customers.get(o.customer_id),
          users,
          payments: await this.views.paymentsOf(o.id),
          documents: await this.views.documentsOf(o, viewer.actor),
          createOutbox: null,
        }),
      );
    }
    const out: Record<string, unknown> = {
      items,
      nextCursor: hasMore ? this.encodeCursor(f.offset + f.limit, f.sort) : null,
      hasMore,
      totalEstimate: Number(countRow?.n ?? 0), // money-double: allow — число заказов, не деньги
      isEstimate: false,
    };
    if (f.statusCounts) {
      const counts = await this.db.execute<{ status: OrderStatus; n: number }>(sql`
        SELECT o.status::text AS status, count(*)::int AS n FROM orders o WHERE ${this.where(viewer, f, false)}
         GROUP BY o.status`);
      const sc: Record<string, number> = {}; // money-double: allow — счётчики заказов по статусам
      for (const s of ORDER_STATUS_VALUES) if (s !== 'draft') sc[s] = 0;
      for (const r of counts.rows) sc[r.status] = Number(r.n); // money-double: allow — счётчик заказов
      out.statusCounts = sc;
    }
    return out;
  }

  async get(viewer: OrderViewer, id: string, q: Record<string, unknown>): Promise<Record<string, unknown>> {
    if (!UUID_RE.test(id)) throw new ProblemException('NOT_FOUND', { detail: 'Заказ не найден.' });
    let include: Set<OrderInclude> | undefined;
    const rawInclude = q.include;
    if (rawInclude !== undefined && rawInclude !== '') {
      const parts = (Array.isArray(rawInclude) ? rawInclude : [rawInclude]).flatMap((v) => String(v).split(','));
      const allowed: OrderInclude[] = ['items', 'payments', 'history', 'documents'];
      if (parts.some((p) => !allowed.includes(p.trim() as OrderInclude))) {
        throw bad('include', 'enum', 'Допустимо: items, payments, history, documents.');
      }
      include = new Set(parts.map((p) => p.trim() as OrderInclude));
    }
    let o = await this.views.loadVisible(this.db, viewer, id);
    const warnings: { code: string; message: string }[] = [];
    if (str(q.refreshFromOnec) === 'true' && !viewer.actor.isCustomer) {
      const ok = await this.refreshFromOnec(o);
      if (!ok) {
        warnings.push({ code: 'STALE_DATA', message: 'Статус из 1С не получен: показан последний снимок.' });
      }
      o = await this.views.loadVisible(this.db, viewer, id);
    }
    return this.views.present(this.db, viewer, o, { ...(include ? { include } : {}), warnings });
  }

  /** Синхронный запрос статуса в 1С (`getOrderStatus`, ≤ 6000 мс); `false` — 1С недоступна / документ не найден. */
  private async refreshFromOnec(o: OrderRow): Promise<boolean> {
    if (!o.onec_ref) return false;
    try {
      const r = await this.onec.getOrderStatus(o.id, {
        signal: AbortSignal.timeout(this.config.ONEC_SYNC_CHECK_TIMEOUT_MS),
      });
      const doc = parseOnecOrderDocument(r.body);
      if (doc.ref && doc.ref !== o.onec_ref) return false;
      await this.db.transaction(async (tx) => {
        // Документ прочитан по externalId и сопоставлен по onec_ref → `linked` (07 §6.5, как синхронизация статусов).
        await this.projector.apply(tx, {
          orderId: o.id,
          source: 'onec_sync',
          actorUserId: null,
          onec: doc,
          ...(doc.ref === o.onec_ref ? { syncState: 'linked' as const } : {}),
        });
      });
      return true;
    } catch (e) {
      this.logger.warn({ err: e, orderId: o.id }, 'orders.refresh_from_onec.failed');
      return false;
    }
  }

  // Курсор: смещение, подписанное HMAC (08 §2.5: непрозрачный; подделка → 400 rule cursor).
  private encodeCursor(offset: number, scope: string): string {
    const body = Buffer.from(JSON.stringify([offset, scope]), 'utf8').toString('base64url');
    return `${body}.${this.mac(body)}`;
  }

  private decodeCursor(raw: unknown, scope: string): number {
    const c = str(raw);
    if (c === undefined) return 0;
    const [body, mac, ...rest] = c.split('.');
    const fail = () => bad('cursor', 'cursor', 'Курсор недействителен — запросите список заново.');
    if (!body || !mac || rest.length > 0 || mac.length !== 32) throw fail();
    if (!timingSafeEqual(Buffer.from(this.mac(body), 'utf8'), Buffer.from(mac, 'utf8'))) throw fail();
    try {
      const v: unknown = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
      if (Array.isArray(v) && Number.isInteger(v[0]) && v[0] >= 0 && v[1] === scope) return v[0] as number;
    } catch {
      // ниже
    }
    throw fail();
  }

  private mac(body: string): string {
    return this.hmac.pseudonym('cursor:orders', body).slice(0, 32);
  }
}
