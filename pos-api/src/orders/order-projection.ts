import { sql } from 'drizzle-orm';
import type { OnecSyncState, OrderStatus, PaymentMethod, StatusChangeSource } from '../common/enums.js';
import { transactionJournal } from '../common/journal/index.js';
import { Money } from '../common/money/money.js';
import {
  type NotificationInput,
  type NotificationsPort,
  PortNotBoundError,
  type SalesTx,
} from '../common/ports/index.js';
import {
  type OnecOrderStatus,
  type OrderFacts,
  type OrderStatusChange,
  planOrderStatusChange,
} from '../sales-domain/order/order-status.js';
import { findOrder, findOrderOutbox, insertHistory, type OrderRow } from './order.repository.js';

/**
 * Перенос фактов документа 1С в заказ и проекция статуса D-20 (10 §2.2, ORD-033; 05 §5.1b ONEC-021; 07 §6.3; ядро
 * §23 п. 2). Общая процедура для ответа воркера outbox (`orders.onec-confirmed`/`-failed`), ручной привязки
 * (`onec-link`), синхронизации статусов (`sync.order_status`, `refreshFromOnec`) и приёма оплаты (`applyReceived`).
 * Сам статус решает чистая функция `planOrderStatusChange`; здесь — запись `orders`, `order_status_history`,
 * `transactions (order_cancelled)` и уведомление `order_status` автору заказа (D-41) в транзакции вызывающего.
 */

/** Сырые значения документа «Заказ клиента» из ответа 1С (`POST /pos/v1/orders`, `/orders/{uuid}/status`, пакет). */
export interface OnecOrderDocument {
  readonly ref: string | null;
  readonly number: string | null;
  readonly date: string | null;
  readonly status: string | null;
  readonly approved: boolean | null;
  readonly deletionMark: boolean;
  readonly total: string | null;
  /** Есть проведённая реализация (M4/M7). */
  readonly hasShipment: boolean;
}

/** Разбор тела ответа 1С (контракт `OrderCreateResponse` / `OrderStatus`). Неизвестные поля игнорируются (ONEC-058). */
export function parseOnecOrderDocument(body: unknown): OnecOrderDocument {
  const b = (typeof body === 'object' && body !== null ? body : {}) as Record<string, unknown>;
  const s = (v: unknown): string | null => (typeof v === 'string' && v.trim() !== '' ? v.trim() : null);
  const total = s(b.total) ?? s((b.totals as Record<string, unknown> | undefined)?.total);
  const shipments = Array.isArray(b.shipments) ? (b.shipments as Record<string, unknown>[]) : [];
  return {
    ref: s(b.ref),
    number: s(b.number),
    date: s(b.date),
    status: s(b.status),
    approved: typeof b.approved === 'boolean' ? b.approved : null,
    deletionMark: b.deletionMark === true,
    total: total && /^-?\d+(\.\d+)?$/.test(total) ? Money.of(total).toString() : null,
    hasShipment: shipments.some((x) => x && x.posted === true),
  };
}

/**
 * Нормализация `Статус` 1С (05 §5.1b M1–M5, M11): `null` — статус не передан; `'unrecognized'` — значение вне
 * таблицы (факты не меняются, `sync_errors`).
 */
export function normalizeOnecStatus(raw: string | null | undefined): OnecOrderStatus | null | 'unrecognized' {
  if (raw === null || raw === undefined || raw.trim() === '') return null;
  const v = raw.replace(/[\s_]/g, '').toLowerCase();
  if (v === 'несогласован' || v === 'насогласовании') return 'not_approved';
  if (v === 'квыполнению' || v === 'согласован') return 'to_execute';
  if (v === 'закрыт') return 'closed';
  return 'unrecognized';
}

/** Человекочитаемый статус для уведомлений `order_status` (title_ru/body_ru, 07 §5.50). */
export const ORDER_STATUS_TITLE_RU: Readonly<Record<OrderStatus, string>> = {
  draft: 'Черновик',
  submitting: 'Отправляется в 1С',
  submit_failed: 'Отклонён 1С',
  pending_approval: 'Ожидает согласования',
  awaiting_payment: 'Ожидает оплаты',
  approved: 'Согласован',
  awaiting_shipment: 'Ожидает отгрузки',
  shipped: 'Отгружен',
  partially_returned: 'Частичный возврат',
  closed: 'Закрыт',
  cancelled: 'Отменён',
};

