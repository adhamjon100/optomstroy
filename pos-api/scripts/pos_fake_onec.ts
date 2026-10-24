/**
 * Управляемый фейк HTTP-сервиса расширения 1С «OptomstroyPOS» для этапа F на настоящих процессах (local-stack
 * `pos-smoke` и `serve --pos-fixtures`; RM-F-009, RM-F-010 «на фикстурах»). **Тестовые данные, не реальная
 * интеграция**: ответы построены из фикстур `contracts/onec/fixtures` (05 §6.4, §6.7), состояние — в памяти процесса.
 *
 *   APP_ENV=dev node --import tsx scripts/pos_fake_onec.ts --port 8091 [--prefix /ut11/hs] [--ready-file <path>]
 *                                                           [--qr-paid-after-polls N]
 *
 * pos-api и pos-worker подключаются к нему как к настоящему расширению (`ONEC_MODE=extension`,
 * `ONEC_BASE_URL=http://127.0.0.1:<port>`, `ONEC_HS_PATH=ut11/hs`, `ONEC_HS_USER_FILE`, `ONEC_HS_TOKEN_FILE`) —
 * проверяется и боевой HTTP-адаптер `OnecExtensionGateway`. Поведение:
 * - `POST /pos/v1/orders` — «Заказ клиента» (`НеСогласован`), **идемпотентно по `externalId`** (повтор → 200, тот же
 *   `ref`/номер, дубль не создаётся — 05 ONEC-039); режимы `accept` | `unavailable` (503 `POS_E_MAINTENANCE`) |
 *   `reject` (422 `POS_E_VALIDATION`); счётчик режимов `failNext` — N отказов, затем `accept`;
 * - `GET /pos/v1/orders/{externalId}/status`, `POST /pos/v1/orders/status` — статус, меняется управляющим вызовом;
 * - `POST /pos/v1/payments/qr` — QR (`pending`, сумма запроса, срок = сейчас + `requestedTtlSeconds`), идемпотентно по
 *   `externalId`; `GET /pos/v1/payments/{externalId}/status` — `pending`, пока не наступил N-й опрос
 *   (`--qr-paid-after-polls`, по умолчанию 2; 0 — только управляющим вызовом) или не вызван `/__fake/qr/{id}/pay`;
 *   `POST …/qr/cancel` — `cancelled`;
 * - `POST /pos/v1/check` — фикстура `check.stock-prices.200` (замечаний к строкам корзины нет);
 * - `GET /pos/v1/health`, `GET /pos/v1/changes` (пустое сообщение), `POST /pos/v1/changes/ack|reregister`.
 *
 * Режим кассира (`--cashier`, этап G; local-stack `cashier-smoke` и `serve --cashier-fixtures`): состояние — синтетика
 * кассира `SyntheticCashier` (те же данные, что `FakeOnecGateway({ cashier })` в тестах: 10 сценарных клиентов —
 * долг в лимите, просрочка, без долга, почти исчерпан лимит, лимит не задан, без отсрочки, неполный снимок,
 * «устаревший», покупатель с историей и возвратом, аванс — и `--cashier-extra` обычных; реализации за
 * `SALES_HISTORY_MONTHS`+, оплаты, возвраты, правила скидок). Товары строк реализаций — синтетический каталог
 * `--catalog-sku N` (seed 1, тот же, что загружает `load_catalog_fixtures`), иначе товар фикстуры. Методы по состоянию:
 * - `GET /pos/v1/changes`, `POST …/changes/ack`, `POST …/changes/reregister` — план обмена над синтетикой кассира
 *   (клиенты, соглашения, скидки, реализации, оплаты, документы возврата; пагинация `limit`/`cursor`);
 * - `GET /pos/v1/customers?phone=` — поиск по телефону; `POST /pos/v1/customers` — 201 / 200 (повтор externalId) /
 *   409 `POS_E_DUPLICATE`;
 * - `GET /pos/v1/customers/{ref}/receivables` — снимок долга на момент ответа (404 — клиента нет);
 * - `POST /pos/v1/returns` — заявка на возврат 201 / 200 / 409 / 422; `GET /pos/v1/returns/{externalId}/status`.
 *
 * Управляющие вызовы (только этот dev-процесс; без `APP_ENV=dev|test` фейк не стартует; заголовок не нужен):
 *   GET  /__fake/state                                   — состояние (заказы, QR, режим, журнал вызовов)
 *   POST /__fake/reset                                   — сброс состояния
 *   POST /__fake/orders/mode {mode, failNext?}           — accept | unavailable | reject (failNext — N раз, затем accept)
 *   POST /__fake/orders/{externalId}/status {status, approved?} — например {"status":"КВыполнению","approved":true}
 *   POST /__fake/qr/config {paidAfterPolls}              — N опросов до оплаты (0 — только вручную)
 *   POST /__fake/qr/{externalId}/pay {amount?}           — оплатить QR сейчас (сумма по умолчанию — выданная)
 *   POST /__fake/down {down: true|false}                 — все методы /pos/v1/* → 503 (1С недоступна)
 * Режим кассира (`--cashier`):
 *   GET  /__fake/cashier/state                           — сценарные клиенты (ref, телефон), состояние плана обмена
 *   POST /__fake/cashier/returns/{externalId}/status {status} — submitted | accepted | rejected | completed
 *                                                          (completed — проводит «Возврат товаров от клиента»)
 *   POST /__fake/cashier/customers/{ref} {creditLimit?, creditAllowed?, creditDays?, discountPercent?} — изменить
 *                                                          соглашение клиента (регистрируется в плане обмена)
 */
