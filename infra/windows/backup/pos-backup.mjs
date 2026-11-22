#!/usr/bin/env node
// pos-backup — резервное копирование POS под Windows Server без сторонних программ (infra/windows/backup/README.md).
// Работает на node.exe из релиза (Node 24), зависимостей npm нет. Команды:
//   keygen --out <папка> [--passphrase-file <файл>] [--no-passphrase]   пара ключей RSA-4096 (ПК держателя ключа)
//   daemon --config <backup.json>        служба OptomstroyBackup: расписание, WAL, вне сервера; стоп — конец stdin
//   dump-now --config <backup.json> [--globals]   ежедневный прогон сейчас (дамп, globals, база PITR, фото, …)
//   dump-only --config <backup.json>     только дамп (перед обновлением программы; код 0 — дамп опубликован)
//   base-now | wal-ship | media-now | prune --config <backup.json>     отдельные шаги
//   offsite-now --config <backup.json> [--wal]     копия вне сервера сейчас (--wal — только PITR)
//   status --config <backup.json> [--no-db]        состояние для мониторинга (JSON; код 0 — норма, 1 — проблемы)
//   drill-record --config <backup.json> --result ok|fail [--dump <файл>] [--seconds N] [--detail <текст>] [--ping-url-file <файл>]
//                                                  итог проверки восстановления (restore-drill.ps1) в state\status.json
//   wal-archive (--config <backup.json> | --spool <папка>) <путь> <имя>   archive_command PostgreSQL (%p %f)
//   verify-file <файл> [--key <закрытый.pem>]      проверка копии (без ключа — структура и контрольные суммы)
//   decrypt --key <закрытый.pem> [--gunzip] <вход> <выход|->            расшифровка (ПК держателя ключа)
//   decrypt-pipe --key <закрытый.pem> [--gunzip] <вход> -- <программа> [аргументы…]  расшифровка в stdin программы
//   restore-base --key <закрытый.pem> <base-….tar.gz.optbk> --to <пустая папка>      распаковка базовой копии
//   wal-unpack --key <закрытый.pem> --from <папка wal> --to <папка> [--start-wal <сегмент>] [--allow-gap]  WAL для PITR
//              (код 3 — архив с дырой или повреждённым сегментом: распакован непрерывный отрезок)
//   key-id --public <открытый.pem>                 отпечаток ключа (keyId)
// Парольная фраза закрытого ключа: --passphrase-file <файл>, переменная POS_BACKUP_KEY_PASSPHRASE или ввод с
// клавиатуры. Коды выхода: 0 — успех, 1 — ошибка, 2 — неверный вызов.

import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { spawn } from 'node:child_process';
import { pipeline } from 'node:stream/promises';

import { OptbkError, decryptStream, generateKeyPair, loadPrivateKey, loadPublicKey, publicKeyId } from './lib/optbk.mjs';
import { extractTar } from './lib/tar.mjs';
import { UsageError, WAL_NAME, layout, listDir, loadConfig, log, readJson, zonedParts } from './lib/common.mjs';
import {
  CONFIG_RISK_PROBLEMS, LOCK_STALE_MS, alertingMode, baseBackup, dailyRun, dumpOnly, lockState, mediaSync, offsiteCopy, offsiteMode,
  pingHealthchecks, prune, readStatus, recordRestoreDrill, status, takeLock, updateStatus, verifyFileNoKey, walArchive, walShip,
} from './lib/jobs.mjs';

function parseArgs(argv) {
  const opts = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--') {
      opts.rest = argv.slice(i + 1);
      break;
    }
    if (a.startsWith('--')) {
      const k = a.slice(2);
      if (['no-passphrase', 'gunzip', 'globals', 'wal', 'no-db', 'force', 'allow-gap', 'no-space-check'].includes(k)) opts[k] = true;
      else {
        if (i + 1 >= argv.length) throw new UsageError(`у ${a} нет значения`);
        opts[k] = argv[++i];
      }
    } else opts._.push(a);
  }
  return opts;
}

