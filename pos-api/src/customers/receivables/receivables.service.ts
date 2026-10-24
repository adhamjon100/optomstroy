import { timingSafeEqual } from 'node:crypto';
import { Inject, Injectable, Optional } from '@nestjs/common';
import { StepUpTokenVerifier } from '../../auth/step-up/step-up-token.verifier.js';
import { auditContextFromRequest } from '../../common/audit/audit-context.js';
import { AuditService, type AuditStepUpMethod } from '../../common/audit/audit.service.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import type { AuthenticatedPrincipal } from '../../common/auth/principal.js';
import { OtpHmacService } from '../../common/crypto/otp-hmac.service.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { MONEY_AMOUNT_RE } from '../../common/money/money.js';
import type { SalesActor } from '../../common/ports/index.js';
import { ProblemException, type ProblemFieldError } from '../../common/problem-details/problem.exception.js';
import { MemoryWindowCounter } from '../../common/rate-limit/http-rate-limit.js';
import { PermissionCatalog } from '../../common/rbac/permission-catalog.js';
import type { PermissionCode } from '../../common/rbac/permissions.generated.js';
import { principalOf } from '../../admin/users/shared/principal.js';
import { presentOverdueCustomer, presentReceivable } from './receivables.presenter.js';
import { type OverdueSort, ReceivablesRepository, type ReceivablesCustomerRow } from './receivables.repository.js';
import { ReceivablesSnapshotService } from './receivables-snapshot.service.js';

/** Лимиты RL-RECV-REFRESH (08 §2.9; значения — предложение, Q-004/Q-251). */
export interface ReceivablesRefreshLimits {
  /** Синхронных запросов обновления на пользователя в минуту (08: 10). */
  readonly perUserPerMinute: number;
  /** Не более одного обращения к 1С на клиента за N секунд (08: 30). */
  readonly perCustomerSeconds: number;
}

export const RECEIVABLES_REFRESH_LIMITS = Symbol('RECEIVABLES_REFRESH_LIMITS');
export const DEFAULT_RECEIVABLES_REFRESH_LIMITS: ReceivablesRefreshLimits = {
  perUserPerMinute: 10,
  perCustomerSeconds: 30,
};

const DETAIL_OPERATION = 'customer.receivables.read.detail';
const OVERDUE_SORTS: readonly OverdueSort[] = ['overdueAmount:desc', 'overdueDays:desc', 'customerName:asc'];
const CURSOR_MAC_LENGTH = 32;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type Query = Record<string, unknown>;

function bad(errors: ProblemFieldError[]): ProblemException {
  return new ProblemException('VALIDATION_FAILED', { status: 400, detail: 'Запрос не прошёл проверку.', errors });
}

function single(q: Query, name: string): string | undefined {
  const v = q[name];
  if (v === undefined) return undefined;
  if (typeof v !== 'string') throw bad([{ field: name, rule: 'type', message: 'Ожидается одно значение.' }]);
  return v;
}

export function uuidParam(value: string, field = 'id'): string {
  if (!UUID_RE.test(value)) {
    throw bad([{ field, rule: 'uuid', message: 'Ожидается UUID.' }]);
  }
  return value.toLowerCase();
}

function includeDocuments(q: Query): boolean {
  const v = single(q, 'include');
  if (v === undefined || v === '') return false;
  if (v !== 'documents') throw bad([{ field: 'include', rule: 'enum', message: 'Допустимо: documents.' }]);
  return true;
}

function boolParam(q: Query, name: string): boolean {
  const v = single(q, name);
  if (v === undefined || v === '' || v === 'false') return false;
  if (v === 'true') return true;
  throw bad([{ field: name, rule: 'type', message: 'Ожидается true или false.' }]);
}

function salesActorOf(p: AuthenticatedPrincipal, requestId: string | null): SalesActor {
  return {
    userId: p.userId,
    roles: p.roles,
    isCustomer: p.kind === 'customer',
    sessionId: p.sessionId,
    deviceId: p.deviceId,
    requestId,
  };
}

