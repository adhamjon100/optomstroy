// «Обход» операций, которые вызывает приложение (WP-T1; 116 операций Dio по карте api-surface
// D:/optomstroy/.tmp/web_demo/maps/api-surface.json и openapi_ops.txt; + GET /health). Сценарии README и негативные
// ветки уже покрыли часть операций; здесь — остальные, по ролям, как их вызывают экраны. Каждый шаг ждёт свой
// документированный статус (2xx или объявленный 4xx ветки).
import { PIN, cashAmount, fillCart, orderBody, placeOrder, qty, sleep } from './dsl.mjs';
import { period } from './readme.mjs';

const enc = encodeURIComponent;

export async function walkAuth(w) {
  const { ctx, C, O } = w;
  ctx.begin('Обход: вход, сессии, профиль');
  const rf = await C.call('POST /auth/refresh', 'POST', '/auth/refresh', { noAuth: true, body: { refreshToken: C.refresh } });
  ctx.check('refresh → новая пара токенов', rf.status === 200 && !!rf.json?.accessToken && rf.json?.refreshToken !== C.refresh, { status: rf.status });
  C.token = rf.json?.accessToken; // check-secrets: allow — токен из ответа API в прогоне, не секрет; gitleaks:allow
  C.refresh = rf.json?.refreshToken;
  const un = await C.call('POST /auth/unlock (PIN)', 'POST', '/auth/unlock', { noAuth: true, body: { method: 'pin', refreshToken: C.refresh, pin: PIN } });
  ctx.check('разблокировка по PIN → пара токенов', un.status === 200 && !!un.json?.accessToken, { status: un.status, code: un.json?.code });
  if (un.json?.accessToken) {
    C.token = un.json.accessToken; // check-secrets: allow — токен из ответа API в прогоне, не секрет; gitleaks:allow
    C.refresh = un.json.refreshToken ?? C.refresh;
  }
  // вторая сессия кассира на другом устройстве: переименовать свою, отозвать чужую (step-up session.revoke.other)
  const C2 = ctx.dev('android', { name: 'кассир 906 (второе устройство)' });
  await C2.login('+996777000906', { setPin: false });
  const list = await C.call('GET /auth/sessions', 'GET', '/auth/sessions');
  const mine = (list.json?.items ?? []).find((x) => x.isCurrent);
  const other = (list.json?.items ?? []).find((x) => !x.isCurrent && x.deviceId === C2.deviceId);
  const ren = await C.call('PATCH /auth/sessions/{id} (переименовать)', 'PATCH', `/auth/sessions/${mine?.id}`, { idem: true, body: { deviceName: 'Касса 1 (тест)' } });
  ctx.check('сессии: список и переименование', list.status === 200 && ren.status === 200 && ren.json?.deviceName === 'Касса 1 (тест)', { n: list.json?.items?.length, rename: ren.status });
  const rv = await C.withStepUp('DELETE /auth/sessions/{id} (чужое устройство)', 'DELETE', `/auth/sessions/${other?.id}`, { idem: false, expect: 204 });
  const gone = await C2.call('отозванная сессия → 401', 'GET', '/me', { expect: 401 });
  ctx.check('отзыв сессии другого устройства → 204; та сессия → 401', rv.final.status === 204 && gone.status === 401, { revoke: rv.final.status, first: rv.first.status, after: gone.json?.code });
  // выход: отдельная сессия руководителя
  const O2 = ctx.dev('windows', { name: 'руководитель 909 (второе устройство)' });
  await O2.login('+996777000909', { setPin: false });
  const lo = await O2.call('POST /auth/logout', 'POST', '/auth/logout', { idem: true, body: { reason: 'user' }, expect: 204 });
  const lo2 = await O2.call('после выхода → 401', 'GET', '/me', { expect: 401 });
  ctx.check('выход → 204; токен больше не действует', lo.status === 204 && lo2.status === 401, { logout: lo.status, after: lo2.status });
  // выход везде (step-up session.logout_all) — покупатель 903
  const N = w.N;
  const la = await N.withStepUp('POST /auth/logout-all', 'POST', '/auth/logout-all', { expect: 204 });
  const la2 = await N.call('после «выйти везде» → 401', 'GET', '/me', { expect: 401 });
  ctx.check('«выйти на всех устройствах» → 204; сессии отозваны', la.final.status === 204 && la2.status === 401, { first: la.first.status, final: la.final.status, after: la2.status });

  // профиль, настройки, согласия, биометрия, смена PIN и номера
  const me = (await w.S.call('GET /me (продавец)', 'GET', '/me')).json;
  const pr = await w.S.call('PATCH /me/profile', 'PATCH', '/me/profile', { idem: true, body: { fullName: 'Тестов Продавец', rowVersion: me?.profile?.rowVersion } });
  ctx.check('профиль: PATCH /me/profile → 200', pr.status === 200, { status: pr.status, code: pr.json?.code });
  const cm = (await C.call('GET /me (кассир)', 'GET', '/me')).json;
  const st = await C.call('PUT /me/settings', 'PUT', '/me/settings', {
    idem: true,
    body: { locale: 'ru', scanner: { mode: 'hid', suffix: 'enter' }, scanAddsToCart: true, printer: { defaultFormat: 'thermal80', autoPrint: false }, catalogView: 'list', defaultWarehouseId: w.wh[0]?.id, idleLockMinutes: 30, rowVersion: cm?.settings?.rowVersion },
  });
  ctx.check('настройки: PUT /me/settings → 200', st.status === 200 && st.json?.catalogView === 'list', { status: st.status, code: st.json?.code });
  const bio = await C.withStepUp('POST /me/biometrics', 'POST', '/me/biometrics', { body: { enabled: true, biometricClass: 'windows_hello', consent: { kind: 'biometrics_device', version: '2026-10-01', granted: true } }, expect: 200 });
  ctx.check('биометрия: включение со step-up → 200', bio.final.status === 200, { first: bio.first.status, final: bio.final.status, code: bio.final.json?.code });
  const cons = await w.K.call('POST /me/consents (sms)', 'POST', '/me/consents', { idem: true, body: { kind: 'sms', version: '2026-10-01', granted: true } });
  ctx.check('согласие на SMS → 200', cons.status === 200, { status: cons.status, code: cons.json?.code });
  const pin = await O.withStepUp('POST /me/pin (смена PIN)', 'POST', '/me/pin', { body: { newPin: '604817' }, expect: 204 });
  ctx.check('смена PIN со step-up → 204', pin.final.status === 204 && pin.first.status === 403, { first: pin.first.status, final: pin.final.status });
  if (pin.final.status === 204) O.pin = '604817';
  const X = ctx.dev('android', { name: 'покупатель 908 (смена номера)' });
  await X.login('+996777000908');
  await X.registerCustomer({ fullName: 'Покупатель Смена Номера', label: 'регистрация 908' });
  const chg = await X.withStepUp('POST /me/phone/change/request', 'POST', '/me/phone/change/request', { body: { newPhone: '+996777000948' }, expect: 202 });
  const cc = await X.call('POST /me/phone/change/confirm', 'POST', '/me/phone/change/confirm', { idem: true, body: { challengeId: chg.final.json?.challengeId, code: '246810' } });
  const me2 = await X.call('GET /me (новый номер)', 'GET', '/me');
  ctx.check('смена номера: запрос со step-up → 202, код → 200, номер сменился', chg.final.status === 202 && cc.status === 200 && me2.json?.profile?.phone === '+996777000948', { request: chg.final.status, confirm: cc.status, code: cc.json?.code, phone: me2.json?.profile?.phone });
  const sp = await C.call('GET /settings/public', 'GET', '/settings/public');
  ctx.check('публичные настройки: minAppVersion из pubspec', /windows=\d/.test(sp.json?.minAppVersion ?? ''), { minAppVersion: sp.json?.minAppVersion, features: sp.json?.features });
}

