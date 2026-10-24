import { Inject, Injectable } from '@nestjs/common';
import { ProblemException } from '../problem-details/problem.exception.js';
import { getIdempotencyState } from './idempotency.context.js';
import {
  IDEMPOTENCY_STORE,
  type IdempotencyExecutor,
  IDEMPOTENCY_TTL_MS,
  type IdempotencyScope,
  type IdempotencyStore,
} from './idempotency.store.js';

export type BeginResult =
  { readonly kind: 'proceed' } | { readonly kind: 'replay'; readonly status: number; readonly body: unknown };

/** `Retry-After` для `409 IDEMPOTENCY_IN_PROGRESS` (08 §2.7). */
export const IDEMPOTENCY_RETRY_AFTER_SEC = 2;

/**
 * Логика идемпотентности 08 §2.7 (не зависит от HTTP и БД — проверяется unit-тестом на in-memory хранилище):
 * - новый ключ / просроченный (> 24 ч) → выполнить запрос;
 * - тот же ключ, другой отпечаток → `422 IDEMPOTENCY_KEY_REUSED`;
 * - тот же ключ, `in_progress` → `409 IDEMPOTENCY_IN_PROGRESS` + `Retry-After: 2`;
 * - тот же ключ, `completed` → повтор сохранённого статуса и тела (`Idempotent-Replayed: true`).
 */
@Injectable()
export class IdempotencyService {
  constructor(@Inject(IDEMPOTENCY_STORE) private readonly store: IdempotencyStore) {}

  async begin(scope: IdempotencyScope, requestHash: Buffer): Promise<BeginResult> {
    // Повтор цикла — только при гонке «запись удалили между захватом и чтением» (release параллельного запроса).
    for (let attempt = 0; attempt < 3; attempt++) {
      const existing = await this.store.acquire(scope, requestHash, IDEMPOTENCY_TTL_MS);
      if (existing === null) return { kind: 'proceed' };
      if (!existing.requestHash.equals(requestHash)) {
        throw new ProblemException('IDEMPOTENCY_KEY_REUSED', {
          detail: 'Ключ идемпотентности уже использован для другого запроса.',
        });
      }
      if (existing.status === 'in_progress') {
        throw new ProblemException('IDEMPOTENCY_IN_PROGRESS', {
          detail: 'Запрос с этим ключом ещё выполняется.',
          retryAfter: IDEMPOTENCY_RETRY_AFTER_SEC,
        });
      }
      if (existing.responseStatus !== null) {
        return { kind: 'replay', status: existing.responseStatus, body: existing.responseBody };
      }
    }
    throw new ProblemException('IDEMPOTENCY_IN_PROGRESS', {
      detail: 'Запрос с этим ключом ещё выполняется.',
      retryAfter: IDEMPOTENCY_RETRY_AFTER_SEC,
    });
  }

  complete(scope: IdempotencyScope, status: number, body: unknown, resourceId?: string | null): Promise<void> {
    return this.store.complete(scope, status, body, resourceId);
  }

  /**
   * Запись итога в транзакции бизнес-операции (B-AR-04; обязательно для денежных маршрутов): вызывается
   * обработчиком до COMMIT с клиентом этой транзакции. Перехватчик после этого итог отдельно не пишет (C-CR-02).
   * Без `Idempotency-Key` в запросе — no-op.
   */
  async recordInTransaction(
    tx: IdempotencyExecutor,
    req: object,
    status: number,
    body: unknown,
    resourceId?: string | null,
  ): Promise<void> {
    const state = getIdempotencyState(req);
    if (!state) return;
    await this.store.complete(state.scope, status, body, resourceId, tx);
    state.recordedInTx = true;
  }

  release(scope: IdempotencyScope): Promise<void> {
    return this.store.release(scope);
  }
}

/**
 * Какие ответы-ошибки сохраняются для повтора (08 §2.7: «тот же HTTP-статус и тело, включая ошибки 4xx
 * бизнес-уровня»): 404, 409, 422 — результат бизнес-проверки. Не сохраняются (ключ освобождается, клиент
 * повторяет с тем же ключом): 400/413/415 (запрос не принят к обработке), 401/403 (в т.ч. STEP_UP_REQUIRED —
 * «повторить запрос с тем же Idempotency-Key»), 426, 429 и 5xx.
 */
export function isStorableErrorStatus(status: number): boolean {
  return status === 404 || status === 409 || status === 422;
}
