// WP-T1: «единица работы» вместе с настоящим pg-boss 12.38 на PGlite (alias/pgboss-shim.mjs + alias/pg-shim.mjs +
// alias/work-gate.mjs — те же модули, что в backend.js). Порядок и приоритеты, окно затихания и отдельные случаи — в
// work-gate.test.mjs (WP-B2); здесь — то, что видно только с pg-boss и с шаблоном long-poll:
//   - обработчик work() выполняется как единица kind 'job' (метка «job <очередь>»), по одной, не внутри запроса;
//   - запрос приложения, пришедший во время задачи, ждёт её конца, а из очереди идёт раньше следующей задачи;
//   - шаблон long-poll (payment-waiter): единица запроса отпускает слот на ожидание, в это время идут другие запросы и
//     перечитывание статуса (kind 'poll'), затем запрос возвращается раньше задач (приоритет resume);
//   - хук конца единицы (WP-B3: сохранение имитатора «1С» и сброс тома) выполняется, пока единица держит слот.
//   node --test demo/web/backend/test/gate.test.mjs
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { after, before, describe, test } from 'node:test';
import { pathToFileURL } from 'node:url';
import { OUT } from '../lib/paths.mjs';
import { bundleForTest } from './support/bundle-for-test.mjs';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const PGLITE = `${OUT}/pglite/index.js`;
let m;
let db;
let boss;

before(async () => {
  if (!existsSync(PGLITE)) throw new Error(`нет ${PGLITE}: сначала node demo/web/backend/build-backend.mjs`);
  m = await bundleForTest(
    'gate',
    `export * as gate from './alias/work-gate.mjs';
     export * as pg from './alias/pg-shim.mjs';
     export * as bossShim from './alias/pgboss-shim.mjs';`,
  );
  globalThis.__posDemoLog = () => {};
  const { PGlite } = await import(pathToFileURL(PGLITE).href);
  db = await PGlite.create('memory://');
  m.pg.attachPglite(db);
  m.bossShim.attachPgliteToBoss(db);
  m.gate.configureGate({ quietMs: 2, quietMaxMs: 30 });
  boss = new m.bossShim.PgBoss({ schema: 'pgboss', supervise: false, schedule: false, migrate: true });
  boss.on('error', () => {});
  await boss.start();
});
after(async () => {
  await boss?.stop({ graceful: false, wait: false }).catch(() => undefined);
  await db?.close();
  setTimeout(() => process.exit(), 300).unref();
});

