// Сценарии README 1–6 (demo/README.md «Что попробовать») на уровне API (WP-T1; 7 — офлайн — проверяет WP-T2) и
// общая подготовка мира: сотрудники стенда, ожидание догоняния расписаний (клиенты и долги «1С»), товары, тестовые
// клиенты по demo/web/backend/pii-map.json («Покупатель Просрочка (тест)» и т. д.).
import { PIN, cashAmount, fillCart, orderBody, placeOrder, sellable, sleep } from './dsl.mjs';

export const NAMES = Object.freeze({
  overdue: 'Покупатель Просрочка (тест)',
  within: 'Покупатель Долг в лимите (тест)',
  limitExceeded: 'ОсОО Лимит превышен (тест)',
  noDebt: 'ОсОО Без долга (тест)',
});
const enc = encodeURIComponent;
export const period = () => `from=${enc(new Date(Date.now() - 2 * 86400e3).toISOString())}&to=${enc(new Date(Date.now() + 3600e3).toISOString())}`;

/** Подготовка: входы сотрудников, ожидание синхронизации клиентов/долгов, выбор товаров и клиентов. */
export async function setup(ctx) {
  ctx.begin('0. подготовка');
  const w = { ctx };
  const s = (await ctx.dev('windows', { name: 'служебный' }).call('GET /health', 'GET', '/health')).json;
  ctx.check('GET /health → ok', s?.status === 'ok', s);
  w.A = ctx.dev('windows', { name: 'админ 901' });
  w.C = ctx.dev('windows', { name: 'кассир 906' });
  w.SS = ctx.dev('windows', { name: 'старший 907' });
  w.O = ctx.dev('android', { name: 'руководитель 909' });
  await w.A.login('+996777000901');
  await w.C.login('+996777000906');
  await w.SS.login('+996777000907');
  await w.O.login('+996777000909');
  // Догоняние расписаний после ready: клиенты и долги «1С» приходят настоящей синхронизацией.
  // ожидание без записи: счётчики первого прогона receivables зависят от гонки догоняния (см. ниже)
  const ss = (await ctx.until(async () => (await w.A.call('GET /sync/status (ждём ok)', 'GET', '/sync/status', { record: false })).json, (j) => j?.overall === 'ok', { timeoutMs: 90000, everyMs: 1000 })).v;
  ctx.check('/sync/status overall=ok после догоняния', ss?.overall === 'ok', { overall: ss?.overall, stale: (ss?.entities ?? []).filter((e) => e.isStale).map((e) => e.entity) });
  // Долги «1С» после холодного старта: догоняние ставит receivables и customers одновременно; если receivables
  // выполнится раньше customers, снимков долга нет до следующего запуска по расписанию (находка WP-T1). Проверка — без
  // записи (результат зависит от гонки), затем — ручной запуск receivables администратором, как сделал бы он сам.
  const race = await ctx.until(async () => (await w.C.call('поиск «Просрочка»', 'GET', `/search/customers?q=${enc('Просрочка')}&include=receivable&limit=5`, { record: false })).json?.items?.[0], (x) => x?.isOverdue === true, { timeoutMs: 20000, everyMs: 1000 });
  const runs = (await w.A.call('прогоны receivables/customers', 'GET', '/sync/runs?limit=50', { record: false })).json?.items ?? [];
  const firstRecv = runs.filter((r) => r.entity === 'receivables').at(-1);
  const firstCust = runs.filter((r) => r.entity === 'customers').at(-1);
  w.coldStartDebts = { visibleWithin20s: race.ok, firstReceivables: firstRecv && { fetched: firstRecv.counts?.fetched, startedAt: firstRecv.startedAt }, firstCustomers: firstCust && { fetched: firstCust.counts?.fetched, finishedAt: firstCust.finishedAt } };
  ctx.log(`  долги после холодного старта без ручного запуска: ${JSON.stringify(w.coldStartDebts)}`);
  const su = await w.A.stepUp('sync.run.full', { label: 'step-up sync.run.full (долги)' });
  const run = await w.A.call('POST /sync/runs receivables', 'POST', '/sync/runs', { idem: true, stepUp: su, body: { entity: 'receivables', mode: 'incremental' }, expect: 202 });
  await w.A.poll('прогон receivables завершён', 'GET', `/sync/runs/${run.json?.id}`, (r) => ['success', 'partial', 'failed'].includes(r.json?.status), { timeoutMs: 60000 });
  const od = await w.C.poll('поиск «Просрочка» (долг виден)', 'GET', `/search/customers?q=${enc('Просрочка')}&include=receivable&limit=5`, (r) => r.json?.items?.[0]?.isOverdue === true, { timeoutMs: 30000, everyMs: 1000 });
  w.overdue = od.json?.items?.find((x) => x.name === NAMES.overdue);
  const find = async (q, name) => (await w.C.call(`поиск «${q}»`, 'GET', `/search/customers?q=${enc(q)}&include=receivable&limit=5`)).json?.items?.find((x) => x.name === name);
  w.within = await find('Долг в лимите', NAMES.within);
  w.limitEx = await find('Лимит превышен', NAMES.limitExceeded);
  w.noDebt = await find('Без долга', NAMES.noDebt);
  ctx.check('тестовые клиенты «1С» найдены (имена — pii-map.json), просрочка видна', w.overdue?.isOverdue === true && w.within && w.limitEx && w.noDebt, { overdue: w.overdue?.isOverdue, within: w.within?.hasDebt, limitEx: !!w.limitEx, noDebt: !!w.noDebt });
  w.products = await sellable(w.C, { limit: 200, maxPrice: 6000 });
  w.wh = (await w.C.call('склады', 'GET', '/catalog/warehouses')).json?.items ?? [];
  ctx.check('каталог: ≥ 24 недорогих товара в наличии', w.products.length >= 24, { n: w.products.length, skus: w.products.slice(0, 5).map((p) => p.sku) });
  w.p = (i) => w.products[i % w.products.length];
  w.orders = {};
  return w;
}

