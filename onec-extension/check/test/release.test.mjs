// Сборка --no-runtime во временную папку и запуск из раскладки релиза в папке с пробелами, скобками и кириллицей
// («Тест папка (1)\Проверка API 1С»):
//  - мастер первого запуска (нет nastrojki.json): адрес …/pos/v1/health → …/hs, пароль и ключ из ввода, настройки
//    сохранены рядом с программой без секретов, протокол в protokoly\ рядом с программой (не в текущей папке);
//    второй запуск берёт сохранённые настройки;
//  - Windows: Proverka_API_1C.cmd (node.exe этого теста в runtime\) — коды 0/1/2 доходят до вызывающего,
//    Proverka_API_1C_zapis.cmd передаёт флаги и ввод (подтверждение записи).
// Страж утечки сборки здесь отключён (--draft-contract = 1.2.0): его проверяет build.test.mjs.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { CHECK_DIR, tmpDir, frontWithSecrets, mockWithSecrets, secretForms, leaks, readProtocol, check } from './helpers/env.mjs';

const isWin = process.platform === 'win32';
const dirs = [];
const fronts = [];
let STAGE = null;
after(async () => { for (const f of fronts) await f.close(); for (const d of dirs) fs.rmSync(d, { recursive: true, force: true }); });

before(() => {
  const out = tmpDir('oc-rel-build-');
  dirs.push(out);
  const r = spawnSync(process.execPath, [path.join(CHECK_DIR, 'build.mjs'), '--no-runtime', '--out', out,
    '--draft-contract', path.join(CHECK_DIR, 'contract', '1.2.0', 'onec-http-service.v1.yaml')], { encoding: 'utf8', timeout: 300000 });
  assert.equal(r.status, 0, r.stdout + r.stderr);
  STAGE = path.join(out, fs.readdirSync(out).find((f) => /^Optomstroy_Proverka_API_1C_\d+\.\d+\.\d+$/.test(f)));
});

/** Копия раскладки релиза в «Тест папка (1)\Проверка API 1С». */
function releaseCopy(prefix) {
  const root = tmpDir(prefix);
  dirs.push(root);
  const X = path.join(root, 'Тест папка (1)', 'Проверка API 1С');
  fs.mkdirSync(X, { recursive: true });
  copyTree(STAGE, X);
  return { root, X };
}

/** Копирование по файлам: fs.cpSync в Node 24.11.1 под Windows молча ничего не копирует в папку с кириллицей. */
function copyTree(from, to) {
  fs.mkdirSync(to, { recursive: true });
  for (const e of fs.readdirSync(from, { withFileTypes: true })) {
    if (e.isDirectory()) copyTree(path.join(from, e.name), path.join(to, e.name));
    else fs.copyFileSync(path.join(from, e.name), path.join(to, e.name));
  }
}

