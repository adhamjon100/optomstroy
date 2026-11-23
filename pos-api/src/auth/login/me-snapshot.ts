import { Injectable } from '@nestjs/common';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import type { AmrValue } from '../../common/auth/jwt.service.js';
import { biometricWeakAllowed } from '../../common/auth/weak-biometrics.js';
import { PermissionCatalog } from '../../common/rbac/permission-catalog.js';
import { SessionsRepository } from '../../users/sessions.repository.js';
import { UserProfilesRepository } from '../../users/user-profiles.repository.js';
import type { DeviceRow, RoleCode, SessionRow, UserRow } from '../../users/users.types.js';
import { AuthPolicyService } from '../common/auth-policy.js';
import { AppPinsRepository } from '../pin/app-pins.repository.js';
import { HelloKeyService } from '../sessions/hello-key.service.js';
import type { LoginDeviceInfo } from '../sessions/session-issuer.service.js';

/** Подмножество DTO `Me` (OpenAPI `components.schemas.Me`), которое возвращают `/auth/otp/verify` и вход. */
export interface MeDto {
  readonly id: string;
  readonly kind: UserRow['kind'];
  readonly status: UserRow['status'];
  readonly roles: readonly RoleCode[];
  readonly permissions: readonly string[];
  readonly permissionsVersion: number;
  readonly profile?: {
    readonly fullName: string;
    readonly birthYear: number | null;
    readonly activitySphere: string | null;
  };
  readonly security: {
    readonly pinSet: boolean;
    readonly biometricsEnabled: boolean;
    readonly biometricsPlatform:
      'android_class3' | 'ios' | 'windows_hello_gate' | 'none' | 'android_class2' | 'windows_hello_key';
    /** Уровень W Android разрешён субъекту на устройстве входа (08 §3.14, §4.1.2 п. 4; ADR-116). */
    readonly biometricWeakAllowed: boolean;
    /** Ключ Windows Hello (W2) разрешён на устройстве входа (08 §3.14, API-201; ADR-116). */
    readonly windowsHelloKeyAllowed: boolean;
  };
  readonly session?: {
    readonly sid: string;
    readonly deviceId: string;
    readonly deviceName?: string;
    readonly createdAt: string;
    readonly amr: readonly AmrValue[];
    readonly expiresAt: string;
  };
}

export function biometricsPlatform(
  platform: DeviceRow['platform'],
  biometricClass?: LoginDeviceInfo['biometricClass'],
): Exclude<MeDto['security']['biometricsPlatform'], 'android_class2' | 'windows_hello_key'> {
  if (platform === 'windows') return 'windows_hello_gate';
  if (platform === 'ios') return 'ios';
  return biometricClass === 'class3' ? 'android_class3' : 'none';
}

/**
 * Снимок `Me` для ответа входа (09 §4.3: `user` — свои данные после верного кода). Права — по ролям и статусу
 * (PermissionCatalog, 11 §4.2–§4.4); `security.pinSet` — по наличию строки `app_pins` (07 §19 п. 14).
 * Без телефона: ответ входа не дублирует номер (номер на устройстве не хранится — ядро §19.3).
 * Вход по лицу (08 §4.1.2 «Вход по лицу» п. 4, §3.14; ADR-116): `security.biometricWeakAllowed` — как в `GET /me`;
 * `biometricsPlatform = android_class2`, если на устройстве входа живёт семья уровня W; `windowsHelloKeyAllowed` и
 * `windows_hello_key` (живой ключ Windows Hello устройства, W2) — как в `GET /me`.
 */
@Injectable()
export class MeSnapshotBuilder {
  constructor(
    private readonly catalog: PermissionCatalog,
    private readonly profiles: UserProfilesRepository,
    private readonly pins: AppPinsRepository,
    private readonly sessions: SessionsRepository,
    private readonly policy: AuthPolicyService,
    private readonly helloKeys: HelloKeyService,
  ) {}

  async build(
    user: UserRow,
    roles: readonly RoleCode[],
    ctx: {
      readonly session?: SessionRow;
      readonly device?: DeviceRow;
      readonly deviceKey?: string;
      readonly amr?: readonly AmrValue[];
      readonly biometricClass?: LoginDeviceInfo['biometricClass'];
    },
    tx: DbExecutor,
  ): Promise<MeDto> {
    const status = user.status === 'pending_activation' ? 'pending_activation' : 'active';
    const permissions = [...this.catalog.effectivePermissions({ roles, status })].sort();
    const profile = await this.profiles.findByUserId(user.id, tx);
    const pinSet = await this.pins.exists(user.id, tx);
    const weakOnDevice =
      ctx.device !== undefined &&
      ctx.device.platform === 'android' &&
      (await this.sessions.listWeakFamilies(user.id, { deviceId: ctx.device.id }, tx)).length > 0;
    const helloKeyOnDevice = await this.helloKeys.liveOnDevice(ctx.device, tx);
    const windowsHelloKeyAllowed = await this.helloKeys.allowedOn(user, ctx.device, tx);
    return {
      id: user.id,
      kind: user.kind,
      status: user.status,
      roles: [...roles],
      permissions,
      permissionsVersion: user.permissionsVersion,
      ...(profile
        ? {
            profile: {
              fullName: profile.fullName,
              birthYear: profile.birthYear,
              activitySphere: profile.activitySphere,
            },
          }
        : {}),
      security: {
        pinSet,
        biometricsEnabled: profile?.biometricsEnabled ?? false,
        biometricsPlatform: weakOnDevice
          ? 'android_class2'
          : helloKeyOnDevice
            ? 'windows_hello_key'
            : ctx.device
              ? biometricsPlatform(ctx.device.platform, ctx.biometricClass)
              : 'none',
        biometricWeakAllowed: biometricWeakAllowed(
          this.policy.config.AUTH_BIO_ALLOW_WEAK,
          user.kind,
          ctx.device?.platform,
        ),
        windowsHelloKeyAllowed,
      },
      ...(ctx.session && ctx.deviceKey
        ? {
            session: {
              sid: ctx.session.id,
              deviceId: ctx.deviceKey,
              ...(ctx.device ? { deviceName: ctx.device.displayName ?? ctx.device.model ?? undefined } : {}),
              createdAt: ctx.session.issuedAt.toISOString(),
              amr: [...(ctx.amr ?? ['sms'])],
              expiresAt: ctx.session.expiresAt.toISOString(),
            },
          }
        : {}),
    };
  }
}
