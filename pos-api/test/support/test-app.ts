import { Writable } from 'node:stream';
import {
  type DynamicModule,
  Global,
  type MiddlewareConsumer,
  Module,
  type NestModule,
  type Provider,
  RequestMethod,
  type Type,
} from '@nestjs/common';
import { APP_FILTER, APP_GUARD, APP_INTERCEPTOR, APP_PIPE } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { Test } from '@nestjs/testing';
import type { NextFunction, Request, Response } from 'express';
import type pg from 'pg';
import { configureHttpApp } from '../../src/bootstrap/create-app.js';
import { AppVersionMiddleware } from '../../src/common/app-version/app-version.middleware.js';
import { AppVersionModule } from '../../src/common/app-version/app-version.module.js';
import { type AppConfig, loadAppConfig } from '../../src/common/config/app-config.js';
import { ConfigModule } from '../../src/common/config/config.module.js';
import { PG_POOL } from '../../src/common/db/database.module.js';
import type { Principal } from '../../src/common/http/request-context.js';
import { IdempotencyInterceptor } from '../../src/common/idempotency/idempotency.interceptor.js';
import { InMemoryIdempotencyStore } from '../../src/common/idempotency/idempotency.memory-store.js';
import { IdempotencyService } from '../../src/common/idempotency/idempotency.service.js';
import { IDEMPOTENCY_STORE } from '../../src/common/idempotency/idempotency.store.js';
import { LoggingModule } from '../../src/common/logging/logging.module.js';
import { ProblemDetailsFilter } from '../../src/common/problem-details/problem-details.filter.js';
import { RbacGuard } from '../../src/common/rbac/rbac.guard.js';
import { RbacModule } from '../../src/common/rbac/rbac.module.js';
import {
  type AllowedMutation,
  DEFAULT_READ_ONLY_ALLOWLIST,
  READ_ONLY_ALLOWLIST,
} from '../../src/common/read-only/read-only.allowlist.js';
import { ReadOnlyGuard } from '../../src/common/read-only/read-only.guard.js';
import { SettingsReader } from '../../src/common/settings/settings-reader.js';
import { createValidationPipe } from '../../src/common/validation/validation.js';

/** Минимальное окружение для тестов (без секретов; БД не нужна). */
export const TEST_ENV: Record<string, string> = {
  APP_ENV: 'dev',
  LOG_LEVEL: 'info',
  MIN_APP_VERSION: 'android=1.2.0,windows=1.2.0',
  DATABASE_URL: 'postgres://test:test@127.0.0.1:1/none',
};

export function testConfig(overrides: Record<string, string | undefined> = {}): AppConfig {
  return loadAppConfig({ ...TEST_ENV, ...overrides });
}

/** Поток, собирающий строки лога pino (JSON по строке). */
export class LogCapture extends Writable {
  readonly lines: string[] = [];

  override _write(chunk: Buffer | string, _enc: BufferEncoding, cb: (error?: Error | null) => void): void {
    for (const line of chunk.toString().split('\n')) if (line.trim() !== '') this.lines.push(line);
    cb();
  }

  get text(): string {
    return this.lines.join('\n');
  }

  json(): Record<string, unknown>[] {
    return this.lines.map((l) => JSON.parse(l) as Record<string, unknown>);
  }
}

/** Фейковая таблица app_settings для SettingsReader (запрос `SELECT value FROM app_settings WHERE key = $1`). */
export class FakeSettingsTable {
  readonly values = new Map<string, unknown>();
  failing = false;

  readonly pool = {
    query: (_sql: string, params: unknown[]): Promise<{ rows: { value: unknown }[] }> => {
      if (this.failing) return Promise.reject(new Error('db down'));
      const key = String(params[0]);
      return Promise.resolve({ rows: this.values.has(key) ? [{ value: this.values.get(key) }] : [] });
    },
  };
}

export interface TestAppOptions {
  readonly config?: AppConfig;
  readonly controllers?: Type[];
  readonly providers?: Provider[];
  readonly imports?: (Type | DynamicModule)[];
  /** Субъект для каждого запроса (вместо common/auth-context этапа D); `x-test-principal` в JSON перекрывает. */
  readonly principal?: Principal;
  readonly settings?: FakeSettingsTable;
  readonly now?: () => number;
  readonly logStream?: LogCapture;
  readonly idempotencyStore?: InMemoryIdempotencyStore;
  /** Перечень APP_READ_ONLY; по умолчанию — как в AppModule (пустой до принятия ADR-083). */
  readonly readOnlyAllowlist?: readonly AllowedMutation[];
}

/** Тестовая подстановка субъекта: заголовок `x-test-principal: {"userId":…,"roles":[…]}` (только тесты). */
function principalMiddleware(defaultPrincipal?: Principal) {
  return (req: Request & { principal?: Principal }, _res: Response, next: NextFunction): void => {
    const raw = req.header('x-test-principal');
    req.principal = raw ? (JSON.parse(raw) as Principal) : defaultPrincipal;
    next();
  };
}

/**
 * Собирает Nest-приложение с инфраструктурой common/* (как AppModule), но без БД и pg-boss:
 * SettingsReader — на FakeSettingsTable, идемпотентность — на InMemoryIdempotencyStore.
 */
export async function createTestApp(options: TestAppOptions = {}): Promise<NestExpressApplication> {
  const config = options.config ?? testConfig();
  const settings = options.settings ?? new FakeSettingsTable();
  const store = options.idempotencyStore ?? new InMemoryIdempotencyStore();
  const logStream = options.logStream ?? new LogCapture();

  @Global()
  @Module({
    providers: [
      { provide: PG_POOL, useValue: settings.pool },
      {
        provide: SettingsReader,
        useFactory: () =>
          new SettingsReader(settings.pool as unknown as Pick<pg.Pool, 'query'>, options.now ?? Date.now),
      },
      { provide: IDEMPOTENCY_STORE, useValue: store },
      IdempotencyService,
    ],
    exports: [PG_POOL, SettingsReader, IDEMPOTENCY_STORE, IdempotencyService],
  })
  class TestInfraModule {}

  @Module({
    imports: [
      ConfigModule.forRoot(config),
      LoggingModule.forRoot(config, logStream),
      TestInfraModule,
      RbacModule,
      AppVersionModule,
      ...(options.imports ?? []),
    ],
    controllers: options.controllers ?? [],
    providers: [
      { provide: READ_ONLY_ALLOWLIST, useValue: options.readOnlyAllowlist ?? DEFAULT_READ_ONLY_ALLOWLIST },
      { provide: APP_GUARD, useClass: ReadOnlyGuard },
      { provide: APP_GUARD, useClass: RbacGuard },
      { provide: APP_INTERCEPTOR, useClass: IdempotencyInterceptor },
      { provide: APP_FILTER, useClass: ProblemDetailsFilter },
      { provide: APP_PIPE, useFactory: createValidationPipe },
      ...(options.providers ?? []),
    ],
  })
  class TestRootModule implements NestModule {
    configure(consumer: MiddlewareConsumer): void {
      consumer.apply(AppVersionMiddleware).forRoutes({ path: '{*splat}', method: RequestMethod.ALL });
    }
  }

  const moduleRef = await Test.createTestingModule({ imports: [TestRootModule] }).compile();
  const app = moduleRef.createNestApplication<NestExpressApplication>({ bodyParser: false, bufferLogs: true });
  configureHttpApp(app);
  app.use(principalMiddleware(options.principal));
  await app.init();
  return app;
}
