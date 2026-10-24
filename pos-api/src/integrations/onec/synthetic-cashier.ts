import { Money } from '../../common/money/money.js';
import type { OnecJson, OnecJsonObject, OnecMoney } from './onec-gateway.js';
import { prng } from './synthetic-catalog.js';

/**
 * Синтетика кассира для `FakeOnecGateway` (этап G, **тестовые данные**, не реальная интеграция): клиенты 1С с
 * телефонами (`Catalog_Партнеры`, `Catalog_Контрагенты`, `Catalog_СоглашенияСКлиентами`), взаиморасчёты
 * (`GET /pos/v1/customers/{ref}/receivables` — сальдо, просрочка, лимит, документы), реализации
 * (`Document_РеализацияТоваровУслуг` — история продаж, глубина `SALES_HISTORY_MONTHS`), документы оплат и возвратов,
 * правила скидок (`Catalog_СкидкиНаценки`), создание клиента (201/200/409) и заявки на возврат (201/200/409/422).
 *
 * Детерминированность: состав и суммы зависят только от `seed`, `asOf` (дата Бишкека, по умолчанию — сегодня) и
 * списка товаров; `snapshotAt` снимка долга — момент ответа (`now()`), чтобы свежесть считалась от реального
 * времени теста (`RECEIVABLES_MAX_AGE_MIN`).
 *
 * Поля, которых нет в контракте `contracts/onec/onec-http-service.v1.yaml` 1.x (ONEC-058: неизвестные поля
 * игнорируются), помечены «предложение» — см. docs/stages/G_spec_questions.md (GQ-FND-03…05): `kind` контрагента,
 * `discountPercent` соглашения, параметры правила скидки (`kind`, `value`, `isActive`, `appliesAutomatically`,
 * `validFrom`, `validTo`, `conditions`). С `discountDetails: false` правила скидок — строго по контракту.
 */

/** Товар для строк реализаций (ссылки 1С каталога, цена за базовую единицу). */
export interface SyntheticProductRef {
  readonly productRef: string;
  readonly variantRef: string | null;
  readonly name: string;
  readonly price: OnecMoney;
}

/** Товар фикстуры `catalog-card.200` / `returns-create.request` — по умолчанию, если каталог не задан. */
export const FIXTURE_PRODUCT: SyntheticProductRef = {
  productRef: 'a1b2c3d4-0000-4000-8000-000000000001',
  variantRef: 'a1b2c3d4-0000-4000-8000-000000000101',
  name: 'Смеситель для кухни KX-1245, хром',
  price: '2350.00',
};

export interface SyntheticCashierOptions {
  readonly seed?: number;
  /** Число «обычных» клиентов сверх сценарных (по умолчанию 20). */
  readonly extraCustomers?: number;
  /** Дата отсчёта истории и сроков (`YYYY-MM-DD`, Бишкек); по умолчанию — сегодня. */
  readonly asOf?: string;
  /** Часы ответа 1С (`snapshotAt`); по умолчанию `new Date()`. */
  readonly now?: () => Date;
  /** Глубина истории продаж в POS (`SALES_HISTORY_MONTHS`); реализации генерируются на 3 мес. глубже. */
  readonly salesHistoryMonths?: number;
  readonly products?: readonly SyntheticProductRef[];
  /** Склад реализаций (`warehouseRef`); `null` — не указан. */
  readonly warehouseRef?: string | null;
  /** Вид цены соглашений; `null` — не указан. */
  readonly priceListRef?: string | null;
  /** Поля правил скидок сверх контракта (предложение GQ-FND-05); по умолчанию `true`. */
  readonly discountDetails?: boolean;
}

/** Сценарные клиенты (ссылки фиксированы, не зависят от `seed`). */
export const CASHIER_SCENARIOS = {
  /** Долг в лимите, без просрочки — клиент фикстур `receivables.200`, `customers-search.200`. */
  debtWithinLimit: 'c3d4e5f6-0000-4000-8000-000000000001',
  /** Просрочка — клиент фикстуры `receivables.overdue.200` → `CREDIT_BLOCKED` (`overdue`). */
  overdue: 'c3d4e5f6-0000-4000-8000-000000000002',
  /** Долга нет, отсрочка разрешена. */
  noDebt: 'c3d4e5f6-0000-4000-8000-000000000003',
  /** Почти исчерпан лимит (49 000 из 50 000) → `CREDIT_LIMIT_EXCEEDED` при заказе > 1 000. */
  overLimit: 'c3d4e5f6-0000-4000-8000-000000000004',
  /** Лимит в 1С не задан (`creditLimit: null`, DEBT-012). */
  noLimit: 'c3d4e5f6-0000-4000-8000-000000000005',
  /** Соглашение без отсрочки (`creditAllowed: false`) → `credit_not_allowed`. */
  creditNotAllowed: 'c3d4e5f6-0000-4000-8000-000000000006',
  /** Неполный снимок: просрочка неизвестна (`overdueAmount: null`). */
  incomplete: 'c3d4e5f6-0000-4000-8000-000000000007',
  /** В 1С свежо и чисто; в БД теста снимок устаревший (`cashier-fixture`). */
  stale: 'c3d4e5f6-0000-4000-8000-000000000008',
  /** Клиент-покупатель (режим клиента): долг, 14 месяцев реализаций, возврат. */
  buyer: 'c3d4e5f6-0000-4000-8000-000000000009',
  /** Аванс (отрицательное сальдо). */
  advance: 'c3d4e5f6-0000-4000-8000-00000000000a',
} as const;
export type CashierScenario = keyof typeof CASHIER_SCENARIOS;

/** Телефоны сценарных клиентов (E.164). `debtWithinLimit` — телефон фикстур (`+996700123456`). */
export const CASHIER_SCENARIO_PHONES: Readonly<Record<CashierScenario, string>> = {
  debtWithinLimit: '+996700123456',
  overdue: '+996700223344',
  noDebt: '+996555000103',
  overLimit: '+996555000104',
  noLimit: '+996555000105',
  creditNotAllowed: '+996555000106',
  incomplete: '+996555000107',
  stale: '+996555000108',
  buyer: '+996555000109',
  advance: '+996555000110',
};

/** Реализация фикстуры `returns-create.request` (клиент `debtWithinLimit`). */
export const FIXTURE_SHIPMENT_REF = 'f1e2d3c4-0000-4000-8000-000000000020';

