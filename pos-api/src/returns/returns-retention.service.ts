import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { applyAuditGucs, systemActor } from '../common/audit/audit-context.js';
import { AuditService } from '../common/audit/audit.service.js';
import { DRIZZLE, type Database } from '../common/db/database.module.js';

/** Срок хранения черновика заявки на возврат (07 §5.45, §13.3: `return_requests (draft) | 7 дней | DELETE`; Q-141). */
export const RETURN_DRAFT_TTL_DAYS = 7;

/**
 * Обработчик модуля `returns` в задаче сроков хранения `retention.daily` (06 §7.5, MOD-024; 07 §5.45, §13.3; 11
 * PRIV-016; ревью G-trace-10): черновики заявок старше 7 дней удаляются физически вместе со строками — забытый
 * черновик больше не резервирует остаток к возврату (триггер `return_request_items_guard` считает `draft`).
 * Исполнение журналируется событием аудита `retention.executed` (таблица, число строк).
 */
@Injectable()
export class ReturnsRetentionService {
  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    private readonly audit: AuditService,
  ) {}

  async purgeExpiredDrafts(): Promise<{ deleted: number }> {
    return this.db.transaction(async (tx) => {
      const ctx = systemActor('retention');
      await applyAuditGucs(tx, ctx);
      const due = await tx.execute<{ id: string }>(sql`
        SELECT id FROM return_requests
         WHERE status = 'draft' AND created_at < now() - make_interval(days => ${RETURN_DRAFT_TTL_DAYS})
         ORDER BY created_at
         FOR UPDATE SKIP LOCKED`);
      const ids = due.rows.map((r) => r.id);
      if (ids.length === 0) return { deleted: 0 };
      await tx.execute(sql`DELETE FROM return_request_items WHERE return_request_id = ANY(${sql.param(ids)}::uuid[])`);
      const del = await tx.execute(
        sql`DELETE FROM return_requests WHERE id = ANY(${sql.param(ids)}::uuid[]) AND status = 'draft'`,
      );
      const deleted = del.rowCount ?? 0;
      await this.audit.write(
        ctx,
        {
          action: 'retention.executed',
          entityType: 'return_requests',
          after: { table: 'return_requests', status: 'draft', olderThanDays: RETURN_DRAFT_TTL_DAYS, rows: deleted },
        },
        tx,
      );
      return { deleted };
    });
  }
}
