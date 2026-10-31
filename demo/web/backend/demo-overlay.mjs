// Надстройки веб-демо над имитатором 1С и печатными формами (WP-B3; plan §3.5, §3.7; critic [0], [9]).
//
// Модуль без статических импортов pos-api: классы синтетики передаются параметром (deps), поэтому водяной знак PDF
// подключается и в сборке (vfs/transforms.mjs, Node), и в воркере.
//
// 1. Водяной знак PDF: первым блоком каждого шаблона pos-api/assets/templates/pdf/*.json — строка
//    «ДЕМО · тестовые данные · не фискальный документ» (§3.7). Применяется при сборке vfs.
// 2. createDemoCashierState() — как createCashierState() из scripts/pos_fake_onec.ts (синтетика кассира + план
//    обмена), но с журналом изменений синтетики (создание клиентов из POS, заявки и статусы возвратов, условия
//    клиентов, отгрузки демо): журнал хранится в demo_meta и проигрывается на каждом холодном старте (critic [0]).
//    ФИО и телефоны клиентов уже заменены при сборке (pii-map.json, WP-B1).
// 3. FakeOnecOverlay — обёртка PosFakeOnec.handle():
//    - неплатёжный QR: qrPayload «DEMO-NOT-PAYABLE|…» вместо TEST-QR-PAYLOAD-… (§3.7);
//    - GET /pos/v1/external-ids по состоянию имитатора (заказы, клиенты из POS, документы, «заведённые вручную»
//      после «Отклонить следующий заказ») — ручная привязка заказа к 1С и сверка клиентов (critic [9]);
//    - POST /pos/v1/check: режим замечаний панели (ok | remarks | reject | unavailable, critic [9]);
//    - заказ, отклонённый «1С» (режим reject), заводится «вручную» с новым номером — его номер и вводят в POS для
//      привязки (POST /orders/{id}/onec-link);
//    - учёт изменений (dirty) для сохранения состояния в demo_meta в конце единицы работы;
//    - serialize()/restore()/reconcile(): состояние PosFakeOnec (заказы, QR, orderSeq, messageNumber, режимы,
//      paidAfterPolls), план обмена (регистрации, lastIssued/lastAck) и журнал синтетики переживают перезагрузку;
//      номера 1С и номер сообщения продолжаются от данных PGlite (заказы с onec_number, sync_node_state).

export const WATERMARK_TEXT = 'ДЕМО · тестовые данные · не фискальный документ';
export const NON_PAYABLE_PREFIX = 'DEMO-NOT-PAYABLE';
/** Версия формата состояния имитатора в demo_meta (меняется — состояние не восстанавливается, только сверка). */
export const FAKE_STATE_VERSION = 1;

// ---------------------------------------------------------------- 1. водяной знак PDF
/** Шаблон PDF (текст JSON) → тот же шаблон с первым блоком-водяным знаком. Повторный вызов ничего не меняет. */
export function watermarkTemplate(text) {
  const t = JSON.parse(text);
  if (!Array.isArray(t.blocks)) return text;
  if (t.blocks.some((b) => b && b.type === 'text' && b.text === WATERMARK_TEXT)) return text;
  const narrow = t.paper === 'thermal80' || (t.page && Number(t.page.width) < 300);
  t.blocks.unshift({ type: 'text', text: WATERMARK_TEXT, align: 'center', bold: true, size: narrow ? 6.5 : 8 });
  t.$demoWatermark = 'веб-демо (WP-B3): тестовые данные, не фискальный документ';
  return JSON.stringify(t, null, 2) + '\n';
}

// ---------------------------------------------------------------- 2. синтетика кассира с журналом
const JOURNALED = ['createCustomer', 'createReturnRequest', 'setReturnStatus', 'updatePartner', 'linkShipmentToOrder', 'setReceivables'];

/**
 * Синтетика кассира и план обмена (как createCashierState pos_fake_onec.ts) + журнал изменений.
 * deps: { SyntheticCashier, SyntheticCatalog, FakeExchangePlan, catalogProducts }.
 * Возвращает { cashier, exchange, journal: { ops, muted, skipKeys }, addShipment(s) }.
 */
