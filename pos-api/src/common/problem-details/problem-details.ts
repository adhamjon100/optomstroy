import { HttpException, HttpStatus } from '@nestjs/common';
import { PROBLEM_CODE_HTTP_STATUS, type ProblemCode } from '../enums.js';
import { ProblemException, type ProblemExtensions } from './problem.exception.js';
import { PROBLEM_TITLES_RU } from './problem-titles.ru.js';

export const PROBLEM_CONTENT_TYPE = 'application/problem+json';

/** Базовый URI `type`, если PUBLIC_BASE_URL не задан (допустимо только при APP_ENV=dev): плейсхолдер 08 §2.4. */
export const DEV_PROBLEM_BASE_URL = 'https://api.example.invalid';

/** Тело RFC 9457 + расширения 08 §3.3. */
export interface ProblemBody extends ProblemExtensions {
  readonly type: string;
  readonly title: string;
  readonly status: number;
  readonly detail?: string;
  readonly instance: string;
  readonly code: ProblemCode;
  readonly requestId: string;
}

export interface NormalizedProblem {
  readonly status: number;
  readonly body: ProblemBody;
  readonly headers: Readonly<Record<string, string>>;
  /** true — ошибка сервера (5xx), логируется с уровнем error. */
  readonly internal: boolean;
}

/** `PRICE_CHANGED` → `price-changed` (08 §2.4: type = https://api.<домен>/problems/<code-kebab>). */
export function codeToKebab(code: string): string {
  return code.toLowerCase().replace(/_/g, '-');
}

export function problemTypeUri(baseUrl: string, code: string): string {
  return `${baseUrl.replace(/\/+$/, '')}/problems/${codeToKebab(code)}`;
}

/**
 * Отображение «прочих» HttpException (Nest/Express) на закрытый перечень кодов 08 §2.4 (ревью C-MN-01).
 * Статус ответа берётся из перечня кода (PROBLEM_CODE_HTTP_STATUS), поэтому пара «код — статус» всегда по контракту:
 * - 409 (ConflictException) → `VERSION_CONFLICT` (общий конфликт состояния);
 * - 423 (Locked) → `FORBIDDEN` 403 (доступ временно закрыт; специфичные OTP_LOCKED/PIN_LOCKED бросают модули);
 * - прочие 4xx (406, 408, 410, 411, 412, 414, 416, 417, 418, 428, 431 …) → `VALIDATION_FAILED` 400 (запрос не принят);
 * - 5xx без кода (502/503/504 и др.) → `INTERNAL` 500: в 08 §2.4 нет общего 503-кода (503 — только SMS_PROVIDER_ERROR,
 *   ONEC_UNAVAILABLE, QR_UNAVAILABLE, APP_READ_ONLY — их бросают модули через ProblemException с причиной).
 */
function codeForHttpStatus(status: number): ProblemCode {
  switch (status) {
    case 400: // BAD_REQUEST
    case 422: // UNPROCESSABLE_ENTITY
      return 'VALIDATION_FAILED';
    case 401: // UNAUTHORIZED
      return 'UNAUTHENTICATED';
    case 403: // FORBIDDEN
      return 'FORBIDDEN';
    case 404: // NOT_FOUND
      return 'NOT_FOUND';
    case 405: // METHOD_NOT_ALLOWED
      return 'METHOD_NOT_ALLOWED';
    case 413: // PAYLOAD_TOO_LARGE
      return 'PAYLOAD_TOO_LARGE';
    case 415: // UNSUPPORTED_MEDIA_TYPE
      return 'UNSUPPORTED_MEDIA_TYPE';
    case 409: // CONFLICT
      return 'VERSION_CONFLICT';
    case 423: // LOCKED
      return 'FORBIDDEN';
    case 429: // TOO_MANY_REQUESTS
      return 'RATE_LIMITED';
    default:
      return status >= 400 && status < 500 ? 'VALIDATION_FAILED' : 'INTERNAL';
  }
}

/** Статус ответа для кода, выбранного по «прочему» статусу: исходный, если он в перечне кода, иначе первый. */
function statusForCode(code: ProblemCode, original: number): number {
  const allowed = PROBLEM_CODE_HTTP_STATUS[code];
  return allowed.includes(original) ? original : (allowed[0] ?? HttpStatus.INTERNAL_SERVER_ERROR);
}

/**
 * Нормализует любое исключение в problem+json. Стек-трейсы, SQL, внутренние пути и тексты чужих исключений
 * в тело не попадают (08 §2.4, ASVS 16.5.1); при INTERNAL detail = «Внутренняя ошибка. Код обращения: <requestId>».
 */
export function toProblem(exception: unknown, requestId: string, baseUrl: string): NormalizedProblem {
  let code: ProblemCode;
  let status: number;
  let detail: string | undefined;
  let extensions: ProblemExtensions = {};
  let headers: Readonly<Record<string, string>> = {};

  if (exception instanceof ProblemException) {
    code = exception.code;
    status = exception.getStatus();
    detail = exception.detail;
    extensions = exception.extensions;
    headers = exception.headers;
  } else if (exception instanceof HttpException) {
    code = codeForHttpStatus(exception.getStatus());
    status = statusForCode(code, exception.getStatus());
  } else if (isBodyParserError(exception)) {
    code = codeForHttpStatus(exception.status);
    status = statusForCode(code, exception.status);
  } else {
    code = 'INTERNAL';
    status = HttpStatus.INTERNAL_SERVER_ERROR;
  }

  if (code === 'INTERNAL') detail = `Внутренняя ошибка. Код обращения: ${requestId}`;

  const body: ProblemBody = {
    ...extensions,
    type: problemTypeUri(baseUrl, code),
    title: PROBLEM_TITLES_RU[code],
    status,
    ...(detail !== undefined ? { detail } : {}),
    instance: `urn:request:${requestId}`,
    code,
    requestId,
  };
  return { status, body, headers, internal: status >= 500 && code !== 'APP_READ_ONLY' };
}

function isBodyParserError(e: unknown): e is { status: number; type: string } {
  return (
    typeof e === 'object' &&
    e !== null &&
    typeof (e as { status?: unknown }).status === 'number' &&
    typeof (e as { type?: unknown }).type === 'string'
  );
}
