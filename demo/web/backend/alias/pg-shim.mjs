// Шим модуля `pg` поверх одного экземпляра PGlite (WP-B2; plan §3.3, §3.4 правила 2–5). Семантика node-postgres:
// значения параметров готовит pg/lib/utils.prepareValue, разбор результатов — pg-types (или `types` конфига
// запроса, как делает drizzle), multi-statement без параметров — массив результатов, LISTEN/UNLISTEN — PGlite.listen.
//
// PGlite — ОДНО соединение (одна сессия). Замок сессии: BEGIN клиента держит его до COMMIT/ROLLBACK/release();
// оператор вне транзакции берёт его на время оператора. Обращение к пулу ИЗНУТРИ открытой транзакции (в настоящем
// PG — второе соединение) здесь дало бы взаимоблокировку, поэтому такой оператор «подсаживается» в транзакцию
// держателя под SAVEPOINT. Кто может подсесть (решение — piggyDecision):
//   scope — только у «сырых» транзакций (client.query('BEGIN')): асинхронный стек V8 оператора проходит через
//           функцию, открывшую транзакцию (та же ветвь Promise.all, та же единица работы): оператор выполняется
//           внутри неё, и она его ждёт. Подсаживается сразу; вложенный BEGIN из вызванной ею функции — SAVEPOINT.
//           У транзакций drizzle области нет: их асинхронная цепочка обрывается внутри drizzle (см. scopeOfBegin).
//           Исключение — BEGIN транзакции drizzle, открытой из колбэка транзакции drizzle держателя (рамка
//           `__posDtx_<id>` в стеке вызова db.transaction(), attachDrizzleScope): сразу SAVEPOINT (fix round 1).
//   unit  — транзакция принадлежит АКТИВНОЙ единице работы (work-gate.mjs), держатель простаивает, оператор не из
//           чужой единицы (по стеку): асинхронная связь потеряна (drizzle, общий промис кэша и т. п.). Сразу — если
//           ключ оператора в белом списке с режимом unit, иначе после idleMs простоя («вне белого списка»). BEGIN —
//           только после nestedBeginIdleMs простоя (вложенная транзакция пула внутри колбэка транзакции).
//   idle  — держатель (не активной единицы: отсоединённой, таймера, продолжения) простаивает idleForeignMs и
//           оператор ждёт столько же — страховка от взаимоблокировки (с предупреждением, если ключа нет в белом
//           списке с режимом idle). BEGIN по idle не подсаживается никогда.
// Простой считается от последнего оператора держателя и от последней уступки вычисления (Argon2 хэширует PIN
// внутри транзакции step-up — такой держатель не простаивает, alias/noble-yield.mjs).
// Никогда не подсаживаются: BEGIN чужой единицы (так в спайке возникала ошибка «savepoint pgshim_tx_N does not
// exist»: BEGIN AdminRateLimitInterceptor другого запроса сел в чужую транзакцию по таймауту простоя), оператор из
// чужой единицы (по стеку), внутренние операторы pg-boss вне области, блоки pg-boss BEGIN…COMMIT, LISTEN/UNLISTEN.
//
// Разбор значений — как у node-postgres (pg-types 2.2.0 или `types` запроса drizzle), таблицей-объектом для PGlite
// (rawParsers; fix round 1: int8 → строка, bytea → Buffer, interval → postgres-interval, `types` drizzle действует).
//
// Белый список (piggyback-allow.json): ключ «глагол таблица» (fingerprint) и разрешённые режимы. Подсадка вне
// списка считается (shimStats.outsideWhitelist) и пишется в журнал: WARN, в строгом режиме тестов — ERROR.
//
// Сохранность сессии: подсаженный SAVEPOINT-блок и операторы держателя не перемежаются (hostRun). Вложенная
// транзакция (SAVEPOINT pgshim_tx_N) «сиротеет», если держатель завершил транзакцию или откатил/освободил более
// ранний SAVEPOINT: её операторы получают ошибку ERR_DEMO_TX_ORPHANED, а RELEASE/ROLLBACK TO её точки сохранения
// в сессию не уходят. Поэтому «savepoint … does not exist» из-за шима невозможна.
//
// Сторож: ожидание замка дольше watchdogMs — ERROR с SQL держателя и ожидающего; дольше breakerMs — ожидающий
// оператор отклоняется (ERR_DEMO_LOCK_TIMEOUT), чтобы взаимоблокировка не стала вечной.
import { EventEmitter } from 'node:events';
import pgTypesMod from 'nm:pg-types/index.js';
import pgUtils from 'nm:pg/lib/utils.js';
import ALLOW_LIST from './piggyback-allow.json';
import { activeUnitId, getUnit, lastBusyAt, noteWrite, setActivityProbe, unitIdFromSites } from './work-gate.mjs';

const pgTypes = pgTypesMod;
const { prepareValue } = pgUtils;
const now = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());
const HOST_GONE = Symbol('pg-shim.host-gone');

export const shimConfig = {
  /** Простой держателя активной единицы (мс), после которого возможна подсадка unit вне белого списка. */
  idleMs: 100,
  /** Простой держателя НЕ активной единицы (отсоединённой, таймера, продолжения) для подсадки idle. */
  idleForeignMs: 300,
  /** Простой транзакции активной единицы, после которого BEGIN той же единицы без области становится SAVEPOINT. */
  nestedBeginIdleMs: 1000,
  /** Ожидание замка дольше — ERROR (сторож). */
  watchdogMs: 3000,
  /** Ожидание замка дольше — оператор отклоняется (ERR_DEMO_LOCK_TIMEOUT). */
  breakerMs: 20000,
  /** Строгий режим (тесты): подсадка вне белого списка — ERROR вместо WARN. */
  strict: false,
  /** Период перепроверки ожидающих. */
  recheckMs: 10,
  /** Отладка областей транзакций (тесты/разбор): стек BEGIN и совпавший кадр подсадки scope в shimStats.scopeDebug. */
  debugScopes: false,
};
export function configureShim(patch = {}) {
  for (const [k, v] of Object.entries(patch)) if (k in shimConfig) shimConfig[k] = v;
  return { ...shimConfig };
}

const state = { db: null };
export const shimStats = {
  queries: 0,
  errors: 0,
  tx: 0,
  maxTxMs: 0,
  longTx: [],
  waits: 0,
  maxWaitMs: 0,
  waitsOver1s: 0,
  waitsOver3s: 0,
  breakerRejects: 0,
  longWaits: [],
  slowWaits: [],
  piggyback: 0,
  piggyScope: 0,
  piggyUnit: 0,
  piggyIdle: 0,
  piggyBoss: 0,
  piggybackByKey: {},
  outsideWhitelist: 0,
  outsideWhitelistList: [],
  piggyDetails: [],
  scopeDebug: [],
  txByScope: { drizzle: 0, raw: 0, none: 0 },
  nestedBegin: 0,
  nestedBeginForeign: 0,
  beginWaitedForTx: 0,
  foreignUnitWaits: 0,
  orphanedNested: 0,
  orphanedStatements: 0,
  hostGoneRetries: 0,
  stackCaptures: 0,
  stackUnavailable: 0,
  poolBegin: 0,
  /** Вызовы db.transaction() изнутри колбэка открытой транзакции drizzle (рамка __posDtx_<id> в стеке). */
  dtxNestedCalls: 0,
  /** Их BEGIN, ставшие SAVEPOINT в транзакции держателя по области (без ожидания nestedBeginIdleMs). */
  dtxNestedBegin: 0,
};
globalThis.__posPgShimStats = shimStats;