describe('единица работы и pg-boss', () => {
  test('обработчик задачи pg-boss — единица kind job; запрос во время задачи ждёт её конца', async () => {
    const seen = [];
    let release;
    const hold = new Promise((r) => (release = r));
    await boss.createQueue('t1.q');
    await boss.work('t1.q', { pollingIntervalSeconds: 0.5 }, async (jobs) => {
      const u = m.gate.activeUnit();
      seen.push({ kind: u?.kind, label: u?.label, n: jobs.length });
      await hold;
    });
    await boss.send('t1.q', { a: 1 });
    for (let i = 0; i < 100 && !seen.length; i++) await sleep(50);
    assert.equal(seen.length, 1, 'задача взята');
    assert.equal(seen[0].kind, 'job');
    assert.equal(seen[0].label, 'job t1.q');
    let httpStartedAt = 0;
    const t0 = Date.now();
    const req = m.gate.run({ kind: 'http', name: 'GET /me', label: 'GET /api/v1/me' }, async () => {
      httpStartedAt = Date.now();
    });
    await sleep(150);
    assert.equal(httpStartedAt, 0, 'запрос ждёт, пока задача держит слот');
    release();
    await req;
    assert.ok(httpStartedAt - t0 >= 140, `запрос начался после конца задачи (${httpStartedAt - t0} мс)`);
    await boss.offWork('t1.q');
  });

  test('из очереди запрос приложения идёт раньше задачи pg-boss (обе ждут слот)', async () => {
    const order = [];
    let release;
    const blocker = m.gate.run({ kind: 'job', name: 'blocker', label: 'job blocker' }, () => new Promise((r) => (release = r)));
    await sleep(5);
    const j = m.gate.run({ kind: 'job', name: 'q', label: 'job q' }, async () => order.push('job'));
    await sleep(5);
    const h = m.gate.run({ kind: 'http', name: 'GET /cart', label: 'GET /api/v1/cart' }, async () => order.push('http'));
    release();
    await Promise.all([blocker, j, h]);
    assert.deepEqual(order, ['http', 'job']);
  });

  test('шаблон long-poll: слот отпущен на ожидание, идут запрос и перечитывание (poll), затем возврат раньше задачи', async () => {
    const order = [];
    let kick;
    const changed = new Promise((r) => (kick = r));
    const lp = m.gate.run({ kind: 'http', name: 'GET /payments/{id}', label: 'GET /api/v1/payments/p1?wait=25' }, async (u) => {
      order.push('lp:start');
      await m.gate.releaseWhile(u, async () => {
        await changed;
        await m.gate.run({ kind: 'poll', name: 'payments.wait.reread', label: 'poll payment p1' }, async () => order.push('poll'));
      });
      order.push('lp:resume');
    });
    await sleep(20);
    const me = m.gate.run({ kind: 'http', name: 'GET /me', label: 'GET /api/v1/me' }, async () => order.push('me'));
    await me;
    // задача pg-boss встаёт в очередь, пока long-poll ещё ждёт; изменение статуса → перечитывание → возврат
    const job = m.gate.run({ kind: 'job', name: 'payments.qr_poll', label: 'job payments.qr_poll' }, async () => order.push('job'));
    await sleep(5);
    kick();
    await Promise.all([lp, job]);
    assert.equal(order[0], 'lp:start');
    assert.equal(order[1], 'me', 'запрос выполнился во время ожидания long-poll');
    assert.ok(order.indexOf('poll') < order.indexOf('lp:resume'), `перечитывание раньше возврата: ${order}`);
    // задача (опрос QR, который и меняет статус) выполняется, пока long-poll ждёт, — long-poll её не блокирует;
    // приоритет resume над очередью проверен в work-gate.test.mjs
    assert.ok(order.indexOf('job') < order.indexOf('lp:resume'), `задача выполнилась во время ожидания long-poll: ${order}`);
    assert.equal(order.at(-1), 'lp:resume');
  });

  test('хук конца единицы (WP-B3) выполняется, пока единица держит слот; следующая единица — после хука', async () => {
    const order = [];
    m.gate.setUnitEndHook(async (u) => {
      if (u.name !== 'durable') return;
      order.push(`hook:${u.durable ? 'durable' : 'plain'}`);
      await sleep(30);
      order.push('hook:end');
    });
    try {
      const a = m.gate.run({ kind: 'http', name: 'durable', label: 'POST /api/v1/orders', durable: true }, async () => order.push('a'));
      const b = m.gate.run({ kind: 'http', name: 'next', label: 'GET /api/v1/orders' }, async () => order.push('b'));
      await Promise.all([a, b]);
      assert.deepEqual(order, ['a', 'hook:durable', 'hook:end', 'b']);
    } finally {
      m.gate.setUnitEndHook(null);
    }
  });

  test('fix round 2: afterRelease хука — после освобождения слота; результат run() — после него; удержания нет', async () => {
    const order = [];
    const wd = m.gate.gateConfig.watchdogMs;
    m.gate.configureGate({ watchdogMs: 150 });
    m.gate.resetGateStats();
    m.gate.setUnitEndHook(async (u) => {
      if (u.name === 'fails') return { afterRelease: async () => Promise.reject(new Error('диск')) };
      if (u.name !== 'durable') return undefined;
      order.push('hook');
      return {
        afterRelease: async () => {
          order.push('flush:start');
          await sleep(400); // «медленный commit IndexedDB»
          order.push('flush:end');
        },
      };
    });
    try {
      const t0 = performance.now();
      let aMs = 0;
      let bMs = 0;
      const a = m.gate.run({ kind: 'http', name: 'durable', label: 'PUT /api/v1/cart/items/x', durable: true }, async () => (order.push('a'), 'A')).then((v) => ((aMs = performance.now() - t0), v));
      const b = m.gate.run({ kind: 'http', name: 'next', label: 'GET /api/v1/me' }, async () => order.push('b')).then(() => (bMs = performance.now() - t0));
      const [ra] = await Promise.all([a, b]);
      assert.equal(ra, 'A', 'результат единицы сохранён');
      assert.ok(bMs < 300, `следующая единица шла во время сброса: ${bMs.toFixed(0)} мс`);
      assert.ok(aMs >= 400, `результат изменяющей единицы — после сброса: ${aMs.toFixed(0)} мс`);
      assert.ok(order.indexOf('b') > order.indexOf('flush:start') && order.indexOf('b') < order.indexOf('flush:end'), order.join(','));
      const st = m.gate.gateStats;
      assert.equal(st.holdsOver3s, 0, 'слот не удерживался дольше watchdogMs (150 мс)');
      assert.equal(st.queueWaitsOver3s, 0);
      assert.equal(st.afterRelease, 1);
      assert.ok(st.maxAfterReleaseMs >= 400);
      // сбой afterRelease — ошибка конца единицы в журнале, результат единицы не теряется
      const e0 = st.endHookErrors ?? 0;
      assert.equal(await m.gate.run({ kind: 'http', name: 'fails', durable: true }, async () => 'ok'), 'ok');
      assert.equal((m.gate.gateStats.endHookErrors ?? 0) - e0, 1);
    } finally {
      m.gate.setUnitEndHook(null);
      m.gate.configureGate({ watchdogMs: wd });
    }
  });
});