export interface SyntheticPartner {
  readonly ref: string;
  readonly counterpartyRef: string;
  readonly agreementRef: string;
  readonly code: string;
  readonly name: string;
  readonly fullName: string | null;
  readonly kind: 'individual' | 'entrepreneur' | 'legal';
  readonly taxId: string | null;
  readonly phones: readonly string[];
  readonly creditAllowed: boolean;
  readonly creditLimit: OnecMoney | null;
  readonly creditDays: number | null;
  readonly discountPercent: string | null;
  readonly deletionMark: boolean;
  /** `externalId` карточки, созданной из POS (`POST /pos/v1/customers`). */
  readonly externalId: string | null;
  readonly scenario: CashierScenario | null;
}

export interface SyntheticReceivableDoc {
  readonly documentRef: string;
  readonly documentType: string;
  readonly number: string;
  /** `YYYY-MM-DD`. */
  readonly date: string;
  readonly amount: OnecMoney;
  readonly paid: OnecMoney;
  readonly remaining: OnecMoney;
  readonly dueDate: string | null;
  readonly overdueDays: number;
}

export interface SyntheticReceivables {
  readonly balance: OnecMoney;
  /** `null` — просрочка неизвестна. */
  readonly overdueAmount: OnecMoney | null;
  readonly overdueDays: number | null;
  readonly documents: readonly SyntheticReceivableDoc[];
}

export interface SyntheticShipmentLine {
  readonly lineNumber: number;
  readonly productRef: string;
  readonly variantRef: string | null;
  readonly productName: string;
  /** Количество `^\d+\.\d{3}$`. */
  readonly quantity: string;
  readonly price: OnecMoney;
  readonly amount: OnecMoney;
  readonly discountAmount: OnecMoney;
  /** Уже возвращено (ONEC-048). */
  returnedQuantity: string;
}

export interface SyntheticShipment {
  readonly ref: string;
  readonly number: string;
  /** `YYYY-MM-DD` (время документа — 11:00 Бишкека). */
  readonly date: string;
  readonly customerRef: string;
  /** externalId заказа POS-основания (`orders.id`), если реализация по заказу из POS. */
  orderExternalId: string | null;
  readonly total: OnecMoney;
  readonly discountTotal: OnecMoney;
  readonly paymentDueDate: string | null;
  readonly lines: SyntheticShipmentLine[];
  returnedTotal: OnecMoney;
  dataVersion: number;
}

export interface SyntheticReturnRequest {
  readonly externalId: string;
  readonly ref: string;
  readonly number: string;
  readonly shipmentRef: string;
  readonly customerRef: string;
  readonly lines: readonly { readonly shipmentLineNumber: number; readonly quantity: string }[];
  status: 'submitted' | 'accepted' | 'rejected' | 'completed';
}

export interface SyntheticDiscountRule {
  readonly ref: string;
  readonly code: string;
  readonly description: string;
  readonly kind: 'percent' | 'fixed_amount' | 'price_list';
  readonly value: string;
  readonly isActive: boolean;
  readonly appliesAutomatically: boolean;
  readonly validFrom: string | null;
  readonly validTo: string | null;
  readonly conditions: { readonly minTotal?: OnecMoney; readonly partnerRefs?: readonly string[] };
  readonly deletionMark: boolean;
}

/** Ошибка бизнес-проверки фейка → `OnecError` с этим статусом/кодом (оборачивает `FakeOnecGateway`). */
export class SyntheticOnecRejection extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly details?: OnecJson,
  ) {
    super(message);
  }
}

const NAMES_INDIVIDUAL = [
  'Асанов Бакыт',
  'Асанова Айгуль',
  'Токтогулов Эрлан',
  'Жумабаева Нургуль',
  'Исаков Талант',
  'Мамытова Айпери',
  'Садыков Нурлан',
  'Орозбекова Жылдыз',
  'Кадыров Азамат',
  'Бекова Чолпон',
];
const NAMES_LEGAL = [
  'ОсОО «СантехСтрой»',
  'ОсОО «Ак-Таш Курулуш»',
  'ОсОО «Бишкек Ремонт»',
  'ИП Алыбаев',
  'ОсОО «Водопровод-Сервис»',
  'ИП Нуралиева',
];

const SCENARIO_NAMES: Readonly<Record<CashierScenario, string>> = {
  debtWithinLimit: 'Асанов Бакыт',
  overdue: 'Асанова Айгуль',
  noDebt: 'ОсОО «Чистый Дом»',
  overLimit: 'ОсОО «Лимит-Строй»',
  noLimit: 'ИП Без Лимита',
  creditNotAllowed: 'Наличный Покупатель Ыйман',
  incomplete: 'ОсОО «Неполные Данные»',
  stale: 'ОсОО «Устаревший Снимок»',
  buyer: 'Покупатель Айбек Тестов',
  advance: 'ОсОО «Аванс Плюс»',
};

const DOC_SHIPMENT = 'Document_РеализацияТоваровУслуг';
const DOC_CASH_IN = 'Document_ПриходныйКассовыйОрдер';
const DOC_RETURN = 'Document_ВозвратТоваровОтКлиента';
const DOC_ADJUSTMENT = 'Document_КорректировкаРеализации';

const DAY_MS = 86_400_000;
const BISHKEK_OFFSET_MS = 6 * 3_600_000;

function hex(n: number, width: number): string {
  return n.toString(16).padStart(width, '0').slice(-width);
}

function dataVersion(counter: number): string {
  const b = Buffer.alloc(8);
  b.writeUInt32BE(counter >>> 0, 4);
  return b.toString('base64');
}

/** Сегодня по Бишкеку `YYYY-MM-DD`. */
export function bishkekToday(now: Date = new Date()): string {
  return new Date(now.getTime() + BISHKEK_OFFSET_MS).toISOString().slice(0, 10);
}

/** Момент → `YYYY-MM-DDTHH:MM:SS+06:00` (ONEC-058). */
export function bishkekIso(d: Date): string {
  return `${new Date(d.getTime() + BISHKEK_OFFSET_MS).toISOString().slice(0, 19)}+06:00`;
}

function addDays(date: string, days: number): string {
  return new Date(Date.parse(`${date}T00:00:00Z`) + days * DAY_MS).toISOString().slice(0, 10);
}

/** Тот же день `months` месяцев назад (день > длины месяца → последний день). */
function monthsBack(date: string, months: number): string {
  const [y, m, d] = date.split('-').map((x) => Number(x)) as [number, number, number];
  const total = y * 12 + (m - 1) - months;
  const yy = Math.floor(total / 12);
  const mm = total % 12;
  const last = new Date(Date.UTC(yy, mm + 1, 0)).getUTCDate();
  return new Date(Date.UTC(yy, mm, Math.min(d, last))).toISOString().slice(0, 10);
}