export async function walkRegistration(w) {
  const { ctx, C, SS } = w;
  ctx.begin('Обход: привязка покупателя к карточке «1С»');
  // самоотказ: номер «ОсОО Без долга (тест)»
  const R = ctx.dev('android', { name: 'покупатель 103' });
  await R.login('+996700000103');
  await R.registerCustomer({ fullName: 'Покупатель Отказ', label: 'регистрация 103' });
  const m = await R.call('GET /registration/customer-match', 'GET', '/registration/customer-match');
  const rj = await R.call('POST /registration/customer-match/reject', 'POST', '/registration/customer-match/reject', { body: { linkId: m.json?.linkId } });
  ctx.check('«Это не я» → отказ от привязки', m.json?.status === 'proposed' && rj.status === 200, { match: m.json?.status, reject: rj.status, status: rj.json?.status });
  // привязки, которые решает сотрудник (step-up customer.link.resolve): 104 — подтвердить, 105 — отклонить
  for (const [phone, act] of [
    ['+996700000104', 'confirm'],
    ['+996700000105', 'reject'],
  ]) {
    const D = ctx.dev('android', { name: `покупатель ${phone.slice(-3)}` });
    await D.login(phone);
    await D.registerCustomer({ fullName: act === 'confirm' ? 'Покупатель Подтверждение' : 'Покупатель Отклонение', label: `регистрация ${phone.slice(-3)}` });
  }
  const A = w.A;
  const pl = await A.call('GET /customers?linkStatus=proposed (админ)', 'GET', '/customers?linkStatus=proposed&limit=50');
  const withLinks = [];
  for (const c of pl.json?.items ?? []) {
    const d = await A.call('GET /customers/{id}?include=links', 'GET', `/customers/${c.id}?include=links,contacts,receivable,discounts`);
    const link = (d.json?.links ?? []).find((l) => l.status === 'proposed');
    if (link) withLinks.push({ c: d.json, link });
  }
  const phoneOf = (x) => (x.c.phones ?? []).map((p) => p.value ?? p).join(',');
  const toConfirm = withLinks.find((x) => phoneOf(x).includes('700000104')) ?? withLinks[0];
  const toReject = withLinks.find((x) => phoneOf(x).includes('700000105')) ?? withLinks[1];
  ctx.check('сотрудник видит предложенные привязки', withLinks.length >= 2, { proposed: pl.json?.items?.length, withLinks: withLinks.length });
  if (toConfirm) {
    const r = await A.withStepUp('POST /customers/{id}/links/{linkId}/confirm', 'POST', `/customers/${toConfirm.c.id}/links/${toConfirm.link.id}/confirm`, { body: { comment: 'Проверено по документу (тест)' }, expect: 200 });
    ctx.check('сотрудник подтверждает привязку → 200', r.final.status === 200, { first: r.first.status, final: r.final.status, code: r.final.json?.code });
  }
  if (toReject) {
    const r = await A.withStepUp('POST /customers/{id}/links/{linkId}/reject', 'POST', `/customers/${toReject.c.id}/links/${toReject.link.id}/reject`, { body: { comment: 'Не совпадает (тест)' }, expect: 200 });
    ctx.check('сотрудник отклоняет привязку → 200', r.final.status === 200, { first: r.first.status, final: r.final.status, code: r.final.json?.code });
  }
}