import { randomUUID } from 'node:crypto';
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { FakeExchangePlan } from '../src/integrations/onec/fake-exchange-plan.js';
import { catalogProducts, DEFAULT_ONEC_FIXTURES_DIR } from '../src/integrations/onec/fake-onec.gateway.js';
import { OnecError } from '../src/integrations/onec/onec-error.js';
import {
  CASHIER_SCENARIO_PHONES,
  CASHIER_SCENARIOS,
  SyntheticCashier,
  SyntheticOnecRejection,
} from '../src/integrations/onec/synthetic-cashier.js';
import { SyntheticCatalog } from '../src/integrations/onec/synthetic-catalog.js';

type Json = Record<string, unknown>;

/** Строковое поле тела запроса (иначе пустая строка). */
function str(v: unknown): string {
  return typeof v === 'string' ? v : '';
}
type OrderMode = 'accept' | 'unavailable' | 'reject';

interface FakeOrder {
  readonly externalId: string;
  readonly ref: string;
  readonly number: string;
  readonly date: string;
  status: string;
  approved: boolean;
  readonly total: string;
  readonly createdAt: string;
  createCalls: number;
}

interface FakeQr {
  readonly externalId: string;
  readonly orderExternalId: string | null;
  readonly reference: string;
  readonly amount: string;
  readonly createdAt: string;
  readonly expiresAt: string;
  status: 'pending' | 'paid' | 'expired' | 'cancelled';
  polls: number;
  paidAmount: string | null;
  paidAt: string | null;
  readonly bankReference: string;
}

interface FakeResponse {
  readonly status: number;
  readonly body?: unknown;
}

const BISHKEK_OFFSET_MS = 6 * 3600 * 1000;

/** ISO-время в поясе 1С магазина (+06:00), как в фикстурах. */
function onecTime(d = new Date()): string {
  return `${new Date(d.getTime() + BISHKEK_OFFSET_MS).toISOString().slice(0, 19)}+06:00`;
}

function loadFixtures(): Map<string, Json> {
  const m = new Map<string, Json>();
  for (const f of readdirSync(DEFAULT_ONEC_FIXTURES_DIR).filter((x) => x.endsWith('.json'))) {
    const raw = JSON.parse(readFileSync(join(DEFAULT_ONEC_FIXTURES_DIR, f), 'utf8')) as Json;
    if (raw._note !== 'тестовые данные') throw new Error(`фикстура ${f} без маркировки «тестовые данные»`);
    m.set(f.slice(0, -'.json'.length), raw);
  }
  return m;
}

/** Синтетика кассира и план обмена над ней (`--cashier`). */
export interface FakeCashierState {
  readonly cashier: SyntheticCashier;
  readonly exchange: FakeExchangePlan;
}