function som(whole: number): Money {
  return Money.fromTyiyn(BigInt(whole) * 100n);
}

function pieces(n: number): string {
  return `${n}.000`;
}

function piecesOf(v: string): number {
  const m = /^(\d+)\.(\d{3})$/.exec(v);
  if (!m || m[2] !== '000') throw new SyntheticOnecRejection(400, 'POS_E_BAD_REQUEST', `Количество ${v}: шт.`);
  return Number(m[1]);
}

/**
 * Набор данных кассира. Изменения после создания (`setReceivables`, `createCustomer`, `setReturnStatus`, …)
 * сообщают затронутые ключи `type:ref` подписчику (`FakeOnecGateway` регистрирует их в плане обмена).
 */
export class SyntheticCashier {
  readonly seed: number;
  readonly asOf: string;
  readonly salesHistoryMonths: number;
  readonly now: () => Date;
  readonly discountDetails: boolean;
  readonly warehouseRef: string | null;
  readonly priceListRef: string | null;
  private products: readonly SyntheticProductRef[];
  private readonly partners = new Map<string, SyntheticPartner>();
  private readonly receivables = new Map<string, SyntheticReceivables | null>();
  private readonly shipments = new Map<string, SyntheticShipment>();
  private readonly payments: OnecJsonObject[] = [];
  private readonly returnDocs = new Map<string, OnecJsonObject>();
  private readonly returnRequests = new Map<string, SyntheticReturnRequest>();
  private readonly discounts = new Map<string, SyntheticDiscountRule>();
  private readonly listeners: ((keys: readonly string[]) => void)[] = [];
  private version = 1;
  private createdSeq = 0;
  private returnSeq = 16;
  private readonly extraCount: number;

  constructor(options: SyntheticCashierOptions = {}) {
    this.seed = options.seed ?? 7;
    this.now = options.now ?? (() => new Date());
    this.asOf = options.asOf ?? bishkekToday(this.now());
    this.salesHistoryMonths = options.salesHistoryMonths ?? 12;
    this.discountDetails = options.discountDetails ?? true;
    this.warehouseRef = options.warehouseRef ?? null;
    this.priceListRef = options.priceListRef ?? null;
    this.products = options.products && options.products.length > 0 ? options.products : [FIXTURE_PRODUCT];
    this.extraCount = options.extraCustomers ?? 20;
    this.generate();
  }

  // ------------------------------------------------------------------------------------------------ чтение

  /** Ссылка 1С сценарного клиента. */
  scenarioRef(s: CashierScenario): string {
    return CASHIER_SCENARIOS[s];
  }

  partner(ref: string): SyntheticPartner | undefined {
    return this.partners.get(ref);
  }

  allPartners(): SyntheticPartner[] {
    return [...this.partners.values()];
  }

  /** Снимок долга как хранит фейк (`undefined` — клиента нет; `null` — 1С не отдаёт снимок: 404). */
  receivablesOf(ref: string): SyntheticReceivables | null | undefined {
    return this.receivables.get(ref);
  }

  shipmentsOf(customerRef: string): SyntheticShipment[] {
    return [...this.shipments.values()]
      .filter((s) => s.customerRef === customerRef)
      .sort((a, b) => (a.date < b.date ? 1 : a.date > b.date ? -1 : a.ref.localeCompare(b.ref)));
  }

  shipment(ref: string): SyntheticShipment | undefined {
    return this.shipments.get(ref);
  }

  discountRules(): SyntheticDiscountRule[] {
    return [...this.discounts.values()];
  }

  returnRequest(externalId: string): SyntheticReturnRequest | undefined {
    return this.returnRequests.get(externalId);
  }

  /** Граница истории продаж в POS: `asOf − SALES_HISTORY_MONTHS` (`historyFrom`). */
  historyFrom(): string {
    return monthsBack(this.asOf, this.salesHistoryMonths);
  }

  // ------------------------------------------------------------------------------------- элементы /changes

  /** Все элементы плана обмена кассира (`/changes`) в порядке зависимостей. */
  allItems(): OnecJsonObject[] {
    const out: OnecJsonObject[] = [];
    for (const p of this.partners.values()) out.push(...this.partnerItems(p));
    for (const d of this.discounts.values()) out.push(this.discountItem(d));
    for (const s of this.shipments.values()) out.push(this.shipmentItem(s));
    out.push(...this.payments);
    out.push(...this.returnDocs.values());
    return out;
  }

  itemByKey(key: string): OnecJsonObject | undefined {
    const i = key.indexOf(':');
    const type = key.slice(0, i);
    const ref = key.slice(i + 1);
    switch (type) {
      case 'Catalog_Партнеры':
      case 'Catalog_Контрагенты':
      case 'Catalog_СоглашенияСКлиентами': {
        const p = [...this.partners.values()].find(
          (x) => x.ref === ref || x.counterpartyRef === ref || x.agreementRef === ref,
        );
        return p ? this.partnerItems(p).find((it) => it.type === type && it.ref === ref) : undefined;
      }
      case 'Catalog_СкидкиНаценки': {
        const d = this.discounts.get(ref);
        return d ? this.discountItem(d) : undefined;
      }
      case DOC_SHIPMENT: {
        const s = this.shipments.get(ref);
        return s ? this.shipmentItem(s) : undefined;
      }
      case DOC_CASH_IN:
        return this.payments.find((p) => p.ref === ref);
      case DOC_RETURN:
        return this.returnDocs.get(ref);
      default:
        return undefined;
    }
  }

  /** Подписка на изменения (ключи `type:ref` для регистрации в плане обмена). */
  subscribe(listener: (keys: readonly string[]) => void): void {
    this.listeners.push(listener);
  }

  // ------------------------------------------------------------------------------------ операции HS 1С

  /** `GET /pos/v1/customers?phone=` — кандидаты `CustomerCandidate` (без помеченных на удаление — тоже отдаются). */
  findByPhone(phone: string): OnecJsonObject[] {
    if (!/^\+[1-9]\d{7,14}$/.test(phone)) {
      throw new SyntheticOnecRejection(400, 'POS_E_BAD_REQUEST', 'phone: формат E.164');
    }
    return [...this.partners.values()]
      .filter((p) => p.phones.includes(phone))
      .map((p) => ({
        ref: p.ref,
        contractorRef: p.counterpartyRef,
        code: p.code,
        name: p.name,
        phone,
        deletionMark: p.deletionMark,
      }));
  }