export async function walkCatalog(w) {
  const { ctx, S, C } = w;
  ctx.begin('Обход: каталог, поиск, избранное, недавние');
  const cats = await S.call('GET /catalog/categories', 'GET', '/catalog/categories');
  const etag = cats.headers.etag;
  const nm = await S.call('GET /catalog/categories If-None-Match → 304', 'GET', '/catalog/categories', { headers: { 'If-None-Match': etag ?? '' }, expect: [304, 200] });
  ctx.check('категории: ETag и 304 по If-None-Match', !!etag && nm.status === 304, { etag: !!etag, status: nm.status });
  const leaf = (cats.json?.items ?? []).find((c) => (c.productsCount ?? 1) > 0) ?? cats.json?.items?.[0];
  await S.call('GET /catalog/categories?parentId', 'GET', `/catalog/categories?parentId=${leaf?.id}&depth=2`);
  const p1 = await S.call('GET /catalog/products (категория)', 'GET', `/catalog/products?categoryId=${leaf?.id}&includeSubcategories=true&limit=20&sort=price:asc`);
  const page1 = await S.call('GET /catalog/products?limit=30', 'GET', '/catalog/products?limit=30&sort=name:asc');
  const page2 = await S.call('GET /catalog/products?cursor', 'GET', `/catalog/products?limit=30&sort=name:asc&cursor=${enc(page1.json?.nextCursor ?? '')}`);
  const overlap = (page2.json?.items ?? []).filter((x) => (page1.json?.items ?? []).some((y) => y.id === x.id)).length;
  ctx.check('товары: курсор без повторов', p1.status === 200 && page2.status === 200 && (page2.json?.items ?? []).length > 0 && overlap === 0, { page2: page2.json?.items?.length, overlap });
  const variantful = (await S.call('товары с вариантами', 'GET', '/catalog/products?limit=100&sort=sku:asc')).json?.items?.find((p) => p.hasVariants);
  const vv = await S.call('GET /catalog/products/{id}/variants', 'GET', `/catalog/products/${(variantful ?? w.p(0)).id}/variants`);
  ctx.check('варианты товара', vv.status === 200 && (vv.json?.items ?? []).length > 0, { hasVariants: !!variantful, n: vv.json?.items?.length });
  await S.call('GET /catalog/warehouses', 'GET', '/catalog/warehouses');
  // офлайн-выгрузка каталога (как SyncScheduler приложения): все сущности страницами по 200
  const ents = ['categories', 'products', 'variants', 'attributes', 'units', 'barcodes', 'images', 'warehouses', 'stock', 'prices', 'packagings'];
  const syncCounts = {};
  let barcode = null;
  for (const e of ents) {
    let since;
    let n = 0;
    for (let pg = 0; pg < 20; pg++) {
      const r = await S.call(`GET /catalog/sync/${e}`, 'GET', `/catalog/sync/${e}?limit=200${since ? `&since=${enc(since)}` : ''}`, { expect: [200, 400, 404] });
      if (r.status !== 200) {
        syncCounts[e] = r.status;
        break;
      }
      n += (r.json?.items ?? []).length;
      if (e === 'barcodes' && !barcode) barcode = (r.json?.items ?? []).find((b) => !b.packagingId)?.barcode;
      since = r.json?.nextCursor ?? since;
      if (!r.json?.hasMore) break;
    }
    syncCounts[e] ??= n;
  }
  ctx.check('выгрузка каталога /catalog/sync/{entity} до hasMore=false', syncCounts.products > 0 && syncCounts.prices > 0 && syncCounts.barcodes > 0, syncCounts);
  const bc = await C.call('GET /search/barcode/{value}', 'GET', `/search/barcode/${enc(barcode ?? '0')}`);
  ctx.check('поиск по штрихкоду → товар и вариант', bc.status === 200 && !!bc.json?.product?.id && !!bc.json?.variant?.id, { status: bc.status, type: bc.json?.barcodeType });
  const fts = await S.call('GET /search/products (слово)', 'GET', `/search/products?q=${enc('смеситель')}&limit=10`);
  ctx.check('полнотекстовый поиск «смеситель»', fts.status === 200 && (fts.json?.items ?? []).length > 0, { n: fts.json?.items?.length, matchType: fts.json?.items?.[0]?.matchType });
  await S.call('GET /search/products (без остатка, фильтр цены)', 'GET', `/search/products?q=${enc('кран')}&inStock=false&priceMin=10.00&priceMax=99999.00&limit=10`);
  // недавние
  await S.call('просмотр карточки (для «Недавних»)', 'GET', `/catalog/products/${w.p(14).id}`);
  const rec = await S.poll('GET /catalog/products/recent', 'GET', '/catalog/products/recent?limit=20', (r) => (r.json?.items ?? []).some((x) => x.id === w.p(14).id), { timeoutMs: 5000, everyMs: 200 });
  const clr = await S.call('DELETE /catalog/products/recent', 'DELETE', '/catalog/products/recent', { expect: 204 });
  const rec2 = await S.call('недавние после очистки', 'GET', '/catalog/products/recent?limit=20');
  ctx.check('недавние: просмотр попадает, очистка → 204 и пусто', rec.pollOk && clr.status === 204 && (rec2.json?.items ?? []).length === 0, { found: rec.pollOk, clear: clr.status, after: rec2.json?.items?.length });
  // избранные товары
  const f1 = await S.call('PUT /favorites/products/{id}', 'PUT', `/favorites/products/${w.p(15).id}`, { expect: 204 });
  const f2 = await S.call('PUT /favorites/products/{id} (повтор)', 'PUT', `/favorites/products/${w.p(15).id}`, { expect: 204 });
  const fl = await S.call('GET /favorites/products', 'GET', '/favorites/products?limit=50');
  const fd = await S.call('DELETE /favorites/products/{id}', 'DELETE', `/favorites/products/${w.p(15).id}`, { expect: 204 });
  ctx.check('избранное: двойной PUT идемпотентен, DELETE убирает', f1.status === 204 && f2.status === 204 && (fl.json?.items ?? []).filter((x) => x.id === w.p(15).id).length === 1 && fd.status === 204, { put: [f1.status, f2.status], inList: (fl.json?.items ?? []).filter((x) => x.id === w.p(15).id).length, del: fd.status });
}

