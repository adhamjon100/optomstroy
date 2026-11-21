// O — заказы (Требования §6.6–§6.9; обязательные методы: «метода нет» — ОШИБКА).
import { expectStatus, expectPosError, netFailed, statusText, looksAbsent, burst, rnd, absentRequired, sameObjectDiffs, documentDateFindings } from './common.mjs';
import { parseIso } from '../report/time.mjs';

const CREATE = 'POST /pos/v1/orders';
const STATUS = 'GET /pos/v1/orders/{uuid}/status';
const BATCH = 'POST /pos/v1/orders/status';
const CANCEL = 'POST /pos/v1/orders/{uuid}/cancel';

/** Статус заказа для сравнения: «Регистр букв, пробелы и подчёркивания POS не учитывает» (Требования §6.6). */
export function normStatus(s) {
  return typeof s === 'string' ? s.toLowerCase().replace(/ё/g, 'е').replace(/[\s_]+/g, '') : null;
}
// Требования §6.6, таблица «Статусы заказа»: значения, при которых заказ действует (принят, согласован, к выполнению,
// к обеспечению, к отгрузке). После отмены (§6.7) такого статуса без deletionMark=true быть не может.
const ACTIVE_STATUSES = new Set(['несогласован', 'насогласовании', 'согласован', 'квыполнению', 'кобеспечению', 'котгрузке']);
// Статусы, которых не может быть у только что созданного заказа: при создании — «Не согласован» или эквивалент (§6.6).
const NOT_AT_CREATE = new Set(['согласован', 'квыполнению', 'закрыт']);
const show = (v) => (v === undefined ? 'нет поля' : v === null ? 'null' : typeof v === 'string' ? `«${v}»` : String(v));

/**
 * O1, O2: ответ 201/200 создания заказа — тот externalId, документ проведён, не согласован (Требования §6.6 «Ответ»,
 * «Правила на стороне 1С»; КП-8). what — «заказ» или «повтор».
 */
export function createdOrderFindings(r, j, body, what) {
  if (j.externalId !== body.externalId) {
    r.fail(`${what}: externalId ответа ${show(j.externalId)}, а в запросе ${body.externalId} — в ответе externalId из запроса (Требования §6.6 «Ответ»); иначе POS свяжет документ с чужим заказом`, { code: 'external-id' });
  }
  // 200 на повтор после пометки удаления — допустимо: deletionMark=true, документ не проведён, «Закрыт» (§6.6 «Ответ»,
  // образец orders-create.200.deleted.json). У нового заказа (201) deletionMark=false проверяется отдельно.
  if (j.deletionMark === true && what === 'повтор') return;
  if (j.posted !== true) {
    r.fail(`${what}: posted = ${show(j.posted)} — ответ 201 (и 200 на повтор) означает «документ создан и проведён», проведение — в той же транзакции (Требования §6.6 «Ответ» и «Проведение»; КП-8)`, { code: 'posted' });
  }
  const st = normStatus(j.status);
  if (j.approved === true || NOT_AT_CREATE.has(st)) {
    // Повтор отдаёт уже существующий документ в его текущем состоянии (Требования §4.7 п. 1: «вернуть 200 с уже
    // существующим объектом: номер, дата, статус, пометка удаления»): заказ мог согласовать менеджер или правило 1С
    // сразу после создания (сценарий G15). «Не согласован» обязателен только при создании (§6.6), то есть в ответе 201.
    if (what === 'повтор') {
      r.info(`повтор: заказ уже в состоянии status ${show(j.status)}, approved = ${show(j.approved)} — повтор отдаёт текущее состояние документа, это верно (Требования §4.7 п. 1); «Не согласован» обязателен только в ответе 201 на создание (§6.6)`, { code: 'state-now' });
      return;
    }
    r.fail(`${what}: заказ уже согласован или закрыт (status ${show(j.status)}, approved = ${show(j.approved)}) — при создании статус «Не согласован» или эквивалент вашей конфигурации, согласует менеджер в 1С (Требования §6.6 «Статус и обеспечение»; КП-8 «заказ «Не согласован»»)`, { code: 'approved' });
  }
}

