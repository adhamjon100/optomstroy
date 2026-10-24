import { type AppConfig, ConfigError } from '../../common/config/app-config.js';
import { type FakeSmsDb, FakeSmsGateway } from './fake-sms.gateway.js';
import type { SmsGateway } from './sms-gateway.js';
import type { SmsHttpTransport } from './sms-http-transport.js';
import type { SmsLogger, SmsTelemetry } from './sms-telemetry.js';
import { type SmsProConfig, SmsProXmlGateway } from './smspro-xml.gateway.js';

export type SmsGatewayConfig = Pick<AppConfig, 'APP_ENV' | 'SMS_PROVIDER'> & SmsProConfig;

export interface SmsGatewayDeps {
  /** Пул БД (`dev_outbox`) — нужен только `fake`. */
  readonly db?: FakeSmsDb;
  readonly logger?: SmsLogger;
  /** Метрики/алерты процесса (один набор на процесс). */
  readonly telemetry?: SmsTelemetry;
  /** HTTP-транспорт SMSPro (тесты — агент с CA локального стенда). */
  readonly transport?: SmsHttpTransport;
  readonly now?: () => number;
}

/**
 * Выбор реализации `SmsGateway` по `SMS_PROVIDER` (09 §6.8). Второй рубеж после env.schema.ts (OPS-027):
 * `fake` — только `APP_ENV ∈ {dev, staging}`. Не задан: в `dev` — `fake` (16 §4.3: «тест — fake»),
 * в `staging`/`prod` — отказ (значение по умолчанию в 16 §4.3 не задано: «—»).
 */
export function createSmsGateway(config: SmsGatewayConfig, deps: SmsGatewayDeps = {}): SmsGateway {
  const provider = config.SMS_PROVIDER ?? (config.APP_ENV === 'dev' ? 'fake' : undefined);
  if (provider === undefined) {
    throw new ConfigError([`SMS_PROVIDER: обязателен при APP_ENV=${config.APP_ENV} (smspro | fake)`]);
  }
  if (provider === 'fake') {
    if (config.APP_ENV === 'prod') {
      throw new ConfigError(['SMS_PROVIDER: fake запрещён при APP_ENV=prod (OPS-027)']);
    }
    if (!deps.db) throw new Error('FakeSmsGateway: нужен пул БД (таблица dev_outbox)');
    return new FakeSmsGateway(deps.db, {
      appEnv: config.APP_ENV,
      logger: deps.logger ?? deps.telemetry?.logger,
      ...(deps.now ? { now: deps.now } : {}),
    });
  }
  return new SmsProXmlGateway(config, {
    ...(deps.transport ? { transport: deps.transport } : {}),
    ...(deps.telemetry ? { telemetry: deps.telemetry } : {}),
    ...(deps.now ? { now: deps.now } : {}),
  });
}
