// Прогон СОБРАННОГО site/backend/backend.js в Node (WP-B2; переиспользуется WP-T1): бандл запускается в
// node:worker_threads с прослойкой self/postMessage/addEventListener (worker-boot.mjs), PGlite storage 'memory',
// тот же протокол моста, что у страницы (plan §3.3): init → ready {features}, http → http:start → http:res,
// http:cancel, control → control:res, stats/logs/reqstats → res, shutdown.
//
//   API:  const be = await startWorkerBackend({ sku: 120, strict: true }); await be.api('GET', '/health'); …; await be.close();
//   CLI:  node demo/web/backend/test/harness/worker-harness.mjs [--sku 120] [--no-strict] [--json <файл>] [--quiet]
//         прогон scenario-run-full.mjs + проверка приёмки WP-B2; код выхода 0 — всё выполнено, 1 — нет.
//
// Внешние файлы vfs (шрифты Inter) передаются байтами (opts.vfsExternal) из site/backend по build.json.
import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { Worker } from 'node:worker_threads';

const HERE = dirname(fileURLToPath(import.meta.url));
export const SITE = resolve(HERE, '../../../site').replace(/\\/g, '/');

const enc = new TextEncoder();
const dec = new TextDecoder();

/**
 * Запустить бэкенд в worker_threads и дождаться ready.
 * opts: { site, sku=120, storage='memory', qrPaidAfterPolls=2, strict=true, gate, shim, onecRetry, initOpts, onLog,
 *         initTimeoutMs=120000, snapshot (false — без снимка site/demo/snapshot; снимок берётся, только если его
 *         число SKU = sku, иначе воркер грузит каталог конвейером),
 *         WP-T1: backendFile (другой бандл — эталон native-runner.mjs), boot { clockOffsetMs, netRecorder } (см.
 *         worker-boot.mjs), onNet(event) }
 */
