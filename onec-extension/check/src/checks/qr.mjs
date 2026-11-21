// Q — QR-оплаты через 1С (Требования §6.14–§6.16, §7): делаются, только если интеграция с банком умеет (§7.13, §8.2 этап 5).
import { expectStatus, expectPosError, netFailed, rnd } from './common.mjs';
import { discover } from './orders.mjs';
import { parseIso } from '../report/time.mjs';
import { percentile, selftestGuid } from '../util.mjs';

const QR = 'POST /pos/v1/payments/qr';
const STATUS = 'GET /pos/v1/payments/{externalId}/status';
const CANCEL = 'POST /pos/v1/payments/{externalId}/qr/cancel';

const show = (v) => (v === undefined ? 'нет поля' : v === null ? 'null' : typeof v === 'string' ? `«${v.length > 60 ? v.slice(0, 60) + '…' : v}»` : String(v));
const money = (v) => (typeof v === 'string' && /^-?\d+(\.\d+)?$/.test(v.trim()) ? Number(v).toFixed(2) : null);
const sameMoney = (a, b) => money(a) !== null && money(a) === money(b);
const filled = (v) => typeof v === 'string' && v.trim() !== '';
const instant = (v) => { const d = parseIso(v); return d ? d.getTime() : null; };

/**
 * Ответ статуса или повтора — тот QR, что выдан в Q1: reference, amount, expiresAt (Требования §6.14 п. 2 «тот же QR
 * (qrPayload, reference, expiresAt)», §6.15 reference — «референс QR», expiresAt — «срок действия QR»; §7.3 п. 7: POS
 * отмечает оплату, только если «сумма и референс совпали с выданным QR», иначе — ручная проверка).
 */
export function sameQrFindings(r, j, q, what) {
  qrIdFindings(r, j, q, what);
  if (j.reference !== q.reference) {
    r.fail(`${what}: reference ${show(j.reference)}, а QR выдан с reference ${show(q.reference)} — референс QR, выданный при создании (Требования §6.15, §7.3 п. 7: с чужим референсом POS отправит оплату на ручную проверку)`, { code: 'reference' });
  }
  if (!sameMoney(j.amount, q.amount)) {
    r.fail(`${what}: amount ${show(j.amount)}, а QR выдан на ${show(q.amount)} — сумма QR не меняется (Требования §6.15 amount — «сумма к оплате по QR», §7.3 п. 7)`, { code: 'amount' });
  }
  const t = instant(j.expiresAt);
  if (q.expiresMs !== null && (t === null || Math.abs(t - q.expiresMs) > 1000)) {
    // После отмены QR (Q4) срок отменённого QR Требования не задают: §6.16 п. 3 — «Установите Статус = cancelled», о сроке
    // ни слова; POS по сроку отменённого QR ничего не решает (§6.15: cancelled, «отмену запросил POS» — «ничего не
    // меняется»). Сдвиг срока к моменту отмены (сценарий G12) — ЗАМЕЧАНИЕ и вопрос владельцу, не ОШИБКА.
    if (q.cancelled && j.status === 'cancelled' && t !== null) {
      r.warn(`${what}: после отмены QR expiresAt ${show(j.expiresAt)}, а QR выдан со сроком ${show(q.expiresAt)}. Документы здесь молчат: Требования §6.15 expiresAt — «срок действия QR», §6.14 п. 2 «тот же QR (qrPayload, reference, expiresAt)» — про действующий QR, §6.16 п. 3 «Установите Статус = cancelled» — о сроке отменённого QR ничего; POS по сроку отменённого QR ничего не решает (§6.15: cancelled, отмену запросил POS — «ничего не меняется»). Если 1С меняет срок при отмене осознанно — сообщите разработчику; надёжнее оставлять срок выданного QR`, { code: 'expires-after-cancel', where: 'после отмены' });
      return;
    }
    r.fail(`${what}: expiresAt ${show(j.expiresAt)}, а QR выдан со сроком ${show(q.expiresAt)} — срок действия выданного QR не пересчитывается (Требования §6.15 expiresAt — «срок действия QR», §6.14 п. 2)`, { code: 'expires-changed' });
  }
}

