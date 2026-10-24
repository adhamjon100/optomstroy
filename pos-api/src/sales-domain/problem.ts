import { ProblemException } from '../common/problem-details/problem.exception.js';
import { SalesDomainError } from './domain-error.js';

/** `SalesDomainError` → `ProblemException` (08 §2.4, §3.3). Остальные исключения возвращаются без изменений. */
export function toProblemException(e: unknown): unknown {
  if (!(e instanceof SalesDomainError)) return e;
  return new ProblemException(e.code, {
    detail: e.detail,
    ...(e.status !== undefined ? { status: e.status } : {}),
    ...e.extensions,
  });
}

/** Выполняет `fn`; доменная ошибка превращается в `ProblemException` (для контроллеров и сервисов). */
export async function withProblem<T>(fn: () => Promise<T> | T): Promise<T> {
  try {
    return await fn();
  } catch (e) {
    throw toProblemException(e);
  }
}
