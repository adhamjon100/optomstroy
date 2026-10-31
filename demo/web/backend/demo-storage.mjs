// Том PGlite и его сброс на диск (WP-B3 DemoStorage; fix round 2 — запись IndexedDB без замка сессии и без слота).
//
// Fix round 2 (сторож browser soak WP-T1: 37–38 ожиданий замка > 3 с за «demo.flush [SYNCFS …]»): IDBFS syncfs из
// Emscripten — многошаговый (обход файлов → асинхронное чтение списка из IndexedDB → транзакция записи → ожидание
// commit), поэтому WP-B3 выполнял его целиком под замком сессии pg-shim, а сброс после изменяющего запроса — ещё и в
// слоте единицы работы. Под нагрузкой на диск commit IndexedDB длится секундами (3,0–4,5 с в прогонах WP-T1 и fix
// round 1), и всё это время стояли опросы pg-boss и запросы приложения.
//
// Теперь запись тома IndexedDB (IdbVolume) — в два шага:
//  1. Снимок — синхронно, под замком сессии (миллисекунды): обход файлов MEMFS тома, сравнение mtime с индексом уже
//     записанного (кэш в памяти; полный список из IndexedDB читается только при первом сбросе и после сбоя — вне
//     замка) и put()/delete() всех изменённых файлов в ОДНУ транзакцию readwrite. put() клонирует значение синхронно
//     (structured clone в момент вызова), поэтому снимок — состояние всех файлов на одной границе операторов, как
//     «выключение питания» в этот момент; PostgreSQL восстанавливается по WAL так же, как после закрытия вкладки.
//  2. Ожидание commit — без замка; для изменяющей единицы работы — и после освобождения слота (work-gate
//     afterRelease): операторы и другие запросы идут дальше, а ответ изменяющего запроса уходит только после commit
//     (critic [4]).
// Сбросы идут по очереди (следующий снимок — после commit предыдущего), поэтому индекс отражает записанное; сбой
// commit (transaction abort — транзакция откатывается целиком) обнуляет индекс: следующий сброс сверяется с IndexedDB
// заново и дописывает всё. Ещё две поправки к IDBFS:
//  - после снимка — дождаться следующей миллисекунды Date.now() (≤ 1 мс): иначе запись в ту же миллисекунду дала бы
//    тот же mtime и файл не попал бы в следующий сброс (раньше это исключало только ожидание commit под замком);
//    если часы не идут — такие файлы помечаются «перезаписать в следующий раз»;
//  - FS.truncate Emscripten не обновлял mtime (MEMFS.setattr игнорирует `timestamp`): файл, только укороченный
//    (ftruncate PostgreSQL), IDBFS не видел — теперь mtime ставится.
// Запросы очереди сбросов, ещё не начатые, объединяются: снимок более позднего покрывает и их изменения.
// OPFS (opfs-ahp) пишет файлы сразу; его syncToFs (сброс дескрипторов и пул) — по-прежнему под замком (1–2 мс).
//
// Review fixes:
//  - итог сброса возвращается вызывающему как есть ({ms} | {error} | {fenced} | {skipped}); мост отвечает 503 на
//    изменяющий запрос, если его данные не дошли до диска (а не «успех», который пропадёт после F5);
//  - здоровье хранилища → странице сообщение `storage {ok:false, error, failures}` (плашка «Данные демо не
//    сохраняются…») после первого сбоя изменяющего сброса или двух фоновых подряд, `storage {ok:true}` — после
//    восстановления;
//  - durablePending()/durableIdle(): GET-ответ ждёт идущий изменяющий сброс (оплата, записанная задачей pg-boss, видна
//    приложению только после записи на диск);
//  - fencing: поколение И вкладка ({generation, tabId} страницы), повторная сверка под замком сессии прямо перед
//    снимком (вкладка, замороженная между проверкой и снимком, после разморозки не запишет устаревший том).
import * as pgShim from './alias/pg-shim.mjs';
import { FLUSH } from './demo-config.mjs';

const now = () => performance.now();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const round1 = (x) => Math.round(x * 10) / 10;

// ======================================================================== поколение тома (fence, WP-S1)
export const FENCE_DB = 'optomstroy-demo-fence';
/** Review fixes: поколение — имя пустой базы `optomstroy-demo-fence-g<поколение>-t<вкладка>` (demo-lock.js). */
export const FENCE_NAME_RE = /^optomstroy-demo-fence-g(\d+)-t([0-9a-z]+)$/;

