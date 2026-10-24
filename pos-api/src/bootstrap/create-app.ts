import type { INestApplication } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { Logger } from 'nestjs-pino';
import { AppModule, type AppModuleOptions } from '../app.module.js';
import type { AppConfig } from '../common/config/app-config.js';
import { securityHeadersMiddleware } from '../common/http/security-headers.middleware.js';
import { requestIdMiddleware } from '../common/logging/request-id.middleware.js';
import { buildOpenApiDocument, OPENAPI_DOCUMENT, type OpenApiDocumentHolder } from '../health/openapi.document.js';

/** Внутренний порт pos-api (ядро R0 §16 п. 1): наружу — только через pos-proxy. */
export const API_PORT = 3000;
/** Предел тела JSON (08 §2.1: ≤ 1 MB → 413). */
export const JSON_BODY_LIMIT = '1mb';
/** Пути вне префикса `/api/v1` (pos-proxy: `handle /health*`; healthcheck compose — `http://localhost:3000/health`). */
export const PREFIX_EXCLUDED_PATHS = ['health', 'health/ready', 'openapi.json', 'api/v1/openapi.json'];

/**
 * HTTP-настройка приложения (общая для main.ts и тестов): requestId и заголовки безопасности до любых
 * обработчиков, pino-логгер, тело JSON ≤ 1 MB, префикс `/api/v1` (кроме `/health*`, `/openapi.json`).
 */
export function configureHttpApp(app: NestExpressApplication): void {
  app.useLogger(app.get(Logger));
  app.disable('x-powered-by');
  app.set('trust proxy', 'loopback, uniquelocal');
  app.use(requestIdMiddleware);
  app.use(securityHeadersMiddleware);
  app.useBodyParser('json', { limit: JSON_BODY_LIMIT });
  app.setGlobalPrefix('api/v1', { exclude: PREFIX_EXCLUDED_PATHS });
}

export async function createApp(config: AppConfig, options: AppModuleOptions = {}): Promise<INestApplication> {
  const app = await NestFactory.create<NestExpressApplication>(AppModule.forRoot(config, options), {
    bufferLogs: true,
    bodyParser: false,
  });
  configureHttpApp(app);
  app.enableShutdownHooks();
  await app.init();
  const holder = app.get<{ current?: OpenApiDocumentHolder }>(OPENAPI_DOCUMENT);
  holder.current = buildOpenApiDocument(app);
  return app;
}
