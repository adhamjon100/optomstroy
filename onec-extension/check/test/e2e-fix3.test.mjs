// fix3 (ревью verify2): сценарии рецензентов через фасад 1С (test/helpers/front-1c.mjs), данные вымышленные.
//  - латинская раскладка: «y» (клавиша «н») на «Выполнить перерегистрацию?», «Создать пробный QR?», «Публикация закрыта
//    из интернета?» — не «да»: ни одного POST перерегистрации и QR, M3 не «ВРУЧНУЮ: ДА»;
//  - F02, F08: наименования товаров («долговечная 2.70 кг», «Клей плиточный Мастер 25 кг») и «Розничный покупатель»
//    в тексте ошибки — не E9 ОШИБКА, код 0;
//  - H06 (поиск по телефону возвращает чужого кандидата), H07b («+9960…»), H21 (ref штрихкода — GUID), H26 (post=false,
//    а документ проведён), H30 (/external-ids не соблюдает limit), P03 (ошибка со статусом 200) — ОШИБКА, код 1.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { jsonResponse, mutateJson } from './helpers/front-1c.mjs';
import {
  mockWithSecrets, frontWithSecrets, makeConfig, runMain, runInteractive, readProtocol, check, checkTexts, tmpDir, secretForms, leaks,
} from './helpers/env.mjs';

const dirs = [];
const closers = [];
after(async () => { for (const c of closers) await c(); for (const d of dirs) fs.rmSync(d, { recursive: true, force: true }); });

