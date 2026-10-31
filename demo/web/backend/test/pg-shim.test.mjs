// WP-B2: шим `pg` на одном PGlite (alias/pg-shim.mjs, plan §3.4 правила 2–5) вместе с единицей работы
// (alias/work-gate.mjs) — те же модули, что в backend.js (сборка теми же подменами). PGlite 0.3.16 — копия сайта
// site/backend/pglite (нужна собранная demo/web/site: node demo/web/backend/build-backend.mjs).
//
// Проверяется: подсадка по области сырой транзакции и вложенный BEGIN → SAVEPOINT; ошибка спайка («savepoint
// pgshim_tx_N does not exist» — BEGIN чужого потока подсел по простою) невозможна: чужой BEGIN ждёт; параллельные
// ветви Promise.all одной функции — разные транзакции; транзакции drizzle без области (подсадка unit); белый
// список (сразу / после простоя с пометкой «вне списка»); осиротевшая вложенная транзакция не трогает сессию;
// сторож и предохранитель ожидания; releaseWhile при открытой транзакции не отпускает слот.
//   node --test "demo/web/backend/test/*.test.mjs"
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
let pool;
const logs = [];

/** Поток «чужой единицы»: асинхронная рамка с именем маркера единицы, которой нет в шлюзе. */
const foreignUnit = {
  async __posUnit_999999(fn) {
    return await fn();
  },
}.__posUnit_999999;

before(async () => {
  if (!existsSync(PGLITE)) throw new Error(`нет ${PGLITE}: сначала node demo/web/backend/build-backend.mjs`);
  m = await bundleForTest(
    'pg-shim',
    `export * as pg from './alias/pg-shim.mjs';
     export * as gate from './alias/work-gate.mjs';
     export { drizzle } from 'drizzle-orm/node-postgres';
     export { NodePgSession } from 'drizzle-orm/node-postgres/session';
     export { sql } from 'drizzle-orm';`,
  );
  globalThis.__posDemoLog = (lv, msg) => logs.push(`${lv} ${msg}`);
  const { PGlite } = await import(pathToFileURL(PGLITE).href);
  db = await PGlite.create('memory://');
  m.pg.attachPglite(db);
  m.pg.attachDrizzleScope(m.NodePgSession);
  m.gate.configureGate({ quietMs: 2, quietMaxMs: 20 });
  pool = new m.pg.Pool({ application_name: 'test' });
  await pool.query(`CREATE TABLE t (id serial PRIMARY KEY, v text NOT NULL)`);
  await pool.query(`CREATE TABLE app_settings (key text PRIMARY KEY, value jsonb)`);
});
after(async () => {
  await db?.close();
});
const S = () => m.pg.shimStats;
const snap = () => JSON.parse(JSON.stringify(S()));
const count = async (v) => (await pool.query('SELECT count(*)::int AS n FROM t WHERE v = $1', [v])).rows[0].n;

describe('pg-shim: fingerprint', () => {
  test('«глагол таблица» верхнего уровня', () => {
    const f = (s) => m.pg.fingerprint(s);
    assert.equal(f('SELECT value FROM app_settings WHERE key = $1'), 'select app_settings');
    assert.equal(f(`SELECT u.id, (SELECT ro.code FROM user_roles ro WHERE ro.user_id = u.id) FROM users u`), 'select users');
    assert.equal(f('select "id", "v" from "orders" where "orders"."id" = $1'), 'select orders');
    assert.equal(f('INSERT INTO sync_runs (entity) VALUES ($1)'), 'insert sync_runs');
    assert.equal(f('UPDATE sync_node_state SET x = 1'), 'update sync_node_state');
    assert.equal(f('INSERT INTO pgboss.job (id, name, data) VALUES (1)'), 'insert pgboss.job');
    assert.equal(f("SELECT to_regclass('public.demo_meta')"), 'select');
    assert.equal(f('BEGIN'), 'begin');
  });
});

