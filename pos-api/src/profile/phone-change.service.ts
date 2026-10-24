import { Inject, Injectable } from '@nestjs/common';
import { and, eq, isNull, sql } from 'drizzle-orm';
import { type OtpCheck, OtpService } from '../auth/otp/otp.service.js';
import { applyAuditGucs, type AuditContext } from '../common/audit/audit-context.js';
import { AuditService } from '../common/audit/audit.service.js';
import { AuthStateCache } from '../common/auth/auth-state.js';
import { CLOCK, type Clock } from '../common/auth/clock.js';
import type { AuthenticatedPrincipal } from '../common/auth/principal.js';
import { DRIZZLE } from '../common/db/database.module.js';
import { ProblemException } from '../common/problem-details/problem.exception.js';
import type { PosDatabase } from '../db/database.js';
import { customerLinks, devices, users } from '../db/schema/index.js';
import { SessionsRepository } from '../users/sessions.repository.js';
import { UserProfilesRepository } from '../users/user-profiles.repository.js';
import { UsersRepository } from '../users/users.repository.js';
import type { StepUpOutcome } from './step-up/step-up.guard.js';

/** contracts/openapi `AuthOtpChallengeIssued` (202 `POST /me/phone/change/request`). */
export interface OtpChallengeIssuedDto {
  readonly challengeId: string;
  readonly resendAfterSec: number;
  readonly otpTtlSec: number;
}

/** contracts/openapi `MePhoneChangeResult`. */
export interface MePhoneChangeResult {
  readonly phone: string;
  readonly sessionsRevoked: boolean;
}

const PG_UNIQUE_VIOLATION = '23505';

function isUniqueViolation(e: unknown): boolean {
  const cause = (e as { cause?: { code?: unknown } } | null)?.cause;
  return (e as { code?: unknown } | null)?.code === PG_UNIQUE_VIOLATION || cause?.code === PG_UNIQUE_VIOLATION;
}

type ConfirmOutcome =
  | { readonly kind: 'ok'; readonly result: MePhoneChangeResult; readonly revoked: string[] }
  | { readonly kind: 'otp_failed'; readonly check: Exclude<OtpCheck, { kind: 'ok' } | { kind: 'replay' }> };

/**
 * Смена номера телефона (08 §4.3.3; 09 §4.7; 06 §7.4 — через `OtpService` модуля auth): `request` — со step-up
 * `profile.phone.change`, OTP `purpose=phone_change_new` на **новый** номер (лимиты RL-OTP-SEND по новому номеру,
 * cooldown, пауза — у OtpService); `confirm` — код с нового номера, затем в одной транзакции: `users.phone_e164`,
 * отзыв всех других сессий (`phone_changed`), инвалидация `biometric_refresh` на всех устройствах, привязки
 * `customer_links` `confirmed → proposed` (владение новым номером ≠ владение карточкой 1С, 09 §7.9), аудит
 * `user.phone_changed` (маски номеров). Ошибка кода фиксирует попытку (COMMIT) и отдаётся после транзакции.
 */
@Injectable()
export class PhoneChangeService {
  constructor(
    @Inject(DRIZZLE) private readonly db: PosDatabase,
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly otp: OtpService,
    private readonly users: UsersRepository,
    private readonly profiles: UserProfilesRepository,
    private readonly sessions: SessionsRepository,
    private readonly cache: AuthStateCache,
    private readonly audit: AuditService,
  ) {}

  private phoneTaken(): ProblemException {
    return new ProblemException('PHONE_ALREADY_REGISTERED', {
      detail: 'Этот номер уже используется другой учётной записью.',
    });
  }

