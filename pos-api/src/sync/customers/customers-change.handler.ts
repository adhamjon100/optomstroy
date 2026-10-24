import { createHash } from 'node:crypto';
import type pg from 'pg';
import type { SyncEntity } from '../../common/enums.js';
import { Money, Quantity } from '../../common/money/money.js';
import type { ApplyScope, ChangeItemHandler, ItemError } from '../apply/apply.types.js';
import { entityCounts } from '../apply/replica-writer.js';
import { type OnecContactPhone, parseContactPhones } from './customer-phones.js';
import { UNREFERENCED_STUB_GUARD } from './customer-stub.js';

export const ONEC_PARTNER = 'Catalog_Партнеры';
export const ONEC_COUNTERPARTY = 'Catalog_Контрагенты';
export const ONEC_AGREEMENT = 'Catalog_СоглашенияСКлиентами';
export const ONEC_SHIPMENT = 'Document_РеализацияТоваровУслуг';

const CUSTOMER_TYPES = new Set(['individual', 'entrepreneur', 'legal']);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MONEY_RE = /^-?\d{1,12}\.\d{2}$/;
const BISHKEK_OFFSET_MS = 6 * 3_600_000;

type Item = Readonly<Record<string, unknown>>;

export interface CustomersChangeHandlerOptions {
  /** Глубина истории продаж в POS (`SALES_HISTORY_MONTHS`, 05 SYNC-008; ядро §17.3). */
  readonly salesHistoryMonths: number;
  readonly now?: () => Date;
}

function str(v: unknown): string | null {
  return typeof v === 'string' && v.trim() !== '' ? v.trim() : null;
}

function ref(v: unknown): string | null {
  const s = str(v);
  return s && UUID_RE.test(s) ? s.toLowerCase() : null;
}

function hashOf(item: Item): string {
  const { dataVersion: _dv, ...rest } = item;
  return createHash('sha256').update(JSON.stringify(rest), 'utf8').digest('hex');
}

/** `YYYY-MM-DD` того же дня `months` месяцев назад (день > длины месяца → последний день). */
export function monthsBack(date: string, months: number): string {
  const [y, m, d] = date.split('-').map((x) => Number(x)) as [number, number, number];
  const total = y * 12 + (m - 1) - months;
  const yy = Math.floor(total / 12);
  const mm = total % 12;
  const last = new Date(Date.UTC(yy, mm + 1, 0)).getUTCDate();
  return new Date(Date.UTC(yy, mm, Math.min(d, last))).toISOString().slice(0, 10);
}

/** Граница истории продаж: сегодня (Бишкек) − `months` месяцев (GQ-FND-10: по дате Бишкека). */
export function salesHistoryFrom(months: number, now: Date): string {
  return monthsBack(new Date(now.getTime() + BISHKEK_OFFSET_MS).toISOString().slice(0, 10), months);
}

/** Наименование для CHECK `customers_name_chk` (2…200 символов). */
function customerName(v: unknown): string {
  const t = (str(v) ?? '').slice(0, 200);
  return t.length >= 2 ? t : `${t}__`.slice(0, 2);
}

interface CustomerRef {
  readonly id: string;
  readonly source: 'onec' | 'pos';
  readonly onecAgreementRef: string | null;
}

