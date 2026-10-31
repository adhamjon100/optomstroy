// Эталон на НАСТОЯЩЕМ PostgreSQL (review fixes, critic [18]): тот же backend-entry.mjs, demo-init, мост, единица
// работы, pos-api dist и PosFakeOnec, что у эталона native-runner.mjs, но pg и pg-boss — настоящие (node-postgres и
// pg-boss на пулах соединений к серверу PostgreSQL 17 из pos-api/node_modules/embedded-postgres), а demo-init получает
// «PGlite»-фасад над одним соединением (test/realpg/fake-pglite). Порты 3000/8080/8091/8092 local-stack не трогаются:
// сервер слушает свободный порт 127.0.0.1, данные — во временном каталоге .tmp/web_demo/realpg (удаляется).
// База каждого прогона создаётся как у local-stack serve: UTF8, LOCALE_PROVIDER builtin 'C.UTF-8', LC_COLLATE 'C',
// LC_CTYPE en-US (Windows), timezone UTC.
//
//   API: await startRealPg() → { url(db), admin, stop() }; await buildRealPgReference(); startRealPgBackend(pgs, opts)
import { createHash, randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import net from 'node:net';
import { dirname, resolve as resolvePath } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { createAliasPlugin } from '../../lib/alias-plugin.mjs';
import { BACKEND, BUILD, NM, ROOT, norm } from '../../lib/paths.mjs';
import { loadPiiMap } from '../../pii/pii-transform.mjs';
import { buildNativeReference, demoBuildInfoFromSite, nativePlugin } from '../harness/native-runner.mjs';
import { startWorkerBackend } from '../harness/worker-harness.mjs';

const HERE = norm(dirname(fileURLToPath(import.meta.url)));
export const RPG_DIR = `${BUILD}/realpg`;
export const RPG_FILE = `${RPG_DIR}/backend-realpg.mjs`;
const DATA_ROOT = `${ROOT}/.tmp/web_demo/realpg`;
const require = createRequire(`${ROOT}/pos-api/package.json`);

function realPgPlugin(report) {
  const shimFile = `${BACKEND}/alias/pg-shim.mjs`;
  const bossFile = `${BACKEND}/alias/pgboss-shim.mjs`;
  return {
    name: 'pos-realpg',
    setup(b) {
      b.onResolve({ filter: /.*/ }, (a) => {
        if (a.kind === 'entry-point') return undefined;
        const s = a.path;
        if (s === 'pg') {
          report.pg = (report.pg ?? 0) + 1;
          return { path: `${NM}/pg/lib/index.js` };
        }
        if (s === 'pg-boss') return { path: `${HERE}/pgboss-real.mjs` };
        if (s.startsWith('.') && a.importer) {
          const abs = norm(resolvePath(dirname(a.importer), s));
          if (abs === shimFile) {
            report.pgShim = (report.pgShim ?? 0) + 1;
            return { path: `${HERE}/pg-real.mjs` };
          }
          if (abs === bossFile) return { path: `${HERE}/pgboss-real.mjs` };
        }
        return undefined;
      });
    },
  };
}

/** Собрать эталон на PostgreSQL (esbuild platform=node; те же подмены демо, кроме pg/pg-boss). */
export async function buildRealPgReference({ quiet = false } = {}) {
  const t0 = Date.now();
  await buildNativeReference({ quiet: true }); // vfs-map.json и native/* — общие с эталоном native-runner
  mkdirSync(RPG_DIR, { recursive: true });
  const esbuild = await import(pathToFileURL(`${NM}/esbuild/lib/main.js`).href);
  const report = { builtins: {}, startedAt: new Date().toISOString() };
  const info = demoBuildInfoFromSite();
  await esbuild.build({
    absWorkingDir: ROOT,
    entryPoints: [`${BACKEND}/backend-entry.mjs`],
    bundle: true,
    format: 'esm',
    platform: 'node',
    target: 'node24',
    outfile: RPG_FILE,
    minify: false,
    charset: 'utf8',
    logLevel: 'silent',
    mainFields: ['main', 'module'],
    conditions: ['node'],
    nodePaths: [NM],
    banner: { js: "import { createRequire as __posCreateRequire } from 'node:module'; const require = __posCreateRequire(import.meta.url);" },
    define: { 'process.env.NODE_ENV': '"production"', __dirname: '"/vfs"', __filename: '"/vfs/index.js"', __POS_DEMO_BUILD_JSON__: JSON.stringify(JSON.stringify(info)) },
    plugins: [realPgPlugin(report), nativePlugin(report), createAliasPlugin({ piiMap: loadPiiMap(), report: {}, importMetaUrl: 'vfs' })],
    supported: { 'top-level-await': true },
  }).catch((e) => {
    const errs = (e.errors ?? []).map((x) => `${x.text} @ ${x.location?.file}:${x.location?.line}`);
    throw new Error(`эталон на PostgreSQL: esbuild ${errs.length} ошибок:\n${errs.slice(0, 20).join('\n')}`);
  });
  report.bytes = statSync(RPG_FILE).size;
  report.ms = Date.now() - t0;
  writeFileSync(`${RPG_DIR}/report.json`, JSON.stringify(report, null, 1));
  if (!quiet) console.log(`[realpg] эталон ${RPG_FILE}: ${(report.bytes / 1e6).toFixed(2)} МБ за ${report.ms} мс; pg-shim → pg-real ×${report.pgShim ?? 0}`);
  return { file: RPG_FILE, report };
}

const freePort = () =>
  new Promise((res, rej) => {
    const s = net.createServer();
    s.once('error', rej);
    s.listen(0, '127.0.0.1', () => {
      const p = s.address().port;
      s.close(() => res(p));
    });
  });

/** Запустить временный PostgreSQL 17 (embedded-postgres). → { port, password, admin(sql), url(db), createDb(name), stop() } */
export async function startRealPg({ log = () => {} } = {}) {
  const { default: EmbeddedPostgres } = await import(pathToFileURL(`${NM}/embedded-postgres/dist/index.js`).href);
  const pg = require('pg');
  const dir = `${DATA_ROOT}/pg-${Date.now()}`;
  mkdirSync(dir, { recursive: true });
  const password = randomBytes(18).toString('base64url');
  let port = await freePort();
  for (const bad of [3000, 8080, 8091, 8092]) if (port === bad) port = await freePort();
  const server = new EmbeddedPostgres({
    databaseDir: `${dir}/data`,
    user: 'postgres',
    password,
    port,
    persistent: false,
    initdbFlags: ['--encoding=UTF8', '--locale=C'],
    postgresFlags: ['-c', 'listen_addresses=127.0.0.1', '-c', 'fsync=off', '-c', 'timezone=UTC', '-c', 'max_connections=200'],
    onLog: () => undefined,
    onError: () => undefined,
  });
  await server.initialise();
  await server.start();
  const url = (db) => `postgres://postgres:${encodeURIComponent(password)}@127.0.0.1:${port}/${db}`;
  const admin = async (sql, values) => {
    const c = new pg.Client({ connectionString: url('postgres') });
    await c.connect();
    try {
      return await c.query(sql, values);
    } finally {
      await c.end();
    }
  };
  const v = (await admin('SHOW server_version')).rows[0].server_version;
  log(`[realpg] PostgreSQL ${v} на 127.0.0.1:${port} (${dir})`);
  let n = 0;
  return {
    port,
    password,
    version: v,
    dir,
    url,
    admin,
    /** База как у local-stack serve (locale builtin C.UTF-8, collate C). */
    async createDb() {
      const name = `pos_realpg_${++n}`;
      const ctype = process.platform === 'win32' ? 'en-US' : 'C.UTF-8';
      await admin(`CREATE DATABASE ${name} TEMPLATE template0 ENCODING 'UTF8' LOCALE_PROVIDER builtin BUILTIN_LOCALE 'C.UTF-8' LC_COLLATE 'C' LC_CTYPE '${ctype}'`);
      return name;
    },
    async query(db, sql, values) {
      const c = new pg.Client({ connectionString: url(db) });
      await c.connect();
      try {
        return await c.query(sql, values);
      } finally {
        await c.end();
      }
    },
    async stop() {
      await server.stop().catch(() => undefined);
      rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 300 });
    },
  };
}

