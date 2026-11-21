// Сборка --no-runtime во временную папку: проверки blob и манифеста, состав zip, бит UTF-8 у ЧИТАЙ_МЕНЯ.txt,
// SHA256SUMS; страж утечки на синтетическом «1.3.0»-контракте с вымышленными именами — сборка останавливается.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { readZip } from '../tools/unzip.mjs';
import { CHECK_DIR, tmpDir } from './helpers/env.mjs';

const dirs = [];
after(() => { for (const d of dirs) fs.rmSync(d, { recursive: true, force: true }); });
const BUILD = path.join(CHECK_DIR, 'build.mjs');

test('сборка без среды выполнения: состав архива и SHA256SUMS', () => {
  const out = tmpDir('oc-build-');
  dirs.push(out);
  const r = spawnSync(process.execPath, [BUILD, '--no-runtime', '--out', out], { encoding: 'utf8', timeout: 300000 });
  assert.equal(r.status, 0, r.stdout + r.stderr);
  const zip = fs.readdirSync(out).find((f) => f.endsWith('.zip'));
  const list = readZip(path.join(out, zip));
  const names = list.map((e) => e.name);
  const root = names[0].split('/')[0];
  assert.match(root, /^Optomstroy_Proverka_API_1C_\d+\.\d+\.\d+$/);
  assert.ok(names.every((n) => n.startsWith(root + '/')));
  const readme = list.find((e) => e.name === `${root}/ЧИТАЙ_МЕНЯ.txt`);
  assert.ok(readme && readme.utf8 && readme.extraIds.includes(0x7075));
  assert.equal(names.filter((n) => /\/programma\/obrazcy\/.+\.json$/.test(n)).length, 59);
  assert.ok(!names.some((n) => /\/(test|tools)\//.test(n) || n.endsWith('build.mjs')));
  const sums = fs.readFileSync(path.join(out, 'SHA256SUMS'), 'utf8');
  assert.match(sums, new RegExp(`^[0-9a-f]{64} \\*${zip.replace(/\./g, '\\.')}`));
  const inner = list.find((e) => e.name === `${root}/SHA256SUMS.txt`).data().toString('utf8');
  assert.match(inner, /programma\/main\.mjs/);
  // Стандартный вид для sha256sum -c: без BOM, строки LF, каждая сумма верна, перечислены все файлы, кроме самого списка.
  assert.ok(inner.charCodeAt(0) !== 0xfeff && !inner.includes('\r'));
  const byName = new Map(list.map((e) => [e.name, e]));
  const lines = inner.trim().split('\n');
  for (const l of lines) {
    const m = /^([0-9a-f]{64}) \*(.+)$/.exec(l);
    assert.ok(m, `строка SHA256SUMS.txt: ${l}`);
    assert.equal(createHash('sha256').update(byName.get(`${root}/${m[2]}`).data()).digest('hex'), m[1], m[2]);
  }
  assert.equal(lines.length, names.filter((n) => !n.endsWith('/') && n !== `${root}/SHA256SUMS.txt`).length);
  // Запускатели: только ASCII, CRLF, чистят NODE_OPTIONS компьютера, без runtime\ — сообщение и код 2.
  for (const f of ['Proverka_API_1C.cmd', 'Proverka_API_1C_zapis.cmd']) {
    const t = byName.get(`${root}/${f}`).data().toString('latin1');
    assert.ok(!/[^\x09\x0a\x0d\x20-\x7e]/.test(t), `${f}: только ASCII`);
    assert.ok(!/[^\r]\n/.test(t), `${f}: строки CRLF`);
    assert.match(t, /^set "NODE_OPTIONS="\r$/m);
    assert.match(t, /^if not exist "%~dp0runtime\\node\.exe" goto net_fajlov\r$/m);
    assert.match(t, /^endlocal & exit \/b 2\r$/m);
  }
  const meta = JSON.parse(list.find((e) => e.name === `${root}/programma/contract/meta.json`).data().toString('utf8'));
  assert.equal(meta.version, '1.2.0');
  assert.equal(meta.gitBlob, '63995cc4badb60badeda208adec11c8d6a06d864');
});

test('страж утечки: имя из синтетического черновика 1.3.0 в сборке — сборка останавливается', () => {
  const out = tmpDir('oc-build-leak-');
  dirs.push(out);
  const draft = path.join(out, 'draft.yaml');
  // Вымышленный черновик: схема с именем, которое есть в коде программы, но нет в 1.2.0 и ТЗ.
  fs.writeFileSync(draft, [
    'openapi: 3.0.3',
    'info: { title: synthetic, version: 1.3.0 }',
    'paths: {}',
    'components:',
    '  schemas:',
    '    discoverRefs: { type: object, properties: { vymyshlennoePole: { type: string } } }',
    '',
  ].join('\n'));
  const r = spawnSync(process.execPath, [BUILD, '--no-runtime', '--out', out, '--draft-contract', draft], { encoding: 'utf8', timeout: 300000 });
  assert.equal(r.status, 1, r.stdout + r.stderr);
  assert.match(r.stdout, /СБОРКА ОСТАНОВЛЕНА: в сборке найдены имена черновика контракта \(1\)/);
  assert.ok(!r.stdout.includes('discoverRefs'), 'список имён в журнал сборки не пишется');
});