/**
 * Обработчик элементов плана обмена «POS» для клиентов и истории продаж (05 §6.2, §5.3 ONEC-011…ONEC-013,
 * SYNC-005, SYNC-018, SYNC-049; 07 §5.28–§5.29, §5.42–§5.43 «писатели столбцов»; RM-G-001):
 *
 * - `Catalog_Партнеры` → `customers` (upsert по `onec_ref`): наименование, код, пометка удаления, основное
 *   соглашение, телефоны партнёра; карточка, созданная в POS (`externalId` = `customers.id`, SYNC-005), получает
 *   `onec_ref` и `onec_status = confirmed`, строка outbox клиента `sent → confirmed` (`confirmed_by_sync`);
 * - `Catalog_Контрагенты` → ИНН, `onec_counterparty_ref`, вид клиента (`kind` — предложение GQ-FND-03; нет — прежний,
 *   у новой карточки `legal`), телефоны контрагента;
 * - `Catalog_СоглашенияСКлиентами` (основное соглашение партнёра) → вид цены, отсрочка (`credit_allowed`), лимит,
 *   дни, скидка клиента (`discountPercent` — предложение GQ-FND-04; нет — `NULL`, DISC-007);
 * - телефоны (`customer_contacts`, ONEC-012): набор стороны (партнёр `p:N` / контрагент `c:N`) заменяется целиком,
 *   нормализация в E.164; исчезновение телефона, по которому привязан пользователь, переводит `customer_links`
 *   (`proposed`/`confirmed`) в `conflict` (AC-ONEC-012);
 * - `Document_РеализацияТоваровУслуг` → `shipments`/`shipment_items` (`sync_entity = sales_history`): только в глубине
 *   `SALES_HISTORY_MONTHS` (старее — пропуск), связь с заказом POS по `orderExternalId`/`orderRef`, товары/упаковки
 *   по ссылкам 1С; без итога документа — Σ строк (ONEC-106);
 * - `ObjectDeletion` этих типов — пометка удаления (физически строки не удаляются: на них ссылаются заказы,
 *   платежи, заявки на возврат).
 *
 * Модуль `sync` не импортирует `customers` (06 §7.4): только таблицы-реплики. Ошибки позиций — `sync_errors`
 * (без ПДн: ни телефонов, ни ИНН, SEC-061), прогоны — `customers` и `sales_history`.
 */
export class CustomersChangeHandler implements ChangeItemHandler {
  readonly types: readonly string[] = [ONEC_PARTNER, ONEC_COUNTERPARTY, ONEC_AGREEMENT, ONEC_SHIPMENT];
  private readonly now: () => Date;

  constructor(private readonly options: CustomersChangeHandlerOptions) {
    this.now = options.now ?? (() => new Date());
  }

  entityOf(item: Item): SyncEntity | undefined {
    const type = item.type === 'ObjectDeletion' ? item.objectType : item.type;
    return type === ONEC_SHIPMENT ? 'sales_history' : 'customers';
  }

  async apply(scope: ApplyScope, items: readonly Item[]): Promise<void> {
    const byType = (t: string): Item[] => items.filter((i) => i.type === t);
    const deletions = items.filter((i) => i.type === 'ObjectDeletion');
    const counterparties = byType(ONEC_COUNTERPARTY);
    const kindByPartner = new Map<string, string>();
    for (const c of counterparties) {
      const p = ref(c.partnerRef);
      const k = str(c.kind);
      if (p && k && CUSTOMER_TYPES.has(k)) kindByPartner.set(p, k);
    }
    for (const it of byType(ONEC_PARTNER)) await this.applyPartner(scope, it, kindByPartner);
    for (const it of counterparties) await this.applyCounterparty(scope, it);
    for (const it of byType(ONEC_AGREEMENT)) await this.applyAgreement(scope, it);
    for (const it of deletions) {
      if (it.objectType !== ONEC_SHIPMENT) await this.applyCatalogDeletion(scope, it);
    }
    for (const it of byType(ONEC_SHIPMENT)) await this.applyShipment(scope, it);
    for (const it of deletions) {
      if (it.objectType === ONEC_SHIPMENT) await this.applyShipmentDeletion(scope, it);
    }
  }

  // ---------------------------------------------------------------------------------------------------- клиенты

