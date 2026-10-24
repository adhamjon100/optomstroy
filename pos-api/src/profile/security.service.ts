import { Inject, Injectable, Logger } from '@nestjs/common';
import { AppPinsRepository } from '../auth/pin/app-pins.repository.js';
import { applyAuditGucs, type AuditContext } from '../common/audit/audit-context.js';
import { AuditService, type AuditStepUpMethod } from '../common/audit/audit.service.js';
import type { DbExecutor } from '../common/audit/db-executor.js';
import { AuthStateCache } from '../common/auth/auth-state.js';
import { CLOCK, type Clock } from '../common/auth/clock.js';
import type { AuthenticatedPrincipal } from '../common/auth/principal.js';
import { APP_CONFIG, type AppConfig } from '../common/config/app-config.js';
import { PinHasher } from '../common/crypto/pin-hasher.service.js';
import { generateOpaqueToken, sha256 } from '../common/crypto/random.js';
import { DRIZZLE } from '../common/db/database.module.js';
import { newId } from '../common/ids/uuid.js';
import { ProblemException } from '../common/problem-details/problem.exception.js';
import type { PosDatabase } from '../db/database.js';
import { DevicesRepository } from '../users/devices.repository.js';
import { SessionsRepository } from '../users/sessions.repository.js';
import { UserProfilesRepository } from '../users/user-profiles.repository.js';
import type { DeviceRow } from '../users/users.types.js';
import { isCurrentConsentVersion } from './consents/consent-catalog.js';
import { ConsentsService } from './consents/consents.service.js';
import { loginProtectionRequired, pinErrors, pinMinLength, throwIfErrors } from './domain/profile-rules.js';
import { AppPinWriter } from './pin/app-pin.writer.js';
import type { MeBiometricsRequest } from './profile.dto.js';
import type { StepUpOutcome } from './step-up/step-up.guard.js';

/** contracts/openapi `MeBiometricsResponse`. */
export interface MeBiometricsResponse {
  readonly enabled: boolean;
  readonly biometricRefreshToken?: string;
  readonly expiresAt?: string;
  readonly reason?: 'no_crypto_binding_on_platform';
}

const DAY_MS = 24 * 3600_000;

function stepUpMethodOf(o: StepUpOutcome): AuditStepUpMethod | null {
  return o.proof?.method ?? null;
}

/**
 * PIN приложения и биометрический вход (08 §4.3.5, §4.3.6; 09 §9.5, §9.6; D-13, D-48).
 *
 * PIN хранится только как Argon2id-хэш с pepper (`app_pins`, PinHasher); проверка PIN и счётчик попыток — модуль
 * `auth` (`/auth/step-up`, `/auth/unlock`). Биометрия: сервер выдаёт `biometric_refresh` отдельной семьи
 * (`sessions.kind=biometric`) только для текущего устройства Android/iOS; биометрических данных не получает.
 */
@Injectable()
export class SecurityService {
  private readonly logger = new Logger('profile.security');

  constructor(
    @Inject(DRIZZLE) private readonly db: PosDatabase,
    @Inject(CLOCK) private readonly clock: Clock,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    private readonly hasher: PinHasher,
    private readonly pins: AppPinsRepository,
    private readonly pinWriter: AppPinWriter,
    private readonly profiles: UserProfilesRepository,
    private readonly devices: DevicesRepository,
    private readonly sessions: SessionsRepository,
    private readonly consents: ConsentsService,
    private readonly cache: AuthStateCache,
    private readonly audit: AuditService,
  ) {}

