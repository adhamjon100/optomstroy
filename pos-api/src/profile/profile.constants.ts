/** Заголовок step-up (08 §2.12; contracts/openapi `parameters.StepUpToken`). */
export const STEP_UP_TOKEN_HEADER = 'x-step-up-token'; // check-secrets: allow — имя поля/заголовка, не секрет

/**
 * Окно «step-up считается выполненным OTP-входом» (09 §7.3, §7.6, §9.5 п. 3; 08 §4.3.5 — первый PIN сотрудника по
 * приглашению): 15 мин с создания сессии по OTP (`sessions.issued_at`, `amr` содержит `sms`).
 */
export const OTP_SESSION_STEP_UP_WINDOW_MS = 15 * 60_000;

/** Узкие значения `operation` step-up профиля (08 §2.12, таблица «Значения operation и область scope»). */
export const PROFILE_STEP_UP = {
  pinSet: 'profile.pin.set',
  biometricsToggle: 'profile.biometrics.toggle',
  consentRevoke: 'profile.consent.revoke',
  phoneChange: 'profile.phone.change',
} as const;
export type ProfileStepUpOperation = (typeof PROFILE_STEP_UP)[keyof typeof PROFILE_STEP_UP];

/**
 * Справочник «Сфера деятельности» (Q-165, Q-203 — открыты): коды по ключам ARB `reg_activity_*`
 * (contracts/l10n/app_ru.arb: plumber, foreman, reseller, installer, private, other); «Не указывать» = `null`.
 * Расхождение с примером 08 (`plumbing`) — docs/stages/D_spec_questions.md (RG-03).
 */
export const ACTIVITY_SPHERE_CODES = ['plumber', 'foreman', 'reseller', 'installer', 'private', 'other'] as const;
export type ActivitySphereCode = (typeof ACTIVITY_SPHERE_CODES)[number];

/** Нижняя граница года рождения и минимальный возраст (ядро §19.3; Q-161). */
export const BIRTH_YEAR_MIN = 1920;
export const MIN_AGE_YEARS = 14;

/** ФИО: 2…150 символов после trim (CHECK `user_profiles_full_name_chk`; контракт — maxLength 150). */
export const FULL_NAME_MIN = 2;
export const FULL_NAME_MAX = 150;

/** PIN `customer` — 4 цифры минимум (09 §9.6); `staff` — `PIN_MIN_LENGTH_STAFF` (6 по умолчанию). */
export const PIN_MIN_LENGTH_CUSTOMER = 4;

/**
 * `idleLockMinutes` (08 §4.3.4): 5…30, для `staff` больше `SESSION_IDLE_LOCK_MINUTES` нельзя; для `customer`
 * idle-блокировка «не применяется (опционально 60 мин)» (09 §8.8) — верхняя граница 60 (D_spec_questions PR-04).
 */
export const IDLE_LOCK_MIN = 5;
export const IDLE_LOCK_MAX_CUSTOMER = 60;
