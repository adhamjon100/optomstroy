// «Единица работы» браузерного бэкенда (WP-B2, plan §3.4 правило 1). PGlite — одна сессия PostgreSQL, поэтому
// входящие в бэкенд действия выполняются ПО ОДНОМУ: запрос моста (http), команда панели (panel), обработчик задачи
// pg-boss (job), шаги сида (seed), перечитывание статуса для long-poll (poll). Очередь с приоритетами:
//   resume (продолжение отпущенной единицы) → app (http, poll) → panel → job → seed;
// ожидание поднимает приоритет на один класс за каждые AGING_MS (задачи pg-boss не голодают при частых запросах).
//
// Единица заканчивается, когда её функция завершилась и пул «затих»: нет держателя замка pg-shim, нет ожидающих и
// нет операторов в полёте quietMs подряд, но не дольше quietMaxMs. Так продолжения «после ответа» (void …, .catch
// без await — см. continuations-audit.md) успевают выполниться внутри своей единицы.
//
// Отмена (critic «отменённые запросы»): ещё не начатая единица снимается из очереди (run() отклоняется с
// ERR_DEMO_CANCELLED); начатая получает сигнал отмены (unit.signal, unit.onCancel), и если её функция не
// завершилась за cancelGraceMs, слот освобождается («отсоединение»): код запроса дорабатывает сам, а следующая
// единица не ждёт.
//
// Long-poll и подобные ожидания: releaseWhile(unit, fn) отпускает слот на время fn и затем снова занимает его с
// приоритетом resume (payment-waiter.mjs). Время в отпущенном состоянии не считается удержанием.
//
// Сторож (правило 5): ожидание в очереди дольше watchdogMs и удержание слота дольше watchdogMs — ERROR в журнале
// (в тестах — падение прогона); удержание дольше overrunMs — слот принудительно освобождается (страховка от
// взаимоблокировки на уровне единиц).
//
// Чья единица (для pg-shim): у каждой единицы своя именованная рамка `__posUnit_<id>`; если асинхронный стек V8
// оператора проходит через неё, единица известна точно (задачи pg-boss, сид, панель). У http-запросов цепочка
// await обрывается в express/RxJS, там действует «единица по времени»: активна ровно одна.

const now = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());
const log = (level, msg) => globalThis.__posDemoLog?.(level, msg);

export const PRIORITY = Object.freeze({ resume: -1, app: 0, panel: 1, job: 2, seed: 3 });
const KIND_PRIORITY = { http: PRIORITY.app, poll: PRIORITY.app, panel: PRIORITY.panel, job: PRIORITY.job, seed: PRIORITY.seed };

export const gateConfig = {
  /** Окно затихания пула после функции единицы (мс подряд без активности pg-shim). */
  quietMs: 15,
  /** Предел окна затихания. */
  quietMaxMs: 200,
  /** Шаг проверки затихания. */
  quietPollMs: 4,
  /** Сторож: ожидание в очереди (запрос приложения, панель) и удержание слота дольше — ERROR. */
  watchdogMs: 3000,
  /** Сторож очереди для задач pg-boss и сида (низший приоритет: ждать запросы приложения — норма). */
  jobQueueWatchdogMs: 15000,
  /** Удержание дольше — слот принудительно освобождается (ERROR, единица «overrun»). */
  overrunMs: 30000,
  /** Сколько ждать завершения отменённой начатой единицы, прежде чем отсоединить её. */
  cancelGraceMs: 250,
  /** Шаг повышения приоритета ожидающей единицы. */
  agingMs: 1000,
};

export function configureGate(patch = {}) {
  for (const [k, v] of Object.entries(patch)) if (k in gateConfig && Number.isFinite(v)) gateConfig[k] = v;
  return { ...gateConfig };
}

