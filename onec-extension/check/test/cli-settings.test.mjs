// Флаги, настройки и коды выхода отдельным процессом: справка, версия, каталог (0); ошибки флагов и настроек (2)
// с понятным русским текстом; секреты в командной строке не принимаются и не повторяются в выводе.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { parseCli } from '../src/cli.mjs';
import { runMain, tmpDir, readProtocol } from './helpers/env.mjs';

const dirs = [];
after(() => { for (const d of dirs) fs.rmSync(d, { recursive: true, force: true }); });

function settingsFile(obj, raw = null) {
  const d = tmpDir('oc-cli-');
  dirs.push(d);
  const f = path.join(d, 'nastrojki.json');
  fs.writeFileSync(f, raw ?? JSON.stringify(obj));
  return { dir: d, file: f };
}

test('--help, --version, --list → код 0, по-русски', async () => {
  const h = await runMain(['--help']);
  assert.equal(h.code, 0);
  assert.match(h.out, /Коды выхода: 0 — ошибок нет; 1 — есть ошибки/);
  assert.match(h.out, /--allow-write/);
  assert.ok(!/--demo-defect|--timeout-scale/.test(h.out), 'флаги разработчика не в справке');
  const v = await runMain(['--version']);
  assert.equal(v.code, 0);
  assert.match(v.out, /контракт onec-http-service 1\.2\.0; sha256 YAML [0-9a-f]{64}.*git blob 63995cc4badb60badeda208adec11c8d6a06d864/);
  const l = await runMain(['--list']);
  assert.equal(l.code, 0);
  for (const s of ['S1', 'A2', 'C7', 'PAY6', 'O5', 'R1', 'CK4', 'E12', 'Корзина в долг клиента → блок receivables']) assert.ok(l.out.includes(s), s);
  // Проб методов отозванного задания и проверок «ждут 1.3.0» в каталоге нет.
  for (const s of ['N1', 'T13', '/prices', 'ТЗ 2.3', '1.3.0']) assert.ok(!l.out.includes(s), s);
});

test('секрет флагом в любом виде → код 2, значение не повторяется', async () => {
  for (const a of [['--password=Vymysel-Sekret-1'], ['--token', 'Vymysel-Sekret-2'], ['--client-key=Vymysel-Sekret-3'], ['-parol', 'Vymysel-Sekret-4'], ['--X-POS-Client-Key=Vymysel-Sekret-5']]) { // check-secrets: allow — вымышленное тестовое значение, не секрет
    const r = await runMain(a);
    assert.equal(r.code, 2, a.join(' '));
    assert.match(r.out, /в командной строке не передаются/);
    assert.ok(!/Vymysel-Sekret/.test(r.out), `секрет повторён: ${a.join(' ')}`);
  }
});

test('ошибки флагов → код 2 и понятный текст', async () => {
  const cases = [
    [['--neizvestnyj'], /неизвестный флаг --neizvestnyj/],
    [['--checks', 'ZZ9,A2'], /неизвестные проверки или группы: ZZ9/],
    [['--demo-defect', 'D01'], /--demo-defect только вместе с --demo/],
    [['--demo', '--demo-defect', 'D99'], /неизвестный дефект D99/],
    [['--timeout-scale', '5'], /--timeout-scale: число от 0\.001 до 1/],
    [['--config'], /у флага --config нет значения/],
    [['--demo=da'], /флаг --demo не принимает значение/],
    [['Vymysel-Pozicionnyj-Parol'], /лишний аргумент без флага/],
  ];
  for (const [args, re] of cases) {
    const r = await runMain(args);
    assert.equal(r.code, 2, `${args.join(' ')}: ${r.out}`);
    assert.match(r.out, re, args.join(' '));
    assert.ok(!/Unexpected|argument missing|Unknown option|does not take/i.test(r.out), `английский текст Node: ${r.out}`);
    assert.ok(!r.out.includes('Vymysel-Pozicionnyj'), 'лишний аргумент (возможно, пароль) не повторяется');
  }
});

