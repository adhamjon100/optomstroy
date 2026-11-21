// Приватность: пароль, ключ, base64(user:password) и ПДн имитатора (ООО Пример, +996700000001) не попадают
// ни в консоль, ни в три файла протокола, ни в сохранённые настройки; маскированные формы есть.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import fs from 'node:fs';
import { mockWithSecrets, makeConfig, runMain, readProtocol, tmpDir, frontWithSecrets, secretForms, leaks, SAMPLE_PII } from './helpers/env.mjs';
import { RICH_PII, RICH_PII_HOOK, EXTRA_DEFECTS, EXTRA_PII } from './helpers/defects-extra.mjs';
import { mutateJson } from './helpers/front-1c.mjs';

const dirs = [];
const mocks = [];
after(async () => { for (const m of mocks) await m.close(); for (const d of dirs) fs.rmSync(d, { recursive: true, force: true }); });

const PII = ['ООО Пример', '+996700000001', '0700 000 001', '996700000001'];

test('секреты и ПДн не попадают в консоль и протокол (запись подтверждена)', async () => {
  const { mock, password, clientKey } = await mockWithSecrets({ password: 'Vymyshlennyj-Parol-2026', clientKey: 'vymyshlennyj-klyuch-0000-1111' });
  mocks.push(mock);
  const dir = tmpDir('oc-priv-');
  dirs.push(dir);
  const cfg = makeConfig(dir, { baseUrl: mock.baseUrl, password, clientKey });
  const r = await runMain(['--config', cfg, '--allow-http', '--no-manual', '--allow-write', '--verbose'], { input: `${mock.publication}\n` });
  assert.equal(r.code, 0, r.out.slice(-1500));
  const p = readProtocol(path.join(dir, 'protokoly'));
  const b64 = Buffer.from(`pos_hs:${password}`).toString('base64');
  const all = [r.out, ...p.texts, fs.readFileSync(cfg, 'utf8')];
  for (const t of all) {
    for (const s of [password, clientKey, b64, encodeURIComponent(password)]) assert.ok(!t.includes(s), `секрет в выводе: ${s.slice(0, 6)}…`);
  }
  for (const t of [r.out, ...p.texts]) for (const s of PII) assert.ok(!t.includes(s), `ПДн в выводе: ${s}`);
  assert.ok(p.texts[0].includes('Authorization: Basic ***'));
  assert.ok(p.texts[0].includes('X-POS-Client-Key: ***'));
  assert.ok(p.texts[0].includes('[имя скрыто]'));
  assert.match(p.texts[0], /\+996 \*\*\* \*\* 01/);
});

test('при сетевой ошибке пароль не попадает в вывод, код 2', async () => {
  const dir = tmpDir('oc-priv2-');
  dirs.push(dir);
  const cfg = makeConfig(dir, { baseUrl: 'http://127.0.0.1:9/demo/hs', password: 'Drugoj-Vymyshlennyj-Parol', clientKey: 'drugoj-klyuch-2222' });
  const r = await runMain(['--config', cfg, '--allow-http', '--no-manual']);
  assert.equal(r.code, 2);
  const p = readProtocol(path.join(dir, 'protokoly'));
  assert.ok(p, 'протокол пишется и при сбое связи');
  for (const t of [r.out, ...p.texts]) {
    assert.ok(!t.includes('Drugoj-Vymyshlennyj-Parol'));
    assert.ok(!t.includes('drugoj-klyuch-2222'));
  }
  assert.ok(p.json.aborted);
});

test('флаг с паролем отклоняется с кодом 2', async () => {
  const r = await runMain(['--password=Vymyshlennyj']);
  assert.equal(r.code, 2);
  assert.match(r.out, /только скрытым вводом или файлом/);
  assert.ok(!r.out.includes('Vymyshlennyj'));
});

test('ПДн тестовой копии: контрагент с ИНН, партнёр с ФИО и телефоном — скрыты везде (с записью и --verbose)', async () => {
  const { front, password, clientKey } = await frontWithSecrets({ defect: RICH_PII_HOOK });
  mocks.push(front);
  const dir = tmpDir('oc-priv3-');
  dirs.push(dir);
  const cfg = makeConfig(dir, { baseUrl: front.baseUrl, password, clientKey });
  const r = await runMain(['--config', cfg, '--allow-http', '--no-manual', '--allow-write', '--verbose'], { input: `${front.publication}\n` });
  assert.equal(r.code, 0, r.out.slice(-1500));
  const p = readProtocol(path.join(dir, 'protokoly'));
  const all = [r.out, ...p.texts];
  assert.deepEqual(leaks([...all, fs.readFileSync(cfg, 'utf8')], secretForms(password, clientKey)), []);
  assert.deepEqual(leaks(all, [...SAMPLE_PII, ...RICH_PII.names, RICH_PII.inn, ...RICH_PII.phones, '555123456', '12 34 56']), []);
  // Контрагент из /changes попал в протокол (первые элементы каждого типа) — в маскированном виде.
  assert.ok(p.texts[2].includes('Catalog_Контрагенты'), 'элемент контрагента есть в протоколе');
  assert.ok(p.texts[0].includes('[ИНН скрыт]'));
  assert.match(p.texts[0], /\+996 \*\*\* \*\* 56/);
});

