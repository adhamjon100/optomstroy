// Сборка фрагмента кода теми же подменами и шимами, что и backend.js (lib/alias-plugin.mjs, shims/inject.mjs), для
// проверки шимов в Node против настоящих встроенных модулей. Результат — .build/test/<name>.mjs, импортируется.
import { mkdirSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { createAliasPlugin } from '../../lib/alias-plugin.mjs';
import { BACKEND, BUILD, NM, ROOT, SHIMS } from '../../lib/paths.mjs';
import { loadPiiMap } from '../../pii/pii-transform.mjs';

export async function bundleForTest(name, contents) {
  const esbuild = await import(pathToFileURL(`${NM}/esbuild/lib/main.js`).href);
  const outfile = `${BUILD}/test/${name}.mjs`;
  mkdirSync(`${BUILD}/test`, { recursive: true });
  const report = {};
  await esbuild.build({
    absWorkingDir: ROOT,
    stdin: { contents, resolveDir: BACKEND, sourcefile: `${name}.entry.mjs`, loader: 'js' },
    bundle: true,
    format: 'esm',
    platform: 'browser',
    target: 'es2023',
    outfile,
    minify: false,
    charset: 'utf8',
    logLevel: 'silent',
    mainFields: ['browser', 'module', 'main'],
    conditions: ['browser', 'module'],
    nodePaths: [NM],
    inject: [`${SHIMS}/inject.mjs`],
    define: { 'process.env.NODE_ENV': '"production"', __dirname: '"/vfs"', __filename: '"/vfs/index.js"' },
    plugins: [createAliasPlugin({ piiMap: loadPiiMap(), report })],
    supported: { 'top-level-await': true },
  });
  // ?t= — новый экземпляр модуля на каждый прогон (кэш ESM Node).
  return import(`${pathToFileURL(outfile).href}?t=${Date.now()}`);
}
