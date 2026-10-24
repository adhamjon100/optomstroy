import { createHash } from 'node:crypto';
import type { INestApplication } from '@nestjs/common';
import { DocumentBuilder, type OpenAPIObject, SwaggerModule } from '@nestjs/swagger';
import { API_PREFIX } from '../common/http/route-template.js';

/**
 * Генерируемая копия контракта (D-03; 08 §4.19.2). Источник истины — contracts/openapi/pos-api.v1.yaml;
 * сверка — `openapi-diff contracts/openapi/pos-api.v1.yaml http://localhost:3000/openapi.json` (RM-C-005 п. 5,
 * CI RM-C-011). Пути — относительно сервера `/api/v1`, как в контракте.
 */
export const OPENAPI_TAGS = [
  'auth',
  'registration',
  'me',
  'catalog',
  'search',
  'inventory',
  'cart',
  'orders',
  'payments',
  'pos',
  'customers',
  'receivables',
  'discounts',
  'favorites',
  'transactions',
  'returns',
  'notifications',
  'sync',
  'admin',
  'health',
] as const;

export interface OpenApiDocumentHolder {
  readonly document: OpenAPIObject;
  readonly json: string;
  readonly etag: string;
}

export const OPENAPI_DOCUMENT = Symbol('OPENAPI_DOCUMENT');

/**
 * info.version экспорта = info.version контракта (contracts/openapi/parts/00_root.yaml; CHANGELOG, ADR-097).
 * Константа, а не чтение yaml в рантайме: образ pos-api не содержит contracts/. Расхождение ловят
 * src/health/openapi.document.spec.ts и smoke.e2e-spec.ts (ревью E: RC-3, RS-11).
 */
export const OPENAPI_INFO_VERSION = '1.2.0';

export function buildOpenApiDocument(app: INestApplication): OpenApiDocumentHolder {
  const builder = new DocumentBuilder()
    .setTitle('Optomstroy POS API')
    .setVersion(OPENAPI_INFO_VERSION)
    .setOpenAPIVersion('3.0.3')
    .setDescription(
      'REST/JSON API pos-api (NestJS). Генерируемая копия; источник истины — contracts/openapi/pos-api.v1.yaml.',
    )
    .addServer(API_PREFIX, 'текущий сервер')
    .addBearerAuth({ type: 'http', scheme: 'bearer', bearerFormat: 'JWT' }, 'bearerAuth')
    .addSecurityRequirements('bearerAuth');
  for (const tag of OPENAPI_TAGS) builder.addTag(tag);
  const document = SwaggerModule.createDocument(app, builder.build(), { ignoreGlobalPrefix: true });
  const json = JSON.stringify(document);
  const etag = `"${createHash('sha256').update(json).digest('hex').slice(0, 32)}"`;
  return { document, json, etag };
}
