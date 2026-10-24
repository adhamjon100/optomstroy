/**
 * HTTP-сервер для бенчмарка поиска (RM-E-005, NFR-PERF-001): Nest + Express с SearchModule и инфраструктурой common
 * (как test/search/support/search-app.ts), пул PostgreSQL — `createPool` прода (max 10 на процесс). Запускается
 * отдельным процессом из search-bench.ts, чтобы генератор нагрузки (autocannon) не делил с ним event loop.
 *
 * Отличие от боевого pos-api: субъект — заголовок `x-test-principal` вместо проверки JWT (AuthGuard и
 * SessionActivityGuard не подключены, см. docs/perf/E_search_benchmark.md). Журнал запросов pino пишется (уровень
 * BENCH_LOG_LEVEL, по умолчанию info, как в проде) в поток-заглушку. Только для APP_ENV=dev, тестовые данные.
 *
 * Окружение: BENCH_DATABASE_URL, BENCH_PORT, BENCH_LOG_LEVEL, BENCH_WORKERS (число процессов node:cluster на одном
 * порту; по умолчанию 1 — один процесс pos-api). Служебные маршруты (только при BENCH_WORKERS=1): GET /__bench/stats,
 * POST /__bench/reset.
 */
import cluster from 'node:cluster';
import { Writable } from 'node:stream';
import type { NextFunction, Request, Response } from 'express';
import { createPool } from '../../../src/common/db/database.module.js';
import { createSearchApp } from '../support/search-app.js';

const url = process.env.BENCH_DATABASE_URL;
const port = Number(process.env.BENCH_PORT ?? '0');
const workers = Math.max(1, Number(process.env.BENCH_WORKERS ?? '1'));
if (!url || !port) {
  process.stderr.write('bench-server: нужны BENCH_DATABASE_URL и BENCH_PORT\n');
  process.exit(2);
}

/** Длительности обработки на сервере (мс) по ключу запроса: `q` для поиска, путь для штрихкода. */
const timings = new Map<string, number[]>();

const sink = new Writable({
  write(_chunk, _enc, cb) {
    cb();
  },
});

function onStop(stop: () => void): void {
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
  process.stdin.on('end', stop);
  process.stdin.resume();
}

async function primary(): Promise<void> {
  let ready = 0;
  for (let i = 0; i < workers; i++) {
    const w = cluster.fork();
    w.on('message', (m: unknown) => {
      if (m === 'ready' && ++ready === workers) process.stdout.write(`READY ${port} x${workers}\n`);
    });
  }
  onStop(() => {
    for (const w of Object.values(cluster.workers ?? {})) w?.kill();
    process.exit(0);
  });
  await Promise.resolve();
}

async function worker(): Promise<void> {
  const pool = createPool({ DATABASE_URL: url! }, 'pos-api-bench');
  const { app } = await createSearchApp(pool, { LOG_LEVEL: process.env.BENCH_LOG_LEVEL ?? 'info' }, sink, (a) =>
    a.use(timing),
  );
  const http = app.getHttpAdapter().getInstance();
  // Загрузка процесса сервера с последнего reset: CPU (мс) и загрузка event loop (0…1) — Node-узкое место или БД.
  let cpu0 = process.cpuUsage();
  let elu0 = performance.eventLoopUtilization();
  let wall0 = performance.now();
  http.get('/__bench/stats', (_req: Request, res: Response) => {
    const cpu = process.cpuUsage(cpu0);
    const elu = performance.eventLoopUtilization(elu0);
    res.json({
      ...Object.fromEntries([...timings.entries()].map(([k, v]) => [k, v])),
      __process: [cpu.user / 1000, cpu.system / 1000, performance.now() - wall0, elu.utilization],
    });
  });
  http.post('/__bench/reset', (_req: Request, res: Response) => {
    timings.clear();
    cpu0 = process.cpuUsage();
    elu0 = performance.eventLoopUtilization();
    wall0 = performance.now();
    res.json({ ok: true });
  });
  await app.listen(port, '127.0.0.1');
  if (cluster.isWorker) {
    process.send?.('ready');
    process.on('SIGTERM', () => void app.close().finally(() => process.exit(0)));
    return;
  }
  process.stdout.write(`READY ${port}\n`);
  onStop(() => void app.close().finally(() => process.exit(0)));
}

function timing(req: Request, res: Response, next: NextFunction): void {
  if (!req.path.startsWith('/api/v1/search/')) {
    next();
    return;
  }
  const t0 = process.hrtime.bigint();
  res.on('finish', () => {
    const ms = Number(process.hrtime.bigint() - t0) / 1e6;
    const key = req.path.startsWith('/api/v1/search/barcode/')
      ? 'barcode-endpoint'
      : `${req.path.replace('/api/v1/search/', '')}?${new URLSearchParams(req.query as Record<string, string>).toString()}`;
    let arr = timings.get(key);
    if (!arr) timings.set(key, (arr = []));
    arr.push(ms);
  });
  next();
}

(workers > 1 && cluster.isPrimary ? primary() : worker()).catch((e: unknown) => {
  process.stderr.write(`bench-server: ${e instanceof Error ? (e.stack ?? e.message) : String(e)}\n`);
  process.exit(1);
});
