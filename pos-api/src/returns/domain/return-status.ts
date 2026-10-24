import type { OutboxStatus, ReturnRequestStatus } from '../../common/enums.js';

/**
 * Автомат заявки на возврат — ядро §22.11, владелец 10 RET (§2.4, RET-007, RET-013); 08 §3.12, §4.15:
 *
 * ```
 * [*] → draft → submitted → accepted → completed
 *                 submitted | accepted → rejected
 * draft → [*] (DELETE /returns/{id})
 * ```
 *
 * Перехода `draft → rejected` нет (черновик удаляется), выхода из `rejected`/`completed` нет. Чистые функции без БД:
 * HTTP-слой и обработчики 1С проверяют переход здесь, а SQL-переход — условным `UPDATE … WHERE status = …`.
 */
const NEXT: Readonly<Record<ReturnRequestStatus, readonly ReturnRequestStatus[]>> = {
  draft: ['submitted'],
  submitted: ['accepted', 'rejected'],
  accepted: ['rejected', 'completed'],
  rejected: [],
  completed: [],
};

export function canReturnTransition(from: ReturnRequestStatus, to: ReturnRequestStatus): boolean {
  return NEXT[from].includes(to);
}

/** Итог проверки действия в POS (409 `ORDER_STATE_INVALID`, `resource: return_request`, 08 §4.15.5–§4.15.6). */
export type ReturnActionDecision =
  | { readonly kind: 'ok'; readonly cancelOutbox: boolean }
  | { readonly kind: 'invalid_transition' }
  | { readonly kind: 'already_in_onec' };

/** Элемент outbox `return_request/create`, переданный (или передающийся) в 1С: отклонить можно только в 1С. */
const OUTBOX_IN_ONEC: ReadonlySet<OutboxStatus> = new Set(['sending', 'sent', 'confirmed']);
/** Задача не дошла до 1С — отзывается вместе с отклонением (ядро §22.1: `pending | failed | dead → cancelled`). */
const OUTBOX_CANCELLABLE: ReadonlySet<OutboxStatus> = new Set(['pending', 'failed', 'dead']);

/**
 * `POST /returns/{id}/reject` (10 RET-013 (а), 08 §4.15.5): `submitted | accepted → rejected`, пока заявка не передана
 * в 1С. Передача определяется по факту (элемент outbox и ссылка 1С), а не по текущему значению env: заявка, отправленная
 * при `RETURNS_FROM_POS_ENABLED=false`, outbox не имеет и отклоняется в POS и после включения флага.
 * `accepted`, поставленный 1С (`acceptedInPos=false`), — только отклонение в 1С.
 */
export function decideReject(i: {
  readonly status: ReturnRequestStatus;
  readonly outboxStatus: OutboxStatus | null;
  readonly onecRef: string | null;
  readonly acceptedInPos: boolean;
}): ReturnActionDecision {
  if (!canReturnTransition(i.status, 'rejected')) return { kind: 'invalid_transition' };
  if (i.onecRef !== null) return { kind: 'already_in_onec' };
  if (i.outboxStatus !== null && OUTBOX_IN_ONEC.has(i.outboxStatus)) return { kind: 'already_in_onec' };
  if (i.status === 'accepted' && !i.acceptedInPos) return { kind: 'already_in_onec' };
  return { kind: 'ok', cancelOutbox: i.outboxStatus !== null && OUTBOX_CANCELLABLE.has(i.outboxStatus) };
}

/**
 * `POST /returns/{id}/accept` (10 RET-013 (б), 08 §4.15.6, ядро §23 п. 8): `submitted → accepted` старшим в POS — только
 * при `RETURNS_FROM_POS_ENABLED=false`; при `true` согласование ставит 1С (`already_in_onec`).
 */
export function decideAccept(i: {
  readonly status: ReturnRequestStatus;
  readonly outboxEnabled: boolean;
}): ReturnActionDecision {
  if (!canReturnTransition(i.status, 'accepted')) return { kind: 'invalid_transition' };
  if (i.outboxEnabled) return { kind: 'already_in_onec' };
  return { kind: 'ok', cancelOutbox: false };
}

/**
 * Путь проекции статуса 1С (05 §6.4, ONEC-067) из текущего статуса POS: шаги автомата, которые нужно выполнить
 * (пустой — изменений нет или переход недопустим: назад `completed → accepted` не выполняется, 05 §6.4). `completed`
 * из `submitted` проходит через `accepted` (согласование подразумевается проведённым возвратом).
 */
export function onecProjectionPath(
  current: ReturnRequestStatus,
  onec: 'submitted' | 'accepted' | 'rejected' | 'completed',
): ReturnRequestStatus[] {
  if (onec === 'submitted' || current === onec) return [];
  if (onec === 'completed' && current === 'submitted') return ['accepted', 'completed'];
  return canReturnTransition(current, onec) ? [onec] : [];
}

export function isOnecReturnStatus(v: unknown): v is 'submitted' | 'accepted' | 'rejected' | 'completed' {
  return v === 'submitted' || v === 'accepted' || v === 'rejected' || v === 'completed';
}
