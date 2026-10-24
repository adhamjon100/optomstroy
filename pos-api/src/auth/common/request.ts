import { normalizeIp } from '../../common/audit/audit-context.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';

/** Запрос Express с полями common/* (requestId, principal) и IP с учётом `trust proxy`. */
export type AuthHttpRequest = RequestWithContext & { ip?: string; path?: string };

const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

function single(v: string | string[] | undefined): string | undefined {
  if (Array.isArray(v)) return v.length === 1 ? v[0] : undefined;
  return v;
}

/**
 * `X-Device-Id` (08 §2.2, API-052; ядро §18.2 п. 3) — UUID v4 клиента = `devices.device_key` (CHECK 07 §5.8).
 * Нет / не UUID v4 → 400 VALIDATION_FAILED (`rule=uuid`). Возвращает значение в нижнем регистре.
 */
export function requireDeviceKey(req: AuthHttpRequest): string {
  const raw = single(req.headers['x-device-id'])?.trim().toLowerCase();
  if (raw === undefined || !UUID_V4.test(raw)) {
    throw new ProblemException('VALIDATION_FAILED', {
      status: 400,
      detail: 'Заголовок X-Device-Id обязателен (UUID устройства).',
      errors: [{ field: 'X-Device-Id', message: 'Ожидается UUID v4 устройства', rule: 'uuid' }],
    });
  }
  return raw;
}

export function isDeviceKey(v: unknown): v is string {
  return typeof v === 'string' && UUID_V4.test(v);
}

/** IP клиента (нормализованный; полный IP — только в `audit_logs.ip` и `otp_challenges.ip`, SEC-063). */
export function clientIp(req: AuthHttpRequest): string | null {
  return normalizeIp(req.ip);
}

export function requestIdOf(req: AuthHttpRequest): string | null {
  return typeof req.id === 'string' ? req.id : null;
}

export function headerValue(req: AuthHttpRequest, name: string): string | undefined {
  const v = single(req.headers[name.toLowerCase()]);
  return typeof v === 'string' && v.trim() !== '' ? v.trim() : undefined;
}

/** Путь запроса без глобального префикса `/api/v1` (для правил ограниченной сессии). */
export function routePath(req: AuthHttpRequest): string {
  const raw = (req.originalUrl ?? req.url ?? req.path ?? '').split('?')[0] ?? '';
  return raw.replace(/^\/api\/v1(?=\/|$)/, '') || '/';
}

/** Маска IP для списка сессий (08 §3 `Session.ipLast`: `212.***.***.12`). */
export function maskIp(ip: string | null | undefined): string | undefined {
  if (!ip) return undefined;
  const v4 = /^(\d{1,3})\.\d{1,3}\.\d{1,3}\.(\d{1,3})$/.exec(ip);
  if (v4) return `${v4[1]}.***.***.${v4[2]}`;
  const parts = ip.split(':').filter((p) => p !== '');
  return parts.length > 0 ? `${parts[0]}:****` : undefined;
}