const uuidFrom = (s) => {
  const h = crypto.createHash('sha1').update(s).digest('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`;
};
const is = (c, m, sub) => c.method === m && c.sub === sub;
const isImage = (c) => c.method === 'GET' && /^\/pos\/v1\/images\/[^/]+$/.test(c.sub || '');
const isRecv = (c) => c.method === 'GET' && /^\/pos\/v1\/customers\/[^/]+\/receivables$/.test(c.sub || '');
const eachType = (j, type, fn) => { for (const it of (j && Array.isArray(j.items)) ? j.items : []) if (it && it.type === type) fn(it); };
const bodyOf = (c) => { const p = c.json(); return p.ok ? p.value : null; };

async function runWith(defect, { write = false } = {}) {
  const { front, password, clientKey } = await frontWithSecrets({ defect });
  closers.push(() => front.close());
  const dir = tmpDir(`oc-fix3-${defect.id}-`);
  dirs.push(dir);
  const cfg = makeConfig(dir, { baseUrl: front.baseUrl, password, clientKey });
  const r = await runMain(['--config', cfg, '--allow-http', '--no-manual', ...(write ? ['--allow-write'] : [])],
    { input: write ? `${front.publication}\n` : '', timeoutMs: 240000 });
  const p = readProtocol(path.join(dir, 'protokoly'));
  assert.ok(p, `нет протокола: ${r.out.slice(-1500)}`);
  assert.deepEqual(leaks([r.out, ...p.texts], secretForms(password, clientKey)), []);
  return { ...r, p, journal: front.journal };
}

const fails = (p) => p.json.checks.filter((c) => c.verdict === 'FAIL').map((c) => `${c.id}: ${checkTexts(c)}`);
const codes = (c) => c.findings.map((f) => `${f.severity} ${f.code}`);

test('латинская раскладка: «y» на перерегистрацию, пробный QR и M3 — не «да»: POST не уходят, M3 не ВРУЧНУЮ: ДА, подсказка о раскладке', async () => {
  const { mock, password, clientKey } = await mockWithSecrets();
  closers.push(() => mock.close());
  const dir = tmpDir('oc-fix3-layout-');
  dirs.push(dir);
  const cfg = makeConfig(dir, { baseUrl: mock.baseUrl, password, clientKey });
  const y3 = (re) => [[re, 'y'], [re, 'y'], [re, 'y']];
  const r = await runInteractive(['--config', cfg, '--allow-http', '--allow-write'], [
    [/введите имя публикации/, mock.publication],
    ...y3(/Выполнить перерегистрацию[^\n]*\[д\/Н\]: /),
    ...y3(/Создать пробный QR[^\n]*\[д\/Н\]: /),
    [/Измените в 1С описание товара/, 'g'],
    [/удалите на копии/, 'g'],
    ...y3(/Сальдо совпадает[^\n]*\[д\/н\/П\]: /),
    [/Включите в 1С константу ОбменПриостановлен/, 'g'],
    ...y3(/Публикация закрыта из интернета[^\n]*\[д\/н\/П\]: /),
    [/Найдите в 1С объекты из списка/, 'g'],
    [/POS_ЖурналЗапросовPOS/, 'g'],
    [/работали без замедления/, 'l'],
  ], { timeoutMs: 240000 });
  assert.deepEqual(r.unanswered, [], `не все вопросы заданы: ${r.unanswered.join(', ')}\n${r.out.slice(-2500)}`);
  // Запросы без ключа (проверки доступа A) получают 401 и ничего не делают; принятых (2xx) быть не должно.
  const done = mock.journal.filter((j) => j.method === 'POST' && j.status >= 200 && j.status < 300).map((j) => j.path || '');
  assert.ok(!done.some((p) => /reregister/.test(p)), `перерегистрация не должна уходить: ${done.join(', ')}`);
  assert.ok(!done.some((p) => /payments\/qr$/.test(p)), `QR не должен создаваться: ${done.join(', ')}`);
  assert.ok((r.out.match(/Похоже, включена латинская раскладка — ответьте д или н/g) || []).length >= 6, r.out.slice(-3000));
  assert.match(r.out, /Похоже, включена латинская раскладка — ответьте д, н или п/);
  const p = readProtocol(path.join(dir, 'protokoly'));
  assert.ok(p, r.out.slice(-1500));
  assert.equal(check(p, 'C6').verdict, 'SKIP', checkTexts(check(p, 'C6')));
  assert.equal(check(p, 'Q1').verdict, 'SKIP', checkTexts(check(p, 'Q1')));
  assert.notEqual(check(p, 'M3').verdict, 'MANUAL_YES');
  assert.equal(check(p, 'M3').verdict, 'SKIP', '«y» трижды на [д/н/П] — «пропустить» (ответ на Enter)');
  assert.notEqual(check(p, 'K10').verdict, 'MANUAL_YES');
  assert.equal(check(p, 'M10').verdict, 'MANUAL_YES', '«l» (клавиша «д» в латинской раскладке) — «да»');
  assert.equal(check(p, 'C11').verdict, 'SKIP', '«g» (клавиша «п») — пропустить');
});

test('F02: наименования товаров «долговечная … 2.70 кг», «Аванс по заказу …», «лимит кредита» в текстах ошибок — не E9 ОШИБКА, код 0', async () => {
  const r = await runWith({
    id: 'F02',
    after: (c, res) => {
      if (isImage(c) && res.status === 404) return mutateJson(res, (j) => { j.message = 'Файл не найден: у товара «Эмаль ПФ-115 долговечная белая 2.70 кг» (код 00-00001234) нет такого файла'; });
      if (is(c, 'POST', '/pos/v1/payments') && res.status === 422) {
        return mutateJson(res, (j) => {
          j.message = /Заказ/.test(j.message) ? 'Заказ не найден. Аванс по заказу ЗК-000123 от 20.11.2026 не зачтён' : 'Распределение оплаты не выполнено';
          j.details = { lines: [{ lineNumber: 1, text: 'Документ РТУ-000123 от 20.11.2026: товар «Эмаль ПФ-115 долговечная белая 2.70 кг», количество 2.000, уже оплачен' }] };
        });
      }
      if (isRecv(c) && res.status === 404) return mutateJson(res, (j) => { j.message = 'Клиент не найден (Кабель ВВГнг 3х2.50 долговечный; Ограничитель лимита 1.50 м; Плитка Керамин Сальдо 30.00х60.00)'; });
      return null;
    },
  }, { write: true });
  const e9 = check(r.p, 'E9');
  assert.ok(!e9.findings.some((f) => f.severity === 'FAIL'), checkTexts(e9));
  for (const id of ['I3', 'K9', 'PAY4', 'PAY5']) assert.equal(check(r.p, id).verdict, 'PASS', `${id}: ${checkTexts(check(r.p, id))}`);
  assert.equal(r.code, 0, `${fails(r.p).join('\n')}\n${r.out.slice(-1500)}`);
});

test('F08: «Розничный покупатель» и однословная организация «Мастер» в наименовании товара — не E9 ОШИБКА, код 0', async () => {
  const r = await runWith({
    id: 'F08',
    after: (c, res) => {
      if (is(c, 'GET', '/pos/v1/changes') && res.status === 200) {
        return mutateJson(res, (j) => {
          if (j.hasMore !== false) return;
          j.items.push({ type: 'Catalog_Партнеры', ref: 'c3d4e5f6-0000-4000-8000-0000000000f8', dataVersion: 'AAAAAQAAAAg=', deletionMark: false, externalId: null, code: '00000001', description: 'Розничный покупатель', fullName: null, isClient: true, mainAgreementRef: null, phones: [] });
          j.items.push({ type: 'Catalog_Партнеры', ref: 'c3d4e5f6-0000-4000-8000-0000000000f9', dataVersion: 'AAAAAQAAAAk=', deletionMark: false, externalId: null, code: '00000077', description: 'Мастер', fullName: 'ОсОО «Мастер»', isClient: true, mainAgreementRef: null, phones: [] });
        });
      }
      if (isImage(c) && res.status === 404) return mutateJson(res, (j) => { j.message = 'Файл не найден: картинка товара «Клей плиточный Мастер 25 кг» удалена'; });
      if (isRecv(c) && res.status === 404) return mutateJson(res, (j) => { j.message = 'Клиент не найден; продажу без клиента оформляйте на «Розничный покупатель»'; });
      return null;
    },
  });
  const e9 = check(r.p, 'E9');
  assert.ok(!e9.findings.some((f) => f.severity === 'FAIL'), checkTexts(e9));
  assert.equal(r.code, 0, `${fails(r.p).join('\n')}\n${r.out.slice(-1500)}`);
  // Однословное имя организации в протоколе всё равно скрыто (целым словом); «Розничный покупатель» — нет.
  assert.ok(!r.p.texts.some((t) => /Клей плиточный Мастер/.test(t)), 'имя организации «Мастер» скрыто и в наименовании товара');
});

test('H06: поиск по телефону возвращает кандидата с другим номером — K7 ОШИБКА «кандидат с другим телефоном», код 1', async () => {
  const r = await runWith({
    id: 'H06',
    after: (c, res) => (is(c, 'GET', '/pos/v1/customers') && res.status === 200 ? mutateJson(res, (j) => {
      if (Array.isArray(j)) j.push({ ref: 'c3d4e5f6-0000-4000-8000-0000000000e9', contractorRef: null, code: '00009999', name: 'ООО Посторонний', phone: '+996555000111', deletionMark: false });
    }) : null),
  });
  const k7 = check(r.p, 'K7');
  assert.equal(k7.verdict, 'FAIL', checkTexts(k7));
  assert.match(checkTexts(k7), /кандидат с другим телефоном — поиск не фильтрует по номеру: 1 из 2/);
  assert.ok(codes(k7).includes('FAIL other-phone'));
  assert.ok(!r.p.texts.some((t) => t.includes('+996555000111') || t.includes('555000111')), 'номер постороннего кандидата скрыт');
  assert.equal(r.code, 1);
});

test('H07b: телефоны «+9960XXXXXXXXX» (к +996 приписан номер с 0) — E5 ОШИБКА «после +996 должно быть 9 цифр», код 1', async () => {
  const fix = (p) => (typeof p === 'string' && /^\+996\d{9}$/.test(p) ? '+9960' + p.slice(4) : p);
  const r = await runWith({
    id: 'H07b',
    after: (c, res) => {
      if (is(c, 'GET', '/pos/v1/customers') && res.status === 200) return mutateJson(res, (j) => { if (Array.isArray(j)) for (const x of j) x.phone = fix(x.phone); });
      if (is(c, 'GET', '/pos/v1/changes') && res.status === 200) return mutateJson(res, (j) => eachType(j, 'Catalog_Партнеры', (it) => { for (const p of it.phones || []) p.phone = fix(p.phone); }));
      return null;
    },
  });
  const e5 = check(r.p, 'E5');
  assert.equal(e5.verdict, 'FAIL', checkTexts(e5));
  assert.match(checkTexts(e5), /после \+996 должно быть 9 цифр, пришло 10; похоже, к \+996 приписан номер с ведущим 0/);
  assert.ok(!r.p.texts.some((t) => t.includes('9960700000001')), 'телефон скрыт');
  assert.equal(r.code, 1);
});

test('H21: ref набора штрихкодов — GUID вместо значения штрихкода — C3 ОШИБКА, код 1', async () => {
  const r = await runWith({
    id: 'H21',
    after: (c, res) => (is(c, 'GET', '/pos/v1/changes') && res.status === 200
      ? mutateJson(res, (j) => eachType(j, 'InformationRegister_ШтрихкодыНоменклатуры', (it) => { it.ref = uuidFrom('bc:' + it.barcode); })) : null),
  });
  const c3 = check(r.p, 'C3');
  assert.equal(c3.verdict, 'FAIL', checkTexts(c3));
  assert.match(checkTexts(c3), /ref набора штрихкодов — значение штрихкода, не GUID/);
  assert.equal(r.code, 1);
});

test('H26: POST /payments с post=false → 201 posted=true — PAY1 ОШИБКА «документ проведён, хотя post=false», код 1', async () => {
  const r = await runWith({
    id: 'H26',
    after: (c, res) => (is(c, 'POST', '/pos/v1/payments') && (res.status === 201 || res.status === 200) && bodyOf(c)?.post === false
      ? mutateJson(res, (j) => { j.posted = true; }) : null),
  }, { write: true });
  const p1 = check(r.p, 'PAY1');
  assert.equal(p1.verdict, 'FAIL', checkTexts(p1));
  assert.match(checkTexts(p1), /документ проведён, хотя post=false/);
  assert.equal(check(r.p, 'PAY2').verdict, 'FAIL', checkTexts(check(r.p, 'PAY2')));
  assert.equal(r.code, 1);
  assert.match(r.p.texts[1], /отмените проведение/, 'в таблице созданных объектов — как удалить проведённый документ');
});

test('H30: /external-ids не соблюдает limit (limit=10 → 25 записей) — X2 ОШИБКА «страница больше limit», код 1', async () => {
  const r = await runWith({
    id: 'H30',
    after: (c, res) => {
      if (!(is(c, 'GET', '/pos/v1/external-ids') && res.status === 200 && Number(c.query.get('limit')) === 10)) return null;
      return mutateJson(res, (j) => {
        if (!Array.isArray(j.items)) return;
        for (let i = j.items.length; i < 25; i++) {
          j.items.push({ externalId: uuidFrom('xid' + i), objectType: 'Клиент', ref: uuidFrom('ref' + i), number: String(10000 + i).padStart(8, '0'), date: null, deletionMark: false });
        }
      });
    },
  });
  const x2 = check(r.p, 'X2');
  assert.equal(x2.verdict, 'FAIL', checkTexts(x2));
  assert.match(checkTexts(x2), /страница больше limit — 1С не ограничивает страницу: 25 записей при limit=10/);
  assert.equal(r.code, 1);
});

test('P03: долг неизвестного клиента отвечает 200 с телом ошибки POS_E_NOT_FOUND — K9 и E7 ОШИБКА «ошибка отдана со статусом 200», код 1', async () => {
  // Раньше — проба метода отозванного задания; правило то же, метод контракта 1.2.0 (GET /customers/{ref}/receivables).
  const r = await runWith({
    id: 'P03',
    before: (c) => (c.method === 'GET' && /^\/pos\/v1\/customers\/[^/]+\/receivables$/.test(c.sub || '') && c.key
      ? jsonResponse(200, { code: 'POS_E_NOT_FOUND', message: 'Клиент не найден', requestId: c.reqId }, c.reqId) : null),
  });
  const k9 = check(r.p, 'K9');
  assert.equal(k9.verdict, 'FAIL', checkTexts(k9));
  assert.match(checkTexts(k9), /нужен 404 POS_E_NOT_FOUND, пришёл 200/);
  const e7t = checkTexts(check(r.p, 'E7'));
  assert.match(e7t, /ошибка отдана со статусом 200 \(POS_E_NOT_FOUND\) — нужен HTTP-код из приложения А\.1 Требований/);
  const e7 = check(r.p, 'E7');
  assert.equal(e7.verdict, 'FAIL', checkTexts(e7));
  assert.ok(codes(e7).includes('FAIL error-200'));
  assert.equal(r.code, 1);
});
