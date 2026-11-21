// Состояние имитатора HTTP-сервиса 1С на образцах 1.2.0: регистр externalId, план обмена (номера, курсоры,
// ack, reregister), клиенты, оплаты, заказы, QR, константа «обмен приостановлен», журнал запросов.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { isoBishkek } from '../report/time.mjs';

const PAGE = 12; // имитатор отдаёт сообщение страницами по 12 элементов (как в образцах), чтобы был виден курсор

function loadSamples(dir) {
  const m = new Map();
  for (const f of fs.readdirSync(dir)) if (f.endsWith('.json')) m.set(f, JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8')));
  return m;
}

const clone = (x) => structuredClone(x);
const key = (it) => `${it.type}:${it.ref}`;
const b64 = (s) => Buffer.from(s, 'utf8').toString('base64');
const unb64 = (s) => { try { return Buffer.from(String(s), 'base64').toString('utf8'); } catch { return ''; } };

export class MockState {
  constructor(samplesDir, defect = null) {
    this.S = loadSamples(samplesDir);
    this.defect = defect;
    this.maintenance = false;
    const h = this.body('health.200.json');
    this.health = h;
    this.lastAck = h.lastAckMessageNumber;
    // Базовый состав плана обмена — элементы двух страниц образца сообщения 5121.
    this.base = [...this.body('changes.catalog.page1.200.json').items, ...this.body('changes.documents.page2.200.json').items];
    this.registrations = new Map(this.base.map((it) => [key(it), clone(it)]));
    this.issued = null; // номер выданного (пронумерованного) сообщения
    this.getsWithoutCursor = 0;
    this.customers = new Map(); // externalId → {ref, code, phone, body}
    this.custByExt = new Map();
    this.phoneIndex = new Map([['+996700000001', 'c3d4e5f6-0000-4000-8000-000000000001']]);
    this.payments = new Map();
    this.orders = new Map();
    this.qr = new Map();
    this.xid = []; // записи POS_ВнешниеИдентификаторыPOS, созданные в имитаторе
    this.locks = new Map();
    this.seq = 1;
    this.image = this.#makeImage();
  }

  body(name) {
    const j = this.S.get(name);
    if (!j) throw new Error(`нет образца ${name}`);
    return clone(j.body);
  }

  nextNum(prefix) {
    return `${prefix}${String(this.seq++).padStart(6, '0')}`;
  }

  /** Блокировка по externalId (управляемая блокировка 1С). */
  async withLock(id, fn) {
    while (this.locks.has(id)) await this.locks.get(id);
    let release;
    const p = new Promise((r) => { release = r; });
    this.locks.set(id, p);
    try {
      await new Promise((r) => setTimeout(r, 3));
      return await fn();
    } finally {
      this.locks.delete(id);
      release();
    }
  }

  // ------------------------------------------------------------ картинка: JPEG-подобные байты размера из образца
  #makeImage() {
    const img = this.base.find((i) => i.type === 'Catalog_НоменклатураПрисоединенныеФайлы');
    const size = img ? img.size : 4096;
    const buf = Buffer.alloc(size, 0);
    Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00]).copy(buf, 0);
    const rnd = crypto.createHash('sha256').update('optomstroy-demo-image').digest();
    for (let i = 16; i < size - 2; i++) buf[i] = rnd[i % 32] ^ (i & 0xff);
    buf[size - 2] = 0xff; buf[size - 1] = 0xd9;
    return { ref: img ? img.ref : null, bytes: buf, sha256: crypto.createHash('sha256').update(buf).digest('hex') };
  }

  // ------------------------------------------------------------ план обмена

  get backlog() {
    return this.registrations.size;
  }

  register(item) {
    this.registrations.set(key(item), clone(item));
  }

  reregister() {
    for (const it of this.base) this.register(it);
    for (const c of this.customers.values()) this.register(c.partner);
    for (const id of this.orders.keys()) this.register(this.orderItem(id));
    for (const id of this.qr.keys()) this.register(this.qrItem(id));
  }

  /**
   * Элемент Document_ЗаказКлиента для заказа POS (Требования §5.1, §5.7, §6.2 правило 8, §6.6 «Регистрация изменений»):
   * текущее состояние документа и externalId заказа POS. Регистрируется при создании и при отмене.
   */
  orderItem(id) {
    const s = this.orderStatus(id);
    this.ver = (this.ver || 0) + 1;
    return {
      type: 'Document_ЗаказКлиента', ref: s.ref, dataVersion: b64(`order-${this.ver}`), deletionMark: s.deletionMark, externalId: id,
      number: s.number, date: s.date, status: s.status, approved: s.approved, fulfillmentState: s.fulfillmentState ?? null, total: s.total, shipments: s.shipments,
    };
  }

  /** Элемент QrPaymentStatus для записи POS_ОплатыQR (Требования §5.7, §6.14 п. 9, §7.10): каждое изменение записи. */
  qrItem(id) {
    const q = this.qr.get(id);
    return { type: 'QrPaymentStatus', ref: id, externalId: id, status: q.status, reference: q.resp.reference, paidAmount: null, paidAt: null, bankReference: null, documentRef: null };
  }

  /** GET /changes. */
  changes(since, limit, cursor) {
    const D = this.defect;
    if (since !== this.lastAck && D !== 'D34') return { error: [400, 'POS_E_BAD_REQUEST', `Номер ${since} не равен последнему подтверждённому ${this.lastAck}`] };
    let N = this.lastAck + 1;
    if (!cursor) {
      this.getsWithoutCursor++;
      this.issued = N;
      if (D === 'D28' && this.getsWithoutCursor >= 2) N = N + 1;
    }
    const all = [...this.registrations.values()].sort((a, b) => key(a).localeCompare(key(b), 'ru'));
    let size = Math.min(limit, 5000, PAGE);
    let items = all;
    if (D === 'D33' && limit >= 10000) { items = Array.from({ length: 5001 }, (_, i) => ({ ...clone(all[0] || this.base[0]), ref: crypto.randomUUID(), _i: i })); size = 5001; }
    let offset = 0;
    if (cursor) {
      const m = /^(\d+):(\d+)$/.exec(unb64(cursor));
      if (!m || Number(m[1]) !== N) return { error: [400, 'POS_E_BAD_REQUEST', 'Неверный курсор'] };
      offset = Number(m[2]);
    }
    const page = items.slice(offset, offset + size).map((x) => { const c = clone(x); delete c._i; return c; });
    const next = offset + size;
    let hasMore = next < items.length;
    let cur = hasMore ? b64(`${N}:${next}`) : null;
    let msgNo = N;
    if (D === 'D29' && hasMore) cur = null;
    if (D === 'D30' && offset > 0) msgNo = N + 7;
    if (D === 'D31' && offset > 0) { hasMore = true; cur = cursor; }
    if (D === 'D32' && offset > 0 && page.length) page.unshift(clone(items[0]));
    if (D === 'D07') for (const it of page) if (it.type === 'Catalog_Номенклатура' && !it.isFolder) it.ref = it.ref.toUpperCase();
    if (D === 'D08') for (const it of page) if (it.type === 'Catalog_Склады') it.ref = `{${it.ref}}`;
    if (D === 'D10') for (const it of page) if (it.type === 'Catalog_УпаковкиЕдиницыИзмерения') it.factor = Number(it.factor).toFixed(2);
    if (D === 'D12') return { body: { messageNumber: msgNo, hasMore, cursor: cur, generatedAt: new Date().toISOString().replace('Z', '+06:00'), items: page } };
    if (D === 'D31' && hasMore && offset === 0) cur = b64(`${N}:${next}`);
    return { body: { messageNumber: msgNo, hasMore, cursor: cur, generatedAt: isoBishkek(), items: page } };
  }

  ack(n) {
    const D = this.defect;
    if (n <= this.lastAck) {
      if (D === 'D35') return { error: [409, 'POS_E_ACK_OUT_OF_ORDER', `Номер сообщения ${n} уже подтверждён`] };
      return { body: { messageNumber: n, removedRegistrations: 0 } };
    }
    if (n === this.lastAck + 1 && this.issued === n) {
      const removed = this.registrations.size;
      if (D !== 'D37') this.registrations.clear();
      this.lastAck = n;
      this.issued = null;
      this.getsWithoutCursor = 0;
      return { body: { messageNumber: n, removedRegistrations: removed } };
    }
    if (D === 'D36') return { body: { messageNumber: n, removedRegistrations: 0 } };
    return { error: [409, 'POS_E_ACK_OUT_OF_ORDER', `Номер сообщения ${n} не выдавался`] };
  }

  // ------------------------------------------------------------ клиенты

  partnerItem(c) {
    return {
      type: 'Catalog_Партнеры', ref: c.ref, dataVersion: b64(`v${this.seq++}`), deletionMark: false, externalId: c.externalId,
      code: c.code, description: c.body.name, fullName: c.body.fullName ?? null, isClient: true, mainAgreementRef: null,
      phones: [{ phone: c.body.phone, presentation: c.body.phone }],
    };
  }

  async createCustomer(b) {
    if (typeof b.phone !== 'string' || !/^\+[1-9]\d{7,14}$/.test(b.phone)) return { error: [400, 'POS_E_BAD_REQUEST', 'Телефон не в формате +996XXXXXXXXX'] };
    const D = this.defect;
    return this.withLock(b.externalId, async () => {
      const list = this.custByExt.get(b.externalId) || [];
      const dupMode = (D === 'D38' && list.length < 2) || (D === 'D39' && list.length < 3);
      if (list.length && !dupMode) {
        const c = list[0];
        return { status: 200, body: { externalId: b.externalId, ref: c.ref, contractorRef: c.contractorRef, code: c.code, created: false } };
      }
      if (!list.length) {
        const dupRef = this.phoneIndex.get(b.phone);
        if (dupRef && b.dedupe?.failOnDuplicate !== false) {
          const msg = D === 'D27' ? `Найден другой клиент с телефоном ${b.phone}` : (D === 'D26' ? 'Duplicate customer found' : 'Найден другой клиент с тем же телефоном');
          const details = D === 'D40' ? undefined : { candidates: [{ ref: dupRef, name: 'Клиент найден по телефону', phone: b.phone }] };
          return { error: [409, D === 'D23' ? 'POS_E_WHATEVER' : 'POS_E_DUPLICATE', msg, details] };
        }
      }
      const c = { externalId: b.externalId, ref: crypto.randomUUID(), contractorRef: crypto.randomUUID(), code: this.nextNum('ПР'), body: b, createdAt: new Date() };
      c.partner = this.partnerItem(c);
      list.push(c);
      this.custByExt.set(b.externalId, list);
      this.customers.set(b.externalId + (list.length > 1 ? ':' + list.length : ''), c);
      if (!this.phoneIndex.has(b.phone)) this.phoneIndex.set(b.phone, c.ref);
      this.register(c.partner);
      if (list.length === 1) this.xid.push({ externalId: b.externalId, objectType: 'Клиент', ref: c.ref, number: c.code, date: null, deletionMark: false, createdAt: c.createdAt });
      return { status: 201, body: { externalId: b.externalId, ref: c.ref, contractorRef: c.contractorRef, code: c.code, created: true } };
    });
  }

  findCustomers(phone) {
    let p = String(phone || '').replace(/[\s()-]/g, '');
    if (/^0\d{9}$/.test(p)) p = '+996' + p.slice(1);
    if (/^996\d{9}$/.test(p)) p = '+' + p;
    if (p === '+996700000001') {
      const b = this.body('customers-search.200.json');
      if (this.defect === 'D13') for (const x of b) x.phone = '0700000001';
      return b;
    }
    const out = [];
    for (const c of this.customers.values()) {
      if (c.body.phone === p) out.push({ ref: c.ref, contractorRef: c.contractorRef, code: c.code, name: c.body.name, phone: c.body.phone, deletionMark: false, kind: c.body.kind });
    }
    return out;
  }

  knownCustomer(ref) {
    if (ref === 'c3d4e5f6-0000-4000-8000-000000000001') return true;
    for (const c of this.customers.values()) if (c.ref === ref) return true;
    return false;
  }

  receivables(ref) {
    if (!this.knownCustomer(ref)) return { error: [404, 'POS_E_NOT_FOUND', 'Клиент не найден'] };
    const b = this.body('receivables.200.json');
    b.customerRef = ref;
    b.snapshotAt = isoBishkek();
    if (this.defect === 'D09') b.balance = 1234.5;
    if (this.defect === 'D46') { b.customerRef = crypto.randomUUID(); b.overdueAmount = '99999.00'; }
    return { status: 200, body: b };
  }

  // ------------------------------------------------------------ оплаты

  async createPayment(b) {
    return this.withLock(b.externalId, async () => {
      const ex = this.payments.get(b.externalId);
      if (ex) return { status: 200, body: ex.resp };
      if (b.orderExternalId && !this.orders.has(b.orderExternalId) && b.orderExternalId !== '0192f5a0-7c2e-7d3b-9a1f-3c4d5e6f7a8b') {
        if (this.defect === 'D41') return { error: [404, 'POS_E_NOT_FOUND', 'Заказ не найден'] };
        return { error: [422, 'POS_E_VALIDATION', 'Заказ не найден'] };
      }
      const sum = (b.allocations || []).reduce((a, x) => a + Number(x?.amount || 0), 0);
      if (sum > Number(b.amount) + 1e-9) {
        if (this.defect === 'D24') return { error: [422, 'POS_E_INTERNAL', 'Сумма распределения больше суммы оплаты'] };
        return { error: [422, 'POS_E_VALIDATION', 'Сумма распределения больше суммы оплаты'] };
      }
      const resp = { ref: crypto.randomUUID(), number: this.nextNum('ПКО0-'), date: isoBishkek(), posted: !!b.post, documentType: 'Document_ПриходныйКассовыйОрдер' };
      this.payments.set(b.externalId, { resp, body: b });
      this.xid.push({ externalId: b.externalId, objectType: 'Платеж', ref: resp.ref, number: resp.number, date: resp.date, deletionMark: false, createdAt: new Date() });
      return { status: 201, body: resp };
    });
  }

  // ------------------------------------------------------------ заказы

  async createOrder(b) {
    return this.withLock(b.externalId, async () => {
      const ex = this.orders.get(b.externalId);
      if (ex) return { status: 200, body: ex.resp };
      const resp = this.body('orders-create.201.json');
      resp.externalId = b.externalId;
      resp.ref = crypto.randomUUID();
      resp.number = this.nextNum('ЗК00-');
      resp.date = isoBishkek();
      resp.totals = clone(b.totals);
      resp.recalculated = false;
      resp.deletionMark = false;
      resp.warnings = [];
      if (this.defect === 'D14') resp.totals.currency = 'USD';
      this.orders.set(b.externalId, { resp, body: b, cancelled: false });
      this.xid.push({ externalId: b.externalId, objectType: this.defect === 'D47' ? 'Order' : 'Заказ', ref: resp.ref, number: resp.number, date: resp.date, deletionMark: false, createdAt: new Date() });
      this.register(this.orderItem(b.externalId));
      return { status: 201, body: resp };
    });
  }

  orderStatus(id) {
    const o = this.orders.get(id);
    if (!o) return null;
    const s = this.body('orders-status.200.json');
    Object.assign(s, { externalId: id, ref: o.resp.ref, number: o.resp.number, date: o.resp.date, total: o.resp.totals.total, shipments: [] });
    if (o.cancelled) { s.status = 'Закрыт'; s.approved = false; s.deletionMark = false; s.fulfillmentState = null; }
    return s;
  }

  cancelOrder(id) {
    const o = this.orders.get(id);
    if (!o) return { error: [404, 'POS_E_NOT_FOUND', 'Заказ не найден'] };
    // Повторная отмена отменённого заказа — 200 с тем же состоянием, без изменений документа (Требования §6.7).
    if (!o.cancelled) { o.cancelled = true; this.register(this.orderItem(id)); }
    return { status: 200, body: this.orderStatus(id) };
  }

  // ------------------------------------------------------------ QR

  createQr(b) {
    const ex = this.qr.get(b.externalId);
    if (ex && ex.status === 'pending') return { status: 200, body: { ...ex.resp } };
    const resp = this.body('payments-qr.201.json');
    const now = new Date();
    Object.assign(resp, {
      externalId: b.externalId, status: 'pending', reference: `QR-DEMO-${String(this.seq++).padStart(6, '0')}`, amount: b.amount,
      createdAt: isoBishkek(now), expiresAt: isoBishkek(new Date(now.getTime() + (b.requestedTtlSeconds || 900) * 1000)),
    });
    this.qr.set(b.externalId, { resp, status: 'pending' });
    this.register(this.qrItem(b.externalId));
    return { status: 201, body: resp };
  }

  qrStatus(id) {
    const q = this.qr.get(id);
    if (!q) return null;
    const s = this.body('payments-status.pending.200.json');
    Object.assign(s, { externalId: id, status: q.status, reference: q.resp.reference, amount: q.resp.amount, expiresAt: q.resp.expiresAt, paidAmount: null, paidAt: null, bankReference: null, documentRef: null, documentType: null });
    if (this.defect === 'D15') delete s.paidAmount;
    return s;
  }

  cancelQr(id) {
    const q = this.qr.get(id);
    if (!q) return { error: [404, 'POS_E_NOT_FOUND', 'Оплата не найдена'] };
    // Повторная отмена ничего не меняет — и не регистрирует запись заново (Требования §6.16 п. 4).
    if (q.status !== 'cancelled') { q.status = 'cancelled'; this.register(this.qrItem(id)); }
    return { status: 200, body: { externalId: id, status: 'cancelled', reference: q.resp.reference, paidAmount: null, paidAt: null, bankReference: null, documentRef: null } };
  }

  // ------------------------------------------------------------ сверка

  externalIds({ since, type, limit, cursor }) {
    // Записи образца считаются созданными вчера — чтобы сверка за 7 дней (X1) в демо видела данные.
    const yesterday = new Date(Date.now() - 86400000);
    const sampleRecs = this.body('external-ids.200.json').items.map((x) => ({ ...x, createdAt: yesterday }));
    let recs = [...this.xid, ...sampleRecs];
    if (this.defect === 'D47') recs.push({ externalId: crypto.randomUUID(), objectType: 'Order', ref: crypto.randomUUID(), number: 'ЗК00-000001', date: isoBishkek(), deletionMark: false, createdAt: new Date() });
    if (since) {
      const t = Date.parse(since);
      if (!Number.isFinite(t)) return { error: [400, 'POS_E_BAD_REQUEST', 'Неверная дата since'] };
      recs = recs.filter((x) => x.createdAt.getTime() >= t);
    }
    if (type) recs = recs.filter((x) => x.objectType === type);
    recs.sort((a, b) => (b.createdAt - a.createdAt) || a.externalId.localeCompare(b.externalId));
    const lim = Math.min(Math.max(1, limit || 1000), 1000);
    const off = cursor ? Number(unb64(cursor)) || 0 : 0;
    const page = recs.slice(off, off + lim).map(({ createdAt, ...x }) => {
      void createdAt;
      return x;
    });
    const hasMore = off + lim < recs.length;
    return { status: 200, body: { items: page, hasMore, cursor: hasMore ? b64(String(off + lim)) : null } };
  }

  // ------------------------------------------------------------ имитация действий человека в 1С (C11, C12, M1)

  changeProduct(ref) {
    let it = this.base.find((i) => i.ref === ref) || [...this.registrations.values()].find((i) => i.ref === ref);
    if (!it) return false;
    it = clone(it);
    it.dataVersion = b64(`changed-${Date.now()}`);
    it.descriptionText = (it.descriptionText || '') + ' (изменено)';
    this.register(it);
    return true;
  }

  deleteObject() {
    const v = this.base.find((i) => i.type === 'Catalog_ХарактеристикиНоменклатуры');
    const ref = v ? v.ref : crypto.randomUUID();
    this.register({ type: 'ObjectDeletion', objectType: 'Catalog_ХарактеристикиНоменклатуры', ref });
    return ref;
  }
}
