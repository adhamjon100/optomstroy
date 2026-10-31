// Обязательные сценарии критика для WP-T1 (D:/optomstroy/.tmp/web_demo/critic.json [0], [1], [2], [3], [8], [12])
// на СОБРАННОМ backend.js (worker_threads, storage 'memory'; «перезагрузка вкладки» = снимок тома `dump` → новый
// воркер с loadDataDir, как тёплый старт на том же томе IndexedDB/OPFS; «падение процесса» = dump посреди задачи и
// обрыв воркера без shutdown; «прошло N дней» = сдвиг часов воркера, JS и PGlite вместе — worker-boot clockOffsetMs).
//
//   C1 заголовки настоящего приложения: X-App-Version 0.1.0+1, X-Platform windows / android / без заголовка → не 426
//   C2 перезагрузка посреди работы: заказ + ожидающий QR + возврат + клиент из POS → перезапуск → статусы
//      продолжаются, missing нет, следующий номер «1С» (critic [0])
//   C3 обрыв воркера посреди задачи → холодный старт → всё снова идёт не позже чем через 30 с (critic [1])
//   C4 часы +3 и +10 дней: /sync/status overall=ok, 902 остаётся «Продавцом» (critic [2])
//   C5 «1С недоступна» под сторожем единицы работы (critic [8])
//   C6 ни одного внешнего сетевого запроса из воркера (critic [12]) — по всем бэкендам этого набора
//   C7 холодный старт эпохи: долги «1С» видны без ручного запуска синхронизации (гонка догоняния, найдена WP-T1)
import { startWorkerBackend } from '../harness/worker-harness.mjs';
import { APP_VERSION, cashAmount, createCtx, placeOrder, sellable, sleep } from './dsl.mjs';

const enc = encodeURIComponent;
const DAY = 86400e3;
/** Сущности, которые в режиме extension опрашиваются своими cron (pos-api sync-queues EXTENSION_POLLED_ENTITIES). */
const EXTENSION_POLLED = new Set(['stock', 'prices', 'receivables', 'order_status', 'images']);

/** Общий запуск бандла для сценариев критика: учёт сети, строгий режим. */
export async function bootBundle(world, { label, initOpts = {}, boot = {}, sku = 500 } = {}) {
  const be = await startWorkerBackend({ sku, strict: true, initOpts: { seed: false, ...initOpts }, boot: { netRecorder: true, ...boot }, onLog: (lv, m) => lv === 'error' && world.errors.push(`[${label}] ${String(m).slice(0, 600)}`) });
  world.backends.push({ label, be });
  return be;
}
async function closeBe(world, be, { abrupt = false } = {}) {
  const stats = await be.stats().catch(() => null);
  world.netEvents.push(...be.netEvents.map((e) => ({ ...e, backend: world.backends.find((x) => x.be === be)?.label })));
  if (stats) world.netBlocked += stats.net?.blocked ?? 0;
  if (abrupt) await be.terminate();
  else await be.close();
  return stats;
}
const counters = (st) => ({
  pgWaits3s: st.pg.waitsOver3s,
  pgMaxWaitMs: st.pg.maxWaitMs,
  outsideWhitelist: st.pg.outsideWhitelist,
  nestedForeign: st.pg.nestedBeginForeign,
  holds3s: st.gate.stats.holdsOver3s,
  queue3s: st.gate.stats.queueWaitsOver3s,
  maxHoldMs: st.gate.stats.maxHoldMs,
  gatewaySleeps: st.onec.gateway.sleeps,
  onec503: st.onec.byStatus['503'] ?? 0,
  onec404: st.onec.byStatus['404'] ?? 0,
});
const delta = (a, b) => Object.fromEntries(Object.keys(b).map((k) => [k, typeof b[k] === 'number' && typeof a[k] === 'number' && !/max/i.test(k) ? b[k] - a[k] : b[k]]));

async function staff(ctx) {
  const A = ctx.dev('windows', { name: 'админ 901' });
  const C = ctx.dev('windows', { name: 'кассир 906' });
  await A.login('+996777000901');
  await C.login('+996777000906');
  return { A, C };
}
async function manualSync(A, entity, ctx, { timeoutMs = 60000 } = {}) {
  const su = await A.stepUp('sync.run.full', { label: `step-up sync ${entity}` });
  const st = await A.call(`POST /sync/runs ${entity}`, 'POST', '/sync/runs', { idem: true, stepUp: su, body: { entity, mode: 'incremental' }, expect: [202, 409] });
  if (st.status !== 202) return { start: st, fin: null };
  const fin = await A.poll(`прогон ${entity}`, 'GET', `/sync/runs/${st.json.id}`, (r) => ['success', 'partial', 'failed'].includes(r.json?.status), { timeoutMs });
  return { start: st, fin };
}