export const gateStats = {
  units: {},
  started: 0,
  finished: 0,
  failed: 0,
  maxQueueWaitMs: 0,
  maxQueueWaitByKind: {},
  queueWaitsOver1s: 0,
  queueWaitsOver3s: 0,
  maxHoldMs: 0,
  holdsOver1s: 0,
  holdsOver3s: 0,
  overruns: 0,
  cancelledQueued: 0,
  cancelledRunning: 0,
  cancelledReleased: 0,
  cancelDetached: 0,
  releases: 0,
  releaseRefusedTx: 0,
  resumes: 0,
  inline: 0,
  timerUnits: {},
  quietWaits: 0,
  quietTimeouts: 0,
  maxQuietMs: 0,
  /** Fix round 2: работы конца единицы после освобождения слота (сброс тома на диск) и их наибольшая длительность. */
  afterRelease: 0,
  maxAfterReleaseMs: 0,
  slowUnits: [],
  watchdog: [],
};
globalThis.__posGateStats = gateStats;

class CancelledError extends Error {
  constructor(unit) {
    super(`единица работы отменена до начала: ${unit.label}`);
    this.name = 'CancelledError';
    this.code = 'ERR_DEMO_CANCELLED';
  }
}
export { CancelledError };

// WP-B3: «конец единицы работы» — вызывается после окна затихания, ПОКА единица ещё держит слот (до освобождения):
// здесь точка входа сохраняет состояние имитатора 1С в demo_meta — без чужих операторов между изменением и записью.
// Fix round 2: хук может вернуть { afterRelease: () => Promise } — это выполняется ПОСЛЕ освобождения слота, но до
// того, как run() вернёт результат (мост шлёт ответ изменяющего запроса только после него). Так сброс тома на диск
// (ожидание записи IndexedDB, которое под нагрузкой бывает секундами) не держит слот: следующие единицы работают,
// а ответ всё равно уходит только после записи (critic [4]).
let unitEndHook = null;
export function setUnitEndHook(fn) {
  unitEndHook = typeof fn === 'function' ? fn : null;
}

let seq = 0;
const queue = []; // ожидающие слота: { unit, resolve, reject, priority, at }
const live = new Map(); // id → unit (в очереди, выполняется, отпущена)
const byKey = new Map(); // ключ (id запроса моста) → unit
let active = null; // единица, держащая слот (выполняется или в окне затихания)
let probe = () => ({ busy: false, lastActivityAt: 0, txUnit: null });

/** pg-shim сообщает о своей активности: { busy, lastActivityAt, txUnit — единица держателя транзакции | null }. */
export function setActivityProbe(fn) {
  probe = fn;
}

// «Идёт вычисление» (Argon2 отдаёт цикл событий каждые ~10 мс, alias/noble-yield.mjs): держатель транзакции,
// который хэширует PIN, не простаивает — pg-shim не считает его ожидающим подсадки (правило idle).
let busyAt = -Infinity;
export function markBusy() {
  busyAt = now();
}
export function lastBusyAt() {
  return busyAt;
}

function makeMarker(id) {
  const name = `__posUnit_${id}`;
  // Имя функции видно в асинхронном стеке V8 (CallSite.getFunctionName), в том числе у кадров `async`.
  const holder = {
    async [name](fn, unit) {
      return await fn(unit);
    },
  };
  return holder[name];
}
const MARKER_RE = /^__posUnit_(\d+)$/;

/** Единица из асинхронного стека (массив { name } из pg-shim captureSites); null — не определена. */
export function unitIdFromSites(sites) {
  if (!sites) return null;
  for (const f of sites) {
    const m = f.name && MARKER_RE.exec(f.name);
    if (m) return Number(m[1]);
  }
  return null;
}

/** Единица, держащая слот сейчас (выполняется или в окне затихания), или null. */
export function activeUnit() {
  return active;
}

/**
 * Review fixes (сохранность фоновых изменений): pg-shim отмечает у активной единицы изменяющий оператор таблицы с
 * видимым заказчику состоянием (оплата, номер «1С», статус заказа/возврата). Точка входа по этой отметке делает
 * задачу pg-boss «durable»: её изменения сбрасываются на диск сразу, а не фоновым сбросом через 2–10 с.
 */
export function noteWrite(table) {
  const u = active;
  if (!u) return;
  (u.writes ??= {})[table] = (u.writes[table] ?? 0) + 1;
}
export function activeUnitId() {
  return active ? active.id : null;
}
export function getUnit(id) {
  return live.get(id) ?? null;
}
/** Найти живую единицу по условию (например, long-poll конкретного платежа). */
export function findUnit(pred) {
  for (const u of live.values()) if (pred(u)) return u;
  return null;
}

