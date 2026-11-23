// Раунд исправлений fixo2 (ревью онлайн-обмена сборки 1.1.0, 20.11.2026, сценарии .tmp/onec-check/hunt-o2): каждый
// неверный ответ 1С — через фасад test/helpers/front-1c.mjs, отдельный процесс программы. Неверные ответы — нужна ОШИБКА у
// названной проверки; «верно:» — необычный, но верный ответ, который ОШИБКИ давать не должен. Данные вымышленные.
//  - заказ, отменённый пометкой удаления, в /external-ids с deletionMark: true (X4, сценарий G17) — не ошибка;
//  - пакетный статус: наш заказ и в items, и в notFound (O5, O6; N08);
//  - снимок долга устарел (snapshotAt на 3 ч 10 мин раньше запроса) в K8 и в блоке receivables /check (CK4; N16);
//    правила приёма POS — и для блока /check;
//  - статус, пакет и отмена отдают другой номер (НомерНаПечать) или чужой externalId (O4–O7; N06, N07);
//  - /external-ids без since по возрастанию ДатаСоздания (X5, второй запрос КП-19; N21);
//  - пустая дата 1С 0001-01-01 в датах (E5) и поля оплаты QR до оплаты не null (Q3–Q6, Q8; N01, N02).
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { mutateJson, isoBishkek } from './helpers/front-1c.mjs';
import {
  frontWithSecrets, makeConfig, runInteractive, readProtocol, check, checkTexts, tmpDir, secretForms, leaks, limiter, SAMPLES,
} from './helpers/env.mjs';
import { loadContract } from '../src/contract.mjs';
import { Validator } from '../src/schema.mjs';

const dirs = [];
const closers = [];
after(async () => { for (const c of closers) await c(); for (const d of dirs) fs.rmSync(d, { recursive: true, force: true }); });
const limit = limiter(4);

const is = (c, m, re) => c.method === m && re.test(c.sub || '');
const ORDERS = /^\/pos\/v1\/orders$/;
const ORDER_ST = /^\/pos\/v1\/orders\/[^/]+\/status$/;
const ORDER_BATCH = /^\/pos\/v1\/orders\/status$/;
const ORDER_CANCEL = /^\/pos\/v1\/orders\/[^/]+\/cancel$/;
const QR_ST = /^\/pos\/v1\/payments\/[^/]+\/status$/;
const QR_CANCEL = /^\/pos\/v1\/payments\/[^/]+\/qr\/cancel$/;
const CHECK = /^\/pos\/v1\/check$/;
const CHANGES = /^\/pos\/v1\/changes$/;
const XID = /^\/pos\/v1\/external-ids$/;
const RECV = /^\/pos\/v1\/customers\/[^/]+\/receivables$/;
const ok2 = (r) => r.status >= 200 && r.status < 300;
const codes = (c) => c.findings.map((f) => `${f.severity} ${f.code}`);
const EMPTY_DATE = '0001-01-01T00:00:00+06:00';
const NIL = '00000000-0000-0000-0000-000000000000';
const seg4 = (c) => (c.sub || '').split('/')[4];
const jsonOf = (r) => { try { return JSON.parse(r.body.toString('utf8')); } catch { return undefined; } };
// Заказы программы: externalId из ответов POST /orders.
const noteOrder = (c, r) => { if (is(c, 'POST', ORDERS) && ok2(r)) { const j = jsonOf(r); if (j?.externalId) (c.state.orders ||= new Set()).add(j.externalId); } };
/** fn — каждому состоянию нашего заказа: GET статус, ответ отмены, элементы пакета, элементы /changes (если changes). */
function eachOrderState(c, r, fn, { changes = false, single = true, batch = true, cancel = true } = {}) {
  if (!ok2(r)) return null;
  const ours = c.state.orders || new Set();
  if ((single && is(c, 'GET', ORDER_ST)) || (cancel && is(c, 'POST', ORDER_CANCEL))) return mutateJson(r, (j) => { if (ours.has(j.externalId)) fn(j); });
  if (batch && is(c, 'POST', ORDER_BATCH)) return mutateJson(r, (j) => { for (const it of j.items || []) if (ours.has(it.externalId)) fn(it); });
  if (changes && is(c, 'GET', CHANGES)) return mutateJson(r, (j) => { for (const it of j.items || []) if (it.type === 'Document_ЗаказКлиента' && ours.has(it.externalId)) fn(it); });
  return null;
}

/**
 * Прогон против фасада с дефектом: запись с подтверждением; перерегистрация — «д» (клиент и товар для K8 и CK4 — из
 * полной выгрузки), пробный QR — «д» (qr: true); ручные шаги после записи — «нет ввода» (ПРОПУЩЕНО).
 */