const moneyOf = (v) => (typeof v === 'string' && /^-?\d+(\.\d+)?$/.test(v.trim()) ? Number(v) : null);
const sameMoney = (a, b) => a !== null && b !== null && Math.abs(a - b) < 0.005;

const sameInstant = (a, b) => {
  if (a === b) return true;
  const x = parseIso(a), y = parseIso(b);
  return !!x && !!y && x.getTime() === y.getTime();
};

/**
 * O4–O7: ответ статуса, пакета или отмены — тот же заказ, что создан в O1: externalId из запроса, ref, number и date ответа
 * создания (Требования §6.8 «Состав полей совпадает с элементом Document_ЗаказКлиента», externalId — «externalId заказа
 * POS», number — «номер документа»; §6.7 «Тело — текущее состояние заказа в формате ответа метода GET …/status»; §6.20:
 * по номеру и дате администратор привязывает заказ вручную). what — где ответ (идёт и в where: находки не сливаются).
 */
export function sameOrderFindings(r, j, o1, what) {
  if (!j || typeof j !== 'object') return;
  const where = what;
  if (j.externalId !== o1.body.externalId) {
    const asRef = j.externalId && j.externalId === o1.ref ? ' — это ссылка документа (ref), а не externalId' : '';
    r.fail(`${what}: externalId ${show(j.externalId)}, а запрошен ${o1.body.externalId}${asRef}: в ответе externalId заказа POS из запроса (Требования §6.8 externalId — «externalId заказа POS»); по нему POS находит свой заказ`, { code: 'external-id', where });
  }
  if (o1.ref && j.ref !== o1.ref) r.fail(`${what}: ref ${show(j.ref)}, а при создании (O1) ${show(o1.ref)} — ссылка того же документа «Заказ клиента» (Требования §6.8)`, { code: 'ref', where });
  if (typeof o1.number === 'string' && o1.number && j.number !== o1.number) {
    r.fail(`${what}: number ${show(j.number)}, а при создании (O1) ${show(o1.number)} — номер документа один во всех ответах, полный, как в ответе POST /orders (не НомерНаПечать, без отбрасывания префикса и нулей): Требования §6.8 «Состав полей совпадает с элементом Document_ЗаказКлиента», number — «номер документа»; по номеру продавец видит заказ в 1С и администратор привязывает его вручную (§6.20)`, { code: 'number', where });
  }
  if (typeof o1.date === 'string' && o1.date && !sameInstant(j.date, o1.date)) {
    r.fail(`${what}: date ${show(j.date)}, а при создании (O1) ${show(o1.date)} — дата того же документа (Требования §6.8 date — «дата документа»; §6.20: заказ ищется по номеру и дате)`, { code: 'date', where });
  }
}

/**
 * O2: итог повтора — тот же документ (Требования §4.7 п. 1: «нашли — вернуть 200 с уже существующим объектом … Ничего не
 * создавать и не изменять»; §6.6 totals — «фактические суммы документа 1С»). Итог повтора другой, чем при создании, —
 * спрашиваем текущий итог документа (GET …/status, total): документ прежний — повтор пересчитал суммы (ОШИБКА, сценарий
 * T36); документ тоже изменился — его могли изменить в 1С между запросами (ЗАМЕЧАНИЕ).
 */