// ---------- парольная фраза ----------
function promptHidden(question) {
  return new Promise((resolve, reject) => {
    const stdin = process.stdin;
    if (!stdin.isTTY) return reject(new UsageError('нужна парольная фраза: --passphrase-file или POS_BACKUP_KEY_PASSPHRASE'));
    process.stderr.write(question);
    stdin.setRawMode(true);
    stdin.resume();
    let s = '';
    const onData = (d) => {
      for (const ch of d.toString('utf8')) {
        if (ch === '\r' || ch === '\n') {
          stdin.setRawMode(false);
          stdin.pause();
          stdin.off('data', onData);
          process.stderr.write('\n');
          return resolve(s);
        }
        if (ch === '\u0003') {
          stdin.setRawMode(false);
          return reject(new UsageError('ввод прерван'));
        }
        if (ch === '\u0008' || ch === '\u007f') s = s.slice(0, -1);
        else s += ch;
      }
    };
    stdin.on('data', onData);
  });
}

async function passphraseFrom(opts) {
  if (opts['passphrase-file']) return fs.readFileSync(opts['passphrase-file'], 'utf8').replace(/[\r\n]+$/, '');
  if (process.env.POS_BACKUP_KEY_PASSPHRASE) return process.env.POS_BACKUP_KEY_PASSPHRASE;
  return null;
}

async function privateKey(opts) {
  if (!opts.key) throw new UsageError('не указан --key <закрытый ключ .pem>');
  const pem = fs.readFileSync(opts.key, 'utf8');
  let pass = await passphraseFrom(opts);
  if (!pass && pem.includes('ENCRYPTED')) pass = await promptHidden('Парольная фраза закрытого ключа: ');
  return loadPrivateKey(opts.key, pass);
}

// ---------- команды ----------
async function cmdKeygen(opts) {
  const out = opts.out;
  if (!out) throw new UsageError('не указан --out <папка>');
  fs.mkdirSync(out, { recursive: true });
  const priv = path.join(out, 'backup-private.pem');
  const pub = path.join(out, 'backup-public.pem');
  if (fs.existsSync(priv) || fs.existsSync(pub)) throw new UsageError(`в ${out} уже есть ключи — не перезаписываются`);
  let pass = null;
  if (!opts['no-passphrase']) {
    pass = await passphraseFrom(opts);
    if (!pass) {
      pass = await promptHidden('Парольная фраза для закрытого ключа (не короче 12 символов): ');
      const again = await promptHidden('Повторите парольную фразу: ');
      if (pass !== again) throw new UsageError('парольные фразы не совпадают');
    }
    if (pass.length < 12) throw new UsageError('парольная фраза короче 12 символов');
  }
  const kp = generateKeyPair(pass);
  fs.writeFileSync(priv, kp.privateKey, { flag: 'wx' });
  fs.writeFileSync(pub, kp.publicKey, { flag: 'wx' });
  const id = publicKeyId(kp.publicKey).toString('hex');
  fs.writeFileSync(path.join(out, 'key-id.txt'), `${id}\n`);
  process.stdout.write(`Ключи созданы в ${out}\n  открытый (на сервер): backup-public.pem\n  закрытый (НЕ на сервер; хранить офлайн, сделать вторую копию): backup-private.pem${pass ? ' (защищён парольной фразой)' : ' (БЕЗ парольной фразы)'}\n  keyId: ${id}\n`);
}

async function cmdDecrypt(opts) {
  const [inp, outp] = opts._;
  if (!inp || !outp) throw new UsageError('decrypt --key <закрытый.pem> [--gunzip] <вход> <выход|->');
  const key = await privateKey(opts);
  const stages = [fs.createReadStream(inp), decryptStream(key)];
  if (opts.gunzip) stages.push(zlib.createGunzip());
  if (outp === '-') {
    stages.push(process.stdout);
    await pipeline(stages);
    return;
  }
  const tmp = `${outp}.partial`;
  stages.push(fs.createWriteStream(tmp, { flags: 'wx' }));
  try {
    await pipeline(stages);
  } catch (e) {
    fs.rmSync(tmp, { force: true });
    throw e;
  }
  fs.renameSync(tmp, outp);
  process.stderr.write(`расшифровано: ${outp}\n`);
}

