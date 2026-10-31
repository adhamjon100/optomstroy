// WP-T1: собранный бэкенд сайта (plan §4 WP-T1 «bundle.test.mjs», §5 п. 3, п. 9): site/backend/backend.js и его окружение.
//   - build.json: sha256 и размеры совпадают с файлом; бюджет 6,5 МБ min / 1,5 МБ brotli; ревизия и ключ эпохи;
//   - нет импортов node:* и require встроенных модулей в бандле; metafile — без external, без sharp/@img/@node-rs/pg-native;
//   - нет запрещённых строк ПДн (pii-map.json forbidden: полный список WP-B4) в бандле и текстовых файлах сайта;
//   - нет машинных путей (D:/, C:/Users, \Users\Farruh), *.map, приватных ключей и токенов-констант;
//   - баннер лицензий и THIRD_PARTY_NOTICES.txt (PGlite, pg-boss, NestJS, Inter);
//   - PGlite 0.3.16 = pglite.lock.json (sha256 каждого файла); снимок БД — файлы манифеста на месте.
//   node --test demo/web/backend/test/bundle.test.mjs
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { brotliCompressSync, constants as zc } from 'node:zlib';
import { before, describe, test } from 'node:test';
import { BACKEND, BUILD, OUT, SITE, norm } from '../lib/paths.mjs';
import { loadPiiMap } from '../pii/pii-transform.mjs';

const sha = (b) => createHash('sha256').update(b).digest('hex');
let js;
let text;
let build;
let pii;
before(() => {
  js = readFileSync(`${OUT}/backend.js`);
  text = js.toString('utf8');
  build = JSON.parse(readFileSync(`${OUT}/build.json`, 'utf8'));
  pii = loadPiiMap();
});
const walk = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(dir, e.name)) : [join(dir, e.name)]));
const TEXT_EXT = /\.(js|mjs|cjs|json|html|css|txt|md|svg|webmanifest|copy)$/i;

