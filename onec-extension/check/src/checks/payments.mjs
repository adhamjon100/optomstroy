// PAY — оплаты POST /pos/v1/payments (Требования §6.13).
import { expectStatus, expectPosError, netFailed, statusText, burst, rnd, sameObjectDiffs, documentDateFindings } from './common.mjs';

const PAY = 'POST /pos/v1/payments';

// Контракт /payments: «`post` применяется только при `РазрешитьПроведениеПлатежей = Истина` (Q-124), иначе
// `posted=false`»; программа шлёт post=false — проведённый документ значит, что 1С проводит без просьбы.
function postedNotAsked(r, body, j) {
  if (body && body.post === false && j && j.posted === true) {
    r.fail('документ проведён, хотя post=false (контракт: post применяется только при РазрешитьПроведениеПлатежей = Истина, иначе posted=false)', { code: 'posted-not-asked' });
    return true;
  }
  return false;
}

// Вид документа по способу оплаты (контракт POST /payments: «ПриходныйКассовыйОрдер для cash, документ поступления
// безнала или эквайринга для qr_bakai»; Требования §6.13 п. 3, имена — «типово, уточнить»).
const NON_CASH_DOC = /Безналичн|ПлатежнойКарт|РасчетныйСчет|Эквайринг|Банк/i;
const CASH_DOC = /КассовыйОрдер|ПКО/i;

/** documentType ответа против kind запроса: заведомо не тот вид — ОШИБКА, непривычное имя — ЗАМЕЧАНИЕ. */
export function documentTypeForKind(r, kind, documentType) {
  if (typeof documentType !== 'string' || !documentType) return;
  if (!/^Document_/.test(documentType)) { r.fail(`documentType «${documentType}» — нужен вид Document_…`, { code: 'doc-type' }); return; }
  if (kind === 'cash') {
    if (NON_CASH_DOC.test(documentType)) r.fail(`оплата наличными (kind=cash) оформлена документом ${documentType} — для наличных нужен приходный кассовый ордер (контракт POST /payments: «ПриходныйКассовыйОрдер для cash»; Требования §6.13 п. 3)`, { code: 'doc-kind' });
    else if (!CASH_DOC.test(documentType)) r.warn(`оплата наличными оформлена документом ${documentType} — типово Document_ПриходныйКассовыйОрдер; если ПКО в вашей конфигурации называется иначе, сообщите имя (Требования §6.13 п. 3, «типово — уточнить»)`, { code: 'doc-kind-name' });
  } else if (kind === 'qr_bakai' && CASH_DOC.test(documentType)) {
    r.fail(`оплата по QR (kind=qr_bakai) оформлена кассовым ордером ${documentType} — нужен документ поступления безнала или эквайринга (контракт POST /payments; Требования §6.13 п. 3)`, { code: 'doc-kind' });
  }
}

