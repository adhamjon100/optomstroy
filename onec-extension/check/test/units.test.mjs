// Модульные: маскирование, вычистка секретов, файлы секретов, настройки, флаги, постраничное чтение, пробы, правила E.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { Masker, Redactor, maskPhone, maskQueryPhone } from '../src/mask.mjs';
import { readSecretFile } from '../src/secrets.mjs';
import { loadSettings, saveSettings } from '../src/settings.mjs';
import { parseCli } from '../src/cli.mjs';
import { parseBaseUrl, HttpClient } from '../src/http.mjs';
import { RunContext, transientReason } from '../src/context.mjs';
import { unstableRefs, naturalKey } from '../src/checks/changes.mjs';
import { Registry } from '../src/registry.mjs';
import { loadContract } from '../src/contract.mjs';
import { CHECK_DIR } from './helpers/env.mjs';
import { resolveSelection } from '../src/checks/index.mjs';
import { readPages } from '../src/paging.mjs';
import { parseExchange, crossRules } from '../src/rules.mjs';
import { tmpDir } from './helpers/env.mjs';


test('маска: телефоны во всех видах, ИНН, e-mail, GUID и даты не трогаются', () => {
  const m = new Masker();
  const s = m.maskText('тел +996700123456, 0700 123 456, +996 (555) 12-34-56; ИНН 12345678901234; a.b@primer.kg; ref a1b2c3d4-0000-4000-8000-000000000001 от 2026-10-21T14:05:00+06:00, сумма 16007.50, код 00004521');
  assert.ok(!/700123456|12345678901234|primer\.kg|123 456|12-34-56/.test(s), s);
  assert.match(s, /\+996 \*\*\* \*\* 56/);
  assert.match(s, /\[ИНН скрыт\]/);
  assert.match(s, /\[e-mail скрыт\]/);
  assert.match(s, /a1b2c3d4-0000-4000-8000-000000000001/);
  assert.match(s, /2026-10-21T14:05:00\+06:00/);
  assert.match(s, /16007\.50/);
  assert.match(s, /00004521/);
  assert.equal(maskPhone('+996700000034'), '+996 *** ** 34');
  assert.equal(maskQueryPhone('/pos/v1/customers?phone=%2B996700000001'), '/pos/v1/customers?phone=[+996 *** ** 01]');
});

test('маска по схеме: партнёр, кандидат, запрос клиента, свободный текст; «ПРОВЕРКА POS» и товары не скрываются', () => {
  const m = new Masker();
  const j = m.maskJson({
    items: [
      { type: 'Catalog_Партнеры', description: 'ООО Вымысел', fullName: 'Иванов Вымышленный', phones: [{ phone: '+996700000099', presentation: '0700 000 099' }] },
      { type: 'Catalog_Номенклатура', description: 'Смеситель для кухни' },
      { type: 'Document_РеализацияТоваровУслуг', comment: 'POS 0192f5a0-7c2e-7d3b-9a1f-3c4d5e6f7a8b · POS-2026-000123 · позвонить Иванову' },
    ],
    candidates: [{ ref: 'a1b2c3d4-0000-4000-8000-000000000001', name: 'Петров Вымышленный', phone: '+996700000098' }],
    request: { externalId: 'x', name: 'ПРОВЕРКА POS клиент 120000 (удалить)', phone: '+996000123456', dedupe: {} },
  });
  const s = JSON.stringify(j);
  for (const bad of ['ООО Вымысел', 'Иванов Вымышленный', '700000099', '0700 000 099', 'Петров Вымышленный', 'позвонить']) assert.ok(!s.includes(bad), bad);
  assert.ok(s.includes('Смеситель для кухни'));
  assert.ok(s.includes('ПРОВЕРКА POS клиент'));
  assert.ok(s.includes('POS-2026-000123'));
  assert.equal(m.maskText('Клиент ООО Вымысел уже есть'), 'Клиент [имя скрыто] уже есть');
  const u = JSON.stringify(m.maskJson({ type: 'x', note: 'какой-то текст', code: 'КОД 1' }, { mode: 'unknown' }));
  assert.ok(!u.includes('какой-то текст') && u.includes('КОД 1'));
});

