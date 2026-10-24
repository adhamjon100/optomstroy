import { ValidationPipe, type ValidationError } from '@nestjs/common';
import { ProblemException, type ProblemFieldError } from '../problem-details/problem.exception.js';

/** class-validator → `errors[]` Problem (08 §3.3, §2.14): поле, сообщение, правило (имя ограничения). */
export function flattenValidationErrors(errors: readonly ValidationError[], parent = ''): ProblemFieldError[] {
  const out: ProblemFieldError[] = [];
  for (const e of errors) {
    const field = parent
      ? /^\d+$/.test(e.property)
        ? `${parent}[${e.property}]`
        : `${parent}.${e.property}`
      : e.property;
    for (const [rule, message] of Object.entries(e.constraints ?? {})) {
      out.push({ field, message, rule: rule === 'whitelistValidation' ? 'additional_properties' : rule });
    }
    if (e.children?.length) out.push(...flattenValidationErrors(e.children, field));
  }
  return out;
}

/**
 * Глобальная валидация DTO: `additionalProperties:false` для запросов (08 §2.11, §2.14) — лишние поля → 400
 * VALIDATION_FAILED; преобразование типов включено.
 */
export function createValidationPipe(): ValidationPipe {
  return new ValidationPipe({
    whitelist: true,
    forbidNonWhitelisted: true,
    transform: true,
    stopAtFirstError: false,
    exceptionFactory: (errors) =>
      new ProblemException('VALIDATION_FAILED', {
        status: 400,
        detail: 'Запрос не прошёл проверку.',
        errors: flattenValidationErrors(errors),
      }),
  });
}