/**
 * Поколение тома, записанное страницей: наибольшее из баз-поколений по indexedDB.databases() — БЕЗ транзакций
 * (review fixes: чтение хранилища fence воркером замороженной вкладки держало транзакцию readonly, и запись нового
 * поколения другой вкладкой ждала ~58 с); если таких баз нет (нет databases()) — прежнее хранилище fence. Только чтение.
 */
export async function readFence() {
  if (typeof indexedDB === 'undefined') return null;
  if (typeof indexedDB.databases === 'function') {
    try {
      let best = null;
      for (const d of await indexedDB.databases()) {
        const m = d?.name ? FENCE_NAME_RE.exec(d.name) : null;
        if (m && (!best || Number(m[1]) > best.generation)) best = { generation: Number(m[1]), tabId: m[2], source: 'name' };
      }
      if (best) return best;
    } catch {
      /* перечень недоступен — хранилище fence */
    }
  }
  return readFenceStore();
}

/** Прежний формат (WP-S1): IndexedDB optomstroy-demo-fence/fence/'generation'. Только чтение. */
export function readFenceStore() {
  if (typeof indexedDB === 'undefined') return Promise.resolve(null);
  return new Promise((resolve) => {
    let req;
    try {
      req = indexedDB.open(FENCE_DB);
    } catch {
      resolve(null);
      return;
    }
    // Базы нет — не создавать её (страница — единственный владелец fence): отмена версии 1.
    req.onupgradeneeded = () => {
      try {
        req.transaction.abort();
      } catch {
        /* ignore */
      }
    };
    req.onerror = () => resolve(null);
    req.onblocked = () => resolve(null);
    req.onsuccess = () => {
      const db = req.result;
      try {
        if (!db.objectStoreNames.contains('fence')) {
          db.close();
          resolve(null);
          return;
        }
        const g = db.transaction('fence', 'readonly').objectStore('fence').get('generation');
        g.onsuccess = () => {
          db.close();
          resolve(g.result ?? null);
        };
        g.onerror = () => {
          db.close();
          resolve(null);
        };
      } catch {
        try {
          db.close();
        } catch {
          /* ignore */
        }
        resolve(null);
      }
    };
  });
}

// ======================================================================== том IndexedDB (IDBFS PGlite)
const IDB_STORE = 'FILE_DATA'; // IDBFS.DB_STORE_NAME: ключ — путь, значение {timestamp, mode, contents?}, индекс timestamp

/**
 * Запись тома PGlite `idb://…` в IndexedDB снимком под замком и commit без замка (см. заголовок). Формат записей —
 * как у IDBFS Emscripten (PGlite читает его при открытии: initialSyncFs → syncfs(true)).
 */
export class IdbVolume {
  constructor(pglite) {
    this.FS = pglite.Module.FS;
    this.MEMFS = this.FS.filesystems.MEMFS;
    this.IDBFS = this.FS.filesystems.IDBFS;
    this.mount = this.findMount();
    /** IDBDatabase IDBFS (кэш IDBFS.dbs) и индекс записанного: путь → mtime в мс (NaN — «перезаписать»). */
    this.idb = null;
    this.index = null;
    this.stats = { captures: 0, emptyCaptures: 0, puts: 0, deletes: 0, bytes: 0, maxPutBytes: 0, maxCaptureMs: 0, commits: 0, maxCommitMs: 0, commitMsTotal: 0, aborts: 0, indexLoads: 0, uncertain: 0, truncates: 0 };
    this.patchTruncate();
  }

  findMount() {
    const FS = this.FS;
    for (const m of FS.getMounts(FS.root.mount)) if (m.type === this.IDBFS) return m;
    throw new Error('IdbVolume: точка монтирования IDBFS не найдена');
  }

  /** FS.truncate → setattr({size, timestamp}), а MEMFS.setattr понимает только mtime: без поправки mtime не меняется. */
  patchTruncate() {
    const FS = this.FS;
    if (FS.__posTruncatePatched) return;
    const orig = FS.truncate;
    const st = this.stats;
    FS.truncate = function (path, len) {
      const r = orig.call(this, path, len);
      try {
        const node = typeof path === 'string' ? FS.lookupPath(path, { follow: true }).node : path;
        node.mtime = node.ctime = Date.now();
        st.truncates++;
      } catch {
        /* узла нет — orig уже бросил бы */
      }
      return r;
    };
    FS.__posTruncatePatched = true;
  }

