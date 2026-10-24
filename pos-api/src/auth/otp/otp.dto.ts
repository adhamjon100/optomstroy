import { Type } from 'class-transformer';
import { IsDefined, IsObject, IsOptional, ValidateNested } from 'class-validator';
import { IsBoundedText, IsKgPhone, IsOneOf, IsOtpCode, IsUuidRule } from '../common/validators.js';

/** Тело `POST /auth/otp/request` (OpenAPI `AuthOtpRequestRequest`; 08 §4.1.1). */
export class OtpRequestDto {
  @IsKgPhone()
  phone!: string;

  /** На этом маршруте — только `login_or_register` (ядро §18.2 п. 7; иное → rule `purpose`). */
  @IsOneOf(['login_or_register'], 'purpose')
  purpose!: 'login_or_register';

  @IsOptional()
  @IsOneOf(['ru', 'ky', 'en'], 'enum')
  locale?: 'ru' | 'ky' | 'en';

  /** Зарезервировано (R2, R6 §1.5): в R1 игнорируется и не логируется (12 T-AUTH-036). */
  @IsOptional()
  @IsBoundedText(0, 8192)
  attestation?: string | null;
}

/** `device` в теле verify (OpenAPI `AuthDeviceInfo`). */
export class DeviceInfoDto {
  @IsBoundedText(1, 100)
  name!: string;

  @IsOneOf(['android', 'ios', 'windows'], 'enum')
  platform!: 'android' | 'ios' | 'windows';

  @IsOptional()
  @IsBoundedText(1, 32)
  osVersion?: string;

  @IsBoundedText(1, 32)
  appVersion!: string;

  @IsOptional()
  @IsOneOf(['class3', 'class2', 'none', 'windows_hello'], 'enum')
  biometricClass?: 'class3' | 'class2' | 'none' | 'windows_hello';
}

/** Тело `POST /auth/otp/verify` (OpenAPI `OtpVerifyRequest`; 08 §4.1.2). */
export class OtpVerifyDto {
  @IsUuidRule()
  challengeId!: string;

  @IsOtpCode()
  code!: string;

  @IsDefined()
  @IsObject()
  @ValidateNested()
  @Type(() => DeviceInfoDto)
  device!: DeviceInfoDto;
}