function runNode(file, args, { input = '', cwd } = {}) {
  return new Promise((resolve) => {
    const p = spawn(process.execPath, [file, ...args], { cwd, stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '';
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { out += d; });
    p.stdin.on('error', () => {});
    p.stdin.end(input);
    const t = setTimeout(() => p.kill(), 180000);
    p.on('close', (code) => { clearTimeout(t); resolve({ code, out }); });
  });
}

test('запускатели: только ASCII, CRLF, chcp 65001, путь в кавычках, без EnableDelayedExpansion', () => {
  for (const f of ['Proverka_API_1C.cmd', 'Proverka_API_1C_zapis.cmd']) {
    const buf = fs.readFileSync(path.join(STAGE, f));
    assert.ok(buf.every((b) => b < 0x80), `${f}: не ASCII`);
    const t = buf.toString('latin1');
    assert.ok(!/[^\r]\n/.test(t), `${f}: не CRLF`);
    assert.match(t, /chcp 65001/);
    assert.match(t, /"%~dp0runtime\\node\.exe"/);
    assert.match(t, /"%~dp0programma\\main\.mjs"/);
    assert.ok(!/EnableDelayedExpansion/i.test(t));
    assert.match(t, /exit \/b %RC%/);
  }
  assert.match(fs.readFileSync(path.join(STAGE, 'Proverka_API_1C_zapis.cmd'), 'latin1'), /main\.mjs" --allow-write %\*/);
});

test('мастер первого запуска из папки с кириллицей: настройки без секретов, протокол рядом с программой', async () => {
  const { front, password, clientKey } = await frontWithSecrets({ password: 'Vymyshlennyj-Parol-Master-2026', clientKey: 'vymyshlennyj-klyuch-master-0001' });
  fronts.push(front);
  const { root, X } = releaseCopy('oc-rel-wiz-');
  const main = path.join(X, 'programma', 'main.mjs');
  const input = [`${front.baseUrl}/pos/v1/health`, '', '1', password, clientKey, 'д', ''].join('\n');
  const r = await runNode(main, ['--allow-http', '--no-manual', '--checks', 'S,A,H'], { input, cwd: root });
  assert.equal(r.code, 0, r.out.slice(-2000));
  assert.match(r.out, /Файл настроек не найден/);
  assert.match(r.out, /адрес сокращён до публикации/);
  assert.match(r.out, /Настройки сохранены/);
  const saved = path.join(X, 'nastrojki.json');
  assert.ok(fs.existsSync(saved), 'nastrojki.json рядом с программой');
  const s = JSON.parse(fs.readFileSync(saved, 'utf8'));
  assert.equal(s.baseUrl, front.baseUrl);
  assert.equal(s.user, 'pos_hs');
  assert.equal(s.auth, 'basic');
  for (const k of ['password', 'clientKey', 'token']) assert.ok(!(k in s), `в настройках ключ ${k}`);
  const p = readProtocol(path.join(X, 'protokoly'));
  assert.ok(p, 'протокол в protokoly рядом с программой');
  assert.ok(!fs.existsSync(path.join(root, 'protokoly')), 'не в текущей папке');
  assert.equal(p.json.exitCode, 0);
  assert.deepEqual(leaks([r.out, ...p.texts, fs.readFileSync(saved, 'utf8')], secretForms(password, clientKey)), []);
  // Второй запуск: настройки читаются, мастер не спрашивает адрес; пароль и ключ — снова вводом.
  const r2 = await runNode(main, ['--allow-http', '--no-manual', '--checks', 'S,A,H'], { input: `${password}\n${clientKey}\n`, cwd: root });
  assert.equal(r2.code, 0, r2.out.slice(-2000));
  assert.ok(!/Файл настроек не найден/.test(r2.out));
  assert.match(r2.out, /Пароль пользователя pos_hs \(ввод скрыт\)/);
  assert.deepEqual(leaks([r2.out], secretForms(password, clientKey)), []);
});

const hasOpenssl = spawnSync('openssl', ['version'], { encoding: 'utf8' }).status === 0;

test('мастер по HTTPS с внутренним центром: путь к .pem в кавычках из вопроса «4)» действует в первом же запуске', { skip: !hasOpenssl }, async () => {
  const certDir = tmpDir('oc-rel-ca-certs-');
  dirs.push(certDir);
  const ossl = (args) => {
    const r = spawnSync('openssl', args, { cwd: certDir, encoding: 'utf8', env: { ...process.env, MSYS_NO_PATHCONV: '1' } });
    assert.equal(r.status, 0, r.stderr);
  };
  ossl(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'ca.key', '-out', 'ca.pem', '-days', '120', '-subj', '/CN=Vymyshlennyj Test CA']);
  fs.writeFileSync(path.join(certDir, 'ext.cnf'), 'subjectAltName=DNS:localhost,IP:127.0.0.1\n');
  ossl(['req', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'srv.key', '-out', 'srv.csr', '-subj', '/CN=localhost']);
  ossl(['x509', '-req', '-in', 'srv.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key', '-CAcreateserial', '-out', 'srv.pem', '-days', '90', '-extfile', 'ext.cnf']);
  const { mock, password, clientKey } = await mockWithSecrets({ tls: { key: fs.readFileSync(path.join(certDir, 'srv.key')), cert: fs.readFileSync(path.join(certDir, 'srv.pem')), hostname: 'localhost' } });
  fronts.push(mock);
  const { root, X } = releaseCopy('oc-rel-wizca-');
  const main = path.join(X, 'programma', 'main.mjs');
  // Порядок вопросов: адрес, пользователь, вход, сертификат (до пароля), пароль, ключ, «сохранить?».
  const input = [mock.baseUrl, '', '1', `"${path.join(certDir, 'ca.pem')}"`, password, clientKey, 'н', ''].join('\n');
  const r = await runNode(main, ['--no-manual', '--checks', 'S,A1'], { input, cwd: root });
  assert.equal(r.code, 0, r.out.slice(-2000));
  assert.match(r.out, /4\) Файл корневого сертификата \(\.pem\)/);
  assert.ok(r.out.indexOf('4) Файл корневого сертификата') < r.out.indexOf('Пароль пользователя'), 'сертификат спрашивается до пароля');
  const p = readProtocol(path.join(X, 'protokoly'));
  assert.equal(check(p, 'S2').verdict, 'PASS', check(p, 'S2').summary);
  assert.match(check(p, 'S2').summary, /сертификат проверен/);
  assert.equal(p.json.target.tls.caFile, true);
});

