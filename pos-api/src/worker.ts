import 'reflect-metadata';
import { type INestApplicationContext, Logger as NestLogger, type LoggerService } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import pino, { type Logger } from 'pino';
import { AppModule } from './app.module.js';
import { CartJobsHandler, registerCartJobs } from './cart/cart-jobs.js';
import { type AppConfig, ConfigError, loadAppConfig } from './common/config/app-config.js';
import { createPool } from './common/db/database.module.js';
import {
  CART_READER,
  type CartReader,
  NOTIFICATIONS_PORT,
  type NotificationsPort,
  PAYMENTS_PORT,
  type PaymentsPort,
} from './common/ports/index.js';
import { buildPinoOptions } from './common/logging/logger.config.js';
import { SettingsReader } from './common/settings/settings-reader.js';
import { createOrdersWorkerWiring } from './jobs/orders/orders-worker.wiring.js';
import { createOtpDeliveryListener } from './jobs/otp/otp-delivery-listener.js';
import { createSyncWorkerWiring } from './jobs/sync/sync-worker.wiring.js';
import { WorkerRuntime } from './jobs/worker-runtime.js';
import { ReturnsStatusSyncHandler } from './returns/onec/returns-jobs.bridge.js';
import { pinoSmsLogger } from './integrations/sms/sms-telemetry.js';
import { SmsRuntime } from './notifications/sms/sms-runtime.js';
import { schedulerConfigFromEnv } from './sync/scheduler/scheduler.config.js';

/**
 * Точка входа `pos-worker` (`node dist/worker.js`, RM-C-007; 16 §4.4: тот же образ, `WORKERS_ENABLED=true`).
 * pg-boss в PostgreSQL (D-44): очереди `sync.*`, `onec.changes`, `outbox.*`, расписания `SYNC_*_CRON` с
 * переопределением `app_settings.sync_interval.<entity>`. При `WORKERS_ENABLED=false` процесс завершается
 * с кодом 0, ничего не исполняя (защита от двойной обработки при ошибочной роли контейнера).
 * Этап F: обработчики заказов, платежей (QR через 1С) и корзины получают порты из контекста Nest (`AppModule` без
 * HTTP) — единое решение FQ-PAY-12 / FQ-ORD-05.
 */
const START_RETRY_MS = 15_000;

/** Логи Nest-компонентов (SettingsReader и др.) — в тот же pino JSON (RM-C-010). */
class PinoNestLogger implements LoggerService {
  constructor(private readonly target: Logger) {}
  log(message: unknown, ...rest: unknown[]): void {
    this.write('info', message, rest);
  }
  error(message: unknown, ...rest: unknown[]): void {
    this.write('error', message, rest);
  }
  warn(message: unknown, ...rest: unknown[]): void {
    this.write('warn', message, rest);
  }
  debug(message: unknown, ...rest: unknown[]): void {
    this.write('debug', message, rest);
  }
  verbose(message: unknown, ...rest: unknown[]): void {
    this.write('trace', message, rest);
  }

  /**
   * Nest `Logger` модулей вызывается и как `log('текст')`, и как `log({ поля }, 'текст')` (стиль pino): объект —
   * поля записи, строка после него — сообщение; последний строковый аргумент — контекст (имя логгера).
   */
  private write(level: 'info' | 'error' | 'warn' | 'debug' | 'trace', message: unknown, rest: unknown[]): void {
    const context = typeof rest.at(-1) === 'string' ? (rest.at(-1) as string) : undefined;
    if (message !== null && typeof message === 'object' && !(message instanceof Error)) {
      const msg = rest.length > 1 && typeof rest[0] === 'string' ? rest[0] : (context ?? '');
      this.target[level]({ ...(message as Record<string, unknown>), context }, msg);
      return;
    }
    if (message instanceof Error) {
      this.target[level]({ err: message, context }, message.message);
      return;
    }
    this.target[level]({ context }, String(message));
  }
}

