import { Inject, Injectable } from '@nestjs/common';
import { eq } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { PermissionCatalog } from '../../common/rbac/permission-catalog.js';
import { roleDiscountLimits } from '../../db/schema/index.js';
import { DevicesRepository } from '../../users/devices.repository.js';
import { SessionsRepository } from '../../users/sessions.repository.js';
import { UserProfilesRepository } from '../../users/user-profiles.repository.js';
import { UserRolesRepository } from '../../users/user-roles.repository.js';
import { UsersRepository } from '../../users/users.repository.js';
import type { DeviceRow, RoleCode, UserProfileRow, UserRow } from '../../users/users.types.js';
import { type ConsentDto, ConsentsService } from '../consents/consents.service.js';
import { CustomerLinkReader, type MeCustomerLinkDto } from '../customer-link.reader.js';
import { AppPinsRepository } from '../../auth/pin/app-pins.repository.js';
import { IDLE_LOCK_MAX_CUSTOMER } from '../profile.constants.js';
import { type SettingsDto, settingsFromProfile } from './settings.projection.js';

/** contracts/openapi `Profile` (08 §3.14). `phone` — полный номер только владельцу (09 §2.4). */
export interface ProfileDto {
  readonly fullName: string | null;
  readonly phone: string | null;
  readonly birthYear: number | null;
  readonly activitySphere: string | null;
  readonly avatarUrl: null;
  readonly rowVersion: number;
}

export type BiometricsPlatform = 'android_class3' | 'ios' | 'windows_hello_gate' | 'none';

/** contracts/openapi `Me` (08 §4.3.1, §3.14). */
export interface MeDto {
  readonly id: string;
  readonly kind: 'staff' | 'customer';
  readonly status: UserRow['status'];
  readonly roles: RoleCode[];
  readonly permissions: string[];
  readonly permissionsVersion: number;
  readonly discountLimitPercent?: string;
  readonly profile?: ProfileDto;
  readonly customerLink?: MeCustomerLinkDto;
  readonly settings: SettingsDto;
  readonly security: {
    readonly pinSet: boolean;
    readonly biometricsEnabled: boolean;
    readonly biometricsPlatform: BiometricsPlatform;
  };
  readonly consents: ConsentDto[];
  readonly session?: {
    readonly sid: string;
    readonly deviceId: string;
    readonly deviceName?: string;
    readonly createdAt: string;
    readonly amr: ('sms' | 'bio' | 'pin')[];
    readonly expiresAt: string;
  };
  readonly appVersion?: { readonly min?: string; readonly recommended?: string | null };
  readonly apiVersion: string;
  readonly serverTime: string;
}

export interface MeContext {
  /** `sessions.id` (= claim `sid`). */
  readonly sessionId?: string | null;
  /** `X-Device-Id` (= `devices.device_key`). */
  readonly deviceKey?: string | null;
  /** Версии приложения из заголовков ответа `X-Min-App-Version` / `X-Recommended-App-Version` (08 §2.11). */
  readonly appVersion?: { readonly min?: string; readonly recommended?: string | null };
}

export const API_VERSION = '1.0';

export function profileToDto(p: UserProfileRow | undefined, user: Pick<UserRow, 'phoneE164'>): ProfileDto | undefined {
  if (!p) return undefined;
  return {
    fullName: p.fullName,
    phone: user.phoneE164,
    birthYear: p.birthYear,
    activitySphere: p.activitySphere,
    avatarUrl: null,
    rowVersion: p.rowVersion,
  };
}

export function biometricsPlatformOf(device: DeviceRow | undefined): BiometricsPlatform {
  if (!device) return 'none';
  if (device.platform === 'windows') return 'windows_hello_gate';
  if (device.biometricEnrolledAt === null) return 'none';
  return device.platform === 'ios' ? 'ios' : 'android_class3';
}

/**
 * Представление `GET /me` (08 §4.3.1; 09 §2.4) — источник правды клиента о ролях, правах (`permissions[]` — для
 * скрытия кнопок, не защита), настройках, защите входа и привязке. `pending_activation` — усечённый DTO: права —
 * псевдо-набор 11 §4.2, без `discountLimitPercent` и `customerLink`. Используется также ответами
 * `/registration/complete` (`user`).
 */