export interface ApplyOrderFactsInput {
  readonly orderId: string;
  readonly source: StatusChangeSource;
  readonly actorUserId: string | null;
  /** Документ 1С (ответ/синхронизация/ручная привязка); `null` — факты 1С не меняются. */
  readonly onec?: OnecOrderDocument | null;
  /** Новое `onec_sync_state` (по умолчанию — прежнее с поправкой на CHECK 07 §6.5). */
  readonly syncState?: OnecSyncState;
  /** Отказ 1С при записи документа (outbox `failed`, ONEC_REJECTED) — P2/P3. */
  readonly rejected?: { readonly code: string; readonly message: string } | null;
  /** Ручная привязка `onec-link` (`onec_linked_by_user_id`, `onec_linked_at`). */
  readonly linkedByUserId?: string | null;
  /** Предварительные шаги истории (например, `submit_failed → submitting` при ручной привязке, ORD-027). */
  readonly preSteps?: readonly { readonly from: OrderStatus; readonly to: OrderStatus }[];
  readonly requestId?: string | null;
  readonly syncRunId?: string | null;
  readonly reason?: string | null;
  /** Заказ уже заблокирован вызывающим (`FOR UPDATE`). */
  readonly locked?: OrderRow;
}

export interface ApplyOrderFactsResult {
  readonly before: OrderRow;
  readonly from: OrderStatus;
  readonly to: OrderStatus;
  readonly change: OrderStatusChange | null;
  /** Значение `Статус` 1С вне таблицы M1–M5 (`sync_errors`, ORD-041). */
  readonly unrecognizedStatus: string | null;
  readonly becameCancelled: boolean;
}

export class OrderProjector {
  constructor(
    private readonly notifications: NotificationsPort | null,
    private readonly warn: (msg: string, data?: Record<string, unknown>) => void = () => undefined,
  ) {}

