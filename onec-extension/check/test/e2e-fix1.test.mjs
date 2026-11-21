// Сценарии исправлений ревью 2026-11-20 (раунд fix1) через фасад 1С (test/helpers/front-1c.mjs). Данные вымышленные.
//  - нет обязательных методов (долг, картинки, поиск — 405, заказы, корзина) — ОШИБКА «метод обязателен»;
//    QR, заявки на возврат (условно обязательны: Q-014, Q-018) и карточка товара — МЕТОДА НЕТ, не ошибка;
//  - ПДн в непривычных местах (адрес юрлица, контакты, имя в тексте 409) и секреты с цифрами — скрыты;
//  - неверный JSON с именем клиента: сырой текст не пишется, только скелет; текста V8 нет;
//  - запросы «без ключа» не меняют данные; если 1С всё же ответила 2xx — это в протоколе и на экране;
//  - K1 не создал клиента — оплаты ПРОПУЩЕНО, клиентов базы программа не трогает;
//  - Ctrl+C: незаконченная проверка — ПРОПУЩЕНО, итог «прервана», объект без ответа — «результат неизвестен»;
//  - сообщение больше limits.maxPages — C7/C14 ПРОПУЩЕНО, не ОШИБКА.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import {
  frontWithSecrets, makeConfig, runMain, readProtocol, check, checkTexts, tmpDir, secretForms, leaks, MAIN,
} from './helpers/env.mjs';
import { jsonResponse, mutateJson, posError } from './helpers/front-1c.mjs';

const dirs = [];
const fronts = [];
after(async () => { for (const f of fronts) await f.close(); for (const d of dirs) fs.rmSync(d, { recursive: true, force: true }); });

async function scenario(prefix, { defect = null, args = [], input = '', password, clientKey, extra = {} } = {}) {
  const { front, password: pw, clientKey: ck } = await frontWithSecrets({ defect, ...(password ? { password } : {}), ...(clientKey ? { clientKey } : {}) });
  fronts.push(front);
  const dir = tmpDir(prefix);
  dirs.push(dir);
  const cfg = makeConfig(dir, { baseUrl: front.baseUrl, password: pw, clientKey: ck, extra });
  const r = await runMain(['--config', cfg, '--allow-http', ...args], { input });
  return { ...r, p: readProtocol(path.join(dir, 'protokoly')), front, password: pw, clientKey: ck, dir, cfg };
}

const EMPTY404 = { status: 404, headers: {}, body: Buffer.alloc(0) };

