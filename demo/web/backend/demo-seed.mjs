// История заказов при первом запуске эпохи (WP-B3; plan §3.5 «История»; critic [20]). Сид работает в фоне с низшим
// приоритетом («единицы работы» kind 'seed') через НАСТОЯЩИЙ API pos-api (bridge.request → express), под служебными
// учётками «Демо-история …» (981 продавец, 986 кассир, 987 старший продавец). PIN учёток сид задаёт сам при первом
// входе (случайный, хранится в demo_meta). После сида учётки блокируются, их сессии отзываются.
//
// Заказы «сегодня» (время в прошлое не переносится — иначе ломается хэш-цепочка аудита):
//   cash     — продавец оформил наличными, кассир принял оплату;
//   qr       — QR через «1С», оплачен;
//   credit   — в долг клиенту «Покупатель Долг в лимите (тест)»;
//   shipped  — оплачен, «1С: К выполнению», отгружен (для возврата);
//   cancelled — отменён продавцом.
// Шаги идемпотентны по сохранённому состоянию (demo_meta 'seed'): оборванный сид продолжается на следующем старте.
//
// Review fixes (F5 во время сида на первом визите — 12–17 с, страница выглядит занятой):
//  - состояние сохраняется сразу после КАЖДОГО шага (раньше — только в начале следующего) и сбрасывается на диск
//    (storage.flush), а не фоном;
//  - внутри шага: Idempotency-Key заказа записывается ДО POST /orders, id созданного заказа — сразу после; на
//    следующем старте шаг продолжает свой заказ (поиск по orders.idempotency_key, если ответ не успел записаться),
//    а не создаёт второй; оплата, согласование, отгрузка и отмена пропускаются, если уже выполнены.
import * as gate from './alias/work-gate.mjs';
import * as pgShim from './alias/pg-shim.mjs';
import { ENTITY_QUEUES } from '@pos-api-dist/sync/scheduler/sync-queues.js';
import { DEMO_BUILD, OTP_TEST_CODE, SEED_ACCOUNTS, STAFF } from './demo-config.mjs';
import { writeMeta } from './demo-init.mjs';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
/** Сценарный клиент «долг в лимите» синтетики кассира (CASHIER_SCENARIOS.debtWithinLimit). */
const DEBT_WITHIN_LIMIT_REF = 'c3d4e5f6-0000-4000-8000-000000000001';
const STEPS = ['accounts', 'cash', 'qr', 'credit', 'shipped', 'cancelled', 'block'];

function randomPin() {
  for (;;) {
    const d = [...crypto.getRandomValues(new Uint8Array(6))].map((x) => x % 10);
    const s = d.join('');
    if (/^(\d)\1+$/.test(s)) continue;
    const asc = d.every((x, i) => i === 0 || x === (d[i - 1] + 1) % 10);
    const desc = d.every((x, i) => i === 0 || x === (d[i - 1] + 9) % 10);
    if (!asc && !desc) return s;
  }
}

export class HistorySeed {
  /** ctx: { bridge, be (initBackend), control (demo-control), log } */
  constructor(ctx, saved) {
    this.ctx = ctx;
    this.s = saved && typeof saved === 'object' ? { ...saved } : { state: 'pending', pct: 0, done: {}, accounts: {} };
    this.s.done ??= {};
    this.s.accounts ??= {};
    /** Шаг в работе: { orderKey, orderId } — продолжение того же заказа после перезагрузки. */
    this.s.pending ??= {};
    this.resumed = 0;
    this.H = {};
    this.running = null;
    this.pool = new pgShim.default.Pool({ application_name: 'demo-seed' });
  }

  state() {
    const { accounts: _a, pending: _p, ...pub } = this.s;
    const pending = Object.entries(this.s.pending ?? {}).map(([step, v]) => ({ step, order: !!v?.orderId, key: !!v?.orderKey }));
    return { ...pub, pending, resumed: this.resumed };
  }

  needed() {
    return this.s.state !== 'done';
  }

  start() {
    if (!this.needed() || this.running || this.stopped) return this.running;
    this.running = this.run().finally(() => (this.running = null));
    return this.running;
  }

  /**
   * Review fixes: остановка (shutdown вкладки, перехват тома, сброс) — следующий запрос сида не выполняется, состояние
   * НЕ помечается «failed»: шаг продолжится на следующем старте (pending/orderKey сохранены).
   */
  stop() {
    this.stopped = true;
    return this.running ?? Promise.resolve(null);
  }
  checkStopped() {
    if (this.stopped) throw Object.assign(new Error('сид остановлен (вкладка закрывается)'), { code: 'ERR_DEMO_SEED_STOPPED' });
  }

