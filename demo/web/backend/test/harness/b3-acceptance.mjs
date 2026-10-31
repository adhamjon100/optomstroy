// Приёмка WP-B3 на собранном site/backend/backend.js в Node (worker_threads, storage 'memory'; «перезагрузка
// вкладки» — снимок каталога данных PGlite `dump` → новый воркер с loadDataDir, как тёплый старт на том же томе).
//
//   node demo/web/backend/test/harness/b3-acceptance.mjs [--sku 500] [--json <файл>] [--quiet]
//
// Фазы:
//   A. Холодный старт эпохи: ready ≤ 10 с; сид истории в фоне ≤ 60 с (служебные учётки заблокированы);
//      /sync/status overall=ok ≤ 60 с; 0.1.0+1 X-Platform windows → не 426; 0.0.9+1 → 426; приглашение 902 → продавец;
//      панель: QR «Оплатить сейчас» → received на long-poll; «Согласовать» → «Отгрузить» → shipped, возврат создаётся
//      и проводится «1С»; «Отклонить следующий заказ» → ручная привязка по номеру из external-ids; /check reject →
//      422 ONEC_REJECTED; клиент из POS; ожидающий QR и прерванный прогон синхронизации перед «перезагрузкой».
//   B. Тёплый старт с того же тома: ready ≤ 5 с; POST /auth/refresh 200; номер 1С следующий, ни одного missing,
//      ожидающий QR оплачивается, заявка на возврат и клиент из POS известны «1С»; восстановление после падения
//      (прогон closed, задачи retry); /sync/status ok ≤ 60 с.
//   C. «Сбросить демо» (новая эпоха, пустой том): старые данные недоступны, старый refresh → 401 SESSION_REVOKED.
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { startWorkerBackend } from './worker-harness.mjs';

const argv = process.argv.slice(2);
const arg = (k, d) => {
  const i = argv.indexOf(k);
  return i >= 0 ? argv[i + 1] : d;
};
const QUIET = argv.includes('--quiet');
const SKU = Number(arg('--sku', 500));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const T0 = Date.now();
const el = () => `${((Date.now() - T0) / 1000).toFixed(1)}s`.padStart(7);
const say = (...a) => {
  if (!QUIET) console.log(el(), ...a);
};
const VERSION = '0.1.0+1';
const crit = [];
const add = (criterion, met, evidence) => {
  crit.push({ criterion, met: !!met, evidence });
  console.log(`${met ? 'OK  ' : 'FAIL'} ${criterion}\n      ${String(evidence).slice(0, 600)}`);
};
const all5xx = [];

async function until(fn, ok, timeoutMs, every = 500) {
  const end = Date.now() + timeoutMs;
  for (;;) {
    const v = await fn();
    if (ok(v)) return { v, ok: true };
    if (Date.now() > end) return { v, ok: false };
    await sleep(every);
  }
}

/** Клиент API одного «устройства» (X-Device-Id) поверх моста. */
class Dev {
  constructor(be, platform = 'android', deviceId = crypto.randomUUID()) {
    this.be = be;
    this.platform = platform;
    this.deviceId = deviceId;
    this.token = null;
    this.refresh = null;
  }
  get base() {
    return { 'X-Device-Id': this.deviceId, 'X-App-Version': VERSION, 'X-Platform': this.platform, 'Accept-Language': 'ru' };
  }
  get H() {
    return { ...this.base, ...(this.token ? { Authorization: `Bearer ${this.token}` } : {}) };
  }
  async call(method, url, { body, headers = {}, idem = false, quiet = false } = {}) {
    const r = await this.be.api(method, `/api/v1${url}`, { headers: { ...this.H, ...headers, ...(idem ? { 'Idempotency-Key': crypto.randomUUID() } : {}) }, body });
    if (r.status >= 500) all5xx.push({ method, url: url.split('?')[0], status: r.status, code: r.json?.code });
    if (!quiet) say(String(r.status).padEnd(4), String(r.ms).padStart(5) + 'ms', method, url.split('?')[0].slice(0, 70), r.json?.code ?? '');
    return r;
  }
  async login(phone, pin = '715382') {
    let rq = await this.call('POST', '/auth/otp/request', { body: { phone, purpose: 'login_or_register', locale: 'ru' } });
    for (let i = 0; i < 4 && rq.status === 429; i++) {
      // пауза повторной отправки кода на тот же номер (OTP_RESEND_COOLDOWN_SECONDS демо — 10 с)
      await sleep(Math.min(12, Number(rq.headers?.['retry-after'] ?? 10) + 1) * 1000);
      rq = await this.call('POST', '/auth/otp/request', { body: { phone, purpose: 'login_or_register', locale: 'ru' } });
    }
    const vr = await this.call('POST', '/auth/otp/verify', { body: { challengeId: rq.json?.challengeId, code: '246810', device: { name: 'Node (b3)', platform: this.platform, appVersion: VERSION } } });
    this.token = vr.json?.accessToken; // check-secrets: allow — токен из ответа API в прогоне, не секрет; gitleaks:allow
    this.refresh = vr.json?.refreshToken;
    this.verify = vr.json;
    if (pin && vr.json?.kind !== 'customer') await this.call('POST', '/me/pin', { body: { newPin: pin }, idem: true });
    return vr;
  }
  async stepUp(operation) {
    const r = await this.call('POST', '/auth/step-up', { body: { method: 'pin', operation, pin: '715382' } });
    return r.json?.stepUpToken;
  }
}

