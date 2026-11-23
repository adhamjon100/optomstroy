import { Inject, Injectable } from '@nestjs/common';
import type { AuditContext } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { HELLO_PERSONAL_WINDOW_MS, helloKeyAllowedFor, type HelloKeyMode } from '../../common/auth/hello-key.js';
import { toSubjectKind } from '../../common/auth/subject-kind.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import type { HelloKeyRevokeReason } from '../../common/enums.js';
import { DevicesRepository } from '../../users/devices.repository.js';
import { type HelloKeyFilter, HelloKeysRepository, type RevokedHelloKey } from '../../users/hello-keys.repository.js';
import { UserProfilesRepository } from '../../users/user-profiles.repository.js';
import type { DeviceRow, UserRow } from '../../users/users.types.js';

/** Отказ переменной `AUTH_WINDOWS_HELLO_KEY` (08 §4.3.6 `MeBiometricsResponse.reason`). */
export type HelloKeyRefusal = 'hello_key_disabled' | 'hello_key_shared_device';

/** Причина отзыва по отказу переменной при challenge и разблокировке (08 §4.1.10: `policy_off`, `shared_device`). */
export function revokeReasonOf(refusal: HelloKeyRefusal): HelloKeyRevokeReason {
  return refusal === 'hello_key_disabled' ? 'policy_off' : 'shared_device';
}

export interface RevokeOptions {
  /** Запись `auth.biometrics.disabled` на каждый ключ (по умолчанию — да; выключение в SCR-42 пишет свою запись). */
  readonly audit?: boolean;
  /** Не снимать `devices.biometric_enrolled_at` (замена ключа `replaced`: отметку сразу ставит новый ключ). */
  readonly keepEnrollment?: boolean;
}

/**
 * Правила ключа Windows Hello (W2; 15 ADR-116 п. 3, п. 4; 09 BIO-038…BIO-040; 08 §4.1.5, §4.1.10, §4.3.3, §4.3.6,
 * §4.18.3, §4.18.11, API-196…API-199; 07 §5.66; 11 SEC-146, RR-10), общие для модулей auth, profile, admin и kiosk:
 * переменная `AUTH_WINDOWS_HELLO_KEY` (`off` | `personal` | `all`) и правило `personal`, признак `windowsHelloKeyAllowed`,
 * отзыв ключей с причиной и аудитом. Зависит только от глобальных провайдеров (users, аудит, часы, конфигурация) —
 * поэтому его подключают и `AuthModule` (экспорт), и `AdminUsersModule` (своим провайдером, без импорта `AuthModule`).
 *
 * Ключ переживает выход, `SESSION_REVOKED` и конец срока сессии (09 §9.5 п. 7). Отзыв снимает
 * `devices.biometric_enrolled_at` устройства (его ставит включение ключа) и `user_profiles.biometrics_enabled`, если у
 * пользователя не осталось устройств с биометрией (`GET /me` `biometricsEnabled`, как у отзыва семьи W).
 * Любая блокировка пользователя (`blocked`) и сброс PIN администратором (`pin_reset`) отзывают все ключи пользователя
 * (08 §4.18.3, §4.18.9, §4.3.7 `[ВЫВОД исполнителя]`, доработка 2026-11-18): блокировка шире `logout-all`
 * администратором, а ключ без PIN не живёт (08 §4.3.5 `hello_key_active`; включение — только при заданном PIN). Отзыв —
 * `AdminUsersService` (блокировка и сброс PIN администратором) и `MeConsentsService` (блокировка отзывом согласия
 * `personal_data`).
 */
@Injectable()
export class HelloKeyService {
  constructor(
    @Inject(CLOCK) private readonly clock: Clock,
    @Inject(APP_CONFIG) private readonly config: Pick<AppConfig, 'AUTH_WINDOWS_HELLO_KEY'>,
    private readonly keys: HelloKeysRepository,
    private readonly devices: DevicesRepository,
    private readonly profiles: UserProfilesRepository,
    private readonly audit: AuditService,
  ) {}

  get mode(): HelloKeyMode {
    return this.config.AUTH_WINDOWS_HELLO_KEY;
  }

  /**
   * Правило `personal` (09 BIO-040; 07 §5.66): с этой установкой (`device_key`) за последние 30 дней входил другой
   * пользователь. При `off` и `all` правило не проверяется (`false`).
   */
  async sharedDevice(userId: string, deviceKey: string, ex: DbExecutor): Promise<boolean> {
    if (this.mode !== 'personal') return false;
    const since = new Date(this.clock.now().getTime() - HELLO_PERSONAL_WINDOW_MS);
    return this.keys.otherUserSessionSince(deviceKey, userId, since, ex);
  }

