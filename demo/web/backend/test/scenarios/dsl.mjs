// DSL шагов API для сценариев WP-T1 (plan §4 WP-T1 «scenarios/*.mjs»). Работает с любым бэкендом с протоколом
// моста worker-harness.mjs: собранным backend.js и эталоном native-runner.mjs.
//
// Каждый запрос шага записывается (ctx.rec): сценарий, имя шага, метод, URL, статус, нужные заголовки, JSON-тело,
// размер и сигнатура (PDF) — для проверки по OpenAPI (contract/openapi-validate.mjs), дифференциального сравнения
// бандл ↔ эталон (differential.test.mjs) и учёта покрытия операций. Имена шагов детерминированы: одинаковый
// сценарий даёт одинаковую последовательность ключей «сценарий / шаг #n» на обоих бэкендах.
//
// Ожидаемый статус шага — expect (число, массив или функция); без expect ожидается 2xx/3xx. Неожиданный статус
// и любой 5xx — провал проверки «0 неожиданных статусов / 0 ответов 5xx».
import { readFileSync } from 'node:fs';
import { SITE } from '../harness/worker-harness.mjs';

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const APP_VERSION = JSON.parse(readFileSync(`${SITE}/backend/build.json`, 'utf8')).appVersion;
export const OTP = '246810';
export const PIN = '715382';
/** Заголовки ответа, которые записываются (остальные — шум транспорта). */
const KEEP_HEADERS = ['content-type', 'etag', 'cache-control', 'idempotent-replayed', 'retry-after', 'x-min-app-version', 'x-recommended-app-version', 'content-disposition', 'x-data-as-of', 'content-language', 'location'];
const MAX_JSON_RECORD = 400_000;

/** Ожидаемый ли статус. expect: undefined (2xx/3xx) | число | массив | (status, r) => bool. */
export function statusOk(status, expect, r) {
  if (expect === undefined) return status >= 200 && status < 400;
  if (typeof expect === 'function') return !!expect(status, r);
  if (Array.isArray(expect)) return expect.includes(status);
  return status === expect;
}

export function createCtx(be, { log = () => {}, label = 'be' } = {}) {
  const ctx = {
    be,
    label,
    log,
    rec: [],
    checks: [],
    scenario: '—',
    counts: new Map(),
    t0: Date.now(),
    begin(name) {
      ctx.scenario = name;
      log(`\n== [${label}] ${name}`);
    },
    key(step) {
      const k = `${ctx.scenario} / ${step}`;
      const n = (ctx.counts.get(k) ?? 0) + 1;
      ctx.counts.set(k, n);
      return n === 1 ? k : `${k} #${n}`;
    },
    check(name, ok, evidence) {
      const c = { scenario: ctx.scenario, name, ok: !!ok, evidence: typeof evidence === 'string' ? evidence : JSON.stringify(evidence ?? null) };
      ctx.checks.push(c);
      log(`${ok ? '  OK  ' : '  FAIL'} ${name}${c.evidence && c.evidence !== 'null' ? ` — ${c.evidence.slice(0, 400)}` : ''}`);
      return !!ok;
    },
    record(step, method, url, r, expect, extra = {}) {
      const headers = {};
      for (const h of KEEP_HEADERS) if (r.headers?.[h] !== undefined) headers[h] = r.headers[h];
      const rec = {
        key: ctx.key(step),
        scenario: ctx.scenario,
        step,
        method,
        url,
        path: String(url).split('?')[0],
        status: r.status,
        headers,
        json: r.json !== undefined && (r.size ?? 0) <= MAX_JSON_RECORD ? r.json : undefined,
        size: r.size ?? 0,
        magic: r.magic,
        ms: r.ms,
        expect: expect === undefined ? undefined : typeof expect === 'function' ? 'fn' : expect,
        ok: statusOk(r.status, expect, r),
        ...extra,
      };
      ctx.rec.push(rec);
      if (!rec.ok || r.status >= 500) log(`  !! ${rec.key}: ${method} ${rec.path} → ${r.status} ${r.json?.code ?? ''} ${r.json?.detail ?? r.json?.title ?? ''} (ожидалось ${JSON.stringify(rec.expect ?? '2xx')})`);
      return rec;
    },
    async panel(action, args = {}) {
      return be.control(action, args);
    },
    /** Дождаться тишины фона (нет активной и ждущих единиц работы ~0,5 с) — перед списками, зависящими от задач pg-boss. */
    async settle({ timeoutMs = 20000 } = {}) {
      const end = Date.now() + timeoutMs;
      let quiet = 0;
      while (Date.now() < end && quiet < 3) {
        const g = (await be.stats()).gate;
        quiet = !g.active && g.queued.length === 0 && g.released.length === 0 ? quiet + 1 : 0;
        await sleep(150);
      }
      return quiet >= 3;
    },
    /** Повторять fn (без записи), пока ok; последний результат — в ctx.lastPoll. */
    async until(fn, ok, { timeoutMs = 30000, everyMs = 500 } = {}) {
      const end = Date.now() + timeoutMs;
      for (;;) {
        const v = await fn();
        if (ok(v)) return { v, ok: true };
        if (Date.now() > end) return { v, ok: false };
        await sleep(everyMs);
      }
    },
    dev(platform = 'windows', opts = {}) {
      return new Session(ctx, platform, opts);
    },
  };
  return ctx;
}