export function attachPglite(db) {
  state.db = db;
  resetParserCache();
  // Парсеры массивов PGlite (refreshArrayTypes после новых типов) входят в набор OID таблицы парсеров.
  if (db && typeof db.refreshArrayTypes === 'function' && !db.__posShimWrapped) {
    const orig = db.refreshArrayTypes.bind(db);
    db.refreshArrayTypes = async (...a) => {
      const r = await orig(...a);
      resetParserCache();
      return r;
    };
    db.__posShimWrapped = true;
  }
}
const short = (t) => String(t).replace(/\s+/g, ' ').trim().slice(0, 160);
const log = (level, msg) => globalThis.__posDemoLog?.(level, msg);

// ---------------------------------------------------------------- ключ оператора для белого списка
/**
 * «глагол таблица» верхнего уровня: `select orders`, `insert sync_runs`, `update sync_node_state`,
 * `insert pgboss.job`. FROM ищется вне скобок (подзапросы в списке полей не мешают). Без таблицы — только глагол.
 */
export function fingerprint(text) {
  const s = String(text)
    .replace(/--[^\n]*/g, ' ')
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/'(?:[^']|'')*'/g, "''")
    .replace(/\s+/g, ' ')
    .trim()
    .toLowerCase();
  const verb = /^([a-z]+)/.exec(s)?.[1] ?? '?';
  const ident = /^(?:only )?("?[a-z_][a-z0-9_$]*"?(?:\."?[a-z_][a-z0-9_$]*"?)?)/;
  const after = (re) => {
    const m = re.exec(s);
    if (!m) return null;
    return ident.exec(s.slice(m.index + m[0].length))?.[1] ?? null;
  };
  let table = null;
  if (verb === 'insert') table = after(/^insert into /);
  else if (verb === 'update') table = after(/^update /);
  else if (verb === 'delete') table = after(/^delete from /);
  else if (verb === 'select' || verb === 'with') {
    // FROM на нулевом уровне скобок
    let depth = 0;
    for (let i = 0; i < s.length; i++) {
      const c = s[i];
      if (c === '(') depth++;
      else if (c === ')') depth = Math.max(0, depth - 1);
      else if (depth === 0 && c === ' ' && s.startsWith(' from ', i)) {
        table = ident.exec(s.slice(i + 6))?.[1] ?? null;
        if (table) break;
      }
    }
  }
  return table ? `${verb} ${table.replace(/"/g, '')}` : verb;
}

const ALLOW = new Map();
for (const e of ALLOW_LIST.entries ?? []) ALLOW.set(e.key, new Set(e.modes ?? []));
export const allowList = ALLOW_LIST;
const allowed = (key, mode) => ALLOW.get(key)?.has(mode) === true;

function notePiggy(why, key, who, host, boss, sites = null) {
  shimStats.piggyback++;
  if (why === 'scope') shimStats.piggyScope++;
  else if (why === 'unit') shimStats.piggyUnit++;
  else shimStats.piggyIdle++;
  if (boss) shimStats.piggyBoss++;
  const rec = (shimStats.piggybackByKey[key] ??= { scope: 0, unit: 0, idle: 0, allowed: ALLOW.has(key) ? [...ALLOW.get(key)] : null });
  rec[why]++;
  // Подробности подсадок без асинхронной связи (unit/idle) — для обоснования белого списка и разбора в тестах.
  if (why !== 'scope' && shimStats.piggyDetails.length < 40) shimStats.piggyDetails.push({ key, why, sql: who.sql ?? '', host: host.tag, hostUnit: host.unitId, unitLabel: host.unitId !== null ? (getUnit(host.unitId)?.label ?? null) : null, activeUnit: activeUnitId(), hostBegin: host.beginStack ?? null, stack: stackNames(sites, 10) });
  if (!allowed(key, why)) {
    shimStats.outsideWhitelist++;
    const d = { key, why, sql: who.sql ?? '', waiter: who.tag, host: host.tag, hostUnit: host.unitId, hostBegin: host.beginStack ?? null };
    if (shimStats.outsideWhitelistList.length < 40) shimStats.outsideWhitelistList.push(d);
    log(shimConfig.strict ? 'error' : 'warn', `pg-shim: подсадка вне белого списка (${why}) «${key}»: ${d.sql} → транзакция ${host.tag}`);
  }
}

// ---------------------------------------------------------------- асинхронный стек (V8 CallSite)
function captureSites(skip) {
  const prev = Error.prepareStackTrace;
  const prevLimit = Error.stackTraceLimit;
  let cs;
  try {
    Error.stackTraceLimit = 80;
    Error.prepareStackTrace = (_e, sites) => sites;
    const o = {};
    Error.captureStackTrace(o, skip);
    cs = o.stack;
  } catch {
    cs = null;
  } finally {
    Error.prepareStackTrace = prev;
    Error.stackTraceLimit = prevLimit;
  }
  shimStats.stackCaptures++;
  if (!Array.isArray(cs)) {
    shimStats.stackUnavailable++;
    return null;
  }
  const out = [];
  for (const c of cs) {
    const el = typeof c.getEnclosingLineNumber === 'function' ? c.getEnclosingLineNumber() : null;
    const ec = typeof c.getEnclosingColumnNumber === 'function' ? c.getEnclosingColumnNumber() : null;
    // Кадр «async Promise.all (index N)» (а также any/allSettled): номер ветки различает параллельные вызовы
    // одной и той же функции (receivables-sync.handler: Promise.all(worker × 2) → свои BEGIN…COMMIT).
    const pall = (typeof c.isPromiseAll === 'function' && c.isPromiseAll()) || (typeof c.isPromiseAny === 'function' && c.isPromiseAny());
    out.push({
      name: c.getFunctionName?.() ?? null,
      async: typeof c.isAsync === 'function' ? c.isAsync() : false,
      pidx: pall && typeof c.getPromiseIndex === 'function' ? c.getPromiseIndex() : null,
      key: `${c.getFileName?.() ?? ''}:${el ?? c.getLineNumber?.()}:${ec ?? c.getColumnNumber?.()}`,
    });
  }
  return out;
}
/**
 * Асинхронная цепочка вызывающего: снимок после `await null` (синхронный снимок из thenable-задачи drizzle теряет
 * цепочку), только асинхронные кадры. Синхронная часть снимка — сама функция снимка и внутренности среды,
 * разбирающей микрозадачи (в Node: runNextTicks/processTimers — они общие для всех операторов и дали бы ложное
 * «в области»). Первый асинхронный кадр — функция шима, ждущая снимок (#query, Pool.query, bossStatement); он
 * тоже отбрасывается. Первый оставшийся кадр — вызывающий оператор код. Без асинхронных кадров — [].
 */
