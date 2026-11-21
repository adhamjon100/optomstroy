// Сквозные правила E1–E3, E7–E12 (src/rules.mjs) на собранных ответах: страницы IIS, тела ошибок, Content-Type,
// неверный JSON, статусы вне контракта, время. Тексты — по-русски.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { parseExchange, crossRules, isPlatform404, sumsIn } from '../src/rules.mjs';
import { loadContract } from '../src/contract.mjs';
import { Masker } from '../src/mask.mjs';
import { IIS_404, IIS_500, IIS_WELCOME } from './helpers/front-1c.mjs';
import { CHECK_DIR } from './helpers/env.mjs';

const contract = loadContract(path.join(CHECK_DIR, 'src'));
const RID = 'a1b2c3d4-0000-4000-8000-0000000000a9';
const env = () => ({ masker: new Masker(), errorCodes: contract.errorCodes });

function ex({ status, body = '', headers = {}, method = 'GET', ms = 10, error = null, timeoutMs = 30000 }) {
  const buf = Buffer.isBuffer(body) ? body : Buffer.from(typeof body === 'string' ? body : JSON.stringify(body), 'utf8');
  return parseExchange({ status, method, requestId: RID, timeoutMs, ms, error, headers: { 'x-request-id': RID, ...headers }, body: buf });
}
const JSON_CT = { 'content-type': 'application/json; charset=utf-8' };
const ok = { ...JSON_CT, 'x-pos-api-version': '1' };
const run = (e, { op = null, spec = {} } = {}) => crossRules(e, op ? contract.op(op) : null, spec, env());
const text = (list) => list.map((f) => `${f.severity} ${f.rule} ${f.text}`).join('\n');
const severities = (list, rule) => list.filter((f) => f.rule === rule).map((f) => f.severity);

test('хороший ответ 200 и хорошая ошибка 404 — без находок', () => {
  assert.deepEqual(run(ex({ status: 200, body: { status: 'ok' }, headers: ok }), { op: 'GET /pos/v1/health' }), []);
  const e = ex({ status: 404, body: { code: 'POS_E_NOT_FOUND', message: 'Клиент не найден', requestId: RID }, headers: JSON_CT });
  assert.deepEqual(run(e, { op: 'GET /pos/v1/customers/{ref}/receivables' }), []);
  assert.equal(isPlatform404(e), false);
});

test('страница IIS 500 (HTML): на чтении — СВЕДЕНИЯ «ответ платформы», при ошибке данных — E11 ОШИБКА', () => {
  const e = ex({ status: 500, body: IIS_500, headers: { 'content-type': 'text/html' } });
  assert.ok(!e.isPosError);
  assert.equal(e.platform, true);
  const a = run(e, { op: 'GET /pos/v1/changes' });
  assert.deepEqual(severities(a, 'E7'), ['INFO']);
  assert.ok(!a.some((f) => f.severity === 'FAIL'), text(a));
  const b = run(e, { op: 'POST /pos/v1/payments', spec: { dataError: true } });
  assert.match(text(b), /FAIL E11 ошибка данных отдана как 500 — нужен 400 или 422/);
});

test('страница IIS 404 — «нет метода» (ответ платформы), не тело POS', () => {
  const e = ex({ status: 404, body: IIS_404, headers: { 'content-type': 'text/html' } });
  assert.equal(isPlatform404(e), true);
  assert.deepEqual(severities(run(e), 'E7'), ['INFO']);
});

test('HTML вместо JSON у 200 (стартовая страница IIS) — E3 «ответ не JSON»', () => {
  const t = text(run(ex({ status: 200, body: IIS_WELCOME, headers: { 'content-type': 'text/html', 'x-pos-api-version': '1' } })));
  assert.match(t, /FAIL E3 ответ не JSON \(Content-Type: text\/html\)/);
});

test('400 без тела POS (HTML) — E7 ОШИБКА: статус не платформенный', () => {
  const t = text(run(ex({ status: 400, body: '<html><body>Bad Request</body></html>', headers: { 'content-type': 'text/html' } })));
  assert.match(t, /FAIL E7 ответ 400 без тела ошибки в едином формате/);
});