  private async applyPartner(scope: ApplyScope, it: Item, kindByPartner: ReadonlyMap<string, string>): Promise<void> {
    const c = entityCounts(scope, 'customers');
    c.fetched += 1;
    const onecRef = ref(it.ref);
    if (!onecRef) return this.error(scope, 'customers', 'VALIDATION', 'Партнёр без корректного ref', null);
    const hash = hashOf(it);
    const client = scope.client;
    type Row = { id: string; source: 'onec' | 'pos'; source_hash: string | null; onec_status: string };
    let row: Row | undefined = (
      await client.query<Row>(
        `SELECT id, source::text AS source, source_hash, onec_status::text AS onec_status
           FROM customers WHERE onec_ref = $1::uuid`,
        [onecRef],
      )
    ).rows[0];
    const externalId = ref(it.externalId);
    let adopted = false;
    if (row && externalId && externalId !== row.id) {
      // Ref занят строкой-заглушкой поиска дубля (CustomerMatching), а 1С вернула externalId POS-клиента без
      // onec_ref: заглушка удаляется, Ref переходит к POS-строке (05 SYNC-005; ревью G-customers-1c-2).
      const pos = await client.query(
        `SELECT 1 FROM customers WHERE id = $1::uuid AND onec_ref IS NULL AND deleted_at IS NULL`,
        [externalId],
      );
      if (pos.rows.length > 0) {
        const del = await client.query(
          `DELETE FROM customers s WHERE s.id = $1::uuid ${UNREFERENCED_STUB_GUARD} RETURNING s.id`,
          [row.id],
        );
        if (del.rows.length > 0) row = undefined;
      }
    }
    if (!row && externalId) {
      // SYNC-005: карточка создана в POS — 1С вернула её externalId.
      const pos = await client.query<{ id: string; source: 'onec' | 'pos'; onec_status: string }>(
        `UPDATE customers SET onec_ref = $2::uuid, onec_status = 'confirmed', updated_at = now()
          WHERE id = $1::uuid AND onec_ref IS NULL AND deleted_at IS NULL
          RETURNING id, source::text AS source, onec_status::text AS onec_status`,
        [externalId, onecRef],
      );
      if (pos.rows[0]) {
        row = { ...pos.rows[0], source_hash: null };
        adopted = true;
      }
    }
    if (row && row.source_hash === hash && !adopted) {
      c.skipped += 1;
      return;
    }
    const code = str(it.code);
    const codeOwner = code
      ? (await client.query<{ id: string }>(`SELECT id FROM customers WHERE onec_code = $1`, [code])).rows[0]
      : undefined;
    const codeValue = codeOwner && codeOwner.id !== row?.id ? null : code;
    if (codeOwner && codeOwner.id !== row?.id) {
      this.error(scope, 'customers', 'DUPLICATE_SUSPECTED', 'Код партнёра уже занят другой карточкой', onecRef, code);
    }
    const name = customerName(it.description);
    const deletion = it.deletionMark === true;
    const mainAgreement = ref(it.mainAgreementRef);
    let id: string;
    if (row) {
      id = row.id;
      await client.query(
        `UPDATE customers SET onec_code = $2, onec_data_version = $3, deletion_mark = $4, synced_at = $5,
                source_hash = $6, name = $7, onec_agreement_ref = coalesce($8::uuid, onec_agreement_ref),
                onec_status = CASE WHEN source = 'pos' AND onec_status IN ('pending','rejected','duplicate')
                                   AND $9::boolean THEN 'confirmed'::customer_onec_status ELSE onec_status END,
                updated_at = now()
          WHERE id = $1::uuid`,
        [id, codeValue, str(it.dataVersion), deletion, scope.syncedAt, hash, name, mainAgreement, externalId === id],
      );
      c.updated += 1;
    } else {
      const kind = kindByPartner.get(onecRef) ?? 'legal';
      id = (
        await client.query<{ id: string }>(
          `INSERT INTO customers (onec_ref, onec_code, onec_data_version, deletion_mark, synced_at, source_hash, source,
                                  name, customer_type, onec_agreement_ref, onec_status)
           VALUES ($1::uuid, $2, $3, $4, $5, $6, 'onec', $7, $8::customer_type, $9::uuid, 'n_a')
           RETURNING id`,
          [onecRef, codeValue, str(it.dataVersion), deletion, scope.syncedAt, hash, name, kind, mainAgreement],
        )
      ).rows[0].id;
      c.inserted += 1;
    }
    if (deletion) c.markedDeleted += 1;
    if (row?.source === 'pos' && (adopted || externalId === id)) {
      // 07 §6.5: `sent → confirmed` по синхронизации (элемент партнёра с externalId карточки POS).
      await client.query(
        `UPDATE onec_outbox SET status = 'confirmed', updated_at = now()
          WHERE aggregate_type = 'customer' AND aggregate_id = $1::uuid AND operation = 'create' AND status = 'sent'`,
        [id],
      );
    }
    await this.replacePhones(scope, id, 'p', parseContactPhones(it.phones));
  }