async function callerSites() {
  await null;
  const all = captureSites(captureSites);
  if (!all) return null;
  const i = all.findIndex((f) => f.async);
  return i < 0 ? [] : all.slice(i + 1);
}
/** Номера ветвей Promise.all от кадра i наружу — «путь» вызова; у параллельных вызовов он разный. */
const promisePath = (sites, i) => {
  let s = '';
  for (let j = i; j < sites.length; j++) if (sites[j].pidx !== null) s += `${sites[j].pidx}.`;
  return s;
};
/**
 * Область транзакции по стеку BEGIN (только «сырые» BEGIN: client.query('BEGIN') в outbox-dispatcher,
 * catalog-full-load, onec-changes, receivables writer, мигратор): позиция функции, вызвавшей BEGIN, путь ветвей
 * Promise.all от неё наружу и единица работы из стека (если видна). Транзакции drizzle области не имеют
 * (attachDrizzleScope): асинхронная цепочка их операторов обрывается в QueryPromise drizzle (thenable +
 * `return tracer.startActiveSpan(…, () => this.queryWithCache())` без await) — в стеке BEGIN и операторов пула
 * остаётся только внутренняя функция drizzle, общая для ВСЕХ запросов (проверено в WP-B2: 73 из 73 транзакций).
 * Их подсадки идут по правилам unit/idle.
 */
function scopeOfBegin(sites, drizzle) {
  if (drizzle || !sites || sites.length === 0) return null;
  return { pos: sites[0].key, path: promisePath(sites, 0), unit: unitIdFromSites(sites) };
}
/** Индекс кадра области в стеке оператора (−1 — не в области). */
function scopeIndex(sites, scope) {
  if (!sites || !scope) return -1;
  const i = sites.findIndex((f) => f.key === scope.pos);
  if (i < 0) return -1;
  if (promisePath(sites, i) !== scope.path) return -1; // параллельная ветвь Promise.all — другая транзакция
  if (scope.unit !== null) {
    const su = unitIdFromSites(sites);
    if (su !== null && su !== scope.unit) return -1;
  }
  return i;
}
const stackNames = (sites, n = 14) => (sites ? sites.slice(0, n).map((f) => f.name ?? '?').join(' < ') : null);

/**
 * Пометить транзакции drizzle (вызвать один раз до createApp): NodePgSession.transaction над пулом синхронно
 * вызывает pool.connect() — созданный клиент помечается `drizzle` и получает область null; над клиентом — помечается
 * сам клиент перед его BEGIN.
 *
 * Вложенная транзакция drizzle (fix round 1, WP-T1 дефект 2): колбэк каждой транзакции выполняется внутри своей
 * именованной асинхронной рамки `__posDtx_<id>` (как `__posUnit_<id>` единиц работы). Операторы drizzle асинхронную
 * цепочку теряют, но сам вызов `db.transaction()` — синхронный вызов из кода pos-api, и его асинхронный стек V8
 * доходит до рамки транзакции, в колбэке которой он сделан (RateLimitService.consume ← RefreshService.rotateInTx в
 * POST /auth/unlock: счётчик RL-PIN «в собственной транзакции»). Такая транзакция получает `parent`; её BEGIN, пока
 * держатель — родительская транзакция (или транзакция, в которую та подсажена), сразу становится SAVEPOINT в
 * транзакции держателя (в PostgreSQL — второе соединение; здесь держатель ждёт её — иначе взаимоблокировка и
 * прежнее ожидание nestedBeginIdleMs с подсадкой вне белого списка). Без V8 CallSite (Safari) parent не известен —
 * действует прежнее правило unit/nestedBeginIdleMs.
 */
let drizzleConnect = null; // { id, parent } — транзакция drizzle, открываемая текущим синхронным вызовом
let dtxSeq = 0;
const DTX_RE = /^__posDtx_(\d+)$/;
/** Открытые транзакции drizzle (собственные и подсаженные): id → клиент. */
const dtxClients = new Map();
function dtxMarker(id, cb) {
  const name = `__posDtx_${id}`;
  // Имя функции видно в асинхронном стеке V8 (CallSite.getFunctionName) у кадра `async`.
  const holder = {
    async [name](tx) {
      return await cb(tx);
    },
  };
  return holder[name];
}
function dtxFromSites(sites) {
  if (!sites) return null;
  for (const f of sites) {
    const m = f.name && DTX_RE.exec(f.name);
    if (m) return Number(m[1]);
  }
  return null;
}
export function attachDrizzleScope(NodePgSession) {
  const proto = NodePgSession.prototype;
  if (proto.__posScoped) return;
  const orig = proto.transaction;
  proto.transaction = function transaction(cb, ...rest) {
    const id = ++dtxSeq;
    const parent = dtxClients.size > 0 ? dtxFromSites(captureSites(transaction)) : null;
    const d = { id, parent };
    if (parent !== null) shimStats.dtxNestedCalls++;
    if (this.client instanceof Client) {
      this.client.drizzleNext = true;
      this.client.dtxNext = d;
    }
    drizzleConnect = d;
    try {
      return orig.call(this, typeof cb === 'function' ? dtxMarker(id, cb) : cb, ...rest);
    } finally {
      drizzleConnect = null;
    }
  };
  proto.__posScoped = true;
}
/** BEGIN транзакции drizzle, открытой из колбэка транзакции держателя h (или подсаженной в h)? */
function dtxNestedIn(who, h) {
  const parent = who?.dtxNext?.parent ?? null;
  if (parent === null) return false;
  const pc = dtxClients.get(parent);
  return !!pc && (pc === h || (pc.inTx === 'nested' && pc.nested?.host === h));
}

// ---------------------------------------------------------------- замок сессии
const lock = { holder: null, queue: [] }; // holder: Client (в транзакции) | { tag, sql } (одиночный оператор)
let running = 0; // операторы, выполняющиеся в PGlite
let lastActivityAt = 0;
setActivityProbe(() => {
  const h = lock.holder;
  return { busy: h !== null || lock.queue.length > 0 || running > 0, lastActivityAt, txUnit: h instanceof Client && h.inTx === 'own' ? h.unitId : null };
});

function grant() {
  const n = lock.queue.shift();
  if (!n) {
    lock.holder = null;
    return;
  }
  lock.holder = n.who;
  n.settle({ mode: 'own' });
}
const isTxHolder = (h) => h instanceof Client && h.inTx === 'own';

/**
 * Решение о подсадке оператора в транзакцию держателя h. kind: 'stmt' | 'begin' | 'listen' | 'bossInsert' |
 * 'bossInternal' | 'bossTx'. Возвращает { mode: 'piggy', host, why } или null (ждать замок).
 */
