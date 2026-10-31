// Сокращённый soak WP-T1 (critic [4], [19]: «вкладка открыта 8 часов»): собранный backend.js в worker_threads,
// storage 'memory', сид истории включён (как у заказчика). Нагрузка — как у открытого приложения: опросы экранов
// (уведомления, дашборд кассира, список заказов, статус синхронизации — каждые 30–60 с), раз в 3 минуты — продажа
// за наличные с оплатой и QR с автооплатой «1С»; остальное время — простой с фоновыми задачами pg-boss.
// Раз в минуту — замер: память процесса воркера (rss, heap V8), куча WASM PGlite, размер БД (pg_database_size),
// счётчики единицы работы и pg-shim; в начале и в конце — размер тома (dumpDataDir — то, что IDBFS хранит в IndexedDB).
// По наклону (МНК после прогрева) — экстраполяция на 8 часов.
//
//   API: runSoak({ minutes = 20, log }) → отчёт;  CLI: node demo/web/backend/test/scenarios/soak.mjs [--minutes 20] [--json <файл>]
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startWorkerBackend } from '../harness/worker-harness.mjs';
import { cashAmount, createCtx, placeOrder, sellable, sleep } from './dsl.mjs';
import { writeJson } from '../lib/report.mjs';

/** Наклон МНК y(t) на час. */
export function slopePerHour(points, key) {
  const pts = points.filter((p) => typeof p[key] === 'number');
  if (pts.length < 3) return null;
  const xs = pts.map((p) => p.t / 3600e3);
  const ys = pts.map((p) => p[key]);
  const mx = xs.reduce((a, b) => a + b, 0) / xs.length;
  const my = ys.reduce((a, b) => a + b, 0) / ys.length;
  const num = xs.reduce((a, x, i) => a + (x - mx) * (ys[i] - my), 0);
  const den = xs.reduce((a, x) => a + (x - mx) ** 2, 0);
  return den ? num / den : null;
}

/** Наклон «пола» после сборок мусора: скользящий минимум по 3 замерам во второй половине прогона, МБ/ч. */
export function floorSlopePerHour(samples, key) {
  const half = samples.filter((s) => s.t >= samples.at(-1).t / 2 && typeof s[key] === 'number');
  if (half.length < 4) return null;
  const floor = half.map((s, i) => ({ t: s.t, v: Math.min(...half.slice(Math.max(0, i - 1), i + 2).map((x) => x[key])) }));
  return slopePerHour(floor, 'v');
}