/** Бэкенд на настоящем PostgreSQL тем же протоколом моста (opts — как у startWorkerBackend). */
export async function startRealPgBackend(pgs, opts = {}) {
  const { file } = existsSync(RPG_FILE) ? { file: RPG_FILE } : await buildRealPgReference({ quiet: true });
  const db = await pgs.createDb();
  // окружение воркера (startWorkerBackend передаёт process.env): node-postgres берёт PG* по умолчанию
  Object.assign(process.env, {
    PGHOST: '127.0.0.1',
    PGPORT: String(pgs.port),
    PGUSER: 'postgres',
    PGPASSWORD: pgs.password,
    PGDATABASE: db,
    POS_REALPG_COPY_DIR: `${pgs.dir}/copy`,
    POS_REALPG_NM_ANCHOR: `${ROOT}/pos-api/package.json`,
  });
  const be = await startWorkerBackend({
    ...opts,
    backendFile: file,
    initOpts: { ...(opts.initOpts ?? {}), pgliteBase: pathToFileURL(`${HERE}/fake-pglite/`).href, env: { ...(opts.initOpts?.env ?? {}), DATABASE_URL: pgs.url(db) } },
  });
  be.realPgDb = db;
  return be;
}

/** sha256 входных файлов эталона (для отчёта). */
export function realPgInputsSha() {
  const h = createHash('sha256');
  for (const f of ['pg-real.mjs', 'pgboss-real.mjs', 'fake-pglite/index.js']) h.update(readFileSync(`${HERE}/${f}`));
  return h.digest('hex').slice(0, 16);
}