function effPriority(e, t) {
  if (e.priority < 0) return e.priority;
  return e.priority - Math.floor((t - e.at) / gateConfig.agingMs);
}

function pump() {
  if (active || queue.length === 0) return;
  const t = now();
  let best = 0;
  for (let i = 1; i < queue.length; i++) {
    const a = queue[i];
    const b = queue[best];
    const pa = effPriority(a, t);
    const pb = effPriority(b, t);
    if (pa < pb || (pa === pb && a.at < b.at)) best = i;
  }
  const [e] = queue.splice(best, 1);
  grant(e, t);
}

function grant(e, t) {
  const u = e.unit;
  active = u;
  const waited = t - e.at;
  if (e.timer) clearTimeout(e.timer);
  if (!e.resume) {
    u.queueWaitMs = waited;
    gateStats.maxQueueWaitMs = Math.max(gateStats.maxQueueWaitMs, Math.round(waited));
    gateStats.maxQueueWaitByKind[u.kind] = Math.max(gateStats.maxQueueWaitByKind[u.kind] ?? 0, Math.round(waited));
    if (waited > 1000) gateStats.queueWaitsOver1s++;
  }
  u.state = 'running';
  u.heldSince = t;
  armHoldWatch(u);
  e.resolve();
}

function enqueue(u, priority, resume = false) {
  return new Promise((resolve, reject) => {
    const e = { unit: u, resolve, reject, priority, at: now(), resume, timer: null };
    u.queued = e;
    queue.push(e);
    // Сторож очереди: запрос приложения или команда панели дольше watchdogMs в очереди — ERROR (пользователь ждёт);
    // задача pg-boss или сид — дольше jobQueueWatchdogMs (они нарочно пропускают запросы приложения вперёд).
    const limit = priority >= PRIORITY.job ? gateConfig.jobQueueWatchdogMs : gateConfig.watchdogMs;
    e.timer = setTimeout(() => {
      if (!queue.includes(e)) return;
      gateStats.queueWaitsOver3s++;
      const h = active;
      const rec = { what: 'queue-wait', unit: u.label, kind: u.kind, ms: Math.round(now() - e.at), holder: h ? h.label : null, holderMs: h ? Math.round(now() - h.heldSince) : null };
      if (gateStats.watchdog.length < 50) gateStats.watchdog.push(rec);
      log('error', `сторож: единица работы ждёт слот ${rec.ms} мс: ${u.label}; держит ${rec.holder ?? '—'} (${rec.holderMs ?? '—'} мс)`);
    }, limit);
    e.timer.unref?.();
    pump();
  });
}

function armHoldWatch(u) {
  disarmHoldWatch(u);
  u.watchTimer = setTimeout(() => {
    if (active !== u) return;
    gateStats.holdsOver3s++;
    const rec = { what: 'hold', unit: u.label, kind: u.kind, ms: Math.round(now() - u.heldSince), waiting: queue.length };
    if (gateStats.watchdog.length < 50) gateStats.watchdog.push(rec);
    log('error', `сторож: единица работы держит слот ${rec.ms} мс: ${u.label} (в очереди ${rec.waiting})`);
  }, gateConfig.watchdogMs);
  u.watchTimer.unref?.();
  u.overrunTimer = setTimeout(() => {
    if (active !== u) return;
    gateStats.overruns++;
    log('error', `сторож: единица работы ${u.label} держит слот дольше ${gateConfig.overrunMs} мс — слот освобождён принудительно`);
    u.detached = true;
    freeSlot(u);
  }, gateConfig.overrunMs);
  u.overrunTimer.unref?.();
}
function disarmHoldWatch(u) {
  if (u.watchTimer) clearTimeout(u.watchTimer);
  if (u.overrunTimer) clearTimeout(u.overrunTimer);
  u.watchTimer = null;
  u.overrunTimer = null;
}

/** Учесть удержание слота и освободить его (следующая единица из очереди). */
function freeSlot(u) {
  if (active !== u) return;
  disarmHoldWatch(u);
  const held = now() - u.heldSince;
  u.holdMs += held;
  active = null;
  pump();
}

