import { ValidateBy, type ValidationOptions } from 'class-validator';
import { normalizeKgPhone } from './phone.js';

/**
 * Ограничения class-validator с именами правил 08 §2.14 (`rule` в `errors[]` Problem = имя ограничения):
 * `phone_e164`, `otp_format`, `uuid`, `pin_format`, `max_length`, `enum`, `purpose`, `method`, `operation`,
 * `forbidden_field`, `type`.
 */

const UUID_ANY = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function IsKgPhone(options?: ValidationOptions): PropertyDecorator {
  return ValidateBy(
    {
      name: 'phone_e164',
      validator: {
        validate: (v: unknown) => normalizeKgPhone(v) !== null,
        defaultMessage: () => 'Ожидается мобильный номер КР в формате +996XXXXXXXXX',
      },
    },
    options,
  );
}

export function IsOtpCode(options?: ValidationOptions): PropertyDecorator {
  return ValidateBy(
    {
      name: 'otp_format',
      validator: {
        validate: (v: unknown) => typeof v === 'string' && /^\d{6}$/.test(v),
        defaultMessage: () => 'Код — ровно 6 цифр',
      },
    },
    options,
  );
}

export function IsUuidRule(options?: ValidationOptions): PropertyDecorator {
  return ValidateBy(
    {
      name: 'uuid',
      validator: {
        validate: (v: unknown) => typeof v === 'string' && UUID_ANY.test(v.toLowerCase()),
        defaultMessage: () => 'Ожидается UUID',
      },
    },
    options,
  );
}

export function IsPinFormat(options?: ValidationOptions): PropertyDecorator {
  return ValidateBy(
    {
      name: 'pin_format',
      validator: {
        validate: (v: unknown) => typeof v === 'string' && /^\d{4,6}$/.test(v),
        defaultMessage: () => 'PIN — 4–6 цифр',
      },
    },
    options,
  );
}

/** Строка длиной `min…max` без управляющих символов (rule `max_length`). */
export function IsBoundedText(min: number, max: number, options?: ValidationOptions): PropertyDecorator {
  return ValidateBy(
    {
      name: 'max_length',
      validator: {
        validate: (v: unknown) =>
          typeof v === 'string' &&
          v.trim().length >= min &&
          v.length <= max &&
          // eslint-disable-next-line no-control-regex
          !/[\u0000-\u001F\u007F]/.test(v),
        defaultMessage: () => `Строка ${min}…${max} символов без управляющих символов`,
      },
    },
    options,
  );
}

/** Значение из перечня; имя правила задаётся (`enum`, `purpose`, `method`, `operation`). */
export function IsOneOf(values: readonly string[], rule: string, options?: ValidationOptions): PropertyDecorator {
  return ValidateBy(
    {
      name: rule,
      constraints: [values],
      validator: {
        validate: (v: unknown) => typeof v === 'string' && values.includes(v),
        defaultMessage: () => `Допустимые значения: ${values.join(', ')}`,
      },
    },
    options,
  );
}

/** Поле запрещено в теле (08 §4.1.3: `kind`, `amr` → rule `forbidden_field`). Срабатывает, если поле передано. */
export function ForbiddenField(options?: ValidationOptions): PropertyDecorator {
  return ValidateBy(
    {
      name: 'forbidden_field',
      validator: {
        validate: (v: unknown) => v === undefined,
        defaultMessage: () => 'Поле не принимается',
      },
    },
    options,
  );
}

export function IsBool(options?: ValidationOptions): PropertyDecorator {
  return ValidateBy(
    {
      name: 'type',
      validator: { validate: (v: unknown) => typeof v === 'boolean', defaultMessage: () => 'Ожидается boolean' },
    },
    options,
  );
}