function piggyDecision(h, kind, sites, key, waited, who = null) {
  if (!isTxHolder(h)) return null;
  if (kind === 'bossTx' || kind === 'listen') return null;
  // Транзакция drizzle из колбэка транзакции держателя (рамка __posDtx_<id>, attachDrizzleScope): асинхронная связь
  // установлена — это область, как у сырых транзакций; держатель ждёт её BEGIN.
  if (kind === 'begin' && h.inflight === 0 && dtxNestedIn(who, h)) return { mode: 'piggy', host: h, why: 'scope' };
  const si = scopeIndex(sites, h.scope);
  // Вложенный BEGIN по области — только из функции, вызванной внутри транзакции (si > 0): BEGIN, который вызывает
  // сама функция области, — это её повторный/параллельный вызов, то есть другая транзакция.
  if (si >= 0 && (kind !== 'begin' || si > 0)) {
    if (shimConfig.debugScopes && shimStats.scopeDebug.length < 200) shimStats.scopeDebug.push({ at: 'piggy', kind, key, host: h.tag, scope: h.scope, stack: stackNames(sites, 25) });
    return { mode: 'piggy', host: h, why: 'scope' };
  }
  if (kind === 'bossInternal') return null;
  // без асинхронной связи с транзакцией: обычный оператор, вставка задачи pg-boss, BEGIN
  const su = unitIdFromSites(sites);
  if (su !== null && h.unitId !== null && su !== h.unitId) return null; // чужая единица — никогда
  if (h.inflight !== 0) return null;
  const hostActive = h.unitId !== null && h.unitId === activeUnitId();
  // Простой держателя — с последнего его оператора и с последней уступки вычисления (Argon2 внутри транзакции
  // step-up/входа по PIN — не простой: держатель сам дойдёт до COMMIT, ждать правильно).
  const idle = now() - Math.max(h.lastActivity, lastBusyAt());
  if (kind === 'begin') {
    // Только своя (активная) единица и долгий простой держателя: так выглядит вложенная транзакция пула внутри
    // колбэка транзакции (в PG — второе соединение), иначе — взаимоблокировка. Чужой BEGIN не подсаживается никогда.
    if (hostActive && idle >= shimConfig.nestedBeginIdleMs && waited >= shimConfig.nestedBeginIdleMs) return { mode: 'piggy', host: h, why: 'unit' };
    return null;
  }
  if (kind === 'bossInsert') {
    // Вставка задачи pg-boss вне области — только в режимах, разрешённых белым списком (plan §3.4 правило 3), без
    // страховки по простою: тикер outbox и другие таймеры не должны попадать в чужую транзакцию. Публикации из
    // транзакций pos-api идут с { db: tx } (клиентом транзакции) и сюда не попадают.
    if (hostActive && allowed(key, 'unit')) return { mode: 'piggy', host: h, why: 'unit' };
    if (!hostActive && allowed(key, 'idle') && idle >= shimConfig.idleForeignMs && waited >= shimConfig.idleForeignMs) return { mode: 'piggy', host: h, why: 'idle' };
    return null;
  }
  if (hostActive && allowed(key, 'unit')) return { mode: 'piggy', host: h, why: 'unit' };
  const need = hostActive ? shimConfig.idleMs : shimConfig.idleForeignMs;
  if (idle >= need && waited >= need) return { mode: 'piggy', host: h, why: hostActive ? 'unit' : 'idle' };
  return null;
}

function acquire(who, kind, sites, key) {
  const h = lock.holder;
  if (!h) {
    lock.holder = who;
    return Promise.resolve({ mode: 'own' });
  }
  const d0 = piggyDecision(h, kind, sites, key, 0, who);
  if (d0) return Promise.resolve(d0);
  const at = now();
  if (kind === 'begin' && isTxHolder(h)) shimStats.beginWaitedForTx++;
  const su = unitIdFromSites(sites);
  if (su !== null && isTxHolder(h) && h.unitId !== null && su !== h.unitId) shimStats.foreignUnitWaits++;
  return new Promise((resolve, reject) => {
    let timer = null;
    let warned = false;
    const holderAtStart = h.tag ?? '?';
    const holderSqlAtStart = h.sql ?? '';
    const entry = {
      who,
      settle: (v) => {
        if (timer) clearInterval(timer);
        const waited = now() - at;
        shimStats.maxWaitMs = Math.max(shimStats.maxWaitMs, Math.round(waited));
        shimStats.waits++;
        if (waited > 1000) shimStats.waitsOver1s++;
        if (waited > 500 && shimStats.slowWaits.length < 60) shimStats.slowWaits.push({ waiter: who.tag, wsql: who.sql, kind, holder: holderAtStart, hsql: holderSqlAtStart, hstack: h.beginStack ?? null, ms: Math.round(waited), mode: v.mode, why: v.why });
        resolve(v);
      },
    };
    lock.queue.push(entry);
    timer = setInterval(() => {
      const waited = now() - at;
      if (waited > shimConfig.watchdogMs && !warned) {
        warned = true;
        shimStats.waitsOver3s++;
        const cur = lock.holder;
        const rec = { waiter: who.tag, kind, sql: who.sql, holder: cur?.tag ?? null, hsql: cur?.sql ?? null, hunit: cur?.unitId ?? null, hstack: cur?.beginStack ?? null, ms: Math.round(waited) };
        if (shimStats.longWaits.length < 20) shimStats.longWaits.push(rec);
        log('error', `pg-shim: сторож — ожидание замка ${rec.ms} мс: ждёт ${who.tag} [${who.sql ?? ''}], держит ${rec.holder ?? '—'} [${rec.hsql ?? ''}] (BEGIN: ${rec.hstack ?? '—'})`);
      }
      if (waited > shimConfig.breakerMs) {
        const i = lock.queue.indexOf(entry);
        if (i >= 0) lock.queue.splice(i, 1);
        clearInterval(timer);
        shimStats.breakerRejects++;
        log('error', `pg-shim: ожидание замка дольше ${shimConfig.breakerMs} мс — оператор отклонён: ${who.tag} [${who.sql ?? ''}]`);
        const e = new Error(`pg-shim: ожидание замка сессии дольше ${shimConfig.breakerMs} мс`);
        e.code = 'ERR_DEMO_LOCK_TIMEOUT';
        reject(e);
        return;
      }
      const cur = lock.holder;
      const d = cur && piggyDecision(cur, kind, sites, key, waited, who);
      if (d) {
        const i = lock.queue.indexOf(entry);
        if (i < 0) return;
        lock.queue.splice(i, 1);
        entry.settle(d);
      }
    }, shimConfig.recheckMs);
    timer.unref?.();
  });
}
function release(who) {
  if (lock.holder === who) grant();
}
export const lockState = lock;
/** Снимок для /__demo/state и тестов. */
export function shimSnapshot() {
  const h = lock.holder;
  return {
    config: { ...shimConfig },
    holder: h ? { tag: h.tag, inTx: h.inTx ?? null, unit: h.unitId ?? null, sql: h.sql ?? null } : null,
    waiting: lock.queue.map((e) => ({ tag: e.who.tag, sql: e.who.sql })),
    running,
    stats: { ...shimStats, piggybackByKey: { ...shimStats.piggybackByKey } },
  };
}