  /** Полный список записанного из IndexedDB (как IDBFS.getRemoteSet). Вне замка: IndexedDB меняет только этот том. */
  loadIndex() {
    return new Promise((resolve, reject) => {
      this.IDBFS.getRemoteSet(this.mount, (err, set) => {
        if (err) return reject(err instanceof Error ? err : new Error(String(err?.message ?? err)));
        this.idb = set.db;
        const index = new Map();
        for (const [p, e] of Object.entries(set.entries)) index.set(p, +e.timestamp);
        this.index = index;
        this.stats.indexLoads++;
        resolve(index.size);
      });
    });
  }

  /** Все файлы и каталоги тома (как IDBFS.getLocalSet, но с stat). */
  walk() {
    const FS = this.FS;
    const out = new Map();
    const kids = (dir) => FS.readdir(dir).filter((n) => n !== '.' && n !== '..').map((n) => `${dir}/${n}`);
    const stack = kids(this.mount.mountpoint);
    while (stack.length) {
      const p = stack.pop();
      const st = FS.stat(p);
      if (FS.isDir(st.mode)) stack.push(...kids(p));
      out.set(p, st);
    }
    return out;
  }

  /**
   * Снимок — СИНХРОННО (вызывать под замком сессии): put/delete изменённого в одну транзакцию readwrite.
   * Возвращает { puts, deletes, bytes, uncertain, captureMs, committed: Promise<{ok, ms, error?}> }.
   */
  capture() {
    if (!this.index || !this.idb) throw new Error('IdbVolume: индекс не загружен');
    const t0 = now();
    const FS = this.FS;
    const local = this.walk();
    const puts = [];
    for (const [p, st] of local) {
      const known = this.index.get(p);
      if (known === undefined || known !== +st.mtime) puts.push(p);
    }
    const dels = [];
    for (const p of this.index.keys()) if (!local.has(p)) dels.push(p);
    // Следующая миллисекунда: запись после снимка получит mtime ≥ T1 > mtime снятого.
    const T0 = Date.now();
    const spin0 = now();
    while (Date.now() <= T0 && now() - spin0 < 3) {
      /* ≤ 1 мс */
    }
    const T1 = Date.now();
    const next = new Map();
    let uncertain = 0;
    for (const [p, st] of local) {
      const m = +st.mtime;
      if (m >= T1) {
        next.set(p, Number.NaN);
        uncertain++;
      } else next.set(p, m);
    }
    let tx = null;
    let bytes = 0;
    let maxPut = 0;
    if (puts.length || dels.length) {
      tx = this.idb.transaction([IDB_STORE], 'readwrite');
      const store = tx.objectStore(IDB_STORE);
      try {
        puts.sort(); // каталоги раньше вложенных файлов, как в IDBFS.reconcile
        for (const p of puts) {
          const st = local.get(p);
          if (FS.isDir(st.mode)) store.put({ timestamp: st.mtime, mode: st.mode }, p);
          else if (FS.isFile(st.mode)) {
            const v = this.MEMFS.getFileDataAsTypedArray(FS.lookupPath(p, { follow: true }).node);
            // Клон вида копирует ВЕСЬ его буфер (ёмкость MEMFS бывает больше длины файла) — копия точной длины.
            const contents = v.byteOffset === 0 && v.byteLength === v.buffer.byteLength ? v : v.slice();
            bytes += contents.byteLength;
            maxPut = Math.max(maxPut, contents.byteLength);
            store.put({ timestamp: st.mtime, mode: st.mode, contents }, p);
          } else throw new Error(`IdbVolume: тип файла ${st.mode} не поддерживается: ${p}`);
        }
        dels.sort().reverse();
        for (const p of dels) store.delete(p);
      } catch (e) {
        try {
          tx.abort();
        } catch {
          /* ignore */
        }
        this.index = null;
        throw e;
      }
    }
    this.index = next;
    const captureMs = now() - t0;
    const s = this.stats;
    s.captures++;
    if (!tx) s.emptyCaptures++;
    s.puts += puts.length;
    s.deletes += dels.length;
    s.bytes += bytes;
    s.maxPutBytes = Math.max(s.maxPutBytes, maxPut);
    s.uncertain += uncertain;
    s.maxCaptureMs = Math.max(s.maxCaptureMs, round1(captureMs));
    const committed = !tx
      ? Promise.resolve({ ok: true, ms: 0, empty: true })
      : new Promise((resolve) => {
          const tc = now();
          tx.oncomplete = () => resolve({ ok: true, ms: now() - tc });
          // Ошибка запроса всплывает в транзакцию; без preventDefault транзакция откатывается целиком → onabort.
          tx.onabort = () => resolve({ ok: false, ms: now() - tc, error: String(tx.error?.message ?? tx.error?.name ?? 'transaction abort') });
        });
    return { puts: puts.length, deletes: dels.length, bytes, uncertain, captureMs, committed };
  }

