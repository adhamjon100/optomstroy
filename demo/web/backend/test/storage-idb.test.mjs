// Fix round 2: том IndexedDB (demo-storage.mjs: DemoStorage + IdbVolume) — снимок под замком сессии, commit без замка.
// Настоящий PGlite 0.3.16 (копия сайта) на IDBFS поверх IndexedDB в памяти (support/fake-idb.mjs: put клонирует
// синхронно, транзакции по очереди, commit с задержкой или сбоем, dump() — «падение процесса»). Проверяется:
//   - сброс держит замок сессии миллисекунды, медленный commit (1,2 с) ждёт только вызывающий сброс; операторы
//     идут во время commit; ещё не начатые сбросы из очереди объединяются;
//   - запись в ту же миллисекунду сразу после снимка не теряется (следующая мс Date.now()); укорочение файла без
//     записи (ftruncate VACUUM) попадает в следующий сброс (mtime после FS.truncate);
//   - сбой commit (transaction abort): ошибка сброса, индекс обнулён, следующий сброс дописывает всё;
//   - «падение» в любой момент под нагрузкой (фоновые сбросы каждые 7 мс, случайные задержки commit, CHECKPOINT,
//     UPDATE, VACUUM): после перезапуска PostgreSQL восстанавливается, все подтверждённые сбросом строки на месте,
//     индекс и куча согласованы.
//   node --test demo/web/backend/test/storage-idb.test.mjs
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { after, before, describe, test } from 'node:test';
import { pathToFileURL } from 'node:url';
import { OUT } from '../lib/paths.mjs';
import { bundleForTest } from './support/bundle-for-test.mjs';
import { createFakeIndexedDB } from './support/fake-idb.mjs';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const PGLITE = `${OUT}/pglite/index.js`;
const DBNAME = 'fix2-volume';
const IDBNAME = `/pglite/${DBNAME}`;
let m;
let PGlite;
let fake;
let db;
let pool;
let storage;
const logs = [];
const snapshots = [];

before(async () => {
  if (!existsSync(PGLITE)) throw new Error(`нет ${PGLITE}: сначала node demo/web/backend/build-backend.mjs`);
  m = await bundleForTest(
    'storage-idb',
    `export { DemoStorage, IdbVolume } from './demo-storage.mjs';
     export * as pg from './alias/pg-shim.mjs';`,
  );
  globalThis.__posDemoLog = (lv, msg) => logs.push(`${lv} ${msg}`);
  fake = createFakeIndexedDB();
  globalThis.indexedDB = fake.indexedDB;
  ({ PGlite } = await import(pathToFileURL(PGLITE).href));
  db = await PGlite.create(`idb://${DBNAME}`, { relaxedDurability: true });
  storage = new m.DemoStorage({ kind: 'idb', dbName: DBNAME, generation: undefined, post: () => {}, log: (lv, msg) => logs.push(`${lv} ${msg}`) });
  storage.attach(db);
  m.pg.attachPglite(db);
  pool = new m.pg.Pool({ application_name: 'storage-idb-test' });
  await pool.query(`CREATE TABLE t (id int PRIMARY KEY, v text NOT NULL)`);
  const r = await storage.flush('init');
  assert.ok(!r.error, JSON.stringify(r));
});
after(async () => {
  await db?.close().catch(() => undefined);
  setTimeout(() => process.exit(), 300).unref();
});

/** «Новый запуск» на сохранённом IndexedDB: PostgreSQL восстанавливается; что в таблицах. */
async function restore(dump, fn) {
  const f2 = createFakeIndexedDB({ from: dump });
  const prev = globalThis.indexedDB;
  globalThis.indexedDB = f2.indexedDB;
  let db2;
  try {
    db2 = await PGlite.create(`idb://${DBNAME}`);
    return await fn(db2);
  } finally {
    await db2?.close().catch(() => undefined);
    globalThis.indexedDB = prev;
  }
}
const ids = async (d) => new Set((await d.query('SELECT id FROM t')).rows.map((r) => r.id));
const missing = (acked, have) => [...acked].filter((x) => !have.has(x));