// ---------------------------------------------------------------- выполнение
// Разбор значений по OID как в node-postgres: pg-types 2.2.0 или `types` запроса (drizzle node-postgres передаёт свой
// getTypeParser: timestamptz/timestamp/date/interval и их массивы, numeric[] — сырой строкой).
// PGlite 0.3.16 объединяет парсеры распаковкой — parseResults: `{...this.parsers, ...options.parsers}`, — поэтому
// таблица парсеров запроса должна быть ОБЫЧНЫМ объектом с собственными ключами. (До fix round 1 здесь был Proxy без
// ключей: распаковка давала пустой объект и действовали парсеры PGlite — int8 → BigInt, int8[] → числа, bytea →
// Uint8Array без .equals, interval → строка, `types` drizzle игнорировался; WP-T1 дефект 1.)
// Ключи — все OID, которые разбирает хоть одна сторона: pg-types (перебор OID встроенных типов), подмены drizzle и
// PGlite (его умолчания и парсеры массивов из _initArrayTypes). OID без парсера в pg-types остаётся строкой (noParse),
// как у node-postgres; OID вне набора (enum с динамическим OID и т. п.) PGlite и так возвращает строкой.
const NO_PARSE = pgTypes.getTypeParser(0x7fffffff, 'text');
const DRIZZLE_OVERRIDE_OIDS = [1082, 1114, 1115, 1182, 1184, 1185, 1186, 1187, 1231]; // drizzle-orm/node-postgres/session.js
const MAX_BUILTIN_OID = 16384; // FirstNormalObjectId: OID встроенных типов меньше
const parserCache = { oids: null, plain: null, typed: new WeakMap() };
function resetParserCache() {
  parserCache.oids = null;
  parserCache.plain = null;
  parserCache.typed = new WeakMap();
}
function parserOids() {
  if (parserCache.oids) return parserCache.oids;
  const set = new Set(DRIZZLE_OVERRIDE_OIDS);
  for (let oid = 0; oid < MAX_BUILTIN_OID; oid++) if (pgTypes.getTypeParser(oid, 'text') !== NO_PARSE) set.add(oid);
  for (const k of Object.keys(state.db?.parsers ?? {})) {
    const n = Number(k);
    if (Number.isInteger(n) && n >= 0) set.add(n);
  }
  parserCache.oids = [...set].sort((a, b) => a - b);
  return parserCache.oids;
}
function buildParsers(get) {
  const o = {};
  for (const oid of parserOids()) {
    const p = get(oid) ?? NO_PARSE;
    o[oid] = (text) => p(text); // только текст: PGlite зовёт parser(value, oid), а JSON.parse принял бы oid за reviver
  }
  return o;
}
/** Таблица парсеров запроса для PGlite (обычный объект): pg-types или `types` запроса. */
export function rawParsers(cfgTypes) {
  if (!cfgTypes || typeof cfgTypes.getTypeParser !== 'function') return (parserCache.plain ??= buildParsers((oid) => pgTypes.getTypeParser(oid, 'text')));
  let o = parserCache.typed.get(cfgTypes);
  if (!o) {
    o = buildParsers((oid) => cfgTypes.getTypeParser(oid, 'text'));
    parserCache.typed.set(cfgTypes, o);
  }
  return o;
}
// types.setTypeParser (pg.types) меняет разбор у node-postgres — таблицы пересобираются.
if (typeof pgTypes.setTypeParser === 'function' && !pgTypes.__posShimWrapped) {
  const origSet = pgTypes.setTypeParser;
  pgTypes.setTypeParser = function setTypeParser(...a) {
    const r = origSet.apply(this, a);
    resetParserCache();
    return r;
  };
  pgTypes.__posShimWrapped = true;
}
// Значения уже подготовлены prepareValue (строки/Buffer/null) — PGlite передаёт их как есть.
const identitySerializers = new Proxy({}, { get: () => (x) => x });

