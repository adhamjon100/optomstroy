import type pg from 'pg';
import { catalogProducts } from '../../src/integrations/onec/fake-onec.gateway.js';
import {
  CASHIER_SCENARIO_PHONES,
  CASHIER_SCENARIOS,
  type CashierScenario,
  FIXTURE_SHIPMENT_REF,
  SyntheticCashier,
  type SyntheticCashierOptions,
  type SyntheticPartner,
  type SyntheticReceivableDoc,
  type SyntheticShipment,
} from '../../src/integrations/onec/synthetic-cashier.js';
import {
  type PosActor,
  type PosFixtureOptions,
  PosTestApp,
  RETAIL_CUSTOMER_ID,
  type SeededOrder,
} from './pos-fixture.js';
import { ScriptedOnecGateway } from './scripted-onec.gateway.js';

/**
 * Тестовый стенд этапа G «Кассир» — **тестовые данные** (фейк 1С и синтетика, не реальная интеграция). Поверх
 * `PosTestApp` (pos-fixture: embedded PostgreSQL 17, миграции, синтетический каталог через конвейер 1С, seed
 * `0001_defaults.sql`, Nest-приложение с фундаментом D, каталогом E и модулями F):
 *
 * - `onec` — `ScriptedOnecGateway` в режиме кассира (`SyntheticCashier`): клиенты с телефонами, соглашения,
 *   взаиморасчёты (снимок на момент ответа), реализации, оплаты, возвраты и правила скидок в плане обмена
 *   `/changes`; `createCustomer` 201/200/409, `getCustomerReceivables` 200/404, `createReturnRequest`
 *   201/200/409/422, `getReturnRequestStatus` — по состоянию; сценарии ошибок — `script`/`always`;
 * - `seedCashierWorld()` — реплика 1С в БД **напрямую** (как её запишут обработчики синхронизации G): клиенты
 *   (`customers`, `customer_contacts`), снимки долга (`receivables`, `receivable_documents`) — свежие, устаревший,
 *   неполный, без снимка; POS-клиент, ещё не созданный в 1С; правила скидок (`discount_rules`); реализации в
 *   глубине `SALES_HISTORY_MONTHS` (`shipments`, `shipment_items`) по товарам каталога БД; пользователи всех ролей;
 *   клиенты-покупатели с привязкой `confirmed` и `proposed`; избранные клиенты кассира; заказы POS покупателя
 *   (отгруженный — для возвратов, заявка клиента `created_via=customer`).
 *
 * ```ts
 * const t = await new CashierTestApp().start({ env: { QR_PROVIDER: 'none' } });
 * const w = await t.seedCashierWorld();
 * await t.req('get', `/customers/${w.customers.overdue.id}`, w.actors.cashier).expect(200);
 * t.onec.always('getCustomerReceivables', { transport: true });   // 1С недоступна
 * await t.stop();
 * ```
 */
export type CashierCustomerKey = CashierScenario | 'noSnapshot' | 'posPending' | 'retail';

export interface CashierCustomer {
  readonly key: CashierCustomerKey;
  readonly id: string;
  /** `onec_ref` (= ссылка партнёра в фейке 1С); `null` — POS-клиент до подтверждения 1С. */
  readonly onecRef: string | null;
  readonly name: string;
  readonly phone: string | null;
}

export interface CashierShipmentRow {
  readonly id: string;
  readonly onecRef: string;
  readonly number: string;
  readonly customerId: string;
  readonly orderId: string | null;
  /** Строки: `shipment_items.id` по номеру строки 1С. */
  readonly itemIds: Readonly<Record<number, string>>;
}

export interface CashierWorld {
  readonly actors: Record<'seller' | 'cashier' | 'senior_seller' | 'admin' | 'owner' | 'customer', PosActor>;
  readonly customers: Readonly<Record<CashierCustomerKey, CashierCustomer>>;
  /** Все клиенты 1С синтетики: `onec_ref` → `customers.id`. */
  readonly customerIdByRef: ReadonlyMap<string, string>;
  /** Покупатель с привязкой `confirmed` к `customers.buyer` (режим клиента, RM-G-014). */
  readonly buyerConfirmed: PosActor;
  /** Покупатель с привязкой `proposed` к тому же клиенту (свой долг/история → 404). */
  readonly buyerProposed: PosActor;
  readonly orders: {
    /** Заказ покупателя `shipped`, связанный с последней реализацией (`shipments.order_id`) — для возвратов. */
    readonly buyerShipped: SeededOrder;
    /** Заявка-заказ клиента (`created_via=customer`, `awaiting_payment`). */
    readonly buyerRequest: SeededOrder;
  };
  readonly shipments: {
    /** Последняя реализация покупателя (связана с `orders.buyerShipped`). */
    readonly buyerLatest: CashierShipmentRow;
    /** Реализация фикстуры `returns-create.request` (`debtWithinLimit`). */
    readonly fixture: CashierShipmentRow;
    /** Все реализации в БД: `onec_ref` → строка. */
    readonly byRef: ReadonlyMap<string, CashierShipmentRow>;
  };
  /** `discount_rules.id` по `onec_ref` правила. */
  readonly discountRuleIds: ReadonlyMap<string, string>;
  /** Граница истории продаж (`SALES_HISTORY_MONTHS`), `YYYY-MM-DD`. */
  readonly historyFrom: string;
}