// ------------------------------------------------------------------------------------------------- C1
export async function c1Headers(world) {
  const be = await bootBundle(world, { label: 'C1' });
  const ctx = createCtx(be, { log: world.log, label: 'C1' });
  ctx.begin('C1. заголовки приложения: X-App-Version 0.1.0+1');
  const res = {};
  for (const platform of ['windows', 'android', null]) {
    const d = ctx.dev(platform, { name: `0.1.0+1 ${platform ?? 'без X-Platform'}` });
    const v = await d.login(platform === 'android' ? '+996777000907' : platform === 'windows' ? '+996777000906' : '+996777000909');
    const me = await d.call('GET /me', 'GET', '/me');
    const cat = await d.call('GET /catalog/categories', 'GET', '/catalog/categories');
    res[platform ?? 'none'] = { verify: v.status, me: me.status, catalog: cat.status, min: me.headers['x-min-app-version'] ?? null };
  }
  const old = await ctx.dev('windows', { name: '0.0.9+1', version: '0.0.9+1' }).call('GET /catalog/categories 0.0.9+1', 'GET', '/catalog/categories', { expect: 426 });
  ctx.check(`C1 настоящий заголовок X-App-Version ${APP_VERSION}: X-Platform windows / android / без заголовка (браузер вне Windows) → нет 426`, Object.values(res).every((x) => x.verify === 200 && x.me === 200 && x.catalog === 200), res);
  ctx.check('C1a версия ниже минимальной (0.0.9+1) → 426 APP_UPDATE_REQUIRED', old.status === 426 && old.json?.code === 'APP_UPDATE_REQUIRED', { status: old.status, code: old.json?.code, min: old.headers['x-min-app-version'] });
  world.ctxs.push(ctx);
  await closeBe(world, be);
}

