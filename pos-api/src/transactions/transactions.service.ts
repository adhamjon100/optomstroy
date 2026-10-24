import { createHash, timingSafeEqual } from 'node:crypto';
import { Inject, Injectable, Logger } from '@nestjs/common';
import { type AuditContext } from '../common/audit/audit-context.js';
import { AuditService } from '../common/audit/audit.service.js';
import { OtpHmacService } from '../common/crypto/otp-hmac.service.js';
import { DRIZZLE, type Database } from '../common/db/database.module.js';
import {
  isPaymentMethod,
  isTransactionKind,
  type PaymentMethod,
  type TransactionKind,
  type TransactionSource,
} from '../common/enums.js';
import {
  AUDIT_QUERY_PORT,
  type AuditQueryPort,
  type AuditRowView,
  PortNotBoundError,
  type SalesActor,
} from '../common/ports/index.js';
import { ProblemException, type ProblemFieldError } from '../common/problem-details/problem.exception.js';
import type { PermissionCode } from '../common/rbac/permissions.generated.js';
import {
  loadTxUserRefs,
  presentTransaction,
  selectTransactionById,
  selectTransactions,
  summarizeTransactions,
  TRANSACTION_STATUS_GROUPS,
  type TransactionRowDb,
  type TransactionStatusGroup,
  type TransactionsFilter,
  type TransactionsKeyset,
  type TransactionsSort,
} from './transactions.sql.js';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MONEY_RE = /^-?\d{1,12}\.\d{2}$/;
const LIMIT_DEFAULT = 50;
const LIMIT_MAX = 200;
const DAY_MS = 86_400_000;
/** Максимальный период журналов — 366 дней (ядро §19.4; 10 TXN-002). */
export const MAX_PERIOD_MS = 366 * DAY_MS;
const BISHKEK_OFFSET_MS = 6 * 3_600_000;
const SORTS: readonly TransactionsSort[] = ['occurredAt:desc', 'amount:desc'];
const MAC_HEX = 32;
const VIEWED_ALL_CACHE = 10_000;

export interface TransactionsViewer {
  readonly actor: SalesActor;
  readonly userId: string;
  readonly sessionId: string;
  readonly perms: ReadonlySet<PermissionCode>;
  readonly audit: AuditContext;
}

export interface TransactionsQuery {
  readonly filter: TransactionsFilter;
  readonly sort: TransactionsSort;
  readonly limit: number;
  readonly after?: TransactionsKeyset;
  /** Нормализованный набор фильтров (для агрегирования аудита `transaction.viewed_all`). */
  readonly fingerprint: string;
}

function bad(errors: ProblemFieldError[]): ProblemException {
  return new ProblemException('VALIDATION_FAILED', { status: 400, detail: 'Запрос не прошёл проверку.', errors });
}

function one(v: unknown): string | undefined {
  const s: unknown = Array.isArray(v) ? (v as unknown[])[0] : v;
  return typeof s === 'string' && s !== '' ? s : undefined;
}

/** Значения списка: `a,b` и повтор параметра (`?kind=a&kind=b`) — 08 §2.6. */
function many(v: unknown): string[] | undefined {
  if (v === undefined || v === '') return undefined;
  const parts = (Array.isArray(v) ? v : [v]).flatMap((x) => String(x).split(',')).map((x) => x.trim());
  return parts.filter((x) => x !== '');
}

/** Начало суток по Бишкеку для момента `d` (UTC). */
export function bishkekDayStart(d: Date): Date {
  const local = new Date(d.getTime() + BISHKEK_OFFSET_MS);
  return new Date(Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate()) - BISHKEK_OFFSET_MS);
}

/**
 * Журнал операций (08 §4.14; 10 TXN-001…TXN-004, TXN-011; 13 RM-G-004, RM-G-011): `GET /transactions` — фильтры,
 * keyset-курсор, `summary` (только `transactions.read.all`), видимость `seller` — только свои (в SQL, TXN-004);
 * `GET /transactions/{id}` — связанные документы и записи аудита по объекту (только `audit.read`, через
 * `AUDIT_QUERY_PORT`). Аудит `transaction.viewed_all` — при выборке с чужими данными, раз на сессию и набор фильтров.
 */
