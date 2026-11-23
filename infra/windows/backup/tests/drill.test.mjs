// Проверка restore-drill.ps1 и restore.ps1 на настоящем PostgreSQL 17 (@embedded-postgres) без официальных psql и
// pg_restore: их заменяет fakepg (tests/fakepg.mjs за fakepg.exe, собранным csc.exe) — SQL выполняет настоящий сервер,
// «дамп» — зашифрованный OPTBK1 SQL-текст. Проверяются скрипты вокруг pg_restore: временный кластер и уборка
// (DATA-06), роли через apply-roles.ps1 без открытых паролей в журнале сервера, локаль и стоп-проверка (DATA-04),
// восстановление всех mediaDirs, включая audit-anchors (DATA-05).
// Порты 55445 (временный кластер проверки) и 55446 («рабочий» кластер для restore.ps1). Временные данные —
// .tmp/wn-backup/drill (удаляются; WN_BACKUP_KEEP=1 — оставить).
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

import { encryptStream, generateKeyPair, loadPublicKey } from '../lib/optbk.mjs';
import { writeSidecars } from '../lib/jobs.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(here, '..', '..', '..', '..');
const KIT = path.resolve(here, '..');
const NATIVE = path.join(REPO, 'pos-api', 'node_modules', '@embedded-postgres', 'windows-x64', 'native');
const TMP = process.env.WN_BACKUP_DRILL_TMP || path.join(REPO, '.tmp', 'wn-backup', 'drill');
const CSC = 'C:\\Windows\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe';
const require = createRequire(path.join(REPO, 'pos-api', 'package.json'));
const { Client } = require('pg');

const PORT_DRILL = 55445;
const PORT_PROD = 55446;
const SUPER_PW = 'drill-super-pass-55446'; // check-secrets: allow — пароль временного тестового кластера
const APP_PW = 'drill-app-pass-0123456789'; // check-secrets: allow — пароль временного тестового кластера
const MIG_PW = 'drill-mig-pass-0123456789'; // check-secrets: allow — пароль временного тестового кластера
const BK_PW = 'drill-bk-pass-01234567890'; // check-secrets: allow — пароль временного тестового кластера

const D = {
  pgfake: path.join(TMP, 'pgfake'),
  bin: path.join(TMP, 'pgfake', 'bin'),
  backups: path.join(TMP, 'backups'),
  inst: path.join(TMP, 'inst'),
  secrets: path.join(TMP, 'inst', 'secrets'),
  cfg: path.join(TMP, 'inst', 'config', 'backup.json'),
  prod: path.join(TMP, 'pg-prod'),
  prodLog: path.join(TMP, 'pg-prod.log'),
  work: path.join(TMP, 'work'),
};
let pubFile;
let privFile;

const FAKE_CS = `using System; using System.Diagnostics; using System.IO; using System.Text;
class P {
  static string Q(string s) {
    if (s.Length > 0 && s.IndexOfAny(new[] { ' ', '\\t', '"' }) < 0) return s;
    var b = new StringBuilder("\\""); int bs = 0;
    foreach (char ch in s) {
      if (ch == '\\\\') { bs++; continue; }
      if (ch == '"') { b.Append('\\\\', 2 * bs + 1); b.Append('"'); } else { b.Append('\\\\', bs); b.Append(ch); }
      bs = 0;
    }
    b.Append('\\\\', 2 * bs); b.Append('"'); return b.ToString();
  }
  static int Main(string[] a) {
    string me = Path.GetFileNameWithoutExtension(Environment.GetCommandLineArgs()[0]).ToLowerInvariant();
    var sb = new StringBuilder(Q(Environment.GetEnvironmentVariable("FAKEPG_SCRIPT"))).Append(' ').Append(me);
    foreach (var x in a) sb.Append(' ').Append(Q(x));
    var psi = new ProcessStartInfo(Environment.GetEnvironmentVariable("FAKEPG_NODE"), sb.ToString()) { UseShellExecute = false };
    var p = Process.Start(psi); p.WaitForExit(); return p.ExitCode;
  }
}`;

const DUMP_SQL = `CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA pos_meta AUTHORIZATION pos_migrate;
CREATE TABLE pos_meta.schema_migrations (version text PRIMARY KEY);
ALTER TABLE pos_meta.schema_migrations OWNER TO pos_migrate;
INSERT INTO pos_meta.schema_migrations VALUES ('0001'), ('0042');
${['products', 'product_variants', 'customers', 'orders', 'payments', 'audit_logs'].map((t) => `CREATE TABLE public.${t} (id int PRIMARY KEY, note text);
ALTER TABLE public.${t} OWNER TO pos_migrate;`).join('\n')}
GRANT SELECT ON public.products TO pos_app;
INSERT INTO public.products SELECT g, 'Товар ' || g FROM generate_series(1, 7) g;
`;