// ---------------------------------------------------------------------------------------------------------------
/** README 1. Продавец 902 (по приглашению): каталог, поиск, корзина со скидкой 5 %, заказ с оплатой по QR, чек PDF. */
export async function readme1(w) {
  const { ctx } = w;
  ctx.begin('README 1. продавец: продажа с оплатой по QR');
  const S = (w.S = ctx.dev('windows', { name: 'продавец 902' }));
  const v = await S.login('+996777000902');
  ctx.check('вход 902 → сотрудник «Продавец» по приглашению, первый PIN', v.json?.status === 'authenticated' && (v.json?.user?.roles ?? []).includes('seller') && v.json?.roleSource === 'invitation', { roles: v.json?.user?.roles, roleSource: v.json?.roleSource, nextStep: v.json?.nextStep });
  const sr = await S.call('поиск F4252', 'GET', `/search/products?q=F4252&limit=10`);
  ctx.check('поиск по артикулу F4252 → matchType sku', sr.json?.items?.[0]?.sku === 'F4252' && sr.json?.items?.[0]?.matchType === 'sku', sr.json?.items?.[0] && { sku: sr.json.items[0].sku, matchType: sr.json.items[0].matchType });
  const card = await S.call('карточка товара', 'GET', `/catalog/products/${w.p(0).id}?include=variants,prices,stockByWarehouse,images`);
  ctx.check('карточка товара: цена и остаток', !!card.json?.price && !!card.json?.stock, { sku: card.json?.sku });
  let cart = await fillCart(S, [{ p: w.p(0), q: '2' }, { p: w.p(1), q: '1' }, { p: w.p(2), q: '3' }], { label: 'корзина продавца' });
  const disc = await S.call('скидка 5 %', 'POST', '/cart/discount', { idem: true, body: { percent: '5.00', rowVersion: cart.rowVersion } });
  cart = disc.json ?? cart;
  ctx.check('скидка до 5 % у продавца применяется', disc.status === 200 && disc.json?.appliedDiscountPercent === '5.00', { status: disc.status, applied: disc.json?.appliedDiscountPercent, total: disc.json?.total });
  await ctx.panel('POST qr/config', { paidAfterPolls: 2 });
  const pv = await S.call('checkout-preview qr_bakai', 'POST', '/cart/checkout-preview', { idem: true, body: { cartId: cart.id, cartRowVersion: cart.rowVersion, paymentMethod: 'qr_bakai', delivery: { method: 'pickup' }, receiver: { kind: 'customer' } } });
  const items = [{ p: w.p(0), q: '2' }, { p: w.p(1), q: '1' }, { p: w.p(2), q: '3' }];
  const o = await S.call('POST /orders qr_bakai', 'POST', '/orders', { idem: true, expect: [201, 202], body: orderBody(cart, items, 'qr_bakai', { previewToken: pv.json?.previewToken }) }); // check-secrets: allow — имя поля ответа API в прогоне, не секрет; gitleaks:allow
  const pay = o.json?.payments?.[0];
  ctx.check('заказ QR: платёж qr_shown, QR от «1С», payload неплатёжный', [201, 202].includes(o.status) && pay?.status === 'qr_shown' && /^DEMO-NOT-PAYABLE\|/.test(pay?.qr?.payload ?? ''), { status: o.status, payment: pay?.status, provider: pay?.qr?.provider, payload: String(pay?.qr?.payload ?? '').slice(0, 40) });
  const t = Date.now();
  let st = null;
  for (let i = 0; i < 6 && st !== 'received'; i++) st = (await S.call('long-poll GET /payments/{id}?wait=25', 'GET', `/payments/${pay?.id}?wait=25`)).json?.status;
  ctx.check('QR оплачивается «1С» сам (автооплата имитатора) → received', st === 'received', { status: st, ms: Date.now() - t });
  const od = await S.poll('заказ оплачен и в «1С»', 'GET', `/orders/${o.json?.id}`, (r) => r.json?.isPaid === true && !!r.json?.onec?.number, { timeoutMs: 30000 });
  ctx.check('заказ QR оплачен, номер «1С» ОС00-…', od.json?.isPaid === true && /^ОС00-\d+$/.test(od.json?.onec?.number ?? ''), { isPaid: od.json?.isPaid, onec: od.json?.onec?.number, status: od.json?.status });
  const pdf = await S.call('товарный чек PDF', 'GET', `/orders/${o.json?.id}/documents/receipt.pdf?format=thermal80`);
  ctx.check('товарный чек — PDF', pdf.status === 200 && pdf.magic === '%PDF-' && /application\/pdf/.test(pdf.headers['content-type'] ?? ''), { status: pdf.status, size: pdf.size, ct: pdf.headers['content-type'] });
  w.orders.qrSeller = od.json;
  await ctx.panel('POST qr/config', { paidAfterPolls: 0 });
}