export function createDemoCashierState(deps, { catalogSku = 0, extraCustomers = 20 } = {}) {
  const { SyntheticCashier, SyntheticCatalog, FakeExchangePlan, catalogProducts } = deps;
  const products = catalogSku > 0 ? catalogProducts(new SyntheticCatalog({ skuCount: catalogSku, seed: 1 })) : [];
  const cashier = new SyntheticCashier({ ...(products.length > 0 ? { products } : {}), extraCustomers });
  const exchange = new FakeExchangePlan(null).addSource(cashier);
  const journal = { ops: [], muted: false, replaying: false, skipKeys: new Set() };
  // Регистрация изменений в плане обмена. Отгрузки демо (POST /__demo/orders/{id}/ship) уже записаны в POS тем же SQL,
  // что local-stack shipOrderForTest, — их реализация в план обмена не идёт (иначе POS перезаписал бы свою строку).
  cashier.subscribe((keys) => {
    if (journal.muted) return;
    const k = keys.filter((x) => !journal.skipKeys.has(x));
    if (k.length) exchange.register(k);
  });
  exchange.registerAll();
  for (const name of JOURNALED) {
    const orig = cashier[name];
    if (typeof orig !== 'function') continue;
    cashier[name] = function journaled(...args) {
      const r = orig.apply(this, args);
      if (!journal.replaying) {
        const created = name === 'createCustomer' || name === 'createReturnRequest' ? r && r.status === 201 : true;
        if (created) journal.ops.push([name, ...JSON.parse(JSON.stringify(args))]);
      }
      return r;
    };
    cashier[name].__orig = orig;
  }
  /** Отгрузка демо: реализация, известная «1С» (для заявок на возврат), без регистрации в плане обмена. */
  const addShipment = (s) => {
    cashier.shipments.set(s.ref, { ...s, lines: s.lines.map((l) => ({ ...l })) });
    journal.skipKeys.add(`Document_РеализацияТоваровУслуг:${s.ref}`);
    if (!journal.replaying) journal.ops.push(['addShipment', JSON.parse(JSON.stringify(s))]);
  };
  return { cashier, exchange, journal, addShipment };
}

// ---------------------------------------------------------------- 3. обёртка PosFakeOnec
const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const ORDER_STATUS_RE = new RegExp(`^/pos/v1/orders/(${UUID})/status$`);
const QR_STATUS_RE = new RegExp(`^/pos/v1/payments/(${UUID})/status$`);
const BISHKEK_OFFSET_MS = 6 * 3600 * 1000;
const onecTime = (d = new Date()) => `${new Date(d.getTime() + BISHKEK_OFFSET_MS).toISOString().slice(0, 19)}+06:00`;
const ONEC_NUMBER_RE = /^ОС00-(\d+)$/;
const rid = () => globalThis.crypto.randomUUID();
const b64 = (s) => (typeof btoa === 'function' ? btoa(s) : Buffer.from(s, 'utf8').toString('base64'));
const unb64 = (s) => (typeof atob === 'function' ? atob(s) : Buffer.from(s, 'base64').toString('utf8'));

/** Режимы ответа POST /pos/v1/check (панель «1С» → «Проверка корзины»). */
export const CHECK_MODES = ['ok', 'remarks', 'reject', 'unavailable'];

export class FakeOnecOverlay {
  /**
   * fake — экземпляр PosFakeOnec (режим кассира); cs — результат createDemoCashierState.
   * onDirty() — состояние изменилось (сохранить в demo_meta в конце единицы работы).
   */
  constructor(fake, cs, { onDirty } = {}) {
    this.fake = fake;
    this.cs = cs;
    this.onDirty = onDirty ?? (() => {});
    this.dirty = false;
    /** Заказы, «заведённые вручную» в 1С после отказа: externalId заказа POS → документ (номер для привязки). */
    this.manualDocs = new Map();
    this.check = { mode: 'ok', remaining: 0 };
    this.stats = { calls: 0, externalIds: 0, checks: {}, manualDocs: 0, restored: null, reconciled: null };
    const orig = fake.handle.bind(fake);
    this.origHandle = orig;
    fake.handle = (method, path, body = {}, query = new URLSearchParams()) => this.handle(method, path, body, query);
  }