export interface CashierWorldOptions {
  /** Возраст свежих снимков долга, мин (по умолчанию 5). */
  readonly freshAgeMinutes?: number;
  /** Возраст устаревшего снимка (`stale`), мин (по умолчанию 180 при `RECEIVABLES_MAX_AGE_MIN` 60). */
  readonly staleAgeMinutes?: number;
  /** Загрузить и реализации старше `SALES_HISTORY_MONTHS` (по умолчанию нет — как синхронизация). */
  readonly includeOlderShipments?: boolean;
}

/** Параметры стенда — как у `PosTestApp` (синтетика кассира — в конструкторе `CashierTestApp`). */
export type CashierFixtureOptions = PosFixtureOptions;

const DOC_KIND: Readonly<Record<string, 'invoice' | 'payment' | 'return' | 'discount' | 'adjustment'>> = {
  Document_РеализацияТоваровУслуг: 'invoice',
  Document_ЗаказКлиента: 'invoice',
  Document_ПриходныйКассовыйОрдер: 'payment',
  Document_ПоступлениеБезналичныхДенежныхСредств: 'payment',
  Document_ВозвратТоваровОтКлиента: 'return',
};

/**
 * Вид строки детализации долга из типа документа 1С (временное правило фикстуры, GQ-FND-06: в контракте 1С
 * `kind/status` нет — маппинг владеет G-be-credit).
 */
export function receivableDocKind(documentType: string): 'invoice' | 'payment' | 'return' | 'discount' | 'adjustment' {
  return DOC_KIND[documentType] ?? (documentType.includes('Скидк') ? 'discount' : 'adjustment');
}

/** Статус строки детализации: `due` — срок наступил и остаток > 0; иначе `posted` (GQ-FND-06). */
export function receivableDocStatus(d: SyntheticReceivableDoc, today: string): 'posted' | 'not_posted' | 'due' {
  const positive = /^\d/.test(d.remaining) && !/^0\.00$/.test(d.remaining);
  return d.dueDate !== null && d.dueDate <= today && positive ? 'due' : 'posted';
}

export class CashierTestApp extends PosTestApp {
  /** Синтетика кассира фейка 1С (общая с `onec`). */
  readonly cashier: SyntheticCashier;
  declare readonly onec: ScriptedOnecGateway;
  world: CashierWorld | undefined;

  constructor(cashierOptions: SyntheticCashierOptions = {}) {
    super();
    this.cashier = new SyntheticCashier(cashierOptions);
    this.onec = new ScriptedOnecGateway({ cashier: this.cashier });
  }

  /** Стенд + (по умолчанию) товары синтетического каталога БД в строках реализаций фейка 1С. */
  override async start(opts: CashierFixtureOptions = {}): Promise<this> {
    await super.start(opts);
    this.cashier.bindProducts(catalogProducts(this.fx.catalog));
    return this;
  }

