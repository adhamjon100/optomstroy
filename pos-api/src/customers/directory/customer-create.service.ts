import { Inject, Injectable, Logger } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { type AuditContext, applyAuditGucs } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { CUSTOMER_TYPE_VALUES, type CustomerType } from '../../common/enums.js';
import { maskPhone } from '../../common/logging/redaction.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { customerDisplayName } from '../../common/presenters/customer-name.js';
import type { PosDatabase } from '../../db/database.js';
import { OnecOutboxWriterService } from '../../sync/outbox/onec-outbox.writer.js';
import { type CustomerViewer } from '../common/customer-access.js';
import { forbidden, invalid, UUID_RE } from '../common/customer-http.js';
import { CUSTOMER_MATCHING, type CustomerMatching, type OnecLookupState } from '../matching/customer-matching.port.js';

/** Тело `POST /customers` после проверки (08 §4.11.2; OpenAPI `CustomersCreateRequest`). */
export interface CustomerCreateInput {
  readonly name: string;
  readonly customerType: CustomerType;
  readonly phones: readonly string[];
  readonly inn: string | null;
  readonly address: string | null;
  readonly comment: string | null;
  readonly priceListId: string | null;
  readonly forceCreate: boolean;
  readonly forceReason: string | null;
}

const BODY_FIELDS = new Set([
  'name',
  'customerType',
  'phones',
  'inn',
  'address',
  'comment',
  'priceListId',
  'forceCreate',
  'forceReason',
]);
const E164_KG = /^\+996\d{9}$/;

/** Проверка тела по OpenAPI `CustomersCreateRequest` (`additionalProperties: false`; 08 §2.14). */
export function parseCreateBody(body: unknown): CustomerCreateInput {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) invalid('body', 'type', 'Тело — объект JSON.');
  const b = body as Record<string, unknown>;
  for (const k of Object.keys(b)) {
    if (!BODY_FIELDS.has(k)) invalid(k, 'additional_properties', `Поле ${k} не допускается.`);
  }
  const str = (k: string, min: number, max: number, nullable: boolean): string | null => {
    const v = b[k];
    if (v === undefined || v === null) {
      if (!nullable) invalid(k, 'required', `Поле ${k} обязательно.`);
      return null;
    }
    if (typeof v !== 'string') invalid(k, 'type', `${k} — строка.`);
    const t = v.trim();
    if (t.length < min) invalid(k, min <= 1 ? 'required' : 'min_length', `${k}: не короче ${min} символов.`);
    if (t.length > max) invalid(k, 'max_length', `${k}: не длиннее ${max} символов.`);
    return t;
  };
  const name = str('name', 2, 150, false) as string;
  const customerType = b.customerType;
  if (customerType === undefined || customerType === null)
    invalid('customerType', 'required', 'Тип клиента обязателен.');
  if (typeof customerType !== 'string' || !(CUSTOMER_TYPE_VALUES as readonly string[]).includes(customerType)) {
    invalid('customerType', 'enum', 'customerType: individual, entrepreneur или legal.');
  }
  const phonesRaw = b.phones;
  if (!Array.isArray(phonesRaw) || phonesRaw.length === 0)
    invalid('phones', 'min_items', 'Нужен хотя бы один телефон.');
  if (phonesRaw.length > 5) invalid('phones', 'max_items', 'Не более 5 телефонов.');
  const phones: string[] = [];
  for (const [i, p] of phonesRaw.entries()) {
    if (typeof p !== 'string' || !E164_KG.test(p))
      invalid(`phones[${i}]`, 'phone_e164', 'Телефон в формате +996XXXXXXXXX.');
    if (phones.includes(p)) invalid('phones', 'unique_items', 'Телефоны не повторяются.');
    phones.push(p);
  }
  const inn = b.inn === undefined || b.inn === null ? null : b.inn;
  if (inn !== null && (typeof inn !== 'string' || !/^\d{14}$/.test(inn))) invalid('inn', 'pattern', 'ИНН — 14 цифр.');
  const address = str('address', 0, 300, true);
  const comment = str('comment', 0, 500, true);
  const priceListId = b.priceListId === undefined || b.priceListId === null ? null : b.priceListId;
  if (priceListId !== null && (typeof priceListId !== 'string' || !UUID_RE.test(priceListId))) {
    invalid('priceListId', 'uuid', 'priceListId — UUID.');
  }
  const forceCreate = b.forceCreate === undefined || b.forceCreate === null ? false : b.forceCreate;
  if (typeof forceCreate !== 'boolean') invalid('forceCreate', 'type', 'forceCreate — true или false.');
  const reasonRaw = b.forceReason;
  let forceReason: string | null = null;
  if (forceCreate) {
    if (typeof reasonRaw !== 'string' || reasonRaw.trim().length < 5 || reasonRaw.trim().length > 200) {
      invalid('forceReason', 'force_reason_required', 'Укажите причину создания (5–200 символов).');
    }
    forceReason = reasonRaw.trim();
  } else if (reasonRaw !== undefined && reasonRaw !== null) {
    invalid('forceReason', 'force_reason_required', 'Причина передаётся только при forceCreate=true.');
  }
  return {
    name,
    customerType: customerType as CustomerType,
    phones,
    inn: inn,
    address: address === '' ? null : address,
    comment: comment === '' ? null : comment,
    priceListId: priceListId === null ? null : priceListId.toLowerCase(),
    forceCreate,
    forceReason,
  };
}