  /** Итог commit: учёт; при сбое индекс обнуляется (следующий сброс сверится с IndexedDB). */
  settle(res) {
    const s = this.stats;
    if (res.empty) return;
    s.commits++;
    s.commitMsTotal += res.ms;
    s.maxCommitMs = Math.max(s.maxCommitMs, Math.round(res.ms));
    if (!res.ok) {
      s.aborts++;
      this.index = null;
    }
  }
}

// ======================================================================== том демо и сброс на диск
/**
 * Том PGlite и его сброс на диск. PGlite с relaxedDurability не ждёт syncToFs (ответ мог уйти раньше записи в
 * IndexedDB — critic [4]); здесь его вызов после каждого оператора только отмечает «есть изменения», а запись
 * делает flush(): после изменяющей единицы работы — до ответа (после освобождения слота), фоном — не чаще
 * FLUSH.backgroundMs. Перед КАЖДОЙ записью сверяется поколение тома (fencing WP-S1): если страница отдала том другой
 * вкладке — запись не делается, странице уходит `fenced`, фоновые задачи останавливаются.
 */
export class DemoStorage {
  /**
   * testCommitDelayMs — только тесты (init.testFlushCommitDelayMs): «медленный commit IndexedDB»;
   * testFailures — только тесты (init.testFlushFailures, control config): столько следующих сбросов вернут {error}.
   */
  constructor({ kind, dbName, generation, tabId = null, post, log, testCommitDelayMs = 0, testFailures = 0 }) {
    this.kind = kind;
    this.dbName = dbName;
    this.generation = generation;
    this.tabId = tabId ?? null;
    this.testFailures = Number(testFailures) > 0 ? Number(testFailures) : 0;
    /** Изменяющие сбросы в работе (вызван flush(durable) и ещё не завершён) — GET-ответы ждут их (durableIdle). */
    this.durableSet = new Set();
    /** Здоровье записи: подряд неудачных сбросов, сообщено ли странице. */
    this.health = { consecutiveFailures: 0, reported: false, lastError: null, lastOkAt: null, lastErrorAt: null };
    this.post = post;
    this.log = log;
    this.testCommitDelayMs = Number(testCommitDelayMs) > 0 ? Number(testCommitDelayMs) : 0;
    this.db = null;
    this.volume = null;
    this.dirty = false;
    this.fenced = false;
    this.closed = false;
    this.chain = Promise.resolve();
    this.queued = null;
    this.timer = null;
    this.onFenced = null;
    this.stats = {
      flushes: 0,
      durable: 0,
      background: 0,
      skippedClean: 0,
      coalesced: 0,
      totalMs: 0,
      maxMs: 0,
      lastMs: 0,
      /** Удержание замка сессии сбросом (снимок IndexedDB / syncToFs OPFS) — fix round 2. */
      lockMsTotal: 0,
      maxLockMs: 0,
      fenceChecks: 0,
      fenceRefused: 0,
      /** Поколение совпало, но запись fence — другой вкладки ({generation, tabId} страницы). */
      fenceTabMismatch: 0,
      /** Сверки под замком сессии непосредственно перед снимком/syncToFs. */
      fenceLockedChecks: 0,
      errors: 0,
      durableErrors: 0,
      healthReports: 0,
      byReason: {},
      pgliteSyncCalls: 0,
      testCommitDelayMs: this.testCommitDelayMs,
      idb: null,
    };
  }

  attach(db) {
    this.db = db;
    // Вызов PGlite после каждого оператора (execProtocol → syncToFs): только отметка; запись — flush().
    db.syncToFs = async () => {
      this.stats.pgliteSyncCalls++;
      this.dirty = true;
    };
    if (this.kind === 'idb') {
      this.volume = new IdbVolume(db);
      this.stats.idb = this.volume.stats;
    }
  }

  startBackground() {
    const every = FLUSH.backgroundMs[this.kind] ?? 0;
    if (!every || this.timer) return;
    this.timer = setInterval(() => {
      if (this.dirty && !this.closed && !this.fenced) void this.flush('background', { durable: false });
    }, every);
    this.timer.unref?.();
  }

