import type { AuditResult, RoleCode, StepUpMethod } from '../enums.js';
import type { SalesActor, SalesTx } from './sales-context.js';

/**
 * `AuditQueryPort` (этап G, RM-G-006; 06 §7.4: чтение аудита — модуль `admin`, запись — только `AuditService` и
 * триггеры БД) — чтение `audit_logs` с проверкой хэш-цепочки (D-36, ядро §19.2 `AuditRow.chainOk`) для
 * межмодульных вызовов: `GET /transactions/{id}` (записи аудита по объекту для `audit.read`, 08 §4.14.2, TXN-003) и
 * отчётов. Маскирование финансовых значений `before/after` для `admin` (`"***"`; `owner` видит полностью —
 * 08 `AuditRow`, API-118/134) выполняет реализация по `viewer`.
 *
 * Реализация — агент G-be-admin-reports (`pos-api/src/admin/audit/**`, `bindSalesPort`; проверка цепочки —
 * `AuditAnchorService.verifyChain` / SQL `audit_verify_chain`). Заглушка — `InMemoryAuditQuery`
 * (`test/support/cashier-ports.fakes.ts`).
 */
export const AUDIT_QUERY_PORT = 'sales.AuditQueryPort' as const;

export interface AuditQuery {
  /** Период по `occurred_at` (включительно `from`, исключительно `to`); не более 366 дней (ядро §19.4). */
  readonly from: Date;
  readonly to: Date;
  readonly actorUserId?: string;
  /** Точное имя (`order.created`) или префикс с `.*` (`return.*`). */
  readonly action?: string;
  readonly entityType?: string;
  readonly entityId?: string;
  readonly result?: AuditResult;
  /** Непрозрачный курсор предыдущей страницы. */
  readonly cursor?: string | null;
  /** 1…200 (по умолчанию 50). */
  readonly limit?: number;
}

export interface AuditRowView {
  readonly id: string;
  readonly chainSeq: string;
  readonly occurredAt: Date;
  readonly requestId: string | null;
  readonly actorUserId: string | null;
  readonly actorName: string | null;
  readonly actorRole: RoleCode | null;
  readonly sessionId: string | null;
  readonly deviceId: string | null;
  readonly ip: string | null;
  readonly appVersion: string | null;
  readonly action: string;
  readonly entityType: string | null;
  readonly entityId: string | null;
  readonly onecRef: string | null;
  /** Уже маскированные для `viewer` значения. */
  readonly before: Readonly<Record<string, unknown>> | null;
  readonly after: Readonly<Record<string, unknown>> | null;
  readonly result: AuditResult;
  readonly stepUpMethod: StepUpMethod | null;
  readonly reason: string | null;
  /** `row_hash` hex. */
  readonly rowHash: string;
  /** Цепочка `prev_hash → row_hash` у этой строки сходится (D-36). */
  readonly chainOk: boolean;
}

export interface AuditPage {
  readonly items: readonly AuditRowView[];
  readonly nextCursor: string | null;
  readonly hasMore: boolean;
}

export interface AuditQueryPort {
  /** `GET /admin/audit-logs`: фильтры, курсор, порядок — новые сверху. */
  list(tx: SalesTx | null, viewer: SalesActor, query: AuditQuery): Promise<AuditPage>;

  /** Записи по объекту (`entity_type`, `entity_id`) — для деталей транзакции (TXN-003); новые сверху. */
  forEntity(
    tx: SalesTx | null,
    viewer: SalesActor,
    entityType: string,
    entityId: string,
    limit?: number,
  ): Promise<readonly AuditRowView[]>;

  /** Проверка цепочки на отрезке `chain_seq` (без границ — вся): `brokenAtChainSeq` — первая расходящаяся строка. */
  verifyChain(
    tx: SalesTx | null,
    range?: { readonly fromChainSeq?: string; readonly toChainSeq?: string },
  ): Promise<{ readonly ok: boolean; readonly brokenAtChainSeq: string | null; readonly gaps: number }>;
}