/**
 * externalId в ответе статуса и отмены QR — идентификатор платежа, тот же, что в пути и в POST /payments/qr (Требования
 * §6.15 и §6.16 «Ответ»: externalId — «идентификатор платежа»; §4.7: ключ записи POS_ОплатыQR; контракт QrPaymentStatus,
 * QrCancelResponse). externalId заказа вместо него (сценарий T12) — POS не найдёт свой платёж.
 */
export function qrIdFindings(r, j, q, what) {
  if (!j || typeof j !== 'object' || j.externalId === q.body.externalId) return;
  const isOrder = j.externalId && j.externalId === q.body.orderExternalId;
  r.fail(`${what}: externalId ${show(j.externalId)}, а QR создан для платежа ${q.body.externalId}${isOrder ? ' — это externalId заказа (orderExternalId), а не платежа' : ''}: в ответе — идентификатор платежа, тот же, что в пути запроса и в POST /payments/qr, ключ записи POS_ОплатыQR (Требования §6.15, §6.16 «Ответ»: externalId — «идентификатор платежа»; §4.7). По нему POS сопоставляет ответ и событие QR со своим платежом`, { code: 'external-id', where: what });
}

// Статусы без оплаты: зачисления не было — данных оплаты нет (Требования §6.15 п. 4: деньги после истечения или отмены —
// всё равно paid).
const UNPAID = new Set(['pending', 'cancelled', 'expired']);

/**
 * Q3–Q6, Q8: до оплаты поля оплаты — null (Требования §6.15 «Ответ»: «Все поля присутствуют всегда; поля без значения —
 * null», paidAmount «до оплаты — null», paidAt — «момент зачисления»; §7 п. 6: СуммаОплаты, МоментОплаты, РеференсБанка
 * заполняются при переводе в paid). Пустые значения 1С — 0, Дата(1, 1, 1), пустая строка — не null. Непустой bankReference
 * при pending не ошибка: у него нет «до оплаты — null» (решение раунда fixo1, сценарий «верно» V05).
 */
export function unpaidFindings(r, j, what) {
  if (!j || typeof j !== 'object' || !UNPAID.has(j.status)) return;
  const bad = [];
  if (j.paidAmount !== null && j.paidAmount !== undefined) bad.push(`paidAmount ${show(j.paidAmount)}`);
  if (j.paidAt !== null && j.paidAt !== undefined) bad.push(`paidAt ${show(j.paidAt)}`);
  for (const k of ['bankReference', 'documentType']) if (typeof j[k] === 'string' && j[k].trim() === '') bad.push(`${k} ${show(j[k])}`);
  if (!bad.length) return;
  r.fail(`${what}: статус ${j.status}, а ${bad.join(', ')} — оплаты не было, эти поля null: «поля без значения — null», paidAmount «до оплаты — null», paidAt — «момент зачисления» (Требования §6.15 «Ответ»); пустые значения 1С (0, пустую дату, пустую строку) передавайте как null`, { code: 'unpaid-not-null', where: what });
}

export async function runQrRead(ctx) {
  await ctx.run('Q0', async (r) => {
    await discover(ctx, r, {
      op: STATUS, path: `/pos/v1/payments/${rnd()}/status`, id: 'Q0', what: 'QR-оплата через 1С',
      absentText: 'МЕТОДА НЕТ — QR-оплата через 1С делается, только если интеграция с банком умеет создавать QR и узнавать о зачислении (Требования §7.13, §8.2 этап 5); до этого кассир подтверждает оплату по QR вручную',
      notFoundRef: 'Требования §6.15 «404 — QR с таким externalId не создавался», §8.4 «/payments/{externalId}/status … неизвестный externalId — 404»',
    });
  });
}