export async function walkCart(w) {
  const { ctx, C } = w;
  ctx.begin('Обход: корзина, отложенные');
  let cart = await fillCart(C, [{ p: w.p(16), q: '1' }, { p: w.p(17), q: '2' }], { label: 'корзина (обход)' });
  const wh2 = w.wh[1] ?? w.wh[0];
  const up = await C.call('PATCH /cart (склад)', 'PATCH', '/cart', { idem: true, body: { warehouseId: wh2.id, rowVersion: cart.rowVersion } });
  cart = up.json ?? cart;
  const back = await C.call('PATCH /cart (склад обратно)', 'PATCH', '/cart', { idem: true, body: { warehouseId: w.wh[0].id, rowVersion: cart.rowVersion } });
  cart = back.json ?? cart;
  ctx.check('смена склада корзины → 200', up.status === 200 && back.status === 200 && back.json?.warehouseId === w.wh[0].id, { up: up.status, back: back.status });
  const inc = await C.call('PUT /cart/items mode=increment', 'PUT', `/cart/items/${w.p(16).defaultVariantId}`, { idem: true, body: { quantity: qty(w.p(16), '1'), rowVersion: cart.rowVersion, mode: 'increment' } });
  cart = inc.json ?? cart;
  ctx.check('mode=increment складывает количество', Number(cart.items?.find((i) => i.variantId === w.p(16).defaultVariantId)?.quantity?.value) === 2, { q: cart.items?.find((i) => i.variantId === w.p(16).defaultVariantId)?.quantity?.value });
  const del = await C.call('DELETE /cart/items/{variantId}', 'DELETE', `/cart/items/${w.p(17).defaultVariantId}`);
  cart = del.json ?? cart;
  ctx.check('удаление строки корзины', del.status === 200 && !(cart.items ?? []).some((i) => i.variantId === w.p(17).defaultVariantId), { status: del.status });
  const cs = await C.call('POST /cart/customer', 'POST', '/cart/customer', { idem: true, body: { customerId: w.noDebt.id, rowVersion: cart.rowVersion } });
  const cu = await C.call('DELETE /cart/customer', 'DELETE', '/cart/customer');
  cart = cu.json ?? cart;
  ctx.check('клиент корзины: выбрать и снять', cs.status === 200 && cu.status === 200 && !cu.json?.customer, { set: cs.status, unset: cu.status });
  const pk = await C.call('POST /cart/park', 'POST', '/cart/park', { idem: true, body: { name: 'Отложенная 1 (тест)', rowVersion: cart.rowVersion }, expect: 201 });
  const pl = await C.call('GET /cart/parked', 'GET', '/cart/parked?scope=own&limit=20');
  const pid = pk.json?.parked?.id ?? pk.json?.id ?? (pl.json?.items ?? [])[0]?.id;
  const rs = await C.call('POST /cart/parked/{id}/resume', 'POST', `/cart/parked/${pid}/resume`, { idem: true, body: { replaceActive: true } });
  ctx.check('отложить → список → вернуть', pk.status === 201 && (pl.json?.items ?? []).some((x) => x.id === pid) && rs.status === 200, { park: pk.status, inList: (pl.json?.items ?? []).length, resume: rs.status });
  cart = rs.json?.cart ?? rs.json ?? (await C.call('GET /cart', 'GET', '/cart')).json;
  const cur = (await C.call('GET /cart (после возврата)', 'GET', '/cart')).json;
  const pk2 = await C.call('POST /cart/park (вторая)', 'POST', '/cart/park', { idem: true, body: { name: 'Отложенная 2 (тест)', rowVersion: cur.rowVersion }, expect: 201 });
  const pd = await C.call('DELETE /cart/parked/{id}', 'DELETE', `/cart/parked/${pk2.json?.parked?.id ?? pk2.json?.id}`, { expect: 204 });
  ctx.check('удаление отложенной → 204', pd.status === 204, { status: pd.status });
  const all = await w.SS.call('GET /cart/parked?scope=all (старший)', 'GET', '/cart/parked?scope=all&limit=20');
  ctx.check('отложенные всех (старший продавец)', all.status === 200, { status: all.status, n: all.json?.items?.length });
}

