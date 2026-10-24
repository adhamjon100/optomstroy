import { Transform } from 'class-transformer';
import { ValidateBy, type ValidationOptions } from 'class-validator';
import { normalizePhone } from './phone.js';

const PHONE_E164 = /^\+996\d{9}$/;

/** Телефон E.164 КР (08 §2.14, rule `phone_e164`): пробелы/скобки/дефисы удаляются до проверки. */
export function IsPhoneE164(options?: ValidationOptions): PropertyDecorator {
  return ValidateBy(
    {
      name: 'phone_e164',
      validator: {
        validate: (v: unknown) => typeof v === 'string' && PHONE_E164.test(v),
        defaultMessage: () => 'Телефон в формате +996XXXXXXXXX.',
      },
    },
    options,
  );
}

export const NormalizePhone = (): PropertyDecorator => Transform(({ value }) => normalizePhone(value));

/** Обрезка пробелов строк (08 §2.14 «обрезка пробелов»). */
export const Trim = (): PropertyDecorator =>
  Transform(({ value }: { value: unknown }) => (typeof value === 'string' ? value.trim() : value));

/**
 * Поле, запрещённое в R1 (`discountLimitPercent`, `warehouseIds` — 08 §4.18.1, 11 SEC-043, ядро §22.10): наличие
 * в теле → `400 VALIDATION_FAILED` rule `forbidden_field` (а не `additional_properties`).
 */
export function ForbiddenField(): PropertyDecorator {
  return ValidateBy({
    name: 'forbidden_field',
    validator: {
      validate: (v: unknown) => v === undefined,
      defaultMessage: () => 'Поле не принимается в R1 (лимиты и склады задаются по ролям).',
    },
  });
}

/** Причина ≥ 5 символов после обрезки (11 SEC-076, rule `reason_required`). */
export function IsReason(options?: ValidationOptions): PropertyDecorator {
  return ValidateBy(
    {
      name: 'reason_required',
      validator: {
        validate: (v: unknown) => typeof v === 'string' && v.trim().length >= 5 && v.length <= 500,
        defaultMessage: () => 'Укажите причину (от 5 до 500 символов).',
      },
    },
    options,
  );
}

/** Отсутствие управляющих символов в строке (08 §2.14). */
export function NoControlChars(options?: ValidationOptions): PropertyDecorator {
  return ValidateBy(
    {
      name: 'control_chars',
      validator: {
        // eslint-disable-next-line no-control-regex
        validate: (v: unknown) => typeof v !== 'string' || !/[\u0000-\u001f\u007f]/.test(v),
        defaultMessage: () => 'Строка содержит управляющие символы.',
      },
    },
    options,
  );
}
