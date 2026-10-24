import type { PaymentMethod, PaymentStatus, ReviewReason } from '../../common/enums.js';
import { SalesDomainError } from '../domain-error.js';

/**
 * Автомат `payment_status` (07 §6.4 — владелец переходов; ядро §22.2, §23 пп. 3–4, §24.4; бизнес-правила — 10 §2.3,
 * §9). Чистый модуль: таблица переходов с инициаторами и проверки; записи делает модуль `payments`.
 *
 * Ключевые запреты: `credit` — конечный; `received → voided` запрещён (исправление — документами 1С);
 * `qr_expired → received` напрямую нет (поздняя оплата → `manual_confirm`, `late_payment`); создание платежа сразу в
 * `manual_confirm` недопустимо; выход из `manual_confirm` — только решением кассира со step-up.
 */

/** Кто выполняет переход (для проверки step-up и аудита). */
export type PaymentActor =
  /** Сервер в составе операции (создание, смена способа — `void_reason=method_changed`, без step-up). */
  | 'system'
  /** Подтверждение оплаты от провайдера QR: 1С (`onec`, основной R1) или банк (`bakai`, R2). */
  | 'provider'
  /** Таймер `qr_expires_at` (job `payments.qr_expire`). */
  | 'timer'
  /** Пользователь (кассир) — подтверждение приёма наличных, показ QR. */
  | 'user'
  /** Пользователь со step-up: ручное подтверждение, ручной void, решение по разбору. */
  | 'user_step_up'
  /** Проекция документа 1С (возврат денег, `received → refunded`). */
  | 'onec_sync';

export interface PaymentTransition {
  readonly from: PaymentStatus;
  readonly to: PaymentStatus;
  readonly actors: readonly PaymentActor[];
  readonly rule: string;
}

const P = (from: PaymentStatus, to: PaymentStatus, actors: PaymentActor[], rule: string): PaymentTransition => ({
  from,
  to,
  actors,
  rule,
});

/** Исчерпывающая таблица переходов 07 §6.4; всё остальное — `409 PAYMENT_STATE_INVALID`. */
export const PAYMENT_TRANSITIONS: readonly PaymentTransition[] = [
  P('initiated', 'cash_pending', ['system'], 'method = cash'),
  P('initiated', 'qr_pending', ['system'], 'method = qr_bakai'),
  P('initiated', 'credit', ['system'], 'method = credit, решение PAY-031'),
  P('cash_pending', 'received', ['user'], 'кассир подтвердил приём (payment.received)'),
  P('cash_pending', 'voided', ['system', 'user_step_up'], 'смена способа (система) / отмена (step-up)'),
  P('qr_pending', 'qr_shown', ['system', 'user'], 'QR выдан провайдером или показан статический'),
  P('qr_pending', 'voided', ['system', 'user_step_up'], 'смена способа (система) / отмена (step-up)'),
  P('qr_shown', 'received', ['provider'], 'подтверждение оплаты 1С/банка, сумма и референс совпали'),
  P('qr_shown', 'qr_expired', ['timer'], 'наступил qr_expires_at'),
  P('qr_shown', 'manual_confirm', ['provider', 'user_step_up'], 'расхождение / неизвестный референс / нет вебхука'),
  P('qr_shown', 'voided', ['system', 'user_step_up'], 'смена способа (система) / отмена (step-up)'),
  P('qr_expired', 'qr_shown', ['system', 'user'], 'перевыпуск QR, тот же payment_id (PAY-025)'),
  P('qr_expired', 'manual_confirm', ['provider'], 'оплата после истечения, late_payment (ядро §23 п. 4)'),
  P('qr_expired', 'voided', ['system', 'user_step_up'], 'отказ от QR или отмена заказа'),
  P('manual_confirm', 'received', ['user_step_up'], 'кассир подтвердил по выписке'),
  P('manual_confirm', 'voided', ['user_step_up', 'system'], 'кассир отклонил; отмена заказа (PAY-050)'),
  P('received', 'refunded', ['onec_sync'], 'только проекция документа возврата 1С'),
];