export async function walkOrders(w) {
  const { ctx, C, A, S } = w;
  ctx.begin('Обход: заказы, документы, платежи');
  const list = await C.call('GET /orders', 'GET', '/orders?limit=20&sort=createdAt:desc&include=statusCounts');
  ctx.check('список заказов со счётчиками статусов', list.status === 200 && (list.json?.items ?? []).length > 0, { n: list.json?.items?.length, counts: !!list.json?.statusCounts });
  await C.call('GET /orders?status&paymentMethod', 'GET', `/orders?status=awaiting_payment&status=approved&paymentMethod=cash&${period()}&limit=20`);
  const any = w.orders.cashOverdue;
  const full = await C.call('GET /orders/{id}?include', 'GET', `/orders/${any.id}?include=items,payments,history,documents`);
  ctx.check('карточка заказа с историей и документами', full.status === 200 && Array.isArray(full.json?.items), { status: full.json?.status });
  await C.call('GET /orders/{id}?refreshFromOnec', 'GET', `/orders/${any.id}?refreshFromOnec=true`);
  const inv = await C.call('счёт PDF A4', 'GET', `/orders/${any.id}/documents/invoice.pdf?format=a4`);
  const rc = await C.call('товарный чек A4 (копия)', 'GET', `/orders/${any.id}/documents/receipt.pdf?format=a4&copy=true`);
  ctx.check('документы PDF: счёт и копия чека', inv.magic === '%PDF-' && rc.magic === '%PDF-', { invoice: inv.status, receipt: rc.status });
  // отмена своего неоплаченного заказа
  const oc = await placeOrder(C, w.p(18), 'cash', { label: 'заказ под отмену' });
  const cn = await C.withStepUp('POST /orders/{id}/cancel', 'POST', `/orders/${oc.order.json?.id}/cancel`, { body: { reason: 'Покупатель передумал (тест)', reasonCode: 'customer_refused', refundIntent: 'none' }, expect: 200 });
  // Контракт orders_cancel: (а) status cancelled — документ «1С» ещё не создан; (б) прежний статус + cancelRequested —
  // outbox уже отправляет заказ. Какой исход — гонка с фоновой отправкой (fix round 2: ≈ 2 из 30 на бандле и на
  // эталоне одинаково; .tmp/web_demo/fix2/probe-cancel-race.mjs), оба — по контракту.
  ctx.check('отмена заказа → cancelled или запрос отмены', cn.final.status === 200 && (cn.final.json?.status === 'cancelled' || cn.final.json?.cancelRequested === true), { first: cn.first.status, final: cn.final.status, status: cn.final.json?.status, cancelRequested: cn.final.json?.cancelRequested });
  // «1С» отклонила заказ → ручная привязка по номеру документа «1С» (external-ids имитатора)
  await ctx.panel('POST onec/orders/mode', { mode: 'reject', failNext: 1 });
  const rj = await placeOrder(C, w.p(19), 'cash', { label: 'заказ (1С отклонит)' });
  const failed = await C.poll('заказ submit_failed', 'GET', `/orders/${rj.order.json?.id}`, (r) => r.json?.status === 'submit_failed', { timeoutMs: 30000 });
  const st = await ctx.panel('GET state');
  const manual = st.orders.find((x) => x.id === rj.order.json?.id)?.manualOnecNumber;
  const lk = await A.withStepUp('POST /orders/{id}/onec-link', 'POST', `/orders/${rj.order.json?.id}/onec-link`, { body: { onecNumber: manual ?? 'ОС00-000000', reason: 'Заказ заведён в 1С вручную (тест)' }, expect: 200 });
  ctx.check('отказ «1С» → submit_failed → ручная привязка к документу «1С» → 200', failed.json?.status === 'submit_failed' && !!manual && lk.final.status === 200, { status: failed.json?.status, manual, link: lk.final.status, code: lk.final.json?.code });
  // уведомления (отказ «1С» → уведомление автору)
  const nl = await C.poll('GET /notifications', 'GET', '/notifications?limit=50', (r) => (r.json?.items ?? []).length > 0, { timeoutMs: 15000 });
  const n0 = nl.json?.items?.[0];
  const rd = n0 ? await C.call('POST /notifications/{id}/read', 'POST', `/notifications/${n0.id}/read`) : null;
  await C.call('GET /notifications?unread', 'GET', '/notifications?unread=true&limit=20');
  const ra = await C.call('POST /notifications/read-all', 'POST', '/notifications/read-all');
  ctx.check('уведомления: есть, отметка одного и всех', !!n0 && rd?.status === 200 && ra.status === 200, { n: nl.json?.items?.length, kind: n0?.kind, read: rd?.status, all: ra.status });

  // платежи: GET, refreshStatus; QR — ручное подтверждение и аннулирование (step-up)
  const paid = w.orders.cashOverdue.payments?.[0]?.id ?? (await C.call('заказ (платежи)', 'GET', `/orders/${w.orders.cashOverdue.id}`)).json?.payments?.[0]?.id;
  const pg = await C.call('GET /payments/{id}', 'GET', `/payments/${paid}`);
  ctx.check('платёж по id', pg.status === 200 && !!pg.json?.status, { status: pg.json?.status });
  await ctx.panel('POST qr/config', { paidAfterPolls: 0 });
  const q1 = await placeOrder(C, w.p(20), 'qr_bakai', { label: 'QR под ручное подтверждение' });
  const qp1 = q1.order.json?.payments?.[0];
  await C.call('GET /payments/{id}?refreshStatus', 'GET', `/payments/${qp1?.id}?refreshStatus=true`);
  const cm = await C.withStepUp('POST /payments/{id}/confirm-manual', 'POST', `/payments/${qp1?.id}/confirm-manual`, { body: { bankReference: 'BK-TEST-0001', receivedAmount: { amount: qp1?.amount?.amount ?? q1.order.json?.total?.amount, currency: 'KGS' }, comment: 'Оплата видна в банке (тест)' }, expect: [200, 409, 422] });
  ctx.check('QR: ручное подтверждение со step-up обработано (200 или объявленный отказ)', [200, 409, 422].includes(cm.final.status), { first: cm.first.status, final: cm.final.status, status: cm.final.json?.status, code: cm.final.json?.code });
  const q2 = await placeOrder(C, w.p(21), 'qr_bakai', { label: 'QR под аннулирование' });
  const qp2 = q2.order.json?.payments?.[0];
  const vd = await C.withStepUp('POST /payments/{id}/void', 'POST', `/payments/${qp2?.id}/void`, { body: { reason: 'Ошибка кассира (тест)', reasonCode: 'cashier_error' }, expect: [200, 409, 422] });
  ctx.check('аннулирование платежа со step-up обработано', [200, 409, 422].includes(vd.final.status), { first: vd.first.status, final: vd.final.status, status: vd.final.json?.status, code: vd.final.json?.code });
  await ctx.panel('POST qr/config', { paidAfterPolls: 2 });
  w.orders.qrPending = q2.order.json;
  // дашборд кассира, журнал операций
  const db = await C.call('GET /pos/dashboard', 'GET', '/pos/dashboard');
  ctx.check('дашборд кассира', db.status === 200, { keys: Object.keys(db.json ?? {}).slice(0, 8) });
  await ctx.settle();
  const tx = await A.call('GET /transactions (админ)', 'GET', `/transactions?${period()}&limit=200`);
  const kinds = new Set((tx.json?.items ?? []).map((x) => x.kind));
  ctx.check('журнал операций: order_created, payment_received, credit_sale_approved', ['order_created', 'payment_received', 'credit_sale_approved'].every((k) => kinds.has(k)) && tx.json?.summary !== undefined, { kinds: [...kinds].sort() });
  const t0 = tx.json?.items?.[0];
  const td = await A.call('GET /transactions/{id}', 'GET', `/transactions/${t0?.id}`);
  ctx.check('операция по id', td.status === 200, { kind: td.json?.kind });
  const mineTx = await S.call('GET /transactions (продавец: свои)', 'GET', `/transactions?${period()}&mine=true&limit=50`);
  ctx.check('продавец видит свои операции без summary', mineTx.status === 200 && mineTx.json?.summary === undefined, { n: mineTx.json?.items?.length });
}

