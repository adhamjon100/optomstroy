// Проверки сборки браузерного бэкенда (WP-B1): подмены dist экспортируют всё, что экспортирует оригинал; в
// metafile нет неразрешённых node:* и внешних импортов; нет Proxy-заглушек и «отсутствующих» пакетов на пути
// исполнения; в бандле нет запрещённых строк ПДн; перечень внешних адресов-литералов (для отчёта).
import { existsSync, readFileSync } from 'node:fs';
import { DIST_ALIASES } from '../alias-map.mjs';
import { ownerOf } from './alias-plugin.mjs';
import { ALIAS, BACKEND, DIST, ROOT, SHIMS, norm } from './paths.mjs';

const INJECT = `${SHIMS}/inject.mjs`;

// Пути metafile — относительно absWorkingDir сборки (корень репозитория).
const absOf = (file) => {
  const s = norm(file);
  return /^[A-Za-z]:\//.test(s) ? s : `${ROOT}/${s}`;
};

async function exportsOf(esbuild, file) {
  const r = await esbuild.build({
    entryPoints: [file],
    bundle: false,
    write: false,
    metafile: true,
    format: 'esm',
    platform: 'neutral',
    logLevel: 'silent',
    outdir: '/__exports__',
  });
  const out = Object.values(r.metafile.outputs)[0];
  return out?.exports ?? [];
}

/** Подмена файла dist должна экспортировать все его имена (иначе импортёр получил бы undefined). */
export async function checkDistAliases(esbuild) {
  const res = [];
  for (const [rel, spec] of Object.entries(DIST_ALIASES)) {
    const orig = `${DIST}/${rel}`;
    const to = `${BACKEND}/${spec.to}`;
    if (!existsSync(orig)) throw new Error(`alias-map: в pos-api-dist нет файла ${rel} (pos-api изменился — обновите alias-map.mjs)`);
    if (!existsSync(to)) {
      res.push({ dist: rel, to: spec.to, status: spec.optional ? 'skipped (нет файла подмены, optional)' : 'MISSING' });
      continue;
    }
    const a = await exportsOf(esbuild, orig);
    const b = new Set(await exportsOf(esbuild, to));
    const missing = a.filter((x) => !b.has(x));
    if (missing.length) throw new Error(`alias-map: ${spec.to} не экспортирует ${missing.join(', ')} из dist/${rel}`);
    res.push({ dist: rel, to: spec.to, exports: a.length, status: 'ok' });
  }
  return res;
}

export function checkMetafile(metafile) {
  const unresolved = [];
  const nodeImports = [];
  const missingEager = [];
  const missingLazy = [];
  for (const [file, info] of Object.entries(metafile.inputs)) {
    for (const imp of info.imports ?? []) {
      // esbuild помечает в metafile внедрённый модуль (inject) и свой <runtime> как external — это не импорты.
      if (imp.path === '<runtime>' || absOf(imp.path) === INJECT) continue;
      if (imp.external) unresolved.push({ from: ownerOf(absOf(file)), path: imp.path, kind: imp.kind });
      if (imp.path.startsWith('node:')) nodeImports.push({ from: ownerOf(absOf(file)), path: imp.path, kind: imp.kind });
      if (absOf(imp.path) === `${ALIAS}/missing.cjs`) {
        const rec = { from: norm(absOf(file)).replace(`${ROOT}/`, ''), kind: imp.kind, original: imp.original ?? null };
        if (imp.kind === 'require-call' || imp.kind === 'dynamic-import') missingLazy.push(rec);
        else missingEager.push(rec);
      }
    }
  }
  return { unresolved, nodeImports, missingEager, missingLazy };
}

