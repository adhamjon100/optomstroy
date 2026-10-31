// Негативные ветки WP-T1 (plan §4 WP-T1): OTP_INVALID с attemptsLeft, VERSION_CONFLICT корзины, possible_duplicate,
// DISCOUNT_LIMIT_EXCEEDED, STEP_UP_REQUIRED → step-up → повтор тем же Idempotency-Key, RETURN_QTY_EXCEEDED; плюс
// 426 APP_UPDATE_REQUIRED, 401 без токена и с поддельным JWT, 403 по правам, 404, CREDIT_LIMIT_EXCEEDED.
import { OTP, cashAmount, fillCart, orderBody, placeOrder, qty } from './dsl.mjs';

export async function negatives(w) {
  const { ctx, C, SS, S, A } = w;
  ctx.begin('Негативные ветки');

  // OTP_INVALID с attemptsLeft → верный код проходит
  const N = (w.N = ctx.dev('android', { name: 'покупатель 903' }));
  const rq = await N.call('otp/request 903', 'POST', '/auth/otp/request', { body: { phone: '+996777000903', purpose: 'login_or_register', locale: 'ru' }, expect: 202 });
  const bad = await N.call('otp/verify неверный код', 'POST', '/auth/otp/verify', { body: { challengeId: rq.json?.challengeId, code: '000000', device: { name: 'N', platform: 'android', appVersion: N.version } }, expect: 422 });
  ctx.check('неверный код → 422 OTP_INVALID с attemptsLeft', bad.json?.code === 'OTP_INVALID' && Number.isInteger(bad.json?.attemptsLeft), { code: bad.json?.code, attemptsLeft: bad.json?.attemptsLeft });
  const ch = await N.call('статус OTP-запроса', 'GET', `/auth/otp/challenges/${rq.json?.challengeId}`);
  ctx.check('GET /auth/otp/challenges/{id} → статус и попытки', ch.status === 200, ch.json && { status: ch.json.status, attemptsLeft: ch.json.attemptsLeft });
  const good = await N.call('otp/verify верный код', 'POST', '/auth/otp/verify', { body: { challengeId: rq.json?.challengeId, code: OTP, device: { name: 'N', platform: 'android', appVersion: N.version } } });
  N.verify = good.json;
  ctx.check('после ошибки верный код 246810 проходит', good.status === 200 && good.json?.status === 'registration_required', { status: good.status, s: good.json?.status });
  await N.registerCustomer({ fullName: 'Покупатель Выход', label: 'регистрация 903' });

  // 426 и 401
  const old = await ctx.dev('windows', { name: 'старая версия', version: '0.0.9+1' }).call('otp/request с версией 0.0.9+1', 'POST', '/auth/otp/request', { body: { phone: '+996777000906', purpose: 'login_or_register', locale: 'ru' }, expect: 426 });
  ctx.check('X-App-Version 0.0.9+1 → 426 APP_UPDATE_REQUIRED + X-Min-App-Version', old.status === 426 && old.json?.code === 'APP_UPDATE_REQUIRED' && !!old.headers['x-min-app-version'], { status: old.status, code: old.json?.code, min: old.headers['x-min-app-version'] });
  const noTok = await ctx.dev('windows', { name: 'без токена' }).call('GET /me без токена', 'GET', '/me', { expect: 401 });
  const fake = ctx.dev('windows', { name: 'поддельный JWT' });
  fake.token = `${Buffer.from('{"alg":"none","typ":"JWT"}').toString('base64url')}.${Buffer.from('{"sub":"x"}').toString('base64url')}.`;
  const alg = await fake.call('GET /me с alg=none', 'GET', '/me', { expect: 401 });
  ctx.check('без токена и с JWT alg=none → 401 UNAUTHENTICATED', noTok.json?.code === 'UNAUTHENTICATED' && alg.json?.code === 'UNAUTHENTICATED', { noToken: noTok.json?.code, algNone: alg.json?.code }); // check-secrets: allow — имя поля ответа API в прогоне, не секрет; gitleaks:allow

  // 403 по правам и 404
  const dash = await S.call('дашборд кассира продавцу → 403', 'GET', '/pos/dashboard', { expect: 403 });
  const recv = await S.call('долг клиента продавцу → 403', 'GET', `/customers/${w.overdue.id}/receivables`, { expect: 403 });
  const sscope = await S.call('поиск клиента продавцом по 4 цифрам → 400', 'GET', '/search/customers?q=0102', { expect: 400 });
  ctx.check('права: продавцу дашборд и долг — 403 FORBIDDEN; поиск по 4 цифрам — 400 (только полный номер)', dash.json?.code === 'FORBIDDEN' && recv.status === 403 && sscope.status === 400, { dash: dash.json?.code, recv: recv.status, scope: sscope.json?.code, rule: sscope.json?.errors?.[0]?.rule });
  const nf = await C.call('несуществующий заказ → 404', 'GET', '/orders/01a00000-0000-7000-8000-000000000000', { expect: 404 });
  ctx.check('несуществующий заказ → 404 NOT_FOUND', nf.json?.code === 'NOT_FOUND', { code: nf.json?.code });

  // VERSION_CONFLICT корзины
  let cart = await fillCart(C, w.p(7), { label: 'корзина (конфликт версии)' });
  const stale = cart.rowVersion;
  await C.call('PUT второй товар (текущая версия)', 'PUT', `/cart/items/${w.p(8).defaultVariantId}`, { idem: true, body: { quantity: qty(w.p(8)), rowVersion: stale, mode: 'set' } });
  const vc = await C.call('PUT со старой rowVersion → 409', 'PUT', `/cart/items/${w.p(9).defaultVariantId}`, { idem: true, body: { quantity: qty(w.p(9)), rowVersion: stale, mode: 'set' }, expect: 409 });
  ctx.check('старая rowVersion корзины → 409 VERSION_CONFLICT с текущей корзиной', vc.json?.code === 'VERSION_CONFLICT' && !!vc.json?.current, { code: vc.json?.code, current: vc.json?.current?.rowVersion });

  // possible_duplicate: тот же состав у автора за 60 с → 409, confirmDuplicate → создаётся
  const first = await placeOrder(C, w.p(10), 'cash', { label: 'заказ (дубль 1)' });
  cart = await fillCart(C, w.p(10), { label: 'корзина (дубль 2)' });
  const pv = await C.call('checkout-preview (дубль 2)', 'POST', '/cart/checkout-preview', { idem: true, body: { cartId: cart.id, cartRowVersion: cart.rowVersion, paymentMethod: 'cash', delivery: { method: 'pickup' }, receiver: { kind: 'customer' } } });
  const body = orderBody(cart, w.p(10), 'cash', pv.json?.previewToken ? { previewToken: pv.json.previewToken } : {});
  const dup = await C.call('POST /orders тот же состав → 409', 'POST', '/orders', { idem: true, body, expect: 409 });
  ctx.check('тот же состав за 60 с → 409 ORDER_STATE_INVALID reason=possible_duplicate', dup.json?.code === 'ORDER_STATE_INVALID' && dup.json?.reason === 'possible_duplicate' && dup.json?.possibleDuplicateOrderId === first.order.json?.id, { code: dup.json?.code, reason: dup.json?.reason, sameOrder: dup.json?.possibleDuplicateOrderId === first.order.json?.id });
  const conf = await C.call('POST /orders confirmDuplicate=true', 'POST', '/orders', { idem: true, body: { ...body, confirmDuplicate: true }, expect: [201, 202] });
  ctx.check('confirmDuplicate=true → заказ создан', [201, 202].includes(conf.status), { status: conf.status });
  w.orders.dupA = first.order.json;
  w.orders.dupB = conf.json;

  // DISCOUNT_LIMIT_EXCEEDED: продавец (лимит 5 %) просит 20 %
  cart = await fillCart(S, w.p(11), { label: 'корзина продавца (скидка сверх лимита)' });
  const dl = await S.call('скидка 20 % продавцу → 422', 'POST', '/cart/discount', { idem: true, body: { percent: '20.00', rowVersion: cart.rowVersion }, expect: 422 });
  ctx.check('скидка сверх лимита роли → 422 DISCOUNT_LIMIT_EXCEEDED, requiresRole senior_seller', dl.json?.code === 'DISCOUNT_LIMIT_EXCEEDED' && dl.json?.requiresRole === 'senior_seller', { code: dl.json?.code, requiresRole: dl.json?.requiresRole });
  // старший продавец: скидка сверх своего лимита с разрешением (step-up discount.approve.over_limit)
  let sc = await fillCart(SS, w.p(12), { label: 'корзина старшего (скидка 12 %)' });
  const over = await SS.withStepUp('скидка 12 % сверх лимита (override)', 'POST', '/cart/discount', { body: { percent: '12.00', rowVersion: sc.rowVersion, override: { reason: 'Оптовый клиент (тест)' } }, expect: [200, 422] });
  ctx.check('скидка сверх лимита старшего: ветка override / DISCOUNT_LIMIT_EXCEEDED обработана', [200, 422].includes(over.final.status), { first: over.first.status, firstCode: over.first.json?.code, final: over.final.status, applied: over.final.json?.appliedDiscountPercent, code: over.final.json?.code });

  // CREDIT_LIMIT_EXCEEDED: «Лимит превышен» + дорогой товар
  const k = (await C.call('поиск K5383', 'GET', '/search/products?q=K5383&limit=5')).json?.items?.find((x) => x.sku === 'K5383');
  if (k) {
    const lim = await placeOrder(C, { ...k, baseUnit: k.baseUnit, defaultVariantId: k.defaultVariantId }, 'credit', { customerId: w.limitEx.id, expect: 422, label: 'в долг сверх лимита' });
    ctx.check('«ОсОО Лимит превышен (тест)» в долг → 422 CREDIT_LIMIT_EXCEEDED', lim.order.json?.code === 'CREDIT_LIMIT_EXCEEDED', { code: lim.order.json?.code, creditReason: lim.order.json?.creditReason });
  } else ctx.check('товар K5383 найден для CREDIT_LIMIT_EXCEEDED', false, 'нет K5383');

  // RETURN_QTY_EXCEEDED: отгруженный заказ, возврат больше отгруженного
  const ro = await placeOrder(C, w.p(13), 'cash', { label: 'заказ под возврат (лимит)' });
  await C.call('оплата (под возврат)', 'POST', `/orders/${ro.order.json?.id}/payments`, { idem: true, expect: [200, 201], body: { method: 'cash', receivedAmount: cashAmount(ro.order.json) } });
  await C.poll('номер «1С» (под возврат)', 'GET', `/orders/${ro.order.json?.id}`, (r) => !!r.json?.onec?.number, { timeoutMs: 30000 });
  await ctx.panel(`POST orders/${ro.order.json?.id}/onec-status`, { status: 'КВыполнению', approved: true });
  await C.poll('согласован (под возврат)', 'GET', `/orders/${ro.order.json?.id}`, (r) => ['approved', 'awaiting_shipment'].includes(r.json?.status), { timeoutMs: 30000 });
  await ctx.panel(`POST orders/${ro.order.json?.id}/ship`, {});
  const shipped = await C.call('заказ отгружен', 'GET', `/orders/${ro.order.json?.id}`);
  const line = shipped.json?.items?.[0];
  const rItem = (v) => [{ orderLineNo: line?.lineNo ?? 1, quantity: { value: v, unitId: line?.quantity?.unitId ?? w.p(13).baseUnit.id, packagingId: null } }];
  const overSold = await C.call('возврат больше проданного → 400', 'POST', '/returns', { idem: true, expect: 400, body: { orderId: ro.order.json?.id, reasonCode: 'defect', items: rItem('5') } });
  ctx.check('возврат больше проданного → 400 VALIDATION_FAILED (rule max)', overSold.json?.code === 'VALIDATION_FAILED' && overSold.json?.errors?.[0]?.rule === 'max', { code: overSold.json?.code, rule: overSold.json?.errors?.[0]?.rule });
  const held = await C.call('возврат 1 шт (черновик держит остаток)', 'POST', '/returns', { idem: true, expect: 201, body: { orderId: ro.order.json?.id, reasonCode: 'defect', items: rItem('1') } });
  const tooMuch = await C.call('второй возврат той же 1 шт → 422', 'POST', '/returns', { idem: true, expect: 422, body: { orderId: ro.order.json?.id, reasonCode: 'defect', items: rItem('1') } });
  ctx.check('возврат сверх «отгружено − возвращено − в других заявках» → 422 RETURN_QTY_EXCEEDED', shipped.json?.status === 'shipped' && held.status === 201 && tooMuch.json?.code === 'RETURN_QTY_EXCEEDED', { order: shipped.json?.status, first: held.status, code: tooMuch.json?.code });
  if (held.json?.id) await C.call('удалить черновик (освободить остаток)', 'DELETE', `/returns/${held.json.id}?rowVersion=${held.json.rowVersion}`, { expect: 204 });
  w.orders.shipped = shipped.json;

  // STEP_UP_REQUIRED → step-up → повтор тем же ключом (отдельная операция: ручной запуск синхронизации)
  const sync = await A.withStepUp('POST /sync/runs customers', 'POST', '/sync/runs', { body: { entity: 'customers', mode: 'incremental' }, expect: 202 });
  ctx.check('STEP_UP_REQUIRED (sync.run.full) → PIN → повтор с тем же Idempotency-Key → 202', sync.first.status === 403 && sync.operation === 'sync.run.full' && sync.final.status === 202, { first: sync.first.status, operation: sync.operation, final: sync.final.status });
  w.syncRunId = sync.final.json?.id;
}
