import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import type { NotificationKind } from '../../common/enums.js';
import type { NotificationInput } from '../../common/ports/notifications.port.js';
import type { SalesTx } from '../../common/ports/sales-context.js';

/**
 * Доступ к `notifications` (07 §5.50; D-41). Только свои уведомления: каждый запрос чтения и отметки содержит
 * фильтр `user_id = :subject` в SQL (11 SEC-030 (а)); чужое уведомление неотличимо от несуществующего (404).
 * Истёкшие (`expires_at <= now()`) не показываются и не считаются в `unreadCount`.
 */
export interface NotificationRow {
  readonly id: string;
  readonly kind: NotificationKind;
  readonly severity: 'info' | 'warning' | 'error';
  readonly title: string;
  readonly body: string;
  readonly payload: Record<string, unknown>;
  readonly createdAt: string;
  readonly readAt: string | null;
}

export interface ListFilter {
  readonly unreadOnly: boolean;
  readonly kinds: readonly NotificationKind[];
  readonly since?: string;
  /** Keyset: строки «после» (`created_at`, `id`) в порядке убывания. */
  readonly after?: { readonly createdAt: string; readonly id: string };
  readonly limit: number; // money-double: allow — размер страницы, не деньги
}

type Row = Record<string, unknown>;

function parsePayload(v: unknown): Record<string, unknown> {
  if (v !== null && typeof v === 'object' && !Array.isArray(v)) return v as Record<string, unknown>;
  if (typeof v !== 'string') return {};
  try {
    const o: unknown = JSON.parse(v);
    return o !== null && typeof o === 'object' && !Array.isArray(o) ? (o as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

function toRow(r: Row): NotificationRow {
  return {
    id: String(r.id),
    kind: String(r.kind) as NotificationKind,
    severity: String(r.severity) as NotificationRow['severity'],
    title: String(r.title_ru),
    body: String(r.body_ru),
    payload: parsePayload(r.payload),
    createdAt: typeof r.created_at === 'string' ? r.created_at : '',
    readAt: typeof r.read_at === 'string' ? r.read_at : null,
  };
}

const NOT_EXPIRED = sql`(n.expires_at IS NULL OR n.expires_at > now())`;

@Injectable()
export class NotificationsRepository {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async list(userId: string, f: ListFilter): Promise<NotificationRow[]> {
    const conds = [sql`n.user_id = ${userId}::uuid`, NOT_EXPIRED];
    if (f.unreadOnly) conds.push(sql`n.read_at IS NULL`);
    if (f.kinds.length > 0) conds.push(sql`n.kind::text = ANY(${`{${f.kinds.join(',')}}`}::text[])`);
    if (f.since !== undefined) conds.push(sql`n.created_at > ${f.since}::timestamptz`);
    if (f.after) {
      conds.push(sql`(n.created_at, n.id) < (${f.after.createdAt}::timestamptz, ${f.after.id}::uuid)`);
    }
    const r = await this.db.execute<Row>(sql`
      SELECT n.id, n.kind::text AS kind, n.severity, n.title_ru, n.body_ru, n.payload::text AS payload,
             to_json(n.created_at) #>> '{}' AS created_at, to_json(n.read_at) #>> '{}' AS read_at
        FROM notifications n
       WHERE ${sql.join(conds, sql` AND `)}
       ORDER BY n.created_at DESC, n.id DESC
       LIMIT ${f.limit + 1}`);
    return r.rows.map(toRow);
  }

  async unreadCount(userId: string): Promise<number> {
    const r = await this.db.execute<Row>(sql`
      SELECT count(*)::int AS c FROM notifications n
       WHERE n.user_id = ${userId}::uuid AND n.read_at IS NULL AND ${NOT_EXPIRED}`);
    return Number(r.rows[0]?.c ?? 0); // money-double: allow — счётчик уведомлений, не деньги
  }

  /** Отметка прочтения своего уведомления; повтор не меняет `read_at`. `false` — нет такого своего уведомления. */
  async markRead(userId: string, id: string): Promise<boolean> {
    const r = await this.db.execute<Row>(sql`
      WITH upd AS (
        UPDATE notifications SET read_at = now(), updated_at = now()
         WHERE id = ${id}::uuid AND user_id = ${userId}::uuid AND read_at IS NULL
        RETURNING id)
      SELECT EXISTS (SELECT 1 FROM upd) OR EXISTS (
               SELECT 1 FROM notifications WHERE id = ${id}::uuid AND user_id = ${userId}::uuid) AS found`);
    return r.rows[0]?.found === true;
  }

  /** Отметка всех своих непрочитанных; `before` — только созданные не позже момента (`created_at <= before`). */
  async markAllRead(userId: string, before?: string): Promise<number> {
    const r = await this.db.execute(sql`
      UPDATE notifications SET read_at = now(), updated_at = now()
       WHERE user_id = ${userId}::uuid AND read_at IS NULL
         AND (${before ?? null}::timestamptz IS NULL OR created_at <= ${before ?? null}::timestamptz)`);
    return r.rowCount ?? 0; // money-double: allow — число строк, не деньги
  }

  /** Вставка с дедупликацией `UNIQUE (user_id, dedupe_key)`; при дубле возвращается существующий id. */
  async insert(tx: SalesTx | null, n: NotificationInput): Promise<{ id: string; created: boolean }> {
    const ex = tx ?? this.db;
    const ins = await ex.execute<Row>(sql`
      INSERT INTO notifications (user_id, kind, severity, title_ru, body_ru, payload, dedupe_key, expires_at)
      VALUES (${n.userId}::uuid, ${n.kind}::notification_kind, ${n.severity}, ${n.title}, ${n.body},
              ${JSON.stringify(n.payload ?? {})}::jsonb, ${n.dedupeKey}, ${n.expiresAt?.toISOString() ?? null}::timestamptz)
      ON CONFLICT (user_id, dedupe_key) DO NOTHING
      RETURNING id`);
    const created = ins.rows[0];
    if (created) return { id: String(created.id), created: true };
    const cur = await ex.execute<Row>(sql`
      SELECT id FROM notifications WHERE user_id = ${n.userId}::uuid AND dedupe_key = ${n.dedupeKey}`);
    return { id: String(cur.rows[0]?.id), created: false };
  }

  /** Всем активным пользователям роли (действующая `user_roles`); возвращает id уведомлений (новые и существующие). */
  async insertForRole(tx: SalesTx | null, role: string, n: Omit<NotificationInput, 'userId'>): Promise<string[]> {
    const ex = tx ?? this.db;
    await ex.execute(sql`
      INSERT INTO notifications (user_id, kind, severity, title_ru, body_ru, payload, dedupe_key, expires_at)
      SELECT DISTINCT u.id, ${n.kind}::notification_kind, ${n.severity}, ${n.title}, ${n.body},
             ${JSON.stringify(n.payload ?? {})}::jsonb, ${n.dedupeKey}, ${n.expiresAt?.toISOString() ?? null}::timestamptz
        FROM users u
        JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL
        JOIN roles r ON r.id = ur.role_id AND r.code::text = ${role}
       WHERE u.status = 'active' AND u.deleted_at IS NULL
      ON CONFLICT (user_id, dedupe_key) DO NOTHING`);
    const r = await ex.execute<Row>(sql`
      SELECT n.id FROM notifications n
        JOIN user_roles ur ON ur.user_id = n.user_id AND ur.revoked_at IS NULL
        JOIN roles r ON r.id = ur.role_id AND r.code::text = ${role}
        JOIN users u ON u.id = n.user_id AND u.status = 'active' AND u.deleted_at IS NULL
       WHERE n.dedupe_key = ${n.dedupeKey}
       ORDER BY n.id`);
    return [...new Set(r.rows.map((x) => String(x.id)))];
  }
}