async function repeatTotalsFindings(r, j, o1) {
  const t1 = moneyOf(o1.totals?.total), t2 = moneyOf(j?.totals?.total);
  if (t1 === null || t2 === null || sameMoney(t1, t2)) return;
  const st = await r.call({ op: STATUS, path: `/pos/v1/orders/${o1.body.externalId}/status`, label: 'итог документа после повтора' });
  const cur = !st.error && st.status === 200 ? moneyOf(st.json?.total) : null;
  const rc = j.recalculated !== o1.recalculated ? `, recalculated = ${show(j.recalculated)} (при создании ${show(o1.recalculated)})` : '';
  if (cur === null) {
    r.warn(`повтор вернул итог ${j.totals.total}${rc}, а при создании (O1) — ${o1.totals.total}; текущий итог документа узнать не удалось (GET /orders/{uuid}/status: ${statusText(st)}) — повтор отдаёт уже существующий документ как есть, «ничего не создавать и не изменять» (Требования §4.7 п. 1): проверьте суммы заказа в 1С`, { code: 'totals-unknown' });
    return;
  }
  if (sameMoney(cur, t2)) {
    r.warn(`повтор вернул итог ${j.totals.total}${rc}, а при создании (O1) — ${o1.totals.total}; документ 1С сейчас тоже ${st.json.total} (GET /orders/{uuid}/status): если заказ меняли в 1С между запросами — это верно; если нет — 1С пересчитывает и перезаписывает документ на повтор, а на повтор «ничего не создавать и не изменять» (Требования §4.7 п. 1)`, { code: 'totals-doc-changed' });
    return;
  }
  const doc = sameMoney(cur, t1)
    ? `документ 1С — ${o1.totals.total}: так ответило создание (O1) и так показывает GET /orders/{uuid}/status (total ${st.json.total})`
    : `при создании (O1) — ${o1.totals.total}, а GET /orders/{uuid}/status показывает total ${st.json.total}`;
  r.fail(`повтор вернул итог ${j.totals.total}${rc}, а ${doc} — повтор отдаёт уже существующий документ как есть: «нашли — вернуть 200 с уже существующим объектом … Ничего не создавать и не изменять» (Требования §4.7 п. 1); totals — «фактические суммы документа 1С» (§6.6 «Ответ»), а не пересчёт по текущим ценам. POS по ответу на повтор сохранит чужой итог и покажет продавцу «итог уточнён 1С»`, { code: 'totals-changed' });
}

/**
 * O5, O6: «Каждый запрошенный externalId должен попасть либо в items, либо в notFound» (Требования §6.9). Наш заказ есть в
 * 1С (O1) — в notFound его быть не может: по notFound POS отмечает «документ в 1С не найден» и сообщает администратору
 * (§6.9 «Ненайденные заказы…»), и так при каждой синхронизации раз в 5 минут.
 */
function batchListFindings(r, { items, nf, requested, ours, what }) {
  const inItems = new Set(items.map((i) => i?.externalId));
  for (const id of requested) {
    if (!nf.includes(id)) continue;
    if (inItems.has(id)) {
      r.fail(`${what}: ${id === ours ? 'наш заказ' : 'externalId'} ${id} и в items, и в notFound — каждый запрошенный externalId либо в items, либо в notFound (Требования §6.9)${id === ours ? '; по notFound POS отметит заказ «документ в 1С не найден» и сообщит администратору — при каждой синхронизации статусов раз в 5 минут' : ''}`, { code: 'both', where: what });
    } else if (id === ours) {
      r.fail(`${what}: наш заказ ${id} в notFound, а документ в 1С есть (создан в O1) — найденные заказы — в items (Требования §6.9); по notFound POS отметит заказ «документ в 1С не найден»`, { code: 'ours-not-found', where: what });
    }
  }
}

/** Отменён ли заказ по ответу (Требования §6.7: status отмены, типово «Закрыт», или deletionMark=true). */
function cancelFindings(r, j) {
  const st = normStatus(j.status);
  if (j.deletionMark === true || st === 'закрыт') return true;
  const state = `status ${show(j.status)}, deletionMark = ${show(j.deletionMark)}`;
  if (!st || ACTIVE_STATUSES.has(st)) {
    r.fail(`отмена ответила 200, а заказ не отменён: ${state} — признак отмены — status отмены вашей конфигурации (типово «Закрыт») или deletionMark = true (Требования §6.7 «Ответ»; КП-15 «200, заказ отменён в 1С»)`, { code: 'not-cancelled' });
  } else {
    r.warn(`после отмены ${state}: такой статус POS не знает и отменённым заказ не считает — пришлите статус отмены вашей конфигурации (Требования §6.7, вопрос 51 раздела 10, Q-012)`, { code: 'cancel-status-unknown' });
  }
  return false;
}