  private async applyCounterparty(scope: ApplyScope, it: Item): Promise<void> {
    const c = entityCounts(scope, 'customers');
    c.fetched += 1;
    const onecRef = ref(it.ref);
    const partnerRef = ref(it.partnerRef);
    const customer = partnerRef ? await this.customerByRef(scope.client, partnerRef) : null;
    if (!onecRef || !customer) {
      return this.error(scope, 'customers', 'NOT_FOUND_LOCAL', 'Контрагент без известного партнёра', onecRef);
    }
    const taxId = str(it.taxId);
    const inn = taxId && /^\d{14}$/.test(taxId) ? taxId : null;
    if (taxId && !inn) this.error(scope, 'customers', 'VALIDATION', 'ИНН контрагента не 14 цифр (не записан)', onecRef);
    const kind = str(it.kind);
    const deletion = it.deletionMark === true;
    await scope.client.query(
      `UPDATE customers SET onec_counterparty_ref = CASE WHEN $4 THEN NULL ELSE $2::uuid END,
              inn = CASE WHEN $4 THEN inn ELSE $3 END,
              customer_type = coalesce($5::customer_type, customer_type), synced_at = $6, updated_at = now()
        WHERE id = $1::uuid`,
      [customer.id, onecRef, inn, deletion, kind && CUSTOMER_TYPES.has(kind) ? kind : null, scope.syncedAt],
    );
    c.updated += 1;
    await this.replacePhones(scope, customer.id, 'c', deletion ? [] : parseContactPhones(it.phones));
  }

  private async applyAgreement(scope: ApplyScope, it: Item): Promise<void> {
    const c = entityCounts(scope, 'customers');
    c.fetched += 1;
    const onecRef = ref(it.ref);
    const partnerRef = ref(it.partnerRef);
    const customer = partnerRef ? await this.customerByRef(scope.client, partnerRef) : null;
    if (!onecRef || !customer) {
      return this.error(scope, 'customers', 'NOT_FOUND_LOCAL', 'Соглашение без известного партнёра', onecRef);
    }
    if (customer.onecAgreementRef !== null && customer.onecAgreementRef !== onecRef) {
      c.skipped += 1; // не основное соглашение партнёра
      return;
    }
    const deletion = it.deletionMark === true;
    let priceListId: string | null | undefined = null;
    const priceRef = ref(it.priceListRef);
    if (priceRef) {
      priceListId = (
        await scope.client.query<{ id: string }>(`SELECT id FROM price_lists WHERE onec_ref = $1::uuid`, [priceRef])
      ).rows[0]?.id;
      if (!priceListId) {
        this.error(
          scope,
          'customers',
          'NOT_FOUND_LOCAL',
          'Вид цены соглашения не загружен (оставлен прежний)',
          onecRef,
        );
      }
    }
    const limitRaw = str(it.creditLimit);
    let creditLimit: string | null = null;
    if (limitRaw !== null) {
      if (MONEY_RE.test(limitRaw) && !Money.of(limitRaw).isNegative()) creditLimit = Money.of(limitRaw).toString();
      else this.error(scope, 'customers', 'VALIDATION', 'Лимит долга соглашения некорректен (не записан)', onecRef);
    }
    const days =
      typeof it.creditDays === 'number' && Number.isInteger(it.creditDays) && it.creditDays >= 0 ? it.creditDays : null;
    const pctRaw = str(it.discountPercent);
    const discountPercent = pctRaw && /^(\d{1,2}(\.\d{1,2})?|100(\.0{1,2})?)$/.test(pctRaw) ? pctRaw : null;
    await scope.client.query(
      `UPDATE customers SET onec_agreement_ref = CASE WHEN $2 THEN NULL ELSE $3::uuid END,
              default_price_list_id = CASE WHEN $4::boolean THEN default_price_list_id ELSE $5::uuid END,
              credit_allowed = $6, credit_limit = $7::numeric, credit_days = $8, discount_percent = $9::numeric,
              synced_at = $10, updated_at = now()
        WHERE id = $1::uuid`,
      [
        customer.id,
        deletion,
        onecRef,
        priceListId === undefined,
        priceListId ?? null,
        !deletion && it.creditAllowed === true,
        deletion ? null : creditLimit,
        deletion ? null : days,
        deletion ? null : discountPercent,
        scope.syncedAt,
      ],
    );
    c.updated += 1;
  }

