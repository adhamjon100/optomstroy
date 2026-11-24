// Проверки заданий pos-backup без PostgreSQL (node --test): замок, wal-ship после обрыва, wal-unpack с дырой и
// повреждённым сегментом, окно копии WAL вне сервера, ежедневный прогон при сбое pg_dump (одна базовая копия в день,
// без очистки, оповещение Healthchecks), пороги status на свежей установке, защита последних дампов.
// Поддельные pg_dump.exe / pg_basebackup.exe / psql.exe собираются встроенным csc.exe (.NET Framework 4).
// Временные данные — .tmp/wn-backup/jobs; HTTP-приёмник оповещений — 127.0.0.1:55447.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import zlib from 'node:zlib';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

import { encryptStream, generateKeyPair } from '../lib/optbk.mjs';
import { loadConfig, stamp } from '../lib/common.mjs';
import { CONFIG_RISK_PROBLEMS, LOCK_STALE_MS, dailyRun, offsiteCopy, prune, recordRestoreDrill, status, takeLock, updateStatus, walShip } from '../lib/jobs.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const TOOL = path.join(here, '..', 'pos-backup.mjs');
const TMP = process.env.WN_BACKUP_JOBS_TMP || path.resolve(here, '..', '..', '..', '..', '.tmp', 'wn-backup', 'jobs');
const CSC = 'C:\\Windows\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe';
const HC_PORT = 55447;
const SYSID = '7300000000000000001';

let K;
let pubFile;
let privFile;
before(() => {
  fs.rmSync(TMP, { recursive: true, force: true });
  fs.mkdirSync(TMP, { recursive: true });
  K = generateKeyPair(null);
  pubFile = path.join(TMP, 'pub.pem');
  privFile = path.join(TMP, 'priv.pem');
  fs.writeFileSync(pubFile, K.publicKey);
  fs.writeFileSync(privFile, K.privateKey);
});

after(() => {
  if (process.env.WN_BACKUP_KEEP !== '1') fs.rmSync(TMP, { recursive: true, force: true });
});

function cfgFor(root, extra = {}) {
  return {
    backupRoot: root, publicKeyFile: pubFile, walSpoolDir: path.join(root, 'spool'), pgBin: path.join(root, 'bin'),
    pg: { host: '127.0.0.1', port: 55449, user: 'pos_backup', database: 'optomstroy', credentialFile: path.join(root, 'pgpass.conf') },
    timeZone: 'Asia/Bishkek', chunkSize: 4096, gzipLevel: 3, keepDays: 30, monthlyExtraDays: 93, globalsKeepDays: 90, globalsWeekday: 9,
    pitr: true, mediaDirs: [], offsite: null, healthchecksUrlFile: null, retryMinutes: 30, ...extra,
  };
}

// Сегмент WAL с длинным заголовком страницы: xlp_info (смещение 2) с XLP_LONG_HEADER, xlp_sysid (смещение 24).
function fakeSegment(fill) {
  const b = Buffer.alloc(16384, fill);
  b.writeUInt16LE(0x0002, 2);
  b.writeBigUInt64LE(BigInt(SYSID), 24);
  return b;
}

async function encGz(data) {
  const parts = [];
  await pipeline(Readable.from([data]), zlib.createGzip(), encryptStream(crypto.createPublicKey(K.publicKey), { chunkSize: 4096 }), async (src) => {
    for await (const b of src) parts.push(b);
  });
  return Buffer.concat(parts);
}