function runCmd(cwd, cmdFile, args) {
  // Как двойной щелчок по полному пути: cmd /d /s /c ""…\Proverka_API_1C.cmd" аргументы"
  const line = `/d /s /c ""${cmdFile}" ${args}"`;
  return spawnSync('cmd.exe', [line], { cwd, encoding: 'utf8', timeout: 300000, windowsVerbatimArguments: true, input: '' });
}

test('Windows: Proverka_API_1C.cmd из «Тест папка (1)\\Проверка API 1С» — коды 0, 1, 2 и протокол', { skip: !isWin }, () => {
  const { root, X } = releaseCopy('oc-rel-cmd-');
  fs.mkdirSync(path.join(X, 'runtime'));
  fs.copyFileSync(process.execPath, path.join(X, 'runtime', 'node.exe'));
  const cmd = path.join(X, 'Proverka_API_1C.cmd');
  const v = runCmd(root, cmd, '--version');
  assert.equal(v.status, 0, v.stdout + v.stderr);
  assert.match(v.stdout, /контракт onec-http-service 1\.2\.0/);
  const ok = runCmd(root, cmd, '--demo --no-manual');
  assert.equal(ok.status, 0, String(ok.stdout).slice(-2000));
  assert.match(ok.stdout, /Итог: ошибок нет/, 'русский текст в консоли (chcp 65001)');
  const prot = fs.readdirSync(path.join(X, 'protokoly'));
  assert.equal(prot.filter((f) => /^protokol_proverki_API_1C_DEMO_.*\.(html|md|json)$/.test(f)).length, 3, prot.join(', '));
  const bad = runCmd(root, cmd, '--demo --no-manual --demo-defect D01');
  assert.equal(bad.status, 1, String(bad.stdout).slice(-1500));
  const err = runCmd(root, cmd, '--checks ZZ9');
  assert.equal(err.status, 2, err.stdout);
  assert.match(err.stdout, /неизвестные проверки или группы: ZZ9/);
});

test('Windows: Proverka_API_1C_zapis.cmd передаёт флаги и ввод — запись с подтверждением, код 0', { skip: !isWin }, async () => {
  const { front, password, clientKey } = await frontWithSecrets();
  fronts.push(front);
  const { root, X } = releaseCopy('oc-rel-zap-');
  fs.mkdirSync(path.join(X, 'runtime'));
  fs.copyFileSync(process.execPath, path.join(X, 'runtime', 'node.exe'));
  fs.writeFileSync(path.join(X, 'parol.txt'), password + '\r\n');
  fs.writeFileSync(path.join(X, 'klyuch.txt'), clientKey + '\r\n');
  fs.writeFileSync(path.join(X, 'nastrojki.json'), JSON.stringify({ baseUrl: front.baseUrl, user: 'pos_hs', passwordFile: 'parol.txt', clientKeyFile: 'klyuch.txt' }));
  const line = `/d /s /c ""${path.join(X, 'Proverka_API_1C_zapis.cmd')}" --allow-http --no-manual"`;
  const r = await new Promise((resolve) => {
    const p = spawn('cmd.exe', [line], { cwd: root, windowsVerbatimArguments: true, stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '';
    p.stdout.setEncoding('utf8');
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { out += d; });
    p.stdin.end(`${front.publication}\r\n`);
    p.on('close', (code) => resolve({ code, out }));
  });
  assert.equal(r.code, 0, r.out.slice(-2500));
  assert.match(r.out, /Режим: с записью/);
  const p = readProtocol(path.join(X, 'protokoly'));
  assert.equal(p.json.mode.writeConfirmed, true);
  assert.ok(front.inner.state.custByExt.size > 0, 'в имитаторе созданы тестовые клиенты');
  assert.deepEqual(leaks([r.out, ...p.texts], secretForms(password, clientKey)), []);
});