function runWith(defect, { qr = true } = {}) {
  return limit(async () => {
    const { front, password, clientKey } = await frontWithSecrets({ defect });
    closers.push(() => front.close());
    const dir = tmpDir(`oc-o2-${defect.id}-`);
    dirs.push(dir);
    const cfg = makeConfig(dir, { baseUrl: front.baseUrl, password, clientKey });
    const r = await runInteractive(['--config', cfg, '--allow-http', '--allow-write'], [
      [/введите имя публикации/, front.publication],
      [/Выполнить перерегистрацию[^\n]*: /, 'д'],
      ...(qr ? [[/Создать пробный QR[^\n]*: /, 'д']] : []),
    ], { timeoutMs: 240000 });
    const p = readProtocol(path.join(dir, 'protokoly'));
    assert.ok(p, `нет протокола: ${r.out.slice(-1500)}`);
    assert.deepEqual(leaks([r.out, ...p.texts], secretForms(password, clientKey)), [], 'секрет в выводе');
    return { ...r, p, journal: front.journal, inner: front.inner };
  });
}

function expectFinding(r, id, verdict, code, fragment = null) {
  const c = check(r.p, id);
  assert.ok(c, `нет проверки ${id}`);
  assert.equal(c.verdict, verdict, `${id}: ${c.verdict} — ${checkTexts(c)}`);
  const f = c.findings.find((x) => x.code === code && (!fragment || fragment.test(x.text)));
  assert.ok(f, `${id}: нет находки ${code}${fragment ? ` ${fragment}` : ''}; есть: ${codes(c).join(', ')} — ${checkTexts(c).slice(0, 600)}`);
  return f;
}
const noFail = (r) => {
  const bad = r.p.json.checks.filter((c) => c.verdict === 'FAIL').map((c) => `${c.id}: ${checkTexts(c).slice(0, 300)}`);
  assert.deepEqual(bad, []);
  assert.equal(r.code, 0, r.out.slice(-1500));
};

// ---------------------------------------------------------------- X4: отмена пометкой удаления (G17)

test('верно (G17): отмена пометкой удаления везде одинаково, /external-ids отдаёт заказ с deletionMark: true — X4, X5, O6, O7, C14 без ОШИБКИ, код 0', async () => {
  const r = await runWith({
    id: 'G17',
    after: (c, res) => {
      noteOrder(c, res);
      const cx = (c.state.cx ||= new Set());
      if (is(c, 'POST', ORDER_CANCEL) && res.status === 200 && (c.state.orders || new Set()).has(seg4(c))) cx.add(seg4(c));
      if (is(c, 'GET', XID) && res.status === 200) return mutateJson(res, (j) => { for (const it of j.items || []) if (cx.has(it.externalId)) it.deletionMark = true; });
      return eachOrderState(c, res, (j) => { if (cx.has(j.externalId)) { j.status = 'НеСогласован'; j.approved = false; j.fulfillmentState = null; j.deletionMark = true; } }, { changes: true });
    },
  }, { qr: false });
  for (const id of ['O6', 'O7', 'C14', 'X4', 'X5']) assert.equal(check(r.p, id).verdict, 'PASS', `${id}: ${checkTexts(check(r.p, id))}`);
  noFail(r);
});

test('X4: заказ отменён пометкой удаления (O6: deletionMark = true), а /external-ids отдаёт deletionMark = false — X4 ОШИБКА', async () => {
  const r = await runWith({
    id: 'G17NEG',
    after: (c, res) => {
      noteOrder(c, res);
      const cx = (c.state.cx ||= new Set());
      if (is(c, 'POST', ORDER_CANCEL) && res.status === 200 && (c.state.orders || new Set()).has(seg4(c))) cx.add(seg4(c));
      return eachOrderState(c, res, (j) => { if (cx.has(j.externalId)) { j.status = 'НеСогласован'; j.approved = false; j.deletionMark = true; } }, { changes: true });
    },
  }, { qr: false });
  expectFinding(r, 'X4', 'FAIL', 'deleted', /deletionMark = false, а заказ отменён пометкой удаления \(O6: deletionMark = true\).*§6\.20/);
  assert.equal(r.code, 1);
});

// ---------------------------------------------------------------- O5, O6: наш заказ и в items, и в notFound (N08)