async function quietWindow() {
  const t0 = now();
  let polled = false;
  for (;;) {
    const a = probe();
    const t = now();
    if (!a.busy && t - a.lastActivityAt >= gateConfig.quietMs) break;
    if (t - t0 >= gateConfig.quietMaxMs) {
      gateStats.quietTimeouts++;
      break;
    }
    polled = true;
    const left = a.busy ? gateConfig.quietPollMs : Math.max(1, Math.min(gateConfig.quietPollMs, gateConfig.quietMs - (t - a.lastActivityAt)));
    await new Promise((r) => setTimeout(r, left));
  }
  const ms = now() - t0;
  if (polled) gateStats.quietWaits++;
  gateStats.maxQuietMs = Math.max(gateStats.maxQuietMs, Math.round(ms));
}

/**
 * Выполнить fn(unit) как единицу работы.
 * spec: { kind: 'http'|'poll'|'panel'|'job'|'seed', name, label?, key?, priority?, onStart?, inline? }
 *   key — внешний идентификатор (id запроса моста) для cancel(key);
 *   onStart — вызывается, когда единица получила слот (мост шлёт `http:start` для таймаутов Dio);
 *   inline — выполнить сразу, без очереди (вложенный вызов изнутри активной единицы).
 */
export function run(spec, fn) {
  const kind = spec.kind ?? 'job';
  // Вложенный вызов изнутри активной единицы: очередь дала бы взаимоблокировку — выполнить на месте.
  if (spec.inline || (active && spec.parent === active.id)) {
    gateStats.inline++;
    return Promise.resolve().then(() => fn(active));
  }
  const id = ++seq;
  const ac = new AbortController();
  const u = {
    id,
    kind,
    name: spec.name ?? kind,
    label: spec.label ?? `${kind} ${spec.name ?? ''}`.trim(),
    key: spec.key ?? null,
    /** WP-B3: изменяющая единица — сброс PGlite на диск в конце единицы (setUnitEndHook). */
    durable: !!spec.durable,
    meta: spec.meta ?? null,
    /** Review fixes: изменяющие операторы единицы по таблицам с видимым заказчику состоянием (pg-shim noteWrite). */
    writes: null,
    /** Review fixes: итог конца единицы — сбой хука и результат afterRelease (сброс тома на диск). */
    endHookError: null,
    endResult: null,
    state: 'queued',
    priority: spec.priority ?? KIND_PRIORITY[kind] ?? PRIORITY.job,
    enqueuedAt: now(),
    heldSince: 0,
    holdMs: 0,
    queueWaitMs: 0,
    cancelled: false,
    detached: false,
    signal: ac.signal,
    abort: ac,
    cancelHooks: [],
    onCancel(cb) {
      if (u.cancelled) queueMicrotask(cb);
      else u.cancelHooks.push(cb);
    },
    marker: makeMarker(id),
  };
  live.set(id, u);
  if (u.key !== null) byKey.set(u.key, u);
  gateStats.units[kind] = (gateStats.units[kind] ?? 0) + 1;

  const finish = () => {
    live.delete(id);
    if (u.key !== null && byKey.get(u.key) === u) byKey.delete(u.key);
    u.state = 'done';
  };
  return (async () => {
    try {
      await enqueue(u, u.priority);
    } catch (e) {
      finish();
      throw e;
    }
    gateStats.started++;
    try {
      spec.onStart?.(u);
    } catch {
      /* onStart — уведомление, его сбой не меняет выполнение */
    }
    let result;
    let error;
    let failed = false;
    try {
      result = await u.marker(fn, u);
    } catch (e) {
      failed = true;
      error = e;
    }
    // Функция завершилась: окно затихания — только если единица ещё держит слот (не отсоединена/не отпущена).
    if (active === u && !u.detached) {
      u.state = 'quiet';
      await quietWindow();
    }
    let afterRelease = null;
    if (unitEndHook && active === u && !u.detached) {
      try {
        const r = await u.marker(unitEndHook, u);
        if (r && typeof r.afterRelease === 'function') afterRelease = r.afterRelease;
      } catch (e) {
        // Review fixes: сбой хука виден вызывающему (мост отвечает 503 на изменяющий запрос, а не «успех»).
        u.endHookError = String(e?.message ?? e);
        gateStats.endHookErrors = (gateStats.endHookErrors ?? 0) + 1;
        log('error', `единица работы ${u.label}: конец единицы (сохранение/сброс на диск): ${e?.stack ?? e}`);
      }
    }
    const hold = u.holdMs + (active === u ? now() - u.heldSince : 0);
    freeSlot(u);
    gateStats.maxHoldMs = Math.max(gateStats.maxHoldMs, Math.round(hold));
    if (hold > 1000) {
      gateStats.holdsOver1s++;
      if (gateStats.slowUnits.length < 40) gateStats.slowUnits.push({ unit: u.label, holdMs: Math.round(hold), queueWaitMs: Math.round(u.queueWaitMs) });
    }
    finish();
    if (afterRelease) {
      // Слот уже свободен (следующая единица могла начаться); результат единицы — после afterRelease.
      // Review fixes: итог afterRelease (сброс тома: { ms } | { error } | { fenced } …) — в u.endResult: мост по нему
      // решает, можно ли отдать странице «успех» изменяющего запроса (critic [4]).
      const ta = now();
      try {
        u.endResult = (await afterRelease()) ?? null;
      } catch (e) {
        u.endResult = { error: String(e?.message ?? e) };
        gateStats.endHookErrors = (gateStats.endHookErrors ?? 0) + 1;
        log('error', `единица работы ${u.label}: после освобождения слота (сброс на диск): ${e?.stack ?? e}`);
      }
      const d = now() - ta;
      gateStats.afterRelease = (gateStats.afterRelease ?? 0) + 1;
      gateStats.maxAfterReleaseMs = Math.max(gateStats.maxAfterReleaseMs ?? 0, Math.round(d));
    }
    if (failed) {
      gateStats.failed++;
      throw error;
    }
    gateStats.finished++;
    return result;
  })();
}

