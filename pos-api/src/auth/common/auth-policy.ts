import { Inject, Injectable, Logger, Optional } from '@nestjs/common';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { SettingsReader } from '../../common/settings/settings-reader.js';

/**
 * Эффективная политика OTP/сессий/PIN (09 §5.3–§5.4, §8.2, §8.8, §9.6; D-10, D-12, D-48). Источник — env 16 §4.3;
 * ключи `app_settings` 07 §5.59 `otp.ttl_seconds`, `otp.max_attempts`, `session.staff_refresh_days` переопределяют
 * env (RM-D-001 п. 1 «параметры из app_settings»), если значение — целое в коридоре 09 (иначе игнорируется).
 */
export interface OtpPolicy {
  readonly ttlSeconds: number;
  readonly maxAttempts: number;
  readonly resendCooldownSeconds: number;
  readonly maxPerPhone15m: number;
  readonly maxPerPhone24h: number;
  readonly maxPerIp10m: number;
  readonly maxPerIp24h: number;
  readonly maxPerDevice10m: number;
  readonly maxPerDevice24h: number;
  readonly globalPerMinute: number;
  readonly lockAfterLockedCodes: number;
  readonly phonePauseMinutes: number;
  /** Окно сетевого повтора verify (09 §5.6). */
  readonly replayWindowSeconds: number;
  readonly codeLength: number;
}

export interface SessionPolicy {
  readonly refreshTtlStaffDays: number;
  readonly refreshTtlCustomerDays: number;
  readonly idleStaffHours: number;
  readonly idleCustomerDays: number;
  readonly graceSeconds: number;
  readonly idleLockMinutes: number;
  /** Лимит одновременных устройств (09 §8.2: staff 3, customer 5 — предложение, Q-154). */
  readonly maxSessionsStaff: number;
  readonly maxSessionsCustomer: number;
  readonly registrationTokenTtlSeconds: number;
  readonly stepUpTtlSeconds: number;
  readonly pinMaxAttempts: number;
}

export interface EffectivePolicy {
  readonly otp: OtpPolicy;
  readonly session: SessionPolicy;
}

/** Срок `registration_token` — 15 мин (09 §7.3, ядро §17.2). */
export const REGISTRATION_TOKEN_TTL_SECONDS = 900;
/** Срок `stepUpToken` — 15 мин (ядро §17.2, §18.2 п. 6). */
export const STEP_UP_TTL_SECONDS = 900;

function intIn(v: unknown, min: number, max: number): number | undefined {
  const n = typeof v === 'string' && v.trim() !== '' ? Number(v) : v;
  return typeof n === 'number' && Number.isInteger(n) && n >= min && n <= max ? n : undefined;
}

@Injectable()
export class AuthPolicyService {
  private readonly logger = new Logger('auth');

  constructor(
    @Inject(APP_CONFIG) readonly config: AppConfig,
    @Optional() private readonly settings?: SettingsReader,
  ) {}

  /** Политика без `app_settings` (синхронно; используется там, где запрос в БД не нужен). */
  base(): EffectivePolicy {
    const c = this.config;
    return {
      otp: {
        ttlSeconds: c.OTP_TTL_SECONDS,
        maxAttempts: c.OTP_MAX_VERIFY_ATTEMPTS,
        resendCooldownSeconds: c.OTP_RESEND_COOLDOWN_SECONDS,
        maxPerPhone15m: c.OTP_MAX_SENDS_PER_PHONE_15M,
        maxPerPhone24h: c.OTP_MAX_SENDS_PER_PHONE_24H,
        maxPerIp10m: c.OTP_MAX_SENDS_PER_IP_10M,
        maxPerIp24h: c.OTP_MAX_SENDS_PER_IP_24H,
        maxPerDevice10m: c.OTP_MAX_SENDS_PER_DEVICE_10M,
        maxPerDevice24h: c.OTP_MAX_SENDS_PER_DEVICE_24H,
        globalPerMinute: c.OTP_GLOBAL_PER_MIN,
        lockAfterLockedCodes: c.OTP_LOCK_AFTER_LOCKED_CODES,
        phonePauseMinutes: c.OTP_PHONE_PAUSE_MINUTES,
        replayWindowSeconds: 60,
        codeLength: 6,
      },
      session: {
        refreshTtlStaffDays: c.AUTH_REFRESH_TTL_STAFF_DAYS,
        refreshTtlCustomerDays: c.AUTH_REFRESH_TTL_CUSTOMER_DAYS,
        idleStaffHours: c.AUTH_REFRESH_IDLE_STAFF_HOURS,
        idleCustomerDays: c.AUTH_REFRESH_IDLE_CUSTOMER_DAYS,
        graceSeconds: c.AUTH_REFRESH_GRACE_SECONDS,
        idleLockMinutes: c.SESSION_IDLE_LOCK_MINUTES,
        maxSessionsStaff: 3,
        maxSessionsCustomer: 5,
        registrationTokenTtlSeconds: REGISTRATION_TOKEN_TTL_SECONDS,
        stepUpTtlSeconds: STEP_UP_TTL_SECONDS,
        pinMaxAttempts: c.PIN_MAX_ATTEMPTS,
      },
    };
  }

  /** Политика с переопределениями `app_settings` (кэш SettingsReader 10 с; ошибка БД → env). */
  async effective(): Promise<EffectivePolicy> {
    const base = this.base();
    if (!this.settings) return base;
    try {
      const [ttl, attempts, staffDays] = await Promise.all([
        this.settings.get('otp.ttl_seconds'),
        this.settings.get('otp.max_attempts'),
        this.settings.get('session.staff_refresh_days'),
      ]);
      return {
        otp: {
          ...base.otp,
          ttlSeconds: intIn(ttl, 180, 600) ?? base.otp.ttlSeconds,
          maxAttempts: intIn(attempts, 3, 10) ?? base.otp.maxAttempts,
        },
        session: {
          ...base.session,
          refreshTtlStaffDays: intIn(staffDays, 1, 30) ?? base.session.refreshTtlStaffDays,
        },
      };
    } catch (e) {
      this.logger.warn({ event: 'auth.policy.settings_unavailable', err: e }, 'app_settings недоступны: env');
      return base;
    }
  }
}
