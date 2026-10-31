// Точка входа браузерного бэкенда веб-демо — module Web Worker `backend/backend.js` (WP-B3; plan §3.3, §3.5, §3.6).
// Настоящий pos-api (tsc → .build/pos-api-dist) + pos-worker (pg-boss на PGlite) + имитатор 1С PosFakeOnec в одном
// воркере на одном PGlite 0.3.16. Жизненный цикл: loaded → init → progress… → ready | fatal; shutdown.
//
// Протокол (structured clone; тело — передаваемый ArrayBuffer; handoff WP-S1 «Worker protocol», PROTOCOL CHANGES WP-B3):
//   страница → воркер: init {id:'init', protocol, epochKey, dbName, storage, storageFallback[], generation, pgliteBase,
//                       origin, buildId, tabId, persisted, …, opts:{…то же…}}
//                      http {id, method, url, headers:[[k,v]], body} · http:cancel {id}
//                      control {id, action, args} · flush {id, generation, reason} · shutdown {id, generation}
//                      (тесты) stats · logs {n} · reqstats {n} · dump · snapcheck (WP-B4: число строк таблиц, фото, время)
//   воркер → страница: loaded · progress {stage, pct, label?} · ready {epoch, epochKey, buildId, storage, generation,
//                       warm, features[], timings, roles, phones, code} · fatal {message, code}
//                      http:start {id, queuedMs} · http:res {id, status, headers, body, workerMs, execMs}
//                      control:res {id, ok, data | error:{code, message}} · flush:ok {id, ok, data} · shutdown:ok {id}
//                      fenced {generation, volumeGeneration} · log {level, msg} · res {id, ok, data | error}
//                      (review fixes) storage {ok, error?, failures?, kind} — запись тома не удаётся / восстановилась;
//                      fatal {code: 'pglite_aborted'} и ПОСЛЕ ready — PGlite погиб, запросы получают 503.
import { netGuard } from './shims/net-guard.mjs';
import 'reflect-metadata'; // до первого класса Nest с декораторами (payment-waiter → dist payments)
import * as gate from './alias/work-gate.mjs';
import * as pgShim from './alias/pg-shim.mjs';
import * as bossShim from './alias/pgboss-shim.mjs';
import { waiterStats } from './alias/payment-waiter.mjs';
import { onecGatewayStats } from './alias/onec-gateway.mjs';
import { transportStats } from './alias/onec-transport.mjs';
import { nobleYieldStats } from './alias/noble-yield.mjs';
import { BridgeServer } from './bridge-server.mjs';
import { DemoInitError, catchUp, catchUpState, initBackend } from './demo-init.mjs';
import { ControlError, createControl } from './demo-control.mjs';
import { HistorySeed } from './demo-seed.mjs';
import { DEMO_BUILD, LOGIN_HINTS, OTP_TEST_CODE } from './demo-config.mjs';

const PROTOCOL = 1;
/** Возможности воркера (ready.features): страница и Dart смотрят на 'http:start' (WP-F1/S1). */
const FEATURES = ['http:start', 'flush', 'fence', 'fence-tab', 'control', 'durable-response', 'durable-fail-503', 'storage-health', 'fatal-after-ready', 'storage-fallback'];
/** Задачи pg-boss, после которых том сбрасывается сразу (а не фоном): изменили оплату, заказ или возврат. */
const DURABLE_JOB_TABLES = ['payments', 'orders', 'return_requests'];
const now = () => performance.now();

// ---------------------------------------------------------------- журнал
const LOG_RING = [];
const logCounts = { error: 0, warn: 0, info: 0, debug: 0 };
const post = (m, t) => self.postMessage(m, t);
const log = (level, msg) => {
  const lv = level === 'fatal' ? 'error' : level === 'trace' ? 'debug' : level;
  logCounts[lv] = (logCounts[lv] ?? 0) + 1;
  const line = `${new Date().toISOString()} ${lv.toUpperCase()} ${String(msg).slice(0, 4000)}`;
  LOG_RING.push(line);
  if (LOG_RING.length > 600) LOG_RING.splice(0, 150);
  if (lv === 'error') console.error(line);
  else if (lv === 'warn') console.warn(line);
  if (lv === 'error') post({ type: 'log', level: lv, msg: line.slice(0, 2000) });
};
globalThis.__posDemoLog = log;

