import { registerDecorator, type ValidationArguments, type ValidationOptions } from 'class-validator';

/**
 * Декораторы class-validator с именами правил 08 §2.14 / contracts (`errors[].rule`): имя ограничения становится
 * `rule` в problem+json (common/validation `flattenValidationErrors`).
 */
function rule(
  name: string,
  message: string,
  test: (value: unknown, args: ValidationArguments) => boolean,
  options?: ValidationOptions,
): PropertyDecorator {
  return (target: object, propertyName: string | symbol): void => {
    registerDecorator({
      name,
      target: target.constructor,
      propertyName: String(propertyName),
      options: { message, ...options },
      validator: { validate: test },
    });
  };
}

/** Поле, которое нельзя передавать (08 §2.14 `forbidden_field`: `phone`, `roles`, `status` в PATCH /me/profile). */
export const ForbiddenField = (): PropertyDecorator =>
  rule('forbidden_field', 'Поле нельзя изменять этим запросом', (v) => v === undefined);

/** Телефон КР E.164 `+996XXXXXXXXX` (contracts `PhoneE164`, rule `phone_e164`). */
export const IsPhoneE164 = (): PropertyDecorator =>
  rule('phone_e164', 'Ожидается номер в формате +996XXXXXXXXX', (v) => typeof v === 'string' && /^\+996\d{9}$/.test(v));

/** PIN 4–6 цифр (contracts `pattern ^\d{4,6}$`; rule `pin_weak` — 08 §4.2.1, §4.3.5). */
export const IsPinFormat = (): PropertyDecorator =>
  rule('pin_weak', 'PIN — от 4 до 6 цифр', (v) => typeof v === 'string' && /^\d{4,6}$/.test(v));

/** Код OTP — 6 цифр (rule `otp_format`, 08 §4.3.3). */
export const IsOtpCode = (): PropertyDecorator =>
  rule('otp_format', 'Код — 6 цифр', (v) => typeof v === 'string' && /^\d{6}$/.test(v));

/** Год рождения — целое ≥ 1920 (верхняя граница «текущий − 14» проверяется сервисом по часам `CLOCK`). */
export const IsBirthYearShape = (): PropertyDecorator =>
  rule(
    'birth_year_range',
    'Год рождения — целое число не меньше 1920',
    (v) => typeof v === 'number' && Number.isInteger(v) && v >= 1920,
  );

/** UUID или `null` (обязательное nullable-поле, например `defaultWarehouseId`). */
export const IsUuidOrNull = (): PropertyDecorator =>
  rule(
    'uuid',
    'Ожидается UUID или null',
    (v) =>
      v === null ||
      (typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v)),
  );