/** Конечные статусы. */
export const PAYMENT_TERMINAL_STATUSES: ReadonlySet<PaymentStatus> = new Set(['credit', 'voided', 'refunded']);

/** Незавершённые (частичный UNIQUE `payments_one_open_per_order_uq`, 07 §6.4 правило 2). */
export const PAYMENT_OPEN_STATUSES: ReadonlySet<PaymentStatus> = new Set([
  'initiated',
  'cash_pending',
  'qr_pending',
  'qr_shown',
  'qr_expired',
  'manual_confirm',
]);

/** Аннулирует система без step-up при смене способа оплаты (ядро §23 п. 3; 10 PAY-052). */
export const PAYMENT_SYSTEM_VOIDABLE_ON_METHOD_CHANGE: ReadonlySet<PaymentStatus> = new Set([
  'cash_pending',
  'qr_pending',
  'qr_shown',
]);

/** Ручной `POST /payments/{id}/void` (`payment.void`, step-up) — только до получения денег (11 §4.3). */
export const PAYMENT_USER_VOIDABLE: ReadonlySet<PaymentStatus> = new Set([
  'cash_pending',
  'qr_pending',
  'qr_shown',
  'qr_expired',
  'manual_confirm',
]);

/** Аннулируются при отмене заказа (PAY-050, 07 §6.3): неполученные платежи; `credit` остаётся `credit`. */
export const PAYMENT_VOID_ON_ORDER_CANCEL: ReadonlySet<PaymentStatus> = new Set([
  'cash_pending',
  'qr_pending',
  'qr_shown',
  'qr_expired',
  'manual_confirm',
]);

export function findPaymentTransition(from: PaymentStatus, to: PaymentStatus): PaymentTransition | undefined {
  return PAYMENT_TRANSITIONS.find((t) => t.from === from && t.to === to);
}

export function isPaymentTransitionAllowed(from: PaymentStatus, to: PaymentStatus, actor?: PaymentActor): boolean {
  const t = findPaymentTransition(from, to);
  return t !== undefined && (actor === undefined || t.actors.includes(actor));
}

export function paymentStateInvalid(
  current: PaymentStatus,
  reason: string,
  detail = 'Операция недопустима в текущем статусе платежа.',
  extra: Readonly<Record<string, unknown>> = {},
): SalesDomainError {
  return new SalesDomainError('PAYMENT_STATE_INVALID', detail, { reason, currentStatus: current, ...extra });
}

/** Проверка перехода; иначе `409 PAYMENT_STATE_INVALID` (`reason: transition_not_allowed`). */
export function assertPaymentTransition(
  from: PaymentStatus,
  to: PaymentStatus,
  actor: PaymentActor,
): PaymentTransition {
  const t = findPaymentTransition(from, to);
  if (!t || !t.actors.includes(actor)) {
    const reason =
      from === 'received' && to === 'voided'
        ? 'received_void_forbidden'
        : from === 'credit'
          ? 'credit_terminal'
          : 'transition_not_allowed';
    throw paymentStateInvalid(from, reason, `Переход платежа ${from} → ${to} (${actor}) недопустим.`, {
      targetStatus: to,
    });
  }
  return t;
}

/** Первый статус платежа после `initiated` по способу оплаты (07 §6.4). */
export function initialPaymentStatus(method: PaymentMethod): 'cash_pending' | 'qr_pending' | 'credit' {
  switch (method) {
    case 'cash':
      return 'cash_pending';
    case 'qr_bakai':
      return 'qr_pending';
    case 'credit':
      return 'credit';
  }
}

