// Сборка релиза программы проверки API 1С: node build.mjs [--no-runtime] [--out <папка>] [--pack <zip заказчика>]
// 1) Node ≥ 24; 2) контракт = 1.2.0 (git blob, sha256); 3) образцы по MANIFEST; 4) YAML → JSON (yaml из pos-api,
// только при сборке); 5) раскладка programma/ (в src/ только .mjs); 6) страж утечки 1.3.0 и отозванного задания
// «ночной обмен» (ТЗ 2.3 отозвано 20.11.2026); 7) самопроверка --demo;
// 8) node.exe + LICENSE (версия, подпись, sha256); 9) zip + SHA256SUMS; 10) проверка zip: состав точно по плану, бит UTF-8,
// распаковка в папку с пробелами и кириллицей, запуск .cmd --demo (вывод UTF-8), .cmd при чужом NODE_OPTIONS и без runtime\.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { writeZip, listFiles } from './tools/zip.mjs';
import { readZip } from './tools/unzip.mjs';
import { CONTRACT_BLOB, CONTRACT_SHA256, gitBlob, sha256 } from './tools/import-customer-pack.mjs';
import { programHash } from './src/contract.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..', '..');
const VERSION = JSON.parse(fs.readFileSync(path.join(HERE, 'package.json'), 'utf8')).version;
const NAME = `Optomstroy_Proverka_API_1C_${VERSION}`;
const NODE_EXE = 'C:/Program Files/nodejs/node.exe';
const NODE_VERSION = 'v24.11.1';
// Точный файл официального node.exe v24.11.1 win-x64: сборка повторяема побайтно, подмена видна сразу.
const NODE_EXE_SHA256 = 'f13ac3ca23248dc389507e8fe38c34489ab7edb3e6d6700eb6da6a0b7e128eaf';
// LICENSE Node.js v24.11.1: найден локально рядом с побайтно тем же node.exe (sha256 f13ac3ca…) в папке драйвера
// Playwright для Go 1.57.0 (ms-playwright-go/1.57.0/); в установке C:/Program Files/nodejs файла LICENSE нет.
const NODE_LICENSE_SHA256 = 'b4c7840e841ab8f14543646bd941d01a459fb0f8ce1249244341b2a63272ca79';
const DEFAULT_OUT = path.join(REPO, '.tmp', 'onec-check', 'release');
const DEFAULT_PACK = path.join(REPO, '.tmp', 'customer-pack', 'Optomstroy_paket_programmistu_1C_2026-11-19.zip');
const GENERIC_WORDS = ['none', 'true', 'false', 'null', 'default', 'string', 'number', 'object', 'array', 'boolean', 'integer'];
const TEXT_EXT = new Set(['.mjs', '.js', '.json', '.txt', '.md', '.cmd', '.yaml', '.html']);

function arg(name, def = null) {
  const i = process.argv.indexOf(name);
  return i > 0 ? process.argv[i + 1] : def;
}
const NO_RUNTIME = process.argv.includes('--no-runtime');
const OUT = path.resolve(arg('--out', DEFAULT_OUT));
const PACK = arg('--pack', DEFAULT_PACK);
const DRAFT = arg('--draft-contract', path.join(REPO, 'contracts', 'onec', 'onec-http-service.v1.yaml'));

const log = (s) => process.stdout.write(s + '\n');
function stop(msg) { log(`СБОРКА ОСТАНОВЛЕНА: ${msg}`); process.exit(1); }
const crlf = (s) => s.replace(/\r?\n/g, '\r\n');

// ---------------------------------------------------------------- 1. Node
const major = Number(process.versions.node.split('.')[0]);
if (major < 24) stop(`нужен Node.js 24 или новее, сейчас ${process.version}`);

// ---------------------------------------------------------------- 2. контракт
const C_DIR = path.join(HERE, 'contract', '1.2.0');
const yamlBuf = fs.readFileSync(path.join(C_DIR, 'onec-http-service.v1.yaml'));
if (gitBlob(yamlBuf) !== CONTRACT_BLOB) stop('git blob контракта не 63995cc4… — это не 1.2.0, переданный заказчику');
if (sha256(yamlBuf) !== CONTRACT_SHA256) stop('sha256 контракта не совпадает с 1.2.0');

