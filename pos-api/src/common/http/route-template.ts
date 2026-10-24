/** Глобальный префикс REST API (08 §2.1: https://<host>/api/v1). `/health*` и `/openapi.json` — вне префикса. */
export const API_PREFIX = '/api/v1';

/**
 * Нормализованный шаблон маршрута для сравнения с путями OpenAPI: префикс `/api/v1` снимается,
 * параметры `:id` (Express) и `{id}` (OpenAPI) приводятся к `{}` — имена параметров не важны.
 */
export function normalizeRouteTemplate(path: string): string {
  let p = path.trim();
  if (p.startsWith(API_PREFIX + '/') || p === API_PREFIX) p = p.slice(API_PREFIX.length) || '/';
  p = p.replace(/:[A-Za-z0-9_]+/g, '{}').replace(/\{[^}]*\}/g, '{}');
  if (p.length > 1) p = p.replace(/\/+$/, '');
  return p.startsWith('/') ? p : `/${p}`;
}

export function routeKey(method: string, path: string): string {
  return `${method.toUpperCase()} ${normalizeRouteTemplate(path)}`;
}

/** Шаблон маршрута текущего запроса (Express `req.route.path` + baseUrl) или фактический путь, если маршрут не найден. */
export function requestRouteTemplate(req: {
  route?: { path?: unknown };
  baseUrl?: string;
  originalUrl?: string;
  url?: string;
}): string {
  const routePath = typeof req.route?.path === 'string' ? req.route.path : undefined;
  if (routePath !== undefined) return `${req.baseUrl ?? ''}${routePath}`;
  const raw = req.originalUrl ?? req.url ?? '/';
  return raw.split('?')[0] ?? '/';
}

export const MUTATING_METHODS: ReadonlySet<string> = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);
