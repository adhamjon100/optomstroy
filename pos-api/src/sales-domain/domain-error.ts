import type { ProblemCode } from '../common/enums.js';

/**
 * Ошибка правила домена продаж (этап F). Домен (`src/sales-domain/**` кроме `adapters/`) — чистый TypeScript без
 * Nest и БД: он только решает, допустимо ли действие, и описывает отказ кодом 08 §2.4. Преобразование в HTTP-ответ —
 * `toProblemException` (sales-domain/problem.ts), его вызывают сервисы модулей cart/orders/payments.
 *
 * `extensions` — поля-расширения Problem (08 §3.3): `resource`, `reason`, `currentStatus`, `allowedActions`,
 * `limitPercent`, `creditReason`, `conflicts` и т. п.
 */
export class SalesDomainError extends Error {
  override readonly name = 'SalesDomainError';

  constructor(
    readonly code: ProblemCode,
    readonly detail: string,
    readonly extensions: Readonly<Record<string, unknown>> = {},
    /** HTTP-статус, если у кода их несколько (VALIDATION_FAILED 400|422); иначе — первый из 08 §2.4. */
    readonly status?: number,
  ) {
    super(`${code}: ${detail}`);
  }
}

export function isSalesDomainError(e: unknown): e is SalesDomainError {
  return e instanceof SalesDomainError;
}