// ---------------------------------------------------------------- 3. образцы по манифесту
const manifest = fs.readFileSync(path.join(C_DIR, 'MANIFEST.sha256'), 'utf8').split(/\r?\n/).filter((l) => l && !l.startsWith('#'));
const samples = [];
for (const l of manifest) {
  const [sh, blob, rel] = l.split(/\s+/);
  const buf = fs.readFileSync(path.join(C_DIR, rel));
  if (sha256(buf) !== sh || gitBlob(buf) !== blob) stop(`файл ${rel} не совпадает с манифестом`);
  if (rel.startsWith('obrazcy_json/')) samples.push(rel);
}
const sampleFiles = fs.readdirSync(path.join(C_DIR, 'obrazcy_json')).filter((f) => f.endsWith('.json'));
if (samples.length !== 59 || sampleFiles.length !== 59) stop(`образцов должно быть 59: в манифесте ${samples.length}, в папке ${sampleFiles.length}`);

// ---------------------------------------------------------------- 4. YAML → JSON
let YAML;
try { YAML = createRequire(path.join(REPO, 'pos-api', 'package.json'))('yaml'); } catch { stop('нет модуля yaml: выполните npm ci в pos-api'); }
const doc = YAML.parse(yamlBuf.toString('utf8'));
if (doc.info?.version !== '1.2.0') stop(`info.version контракта ${doc.info?.version}, нужен 1.2.0`);
const contractJson = Buffer.from(JSON.stringify(doc) + '\n', 'utf8');
const SRC_HASH = programHash(path.join(HERE, 'src'));
const meta = { version: '1.2.0', yamlSha256: CONTRACT_SHA256, jsonSha256: sha256(contractJson), gitBlob: CONTRACT_BLOB, builtFrom: 'onec-http-service.v1.yaml 1.2.0 (пакет программисту 1С 2026-11-19)', srcSha256: SRC_HASH };

// ---------------------------------------------------------------- 5. раскладка
// В programma/ идёт весь src/, поэтому в src/ — только модули .mjs (заметки, копии, временные файлы не попадут в архив).
const srcFiles = listFiles(path.join(HERE, 'src')).filter((e) => e.file);
const oddSrc = srcFiles.filter((e) => path.extname(e.name) !== '.mjs');
if (oddSrc.length) stop(`в src/ должны быть только модули .mjs, лишнее: ${oddSrc.map((e) => e.name).join(', ')}`);
fs.mkdirSync(OUT, { recursive: true });
const STAGE = path.join(OUT, NAME);
fs.rmSync(STAGE, { recursive: true, force: true });
const P = path.join(STAGE, 'programma');
fs.mkdirSync(path.join(P, 'contract'), { recursive: true });
fs.mkdirSync(path.join(P, 'obrazcy'), { recursive: true });
// Не fs.cpSync: в Node 24.11.1 под Windows он молча ничего не копирует в папку с кириллицей в пути.
for (const e of srcFiles) {
  const to = path.join(P, ...e.name.split('/'));
  fs.mkdirSync(path.dirname(to), { recursive: true });
  fs.copyFileSync(e.file, to);
}
fs.writeFileSync(path.join(P, 'contract', 'onec-http-service.v1.2.0.json'), contractJson);
fs.writeFileSync(path.join(P, 'contract', 'meta.json'), JSON.stringify(meta, null, 2) + '\n');
for (const f of sampleFiles) fs.copyFileSync(path.join(C_DIR, 'obrazcy_json', f), path.join(P, 'obrazcy', f));
for (const f of ['Proverka_API_1C.cmd', 'Proverka_API_1C_zapis.cmd']) {
  const t = fs.readFileSync(path.join(HERE, 'release', f), 'latin1');
  // eslint-disable-next-line no-control-regex
  if (/[^\x09\x0a\x0d\x20-\x7e]/.test(t)) stop(`${f}: запускатель должен быть только ASCII`);
  fs.writeFileSync(path.join(STAGE, f), crlf(t), 'latin1');
}
fs.writeFileSync(path.join(STAGE, 'ЧИТАЙ_МЕНЯ.txt'), '\uFEFF' + crlf(fs.readFileSync(path.join(HERE, 'release', 'chitai_menya.txt'), 'utf8')), 'utf8');
fs.writeFileSync(path.join(STAGE, 'nastrojki.primer.json'), crlf(fs.readFileSync(path.join(HERE, 'release', 'nastrojki.primer.json'), 'utf8')), 'utf8');
log(`Раскладка: ${STAGE}; программа sha256 ${SRC_HASH}`);