/** README 2. Кассир: клиент с просрочкой — продажа в долг заблокирована; тот же заказ за наличные и оплата. */
export async function readme2(w) {
  const { ctx, C } = w;
  ctx.begin('README 2. кассир: продажа в долг заблокирована');
  const card = await C.call('карточка клиента с долгом', 'GET', `/customers/${w.overdue.id}?include=receivable`);
  const rec = await C.call('долг клиента (снимок «1С»)', 'GET', `/customers/${w.overdue.id}/receivables`);
  ctx.check('карточка: просрочка видна (снимок долга «1С» свежий)', card.status === 200 && rec.status === 200 && Number(rec.json?.overdueAmount?.amount ?? 0) > 0 && rec.json?.isStale === false, { overdue: rec.json?.overdueAmount, stale: rec.json?.isStale });
  const blocked = await placeOrder(C, w.p(3), 'credit', { customerId: w.overdue.id, expect: 422, label: 'в долг (просрочка)' });
  ctx.check('в долг клиенту с просрочкой → 422 CREDIT_BLOCKED (creditReason overdue)', blocked.order.status === 422 && blocked.order.json?.code === 'CREDIT_BLOCKED' && blocked.order.json?.creditReason === 'overdue', { status: blocked.order.status, code: blocked.order.json?.code, creditReason: blocked.order.json?.creditReason });
  const pv = blocked.preview.json;
  ctx.check('checkout-preview заранее показывает причину (creditAllowed=false)', pv?.paymentChecks?.creditAllowed === false && !!pv?.paymentChecks?.creditReason, pv?.paymentChecks);
  // тот же заказ — наличными (корзина с клиентом осталась)
  const cart = (await C.call('корзина после отказа', 'GET', '/cart')).json;
  const pv2 = await C.call('checkout-preview cash', 'POST', '/cart/checkout-preview', { idem: true, body: { cartId: cart.id, cartRowVersion: cart.rowVersion, paymentMethod: 'cash', delivery: { method: 'pickup' }, receiver: { kind: 'customer' } } });
  const o = await C.call('POST /orders cash', 'POST', '/orders', { idem: true, expect: [201, 202], body: orderBody(cart, w.p(3), 'cash', { customerId: w.overdue.id, previewToken: pv2.json?.previewToken }) }); // check-secrets: allow — имя поля ответа API в прогоне, не секрет; gitleaks:allow
  const pay = await C.call('оплата наличными', 'POST', `/orders/${o.json?.id}/payments`, { idem: true, expect: [200, 201], body: { method: 'cash', receivedAmount: cashAmount(o.json) } });
  ctx.check('тот же заказ наличными → оплачен (received)', [201, 202].includes(o.status) && pay.json?.status === 'received' && pay.json?.order?.isPaid === true, { order: o.status, payment: pay.json?.status, isPaid: pay.json?.order?.isPaid });
  w.orders.cashOverdue = o.json;
}

