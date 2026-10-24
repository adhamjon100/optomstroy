import { type ChildProcess, spawn, spawnSync } from 'node:child_process';
import { existsSync, readdirSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { EmbeddedPg } from '../support/embedded-pg.js';
import { TEST_ENV } from '../support/test-app.js';
import { makeWorkerCompileDir, waitFor } from './helpers.js';

/**
 * Точка входа `src/worker.ts` (как `node dist/worker.js`, запуск через tsx): флаг WORKERS_ENABLED (R0 §17.7)
 * и старт против PostgreSQL 17 — расписания и очереди создаются в схеме pgboss. Этап F (FQ-PAY-12, FQ-ORD-05): процесс
 * поднимает контекст Nest (AppModule без HTTP) и регистрирует обработчики платежей (`payments.*`) и корзины
 * (`catalog.prices-changed|stock-changed`, `cart.parked_expire`) — поэтому БД мигрируется всеми миграциями.
 */
const NL = String.fromCharCode(10);
const MIGRATIONS = readdirSync(fileURLToPath(new URL('../../migrations/', import.meta.url)))
  .filter((f) => f.endsWith('.sql'))
  .sort();
const ROOT = fileURLToPath(new URL('../..', import.meta.url));
/**
 * Скомпилированный worker (как `node dist/worker.js`): DI контекста Nest требует метаданных декораторов
 * (`emitDecoratorMetadata`), которых нет у tsx/esbuild. Каталог — на глубине `dist/` (пути к фикстурам и ресурсам
 * вычисляются от него), уникален для прогона (`mkdtemp`, ревью F RR-5 — параллельные прогоны не мешают друг другу) и
 * удаляется после набора.
 */
let compiledDir: string | null = null;

function startWorker(
  env: Record<string, string>,
  compiled: string | null = null,
): {
  child: ChildProcess;
  out: string[];
  exit: Promise<number | null>;
} {
  const out: string[] = [];
  const entry = compiled ? [join(compiled, 'worker.js')] : ['--import', 'tsx', 'src/worker.ts'];
  const child = spawn(process.execPath, entry, {
    cwd: ROOT,
    env: {
      PATH: process.env.PATH ?? '',
      SystemRoot: process.env.SystemRoot ?? '',
      TEMP: process.env.TEMP ?? '',
      ...TEST_ENV,
      ...env,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const collect = (b: Buffer) =>
    out.push(
      ...b
        .toString()
        .split('\n')
        .filter((l) => l.trim() !== ''),
    );
  child.stdout?.on('data', collect);
  child.stderr?.on('data', collect);
  const exit = new Promise<number | null>((resolve) => child.on('exit', (code) => resolve(code)));
  return { child, out, exit };
}

describe('RM-C-007: точка входа worker.ts', () => {
  const db = new EmbeddedPg();

  beforeAll(async () => {
    await db.start();
    await db.createDatabase('pos_worker_entry');
    await db.migrate('pos_worker_entry', MIGRATIONS);
  });

  afterAll(async () => {
    await db.stop();
    if (compiledDir) rmSync(compiledDir, { recursive: true, force: true });
  });

  it('RR-5: каталог компиляции уникален для прогона и лежит на глубине dist/', () => {
    const a = makeWorkerCompileDir(ROOT);
    const b = makeWorkerCompileDir(ROOT);
    try {
      expect(a).not.toBe(b);
      for (const d of [a, b]) {
        expect(existsSync(d)).toBe(true);
        expect(dirname(d)).toBe(dirname(join(ROOT, 'dist')));
      }
    } finally {
      rmSync(a, { recursive: true, force: true });
      rmSync(b, { recursive: true, force: true });
    }
  });

  it('WORKERS_ENABLED=false → процесс завершается с кодом 0, обработчики не запускаются', async () => {
    const w = startWorker({ WORKERS_ENABLED: 'false', DATABASE_URL: db.url('pos_worker_entry') });
    expect(await w.exit).toBe(0);
    const line = w.out.find((l) => l.includes('worker.disabled'));
    expect(line).toBeDefined();
    expect(JSON.parse(line!)).toMatchObject({ level: 'warn', service: 'pos-worker' });
    console.error(`--- worker.ts WORKERS_ENABLED=false ---\n${w.out.join('\n')}`);
  });

  it('невалидная конфигурация → код 1 и сообщение без значений', async () => {
    const w = startWorker({ WORKERS_ENABLED: 'true', DATABASE_URL: 'mysql://nope', SYNC_STOCK_CRON: 'каждые 5 минут' });
    expect(await w.exit).toBe(1);
    const text = w.out.join('\n');
    expect(text).toContain('DATABASE_URL');
    expect(text).toContain('SYNC_STOCK_CRON');
  });

  it('WORKERS_ENABLED=true → worker.started, очереди и расписания в PostgreSQL', async () => {
    compiledDir = makeWorkerCompileDir(ROOT);
    const tsc = spawnSync(
      process.execPath,
      [join(ROOT, 'node_modules/typescript/bin/tsc'), '-p', 'tsconfig.build.json', '--outDir', compiledDir],
      { cwd: ROOT, encoding: 'utf8' },
    );
    expect(tsc.status, tsc.stdout + tsc.stderr).toBe(0);
    const w = startWorker(
      { WORKERS_ENABLED: 'true', DATABASE_URL: db.url('pos_worker_entry'), LOG_LEVEL: 'info' },
      compiledDir,
    );
    try {
      await waitFor(
        () =>
          Promise.resolve(
            w.out.some((l) => l.includes('"worker.started"')) &&
              w.out.some((l) => l.includes('payments.jobs.registered')) &&
              w.out.some((l) => l.includes('cart.jobs.registered')),
          ),
        { timeoutMs: 90_000, what: 'worker.started + payments/cart jobs' },
      ).catch((e: unknown) => {
        console.error(`--- worker.ts: журнал ---${NL}${w.out.slice(-40).join(NL)}`);
        throw e;
      });
      const pool = new pg.Pool({ connectionString: db.url('pos_worker_entry'), max: 1 });
      try {
        const q = await pool.query<{ n: number }>(
          `SELECT count(*)::int AS n FROM pgboss.queue WHERE name LIKE 'sync.%'`,
        );
        expect(q.rows[0].n).toBeGreaterThanOrEqual(16);
        const s = await pool.query<{ name: string; key: string; cron: string }>(
          `SELECT name, key, cron FROM pgboss.schedule WHERE name = 'sync.stock'`,
        );
        expect(s.rows).toEqual([{ name: 'sync.stock', key: 'stock', cron: '*/10 * * * *' }]);
        // Этап F: очереди платежей и корзины из контекста Nest pos-worker.
        const f = await pool.query<{ name: string }>(
          `SELECT name FROM pgboss.queue WHERE name LIKE 'payments.%' OR name LIKE 'cart.%' OR name LIKE 'catalog.%'
            OR name LIKE 'orders.onec-%' ORDER BY name`,
        );
        expect(f.rows.map((r) => r.name)).toEqual(
          expect.arrayContaining([
            'cart.parked_expire',
            'catalog.prices-changed',
            'catalog.stock-changed',
            'orders.onec-confirmed',
            'orders.onec-failed',
            'payments.qr_expire',
            'payments.qr_onec_poll',
          ]),
        );
        const fs = await pool.query<{ name: string }>(
          `SELECT name FROM pgboss.schedule WHERE name IN ('payments.qr_expire', 'cart.parked_expire') ORDER BY name`,
        );
        expect(fs.rows.map((r) => r.name)).toEqual(['cart.parked_expire', 'payments.qr_expire']);
      } finally {
        await pool.end();
      }
      console.error(`--- worker.ts WORKERS_ENABLED=true (первые строки) ---\n${w.out.slice(0, 6).join('\n')}`);
    } finally {
      w.child.kill();
      await w.exit;
    }
  }, 240_000);
});
