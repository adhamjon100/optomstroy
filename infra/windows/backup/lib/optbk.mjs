// Формат зашифрованных копий OPTBK1 (infra/windows/backup/README.md, раздел «Формат OPTBK1»).
// Гибридное шифрование без сторонних программ: случайный ключ AES-256-GCM на каждый файл, ключ зашифрован
// открытым ключом RSA-4096 (RSA-OAEP, SHA-256). Данные — потоком, кусками по chunkSize байт, у каждого куска свой
// тег GCM. Закрытый ключ на сервере не хранится: расшифровка — только на компьютере держателя ключа.
//
// Заголовок (все числа — big-endian):
//   0   6  магия "OPTBK1"
//   6   1  версия формата = 1
//   7   1  флаги = 0 (зарезервировано)
//   8   4  chunkSize — размер открытого текста в каждом не последнем куске
//   12  32 keyId — SHA-256 открытого ключа (SubjectPublicKeyInfo, DER): быстрый отказ при чужом ключе
//   44  2  wrappedLen — длина зашифрованного ключа (512 для RSA-4096)
//   46  wrappedLen  RSA-OAEP-SHA256(32 байта ключа AES)
// Куски, подряд до последнего:
//   1  флаг: 0 — не последний, 1 — последний
//   4  длина шифртекста N (у не последнего куска N == chunkSize; у последнего 0..chunkSize)
//   N  шифртекст
//   16 тег GCM
// Одноразовое число куска i: 4 нулевых байта || i (uint64). Ключ у каждого файла свой, поэтому счётчика достаточно.
// AAD куска: SHA-256(заголовок) || i (uint64) || флаг. Изменение заголовка, перестановка, подмена флага или удаление
// кусков ломают проверку тега; файл без последнего куска — «обрезан»; байты после последнего куска — ошибка.

import crypto from 'node:crypto';
import fs from 'node:fs';

export const MAGIC = Buffer.from('OPTBK1', 'ascii');
export const VERSION = 1;
export const DEFAULT_CHUNK = 1024 * 1024;
export const MAX_CHUNK = 16 * 1024 * 1024;
const TAG = 16;
const FIXED_HEADER = 46;

export class OptbkError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

export function publicKeyId(publicKey) {
  const key = typeof publicKey === 'string' || Buffer.isBuffer(publicKey) ? crypto.createPublicKey(publicKey) : publicKey;
  const der = key.export({ type: 'spki', format: 'der' });
  return crypto.createHash('sha256').update(der).digest();
}

export function loadPublicKey(file) {
  const key = crypto.createPublicKey(fs.readFileSync(file));
  if (key.asymmetricKeyType !== 'rsa' || key.asymmetricKeyDetails.modulusLength < 4096) {
    throw new OptbkError('bad-key', `открытый ключ ${file}: нужен RSA не короче 4096 бит`);
  }
  return key;
}

export function loadPrivateKey(file, passphrase) {
  const pem = fs.readFileSync(file);
  try {
    return crypto.createPrivateKey(passphrase ? { key: pem, passphrase } : pem);
  } catch (e) {
    throw new OptbkError('bad-key', `закрытый ключ ${file} не прочитан (неверная парольная фраза или файл): ${e.code ?? e.message}`);
  }
}

export function generateKeyPair(passphrase) {
  const opts = {
    modulusLength: 4096,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: passphrase
      ? { type: 'pkcs8', format: 'pem', cipher: 'aes-256-cbc', passphrase }
      : { type: 'pkcs8', format: 'pem' },
  };
  return crypto.generateKeyPairSync('rsa', opts);
}

function nonce(counter) {
  const n = Buffer.alloc(12);
  n.writeBigUInt64BE(BigInt(counter), 4);
  return n;
}

function aad(headerHash, counter, final) {
  const a = Buffer.alloc(32 + 8 + 1);
  headerHash.copy(a, 0);
  a.writeBigUInt64BE(BigInt(counter), 32);
  a[40] = final ? 1 : 0;
  return a;
}

