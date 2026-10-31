// THIRD_PARTY_NOTICES.txt для сайта веб-демо (WP-B1; критик [11]). Состав backend.js берётся из metafile esbuild:
// каждый пакет npm, чей файл попал в бандл, — имя, версия, лицензия (package.json) и полный текст файла лицензии
// из пакета (LICENSE*, LICENCE*, COPYING*, NOTICE*). Если в пакете нет файла лицензии — стандартный текст по SPDX
// из notices/texts/ с правообладателем из package.json. Плюс компоненты сайта вне бандла: PGlite и PostgreSQL,
// шрифты Inter и Roboto, SQLite (sqlite3.wasm), sqlite3.dart и drift (drift_worker.js), и комментарии /*! … */ и
// @license, которые esbuild вынес из бандла (legalComments: 'external').
//
// Review fixes (critic [11]):
//  - раздел 6 «Приложение (Flutter)»: полный перечень — assets/NOTICES сборки Flutter (main.dart.js, среда Dart,
//    CanvasKit/Skia, MaterialIcons, пакеты Dart) и среда dart2js в drift_worker.js;
//  - Roboto описан ровно тем файлом, который публикует сборка сайта (fonts/roboto/v32/KFOmCnqEu92Fr1Me4GZLCzYlKw.woff2 —
//    копия roboto-regular.ttf из Flutter SDK), с лицензией Apache-2.0 и её текстом из SDK;
//  - пути pub-кэша и Flutter SDK — из окружения (PUB_CACHE, FLUTTER_ROOT, LOCALAPPDATA, PATH), версии drift и sqlite3 —
//    из pos-app/pubspec.lock; нет источника лицензии — ошибка сборки (problems), а не текст-заглушка на сайте.
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname } from 'node:path';
import { API, BACKEND, PGLITE_DIR, ROOT, norm } from '../lib/paths.mjs';

const TEXTS = `${BACKEND}/notices/texts`;
const LICENSE_FILE = /^(licen[sc]e|copying|notice)([-._].*)?$/i;

/** Каталог пакетов pub.dev в pub-кэше: PUB_CACHE_HOSTED | PUB_CACHE/hosted/pub.dev | %LOCALAPPDATA%/Pub/Cache/hosted/pub.dev. */
export function pubHostedDir(env = process.env) {
  const cands = [env.PUB_CACHE_HOSTED, env.PUB_CACHE && `${env.PUB_CACHE}/hosted/pub.dev`, env.LOCALAPPDATA && `${env.LOCALAPPDATA}/Pub/Cache/hosted/pub.dev`, env.HOME && `${env.HOME}/.pub-cache/hosted/pub.dev`].filter(Boolean).map(norm);
  return cands.find((d) => existsSync(d)) ?? cands[0] ?? null;
}

/** Корень Flutter SDK: FLUTTER_ROOT или каталог над bin/flutter(.bat) из PATH. */
export function flutterRoot(env = process.env) {
  if (env.FLUTTER_ROOT && existsSync(env.FLUTTER_ROOT)) return norm(env.FLUTTER_ROOT);
  try {
    const out = execFileSync(process.platform === 'win32' ? 'where.exe' : 'which', ['flutter'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    const first = out.split(/\r?\n/).map((s) => s.trim()).find(Boolean);
    if (first) return norm(dirname(dirname(first)));
  } catch {
    /* flutter нет в PATH */
  }
  return null;
}

/** Версия пакета из pos-app/pubspec.lock (то, с чем собраны drift_worker.js и sqlite3.wasm). */
export function lockedVersion(name, lockFile = `${ROOT}/pos-app/pubspec.lock`) {
  if (!existsSync(lockFile)) return null;
  const text = readFileSync(lockFile, 'utf8').replace(/\r\n/g, '\n');
  const m = new RegExp(`\\n  ${name}:\\n(?:    .*\\n)*?    version: "([^"]+)"`).exec(text);
  return m ? m[1] : null;
}

/** Файл Roboto, который сборка сайта кладёт по адресу fontFallbackBaseUrl Flutter (WP-N1). */
export const ROBOTO_SITE_PATH = 'fonts/roboto/v32/KFOmCnqEu92Fr1Me4GZLCzYlKw.woff2';
export function robotoSource(env = process.env) {
  const root = flutterRoot(env);
  const dir = env.FLUTTER_MATERIAL_FONTS ? norm(env.FLUTTER_MATERIAL_FONTS) : root ? `${root}/bin/cache/artifacts/material_fonts` : null;
  return dir ? { font: `${dir}/roboto-regular.ttf`, license: `${dir}/roboto_license.txt`, dir } : null;
}

function pkgRootOf(file) {
  const s = norm(file);
  const i = s.lastIndexOf('/node_modules/');
  if (i < 0) return null;
  const rest = s.slice(i + 14).split('/');
  const name = rest[0].startsWith('@') ? `${rest[0]}/${rest[1]}` : rest[0];
  return { root: `${s.slice(0, i + 14)}${name}`, name };
}

function licenseFiles(dir) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => LICENSE_FILE.test(f) && statSync(`${dir}/${f}`).isFile())
    .sort()
    .map((f) => ({ file: f, text: readFileSync(`${dir}/${f}`, 'utf8').replace(/\r\n/g, '\n').trim() }));
}