function toPgResult(r, text, rowMode) {
  const rows = r.rows ?? [];
  const affected = r.affectedRows ?? 0;
  const command = (/^\s*([a-zA-Z]+)/.exec(text)?.[1] ?? '').toUpperCase();
  return {
    command,
    rowCount: affected || rows.length,
    oid: null,
    rows,
    fields: (r.fields ?? []).map((f) => ({ name: f.name, dataTypeID: f.dataTypeID, format: 'text' })),
    rowAsArray: rowMode === 'array',
  };
}
// Review fixes: изменяющие операторы таблиц с видимым заказчику состоянием — отметка у активной единицы (work-gate
// noteWrite → задача pg-boss становится durable). Drizzle пишет `update "payments" set …`, сырой SQL — `UPDATE payments`.
const DURABLE_WRITE_RE = /^\s*(?:update|insert\s+into|delete\s+from)\s+(?:"?public"?\.)?"?(payments|orders|return_requests)"?[\s(]/i;

// Review fixes (сбой WebAssembly после ready): ловушка PGlite (Aborted(), unreachable, выход за память) или закрытая
// не нами база — сервер демо мёртв. Дальше ни один оператор не выполняется, точка входа шлёт странице fatal.
const fatalState = { dead: false, reason: null, handler: null, expected: false };
/** Обработчик «PGlite мёртв» (точка входа): вызывается один раз, с ошибкой. */
export function setFatalHandler(fn) {
  fatalState.handler = typeof fn === 'function' ? fn : null;
}
/** Отключить обнаружение (штатное закрытие PGlite: shutdown, сброс) — «PGlite is closed» тогда не авария. */
export function expectClosed() {
  fatalState.expected = true;
}
export function pgliteDead() {
  return fatalState.dead ? fatalState.reason : null;
}
/** Ошибка PGlite — гибель экземпляра (ловушка WebAssembly, abort Emscripten, база закрыта не нами), а не ошибка SQL. */
export function isPgliteFatal(e) {
  if (fatalState.expected || !e) return false;
  if (typeof e.code === 'string' && /^[0-9A-Z]{5}$/.test(e.code)) return false; // SQLSTATE — обычная ошибка оператора
  if (typeof WebAssembly !== 'undefined' && e instanceof WebAssembly.RuntimeError) return true;
  const msg = String(e.message ?? e);
  return e.name === 'RuntimeError' || /^Aborted\(|PGlite is closed/.test(msg);
}
/** Ошибка из любого пути к PGlite (pg-boss, demo_meta, сброс тома, обработчики ошибок воркера): авария — отметить. */
export function reportPgliteError(e) {
  if (!fatalState.dead && isPgliteFatal(e)) markPgliteDead(e);
}
function markPgliteDead(e) {
  if (fatalState.dead) return;
  fatalState.dead = true;
  fatalState.reason = String(e?.message ?? e).slice(0, 500);
  log('error', `pg-shim: PGlite остановился (${fatalState.reason}); сервер демо больше не выполняет операторы`);
  try {
    fatalState.handler?.(e);
  } catch {
    /* обработчик — уведомление */
  }
}

async function runRaw(text, values, cfg) {
  if (!state.db) throw new Error('pg-shim: PGlite не подключён');
  if (fatalState.dead) throw Object.assign(new Error(`PGlite остановился: ${fatalState.reason}`), { code: 'ERR_DEMO_PGLITE_DEAD' });
  shimStats.queries++;
  running++;
  lastActivityAt = now();
  const rowMode = cfg?.rowMode === 'array' ? 'array' : 'object';
  const parsers = rawParsers(cfg?.types);
  const w = DURABLE_WRITE_RE.exec(text);
  if (w) noteWrite(w[1].toLowerCase());
  try {
    if (values && values.length > 0) {
      const vals = values.map((v) => (v === undefined ? null : prepareValue(v)));
      const r = await state.db.query(text, vals, { rowMode, parsers, serializers: identitySerializers });
      return toPgResult(r, text, rowMode);
    }
    const rs = await state.db.exec(text, { rowMode, parsers });
    if (rs.length <= 1) return toPgResult(rs[0] ?? { rows: [] }, text, rowMode);
    return rs.map((r) => toPgResult(r, text, rowMode));
  } catch (e) {
    shimStats.errors++;
    if (isPgliteFatal(e)) markPgliteDead(e);
    if (!/^\s*(SAVEPOINT|RELEASE|ROLLBACK)/i.test(text)) log('warn', `pg-shim: ошибка оператора: ${e?.message ?? e} [${short(text)}]`);
    throw e;
  } finally {
    running--;
    lastActivityAt = now();
  }
}

// Точки сохранения держателя: его собственные (drizzle `savepoint sp1`) и вложенных транзакций (pgshim_tx_N), по
// порядку создания. RELEASE x снимает x и всё выше, ROLLBACK TO x — всё выше x (семантика PostgreSQL).
const SP_RE = /^\s*savepoint\s+("?)([A-Za-z0-9_]+)\1\s*;?\s*$/i;
const RELEASE_RE = /^\s*release\s+(?:savepoint\s+)?("?)([A-Za-z0-9_]+)\1\s*;?\s*$/i;
const RB_TO_RE = /^\s*rollback\s+to\s+(?:savepoint\s+)?("?)([A-Za-z0-9_]+)\1\s*;?\s*$/i;
function trackSavepoint(host, text, child = null) {
  let m = SP_RE.exec(text);
  if (m) {
    host.spStack.push({ name: m[2], child });
    return;
  }
  m = RELEASE_RE.exec(text);
  if (m) return dropSavepoints(host, m[2], 0);
  m = RB_TO_RE.exec(text);
  if (m) return dropSavepoints(host, m[2], 1);
}
function dropSavepoints(host, name, keep) {
  let i = -1;
  for (let j = host.spStack.length - 1; j >= 0; j--)
    if (host.spStack[j].name === name) {
      i = j;
      break;
    }
  if (i < 0) return;
  const gone = host.spStack.splice(i + keep);
  for (const g of gone) if (g.child && g.child.nested && !g.child.nested.orphaned) orphan(g.child, 'точка сохранения снята держателем');
}
function orphan(child, why) {
  if (!child.nested || child.nested.orphaned) return;
  child.nested.orphaned = why;
  shimStats.orphanedNested++;
  log('warn', `pg-shim: вложенная транзакция ${child.tag} осиротела (${why}); держатель ${child.nested.host.tag}`);
}
function orphanError(child) {
  shimStats.orphanedStatements++;
  const e = new Error(`pg-shim: вложенная транзакция ${child.tag} завершена держателем (${child.nested?.orphaned ?? '—'})`);
  e.code = 'ERR_DEMO_TX_ORPHANED';
  return e;
}

// Последовательность операторов внутри транзакции держателя: свои операторы держателя и подсаженные
// SAVEPOINT-блоки не перемежаются (иначе ROLLBACK TO SAVEPOINT откатил бы чужой оператор).
function hostRun(host, fn) {
  const run = host.chain.then(fn, fn);
  host.chain = run.then(
    () => undefined,
    () => undefined,
  );
  return run;
}
let spSeq = 0;
function runPiggy(host, text, values, cfg) {
  const sp = `pgshim_sp_${++spSeq}`;
  host.inflight++;
  return hostRun(host, async () => {
    // Держатель мог завершить транзакцию, пока подсадка ждала очереди: оператор выполняется заново как обычный.
    if (host.inTx !== 'own') {
      host.inflight--;
      shimStats.hostGoneRetries++;
      throw HOST_GONE;
    }
    try {
      await runRaw(`SAVEPOINT ${sp}`);
      try {
        const r = await runRaw(text, values, cfg);
        await runRaw(`RELEASE SAVEPOINT ${sp}`);
        return r;
      } catch (e) {
        await runRaw(`ROLLBACK TO SAVEPOINT ${sp}`).catch(() => undefined);
        await runRaw(`RELEASE SAVEPOINT ${sp}`).catch(() => undefined);
        throw e;
      }
    } finally {
      host.inflight--;
      host.lastActivity = now();
    }
  });
}

function normalize(textOrConfig, values) {
  if (typeof textOrConfig === 'string') return { text: textOrConfig, values, cfg: undefined };
  return { text: textOrConfig.text, values: values ?? textOrConfig.values, cfg: textOrConfig };
}
const BEGIN_RE = /^\s*(begin|start\s+transaction)\b/i;
const COMMIT_RE = /^\s*(commit|end)\b/i;
const ROLLBACK_RE = /^\s*rollback\b(?!\s+to\b)/i;
const LISTEN_RE = /^\s*listen\s+("?)([a-zA-Z0-9_]+)\1\s*;?\s*$/i;
const UNLISTEN_RE = /^\s*unlisten\s+("?)([a-zA-Z0-9_*]+)\1\s*;?\s*$/i;
const withCb = (p, values, cb) => {
  const f = typeof cb === 'function' ? cb : typeof values === 'function' ? values : null;
  if (f) p.then((r) => f(null, r), (e) => f(e));
  return p;
};
/** Нужен ли стек: BEGIN или замок держит транзакция (иначе подсадка невозможна и решать нечего). */
const needSites = (text) => BEGIN_RE.test(text) || isTxHolder(lock.holder);

let clientSeq = 0;
export class Client extends EventEmitter {
  constructor(opts = {}) {
    super();
    this.id = ++clientSeq;
    this.tag = `${opts.application_name ?? 'client'}#${this.id}`;
    this.inTx = false; // false | 'own' | 'nested'
    this.nested = null; // { host, sp, orphaned }
    this.children = new Set(); // вложенные транзакции, подсевшие в эту
    this.spStack = [];
    this.inflight = 0;
    this.lastActivity = now();
    this.listens = new Map();
    this.chain = Promise.resolve();
    this.scope = null;
    this.unitId = null;
  }
  async connect() {}
  query(textOrConfig, values, cb) {
    const { text, values: vals, cfg } = normalize(textOrConfig, values);
    return withCb(this.#query(text, vals, cfg, !this.inTx && needSites(text)), values, cb);
  }
  async #exec(text, vals, cfg) {
    this.sql = short(text);
    this.inflight++;
    try {
      return await runRaw(text, vals, cfg);
    } finally {
      this.inflight--;
      this.lastActivity = now();
    }
  }
  async #query(text, vals, cfg, wantSites) {
    const sites = wantSites ? await callerSites() : null;
    const l = LISTEN_RE.exec(text);
    if (l) {
      const ch = l[2];
      if (this.inTx) throw new Error('pg-shim: LISTEN внутри транзакции не поддерживается (PGlite.listen работает вне транзакции)');
      if (!this.listens.has(ch)) {
        // LISTEN внутри чужой транзакции пропал бы при её откате — ждём замок без подсадки.
        const un = await sessionLocked(`listen:${ch}`, 'listen', `LISTEN ${ch}`, () => state.db.listen(ch, (payload) => this.emit('notification', { channel: ch, payload, processId: 0 })));
        this.listens.set(ch, un);
      }
      return toPgResult({ rows: [] }, text);
    }
    const u = UNLISTEN_RE.exec(text);
    if (u) {
      for (const [ch, un] of this.listens)
        if (u[2] === '*' || u[2] === ch) {
          await sessionLocked(`unlisten:${ch}`, 'listen', `UNLISTEN ${ch}`, () => un());
          this.listens.delete(ch);
        }
      return toPgResult({ rows: [] }, text);
    }
    if (this.inTx === 'own') {
      const r = await hostRun(this, async () => {
        const res = await this.#exec(text, vals, cfg);
        trackSavepoint(this, text);
        return res;
      });
      if (COMMIT_RE.test(text) || ROLLBACK_RE.test(text)) this.#endOwn();
      return r;
    }
    if (this.inTx === 'nested') return this.#nestedQuery(text, vals, cfg);

    const isBegin = BEGIN_RE.test(text);
    this.sql = short(text);
    const key = fingerprint(text);
    let g;
    for (;;) {
      g = await acquire(this, isBegin ? 'begin' : 'stmt', sites, key);
      if (g.mode !== 'piggy') break;
      try {
        if (isBegin) {
          const host = g.host;
          const sp = `pgshim_tx_${++spSeq}`;
          notePiggy(g.why, 'begin', this, host, false, sites);
          await runPiggyBegin(host, this, sp);
          shimStats.nestedBegin++;
          this.#takeDtx();
          if (g.why === 'scope' && this.dtx?.parent != null) shimStats.dtxNestedBegin++;
          const su = unitIdFromSites(sites);
          if (su !== null && host.unitId !== null && su !== host.unitId) {
            shimStats.nestedBeginForeign++;
            log('error', `pg-shim: вложенный BEGIN из чужой единицы ${su} в транзакцию ${host.tag} (единица ${host.unitId})`);
          }
          return toPgResult({ rows: [] }, 'BEGIN');
        }
        notePiggy(g.why, key, this, g.host, false, sites);
        return await runPiggy(g.host, text, vals, cfg);
      } catch (e) {
        if (e !== HOST_GONE) throw e;
      }
    }
    let keep = false;
    try {
      const r = await this.#exec(text, vals, cfg);
      if (isBegin) {
        this.inTx = 'own';
        const drizzle = this.drizzle || this.drizzleNext === true;
        this.drizzleNext = false;
        this.txDrizzle = drizzle;
        this.scope = scopeOfBegin(sites, drizzle);
        shimStats.txByScope[drizzle ? 'drizzle' : this.scope ? 'raw' : 'none']++;
        if (shimConfig.debugScopes && shimStats.scopeDebug.length < 200) shimStats.scopeDebug.push({ at: 'begin', tag: this.tag, scope: this.scope, stack: stackNames(sites, 25) });
        this.beginStack = stackNames(sites);
        this.unitId = unitIdFromSites(sites) ?? activeUnitId();
        this.spStack = [];
        this.beganAt = now();
        this.#takeDtx();
        keep = true;
        shimStats.tx++;
      }
      return r;
    } finally {
      if (!keep) release(this);
    }
  }
  async #nestedQuery(text, vals, cfg) {
    const n = this.nested;
    const { host, sp } = n;
    if (COMMIT_RE.test(text)) {
      if (n.orphaned) {
        this.#endNested();
        throw orphanError(this);
      }
      await this.#onHost(`RELEASE SAVEPOINT ${sp}`);
      this.#endNested();
      return toPgResult({ rows: [] }, 'COMMIT');
    }
    if (ROLLBACK_RE.test(text)) {
      if (!n.orphaned) await this.#onHost(`ROLLBACK TO SAVEPOINT ${sp}`).catch(() => undefined);
      if (!n.orphaned) await this.#onHost(`RELEASE SAVEPOINT ${sp}`).catch(() => undefined);
      this.#endNested();
      return toPgResult({ rows: [] }, 'ROLLBACK');
    }
    return this.#onHost(text, vals, cfg);
  }
  /** Оператор вложенной транзакции — в цепочке держателя; если держатель её «осиротил» — ошибка, не сессия. */
  #onHost(text, vals, cfg) {
    const n = this.nested;
    const host = n.host;
    host.inflight++;
    return hostRun(host, async () => {
      try {
        if (n.orphaned || host.inTx !== 'own') {
          orphan(this, 'транзакция держателя завершена');
          throw orphanError(this);
        }
        this.sql = short(text);
        const r = await runRaw(text, vals, cfg);
        trackSavepoint(host, text, null);
        return r;
      } finally {
        host.inflight--;
        host.lastActivity = now();
      }
    });
  }
  _beginNested(host, sp) {
    this.inTx = 'nested';
    this.nested = { host, sp, orphaned: false };
    host.children.add(this);
    host.spStack.push({ name: sp, child: this });
  }
  /** Транзакция drizzle этого BEGIN (attachDrizzleScope) — в таблицу открытых; снимается в #endOwn/#endNested. */
  #takeDtx() {
    this.dtx = this.dtxNext ?? null;
    this.dtxNext = null;
    if (this.dtx) dtxClients.set(this.dtx.id, this);
  }
  #dropDtx() {
    if (this.dtx && dtxClients.get(this.dtx.id) === this) dtxClients.delete(this.dtx.id);
    this.dtx = null;
  }
  #endOwn() {
    this.#dropDtx();
    const held = this.beganAt ? now() - this.beganAt : 0;
    shimStats.maxTxMs = Math.max(shimStats.maxTxMs, Math.round(held));
    if (held > 1000 && shimStats.longTx.length < 30) shimStats.longTx.push({ tag: this.tag, ms: Math.round(held), stack: this.beginStack, last: this.sql, unit: this.unitId });
    for (const c of this.children) orphan(c, 'держатель завершил транзакцию');
    this.children.clear();
    this.spStack = [];
    this.inTx = false;
    this.scope = null;
    this.unitId = null;
    release(this);
  }
  #endNested() {
    this.#dropDtx();
    const n = this.nested;
    if (n) {
      n.host.children.delete(this);
      const i = n.host.spStack.findIndex((x) => x.child === this);
      if (i >= 0) n.host.spStack.splice(i, 1);
    }
    this.inTx = false;
    this.nested = null;
  }
  async #abort() {
    if (this.inTx === 'own') {
      await hostRun(this, () => runRaw('ROLLBACK')).catch(() => undefined);
      this.#endOwn();
    } else if (this.inTx === 'nested') {
      const n = this.nested;
      if (!n.orphaned) await this.#onHost(`ROLLBACK TO SAVEPOINT ${n.sp}`).catch(() => undefined);
      if (!n.orphaned) await this.#onHost(`RELEASE SAVEPOINT ${n.sp}`).catch(() => undefined);
      this.#endNested();
    }
  }
  release(_err) {
    void this.#abort();
    this.pool?._released(this);
  }
  async end() {
    await this.#abort();
    for (const un of this.listens.values()) await un();
    this.listens.clear();
  }
  escapeIdentifier(s) {
    return `"${String(s).replace(/"/g, '""')}"`;
  }
  escapeLiteral(s) {
    return `'${String(s).replace(/'/g, "''")}'`;
  }
}