// ------------------------------------------------------------------------------------------------- C2
export async function c2Reload(world) {
  let be = await bootBundle(world, { label: 'C2 до перезагрузки' });
  let ctx = createCtx(be, { log: world.log, label: 'C2' });
  ctx.begin('C2. перезагрузка посреди работы (critic [0])');
  const { A, C } = await staff(ctx);
  const SS = ctx.dev('windows', { name: 'старший 907' });
  await SS.login('+996777000907');
  const pl = await sellable(C, { limit: 100, maxPrice: 6000 });
  // заказ → оплата → «1С» → согласован → отгружен; возврат отправлен
  const o1 = (await placeOrder(C, pl[0], 'cash', { label: 'O1' })).order.json;
  await C.call('O1 оплата', 'POST', `/orders/${o1.id}/payments`, { idem: true, body: { method: 'cash', receivedAmount: cashAmount(o1) }, expect: [200, 201] });
  await C.poll('O1 номер «1С»', 'GET', `/orders/${o1.id}`, (r) => !!r.json?.onec?.number, { timeoutMs: 30000 });
  await ctx.panel(`POST orders/${o1.id}/onec-status`, { status: 'КВыполнению', approved: true });
  await C.poll('O1 согласован', 'GET', `/orders/${o1.id}`, (r) => ['approved', 'awaiting_shipment'].includes(r.json?.status), { timeoutMs: 30000 });
  await ctx.panel(`POST orders/${o1.id}/ship`, {});
  const o1s = (await C.call('O1 отгружен', 'GET', `/orders/${o1.id}`)).json;
  const line = o1s.items[0];
  const r1 = await C.call('R1 черновик', 'POST', '/returns', { idem: true, expect: 201, body: { orderId: o1.id, reasonCode: 'defect', items: [{ orderLineNo: line.lineNo, quantity: { value: '1', unitId: line.quantity.unitId, packagingId: null } }] } });
  const r1s = await C.withStepUp('R1 submit', 'POST', `/returns/${r1.json?.id}/submit`, { body: { rowVersion: r1.json?.rowVersion }, expect: 200 });
  // клиент из POS → «1С»
  const pc = await C.call('клиент из POS', 'POST', '/customers', { idem: true, expect: 201, body: { name: 'Клиент Перезагрузки', customerType: 'individual', phones: ['+996777000957'] } });
  const pcc = await C.poll('клиент подтверждён «1С»', 'GET', `/customers/${pc.json?.id}`, (r) => r.json?.onecStatus === 'confirmed', { timeoutMs: 30000, everyMs: 700 });
  // ожидающий QR и неоплаченный заказ
  await ctx.panel('POST qr/config', { paidAfterPolls: 0 });
  const q1 = (await placeOrder(C, pl[1], 'qr_bakai', { label: 'Q1' })).order.json;
  const q1p = q1.payments?.[0];
  await C.poll('Q1 номер «1С»', 'GET', `/orders/${q1.id}`, (r) => !!r.json?.onec?.number, { timeoutMs: 30000 });
  const o2 = (await placeOrder(C, pl[2], 'cash', { label: 'O2' })).order.json;
  await C.poll('O2 номер «1С»', 'GET', `/orders/${o2.id}`, (r) => !!r.json?.onec?.number, { timeoutMs: 30000 });
  const st0 = await ctx.panel('GET state');
  const before = { orderSeq: st0.onec.orderSeq, numbers: st0.orders.filter((x) => x.onecNumber).map((x) => x.onecNumber), returnInState: st0.orders.find((x) => x.id === o1.id)?.actions ?? [] };
  const fakeBefore = await ctx.panel('fake', { method: 'GET', path: '/__fake/cashier/state' });
  const flush = await be.rpc({ type: 'flush', reason: 'pagehide' }).catch((e) => ({ error: String(e) }));
  const dump = await be.rpc({ type: 'dump' }, 120000);
  const cashierRefresh = C.refresh;
  const cashierDevice = C.deviceId;
  world.ctxs.push(ctx);
  await closeBe(world, be);

  // ---- тёплый старт с того же тома
  be = await bootBundle(world, { label: 'C2 после перезагрузки', initOpts: { generation: 2, loadDataDir: dump.data } });
  ctx = createCtx(be, { log: world.log, label: 'C2b' });
  ctx.begin('C2. после перезагрузки');
  const C2 = ctx.dev('windows', { name: 'кассир 906 (после F5)', deviceId: cashierDevice });
  const rf = await C2.call('refresh старой сессии', 'POST', '/auth/refresh', { body: { refreshToken: cashierRefresh } });
  C2.token = rf.json?.accessToken; // check-secrets: allow — токен из ответа API в прогоне, не секрет; gitleaks:allow
  C2.refresh = rf.json?.refreshToken;
  const A2 = ctx.dev('windows', { name: 'админ 901 (после F5)' });
  await A2.login('+996777000901', { setPin: false });
  // синхронизация статусов заказов «1С» (как по cron): ни одного missing
  const o3 = (await placeOrder(C2, pl[3], 'cash', { label: 'O3 (после F5)' })).order.json;
  const o3l = await C2.poll('O3 номер «1С»', 'GET', `/orders/${o3.id}`, (r) => !!r.json?.onec?.number, { timeoutMs: 30000 });
  await ctx.panel(`POST orders/${o3.id}/onec-status`, { status: 'КВыполнению', approved: true });
  await C2.poll('O3 согласован (синхронизация статусов)', 'GET', `/orders/${o3.id}`, (r) => ['approved', 'awaiting_shipment'].includes(r.json?.status), { timeoutMs: 30000 });
  const st1 = await ctx.panel('GET state');
  const missing = st1.orders.filter((x) => x.syncState === 'missing');
  const n3 = Number(/(\d+)$/.exec(o3l.json?.onec?.number ?? '')?.[1] ?? 0);
  const o1a = (await C2.call('O1 после F5', 'GET', `/orders/${o1.id}`)).json;
  const o2a = (await C2.call('O2 после F5', 'GET', `/orders/${o2.id}`)).json;
  // ожидающий QR оплачивается
  const qPend = st1.qr.pending.find((x) => x.paymentId === q1p?.id);
  await ctx.panel(`POST qr/${q1p?.id}/pay`, {});
  const qr = await C2.poll('Q1 оплачен после F5', 'GET', `/payments/${q1p?.id}?wait=10`, (r) => r.json?.status === 'received', { timeoutMs: 30000, everyMs: 200 });
  // возврат: «1С» проводит заявку, которую POS отправил до перезагрузки
  const offered = st1.orders.find((x) => x.id === o1.id)?.actions ?? [];
  const ret = offered.includes('return') ? await ctx.panel(`POST returns/${r1.json?.id}/status`, { status: 'completed' }) : null;
  const retDone = await C2.poll('R1 проведён «1С»', 'GET', `/returns/${r1.json?.id}`, (r) => r.json?.status === 'completed', { timeoutMs: 30000, everyMs: 800 });
  const fakeAfter = await ctx.panel('fake', { method: 'GET', path: '/__fake/cashier/state' });
  const pcAfter = (await C2.call('клиент из POS после F5', 'GET', `/customers/${pc.json?.id}`)).json;
  const stats = await be.stats();
  ctx.check('C2.1 сессия жива после перезагрузки (POST /auth/refresh 200), том тёплый', be.ready.warm === true && rf.status === 200, { warm: be.ready.warm, refresh: rf.status, flush: flush?.data ?? flush });
  ctx.check('C2.2 номер «1С» следующий: продолжает orderSeq, не повторяется', n3 === before.orderSeq + 1 && !before.numbers.includes(o3l.json?.onec?.number), { before: before.orderSeq, after: o3l.json?.onec?.number });
  ctx.check('C2.3 после синхронизации статусов ни одного заказа missing; статусы прежних заказов сохранились', missing.length === 0 && o1a?.status === 'shipped' && o2a?.onec?.number && o2a?.onecSyncState !== 'missing', { missing: missing.length, o1: o1a?.status, o2: `${o2a?.status}/${o2a?.onecSyncState}` });
  ctx.check('C2.4 ожидающий QR пережил перезагрузку и оплачивается', !!qPend && qr.json?.status === 'received', { pendingAfterReload: !!qPend, status: qr.json?.status });
  ctx.check('C2.5 возврат, отправленный до перезагрузки, известен «1С» и проводится', r1s.final.json?.status === 'submitted' && offered.includes('return') && retDone.json?.status === 'completed', { submitted: r1s.final.json?.status, offered, after: retDone.json?.status, op: ret ? 'ok' : null });
  ctx.check('C2.6 клиент из POS известен «1С» после перезагрузки; 404 «1С» нет', pcc.json?.onecStatus === 'confirmed' && pcAfter?.onecStatus === 'confirmed' && (fakeAfter.body?.customers ?? 0) >= (fakeBefore.body?.customers ?? 1) && (stats.onec.byStatus['404'] ?? 0) === 0, { before: fakeBefore.body?.customers, after: fakeAfter.body?.customers, onec404: stats.onec.byStatus['404'] ?? 0, restore: be.ready.timings.fakeRestore });
  world.ctxs.push(ctx);
  await closeBe(world, be);
}

