import { readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import YAML from 'yaml';
import { customerTypeEnum } from '../../src/db/schema/enums.js';
import { ODATA_ALLOWLIST } from '../../src/integrations/onec/odata-allowlist.js';
import { ONEC_HS_DEFAULTS, OnecExtensionGateway } from '../../src/integrations/onec/onec-extension.gateway.js';
import { ONEC_OPERATIONS, type OnecOperationId } from '../../src/integrations/onec/onec-gateway.js';
import type { OnecHttpRequest, OnecHttpTransport } from '../../src/integrations/onec/onec-http-transport.js';
import { SyntheticCashier } from '../../src/integrations/onec/synthetic-cashier.js';
import { isValidEan13 } from '../../src/integrations/onec/synthetic-catalog.js';
import { buildOnecOrderPayload, type OnecOrderPayloadInput } from '../../src/orders/onec-order-payload.js';
import { MAX_SOURCE_BYTES } from '../../src/sync/images/image-processor.js';
import { IMAGE_EXTENSIONS } from '../../src/sync/images/image-sources.js';
import { receivableDocKind } from '../../src/sync/receivables/onec-receivables.parser.js';
import { contractErrors } from '../cashier-foundation/support/onec-contract.js';

/**
 * Контракт 1С 1.1.0 ↔ ТЗ для программиста 1С ↔ реализация POS (разбор docs/integration/onec_api/98_triage.md, пункты
 * CONTRACT). Каждый блок падал на контракте/фикстурах 1.0.0. Без БД и сети; **тестовые данные**.
 */
const ROOT = new URL('../../../contracts/onec/', import.meta.url);
const CONTRACT = fileURLToPath(new URL('onec-http-service.v1.yaml', ROOT));
const ALLOWLIST = fileURLToPath(new URL('odata-allowlist.yaml', ROOT));
const FIXTURES = fileURLToPath(new URL('fixtures/', ROOT));

type Obj = Record<string, unknown>;
const doc = YAML.parse(readFileSync(CONTRACT, 'utf8')) as {
  info: Obj;
  paths: Record<string, Record<string, Obj>>;
  components: { schemas: Record<string, Obj> };
};
const schemas = doc.components.schemas;
const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';

function op(id: OnecOperationId): Obj {
  const [method, path] = ONEC_OPERATIONS[id].split(' ');
  const o = doc.paths[path]?.[method.toLowerCase()];
  if (!o || o.operationId !== id) throw new Error(`нет операции ${id} в контракте`);
  return o;
}

function prop(schema: string, name: string): Obj {
  return (schemas[schema].properties as Record<string, Obj>)[name];
}

interface Fixture {
  readonly file: string;
  readonly operation: string;
  readonly kind: 'request' | 'response';
  readonly status?: number;
  readonly body: unknown;
}
const fixtures: Fixture[] = readdirSync(FIXTURES)
  .filter((f) => f.endsWith('.json'))
  .map((f) => ({ file: f, ...(JSON.parse(readFileSync(`${FIXTURES}${f}`, 'utf8')) as Omit<Fixture, 'file'>) }));
const fixture = (file: string): Fixture => {
  const f = fixtures.find((x) => x.file === `${file}.json`);
  if (!f) throw new Error(`нет фикстуры ${file}`);
  return f;
};

/** Поля значения, не описанные в схеме контракта (строгая проверка поверх `contractErrors`). */
function undeclared(schema: Obj, value: unknown, path: string, out: string[]): string[] {
  const resolve = (s: Obj): Obj => (typeof s.$ref === 'string' ? resolve(schemas[s.$ref.split('/').pop()!]) : s);
  const s = resolve(schema);
  if (value === null || typeof value !== 'object') return out;
  if (Array.isArray(value)) {
    if (s.items) value.forEach((v, i) => undeclared(s.items as Obj, v, `${path}[${i}]`, out));
    return out;
  }
  const v = value as Obj;
  const disc = s.discriminator as { propertyName: string; mapping: Record<string, string> } | undefined;
  if (disc) return undeclared({ $ref: disc.mapping[String(v[disc.propertyName])] }, v, path, out);
  const props: Record<string, Obj> = { ...((s.properties as Record<string, Obj>) ?? {}) };
  for (const part of (s.allOf as Obj[] | undefined) ?? []) Object.assign(props, resolve(part).properties ?? {});
  if (Object.keys(props).length === 0) return out;
  for (const [k, x] of Object.entries(v)) {
    if (!(k in props)) out.push(`${path}.${k}`);
    else undeclared(props[k], x, `${path}.${k}`, out);
  }
  return out;
}

/** Транзакция-заглушка для `buildOnecOrderPayload`: ответы на SELECT по порядку вызовов. */
function fakeTx(...answers: Obj[][]): never {
  let i = 0;
  return { execute: () => Promise.resolve({ rows: answers[i++] ?? [] }) } as never;
}

const ORDER_ID = '0192f5a0-7c2e-7d3b-9a1f-3c4d5e6f7a90';
const USER_ID = '0192f5a0-0000-7000-8000-0000000000bb';
const VARIANT_ID = '0192f5a0-1111-7000-8000-000000000001';
const PACK_ID = '0192f5a0-2222-7000-8000-000000000001';

function orderInput(over: Partial<OnecOrderPayloadInput> = {}): OnecOrderPayloadInput {
  return {
    orderId: ORDER_ID,
    publicNumber: 'POS-2026-000124',
    createdAt: new Date('2026-10-21T07:39:12Z'),
    createdByUserId: USER_ID,
    createdVia: 'customer',
    customerId: '0192f5a0-3333-7000-8000-000000000001',
    paymentMethod: 'cash',
    snapshot: {
      warehouseId: '0192f5a0-4444-7000-8000-000000000001',
      priceListId: '0192f5a0-5555-7000-8000-000000000001',
      manualDiscountPercent: '0.00',
      subtotal: '14100.00',
      discountTotal: '0.00',
      total: '14100.00',
      lines: [
        {
          lineNo: 1,
          variantId: VARIANT_ID,
          packagingId: PACK_ID,
          baseQuantity: '6',
          quantity: '1',
          unitPrice: '2350.00',
          lineTotal: '14100.00',
        },
      ],
    } as never,
    delivery: {
      method: 'pickup',
      address: null,
      receiverName: null,
      receiverPhone: null,
      desiredDate: null,
      timeFrom: null,
      timeTo: null,
      courierComment: null,
    },
    comment: 'Позвонить перед выдачей',
    ...over,
  };
}

async function retailPayload(over: Partial<OnecOrderPayloadInput> = {}): Promise<Obj> {
  return buildOnecOrderPayload(
    fakeTx(
      [
        {
          customer_ref: null, // «Розничный покупатель»: customers.onec_ref IS NULL (Q-026)
          contractor_ref: null,
          agreement_ref: null,
          warehouse_ref: 'd4e5f6a7-0000-4000-8000-000000000001',
          price_list_ref: 'e5f6a7b8-0000-4000-8000-000000000001',
        },
      ],
      [
        {
          variant_id: VARIANT_ID,
          variant_ref: 'a1b2c3d4-0000-4000-8000-000000000101',
          product_ref: 'a1b2c3d4-0000-4000-8000-000000000001',
        },
      ],
      [{ id: PACK_ID, onec_ref: 'a1b2c3d4-0000-4000-8000-000000000201' }],
    ),
    orderInput(over),
  );
}

describe('Контракт 1С 1.1.0: заказ (ТЗ для 1С §6.6; пп. 1–3, 5, 57 разбора)', () => {
  const commentRe = new RegExp(prop('OrderCreateRequest', 'comment')['x-comment-pattern'] as string);

  it('п. 1: тело заказа «Розничного покупателя» из кода (customer.ref = null) проходит схему OrderCreateRequest', async () => {
    const body = await retailPayload();
    expect((body.customer as Obj).ref).toBeNull();
    expect(contractErrors('OrderCreateRequest', body)).toEqual([]);
    expect(undeclared({ $ref: '#/components/schemas/OrderCreateRequest' }, body, 'order', [])).toEqual([]);
  });

  it('п. 1: фикстура orders-create.request.retail — customer.ref = null по схеме контракта', () => {
    const f = fixture('orders-create.request.retail');
    expect(f).toMatchObject({ operation: 'POST /pos/v1/orders', kind: 'request' });
    const body = f.body as Obj;
    expect(body.customer).toEqual({ ref: null, contractorRef: null, agreementRef: null });
    expect(contractErrors('OrderCreateRequest', body)).toEqual([]);
  });

  it('п. 2: createdByUserCode — UUID пользователя POS (код и фикстура), не логин', async () => {
    const re = new RegExp(prop('OrderCreateRequest', 'createdByUserCode').pattern as string);
    expect((await retailPayload()).createdByUserCode).toMatch(re);
    for (const f of fixtures.filter((x) => x.operation === 'POST /pos/v1/orders' && x.kind === 'request')) {
      expect((f.body as Obj).createdByUserCode, f.file).toMatch(re);
    }
    expect('seller-abdulla').not.toMatch(re);
  });

  it('п. 3: comment — «POS <полный uuid> · <номер POS>[ · заявка клиента][ · комментарий]», ≤ maxLength', async () => {
    const max = prop('OrderCreateRequest', 'comment').maxLength as number;
    expect(max).toBe(1000);
    const customer = (await retailPayload()).comment as string;
    expect(customer).toBe(`POS ${ORDER_ID} · POS-2026-000124 · заявка клиента · Позвонить перед выдачей`);
    const staff = (await retailPayload({ createdVia: 'staff', comment: null })).comment as string;
    const long = (await retailPayload({ comment: 'х'.repeat(2000) })).comment as string;
    for (const c of [customer, staff, long]) {
      expect(c).toMatch(commentRe);
      expect(c.length).toBeLessThanOrEqual(max);
    }
    for (const f of fixtures.filter((x) => x.operation === 'POST /pos/v1/orders' && x.kind === 'request')) {
      expect((f.body as Obj).comment, f.file).toMatch(commentRe);
    }
    expect('POS 0192f5a0 · продавец Абдулла').not.toMatch(commentRe);
  });

  it('п. 5, 57: discountPercent строки — ручная скидка заказа, quantity — в базовой единице, packQuantity — в упаковках', async () => {
    const body = await retailPayload({ snapshot: { ...orderInput().snapshot, manualDiscountPercent: '5.00' } });
    const line = (body.lines as Obj[])[0];
    expect(line).toMatchObject({
      discountPercent: '5.00',
      quantity: '6.000',
      packQuantity: '1.000',
      amount: '14100.00',
    });
    expect(body.discountPercent).toBe('5.00');
    expect(body.organizationRef).toBeNull();
    expect(body.clientChecks).toEqual({ pricesSnapshotAt: null, stockSnapshotAt: null });
    for (const k of ['discountPercent', 'amount', 'quantity', 'packQuantity'])
      expect(prop('OrderLine', k).description, k).toBeTruthy();
    expect(prop('OrderCreateRequest', 'organizationRef').description).toMatch(/null/);
    expect(prop('OrderCreateRequest', 'clientChecks').description).toMatch(/null/);
  });
});

describe('Контракт 1С 1.1.0: операции, таймауты, повторы (ТЗ для 1С §4.7, §4.9, §6.9, §6.20)', () => {
  it('п. 7, 46: x-timeout-ms каждой операции = таймаут OnecExtensionGateway (POST /orders — 6 с)', async () => {
    const seen = new Map<string, number>();
    const transport: OnecHttpTransport = {
      request(req: OnecHttpRequest) {
        const path = new URL(req.url).pathname.replace(/^\/hs/, '');
        const key = `${req.method} ${path}`;
        if (!seen.has(key)) seen.set(key, req.timeoutMs);
        const body = JSON.stringify({ code: 'POS_E_BAD_REQUEST', message: 'тест', requestId: USER_ID });
        return Promise.resolve({
          status: 400,
          headers: { 'content-type': 'application/json' },
          body: Buffer.from(body),
        });
      },
    };
    const gw = new OnecExtensionGateway({ baseUrl: 'https://host-1c', hsPath: 'hs' }, transport, () =>
      Promise.resolve(),
    );
    const id = '0192f5a0-7c2e-7d3b-9a1f-3c4d5e6f7a8b';
    const calls: Record<OnecOperationId, () => Promise<unknown>> = {
      getHealth: () => gw.getHealth(),
      getChanges: () => gw.getChanges({ since: 1 }),
      ackChanges: () => gw.ackChanges(2),
      reregisterChanges: () => gw.reregisterChanges(),
      createOrder: () => gw.createOrder({ externalId: id }),
      getOrderStatus: () => gw.getOrderStatus(id),
      getOrderStatusBatch: () => gw.getOrderStatusBatch([id]),
      cancelOrder: () => gw.cancelOrder(id, { reason: 'тест' }),
      createPayment: () => gw.createPayment({ externalId: id }),
      createQrPayment: () => gw.createQrPayment({ externalId: id } as never),
      getQrPaymentStatus: () => gw.getQrPaymentStatus(id),
      cancelQrPayment: () => gw.cancelQrPayment(id, 'reissue'),
      findCustomersByPhone: () => gw.findCustomersByPhone('+996700000001'),
      createCustomer: () => gw.createCustomer({ externalId: id }),
      getCustomerReceivables: () => gw.getCustomerReceivables(id),
      createReturnRequest: () => gw.createReturnRequest({ externalId: id }),
      getReturnRequestStatus: () => gw.getReturnRequestStatus(id),
      getImage: () => gw.getImage(id),
      checkCart: () => gw.checkCart({ lines: [] }),
      getCatalogCard: () => gw.getCatalogCard(id),
      listExternalIds: () => gw.listExternalIds({ type: 'Заказ', limit: 500 }),
    };
    for (const [name, call] of Object.entries(calls) as [OnecOperationId, () => Promise<unknown>][]) {
      await call().catch(() => undefined);
      const [method, template] = ONEC_OPERATIONS[name].split(' ');
      const re = new RegExp(`^${method} ${template.replace(/\{[^}]+\}/g, '[^/]+')}$`);
      const actual = [...seen.entries()].find(([k]) => re.test(k))?.[1];
      expect(actual, name).toBeDefined();
      expect(op(name)['x-timeout-ms'], name).toBe(actual);
    }
    expect(op('createOrder')['x-timeout-ms']).toBe(6_000);
  });

  it('п. 39: x-get-retry в info = повтор GET HTTP-клиентом (3 попытки, паузы 0,5 и 1 с)', () => {
    const r = doc.info['x-get-retry'] as { maxAttempts: number; delaysMs: number[] };
    const { maxAttempts, baseDelayMs } = ONEC_HS_DEFAULTS.retry;
    expect(r.maxAttempts).toBe(maxAttempts);
    expect(r.delaysMs).toEqual(Array.from({ length: maxAttempts - 1 }, (_, i) => baseDelayMs * 2 ** i));
  });

  it('п. 6, 27: GET /external-ids — since необязателен (ручная привязка вызывает метод без since), порядок описан', () => {
    const since = (op('listExternalIds').parameters as Obj[]).find((p) => p.name === 'since')!;
    expect(since.required).toBe(false);
    expect(since['x-status']).toBe('proposed');
    expect(op('listExternalIds').description).toMatch(/\*\*убыванию\*\* `ДатаСоздания`, затем\s+по `ВнешнийИд`/);
    const proposed = op('listExternalIds')['x-proposed-operations'] as Obj[];
    expect(proposed.map((p) => `${String(p.method)} ${String(p.path)}`)).toContain('GET /pos/v1/orders?number={номер}');
  });

  it('п. 53: у POST /orders/status нет ответа 404 и кода POS_E_NOT_FOUND; у одиночного статуса 404 остаётся', () => {
    expect(Object.keys(op('getOrderStatusBatch').responses as Obj)).not.toContain('404');
    expect(op('getOrderStatusBatch')['x-error-codes']).not.toContain('POS_E_NOT_FOUND');
    expect(Object.keys(op('getOrderStatus').responses as Obj)).toContain('404');
  });

  it('п. 10, 11, 30, 72, 73: x-retry без несуществующих в коде переходов и с правилами ТЗ', () => {
    expect(op('getQrPaymentStatus')['x-retry']).not.toMatch(/no_webhook/);
    expect(op('getQrPaymentStatus')['x-retry']).toMatch(/qr_expired/);
    expect(op('getQrPaymentStatus')['x-retry']).toMatch(/late_payment/);
    expect(op('cancelQrPayment')['x-retry']).toMatch(/reissue\) — одна синхронная попытка до 6 с/);
    expect(op('getCatalogCard')['x-retry']).toMatch(/не вызывает/);
    expect(op('createReturnRequest')['x-retry']).toMatch(/404 расширение не возвращает/);
    expect(op('createPayment')['x-retry']).toMatch(/404 расширение не возвращает/);
    expect(op('createPayment').description).toMatch(/Заказ-основание не найден — 422 `POS_E_VALIDATION`/);
    expect(op('getHealth')['x-access']).not.toMatch(/401 без тела$/);
  });
});