/** Асинхронный стек вызывающего уже внутри активной единицы (её рамка `__posUnit_<id>` видна)? Только V8. */
function calledFromActive() {
  if (!active) return false;
  const prev = Error.prepareStackTrace;
  const prevLimit = Error.stackTraceLimit;
  try {
    Error.stackTraceLimit = 60;
    Error.prepareStackTrace = (_e, s) => s;
    const o = {};
    Error.captureStackTrace(o, calledFromActive);
    const sites = Array.isArray(o.stack) ? o.stack.map((c) => ({ name: c.getFunctionName?.() ?? null })) : null;
    return unitIdFromSites(sites) === active.id;
  } catch {
    return false;
  } finally {
    Error.prepareStackTrace = prev;
    Error.stackTraceLimit = prevLimit;
  }
}

/**
 * Работа по таймеру pos-api (не продолжение запроса) — отдельной единицей (continuations-audit.md). Если вызов
 * пришёл изнутри активной единицы (по асинхронному стеку), выполняется на месте: очередь дала бы взаимоблокировку.
 */
export function runTimerUnit(name, fn) {
  if (calledFromActive()) {
    gateStats.inline++;
    return Promise.resolve().then(fn);
  }
  gateStats.timerUnits[name] = (gateStats.timerUnits[name] ?? 0) + 1;
  return run({ kind: 'job', name, label: `timer ${name}` }, () => fn());
}

/**
 * Отменить единицу по ключу (id запроса моста). Возвращает 'queued' (снята из очереди), 'running' (сигнал отмены,
 * отсоединение через cancelGraceMs), 'released' (сигнал отмены отпущенной единице) или 'unknown'.
 */