/** BEGIN клиента внутри области держателя: SAVEPOINT в цепочке держателя, клиент становится вложенным. */
function runPiggyBegin(host, client, sp) {
  host.inflight++;
  return hostRun(host, async () => {
    try {
      if (host.inTx !== 'own') {
        shimStats.hostGoneRetries++;
        throw HOST_GONE;
      }
      await runRaw(`SAVEPOINT ${sp}`);
      client._beginNested(host, sp);
    } finally {
      host.inflight--;
      host.lastActivity = now();
    }
  });
}

export class Pool extends EventEmitter {
  constructor(opts = {}) {
    super();
    this.options = opts;
    this.totalCount = 0;
    this.idleCount = 0;
    this.waitingCount = 0;
    this.ended = false;
  }
  async connect(cb) {
    const c = new Client(this.options);
    c.pool = this;
    // Клиент транзакции drizzle (NodePgSession.transaction над пулом вызывает connect() синхронно).
    if (drizzleConnect) {
      c.drizzle = true;
      c.dtxNext = drizzleConnect;
      drizzleConnect = null;
    }
    this.totalCount++;
    if (typeof cb === 'function') {
      cb(null, c, () => c.release());
      return undefined;
    }
    return c;
  }
  _released() {
    this.totalCount = Math.max(0, this.totalCount - 1);
  }
  query(textOrConfig, values, cb) {
    const { text, values: vals, cfg } = normalize(textOrConfig, values);
    const who = { tag: `${this.options.application_name ?? 'pool'}.query`, sql: short(text) };
    const wantSites = needSites(text);
    if (BEGIN_RE.test(text)) {
      shimStats.poolBegin++;
      log('warn', `pg-shim: BEGIN через pool.query (${who.tag}) — транзакция без клиента`);
    }
    const key = fingerprint(text);
    const p = (async () => {
      const sites = wantSites ? await callerSites() : null;
      for (;;) {
        // BEGIN через pool.query (без клиента) не подсаживается никогда: он открыл бы транзакцию без владельца.
        const g = await acquire(who, BEGIN_RE.test(text) ? 'bossTx' : 'stmt', sites, key);
        if (g.mode !== 'piggy') break;
        try {
          notePiggy(g.why, key, who, g.host, false, sites);
          return await runPiggy(g.host, text, vals, cfg);
        } catch (e) {
          if (e !== HOST_GONE) throw e;
        }
      }
      try {
        return await runRaw(text, vals, cfg);
      } finally {
        release(who);
      }
    })();
    return withCb(p, values, cb);
  }
  async end() {
    this.ended = true;
  }
}

