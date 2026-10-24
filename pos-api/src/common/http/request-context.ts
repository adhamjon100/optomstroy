/**
 * Поля, которые common/* добавляет к запросу Express. `id` — requestId (pino-http использует то же поле),
 * `principal` — аутентифицированный субъект (заполняет common/auth-context, этап D; RM-C-005 — только чтение).
 */
export interface Principal {
  readonly userId: string;
  readonly kind: 'staff' | 'customer' | 'integration';
  /** Коды role_code (08 §2.2: в R1 одна активная роль, maxItems 1). */
  readonly roles: readonly string[];
  readonly status?: 'active' | 'pending_activation';
  readonly sessionId?: string;
  readonly deviceId?: string;
}

export interface RequestWithContext {
  id?: string;
  url?: string;
  headers: Record<string, string | string[] | undefined>;
  principal?: Principal;
  originalUrl?: string;
  route?: { path?: string };
  params?: Record<string, string>;
  body?: unknown;
  method?: string;
}

export function getRequestId(req: { id?: unknown } | undefined): string | undefined {
  return typeof req?.id === 'string' ? req.id : undefined;
}