export class Session {
  constructor(ctx, platform = 'windows', { deviceId = crypto.randomUUID(), name = 'session', version = APP_VERSION } = {}) {
    this.ctx = ctx;
    this.platform = platform; // null — без X-Platform (Flutter web на macOS и т. п.)
    this.deviceId = deviceId;
    this.name = name;
    this.version = version;
    this.token = null;
    this.refresh = null;
    this.verify = null;
    this.pin = PIN;
    this.stepUps = new Map();
  }
  baseHeaders() {
    const h = { 'X-Device-Id': this.deviceId, 'X-App-Version': this.version, 'Accept-Language': 'ru', 'X-Request-Id': crypto.randomUUID() };
    if (this.platform) h['X-Platform'] = this.platform;
    if (this.token) h.Authorization = `Bearer ${this.token}`;
    return h;
  }
  /** Запрос шага. o: { body, headers, idem (true | ключ), stepUp (токен), expect, record=true, quiet, raw } */
  async call(step, method, url, o = {}) {
    const headers = { ...this.baseHeaders(), ...(o.headers ?? {}) };
    if (o.noAuth) delete headers.Authorization;
    if (o.idem) headers['Idempotency-Key'] = o.idem === true ? crypto.randomUUID() : o.idem;
    if (o.stepUp) headers['X-Step-Up-Token'] = o.stepUp;
    const fullUrl = url.startsWith('/api/') || url === '/health' || url.startsWith('/health') ? url : `/api/v1${url}`;
    let r = await this.ctx.be.api(method, fullUrl, { headers, body: o.body });
    // как AuthInterceptor приложения: 401 UNAUTHENTICATED/TOKEN_STALE → POST /auth/refresh → один повтор
    // (включается явно: долгие прогоны soak живут дольше access-токена, 15 мин)
    if (this.autoRefresh && r.status === 401 && ['UNAUTHENTICATED', 'TOKEN_STALE'].includes(r.json?.code) && this.refresh && !o.noAuth) {
      const rf = await this.ctx.be.api('POST', '/api/v1/auth/refresh', { headers: { ...this.baseHeaders(), Authorization: undefined }, body: { refreshToken: this.refresh } });
      this.refreshes = (this.refreshes ?? 0) + 1;
      if (rf.status === 200 && rf.json?.accessToken) {
        this.token = rf.json.accessToken; // check-secrets: allow — токен из ответа API в прогоне, не секрет; gitleaks:allow
        this.refresh = rf.json.refreshToken ?? this.refresh;
        r = await this.ctx.be.api(method, fullUrl, { headers: { ...headers, Authorization: `Bearer ${this.token}` }, body: o.body });
      }
    }
    r.idem = headers['Idempotency-Key'];
    if (o.record !== false) this.ctx.record(`${this.name}: ${step}`, method, fullUrl, r, o.expect);
    return r;
  }
  /** Повторять запрос (без записи), пока ok(r); последний ответ записывается шагом step. */
  async poll(step, method, url, ok, { timeoutMs = 30000, everyMs = 500, expect, ...o } = {}) {
    const end = Date.now() + timeoutMs;
    let r;
    for (;;) {
      r = await this.call(step, method, url, { ...o, record: false });
      if (ok(r) || Date.now() > end) break;
      await sleep(everyMs);
    }
    const fullUrl = url.startsWith('/api/') || url.startsWith('/health') ? url : `/api/v1${url}`;
    this.ctx.record(`${this.name}: ${step}`, method, fullUrl, r, expect);
    r.pollOk = ok(r);
    return r;
  }
  /** OTP-вход тестовым кодом; сотруднику без PIN — первый PIN (без step-up). → ответ verify. */
  async login(phone, { setPin = true, pin = PIN, label } = {}) {
    const L = label ?? `login ${phone}`;
    let rq = await this.call(`${L} otp/request`, 'POST', '/auth/otp/request', { body: { phone, purpose: 'login_or_register', locale: 'ru' }, expect: [202, 429] });
    for (let i = 0; i < 4 && rq.status === 429; i++) {
      await sleep(Math.min(12, Number(rq.headers?.['retry-after'] ?? rq.json?.retryAfter ?? 10) + 1) * 1000);
      rq = await this.call(`${L} otp/request (после паузы)`, 'POST', '/auth/otp/request', { body: { phone, purpose: 'login_or_register', locale: 'ru' }, expect: [202, 429] });
    }
    this.challengeId = rq.json?.challengeId;
    const vr = await this.call(`${L} otp/verify`, 'POST', '/auth/otp/verify', {
      body: { challengeId: rq.json?.challengeId, code: OTP, device: { name: `${this.name} (WP-T1)`, platform: this.platform ?? 'windows', appVersion: this.version } },
      expect: (s) => s === 200 || s === 403,
    });
    this.verify = vr.json;
    if (vr.json?.accessToken) {
      this.token = vr.json.accessToken; // check-secrets: allow — токен из ответа API в прогоне, не секрет; gitleaks:allow
      this.refresh = vr.json.refreshToken;
      this.sid = vr.json.sid ?? vr.json.session?.id;
    }
    this.pin = pin;
    if (setPin && vr.json?.status === 'authenticated' && vr.json?.user?.kind === 'staff' && (vr.json?.nextStep === 'set_pin' || vr.json?.security?.pinSet === false)) {
      await this.call(`${L} me/pin (первый PIN)`, 'POST', '/me/pin', { body: { newPin: pin }, idem: true, expect: 204 });
    }
    return vr;
  }
  /** Регистрация покупателя после verify registration_required. */
  async registerCustomer({ fullName, birthYear = 1990, pin = '583921', label = 'registration' } = {}) {
    const r = await this.call(`${label} registration/complete`, 'POST', '/registration/complete', {
      idem: true,
      body: {
        registrationToken: this.verify?.registrationToken, // check-secrets: allow — имя поля, не секрет
        fullName,
        birthYear,
        security: { pin },
        consents: [{ kind: 'personal_data', version: '2026-10-01' }],
        device: { name: `${this.name} (WP-T1)`, platform: this.platform ?? 'windows', appVersion: this.version },
      },
      expect: 201,
    });
    if (r.json?.accessToken) {
      this.token = r.json.accessToken; // check-secrets: allow — токен из ответа API в прогоне, не секрет; gitleaks:allow
      this.refresh = r.json.refreshToken;
    }
    this.pin = pin;
    return r;
  }
  async stepUp(operation, { label } = {}) {
    const r = await this.call(label ?? `step-up ${operation}`, 'POST', '/auth/step-up', { body: { method: 'pin', operation, pin: this.pin }, expect: 200 });
    return r.json?.stepUpToken;
  }
  /**
   * Действие со step-up как у приложения: без токена → 403 STEP_UP_REQUIRED {stepUp.operation} → POST /auth/step-up
   * → повтор с X-Step-Up-Token и ТЕМ ЖЕ Idempotency-Key. → { first, final, operation }.
   */
  async withStepUp(step, method, url, { body, expect, idem = true, ...o } = {}) {
    const key = idem === true ? crypto.randomUUID() : idem || undefined;
    const first = await this.call(`${step} (без step-up)`, method, url, { ...o, body, idem: key, expect: (s, r) => s === 403 || statusOk(s, expect, r) });
    if (!(first.status === 403 && first.json?.code === 'STEP_UP_REQUIRED')) return { first, final: first, operation: null };
    const operation = first.json?.stepUp?.operation;
    const tok = await this.stepUp(operation, { label: `${step}: step-up ${operation}` });
    const final = await this.call(`${step} (со step-up)`, method, url, { ...o, body, idem: key, stepUp: tok, expect });
    return { first, final, operation, token: tok };
  }
}

