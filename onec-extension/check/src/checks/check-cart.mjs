// CK — проверка корзины POST /check (Требования §6.5; обязательный метод: «метода нет» — ОШИБКА);
// CC — карточка товара GET /catalog/{ref} (Требования §6.21; по желанию).
import { expectStatus, netFailed, statusText, looksAbsent, absentRequired } from './common.mjs';
import { receivablesFindings } from './customers.mjs';
import { parseIso } from '../report/time.mjs';

const CHECK = 'POST /pos/v1/check';

export async function runCatalogRead(ctx) {
  await ctx.run('CC1', async (r) => {
    const ref = ctx.data.refs?.productRef;
    if (!ref) { r.skip('нет товара (refs.productRef)'); return; }
    const ex = await r.call({ op: 'GET /pos/v1/catalog/{ref}', path: `/pos/v1/catalog/${ref}`, absentProbe: true, label: 'карточка товара' });
    if (netFailed(r, ex, 'карточка')) return;
    if (looksAbsent(ctx, ex)) { ctx.data.absent.add('CC1'); r.absent('МЕТОДА НЕТ — карточка товара делается по желанию (Требования §6.21, §8.2): допустимо'); return; }
    ctx.data.present.add('CC1');
    if (ex.status === 404) { r.warn(`товар ${ref} из /changes не найден карточкой (404)`, { code: '404' }); return; }
    if (!expectStatus(r, ex, 200, 'карточка')) return;
    r.pass('200 по схеме CatalogCard');
  });
}

