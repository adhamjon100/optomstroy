import { Injectable, Logger, type OnApplicationShutdown, type OnModuleInit } from '@nestjs/common';
import { PgBoss } from 'pg-boss';

export const PG_BOSS_SCHEMA = 'pgboss';

/**
 * Экземпляр pg-boss процесса API (D-44: очереди только в PostgreSQL). В API он нужен для публикации задач
 * (`send`) и проверки готовности; обработчики, расписания и обслуживание (`supervise`, `schedule`) включает
 * только worker (RM-C-007, `WORKERS_ENABLED`). Старт не блокирует запуск HTTP: при недоступной БД сервис
 * повторяет попытку, а `/health/ready` отвечает 503, пока pg-boss не готов.
 */
@Injectable()
export class PgBossService implements OnModuleInit, OnApplicationShutdown {
  private readonly logger = new Logger('pg-boss');
  private boss: PgBoss | undefined;
  private started = false;
  private stopping = false;
  private retryTimer: NodeJS.Timeout | undefined;
  private startPromise: Promise<void> | undefined;

  constructor(
    private readonly connectionString: string,
    private readonly options: { readonly retryDelayMs?: number; readonly autoStart?: boolean } = {},
  ) {}

  onModuleInit(): void {
    if (this.options.autoStart !== false) void this.start();
  }

  /** Запуск с повторами; промис разрешается после первого успешного старта. */
  start(): Promise<void> {
    this.startPromise ??= new Promise<void>((resolve) => {
      const attempt = async (): Promise<void> => {
        if (this.stopping) return resolve();
        const boss = new PgBoss({
          connectionString: this.connectionString,
          schema: PG_BOSS_SCHEMA,
          application_name: 'pos-api:pg-boss',
          supervise: false,
          schedule: false,
          max: 2,
        });
        boss.on('error', (err: unknown) => this.logger.error({ err }, 'pg-boss error'));
        try {
          await boss.start();
          this.boss = boss;
          this.started = true;
          this.logger.log('pg-boss started');
          resolve();
        } catch (err) {
          this.logger.warn({ err }, 'pg-boss start failed, retrying');
          await boss.stop({ graceful: false }).catch(() => undefined);
          this.retryTimer = setTimeout(() => void attempt(), this.options.retryDelayMs ?? 15_000);
          this.retryTimer.unref();
        }
      };
      void attempt();
    });
    return this.startPromise;
  }

  get instance(): PgBoss | undefined {
    return this.started ? this.boss : undefined;
  }

  /** Проверка готовности: экземпляр запущен и схема pg-boss установлена в БД. */
  async isReady(): Promise<boolean> {
    const boss = this.instance;
    if (!boss) return false;
    try {
      return await boss.isInstalled();
    } catch {
      return false;
    }
  }

  async onApplicationShutdown(): Promise<void> {
    this.stopping = true;
    if (this.retryTimer) clearTimeout(this.retryTimer);
    if (this.boss && this.started) await this.boss.stop({ graceful: true, timeout: 5_000 }).catch(() => undefined);
  }
}
