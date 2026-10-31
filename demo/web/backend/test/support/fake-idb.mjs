// Fix round 2: минимальный IndexedDB в памяти для Node — ровно то, что используют IDBFS PGlite 0.3.16 (открытие с
// версией и onupgradeneeded, createObjectStore/createIndex, put/get/delete, index('timestamp').openKeyCursor()),
// readFence (open без версии с отменой upgrade) и IdbVolume (одна транзакция readwrite на снимок).
// Семантика, важная для тестов тома:
//   - put() клонирует значение СИНХРОННО (structuredClone в момент вызова), как IndexedDB;
//   - транзакции одной базы выполняются строго по очереди создания (строже IndexedDB: readonly тоже ждут);
//   - запись видна другим транзакциям и попадает в dump() только после commit; abort откатывает транзакцию целиком;
//   - commitDelayMs(tx) — «медленный диск», abortTx(tx) — сбой commit (QuotaExceeded и т. п.);
//   - dump() — «падение процесса»: только зафиксированное; createFakeIndexedDB({ from: dump }) — «новый запуск».
const tick = () => new Promise((r) => setImmediate(r));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const DELETED = Symbol('deleted');

function makeEvent(type, target, extra = {}) {
  return {
    type,
    target,
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true;
    },
    stopPropagation() {},
    ...extra,
  };
}
function fire(target, type, ev = makeEvent(type, target)) {
  const h = target[`on${type}`];
  if (typeof h === 'function') h.call(target, ev);
  return ev;
}
function domError(name, message = name) {
  const e = new Error(message);
  e.name = name;
  return e;
}
function cmpKey(a, b) {
  const va = a instanceof Date ? a.getTime() : a;
  const vb = b instanceof Date ? b.getTime() : b;
  if (typeof va === typeof vb) return va < vb ? -1 : va > vb ? 1 : 0;
  return typeof va < typeof vb ? -1 : 1;
}

class Request {
  constructor(source, tx) {
    this.source = source;
    this.transaction = tx;
    this.result = undefined;
    this.error = null;
    this.readyState = 'pending';
    this.onsuccess = null;
    this.onerror = null;
  }
}

class Store {
  constructor(rec, name, tx) {
    this.rec = rec;
    this.name = name;
    this.tx = tx;
  }
  get indexNames() {
    const names = [...this.rec.indexes.keys()];
    return { contains: (n) => this.rec.indexes.has(n), length: names.length, item: (i) => names[i] };
  }
  createIndex(name, keyPath) {
    this.rec.indexes.set(name, keyPath);
    return { name, keyPath };
  }
  visible() {
    const out = new Map(this.rec.data);
    const st = this.tx?.staged.get(this.name);
    if (st) for (const [k, v] of st) v === DELETED ? out.delete(k) : out.set(k, v);
    return out;
  }
  stage(key, value) {
    if (!this.tx || this.tx.mode === 'readonly') throw domError('ReadOnlyError');
    if (!this.tx.staged.has(this.name)) this.tx.staged.set(this.name, new Map());
    this.tx.staged.get(this.name).set(key, value);
  }
  put(value, key) {
    if (this.tx.finished || this.tx.aborted) throw domError('TransactionInactiveError');
    const clone = structuredClone(value); // синхронно, как IndexedDB
    this.tx.factory.stats.puts++;
    this.tx.factory.stats.putBytes += value?.contents?.byteLength ?? 0;
    return this.tx.request(this, () => {
      this.stage(key, clone);
      return key;
    });
  }
  delete(key) {
    if (this.tx.finished || this.tx.aborted) throw domError('TransactionInactiveError');
    this.tx.factory.stats.deletes++;
    return this.tx.request(this, () => {
      this.stage(key, DELETED);
      return undefined;
    });
  }
  get(key) {
    return this.tx.request(this, () => {
      const v = this.visible().get(key);
      return v === undefined ? undefined : structuredClone(v);
    });
  }
  index(name) {
    const keyPath = this.rec.indexes.get(name);
    if (!keyPath) throw domError('NotFoundError', `index ${name}`);
    const store = this;
    return {
      openKeyCursor() {
        let list = null;
        let i = 0;
        let req = null;
        const step = () => {
          if (!list) {
            list = [...store.visible().entries()].filter(([, v]) => v && v[keyPath] !== undefined).map(([k, v]) => ({ key: v[keyPath], primaryKey: k }));
            list.sort((a, b) => cmpKey(a.key, b.key) || cmpKey(a.primaryKey, b.primaryKey));
          }
          if (i >= list.length) return null;
          const e = list[i++];
          return {
            key: e.key,
            primaryKey: e.primaryKey,
            continue() {
              store.tx.requeue(req, step);
            },
          };
        };
        req = store.tx.request(store, step);
        return req;
      },
    };
  }
}