/** programma/*.mjs побайтно равны src/*.mjs (и отпечаток тот же): иначе в архиве не та программа, что проверена тестами. */
function assertProgramMatchesSrc(when) {
  const now = listFiles(path.join(HERE, 'src')).filter((e) => e.file);
  for (const e of now) {
    const to = path.join(P, ...e.name.split('/'));
    if (!fs.existsSync(to) || !fs.readFileSync(to).equals(fs.readFileSync(e.file))) stop(`${when}: programma/${e.name} не совпадает с src/${e.name} — исходники менялись во время сборки, соберите заново`);
  }
  const h = programHash(P);
  if (h !== SRC_HASH || programHash(path.join(HERE, 'src')) !== SRC_HASH) stop(`${when}: отпечаток программы изменился во время сборки — соберите заново`);
}
assertProgramMatchesSrc('после раскладки');

// ---------------------------------------------------------------- 6. страж утечки 1.3.0 и секретов
function docxText(buf) {
  const e = readZip(buf).find((x) => x.name === 'word/document.xml');
  if (!e) return '';
  return e.data().toString('utf8').replace(/<\/w:p>/g, '\n').replace(/<[^>]+>/g, '')
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&');
}
function idents(d) {
  const out = new Set();
  const add = (s) => { if (typeof s === 'string' && s.length >= 4) out.add(s); };
  for (const [p, item] of Object.entries(d.paths || {})) {
    add(p);
    for (const seg of p.split('/')) if (seg && !seg.startsWith('{')) add(seg);
    for (const op of Object.values(item || {})) if (op && typeof op === 'object') { add(op.operationId); for (const prm of op.parameters || []) add(prm.name); }
  }
  for (const n of Object.keys(d.components?.schemas || {})) add(n);
  const walk = (v) => {
    if (Array.isArray(v)) { v.forEach(walk); return; }
    if (v && typeof v === 'object') {
      if (v.properties && typeof v.properties === 'object') for (const k of Object.keys(v.properties)) add(k);
      if (Array.isArray(v.enum)) for (const e of v.enum) add(e);
      for (const x of Object.values(v)) walk(x);
    }
  };
  walk(d.components);
  walk(d.paths);
  return out;
}
function tokensOf(text) {
  const s = new Set();
  for (const m of text.matchAll(/[A-Za-zА-Яа-яЁё_][A-Za-zА-Яа-яЁё0-9_]*/g)) s.add(m[0]);
  for (const m of text.matchAll(/\/pos\/v1\/[A-Za-z0-9_\-/{}]+/g)) {
    const p = m[0].replace(/[?].*$/, '');
    s.add(p);
    for (const seg of p.split('/')) if (seg) s.add(seg);
  }
  return s;
}
const textFiles = listFiles(STAGE).filter((e) => e.file && TEXT_EXT.has(path.extname(e.file).toLowerCase()));
{
  let leaks = 0;
  const leakFiles = new Set();
  const draftPath = DRAFT;
  if (fs.existsSync(draftPath)) {
    const draft = YAML.parse(fs.readFileSync(draftPath, 'utf8'));
    if (draft?.info?.version && draft.info.version !== '1.2.0') {
      const allowed = idents(doc);
      let allowText = '';
      // Разрешённые слова — контракт 1.2.0 и «Требования к API 1С» 1.2. ТЗ «ночной обмен» 2.3 отозвано (20.11.2026):
      // его docx из пакета заказчика в разрешённые не входит — имена его методов в сборке тоже утечка.
      if (PACK && fs.existsSync(PACK)) {
        for (const e of readZip(PACK)) if (e.name.endsWith('.docx') && !/nightly/i.test(e.name)) allowText += '\n' + docxText(e.data());
      } else {
        try { allowText += execFileSync('git', ['show', 'HEAD:docs/integration/1C_API_requirements.md'], { cwd: REPO, encoding: 'utf8', maxBuffer: 64 << 20 }); } catch { /* нет git */ }
        if (!allowText) stop('нет текста «Требований к API 1С» 1.2 для стража утечки (укажите --pack <zip заказчика>)');
      }
      for (const t of tokensOf(allowText)) allowed.add(t);
      for (const t of tokensOf(yamlBuf.toString('utf8'))) allowed.add(t);
      // Общие слова языка и HTML (CSP 'none', true/false) утечкой не считаются.
      for (const w of GENERIC_WORDS) allowed.add(w);
      const suspicious = [...idents(draft)].filter((x) => !allowed.has(x));
      for (const e of textFiles) {
        const t = fs.readFileSync(e.file, 'utf8');
        let hit = 0;
        for (const x of suspicious) {
          const re = new RegExp(`(?<![A-Za-zА-Яа-яЁё0-9_])${x.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&')}(?![A-Za-zА-Яа-яЁё0-9_])`);
          if (re.test(t)) hit++;
        }
        if (hit) { leaks += hit; leakFiles.add(path.relative(STAGE, e.file)); }
      }
      log(`Страж утечки 1.3.0: черновик ${draft.info.version}, новых имён в черновике ${suspicious.length}, совпадений в сборке ${leaks}`);
      if (leaks) stop(`в сборке найдены имена черновика контракта (${leaks}) в файлах: ${[...leakFiles].join(', ')}`);
    } else log('Страж утечки 1.3.0: контракт рабочего дерева — 1.2.0, проверять нечего');
  } else log('Страж утечки 1.3.0: черновика контракта нет');
  // Отозванное задание «ночной обмен» (ТЗ 2.3) и черновик 1.3.0: ни ссылок, ни методов в сборке. Одна строка истории
  // версий в ЧИТАЙ_МЕНЯ.txt («проверки ночного обмена убраны: ТЗ 2.3 отозвано 20.11.2026») разрешена.
  const HISTORY_LINE = 'проверки ночного обмена убраны: ТЗ 2.3 отозвано 20.11.2026';
  const WITHDRAWN = [/ТЗ\s*2\.3/, /ночн\S*\s+обмен/i, /(?<![\d.])1\.3\.0(?![\d.])/, /\/pos\/v1\/(?:prices|stock|receivables|sales|sale-returns|advance-refunds|stock-documents)(?![\w/{-])/, /tz23|PENDING_13/i];
  for (const e of textFiles) {
    const t = fs.readFileSync(e.file, 'utf8').split(HISTORY_LINE).join(' ');
    const hit = WITHDRAWN.find((re) => re.test(t));
    if (hit) stop(`в сборке материал отозванного задания или черновика 1.3.0 (${hit}) в файле ${path.relative(STAGE, e.file)}`);
  }
  log('Страж отозванного задания: ссылок на ТЗ 2.3, ночной обмен, 1.3.0 и методы срезов в сборке нет');
  for (const e of textFiles) {
    const t = fs.readFileSync(e.file, 'utf8');
    if (/-----BEGIN [A-Z ]*PRIVATE KEY-----/.test(t)) stop(`закрытый ключ PEM в ${path.relative(STAGE, e.file)}`);
    if (/"(password|clientKey|token)"\s*:\s*"[^"]+"/.test(t)) stop(`непустой пароль, ключ или токен в ${path.relative(STAGE, e.file)}`);
  }
}

// ---------------------------------------------------------------- 7. самопроверка
const SELF = path.join(OUT, 'selfcheck');
fs.rmSync(SELF, { recursive: true, force: true });
{
  const r = spawnSync(process.execPath, [path.join(P, 'main.mjs'), '--demo', '--no-manual', '--out', SELF], { encoding: 'utf8', timeout: 300000, input: '' });
  if (r.status !== 0) { log(r.stdout.slice(-3000)); stop(`самопроверка --demo: код ${r.status}, нужен 0`); }
  const js = fs.readdirSync(SELF).filter((f) => f.endsWith('.json'));
  if (js.length !== 1) stop('самопроверка: нет протокола JSON');
  const m = JSON.parse(fs.readFileSync(path.join(SELF, js[0]), 'utf8'));
  if (m.format !== 'optomstroy-onec-check-protocol' || m.formatVersion !== 2 || m.exitCode !== 0 || m.summary.FAIL) stop('самопроверка: протокол не по формату или есть ошибки');
  log(`Самопроверка --demo: код 0, ПРОЙДЕНО ${m.summary.PASS}, ОШИБКА ${m.summary.FAIL}`);
}

// ---------------------------------------------------------------- 8. среда выполнения
if (!NO_RUNTIME) {
  if (process.platform !== 'win32') stop('node.exe собирается только на Windows (или --no-runtime)');
  if (!fs.existsSync(NODE_EXE)) stop(`нет ${NODE_EXE}`);
  const v = execFileSync(NODE_EXE, ['--version'], { encoding: 'utf8' }).trim();
  if (v !== NODE_VERSION) stop(`node.exe ${v}, ожидается ${NODE_VERSION}`);
  const ps = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
    `$s = Get-AuthenticodeSignature -LiteralPath '${NODE_EXE}'; "$($s.Status)|$($s.SignerCertificate.Subject)"`], { encoding: 'utf8' });
  const [st, subj] = String(ps.stdout || '').trim().split('|');
  if (st !== 'Valid' || !/CN=OpenJS Foundation/.test(subj || '')) stop(`подпись node.exe: ${st || '?'} ${subj || ''}`);
  const exeSha = sha256(fs.readFileSync(NODE_EXE));
  if (exeSha !== NODE_EXE_SHA256) stop(`node.exe ${v} не тот файл: sha256 ${exeSha}, ожидается ${NODE_EXE_SHA256}`);
  const licBuf = fs.readFileSync(path.join(HERE, 'release', 'node-LICENSE.txt'));
  if (sha256(licBuf) !== NODE_LICENSE_SHA256) stop('release/node-LICENSE.txt не совпадает с LICENSE Node.js v24.11.1 (sha256 b4c7840e…)');
  log(`node.exe ${v}: подпись Valid, ${subj.split(',')[0]}, sha256 ${exeSha.slice(0, 16)}…; LICENSE — дистрибутив ${NODE_VERSION}`);
  fs.mkdirSync(path.join(STAGE, 'runtime'), { recursive: true });
  fs.copyFileSync(NODE_EXE, path.join(STAGE, 'runtime', 'node.exe'));
  fs.writeFileSync(path.join(STAGE, 'runtime', 'LICENSE'), licBuf);
  fs.writeFileSync(path.join(STAGE, 'runtime', 'ИСТОЧНИК_ЛИЦЕНЗИИ.txt'), '\uFEFF' + crlf(
    `node.exe — официальный Node.js ${NODE_VERSION} для Windows x64 (цифровая подпись OpenJS Foundation). LICENSE — текст лицензии Node.js ${NODE_VERSION} (условия Node.js и входящих в него библиотек); он лежал рядом с побайтно тем же node.exe ${NODE_VERSION} в комплекте драйвера Playwright 1.57.0 — в установке Node.js для Windows отдельного файла LICENSE нет.\n`), 'utf8');
}

