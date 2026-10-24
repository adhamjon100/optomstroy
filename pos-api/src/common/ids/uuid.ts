import { v7 as uuidv7, validate as uuidValidate } from 'uuid';

/** UUID v7 в нижнем регистре — идентификаторы и requestId (08 §2.1, §2.3; R5 §3.4). */
export function newId(): string {
  return uuidv7();
}

/** Любая версия UUID в каноническом виде (36 символов). */
export function isUuid(value: unknown): value is string {
  return typeof value === 'string' && value.length === 36 && uuidValidate(value);
}

const UUID_V4_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

/** UUID v4 в нижнем регистре — формат Idempotency-Key (08 §2.7, схема IdempotencyKeyValue). */
export function isUuidV4Lower(value: unknown): value is string {
  return typeof value === 'string' && UUID_V4_RE.test(value);
}