class Transaction {
  constructor(conn, names, mode, factory) {
    this.db = conn;
    this.names = names;
    this.mode = mode;
    this.factory = factory;
    this.seq = ++factory.txSeq;
    this.requests = [];
    this.staged = new Map();
    this.aborted = false;
    this.finished = false;
    this.error = null;
    this.oncomplete = null;
    this.onerror = null;
    this.onabort = null;
  }
  objectStore(name) {
    if (!this.names.includes(name)) throw domError('NotFoundError', `store ${name}`);
    return new Store(this.db.rec.stores.get(name), name, this);
  }
  request(source, exec) {
    const req = new Request(source, this);
    this.requests.push({ req, exec });
    return req;
  }
  requeue(req, exec) {
    req.readyState = 'pending';
    this.requests.push({ req, exec });
  }
  abort() {
    if (this.finished) throw domError('InvalidStateError');
    this.aborted = true;
    this.error ??= domError('AbortError', 'transaction aborted');
  }
}

class Connection {
  constructor(name, rec, factory) {
    this.name = name;
    this.rec = rec;
    this.factory = factory;
    this.closed = false;
  }
  get version() {
    return this.rec.version;
  }
  get objectStoreNames() {
    const names = [...this.rec.stores.keys()];
    return { contains: (n) => this.rec.stores.has(n), length: names.length, item: (i) => names[i] };
  }
  createObjectStore(name) {
    this.rec.stores.set(name, { data: new Map(), indexes: new Map() });
    return new Store(this.rec.stores.get(name), name, this.upgradeTx);
  }
  transaction(names, mode = 'readonly') {
    if (this.closed) throw domError('InvalidStateError', 'connection closed');
    const list = Array.isArray(names) ? names : [names];
    for (const n of list) if (!this.rec.stores.has(n)) throw domError('NotFoundError', `store ${n}`);
    const tx = new Transaction(this, list, mode, this.factory);
    this.factory.enqueue(this.name, tx);
    return tx;
  }
  close() {
    this.closed = true;
  }
}

/**
 * opts: { from?: dump(), commitDelayMs?: (tx) => мс, abortTx?: (tx) => boolean }.
 * Возвращает { indexedDB, dump(), stats, set(opts) }.
 */