// ---------------------------------------------------------------- SHA256SUMS внутри
assertProgramMatchesSrc('перед архивом');
// Стандартный вид «<sha256> *<путь>», UTF-8 без BOM, строки LF: читают sha256sum -c и Блокнот Windows 10/11.
{
  const files = listFiles(STAGE).filter((e) => e.file).map((e) => e.name).sort();
  const lines = files.map((n) => `${sha256(fs.readFileSync(path.join(STAGE, n)))} *${n}`);
  fs.writeFileSync(path.join(STAGE, 'SHA256SUMS.txt'), lines.join('\n') + '\n', 'utf8');
}

// ---------------------------------------------------------------- 9. zip
const ZIP = path.join(OUT, `${NAME}${NO_RUNTIME ? '_bez_runtime' : ''}.zip`);
const entries = [{ name: `${NAME}/`, dir: true }, ...listFiles(STAGE, NAME)];
const t0 = Date.now();
const z = writeZip(ZIP, entries);
const zipSha = sha256(fs.readFileSync(ZIP));
fs.writeFileSync(path.join(OUT, 'SHA256SUMS'), `${zipSha} *${path.basename(ZIP)}\n`);
log(`Архив: ${ZIP} (${(z.size / 1048576).toFixed(1)} МБ, записей ${z.entries}, ${Math.round((Date.now() - t0) / 1000)} с), sha256 ${zipSha}`);

