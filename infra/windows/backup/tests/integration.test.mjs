// Интеграционная проверка на настоящем PostgreSQL 17 (встроенные двоичные файлы pos-api/node_modules/@embedded-postgres).
// Порты 55440–55449. Временные данные — .tmp/wn-backup/it (удаляются в конце, если не задано WN_BACKUP_KEEP=1).
//
// Что проверяется по-настоящему:
//   - archive_command = pos-backup.mjs wal-archive (кластер с archive_mode=on пишет WAL в спул, failed_count = 0);
//   - wal-ship: спул → gzip → OPTBK1 в pitr\<system_identifier>\wal, спул пуст;
//   - служба daemon: ежедневный прогон по расписанию, копия вне сервера, фото, штатная остановка по концу stdin;
//   - restore-pitr.ps1 -DevTest: восстановление на момент между двумя вставками (есть только первая) и -Latest
//     (есть обе), с закрытым ключом под парольной фразой.
// Ограничение стенда: в наборе @embedded-postgres нет pg_dump, pg_restore, psql и pg_basebackup (только initdb,
// pg_ctl, postgres). Поэтому базовая копия делается здесь низкоуровневым API PostgreSQL (pg_backup_start /
// pg_backup_stop, копия файлов, tar.exe) и шифруется тем же конвейером pos-backup (encryptChildToFile); цепочка
// дамп → pg_restore на этом ПК не исполняется (см. README, «Что проверено»).
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

import { generateKeyPair } from '../lib/optbk.mjs';
import { encryptChildToFile, writeSidecars } from '../lib/jobs.mjs';
import { loadConfig, stamp } from '../lib/common.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(here, '..', '..', '..', '..');
const TOOL = path.join(here, '..', 'pos-backup.mjs');
const PGBIN = process.env.WN_PG_BIN || path.join(REPO, 'pos-api', 'node_modules', '@embedded-postgres', 'windows-x64', 'native', 'bin');
const TMP = process.env.WN_BACKUP_IT_TMP || path.join(REPO, '.tmp', 'wn-backup', 'it');
const require = createRequire(path.join(REPO, 'pos-api', 'package.json'));
const { Client } = require('pg');

const PORT = 55441;
const PORT_PITR = 55442;
const PORT_LATEST = 55443;
const SUPER_PW = 'it-super-pass-55441'; // check-secrets: allow — пароль временного тестового кластера
const BACKUP_PW = 'it-backup-pass-55441'; // check-secrets: allow — пароль временного тестового кластера
const PASSPHRASE = 'it-key-passphrase-123'; // check-secrets: allow — парольная фраза тестового ключа

const D = {
  data: path.join(TMP, 'pg1'),
  log: path.join(TMP, 'pg1.log'),
  spool: path.join(TMP, 'walspool'),
  backups: path.join(TMP, 'backups'),
  offsite: path.join(TMP, 'offsite'),
  media: path.join(TMP, 'media'),
  keys: path.join(TMP, 'keys'),
  cfg: path.join(TMP, 'backup.json'),
  pitrData: path.join(TMP, 'pg-pitr'),
  latestData: path.join(TMP, 'pg-latest'),
  pglogs: path.join(TMP, 'pglogs'),
  officialPitr: path.join(TMP, 'pg-official-pitr'),
};

const exe = (n) => path.join(PGBIN, `${n}.exe`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function sh(file, args, opts = {}) {
  const r = spawnSync(file, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], ...opts });
  if (r.status !== 0) throw new Error(`${path.basename(file)} ${args.join(' ')} → ${r.status}\n${r.stdout}\n${r.stderr}`);
  return r;
}

async function client(port, database = 'optomstroy', user = 'postgres', password = SUPER_PW) {
  const c = new Client({ host: '127.0.0.1', port, user, password, database });
  await c.connect();
  return c;
}

function pgStop(dir) {
  if (fs.existsSync(path.join(dir, 'postmaster.pid'))) spawnSync(exe('pg_ctl'), ['stop', '-D', dir, '-m', 'fast', '-w'], { stdio: 'ignore' });
}

let cfg;