// decrypt-pipe: поток расшифровки идёт в stdin программы (pg_restore, psql). Успех — только если и расшифровка
// (все куски подлинны, последний кусок на месте), и программа завершились без ошибок. PowerShell 5.1 не передаёт
// двоичные данные между программами конвейером «|», поэтому восстановление идёт через эту команду.
async function cmdDecryptPipe(opts) {
  const [inp] = opts._;
  const rest = opts.rest ?? [];
  if (!inp || !rest.length) throw new UsageError('decrypt-pipe --key <закрытый.pem> [--gunzip] <вход> -- <программа> [аргументы…]');
  const key = await privateKey(opts);
  const child = spawn(rest[0], rest.slice(1), { stdio: ['pipe', 'inherit', 'inherit'], windowsHide: true });
  const exited = new Promise((resolve) => {
    child.on('error', (e) => resolve({ code: -1, error: e }));
    child.on('close', (code) => resolve({ code }));
  });
  child.stdin.on('error', () => {}); // программа завершилась раньше — причину покажет её код выхода
  const stages = [fs.createReadStream(inp), decryptStream(key)];
  if (opts.gunzip) stages.push(zlib.createGunzip());
  stages.push(child.stdin);
  let perr = null;
  try {
    await pipeline(stages);
  } catch (e) {
    perr = e;
    child.kill();
  }
  const ex = await exited;
  if (perr && !(perr.code === 'EPIPE' || perr.code === 'ERR_STREAM_DESTROYED')) throw new Error(`расшифровка прервана: ${perr.message}`);
  if (ex.error) throw new Error(`${rest[0]} не запущен: ${ex.error.message}`);
  if (ex.code !== 0) throw new Error(`${path.basename(rest[0])} завершился с кодом ${ex.code}`);
  if (perr) throw new Error(`расшифровка прервана: ${perr.message}`);
  process.stderr.write(`decrypt-pipe: расшифровка и ${path.basename(rest[0])} завершены успешно\n`);
}

// Свободное место на томе папки (папка может ещё не существовать — берётся ближайшая существующая родительская).
function freeBytes(dir) {
  let d = path.resolve(dir);
  while (!fs.existsSync(d)) {
    const up = path.dirname(d);
    if (up === d) break;
    d = up;
  }
  const s = fs.statfsSync(d);
  return Number(s.bavail) * Number(s.bsize);
}

const GiB = 1024 ** 3;

function assertSpace(dir, need, what, opts) {
  if (opts['no-space-check']) return;
  const free = freeBytes(dir);
  const want = need + SPACE_MARGIN;
  if (free < want) {
    throw new Error(`${what}: на томе ${dir} свободно ${(free / GiB).toFixed(1)} ГиБ, нужно не меньше ${(want / GiB).toFixed(1)} ГиБ (оценка ${(need / GiB).toFixed(1)} ГиБ + запас 1 ГиБ). Выберите папку на другом томе или освободите место (--no-space-check — без проверки)`);
  }
  process.stderr.write(`${what}: оценка ${(need / GiB).toFixed(2)} ГиБ, свободно ${(free / GiB).toFixed(1)} ГиБ — достаточно\n`);
}
const SPACE_MARGIN = GiB;

async function cmdRestoreBase(opts) {
  const [inp] = opts._;
  if (!inp || !opts.to) throw new UsageError('restore-base --key <закрытый.pem> <base-….tar.gz.optbk> --to <пустая папка>');
  if (fs.existsSync(opts.to) && fs.readdirSync(opts.to).length) throw new UsageError(`папка ${opts.to} не пуста`);
  const man = readJson(`${inp}.json`, {}) ?? {};
  const tarBytes = Number(man.tarBytes ?? man.plainBytes) || 0;
  if (tarBytes) assertSpace(opts.to, tarBytes, 'restore-base', opts);
  else process.stderr.write('restore-base: в манифесте .json нет tarBytes — место на диске не оценено\n');
  const key = await privateKey(opts);
  // расшифровка → gunzip → распаковка tar; ошибка любого звена — отказ (pipeline разрушает gunzip с ошибкой,
  // и чтение в extractTar её получает)
  const gunzip = zlib.createGunzip();
  const piped = pipeline(fs.createReadStream(inp), decryptStream(key), gunzip);
  const [st] = await Promise.all([extractTar(gunzip, opts.to), piped]);
  process.stderr.write(`restore-base: распаковано файлов ${st.files}, каталогов ${st.dirs}, ${st.bytes} байт → ${opts.to}\n`);
}