  markDirty() {
    this.dirty = true;
    try {
      this.onDirty();
    } catch {
      /* уведомление */
    }
  }

  handle(method, path, body, query) {
    const fake = this.fake;
    this.stats.calls++;
    const mutating = method !== 'GET' || QR_STATUS_RE.test(path) || path === '/pos/v1/changes';
    try {
      if (path.startsWith('/__fake/')) return this.origHandle(method, path, body, query);
      if (fake.down && path.startsWith('/pos/v1/')) return this.origHandle(method, path, body, query);
      if (method === 'GET' && path === '/pos/v1/external-ids') return this.externalIds(query);
      if (method === 'POST' && path === '/pos/v1/check') return this.checkCart(body);
      if (method === 'POST' && path === '/pos/v1/orders') return this.createOrder(body, query);
      if (method === 'POST' && path === '/pos/v1/orders/status') {
        const r = this.origHandle(method, path, body, query);
        const nf = Array.isArray(r.body?.notFound) ? r.body.notFound : [];
        const manual = nf.filter((id) => this.manualDocs.has(id));
        if (manual.length === 0) return r;
        return {
          status: r.status,
          body: { items: [...r.body.items, ...manual.map((id) => this.manualStatus(this.manualDocs.get(id)))], notFound: nf.filter((id) => !this.manualDocs.has(id)) },
        };
      }
      let m;
      if (method === 'GET' && (m = ORDER_STATUS_RE.exec(path)) && !fake.orders.has(m[1]) && this.manualDocs.has(m[1])) {
        return { status: 200, body: this.manualStatus(this.manualDocs.get(m[1])) };
      }
      if (method === 'POST' && path === '/pos/v1/payments/qr') {
        const r = this.origHandle(method, path, body, query);
        if (r.body && typeof r.body.qrPayload === 'string') r.body.qrPayload = nonPayable(r.body.externalId ?? '');
        return r;
      }
      return this.origHandle(method, path, body, query);
    } finally {
      if (mutating) this.markDirty();
    }
  }

  // -------------------------------------------------------------- заказы и «ручные» документы
  createOrder(body, query) {
    const fake = this.fake;
    const willReject = fake.orderMode === 'reject';
    const r = this.origHandle('POST', '/pos/v1/orders', body, query);
    const externalId = typeof body?.externalId === 'string' ? body.externalId : '';
    if (willReject && r.status === 422 && /^[0-9a-f-]{36}$/.test(externalId) && !this.manualDocs.has(externalId)) {
      // Оператор 1С заводит заказ вручную (в демо — сразу): номер следующий, externalId у документа нет.
      fake.orderSeq += 1;
      const totals = body.totals ?? {};
      this.manualDocs.set(externalId, {
        externalId,
        ref: rid(),
        number: `ОС00-${String(fake.orderSeq).padStart(6, '0')}`,
        date: onecTime(),
        status: 'НеСогласован',
        approved: false,
        total: typeof totals.total === 'string' ? totals.total : '0.00',
        createdAt: new Date().toISOString(),
      });
      this.stats.manualDocs++;
    }
    return r;
  }

  manualStatus(d) {
    return {
      externalId: d.externalId,
      ref: d.ref,
      number: d.number,
      date: d.date,
      status: d.status,
      approved: d.approved,
      fulfillmentState: d.approved ? 'ГотовКОтгрузке' : 'НеГотов',
      deletionMark: false,
      total: d.total,
      shipments: [],
    };
  }

  /** Статус документа 1С заказа (панель «Согласовать», «Закрыть»): заказ имитатора или «ручной» документ. */
  setOrderStatus(externalId, status, approved) {
    const o = this.fake.orders.get(externalId) ?? this.manualDocs.get(externalId);
    if (!o) return null;
    o.status = status || o.status;
    o.approved = approved === undefined ? o.status === 'КВыполнению' : approved === true;
    this.markDirty();
    return o;
  }