async function products(d) {
  const r = await d.call('GET', '/catalog/products?limit=40&inStock=true');
  return (r.json?.items ?? []).filter((p) => !p.hasVariants && p.price && p.defaultVariantId);
}
async function sell(d, p, method, { customerId, expect } = {}) {
  let c = (await d.call('GET', '/cart')).json;
  if ((c?.items ?? []).length) c = (await d.call('DELETE', `/cart?rowVersion=${c.rowVersion}`)).json;
  c = (await d.call('PUT', `/cart/items/${p.defaultVariantId}`, { idem: true, body: { quantity: { value: '1', unitId: p.baseUnit.id, packagingId: null }, rowVersion: c.rowVersion, mode: 'set' } })).json;
  if (customerId) c = (await d.call('POST', '/cart/customer', { idem: true, body: { customerId, rowVersion: c.rowVersion } })).json;
  const pv = await d.call('POST', '/cart/checkout-preview', { idem: true, body: { cartId: c.id, cartRowVersion: c.rowVersion, paymentMethod: method, delivery: { method: 'pickup' }, receiver: { kind: 'customer' } } });
  const o = await d.call('POST', '/orders', {
    idem: true,
    body: {
      cartId: c.id,
      cartRowVersion: c.rowVersion,
      ...(pv.json?.previewToken ? { previewToken: pv.json.previewToken } : {}),
      ...(customerId ? { customerId } : {}),
      receiver: { kind: 'customer' },
      delivery: { method: 'pickup' },
      paymentMethod: method,
      items: [{ variantId: p.defaultVariantId, quantity: { value: '1', unitId: p.baseUnit.id, packagingId: null } }],
    },
  });
  if (expect !== undefined && o.status !== expect) say(`!! POST /orders ${method}: ${o.status} вместо ${expect}`, JSON.stringify(o.json).slice(0, 300));
  return o;
}
const payCash = (d, o) => d.call('POST', `/orders/${o.id}/payments`, { idem: true, body: { method: 'cash', receivedAmount: { amount: `${Math.ceil(Number(o.total.amount)) + 50}.00`, currency: 'KGS' } } });
const getOrder = async (d, id) => (await d.call('GET', `/orders/${id}`, { quiet: true })).json;
async function syncStatus(admin, timeoutMs) {
  const t = Date.now();
  const r = await until(async () => (await admin.call('GET', '/sync/status', { quiet: true })).json, (s) => s?.overall === 'ok', timeoutMs, 1000);
  return { ...r, ms: Date.now() - t, stale: (r.v?.entities ?? []).filter((e) => e.isStale).map((e) => e.entity), outbox: r.v?.outbox };
}