  /** Состояние сида → demo_meta и сразу на диск (review fixes: F5 посреди сида не повторяет шаг). */
  async save(patch = {}) {
    Object.assign(this.s, patch);
    if (this.stopped) return;
    try {
      await writeMeta(this.ctx.be.db, 'seed', this.s);
      const r = await this.ctx.be.storage.flush('seed:state');
      if (r?.error) this.ctx.log('warn', `сид: состояние не записано на диск: ${r.error}`);
    } catch (e) {
      this.ctx.log('warn', `сид: состояние не сохранено: ${e?.message ?? e}`);
    }
  }

  progress(step, message) {
    const i = STEPS.indexOf(step);
    this.s.step = step;
    this.s.pct = Math.round(((i < 0 ? 0 : i) / STEPS.length) * 100);
    this.s.message = message;
  }

  async run() {
    const t0 = Date.now();
    this.s.startedAt ??= new Date().toISOString();
    this.s.state = 'running';
    try {
      for (const step of STEPS) {
        if (this.s.done[step]) continue;
        this.progress(step, STEP_TEXT[step]);
        await this.save();
        const r = await this[`step_${step}`]();
        this.s.done[step] = r ?? true;
        delete this.s.pending[step];
        await this.save();
      }
      this.s.state = 'done';
      this.s.pct = 100;
      this.s.message = 'История заказов создана';
      this.s.finishedAt = new Date().toISOString();
      this.s.ms = (this.s.ms ?? 0) + (Date.now() - t0);
      await this.save();
    } catch (e) {
      if (e?.code === 'ERR_DEMO_SEED_STOPPED' || this.stopped) {
        this.ctx.log('info', `сид истории: остановлен на шаге ${this.s.step} (продолжится на следующем старте)`);
        return this.state();
      }
      this.s.state = 'failed';
      this.s.message = String(e?.message ?? e).slice(0, 300);
      this.s.ms = (this.s.ms ?? 0) + (Date.now() - t0);
      this.ctx.log('warn', `сид истории: шаг ${this.s.step}: ${e?.stack ?? e}`);
      await this.save();
    }
    return this.state();
  }

  // ------------------------------------------------------------------ API
  base(acc) {
    return { 'X-Device-Id': acc.deviceId, 'X-App-Version': DEMO_BUILD.appVersion, 'X-Platform': 'android', 'Accept-Language': 'ru' };
  }
  async api(method, url, { headers = {}, body, idem = false, expect } = {}) {
    this.checkStopped();
    const h = { ...headers, ...(idem ? { 'Idempotency-Key': crypto.randomUUID() } : {}) };
    const r = await this.ctx.bridge.request(method, `/api/v1${url}`, { headers: h, body, kind: 'seed' });
    const ok = expect ? [].concat(expect).includes(r.status) : r.status < 400;
    if (!ok) throw new Error(`${method} ${url.split('?')[0]} → ${r.status} ${r.json?.code ?? ''} ${r.json?.detail ?? ''}`.trim());
    return r;
  }
  /** Единица сида для собственных действий (SQL, имитатор 1С). */
  unit(name, fn) {
    this.checkStopped();
    return gate.run({ kind: 'seed', name, label: `seed ${name}`, durable: true }, fn);
  }
  async until(fn, ok, timeoutMs, every = 500) {
    const end = Date.now() + timeoutMs;
    for (;;) {
      const v = await fn();
      if (ok(v)) return v;
      if (Date.now() > end) return v;
      await sleep(every);
    }
  }