test('вычистка секретов: пароль, ключ, base64(user:password), URL-кодирование, заголовки', () => {
  const r = new Redactor();
  r.add('Vymysel Parol/1');
  r.addBasic('pos_hs', 'Vymysel Parol/1');
  r.add('kluch-xyz-123');
  const b64 = Buffer.from('pos_hs:Vymysel Parol/1').toString('base64');
  // Заголовки — отдельными строками, как в дампе запроса (свободный текст «без заголовка X-POS-Client-Key — …» не трогается).
  const s = r.redact(`p=Vymysel Parol/1 u=${encodeURIComponent('Vymysel Parol/1')} b=${b64} k=kluch-xyz-123 Authorization: Basic QUJD\nX-POS-Client-Key: abc`);
  assert.ok(!s.includes('Vymysel') && !s.includes(b64) && !s.includes('kluch') && !s.includes('QUJD') && !s.includes(': abc'), s);
});

test('файлы секретов: BOM, UTF-16, CRLF; две строки — ошибка настроек', () => {
  const d = tmpDir('oc-sec-');
  try {
    fs.writeFileSync(path.join(d, 'a.txt'), Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from('Parol1\r\n')]));
    assert.equal(readSecretFile(path.join(d, 'a.txt'), 'пароля'), 'Parol1');
    fs.writeFileSync(path.join(d, 'b.txt'), Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from('Ключ2\r\n', 'utf16le')]));
    assert.equal(readSecretFile(path.join(d, 'b.txt'), 'ключа'), 'Ключ2');
    fs.writeFileSync(path.join(d, 'c.txt'), 'x\ny\n');
    assert.throws(() => readSecretFile(path.join(d, 'c.txt'), 'пароля'), /больше одной строки/);
  } finally { fs.rmSync(d, { recursive: true, force: true }); }
});

test('настройки: BOM, неизвестный ключ — «возможно, опечатка», ключ-пароль — ошибка, сохранение без секретов', () => {
  const d = tmpDir('oc-set-');
  try {
    const f = path.join(d, 'n.json');
    fs.writeFileSync(f, '﻿' + JSON.stringify({ baseUrl: 'https://srv/ut_test/hs', baseURl: 'x', refs: { productRef: 'BAD' } }));
    const r = loadSettings(f);
    assert.ok(r.warnings.some((w) => /baseURl.*возможно, опечатка: «baseUrl»/.test(w)), r.warnings.join('; '));
    assert.ok(r.warnings.some((w) => /refs\.productRef/.test(w)));
    fs.writeFileSync(f, JSON.stringify({ baseUrl: 'https://srv/hs', password: 'x' }));
    assert.throws(() => loadSettings(f), /не пишутся/);
    const out = path.join(d, 'save.json');
    saveSettings(out, { baseUrl: 'https://srv/hs', user: 'pos_hs', password: 'NePopadet', clientKey: 'NePopadet2', token: 'NePopadet3' });
    const t = fs.readFileSync(out, 'utf8');
    assert.ok(!t.includes('NePopadet'));
  } finally { fs.rmSync(d, { recursive: true, force: true }); }
});

test('флаги и адрес: отказ от --password, неизвестный флаг, адрес …/pos/v1/health → …/hs, --checks с зависимостями', () => {
  assert.throws(() => parseCli(['--password=1']), /скрытым вводом или файлом/);
  assert.throws(() => parseCli(['--key', 'x']), /скрытым вводом или файлом/);
  assert.throws(() => parseCli(['--neizvestnyj']), /неизвестный флаг/);
  const b = parseBaseUrl('https://srv-1c.local/ut_test/hs/pos/v1/health');
  assert.equal(b.href, 'https://srv-1c.local/ut_test/hs');
  assert.equal(b.publication, 'ut_test');
  assert.ok(b.notes.length);
  assert.throws(() => parseBaseUrl('https://user:p@srv/hs'), /пользователь и пароль в адресе/);
  const s = resolveSelection(['C']);
  assert.ok(s.sel.has('C7') && s.sel.has('C2') && s.sel.has('S3') && s.sel.has('K1'), 'C14 тянет за собой K1');
  assert.ok(!resolveSelection(['A2']).sel.has('C2'));
  assert.ok(resolveSelection(['C14']).sel.has('K1'));
  assert.deepEqual(resolveSelection(['ZZ9']).unknown, ['ZZ9']);
});

async function pages(list, opts = {}) {
  const found = [];
  const res = await readPages({
    maxPages: opts.maxPages || 10, limit: 2, sameMessage: true, keyOf: (i) => i.k,
    report: (f) => found.push(f.text),
    fetchPage: async (cursor) => {
      const i = cursor ? Number(cursor) : 0;
      return { ex: { status: 200, ms: 1 }, body: list[Math.min(i, list.length - 1)] };
    },
  });
  return { res, found: found.join(' | ') };
}