// ---------------------------------------------------------------- помощники предметной области
/** Простые товары в наличии с ценой (детерминированный порядок каталога). */
export async function sellable(s, { limit = 100, maxPrice = Infinity, step = 'каталог: товары в наличии' } = {}) {
  const r = await s.call(step, 'GET', `/catalog/products?limit=${limit}&inStock=true&sort=price:asc`);
  return (r.json?.items ?? []).filter((p) => !p.hasVariants && p.defaultVariantId && p.baseUnit?.id && p.price && Number(p.price?.price?.amount ?? p.price?.amount ?? 0) > 0 && Number(p.price?.price?.amount ?? p.price?.amount ?? 0) <= maxPrice);
}
export const qty = (p, value = '1') => ({ value, unitId: p.baseUnit.id, packagingId: null });

/** Корзина: очистить и положить товары [{p, q}] (или один p). → корзина. */
export async function fillCart(s, items, { label = 'корзина' } = {}) {
  let c = (await s.call(`${label}: GET /cart`, 'GET', '/cart')).json;
  if ((c?.items ?? []).length) c = (await s.call(`${label}: очистить`, 'DELETE', `/cart?rowVersion=${c.rowVersion}`)).json;
  if (c?.customer || c?.customerId) c = (await s.call(`${label}: снять клиента`, 'DELETE', '/cart/customer')).json;
  const list = Array.isArray(items) ? items : [{ p: items, q: '1' }];
  for (const [i, it] of list.entries()) {
    const put = await s.call(`${label}: PUT товар ${i + 1}`, 'PUT', `/cart/items/${it.p.defaultVariantId}`, { idem: true, body: { quantity: qty(it.p, it.q ?? '1'), rowVersion: c.rowVersion, mode: 'set' } });
    c = put.json ?? c;
  }
  return c;
}
export function orderBody(cart, items, paymentMethod, extra = {}) {
  const list = Array.isArray(items) ? items : [{ p: items, q: '1' }];
  return {
    cartId: cart.id,
    cartRowVersion: cart.rowVersion,
    receiver: { kind: 'customer' },
    delivery: { method: 'pickup' },
    paymentMethod,
    items: list.map((it) => ({ variantId: it.p.defaultVariantId, quantity: qty(it.p, it.q ?? '1') })),
    ...extra,
  };
}
/** Корзина → checkout-preview → POST /orders. → { cart, preview, order }. */
export async function placeOrder(s, items, method, { customerId, label = 'заказ', expect, extra = {}, previewExpect, idem = true } = {}) {
  let cart = await fillCart(s, items, { label });
  if (customerId) cart = (await s.call(`${label}: клиент в корзину`, 'POST', '/cart/customer', { idem: true, body: { customerId, rowVersion: cart.rowVersion } })).json ?? cart;
  const preview = await s.call(`${label}: checkout-preview ${method}`, 'POST', '/cart/checkout-preview', {
    idem: true,
    expect: previewExpect,
    body: { cartId: cart.id, cartRowVersion: cart.rowVersion, paymentMethod: method, delivery: { method: 'pickup' }, receiver: { kind: 'customer' }, ...(extra.creditOverride ? { creditOverride: extra.creditOverride } : {}) },
  });
  const body = orderBody(cart, items, method, { ...(preview.json?.previewToken ? { previewToken: preview.json.previewToken } : {}), ...(customerId ? { customerId } : {}), ...extra });
  const order = await s.call(`${label}: POST /orders ${method}`, 'POST', '/orders', { idem, body, expect: expect ?? [201, 202] });
  return { cart, preview, order, body };
}
export const cashAmount = (o) => ({ amount: `${Math.ceil(Number(o.total?.amount ?? 0))}.00`, currency: 'KGS' });