  async login(key) {
    if (this.H[key]) return this.H[key];
    const def = SEED_ACCOUNTS.find((a) => a.key === key);
    const acc = (this.s.accounts[def.phone] ??= { deviceId: crypto.randomUUID(), pin: randomPin() });
    const base = this.base(acc);
    // Review fixes: после перезагрузки посреди сида учётка входит заново — в пределах паузы повторной отправки кода
    // (10 с) ответ 429 OTP_RATE_LIMITED; ждём Retry-After и повторяем (раньше сид падал с state 'failed').
    let rq = null;
    for (let i = 0; i < 4; i++) {
      rq = await this.api('POST', '/auth/otp/request', { headers: base, body: { phone: def.phone, purpose: 'login_or_register', locale: 'ru' }, expect: [202, 429] });
      if (rq.status !== 429) break;
      const wait = Math.min(15, Number(rq.headers?.['retry-after'] ?? rq.json?.retryAfter ?? 10) + 1);
      this.ctx.log('info', `сид: вход ${def.phone} — пауза повторной отправки кода ${wait} с`);
      await sleep(wait * 1000);
    }
    if (rq.status !== 202) throw new Error(`POST /auth/otp/request → ${rq.status} ${rq.json?.code ?? ''}`);
    const vr = await this.api('POST', '/auth/otp/verify', {
      headers: base,
      body: { challengeId: rq.json?.challengeId, code: OTP_TEST_CODE, device: { name: 'Демо-история', platform: 'android', appVersion: DEMO_BUILD.appVersion } },
    });
    const H = { ...base, Authorization: `Bearer ${vr.json?.accessToken}` };
    if (!acc.pinSet) {
      await this.api('POST', '/me/pin', { headers: H, body: { newPin: acc.pin }, idem: true, expect: [200, 204, 403] });
      acc.pinSet = true;
      await this.save();
    }
    this.H[key] = H;
    return H;
  }

  async products() {
    if (this.plist) return this.plist;
    const H = await this.login('cashier');
    const r = await this.api('GET', '/catalog/products?limit=40&inStock=true', { headers: H });
    this.plist = (r.json?.items ?? []).filter((p) => !p.hasVariants && p.price && p.defaultVariantId && p.baseUnit?.id);
    if (this.plist.length < 5) throw new Error(`мало товаров в наличии для истории: ${this.plist.length}`);
    return this.plist;
  }

  /**
   * Заказ шага step — один на шаг, и после перезагрузки тоже: сохранённый id; иначе — заказ с сохранённым заранее
   * Idempotency-Key (ответ POST /orders мог не успеть записаться в состояние сида); иначе — новая продажа.
   */
  async orderFor(step, H, p, method, opts = {}) {
    const pend = (this.s.pending[step] ??= {});
    if (!pend.orderId && pend.orderKey) {
      const ex = await this.unit('seed find order', async () => (await this.pool.query(`SELECT id::text AS id FROM orders WHERE idempotency_key = $1 ORDER BY created_at DESC LIMIT 1`, [pend.orderKey])).rows[0] ?? null);
      if (ex) pend.orderId = ex.id;
    }
    if (pend.orderId) {
      const r = await this.api('GET', `/orders/${pend.orderId}`, { headers: H, expect: [200, 404] });
      if (r.status === 200 && r.json?.id) {
        this.resumed++;
        this.ctx.log('info', `сид: шаг ${step} продолжает заказ ${r.json.publicNumber ?? r.json.id}`);
        return r.json;
      }
    }
    pend.orderKey = crypto.randomUUID();
    pend.orderId = null;
    await this.save();
    const o = await this.sell(H, p, method, { ...opts, orderKey: pend.orderKey });
    pend.orderId = o.id;
    await this.save();
    return o;
  }

  /** Получена ли оплата заказа (наличные/QR) — повтор шага после перезагрузки её не дублирует. */
  paid(o) {
    return (o?.payments ?? []).some((p) => p.status === 'received');
  }

  /** Заказ через корзину (как приложение): корзина → checkout-preview → POST /orders. */
  async sell(H, p, method, { customerId, qty = '1', orderKey } = {}) {
    let cart = (await this.api('GET', '/cart', { headers: H })).json;
    if ((cart?.items ?? []).length > 0) cart = (await this.api('DELETE', `/cart?rowVersion=${cart.rowVersion}`, { headers: H })).json;
    cart = (
      await this.api('PUT', `/cart/items/${p.defaultVariantId}`, {
        headers: H,
        idem: true,
        body: { quantity: { value: qty, unitId: p.baseUnit.id, packagingId: null }, rowVersion: cart.rowVersion, mode: 'set' },
      })
    ).json;
    if (customerId) cart = (await this.api('POST', '/cart/customer', { headers: H, idem: true, body: { customerId, rowVersion: cart.rowVersion } })).json;
    const prev = await this.api('POST', '/cart/checkout-preview', {
      headers: H,
      idem: true,
      body: { cartId: cart.id, cartRowVersion: cart.rowVersion, paymentMethod: method, delivery: { method: 'pickup' }, receiver: { kind: 'customer' } },
    });
    const o = await this.api('POST', '/orders', {
      headers: orderKey ? { ...H, 'Idempotency-Key': orderKey } : H,
      idem: !orderKey,
      body: {
        cartId: cart.id,
        cartRowVersion: cart.rowVersion,
        ...(prev.json?.previewToken ? { previewToken: prev.json.previewToken } : {}),
        ...(customerId ? { customerId } : {}),
        receiver: { kind: 'customer' },
        delivery: { method: 'pickup' },
        paymentMethod: method,
        items: [{ variantId: p.defaultVariantId, quantity: { value: qty, unitId: p.baseUnit.id, packagingId: null } }],
      },
    });
    return o.json;
  }

