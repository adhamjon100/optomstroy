// Валидатор: все 59 образцов 1.2.0 проходят свои схемы (0 нарушений); типовые нарушения дают русские тексты с путём.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { loadContract } from '../src/contract.mjs';
import { Validator } from '../src/schema.mjs';
import { SAMPLES } from './helpers/env.mjs';

const c = loadContract(path.resolve(SAMPLES, '..', '..', '..', 'src'));
const v = new Validator(c, { extraEnum: { ExternalObjectType: ['Реализация'] }, extraKnown: { ExternalIdRecord: ['posted'] } });
const S = (n) => ({ $ref: `#/components/schemas/${n}` });
const errs = (val, n) => v.validate(val, S(n)).errors;

test('все 59 образцов проходят схемы своих операций и статусов', () => {
  const files = fs.readdirSync(SAMPLES).filter((f) => f.endsWith('.json'));
  assert.equal(files.length, 59);
  for (const f of files) {
    const j = JSON.parse(fs.readFileSync(path.join(SAMPLES, f), 'utf8'));
    const [m, p] = j.operation.split(' ');
    const op = c.op(`${m} ${p}`);
    const schema = j.kind === 'request' ? op.requestSchema : c.responseSchema(op, j.status);
    assert.ok(schema, `${f}: нет схемы`);
    const e = v.validate(j.body, schema).errors.filter((x) => x.severity !== 'INFO');
    assert.deepEqual(e, [], `${f}: ${e.map((x) => x.text).join('; ')}`);
  }
});

test('форматы: деньги числом, количество, дата, GUID, телефон, валюта', () => {
  const r = errs({ customerRef: 'C3D4E5F6-0000-4000-8000-000000000001', snapshotAt: '2026-10-21T13:39:05.123+06:00', balance: 1234.5, overdueAmount: '0', overdueDays: 0, creditAllowed: true, creditLimit: null, creditDays: null, creditAvailable: null, documents: null }, 'CustomerReceivables');
  const t = r.map((e) => `${e.rule} ${e.text}`).join('\n');
  assert.match(t, /E4 customerRef: ссылка в верхнем регистре/);
  assert.match(t, /E5 snapshotAt: дата с долями секунды — нужно без долей секунды/);
  assert.match(t, /E5 balance: деньги переданы числом/);
  assert.match(t, /E5 overdueAmount: деньги не в формате/);
  assert.match(t, /E6 documents: пустой список — \[\], не null/);
  const t2 = errs({ subtotal: '1.00', discount: '0.00', total: '1.00', currency: 'USD' }, 'Totals').map((e) => e.text).join('\n');
  assert.match(t2, /валюта не KGS/);
  const t3 = errs({ ref: 'c3d4e5f6-0000-4000-8000-000000000002', name: 'x', phone: '0700000001' }, 'DuplicateCandidate').map((e) => e.text).join('\n');
  assert.match(t3, /телефон не в формате \+996XXXXXXXXX/);
  assert.ok(!t3.includes('0700000001'), 'телефон в тексте находки маскируется');
});

test('nullable, oneOf [схема, null], дискриминатор, неизвестный тип и поле-опечатка', () => {
  assert.deepEqual(errs({ checkedAt: '2026-10-21T14:05:00+06:00', lines: [], receivables: null, totals: null, issues: [] }, 'CheckResponse'), []);
  const page = {
    messageNumber: 1, hasMore: false, cursor: null, generatedAt: '2026-10-21T14:05:00+06:00',
    items: [{ type: 'Catalog_Чтото', ref: 'x' }, { type: 'Catalog_Склады', ref: '{a1b2c3d4-0000-4000-8000-000000000001}', dataVersion: 'x', deletionMark: false, description: 'Склад', externalID: 'y', isFoldr: true }],
  };
  const r = errs(page, 'ChangesPage');
  const t = r.map((e) => `${e.severity} ${e.rule} ${e.text}`).join('\n');
  assert.match(t, /WARN UNKNOWN_TYPE items\[0\]\.type: неизвестный тип элемента/);
  assert.match(t, /FAIL E4 items\[1\]\.ref: ссылка не GUID из 36 символов/);
  assert.match(t, /WARN FIELD items\[1\]\.isFoldr: поле «isFoldr» — возможно, опечатка: в контракте «isFolder»/);
  assert.match(t, /INFO FIELD items\[1\]\.externalID/);
});

test('нет обязательного поля, null вместо значения, правила приёма POS', () => {
  const t = errs({ type: 'Catalog_УпаковкиЕдиницыИзмерения', ref: 'a1b2c3d4-0000-4000-8000-000000000201', dataVersion: 'x', deletionMark: false, description: 'шт', ownerRef: 'a1b2c3d4-0000-4000-8000-000000000001', unitRef: null, factor: '2.00' }, 'PackagingChange')
    .map((e) => `${e.severity} ${e.rule} ${e.text}`).join('\n');
  assert.match(t, /WARN POS unitRef: POS не применит элемент/);
  assert.match(t, /FAIL E5 factor: количество — три знака после точки/);
  const t2 = errs({ apiVersion: '1' }, 'Health').map((e) => e.text).join('\n');
  assert.match(t2, /нет обязательного поля serverTime/);
});

test('ExternalObjectType — только перечень контракта 1.2.0: другие значения (в том числе «Реализация») — ОШИБКА; поле posted — вне контракта (СВЕДЕНИЯ)', () => {
  const rec = (t) => ({ externalId: 'a1b2c3d4-0000-4000-8000-000000000001', objectType: t, ref: 'a1b2c3d4-0000-4000-8000-000000000002', number: null, date: null, deletionMark: false, posted: null });
  const r1 = errs(rec('Реализация'), 'ExternalIdRecord');
  assert.deepEqual(r1.map((e) => `${e.severity} ${e.code}`).sort(), ['FAIL enum', 'INFO unknown-field']);
  assert.match(r1.find((e) => e.code === 'enum').text, /не из перечня контракта: Заказ, Платеж, Клиент, ЗаявкаНаВозврат/);
  assert.equal(errs(rec('Order'), 'ExternalIdRecord').find((e) => e.code === 'enum').severity, 'FAIL');
  assert.deepEqual(errs(rec('Клиент'), 'ExternalIdRecord').map((e) => `${e.severity} ${e.code}`), ['INFO unknown-field']);
});

test('fix3 E5: «+996» + местный номер с 0 («+9960700000001») — ОШИБКА «после +996 должно быть 9 цифр» (H07b); чужая страна — ЗАМЕЧАНИЕ', () => {
  const cand = (phone) => errs({ ref: 'c3d4e5f6-0000-4000-8000-000000000002', contractorRef: null, code: '00000001', name: 'x', phone, deletionMark: false }, 'CustomerCandidate')
    .filter((e) => e.rule === 'E5');
  const a = cand('+9960700000001');
  assert.deepEqual(a.map((e) => `${e.severity} ${e.code}`), ['FAIL phone-kg-digits'], JSON.stringify(a));
  assert.match(a[0].text, /после \+996 должно быть 9 цифр, пришло 10; похоже, к \+996 приписан номер с ведущим 0/);
  assert.ok(!a[0].text.includes('0700000001'), 'телефон в тексте находки маскируется');
  assert.deepEqual(cand('+99670000001').map((e) => `${e.severity} ${e.code}`), ['FAIL phone-kg-digits']);
  assert.deepEqual(cand('+77011234567').map((e) => `${e.severity} ${e.code}`), ['WARN phone-not-kg']);
  assert.deepEqual(cand('+996700000001'), []);
});