  stopBackground() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  /** Запись fence страницы {generation, tabId} разрешает запись этой вкладке? (нет fence — разрешает.) */
  fenceMatches(f) {
    if (!f || f.generation === undefined) return true;
    if (f.generation !== this.generation) return false;
    // Review fixes: то же поколение у другой вкладки (поколение когда-то начиналось заново после сброса) — не наш том.
    if (this.tabId && f.tabId && f.tabId !== this.tabId) {
      this.stats.fenceTabMismatch++;
      return false;
    }
    return true;
  }

  /** Отметить перехват тома: запись запрещена, странице — `fenced`, точке входа — onFenced. */
  markFenced(f) {
    if (this.fenced) return;
    this.fenced = true;
    this.stats.fenceRefused++;
    this.log('warn', `том перехвачен другой вкладкой: поколение ${this.generation}/${this.tabId ?? '—'} ≠ ${f?.generation}/${f?.tabId ?? '—'}; запись на диск остановлена`);
    this.post({ type: 'fenced', generation: this.generation, volumeGeneration: f?.generation ?? null, tabId: this.tabId, volumeTabId: f?.tabId ?? null });
    try {
      this.onFenced?.();
    } catch {
      /* ignore */
    }
  }

  /** Поколение тома совпадает с поколением этой вкладки (нет fence — совпадает). */
  async fenceOk() {
    if (this.fenced) return false;
    if (this.generation === undefined || this.generation === null) return true;
    this.stats.fenceChecks++;
    const f = await readFence();
    if (this.fenceMatches(f)) return true;
    this.markFenced(f);
    return false;
  }

  /** Та же сверка под замком сессии (вызывать внутри bossSessionLocked, прямо перед записью тома). */
  async fenceOkLocked() {
    if (this.fenced) return false;
    if (this.generation === undefined || this.generation === null) return true;
    this.stats.fenceLockedChecks++;
    const f = await readFence();
    if (this.fenceMatches(f)) return true;
    this.markFenced(f);
    return false;
  }

  /** Изменяющие сбросы ещё идут? (GET-ответ моста подождёт их.) */
  durablePending() {
    return this.durableSet.size > 0;
  }

  /** Промис: все изменяющие сбросы, начатые к этому моменту, завершились (успехом или нет). */
  durableIdle() {
    if (!this.durableSet.size) return Promise.resolve();
    return Promise.allSettled([...this.durableSet]).then(() => undefined);
  }

  /** Итог сброса → здоровье хранилища и сообщение странице (плашка «Данные демо не сохраняются»). */
  noteHealth(out, durable) {
    const h = this.health;
    if (out && out.error) {
      h.consecutiveFailures++;
      h.lastError = String(out.error).slice(0, 300);
      h.lastErrorAt = new Date().toISOString();
      if (durable) this.stats.durableErrors++;
      if (!h.reported && (durable || h.consecutiveFailures >= 2)) {
        h.reported = true;
        this.stats.healthReports++;
        this.post({ type: 'storage', ok: false, error: h.lastError, failures: h.consecutiveFailures, kind: this.kind });
      }
      return;
    }
    if (out && out.ms !== undefined) {
      h.consecutiveFailures = 0;
      h.lastOkAt = new Date().toISOString();
      if (h.reported) {
        h.reported = false;
        this.stats.healthReports++;
        this.post({ type: 'storage', ok: true, kind: this.kind });
      }
    }
  }