test('N08: пакетный статус — наш найденный заказ и в items, и в notFound — O5 и O6 ОШИБКА «и в items, и в notFound»', async () => {
  const r = await runWith({
    id: 'N08',
    after: (c, res) => (is(c, 'POST', ORDER_BATCH) && res.status === 200 ? mutateJson(res, (j) => {
      for (const it of j.items || []) if (!j.notFound.includes(it.externalId)) j.notFound.push(it.externalId);
    }) : null),
  }, { qr: false });
  expectFinding(r, 'O5', 'FAIL', 'both', /пакетный статус: наш заказ [0-9a-f-]{36} и в items, и в notFound — .*§6\.9.*«документ в 1С не найден»/);
  expectFinding(r, 'O6', 'FAIL', 'both', /пакетный статус после отмены: наш заказ [0-9a-f-]{36} и в items, и в notFound/);
  assert.equal(r.code, 1);
});

test('O5: наш заказ только в notFound (документ есть) — O5 ОШИБКА «в notFound, а документ в 1С есть»', async () => {
  const r = await runWith({
    id: 'N08B',
    after: (c, res) => {
      noteOrder(c, res);
      if (!(is(c, 'POST', ORDER_BATCH) && res.status === 200)) return null;
      const ours = c.state.orders || new Set();
      return mutateJson(res, (j) => { for (const it of j.items || []) if (ours.has(it.externalId)) j.notFound.push(it.externalId); j.items = (j.items || []).filter((it) => !ours.has(it.externalId)); });
    },
  }, { qr: false });
  expectFinding(r, 'O5', 'FAIL', 'ours-not-found', /наш заказ [0-9a-f-]{36} в notFound, а документ в 1С есть/);
  assert.equal(r.code, 1);
});

// ---------------------------------------------------------------- K8, CK4: снимок долга (N16)

test('N16: snapshotAt долга на 3 ч 10 мин раньше запроса в K8 и в блоке receivables /check — K8 и CK4 ОШИБКА «снимок не на момент расчёта»', async () => {
  const old = () => isoBishkek(new Date(Date.now() - (3 * 3600 + 600) * 1000));
  const r = await runWith({
    id: 'N16',
    after: (c, res) => {
      if (is(c, 'GET', RECV) && res.status === 200) return mutateJson(res, (j) => { j.snapshotAt = old(); });
      if (is(c, 'POST', CHECK) && res.status === 200) return mutateJson(res, (j) => { if (j.receivables) j.receivables.snapshotAt = old(); });
      return null;
    },
  }, { qr: false });
  expectFinding(r, 'K8', 'FAIL', 'snapshot-old', /долг клиента: snapshotAt .* — на 3 ч 1\d мин раньше момента запроса: .*текущее время сервера 1С на момент расчёта.*§6\.12.*старше 60 минут — POS откажет в продаже в долг/);
  expectFinding(r, 'CK4', 'FAIL', 'snapshot-old', /блок receivables: snapshotAt .* — на 3 ч 1\d мин раньше момента запроса/);
  assert.equal(r.code, 1);
});

test('CK4: блок receivables /check нарушает правила приёма POS (overdueAmount > balance, creditLimit < 0) и рассчитан не на checkedAt — CK4 ОШИБКА', async () => {
  const r = await runWith({
    id: 'CK4REJ',
    after: (c, res) => (is(c, 'POST', CHECK) && res.status === 200 ? mutateJson(res, (j) => {
      if (j.receivables) { j.receivables.overdueAmount = '99999.00'; j.receivables.creditLimit = '-1.00'; }
    }) : null),
  }, { qr: false });
  expectFinding(r, 'CK4', 'FAIL', 'reject', /POS не применит блок receivables: overdueAmount 99999\.00 вне 0…max\(balance, 0\)/);
  expectFinding(r, 'CK4', 'FAIL', 'reject', /POS не применит блок receivables: creditLimit -1\.00 < 0/);
  const r2 = await runWith({
    id: 'CK4AT',
    after: (c, res) => (is(c, 'POST', CHECK) && res.status === 200 ? mutateJson(res, (j) => {
      if (j.receivables) {
        j.checkedAt = isoBishkek(new Date(Date.now() + 4 * 60000));
        j.receivables.snapshotAt = isoBishkek(new Date(Date.now() - 4 * 60000));
      }
    }) : null),
  }, { qr: false });
  expectFinding(r2, 'CK4', 'FAIL', 'snapshot-checked-at', /snapshotAt .*, а checkedAt ответа .* — расходятся больше чем на 5 минут.*§6\.5/);
  assert.equal(r.code, 1);
});

// ---------------------------------------------------------------- O4–O7: тот же заказ (N06, N07)