function sh(file, args, opts = {}) {
  const r = spawnSync(file, args, { encoding: 'utf8', ...opts });
  if (r.status !== 0) throw new Error(`${path.basename(file)} ${args.join(' ')} → ${r.status}\n${r.stdout}\n${r.stderr}`);
  return r;
}

function portFree(port) {
  return new Promise((resolve) => {
    const s = net.createServer();
    s.once('error', () => resolve(false));
    s.listen(port, '127.0.0.1', () => s.close(() => resolve(true)));
  });
}

async function makeDump(name, sql) {
  const dir = path.join(D.backups, 'dumps');
  fs.mkdirSync(dir, { recursive: true });
  const out = path.join(dir, name);
  await pipeline(Readable.from([Buffer.from(sql, 'utf8')]), encryptStream(loadPublicKey(pubFile), { chunkSize: 4096 }), fs.createWriteStream(out));
  await writeSidecars(out, { kind: 'dump', format: 'OPTBK1', content: 'test SQL', database: 'optomstroy', createdUtc: new Date().toISOString() });
  return out;
}

const env = () => ({ ...process.env, FAKEPG_NODE: process.execPath, FAKEPG_SCRIPT: path.join(here, 'fakepg.mjs'), PGPASSWORD: '', PGPASSFILE: '' });

function ps(script, args) {
  const r = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(KIT, script), ...args],
    { encoding: 'utf8', env: env(), timeout: 600000 });
  fs.appendFileSync(path.join(TMP, `${script}.log`), `\n===== ${args.join(' ')}\n${r.stdout}\n${r.stderr}`);
  return r;
}

const readStatusJson = () => JSON.parse(fs.readFileSync(path.join(D.backups, 'state', 'status.json'), 'utf8'));

before(async () => {
  fs.rmSync(TMP, { recursive: true, force: true });
  fs.mkdirSync(TMP, { recursive: true });
  for (const sub of ['bin', 'lib', 'share']) fs.cpSync(path.join(NATIVE, sub), path.join(D.pgfake, sub), { recursive: true });
  fs.writeFileSync(path.join(TMP, 'fakepg.cs'), FAKE_CS);
  for (const n of ['psql', 'pg_restore']) sh(CSC, ['/nologo', `/out:${path.join(D.bin, `${n}.exe`)}`, path.join(TMP, 'fakepg.cs')]);
  const K = generateKeyPair(null);
  pubFile = path.join(TMP, 'pub.pem');
  privFile = path.join(TMP, 'keyholder', 'backup-private.pem');
  fs.mkdirSync(path.dirname(privFile), { recursive: true });
  fs.writeFileSync(pubFile, K.publicKey);
  fs.writeFileSync(privFile, K.privateKey);
  fs.mkdirSync(D.secrets, { recursive: true });
  fs.mkdirSync(path.dirname(D.cfg), { recursive: true });
  fs.writeFileSync(D.cfg, JSON.stringify({
    backupRoot: D.backups, pgBin: D.bin, publicKeyFile: pubFile, walSpoolDir: path.join(D.inst, 'data', 'walspool'),
    pg: { host: '127.0.0.1', port: PORT_PROD, user: 'pos_backup', database: 'optomstroy', credentialFile: path.join(D.secrets, 'pgpass_backup.conf') },
    mediaDirs: [{ name: 'media', path: path.join(D.inst, 'data', 'media') }, { name: 'audit-anchors', path: path.join(D.inst, 'data', 'audit-anchors') }],
    offsite: null, healthchecksUrlFile: null,
  }, null, 2));
});

after(() => {
  try {
    sh(path.join(D.bin, 'pg_ctl.exe'), ['stop', '-D', D.prod, '-m', 'immediate', '-w']);
  } catch {
    /* не запущен */
  }
  if (process.env.WN_BACKUP_KEEP !== '1') fs.rmSync(TMP, { recursive: true, force: true });
});

