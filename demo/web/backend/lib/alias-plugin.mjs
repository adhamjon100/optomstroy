// Плагин esbuild браузерного бэкенда (WP-B1): подмена встроенных модулей Node шимами (shims/shim-map.mjs),
// пакетов и файлов pos-api — модулями из backend/alias/ (alias-map.mjs, точка расширения WP-B2), перенос
// import.meta.url файлов pos-api в виртуальную fs, замена ПДн синтетики кассира (pii-map.json).
//
// Служебные спецификаторы (только в коде backend/):
//   nm:<путь>               — файл из pos-api/node_modules напрямую, мимо подмен и поля exports пакета;
//   @pos-api-dist/<путь>    — файл .build/pos-api-dist (с подменами DIST_ALIASES);
//   @pos-api-scripts/<файл> — pos-api/scripts/<файл> (pos_fake_onec.ts, транспиляция loader 'ts');
//   pos-vfs-data            — сгенерированный модуль виртуальной fs (.build/gen/vfs-data.cjs).
import { builtinModules } from 'node:module';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve as resolvePath } from 'node:path';
import { pathToFileURL } from 'node:url';
import { DIST_ALIASES, IMPORT_ALIASES, MISSING_PACKAGES, PACKAGE_ALIASES } from '../alias-map.mjs';
import { applyPiiLiterals, applyPiiToSyntheticCashier } from '../pii/pii-transform.mjs';
import { SHIM_MAP } from '../shims/shim-map.mjs';
import { ALIAS, BACKEND, DIST, GEN, NM, SCRIPTS, SHIMS, norm } from './paths.mjs';

const BUILTINS = new Set(builtinModules.filter((m) => !m.startsWith('_')));

/** Владелец файла для отчёта: имя пакета npm, pos-api-dist, pos-api/scripts или backend/<каталог>. */
export function ownerOf(p) {
  const s = norm(p || '');
  const i = s.lastIndexOf('/node_modules/');
  if (i >= 0) {
    const rest = s.slice(i + 14).split('/');
    return rest[0].startsWith('@') ? `${rest[0]}/${rest[1]}` : rest[0];
  }
  if (s.startsWith(DIST + '/')) return 'pos-api-dist';
  if (s.startsWith(SCRIPTS + '/')) return 'pos-api/scripts';
  if (s.startsWith(BACKEND + '/')) return `backend/${s.slice(BACKEND.length + 1).split('/')[0]}`;
  if (s.startsWith(GEN + '/')) return '.build/gen';
  return s;
}

/**
 * @param {{ piiMap: object, report: object, importMetaUrl?: 'vfs' | 'file' }} o
 *   report — объект, куда плагин пишет учёт (builtins, aliased, missing, importMeta, pii, errors).
 *   importMetaUrl — 'vfs' (браузерный бэкенд: адрес в виртуальной fs) или 'file' (построитель снимка в Node,
 *   WP-B4: настоящий file:// URL файла dist, чтобы fileURLToPath работал и на Windows).
 */
