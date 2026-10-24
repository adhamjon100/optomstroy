import { Inject, Injectable } from '@nestjs/common';
import { and, asc, eq, gt, inArray, isNull, ne, sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { customerLinks, customers, receivables, userProfiles, users } from '../../db/schema/index.js';

export type CustomerLinkRow = typeof customerLinks.$inferSelect;
export type CustomerLinkStatusValue = CustomerLinkRow['status'];

/** Карточка клиента в объёме, нужном привязкам (без финансовых полей). */
export interface CustomerCardRow {
  readonly id: string;
  readonly name: string;
  readonly customerType: (typeof customers.$inferSelect)['customerType'];
  readonly onecRef: string | null;
  readonly onecCode: string | null;
  readonly source: (typeof customers.$inferSelect)['source'];
  readonly onecStatus: (typeof customers.$inferSelect)['onecStatus'];
  readonly primaryPhoneE164: string | null;
  readonly phonesNorm: string[];
  readonly inn: string | null;
  readonly isRetailDefault: boolean;
  readonly creditAllowed: boolean;
  readonly syncedAt: Date | null;
}

export interface LinkUserInfo {
  readonly userId: string;
  readonly phoneE164: string | null;
  readonly fullName: string | null;
  readonly displayName: string | null;
}

const cardColumns = {
  id: customers.id,
  name: customers.name,
  customerType: customers.customerType,
  onecRef: customers.onecRef,
  onecCode: customers.onecCode,
  source: customers.source,
  onecStatus: customers.onecStatus,
  primaryPhoneE164: customers.primaryPhoneE164,
  phonesNorm: customers.phonesNorm,
  inn: customers.inn,
  isRetailDefault: customers.isRetailDefault,
  creditAllowed: customers.creditAllowed,
  syncedAt: customers.syncedAt,
};

export interface ProposalInput {
  readonly userId: string;
  readonly customerId: string;
  readonly status: 'proposed' | 'conflict';
  readonly matchedPhoneE164: string;
  readonly conflictCandidates: readonly string[] | null;
}

export interface ResolveInput {
  readonly status: 'confirmed' | 'rejected';
  readonly resolvedByUserId: string;
  readonly reason?: string | null;
  readonly at: Date;
}

/**
 * `customer_links` (07 §5.30) и чтение карточек `customers` для привязок. Только доступ к данным; правила
 * (SEC-130, step-up, аудит) — `CustomerLinksService`. Object-level фильтры (`user_id = subject`,
 * `customer_id = :id`) — в SQL (11 SEC-030), а не пост-фильтрацией.
 */
@Injectable()
export class CustomerLinksRepository {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async findById(id: string, ex: DbExecutor = this.db): Promise<CustomerLinkRow | undefined> {
    const rows = await ex.select().from(customerLinks).where(eq(customerLinks.id, id)).limit(1);
    return rows[0];
  }

  /** Своя привязка (SEC-130: `user_id = subject`); `forUpdate` — блокировка строки в транзакции решения. */
  async findOwn(
    linkId: string,
    userId: string,
    ex: DbExecutor = this.db,
    forUpdate = false,
  ): Promise<CustomerLinkRow | undefined> {
    const q = ex
      .select()
      .from(customerLinks)
      .where(and(eq(customerLinks.id, linkId), eq(customerLinks.userId, userId)))
      .limit(1);
    const rows = forUpdate ? await q.for('update') : await q;
    return rows[0];
  }

  /** Привязка карточки (путь `/customers/{id}/links/{linkId}`). */
  async findForCustomer(
    linkId: string,
    customerId: string,
    ex: DbExecutor = this.db,
    forUpdate = false,
  ): Promise<CustomerLinkRow | undefined> {
    const q = ex
      .select()
      .from(customerLinks)
      .where(and(eq(customerLinks.id, linkId), eq(customerLinks.customerId, customerId)))
      .limit(1);
    const rows = forUpdate ? await q.for('update') : await q;
    return rows[0];
  }

  /** Все привязки пользователя (по времени предложения). */
  async listForUser(userId: string, ex: DbExecutor = this.db): Promise<CustomerLinkRow[]> {
    return ex
      .select()
      .from(customerLinks)
      .where(eq(customerLinks.userId, userId))
      .orderBy(asc(customerLinks.proposedAt), asc(customerLinks.id));
  }

  async listForCustomer(customerId: string, ex: DbExecutor = this.db): Promise<CustomerLinkRow[]> {
    return ex
      .select()
      .from(customerLinks)
      .where(eq(customerLinks.customerId, customerId))
      .orderBy(asc(customerLinks.proposedAt), asc(customerLinks.id));
  }

  /** Привязки пользователя в статусе (кроме `exceptId`) — для разрешения `conflict` и проверки «другая confirmed». */
  async listForUserByStatus(
    userId: string,
    status: CustomerLinkStatusValue,
    exceptId: string | null,
    ex: DbExecutor = this.db,
  ): Promise<CustomerLinkRow[]> {
    return ex
      .select()
      .from(customerLinks)
      .where(
        and(
          eq(customerLinks.userId, userId),
          eq(customerLinks.status, status),
          exceptId ? ne(customerLinks.id, exceptId) : undefined,
        ),
      )
      .for('update');
  }

  /** `confirmed`-привязки карточки к другим пользователям (SEC-130 «карточка уже привязана к другому пользователю»). */
  async confirmedByOthers(customerId: string, userId: string, ex: DbExecutor = this.db): Promise<CustomerLinkRow[]> {
    return ex
      .select()
      .from(customerLinks)
      .where(
        and(
          eq(customerLinks.customerId, customerId),
          eq(customerLinks.status, 'confirmed'),
          ne(customerLinks.userId, userId),
        ),
      );
  }

  /**
   * Предложение по результату поиска (09 §7.8 п. 3). Существующая пара `(user_id, customer_id)`:
   * `confirmed` не меняется; `rejected` по **тому же** телефону не возрождается (повторный поиск — только по новому
   * подтверждённому номеру, 09 §7.9); иначе — статус/телефон/кандидаты обновляются, решение сбрасывается.
   */
  async upsertProposal(input: ProposalInput, now: Date, ex: DbExecutor = this.db): Promise<CustomerLinkRow> {
    const candidates = input.conflictCandidates ? [...input.conflictCandidates] : null;
    const rows = await ex
      .insert(customerLinks)
      .values({
        userId: input.userId,
        customerId: input.customerId,
        status: input.status,
        matchMethod: 'phone',
        matchedPhoneE164: input.matchedPhoneE164,
        proposedAt: now,
        conflictCandidates: candidates,
      })
      .onConflictDoUpdate({
        target: [customerLinks.userId, customerLinks.customerId],
        set: {
          status: input.status,
          matchMethod: 'phone',
          matchedPhoneE164: input.matchedPhoneE164,
          proposedAt: now,
          conflictCandidates: candidates,
          confirmedByUserId: null,
          confirmedAt: null,
          rejectedAt: null,
          reason: null,
          updatedAt: sql`now()`,
        },
        setWhere: sql`${customerLinks.status} <> 'confirmed'
          AND NOT (${customerLinks.status} = 'rejected' AND ${customerLinks.matchedPhoneE164} IS NOT DISTINCT FROM ${input.matchedPhoneE164})`,
      })
      .returning();
    const row = rows[0] ?? (await this.findPair(input.userId, input.customerId, ex));
    if (!row) throw new Error('customer_links.upsertProposal: строка не найдена после INSERT');
    return row;
  }

  async findPair(userId: string, customerId: string, ex: DbExecutor = this.db): Promise<CustomerLinkRow | undefined> {
    const rows = await ex
      .select()
      .from(customerLinks)
      .where(and(eq(customerLinks.userId, userId), eq(customerLinks.customerId, customerId)))
      .limit(1);
    return rows[0];
  }

  /** Решение по привязке: `confirmed` (кто, когда) или `rejected`; `confirmed_by_user_id` — кто принял решение. */
  async resolve(id: string, input: ResolveInput, ex: DbExecutor = this.db): Promise<CustomerLinkRow> {
    const rows = await ex
      .update(customerLinks)
      .set({
        status: input.status,
        confirmedByUserId: input.resolvedByUserId,
        confirmedAt: input.status === 'confirmed' ? input.at : null,
        rejectedAt: input.status === 'rejected' ? input.at : null,
        reason: input.reason ?? null,
        updatedAt: sql`now()`,
      })
      .where(eq(customerLinks.id, id))
      .returning();
    const row = rows[0];
    if (!row) throw new Error('customer_links.resolve: строка не найдена');
    return row;
  }

  async findCard(customerId: string, ex: DbExecutor = this.db): Promise<CustomerCardRow | undefined> {
    const rows = await ex
      .select(cardColumns)
      .from(customers)
      .where(and(eq(customers.id, customerId), isNull(customers.deletedAt)))
      .limit(1);
    return rows[0];
  }

  async findCards(ids: readonly string[], ex: DbExecutor = this.db): Promise<Map<string, CustomerCardRow>> {
    if (ids.length === 0) return new Map();
    const rows = await ex
      .select(cardColumns)
      .from(customers)
      .where(inArray(customers.id, [...ids]));
    return new Map(rows.map((r) => [r.id, r]));
  }

  /** Телефон и ФИО пользователей (для `user {id, displayName, phoneMasked}`; полный телефон наружу не отдаётся). */
  async userInfo(ids: readonly string[], ex: DbExecutor = this.db): Promise<Map<string, LinkUserInfo>> {
    if (ids.length === 0) return new Map();
    const rows = await ex
      .select({
        userId: users.id,
        phoneE164: users.phoneE164,
        fullName: userProfiles.fullName,
        displayName: userProfiles.displayName,
      })
      .from(users)
      .leftJoin(userProfiles, eq(userProfiles.userId, users.id))
      .where(inArray(users.id, [...new Set(ids)]));
    return new Map(rows.map((r) => [r.userId, r]));
  }

  /** Флаги долга без сумм (08 §3.7 «индикатор»): `hasDebt`, `isOverdue`. */
  async debtFlags(
    ids: readonly string[],
    ex: DbExecutor = this.db,
  ): Promise<Map<string, { hasDebt: boolean; isOverdue: boolean }>> {
    if (ids.length === 0) return new Map();
    const rows = await ex
      .select({
        customerId: receivables.customerId,
        hasDebt: sql<boolean>`${receivables.balance} > 0`,
        isOverdue: sql<boolean>`coalesce(${receivables.overdueAmount}, 0) > 0`,
      })
      .from(receivables)
      .where(inArray(receivables.customerId, [...ids]));
    return new Map(rows.map((r) => [r.customerId, { hasDebt: r.hasDebt, isOverdue: r.isOverdue }]));
  }

  /**
   * Очередь администратора (`GET /customers?linkStatus=…`, 08 §4.11.1): карточки, у которых есть привязки в
   * статусах `statuses`, по возрастанию `customers.id` (курсор — последний id страницы).
   */
  async queueCustomerIds(
    statuses: readonly ('proposed' | 'conflict')[],
    limit: number,
    afterCustomerId: string | null,
    ex: DbExecutor = this.db,
  ): Promise<string[]> {
    const rows = await ex
      .selectDistinct({ customerId: customerLinks.customerId })
      .from(customerLinks)
      .innerJoin(customers, eq(customers.id, customerLinks.customerId))
      .where(
        and(
          inArray(customerLinks.status, [...statuses]),
          isNull(customers.deletedAt),
          afterCustomerId ? gt(customerLinks.customerId, afterCustomerId) : undefined,
        ),
      )
      .orderBy(asc(customerLinks.customerId))
      .limit(limit);
    return rows.map((r) => r.customerId);
  }

  async listForCustomersByStatus(
    customerIds: readonly string[],
    statuses: readonly ('proposed' | 'conflict')[],
    ex: DbExecutor = this.db,
  ): Promise<CustomerLinkRow[]> {
    if (customerIds.length === 0) return [];
    return ex
      .select()
      .from(customerLinks)
      .where(and(inArray(customerLinks.customerId, [...customerIds]), inArray(customerLinks.status, [...statuses])))
      .orderBy(asc(customerLinks.proposedAt), asc(customerLinks.id));
  }

  /** Активные администраторы — получатели уведомления о конфликте привязки (09 §7.8 п. 3 «задача администратору»). */
  async activeAdminIds(ex: DbExecutor = this.db): Promise<string[]> {
    const res = await ex.execute<{ id: string }>(sql`
      SELECT DISTINCT u.id
        FROM users u
        JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL
        JOIN roles r ON r.id = ur.role_id AND r.code = 'admin'
       WHERE u.status = 'active' AND u.deleted_at IS NULL
       ORDER BY u.id`);
    return res.rows.map((r) => r.id);
  }
}
