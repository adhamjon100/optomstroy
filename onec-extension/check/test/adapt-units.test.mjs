// Онлайн-адаптация (20.11.2026): модульные проверки правил, добавленных после охоты на дефекты (раунд 3), и того, что
// в программе не осталось материала отозванного задания «ночной обмен» (ТЗ 2.3) и черновика 1.3.0. Каждый тест на
// сборке до исправлений падал (журнал — .tmp/onec-check/online-adapt.md).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { CATALOG } from '../src/checks/index.mjs';
import { loadContract } from '../src/contract.mjs';
import * as schema from '../src/schema.mjs';
import { readPages } from '../src/paging.mjs';
import * as rules from '../src/rules.mjs';
import * as payments from '../src/checks/payments.mjs';

// Пространства имён, а не именованный импорт: на сборке до исправлений нового экспорта нет, и падает только тест,
// который им пользуется, а не весь файл.
const { Validator } = schema;
const { crossRules, parseExchange } = rules;
const calendarError = (...a) => schema.calendarError(...a);
const loneSurrogates = (...a) => rules.loneSurrogates(...a);
const doubleEncoded = (...a) => rules.doubleEncoded(...a);
const documentTypeForKind = (...a) => payments.documentTypeForKind(...a);
import { Masker } from '../src/mask.mjs';
import { CHECK_DIR } from './helpers/env.mjs';

const contract = loadContract(path.join(CHECK_DIR, 'src'));
const validator = new Validator(contract);
const errs = (v, name) => validator.validate(v, { $ref: `#/components/schemas/${name}` }).errors;
const REPO = path.resolve(CHECK_DIR, '..', '..');

test('Z06: дата по шаблону контракта, но не по календарю (30.02, 31.11, 29.02 невисокосного года, 24:00) — E5 ОШИБКА', () => {
  assert.match(calendarError('2026-02-30T10:00:00+06:00'), /30\.02\.2026 — такой даты нет в календаре \(в этом месяце 28 дн\.\)/);
  assert.match(calendarError('2026-11-31T12:00:00+06:00'), /31\.11\.2026 — такой даты нет/);
  assert.match(calendarError('2026-02-29T00:00:00+06:00'), /такой даты нет/);
  assert.equal(calendarError('2028-02-29T00:00:00+06:00'), null, 'високосный год');
  assert.match(calendarError('2026-13-01T00:00:00+06:00'), /месяца 13 нет/);
  assert.match(calendarError('2026-11-20T24:00:00+06:00'), /час 24/);
  assert.match(calendarError('2026-11-20T10:61:00+06:00'), /минута 61/);
  assert.equal(calendarError('2026-11-20T23:59:59+06:00'), null);
  assert.equal(calendarError('2026-11-20'), null, 'дата без времени (DiscountChange.validFrom)');
  const health = (serverTime) => errs({ apiVersion: '1', extensionVersion: '1.0.0', platform: '8.3.25.1000', configuration: 'УТ', configurationVersion: '11.5', exchangeNode: 'POS', registrationBacklog: 0, lastAckMessageNumber: 0, serverTime, status: 'ok' }, 'Health')
    .filter((e) => e.rule === 'E5');
  assert.deepEqual(health('2026-02-30T10:00:00+06:00').map((e) => `${e.severity} ${e.code}`), ['FAIL date-calendar']);
  assert.deepEqual(health('2026-11-20T10:00:00+06:00'), []);
});

test('Z49: пустой GUID в ref объекта — E4 ОШИБКА; в прочих …Ref — ЗАМЕЧАНИЕ «передайте null»', () => {
  const cand = (ref, contractorRef) => errs({ ref, contractorRef, code: '00000001', name: 'x', phone: '+996700000001', deletionMark: false }, 'CustomerCandidate')
    .filter((e) => e.rule === 'E4');
  assert.deepEqual(cand('00000000-0000-0000-0000-000000000000', null).map((e) => `${e.severity} ${e.code}`), ['FAIL guid-nil']);
  assert.deepEqual(cand('c3d4e5f6-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000').map((e) => `${e.severity} ${e.code}`), ['WARN guid-nil-ref']);
  assert.deepEqual(cand('c3d4e5f6-0000-4000-8000-000000000002', null), []);
});