/** Режим кассира: синтетика (`extraCustomers` обычных клиентов) и план обмена; товары — каталог `catalogSku` (seed 1). */
export function createCashierState(
  o: { readonly catalogSku?: number; readonly extraCustomers?: number } = {},
): FakeCashierState {
  const products =
    o.catalogSku && o.catalogSku > 0 ? catalogProducts(new SyntheticCatalog({ skuCount: o.catalogSku, seed: 1 })) : [];
  const cashier = new SyntheticCashier({
    ...(products.length > 0 ? { products } : {}),
    ...(o.extraCustomers !== undefined ? { extraCustomers: o.extraCustomers } : {}),
  });
  const exchange = new FakeExchangePlan(null).addSource(cashier);
  cashier.subscribe((keys) => exchange.register(keys));
  exchange.registerAll();
  return { cashier, exchange };
}

export class PosFakeOnec {
  private readonly fixtures = loadFixtures();
  readonly orders = new Map<string, FakeOrder>();
  readonly qr = new Map<string, FakeQr>();
  readonly calls: { readonly at: string; readonly method: string; readonly path: string; readonly status: number }[] =
    [];
  orderMode: OrderMode = 'accept';
  failNext = 0;
  down = false;
  orderSeq = 4600;
  messageNumber = 6000;

  constructor(
    public paidAfterPolls = 2,
    readonly cashierState: FakeCashierState | null = null,
  ) {}

  reset(): void {
    this.orders.clear();
    this.qr.clear();
    this.calls.length = 0;
    this.orderMode = 'accept';
    this.failNext = 0;
    this.down = false;
  }

  private fixtureBody(name: string): Json {
    const f = this.fixtures.get(name);
    if (!f) throw new Error(`нет фикстуры ${name}`);
    return structuredClone(f.body) as Json;
  }

  private error(name: string): FakeResponse {
    const f = this.fixtures.get(name);
    if (!f) throw new Error(`нет фикстуры ${name}`);
    return { status: Number(f.status), body: { ...(f.body as Json), requestId: randomUUID() } };
  }

  state(): Json {
    return {
      note: 'тестовые данные — фейк 1С, не реальная интеграция',
      orderMode: this.orderMode,
      failNext: this.failNext,
      down: this.down,
      paidAfterPolls: this.paidAfterPolls,
      orders: [...this.orders.values()],
      qr: [...this.qr.values()],
      calls: this.calls.slice(-200),
    };
  }

