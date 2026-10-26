import { Inject, Injectable, Logger } from '@nestjs/common';
import { parse as uuidParse } from 'uuid';
import type { AuditContext } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { OtpHmacService } from '../../common/crypto/otp-hmac.service.js';
import { generateOtpCode } from '../../common/crypto/random.js';
import { DRIZZLE, type Database } from '../../common/db/database.module.js';
import { newId } from '../../common/ids/uuid.js';
import { maskPhone } from '../../common/logging/redaction.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import {
  type RateLimitResult,
  type RateLimitRule,
  type RateLimitScope,
  RateLimitService,
} from '../../common/rate-limit/rate-limit.service.js';
import type { SmsTemplateKey } from '../../integrations/sms/sms-gateway.js';
import { AuthPolicyService, type OtpPolicy } from '../common/auth-policy.js';
import { type OtpChallengeRow, OtpChallengesRepository, type OtpPurpose } from './otp-challenges.repository.js';
import { OtpCircuitBreaker } from './otp-circuit-breaker.js';
import { otpPhoneSubject, releaseOtpPhoneQuota } from './otp-quota.js';
import { OTP_PROVIDER, type OtpProvider, type PreparedDelivery } from './otp.provider.js';

export interface IssueOtpInput {
  readonly phoneE164: string;
  readonly purpose: OtpPurpose;
  readonly deviceKey: string;
  readonly ip: string | null;
  readonly requestId: string | null;
  /** Аккаунт на момент запроса (09 §4.1: фиксируется в `otp_challenges.user_id`, клиенту не раскрывается). */
  readonly userId: string | null;
  readonly audit: AuditContext;
}

export interface IssuedChallenge {
  readonly challengeId: string;
  readonly resendAfterSec: number;
  readonly otpTtlSec: number;
  readonly codeLength: number;
  readonly phoneMasked: string;
  readonly expiresAt: Date;
}

/** Итог проверки кода (09 §4.3 «Порядок проверок»; AUTH-051). Ошибочные итоги бросаются после COMMIT. */
export type OtpCheck =
  | { readonly kind: 'not_found' }
  | { readonly kind: 'device_mismatch' }
  | { readonly kind: 'expired' }
  | { readonly kind: 'locked'; readonly retryAfter: number }
  | { readonly kind: 'invalid'; readonly attemptsLeft: number; readonly lockedNow: boolean }
  | { readonly kind: 'ok'; readonly challenge: OtpChallengeRow }
  | { readonly kind: 'replay'; readonly challenge: OtpChallengeRow };

const TEMPLATE_BY_PURPOSE: Readonly<Record<OtpPurpose, SmsTemplateKey>> = {
  login_or_register: 'otp_login',
  step_up: 'otp_step_up',
  phone_change_old: 'otp_phone_change',
  phone_change_new: 'otp_phone_change',
  customer_link: 'otp_customer_link',
};

/** Субъект глобального лимита RL-OTP-GLOBAL (`otp_global_1m`, весь сервис). */
export const OTP_GLOBAL_SUBJECT = 'global';

const PHONE_SCOPES: ReadonlySet<RateLimitScope> = new Set<RateLimitScope>(['otp_phone_15m', 'otp_phone_24h']);
const CLIENT_SCOPES: ReadonlySet<RateLimitScope> = new Set<RateLimitScope>([
  'otp_ip_10m',
  'otp_ip_24h',
  'otp_device_10m',
  'otp_device_24h',
]);

/**
 * OtpService (RM-D-001; D-10, D-47; 09 §5): генерация 6-значного кода CSPRNG, хранение `HMAC-SHA-256(pepper,
 * challenge_id:code)` с `pepper_version`, TTL, попытки, cooldown, лимиты номера/IP/устройства/глобальный,
 * пауза номера после 3 аннулированных кодов; доставка — через `OtpProvider`. Код не попадает в логи, аудит и БД.
 */