test('постраничное чтение: hasMore без курсора, повтор курсора, повтор элемента, разный номер, предел страниц', async () => {
  assert.match((await pages([{ messageNumber: 1, hasMore: true, cursor: null, items: [] }])).found, /hasMore=true без cursor/);
  assert.match((await pages([{ messageNumber: 1, hasMore: true, cursor: '1', items: [{ k: 'a' }] }, { messageNumber: 1, hasMore: true, cursor: '1', items: [{ k: 'b' }] }])).found, /курсор повторился/);
  assert.match((await pages([{ messageNumber: 1, hasMore: true, cursor: '1', items: [{ k: 'a' }] }, { messageNumber: 1, hasMore: false, cursor: null, items: [{ k: 'a' }] }])).found, /повторяется на страницах/);
  assert.match((await pages([{ messageNumber: 1, hasMore: true, cursor: '1', items: [] }, { messageNumber: 2, hasMore: false, cursor: null, items: [] }])).found, /номер сообщения разный/);
  const many = Array.from({ length: 20 }, (_, i) => ({ messageNumber: 1, hasMore: true, cursor: String(i + 1), items: [{ k: 'x' + i }] }));
  assert.match((await pages(many, { maxPages: 3 })).found, /по пределу: 3 страниц/);
  assert.match((await pages([{ messageNumber: 1, hasMore: false, cursor: null, items: [{ k: 1 }, { k: 2 }, { k: 3 }] }])).found, /больше limit=2/);
});

test('правила E: код ↔ статус, requestId, русский текст, ПДн, BOM, charset', () => {
  const m = new Masker();
  const env = { masker: m, errorCodes: ['POS_E_BAD_REQUEST', 'POS_E_VALIDATION', 'POS_E_INTERNAL', 'POS_E_DUPLICATE'] };
  const mk = (status, body, headers = {}, extra = {}) => parseExchange({
    status, method: 'POST', requestId: 'a1b2c3d4-0000-4000-8000-000000000009', timeoutMs: 30000, ms: 10,
    headers: { 'content-type': 'application/json; charset=utf-8', 'x-request-id': 'a1b2c3d4-0000-4000-8000-000000000009', ...headers },
    body: Buffer.concat([extra.bom ? Buffer.from([0xef, 0xbb, 0xbf]) : Buffer.alloc(0), Buffer.from(JSON.stringify(body))]),
  });
  const rules = (ex, spec = {}) => crossRules(ex, null, spec, env).map((x) => `${x.rule} ${x.text}`).join('\n');
  assert.match(rules(mk(422, { code: 'POS_E_INTERNAL', message: 'Ошибка', requestId: 'a1b2c3d4-0000-4000-8000-000000000009' })), /E7 код не соответствует HTTP-статусу/);
  assert.match(rules(mk(400, { code: 'POS_E_BAD_REQUEST', message: 'Bad request', requestId: 'a1b2c3d4-0000-4000-8000-000000000001' })), /E2 requestId в теле ошибки не совпадает[\s\S]*E8 текст ошибки не по-русски/);
  assert.match(rules(mk(409, { code: 'POS_E_DUPLICATE', message: 'Есть клиент +996700000001', requestId: 'a1b2c3d4-0000-4000-8000-000000000009' })), /E9 в тексте ошибки телефон/);
  assert.match(rules(mk(200, { ok: true }, {}, { bom: true })), /E1 нет заголовка X-POS-API-Version[\s\S]*E3 тело начинается с BOM/);
  assert.match(rules(mk(200, { ok: true }, { 'content-type': 'application/json', 'x-pos-api-version': '1' })), /E3 в Content-Type нет charset/);
  assert.match(rules(mk(500, { code: 'POS_E_INTERNAL', message: 'Сбой', requestId: 'a1b2c3d4-0000-4000-8000-000000000009' }), { dataError: true }), /E11 ошибка данных отдана как 500/);
  assert.match(rules(mk(400, { error: 'x' })), /E7 тело ошибки не по формату/);
});

test('ключ с русскими буквами до HTTP-слоя: запрос не уходит, проверка останавливается с понятным текстом (код 2)', async () => {
  const http = new HttpClient({ base: parseBaseUrl('http://127.0.0.1:9/ut_test/hs'), auth: { scheme: 'basic', user: 'pos_hs', password: 'Vymysel-1' }, clientKey: 'Еуые-ключ' });
  await assert.rejects(http.request({ path: '/pos/v1/health' }), { code: 'ERR_INVALID_CHAR' });
  const contract = loadContract(path.join(CHECK_DIR, 'src'));
  const ctx = new RunContext({ contract, http, registry: new Registry(), masker: new Masker(), out: { verbose: false }, flags: {}, settings: {} });
  await assert.rejects(ctx.exchange(ctx.runObj('S3'), { op: 'GET /pos/v1/health', path: '/pos/v1/health' }), (e) => {
    assert.equal(e.code, 'ABORT');
    assert.equal(e.exitCode, 2);
    assert.match(e.reason, /недопустимые для заголовка символы/);
    assert.ok(!/Invalid character/.test(e.reason));
    return true;
  });
  http.close();
});

