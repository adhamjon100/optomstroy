import { Global, Inject, Injectable, Logger, Module, type OnApplicationShutdown } from '@nestjs/common';
import pg from 'pg';
import { createDatabase, type PosDatabase } from '../../db/database.js';
import { APP_CONFIG, type AppConfig } from '../config/app-config.js';

export const PG_POOL = Symbol('PG_POOL');
export const DRIZZLE = Symbol('DRIZZLE');
/** Drizzle-клиент со схемой всех таблиц (src/db/schema/*, RM-C-006). */
export type Database = PosDatabase;

/** Обработчик ошибки простаивающего соединения пула (разрыв БД): только код ошибки, без строки подключения. */
export type PoolErrorHandler = (info: { readonly applicationName: string; readonly code: string | undefined }) => void;

const nestPoolLogger = new Logger('db');

export function createPool(
  config: Pick<AppConfig, 'DATABASE_URL'>,
  applicationName: string,
  onIdleError?: PoolErrorHandler,
): pg.Pool {
  // Соединения открываются лениво: процесс стартует и отвечает на /health без БД (liveness), /health/ready → 503.
  const pool = new pg.Pool({
    connectionString: config.DATABASE_URL,
    application_name: applicationName,
    max: 10,
    connectionTimeoutMillis: 5_000,
    idleTimeoutMillis: 30_000,
  });
  // 12 T-FAIL-012, 06 (восстановление без ручных действий): БД перезапущена или соединения разорваны — простаивающий
  // клиент пула получает ECONNRESET / 57P01 и пул испускает 'error'. Без слушателя это необработанное исключение —
  // процесс API/worker падает. Сломанный клиент пул уже исключил; следующий запрос откроет новое соединение.
  pool.on('error', (err: Error & { code?: string }) => {
    const info = { applicationName, code: err.code };
    try {
      if (onIdleError) onIdleError(info);
      else nestPoolLogger.warn(`pg.pool.idle_client_error: ${applicationName} ${err.code ?? 'unknown'}`);
    } catch {
      // журналирование не должно ронять процесс
    }
  });
  return pool;
}

@Injectable()
class PoolCloser implements OnApplicationShutdown {
  constructor(@Inject(PG_POOL) private readonly pool: pg.Pool) {}

  async onApplicationShutdown(): Promise<void> {
    await this.pool.end();
  }
}

@Global()
@Module({
  providers: [
    { provide: PG_POOL, inject: [APP_CONFIG], useFactory: (c: AppConfig) => createPool(c, 'pos-api') },
    { provide: DRIZZLE, inject: [PG_POOL], useFactory: (pool: pg.Pool): Database => createDatabase(pool) },
    PoolCloser,
  ],
  exports: [PG_POOL, DRIZZLE],
})
export class DatabaseModule {}