export function createFakeIndexedDB(opts = {}) {
  const dbs = new Map();
  if (opts.from) {
    for (const [name, d] of Object.entries(opts.from)) {
      const stores = new Map();
      for (const [sn, s] of Object.entries(d.stores)) stores.set(sn, { data: new Map(s.data.map(([k, v]) => [k, structuredClone(v)])), indexes: new Map(s.indexes) });
      dbs.set(name, { version: d.version, stores });
    }
  }
  const factory = {
    txSeq: 0,
    queues: new Map(),
    running: new Map(),
    stats: { tx: 0, readwrite: 0, commits: 0, aborts: 0, puts: 0, putBytes: 0, deletes: 0, maxCommitDelayMs: 0 },
    commitDelayMs: opts.commitDelayMs ?? (() => 0),
    abortTx: opts.abortTx ?? (() => false),
    enqueue(name, tx) {
      if (!this.queues.has(name)) this.queues.set(name, []);
      this.queues.get(name).push(tx);
      this.stats.tx++;
      if (tx.mode === 'readwrite') this.stats.readwrite++;
      void this.pump(name);
    },
    async pump(name) {
      if (this.running.get(name)) return;
      this.running.set(name, true);
      try {
        const q = this.queues.get(name);
        while (q.length) {
          const tx = q.shift();
          await this.runTx(tx);
        }
      } finally {
        this.running.set(name, false);
      }
    },
    async runTx(tx) {
      await tick(); // запросы, созданные в той же задаче, что и транзакция
      for (;;) {
        if (tx.aborted) break;
        const r = tx.requests.shift();
        if (!r) {
          await tick(); // обработчики success могли добавить запросы
          if (tx.requests.length) continue;
          break;
        }
        try {
          r.req.result = r.exec();
          r.req.readyState = 'done';
          fire(r.req, 'success');
        } catch (e) {
          r.req.error = e;
          r.req.readyState = 'done';
          const ev = fire(r.req, 'error', makeEvent('error', r.req));
          if (!ev.defaultPrevented) fire(tx, 'error', ev);
          if (!ev.defaultPrevented) {
            tx.aborted = true;
            tx.error = e;
          }
        }
        await tick();
      }
      if (!tx.aborted && tx.mode === 'readwrite') {
        const d = Number(this.commitDelayMs(tx)) || 0;
        this.stats.maxCommitDelayMs = Math.max(this.stats.maxCommitDelayMs, d);
        if (d > 0) await sleep(d);
        if (this.abortTx(tx)) {
          tx.aborted = true;
          tx.error = domError('QuotaExceededError', 'fake: commit failed');
        }
      }
      tx.finished = true;
      if (tx.aborted) {
        this.stats.aborts++;
        fire(tx, 'abort', makeEvent('abort', tx));
        return;
      }
      for (const [sn, changes] of tx.staged) {
        const data = tx.db.rec.stores.get(sn).data;
        for (const [k, v] of changes) v === DELETED ? data.delete(k) : data.set(k, v);
      }
      this.stats.commits++;
      fire(tx, 'complete', makeEvent('complete', tx));
    },
  };
  const indexedDB = {
    open(name, version) {
      const req = new Request(null, null);
      req.onupgradeneeded = null;
      req.onblocked = null;
      setImmediate(() => {
        let rec = dbs.get(name);
        const existed = !!rec;
        const oldVersion = rec?.version ?? 0;
        const newVersion = version ?? (existed ? rec.version : 1);
        if (existed && newVersion < oldVersion) {
          req.error = domError('VersionError');
          fire(req, 'error');
          return;
        }
        if (!existed) {
          rec = { version: 0, stores: new Map() };
          dbs.set(name, rec);
        }
        const conn = new Connection(name, rec, factory);
        if (newVersion > oldVersion) {
          const utx = new Transaction(conn, [], 'versionchange', factory);
          utx.objectStore = (n) => new Store(rec.stores.get(n), n, utx);
          conn.upgradeTx = utx;
          req.result = conn;
          req.transaction = utx;
          fire(req, 'upgradeneeded', makeEvent('upgradeneeded', req, { oldVersion, newVersion }));
          conn.upgradeTx = null;
          if (utx.aborted) {
            if (!existed) dbs.delete(name);
            req.result = undefined;
            req.transaction = null;
            req.error = domError('AbortError', 'upgrade aborted');
            fire(req, 'error');
            return;
          }
          rec.version = newVersion;
          req.transaction = null;
        }
        req.result = conn;
        req.readyState = 'done';
        fire(req, 'success');
      });
      return req;
    },
    deleteDatabase(name) {
      const req = new Request(null, null);
      setImmediate(() => {
        dbs.delete(name);
        fire(req, 'success');
      });
      return req;
    },
    /** Review fixes: перечень баз (fence по именам баз-поколений). */
    databases() {
      return new Promise((resolve) => setImmediate(() => resolve([...dbs].map(([name, rec]) => ({ name, version: rec.version })))));
    },
  };
  return {
    indexedDB,
    stats: factory.stats,
    set(patch) {
      if (patch.commitDelayMs) factory.commitDelayMs = patch.commitDelayMs;
      if (patch.abortTx) factory.abortTx = patch.abortTx;
    },
    /** «Падение процесса»: только зафиксированное (structuredClone). */
    dump() {
      const out = {};
      for (const [name, rec] of dbs) {
        const stores = {};
        for (const [sn, s] of rec.stores) stores[sn] = { indexes: [...s.indexes], data: [...s.data].map(([k, v]) => [k, structuredClone(v)]) };
        out[name] = { version: rec.version, stores };
      }
      return out;
    },
    /** Записанное содержимое файла тома (или undefined). */
    file(dbName, path) {
      const v = dbs.get(dbName)?.stores.get('FILE_DATA')?.data.get(path);
      return v?.contents;
    },
  };
}