  async apply(tx: SalesTx, input: ApplyOrderFactsInput): Promise<ApplyOrderFactsResult> {
    const o = input.locked ?? (await findOrder(tx, input.orderId, true));
    if (!o) throw new Error(`orders: заказ ${input.orderId} не найден`);
    const doc = input.onec ?? null;
    const createOutbox = await findOrderOutbox(tx, o.id, 'create');

    const onecRef = o.onec_ref ?? doc?.ref ?? null;
    const rawStatus = doc?.status ?? o.onec_status_raw;
    const normalized = normalizeOnecStatus(rawStatus);
    const unrecognizedStatus = normalized === 'unrecognized' ? rawStatus : null;
    const onecStatus: OnecOrderStatus | null = normalized === 'unrecognized' ? null : normalized;
    const hasShipment = o.shipped_at !== null || doc?.hasShipment === true;
    const deletion = doc?.deletionMark === true;
    const rejected =
      (input.rejected !== undefined && input.rejected !== null) ||
      (createOutbox?.status === 'failed' && createOutbox.last_error_code === 'ONEC_REJECTED' && onecRef === null);

    // Предварительные шаги (ручная привязка заказа `submit_failed`): статус для проекции — после них.
    let current: OrderStatus = o.status;
    const preHistory = input.preSteps ?? [];
    if (preHistory.length > 0) current = preHistory[preHistory.length - 1].to;

    const facts: OrderFacts = {
      creating: false,
      cancelConfirmed: o.cancelled_at !== null || deletion,
      rejected,
      hasOnecRef: onecRef !== null,
      onecStatus,
      hasShipment,
      hasReturn: o.has_return,
      paymentMethod: o.payment_method,
      paidAtSet: o.paid_at !== null,
      hasReceivedMoney: Money.of(o.paid_amount).compare(Money.ZERO) > 0,
    };
    const change = planOrderStatusChange(current, facts, input.source);
    const to: OrderStatus = change?.to ?? current;
    const allSteps = [...preHistory.map((s) => ({ ...s, source: input.source })), ...(change?.history ?? [])];

    // onec_sync_state с учётом CHECK 07 §6.5 (`orders_onec_sync_status_chk`, `orders_onec_sync_ref_chk`).
    let syncState: OnecSyncState = input.syncState ?? o.onec_sync_state;
    if (to === 'submit_failed' || to === 'draft') syncState = 'unknown';
    else if (onecRef === null) {
      if (syncState === 'linked' || syncState === 'missing') syncState = 'pending';
      if (syncState === 'ambiguous' && to !== 'submitting') syncState = 'pending';
    } else if (syncState === 'unknown' || syncState === 'ambiguous') {
      // Документ 1С известен: `unknown`/`ambiguous` требуют `onec_ref IS NULL` (CHECK `orders_onec_sync_ref_chk`).
      syncState = 'pending';
    }
    if (syncState === 'unknown' && !['draft', 'submitting', 'submit_failed', 'cancelled'].includes(to)) {
      syncState = 'pending';
    }

    const becameCancelled = to === 'cancelled' && o.status !== 'cancelled';
    // Итог 1С впервые отличается от итога POS (`totals_differ` false → true; 10 DISC-006; 05 ONEC-039; 07 DATA-215).
    const onecTotalAfter = doc?.total ?? o.onec_total;
    const totalsDifferNow = onecTotalAfter !== null && Money.of(onecTotalAfter).compare(Money.of(o.total)) !== 0;
    const approvedNow = allSteps.some((s) => s.to === 'approved');
    await tx.execute(sql`
      UPDATE orders SET
        status = ${to}::order_status,
        onec_ref = COALESCE(onec_ref, ${doc?.ref ?? null}::uuid),
        onec_number = COALESCE(${doc?.number ?? null}, onec_number),
        onec_date = COALESCE(${doc?.date ?? null}::timestamptz, onec_date),
        onec_status_raw = COALESCE(${doc?.status ?? null}, onec_status_raw),
        onec_total = COALESCE(${doc?.total ?? null}::numeric, onec_total),
        onec_last_sync_at = CASE WHEN ${doc !== null}::boolean THEN now() ELSE onec_last_sync_at END,
        onec_sync_state = ${syncState}::onec_sync_state,
        onec_linked_by_user_id = COALESCE(${input.linkedByUserId ?? null}::uuid, onec_linked_by_user_id),
        onec_linked_at = CASE WHEN ${input.linkedByUserId ?? null}::uuid IS NOT NULL THEN now() ELSE onec_linked_at END,
        approved_at = CASE WHEN ${approvedNow}::boolean AND approved_at IS NULL THEN now() ELSE approved_at END,
        shipped_at = CASE WHEN ${hasShipment}::boolean AND shipped_at IS NULL THEN now() ELSE shipped_at END,
        closed_at = CASE WHEN ${to === 'closed'}::boolean AND closed_at IS NULL THEN now() ELSE closed_at END,
        cancelled_at = CASE WHEN ${to === 'cancelled' || deletion}::boolean AND cancelled_at IS NULL THEN now() ELSE cancelled_at END,
        submit_error_code = CASE WHEN ${input.rejected ? input.rejected.code : null}::text IS NOT NULL
                                 THEN ${input.rejected ? input.rejected.code : null}::text ELSE submit_error_code END,
        submit_error_message = CASE WHEN ${input.rejected ? input.rejected.message.slice(0, 500) : null}::text IS NOT NULL
                                 THEN ${input.rejected ? input.rejected.message.slice(0, 500) : null}::text
                                 ELSE submit_error_message END,
        row_version = row_version + 1,
        updated_at = now()
      WHERE id = ${o.id}::uuid`);

    for (const s of allSteps) {
      await insertHistory(tx, {
        orderId: o.id,
        from: s.from,
        to: s.to,
        source: s.source,
        actorUserId: input.actorUserId,
        onecStatusRaw: doc?.status ?? null,
        reason: input.reason ?? null,
        errorCode: input.rejected?.code ?? null,
        requestId: input.requestId ?? null,
        syncRunId: input.syncRunId ?? null,
      });
    }

    if (becameCancelled) {
      await insertOrderTransaction(tx, {
        kind: 'order_cancelled',
        orderId: o.id,
        customerId: o.customer_id,
        actorUserId: input.actorUserId,
        amount: o.total,
        paymentMethod: o.payment_method,
        statusSnapshot: 'cancelled',
        title: `Заказ ${o.public_number} отменён`,
        details: { source: input.source },
        dedupeKey: `order_cancelled:${o.id}`,
      });
    }

    if (allSteps.length > 0 && o.status !== to) {
      await this.notifyOwner(tx, o, to);
    }
    if (totalsDifferNow && !o.totals_differ) {
      await this.notifyTotalsDiffer(tx, o, onecTotalAfter);
    }
    return { before: o, from: o.status, to, change, unrecognizedStatus, becameCancelled };
  }