// ---------------------------------------------------------------- учёт записи в IndexedDB / OPFS (замеры WP-T2)
const io = { idbPuts: 0, idbBytes: 0, idbTx: 0, opfsWrites: 0, opfsBytes: 0, opfsFlushes: 0 };
function instrumentStorage() {
  if (typeof IDBObjectStore !== 'undefined' && !IDBObjectStore.prototype.__posPatched) {
    const proto = IDBObjectStore.prototype;
    proto.__posPatched = true;
    const put = proto.put;
    proto.put = function (value, key) {
      io.idbPuts++;
      io.idbBytes += (value?.contents?.byteLength ?? 0) + 64;
      return put.call(this, value, key);
    };
    const tx = IDBDatabase.prototype.transaction;
    IDBDatabase.prototype.transaction = function (...a) {
      io.idbTx++;
      return tx.apply(this, a);
    };
  }
  if (typeof FileSystemSyncAccessHandle !== 'undefined' && !FileSystemSyncAccessHandle.prototype.__posPatched) {
    const proto = FileSystemSyncAccessHandle.prototype;
    proto.__posPatched = true;
    const write = proto.write;
    proto.write = function (buf, opts) {
      io.opfsWrites++;
      io.opfsBytes += buf?.byteLength ?? 0;
      return write.call(this, buf, opts);
    };
    const flush = proto.flush;
    proto.flush = function () {
      io.opfsFlushes++;
      return flush.call(this);
    };
  }
}

// ---------------------------------------------------------------- состояние воркера
const S = { phase: 'loaded', init: null, be: null, bridge: null, control: null, seed: null, fenced: false, dead: null, catchUp: null, timings: {}, shutdownP: null, endHook: { flushes: 0, jobFlushes: 0, getFlushes: 0, fakeErrors: 0 } };

/**
 * Review fixes: PGlite погиб после ready (ловушка WebAssembly, abort) — сервер демо мёртв: запросы получают 503,
 * фоновые задачи останавливаются, странице — fatal (она покажет «Сервер демо остановился» с кнопками).
 */
function onPgliteDead(e) {
  if (S.dead || S.phase === 'stopping' || S.phase === 'stopped') return;
  S.dead = String(e?.message ?? e).slice(0, 500);
  const wasReady = S.phase === 'ready';
  S.phase = 'fatal';
  log('error', `PGlite остановился: ${e?.stack ?? e}`);
  try {
    S.be?.storage.stopBackground();
  } catch {
    /* ignore */
  }
  void Promise.resolve(S.be?.runtime?.stop()).catch(() => undefined);
  post({ type: 'fatal', code: 'pglite_aborted', message: 'Сервер демо остановился. Обновите страницу.', detail: S.dead, afterReady: wasReady });
}
pgShim.setFatalHandler(onPgliteDead);
const progress = (stage, pct, label) => post({ type: 'progress', stage, pct, ...(label ? { label } : {}), t: Math.round(now()) });

/** Поля init: верхний уровень (WP-S1) поверх opts (спайк/WP-B1/WP-B2 и worker-harness). */
function readInit(msg) {
  const out = { ...(msg.opts && typeof msg.opts === 'object' ? msg.opts : {}) };
  for (const [k, v] of Object.entries(msg)) if (k !== 'type' && k !== 'id' && k !== 'opts' && v !== undefined) out[k] = v;
  out.dbName ??= `optomstroy-demo-${String(out.epochKey ?? DEMO_BUILD.epochKey).replace(/[^a-z0-9-]/gi, '').slice(0, 16)}`;
  out.storage ??= 'memory';
  return out;
}

