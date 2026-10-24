/**
 * Бенчмарк поиска NFR-PERF-001 (RM-E-005; 12 T-PERF-002: `autocannon -c 50 -d 60` по 20 запросам, смесь «артикул
 * 30 % / название 50 % / штрихкод 20 %»): p95 ≤ 300 мс на 50 000 синтетических SKU.
 *
 *   npm run bench:search -- [--sku 50000] [--duration 60] [--connections 50] [--json ../.tmp/search-bench.json]
 *                           [--report ../docs/perf/E_search_benchmark.md]
 *
 * Шаги: одноразовый embedded PostgreSQL 17 (UTF-8 LC_CTYPE — test/search/support/search-pg.ts) → все миграции →
 * `scripts/seed_synthetic_catalog.ts --sku N` (каталог основы RM-E-001, конвейер применения 1С) → VACUUM ANALYZE →
 * отдельный процесс HTTP-сервера поиска (bench-server.ts, пул как в проде) → прогрев и проверка matchType →
 * autocannon → EXPLAIN (ANALYZE, BUFFERS) ключевых запросов → отчёт. **Тестовые данные** (синтетика), не реальная
 * интеграция с 1С. Все процессы и кластер останавливаются в finally.
 */
import { type ChildProcess, spawn } from 'node:child_process';
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { createServer } from 'node:net';
import { cpus, platform, release, totalmem } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import pg from 'pg';
import type { CatalogViewer } from '../../../src/catalog/common/catalog-viewer.js';
import {
  buildStageQuery,
  buildSuggestQuery,
  correctWords,
  SEARCH_TX_BEGIN,
} from '../../../src/catalog/search/search.repository.js';
import { classifyQuery, type SearchStage } from '../../../src/catalog/search/search-text.js';
import { allMigrations, SEARCH_LC_CTYPE, SearchPg } from '../support/search-pg.js';
import { principalHeader } from '../support/search-app.js';

const API_DIR = fileURLToPath(new URL('../../../', import.meta.url));
const BENCH_TSCONFIG = 'test/search/bench/tsconfig.bench.json';
const BENCH_DIST = fileURLToPath(new URL('./.dist/', import.meta.url));
const require = createRequire(import.meta.url);

interface AutocannonResult {
  requests: { average: number; total: number };
  latency: { p50: number; p90: number; p99: number; max: number; average: number };
  errors: number;
  timeouts: number;
  non2xx: number;
  '2xx': number;
  duration: number;
}
interface AutocannonInstance {
  on(event: 'response', cb: (client: unknown, status: number, bytes: number, ms: number) => void): void;
}
type Autocannon = (
  opts: Record<string, unknown>,
  cb: (err: Error | null, res: AutocannonResult) => void,
) => AutocannonInstance;
const autocannon = require('autocannon') as Autocannon;

interface BenchQuery {
  readonly label: string;
  readonly kind: 'barcode' | 'sku' | 'name';
  readonly q: string;
  readonly extra?: Record<string, string>;
  readonly expect: SearchStage;
}

const log = (s: string) => process.stderr.write(`[bench] ${s}\n`);

function pct(sorted: readonly number[], p: number): number {
  if (sorted.length === 0) return NaN;
  const i = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[i];
}

function stats(values: readonly number[]) {
  const s = [...values].sort((a, b) => a - b);
  return { n: s.length, p50: pct(s, 50), p95: pct(s, 95), p99: pct(s, 99), max: s.at(-1) ?? NaN };
}

const f1 = (x: number) => (Number.isFinite(x) ? x.toFixed(1) : '—');

function freePort(): Promise<number> {
  return new Promise((ok, fail) => {
    const s = createServer();
    s.once('error', fail);
    s.listen(0, '127.0.0.1', () => {
      const a = s.address();
      const port = typeof a === 'object' && a ? a.port : 0;
      s.close(() => ok(port));
    });
  });
}

