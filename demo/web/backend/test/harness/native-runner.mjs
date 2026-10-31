// Эталон WP-T1 для дифференциального теста (plan §4 WP-T1, §5 п. 5): ТА ЖЕ точка входа демо (backend-entry.mjs,
// demo-init, мост, единица работы, pg-shim на PGlite, pg-boss, PosFakeOnec, подмены dist) и тот же скомпилированный
// pos-api (.build/pos-api-dist), но БЕЗ браузерных шимов Node: встроенные модули — настоящие (crypto, buffer, stream,
// events, util, path, url, querystring, zlib, timers, os, async_hooks, perf_hooks, assert, string_decoder…), пакеты
// npm — в своих сборках для Node (conditions node/import, как pos-api на сервере), без shims/inject.mjs.
// Как run-full.mjs спайка, но с тем же протоколом моста, поэтому сценарии гоняются одинаково (worker-harness).
//
// Отличия от «чистого Node», без которых эталон не запускается (записаны в отчёт):
//   - http/https — настоящий node:http (IncomingMessage/ServerResponse) + FakeSocket/res._onEnd для моста
//     (native/http-native.cjs); клиент запрещён, как в шиме;
//   - path — node:path.posix (как у сервера на Linux и шима), url — настоящий node:url, но file:///vfs/… остаются
//     POSIX-путями (на Windows настоящий fileURLToPath такие URL отвергает; native/url-native.cjs);
//   - fs — настоящий node:fs, пути /vfs/… переводятся в каталоги репозитория по таблице vfs/build-vfs.mjs, с теми же
//     преобразованиями (native/fs-native.cjs); demo-init по-прежнему кладёт шрифты PDF в реестр pdfkit через vfs;
//   - pdfkit — его браузерная сборка, как в бандле (сборка для Node читает шрифты AFM с диска и не экспортирует
//     registerStdFonts, которым demo-init регистрирует Helvetica);
//   - подмены демо (alias-map.mjs: pg → pg-shim, pg-boss, argon2 → @noble, pino, jwt-keys, onec-transport…) — те же:
//     это устройство демо, а не шимы; сравнивается именно слой шимов.
//
//   API: await buildNativeReference({ force }) → { file, report }; startNativeBackend(opts) — как startWorkerBackend.
//   CLI: node demo/web/backend/test/harness/native-runner.mjs [--force]  (собрать эталон и запустить /health)
import { builtinModules } from 'node:module';
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createAliasPlugin } from '../../lib/alias-plugin.mjs';
import { BACKEND, BUILD, DIST, NM, ROOT, SITE, norm } from '../../lib/paths.mjs';
import { loadPiiMap } from '../../pii/pii-transform.mjs';
import { VFS_SOURCES } from '../../vfs/build-vfs.mjs';
import { DEMO_DATA, EPOCH_MIGRATION_BASE } from '../../demo-config.mjs';
import { startWorkerBackend } from './worker-harness.mjs';

const HERE = norm(dirname(fileURLToPath(import.meta.url)));
const NATIVE = `${HERE}/native`;
export const REF_DIR = `${BUILD}/reference`;
export const REF_FILE = `${REF_DIR}/backend-native.mjs`;
const BUILTINS = new Set(builtinModules.filter((m) => !m.startsWith('_')));

/** Сведения сборки (define __POS_DEMO_BUILD_JSON__) — те же, что build-backend.mjs вшил в backend.js. */
export function demoBuildInfoFromSite(site = SITE) {
  const b = JSON.parse(readFileSync(`${site}/backend/build.json`, 'utf8'));
  const info = { appVersion: b.appVersion, epochKey: b.epochKey, migrationBase: b.epoch?.migrationBase ?? EPOCH_MIGRATION_BASE, stateFormat: DEMO_DATA.stateFormat };
  if (b.snapshot) info.snapshot = { format: b.snapshot.format, dataSha256: b.snapshot.dataSha256, skuCount: b.snapshot.skuCount };
  return info;
}