function counters() {
  const g = gate.gateSnapshot();
  const p = pgShim.shimSnapshot();
  const st = p.stats;
  return {
    gate: { active: g.active, queued: g.queued.length, released: g.released.length, started: g.stats.started, maxQueueWaitMs: g.stats.maxQueueWaitMs, maxHoldMs: g.stats.maxHoldMs, queueWaitsOver3s: g.stats.queueWaitsOver3s, holdsOver3s: g.stats.holdsOver3s, overruns: g.stats.overruns, units: g.stats.units, endHookErrors: g.stats.endHookErrors ?? 0, afterRelease: g.stats.afterRelease ?? 0, maxAfterReleaseMs: g.stats.maxAfterReleaseMs ?? 0 },
    pg: { queries: st.queries, maxWaitMs: st.maxWaitMs, waitsOver3s: st.waitsOver3s, piggyback: st.piggyback, outsideWhitelist: st.outsideWhitelist, nestedBeginForeign: st.nestedBeginForeign, breakerRejects: st.breakerRejects },
    storage: S.be?.storage ? { ...S.be.storage.stats, health: { ...S.be.storage.health } } : null,
    endHook: { ...S.endHook },
    dead: S.dead,
    bridge: S.bridge?.stats ?? null,
    onec: S.be?.overlay?.stats ?? null,
    recovery: S.timings.recovery ?? null,
    catchUp: S.catchUp ? { ...S.catchUp, receivables: catchUpState.receivables } : null,
    net: { allowed: netGuard.allowed, blocked: netGuard.blocked },
    logs: { ...logCounts },
  };
}