@Injectable()
export class OtpService {
  private readonly logger = new Logger('auth');

  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    @Inject(CLOCK) private readonly clock: Clock,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    @Inject(OTP_PROVIDER) private readonly provider: OtpProvider,
    private readonly policy: AuthPolicyService,
    private readonly challenges: OtpChallengesRepository,
    private readonly hmac: OtpHmacService,
    private readonly rateLimit: RateLimitService,
    private readonly breaker: OtpCircuitBreaker,
    private readonly audit: AuditService,
  ) {}

  /**
   * Тестовый режим 09 §5.8: только `APP_ENV ∈ {dev, staging}` и номер из `AUTH_OTP_TEST_PHONES`.
   * Значение `*` (любой номер) — только `APP_ENV=dev`: локальное демо на тестовых данных (ADR-109); в staging и prod
   * запрещено проверкой конфигурации (env.schema.ts).
   */
  isTestPhone(phoneE164: string): boolean {
    const c = this.config;
    if (!c.AUTH_OTP_TEST_MODE || (c.APP_ENV !== 'dev' && c.APP_ENV !== 'staging')) return false;
    if (!c.AUTH_OTP_TEST_CODE || !/^\d{6}$/.test(c.AUTH_OTP_TEST_CODE)) return false;
    const phones = (c.AUTH_OTP_TEST_PHONES ?? '').split(',').map((s) => s.trim());
    if (phones.includes('*')) return c.APP_ENV === 'dev';
    return phones.includes(phoneE164);
  }

  /** Сырой номер в `rate_limit_counters.subject` запрещён (07 §5.12): только HMAC-псевдоним. */
  phoneSubject(phoneE164: string): string {
    return otpPhoneSubject(this.hmac, phoneE164);
  }

  phoneRules(phoneE164: string, p: OtpPolicy): RateLimitRule[] {
    const subject = this.phoneSubject(phoneE164);
    return [
      { scope: 'otp_phone_15m', subject, limit: p.maxPerPhone15m },
      { scope: 'otp_phone_24h', subject, limit: p.maxPerPhone24h },
    ];
  }

  /**
   * Лимиты клиента RL-OTP-SEND-IP (20 / 10 мин, 100 / 24 ч) и RL-OTP-SEND-DEV (5 / 10 мин, 20 / 24 ч) — счётчики
   * `rate_limit_counters` (08 §2.9 «Postgres»; миграция 0003, DQ-01). Без IP (нет адреса клиента) — только устройство.
   */
  clientRules(input: Pick<IssueOtpInput, 'ip' | 'deviceKey'>, p: OtpPolicy): RateLimitRule[] {
    const rules: RateLimitRule[] = [];
    if (input.ip) {
      rules.push({ scope: 'otp_ip_10m', subject: input.ip, limit: p.maxPerIp10m });
      rules.push({ scope: 'otp_ip_24h', subject: input.ip, limit: p.maxPerIp24h });
    }
    rules.push({ scope: 'otp_device_10m', subject: input.deviceKey, limit: p.maxPerDevice10m });
    rules.push({ scope: 'otp_device_24h', subject: input.deviceKey, limit: p.maxPerDevice24h });
    return rules;
  }

  /**
   * Выпуск кода (09 §4.2, §5.3–§5.4). Порядок отказов: circuit-breaker → cooldown (429 OTP_RATE_LIMITED) →
   * пауза номера (423 OTP_LOCKED) → лимиты номера (429 OTP_RATE_LIMITED) → лимиты IP/устройства (429
   * RATE_LIMITED) → глобальный лимит (503 SMS_PROVIDER_ERROR). Все лимиты — фиксированные окна
   * `rate_limit_counters` (переживают рестарт и общие для реплик), учитываются атомарно одним `consume`:
   * отказ по любому правилу не расходует ни одну квоту.
   */
  async issue(input: IssueOtpInput): Promise<IssuedChallenge> {
    const policy = (await this.policy.effective()).otp;
    if (this.breaker.isOpen() || (this.provider.blocked !== undefined && (await this.provider.blocked()))) {
      throw smsProviderError();
    }
    const now = this.clock.now();
    const testMode = this.isTestPhone(input.phoneE164);
    const code = testMode ? (this.config.AUTH_OTP_TEST_CODE as string) : generateOtpCode();
    const challengeId = newId();
    const templateKey = TEMPLATE_BY_PURPOSE[input.purpose];

    type Outcome =
      | { kind: 'ok'; prepared: PreparedDelivery | null; expiresAt: Date }
      | { kind: 'cooldown'; retryAfter: number }
      | { kind: 'paused'; retryAfter: number }
      | { kind: 'phone_limit'; retryAfter: number; scope: string }
      | { kind: 'client_limit'; retryAfter: number; scope: string }
      | { kind: 'global' };

    const outcome = await this.db.transaction(async (tx): Promise<Outcome> => {
      await this.challenges.lockPhone(input.phoneE164, input.purpose, tx);
      const recent = await this.challenges.recentDelivered(
        input.phoneE164,
        input.purpose,
        Math.max(1, policy.lockAfterLockedCodes),
        tx,
      );
      const last = recent[0];
      if (last) {
        const cooldownLeft = Math.ceil(
          (last.createdAt.getTime() + policy.resendCooldownSeconds * 1000 - now.getTime()) / 1000,
        );
        if (cooldownLeft > 0) return { kind: 'cooldown', retryAfter: cooldownLeft };
      }
      if (recent.length >= policy.lockAfterLockedCodes && recent.every((r) => r.status === 'locked')) {
        // Отсчёт — от блокировки последнего кода (`locked_at`, миграция 0003; DQ-03 / auth A-07). Строки,
        // заблокированные до 0003 без отметки, — от выпуска кода (`created_at`).
        const pauseEnd = (last.lockedAt ?? last.createdAt).getTime() + policy.phonePauseMinutes * 60_000;
        if (pauseEnd > now.getTime()) {
          return { kind: 'paused', retryAfter: Math.ceil((pauseEnd - now.getTime()) / 1000) };
        }
      }
      const consumed = await this.rateLimit.consume(
        [
          ...this.phoneRules(input.phoneE164, policy),
          ...this.clientRules(input, policy),
          { scope: 'otp_global_1m', subject: OTP_GLOBAL_SUBJECT, limit: policy.globalPerMinute },
        ],
        tx,
      );
      if (!consumed.allowed) return classifyDenial(consumed);

      await this.challenges.retireActive(input.phoneE164, input.purpose, now, tx);
      const expiresAt = new Date(now.getTime() + policy.ttlSeconds * 1000);
      await this.challenges.insert(
        {
          id: challengeId,
          phoneE164: input.phoneE164,
          userId: input.userId,
          purpose: input.purpose,
          codeHmac: this.hmac.codeHmac(challengeId, code),
          // 07 §5.11 `salt NOT NULL`; по 09 §5.2 соль = challenge_id (входит в сообщение HMAC) — D_spec_questions F-03.
          salt: Buffer.from(uuidParse(challengeId)),
          pepperVersion: this.hmac.currentVersion,
          expiresAt,
          attempts: 0,
          status: 'sent',
          deviceKey: input.deviceKey,
          ip: input.ip,
          requestId: input.requestId,
          createdAt: now,
          updatedAt: now,
        },
        tx,
      );
      let prepared: PreparedDelivery | null = null;
      if (!testMode) {
        prepared = await this.provider.prepare(
          { challengeId, phoneE164: input.phoneE164, templateKey, requestId: input.requestId },
          code,
          now,
          tx,
        );
        await this.challenges.update(challengeId, { smsOutboxId: prepared.smsOutboxId }, now, tx);
      }
      await this.audit.write(
        input.audit,
        {
          action: 'auth.otp.sent',
          entityType: 'otp_challenge',
          entityId: challengeId,
          after: { purpose: input.purpose, phone: input.phoneE164, testMode, delivery: testMode ? 'none' : 'queued' },
        },
        tx,
      );
      return { kind: 'ok', prepared, expiresAt };
    });

    switch (outcome.kind) {
      case 'ok':
        break;
      case 'cooldown':
        await this.rateLimitedAudit(input, 'otp_resend_cooldown');
        throw new ProblemException('OTP_RATE_LIMITED', {
          detail: 'Код уже отправлен. Повторная отправка — позже.',
          retryAfter: outcome.retryAfter,
        });
      case 'paused':
        await this.rateLimitedAudit(input, 'otp_phone_pause');
        throw new ProblemException('OTP_LOCKED', {
          detail: 'Слишком много неверных попыток. Запросите новый код позже.',
          retryAfter: outcome.retryAfter,
        });
      case 'phone_limit':
        await this.rateLimitedAudit(input, outcome.scope);
        throw new ProblemException('OTP_RATE_LIMITED', {
          detail: 'Слишком много запросов кода на этот номер.',
          retryAfter: outcome.retryAfter,
        });
      case 'client_limit':
        await this.rateLimitedAudit(input, outcome.scope);
        throw new ProblemException('RATE_LIMITED', {
          detail: 'Слишком много запросов. Повторите позже.',
          retryAfter: outcome.retryAfter,
        });
      case 'global':
        this.breaker.open('global_limit', 5);
        await this.rateLimitedAudit(input, 'otp_global_1m');
        throw smsProviderError();
    }

    this.logger.log(
      {
        event: testMode ? 'otp.test_mode' : 'otp.requested',
        challengeId,
        purpose: input.purpose,
        phoneMasked: maskPhone(input.phoneE164),
        deviceId: input.deviceKey,
        requestId: input.requestId ?? undefined,
      },
      testMode ? 'otp.test_mode' : 'otp.requested',
    );
    if (outcome.prepared) {
      const createdAt = now;
      this.provider.dispatch(
        outcome.prepared,
        { challengeId, phoneE164: input.phoneE164, templateKey, requestId: input.requestId },
        code,
        { onFailed: () => this.releasePhoneQuota(input.phoneE164, createdAt) },
      );
    }
    return {
      challengeId,
      resendAfterSec: policy.resendCooldownSeconds,
      otpTtlSec: policy.ttlSeconds,
      codeLength: policy.codeLength,
      phoneMasked: maskPhone(input.phoneE164),
      expiresAt: outcome.expiresAt,
    };
  }

  /**
   * Проверка кода в транзакции вызывающего (09 §4.3 порядок AUTH-051; §5.3; §5.6). Мутации (`attempts`,
   * `status`, `verified_at`, `replayed_at`) выполняются в `tx`; вызывающий фиксирует транзакцию и бросает
   * ошибку итога после COMMIT (иначе счётчик попыток откатился бы — «бесплатная попытка»).
   */
  async check(
    tx: DbExecutor,
    args: {
      readonly challengeId: string;
      readonly code: string;
      readonly deviceKey: string;
      readonly purpose: OtpPurpose;
      readonly userId?: string;
      readonly allowReplay: boolean;
    },
  ): Promise<OtpCheck> {
    const policy = (await this.policy.effective()).otp;
    const now = this.clock.now();
    const ch = await this.challenges.findById(args.challengeId, tx, true);
    if (!ch || ch.purpose !== args.purpose || (args.userId !== undefined && ch.userId !== args.userId)) {
      return { kind: 'not_found' };
    }
    if (ch.deviceKey !== args.deviceKey) {
      // Попытка учитывается, челлендж не потребляется (09 §4.3 п. 2).
      if (ch.status === 'sent') {
        const attempts = ch.attempts + 1;
        await this.challenges.update(
          ch.id,
          { attempts, ...(attempts >= policy.maxAttempts ? { status: 'locked' as const } : {}) },
          now,
          tx,
        );
      }
      return { kind: 'device_mismatch' };
    }
    if (ch.status === 'verified') {
      if (
        args.allowReplay &&
        ch.verifiedAt !== null &&
        ch.replayedAt === null &&
        now.getTime() - ch.verifiedAt.getTime() <= policy.replayWindowSeconds * 1000 &&
        this.hmac.verifyCode(ch.id, args.code, ch.codeHmac, ch.pepperVersion)
      ) {
        return { kind: 'replay', challenge: ch };
      }
      return { kind: 'expired' };
    }
    if (ch.status === 'locked') return { kind: 'locked', retryAfter: await this.lockedRetryAfter(ch, policy, now, tx) };
    if (ch.status !== 'sent') return { kind: 'expired' };
    if (ch.expiresAt.getTime() <= now.getTime()) {
      await this.challenges.update(ch.id, { status: 'expired' }, now, tx);
      return { kind: 'expired' };
    }
    if (ch.attempts >= policy.maxAttempts) {
      await this.challenges.update(ch.id, { status: 'locked' }, now, tx);
      return { kind: 'locked', retryAfter: await this.lockedRetryAfter(ch, policy, now, tx) };
    }
    // Счётчик — до сравнения (09 §5.3: падение процесса после сравнения не даёт бесплатной попытки).
    const attempts = ch.attempts + 1;
    await this.challenges.update(ch.id, { attempts }, now, tx);
    if (!this.hmac.verifyCode(ch.id, args.code, ch.codeHmac, ch.pepperVersion)) {
      const lockedNow = attempts >= policy.maxAttempts;
      if (lockedNow) await this.challenges.update(ch.id, { status: 'locked' }, now, tx);
      return { kind: 'invalid', attemptsLeft: Math.max(0, policy.maxAttempts - attempts), lockedNow };
    }
    // Атомарное потребление (single-use): строка заблокирована FOR UPDATE, статус `sent` → `verified`.
    const updated = await this.challenges.update(ch.id, { status: 'verified', verifiedAt: now }, now, tx);
    return { kind: 'ok', challenge: updated ?? ch };
  }

  /** Перевод итога проверки в Problem (после COMMIT). */
  static toProblem(check: Exclude<OtpCheck, { kind: 'ok' } | { kind: 'replay' }>): ProblemException {
    switch (check.kind) {
      case 'not_found':
        return new ProblemException('NOT_FOUND', { detail: 'Код не найден. Запросите новый.' });
      case 'device_mismatch':
        return new ProblemException('DEVICE_MISMATCH', { detail: 'Код запрошен на другом устройстве.' });
      case 'expired':
        return new ProblemException('OTP_EXPIRED', { detail: 'Код истёк. Запросите новый.' });
      case 'locked':
        return new ProblemException('OTP_LOCKED', {
          detail: 'Слишком много неверных попыток. Запросите новый код.',
          retryAfter: check.retryAfter,
        });
      case 'invalid':
        return new ProblemException('OTP_INVALID', {
          detail: `Неверный код. Осталось попыток: ${check.attemptsLeft}.`,
          attemptsLeft: check.attemptsLeft,
        });
    }
  }

  /** До выпуска нового кода: остаток cooldown или паузы номера, но не меньше 0. */
  private async lockedRetryAfter(ch: OtpChallengeRow, p: OtpPolicy, now: Date, tx: DbExecutor): Promise<number> {
    const recent = await this.challenges.recentDelivered(
      ch.phoneE164,
      ch.purpose,
      Math.max(1, p.lockAfterLockedCodes),
      tx,
    );
    const cooldownEnd = (recent[0]?.createdAt ?? ch.createdAt).getTime() + p.resendCooldownSeconds * 1000;
    let end = cooldownEnd;
    if (recent.length >= p.lockAfterLockedCodes && recent.every((r) => r.status === 'locked' || r.id === ch.id)) {
      // Пауза номера — от блокировки кода (`locked_at`; код блокируется сейчас — от `now`).
      end = Math.max(end, (ch.lockedAt ?? now).getTime() + p.phonePauseMinutes * 60_000);
    }
    return Math.max(0, Math.ceil((end - now.getTime()) / 1000));
  }

  /**
   * `failed_delivery` не учитывается в лимите номера (09 §6.8): возврат единицы в окна запроса (`at` — момент
   * выпуска кода, `otp_challenges.created_at`).
   */
  async releasePhoneQuota(phoneE164: string, at: Date, ex: DbExecutor = this.db): Promise<void> {
    await releaseOtpPhoneQuota(ex, this.hmac, phoneE164, at);
  }

  private async rateLimitedAudit(input: IssueOtpInput, scope: string): Promise<void> {
    this.logger.warn(
      {
        event: 'otp.rate_limited',
        scope,
        purpose: input.purpose,
        phoneMasked: maskPhone(input.phoneE164),
        deviceId: input.deviceKey,
        requestId: input.requestId ?? undefined,
      },
      'otp.rate_limited',
    );
    await this.audit
      .write(input.audit, {
        action: 'auth.otp.rate_limited',
        entityType: 'otp_challenge',
        result: 'denied',
        after: { purpose: input.purpose, phone: input.phoneE164, scope },
      })
      .catch((err: unknown) =>
        this.logger.error({ event: 'audit.write_failed', action: 'auth.otp.rate_limited', err }, 'audit failed'),
      );
  }
}