  /**
   * Записать том на диск. durable — после изменяющей единицы/по запросу страницы (учёт отдельно от фоновых).
   * Сбросы идут по очереди; ещё не начатый сброс из очереди переиспользуется (его снимок будет позже — он покрывает и
   * изменения нового вызывающего). Промис — после commit: { ms, files?, bytes?, lockMs?, skipped?, fenced?, error? }.
   */
  flush(reason, { durable = true } = {}) {
    const q = this.queued;
    if (q) {
      this.stats.coalesced++;
      if (durable && !q.durable) {
        q.durable = true;
        this.trackDurable(q.promise);
      }
      return q.promise;
    }
    const job = { reason, durable, promise: null };
    const run = async () => {
      if (this.queued === job) this.queued = null;
      if (this.closed || !this.db) return { skipped: 'closed' };
      if (this.testFailures > 0) {
        // Только тесты: «браузер не дал записать» (квота, отказ IndexedDB) — до проверки вида хранилища.
        this.testFailures--;
        this.stats.errors++;
        const out = { error: 'тест: запись тома отклонена (testFlushFailures)' };
        this.noteHealth(out, job.durable);
        return out;
      }
      if (this.kind === 'memory') {
        if (this.health.reported) this.noteHealth({ ms: 0 }, job.durable); // тест сбоя на memory: восстановление
        return { skipped: 'memory' };
      }
      if (!job.durable && !this.dirty) {
        this.stats.skippedClean++;
        return { skipped: 'clean' };
      }
      if (!(await this.fenceOk())) return { fenced: true };
      const t = now();
      this.dirty = false;
      let out;
      try {
        out = this.volume ? await this.flushIdb(job.reason) : await this.flushLocked(job.reason);
      } catch (e) {
        this.dirty = true;
        this.stats.errors++;
        pgShim.reportPgliteError(e);
        this.log('error', `сброс PGlite на диск (${job.reason}): ${e?.stack ?? e}`);
        const res = { error: String(e?.message ?? e) };
        this.noteHealth(res, job.durable);
        return res;
      }
      if (out?.fenced) return { fenced: true };
      const d = now() - t;
      this.stats.flushes++;
      if (job.durable) this.stats.durable++;
      else this.stats.background++;
      this.stats.totalMs += d;
      this.stats.maxMs = Math.max(this.stats.maxMs, Math.round(d));
      this.stats.lastMs = round1(d);
      const k = String(job.reason).split(':')[0];
      this.stats.byReason[k] = (this.stats.byReason[k] ?? 0) + 1;
      const res = { ms: round1(d), ...out };
      this.noteHealth(res, job.durable);
      return res;
    };
    job.promise = this.chain.then(run, run);
    this.queued = job;
    this.chain = job.promise.catch(() => undefined);
    if (durable) this.trackDurable(job.promise);
    return job.promise;
  }

  /** Учесть изменяющий сброс до его завершения (синхронно: следующая единица работы уже видит его). */
  trackDurable(p) {
    this.durableSet.add(p);
    const done = () => this.durableSet.delete(p);
    p.then(done, done);
  }

  noteLock(ms) {
    this.stats.lockMsTotal += ms;
    this.stats.maxLockMs = Math.max(this.stats.maxLockMs, round1(ms));
  }

  /** OPFS (и прочее не-IndexedDB): syncToFs PGlite под замком сессии; fence сверяется под тем же замком. */
  async flushLocked(reason) {
    let tl = 0;
    let fenced = false;
    await pgShim.bossSessionLocked('demo.flush', `SYNCFS ${reason}`, async () => {
      tl = now();
      try {
        if (!(await this.fenceOkLocked())) {
          fenced = true;
          return;
        }
        await this.db.fs.syncToFs(false);
      } finally {
        this.noteLock(now() - tl);
      }
    });
    if (fenced) return { fenced: true };
    return { lockMs: round1(now() - tl) };
  }

  /** IndexedDB: индекс (вне замка) → снимок под замком (синхронно) → commit без замка. */
  async flushIdb(reason) {
    const v = this.volume;
    if (!v.index) await v.loadIndex();
    let cap = null;
    let lockMs = 0;
    let fenced = false;
    await pgShim.bossSessionLocked('demo.flush', `IDB CAPTURE ${reason}`, async () => {
      const tl = now();
      try {
        // Review fixes: fence ещё раз — уже под замком (чтение IndexedDB ~1–3 мс): вкладка, замороженная между
        // проверкой во flush() и снимком (или ждавшая замок за открытой транзакцией), не допишет устаревшие файлы
        // поверх тома вкладки, которая его перехватила.
        if (!(await this.fenceOkLocked())) {
          fenced = true;
          return;
        }
        cap = v.capture(); // синхронно: между снимком и освобождением замка операторов нет
      } finally {
        lockMs = now() - tl;
        this.noteLock(lockMs);
      }
    });
    if (fenced) return { fenced: true };
    const res = await cap.committed; // без замка
    if (this.testCommitDelayMs && !res.empty) await sleep(this.testCommitDelayMs);
    v.settle(res);
    if (!res.ok) throw new Error(`IndexedDB: транзакция записи тома откатилась (${res.error}); следующий сброс сверит том заново`);
    return { files: cap.puts, deletes: cap.deletes, bytes: cap.bytes, lockMs: round1(lockMs), commitMs: Math.round(res.ms) };
  }

  async close() {
    this.stopBackground();
    if (this.closed || !this.db) return;
    await this.flush('close');
    this.closed = true;
    await this.db.close().catch((e) => this.log('warn', `PGlite close: ${e?.message ?? e}`));
  }
}