test('реестр: запрос создания — до отправки; 4xx — объект убран, нет ответа — «результат неизвестен», 2xx — создан', () => {
  const reg = new Registry();
  const a = reg.addPending({ kind: 'Клиент', externalId: '5e1f7e57-0000-4000-8000-00000000000a', checkId: 'K4' });
  reg.settlePending(a, 'rejected');
  assert.equal(reg.created.length, 0);
  const b = reg.addPending({ kind: 'Платеж', externalId: '5e1f7e57-0000-4000-8000-00000000000b', checkId: 'PAY1' });
  reg.settlePending(b, 'unknown');
  const c = reg.addPending({ kind: 'Клиент', externalId: '5e1f7e57-0000-4000-8000-00000000000c', checkId: 'K3' });
  for (let i = 0; i < 9; i++) reg.addPending({ kind: 'Клиент', externalId: '5e1f7e57-0000-4000-8000-00000000000c', checkId: 'K3' });
  for (let i = 0; i < 9; i++) reg.settlePending(c, 'rejected');
  reg.settlePending(c, 'created', { ref: 'a1b2c3d4-0000-4000-8000-0000000000cc' });
  reg.addPending({ kind: 'Заказ', externalId: '5e1f7e57-0000-4000-8000-00000000000d', checkId: 'O1' }); // Ctrl+C: ответа нет
  reg.finalizePending();
  const by = Object.fromEntries(reg.created.map((x) => [x.externalId.slice(-1), x]));
  assert.deepEqual(Object.keys(by).sort(), ['b', 'c', 'd']);
  assert.equal(by.b.unknown, true);
  assert.match(by.b.note, /результат неизвестен — найдите по externalId 5e1f7e57-/);
  assert.equal(by.c.unknown, false);
  assert.equal(by.c.ref, 'a1b2c3d4-0000-4000-8000-0000000000cc');
  assert.equal(by.d.unknown, true);
  for (const x of reg.created) for (const k of ['pending', 'inflight', 'everCreated', 'sawUnknown']) assert.ok(!(k in x), k);
});

test('fix2: C1 — тот же объект с другим ref во втором чтении (ключ: тип + код, штрихкод, номер документа…)', () => {
  const item = (type, ref, extra) => ({ type, ref, dataVersion: 'AAAAAQ==', deletionMark: false, ...extra });
  const g = (n) => `a1b2c3d4-0000-4000-8000-${String(n).padStart(12, '0')}`;
  const first = [
    item('Catalog_Номенклатура', g(1), { code: '00001234', description: 'Смеситель' }),
    item('Catalog_Номенклатура', g(2), { code: '00001235', description: 'Кран' }),
    item('Catalog_ХарактеристикиНоменклатуры', g(3), { code: '000000001', ownerRef: g(1) }),
    item('Catalog_ХарактеристикиНоменклатуры', g(4), { code: '000000001', ownerRef: g(2) }),
    { type: 'InformationRegister_ШтрихкодыНоменклатуры', ref: '4601234567890', barcode: '4601234567890', productRef: g(1) },
    item('Document_РеализацияТоваровУслуг', g(5), { number: 'РТ00-001790', date: '2026-10-10T11:20:00+06:00' }),
    item('Catalog_СоглашенияСКлиентами', g(6), { description: 'Оптовое соглашение' }),
    { type: 'ObjectDeletion', objectType: 'Catalog_Номенклатура', ref: g(7) },
  ];
  // Стабильные ссылки (и регистр букв GUID не важен) — расхождений нет.
  assert.deepEqual(unstableRefs(first, first.map((x) => ({ ...x }))).length, 0);
  assert.equal(unstableRefs(first, first.map((x) => ({ ...x, ref: String(x.ref).toUpperCase() }))).length, 0);
  // Новый УникальныйИдентификатор() у товаров при каждом чтении — оба товара найдены по коду.
  const second = first.map((x) => (x.type === 'Catalog_Номенклатура' ? { ...x, ref: g(100 + Number(x.ref.slice(-2))) } : { ...x }));
  const moved = unstableRefs(first, second);
  assert.equal(moved.length, 2);
  assert.ok(moved.paired >= 6, `сопоставлено ${moved.paired}`);
  assert.equal(moved[0].label, 'Catalog_Номенклатура код 00001234');
  // Объекта нет во втором чтении — это не «ссылка меняется».
  assert.equal(unstableRefs(first, second.filter((x) => x.type !== 'Catalog_Номенклатура')).length, 0);
  // Ключ, который в одном чтении встречается дважды, не сопоставляется.
  assert.equal(naturalKey({ type: 'ObjectDeletion', objectType: 'Catalog_Номенклатура', ref: g(7) }), null);
  const dup = [item('Catalog_Склады', g(8), { code: '1' }), item('Catalog_Склады', g(9), { code: '1' })];
  assert.equal(unstableRefs(dup, [item('Catalog_Склады', g(10), { code: '1' })]).length, 0);
});

