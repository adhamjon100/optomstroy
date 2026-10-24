import { isIP } from 'node:net';
import { sql } from 'drizzle-orm';
import type { RequestWithContext } from '../http/request-context.js';
import { isUuid } from '../ids/uuid.js';
import { RBAC_ROLES, type RbacRole } from '../rbac/permissions.generated.js';
import type { DbExecutor } from './db-executor.js';

/**
 * Контекст записи аудита (11 §7.1, SEC-077): кто, откуда, в каком запросе. Заполняется из запроса
 * (`auditContextFromRequest`) или воркером (`systemActor`). `deviceId` — `X-Device-Id` (UUID устройства клиента).
 */
export interface AuditContext {
  readonly requestId?: string | null;
  readonly actorUserId?: string | null;
  readonly actorRole?: RbacRole | null;
  readonly onBehalfOfUserId?: string | null;
  readonly sessionId?: string | null;
  readonly deviceId?: string | null;
  readonly ip?: string | null;
  readonly appVersion?: string | null;
  readonly clientPlatform?: string | null;
  /** Системный процесс (`SET LOCAL app.system`, 07 §9.1): `sync`, `outbox`, `retention`, `auth`… */
  readonly system?: string | null;
}

function header(req: RequestWithContext, name: string): string | undefined {
  const v = req.headers[name];
  const s = Array.isArray(v) ? v[0] : v;
  return typeof s === 'string' && s.trim() !== '' ? s.trim().slice(0, 64) : undefined;
}

export function toRbacRole(v: string | undefined | null): RbacRole | null {
  return v !== undefined && v !== null && (RBAC_ROLES as readonly string[]).includes(v) ? (v as RbacRole) : null;
}

/** Нормализованный IP (IPv4-mapped IPv6 → IPv4) или null. */
export function normalizeIp(ip: string | undefined | null): string | null {
  if (!ip) return null;
  const v = ip.startsWith('::ffff:') && isIP(ip.slice(7)) === 4 ? ip.slice(7) : ip;
  return isIP(v) ? v : null;
}

/**
 * Контекст из HTTP-запроса: `requestId`, субъект (`req.principal`), `X-Device-Id`, `X-App-Version`, `X-Platform`,
 * IP клиента (`req.ip` Express с учётом `trust proxy`). Полный IP — только в `audit_logs.ip` (SEC-063).
 */
export function auditContextFromRequest(req: RequestWithContext & { ip?: string }): AuditContext {
  const p = req.principal;
  const deviceHeader = header(req, 'x-device-id');
  const deviceId = p?.deviceId ?? (isUuid(deviceHeader) ? deviceHeader : undefined);
  return {
    requestId: typeof req.id === 'string' ? req.id : null,
    actorUserId: p?.userId ?? null,
    actorRole: toRbacRole(p?.roles[0]),
    sessionId: p?.sessionId ?? null,
    deviceId: deviceId ?? null,
    ip: normalizeIp(req.ip),
    appVersion: header(req, 'x-app-version') ?? null,
    clientPlatform: header(req, 'x-platform') ?? null,
  };
}

/** Контекст системного процесса (воркер, планировщик): актор отсутствует, `app.system` задан. */
export function systemActor(system: string, requestId?: string): AuditContext {
  return { system, requestId: requestId ?? null };
}

/**
 * `SET LOCAL app.*` для триггеров аудита уровня БД (07 §9.1; 11 SEC-074): вызывается первым оператором
 * бизнес-транзакции. Вне транзакции не имеет эффекта (set_config(..., true) действует до конца транзакции).
 */
export async function applyAuditGucs(tx: DbExecutor, ctx: AuditContext): Promise<void> {
  const v = (s: string | null | undefined) => s ?? '';
  await tx.execute(sql`SELECT
      set_config('app.actor_id', ${v(ctx.actorUserId)}, true),
      set_config('app.actor_role', ${v(ctx.actorRole)}, true),
      set_config('app.session_id', ${v(ctx.sessionId)}, true),
      set_config('app.device_id', ${v(ctx.deviceId)}, true),
      set_config('app.request_id', ${v(ctx.requestId)}, true),
      set_config('app.ip', ${v(normalizeIp(ctx.ip))}, true),
      set_config('app.system', ${v(ctx.system)}, true)`);
}