// ------------------------------------------------------------------------------------------------- C3
export async function c3Interrupt(world) {
  let be = await bootBundle(world, { label: 'C3 до обрыва' });
  let ctx = createCtx(be, { log: world.log, label: 'C3' });
  ctx.begin('C3. обрыв воркера посреди задачи (critic [1])');
  const { A, C } = await staff(ctx);
  await A.poll('/sync/status ok перед обрывом', 'GET', '/sync/status', (r) => r.json?.overall === 'ok', { timeoutMs: 60000, everyMs: 1000 });
  const pl = await sellable(C, { limit: 100, maxPrice: 6000 });
  await ctx.panel('POST qr/config', { paidAfterPolls: 0 });
  const q = (await placeOrder(C, pl[0], 'qr_bakai', { label: 'Q (до обрыва)' })).order.json;
  const qp = q.payments?.[0];
  // ручной прогон receivables и заказ в outbox — затем снимок тома, когда задача pg-boss уже взята в работу
  const su = await A.stepUp('sync.run.full');
  const run = await A.call('POST /sync/runs receivables (до обрыва)', 'POST', '/sync/runs', { idem: true, stepUp: su, body: { entity: 'receivables', mode: 'incremental' }, expect: 202 });
  const o = (await placeOrder(C, pl[1], 'cash', { label: 'O (до обрыва)' })).order.json;
  const active = await ctx.until(async () => (await be.stats()).gate.active?.label ?? '', (l) => /^job /.test(l), { timeoutMs: 8000, everyMs: 5 });
  const dump = await be.rpc({ type: 'dump' }, 120000);
  world.ctxs.push(ctx);
  await closeBe(world, be, { abrupt: true });

  // ---- холодный старт процесса на том же томе
  be = await bootBundle(world, { label: 'C3 после обрыва', initOpts: { generation: 2, loadDataDir: dump.data } });
  const tReady = Date.now();
  ctx = createCtx(be, { log: world.log, label: 'C3b' });
  ctx.begin('C3. после обрыва: всё снова идёт');
  const A2 = ctx.dev('windows', { name: 'админ 901 (после обрыва)' });
  const C2 = ctx.dev('windows', { name: 'кассир 906 (после обрыва)' });
  await A2.login('+996777000901', { setPin: false });
  await C2.login('+996777000906', { setPin: false });
  const left = () => Math.max(1000, 30000 - (Date.now() - tReady));
  const ms = () => Date.now() - tReady;
  const ss = await A2.poll('/sync/status ok', 'GET', '/sync/status', (r) => r.json?.overall === 'ok', { timeoutMs: left(), everyMs: 500 });
  const ssMs = ms();
  const sync = await manualSync(A2, 'receivables', ctx, { timeoutMs: left() });
  const syncMs = ms();
  const ol = await C2.poll('заказ до обрыва получил номер «1С»', 'GET', `/orders/${o.id}`, (r) => !!r.json?.onec?.number, { timeoutMs: left() });
  const olMs = ms();
  await ctx.panel(`POST qr/${qp?.id}/pay`, {});
  const qr = await C2.poll('QR до обрыва оплачен', 'GET', `/payments/${qp?.id}?wait=5`, (r) => r.json?.status === 'received', { timeoutMs: left(), everyMs: 200 });
  const qrMs = ms();
  const pl2 = await sellable(C2, { limit: 100, maxPrice: 6000 });
  const n = (await placeOrder(C2, pl2[2], 'cash', { label: 'новый заказ после обрыва' })).order.json;
  const nl = await C2.poll('новый заказ — номер «1С»', 'GET', `/orders/${n.id}`, (r) => !!r.json?.onec?.number, { timeoutMs: left() });
  const allMs = ms();
  const rec = be.ready.timings.recovery ?? {};
  ctx.check('C3.1 обрыв пришёлся на задачу pg-boss (снимок тома во время job)', active.ok, { activeUnit: active.v, manualRun: run.status });
  ctx.check('C3.2 восстановление до WorkerRuntime: задачи active → retry/failed, прогоны running закрыты, аренда outbox снята', (rec.jobsRetried ?? 0) + (rec.jobsFailed ?? 0) >= 1 || (rec.runsClosed ?? 0) >= 1, rec);
  ctx.check('C3.3 не позже 30 с после старта: /sync/status ok, ручной прогон принят и завершён, outbox доставил заказ, QR оплачен, новый заказ в «1С»', ss.json?.overall === 'ok' && sync.start.status === 202 && sync.fin?.json?.status === 'success' && !!ol.json?.onec?.number && qr.json?.status === 'received' && !!nl.json?.onec?.number && allMs <= 30000, { syncStatusOkMs: ssMs, manualRun: `${sync.start.status} ${sync.start.json?.code ?? ''} → ${sync.fin?.json?.status ?? '—'} @${syncMs}`, orderLinkedMs: olMs, qrMs, allMs, newOrder: nl.json?.onec?.number });
  world.ctxs.push(ctx);
  await closeBe(world, be);
}