export async function runSoak({ minutes = 20, log = console.log, warmupMin = 3 } = {}) {
  const errors = [];
  const be = await startWorkerBackend({ sku: 500, strict: true, initOpts: { seed: true }, boot: { netRecorder: true, exposeGc: true }, onLog: (lv, m) => lv === 'error' && errors.push(String(m).slice(0, 600)) });
  const ctx = createCtx(be, { log: () => {}, label: 'soak' });
  ctx.begin('soak');
  const t0 = Date.now();
  const samples = [];
  const volumes = [];
  const sample = async (phase) => {
    const st = await be.stats();
    const mem = await be.mem({ gc: true }); // после полной сборки мусора: «пол» кучи, без пилы GC
    samples.push({ t: Date.now() - t0, phase, rss: mem.rss, heapUsed: mem.heapUsedV8, heapTotal: mem.heapTotalV8, external: mem.external, wasmHeap: st.wasmHeapBytes, dbSize: st.dbSize, gateStarted: st.gate.stats.started, holds3s: st.gate.stats.holdsOver3s, queue3s: st.gate.stats.queueWaitsOver3s, pgWaits3s: st.pg.waitsOver3s, outside: st.pg.outsideWhitelist, bossJobs: st.boss.jobUnits, seed: st.seed?.state });
  };
  const volume = async (phase) => {
    const d = await be.rpc({ type: 'dump' }, 120000);
    volumes.push({ t: Date.now() - t0, phase, bytes: d.data?.byteLength ?? 0 });
  };
  let orders = 0;
  let qrPaid = 0;
  let failedCalls = 0;
  let finalStats = null;
  const failedSamples = [];
  let refreshes = 0;
  try {
    const A = ctx.dev('windows', { name: 'админ' });
    const C = ctx.dev('windows', { name: 'кассир' });
    const S = ctx.dev('windows', { name: 'продавец' });
    await A.login('+996777000901');
    await C.login('+996777000906');
    await S.login('+996777000902');
    for (const s of [A, C, S]) s.autoRefresh = true;
    await ctx.panel('POST qr/config', { paidAfterPolls: 3 });
    const pl = await sellable(C, { limit: 100, maxPrice: 6000 });
    await sample('start');
    await volume('start');
    const end = t0 + minutes * 60e3;
    let tick = 0;
    let lastSample = Date.now();
    while (Date.now() < end) {
      const cycleStart = Date.now();
      tick++;
      // опросы экранов (как интервалы приложения: уведомления 60 с, дашборд 60 с, заказы 30 с, статус 30 с)
      for (const [s, url] of [
        [C, '/me'],
        [C, '/notifications?limit=20'],
        [C, '/pos/dashboard'],
        [C, '/orders?limit=20&include=statusCounts'],
        [A, '/sync/status'],
        [S, '/catalog/products?limit=20&inStock=true'],
        [S, '/cart'],
      ]) {
        const r = await s.call(`опрос ${url}`, 'GET', url, { record: false });
        if (r.status >= 400 || r.status === 0) {
          failedCalls++;
          if (failedSamples.length < 10) failedSamples.push({ url, status: r.status, code: r.json?.code ?? null, min: +((Date.now() - t0) / 60e3).toFixed(1) });
        }
      }
      if (tick % 6 === 1) {
        // раз в ~3 мин: наличные (кассир, оплата) и QR продавца с автооплатой
        const o = (await placeOrder(C, pl[orders % pl.length], 'cash', { label: `soak наличные ${orders}`, idem: true })).order;
        const paid = o.json?.id ? await C.call('soak оплата', 'POST', `/orders/${o.json.id}/payments`, { idem: true, body: { method: 'cash', receivedAmount: cashAmount(o.json) }, expect: [200, 201] }) : null;
        if (![201, 202].includes(o.status) || paid?.json?.status !== 'received') {
          failedCalls++;
          if (failedSamples.length < 10) failedSamples.push({ url: 'POST /orders + оплата', status: o.status, code: o.json?.code ?? null, pay: paid?.status ?? null, min: +((Date.now() - t0) / 60e3).toFixed(1) });
        }
        const q = (await placeOrder(S, pl[(orders + 7) % pl.length], 'qr_bakai', { label: `soak QR ${orders}` })).order;
        const pid = q.json?.payments?.[0]?.id;
        if (pid) {
          const r = await S.call('soak long-poll', 'GET', `/payments/${pid}?wait=25`, { record: false });
          if (r.json?.status === 'received' || (await S.call('soak long-poll 2', 'GET', `/payments/${pid}?wait=25`, { record: false })).json?.status === 'received') qrPaid++;
        }
        orders++;
      }
      if (Date.now() - lastSample >= 60e3) {
        await sample(Date.now() - t0 < warmupMin * 60e3 ? 'warmup' : 'run');
        lastSample = Date.now();
        log(`[soak ${((Date.now() - t0) / 60e3).toFixed(1)} мин] heap ${(samples.at(-1).heapUsed / 1e6).toFixed(1)} МБ, rss ${(samples.at(-1).rss / 1e6).toFixed(0)} МБ, wasm ${(samples.at(-1).wasmHeap / 1e6).toFixed(0)} МБ, БД ${(samples.at(-1).dbSize / 1e6).toFixed(1)} МБ, заказов ${orders}, сид ${samples.at(-1).seed}`);
      }
      await sleep(Math.max(0, 30e3 - (Date.now() - cycleStart)));
    }
    await sample('end');
    await volume('end');
    refreshes = [A, C, S].reduce((a, s) => a + (s.refreshes ?? 0), 0);
  } finally {
    finalStats = await be.stats().catch(() => null);
    await be.close();
  }
  const run = samples.filter((s) => s.phase !== 'warmup' && s.phase !== 'start');
  const per = (k) => slopePerHour(run.length >= 3 ? run : samples, k);
  const durH = (samples.at(-1).t - samples[0].t) / 3600e3;
  const ex = (k) => {
    const s = per(k);
    return s === null ? null : { perHourMB: +(s / 1e6).toFixed(2), in8hMB: +((s * 8) / 1e6).toFixed(1) };
  };
  const vol = volumes.length >= 2 ? { startMB: +(volumes[0].bytes / 1e6).toFixed(2), endMB: +(volumes.at(-1).bytes / 1e6).toFixed(2), perHourMB: +((volumes.at(-1).bytes - volumes[0].bytes) / 1e6 / Math.max(durH, 1e-6)).toFixed(2) } : null;
  if (vol) vol.in8hMB = +(vol.endMB + vol.perHourMB * Math.max(0, 8 - durH)).toFixed(1);
  const rep = {
    minutes: +(durH * 60).toFixed(1),
    orders,
    qrPaid,
    failedCalls,
    failedSamples,
    tokenRefreshes: refreshes,
    requests: finalStats?.bridge?.requests ?? null,
    extrapolation8h: { heapUsed: ex('heapUsed'), rss: ex('rss'), wasmHeap: ex('wasmHeap'), dbSize: ex('dbSize') },
    // справочно: вторая половина прогона («пол» по скользящему минимуму, heapTotal, rss процесса Node)
    leak8h: (() => {
      const f = (k) => {
        const s = floorSlopePerHour(samples, k);
        return s === null ? null : { perHourMB: +(s / 1e6).toFixed(2), in8hMB: +((s * 8) / 1e6).toFixed(1) };
      };
      return { heapUsedFloor: f('heapUsed'), heapTotal: f('heapTotal'), wasmHeap: f('wasmHeap'), rss: f('rss') };
    })(),
    volume: vol,
    last: samples.at(-1),
    first: samples[0],
    watchdog: { holds3s: samples.at(-1).holds3s, queue3s: samples.at(-1).queue3s, pgWaits3s: samples.at(-1).pgWaits3s, outsideWhitelist: samples.at(-1).outside },
    net: { events: be.netEvents.length, blocked: finalStats?.net?.blocked ?? null },
    errors: errors.slice(0, 20),
    errorCount: errors.length,
    samples,
    volumes,
  };
  return rep;
}