/** Кандидат дубля в `409 CUSTOMER_DUPLICATE_SUSPECTED` (08 §4.11.2: `id`, `displayName`, `phoneMasked`, `source`). */
export interface DuplicateCandidate {
  readonly id: string;
  readonly displayName: string;
  readonly phoneMasked: string | null;
  readonly source: string;
  readonly onecCode: string | null;
}

/**
 * Создание клиента `POST /customers` (08 §4.11.2; 10 CUST-010…CUST-016; 05 SYNC-049; RM-G-001, RM-G-011):
 * 1. `forceCreate=true` без `customer.create.force` → `403` (11 §4.3 код 66; `seller` выбирает существующего);
 * 2. дедупликация по каждому телефону через `CustomerMatching` RM-D-005 (реплика `customers`/`customer_contacts` +
 *    синхронный поиск 1С `GET /pos/v1/customers?phone=` при доступной 1С, CUST-012; недоступность 1С не блокирует —
 *    `ONEC_UNAVAILABLE` не возвращается) и по ИНН; есть кандидаты и нет `forceCreate` → `409
 *    CUSTOMER_DUPLICATE_SUSPECTED` с `candidates[]` (D-08, CUST-011);
 * 3. одна транзакция: `customers(source=pos, onec_status=pending, onec_ref=NULL)`, телефоны и адрес в
 *    `customer_contacts`, `onec_outbox(customer/create)` с телом `CustomerCreateRequest` 1С (`externalId` = id,
 *    `dedupe.failOnDuplicate = !forceCreate`), аудит `customer.created` (`forceCreate`, `forceReason`,
 *    `candidatesCount`, состояние проверки 1С) последней записью; после COMMIT — `outbox.dispatch`.
 * Подтверждение 1С (`onec_ref`) — обработчик `customers.onec-confirmed` (`CustomerOnecResultsHandler`).
 */
@Injectable()
export class CustomerCreateService {
  private readonly logger = new Logger('customers.create');

  constructor(
    @Inject(DRIZZLE) private readonly db: PosDatabase,
    @Inject(CUSTOMER_MATCHING) private readonly matching: CustomerMatching,
    private readonly outbox: OnecOutboxWriterService,
    private readonly audit: AuditService,
  ) {}

