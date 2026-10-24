import { createPrivateKey, createPublicKey, generateKeyPairSync, type KeyObject } from 'node:crypto';

/**
 * Набор ключей access-JWT (09 §8.1; D-12; ядро R0 §17.7; RM-D-003 п. 4):
 * - `JWT_PRIVATE_KEY_FILE` — PEM PKCS#8 текущего ключа подписи, его `kid` — `JWT_KEY_ID`;
 * - `JWT_PUBLIC_KEY_FILE` — набор `{"<kid>": "<PEM SPKI>", …}` (JSON): текущий и предыдущие ключи — токены,
 *   подписанные прежним ключом, принимаются до истечения; допускается и одиночный PEM (тогда его `kid` = `JWT_KEY_ID`).
 * Алгоритмы — только Ed25519 → `EdDSA` (основной) и P-256 → `ES256` (09 §8.1); `alg` фиксирован ключом `kid`
 * (защита от подмены алгоритма), `none` и `HS*` не принимаются никогда.
 */
export type JwtAlg = 'EdDSA' | 'ES256';
export const JWT_ALLOWED_ALGS: readonly JwtAlg[] = ['EdDSA', 'ES256'];
export const JWT_KID_RE = /^[A-Za-z0-9._-]{1,64}$/;
/** `kid` эфемерного ключа dev-процесса без настроенных файлов. */
export const EPHEMERAL_KID = 'dev-ephemeral';

export interface JwtVerifyKey {
  readonly kid: string;
  readonly alg: JwtAlg;
  readonly key: KeyObject;
}

export interface JwtSigningKey {
  readonly kid: string;
  readonly alg: JwtAlg;
  readonly key: KeyObject;
}

export interface JwtKeyRing {
  /** Ключ подписи; `undefined` — процесс только проверяет токены (например, pos-worker). */
  readonly signing: JwtSigningKey | undefined;
  readonly verify: ReadonlyMap<string, JwtVerifyKey>;
  readonly ephemeral: boolean;
}

export class JwtKeyConfigError extends Error {
  override readonly name = 'JwtKeyConfigError';
}

export interface JwtKeySource {
  readonly privateKeyPem?: string;
  readonly publicKeys?: string;
  readonly keyId?: string;
  readonly appEnv: string;
}

function algOf(key: KeyObject, what: string): JwtAlg {
  if (key.asymmetricKeyType === 'ed25519') return 'EdDSA';
  if (key.asymmetricKeyType === 'ec' && key.asymmetricKeyDetails?.namedCurve === 'prime256v1') return 'ES256';
  throw new JwtKeyConfigError(`${what}: поддерживаются только Ed25519 (EdDSA) и P-256 (ES256) — 09 §8.1`);
}

function checkKid(kid: string, what: string): string {
  if (!JWT_KID_RE.test(kid)) throw new JwtKeyConfigError(`${what}: kid «${kid}» не соответствует [A-Za-z0-9._-]{1,64}`);
  return kid;
}

function publicFromPem(pem: string, what: string): KeyObject {
  try {
    const key = createPublicKey(pem);
    if (key.type !== 'public') throw new Error('not public');
    return key;
  } catch {
    throw new JwtKeyConfigError(`${what}: не содержит открытого ключа PEM (SPKI)`);
  }
}

function spki(key: KeyObject): Buffer {
  return key.export({ type: 'spki', format: 'der' });
}