// ------------------------------------------------------------------------------------------------- C4
export async function c4Clock(world, { days = [3, 10] } = {}) {
  let be = await bootBundle(world, { label: 'C4 день 0' });
  let ctx = createCtx(be, { log: world.log, label: 'C4' });
  ctx.begin('C4. часы +N дней: день 0');
  const { A } = await staff(ctx);
  await A.poll('/sync/status ok (день 0)', 'GET', '/sync/status', (r) => r.json?.overall === 'ok', { timeoutMs: 60000, everyMs: 1000 });
  const inv0 = (await A.call('приглашения (день 0)', 'GET', '/admin/invitations')).json?.items?.find((x) => x.status === 'pending');
  const dump = await be.rpc({ type: 'dump' }, 120000);
  const adminRefresh = A.refresh;
  const adminDevice = A.deviceId;
  world.ctxs.push(ctx);
  await closeBe(world, be);
  for (const d of days) {
    be = await bootBundle(world, { label: `C4 +${d} дн.`, initOpts: { generation: 2, loadDataDir: dump.data }, boot: { clockOffsetMs: d * DAY } });
    const tReady = Date.now();
    ctx = createCtx(be, { log: world.log, label: `C4+${d}` });
    ctx.begin(`C4. часы +${d} дней`);
    const now = (await ctx.dev('windows', { name: 'служебный' }).call('GET /health', 'GET', '/health')).json?.serverTime;
    const Ad = ctx.dev('windows', { name: 'админ 901', deviceId: adminDevice });
    const rf = await Ad.call('refresh сессии дня 0', 'POST', '/auth/refresh', { body: { refreshToken: adminRefresh }, expect: [200, 401] });
    if (rf.status === 200) {
      Ad.token = rf.json.accessToken; // check-secrets: allow — токен из ответа API в прогоне, не секрет; gitleaks:allow
      Ad.refresh = rf.json.refreshToken;
    } else await Ad.login('+996777000901', { setPin: false });
    const ss = await Ad.poll(`/sync/status ok (+${d} дн.)`, 'GET', '/sync/status', (r) => r.json?.overall === 'ok', { timeoutMs: Math.max(1000, 60000 - (Date.now() - tReady)), everyMs: 1000 });
    const ssMs = Date.now() - tReady;
    const S = ctx.dev('windows', { name: 'продавец 902' });
    const v = await S.login('+996777000902');
    const inv = (await Ad.call('приглашения', 'GET', '/admin/invitations')).json?.items ?? [];
    const C = ctx.dev('windows', { name: 'кассир 906' });
    await C.login('+996777000906', { setPin: false });
    const od = await C.poll('просрочка видна (снимок долга свежий)', 'GET', `/search/customers?q=${enc('Просрочка')}&include=receivable`, (r) => r.json?.items?.[0]?.isOverdue === true, { timeoutMs: 30000, everyMs: 1000 });
    const rcv = od.json?.items?.[0] ? await C.call('долг просрочки', 'GET', `/customers/${od.json.items[0].id}/receivables`) : null;
    const pl = await sellable(C, { limit: 100, maxPrice: 6000 });
    const o = (await placeOrder(C, pl[d % pl.length], 'cash', { label: `заказ (+${d} дн.)` })).order.json;
    const ol = await C.poll('номер «1С»', 'GET', `/orders/${o.id}`, (r) => !!r.json?.onec?.number, { timeoutMs: 30000 });
    ctx.check(`C4.${d}a часы воркера сдвинуты на +${d} дн. (serverTime, JS и PGlite)`, Math.abs(Date.parse(now) - (Date.now() + d * DAY)) < 120000, { serverTime: now });
    const stale = (ss.json?.entities ?? []).filter((e) => e.isStale).map((e) => e.entity);
    // Только сущности плана обмена устарели — признак регрессии POSAPI-T1-01 (test/pos-api-defects.json): дефект
    // исправлен в pos-api 2026-10-30 (успешный цикл onec.changes, в том числе пустой, подтверждает их свежесть), поэтому
    // такой провал — провал демо (в pos-api-defects.json у дефекта `tests: []`), а `regressionOf` — подсказка в свидетельстве.
    const planOnly = stale.length > 0 && stale.every((e) => !EXTENSION_POLLED.has(e));
    ctx.check(`C4.${d}b /sync/status overall=ok ≤ 60 с после старта через ${d} дн.`, ss.json?.overall === 'ok', { overall: ss.json?.overall, ms: ssMs, stale, regressionOf: planOnly ? 'POSAPI-T1-01 (исправлен; устарели только сущности плана обмена)' : null });
    ctx.check(`C4.${d}c вход 902 через ${d} дн. → «Продавец» по приглашению (приглашение продлено при старте, если истекло или осталось < 3 дн.)`, (v.json?.user?.roles ?? []).includes('seller') && v.json?.roleSource === 'invitation', { roles: v.json?.user?.roles, roleSource: v.json?.roleSource, status: v.json?.status, invitationAtStart: be.ready.timings.invitation, day0ExpiresAt: inv0?.expiresAt, now: inv.map((x) => `${x.status} до ${x.expiresAt}`).slice(0, 3) });
    ctx.check(`C4.${d}d через ${d} дн.: долги «1С» свежие, заказ доходит до «1С»`, rcv?.json?.isStale === false && !!ol.json?.onec?.number, { overdue: od.json?.items?.[0]?.isOverdue, stale: rcv?.json?.isStale, onec: ol.json?.onec?.number });
    ctx.check(`C4.${d}e refresh-токен дня 0 через ${d} дн.: ${rf.status === 200 ? 'действует' : 'истёк (вход заново по OTP)'} — по сроку сессии`, rf.status === 200 || rf.json?.code === 'SESSION_REVOKED' || rf.json?.code === 'UNAUTHENTICATED' || rf.json?.code === 'TOKEN_STALE', { status: rf.status, code: rf.json?.code });
    world.ctxs.push(ctx);
    await closeBe(world, be);
  }
}