export function cancel(key) {
  const u = byKey.get(key);
  if (!u) return 'unknown';
  if (u.cancelled) return u.state;
  u.cancelled = true;
  if (u.state === 'queued' && u.queued && queue.includes(u.queued)) {
    const e = u.queued;
    queue.splice(queue.indexOf(e), 1);
    if (e.timer) clearTimeout(e.timer);
    gateStats.cancelledQueued++;
    fireCancel(u);
    e.reject(new CancelledError(u));
    return 'queued';
  }
  const st = u.state;
  if (st === 'released') gateStats.cancelledReleased++;
  else gateStats.cancelledRunning++;
  fireCancel(u);
  if (st === 'running' || st === 'quiet') {
    const t = setTimeout(() => {
      if (active === u && !u.detached) {
        gateStats.cancelDetached++;
        u.detached = true;
        log('warn', `единица работы ${u.label}: отменена и не завершилась за ${gateConfig.cancelGraceMs} мс — слот освобождён`);
        freeSlot(u);
      }
    }, gateConfig.cancelGraceMs);
    t.unref?.();
  }
  return st;
}
function fireCancel(u) {
  try {
    u.abort.abort();
  } catch {
    /* ignore */
  }
  const hooks = u.cancelHooks.splice(0);
  for (const cb of hooks) {
    try {
      cb();
    } catch (e) {
      log('warn', `единица работы ${u.label}: обработчик отмены: ${e?.message ?? e}`);
    }
  }
}

/**
 * Отпустить слот единицы u на время fn и снова занять его (приоритет resume). Для ожиданий, которые сами не
 * работают с БД (long-poll): другие единицы выполняются, пока fn ждёт. Если u не держит слот (отсоединена,
 * отменена) — fn выполняется как есть.
 */
export async function releaseWhile(u, fn) {
  if (!u || active !== u || u.detached) return fn();
  // Единица с открытой транзакцией слот не отпускает: следующая единица ждала бы её замок, а эта — слот
  // (взаимоблокировка). long-poll транзакцию не держит; отказ — признак ошибки вызывающего.
  if (probe().txUnit === u.id) {
    gateStats.releaseRefusedTx++;
    log('warn', `единица работы ${u.label}: releaseWhile при открытой транзакции — слот не отпускается`);
    return fn();
  }
  gateStats.releases++;
  u.state = 'released';
  freeSlot(u);
  try {
    return await fn();
  } finally {
    if (u.detached || u.state === 'done') {
      /* слот не возвращается */
    } else {
      gateStats.resumes++;
      await enqueue(u, PRIORITY.resume, true);
      u.state = 'running';
    }
  }
}

/**
 * Review fixes (smoke «замороженная вкладка»): дождаться, пока не останется работающих единиц (в очереди, в слоте,
 * отсоединённых после отмены), не дольше timeoutMs — перед закрытием PGlite при shutdown, чтобы запрос, уже
 * начатый вкладкой, которая уходит, не упал на закрытой базе (500 и ERROR в консоли). Отпущенные (long-poll) не ждём.
 */
export async function drain(timeoutMs = 1000) {
  const end = now() + timeoutMs;
  const busy = () => queue.length > 0 || [...live.values()].some((u) => u.state !== 'released' && u.state !== 'done');
  while (busy() && now() < end) await new Promise((r) => setTimeout(r, 10));
  return { drained: !busy(), left: [...live.values()].filter((u) => u.state !== 'done').map((u) => `${u.label} (${u.state})`).slice(0, 10) };
}

/** Снимок для /__demo/state и тестов. */
export function gateSnapshot() {
  const t = now();
  return {
    config: { ...gateConfig },
    active: active ? { id: active.id, label: active.label, kind: active.kind, state: active.state, heldMs: Math.round(t - active.heldSince) } : null,
    queued: queue.map((e) => ({ id: e.unit.id, label: e.unit.label, kind: e.unit.kind, priority: e.priority, waitMs: Math.round(t - e.at), resume: e.resume })),
    released: [...live.values()].filter((u) => u.state === 'released').map((u) => ({ id: u.id, label: u.label })),
    stats: { ...gateStats, units: { ...gateStats.units }, maxQueueWaitByKind: { ...gateStats.maxQueueWaitByKind }, timerUnits: { ...gateStats.timerUnits }, slowUnits: gateStats.slowUnits.slice(), watchdog: gateStats.watchdog.slice() },
  };
}

/** Только для тестов: сбросить счётчики (единицы в работе не трогаются). */
export function resetGateStats() {
  for (const [k, v] of Object.entries(gateStats)) {
    if (Array.isArray(v)) v.length = 0;
    else if (typeof v === 'number') gateStats[k] = 0;
    else if (v && typeof v === 'object') for (const kk of Object.keys(v)) delete v[kk];
  }
}