/** Ручной void (`POST /payments/{id}/void`): только до получения денег; `received` → `received_void_forbidden`. */
export function assertUserVoidable(status: PaymentStatus): void {
  if (!PAYMENT_USER_VOIDABLE.has(status)) {
    throw paymentStateInvalid(
      status,
      status === 'received' ? 'received_void_forbidden' : 'not_voidable',
      status === 'received'
        ? 'Полученный платёж аннулировать нельзя: исправление — документами 1С.'
        : 'Платёж в этом статусе аннулировать нельзя.',
    );
  }
}

/**
 * Путь `POST /payments/{id}/confirm-manual` (step-up): из `qr_shown` — `qr_shown → manual_confirm → received`
 * одной операцией (две записи истории, `review_reason=no_webhook`); из `manual_confirm` — `→ received`; из
 * `qr_expired` — сначала перевыпуск (`reason: qr_expired_reissue_required`, 08 §2.4).
 */
export function planConfirmManual(status: PaymentStatus): {
  readonly steps: readonly { readonly from: PaymentStatus; readonly to: PaymentStatus }[];
  readonly reviewReason: ReviewReason | null;
} {
  if (status === 'qr_shown') {
    return {
      steps: [
        { from: 'qr_shown', to: 'manual_confirm' },
        { from: 'manual_confirm', to: 'received' },
      ],
      reviewReason: 'no_webhook',
    };
  }
  if (status === 'manual_confirm') return { steps: [{ from: 'manual_confirm', to: 'received' }], reviewReason: null };
  if (status === 'qr_expired') {
    throw paymentStateInvalid(status, 'qr_expired_reissue_required', 'QR истёк: сначала обновите QR.');
  }
  throw paymentStateInvalid(status, 'transition_not_allowed', 'Ручное подтверждение в этом статусе недопустимо.');
}

/** Перевыпуск QR (PAY-025): из `qr_expired` → `qr_shown`; из `qr_pending` (QR не выдан) → `qr_shown`. */
export function planQrReissue(status: PaymentStatus): { readonly from: PaymentStatus; readonly to: 'qr_shown' } {
  if (status === 'qr_expired' || status === 'qr_pending') return { from: status, to: 'qr_shown' };
  throw paymentStateInvalid(status, 'transition_not_allowed', 'Перевыпуск QR в этом статусе недопустим.');
}

// ---------------------------------------------------------------------------------------------------------------
// Подтверждение оплаты провайдером QR (1С при QR_PROVIDER=onec; 07 §6.4 правило 10; ядро §24.4)
// ---------------------------------------------------------------------------------------------------------------

export interface ProviderPaymentReport {
  /** Состояние у провайдера (`PaymentProvider.status`): `paid` — деньги зачислены. */
  readonly state: 'pending' | 'paid' | 'expired' | 'cancelled' | 'unknown';
  /** Зачисленная сумма (тыйыны), если `paid`. */
  readonly paidTyiyn: bigint | null;
  /** Референс оплаты совпал с текущим `payments.qr_provider_ref`. */
  readonly referenceKnown: boolean;
  /** Референс — из истории платежа (заменён перевыпуском QR, 10 PAY-025): оплата по нему — `late_payment`. */
  readonly referencePrevious?: boolean;
}

export type ProviderDecision =
  | { readonly kind: 'none' }
  | { readonly kind: 'transition'; readonly to: 'received' }
  /** `cause: provider_cancelled` — QR отменён в 1С/банком без запроса backend (05 §6.7.3): истекает сразу. */
  | {
      readonly kind: 'transition';
      readonly to: 'qr_expired';
      readonly cause?: 'provider_expired' | 'provider_cancelled';
    }
  | { readonly kind: 'transition'; readonly to: 'manual_confirm'; readonly reviewReason: ReviewReason }
  /** Провайдер сообщил об оплате, когда платёж уже вне `qr_shown`/`qr_expired` — разбор (уведомление), без перехода. */
  | { readonly kind: 'review_only'; readonly reason: 'payment_not_awaiting' };