/** README 3. Старший продавец: разрешение продажи в долг (причина + PIN); в лимите — сразу. */
export async function readme3(w) {
  const { ctx, SS } = w;
  ctx.begin('README 3. старший продавец: разрешение продажи в долг');
  let cart = await fillCart(SS, w.p(4), { label: 'корзина старшего' });
  cart = (await SS.call('клиент с просрочкой в корзину', 'POST', '/cart/customer', { idem: true, body: { customerId: w.overdue.id, rowVersion: cart.rowVersion } })).json;
  const override = { reason: 'Согласовано с руководителем (тест)' };
  const pv = await SS.call('checkout-preview credit + override', 'POST', '/cart/checkout-preview', { idem: true, body: { cartId: cart.id, cartRowVersion: cart.rowVersion, paymentMethod: 'credit', delivery: { method: 'pickup' }, receiver: { kind: 'customer' }, creditOverride: override } });
  const body = orderBody(cart, w.p(4), 'credit', { customerId: w.overdue.id, creditOverride: override, ...(pv.json?.previewToken ? { previewToken: pv.json.previewToken } : {}) });
  const key = crypto.randomUUID();
  const r = await SS.withStepUp('POST /orders credit (разрешение)', 'POST', '/orders', { body, idem: key, expect: [201, 202] });
  ctx.check('без step-up → 403 STEP_UP_REQUIRED (credit.sale.approve); после PIN — заказ в долг', r.first.status === 403 && r.operation === 'credit.sale.approve' && [201, 202].includes(r.final.status), { first: r.first.status, operation: r.operation, final: r.final.status, code: r.final.json?.code });
  const replay = await SS.call('повтор тем же Idempotency-Key', 'POST', '/orders', { body, idem: key, stepUp: r.token, expect: [201, 202] });
  ctx.check('повтор с тем же ключом → тот же заказ, Idempotent-Replayed: true', replay.json?.id === r.final.json?.id && replay.headers['idempotent-replayed'] === 'true', { same: replay.json?.id === r.final.json?.id, replayed: replay.headers['idempotent-replayed'] });
  w.orders.creditOverride = r.final.json;
  const ok = await placeOrder(SS, w.p(5), 'credit', { customerId: w.within.id, label: 'в долг (в лимите)' });
  ctx.check('клиент «Долг в лимите» → в долг сразу, без разрешения', [201, 202].includes(ok.order.status), { status: ok.order.status, code: ok.order.json?.code });
  w.orders.creditWithin = ok.order.json;
}

