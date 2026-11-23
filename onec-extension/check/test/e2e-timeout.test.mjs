// Таймауты и «нет связи»: задержка ответа одного метода сверх x-timeout-ms (с --timeout-scale) → E10 ОШИБКА
// «нет ответа за …», прогон продолжается, код 1; сервер принимает TCP и молчит (HTTP) → S3 ОШИБКА, код 2;
// то же по HTTPS → TLS-рукопожатие не завершается → «не ответил за отведённое время на соединение», код 2;
// закрытый порт → «отказал в соединении», код 2. Пароль в выводе не появляется.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { startSilent } from './helpers/front-1c.mjs';
import { frontWithSecrets, makeConfig, runMain, readProtocol, check, checkTexts, tmpDir, secretForms, leaks } from './helpers/env.mjs';

const dirs = [];
const servers = [];
after(async () => { for (const s of servers) await s.close(); for (const d of dirs) fs.rmSync(d, { recursive: true, force: true }); });

const isRecv = (c) => /^\/pos\/v1\/customers\/[^/]+\/receivables$/.test(c.sub || '');

test('задержка ответа /receivables сверх таймаута → E10 «нет ответа за», прогон продолжается, код 1', async () => {
  // x-timeout-ms у /customers/{ref}/receivables — 6000; при --timeout-scale 0.1 — 600 мс; ответ через 2.5 с.
  const { front, password, clientKey } = await frontWithSecrets({ defect: { id: 'DELAY', delay: { match: isRecv, ms: 2500 } } });
  servers.push(front);
  const dir = tmpDir('oc-to-delay-');
  dirs.push(dir);
  const cfg = makeConfig(dir, { baseUrl: front.baseUrl, password, clientKey });
  const t0 = Date.now();
  const r = await runMain(['--config', cfg, '--allow-http', '--no-manual', '--timeout-scale', '0.1']);
  assert.equal(r.code, 1, r.out.slice(-1500));
  const p = readProtocol(path.join(dir, 'protokoly'));
  const e10 = check(p, 'E10');
  assert.equal(e10.verdict, 'FAIL');
  assert.match(checkTexts(e10), /нет ответа за \d+ с — POS считает результат неизвестным/);
  assert.ok(e10.findings.some((f) => /receivables/.test(f.where || '')), 'в находке — метод, который не ответил');
  const k9 = check(p, 'K9');
  assert.equal(k9.verdict, 'FAIL');
  assert.match(checkTexts(k9), /нет ответа за отведённое время/);
  // После таймаута проверка идёт дальше: X и пробы выполнены.
  assert.ok(['PASS', 'INFO', 'ABSENT'].includes(check(p, 'X1').verdict));
  assert.equal(p.json.aborted, null);
  assert.ok(Date.now() - t0 < 60000, 'таймаут не ждёт полный x-timeout-ms');
  assert.deepEqual(leaks([r.out, ...p.texts], secretForms(password, clientKey)), []);
});

test('сервер принимает соединение и молчит (HTTP) → S3 ОШИБКА «нет ответа», код 2, частичный протокол', async () => {
  const silent = await startSilent();
  servers.push(silent);
  const dir = tmpDir('oc-to-silent-');
  dirs.push(dir);
  const cfg = makeConfig(dir, { baseUrl: `http://127.0.0.1:${silent.port}/ut_test/hs`, password: 'Vymysel-Parol-Tishina-1', clientKey: 'vymysel-klyuch-tishina-1' }); // check-secrets: allow — вымышленное тестовое значение, не секрет
  const r = await runMain(['--config', cfg, '--allow-http', '--no-manual', '--timeout-scale', '0.02']);
  assert.equal(r.code, 2, r.out.slice(-1500));
  assert.ok(silent.accepted() >= 0);
  assert.match(r.out, /нет ответа за отведённое время/);
  assert.match(r.out, /ПРОВЕРКА ПРЕРВАНА/);
  const p = readProtocol(path.join(dir, 'protokoly'));
  assert.ok(p, 'протокол пишется и при обрыве');
  assert.equal(check(p, 'S3').verdict, 'FAIL');
  assert.equal(check(p, 'E10').verdict, 'FAIL');
  assert.match(p.json.aborted, /нет связи с публикацией/);
  assert.deepEqual(leaks([r.out, ...p.texts], secretForms('Vymysel-Parol-Tishina-1', 'vymysel-klyuch-tishina-1')), []);
});

test('HTTPS к серверу, который молчит → «не ответил за отведённое время на соединение», код 2', async () => {
  const silent = await startSilent();
  servers.push(silent);
  const dir = tmpDir('oc-to-tls-');
  dirs.push(dir);
  const cfg = makeConfig(dir, { baseUrl: `https://127.0.0.1:${silent.port}/ut_test/hs`, password: 'Vymysel-Parol-Tishina-2', clientKey: 'vymysel-klyuch-tishina-2' }); // check-secrets: allow — вымышленное тестовое значение, не секрет
  const r = await runMain(['--config', cfg, '--no-manual', '--timeout-scale', '0.05']);
  assert.equal(r.code, 2, r.out.slice(-1500));
  assert.match(r.out, /не ответил за отведённое время на соединение/);
  const p = readProtocol(path.join(dir, 'protokoly'));
  assert.equal(check(p, 'S2').verdict, 'FAIL');
});

test('закрытый порт → «отказал в соединении», код 2', async () => {
  const silent = await startSilent();
  const port = silent.port;
  await silent.close(); // порт свободен и закрыт
  const dir = tmpDir('oc-to-refused-');
  dirs.push(dir);
  const cfg = makeConfig(dir, { baseUrl: `http://127.0.0.1:${port}/ut_test/hs`, password: 'Vymysel-Parol-Zakryt', clientKey: 'vymysel-klyuch-zakryt' }); // check-secrets: allow — вымышленное тестовое значение, не секрет
  const r = await runMain(['--config', cfg, '--allow-http', '--no-manual']);
  assert.equal(r.code, 2, r.out.slice(-1500));
  assert.match(r.out, /отказал в соединении \(ECONNREFUSED\)/);
  const p = readProtocol(path.join(dir, 'protokoly'));
  assert.equal(check(p, 'S3').verdict, 'FAIL');
});