before(() => {
  for (const d of [D.data, D.pitrData, D.latestData, D.officialPitr]) pgStop(d);
  fs.rmSync(TMP, { recursive: true, force: true });
  for (const d of [D.spool, D.backups, D.offsite, path.join(D.media, 'sub'), D.keys]) fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(D.media, 'sub', 'photo-1.jpg'), Buffer.alloc(5000, 7));
  // ключи держателя: закрытый — под парольной фразой
  const kp = generateKeyPair(PASSPHRASE);
  fs.writeFileSync(path.join(D.keys, 'backup-private.pem'), kp.privateKey);
  fs.writeFileSync(path.join(D.keys, 'backup-public.pem'), kp.publicKey);
  fs.writeFileSync(path.join(TMP, 'pgpass.conf'), `127.0.0.1:${PORT}:*:pos_backup:${BACKUP_PW}\n`);
  fs.writeFileSync(path.join(TMP, 'pgpass-super.conf'), `127.0.0.1:*:*:postgres:${SUPER_PW}\n`);
  fs.writeFileSync(
    D.cfg,
    JSON.stringify({
      backupRoot: D.backups, pgBin: PGBIN,
      pg: { host: '127.0.0.1', port: PORT, user: 'pos_backup', database: 'optomstroy', credentialFile: path.join(TMP, 'pgpass.conf') },
      publicKeyFile: path.join(D.keys, 'backup-public.pem'), walSpoolDir: D.spool, timeZone: 'Asia/Bishkek',
      dailyAt: '00:00', pitr: true, walShipEverySeconds: 2, walOffsiteEverySeconds: 2, chunkSize: 262144,
      mediaDirs: [{ name: 'media', path: D.media }], offsite: { path: D.offsite },
    }, null, 2),
  );
  cfg = loadConfig(D.cfg);
});

after(() => {
  for (const d of [D.data, D.pitrData, D.latestData, D.officialPitr]) pgStop(d);
  if (process.env.WN_BACKUP_KEEP !== '1') fs.rmSync(TMP, { recursive: true, force: true });
});

let sysid;
let targetTime;

test('кластер PostgreSQL 17 с archive_command = pos-backup wal-archive', { timeout: 180000 }, async () => {
  fs.writeFileSync(path.join(TMP, 'pw.txt'), `${SUPER_PW}\n`);
  sh(exe('initdb'), ['-D', D.data, '-U', 'postgres', `--pwfile=${path.join(TMP, 'pw.txt')}`, '--auth=scram-sha-256', '-E', 'UTF8',
    '--locale-provider=builtin', '--builtin-locale=C.UTF-8', '--locale=C']);
  const q = (s) => `'${s.replace(/\\/g, '\\\\').replace(/'/g, "''")}'`;
  const archiveCmd = `"${process.execPath}" "${TOOL}" wal-archive --config "${D.cfg}" "%p" "%f"`;
  // Журнал — как у init-postgres.ps1 (logging_collector = on, абсолютная папка, postgresql-%a.log): так кластер,
  // восстановленный restore-pitr.ps1 из базовой копии, наследует настройки рабочего (замечание BK-01).
  fs.mkdirSync(D.pglogs, { recursive: true });
  fs.appendFileSync(path.join(D.data, 'postgresql.conf'), [
    '', `port = ${PORT}`, "listen_addresses = '127.0.0.1'", 'wal_level = replica', 'archive_mode = on',
    'archive_timeout = 60', `archive_command = ${q(archiveCmd)}`,
    'logging_collector = on', `log_directory = ${q(D.pglogs)}`, "log_filename = 'postgresql-%a.log'", '',
  ].join('\n'));
  sh(exe('pg_ctl'), ['start', '-D', D.data, '-l', D.log, '-w', '-t', '60'], { stdio: 'ignore' });
  const c = await client(PORT, 'postgres');
  await c.query(`CREATE ROLE pos_backup LOGIN REPLICATION PASSWORD '${BACKUP_PW}'`);
  await c.query('GRANT pg_read_all_data TO pos_backup');
  await c.query('CREATE DATABASE optomstroy');
  sysid = (await c.query('SELECT system_identifier::text AS s FROM pg_control_system()')).rows[0].s;
  await c.end();
  const db = await client(PORT);
  assert.equal((await db.query("SELECT lower('ЁЯ') AS l")).rows[0].l, 'ёя', 'builtin C.UTF-8: lower(ЁЯ)');
  await db.query('CREATE TABLE it_rows (id serial PRIMARY KEY, note text NOT NULL, at timestamptz NOT NULL DEFAULT clock_timestamp())');
  await db.query("INSERT INTO it_rows(note) VALUES ('до базовой копии')");
  const lsn = (await db.query('SELECT pg_walfile_name(pg_switch_wal()) AS w')).rows[0].w;
  await db.end();
  // сегмент закрыт → archive_command должен положить его в спул
  for (let i = 0; i < 60 && !fs.existsSync(path.join(D.spool, lsn)); i++) await sleep(500);
  assert.ok(fs.existsSync(path.join(D.spool, lsn)), `сегмент ${lsn} в спуле`);
  const a = await client(PORT, 'postgres');
  const st = (await a.query('SELECT archived_count, failed_count FROM pg_stat_archiver')).rows[0];
  await a.end();
  assert.equal(Number(st.failed_count), 0, 'pg_stat_archiver.failed_count = 0');
  assert.ok(Number(st.archived_count) >= 1);
});