  /**
   * Отказ переменной для субъекта на установке: `off` (или планшет) → `hello_key_disabled`; `personal` и другой
   * пользователь на установке за 30 дней → `hello_key_shared_device`; `undefined` — ключ разрешён.
   */
  async refusal(
    user: Pick<UserRow, 'id' | 'kind'>,
    deviceKey: string,
    ex: DbExecutor,
  ): Promise<HelloKeyRefusal | undefined> {
    if (!helloKeyAllowedFor(this.mode, toSubjectKind(user.kind))) return 'hello_key_disabled';
    if (await this.sharedDevice(user.id, deviceKey, ex)) return 'hello_key_shared_device';
    return undefined;
  }

  /**
   * `Me.security.windowsHelloKeyAllowed` (08 §3.14, API-201): переменная ≠ `off`, устройство запроса `platform=windows`,
   * правило `personal`; у планшета — `false` (у `MeKiosk` поля `security` нет). PIN — отдельный признак `pinSet`.
   */
  async allowedOn(user: Pick<UserRow, 'id' | 'kind'>, device: DeviceRow | undefined, ex: DbExecutor): Promise<boolean> {
    if (device?.platform !== 'windows') return false;
    return (await this.refusal(user, device.deviceKey, ex)) === undefined;
  }

  /** Живой ключ строки `devices` (`biometricsPlatform = windows_hello_key`, 08 §3.14). */
  async liveOnDevice(device: DeviceRow | undefined, ex: DbExecutor): Promise<boolean> {
    if (device?.platform !== 'windows') return false;
    return (await this.keys.findLiveByDevice(device.id, ex)) !== undefined;
  }

  /**
   * Отзыв живых ключей по фильтру с причиной (07 §5.66; 08 API-199): challenge гасится, отметка биометрии устройства
   * снимается, на каждый ключ — `auth.biometrics.disabled` с причиной и источником (11 §7.2.1; без ключа и challenge).
   */
  async revoke(
    filter: HelloKeyFilter,
    reason: HelloKeyRevokeReason,
    ctx: AuditContext,
    tx: DbExecutor,
    opts: RevokeOptions = {},
  ): Promise<RevokedHelloKey[]> {
    const revoked = await this.keys.revokeLive(filter, reason, tx);
    if (revoked.length === 0) return revoked;
    if (opts.keepEnrollment !== true) {
      const owners = new Set<string>();
      for (const k of revoked) {
        await this.devices.setBiometricEnrolled(k.deviceId, null, tx);
        owners.add(k.userId);
      }
      for (const userId of owners) {
        const enrolled = (await this.devices.listActive(userId, tx)).some((d) => d.biometricEnrolledAt !== null);
        if (!enrolled) await this.profiles.setBiometricsEnabled(userId, false, tx);
      }
    }
    if (opts.audit !== false) {
      for (const k of revoked) {
        await this.audit.write(
          ctx,
          {
            action: 'auth.biometrics.disabled',
            entityType: 'devices',
            entityId: k.deviceId,
            after: { reason, biometricClass: 'windows_hello', keySource: k.source, helloKeyId: k.id, userId: k.userId },
          },
          tx,
        );
      }
    }
    return revoked;
  }

  /**
   * Выдача сессии по SMS, `/registration/complete` или аварийному коду (08 §4.1.2 `[ВЫВОД]`; 09 §9.2 W2 п. 5): при
   * `personal` вход другого пользователя на установке отзывает ключи прежних (`shared_device`).
   */
  async onLoginSession(
    user: Pick<UserRow, 'id'>,
    device: Pick<DeviceRow, 'deviceKey'>,
    ctx: AuditContext,
    tx: DbExecutor,
  ): Promise<RevokedHelloKey[]> {
    if (this.mode !== 'personal') return [];
    return this.revoke({ deviceKey: device.deviceKey, exceptUserId: user.id }, 'shared_device', ctx, tx);
  }

  /**
   * Подключение и подключение заново планшета магазина (08 §4.18.11, §4.18.15 `[ВЫВОД]`; 09 BIO-037): ключи всех
   * пользователей с этой установкой отзываются (`kiosk_connect`) — при любом значении переменной.
   */
  onKioskConnect(deviceKey: string, ctx: AuditContext, tx: DbExecutor): Promise<RevokedHelloKey[]> {
    return this.revoke({ deviceKey }, 'kiosk_connect', ctx, tx);
  }
}