/**
 * Долг клиента для HTTP (RM-G-002, RM-G-011): `GET /customers/{id}/receivables` (08 §4.11.5),
 * `POST /customers/{id}/receivables/refresh` (08 §4.11.8, ядро §19.2), `GET /receivables/overdue` (08 §4.12.1).
 * Данные — только снимок 1С (D-24); права — 11 §4.3–§4.4 (`customer.receivables.read.summary|detail`,
 * `customer.self.receivables.read`), field-level — SEC-031; аудит — 11 §7.2, SEC-032, SEC-073.
 *
 * Step-up детализации (`include=documents`, 10 DEBT-005, ядро §17.2) — `X-Step-Up-Token` со `scope`
 * `customer.receivables.read.detail` для **всех** ролей: токен выдаётся на 15 мин (`POST /auth/step-up`,
 * многоразовый в своей сессии), поэтому первый просмотр в сессии требует step-up, повторные в течение 15 мин — нет,
 * после 15 мин — снова (хранить отметку на сервере не нужно — GQ-CRD-01).
 */
@Injectable()
export class ReceivablesService {
  private readonly perUser = new MemoryWindowCounter();
  /** Последнее обращение к 1С по клиенту (RL-RECV-REFRESH «1 запрос на клиента за 30 с», в т. ч. неудачное). */
  private readonly lastAttempt = new Map<string, { readonly at: number; readonly ok: boolean }>();
  private readonly limits: ReceivablesRefreshLimits;

  constructor(
    private readonly repo: ReceivablesRepository,
    private readonly snapshots: ReceivablesSnapshotService,
    private readonly catalog: PermissionCatalog,
    private readonly stepUp: StepUpTokenVerifier,
    private readonly audit: AuditService,
    private readonly hmac: OtpHmacService,
    @Inject(CLOCK) private readonly clock: Clock,
    @Inject(APP_CONFIG) private readonly config: Pick<AppConfig, 'CUSTOMER_SELF_SERVICE'>,
    @Optional() @Inject(RECEIVABLES_REFRESH_LIMITS) limits?: Partial<ReceivablesRefreshLimits>,
  ) {
    this.limits = { ...DEFAULT_RECEIVABLES_REFRESH_LIMITS, ...limits };
  }

  // ------------------------------------------------------------------------------------------- GET receivables

  async view(req: RequestWithContext, rawId: string, q: Query): Promise<{ body: Record<string, unknown> }> {
    const p = principalOf(req);
    const id = uuidParam(rawId);
    const perms = this.catalog.effectivePermissions(p);
    const isCustomer = p.kind === 'customer';
    // Режим клиента выключен (CUSTOMER_SELF_SERVICE=false): строки `customer` матрицы не действуют — 403 (10 CASH-006,
    // 11 §4.2, T-CASH-014; ревью G-security-2).
    if (isCustomer && !this.config.CUSTOMER_SELF_SERVICE) throw forbidden();
    const wantDocs = includeDocuments(q);
    const wantRefresh = boolParam(q, 'refresh');
    if (isCustomer ? !perms.has('customer.self.receivables.read') : !perms.has('customer.receivables.read.summary')) {
      throw forbidden();
    }
    const stepUpMethod = wantDocs ? await this.detailStepUp(req, p, perms, isCustomer) : null;
    const customer = await this.repo.customer(null, id);
    if (!customer) throw notFound();
    // Свой клиент — только при подтверждённой привязке (CUST-023, AC-API-179): иначе 404 (существование не раскрывается).
    if (isCustomer && !(await this.repo.isConfirmedLink(p.userId, id))) throw notFound();
    // `refresh=true` (совместимость, 08 §4.11.5): те же лимиты RL-RECV-REFRESH; при недоступности 1С — снимок с isStale.
    let current = customer;
    if (wantRefresh && !isCustomer && customer.onecRef !== null) {
      this.consumeUserQuota(p.userId);
      if (await this.refreshOrKeep(p, customer, req, { failOnUnavailable: false })) {
        current = (await this.repo.customer(null, id)) ?? customer;
      }
    }
    const body = await this.build(current, { documents: wantDocs });
    await this.auditView(req, current, body, { detail: wantDocs, stepUpMethod, refresh: wantRefresh });
    return { body };
  }

  // ----------------------------------------------------------------------------------------- POST refresh