async function onInit(msg) {
  if (S.phase !== 'loaded') {
    post({ type: 'res', id: msg.id, ok: false, error: { code: 'ALREADY_STARTED', message: 'init уже выполнен' } });
    return;
  }
  S.phase = 'starting';
  const init = readInit(msg);
  S.init = init;
  instrumentStorage();
  const tInit = now();
  try {
    if (init.protocol !== undefined && Number(init.protocol) !== PROTOCOL) throw new DemoInitError('protocol', `протокол страницы ${init.protocol}, воркера ${PROTOCOL}`);
    const be = await initBackend(init, { post, log, progress });
    S.be = be;
    S.timings = be.timings;
    be.storage.onFenced = () => onFenced();
    S.bridge = new BridgeServer({
      handler: be.handler,
      post,
      log,
      isFenced: () => S.fenced,
      isDead: () => !!S.dead,
      // GET-ответ ждёт идущий изменяющий сброс тома и сброс своей единицы, если она изменила состояние «1С».
      durability: { mustWait: () => be.isFakeDirty() || be.storage.durablePending(), idle: () => be.storage.durableIdle() },
    });
    S.control = createControl({
      be,
      bridge: S.bridge,
      get seed() {
        return S.seed;
      },
      info: { epochKey: be.meta.epoch.epochKey, buildId: init.buildId ?? null, generation: init.generation ?? null },
      counters,
      logs: (n) => LOG_RING.slice(-n),
      log,
      onReset: () => stopBackground('reset'),
    });
    S.seed = new HistorySeed({ bridge: S.bridge, be, control: (a, b) => S.control(a, b), log }, be.seedState);
    // Конец единицы работы (work-gate): состояние имитатора 1С → demo_meta (в слоте единицы); изменяющая единица —
    // сброс тома на диск ДО ответа (мост шлёт ответ изменяющего запроса после run()), но уже ПОСЛЕ освобождения слота
    // (afterRelease, fix round 2): ожидание записи IndexedDB не задерживает другие запросы и задачи.
    // Review fixes (critic [4]):
    //  - сбой записи состояния «1С» не отменяет сброс тома (раньше исключение хука оставляло afterRelease пустым и
    //    изменяющий запрос получал «успех» без записи на диск); флаги «изменено» имитатора остаются поднятыми;
    //  - итог сброса (afterRelease) мост видит в unit.endResult и отвечает 503 вместо «успеха», если запись не удалась;
    //  - задача pg-boss, изменившая оплату, заказ или возврат (pg-shim noteWrite), сбрасывается сразу — «Оплачено»
    //    и номер «1С» не пропадают после F5 в первые 2–10 с; GET-ответы моста ждут такой сброс (durableIdle).
    gate.setUnitEndHook(async (u) => {
      if (!S.be) return undefined;
      // том перехвачен / PGlite погиб посреди изменяющей единицы: на диск она уже не попадёт — мост ответит 503
      if (S.fenced || S.dead) return u.durable ? { afterRelease: async () => (S.fenced ? { fenced: true } : { error: 'PGlite остановился' }) } : undefined;
      let changed = false;
      let fakeError = null;
      try {
        changed = await S.be.persistFake();
      } catch (e) {
        fakeError = String(e?.message ?? e);
        S.endHook.fakeErrors++;
        log('error', `состояние имитатора «1С» не сохранено (${u.label}): ${e?.stack ?? e}`);
      }
      const jobWrites = u.kind === 'job' && u.writes ? DURABLE_JOB_TABLES.filter((t) => u.writes[t]) : [];
      const flush = u.durable || (changed && u.kind !== 'job') || jobWrites.length > 0 || (fakeError && u.kind !== 'job');
      if (!flush) return undefined;
      S.endHook.flushes++;
      if (jobWrites.length) S.endHook.jobFlushes++;
      if (!u.durable && u.kind === 'http') S.endHook.getFlushes++;
      const reason = `unit:${u.kind}${jobWrites.length ? `:${jobWrites.join('+')}` : ''}`;
      return {
        afterRelease: async () => {
          if (S.fenced) return { fenced: true };
          if (S.dead) return { error: 'PGlite остановился' };
          const r = await S.be.storage.flush(reason);
          return fakeError ? { ...r, fakeError } : r;
        },
      };
    });
    S.phase = 'ready';
    be.timings.readyMs = Math.round(now() - tInit);
    progress('ready', 100);
    post({
      type: 'ready',
      id: msg.id,
      protocol: PROTOCOL,
      epoch: be.meta.epoch.epochKey,
      epochKey: be.meta.epoch.epochKey,
      backendEpochKey: DEMO_BUILD.epochKey,
      buildId: init.buildId ?? null,
      appVersion: DEMO_BUILD.appVersion,
      storage: be.storage.kind,
      generation: init.generation ?? null,
      warm: be.warm,
      features: FEATURES,
      timings: be.timings,
      roles: LOGIN_HINTS,
      phones: LOGIN_HINTS.map((h) => h.phone),
      code: OTP_TEST_CODE,
      seed: S.seed.state(),
    });
    // Догоняние расписаний — сразу после ready, единицей работы (приложение уже может слать запросы).
    // init.catchUp === false — только тесты (WP-B4: состав БД сразу после восстановления снимка; запуск — POST sync/catch-up).
    if (init.catchUp !== false) {
      gate
        .run({ kind: 'job', name: 'demo.catch-up', label: 'demo catch-up' }, () => catchUp(be.runtime, log))
        .then((r) => (S.catchUp = { at: new Date().toISOString(), jobs: r }))
        .catch((e) => log('warn', `догоняние расписаний: ${e?.stack ?? e}`));
    }
    // История заказов — в фоне, низшим приоритетом; первые запросы приложения идут раньше.
    if (S.seed.needed() && init.seed !== false) setTimeout(() => S.seed?.start(), init.seedDelayMs ?? 1500);
  } catch (e) {
    S.phase = 'fatal';
    const code = e instanceof DemoInitError ? e.code : 'init_failed';
    log('error', `init: ${e?.stack ?? e}${e?.cause ? ` (причина: ${e.cause?.message ?? e.cause})` : ''}`);
    post({ type: 'fatal', id: msg.id, code, message: e instanceof DemoInitError ? e.message : `Сервер демо не запустился: ${e?.message ?? e}`, detail: String(e?.stack ?? e).slice(0, 4000) });
  }
}

/** Том перехвачен другой вкладкой: запросы отклоняются, фоновые задачи останавливаются (запись уже запрещена). */
function onFenced() {
  if (S.fenced) return;
  S.fenced = true;
  log('warn', 'fenced: фоновые задачи остановлены, запросы отклоняются');
  void stopBackground('fenced');
}

async function stopBackground(reason) {
  try {
    S.be?.storage.stopBackground();
    // сид истории — следующий шаг не начинается (review fixes: при выходе вкладки его запрос падал на закрытой базе)
    void S.seed?.stop();
    await S.be?.runtime.stop();
  } catch (e) {
    log('warn', `остановка фоновых задач (${reason}): ${e?.message ?? e}`);
  }
  return { stopped: true, reason, wipe: 'page' };
}