test('нет обязательных методов (долг, картинки, поиск → 405, заказы, корзина) — ОШИБКА «метод обязателен»; QR, возвраты и карточка — МЕТОДА НЕТ', async () => {
  const absent = [/^\/pos\/v1\/orders(\/|$)/, /^\/pos\/v1\/returns(\/|$)/, /^\/pos\/v1\/payments\/qr$/, /^\/pos\/v1\/payments\/[^/]+\/(status|qr\/cancel)$/,
    /^\/pos\/v1\/check$/, /^\/pos\/v1\/catalog\//, /^\/pos\/v1\/customers\/[^/]+\/receivables$/, /^\/pos\/v1\/images\//];
  const defect = {
    id: 'TZ23',
    before: (c) => {
      if (c.sub === null) return null;
      if (absent.some((re) => re.test(c.sub))) return EMPTY404;
      // шаблон /customers только для POST: на GET платформа 1С отвечает 405
      if (c.sub === '/pos/v1/customers' && c.method === 'GET') return { status: 405, headers: { allow: 'POST' }, body: Buffer.alloc(0) };
      return null;
    },
  };
  const r = await scenario('oc-f1-absent-', { defect, args: ['--no-manual', '--allow-write'], input: 'proverka_test\n' });
  assert.equal(r.code, 1, r.out.slice(-2500));
  // Обязательные методы (Требования §6, x-priority: must): «метода нет» — ОШИБКА с разделом и этапом работ.
  for (const id of ['K7', 'K9', 'I3', 'O0', 'CK1']) {
    assert.equal(check(r.p, id).verdict, 'FAIL', `${id}: ${check(r.p, id).summary}`);
    assert.match(checkTexts(check(r.p, id)), /МЕТОДА НЕТ — .*метод обязателен \(Требования к API 1С §6\.\d+/, id);
  }
  assert.match(checkTexts(check(r.p, 'K7')), /шаблон URL есть, а обработчика этого HTTP-метода нет — ответ 405/);
  // Зависимые проверки — ПРОПУЩЕНО со ссылкой на ошибку, а не вторая ошибка.
  for (const id of ['K8', 'I1', 'I2', 'O1', 'O6', 'CK2', 'CK4']) assert.equal(check(r.p, id).verdict, 'SKIP', `${id}: ${check(r.p, id).summary}`);
  // QR (если интеграция с банком умеет), заявки на возврат (если 1С принимает их извне — Q-018, вопрос 77; раунд fixo1)
  // и карточка товара (по желанию) — МЕТОДА НЕТ, не ошибка.
  for (const id of ['Q0', 'R0', 'R1', 'CC1']) assert.equal(check(r.p, id).verdict, 'ABSENT', `${id}: ${check(r.p, id).summary}`);
  assert.match(check(r.p, 'Q0').summary, /интеграция с банком/);
  assert.match(check(r.p, 'R0').summary, /обязательны, если 1С принимает заявки на возврат извне .*Q-018, вопрос 77/);
  for (const id of ['A6', 'E7', 'E12', 'M1']) assert.notEqual(check(r.p, id).verdict, 'FAIL', `${id}: ${checkTexts(check(r.p, id))}`);
});

test('ПДн в непривычных местах и секреты с цифрами ИНН и телефона — нигде не видны', async () => {
  const clientKey = 'Test-Klyuch-12345678901234-zz';
  const password = 'Parol!0555123456-Vymysel';
  const defect = {
    id: 'PRIV',
    after: (c, r) => {
      if (c.method === 'POST' && c.sub === '/pos/v1/customers' && r.status === 409) return mutateJson(r, (j) => { j.message = 'Клиент Жумабеков уже есть, тел. 0555-12-34-56 (моб. 700 123 456)'; });
      if (c.method === 'GET' && c.sub === '/pos/v1/health' && r.status === 200) return mutateJson(r, (j) => { j.debugNode = clientKey; j.debugPw = password; });
      if (c.method === 'GET' && c.sub === '/pos/v1/changes' && r.status === 200) {
        return mutateJson(r, (j) => { for (const it of j.items || []) if (it.type === 'Catalog_Партнеры') { it.legalAddress = 'г. Бишкек, ул. Вымышленная, 77'; it.contacts = [{ kind: 'phone', value: '0777-11-22-33' }]; it.director = 'Вымышленный Директорович'; } });
      }
      return null;
    },
  };
  const r = await scenario('oc-f1-priv-', { defect, password, clientKey, args: ['--no-manual', '--allow-write', '--verbose'], input: 'proverka_test\n' });
  assert.equal(r.code, 1, r.out.slice(-2000));
  const all = [r.out, ...r.p.texts];
  assert.deepEqual(leaks(all, ['0555-12-34-56', '700 123 456', 'Жумабеков', 'Асанова', '0555-44-33-22', 'Вымышленная, 77', '0777-11-22-33', 'Директорович']), [], 'ПДн в выводе');
  assert.deepEqual(leaks([...all, fs.readFileSync(r.cfg, 'utf8')], [...secretForms(password, clientKey), 'Test-Klyuch', 'Parol!0555']), [], 'секрет в выводе');
  const e9 = check(r.p, 'E9');
  assert.equal(e9.verdict, 'FAIL');
  assert.match(checkTexts(e9), /в тексте ошибки телефон/);
});

test('неверный JSON с именем клиента: в протоколе нет сырого текста — только скелет; в E3 нет текста V8', async () => {
  const NAME = 'Петров Иван Сидорович';
  const ORG = 'ОсОО "Ромашка-Тест"';
  const ADDR = 'г. Бишкек, ул. Вымышленная, 12';
  const defect = {
    id: 'BADJSON',
    before: (c) => {
      if (!(c.method === 'GET' && c.sub === '/pos/v1/changes' && c.query.get('since') === '5120' && c.key)) return null;
      const item = `{"type":"Catalog_Партнеры","ref":"c3d4e5f6-0000-4000-8000-000000000001","dataVersion":"AAAAAwAAAAA=","deletionMark":false,"externalId":null,"code":"00004521","description":"${ORG}","fullName":"${NAME}","isClient":true,"mainAgreementRef":null,"phones":[{"phone":"+996700000001","presentation":"0700 000 001"}],"address":"${ADDR}"}`;
      const body = `{"messageNumber":5121,"hasMore":false,"cursor":null,"generatedAt":"2026-10-21T14:05:01+06:00","items":[${item}]}`;
      return { status: 200, headers: { 'content-type': 'application/json; charset=utf-8', 'x-request-id': c.reqId, 'x-pos-api-version': '1' }, body: Buffer.from(body, 'utf8') };
    },
  };
  const r = await scenario('oc-f1-badjson-', { defect, args: ['--no-manual'] });
  assert.equal(r.code, 1, r.out.slice(-1500));
  assert.deepEqual(leaks([r.out, ...r.p.texts], ['Петров', 'Ромашка', 'Вымышленная', 'Сидорович', '700000001', '0700 000 001']), []);
  const e3 = checkTexts(check(r.p, 'E3'));
  assert.match(e3, /тело — неверный JSON \(строка 1, столбец \d+\)/);
  assert.ok(!/Unexpected|valid JSON/.test(e3), e3);
  const body = check(r.p, 'C2').exchanges.find((e) => e.resBody && e.resBody.includes('не JSON'))?.resBody || '';
  assert.match(body, /не JSON: \d+ байт, Content-Type: application\/json; charset=utf-8, ошибка разбора: строка 1, столбец \d+/);
  assert.match(body, /"description": "\[текст скрыт\]"/, 'скелет: ключ виден, значение скрыто');
  assert.match(body, /"ref": "c3d4e5f6-0000-4000-8000-000000000001"/, 'GUID в скелете остаётся');
});

test('запросы «без ключа» ничего не меняют; 2xx на них и ack невыданного номера — в протоколе и на экране', async () => {
  const defect = {
    id: 'SIDEFX',
    before: (c) => {
      if (c.method === 'POST' && c.sub === '/pos/v1/payments' && !c.key) return jsonResponse(201, { ref: 'f1e2d3c4-0000-4000-8000-0000000000ab' }, c.reqId);
      if (c.method === 'POST' && c.sub === '/pos/v1/changes/reregister' && !c.key) return { status: 202, headers: { 'x-request-id': c.reqId }, body: Buffer.alloc(0) };
      if (c.method === 'POST' && c.sub === '/pos/v1/changes/ack' && c.key) {
        const j = c.json();
        if (j.ok && j.value && j.value.messageNumber >= 6000) return jsonResponse(200, { messageNumber: j.value.messageNumber, removedRegistrations: 0 }, c.reqId);
      }
      return null;
    },
  };
  const r = await scenario('oc-f1-sidefx-', { defect, args: ['--no-manual', '--allow-write'], input: 'proverka_test\n' });
  assert.equal(r.code, 1, r.out.slice(-2000));
  assert.ok(!r.front.journal.some((j) => j.path.endsWith('/changes/reregister')), 'перерегистрация без ответа «да» (C6) не вызывается — и без ключа тоже');
  // Каждый POST без ключа — неразбираемое тело.
  const noKeyPosts = r.front.journal.filter((j) => j.method === 'POST' && j.body === '{"externalId":');
  assert.ok(noKeyPosts.length >= 4, 'A6 и пробы отправили неразбираемое тело');
  assert.ok(!r.front.journal.some((j) => j.method === 'POST' && j.body === '{}'), 'тела {} без ключа больше нет');
  assert.equal(check(r.p, 'A6').verdict, 'FAIL');
  assert.equal(check(r.p, 'C9').verdict, 'FAIL');
  const sus = r.p.json.createdObjects.find((c) => c.checkId === 'A6');
  assert.ok(sus && /возможно, создан объект: POST \/pos\/v1\/payments/.test(sus.note), JSON.stringify(r.p.json.createdObjects));
  assert.ok(r.p.json.exchangePlanChanges.some((x) => x.checkId === 'C9' && x.messageNumber >= 6000 && /могла снять все регистрации/.test(x.note)));
  assert.match(r.out, /ВНИМАНИЕ \(A6\)/);
  assert.match(r.out, /ВНИМАНИЕ \(C9\)/);
});

test('K1 не создал тестового клиента — оплаты ПРОПУЩЕНО, клиент базы не используется', async () => {
  const defect = {
    id: 'K1REJ',
    before: (c) => (c.method === 'POST' && c.sub === '/pos/v1/customers' && c.key && c.json().ok
      ? posError(422, 'POS_E_VALIDATION', 'Код оператора 000 не существует', c.reqId) : null),
  };
  const r = await scenario('oc-f1-k1rej-', { defect, args: ['--no-manual', '--allow-write'], input: 'proverka_test\n' });
  assert.equal(r.code, 1, r.out.slice(-2000));
  assert.equal(check(r.p, 'K1').verdict, 'FAIL');
  for (const id of ['PAY1', 'PAY2', 'PAY3', 'PAY4', 'PAY5']) {
    assert.equal(check(r.p, id).verdict, 'SKIP', id);
  }
  assert.match(check(r.p, 'PAY1').summary, /нет тестового клиента «ПРОВЕРКА POS»/);
  const payBodies = r.front.journal.filter((j) => j.method === 'POST' && j.path === '/pos/v1/payments').map((j) => j.body);
  assert.ok(payBodies.every((b) => b === '{"externalId":'), `оплата ушла с данными: ${payBodies.join(' | ').slice(0, 300)}`);
  assert.match(r.out, /Оплаты 1\.00 KGS привязываются только к тестовому клиенту «ПРОВЕРКА POS»/);
  assert.equal(r.p.json.createdObjects.filter((c) => c.kind === 'Платеж').length, 0);
});

function runWithSigint(args, { input = '', sigintMs }) {
  return new Promise((resolve) => {
    const hook = pathToFileURL(path.join(path.dirname(MAIN), '..', 'test', 'helpers', 'sigint-hook.mjs')).href;
    const p = spawn(process.execPath, ['--import', hook, MAIN, ...args], { stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, TEST_SIGINT_MS: String(sigintMs) } });
    let out = '';
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { out += d; });
    p.stdin.end(input);
    const t = setTimeout(() => p.kill(), 120000);
    p.on('close', (code) => { clearTimeout(t); resolve({ code, out }); });
  });
}

