// Задания резервного копирования: дамп, globals, базовая копия PITR, архив WAL, фото, копия вне сервера, очистка,
// состояние для мониторинга. Дампы, globals, базовые копии и архив WAL пишутся сразу зашифрованными (OPTBK1): открытый
// файл на диск не попадает. Исключение — фото и отметки аудита (mediaSync): они копируются как есть, без шифрования
// (не персональные данные; 16 §8.2 — накопительная копия фото, как rclone copy в Linux), и в таком же виде уходят
// вне сервера (offsiteCopy, папка media\).

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { spawn } from 'node:child_process';
import { pipeline } from 'node:stream/promises';

import { encryptStream, inspectStream, loadPublicKey, publicKeyId } from './optbk.mjs';
import {
  WAL_NAME, WAL_SEGMENT, fsyncFile, layout, listDir, log, pgConnArgs, pgEnv, pgExe, psql, publishNoReplace,
  readJson, rmQuiet, sha256File, stamp, stampToDate, walPos, walSysid, writeFileDurable, zonedParts,
} from './common.mjs';

// ---------- состояние (state\status.json) ----------
export function readStatus(c) {
  return readJson(layout(c).statusFile, {});
}

export function updateStatus(c, patch) {
  const L = layout(c);
  fs.mkdirSync(L.stateDir, { recursive: true });
  const s = { ...readJson(L.statusFile, {}), ...patch, updatedAt: new Date().toISOString() };
  writeFileDurable(L.statusFile, JSON.stringify(s, null, 2));
  return s;
}

// ---------- замок (одно задание одного вида за раз: служба и ручной запуск) ----------
// В файле замка — PID и случайная метка владельца; владелец раз в LOCK_HEARTBEAT_MS обновляет время изменения файла.
// Замок брошен, если процесса с этим PID нет ИЛИ отметка не обновлялась дольше LOCK_STALE_MS: Windows быстро
// переиспользует PID, и после аварийного завершения в замке может оказаться PID постороннего живого процесса.
export const LOCK_HEARTBEAT_MS = 60000;
export const LOCK_STALE_MS = 5 * 60000;

function readLockOwner(file) {
  const raw = fs.readFileSync(file, 'utf8');
  try {
    const j = JSON.parse(raw);
    return { pid: Number(j.pid) || 0, token: j.token ?? null };
  } catch {
    return { pid: Number(raw) || 0, token: null }; // старый формат: только PID
  }
}

export function lockState(file, { now = Date.now() } = {}) {
  let owner;
  let mtimeMs;
  try {
    owner = readLockOwner(file);
    mtimeMs = fs.statSync(file).mtimeMs;
  } catch {
    return { exists: false };
  }
  let alive = false;
  try {
    if (owner.pid) {
      process.kill(owner.pid, 0);
      alive = true;
    }
  } catch {
    alive = false;
  }
  const stale = !alive || now - mtimeMs > LOCK_STALE_MS;
  return { exists: true, pid: owner.pid, token: owner.token, alive, ageMs: now - mtimeMs, stale };
}

export function takeLock(c, name) {
  const L = layout(c);
  fs.mkdirSync(L.stateDir, { recursive: true });
  const file = path.join(L.stateDir, `${name}.lock`);
  const token = crypto.randomBytes(12).toString('hex');
  for (let i = 0; i < 2; i++) {
    try {
      const fd = fs.openSync(file, 'wx');
      fs.writeSync(fd, JSON.stringify({ pid: process.pid, token, utc: new Date().toISOString() }));
      fs.closeSync(fd);
      const beat = setInterval(() => {
        try {
          const t = new Date();
          fs.utimesSync(file, t, t);
        } catch {
          /* замок удалён — освобождение ниже это учтёт */
        }
      }, LOCK_HEARTBEAT_MS);
      beat.unref();
      return () => {
        clearInterval(beat);
        try {
          if (readLockOwner(file).token === token) rmQuiet(file); // чужой (перехваченный) замок не удаляется
        } catch {
          /* замка уже нет */
        }
      };
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      const st = lockState(file);
      if (st.exists && !st.stale && st.pid !== process.pid) return null;
      if (st.exists) log('warn', `замок ${name}.lock брошен (PID ${st.pid}${st.alive ? ', процесс с этим PID жив, но отметка не обновлялась' : ' не найден'}; ${Math.round(st.ageMs / 1000)} с) — снят`);
      rmQuiet(file);
    }
  }
  return null;
}

// ---------- запись зашифрованного файла ----------
export async function writeSidecars(file, meta) {
  const sha = await sha256File(file);
  const size = fs.statSync(file).size;
  writeFileDurable(`${file}.sha256`, `${sha} *${path.basename(file)}\n`);
  const manifest = { ...meta, file: path.basename(file), size, sha256: sha };
  writeFileDurable(`${file}.json`, JSON.stringify(manifest, null, 2));
  return manifest;
}