  async refresh(req: RequestWithContext, rawId: string, q: Query): Promise<{ body: Record<string, unknown> }> {
    const p = principalOf(req);
    const id = uuidParam(rawId);
    const perms = this.catalog.effectivePermissions(p);
    // seller, customer → 403 (RBAC: `customer.receivables.read.summary`; режим клиента — запрещён явно).
    if (p.kind === 'customer' || !perms.has('customer.receivables.read.summary')) throw forbidden();
    const wantDocs = includeDocuments(q);
    const stepUpMethod = wantDocs ? await this.detailStepUp(req, p, perms, false) : null;
    this.consumeUserQuota(p.userId);
    const customer = await this.repo.customer(null, id);
    if (!customer) throw notFound();
    if (customer.onecRef === null) {
      throw new ProblemException('CUSTOMER_NOT_IDENTIFIED', {
        detail: 'Клиента ещё нет в 1С: данных о долге нет.',
        reason: 'not_in_onec',
      });
    }
    const refreshed = await this.refreshOrKeep(p, customer, req, { failOnUnavailable: true });
    // Обновление снимка могло изменить условия соглашения (лимит, отсрочка) — карточка перечитывается.
    const fresh = (await this.repo.customer(null, id)) ?? customer;
    const body = await this.build(fresh, { documents: wantDocs, refreshed });
    await this.auditView(req, customer, body, { detail: wantDocs, stepUpMethod, refresh: true });
    return { body };
  }

  /**
   * Обновление снимка с ограничениями RL-RECV-REFRESH: идёт обновление по клиенту — присоединиться (single-flight);
   * снимок записан менее N с назад — без обращения к 1С (`refreshed=false`); последнее обращение к 1С по клиенту
   * менее N с назад было неудачным — без нового обращения (`503`, `retryAfter`). Возвращает `refreshed`.
   */
  private async refreshOrKeep(
    p: AuthenticatedPrincipal,
    customer: ReceivablesCustomerRow,
    req: RequestWithContext,
    o: { readonly failOnUnavailable: boolean },
  ): Promise<boolean> {
    const now = this.clock.now().getTime();
    const windowMs = this.limits.perCustomerSeconds * 1000;
    if (!this.snapshots.isRefreshing(customer.id)) {
      // Последнее обращение к 1С по клиенту в этом процессе (успешное или нет) — в пределах окна.
      const last = this.lastAttempt.get(customer.id);
      if (last !== undefined && now - last.at < windowMs) {
        if (last.ok || !o.failOnUnavailable) return false;
        throw new ProblemException('ONEC_UNAVAILABLE', {
          detail: '1С не ответила. Показаны данные последнего снимка — повторите позже.',
          retryAfter: Math.max(1, Math.ceil((last.at + windowMs - now) / 1000)),
        });
      }
      // Снимок записан недавно (в т. ч. другим экземпляром API или прогоном синхронизации) — без обращения к 1С.
      const current = await this.repo.snapshot(null, customer.id);
      if (current && now - current.syncedAt.getTime() < windowMs && now >= current.syncedAt.getTime()) return false;
    }
    // Повторная проверка после await: параллельный запрос мог уже начать обновление — присоединяемся к нему.
    const joining = this.snapshots.isRefreshing(customer.id);
    const r = await this.snapshots.refresh(customer.id, {
      actor: salesActorOf(p, typeof req.id === 'string' ? req.id : null),
    });
    if (!joining) {
      this.lastAttempt.set(customer.id, { at: now, ok: r.kind === 'refreshed' });
      if (this.lastAttempt.size > 10_000) this.pruneAttempts(now, windowMs);
    }
    if (r.kind === 'refreshed') return true;
    if (!o.failOnUnavailable) return false;
    if (r.kind === 'not_in_onec') {
      throw new ProblemException('CUSTOMER_NOT_IDENTIFIED', {
        detail: 'Клиент не найден в 1С: данных о долге нет.',
        reason: 'not_in_onec',
      });
    }
    throw new ProblemException('ONEC_UNAVAILABLE', {
      detail: '1С не ответила. Показаны данные последнего снимка — повторите позже.',
      retryAfter: this.limits.perCustomerSeconds,
      ...(r.snapshot ? { asOf: r.snapshot.snapshotAt.toISOString() } : {}),
    });
  }

  private pruneAttempts(now: number, windowMs: number): void {
    for (const [k, v] of this.lastAttempt) if (now - v.at >= windowMs) this.lastAttempt.delete(k);
  }

  private consumeUserQuota(userId: string): void {
    const limit = this.limits.perUserPerMinute;
    const r = this.perUser.consume(`recv-refresh:${userId}`, limit, this.clock.now().getTime());
    if (!r.allowed) {
      throw new ProblemException('RATE_LIMITED', {
        detail: 'Слишком много запросов обновления долга. Повторите позже.',
        retryAfter: r.retryAfterSec,
        headers: { 'X-RateLimit-Limit': String(limit), 'X-RateLimit-Remaining': '0' },
      });
    }
  }