// ------------------------------------------------------------------------------------------------- C5
export async function c5OnecDown(world) {
  const be = await bootBundle(world, { label: 'C5' });
  const ctx = createCtx(be, { log: world.log, label: 'C5' });
  ctx.begin('C5. «1С недоступна» под сторожем (critic [8])');
  const { A, C } = await staff(ctx);
  await A.poll('/sync/status ok', 'GET', '/sync/status', (r) => r.json?.overall === 'ok', { timeoutMs: 60000, everyMs: 1000 });
  const pl = await sellable(C, { limit: 100, maxPrice: 6000 });
  const s0 = counters(await be.stats());
  const errs0 = world.errors.length;
  await ctx.panel('POST onec/down', { down: true });
  const t = Date.now();
  const sync = await manualSync(A, 'customers', ctx, { timeoutMs: 30000 });
  const syncMs = Date.now() - t;
  const me = [];
  for (let i = 0; i < 6; i++) {
    const r = await C.call('GET /me (1С недоступна)', 'GET', '/me');
    me.push(r.ms);
    await sleep(150);
  }
  const o = await placeOrder(C, pl[0], 'cash', { label: 'заказ при недоступной «1С»' });
  const ss = await A.call('/sync/status при недоступной «1С»', 'GET', '/sync/status');
  const dash = await C.call('дашборд при недоступной «1С»', 'GET', '/pos/dashboard');
  const s1 = counters(await be.stats());
  await ctx.panel('POST onec/down', { down: false });
  const linked = await C.poll('заказ доходит до «1С» после восстановления (повтор outbox по графику)', 'GET', `/orders/${o.order.json?.id}`, (r) => !!r.json?.onec?.number, { timeoutMs: 150000, everyMs: 2000 });
  const d = delta(s0, s1);
  const watchdogErrors = world.errors.slice(errs0).filter((l) => /сторож|watchdog/.test(l));
  ctx.check('C5.1 при «1С недоступна» прогон синхронизации завершается быстро (failed), без пауз повторов шлюза', sync.fin?.json?.status === 'failed' && syncMs < 10000 && d.gatewaySleeps === 0 && d.onec503 > 0, { run: sync.fin?.json?.status, ms: syncMs, gatewaySleeps: d.gatewaySleeps, onec503: d.onec503 });
  ctx.check('C5.2 запросы приложения не ждут «1С»: GET /me < 3 с, заказ принят (202, STALE_DATA), дашборд 200', Math.max(...me) < 3000 && o.order.status === 202 && dash.status === 200, { meMaxMs: Math.max(...me), order: o.order.status, warning: o.order.json?.warnings?.[0]?.code, onecCheck: o.preview.json?.onecCheck?.result, onecReachable: ss.json?.onecReachable, overall: ss.json?.overall });
  ctx.check('C5.3 сторож молчит: 0 удержаний слота > 3 с, 0 ожиданий слота > 3 с, 0 ожиданий замка > 3 с', d.holds3s === 0 && d.queue3s === 0 && d.pgWaits3s === 0 && watchdogErrors.length === 0, { ...d, watchdogErrors: watchdogErrors.slice(0, 3) });
  ctx.check('C5.4 после восстановления «1С» заказ получает номер (повтор outbox)', !!linked.json?.onec?.number, { onec: linked.json?.onec?.number, state: linked.json?.onecSyncState });
  world.ctxs.push(ctx);
  await closeBe(world, be);
}

