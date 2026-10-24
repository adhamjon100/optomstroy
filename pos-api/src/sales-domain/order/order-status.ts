import type { OrderStatus, PaymentMethod, StatusChangeSource } from '../../common/enums.js';
import { SalesDomainError } from '../domain-error.js';

/**
 * Статусы заказа D-20 — производная проекция `projectOrderStatus` (10 §2.2 P1…P10 — владелец бизнес-правил;
 * 07 §6.3 — владелец enum, таблицы переходов и состава записей истории; ядро §17.2, §22.3, §22.9, §23 пп. 1–2).
 *
 * - `draft` — технический статус строки внутри транзакции `POST /orders` (не корзина, клиенту не возвращается);
 * - `awaiting_payment` — служебный статус «ждёт денег» (P8) до ответа Q-012;
 * - `approved` — статус-событие: пишется в историю при согласовании в 1С и в той же транзакции уточняется до
 *   `awaiting_shipment` (P10);
 * - проекция выполняется в момент перехода outbox `create` в `sent` (ответ 1С или ручная привязка `onec-link`);
 *   `sent → confirmed` повторной проекции не вызывает (ядро §23 п. 2).
 *
 * Модуль чистый: решает, какой статус следует из фактов и допустим ли переход. Записи (`orders`,
 * `order_status_history`, уведомления, аудит) делает модуль `orders`.
 */

/** Нормализованный статус документа 1С (05 ONEC-021; «Закрыт» без реализации = отмена, P2). `null` — неизвестен. */
export type OnecOrderStatus = 'not_approved' | 'to_execute' | 'closed';

/** Входные факты проекции (10 §2.2; где хранятся — 07 §6.3). */
export interface OrderFacts {
  /** Строка существует только внутри транзакции `POST /orders`. */
  readonly creating: boolean;
  /** `orders.cancelled_at IS NOT NULL` или пометка удаления в 1С (ONEC-020). */
  readonly cancelConfirmed: boolean;
  /** outbox `create` в `failed` с `ONEC_REJECTED`. */
  readonly rejected: boolean;
  /** `orders.onec_ref IS NOT NULL`. */
  readonly hasOnecRef: boolean;
  /** `orders.onec_status_raw`, нормализованный; `null` — статус 1С неизвестен (10 §2.2 правило 8). */
  readonly onecStatus: OnecOrderStatus | null;
  readonly hasShipment: boolean;
  readonly hasReturn: boolean;
  readonly paymentMethod: PaymentMethod;
  /** `orders.paid_at IS NOT NULL` (монотонный факт, 10 §2.2 правило 3). */
  readonly paidAtSet: boolean;
  /** `orders.paid_amount > 0` (для P2 «деньги получены — заказ отклонён», ядро §22.9). */
  readonly hasReceivedMoney: boolean;
}

export type ProjectionRule = 'P1' | 'P2' | 'P3' | 'P4' | 'P5' | 'P6' | 'P7' | 'P8' | 'P9' | 'P10';

export type OrderProjection =
  | { readonly status: OrderStatus; readonly rule: ProjectionRule }
  /** Статус 1С неизвестен — статус заказа не меняется, ошибка — в `sync_errors` (10 §2.2 правило 8, ORD-041). */
  | { readonly status: null; readonly rule: 'unknown_onec_status' };

/** Факт `settled` (10 §2.2): продажа в долг разрешена при создании или установлен `paid_at`. */
export function isSettled(f: Pick<OrderFacts, 'paymentMethod' | 'paidAtSet'>): boolean {
  return f.paymentMethod === 'credit' || f.paidAtSet;
}