function spdxOf(pkg) {
  if (typeof pkg.license === 'string') return pkg.license;
  if (pkg.license && typeof pkg.license.type === 'string') return pkg.license.type;
  if (Array.isArray(pkg.licenses)) return pkg.licenses.map((l) => l.type ?? l).join(' OR ');
  return 'UNKNOWN';
}
function authorOf(pkg) {
  const a = pkg.author;
  if (!a) return null;
  if (typeof a === 'string') return a;
  return [a.name, a.email ? `<${a.email}>` : null].filter(Boolean).join(' ');
}

function standardText(spdx, holder) {
  const id = spdx.replace(/[()]/g, '').split(/\s+(?:OR|AND)\s+/i)[0].trim();
  const f = `${TEXTS}/${id}.txt`;
  if (!existsSync(f)) return null;
  return readFileSync(f, 'utf8')
    .replace(/\r\n/g, '\n')
    .replace('<copyright holders>', holder || 'the authors of this package (see its package.json)')
    .trim();
}

const rule = (c = '=') => c.repeat(78);

/**
 * @param {object} o
 * @param {object} o.metafile  metafile esbuild основного бандла
 * @param {string} o.legalText содержимое backend.js.LEGAL.txt (может быть пустым)
 * @param {object} o.pglite    итог copyPglite()
 * @param {object} o.build     ревизия (build.json)
 * @param {string} [o.flutterNotices] assets/NOTICES сборки Flutter (раздел 6; нет файла — предупреждение)
 */