test('Z01, Z02: повтор на одной странице — ОШИБКА «дважды на странице»; тот же externalId с другим ref — «два объекта 1С»', async () => {
  const run = async (pages, conflictOf = null) => {
    const found = [];
    await readPages({
      maxPages: 10, limit: 10, keyOf: (i) => i.k, conflictOf, report: (f) => found.push(f), labels: { item: 'элемент' },
      fetchPage: async (cursor) => { const i = cursor ? Number(cursor) : 0; return { ex: { status: 200, ms: 1 }, body: pages[i] }; },
    });
    return found;
  };
  const f1 = await run([{ items: [{ k: 'a' }, { k: 'a' }], hasMore: false, cursor: null }]);
  assert.deepEqual(f1.map((f) => `${f.severity} ${f.code}`), ['FAIL dup-in-page']);
  assert.match(f1[0].text, /элемент дважды на странице 1 \(a\) — одна запись выдана два раза/);
  const conflict = (a, b) => (a.ref !== b.ref ? 'один externalId — два объекта 1С' : null);
  const f2 = await run([{ items: [{ k: 'x', ref: 'r1' }], hasMore: true, cursor: '1' }, { items: [{ k: 'x', ref: 'r2' }], hasMore: false, cursor: null }], conflict);
  assert.deepEqual(f2.map((f) => `${f.severity} ${f.code}`), ['FAIL dup-conflict']);
  assert.match(f2[0].text, /один externalId — два объекта 1С \(x, страницы 1 и 2\)/);
});

test('Z16, Z04: одиночный суррогат в строке — E3 ЗАМЕЧАНИЕ; JSON, закодированный дважды, — E3 ОШИБКА', () => {
  assert.deepEqual(loneSurrogates({ items: [{ description: 'Смеситель \ud83d' }, { description: 'ок 😀' }] }), ['items[0].description']);
  assert.equal(doubleEncoded(JSON.stringify({ apiVersion: '1' })), true);
  assert.equal(doubleEncoded('строка'), false);
  const RID = 'a1b2c3d4-0000-4000-8000-0000000000a9';
  const mk = (bodyText) => parseExchange({ status: 200, method: 'GET', requestId: RID, timeoutMs: 30000, ms: 5, headers: { 'x-request-id': RID, 'x-pos-api-version': '1', 'content-type': 'application/json; charset=utf-8' }, body: Buffer.from(bodyText, 'utf8') });
  const run = (ex) => crossRules(ex, contract.op('GET /pos/v1/health'), {}, { masker: new Masker(), errorCodes: contract.errorCodes }).filter((f) => f.rule === 'E3').map((f) => `${f.severity} ${f.code}`);
  assert.deepEqual(run(mk(JSON.stringify(JSON.stringify({ apiVersion: '1' })))), ['FAIL double-json']);
  assert.deepEqual(run(mk('{"status":"ok \\ud83d"}')), ['WARN lone-surrogate']);
  assert.deepEqual(run(mk('{"status":"ok"}')), []);
});

test('Z75: вид документа по способу оплаты — наличные безналичным документом — ОШИБКА; непривычное имя ПКО — ЗАМЕЧАНИЕ', () => {
  const rec = () => { const f = []; return { f, fail: (t, o) => f.push(`FAIL ${o.code}`), warn: (t, o) => f.push(`WARN ${o.code}`) }; };
  const a = rec(); documentTypeForKind(a, 'cash', 'Document_ПоступлениеБезналичныхДенежныхСредств'); assert.deepEqual(a.f, ['FAIL doc-kind']);
  const b = rec(); documentTypeForKind(b, 'cash', 'Document_ПриходныйКассовыйОрдер'); assert.deepEqual(b.f, []);
  const c = rec(); documentTypeForKind(c, 'cash', 'Document_POS_Оплата'); assert.deepEqual(c.f, ['WARN doc-kind-name']);
  const d = rec(); documentTypeForKind(d, 'qr_bakai', 'Document_ПриходныйКассовыйОрдер'); assert.deepEqual(d.f, ['FAIL doc-kind']);
  const e = rec(); documentTypeForKind(e, 'qr_bakai', 'Document_ОперацияПоПлатежнойКарте'); assert.deepEqual(e.f, []);
});