describe('site/backend/backend.js', () => {
  test('build.json: sha256 и размер = файлу; бюджет 6,5 МБ min / 1,5 МБ brotli; ревизия и эпоха', () => {
    assert.equal(build.backend.sha256, sha(js));
    assert.equal(build.backend.minBytes, js.length);
    assert.ok(js.length <= 6_500_000, `min ${js.length}`);
    const br = brotliCompressSync(js, { params: { [zc.BROTLI_PARAM_QUALITY]: 11, [zc.BROTLI_PARAM_SIZE_HINT]: js.length } }).length;
    assert.ok(br <= 1_500_000, `brotli ${br}`);
    assert.match(build.gitHead, /^[0-9a-f]{40}$/);
    assert.match(build.posApiDiffSha256, /^[0-9a-f]{64}$/);
    assert.match(build.epochKey, /^[0-9a-f]{16}$/);
    assert.match(build.appVersion, /^\d+\.\d+\.\d+\+\d+$/);
  });
  test('нет импортов node:* и require встроенных модулей', () => {
    const bad = text.match(/(?:from\s*["']node:[a-z_/]+["']|import\(\s*["']node:|require\(\s*["']node:[a-z_/]+["']\))/g) ?? [];
    assert.deepEqual(bad.slice(0, 5), []);
  });
  test('metafile: ни одного external; sharp, @img, @node-rs, pg-native не в бандле; первый модуль — запрет сети', () => {
    const meta = JSON.parse(readFileSync(`${BUILD}/backend-metafile.json`, 'utf8'));
    const ext = [];
    // inject (shims/inject.mjs) esbuild записывает как external-импорт каждого модуля, а require шаблонизатора express
    // (lib/view.js, view engine) — как <runtime>; pos-api шаблоны не рендерит (WP-B1). Остальное external — ошибка.
    for (const [f, info] of Object.entries(meta.inputs)) for (const imp of info.imports ?? []) if (imp.external && !/shims[\\/]inject\.mjs$/.test(imp.path) && !(imp.path === '<runtime>' && /express[\\/]lib[\\/]view\.js$/.test(f))) ext.push(`${f} → ${imp.path}`);
    assert.deepEqual(ext.slice(0, 5), []);
    const banned = Object.keys(meta.inputs).filter((f) => /node_modules[\\/](sharp|@img|@node-rs|pg-native)[\\/]/.test(f));
    assert.deepEqual(banned, []);
    const out = Object.values(meta.outputs).find((o) => o.entryPoint);
    const firstOwn = Object.keys(out.inputs).find((f) => /demo[\\/]web[\\/]backend[\\/]/.test(f));
    assert.match(firstOwn, /shims[\\/](net-guard\.mjs|inject\.mjs)$/, `первый модуль бэкенда: ${firstOwn}`);
  });
  test(`нет запрещённых строк ПДн (pii-map.json, ${'forbidden'})`, () => {
    assert.ok(pii.forbidden.length >= 90, `список ${pii.forbidden.length}`);
    const hits = pii.forbidden.filter((s) => text.includes(s));
    assert.deepEqual(hits, []);
    // замена выполнена: тестовые имена сценарных клиентов — в бандле
    for (const name of ['Покупатель Просрочка (тест)', 'Покупатель Долг в лимите (тест)', 'ОсОО Лимит превышен (тест)']) assert.ok(text.includes(name), `нет тестового имени ${name}`);
  });
  test('нет машинных путей, приватных ключей и констант-токенов', () => {
    for (const re of [/[A-Za-z]:[\\/]optomstroy/i, /[A-Za-z]:[\\/]Users[\\/]/i, /\\Users\\Farruh/i, /-----BEGIN (?:RSA |EC |)PRIVATE KEY-----/, /AKIA[0-9A-Z]{16}/, /sk_live_[0-9a-zA-Z]{20,}/, /xox[baprs]-[0-9a-zA-Z-]{10,}/]) {
      const m = re.exec(text);
      assert.equal(m, null, `${re}: ${m?.[0]}`);
    }
    assert.ok(!/ONEC_HS_TOKEN\s*[:=]\s*["'][^"']{6,}["']/.test(text), 'токен 1С константой');
  });
  test('баннер лицензий и THIRD_PARTY_NOTICES.txt (PGlite, pg-boss, NestJS, Inter)', () => {
    assert.ok(text.startsWith('/*! Оптомстрой POS'), 'баннер');
    assert.ok(text.slice(0, 300).includes('THIRD_PARTY_NOTICES.txt'));
    const n = readFileSync(`${SITE}/THIRD_PARTY_NOTICES.txt`, 'utf8');
    for (const s of ['@electric-sql/pglite', 'pg-boss', '@nestjs/core', 'Inter', 'PostgreSQL']) assert.ok(n.includes(s), `в уведомлениях нет ${s}`);
  });
});

describe('окружение бандла на сайте', () => {
  test('нет *.map и *.symbols в site/', () => {
    const maps = walk(SITE).filter((f) => /\.(map|symbols)$/i.test(f));
    assert.deepEqual(maps.map((f) => norm(relative(SITE, f))).slice(0, 5), []);
  });
  test('review fixes: ни в одном .js/.mjs/.css сайта нет ссылки sourceMappingURL (карт нет — DevTools получал 404)', () => {
    const files = walk(SITE).filter((f) => /\.(js|mjs|cjs|css)$/i.test(f));
    const bad = files.filter((f) => /[#@]\s*sourceMappingURL=/.test(readFileSync(f, 'utf8'))).map((f) => norm(relative(SITE, f)));
    assert.ok(files.length >= 10, `файлов ${files.length}`);
    assert.deepEqual(bad.slice(0, 10), []);
  });
  test('review fixes: ревизия pos-api — git diff HEAD (изменения в индексе тоже)', () => {
    assert.equal(build.posApiDiffBase, 'HEAD');
  });
  test('текстовые файлы сайта: нет запрещённых строк ПДн и машинных путей', () => {
    const files = walk(SITE).filter((f) => TEXT_EXT.test(f) && statSync(f).size < 20_000_000 && !/[\\/]pglite[\\/]/.test(f));
    const bad = [];
    for (const f of files) {
      const s = readFileSync(f, 'utf8');
      for (const x of pii.forbidden) if (s.includes(x)) bad.push(`${norm(relative(SITE, f))}: ${x}`);
      if (/[A-Za-z]:[\\/](optomstroy|Users)[\\/]/i.test(s)) bad.push(`${norm(relative(SITE, f))}: машинный путь`);
    }
    assert.ok(files.length >= 3, `файлов ${files.length}`);
    assert.deepEqual(bad.slice(0, 10), []);
  });
  test('PGlite 0.3.16: файлы site/backend/pglite совпадают с pglite.lock.json (sha256; .js — опубликованная копия без sourceMappingURL)', () => {
    const lock = JSON.parse(readFileSync(`${BACKEND}/pglite.lock.json`, 'utf8'));
    assert.equal(lock.version, '0.3.16');
    assert.ok(lock.shipped && Object.keys(lock.shipped).length >= 5, 'lock.shipped');
    for (const [rel, orig] of Object.entries(lock.files)) {
      const meta = lock.shipped[rel] ?? orig;
      const p = `${OUT}/pglite/${rel.replace(/^dist\//, '')}`;
      assert.ok(existsSync(p), rel);
      const b = readFileSync(p);
      assert.equal(b.length, meta.bytes, `${rel} размер`);
      assert.equal(sha(b), meta.sha256, `${rel} sha256`);
    }
  });
  test('внешние файлы vfs (шрифты Inter) и снимок БД на месте, sha снимка вшит в build.json', () => {
    for (const url of Object.values(build.backend.vfsExternal ?? {})) assert.ok(existsSync(`${OUT}/${url}`), url);
    const manifest = JSON.parse(readFileSync(`${SITE}/demo/snapshot/manifest.json`, 'utf8'));
    assert.equal(manifest.data.sha256, build.snapshot.dataSha256);
    const gz = readFileSync(`${SITE}/demo/snapshot/${manifest.data.gzipFile}`);
    assert.ok(gz.length > 100_000 && gz[0] === 0x1f && gz[1] === 0x8b, 'gzip');
  });
});