  /**
   * «Итог уточнён 1С» (10 DISC-006; 05 ONEC-039, SYNC-047; ТЗ для 1С §6.6): уведомление `order_status` автору заказа,
   * когда итог 1С впервые отличается от итога POS. Один раз на заказ (`dedupe_key` `order_totals_differ:<id>`).
   */
  async notifyTotalsDiffer(
    tx: SalesTx,
    o: Pick<OrderRow, 'id' | 'public_number' | 'created_by_user_id' | 'total'>,
    onecTotal: string,
  ): Promise<void> {
    const pos = Money.of(o.total).toString();
    const onec = Money.of(onecTotal).toString();
    await this.send(tx, o.id, {
      userId: o.created_by_user_id,
      kind: 'order_status',
      severity: 'warning',
      title: `Заказ ${o.public_number}: итог уточнён 1С`,
      body: `Итог заказа ${o.public_number} в 1С — ${onec} сом, в POS — ${pos} сом. Действует итог 1С.`,
      payload: { orderId: o.id, totalsDiffer: true, total: pos, onecTotal: onec },
      dedupeKey: `order_totals_differ:${o.id}`,
    });
  }

  /** Уведомление `order_status` автору заказа (10 ORD-040, D-41); дубль по `dedupe_key` не создаётся. */
  async notifyOwner(
    tx: SalesTx | null,
    o: Pick<OrderRow, 'id' | 'public_number' | 'created_by_user_id'>,
    to: OrderStatus,
    extra = '',
  ): Promise<void> {
    await this.send(tx, o.id, {
      userId: o.created_by_user_id,
      kind: 'order_status',
      severity: to === 'submit_failed' || to === 'cancelled' ? 'warning' : 'info',
      title: `Заказ ${o.public_number}: ${ORDER_STATUS_TITLE_RU[to]}`,
      body: `Статус заказа ${o.public_number} — «${ORDER_STATUS_TITLE_RU[to]}».${extra ? ` ${extra}` : ''}`,
      payload: { orderId: o.id, status: to },
      dedupeKey: `order_status:${o.id}:${to}`,
    });
  }

  private async send(tx: SalesTx | null, orderId: string, input: NotificationInput): Promise<void> {
    if (!this.notifications) return;
    try {
      await this.notifications.notify(tx, input);
    } catch (e) {
      if (e instanceof PortNotBoundError) {
        this.warn('orders.notify.skipped: NotificationsPort не привязан', { orderId });
        return;
      }
      throw e;
    }
  }
}

export interface OrderTransactionInput {
  readonly kind: 'order_created' | 'order_cancelled' | 'credit_sale_approved' | 'discount_override';
  readonly orderId: string;
  readonly customerId: string | null;
  readonly actorUserId: string | null;
  readonly amount: string;
  readonly paymentMethod: string | null;
  readonly statusSnapshot: string;
  readonly title: string;
  readonly details?: Readonly<Record<string, unknown>>;
  readonly dedupeKey: string;
}

/**
 * Сумма строки журнала по виду (07 §5.44 `amount`: «+ приход / − возврат/аннулирование; 0 для нефинансовых
 * (`discount_override`)»; 10 TXN-001; ревью G-returns-txn-2, G-returns-txn-3): `order_cancelled` — `−total`;
 * подтверждения (`discount_override`, `credit_sale_approved`) — `0` (сумма заказа уже в `order_created`, процент и
 * суммы — в `details`); `order_created` — `+total`.
 */
export function orderJournalAmount(kind: OrderTransactionInput['kind'], amount: string): string {
  const m = Money.of(amount);
  switch (kind) {
    case 'order_cancelled':
      return (m.isNegative() ? m : Money.ZERO.minus(m)).toString();
    case 'discount_override':
    case 'credit_sale_approved':
      return Money.ZERO.toString();
    default:
      return m.toString();
  }
}

/**
 * Строка производного журнала `transactions` (07 §5.44; ORD-053: повтор не создаёт дубль — `dedupe_key`). Запись —
 * через общий журнал `TransactionJournal` (порт `TransactionsWriter`, common/journal; этап G, RM-G-004). `amount` —
 * модуль суммы события; знак ставит `orderJournalAmount`.
 */
export async function insertOrderTransaction(tx: SalesTx, t: OrderTransactionInput): Promise<void> {
  await transactionJournal.record(tx, {
    kind: t.kind,
    source: 'pos',
    orderId: t.orderId,
    customerId: t.customerId,
    actorUserId: t.actorUserId,
    amount: orderJournalAmount(t.kind, t.amount),
    paymentMethod: t.paymentMethod as PaymentMethod | null,
    statusSnapshot: t.statusSnapshot,
    title: t.title,
    details: t.details ?? {},
    dedupeKey: t.dedupeKey,
  });
}