const report = { at: new Date().toISOString(), sku: SKU, phases: {} };
let be = null;
try {
  // ======================================================================== A. холодный старт эпохи
  say('== A: холодный старт');
  be = await startWorkerBackend({ sku: SKU, strict: true, initOpts: { generation: 1, buildId: 'b3-acceptance', epochKey: undefined }, onLog: (lv, m) => !QUIET && lv === 'error' && console.log('[worker error]', String(m).slice(0, 300)) });
  const tReady = Date.now();
  const A = (report.phases.A = { initMs: be.initMs, timings: be.ready.timings, ready: { ...be.ready, timings: undefined, roles: undefined } });
  say('ready', be.initMs, 'ms', JSON.stringify(be.ready.timings));
  add('A1 первый запуск эпохи: ready ≤ 10 с после загрузки файлов', be.initMs <= 10000 && be.ready.warm === false, `init→ready ${be.initMs} мс (${SKU} SKU), warm=${be.ready.warm}, storage ${be.ready.storage}; этапы ${JSON.stringify(be.ready.timings)}`);
  add('A1a ready.features содержит http:start, роли и телефоны для «Как войти»', be.ready.features?.includes('http:start') && be.ready.roles?.length >= 8, `features ${JSON.stringify(be.ready.features)}, roles ${be.ready.roles?.length}`);

  // MIN_APP_VERSION (critic [3])
  const win = new Dev(be, 'windows');
  const old = await be.api('POST', '/api/v1/auth/otp/request', { headers: { ...win.base, 'X-App-Version': '0.0.9+1' }, body: { phone: '+996777000906', purpose: 'login_or_register', locale: 'ru' } });
  const cashierWin = await win.login('+996777000906');
  const meWin = await win.call('GET', '/me');
  add('A2 MIN_APP_VERSION из pubspec: 0.1.0+1 с X-Platform windows принят, 0.0.9+1 → 426', old.status === 426 && meWin.status === 200 && cashierWin.status === 200, `0.0.9+1 → ${old.status} ${old.json?.code}; 0.1.0+1 windows: verify ${cashierWin.status}, /me ${meWin.status}`);

  const admin = new Dev(be, 'android');
  await admin.login('+996777000901');
  const cashier = new Dev(be, 'android');
  await cashier.login('+996777000906');

  // сид и /sync/status — параллельно, время от ready
  let seedMs = null;
  let ssMs = null;
  const [seedR, ss] = await Promise.all([
    until(async () => (await be.stats()).seed, (s) => s?.state === 'done' || s?.state === 'failed', 60000 - (Date.now() - tReady), 500).then((r) => ((seedMs = Date.now() - tReady), r)),
    syncStatus(admin, Math.max(1000, 60000 - (Date.now() - tReady))).then((r) => ((ssMs = Date.now() - tReady), r)),
  ]);
  A.seed = seedR.v;
  A.syncStatus = { overall: ss.v?.overall, msFromReady: ssMs, stale: ss.stale, outbox: ss.outbox };
  const blocked = await (async () => {
    const st = await be.control('GET state');
    return st.seed;
  })();
  const seedLogin = await be.api('POST', '/api/v1/auth/otp/request', { headers: admin.base, body: { phone: '+996777000981', purpose: 'login_or_register', locale: 'ru' } });
  const seedVerify = await be.api('POST', '/api/v1/auth/otp/verify', { headers: admin.base, body: { challengeId: seedLogin.json?.challengeId, code: '246810', device: { name: 'x', platform: 'android', appVersion: VERSION } } });
  const ordersSeed = await admin.call('GET', '/orders?limit=20');
  add('A3 сид истории завершается в фоне ≤ 60 с, служебные учётки «Демо-история» заблокированы', seedR.v?.state === 'done' && seedMs <= 60000 && seedVerify.status >= 400, `сид ${seedR.v?.state} за ${seedMs} мс от ready (${seedR.v?.ms ?? '?'} мс работы): ${JSON.stringify(seedR.v?.done ?? {}).slice(0, 400)}; вход 981 после сида → ${seedVerify.status} ${seedVerify.json?.code ?? ''}; заказов в истории ${ordersSeed.json?.items?.length ?? '?'}; ${blocked?.message ?? ''}`);
  add('A4 GET /sync/status overall=ok ≤ 60 с после старта', ss.ok, `overall ${ss.v?.overall} через ${A.syncStatus.msFromReady} мс от ready; устаревшие ${JSON.stringify(ss.stale)}; outbox ${JSON.stringify(ss.outbox)}`);

  // приглашение 902 (critic [2])
  const seller = new Dev(be, 'android');
  const sv = await seller.login('+996777000902');
  const sme = await seller.call('GET', '/me');
  const roles = JSON.stringify(sme.json?.roles ?? sme.json?.user?.roles ?? sme.json).slice(0, 200);
  add('A5 приглашение 902 действует: вход → роль «Продавец»', sv.status === 200 && /seller/.test(roles), `verify ${sv.status} (${sv.json?.kind ?? ''} ${sv.json?.roleSource ?? ''}); /me ${sme.status} ${roles}; приглашение при старте: ${be.ready.timings.invitation}`);

  const plist = await products(cashier);
  say('товаров в наличии', plist.length);

  // панель: QR «Оплатить сейчас» → received на следующем long-poll
  await be.control('POST qr/config', { paidAfterPolls: 0 });
  const oq = await sell(cashier, plist[5], 'qr_bakai');
  const pay = oq.json?.payments?.[0];
  let qrOk = false;
  let qrEv = '';
  if (pay?.id) {
    const st0 = await be.control('GET state');
    const pending = st0.qr.pending.find((x) => x.paymentId === pay.id);
    const t = Date.now();
    const lp = cashier.call('GET', `/payments/${pay.id}?wait=25`);
    await sleep(600);
    const me = await cashier.call('GET', '/me', { quiet: true });
    await be.control(`POST qr/${pay.id}/pay`, {});
    const r = await lp;
    let status = r.json?.status ?? r.json?.payment?.status;
    if (status !== 'received') status = (await cashier.call('GET', `/payments/${pay.id}?wait=25`)).json?.status;
    qrOk = !!pending && status === 'received';
    qrEv = `в «Ожидают оплаты»: ${!!pending}; long-poll → ${status} через ${Date.now() - t} мс; GET /me во время ожидания ${me.ms} мс; payload ${pay.qr?.payload}`;
  }
  add('A6 панель «Оплатить сейчас» → received на следующем long-poll; QR неплатёжный', qrOk && /^DEMO-NOT-PAYABLE\|/.test(pay?.qr?.payload ?? ''), qrEv);

  // «Согласовать» → «Отгрузить» → shipped, возврат доступен и проводится «1С»
  let shipEv = '';
  let shipOk = false;
  let retOk = false;
  let retEv = '';
  let retId = null;
  {
    const o = (await sell(cashier, plist[6], 'cash')).json;
    await payCash(cashier, o);
    const linked = await until(() => getOrder(cashier, o.id), (x) => !!x?.onec?.number, 25000, 400);
    await be.control(`POST orders/${o.id}/onec-status`, { status: 'КВыполнению', approved: true });
    const appr = await until(() => getOrder(cashier, o.id), (x) => ['approved', 'awaiting_shipment'].includes(x?.status), 20000, 500);
    const sh = await be.control(`POST orders/${o.id}/ship`, {});
    const after = await getOrder(cashier, o.id);
    shipOk = after?.status === 'shipped';
    shipEv = `1С ${linked.v?.onec?.number}; после «Согласовать» статус ${appr.v?.status}; «Отгрузить» → ${JSON.stringify(sh)}; заказ ${after?.status}`;
    // возврат: заявка в POS → «1С» → «Выполнить возврат» в панели
    const line = after?.items?.[0] ?? after?.lines?.[0];
    const unitId = line?.quantity?.unitId ?? plist[6].baseUnit.id;
    const cr = await cashier.call('POST', '/returns', { idem: true, body: { orderId: o.id, reasonCode: 'defect', items: [{ orderLineNo: line?.lineNo ?? 1, quantity: { value: '1', unitId, packagingId: null } }] } });
    retId = cr.json?.id;
    let sub = null;
    if (retId) {
      // Сверх порога согласования (10 000 сом) отправляет старший продавец со step-up (RET-009).
      const senior = new Dev(be, 'android');
      await senior.login('+996777000907');
      const tok = await senior.stepUp('return.approve');
      sub = await senior.call('POST', `/returns/${retId}/submit`, { idem: true, headers: { 'X-Step-Up-Token': tok }, body: { rowVersion: cr.json.rowVersion } });
      if (sub.status === 403 && sub.json?.code === 'STEP_UP_REQUIRED') {
        const t2 = await senior.stepUp(sub.json?.operation ?? 'return.submit');
        sub = await senior.call('POST', `/returns/${retId}/submit`, { idem: true, headers: { 'X-Step-Up-Token': t2 }, body: { rowVersion: cr.json.rowVersion } });
      }
      const st1 = await be.control('GET state');
      const offered = st1.orders.find((x) => x.id === o.id)?.actions ?? [];
      let done = null;
      let opRes = null;
      if (offered.includes('return')) {
        opRes = await be.control(`POST returns/${retId}/status`, { status: 'completed' });
        done = await until(async () => (await cashier.call('GET', `/returns/${retId}`, { quiet: true })).json, (x) => x?.status === 'completed', 30000, 800);
      }
      const ordAfter = await getOrder(cashier, o.id);
      retOk = cr.status === 201 && sub?.status === 200 && offered.includes('return') && done?.ok;
      retEv = `POST /returns → ${cr.status}; submit (старший) → ${sub?.status} ${sub?.json?.code ?? sub?.json?.status ?? ''}; панель предлагает «Выполнить возврат»: ${offered.includes('return')} (${JSON.stringify(offered)}); оператор «1С» → ${JSON.stringify(opRes?.onec ?? opRes)?.slice(0, 120)}; заявка POS ${done?.v?.status ?? '—'}; заказ ${ordAfter?.status}`;
    } else retEv = `POST /returns → ${cr.status} ${JSON.stringify(cr.json).slice(0, 300)}`;
  }
  add('A7 панель «Согласовать» → «Отгрузить» → shipped', shipOk, shipEv);
  add('A8 после «Отгрузить» возврат доступен: заявка создаётся, «1С» её принимает и проводит', retOk, retEv);

  // «Отклонить следующий заказ» → ручная привязка по номеру «1С» (external-ids, critic [9])
  let linkOk = false;
  let linkEv = '';
  {
    await be.control('POST onec/orders/mode', { mode: 'reject', failNext: 1 });
    const o = (await sell(cashier, plist[7], 'cash')).json;
    const failed = await until(() => getOrder(cashier, o.id), (x) => x?.status === 'submit_failed', 25000, 500);
    const st = await be.control('GET state');
    const manual = st.orders.find((x) => x.id === o.id)?.manualOnecNumber;
    const tok = await admin.stepUp('order.onec_link');
    const lk = await admin.call('POST', `/orders/${o.id}/onec-link`, { idem: true, headers: tok ? { 'X-Step-Up-Token': tok } : {}, body: { onecNumber: manual ?? 'ОС00-000000', reason: 'Заказ заведён в 1С вручную (демо)' } });
    const after = await getOrder(admin, o.id);
    linkOk = failed.ok && !!manual && lk.status === 200 && after?.onec?.number === manual;
    linkEv = `после отказа «1С» статус ${failed.v?.status}; номер ручного документа ${manual}; onec-link → ${lk.status} ${lk.json?.code ?? ''}; заказ 1С ${after?.onec?.number} (${after?.onecSyncState ?? after?.onec?.syncState ?? ''})`;
  }
  add('A9 «Отклонить следующий заказ» → ручная привязка: external-ids имитатора находит документ', linkOk, linkEv);

  // /check: режим «отклонять» → ONEC_REJECTED (critic [9])
  {
    await be.control('POST onec/check', { mode: 'reject' });
    const r = await sell(cashier, plist[8], 'cash');
    await be.control('POST onec/check', { mode: 'ok' });
    const r2 = await sell(cashier, plist[8], 'cash');
    add('A10 переключатель /pos/v1/check в панели: reject → 422 ONEC_REJECTED, ok → 201', r.status === 422 && r.json?.code === 'ONEC_REJECTED' && r2.status === 201, `reject → ${r.status} ${r.json?.code}; ok → ${r2.status}`);
  }

  // клиент из POS (журнал синтетики) и ожидающий QR перед «перезагрузкой»
  const newPhone = `+9967770009${String(Math.floor(Math.random() * 90) + 10)}`;
  const cc = await cashier.call('POST', '/customers', { idem: true, body: { name: 'Клиент из POS (тест)', customerType: 'individual', phones: [newPhone] } });
  const custInOnec = await until(async () => {
    const r = await be.control('fake', { method: 'GET', path: '/__fake/cashier/state' });
    return r.body?.customers;
  }, (n) => n > 0, 1, 100);
  const custSynced = await until(async () => (await be.stats()).onec.byPath['POST /pos/v1/customers'] ?? 0, (n) => n > 0, 20000, 500);
  say('клиент из POS', cc.status, 'POST /pos/v1/customers', custSynced.v, 'клиентов в «1С»', custInOnec.v);
  await be.control('POST qr/config', { paidAfterPolls: 0 });
  const oqp = (await sell(cashier, plist[9], 'qr_bakai')).json;
  const pendingPay = oqp?.payments?.[0]?.id;
  await until(() => getOrder(cashier, oqp.id), (x) => !!x?.onec?.number, 20000, 400);
  const stBefore = await be.control('GET state');
  const orderSeqBefore = stBefore.onec.orderSeq;
  const ordersBefore = stBefore.orders.filter((x) => x.onecNumber).map((x) => ({ id: x.id, onec: x.onecNumber }));
  // прерванный прогон синхронизации: ручной запуск и снимок тома сразу
  const su = await admin.stepUp('sync.run.full');
  const run = await admin.call('POST', '/sync/runs', { idem: true, headers: { 'X-Step-Up-Token': su }, body: { entity: 'receivables', mode: 'incremental' } });
  // снимок тома, когда задача pg-boss уже взята в работу (active) — как F5 посреди прогона
  const running = await until(async () => {
    const g = (await be.stats()).gate;
    return [g.active?.label, ...g.queued.map((x) => x.label)].some((l) => /job sync\.manual/.test(l ?? '')) && /job sync\.manual/.test(g.active?.label ?? '') ? 'running' : 'waiting';
  }, (x) => x === 'running', 8000, 15);
  say('прогон перед снимком:', running.v);
  const statsA = await be.stats();
  A.stats = { gate: statsA.gate.stats, pg: { maxWaitMs: statsA.pg.maxWaitMs, waitsOver3s: statsA.pg.waitsOver3s, outsideWhitelist: statsA.pg.outsideWhitelist, nestedBeginForeign: statsA.pg.nestedBeginForeign }, storage: statsA.storage, bridge: statsA.bridge, onec: statsA.onec.overlay };
  const dump = await be.rpc({ type: 'dump' }, 120000);
  const dumpBytes = dump.data?.byteLength ?? 0;
  say('dump', dumpBytes, 'B; ручной прогон', run.status, run.json?.id);
  const oldRefresh = cashier.refresh;
  const oldDevice = cashier.deviceId;
  const oldOrderId = ordersBefore[0]?.id;
  await be.close();
  be = null;

  // ======================================================================== B. тёплый старт с того же тома
  say('== B: тёплый старт (тот же том)');
  be = await startWorkerBackend({ sku: SKU, strict: true, initOpts: { generation: 2, buildId: 'b3-acceptance-2', loadDataDir: dump.data } });
  const tReadyB = Date.now();
  const B = (report.phases.B = { initMs: be.initMs, timings: be.ready.timings, warm: be.ready.warm });
  say('ready (warm)', be.initMs, 'ms', JSON.stringify(be.ready.timings));
  const dev = new Dev(be, 'android', oldDevice);
  const rf = await dev.call('POST', '/auth/refresh', { body: { refreshToken: oldRefresh } });
  dev.token = rf.json?.accessToken; // check-secrets: allow — токен из ответа API в прогоне, не секрет; gitleaks:allow
  dev.refresh = rf.json?.refreshToken;
  const meB = await dev.call('GET', '/me');
  add('B1 повторный запуск: ready ≤ 5 с, сессия жива (POST /auth/refresh 200)', be.ready.warm === true && be.initMs <= 5000 && rf.status === 200 && meB.status === 200, `warm=${be.ready.warm}, init→ready ${be.initMs} мс; refresh → ${rf.status}; /me → ${meB.status}; этапы ${JSON.stringify(be.ready.timings)}`);
  const adminB = new Dev(be, 'android');
  await adminB.login('+996777000901', null);
  const ssB2 = await syncStatus(adminB, Math.max(1000, 60000 - (Date.now() - tReadyB)));
  B.syncStatus = { overall: ssB2.v?.overall, msFromReady: Date.now() - tReadyB, stale: ssB2.stale };
  const rec = be.ready.timings.recovery ?? {};
  add('B2 восстановление после «падения процесса» до WorkerRuntime: прогоны закрыты, задачи pg-boss повторяются, аренда outbox снята', rec.runsClosed >= 1 && (running.v !== 'running' || rec.jobsRetried + rec.jobsFailed >= 1), `recovery ${JSON.stringify(rec)}; ручной прогон перед снимком: ${run.status}, статус ${running.v}`);
  const rst = be.ready.timings.fakeRestore ?? {};
  const rcn = be.ready.timings.fakeReconcile ?? {};
  // новый заказ → следующий номер «1С»
  const plistB = await products(dev);
  const ob = (await sell(dev, plistB[10] ?? plistB[0], 'cash')).json;
  const obl = await until(() => getOrder(dev, ob.id), (x) => !!x?.onec?.number, 25000, 400);
  const nb = Number(/(\d+)$/.exec(obl.v?.onec?.number ?? '')?.[1] ?? 0);
  const repeated = ordersBefore.some((x) => x.onec === obl.v?.onec?.number);
  add('B3 после перезагрузки номера «1С» продолжаются (не повторяются)', nb === orderSeqBefore + 1 && !repeated, `до: orderSeq ${orderSeqBefore}; новый заказ ${obl.v?.onec?.number}; повтор ${repeated}; восстановлено ${JSON.stringify(rst)}; сверка ${JSON.stringify(rcn)}`);
  // синхронизация статусов: ни одного missing
  await be.control(`POST orders/${ob.id}/onec-status`, { status: 'КВыполнению', approved: true });
  await until(() => getOrder(dev, ob.id), (x) => ['approved', 'awaiting_shipment'].includes(x?.status), 20000, 500);
  const stB = await be.control('GET state');
  const missing = stB.orders.filter((x) => x.syncState === 'missing');
  const oldO = oldOrderId ? await getOrder(dev, oldOrderId) : null;
  add('B4 прежние заказы не помечаются missing после синхронизации статусов', missing.length === 0 && (!oldO || oldO.onecSyncState !== 'missing'), `missing ${missing.length} из ${stB.orders.length}; старый заказ ${oldO?.publicNumber} sync ${oldO?.onecSyncState ?? oldO?.onec?.syncState ?? '—'}`);
  // ожидающий QR
  let qrB = '—';
  if (pendingPay) {
    const pend = stB.qr.pending.find((x) => x.paymentId === pendingPay);
    await be.control(`POST qr/${pendingPay}/pay`, {});
    const r = await until(async () => (await dev.call('GET', `/payments/${pendingPay}?wait=10`)).json, (x) => (x?.status ?? x?.payment?.status) === 'received', 25000, 200);
    qrB = `в «Ожидают оплаты» после перезагрузки: ${!!pend} (опросов ${pend?.polls}); «Оплатить сейчас» → ${r.v?.status ?? r.v?.payment?.status}`;
    add('B5 ожидающий QR переживает перезагрузку и оплачивается', !!pend && r.ok, qrB);
  }
  const fs = await be.control('fake', { method: 'GET', path: '/__fake/cashier/state' });
  const stats404 = (await be.stats()).onec.byStatus['404'] ?? 0;
  const retStateB = retId ? stB.returns.find((x) => x.externalId === retId) : null;
  add('B6 состояние «1С» после перезагрузки: заявка на возврат и клиент из POS известны, 404 «1С» нет', (!retId || retStateB?.inOnec) && stats404 === 0, `возврат ${retId ? `${retStateB?.status} inOnec=${retStateB?.inOnec}` : '—'}; клиентов в «1С» ${fs.body?.customers} (до ${custInOnec.v}); журнал синтетики ${rst.journal} оп., ошибок ${rst.journalErrors}; ответов 404 «1С» ${stats404}; lastAck ${fs.body?.lastAck}`);
  const ssEnd = await syncStatus(adminB, 1);
  add('B7 GET /sync/status overall=ok ≤ 60 с после тёплого старта (и в конце фазы)', ssB2.ok && ssEnd.v?.overall === 'ok', `overall ${ssB2.v?.overall} через ${B.syncStatus.msFromReady} мс от ready; устаревшие ${JSON.stringify(ssB2.stale)}; в конце фазы ${ssEnd.v?.overall} ${JSON.stringify(ssEnd.stale)}`);
  const statsB = await be.stats();
  B.stats = { gate: statsB.gate.stats, pg: { maxWaitMs: statsB.pg.maxWaitMs, waitsOver3s: statsB.pg.waitsOver3s, outsideWhitelist: statsB.pg.outsideWhitelist, nestedBeginForeign: statsB.pg.nestedBeginForeign }, storage: statsB.storage, bridge: statsB.bridge };
  await be.close();
  be = null;

  // ======================================================================== B'. тот же том, состояние «1С» не сохранилось
  // Сверка с PGlite одна (без demo_meta 'fake'): номера 1С продолжаются от orders.onec_number, заказы и ожидающий QR
  // заводятся в имитаторе заново.
  say("== B': тот же том без сохранённого состояния «1С» (только сверка с PGlite)");
  be = await startWorkerBackend({ sku: SKU, strict: true, initOpts: { generation: 2, buildId: 'b3-acceptance-2b', loadDataDir: dump.data, testDropFakeState: true, seed: false } });
  {
    const rc = be.ready.timings.fakeReconcile ?? {};
    const d2 = new Dev(be, 'android');
    await d2.login('+996777000907');
    const pl2 = await products(d2);
    const o2 = (await sell(d2, pl2[11] ?? pl2[0], 'cash')).json;
    const l2 = await until(() => getOrder(d2, o2.id), (x) => !!x?.onec?.number, 25000, 400);
    const n2 = Number(/(\d+)$/.exec(l2.v?.onec?.number ?? '')?.[1] ?? 0);
    await be.control(`POST orders/${o2.id}/onec-status`, { status: 'КВыполнению', approved: true });
    await until(() => getOrder(d2, o2.id), (x) => ['approved', 'awaiting_shipment'].includes(x?.status), 20000, 500);
    const st2 = await be.control('GET state');
    const miss2 = st2.orders.filter((x) => x.syncState === 'missing').length;
    // Ожидающий QR: заведён в «1С» заново, опрос идёт без 404 (без сохранённого paidAfterPolls имитатор оплачивает сам).
    const fst = await be.control('fake', { method: 'GET', path: '/__fake/state' });
    const fq = pendingPay ? (fst.body?.qr ?? []).find((x) => x.externalId === pendingPay) : null;
    const p2 = pendingPay ? (await d2.call('GET', `/payments/${pendingPay}`)).json : null;
    const s404 = (await be.stats()).onec.byStatus['404'] ?? 0;
    add("B'1 без сохранённого состояния «1С»: номера продолжаются от PGlite, заказы не missing, QR заведён заново", n2 === orderSeqBefore + 1 && miss2 === 0 && (!pendingPay || !!fq) && s404 === 0, `сверка ${JSON.stringify(rc)}; новый заказ ${l2.v?.onec?.number} (до перезагрузки orderSeq ${orderSeqBefore}); missing ${miss2}; QR в «1С»: ${fq?.status ?? '—'} (опросов ${fq?.polls ?? '—'}), POS ${p2?.status ?? p2?.payment?.status ?? '—'}; ответов 404 «1С» ${s404}`);
    await be.close();
    be = null;
  }

  // ======================================================================== C. сброс демо
  say('== C: сброс (новая эпоха, пустой том)');
  be = await startWorkerBackend({ sku: SKU, strict: true, initOpts: { generation: 3, buildId: 'b3-acceptance-3', seed: false } });
  report.phases.C = { initMs: be.initMs, warm: be.ready.warm };
  const devC = new Dev(be, 'android', oldDevice);
  const rfC = await devC.call('POST', '/auth/refresh', { body: { refreshToken: dev.refresh ?? oldRefresh } });
  await devC.login('+996777000906');
  const oldC = oldOrderId ? await devC.call('GET', `/orders/${oldOrderId}`) : null;
  const listC = await devC.call('GET', '/orders?limit=50');
  add('C1 после сброса старые данные недоступны, старый refresh → 401 SESSION_REVOKED', rfC.status === 401 && rfC.json?.code === 'SESSION_REVOKED' && (!oldC || oldC.status === 404) && (listC.json?.items ?? []).length === 0, `refresh → ${rfC.status} ${rfC.json?.code}; старый заказ → ${oldC?.status}; заказов ${listC.json?.items?.length}; warm=${be.ready.warm}`);
  await be.close();
  be = null;
  add('0 ответов 5xx во всех фазах', all5xx.length === 0, JSON.stringify(all5xx).slice(0, 500));
  for (const [k, ph] of Object.entries(report.phases)) if (ph.stats) add(`${k}: 0 ожиданий замка > 3 с, 0 подсадок вне белого списка, 0 BEGIN из чужой единицы, 0 удержаний слота > 3 с`, ph.stats.pg.waitsOver3s === 0 && ph.stats.pg.outsideWhitelist === 0 && ph.stats.pg.nestedBeginForeign === 0 && ph.stats.gate.holdsOver3s === 0 && ph.stats.gate.queueWaitsOver3s === 0, `pg ${JSON.stringify(ph.stats.pg)}; gate holds>3s ${ph.stats.gate.holdsOver3s}, queue>3s ${ph.stats.gate.queueWaitsOver3s}, maxHold ${ph.stats.gate.maxHoldMs} мс, endHookErrors ${ph.stats.gate.endHookErrors ?? 0}`);
} catch (e) {
  console.error('B3 ACCEPTANCE FAILED', e?.stack ?? e);
  add('прогон без исключений', false, String(e?.stack ?? e).slice(0, 800));
  try {
    if (be) {
      const logs = await be.logs(80);
      console.error(logs.filter((l) => / (ERROR|WARN) /.test(l)).slice(-30).join('\n'));
    }
  } catch {
    /* ignore */
  }
} finally {
  if (be) await be.close().catch(() => undefined);
}
report.acceptance = crit;
report.totalSec = (Date.now() - T0) / 1000;
const out = arg('--json', null);
if (out) {
  mkdirSync(dirname(resolve(out)), { recursive: true });
  writeFileSync(out, JSON.stringify(report, null, 1));
}
console.log(`\n==== WP-B3: ${crit.filter((c) => c.met).length}/${crit.length} за ${report.totalSec.toFixed(1)} с`);
process.exit(crit.every((c) => c.met) ? 0 : 1);
