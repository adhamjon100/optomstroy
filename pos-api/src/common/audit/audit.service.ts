import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DRIZZLE } from '../db/database.module.js';
import { isUuid } from '../ids/uuid.js';
import {
  type AuditAction,
  isAuditAction,
  MIN_REASON_LENGTH,
  REASON_REQUIRED_ACTIONS,
  RESERVED_AUDIT_ACTIONS,
} from './audit-actions.js';
import { type AuditContext, normalizeIp, toRbacRole } from './audit-context.js';
import { sanitizeAuditPayload } from './audit-sanitize.js';
import type { DbExecutor } from './db-executor.js';

export type AuditResult = 'ok' | 'denied' | 'error';
export type AuditSeverity = 'info' | 'warning' | 'critical';
export type AuditStepUpMethod = 'pin' | 'biometric' | 'otp';

/** Событие аудита уровня приложения (11 §7.1; поля — 07 §5.57). */
export interface AuditEntry {
  readonly action: AuditAction;
  readonly entityType?: string | null;
  readonly entityId?: string | null;
  readonly onecRef?: string | null;
  /** Только изменённые поля; секреты удаляются, телефоны маскируются (audit-sanitize.ts). */
  readonly before?: Readonly<Record<string, unknown>> | null;
  readonly after?: Readonly<Record<string, unknown>> | null;
  readonly result?: AuditResult;
  /** Фактор, проверенный сервером (09 §8.8): `pin`/`bio+pin` → `pin`, `otp`/`bio+otp` → `otp`. */
  readonly stepUpMethod?: AuditStepUpMethod | null;
  readonly reason?: string | null;
  /** По умолчанию: `ok` → info, `denied`/`error` → warning. */
  readonly severity?: AuditSeverity;
}

export interface AuditWritten {
  readonly id: string;
  readonly seq: number;
  readonly chainSeq: number;
  readonly rowHash: Buffer;
}

/** Ошибка программиста при формировании записи (действие вне словаря, нет причины, неверный UUID…). */
export class AuditEntryError extends Error {
  override readonly name = 'AuditEntryError';
}

function uuidOrNull(v: string | null | undefined, field: string): string | null {
  if (v === null || v === undefined || v === '') return null;
  if (!isUuid(v)) throw new AuditEntryError(`audit: ${field} — не UUID`);
  return v.toLowerCase();
}

function short(v: string | null | undefined, max: number): string | null {
  if (v === null || v === undefined) return null;
  const t = v.trim();
  return t === '' ? null : t.slice(0, max);
}

/**
 * AuditService (07 §9.1 «уровень приложения», 11 SEC-073…SEC-080): append-only INSERT в `audit_logs` с
 * `level='app'`. Хэш-цепочку (`chain_seq`, `prev_hash`, `row_hash` = SHA-256(prev ‖ canonical)) вычисляет триггер
 * `trg_audit_logs_chain` под `pg_advisory_xact_lock` — приложение эти поля не задаёт и не может подделать.
 *
 * Правила вызова (07 §9.3, B-AR-08): запись — **последний** оператор бизнес-транзакции перед COMMIT (блокировка
 * цепочки держится до конца транзакции); транзакция — READ COMMITTED (иначе триггер бросает исключение); вызов вне
 * транзакции (`executor` по умолчанию — пул) допустим для событий чтения (`audit.viewed`, `customer.debt_viewed`).
 */
@Injectable()
export class AuditService {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async write(ctx: AuditContext, entry: AuditEntry, executor: DbExecutor = this.db): Promise<AuditWritten> {
    const action: string = entry.action;
    if (!isAuditAction(action)) throw new AuditEntryError(`audit: действие «${action}» вне словаря 11 §7.2`);
    if (RESERVED_AUDIT_ACTIONS.has(entry.action)) {
      throw new AuditEntryError(`audit: «${action}» зарезервировано в R1 (11 §7.2; D-22, D-23)`);
    }
    const actorUserId = uuidOrNull(ctx.actorUserId, 'actorUserId');
    const reason = short(entry.reason, 1000);
    if (actorUserId !== null && REASON_REQUIRED_ACTIONS.has(entry.action)) {
      if (reason === null || reason.length < MIN_REASON_LENGTH) {
        throw new AuditEntryError(`audit: для «${action}» нужна причина ≥ ${MIN_REASON_LENGTH} символов (11 SEC-076)`);
      }
    }
    const result: AuditResult = entry.result ?? 'ok';
    const severity: AuditSeverity = entry.severity ?? (result === 'ok' ? 'info' : 'warning');
    const before = sanitizeAuditPayload(entry.before);
    const after = sanitizeAuditPayload(entry.after);
    const res = await executor.execute<{ id: string; seq: string; chain_seq: string; row_hash: Buffer }>(sql`
      INSERT INTO audit_logs (
        level, actor_user_id, actor_role, on_behalf_of_user_id, session_id, device_id, ip, app_version,
        client_platform, request_id, action, entity_type, entity_id, onec_ref, before, after, result,
        step_up_method, reason, severity)
      VALUES (
        'app', ${actorUserId}::uuid, ${toRbacRole(ctx.actorRole)}::role_code,
        ${uuidOrNull(ctx.onBehalfOfUserId, 'onBehalfOfUserId')}::uuid, ${uuidOrNull(ctx.sessionId, 'sessionId')}::uuid,
        ${uuidOrNull(ctx.deviceId, 'deviceId')}::uuid, ${normalizeIp(ctx.ip)}::inet, ${short(ctx.appVersion, 64)},
        ${short(ctx.clientPlatform, 32)}, ${short(ctx.requestId, 128)}, ${action},
        ${short(entry.entityType, 64)}, ${uuidOrNull(entry.entityId, 'entityId')}::uuid,
        ${uuidOrNull(entry.onecRef, 'onecRef')}::uuid,
        ${before === null ? null : JSON.stringify(before)}::jsonb, ${after === null ? null : JSON.stringify(after)}::jsonb,
        ${result}, ${entry.stepUpMethod ?? null}::step_up_method, ${reason}, ${severity})
      RETURNING id, seq, chain_seq, row_hash`);
    const row = res.rows[0];
    if (!row) throw new Error('audit: INSERT не вернул строку');
    return { id: row.id, seq: Number(row.seq), chainSeq: Number(row.chain_seq), rowHash: row.row_hash };
  }
}