test('базовая копия (низкоуровневый API) шифруется конвейером pos-backup; wal-ship', { timeout: 180000 }, async () => {
  const c = await client(PORT, 'postgres');
  const startUtc = new Date().toISOString();
  const start = (await c.query("SELECT pg_walfile_name(pg_backup_start('it-base', true)) AS w")).rows[0].w;
  const stage = path.join(TMP, 'base-stage');
  const skip = new Set(['postmaster.pid', 'postmaster.opts']);
  const emptyDirs = new Set(['pg_wal', 'pg_replslot', 'pg_dynshmem', 'pg_notify', 'pg_serial', 'pg_snapshots', 'pg_stat_tmp', 'pg_subtrans']);
  fs.cpSync(D.data, stage, {
    recursive: true,
    filter: (src) => {
      const rel = path.relative(D.data, src);
      if (!rel) return true;
      const parts = rel.split(path.sep);
      if (parts.length === 1 && skip.has(parts[0])) return false;
      if (parts.length > 1 && emptyDirs.has(parts[0])) return false;
      return true;
    },
  });
  const stop = (await c.query('SELECT labelfile, spcmapfile, pg_walfile_name(lsn) AS w FROM pg_backup_stop(true)')).rows[0];
  await c.end();
  fs.writeFileSync(path.join(stage, 'backup_label'), stop.labelfile);
  const ts = stamp();
  const out = path.join(D.backups, 'pitr', sysid, 'base', `base-${ts}.tar.gz.optbk`);
  const r = await encryptChildToFile(cfg, { exe: 'C:\\Windows\\System32\\tar.exe', args: ['-c', '-f', '-', '-C', stage, '.'], out, gzip: true, label: 'tar' });
  await writeSidecars(out, { kind: 'base', format: 'OPTBK1', content: 'low-level backup | tar | gzip (стенд)', systemIdentifier: sysid, label: `base-${ts}`, startUtc, endUtc: new Date().toISOString(), startWal: start, endWal: stop.w, tarBytes: r.plainBytes, ...r });
  fs.rmSync(stage, { recursive: true, force: true });

  // данные после базовой копии: первая вставка → момент восстановления → вторая вставка
  const db = await client(PORT);
  await db.query("INSERT INTO it_rows(note) VALUES ('первая вставка — должна остаться')");
  await sleep(1500);
  targetTime = (await db.query("SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.MS') || '+00:00' AS t")).rows[0].t;
  await sleep(1500);
  await db.query("INSERT INTO it_rows(note) VALUES ('вторая вставка — после момента')");
  const last = (await db.query('SELECT pg_walfile_name(pg_switch_wal()) AS w')).rows[0].w;
  await db.end();
  for (let i = 0; i < 60 && !fs.existsSync(path.join(D.spool, last)); i++) await sleep(500);
  assert.ok(fs.existsSync(path.join(D.spool, last)), `сегмент ${last} в спуле`);

  const ship = spawnSync(process.execPath, [TOOL, 'wal-ship', '--config', D.cfg], { encoding: 'utf8' });
  assert.equal(ship.status, 0, ship.stdout + ship.stderr);
  const left = fs.readdirSync(D.spool).filter((n) => !n.startsWith('.'));
  assert.deepEqual(left, [], 'спул пуст после wal-ship');
  const walDir = path.join(D.backups, 'pitr', sysid, 'wal');
  assert.ok(fs.existsSync(path.join(walDir, `${last}.gz.optbk`)), 'последний сегмент в архиве');
  assert.ok(fs.existsSync(path.join(walDir, `${start}.gz.optbk`)), 'сегмент начала базовой копии в архиве');
  // проверка файла с ключом: базовая копия расшифровывается и распаковывается gzip целиком
  const v = spawnSync(process.execPath, [TOOL, 'verify-file', out, '--key', path.join(D.keys, 'backup-private.pem')], { encoding: 'utf8', env: { ...process.env, POS_BACKUP_KEY_PASSPHRASE: PASSPHRASE } });
  assert.equal(v.status, 0, v.stdout + v.stderr);
});