  /**
   * `POST /pos/v1/customers` (ONEC-045, ONEC-046): повтор `externalId` → 200 (`created=false`); телефон другого
   * клиента при `dedupe.failOnDuplicate` → 409 `POS_E_DUPLICATE` с `details.candidates`; иначе 201.
   */
  createCustomer(request: OnecJsonObject): { status: 200 | 201; body: OnecJsonObject } {
    const externalId = str(request.externalId);
    const name = str(request.name);
    const phone = str(request.phone);
    const kind = str(request.kind);
    if (!externalId || !name || !phone || !kind || !isObj(request.dedupe)) {
      throw new SyntheticOnecRejection(
        400,
        'POS_E_BAD_REQUEST',
        'Обязательные поля: externalId, name, phone, kind, dedupe',
      );
    }
    if (!/^\+[1-9]\d{7,14}$/.test(phone)) throw new SyntheticOnecRejection(422, 'POS_E_VALIDATION', 'phone: E.164');
    const repeat = [...this.partners.values()].find((p) => p.externalId === externalId);
    if (repeat) return { status: 200, body: this.createdBody(repeat, false) };
    if (request.dedupe.failOnDuplicate === true) {
      const candidates = [...this.partners.values()].filter((p) => !p.deletionMark && p.phones.includes(phone));
      if (candidates.length > 0) {
        throw new SyntheticOnecRejection(409, 'POS_E_DUPLICATE', 'Найден другой клиент с тем же телефоном', {
          candidates: candidates.map((p) => ({ ref: p.ref, name: p.name, phone })),
        });
      }
    }
    this.createdSeq += 1;
    const n = this.createdSeq;
    const p: SyntheticPartner = {
      ref: `c3d4e5f6-00ff-4000-8000-${hex(n, 12)}`,
      counterpartyRef: `c3d4e5f6-00fe-4000-8000-${hex(n, 12)}`,
      agreementRef: `c3d4e5f6-00fd-4000-8000-${hex(n, 12)}`,
      code: `П${String(90000 + n).padStart(8, '0')}`,
      name,
      fullName: str(request.fullName) ?? null,
      kind: kind === 'legal' || kind === 'entrepreneur' ? kind : 'individual',
      taxId: str(request.taxId) ?? null,
      phones: [phone],
      creditAllowed: false,
      creditLimit: null,
      creditDays: null,
      discountPercent: null,
      deletionMark: false,
      externalId,
      scenario: null,
    };
    this.partners.set(p.ref, p);
    this.receivables.set(p.ref, { balance: '0.00', overdueAmount: '0.00', overdueDays: 0, documents: [] });
    this.emit(this.partnerItems(p).map(keyOf));
    return { status: 201, body: this.createdBody(p, true) };
  }

  /** `GET /pos/v1/customers/{ref}/receivables` (ONEC-047): снимок с `snapshotAt = now()`; нет клиента/снимка → 404. */
  getReceivables(ref: string): OnecJsonObject {
    const p = this.partners.get(ref);
    const r = this.receivables.get(ref);
    if (!p || !r) throw new SyntheticOnecRejection(404, 'POS_E_NOT_FOUND', 'Клиент не найден');
    const limit = p.creditLimit;
    const available = limit === null ? null : Money.of(limit).minus(Money.of(r.balance)).toString();
    return {
      customerRef: ref,
      snapshotAt: bishkekIso(this.now()),
      balance: r.balance,
      overdueAmount: r.overdueAmount,
      overdueDays: r.overdueDays,
      creditAllowed: p.creditAllowed,
      creditLimit: limit,
      creditDays: p.creditDays,
      creditAvailable: available,
      documents: r.documents.map((d) => ({
        documentRef: d.documentRef,
        documentType: d.documentType,
        number: d.number,
        date: `${d.date}T10:00:00+06:00`,
        amount: d.amount,
        paid: d.paid,
        remaining: d.remaining,
        dueDate: d.dueDate === null ? null : `${d.dueDate}T00:00:00+06:00`,
        overdueDays: d.overdueDays,
      })),
    };
  }

  /**
   * `POST /pos/v1/returns` (ONEC-048, ONEC-067): повтор `externalId` → 200; неизвестная реализация → 422
   * `POS_E_VALIDATION`; количество > отгружено − возвращено − в открытых заявках → 409 `POS_E_STATE`; иначе 201
   * `submitted`.
   */
  createReturnRequest(request: OnecJsonObject): { status: 200 | 201; body: OnecJsonObject } {
    const externalId = str(request.externalId);
    const shipmentRef = str(request.shipmentRef);
    const lines = Array.isArray(request.lines) ? request.lines.filter(isObj) : [];
    if (!externalId || !shipmentRef || !str(request.customerRef) || !str(request.reasonCode) || lines.length === 0) {
      throw new SyntheticOnecRejection(400, 'POS_E_BAD_REQUEST', 'Обязательные поля заявки и хотя бы одна строка');
    }
    const existing = this.returnRequests.get(externalId);
    if (existing) return { status: 200, body: this.returnBody(existing) };
    const s = this.shipments.get(shipmentRef);
    if (!s) throw new SyntheticOnecRejection(422, 'POS_E_VALIDATION', 'Реализация не найдена');
    const asked = lines.map((l) => ({
      shipmentLineNumber: typeof l.shipmentLineNumber === 'number' ? l.shipmentLineNumber : 0,
      quantity: str(l.quantity) ?? '',
    }));
    const problems: OnecJsonObject[] = [];
    asked.forEach((a, idx) => {
      const line = s.lines.find((x) => x.lineNumber === a.shipmentLineNumber);
      if (!line) {
        problems.push({ lineNumber: idx + 1, text: 'Нет строки реализации' });
        return;
      }
      const pending = [...this.returnRequests.values()]
        .filter((r) => r.shipmentRef === shipmentRef && (r.status === 'submitted' || r.status === 'accepted'))
        .flatMap((r) => r.lines)
        .filter((x) => x.shipmentLineNumber === a.shipmentLineNumber)
        .reduce((n, x) => n + piecesOf(x.quantity), 0);
      const left = piecesOf(line.quantity) - piecesOf(line.returnedQuantity) - pending;
      if (piecesOf(a.quantity) > left) problems.push({ lineNumber: idx + 1, text: 'Превышено отгруженное количество' });
    });
    if (problems.length > 0) {
      throw new SyntheticOnecRejection(409, 'POS_E_STATE', 'Количество больше отгруженного за вычетом возвращённого', {
        lines: problems,
      });
    }
    this.returnSeq += 1;
    const rr: SyntheticReturnRequest = {
      externalId,
      ref: `f1e2d3c4-7000-4000-8000-${hex(this.returnSeq, 12)}`,
      number: `ЗВ00-${String(this.returnSeq).padStart(6, '0')}`,
      shipmentRef,
      customerRef: s.customerRef,
      lines: asked,
      status: 'submitted',
    };
    this.returnRequests.set(externalId, rr);
    return { status: 201, body: this.returnBody(rr) };
  }