export function buildNotices({ metafile, legalText, pglite, build, flutterNotices = `${ROOT}/demo/web/.build/flutter/assets/NOTICES` }) {
  const pkgs = new Map();
  let ownBytes = 0;
  for (const [file, info] of Object.entries(metafile.inputs)) {
    if (file.startsWith('(disabled):')) continue; // пустой модуль по полю browser: false пакета
    const f = norm(file);
    const abs = /^[A-Za-z]:\//.test(f) ? f : `${ROOT}/${f}`; // пути metafile — от корня репозитория
    const pr = pkgRootOf(abs);
    if (!pr) {
      ownBytes += info.bytes;
      continue;
    }
    const root = pr.root;
    if (!pkgs.has(root)) pkgs.set(root, { name: pr.name, root, bytes: 0, files: 0 });
    const e = pkgs.get(root);
    e.bytes += info.bytes;
    e.files++;
  }
  const problems = [];
  const entries = [];
  for (const e of [...pkgs.values()].sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))) {
    const pj = JSON.parse(readFileSync(`${e.root}/package.json`, 'utf8'));
    const spdx = spdxOf(pj);
    let texts = licenseFiles(e.root);
    let note = null;
    if (!texts.length) {
      const holder = authorOf(pj);
      const std = standardText(spdx, holder);
      if (std) {
        texts = [{ file: `стандартный текст ${spdx} (в пакете нет файла лицензии)`, text: std }];
        note = 'license-file-missing';
      } else problems.push(`${pj.name}@${pj.version}: нет файла лицензии и нет стандартного текста для «${spdx}»`);
    }
    entries.push({ name: pj.name, version: pj.version, spdx, path: norm(e.root).replace(`${ROOT}/`, ''), bytes: e.bytes, texts, note, repo: typeof pj.repository === 'string' ? pj.repository : pj.repository?.url ?? null });
  }

  const out = [];
  out.push(rule());
  out.push('THIRD_PARTY_NOTICES — веб-демо «Оптомстрой POS» (тестовая демонстрация, не боевая система)');
  out.push(rule());
  out.push(`Сформировано: ${build.builtAt} · demo/web/backend/notices/build-notices.mjs`);
  out.push(`Ревизия pos-api: ${build.gitHead}, sha256(git diff HEAD -- pos-api) = ${build.posApiDiffSha256}`);
  out.push('');
  out.push('Сайт содержит компоненты третьих сторон. Ниже — перечень и полные тексты их лицензий.');
  out.push('This site contains third-party components; their licence notices follow.');
  out.push('');
  out.push('Собственный код:');
  out.push('  pos-api (сервер «Оптомстрой POS», скомпилированный и минифицированный в backend/backend.js) и');
  out.push('  приложение «Оптомстрой POS» — не открытое ПО (package.json: UNLICENSED). Код опубликован в составе');
  out.push('  демо по решению владельца (а) от 2026-10-29 только для просмотра; это не предоставление лицензии.');
  out.push('  Все права защищены (ADR-113 п. 11 (а)). All rights reserved; view only, no licence granted.');
  out.push('');
  out.push('Разделы:');
  out.push(`  1. backend/backend.js — пакеты npm, вошедшие в бандл (${entries.length}), по metafile esbuild`);
  out.push(`  2. backend/pglite/ — PGlite ${pglite.version}, PostgreSQL и OpenSSL (pgcrypto)`);
  out.push(`  3. Шрифты: Inter (backend/vfs/…, assets/…), Roboto (${ROBOTO_SITE_PATH})`);
  out.push('  4. SQLite (sqlite3.wasm), sqlite3.dart, drift (drift_worker.js)');
  out.push('  5. Комментарии /*! … */ и @license, вынесенные esbuild из backend/backend.js');
  out.push('  6. Приложение (Flutter): main.dart.js, CanvasKit, шрифты и пакеты Dart — полный перечень в assets/NOTICES');
  out.push('');
  out.push(rule());
  out.push('1. backend/backend.js — пакеты npm');
  out.push(rule());
  for (const e of entries) out.push(`  ${`${e.name}@${e.version}`.padEnd(52)} ${e.spdx}`);
  out.push('');
  for (const e of entries) {
    out.push(rule('-'));
    out.push(`${e.name}@${e.version} — ${e.spdx}${e.repo ? ` — ${e.repo}` : ''}`);
    out.push(rule('-'));
    for (const t of e.texts) {
      if (e.texts.length > 1 || e.note) out.push(`[${t.file}]`);
      out.push(t.text);
      out.push('');
    }
  }

  out.push(rule());
  out.push(`2. backend/pglite/ — PGlite ${pglite.version} (@electric-sql/pglite) и PostgreSQL`);
  out.push(rule());
  out.push('PGlite распространяется на условиях Apache License 2.0 или PostgreSQL License (на выбор, см. README');
  out.push('PGlite); изменения исходников Postgres — PostgreSQL License. pglite.wasm и pglite.data содержат PostgreSQL');
  out.push('17 (WebAssembly-сборка); расширения pgcrypto, pg_trgm, unaccent (*.tar.gz) — модули contrib PostgreSQL');
  out.push('(PostgreSQL License; в pgcrypto есть код под BSD-подобными лицензиями авторов, см. contrib/pgcrypto в');
  out.push('исходниках PostgreSQL). Файлы скопированы без изменений, sha256 — в demo/web/backend/pglite.lock.json.');
  out.push('');
  out.push('[LICENSE из пакета @electric-sql/pglite]');
  out.push(readFileSync(`${PGLITE_DIR}/LICENSE`, 'utf8').replace(/\r\n/g, '\n').trim());
  out.push('');
  out.push('[PostgreSQL License]');
  out.push(readFileSync(`${TEXTS}/PostgreSQL.txt`, 'utf8').replace(/\r\n/g, '\n').trim());
  out.push('');
  // Ревью сайта SITE-03 (WEB-KI-33): lib/postgresql/pgcrypto.so в pgcrypto.tar.gz статически собран с OpenSSL
  // (строка версии в бинарнике — «OpenSSL 3.0.17 1 Jul 2025»; файл закреплён sha256 в pglite.lock.json).
  out.push(rule('-'));
  out.push('OpenSSL 3.0.17 — статически собран в lib/postgresql/pgcrypto.so (backend/pglite/pgcrypto.tar.gz).');
  out.push('Copyright (c) 1998-2025 The OpenSSL Project Authors. Apache License, Version 2.0:');
  out.push(rule('-'));
  out.push(readFileSync(`${TEXTS}/Apache-2.0.txt`, 'utf8').replace(/\r\n/g, '\n').trim());
  out.push('');

  out.push(rule());
  out.push('3. Шрифты');
  out.push(rule());
  out.push('Inter (Inter-Regular.ttf, Inter-Bold.ttf; печатные формы сервера и интерфейс приложения) —');
  out.push('Copyright 2016 The Inter Project Authors — SIL Open Font License 1.1:');
  out.push('');
  out.push(readFileSync(`${API}/assets/fonts/OFL.txt`, 'utf8').replace(/\r\n/g, '\n').trim());
  out.push('');
  out.push(rule('-'));
  const rob = robotoSource();
  out.push(`Roboto — файл ${ROBOTO_SITE_PATH}: копия roboto-regular.ttf (TrueType, Roboto 2.137) из Flutter SDK`);
  out.push('bin/cache/artifacts/material_fonts; запасной шрифт движка Flutter (fontFallbackBaseUrl: fonts/).');
  out.push('Copyright 2011 Google Inc. All Rights Reserved. Apache License, Version 2.0:');
  out.push('');
  if (rob && existsSync(rob.font) && existsSync(rob.license)) out.push(readFileSync(rob.license, 'utf8').replace(/\r\n/g, '\n').trim());
  else problems.push(`Roboto: нет ${rob ? `${rob.font} или ${rob.license}` : 'Flutter SDK (FLUTTER_ROOT, flutter в PATH)'} — задайте FLUTTER_ROOT или FLUTTER_MATERIAL_FONTS`);
  out.push('');

  out.push(rule());
  out.push('4. SQLite, sqlite3.dart, drift');
  out.push(rule());
  out.push('sqlite3.wasm — SQLite (public domain, https://sqlite.org/copyright.html):');
  out.push(readFileSync(`${TEXTS}/SQLite-blessing.txt`, 'utf8').replace(/\r\n/g, '\n').trim());
  out.push('');
  const pub = pubHostedDir();
  const v = { sqlite3: lockedVersion('sqlite3'), drift: lockedVersion('drift') };
  if (!pub) problems.push('pub-кэш не найден (PUB_CACHE, LOCALAPPDATA) — тексты лицензий sqlite3 и drift');
  for (const [name, pkg] of [
    [`sqlite3 (Dart) ${v.sqlite3 ?? '?'} — обвязка и сборка sqlite3.wasm`, 'sqlite3'],
    [`drift ${v.drift ?? '?'} — drift_worker.js (скомпилирован dart2js; в нём среда выполнения Dart, BSD-3-Clause, раздел 6)`, 'drift'],
  ]) {
    out.push(rule('-'));
    out.push(name);
    out.push(rule('-'));
    const dir = pub && v[pkg] ? `${pub}/${pkg}-${v[pkg]}` : null;
    const t = dir ? licenseFiles(dir) : [];
    if (t.length) for (const x of t) out.push(x.text, '');
    else problems.push(`нет LICENSE для ${pkg} ${v[pkg] ?? '(версии нет в pos-app/pubspec.lock)'} (${dir ?? 'pub-кэш не найден'})`);
  }
  out.push('');

  out.push(rule());
  out.push('5. Комментарии /*! … */ и @license из backend/backend.js (esbuild legalComments: external)');
  out.push(rule());
  out.push(legalText && legalText.trim() ? legalText.replace(/\r\n/g, '\n').trim() : '(нет)');
  out.push('');

  // ---------------------------------------------------------------- 6. Flutter
  const warnings = [];
  out.push(rule());
  out.push('6. Приложение (Flutter): полный перечень — assets/NOTICES');
  out.push(rule());
  out.push('main.dart.js (приложение, скомпилированное dart2js), flutter.js и flutter_bootstrap.js, CanvasKit');
  out.push('(canvaskit/*.js, *.wasm — графический движок Skia), шрифт MaterialIcons и шейдеры (assets/…), среда');
  out.push('выполнения Dart и пакеты Dart приложения. Полные тексты их лицензий Flutter собирает сам в файл');
  out.push('assets/NOTICES этого сайта (рядом с main.dart.js); здесь — перечень компонентов из него.');
  out.push('drift_worker.js содержит среду выполнения Dart (dart2js) — лицензия BSD-3-Clause «dart» из того же файла.');
  // Ревью сайта SITE-04 (WEB-KI-33): в assets/NOTICES записи о шрифте MaterialIcons нет.
  out.push('Шрифт MaterialIcons (assets/fonts/MaterialIcons-Regular.otf) — Material Design Icons, Copyright Google LLC,');
  out.push('Apache License, Version 2.0 (полный текст — в разделе 2, у OpenSSL). В assets/NOTICES этой записи нет.');
  if (existsSync(flutterNotices)) {
    const names = new Set();
    let header = false;
    for (const line of readFileSync(flutterNotices, 'utf8').replace(/\r\n/g, '\n').split('\n')) {
      if (/^-{20,}$/.test(line)) {
        header = true;
        continue;
      }
      if (header && line === '') {
        header = false;
        continue;
      }
      if (header) names.add(line.trim());
    }
    // Имена компонентов — идентификаторы без пробелов (строки текста лицензий после линий «-----» внутри текста — нет).
    const list = [...names].filter((n) => /^[A-Za-z0-9_.+-]{1,60}$/.test(n)).sort((a, b) => a.localeCompare(b));
    out.push('');
    out.push(`Компоненты (${list.length}, по assets/NOTICES сборки, ${statSync(flutterNotices).size} байт):`);
    for (let i = 0; i < list.length; i += 6) out.push(`  ${list.slice(i, i + 6).join(', ')}`);
  } else {
    out.push('');
    out.push('(Сборки Flutter нет на машине сборки бэкенда: перечень появится при сборке сайта.)');
    warnings.push(`нет ${flutterNotices}: раздел 6 без перечня (сборка сайта проверит assets/NOTICES)`);
  }
  out.push('');

  return {
    text: out.join('\n') + '\n',
    packages: entries.map(({ texts: _t, ...rest }) => rest),
    ownBytes,
    problems,
    warnings,
  };
}