test('тело ошибки без code / с code не POS_E_ — «не по формату»; без message и requestId; details-массив', () => {
  assert.match(text(run(ex({ status: 404, body: { message: 'Клиент не найден', requestId: RID }, headers: JSON_CT }))), /FAIL E7 тело ошибки не по формату \{code, message, details\?, requestId\} \(статус 404\)/);
  assert.match(text(run(ex({ status: 409, body: { code: 'DUPLICATE', message: 'Дубль', requestId: RID }, headers: JSON_CT }))), /тело ошибки не по формату/);
  const t = text(run(ex({ status: 422, body: { code: 'POS_E_VALIDATION', details: [1] }, headers: JSON_CT })));
  assert.match(t, /FAIL E7 в теле ошибки нет строки message/);
  assert.match(t, /FAIL E7 в теле ошибки нет requestId/);
  assert.match(t, /FAIL E7 details должен быть объектом/);
});

test('Content-Type ошибки text/plain при JSON-теле — E3 ОШИБКА; application/problem+json — допустимо', () => {
  const body = { code: 'POS_E_BAD_REQUEST', message: 'Неверный запрос', requestId: RID };
  assert.match(text(run(ex({ status: 400, body, headers: { 'content-type': 'text/plain; charset=utf-8' } }))), /FAIL E3 ответ не JSON \(Content-Type: text\/plain/);
  assert.deepEqual(severities(run(ex({ status: 400, body, headers: { 'content-type': 'application/problem+json; charset=utf-8' } })), 'E3'), []);
});

test('неверный JSON, пустое тело, charset не utf-8 — E3', () => {
  assert.match(text(run(ex({ status: 200, body: '{"items": [', headers: ok }))), /FAIL E3 тело — неверный JSON/);
  assert.match(text(run(ex({ status: 200, body: '', headers: ok }))), /FAIL E3 пустое тело ответа — ожидался JSON/);
  assert.match(text(run(ex({ status: 200, body: { a: 1 }, headers: { ...ok, 'content-type': 'application/json; charset=windows-1251' } }))), /FAIL E3 charset=windows-1251 — нужно utf-8/);
  // 202 и 204 тела не требуют.
  assert.deepEqual(severities(run(ex({ status: 202, body: '', headers: { 'x-pos-api-version': '1' } })), 'E3'), []);
});

test('E2: нет X-Request-Id в ответе; регистр GUID в эхе не важен', () => {
  const noEcho = parseExchange({ status: 200, method: 'GET', requestId: RID, timeoutMs: 1000, ms: 1, headers: ok, body: Buffer.from('{}') });
  assert.match(text(run(noEcho)), /FAIL E2 нет заголовка X-Request-Id в ответе/);
  assert.deepEqual(severities(run(ex({ status: 200, body: {}, headers: { ...ok, 'x-request-id': RID.toUpperCase() } })), 'E2'), []);
});

test('E7 код ↔ статус, код вне x-error-codes метода — ЗАМЕЧАНИЕ, 423 не у /orders и /check — ЗАМЕЧАНИЕ', () => {
  const e = ex({ status: 503, body: { code: 'POS_E_LOCKED', message: 'Объект заблокирован', requestId: RID }, headers: JSON_CT });
  const t = text(run(e, { op: 'GET /pos/v1/customers/{ref}/receivables' }));
  assert.match(t, /WARN E7 код POS_E_LOCKED не указан в x-error-codes метода GET \/pos\/v1\/customers\/\{ref\}\/receivables/);
  const l = text(run(ex({ status: 423, body: { code: 'POS_E_LOCKED', message: 'Заблокировано', requestId: RID }, headers: JSON_CT }), { op: 'POST /pos/v1/payments' }));
  assert.match(l, /WARN E7 423 у \/pos\/v1\/payments/);
});

test('E8: текст исключения 1С, длинный и пустой текст — ЗАМЕЧАНИЕ (содержание message в Требованиях — «текст для журнала», язык и длина не заданы)', () => {
  const mk = (message) => text(run(ex({ status: 422, body: { code: 'POS_E_VALIDATION', message, requestId: RID }, headers: JSON_CT })));
  assert.match(mk('{ОбщийМодуль.POS_HTTPСервис.Модуль(123)}: Ошибка при вызове метода контекста (Записать)'), /WARN E8 текст ошибки похож на текст исключения 1С/);
  assert.match(mk('Ошибка: ' + 'очень длинный текст '.repeat(30)), /WARN E8 текст ошибки длиннее 500 символов/);
  assert.match(mk('   '), /WARN E8 текст ошибки \(message\) пустой/);
});

test('E9: телефон, ИНН, e-mail, сумма долга в message — ОШИБКА; прочая сумма — ЗАМЕЧАНИЕ; телефоны в details.lines тоже', () => {
  const mk = (message, details) => text(run(ex({ status: 409, body: { code: 'POS_E_DUPLICATE', message, details, requestId: RID }, headers: JSON_CT })));
  assert.match(mk('Клиент 0555 12 34 56 уже есть'), /FAIL E9 в тексте ошибки телефон/);
  assert.match(mk('ИНН 02345678901234 уже занят'), /FAIL E9 в тексте ошибки ИНН/);
  assert.match(mk('Ответ на vymysel@primer-kg.test'), /FAIL E9 в тексте ошибки e-mail/);
  assert.match(mk('Долг клиента 12500.00 больше лимита'), /FAIL E9 в тексте ошибки сумма долга/);
  assert.match(mk('Цена изменилась: 12500.00'), /WARN E9 в тексте ошибки число, похожее на сумму/);
  assert.doesNotMatch(mk('Цена изменилась: 12500.00'), /FAIL E9/);
  assert.match(mk('Есть ошибки в строках', { lines: [{ text: 'позвоните +996555123456' }] }), /FAIL E9 в тексте ошибки телефон/);
});

test('E3: текст V8 (с куском тела) в находку не попадает — только строка и столбец', () => {
  const f = run(ex({ status: 200, body: '{"description":"Клиент Асанов "Тест""}', headers: { 'content-type': 'application/json; charset=utf-8', 'x-pos-api-version': '1' } }));
  const t = f.filter((x) => x.rule === 'E3').map((x) => x.text).join(' ');
  assert.match(t, /тело — неверный JSON \(строка 1, столбец \d+\)/);
  assert.ok(!/Асанов|Unexpected|valid JSON/.test(t), t);
});

test('405 платформы (шаблон есть, HTTP-метода нет) — сведения E7, не ошибка; E12 молчит у пробы метода', () => {
  const e = ex({ status: 405, body: '', headers: { allow: 'POST' } });
  assert.deepEqual(severities(run(e), 'E7'), ['INFO']);
  assert.deepEqual(severities(run(e, { op: 'GET /pos/v1/customers', spec: { absentProbe: true } }), 'E12'), []);
});

test('E9: коды УТ и номера документов — не телефон; имя после «Клиент» — замечание', () => {
  const body = (message) => ({ code: 'POS_E_DUPLICATE', message, requestId: RID });
  const e9 = (msg) => run(ex({ status: 409, body: body(msg), headers: { 'content-type': 'application/json; charset=utf-8', 'x-request-id': RID } }), { op: 'POST /pos/v1/customers' }).filter((x) => x.rule === 'E9');
  assert.deepEqual(e9('Клиент с таким телефоном уже есть: код 00-00000045'), []);
  assert.deepEqual(e9('Клиент с таким телефоном уже есть: тел. 0555-12-34-56').map((x) => x.severity), ['FAIL']);
  assert.deepEqual(e9('Клиент Жумабеков уже есть').map((x) => x.severity), ['WARN']);
});

test('fix2 E9: сумма долга в любом формате 1С (пробел, неразрывный пробел, запятая, меньше 1000) — ОШИБКА (V13, V13b–d)', () => {
  const e9 = (message) => run(ex({ status: 404, body: { code: 'POS_E_NOT_FOUND', message, requestId: RID }, headers: JSON_CT }), { op: 'GET /pos/v1/customers/{ref}/receivables' })
    .filter((x) => x.rule === 'E9');
  for (const msg of ['Клиент не найден, сумма долга 15 300.00 сом не обновлена', 'Клиент не найден: долг клиента 15300.00 больше лимита',
    'Клиент не найден, долг 15\u00a0300,00 сом', 'Клиент не найден, долг 15\u202f300,00 сом', 'Клиент не найден, задолженность 850.00 сом',
    'Превышен лимит кредита: 100 000,00', 'Сальдо 1 234,56', '15 300,00 сом долга', 'Долг 5000 сом']) {
    const f = e9(msg);
    assert.ok(f.some((x) => x.severity === 'FAIL' && x.code === 'pii-debt-sum'), `${msg}: ${JSON.stringify(f)}`);
  }
  // Не долг: сумма оплаты, цена, дата и номер документа — не ОШИБКА.
  for (const msg of ['Сумма оплаты 1500.00 больше остатка по заказу', 'Цена 12500,00 изменилась', 'Документ РТ00-001790 от 10.10.2026 не проведён',
    'Остаток товара 12.000 меньше заказанного']) {
    assert.ok(!e9(msg).some((x) => x.severity === 'FAIL'), `${msg}: ${JSON.stringify(e9(msg))}`);
  }
});

test('fix2 E9: ФИО клиента без слова «клиент» (V35) и «Фамилия Имя» после «Партнёр» (V36) — ОШИБКА', () => {
  const e9 = (message) => run(ex({ status: 404, body: { code: 'POS_E_NOT_FOUND', message, requestId: RID }, headers: JSON_CT }), { op: 'GET /pos/v1/customers/{ref}/receivables' })
    .filter((x) => x.rule === 'E9');
  assert.deepEqual(e9('Асанов Бакыт Жумабекович: карточка не найдена').map((x) => `${x.severity} ${x.code}`), ['FAIL pii-имя клиента']);
  assert.deepEqual(e9('Партнёр Токтогулова Айгуль не найден').map((x) => `${x.severity} ${x.code}`), ['FAIL pii-имя клиента']);
  assert.deepEqual(e9('Клиент Асанов Б. Ж. не найден').map((x) => x.severity), ['FAIL']);
  assert.deepEqual(e9('Клиент не найден').map((x) => x.severity), []);
});

test('E10: нет ответа за x-timeout-ms — ОШИБКА; /check дольше 3 с и страница /changes дольше 20 с — ЗАМЕЧАНИЕ (Требования §4.9)', () => {
  const timeout = parseExchange({ status: null, method: 'GET', requestId: RID, timeoutMs: 6000, ms: 6000, headers: {}, body: Buffer.alloc(0), error: Object.assign(new Error('t'), { code: 'RESPONSE_TIMEOUT' }) });
  assert.match(text(run(timeout)), /FAIL E10 нет ответа за 6 с — POS считает результат неизвестным/);
  const okBody = { code: 'x' };
  assert.match(text(run(ex({ status: 200, body: okBody, headers: ok, method: 'POST', ms: 3500 }), { op: 'POST /pos/v1/check' })), /WARN E10 проверка корзины 3\.5 с — дольше цели 3 с \(Требования §4\.9\)/);
  assert.match(text(run(ex({ status: 200, body: okBody, headers: ok, ms: 21000 }), { op: 'GET /pos/v1/changes' })), /WARN E10 страница \/changes 21 с — дольше 20 с \(Требования §4\.9\)/);
  // Запись в пределах таймаута POS (POST /customers — 30 с, Требования §4.9): цели «2 с / 6 с» отозванного задания больше нет.
  assert.deepEqual(severities(run(ex({ status: 201, body: okBody, headers: ok, method: 'POST', ms: 7000 }), { op: 'POST /pos/v1/customers' }), 'E10'), []);
});

test('E12: статус не из ответов операции — ЗАМЕЧАНИЕ; 404 пробы и разрешённые статусы — нет', () => {
  const e = ex({ status: 418, body: { code: 'POS_E_BAD_REQUEST', message: 'Неверно', requestId: RID }, headers: JSON_CT });
  assert.match(text(run(e, { op: 'GET /pos/v1/health' })), /WARN E12 HTTP 418 нет среди ответов GET \/pos\/v1\/health/);
  const p404 = ex({ status: 404, body: IIS_404, headers: { 'content-type': 'text/html' } });
  assert.deepEqual(severities(run(p404, { op: 'GET /pos/v1/customers', spec: { absentProbe: true } }), 'E12'), []);
});

test('fix3 E9: наименования товаров с «долг…», «лимит», «Сальдо», размеры и единицы (кг, м, мм, 3х2.50) — не ОШИБКА (F02)', () => {
  const e9 = (message, details) => run(ex({ status: 404, body: { code: 'POS_E_NOT_FOUND', message, details, requestId: RID }, headers: JSON_CT }), { op: 'GET /pos/v1/images/{ref}' })
    .filter((x) => x.rule === 'E9');
  for (const msg of [
    'Товар «Эмаль ПФ-115 долговечная белая 2.70 кг» помечен на удаление',
    'Кабель ВВГнг 3х2.50 долговечный',
    'Ограничитель лимита 1.50 м',
    'Плитка Керамин Сальдо 30.00х60.00',
    'Файл не найден: у товара «Эмаль ПФ-115 долговечная белая 2.70 кг» (код 00-00001234) нет такого файла',
    'Лист оцинкованный 0.45 мм, кредитная линия не нужна',
    'Заказ не найден. Аванс по заказу ЗК-000123 от 20.11.2026 не зачтён',
    'Клиент не найден (лимит кредита по соглашению «Основное 2026» не проверялся)',
    'Товар «Плитка Керамин Сальдо» по цене 1500.00 не найден',
    'Профиль 60х27 3.00 м, кредит не предусмотрен',
  ]) {
    const f = e9(msg);
    assert.ok(!f.some((x) => x.severity === 'FAIL'), `не ОШИБКА: ${msg}: ${JSON.stringify(f)}`);
    assert.equal(sumsIn(msg).debt, false, msg);
  }
  const lines = { lines: [{ lineNumber: 1, text: 'Документ РТУ-000123 от 20.11.2026: товар «Эмаль ПФ-115 долговечная белая 2.70 кг», количество 2.000, уже оплачен' }] };
  assert.ok(!e9('Распределение оплаты не выполнено', lines).some((x) => x.severity === 'FAIL'));
  // Сумма долга по-прежнему ОШИБКА: целое слово «долг», «лимит», «аванс», «сальдо» рядом с суммой.
  for (const msg of ['Долг клиента 15 300.00 сом', 'Превышен лимит кредита: 50000.00', 'Аванс 500.00 не зачтён', 'Сальдо 1 234,56',
    'Сумма 850.00 сом долга', 'Задолженность по документах 1500.00', 'Клиент не найден, долг 12500.00 больше лимита']) {
    assert.ok(e9(msg).some((x) => x.severity === 'FAIL' && x.code === 'pii-debt-sum'), msg);
  }
});

test('fix3 E7: тело ошибки POS со статусом 200 — ОШИБКА «ошибка отдана со статусом 200» (P03)', () => {
  const e = ex({ status: 200, body: { code: 'POS_E_NOT_FOUND', message: 'Вид цены не найден', requestId: RID }, headers: ok });
  assert.equal(e.errorIn2xx, true);
  const f = run(e).filter((x) => x.rule === 'E7');
  assert.deepEqual(f.map((x) => `${x.severity} ${x.code}`), ['FAIL error-200'], text(f));
  assert.match(f[0].text, /ошибка отдана со статусом 200 \(POS_E_NOT_FOUND\) — нужен HTTP-код из приложения А\.1 Требований/);
  // Обычный ответ с полем code (не POS_E_) и ошибка 404 — без этой находки.
  assert.equal(ex({ status: 200, body: { code: '00-00001234', message: 'x' }, headers: ok }).errorIn2xx, false);
  assert.equal(ex({ status: 404, body: { code: 'POS_E_NOT_FOUND', message: 'Не найден', requestId: RID }, headers: JSON_CT }).errorIn2xx, false);
});