export async function walkCustomers(w) {
  const { ctx, C, SS } = w;
  ctx.begin('Обход: клиенты, долги, скидки, избранное');
  const lst = await C.call('GET /customers', 'GET', '/customers?limit=20&include=receivable&sort=name:asc');
  const debt = await C.call('GET /customers?hasDebt', 'GET', '/customers?hasDebt=true&isOverdue=true&limit=20');
  ctx.check('список клиентов и фильтр долга', lst.status === 200 && (debt.json?.items ?? []).some((x) => x.id === w.overdue.id), { n: lst.json?.items?.length, overdue: debt.json?.items?.length });
  const phone = '+996777000955';
  const cc = await C.call('POST /customers', 'POST', '/customers', { idem: true, body: { name: 'Клиент из POS (тест)', customerType: 'individual', phones: [phone] }, expect: 201 });
  ctx.check('новый клиент из POS → 201, onecStatus pending', cc.status === 201 && cc.json?.onecStatus === 'pending', { status: cc.status, onecStatus: cc.json?.onecStatus });
  const dup = await C.call('POST /customers (тот же телефон)', 'POST', '/customers', { idem: true, body: { name: 'Клиент из POS дубль (тест)', customerType: 'individual', phones: [phone] }, expect: 409 });
  ctx.check('тот же телефон → 409 CUSTOMER_DUPLICATE_SUSPECTED', dup.json?.code === 'CUSTOMER_DUPLICATE_SUSPECTED', { code: dup.json?.code });
  const conf = await C.poll('клиент подтверждён «1С»', 'GET', `/customers/${cc.json?.id}`, (r) => r.json?.onecStatus === 'confirmed', { timeoutMs: 30000, everyMs: 700 });
  ctx.check('клиент из POS → outbox → «1С» → confirmed', conf.json?.onecStatus === 'confirmed', { onecStatus: conf.json?.onecStatus });
  w.posCustomer = conf.json;
  const ord = await C.call('GET /customers/{id}/orders', 'GET', `/customers/${w.within.id}/orders?limit=50&source=all`);
  ctx.check('история продаж клиента (реализации «1С»)', ord.status === 200 && (ord.json?.items ?? []).length > 0, { n: ord.json?.items?.length, historyFrom: ord.json?.historyFrom });
  const cd = await C.call('GET /customers/{id}/discounts', 'GET', `/customers/${w.within.id}/discounts`);
  const rules = await C.call('GET /discounts/rules', 'GET', `/discounts/rules?customerId=${w.within.id}`);
  ctx.check('скидки клиента и правила скидок', cd.status === 200 && rules.status === 200 && typeof rules.json?.manualDiscountLimitPercent === 'string', { customer: cd.status, rules: rules.json?.rules?.length, limit: rules.json?.manualDiscountLimitPercent });
  const docs = await C.withStepUp('GET /customers/{id}/receivables?include=documents', 'GET', `/customers/${w.overdue.id}/receivables?include=documents`, { idem: false, expect: 200 });
  ctx.check('долг с документами (step-up при необходимости)', docs.final.status === 200, { first: docs.first.status, final: docs.final.status, docs: docs.final.json?.documents?.length });
  const rr = await C.withStepUp('POST /customers/{id}/receivables/refresh', 'POST', `/customers/${w.overdue.id}/receivables/refresh`, { idem: false, expect: 200 });
  ctx.check('обновить долг из «1С» → 200', rr.final.status === 200, { first: rr.first.status, final: rr.final.status, code: rr.final.json?.code });
  const od = await C.call('GET /receivables/overdue', 'GET', '/receivables/overdue?limit=20&sort=overdueAmount:desc');
  ctx.check('просроченные долги', od.status === 200 && (od.json?.items ?? []).length > 0, { n: od.json?.items?.length });
  const fp = await C.call('PUT /favorites/customers/{id}', 'PUT', `/favorites/customers/${w.within.id}`, { expect: 204 });
  const fl = await C.call('GET /favorites/customers', 'GET', '/favorites/customers?limit=20');
  const fd = await C.call('DELETE /favorites/customers/{id}', 'DELETE', `/favorites/customers/${w.within.id}`, { expect: 204 });
  ctx.check('избранные клиенты: PUT, список, DELETE', fp.status === 204 && (fl.json?.items ?? []).some((x) => x.id === w.within.id) && fd.status === 204, { put: fp.status, del: fd.status });
  const sf = await SS.call('GET /search/customers?favorite', 'GET', `/search/customers?q=${enc('Покупатель')}&favorite=false&limit=10`);
  ctx.check('поиск клиентов старшим продавцом', sf.status === 200, { n: sf.json?.items?.length });
}