test('замок: живой владелец со свежей отметкой — занят; PID жив, но отметка старая — брошен; PID мёртв — брошен', () => {
  const c = cfgFor(path.join(TMP, 'lock'));
  const file = path.join(c.backupRoot, 'state', 'wal.lock');
  const rel = takeLock(c, 'wal');
  assert.ok(rel, 'первый захват');
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).pid, process.pid);
  rel();
  assert.ok(!fs.existsSync(file), 'освобождён');
  // чужой живой процесс (родительский) со свежей отметкой
  fs.writeFileSync(file, JSON.stringify({ pid: process.ppid, token: 'x' }));
  assert.equal(takeLock(c, 'wal'), null, 'живой владелец — занят');
  // тот же PID (переиспользован Windows), но отметка не обновлялась дольше LOCK_STALE_MS
  const old = new Date(Date.now() - LOCK_STALE_MS - 60000);
  fs.utimesSync(file, old, old);
  const r2 = takeLock(c, 'wal');
  assert.ok(r2, 'старая отметка — замок брошен');
  r2();
  // старый формат (только PID) с несуществующим процессом
  fs.writeFileSync(file, '999999');
  const r3 = takeLock(c, 'wal');
  assert.ok(r3, 'мёртвый PID — замок брошен');
  // перехваченный замок не удаляется прежним владельцем
  fs.writeFileSync(file, JSON.stringify({ pid: process.pid, token: 'другой' }));
  r3();
  assert.ok(fs.existsSync(file), 'чужой замок остался');
  fs.rmSync(file);
});

test('wal-ship: обрыв между отпечатком и публикацией не останавливает отправку WAL (BK-08)', async () => {
  const c = cfgFor(path.join(TMP, 'ship'));
  fs.mkdirSync(c.walSpoolDir, { recursive: true });
  const walDir = path.join(c.backupRoot, 'pitr', SYSID, 'wal');
  const s1 = '000000010000000000000007';
  const s2 = '000000010000000000000008';
  fs.writeFileSync(path.join(c.walSpoolDir, s1), fakeSegment(1));
  fs.writeFileSync(path.join(c.walSpoolDir, s2), fakeSegment(2));
  // обрыв после публикации архива s1 (отпечаток уже записан — новый порядок): архив и .plain.json есть, s1 в спуле
  fs.mkdirSync(walDir, { recursive: true });
  fs.writeFileSync(path.join(walDir, `${s1}.gz.optbk`), await encGz(fakeSegment(1)));
  const sha = crypto.createHash('sha256').update(fakeSegment(1)).digest('hex');
  fs.writeFileSync(path.join(walDir, `${s1}.gz.optbk.plain.json`), JSON.stringify({ name: s1, plainSha256: sha }));
  // обрыв до публикации s2: отпечаток есть, архива нет
  fs.writeFileSync(path.join(walDir, `${s2}.gz.optbk.plain.json`), JSON.stringify({ name: s2, plainSha256: 'старый' }));
  const r = await walShip(c);
  assert.equal(r.shipped, 1, 's2 отправлен заново');
  assert.deepEqual(fs.readdirSync(c.walSpoolDir), [], 'спул пуст');
  assert.ok(fs.existsSync(path.join(walDir, `${s2}.gz.optbk`)));
  assert.equal(JSON.parse(fs.readFileSync(path.join(walDir, `${s2}.gz.optbk.plain.json`), 'utf8')).plainSha256,
    crypto.createHash('sha256').update(fakeSegment(2)).digest('hex'), 'отпечаток перезаписан');
  // брошенный отпечаток без архива старше суток удаляет prune
  const orphan = path.join(walDir, '000000010000000000000009.gz.optbk.plain.json');
  fs.writeFileSync(orphan, '{}');
  const old = new Date(Date.now() - 2 * 86400000);
  fs.utimesSync(orphan, old, old);
  prune(c);
  assert.ok(!fs.existsSync(orphan), 'брошенный отпечаток удалён');
  assert.ok(fs.existsSync(path.join(walDir, `${s2}.gz.optbk.plain.json`)), 'отпечаток с архивом остался');
});