  /** Маршрутизация запроса (путь — без префикса публикации; `query` — параметры строки запроса). */
  handle(method: string, path: string, body: Json, query: URLSearchParams = new URLSearchParams()): FakeResponse {
    if (path.startsWith('/__fake/')) return this.control(method, path, body);
    if (this.down && path.startsWith('/pos/v1/')) return this.error('error.503.maintenance');
    if (this.cashierState) {
      const r = this.cashierRoute(this.cashierState, method, path, body, query);
      if (r) return r;
    }
    let m: RegExpExecArray | null;
    if (method === 'GET' && path === '/pos/v1/health') {
      return {
        status: 200,
        body: { ...this.fixtureBody('health.200'), serverTime: onecTime(), registrationBacklog: 0 },
      };
    }
    if (method === 'GET' && path === '/pos/v1/changes') {
      return {
        status: 200,
        body: { messageNumber: this.messageNumber, hasMore: false, cursor: null, generatedAt: onecTime(), items: [] },
      };
    }
    if (method === 'POST' && path === '/pos/v1/changes/ack') {
      const n = Number(body.messageNumber ?? this.messageNumber);
      if (n === this.messageNumber) this.messageNumber += 1;
      return { status: 200, body: { messageNumber: n, removedRegistrations: 0 } };
    }
    if (method === 'POST' && path === '/pos/v1/changes/reregister') return { status: 202 };
    if (method === 'POST' && path === '/pos/v1/check') {
      return { status: 200, body: { ...this.fixtureBody('check.stock-prices.200'), checkedAt: onecTime(), lines: [] } };
    }
    if (method === 'POST' && path === '/pos/v1/orders') return this.createOrder(body);
    if (method === 'POST' && path === '/pos/v1/orders/status') {
      const ids = Array.isArray(body.externalIds) ? (body.externalIds as string[]) : [];
      return {
        status: 200,
        body: {
          items: ids.filter((id) => this.orders.has(id)).map((id) => this.orderStatus(this.orders.get(id)!)),
          notFound: ids.filter((id) => !this.orders.has(id)),
        },
      };
    }
    if (method === 'GET' && (m = /^\/pos\/v1\/orders\/([0-9a-f-]{36})\/status$/.exec(path))) {
      const o = this.orders.get(m[1]);
      return o ? { status: 200, body: this.orderStatus(o) } : this.error('orders-status.404');
    }
    if (method === 'POST' && (m = /^\/pos\/v1\/orders\/([0-9a-f-]{36})\/cancel$/.exec(path))) {
      const o = this.orders.get(m[1]);
      if (!o) return this.error('orders-status.404');
      o.status = 'Закрыт';
      o.approved = false;
      return { status: 200, body: { ...this.fixtureBody('orders-cancel.200'), externalId: o.externalId, ref: o.ref } };
    }
    if (method === 'POST' && path === '/pos/v1/payments/qr') return this.createQr(body);
    if (method === 'GET' && (m = /^\/pos\/v1\/payments\/([0-9a-f-]{36})\/status$/.exec(path))) {
      const q = this.qr.get(m[1]);
      if (!q) return this.error('payments-status.404');
      if (q.status === 'pending') {
        q.polls += 1;
        if (this.paidAfterPolls > 0 && q.polls >= this.paidAfterPolls) this.pay(q);
        else if (Date.parse(q.expiresAt) < Date.now()) q.status = 'expired';
      }
      return { status: 200, body: this.qrStatus(q) };
    }
    if (method === 'POST' && (m = /^\/pos\/v1\/payments\/([0-9a-f-]{36})\/qr\/cancel$/.exec(path))) {
      const q = this.qr.get(m[1]);
      if (!q) return this.error('payments-status.404');
      if (q.status === 'paid') return { status: 200, body: this.fixtureBody('payments-qr-cancel.200.paid') };
      q.status = 'cancelled';
      return { status: 200, body: { externalId: q.externalId, status: 'cancelled' } };
    }
    return { status: 404, body: { code: 'POS_E_NOT_FOUND', message: 'метод не эмулируется', requestId: randomUUID() } };
  }

  /** Методы режима кассира (по состоянию синтетики); `null` — метод не относится к режиму кассира. */
  private cashierRoute(
    st: FakeCashierState,
    method: string,
    path: string,
    body: Json,
    query: URLSearchParams,
  ): FakeResponse | null {
    const { cashier, exchange } = st;
    let m: RegExpExecArray | null;
    try {
      if (method === 'GET' && path === '/pos/v1/changes') {
        const limit = query.get('limit');
        const cursor = query.get('cursor');
        const page = exchange.getChanges({
          since: Number(query.get('since') ?? '0'),
          ...(limit ? { limit: Number(limit) } : {}),
          ...(cursor ? { cursor } : {}),
        });
        return { status: 200, body: page as unknown as Json };
      }
      if (method === 'POST' && path === '/pos/v1/changes/ack') {
        return { status: 200, body: exchange.ack(Number(body.messageNumber)) as unknown as Json };
      }
      if (method === 'POST' && path === '/pos/v1/changes/reregister') {
        exchange.registerAll();
        return { status: 202 };
      }
      if (method === 'GET' && path === '/pos/v1/customers') {
        return { status: 200, body: cashier.findByPhone(query.get('phone') ?? '') as unknown as Json };
      }
      if (method === 'POST' && path === '/pos/v1/customers') {
        const r = cashier.createCustomer(body as never);
        return { status: r.status, body: r.body };
      }
      if (method === 'GET' && (m = /^\/pos\/v1\/customers\/([0-9a-f-]{36})\/receivables$/.exec(path))) {
        return { status: 200, body: cashier.getReceivables(m[1]) };
      }
      if (method === 'POST' && path === '/pos/v1/returns') {
        const r = cashier.createReturnRequest(body as never);
        return { status: r.status, body: r.body };
      }
      if (method === 'GET' && (m = /^\/pos\/v1\/returns\/([0-9a-f-]{36})\/status$/.exec(path))) {
        return { status: 200, body: cashier.getReturnRequestStatus(m[1]) };
      }
    } catch (e) {
      if (e instanceof SyntheticOnecRejection || e instanceof OnecError) {
        return {
          status: e.status,
          body: {
            code: e.code,
            message: e.message,
            ...(e.details !== undefined ? { details: e.details as Json } : {}),
            requestId: randomUUID(),
          },
        };
      }
      throw e;
    }
    return null;
  }