function parsePublicSet(raw: string, keyId: string | undefined): Map<string, JwtVerifyKey> {
  const trimmed = raw.trim();
  const out = new Map<string, JwtVerifyKey>();
  if (trimmed.startsWith('{')) {
    let parsed: unknown;
    try {
      parsed = JSON.parse(trimmed);
    } catch {
      throw new JwtKeyConfigError('JWT_PUBLIC_KEY: ожидается JSON-набор {"<kid>": "<PEM>"} или один PEM');
    }
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new JwtKeyConfigError('JWT_PUBLIC_KEY: ожидается JSON-набор {"<kid>": "<PEM>"}');
    }
    for (const [kid, pem] of Object.entries(parsed as Record<string, unknown>)) {
      checkKid(kid, 'JWT_PUBLIC_KEY');
      if (typeof pem !== 'string')
        throw new JwtKeyConfigError(`JWT_PUBLIC_KEY[${kid}]: значение должно быть PEM-строкой`);
      const key = publicFromPem(pem, `JWT_PUBLIC_KEY[${kid}]`);
      out.set(kid, { kid, alg: algOf(key, `JWT_PUBLIC_KEY[${kid}]`), key });
    }
    if (out.size === 0) throw new JwtKeyConfigError('JWT_PUBLIC_KEY: пустой набор ключей');
    return out;
  }
  if (!keyId) throw new JwtKeyConfigError('JWT_PUBLIC_KEY задан одним PEM — нужен JWT_KEY_ID');
  const key = publicFromPem(trimmed, 'JWT_PUBLIC_KEY');
  out.set(keyId, { kid: keyId, alg: algOf(key, 'JWT_PUBLIC_KEY'), key });
  return out;
}

/**
 * Разбор ключей из конфигурации. Без ключей: `APP_ENV=dev` → эфемерная пара Ed25519 (`kid=dev-ephemeral`,
 * токены не переживают перезапуск), иначе — ошибка старта (секреты обязательны вне dev).
 */
export function parseJwtKeyRing(src: JwtKeySource): JwtKeyRing {
  const privatePem = src.privateKeyPem?.trim() ? src.privateKeyPem : undefined;
  const publicRaw = src.publicKeys?.trim() ? src.publicKeys : undefined;
  const keyId = src.keyId?.trim() ? checkKid(src.keyId.trim(), 'JWT_KEY_ID') : undefined;

  if (!privatePem && !publicRaw) {
    if (src.appEnv !== 'dev') {
      throw new JwtKeyConfigError(
        `JWT_PRIVATE_KEY_FILE / JWT_PUBLIC_KEY_FILE не заданы: обязательны при APP_ENV=${src.appEnv}`,
      );
    }
    const pair = generateKeyPairSync('ed25519');
    const kid = EPHEMERAL_KID;
    return {
      signing: { kid, alg: 'EdDSA', key: pair.privateKey },
      verify: new Map([[kid, { kid, alg: 'EdDSA', key: pair.publicKey }]]),
      ephemeral: true,
    };
  }

  const verify = publicRaw ? parsePublicSet(publicRaw, keyId) : new Map<string, JwtVerifyKey>();
  let signing: JwtSigningKey | undefined;
  if (privatePem) {
    if (!keyId) throw new JwtKeyConfigError('JWT_KEY_ID обязателен при заданном JWT_PRIVATE_KEY_FILE');
    let key: KeyObject;
    try {
      key = createPrivateKey(privatePem);
    } catch {
      throw new JwtKeyConfigError('JWT_PRIVATE_KEY: не содержит закрытого ключа PEM (PKCS#8)');
    }
    const alg = algOf(key, 'JWT_PRIVATE_KEY');
    const derived = createPublicKey(key);
    const listed = verify.get(keyId);
    if (listed) {
      if (!spki(listed.key).equals(spki(derived))) {
        throw new JwtKeyConfigError(`JWT_PUBLIC_KEY[${keyId}] не соответствует JWT_PRIVATE_KEY (JWT_KEY_ID=${keyId})`);
      }
    } else if (publicRaw) {
      throw new JwtKeyConfigError(`JWT_PUBLIC_KEY: в наборе нет текущего kid ${keyId} (JWT_KEY_ID)`);
    } else {
      verify.set(keyId, { kid: keyId, alg, key: derived });
    }
    signing = { kid: keyId, alg, key };
  }
  return { signing, verify, ephemeral: false };
}