  // -------------------------------------------------------------- GET /pos/v1/external-ids
  externalIds(query) {
    this.stats.externalIds++;
    const type = query.get('type');
    const since = query.get('since');
    const limit = Math.min(Math.max(1, Number(query.get('limit') ?? 500) || 500), 5000);
    const cursor = query.get('cursor');
    const sinceMs = since ? Date.parse(since) : NaN;
    const items = [];
    if (!type || type === 'Заказ') {
      for (const o of this.fake.orders.values()) items.push({ externalId: o.externalId, objectType: 'Заказ', ref: o.ref, number: o.number, date: o.date, deletionMark: false, _at: o.createdAt });
      for (const d of this.manualDocs.values()) items.push({ objectType: 'Заказ', ref: d.ref, number: d.number, date: d.date, deletionMark: false, _at: d.createdAt });
    }
    if (!type || type === 'Клиент') {
      for (const p of this.cs.cashier.allPartners()) {
        if (!p.externalId) continue;
        items.push({ externalId: p.externalId, objectType: 'Клиент', ref: p.ref, number: p.code, date: null, deletionMark: !!p.deletionMark, _at: null });
      }
    }
    const filtered = items.filter((it) => Number.isNaN(sinceMs) || it._at === null || Date.parse(it._at) >= sinceMs);
    let offset = 0;
    if (cursor) {
      const mm = /^ext:(\d+)$/.exec(unb64(cursor));
      if (!mm) return { status: 400, body: { code: 'POS_E_BAD_REQUEST', message: 'неизвестный cursor', requestId: rid() } };
      offset = Number(mm[1]);
    }
    const page = filtered.slice(offset, offset + limit).map(({ _at, ...it }) => it);
    const next = offset + limit;
    const hasMore = next < filtered.length;
    return { status: 200, body: { items: page, hasMore, cursor: hasMore ? b64(`ext:${next}`) : null } };
  }

  // -------------------------------------------------------------- POST /pos/v1/check
  setCheckMode(mode, count = 0) {
    if (!CHECK_MODES.includes(mode)) throw Object.assign(new Error(`режим проверки: ${CHECK_MODES.join(' | ')}`), { code: 'BAD_ARGS' });
    this.check = { mode, remaining: Math.max(0, Number(count) || 0) };
    this.markDirty();
    return { ...this.check };
  }

  checkCart(body) {
    const mode = this.check.mode;
    this.stats.checks[mode] = (this.stats.checks[mode] ?? 0) + 1;
    if (mode !== 'ok' && this.check.remaining > 0) {
      this.check.remaining -= 1;
      if (this.check.remaining === 0) this.check = { mode: 'ok', remaining: 0 };
    }
    const lines = Array.isArray(body?.lines) ? body.lines : [];
    if (mode === 'unavailable') return { status: 503, body: { code: 'POS_E_MAINTENANCE', message: '1С на обслуживании (демо: режим проверки «недоступна»)', requestId: rid() } };
    if (mode === 'reject') {
      return {
        status: 409,
        body: {
          code: 'POS_E_STATE',
          message: 'Остаток или цена в 1С не совпадают с корзиной (демо: режим проверки «отклонять»)',
          details: { lines: lines.map((_, i) => ({ lineNumber: i + 1, text: 'Недостаточно остатка на складе; цена в 1С изменилась' })) },
          requestId: rid(),
        },
      };
    }
    const checkedAt = onecTime();
    const out = lines.map((l) => {
      const q = typeof l.quantity === 'string' ? l.quantity : '1.000';
      const base = { productRef: l.productRef ?? null, variantRef: l.variantRef ?? null };
      if (mode !== 'remarks') return { ...base, available: q, onHand: q, reserved: '0.000', isAvailable: true, warehouses: [], issues: [] };
      return { ...base, available: '0.000', onHand: '0.000', reserved: '0.000', isAvailable: false, warehouses: [], issues: [{ code: 'STOCK_INSUFFICIENT' }, { code: 'PRICE_CHANGED' }] };
    });
    return { status: 200, body: { checkedAt, lines: out, receivables: null, totals: null, issues: [] } };
  }

  // -------------------------------------------------------------- QR
  /** Истечь QR (панель «Истечь»): следующий опрос вернёт expired. */
  expireQr(paymentId) {
    const q = this.fake.qr.get(paymentId);
    if (!q) return null;
    if (q.status === 'pending') q.status = 'expired';
    this.markDirty();
    return q;
  }