  /**
   * `POST /me/pin {newPin}`: политика PIN роли (09 §9.6), повтор того же PIN → 204 без смены (запись аудита —
   * повторно, 08 §4.3.5). Новый PIN сбрасывает счётчик неверных попыток и блокировку.
   */
  async setPin(p: AuthenticatedPrincipal, newPin: string, stepUp: StepUpOutcome, ctx: AuditContext): Promise<void> {
    const profile = await this.profiles.findByUserId(p.userId);
    const minLength = pinMinLength(p.kind, this.config.PIN_MIN_LENGTH_STAFF);
    throwIfErrors(pinErrors(newPin, minLength, profile?.birthYear ?? null, 'newPin'));
    const existing = await this.pins.find(p.userId);
    if (existing) {
      const same = await this.hasher.verify(newPin, p.userId, existing.pinHash, existing.pepperVersion);
      if (same.ok && !same.needsRehash) {
        await this.audit.write(ctx, {
          action: 'auth.pin.changed',
          entityType: 'app_pins',
          entityId: p.userId,
          after: { pepperVersion: existing.pepperVersion, deviceId: p.deviceId, repeated: true },
          stepUpMethod: stepUpMethodOf(stepUp),
        });
        return;
      }
    }
    const hashed = await this.hasher.hash(newPin, p.userId);
    await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      const before = await this.pins.find(p.userId, tx, true);
      await this.pinWriter.upsert(
        {
          userId: p.userId,
          pinHash: hashed.pinHash,
          pepperVersion: hashed.pepperVersion,
          pinLength: hashed.pinLength,
          changedAt: this.clock.now(),
        },
        tx,
      );
      await this.audit.write(
        ctx,
        {
          action: before ? 'auth.pin.changed' : 'auth.pin.set',
          entityType: 'app_pins',
          entityId: p.userId,
          after: { pepperVersion: hashed.pepperVersion, deviceId: p.deviceId },
          stepUpMethod: stepUpMethodOf(stepUp),
        },
        tx,
      );
    });
  }

  /**
   * `DELETE /me/pin` (08 §4.3.5; D-48): только `customer` при включённой биометрии с криптопривязкой; `staff` →
   * `403 FORBIDDEN (pin_required_for_staff)`. Повтор → 204.
   */
  async deletePin(p: AuthenticatedPrincipal, stepUp: StepUpOutcome, ctx: AuditContext): Promise<void> {
    if (p.kind !== 'customer') {
      throw new ProblemException('FORBIDDEN', {
        detail: 'Для сотрудника PIN обязателен.',
        reason: 'pin_required_for_staff',
      });
    }
    const existing = await this.pins.find(p.userId);
    if (!existing) return;
    const device = await this.devices.findByKey(p.userId, p.deviceId);
    if (!this.hasCryptoBoundBiometrics(device)) {
      throw loginProtectionRequired(422, 'Удалить PIN можно только при включённом входе по биометрии устройства');
    }
    await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      const removed = await this.pinWriter.delete(p.userId, tx);
      if (removed) {
        await this.audit.write(
          ctx,
          {
            action: 'auth.pin.removed',
            entityType: 'app_pins',
            entityId: p.userId,
            after: { deviceId: p.deviceId },
            stepUpMethod: stepUpMethodOf(stepUp),
          },
          tx,
        );
      }
    });
  }

  private hasCryptoBoundBiometrics(device: DeviceRow | undefined): boolean {
    return device !== undefined && device.platform !== 'windows' && device.biometricEnrolledAt !== null;
  }

  /** Срок `biometric_refresh` (09 §9.5 п. 5): сотрудник 7 дн., клиент 30 дн., не дольше обычной сессии. */
  private biometricTtlMs(kind: 'staff' | 'customer'): number {
    return (
      (kind === 'staff' ? this.config.AUTH_REFRESH_TTL_STAFF_DAYS : this.config.AUTH_REFRESH_TTL_CUSTOMER_DAYS) * DAY_MS
    );
  }

  private biometricIdleMs(kind: 'staff' | 'customer'): number {
    return kind === 'staff'
      ? this.config.AUTH_REFRESH_IDLE_STAFF_HOURS * 3600_000
      : this.config.AUTH_REFRESH_IDLE_CUSTOMER_DAYS * DAY_MS;
  }

  /** `POST /me/biometrics` (08 §4.3.6; 09 §9.5). */
  async toggleBiometrics(
    p: AuthenticatedPrincipal,
    body: MeBiometricsRequest,
    stepUp: StepUpOutcome,
    ctx: AuditContext,
  ): Promise<MeBiometricsResponse> {
    const device = await this.devices.findByKey(p.userId, p.deviceId);
    const session = await this.sessions.findById(p.sessionId);
    if (!device || !session) throw new ProblemException('SESSION_REVOKED', { detail: 'Сессия завершена.' });
    return body.enabled
      ? this.enableBiometrics(p, body, device, session.expiresAt, session.kind, stepUp, ctx)
      : this.disableBiometrics(p, device, stepUp, ctx);
  }

  private async enableBiometrics(
    p: AuthenticatedPrincipal,
    body: MeBiometricsRequest,
    device: DeviceRow,
    sessionExpiresAt: Date,
    sessionKind: 'standard' | 'biometric',
    stepUp: StepUpOutcome,
    ctx: AuditContext,
  ): Promise<MeBiometricsResponse> {
    // Windows: Windows Hello — только UX-гейт перед PIN, без криптопривязки (D-13): токен не выдаётся.
    if (device.platform === 'windows' || body.biometricClass === 'windows_hello') {
      return { enabled: false, reason: 'no_crypto_binding_on_platform' };
    }
    const expectedClass = device.platform === 'ios' ? 'ios' : 'class3';
    if (body.biometricClass !== undefined && body.biometricClass !== expectedClass) {
      throw new ProblemException('VALIDATION_FAILED', {
        status: 400,
        detail: 'Биометрия устройства не поддерживает криптопривязку.',
        errors: [
          {
            field: 'biometricClass',
            message: `Для платформы ${device.platform} ожидается ${expectedClass}`,
            rule: 'biometric_class',
          },
        ],
      });
    }
    // Предусловие 09 §9.5 п. 1: сессия получена по OTP на этом устройстве, а не через biometric_refresh.
    if (sessionKind !== 'standard') {
      throw new ProblemException('FORBIDDEN', {
        detail: 'Включить биометрию можно только после входа по коду из SMS.',
        reason: 'otp_session_required',
      });
    }
    const consent = body.consent;
    if (consent !== undefined) {
      if (
        consent.kind !== 'biometrics_device' ||
        !consent.granted ||
        !isCurrentConsentVersion(consent.kind, consent.version)
      ) {
        throw new ProblemException('VALIDATION_FAILED', {
          status: 400,
          detail: 'Согласие на биометрию: неверный вид или версия текста.',
          errors: [
            { field: 'consent', message: 'Ожидается действующая версия biometrics_device', rule: 'consent_version' },
          ],
        });
      }
    } else if (!(await this.consents.isActive(p.userId, 'biometrics_device', device.id))) {
      throw new ProblemException('CONSENT_REQUIRED', {
        detail: 'Нужно согласие на вход по биометрии устройства.',
        reason: 'biometrics_device',
      });
    }

    const now = this.clock.now();
    const refreshToken = generateOpaqueToken();
    const expiresAt = new Date(Math.min(now.getTime() + this.biometricTtlMs(p.kind), sessionExpiresAt.getTime()));
    const idleExpiresAt = new Date(Math.min(now.getTime() + this.biometricIdleMs(p.kind), expiresAt.getTime()));
    const revoked = await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      const granted = consent
        ? await this.consents.grant(
            {
              userId: p.userId,
              kind: 'biometrics_device',
              version: consent.version,
              deviceRowId: device.id,
              ip: ctx.ip ?? null,
              appVersion: ctx.appVersion ?? null,
            },
            tx,
          )
        : undefined;
      // Повтор enabled=true: прежняя биометрическая семья этого устройства отзывается (08 §4.3.6, не дублирует).
      const replaced = await this.sessions.revokeAllForUser(
        p.userId,
        'session_limit',
        { kind: 'biometric', deviceId: device.id },
        tx,
      );
      await this.sessions.create(
        {
          userId: p.userId,
          deviceId: device.id,
          familyId: newId(),
          refreshHash: sha256(refreshToken),
          kind: 'biometric',
          expiresAt,
          idleExpiresAt,
          amr: ['sms', 'bio'],
          ipLast: ctx.ip ?? null,
        },
        tx,
      );
      await this.devices.setBiometricEnrolled(device.id, now, tx);
      await this.profiles.setBiometricsEnabled(p.userId, true, tx);
      if (granted?.superseded)
        await this.auditConsent(
          ctx,
          'consent.revoked',
          granted.superseded.id,
          tx,
          granted.superseded.version,
          device.id,
        );
      if (granted?.changed)
        await this.auditConsent(ctx, 'consent.granted', granted.row.id, tx, granted.row.version, device.id);
      await this.audit.write(
        ctx,
        {
          action: 'auth.biometrics.enabled',
          entityType: 'devices',
          entityId: device.id,
          after: { deviceId: p.deviceId, platform: device.platform, replacedSessions: replaced.length },
          stepUpMethod: stepUpMethodOf(stepUp),
        },
        tx,
      );
      return replaced;
    });
    for (const sid of revoked) this.cache.invalidateSession(sid);
    return { enabled: true, biometricRefreshToken: refreshToken, expiresAt: expiresAt.toISOString() };
  }

  private async disableBiometrics(
    p: AuthenticatedPrincipal,
    device: DeviceRow,
    stepUp: StepUpOutcome,
    ctx: AuditContext,
  ): Promise<MeBiometricsResponse> {
    if (device.biometricEnrolledAt === null) {
      // Повтор enabled=false → 200 без изменений (08 §4.3.6).
      return { enabled: false };
    }
    if (p.kind === 'customer' && (await this.pins.find(p.userId)) === undefined) {
      // 09 §9.6: выключение последнего способа защиты входа без установки PIN не допускается.
      throw loginProtectionRequired(422, 'Сначала установите PIN: биометрия — единственный способ защиты входа');
    }
    const revoked = await this.db.transaction(async (tx) => this.disableOnDevice(p.userId, device, ctx, tx, stepUp));
    for (const sid of revoked) this.cache.invalidateSession(sid);
    return { enabled: false };
  }

  /**
   * Выключение биометрии на устройстве (также при отзыве согласия `biometrics_device`, 08 §4.3.7): отзыв
   * биометрической семьи, `devices.biometric_enrolled_at = NULL`, отзыв согласия устройства (09 §9.5 п. 4),
   * `user_profiles.biometrics_enabled` — по наличию других устройств. Возвращает id отозванных сессий.
   */
  async disableOnDevice(
    userId: string,
    device: DeviceRow,
    ctx: AuditContext,
    tx: DbExecutor,
    stepUp?: StepUpOutcome,
    revokeConsent = true,
  ): Promise<string[]> {
    await applyAuditGucs(tx, ctx);
    const revoked = await this.sessions.revokeAllForUser(
      userId,
      'logout',
      { kind: 'biometric', deviceId: device.id },
      tx,
    );
    await this.devices.setBiometricEnrolled(device.id, null, tx);
    const others = (await this.devices.listActive(userId, tx)).some(
      (d) => d.id !== device.id && d.biometricEnrolledAt !== null,
    );
    if (!others) await this.profiles.setBiometricsEnabled(userId, false, tx);
    const consent = revokeConsent ? await this.consents.revoke(userId, 'biometrics_device', device.id, tx) : undefined;
    if (consent) await this.auditConsent(ctx, 'consent.revoked', consent.id, tx, consent.version, device.id);
    await this.audit.write(
      ctx,
      {
        action: 'auth.biometrics.disabled',
        entityType: 'devices',
        entityId: device.id,
        after: { deviceId: device.deviceKey, platform: device.platform, revokedSessions: revoked.length },
        stepUpMethod: stepUp ? stepUpMethodOf(stepUp) : null,
      },
      tx,
    );
    this.logger.log({ event: 'biometrics.disabled', revokedSessions: revoked.length }, 'biometrics.disabled');
    return revoked;
  }

  private async auditConsent(
    ctx: AuditContext,
    action: 'consent.granted' | 'consent.revoked',
    consentId: string,
    tx: DbExecutor,
    version: string,
    deviceRowId: string | null,
  ): Promise<void> {
    await this.audit.write(
      ctx,
      {
        action,
        entityType: 'consents',
        entityId: consentId,
        after: { kind: 'biometrics_device', version, deviceId: deviceRowId },
      },
      tx,
    );
  }
}