export function nativePlugin(report) {
  const httpNative = `${NATIVE}/http-native.cjs`;
  const fsNative = `${NATIVE}/fs-native.cjs`;
  const pdfkitBrowser = `${NM}/pdfkit/js/pdfkit.browser.mjs`;
  return {
    name: 'pos-native-reference',
    setup(b) {
      b.onResolve({ filter: /.*/ }, (a) => {
        const s = a.path;
        const importer = norm(a.importer || '');
        if (importer.startsWith(NATIVE + '/')) {
          if (s === './vfs-map.json') return { path: `${REF_DIR}/vfs-map.json` };
          if (s.startsWith('node:')) return { path: s, external: true };
        }
        const bare = s.startsWith('node:') ? s.slice(5) : s;
        if (s.startsWith('node:') || BUILTINS.has(bare)) {
          report.builtins[bare] = (report.builtins[bare] ?? 0) + 1;
          if (bare === 'http' || bare === 'https') return { path: httpNative };
          if (bare === 'fs') return { path: fsNative };
          if (bare === 'fs/promises') return { path: 'fs/promises', namespace: 'pos-native' };
          if (bare === 'url') return { path: `${NATIVE}/url-native.cjs` };
          if (bare === 'path' || bare === 'path/posix') return { path: `${NATIVE}/path-native.cjs` };
          return { path: `node:${bare}`, external: true };
        }
        if (s === 'pdfkit') {
          report.pdfkitBrowser = (report.pdfkitBrowser ?? 0) + 1;
          return { path: pdfkitBrowser };
        }
        return undefined;
      });
      b.onLoad({ filter: /.*/, namespace: 'pos-native' }, () => ({ contents: `module.exports = require(${JSON.stringify(fsNative)}).promises;`, loader: 'js', resolveDir: NATIVE }));
    },
  };
}

function newestMtime(dirs) {
  let t = 0;
  const walk = (p) => {
    const st = statSync(p);
    if (st.isDirectory()) {
      for (const e of readdirSafe(p)) walk(`${p}/${e}`);
    } else t = Math.max(t, st.mtimeMs);
  };
  for (const d of dirs) if (existsSync(d)) walk(d);
  return t;
}
function readdirSafe(p) {
  try {
    return readdirSync(p);
  } catch {
    return [];
  }
}

