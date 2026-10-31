// Сборка построителя снимка (snapshot/builder-entry.mjs) для Node: esbuild platform=node теми же подменами модулей,
// что backend.js (lib/alias-plugin.mjs — pg-shim, pino, подмены dist, замена ПДн синтетики кассира), но встроенные
// модули Node остаются настоящими, а sharp берётся из pos-api/node_modules (только при сборке, в backend.js его нет).
import { builtinModules } from 'node:module';
import { mkdirSync } from 'node:fs';
import { dirname, resolve as resolvePath } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createAliasPlugin } from '../lib/alias-plugin.mjs';
import { BACKEND, BUILD, DIST, NM, ROOT, norm } from '../lib/paths.mjs';
import { loadPiiMap } from '../pii/pii-transform.mjs';

const BUILTINS = new Set(builtinModules.filter((m) => !m.startsWith('_')));

/**
 * Плагин «Node как есть»: встроенные модули и sharp — внешние (настоящие), раньше подмен браузерного бэкенда;
 * dist/common/ids/uuid.js → snapshot/det-ids.mjs (детерминированный UUID v7 только в построителе снимка).
 */
function nodeNativePlugin(report) {
  const sharpUrl = pathToFileURL(`${NM}/sharp/lib/index.js`).href;
  const idsDist = `${DIST}/common/ids/uuid.js`;
  const idsDet = `${BACKEND}/snapshot/det-ids.mjs`;
  return {
    name: 'snapshot-node-native',
    setup(b) {
      b.onResolve({ filter: /.*/ }, (a) => {
        const s = a.path;
        const bare = s.startsWith('node:') ? s.slice(5) : s;
        if (s.startsWith('node:') || BUILTINS.has(bare)) return { path: `node:${bare}`, external: true };
        if (s === 'sharp') {
          report.sharp = (report.sharp ?? 0) + 1;
          return { path: sharpUrl, external: true };
        }
        const importer = norm(a.importer || '');
        if (s.startsWith('.') && importer.startsWith(DIST + '/') && norm(resolvePath(dirname(importer), s)) === idsDist) {
          report.deterministicIds = (report.deterministicIds ?? 0) + 1;
          return { path: idsDet };
        }
        return undefined;
      });
    },
  };
}

/** → { file (абсолютный путь .build/snapshot/builder.mjs), report }. */
export async function bundleBuilder({ outDir = `${BUILD}/snapshot` } = {}) {
  const esbuild = await import(pathToFileURL(`${NM}/esbuild/lib/main.js`).href);
  mkdirSync(outDir, { recursive: true });
  const outfile = `${outDir}/builder.mjs`;
  const report = {};
  const piiMap = loadPiiMap();
  await esbuild.build({
    absWorkingDir: ROOT,
    entryPoints: [`${BACKEND}/snapshot/builder-entry.mjs`],
    bundle: true,
    format: 'esm',
    platform: 'node',
    target: 'node24',
    outfile,
    minify: false,
    charset: 'utf8',
    logLevel: 'silent',
    mainFields: ['module', 'main'],
    conditions: ['node', 'import', 'module'],
    nodePaths: [NM],
    // CJS-пакеты внутри ESM-бандла вызывают require() встроенных модулей.
    banner: { js: "import { createRequire as __posCreateRequire } from 'node:module'; const require = __posCreateRequire(import.meta.url);" },
    plugins: [nodeNativePlugin(report), createAliasPlugin({ piiMap, report, importMetaUrl: 'file' })],
  });
  return { file: outfile, report };
}