  /** `GET /pos/v1/returns/{uuid}/status`. */
  getReturnRequestStatus(externalId: string): OnecJsonObject {
    const rr = this.returnRequests.get(externalId);
    if (!rr) throw new SyntheticOnecRejection(404, 'POS_E_NOT_FOUND', 'Заявка не найдена');
    return this.returnBody(rr);
  }

  // ------------------------------------------------------------------------------- управление (тесты)

  /** Заменить снимок долга клиента (`null` — 1С не отдаёт снимок: 404). */
  setReceivables(ref: string, r: SyntheticReceivables | null): void {
    if (!this.partners.has(ref)) throw new Error(`SyntheticCashier: нет клиента ${ref}`);
    this.receivables.set(ref, r);
  }

  /** Изменить условия соглашения/карточку клиента (регистрирует партнёра и соглашение в плане обмена). */
  updatePartner(
    ref: string,
    patch: Partial<
      Pick<
        SyntheticPartner,
        | 'name'
        | 'phones'
        | 'creditAllowed'
        | 'creditLimit'
        | 'creditDays'
        | 'discountPercent'
        | 'deletionMark'
        | 'taxId'
      >
    >,
  ): SyntheticPartner {
    const p = this.partners.get(ref);
    if (!p) throw new Error(`SyntheticCashier: нет клиента ${ref}`);
    const next: SyntheticPartner = { ...p, ...patch };
    this.partners.set(ref, next);
    this.version += 1;
    this.emit(this.partnerItems(next).map(keyOf));
    return next;
  }

  /**
   * Статус заявки на возврат в 1С. `completed` — проводит «Возврат товаров от клиента»: растут
   * `returnedQuantity`/`returnedTotal` реализации, документ возврата регистрируется в плане обмена.
   */
  setReturnStatus(externalId: string, status: SyntheticReturnRequest['status']): void {
    const rr = this.returnRequests.get(externalId);
    if (!rr) throw new Error(`SyntheticCashier: нет заявки ${externalId}`);
    rr.status = status;
    if (status !== 'completed') return;
    const s = this.shipments.get(rr.shipmentRef);
    if (!s) return;
    const doc = this.applyReturn(s, rr.lines, rr.ref.replace('-7000-', '-2000-'), rr.number.replace('ЗВ', 'ВЗ'));
    this.emit([keyOf(this.shipmentItem(s)), keyOf(doc)]);
  }

  /** Связать реализацию с заказом POS (`orderExternalId`) — регистрирует реализацию в плане обмена. */
  linkShipmentToOrder(shipmentRef: string, orderExternalId: string): void {
    const s = this.shipments.get(shipmentRef);
    if (!s) throw new Error(`SyntheticCashier: нет реализации ${shipmentRef}`);
    s.orderExternalId = orderExternalId;
    s.dataVersion += 1;
    this.emit([keyOf(this.shipmentItem(s))]);
  }

  /**
   * Заменить товары строк реализаций (например, ссылки синтетического каталога, загруженного в БД теста) —
   * реализации пересобираются детерминированно (те же номера и ссылки документов).
   */
  bindProducts(products: readonly SyntheticProductRef[]): void {
    if (products.length === 0) throw new Error('SyntheticCashier.bindProducts: пустой список');
    this.products = products;
    this.shipments.clear();
    this.payments.length = 0;
    this.returnDocs.clear();
    this.generateDocuments();
  }

  // ------------------------------------------------------------------------------------------ генерация

  private generate(): void {
    const scenarios = Object.keys(CASHIER_SCENARIOS) as CashierScenario[];
    scenarios.forEach((s, i) => this.addScenario(s, i + 1));
    const rnd = prng(this.seed * 7919 + 13);
    for (let i = 1; i <= this.extraCount; i++) {
      const legal = rnd() < 0.4;
      const name = legal
        ? `${NAMES_LEGAL[i % NAMES_LEGAL.length]} ${i}`
        : `${NAMES_INDIVIDUAL[i % NAMES_INDIVIDUAL.length]} ${i}`;
      const noLimit = rnd() < 0.1;
      const ref = `c3d4e5f6-${hex(this.seed, 4)}-4000-8000-${hex(i, 12)}`;
      const p: SyntheticPartner = {
        ref,
        counterpartyRef: `c3d4e5f6-${hex(this.seed, 4)}-4000-8001-${hex(i, 12)}`,
        agreementRef: `c3d4e5f6-${hex(this.seed, 4)}-4000-8002-${hex(i, 12)}`,
        code: String(10000 + this.seed * 1000 + i).padStart(8, '0'),
        name,
        fullName: legal ? `${name} (полное)` : null,
        kind: legal ? (name.startsWith('ИП') ? 'entrepreneur' : 'legal') : 'individual',
        taxId: legal ? `${String(10000000000000 + this.seed * 100000 + i).slice(-14)}` : null,
        phones: [`+99670${String(this.seed * 10000 + i).padStart(7, '0')}`],
        creditAllowed: rnd() < 0.8,
        creditLimit: noLimit ? null : som(20000 + Math.floor(rnd() * 8) * 10000).toString(),
        creditDays: 14,
        discountPercent: rnd() < 0.3 ? '3.00' : null,
        deletionMark: i % 17 === 0,
        externalId: null,
        scenario: null,
      };
      this.partners.set(ref, p);
    }
    this.generateDocuments();
    this.generateDiscounts();
  }