/** Заголовок раздела 7 (по нему раздел находится при повторной сборке сайта и в check-site.mjs). */
export const PDFJS_SECTION = '7. pdfjs/ — pdf.js';

/**
 * Раздел 7 «pdfjs/ — pdf.js» (fix:pdfcsp). pdf.js — компонент сайта, а не бандла: раздел и строку оглавления
 * добавляет сборка сайта (tools/assemble-site.mjs) в site/THIRD_PARTY_NOTICES.txt, который пишет build-backend.mjs
 * (разделы 1–6). Повторная сборка заменяет раздел и строку, а не дублирует их.
 * @param {string} text THIRD_PARTY_NOTICES.txt (разделы 1–6; возможно, уже с разделом 7)
 * @param {object} p    tools/pdfjs-files.mjs PDFJS + licenseText (LICENSE пакета pdfjs-dist)
 * @returns {string}
 */
export function withPdfjsNotice(text, p) {
  if (!p?.licenseText || !p.licenseText.trim()) throw new Error('pdf.js: нет текста лицензии (LICENSE пакета pdfjs-dist)');
  const src = String(text).replace(/\r\n/g, '\n');
  const at = src.indexOf(`\n${rule()}\n${PDFJS_SECTION}`);
  const lines = (at >= 0 ? src.slice(0, at + 1) : src).split('\n');
  const toc = `  7. pdfjs/ — pdf.js ${p.version} (предпросмотр PDF в приложении; раздел добавляет сборка сайта)`;
  const i7 = lines.findIndex((l) => /^ {2}7\. pdfjs\//.test(l));
  if (i7 >= 0) lines[i7] = toc;
  else {
    const i6 = lines.findIndex((l) => /^ {2}6\. /.test(l));
    if (i6 < 0) throw new Error('THIRD_PARTY_NOTICES.txt: нет строки оглавления «6.» — пересоберите бэкенд');
    lines.splice(i6 + 1, 0, toc);
  }
  let body = lines.join('\n');
  if (!body.endsWith('\n')) body += '\n';
  const sha = (to) => p.files.find((f) => f.to === to)?.sha256.slice(0, 12) ?? '?';
  const out = [
    rule(),
    `${PDFJS_SECTION} ${p.version} (${p.package}, Mozilla Foundation) — предпросмотр PDF`,
    rule(),
    `pdfjs/pdf.min.mjs и pdfjs/pdf.worker.min.mjs — файлы пакета npm ${p.package} ${p.version} (сборка ${p.build}) без`,
    `изменений, ${p.repository}; sha256 ${sha('pdfjs/pdf.min.mjs')}… и ${sha('pdfjs/pdf.worker.min.mjs')}… (demo/web/tools/pdfjs-files.mjs).`,
    'Через них пакет printing приложения показывает PDF документов заказа (предпросмотр). pdfjs/pdf.min.js —',
    'загрузчик демо (собственный код, не pdf.js). Copyright Mozilla Foundation — Apache License 2.0 (текст — ниже',
    'и в pdfjs/LICENSE).',
    '',
    `[LICENSE из пакета ${p.package}]`,
    p.licenseText.replace(/\r\n/g, '\n').trim(),
    '',
  ];
  return body + out.join('\n') + '\n';
}