  // -------------------------------------------------------------- сохранение и восстановление
  serialize() {
    const f = this.fake;
    const ex = this.cs.exchange;
    return {
      v: FAKE_STATE_VERSION,
      savedAt: new Date().toISOString(),
      fake: {
        orders: [...f.orders.values()],
        qr: [...f.qr.values()],
        orderMode: f.orderMode,
        failNext: f.failNext,
        down: f.down,
        orderSeq: f.orderSeq,
        messageNumber: f.messageNumber,
        paidAfterPolls: f.paidAfterPolls,
      },
      manualDocs: [...this.manualDocs.values()],
      check: { ...this.check },
      exchange: {
        registrations: [...ex.registrations.entries()],
        deletions: [...ex.deletions.entries()],
        current: ex.current ?? null,
        lastIssued: ex.lastIssued,
        lastAck: ex.lastAck,
      },
      journal: this.cs.journal.ops,
    };
  }

  /** Восстановить сохранённое состояние (до сверки с PGlite). Возвращает отчёт. */
  restore(saved, log = () => {}) {
    const rep = { version: saved?.v ?? null, orders: 0, qr: 0, journal: 0, journalErrors: 0, exchange: false };
    if (!saved || saved.v !== FAKE_STATE_VERSION) {
      this.stats.restored = { ...rep, skipped: saved ? `версия ${saved.v}` : 'нет состояния' };
      return this.stats.restored;
    }
    const f = this.fake;
    const s = saved.fake ?? {};
    f.orders.clear();
    for (const o of s.orders ?? []) f.orders.set(o.externalId, { ...o });
    f.qr.clear();
    for (const q of s.qr ?? []) f.qr.set(q.externalId, { ...q });
    if (typeof s.orderMode === 'string') f.orderMode = s.orderMode;
    if (Number.isFinite(s.failNext)) f.failNext = s.failNext;
    f.down = s.down === true;
    if (Number.isFinite(s.orderSeq)) f.orderSeq = Math.max(f.orderSeq, s.orderSeq);
    if (Number.isFinite(s.messageNumber)) f.messageNumber = Math.max(f.messageNumber, s.messageNumber);
    if (Number.isFinite(s.paidAfterPolls)) f.paidAfterPolls = s.paidAfterPolls;
    this.manualDocs.clear();
    for (const d of saved.manualDocs ?? []) this.manualDocs.set(d.externalId, { ...d });
    if (saved.check && CHECK_MODES.includes(saved.check.mode)) this.check = { mode: saved.check.mode, remaining: saved.check.remaining ?? 0 };
    rep.orders = f.orders.size;
    rep.qr = f.qr.size;
    // Журнал синтетики: проигрывание без регистрации в плане обмена (регистрации восстанавливаются ниже как были).
    const cs = this.cs;
    cs.journal.muted = true;
    cs.journal.replaying = true;
    try {
      for (const op of saved.journal ?? []) {
        const [name, ...args] = op;
        try {
          if (name === 'addShipment') cs.addShipment(args[0]);
          else {
            const fn = cs.cashier[name]?.__orig ?? cs.cashier[name];
            fn.apply(cs.cashier, args);
          }
          cs.journal.ops.push(op);
          rep.journal++;
        } catch (e) {
          rep.journalErrors++;
          log('warn', `fake1c: журнал синтетики: ${name} не проигран: ${e?.message ?? e}`);
        }
      }
    } finally {
      cs.journal.muted = false;
      cs.journal.replaying = false;
    }
    const ex = cs.exchange;
    const se = saved.exchange;
    if (se) {
      ex.registrations.clear();
      for (const [k, n] of se.registrations ?? []) ex.registrations.set(k, n);
      ex.deletions.clear();
      for (const [k, v] of se.deletions ?? []) ex.deletions.set(k, v);
      ex.current = se.current ?? undefined;
      ex.lastIssued = Math.max(ex.lastIssued ?? 0, se.lastIssued ?? 0);
      ex.lastAck = Math.max(ex.lastAck ?? 0, se.lastAck ?? 0);
      rep.exchange = true;
    }
    this.stats.restored = rep;
    return rep;
  }