// wal-unpack: расшифровка архива WAL для PITR.
//   - Непрерывность: номера сегментов (без линии времени: на развилке один номер есть на двух линиях) от
//     --start-wal до самого нового должны идти без пропусков. Дыра — распаковка останавливается перед ней.
//   - Повреждённый или подменённый сегмент — распаковка останавливается на нём (всё до него уже на диске).
//   - Место: число сегментов × размер сегмента (--segment-mb, по умолчанию 16) против свободного места тома.
// Код 0 — весь архив; код 3 — распакован непрерывный отрезок до дыры или повреждения (восстановление возможно
// только до последнего распакованного сегмента; см. строку «wal-unpack: НЕПОЛНЫЙ АРХИВ»); 1 — ошибка.
const WAL_UNPACK_INCOMPLETE = 3;

function walSegno(name, segsPerLog) {
  if (!/^[0-9A-F]{24}/.test(name)) return null;
  return BigInt(`0x${name.slice(8, 16)}`) * segsPerLog + BigInt(`0x${name.slice(16, 24)}`);
}

async function cmdWalUnpack(opts) {
  if (!opts.from || !opts.to) throw new UsageError('wal-unpack --key <закрытый.pem> --from <папка wal> --to <папка> [--start-wal <сегмент>] [--allow-gap] [--segment-mb 16]');
  const segMb = Number(opts['segment-mb'] ?? 16);
  if (![1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024].includes(segMb)) throw new UsageError('--segment-mb: степень двойки 1…1024');
  const segBytes = segMb * 1024 * 1024;
  const segsPerLog = 0x100000000n / BigInt(segBytes);
  const startName = opts['start-wal'] ?? null;
  if (startName && !/^[0-9A-F]{24}$/.test(startName)) throw new UsageError('--start-wal: имя сегмента из 24 шестнадцатеричных символов');
  const start = startName ? walSegno(startName, segsPerLog) : null;

  const items = [];
  for (const f of listDir(opts.from)) {
    if (!f.endsWith('.gz.optbk')) continue;
    const name = f.slice(0, -'.gz.optbk'.length);
    if (!WAL_NAME.test(name)) continue;
    const segno = walSegno(name, segsPerLog);
    if (start !== null && segno !== null && segno < start) continue;
    items.push({ f, name, segno });
  }
  // .history — первыми (маленькие, нужны для выбора линии времени); затем по номеру сегмента и имени
  items.sort((a, b) => (a.segno === null) !== (b.segno === null) ? (a.segno === null ? -1 : 1)
    : a.segno === b.segno ? (a.name < b.name ? -1 : a.name > b.name ? 1 : 0) : (a.segno < b.segno ? -1 : 1));

  // непрерывность номеров сегментов (полные сегменты и .partial — оба покрывают свой номер)
  const have = new Set(items.filter((x) => x.segno !== null && !x.name.endsWith('.backup')).map((x) => x.segno));
  let limit = null; // последний номер непрерывного отрезка, если есть дыра
  let gapMsg = null;
  if (have.size) {
    const sorted = [...have].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
    let expect = start ?? sorted[0];
    if (sorted[0] !== expect) {
      gapMsg = `нет сегмента начала базовой копии ${startName}`;
      limit = expect - 1n;
    } else {
      for (const s of sorted) {
        if (s !== expect) {
          gapMsg = `дыра в архиве WAL: после сегмента №${expect - 1n} следующий №${s} (нет ${s - expect} шт.)`;
          limit = expect - 1n;
          break;
        }
        expect = s + 1n;
      }
    }
  } else if (start !== null) {
    gapMsg = `в архиве нет сегментов от ${startName}`;
    limit = start - 1n;
  }
  if (gapMsg && opts['allow-gap']) {
    process.stderr.write(`wal-unpack: ВНИМАНИЕ: ${gapMsg} — распаковывается всё (--allow-gap)\n`);
    limit = null;
  }
  const todo = items.filter((x) => limit === null || x.segno === null || x.segno <= limit);
  const segCount = todo.filter((x) => x.segno !== null).length;
  fs.mkdirSync(opts.to, { recursive: true });
  assertSpace(opts.to, segCount * segBytes, 'wal-unpack', opts);

  const key = await privateKey(opts);
  let n = 0;
  let lastName = null;
  let bad = null;
  for (const x of todo) {
    const dst = path.join(opts.to, x.name);
    if (fs.existsSync(dst)) continue;
    const tmp = `${dst}.partial-unpack`;
    try {
      await pipeline(fs.createReadStream(path.join(opts.from, x.f)), decryptStream(key), zlib.createGunzip(), fs.createWriteStream(tmp));
    } catch (e) {
      fs.rmSync(tmp, { force: true });
      if (x.segno === null) throw new Error(`${x.f}: ${e.message}`); // .history повреждён — без него линии времени не выбрать
      bad = `${x.f}: ${e instanceof OptbkError ? `[${e.code}] ` : ''}${e.message}`;
      break;
    }
    fs.renameSync(tmp, dst);
    n++;
    if (x.segno !== null) lastName = x.name;
  }
  process.stderr.write(`wal-unpack: расшифровано файлов WAL ${n} → ${opts.to}${lastName ? ` (последний сегмент ${lastName})` : ''}\n`);
  if (bad || (gapMsg && !opts['allow-gap'])) {
    process.stderr.write(`wal-unpack: НЕПОЛНЫЙ АРХИВ: ${bad ? `повреждён сегмент ${bad}` : gapMsg}. Восстановление возможно только до ${lastName ?? 'конца базовой копии'}.\n`);
    return WAL_UNPACK_INCOMPLETE;
  }
  return 0;
}