// ------------------------------------------------------------------------------------------------- C7
/**
 * Холодный старт эпохи: долги «1С» видны без ручной синхронизации. Клиентов «1С» в снимке нет (их приносит
 * синхронизация customers); если задача receivables выполнится раньше customers, она получает 0 снимков и долгов нет
 * до следующего запуска по расписанию (дефект WP-T1 № 3). С fix round 1 догоняние (demo-init.mjs catchUp) ставит
 * receivables только после завершения задачи customers. Гонка — несколько холодных стартов подряд.
 */
export async function c7ColdStartDebts(world, { starts = 4 } = {}) {
  const ctx = createCtx(null, { log: world.log, label: 'C7' });
  ctx.begin('C7. холодный старт: долги «1С» без ручной синхронизации');
  const rounds = [];
  for (let i = 0; i < starts; i++) {
    const be = await bootBundle(world, { label: `C7 старт ${i + 1}` });
    const c = createCtx(be, { log: () => {}, label: 'C7' });
    // как утро смены: сразу после старта входят несколько сотрудников (первые PIN — Argon2 в слоте запросов);
    // запросы приложения идут раньше задач pg-boss, и порядок задач догоняния смещается
    const { A, C } = await staff(c);
    await c.dev('windows', { name: 'старший 907' }).login('+996777000907');
    await c.dev('android', { name: 'руководитель 909' }).login('+996777000909');
    const t = Date.now();
    const seen = await c.until(async () => (await C.call('поиск «Просрочка»', 'GET', `/search/customers?q=${enc('Просрочка')}&include=receivable`, { record: false })).json?.items?.[0], (x) => x?.isOverdue === true, { timeoutMs: 20000, everyMs: 1000 });
    const runs = (await A.call('прогоны', 'GET', '/sync/runs?limit=50', { record: false })).json?.items ?? [];
    const first = (e) => runs.filter((r) => r.entity === e).at(-1);
    const st = (await A.call('статус', 'GET', '/sync/status', { record: false })).json;
    rounds.push({ visible: seen.ok, ms: Date.now() - t, receivables: first('receivables') && { fetched: first('receivables').counts?.fetched, startedAt: first('receivables').startedAt?.slice(11, 23) }, customers: first('customers') && { fetched: first('customers').counts?.fetched, finishedAt: first('customers').finishedAt?.slice(11, 23) }, nextReceivablesRun: st?.entities?.find((e) => e.entity === 'receivables')?.nextRunAt ?? null });
    await closeBe(world, be);
  }
  const missed = rounds.filter((r) => !r.visible).length;
  ctx.check(`C7 после холодного старта эпохи долги «1С» видны ≤ 20 с без ручного запуска синхронизации (${starts} стартов)`, missed === 0, { missed, rounds });
  world.ctxs.push(ctx);
}