  private async applyCatalogDeletion(scope: ApplyScope, it: Item): Promise<void> {
    const c = entityCounts(scope, 'customers');
    c.fetched += 1;
    const onecRef = ref(it.ref);
    if (!onecRef) return;
    const client = scope.client;
    if (it.objectType === ONEC_PARTNER) {
      const r = await client.query(
        `UPDATE customers SET deletion_mark = true, synced_at = $2, updated_at = now()
          WHERE onec_ref = $1::uuid AND NOT deletion_mark`,
        [onecRef, scope.syncedAt],
      );
      c.markedDeleted += r.rowCount ?? 0;
    } else if (it.objectType === ONEC_COUNTERPARTY) {
      const r = await client.query<{ id: string }>(
        `UPDATE customers SET onec_counterparty_ref = NULL, updated_at = now()
          WHERE onec_counterparty_ref = $1::uuid RETURNING id`,
        [onecRef],
      );
      for (const row of r.rows) await this.replacePhones(scope, row.id, 'c', []);
      c.updated += r.rowCount ?? 0;
    } else if (it.objectType === ONEC_AGREEMENT) {
      const r = await client.query(
        `UPDATE customers SET onec_agreement_ref = NULL, credit_allowed = false, credit_limit = NULL, credit_days = NULL,
                updated_at = now()
          WHERE onec_agreement_ref = $1::uuid`,
        [onecRef],
      );
      c.updated += r.rowCount ?? 0;
    }
  }

  /**
   * Замена телефонов стороны (`p` — партнёр, `c` — контрагент) и пересчёт `primary_phone_e164`/`phones_norm`.
   * Контакты без ключа строки 1С (созданные в POS или иным загрузчиком) считаются стороной партнёра.
   */
  private async replacePhones(
    scope: ApplyScope,
    customerId: string,
    side: 'p' | 'c',
    phones: readonly OnecContactPhone[],
  ): Promise<void> {
    const client = scope.client;
    const owned =
      side === 'c' ? `cc.onec_line_key LIKE 'c:%'` : `(cc.onec_line_key IS NULL OR cc.onec_line_key NOT LIKE 'c:%')`;
    const before = await client.query<{ phones_norm: string[] }>(
      `SELECT phones_norm FROM customers WHERE id = $1::uuid`,
      [customerId],
    );
    const oldPhones = new Set(before.rows[0]?.phones_norm ?? []);
    const keep: string[] = [];
    for (const [i, p] of phones.entries()) {
      const key = `${side}:${i + 1}`;
      const value = p.e164 ?? p.raw;
      const existing = p.e164
        ? (
            await client.query<{ id: string }>(
              `SELECT cc.id FROM customer_contacts cc
                WHERE cc.customer_id = $1::uuid AND cc.kind = 'phone' AND cc.deleted_at IS NULL AND cc.value_norm = $2`,
              [customerId, p.e164],
            )
          ).rows[0]
        : (
            await client.query<{ id: string }>(
              `SELECT cc.id FROM customer_contacts cc
                WHERE cc.customer_id = $1::uuid AND cc.kind = 'phone' AND cc.deleted_at IS NULL
                  AND cc.value_norm IS NULL AND cc.onec_line_key = $2`,
              [customerId, key],
            )
          ).rows[0];
      if (existing) {
        await client.query(
          `UPDATE customer_contacts SET onec_line_key = $2, value = $3, is_primary = $4, synced_at = $5,
                  updated_at = now()
            WHERE id = $1::uuid`,
          [existing.id, key, value, side === 'p' && i === 0, scope.syncedAt],
        );
        keep.push(existing.id);
      } else {
        const ins = await client.query<{ id: string }>(
          `INSERT INTO customer_contacts (customer_id, kind, label, value, value_norm, is_primary, onec_line_key, synced_at)
           VALUES ($1::uuid, 'phone', 'Телефон', $2, $3, $4, $5, $6) RETURNING id`,
          [customerId, value, p.e164, side === 'p' && i === 0, key, scope.syncedAt],
        );
        keep.push(ins.rows[0].id);
      }
    }
    await client.query(
      `UPDATE customer_contacts cc SET deleted_at = now(), updated_at = now()
        WHERE cc.customer_id = $1::uuid AND cc.kind = 'phone' AND cc.deleted_at IS NULL AND ${owned}
          AND NOT (cc.id = ANY($2::uuid[]))`,
      [customerId, keep],
    );
    const after = await client.query<{ phones: string[]; primary: string | null }>(
      `SELECT coalesce(array_agg(cc.value_norm ORDER BY cc.is_primary DESC, cc.onec_line_key, cc.created_at)
                FILTER (WHERE cc.value_norm IS NOT NULL), '{}') AS phones,
              (array_agg(cc.value_norm ORDER BY cc.is_primary DESC, cc.onec_line_key, cc.created_at)
                FILTER (WHERE cc.value_norm ~ '^\\+996[0-9]{9}$'))[1] AS primary
         FROM customer_contacts cc
        WHERE cc.customer_id = $1::uuid AND cc.kind = 'phone' AND cc.deleted_at IS NULL`,
      [customerId],
    );
    const phonesNorm = after.rows[0]?.phones ?? [];
    await client.query(
      `UPDATE customers SET phones_norm = $2::text[], primary_phone_e164 = $3, updated_at = now() WHERE id = $1::uuid`,
      [customerId, phonesNorm, after.rows[0]?.primary ?? null],
    );
    const removed = [...oldPhones].filter((p) => !phonesNorm.includes(p));
    if (removed.length > 0) {
      // AC-ONEC-012: исчезновение телефона привязанного клиента → привязка `conflict` (решает admin, SCR-45).
      await client.query(
        `UPDATE customer_links SET status = 'conflict', reason = 'phone_removed_in_onec', updated_at = now()
          WHERE customer_id = $1::uuid AND status IN ('proposed','confirmed') AND matched_phone_e164 = ANY($2::text[])`,
        [customerId, removed],
      );
    }
  }