function shutdown() {
  S.shutdownP ??= (async () => {
    const t = now();
    S.phase = 'stopping'; // новые запросы — 503 «Сервер демо остановлен»
    await stopBackground('shutdown');
    // начатые запросы и задачи — доработать (не дольше 1,5 с), а не уронить на закрытой базе
    const dr = await gate.drain(1500);
    if (!dr.drained) log('warn', `shutdown: не дождались единиц работы: ${dr.left.join(', ')}`);
    pgShim.expectClosed(); // дальше «PGlite is closed» — штатное закрытие, а не авария
    await S.be?.app.close().catch((e) => log('warn', `app.close: ${e?.message ?? e}`));
    // close() сверяет поколение тома перед последней записью (вкладка, у которой том забрали, не пишет).
    await S.be?.storage.close().catch((e) => log('warn', `storage.close: ${e?.message ?? e}`));
    S.phase = 'stopped';
    return { ms: Math.round(now() - t) };
  })();
  return S.shutdownP;
}

async function stats() {
  let dbSize = null;
  try {
    if (S.be) dbSize = Number((await pgShim.bossSessionLocked('demo.stats', 'pg_database_size', () => S.be.db.query('SELECT pg_database_size(current_database()) AS s'))).rows[0].s);
  } catch {
    /* ignore */
  }
  const mem = performance.memory ? { used: performance.memory.usedJSHeapSize, total: performance.memory.totalJSHeapSize } : null;
  return {
    phase: S.phase,
    io: { ...io },
    pg: { ...pgShim.shimStats, piggybackByKey: { ...pgShim.shimStats.piggybackByKey } },
    pgLock: pgShim.shimSnapshot(),
    gate: gate.gateSnapshot(),
    waiter: { ...waiterStats },
    cancels: { ...(S.bridge?.cancels ?? {}) },
    argon2Yields: nobleYieldStats.yields,
    boss: { ...bossShim.bossStats },
    onec: { calls: transportStats.calls, errors: transportStats.errors, aborted: transportStats.aborted, byPath: transportStats.byPath, byStatus: transportStats.byStatus, gateway: { ...onecGatewayStats }, overlay: S.be?.overlay?.stats ?? null },
    storage: S.be?.storage?.stats ?? null,
    bridge: S.bridge?.stats ?? null,
    seed: S.seed?.state() ?? null,
    catchUp: S.catchUp ? { ...S.catchUp, receivables: catchUpState.receivables } : null,
    net: { allowed: netGuard.allowed, blocked: netGuard.blocked, blockedLog: netGuard.blockedLog.slice(-10) },
    logs: { ...logCounts },
    dbSize,
    heap: mem,
    wasmHeapBytes: S.be?.db?.Module?.HEAPU8?.byteLength ?? null,
    timings: S.timings,
  };
}

