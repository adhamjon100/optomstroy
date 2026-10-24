import type { ReceivableDocumentKind, ReceivableDocumentStatus } from '../enums.js';
import type { MoneyString, SalesActor, SalesTx } from './sales-context.js';

/**
 * `ReceivablesSnapshotPort` (этап G, RM-G-002, RM-G-011; 06 §7.4 `ReceivablesService`) — снимок долга клиента из 1С
 * (`receivables` + `receivable_documents`) с возрастом, прогноз открытых заказов и точечное синхронное обновление
 * снимка. Долг только из 1С: backend его **не вычисляет** (D-24, DEBT-001); fail-closed — снимок старше
 * `RECEIVABLES_MAX_AGE_MIN` (ключ `receivables.max_age_minutes`, по умолчанию 60 мин) или неполный
 * (`overdue_amount IS NULL`) непригоден для решения о продаже в долг (PAY-031 шаг 3).
 *
 * Реализация — агент G-be-credit (`pos-api/src/customers/receivables/**`, `bindSalesPort`). Потребители:
 * `CreditDecisionService` (G-be-credit), дашборд кассира `/pos/dashboard` и `/receivables/overdue`
 * (G-be-txn-returns / G-be-credit), отчёт `/admin/reports/receivables` (G-be-admin-reports), свой долг клиента
 * (RM-G-014). Заглушка — `test/support/cashier-ports.fakes.ts` (`InMemoryReceivablesSnapshots`).
 */
export const RECEIVABLES_SNAPSHOT_PORT = 'sales.ReceivablesSnapshotPort' as const;

/**
 * Допуск расхождения часов 1С и backend для метки снимка `onec_snapshot_at` (ревью G-credit-2; 10 DEBT-006, D-24
 * fail-closed): метка позже момента ответа больше чем на допуск отклоняется разбором ответа 1С, а уже записанный
 * снимок «из будущего» непригоден для решения о долге (`isStale`) и перезаписывается следующим обновлением.
 */
export const RECEIVABLES_CLOCK_SKEW_MS = 5 * 60_000;

export interface ReceivablesSnapshotView {
  readonly customerId: string;
  /** Сальдо 1С (`+` долг, `−` аванс). */
  readonly balance: MoneyString;
  /** `null` — просрочка неизвестна (снимок неполон, DEBT-012). */
  readonly overdueAmount: MoneyString | null;
  readonly overdueDays: number | null;
  /** `YYYY-MM-DD` или `null`. */
  readonly oldestDueDate: string | null;
  /** `receivables.onec_snapshot_at` — метка времени 1С (`asOf`). */
  readonly snapshotAt: Date;
  /** Минут с `snapshotAt` до `now` (целое, вниз). */
  readonly ageMinutes: number;
  /** `ageMinutes > maxAgeMinutes` (DEBT-006: пометка «данные могут быть неактуальны»). */
  readonly isStale: boolean;
  /** Снимок пригоден для решения о долге: свежий и полный (`!isStale && overdueAmount !== null`). */
  readonly usableForCredit: boolean;
  readonly maxAgeMinutes: number;
}

export interface ReceivableDocumentView {
  readonly onecRef: string;
  readonly docType: string;
  readonly kind: ReceivableDocumentKind;
  readonly status: ReceivableDocumentStatus;
  readonly number: string;
  /** `YYYY-MM-DD`. */
  readonly date: string;
  readonly amount: MoneyString;
  readonly paid: MoneyString;
  readonly remaining: MoneyString;
  readonly dueDate: string | null;
  readonly overdueDays: number | null;
  readonly orderId: string | null;
}

/** Исход точечного обновления (`POST /customers/{id}/receivables/refresh`, PAY-031 шаг 3). */
export type ReceivablesRefreshOutcome =
  | { readonly kind: 'refreshed'; readonly snapshot: ReceivablesSnapshotView }
  /** 1С недоступна (таймаут, сеть, 5xx) или режим C-2: прежний снимок сохранён (DEBT-006). */
  | { readonly kind: 'unavailable'; readonly snapshot: ReceivablesSnapshotView | null; readonly reason: string }
  /** Клиент не идентифицирован в 1С (`onec_ref IS NULL`, `source=pos` до подтверждения) — `reason=not_in_onec`. */
  | { readonly kind: 'not_in_onec' };

export interface ReceivablesSnapshotPort {
  /** `RECEIVABLES_MAX_AGE_MIN` (`app_settings.receivables.max_age_minutes`, иначе env). */
  maxAgeMinutes(): Promise<number>;

  /** Текущий снимок; `null` — снимка нет («Нет данных из 1С», DEBT-009). */
  snapshot(tx: SalesTx | null, customerId: string, now?: Date): Promise<ReceivablesSnapshotView | null>;

  /** Строки детализации текущего снимка (`superseded_at IS NULL`), по сроку оплаты. */
  documents(tx: SalesTx | null, customerId: string): Promise<readonly ReceivableDocumentView[]>;

  /**
   * Прогноз открытых заказов клиента в долг, ещё не отражённых в снимке (DEBT-011: Σ `total` заказов `credit` в
   * `pending_approval`/`approved`/`awaiting_shipment` без полной оплаты).
   */
  openOrdersAmount(tx: SalesTx | null, customerId: string): Promise<MoneyString>;

  /**
   * Синхронное обновление снимка из 1С (`OnecGateway.getCustomerReceivables`, таймаут
   * `ONEC_SYNC_CHECK_TIMEOUT_MS`). Вне транзакции вызывающего (запись снимка — своя транзакция, 07 §8). Аудит и
   * rate-limit — у HTTP-обработчика; `actor` — для журнала. Исключений для недоступности 1С не бросает.
   */
  refresh(
    customerId: string,
    opts?: { readonly actor?: SalesActor; readonly timeoutMs?: number },
  ): Promise<ReceivablesRefreshOutcome>;
}