/**
 * Решение по отчёту провайдера (опрос `payments.qr_onec_poll`, изменение `/changes`): совпали сумма и референс →
 * `received`; сумма ≠ `amount` → `manual_confirm` (`amount_mismatch`, сумма — в `bank_amount`); неизвестный
 * референс → `unknown_reference`; оплата после истечения (`qr_expired`) → `late_payment`. `expired` у провайдера для
 * `qr_shown` → `qr_expired`.
 */
export function decideProviderReport(
  status: PaymentStatus,
  amountTyiyn: bigint,
  report: ProviderPaymentReport,
): ProviderDecision {
  if (report.state === 'paid') {
    if (status === 'qr_expired') return { kind: 'transition', to: 'manual_confirm', reviewReason: 'late_payment' };
    if (status !== 'qr_shown') return { kind: 'review_only', reason: 'payment_not_awaiting' };
    // Оплата по референсу, заменённому перевыпуском (PAY-025): тот же payment_id, разбор как поздней оплаты.
    if (!report.referenceKnown && report.referencePrevious === true) {
      return { kind: 'transition', to: 'manual_confirm', reviewReason: 'late_payment' };
    }
    if (!report.referenceKnown) {
      return { kind: 'transition', to: 'manual_confirm', reviewReason: 'unknown_reference' };
    }
    if (report.paidTyiyn === null || report.paidTyiyn !== amountTyiyn) {
      return { kind: 'transition', to: 'manual_confirm', reviewReason: 'amount_mismatch' };
    }
    return { kind: 'transition', to: 'received' };
  }
  if (report.state === 'expired' && status === 'qr_shown') {
    return { kind: 'transition', to: 'qr_expired', cause: 'provider_expired' };
  }
  // 05 §6.7.3: `cancelled` без запроса backend (QR отменён в 1С или банком) — QR больше не принимает оплату:
  // `qr_shown → qr_expired`, кассир перевыпускает QR или меняет способ. Отмена прежнего QR при перевыпуске
  // (референс из истории) текущий QR не гасит.
  if (report.state === 'cancelled' && status === 'qr_shown' && report.referencePrevious !== true) {
    return { kind: 'transition', to: 'qr_expired', cause: 'provider_cancelled' };
  }
  return { kind: 'none' };
}

// ---------------------------------------------------------------------------------------------------------------
// Смена способа оплаты (ядро §23 п. 3; 10 PAY-052) и повторный запрос платежа (08 §4.8.6)
// ---------------------------------------------------------------------------------------------------------------

export type NewPaymentPlan =
  /** Открытого платежа нет — создать новый. */
  | { readonly kind: 'create' }
  /** Тот же способ, платёж открыт — вернуть существующий (`cash` — тот же `payment_id`; QR — перевыпуск/показ). */
  | { readonly kind: 'reuse'; readonly paymentId: string }
  /** Другой способ: прежний открытый платёж аннулирует система (`method_changed`, без step-up), затем создать новый. */
  | { readonly kind: 'void_and_create'; readonly voidPaymentId: string };

export function planNewPayment(
  open: { readonly id: string; readonly method: PaymentMethod; readonly status: PaymentStatus } | null,
  method: PaymentMethod,
): NewPaymentPlan {
  if (!open) return { kind: 'create' };
  if (open.method === method) return { kind: 'reuse', paymentId: open.id };
  if (!PAYMENT_SYSTEM_VOIDABLE_ON_METHOD_CHANGE.has(open.status)) {
    // qr_expired / manual_confirm: деньги могли поступить — сначала решение кассира (перевыпуск или разбор).
    // Имя причины и поле — по контракту 08 (`open_payment_exists`, `openPaymentId`; FQ-PAY-06).
    throw paymentStateInvalid(
      open.status,
      'open_payment_exists',
      'По заказу есть платёж на разборе: подтвердите его или аннулируйте.',
      { openPaymentId: open.id },
    );
  }
  return { kind: 'void_and_create', voidPaymentId: open.id };
}