test('ПДн в тексте ошибки 1С (e-mail, ИНН) — находка E9 есть, самих значений в выводе нет', async () => {
  const d = EXTRA_DEFECTS.find((x) => x.id === 'DX13');
  const { front, password, clientKey } = await frontWithSecrets({ defect: d });
  mocks.push(front);
  const dir = tmpDir('oc-priv4-');
  dirs.push(dir);
  const cfg = makeConfig(dir, { baseUrl: front.baseUrl, password, clientKey });
  const r = await runMain(['--config', cfg, '--allow-http', '--no-manual', '--verbose']);
  assert.equal(r.code, 1, r.out.slice(-1500));
  const p = readProtocol(path.join(dir, 'protokoly'));
  assert.deepEqual(leaks([r.out, ...p.texts], [EXTRA_PII.email, EXTRA_PII.inn, 'primer-kg']), []);
  assert.ok(p.texts[0].includes('[e-mail скрыт]') && p.texts[0].includes('[ИНН скрыт]'));
});

// fix2 (Y2, Y10, V35): 1С отдаёт реквизиты «как есть» — русские и транслит-ключи вне контракта 1.2.0 (КонтактноеЛицо,
// Ответственный, adresDostavki…), свободный текст с ФИО и адресом, ФИО клиента в тексте ошибки без слова «клиент».
const Y_PII = {
  names: ['Вымышленная Гульнара Асановна', 'Вымышленный Азамат Бекович', 'Асанов Бакыт Жумабекович', 'Токтогулова Айгуль Вымышленовна'],
  parts: ['Гульнара', 'Азамат', 'Бакыт', 'Жумабекович', 'Токтогулова', 'Айгуль', 'Вымышленовна'],
  address: ['г. Бишкек, ул. Вымышленная, 99', 'ул. Вымышленная', 'Вымышленная, 99', 'мкр. Вымышленный, д. 5', 'Вымышленный, д. 5'],
  phones: ['0555-98-76-54', '+996555987654', '98-76-54', '987654'],
  inn: '01987654321098',
  email: 'vymysel.kontakt@primer.test',
};
const isRecvY = (c) => /^\/pos\/v1\/customers\/[^/]+\/receivables$/.test(c.sub || '');
const oddFields = (o) => Object.assign(o, {
  kontakt: Y_PII.phones[0], zametka: `пишите на ${Y_PII.email}`, otvetstvennyi: Y_PII.names[1], innNomer: Y_PII.inn,
  adresDostavki: Y_PII.address[0], telefonDop: Y_PII.phones[1],
});
const Y_HOOK = {
  id: 'Y10', what: 'ПДн под русскими и транслит-ключами вне контракта, ФИО в тексте ошибки',
  after: (c, r) => {
    if (isRecvY(c) && r.status === 200) {
      return mutateJson(r, (j) => Object.assign(j, {
        КонтактноеЛицо: Y_PII.names[0], Адрес: Y_PII.address[0], Ответственный: Y_PII.names[1], ФИО: Y_PII.names[2], Телефон: Y_PII.phones[0],
        Менеджер: Y_PII.names[3], Покупатель: Y_PII.names[2], Получатель: Y_PII.names[0], deliveryPlace: Y_PII.address[3],
        note: `${Y_PII.names[2]}, ${Y_PII.address[0]}`,
      }));
    }
    if (isRecvY(c) && r.status === 404) return mutateJson(r, (j) => { j.message = `${Y_PII.names[2]}: карточка не найдена`; });
    if (c.sub === '/pos/v1/customers' && r.status >= 200 && r.status < 300) {
      return mutateJson(r, (j) => { if (Array.isArray(j)) j.forEach(oddFields); else oddFields(j); });
    }
    if (c.method === 'GET' && c.sub === '/pos/v1/changes' && r.status === 200) {
      return mutateJson(r, (j) => {
        for (const it of j.items || []) {
          if (it.type === 'Catalog_Партнеры') Object.assign(it, { КонтактноеЛицо: Y_PII.names[3], adresDostavki: Y_PII.address[3] });
        }
      });
    }
    return null;
  },
};

test('fix2: ПДн под ключами вне контракта (КонтактноеЛицо, Ответственный, adresDostavki…) и ФИО в тексте ошибки — нигде не видны; E9 ОШИБКА', async () => {
  const { front, password, clientKey } = await frontWithSecrets({ defect: Y_HOOK });
  mocks.push(front);
  const dir = tmpDir('oc-priv-y10-');
  dirs.push(dir);
  const cfg = makeConfig(dir, { baseUrl: front.baseUrl, password, clientKey });
  const r = await runMain(['--config', cfg, '--allow-http', '--no-manual', '--allow-write', '--verbose'], { input: `${front.publication}\n` });
  const p = readProtocol(path.join(dir, 'protokoly'));
  assert.ok(p, `нет протокола: ${r.out.slice(-1500)}`);
  assert.equal(r.code, 1, r.out.slice(-1500));
  const fails = p.json.checks.filter((x) => x.verdict === 'FAIL').map((x) => x.id);
  assert.deepEqual(fails, ['E9'], `ошибки: ${fails.join(', ')}`);
  const e9 = p.json.checks.find((x) => x.id === 'E9');
  assert.ok(e9.findings.some((f) => f.severity === 'FAIL' && /в тексте ошибки имя клиента/.test(f.text)), JSON.stringify(e9.findings));
  // Ответы с ПДн действительно были в протоколе (маска сработала, а не ответа не было).
  const html = p.texts[0];
  assert.ok(html.includes('КонтактноеЛицо') && html.includes('adresDostavki') && html.includes('otvetstvennyi'), 'поля вне контракта показаны');
  assert.ok(html.includes('[имя скрыто]') && html.includes('[адрес скрыт]') && html.includes('[текст скрыт]'));
  const all = [r.out, ...p.texts];
  assert.deepEqual(leaks([...all, fs.readFileSync(cfg, 'utf8')], secretForms(password, clientKey)), []);
  assert.deepEqual(leaks(all, [...Y_PII.names, ...Y_PII.parts, ...Y_PII.address, ...Y_PII.phones, Y_PII.inn, Y_PII.email, 'primer.test', ...SAMPLE_PII]), []);
});