test('служба daemon: прогон по расписанию, вне сервера, фото, отправка WAL, остановка по концу stdin', { timeout: 120000 }, async (t) => {
  const ch = spawn(process.execPath, [TOOL, 'daemon', '--config', D.cfg], { env: { ...process.env, POS_SHUTDOWN_ON_STDIN_EOF: '1' }, stdio: ['pipe', 'pipe', 'pipe'] });
  let out = '';
  ch.stdout.on('data', (d) => (out += d));
  ch.stderr.on('data', (d) => (out += d));
  const closed = new Promise((r) => ch.on('close', (code) => r(code)));
  t.after(() => {
    if (ch.exitCode === null) ch.kill(); // проверка упала раньше остановки — служба не должна пережить тест
    fs.writeFileSync(path.join(TMP, 'daemon.log'), out);
  });
  for (let i = 0; i < 120 && !out.includes('ежедневный прогон'); i++) await sleep(500);
  // ещё один сегмент — служба должна сама отправить его из спула
  const db = await client(PORT);
  await db.query("INSERT INTO it_rows(note) VALUES ('после второй вставки')");
  const seg = (await db.query('SELECT pg_walfile_name(pg_switch_wal()) AS w')).rows[0].w;
  await db.end();
  const walFile = path.join(D.backups, 'pitr', sysid, 'wal', `${seg}.gz.optbk`);
  for (let i = 0; i < 80 && !fs.existsSync(path.join(D.offsite, 'pitr', sysid, 'wal', `${seg}.gz.optbk`)); i++) await sleep(500);
  assert.ok(fs.existsSync(walFile), 'служба отправила новый сегмент в архив');
  assert.ok(fs.existsSync(path.join(D.offsite, 'pitr', sysid, 'wal', `${seg}.gz.optbk`)), 'и скопировала его вне сервера');
  const t0 = Date.now();
  ch.stdin.end();
  const code = await closed;
  const ms = Date.now() - t0;
  fs.writeFileSync(path.join(TMP, 'daemon.log'), out);
  assert.equal(code, 0, out.slice(-2000));
  assert.ok(ms < 15000, `остановка за ${ms} мс`);
  assert.match(out, /остановка: stdin-eof/);
  assert.match(out, /служба резервного копирования остановлена штатно/);
  // в этом наборе нет pg_dump → дамп честно падает; накопительные шаги (фото, вне сервера) выполнены, очистка — нет,
  // базовая копия за этот день уже есть (сделана выше) — вторая не делается
  assert.match(out, /pg_dump не найден/);
  assert.match(out, /очистка пропущена: дамп не создан/);
  assert.match(out, /базовая копия за \d{4}-\d{2}-\d{2} уже есть — пропуск/);
  assert.ok(fs.existsSync(path.join(D.backups, 'media', 'media', 'sub', 'photo-1.jpg')), 'фото скопированы');
  assert.ok(fs.existsSync(path.join(D.offsite, 'media', 'media', 'sub', 'photo-1.jpg')), 'фото вне сервера');
  const base = fs.readdirSync(path.join(D.offsite, 'pitr', sysid, 'base'));
  assert.ok(base.some((n) => n.endsWith('.tar.gz.optbk')) && base.some((n) => n.endsWith('.json')), 'базовая копия вне сервера');
  assert.ok(!fs.readdirSync(path.join(D.offsite, 'pitr', sysid, 'wal')).some((n) => n.endsWith('.plain.json')), 'отпечатки открытых сегментов вне сервера не уходят');
  const st = JSON.parse(fs.readFileSync(path.join(D.backups, 'state', 'status.json'), 'utf8'));
  assert.equal(st.lastDailyAttempt.dumpOk, false);
  assert.ok(st.lastError.errors.some((e) => e.includes('pg_dump')));
  const dumpsDir = path.join(D.backups, 'dumps');
  assert.ok(!(fs.existsSync(dumpsDir) ? fs.readdirSync(dumpsDir) : []).some((n) => n.includes('.partial')), 'частичных файлов дампа нет');
  const s = spawnSync(process.execPath, [TOOL, 'status', '--config', D.cfg, '--no-db'], { encoding: 'utf8' });
  assert.equal(s.status, 1, 'status: прогон с ошибкой и служба остановлена → код 1');
  const sj = JSON.parse(s.stdout);
  assert.ok(sj.problems.includes('last-run-failed'), sj.problems.join(','));
  assert.ok(sj.problems.includes('daemon-not-running'), 'служба остановлена — daemon-not-running');
  assert.ok(!sj.problems.includes('dump-older-26h'), 'свежая установка: «дампа ещё нет» не ошибка первые 26 ч');
  assert.ok(sj.monitorSinceUtc, 'служба записала начало отсчёта');
  assert.ok(!sj.problems.includes('wal-spool-stuck-10m'));
  assert.ok(sj.walArchive.files >= 3);
});