  /** Реплика 1С кассира в БД, пользователи, привязки, избранное, заказы (см. описание класса). */
  async seedCashierWorld(o: CashierWorldOptions = {}): Promise<CashierWorld> {
    const fresh = o.freshAgeMinutes ?? 5;
    const staleAge = o.staleAgeMinutes ?? 180;
    const priceListId = await this.defaultPriceListId();
    const warehouseId = await this.defaultWarehouseId();
    const actors = await this.actors();
    const historyFrom = this.cashier.historyFrom();
    const today = this.cashier.asOf;

    const customerIdByRef = new Map<string, string>();
    const shipmentsByRef = new Map<string, CashierShipmentRow>();
    const discountRuleIds = new Map<string, string>();
    let noSnapshot: CashierCustomer | undefined;

    const c = await this.pool.connect();
    try {
      await c.query('BEGIN');
      // Клиенты 1С и контакты.
      for (const p of this.cashier.allPartners()) {
        customerIdByRef.set(p.ref, await insertPartner(c, p, priceListId));
      }
      // Снимки долга: устаревший — `stale`; без снимка — первый «обычный» клиент с отсрочкой и лимитом (в 1С
      // снимок есть — обновление возможно).
      const generic = this.cashier
        .allPartners()
        .find(
          (p) =>
            p.scenario === null &&
            p.externalId === null &&
            !p.deletionMark &&
            p.creditAllowed &&
            p.creditLimit !== null,
        );
      for (const p of this.cashier.allPartners()) {
        const r = this.cashier.receivablesOf(p.ref);
        if (!r || p.ref === generic?.ref) continue;
        const age = p.scenario === 'stale' ? staleAge : fresh;
        await insertReceivables(c, customerIdByRef.get(p.ref)!, r, age, today);
      }
      if (generic) {
        noSnapshot = {
          key: 'noSnapshot',
          id: customerIdByRef.get(generic.ref)!,
          onecRef: generic.ref,
          name: generic.name,
          phone: generic.phones[0] ?? null,
        };
      }
      // Правила скидок 1С.
      for (const d of this.cashier.discountRules()) {
        const customerIds = (d.conditions.partnerRefs ?? []).map((r) => customerIdByRef.get(r)).filter(Boolean);
        const conditions = {
          ...(d.conditions.minTotal ? { minTotal: d.conditions.minTotal } : {}),
          ...(customerIds.length > 0 ? { customerIds } : {}),
        };
        const r = await c.query<{ id: string }>(
          `INSERT INTO discount_rules (onec_ref, onec_code, onec_data_version, deletion_mark, synced_at, source_hash,
                                       source, name, kind, value, conditions, applies_automatically, is_active,
                                       valid_from, valid_to, description_ru)
           VALUES ($1::uuid, $2, 'AAAAAQ==', $3, now(), 'cashier-fixture', 'onec', $4, $5::discount_kind,
                   $6::numeric, $7::jsonb, $8, $9, $10::date, $11::date, $4)
           RETURNING id`,
          [
            d.ref,
            d.code,
            d.deletionMark,
            d.description,
            d.kind,
            d.value,
            JSON.stringify(conditions),
            d.appliesAutomatically,
            d.isActive,
            d.validFrom,
            d.validTo,
          ],
        );
        discountRuleIds.set(d.ref, r.rows[0].id);
      }
      // Реализации (история продаж) в глубине SALES_HISTORY_MONTHS.
      for (const p of this.cashier.allPartners()) {
        for (const s of this.cashier.shipmentsOf(p.ref)) {
          if (!o.includeOlderShipments && s.date < historyFrom) continue;
          shipmentsByRef.set(s.ref, await insertShipment(c, s, customerIdByRef.get(p.ref)!, warehouseId));
        }
      }
      await c.query('COMMIT');
    } catch (e) {
      await c.query('ROLLBACK').catch(() => undefined);
      throw e;
    } finally {
      c.release();
    }

    // POS-клиент, ещё не созданный в 1С (`source=pos`, `onec_status=pending`, снимка нет — `not_in_onec`).
    const posPhone = '+996555000199';
    const pos = await this.q<{ id: string }>(
      `INSERT INTO customers (source, name, customer_type, primary_phone_e164, phones_norm, onec_status,
                              created_by_user_id, credit_allowed)
       VALUES ('pos', 'Новый Клиент Из POS', 'individual', $1, ARRAY[$1::text], 'pending', $2::uuid, false)
       RETURNING id`,
      [posPhone, actors.cashier.userId],
    );
    await this.q(
      `INSERT INTO customer_contacts (customer_id, kind, label, value, value_norm, is_primary)
       VALUES ($1::uuid, 'phone', 'Телефон', $2, $2, true)`,
      [pos[0].id, posPhone],
    );

    const scen = (k: CashierScenario): CashierCustomer => {
      const p = this.cashier.partner(CASHIER_SCENARIOS[k])!;
      return {
        key: k,
        id: customerIdByRef.get(p.ref)!,
        onecRef: p.ref,
        name: p.name,
        phone: CASHIER_SCENARIO_PHONES[k],
      };
    };
    const customers = {
      ...(Object.fromEntries((Object.keys(CASHIER_SCENARIOS) as CashierScenario[]).map((k) => [k, scen(k)])) as Record<
        CashierScenario,
        CashierCustomer
      >),
      noSnapshot: noSnapshot!,
      posPending: { key: 'posPending', id: pos[0].id, onecRef: null, name: 'Новый Клиент Из POS', phone: posPhone },
      retail: { key: 'retail', id: RETAIL_CUSTOMER_ID, onecRef: null, name: 'Розничный покупатель', phone: null },
    } satisfies Record<CashierCustomerKey, CashierCustomer>;

    // Клиенты-покупатели: confirmed и proposed к `buyer`.
    const buyerConfirmed = await this.actor({ role: 'customer' });
    const buyerProposed = await this.actor({ role: 'customer' });
    await this.linkCustomer(buyerConfirmed.userId, customers.buyer.id, 'confirmed');
    await this.linkCustomer(buyerProposed.userId, customers.buyer.id, 'proposed');

    // Избранные клиенты кассира.
    for (const k of ['buyer', 'debtWithinLimit'] as const) {
      await this.q(`INSERT INTO favorites_customers (user_id, customer_id) VALUES ($1::uuid, $2::uuid)`, [
        actors.cashier.userId,
        customers[k].id,
      ]);
    }

    // Заказы POS покупателя: отгруженный (связан с последней реализацией) и заявка клиента.
    const buyerShipped = await this.seedOrder({
      createdBy: actors.cashier,
      customerId: customers.buyer.id,
      method: 'cash',
      status: 'awaiting_shipment',
    });
    await this.q(`UPDATE orders SET status = 'shipped', shipped_at = now() WHERE id = $1::uuid`, [
      buyerShipped.orderId,
    ]);
    const latest = this.cashier.shipmentsOf(CASHIER_SCENARIOS.buyer)[0];
    this.cashier.linkShipmentToOrder(latest.ref, buyerShipped.orderId);
    await this.q(`UPDATE shipments SET order_id = $2::uuid WHERE onec_ref = $1::uuid`, [
      latest.ref,
      buyerShipped.orderId,
    ]);
    const buyerLatest = { ...shipmentsByRef.get(latest.ref)!, orderId: buyerShipped.orderId };
    shipmentsByRef.set(latest.ref, buyerLatest);
    const buyerRequest = await this.seedOrder({
      createdBy: buyerConfirmed,
      customerId: customers.buyer.id,
      method: 'cash',
      status: 'awaiting_payment',
      createdVia: 'customer',
    });

    this.world = {
      actors,
      customers,
      customerIdByRef,
      buyerConfirmed,
      buyerProposed,
      orders: { buyerShipped, buyerRequest },
      shipments: { buyerLatest, fixture: shipmentsByRef.get(FIXTURE_SHIPMENT_REF)!, byRef: shipmentsByRef },
      discountRuleIds,
      historyFrom,
    };
    return this.world;
  }

