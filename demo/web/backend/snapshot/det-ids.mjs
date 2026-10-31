// Подмена dist/common/ids/uuid.js ТОЛЬКО в построителе снимка (WP-B4): детерминированный UUID v7, чтобы два прогона
// сборки давали байт-в-байт одинаковый снимок (manifest.json и ключ эпохи не меняются от пересборки). Формат — как у
// uuid v7 пакета uuid (48 бит времени, версия 7, 12 бит счётчика, вариант 10, 62 бита «случайности»); время —
// T0 снимка, «случайность» — sha256 от номера. В браузерном бэкенде (backend.js) подмены нет: там настоящий v7.
import { createHash } from 'node:crypto';
import { validate as uuidValidate } from 'uuid';

let base = Date.UTC(2026, 0, 1);
let n = 0;

/** Начать последовательность заново (каждая сборка снимка): t0 — мс эпохи времени снимка. */
export function resetDeterministicIds(t0Ms) {
  base = t0Ms;
  n = 0;
}

/** UUID v7 в нижнем регистре — идентификаторы и requestId (08 §2.1, §2.3; R5 §3.4). */
export function newId() {
  const i = n++;
  const ms = base + Math.floor(i / 4096);
  const counter = i % 4096;
  const h = createHash('sha256').update(`pos-demo-snapshot/js/${i}`).digest();
  const b = Buffer.alloc(16);
  b.writeUIntBE(ms, 0, 6);
  b[6] = 0x70 | (counter >> 8);
  b[7] = counter & 0xff;
  h.copy(b, 8, 0, 8);
  b[8] = 0x80 | (b[8] & 0x3f);
  const x = b.toString('hex');
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20)}`;
}

/** Любая версия UUID в каноническом виде (36 символов). */
export function isUuid(value) {
  return typeof value === 'string' && value.length === 36 && uuidValidate(value);
}

const UUID_V4_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

/** UUID v4 в нижнем регистре — формат Idempotency-Key (08 §2.7, схема IdempotencyKeyValue). */
export function isUuidV4Lower(value) {
  return typeof value === 'string' && UUID_V4_RE.test(value);
}