test('каталог онлайн-обмена: нет проб и проверок «ждут 1.3.0», у каждой проверки источник — контракт, Требования, КП или AC', () => {
  const groups = new Set(CATALOG.map((d) => d.group));
  assert.ok(!groups.has('N') && !groups.has('T'), [...groups].join(','));
  for (const d of CATALOG) {
    assert.ok(!('tz' in d.sources) && !('tz8' in d.sources), `${d.id}: ссылка на ТЗ 2.3`);
    const n = ['contract', 'ref', 'kp', 'ac'].reduce((a, k) => a + (d.sources[k]?.length || 0), 0);
    assert.ok(n > 0, `${d.id}: нет источника правила`);
  }
  // Обязательные методы онлайн-обмена (x-priority: must) — в полноте прогона; QR, карточка и /external-ids — нет.
  for (const id of ['O1', 'O4', 'O6', 'R1', 'CK1', 'CK4', 'K7', 'K8', 'I1']) assert.equal(CATALOG.find((d) => d.id === id).optional, false, id);
  for (const id of ['Q1', 'CC1', 'X1']) assert.equal(CATALOG.find((d) => d.id === id).optional, true, id);
});

test('в программе нет материала отозванного задания «ночной обмен» и черновика 1.3.0', () => {
  const files = [];
  const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else files.push(p); } };
  walk(path.join(CHECK_DIR, 'src'));
  walk(path.join(CHECK_DIR, 'contract'));
  for (const f of ['chitai_menya.txt', 'nastrojki.primer.json', 'Proverka_API_1C.cmd', 'Proverka_API_1C_zapis.cmd']) files.push(path.join(CHECK_DIR, 'release', f));
  const HISTORY_LINE = 'проверки ночного обмена убраны: ТЗ 2.3 отозвано 20.11.2026';
  const bad = /ТЗ\s*2\.3|ночн\S*\s+обмен|(?<![\d.])1\.3\.0(?![\d.])|\/pos\/v1\/(?:prices|stock|receivables|sales|sale-returns|advance-refunds|stock-documents)(?![\w/{-])|tz23|PENDING_13/i;
  const hits = [];
  for (const f of files) {
    const t = fs.readFileSync(f, 'utf8').split(HISTORY_LINE).join(' ');
    const m = bad.exec(t);
    if (m) hits.push(`${path.relative(CHECK_DIR, f)}: ${m[0]}`);
  }
  assert.deepEqual(hits, []);
  assert.ok(!fs.existsSync(path.join(CHECK_DIR, 'contract', 'tz23-general-rules.json')));
});

test('запускатели очищают NODE_EXTRA_CA_CERTS компьютера (как NODE_OPTIONS и NODE_TLS_REJECT_UNAUTHORIZED)', () => {
  for (const f of ['Proverka_API_1C.cmd', 'Proverka_API_1C_zapis.cmd']) {
    const t = fs.readFileSync(path.join(CHECK_DIR, 'release', f), 'latin1');
    assert.match(t, /^set "NODE_EXTRA_CA_CERTS="\r$/m, f);
    assert.ok(t.indexOf('NODE_EXTRA_CA_CERTS') < t.indexOf('runtime\\node.exe" --use-system-ca'), `${f}: очистка до запуска node.exe`);
  }
});

test('сноска о LICENSE называет настоящий источник: LICENSE рядом с тем же node.exe v24.11.1 (Playwright для Go 1.57.0), не v24.13.0', () => {
  for (const f of [path.join(REPO, 'docs', 'integration', 'ONEC_CHECK_TOOL.md'), path.join(CHECK_DIR, 'README.md')]) {
    const t = fs.readFileSync(f, 'utf8');
    assert.ok(!/v24\.13\.0/.test(t), `${path.basename(f)}: упоминает v24.13.0`);
    assert.match(t, /ms-playwright-go\/1\.57\.0/, `${path.basename(f)}: нет настоящего источника LICENSE`);
    assert.match(t, /b4c7840e/, `${path.basename(f)}: нет sha256 LICENSE`);
  }
});