async function bootstrap(): Promise<void> {
  let config: AppConfig;
  try {
    config = loadAppConfig();
  } catch (e) {
    if (e instanceof ConfigError) {
      console.error(e.message);
      process.exit(1);
    }
    throw e;
  }
  const log = pino(buildPinoOptions(config, 'pos-worker'));
  NestLogger.overrideLogger(new PinoNestLogger(log));

  if (!config.WORKERS_ENABLED) {
    log.warn('worker.disabled: WORKERS_ENABLED=false — процесс pos-worker завершается без запуска обработчиков');
    log.flush();
    process.exit(0);
  }

  // Этап F (FQ-PAY-12, FQ-ORD-05; 06 §7.5, D-45 «тот же код с ролью воркера»): контекст Nest без HTTP с теми же
  // модулями, что pos-api. Из него pos-worker берёт реализации портов `CartReader` (восстановление корзины ORD-027),
  // `PaymentsPort` (аннулирование платежей при отказе 1С/отмене) и `NotificationsPort`; `PaymentsJobsBridge` при
  // `WORKERS_ENABLED=true` регистрирует обработчики `payments.qr_onec_poll|qr_expire|onec-qr-status`; обработчики
  // `cart` (`catalog.prices-changed|stock-changed`, `cart.parked_expire`) регистрируются ниже (`registerCartJobs`).
  let nest: INestApplicationContext;
  try {
    nest = await NestFactory.createApplicationContext(AppModule.forRoot(config), {
      logger: new PinoNestLogger(log.child({ component: 'nest' })),
      abortOnError: false,
    });
  } catch (err) {
    log.error({ err }, 'worker.nest_context_failed: модули этапа F не подняты');
    log.flush();
    process.exit(1);
  }
  const cartReader = nest.get<CartReader>(CART_READER);
  const paymentsPort = nest.get<PaymentsPort>(PAYMENTS_PORT);
  const notificationsPort = nest.get<NotificationsPort>(NOTIFICATIONS_PORT);
  const cartJobs = nest.get(CartJobsHandler, { strict: false });

  const pool = createPool(config, 'pos-worker', (info) => log.warn(info, 'pg.pool.idle_client_error'));
  // SMS-контур (RM-D-002): `sms.send`, DR-опрос и баланс SMSPro — обработчики pg-boss этого процесса.
  // Очередь OTP-SMS (INT-01; 09 §6.8): итог `sms.send` → владелец OTP (`failed_delivery`, возврат квоты номера).
  const sms = new SmsRuntime({
    config,
    pool,
    logger: pinoSmsLogger(log.child({ component: 'sms' })),
    listener: createOtpDeliveryListener({ config, pool }),
  });
  // Синхронизация с 1С (RM-E-002): обработчики сущностей каталога, `onec.changes`, сверка `$count`, алерты.
  const schedulerConfig = schedulerConfigFromEnv(config);
  const sync = createSyncWorkerWiring({ config, pool, log, scheduler: schedulerConfig });
  // Заказы (RM-F-002): канал записи outbox → 1С, результаты `orders.onec-*`, сверщик, статусы `order_status`.
  const orders = createOrdersWorkerWiring({
    config,
    pool,
    log,
    ...(sync.gateway ? { gateway: sync.gateway } : {}),
    cart: cartReader,
    payments: paymentsPort,
    notifications: notificationsPort,
  });
  const cartLog = log.child({ component: 'cart' });
  const runtime = new WorkerRuntime({
    // RM-G-005: прогон `return_docs` — опрос статусов заявок на возврат, переданных в 1С (ONEC-067).
    handlers: {
      ...sync.handlers,
      ...orders.handlers,
      return_docs: nest.get(ReturnsStatusSyncHandler, { strict: false }),
    },
    jobs: { ...sync.jobs, ...orders.jobs },
    onRunFinished: sync.onRunFinished,
    ...(orders.outboxDelivery ? { outboxDelivery: orders.outboxDelivery } : {}),
    outboxHooks: orders.outboxHooks,
    extraWorkers: [
      // 05 SYNC-070: публикатор изменений цен/остатков для корзин получает pg-boss процесса (ревью F-trace-3).
      (boss) => {
        sync.catalogChanges.attach(boss);
        return Promise.resolve();
      },
      // Задачи `payments.onec-qr-status` / `orders.onec-status-changed` из транзакции сообщения `/changes` (ядро §22.8).
      (boss) => sync.changeJobs.attach(boss),
      (boss) => sms.register(boss),
      (boss) => orders.register(boss),
      (boss) =>
        registerCartJobs(boss, cartJobs, {
          pollingIntervalSeconds: 2, // money-double: allow — секунды
          log: { warn: (o, m) => cartLog.warn(o, m), info: (o, m) => cartLog.info(o, m) },
        }),
    ],
    enabled: true,
    connectionString: config.DATABASE_URL,
    pool,
    settings: new SettingsReader(pool),
    scheduler: schedulerConfig,
    log,
  });

  let stopping = false;
  const shutdown = async (signal: string): Promise<void> => {
    if (stopping) return;
    stopping = true;
    log.info({ signal }, 'worker.shutdown');
    await runtime.stop();
    await nest.close().catch(() => undefined);
    await pool.end().catch(() => undefined);
    log.flush();
    process.exit(0);
  };
  process.once('SIGTERM', () => void shutdown('SIGTERM'));
  process.once('SIGINT', () => void shutdown('SIGINT'));

  // БД может быть недоступна при старте (compose: depends_on + healthcheck) — повторяем, не падая.
  for (;;) {
    try {
      await runtime.start();
      return;
    } catch (err) {
      if (stopping) return;
      log.error({ err }, 'worker.start_failed: повтор');
      await runtime.stop().catch(() => undefined);
      await new Promise((r) => setTimeout(r, START_RETRY_MS));
    }
  }
}

await bootstrap();
