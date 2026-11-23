// R — заявки на возврат (Требования §6.17–§6.18). Методы обязательны, если 1С принимает заявки на возврат извне
// (таблица раздела 6: «обязательно, если 1С принимает такие заявки (Q-018)»; контракт: x-priority «must (условно Q-018)»;
// вопрос 77 раздела 10: «Допущение: передача заявок выключена до вашего ответа») — «метода нет» — МЕТОДА НЕТ, как у QR.
import { expectPosError, netFailed, statusText, rnd } from './common.mjs';
import { discover } from './orders.mjs';

export const RETURNS_ABSENT = 'МЕТОДА НЕТ — заявки на возврат (POST /returns, статус заявки): методы обязательны, если 1С принимает заявки на возврат извне (Требования, таблица раздела 6, §6.17–§6.18; Q-018, вопрос 77 раздела 10); если 1С их не принимает — сообщите ответом на вопрос 77: передача заявок в POS останется выключенной, возвраты оформляют в 1С вручную';

export async function runReturnsRead(ctx) {
  await ctx.run('R0', async (r) => {
    await discover(ctx, r, {
      op: 'GET /pos/v1/returns/{uuid}/status', path: `/pos/v1/returns/${rnd()}/status`, id: 'R0', what: 'заявки на возврат (POST /returns, статус заявки)',
      absentText: RETURNS_ABSENT,
      notFoundRef: 'Требования §6.18 «404 — заявка с таким externalId не найдена», §8.4 «/returns/{uuid}/status … неизвестный externalId — 404»',
    });
  });
}

export async function runReturnsWrite(ctx) {
  await ctx.run('R1', async (r) => {
    if (ctx.data.absent.has('R0')) { r.absent('МЕТОДА НЕТ (R0) — заявки на возврат делаются, если 1С принимает их извне (Q-018, вопрос 77 раздела 10)'); return; }
    if (!ctx.data.present.has('R0')) { r.skip('метод не обнаружен (R0 не выполнялся)'); return; }
    // Только тестовый клиент «ПРОВЕРКА POS» из K1 или клиент, явно указанный в refs.customerRef.
    const customerRef = ctx.data.k1?.ref || ctx.settings.refs?.customerRef;
    const productRef = ctx.data.refs?.productRef;
    if (!customerRef) { r.skip('нет тестового клиента «ПРОВЕРКА POS» (K1) и не указан refs.customerRef'); return; }
    if (!productRef) { r.skip('нет товара: укажите refs.productRef или запустите с перерегистрацией'); return; }
    const body = ctx.synth.returnRequest({ customerRef, productRef });
    const ex = await r.call({ op: 'POST /pos/v1/returns', path: '/pos/v1/returns', body, dataError: true, label: 'несуществующая реализация' });
    if (netFailed(r, ex, 'заявка на возврат')) return;
    if (ex.status === 201 || ex.status === 200) {
      ctx.registry.addCreated({ kind: 'ЗаявкаНаВозврат', externalId: body.externalId, ref: ex.json?.ref ?? null, number: ex.json?.number ?? null, checkId: 'R1', note: 'создана по несуществующей реализации' });
      r.fail(`заявка по несуществующей реализации создана (${ex.status}) — нужен 422`, { code: 'created' });
      return;
    }
    if (ex.status === 404) { r.fail('нужен 422 POS_E_VALIDATION, а не 404', { code: '404' }); return; }
    expectPosError(r, ex, 422, 'POS_E_VALIDATION', 'несуществующая реализация');
    r.pass(`${statusText(ex)}`);
  });
}