export function createAliasPlugin({ piiMap, report, importMetaUrl = 'vfs' }) {
  report.builtinsUsed ??= {};
  report.aliased ??= {};
  report.missing ??= {};
  report.skippedAliases ??= [];
  report.importMetaRewritten ??= [];
  report.pii ??= { syntheticCashier: null, literalFiles: {} };
  report.unknownBuiltins ??= {};
  const bump = (o, k, importer) => {
    o[k] ??= {};
    const who = ownerOf(importer);
    o[k][who] = (o[k][who] ?? 0) + 1;
  };
  const distAlias = new Map();
  for (const [rel, spec] of Object.entries(DIST_ALIASES)) {
    const to = `${BACKEND}/${spec.to}`;
    if (!existsSync(to)) {
      if (spec.optional) {
        report.skippedAliases.push({ dist: rel, to: spec.to, why: 'файла подмены ещё нет (optional)' });
        continue;
      }
      throw new Error(`alias-map: нет файла подмены ${spec.to} для dist/${rel}`);
    }
    distAlias.set(`${DIST}/${rel}`, to);
  }
  const pkgAlias = new Map();
  for (const [pkg, spec] of Object.entries(PACKAGE_ALIASES)) {
    const to = `${BACKEND}/${spec.to}`;
    if (!existsSync(to)) throw new Error(`alias-map: нет файла подмены ${spec.to} для пакета ${pkg}`);
    pkgAlias.set(pkg, to);
  }
  const importAlias = (IMPORT_ALIASES ?? []).map((a) => {
    const to = `${BACKEND}/${a.to}`;
    if (!existsSync(to)) throw new Error(`alias-map: нет файла подмены ${a.to} для импорта ${a.spec} в ${a.importer}`);
    return { ...a, suffix: `/node_modules/${a.importer}`, toAbs: to };
  });
  // Подмена файла dist применяется ко всем импортёрам, кроме самих модулей подмен (они могут обернуть оригинал).
  const mayAlias = (importer) => !norm(importer || '').startsWith(ALIAS + '/');
  const viaDist = (abs, importer) => {
    const p = norm(abs);
    if (distAlias.has(p) && mayAlias(importer)) {
      bump(report.aliased, `dist/${p.slice(DIST.length + 1)}`, importer);
      return distAlias.get(p);
    }
    return p;
  };

  return {
    name: 'pos-browser-alias',
    setup(b) {
      b.onResolve({ filter: /.*/ }, (a) => {
        if (a.kind === 'entry-point') return undefined;
        const spec = a.path;
        const importer = norm(a.importer || '');

        if (spec.startsWith('nm:')) {
          const p = `${NM}/${spec.slice(3)}`;
          if (!existsSync(p)) return { errors: [{ text: `nm: нет файла ${p}` }] };
          return { path: p };
        }
        if (spec === 'pos-vfs-data') return { path: `${GEN}/vfs-data.cjs` };
        for (const ia of importAlias)
          if (spec === ia.spec && importer.endsWith(ia.suffix)) {
            bump(report.aliased, `import ${ia.importer} → ${ia.spec}`, importer);
            return { path: ia.toAbs };
          }
        if (spec.startsWith('@pos-api-dist/')) return { path: viaDist(`${DIST}/${spec.slice('@pos-api-dist/'.length)}`, importer) };
        if (spec.startsWith('@pos-api-scripts/')) return { path: `${SCRIPTS}/${spec.slice('@pos-api-scripts/'.length)}` };

        // встроенные модули Node
        const bare = spec.startsWith('node:') ? spec.slice(5) : spec;
        if (spec.startsWith('node:') || BUILTINS.has(bare)) {
          const shim = SHIM_MAP[bare];
          if (shim === undefined) {
            bump(report.unknownBuiltins, bare, importer);
            return { errors: [{ text: `встроенный модуль Node «${bare}» без шима (импорт из ${ownerOf(importer)}); добавьте его в shims/shim-map.mjs` }] };
          }
          bump(report.builtinsUsed, bare, importer);
          if (typeof shim === 'object') return { path: bare, namespace: 'pos-virtual' };
          return { path: `${SHIMS}/${shim}` };
        }

        if (pkgAlias.has(spec)) {
          bump(report.aliased, spec, importer);
          return { path: pkgAlias.get(spec) };
        }
        if (MISSING_PACKAGES.test(spec)) {
          bump(report.missing, spec, importer);
          return { path: `${ALIAS}/missing.cjs` };
        }

        // относительные импорты внутри pos-api-dist; ../src/* из scripts/pos_fake_onec.ts → pos-api-dist
        if (spec.startsWith('.') && importer) {
          if (importer.startsWith(SCRIPTS + '/') && spec.startsWith('../src/')) {
            return { path: viaDist(`${DIST}/${spec.slice('../src/'.length)}`, importer) };
          }
          if (importer.startsWith(DIST + '/')) {
            const abs = norm(resolvePath(dirname(importer), spec));
            if (distAlias.has(abs)) return { path: viaDist(abs, importer) };
          }
        }
        return undefined;
      });

      b.onLoad({ filter: /.*/, namespace: 'pos-virtual' }, (a) => ({
        contents: SHIM_MAP[a.path].virtual,
        loader: 'js',
        resolveDir: SHIMS,
      }));

      // Файлы pos-api: import.meta.url → адрес в виртуальной fs (/vfs/pos-api/dist/<rel>), чтобы относительные
      // пути к migrations/, assets/ и contracts/ совпали с раскладкой репозитория; замена ПДн.
      b.onLoad({ filter: /[\\/](pos-api-dist[\\/].*\.js|pos-api[\\/]scripts[\\/][^\\/]+\.ts)$/ }, (a) => {
        const p = norm(a.path);
        if (!p.startsWith(DIST + '/') && !p.startsWith(SCRIPTS + '/')) return undefined;
        let src = readFileSync(a.path, 'utf8');
        const rel = p.startsWith(DIST + '/') ? p.slice(DIST.length + 1) : null;
        const vpath = rel ? `/vfs/pos-api/dist/${rel}` : `/vfs/pos-api/scripts/${p.slice(SCRIPTS.length + 1)}`;
        if (src.includes('import.meta.url')) {
          report.importMetaRewritten.push(rel ? `dist/${rel}` : `scripts/${p.slice(SCRIPTS.length + 1)}`);
          const url = importMetaUrl === 'file' ? pathToFileURL(a.path).href : `file://${vpath}`;
          src = src.replace(/\bimport\.meta\.url\b/g, JSON.stringify(url));
        }
        if (rel === piiMap.file) {
          const r = applyPiiToSyntheticCashier(src, piiMap);
          src = r.code;
          report.pii.syntheticCashier = r.report;
        } else {
          const r = applyPiiLiterals(src, piiMap);
          if (r.replaced) {
            src = r.code;
            report.pii.literalFiles[rel ?? p] = r.replaced;
          }
        }
        return { contents: src, loader: p.endsWith('.ts') ? 'ts' : 'js', resolveDir: dirname(a.path) };
      });
    },
  };
}