test('N06: статус, пакет и отмена отдают номер «9» (НомерНаПечать), создание — «ЗК00-000…» — O4, O5, O6, O7 ОШИБКА «number»', async () => {
  const printNo = (n) => String(n).replace(/^.*-0*/, '');
  const r = await runWith({
    id: 'N06',
    after: (c, res) => { noteOrder(c, res); return eachOrderState(c, res, (j) => { j.number = printNo(j.number); }); },
  }, { qr: false });
  for (const id of ['O4', 'O5', 'O7']) expectFinding(r, id, 'FAIL', 'number', /number «\d+», а при создании \(O1\) «ЗК00-\d+» — номер документа один во всех ответах.*НомерНаПечать.*§6\.8.*§6\.20/);
  for (const w of ['отмена', 'статус после отмены', 'пакетный статус после отмены']) {
    expectFinding(r, 'O6', 'FAIL', 'number', new RegExp(`^${w}: number «\\d+», а при создании`));
  }
  assert.equal(r.code, 1);
});

test('N07: статус и пакет отдают externalId = ref документа — O4 и O5 ОШИБКА «externalId»', async () => {
  const r = await runWith({
    id: 'N07',
    after: (c, res) => { noteOrder(c, res); return eachOrderState(c, res, (j) => { j.externalId = j.ref; }, { cancel: false }); },
  }, { qr: false });
  expectFinding(r, 'O4', 'FAIL', 'external-id', /статус: externalId «[0-9a-f-]{36}», а запрошен [0-9a-f-]{36} — это ссылка документа \(ref\), а не externalId.*§6\.8/);
  expectFinding(r, 'O5', 'FAIL', 'external-id', /пакетный статус: наш заказ \(ref [0-9a-f-]{36}\) в items с externalId «[0-9a-f-]{36}» вместо/);
  assert.equal(r.code, 1);
});

test('O4: статус отдаёт другую дату документа — O4 ОШИБКА «date»', async () => {
  const r = await runWith({
    id: 'O4DATE',
    after: (c, res) => { noteOrder(c, res); return eachOrderState(c, res, (j) => { j.date = '2026-01-01T00:00:00+06:00'; }, { batch: false, cancel: false }); },
  }, { qr: false });
  expectFinding(r, 'O4', 'FAIL', 'date', /статус: date «2026-01-01T00:00:00\+06:00», а при создании \(O1\) «.*» — дата того же документа/);
  assert.equal(r.code, 1);
});

// ---------------------------------------------------------------- X5: порядок /external-ids (N21)

test('N21: /external-ids по возрастанию ДатаСоздания (старые первыми) — X5 ОШИБКА «первыми идут старые записи», второй запрос КП-19 сделан', async () => {
  const r = await runWith({
    id: 'N21',
    after: (c, res) => (is(c, 'GET', XID) && res.status === 200 ? mutateJson(res, (j) => { j.items = (j.items || []).slice().reverse(); }) : null),
  }, { qr: false });
  const asked = r.journal.filter((j) => j.path === '/pos/v1/external-ids' && /type=%D0%97%D0%B0%D0%BA%D0%B0%D0%B7/.test(j.query) && /limit=500/.test(j.query) && !/since=/.test(j.query));
  assert.equal(asked.length, 1, JSON.stringify(r.journal.filter((j) => j.path === '/pos/v1/external-ids').map((j) => j.query)));
  expectFinding(r, 'X5', 'FAIL', 'order', /первыми идут старые записи: на позиции 1 — заказ «ОС00-004512» от «2026-10-21T13:40:00\+06:00», а заказ этого прогона O\d \(«ЗК00-\d+»\) — только на позиции \d+: порядок выдачи — по убыванию ДатаСоздания.*КП-19/);
  assert.equal(r.code, 1);
});

test('верно: перед заказами прогона в /external-ids — заказ, созданный в 1С во время проверки (новее начала) — X5 ПРОЙДЕНО', async () => {
  const r = await runWith({
    id: 'X5NEW',
    after: (c, res) => (is(c, 'GET', XID) && res.status === 200 && c.query.get('type') === 'Заказ' ? mutateJson(res, (j) => {
      j.items.unshift({ externalId: crypto.randomUUID(), objectType: 'Заказ', ref: crypto.randomUUID(), number: 'ЗК00-777777', date: isoBishkek(), deletionMark: false });
    }) : null),
  }, { qr: false });
  for (const id of ['X4', 'X5']) assert.equal(check(r.p, id).verdict, 'PASS', `${id}: ${checkTexts(check(r.p, id))}`);
  assert.match(check(r.p, 'X5').summary, /заказы прогона \(2 из 2\) — первыми на странице/);
  noFail(r);
});

// ---------------------------------------------------------------- E5, K8, Q: пустые значения 1С (N01, N02)