  async payCash(order) {
    const H = await this.login('cashier');
    const total = Number(order.total?.amount ?? order.total ?? 0); // money-double: allow — сумма «с запасом» для сдачи
    const amount = `${Math.ceil(total) + 100}.00`;
    return (await this.api('POST', `/orders/${order.id}/payments`, { headers: H, idem: true, body: { method: 'cash', receivedAmount: { amount, currency: 'KGS' } } })).json;
  }

  async waitOnec(H, id, timeoutMs = 25000) {
    return this.until(async () => (await this.api('GET', `/orders/${id}`, { headers: H })).json, (o) => !!o?.onec?.number, timeoutMs, 600);
  }

  // ------------------------------------------------------------------ шаги
  async step_accounts() {
    for (const a of SEED_ACCOUNTS) await this.login(a.key);
    return { at: new Date().toISOString() };
  }

  async step_cash() {
    const p = (await this.products())[0];
    const S = await this.login('seller');
    const o = await this.orderFor('cash', S, p, 'cash', { qty: '2' });
    if (!this.paid(o)) await this.payCash(o);
    return { orderId: o.id, number: o.publicNumber };
  }

  async step_qr() {
    const p = (await this.products())[1];
    const C = await this.login('cashier');
    const o = await this.orderFor('qr', C, p, 'qr_bakai');
    const pay = o.payments?.[0];
    if (!pay?.id) throw new Error('QR-платёж не создан');
    const status = (x) => x?.status ?? x?.payment?.status;
    let st = (await this.api('GET', `/payments/${pay.id}`, { headers: C })).json;
    if (status(st) !== 'received') {
      await this.unit('qr pay', async () => {
        const fq = this.ctx.be.fake.qr.get(pay.id);
        if (fq && /paid|received/i.test(String(fq.status ?? ''))) return; // уже оплачен в «1С» до перезагрузки
        const r = this.ctx.be.fake.handle('POST', `/__fake/qr/${pay.id}/pay`, {}, new URLSearchParams());
        if (r.status >= 400) throw new Error(`«1С» не оплатила QR: ${r.status}`);
      });
      st = await this.until(async () => (await this.api('GET', `/payments/${pay.id}`, { headers: C })).json, (x) => status(x) === 'received', 25000, 700);
    }
    return { orderId: o.id, number: o.publicNumber, payment: status(st) ?? null };
  }

  async step_credit() {
    const C = await this.login('cashier');
    const cust = await this.until(
      () => this.unit('find customer', async () => (await this.pool.query(`SELECT id::text AS id FROM customers WHERE onec_ref = $1`, [DEBT_WITHIN_LIMIT_REF])).rows[0] ?? null),
      (x) => !!x,
      40000,
      1000,
    );
    if (!cust) throw new Error('клиент «Долг в лимите» ещё не синхронизирован');
    const p = (await this.products())[2];
    // Снимок долга клиента должен быть свежим (receivables) — повтор, пока синхронизация долгов не прошла.
    let o = null;
    let lastErr = null;
    for (let i = 0; i < 12 && !o; i++) {
      try {
        o = await this.orderFor('credit', C, p, 'credit', { customerId: cust.id });
      } catch (e) {
        lastErr = e;
        if (!/RECEIVABLES|CREDIT/.test(String(e?.message))) throw e;
        await sleep(2000);
      }
    }
    if (!o) throw lastErr ?? new Error('продажа в долг не оформлена');
    return { orderId: o.id, number: o.publicNumber };
  }