test('restore-drill.ps1 -DevTest: копия восстанавливается во временный кластер, всё временное удалено, итог в status (DATA-06)', { timeout: 600000, skip: !fs.existsSync(CSC) && 'нет csc.exe' }, async () => {
  const dump = await makeDump('20261120-003000.dump.optbk', DUMP_SQL);
  const work = path.join(D.work, 'ok');
  const r = ps('restore-drill.ps1', ['-DevTest', '-KeyFile', privFile, '-BackupConfig', D.cfg, '-PgBin', D.bin, '-Port', String(PORT_DRILL),
    '-WorkDir', work, '-NodeExe', process.execPath]);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /products\s+7/, 'число строк ключевой таблицы в выводе');
  assert.match(r.stdout, /последняя миграция: 0042/);
  assert.match(r.stdout, new RegExp(path.basename(dump).replace(/\./g, '\\.')), 'выбран самый новый дамп');
  assert.ok(!fs.existsSync(work), 'папка временного кластера удалена');
  assert.ok(await portFree(PORT_DRILL), 'временный кластер остановлен');
  const st = readStatusJson();
  assert.equal(st.lastRestoreDrill.result, 'ok');
  assert.equal(st.lastRestoreDrill.dump, path.basename(dump));
  assert.ok(st.lastRestoreDrillOkUtc);
  const s = spawnSync(process.execPath, [path.join(KIT, 'pos-backup.mjs'), 'status', '--config', D.cfg, '--no-db'], { encoding: 'utf8' });
  const sj = JSON.parse(s.stdout);
  assert.ok(!sj.problems.includes('restore-drill-failed') && !sj.problems.includes('restore-drill-older-35d'), sj.problems.join(','));
  assert.ok(sj.problems.includes('offsite-not-configured') && sj.problems.includes('alerting-not-configured'), 'риски настройки видны (DATA-02)');
});

test('restore-drill.ps1 -DevTest: копия без журнала миграций — код 1, кластер остановлен, папка удалена, restore-drill-failed', { timeout: 600000, skip: !fs.existsSync(CSC) && 'нет csc.exe' }, async () => {
  const dump = await makeDump('20261119-003000.dump.optbk', 'CREATE TABLE public.products (id int);\n');
  const work = path.join(D.work, 'bad');
  const r = ps('restore-drill.ps1', ['-DevTest', '-KeyFile', privFile, '-DumpFile', dump, '-BackupConfig', D.cfg, '-PgBin', D.bin,
    '-Port', String(PORT_DRILL), '-WorkDir', work, '-NodeExe', process.execPath]);
  assert.equal(r.status, 1, r.stdout + r.stderr);
  assert.match(r.stdout, /ПРОВЕРКА НЕ ПРОЙДЕНА: .*schema_migrations/);
  assert.ok(!fs.existsSync(work), 'папка временного кластера удалена и после ошибки');
  assert.ok(await portFree(PORT_DRILL), 'временный кластер остановлен и после ошибки');
  const st = readStatusJson();
  assert.equal(st.lastRestoreDrill.result, 'fail');
  assert.match(st.lastRestoreDrill.detail, /schema_migrations/);
  const s = spawnSync(process.execPath, [path.join(KIT, 'pos-backup.mjs'), 'status', '--config', D.cfg, '--no-db'], { encoding: 'utf8' });
  assert.ok(JSON.parse(s.stdout).problems.includes('restore-drill-failed'));
});