test('fix2: повтор GET (x-get-retry контракта): временные ошибки — сеть, таймаут, 5xx, POS_E_LOCKED, POS_E_MAINTENANCE', () => {
  const contract = loadContract(path.join(CHECK_DIR, 'src'));
  assert.deepEqual(contract.getRetry, { maxAttempts: 3, delaysMs: [500, 1000] });
  const e = (o) => ({ status: null, error: null, posCode: null, ...o });
  assert.equal(transientReason(e({ status: 503, posCode: 'POS_E_LOCKED' })), '503 POS_E_LOCKED');
  assert.equal(transientReason(e({ status: 423, posCode: 'POS_E_LOCKED' })), '423 POS_E_LOCKED');
  assert.equal(transientReason(e({ status: 503, posCode: 'POS_E_MAINTENANCE' })), '503 POS_E_MAINTENANCE');
  assert.equal(transientReason(e({ status: 500 })), '500');
  assert.equal(transientReason(e({ error: { code: 'RESPONSE_TIMEOUT' }, errorInfo: { code: 'RESPONSE_TIMEOUT', kind: 'timeout' } })), 'нет ответа за отведённое время');
  assert.match(transientReason(e({ error: { code: 'ECONNRESET' }, errorInfo: { code: 'ECONNRESET', kind: 'net' } })), /нет связи \(ECONNRESET\)/);
  for (const x of [e({ status: 200 }), e({ status: 404, posCode: 'POS_E_NOT_FOUND' }), e({ status: 401 }), e({ status: 409, posCode: 'POS_E_STATE' }),
    e({ error: { code: 'DEPTH_ZERO_SELF_SIGNED_CERT' }, errorInfo: { code: 'DEPTH_ZERO_SELF_SIGNED_CERT', kind: 'tls' } }),
    e({ error: { code: 'ENOTFOUND' }, errorInfo: { code: 'ENOTFOUND', kind: 'net' } })]) {
    assert.equal(transientReason(x), null, JSON.stringify(x));
  }
});

test('fix3: «y» в латинской раскладке (клавиша «н») — не «да»: переспрос с подсказкой; «l» = «д», «ytn» = «нет», «g» = «п»', async () => {
  const { Prompter } = await import('../src/prompt.mjs');
  const { PassThrough } = await import('node:stream');
  const ask = async (lines, o) => {
    const input = new PassThrough();
    let out = '';
    const p = new Prompter({ input, output: new PassThrough(), write: (s) => { out += s; } });
    input.end(lines.map((l) => l + '\n').join(''));
    const a = await p.yesNo('Создать пробный QR?', o);
    p.close();
    return { a, out };
  };
  let r = await ask(['y', 'y', 'y'], { def: 'n' });
  assert.equal(r.a, 'n', '«y» трижды — ответ по умолчанию «нет»');
  assert.equal((r.out.match(/Похоже, включена латинская раскладка — ответьте д или н/g) || []).length, 3, r.out);
  r = await ask(['y', 'д'], { def: 'n' });
  assert.equal(r.a, 'y', 'после подсказки «д» — да');
  r = await ask(['yes', 'ytn'], { def: 'n' });
  assert.equal(r.a, 'n');
  r = await ask(['y'], { def: 's', allowSkip: true });
  assert.equal(r.a, null, '«y», затем конец ввода — нет ответа, не «да»');
  assert.match(r.out, /ответьте д, н или п/);
  for (const [w, want] of [['l', 'y'], ['lf', 'y'], ['Д', 'y'], ['н', 'n'], ['n', 'n'], ['g', 's'], ['п', 's'], ['', 's']]) {
    assert.equal((await ask([w], { def: 's', allowSkip: true })).a, want, `«${w}»`);
  }
  assert.equal((await ask(['g', 'н'], { def: 'n' })).a, 'n', '«g» без «пропустить» — переспрос');
});