/** Собрать эталон (esbuild platform=node). Пересборка — если эталона нет, он старше backend.js или force. */
export async function buildNativeReference({ force = false, quiet = false } = {}) {
  const t0 = Date.now();
  mkdirSync(REF_DIR, { recursive: true });
  const bundleMtime = existsSync(`${SITE}/backend/backend.js`) ? statSync(`${SITE}/backend/backend.js`).mtimeMs : 0;
  const srcMtime = Math.max(newestMtime([`${BACKEND}/alias`, `${BACKEND}/shims`, `${NATIVE}`]), ...['backend-entry.mjs', 'bridge-server.mjs', 'demo-init.mjs', 'demo-storage.mjs', 'demo-control.mjs', 'demo-seed.mjs', 'demo-overlay.mjs', 'demo-config.mjs'].map((f) => statSync(`${BACKEND}/${f}`).mtimeMs));
  if (!force && existsSync(REF_FILE) && statSync(REF_FILE).mtimeMs >= Math.max(bundleMtime, srcMtime)) {
    const report = existsSync(`${REF_DIR}/report.json`) ? JSON.parse(readFileSync(`${REF_DIR}/report.json`, 'utf8')) : {};
    return { file: REF_FILE, report: { ...report, reused: true } };
  }
  writeFileSync(
    `${REF_DIR}/vfs-map.json`,
    JSON.stringify(
      {
        sources: VFS_SOURCES.map((s) => ({ to: s.to, from: norm(s.from), include: s.include.source, flags: s.include.flags })),
        media: `${REF_DIR}/media`,
        dist: DIST,
        missing: `${REF_DIR}/__vfs_missing__`,
      },
      null,
      1,
    ),
  );
  mkdirSync(`${REF_DIR}/media`, { recursive: true });
  const esbuild = await import(pathToFileURL(`${NM}/esbuild/lib/main.js`).href);
  const report = { builtins: {}, startedAt: new Date().toISOString() };
  const aliasReport = {};
  const info = demoBuildInfoFromSite();
  const result = await esbuild.build({
    absWorkingDir: ROOT,
    entryPoints: [`${BACKEND}/backend-entry.mjs`],
    bundle: true,
    format: 'esm',
    platform: 'node',
    target: 'node24',
    outfile: REF_FILE,
    minify: false,
    charset: 'utf8',
    logLevel: 'silent',
    metafile: true,
    // как Node: main раньше module; условия node + import/require по виду импорта (esbuild добавляет их сам)
    mainFields: ['main', 'module'],
    conditions: ['node'],
    nodePaths: [NM],
    banner: { js: "import { createRequire as __posCreateRequire } from 'node:module'; const require = __posCreateRequire(import.meta.url);" },
    define: {
      'process.env.NODE_ENV': '"production"',
      __dirname: '"/vfs"',
      __filename: '"/vfs/index.js"',
      __POS_DEMO_BUILD_JSON__: JSON.stringify(JSON.stringify(info)),
    },
    plugins: [nativePlugin(report), createAliasPlugin({ piiMap: loadPiiMap(), report: aliasReport, importMetaUrl: 'vfs' })],
    supported: { 'top-level-await': true },
  }).catch((e) => {
    const errs = (e.errors ?? []).map((x) => `${x.text} @ ${x.location?.file}:${x.location?.line}`);
    throw new Error(`эталон: esbuild ${errs.length} ошибок:\n${errs.slice(0, 20).join('\n')}`);
  });
  const shimInputs = Object.keys(result.metafile.inputs).filter((f) => /demo[\\/]web[\\/]backend[\\/]shims[\\/]/.test(f));
  report.shimInputs = shimInputs; // ожидается только shims/node-fs.cjs (+ его buffer/path) и net-guard.mjs: demo-init импортирует их напрямую
  report.pii = aliasReport.pii?.syntheticCashier ? 'applied' : 'missing';
  report.aliased = Object.keys(aliasReport.aliased ?? {});
  report.bytes = statSync(REF_FILE).size;
  report.ms = Date.now() - t0;
  report.demoBuildInfo = info;
  writeFileSync(`${REF_DIR}/report.json`, JSON.stringify(report, null, 1));
  if (!quiet) console.log(`[native-runner] эталон ${REF_FILE}: ${(report.bytes / 1e6).toFixed(2)} МБ за ${report.ms} мс; шимы в эталоне: ${shimInputs.map((f) => f.split(/[\\/]/).pop()).join(', ')}`);
  return { file: REF_FILE, report };
}

/** Запустить эталон в worker_threads тем же протоколом моста (opts — как у startWorkerBackend). */
export async function startNativeBackend(opts = {}) {
  const { file } = await buildNativeReference({ quiet: true });
  return startWorkerBackend({ ...opts, backendFile: file });
}

// ---------------------------------------------------------------- CLI
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const r = await buildNativeReference({ force: process.argv.includes('--force') });
  console.log(JSON.stringify({ ...r.report, demoBuildInfo: undefined }, null, 1).slice(0, 3000));
  const be = await startNativeBackend({ sku: 500, initOpts: { seed: false }, onLog: (lv, m) => console.log(`[ref ${lv}]`, String(m).slice(0, 300)) });
  console.log('ready', be.initMs, 'ms', JSON.stringify(be.ready.timings).slice(0, 600));
  const h = await be.api('GET', '/health', { headers: { 'X-Device-Id': crypto.randomUUID(), 'X-App-Version': be.ready.appVersion } });
  console.log('/health', h.status, JSON.stringify(h.json));
  await be.close();
}