  private async detailStepUp(
    req: RequestWithContext,
    p: AuthenticatedPrincipal,
    perms: ReadonlySet<PermissionCode>,
    isCustomer: boolean,
  ): Promise<AuditStepUpMethod> {
    // Детализация: сотрудник — `customer.receivables.read.detail`; клиент — `customer.self.receivables.read`.
    if (!isCustomer && !perms.has('customer.receivables.read.detail')) throw forbidden();
    const v = await this.stepUp.verify(req.headers['x-step-up-token'], p, {
      operation: DETAIL_OPERATION,
      detail: 'Подтвердите просмотр детализации долга PIN-кодом или кодом из SMS.',
    });
    return v.method;
  }

  private async build(
    customer: ReceivablesCustomerRow,
    o: { readonly documents: boolean; readonly refreshed?: boolean },
  ): Promise<Record<string, unknown>> {
    const maxAgeMinutes = await this.snapshots.maxAgeMinutes();
    const now = this.clock.now();
    const identified = customer.onecRef !== null;
    const snapshot = identified ? await this.snapshots.snapshot(null, customer.id, now) : null;
    const openOrdersAmount = identified ? await this.snapshots.openOrdersAmount(null, customer.id) : '0.00';
    const documents =
      o.documents && snapshot ? await this.snapshots.documents(null, customer.id) : o.documents ? [] : undefined;
    return presentReceivable({
      customer,
      snapshot,
      maxAgeMinutes,
      openOrdersAmount,
      ...(documents !== undefined ? { documents } : {}),
      ...(o.refreshed !== undefined ? { refreshed: o.refreshed } : {}),
    });
  }

  /**
   * Аудит просмотра (11 §7.2, SEC-032, SEC-073 — сразу после успешного чтения): `customer.debt_viewed` с объёмом
   * `summary|detail` и меткой снимка при каждом ответе с суммами; детализация — дополнительно `customer.finance.view`
   * (число документов, метка снимка, метод step-up). Ответ без сумм (`not_in_onec`, снимка нет) не аудируется.
   */
  private async auditView(
    req: RequestWithContext,
    customer: ReceivablesCustomerRow,
    body: Record<string, unknown>,
    o: { readonly detail: boolean; readonly stepUpMethod: AuditStepUpMethod | null; readonly refresh: boolean },
  ): Promise<void> {
    if (body.balance === null) return;
    const ctx = auditContextFromRequest(req);
    const snapshotAt = body.asOf as string;
    await this.audit.write(ctx, {
      action: 'customer.debt_viewed',
      entityType: 'customer',
      entityId: customer.id,
      // «refresh: true» 08 §4.11.8 — ключ `onecSync`: санитайзер аудита вырезает ключи с «refresh» (как токены),
      // GQ-CRD-09.
      after: { scope: o.detail ? 'detail' : 'summary', snapshotAt, ...(o.refresh ? { onecSync: true } : {}) },
    });
    if (o.detail) {
      await this.audit.write(ctx, {
        action: 'customer.finance.view',
        entityType: 'customer',
        entityId: customer.id,
        after: { documents: (body.documents as unknown[] | undefined)?.length ?? 0, snapshotAt },
        stepUpMethod: o.stepUpMethod,
      });
    }
  }

  // --------------------------------------------------------------------------------------- GET /receivables/overdue