test('N02: documents[].dueDate = 0001-01-01 (пустая дата 1С вместо null) — E5 и K8 ОШИБКА', async () => {
  const r = await runWith({
    id: 'N02',
    after: (c, res) => (is(c, 'GET', RECV) && res.status === 200 ? mutateJson(res, (j) => { for (const d of j.documents || []) d.dueDate = EMPTY_DATE; }) : null),
  }, { qr: false });
  expectFinding(r, 'K8', 'FAIL', 'due-empty', /documents\[0\]\.dueDate "0001-01-01T00:00:00\+06:00" — пустая дата 1С вместо null: POS сочтёт срок наступившим и покажет документ «к оплате».*§6\.12/);
  expectFinding(r, 'E5', 'FAIL', 'date-empty', /dueDate: пустая дата 1С «0001-01-01T00:00:00\+06:00» вместо null — если даты нет, передайте null/);
  assert.equal(r.code, 1);
});

test('N01: QR без оплаты — статус и отмена отдают paidAmount "0.00", paidAt 0001-01-01, bankReference "" — Q3–Q6, Q8 и E5 ОШИБКА', async () => {
  const r = await runWith({
    id: 'N01',
    after: (c, res) => {
      if (!ok2(res) || !(is(c, 'GET', QR_ST) || is(c, 'POST', QR_CANCEL))) return null;
      return mutateJson(res, (j) => {
        if (j.status === 'paid') return;
        j.paidAmount = '0.00'; j.paidAt = EMPTY_DATE; j.bankReference = ''; j.documentRef = NIL;
        if (is(c, 'GET', QR_ST)) j.documentType = '';
      });
    },
  });
  expectFinding(r, 'Q3', 'FAIL', 'unpaid-not-null', /статус: статус pending, а paidAmount «0\.00», paidAt «0001-01-01T00:00:00\+06:00», bankReference «», documentType «» — оплаты не было, эти поля null.*§6\.15/);
  for (const id of ['Q4', 'Q5']) expectFinding(r, id, 'FAIL', 'unpaid-not-null', /статус cancelled, а paidAmount «0\.00», paidAt «0001-01-01T00:00:00\+06:00», bankReference «»/);
  for (const id of ['Q6', 'Q8']) expectFinding(r, id, 'FAIL', 'unpaid-not-null', /статус cancelled, а paidAmount «0\.00»/);
  expectFinding(r, 'E5', 'FAIL', 'date-empty', /paidAt: пустая дата 1С «0001-01-01T00:00:00\+06:00» вместо null/);
  assert.equal(r.code, 1);
});

// ---------------------------------------------------------------- E5: правило пустой даты (модуль)

test('E5: пустая дата 1С — в поле с null «передайте null», в обязательном — «нужна настоящая дата»; 1900 год и позже — без находки', () => {
  const c = loadContract(path.resolve(SAMPLES, '..', '..', '..', 'src'));
  const v = new Validator(c);
  const S = (n) => ({ $ref: `#/components/schemas/${n}` });
  const doc = { documentRef: 'c3d4e5f6-0000-4000-8000-000000000101', documentType: 'Document_РеализацияТоваровУслуг', number: 'РТ-1', date: EMPTY_DATE, amount: '1.00', paid: '0.00', remaining: '1.00', dueDate: '1899-12-31T00:00:00+06:00', overdueDays: 0 };
  const recv = { customerRef: 'c3d4e5f6-0000-4000-8000-000000000001', snapshotAt: '2026-10-21T13:39:05+06:00', balance: '1.00', overdueAmount: '0.00', overdueDays: 0, creditAllowed: true, creditLimit: null, creditDays: null, creditAvailable: null, documents: [doc] };
  const e = v.validate(recv, S('CustomerReceivables')).errors.filter((x) => x.code === 'date-empty');
  assert.deepEqual(e.map((x) => `${x.rule} ${x.severity} ${x.path}`), ['E5 FAIL documents[0].date', 'E5 FAIL documents[0].dueDate']);
  assert.match(e[0].text, /documents\[0\]\.date: пустая дата 1С «0001-01-01T00:00:00\+06:00» — поле обязательно и null не допускает: нужна настоящая дата/);
  assert.match(e[1].text, /documents\[0\]\.dueDate: пустая дата 1С «1899-12-31T00:00:00\+06:00» вместо null — если даты нет, передайте null/);
  assert.match(e[0].hint, /ЗначениеЗаполнено/);
  const ok = v.validate({ ...recv, documents: [{ ...doc, date: '1900-01-01T00:00:00+06:00', dueDate: null }] }, S('CustomerReceivables')).errors.filter((x) => x.severity === 'FAIL');
  assert.deepEqual(ok, []);
});