  async create(
    v: CustomerViewer,
    ctx: AuditContext,
    input: CustomerCreateInput,
    requestId: string | null,
  ): Promise<{ id: string; onecCheck: OnecLookupState }> {
    if (input.forceCreate && !v.permissions.has('customer.create.force')) forbidden();
    if (input.priceListId) {
      const pl = await this.db.execute<{ id: string }>(
        sql`SELECT id FROM price_lists WHERE id = ${input.priceListId}::uuid AND NOT deletion_mark`,
      );
      if (!pl.rows[0]) invalid('priceListId', 'not_found', 'Вид цены не найден.', 422);
    }
    const candidateIds = new Set<string>();
    const states = new Set<OnecLookupState>();
    for (const phone of input.phones) {
      const r = await this.matching.findByPhone(phone, { ...(requestId ? { requestId } : {}) });
      for (const c of r.candidates) candidateIds.add(c.customerId);
      states.add(r.onec);
    }
    const onecCheck: OnecLookupState = states.has('unavailable') ? 'unavailable' : states.has('ok') ? 'ok' : 'disabled';
    if (input.inn) {
      const byInn = await this.db.execute<{ id: string }>(sql`
        SELECT id FROM customers
         WHERE inn = ${input.inn} AND deleted_at IS NULL AND NOT deletion_mark AND NOT is_retail_default`);
      for (const r of byInn.rows) candidateIds.add(r.id);
    }
    if (onecCheck === 'unavailable') {
      // CUST-012: при недоступной 1С создание не блокируется («проверка в 1С недоступна, возможен дубль»).
      this.logger.warn({ event: 'customers.create.onec_check_unavailable' }, 'проверка дубля в 1С недоступна');
    }
    const candidates = await this.describe([...candidateIds]);
    if (candidates.length > 0 && !input.forceCreate) {
      throw new ProblemException('CUSTOMER_DUPLICATE_SUSPECTED', {
        detail: 'Найден клиент с таким телефоном или ИНН. Выберите существующего клиента.',
        candidates,
      });
    }
    const id = await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      // Сериализация создания по нормализованному телефону и ИНН (10 CUST-011; ревью G-customers-1c-3): проверка
      // реплики повторяется под блокировкой — параллельный POST /customers с тем же телефоном видит первую карточку.
      const keys = [
        ...input.phones.map((p) => `customer_phone:${p}`),
        ...(input.inn ? [`customer_inn:${input.inn}`] : []),
      ];
      for (const k of [...new Set(keys)].sort()) {
        await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtext(${k}))`);
      }
      if (!input.forceCreate) {
        const late = new Set<string>();
        for (const phone of input.phones) {
          const r = await this.matching.findByPhone(phone, { executor: tx, useOnec: false });
          for (const c of r.candidates) late.add(c.customerId);
        }
        if (input.inn) {
          const byInn = await tx.execute<{ id: string }>(sql`
            SELECT id FROM customers
             WHERE inn = ${input.inn} AND deleted_at IS NULL AND NOT deletion_mark AND NOT is_retail_default`);
          for (const r of byInn.rows) late.add(r.id);
        }
        if (late.size > 0) {
          throw new ProblemException('CUSTOMER_DUPLICATE_SUSPECTED', {
            detail: 'Найден клиент с таким телефоном или ИНН. Выберите существующего клиента.',
            candidates: await this.describe([...late], tx),
          });
        }
      }
      const ins = await tx.execute<{ id: string }>(sql`
        INSERT INTO customers (source, name, customer_type, inn, primary_phone_e164, phones_norm, default_price_list_id,
                               comment, created_by_user_id, force_reason, onec_status, credit_allowed)
        VALUES ('pos', ${input.name}, ${input.customerType}::customer_type, ${input.inn}, ${input.phones[0]},
                ${sql.param([...input.phones])}::text[], ${input.priceListId}::uuid, ${input.comment},
                ${v.userId}::uuid, ${input.forceReason}, 'pending', false)
        RETURNING id`);
      const customerId = ins.rows[0].id;
      for (const [i, phone] of input.phones.entries()) {
        await tx.execute(sql`
          INSERT INTO customer_contacts (customer_id, kind, label, value, value_norm, is_primary)
          VALUES (${customerId}::uuid, 'phone', 'Телефон', ${phone}, ${phone}, ${i === 0})`);
      }
      if (input.address) {
        await tx.execute(sql`
          INSERT INTO customer_contacts (customer_id, kind, label, value, value_norm, is_primary)
          VALUES (${customerId}::uuid, 'address', 'Адрес', ${input.address}, NULL, false)`);
      }
      const priceListRef = input.priceListId
        ? ((
            await tx.execute<{ ref: string | null }>(
              sql`SELECT onec_ref::text AS ref FROM price_lists WHERE id = ${input.priceListId}::uuid`,
            )
          ).rows[0]?.ref ?? null)
        : null;
      await this.outbox.enqueue(tx, {
        aggregateType: 'customer',
        aggregateId: customerId,
        operation: 'create',
        payload: {
          externalId: customerId,
          name: input.name,
          fullName: null,
          phone: input.phones[0],
          taxId: input.inn,
          kind: input.customerType,
          priceListRef,
          comment: input.comment,
          dedupe: { byPhone: true, failOnDuplicate: !input.forceCreate },
        },
        requestedByUserId: v.userId,
      });
      await this.audit.write(
        ctx,
        {
          action: 'customer.created',
          entityType: 'customer',
          entityId: customerId,
          after: {
            source: 'pos',
            customerType: input.customerType,
            forceCreate: input.forceCreate,
            candidatesCount: candidates.length,
            onecCheck,
          },
          reason: input.forceReason,
        },
        tx,
      );
      return customerId;
    });
    await this.outbox.kickAfterCommit();
    return { id, onecCheck };
  }

  private async describe(ids: readonly string[], ex: DbExecutor = this.db): Promise<DuplicateCandidate[]> {
    if (ids.length === 0) return [];
    const r = await ex.execute<{
      id: string;
      name: string;
      primary_phone_e164: string | null;
      source: string;
      onec_code: string | null;
    }>(sql`
      SELECT id, name, primary_phone_e164, source::text AS source, onec_code FROM customers
       WHERE id = ANY(${sql.param([...ids])}::uuid[]) AND deleted_at IS NULL
       ORDER BY (source = 'onec') DESC, name, id`);
    return r.rows.map((c) => ({
      id: c.id,
      displayName: customerDisplayName(c.name),
      phoneMasked: c.primary_phone_e164 ? maskPhone(c.primary_phone_e164) : null,
      source: c.source,
      onecCode: c.onec_code,
    }));
  }
}