test('ошибки настроек → код 2 и понятный текст (без протокола проверок)', async () => {
  const missing = path.join(tmpDir('oc-cli-none-'), 'net_takogo.json');
  dirs.push(path.dirname(missing));
  const cases = [
    [missing, /файл настроек net_takogo\.json не найден/],
    [settingsFile(null, '{ "baseUrl": "https://srv/hs", }').file, /ошибка JSON в строке 1, столбце 32/],
    [settingsFile({ baseUrl: 'https://srv/ut_test/hs', password: 'Vymysel-V-Nastrojkah' }).file, /пароль, токен и ключ в настройки не пишутся/], // check-secrets: allow — вымышленное тестовое значение, не секрет
    [settingsFile({ user: 'pos_hs' }).file, /не указан адрес публикации \(baseUrl\)/],
    [settingsFile({ baseUrl: 'https://srv/ut_test/hs', auth: 'ntlm' }).file, /auth: «ntlm» — допустимо basic или bearer/],
    [settingsFile({ baseUrl: 'https://user:p@srv/ut_test/hs' }).file, /пользователь и пароль в адресе не допускаются/],
    [settingsFile({ baseUrl: 'ftp://srv/ut_test/hs' }).file, /схема ftp: не поддерживается/],
    [settingsFile({ baseUrl: 'https://127.0.0.1:9/ut_test/hs', passwordFile: 'net_fajla.txt', clientKeyFile: 'net_fajla2.txt' }).file, /файл, указанный в passwordFile, не найден — там должен быть ПУТЬ к файлу с паролем/], // check-secrets: allow — вымышленное тестовое значение, не секрет
    [settingsFile({ baseUrl: 'http://127.0.0.1:9/ut_test/hs' }).file, /без шифрования.*--allow-http/],
  ];
  for (const [file, re] of cases) {
    const r = await runMain(['--config', file, '--no-manual'], { input: '' });
    assert.equal(r.code, 2, `${path.basename(path.dirname(file))}: ${r.out}`);
    assert.match(r.out, re);
    assert.ok(!r.out.includes('Vymysel-V-Nastrojkah'));
  }
});

test('ошибки настроек не повторяют введённое: пароль в passwordFile, пароль без кавычек, адрес с ошибкой', async () => {
  const cases = [
    // сам пароль вместо пути к файлу
    [settingsFile({ baseUrl: 'https://127.0.0.1:9/ut_test/hs', passwordFile: 'Vymysel-Sekret-Parol-2026' }).file, /файл, указанный в passwordFile, не найден — там должен быть ПУТЬ к файлу с паролем, а не сам секрет/], // check-secrets: allow — вымышленное тестовое значение, не секрет
    // значение без кавычек: текст V8 процитировал бы пароль
    [settingsFile(null, '{\n  "baseUrl": "https://127.0.0.1:9/ut_test/hs",\n  "parol": Vymysel-Sekret-Parol-2026\n}').file, /ошибка JSON в строке 3, столбце 12/],
    // одиночная обратная черта в пути — подсказка, как писать путь
    [settingsFile(null, '{ "baseUrl": "https://127.0.0.1:9/ut_test/hs", "caFile": "C:\\certs\\new\\ca.pem" }').file, /в пути пишите две обратные черты или прямую/],
    // адрес не разобран — не повторяется
    [settingsFile({ baseUrl: 'https://pos_hs:Vymysel-Sekret-Parol-2026@[::zz]/ut_test/hs' }).file, /адрес публикации не разобран — нужен вид https:\/\/сервер\/публикация\/hs/], // check-secrets: allow — вымышленное тестовое значение, не секрет
  ];
  for (const [file, re] of cases) {
    const r = await runMain(['--config', file, '--no-manual'], { input: '' });
    assert.equal(r.code, 2, r.out);
    assert.match(r.out, re);
    assert.ok(!r.out.includes('Vymysel-Sekret'), `введённое повторено: ${r.out}`);
    assert.ok(!/Unexpected|valid JSON|Bad control/i.test(r.out), `текст V8: ${r.out}`);
    assert.match(r.out, /протокол не записан — причина на экране/);
  }
});

test('настройки в UTF-16 (Блокнот «Юникод») читаются; ключ в русской раскладке → код 2, понятный текст', async () => {
  const s = settingsFile(null, 'x');
  fs.writeFileSync(s.file, Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(JSON.stringify({ baseUrl: 'http://127.0.0.1:9/ut_test/hs', passwordFile: 'p.txt', clientKeyFile: 'k.txt' }), 'utf16le')]));
  fs.writeFileSync(path.join(s.dir, 'p.txt'), 'Vymysel-Parol-U16');
  fs.writeFileSync(path.join(s.dir, 'k.txt'), 'Еуые-Лднгср-ключ1234567');
  const r = await runMain(['--config', s.file, '--allow-http', '--no-manual'], { input: '' });
  assert.equal(r.code, 2, r.out);
  assert.match(r.out, /в ключе клиента есть русские буквы, пробелы или другие недопустимые символы — проверьте раскладку клавиатуры/);
  assert.ok(!r.out.includes('Еуые') && !/Invalid character/i.test(r.out));
});

