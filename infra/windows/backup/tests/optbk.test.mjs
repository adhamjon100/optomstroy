// Модульные проверки формата OPTBK1 и распаковки tar (node --test). Ключи создаются заново в памяти и во временной
// папке .tmp/wn-backup/unit; в репозитории ключей нет.
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

import { decryptStream, encryptStream, generateKeyPair, inspectStream, loadPrivateKey, publicKeyId } from '../lib/optbk.mjs';
import { extractTar } from '../lib/tar.mjs';
import { walArchive } from '../lib/jobs.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const TOOL = path.join(here, '..', 'pos-backup.mjs');
const TMP = process.env.WN_BACKUP_TMP || path.resolve(here, '..', '..', '..', '..', '.tmp', 'wn-backup', 'unit');

let A;
let B;
before(() => {
  fs.rmSync(TMP, { recursive: true, force: true });
  fs.mkdirSync(TMP, { recursive: true });
  A = generateKeyPair(null);
  B = generateKeyPair(null);
});

async function enc(pub, data, chunkSize = 1024) {
  const parts = [];
  await pipeline(Readable.from([data]), encryptStream(crypto.createPublicKey(pub), { chunkSize }), async (src) => {
    for await (const b of src) parts.push(b);
  });
  return Buffer.concat(parts);
}

async function dec(priv, blob) {
  const parts = [];
  await pipeline(Readable.from([blob]), decryptStream(crypto.createPrivateKey(priv)), async (src) => {
    for await (const b of src) parts.push(b);
  });
  return Buffer.concat(parts);
}

const HEADER = 46 + 512;

test('round trip: пустой, меньше куска, ровно кусок, кратно куску, несколько кусков', async () => {
  for (const n of [0, 1, 1023, 1024, 2048, 5000, 300000]) {
    const data = crypto.randomBytes(n);
    const blob = await enc(A.publicKey, data);
    assert.deepEqual(await dec(A.privateKey, blob), data, `n=${n}`);
    const info = await inspectStream(Readable.from([blob]));
    assert.equal(info.plainBytes, n);
    assert.equal(info.keyId, publicKeyId(A.publicKey).toString('hex'));
    assert.equal(info.chunks, Math.max(1, Math.ceil(n / 1024)), `chunks n=${n}`);
  }
});

test('поток мелкими порциями расшифровывается так же', async () => {
  const data = crypto.randomBytes(10000);
  const blob = await enc(A.publicKey, data);
  const pieces = [];
  for (let i = 0; i < blob.length; i += 7) pieces.push(blob.subarray(i, i + 7));
  const parts = [];
  await pipeline(Readable.from(pieces), decryptStream(crypto.createPrivateKey(A.privateKey)), async (src) => {
    for await (const b of src) parts.push(b);
  });
  assert.deepEqual(Buffer.concat(parts), data);
});

test('одинаковые данные дают разные файлы (случайный ключ на файл)', async () => {
  const data = Buffer.from('одинаковое содержимое');
  assert.notDeepEqual(await enc(A.publicKey, data), await enc(A.publicKey, data));
});

test('подмена байта шифртекста → отказ auth', async () => {
  const blob = await enc(A.publicKey, crypto.randomBytes(3000));
  for (const off of [HEADER + 5 + 10, blob.length - 3]) {
    const t = Buffer.from(blob);
    t[off] ^= 1;
    await assert.rejects(dec(A.privateKey, t), (e) => e.code === 'auth', `off=${off}`);
  }
});

test('подмена заголовка (размер куска, keyId) → отказ', async () => {
  const blob = await enc(A.publicKey, crypto.randomBytes(3000));
  const t1 = Buffer.from(blob);
  t1[20] ^= 1; // keyId
  await assert.rejects(dec(A.privateKey, t1), (e) => e.code === 'wrong-key');
  const t2 = Buffer.from(blob);
  t2[7] = 1; // флаги входят в SHA-256 заголовка → AAD
  await assert.rejects(dec(A.privateKey, t2), (e) => e.code === 'auth');
  const t3 = Buffer.from(blob);
  t3[0] = 0x58;
  await assert.rejects(dec(A.privateKey, t3), (e) => e.code === 'not-optbk');
});

