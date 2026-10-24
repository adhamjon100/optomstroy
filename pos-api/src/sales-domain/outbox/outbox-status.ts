import type { OutboxStatus } from '../../common/enums.js';
import { outboxBackoffMs, outboxDeadReason, type OutboxDeadReason } from '../../sync/scheduler/outbox-backoff.js';
import type { OutboxConfig } from '../../sync/scheduler/scheduler.config.js';
import { SalesDomainError } from '../domain-error.js';

/**
 * Автомат `onec_outbox` (07 §6.5 — владелец; ядро §22.1 + единственное расширение §23 п. 1: `pending | failed | dead
 * → sent` ручной привязкой). Повторы и пороги — те же функции, что у диспетчера `outbox.dispatch`
 * (`sync/scheduler/outbox-backoff.ts`: 1, 2, 5, 15, 60 мин, далее 60 мин; `dead` при `attempts ≥ OUTBOX_MAX_ATTEMPTS`
 * (20) или возрасте > `OUTBOX_MAX_AGE_HOURS` (24 ч)) — здесь они не дублируются.
 *
 * Таймаут/неизвестный результат — **всегда `pending`**, никогда не `sent` (повтор безопасен по `externalId`).
 */

/** Что вызывает переход (для таблицы и тестов). */
export type OutboxTrigger =
  /** Воркер захватил строку (`FOR UPDATE SKIP LOCKED`, `lease_until`, `attempts + 1`). */
  | 'claim'
  /** 1С вернула Ref_Key (200/201) или `POS_E_DUPLICATE`. */
  | 'delivered'
  /** Таймаут, 5xx, сеть, истечение аренды — временная ошибка. */
  | 'transient'
  /** Ошибка данных / бизнес-отказ 1С (`POS_E_VALIDATION|STOCK|PRICE|CREDIT|STATE`). */
  | 'rejected'
  /** Порог попыток/возраста при временной ошибке, либо 401/403/ошибка конфигурации. */
  | 'dead'
  /** Синхронизация прочитала документ и сопоставила по `externalId`. */
  | 'confirmed_by_sync'
  /** Ручной повтор `POST /sync/outbox/{id}/retry` (`attempts = 0`). */
  | 'manual_retry'
  /** Ручная привязка документа 1С `POST /orders/{id}/onec-link` (step-up, аудит `order.onec_linked`). */
  | 'manual_link'
  /** Отзыв задачи транзакцией бизнес-операции над агрегатом (отмена заказа до отправки). */
  | 'aggregate_cancelled';

export interface OutboxTransition {
  readonly from: OutboxStatus;
  readonly to: OutboxStatus;
  readonly triggers: readonly OutboxTrigger[];
}

const O = (from: OutboxStatus, to: OutboxStatus, triggers: OutboxTrigger[]): OutboxTransition => ({
  from,
  to,
  triggers,
});

/** Исчерпывающая таблица 07 §6.5; всё остальное — ошибка автомата (`sending → cancelled`, `pending → confirmed`…). */
export const OUTBOX_TRANSITIONS: readonly OutboxTransition[] = [
  O('pending', 'sending', ['claim']),
  O('pending', 'sent', ['manual_link']),
  O('pending', 'cancelled', ['aggregate_cancelled']),
  O('sending', 'sent', ['delivered']),
  O('sending', 'pending', ['transient']),
  O('sending', 'failed', ['rejected']),
  O('sending', 'dead', ['dead']),
  O('sent', 'confirmed', ['confirmed_by_sync']),
  O('failed', 'pending', ['manual_retry']),
  O('failed', 'sent', ['manual_link']),
  O('failed', 'cancelled', ['aggregate_cancelled']),
  O('dead', 'pending', ['manual_retry']),
  O('dead', 'sent', ['manual_link']),
  O('dead', 'cancelled', ['aggregate_cancelled']),
];

export const OUTBOX_TERMINAL_STATUSES: ReadonlySet<OutboxStatus> = new Set(['confirmed', 'cancelled']);

export function findOutboxTransition(from: OutboxStatus, to: OutboxStatus): OutboxTransition | undefined {
  return OUTBOX_TRANSITIONS.find((t) => t.from === from && t.to === to);
}

