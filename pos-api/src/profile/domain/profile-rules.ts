import { ProblemException, type ProblemFieldError } from '../../common/problem-details/problem.exception.js';
import {
  ACTIVITY_SPHERE_CODES,
  BIRTH_YEAR_MIN,
  FULL_NAME_MAX,
  FULL_NAME_MIN,
  MIN_AGE_YEARS,
  PIN_MIN_LENGTH_CUSTOMER,
} from '../profile.constants.js';

/**
 * Правила полей профиля, общие для `POST /registration/complete` и `PATCH /me/profile` (08 §4.2.1, §4.3.2; 09 §7.1,
 * §9.6; ядро §19.3). Возвращают `ProblemFieldError` (08 §3.3) — вызывающий собирает их в один ответ 400.
 */

/** Буквы кириллицы/латиницы (вкл. ө, ү, ң), слова через пробел, дефис или апостроф; без цифр (09 §7.1, T-REG-003). */
const FULL_NAME_RE = /^[\p{Script=Cyrillic}\p{Script=Latin}]+(?:[ '’-][\p{Script=Cyrillic}\p{Script=Latin}]+)*$/u;

/** Нормализация ФИО: trim и схлопывание пробелов. */
export function normalizeFullName(raw: string): string {
  return raw.trim().replace(/\s+/g, ' ');
}

export function fullNameErrors(value: string, field = 'fullName'): ProblemFieldError[] {
  const v = normalizeFullName(value);
  if (v.length < FULL_NAME_MIN || v.length > FULL_NAME_MAX) {
    return [
      {
        field,
        message: `ФИО: от ${FULL_NAME_MIN} до ${FULL_NAME_MAX} символов`,
        rule: 'full_name_length',
        params: { min: FULL_NAME_MIN, max: FULL_NAME_MAX },
      },
    ];
  }
  if (!FULL_NAME_RE.test(v)) {
    return [{ field, message: 'Используйте только буквы, пробел, дефис и апостроф', rule: 'full_name_format' }];
  }
  return [];
}

/** Верхняя граница года рождения: текущий год − 14 (ядро §19.3, до ответа Q-161). */
export function maxBirthYear(now: Date): number {
  return now.getUTCFullYear() - MIN_AGE_YEARS;
}

export function birthYearErrors(year: number, now: Date, field = 'birthYear'): ProblemFieldError[] {
  const max = maxBirthYear(now);
  if (!Number.isInteger(year) || year < BIRTH_YEAR_MIN || year > max) {
    return [
      {
        field,
        message: `Введите год от ${BIRTH_YEAR_MIN} до ${max}`,
        rule: 'birth_year_range',
        params: { min: BIRTH_YEAR_MIN, max },
      },
    ];
  }
  return [];
}

export function activitySphereErrors(code: string | null | undefined, field = 'activitySphere'): ProblemFieldError[] {
  if (code === null || code === undefined) return [];
  if (!(ACTIVITY_SPHERE_CODES as readonly string[]).includes(code)) {
    return [
      {
        field,
        message: 'Неизвестное значение справочника сфер деятельности',
        rule: 'activity_sphere',
        params: { allowed: [...ACTIVITY_SPHERE_CODES] },
      },
    ];
  }
  return [];
}

export type PinWeakReason = 'length' | 'repeated' | 'sequence' | 'birth_year';

/** Минимальная длина PIN по виду учётной записи (09 §9.6: `staff` — `PIN_MIN_LENGTH_STAFF`, `customer` — 4). */
export function pinMinLength(kind: 'staff' | 'customer', staffMinLength: number): number {
  return kind === 'staff' ? Math.max(PIN_MIN_LENGTH_CUSTOMER, Math.min(6, staffMinLength)) : PIN_MIN_LENGTH_CUSTOMER;
}

/**
 * Политика PIN (09 §9.6, BIO-018; T-BIO-011): 4–6 цифр, длина не меньше политики роли, запрещены одинаковые цифры
 * (`0000`), монотонные последовательности (`1234`, `654321`) и год рождения пользователя. `null` — PIN допустим.
 */
export function pinWeakReason(pin: string, minLength: number, birthYear?: number | null): PinWeakReason | null {
  if (!/^\d{4,6}$/.test(pin) || pin.length < minLength) return 'length';
  if (/^(\d)\1+$/.test(pin)) return 'repeated';
  const digits = [...pin].map(Number);
  const step = (digits[1] ?? 0) - (digits[0] ?? 0);
  if ((step === 1 || step === -1) && digits.every((d, i) => i === 0 || d - (digits[i - 1] ?? 0) === step)) {
    return 'sequence';
  }
  if (birthYear !== null && birthYear !== undefined && pin.includes(String(birthYear))) return 'birth_year';
  return null;
}

export function pinErrors(
  pin: string,
  minLength: number,
  birthYear: number | null | undefined,
  field: string,
): ProblemFieldError[] {
  const reason = pinWeakReason(pin, minLength, birthYear);
  if (reason === null) return [];
  return [
    {
      field,
      message: 'Выберите PIN без повторяющихся или последовательных цифр',
      rule: 'pin_weak',
      params: { reason, minLength },
    },
  ];
}

/** 400/422 VALIDATION_FAILED с перечнем ошибок полей. */
export function validationProblem(
  errors: readonly ProblemFieldError[],
  status: 400 | 422 = 400,
  detail = 'Запрос не прошёл проверку.',
): ProblemException {
  return new ProblemException('VALIDATION_FAILED', { status, detail, errors });
}

export function throwIfErrors(errors: readonly ProblemFieldError[], status: 400 | 422 = 400): void {
  if (errors.length > 0) throw validationProblem(errors, status);
}

/** Шаг «защита входа» не выполнен (08 API-182, AC-API-182; 09 REG-038): rule `login_protection_required`. */
export function loginProtectionRequired(status: 400 | 422, message: string): ProblemException {
  return validationProblem(
    [{ field: 'security', message, rule: 'login_protection_required' }],
    status,
    'Настройте защиту входа: PIN или биометрию устройства.',
  );
}
