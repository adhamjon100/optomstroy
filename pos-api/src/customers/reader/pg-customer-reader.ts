import { Inject, Injectable } from '@nestjs/common';
import { type SQL, sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import type { CustomerLinkStatus, CustomerOnecStatus, CustomerSource, CustomerType } from '../../common/enums.js';
import type {
  CustomerAccess,
  CustomerCard,
  CustomerFieldPolicy,
  CustomerReader,
  SalesActor,
  SalesTx,
} from '../../common/ports/index.js';
import { CustomerAccessService } from '../common/customer-access.js';
import { VERIFIED_PHONES_SQL } from '../common/customer-rows.js';

interface CardRow extends Record<string, unknown> {
  id: string;
  name: string;
  customer_type: CustomerType;
  source: CustomerSource;
  onec_status: CustomerOnecStatus;
  onec_ref: string | null;
  onec_code: string | null;
  is_retail_default: boolean;
  deletion_mark: boolean;
  inn: string | null;
  primary_phone_e164: string | null;
  phones_norm: string[] | null;
  price_list_id: string | null;
  discount_percent: string | null;
  credit_allowed: boolean;
  credit_limit: string | null;
  credit_days: number | null;
  synced_at: Date | string | null;
  verified_phones: string[] | null;
}

/**
 * Реализация порта `CustomerReader` (RM-G-001; `common/ports/customer-reader.port.ts`) над `customers`: карточки для
 * межмодульных вызовов (`cart`, `orders`, `payments`, `returns`, `transactions`, отчёты, режим клиента) и политика
 * полей по ролям — те же правила, что у HTTP-ответов модуля (`CustomerAccessService.policyForActor`). Карточки с
 * `deleted_at` не существуют; помеченные на удаление в 1С (`deletion_mark`) — отдаются (ссылки на них допустимы).
 * `customer` видит только карточку с привязкой `confirmed` (иначе `null` → вызывающий отвечает 404, 08 AC-API-179).
 */
@Injectable()
export class PgCustomerReader implements CustomerReader {
  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    private readonly access: CustomerAccessService,
  ) {}

  async get(tx: SalesTx | null, customerId: string): Promise<CustomerCard | null> {
    return this.one(tx, sql`c.id = ${customerId}::uuid`);
  }

  async getByOnecRef(tx: SalesTx | null, onecRef: string): Promise<CustomerCard | null> {
    return this.one(tx, sql`c.onec_ref = ${onecRef}::uuid`);
  }

  async getForActor(
    tx: SalesTx | null,
    actor: SalesActor,
    customerId: string,
  ): Promise<{ readonly card: CustomerCard; readonly access: CustomerAccess } | null> {
    const policy = this.fieldPolicy(actor);
    if (actor.isCustomer || actor.roles.includes('customer')) {
      if (!actor.userId) return null;
      const link = await this.linkOf(tx, actor.userId);
      if (!link || link.status !== 'confirmed' || link.customerId !== customerId) return null;
      const card = await this.get(tx, customerId);
      return card ? { card, access: { kind: 'self', policy, linkId: link.linkId } } : null;
    }
    // Сотрудник — по `customer.read.basic`; системный субъект (job, `userId = null`) — без ограничений.
    if (actor.userId !== null && !this.access.actorCan(actor, 'customer.read.basic')) return null;
    const card = await this.get(tx, customerId);
    return card ? { card, access: { kind: 'staff', policy } } : null;
  }

  fieldPolicy(actor: SalesActor): CustomerFieldPolicy {
    return this.access.policyForActor(actor);
  }

  async linkOf(
    tx: SalesTx | null,
    userId: string,
  ): Promise<{ readonly customerId: string; readonly status: CustomerLinkStatus; readonly linkId: string } | null> {
    return this.access.linkOf(userId, tx ?? this.db);
  }

  private async one(tx: SalesTx | null, where: SQL): Promise<CustomerCard | null> {
    const ex = tx ?? this.db;
    const r = await ex.execute<CardRow>(sql`
      SELECT c.id, c.name, c.customer_type::text AS customer_type, c.source::text AS source,
             c.onec_status::text AS onec_status, c.onec_ref::text AS onec_ref, c.onec_code, c.is_retail_default,
             c.deletion_mark, c.inn, c.primary_phone_e164, c.phones_norm, c.default_price_list_id::text AS price_list_id,
             c.discount_percent::text AS discount_percent, c.credit_allowed, c.credit_limit::text AS credit_limit,
             c.credit_days::int AS credit_days, c.synced_at, ${VERIFIED_PHONES_SQL} AS verified_phones
        FROM customers c WHERE ${where} AND c.deleted_at IS NULL`);
    const x = r.rows[0];
    if (!x) return null;
    const phones = new Set<string>();
    if (x.primary_phone_e164) phones.add(x.primary_phone_e164);
    for (const p of x.phones_norm ?? []) if (/^\+996\d{9}$/.test(p)) phones.add(p);
    const syncedAt = x.synced_at === null ? null : x.synced_at instanceof Date ? x.synced_at : new Date(x.synced_at);
    // CUST-003: «подтверждён» — номер, подтверждённый OTP при привязке аккаунта (`confirmed`).
    const verified = (p: string): boolean => (x.verified_phones ?? []).includes(p);
    return {
      id: x.id,
      name: x.name,
      customerType: x.customer_type,
      source: x.source,
      onecStatus: x.onec_status,
      onecRef: x.onec_ref,
      onecCode: x.onec_code,
      isRetailDefault: x.is_retail_default,
      deletionMark: x.deletion_mark,
      inn: x.inn,
      primaryPhoneE164: x.primary_phone_e164,
      phones: [...phones].map((value) => ({ value, verified: verified(value) })),
      priceListId: x.price_list_id,
      discountPercent: x.discount_percent,
      creditAllowed: x.credit_allowed,
      creditLimit: x.credit_limit,
      creditDays: x.credit_days === null ? null : Number(x.credit_days), // money-double: allow — дни отсрочки
      syncedAt,
    };
  }
}