export async function runCheckCart(ctx) {
  const productRef = ctx.data.refs?.productRef, warehouseRef = ctx.data.refs?.warehouseRef;
  let ok = false;
  await ctx.run('CK1', async (r) => {
    if (!productRef || !warehouseRef) { r.skip('нет товара и склада (refs)'); return; }
    const body = ctx.synth.check({ productRef, warehouseRef, priceListRef: ctx.data.refs?.priceListRef || null });
    const ex = await r.call({ op: CHECK, path: '/pos/v1/check', body, absentProbe: true, label: '2 строки, наличные, без скидок' });
    if (netFailed(r, ex, 'проверка корзины')) return;
    if (looksAbsent(ctx, ex)) { absentRequired(ctx, r, 'CK1', { what: 'проверка корзины POST /check', section: '§6.5', stage: '3 «Чтение»' }); return; }
    ctx.data.present.add('CK1');
    if (!expectStatus(r, ex, 200, 'проверка корзины')) return;
    const j = ex.json || {};
    if (j.receivables !== null) r.fail('receivables должен быть null (клиент не указан)', { code: 'receivables' });
    if (j.totals !== null) r.fail('totals должен быть null при calculateDiscounts=false', { code: 'totals' });
    if (Array.isArray(j.lines) && j.lines.length !== body.lines.length) r.fail(`строк в ответе ${j.lines.length}, в запросе ${body.lines.length}`, { code: 'lines' });
    if (ex.ms > 3000) r.warn(`проверка корзины ${Math.round(ex.ms)} мс — дольше 3 с (Требования §4.9)`, { code: 'slow' });
    ok = true;
    r.pass(`200 за ${Math.round(ex.ms)} мс`);
  });
  const noMethod = () => (ctx.data.absent.has('CK1') ? 'метода проверки корзины нет (CK1 — ОШИБКА)' : 'нет успешной проверки CK1');
  await ctx.run('CK2', async (r) => {
    if (!ok) { r.skip(noMethod()); return; }
    const body = ctx.synth.check({ productRef, warehouseRef, priceListRef: ctx.data.refs?.priceListRef || null, lines: 1, quantity: '999999.000' });
    const ex = await r.call({ op: CHECK, path: '/pos/v1/check', body, label: 'количество 999999.000' });
    if (!expectStatus(r, ex, 200, 'корзина с большим количеством')) return;
    const line = ex.json?.lines?.[0];
    const codes = (line?.issues || []).map((i) => i?.code);
    if (!codes.includes('STOCK_INSUFFICIENT')) r.fail('в строке нет замечания STOCK_INSUFFICIENT при количестве 999999.000', { code: 'no-issue' });
    if (line && line.isAvailable !== false) r.fail('isAvailable должен быть false', { code: 'available' });
    r.pass('STOCK_INSUFFICIENT, isAvailable=false');
  });
  await ctx.run('CK3', async (r) => {
    if (!ok) { r.skip(noMethod()); return; }
    const body = ctx.synth.check({ productRef, warehouseRef, lines: 101 });
    const ex = await r.call({ op: CHECK, path: '/pos/v1/check', body, dataError: true, label: '101 строка' });
    if (netFailed(r, ex, '101 строка')) return;
    if (ex.status !== 400) { r.fail(`101 строка (maxItems 100): нужен 400, пришёл ${statusText(ex)}`, { code: 'status' }); return; }
    r.pass('400');
  });
  // КП-7: корзина в долг клиента (paymentMethod=credit и customerRef) — в ответе блок receivables (контракт
  // CheckResponse.receivables: «только при customerRef и paymentMethod=credit»). /check ничего не записывает
  // (Требования §4.7 «методы чтения»), поэтому берётся клиент из /changes или refs.customerRef.
  await ctx.run('CK4', async (r) => {
    if (!ok) { r.skip(noMethod()); return; }
    const customerRef = ctx.data.refs?.customerRef || ctx.data.k1?.ref || null;
    if (!customerRef) { r.skip('нет клиента: укажите refs.customerRef (клиент с долгом и соглашением в долг) или запустите с перерегистрацией'); return; }
    const body = ctx.synth.check({ productRef, warehouseRef, priceListRef: ctx.data.refs?.priceListRef || null, lines: 1, customerRef, paymentMethod: 'credit' });
    const ex = await r.call({ op: CHECK, path: '/pos/v1/check', body, label: 'в долг (credit), клиент указан' });
    if (netFailed(r, ex, 'корзина в долг')) return;
    if (ex.status === 422 && ex.isPosError) { r.warn(`корзина в долг клиенту ${customerRef} отклонена (${statusText(ex)}) — проверьте, что у клиента есть соглашение с продажей в долг (refs.customerRef)`, { code: 'rejected' }); return; }
    if (!expectStatus(r, ex, 200, 'корзина в долг')) return;
    const rec = ex.json?.receivables;
    if (rec === null || rec === undefined || typeof rec !== 'object') {
      r.fail('при paymentMethod=credit и указанном клиенте нужен блок receivables (долг и лимит клиента), пришёл null — кассир не увидит долг (Требования §6.5: блок заполняется при customerRef и paymentMethod=credit; КП-7: «блок receivables с долгом и лимитом»)', { code: 'no-receivables' });
      return;
    }
    // Блок — «те же поля итога, что и ответ метода долга» (Требования §6.5): те же правила приёма POS и свежесть снимка;
    // «Сальдо должно совпадать с отчётом «Задолженность клиентов» на момент checkedAt» (§6.5) — снимок на момент checkedAt.
    const rej = (t, where = null) => r.fail(`POS не применит блок receivables: ${t}`, { code: 'reject', where: where && `receivables.${where}` });
    const stale = receivablesFindings(ctx, r, rec, { ex, what: 'блок receivables', rej });
    const snap = parseIso(rec.snapshotAt), chk = parseIso(ex.json?.checkedAt);
    if (stale === null && snap && chk && Math.abs(chk.getTime() - snap.getTime()) > 5 * 60000) {
      r.fail(`блок receivables: snapshotAt ${rec.snapshotAt}, а checkedAt ответа ${ex.json.checkedAt} — расходятся больше чем на 5 минут: долг в /check — на момент checkedAt, теми же правилами, что метод долга (Требования §6.5 «Сальдо должно совпадать с отчётом … на момент checkedAt», §6.12 snapshotAt)`, { code: 'snapshot-checked-at' });
    }
    r.evidence = { customerRef, balance: rec.balance ?? null, creditLimit: rec.creditLimit ?? null, snapshotAt: rec.snapshotAt ?? null };
    r.pass(`блок receivables есть: долг ${rec.balance ?? '?'}, лимит ${rec.creditLimit ?? 'нет'}, снимок на момент проверки`);
  });
}