@Injectable()
export class TransactionQueryService {
  private readonly logger = new Logger('transactions');
  /** Уже записанные `transaction.viewed_all` (сессия + фильтры) — агрегирование в пределах процесса. */
  private readonly viewedAll = new Set<string>();

  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    private readonly hmac: OtpHmacService,
    private readonly audit: AuditService,
    @Inject(AUDIT_QUERY_PORT) private readonly auditQuery: AuditQueryPort,
  ) {}

  parse(q: Record<string, unknown>, viewer: TransactionsViewer, now: Date = new Date()): TransactionsQuery {
    const errors: ProblemFieldError[] = [];
    const readAll = viewer.perms.has('transactions.read.all');
    const date = (field: string): Date | undefined => {
      const v = one(q[field]);
      if (v === undefined) return undefined;
      const d = new Date(v);
      if (Number.isNaN(d.getTime())) {
        errors.push({ field, rule: 'date_time', message: 'Ожидается дата-время ISO-8601.' });
        return undefined;
      }
      return d;
    };
    const today = bishkekDayStart(now);
    const from = date('from') ?? today;
    const to = date('to') ?? new Date(today.getTime() + DAY_MS - 1);
    if (from > to || to.getTime() - from.getTime() > MAX_PERIOD_MS) {
      errors.push({
        field: 'from',
        rule: 'date_range',
        message: 'Период: from ≤ to, не более 366 дней.',
        params: { maxDays: 366 },
      });
    }
    const uuid = (field: string): string | undefined => {
      const v = one(q[field]);
      if (v === undefined) return undefined;
      if (!UUID_RE.test(v)) {
        errors.push({ field, rule: 'uuid', message: 'Ожидается UUID.' });
        return undefined;
      }
      return v.toLowerCase();
    };
    const customerId = uuid('customerId');
    const actorId = uuid('actorId');
    let statusGroups: TransactionStatusGroup[] | undefined;
    const st = many(q.status);
    if (st) {
      if (st.length > 50 || st.some((s) => !(TRANSACTION_STATUS_GROUPS as readonly string[]).includes(s))) {
        errors.push({ field: 'status', rule: 'enum', message: `Допустимо: ${TRANSACTION_STATUS_GROUPS.join(', ')}.` });
      } else statusGroups = [...new Set(st as TransactionStatusGroup[])];
    }
    let kinds: TransactionKind[] | undefined;
    const kd = many(q.kind);
    if (kd) {
      if (kd.length > 50 || kd.some((k) => !isTransactionKind(k))) {
        errors.push({ field: 'kind', rule: 'enum', message: 'Значение вне перечня transaction_kind.' });
      } else kinds = [...new Set(kd as TransactionKind[])];
    }
    const sourceRaw = one(q.source);
    let source: TransactionSource | undefined;
    if (sourceRaw !== undefined) {
      if (sourceRaw !== 'pos' && sourceRaw !== 'onec') {
        errors.push({ field: 'source', rule: 'enum', message: 'Допустимо: pos, onec.' });
      } else source = sourceRaw;
    }
    const mineRaw = one(q.mine);
    let mine = false;
    if (mineRaw !== undefined) {
      if (!['true', 'false', '1', '0'].includes(mineRaw)) {
        errors.push({ field: 'mine', rule: 'boolean', message: 'Ожидается true или false.' });
      } else mine = mineRaw === 'true' || mineRaw === '1';
    }
    const pmRaw = one(q.paymentMethod);
    let paymentMethod: PaymentMethod | undefined;
    if (pmRaw !== undefined) {
      if (!isPaymentMethod(pmRaw))
        errors.push({ field: 'paymentMethod', rule: 'enum', message: 'Значение вне перечня.' });
      else paymentMethod = pmRaw;
    }
    const moneyParam = (field: string): string | undefined => {
      const v = one(q[field]);
      if (v === undefined) return undefined;
      if (!MONEY_RE.test(v)) {
        errors.push({ field, rule: 'money_format', message: 'Сумма строкой с двумя знаками («1500.00»).' });
        return undefined;
      }
      return v.replace(/^-/, '');
    };
    const amountMin = moneyParam('amountMin');
    const amountMax = moneyParam('amountMax');
    const qs = one(q.q)?.trim();
    if (qs !== undefined && qs.length > 200)
      errors.push({ field: 'q', rule: 'max_length', message: 'Не длиннее 200.' });
    const limitRaw = one(q.limit);
    const limit = limitRaw === undefined ? LIMIT_DEFAULT : Number(limitRaw); // money-double: allow — размер страницы
    if (!Number.isInteger(limit) || limit < 1 || limit > LIMIT_MAX) {
      errors.push({ field: 'limit', rule: 'range', message: `Целое 1…${LIMIT_MAX}.` });
    }
    const sortRaw = one(q.sort) ?? 'occurredAt:desc';
    if (!(SORTS as readonly string[]).includes(sortRaw)) {
      errors.push({ field: 'sort', rule: 'sort_field', message: 'Допустимо: occurredAt:desc, amount:desc.' });
    }
    if (errors.length > 0) throw bad(errors);
    // 08 §4.14.1: `actorId` — только `transactions.read.all` (403, а не 400).
    if (actorId && !readAll) {
      throw new ProblemException('FORBIDDEN', {
        detail: 'Фильтр по исполнителю доступен только при чтении всех операций.',
      });
    }
    const sort = sortRaw as TransactionsSort;
    const filter: TransactionsFilter = {
      from,
      to,
      ...(customerId ? { customerId } : {}),
      ...(statusGroups ? { statusGroups } : {}),
      ...(kinds ? { kinds } : {}),
      ...(source ? { source } : {}),
      // TXN-004: `seller` (`transactions.read.own`) — только свои, `mine` применяется всегда; `read.all` — по `mine`.
      ...(!readAll || mine ? { ownerUserId: viewer.userId } : {}),
      ...(actorId ? { actorId } : {}),
      ...(paymentMethod ? { paymentMethod } : {}),
      ...(amountMin ? { amountMin } : {}),
      ...(amountMax ? { amountMax } : {}),
      ...(qs ? { q: qs } : {}),
    };
    const fingerprint = createHash('sha256')
      .update(
        JSON.stringify(
          Object.entries({ ...filter, from: from.toISOString(), to: to.toISOString(), sort }).sort(([x], [y]) =>
            x.localeCompare(y),
          ),
        ),
      )
      .digest('hex');
    const after = this.decodeCursor(one(q.cursor), sort);
    return { filter, sort, limit, ...(after ? { after } : {}), fingerprint };
  }

  async list(viewer: TransactionsViewer, query: TransactionsQuery): Promise<Record<string, unknown>> {
    const rows = await selectTransactions(this.db, query.filter, query.sort, query.limit, query.after);
    const hasMore = rows.length > query.limit;
    const page = rows.slice(0, query.limit);
    const users = await loadTxUserRefs(
      this.db,
      page.map((r) => r.actor_user_id),
    );
    const last = page.at(-1);
    const readAll = viewer.perms.has('transactions.read.all');
    const summary = readAll ? await summarizeTransactions(this.db, query.filter) : null;
    if (readAll && !query.filter.ownerUserId) await this.auditViewedAll(viewer, query);
    return {
      items: page.map((r) => presentTransaction(r, users)),
      nextCursor: hasMore && last ? this.encodeCursor(query.sort, last) : null,
      hasMore,
      ...(summary
        ? {
            summary: {
              count: summary.count,
              sumIn: { amount: summary.sumIn, currency: 'KGS' },
              sumOut: { amount: summary.sumOut, currency: 'KGS' },
            },
          }
        : {}),
    };
  }

  /** `GET /transactions/{id}` (08 §4.14.2): чужая для `seller` — 404; `audit[]` — только `audit.read`. */
  async get(viewer: TransactionsViewer, id: string): Promise<Record<string, unknown>> {
    if (!UUID_RE.test(id)) throw new ProblemException('NOT_FOUND', { detail: 'Операция не найдена.' });
    const t = await selectTransactionById(this.db, id.toLowerCase());
    if (!t || !this.canSee(viewer, t)) throw new ProblemException('NOT_FOUND', { detail: 'Операция не найдена.' });
    const users = await loadTxUserRefs(this.db, [t.actor_user_id]);
    const dto = presentTransaction(t, users);
    if (!viewer.perms.has('audit.read')) return dto;
    const audit = await this.auditRows(viewer, t);
    // Блок `audit[]` — чтение журнала аудита: событие `audit.viewed` (11 SEC-083, SEC-073, §7.2; словарь аудита —
    // 11, ядро §18.1; ревью G-security-7). Пустой блок записей журнала не раскрывает — событие не пишется.
    if (audit.length > 0) {
      await this.audit.write(viewer.audit, {
        action: 'audit.viewed',
        entityType: 'audit_logs',
        after: { source: 'transaction', transactionId: t.id, rowsReturned: audit.length },
      });
    }
    return { ...dto, audit };
  }

  /** TXN-004: `read.all` — все; `read.own` — автор операции или автор заказа. */
  private canSee(viewer: TransactionsViewer, t: TransactionRowDb): boolean {
    if (viewer.perms.has('transactions.read.all')) return true;
    if (!viewer.perms.has('transactions.read.own')) return false;
    return t.actor_user_id === viewer.userId || t.order_author === viewer.userId;
  }

  private async auditRows(viewer: TransactionsViewer, t: TransactionRowDb): Promise<Record<string, unknown>[]> {
    const targets: [string, string][] = [];
    if (t.order_id) targets.push(['order', t.order_id], ['orders', t.order_id]);
    if (t.payment_id) targets.push(['payment', t.payment_id], ['payments', t.payment_id]);
    if (t.return_request_id) {
      targets.push(['return_request', t.return_request_id], ['return_requests', t.return_request_id]);
    }
    const seen = new Map<string, AuditRowView>();
    try {
      for (const [type, eid] of targets) {
        for (const row of await this.auditQuery.forEntity(null, viewer.actor, type, eid, 50)) seen.set(row.id, row);
      }
    } catch (e) {
      if (!(e instanceof PortNotBoundError)) throw e;
      this.logger.warn({ transactionId: t.id }, 'transactions.audit_unavailable: AuditQueryPort не привязан');
      return [];
    }
    return [...seen.values()]
      .sort((a, b) => b.occurredAt.getTime() - a.occurredAt.getTime())
      .slice(0, 50)
      .map(presentAuditRow);
  }

  /** `transaction.viewed_all` (08 §4.14.1; D-36, 11 SEC-032): раз на сессию и набор фильтров. */
  private async auditViewedAll(viewer: TransactionsViewer, query: TransactionsQuery): Promise<void> {
    const key = `${viewer.sessionId}:${query.fingerprint}`;
    if (this.viewedAll.has(key)) return;
    if (this.viewedAll.size >= VIEWED_ALL_CACHE) this.viewedAll.clear();
    this.viewedAll.add(key);
    const f = query.filter;
    await this.audit.write(viewer.audit, {
      action: 'transaction.viewed_all',
      entityType: 'transaction',
      after: {
        from: f.from.toISOString(),
        to: f.to.toISOString(),
        customerId: f.customerId ?? null,
        kinds: f.kinds ?? null,
        statusGroups: f.statusGroups ?? null,
        actorId: f.actorId ?? null,
        paymentMethod: f.paymentMethod ?? null,
        source: f.source ?? null,
        q: f.q ? 'set' : null,
      },
    });
  }

  private encodeCursor(sort: TransactionsSort, last: TransactionRowDb): string {
    const value = sort === 'amount:desc' ? last.amount : last.occurred_key;
    const body = Buffer.from(JSON.stringify({ o: sort, s: value, id: last.id }), 'utf8').toString('base64url');
    return `${body}.${this.mac(body)}`;
  }

  private decodeCursor(raw: string | undefined, sort: TransactionsSort): TransactionsKeyset | undefined {
    if (raw === undefined) return undefined;
    const fail = () =>
      bad([{ field: 'cursor', rule: 'cursor', message: 'Курсор недействителен — запросите список заново.' }]);
    const [body, mac, ...rest] = raw.split('.');
    if (!body || !mac || rest.length > 0 || mac.length !== MAC_HEX) throw fail();
    if (!timingSafeEqual(Buffer.from(this.mac(body), 'utf8'), Buffer.from(mac, 'utf8'))) throw fail();
    let v: unknown;
    try {
      v = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
    } catch {
      throw fail();
    }
    const c = v as { o?: unknown; s?: unknown; id?: unknown };
    if (typeof c.o !== 'string' || typeof c.s !== 'string' || typeof c.id !== 'string' || !UUID_RE.test(c.id)) {
      throw fail();
    }
    if (c.o !== sort) {
      throw bad([{ field: 'cursor', rule: 'cursor_sort_mismatch', message: 'Курсор выдан для другой сортировки.' }]);
    }
    return { value: c.s, id: c.id };
  }

  private mac(body: string): string {
    return this.hmac.pseudonym('cursor:transactions', body).slice(0, MAC_HEX);
  }
}

/** `AuditRow` (08 §4.18.7): значения `before/after` уже маскированы портом по `viewer`. */
export function presentAuditRow(r: AuditRowView): Record<string, unknown> {
  return {
    id: r.id,
    occurredAt: r.occurredAt.toISOString(),
    ...(r.requestId ? { requestId: r.requestId } : {}),
    actor: r.actorUserId
      ? { id: r.actorUserId, displayName: r.actorName ?? 'Сотрудник', ...(r.actorRole ? { role: r.actorRole } : {}) }
      : null,
    ...(r.actorRole ? { actorRole: r.actorRole } : {}),
    sessionId: r.sessionId,
    deviceId: r.deviceId,
    ip: r.ip,
    appVersion: r.appVersion,
    action: r.action,
    entityType: r.entityType,
    entityId: r.entityId,
    onecRef: r.onecRef,
    before: r.before,
    after: r.after,
    result: r.result,
    stepUpMethod: r.stepUpMethod,
    reason: r.reason,
    rowHash: r.rowHash,
    chainOk: r.chainOk,
  };
}