/**
 * O6: 409 POS_E_STATE на отмену. Требования §6.7: отказ верен, если «по заказу есть проведённая реализация или документ в
 * состоянии, которое не позволяет отмену»; «Отмена возможна, только если по заказу нет проведённых реализаций»; КП-15 —
 * заказ без реализаций отменяется («200, заказ отменён в 1С по вашим правилам»). Состояние — по статусу сразу после отказа
 * (нет ответа — по статусу из O4): есть проведённая реализация — отказ верен, отмена не проверена (ЗАМЕЧАНИЕ, сценарий
 * G10, КП-16); реализаций нет, но заказ уже не такой, как при создании (согласован, к выполнению…) — Требования отказ
 * допускают, КП-15 ждёт 200: ЗАМЕЧАНИЕ и вопрос разработчику; заказ как при создании — ОШИБКА.
 */
async function cancelRefused(r, o1) {
  const st = await r.call({ op: STATUS, path: `/pos/v1/orders/${o1.body.externalId}/status`, label: 'статус после отказа в отмене' });
  const sj = !st.error && st.status === 200 && st.json && typeof st.json === 'object' ? st.json : (o1.seen || null);
  if (!sj) {
    r.warn(`отмена не проверена: 1С ответила 409 POS_E_STATE, а состояние заказа узнать не удалось (статус: ${statusText(st)}) — отказ верен, только если «по заказу есть проведённая реализация или документ в состоянии, которое не позволяет отмену» (Требования §6.7); проверьте отмену по КП-15 на заказе без реализаций`, { code: 'cancel-refused-unknown' });
    return;
  }
  const shipped = Array.isArray(sj.shipments) && sj.shipments.some((s) => s && s.posted === true);
  const state = `status ${show(sj.status)}, approved = ${show(sj.approved)}, ${shipped ? 'есть проведённая реализация (shipments, posted = true)' : 'проведённых реализаций нет'}`;
  if (shipped) {
    r.warn(`отмена не проверена: 1С ответила 409 POS_E_STATE, а по тестовому заказу уже есть проведённая реализация (${state}) — отказ верен: «Есть — 409 POS_E_STATE, документ не меняйте» (Требования §6.7; КП-16). Заказ отгрузили между созданием и отменой (менеджер или правило 1С?); отмену проверьте по КП-15 на заказе без реализаций`, { code: 'cancel-refused-shipped' });
    return;
  }
  const s = normStatus(sj.status);
  if (sj.approved === true || !(s === 'несогласован' || s === 'насогласовании')) {
    r.warn(`отмена не проверена: 1С ответила 409 POS_E_STATE, проведённых реализаций по заказу нет, а сам заказ уже не такой, как при создании (${state}). Документы здесь расходятся: Требования §6.7 допускают отказ, если «документ в состоянии, которое не позволяет отмену», а §6.7 «Отмена возможна, только если по заказу нет проведённых реализаций» и КП-15 ждут «200, заказ отменён в 1С по вашим правилам». Если в вашей базе заказ в таком состоянии отменить нельзя — сообщите разработчику, какие состояния не отменяются; отмену проверьте по КП-15`, { code: 'cancel-refused-state' });
    return;
  }
  r.fail(`отмена: 1С ответила 409 POS_E_STATE, а заказ — как при создании (${state}): отказ допустим, если «по заказу есть проведённая реализация или документ в состоянии, которое не позволяет отмену» (Требования §6.7); только что созданный несогласованный заказ без реализаций отменяется — «Отмена возможна, только если по заказу нет проведённых реализаций» (§6.7), КП-15 «200, заказ отменён в 1С по вашим правилам». Проверьте условие «есть проведённые реализации» (Документ.РеализацияТоваровУслуг с этим заказом в основании, проведён)`, { code: 'cancel-refused' });
}

/** Контрольный запрос: «ловит» ли расширение неизвестные пути ответом POS_E_NOT_FOUND (§1.5). */
export async function detectCatchAll(ctx, run) {
  if (ctx.data.catchAll !== undefined) return ctx.data.catchAll;
  const ex = await run.call({ op: null, method: 'GET', path: '/pos/v1/__proverka_net_takogo_metoda__', noSchema: true, absentProbe: true, noRetry: true, label: 'контрольный запрос: заведомо несуществующий путь' });
  ctx.data.catchAll = !ex.error && ex.status === 404 && ex.isPosError;
  if (ctx.data.catchAll) run.info('расширение отвечает POS_E_NOT_FOUND и на несуществующий путь — отсутствие метода нельзя отличить от «не найдено»', { code: 'catch-all' });
  return ctx.data.catchAll;
}

