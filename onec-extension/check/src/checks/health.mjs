// H — GET /pos/v1/health (тот же ответ, что в S3/A1).
import { parseIso, isoBishkek } from '../report/time.mjs';

export async function runHealth(ctx) {
  const ex = ctx.data.healthEx;
  const h = ctx.data.health || {};
  await ctx.run('H1', async (r) => {
    r.note(`ответ запроса №${ex.n} (S3)`);
    if (h.apiVersion !== '1') r.fail(`apiVersion = ${JSON.stringify(h.apiVersion)} — нужно строка "1"`, { code: 'api-version', where: 'apiVersion' });
    const v = ex.headers['x-pos-api-version'];
    if (v === undefined) r.fail('нет заголовка X-POS-API-Version: 1', { code: 'no-header' });
    else if (String(v).trim() !== '1') r.fail(`заголовок X-POS-API-Version: «${v}» — нужно 1`, { code: 'bad-header' });
    if (typeof h.exchangeNode === 'string' && h.exchangeNode !== 'POS') r.warn(`exchangeNode = «${h.exchangeNode}» — узел плана обмена по Требованиям (§5) называется «POS»`, { code: 'node' });
    for (const k of ['registrationBacklog', 'lastAckMessageNumber']) {
      if (!(Number.isInteger(h[k]) && h[k] >= 0)) r.fail(`${k}: нужно целое число ≥ 0, пришло ${JSON.stringify(h[k])}`, { code: k, where: k });
    }
    r.evidence = {
      extensionVersion: h.extensionVersion, platform: h.platform, configuration: h.configuration,
      configurationVersion: h.configurationVersion, registrationBacklog: h.registrationBacklog, lastAckMessageNumber: h.lastAckMessageNumber,
    };
    r.pass(`расширение ${h.extensionVersion ?? '?'}, платформа ${h.platform ?? '?'}, ${h.configuration ?? '?'} ${h.configurationVersion ?? ''}`.trim());
  });
  await ctx.run('H2', async (r) => {
    const st = h.serverTime;
    if (typeof st !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+06:00$/.test(st)) {
      r.fail(`serverTime ${JSON.stringify(st)}: дата без смещения +06:00 или не в формате ГГГГ-ММ-ДДTчч:мм:сс+06:00`, { code: 'format', where: 'serverTime' });
      return;
    }
    const t = parseIso(st);
    const local = ex.startedAt.getTime() + ex.ms / 2;
    const diffMin = Math.abs(t.getTime() - local) / 60000;
    r.evidence = { serverTime: st, local: isoBishkek(new Date(local)), diffSeconds: Math.round(Math.abs(t.getTime() - local) / 1000) };
    if (diffMin > 5) r.warn(`часы 1С расходятся с этим компьютером на ${Math.round(diffMin)} мин: 1С ${st}, компьютер ${isoBishkek(new Date(local))} — проверьте время на сервере 1С`, { code: 'clock' });
    r.pass(`расхождение часов ${r.evidence.diffSeconds} с`);
  });
  await ctx.run('H3', async (r) => {
    if (h.status === 'ok') { r.pass('ok'); return; }
    if (h.status === 'warning') r.warn('status = warning: есть не подтверждённые сообщения старше 24 ч или больше 100 000 регистраций', { code: 'warning' });
    else r.warn(`status = ${JSON.stringify(h.status)} — ожидается ok (или warning)`, { code: 'other' });
  });
}