/** Критерии soak: стабильность, без ошибок; рост памяти и тома за 8 ч — в пределах. */
export function soakCriteria(rep) {
  const crit = [];
  const add = (name, ok, evidence) => crit.push({ name, ok: !!ok, evidence: JSON.stringify(evidence) });
  add(`soak ${rep.minutes} мин: все опросы 2xx (токены обновляются, как в приложении), заказы оплачиваются, QR проходят`, rep.failedCalls === 0 && rep.orders >= 3 && rep.qrPaid === rep.orders, { failedCalls: rep.failedCalls, failedSamples: rep.failedSamples, orders: rep.orders, qrPaid: rep.qrPaid, tokenRefreshes: rep.tokenRefreshes, requests: rep.requests });
  add('soak: сторож молчит (0 удержаний/ожиданий > 3 с, 0 подсадок вне белого списка), ERROR в журнале нет', rep.watchdog.holds3s === 0 && rep.watchdog.queue3s === 0 && rep.watchdog.pgWaits3s === 0 && rep.watchdog.outsideWhitelist === 0 && rep.errorCount === 0, { ...rep.watchdog, errorCount: rep.errorCount, errors: rep.errors.slice(0, 3) });
  // МНК по всем замерам ловит ступень роста кучи к плато и пилу GC; критерий утечки — «пол» кучи после GC и heapTotal
  // во второй половине прогона (rss процесса — справочно: в нём весь Node, а не только вкладка)
  // замеры кучи — после полной сборки мусора в воркере (gc), поэтому МНК после прогрева показывает рост живых объектов
  const heap8 = rep.extrapolation8h.heapUsed?.in8hMB ?? 0;
  const wasm8 = rep.extrapolation8h.wasmHeap?.in8hMB ?? 0;
  add('soak → 8 ч: живая куча JS (после GC) растёт ≤ 150 МБ, куча WASM PGlite ≤ 150 МБ (вкладка остаётся в 300–600 МБ)', heap8 <= 150 && wasm8 <= 150, { extrapolation8h: rep.extrapolation8h, secondHalf: rep.leak8h });
  add('soak → 8 ч: том PGlite (что хранит IndexedDB) ≤ 200 МБ', !rep.volume || rep.volume.in8hMB <= 200, rep.volume);
  add('soak: ни одного сетевого вызова воркера', rep.net.events === 0 && !rep.net.blocked, rep.net);
  return crit;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const argv = process.argv.slice(2);
  const arg = (k, d) => (argv.includes(k) ? argv[argv.indexOf(k) + 1] : d);
  const rep = await runSoak({ minutes: Number(arg('--minutes', 20)) });
  const crit = soakCriteria(rep);
  const out = arg('--json', null);
  if (out) writeJson(out, { ...rep, criteria: crit });
  for (const c of crit) console.log(`${c.ok ? 'OK  ' : 'FAIL'} ${c.name}\n      ${c.evidence.slice(0, 500)}`);
  process.exit(crit.every((c) => c.ok) ? 0 : 1);
}