  private addScenario(s: CashierScenario, index: number): void {
    const ref = CASHIER_SCENARIOS[s];
    const tail = ref.slice(-2);
    const legal = !['debtWithinLimit', 'overdue', 'creditNotAllowed', 'buyer'].includes(s);
    const limitBy: Partial<Record<CashierScenario, string | null>> = {
      debtWithinLimit: '100000.00',
      overdue: '50000.00',
      noDebt: '50000.00',
      overLimit: '50000.00',
      noLimit: null,
      creditNotAllowed: null,
      incomplete: '60000.00',
      stale: '40000.00',
      buyer: '30000.00',
      advance: '20000.00',
    };
    const p: SyntheticPartner = {
      ref,
      counterpartyRef: `c3d4e5f6-0000-4000-8000-0000000000c${tail.slice(-1)}`,
      agreementRef: `c3d4e5f6-0000-4000-8000-0000000000a${tail.slice(-1)}`,
      code: String(4520 + index).padStart(8, '0'),
      name: SCENARIO_NAMES[s],
      fullName: legal ? `${SCENARIO_NAMES[s]} (юр. лицо)` : null,
      kind: legal ? (SCENARIO_NAMES[s].startsWith('ИП') ? 'entrepreneur' : 'legal') : 'individual',
      taxId: legal ? `0110${String(2020000000 + index).padStart(10, '0')}` : null,
      phones: [CASHIER_SCENARIO_PHONES[s]],
      creditAllowed: s !== 'creditNotAllowed',
      creditLimit: limitBy[s] ?? null,
      creditDays: s === 'creditNotAllowed' ? 0 : s === 'overdue' ? 7 : 14,
      discountPercent: s === 'buyer' || s === 'debtWithinLimit' ? '5.00' : null,
      deletionMark: false,
      externalId: null,
      scenario: s,
    };
    this.partners.set(ref, p);
  }

  /** Реализации, оплаты, возвраты и снимки долга (зависят от товаров). */
  private generateDocuments(): void {
    const rnd = prng(this.seed * 104729 + 7);
    let shipSeq = 0;
    const ship = (customerRef: string, date: string, lines: number, opts: { ref?: string; number?: string } = {}) => {
      shipSeq += 1;
      const ref = opts.ref ?? `f1e2d3c4-1000-4000-8000-${hex(shipSeq, 12)}`;
      const shipLines: SyntheticShipmentLine[] = [];
      let total = Money.ZERO;
      for (let l = 1; l <= lines; l++) {
        const pr = this.products[(shipSeq * 3 + l) % this.products.length];
        const count = 1 + ((shipSeq + l) % 4);
        const amount = Money.of(pr.price).times(pieces(count));
        total = total.plus(amount);
        shipLines.push({
          lineNumber: l,
          productRef: pr.productRef,
          variantRef: pr.variantRef,
          productName: pr.name,
          quantity: pieces(count),
          price: Money.of(pr.price).toString(),
          amount: amount.toString(),
          discountAmount: '0.00',
          returnedQuantity: '0.000',
        });
      }
      const s: SyntheticShipment = {
        ref,
        number: opts.number ?? `РТ00-${String(2000 + shipSeq).padStart(6, '0')}`,
        date,
        customerRef,
        orderExternalId: null,
        total: total.toString(),
        discountTotal: '0.00',
        paymentDueDate: addDays(date, 14),
        lines: shipLines,
        returnedTotal: '0.00',
        dataVersion: 1,
      };
      this.shipments.set(ref, s);
      return s;
    };

    // Сценарные реализации.
    const S = CASHIER_SCENARIOS;
    ship(S.debtWithinLimit, addDays(this.asOf, -11), 2, {
      ref: 'f1e2d3c4-0000-4000-8000-000000000031',
      number: 'РТ00-001790',
    });
    ship(S.debtWithinLimit, addDays(this.asOf, -2), 2, { ref: FIXTURE_SHIPMENT_REF, number: 'РТ00-001801' });
    ship(S.overdue, addDays(this.asOf, -19), 1, { ref: 'f1e2d3c4-0000-4000-8000-000000000032', number: 'РТ00-001702' });
    // Покупатель: реализации каждый месяц на `salesHistoryMonths + 2` месяцев назад (две — за границей истории).
    const buyerShipments: SyntheticShipment[] = [];
    for (let m = 0; m <= this.salesHistoryMonths + 1; m++) {
      buyerShipments.push(ship(S.buyer, monthsBack(addDays(this.asOf, -1), m), 1 + (m % 3)));
    }
    // Возврат по второй реализации покупателя (1 шт. первой строки) — документ 1С, уже проведён.
    const returned = buyerShipments[1];
    this.applyReturn(
      returned,
      [{ shipmentLineNumber: 1, quantity: '1.000' }],
      'f1e2d3c4-2000-4000-8000-000000000001',
      'ВЗ00-000001',
    );
    // Обычные клиенты: 0–3 реализации за последние 10 месяцев.
    for (const p of this.partners.values()) {
      if (p.scenario !== null || p.externalId !== null) continue;
      const k = Math.floor(rnd() * 4);
      for (let j = 0; j < k; j++) ship(p.ref, monthsBack(addDays(this.asOf, -(1 + j * 9)), j * 3), 1 + (j % 2));
    }
    // Оплата (ПКО) покупателя.
    this.payments.push({
      type: DOC_CASH_IN,
      ref: 'f1e2d3c4-3000-4000-8000-000000000001',
      dataVersion: dataVersion(1),
      deletionMark: false,
      externalId: null,
      number: 'ПКО0-000101',
      date: `${addDays(this.asOf, -5)}T12:00:00+06:00`,
      posted: true,
      customerRef: S.buyer,
      amount: '1000.00',
    });
    this.generateReceivables(buyerShipments);
  }

