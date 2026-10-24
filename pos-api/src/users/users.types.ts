import type {
  devices,
  roleCodeEnum,
  sessions,
  tokenDenylist,
  userProfiles,
  userRoles,
  users,
} from '../db/schema/index.js';

/** Строки таблиц домена auth (Drizzle-схема src/db/schema/auth.ts — проекция миграций 0001). */
export type UserRow = typeof users.$inferSelect;
export type UserProfileRow = typeof userProfiles.$inferSelect;
export type UserRoleRow = typeof userRoles.$inferSelect;
export type DeviceRow = typeof devices.$inferSelect;
export type SessionRow = typeof sessions.$inferSelect;
export type TokenDenylistRow = typeof tokenDenylist.$inferSelect;

export type UserKind = UserRow['kind'];
export type UserStatusValue = UserRow['status'];
export type DevicePlatform = DeviceRow['platform'];
export type SessionKind = SessionRow['kind'];
export type StepUpMethod = NonNullable<SessionRow['stepUpMethod']>;
export type RoleCode = (typeof roleCodeEnum.enumValues)[number];

/** CHECK `sessions_revoke_reason_chk` (07 §5.9; ядро §18.2 п. 8). */
export const SESSION_REVOKE_REASONS = [
  'logout',
  'logout_all',
  'reuse_detected',
  'admin',
  'phone_changed',
  'role_changed',
  'expired',
  'device_revoked',
  'blocked',
  'session_limit',
  'device_mismatch',
  'biometric_invalidated',
  // миграция 0003 (09 §8.3 `refresh_replay`, §17 п. 19(а); DQ-03)
  'refresh_replay',
] as const;
export type SessionRevokeReason = (typeof SESSION_REVOKE_REASONS)[number];

/** CHECK `sessions_amr_chk`: `amr <@ {sms,pin,bio,admin_code}` (`admin_code` — миграция 0003, 09 §6.13 п. 3). */
export type SessionAmr = 'sms' | 'pin' | 'bio' | 'admin_code';

/** CHECK `token_denylist_token_kind_chk` / `token_denylist_reason_chk` (07 §5.10). */
export type DeniedTokenKind = 'access' | 'registration' | 'step_up';
export type DenyReason = 'logout' | 'logout_all' | 'role_changed' | 'blocked' | 'used' | 'revoked';
