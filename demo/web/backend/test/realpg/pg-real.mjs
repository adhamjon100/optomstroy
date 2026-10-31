// Сверка с НАСТОЯЩИМ PostgreSQL (review fixes, critic [18]): подмена alias/pg-shim.mjs в сборке «эталон на
// PostgreSQL» (test/realpg/realpg-runner.mjs). Тот же интерфейс, что у pg-shim, но под ним — настоящий node-postgres и
// настоящий сервер PostgreSQL 17 (embedded-postgres из pos-api/node_modules): у каждого пула и клиента — свои
// соединения, как на сервере заказчика. Ни замка сессии, ни подсадки: сравнение бандла с этим эталоном показывает,
// где «одна сессия PGlite» ведёт себя иначе, чем сервер (подсаженный оператор видит незафиксированное и откатывается
// с держателем, set_config(…, true) держателя, порядок сортировки, разбор типов).
//
// Единица работы (alias/work-gate.mjs) остаётся та же — порядок запросов и задач такой же, как в демо; окно затихания
// работает по счётчику операторов в полёте (обёртка Client.prototype.query).
import pgMod from 'pg';
import { setActivityProbe } from '../../alias/work-gate.mjs';

const pg = pgMod.default ?? pgMod;
const now = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());

let running = 0;
let lastActivityAt = 0;
export const shimConfig = { strict: false, real: true };
export function configureShim() {
  return { ...shimConfig };
}
export const shimStats = {
  queries: 0,
  errors: 0,
  tx: 0,
  maxTxMs: 0,
  waits: 0,
  maxWaitMs: 0,
  waitsOver1s: 0,
  waitsOver3s: 0,
  breakerRejects: 0,
  piggyback: 0,
  piggyScope: 0,
  piggyUnit: 0,
  piggyIdle: 0,
  piggyBoss: 0,
  piggybackByKey: {},
  outsideWhitelist: 0,
  outsideWhitelistList: [],
  nestedBegin: 0,
  nestedBeginForeign: 0,
  beginWaitedForTx: 0,
  orphanedNested: 0,
  real: true,
};
globalThis.__posPgShimStats = shimStats;

// ---------------------------------------------------------------- счётчик операторов в полёте (окно затихания)
const origQuery = pg.Client.prototype.query;
pg.Client.prototype.query = function posRealQuery(...args) {
  shimStats.queries++;
  running++;
  lastActivityAt = now();
  let done = false;
  const finish = (err) => {
    if (done) return;
    done = true;
    running--;
    lastActivityAt = now();
    if (err) shimStats.errors++;
  };
  const cbIndex = typeof args[args.length - 1] === 'function' ? args.length - 1 : typeof args[1] === 'function' ? 1 : -1;
  if (cbIndex >= 0) {
    const cb = args[cbIndex];
    args[cbIndex] = function (err, res) {
      finish(err);
      return cb.call(this, err, res);
    };
    return origQuery.apply(this, args);
  }
  let r;
  try {
    r = origQuery.apply(this, args);
  } catch (e) {
    finish(e);
    throw e;
  }
  if (r && typeof r.then === 'function') {
    r.then(() => finish(), (e) => finish(e));
  } else if (r && typeof r.on === 'function') {
    r.on('end', () => finish());
    r.on('error', (e) => finish(e));
  } else finish();
  return r;
};
setActivityProbe(() => ({ busy: running > 0, lastActivityAt, txUnit: null }));

// ---------------------------------------------------------------- Client с ленивым подключением (как pg-shim)
// demo-init создаёт pg.Client и сразу шлёт запросы (у pg-shim connect() — пустой); node-postgres ставит запросы в
// очередь до готовности соединения — поэтому connect() вызывается при первом запросе.
export class Client extends pg.Client {
  query(...args) {
    if (!this.__posConnectStarted) {
      this.__posConnectStarted = true;
      this.__posConnect = super.connect().catch((e) => {
        this.__posConnectError = e;
      });
    }
    return super.query(...args);
  }
  connect(cb) {
    if (this.__posConnectStarted) return cb ? void this.__posConnect.then(() => cb()) : this.__posConnect;
    this.__posConnectStarted = true;
    this.__posConnect = super.connect(cb);
    return this.__posConnect;
  }
}
export const Pool = pg.Pool;
export const types = pg.types;
export const DatabaseError = pg.DatabaseError;
const real = { ...pg, Client, Pool: pg.Pool, types: pg.types, DatabaseError: pg.DatabaseError, escapeIdentifier: pg.escapeIdentifier ?? pg.Client.prototype.escapeIdentifier, escapeLiteral: pg.escapeLiteral ?? pg.Client.prototype.escapeLiteral };
export default real;

// ---------------------------------------------------------------- интерфейс pg-shim без единой сессии
const state = { db: null };
export function attachPglite(db) {
  state.db = db;
}
export function attachDrizzleScope() {}
export function fingerprint(text) {
  return String(text).replace(/\s+/g, ' ').trim().slice(0, 80);
}
export const allowList = {};
export const lockState = { holder: null, queue: [] };
export function shimSnapshot() {
  return { config: { ...shimConfig }, holder: null, waiting: [], running, stats: { ...shimStats, piggybackByKey: {} } };
}
export function rawParsers() {
  return {};
}
/** Под настоящим сервером замок сессии не нужен: соединения независимы. */
export function bossSessionLocked(_tag, _sql, fn) {
  return fn();
}
export function bossStatement(_text, _values, ownFn) {
  return ownFn();
}
export function setFatalHandler() {}
export function expectClosed() {}
export function pgliteDead() {
  return null;
}
export function reportPgliteError() {}
export function isPgliteFatal() {
  return false;
}