describe('pg-shim: подсадка и транзакции', () => {
  test('область сырой транзакции: оператор пула подсаживается сразу, вложенный BEGIN → SAVEPOINT', async () => {
    const s0 = snap();
    const readViaPool = async (v) => (await pool.query('SELECT count(*)::int AS n FROM t WHERE v = $1', [v])).rows[0].n;
    const nestedTx = async () => {
      const c2 = await pool.connect();
      await c2.query('BEGIN');
      await c2.query(`INSERT INTO t (v) VALUES ('scope-nested')`);
      await c2.query('COMMIT');
      c2.release();
    };
    const rawTx = async () => {
      const c = await pool.connect();
      await c.query('BEGIN');
      await c.query(`INSERT INTO t (v) VALUES ('scope-a')`);
      const seen = await readViaPool('scope-a'); // в PG — другое соединение; здесь — подсадка, видит незафиксированное
      await nestedTx();
      await c.query('COMMIT');
      c.release();
      return seen;
    };
    const seen = await m.gate.run({ kind: 'job', name: 'raw' }, rawTx);
    assert.equal(seen, 1);
    assert.equal(await count('scope-nested'), 1);
    assert.equal(S().piggyScope - s0.piggyScope, 2, 'SELECT и BEGIN — по области');
    assert.equal(S().nestedBegin - s0.nestedBegin, 1);
    assert.equal(S().nestedBeginForeign, 0);
  });

  test('ошибка спайка невозможна: BEGIN чужой единицы ждёт COMMIT держателя, а не становится SAVEPOINT', async () => {
    const s0 = snap();
    const order = [];
    const host = m.gate.run({ kind: 'http', name: 'host' }, async () => {
      const c = await pool.connect();
      await c.query('BEGIN');
      await c.query(`INSERT INTO t (v) VALUES ('b0-host')`);
      await sleep(400); // держатель простаивает дольше idleMs / idleForeignMs
      order.push('host-commit');
      await c.query('COMMIT');
      c.release();
    });
    await sleep(20);
    const foreign = foreignUnit(async () => {
      const c = await pool.connect();
      await c.query('BEGIN'); // как AdminRateLimitInterceptor другого запроса в спайке
      order.push('foreign-begun');
      await c.query(`INSERT INTO t (v) VALUES ('b0-foreign')`);
      await c.query('COMMIT');
      c.release();
    });
    await Promise.all([host, foreign]);
    assert.deepEqual(order, ['host-commit', 'foreign-begun']);
    assert.equal(S().nestedBegin - s0.nestedBegin, 0);
    assert.equal(S().beginWaitedForTx - s0.beginWaitedForTx, 1);
    assert.equal(S().foreignUnitWaits - s0.foreignUnitWaits, 1);
    assert.equal(await count('b0-foreign'), 1);
    assert.ok(!logs.some((l) => /does not exist/.test(l)));
  });

  test('параллельные ветви Promise.all одной функции — разные транзакции (BEGIN второй ждёт)', async () => {
    const s0 = snap();
    const worker = async (i) => {
      if (i) await sleep(15); // как запрос в 1С перед записью: BEGIN второй ветви приходит при открытой транзакции первой
      const c = await pool.connect();
      await c.query('BEGIN');
      await c.query('INSERT INTO t (v) VALUES ($1)', [`pall-${i}`]);
      await sleep(60);
      await c.query('COMMIT');
      c.release();
    };
    await m.gate.run({ kind: 'job', name: 'pall' }, () => Promise.all([worker(0), worker(1)]));
    assert.equal(S().nestedBegin - s0.nestedBegin, 0);
    assert.equal(S().beginWaitedForTx - s0.beginWaitedForTx, 1);
    assert.equal((await count('pall-0')) + (await count('pall-1')), 2);
  });

  test('транзакция drizzle без области: оператор пула внутри — подсадка unit; ключ вне списка — после простоя', async () => {
    const s0 = snap();
    const d = m.drizzle(pool);
    let ms;
    let seen;
    await m.gate.run({ kind: 'http', name: 'drizzle' }, () =>
      d.transaction(async (tx) => {
        await tx.execute(m.sql`INSERT INTO t (v) VALUES ('drz')`);
        const t0 = performance.now();
        const r = await d.execute(m.sql`SELECT count(*)::int AS n FROM t WHERE v = 'drz'`);
        ms = performance.now() - t0;
        seen = r.rows[0].n;
      }),
    );
    assert.equal(seen, 1);
    assert.equal(S().txByScope.drizzle - s0.txByScope.drizzle, 1);
    assert.equal(S().piggyUnit - s0.piggyUnit, 1);
    assert.equal(S().outsideWhitelist - s0.outsideWhitelist, 1, '«select t» нет в белом списке');
    assert.ok(ms >= m.pg.shimConfig.idleMs - 5, `вне списка — после простоя idleMs: ${ms.toFixed(1)} мс`);
  });

  test('ключ из белого списка (unit) подсаживается сразу', async () => {
    const s0 = snap();
    const d = m.drizzle(pool);
    let ms;
    await m.gate.run({ kind: 'http', name: 'drizzle-allowed' }, () =>
      d.transaction(async (tx) => {
        await tx.execute(m.sql`INSERT INTO t (v) VALUES ('drz2')`);
        const t0 = performance.now();
        await pool.query('SELECT value FROM app_settings WHERE key = $1', ['x']);
        ms = performance.now() - t0;
      }),
    );
    assert.equal(S().piggyUnit - s0.piggyUnit, 1);
    assert.equal(S().outsideWhitelist - s0.outsideWhitelist, 0);
    assert.ok(ms < 60, `сразу: ${ms.toFixed(1)} мс`);
  });

  // fix round 1 (WP-T1 дефект 2): POST /auth/unlock — RefreshService.rotate открывает транзакцию drizzle, колбэк
  // возвращает rotateInTx() без await, тот вызывает RateLimitService.consume() → своя транзакция drizzle (RL-PIN).
  test('транзакция drizzle из колбэка транзакции drizzle (как RL-PIN в /auth/unlock): BEGIN сразу SAVEPOINT по области, без простоя и вне белого списка', async () => {
    const s0 = snap();
    const d = m.drizzle(pool);
    const limiter = {
      async consume() {
        return d.transaction(async (tx) => {
          await tx.execute(m.sql`INSERT INTO t (v) VALUES ('dtx-inner')`);
          return (await tx.execute(m.sql`SELECT count(*)::int AS n FROM t WHERE v = 'dtx-inner'`)).rows[0].n;
        });
      },
    };
    const svc = {
      async rotateInTx(tx) {
        await tx.execute(m.sql`INSERT INTO t (v) VALUES ('dtx-outer')`);
        const t0 = performance.now();
        const n = await limiter.consume();
        return { n, ms: performance.now() - t0 };
      },
      rotate() {
        return d.transaction(async (tx) => {
          await tx.execute(m.sql`SELECT 1`);
          return this.rotateInTx(tx);
        });
      },
    };
    const r = await m.gate.run({ kind: 'http', name: 'dtx-nested' }, () => svc.rotate());
    assert.equal(r.n, 1);
    assert.ok(r.ms < 200, `вложенная транзакция без ожидания nestedBeginIdleMs (${m.pg.shimConfig.nestedBeginIdleMs} мс): ${r.ms.toFixed(1)} мс`);
    assert.equal(S().dtxNestedCalls - s0.dtxNestedCalls, 1);
    assert.equal(S().dtxNestedBegin - s0.dtxNestedBegin, 1);
    assert.equal(S().piggyScope - s0.piggyScope, 1);
    assert.equal(S().piggyUnit - s0.piggyUnit, 0);
    assert.equal(S().outsideWhitelist - s0.outsideWhitelist, 0);
    assert.equal(await count('dtx-inner'), 1);
    assert.equal(await count('dtx-outer'), 1);
  });

  test('параллельная (не из колбэка) транзакция drizzle той же единицы не вкладывается: её BEGIN ждёт COMMIT первой', async () => {
    const s0 = snap();
    const d = m.drizzle(pool);
    const order = [];
    await m.gate.run({ kind: 'http', name: 'dtx-siblings' }, () =>
      Promise.all([
        d.transaction(async (tx) => {
          await tx.execute(m.sql`INSERT INTO t (v) VALUES ('dtx-a')`);
          await sleep(40);
          await tx.execute(m.sql`INSERT INTO t (v) VALUES ('dtx-a')`);
          order.push('a');
        }),
        (async () => {
          await sleep(10);
          return d.transaction(async (tx) => {
            await tx.execute(m.sql`INSERT INTO t (v) VALUES ('dtx-b')`);
            order.push('b');
          });
        })(),
      ]),
    );
    assert.deepEqual(order, ['a', 'b']);
    assert.equal(S().dtxNestedCalls - s0.dtxNestedCalls, 0);
    assert.equal(S().dtxNestedBegin - s0.dtxNestedBegin, 0);
    assert.equal(S().nestedBegin - s0.nestedBegin, 0);
    assert.equal(S().beginWaitedForTx - s0.beginWaitedForTx, 1);
    assert.equal(await count('dtx-a'), 2);
    assert.equal(await count('dtx-b'), 1);
  });

  test('осиротевшая вложенная транзакция: держатель завершился — её операторы получают ошибку, сессия цела', async () => {
    const s0 = snap();
    m.pg.configureShim({ nestedBeginIdleMs: 80 });
    let childErr = null;
    let child;
    try {
      await m.gate.run({ kind: 'http', name: 'orphan-host' }, async () => {
        const c = await pool.connect();
        await c.query('BEGIN');
        // BEGIN без области из той же (активной) единицы после долгого простоя → SAVEPOINT (вложенная транзакция пула)
        child = (async () => {
          const c2 = await pool.connect();
          await c2.query('BEGIN');
          await sleep(150); // держатель тем временем фиксируется
          try {
            await c2.query(`INSERT INTO t (v) VALUES ('orphan')`);
          } catch (e) {
            childErr = e;
          }
          await c2.query('ROLLBACK');
          c2.release();
        })();
        await sleep(120);
        await c.query('COMMIT');
        c.release();
      });
      await child;
    } finally {
      m.pg.configureShim({ nestedBeginIdleMs: 1000 });
    }
    assert.equal(S().nestedBegin - s0.nestedBegin, 1);
    assert.equal(childErr?.code, 'ERR_DEMO_TX_ORPHANED');
    assert.equal(S().orphanedNested - s0.orphanedNested, 1);
    assert.equal(await count('orphan'), 0);
    assert.ok(!logs.some((l) => /does not exist/.test(l)), 'RELEASE/ROLLBACK TO снятой точки сохранения в сессию не уходили');
    // сессия не в транзакции и работает
    const c = await pool.connect();
    await c.query('BEGIN');
    await c.query(`INSERT INTO t (v) VALUES ('after-orphan')`);
    await c.query('COMMIT');
    c.release();
    assert.equal(await count('after-orphan'), 1);
  });

  test('сторож и предохранитель: ожидание дольше watchdogMs считается, дольше breakerMs — оператор отклонён', async () => {
    const s0 = snap();
    m.pg.configureShim({ watchdogMs: 100, breakerMs: 300 });
    let err = null;
    try {
      const host = m.gate.run({ kind: 'http', name: 'busy-host' }, async () => {
        const c = await pool.connect();
        await c.query('BEGIN');
        // держатель «вычисляет» (как Argon2 внутри транзакции step-up) — не простаивает
        const t0 = performance.now();
        while (performance.now() - t0 < 450) {
          m.gate.markBusy();
          await sleep(10);
        }
        await c.query('COMMIT');
        c.release();
      });
      await sleep(20);
      await foreignUnit(async () => {
        try {
          await pool.query(`INSERT INTO t (v) VALUES ('breaker')`);
        } catch (e) {
          err = e;
        }
      });
      await host;
    } finally {
      m.pg.configureShim({ watchdogMs: 3000, breakerMs: 20000 });
    }
    assert.equal(err?.code, 'ERR_DEMO_LOCK_TIMEOUT');
    assert.equal(S().waitsOver3s - s0.waitsOver3s, 1);
    assert.equal(S().breakerRejects - s0.breakerRejects, 1);
    assert.equal(S().piggyback - s0.piggyback, 0, 'занятый держатель не принимается за простаивающего');
    assert.ok(logs.some((l) => l.startsWith('error') && l.includes('сторож')));
  });

  test('вставка задачи pg-boss вне области (тикер) не подсаживается по простою — ждёт COMMIT', async () => {
    await pool.query(`CREATE SCHEMA IF NOT EXISTS pgboss`);
    await pool.query(`CREATE TABLE IF NOT EXISTS pgboss.job (id uuid PRIMARY KEY, name text, data jsonb)`);
    const s0 = snap();
    const order = [];
    const host = m.gate.run({ kind: 'http', name: 'boss-host' }, async () => {
      const c = await pool.connect();
      await c.query('BEGIN');
      await c.query(`INSERT INTO t (v) VALUES ('boss-host')`);
      await sleep(250); // простой дольше idleMs: обычный оператор вне списка уже подсел бы
      order.push('host-commit');
      await c.query('COMMIT');
      c.release();
    });
    await sleep(20);
    const text = `INSERT INTO pgboss.job (id, name, data) VALUES (gen_random_uuid(), 'outbox.dispatch', '{}'::jsonb) RETURNING id`;
    const r = await m.pg.bossStatement(text, undefined, () => db.query(text));
    order.push('boss-insert');
    await host;
    assert.equal(r.rows.length, 1);
    assert.deepEqual(order, ['host-commit', 'boss-insert']);
    assert.equal(S().piggyBoss - s0.piggyBoss, 0);
    assert.equal(S().outsideWhitelist - s0.outsideWhitelist, 0);
  });

  test('releaseWhile при открытой транзакции единицы слот не отпускает', async () => {
    const g0 = m.gate.gateStats.releaseRefusedTx;
    await m.gate.run({ kind: 'http', name: 'tx-release' }, async (u) => {
      const c = await pool.connect();
      await c.query('BEGIN');
      await m.gate.releaseWhile(u, () => sleep(5));
      assert.equal(m.gate.activeUnit(), u);
      await c.query('COMMIT');
      c.release();
    });
    assert.equal(m.gate.gateStats.releaseRefusedTx - g0, 1);
  });
});