async function cmdVerifyFile(opts) {
  const [file] = opts._;
  if (!file) throw new UsageError('verify-file <файл> [--key <закрытый.pem>]');
  const res = await verifyFileNoKey(file);
  if (opts.key) {
    const key = await privateKey(opts);
    let bytes = 0;
    const stages = [fs.createReadStream(file), decryptStream(key)];
    if (/\.gz\.optbk$/.test(file)) stages.push(zlib.createGunzip());
    stages.push(async (src) => {
      for await (const b of src) bytes += b.length;
    });
    try {
      await pipeline(stages);
      res.decrypted = { ok: true, plainBytes: bytes };
    } catch (e) {
      res.ok = false;
      res.decrypted = { ok: false, error: e.message };
      res.problems.push(`расшифровка: ${e.message}`);
    }
  } else {
    res.note = 'без закрытого ключа подлинность кусков не проверяется: только заголовок, структура, размеры и SHA-256';
  }
  process.stdout.write(`${JSON.stringify(res, null, 2)}\n`);
  return res.ok ? 0 : 1;
}

async function cmdWalArchive(opts) {
  const [src, name] = opts._;
  let spool = opts.spool;
  if (!spool && opts.config) spool = readJson(opts.config)?.walSpoolDir;
  if (!spool) {
    process.stderr.write('wal-archive: нужен --config <backup.json> (walSpoolDir) или --spool <папка>\n');
    return 2;
  }
  return walArchive(spool, src, name);
}

// ---------- служба ----------
function sleep(ms, signal) {
  return new Promise((resolve) => {
    if (signal.aborted) return resolve();
    const t = setTimeout(resolve, ms);
    signal.addEventListener('abort', () => {
      clearTimeout(t);
      resolve();
    }, { once: true });
  });
}

function isTruthy(v) {
  return ['1', 'true', 'yes', 'on'].includes(String(v ?? '').toLowerCase());
}