/** Proxy-заглушки среди наших модулей подмен и шимов: `module.exports = new Proxy` / `export default new Proxy`. */
export function checkProxyStubs(metafile) {
  const stubs = [];
  const proxyUses = [];
  for (const file of Object.keys(metafile.inputs)) {
    const abs = absOf(file);
    if (!abs.startsWith(`${BACKEND}/`) || !existsSync(abs)) continue;
    const src = readFileSync(abs, 'utf8');
    if (/module\.exports\s*=\s*new\s+Proxy|export\s+default\s+new\s+Proxy|exports\s*=\s*new\s+Proxy/.test(src)) stubs.push(abs.replace(`${ROOT}/`, ''));
    src.split('\n').forEach((line, i) => {
      if (/new\s+Proxy\s*\(/.test(line) && !/^\s*\/\//.test(line)) proxyUses.push(`${abs.replace(`${ROOT}/`, '')}:${i + 1}`);
    });
  }
  return { stubs, proxyUses };
}

export function checkOutput(text, forbidden) {
  const nodeInOutput = [...text.matchAll(/(?:from\s*|import\s*\(\s*|require\s*\(\s*)["'`]node:[a-z_/]+["'`]/g)].map((m) => m[0]).slice(0, 20);
  const pii = [];
  for (const f of forbidden) {
    const n = text.split(f).length - 1;
    if (n) pii.push({ string: f, count: n });
  }
  const hosts = {};
  for (const m of text.matchAll(/\b(?:https?|wss?):\/\/([a-zA-Z0-9.-]+\.[a-zA-Z]{2,})/g)) hosts[m[1]] = (hosts[m[1]] ?? 0) + 1;
  const sortedHosts = Object.fromEntries(Object.entries(hosts).sort((a, b) => b[1] - a[1]));
  // Оставшиеся динамические import(…) и вызовы рантайм-помощника esbuild __require («Dynamic require of … is not
  // supported», внутри — Proxy рантайма esbuild, это не заглушка пакета): для отчёта, с контекстом.
  const ctx = (i) => text.slice(Math.max(0, i - 70), i + 50).replace(/\s+/g, ' ');
  const dynamicImports = [...text.matchAll(/\bimport\(/g)].map((m) => ctx(m.index));
  const helper = /var ([A-Za-z_$][\w$]*)=\(\w=>typeof require<"u"\?require:typeof Proxy<"u"\?new Proxy\(/.exec(text);
  let dynamicRequire = [];
  if (helper) {
    const name = helper[1].replace(/\$/g, '\\$');
    dynamicRequire = [...text.matchAll(new RegExp(`(?<![\\w$.])${name}\\(`, 'g'))].map((m) => ctx(m.index));
  }
  return { nodeInOutput, pii, urlHosts: sortedHosts, dynamicImports, dynamicRequire };
}

const PIGGY_MODES = new Set(['scope', 'unit', 'idle']);
/**
 * WP-B2: белый список подсадок pg-shim (alias/piggyback-allow.json) — формат и обоснования. Ключ — fingerprint()
 * pg-shim («глагол таблица»), режимы ⊆ {scope, unit, idle}, у каждой записи where и why; ключи не повторяются.
 * Модули поддержки (SUPPORT_MODULES alias-map.mjs) существуют.
 */
export function checkPiggybackAllow(supportModules = []) {
  const problems = [];
  for (const m of supportModules) if (!existsSync(`${BACKEND}/${m}`)) problems.push(`нет модуля ${m}`);
  const file = `${ALIAS}/piggyback-allow.json`;
  let list = null;
  try {
    list = JSON.parse(readFileSync(file, 'utf8'));
  } catch (e) {
    problems.push(`piggyback-allow.json не читается: ${e.message}`);
    return { entries: 0, problems };
  }
  const seen = new Set();
  for (const [i, e] of (list.entries ?? []).entries()) {
    const at = `entries[${i}]${e?.key ? ` «${e.key}»` : ''}`;
    if (typeof e?.key !== 'string' || !/^[a-z]+( [a-z0-9_.$]+)?$/.test(e.key)) problems.push(`${at}: key — «глагол таблица» в нижнем регистре`);
    if (seen.has(e?.key)) problems.push(`${at}: ключ повторяется`);
    seen.add(e?.key);
    if (!Array.isArray(e?.modes) || e.modes.length === 0 || e.modes.some((m) => !PIGGY_MODES.has(m))) problems.push(`${at}: modes ⊆ scope|unit|idle, не пусто`);
    if (!e?.where || !e?.why) problems.push(`${at}: нужны where и why`);
  }
  if (!Array.isArray(list.entries) || list.entries.length === 0) problems.push('piggyback-allow.json: пустой список');
  return { entries: list.entries?.length ?? 0, keys: [...seen], problems };
}