// ---------------------------------------------------------------------------------------------------------------
// WP-T1 (plan §4 WP-T1 «pg-shim.test.mjs»): параметры и типы как у node-postgres (pg-types по умолчанию), многооператорные
// запросы, LISTEN/NOTIFY, rowMode 'array', ошибки SQLSTATE, откат транзакции.
describe('pg-shim: параметры и типы как у node-postgres (WP-T1)', () => {
  test('типы результата как у node-postgres: int2/int4/float → number, numeric → строка, bool, text, uuid, json/jsonb, int4[]/text[]', async () => {
    const r = await pool.query(`SELECT 7::int2 AS i2, 42::int4 AS i4, 12.30::numeric(10,2) AS num, 1.5::float8 AS f8,
      true AS b, 'кв'::text AS t, '0190f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55'::uuid AS u, '{"a":[1,"б"]}'::jsonb AS jb, '{"x":1}'::json AS j,
      ARRAY[1,2,3]::int4[] AS ai, ARRAY['a','б']::text[] AS at, NULL::text AS n`);
    assert.deepEqual(r.rows[0], { i2: 7, i4: 42, num: '12.30', f8: 1.5, b: true, t: 'кв', u: '0190f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55', jb: { a: [1, 'б'] }, j: { x: 1 }, ai: [1, 2, 3], at: ['a', 'б'], n: null });
    assert.equal(r.rowCount, 1);
    assert.equal(r.command, 'SELECT');
    assert.deepEqual(r.fields.map((f) => f.name).slice(0, 3), ['i2', 'i4', 'num']);
  });
  // Ниже — поведение node-postgres (pg 8.23 / pg-types 2.2.0). До fix round 1 PGlite 0.3.16 его не применял:
  // parseResults делает {...this.parsers, ...options.parsers}, а распаковка прежнего Proxy без собственных ключей
  // пуста — действовали парсеры PGlite (WP-T1 дефект 1). Теперь rawParsers — обычный объект по всем OID.
  test('int8 → строка (node-postgres), а не BigInt', async () => {
    const r = await pool.query(`SELECT 9007199254740993::int8 AS i8, count(*) AS cnt, ARRAY[1,2]::int8[] AS a8`);
    assert.equal(typeof r.rows[0].i8, 'string', `int8 → ${typeof r.rows[0].i8}; JSON.stringify(BigInt) бросает TypeError`);
    assert.equal(typeof r.rows[0].cnt, 'string', `count(*) (int8) → ${typeof r.rows[0].cnt}`);
    assert.deepEqual(r.rows[0].a8, ['1', '2']);
  });
  test('interval → объект postgres-interval (node-postgres), а не строка', async () => {
    const r = await pool.query(`SELECT interval '1 day 02:03:04' AS iv`);
    assert.equal(typeof r.rows[0].iv, 'object', `interval → ${typeof r.rows[0].iv} ${JSON.stringify(r.rows[0].iv)}`);
  });
  test('свой разбор типов запроса (config.types, как у drizzle node-postgres) применяется', async () => {
    const types = { getTypeParser: (oid) => (oid === 1184 ? (v) => `RAW:${v}` : (v) => v) };
    const r = await pool.query({ text: `SELECT '2026-10-30 04:05:06+00'::timestamptz AS ts`, types });
    assert.match(String(r.rows[0].ts), /^RAW:2026-10-30 04:05:06/, `drizzle ждёт сырую строку timestamptz, а получил ${r.rows[0].ts instanceof Date ? 'Date' : typeof r.rows[0].ts}`);
  });
  test('timestamptz → Date (тот же момент), параметр Date → timestamptz', async () => {
    const when = new Date('2026-10-30T04:05:06.789Z');
    const r = await pool.query(`SELECT $1::timestamptz AS ts, ($1::timestamptz + interval '1 day') AS next`, [when]);
    assert.ok(r.rows[0].ts instanceof Date, 'Date');
    assert.equal(r.rows[0].ts.toISOString(), '2026-10-30T04:05:06.789Z');
    assert.equal(r.rows[0].next.toISOString(), '2026-10-31T04:05:06.789Z');
  });
  test('параметры: объект → jsonb, массив → int[], boolean, null, строка с кавычками', async () => {
    const r = await pool.query(`SELECT $1::jsonb AS j, $2::int[] AS a, $3::bool AS b, $4::text AS n, $5::text AS q`, [{ k: 'в', n: [1] }, [3, 4], false, null, `O'Neil "x"`]);
    assert.deepEqual(r.rows[0], { j: { k: 'в', n: [1] }, a: [3, 4], b: false, n: null, q: `O'Neil "x"` });
  });
  test('bytea → Buffer, как у node-postgres (pos-api вызывает .equals у request_hash ключа идемпотентности)', async () => {
    const r = await pool.query(`SELECT decode('0102ff', 'hex') AS b, digest('x', 'sha256') IS NULL AS skip`).catch(() => pool.query(`SELECT decode('0102ff', 'hex') AS b`));
    const b = r.rows[0].b;
    assert.equal(typeof b?.equals, 'function', `bytea вернулся как ${b?.constructor?.name} без .equals — как в node-postgres должен быть Buffer (IdempotencyService.begin: requestHash.equals → 500 на повторе с тем же Idempotency-Key)`);
    assert.deepEqual([...b], [1, 2, 255]);
  });
  test('многооператорный запрос без параметров → массив результатов; rowMode array', async () => {
    const rs = await pool.query(`SELECT 1 AS a; SELECT 2 AS b, 3 AS c`);
    assert.ok(Array.isArray(rs));
    assert.deepEqual(rs.map((x) => x.rows[0]), [{ a: 1 }, { b: 2, c: 3 }]);
    const ra = await pool.query({ text: `SELECT 1 AS a, 'x' AS b`, rowMode: 'array' });
    assert.deepEqual(ra.rows, [[1, 'x']]);
    assert.deepEqual(ra.fields.map((f) => f.name), ['a', 'b']);
  });
  test('ошибка SQL: код SQLSTATE как у pg (42601, 23505), сессия остаётся рабочей', async () => {
    await assert.rejects(pool.query(`SELEC 1`), (e) => e.code === '42601');
    await pool.query(`CREATE TABLE IF NOT EXISTS t1u (k text PRIMARY KEY)`);
    await pool.query(`INSERT INTO t1u VALUES ('a')`);
    await assert.rejects(pool.query(`INSERT INTO t1u VALUES ('a')`), (e) => e.code === '23505');
    assert.equal((await pool.query(`SELECT count(*)::int AS n FROM t1u`)).rows[0].n, 1);
  });
  test('транзакция: ROLLBACK отменяет вставку; COMMIT сохраняет', async () => {
    const c = await pool.connect();
    await c.query('BEGIN');
    await c.query(`INSERT INTO t (v) VALUES ('t1-rollback')`);
    await c.query('ROLLBACK');
    await c.query('BEGIN');
    await c.query(`INSERT INTO t (v) VALUES ('t1-commit')`);
    await c.query('COMMIT');
    c.release();
    assert.equal(await count('t1-rollback'), 0);
    assert.equal(await count('t1-commit'), 1);
  });
  test('LISTEN/NOTIFY: уведомление с payload приходит слушателю (PGlite.listen)', async () => {
    const c = await pool.connect();
    const got = new Promise((resolve) => c.on('notification', (n) => resolve(n)));
    await c.query('LISTEN t1_channel');
    await pool.query(`NOTIFY t1_channel, 'платёж-1'`);
    const n = await Promise.race([got, sleep(2000).then(() => null)]);
    await c.query('UNLISTEN t1_channel');
    c.release();
    assert.ok(n, 'уведомление пришло');
    assert.equal(n.channel, 't1_channel');
    assert.equal(n.payload, 'платёж-1');
  });
});