describe('том IndexedDB: снимок под замком, commit без замка', () => {
  test('медленный commit (1,2 с) не держит замок сессии; ответ сброса — после commit; очередь объединяется', async () => {
    await pool.query(`INSERT INTO t SELECT g, 'a' FROM generate_series(1, 200) g`);
    const s0 = { ...m.pg.shimStats };
    fake.set({ commitDelayMs: () => 1200 });
    try {
      const t0 = performance.now();
      const f1 = storage.flush('t:slow');
      await sleep(40);
      const tq = performance.now();
      const n = (await pool.query('SELECT count(*)::int AS n FROM t')).rows[0].n;
      const queryMs = performance.now() - tq;
      await pool.query(`UPDATE t SET v = 'b' WHERE id <= 10`);
      const tu = performance.now() - tq;
      const c0 = storage.stats.coalesced;
      const f2 = storage.flush('t:next');
      const f3 = storage.flush('t:joined');
      const r1 = await f1;
      const d1 = performance.now() - t0;
      const [r2, r3] = await Promise.all([f2, f3]);
      assert.equal(n, 200);
      assert.ok(!r1.error && !r2.error, JSON.stringify({ r1, r2 }));
      assert.ok(queryMs < 300 && tu < 600, `оператор во время commit: SELECT ${queryMs.toFixed(1)} мс, +UPDATE ${tu.toFixed(1)} мс`);
      assert.ok(d1 >= 1150, `сброс завершён после commit: ${d1.toFixed(0)} мс`);
      assert.ok(r1.lockMs < 300, `замок держится только на снимок: ${r1.lockMs} мс`);
      assert.ok(r1.files > 0 && r2.files > 0, `файлы: ${r1.files}, ${r2.files}`);
      assert.equal(storage.stats.coalesced - c0, 1, 'третий сброс присоединился к ещё не начатому второму');
      assert.equal(r3, r2, 'тот же результат');
      assert.equal(m.pg.shimStats.waitsOver1s - s0.waitsOver1s, 0, 'ни одного ожидания замка > 1 с');
      assert.ok(storage.stats.maxLockMs < 300, `maxLockMs ${storage.stats.maxLockMs}`);
    } finally {
      fake.set({ commitDelayMs: () => 0 });
    }
  });

  test('запись сразу после снимка (та же миллисекунда) попадает в следующий сброс', async () => {
    const FS = db.Module.FS;
    const path = `${storage.volume.mount.mountpoint}/fix2-same-ms.bin`;
    FS.writeFile(path, new Uint8Array([1]));
    assert.ok(!(await storage.flush('t:ms0')).error);
    const v = storage.volume;
    const orig = v.capture;
    // Запись прямо перед снимком и сразу после него в ОДНУ миллисекунду (часы заморожены на время снимка — как очень
    // быстрый снимок): mtime обеих записей совпадает, и без защиты вторая запись потерялась бы. Часы не идут —
    // ожидание следующей миллисекунды не помогает, файл помечается «перезаписать в следующий раз».
    const realNow = Date.now;
    const frozen = realNow();
    const u0 = v.stats.uncertain;
    v.capture = function () {
      Date.now = () => frozen;
      try {
        FS.writeFile(path, new Uint8Array([2, 2]));
        const c = orig.call(this);
        FS.writeFile(path, new Uint8Array([3, 3, 3]));
        return c;
      } finally {
        Date.now = realNow;
      }
    };
    try {
      assert.ok(!(await storage.flush('t:ms1')).error);
    } finally {
      v.capture = orig;
    }
    assert.ok(v.stats.uncertain > u0, 'файл той же миллисекунды помечен «перезаписать»');
    assert.deepEqual([...fake.file(IDBNAME, path)], [2, 2], 'снимок — состояние на момент снимка');
    assert.ok(!(await storage.flush('t:ms2')).error);
    assert.deepEqual([...fake.file(IDBNAME, path)], [3, 3, 3], 'запись после снимка — в следующем сбросе');
    FS.unlink(path);
    assert.ok(!(await storage.flush('t:ms3')).error);
    assert.equal(fake.file(IDBNAME, path), undefined, 'удалённый файл удалён и из IndexedDB');
  });

  test('укорочение без записи (FS.truncate, ftruncate VACUUM) попадает в следующий сброс', async () => {
    const FS = db.Module.FS;
    const path = `${storage.volume.mount.mountpoint}/fix2-trunc.bin`;
    FS.writeFile(path, new Uint8Array(1000).fill(7));
    assert.ok(!(await storage.flush('t:tr0')).error);
    assert.equal(fake.file(IDBNAME, path).length, 1000);
    await sleep(2);
    FS.truncate(path, 10);
    assert.ok(!(await storage.flush('t:tr1')).error);
    assert.equal(fake.file(IDBNAME, path).length, 10);
    FS.unlink(path);
    // ftruncate из PostgreSQL: VACUUM укорачивает пустую кучу до 0 страниц
    const tr0 = storage.volume.stats.truncates;
    await pool.query(`CREATE TABLE tt AS SELECT g FROM generate_series(1, 20000) g`);
    assert.ok(!(await storage.flush('t:tt0')).error);
    await pool.query('DELETE FROM tt');
    await pool.query('VACUUM tt');
    assert.ok(storage.volume.stats.truncates > tr0, `ftruncate PostgreSQL прошёл через FS.truncate: ${storage.volume.stats.truncates - tr0}`);
    assert.ok(!(await storage.flush('t:tt1')).error);
    const relPath = (await pool.query(`SELECT pg_relation_filepath('tt') AS p`)).rows[0].p;
    const stored = fake.file(IDBNAME, `${storage.volume.mount.mountpoint}/${relPath}`);
    assert.equal(stored?.length ?? -1, 0, `куча tt в IndexedDB укорочена до 0 (${relPath})`);
  });

  test('сбой commit: ошибка сброса, индекс обнулён; следующий сброс дописывает всё', async () => {
    let fail = true;
    fake.set({
      abortTx: (tx) => {
        if (tx.mode !== 'readwrite' || !fail) return false;
        fail = false;
        return true;
      },
    });
    try {
      await pool.query(`INSERT INTO t SELECT g, 'd' FROM generate_series(1001, 1100) g`);
      const a0 = storage.volume.stats.aborts;
      const r = await storage.flush('t:fail');
      assert.ok(r.error, `сброс сообщает об ошибке: ${JSON.stringify(r)}`);
      assert.equal(storage.volume.stats.aborts - a0, 1);
      assert.equal(storage.volume.index, null, 'индекс обнулён');
      assert.equal(storage.dirty, true);
      const r2 = await storage.flush('t:repair');
      assert.ok(!r2.error && r2.files > 0, JSON.stringify(r2));
      snapshots.push({ label: 'после сбоя', dump: fake.dump(), acked: new Set([...Array(100)].map((_, i) => 1001 + i)) });
    } finally {
      fake.set({ abortTx: () => false });
    }
  });

  test('«падение» в любой момент под нагрузкой: PostgreSQL восстанавливается, подтверждённое на месте', async () => {
    fake.set({ commitDelayMs: () => Math.random() * 25 });
    let bgCalls = 0;
    const cap0 = storage.volume.stats.captures;
    const bg = setInterval(() => {
      bgCalls++;
      void storage.flush('background', { durable: false });
    }, 7);
    const acked = new Set([...Array(200)].map((_, i) => i + 1));
    for (let i = 1001; i <= 1100; i++) acked.add(i);
    let pending = [];
    let id = 10000;
    try {
      for (let i = 0; i < 90; i++) {
        const batch = [];
        for (let j = 0; j < 5; j++) batch.push(++id);
        await pool.query(`INSERT INTO t SELECT x, repeat('e', 400) FROM unnest($1::int[]) x`, [batch]);
        pending.push(...batch);
        if (i % 10 === 3) await pool.query('CHECKPOINT');
        if (i % 17 === 5) await pool.query(`UPDATE t SET v = v || 'u' WHERE id % 7 = 0`);
        if (i % 29 === 11) await pool.query('VACUUM t');
        if (i % 3 === 0) {
          const mine = pending;
          pending = [];
          const r = await storage.flush('t:durable');
          assert.ok(!r.error, JSON.stringify(r));
          for (const x of mine) acked.add(x);
        }
        if (i % 30 === 17) snapshots.push({ label: `шаг ${i}`, dump: fake.dump(), acked: new Set(acked) });
      }
    } finally {
      clearInterval(bg);
    }
    const r = await storage.flush('t:final');
    assert.ok(!r.error);
    for (const x of pending) acked.add(x);
    snapshots.push({ label: 'конец', dump: fake.dump(), acked: new Set(acked) });
    fake.set({ commitDelayMs: () => 0 });
    const caps = storage.volume.stats.captures - cap0;
    assert.ok(bgCalls > 10 && caps >= 31, `фоновые сбросы шли вперемежку: вызовов ${bgCalls}, снимков ${caps}, объединено ${storage.stats.coalesced}`);

    for (const s of snapshots) {
      const res = await restore(s.dump, async (d) => {
        const have = await ids(d);
        await d.exec('SET enable_seqscan = off');
        const viaIndex = (await d.query('SELECT count(*)::int AS n FROM t WHERE id > 0')).rows[0].n;
        await d.exec('SET enable_seqscan = on; SET enable_indexscan = off; SET enable_bitmapscan = off; SET enable_indexonlyscan = off');
        const viaHeap = (await d.query('SELECT count(*)::int AS n FROM t WHERE id > 0')).rows[0].n;
        const tt = (await d.query(`SELECT pg_relation_size('tt')::int AS n`).catch(() => ({ rows: [{ n: null }] }))).rows[0].n;
        return { have, viaIndex, viaHeap, tt };
      });
      const lost = missing(s.acked, res.have);
      assert.deepEqual(lost.slice(0, 10), [], `${s.label}: потеряны подтверждённые строки (${lost.length})`);
      assert.equal(res.viaIndex, res.viaHeap, `${s.label}: индекс и куча согласованы`);
      assert.equal(res.viaHeap, res.have.size);
      if (res.tt !== null) assert.equal(res.tt, 0, `${s.label}: tt укорочена`);
    }
  });
});

