import { timingSafeEqual } from 'node:crypto';
import { Inject, Injectable } from '@nestjs/common';
import { type SQL, sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { OtpHmacService } from '../../common/crypto/otp-hmac.service.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import type { AuditResult, RoleCode, StepUpMethod } from '../../common/enums.js';
import { isUuid } from '../../common/ids/uuid.js';
import type {
  AuditPage,
  AuditQuery,
  AuditQueryPort,
  AuditRowView,
  SalesActor,
  SalesTx,
} from '../../common/ports/index.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { maskAuditPayload } from './audit-masking.js';

/** Период выборки журналов — не более 366 дней (ядро §19.4, §20.2 п. 15; 08 §4.18.7). */
export const AUDIT_MAX_RANGE_MS = 366 * 86_400_000;
export const AUDIT_LIMIT_DEFAULT = 50;
export const AUDIT_LIMIT_MAX = 200;
const MAC_HEX_LENGTH = 32;
const ACTION_FILTER = /^[a-z_]+(\.[a-z_]+)*(\.|\.\*)?$/;

interface AuditDbRow extends Record<string, unknown> {
  id: string;
  chain_seq: string;
  occurred_at: Date | string;
  request_id: string | null;
  actor_user_id: string | null;
  actor_name: string | null;
  actor_role: RoleCode | null;
  session_id: string | null;
  device_id: string | null;
  ip: string | null;
  app_version: string | null;
  action: string;
  entity_type: string | null;
  entity_id: string | null;
  onec_ref: string | null;
  before: Record<string, unknown> | null;
  after: Record<string, unknown> | null;
  result: AuditResult;
  step_up_method: StepUpMethod | null;
  reason: string | null;
  row_hash: string;
  chain_ok: boolean;
}

/** `VALIDATION_FAILED` фильтра аудита: 400 — формат, 422 — период (контракт `admin_audit_logs_list`). */
function invalid(field: string, rule: string, message: string, status: 400 | 422 = 400): ProblemException {
  return new ProblemException('VALIDATION_FAILED', {
    status,
    detail: 'Параметры журнала аудита не прошли проверку.',
    errors: [{ field, rule, message }],
  });
}

/**
 * Условие по имени события (08 §4.18.7: «префикс имени события», пример `payment.`; порт: `return.*`): `x.` и `x.*`
 * — все события с префиксом `x.`; иначе — точное имя или его подпространство (`payment` → `payment`, `payment.*`).
 */
function actionCondition(action: string): SQL {
  const escape = (s: string) => s.replace(/[\\%_]/g, (c) => `\\${c}`);
  if (action.endsWith('.*')) return sql`a.action LIKE ${`${escape(action.slice(0, -1))}%`}`;
  if (action.endsWith('.')) return sql`a.action LIKE ${`${escape(action)}%`}`;
  return sql`(a.action = ${action} OR a.action LIKE ${`${escape(action)}.%`})`;
}

/**
 * Чтение журнала аудита — реализация `AuditQueryPort` (этап G, RM-G-006; 06 §7.4: чтение аудита — модуль `admin`,
 * запись — только `AuditService` и триггеры БД). Для каждой строки вычисляется `chainOk` (D-36, ядро §19.2):
 * `prev_hash` равен `row_hash` предыдущей существующей строки цепочки (пропуски `chain_seq` после откатов — норма,
 * 07 §9.3) и `row_hash = SHA-256(prev_hash ‖ audit_canon(строка))` — то же правило, что `audit_verify_chain`.
 * `before/after` маскируются для зрителя (`audit-masking.ts`). Порядок — новые сверху (`chain_seq DESC`, 07 §9.6
 * «курсор по seq DESC»); курсор — непрозрачный, подписан HMAC (подделка → 400 `cursor`).
 */
@Injectable()
export class AuditQueryService implements AuditQueryPort {
  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    private readonly hmac: OtpHmacService,
  ) {}

  async list(tx: SalesTx | null, viewer: SalesActor, query: AuditQuery): Promise<AuditPage> {
    const ex = tx ?? this.db;
    const limit = query.limit ?? AUDIT_LIMIT_DEFAULT;
    if (!Number.isInteger(limit) || limit < 1 || limit > AUDIT_LIMIT_MAX) {
      throw invalid('limit', 'range', `Целое 1…${AUDIT_LIMIT_MAX}.`);
    }
    if (Number.isNaN(query.from.getTime()) || Number.isNaN(query.to.getTime())) {
      throw invalid('from', 'date_time', 'Ожидается дата-время ISO-8601.');
    }
    if (query.from > query.to || query.to.getTime() - query.from.getTime() > AUDIT_MAX_RANGE_MS) {
      throw invalid('from', 'date_range', 'Период: from ≤ to, не более 366 дней.', 422);
    }
    const conds: SQL[] = [
      sql`a.occurred_at >= ${query.from.toISOString()}::timestamptz`,
      sql`a.occurred_at < ${query.to.toISOString()}::timestamptz`,
    ];
    if (query.actorUserId !== undefined) {
      if (!isUuid(query.actorUserId)) throw invalid('actorId', 'uuid', 'Ожидается UUID.');
      conds.push(sql`a.actor_user_id = ${query.actorUserId.toLowerCase()}::uuid`);
    }
    if (query.action !== undefined) {
      if (query.action.length > 100 || !ACTION_FILTER.test(query.action)) {
        throw invalid('action', 'pattern', 'Имя или префикс события: латиница, «_» и «.».');
      }
      conds.push(actionCondition(query.action));
    }
    if (query.entityType !== undefined) conds.push(sql`a.entity_type = ${query.entityType}`);
    if (query.entityId !== undefined) {
      // `audit_logs.entity_id` — uuid: иной идентификатор ни с одной строкой не совпадает.
      if (!isUuid(query.entityId)) return { items: [], nextCursor: null, hasMore: false };
      conds.push(sql`a.entity_id = ${query.entityId.toLowerCase()}::uuid`);
    }
    if (query.result !== undefined) conds.push(sql`a.result = ${query.result}`);
    const after = this.decodeCursor(query.cursor ?? null);
    if (after !== null) conds.push(sql`a.chain_seq < ${after}::bigint`);
    const rows = await this.select(ex, sql.join(conds, sql.raw(' AND ')), limit + 1);
    const hasMore = rows.length > limit;
    const page = rows.slice(0, limit);
    const last = page.at(-1);
    return {
      items: page.map((r) => this.view(viewer, r)),
      nextCursor: hasMore && last ? this.encodeCursor(last.chain_seq) : null,
      hasMore,
    };
  }

  async forEntity(
    tx: SalesTx | null,
    viewer: SalesActor,
    entityType: string,
    entityId: string,
    limit = 20,
  ): Promise<readonly AuditRowView[]> {
    if (!isUuid(entityId)) return [];
    const n = Math.min(Math.max(Math.trunc(limit), 1), AUDIT_LIMIT_MAX);
    const rows = await this.select(
      tx ?? this.db,
      sql`a.entity_type = ${entityType} AND a.entity_id = ${entityId.toLowerCase()}::uuid`,
      n,
    );
    return rows.map((r) => this.view(viewer, r));
  }

  async verifyChain(
    tx: SalesTx | null,
    range: { readonly fromChainSeq?: string; readonly toChainSeq?: string } = {},
  ): Promise<{ readonly ok: boolean; readonly brokenAtChainSeq: string | null; readonly gaps: number }> {
    const bound = (v: string | undefined, field: string): string | null => {
      if (v === undefined) return null;
      if (!/^\d{1,19}$/.test(v)) throw invalid(field, 'integer', 'Номер строки цепочки — целое ≥ 0.');
      return v;
    };
    const from = bound(range.fromChainSeq, 'fromChainSeq');
    const to = bound(range.toChainSeq, 'toChainSeq');
    const res = await (tx ?? this.db).execute<{ ok: boolean; broken: string | null; gaps: number }>(sql`
      SELECT v.ok, v.broken_at_chain_seq::text AS broken, v.gaps FROM audit_verify_chain(
        coalesce(${from}::bigint, (SELECT coalesce(min(chain_seq), 0) FROM audit_logs)),
        coalesce(${to}::bigint, (SELECT coalesce(max(chain_seq), 0) FROM audit_logs))) v`);
    const r = res.rows[0];
    return { ok: r?.ok ?? true, brokenAtChainSeq: r?.broken ?? null, gaps: Number(r?.gaps ?? 0) };
  }

  private async select(ex: DbExecutor, where: SQL, limit: number): Promise<AuditDbRow[]> {
    const res = await ex.execute<AuditDbRow>(sql`
      SELECT a.id, a.chain_seq::text AS chain_seq, a.occurred_at, a.request_id, a.actor_user_id,
             coalesce(p.display_name, p.full_name) AS actor_name, a.actor_role::text AS actor_role,
             a.session_id, a.device_id, host(a.ip) AS ip, a.app_version, a.action, a.entity_type, a.entity_id,
             a.onec_ref, a.before, a.after, a.result, a.step_up_method::text AS step_up_method, a.reason,
             encode(a.row_hash, 'hex') AS row_hash,
             (a.prev_hash IS NOT DISTINCT FROM coalesce(
                (SELECT pr.row_hash FROM audit_logs pr WHERE pr.chain_seq < a.chain_seq
                  ORDER BY pr.chain_seq DESC LIMIT 1), decode(repeat('00', 32), 'hex'))
              AND a.row_hash = digest(a.prev_hash || convert_to(audit_canon(a), 'UTF8'), 'sha256')) AS chain_ok
        FROM audit_logs a LEFT JOIN user_profiles p ON p.user_id = a.actor_user_id
       WHERE ${where}
       ORDER BY a.chain_seq DESC
       LIMIT ${limit}`);
    return res.rows;
  }

  private view(viewer: SalesActor, r: AuditDbRow): AuditRowView {
    return {
      id: r.id,
      chainSeq: r.chain_seq,
      occurredAt: new Date(r.occurred_at),
      requestId: r.request_id,
      actorUserId: r.actor_user_id,
      actorName: r.actor_name,
      actorRole: r.actor_role,
      sessionId: r.session_id,
      deviceId: r.device_id,
      ip: r.ip,
      appVersion: r.app_version,
      action: r.action,
      entityType: r.entity_type,
      entityId: r.entity_id,
      onecRef: r.onec_ref,
      before: maskAuditPayload(viewer, r.action, r.before),
      after: maskAuditPayload(viewer, r.action, r.after),
      result: r.result,
      stepUpMethod: r.step_up_method,
      reason: r.reason,
      rowHash: r.row_hash,
      chainOk: r.chain_ok === true,
    };
  }

  // Курсор (08 §2.5, непрозрачный): `base64url("<chain_seq>") "." HMAC`; подделка → 400 `cursor`.
  private encodeCursor(chainSeq: string): string {
    const body = Buffer.from(chainSeq, 'utf8').toString('base64url');
    return `${body}.${this.mac(body)}`;
  }

  private decodeCursor(raw: string | null): string | null {
    if (raw === null || raw === '') return null;
    const fail = () => invalid('cursor', 'cursor', 'Курсор недействителен — запросите список заново.');
    const [body, mac, ...rest] = raw.split('.');
    if (!body || !mac || rest.length > 0 || mac.length !== MAC_HEX_LENGTH) throw fail();
    if (!timingSafeEqual(Buffer.from(this.mac(body), 'utf8'), Buffer.from(mac, 'utf8'))) throw fail();
    const seq = Buffer.from(body, 'base64url').toString('utf8');
    if (!/^\d{1,19}$/.test(seq)) throw fail();
    return seq;
  }

  private mac(body: string): string {
    return this.hmac.pseudonym('cursor:audit', body).slice(0, MAC_HEX_LENGTH);
  }
}