/** Таблица проекции P1…P10 (условия сверху вниз; первое выполненное определяет статус). */
export function projectOrderStatus(f: OrderFacts): OrderProjection {
  if (f.creating) return { status: 'draft', rule: 'P1' };
  // «Закрыт» в 1С без реализации трактуется как подтверждённая отмена (10 §2.2 «Полнота»).
  const closedWithoutShipment = f.hasOnecRef && f.onecStatus === 'closed' && !f.hasShipment;
  if (f.cancelConfirmed || closedWithoutShipment || (f.rejected && f.hasReceivedMoney)) {
    return { status: 'cancelled', rule: 'P2' };
  }
  if (f.rejected && !f.hasOnecRef) return { status: 'submit_failed', rule: 'P3' };
  if (!f.hasOnecRef) return { status: 'submitting', rule: 'P4' };
  if (f.onecStatus === 'closed' && f.hasShipment) return { status: 'closed', rule: 'P5' };
  if (f.hasReturn) return { status: 'partially_returned', rule: 'P6' };
  if (f.hasShipment) return { status: 'shipped', rule: 'P7' };
  if ((f.paymentMethod === 'cash' || f.paymentMethod === 'qr_bakai') && !isSettled(f)) {
    return { status: 'awaiting_payment', rule: 'P8' };
  }
  if (f.onecStatus === 'not_approved') return { status: 'pending_approval', rule: 'P9' };
  if (f.onecStatus === 'to_execute') return { status: 'awaiting_shipment', rule: 'P10' };
  return { status: null, rule: 'unknown_onec_status' };
}

/** Допустимый переход 07 §6.3 (таблица «Из → В», инициатор = `order_status_history.source`). */
export interface OrderTransition {
  readonly from: OrderStatus;
  readonly to: OrderStatus;
  readonly sources: readonly StatusChangeSource[];
  /** Пояснение (правило 10/07), для сообщений и тестов. */
  readonly rule: string;
}

const T = (from: OrderStatus, to: OrderStatus, sources: StatusChangeSource[], rule: string): OrderTransition => ({
  from,
  to,
  sources,
  rule,
});

/**
 * Исчерпывающая таблица допустимых переходов `order_status` (07 §6.3 + диаграмма 10 §2.2). Всё, чего нет в
 * таблице, — `409 ORDER_STATE_INVALID` (DATA-201), в т. ч. любой переход из `closed`/`cancelled`, `shipped →
 * cancelled`, `submit_failed → cancelled`, `awaiting_shipment → awaiting_payment`.
 *
 * Примечание: `awaiting_payment → awaiting_shipment` есть на диаграмме 10 §2.2, а 07 §6.3 (владелец состава записей)
 * пишет при этом событие `approved` (две записи истории). Прямой переход допустим таблицей, `planOrderStatusChange`
 * строит путь через `approved` (FQ-BASE-03).
 */
export const ORDER_TRANSITIONS: readonly OrderTransition[] = [
  T('draft', 'submitting', ['pos_system'], 'POST /orders: проверки пройдены, outbox pending (P4)'),
  T('submitting', 'awaiting_payment', ['onec_response', 'pos_user'], 'outbox create → sent, не оплачен (P8)'),
  T('submitting', 'pending_approval', ['onec_response', 'pos_user'], 'outbox create → sent, settled (P9)'),
  T('submitting', 'approved', ['onec_response', 'pos_user'], 'outbox create → sent, сразу «К выполнению» (P10)'),
  T('submitting', 'submit_failed', ['onec_response'], 'ONEC_REJECTED без оплаты (P3)'),
  T('submitting', 'cancelled', ['pos_user', 'onec_response'], 'ORD-050 немедленная отмена / отказ 1С при оплате (P2)'),
  T('submit_failed', 'submitting', ['pos_user'], 'технический повтор outbox (ORD-027)'),
  T('awaiting_payment', 'pending_approval', ['pos_system'], 'оплата закрыта (paid_at), «Не согласован» (P9)'),
  T('awaiting_payment', 'approved', ['pos_system', 'onec_sync', 'onec_response'], 'оплата закрыта, «К выполнению»'),
  T('awaiting_payment', 'awaiting_shipment', ['pos_system', 'onec_sync'], 'диаграмма 10 §2.2 (см. FQ-BASE-03)'),
  T('awaiting_payment', 'cancelled', ['onec_response', 'onec_sync'], 'отмена подтверждена 1С (ORD-050, ORD-051)'),
  T('pending_approval', 'approved', ['onec_sync', 'onec_response'], '1С «К выполнению» (P10)'),
  T('pending_approval', 'cancelled', ['onec_response', 'onec_sync'], 'отмена подтверждена 1С (ORD-050)'),
  T('approved', 'awaiting_shipment', ['onec_sync', 'onec_response', 'pos_system', 'pos_user'], 'P10, та же транзакция'),
  T('awaiting_shipment', 'pending_approval', ['onec_sync'], '1С вернула «Не согласован» (10 §2.2 правило 7)'),
  T('awaiting_shipment', 'shipped', ['onec_sync'], 'реализация проведена (P7)'),
  T('awaiting_shipment', 'cancelled', ['onec_response', 'onec_sync'], 'запрос отмены подтверждён 1С (ORD-051)'),
  T('shipped', 'partially_returned', ['onec_sync'], 'возврат проведён (P6)'),
  T('shipped', 'closed', ['onec_sync'], '«Закрыт» в 1С (P5)'),
  T('partially_returned', 'closed', ['onec_sync'], '«Закрыт» в 1С (P5)'),
];