test('файл корневого сертификата: не PEM → код 2; путь в кавычках («Копировать как путь») — кавычки снимаются', async () => {
  const s = settingsFile({ baseUrl: 'https://127.0.0.1:9/ut_test/hs', passwordFile: 'p.txt', clientKeyFile: 'k.txt' });
  fs.writeFileSync(path.join(s.dir, 'p.txt'), 'Vymysel-Parol-CA');
  fs.writeFileSync(path.join(s.dir, 'k.txt'), 'vymysel-klyuch-ca');
  fs.writeFileSync(path.join(s.dir, 'der.cer'), Buffer.from([0x30, 0x82, 0x01, 0x0a, 0x02, 0x82]));
  const r = await runMain(['--config', s.file, '--no-manual', '--ca', `"${path.join(s.dir, 'der.cer')}"`]);
  assert.equal(r.code, 2, r.out);
  assert.match(r.out, /не PEM: нужен текст, начинающийся с -----BEGIN CERTIFICATE-----/);
});

test('файл корневого сертификата не найден → код 2', async () => {
  const s = settingsFile({ baseUrl: 'https://127.0.0.1:9/ut_test/hs', passwordFile: 'p.txt', clientKeyFile: 'k.txt' });
  fs.writeFileSync(path.join(s.dir, 'p.txt'), 'Vymysel-Parol-CA');
  fs.writeFileSync(path.join(s.dir, 'k.txt'), 'vymysel-klyuch-ca');
  const r = await runMain(['--config', s.file, '--no-manual', '--ca', path.join(s.dir, 'net.pem')]);
  assert.equal(r.code, 2, r.out);
  assert.match(r.out, /файл корневого сертификата не прочитан/);
});

test('пароль и ключ вводом: пустой ввод (нет консоли) → код 2 «не введён»', async () => {
  const s = settingsFile({ baseUrl: 'http://127.0.0.1:9/ut_test/hs' });
  const r = await runMain(['--config', s.file, '--allow-http', '--no-manual'], { input: '' });
  assert.equal(r.code, 2, r.out);
  assert.match(r.out, /пароль не введён/);
  assert.equal(readProtocol(path.join(s.dir, 'protokoly')), null, 'без связи с 1С протокол проверок не пишется');
});

test('предупреждения настроек не мешают: опечатка ключа, неверный GUID в refs, limits', async () => {
  const s = settingsFile({ baseUrl: 'http://127.0.0.1:9/ut_test/hs', passwordFile: 'p.txt', clientKeyFile: 'k.txt', outDr: 'x', refs: { productRef: 'A1B2' }, limits: { pageLimit: 0 } });
  fs.writeFileSync(path.join(s.dir, 'p.txt'), 'Vymysel-Parol-Warn');
  fs.writeFileSync(path.join(s.dir, 'k.txt'), 'vymysel-klyuch-warn');
  const r = await runMain(['--config', s.file, '--allow-http', '--no-manual', '--timeout-scale', '0.05']);
  assert.equal(r.code, 2, 'порт 9 закрыт — нет связи');
  assert.match(r.out, /неизвестный ключ настроек «outDr» — возможно, опечатка: «outDir»/);
  assert.match(r.out, /refs\.productRef: «A1B2» — не GUID/);
  assert.match(r.out, /limits\.pageLimit: нужно целое число ≥ 1/);
});

test('parseCli: значения флагов', () => {
  const f = parseCli(['--config', 'n.json', '--checks', 'a2, c;pay', '--allow-write', '--timeout-scale', '0.5', '--insecure']);
  assert.equal(f.config, 'n.json');
  assert.deepEqual(f.checks, ['A2', 'C', 'PAY']);
  assert.equal(f.allowWrite, true);
  assert.equal(f.timeoutScale, 0.5);
  assert.equal(f.insecure, true);
  assert.equal(parseCli([]).noArgs, true);
});
