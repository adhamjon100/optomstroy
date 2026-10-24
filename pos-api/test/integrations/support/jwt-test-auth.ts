import { generateKeyPairSync, type KeyObject } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { type MiddlewareConsumer, Module, type NestModule, RequestMethod } from '@nestjs/common';
import type { NextFunction, Request, Response } from 'express';
import { errors as joseErrors, jwtVerify } from 'jose';
import { TEST_JWT_AUDIENCE, TEST_JWT_ISSUER } from '../../../scripts/issue_test_jwt.js';
import type { Principal } from '../../../src/common/http/request-context.js';

/**
 * Временная пара ключей dev для тестов: создаётся в `os.tmpdir()` и удаляется в `dispose()` — в репозиторий
 * не попадает (RM-C-008: «не коммитить»).
 */
export class TempJwtKeys {
  readonly dir = mkdtempSync(join(tmpdir(), 'pos-api-jwt-'));
  readonly privateKeyFile = join(this.dir, 'jwt_private.pem');
  readonly publicKey: KeyObject;

  constructor(type: 'ed25519' | 'p256' = 'ed25519') {
    const pair =
      type === 'ed25519' ? generateKeyPairSync('ed25519') : generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    writeFileSync(this.privateKeyFile, pair.privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
    this.publicKey = pair.publicKey;
  }

  dispose(): void {
    rmSync(this.dir, { recursive: true, force: true });
  }
}

/**
 * Минимальная проверка Bearer access-JWT для тестов RM-C-008 (до common/auth-context этапа D, RM-D-003):
 * подпись (allowlist EdDSA/ES256), `iss`, `aud`, `exp` → `req.principal`. Невалидный токен → без субъекта
 * (RbacGuard ответит 401). Denylist `jti`, `permissionsVersion`, `sessions` — этап D.
 */
export function bearerJwtMiddleware(publicKey: KeyObject) {
  return (req: Request & { principal?: Principal }, _res: Response, next: NextFunction): void => {
    const header = req.header('authorization');
    const m = header ? /^Bearer (\S+)$/.exec(header) : null;
    if (!m?.[1]) {
      next();
      return;
    }
    jwtVerify(m[1], publicKey, {
      issuer: TEST_JWT_ISSUER,
      audience: TEST_JWT_AUDIENCE,
      algorithms: ['EdDSA', 'ES256'],
    })
      .then(({ payload }) => {
        req.principal = {
          userId: String(payload.sub),
          kind: payload.kind as Principal['kind'],
          roles: Array.isArray(payload.roles) ? payload.roles.map(String) : [],
          status: 'active',
          sessionId: typeof payload.sid === 'string' ? payload.sid : undefined,
          deviceId: typeof payload.deviceId === 'string' ? payload.deviceId : undefined,
        };
        next();
      })
      .catch((e: unknown) => {
        if (e instanceof joseErrors.JOSEError) {
          req.principal = undefined;
          next();
          return;
        }
        next(e);
      });
  };
}

/** Модуль, подключающий bearerJwtMiddleware ко всем маршрутам (после тестового principalMiddleware createTestApp). */
export function jwtAuthModule(publicKey: KeyObject): new () => NestModule {
  @Module({})
  class JwtTestAuthModule implements NestModule {
    configure(consumer: MiddlewareConsumer): void {
      consumer.apply(bearerJwtMiddleware(publicKey)).forRoutes({ path: '{*splat}', method: RequestMethod.ALL });
    }
  }
  return JwtTestAuthModule;
}