/** Терминальные статусы (переходов из них нет). `submit_failed` терминален для пользователя (тех. повтор — выше). */
export const ORDER_TERMINAL_STATUSES: ReadonlySet<OrderStatus> = new Set(['closed', 'cancelled']);

export function findOrderTransition(from: OrderStatus, to: OrderStatus): OrderTransition | undefined {
  return ORDER_TRANSITIONS.find((t) => t.from === from && t.to === to);
}

export function isOrderTransitionAllowed(from: OrderStatus, to: OrderStatus, source?: StatusChangeSource): boolean {
  const t = findOrderTransition(from, to);
  return t !== undefined && (source === undefined || t.sources.includes(source));
}

export function orderStateInvalid(
  current: OrderStatus,
  reason: string,
  detail = 'Действие недопустимо в текущем статусе заказа.',
  extra: Readonly<Record<string, unknown>> = {},
): SalesDomainError {
  return new SalesDomainError('ORDER_STATE_INVALID', detail, {
    resource: 'order',
    reason,
    currentStatus: current,
    ...extra,
  });
}

/** Проверка перехода по таблице; иначе `409 ORDER_STATE_INVALID` (`resource: order`, `reason: transition_not_allowed`). */
export function assertOrderTransition(from: OrderStatus, to: OrderStatus, source: StatusChangeSource): OrderTransition {
  const t = findOrderTransition(from, to);
  if (!t || !t.sources.includes(source)) {
    throw orderStateInvalid(from, 'transition_not_allowed', `Переход ${from} → ${to} (${source}) недопустим.`, {
      targetStatus: to,
    });
  }
  return t;
}

/** Запись истории статусов, которую модуль `orders` вставляет в `order_status_history`. */
export interface OrderHistoryStep {
  readonly from: OrderStatus;
  readonly to: OrderStatus;
  readonly source: StatusChangeSource;
}

export interface OrderStatusChange {
  /** Итоговый `orders.status`. */
  readonly to: OrderStatus;
  readonly rule: ProjectionRule;
  /** Записи истории по порядку (для P10 — событие `approved` и уточнение до `awaiting_shipment`). */
  readonly history: readonly OrderHistoryStep[];
}

/** Статусы, из которых получение «К выполнению» означает согласование (событие `approved`, 07 §6.3 P10). */
const APPROVAL_EVENT_FROM: ReadonlySet<OrderStatus> = new Set([
  'submitting',
  'awaiting_payment',
  'pending_approval',
  'approved',
]);

/**
 * Пересчёт статуса по фактам (ORD-033): `null` — статус не меняется (тот же статус, неизвестный статус 1С —
 * «повторная синхронизация с тем же статусом не создаёт записи», 07 §6.3). Каждый шаг проверяется таблицей
 * переходов; недопустимый — `ORDER_STATE_INVALID`.
 */
