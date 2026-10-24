import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayMinSize,
  ArrayUnique,
  IsArray,
  IsBoolean,
  IsIn,
  IsInt,
  IsOptional,
  IsString,
  Length,
  Max,
  MaxLength,
  Min,
  MinLength,
} from 'class-validator';
import { ForbiddenField, IsPhoneE164, IsReason, NoControlChars, NormalizePhone, Trim } from './shared/validators.js';

/** `RoleCode` (07 §6.1) — значения схемы; ограничения назначения проверяет target-policy. */
export const ROLE_CODES = ['seller', 'cashier', 'senior_seller', 'admin', 'owner', 'customer', 'integration'] as const;
export const USER_STATUSES = ['pending', 'pending_activation', 'active', 'blocked', 'deleted'] as const;
export const USER_KINDS = ['staff', 'customer'] as const;
/** `user_invitations.role` (07 §6.1.1): подмножество RoleCode без customer и integration. */
export const INVITATION_ROLE_CODES = ['seller', 'cashier', 'senior_seller', 'admin', 'owner'] as const;

/** Query `GET /admin/users` (08 §4.18.1). */
export class AdminUsersListQuery {
  @IsOptional()
  @Trim()
  @IsString()
  @MinLength(2)
  @MaxLength(200)
  q?: string;

  @IsOptional()
  @IsIn(ROLE_CODES)
  role?: (typeof ROLE_CODES)[number];

  @IsOptional()
  @IsIn(USER_STATUSES)
  status?: (typeof USER_STATUSES)[number];

  @IsOptional()
  @IsIn(USER_KINDS)
  kind?: (typeof USER_KINDS)[number];

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(200)
  limit?: number;

  @IsOptional()
  @IsString()
  @MaxLength(512)
  cursor?: string;
}

/** Тело `POST /admin/users` (схема `AdminUsersCreateRequest`). */
export class AdminUsersCreateDto {
  @NormalizePhone()
  @IsPhoneE164()
  phone!: string;

  @Trim()
  @IsString()
  @Length(2, 150)
  @NoControlChars()
  fullName!: string;

  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(1)
  @ArrayUnique()
  @IsIn(INVITATION_ROLE_CODES, { each: true })
  roles!: (typeof INVITATION_ROLE_CODES)[number][];

  @ForbiddenField()
  discountLimitPercent?: unknown;

  @ForbiddenField()
  warehouseIds?: unknown;
}

/** Тело `PATCH /admin/users/{id}` (схема `AdminUsersUpdateRequest`). */
export class AdminUsersUpdateDto {
  @IsOptional()
  @Trim()
  @IsString()
  @Length(2, 150)
  @NoControlChars()
  fullName?: string;

  @IsInt()
  @Min(0)
  rowVersion!: number;

  @ForbiddenField()
  discountLimitPercent?: unknown;

  @ForbiddenField()
  warehouseIds?: unknown;
}

/** Тело `PUT /admin/users/{id}/roles` (схема `AdminUsersRolesSetRequest`; R1 — ровно одна роль). */
export class AdminUsersRolesSetDto {
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(1)
  @ArrayUnique()
  @IsIn(ROLE_CODES, { each: true })
  roles!: (typeof ROLE_CODES)[number][];

  @IsOptional()
  @Trim()
  @IsString()
  @MaxLength(500)
  @NoControlChars()
  reason?: string;

  @IsInt()
  @Min(0)
  rowVersion!: number;
}

/** Тело `POST /admin/users/{id}/block` (схема `AdminUsersBlockRequest`). */
export class AdminUsersBlockDto {
  @IsBoolean()
  blocked!: boolean;

  @IsOptional()
  @Trim()
  @IsString()
  @MaxLength(500)
  @NoControlChars()
  reason?: string;
}

/** Тело `DELETE /admin/users/{id}/pin` (схема `AdminUsersPinResetRequest`; 11 SEC-076). */
export class AdminUsersPinResetDto {
  @Trim()
  @IsReason()
  @NoControlChars()
  reason!: string;
}
