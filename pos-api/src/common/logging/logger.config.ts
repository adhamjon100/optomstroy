import type { IncomingMessage, ServerResponse } from 'node:http';
import type { DestinationStream, LoggerOptions } from 'pino';
import { stdTimeFunctions } from 'pino';
import type { Options as PinoHttpOptions } from 'pino-http';
import type { AppConfig } from '../config/app-config.js';
import { newId } from '../ids/uuid.js';
import { ipPrefix, REDACTED, sanitizeLogValue, sanitizeString } from './redaction.js';

export type ServiceRole = 'pos-api' | 'pos-worker';

/**
 * Базовые опции pino (RM-C-010, NFR-LOG-001, 11 SEC-061…SEC-063): JSON в stdout, ISO-время, `level` строкой,
 * redaction объекта записи до сериализации и маскирование строковых аргументов сообщения.
 * Используются и API (через nestjs-pino), и worker (RM-C-007 — `pino(buildPinoOptions(config, 'pos-worker'))`).
 */
export function buildPinoOptions(
  config: Pick<AppConfig, 'LOG_LEVEL' | 'APP_ENV'>,
  service: ServiceRole,
): LoggerOptions {
  return {
    level: config.LOG_LEVEL,
    base: { service, env: config.APP_ENV },
    messageKey: 'msg',
    timestamp: stdTimeFunctions.isoTime,
    formatters: {
      level: (label) => ({ level: label }),
      log: (obj) => sanitizeLogValue(obj) as Record<string, unknown>,
    },
    hooks: {
      logMethod(args, method) {
        // Маскирование до записи (SEC-063): pino берёт msg из err.message до formatters.log, поэтому объекты
        // очищаются уже здесь; formatters.log — второй слой для bindings дочерних логгеров.
        const safe = args.map((a) =>
          typeof a === 'string' ? sanitizeString(a) : typeof a === 'object' && a !== null ? sanitizeLogValue(a) : a,
        ) as Parameters<typeof method>;
        method.apply(this, safe);
      },
    },
    // Второй слой (на случай логирования заголовков в обход сериализаторов).
    redact: {
      paths: [
        'req.headers.authorization',
        'req.headers.cookie',
        'req.headers["x-step-up-token"]',
        'res.headers["set-cookie"]',
        'headers.authorization',
        'headers.cookie',
      ],
      censor: REDACTED,
    },
  };
}

type Req = IncomingMessage & { id?: string; originalUrl?: string };

/** Опции pino-http: requestId = req.id (request-id.middleware.ts), тела и заголовки запросов не логируются (SEC-061). */
export function buildPinoHttpOptions(
  config: Pick<AppConfig, 'LOG_LEVEL' | 'APP_ENV'>,
  stream?: DestinationStream,
): PinoHttpOptions {
  return {
    ...buildPinoOptions(config, 'pos-api'),
    ...(stream ? { stream } : {}),
    genReqId: (req: IncomingMessage) => (req as Req).id ?? newId(),
    customAttributeKeys: { reqId: 'requestId' },
    // requestId привязывается к каждой записи в рамках запроса (child-логгер pino-http → nestjs-pino).
    quietReqLogger: true,
    serializers: {
      req: (req: Req & { raw?: Req; remoteAddress?: string }) => ({
        method: req.method,
        url: sanitizeString(safeDecode(String(req.raw?.originalUrl ?? req.url ?? ''))),
        ipPrefix: ipPrefix(req.remoteAddress ?? req.socket?.remoteAddress),
        appVersion: headerValue(req.headers?.['x-app-version']),
        platform: headerValue(req.headers?.['x-platform']),
      }),
      res: (res: { statusCode: number | null; raw?: ServerResponse }) => ({
        statusCode: res.raw?.statusCode ?? res.statusCode,
      }),
    },
    customLogLevel: (_req, res, err) =>
      err || res.statusCode >= 500 ? 'error' : res.statusCode >= 400 ? 'warn' : 'info',
    // Синтетическая ошибка pino-http «failed with status code 5xx» не несёт информации — уровень error и так выставлен.
    customErrorObject: (_req, _res, err, val: Record<string, unknown>) =>
      err instanceof Error && err.message.startsWith('failed with status code') ? { ...val, err: undefined } : val,
    customSuccessMessage: () => 'http.request',
    customErrorMessage: () => 'http.request',
    autoLogging: { ignore: (req) => (req.url ?? '') === '/health' },
  };
}

function safeDecode(url: string): string {
  try {
    return decodeURIComponent(url);
  } catch {
    return url;
  }
}

function headerValue(v: string | string[] | undefined): string | undefined {
  const s = Array.isArray(v) ? v[0] : v;
  return s === undefined ? undefined : sanitizeString(s).slice(0, 64);
}