async function restorePitr(dataDir, port, extra) {
  const ps = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(here, '..', 'restore-pitr.ps1'),
    '-DevTest', '-BackupRoot', D.backups, '-KeyFile', path.join(D.keys, 'backup-private.pem'), '-PgBin', PGBIN, '-DataDir', dataDir,
    '-Port', String(port), '-NodeExe', process.execPath, '-TimeoutMinutes', '5', '-BackupConfig', D.cfg,
    '-LivePort', String(PORT), '-SuperPassFile', path.join(TMP, 'pgpass-super.conf'), ...extra],
  { encoding: 'utf8', env: { ...process.env, POS_BACKUP_KEY_PASSPHRASE: PASSPHRASE }, timeout: 400000 });
  fs.writeFileSync(`${dataDir}-ps.log`, `${ps.stdout}\n${ps.stderr}`);
  assert.equal(ps.status, 0, `${ps.stdout}\n${ps.stderr}`);
  // BK-01: журнал временного кластера — в своём файле (-l), не в общей папке журналов рабочего кластера
  const recLog = fs.readFileSync(`${dataDir}-recovery.log`, 'utf8');
  assert.match(recLog, /database system is ready to accept connections/, 'журнал восстановления читается скриптом');
  assert.match(ps.stdout, /спул WAL отправлен в зашифрованный архив/, 'шаг 1а: wal-ship выполнен');
  const db = await client(port);
  const rows = (await db.query('SELECT note FROM it_rows ORDER BY id')).rows.map((r) => r.note);
  const rec = (await db.query('SELECT pg_is_in_recovery() AS r')).rows[0].r;
  await db.end();
  return { rows, rec, out: ps.stdout };
}

test('restore-pitr.ps1 -DevTest: момент между вставками — есть только первая', { timeout: 420000 }, async () => {
  const r = await restorePitr(D.pitrData, PORT_PITR, ['-TargetTime', targetTime]);
  assert.equal(r.rec, false, 'восстановленный кластер повышен (не в восстановлении)');
  assert.deepEqual(r.rows, ['до базовой копии', 'первая вставка — должна остаться']);
  assert.match(r.out, /recovery stopping before commit/);
  pgStop(D.pitrData);
});

test('restore-pitr.ps1 -DevTest -Latest: все вставки на месте, включая сегмент, лежавший в спуле (BK-04)', { timeout: 420000 }, async () => {
  // служба остановлена: последний сегмент лежит в спуле и в архив не отправлен — его отправляет шаг 1а скрипта
  const db = await client(PORT);
  await db.query("INSERT INTO it_rows(note) VALUES ('в спуле перед восстановлением')");
  const seg = (await db.query('SELECT pg_walfile_name(pg_switch_wal()) AS w')).rows[0].w;
  await db.end();
  for (let i = 0; i < 60 && !fs.existsSync(path.join(D.spool, seg)); i++) await sleep(500);
  assert.ok(fs.existsSync(path.join(D.spool, seg)), `сегмент ${seg} в спуле`);
  assert.ok(!fs.existsSync(path.join(D.backups, 'pitr', sysid, 'wal', `${seg}.gz.optbk`)), 'и ещё не в архиве');
  const r = await restorePitr(D.latestData, PORT_LATEST, ['-Latest']);
  assert.equal(r.rec, false);
  assert.deepEqual(r.rows, ['до базовой копии', 'первая вставка — должна остаться', 'вторая вставка — после момента', 'после второй вставки', 'в спуле перед восстановлением']);
  pgStop(D.latestData);
});