export async function startWorkerBackend(opts = {}) {
  const site = opts.site ?? SITE;
  const build = JSON.parse(readFileSync(`${site}/backend/build.json`, 'utf8'));
  const vfsExternal = Object.fromEntries(Object.entries(build.backend?.vfsExternal ?? {}).map(([k, url]) => [k, new Uint8Array(readFileSync(`${site}/backend/${url}`)).buffer]));
  // Снимок БД (WP-B4): fetch в Node не читает file:, поэтому байты site/demo/snapshot передаются в init, как
  // vfsExternal; воркер распаковывает и проверяет их тем же кодом, что в браузере. snapshot: false — без снимка.
  let snapshotData;
  const snapDir = `${site}/demo/snapshot`;
  if (opts.snapshot !== false && existsSync(`${snapDir}/manifest.json`)) {
    const manifest = readFileSync(`${snapDir}/manifest.json`, 'utf8');
    const gzFile = JSON.parse(manifest).data?.gzipFile;
    if (gzFile && existsSync(`${snapDir}/${gzFile}`)) snapshotData = { manifest, dataGz: new Uint8Array(readFileSync(`${snapDir}/${gzFile}`)).buffer };
  }
  const backendFile = opts.backendFile ?? `${site}/backend/backend.js`;
  const worker = new Worker(new URL('./worker-boot.mjs', import.meta.url), {
    workerData: { backendUrl: pathToFileURL(backendFile).href, ...(opts.boot ?? {}) },
    env: { ...process.env },
    stdout: false,
    stderr: false,
  });
  const pendingHttp = new Map();
  const pendingRpc = new Map();
  const errorLogs = [];
  const netEvents = [];
  const storageEvents = [];
  const fatalEvents = [];
  const fencedEvents = [];
  let seq = 0;
  let exited = null;
  let loadedResolve;
  const loaded = new Promise((r) => (loadedResolve = r));
  worker.on('message', (m) => {
    switch (m?.type) {
      case 'loaded':
        loadedResolve();
        return;
      case 'progress':
        return;
      case '__net':
        netEvents.push({ api: m.api, url: m.url, at: Date.now() });
        opts.onNet?.(m);
        return;
      case '__mem:res': {
        const p = pendingRpc.get(m.id);
        if (p) {
          pendingRpc.delete(m.id);
          p(m);
        }
        return;
      }
      case 'log':
        errorLogs.push(m.msg);
        opts.onLog?.(m.level, m.msg);
        return;
      case 'storage':
        // review fixes: здоровье записи тома (плашка страницы «Данные демо не сохраняются»)
        storageEvents.push({ ...m, at: Date.now() });
        opts.onStorage?.(m);
        return;
      case 'fatal': {
        // до ready fatal — ответ на init (rpc); после ready (review fixes: PGlite погиб) — событие
        const p = m.id ? pendingRpc.get(m.id) : null;
        if (p) {
          pendingRpc.delete(m.id);
          p(m);
          return;
        }
        fatalEvents.push({ ...m, at: Date.now() });
        opts.onFatal?.(m);
        return;
      }
      case 'fenced':
        fencedEvents.push({ ...m, at: Date.now() });
        return;
      case 'http:start': {
        const p = pendingHttp.get(m.id);
        if (p && !p.started) {
          p.started = true;
          p.startedAt = Date.now();
          p.queuedMs = m.queuedMs;
          try {
            p.onStart?.();
          } catch {
            /* ignore */
          }
        }
        return;
      }
      case 'http:res': {
        const p = pendingHttp.get(m.id);
        if (!p) return; // отменённый запрос: ответ не ждут
        pendingHttp.delete(m.id);
        p.resolve(m);
        return;
      }
      default: {
        const p = pendingRpc.get(m?.id);
        if (p) {
          pendingRpc.delete(m.id);
          p(m);
        }
      }
    }
  });
  worker.on('error', (e) => {
    errorLogs.push(`worker error: ${e?.stack ?? e}`);
    opts.onLog?.('error', `worker error: ${e?.stack ?? e}`);
  });
  worker.on('exit', (code) => {
    exited = code;
    for (const p of pendingHttp.values()) p.resolve({ status: 0, headers: [], body: null, error: `worker exited ${code}` });
    pendingHttp.clear();
    for (const p of pendingRpc.values()) p({ ok: false, error: `worker exited ${code}` });
    pendingRpc.clear();
  });

  const rpc = (msg, timeoutMs = 60000) =>
    new Promise((resolve, reject) => {
      const id = `rpc-${++seq}`;
      const t = setTimeout(() => {
        pendingRpc.delete(id);
        reject(new Error(`rpc ${msg.type} timeout`));
      }, timeoutMs);
      pendingRpc.set(id, (m) => {
        clearTimeout(t);
        resolve(m);
      });
      worker.postMessage({ ...msg, id });
    });

  await loaded;
  const tInit = Date.now();
  const ready = await rpc(
    {
      type: 'init',
      opts: {
        storage: opts.storage ?? 'memory',
        pgliteBase: pathToFileURL(`${site}/backend/pglite/`).href,
        sku: opts.sku ?? 120,
        qrPaidAfterPolls: opts.qrPaidAfterPolls ?? 2,
        vfsExternal,
        ...(snapshotData ? { snapshotData } : {}),
        strict: opts.strict !== false,
        ...(opts.gate ? { gate: opts.gate } : {}),
        ...(opts.shim ? { shim: opts.shim } : {}),
        ...(opts.onecRetry ? { onecRetry: opts.onecRetry } : {}),
        ...(opts.initOpts ?? {}),
      },
    },
    opts.initTimeoutMs ?? 120000,
  );
  if (ready.type !== 'ready') {
    await worker.terminate();
    throw new Error(`init failed: ${ready.message ?? JSON.stringify(ready).slice(0, 2000)}`);
  }
  const initMs = Date.now() - tInit;

  /** Запрос моста. options: { headers, body (объект → JSON | Uint8Array | null), id, onStart }. */
  function api(method, url, { headers = {}, body, id, onStart } = {}) {
    const rid = id ?? crypto.randomUUID();
    const h = Object.entries(headers).filter(([, v]) => v !== undefined).map(([k, v]) => [k, String(v)]);
    let b = null;
    if (body instanceof Uint8Array) b = body.slice().buffer;
    else if (body !== undefined && body !== null) {
      b = enc.encode(JSON.stringify(body)).buffer;
      h.push(['content-type', 'application/json']);
    }
    const t = Date.now();
    return new Promise((resolve) => {
      const entry = {
        started: false,
        startedAt: 0,
        queuedMs: null,
        onStart,
        resolve: (m) => {
          const ms = Date.now() - t;
          if (m.cancelled) return resolve({ status: 0, cancelled: true, started: entry.started, ms, headers: {}, json: undefined, size: 0, magic: '' });
          const hdr = Object.fromEntries((m.headers || []).map(([k, v]) => [k.toLowerCase(), v]));
          const bytes = m.body ? new Uint8Array(m.body) : new Uint8Array(0);
          let json;
          if (/json/.test(hdr['content-type'] ?? '') && bytes.length) {
            try {
              json = JSON.parse(dec.decode(bytes));
            } catch {
              json = undefined;
            }
          }
          resolve({ status: m.status, headers: hdr, json, bytes, size: bytes.length, magic: dec.decode(bytes.subarray(0, 5)), ms, workerMs: m.workerMs, execMs: m.execMs, queuedMs: entry.queuedMs, started: entry.started, startedAt: entry.startedAt, error: m.error });
        },
      };
      pendingHttp.set(rid, entry);
      worker.postMessage({ type: 'http', id: rid, method, url, headers: h, body: b }, b ? [b] : []);
    });
  }
  /** Отмена, как у страницы: промис запроса сразу завершается { cancelled: true }, воркеру уходит http:cancel. */
  function cancel(id) {
    const p = pendingHttp.get(id);
    worker.postMessage({ type: 'http:cancel', id });
    if (p) {
      pendingHttp.delete(id);
      p.resolve({ cancelled: true });
    }
  }
  async function control(action, args) {
    const r = await rpc({ type: 'control', action, args });
    if (!r.ok) throw Object.assign(new Error(`control ${action}: ${r.error?.message ?? r.error}`), { code: r.error?.code });
    return r.data;
  }
  const data = async (type, extra = {}) => {
    const r = await rpc({ type, ...extra });
    if (r.ok === false) throw new Error(`${type}: ${r.error}`);
    return r.data;
  };
  /** Обрыв без shutdown (как закрытая вкладка / упавший процесс): том не сбрасывается. */
  async function terminate() {
    if (exited !== null) return;
    await worker.terminate();
  }
  async function close() {
    if (exited !== null) return;
    try {
      await rpc({ type: 'shutdown' }, 20000);
    } catch {
      /* ignore */
    }
    await worker.terminate();
  }
  return {
    ready,
    initMs,
    worker,
    errorLogs,
    netEvents,
    storageEvents,
    fatalEvents,
    fencedEvents,
    backendFile,
    terminate,
    mem: async ({ gc = false } = {}) => (await rpc({ type: '__mem', gc }, 20000)).data,
    exited: () => exited,
    api,
    cancel,
    control,
    rpc,
    stats: () => data('stats'),
    logs: (n = 200) => data('logs', { n }),
    reqstats: (n = 2000) => data('reqstats', { n }),
    close,
  };
}

