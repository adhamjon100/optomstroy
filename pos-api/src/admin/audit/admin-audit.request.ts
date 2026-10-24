import { isUuid } from '../../common/ids/uuid.js';
import type { AuditQuery } from '../../common/ports/index.js';
import { ProblemException, type ProblemFieldError } from '../../common/problem-details/problem.exception.js';
import { AUDIT_LIMIT_DEFAULT, AUDIT_LIMIT_MAX } from './audit-query.service.js';

export type AdminAuditQuery = AuditQuery & { readonly limit: number };

const RESULTS = ['ok', 'denied', 'error'] as const;

function one(v: unknown): string | undefined {
  if (Array.isArray(v)) return one(v[0]);
  return typeof v === 'string' && v !== '' ? v : undefined;
}

/**
 * Параметры `GET /admin/audit-logs` (08 §4.18.7; OpenAPI `admin_audit_logs_list`): `from`/`to` обязательны (UTC,
 * ISO-8601), `result` ∈ ok|denied|error, `limit` 1…200 (по умолчанию 50), `actorId` — UUID, `entityType`/`entityId`
 * ≤ 64, `action` ≤ 100 (префикс). Ошибки формата — `400 VALIDATION_FAILED` (все сразу); период > 366 дней или
 * `from > to` — `422 VALIDATION_FAILED` rule `date_range` (проверяет `AuditQueryService`). Неизвестные параметры
 * игнорируются (08 §2.6: фильтры вне перечня не влияют на выборку).
 */
export function parseAdminAuditQuery(q: Record<string, unknown>): AdminAuditQuery {
  const errors: ProblemFieldError[] = [];
  const date = (field: 'from' | 'to'): Date | undefined => {
    const s = one(q[field]);
    if (s === undefined) {
      errors.push({ field, rule: 'required', message: 'Параметр обязателен.' });
      return undefined;
    }
    const d = new Date(s);
    if (Number.isNaN(d.getTime()) || !/^\d{4}-\d{2}-\d{2}/.test(s)) {
      errors.push({ field, rule: 'date_time', message: 'Ожидается дата-время ISO-8601.' });
      return undefined;
    }
    return d;
  };
  const from = date('from');
  const to = date('to');
  const actorId = one(q.actorId);
  if (actorId !== undefined && !isUuid(actorId)) errors.push({ field: 'actorId', rule: 'uuid', message: 'UUID.' });
  const action = one(q.action);
  if (action !== undefined && action.length > 100) {
    errors.push({ field: 'action', rule: 'maxLength', message: 'Не длиннее 100 символов.' });
  }
  const entityType = one(q.entityType);
  if (entityType !== undefined && entityType.length > 64) {
    errors.push({ field: 'entityType', rule: 'maxLength', message: 'Не длиннее 64 символов.' });
  }
  const entityId = one(q.entityId);
  if (entityId !== undefined && entityId.length > 64) {
    errors.push({ field: 'entityId', rule: 'maxLength', message: 'Не длиннее 64 символов.' });
  }
  const result = one(q.result);
  if (result !== undefined && !(RESULTS as readonly string[]).includes(result)) {
    errors.push({ field: 'result', rule: 'enum', message: 'Допустимо: ok, denied, error.' });
  }
  const limitRaw = one(q.limit);
  const limit = limitRaw === undefined ? AUDIT_LIMIT_DEFAULT : Number(limitRaw);
  if (limitRaw !== undefined && (!/^\d{1,3}$/.test(limitRaw) || limit < 1 || limit > AUDIT_LIMIT_MAX)) {
    errors.push({ field: 'limit', rule: 'range', message: `Целое 1…${AUDIT_LIMIT_MAX}.` });
  }
  const cursor = one(q.cursor);
  if (errors.length > 0 || !from || !to) {
    throw new ProblemException('VALIDATION_FAILED', {
      status: 400,
      detail: 'Параметры журнала аудита не прошли проверку.',
      errors,
    });
  }
  return {
    from,
    to,
    limit,
    ...(actorId !== undefined ? { actorUserId: actorId.toLowerCase() } : {}),
    ...(action !== undefined ? { action } : {}),
    ...(entityType !== undefined ? { entityType } : {}),
    ...(entityId !== undefined ? { entityId } : {}),
    ...(result !== undefined ? { result: result as (typeof RESULTS)[number] } : {}),
    ...(cursor !== undefined ? { cursor } : {}),
  };
}