export function planOrderStatusChange(
  current: OrderStatus,
  facts: OrderFacts,
  source: StatusChangeSource,
): OrderStatusChange | null {
  const p = projectOrderStatus(facts);
  if (p.status === null || p.status === current) return null;
  const target = p.status;
  if (target === 'awaiting_shipment' && APPROVAL_EVENT_FROM.has(current)) {
    const steps: OrderHistoryStep[] = [];
    if (current !== 'approved') {
      assertOrderTransition(current, 'approved', source);
      steps.push({ from: current, to: 'approved', source });
    }
    assertOrderTransition('approved', 'awaiting_shipment', source);
    steps.push({ from: 'approved', to: 'awaiting_shipment', source });
    return { to: target, rule: p.rule, history: steps };
  }
  assertOrderTransition(current, target, source);
  return { to: target, rule: p.rule, history: [{ from: current, to: target, source }] };
}

// ---------------------------------------------------------------------------------------------------------------
// Приём оплаты по заказу (ядро §22.5; 10 §2.2 правило 4)
// ---------------------------------------------------------------------------------------------------------------

/** Статусы, в которых принимается оплата любым способом и показывается QR (ядро §22.5, §19.4 G-10). */
export const ORDER_PAYABLE_STATUSES: ReadonlySet<OrderStatus> = new Set([
  'submitting',
  'pending_approval',
  'approved',
  'awaiting_payment',
]);

export function isOrderPayable(status: OrderStatus): boolean {
  return ORDER_PAYABLE_STATUSES.has(status);
}

/**
 * Проверка «заказ принимает оплату» (`POST /orders/{id}/payments`, перевыпуск QR): статус вне перечня ядра §22.5 →
 * `ORDER_STATE_INVALID` (`reason: order_not_payable`); полностью оплаченный — `reason: already_paid` (08 §4.8.6).
 */
export function assertOrderAcceptsPayment(status: OrderStatus, isPaid: boolean): void {
  if (!isOrderPayable(status)) {
    throw orderStateInvalid(status, 'order_not_payable', 'Оплата заказа в этом статусе невозможна.');
  }
  if (isPaid) throw orderStateInvalid(status, 'already_paid', 'Заказ уже оплачен.');
}

// ---------------------------------------------------------------------------------------------------------------
// Отмена заказа (10 ORD-050…ORD-053; 07 §6.3; ядро §22.9)
// ---------------------------------------------------------------------------------------------------------------

/** Статус outbox `create` заказа (07 §6.5) — вход решения об отмене. */
export type OrderCreateOutboxState = 'pending' | 'sending' | 'sent' | 'confirmed' | 'failed' | 'dead' | 'cancelled';

export interface OrderCancelInput {
  readonly status: OrderStatus;
  readonly hasOnecRef: boolean;
  readonly createOutbox: { readonly status: OrderCreateOutboxState; readonly attempts: number } | null;
  readonly hasReceivedPayments: boolean;
  /** Заказ создан текущим пользователем (`created_by_user_id`); для `customer` — свой заказ (CUST-025). */
  readonly isOwn: boolean;
  readonly cancelAlreadyRequested: boolean;
  readonly canCancelOwn: boolean;
  readonly canRequestAny: boolean;
}

export type OrderCancelOutboxAction =
  /** outbox `create` (`pending`/`dead`) → `cancelled`; 1С не вызывалась (`attempts = 0`). */
  | 'cancel_create'
  /** outbox `create` → `cancelled` и защитная `cancel` без `depends_on` (была попытка с неизвестным результатом). */
  | 'cancel_create_and_enqueue_cancel'
  /** outbox `cancel` с `depends_on_outbox_id` на `create` (`sending`) — статус не меняется до ответа 1С. */
  | 'enqueue_cancel_after_create'
  /** outbox `cancel` → `POST /pos/v1/orders/{uuid}/cancel` (заказ создан в 1С). */
  | 'enqueue_cancel';

export type OrderCancelDecision =
  | {
      readonly kind: 'cancel_now';
      readonly outbox: 'cancel_create' | 'cancel_create_and_enqueue_cancel';
      /** Право, по которому выполняется (`order.cancel.request.any` требует step-up). */
      readonly via: 'own' | 'any';
      readonly requiresStepUp: boolean;
    }
  | {
      readonly kind: 'request';
      readonly outbox: 'enqueue_cancel_after_create' | 'enqueue_cancel';
      readonly via: 'own' | 'any';
      readonly requiresStepUp: boolean;
      /** При полученных платежах обязателен `refundIntent` (ORD-051). */
      readonly refundIntentRequired: boolean;
    };