describe('Контракт 1С 1.1.0: поля-предложения, которые POS читает (ТЗ для 1С §5.4–§5.7, §6.10–§6.12)', () => {
  const NOW = new Date('2026-10-21T08:00:00Z');
  const c = new SyntheticCashier({ now: () => NOW, asOf: '2026-10-21' });

  it('пп. 17, 18, 29: элементы /changes фейка кассира (kind, discountPercent, параметры скидок) описаны в контракте', () => {
    const extra = c
      .allItems()
      .flatMap((it) => undeclared({ $ref: '#/components/schemas/ChangeItem' }, it, it.type as string, []));
    expect([...new Set(extra)]).toEqual([]);
    for (const it of c.allItems()) expect(contractErrors('ChangeItem', it)).toEqual([]);
    expect(prop('CounterpartyChange', 'kind')['x-status']).toBe('proposed');
    expect(prop('AgreementChange', 'discountPercent')['x-status']).toBe('proposed');
    for (const k of ['kind', 'value', 'isActive', 'appliesAutomatically', 'validFrom', 'validTo', 'conditions'])
      expect(prop('DiscountChange', k)['x-status'], k).toBe('proposed');
  });

  it('пп. 17, 55: вид клиента — enum CustomerKind = канон customer_type; kind в контрагенте и кандидате поиска', () => {
    expect(schemas.CustomerKind.enum).toEqual([...customerTypeEnum.enumValues]);
    expect(
      contractErrors('CustomerCreateRequest', { ...(fixture('customers-create.request').body as Obj), kind: 'x' }),
    ).not.toEqual([]);
    expect(
      contractErrors('CustomerCandidate', { ...(fixture('customers-search.200').body as Obj[])[0], kind: 'legal' }),
    ).toEqual([]);
    expect(
      contractErrors('CustomerCandidate', { ...(fixture('customers-search.200').body as Obj[])[0], kind: 'x' }),
    ).not.toEqual([]);
  });

  it('п. 20, 79: ReturnDocumentChange.returnRequestExternalId — предложение; строки возврата описаны', () => {
    const p = prop('ReturnDocumentChange', 'returnRequestExternalId');
    expect(p).toMatchObject({ nullable: true, 'x-status': 'proposed' });
    expect(prop('ReturnDocumentChange', 'lines').description).toMatch(/номер строки самого документа возврата/);
    expect(prop('ReturnCreateRequest', 'shipmentRef').description).toMatch(/последнюю проведённую/);
  });

  it('п. 19, 50, 52: вид строки долга в контракте = receivableDocKind() парсера', () => {
    const map = prop('ReceivableDocument', 'documentType')['x-pos-kind-by-type'] as Record<string, string>;
    for (const [type, kind] of Object.entries(map)) {
      const sample =
        type === '*Скидк*' ? 'Document_СкидкиКлиенту' : type === '*' ? 'Document_КорректировкаДолга' : type;
      expect(receivableDocKind(sample), type).toBe(kind);
    }
    expect((schemas.CustomerReceivables['x-pos-rejects'] as string[]).length).toBeGreaterThanOrEqual(6);
  });

  it('пп. 32–34, 16: ограничения POS R1 описаны и совпадают с кодом (картинки, ИНН, валюта)', () => {
    const images = op('getImage');
    expect(images['x-pos-image-extensions']).toEqual([...IMAGE_EXTENSIONS]);
    expect(images['x-pos-max-source-bytes']).toBe(MAX_SOURCE_BYTES);
    expect(prop('CounterpartyChange', 'taxId')['x-pos-accepted-pattern']).toBe('^\\d{14}$');
    expect(prop('PriceListChange', 'currency')['x-pos-accepted-values']).toEqual(['KGS']);
    expect(prop('VariantChange', 'ownerType')['x-pos-accepted-values']).toEqual(['Catalog_Номенклатура']);
    expect(prop('PackagingChange', 'unitRef')['x-pos-required']).toBe(true);
  });

  it('п. 16: allow-list — Catalog_Валюты и $orderby=Ref_Key как предложения, вне рабочего ODATA_ALLOWLIST', () => {
    const y = YAML.parse(readFileSync(ALLOWLIST, 'utf8')) as {
      proposedAdditions: { collections: Obj[]; queryOptions: Obj[] };
    };
    expect(y.proposedAdditions.collections).toEqual([
      expect.objectContaining({ name: 'Catalog_Валюты', 'x-status': 'proposed', access: 'read' }),
    ]);
    expect(y.proposedAdditions.queryOptions).toEqual([
      expect.objectContaining({ option: '$orderby', value: 'Ref_Key', 'x-status': 'proposed' }),
    ]);
    expect(ODATA_ALLOWLIST.some((x) => x.name === 'Catalog_Валюты')).toBe(false);
  });

  it('п. 48: PRICE_CHANGED необязателен для 1С (цену сравнивает POS)', () => {
    expect(schemas.IssueCode['x-optional-for-onec']).toEqual(['PRICE_CHANGED']);
  });
});

