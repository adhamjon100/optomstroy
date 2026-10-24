import { Injectable } from '@nestjs/common';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import type { AmrValue } from '../../common/auth/jwt.service.js';
import { PermissionCatalog } from '../../common/rbac/permission-catalog.js';
import { UserProfilesRepository } from '../../users/user-profiles.repository.js';
import type { DeviceRow, RoleCode, SessionRow, UserRow } from '../../users/users.types.js';
import { AppPinsRepository } from '../pin/app-pins.repository.js';
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
    readonly biometricsPlatform: 'android_class3' | 'ios' | 'windows_hello_gate' | 'none';
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
): MeDto['security']['biometricsPlatform'] {
  if (platform === 'windows') return 'windows_hello_gate';
  if (platform === 'ios') return 'ios';
  return biometricClass === 'class3' ? 'android_class3' : 'none';
}

/**
 * Снимок `Me` для ответа входа (09 §4.3: `user` — свои данные после верного кода). Права — по ролям и статусу
 * (PermissionCatalog, 11 §4.2–§4.4); `security.pinSet` — по наличию строки `app_pins` (07 §19 п. 14).
 * Без телефона: ответ входа не дублирует номер (номер на устройстве не хранится — ядро §19.3).
 */
@Injectable()
export class MeSnapshotBuilder {
  constructor(
    private readonly catalog: PermissionCatalog,
    private readonly profiles: UserProfilesRepository,
    private readonly pins: AppPinsRepository,
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
        biometricsPlatform: ctx.device ? biometricsPlatform(ctx.device.platform, ctx.biometricClass) : 'none',
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
