// Чтение zip на node:zlib (без zip64): список записей, имена, бит UTF-8, распаковка с проверкой CRC.
import fs from 'node:fs';
import zlib from 'node:zlib';

export function readZip(fileOrBuf) {
  const buf = Buffer.isBuffer(fileOrBuf) ? fileOrBuf : fs.readFileSync(fileOrBuf);
  let eocd = -1;
  for (let i = buf.length - 22; i >= Math.max(0, buf.length - 22 - 65535); i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error('не zip: нет записи конца каталога');
  const count = buf.readUInt16LE(eocd + 10);
  let p = buf.readUInt32LE(eocd + 16);
  const entries = [];
  for (let i = 0; i < count; i++) {
    if (buf.readUInt32LE(p) !== 0x02014b50) throw new Error('повреждён центральный каталог');
    const flags = buf.readUInt16LE(p + 8);
    const method = buf.readUInt16LE(p + 10);
    const crc = buf.readUInt32LE(p + 16);
    const csize = buf.readUInt32LE(p + 20);
    const usize = buf.readUInt32LE(p + 24);
    const nlen = buf.readUInt16LE(p + 28);
    const xlen = buf.readUInt16LE(p + 30);
    const clen = buf.readUInt16LE(p + 32);
    const local = buf.readUInt32LE(p + 42);
    const nameRaw = buf.subarray(p + 46, p + 46 + nlen);
    const name = (flags & 0x0800) ? nameRaw.toString('utf8') : nameRaw.toString('latin1');
    const extra = buf.subarray(p + 46 + nlen, p + 46 + nlen + xlen);
    entries.push({
      name, flags, utf8: !!(flags & 0x0800), method, crc, csize, usize, extraIds: extraIds(extra),
      data: () => {
        const lnlen = buf.readUInt16LE(local + 26);
        const lxlen = buf.readUInt16LE(local + 28);
        const start = local + 30 + lnlen + lxlen;
        const comp = buf.subarray(start, start + csize);
        const out = method === 8 ? zlib.inflateRawSync(comp) : method === 0 ? Buffer.from(comp) : null;
        if (!out) throw new Error(`метод сжатия ${method} не поддерживается`);
        if (zlib.crc32(out) >>> 0 !== crc) throw new Error(`CRC не совпадает: ${name}`);
        return out;
      },
    });
    p += 46 + nlen + xlen + clen;
  }
  return entries;
}

function extraIds(x) {
  const ids = [];
  let i = 0;
  while (i + 4 <= x.length) { ids.push(x.readUInt16LE(i)); i += 4 + x.readUInt16LE(i + 2); }
  return ids;
}
