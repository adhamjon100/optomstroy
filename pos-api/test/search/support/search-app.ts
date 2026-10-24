import type { Writable } from 'node:stream';
import { Global, Module } from '@nestjs/common';
import { APP_FILTER, APP_GUARD, APP_PIPE } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { Test } from '@nestjs/testing';
import type { NextFunction, Request, Response } from 'express';
import type pg from 'pg';
import { configureHttpApp } from '../../../src/bootstrap/create-app.js';
import { type AppConfig, loadAppConfig } from '../../../src/common/config/app-config.js';
import { ConfigModule } from '../../../src/common/config/config.module.js';
import { CryptoModule } from '../../../src/common/crypto/crypto.module.js';
import { PG_POOL } from '../../../src/common/db/database.module.js';
import type { Principal } from '../../../src/common/http/request-context.js';
import { LoggingModule } from '../../../src/common/logging/logging.module.js';
import { ProblemDetailsFilter } from '../../../src/common/problem-details/problem-details.filter.js';
import { RbacGuard } from '../../../src/common/rbac/rbac.guard.js';
import { RbacModule } from '../../../src/common/rbac/rbac.module.js';
import { SettingsModule } from '../../../src/common/settings/settings.module.js';
import { createValidationPipe } from '../../../src/common/validation/validation.js';
import { SearchModule } from '../../../src/catalog/search/search.module.js';
import { LogCapture } from '../../support/test-app.js';

/**
 * Nest-приложение для e2e поиска: SearchModule поверх реальной БД (embedded PG с каталогом) и инфраструктуры common
 * (Config, Logging, Rbac, Crypto, Settings). Субъект запроса — заголовок `x-test-principal` (JSON Principal, только
 * тесты), как в test/support/test-app.ts; RbacGuard и фильтр Problem — боевые. JWT здесь не проверяется — это
 * покрывают тесты этапа D (AuthGuard → RbacGuard); поиск зависит только от `req.principal`.
 */
export async function createSearchApp(
  pool: pg.Pool,
  env: Record<string, string> = {},
  logStream?: Writable,
  /** Дополнительные express-middleware до регистрации маршрутов (бенчмарк — замер времени на сервере). */
  beforeInit?: (app: NestExpressApplication) => void,
): Promise<{ app: NestExpressApplication; logs: LogCapture; config: AppConfig }> {
  const config = loadAppConfig({
    APP_ENV: 'dev',
    LOG_LEVEL: 'warn',
    MIN_APP_VERSION: 'android=1.2.0,windows=1.2.0',
    DATABASE_URL: 'postgres://unused@127.0.0.1:1/unused',
    ...env,
  });
  const logs = new LogCapture();

  @Global()
  @Module({ providers: [{ provide: PG_POOL, useValue: pool }], exports: [PG_POOL] })
  class SearchTestDbModule {}

  @Module({
    imports: [
      ConfigModule.forRoot(config),
      LoggingModule.forRoot(config, logStream ?? logs),
      SearchTestDbModule,
      RbacModule,
      CryptoModule,
      SettingsModule,
      SearchModule,
    ],
    providers: [
      { provide: APP_GUARD, useClass: RbacGuard },
      { provide: APP_FILTER, useClass: ProblemDetailsFilter },
      { provide: APP_PIPE, useFactory: createValidationPipe },
    ],
  })
  class SearchTestRootModule {}

  const moduleRef = await Test.createTestingModule({ imports: [SearchTestRootModule] }).compile();
  const app = moduleRef.createNestApplication<NestExpressApplication>({ bodyParser: false, bufferLogs: true });
  configureHttpApp(app);
  app.use((req: Request & { principal?: Principal }, _res: Response, next: NextFunction) => {
    const raw = req.header('x-test-principal');
    if (raw) req.principal = JSON.parse(raw) as Principal;
    next();
  });
  beforeInit?.(app);
  await app.init();
  return { app, logs, config };
}

/** Заголовок субъекта для роли (userId — произвольный UUID; строка users не нужна, кроме избранного). */
export function principalHeader(role: string, userId = '00000000-0000-4000-8000-0000000000a1'): string {
  const kind = role === 'customer' ? 'customer' : role === 'integration' ? 'integration' : 'staff';
  return JSON.stringify({ userId, kind, roles: [role], status: 'active' } satisfies Principal);
}
