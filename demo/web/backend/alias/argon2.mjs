// Подмена @node-rs/argon2: Argon2id на чистом JS (@noble/hashes/argon2), та же PHC-строка `$argon2id$v=19$…`
// (совпадение с нативной реализацией проверено в b_argon2_bench.mjs). Async-вариант с asyncTick 10 мс: каждые 10 мс
// хэширование отдаёт цикл событий воркера — nextTick @noble подменён макрозадачей (alias/noble-yield.mjs; в
// @noble/hashes 1.8.0 это микрозадача, и проверка PIN ~0,4 с не пропускала ни сообщений, ни таймеров).
// Пока идёт хэширование, единица работы запроса держит слот (work-gate.mjs): другие запросы ждут, как и раньше.
import { argon2idAsync, argon2dAsync, argon2iAsync } from '@noble/hashes/argon2';

export const Algorithm = { Argon2d: 0, Argon2i: 1, Argon2id: 2 };
export const Version = { V0x10: 0, V0x13: 1 };
const NAMES = ['argon2d', 'argon2i', 'argon2id'];
const FNS = [argon2dAsync, argon2iAsync, argon2idAsync];

const b64 = (u8) => {
  let s = '';
  for (const c of u8) s += String.fromCharCode(c);
  return btoa(s).replace(/=+$/, '');
};
const unb64 = (s) => {
  const pad = s.length % 4 === 0 ? '' : '='.repeat(4 - (s.length % 4));
  const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/') + pad);
  const u = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
  return u;
};
const bytes = (v) => (typeof v === 'string' ? new TextEncoder().encode(v) : v instanceof Uint8Array ? v : new Uint8Array(v));

export async function hash(password, options = {}) {
  const algorithm = options.algorithm ?? Algorithm.Argon2id;
  const m = options.memoryCost ?? 19456;
  const t = options.timeCost ?? 2;
  const p = options.parallelism ?? 1;
  const dkLen = options.outputLen ?? 32;
  const salt = options.salt ? bytes(options.salt) : globalThis.crypto.getRandomValues(new Uint8Array(16));
  const out = await FNS[algorithm](bytes(password), salt, { m, t, p, dkLen, asyncTick: 10, ...(options.secret ? { key: bytes(options.secret) } : {}) });
  return `$${NAMES[algorithm]}$v=19$m=${m},t=${t},p=${p}$${b64(salt)}$${b64(out)}`;
}

export async function verify(hashed, password, options = {}) {
  const mt = /^\$(argon2id|argon2i|argon2d)\$v=(\d+)\$m=(\d+),t=(\d+),p=(\d+)\$([A-Za-z0-9+/]+)\$([A-Za-z0-9+/]+)$/.exec(String(hashed));
  if (!mt) throw new Error('Invalid hashed password');
  const algorithm = NAMES.indexOf(mt[1]);
  const salt = unb64(mt[6]);
  const expected = unb64(mt[7]);
  const out = await FNS[algorithm](bytes(password), salt, {
    m: Number(mt[3]),
    t: Number(mt[4]),
    p: Number(mt[5]),
    dkLen: expected.length,
    asyncTick: 10,
    ...(options.secret ? { key: bytes(options.secret) } : {}),
  });
  if (out.length !== expected.length) return false;
  let d = 0;
  for (let i = 0; i < out.length; i++) d |= out[i] ^ expected[i];
  return d === 0;
}

export function hashSync() {
  throw new Error('argon2.hashSync не поддерживается в браузерном бэкенде');
}
export function verifySync() {
  throw new Error('argon2.verifySync не поддерживается в браузерном бэкенде');
}
export default { hash, verify, hashSync, verifySync, Algorithm, Version };
