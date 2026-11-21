// Страж записи: без --allow-write — только GET; неверное подтверждение или ввод без ответа — ни одного POST;
// с подтверждением — объекты «ПРОВЕРКА POS», externalId 5e1f7e57-…, суммы ≤ 1.00, пределы §1.6.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import fs from 'node:fs';
import { mockWithSecrets, makeConfig, runMain, readProtocol, check, tmpDir } from './helpers/env.mjs';

const dirs = [];
const mocks = [];
after(async () => { for (const m of mocks) await m.close(); for (const d of dirs) fs.rmSync(d, { recursive: true, force: true }); });

async function setup() {
  const { mock, password, clientKey } = await mockWithSecrets();
  mocks.push(mock);
  const dir = tmpDir('oc-wg-');
  dirs.push(dir);
  const cfg = makeConfig(dir, { baseUrl: mock.baseUrl, password, clientKey });
  return { mock, dir, cfg };
}

test('без --allow-write в имитатор не уходит ни одного запроса, кроме GET; W-проверки ПРОПУЩЕНО', async () => {
  const { mock, dir, cfg } = await setup();
  const r = await runMain(['--config', cfg, '--allow-http', '--no-manual']);
  assert.equal(r.code, 0, r.out.slice(-1500));
  assert.deepEqual([...new Set(mock.journal.map((j) => j.method))], ['GET']);
  const p = readProtocol(path.join(dir, 'protokoly'));
  for (const id of ['C6', 'C7', 'K1', 'PAY1', 'O1', 'CK1', 'R1']) assert.equal(check(p, id).verdict, 'SKIP', id);
  assert.equal(p.json.createdObjects.length, 0);
  assert.equal(p.json.mode.allowWrite, false);
});

test('--allow-write с неверным подтверждением — ни одного POST, чтение продолжается', async () => {
  const { mock, dir, cfg } = await setup();
  const r = await runMain(['--config', cfg, '--allow-http', '--no-manual', '--allow-write'], { input: 'prod_baza\n' });
  assert.equal(r.code, 0, r.out.slice(-1500));
  assert.ok(r.out.includes('Запись отменена'));
  assert.equal(mock.journal.filter((j) => j.method !== 'GET').length, 0);
  const p = readProtocol(path.join(dir, 'protokoly'));
  assert.match(check(p, 'K1').summary, /не подтверждена/);
});

test('--allow-write без ввода (нет консоли) — запись отменена', async () => {
  const { mock, cfg } = await setup();
  const r = await runMain(['--config', cfg, '--allow-http', '--no-manual', '--allow-write'], { input: '' });
  assert.equal(r.code, 0, r.out.slice(-1500));
  assert.equal(mock.journal.filter((j) => j.method !== 'GET').length, 0);
});

test('--allow-write с подтверждением: тестовые объекты, пределы и реестр', async () => {
  const { mock, dir, cfg } = await setup();
  const r = await runMain(['--config', cfg, '--allow-http', '--no-manual', '--allow-write'], { input: `${mock.publication}\n` });
  assert.equal(r.code, 0, r.out.slice(-2500));
  const p = readProtocol(path.join(dir, 'protokoly'));
  assert.equal(p.json.mode.writeConfirmed, true);
  assert.equal(check(p, 'C6').verdict, 'SKIP', 'перерегистрация без ответа «да» не выполняется');
  const created = p.json.createdObjects;
  assert.ok(created.length > 0);
  for (const c of created) assert.match(c.externalId, /^5e1f7e57-/);
  const byKind = (k) => created.filter((c) => c.kind === k).length;
  assert.ok(byKind('Клиент') <= 3 && byKind('Платеж') <= 2 && byKind('Заказ') <= 2);
  // В имитаторе ровно те объекты, что в реестре протокола.
  const st = mock.state;
  const mockIds = new Set([...st.custByExt.keys(), ...st.payments.keys(), ...st.orders.keys()]);
  for (const c of created.filter((x) => ['Клиент', 'Платеж', 'Заказ'].includes(x.kind))) assert.ok(mockIds.has(c.externalId), c.externalId);
  assert.equal(mockIds.size, created.filter((x) => ['Клиент', 'Платеж', 'Заказ'].includes(x.kind)).length);
  for (const pay of st.payments.values()) { assert.equal(pay.body.amount, '1.00'); assert.equal(pay.body.post, false); }
  for (const c of st.custByExt.values()) assert.match(c[0].body.name, /^ПРОВЕРКА POS/);
  assert.equal(check(p, 'X4').verdict, 'PASS');
});