/** WP-B4 (тесты): что лежит в БД после восстановления снимка — строки таблиц, фото, время, приглашение, аудит. */
async function snapshotCheck(db) {
  const q = (x) => `"${String(x).replace(/"/g, '""')}"`;
  const tables = (await db.query(`SELECT n.nspname AS s, c.relname AS t FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r', 'p') AND n.nspname IN ('public', 'catalog_sync') ORDER BY 1, 2`)).rows;
  const counts = {};
  for (const r of tables) counts[`${r.s}.${r.t}`] = Number((await db.query(`SELECT count(*)::bigint AS n FROM ${q(r.s)}.${q(r.t)}`)).rows[0].n);
  const images = (await db.query(`SELECT encode(checksum_sha256, 'hex') AS sha, status::text AS status, storage_key, sizes FROM product_images WHERE deleted_at IS NULL ORDER BY 1`)).rows;
  const times = (
    await db.query(`SELECT now()::text AS now,
      (SELECT min(created_at)::text FROM products) AS products_created_min, (SELECT max(updated_at)::text FROM products) AS products_updated_max,
      (SELECT min(last_success_at)::text FROM sync_state WHERE last_success_at IS NOT NULL) AS sync_success_min,
      (SELECT max(last_success_at)::text FROM sync_state) AS sync_success_max,
      (SELECT min(occurred_at)::text FROM audit_logs) AS audit_min, (SELECT max(occurred_at)::text FROM audit_logs) AS audit_max,
      (SELECT min(created_at)::text FROM users) AS users_created_min,
      (SELECT count(*)::int FROM user_invitations WHERE status = 'pending') AS invitations_pending,
      (SELECT max(expires_at)::text FROM user_invitations WHERE status = 'pending') AS invitation_expires,
      (SELECT count(*)::int FROM otp_challenges) AS otp, (SELECT count(*)::int FROM sessions) AS sessions`)
  ).rows[0];
  const audit = (await db.query(`SELECT ok, gaps FROM audit_verify_chain(0, 9223372036854775807)`)).rows[0];
  const staff = (await db.query(`SELECT u.phone_e164 AS phone, p.full_name AS name, u.status FROM users u JOIN user_profiles p ON p.user_id = u.id ORDER BY 1`)).rows;
  // Review fixes (critic [18], сверка с PostgreSQL): кто записан автором действий аудита — контекст set_config(…, true)
  // держателя транзакции не должен «перетечь» на подсаженные операторы. Счётчики по (действие, телефон автора, роль, итог).
  const auditActors = (
    await db.query(`SELECT a.action, coalesce(u.phone_e164, '—') AS actor, coalesce(a.actor_role::text, '—') AS role, a.result, count(*)::int AS n
                      FROM audit_logs a LEFT JOIN users u ON u.id = a.actor_user_id GROUP BY 1, 2, 3, 4 ORDER BY 1, 2, 3, 4`)
  ).rows;
  return { counts, images, times, audit, staff, auditActors };
}

// Диагностика из CDP (сессия воркера, WP-T2): те же данные, что сообщение stats.
globalThis.__posDemoDiag = { stats, counters, phase: () => S.phase };

const notReady = (id, type) => post({ type, id, ok: false, error: { code: S.phase === 'fatal' ? 'fatal' : 'not_ready', message: `сервер демо: ${S.phase}` } });