test('обрезка: по границе куска, внутри куска, в заголовке → отказ', async () => {
  const blob = await enc(A.publicKey, crypto.randomBytes(3000));
  const one = 5 + 1024 + 16;
  for (const cut of [HEADER + one, HEADER + one * 2, HEADER + 100, 30, blob.length - 1]) {
    await assert.rejects(dec(A.privateKey, blob.subarray(0, cut)), (e) => e.code === 'truncated', `cut=${cut}`);
    await assert.rejects(inspectStream(Readable.from([blob.subarray(0, cut)])), (e) => e.code === 'truncated' || e.code === 'not-optbk', `inspect cut=${cut}`);
  }
});

test('подмена флага «последний кусок» у среднего куска → отказ', async () => {
  const blob = await enc(A.publicKey, crypto.randomBytes(3000));
  const t = Buffer.from(blob);
  t[HEADER] = 1; // первый кусок объявлен последним
  await assert.rejects(dec(A.privateKey, t), (e) => e.code === 'auth');
});

test('перестановка кусков → отказ', async () => {
  const blob = await enc(A.publicKey, crypto.randomBytes(3072 + 10));
  const one = 5 + 1024 + 16;
  const h = blob.subarray(0, HEADER);
  const c0 = blob.subarray(HEADER, HEADER + one);
  const c1 = blob.subarray(HEADER + one, HEADER + 2 * one);
  const tail = blob.subarray(HEADER + 2 * one);
  await assert.rejects(dec(A.privateKey, Buffer.concat([h, c1, c0, tail])), (e) => e.code === 'auth');
});

test('лишние байты после последнего куска → отказ', async () => {
  const blob = await enc(A.publicKey, crypto.randomBytes(100));
  await assert.rejects(dec(A.privateKey, Buffer.concat([blob, Buffer.from([0])])), (e) => e.code === 'trailing');
});

test('чужой ключ → отказ wrong-key', async () => {
  const blob = await enc(A.publicKey, crypto.randomBytes(100));
  await assert.rejects(dec(B.privateKey, blob), (e) => e.code === 'wrong-key');
});

test('закрытый ключ с парольной фразой: верная фраза — да, неверная — отказ', () => {
  const kp = generateKeyPair('правильная-фраза-123');
  const f = path.join(TMP, 'enc.pem');
  fs.writeFileSync(f, kp.privateKey);
  assert.ok(loadPrivateKey(f, 'правильная-фраза-123'));
  assert.throws(() => loadPrivateKey(f, 'неверная-фраза-000'), (e) => e.code === 'bad-key');
  assert.match(kp.privateKey, /ENCRYPTED PRIVATE KEY/);
});

