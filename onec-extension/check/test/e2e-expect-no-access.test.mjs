// M2 «нет доступа с другого компьютера»: закрытый порт — ПРОЙДЕНО; работающий имитатор — ОШИБКА «доступна».
// Секреты не спрашиваются (ввод пустой).
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import fs from 'node:fs';
import { mockWithSecrets, runMain, readProtocol, check, tmpDir } from './helpers/env.mjs';

const dirs = [];
const mocks = [];
after(async () => { for (const m of mocks) await m.close(); for (const d of dirs) fs.rmSync(d, { recursive: true, force: true }); });

function cfgOnly(dir, baseUrl) {
  const f = path.join(dir, 'nastrojki.json');
  fs.writeFileSync(f, JSON.stringify({ baseUrl, user: 'pos_hs', outDir: 'protokoly' }));
  return f;
}

test('закрытый порт → ПРОЙДЕНО, код 0', async () => {
  const dir = tmpDir('oc-m2a-');
  dirs.push(dir);
  const r = await runMain(['--config', cfgOnly(dir, 'https://127.0.0.1:9/ut_test/hs'), '--expect-no-access']);
  assert.equal(r.code, 0, r.out.slice(-800));
  const p = readProtocol(path.join(dir, 'protokoly'));
  assert.equal(check(p, 'M2').verdict, 'PASS');
  assert.match(check(p, 'M2').summary, /доступа нет: 127\.0\.0\.1:9 — отказ в соединении \(ECONNREFUSED\)/);
  assert.ok(!/Пароль пользователя/.test(r.out));
  // Сквозные правила E в проверке «нет доступа» не участвуют (им нечего проверять).
  assert.ok(!p.json.checks.some((c) => c.group === 'E'), p.json.checks.map((c) => c.id).join(','));
  assert.ok(!/\[E1\]/.test(r.out));
});

test('имя сервера не найдено на этом компьютере → не ПРОЙДЕНО: «проверка не выполнена», код 2', async () => {
  const dir = tmpDir('oc-m2c-');
  dirs.push(dir);
  const r = await runMain(['--config', cfgOnly(dir, 'https://srv-1c-opechatka.invalid/ut_test/hs'), '--expect-no-access']);
  assert.equal(r.code, 2, r.out.slice(-800));
  assert.match(r.out, /не найдено на этом компьютере/);
  assert.match(r.out, /тот же адрес, что работает на сервере POS, или IP/);
  assert.ok(!/ПРОЙДЕНО — доступа нет/.test(r.out));
  const p = readProtocol(path.join(dir, 'protokoly'));
  assert.equal(check(p, 'M2').verdict, 'SKIP');
});

test('работающая публикация → ОШИБКА «доступна», код 1', async () => {
  const { mock } = await mockWithSecrets();
  mocks.push(mock);
  const dir = tmpDir('oc-m2b-');
  dirs.push(dir);
  const r = await runMain(['--config', cfgOnly(dir, mock.baseUrl), '--expect-no-access', '--allow-http']);
  assert.equal(r.code, 1, r.out.slice(-800));
  const p = readProtocol(path.join(dir, 'protokoly'));
  assert.equal(check(p, 'M2').verdict, 'FAIL');
  assert.match(check(p, 'M2').summary, /доступна с этого компьютера/);
});
