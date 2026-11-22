// Общие функции pos-backup: конфигурация, журнал, время, файлы, запуск программ PostgreSQL.

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';

export function log(level, msg, extra = {}) {
  const rec = { time: new Date().toISOString(), service: 'pos-backup', level, msg, ...extra };
  process.stdout.write(`${JSON.stringify(rec)}\n`);
}

export class UsageError extends Error {}

// ---------- конфигурация backup.json (README, «backup.json») ----------
const DEFAULTS = {
  timeZone: 'Asia/Bishkek',
  dailyAt: '05:30',
  keepDays: 30,
  monthlyExtraDays: 93,
  globalsKeepDays: 90,
  globalsWeekday: 0,
  pitr: true,
  walShipEverySeconds: 20,
  walOffsiteEverySeconds: 300,
  retryMinutes: 30,
  chunkSize: 1024 * 1024,
  gzipLevel: 3,
  mediaDirs: [],
  offsite: null,
  healthchecksUrlFile: null,
  alerting: null,
  statusCheckEveryMinutes: 10,
};

export function loadConfig(file) {
  if (!file) throw new UsageError('не указан --config <backup.json>');
  let raw = fs.readFileSync(file, 'utf8');
  if (raw.charCodeAt(0) === 0xfeff) raw = raw.slice(1);
  const c = { ...DEFAULTS, ...JSON.parse(raw) };
  c.pg = { host: '127.0.0.1', port: 5433, user: 'pos_backup', database: 'optomstroy', ...(c.pg ?? {}) };
  c.configFile = path.resolve(file);
  const errs = [];
  for (const k of ['backupRoot', 'pgBin', 'publicKeyFile', 'walSpoolDir']) {
    if (typeof c[k] !== 'string' || !c[k]) errs.push(`${k}: обязательная строка`);
  }
  if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(c.dailyAt)) errs.push('dailyAt: формат ЧЧ:ММ');
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: c.timeZone });
  } catch {
    errs.push(`timeZone: неизвестный часовой пояс ${c.timeZone}`);
  }
  if (c.healthchecksUrlFile !== null && (typeof c.healthchecksUrlFile !== 'string' || !c.healthchecksUrlFile)) errs.push('healthchecksUrlFile: null или путь к файлу секрета с адресом проверки');
  for (const k of ['keepDays', 'monthlyExtraDays', 'globalsKeepDays', 'walShipEverySeconds', 'walOffsiteEverySeconds', 'retryMinutes', 'statusCheckEveryMinutes']) {
    if (!Number.isInteger(c[k]) || c[k] < 1) errs.push(`${k}: целое ≥ 1`);
  }
  if (!Number.isInteger(c.globalsWeekday) || c.globalsWeekday < 0 || c.globalsWeekday > 6) errs.push('globalsWeekday: 0..6 (0 — воскресенье)');
  if (!Array.isArray(c.mediaDirs)) errs.push('mediaDirs: массив {name, path}');
  else for (const m of c.mediaDirs) if (!m || !/^[A-Za-z0-9_-]+$/.test(m.name ?? '') || !m.path) errs.push('mediaDirs: у каждого элемента name (латиница, цифры, _ -) и path');
  // offsite: null — копии вне сервера нет (status: offsite-not-configured); {"path": …} или {"mode": "push", "path": …} —
  // служба копирует сама; {"mode": "pull"} — хранилище само забирает файлы из корня копий (служба ничего не копирует,
  // контроль свежести — на стороне хранилища). Внутри: c.offsite — только для копирования службой, c.offsitePull — флаг.
  c.offsitePull = false;
  if (c.offsite !== null) {
    const o = c.offsite;
    if (typeof o !== 'object' || Array.isArray(o)) errs.push('offsite: null, {"path": …} или {"mode": "pull"}');
    else if (o.mode === 'pull') {
      if (o.path !== undefined) errs.push('offsite: у {"mode": "pull"} нет path (хранилище забирает файлы само)');
      c.offsitePull = true;
      c.offsite = null;
    } else if (o.mode !== undefined && o.mode !== 'push') errs.push('offsite.mode: "push" или "pull"');
    else if (typeof o.path !== 'string' || !o.path) errs.push('offsite: null, {"path": …} или {"mode": "pull"}');
  }
  if (c.alerting !== null && c.alerting !== 'external') errs.push('alerting: null или "external" (оповещение — внешний мониторинг по status)');
  if (!c.pg.credentialFile) errs.push('pg.credentialFile: файл паролей PostgreSQL (формат pgpass) обязателен');
  if (errs.length) throw new UsageError(`backup.json (${file}):\n  ${errs.join('\n  ')}`);
  return c;
}

export function layout(c) {
  const root = c.backupRoot;
  return {
    root,
    dumps: path.join(root, 'dumps'),
    monthly: path.join(root, 'dumps', 'monthly'),
    pitr: path.join(root, 'pitr'),
    media: path.join(root, 'media'),
    stateDir: path.join(root, 'state'),
    statusFile: path.join(root, 'state', 'status.json'),
  };
}

// ---------- время ----------
// Части местного времени в часовом поясе конфигурации (расписание и месячная копия — по времени магазина).
export function zonedParts(date, timeZone) {
  const f = new Intl.DateTimeFormat('en-US', {
    timeZone, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', weekday: 'short', hourCycle: 'h23',
  });
  const p = Object.fromEntries(f.formatToParts(date).map((x) => [x.type, x.value]));
  const wd = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].indexOf(p.weekday);
  return { date: `${p.year}-${p.month}-${p.day}`, month: `${p.year}-${p.month}`, hhmm: `${p.hour}:${p.minute}`, weekday: wd };
}

