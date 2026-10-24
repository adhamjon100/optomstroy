import type {
  OutboxAggregate,
  OutboxStatus,
  SyncEntity,
  SyncErrorCode,
  SyncMode,
  SyncRunStatus,
  SyncTrigger,
} from '../../common/enums.js';
import { iso } from './sync-api.common.js';

/** `SyncCounts` (OpenAPI): fetched, upserted, deleted, errors, sourceTotal — из `sync_runs.counts` (05 SYNC-037). */
export interface SyncCountsDto {
  fetched?: number;
  upserted?: number;
  deleted?: number;
  errors?: number;
  sourceTotal?: number; // money-double: allow — число записей ($count), не деньги
}

function nonNegInt(v: unknown): number | undefined {
  const n = typeof v === 'number' ? v : typeof v === 'string' && v.trim() !== '' ? Number(v) : NaN;
  return Number.isInteger(n) && n >= 0 ? n : undefined;
}

export function presentCounts(raw: unknown): SyncCountsDto {
  if (!raw || typeof raw !== 'object') return {};
  const c = raw as Record<string, unknown>;
  const out: SyncCountsDto = {};
  const fetched = nonNegInt(c.fetched);
  if (fetched !== undefined) out.fetched = fetched;
  const upserted =
    nonNegInt(c.upserted) ??
    (nonNegInt(c.inserted) !== undefined || nonNegInt(c.updated) !== undefined
      ? (nonNegInt(c.inserted) ?? 0) + (nonNegInt(c.updated) ?? 0)
      : undefined);
  if (upserted !== undefined) out.upserted = upserted;
  const deleted = nonNegInt(c.deleted) ?? nonNegInt(c.markedDeleted);
  if (deleted !== undefined) out.deleted = deleted;
  const errors = nonNegInt(c.errors);
  if (errors !== undefined) out.errors = errors;
  const sourceTotal = nonNegInt(c.sourceTotal);
  if (sourceTotal !== undefined) out.sourceTotal = sourceTotal;
  return out;
}

export interface SyncRunRow {
  id: string;
  cursor_ts: string;
  entity: SyncEntity;
  mode: SyncMode;
  trigger: SyncTrigger;
  status: SyncRunStatus;
  started_at: Date | null;
  finished_at: Date | null;
  counts: unknown;
  error_summary: string | null;
  triggered_by_user_id: string | null;
  triggered_by_name: string | null;
}

/** Колонки `SyncRunRow` (алиас таблицы `r`, профиль автора `up`). */
export const SYNC_RUN_COLUMNS = `r.id, r.entity::text AS entity, r.mode::text AS mode, r."trigger"::text AS trigger,
  r.status::text AS status, r.started_at, r.finished_at, r.counts, r.error_summary, r.triggered_by_user_id,
  COALESCE(up.display_name, up.full_name) AS triggered_by_name`;

export interface SyncRunDto {
  id: string;
  entity: SyncEntity;
  mode: SyncMode;
  trigger: SyncTrigger;
  status: SyncRunStatus;
  startedAt: string | null;
  finishedAt: string | null;
  triggeredBy: { id: string; displayName: string } | null;
  counts: SyncCountsDto;
  errorSummary: string | null;
}

export function presentRun(r: SyncRunRow): SyncRunDto {
  return {
    id: r.id,
    entity: r.entity,
    mode: r.mode,
    trigger: r.trigger,
    status: r.status,
    startedAt: iso(r.started_at),
    finishedAt: iso(r.finished_at),
    triggeredBy: r.triggered_by_user_id
      ? { id: r.triggered_by_user_id, displayName: r.triggered_by_name ?? 'Сотрудник' }
      : null,
    counts: presentCounts(r.counts),
    errorSummary: r.error_summary,
  };
}

export interface SyncErrorRow {
  id: string;
  cursor_ts: string;
  entity: SyncEntity;
  onec_ref: string | null;
  onec_code: string | null;
  error_code: SyncErrorCode;
  message: string;
  payload: Record<string, unknown> | null;
  resolved_at: Date | null;
}

export function presentError(r: SyncErrorRow): Record<string, unknown> {
  return {
    id: r.id,
    entity: r.entity,
    onecRef: r.onec_ref,
    onecCode: r.onec_code,
    errorCode: r.error_code,
    message: r.message,
    payload: r.payload,
    resolvedAt: iso(r.resolved_at),
  };
}

export interface OutboxRowDb {
  id: string;
  cursor_ts: string;
  aggregate_type: OutboxAggregate;
  aggregate_id: string;
  public_number: string | null;
  status: OutboxStatus;
  operation: 'create' | 'cancel';
  attempts: number;
  next_attempt_at: Date | null;
  last_error_code: SyncErrorCode | null;
  last_error: string | null;
  onec_ref: string | null;
  onec_response: Record<string, unknown> | null;
  created_at: Date;
  sent_at: Date | null;
}

/** Колонки `OutboxRowDb` (алиас `o`; номер документа — из таблицы агрегата). */
export const OUTBOX_COLUMNS = `o.id, o.aggregate_type::text AS aggregate_type, o.aggregate_id, o.status::text AS status,
  o.operation, o.attempts, o.next_attempt_at, o.last_error_code, o.last_error, o.onec_ref, o.onec_response,
  o.created_at, o.sent_at,
  CASE o.aggregate_type
    WHEN 'order' THEN (SELECT public_number FROM orders WHERE id = o.aggregate_id)
    WHEN 'payment' THEN (SELECT public_number FROM payments WHERE id = o.aggregate_id)
    WHEN 'return_request' THEN (SELECT public_number FROM return_requests WHERE id = o.aggregate_id)
  END AS public_number`;

export function presentOutbox(r: OutboxRowDb): Record<string, unknown> {
  const number = r.onec_response && typeof r.onec_response.number === 'string' ? r.onec_response.number : undefined;
  return {
    id: r.id,
    aggregateType: r.aggregate_type,
    aggregateId: r.aggregate_id,
    ...(r.public_number ? { publicNumber: r.public_number } : {}),
    status: r.status,
    attempts: Number(r.attempts),
    nextAttemptAt: iso(r.next_attempt_at),
    lastErrorCode: r.last_error_code,
    lastError: r.last_error,
    onecResponse: r.onec_ref ? { ref: r.onec_ref, ...(number ? { number } : {}) } : null,
    createdAt: r.created_at.toISOString(),
    sentAt: iso(r.sent_at),
    operation: r.operation,
  };
}