/** Оператор под замком сессии без подсадки (LISTEN/UNLISTEN, служебные действия pg-boss). */
async function sessionLocked(tag, kind, sql, fn) {
  const who = { tag, sql: short(sql) };
  await acquire(who, kind, null, fingerprint(sql));
  running++;
  lastActivityAt = now();
  try {
    return await fn();
  } catch (e) {
    reportPgliteError(e);
    throw e;
  } finally {
    running--;
    lastActivityAt = now();
    release(who);
  }
}

// Вставка задачи pg-boss (plans.insertJobs): `INSERT INTO pgboss.<таблица очереди> (id, name, data, …`, возможно в
// обёртке `WITH ins AS (…)` (send с notify). Прочие операторы pg-boss — внутренние.
const BOSS_INSERT_RE = /^\s*(?:with\s+ins\s+as\s*\(\s*)?insert\s+into\s+"?pgboss"?\."?[a-z0-9_]+"?\s*\(\s*id\s*,\s*name\s*,\s*data\b/i;
const BOSS_TX_RE = /\b(BEGIN|COMMIT|ROLLBACK)\b/i;
/**
 * Оператор pg-boss (шим pgboss-shim.mjs) под тем же замком. Свой: ownFn() — адаптер pg-boss fromPglite. Подсадка
 * (область держателя; вставка задачи — и unit/idle по правилам piggyDecision): тот же SQL под SAVEPOINT в цепочке
 * держателя, мимо адаптера (он при ошибке шлёт ROLLBACK всей сессии и откатил бы чужую транзакцию).
 * Блоки BEGIN…COMMIT pg-boss не подсаживаются никогда.
 */
export async function bossStatement(text, values, ownFn) {
  const kind = BOSS_TX_RE.test(text) ? 'bossTx' : BOSS_INSERT_RE.test(text) ? 'bossInsert' : 'bossInternal';
  const who = { tag: `pg-boss.${kind}`, sql: short(text) };
  const sites = kind !== 'bossTx' && isTxHolder(lock.holder) ? await callerSites() : null;
  const key = kind === 'bossInsert' ? 'insert pgboss.job' : fingerprint(text);
  for (;;) {
    const g = await acquire(who, kind, sites, key);
    if (g.mode !== 'piggy') break;
    try {
      notePiggy(g.why, key, who, g.host, true, sites);
      const r = await runPiggy(g.host, text, values);
      return Array.isArray(r) ? { rows: r.flatMap((x) => x.rows ?? []) } : { rows: r.rows };
    } catch (e) {
      if (e !== HOST_GONE) throw e;
    }
  }
  running++;
  lastActivityAt = now();
  try {
    return await ownFn();
  } catch (e) {
    reportPgliteError(e);
    throw e;
  } finally {
    running--;
    lastActivityAt = now();
    release(who);
  }
}
/** Служебные действия pg-boss (session statements, LISTEN) — под замком, без подсадки. */
export function bossSessionLocked(tag, sql, fn) {
  return sessionLocked(tag, 'listen', sql, fn);
}

export const types = pgTypes;
export class DatabaseError extends Error {}
const pg = { Pool, Client, types, DatabaseError, escapeIdentifier: Client.prototype.escapeIdentifier, escapeLiteral: Client.prototype.escapeLiteral };
export default pg;