  private cashierControl(st: FakeCashierState, method: string, path: string, body: Json): FakeResponse | null {
    const { cashier } = st;
    let m: RegExpExecArray | null;
    if (method === 'GET' && path === '/__fake/cashier/state') {
      const scenarios: Json = {};
      for (const k of Object.keys(CASHIER_SCENARIOS) as (keyof typeof CASHIER_SCENARIOS)[]) {
        const ref = CASHIER_SCENARIOS[k];
        scenarios[k] = { ref, phone: CASHIER_SCENARIO_PHONES[k], name: cashier.partner(ref)?.name ?? null };
      }
      return {
        status: 200,
        body: {
          note: 'тестовые данные — синтетика кассира фейка 1С, не реальная интеграция',
          historyFrom: cashier.historyFrom(),
          scenarios,
          customers: cashier.allPartners().length,
          lastAck: st.exchange.lastAck,
          backlog: st.exchange.backlog,
        },
      };
    }
    if (method === 'POST' && (m = /^\/__fake\/cashier\/returns\/([0-9a-f-]{36})\/status$/.exec(path))) {
      const status = str(body.status);
      if (!['submitted', 'accepted', 'rejected', 'completed'].includes(status)) {
        return { status: 400, body: { error: 'status' } };
      }
      if (!cashier.returnRequest(m[1])) return { status: 404, body: { error: 'return request' } };
      cashier.setReturnStatus(m[1], status as 'submitted' | 'accepted' | 'rejected' | 'completed');
      return { status: 200, body: cashier.getReturnRequestStatus(m[1]) };
    }
    if (method === 'POST' && (m = /^\/__fake\/cashier\/customers\/([0-9a-f-]{36})$/.exec(path))) {
      if (!cashier.partner(m[1])) return { status: 404, body: { error: 'customer' } };
      const patch: Record<string, unknown> = {};
      for (const k of ['creditLimit', 'creditAllowed', 'creditDays', 'discountPercent'] as const) {
        if (body[k] !== undefined) patch[k] = body[k];
      }
      const p = cashier.updatePartner(m[1], patch);
      return { status: 200, body: { ref: p.ref, creditLimit: p.creditLimit, creditAllowed: p.creditAllowed } };
    }
    return null;
  }

  private createOrder(body: Json): FakeResponse {
    const externalId = str(body.externalId);
    if (!/^[0-9a-f-]{36}$/.test(externalId)) return this.error('orders-create.422');
    const existing = this.orders.get(externalId);
    if (existing) {
      existing.createCalls += 1;
      return { status: 200, body: this.orderCreated(existing) };
    }
    const mode = this.orderMode;
    if (mode !== 'accept' && this.failNext > 0) {
      this.failNext -= 1;
      if (this.failNext === 0) this.orderMode = 'accept';
    }
    if (mode === 'unavailable') return this.error('error.503.maintenance');
    if (mode === 'reject') return this.error('orders-create.422');
    this.orderSeq += 1;
    const totals = (body.totals ?? {}) as Json;
    const o: FakeOrder = {
      externalId,
      ref: randomUUID(),
      number: `ОС00-${String(this.orderSeq).padStart(6, '0')}`,
      date: onecTime(),
      status: 'НеСогласован',
      approved: false,
      total: typeof totals.total === 'string' ? totals.total : '0.00',
      createdAt: new Date().toISOString(),
      createCalls: 1,
    };
    this.orders.set(externalId, o);
    return { status: 201, body: this.orderCreated(o) };
  }

  private orderCreated(o: FakeOrder): Json {
    const tpl = this.fixtureBody('orders-create.201');
    return {
      ...tpl,
      externalId: o.externalId,
      ref: o.ref,
      number: o.number,
      date: o.date,
      status: o.status,
      approved: o.approved,
      totals: { ...(tpl.totals as Json), total: o.total, discount: '0.00', subtotal: o.total },
    };
  }

