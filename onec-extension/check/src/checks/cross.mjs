// E — итог сквозных правил по всем ответам прогона; L — время и объём.
import { CATALOG } from './index.mjs';
import { percentile } from '../util.mjs';

export async function finalizeCross(ctx) {
  // Считаются ответы 1С (со статусом HTTP), а не попытки: при обрыве связи проверять было нечего.
  const total = ctx.responses;
  for (const d of CATALOG.filter((x) => x.group === 'E')) {
    const r = ctx.runObj(d.id);
    if (r.done) continue;
    ctx.order.push(d.id);
    const viol = r.findings.filter((f) => f.severity !== 'INFO').reduce((a, f) => a + f.count, 0);
    r.evidence = { ...(r.evidence || {}), responses: total, violations: viol, kinds: r.findings.length };
    if (!total) r.skip('ответов 1С не было — проверять нечего');
    if (!r.findings.length) { if (total) r.pass(`нарушений нет (ответов: ${total})`); }
    else if (!viol) r.pass(`нарушений нет; сведений: ${r.findings.length}`);
    else r.summary = `нарушений: ${viol} (видов: ${r.findings.filter((f) => f.severity !== 'INFO').length})`;
    r.done = true;
  }
}

export async function runTimings(ctx) {
  await ctx.run('L1', async (r) => {
    const rows = [];
    for (const [op, t] of ctx.timings) {
      const ms = t.ms;
      rows.push({
        op, count: ms.length, min: Math.round(Math.min(...ms)), p50: Math.round(percentile(ms, 50)),
        p95: Math.round(percentile(ms, 95)), max: Math.round(Math.max(...ms)), timeoutMs: t.timeoutMs,
      });
    }
    rows.sort((a, b) => a.op.localeCompare(b.op));
    r.evidence = { rows };
    r.infoVerdict(`операций: ${rows.length}, запросов: ${ctx.reqN}`);
  });
  await ctx.run('L2', async (r) => {
    const f = ctx.data.fullRead;
    if (!f) { r.skip('полного чтения не было'); return; }
    const perSec = f.ms > 0 ? Math.round((f.items * 1000) / f.ms) : null;
    r.evidence = { ...f, itemsPerSecond: perSec, pageP95: Math.round(percentile(f.pageMs, 95) ?? 0) };
    r.infoVerdict(`${f.reregistered ? 'после перерегистрации: ' : ''}страниц ${f.pages}, элементов ${f.items}, ${Math.round(f.ms / 100) / 10} с${perSec !== null ? `, ${perSec} элементов/с` : ''}`);
  });
}