// Метка UTC для имён файлов: YYYYMMDD-HHMMSS (UTC — однозначно при переходах времени и смене пояса сервера).
export function stamp(date = new Date()) {
  return date.toISOString().replace(/[-:]/g, '').replace('T', '-').slice(0, 15);
}

export function stampToDate(s) {
  const m = /^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$/.exec(s);
  return m ? new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6])) : null;
}

// ---------- файлы ----------
export function sha256File(file) {
  return new Promise((resolve, reject) => {
    const h = crypto.createHash('sha256');
    fs.createReadStream(file).on('error', reject).on('data', (d) => h.update(d)).on('end', () => resolve(h.digest('hex')));
  });
}

export function fsyncFile(file) {
  const fd = fs.openSync(file, 'r+');
  try {
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}

// Сброс каталога на диск: в Windows каталог нельзя открыть для fsync (EPERM/EISDIR) — метаданные NTFS
// журналируются; ошибку не считаем сбоем.
export function fsyncDir(dir) {
  try {
    const fd = fs.openSync(dir, 'r');
    try {
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
  } catch {
    /* Windows: не поддерживается */
  }
}

// Публикация без перезаписи: жёсткая ссылка (ошибка EEXIST, если цель уже есть), затем удаление временного.
// Если файловая система не умеет жёсткие ссылки — переименование после проверки отсутствия цели.
export function publishNoReplace(tmp, dst) {
  try {
    fs.linkSync(tmp, dst);
    fs.unlinkSync(tmp);
  } catch (e) {
    if (e.code === 'EEXIST') throw e;
    if (fs.existsSync(dst)) {
      const ex = new Error(`${dst} уже существует`);
      ex.code = 'EEXIST';
      throw ex;
    }
    fs.renameSync(tmp, dst);
  }
  fsyncDir(path.dirname(dst));
}

export function writeFileDurable(file, data) {
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, data);
  fsyncFile(tmp);
  fs.renameSync(tmp, file);
  fsyncDir(path.dirname(file));
}

export function readJson(file, fallback = null) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

export function rmQuiet(file) {
  try {
    fs.rmSync(file, { force: true });
  } catch {
    /* нет файла */
  }
}

export function listDir(dir) {
  try {
    return fs.readdirSync(dir);
  } catch {
    return [];
  }
}

// ---------- PostgreSQL ----------
export function pgExe(c, name) {
  const p = path.join(c.pgBin, process.platform === 'win32' ? `${name}.exe` : name);
  if (!fs.existsSync(p)) throw new Error(`${name} не найден в pgBin (${c.pgBin})`);
  return p;
}

export function pgEnv(c) {
  const env = { ...process.env, PGCONNECT_TIMEOUT: process.env.PGCONNECT_TIMEOUT || '10', PGAPPNAME: 'pos-backup' };
  delete env.PGPASSWORD;
  env.PGPASSFILE = c.pg.credentialFile; // пароль pos_backup — только из файла pgpass, не из окружения службы
  return env;
}

export function pgConnArgs(c, { database = c.pg.database } = {}) {
  return ['-h', c.pg.host, '-p', String(c.pg.port), '-U', c.pg.user, '-w', ...(database ? ['-d', database] : [])];
}

// Запуск программы с захватом stdout/stderr (короткие запросы psql).
export function run(exe, args, { env, input, signal } = {}) {
  return new Promise((resolve, reject) => {
    const ch = spawn(exe, args, { env, windowsHide: true, signal });
    let out = '';
    let err = '';
    ch.stdout.on('data', (d) => (out += d));
    ch.stderr.on('data', (d) => (err += d));
    ch.on('error', reject);
    ch.on('close', (code) => resolve({ code, out, err }));
    if (input !== undefined) ch.stdin.end(input);
    else ch.stdin.end();
  });
}

export async function psql(c, sql, opts = {}) {
  const r = await run(pgExe(c, 'psql'), ['-X', '-A', '-t', '-q', '-v', 'ON_ERROR_STOP=1', ...pgConnArgs(c, opts), '-c', sql], { env: pgEnv(c), signal: opts.signal });
  if (r.code !== 0) throw new Error(`psql: код ${r.code}: ${r.err.trim().split('\n').slice(-2).join(' ')}`);
  return r.out.trim();
}

export const WAL_NAME = /^([0-9A-F]{24}(\.partial|\.[0-9A-F]{8}\.backup)?|[0-9A-F]{8}\.history)$/;
export const WAL_SEGMENT = /^[0-9A-F]{24}$/;

// Номер сегмента без линии времени (последние 16 символов) — для сравнения «раньше/позже».
export function walPos(name) {
  return /^[0-9A-F]{24}/.test(name) ? name.slice(8, 24) : null;
}

// system_identifier из длинного заголовка первой страницы сегмента WAL (XLogLongPageHeaderData: xlp_info по
// смещению 2, флаг XLP_LONG_HEADER = 0x0002; xlp_sysid — uint64 по смещению 24, порядок байтов x86 — little-endian).
export function walSysid(file) {
  const fd = fs.openSync(file, 'r');
  try {
    const b = Buffer.alloc(40);
    if (fs.readSync(fd, b, 0, 40, 0) < 40) return null;
    if (!(b.readUInt16LE(2) & 0x0002)) return null;
    return b.readBigUInt64LE(24).toString();
  } finally {
    fs.closeSync(fd);
  }
}
