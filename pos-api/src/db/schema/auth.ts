// СГЕНЕРИРОВАНО test/db/codegen/gen-drizzle-schema.ts из каталога PostgreSQL 17 после migrations/*.sql
// (RM-C-006) — вручную не править: новая миграция → `npx tsx test/db/codegen/gen-drizzle-schema.ts`.
// Сверка с БД — test/db/migrate-seed.db-spec.ts («Drizzle-схема совпадает с БД»).

// Домен auth (07 §5.A)

import { sql } from 'drizzle-orm';
import {
  boolean,
  inet,
  integer,
  jsonb,
  pgTable,
  primaryKey,
  smallint,
  text,
  timestamp,
  uuid,
} from 'drizzle-orm/pg-core';
import { bytea } from './types.js';
import {
  consentKindEnum,
  devicePlatformEnum,
  invitationStatusEnum,
  otpPurposeEnum,
  otpStatusEnum,
  roleCodeEnum,
  sessionKindEnum,
  stepUpMethodEnum,
  userKindEnum,
  userStatusEnum,
} from './enums.js';

/** users — 07 §5.1 */
export const users = pgTable('users', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  phoneE164: text('phone_e164'),
  phoneVerifiedAt: timestamp('phone_verified_at', { withTimezone: true }),
  kind: userKindEnum('kind').notNull(),
  status: userStatusEnum('status')
    .notNull()
    .default(sql`'pending'::user_status`),
  permissionsVersion: integer('permissions_version')
    .notNull()
    .default(sql`1`),
  invitationId: uuid('invitation_id'),
  lastLoginAt: timestamp('last_login_at', { withTimezone: true }),
  blockedAt: timestamp('blocked_at', { withTimezone: true }),
  blockedByUserId: uuid('blocked_by_user_id'),
  blockReason: text('block_reason'),
  deletedAt: timestamp('deleted_at', { withTimezone: true }),
  deletedPhoneHmac: bytea('deleted_phone_hmac'),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** user_profiles — 07 §5.2 */
export const userProfiles = pgTable('user_profiles', {
  userId: uuid('user_id').primaryKey(),
  fullName: text('full_name').notNull(),
  birthYear: smallint('birth_year'),
  activitySphere: text('activity_sphere'),
  displayName: text('display_name'),
  locale: text('locale')
    .notNull()
    .default(sql`'ru'::text`),
  settings: jsonb('settings')
    .notNull()
    .default(sql`'{}'::jsonb`),
  biometricsEnabled: boolean('biometrics_enabled')
    .notNull()
    .default(sql`false`),
  homeWarehouseId: uuid('home_warehouse_id'),
  rowVersion: integer('row_version')
    .notNull()
    .default(sql`1`),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** user_invitations — 07 §5.3 */
export const userInvitations = pgTable('user_invitations', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  phoneE164: text('phone_e164').notNull(),
  role: roleCodeEnum('role').notNull(),
  fullName: text('full_name').notNull(),
  invitedByUserId: uuid('invited_by_user_id').notNull(),
  status: invitationStatusEnum('status')
    .notNull()
    .default(sql`'pending'::invitation_status`),
  expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
  acceptedUserId: uuid('accepted_user_id'),
  acceptedAt: timestamp('accepted_at', { withTimezone: true }),
  revokedAt: timestamp('revoked_at', { withTimezone: true }),
  note: text('note'),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** roles — 07 §5.4 */
export const roles = pgTable('roles', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  code: roleCodeEnum('code').notNull(),
  nameRu: text('name_ru').notNull(),
  isSystem: boolean('is_system')
    .notNull()
    .default(sql`true`),
  isAssignable: boolean('is_assignable')
    .notNull()
    .default(sql`true`),
  sortOrder: smallint('sort_order').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** permissions — 07 §5.5 */
export const permissions = pgTable('permissions', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  code: text('code').notNull(),
  descriptionRu: text('description_ru').notNull(),
  requiresStepUp: boolean('requires_step_up')
    .notNull()
    .default(sql`false`),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** role_permissions — 07 §5.6 */
export const rolePermissions = pgTable(
  'role_permissions',
  {
    roleId: uuid('role_id').notNull(),
    permissionId: uuid('permission_id').notNull(),
    constraintJson: jsonb('constraint_json'),
    createdAt: timestamp('created_at', { withTimezone: true })
      .notNull()
      .default(sql`now()`),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .notNull()
      .default(sql`now()`),
  },
  (t) => [primaryKey({ name: 'role_permissions_pkey', columns: [t.roleId, t.permissionId] })],
);

/** user_roles — 07 §5.7 */
export const userRoles = pgTable('user_roles', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  userId: uuid('user_id').notNull(),
  roleId: uuid('role_id').notNull(),
  grantedByUserId: uuid('granted_by_user_id'),
  grantedAt: timestamp('granted_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  revokedAt: timestamp('revoked_at', { withTimezone: true }),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** devices — 07 §5.8 */
export const devices = pgTable('devices', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  userId: uuid('user_id').notNull(),
  deviceKey: text('device_key').notNull(),
  platform: devicePlatformEnum('platform').notNull(),
  model: text('model'),
  osVersion: text('os_version'),
  appVersion: text('app_version'),
  displayName: text('display_name'),
  biometricEnrolledAt: timestamp('biometric_enrolled_at', { withTimezone: true }),
  settings: jsonb('settings')
    .notNull()
    .default(sql`'{}'::jsonb`),
  lastSeenAt: timestamp('last_seen_at', { withTimezone: true }),
  lastIp: inet('last_ip'),
  revokedAt: timestamp('revoked_at', { withTimezone: true }),
  revokedByUserId: uuid('revoked_by_user_id'),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** sessions — 07 §5.9 */
export const sessions = pgTable('sessions', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  userId: uuid('user_id').notNull(),
  deviceId: uuid('device_id').notNull(),
  familyId: uuid('family_id').notNull(),
  refreshHash: bytea('refresh_hash').notNull(),
  prevRefreshHash: bytea('prev_refresh_hash'),
  kind: sessionKindEnum('kind')
    .notNull()
    .default(sql`'standard'::session_kind`),
  issuedAt: timestamp('issued_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  rotatedAt: timestamp('rotated_at', { withTimezone: true }),
  lastUsedAt: timestamp('last_used_at', { withTimezone: true }),
  expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
  idleExpiresAt: timestamp('idle_expires_at', { withTimezone: true }).notNull(),
  stepUpUntil: timestamp('step_up_until', { withTimezone: true }),
  stepUpMethod: stepUpMethodEnum('step_up_method'),
  unlockedUntil: timestamp('unlocked_until', { withTimezone: true }),
  supersededRefreshHash: bytea('superseded_refresh_hash'),
  graceUsedAt: timestamp('grace_used_at', { withTimezone: true }),
  createdFromChallengeId: uuid('created_from_challenge_id'),
  amr: text('amr')
    .array()
    .notNull()
    .default(sql`'{sms}'::text[]`),
  revokedAt: timestamp('revoked_at', { withTimezone: true }),
  revokeReason: text('revoke_reason'),
  ipLast: inet('ip_last'),
  userAgent: text('user_agent'),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** token_denylist — 07 §5.10 (ядро §17.3) */
export const tokenDenylist = pgTable('token_denylist', {
  jti: uuid('jti').primaryKey(),
  tokenKind: text('token_kind')
    .notNull()
    .default(sql`'access'::text`),
  sessionId: uuid('session_id'),
  expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
  reason: text('reason').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** otp_challenges — 07 §5.11 */
export const otpChallenges = pgTable('otp_challenges', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  phoneE164: text('phone_e164').notNull(),
  userId: uuid('user_id'),
  purpose: otpPurposeEnum('purpose').notNull(),
  codeHmac: bytea('code_hmac').notNull(),
  salt: bytea('salt').notNull(),
  pepperVersion: smallint('pepper_version').notNull(),
  expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
  attempts: smallint('attempts')
    .notNull()
    .default(sql`0`),
  status: otpStatusEnum('status').notNull(),
  verifiedAt: timestamp('verified_at', { withTimezone: true }),
  replayedAt: timestamp('replayed_at', { withTimezone: true }),
  registrationTokenHash: bytea('registration_token_hash'),
  registrationTokenExpiresAt: timestamp('registration_token_expires_at', { withTimezone: true }),
  smsOutboxId: uuid('sms_outbox_id'),
  deviceKey: text('device_key'),
  ip: inet('ip'),
  requestId: text('request_id'),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  issuedByUserId: uuid('issued_by_user_id'),
  lockedAt: timestamp('locked_at', { withTimezone: true }),
  issuedJti: uuid('issued_jti'),
});

/** rate_limit_counters — 07 §5.12 */
export const rateLimitCounters = pgTable(
  'rate_limit_counters',
  {
    scope: text('scope').notNull(),
    subject: text('subject').notNull(),
    windowStart: timestamp('window_start', { withTimezone: true }).notNull(),
    count: integer('count')
      .notNull()
      .default(sql`0`),
    windowEnd: timestamp('window_end', { withTimezone: true }).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true })
      .notNull()
      .default(sql`now()`),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .notNull()
      .default(sql`now()`),
  },
  (t) => [primaryKey({ name: 'rate_limit_counters_pkey', columns: [t.scope, t.subject, t.windowStart] })],
);

/** app_pins — 07 §5.13 */
export const appPins = pgTable('app_pins', {
  userId: uuid('user_id').primaryKey(),
  pinHash: text('pin_hash').notNull(),
  pepperVersion: smallint('pepper_version').notNull(),
  pinLength: smallint('pin_length').notNull(),
  failedAttempts: smallint('failed_attempts')
    .notNull()
    .default(sql`0`),
  lockedUntil: timestamp('locked_until', { withTimezone: true }),
  changedAt: timestamp('changed_at', { withTimezone: true }).notNull(),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** consents — 07 §5.14 */
export const consents = pgTable('consents', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  userId: uuid('user_id').notNull(),
  kind: consentKindEnum('kind').notNull(),
  version: text('version').notNull(),
  textSha256: bytea('text_sha256').notNull(),
  grantedAt: timestamp('granted_at', { withTimezone: true }).notNull(),
  revokedAt: timestamp('revoked_at', { withTimezone: true }),
  deviceId: uuid('device_id'),
  ip: inet('ip'),
  appVersion: text('app_version'),
  otpChallengeId: uuid('otp_challenge_id'),
  faceScanCompletedAt: timestamp('face_scan_completed_at', { withTimezone: true }),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** integration_tokens — 07 §5.62 (ядро §17.3) */
export const integrationTokens = pgTable('integration_tokens', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  name: text('name').notNull(),
  tokenHash: bytea('token_hash').notNull(),
  tokenPrefix: text('token_prefix').notNull(),
  scope: text('scope')
    .notNull()
    .default(sql`'onec_inbound'::text`),
  source: text('source')
    .notNull()
    .default(sql`'operator_script'::text`),
  createdByUserId: uuid('created_by_user_id'),
  expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
  graceUntil: timestamp('grace_until', { withTimezone: true }),
  revokedAt: timestamp('revoked_at', { withTimezone: true }),
  revokedByUserId: uuid('revoked_by_user_id'),
  revokeReason: text('revoke_reason'),
  lastUsedAt: timestamp('last_used_at', { withTimezone: true }),
  lastUsedIp: inet('last_used_ip'),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});