  private async customerByRef(client: pg.PoolClient, onecRef: string): Promise<CustomerRef | null> {
    const r = await client.query<{ id: string; source: 'onec' | 'pos'; agreement: string | null }>(
      `SELECT id, source::text AS source, onec_agreement_ref::text AS agreement FROM customers WHERE onec_ref = $1::uuid`,
      [onecRef],
    );
    const x = r.rows[0];
    return x ? { id: x.id, source: x.source, onecAgreementRef: x.agreement } : null;
  }

  // -------------------------------------------------------------------------------------------- история продаж

  private async applyShipment(scope: ApplyScope, it: Item): Promise<void> {
    const c = entityCounts(scope, 'sales_history');
    c.fetched += 1;
    const client = scope.client;
    const onecRef = ref(it.ref);
    const dateRaw = str(it.date);
    const date = dateRaw && Number.isFinite(Date.parse(dateRaw)) ? dateRaw : null;
    if (!onecRef || !date) return this.error(scope, 'sales_history', 'VALIDATION', 'Реализация без ref/даты', onecRef);
    const existing = (
      await client.query<{ id: string; source_hash: string }>(
        `SELECT id, source_hash FROM shipments WHERE onec_ref = $1::uuid`,
        [onecRef],
      )
    ).rows[0];
    const from = salesHistoryFrom(this.options.salesHistoryMonths, this.now());
    if (!existing && date.slice(0, 10) < from) {
      c.skipped += 1; // глубже SALES_HISTORY_MONTHS (05 SYNC-008)
      return;
    }
    const hash = hashOf(it);
    if (existing && existing.source_hash === hash) {
      c.skipped += 1;
      return;
    }
    const customerRef = ref(it.customerRef);
    const customer = customerRef ? await this.customerByRef(client, customerRef) : null;
    if (!customer) {
      return this.error(
        scope,
        'sales_history',
        'NOT_FOUND_LOCAL',
        'Клиент реализации не загружен',
        onecRef,
        str(it.number),
      );
    }
    let orderId: string | null = null;
    const orderExternal = ref(it.orderExternalId);
    if (orderExternal) {
      orderId =
        (await client.query<{ id: string }>(`SELECT id FROM orders WHERE id = $1::uuid`, [orderExternal])).rows[0]
          ?.id ?? null;
    }
    const orderRef = ref(it.orderRef);
    if (!orderId && orderRef) {
      orderId =
        (await client.query<{ id: string }>(`SELECT id FROM orders WHERE onec_ref = $1::uuid`, [orderRef])).rows[0]
          ?.id ?? null;
    }
    const warehouseRef = ref(it.warehouseRef);
    const warehouseId = warehouseRef
      ? ((await client.query<{ id: string }>(`SELECT id FROM warehouses WHERE onec_ref = $1::uuid`, [warehouseRef]))
          .rows[0]?.id ?? null)
      : null;
    const lines = Array.isArray(it.lines) ? (it.lines as Item[]) : [];
    let lineSum = Money.ZERO;
    let discountSum = Money.ZERO;
    const prepared: {
      lineNo: number;
      productRef: string | null;
      variantRef: string | null;
      packagingRef: string | null;
      name: string | null;
      quantity: Quantity;
      price: Money;
      amount: Money;
      discount: Money;
      returned: Quantity;
    }[] = [];
    try {
      for (const l of lines) {
        const lineNo = typeof l.lineNumber === 'number' && Number.isInteger(l.lineNumber) ? l.lineNumber : null;
        const qtyRaw = str(l.quantity);
        if (lineNo === null || lineNo < 1 || !qtyRaw) throw new Error('строка реализации без номера/количества');
        const quantity = Quantity.of(qtyRaw);
        const price = str(l.price) ? Money.of(str(l.price)!) : Money.ZERO;
        const amount = str(l.amount) ? Money.of(str(l.amount)!) : price.times(quantity);
        const discount = str(l.discountAmount) ? Money.of(str(l.discountAmount)!) : Money.ZERO;
        const returned = str(l.returnedQuantity) ? Quantity.of(str(l.returnedQuantity)!) : Quantity.of('0');
        lineSum = lineSum.plus(amount);
        discountSum = discountSum.plus(discount);
        prepared.push({
          lineNo,
          productRef: ref(l.productRef),
          variantRef: ref(l.variantRef),
          packagingRef: ref(l.packagingRef),
          name: str(l.productName),
          quantity,
          price,
          amount,
          discount,
          returned,
        });
      }
    } catch (e) {
      return this.error(
        scope,
        'sales_history',
        'VALIDATION',
        `Реализация не записана: ${e instanceof Error ? e.message : String(e)}`.slice(0, 300),
        onecRef,
        str(it.number),
      );
    }
    const totalRaw = str(it.total);
    const total = totalRaw && MONEY_RE.test(totalRaw) ? Money.of(totalRaw) : lineSum;
    const discountRaw = str(it.discountTotal);
    const discountTotal = discountRaw && MONEY_RE.test(discountRaw) ? Money.of(discountRaw) : discountSum;
    const returnedRaw = str(it.returnedTotal);
    const returnedTotal = returnedRaw && MONEY_RE.test(returnedRaw) ? Money.of(returnedRaw) : Money.ZERO;
    const due = str(it.paymentDueDate);
    const shipment = await client.query<{ id: string }>(
      `INSERT INTO shipments (onec_ref, onec_code, onec_data_version, deletion_mark, synced_at, source_hash, onec_doc_type,
                              onec_date, posted, order_id, customer_id, warehouse_id, total, discount_total, currency,
                              payment_due_date, returned_total, comment)
       VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8::timestamptz, $9, $10::uuid, $11::uuid, $12::uuid, $13::numeric,
               $14::numeric, $15, $16::date, $17::numeric, $18)
       ON CONFLICT (onec_ref) DO UPDATE SET onec_code = EXCLUDED.onec_code,
              onec_data_version = EXCLUDED.onec_data_version, deletion_mark = EXCLUDED.deletion_mark,
              synced_at = EXCLUDED.synced_at, source_hash = EXCLUDED.source_hash, onec_date = EXCLUDED.onec_date,
              posted = EXCLUDED.posted, order_id = coalesce(EXCLUDED.order_id, shipments.order_id),
              customer_id = EXCLUDED.customer_id, warehouse_id = EXCLUDED.warehouse_id, total = EXCLUDED.total,
              discount_total = EXCLUDED.discount_total, currency = EXCLUDED.currency,
              payment_due_date = EXCLUDED.payment_due_date, returned_total = EXCLUDED.returned_total,
              comment = EXCLUDED.comment, updated_at = now()
       RETURNING id`,
      [
        onecRef,
        str(it.number),
        str(it.dataVersion),
        it.deletionMark === true,
        scope.syncedAt,
        hash,
        ONEC_SHIPMENT,
        date,
        it.posted === true,
        orderId,
        customer.id,
        warehouseId,
        total.toString(),
        discountTotal.toString(),
        str(it.currency) ?? 'KGS',
        due ? due.slice(0, 10) : null,
        returnedTotal.toString(),
        str(it.comment),
      ],
    );
    const shipmentId = shipment.rows[0].id;
    if (existing) c.updated += 1;
    else c.inserted += 1;
    const keepLines: number[] = [];
    for (const l of prepared) {
      const variant = await this.variantOf(client, l.productRef, l.variantRef);
      const packaging = l.packagingRef
        ? (
            await client.query<{ id: string; factor: string }>(
              `SELECT id, factor::text AS factor FROM packagings WHERE onec_ref = $1::uuid`,
              [l.packagingRef],
            )
          ).rows[0]
        : undefined;
      const base = packaging ? l.quantity.times(packaging.factor) : l.quantity;
      await client.query(
        `INSERT INTO shipment_items (shipment_id, onec_line_no, variant_id, product_name_snapshot, packaging_id, quantity,
                                     base_quantity, unit_price, line_total, discount_amount, returned_quantity, synced_at,
                                     source_hash)
         VALUES ($1::uuid, $2, $3::uuid, $4, $5::uuid, $6::numeric, $7::numeric, $8::numeric, $9::numeric, $10::numeric,
                 $11::numeric, $12, $13)
         ON CONFLICT (shipment_id, onec_line_no) DO UPDATE SET variant_id = EXCLUDED.variant_id,
                product_name_snapshot = EXCLUDED.product_name_snapshot, packaging_id = EXCLUDED.packaging_id,
                quantity = EXCLUDED.quantity, base_quantity = EXCLUDED.base_quantity, unit_price = EXCLUDED.unit_price,
                line_total = EXCLUDED.line_total, discount_amount = EXCLUDED.discount_amount,
                returned_quantity = EXCLUDED.returned_quantity, synced_at = EXCLUDED.synced_at,
                source_hash = EXCLUDED.source_hash, updated_at = now()`,
        [
          shipmentId,
          l.lineNo,
          variant?.id ?? null,
          (l.name ?? variant?.name ?? 'Товар 1С').slice(0, 500),
          packaging?.id ?? null,
          l.quantity.toString(),
          base.toString(),
          l.price.toString(),
          l.amount.toString(),
          l.discount.toString(),
          l.returned.toString(),
          scope.syncedAt,
          hash,
        ],
      );
      keepLines.push(l.lineNo);
    }
    // Строки, исчезнувшие из документа, удаляются, если на них не ссылаются заявки на возврат.
    await client.query(
      `DELETE FROM shipment_items si
        WHERE si.shipment_id = $1::uuid AND NOT (si.onec_line_no = ANY($2::int[]))
          AND NOT EXISTS (SELECT 1 FROM return_request_items ri WHERE ri.shipment_item_id = si.id)`,
      [shipmentId, keepLines],
    );
  }

