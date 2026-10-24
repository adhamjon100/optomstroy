/**
 * Тестовый выпуск access-JWT для e2e до этапа D (RM-C-008 `[НОВОЕ ИМЯ]`; 13 §2.3 — BE/ONEC-дорожка этапа E).
 *
 *   APP_ENV=dev JWT_PRIVATE_KEY_FILE=./.tmp/jwt/dev_ed25519.pem \
 *     npx tsx scripts/issue_test_jwt.ts --role seller [--sub <uuid>] [--kind staff] [--permissions-version 1] \
 *       [--device-id <uuid>] [--sid <uuid>] [--ttl 900] [--kid dev-1]
 *
 * - Работает **только** при `APP_ENV=dev|staging` (значение обязательно; иначе — код выхода 2, токен не выпускается).
 * - Ключ — PEM PKCS#8 из файла `JWT_PRIVATE_KEY_FILE` (Ed25519 → `EdDSA`, P-256 → `ES256`; 09 §8.1). Прямое значение
 *   `JWT_PRIVATE_KEY` не читается: секреты — только файлом (09 §6.11, 16 §4.3). `kid` — `--kid` или `JWT_KEY_ID`.
 * - Claims — 09 §8.1 / SESS-003: `iss=optomstroy-pos`, `aud=optomstroy-api`, `sub`, `kind`, `roles[]`,
 *   `permissionsVersion`, `deviceId`, `sid`, `jti`, `iat`, `exp`, `amr` (`["sms"]`). Без ПДн.
 * - Роль — из contracts/rbac/permissions.yaml (permissions.generated.ts); в R1 одна активная роль (B-AR-02).
 * - В stdout — только токен (одна строка); диагностика — в stderr без значения ключа.
 * - В prod-образ не входит: `tsconfig.build.json` собирает только `src/**`, runtime-стадия Dockerfile копирует
 *   `dist/`, `node_modules/`, `migrations/` (каталога `scripts/` в образе нет).
 */
