// Ручные шаги через ввод (имитатор в процессе теста, ответы по подсказкам):
//  - «п» на «сделайте в 1С … и нажмите Enter» — ПРОПУЩЕНО (не ОШИБКА); после «п» на «Включите» не просит «Выключите»;
//  - Enter на вопрос — «пропустить»; «нет» на необязательный шаг (M9) — ЗАМЕЧАНИЕ, код 0;
//  - вопросы без отрицания: «Публикация закрыта из интернета?» «д» — ВРУЧНУЮ: ДА, «н» — ВРУЧНУЮ: НЕТ, код 1;
//  - C13 (сверка чисел) без перерегистрации не спрашивается; с перерегистрацией — спрашивается;
//  - K10 показывает код клиента (по GUID клиента в 1С не найти).
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import fs from 'node:fs';
import { mockWithSecrets, makeConfig, readProtocol, check, tmpDir, runInteractive } from './helpers/env.mjs';

const dirs = [];
const mocks = [];
after(async () => { for (const m of mocks) await m.close(); for (const d of dirs) fs.rmSync(d, { recursive: true, force: true }); });

async function setup(prefix) {
  const { mock, password, clientKey } = await mockWithSecrets();
  mocks.push(mock);
  const dir = tmpDir(prefix);
  dirs.push(dir);
  return { mock, dir, cfg: makeConfig(dir, { baseUrl: mock.baseUrl, password, clientKey }) };
}

test('«п» — пропустить: C11 и M1 ПРОПУЩЕНО, «Выключите» не спрашивается; Enter — пропустить; «нет» на необязательный — замечание; код 0', async () => {
  const { mock, dir, cfg } = await setup('oc-man1-');
  const r = await runInteractive(['--config', cfg, '--allow-http'], [
    [/Измените в 1С описание товара/, 'п'],
    [/Необязательно: удалите на копии объект состава обмена совсем/, ''],
    [/Долг: клиент с кодом [^,]+ \(ref [0-9a-f-]{36}\)[^\n]*\n[^\n]*Сальдо совпадает с отчётом «Задолженность клиентов»\?[^\n]*\[д\/н\/П\]/, 'д'],
    [/Включите в 1С константу ОбменПриостановлен — нажмите Enter \(или введите «п» и Enter, чтобы пропустить\)/, 'п'],
    [/Публикация закрыта из интернета/, 'д'],
    [/POS_ЖурналЗапросовPOS/, 'н'],
    [/работали без замедления/, ''],
  ]);
  assert.equal(r.code, 0, r.out.slice(-2500));
  assert.deepEqual(r.unanswered, [], `не все вопросы заданы: ${r.unanswered.join(', ')}`);
  assert.ok(!/Выключите константу/.test(r.out), 'после «п» на «Включите» не просит «Выключите»');
  assert.ok(!/Числа товаров и клиентов совпадают с 1С\? \(д/.test(r.out), 'без перерегистрации C13 не спрашивается');
  const p = readProtocol(path.join(dir, 'protokoly'));
  const v = (id) => check(p, id).verdict;
  assert.equal(v('C11'), 'SKIP');
  assert.match(check(p, 'C11').summary, /пропущено человеком/);
  assert.equal(v('M1'), 'SKIP');
  assert.match(check(p, 'M1').summary, /пропущено человеком/);
  assert.equal(v('C12'), 'SKIP');
  assert.equal(v('C13'), 'SKIP');
  assert.match(check(p, 'C13').summary, /только после перерегистрации/);
  assert.equal(v('K10'), 'MANUAL_YES');
  assert.equal(v('M3'), 'MANUAL_YES');
  assert.equal(v('M9'), 'WARN', 'необязательный шаг: «нет» — замечание');
  assert.equal(v('M10'), 'SKIP', 'Enter — пропустить');
  assert.equal(v('M11'), 'SKIP');
  assert.ok(mock.journal.every((j) => j.method === 'GET'), 'без --allow-write ручные шаги тоже только читают');
});

test('M1 и C11 выполнены, «н» на «Публикация закрыта из интернета?» — ВРУЧНУЮ: НЕТ, код 1', async () => {
  const { mock, dir, cfg } = await setup('oc-man2-');
  const r = await runInteractive(['--config', cfg, '--allow-http'], [
    [/Измените в 1С описание товара «[^»]*» \(код [^,]*, ref ([0-9a-f-]{36})\)/, (m) => { mock.simulate.changeProduct(m[1]); return ''; }],
    [/удалите на копии/, 'п'],
    [/Сальдо совпадает/, 'п'],
    [/Включите в 1С константу ОбменПриостановлен/, () => { mock.simulate.setMaintenance(true); return ''; }],
    [/Выключите константу ОбменПриостановлен — нажмите Enter: /, () => { mock.simulate.setMaintenance(false); return ''; }],
    [/Публикация закрыта из интернета/, 'н'],
    [/POS_ЖурналЗапросовPOS/, 'п'],
    [/работали без замедления/, 'д'],
  ]);
  assert.equal(r.code, 1, r.out.slice(-2000));
  assert.deepEqual(r.unanswered, []);
  const p = readProtocol(path.join(dir, 'protokoly'));
  assert.equal(check(p, 'M1').verdict, 'PASS', check(p, 'M1').summary);
  assert.equal(check(p, 'C11').verdict, 'PASS', check(p, 'C11').summary);
  assert.equal(check(p, 'M3').verdict, 'MANUAL_NO');
  assert.equal(check(p, 'M10').verdict, 'MANUAL_YES');
  assert.ok(check(p, 'M3').advice, 'у «ВРУЧНУЮ: НЕТ» есть подсказка');
  assert.ok(p.texts[0].includes('Ручные шаги'));
});

test('с перерегистрацией (запись) C13 спрашивается: «д» — ВРУЧНУЮ: ДА', async () => {
  const { mock, dir, cfg } = await setup('oc-man3-');
  const r = await runInteractive(['--config', cfg, '--allow-http', '--allow-write'], [
    [/введите имя публикации/, mock.publication],
    [/Выполнить перерегистрацию/, 'д'],
    [/Создать пробный QR/, 'н'],
    [/Измените в 1С описание товара/, 'п'],
    [/удалите на копии/, 'п'],
    [/Числа товаров и клиентов совпадают с 1С\?/, 'д'],
    [/Сальдо совпадает/, 'п'],
    [/Включите в 1С константу/, 'п'],
    [/Публикация закрыта из интернета/, 'п'],
    [/Найдите в 1С объекты из списка/, 'п'],
    [/POS_ЖурналЗапросовPOS/, 'п'],
    [/работали без замедления/, 'п'],
  ], { timeoutMs: 240000 });
  assert.equal(r.code, 0, r.out.slice(-2500));
  const p = readProtocol(path.join(dir, 'protokoly'));
  assert.equal(check(p, 'C6').verdict, 'PASS', check(p, 'C6').summary);
  assert.equal(check(p, 'C13').verdict, 'MANUAL_YES', check(p, 'C13').summary);
});