test('wal-unpack: дыра — код 3 и только непрерывный отрезок; повреждённый сегмент — код 3 до него; целый — 0', async () => {
  const root = path.join(TMP, 'unpack');
  const mk = async (dir, names) => {
    fs.mkdirSync(dir, { recursive: true });
    for (const n of names) fs.writeFileSync(path.join(dir, `${n}.gz.optbk`), await encGz(n.endsWith('.history') ? Buffer.from('1\t0/3000000\tno recovery target specified\n') : fakeSegment(n.charCodeAt(23))));
  };
  const seg = (h) => `0000000100000000000000${h}`;
  const run = (from, to, extra = []) => spawnSync(process.execPath, [TOOL, 'wal-unpack', '--key', privFile, '--from', from, '--to', to, '--start-wal', seg('02'), ...extra], { encoding: 'utf8' });
  // переход через границу «логического файла» (…000000FF → …0000000100000000) тоже непрерывен
  const gapDir = path.join(root, 'gap');
  await mk(gapDir, [seg('01'), seg('02'), seg('03'), seg('05'), '00000002.history']);
  let r = run(gapDir, path.join(root, 'gap-out'));
  assert.equal(r.status, 3, r.stderr);
  assert.match(r.stderr, /НЕПОЛНЫЙ АРХИВ: дыра/);
  assert.deepEqual(fs.readdirSync(path.join(root, 'gap-out')).sort(), [seg('02'), seg('03'), '00000002.history']);
  r = run(gapDir, path.join(root, 'gap-allow'), ['--allow-gap']);
  assert.equal(r.status, 0, r.stderr);
  assert.ok(fs.existsSync(path.join(root, 'gap-allow', seg('05'))));

  const badDir = path.join(root, 'bad');
  await mk(badDir, [seg('02'), seg('03'), seg('04')]);
  const f = path.join(badDir, `${seg('03')}.gz.optbk`);
  const t = fs.readFileSync(f);
  t[t.length - 30] ^= 1;
  fs.writeFileSync(f, t);
  r = run(badDir, path.join(root, 'bad-out'));
  assert.equal(r.status, 3, r.stderr);
  assert.match(r.stderr, /повреждён сегмент/);
  assert.deepEqual(fs.readdirSync(path.join(root, 'bad-out')), [seg('02')]);

  const okDir = path.join(root, 'ok');
  await mk(okDir, ['0000000100000000000000FF', '000000010000000100000000', '000000010000000100000001']);
  r = spawnSync(process.execPath, [TOOL, 'wal-unpack', '--key', privFile, '--from', okDir, '--to', path.join(root, 'ok-out'), '--start-wal', '0000000100000000000000FF'], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(fs.readdirSync(path.join(root, 'ok-out')).length, 3);
  // место: оценка больше свободного (сегмент 1024 МиБ × 3 + запас) не проверяется на маленьком томе — только отказ на огромной оценке
  r = spawnSync(process.execPath, [TOOL, 'wal-unpack', '--key', privFile, '--from', okDir, '--to', path.join(root, 'ok-space'), '--segment-mb', '1024', '--start-wal', '0000000100000000000000FF'], { encoding: 'utf8' });
  assert.ok(r.status === 0 || /свободно/.test(r.stderr), r.stderr);
});

test('копия WAL вне сервера: проход раз в 5 минут проверяет только окно с прошлого успеха; ночной — всё (BK-07)', async () => {
  const root = path.join(TMP, 'offsite');
  const off = path.join(root, 'nas');
  fs.mkdirSync(off, { recursive: true });
  const c = cfgFor(root, { offsite: { path: off } });
  const walDir = path.join(root, 'pitr', SYSID, 'wal');
  fs.mkdirSync(walDir, { recursive: true });
  const oldF = path.join(walDir, '000000010000000000000001.gz.optbk');
  const newF = path.join(walDir, '000000010000000000000002.gz.optbk');
  fs.writeFileSync(oldF, 'old');
  fs.writeFileSync(newF, 'new');
  const old = new Date(Date.now() - 86400000);
  fs.utimesSync(oldF, old, old);
  updateStatus(c, { lastWalOffsiteUtc: new Date().toISOString() });
  let s = await offsiteCopy(c, { walOnly: true });
  assert.equal(s.checked, 1, 'проверен только новый файл');
  assert.ok(fs.existsSync(path.join(off, 'pitr', SYSID, 'wal', '000000010000000000000002.gz.optbk')));
  assert.ok(!fs.existsSync(path.join(off, 'pitr', SYSID, 'wal', '000000010000000000000001.gz.optbk')));
  s = await offsiteCopy(c, {});
  assert.ok(fs.existsSync(path.join(off, 'pitr', SYSID, 'wal', '000000010000000000000001.gz.optbk')), 'ночной проход — весь архив');
  // остановка службы во время копии: файл назначения не остаётся
  const big = path.join(root, 'pitr', SYSID, 'base', 'base-20261121-000000.tar.gz.optbk');
  fs.mkdirSync(path.dirname(big), { recursive: true });
  fs.writeFileSync(big, Buffer.alloc(64 * 1024 * 1024, 1));
  const ac = new AbortController();
  const offBase = path.join(off, 'pitr', SYSID, 'base');
  let sawPartial = false;
  const watch = setInterval(() => {
    if (fs.existsSync(offBase) && fs.readdirSync(offBase).some((n) => n.includes('.partial'))) {
      sawPartial = true;
      ac.abort();
    }
  }, 1);
  const p = offsiteCopy(c, { signal: ac.signal });
  const fallback = setTimeout(() => ac.abort(), 3000);
  await assert.rejects(p, /прервано/);
  clearInterval(watch);
  clearTimeout(fallback);
  if (!sawPartial) console.log('примечание: копия завершилась раньше, чем замечен временный файл — остановка проверена до копии');
  const leftovers = (fs.existsSync(offBase) ? fs.readdirSync(offBase) : []).filter((n) => n.includes('.partial'));
  assert.deepEqual(leftovers, [], 'временных файлов вне сервера нет');
  fs.rmSync(big);
});

test('status: свежая установка — «копий ещё нет» не ошибка 26 ч; служба не работает — daemon-not-running (BK-17, BK-05)', async () => {
  const c = cfgFor(path.join(TMP, 'status'), { pitr: true, offsite: null });
  const now = new Date();
  updateStatus(c, { monitorSinceUtc: new Date(now - 3600000).toISOString(), daemonHeartbeatUtc: new Date(now - 30000).toISOString() });
  let s = await status(c, { now, queryDb: false });
  // свежая установка без копии вне сервера и без оповещения: только риски настройки (DATA-02), без отсрочки
  assert.deepEqual(s.problems, ['offsite-not-configured', 'alerting-not-configured'], JSON.stringify(s.problems));
  assert.equal(s.ok, false);
  assert.equal(s.offsiteMode, null);
  assert.equal(s.alerting, null);
  updateStatus(c, { monitorSinceUtc: new Date(now - 27 * 3600000).toISOString(), daemonHeartbeatUtc: new Date(now - 10 * 60000).toISOString() });
  s = await status(c, { now, queryDb: false });
  for (const p of ['dump-older-26h', 'base-older-26h', 'daemon-not-running']) assert.ok(s.problems.includes(p), p);
});

test('status: копия вне сервера и оповещение — риски настройки; {"mode":"pull"} и alerting "external" их снимают (DATA-02)', async () => {
  const root = path.join(TMP, 'status-risks');
  fs.mkdirSync(root, { recursive: true });
  const base = {
    backupRoot: root, pgBin: path.join(root, 'bin'), publicKeyFile: pubFile, walSpoolDir: path.join(root, 'spool'),
    pg: { credentialFile: path.join(root, 'pgpass.conf') }, pitr: false,
  };
  const cfgFile = (extra) => {
    const f = path.join(root, `backup-${crypto.randomBytes(3).toString('hex')}.json`);
    fs.writeFileSync(f, JSON.stringify({ ...base, ...extra }));
    return f;
  };
  const now = new Date();
  // по умолчанию (как пишет install.ps1): offsite = null, healthchecksUrlFile = null
  let c = loadConfig(cfgFile({ offsite: null, healthchecksUrlFile: null }));
  updateStatus(c, { monitorSinceUtc: new Date(now - 3600000).toISOString(), daemonHeartbeatUtc: now.toISOString() });
  let s = await status(c, { now, queryDb: false });
  assert.deepEqual(s.problems, ['offsite-not-configured', 'alerting-not-configured']);
  // хранилище забирает копии само, оповещение — внешний мониторинг по status
  c = loadConfig(cfgFile({ offsite: { mode: 'pull' }, alerting: 'external' }));
  assert.equal(c.offsite, null, 'служба при pull ничего не копирует');
  assert.equal(c.offsitePull, true);
  s = await status(c, { now, queryDb: false });
  assert.deepEqual(s.problems, []);
  assert.equal(s.offsiteMode, 'pull');
  assert.equal(s.alerting, 'external');
  assert.deepEqual(await offsiteCopy(c, {}), { skipped: true });
  // копирование службой и Healthchecks: рисков нет (свежесть копии вне сервера — своими порогами)
  c = loadConfig(cfgFile({ offsite: { path: path.join(root, 'off') }, healthchecksUrlFile: path.join(root, 'hc') }));
  s = await status(c, { now, queryDb: false });
  assert.equal(s.offsiteMode, 'push');
  assert.equal(s.alerting, 'healthchecks');
  assert.ok(!s.problems.some((p) => CONFIG_RISK_PROBLEMS.includes(p)), s.problems.join(','));
  // ошибки схемы
  for (const bad of [{ offsite: { mode: 'pull', path: 'x' } }, { offsite: { mode: 'sftp', path: 'x' } }, { offsite: {} }, { alerting: 'email' }]) {
    assert.throws(() => loadConfig(cfgFile(bad)), /offsite|alerting/, JSON.stringify(bad));
  }
});

test('status: проверка восстановления — restore-drill-failed и restore-drill-older-35d (DATA-06)', async () => {
  const root = path.join(TMP, 'status-drill');
  const c = cfgFor(root, { pitr: false, offsite: null, offsitePull: true, alerting: 'external' });
  const now = new Date();
  updateStatus(c, { monitorSinceUtc: new Date(now - 36 * 86400000).toISOString(), daemonHeartbeatUtc: now.toISOString() });
  let s = await status(c, { now, queryDb: false });
  assert.ok(s.problems.includes('restore-drill-older-35d'), 'проверки не было дольше 35 суток');
  await recordRestoreDrill(c, { result: 'fail', dump: 'D:\\x\\20261101-000000.dump.optbk', detail: 'pg_restore: код 1', now });
  s = await status(c, { now, queryDb: false });
  assert.ok(s.problems.includes('restore-drill-failed'));
  assert.ok(s.problems.includes('restore-drill-older-35d'), 'неудачная проверка не считается проверкой');
  assert.equal(s.lastRestoreDrill.dump, '20261101-000000.dump.optbk');
  await recordRestoreDrill(c, { result: 'ok', dump: 'D:\\x\\20261102-000000.dump.optbk', seconds: 12, now });
  s = await status(c, { now, queryDb: false });
  assert.ok(!s.problems.includes('restore-drill-failed') && !s.problems.includes('restore-drill-older-35d'), s.problems.join(','));
  s = await status(c, { now: new Date(now.getTime() + 36 * 86400000), queryDb: false });
  assert.ok(s.problems.includes('restore-drill-older-35d'), 'через 36 суток после успеха — снова пора');
  await assert.rejects(() => recordRestoreDrill(c, { result: 'maybe' }), /ok или fail/);
});

test('prune: самые новые 3 дампа не удаляются, даже если все старше keepDays (BK-14)', () => {
  const root = path.join(TMP, 'prune-min');
  const dumps = path.join(root, 'dumps');
  fs.mkdirSync(dumps, { recursive: true });
  const now = new Date(Date.UTC(2026, 10, 21, 12));
  const names = [40, 45, 50, 60].map((d) => `${stamp(new Date(now - d * 86400000))}.dump.optbk`);
  for (const n of names) for (const s of ['', '.json']) fs.writeFileSync(path.join(dumps, `${n}${s}`), 'x');
  prune(cfgFor(root), { now });
  const left = fs.readdirSync(dumps).filter((n) => n.endsWith('.dump.optbk')).sort();
  assert.deepEqual(left, names.slice(0, 3).sort());
});

test('prune: старый сегмент WAL удаляется вместе с .plain.json без ENOENT (первый прогон на сервере 24.11.2026)', () => {
  const root = path.join(TMP, 'prune-wal-plain');
  const base = path.join(root, 'pitr', SYSID, 'base');
  const wal = path.join(root, 'pitr', SYSID, 'wal');
  fs.rmSync(root, { recursive: true, force: true });
  fs.mkdirSync(base, { recursive: true });
  fs.mkdirSync(wal, { recursive: true });
  const now = new Date(Date.UTC(2026, 10, 24, 16));
  const b = `base-${stamp(now)}.tar.gz.optbk`;
  fs.writeFileSync(path.join(base, b), 'x');
  fs.writeFileSync(path.join(base, `${b}.json`), JSON.stringify({ startWal: '000000010000000000000008' }));
  for (const seg of ['000000010000000000000001', '000000010000000000000008']) {
    for (const s of ['.gz.optbk', '.gz.optbk.plain.json']) fs.writeFileSync(path.join(wal, `${seg}${s}`), 'x');
  }
  const removed = prune(cfgFor(root), { now });
  assert.ok(removed.some((f) => f.endsWith('000000010000000000000001.gz.optbk')), 'сегмент до начала базовой копии удалён');
  assert.deepEqual(fs.readdirSync(wal).sort(), ['000000010000000000000008.gz.optbk', '000000010000000000000008.gz.optbk.plain.json']);
});

// ---------- ежедневный прогон с поддельными программами PostgreSQL ----------
const FAKE_SRC = `using System; using System.IO;
class P { static int Main(string[] a) {
  string me = Path.GetFileNameWithoutExtension(Environment.GetCommandLineArgs()[0]).ToLowerInvariant();
  string s = string.Join(" ", a);
  if (me == "pg_dump") { Console.Error.WriteLine("pg_dump: error: connection to server failed (fake)"); return 1; }
  if (me == "pg_basebackup") { var o = Console.OpenStandardOutput(); var b = new byte[200000]; o.Write(b, 0, b.Length); o.Flush(); return 0; }
  if (me == "psql") {
    if (s.Contains("system_identifier")) { Console.WriteLine("${SYSID}"); return 0; }
    if (s.Contains("pg_walfile_name")) { Console.WriteLine("000000010000000000000003"); return 0; }
    return 1;
  }
  return 2;
} }`;

test('ежедневный прогон: сбой pg_dump — одна базовая копия в день, очистки нет, Healthchecks /start и /fail (BK-02, BK-05)', { skip: !fs.existsSync(CSC) && 'нет csc.exe' }, async () => {
  const root = path.join(TMP, 'daily');
  const bin = path.join(root, 'bin');
  fs.mkdirSync(bin, { recursive: true });
  fs.writeFileSync(path.join(root, 'fake.cs'), FAKE_SRC);
  for (const n of ['pg_dump', 'pg_basebackup', 'psql']) {
    const r = spawnSync(CSC, ['/nologo', `/out:${path.join(bin, `${n}.exe`)}`, path.join(root, 'fake.cs')], { encoding: 'utf8' });
    assert.equal(r.status, 0, r.stdout + r.stderr);
  }
  const pings = [];
  const srv = http.createServer((req, res) => {
    pings.push(req.url);
    req.resume();
    req.on('end', () => res.end('OK'));
  });
  await new Promise((r) => srv.listen(HC_PORT, '127.0.0.1', r));
  try {
    const hcFile = path.join(root, 'healthchecks_url');
    fs.writeFileSync(hcFile, `http://127.0.0.1:${HC_PORT}/ping/test-check\n`);
    const c = cfgFor(root, { healthchecksUrlFile: hcFile });
    const dumps = path.join(root, 'dumps');
    fs.mkdirSync(dumps, { recursive: true });
    const now = new Date(Date.UTC(2026, 10, 21, 0, 0, 0)); // 06:00 в Бишкеке: повтор через 31 мин — тот же местный день
    const oldDump = `${stamp(new Date(now - 60 * 86400000))}.dump.optbk`;
    for (const s of ['', '.json']) fs.writeFileSync(path.join(dumps, `${oldDump}${s}`), 'x');
    await assert.rejects(dailyRun(c, { now }), /pg_dump/);
    await assert.rejects(dailyRun(c, { now: new Date(now.getTime() + 31 * 60000) }), /pg_dump/);
    const bases = fs.readdirSync(path.join(root, 'pitr', SYSID, 'base')).filter((n) => n.endsWith('.tar.gz.optbk'));
    assert.equal(bases.length, 1, `базовых копий: ${bases.join(', ')}`);
    assert.ok(fs.existsSync(path.join(dumps, oldDump)), 'без нового дампа старые не удаляются');
    assert.ok(!fs.readdirSync(dumps).some((n) => n.includes('.partial')), 'частичного дампа нет');
    assert.deepEqual(pings, ['/ping/test-check/start', '/ping/test-check/fail', '/ping/test-check/start', '/ping/test-check/fail']);
  } finally {
    await new Promise((r) => srv.close(r));
  }
});