/** README 4. Покупатель 905: регистрация, каталог, заявка, «Мои заказы»; +996 700 000 101 — привязка «Это я» и свой долг. */
export async function readme4(w) {
  const { ctx } = w;
  ctx.begin('README 4. покупатель: заявка из приложения');
  const K = (w.K = ctx.dev('android', { name: 'покупатель 905' }));
  const v = await K.login('+996777000905');
  ctx.check('новый номер → registration_required', v.json?.status === 'registration_required' && !!v.json?.registrationToken, { status: v.json?.status });
  const reg = await K.registerCustomer({ fullName: 'Покупатель Демо', birthYear: 1991 });
  ctx.check('регистрация → покупатель active', reg.json?.user?.kind === 'customer' && reg.json?.user?.status === 'active', { kind: reg.json?.user?.kind, status: reg.json?.user?.status });
  const cat = await K.call('каталог с ценами (покупатель)', 'GET', '/catalog/products?limit=20&inStock=true&sort=sku:asc');
  const leaks = (cat.json?.items ?? []).filter((p) => p.stock && ('quantity' in p.stock || 'reserved' in p.stock)).length;
  ctx.check('покупатель видит цены, остатки — только статусом (без количеств)', cat.status === 200 && (cat.json?.items ?? []).some((p) => p.price) && leaks === 0, { items: cat.json?.items?.length, leaks });
  const o = await placeOrder(K, w.p(6), 'cash', { label: 'заявка покупателя' });
  ctx.check('заявка покупателя создана (createdVia customer)', [201, 202].includes(o.order.status) && o.order.json?.createdVia === 'customer', { status: o.order.status, createdVia: o.order.json?.createdVia });
  const mine = await K.call('«Мои заказы»', 'GET', '/orders?limit=20');
  ctx.check('«Мои заказы»: заявка в списке', (mine.json?.items ?? []).some((x) => x.id === o.order.json?.id), { n: mine.json?.items?.length });
  w.orders.customer = o.order.json;
  // покупатель с карточкой «1С»
  const L = (w.L = ctx.dev('android', { name: 'покупатель 101' }));
  await L.login('+996700000101');
  await L.registerCustomer({ fullName: 'Покупатель Долг', birthYear: 1985 });
  const m = await L.call('предложение привязки к карточке «1С»', 'GET', '/registration/customer-match');
  const cf = await L.call('«Это я» (подтвердить)', 'POST', '/registration/customer-match/confirm', { body: { linkId: m.json?.linkId } });
  ctx.check('+996 700 000 101: карточка «1С» предложена → подтверждена', m.json?.status === 'proposed' && cf.status === 200 && cf.json?.status === 'confirmed', { match: m.json?.status, confirm: cf.status, status: cf.json?.status });
  const rf = await L.call('обновить токен после привязки', 'POST', '/auth/refresh', { noAuth: true, body: { refreshToken: L.refresh } });
  if (rf.json?.accessToken) {
    L.token = rf.json.accessToken; // check-secrets: allow — токен из ответа API в прогоне, не секрет; gitleaks:allow
    L.refresh = rf.json.refreshToken;
  }
  const own = await L.call('своя карточка', 'GET', `/customers/${w.within.id}`);
  const ownRec = await L.call('свой долг', 'GET', `/customers/${w.within.id}/receivables`);
  const foreign = await L.call('чужая карточка → 404', 'GET', `/customers/${w.overdue.id}`, { expect: 404 });
  ctx.check('после привязки покупатель видит свой долг; чужая карточка — 404', own.status === 200 && ownRec.status === 200 && foreign.status === 404, { own: own.status, receivables: ownRec.status, foreign: foreign.status });
}

