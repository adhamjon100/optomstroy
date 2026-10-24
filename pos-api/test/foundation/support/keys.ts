import { generateKeyPairSync, randomBytes } from 'node:crypto';

export interface PemPair {
  readonly privatePem: string;
  readonly publicPem: string;
}

/** Временная пара ключей в памяти (в репозиторий и на диск не попадает). */
export function pemPair(type: 'ed25519' | 'p256' = 'ed25519'): PemPair {
  const pair =
    type === 'ed25519' ? generateKeyPairSync('ed25519') : generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  return {
    privatePem: pair.privateKey.export({ type: 'pkcs8', format: 'pem' }).toString(),
    publicPem: pair.publicKey.export({ type: 'spki', format: 'pem' }).toString(),
  };
}

/** Содержимое `JWT_PUBLIC_KEY_FILE`: набор `{kid: pem}`. */
export function publicSet(entries: Record<string, PemPair>): string {
  return JSON.stringify(Object.fromEntries(Object.entries(entries).map(([kid, p]) => [kid, p.publicPem])));
}

/** Тестовый секрет ≥ 32 байт (генерируется на запуск). */
export function testSecret(): string {
  return randomBytes(32).toString('base64url');
}