// Review fixes (fencing, IndexedDB): запись fence страницы {generation, tabId} сверяется целиком (то же поколение у
// другой вкладки — не наш том) и ещё раз под замком сессии прямо перед снимком (вкладка, замороженная между проверкой
// и снимком, не допишет устаревшие файлы поверх тома вкладки, которая его перехватила).
describe('fencing: поколение и вкладка; сверка под замком перед снимком', () => {
  const FENCE = 'optomstroy-demo-fence';
  const writeFence = (rec) =>
    new Promise((resolve, reject) => {
      const req = globalThis.indexedDB.open(FENCE, 1);
      req.onupgradeneeded = () => req.result.createObjectStore('fence');
      req.onerror = () => reject(req.error);
      req.onsuccess = () => {
        const c = req.result;
        const tx = c.transaction('fence', 'readwrite');
        tx.objectStore('fence').put({ ...rec, at: Date.now() }, 'generation');
        tx.oncomplete = () => {
          c.close();
          resolve();
        };
        tx.onabort = () => reject(tx.error);
      };
    });
  const mk = (generation, tabId, posts) => {
    const s = new m.DemoStorage({ kind: 'idb', dbName: DBNAME, generation, tabId, post: (x) => posts.push(x), log: (lv, msg) => logs.push(`${lv} ${msg}`) });
    s.attach(db);
    return s;
  };

  test('своя запись fence → сброс идёт; то же поколение, другая вкладка → {fenced}, `fenced` странице, на диск ничего', async () => {
    const posts = [];
    const s = mk(5, 'tab-A', posts);
    await writeFence({ generation: 5, tabId: 'tab-A' });
    await pool.query(`INSERT INTO t VALUES (90001, 'fence-ok')`);
    const ok = await s.flush('t:fence-ok');
    assert.ok(!ok.error && !ok.fenced && ok.files > 0, JSON.stringify(ok));
    await writeFence({ generation: 5, tabId: 'tab-B' });
    await pool.query(`INSERT INTO t VALUES (90002, 'fence-tab')`);
    const c0 = fake.stats.commits;
    const r = await s.flush('t:fence-tab');
    assert.deepEqual(r, { fenced: true });
    assert.equal(fake.stats.commits, c0, 'commit не было');
    assert.ok(s.stats.fenceTabMismatch >= 1);
    assert.ok(posts.some((p) => p.type === 'fenced' && p.volumeTabId === 'tab-B'), JSON.stringify(posts));
    assert.deepEqual(await s.flush('t:after'), { fenced: true }, 'после перехвата запись запрещена');
  });

  test('fence по именам баз-поколений: запись новой базы не ждёт «замороженного» читателя хранилища fence; воркер видит её без транзакций', async () => {
    const posts = [];
    const s = mk(8, 'tabe', posts);
    const mkGen = (g, t) =>
      new Promise((resolve, reject) => {
        const req = globalThis.indexedDB.open(`optomstroy-demo-fence-g${g}-t${t}`, 1);
        req.onsuccess = () => {
          req.result.close();
          resolve();
        };
        req.onerror = () => reject(req.error);
      });
    await mkGen(8, 'tabe');
    await pool.query(`INSERT INTO t VALUES (90010, 'names-ok')`);
    const ok = await s.flush('t:names-ok');
    assert.ok(!ok.error && !ok.fenced, JSON.stringify(ok));
    // «замороженная вкладка»: транзакция readonly хранилища fence открыта и не завершается — новая база-поколение
    // создаётся сразу (запись в хранилище fence ждала бы её)
    const conn = await new Promise((resolve) => {
      const r = globalThis.indexedDB.open(FENCE);
      r.onsuccess = () => resolve(r.result);
    });
    const hang = conn.transaction('fence', 'readonly');
    hang.objectStore('fence').get('generation');
    const t1 = Date.now();
    await mkGen(9, 'tabf');
    assert.ok(Date.now() - t1 < 500, `новая база-поколение создана за ${Date.now() - t1} мс`);
    await pool.query(`INSERT INTO t VALUES (90011, 'names-stale')`);
    const r = await s.flush('t:names-stale');
    assert.deepEqual(r, { fenced: true });
    assert.ok(posts.some((p) => p.type === 'fenced' && p.volumeGeneration === 9 && p.volumeTabId === 'tabf'), JSON.stringify(posts));
    conn.close();
    for (const n of ['optomstroy-demo-fence-g8-ttabe', 'optomstroy-demo-fence-g9-ttabf']) await new Promise((r) => (globalThis.indexedDB.deleteDatabase(n).onsuccess = r));
  });

  test('fence сменился после проверки во flush(), пока сброс ждал замок сессии → снимок не делается ({fenced})', async () => {
    const posts = [];
    const s = mk(6, 'tab-C', posts);
    await writeFence({ generation: 6, tabId: 'tab-C' });
    await pool.query(`INSERT INTO t VALUES (90003, 'locked')`);
    let release;
    const hold = m.pg.bossSessionLocked('test.hold', 'HOLD', () => new Promise((r) => (release = r)));
    const cap0 = s.volume.stats.captures;
    const fp = s.flush('t:locked');
    for (let i = 0; i < 200 && s.stats.fenceChecks < 1; i++) await sleep(5);
    assert.equal(s.stats.fenceChecks, 1, 'проверка до замка прошла');
    await sleep(30);
    await writeFence({ generation: 7, tabId: 'tab-D' }); // другая вкладка перехватила том, пока этот сброс ждал замок
    const c0 = fake.stats.commits;
    release();
    await hold;
    const r = await fp;
    assert.deepEqual(r, { fenced: true });
    assert.ok(s.stats.fenceLockedChecks >= 1, 'сверка под замком');
    assert.equal(s.volume.stats.captures, cap0, 'снимка не было');
    assert.equal(fake.stats.commits, c0, 'commit не было');
    assert.ok(posts.some((p) => p.type === 'fenced' && p.volumeGeneration === 7));
  });
});