/** README 5. Администратор: пользователи, приглашение 904, вход приглашённого, аудит «Разрешена продажа в долг». */
export async function readme5(w) {
  const { ctx, A } = w;
  ctx.begin('README 5. администратор: пользователи и аудит');
  const users = await A.call('список сотрудников', 'GET', '/admin/users?limit=50&kind=staff');
  ctx.check('список сотрудников с ролями', (users.json?.items ?? []).some((u) => u.roles?.includes('cashier')), { n: users.json?.items?.length });
  const inv = await A.withStepUp('пригласить 904', 'POST', '/admin/invitations', { body: { phone: '+996777000904', roles: ['cashier'], fullName: 'Тестов Приглашённый' }, expect: 201 });
  ctx.check('приглашение 904: без step-up → 403, со step-up → 201', inv.first.status === 403 && inv.final.status === 201, { first: inv.first.status, final: inv.final.status, code: inv.final.json?.code });
  const P = (w.P = ctx.dev('windows', { name: 'приглашённый 904' }));
  const v = await P.login('+996777000904');
  ctx.check('вход 904 → сотрудник «Кассир» по приглашению', (v.json?.user?.roles ?? []).includes('cashier') && v.json?.roleSource === 'invitation', { roles: v.json?.user?.roles, roleSource: v.json?.roleSource });
  await ctx.settle();
  const audit = await A.call('аудит: разрешённая продажа в долг', 'GET', `/admin/audit-logs?${period()}&action=credit.sale_approved&limit=20`);
  ctx.check('аудит: запись credit.sale_approved, цепочка цела (chainOk)', (audit.json?.items ?? []).some((x) => x.action === 'credit.sale_approved' && x.chainOk === true), { n: audit.json?.items?.length });
  const all = await A.call('аудит за период', 'GET', `/admin/audit-logs?${period()}&limit=200`);
  ctx.check('аудит: у всех строк chainOk=true', (all.json?.items ?? []).length > 0 && all.json.items.every((x) => x.chainOk === true), { n: all.json?.items?.length });
}

/** README 6. Руководитель: отчёты (продажи за сегодня, средний чек, долги клиентов). */
export async function readme6(w) {
  const { ctx, O } = w;
  ctx.begin('README 6. руководитель: отчёты');
  await ctx.settle();
  const ss = await O.call('продажи за период', 'GET', `/admin/reports/sales-summary?${period()}&groupBy=paymentMethod`);
  ctx.check('отчёт о продажах учитывает заказы сценариев', ss.status === 200 && Number(ss.json?.totals?.ordersCount ?? 0) >= 4, { totals: ss.json?.totals });
  const byDay = await O.call('продажи по дням', 'GET', `/admin/reports/sales-summary?${period()}&groupBy=day`);
  const rcv = await O.call('долги клиентов', 'GET', '/admin/reports/receivables');
  ctx.check('отчёт о долгах: сумма положительна', rcv.status === 200 && Number(rcv.json?.totalBalance?.amount ?? 0) > 0 && byDay.status === 200, { total: rcv.json?.totalBalance });
  const qr = await O.call('сверка QR', 'GET', `/admin/reports/qr-reconciliation?${period()}`);
  ctx.check('сверка QR — 200', qr.status === 200, { status: qr.status });
}

export const README = [readme1, readme2, readme3, readme4, readme5, readme6];
export { PIN, sleep };
