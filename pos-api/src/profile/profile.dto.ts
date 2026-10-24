import { Type } from 'class-transformer';
import {
  IsBoolean,
  IsIn,
  IsInt,
  IsOptional,
  IsString,
  IsUUID,
  Length,
  MaxLength,
  Min,
  ValidateIf,
  ValidateNested,
} from 'class-validator';
import { CONSENT_KIND_VALUES } from '../common/enums.js';
import {
  ForbiddenField,
  IsBirthYearShape,
  IsOtpCode,
  IsPhoneE164,
  IsPinFormat,
  IsUuidOrNull,
} from './validation/rule.decorators.js';

/**
 * DTO запросов модуля `profile` — вручную по contracts/openapi/pos-api.v1.yaml (источник истины, ADR-085):
 * `additionalProperties: false` обеспечивает глобальный ValidationPipe (`forbidNonWhitelisted`).
 */

/** `MeProfilePatchRequest` (08 §4.3.2): `phone`, `roles`, `status` → 400 rule `forbidden_field`. */
export class MeProfilePatchRequest {
  @IsOptional()
  @IsString()
  @Length(1, 150)
  fullName?: string;

  @IsOptional()
  @IsBirthYearShape()
  birthYear?: number;

  @IsOptional()
  @ValidateIf((_, v) => v !== null)
  @IsString()
  @MaxLength(64)
  activitySphere?: string | null;

  @IsInt()
  @Min(0)
  rowVersion!: number;

  @ForbiddenField()
  phone?: unknown;

  @ForbiddenField()
  roles?: unknown;

  @ForbiddenField()
  status?: unknown;
}

export class MeSettingsScanner {
  @IsIn(['hid', 'camera'])
  mode!: 'hid' | 'camera';

  @IsIn(['enter', 'tab', 'none'])
  suffix!: 'enter' | 'tab' | 'none';
}

export class MeSettingsPrinter {
  @IsIn(['a4', 'thermal80'])
  defaultFormat!: 'a4' | 'thermal80';

  @IsBoolean()
  autoPrint!: boolean;
}

/** `MeSettingsPutRequest` (08 §4.3.4): полная замена с `rowVersion`. */
export class MeSettingsPutRequest {
  @IsOptional()
  @IsIn(['ru', 'ky', 'en'])
  locale?: 'ru' | 'ky' | 'en';

  @IsOptional()
  @ValidateNested()
  @Type(() => MeSettingsScanner)
  scanner?: MeSettingsScanner;

  @IsBoolean()
  scanAddsToCart!: boolean;

  @IsOptional()
  @ValidateNested()
  @Type(() => MeSettingsPrinter)
  printer?: MeSettingsPrinter;

  @IsIn(['grid', 'list', 'compact'])
  catalogView!: 'grid' | 'list' | 'compact';

  @IsUuidOrNull()
  defaultWarehouseId!: string | null;

  @IsInt()
  @Min(5)
  idleLockMinutes!: number;

  @IsInt()
  @Min(0)
  rowVersion!: number;
}

/** `MePinSetRequest` (ядро §19.3; 08 §4.3.5). */
export class MePinSetRequest {
  @IsPinFormat()
  newPin!: string;
}

/** `MeBiometricsConsent`. */
export class MeBiometricsConsent {
  @IsIn(CONSENT_KIND_VALUES)
  kind!: (typeof CONSENT_KIND_VALUES)[number];

  @IsString()
  @Length(1, 32)
  version!: string;

  @IsBoolean()
  granted!: boolean;
}

/** `MeBiometricsRequest` (08 §4.3.6). */
export class MeBiometricsRequest {
  @IsBoolean()
  enabled!: boolean;

  @IsOptional()
  @IsIn(['class3', 'ios', 'windows_hello'])
  biometricClass?: 'class3' | 'ios' | 'windows_hello';

  @IsOptional()
  @ValidateNested()
  @Type(() => MeBiometricsConsent)
  consent?: MeBiometricsConsent;
}

/** `MeConsentUpdateRequest` (08 §4.3.7). */
export class MeConsentUpdateRequest {
  @IsIn(CONSENT_KIND_VALUES)
  kind!: (typeof CONSENT_KIND_VALUES)[number];

  @IsString()
  @Length(1, 32)
  version!: string;

  @IsBoolean()
  granted!: boolean;
}

/** `MePhoneChangeRequest` (08 §4.3.3). */
export class MePhoneChangeRequest {
  @IsPhoneE164()
  newPhone!: string;
}

/** `MePhoneChangeConfirmRequest` (08 §4.3.3): `code` в схеме необязателен — отсутствие → 400 `otp_format`. */
export class MePhoneChangeConfirmRequest {
  @IsUUID()
  challengeId!: string;

  @IsOtpCode()
  code!: string;
}