/** Приёмка WP-B2 по итогам сценария и счётчикам бэкенда. */
export function evaluateAcceptance(summary, stats, logs) {
  const pg = stats.pg;
  const g = stats.gate.stats;
  const shimErrors = logs.filter((l) => / ERROR /.test(l) && /(pg-shim|сторож|единица работы|bridge|unhandledrejection|worker error)/.test(l));
  const crit = [];
  const add = (criterion, met, evidence) => crit.push({ criterion, met: !!met, evidence });
  add('сценарии run-full.mjs повторены: 1С-номер, PDF, QR received, CREDIT_BLOCKED, долг в лимите 201', summary.onecNumber && summary.pdfMagic === '%PDF-' && summary.qrFinal === 'received' && summary.overdueOrder === 'CREDIT_BLOCKED' && summary.withinLimitOrder === 201, `1С ${summary.onecNumber}, PDF ${summary.pdfBytes} Б ${summary.pdfMagic}, QR ${summary.qrFinal} за ${summary.qrMs} мс, просрочка ${summary.overdueOrder}, в лимите ${summary.withinLimitOrder}`);
  add('0 ответов 5xx', summary.status5xx.length === 0, `${summary.status5xx.length} из ${summary.requests}`);
  add('0 неожиданных статусов', summary.unexpected.length === 0, JSON.stringify(summary.unexpected.map((r) => `${r.name} ${r.status} ${r.code ?? ''}`)));
  add('0 ожиданий замка дольше 3 с', pg.waitsOver3s === 0 && pg.breakerRejects === 0, `waitsOver3s ${pg.waitsOver3s}, maxWait ${pg.maxWaitMs} мс, breaker ${pg.breakerRejects}`);
  add('0 ожиданий слота и удержаний дольше 3 с (сторож единиц)', g.queueWaitsOver3s === 0 && g.holdsOver3s === 0 && g.overruns === 0, `queueWaitsOver3s ${g.queueWaitsOver3s}, holdsOver3s ${g.holdsOver3s}, maxQueueWait ${g.maxQueueWaitMs} мс ${JSON.stringify(g.maxQueueWaitByKind)}, maxHold ${g.maxHoldMs} мс, overruns ${g.overruns}`);
  add('0 подсадок вне белого списка', pg.outsideWhitelist === 0, `подсадок ${pg.piggyback} (scope ${pg.piggyScope}, unit ${pg.piggyUnit}, idle ${pg.piggyIdle}); вне списка ${pg.outsideWhitelist} ${JSON.stringify(pg.outsideWhitelistList.slice(0, 5))}`);
  add('0 вложенных BEGIN из чужой единицы', pg.nestedBeginForeign === 0, `nestedBegin ${pg.nestedBegin}, foreign ${pg.nestedBeginForeign}, orphaned ${pg.orphanedNested}, BEGIN ждали чужую транзакцию ${pg.beginWaitedForTx}`);
  add('нет «savepoint … does not exist»', !logs.some((l) => /savepoint .* does not exist/i.test(l)), `в журнале ${logs.filter((l) => /does not exist/i.test(l)).length}`);
  const pm = summary.parallelMeMs ?? [];
  add('long-poll wait=25 не блокирует: параллельный GET /me < 200 мс', pm.length > 0 && Math.max(...pm) < 200, `GET /me во время long-poll: ${JSON.stringify(pm)} мс`);
  const c = summary.checks ?? {};
  add('отменённые до начала запросы сняты из очереди', c.cancelQueued?.ok, JSON.stringify(c.cancelQueued));
  add('отменённый начатый запрос не держит слот (step-up)', c.cancelRunning?.ok, JSON.stringify(c.cancelRunning));
  add('отменённый long-poll быстро завершается', c.cancelLongPoll?.ok, JSON.stringify(c.cancelLongPoll));
  add('«1С недоступна»: без пауз повторов, слот не держится секундами, сторож молчит', c.onecDown?.ok, JSON.stringify(c.onecDown));
  add('работа по таймерам pos-api — отдельными единицами (scheduler.refresh)', (g.timerUnits?.['scheduler.refresh'] ?? 0) > 0, `timerUnits ${JSON.stringify(g.timerUnits)}`);
  add('нет ERROR шима/сторожа/моста в журнале', shimErrors.length === 0, `${shimErrors.length}: ${shimErrors.slice(0, 3).join(' | ').slice(0, 600)}`);
  return crit;
}