export async function walkReturns(w) {
  const { ctx, C, SS } = w;
  ctx.begin('Обход: возвраты');
  const o = w.orders.shipped;
  const line = o.items[0];
  const item = (v) => [{ orderLineNo: line.lineNo, quantity: { value: v, unitId: line.quantity.unitId, packagingId: null } }];
  const d1 = await C.call('POST /returns (черновик)', 'POST', '/returns', { idem: true, body: { orderId: o.id, reasonCode: 'defect', reasonComment: 'Скол (тест)', items: item('1') }, expect: 201 });
  const up = await C.call('PATCH /returns/{id}', 'PATCH', `/returns/${d1.json?.id}`, { idem: true, body: { reasonCode: 'wrong_item', reasonComment: 'Не тот цвет (тест)', rowVersion: d1.json?.rowVersion } });
  const g = await C.call('GET /returns/{id}', 'GET', `/returns/${d1.json?.id}`);
  const lst = await C.call('GET /returns?orderId', 'GET', `/returns?orderId=${o.id}&limit=20`);
  ctx.check('возврат: черновик, правка, карточка, список', d1.status === 201 && up.status === 200 && g.json?.reasonCode === 'wrong_item' && (lst.json?.items ?? []).some((x) => x.id === d1.json?.id), { create: d1.status, update: up.status, reason: g.json?.reasonCode });
  const del = await C.call('DELETE /returns/{id} (черновик)', 'DELETE', `/returns/${d1.json?.id}?rowVersion=${g.json?.rowVersion}`, { expect: 204 });
  ctx.check('удаление черновика → 204', del.status === 204, { status: del.status });
  const submit = async (label) => {
    const d = await C.call(`${label}: POST /returns`, 'POST', '/returns', { idem: true, body: { orderId: o.id, reasonCode: 'defect', items: item('1') }, expect: 201 });
    const s = await C.withStepUp(`${label}: POST /returns/{id}/submit`, 'POST', `/returns/${d.json?.id}/submit`, { body: { rowVersion: d.json?.rowVersion, comment: 'Осмотр (тест)' }, expect: 200 });
    return s.final;
  };
  const s1 = await submit('возврат A');
  const acc = await SS.withStepUp('POST /returns/{id}/accept', 'POST', `/returns/${s1.json?.id}/accept`, { body: { rowVersion: s1.json?.rowVersion, comment: 'Принят (тест)' }, expect: 200 });
  ctx.check('возврат A: submit → accept старшим (step-up)', s1.json?.status === 'submitted' && acc.final.json?.status === 'accepted', { submit: s1.json?.status, accept: acc.final.json?.status, code: acc.final.json?.code });
  const rj = await SS.withStepUp('POST /returns/{id}/reject (принятый)', 'POST', `/returns/${acc.final.json?.id ?? s1.json?.id}/reject`, { body: { rowVersion: acc.final.json?.rowVersion, reason: 'Повторный осмотр: дефекта нет (тест)' }, expect: 200 });
  ctx.check('возврат A: принятый в POS можно отклонить', rj.final.json?.status === 'rejected', { status: rj.final.json?.status, code: rj.final.json?.code });
  const s2 = await submit('возврат B');
  w.returnB = s2.json;
  ctx.check('возврат B отправлен (остаётся для «1С»)', s2.json?.status === 'submitted', { status: s2.json?.status });
  const all = await C.call('GET /returns?status', 'GET', '/returns?status=submitted&limit=20');
  ctx.check('список возвратов по статусу', all.status === 200, { n: all.json?.items?.length });
}

export async function walkSync(w) {
  const { ctx, A, SS } = w;
  ctx.begin('Обход: синхронизация и outbox');
  await ctx.settle();
  const st = await A.call('GET /sync/status', 'GET', '/sync/status');
  // список прогонов одной сущности: первый прогон receivables после старта зависит от гонки догоняния (WP-T1 C7)
  const runs = await A.call('GET /sync/runs', 'GET', '/sync/runs?entity=stock&limit=20');
  const r1 = await A.call('GET /sync/runs?entity', 'GET', '/sync/runs?entity=customers&status=success&limit=5');
  const fin = await A.poll('GET /sync/runs/{id} (ручной прогон)', 'GET', `/sync/runs/${w.syncRunId}`, (r) => ['success', 'partial', 'failed'].includes(r.json?.status), { timeoutMs: 60000 });
  const errs = await A.call('GET /sync/runs/{id}/errors', 'GET', `/sync/runs/${w.syncRunId}/errors?limit=20`);
  ctx.check('статус синхронизации, прогоны, прогон по id и его ошибки', st.status === 200 && runs.status === 200 && r1.status === 200 && fin.json?.status === 'success' && errs.status === 200, { overall: st.json?.overall, run: fin.json?.status, errors: errs.json?.items?.length });
  const ob = await SS.call('GET /sync/outbox (отправленные)', 'GET', '/sync/outbox?status=sent&status=confirmed&limit=50');
  await SS.call('GET /sync/outbox', 'GET', '/sync/outbox?limit=50');
  const any = (ob.json?.items ?? [])[0];
  const rt = any ? await SS.call('POST /sync/outbox/{id}/retry', 'POST', `/sync/outbox/${any.id}/retry`, { idem: true, expect: [202, 409, 422] }) : null;
  ctx.check('outbox: список и ручной повтор (202 или объявленный отказ для отправленной записи)', ob.status === 200 && !!rt && [202, 409, 422].includes(rt.status), { n: ob.json?.items?.length, status: any?.status, retry: rt?.status, code: rt?.json?.code });
  await SS.call('GET /sync/outbox?status=dead', 'GET', '/sync/outbox?status=dead&status=failed&aggregateType=order&limit=20');
}