// ---------------------------------------------------------------- 10. проверка zip
{
  const list = readZip(ZIP);
  const names = list.map((e) => e.name);
  // Состав — точно по плану: ни одного лишнего и ни одного недостающего файла.
  const planned = new Set([
    'Proverka_API_1C.cmd', 'Proverka_API_1C_zapis.cmd', 'ЧИТАЙ_МЕНЯ.txt', 'nastrojki.primer.json', 'SHA256SUMS.txt',
    ...srcFiles.map((e) => `programma/${e.name}`),
    'programma/contract/onec-http-service.v1.2.0.json', 'programma/contract/meta.json',
    ...sampleFiles.map((f) => `programma/obrazcy/${f}`),
    ...(NO_RUNTIME ? [] : ['runtime/node.exe', 'runtime/LICENSE', 'runtime/ИСТОЧНИК_ЛИЦЕНЗИИ.txt']),
  ].map((f) => `${NAME}/${f}`));
  const zipFiles = names.filter((n) => !n.endsWith('/'));
  const extra = zipFiles.filter((n) => !planned.has(n));
  const missing = [...planned].filter((n) => !zipFiles.includes(n));
  if (extra.length || missing.length) stop(`состав архива не по плану: лишние — ${extra.join(', ') || 'нет'}; не хватает — ${missing.join(', ') || 'нет'}`);
  if (!NO_RUNTIME && sha256(list.find((e) => e.name === `${NAME}/runtime/node.exe`).data()) !== NODE_EXE_SHA256) stop('node.exe в архиве не совпадает с оригиналом');
  if (names.filter((n) => n.startsWith(`${NAME}/programma/obrazcy/`) && n.endsWith('.json')).length !== 59) stop('в архиве не 59 образцов');
  for (const e of list) if (/[^\x20-\x7e]/.test(e.name) && !e.utf8) stop(`имя без флага UTF-8: ${e.name}`);
  if (names.some((n) => !n.startsWith(`${NAME}/`))) stop('в корне архива должна быть одна папка');
  if (names.some((n) => /\/(test|tools)\//.test(n) || n.endsWith('build.mjs'))) stop('в архив попали test/, tools/ или build.mjs');
  const readme = list.find((e) => e.name === `${NAME}/ЧИТАЙ_МЕНЯ.txt`).data();
  if (readme[0] !== 0xef || readme[1] !== 0xbb || readme[2] !== 0xbf) stop('ЧИТАЙ_МЕНЯ.txt без BOM');
  log(`Проверка архива: записей ${list.length}, имена и флаг UTF-8 в порядке`);
  if (!NO_RUNTIME && process.platform === 'win32') {
    // Отдельная папка на каждый прогон: Windows может ненадолго удерживать удаляемые каталоги.
    const TESTROOT = path.join(OUT, `zip-test-${Date.now()}`);
    const X = path.join(TESTROOT, 'Тест папка (1)', 'Проверка API 1С');
    fs.mkdirSync(X, { recursive: true });
    const ex = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
      `$ErrorActionPreference='Stop'; Expand-Archive -LiteralPath $env:ZIPF -DestinationPath $env:DEST -Force`],
    { encoding: 'utf8', env: { ...process.env, ZIPF: ZIP, DEST: X }, timeout: 600000 });
    if (ex.status !== 0) stop(`Expand-Archive: ${ex.stderr || ex.stdout}`);
    const root = path.join(X, NAME);
    if (!fs.existsSync(path.join(root, 'ЧИТАЙ_МЕНЯ.txt'))) stop('после Expand-Archive нет ЧИТАЙ_МЕНЯ.txt (имя искажено?)');
    const outDir = path.join(root, 'protokoly test');
    // Полный путь в кавычках (как при двойном щелчке); cmd /s /c ""…"" — пробелы, кириллица и скобки в пути.
    const runCmd = (cmdFile, args, env = process.env) => {
      const r = spawnSync('cmd.exe', [`/d /s /c ""${cmdFile}" ${args}"`], { cwd: X, timeout: 300000, input: '', windowsVerbatimArguments: true, env });
      let text = null;
      try { text = new TextDecoder('utf-8', { fatal: true }).decode(r.stdout); } catch { /* не UTF-8 */ }
      return { status: r.status, text, raw: String(r.stdout) };
    };
    const run = runCmd(path.join(root, 'Proverka_API_1C.cmd'), `--demo --no-manual --out "${outDir}"`);
    if (run.status !== 0) { log(run.raw.slice(-2000)); stop(`запуск Proverka_API_1C.cmd --demo из «${X}»: код ${run.status}`); }
    if (run.text === null || !run.text.includes('Итог: ошибок нет')) stop('вывод Proverka_API_1C.cmd --demo — не UTF-8 или без строки «Итог: ошибок нет»');
    const prot = fs.existsSync(outDir) ? fs.readdirSync(outDir).filter((f) => f.endsWith('.html')) : [];
    if (!prot.length) stop('после запуска .cmd нет протокола');
    log(`Запуск из папки с пробелами и кириллицей: Proverka_API_1C.cmd --demo → код 0, вывод UTF-8, протокол ${prot[0]}`);
    // NODE_OPTIONS и NODE_TLS_REJECT_UNAUTHORIZED компьютера заказчика не должны влиять на программу.
    const hostile = { ...process.env, NODE_OPTIONS: `--require "${path.join(TESTROOT, 'net-takogo-fajla.cjs')}"`, NODE_TLS_REJECT_UNAUTHORIZED: '0' };
    const v2 = runCmd(path.join(root, 'Proverka_API_1C.cmd'), '--version', hostile);
    if (v2.status !== 0 || !String(v2.text).includes('контракт onec-http-service 1.2.0')) stop(`запускатель не защищён от NODE_OPTIONS компьютера: код ${v2.status}`);
    // Запускатель без папок runtime и programma (запуск из окна архива) — понятное сообщение и код 2.
    const ALONE = path.join(TESTROOT, 'только запускатель');
    fs.mkdirSync(ALONE);
    fs.copyFileSync(path.join(root, 'Proverka_API_1C.cmd'), path.join(ALONE, 'Proverka_API_1C.cmd'));
    const a = runCmd(path.join(ALONE, 'Proverka_API_1C.cmd'), '--demo');
    if (a.status !== 2 || !String(a.text).includes('OSHIBKA')) stop(`запускатель без runtime: код ${a.status}, нужен 2 с сообщением`);
    log('Запускатель: NODE_OPTIONS компьютера не мешает (код 0); без runtime\\ и programma\\ — сообщение и код 2');
    fs.rmSync(TESTROOT, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
  }
}
fs.rmSync(SELF, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
assertProgramMatchesSrc('в конце сборки');
fs.writeFileSync(path.join(OUT, 'BUILD_INFO.txt'), `${path.basename(ZIP)}\nsha256 архива ${zipSha}\nпрограмма sha256 ${SRC_HASH}\nсобрано ${new Date().toISOString()}\n`);
log(`ГОТОВО: ${ZIP}; программа sha256 ${SRC_HASH}`);
void crypto;