export async function runPayments(ctx) {
  const synth = ctx.synth;
  // Оплаты — только по тестовому клиенту «ПРОВЕРКА POS» из K1; другой клиент — только если его явно указали в
  // настройках (refs.customerRef), и тогда он назван в подтверждении записи. Клиент из /changes не берётся никогда.
  const customerRef = () => ctx.data.k1?.ref || ctx.settings.refs?.customerRef || null;
  const NO_CUSTOMER = 'нет тестового клиента «ПРОВЕРКА POS» (K1 не создал клиента; клиента из базы программа для записи не берёт — его можно указать в refs.customerRef)';
  let p1 = null;
  await ctx.run('PAY1', async (r) => {
    const cust = customerRef();
    if (!cust) { r.skip(NO_CUSTOMER); return; }
    const body = synth.payment({ customerRef: cust });
    const ex = await r.call({ op: PAY, path: '/pos/v1/payments', body, label: 'наличные 1.00 KGS, без продажи, post=false' });
    if (netFailed(r, ex, 'оплата')) {
      ctx.registry.addCreated({ kind: 'Платеж', externalId: body.externalId, checkId: 'PAY1', unknown: true, note: 'результат неизвестен (нет ответа)' });
      return;
    }
    // orderExternalId = null — «оплата долга без заказа» (Требования §6.13). У нового тестового клиента долга нет, и
    // 409 POS_E_STATE («состояние долга не допускает такую оплату») или 422 по Требованиям допустимы: ЗАМЕЧАНИЕ, не ОШИБКА.
    if ((ex.status === 409 || ex.status === 422) && ex.isPosError) {
      r.warn(`оплата 1.00 KGS без заказа новому клиенту без долга отклонена (${statusText(ex)}) — по Требованиям §6.13 это допустимо; повтор и защита от дублей оплаты (PAY2, PAY3) не проверены — проверьте их по КП-14 (оплата долга с allocations)`, { code: 'no-debt-rejected' });
      ctx.data.notCreated = [...(ctx.data.notCreated || []), { externalId: body.externalId, checkId: 'PAY1' }];
      return;
    }
    if (ex.status === 200) r.fail('200 вместо 201 на первое создание (externalId новый)', { code: '200' });
    else if (ex.status !== 201) { r.fail(`оплата: нужен 201, пришёл ${statusText(ex)}`, { code: 'status' }); return; }
    const j = ex.json || {};
    const posted = postedNotAsked(r, body, j);
    ctx.registry.addCreated({ kind: 'Платеж', externalId: body.externalId, ref: j.ref ?? null, number: j.number ?? null, date: j.date ?? null, checkId: 'PAY1',
      ...(posted ? { note: 'документ проведён — перед удалением отмените проведение' } : {}) });
    documentTypeForKind(r, body.kind, j.documentType);
    documentDateFindings(ctx, r, { date: j.date, sentAt: body.receivedAt, sentField: 'receivedAt', ex, what: 'дата документа оплаты (date)' });
    p1 = { body, ref: j.ref, number: j.number, date: j.date, documentType: j.documentType, posted: j.posted };
    r.pass(`201, ${j.documentType ?? '?'} № ${j.number ?? '?'}, проведён: ${j.posted}`);
  });
  await ctx.run('PAY2', async (r) => {
    if (!p1?.ref) { r.skip('нет оплаты из PAY1'); return; }
    const ex = await r.call({ op: PAY, path: '/pos/v1/payments', body: p1.body, label: 'повтор' });
    if (ex.status === 201) { r.fail('повтор создал второй документ (201) — нужен 200 с тем же документом', { code: 'dup' }); ctx.registry.addCreated({ kind: 'Платеж', externalId: p1.body.externalId + ' (повтор)', ref: ex.json?.ref ?? null, checkId: 'PAY2' }); return; }
    if (!expectStatus(r, ex, 200, 'повтор')) return;
    const j = ex.json || {};
    for (const k of ['ref', 'number', 'date']) if (j[k] !== p1[k]) r.fail(`повтор вернул другой ${k}: ${j[k]} (был ${p1[k]})`, { code: k });
    for (const d of sameObjectDiffs(p1, j, ['documentType'])) r.fail(`повтор вернул другой вид документа — ${d}`, { code: 'documentType' });
    documentTypeForKind(r, p1.body.kind, j.documentType);
    // Повтор отдаёт текущее состояние документа (Требования §4.7 п. 1: «номер, дата, статус»): если бухгалтер провёл
    // ПКО между запросами, posted=true верно. Само проведение на повтор при post=false — ошибка, но отличить одно от
    // другого программа не может: ЗАМЕЧАНИЕ.
    if (p1.posted === false && j.posted === true) {
      r.warn('повтор вернул posted=true, а при создании было posted=false: если документ провёл бухгалтер между запросами — это верно (повтор отдаёт текущее состояние); если никто не проводил — 1С проводит документ при повторе, а на повтор ничего изменять нельзя (Требования §4.7 п. 1)', { code: 'posted-changed' });
    } else postedNotAsked(r, p1.body, j);
    r.pass('200, тот же документ');
  });
  await ctx.run('PAY3', async (r) => {
    const cust = customerRef();
    if (!cust) { r.skip(NO_CUSTOMER); return; }
    if (ctx.data.notCreated?.some((x) => x.checkId === 'PAY1')) { r.skip('оплата без заказа клиенту без долга отклонена (PAY1) — десять одинаковых запросов дадут тот же отказ'); return; }
    await burst(ctx, r, { op: PAY, path: '/pos/v1/payments', body: synth.payment({ customerRef: cust }), kind: 'Платеж', same: ['number', 'date', 'documentType'] });
  });
  await ctx.run('PAY4', async (r) => {
    const cust = customerRef();
    if (!cust) { r.skip(NO_CUSTOMER); return; }
    const body = synth.payment({ customerRef: cust, orderExternalId: rnd() });
    const ex = await r.call({ op: PAY, path: '/pos/v1/payments', body, dataError: true, label: 'оплата несуществующего заказа' });
    if (netFailed(r, ex, 'оплата несуществующего заказа')) return;
    if (ex.status === 201 || ex.status === 200) {
      ctx.registry.addCreated({ kind: 'Платеж', externalId: body.externalId, ref: ex.json?.ref ?? null, number: ex.json?.number ?? null, checkId: 'PAY4', note: 'создан по несуществующему заказу' });
      r.fail(`оплата несуществующего заказа принята (${ex.status}) — нужен 422 «Заказ не найден», документ не создаётся`, { code: 'created' });
      return;
    }
    ctx.data.notCreated = [...(ctx.data.notCreated || []), { externalId: body.externalId, checkId: 'PAY4' }];
    if (ex.status === 404) { r.fail('нужен 422 "Заказ не найден", а не 404 — 404 POS примет за «нет метода/адреса»', { code: '404' }); return; }
    expectPosError(r, ex, 422, 'POS_E_VALIDATION', 'оплата несуществующего заказа');
    r.pass('422 POS_E_VALIDATION');
  });
  await ctx.run('PAY5', async (r) => {
    const cust = customerRef();
    if (!cust) { r.skip(NO_CUSTOMER); return; }
    const body = synth.payment({ customerRef: cust, allocations: [{ documentRef: rnd(), amount: '2.00' }] });
    const ex = await r.call({ op: PAY, path: '/pos/v1/payments', body, dataError: true, label: 'распределение 2.00 при сумме 1.00' });
    if (netFailed(r, ex, 'распределение больше суммы')) return;
    if (ex.status === 201 || ex.status === 200) {
      ctx.registry.addCreated({ kind: 'Платеж', externalId: body.externalId, ref: ex.json?.ref ?? null, number: ex.json?.number ?? null, checkId: 'PAY5', note: 'создан с распределением больше суммы' });
      r.fail(`распределение больше суммы оплаты принято (${ex.status}) — нужен 422`, { code: 'created' });
      return;
    }
    ctx.data.notCreated = [...(ctx.data.notCreated || []), { externalId: body.externalId, checkId: 'PAY5' }];
    expectPosError(r, ex, 422, 'POS_E_VALIDATION', 'распределение больше суммы');
    r.pass('422 POS_E_VALIDATION');
  });
  await ctx.run('PAY6', async (r) => {
    const ex = await r.call({ op: PAY, path: '/pos/v1/payments', rawBody: '{"externalId":', dataError: true, label: 'неверный JSON' });
    if (netFailed(r, ex, 'неверный JSON')) return;
    if (ex.status >= 500) { r.fail(`ошибка данных отдана как ${statusText(ex)} — на неверный JSON нужен 400 POS_E_BAD_REQUEST`, { code: '5xx' }); return; }
    expectPosError(r, ex, 400, 'POS_E_BAD_REQUEST', 'неверный JSON');
    r.pass('400 POS_E_BAD_REQUEST');
  });
}
