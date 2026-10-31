// Сценарий API для прогона собранного бэкенда (WP-B2; переиспользует WP-T1). Часть 1 — все сценарии Node-спайка
// run-full.mjs (+ шаги WP-B0): /health и 426, OTP 246810 и PIN, step-up, синхронизация клиентов и долгов, каталог,
// корзина → checkout-preview → заказ наличными → номер 1С → оплата → PDF-чек, QR с long-poll (и параллельный
// GET /me), долг (просрочка → 422 CREDIT_BLOCKED, в лимите → 201), дашборд, уведомления, отчёт, статус синхронизации.
// Часть 2 — проверки единицы работы WP-B2: пачка параллельных запросов, отмена ещё не начатых запросов
// (поиск при наборе), отмена начатых (step-up, long-poll), «1С недоступна» под сторожем.
//
// be — объект worker-harness.mjs startWorkerBackend(): api(), cancel(), control(), stats().
// Имена и телефоны тестовых клиентов — по demo/web/backend/pii-map.json (WP-B1).

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function runScenario(be, { log = console.log, version = '0.1.0+1', platform = 'windows' } = {}) {
  const deviceId = crypto.randomUUID();
  const base = { 'X-Device-Id': deviceId, 'X-App-Version': version, 'X-Platform': platform, 'Accept-Language': 'ru' };
  const results = [];
  const checks = {};
  const t0 = Date.now();
  const el = () => `${((Date.now() - t0) / 1000).toFixed(1)}s`;
  const idem = () => ({ 'Idempotency-Key': crypto.randomUUID() });
  const record = (name, method, url, r, expect) => {
    const rec = { name, method, url: url.split('?')[0], status: r.status, ms: r.ms, workerMs: r.workerMs ?? null, queuedMs: r.queuedMs ?? null, code: r.json?.code ?? null };
    if (expect !== undefined) rec.expect = expect;
    results.push(rec);
    return rec;
  };
  async function call(name, method, url, { headers = {}, body, expect, quiet = false } = {}) {
    const r = await be.api(method, url, { headers, body });
    record(name, method, url, r, expect);
    if (!quiet) {
      const brief = r.json ? JSON.stringify(r.json).slice(0, 140) : `${r.headers?.['content-type'] ?? ''} ${r.size} bytes ${r.magic ?? ''}`;
      log(`${el().padStart(6)} ${String(r.status).padEnd(4)}${String(r.ms).padStart(6)}ms ${name.padEnd(38)} ${brief}`);
    }
    return r;
  }
  async function until(fn, ok, timeoutMs = 60000, every = 1000) {
    const end = Date.now() + timeoutMs;
    for (;;) {
      const r = await fn();
      if (ok(r) || Date.now() > end) return r;
      await sleep(every);
    }
  }
  async function login(phone, pin) {
    const rq = await call(`otp/request ${phone}`, 'POST', '/api/v1/auth/otp/request', { headers: base, body: { phone, purpose: 'login_or_register', locale: 'ru' } });
    const vr = await call(`otp/verify ${phone}`, 'POST', '/api/v1/auth/otp/verify', {
      headers: base,
      body: { challengeId: rq.json?.challengeId, code: '246810', device: { name: 'Chrome (демо)', platform, appVersion: version } },
    });
    const H = { ...base, Authorization: `Bearer ${vr.json?.accessToken}` };
    if (pin) await call('me/pin', 'POST', '/api/v1/me/pin', { headers: { ...H, ...idem() }, body: { newPin: pin } });
    return H;
  }
  const stepUp = (H, operation = 'sync.run.full') => call('auth/step-up pin', 'POST', '/api/v1/auth/step-up', { headers: H, body: { method: 'pin', operation, pin: '715382' } });
  async function syncRun(A, entity, { timeoutMs = 90000 } = {}) {
    const su = await stepUp(A);
    const st = await call(`sync/runs ${entity}`, 'POST', '/api/v1/sync/runs', {
      headers: { ...A, ...idem(), 'X-Step-Up-Token': su.json?.stepUpToken }, // check-secrets: allow — токен step-up из ответа API в прогоне, не секрет; gitleaks:allow
      body: { entity, mode: 'incremental' },
    });
    if (!st.json?.id) return { start: st, fin: null, ms: 0 };
    const t = Date.now();
    const fin = await until(
      () => be.api('GET', `/api/v1/sync/runs/${st.json.id}`, { headers: A }),
      (x) => {
        if (x.status >= 500) record(`sync/runs/{id} poll ${entity}`, 'GET', '/api/v1/sync/runs/{id}', x);
        return ['success', 'partial', 'failed'].includes(x.json?.status);
      },
      timeoutMs,
      300,
    );
    const ms = Date.now() - t;
    log(`        sync ${entity}: ${fin.json?.status} ${JSON.stringify(fin.json?.counts)} за ${ms} мс`);
    results.push({ name: `sync ${entity} final`, method: 'GET', url: '/api/v1/sync/runs/{id}', status: fin.status, ms, code: fin.json?.status ?? null });
    return { start: st, fin, ms };
  }

  // ---------------------------------------------------------------- часть 1: run-full.mjs
  await call('health', 'GET', '/health', { headers: base });
  await call('426 check (0.0.9+1)', 'POST', '/api/v1/auth/otp/request', {
    headers: { ...base, 'X-App-Version': '0.0.9+1' },
    body: { phone: '+996777000906', purpose: 'login_or_register', locale: 'ru' },
    expect: 426,
  });

  const A = await login('+996777000901', '715382');
  for (const entity of ['customers', 'receivables']) await syncRun(A, entity);

  const C = await login('+996777000906', '715382');
  await call('me', 'GET', '/api/v1/me', { headers: C });
  await call('catalog/categories', 'GET', '/api/v1/catalog/categories', { headers: C });
  const prods = await call('catalog/products?limit=40', 'GET', '/api/v1/catalog/products?limit=40', { headers: C });
  const inStock = await call('catalog/products inStock', 'GET', '/api/v1/catalog/products?limit=20&inStock=true', { headers: C });
  const pList = (inStock.json?.items ?? prods.json?.items ?? []).filter((p) => !p.hasVariants && p.price);
  log(`        products: ${prods.json?.items?.length ?? 0} (inStock usable ${pList.length})`);

  async function sell(p, method, extra = {}) {
    let c0 = await call('cart', 'GET', '/api/v1/cart', { headers: C });
    if ((c0.json?.items ?? []).length > 0) c0 = await call('cart DELETE (очистить)', 'DELETE', `/api/v1/cart?rowVersion=${c0.json.rowVersion}`, { headers: C });
    const put = await call('cart/items PUT', 'PUT', `/api/v1/cart/items/${p.defaultVariantId}`, {
      headers: { ...C, ...idem() },
      body: { quantity: { value: '1', unitId: p.baseUnit.id, packagingId: null }, rowVersion: c0.json.rowVersion, mode: 'set' },
    });
    let cart = put.json;
    if (extra.customerId) cart = (await call('cart/customer', 'POST', '/api/v1/cart/customer', { headers: { ...C, ...idem() }, body: { customerId: extra.customerId, rowVersion: cart.rowVersion } })).json;
    const prev = await call(`checkout-preview ${method}`, 'POST', '/api/v1/cart/checkout-preview', {
      headers: { ...C, ...idem() },
      body: { cartId: cart.id, cartRowVersion: cart.rowVersion, paymentMethod: method, delivery: { method: 'pickup' }, receiver: { kind: 'customer' } },
    });
    return call(`orders POST ${method}`, 'POST', '/api/v1/orders', {
      headers: { ...C, ...idem() },
      expect: extra.expect,
      body: {
        cartId: cart.id,
        cartRowVersion: cart.rowVersion,
        ...(prev.json?.previewToken ? { previewToken: prev.json.previewToken } : {}),
        ...(extra.customerId ? { customerId: extra.customerId } : {}),
        receiver: { kind: 'customer' },
        delivery: { method: 'pickup' },
        paymentMethod: method,
        items: [{ variantId: p.defaultVariantId, quantity: { value: '1', unitId: p.baseUnit.id, packagingId: null } }],
      },
    });
  }

  const out = { onecNumber: null, onecLinkMs: null, pdfBytes: 0, pdfMagic: null, qrFinal: null, qrMs: null, parallelMeMs: [], overdueName: null, withinLimitName: null };
  /** Long-poll статуса платежа с параллельным GET /me во время ожидания. */
  async function longPollUntilFinal(payId, rounds = 4) {
    let st = null;
    for (let i = 0; i < rounds && !['received', 'voided'].includes(st); i++) {
      const lp = call('payments/{id}?wait=25 (long-poll)', 'GET', `/api/v1/payments/${payId}?wait=25`, { headers: C });
      await sleep(300);
      const me = await call('me (parallel to long-poll)', 'GET', '/api/v1/me', { headers: C });
      out.parallelMeMs.push(me.ms);
      const w = await lp;
      st = w.json?.status ?? w.json?.payment?.status;
    }
    return st;
  }
  if (pList.length >= 6) {
    const o1 = await sell(pList[0], 'cash');
    const tLink = Date.now();
    const o1d = await until(() => be.api('GET', `/api/v1/orders/${o1.json.id}`, { headers: C }), (x) => x.json?.onec?.number, 30000, 300);
    out.onecNumber = o1d.json?.onec?.number ?? null;
    out.onecLinkMs = Date.now() - tLink;
    log(`        order ${o1.json?.publicNumber}: status=${o1d.json?.status} onec=${out.onecNumber} (${o1d.json?.onecSyncState}) +${out.onecLinkMs}ms`);
    await call('payments cash', 'POST', `/api/v1/orders/${o1.json.id}/payments`, {
      headers: { ...C, ...idem() },
      body: { method: 'cash', receivedAmount: { amount: `${Math.ceil(Number(o1.json.total.amount)) + 50}.00`, currency: 'KGS' } },
    });
    const pdf = await call('receipt.pdf thermal80', 'GET', `/api/v1/orders/${o1.json.id}/documents/receipt.pdf?format=thermal80`, { headers: C });
    out.pdfBytes = pdf.size;
    out.pdfMagic = pdf.magic;

    const o2 = await sell(pList[1], 'qr_bakai');
    const pay = o2.json?.payments?.[0];
    log(`        QR payment ${pay?.id} status=${pay?.status} payload=${pay?.qr?.payload}`);
    if (pay?.id) {
      const tlp = Date.now();
      out.qrFinal = await longPollUntilFinal(pay.id);
      out.qrMs = Date.now() - tlp;
      log(`        QR final status=${out.qrFinal} after ${out.qrMs} ms`);
    }

    const sc = await call('search/customers Просрочка', 'GET', `/api/v1/search/customers?q=${encodeURIComponent('Просрочка')}&include=receivable&limit=5`, { headers: C });
    out.overdueName = sc.json?.items?.[0]?.name ?? sc.json?.items?.[0]?.displayName ?? null;
    const overdue = sc.json?.items?.[0];
    if (overdue) out.overdueOrder = (await sell(pList[2], 'credit', { customerId: overdue.id, expect: 422 })).json?.code ?? null;
    const sc2 = await call('search/customers 700000101', 'GET', '/api/v1/search/customers?q=0700000101&include=receivable&limit=5', { headers: C });
    out.withinLimitName = sc2.json?.items?.[0]?.name ?? sc2.json?.items?.[0]?.displayName ?? null;
    const okCust = sc2.json?.items?.[0];
    if (okCust) out.withinLimitOrder = (await sell(pList[3], 'credit', { customerId: okCust.id })).status;
  } else log('!! недостаточно товаров для продаж');

  await call('pos/dashboard', 'GET', '/api/v1/pos/dashboard', { headers: C });
  await call('notifications', 'GET', '/api/v1/notifications?limit=10', { headers: C });
  const from = new Date(Date.now() - 86400e3).toISOString();
  const to = new Date(Date.now() + 60e3).toISOString();
  await call('reports/sales-summary', 'GET', `/api/v1/admin/reports/sales-summary?from=${from}&to=${to}&groupBy=paymentMethod`, { headers: A });
  const ss = await call('sync/status (admin)', 'GET', '/api/v1/sync/status', { headers: A });
  out.syncOverall = ss.json?.overall ?? null;

  // ---------------------------------------------------------------- часть 2: единица работы WP-B2
  // 2.1 Пачка параллельных запросов: все отвечают, ожидание в очереди короткое.
  {
    const urls = ['/api/v1/me', '/api/v1/catalog/categories', '/api/v1/catalog/products?limit=20', '/api/v1/cart', '/api/v1/pos/dashboard', '/api/v1/notifications?limit=5'];
    const tb = Date.now();
    const rs = await Promise.all(Array.from({ length: 24 }, (_, i) => be.api('GET', urls[i % urls.length], { headers: C })));
    rs.forEach((r, i) => record(`burst ${urls[i % urls.length].split('?')[0]}`, 'GET', urls[i % urls.length], r));
    checks.burst = { n: rs.length, totalMs: Date.now() - tb, maxMs: Math.max(...rs.map((r) => r.ms)), maxQueuedMs: Math.max(...rs.map((r) => r.queuedMs ?? 0)), statuses: [...new Set(rs.map((r) => r.status))] };
    log(`        burst: ${JSON.stringify(checks.burst)}`);
  }

  // 2.2 Поиск при наборе: слот занят step-up (Argon2 ~0,4 с); 4 из 5 поисковых запросов отменяются до начала.
  {
    const before = (await be.stats()).gate.stats;
    const slow = be.api('POST', '/api/v1/auth/step-up', { headers: A, body: { method: 'pin', operation: 'sync.run.full', pin: '715382' } });
    const qs = ['F', 'F4', 'F42', 'F425', 'F4252'];
    const ids = qs.map(() => crypto.randomUUID());
    const reqs = qs.map((q, i) => be.api('GET', `/api/v1/search/products?q=${encodeURIComponent(q)}&limit=10`, { headers: C, id: ids[i] }));
    for (let i = 0; i < 4; i++) be.cancel(ids[i]);
    const rs = await Promise.all(reqs);
    const su = await slow;
    record('step-up (занимает слот)', 'POST', '/api/v1/auth/step-up', su);
    record('search/products (последний, не отменён)', 'GET', '/api/v1/search/products', rs[4]);
    const after = (await be.stats()).gate.stats;
    checks.cancelQueued = {
      cancelled: rs.slice(0, 4).map((r) => ({ cancelled: !!r.cancelled, started: !!r.started })),
      last: { status: rs[4].status, items: rs[4].json?.items?.length ?? null, ms: rs[4].ms },
      gateCancelledQueued: after.cancelledQueued - before.cancelledQueued,
    };
    checks.cancelQueued.ok = checks.cancelQueued.gateCancelledQueued === 4 && rs.slice(0, 4).every((r) => r.cancelled && !r.started) && rs[4].status === 200;
    log(`        cancel queued: ${JSON.stringify(checks.cancelQueued)}`);
  }

  // 2.3 Отмена начатого запроса: step-up отменяется через 60 мс после начала; следующий запрос не ждёт его конца.
  {
    const before = (await be.stats()).gate.stats;
    const id = crypto.randomUUID();
    let startedAt = 0;
    const p = be.api('POST', '/api/v1/auth/step-up', { headers: A, body: { method: 'pin', operation: 'sync.run.full', pin: '715382' }, id, onStart: () => (startedAt = Date.now()) });
    await until(async () => startedAt, (x) => x > 0, 3000, 5);
    await sleep(60);
    const tc = Date.now();
    be.cancel(id);
    const r = await p;
    const me = await be.api('GET', '/api/v1/me', { headers: C });
    record('me (после отмены начатого step-up)', 'GET', '/api/v1/me', me);
    const after = (await be.stats()).gate.stats;
    checks.cancelRunning = {
      cancelled: !!r.cancelled,
      nextStartedAfterCancelMs: me.startedAt ? me.startedAt - tc : null,
      nextMs: me.ms,
      gateCancelledRunning: after.cancelledRunning - before.cancelledRunning,
      gateCancelDetached: after.cancelDetached - before.cancelDetached,
    };
    checks.cancelRunning.ok = checks.cancelRunning.cancelled && me.status === 200 && checks.cancelRunning.nextStartedAfterCancelMs !== null && checks.cancelRunning.nextStartedAfterCancelMs < 600;
    log(`        cancel running: ${JSON.stringify(checks.cancelRunning)}`);
  }

  // 2.4 Отмена long-poll во время ожидания: отпущенная единица снимается быстро, другие запросы не ждут.
  if (pList.length >= 6) {
    await be.control('fake', { method: 'POST', path: '/__fake/qr/config', body: { paidAfterPolls: 0 } });
    const o = await sell(pList[4], 'qr_bakai');
    const pay = o.json?.payments?.[0];
    if (pay?.id) {
      const id = crypto.randomUUID();
      const lp = be.api('GET', `/api/v1/payments/${pay.id}?wait=25`, { headers: C, id });
      await sleep(400);
      const mid = (await be.stats()).gate;
      const tc = Date.now();
      be.cancel(id);
      const r = await lp;
      // Отпущенная единица заканчивается после следующего тика ожидания (200 мс) и короткого дописывания ответа.
      const gone = await until(async () => (await be.stats()).gate, (g) => g.released.length === 0 && !g.queued.some((q) => q.resume), 3000, 20);
      const endedMs = Date.now() - tc;
      const me = await be.api('GET', '/api/v1/me', { headers: C });
      record('me (после отмены long-poll)', 'GET', '/api/v1/me', me);
      checks.cancelLongPoll = { cancelled: !!r.cancelled, releasedWhileWaiting: mid.released.length, endedAfterCancelMs: endedMs, stillReleased: gone.released.length, meMs: me.ms };
      checks.cancelLongPoll.ok = checks.cancelLongPoll.cancelled && checks.cancelLongPoll.releasedWhileWaiting >= 1 && gone.released.length === 0 && endedMs < 1500 && me.status === 200;
      log(`        cancel long-poll: ${JSON.stringify(checks.cancelLongPoll)}`);
      // Оплата «сейчас» через имитатор (как «Оплатить сейчас» в панели) → следующий long-poll видит received.
      await be.control('fake', { method: 'POST', path: '/__fake/qr/config', body: { paidAfterPolls: 1 } });
      const st = await longPollUntilFinal(pay.id, 3);
      checks.cancelLongPoll.afterPayStatus = st;
    }
  }

  // 2.5 «1С недоступна» (панель): шлюз не спит между повторами, единицы не держат слот секундами.
  {
    const s0 = await be.stats();
    await be.control('fake', { method: 'POST', path: '/__fake/down', body: { down: true } });
    const td = Date.now();
    const sync = syncRun(A, 'customers', { timeoutMs: 30000 });
    const meMs = [];
    for (let i = 0; i < 6; i++) {
      const r = await call('me (1С недоступна)', 'GET', '/api/v1/me', { headers: C, quiet: true });
      meMs.push(r.ms);
      await sleep(150);
    }
    const prodDown = await call('catalog/products (1С недоступна)', 'GET', '/api/v1/catalog/products?limit=20', { headers: C });
    const sr = await sync;
    let orderDown = null;
    if (pList.length >= 6) orderDown = await sell(pList[5], 'cash');
    await be.control('fake', { method: 'POST', path: '/__fake/down', body: { down: false } });
    const s1 = await be.stats();
    checks.onecDown = {
      syncStatus: sr.fin?.json?.status ?? null,
      syncFinishMs: sr.ms,
      meMaxMs: Math.max(...meMs),
      productsStatus: prodDown.status,
      orderStatus: orderDown?.status ?? null,
      gatewaySleeps: s1.onec.gateway.sleeps - s0.onec.gateway.sleeps,
      onec503: (s1.onec.byStatus['503'] ?? 0) - (s0.onec.byStatus['503'] ?? 0),
      holdsOver3s: s1.gate.stats.holdsOver3s - s0.gate.stats.holdsOver3s,
      queueWaitsOver3s: s1.gate.stats.queueWaitsOver3s - s0.gate.stats.queueWaitsOver3s,
      totalMs: Date.now() - td,
    };
    checks.onecDown.ok = checks.onecDown.gatewaySleeps === 0 && checks.onecDown.holdsOver3s === 0 && checks.onecDown.queueWaitsOver3s === 0 && checks.onecDown.meMaxMs < 3000 && checks.onecDown.onec503 > 0; // порог — как у сторожа: GET /me ждёт лишь Argon2 step-up этого же сценария
    log(`        1С недоступна: ${JSON.stringify(checks.onecDown)}`);
  }

  const unexpected = results.filter((r) => (r.expect !== undefined ? r.status !== r.expect : r.status >= 400 || r.status === 0));
  return {
    totalSec: (Date.now() - t0) / 1000,
    requests: results.length,
    status5xx: results.filter((r) => r.status >= 500),
    unexpected,
    expectedNon2xx: results.filter((r) => r.expect !== undefined).map((r) => ({ name: r.name, status: r.status, code: r.code })),
    slowest: [...results].sort((a, b) => b.ms - a.ms).slice(0, 10),
    checks,
    results,
    ...out,
  };
}
