// Запись zip на node:zlib: имена UTF-8 (бит 11 + поле 0x7075 Info-ZIP Unicode Path), фиксированное время,
// сортировка — сборка повторяема. Без zip64 (архив меньше 4 ГБ).
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

// 20.11.2026 00:00:00 в формате DOS
const DOS_DATE = ((2026 - 1980) << 9) | (11 << 5) | 20;
const DOS_TIME = 0;

function u16(n) { const b = Buffer.alloc(2); b.writeUInt16LE(n); return b; }
function u32(n) { const b = Buffer.alloc(4); b.writeUInt32LE(n >>> 0); return b; }

/** Список файлов папки (рекурсивно), пути с «/». */
export function listFiles(dir, prefix = '') {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const rel = prefix ? `${prefix}/${e.name}` : e.name;
    if (e.isDirectory()) { out.push({ name: rel + '/', dir: true }); out.push(...listFiles(path.join(dir, e.name), rel)); }
    else if (e.isFile()) out.push({ name: rel, file: path.join(dir, e.name) });
  }
  return out;
}

/**
 * @param {string} outFile
 * @param {{name:string, file?:string, data?:Buffer, dir?:boolean}[]} entries
 */
export function writeZip(outFile, entries) {
  const sorted = [...entries].sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  const fd = fs.openSync(outFile, 'w');
  let offset = 0;
  const central = [];
  const write = (buf) => { fs.writeSync(fd, buf); offset += buf.length; };
  try {
    for (const e of sorted) {
      const nameBuf = Buffer.from(e.name, 'utf8');
      const nonAscii = /[^\x20-\x7e]/.test(e.name);
      const flags = nonAscii ? 0x0800 : 0;
      let data = e.dir ? Buffer.alloc(0) : (e.data || fs.readFileSync(e.file));
      const crc = e.dir ? 0 : zlib.crc32(data);
      let method = 0;
      let comp = data;
      if (!e.dir && data.length > 0) {
        const d = zlib.deflateRawSync(data, { level: 9 });
        if (d.length < data.length) { comp = d; method = 8; }
      }
      const extra = nonAscii
        ? Buffer.concat([u16(0x7075), u16(1 + 4 + nameBuf.length), Buffer.from([1]), u32(zlib.crc32(nameBuf)), nameBuf])
        : Buffer.alloc(0);
      const localOffset = offset;
      write(Buffer.concat([
        u32(0x04034b50), u16(20), u16(flags), u16(method), u16(DOS_TIME), u16(DOS_DATE),
        u32(crc), u32(comp.length), u32(data.length), u16(nameBuf.length), u16(extra.length), nameBuf, extra,
      ]));
      write(comp);
      central.push(Buffer.concat([
        u32(0x02014b50), u16(20), u16(20), u16(flags), u16(method), u16(DOS_TIME), u16(DOS_DATE),
        u32(crc), u32(comp.length), u32(data.length), u16(nameBuf.length), u16(extra.length), u16(0),
        u16(0), u16(0), u32(e.dir ? 0x10 : 0x20), u32(localOffset), nameBuf, extra,
      ]));
      data = null;
      comp = null;
    }
    const cdStart = offset;
    for (const c of central) write(c);
    const cdSize = offset - cdStart;
    write(Buffer.concat([u32(0x06054b50), u16(0), u16(0), u16(central.length), u16(central.length), u32(cdSize), u32(cdStart), u16(0)]));
  } finally {
    fs.closeSync(fd);
  }
  return { entries: sorted.length, size: offset };
}