function nodeTsx(script: string, args: string[], env: Record<string, string>): ChildProcess {
  return spawn(process.execPath, ['--import', 'tsx', script, ...args], {
    cwd: API_DIR,
    env: { ...process.env, ...env },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
}

function waitExit(cp: ChildProcess): Promise<number> {
  return new Promise((ok) => cp.on('exit', (code) => ok(code ?? 1)));
}

async function main(): Promise<number> {
  const { values } = parseArgs({
    options: {
      sku: { type: 'string', default: '50000' },
      duration: { type: 'string', default: '60' },
      connections: { type: 'string', default: '50' },
      json: { type: 'string', default: '../.tmp/search-bench.json' },
      report: { type: 'string', default: '../docs/perf/E_search_benchmark.md' },
      /** Только эти виды запросов (barcode,sku,name) — для экспериментов. */
      kinds: { type: 'string', default: 'barcode,sku,name' },
      'skip-explain': { type: 'boolean', default: false },
      /** Уровень журнала сервера (по умолчанию info, как в проде). */
      'log-level': { type: 'string', default: 'info' },
      /** Число процессов сервера (node:cluster); 1 — как один процесс pos-api. */
      workers: { type: 'string', default: '1' },
      /** Прогрев нагрузкой перед замером, с (V8 JIT, кэши PostgreSQL и пула; результат прогрева не учитывается). */
      warmup: { type: 'string', default: '10' },
      /** Уже заполненная БД (эксперименты): без запуска кластера, миграций и seed. */
      url: { type: 'string' },
    },
  });
  const sku = Number(values.sku);
  const duration = Number(values.duration);
  const connections = Number(values.connections);
  const pgServer = new SearchPg();
  let server: ChildProcess | undefined;
  let pool: pg.Pool | undefined;
  const started = new Date();
  try {
    let url = values.url ?? '';
    let seedJson: { totalMs: number | null; db: Record<string, number> } = { totalMs: null, db: {} };
    if (!values.url) {
      log(`PostgreSQL 17 (embedded, LC_CTYPE ${SEARCH_LC_CTYPE})…`);
      await pgServer.start();
      await pgServer.createDatabase('pos_bench');
      await pgServer.migrate('pos_bench', allMigrations());
      url = pgServer.url('pos_bench');

      log(`seed_synthetic_catalog.ts --sku ${sku}…`);
      const seedReport = join(API_DIR, '..', '.tmp', 'search-bench-seed.json');
      mkdirSync(dirname(seedReport), { recursive: true });
      const seed = nodeTsx('scripts/seed_synthetic_catalog.ts', ['--sku', String(sku), '--report', seedReport], {
        APP_ENV: 'dev',
        DATABASE_URL: url,
      });
      let seedOut = '';
      seed.stdout?.on('data', (d: Buffer) => (seedOut += d.toString()));
      seed.stderr?.on('data', (d: Buffer) => process.stderr.write(d));
      const seedCode = await waitExit(seed);
      if (seedCode !== 0) throw new Error(`seed_synthetic_catalog: код ${seedCode}\n${seedOut}`);
      seedJson = JSON.parse(readFileSync(seedReport, 'utf8')) as typeof seedJson;
    }

    pool = new pg.Pool({ connectionString: url, max: 4 });
    await pool.query('VACUUM ANALYZE');
    const db = (
      await pool.query<Record<string, string>>(
        `SELECT (SELECT count(*) FROM products WHERE NOT deletion_mark AND is_sellable) AS products,
                (SELECT count(*) FROM product_variants) AS variants, (SELECT count(*) FROM barcodes) AS barcodes,
                (SELECT count(*) FROM prices) AS prices, (SELECT count(*) FROM stock_balances) AS stock,
                (SELECT count(*) FROM categories) AS categories,
                pg_size_pretty(pg_total_relation_size('products')) AS products_size,
                pg_size_pretty(pg_relation_size('products_search_vector_gin')) AS gin_fts,
                pg_size_pretty(pg_relation_size('products_name_norm_trgm')) AS gin_trgm_name,
                pg_size_pretty(pg_relation_size('products_sku_norm_trgm')) AS gin_trgm_sku,
                version() AS version`,
      )
    ).rows[0];

    // ---------------------------------------------------------------- набор запросов (20 шт.: 6 артикул, 10 название, 4 штрихкод)
    const bc = await pool.query<{ value: string }>(
      `SELECT b.value FROM barcodes b JOIN products p ON p.id = b.product_id
        WHERE NOT p.deletion_mark AND p.is_sellable AND b.packaging_id IS NULL ORDER BY b.value OFFSET 1000 LIMIT 3`,
    );
    const anchorBc = await pool.query<{ value: string }>(
      `SELECT b.value FROM barcodes b JOIN products p ON p.id = b.product_id WHERE p.sku = 'F4252' LIMIT 1`,
    );
    const allQueries: BenchQuery[] = [
      ...[anchorBc.rows[0].value, ...bc.rows.map((r) => r.value)].map((v, i): BenchQuery => ({
        label: `штрихкод #${i + 1}`,
        kind: 'barcode',
        q: v,
        expect: 'barcode',
      })),
      { label: 'артикул точный', kind: 'sku', q: 'F4252', expect: 'sku' },
      { label: 'артикул с дефисом', kind: 'sku', q: 'G1017-8', expect: 'sku' },
      { label: 'артикул без дефиса', kind: 'sku', q: 'VTP20', expect: 'sku' },
      { label: 'префикс артикула', kind: 'sku', q: 'F42', expect: 'sku' },
      { label: 'префикс артикула 2', kind: 'sku', q: 'HB15', expect: 'sku' },
      { label: 'артикул с опечаткой', kind: 'sku', q: 'SB-1WJ', expect: 'trgm' },
      { label: 'одно слово (много совпадений)', kind: 'name', q: 'смеситель', expect: 'fts' },
      { label: 'кириллица + бренд транслитом', kind: 'name', q: 'смеситель фрап', expect: 'fts' },
      { label: 'бренд + модель', kind: 'name', q: 'Frap F4252', expect: 'fts' },
      { label: 'два слова', kind: 'name', q: 'унитаз компакт', expect: 'fts' },
      { label: 'слово + число', kind: 'name', q: 'труба ппр 20', expect: 'fts' },
      { label: 'ввод по буквам (префикс)', kind: 'name', q: 'кран шар', expect: 'fts' },
      { label: 'опечатка в названии', kind: 'name', q: 'смиситель', expect: 'trgm' },
      { label: 'ё/е и регистр', kind: 'name', q: 'КОТЕЛ ГАЗОВЫЙ', expect: 'fts' },
      { label: 'раскладка (cvtcbntkm)', kind: 'name', q: 'cvtcbntkm', expect: 'fts' },
      {
        label: 'фильтр inStock + sort=price:asc',
        kind: 'name',
        q: 'радиатор',
        extra: { inStock: 'true', sort: 'price:asc' },
        expect: 'fts',
      },
    ];

    const kinds = new Set(values.kinds.split(','));
    const queries = allQueries.filter((b) => kinds.has(b.kind));

    // ---------------------------------------------------------------- сервер
    // Nest DI нужен emitDecoratorMetadata: tsx (esbuild) его не выпускает, поэтому сервер компилируется tsc
    // (как `npm run build`) во временный каталог test/search/bench/.dist (удаляется в finally).
    log('tsc -p test/search/bench/tsconfig.bench.json…');
    const tsc = spawn(process.execPath, [require.resolve('typescript/bin/tsc'), '-p', BENCH_TSCONFIG], {
      cwd: API_DIR,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let tscOut = '';
    tsc.stdout?.on('data', (d: Buffer) => (tscOut += d.toString()));
    if ((await waitExit(tsc)) !== 0) log(`tsc: есть ошибки типов (сборка продолжена):\n${tscOut.slice(0, 2000)}`);
    const port = await freePort();
    server = spawn(process.execPath, [join(BENCH_DIST, 'test', 'search', 'bench', 'bench-server.js')], {
      cwd: API_DIR,
      env: {
        ...process.env,
        BENCH_DATABASE_URL: url,
        BENCH_PORT: String(port),
        APP_ENV: 'dev',
        BENCH_LOG_LEVEL: values['log-level'],
        BENCH_WORKERS: values.workers,
      },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    server.stderr?.on('data', (d: Buffer) => process.stderr.write(`[server] ${d.toString()}`));
    await new Promise<void>((ok, fail) => {
      const t = setTimeout(() => fail(new Error('bench-server: нет READY за 120 с')), 120_000);
      server!.stdout?.on('data', (d: Buffer) => {
        if (d.toString().includes('READY')) {
          clearTimeout(t);
          ok();
        }
      });
      server!.on('exit', (c) => fail(new Error(`bench-server завершился: ${c}`)));
    });
    const base = `http://127.0.0.1:${port}`;
    const headers = { 'x-test-principal': principalHeader('seller'), accept: 'application/json' };
    const pathOf = (b: BenchQuery) =>
      `/api/v1/search/products?${new URLSearchParams({ q: b.q, limit: '40', ...(b.extra ?? {}) }).toString()}`;

    // Прогрев + проверка matchType.
    const check: { label: string; q: string; matchType: string | null; total: number; ok: boolean }[] = [];
    for (let round = 0; round < 3; round++) {
      for (const b of queries) {
        const res = await fetch(base + pathOf(b), { headers });
        const body = (await res.json()) as {
          items: { matchType: string | null }[];
          matchTypes: Record<string, number>;
        };
        if (round === 0) {
          const mt = body.items[0]?.matchType ?? null;
          check.push({
            label: b.label,
            q: b.q,
            matchType: mt,
            total: body.matchTypes?.[b.expect] ?? 0,
            ok: res.status === 200 && mt === b.expect,
          });
        }
      }
    }
    const bad = check.filter((c) => !c.ok);
    if (bad.length) log(`ВНИМАНИЕ: неожиданный matchType: ${JSON.stringify(bad)}`);
    const workers = Number(values.workers);
    const warmup = Number(values.warmup);
    if (warmup > 0) {
      log(`прогрев: autocannon -c ${connections} -d ${warmup}…`);
      await new Promise<void>((ok, fail) => {
        autocannon(
          {
            url: base,
            connections,
            duration: warmup,
            headers,
            requests: queries.map((b) => ({ method: 'GET', path: pathOf(b) })),
          },
          (err) => (err ? fail(err) : ok()),
        );
      });
    }
    if (workers === 1) await fetch(`${base}/__bench/reset`, { method: 'POST' });

    // ---------------------------------------------------------------- нагрузка
    log(`autocannon -c ${connections} -d ${duration} по ${queries.length} запросам…`);
    // Задержки на стороне клиента: общий список и по запросу (индекс текущего запроса autocannon в момент ответа —
    // pipelining = 1, следующий запрос выбирается после события response).
    const times: number[] = [];
    const timesByQuery: number[][] = queries.map(() => []);
    const result = await new Promise<AutocannonResult>((ok, fail) => {
      const inst = autocannon(
        {
          url: base,
          connections,
          duration,
          headers,
          requests: queries.map((b) => ({ method: 'GET', path: pathOf(b) })),
        },
        (err, res) => (err ? fail(err) : ok(res)),
      );
      inst.on('response', (client, _s, _b, ms) => {
        times.push(ms);
        const idx = (client as { requestIterator?: { currentRequestIndex?: number } }).requestIterator
          ?.currentRequestIndex;
        if (typeof idx === 'number' && timesByQuery[idx]) timesByQuery[idx].push(ms);
      });
    });
    const serverTimes =
      workers === 1 ? ((await (await fetch(`${base}/__bench/stats`)).json()) as Record<string, number[]>) : {};
    const overall = stats(times);
    const [cpuUserMs, cpuSystemMs, wallMs, elu] = serverTimes.__process ?? [NaN, NaN, NaN, NaN];
    const serverProcess = {
      workers,
      cpuUserMs,
      cpuSystemMs,
      wallMs,
      cpuPerRequestMs: (cpuUserMs + cpuSystemMs) / Math.max(1, times.length),
      eventLoopUtilization: elu,
    };
    if (workers === 1) {
      log(`сервер: CPU ${f1(serverProcess.cpuPerRequestMs)} мс/запрос, загрузка event loop ${f1(elu * 100)} %`);
    }
    const serverKey = (b: BenchQuery) => pathOf(b).replace('/api/v1/search/', '');
    const perQuery = queries.map((b, i) => ({
      ...b,
      ...stats(timesByQuery[i]),
      server: stats(serverTimes[serverKey(b)] ?? []),
    }));
    const byKind = (['barcode', 'sku', 'name'] as const).map((k) => ({
      kind: k,
      ...stats(queries.flatMap((b, i) => (b.kind === k ? timesByQuery[i] : []))),
      server: stats(queries.filter((b) => b.kind === k).flatMap((b) => serverTimes[serverKey(b)] ?? [])),
    }));

    // ---------------------------------------------------------------- EXPLAIN
    const pl = await pool.query<{ id: string; name: string }>(
      `SELECT id::text, name FROM price_lists WHERE NOT deletion_mark ORDER BY (name ILIKE 'розн%') DESC, name LIMIT 1`,
    );
    const wh = await pool.query<{ id: string; name: string }>(
      `SELECT id::text, name FROM warehouses WHERE NOT deletion_mark AND is_active ORDER BY sort_order, name, id LIMIT 1`,
    );
    const viewer: CatalogViewer = {
      userId: '00000000-0000-4000-8000-0000000000a1',
      role: 'seller',
      isCustomer: false,
      canReadPrice: true,
      canReadAllPrices: false,
      priceList: pl.rows[0],
      warehouse: wh.rows[0],
      stockDisplay: 'full',
      lowStockThreshold: '5',
    };
    const explains: { title: string; plan: string }[] = [];
    const explain = async (title: string, text: string, vals: unknown[]) => {
      const c = await pool!.connect();
      try {
        await c.query(SEARCH_TX_BEGIN);
        const r = await c.query<{ 'QUERY PLAN': string }>(`EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) ${text}`, vals);
        explains.push({ title, plan: r.rows.map((x) => x['QUERY PLAN']).join('\n') });
        await c.query('ROLLBACK');
      } finally {
        c.release();
      }
    };
    const stage = async (
      title: string,
      st: SearchStage,
      q: string,
      sort: 'relevance:desc' | 'price:asc' = 'relevance:desc',
      extra = {},
      correctedWords?: string[],
    ) => {
      const built = buildStageQuery({
        stage: st,
        query: classifyQuery(q),
        filters: { includeSubcategories: true, ...extra },
        viewer,
        sort,
        limit: 40,
        ...(correctedWords ? { correctedWords } : {}),
      });
      await explain(title, built.text, built.values);
    };
    // Ступень «триграммы» по названию: исправление слов по словарю search_words, затем поиск исправленного запроса.
    const typoClient = await pool.connect();
    let typoFix: string[] | null;
    try {
      await typoClient.query(SEARCH_TX_BEGIN);
      typoFix = await correctWords(typoClient, classifyQuery('смиситель').words);
      await typoClient.query('ROLLBACK');
    } finally {
      typoClient.release();
    }
    if (!values['skip-explain']) {
      await stage(`barcode: q=${anchorBc.rows[0].value}`, 'barcode', anchorBc.rows[0].value);
      await stage('sku: q=F42 (префикс)', 'sku', 'F42');
      await stage('fts: q=смеситель (много совпадений)', 'fts', 'смеситель');
      await stage('fts: q=смеситель фрап (транслитерация)', 'fts', 'смеситель фрап');
      await stage('fts: q=радиатор, inStock=true, sort=price:asc', 'fts', 'радиатор', 'price:asc', { inStock: true });
      await explain(
        'trgm, шаг 1: исправление слова «смиситель» по словарю search_words',
        `SELECT w.input, fix.word AS fix FROM unnest($1::text[]) AS w(input)
           LEFT JOIN LATERAL (SELECT sw.word FROM search_words sw WHERE sw.word % w.input
                               AND similarity(sw.word, w.input) >= 0.4
                             ORDER BY (sw.word = w.input) DESC, similarity(sw.word, w.input) DESC, sw.freq DESC, sw.word
                             LIMIT 1) fix ON true`,
        [['смиситель']],
      );
      await stage(
        `trgm, шаг 2: поиск исправленного «${(typoFix ?? []).join(' ')}»`,
        'trgm',
        'смиситель',
        'relevance:desc',
        {},
        typoFix ?? undefined,
      );
      await stage('trgm, запасной путь без словаря: q=смиситель (word_similarity по названиям)', 'trgm', 'смиситель');
      await stage('trgm: q=SB-1WJ (артикул с опечаткой)', 'trgm', 'SB-1WJ');
      const sg = buildSuggestQuery(classifyQuery('сме'), 20);
      await explain('suggest: q=сме', sg.text, sg.values);
    }

    const cpu = cpus();
    const out = {
      startedAt: started.toISOString(),
      hardware: {
        cpu: cpu[0]?.model ?? '?',
        logicalCores: cpu.length,
        ramGb: Math.round(totalmem() / 1024 ** 3),
        os: `${platform()} ${release()}`,
        node: process.version,
        postgres: db.version,
        lcCtype: SEARCH_LC_CTYPE,
      },
      params: {
        sku,
        duration,
        warmup: Number(values.warmup),
        connections,
        queries: queries.length,
        workers: Number(values.workers),
        logLevel: values['log-level'],
      },
      seed: { totalMs: seedJson.totalMs, db: seedJson.db },
      db,
      check,
      autocannon: {
        requestsTotal: result.requests.total,
        rps: result.requests.average,
        errors: result.errors,
        timeouts: result.timeouts,
        non2xx: result.non2xx,
        ok2xx: result['2xx'],
        latency: result.latency,
      },
      overall,
      serverProcess,
      byKind,
      perQuery,
      explains,
    };
    const jsonPath = resolve(API_DIR, values.json);
    mkdirSync(dirname(jsonPath), { recursive: true });
    writeFileSync(jsonPath, JSON.stringify(out, null, 2));
    log(`JSON: ${jsonPath}`);
    log(
      `ИТОГ: ${overall.n} ответов, p50 ${f1(overall.p50)} мс, p95 ${f1(overall.p95)} мс, p99 ${f1(overall.p99)} мс; ` +
        `rps ${f1(result.requests.average)}; ошибки ${result.errors}, non-2xx ${result.non2xx}`,
    );
    if (values.report) {
      const rp = resolve(API_DIR, values.report);
      mkdirSync(dirname(rp), { recursive: true });
      writeFileSync(rp.replace(/\.md$/, '.generated.md'), renderReport(out));
      log(`Черновик отчёта: ${rp.replace(/\.md$/, '.generated.md')}`);
    }
    return overall.p95 <= 300 && result.errors === 0 && result.non2xx === 0 && bad.length === 0 ? 0 : 1;
  } finally {
    if (server && server.exitCode === null) {
      server.stdin?.end();
      const exited = await Promise.race([
        waitExit(server),
        new Promise((ok) => setTimeout(() => ok('timeout'), 10_000)),
      ]);
      if (exited === 'timeout') server.kill();
    }
    await pool?.end().catch(() => undefined);
    if (!values.url) await pgServer.stop();
    rmSync(BENCH_DIST, { recursive: true, force: true });
    log('процессы и кластер остановлены');
  }
}

type Stats = ReturnType<typeof stats>;

function renderReport(o: {
  hardware: Record<string, unknown>;
  params: Record<string, unknown>;
  overall: Stats;
  serverProcess: Record<string, number>;
  byKind: ({ kind: string; server: Stats } & Stats)[];
  perQuery: (BenchQuery & Stats & { server: Stats })[];
  autocannon: Record<string, unknown>;
  explains: { title: string; plan: string }[];
  check: { label: string; q: string; matchType: string | null; total: number; ok: boolean }[];
}): string {
  const row = (s: Stats) => `${s.n} | ${f1(s.p50)} | ${f1(s.p95)} | ${f1(s.p99)} | ${f1(s.max)}`;
  const lines: string[] = [];
  lines.push(`# Черновик: результаты search-bench (${new Date().toISOString()})`, '');
  lines.push(
    '```json',
    JSON.stringify(
      { hardware: o.hardware, params: o.params, serverProcess: o.serverProcess, autocannon: o.autocannon },
      null,
      2,
    ),
    '```',
    '',
  );
  lines.push(
    '| Ветвь | n (клиент) | p50 | p95 | p99 | max | p50 сервер | p95 сервер |',
    '|---|---|---|---|---|---|---|---|',
  );
  lines.push(`| все | ${row(o.overall)} | — | — |`);
  for (const k of o.byKind) lines.push(`| ${k.kind} | ${row(k)} | ${f1(k.server.p50)} | ${f1(k.server.p95)} |`);
  lines.push(
    '',
    '| Запрос | q | matchType | найдено | n | p50 | p95 | p99 | max | p95 сервер |',
    '|---|---|---|---|---|---|---|---|---|---|',
  );
  for (const q of o.perQuery) {
    const c = o.check.find((x) => x.label === q.label);
    lines.push(
      `| ${q.label} | \`${q.q}\` | ${c?.matchType ?? '—'} | ${c?.total ?? '—'} | ${row(q)} | ${f1(q.server.p95)} |`,
    );
  }
  for (const e of o.explains) lines.push('', `### ${e.title}`, '', '```text', e.plan, '```');
  return `${lines.join('\n')}\n`;
}

main()
  .then((code) => process.exit(code))
  .catch((e: unknown) => {
    process.stderr.write(`search-bench: ${e instanceof Error ? (e.stack ?? e.message) : String(e)}\n`);
    process.exit(2);
  });