/**
 * Обнаружение метода по GET со случайным GUID (ответ — 404 POS_E_NOT_FOUND). required — метод обязателен по Требованиям:
 * «метода нет» — ОШИБКА (absentRequired); иначе — МЕТОДА НЕТ с текстом absentText.
 */
export async function discover(ctx, r, { op, path, id, what, required = null, absentText = null, notFoundRef }) {
  await detectCatchAll(ctx, r);
  const ex = await r.call({ op, path, absentProbe: true, noRetry: true, label: 'обнаружение метода (случайный GUID)' });
  if (netFailed(r, ex, 'обнаружение')) return false;
  if (looksAbsent(ctx, ex)) {
    if (required) absentRequired(ctx, r, id, { what, ...required });
    else { ctx.data.absent.add(id); r.absent(absentText || `МЕТОДА НЕТ — ${what}`); }
    return false;
  }
  if (ex.status === 404 && ex.isPosError) {
    if (ctx.data.catchAll) r.info('нельзя отличить отсутствие метода от «не найдено» (расширение отвечает POS_E_NOT_FOUND на любой путь)', { code: 'ambiguous' });
    ctx.data.present.add(id);
    r.pass('метод есть (404 POS_E_NOT_FOUND на случайный GUID)');
    return true;
  }
  // 200 на неизвестный externalId: POS примет «фантом» за настоящий объект (статус, отмену, оплату) — ОШИБКА; метод при
  // этом есть, зависимые проверки выполняются.
  if (ex.status === 200) r.fail(`на случайный GUID (неизвестный externalId) ответ 200 — нужен 404 POS_E_NOT_FOUND (${notFoundRef}); иначе POS примет пустой ответ за состояние настоящего объекта`, { code: '200' });
  else r.fail(`на случайный GUID нужен 404 POS_E_NOT_FOUND, пришёл ${statusText(ex)}`, { code: 'status' });
  ctx.data.present.add(id);
  return true;
}

export async function runOrdersRead(ctx) {
  await ctx.run('O0', async (r) => {
    await discover(ctx, r, { op: STATUS, path: `/pos/v1/orders/${rnd()}/status`, id: 'O0', what: 'заказы (POST /orders, статусы, отмена)', required: { section: '§6.6–§6.9', stage: '3 «Чтение» (статусы) и 4 «Запись» (заказы, отмена)' }, notFoundRef: 'Требования §6.8 «404 — заказа с таким externalId в 1С нет», §8.4 «/orders/{uuid}/status … неизвестный externalId — 404 POS_E_NOT_FOUND»' });
  });
}