export async function walkAdmin(w) {
  const { ctx, A } = w;
  ctx.begin('Обход: администрирование');
  const cr = await A.withStepUp('POST /admin/users', 'POST', '/admin/users', { body: { phone: '+996777000945', fullName: 'Тестов Новый Сотрудник (тест)', roles: ['seller'] }, expect: 201 });
  const uid = cr.final.json?.id ?? cr.final.json?.user?.id ?? cr.final.json?.appliedToUserId;
  ctx.check('создание сотрудника → 201 (пользователь или приглашение)', cr.final.status === 201, { first: cr.first.status, final: cr.final.status, kind: cr.final.json?.kind ?? (cr.final.json?.roles ? 'invitation?' : null) });
  // цель для остальных действий — существующий сотрудник 904 (вошёл по приглашению в README 5)
  const users = await A.call('GET /admin/users?q', 'GET', `/admin/users?q=${enc('Приглашённый')}&limit=10`);
  const target = (users.json?.items ?? [])[0] ?? { id: uid };
  const u = await A.call('GET /admin/users/{id}', 'GET', `/admin/users/${target.id}`);
  const roles = await A.withStepUp('PUT /admin/users/{id}/roles', 'PUT', `/admin/users/${target.id}/roles`, { body: { roles: ['seller'], reason: 'Перевод в продавцы (тест)', rowVersion: u.json?.rowVersion }, expect: 200 });
  const blk = await A.withStepUp('POST /admin/users/{id}/block', 'POST', `/admin/users/${target.id}/block`, { body: { blocked: true, reason: 'Проверка блокировки (тест)' }, expect: 200 });
  const unb = await A.withStepUp('POST /admin/users/{id}/block (снять)', 'POST', `/admin/users/${target.id}/block`, { body: { blocked: false, reason: 'Проверка завершена (тест)' }, expect: 200 });
  const lo = await A.withStepUp('POST /admin/users/{id}/logout-all', 'POST', `/admin/users/${target.id}/logout-all`, { expect: 204 });
  const pr = await A.withStepUp('DELETE /admin/users/{id}/pin', 'DELETE', `/admin/users/${target.id}/pin`, { idem: false, body: { reason: 'Забыл PIN (тест)' }, expect: 204 });
  const em = await A.withStepUp('POST /admin/users/{id}/emergency-login-code', 'POST', `/admin/users/${target.id}/emergency-login-code`, { idem: false, body: { reason: 'sms_unavailable', comment: 'Нет SMS (тест)' }, expect: 201 });
  ctx.check('сотрудник: роли, блокировка/разблокировка, выход везде, сброс PIN, аварийный код', roles.final.status === 200 && blk.final.json?.status === 'blocked' && unb.final.status === 200 && lo.final.status === 204 && pr.final.status === 204 && em.final.status === 201, { roles: roles.final.status, block: blk.final.json?.status, unblock: unb.final.status, logoutAll: lo.final.status, pinReset: pr.final.status, emergency: em.final.status });
  const inv = await A.withStepUp('POST /admin/invitations (под отзыв)', 'POST', '/admin/invitations', { body: { phone: '+996777000946', roles: ['seller'], fullName: 'Тестов Отозванный (тест)' }, expect: 201 });
  const il = await A.call('GET /admin/invitations', 'GET', '/admin/invitations?limit=20');
  const rv = await A.withStepUp('DELETE /admin/invitations/{id}', 'DELETE', `/admin/invitations/${inv.final.json?.id}`, { idem: false, expect: 204 });
  ctx.check('приглашения: создать, список, отозвать', inv.final.status === 201 && (il.json?.items ?? []).some((x) => x.id === inv.final.json?.id) && rv.final.status === 204, { create: inv.final.status, revoke: rv.final.status });
  const s0 = await A.call('GET /admin/settings', 'GET', '/admin/settings');
  const su = await A.withStepUp('PUT /admin/settings', 'PUT', '/admin/settings', { body: { settings: { lowStockThreshold: 6 }, rowVersion: s0.json?.rowVersion }, expect: 200 });
  const sb = await A.withStepUp('PUT /admin/settings (вернуть)', 'PUT', '/admin/settings', { body: { settings: { lowStockThreshold: 5 }, rowVersion: su.final.json?.rowVersion }, expect: 200 });
  ctx.check('настройки: изменить и вернуть (step-up, rowVersion)', su.final.json?.settings?.lowStockThreshold === 6 && sb.final.json?.settings?.lowStockThreshold === 5, { first: su.first.status, set: su.final.status, back: sb.final.status });
  const dl = await A.call('GET /admin/discount-limits', 'GET', '/admin/discount-limits');
  const du = await A.withStepUp('PUT /admin/discount-limits', 'PUT', '/admin/discount-limits', { body: { limits: dl.json?.limits, overrideRoles: dl.json?.overrideRoles, rowVersion: dl.json?.rowVersion }, expect: 200 });
  ctx.check('лимиты скидок: прочитать и сохранить', dl.status === 200 && du.final.status === 200, { get: dl.status, put: du.final.status, code: du.final.json?.code });
  await ctx.settle();
  const al = await A.call('GET /admin/audit-logs (фильтры)', 'GET', `/admin/audit-logs?${period()}&entityType=user&result=ok&limit=50`);
  ctx.check('аудит с фильтрами', al.status === 200, { n: al.json?.items?.length });
  // CSV в R1 выключен (403 «Экспорт отчётов в CSV недоступен в текущей версии») — ветка UI «недоступно»
  const csv = await w.O.call('отчёт о продажах CSV', 'GET', `/admin/reports/sales-summary?${period()}&groupBy=seller&format=csv`, { expect: [200, 403] });
  ctx.check('отчёт CSV: файл или объявленный отказ «недоступно в текущей версии»', (csv.status === 200 && /text\/csv/.test(csv.headers['content-type'] ?? '')) || (csv.status === 403 && csv.json?.code === 'FORBIDDEN'), { status: csv.status, ct: csv.headers['content-type'] });
  await w.O.call('долги: только на дату снимка', 'GET', '/admin/reports/receivables?asOfOnly=true');
  await w.O.call('сверка QR: несопоставленные', 'GET', `/admin/reports/qr-reconciliation?${period()}&status=unmatched`);
}

export const WALK = [walkAuth, walkRegistration, walkCatalog, walkCart, walkOrders, walkCustomers, walkReturns, walkSync, walkAdmin];
export { sleep, orderBody, cashAmount };