async function cmdDaemon(c) {
  const ac = new AbortController();
  const stop = (why) => {
    if (ac.signal.aborted) return;
    log('info', `остановка: ${why}`);
    ac.abort();
  };
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGBREAK']) process.on(sig, () => stop(sig));
  if (isTruthy(process.env.POS_SHUTDOWN_ON_STDIN_EOF)) {
    process.stdin.on('data', () => {});
    for (const ev of ['end', 'close', 'error']) process.stdin.once(ev, () => stop('stdin-eof'));
    process.stdin.resume();
  }
  const pub = loadPublicKey(c.publicKeyFile);
  log('info', 'служба резервного копирования запущена', {
    backupRoot: c.backupRoot, dailyAt: c.dailyAt, timeZone: c.timeZone, pitr: c.pitr, offsite: offsiteMode(c), keyId: publicKeyId(pub).toString('hex'),
    healthchecks: !!c.healthchecksUrlFile, alerting: alertingMode(c),
  });
  if (!offsiteMode(c)) log('error', 'РИСК: копии вне сервера нет (offsite = null) — все копии только на этом сервере (16 §8.1: копия вне сервера обязательна; README, «Копия вне сервера»)');
  if (!alertingMode(c)) log('error', 'РИСК: оповещения нет (healthchecksUrlFile = null) — сбой копирования виден только в журнале и по status');
  fs.mkdirSync(layout(c).stateDir, { recursive: true });
  const st0 = readStatus(c);
  const nowIso = new Date().toISOString();
  updateStatus(c, { monitorSinceUtc: st0.monitorSinceUtc ?? nowIso, daemonHeartbeatUtc: nowIso, daemonPid: process.pid, daemonStartedUtc: nowIso });

  // Признак «цикл службы жив» для status (daemon-not-running), раз в минуту.
  const heartbeatLoop = async () => {
    while (!ac.signal.aborted) {
      await sleep(60000, ac.signal);
      if (ac.signal.aborted) break;
      try {
        updateStatus(c, { daemonHeartbeatUtc: new Date().toISOString() });
      } catch (e) {
        log('error', `state\\status.json не обновлён: ${e.message}`);
      }
    }
  };

  // Самопроверка (те же правила, что status) раз в statusCheckEveryMinutes: проблемы — в журнал (error) и, если
  // настроен healthchecksUrlFile, ping /fail. Так сбой архивации WAL или застрявший спул заметны без ручного status.
  const healthLoop = async () => {
    let lastKey = '';
    let lastLogged = 0;
    while (!ac.signal.aborted) {
      await sleep(c.statusCheckEveryMinutes * 60000, ac.signal);
      if (ac.signal.aborted) break;
      try {
        const s = await status(c);
        const problems = s.problems.filter((p) => p !== 'daemon-not-running');
        const key = problems.join(',');
        if (problems.length) {
          if (key !== lastKey || Date.now() - lastLogged > 3600000) {
            log('error', `самопроверка: проблемы резервного копирования: ${key}`, { problems });
            lastLogged = Date.now();
          }
          // Риски настройки (CONFIG_RISK_PROBLEMS) — только журнал и status, без /fail (см. jobs.mjs).
          const failures = problems.filter((p) => !CONFIG_RISK_PROBLEMS.includes(p));
          if (failures.length) await pingHealthchecks(c, '/fail', `pos-backup status: ${failures.join(',')}`);
        } else if (lastKey) {
          log('info', 'самопроверка: проблем больше нет');
        }
        lastKey = key;
      } catch (e) {
        log('error', `самопроверка не выполнена: ${e.message}`);
      }
    }
  };

  const walLoop = async () => {
    if (!c.pitr) return;
    let lastOffsite = 0;
    let lastLockWarn = 0;
    while (!ac.signal.aborted) {
      const release = takeLock(c, 'wal');
      if (release) {
        try {
          try {
            await walShip(c, { signal: ac.signal });
          } catch (e) {
            if (!ac.signal.aborted) log('error', e.message);
          }
          // уже зашифрованные сегменты уходят вне сервера, даже если отправка из спула застряла
          if (c.offsite && !ac.signal.aborted && Date.now() - lastOffsite >= c.walOffsiteEverySeconds * 1000) {
            try {
              const r = await offsiteCopy(c, { walOnly: true, signal: ac.signal, skipIfBusy: true });
              if (r.busy) {
                log('info', 'WAL вне сервера: идёт ночная копия вне сервера — повтор через минуту');
                lastOffsite = Date.now() - c.walOffsiteEverySeconds * 1000 + Math.min(60000, c.walOffsiteEverySeconds * 1000);
              } else lastOffsite = Date.now();
            } catch (e) {
              if (!ac.signal.aborted) log('error', `${e.message} — повтор через минуту`);
              lastOffsite = Date.now() - c.walOffsiteEverySeconds * 1000 + Math.min(60000, c.walOffsiteEverySeconds * 1000); // как Linux: сбой — повтор через минуту
            }
          }
        } finally {
          release();
        }
      } else if (Date.now() - lastLockWarn > 600000) {
        lastLockWarn = Date.now();
        const ls = lockState(path.join(layout(c).stateDir, 'wal.lock'));
        log('warn', `WAL: замок state\\wal.lock занят (PID ${ls.pid ?? '?'}, отметка ${ls.ageMs ? Math.round(ls.ageMs / 1000) : '?'} с назад) — отправка пропущена; брошенный замок снимается через ${LOCK_STALE_MS / 60000} мин`);
      }
      await sleep(c.walShipEverySeconds * 1000, ac.signal);
    }
  };

  const dailyLoop = async () => {
    while (!ac.signal.aborted) {
      const now = new Date();
      const zp = zonedParts(now, c.timeZone);
      const att = readStatus(c).lastDailyAttempt;
      const doneToday = att?.localDate === zp.date && (att.dumpOk || now - new Date(att.utc) < c.retryMinutes * 60000);
      // Пропущенный прогон (сервер или служба были остановлены в dailyAt) выполняется сразу после запуска.
      if (zp.hhmm >= c.dailyAt && !doneToday) {
        try {
          await dailyRun(c, { signal: ac.signal, now });
        } catch (e) {
          log('error', e.message);
        }
      }
      await sleep(20000, ac.signal);
    }
  };

  await Promise.all([walLoop(), dailyLoop(), heartbeatLoop(), healthLoop()]);
  try {
    updateStatus(c, { daemonHeartbeatUtc: null, daemonStoppedUtc: new Date().toISOString() });
  } catch {
    /* состояние не записано — status покажет устаревшую отметку */
  }
  log('info', 'служба резервного копирования остановлена штатно');
  return 0;
}