import { createPrivateKey, type KeyObject, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import { SignJWT } from 'jose';
import { v7 as uuidv7 } from 'uuid';
import { RBAC_ROLES, type RbacRole } from '../src/common/rbac/permissions.generated.js';

export const TEST_JWT_ISSUER = 'optomstroy-pos';
export const TEST_JWT_AUDIENCE = 'optomstroy-api';
export const ALLOWED_APP_ENVS = ['dev', 'staging'] as const;
/** Верхняя граница срока тестового токена (24 ч), по умолчанию — `AUTH_ACCESS_TTL_SECONDS` = 900 (D-12). */
export const MAX_TEST_TTL_SECONDS = 86_400;

export type TokenKind = 'staff' | 'customer' | 'integration';

export interface TestJwtOptions {
  readonly role: RbacRole;
  readonly sub?: string;
  readonly kind?: TokenKind;
  readonly permissionsVersion?: number;
  readonly deviceId?: string;
  readonly sid?: string;
  readonly ttlSeconds?: number;
  readonly kid?: string;
  readonly now?: Date;
}

export interface TestJwtClaims {
  readonly iss: string;
  readonly aud: string;
  readonly sub: string;
  readonly kind: TokenKind;
  readonly roles: readonly RbacRole[];
  readonly permissionsVersion: number;
  readonly deviceId: string;
  readonly sid: string;
  readonly jti: string;
  readonly iat: number;
  readonly exp: number;
  readonly amr: readonly string[];
}

export class TestJwtError extends Error {
  override readonly name = 'TestJwtError';
}

type Env = Readonly<Record<string, string | undefined>>;

/** Отказ вне dev/staging (в том числе при незаданном `APP_ENV`): тестовые токены в prod невозможны. */
export function assertTestEnvironment(env: Env): (typeof ALLOWED_APP_ENVS)[number] {
  const appEnv = env.APP_ENV?.trim();
  if (appEnv !== 'dev' && appEnv !== 'staging') {
    throw new TestJwtError(
      `issue_test_jwt: запрещено при APP_ENV=${appEnv === undefined || appEnv === '' ? '(не задано)' : appEnv}; ` +
        'допустимо только dev | staging (RM-C-008)',
    );
  }
  return appEnv;
}

function loadSigningKey(env: Env): { key: KeyObject; alg: 'EdDSA' | 'ES256' } {
  const file = env.JWT_PRIVATE_KEY_FILE?.trim();
  if (!file)
    throw new TestJwtError('issue_test_jwt: не задан JWT_PRIVATE_KEY_FILE (путь к PEM PKCS#8 dev/staging-ключа)');
  let pem: string;
  try {
    pem = readFileSync(file, 'utf8');
  } catch (e) {
    const code = e instanceof Error && 'code' in e ? String((e as NodeJS.ErrnoException).code) : 'read error';
    throw new TestJwtError(`issue_test_jwt: не удалось прочитать JWT_PRIVATE_KEY_FILE (${code})`);
  }
  let key: KeyObject;
  try {
    key = createPrivateKey(pem);
  } catch {
    throw new TestJwtError('issue_test_jwt: JWT_PRIVATE_KEY_FILE не содержит закрытого ключа PEM');
  }
  if (key.asymmetricKeyType === 'ed25519') return { key, alg: 'EdDSA' };
  if (key.asymmetricKeyType === 'ec' && key.asymmetricKeyDetails?.namedCurve === 'prime256v1') {
    return { key, alg: 'ES256' };
  }
  throw new TestJwtError('issue_test_jwt: поддерживаются только Ed25519 (EdDSA) и P-256 (ES256) — 09 §8.1');
}

/** Выпускает подписанный access-JWT; бросает `TestJwtError` при запрещённом окружении или неверных параметрах. */
export async function issueTestJwt(options: TestJwtOptions, env: Env = process.env): Promise<string> {
  assertTestEnvironment(env);
  if (!(RBAC_ROLES as readonly string[]).includes(options.role)) {
    throw new TestJwtError(
      `issue_test_jwt: неизвестная роль ${String(options.role)} (contracts/rbac/permissions.yaml)`,
    );
  }
  const ttl = options.ttlSeconds ?? 900;
  if (!Number.isInteger(ttl) || ttl < 1 || ttl > MAX_TEST_TTL_SECONDS) {
    throw new TestJwtError(`issue_test_jwt: --ttl должен быть целым 1…${MAX_TEST_TTL_SECONDS}`);
  }
  const permissionsVersion = options.permissionsVersion ?? 1;
  if (!Number.isInteger(permissionsVersion) || permissionsVersion < 1) {
    throw new TestJwtError('issue_test_jwt: --permissions-version должен быть целым ≥ 1');
  }
  const { key, alg } = loadSigningKey(env);
  const kind: TokenKind =
    options.kind ??
    (options.role === 'customer' ? 'customer' : options.role === 'integration' ? 'integration' : 'staff');
  const iat = Math.floor((options.now ?? new Date()).getTime() / 1000);
  const kid = options.kid ?? (env.JWT_KEY_ID?.trim() || undefined);

  return new SignJWT({
    kind,
    roles: [options.role],
    permissionsVersion,
    deviceId: options.deviceId ?? randomUUID(),
    sid: options.sid ?? uuidv7(),
    amr: ['sms'],
  })
    .setProtectedHeader({ alg, typ: 'JWT', ...(kid ? { kid } : {}) })
    .setIssuer(TEST_JWT_ISSUER)
    .setAudience(TEST_JWT_AUDIENCE)
    .setSubject(options.sub ?? uuidv7())
    .setJti(uuidv7())
    .setIssuedAt(iat)
    .setExpirationTime(iat + ttl)
    .sign(key);
}

function intArg(v: string | undefined, name: string): number | undefined {
  if (v === undefined) return undefined;
  if (!/^\d+$/.test(v)) throw new TestJwtError(`issue_test_jwt: ${name} должен быть целым числом`);
  return Number(v);
}

export async function main(argv: readonly string[] = process.argv.slice(2), env: Env = process.env): Promise<number> {
  try {
    assertTestEnvironment(env); // до разбора аргументов: в prod скрипт ничего не делает
    const { values } = parseArgs({
      args: [...argv],
      options: {
        role: { type: 'string' },
        sub: { type: 'string' },
        kind: { type: 'string' },
        'permissions-version': { type: 'string' },
        'device-id': { type: 'string' },
        sid: { type: 'string' },
        ttl: { type: 'string' },
        kid: { type: 'string' },
      },
      strict: true,
    });
    if (!values.role) throw new TestJwtError(`issue_test_jwt: нужен --role (${RBAC_ROLES.join(' | ')})`);
    if (values.kind !== undefined && !['staff', 'customer', 'integration'].includes(values.kind)) {
      throw new TestJwtError('issue_test_jwt: --kind — staff | customer | integration');
    }
    const token = await issueTestJwt(
      {
        role: values.role as RbacRole,
        sub: values.sub,
        kind: values.kind as TokenKind | undefined,
        permissionsVersion: intArg(values['permissions-version'], '--permissions-version'),
        deviceId: values['device-id'],
        sid: values.sid,
        ttlSeconds: intArg(values.ttl, '--ttl'),
        kid: values.kid,
      },
      env,
    );
    process.stdout.write(`${token}\n`);
    return 0;
  } catch (e) {
    const message =
      e instanceof TestJwtError ? e.message : `issue_test_jwt: ${e instanceof Error ? e.message : 'ошибка'}`;
    process.stderr.write(`${message}\n`);
    return 2;
  }
}

const invokedDirectly = process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;
if (invokedDirectly) {
  process.exitCode = await main();
}