test('CLI: keygen, decrypt, verify-file (с ключом и без), подмена файла', async () => {
  const kd = path.join(TMP, 'keys');
  const env = { ...process.env, POS_BACKUP_KEY_PASSPHRASE: 'unit-test-passphrase-1' }; // check-secrets: allow — фраза теста, не секрет
  let r = spawnSync(process.execPath, [TOOL, 'keygen', '--out', kd], { env, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  r = spawnSync(process.execPath, [TOOL, 'keygen', '--out', kd], { env, encoding: 'utf8' });
  assert.equal(r.status, 2, 'повторный keygen не перезаписывает ключи');
  const pub = fs.readFileSync(path.join(kd, 'backup-public.pem'));
  const data = crypto.randomBytes(200000);
  const file = path.join(TMP, 'x.bin.optbk');
  fs.writeFileSync(file, await enc(pub, data, 65536));
  const sha = crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  fs.writeFileSync(`${file}.sha256`, `${sha} *x.bin.optbk\n`);
  r = spawnSync(process.execPath, [TOOL, 'verify-file', file], { env, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stdout + r.stderr);
  r = spawnSync(process.execPath, [TOOL, 'verify-file', file, '--key', path.join(kd, 'backup-private.pem')], { env, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.equal(JSON.parse(r.stdout).decrypted.plainBytes, data.length);
  const out = path.join(TMP, 'x.bin');
  r = spawnSync(process.execPath, [TOOL, 'decrypt', '--key', path.join(kd, 'backup-private.pem'), file, out], { env, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(fs.readFileSync(out), data);
  // без парольной фразы и без консоли — отказ (код 2), файл не создаётся
  const env2 = { ...process.env };
  delete env2.POS_BACKUP_KEY_PASSPHRASE;
  r = spawnSync(process.execPath, [TOOL, 'decrypt', '--key', path.join(kd, 'backup-private.pem'), file, `${out}2`], { env: env2, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] });
  assert.equal(r.status, 2, r.stderr);
  // подмена одного байта: без ключа ловит SHA-256, с ключом — проверка подлинности
  const t = fs.readFileSync(file);
  t[t.length - 100] ^= 1;
  fs.writeFileSync(file, t);
  r = spawnSync(process.execPath, [TOOL, 'verify-file', file], { env, encoding: 'utf8' });
  assert.equal(r.status, 1);
  r = spawnSync(process.execPath, [TOOL, 'decrypt', '--key', path.join(kd, 'backup-private.pem'), file, `${out}3`], { env, encoding: 'utf8' });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /\[auth\]/);
  assert.ok(!fs.existsSync(`${out}3`) && !fs.existsSync(`${out}3.partial`), 'частичный файл удалён');
});

test('wal-archive: запись, повтор с тем же содержимым — 0, другое содержимое — 1, неверное имя — 2', async () => {
  const spool = path.join(TMP, 'spool');
  fs.mkdirSync(spool, { recursive: true });
  const src = path.join(TMP, 'seg');
  const seg = '000000010000000000000003';
  fs.writeFileSync(src, crypto.randomBytes(65536));
  assert.equal(await walArchive(spool, src, seg), 0);
  assert.deepEqual(fs.readFileSync(path.join(spool, seg)), fs.readFileSync(src));
  assert.equal(await walArchive(spool, src, seg), 0);
  fs.writeFileSync(src, crypto.randomBytes(65536));
  assert.equal(await walArchive(spool, src, seg), 1);
  assert.equal(await walArchive(spool, src, '../x'), 2);
  assert.equal(await walArchive(spool, path.join(TMP, 'нет-файла'), seg.replace('3', '4')), 1);
  assert.equal(fs.readdirSync(spool).filter((n) => n.startsWith('.')).length, 0, 'временных файлов не осталось');
});

test('tar: распаковка ustar и длинного имени (GNU L), отказ на ..', async () => {
  const mk = (name, body, type = '0') => {
    const h = Buffer.alloc(512);
    h.write(name.slice(0, 100), 0);
    h.write('0000644\0', 100);
    h.write('0000000\0', 108);
    h.write('0000000\0', 116);
    h.write(`${body.length.toString(8).padStart(11, '0')}\0`, 124);
    h.write('00000000000\0', 136);
    h.write(type, 156);
    h.write('ustar\u000000', 257);
    h.fill(32, 148, 156);
    let sum = 0;
    for (const b of h) sum += b;
    h.write(`${sum.toString(8).padStart(6, '0')}\0 `, 148);
    const pad = Buffer.alloc((512 - (body.length % 512)) % 512);
    return Buffer.concat([h, body, pad]);
  };
  const long = `${'d'.repeat(120)}/f.txt`;
  const tar = Buffer.concat([
    mk('base/', Buffer.alloc(0), '5'),
    mk('base/PG_VERSION', Buffer.from('17\n')),
    mk('././@LongLink', Buffer.from(`${long}\0`), 'L'),
    mk('ignored', Buffer.from('длинное имя')),
    Buffer.alloc(1024),
  ]);
  const dir = path.join(TMP, 'tar1');
  const st = await extractTar(Readable.from([zlib.gunzipSync(zlib.gzipSync(tar))]), dir);
  assert.equal(st.files, 2);
  assert.equal(fs.readFileSync(path.join(dir, 'base', 'PG_VERSION'), 'utf8'), '17\n');
  assert.equal(fs.readFileSync(path.join(dir, long), 'utf8'), 'длинное имя');
  await assert.rejects(extractTar(Readable.from([Buffer.concat([mk('../evil', Buffer.from('x')), Buffer.alloc(1024)])]), path.join(TMP, 'tar2')));
});

// ---------- конвейер «программа → [gzip] → OPTBK1 → файл» и очистка по срокам ----------
import { encryptChildToFile, prune } from '../lib/jobs.mjs';

function cfgFor(root, pubFile) {
  return { backupRoot: root, publicKeyFile: pubFile, chunkSize: 4096, gzipLevel: 3, keepDays: 30, monthlyExtraDays: 93, globalsKeepDays: 90, walSpoolDir: path.join(root, 'spool') };
}

test('encryptChildToFile: код 0 — файл опубликован; код ≠ 0, пустой вывод, сбой запуска — файла нет', async () => {
  const root = path.join(TMP, 'pipe');
  fs.mkdirSync(root, { recursive: true });
  const pubFile = path.join(root, 'pub.pem');
  fs.writeFileSync(pubFile, A.publicKey);
  const c = cfgFor(root, pubFile);
  const ok = path.join(root, 'ok.optbk');
  const r = await encryptChildToFile(c, { exe: process.execPath, args: ['-e', "process.stdout.write('x'.repeat(100000))"], out: ok, gzip: true, label: 'node' });
  assert.equal(r.plainBytes, 100000);
  const plain = zlib.gunzipSync(await dec(A.privateKey, fs.readFileSync(ok)));
  assert.equal(plain.toString(), 'x'.repeat(100000));
  const cases = [
    ['exit3', ['-e', "process.stdout.write('частичный вывод'); process.exit(3)"], /код выхода 3/],
    ['empty', ['-e', '0'], /пустой вывод/],
  ];
  for (const [name, args, re] of cases) {
    const out = path.join(root, `${name}.optbk`);
    await assert.rejects(encryptChildToFile(c, { exe: process.execPath, args, out, label: name }), re);
    assert.ok(!fs.existsSync(out) && !fs.existsSync(`${out}.partial`), `${name}: файлов нет`);
  }
  const out = path.join(root, 'nostart.optbk');
  await assert.rejects(encryptChildToFile(c, { exe: path.join(root, 'нет.exe'), args: [], out, label: 'нет' }), /не запущен|ошибка потока/);
  assert.ok(!fs.existsSync(out) && !fs.existsSync(`${out}.partial`));
  // остановка службы во время выгрузки
  const ac = new AbortController();
  const slow = path.join(root, 'slow.optbk');
  const p = encryptChildToFile(c, { exe: process.execPath, args: ['-e', "setInterval(() => process.stdout.write('y'.repeat(1000)), 10)"], out: slow, signal: ac.signal, label: 'slow' });
  setTimeout(() => ac.abort(), 300);
  await assert.rejects(p, /прервано|ошибка потока/);
  assert.ok(!fs.existsSync(slow) && !fs.existsSync(`${slow}.partial`));
});

test('prune: дампы 30 сут, месячные 30+93, globals 90, база PITR — новейшая остаётся, WAL до самой старой базы', () => {
  const root = path.join(TMP, 'prune');
  fs.rmSync(root, { recursive: true, force: true });
  const now = new Date(Date.UTC(2026, 10, 21, 12, 0, 0));
  const ts = (days) => {
    const d = new Date(now.getTime() - days * 86400000);
    return d.toISOString().replace(/[-:]/g, '').replace('T', '-').slice(0, 15);
  };
  const touch = (f, body = 'x') => {
    fs.mkdirSync(path.dirname(f), { recursive: true });
    fs.writeFileSync(f, body);
  };
  const dumps = path.join(root, 'dumps');
  for (const d of [1, 2, 3, 29, 31, 60]) for (const s of ['', '.sha256', '.json']) touch(path.join(dumps, `${ts(d)}.dump.optbk${s}`));
  for (const d of [100, 130]) touch(path.join(dumps, 'monthly', `${ts(d)}.dump.optbk`));
  for (const d of [80, 95]) touch(path.join(dumps, `globals-${ts(d)}.sql.optbk`));
  const sys = path.join(root, 'pitr', '123');
  const base = (d, startWal) => {
    const n = `base-${ts(d)}.tar.gz.optbk`;
    touch(path.join(sys, 'base', n));
    touch(path.join(sys, 'base', `${n}.json`), JSON.stringify({ startWal }));
    return n;
  };
  const b40 = base(40, '000000010000000000000010');
  const b20 = base(20, '000000010000000000000020');
  for (const seg of ['00000001000000000000000F', '000000010000000000000010', '00000001000000000000001F', '000000010000000000000020', '000000020000000000000021', '00000002.history']) {
    touch(path.join(sys, 'wal', `${seg}.gz.optbk`));
  }
  // второй кластер: единственная база старше срока — не удаляется
  const sys2 = path.join(root, 'pitr', '456');
  touch(path.join(sys2, 'base', `base-${ts(90)}.tar.gz.optbk`));
  touch(path.join(sys2, 'base', `base-${ts(90)}.tar.gz.optbk.json`), JSON.stringify({ startWal: '000000010000000000000001' }));
  prune(cfgFor(root, ''), { now });
  const has = (...p) => fs.existsSync(path.join(...p));
  assert.ok(has(dumps, `${ts(1)}.dump.optbk`) && has(dumps, `${ts(29)}.dump.optbk`));
  assert.ok(!has(dumps, `${ts(31)}.dump.optbk`) && !has(dumps, `${ts(31)}.dump.optbk.json`) && !has(dumps, `${ts(60)}.dump.optbk.sha256`));
  assert.ok(has(dumps, 'monthly', `${ts(100)}.dump.optbk`) && !has(dumps, 'monthly', `${ts(130)}.dump.optbk`));
  assert.ok(has(dumps, `globals-${ts(80)}.sql.optbk`) && !has(dumps, `globals-${ts(95)}.sql.optbk`));
  assert.ok(!has(sys, 'base', b40) && has(sys, 'base', b20));
  assert.ok(!has(sys, 'wal', '00000001000000000000001F.gz.optbk'), 'WAL до начала самой старой оставшейся базы удалён');
  assert.ok(has(sys, 'wal', '000000010000000000000020.gz.optbk') && has(sys, 'wal', '000000020000000000000021.gz.optbk'));
  assert.ok(has(sys, 'wal', '00000002.history.gz.optbk'), 'файлы .history не удаляются');
  assert.ok(has(sys2, 'base', `base-${ts(90)}.tar.gz.optbk`), 'единственная база кластера не удаляется');
});

test('decrypt-pipe: данные доходят до программы; код программы ≠ 0 → 1; подменённый файл → 1', async () => {
  const root = path.join(TMP, 'dpipe');
  fs.mkdirSync(root, { recursive: true });
  const priv = path.join(root, 'priv.pem');
  fs.writeFileSync(priv, A.privateKey);
  const data = crypto.randomBytes(500000);
  const sha = crypto.createHash('sha256').update(data).digest('hex');
  const file = path.join(root, 'd.optbk');
  fs.writeFileSync(file, await enc(A.publicKey, data, 65536));
  const sink = `const h=require('crypto').createHash('sha256');process.stdin.on('data',d=>h.update(d));process.stdin.on('end',()=>{process.exit(h.digest('hex')===process.argv[1]?0:5)})`;
  let r = spawnSync(process.execPath, [TOOL, 'decrypt-pipe', '--key', priv, file, '--', process.execPath, '-e', sink, sha], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  r = spawnSync(process.execPath, [TOOL, 'decrypt-pipe', '--key', priv, file, '--', process.execPath, '-e', sink, 'другая-сумма'], { encoding: 'utf8' });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /кодом 5/);
  const t = fs.readFileSync(file);
  t[t.length - 50] ^= 1;
  fs.writeFileSync(file, t);
  r = spawnSync(process.execPath, [TOOL, 'decrypt-pipe', '--key', priv, file, '--', process.execPath, '-e', sink, sha], { encoding: 'utf8' });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /проверка подлинности|расшифровка прервана/);
});