  async request(
    p: AuthenticatedPrincipal,
    newPhone: string,
    stepUp: StepUpOutcome,
    ctx: AuditContext,
  ): Promise<OtpChallengeIssuedDto> {
    const user = await this.users.findById(p.userId);
    if (!user) throw new ProblemException('UNAUTHENTICATED', { detail: 'Требуется вход.' });
    if (user.phoneE164 === newPhone) {
      throw new ProblemException('VALIDATION_FAILED', {
        status: 400,
        detail: 'Новый номер совпадает с текущим.',
        errors: [{ field: 'newPhone', message: 'Номер совпадает с текущим', rule: 'phone_same' }],
      });
    }
    const other = await this.users.findByPhone(newPhone);
    if (other && other.id !== p.userId) {
      // Раскрытие допустимо: пользователь аутентифицирован и прошёл step-up (09 §4.7 п. 2); событие — в аудит.
      await this.audit.write(ctx, {
        action: 'user.phone_change_requested',
        entityType: 'users',
        entityId: p.userId,
        after: { phone: newPhone },
        result: 'denied',
        reason: 'phone_already_registered',
        stepUpMethod: stepUp.proof?.method ?? null,
      });
      throw this.phoneTaken();
    }
    const issued = await this.otp.issue({
      phoneE164: newPhone,
      purpose: 'phone_change_new',
      deviceKey: p.deviceId,
      ip: ctx.ip ?? null,
      requestId: ctx.requestId ?? null,
      userId: p.userId,
      audit: ctx,
    });
    await this.audit.write(ctx, {
      action: 'user.phone_change_requested',
      entityType: 'users',
      entityId: p.userId,
      after: { phone: newPhone, challengeId: issued.challengeId },
      stepUpMethod: stepUp.proof?.method ?? null,
    });
    return { challengeId: issued.challengeId, resendAfterSec: issued.resendAfterSec, otpTtlSec: issued.otpTtlSec };
  }

  async confirm(
    p: AuthenticatedPrincipal,
    challengeId: string,
    code: string,
    ctx: AuditContext,
  ): Promise<MePhoneChangeResult> {
    const outcome = await this.db
      .transaction(async (tx): Promise<ConfirmOutcome> => {
        await applyAuditGucs(tx, ctx);
        const check = await this.otp.check(tx, {
          challengeId,
          code,
          deviceKey: p.deviceId,
          purpose: 'phone_change_new',
          userId: p.userId,
          allowReplay: false,
        });
        if (check.kind === 'replay') return { kind: 'otp_failed', check: { kind: 'expired' } };
        if (check.kind !== 'ok') return { kind: 'otp_failed', check };
        const phoneE164 = check.challenge.phoneE164;
        const rows = await tx.select().from(users).where(eq(users.id, p.userId)).for('update');
        const user = rows[0];
        if (!user) throw new ProblemException('UNAUTHENTICATED', { detail: 'Требуется вход.' });
        const oldPhone = user.phoneE164;
        const taken = await this.users.findByPhone(phoneE164, tx);
        if (taken && taken.id !== p.userId) throw this.phoneTaken();
        const now = this.clock.now();
        await tx
          .update(users)
          .set({ phoneE164, phoneVerifiedAt: now, updatedAt: sql`now()` })
          .where(eq(users.id, p.userId));
        const revoked = await this.sessions.revokeAllForUser(
          p.userId,
          'phone_changed',
          { exceptSessionId: p.sessionId },
          tx,
        );
        // biometric_refresh на всех устройствах инвалидируется — нужен повторный OTP (09 §4.7 п. 3).
        revoked.push(...(await this.sessions.revokeAllForUser(p.userId, 'phone_changed', { kind: 'biometric' }, tx)));
        await tx
          .update(devices)
          .set({ biometricEnrolledAt: null, updatedAt: sql`now()` })
          .where(and(eq(devices.userId, p.userId), isNull(devices.revokedAt)));
        await this.profiles.setBiometricsEnabled(p.userId, false, tx);
        const relinked = await tx
          .update(customerLinks)
          .set({ status: 'proposed', confirmedAt: null, confirmedByUserId: null, updatedAt: sql`now()` })
          .where(and(eq(customerLinks.userId, p.userId), eq(customerLinks.status, 'confirmed')))
          .returning({ id: customerLinks.id });
        await this.audit.write(
          ctx,
          {
            action: 'user.phone_changed',
            entityType: 'users',
            entityId: p.userId,
            before: { phone: oldPhone },
            after: { phone: phoneE164, challengeId, sessionsRevoked: revoked.length, linksReproposed: relinked.length },
          },
          tx,
        );
        return { kind: 'ok', result: { phone: phoneE164, sessionsRevoked: true }, revoked };
      })
      .catch((e: unknown) => {
        if (isUniqueViolation(e)) throw this.phoneTaken();
        throw e;
      });
    if (outcome.kind === 'otp_failed') {
      // Чужой/неизвестный вызов — как использованный код (08 §4.3.3: повтор → OTP_EXPIRED; 404 контракт не содержит).
      throw OtpService.toProblem(outcome.check.kind === 'not_found' ? { kind: 'expired' } : outcome.check);
    }
    for (const sid of outcome.revoked) this.cache.invalidateSession(sid);
    this.cache.invalidateUser(p.userId);
    return outcome.result;
  }
}