self.addEventListener('message', async (ev) => {
  const msg = ev.data ?? {};
  try {
    switch (msg.type) {
      case 'init':
        await onInit(msg);
        return;
      case 'http':
        if (S.phase !== 'ready') {
          const title = S.dead ? 'Сервер демо остановился. Обновите страницу.' : S.phase === 'fatal' ? 'Сервер демо не запустился' : S.phase === 'stopping' || S.phase === 'stopped' ? 'Сервер демо остановлен' : 'Сервер демо ещё запускается';
          const body = new TextEncoder().encode(JSON.stringify({ type: 'https://demo.invalid/problems/service-unavailable', title, status: 503, code: 'SERVICE_UNAVAILABLE', requestId: 'demo' })).buffer;
          post({ type: 'http:res', id: msg.id, status: 503, headers: [['content-type', 'application/problem+json; charset=utf-8']], body }, [body]);
          return;
        }
        S.bridge.handleHttp(msg);
        return;
      case 'http:cancel':
        S.bridge?.cancel(msg.id);
        return;
      case 'control': {
        if (S.phase !== 'ready') return notReady(msg.id, 'control:res');
        try {
          post({ type: 'control:res', id: msg.id, ok: true, data: await S.control(msg.action, msg.args ?? {}) });
        } catch (e) {
          const code = e instanceof ControlError ? e.code : e?.code === 'ERR_DEMO_CANCELLED' ? 'cancelled' : 'ERROR';
          if (!(e instanceof ControlError)) log('warn', `control ${msg.action}: ${e?.stack ?? e}`);
          post({ type: 'control:res', id: msg.id, ok: false, error: { code, message: String(e?.message ?? e) } });
        }
        return;
      }
      case 'flush': {
        if (!S.be || S.dead) return post({ type: 'flush:ok', id: msg.id, ok: true, data: { skipped: S.dead ? 'dead' : S.phase } });
        if (msg.generation !== undefined && S.init.generation !== undefined && msg.generation !== S.init.generation) {
          return post({ type: 'flush:ok', id: msg.id, ok: true, data: { skipped: 'generation' } });
        }
        // Конец текущей единицы может ещё сохранять состояние имитатора — сохранить и его.
        await S.be.persistFake().catch(() => undefined);
        const r = await S.be.storage.flush(`page:${msg.reason ?? 'page'}`);
        post({ type: 'flush:ok', id: msg.id, ok: true, data: r });
        return;
      }
      case 'shutdown': {
        const r = await shutdown();
        post({ type: 'shutdown:ok', id: msg.id, ok: true, data: r });
        return;
      }
      case 'stats':
        post({ type: 'res', id: msg.id, ok: true, data: await stats() });
        return;
      case 'logs':
        post({ type: 'res', id: msg.id, ok: true, data: LOG_RING.slice(-(msg.n ?? 100)) });
        return;
      case 'reqstats':
        post({ type: 'res', id: msg.id, ok: true, data: (S.bridge?.reqStats ?? []).slice(-(msg.n ?? 500)) });
        return;
      case 'dump': {
        // Тесты (worker-harness, storage 'memory'): снимок каталога данных PGlite — «перезагрузка вкладки» в Node.
        if (!S.be) return notReady(msg.id, 'res');
        await S.be.persistFake().catch(() => undefined);
        const file = await pgShim.bossSessionLocked('demo.dump', 'dumpDataDir', () => S.be.db.dumpDataDir('none'));
        const ab = await file.arrayBuffer();
        post({ type: 'res', id: msg.id, ok: true, data: ab }, [ab]);
        return;
      }
      case 'testKillPglite': {
        // Только тесты (init.testHooks): PGlite «погибает» под работающим сервером — закрывается не через shutdown.
        if (!S.init?.testHooks || !S.be) return post({ type: 'res', id: msg.id, ok: false, error: { code: 'FORBIDDEN', message: 'testHooks выключены' } });
        await S.be.db.close().catch(() => undefined);
        post({ type: 'res', id: msg.id, ok: true, data: { closed: true } });
        return;
      }
      case 'testStorage': {
        // Только тесты (init.testHooks): следующие N сбросов тома вернут {error} («браузер не дал записать»).
        if (!S.init?.testHooks || !S.be) return post({ type: 'res', id: msg.id, ok: false, error: { code: 'FORBIDDEN', message: 'testHooks выключены' } });
        S.be.storage.testFailures = Number(msg.failNext) || 0;
        post({ type: 'res', id: msg.id, ok: true, data: { failNext: S.be.storage.testFailures, health: { ...S.be.storage.health } } });
        return;
      }
      case 'snapcheck': {
        // Тесты WP-B4 (только чтение): число строк таблиц public/catalog_sync, фото, время данных снимка, аудит.
        if (!S.be) return notReady(msg.id, 'res');
        const data = await pgShim.bossSessionLocked('demo.snapcheck', 'snapshot check', () => snapshotCheck(S.be.db));
        post({ type: 'res', id: msg.id, ok: true, data });
        return;
      }
      default:
        post({ type: 'res', id: msg.id, ok: false, error: { code: 'UNKNOWN_MESSAGE', message: `неизвестное сообщение ${msg.type}` } });
    }
  } catch (e) {
    log('error', `сообщение ${msg.type}: ${e?.stack ?? e}`);
    post({ type: 'res', id: msg.id, ok: false, error: { code: 'ERROR', message: String(e?.message ?? e) } });
  }
});
self.addEventListener('unhandledrejection', (ev) => {
  log('error', `unhandledrejection: ${ev.reason?.stack ?? ev.reason}`);
  pgShim.reportPgliteError(ev.reason);
});
self.addEventListener('error', (ev) => {
  log('error', `worker error: ${ev.message} ${ev.error?.stack ?? ''}`);
  pgShim.reportPgliteError(ev.error ?? { name: /RuntimeError/.test(String(ev.message)) ? 'RuntimeError' : 'Error', message: ev.message });
});
post({ type: 'loaded', protocol: PROTOCOL, t: Math.round(now()) });