  /** Состояние снимка долга в БД (для проверок «обращений к 1С не было / снимок обновлён»). */
  async receivablesRow(customerId: string) {
    return (
      await this.q<{ balance: string; overdue_amount: string | null; onec_snapshot_at: Date }>(
        `SELECT balance::text AS balance, overdue_amount::text AS overdue_amount, onec_snapshot_at
           FROM receivables WHERE customer_id = $1::uuid`,
        [customerId],
      )
    )[0];
  }

  /** Сделать снимок клиента устаревшим (`onec_snapshot_at = now − minutes`). */
  async ageReceivables(customerId: string, minutes: number): Promise<void> {
    await this.q(
      `UPDATE receivables SET onec_snapshot_at = now() - make_interval(mins => $2) WHERE customer_id = $1::uuid`,
      [customerId, minutes],
    );
  }
}

async function insertPartner(c: pg.PoolClient, p: SyntheticPartner, priceListId: string): Promise<string> {
  const phone = p.phones.find((x) => /^\+996\d{9}$/.test(x)) ?? null;
  const r = await c.query<{ id: string }>(
    `INSERT INTO customers (onec_ref, onec_code, onec_data_version, deletion_mark, synced_at, source_hash, source,
                            onec_counterparty_ref, onec_agreement_ref, name, customer_type, inn, primary_phone_e164,
                            phones_norm, default_price_list_id, discount_percent, credit_allowed, credit_limit,
                            credit_days, onec_status)
     VALUES ($1::uuid, $2, 'AAAAAQ==', $3, now(), 'cashier-fixture', 'onec', $4::uuid, $5::uuid, $6,
             $7::customer_type, $8, $9, $10::text[], $11::uuid, $12::numeric, $13, $14::numeric, $15, 'n_a')
     RETURNING id`,
    [
      p.ref,
      p.code,
      p.deletionMark,
      p.counterpartyRef,
      p.agreementRef,
      p.name,
      p.kind,
      p.taxId,
      phone,
      p.phones,
      priceListId,
      p.discountPercent,
      p.creditAllowed,
      p.creditLimit,
      p.creditDays,
    ],
  );
  const id = r.rows[0].id;
  for (const [i, ph] of p.phones.entries()) {
    await c.query(
      `INSERT INTO customer_contacts (customer_id, kind, label, value, value_norm, is_primary, onec_line_key, synced_at,
                                      source_hash)
       VALUES ($1::uuid, 'phone', 'Телефон', $2, $2, $3, $4, now(), 'cashier-fixture')`,
      [id, ph, i === 0, `phone:${i + 1}`],
    );
  }
  return id;
}

