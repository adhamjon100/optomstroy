import { type DynamicModule, Global, Module } from '@nestjs/common';
import { APP_CONFIG, type AppConfig } from './app-config.js';

/**
 * Роль процесса (06 §7.5, D-45 «тот же код с ролью воркера»): `api` — HTTP pos-api (main.ts, тесты), `worker` —
 * pos-worker (worker.ts, контекст Nest без HTTP). Нужна там, где задачу исполняет не любой процесс с
 * `WORKERS_ENABLED=true`, а владелец состояния: песочница банка живёт в процессе pos-api (ADR-123).
 */
export const PROCESS_ROLE = Symbol('PROCESS_ROLE');
export type ProcessRole = 'api' | 'worker';

/** Глобальный модуль конфигурации: конфигурация валидируется до создания Nest-приложения (main.ts). */
@Global()
@Module({})
export class ConfigModule {
  static forRoot(config: AppConfig, processRole: ProcessRole = 'api'): DynamicModule {
    return {
      module: ConfigModule,
      providers: [
        { provide: APP_CONFIG, useValue: config },
        { provide: PROCESS_ROLE, useValue: processRole },
      ],
      exports: [APP_CONFIG, PROCESS_ROLE],
    };
  }
}
