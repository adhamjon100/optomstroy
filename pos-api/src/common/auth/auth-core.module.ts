import { Global, Logger, Module, type Provider } from '@nestjs/common';
import { APP_GUARD } from '@nestjs/core';
import { APP_CONFIG, type AppConfig } from '../config/app-config.js';
import { AuthGuard } from './auth.guard.js';
import { AuthStateCache } from './auth-state.js';
import { CLOCK, type Clock, systemClock } from './clock.js';
import { type JwtKeyRing, parseJwtKeyRing } from './jwt-keys.js';
import { JwtService } from './jwt.service.js';

export const JWT_KEY_RING = Symbol('JWT_KEY_RING');

export function jwtKeyRingFromConfig(c: AppConfig): JwtKeyRing {
  const ring = parseJwtKeyRing({
    privateKeyPem: c.JWT_PRIVATE_KEY,
    publicKeys: c.JWT_PUBLIC_KEY,
    keyId: c.JWT_KEY_ID,
    appEnv: c.APP_ENV,
  });
  if (ring.ephemeral) {
    new Logger('auth').warn(
      { event: 'auth.ephemeral_jwt_key' },
      'JWT_PRIVATE_KEY_FILE не задан: APP_ENV=dev — эфемерный ключ Ed25519 до перезапуска процесса',
    );
  }
  return ring;
}

/**
 * Глобальный guard аутентификации для `AppModule` (`GLOBAL_PROVIDERS`): вставляется **между** ReadOnlyGuard и
 * RbacGuard — Nest применяет APP_GUARD в порядке регистрации. Файл app.module.ts — у владельца каркаса.
 */
export const AUTH_APP_GUARD: Provider = { provide: APP_GUARD, useClass: AuthGuard };

/**
 * common/auth (этап D, общий фундамент): JwtService (jose EdDSA/ES256, `kid`-ротация из `JWT_*_FILE`),
 * AuthStateCache (кэш 60 с), AuthGuard, часы `CLOCK`. Порт `AUTH_STATE_READER` предоставляет `UsersModule`
 * (src/users) — оба модуля глобальные.
 */
@Global()
@Module({
  providers: [
    { provide: CLOCK, useValue: systemClock },
    { provide: JWT_KEY_RING, inject: [APP_CONFIG], useFactory: jwtKeyRingFromConfig },
    {
      provide: JwtService,
      inject: [JWT_KEY_RING, APP_CONFIG, CLOCK],
      useFactory: (ring: JwtKeyRing, c: AppConfig, clock: Clock) =>
        new JwtService(ring, { accessTtlSeconds: c.AUTH_ACCESS_TTL_SECONDS }, clock),
    },
    AuthStateCache,
    AuthGuard,
  ],
  exports: [CLOCK, JWT_KEY_RING, JwtService, AuthStateCache, AuthGuard],
})
export class AuthCoreModule {}