  async overdue(req: RequestWithContext, q: Query): Promise<Record<string, unknown>> {
    principalOf(req);
    const errors: ProblemFieldError[] = [];
    const daysRaw = single(q, 'minOverdueDays');
    let minOverdueDays: number | null = null;
    if (daysRaw !== undefined) {
      if (!/^\d{1,6}$/.test(daysRaw)) errors.push({ field: 'minOverdueDays', rule: 'minimum', message: 'Целое ≥ 0.' });
      else minOverdueDays = Number(daysRaw);
    }
    const minAmount = single(q, 'minAmount') ?? null;
    if (minAmount !== null && !MONEY_AMOUNT_RE.test(minAmount)) {
      errors.push({ field: 'minAmount', rule: 'money_format', message: 'Сумма в формате 0.00.' });
    }
    const sortRaw = single(q, 'sort') ?? 'overdueAmount:desc';
    const sort = OVERDUE_SORTS.find((s) => s === sortRaw);
    if (!sort) errors.push({ field: 'sort', rule: 'sort_field', message: 'Неизвестная сортировка.' });
    const limitRaw = single(q, 'limit');
    let limit = 50;
    if (limitRaw !== undefined) {
      const n = /^\d{1,4}$/.test(limitRaw) ? Number(limitRaw) : NaN;
      if (!(n >= 1 && n <= 200)) errors.push({ field: 'limit', rule: 'range', message: 'Размер страницы 1…200.' });
      else limit = n;
    }
    if (errors.length > 0) throw bad(errors);
    const offset = this.decodeCursor(single(q, 'cursor'), sort as OverdueSort);
    const rows = await this.repo.overdue({ minOverdueDays, minAmount, sort: sort as OverdueSort, offset, limit });
    const page = rows.slice(0, limit);
    const hasMore = rows.length > limit;
    const maxAgeMinutes = await this.snapshots.maxAgeMinutes();
    const now = this.clock.now();
    const items = page.map((r) => {
      const v = this.snapshots.view(
        r.customer.id,
        {
          balance: r.balance,
          overdueAmount: r.overdueAmount,
          overdueDays: r.overdueDays,
          oldestDueDate: r.oldestDueDate,
          snapshotAt: r.snapshotAt,
          syncedAt: r.snapshotAt,
        },
        maxAgeMinutes,
        now,
      );
      return {
        stale: v.isStale,
        snapshotAt: r.snapshotAt,
        dto: {
          customer: presentOverdueCustomer(r.customer, true),
          balance: { amount: r.balance, currency: 'KGS' },
          overdueAmount: { amount: r.overdueAmount, currency: 'KGS' },
          overdueDays: r.overdueDays,
          oldestDueDate: r.oldestDueDate,
          asOf: r.snapshotAt.toISOString(),
        },
      };
    });
    const oldest = items.reduce<Date | null>((m, i) => (m === null || i.snapshotAt < m ? i.snapshotAt : m), null);
    await this.audit.write(auditContextFromRequest(req), {
      action: 'receivables.overdue_viewed',
      entityType: 'receivables',
      after: {
        filters: { minOverdueDays, minAmount, sort },
        rows: items.length,
        ...(offset > 0 ? { offset } : {}),
      },
    });
    return {
      items: items.map((i) => i.dto),
      nextCursor: hasMore ? this.encodeCursor(sort as OverdueSort, offset + limit) : null,
      hasMore,
      asOf: oldest ? oldest.toISOString() : null,
      isStale: items.some((i) => i.stale),
    };
  }

  private encodeCursor(sort: OverdueSort, offset: number): string {
    const body = Buffer.from(JSON.stringify([sort, offset]), 'utf8').toString('base64url');
    return `${body}.${this.mac(body)}`;
  }

  private decodeCursor(cursor: string | undefined, sort: OverdueSort): number {
    if (cursor === undefined || cursor === '') return 0;
    const invalid = (rule: string) =>
      bad([{ field: 'cursor', rule, message: 'Курсор недействителен — запросите список заново.' }]);
    const [body, mac, ...rest] = cursor.split('.');
    if (!body || !mac || rest.length > 0 || mac.length !== CURSOR_MAC_LENGTH) throw invalid('cursor');
    if (!timingSafeEqual(Buffer.from(this.mac(body), 'utf8'), Buffer.from(mac, 'utf8'))) throw invalid('cursor');
    let parsed: unknown;
    try {
      parsed = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
    } catch {
      throw invalid('cursor');
    }
    if (!Array.isArray(parsed) || typeof parsed[0] !== 'string' || !Number.isInteger(parsed[1]) || parsed[1] < 0) {
      throw invalid('cursor');
    }
    if (parsed[0] !== sort) throw invalid('cursor_sort_mismatch');
    return parsed[1] as number;
  }

  private mac(body: string): string {
    return this.hmac.pseudonym('cursor:receivables_overdue', body).slice(0, CURSOR_MAC_LENGTH);
  }
}

function forbidden(): ProblemException {
  return new ProblemException('FORBIDDEN', { detail: 'Недостаточно прав для просмотра долга клиента.' });
}

function notFound(): ProblemException {
  return new ProblemException('NOT_FOUND', { detail: 'Клиент не найден.' });
}