@Injectable()
export class MeService {
  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly users: UsersRepository,
    private readonly roles: UserRolesRepository,
    private readonly profiles: UserProfilesRepository,
    private readonly devices: DevicesRepository,
    private readonly sessions: SessionsRepository,
    private readonly pins: AppPinsRepository,
    private readonly consents: ConsentsService,
    private readonly links: CustomerLinkReader,
    private readonly catalog: PermissionCatalog,
  ) {}

  settingsContext(kind: 'staff' | 'customer', roles: readonly string[], platform?: string | null) {
    return {
      kind,
      roles,
      platform: platform ?? null,
      staffIdleMinutes: Math.min(30, this.config.SESSION_IDLE_LOCK_MINUTES),
      customerIdleMinutes: IDLE_LOCK_MAX_CUSTOMER,
    };
  }

  async build(userId: string, ctx: MeContext = {}, ex: DbExecutor = this.db): Promise<MeDto> {
    const user = await this.users.findById(userId, ex);
    if (!user) throw new Error('me: пользователь не найден');
    const [roles, profile, pin, session, device] = await Promise.all([
      this.roles.activeRoleCodes(userId, ex),
      this.profiles.findByUserId(userId, ex),
      this.pins.find(userId, ex),
      ctx.sessionId ? this.sessions.findById(ctx.sessionId, ex) : Promise.resolve(undefined),
      ctx.deviceKey ? this.devices.findByKey(userId, ctx.deviceKey, ex) : Promise.resolve(undefined),
    ]);
    const pending = user.status === 'pending_activation';
    const permissions = [
      ...this.catalog.effectivePermissions({ roles, status: pending ? 'pending_activation' : 'active' }),
    ];
    permissions.sort();
    const kind = user.kind;
    const [consents, customerLink, discountLimitPercent] = await Promise.all([
      this.consents.latestView(userId, device?.id ?? null, ex),
      !pending && kind === 'customer' ? this.links.meLink(userId, ex) : Promise.resolve(undefined),
      !pending && kind === 'staff' ? this.discountLimit(roles, ex) : Promise.resolve(undefined),
    ]);
    const profileDto = profileToDto(profile, user);
    const sessionOk = session && session.userId === userId ? session : undefined;
    return {
      id: user.id,
      kind,
      status: user.status,
      roles,
      permissions,
      permissionsVersion: user.permissionsVersion,
      ...(discountLimitPercent !== undefined ? { discountLimitPercent } : {}),
      ...(profileDto ? { profile: profileDto } : {}),
      ...(customerLink ? { customerLink } : {}),
      settings: settingsFromProfile(profile, this.settingsContext(kind, roles, device?.platform)),
      security: {
        pinSet: pin !== undefined,
        biometricsEnabled: device?.biometricEnrolledAt !== null && device?.biometricEnrolledAt !== undefined,
        biometricsPlatform: biometricsPlatformOf(device),
      },
      consents,
      ...(sessionOk
        ? {
            session: {
              sid: sessionOk.id,
              deviceId: device?.deviceKey ?? ctx.deviceKey ?? '',
              ...(device?.displayName || device?.model ? { deviceName: device.displayName ?? device.model ?? '' } : {}),
              createdAt: sessionOk.issuedAt.toISOString(),
              // `admin_code` (миграция 0003) в enum контракта `Me.session.amr` нет — не выводится (DQ-02).
              amr: sessionOk.amr.filter((a): a is 'sms' | 'bio' | 'pin' => a !== 'admin_code'),
              expiresAt: sessionOk.expiresAt.toISOString(),
            },
          }
        : {}),
      ...(ctx.appVersion ? { appVersion: ctx.appVersion } : {}),
      apiVersion: API_VERSION,
      serverTime: this.clock.now().toISOString(),
    };
  }

  /** Лимит ручной скидки роли (`role_discount_limits`, 07 DATA-133) — только `staff`, строка `Percent`. */
  private async discountLimit(roles: readonly RoleCode[], ex: DbExecutor): Promise<string | undefined> {
    const role = roles[0];
    if (!role) return undefined;
    const rows = await ex
      .select({ maxPercent: roleDiscountLimits.maxPercent })
      .from(roleDiscountLimits)
      .where(eq(roleDiscountLimits.role, role))
      .limit(1);
    const v = rows[0]?.maxPercent;
    return v === undefined || v === null ? undefined : String(v);
  }
}