const OWN_CANCEL_STATUSES: ReadonlySet<OrderStatus> = new Set(['submitting', 'awaiting_payment', 'pending_approval']);
const REQUEST_CANCEL_STATUSES: ReadonlySet<OrderStatus> = new Set([
  'submitting',
  'awaiting_payment',
  'pending_approval',
  'approved',
  'awaiting_shipment',
]);

/**
 * Решение по `POST /orders/{id}/cancel`. Право «свой до согласования без полученных платежей» — `order.cancel.own`
 * без step-up; иначе — `order.cancel.request.any` со step-up (`seller`/`customer` чужой заказ → `403 FORBIDDEN`).
 * `submit_failed`, `shipped`, `partially_returned`, `closed`, `cancelled` → `ORDER_STATE_INVALID` (ORD-052, 07 §6.3).
 * Повторный запрос отмены → `ORDER_STATE_INVALID` (`reason: cancel_already_requested`, 08 §4.8.4); идемпотентный
 * повтор с тем же ключом обслуживает механизм `Idempotency-Key`.
 */
export function decideOrderCancel(i: OrderCancelInput): OrderCancelDecision {
  if (!REQUEST_CANCEL_STATUSES.has(i.status)) {
    throw orderStateInvalid(i.status, 'not_cancellable', 'Заказ в этом статусе отменить нельзя.');
  }
  if (i.cancelAlreadyRequested) {
    throw orderStateInvalid(i.status, 'cancel_already_requested', 'Запрос отмены уже отправлен.');
  }
  const ownAllowed = i.isOwn && i.canCancelOwn && OWN_CANCEL_STATUSES.has(i.status) && !i.hasReceivedPayments;
  let via: 'own' | 'any';
  if (ownAllowed) via = 'own';
  else if (i.canRequestAny) via = 'any';
  else throw new SalesDomainError('FORBIDDEN', 'Недостаточно прав для отмены этого заказа.');
  const requiresStepUp = via === 'any';

  if (i.status === 'submitting' && !i.hasOnecRef) {
    const ob = i.createOutbox;
    if (!ob || ob.status === 'pending' || ob.status === 'dead') {
      if (i.hasReceivedPayments) {
        // Деньги получены: немедленная отмена недопустима, только запрос (ORD-051, ORD-035). Задача cancel ставится
        // следом за create (depends_on), чтобы не обогнать создание документа 1С (FQ-BASE-04).
        return {
          kind: 'request',
          outbox: 'enqueue_cancel_after_create',
          via,
          requiresStepUp,
          refundIntentRequired: true,
        };
      }
      return {
        kind: 'cancel_now',
        outbox: ob && ob.attempts > 0 ? 'cancel_create_and_enqueue_cancel' : 'cancel_create',
        via,
        requiresStepUp,
      };
    }
    if (ob.status === 'sending') {
      return {
        kind: 'request',
        outbox: 'enqueue_cancel_after_create',
        via,
        requiresStepUp,
        refundIntentRequired: i.hasReceivedPayments,
      };
    }
    if (ob.status === 'failed') {
      // failed (ONEC_REJECTED) даёт submit_failed (P3) — отмена недопустима (07 §6.3).
      throw orderStateInvalid(i.status, 'not_cancellable', 'Заказ отклонён 1С, отмена недопустима.');
    }
    // sent/confirmed без onec_ref в заказе — проекция ещё не применена: запрос отмены в 1С.
    if (ob.status === 'cancelled') throw orderStateInvalid(i.status, 'not_cancellable', 'Задача 1С уже отозвана.');
  }
  return {
    kind: 'request',
    outbox: 'enqueue_cancel',
    via,
    requiresStepUp,
    refundIntentRequired: i.hasReceivedPayments,
  };
}