test('Ctrl+C во время чтения: незаконченная проверка — ПРОПУЩЕНО, итог «прервана», не «Ошибок нет»', async () => {
  const defect = { id: 'SLOWCH', delay: { match: (c) => c.method === 'GET' && c.sub === '/pos/v1/changes', ms: 8000 } };
  const { front, password, clientKey } = await frontWithSecrets({ defect });
  fronts.push(front);
  const dir = tmpDir('oc-f1-sig-');
  dirs.push(dir);
  const cfg = makeConfig(dir, { baseUrl: front.baseUrl, password, clientKey });
  const r = await runWithSigint(['--config', cfg, '--allow-http', '--no-manual', '--checks', 'C1'], { sigintMs: 2500 });
  assert.equal(r.code, 2, r.out.slice(-1500));
  const p = readProtocol(path.join(dir, 'protokoly'));
  assert.equal(check(p, 'C1').verdict, 'SKIP', check(p, 'C1').summary);
  assert.match(check(p, 'C1').summary, /не завершена/);
  assert.ok(!p.texts[1].includes('**Ошибок нет**'), 'в .md итог не «Ошибок нет»');
  assert.match(p.texts[1], /Проверка прервана — итог неполный/);
  assert.match(p.texts[0], /Проверка прервана — итог неполный/);
  // E-правила без ответов 1С по ним — не «ПРОЙДЕНО (ответов: 0)»
  for (const c of p.json.checks.filter((x) => x.group === 'E')) assert.ok(!/ответов: 0/.test(c.summary), `${c.id}: ${c.summary}`);
});

