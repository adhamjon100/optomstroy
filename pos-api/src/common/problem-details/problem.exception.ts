import { HttpException } from '@nestjs/common';
import { PROBLEM_CODE_HTTP_STATUS, type ProblemCode } from '../enums.js';

/** Элемент `errors[]` (08 §3.3): только для VALIDATION_FAILED и бизнес-валидаций. */
export interface ProblemFieldError {
  readonly field: string;
  readonly message: string;
  readonly rule: string;
  readonly params?: Readonly<Record<string, unknown>>;
}

/**
 * Поля-расширения Problem (08 §3.3). `type`, `title`, `status`, `instance`, `requestId` формирует фильтр;
 * обработчик задаёт только `code`, `detail` и расширения.
 */
export interface ProblemExtensions {
  readonly errors?: readonly ProblemFieldError[];
  readonly conflicts?: readonly unknown[];
  readonly retryAfter?: number;
  readonly attemptsLeft?: number;
  readonly stepUp?: { readonly operation: string; readonly allowedMethods: readonly ('pin' | 'otp')[] };
  readonly current?: Readonly<Record<string, unknown>>;
  readonly currentStatus?: string;
  readonly allowedActions?: readonly string[];
  readonly limitPercent?: string;
  readonly requiresRole?: string;
  readonly reason?: string;
  readonly minVersion?: string;
  readonly storeUrl?: string;
  readonly resource?: 'order' | 'cart' | 'return_request' | 'outbox_item';
  readonly [extra: string]: unknown;
}

export interface ProblemInit extends ProblemExtensions {
  readonly status?: number;
  readonly detail?: string;
  /** Дополнительные заголовки ответа (например, `Retry-After`, `X-Min-App-Version`). */
  readonly headers?: Readonly<Record<string, string>>;
}

/**
 * Исключение с машинным `code` из закрытого перечня 08 §2.4 (common/enums.ts). HTTP-статус по умолчанию —
 * первый из PROBLEM_CODE_HTTP_STATUS; иной статус допускается только из того же перечня (VALIDATION_FAILED: 400|422).
 */
export class ProblemException extends HttpException {
  readonly code: ProblemCode;
  readonly detail: string | undefined;
  readonly extensions: ProblemExtensions;
  readonly headers: Readonly<Record<string, string>>;

  constructor(code: ProblemCode, init: ProblemInit = {}) {
    const { status: requested, detail, headers, ...extensions } = init;
    const allowed = PROBLEM_CODE_HTTP_STATUS[code];
    const status = requested ?? allowed[0] ?? 500;
    if (!allowed.includes(status)) {
      throw new Error(`ProblemException: статус ${status} недопустим для ${code} (08 §2.4: ${allowed.join('|')})`);
    }
    super({ code, detail }, status);
    this.code = code;
    this.detail = detail;
    this.extensions = extensions;
    const h: Record<string, string> = { ...(headers ?? {}) };
    if (extensions.retryAfter !== undefined && h['Retry-After'] === undefined)
      h['Retry-After'] = String(extensions.retryAfter);
    this.headers = h;
  }
}
