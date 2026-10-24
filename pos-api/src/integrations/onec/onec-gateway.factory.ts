import { type AppConfig, ConfigError } from '../../common/config/app-config.js';
import { FakeOnecGateway, type FakeOnecGatewayOptions } from './fake-onec.gateway.js';
import type { OnecGateway } from './onec-gateway.js';

export type OnecGatewayConfig = Pick<AppConfig, 'APP_ENV' | 'ONEC_MODE' | 'ONEC_ODATA_WRITE_ENABLED'>;

/** Боевые реализации порта (RM-E-001): `onecAdapters(config)` из onec-adapters.ts — `OnecExtensionGateway`, `OnecODataGateway`. */
export interface OnecGatewayAdapters {
  readonly extension?: () => OnecGateway;
  readonly odataOnly?: () => OnecGateway;
  readonly fixtures?: FakeOnecGatewayOptions;
}

/**
 * Выбор реализации `OnecGateway` по `ONEC_MODE` (05 ONEC-023). Второй рубеж после env.schema.ts (OPS-027):
 * `fixtures` при `APP_ENV=prod` — отказ, даже если конфигурация собрана в обход схемы; `ONEC_ODATA_WRITE_ENABLED=true`
 * допустим только при `ONEC_MODE=odata_only` (16 §4.3, 05 ONEC-028). Ошибка — `ConfigError` (main.ts → код выхода 1).
 */
export function createOnecGateway(config: OnecGatewayConfig, adapters: OnecGatewayAdapters = {}): OnecGateway {
  const problems: string[] = [];
  if (config.ONEC_MODE === 'fixtures' && config.APP_ENV === 'prod') {
    problems.push('ONEC_MODE: fixtures запрещён при APP_ENV=prod (OPS-027)');
  }
  if (config.ONEC_ODATA_WRITE_ENABLED && config.ONEC_MODE !== 'odata_only') {
    problems.push('ONEC_ODATA_WRITE_ENABLED: true допустимо только при ONEC_MODE=odata_only (05 ONEC-028)');
  }
  if (problems.length > 0) throw new ConfigError(problems);

  switch (config.ONEC_MODE) {
    case 'fixtures':
      return new FakeOnecGateway(adapters.fixtures);
    case 'extension':
      if (adapters.extension) return adapters.extension();
      throw new ConfigError(['ONEC_MODE: extension — адаптер OnecExtensionGateway ещё не подключён (RM-E-001)']);
    case 'odata_only':
      if (adapters.odataOnly) return adapters.odataOnly();
      throw new ConfigError(['ONEC_MODE: odata_only — адаптер OnecODataGateway ещё не подключён (RM-E-001)']);
  }
}