// ---------- точка входа ----------
async function main() {
  const [cmd, ...argv] = process.argv.slice(2);
  const opts = parseArgs(argv);
  const cfg = () => loadConfig(opts.config);
  switch (cmd) {
    case 'keygen': return cmdKeygen(opts);
    case 'key-id':
      if (!opts.public) throw new UsageError('key-id --public <открытый.pem>');
      process.stdout.write(`${publicKeyId(loadPublicKey(opts.public)).toString('hex')}\n`);
      return 0;
    case 'daemon': return cmdDaemon(cfg());
    case 'dump-now': await dailyRun(cfg(), { force: !!opts.globals }); return 0;
    case 'dump-only': {
      const m = await dumpOnly(cfg());
      process.stdout.write(`${JSON.stringify({ dump: m.file, size: m.size, sha256: m.sha256 })}\n`);
      return 0;
    }
    case 'base-now': await baseBackup(cfg()); return 0;
    case 'wal-ship': {
      const c = cfg();
      const release = takeLock(c, 'wal');
      if (!release) throw new Error('отправка WAL уже выполняется (служба)');
      try {
        await walShip(c);
      } finally {
        release();
      }
      return 0;
    }
    case 'media-now': await mediaSync(cfg()); return 0;
    case 'offsite-now': await offsiteCopy(cfg(), { walOnly: !!opts.wal }); return 0;
    case 'prune': prune(cfg()); return 0;
    case 'status': {
      const s = await status(cfg(), { queryDb: !opts['no-db'] });
      process.stdout.write(`${JSON.stringify(s, null, 2)}\n`);
      return s.ok ? 0 : 1;
    }
    case 'drill-record': {
      await recordRestoreDrill(cfg(), {
        result: opts.result, dump: opts.dump ?? null, seconds: opts.seconds ?? null, detail: opts.detail ?? '', pingUrlFile: opts['ping-url-file'] ?? null,
      });
      return 0;
    }
    case 'wal-archive': return cmdWalArchive(opts);
    case 'verify-file': return cmdVerifyFile(opts);
    case 'decrypt': return cmdDecrypt(opts);
    case 'decrypt-pipe': return cmdDecryptPipe(opts);
    case 'restore-base': return cmdRestoreBase(opts);
    case 'wal-unpack': return cmdWalUnpack(opts);
    default:
      throw new UsageError(`неизвестная команда «${cmd ?? ''}». Команды: keygen, daemon, dump-now, dump-only, base-now, wal-ship, media-now, offsite-now, prune, status, drill-record, wal-archive, verify-file, decrypt, decrypt-pipe, restore-base, wal-unpack, key-id`);
  }
}

main().then(
  (code) => process.exit(typeof code === 'number' ? code : 0),
  (e) => {
    const usage = e instanceof UsageError;
    if (['daemon', 'dump-now', 'dump-only'].includes(process.argv[2])) log('error', e.message);
    process.stderr.write(`pos-backup: ${e instanceof OptbkError ? `[${e.code}] ` : ''}${e.message}\n`);
    process.exit(usage ? 2 : 1);
  },
);