  private generateReceivables(buyerShipments: readonly SyntheticShipment[]): void {
    const S = CASHIER_SCENARIOS;
    const inv = (
      ref: string,
      number: string,
      date: string,
      amount: string,
      paid: string,
      due: string | null,
    ): SyntheticReceivableDoc => {
      const remaining = Money.of(amount).minus(Money.of(paid)).toString();
      const overdueDays =
        due !== null && due < this.asOf ? Math.round((Date.parse(this.asOf) - Date.parse(due)) / DAY_MS) : 0;
      return {
        documentRef: ref,
        documentType: DOC_SHIPMENT,
        number,
        date,
        amount,
        paid,
        remaining,
        dueDate: due,
        overdueDays,
      };
    };
    const set = (ref: string, balance: string, overdue: string | null, docs: SyntheticReceivableDoc[]) => {
      const od = overdue === null ? null : Math.max(0, ...docs.map((d) => d.overdueDays));
      this.receivables.set(ref, { balance, overdueAmount: overdue, overdueDays: od, documents: docs });
    };
    const a = this.asOf;
    set(S.debtWithinLimit, '12300.00', '0.00', [
      inv('f1e2d3c4-0000-4000-8000-000000000031', 'РТ00-001790', addDays(a, -11), '15300.00', '3000.00', addDays(a, 3)),
    ]);
    set(S.overdue, '8000.00', '8000.00', [
      inv('f1e2d3c4-0000-4000-8000-000000000032', 'РТ00-001702', addDays(a, -19), '8000.00', '0.00', addDays(a, -12)),
    ]);
    set(S.noDebt, '0.00', '0.00', []);
    set(S.overLimit, '49000.00', '0.00', [
      inv('f1e2d3c4-0000-4000-8000-000000000041', 'РТ00-001811', addDays(a, -6), '30000.00', '0.00', addDays(a, 8)),
      inv('f1e2d3c4-0000-4000-8000-000000000042', 'РТ00-001812', addDays(a, -3), '19000.00', '0.00', addDays(a, 11)),
    ]);
    set(S.noLimit, '5000.00', '0.00', [
      inv('f1e2d3c4-0000-4000-8000-000000000051', 'РТ00-001821', addDays(a, -4), '5000.00', '0.00', addDays(a, 10)),
    ]);
    set(S.creditNotAllowed, '0.00', '0.00', []);
    set(S.incomplete, '7000.00', null, [
      inv('f1e2d3c4-0000-4000-8000-000000000071', 'РТ00-001831', addDays(a, -9), '7000.00', '0.00', null),
    ]);
    set(S.stale, '2000.00', '0.00', [
      inv('f1e2d3c4-0000-4000-8000-000000000081', 'РТ00-001841', addDays(a, -1), '2000.00', '0.00', addDays(a, 13)),
    ]);
    const last = buyerShipments[0];
    set(S.buyer, '4500.00', '0.00', [
      inv(last.ref, last.number, last.date, '5500.00', '1000.00', addDays(a, 13)),
      {
        documentRef: 'f1e2d3c4-3000-4000-8000-000000000001',
        documentType: DOC_CASH_IN,
        number: 'ПКО0-000101',
        date: addDays(a, -5),
        amount: '1000.00',
        paid: '1000.00',
        remaining: '0.00',
        dueDate: null,
        overdueDays: 0,
      },
      {
        documentRef: 'f1e2d3c4-2000-4000-8000-000000000001',
        documentType: DOC_RETURN,
        number: 'ВЗ00-000001',
        date: buyerShipments[1].date,
        amount: buyerShipments[1].lines[0].price,
        paid: buyerShipments[1].lines[0].price,
        remaining: '0.00',
        dueDate: null,
        overdueDays: 0,
      },
      {
        documentRef: 'f1e2d3c4-4000-4000-8000-000000000001',
        documentType: DOC_ADJUSTMENT,
        number: 'КР00-000003',
        date: addDays(a, -40),
        amount: '0.00',
        paid: '0.00',
        remaining: '0.00',
        dueDate: null,
        overdueDays: 0,
      },
    ]);
    set(S.advance, '-2500.00', '0.00', [
      {
        documentRef: 'f1e2d3c4-3000-4000-8000-0000000000a1',
        documentType: DOC_CASH_IN,
        number: 'ПКО0-000102',
        date: addDays(a, -2),
        amount: '2500.00',
        paid: '2500.00',
        remaining: '-2500.00',
        dueDate: null,
        overdueDays: 0,
      },
    ]);
    // Обычные клиенты: сальдо 0…29 000 сом; у каждого пятого — просрочка (часть долга).
    const rnd = prng(this.seed * 15485863 + 3);
    let n = 0;
    for (const p of this.partners.values()) {
      if (p.scenario !== null) continue;
      if (p.externalId !== null) {
        this.receivables.set(
          p.ref,
          this.receivables.get(p.ref) ?? { balance: '0.00', overdueAmount: '0.00', overdueDays: 0, documents: [] },
        );
        continue;
      }
      n += 1;
      const balance = som(Math.floor(rnd() * 30) * 1000);
      const hasOverdue = n % 5 === 0 && !balance.isZero();
      const overdue = hasOverdue ? som(Math.floor(rnd() * 3 + 1) * 500) : Money.ZERO;
      const overdueAmount = overdue.compare(balance) > 0 ? balance : overdue;
      const docRef = `f1e2d3c4-5000-4000-8000-${hex(n, 12)}`;
      const due = hasOverdue ? addDays(a, -(5 + n)) : addDays(a, 7);
      const docs = balance.isZero()
        ? []
        : [
            inv(
              docRef,
              `РТ00-${String(3000 + n).padStart(6, '0')}`,
              addDays(due, -14),
              balance.toString(),
              '0.00',
              due,
            ),
          ];
      set(p.ref, balance.toString(), overdueAmount.toString(), docs);
    }
  }

  private generateDiscounts(): void {
    const S = CASHIER_SCENARIOS;
    const rules: SyntheticDiscountRule[] = [
      {
        ref: 'd15c0000-0000-4000-8000-000000000001',
        code: 'СК-000001',
        description: 'Скидка постоянного клиента 5 %',
        kind: 'percent',
        value: '5.00',
        isActive: true,
        appliesAutomatically: true,
        validFrom: null,
        validTo: null,
        conditions: { partnerRefs: [S.buyer, S.debtWithinLimit] },
        deletionMark: false,
      },
      {
        ref: 'd15c0000-0000-4000-8000-000000000002',
        code: 'СК-000002',
        description: 'Оптовая скидка от 50 000 сом',
        kind: 'percent',
        value: '3.00',
        isActive: true,
        appliesAutomatically: true,
        validFrom: addDays(this.asOf, -90),
        validTo: null,
        conditions: { minTotal: '50000.00' },
        deletionMark: false,
      },
      {
        ref: 'd15c0000-0000-4000-8000-000000000003',
        code: 'СК-000003',
        description: 'Сезонная акция (завершена)',
        kind: 'percent',
        value: '10.00',
        isActive: true,
        appliesAutomatically: true,
        validFrom: addDays(this.asOf, -60),
        validTo: addDays(this.asOf, -30),
        conditions: {},
        deletionMark: false,
      },
      {
        ref: 'd15c0000-0000-4000-8000-000000000004',
        code: 'СК-000004',
        description: 'Скидка 500 сом на заказ (отключена)',
        kind: 'fixed_amount',
        value: '500.00',
        isActive: false,
        appliesAutomatically: false,
        validFrom: null,
        validTo: null,
        conditions: {},
        deletionMark: false,
      },
      {
        ref: 'd15c0000-0000-4000-8000-000000000005',
        code: 'СК-000005',
        description: 'Удалённое правило',
        kind: 'percent',
        value: '1.00',
        isActive: true,
        appliesAutomatically: true,
        validFrom: null,
        validTo: null,
        conditions: {},
        deletionMark: true,
      },
    ];
    for (const r of rules) this.discounts.set(r.ref, r);
  }

