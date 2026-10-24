import type { OnecOperationId } from './onec-gateway.js';

/** Коды ошибок HTTP-сервиса расширения (05 §6.5; `ErrorCode` контракта `onec-http-service.v1.yaml`). */
export const ONEC_ERROR_CODES = [
  'POS_E_BAD_REQUEST',
  'POS_E_UNAUTHORIZED',
  'POS_E_FORBIDDEN',
  'POS_E_NOT_FOUND',
  'POS_E_DUPLICATE',
  'POS_E_STATE',
  'POS_E_ACK_OUT_OF_ORDER',
  'POS_E_STOCK',
  'POS_E_PRICE',
  'POS_E_CREDIT',
  'POS_E_VALIDATION',
  'POS_E_LOCKED',
  'POS_E_INTERNAL',
  'POS_E_MAINTENANCE',
  'POS_E_QR_UNAVAILABLE',
] as const;

/** Временные коды (ONEC-055): повтор допустим. */
const TRANSIENT = new Set(['POS_E_LOCKED', 'POS_E_INTERNAL', 'POS_E_MAINTENANCE', 'POS_E_QR_UNAVAILABLE']);

/**
 * Ответ 1С не-2xx (или сбой транспорта — `status = 0`, `code = 'TRANSPORT'`). `message` — текст 1С для журнала
 * (05 §6.5: без ПДн); при логировании проходит redaction (common/logging/redaction.ts).
 */
export class OnecError extends Error {
  override readonly name = 'OnecError';

  constructor(
    readonly operation: OnecOperationId,
    readonly status: number,
    readonly code: string,
    message: string,
    readonly details?: unknown,
    readonly requestId?: string,
  ) {
    super(`${operation}: ${status} ${code} — ${message}`);
  }

  /** Временная ошибка (ONEC-055) или сбой транспорта: вызывающий повторяет по своему графику. */
  get retryable(): boolean {
    return this.status === 0 || this.status === 503 || this.status === 423 || TRANSIENT.has(this.code);
  }
}

export function isOnecError(e: unknown): e is OnecError {
  return e instanceof OnecError;
}

/** HTTP-статусы отказа авторизации/прав 1С (05 §6.5: 401 `POS_E_UNAUTHORIZED`, 403 `POS_E_FORBIDDEN`). */
const AUTH_STATUSES = new Set([401, 403]);
const AUTH_CODES = new Set(['POS_E_UNAUTHORIZED', 'POS_E_FORBIDDEN']);
/** Текст `OnecError` («`op`: 401 POS_E_UNAUTHORIZED — …»), обёрнутый обработчиком в другую ошибку (`SyncRunError`). */
const AUTH_MESSAGE_RE = /\b40[13] POS_E_(?:UNAUTHORIZED|FORBIDDEN)\b/;

/**
 * Отказ авторизации или прав 1С (401/403) — ошибка не временная и не данных: повторы не помогают до исправления
 * учётных данных (05 §6.5; ТЗ для 1С А.1): чтение приостанавливается на 15 минут, администратору — тревога.
 * Распознаётся сама `OnecError`, её `cause` и текст `OnecError` внутри обёртки (обработчики сущностей заворачивают
 * ошибку шлюза в `SyncRunError` с текстом исходной ошибки).
 */
export function isOnecAuthFailure(e: unknown, depth = 0): boolean {
  if (depth > 4 || e === null || e === undefined) return false;
  if (isOnecError(e)) return AUTH_STATUSES.has(e.status) || AUTH_CODES.has(e.code);
  if (e instanceof Error) {
    if (AUTH_MESSAGE_RE.test(e.message)) return true;
    return isOnecAuthFailure((e as { cause?: unknown }).cause, depth + 1);
  }
  return false;
}
