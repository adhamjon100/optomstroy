import type { IdempotencyScope } from './idempotency.store.js';

/**
 * Состояние идемпотентного запроса, которое IdempotencyInterceptor прикрепляет к `req` после захвата ключа
 * (08 §2.7; ревью C-CR-02). Обработчик бизнес-операции сообщает через него, что побочный эффект зафиксирован:
 *
 * - `IdempotencyService.recordInTransaction(tx, req, …)` — итог записан в `idempotency_keys` **в транзакции
 *   бизнес-операции** (B-AR-04; обязательно для денежных маршрутов: заказ, платёж, возврат). После этого перехватчик
 *   отдельной командой итог не пишет; при ошибке после записи `release` безопасен — он удаляет только строки
 *   `in_progress`, а зафиксированная строка уже `completed`;
 * - `markIdempotencyCommitted(req)` — COMMIT выполнен, но итог в той же транзакции не записан. Тогда при любой
 *   последующей ошибке ключ **не освобождается** (остаётся `in_progress` до истечения 24 ч → повтор получает
 *   `409 IDEMPOTENCY_IN_PROGRESS`, а не второе выполнение операции).
 */
export interface IdempotencyRequestState {
  readonly scope: IdempotencyScope;
  /** Бизнес-транзакция зафиксирована (COMMIT), итог отдельно ещё не записан. */
  committed: boolean;
  /** Итог записан в транзакции бизнес-операции (recordInTransaction). */
  recordedInTx: boolean;
}

const STATE = Symbol.for('optomstroy.idempotency.state');

type Carrier = object & { [STATE]?: IdempotencyRequestState };

export function attachIdempotencyState(req: object, scope: IdempotencyScope): IdempotencyRequestState {
  const state: IdempotencyRequestState = { scope, committed: false, recordedInTx: false };
  (req as Carrier)[STATE] = state;
  return state;
}

export function getIdempotencyState(req: object): IdempotencyRequestState | undefined {
  return (req as Carrier)[STATE];
}

/** Сообщить перехватчику, что побочный эффект зафиксирован (после COMMIT) — ключ больше не освобождается. */
export function markIdempotencyCommitted(req: object): void {
  const state = getIdempotencyState(req);
  if (state) state.committed = true;
}