  private applyReturn(
    s: SyntheticShipment,
    lines: readonly { readonly shipmentLineNumber: number; readonly quantity: string }[],
    ref: string,
    number: string,
  ): OnecJsonObject {
    let total = Money.ZERO;
    const docLines: OnecJsonObject[] = [];
    for (const l of lines) {
      const line = s.lines.find((x) => x.lineNumber === l.shipmentLineNumber);
      if (!line) continue;
      line.returnedQuantity = pieces(piecesOf(line.returnedQuantity) + piecesOf(l.quantity));
      const amount = Money.of(line.price).times(l.quantity);
      total = total.plus(amount);
      docLines.push({
        lineNumber: docLines.length + 1,
        productRef: line.productRef,
        variantRef: line.variantRef,
        packagingRef: null,
        productName: line.productName,
        quantity: l.quantity,
        price: line.price,
        amount: amount.toString(),
        discountAmount: '0.00',
        returnedQuantity: null,
      });
    }
    s.returnedTotal = Money.of(s.returnedTotal).plus(total).toString();
    s.dataVersion += 1;
    const doc: OnecJsonObject = {
      type: DOC_RETURN,
      ref,
      dataVersion: dataVersion(1),
      deletionMark: false,
      number,
      date: `${this.asOf}T15:00:00+06:00`,
      posted: true,
      customerRef: s.customerRef,
      shipmentRef: s.ref,
      total: total.toString(),
      lines: docLines,
    };
    this.returnDocs.set(ref, doc);
    return doc;
  }

  // -------------------------------------------------------------------------------------------- рендер

  private partnerItems(p: SyntheticPartner): OnecJsonObject[] {
    const v = dataVersion(this.version);
    const phones = p.phones.map((x) => ({ phone: x, presentation: formatPhone(x) }));
    return [
      {
        type: 'Catalog_Партнеры',
        ref: p.ref,
        dataVersion: v,
        deletionMark: p.deletionMark,
        externalId: p.externalId,
        code: p.code,
        description: p.name,
        fullName: p.fullName,
        isClient: true,
        mainAgreementRef: p.agreementRef,
        phones,
      },
      {
        type: 'Catalog_Контрагенты',
        ref: p.counterpartyRef,
        dataVersion: v,
        deletionMark: p.deletionMark,
        code: p.code,
        description: p.fullName ?? p.name,
        partnerRef: p.ref,
        taxId: p.taxId,
        phones,
        // предложение GQ-FND-03: вид клиента (`customer_type`) — в контракте нет источника.
        kind: p.kind,
      },
      {
        type: 'Catalog_СоглашенияСКлиентами',
        ref: p.agreementRef,
        dataVersion: v,
        deletionMark: p.deletionMark,
        description: `Соглашение с ${p.name}`,
        partnerRef: p.ref,
        priceListRef: this.priceListRef,
        creditAllowed: p.creditAllowed,
        creditLimit: p.creditLimit,
        creditDays: p.creditDays,
        // предложение GQ-FND-04: скидка клиента (`customers.discount_percent`) — в контракте нет источника.
        discountPercent: p.discountPercent,
      },
    ];
  }

  private discountItem(d: SyntheticDiscountRule): OnecJsonObject {
    const base: OnecJsonObject = {
      type: 'Catalog_СкидкиНаценки',
      ref: d.ref,
      dataVersion: dataVersion(1),
      deletionMark: d.deletionMark,
      code: d.code,
      description: d.description,
    };
    if (!this.discountDetails) return base;
    // предложение GQ-FND-05: параметры правила для `discount_rules` (kind/value/период/условия).
    return {
      ...base,
      kind: d.kind,
      value: d.value,
      isActive: d.isActive,
      appliesAutomatically: d.appliesAutomatically,
      validFrom: d.validFrom,
      validTo: d.validTo,
      conditions: {
        ...(d.conditions.minTotal ? { minTotal: d.conditions.minTotal } : {}),
        ...(d.conditions.partnerRefs ? { partnerRefs: [...d.conditions.partnerRefs] } : {}),
      },
    };
  }

  private shipmentItem(s: SyntheticShipment): OnecJsonObject {
    return {
      type: DOC_SHIPMENT,
      ref: s.ref,
      dataVersion: dataVersion(s.dataVersion),
      deletionMark: false,
      number: s.number,
      date: `${s.date}T11:00:00+06:00`,
      posted: true,
      customerRef: s.customerRef,
      orderRef: null,
      orderExternalId: s.orderExternalId,
      warehouseRef: this.warehouseRef,
      total: s.total,
      discountTotal: s.discountTotal,
      currency: 'KGS',
      paymentDueDate: s.paymentDueDate === null ? null : `${s.paymentDueDate}T00:00:00+06:00`,
      returnedTotal: s.returnedTotal,
      comment: null,
      lines: s.lines.map((l) => ({
        lineNumber: l.lineNumber,
        productRef: l.productRef,
        variantRef: l.variantRef,
        packagingRef: null,
        productName: l.productName,
        quantity: l.quantity,
        price: l.price,
        amount: l.amount,
        discountAmount: l.discountAmount,
        returnedQuantity: l.returnedQuantity,
      })),
    };
  }

  private createdBody(p: SyntheticPartner, created: boolean): OnecJsonObject {
    return { externalId: p.externalId, ref: p.ref, contractorRef: p.counterpartyRef, code: p.code, created };
  }

  private returnBody(rr: SyntheticReturnRequest): OnecJsonObject {
    const raw: Record<SyntheticReturnRequest['status'], string> = {
      submitted: 'НаРассмотрении',
      accepted: 'КВыполнению',
      rejected: 'Отклонена',
      completed: 'Выполнена',
    };
    return { ref: rr.ref, number: rr.number, status: rr.status, onecStatus: raw[rr.status] };
  }

  private emit(keys: readonly string[]): void {
    for (const l of this.listeners) l(keys);
  }
}

function keyOf(it: OnecJsonObject): string {
  return `${it.type as string}:${it.ref as string}`;
}

function str(v: OnecJson | undefined): string | undefined {
  return typeof v === 'string' && v !== '' ? v : undefined;
}

function isObj(v: OnecJson | undefined): v is OnecJsonObject {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function formatPhone(e164: string): string {
  const d = e164.slice(4);
  return `+996 (${d.slice(0, 3)}) ${d.slice(3, 6)}-${d.slice(6)}`;
}
