import { type AppConfig, ConfigError } from '../../common/config/app-config.js';
import type { OnecGatewayAdapters } from './onec-gateway.factory.js';
import { OnecExtensionGateway } from './onec-extension.gateway.js';
import { NodeOnecTransport, type OnecHttpTransport } from './onec-http-transport.js';
import { OnecODataClient } from './onec-odata.client.js';
import { OnecODataGateway } from './onec-odata.gateway.js';

export type OnecAdaptersConfig = Pick<
  AppConfig,
  | 'APP_ENV'
  | 'ONEC_BASE_URL'
  | 'ONEC_HS_PATH'
  | 'ONEC_ODATA_PATH'
  | 'ONEC_USER'
  | 'ONEC_PASSWORD'
  | 'ONEC_HS_USER'
  | 'ONEC_HS_PASSWORD'
  | 'ONEC_HS_TOKEN'
  | 'ONEC_CA_CERT'
  | 'ONEC_TIMEOUT_MS'
  | 'ONEC_SYNC_CHECK_TIMEOUT_MS'
  | 'ONEC_SYNC_PAGE_SIZE'
  | 'ONEC_MAX_CONCURRENCY'
>;

/** Транспорт 1С по конфигурации: `ONEC_CA_CERT_FILE`, `ONEC_MAX_CONCURRENCY`; `http://` — только `APP_ENV=dev`. */
export function createOnecTransport(c: OnecAdaptersConfig): NodeOnecTransport {
  return new NodeOnecTransport({
    ...(c.ONEC_CA_CERT ? { caCert: c.ONEC_CA_CERT } : {}),
    allowInsecureHttp: c.APP_ENV === 'dev',
    maxSockets: c.ONEC_MAX_CONCURRENCY,
  });
}

/** `OnecODataClient` фазы 0 (пользователь `pos_integration`, только чтение). */
export function createOnecODataClient(c: OnecAdaptersConfig, transport: OnecHttpTransport): OnecODataClient {
  if (!c.ONEC_BASE_URL) throw new ConfigError(['ONEC_BASE_URL: обязательна для OData 1С']);
  return new OnecODataClient(
    {
      baseUrl: c.ONEC_BASE_URL,
      odataPath: c.ONEC_ODATA_PATH,
      ...(c.ONEC_USER !== undefined ? { user: c.ONEC_USER } : {}),
      ...(c.ONEC_PASSWORD !== undefined ? { password: c.ONEC_PASSWORD } : {}),
      timeoutMs: c.ONEC_TIMEOUT_MS,
      pageSize: c.ONEC_SYNC_PAGE_SIZE,
    },
    transport,
  );
}

/**
 * Боевые адаптеры порта `OnecGateway` для `createOnecGateway` (RM-E-001): `extension` — HTTP-сервис расширения
 * (`ONEC_BASE_URL` + `ONEC_HS_PATH`, секреты `ONEC_HS_*_FILE`), `odataOnly` — стандартный OData. Недостающие
 * обязательные настройки — `ConfigError` при старте (main.ts → код выхода 1), а не при первом вызове.
 */
export function onecAdapters(c: OnecAdaptersConfig, transport?: OnecHttpTransport): OnecGatewayAdapters {
  const t = (): OnecHttpTransport => transport ?? createOnecTransport(c);
  return {
    extension: () => {
      const problems: string[] = [];
      if (!c.ONEC_BASE_URL) problems.push('ONEC_BASE_URL: обязательна при ONEC_MODE=extension');
      if (!c.ONEC_HS_PATH) problems.push('ONEC_HS_PATH: обязательна при ONEC_MODE=extension');
      if (c.ONEC_HS_USER === undefined)
        problems.push('ONEC_HS_USER: обязательна (ONEC_HS_USER_FILE) при ONEC_MODE=extension');
      if (c.ONEC_HS_TOKEN === undefined)
        problems.push('ONEC_HS_TOKEN: обязательна (ONEC_HS_TOKEN_FILE) — X-POS-Client-Key (ONEC-032)');
      if (problems.length > 0) throw new ConfigError(problems);
      return new OnecExtensionGateway(
        {
          baseUrl: c.ONEC_BASE_URL!,
          hsPath: c.ONEC_HS_PATH!,
          user: c.ONEC_HS_USER!,
          ...(c.ONEC_HS_PASSWORD !== undefined ? { password: c.ONEC_HS_PASSWORD } : {}),
          clientKey: c.ONEC_HS_TOKEN!,
          timeoutMs: c.ONEC_TIMEOUT_MS,
          syncCheckTimeoutMs: c.ONEC_SYNC_CHECK_TIMEOUT_MS,
        },
        t(),
      );
    },
    odataOnly: () => {
      if (c.ONEC_USER === undefined) {
        throw new ConfigError(['ONEC_USER: обязательна (ONEC_USER_FILE) при ONEC_MODE=odata_only']);
      }
      return new OnecODataGateway(createOnecODataClient(c, t()));
    },
  };
}