  /**
   * Сверка с данными PGlite (всегда на холодном старте, после restore): номера 1С и номер сообщения продолжаются от
   * данных POS, заказы POS с номером 1С и ожидающие QR, которых нет в имитаторе (состояние не успело сохраниться
   * или нет сохранённого), заводятся заново — иначе синхронизация статусов пометила бы заказы missing, а опрос QR
   * получил бы 404.
   * pos: { orders: [{id, onec_ref, onec_number, onec_date, onec_status_raw, total, created_at}],
   *        qrs: [{id, order_id, amount, qr_expires_at, qr_provider_ref, qr_issued_at, created_at}],
   *        lastMessageNumber }
   */
  reconcile(pos) {
    const f = this.fake;
    const rep = { ordersAdded: 0, qrAdded: 0, orderSeqFrom: f.orderSeq, messageFrom: f.messageNumber };
    let maxSeq = f.orderSeq;
    for (const o of pos.orders ?? []) {
      const mm = ONEC_NUMBER_RE.exec(String(o.onec_number ?? ''));
      if (mm) maxSeq = Math.max(maxSeq, Number(mm[1]));
      if (!o.onec_ref || f.orders.has(o.id) || this.manualDocs.has(o.id)) continue;
      const status = typeof o.onec_status_raw === 'string' && o.onec_status_raw ? o.onec_status_raw : 'НеСогласован';
      f.orders.set(o.id, {
        externalId: o.id,
        ref: o.onec_ref,
        number: o.onec_number ?? `ОС00-${String(++maxSeq).padStart(6, '0')}`,
        date: o.onec_date ? onecTime(new Date(o.onec_date)) : onecTime(new Date(o.created_at)),
        status,
        approved: status === 'КВыполнению',
        total: typeof o.total === 'string' ? o.total : String(o.total ?? '0.00'),
        createdAt: new Date(o.created_at).toISOString(),
        createCalls: 1,
      });
      rep.ordersAdded++;
    }
    for (const d of this.manualDocs.values()) {
      const mm = ONEC_NUMBER_RE.exec(d.number);
      if (mm) maxSeq = Math.max(maxSeq, Number(mm[1]));
    }
    for (const o of f.orders.values()) {
      const mm = ONEC_NUMBER_RE.exec(o.number);
      if (mm) maxSeq = Math.max(maxSeq, Number(mm[1]));
    }
    f.orderSeq = maxSeq;
    for (const q of pos.qrs ?? []) {
      if (f.qr.has(q.id)) continue;
      const created = new Date(q.qr_issued_at ?? q.created_at);
      f.qr.set(q.id, {
        externalId: q.id,
        orderExternalId: q.order_id ?? null,
        reference: q.qr_provider_ref ?? `QR-${q.id.slice(0, 8).toUpperCase()}`,
        amount: typeof q.amount === 'string' ? q.amount : String(q.amount),
        createdAt: onecTime(created),
        expiresAt: new Date(q.qr_expires_at ?? created.getTime() + 900_000).toISOString(),
        status: 'pending',
        polls: 0,
        paidAmount: null,
        paidAt: null,
        bankReference: `BK-${created.getTime()}`,
      });
      rep.qrAdded++;
    }
    const last = Number(pos.lastMessageNumber ?? 0);
    const ex = this.cs.exchange;
    if (last > 0) {
      // План обмена кассира нумерует сообщение как since+1: номер, выданный POS раньше, считается выданным.
      ex.lastIssued = Math.max(ex.lastIssued ?? 0, last);
      ex.lastAck = Math.max(ex.lastAck ?? 0, last);
      f.messageNumber = Math.max(f.messageNumber, last + 1);
    }
    rep.orderSeq = f.orderSeq;
    rep.messageNumber = f.messageNumber;
    this.stats.reconciled = rep;
    if (rep.ordersAdded || rep.qrAdded) this.markDirty();
    return rep;
  }
}

/** QR-payload, который банковское приложение не примет за платёжный (§3.7). */
export function nonPayable(externalId) {
  return `${NON_PAYABLE_PREFIX}|ОПТОМСТРОЙ-ДЕМО|${String(externalId).slice(0, 8).toUpperCase()}`;
}