// ---------------------------------------------------------------- CLI
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const argv = process.argv.slice(2);
  const arg = (k, d) => {
    const i = argv.indexOf(k);
    return i >= 0 ? argv[i + 1] : d;
  };
  const quiet = argv.includes('--quiet');
  const { runScenario } = await import('./scenario-run-full.mjs');
  const t = Date.now();
  const be = await startWorkerBackend({
    sku: Number(arg('--sku', 120)),
    strict: !argv.includes('--no-strict'),
    // таймер пересчёта расписаний (SyncScheduler.startRefresh) каждые 3 с вместо 60 с — единицы «timer» в прогоне
    initOpts: { schedulerOverrides: { scheduleRefreshMs: Number(arg('--refresh-ms', 3000)) } },
    onLog: (lv, m) => {
      if (!quiet) console.log(`[worker ${lv}]`, String(m).slice(0, 400));
    },
  });
  console.log(`backend ready in ${be.initMs} ms (worker start ${Date.now() - t} ms)`, JSON.stringify(be.ready.timings));
  let summary;
  let failed = false;
  try {
    summary = await runScenario(be, { log: quiet ? () => {} : console.log });
  } catch (e) {
    console.error('SCENARIO FAILED', e?.stack ?? e);
    failed = true;
  }
  const stats = await be.stats();
  const logs = await be.logs(400);
  const reqs = await be.reqstats();
  await be.close();
  if (failed) process.exit(1);
  const acceptance = evaluateAcceptance(summary, stats, logs);
  const lat = reqs.map((r) => r.ms).sort((a, b) => a - b);
  const pct = (p) => lat[Math.min(lat.length - 1, Math.floor((p / 100) * lat.length))];
  const report = {
    at: new Date().toISOString(),
    build: JSON.parse(readFileSync(`${SITE}/backend/build.json`, 'utf8')),
    initMs: be.initMs,
    timings: be.ready.timings,
    scenario: { ...summary, results: undefined },
    latency: { n: lat.length, p50: pct(50), p95: pct(95), max: lat[lat.length - 1] },
    stats: { pg: stats.pg, gate: stats.gate, waiter: stats.waiter, cancels: stats.cancels, argon2Yields: stats.argon2Yields, boss: stats.boss, onec: stats.onec, logs: stats.logs, net: stats.net, dbSize: stats.dbSize },
    warnErrorLogs: logs.filter((l) => / (ERROR|WARN) /.test(l)).slice(-60),
    acceptance,
    results: summary.results,
  };
  const out = arg('--json', null);
  if (out) {
    mkdirSync(dirname(resolve(out)), { recursive: true });
    writeFileSync(out, JSON.stringify(report, null, 1));
  }
  console.log('\n==== WP-B2 acceptance');
  for (const a of acceptance) console.log(`${a.met ? 'OK  ' : 'FAIL'} ${a.criterion}\n      ${String(a.evidence).slice(0, 500)}`);
  console.log(`latency ms: p50 ${report.latency.p50}, p95 ${report.latency.p95}, max ${report.latency.max} (n=${report.latency.n}); scenario ${summary.totalSec.toFixed(1)} s, ${summary.requests} requests; total ${((Date.now() - t) / 1000).toFixed(1)} s`);
  process.exit(acceptance.every((a) => a.met) ? 0 : 1);
}