export async function runQrWrite(ctx) {
  const ids = ['Q1', 'Q2', 'Q3', 'Q4', 'Q5', 'Q6', 'Q7', 'Q8'];
  if (!ctx.data.present.has('Q0')) {
    const abs = ctx.data.absent.has('Q0');
    for (const id of ids) await ctx.run(id, async (r) => { if (abs) r.absent('МЕТОДА НЕТ (Q0) — QR через 1С делается, только если интеграция с банком умеет (Требования §7.13)'); else r.skip('метод QR не обнаружен (Q0 не выполнялся)'); });
    return;
  }
  let q = null;
  await ctx.run('Q1', async (r) => {
    let yes = !!ctx.demo;
    if (!ctx.demo) {
      const a = await ctx.askYesNo(r, 'Создать пробный QR на 1.00 KGS? Если на копии настроен настоящий банк, QR появится в банке (деньги не списываются, пока никто не оплатит)', { def: 'n', allowSkip: false });
      yes = a === 'y';
    }
    if (!yes) { r.skip('пробный QR не выбран (ответ «нет» по умолчанию)'); return; }
    const order = ctx.data.o1;
    const body = ctx.synth.qr({ orderExternalId: order?.body?.externalId || selftestGuid(), publicNumber: order?.publicNumber });
    const ex = await r.call({ op: QR, path: '/pos/v1/payments/qr', body, label: 'пробный QR 1.00 KGS' });
    if (netFailed(r, ex, 'QR')) { ctx.registry.addCreated({ kind: 'ОплатаQR', externalId: body.externalId, checkId: 'Q1', unknown: true }); return; }
    if (ex.status === 503 && ex.posCode === 'POS_E_QR_UNAVAILABLE') { r.warn('QR недоступен (503 POS_E_QR_UNAVAILABLE) — банк на копии не настроен; проверки QR пропущены', { code: 'unavailable' }); return; }
    if (!expectStatus(r, ex, 201, 'создание QR')) return;
    const j = ex.json || {};
    ctx.registry.addCreated({ kind: 'ОплатаQR', externalId: body.externalId, ref: null, number: j.reference ?? null, date: j.createdAt ?? null, checkId: 'Q1' });
    const exp = parseIso(j.expiresAt);
    if (exp && exp.getTime() <= ex.startedAt.getTime()) r.fail(`expiresAt ${j.expiresAt} не позже момента ответа`, { code: 'expires' });
    if (j.externalId !== body.externalId) r.fail(`externalId ответа ${show(j.externalId)}, а в запросе ${body.externalId} — «тот же, что в запросе» (Требования §6.14 «Ответ»)`, { code: 'external-id' });
    if (!sameMoney(j.amount, body.amount)) {
      r.fail(`amount ${show(j.amount)}, а QR запрошен на ${body.amount} KGS — QR создаётся «на сумму amount» в сомах (Требования §6.14 п. 4; ответ amount — «сумма QR»); сумма в тыйынах?`, { code: 'amount' });
    }
    if (!filled(j.qrPayload) && !filled(j.qrImagePng)) {
      r.fail(`qrPayload ${show(j.qrPayload)} и qrImagePng ${show(j.qrImagePng)} — покупателю нечего показать: заполните qrPayload или qrImagePng, одно из двух (Требования §6.14 «Ответ»)`, { code: 'no-qr' });
    }
    q = { body, reference: j.reference, amount: j.amount, expiresAt: j.expiresAt, expiresMs: instant(j.expiresAt), qrPayload: j.qrPayload ?? null, qrImagePng: j.qrImagePng ?? null };
    ctx.data.q1 = { externalId: body.externalId, reference: j.reference, cancelled: false };
    r.pass(`201, reference ${j.reference}`);
  });
  const need = (r) => { if (!q) { r.skip('нет QR из Q1'); return false; } return true; };
  await ctx.run('Q2', async (r) => {
    if (!need(r)) return;
    const ex = await r.call({ op: QR, path: '/pos/v1/payments/qr', body: q.body, label: 'повтор' });
    if (!expectStatus(r, ex, 200, 'повтор QR')) return;
    const j = ex.json && typeof ex.json === 'object' ? ex.json : {};
    if (j.reference !== q.reference) r.fail('повтор вернул другой reference — банк выпустил второй QR', { code: 'reference' });
    else {
      // Тот же QR целиком: та же строка (или картинка), тот же срок и сумма — к банку при действующем QR не обращаются.
      const diff = [];
      if ((j.qrPayload ?? null) !== q.qrPayload) diff.push('qrPayload');
      if ((j.qrImagePng ?? null) !== q.qrImagePng) diff.push('qrImagePng');
      const t = instant(j.expiresAt);
      if (q.expiresMs !== null && (t === null || Math.abs(t - q.expiresMs) > 1000)) diff.push(`expiresAt (${show(j.expiresAt)}, было ${show(q.expiresAt)})`);
      if (!sameMoney(j.amount, q.amount)) diff.push(`amount (${show(j.amount)}, было ${show(q.amount)})`);
      if (diff.length) r.fail(`повтор при действующем QR: reference тот же, а ${diff.join(', ')} другие — похоже, банк вызван снова; нужен тот же QR (qrPayload, reference, expiresAt), к банку не обращайтесь (Требования §6.14 п. 2)`, { code: 'same-qr' });
    }
    r.pass('200, тот же QR');
  });
  await ctx.run('Q3', async (r) => {
    if (!need(r)) return;
    const ex = await r.call({ op: STATUS, path: `/pos/v1/payments/${q.body.externalId}/status`, label: 'статус' });
    if (!expectStatus(r, ex, 200, 'статус QR')) return;
    if (ex.json?.status !== 'pending') r.fail(`статус «${ex.json?.status}», нужен pending`, { code: 'status' });
    sameQrFindings(r, ex.json && typeof ex.json === 'object' ? ex.json : {}, q, 'статус');
    unpaidFindings(r, ex.json, 'статус');
    r.pass('pending, тот же reference, сумма и срок');
  });
  let cancelled = false;
  await ctx.run('Q4', async (r) => {
    if (!need(r)) return;
    const ex = await r.call({ op: CANCEL, path: `/pos/v1/payments/${q.body.externalId}/qr/cancel`, body: { reason: 'voided' }, label: 'отмена QR' });
    if (!expectStatus(r, ex, 200, 'отмена QR')) return;
    if (ex.json?.status !== 'cancelled') r.fail(`после отмены статус «${ex.json?.status}», нужен cancelled`, { code: 'status' });
    else { cancelled = true; if (ctx.data.q1) ctx.data.q1.cancelled = true; }
    unpaidFindings(r, ex.json, 'отмена QR');
    r.pass('cancelled');
  });
  await ctx.run('Q5', async (r) => {
    if (!cancelled) { r.skip('нет отмены из Q4'); return; }
    const ex = await r.call({ op: CANCEL, path: `/pos/v1/payments/${q.body.externalId}/qr/cancel`, body: { reason: 'voided' }, label: 'повтор отмены' });
    if (!expectStatus(r, ex, 200, 'повтор отмены')) return;
    if (ex.json?.status !== 'cancelled') r.fail(`повтор отмены: статус «${ex.json?.status}»`, { code: 'status' });
    unpaidFindings(r, ex.json, 'повтор отмены');
    r.pass('200 cancelled');
  });
  await ctx.run('Q6', async (r) => {
    if (!cancelled) { r.skip('нет отмены из Q4'); return; }
    const ex = await r.call({ op: STATUS, path: `/pos/v1/payments/${q.body.externalId}/status`, label: 'статус после отмены' });
    if (!expectStatus(r, ex, 200, 'статус')) return;
    if (ex.json?.status !== 'cancelled') r.fail(`статус после отмены «${ex.json?.status}», нужен cancelled`, { code: 'status' });
    sameQrFindings(r, ex.json && typeof ex.json === 'object' ? ex.json : {}, q, 'статус после отмены');
    unpaidFindings(r, ex.json, 'статус после отмены');
    r.pass('cancelled, тот же reference, сумма и срок');
  });
  await ctx.run('Q7', async (r) => {
    const ex = await r.call({ op: CANCEL, path: `/pos/v1/payments/${rnd()}/qr/cancel`, body: { reason: 'voided' }, label: 'отмена случайного' });
    expectPosError(r, ex, 404, 'POS_E_NOT_FOUND', 'отмена несуществующего QR');
    r.pass('404 POS_E_NOT_FOUND');
  });
  await ctx.run('Q8', async (r) => {
    if (!need(r)) return;
    const ms = [];
    for (let i = 0; i < 20; i++) {
      const ex = await r.call({ op: STATUS, path: `/pos/v1/payments/${q.body.externalId}/status`, label: `опрос ${i + 1} из 20` });
      if (!ex.error) ms.push(ex.ms);
      if (ex.status === 200 && ex.json && typeof ex.json === 'object') { sameQrFindings(r, ex.json, q, `опрос ${i + 1}`); unpaidFindings(r, ex.json, 'опрос'); }
    }
    const p95 = percentile(ms, 95);
    r.evidence = { p95: Math.round(p95 ?? 0), count: ms.length };
    if (p95 !== null && p95 > 1000) r.warn(`p95 статуса QR ${Math.round(p95)} мс — больше 1 с`, { code: 'slow' });
    r.pass(`p95 ${Math.round(p95 ?? 0)} мс`);
  });
}