  private async applyShipmentDeletion(scope: ApplyScope, it: Item): Promise<void> {
    const c = entityCounts(scope, 'sales_history');
    c.fetched += 1;
    const onecRef = ref(it.ref);
    if (!onecRef) return;
    const r = await scope.client.query(
      `UPDATE shipments SET deletion_mark = true, synced_at = $2, updated_at = now()
        WHERE onec_ref = $1::uuid AND NOT deletion_mark`,
      [onecRef, scope.syncedAt],
    );
    c.markedDeleted += r.rowCount ?? 0;
  }

  private async variantOf(
    client: pg.PoolClient,
    productRef: string | null,
    variantRef: string | null,
  ): Promise<{ id: string; name: string } | undefined> {
    if (variantRef) {
      const v = await client.query<{ id: string; name: string }>(
        `SELECT v.id, p.name FROM product_variants v JOIN products p ON p.id = v.product_id WHERE v.onec_ref = $1::uuid`,
        [variantRef],
      );
      if (v.rows[0]) return v.rows[0];
    }
    if (!productRef) return undefined;
    const d = await client.query<{ id: string; name: string }>(
      `SELECT v.id, p.name FROM product_variants v JOIN products p ON p.id = v.product_id
        WHERE p.onec_ref = $1::uuid ORDER BY v.is_default DESC, v.id LIMIT 1`,
      [productRef],
    );
    return d.rows[0];
  }

  private error(
    scope: ApplyScope,
    entity: SyncEntity,
    code: ItemError['errorCode'],
    message: string,
    onecRef: string | null,
    onecCode: string | null = null,
  ): void {
    scope.errors.push({
      entity,
      errorCode: code,
      message,
      severity: code === 'VALIDATION' ? 'error' : 'warning',
      onecRef,
      onecCode,
    });
    entityCounts(scope, entity).errors += 1;
  }
}
