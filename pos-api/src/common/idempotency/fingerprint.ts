import { createHash } from 'node:crypto';

/**
 * `requestFingerprint = SHA-256(канонизированное тело + path-параметры)` (08 §2.7). Канонизация: ключи объектов
 * сортируются, `undefined` опускается — порядок полей в JSON клиента на отпечаток не влияет.
 */
export function canonicalJson(value: unknown): string {
  if (value === null || value === undefined) return 'null';
  if (Array.isArray(value)) return `[${value.map((v) => (v === undefined ? 'null' : canonicalJson(v))).join(',')}]`;
  if (typeof value === 'object') {
    if (value instanceof Date) return JSON.stringify(value.toISOString());
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([, v]) => v !== undefined)
      // Ключи объекта уникальны — равенства в сравнении не бывает.
      .sort(([a], [b]) => (a < b ? -1 : 1));
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonicalJson(v)}`).join(',')}}`;
  }
  if (typeof value === 'bigint') return JSON.stringify(value.toString());
  return JSON.stringify(value);
}

export function requestFingerprint(params: unknown, body: unknown): Buffer {
  return createHash('sha256')
    .update(canonicalJson({ params: params ?? {}, body: body ?? null }), 'utf8')
    .digest();
}