// encryptChildToFile: stdout программы → [gzip] → OPTBK1 → <out>.partial; успех только если программа вернула 0,
// поток завершён, открытых данных больше нуля. Иначе .partial удаляется, исключение.
export async function encryptChildToFile(c, { exe, args, env, out, gzip = false, signal, label }) {
  const pub = loadPublicKey(c.publicKeyFile);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  const partial = `${out}.partial`;
  rmQuiet(partial);
  const stats = {};
  const child = spawn(exe, args, { env, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  let stderr = '';
  child.stderr.on('data', (d) => {
    stderr += d;
    if (stderr.length > 20000) stderr = stderr.slice(-10000);
  });
  const exited = new Promise((resolve) => {
    child.on('error', (e) => resolve({ code: -1, error: e }));
    child.on('close', (code) => resolve({ code }));
  });
  const onAbort = () => child.kill();
  signal?.addEventListener('abort', onAbort, { once: true });
  const stages = [child.stdout];
  let plainCount = 0;
  stages.push(async function* count(src) {
    for await (const b of src) {
      plainCount += b.length;
      yield b;
    }
  });
  if (gzip) stages.push(zlib.createGzip({ level: c.gzipLevel }));
  stages.push(encryptStream(pub, { chunkSize: c.chunkSize, stats }));
  stages.push(fs.createWriteStream(partial, { flags: 'wx' }));
  let pipeErr = null;
  try {
    await pipeline(stages, signal ? { signal } : {});
  } catch (e) {
    pipeErr = e;
    child.kill();
  }
  const ex = await exited;
  signal?.removeEventListener('abort', onAbort);
  const fail = (why) => {
    rmQuiet(partial);
    const e = new Error(`${label}: ${why}${stderr.trim() ? ` — ${stderr.trim().split(/\r?\n/).slice(-3).join(' | ')}` : ''}`);
    throw e;
  };
  if (signal?.aborted) fail('прервано остановкой службы');
  if (ex.error) fail(`не запущен: ${ex.error.message}`);
  if (pipeErr) fail(`ошибка потока: ${pipeErr.message}`);
  if (ex.code !== 0) fail(`код выхода ${ex.code}`);
  if (plainCount === 0) fail('пустой вывод');
  fsyncFile(partial);
  publishNoReplace(partial, out);
  return { plainBytes: plainCount, chunks: stats.chunks, keyId: publicKeyId(pub).toString('hex'), chunkSize: c.chunkSize };
}

// ---------- дамп ----------
export async function dumpDatabase(c, { signal, now = new Date() } = {}) {
  const L = layout(c);
  const ts = stamp(now);
  const out = path.join(L.dumps, `${ts}.dump.optbk`);
  const started = Date.now();
  const r = await encryptChildToFile(c, {
    exe: pgExe(c, 'pg_dump'),
    args: ['-Fc', ...pgConnArgs(c)],
    env: pgEnv(c),
    out,
    signal,
    label: 'pg_dump',
  });
  const m = await writeSidecars(out, {
    kind: 'dump', format: 'OPTBK1', content: 'pg_dump -Fc', database: c.pg.database, createdUtc: now.toISOString(),
    seconds: Math.round((Date.now() - started) / 1000), ...r,
  });
  log('info', `дамп создан: ${path.basename(out)} (${m.size} байт)`, { file: out, size: m.size });
  // Месячная копия: первый успешный дамп месяца (по времени магазина) — жёсткая ссылка, без второй копии данных.
  const month = zonedParts(now, c.timeZone).month;
  fs.mkdirSync(L.monthly, { recursive: true });
  const have = listDir(L.monthly).some((n) => n.endsWith('.dump.optbk') && readJson(path.join(L.monthly, `${n}.json`), {}).month === month);
  if (!have) {
    const mo = path.join(L.monthly, path.basename(out));
    try {
      fs.linkSync(out, mo);
    } catch {
      fs.copyFileSync(out, mo, fs.constants.COPYFILE_EXCL);
    }
    fs.copyFileSync(`${out}.sha256`, `${mo}.sha256`);
    writeFileDurable(`${mo}.json`, JSON.stringify({ ...m, month }, null, 2));
    log('info', `месячная копия: ${path.basename(mo)} (${month})`);
  }
  return m;
}

export async function dumpGlobals(c, { signal, now = new Date() } = {}) {
  const L = layout(c);
  const out = path.join(L.dumps, `globals-${stamp(now)}.sql.optbk`);
  // Роли и членство без паролей (pos_backup не читает pg_authid): пароли выставляются из секретов при восстановлении.
  const r = await encryptChildToFile(c, {
    exe: pgExe(c, 'pg_dumpall'),
    args: ['--globals-only', '--no-role-passwords', '-h', c.pg.host, '-p', String(c.pg.port), '-U', c.pg.user, '-w', '-l', c.pg.database],
    env: pgEnv(c),
    out,
    signal,
    label: 'pg_dumpall --globals-only',
  });
  const m = await writeSidecars(out, { kind: 'globals', format: 'OPTBK1', content: 'pg_dumpall --globals-only --no-role-passwords', createdUtc: now.toISOString(), ...r });
  log('info', `globals: ${path.basename(out)}`);
  return m;
}

// ---------- базовая копия PITR ----------
export async function clusterSysid(c, signal) {
  const s = await psql(c, 'SELECT system_identifier FROM pg_control_system()', { signal });
  if (!/^\d+$/.test(s)) throw new Error('system_identifier кластера не получен');
  return s;
}

export async function baseBackup(c, { signal, now = new Date() } = {}) {
  const L = layout(c);
  const sysid = await clusterSysid(c, signal);
  const ts = stamp(now);
  const dir = path.join(L.pitr, sysid, 'base');
  fs.mkdirSync(path.join(L.pitr, sysid, 'wal'), { recursive: true });
  const startUtc = new Date().toISOString();
  const startWal = await psql(c, 'SELECT pg_walfile_name(pg_current_wal_lsn())', { signal });
  if (!WAL_SEGMENT.test(startWal)) throw new Error('базовая копия: не получен текущий сегмент WAL');
  const out = path.join(dir, `base-${ts}.tar.gz.optbk`);
  // -X fetch: WAL от начала до конца копии внутри tar (копия восстанавливается и без архива);
  // tar в stdout — только без потоковой WAL и без дополнительных табличных пространств (документация pg_basebackup 17).
  const r = await encryptChildToFile(c, {
    exe: pgExe(c, 'pg_basebackup'),
    args: ['-h', c.pg.host, '-p', String(c.pg.port), '-U', c.pg.user, '-w', '-D', '-', '-F', 'tar', '-X', 'fetch', '--checkpoint=fast', '--no-manifest', '-l', `base-${ts}`],
    env: pgEnv(c),
    out,
    gzip: true,
    signal,
    label: 'pg_basebackup',
  });
  const endWal = await psql(c, 'SELECT pg_walfile_name(pg_current_wal_lsn())', { signal });
  const endUtc = new Date().toISOString();
  const m = await writeSidecars(out, {
    kind: 'base', format: 'OPTBK1', content: 'pg_basebackup -F tar -X fetch | gzip', systemIdentifier: sysid,
    label: `base-${ts}`, startUtc, endUtc, startWal, endWal, tarBytes: r.plainBytes, ...r,
  });
  log('info', `базовая копия PITR: ${path.basename(out)} (${m.size} байт; WAL с ${startWal})`, { file: out });
  return m;
}

// ---------- архив WAL: archive_command ----------
// walArchive(spoolDir, src, name): контракт archive_command PostgreSQL. 0 — файл целиком и надёжно в спуле
// (временный файл, fsync, публикация без перезаписи, сверка SHA-256 с источником). Тот же файл уже есть — 0
// (повтор после сбоя); другой файл с тем же именем — код 1, ничего не перезаписывается.
export async function walArchive(spoolDir, src, name) {
  if (!WAL_NAME.test(name ?? '')) {
    process.stderr.write(`wal-archive: неверное имя файла WAL «${name}»\n`);
    return 2;
  }
  if (!src || !fs.existsSync(src) || !fs.statSync(src).isFile()) {
    process.stderr.write(`wal-archive: нет исходного файла ${name}\n`);
    return 1;
  }
  if (!fs.existsSync(spoolDir)) {
    process.stderr.write(`wal-archive: спул ${spoolDir} недоступен\n`);
    return 1;
  }
  const dst = path.join(spoolDir, name);
  const srcSha = await sha256File(src);
  const same = async () => (await sha256File(dst)) === srcSha;
  if (fs.existsSync(dst)) {
    if (await same()) return 0;
    process.stderr.write(`wal-archive: ${name} уже есть в спуле с другим содержимым — не перезаписывается\n`);
    return 1;
  }
  const tmp = path.join(spoolDir, `.${name}.tmp-${process.pid}`);
  rmQuiet(tmp);
  try {
    fs.copyFileSync(src, tmp, fs.constants.COPYFILE_EXCL);
    fsyncFile(tmp);
    if ((await sha256File(tmp)) !== srcSha) throw new Error('сверка SHA-256 временной копии не прошла');
    publishNoReplace(tmp, dst);
  } catch (e) {
    rmQuiet(tmp);
    if (e.code === 'EEXIST' && (await same())) return 0;
    process.stderr.write(`wal-archive: ${name} не записан: ${e.message}\n`);
    return 1;
  }
  if (!(await same())) {
    process.stderr.write(`wal-archive: ${name}: сверка SHA-256 после публикации не прошла\n`);
    return 1;
  }
  return 0;
}

// ---------- спул WAL → зашифрованный архив ----------
export async function walShip(c, { signal } = {}) {
  const L = layout(c);
  const files = listDir(c.walSpoolDir).filter((n) => WAL_NAME.test(n)).sort();
  if (!files.length) return { shipped: 0 };
  const pub = loadPublicKey(c.publicKeyFile);
  let st = readStatus(c);
  let sysidCache = st.walSysid ?? null;
  let shipped = 0;
  let errors = 0;
  for (const name of files) {
    if (signal?.aborted) break;
    const src = path.join(c.walSpoolDir, name);
    try {
      let sysid = WAL_SEGMENT.test(name) || name.endsWith('.partial') ? walSysid(src) : null;
      if (!sysid) sysid = sysidCache ?? (await clusterSysid(c, signal));
      sysidCache = sysid;
      const dir = path.join(L.pitr, sysid, 'wal');
      fs.mkdirSync(dir, { recursive: true });
      const out = path.join(dir, `${name}.gz.optbk`);
      const plainSha = await sha256File(src);
      if (fs.existsSync(out)) {
        const known = (readJson(`${out}.plain.json`, {}) ?? {}).plainSha256;
        if (known === plainSha) {
          fs.unlinkSync(src);
          log('info', `WAL: ${name} уже в архиве с тем же содержимым (повтор архивации) — копия спула удалена`);
          continue;
        }
        throw new Error(`${name} уже в архиве с другим содержимым — оставлен в спуле`);
      }
      const partial = `${out}.partial`;
      rmQuiet(partial);
      const stats = {};
      await pipeline(fs.createReadStream(src), zlib.createGzip({ level: c.gzipLevel }), encryptStream(pub, { chunkSize: c.chunkSize, stats }), fs.createWriteStream(partial, { flags: 'wx' }));
      fsyncFile(partial);
      // SHA-256 открытого сегмента — только для сверки повторной архивации (вне сервера не копируется). Пишется ДО
      // публикации архива (как .sha256 в Linux): если процесс оборвётся между двумя шагами, следующий проход увидит
      // архив с отпечатком и удалит копию из спула, а не остановит отправку WAL навсегда. Отпечаток без архива
      // (обрыв до публикации) следующий проход перезапишет; брошенные отпечатки старше суток удаляет prune.
      writeFileDurable(`${out}.plain.json`, JSON.stringify({ name, plainSha256: plainSha, plainBytes: fs.statSync(src).size, shippedUtc: new Date().toISOString() }));
      publishNoReplace(partial, out);
      fs.unlinkSync(src);
      shipped++;
    } catch (e) {
      errors++;
      log('error', `WAL: ${name}: ${e.message}`);
      break; // порядок важен: следующий сегмент не отправляется раньше предыдущего
    }
  }
  st = updateStatus(c, { walSysid: sysidCache, ...(shipped ? { lastWalShipUtc: new Date().toISOString() } : {}), ...(errors ? { lastWalShipErrorUtc: new Date().toISOString() } : {}) });
  if (shipped) log('info', `WAL: отправлено в архив ${shipped}`);
  if (errors) throw new Error('WAL: отправка в архив не завершена');
  return { shipped };
}

// ---------- копирование файлов без блокировки цикла событий ----------
// Все операции с файлами здесь асинхронные (пул потоков libuv), копирование — потоком с сигналом остановки: пока
// идёт многогигабайтная копия на общую папку, служба продолжает отправлять WAL и штатно останавливается по концу
// stdin (иначе OptomstroySvc через stopTimeoutSeconds убивает процесс посреди копии).
const fsp = fs.promises;

function abortError() {
  const e = new Error('прервано остановкой службы');
  e.code = 'ABORT_ERR';
  return e;
}

async function copyFileAbortable(src, dst, signal) {
  if (signal?.aborted) throw abortError();
  try {
    await pipeline(fs.createReadStream(src), fs.createWriteStream(dst, { flags: 'wx' }), signal ? { signal } : {});
  } catch (e) {
    await fsp.rm(dst, { force: true }).catch(() => {});
    if (signal?.aborted) throw abortError();
    throw e;
  }
}

async function statOrNull(p) {
  try {
    return await fsp.stat(p);
  } catch {
    return null;
  }
}

async function readdirOrEmpty(dir) {
  try {
    return await fsp.readdir(dir, { withFileTypes: true });
  } catch {
    return [];
  }
}

// ---------- фото и отметки аудита ----------
// Накопительная копия: новые и изменившиеся файлы копируются, ничего не удаляется (D-30). Без шифрования: в папке
// копий (media\<name>) и вне сервера файлы лежат в открытом виде.
export async function mediaSync(c, { signal } = {}) {
  const L = layout(c);
  let copied = 0;
  let bytes = 0;
  const walk = async (srcDir, dstDir) => {
    for (const ent of await readdirOrEmpty(srcDir)) {
      if (signal?.aborted) throw abortError();
      const s = path.join(srcDir, ent.name);
      const d = path.join(dstDir, ent.name);
      if (ent.isDirectory()) {
        await walk(s, d);
        continue;
      }
      if (!ent.isFile()) continue;
      const ss = await fsp.stat(s);
      const ds = await statOrNull(d);
      if (ds && ds.size === ss.size && ds.mtimeMs >= ss.mtimeMs) continue;
      await fsp.mkdir(dstDir, { recursive: true });
      const tmp = `${d}.tmp-${process.pid}-${crypto.randomBytes(4).toString('hex')}`;
      await copyFileAbortable(s, tmp, signal);
      await fsp.utimes(tmp, ss.atime, ss.mtime);
      await fsp.rename(tmp, d);
      copied++;
      bytes += ss.size;
    }
  };
  for (const m of c.mediaDirs) {
    if (!fs.existsSync(m.path)) {
      log('warn', `фото: каталог ${m.path} не найден — пропуск`);
      continue;
    }
    await walk(m.path, path.join(L.media, m.name));
  }
  log('info', `фото: скопировано файлов ${copied} (${bytes} байт)`);
  return { copied, bytes };
}

// ---------- копия вне сервера ----------
// Копирует готовые файлы в offsite.path (например, общая папка \\nas\optomstroy). Там ничего не удаляется и не
// перезаписывается: файл уже есть с тем же размером — пропуск; с другим размером — предупреждение (конфликт).
// since (мс) — копировать только файлы, изменённые не раньше этого момента (проход WAL раз в 5 минут не
// перечисляет весь архив на общей папке: проверяются только сегменты, опубликованные после прошлого успеха).
async function offsiteCopyTree(srcRoot, dstRoot, filter, stats, signal, since = null) {
  for (const ent of await readdirOrEmpty(srcRoot)) {
    if (signal?.aborted) throw abortError();
    const s = path.join(srcRoot, ent.name);
    const d = path.join(dstRoot, ent.name);
    if (ent.isDirectory()) {
      await offsiteCopyTree(s, d, filter, stats, signal, since);
      continue;
    }
    if (!ent.isFile() || !filter(ent.name)) continue;
    const ss = await fsp.stat(s);
    if (since !== null && ss.mtimeMs < since) continue;
    stats.checked++;
    const size = ss.size;
    const ds = await statOrNull(d);
    if (ds) {
      if (ds.size !== size) {
        stats.conflicts++;
        log('warn', `вне сервера: ${d} уже есть с другим размером — не перезаписывается`);
      }
      continue;
    }
    await fsp.mkdir(dstRoot, { recursive: true });
    const tmp = `${d}.partial-${process.pid}-${crypto.randomBytes(4).toString('hex')}`;
    await copyFileAbortable(s, tmp, signal);
    if ((await fsp.stat(tmp)).size !== size) {
      await fsp.rm(tmp, { force: true }).catch(() => {});
      throw new Error(`вне сервера: ${d} скопирован не полностью`);
    }
    await fsp.rename(tmp, d);
    stats.copied++;
    stats.bytes += size;
  }
}

const isFinished = (n) => !n.includes('.partial') && !n.includes('.tmp-') && !n.endsWith('.lock');

// Окно прохода WAL (как wal_upload в Linux): от НАЧАЛА прошлого полностью успешного прохода минус 15 минут запаса,
// не меньше 2 часов. Отметки нет — весь архив. Отметка двигается только после прохода без ошибок.
export const WAL_OFFSITE_MARGIN_MS = 15 * 60000;
export const WAL_OFFSITE_MIN_WINDOW_MS = 2 * 3600000;

// Проходы копии вне сервера в одном процессе выполняются по очереди: ночной (ежедневный прогон) и WAL-проход
// (цикл WAL) иначе копировали бы один и тот же файл одновременно.
// skipIfBusy (цикл WAL): проход уже идёт — сразу { busy: true }, чтобы не ждать многогигабайтную ночную копию и
// не задерживать отправку WAL из спула (как код 75 у wal_upload в Linux).
let offsiteQueue = Promise.resolve();
let offsiteRunning = 0;

export function offsiteCopy(c, opts = {}) {
  if (opts.skipIfBusy && offsiteRunning > 0) return Promise.resolve({ busy: true });
  offsiteRunning++;
  const run = offsiteQueue.then(() => offsiteCopyNow(c, opts)).finally(() => offsiteRunning--);
  offsiteQueue = run.catch(() => {});
  return run;
}

async function offsiteCopyNow(c, { walOnly = false, signal, now = Date.now() } = {}) {
  if (!c.offsite) return { skipped: true };
  const L = layout(c);
  const stats = { copied: 0, bytes: 0, conflicts: 0, checked: 0 };
  const startedUtc = new Date(now).toISOString();
  if (!fs.existsSync(c.offsite.path)) throw new Error(`вне сервера: ${c.offsite.path} недоступен`);
  let since = null;
  if (walOnly) {
    const prev = Date.parse(readStatus(c).lastWalOffsiteUtc ?? '');
    if (Number.isFinite(prev) && prev <= now) since = Math.min(prev - WAL_OFFSITE_MARGIN_MS, now - WAL_OFFSITE_MIN_WINDOW_MS);
  }
  // WAL и базовые копии
  await offsiteCopyTree(L.pitr, path.join(c.offsite.path, 'pitr'), (n) => isFinished(n) && !n.endsWith('.plain.json'), stats, signal, since);
  if (!walOnly) {
    await offsiteCopyTree(L.dumps, path.join(c.offsite.path, 'dumps'), isFinished, stats, signal);
    await offsiteCopyTree(L.media, path.join(c.offsite.path, 'media'), isFinished, stats, signal);
  }
  const patch = walOnly ? { lastWalOffsiteUtc: startedUtc } : { lastOffsiteUtc: startedUtc, lastWalOffsiteUtc: startedUtc };
  patch.offsiteConflicts = stats.conflicts || (walOnly ? readStatus(c).offsiteConflicts ?? 0 : 0);
  updateStatus(c, patch);
  log('info', `вне сервера${walOnly ? ' (WAL)' : ''}: проверено ${stats.checked}, скопировано ${stats.copied} (${stats.bytes} байт), конфликтов ${stats.conflicts}`);
  return stats;
}

// ---------- очистка по срокам хранения ----------
function rmWithSidecars(f) {
  for (const s of ['', '.sha256', '.json', '.plain.json']) rmQuiet(`${f}${s}`);
}

export const KEEP_MIN_DUMPS = 3;

export function prune(c, { now = new Date() } = {}) {
  const L = layout(c);
  const day = 86400000;
  const removed = [];
  const older = (name, prefixRe, days) => {
    const m = prefixRe.exec(name);
    const d = m ? stampToDate(m[1]) : null;
    return d && now - d > days * day;
  };
  // Самые новые KEEP_MIN_DUMPS ежедневных дампов не удаляются никогда (отличие от Linux: если pg_dump падает дольше
  // keepDays, без этой защиты остались бы только месячные копии).
  const dumpNames = listDir(L.dumps).filter((n) => /^\d{8}-\d{6}\.dump\.optbk$/.test(n) && fs.existsSync(path.join(L.dumps, `${n}.json`))).sort();
  const keepDumps = new Set(dumpNames.slice(-KEEP_MIN_DUMPS));
  for (const n of listDir(L.dumps)) {
    const f = path.join(L.dumps, n);
    if (n.endsWith('.dump.optbk') && !keepDumps.has(n) && older(n, /^(\d{8}-\d{6})\.dump\.optbk$/, c.keepDays)) rmWithSidecars(f), removed.push(f);
    else if (n.endsWith('.sql.optbk') && older(n, /^globals-(\d{8}-\d{6})\.sql\.optbk$/, c.globalsKeepDays)) rmWithSidecars(f), removed.push(f);
    else if (n.includes('.partial') && now - fs.statSync(f).mtime > day) rmQuiet(f), removed.push(f);
  }
  for (const n of listDir(L.monthly)) {
    if (n.endsWith('.dump.optbk') && older(n, /^(\d{8}-\d{6})\.dump\.optbk$/, c.keepDays + c.monthlyExtraDays)) {
      const f = path.join(L.monthly, n);
      rmWithSidecars(f);
      removed.push(f);
    }
  }
  // PITR: базовые копии keepDays суток, самая новая не удаляется; WAL — пока нужен самой старой оставшейся копии.
  for (const sysid of listDir(L.pitr)) {
    const baseDir = path.join(L.pitr, sysid, 'base');
    const walDir = path.join(L.pitr, sysid, 'wal');
    const bases = listDir(baseDir).filter((n) => /^base-\d{8}-\d{6}\.tar\.gz\.optbk$/.test(n)).sort();
    const withInfo = bases.filter((n) => fs.existsSync(path.join(baseDir, `${n}.json`)));
    const newest = withInfo[withInfo.length - 1];
    for (const n of bases) {
      const f = path.join(baseDir, n);
      if (n !== newest && older(n, /^base-(\d{8}-\d{6})\./, c.keepDays)) rmWithSidecars(f), removed.push(f);
    }
    for (const n of listDir(baseDir)) if (n.includes('.partial') && now - fs.statSync(path.join(baseDir, n)).mtime > day) rmQuiet(path.join(baseDir, n));
    const remaining = listDir(baseDir).filter((n) => /^base-.*\.tar\.gz\.optbk$/.test(n) && fs.existsSync(path.join(baseDir, `${n}.json`))).sort();
    const oldest = remaining.length ? readJson(path.join(baseDir, `${remaining[0]}.json`), {}) : null;
    const keepFrom = oldest?.startWal ? walPos(oldest.startWal) : null;
    for (const n of listDir(walDir)) {
      if (n.endsWith('.gz.optbk.plain.json')) {
        // отпечаток без архива: обрыв wal-ship между отпечатком и публикацией (сегмент остался в спуле)
        const f = path.join(walDir, n);
        // Сегмент, удалённый выше в этом же проходе (rmWithSidecars), уже унёс свой .plain.json: список listDir снят
        // до удаления, поэтому сначала проверка, что отпечаток ещё есть (иначе ENOENT и «прогон с ошибками»).
        if (!fs.existsSync(f)) continue;
        if (!fs.existsSync(f.slice(0, -'.plain.json'.length)) && now - fs.statSync(f).mtime > day) rmQuiet(f), removed.push(f);
        continue;
      }
      if (!n.endsWith('.gz.optbk')) continue;
      const seg = n.slice(0, -'.gz.optbk'.length);
      const f = path.join(walDir, n);
      if (seg.endsWith('.history')) continue; // файлы линий времени маленькие и нужны всегда
      const pos = walPos(seg);
      const drop = keepFrom ? pos && pos < keepFrom : now - fs.statSync(f).mtime > c.keepDays * day;
      if (drop) rmWithSidecars(f), removed.push(f);
    }
  }
  log('info', `очистка: удалено ${removed.length}`);
  return removed;
}

// ---------- проверка файла без ключа ----------
export async function verifyFileNoKey(file) {
  const res = { file, ok: true, problems: [] };
  try {
    res.structure = await inspectStream(fs.createReadStream(file));
  } catch (e) {
    res.ok = false;
    res.problems.push(`структура: ${e.message}`);
  }
  res.size = fs.statSync(file).size;
  res.sha256 = await sha256File(file);
  if (fs.existsSync(`${file}.sha256`)) {
    const want = fs.readFileSync(`${file}.sha256`, 'utf8').trim().split(/\s+/)[0];
    res.sha256Sidecar = want === res.sha256 ? 'совпадает' : 'НЕ совпадает';
    if (want !== res.sha256) res.ok = false, res.problems.push('SHA-256 не совпадает с .sha256');
  } else res.sha256Sidecar = 'нет файла .sha256';
  const man = readJson(`${file}.json`);
  if (man) {
    res.manifest = 'есть';
    if (man.sha256 !== res.sha256 || man.size !== res.size) res.ok = false, res.problems.push('размер или SHA-256 не совпадают с манифестом .json');
    if (res.structure && man.keyId && man.keyId !== res.structure.keyId) res.ok = false, res.problems.push('keyId заголовка не совпадает с манифестом');
  } else res.manifest = 'нет';
  return res;
}

// ---------- состояние для мониторинга ----------
export const DAEMON_STALE_MINUTES = 3;
export const RESTORE_DRILL_MAX_DAYS = 35;

// Проблемы настройки и порядка работы, а не сбои копирования: status их показывает (код 1), служба пишет их в журнал,
// но /fail в Healthchecks из-за них не отправляет — иначе проверка была бы «красной» постоянно и настоящий сбой
// (дамп, WAL) не отличался бы от ненастроенной копии вне сервера.
//   offsite-not-configured   — копии вне сервера нет (16 §8.1: обязательна): offsite = null и не {"mode": "pull"};
//   alerting-not-configured  — оповещения нет: healthchecksUrlFile = null и alerting не "external";
//   restore-drill-older-35d  — проверки восстановления (restore-drill.ps1) не было дольше 35 суток.
export const CONFIG_RISK_PROBLEMS = Object.freeze(['offsite-not-configured', 'alerting-not-configured', 'restore-drill-older-35d']);

export function offsiteMode(c) {
  if (c.offsite) return 'push';
  return c.offsitePull ? 'pull' : null;
}

export function alertingMode(c) {
  if (c.healthchecksUrlFile) return 'healthchecks';
  return c.alerting === 'external' ? 'external' : null;
}

export async function status(c, { now = new Date(), queryDb = true } = {}) {
  const L = layout(c);
  const st = readStatus(c);
  const hours = (iso) => (iso ? (now - new Date(iso)) / 3600000 : null);
  const newestIn = (dir, re) => {
    const list = listDir(dir).filter((n) => re.test(n)).sort();
    if (!list.length) return null;
    const n = list[list.length - 1];
    const man = readJson(path.join(dir, `${n}.json`), {}) ?? {};
    return { file: path.join(dir, n), size: fs.statSync(path.join(dir, n)).size, createdUtc: man.createdUtc ?? man.endUtc ?? null };
  };
  const out = { ok: true, problems: [], now: now.toISOString(), backupRoot: L.root };
  // Отсчёт порогов — с первого запуска службы (monitorSinceUtc), как .pitr_since в Linux: на свежей установке
  // «копий ещё нет» — не ошибка, пока не прошло 26 ч (для WAL вне сервера — 30 мин).
  out.monitorSinceUtc = st.monitorSinceUtc ?? null;
  const since = hours(st.monitorSinceUtc);
  const graceOver = (h) => since !== null && since > h;
  // Жив ли цикл службы: служба раз в минуту обновляет daemonHeartbeatUtc (Linux: schedule-loop-not-running).
  out.daemonHeartbeatUtc = st.daemonHeartbeatUtc ?? null;
  const hb = hours(st.daemonHeartbeatUtc);
  if (hb === null || hb * 60 > DAEMON_STALE_MINUTES) out.problems.push('daemon-not-running');
  out.lastDump = newestIn(L.dumps, /^\d{8}-\d{6}\.dump\.optbk$/);
  out.lastGlobals = newestIn(L.dumps, /^globals-.*\.sql\.optbk$/);
  out.lastDailyRun = st.lastDailyRun ?? null;
  out.lastError = st.lastError ?? null;
  const ageDump = out.lastDump ? hours(stampToDate(path.basename(out.lastDump.file).slice(0, 15)).toISOString()) : null;
  out.lastDumpAgeHours = ageDump === null ? null : Math.round(ageDump * 10) / 10;
  if (ageDump === null ? graceOver(26) : ageDump > 26) out.problems.push('dump-older-26h');
  let dumpsBytes = 0;
  for (const n of listDir(L.dumps)) if (n.endsWith('.optbk')) dumpsBytes += fs.statSync(path.join(L.dumps, n)).size;
  out.dumpsBytes = dumpsBytes;
  if (c.pitr) {
    let newestBase = null;
    let walCount = 0;
    let walBytes = 0;
    for (const sysid of listDir(L.pitr)) {
      const b = newestIn(path.join(L.pitr, sysid, 'base'), /^base-.*\.tar\.gz\.optbk$/);
      if (b && (!newestBase || b.createdUtc > newestBase.createdUtc)) newestBase = { ...b, systemIdentifier: sysid };
      for (const n of listDir(path.join(L.pitr, sysid, 'wal'))) {
        if (n.endsWith('.gz.optbk')) walCount++, walBytes += fs.statSync(path.join(L.pitr, sysid, 'wal', n)).size;
      }
    }
    out.lastBase = newestBase;
    out.walArchive = { files: walCount, bytes: walBytes, lastShipUtc: st.lastWalShipUtc ?? null };
    const ageBase = newestBase?.createdUtc ? hours(newestBase.createdUtc) : null;
    if (ageBase === null ? graceOver(26) : ageBase > 26) out.problems.push('base-older-26h');
    const spool = listDir(c.walSpoolDir).filter((n) => WAL_NAME.test(n));
    let oldestMin = 0;
    for (const n of spool) oldestMin = Math.max(oldestMin, (now - fs.statSync(path.join(c.walSpoolDir, n)).mtime) / 60000);
    out.walSpool = { files: spool.length, oldestMinutes: Math.round(oldestMin) };
    if (oldestMin > 10) out.problems.push('wal-spool-stuck-10m');
    if (queryDb) {
      try {
        const r = await psql(c, "SELECT archived_count, failed_count, coalesce(last_failed_wal,''), coalesce(last_failed_time::text,''), coalesce(last_archived_time::text,''), current_setting('archive_mode') FROM pg_stat_archiver");
        const [archived, failed, lastFailedWal, lastFailedTime, lastArchivedTime, mode] = r.split('|');
        out.archiver = { archived: +archived, failed: +failed, lastFailedWal, lastFailedTime, lastArchivedTime, archiveMode: mode };
        if (mode !== 'on' && mode !== 'always') out.problems.push('archive-mode-off');
        if (lastFailedTime && (!lastArchivedTime || new Date(lastFailedTime) > new Date(lastArchivedTime))) out.problems.push('wal-archive-failing');
      } catch (e) {
        out.archiver = { error: e.message };
        out.problems.push('db-unreachable');
      }
    }
    if (c.offsite) {
      const w = hours(st.lastWalOffsiteUtc);
      out.lastWalOffsiteUtc = st.lastWalOffsiteUtc ?? null;
      if (w === null ? graceOver(0.5) : w > 0.5) out.problems.push('wal-offsite-older-30m');
    }
  }
  if (c.offsite) {
    out.lastOffsiteUtc = st.lastOffsiteUtc ?? null;
    const o = hours(st.lastOffsiteUtc);
    if (o === null ? graceOver(26) : o > 26) out.problems.push('offsite-older-26h');
    if (st.offsiteConflicts) out.problems.push('offsite-conflicts');
  }
  // Риски настройки (CONFIG_RISK_PROBLEMS): видны сразу после установки, без отсрочки monitorSinceUtc.
  out.offsiteMode = offsiteMode(c);
  out.alerting = alertingMode(c);
  if (!out.offsiteMode) out.problems.push('offsite-not-configured');
  if (!out.alerting) out.problems.push('alerting-not-configured');
  // Проверка восстановления (restore-drill.ps1, 16 §8.1 — ежемесячно): итог пишет drill-record.
  out.lastRestoreDrill = st.lastRestoreDrill ?? null;
  out.lastRestoreDrillOkUtc = st.lastRestoreDrillOkUtc ?? null;
  if (st.lastRestoreDrill && st.lastRestoreDrill.result !== 'ok') out.problems.push('restore-drill-failed');
  const drillDays = hours(st.lastRestoreDrillOkUtc);
  if (drillDays === null ? graceOver(RESTORE_DRILL_MAX_DAYS * 24) : drillDays > RESTORE_DRILL_MAX_DAYS * 24) out.problems.push('restore-drill-older-35d');
  if (st.lastError && (!st.lastDailyRun || new Date(st.lastError.utc) > new Date(st.lastDailyRun.finishedUtc ?? 0))) out.problems.push('last-run-failed');
  out.ok = out.problems.length === 0;
  return out;
}

// ---------- оповещение Healthchecks (как ping_hc в Linux) ----------
// healthchecksUrlFile — файл секрета с адресом проверки (https://hc-ping.com/<uuid> или свой сервер Healthchecks).
// suffix: '' — успех, '/start' — начало, '/fail' — ошибка. Адрес в журнал не пишется. Ошибка доставки — только
// предупреждение (копия важнее оповещения).
export async function pingHealthchecks(c, suffix, body = '') {
  if (!c.healthchecksUrlFile) return false;
  let url;
  try {
    url = fs.readFileSync(c.healthchecksUrlFile, 'utf8').trim();
  } catch (e) {
    log('warn', `healthchecks: файл адреса не прочитан (${e.code ?? e.message})`);
    return false;
  }
  if (!/^https?:\/\/\S+$/.test(url)) {
    log('warn', 'healthchecks: в файле адреса не адрес http(s)');
    return false;
  }
  try {
    const r = await fetch(`${url}${suffix}`, { method: 'POST', body: String(body).slice(0, 10000), signal: AbortSignal.timeout(10000) });
    if (!r.ok) {
      log('warn', `healthchecks: ответ ${r.status} на ping${suffix || ' (успех)'}`);
      return false;
    }
    return true;
  } catch (e) {
    log('warn', `healthchecks: ping${suffix || ' (успех)'} не доставлен (${e.name})`);
    return false;
  }
}

// ---------- итог проверки восстановления (restore-drill.ps1 → drill-record) ----------
// В state\status.json: lastRestoreDrill (последняя попытка) и lastRestoreDrillOkUtc (последний успех) — по ним status
// выдаёт restore-drill-failed и restore-drill-older-35d. pingUrlFile — отдельная проверка Healthchecks «restore-drill»
// (как --ping-url-file у backup-restore-test.sh в Linux): успех — ping, ошибка — /fail.
export async function recordRestoreDrill(c, { result, dump = null, seconds = null, detail = '', pingUrlFile = null, now = new Date() }) {
  if (result !== 'ok' && result !== 'fail') throw new Error('drill-record: --result ok или fail');
  const utc = now.toISOString();
  const rec = { utc, result, dump: dump ? path.basename(dump) : null, seconds: seconds === null ? null : Number(seconds), detail: String(detail).slice(0, 2000) };
  const s = updateStatus(c, { lastRestoreDrill: rec, ...(result === 'ok' ? { lastRestoreDrillOkUtc: utc } : {}) });
  log(result === 'ok' ? 'info' : 'error', `проверка восстановления: ${result === 'ok' ? 'копия восстанавливается' : 'НЕ пройдена'}${rec.dump ? ` (${rec.dump})` : ''}${rec.detail ? ` — ${rec.detail}` : ''}`);
  if (pingUrlFile) await pingHealthchecks({ healthchecksUrlFile: pingUrlFile }, result === 'ok' ? '' : '/fail', `restore-drill ${result}${rec.dump ? ` ${rec.dump}` : ''}\n${rec.detail}`);
  return s;
}

// Базовая копия уже сделана в этот местный день (по метке UTC в имени файла и часовому поясу расписания).
export function baseDoneOnLocalDate(c, localDate) {
  const L = layout(c);
  for (const sysid of listDir(L.pitr)) {
    const dir = path.join(L.pitr, sysid, 'base');
    for (const n of listDir(dir)) {
      const m = /^base-(\d{8}-\d{6})\.tar\.gz\.optbk$/.exec(n);
      if (!m || !fs.existsSync(path.join(dir, `${n}.json`))) continue;
      const d = stampToDate(m[1]);
      if (d && zonedParts(d, c.timeZone).date === localDate) return true;
    }
  }
  return false;
}

// ---------- только дамп (обновление программы: «копия создана — можно обновлять») ----------
// dump-only: дамп + .sha256/.json + месячная копия. Код 0 — дамп опубликован; базовая копия, фото, вне сервера и
// очистка не выполняются (недоступное хранилище вне сервера не должно останавливать обновление).
export async function dumpOnly(c, { signal, now = new Date() } = {}) {
  const m = await dumpDatabase(c, { signal, now });
  updateStatus(c, { lastDumpOnly: { utc: new Date().toISOString(), dump: path.join(layout(c).dumps, m.file), dumpSize: m.size } });
  return m;
}

// ---------- ежедневный прогон ----------
// Порядок как в комплекте Linux: дамп → месячная копия → globals (в день globalsWeekday) → базовая копия PITR →
// фото → вне сервера → очистка. Отличия от «все шаги всегда»:
//   - базовая копия — не больше одной за местный день: повтор прогона через retryMinutes (дамп не удался) её не
//     повторяет, иначе при постоянном сбое pg_dump каждые 30 минут появлялась бы новая полная копия (тома копий и
//     хранилище вне сервера заполнились бы за сутки);
//   - при сбое дампа очистка не выполняется (как в Linux, где прогон заканчивается сразу после сбоя дампа):
//     старые дампы не удаляются, пока нет нового. Фото и копия вне сервера — накопительные и выполняются.
export async function dailyRun(c, { signal, now = new Date(), force = false } = {}) {
  const release = takeLock(c, 'daily');
  if (!release) throw new Error('ежедневный прогон уже выполняется (state\\daily.lock)');
  const errors = [];
  const startedUtc = new Date().toISOString();
  const zp = zonedParts(now, c.timeZone);
  const step = async (name, fn) => {
    if (signal?.aborted) return;
    try {
      await fn();
    } catch (e) {
      errors.push(`${name}: ${e.message}`);
      log('error', `${name}: ${e.message}`);
    }
  };
  try {
    await pingHealthchecks(c, '/start');
    let dump = null;
    await step('дамп', async () => (dump = await dumpDatabase(c, { signal, now })));
    if (zp.weekday === c.globalsWeekday || force) await step('globals', () => dumpGlobals(c, { signal, now }));
    if (c.pitr) {
      if (baseDoneOnLocalDate(c, zp.date)) log('info', `базовая копия за ${zp.date} уже есть — пропуск (одна в день)`);
      else await step('базовая копия', () => baseBackup(c, { signal, now }));
    }
    await step('фото', () => mediaSync(c, { signal }));
    if (c.offsite) await step('вне сервера', () => offsiteCopy(c, { signal }));
    if (dump) await step('очистка', () => prune(c, { now }));
    else log('warn', 'очистка пропущена: дамп не создан (старые копии не удаляются)');
    if (signal?.aborted) errors.push('прервано остановкой службы');
    const finishedUtc = new Date().toISOString();
    updateStatus(c, { lastDailyAttempt: { localDate: zp.date, utc: finishedUtc, dumpOk: !!dump } });
    if (errors.length) {
      updateStatus(c, { lastError: { utc: finishedUtc, localDate: zp.date, errors } });
      await pingHealthchecks(c, '/fail', errors.join('\n'));
      throw new Error(`ежедневный прогон с ошибками: ${errors.join('; ')}`);
    }
    updateStatus(c, { lastDailyRun: { startedUtc, finishedUtc, localDate: zp.date, dump: dump?.file, dumpSize: dump?.size }, lastError: null });
    await pingHealthchecks(c, '');
    log('info', 'ежедневный прогон завершён успешно');
  } finally {
    release();
  }
}