  async step_shipped() {
    const p = (await this.products())[3];
    const C = await this.login('cashier');
    let o = await this.orderFor('shipped', C, p, 'cash');
    if (!this.paid(o)) await this.payCash(o);
    const linked = await this.waitOnec(C, o.id);
    if (!linked?.onec?.number) throw new Error('заказ не получил номер «1С»');
    o = linked;
    if (!['approved', 'awaiting_shipment', 'shipped', 'partially_returned', 'closed'].includes(o.status)) {
      await this.unit('onec approve', async () => {
        this.ctx.be.overlay.setOrderStatus(o.id, 'КВыполнению', true);
        await this.ctx.be.runtime.boss.send(ENTITY_QUEUES.order_status.queue, { entity: 'order_status', mode: 'incremental', trigger: 'schedule' }, { singletonKey: 'order_status' });
      });
      o = await this.until(async () => (await this.api('GET', `/orders/${o.id}`, { headers: C })).json, (x) => ['approved', 'awaiting_shipment'].includes(x?.status), 20000, 800);
    }
    let shipmentRef = null;
    if (!['shipped', 'partially_returned', 'closed'].includes(o?.status)) shipmentRef = (await this.ctx.control(`POST orders/${o.id}/ship`, {})).shipmentRef;
    return { orderId: o.id, number: o.publicNumber, onecNumber: linked.onec.number, shipmentRef };
  }

  async step_cancelled() {
    const p = (await this.products())[4];
    const S = await this.login('seller');
    const o = await this.orderFor('cancelled', S, p, 'cash');
    if (o.status === 'cancelled' || o.cancelRequested) return { orderId: o.id, number: o.publicNumber, status: o.status };
    const idemKey = crypto.randomUUID();
    const body = { reason: 'Покупатель передумал (демо-история)', reasonCode: 'customer_refused' };
    let r = await this.ctx.bridge.request('POST', `/api/v1/orders/${o.id}/cancel`, { headers: { ...S, 'Idempotency-Key': idemKey }, body, kind: 'seed' });
    if (r.status === 403 && r.json?.code === 'STEP_UP_REQUIRED') {
      const acc = this.s.accounts[SEED_ACCOUNTS.find((a) => a.key === 'seller').phone];
      const su = await this.api('POST', '/auth/step-up', { headers: S, body: { method: 'pin', operation: r.json?.operation ?? 'order.cancel.request.any', pin: acc.pin } });
      r = await this.ctx.bridge.request('POST', `/api/v1/orders/${o.id}/cancel`, { headers: { ...S, 'Idempotency-Key': idemKey, 'X-Step-Up-Token': su.json?.stepUpToken }, body, kind: 'seed' }); // check-secrets: allow — токен step-up из ответа API сида, не секрет; gitleaks:allow
    }
    if (r.status >= 400) throw new Error(`отмена заказа → ${r.status} ${r.json?.code ?? ''}`);
    return { orderId: o.id, number: o.publicNumber, status: r.json?.status ?? null };
  }

  /** Служебные учётки сида блокируются, их сессии отзываются (critic [20]). */
  async step_block() {
    const phones = SEED_ACCOUNTS.map((a) => a.phone);
    const r = await this.unit('block accounts', async () => {
      const admin = (await this.pool.query(`SELECT id FROM users WHERE phone_e164 = $1`, [STAFF[0].phone])).rows[0]?.id ?? null;
      const u = await this.pool.query(
        `UPDATE users SET status = 'blocked', blocked_at = now(), blocked_by_user_id = $2,
                block_reason = 'Служебная учётка демо-истории: заблокирована после создания истории заказов', updated_at = now()
          WHERE phone_e164 = ANY($1::text[]) AND status <> 'blocked' RETURNING id`,
        [phones, admin],
      );
      const s = await this.pool.query(
        `UPDATE sessions SET revoked_at = now(), revoke_reason = 'blocked', updated_at = now()
          WHERE revoked_at IS NULL AND user_id IN (SELECT id FROM users WHERE phone_e164 = ANY($1::text[])) RETURNING id`,
        [phones],
      );
      return { blocked: u.rows.length, sessionsRevoked: s.rows.length };
    });
    this.H = {};
    return r;
  }
}

const STEP_TEXT = {
  accounts: 'Вход служебных учёток «Демо-история»',
  cash: 'Заказ наличными: продавец → кассир',
  qr: 'Заказ с оплатой QR',
  credit: 'Продажа в долг (клиент «Долг в лимите»)',
  shipped: 'Заказ «К выполнению» и отгрузка',
  cancelled: 'Отменённый заказ',
  block: 'Блокировка служебных учёток',
};
