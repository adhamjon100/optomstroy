// Подмена dist/common/auth/jwt-keys.js для браузера (WP-B2, plan §3.3): тот же экспортируемый API
// src/common/auth/jwt-keys.ts — JWT_ALLOWED_ALGS, JWT_KID_RE, EPHEMERAL_KID, JwtKeyConfigError, parseJwtKeyRing
// и форма JwtKeyRing { signing, verify: Map<kid, {kid, alg, key}>, ephemeral } — но ключ — WebCrypto CryptoKey
// (Ed25519 → EdDSA, запасной P-256 → ES256: отбор алгоритма как algOf() оригинала), а не KeyObject node:crypto.
// Кольцо готовится асинхронно ДО createApp (prepareJwtKeyRing): WebCrypto не бывает синхронным, а parseJwtKeyRing
// вызывается синхронно из фабрики Nest (auth-core.module). Ключ живёт эпоху: JWK закрытого ключа хранится
// вызывающим (WP-B3: demo_meta) и восстанавливается на тёплом старте — токены переживают перезагрузку вкладки.
// jose (browser-сборка) подписывает и проверяет CryptoKey напрямую. PEM-ключи из конфигурации в демо не нужны.
export const JWT_ALLOWED_ALGS = ['EdDSA', 'ES256'];
export const JWT_KID_RE = /^[A-Za-z0-9._-]{1,64}$/;
export const EPHEMERAL_KID = 'dev-ephemeral';

export class JwtKeyConfigError extends Error {
  name = 'JwtKeyConfigError';
}

let prepared = null;

const PARAMS = { EdDSA: { name: 'Ed25519' }, ES256: { name: 'ECDSA', namedCurve: 'P-256' } };

/** Алгоритм по JWK — те же два, что algOf() оригинала (09 §8.1). */
function algOfJwk(jwk) {
  if (jwk?.kty === 'OKP' && jwk.crv === 'Ed25519') return 'EdDSA';
  if (jwk?.kty === 'EC' && jwk.crv === 'P-256') return 'ES256';
  throw new JwtKeyConfigError('JWT (демо): поддерживаются только Ed25519 (EdDSA) и P-256 (ES256) — 09 §8.1');
}
function checkKid(kid) {
  if (!JWT_KID_RE.test(kid)) throw new JwtKeyConfigError(`JWT (демо): kid «${kid}» не соответствует [A-Za-z0-9._-]{1,64}`);
  return kid;
}

/**
 * Создать (jwk не задан) или восстановить (jwk — JWK закрытого ключа) пару ключей эпохи.
 * Возвращает { kid, alg, jwk } — JWK закрытого ключа для сохранения вызывающим.
 * prefer: 'EdDSA' (по умолчанию) или 'ES256'. Если Ed25519 в WebCrypto нет — ES256.
 */
export async function prepareJwtKeyRing({ kid = 'demo-epoch', jwk, prefer = 'EdDSA' } = {}) {
  const subtle = globalThis.crypto?.subtle;
  if (!subtle) throw new JwtKeyConfigError('JWT (демо): WebCrypto недоступен (нужен безопасный контекст https)');
  checkKid(kid);
  let alg;
  let privateKey;
  let publicKey;
  let privateJwk = jwk;
  if (privateJwk) {
    alg = algOfJwk(privateJwk);
    if (!privateJwk.d) throw new JwtKeyConfigError('JWT (демо): JWK не содержит закрытого ключа');
    privateKey = await subtle.importKey('jwk', { ...privateJwk, key_ops: ['sign'] }, PARAMS[alg], false, ['sign']);
    const { d: _d, key_ops: _ops, ...pub } = privateJwk;
    publicKey = await subtle.importKey('jwk', { ...pub, key_ops: ['verify'] }, PARAMS[alg], true, ['verify']);
  } else {
    const order = prefer === 'ES256' ? ['ES256', 'EdDSA'] : ['EdDSA', 'ES256'];
    let pair = null;
    for (const a of order) {
      try {
        pair = await subtle.generateKey(PARAMS[a], true, ['sign', 'verify']);
        alg = a;
        break;
      } catch {
        /* алгоритма нет в этом браузере — следующий */
      }
    }
    if (!pair) throw new JwtKeyConfigError('JWT (демо): WebCrypto не создаёт ни Ed25519, ни P-256');
    privateJwk = await subtle.exportKey('jwk', pair.privateKey);
    privateKey = pair.privateKey;
    publicKey = pair.publicKey;
  }
  prepared = {
    signing: { kid, alg, key: privateKey },
    verify: new Map([[kid, { kid, alg, key: publicKey }]]),
    ephemeral: false,
  };
  return { kid, alg, jwk: privateJwk };
}

/** Подготовленное кольцо (или null) — для проверок и тестов. */
export function preparedJwtKeyRing() {
  return prepared;
}
/** Только для тестов. */
export function resetJwtKeyRing() {
  prepared = null;
}

/**
 * Синхронный разбор, как в оригинале, но источник — подготовленное кольцо эпохи. PEM из конфигурации браузерное
 * демо не принимает (секретов в сборке нет по ADR-113): заданный PEM — ошибка конфигурации, а не молчаливая подмена.
 */
export function parseJwtKeyRing(src = {}) {
  if (src.privateKeyPem?.trim() || src.publicKeys?.trim()) {
    throw new JwtKeyConfigError('JWT (демо): PEM-ключи не поддерживаются — ключ эпохи создаётся в браузере (prepareJwtKeyRing)');
  }
  if (!prepared) throw new JwtKeyConfigError('JWT (демо): ключ эпохи не подготовлен — вызовите prepareJwtKeyRing() до createApp');
  return prepared;
}
