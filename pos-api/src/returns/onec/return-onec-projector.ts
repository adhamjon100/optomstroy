import { sql } from 'drizzle-orm';
import { applyAuditGucs, systemActor } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import type { ReturnRequestStatus } from '../../common/enums.js';
import type { NotificationsPort } from '../../common/ports/index.js';
import { onecProjectionPath } from '../domain/return-status.js';
import { type ReturnRow, ReturnsRepository } from '../returns.repository.js';

export interface ProjectorLog {
  warn(obj: Record<string, unknown>, msg: string): void;
}

/** Реквизиты заявки в 1С (ответ `POST /pos/v1/returns` / `GET …/status`, контракт `ReturnRequestState`). */
export interface OnecReturnState {
  readonly ref?: string | null;
  readonly number?: string | null;
  /** Спроецированный расширением статус (ONEC-067). */
  readonly status: 'submitted' | 'accepted' | 'rejected' | 'completed';
  /** Исходное значение статуса 1С (`onecStatus`) — в `return_requests.onec_status_raw`. */
  readonly onecStatus?: string | null;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const TITLE: Readonly<Partial<Record<ReturnRequestStatus, (n: string) => string>>> = {
  accepted: (n) => `Заявка на возврат ${n} согласована в 1С`,
  rejected: (n) => `Заявка на возврат ${n} отклонена в 1С`,
  completed: (n) => `Возврат по заявке ${n} оформлен в 1С`,
};

/**
 * Проекция статуса заявки из 1С (05 §6.4, ONEC-067; автомат — ядро §22.11, `domain/return-status.ts`): ответ
 * `POST /pos/v1/returns` (событие `returns.onec-confirmed`), опрос `GET /pos/v1/returns/{uuid}/status` и проведённый
 * «Возврат товаров от клиента» (`return_docs`). Переходы назад не выполняются; автор заявки получает уведомление
 * `return_status` (10 RET-007); аудит `return.status_changed` — системный (актора нет).
 */
export class ReturnOnecProjector {
  private readonly repo = new ReturnsRepository();

  constructor(
    private readonly notifications: NotificationsPort | null,
    private readonly log: ProjectorLog,
  ) {}

  /** Применить состояние 1С к заблокированной строке; возвращает выполненные шаги автомата. */
  async apply(
    tx: DbExecutor,
    r: ReturnRow,
    s: OnecReturnState,
    source: 'onec_response' | 'onec_status' | 'return_docs',
  ): Promise<ReturnRequestStatus[]> {
    await applyAuditGucs(tx, systemActor('sync'));
    const ref = s.ref && UUID_RE.test(s.ref) ? s.ref : null;
    if (ref !== null || s.number || s.onecStatus !== undefined) {
      await tx.execute(sql`
        UPDATE return_requests
           SET onec_ref = coalesce(onec_ref, ${ref}::uuid), onec_number = coalesce(${s.number ?? null}, onec_number),
               onec_status_raw = coalesce(${s.onecStatus ?? null}, onec_status_raw),
               onec_date = coalesce(onec_date, now()), row_version = row_version + 1, updated_at = now()
         WHERE id = ${r.id}::uuid`);
    }
    const path = onecProjectionPath(r.status, s.status);
    let from = r.status;
    const done: ReturnRequestStatus[] = [];
    for (const to of path) {
      if (!(await this.repo.transition(tx, r.id, from, to, null))) break;
      done.push(to);
      from = to;
    }
    if (path.length === 0 && s.status !== 'submitted' && s.status !== r.status) {
      // Переход назад/вне автомата (например, `completed → accepted`): не выполняется (05 §6.4) — только журнал.
      this.log.warn(
        { returnRequestId: r.id, current: r.status, onec: s.status, source },
        'returns.onec_status_ignored: переход вне автомата ядра §22.11',
      );
    }
    if (done.length > 0) {
      const title = TITLE[from]?.(r.public_number);
      if (title && this.notifications) {
        await this.notifications.notify(tx, {
          userId: r.created_by_user_id,
          kind: 'return_status',
          severity: from === 'rejected' ? 'warning' : 'info',
          title,
          body: title,
          payload: { returnRequestId: r.id, status: from },
          dedupeKey: `return_status:${r.id}:${from}`,
        });
      }
      // Аудит — последним оператором (хэш-цепочка, 07 §9.3).
      await new AuditService(tx).write(
        systemActor('sync'),
        {
          action: 'return.status_changed',
          entityType: 'return_request',
          entityId: r.id,
          onecRef: ref ?? r.onec_ref,
          before: { status: r.status },
          after: { status: from, via: source, onecStatus: s.onecStatus ?? null, publicNumber: r.public_number },
        },
        tx,
      );
    }
    return done;
  }
}