describe('Фикстуры contracts/onec/fixtures 1.1.0 (пп. 2, 12, 13, 43, 60, 63, 92)', () => {
  it('п. 12: действующие QR (201/200, статус pending/paid) — expiresAt в будущем; expired — в прошлом', () => {
    const qr = [
      fixture('payments-qr.201'),
      fixture('payments-qr.200'),
      fixture('payments-status.pending.200'),
      fixture('payments-status.paid.200'),
    ];
    for (const f of qr) expect(Date.parse((f.body as Obj).expiresAt as string), f.file).toBeGreaterThan(Date.now());
    const expired = fixture('payments-status.expired.200').body as Obj;
    expect(Date.parse(expired.expiresAt as string)).toBeLessThan(Date.now());
    expect(prop('QrCreateResponse', 'expiresAt').description).toMatch(/должен быть в будущем/);
  });

  it('п. 13: штрихкоды EAN-13 фикстур — с верной контрольной цифрой (4600000000015)', () => {
    const values: string[] = [];
    for (const f of fixtures) {
      const walk = (v: unknown): void => {
        if (Array.isArray(v)) v.forEach(walk);
        else if (v && typeof v === 'object') {
          const o = v as Obj;
          if (o.type === 'InformationRegister_ШтрихкодыНоменклатуры') values.push(String(o.barcode), String(o.ref));
          Object.values(o).forEach(walk);
        }
      };
      walk(f.body);
    }
    expect(values).toContain('4600000000015');
    for (const b of values.filter((x) => /^\d{13}$/.test(x))) expect(isValidEan13(b), b).toBe(true);
  });

  it('п. 13: склады и виды цен catalog-card.200 описаны элементами changes.catalog.page1', () => {
    const items = (fixture('changes.catalog.page1.200').body as { items: Obj[] }).items;
    const refsOf = (type: string) => new Set(items.filter((i) => i.type === type).map((i) => i.ref));
    const card = fixture('catalog-card.200').body as { prices: Obj[]; stock: Obj[] };
    for (const s of card.stock) expect(refsOf('Catalog_Склады').has(s.warehouseRef), String(s.warehouseRef)).toBe(true);
    for (const p of card.prices)
      expect(refsOf('Catalog_ВидыЦен').has(p.priceListRef), String(p.priceListRef)).toBe(true);
  });

  it('пп. 2, 62, 63: cashierUserCode — UUID или system; purpose — «Оплата заказа <номер POS>»', () => {
    const re = new RegExp((schemas.PosUserCode.pattern as string) ?? '');
    for (const name of ['payments-qr.request', 'payments-create.request']) {
      expect((fixture(name).body as Obj).cashierUserCode, name).toMatch(re);
    }
    expect('system').toMatch(re);
    expect(USER_ID).toMatch(re);
    expect(USER_ID).toMatch(new RegExp(`^${UUID}$`));
    expect('cashier-doston').not.toMatch(re);
    expect((fixture('payments-qr.request').body as Obj).purpose).toMatch(/^Оплата заказа POS-\d{4}-\d{6}$/);
  });

  it('пп. 43, 60, 92: в фикстурах нет правдоподобных ФИО и телефонов — только синтетика ТЗ', () => {
    const pii = /Асанов|Бакыт|Айгуль|Достон|Абдулла|\+996700123456|0700 123 456/;
    for (const f of fixtures) expect(JSON.stringify(f), f.file).not.toMatch(pii);
    expect(JSON.stringify(fixture('customers-search.200').body)).toContain('+996700000001');
  });

  it('все фикстуры-запросы и успешные ответы проходят схему контракта (проверка TS-валидатором)', () => {
    const schemaOf: Record<string, string> = {
      'POST /pos/v1/orders': 'OrderCreateRequest',
      'POST /pos/v1/payments': 'PaymentCreateRequest',
      'POST /pos/v1/payments/qr': 'QrCreateRequest',
      'POST /pos/v1/customers': 'CustomerCreateRequest',
      'POST /pos/v1/returns': 'ReturnCreateRequest',
      'POST /pos/v1/check': 'CheckRequest',
    };
    for (const f of fixtures.filter((x) => x.kind === 'request' && schemaOf[x.operation])) {
      expect(contractErrors(schemaOf[f.operation], f.body), f.file).toEqual([]);
    }
  });
});

describe('Версия контракта', () => {
  it('info.version — 1.1.0 (минорная: изменения аддитивные или ослабляющие, ONEC-033)', () => {
    expect(doc.info.version).toBe('1.1.0');
  });
});