test('restore.ps1 -DevTest: роли через apply-roles.ps1 (SCRAM, без открытых паролей в журнале), локаль, фото и audit-anchors (DATA-04, DATA-05)', { timeout: 900000, skip: !fs.existsSync(CSC) && 'нет csc.exe' }, async () => {
  // «рабочий» кластер после потери сервера: ролей программы нет, есть прежняя база optomstroy с меткой
  const pwFile = path.join(TMP, 'super-pw.txt');
  fs.writeFileSync(pwFile, SUPER_PW);
  sh(path.join(D.bin, 'initdb.exe'), ['-D', D.prod, '-U', 'postgres', `--pwfile=${pwFile}`, '--auth=scram-sha-256', '-E', 'UTF8',
    '--locale-provider=builtin', '--builtin-locale=C.UTF-8', '--locale=C', '--lc-ctype=en-US', '--no-sync']);
  fs.rmSync(pwFile);
  // журнал всех операторов: открытый пароль в ALTER ROLE … PASSWORD попал бы сюда
  sh(path.join(D.bin, 'pg_ctl.exe'), ['start', '-D', D.prod, '-l', D.prodLog, '-w', '-o',
    `-p ${PORT_PROD} -c listen_addresses=127.0.0.1 -c shared_preload_libraries=pg_stat_statements -c log_statement=all -c log_min_duration_statement=0`],
  { stdio: 'ignore' });
  const su = new Client({ host: '127.0.0.1', port: PORT_PROD, user: 'postgres', password: SUPER_PW, database: 'postgres' });
  await su.connect();
  await su.query('CREATE DATABASE optomstroy');
  const old = new Client({ host: '127.0.0.1', port: PORT_PROD, user: 'postgres', password: SUPER_PW, database: 'optomstroy' });
  await old.connect();
  await old.query('CREATE TABLE before_marker (x int)');
  await old.end();

  fs.writeFileSync(path.join(D.secrets, 'pg_password'), SUPER_PW);
  fs.writeFileSync(path.join(D.secrets, 'db_migrator_password'), MIG_PW);
  fs.writeFileSync(path.join(D.secrets, 'db_backup_password'), BK_PW);
  fs.writeFileSync(path.join(D.secrets, 'database_url'), `postgres://pos_app:${APP_PW}@127.0.0.1:${PORT_PROD}/optomstroy\n`);
  const superPass = path.join(TMP, 'pgpass-super.conf');
  fs.writeFileSync(superPass, `127.0.0.1:${PORT_PROD}:*:postgres:${SUPER_PW}\n`);
  // копии фото и отметок аудита в корне копий
  fs.mkdirSync(path.join(D.backups, 'media', 'media', 'sub'), { recursive: true });
  fs.writeFileSync(path.join(D.backups, 'media', 'media', 'sub', 'photo-1.jpg'), 'jpg');
  fs.mkdirSync(path.join(D.backups, 'media', 'audit-anchors'), { recursive: true });
  fs.writeFileSync(path.join(D.backups, 'media', 'audit-anchors', 'anchor-20261120.json'), '{"head":"abc"}');

  const dump = await makeDump('20261121-003000.dump.optbk', DUMP_SQL);
  const r = ps('restore.ps1', ['-DevTest', '-DumpFile', dump, '-KeyFile', privFile, '-InstallRoot', D.inst, '-BackupConfig', D.cfg,
    '-SecretsDir', D.secrets, '-ApiDir', path.join(REPO, 'pos-api'), '-PgBin', D.bin, '-Port', String(PORT_PROD), '-SuperPassFile', superPass,
    '-NodeExe', process.execPath]);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /стоп-проверка lower\('ЁЯ'\) = 'ёя': пройдена/);

  // роли: эталон roles.sql, пароли — верификаторы SCRAM, вход pos_app по паролю из database_url
  const roles = await su.query(`SELECT rolname, rolsuper, rolbypassrls, rolreplication, left(rolpassword, 14) AS pw FROM pg_authid
                                 WHERE rolname IN ('pos_migrate', 'pos_app', 'pos_backup') ORDER BY rolname`);
  assert.equal(roles.rows.length, 3);
  for (const x of roles.rows) {
    assert.equal(x.pw, 'SCRAM-SHA-256$', `${x.rolname}: пароль — верификатор SCRAM`);
    assert.equal(x.rolsuper, false);
    assert.equal(x.rolbypassrls, false);
    assert.equal(x.rolreplication, x.rolname === 'pos_backup');
  }
  const db = await su.query("SELECT datlocprovider, datlocale, datcollate, datctype FROM pg_database WHERE datname = 'optomstroy'");
  assert.deepEqual(db.rows[0], { datlocprovider: 'b', datlocale: 'C.UTF-8', datcollate: 'C', datctype: 'en-US' });
  const before = await su.query("SELECT datname FROM pg_database WHERE datname LIKE 'optomstroy_before_%'");
  assert.equal(before.rows.length, 1, 'прежняя база переименована');
  await su.end();
  const app = new Client({ host: '127.0.0.1', port: PORT_PROD, user: 'pos_app', password: APP_PW, database: 'optomstroy' });
  await app.connect();
  assert.equal(Number((await app.query('SELECT count(*) AS n FROM public.products')).rows[0].n), 7);
  await app.end();

  // в журнале сервера (log_statement = all) нет ни одного открытого пароля
  const log = fs.readFileSync(D.prodLog, 'utf8');
  assert.match(log, /ALTER ROLE pos_app/, 'журнал операторов включён');
  for (const pw of [APP_PW, MIG_PW, BK_PW]) assert.ok(!log.includes(pw), 'открытый пароль роли попал в журнал PostgreSQL');

  // фото и отметки аудита — все mediaDirs из backup.json
  assert.equal(fs.readFileSync(path.join(D.inst, 'data', 'media', 'sub', 'photo-1.jpg'), 'utf8'), 'jpg');
  assert.equal(fs.readFileSync(path.join(D.inst, 'data', 'audit-anchors', 'anchor-20261120.json'), 'utf8'), '{"head":"abc"}');
});

test('restore.ps1: база в database_url не совпадает с -Database — отказ до любых изменений', { timeout: 300000, skip: !fs.existsSync(CSC) && 'нет csc.exe' }, async () => {
  const dump = path.join(D.backups, 'dumps', '20261121-003000.dump.optbk');
  const r = ps('restore.ps1', ['-DevTest', '-DumpFile', dump, '-KeyFile', privFile, '-InstallRoot', D.inst, '-BackupConfig', D.cfg,
    '-SecretsDir', D.secrets, '-ApiDir', path.join(REPO, 'pos-api'), '-PgBin', D.bin, '-Port', String(PORT_PROD), '-Database', 'optomstroy_copy',
    '-NodeExe', process.execPath]);
  assert.equal(r.status, 1, r.stdout + r.stderr);
  assert.match(r.stdout, /не совпадает с -Database optomstroy_copy/);
  assert.doesNotMatch(r.stdout, /== 1\./, 'до проверки копии и подключения дело не дошло');
});