export function isOutboxTransitionAllowed(from: OutboxStatus, to: OutboxStatus, trigger?: OutboxTrigger): boolean {
  const t = findOutboxTransition(from, to);
  return t !== undefined && (trigger === undefined || t.triggers.includes(trigger));
}

/**
 * Проверка перехода. Ошибка — `409 ORDER_STATE_INVALID` с `resource: outbox_item` (08 §2.4: так отвечают, например,
 * `retry` строки `cancelled` и `onec-link` при `sending`/`cancelled`, ORD-034).
 */
export function assertOutboxTransition(from: OutboxStatus, to: OutboxStatus, trigger: OutboxTrigger): OutboxTransition {
  const t = findOutboxTransition(from, to);
  if (!t || !t.triggers.includes(trigger)) {
    throw new SalesDomainError('ORDER_STATE_INVALID', `Переход задачи 1С ${from} → ${to} (${trigger}) недопустим.`, {
      resource: 'outbox_item',
      reason: 'transition_not_allowed',
      currentStatus: from,
      targetStatus: to,
    });
  }
  return t;
}

/** Исход доставки (совместим с `OutboxDeliveryResult.kind` диспетчера `jobs/outbox`). */
export type OutboxDeliveryKind = 'sent' | 'transient' | 'rejected' | 'fatal';

export type OutboxOutcome =
  | { readonly to: 'sent' }
  | { readonly to: 'failed'; readonly errorCode: 'ONEC_REJECTED' }
  | { readonly to: 'pending'; readonly retryInMs: number }
  | { readonly to: 'dead'; readonly reason: OutboxDeadReason | 'fatal' };

/**
 * Итог обработки захваченной строки (`sending`) по исходу доставки — та же политика, что `OutboxDispatcher.apply`.
 * `attempts` — уже увеличенный при захвате счётчик; `ageMs` — возраст от создания или последнего ручного повтора.
 */
export function outboxOutcome(
  kind: OutboxDeliveryKind,
  attempts: number,
  ageMs: number,
  cfg: Pick<OutboxConfig, 'backoffMs' | 'backoffTailMs' | 'maxAttempts' | 'maxAgeMs'>,
): OutboxOutcome {
  switch (kind) {
    case 'sent':
      return { to: 'sent' };
    case 'rejected':
      return { to: 'failed', errorCode: 'ONEC_REJECTED' };
    case 'fatal':
      return { to: 'dead', reason: 'fatal' };
    case 'transient': {
      const reason = outboxDeadReason(attempts, ageMs, cfg);
      if (reason) return { to: 'dead', reason };
      return { to: 'pending', retryInMs: outboxBackoffMs(attempts, cfg) };
    }
  }
}

/** Классификация ответа 1С (05 §6.5, ONEC-055) в исход доставки: `POS_E_DUPLICATE` — `sent`. */
export function classifyOnecResult(
  r: { readonly ok: true } | { readonly ok: false; readonly status: number; readonly code: string },
): OutboxDeliveryKind {
  if (r.ok) return 'sent';
  if (r.code === 'POS_E_DUPLICATE') return 'sent';
  if (r.status === 0 || r.status === 503 || r.status === 423 || r.status >= 500) return 'transient';
  if (['POS_E_LOCKED', 'POS_E_INTERNAL', 'POS_E_MAINTENANCE', 'POS_E_QR_UNAVAILABLE'].includes(r.code)) {
    return 'transient';
  }
  if (r.status === 401 || r.status === 403) return 'fatal';
  if (['POS_E_VALIDATION', 'POS_E_STOCK', 'POS_E_PRICE', 'POS_E_CREDIT', 'POS_E_STATE'].includes(r.code)) {
    return 'rejected';
  }
  // Прочие 4xx (POS_E_BAD_REQUEST, POS_E_NOT_FOUND) — ошибка данных запроса: без автоповтора.
  return 'rejected';
}

/** Ручная привязка (`onec-link`, ORD-034): допустима из `pending`/`failed`/`dead`; иначе `ORDER_STATE_INVALID`. */
export function assertManualLinkAllowed(status: OutboxStatus): void {
  assertOutboxTransition(status, 'sent', 'manual_link');
}