// ------------------------------------------------------------------------------------------------- C6
export function c6Network(world) {
  const ctx = createCtx(null, { log: world.log, label: 'C6' });
  ctx.begin('C6. сеть воркера (critic [12])');
  const external = world.netEvents.filter((e) => !/^(file:|data:|blob:)/.test(e.url));
  ctx.check(`C6 ни одного внешнего сетевого запроса из воркера (${world.backends.length} запусков бандла)`, external.length === 0 && world.netBlocked === 0, { reachedPlatform: world.netEvents.length, external: external.slice(0, 5), blockedByGuard: world.netBlocked });
  world.ctxs.push(ctx);
}

export const CRITIC = { c1Headers, c2Reload, c3Interrupt, c4Clock, c5OnecDown, c7ColdStartDebts };

/** Все сценарии критика. → world { ctxs, errors, netEvents, … } */
export async function runCritic({ log = () => {}, only } = {}) {
  const world = { log, ctxs: [], errors: [], backends: [], netEvents: [], netBlocked: 0 };
  for (const [name, f] of Object.entries(CRITIC)) {
    if (only && !only.includes(name)) continue;
    try {
      await f(world);
    } catch (e) {
      const ctx = createCtx(null, { log, label: name });
      ctx.begin(name);
      ctx.check(`${name}: сценарий без исключения`, false, String(e?.stack ?? e).slice(0, 1500));
      world.ctxs.push(ctx);
      for (const b of world.backends)
        if (b.be.exited() === null) {
          world.netEvents.push(...b.be.netEvents.map((e) => ({ ...e, backend: b.label })));
          await b.be.close().catch(() => undefined);
        }
    }
  }
  c6Network(world);
  return world;
}