type LimitDenial =
  | { kind: 'phone_limit'; retryAfter: number; scope: string }
  | { kind: 'client_limit'; retryAfter: number; scope: string }
  | { kind: 'global' };

/** Итог отказа `consume`: приоритет — номер → IP/устройство → глобальный (порядок 09 §5.4). */
function classifyDenial(r: RateLimitResult): LimitDenial {
  const denied = r.decisions.filter((d) => !d.allowed);
  const pick = (set: ReadonlySet<RateLimitScope>) => denied.filter((d) => set.has(d.scope));
  const phone = pick(PHONE_SCOPES);
  if (phone.length > 0) {
    return {
      kind: 'phone_limit',
      scope: phone[0].scope,
      retryAfter: phone.reduce((m, d) => Math.max(m, d.retryAfterSec), 0),
    };
  }
  const client = pick(CLIENT_SCOPES);
  if (client.length > 0) {
    return {
      kind: 'client_limit',
      scope: client[0].scope,
      retryAfter: client.reduce((m, d) => Math.max(m, d.retryAfterSec), 0),
    };
  }
  return { kind: 'global' };
}

function smsProviderError(): ProblemException {
  return new ProblemException('SMS_PROVIDER_ERROR', { detail: 'Не удалось отправить SMS. Попробуйте позже.' });
}