  private orderStatus(o: FakeOrder): Json {
    return {
      externalId: o.externalId,
      ref: o.ref,
      number: o.number,
      date: o.date,
      status: o.status,
      approved: o.approved,
      fulfillmentState: o.approved ? 'ГотовКОтгрузке' : 'НеГотов',
      deletionMark: false,
      total: o.total,
      shipments: [],
    };
  }

  private createQr(body: Json): FakeResponse {
    const externalId = str(body.externalId);
    const amount = typeof body.amount === 'string' ? body.amount : '';
    if (!/^[0-9a-f-]{36}$/.test(externalId) || !/^\d+\.\d{2}$/.test(amount)) return this.error('orders-create.422');
    const existing = this.qr.get(externalId);
    if (existing && existing.status === 'pending') return { status: 200, body: this.qrCreated(existing) };
    const ttl = Number(body.requestedTtlSeconds ?? 900);
    const now = new Date();
    const q: FakeQr = {
      externalId,
      orderExternalId: typeof body.orderExternalId === 'string' ? body.orderExternalId : null,
      reference: `QR-${randomUUID().slice(0, 8).toUpperCase()}`,
      amount,
      createdAt: onecTime(now),
      expiresAt: new Date(now.getTime() + Math.max(60, ttl) * 1000).toISOString(),
      status: 'pending',
      polls: 0,
      paidAmount: null,
      paidAt: null,
      bankReference: `BK-${Date.now()}`,
    };
    this.qr.set(externalId, q);
    return { status: 201, body: this.qrCreated(q) };
  }

  private qrCreated(q: FakeQr): Json {
    return {
      externalId: q.externalId,
      status: 'pending',
      qrPayload: `TEST-QR-PAYLOAD-${q.externalId.slice(0, 8)}`,
      reference: q.reference,
      amount: q.amount,
      createdAt: q.createdAt,
      expiresAt: q.expiresAt,
    };
  }

  private pay(q: FakeQr, amount?: string): void {
    q.status = 'paid';
    q.paidAmount = amount ?? q.amount;
    q.paidAt = onecTime();
  }

  private qrStatus(q: FakeQr): Json {
    return {
      externalId: q.externalId,
      status: q.status,
      reference: q.reference,
      amount: q.amount,
      paidAmount: q.paidAmount,
      paidAt: q.paidAt,
      bankReference: q.status === 'paid' ? q.bankReference : null,
      expiresAt: q.expiresAt,
      documentRef: null,
      documentType: null,
    };
  }

  private control(method: string, path: string, body: Json): FakeResponse {
    let m: RegExpExecArray | null;
    if (this.cashierState && path.startsWith('/__fake/cashier/')) {
      const r = this.cashierControl(this.cashierState, method, path, body);
      if (r) return r;
    }
    if (method === 'GET' && path === '/__fake/state') return { status: 200, body: this.state() };
    if (method === 'POST' && path === '/__fake/reset') {
      this.reset();
      return { status: 200, body: this.state() };
    }
    if (method === 'POST' && path === '/__fake/down') {
      this.down = body.down === true;
      return { status: 200, body: { down: this.down } };
    }
    if (method === 'POST' && path === '/__fake/orders/mode') {
      const mode = str(body.mode);
      if (!['accept', 'unavailable', 'reject'].includes(mode)) return { status: 400, body: { error: 'mode' } };
      this.orderMode = mode as OrderMode;
      this.failNext = mode === 'accept' ? 0 : Math.max(0, Number(body.failNext ?? 0));
      return { status: 200, body: { orderMode: this.orderMode, failNext: this.failNext } };
    }
    if (method === 'POST' && (m = /^\/__fake\/orders\/([0-9a-f-]{36})\/status$/.exec(path))) {
      const o = this.orders.get(m[1]);
      if (!o) return { status: 404, body: { error: 'order' } };
      o.status = str(body.status) || o.status;
      o.approved = body.approved === undefined ? o.status === 'КВыполнению' : body.approved === true;
      return { status: 200, body: this.orderStatus(o) };
    }
    if (method === 'POST' && path === '/__fake/qr/config') {
      this.paidAfterPolls = Math.max(0, Number(body.paidAfterPolls ?? this.paidAfterPolls));
      return { status: 200, body: { paidAfterPolls: this.paidAfterPolls } };
    }
    if (method === 'POST' && (m = /^\/__fake\/qr\/([0-9a-f-]{36})\/pay$/.exec(path))) {
      const q = this.qr.get(m[1]);
      if (!q) return { status: 404, body: { error: 'qr' } };
      this.pay(q, typeof body.amount === 'string' ? body.amount : undefined);
      return { status: 200, body: this.qrStatus(q) };
    }
    return { status: 404, body: { error: 'control route' } };
  }