// ---------- официальные программы PostgreSQL 17 (замечание BK-10) ----------
// В наборе @embedded-postgres нет pg_dump, pg_restore, psql, pg_basebackup — тогда проверка пропускается (skip).
// На тестовом адресе: backup.tests.ps1 -PgBin 'C:\Program Files\PostgreSQL\17\bin'.
const OFFICIAL = ['pg_dump', 'pg_dumpall', 'pg_restore', 'psql', 'pg_basebackup'].every((n) => fs.existsSync(exe(n)));

test('официальные программы: dump-only, base-now, status с базой, restore.ps1 -DevTest, PITR из pg_basebackup', {
  timeout: 900000, skip: !OFFICIAL && `нет программ PostgreSQL в ${PGBIN}`,
}, async () => {
  const run = (args) => spawnSync(process.execPath, [TOOL, ...args, '--config', D.cfg], { encoding: 'utf8' });
  let r = run(['dump-only']);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  const dumpName = JSON.parse(r.stdout.trim().split('\n').pop()).dump;
  const dumpFile = path.join(D.backups, 'dumps', dumpName);
  assert.ok(fs.existsSync(dumpFile));
  r = run(['base-now']);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  r = run(['status']);
  const sj = JSON.parse(r.stdout);
  assert.ok(!sj.problems.includes('db-unreachable'), sj.problems.join(','));
  assert.equal(sj.archiver.archiveMode, 'on');

  // restore.ps1 -DevTest в соседнюю базу того же кластера; роли — как при установке
  const c = await client(PORT, 'postgres');
  for (const role of ['pos_migrate', 'pos_app', 'pos_readonly']) {
    await c.query(`DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${role}') THEN CREATE ROLE ${role}; END IF; END $$`);
  }
  await c.end();
  const ps = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(here, '..', 'restore.ps1'),
    '-DevTest', '-DumpFile', dumpFile, '-KeyFile', path.join(D.keys, 'backup-private.pem'), '-Database', 'optomstroy_restored',
    '-PgBin', PGBIN, '-Port', String(PORT), '-SuperPassFile', path.join(TMP, 'pgpass-super.conf'), '-SkipPasswords', '-NodeExe', process.execPath],
  { encoding: 'utf8', env: { ...process.env, POS_BACKUP_KEY_PASSPHRASE: PASSPHRASE }, timeout: 600000 });
  fs.writeFileSync(path.join(TMP, 'restore-ps.log'), `${ps.stdout}\n${ps.stderr}`);
  assert.equal(ps.status, 0, `${ps.stdout}\n${ps.stderr}`);
  const a = await client(PORT);
  const b = await client(PORT, 'optomstroy_restored');
  const count = async (x) => Number((await x.query('SELECT count(*) AS n FROM it_rows')).rows[0].n);
  assert.equal(await count(b), await count(a), 'строк в восстановленной базе столько же');
  await a.end();
  await b.end();

  // restore-drill.ps1 -DevTest: настоящий pg_restore во временный кластер (порт 55448), итог в status
  const dr = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(here, '..', 'restore-drill.ps1'),
    '-DevTest', '-DumpFile', dumpFile, '-KeyFile', path.join(D.keys, 'backup-private.pem'), '-BackupConfig', D.cfg, '-PgBin', PGBIN,
    '-Port', '55448', '-WorkDir', path.join(TMP, 'drill-work'), '-NodeExe', process.execPath],
  { encoding: 'utf8', env: { ...process.env, POS_BACKUP_KEY_PASSPHRASE: PASSPHRASE }, timeout: 600000 });
  fs.writeFileSync(path.join(TMP, 'restore-drill-ps.log'), `${dr.stdout}\n${dr.stderr}`);
  // в тестовой базе нет pos_meta.schema_migrations — проверка должна дойти до проверок и честно не пройти
  assert.equal(dr.status, 1, `${dr.stdout}\n${dr.stderr}`);
  assert.match(dr.stdout, /восстановлено за/, 'pg_restore во временный кластер выполнен');
  assert.match(dr.stdout, /schema_migrations/);
  assert.ok(!fs.existsSync(path.join(TMP, 'drill-work')), 'временная папка удалена');

  // PITR из настоящей копии pg_basebackup (-Latest; restore-pitr выбирает самую новую базовую копию)
  const p = await restorePitr(D.officialPitr, 55444, ['-Latest']);
  assert.equal(p.rec, false);
  assert.ok(p.rows.includes('в спуле перед восстановлением'));
  pgStop(D.officialPitr);
});