export async function runOrdersWrite(ctx) {
  const ids = ['O1', 'O2', 'O3', 'O4', 'O5', 'O6', 'O7', 'O8', 'O9'];
  if (ctx.data.absent.has('O0') || !ctx.data.present.has('O0')) {
    const why = ctx.data.absent.has('O0') ? 'метода заказов нет (O0 — ОШИБКА)' : 'метод заказов не обнаружен (O0 не выполнялся)';
    for (const id of ids) await ctx.run(id, async (r) => { r.skip(why); });
    return;
  }
  const productRef = ctx.data.refs?.productRef, warehouseRef = ctx.data.refs?.warehouseRef;
  let o1 = null;
  await ctx.run('O1', async (r) => {
    if (!productRef || !warehouseRef) { r.skip('нет товара и склада: укажите refs.productRef и refs.warehouseRef или запустите с перерегистрацией'); return; }
    const { body, publicNumber } = ctx.synth.order({ productRef, warehouseRef, priceListRef: ctx.data.refs?.priceListRef || null });
    const ex = await r.call({ op: CREATE, path: '/pos/v1/orders', body, label: `заказ ${publicNumber}` });
    if (netFailed(r, ex, 'заказ')) { ctx.registry.addCreated({ kind: 'Заказ', externalId: body.externalId, checkId: 'O1', unknown: true, note: 'результат неизвестен (нет ответа)' }); return; }
    if ([409, 422].includes(ex.status) && ex.isPosError) { r.warn(`заказ не создан: ${statusText(ex)} — проверьте товар и склад в refs (остаток, цена)`, { code: 'rejected' }); return; }
    if (ex.status === 400) { r.fail(`заказ розничного покупателя (customer.ref = null) отклонён: ${statusText(ex)} — 1С подставляет розничного контрагента и соглашение по умолчанию, ответ 201, не 400 (Требования §1.2 п. 4, §6.6; КП-8)`, { code: 'retail-400' }); return; }
    if (ex.status === 200) r.fail('200 вместо 201 на первое создание (externalId новый)', { code: '200' });
    else if (ex.status !== 201) { r.fail(`заказ: нужен 201, пришёл ${statusText(ex)}`, { code: 'status' }); return; }
    const j = ex.json || {};
    ctx.registry.addCreated({ kind: 'Заказ', externalId: body.externalId, ref: j.ref ?? null, number: j.number ?? null, date: j.date ?? null, checkId: 'O1' });
    const t = j.totals && typeof j.totals.total === 'string' ? Number(j.totals.total) : null;
    if (t !== null && typeof j.recalculated === 'boolean' && j.recalculated !== (Math.abs(t - 1.0) > 0.01)) {
      r.fail(`recalculated = ${j.recalculated}, а итог 1С ${j.totals.total} при итоге POS 1.00 — признак пересчёта не согласован`, { code: 'recalc' });
    }
    if (j.deletionMark !== false) r.fail(`deletionMark = ${j.deletionMark} у нового заказа`, { code: 'deleted' });
    createdOrderFindings(r, j, body, 'заказ');
    documentDateFindings(ctx, r, { date: j.date, sentAt: body.createdAt, sentField: 'createdAt', ex, what: 'дата заказа (date)' });
    o1 = { body, ref: j.ref, number: j.number, date: j.date, publicNumber, totals: j.totals && typeof j.totals === 'object' ? j.totals : null, recalculated: j.recalculated };
    ctx.data.o1 = o1;
    r.pass(`201, № ${j.number ?? '?'}`);
  });
  const need = (r) => { if (!o1?.ref) { r.skip('нет заказа из O1'); return false; } return true; };
  await ctx.run('O2', async (r) => {
    if (!need(r)) return;
    const ex = await r.call({ op: CREATE, path: '/pos/v1/orders', body: o1.body, label: 'повтор' });
    if (ex.status === 201) { r.fail('повтор создал второй заказ (201) — нужен 200', { code: 'dup' }); return; }
    if (!expectStatus(r, ex, 200, 'повтор')) return;
    if (ex.json?.ref !== o1.ref || ex.json?.number !== o1.number) r.fail('повтор вернул другой ref или номер', { code: 'ref' });
    else {
      for (const d of sameObjectDiffs(o1, ex.json, ['date'])) r.fail(`повтор вернул другую дату заказа — ${d} (Требования §4.7 п. 1: повтор возвращает тот же объект)`, { code: 'date' });
      await repeatTotalsFindings(r, ex.json, o1);
    }
    createdOrderFindings(r, ex.json && typeof ex.json === 'object' ? ex.json : {}, o1.body, 'повтор');
    r.pass('200, тот же заказ');
  });
  await ctx.run('O3', async (r) => {
    if (!productRef || !warehouseRef) { r.skip('нет товара и склада'); return; }
    const { body, publicNumber } = ctx.synth.order({ productRef, warehouseRef, priceListRef: ctx.data.refs?.priceListRef || null });
    // Итог — тоже: десять ответов об одном документе (Требования §4.7 п. 1; §6.6 totals — «фактические суммы документа 1С»).
    const res = await burst(ctx, r, { op: CREATE, path: '/pos/v1/orders', body, kind: 'Заказ', same: ['number', 'date', 'totals.total'] });
    // Заказ O3 не отменяется — пробный QR (Q1) выдаётся для него, а не для отменённого O1 (сценарий U04).
    if (res?.ref) ctx.data.o3 = { body, ref: res.ref, publicNumber };
  });
  await ctx.run('O4', async (r) => {
    if (!need(r)) return;
    const ex = await r.call({ op: STATUS, path: `/pos/v1/orders/${o1.body.externalId}/status`, label: 'статус нашего заказа' });
    if (!expectStatus(r, ex, 200, 'статус')) return;
    if (ex.json && typeof ex.json === 'object') o1.seen = ex.json;
    sameOrderFindings(r, ex.json, o1, 'статус');
    r.pass(`статус «${ex.json?.status}», тот же заказ (externalId, ref, номер, дата)`);
  });
  await ctx.run('O5', async (r) => {
    if (!need(r)) return;
    const other = rnd();
    const ex = await r.call({ op: BATCH, path: '/pos/v1/orders/status', body: { externalIds: [o1.body.externalId, other] }, label: 'пакетный статус' });
    if (ex.status === 404) { r.fail('пакетный статус ответил 404 — неизвестные externalId должны быть в notFound, ответ 200', { code: '404' }); return; }
    if (!expectStatus(r, ex, 200, 'пакетный статус')) return;
    const items = Array.isArray(ex.json?.items) ? ex.json.items : [];
    const nf = Array.isArray(ex.json?.notFound) ? ex.json.notFound : [];
    const ours = items.find((i) => i?.externalId === o1.body.externalId);
    if (ours) sameOrderFindings(r, ours, o1, 'пакетный статус');
    else {
      const byRef = items.find((i) => i && i.ref === o1.ref);
      if (byRef) r.fail(`пакетный статус: наш заказ (ref ${o1.ref}) в items с externalId ${show(byRef.externalId)} вместо ${o1.body.externalId} — в элементе externalId заказа POS (Требования §6.8, §6.9); такой элемент POS пропустит`, { code: 'external-id' });
      else if (!nf.includes(o1.body.externalId)) r.fail('наш заказ не попал в items', { code: 'ours' });
    }
    if (!nf.includes(other)) r.fail('случайный externalId не попал в notFound', { code: 'nf' });
    batchListFindings(r, { items, nf, requested: [o1.body.externalId, other], ours: o1.body.externalId, what: 'пакетный статус' });
    r.pass('наш — в items (тот же заказ), случайный — в notFound');
  });
  let cancelled = null;
  await ctx.run('O6', async (r) => {
    if (!need(r)) return;
    const ex = await r.call({ op: CANCEL, path: `/pos/v1/orders/${o1.body.externalId}/cancel`, body: { reason: 'ПРОВЕРКА POS: отмена тестового заказа' }, label: 'отмена' });
    if (!ex.error && ex.status === 409 && ex.isPosError && ex.posCode === 'POS_E_STATE') { await cancelRefused(r, o1); return; }
    if (!expectStatus(r, ex, 200, 'отмена')) return;
    const j = ex.json && typeof ex.json === 'object' ? ex.json : {};
    cancelled = j;
    o1.cancelState = { status: j.status, deletionMark: j.deletionMark };
    const ok = cancelFindings(r, j);
    sameOrderFindings(r, j, o1, 'отмена');
    // Отмена сохранена: статус и пакетный статус сразу после отмены — то же состояние (§6.8 «Ответ без кэширования:
    // изменение в 1С сразу видно в ответе»; §6.7 «POS считает заказ отменённым … по ответу этого метода или по статусу»).
    const same = (x) => normStatus(x?.status) === normStatus(j.status) && x?.deletionMark === j.deletionMark;
    const was = `отмена ответила status ${show(j.status)}, deletionMark = ${show(j.deletionMark)}`;
    const st = await r.call({ op: STATUS, path: `/pos/v1/orders/${o1.body.externalId}/status`, label: 'статус после отмены' });
    if (st.error || st.status !== 200 || !st.json || typeof st.json !== 'object') {
      r.fail(`статус после отмены: нужен 200 с состоянием заказа, пришёл ${statusText(st)}`, { code: 'status-after-cancel' });
    } else {
      if (!same(st.json)) {
        r.fail(`после отмены GET /orders/{uuid}/status отдаёт status ${show(st.json.status)}, deletionMark = ${show(st.json.deletionMark)}, а ${was} — отмена не сохранена (откат транзакции?) или статус берётся из кэша (Требования §6.8 «без кэширования», §6.7)`, { code: 'status-after-cancel' });
      }
      sameOrderFindings(r, st.json, o1, 'статус после отмены');
    }
    const bt = await r.call({ op: BATCH, path: '/pos/v1/orders/status', body: { externalIds: [o1.body.externalId] }, label: 'пакетный статус после отмены' });
    const bItems = Array.isArray(bt.json?.items) ? bt.json.items : [];
    const bNf = Array.isArray(bt.json?.notFound) ? bt.json.notFound : [];
    const item = bItems.find((i) => i?.externalId === o1.body.externalId) || null;
    if (bt.error || bt.status !== 200) r.fail(`пакетный статус после отмены: нужен 200, пришёл ${statusText(bt)}`, { code: 'batch-after-cancel' });
    else {
      if (!item) r.fail(`пакетный статус после отмены: нашего заказа нет в items (до отмены был)${bNf.includes(o1.body.externalId) ? ', он в notFound — отменённый заказ остаётся в 1С и находится (Требования §6.9: в notFound — только заказы, документа которых в 1С нет)' : ''}`, { code: 'batch-after-cancel' });
      else {
        if (!same(item)) {
          r.fail(`после отмены POST /orders/status отдаёт status ${show(item.status)}, deletionMark = ${show(item.deletionMark)}, а ${was} — отмена не сохранена или статус берётся из кэша (Требования §6.9, §6.8 «без кэширования», §6.7)`, { code: 'batch-after-cancel' });
        }
        sameOrderFindings(r, item, o1, 'пакетный статус после отмены');
      }
      if (item) batchListFindings(r, { items: bItems, nf: bNf, requested: [o1.body.externalId], ours: o1.body.externalId, what: 'пакетный статус после отмены' });
    }
    r.pass(`200, ${ok ? 'заказ отменён' : 'статус'} «${j.status}»${j.deletionMark === true ? ', пометка удаления' : ''}; статус и пакетный статус после отмены — то же`);
  });
  await ctx.run('O7', async (r) => {
    if (!cancelled) { r.skip('нет отмены из O6'); return; }
    const ex = await r.call({ op: CANCEL, path: `/pos/v1/orders/${o1.body.externalId}/cancel`, body: { reason: 'ПРОВЕРКА POS: повтор отмены' }, label: 'повтор отмены' });
    if (!expectStatus(r, ex, 200, 'повтор отмены')) return;
    if (ex.json?.status !== cancelled.status || ex.json?.deletionMark !== cancelled.deletionMark) r.fail('повтор отмены вернул другое состояние', { code: 'state' });
    sameOrderFindings(r, ex.json, o1, 'повтор отмены');
    r.pass('200, то же состояние, тот же заказ');
  });
  await ctx.run('O8', async (r) => {
    const ex = await r.call({ op: CANCEL, path: `/pos/v1/orders/${rnd()}/cancel`, body: { reason: 'ПРОВЕРКА POS' }, label: 'отмена случайного' });
    expectPosError(r, ex, 404, 'POS_E_NOT_FOUND', 'отмена несуществующего заказа');
    r.pass('404 POS_E_NOT_FOUND');
  });
  await ctx.run('O9', async (r) => {
    const ex = await r.call({ op: CREATE, path: '/pos/v1/orders', rawBody: '{"externalId":', dataError: true, label: 'неверный JSON' });
    if (ex.status >= 500) { r.fail(`ошибка данных отдана как ${statusText(ex)} — нужен 400`, { code: '5xx' }); return; }
    expectPosError(r, ex, 400, 'POS_E_BAD_REQUEST', 'неверный JSON');
    r.pass('400 POS_E_BAD_REQUEST');
  });
}