  /** HTTP-сервер фейка; `prefix` — публикация HS (`/ut11/hs`). */
  listen(port: number, prefix: string): Promise<http.Server> {
    const server = http.createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on('data', (c: Buffer) => chunks.push(c));
      req.on('end', () => {
        const url = new URL(req.url ?? '/', 'http://x');
        const path = url.pathname.startsWith(prefix) ? url.pathname.slice(prefix.length) : url.pathname;
        let body: Json = {};
        try {
          const text = Buffer.concat(chunks).toString('utf8');
          if (text) body = JSON.parse(text) as Json;
        } catch {
          body = {};
        }
        let r: FakeResponse;
        if (path.startsWith('/pos/v1/') && !req.headers['x-pos-client-key']) {
          r = this.error('error.401');
        } else {
          try {
            r = this.handle(req.method ?? 'GET', decodeURIComponent(path), body, url.searchParams);
          } catch (e) {
            r = { status: 500, body: { code: 'POS_E_INTERNAL', message: String(e), requestId: randomUUID() } };
          }
        }
        if (!path.startsWith('/__fake/')) {
          this.calls.push({ at: new Date().toISOString(), method: req.method ?? 'GET', path, status: r.status });
          if (this.calls.length > 2000) this.calls.splice(0, 1000);
        }
        const headers: Record<string, string> = { 'X-POS-API-Version': '1' };
        const rid = req.headers['x-request-id'];
        if (typeof rid === 'string') headers['X-Request-Id'] = rid;
        if (r.body !== undefined) headers['Content-Type'] = 'application/json; charset=utf-8';
        res.writeHead(r.status, headers);
        res.end(r.body === undefined ? undefined : JSON.stringify(r.body));
      });
    });
    return new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(port, '127.0.0.1', () => resolve(server));
    });
  }
}

async function main(): Promise<void> {
  const env = process.env['APP_ENV'];
  if (env !== 'dev' && env !== 'test') {
    process.stderr.write('pos_fake_onec: только APP_ENV=dev|test (управляющие вызовы фейка 1С — dev-only)\n');
    process.exit(2);
  }
  const { values } = parseArgs({
    options: {
      port: { type: 'string', default: '0' },
      prefix: { type: 'string', default: '/ut11/hs' },
      'ready-file': { type: 'string' },
      'qr-paid-after-polls': { type: 'string', default: '2' },
      cashier: { type: 'boolean', default: false },
      'catalog-sku': { type: 'string', default: '0' },
      'cashier-extra': { type: 'string', default: '20' },
    },
  });
  const cashierState = values.cashier
    ? createCashierState({
        catalogSku: Number(values['catalog-sku']),
        extraCustomers: Number(values['cashier-extra']),
      })
    : null;
  const fake = new PosFakeOnec(Number(values['qr-paid-after-polls']), cashierState);
  const server = await fake.listen(Number(values.port), values.prefix);
  const port = (server.address() as AddressInfo).port;
  const line = `http://127.0.0.1:${port}`;
  if (values['ready-file']) writeFileSync(values['ready-file'], `${line}\n`);
  const mode = cashierState ? ' [режим кассира]' : '';
  process.stdout.write(
    `pos_fake_onec READY ${line}${values.prefix}${mode} (тестовые данные, не реальная интеграция)\n`,
  );
  const stop = (): void => {
    server.closeAllConnections();
    server.close(() => process.exit(0));
  };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
  process.stdin.on('end', stop);
  process.stdin.resume();
}

if (process.argv[1] && /pos_fake_onec\.ts$/.test(process.argv[1])) await main();
