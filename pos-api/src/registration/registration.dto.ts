import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayMinSize,
  IsArray,
  IsBoolean,
  IsDefined,
  IsIn,
  IsOptional,
  IsString,
  Length,
  MaxLength,
  ValidateIf,
  ValidateNested,
} from 'class-validator';
import { CONSENT_KIND_VALUES, DEVICE_PLATFORM_VALUES } from '../common/enums.js';
import { IsBirthYearShape, IsPinFormat } from '../profile/validation/rule.decorators.js';

/**
 * DTO `POST /registration/complete` — вручную по contracts/openapi/pos-api.v1.yaml (источник истины; ADR-085):
 * `RegistrationCompleteRequest`, `RegistrationSecurity`, `RegistrationConsentGrant`, `AuthDeviceInfo`.
 * Лишние поля (`role`, `phone`, `profile`, `occupation`, `consents[].granted` …) → 400 `additional_properties`.
 */
export class RegistrationSecurity {
  @IsOptional()
  @IsPinFormat()
  pin?: string;

  @IsOptional()
  @IsBoolean()
  biometricsEnabled?: boolean;
}

/** Элемент `consents[]`: наличие = выданное согласие; `kind` — `consent_kind` 07 (значение `biometric_unlock` → 400). */
export class RegistrationConsentGrant {
  @IsIn(CONSENT_KIND_VALUES)
  kind!: (typeof CONSENT_KIND_VALUES)[number];

  @IsString()
  @Length(1, 32)
  version!: string;
}

export const BIOMETRIC_CLASSES = ['class3', 'class2', 'none', 'windows_hello'] as const;

/** `AuthDeviceInfo` (08 §4.1.2): поле `model` не передаётся (`additionalProperties: false`). */
export class AuthDeviceInfo {
  @IsString()
  @Length(1, 100)
  name!: string;

  @IsIn(DEVICE_PLATFORM_VALUES)
  platform!: (typeof DEVICE_PLATFORM_VALUES)[number];

  @IsOptional()
  @IsString()
  @MaxLength(32)
  osVersion?: string;

  @IsString()
  @MaxLength(32)
  appVersion!: string;

  @IsOptional()
  @IsIn(BIOMETRIC_CLASSES)
  biometricClass?: (typeof BIOMETRIC_CLASSES)[number];
}

export class RegistrationCompleteRequest {
  @IsString()
  @Length(1, 4096)
  registrationToken!: string;

  @IsString()
  @Length(1, 150)
  fullName!: string;

  @IsBirthYearShape()
  birthYear!: number;

  @IsOptional()
  @ValidateIf((_, v) => v !== null)
  @IsString()
  @MaxLength(64)
  activitySphere?: string | null;

  @IsDefined()
  @ValidateNested()
  @Type(() => RegistrationSecurity)
  security!: RegistrationSecurity;

  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(500)
  @ValidateNested({ each: true })
  @Type(() => RegistrationConsentGrant)
  consents!: RegistrationConsentGrant[];

  @IsDefined()
  @ValidateNested()
  @Type(() => AuthDeviceInfo)
  device!: AuthDeviceInfo;
}
