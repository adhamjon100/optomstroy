// Распаковка tar из потока (ustar, GNU «L» и pax «x» для длинных имён) — для базовой копии pg_basebackup -F tar.
// Без сторонних программ: tar.exe Windows не нужен. Поддерживаются обычные файлы и каталоги; символические ссылки
// (pg_tblspc при дополнительных табличных пространствах) — отказ: в комплекте их нет (одно табличное пространство).

import fs from 'node:fs';
import path from 'node:path';

const BLOCK = 512;

function cstr(buf, off, len) {
  const s = buf.subarray(off, off + len);
  const z = s.indexOf(0);
  return (z >= 0 ? s.subarray(0, z) : s).toString('utf8');
}

function octal(buf, off, len) {
  if (buf[off] & 0x80) {
    // base-256 (GNU) для файлов больше 8 ГБ
    let v = 0n;
    for (let i = off + 1; i < off + len; i++) v = (v << 8n) | BigInt(buf[i]);
    return Number(v);
  }
  const s = cstr(buf, off, len).trim();
  return s ? parseInt(s, 8) : 0;
}

function checksumOk(h) {
  const stored = octal(h, 148, 8);
  let sum = 0;
  for (let i = 0; i < BLOCK; i++) sum += i >= 148 && i < 156 ? 32 : h[i];
  return sum === stored;
}

function parsePax(data) {
  // Записи вида "<длина> <ключ>=<значение>" с переводом строки в конце; длина — в байтах всей записи.
  const out = {};
  let off = 0;
  while (off < data.length) {
    const sp = data.indexOf(0x20, off);
    if (sp < 0) break;
    const len = parseInt(data.subarray(off, sp).toString('ascii'), 10);
    if (!len || off + len > data.length) break;
    const kv = data.subarray(sp + 1, off + len - 1).toString('utf8');
    const eq = kv.indexOf('=');
    if (eq > 0) out[kv.slice(0, eq)] = kv.slice(eq + 1);
    off += len;
  }
  return out;
}

function safeTarget(root, name) {
  const clean = name.replace(/\\/g, '/');
  if (clean.startsWith('/') || /^[A-Za-z]:/.test(clean) || clean.split('/').includes('..')) {
    throw new Error(`tar: недопустимый путь ${name}`);
  }
  const t = path.resolve(root, clean);
  if (t !== path.resolve(root) && !t.startsWith(path.resolve(root) + path.sep)) throw new Error(`tar: путь вне каталога ${name}`);
  return t;
}

// extractTar(source, root) — source: асинхронно итерируемый поток байтов. Возвращает {files, dirs, bytes}.
export async function extractTar(source, root) {
  fs.mkdirSync(root, { recursive: true });
  const it = source[Symbol.asyncIterator]();
  let buf = Buffer.alloc(0);
  let ended = false;
  async function need(n) {
    while (buf.length < n && !ended) {
      const r = await it.next();
      if (r.done) ended = true;
      else buf = buf.length ? Buffer.concat([buf, r.value]) : Buffer.from(r.value);
    }
    return buf.length >= n;
  }
  function take(n) {
    const out = buf.subarray(0, n);
    buf = buf.subarray(n);
    return out;
  }
  const stats = { files: 0, dirs: 0, bytes: 0 };
  let longName = null;
  let paxName = null;
  for (;;) {
    if (!(await need(BLOCK))) throw new Error('tar: поток оборвался (нет конца архива)');
    const h = take(BLOCK);
    if (h.every((b) => b === 0)) break; // конец архива (второй нулевой блок не обязателен для чтения)
    if (!checksumOk(h)) throw new Error('tar: неверная контрольная сумма заголовка');
    let name = cstr(h, 0, 100);
    const prefix = cstr(h, 345, 155);
    if (prefix && h.subarray(257, 262).toString() === 'ustar') name = `${prefix}/${name}`;
    const size = octal(h, 124, 12);
    const type = String.fromCharCode(h[156] || 48);
    const padded = Math.ceil(size / BLOCK) * BLOCK;
    if (type === 'L' || type === 'x' || type === 'g') {
      if (!(await need(padded))) throw new Error('tar: поток оборвался');
      const data = take(padded).subarray(0, size);
      if (type === 'L') longName = cstr(data, 0, data.length);
      else if (type === 'x') paxName = parsePax(data).path ?? null;
      continue;
    }
    if (longName) name = longName;
    if (paxName) name = paxName;
    longName = null;
    paxName = null;
    const target = safeTarget(root, name);
    if (type === '5') {
      fs.mkdirSync(target, { recursive: true });
      stats.dirs++;
      continue;
    }
    if (type !== '0' && type !== '7') {
      throw new Error(`tar: тип записи «${type}» (${name}) не поддерживается — символические ссылки и табличные пространства вне PGDATA в комплекте не используются`);
    }
    fs.mkdirSync(path.dirname(target), { recursive: true });
    const fd = fs.openSync(target, 'wx');
    try {
      let left = size;
      while (left > 0) {
        if (!(await need(1))) throw new Error(`tar: поток оборвался внутри ${name}`);
        const n = Math.min(left, buf.length);
        fs.writeSync(fd, take(n));
        left -= n;
      }
    } finally {
      fs.closeSync(fd);
    }
    const pad = padded - size;
    if (pad) {
      if (!(await need(pad))) throw new Error('tar: поток оборвался');
      take(pad);
    }
    stats.files++;
    stats.bytes += size;
  }
  // Дочитываем остаток потока (второй нулевой блок, выравнивание), чтобы источник завершился штатно и проверил
  // последний кусок OPTBK1.
  for (;;) {
    const r = await it.next();
    if (r.done) break;
  }
  return stats;
}