async function insertReceivables(
  c: pg.PoolClient,
  customerId: string,
  r: NonNullable<ReturnType<SyntheticCashier['receivablesOf']>>,
  ageMinutes: number,
  today: string,
): Promise<void> {
  const oldest = r.documents
    .filter((d) => d.dueDate !== null && /^\d/.test(d.remaining) && d.remaining !== '0.00')
    .map((d) => d.dueDate!)
    .sort()[0];
  await c.query(
    `INSERT INTO receivables (customer_id, balance, overdue_amount, overdue_days, oldest_due_date, onec_snapshot_at,
                              synced_at, source_hash)
     VALUES ($1::uuid, $2::numeric, $3::numeric, $4, $5::date, now() - make_interval(mins => $6), now(),
             'cashier-fixture')`,
    [customerId, r.balance, r.overdueAmount, r.overdueDays, oldest ?? null, ageMinutes],
  );
  for (const d of r.documents) {
    await c.query(
      `INSERT INTO receivable_documents (customer_id, onec_ref, doc_type, kind, status, doc_number, doc_date, amount,
                                         paid, remaining, due_date, overdue_days, onec_snapshot_at, synced_at,
                                         source_hash)
       VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6, $7::date, $8::numeric, $9::numeric, $10::numeric, $11::date, $12,
               now() - make_interval(mins => $13), now(), 'cashier-fixture')`,
      [
        customerId,
        d.documentRef,
        d.documentType,
        receivableDocKind(d.documentType),
        receivableDocStatus(d, today),
        d.number,
        d.date,
        d.amount,
        d.paid,
        d.remaining,
        d.dueDate,
        d.overdueDays,
        ageMinutes,
      ],
    );
  }
}

async function insertShipment(
  c: pg.PoolClient,
  s: SyntheticShipment,
  customerId: string,
  warehouseId: string,
): Promise<CashierShipmentRow> {
  const r = await c.query<{ id: string }>(
    `INSERT INTO shipments (onec_ref, onec_code, onec_data_version, synced_at, source_hash, onec_doc_type, onec_date,
                            posted, customer_id, warehouse_id, total, discount_total, payment_due_date, returned_total)
     VALUES ($1::uuid, $2, 'AAAAAQ==', now(), 'cashier-fixture', 'Document_РеализацияТоваровУслуг',
             $3::timestamptz, true, $4::uuid, $5::uuid, $6::numeric, $7::numeric, $8::date, $9::numeric)
     RETURNING id`,
    [
      s.ref,
      s.number,
      `${s.date}T11:00:00+06:00`,
      customerId,
      warehouseId,
      s.total,
      s.discountTotal,
      s.paymentDueDate,
      s.returnedTotal,
    ],
  );
  const id = r.rows[0].id;
  const itemIds: Record<number, string> = {};
  for (const l of s.lines) {
    const v = await c.query<{ id: string }>(
      `SELECT v.id FROM product_variants v JOIN products p ON p.id = v.product_id
        WHERE p.onec_ref = $1::uuid
          AND CASE WHEN $2::uuid IS NULL THEN v.is_default ELSE v.onec_ref = $2::uuid END
        LIMIT 1`,
      [l.productRef, l.variantRef],
    );
    const it = await c.query<{ id: string }>(
      `INSERT INTO shipment_items (shipment_id, onec_line_no, variant_id, product_name_snapshot, quantity, base_quantity,
                                   unit_price, line_total, discount_amount, returned_quantity, synced_at, source_hash)
       VALUES ($1::uuid, $2, $3::uuid, $4, $5::numeric, $5::numeric, $6::numeric, $7::numeric, $8::numeric, $9::numeric,
               now(), 'cashier-fixture')
       RETURNING id`,
      [
        id,
        l.lineNumber,
        v.rows[0]?.id ?? null,
        l.productName,
        l.quantity,
        l.price,
        l.amount,
        l.discountAmount,
        l.returnedQuantity,
      ],
    );
    itemIds[l.lineNumber] = it.rows[0].id;
  }
  return { id, onecRef: s.ref, number: s.number, customerId, orderId: null, itemIds };
}