test('Ctrl+C во время создания клиента: K1 ПРОПУЩЕНО, объект в протоколе — «результат неизвестен»', async () => {
  const defect = { id: 'SLOWPOST', delay: { match: (c) => c.method === 'POST' && c.sub === '/pos/v1/customers', ms: 10000 } };
  const { front, password, clientKey } = await frontWithSecrets({ defect });
  fronts.push(front);
  const dir = tmpDir('oc-f1-sigw-');
  dirs.push(dir);
  const cfg = makeConfig(dir, { baseUrl: front.baseUrl, password, clientKey });
  const r = await runWithSigint(['--config', cfg, '--allow-http', '--no-manual', '--allow-write', '--checks', 'K1'], { input: `${front.publication}\n`, sigintMs: 3500 });
  assert.equal(r.code, 2, r.out.slice(-1500));
  assert.ok(front.journal.some((j) => j.method === 'POST' && j.path === '/pos/v1/customers'), 'запрос создания дошёл до 1С');
  const p = readProtocol(path.join(dir, 'protokoly'));
  assert.equal(check(p, 'K1').verdict, 'SKIP');
  const k1 = p.json.createdObjects.find((c) => c.checkId === 'K1');
  assert.ok(k1 && k1.unknown && /^5e1f7e57-/.test(k1.externalId), JSON.stringify(p.json.createdObjects));
  assert.match(k1.note, /результат неизвестен — найдите по externalId 5e1f7e57-/);
  assert.ok(!('pending' in k1) && !('inflight' in k1), 'служебные поля реестра не в протоколе');
});

test('сообщение больше limits.maxPages: C7 и C14 ПРОПУЩЕНО (не ОШИБКА), ack не отправлен, код 0', async () => {
  const r = await scenario('oc-f1-maxp-', { args: ['--no-manual', '--allow-write'], input: 'proverka_test\n', extra: { limits: { pageLimit: 5, maxPages: 1 } } });
  assert.equal(r.code, 0, r.out.slice(-2500));
  assert.equal(check(r.p, 'C2').verdict, 'WARN');
  assert.equal(check(r.p, 'C7').verdict, 'SKIP');
  assert.match(check(r.p, 'C7').summary, /больше предела программы \(limits\.maxPages 1 × limits\.pageLimit 5\)/);
  assert.equal(check(r.p, 'C14').verdict, 'SKIP');
  assert.ok(!r.front.journal.some((j) => j.method === 'POST' && j.path === '/pos/v1/changes/ack' && j.status === 200), 'ack не отправлен');
});
