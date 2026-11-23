// «Хорошая» 1С: --demo и отдельный процесс против фасада в режиме «образцы». Код 0, ни одной ОШИБКИ, три файла
// протокола, JSON formatVersion 2, протокол «запрос → ответ → результат», обязательные методы онлайн-обмена (заказы,
// заявки на возврат, проверка корзины, поиск клиента, долг, картинки) — ПРОЙДЕНО, созданные объекты = объектам имитатора;
// в протоколе нет следов отозванного задания «ночной обмен» и черновика 1.3.0.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { CATALOG } from '../src/checks/index.mjs';
import {
  frontWithSecrets, makeConfig, runMain, readProtocol, check, tmpDir, SAMPLE_PII, secretForms, leaks,
} from './helpers/env.mjs';

const dirs = [];
const fronts = [];
after(async () => { for (const f of fronts) await f.close(); for (const d of dirs) fs.rmSync(d, { recursive: true, force: true }); });

const VERDICTS = new Set(['PASS', 'FAIL', 'WARN', 'SKIP', 'MANUAL_YES', 'MANUAL_NO', 'ABSENT', 'INFO']);
// Обязательные методы онлайн-обмена (Требования §6): у хорошей 1С — ПРОЙДЕНО, не «МЕТОДА НЕТ».
const ONLINE_REQUIRED = ['O0', 'O1', 'O2', 'O3', 'O4', 'O5', 'O6', 'O7', 'O8', 'O9', 'R0', 'R1', 'CK1', 'CK2', 'CK3', 'CK4', 'K7', 'K8', 'K9', 'I1', 'I2', 'I3'];

const p0 = (dir) => readProtocol(dir);

function commonProtocolAsserts(p, dir) {
  const files = fs.readdirSync(dir);
  assert.equal(files.filter((f) => /^protokol_proverki_API_1C_.*\.(html|md|json)$/.test(f)).length, 3, files.join(', '));
  assert.ok(files.every((f) => /^[\x20-\x7e]+$/.test(f)), 'имена файлов протокола — ASCII');
  const j = p.json;
  assert.equal(j.format, 'optomstroy-onec-check-protocol');
  assert.equal(j.formatVersion, 2);
  assert.equal(j.contract.version, '1.2.0');
  assert.equal(j.contract.gitBlob, '63995cc4badb60badeda208adec11c8d6a06d864');
  assert.equal(j.requirements, '1.2.1');
  assert.equal(j.tz, undefined, 'в протоколе нет поля ТЗ отозванного задания');
  assert.match(j.startedAt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+06:00$/);
  assert.equal(j.exitCode, 0);
  assert.equal(j.aborted, null);
  for (const c of j.checks) assert.ok(VERDICTS.has(c.verdict), `${c.id}: ${c.verdict}`);
  const fails = j.checks.filter((c) => c.verdict === 'FAIL' || c.verdict === 'MANUAL_NO');
  assert.deepEqual(fails.map((c) => `${c.id}: ${c.summary}`), []);
  // Итоги = числу проверок по видам.
  const counted = {};
  for (const c of j.checks) counted[c.verdict] = (counted[c.verdict] || 0) + 1;
  for (const [v, n] of Object.entries(j.summary)) assert.equal(n, counted[v] || 0, `итог ${v}`);
  // Каталог: каждая проверка из протокола есть в каталоге; групп N (пробы) и T (ждут 1.3.0) больше нет.
  const ids = new Set(CATALOG.map((d) => d.id));
  for (const c of j.checks) assert.ok(ids.has(c.id), c.id);
  assert.ok(!j.checks.some((c) => c.group === 'N' || c.group === 'T'), 'нет проб и проверок «ждут 1.3.0»');
  assert.ok(!('PENDING_13' in j.summary));
  for (const t of p.texts) assert.ok(!/ТЗ 2\.3|ночн\S* обмен|1\.3\.0|ЖДЁТ/.test(t), 'в протоколе нет отозванного задания и 1.3.0');
  // «запрос → ответ → результат»: у проверки с запросами есть метод, путь, статус и заголовки без секретов.
  const a1 = check(p, 'A2');
  assert.ok(a1.requests.length >= 1);
  const ex = a1.exchanges[0];
  assert.equal(ex.method, 'GET');
  assert.match(ex.path, /^\/pos\/v1\/health/);
  assert.equal(ex.status, 401);
  assert.equal(ex.reqHeaders['X-POS-Client-Key'], '(нет)');
  assert.equal(ex.reqHeaders.Authorization, 'Basic ***');
  assert.ok(ex.resBody, 'тело ответа в протоколе');
  const [html, md] = p.texts;
  assert.ok(html.includes('запрос → ответ'), 'в HTML есть блоки «запрос → ответ»');
  assert.ok(html.includes('Сводная таблица') && md.includes('Сводная таблица'));
  assert.ok(html.includes("default-src 'none'"), 'HTML без скриптов (CSP)');
  assert.ok(!/<script/i.test(html), 'в HTML нет <script>');
}