function buildHeader(publicKey, chunkSize, dataKey) {
  const wrapped = crypto.publicEncrypt(
    { key: publicKey, padding: crypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' },
    dataKey,
  );
  const h = Buffer.alloc(FIXED_HEADER + wrapped.length);
  MAGIC.copy(h, 0);
  h[6] = VERSION;
  h[7] = 0;
  h.writeUInt32BE(chunkSize, 8);
  publicKeyId(publicKey).copy(h, 12);
  h.writeUInt16BE(wrapped.length, 44);
  wrapped.copy(h, FIXED_HEADER);
  return h;
}

function sealChunk(dataKey, headerHash, counter, final, plain) {
  const c = crypto.createCipheriv('aes-256-gcm', dataKey, nonce(counter));
  c.setAAD(aad(headerHash, counter, final));
  const ct = Buffer.concat([c.update(plain), c.final()]);
  const pre = Buffer.alloc(5);
  pre[0] = final ? 1 : 0;
  pre.writeUInt32BE(ct.length, 1);
  return Buffer.concat([pre, ct, c.getAuthTag()]);
}

// encryptStream(publicKey, {chunkSize}) — асинхронный генератор-преобразователь для stream.pipeline:
// на входе открытые данные, на выходе файл OPTBK1. Последний кусок пишется только при нормальном конце входа:
// если источник оборвался с ошибкой, pipeline прерывается и файл без последнего куска останется «обрезанным».
export function encryptStream(publicKey, { chunkSize = DEFAULT_CHUNK, stats } = {}) {
  if (!Number.isInteger(chunkSize) || chunkSize < 1024 || chunkSize > MAX_CHUNK) {
    throw new OptbkError('bad-chunk', `недопустимый размер куска ${chunkSize}`);
  }
  return async function* encrypt(source) {
    const dataKey = crypto.randomBytes(32);
    const header = buildHeader(publicKey, chunkSize, dataKey);
    const headerHash = crypto.createHash('sha256').update(header).digest();
    yield header;
    let counter = 0;
    let buf = Buffer.alloc(0);
    let plainBytes = 0;
    for await (const piece of source) {
      const b = Buffer.isBuffer(piece) ? piece : Buffer.from(piece);
      plainBytes += b.length;
      buf = buf.length ? Buffer.concat([buf, b]) : b;
      // Держим в буфере хотя бы один байт сверх куска: так последний кусок никогда не бывает «пустым не последним».
      while (buf.length > chunkSize) {
        yield sealChunk(dataKey, headerHash, counter++, false, buf.subarray(0, chunkSize));
        buf = buf.subarray(chunkSize);
      }
    }
    yield sealChunk(dataKey, headerHash, counter++, true, buf);
    if (stats) {
      stats.plainBytes = plainBytes;
      stats.chunks = counter;
    }
    dataKey.fill(0);
  };
}

// Читатель потока байтов с точным чтением n байт (для разбора заголовка и кусков).
class ByteReader {
  constructor(source) {
    this.it = source[Symbol.asyncIterator]();
    this.buf = Buffer.alloc(0);
    this.done = false;
  }
  async fill(n) {
    while (this.buf.length < n && !this.done) {
      const r = await this.it.next();
      if (r.done) this.done = true;
      else this.buf = this.buf.length ? Buffer.concat([this.buf, r.value]) : Buffer.from(r.value);
    }
  }
  async read(n) {
    await this.fill(n);
    if (this.buf.length < n) return null;
    const out = this.buf.subarray(0, n);
    this.buf = this.buf.subarray(n);
    return out;
  }
  async atEnd() {
    await this.fill(1);
    return this.buf.length === 0;
  }
}

async function readHeader(reader) {
  const fixed = await reader.read(FIXED_HEADER);
  if (!fixed && reader.buf.length >= 6 && reader.buf.subarray(0, 6).equals(MAGIC)) throw new OptbkError('truncated', 'файл обрезан в заголовке');
  if (!fixed || !fixed.subarray(0, 6).equals(MAGIC)) throw new OptbkError('not-optbk', 'файл не в формате OPTBK1 (нет магии)');
  if (fixed[6] !== VERSION) throw new OptbkError('bad-version', `неподдерживаемая версия формата ${fixed[6]}`);
  const chunkSize = fixed.readUInt32BE(8);
  if (chunkSize < 1024 || chunkSize > MAX_CHUNK) throw new OptbkError('bad-header', `недопустимый размер куска ${chunkSize}`);
  const keyId = Buffer.from(fixed.subarray(12, 44));
  const wrappedLen = fixed.readUInt16BE(44);
  if (wrappedLen < 128 || wrappedLen > 2048) throw new OptbkError('bad-header', `недопустимая длина ключа ${wrappedLen}`);
  const wrapped = await reader.read(wrappedLen);
  if (!wrapped) throw new OptbkError('truncated', 'файл обрезан в заголовке');
  const header = Buffer.concat([fixed, wrapped]);
  return { header, chunkSize, keyId, wrapped, headerHash: crypto.createHash('sha256').update(header).digest() };
}

// Обходит структуру кусков. onChunk(counter, final, ct, tag) — по желанию (расшифровка).
async function walkChunks(reader, chunkSize, onChunk) {
  let counter = 0;
  let cipherBytes = 0;
  for (;;) {
    const pre = await reader.read(5);
    if (!pre) throw new OptbkError('truncated', `файл обрезан: нет последнего куска (прочитано кусков: ${counter})`);
    const flag = pre[0];
    if (flag > 1) throw new OptbkError('bad-chunk', `кусок ${counter}: неверный флаг ${flag}`);
    const len = pre.readUInt32BE(1);
    if (len > chunkSize || (flag === 0 && len !== chunkSize)) {
      throw new OptbkError('bad-chunk', `кусок ${counter}: неверная длина ${len}`);
    }
    const body = await reader.read(len + TAG);
    if (!body) throw new OptbkError('truncated', `файл обрезан внутри куска ${counter}`);
    cipherBytes += len;
    if (onChunk) await onChunk(counter, flag === 1, body.subarray(0, len), body.subarray(len));
    counter++;
    if (flag === 1) break;
  }
  if (!(await reader.atEnd())) throw new OptbkError('trailing', 'после последнего куска есть лишние байты');
  return { chunks: counter, plainBytes: cipherBytes };
}

// decryptStream(privateKey) — генератор-преобразователь: файл OPTBK1 → открытые данные. Каждый кусок отдаётся
// сразу после проверки его тега (весь файл в памяти не держится); ошибка (подмена, обрезка, чужой ключ) прерывает
// поток исключением OptbkError. Потребитель обязан дождаться конца потока: только он подтверждает последний кусок.
export function decryptStream(privateKey, { stats } = {}) {
  return async function* decrypt(source) {
    const reader = new ByteReader(source);
    const h = await readHeader(reader);
    const myId = publicKeyId(crypto.createPublicKey(privateKey));
    if (!myId.equals(h.keyId)) {
      throw new OptbkError('wrong-key', `файл зашифрован другим ключом (keyId файла ${h.keyId.toString('hex').slice(0, 16)}…, ключа ${myId.toString('hex').slice(0, 16)}…)`);
    }
    let dataKey;
    try {
      dataKey = crypto.privateDecrypt(
        { key: privateKey, padding: crypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' },
        h.wrapped,
      );
    } catch {
      throw new OptbkError('wrong-key', 'ключ данных не расшифрован (чужой ключ или повреждён заголовок)');
    }
    if (dataKey.length !== 32) throw new OptbkError('bad-header', 'неверная длина ключа данных');
    let counter = 0;
    let plainBytes = 0;
    for (;;) {
      const pre = await reader.read(5);
      if (!pre) throw new OptbkError('truncated', `файл обрезан: нет последнего куска (прочитано кусков: ${counter})`);
      const flag = pre[0];
      if (flag > 1) throw new OptbkError('bad-chunk', `кусок ${counter}: неверный флаг ${flag}`);
      const len = pre.readUInt32BE(1);
      if (len > h.chunkSize || (flag === 0 && len !== h.chunkSize)) {
        throw new OptbkError('bad-chunk', `кусок ${counter}: неверная длина ${len}`);
      }
      const body = await reader.read(len + TAG);
      if (!body) throw new OptbkError('truncated', `файл обрезан внутри куска ${counter}`);
      const d = crypto.createDecipheriv('aes-256-gcm', dataKey, nonce(counter));
      d.setAAD(aad(h.headerHash, counter, flag === 1));
      d.setAuthTag(body.subarray(len));
      let plain;
      try {
        plain = Buffer.concat([d.update(body.subarray(0, len)), d.final()]);
      } catch {
        throw new OptbkError('auth', `кусок ${counter}: проверка подлинности не пройдена (файл изменён или повреждён)`);
      }
      counter++;
      plainBytes += plain.length;
      if (plain.length) yield plain;
      if (flag === 1) break;
    }
    if (!(await reader.atEnd())) throw new OptbkError('trailing', 'после последнего куска есть лишние байты');
    dataKey.fill(0);
    if (stats) {
      stats.chunks = counter;
      stats.plainBytes = plainBytes;
    }
  };
}

// inspectStream — проверка без ключа: заголовок, длины и флаги кусков, отсутствие обрезки и хвоста.
// Подлинность кусков без закрытого ключа не проверить (README, «verify-file»).
export async function inspectStream(source) {
  const reader = new ByteReader(source);
  const h = await readHeader(reader);
  const r = await walkChunks(reader, h.chunkSize, null);
  return {
    format: 'OPTBK1',
    version: VERSION,
    chunkSize: h.chunkSize,
    keyId: h.keyId.toString('hex'),
    wrappedKeyBytes: h.wrapped.length,
    chunks: r.chunks,
    plainBytes: r.plainBytes,
  };
}