test('--demo --no-manual: код 0, ошибок нет, три файла, формат протокола 1', async () => {
  const dir = tmpDir('oc-good-demo-');
  dirs.push(dir);
  const r = await runMain(['--demo', '--no-manual', '--out', dir]);
  assert.equal(r.code, 0, r.out.slice(-2000));
  // В демо ручные шаги не задаются и M2 — на другом компьютере: «ошибок нет, но проверка неполная» и строка полноты.
  assert.match(r.out, /Итог: ошибок нет, но проверка неполная\./);
  assert.match(r.out, /Проверено обязательных \d+ из \d+; не проверено: ручные шаги/);
  assert.equal(p0(dir).json.coverage.complete, false);
  assert.match(r.out, /Код выхода: 0/);
  const p = readProtocol(dir);
  commonProtocolAsserts(p, dir);
  assert.equal(p.json.mode.demo, true);
  // Обязательные методы онлайн-обмена в имитаторе есть: ПРОЙДЕНО (в том числе корзина в долг — блок receivables).
  for (const id of ONLINE_REQUIRED) assert.equal(check(p, id).verdict, 'PASS', `${id}: ${check(p, id).verdict} — ${check(p, id).summary}`);
  assert.ok(p.json.createdObjects.length > 0, 'демо создаёт тестовые объекты в имитаторе');
  for (const o of p.json.createdObjects) if (o.externalId) assert.match(o.externalId, /^5e1f7e57-/);
});

test('отдельный процесс, фасад «образцы», --allow-write с подтверждением: код 0', async () => {
  const { front, password, clientKey } = await frontWithSecrets();
  fronts.push(front);
  const dir = tmpDir('oc-good-front-');
  dirs.push(dir);
  const cfg = makeConfig(dir, { baseUrl: front.baseUrl, password, clientKey });
  const r = await runMain(['--config', cfg, '--allow-http', '--no-manual', '--allow-write'], { input: `${front.publication}\n` });
  assert.equal(r.code, 0, r.out.slice(-2500));
  const out = path.join(dir, 'protokoly');
  const p = readProtocol(out);
  commonProtocolAsserts(p, out);
  assert.equal(p.json.mode.writeConfirmed, true);
  assert.equal(p.json.mode.demo, false);
  for (const id of ONLINE_REQUIRED) assert.equal(check(p, id).verdict, 'PASS', `${id}: ${check(p, id).verdict} — ${check(p, id).summary}`);
  // Методов отозванного задания (срезы, продажи, возвраты продаж, авансы, складские документы) программа не вызывает.
  assert.ok(!front.journal.some((j) => /\/pos\/v1\/(prices|stock|receivables|sales|sale-returns|advance-refunds|stock-documents)$/.test(j.path)), 'запросов к методам отозванного задания нет');
  // A6: POST без ключа — неразбираемое тело (1С без проверки ключа ничего не создаст); перерегистрация без ключа не
  // вызывается (C6 не выбирали).
  const a6 = front.journal.filter((j) => j.method === 'POST' && j.status === 401);
  assert.ok(a6.length >= 3, 'A6 проверил POST-методы без ключа');
  for (const j of a6) assert.equal(j.body, '{"externalId":', `${j.path}: ${j.body}`);
  assert.ok(!front.journal.some((j) => j.path.endsWith('/changes/reregister')), 'без выбора C6 перерегистрация не вызывается вообще');
  // Созданные объекты протокола = объектам имитатора; все — «ПРОВЕРКА POS».
  const st = front.inner.state;
  const created = p.json.createdObjects.filter((x) => ['Клиент', 'Платеж', 'Заказ'].includes(x.kind));
  const mockIds = new Set([...st.custByExt.keys(), ...st.payments.keys(), ...st.orders.keys()]);
  assert.equal(mockIds.size, created.length);
  for (const c of created) assert.ok(mockIds.has(c.externalId), c.externalId);
  assert.ok(p.texts[0].includes('ПРОВЕРКА POS'));
  // Приватность в хорошем прогоне.
  assert.deepEqual(leaks([r.out, ...p.texts, fs.readFileSync(cfg, 'utf8')], secretForms(password, clientKey)), []);
  assert.deepEqual(leaks([r.out, ...p.texts], SAMPLE_PII), []);
});

test('только чтение против фасада: код 0, в 1С только GET, запись пропущена', async () => {
  const { front, password, clientKey } = await frontWithSecrets();
  fronts.push(front);
  const dir = tmpDir('oc-good-ro-');
  dirs.push(dir);
  const cfg = makeConfig(dir, { baseUrl: front.baseUrl, password, clientKey });
  const r = await runMain(['--config', cfg, '--allow-http', '--no-manual']);
  assert.equal(r.code, 0, r.out.slice(-2000));
  assert.deepEqual([...new Set(front.journal.map((j) => j.method))], ['GET']);
  const p = readProtocol(path.join(dir, 'protokoly'));
  for (const id of ['K7', 'K8', 'K9', 'O0', 'R0', 'I1', 'I2', 'I3']) assert.equal(check(p, id).verdict, 'PASS', id);
  for (const id of ['K1', 'PAY1', 'C7', 'O1', 'CK1', 'CK4', 'R1']) assert.equal(check(p, id).verdict, 'SKIP', id);
  assert.match(r.out, /Режим: только чтение/);
});
