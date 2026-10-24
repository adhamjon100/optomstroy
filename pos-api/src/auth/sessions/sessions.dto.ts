import { IsOptional } from 'class-validator';
import { ForbiddenField, IsBool, IsBoundedText, IsOneOf, IsPinFormat } from '../common/validators.js';

/** Тело `POST /auth/refresh` (OpenAPI `AuthRefreshRequest`): `kind`, `amr` → rule `forbidden_field`. */
export class RefreshDto {
  @IsBoundedText(1, 256)
  refreshToken!: string;

  @ForbiddenField()
  kind?: unknown;

  @ForbiddenField()
  amr?: unknown;
}

/** Тело `POST /auth/unlock` (OpenAPI `AuthUnlockRequest`; 08 §4.1.8). Без `method` — `pin`. */
export class UnlockDto {
  @IsOptional()
  @IsOneOf(['pin', 'biometric'], 'method')
  method?: 'pin' | 'biometric';

  @IsBoundedText(1, 256)
  refreshToken!: string;

  @IsOptional()
  @IsPinFormat()
  pin?: string;

  @IsOptional()
  @IsBool()
  biometricInvalidated?: boolean;
}

/** Тело `POST /auth/logout` (необязательно). */
export class LogoutDto {
  @IsOptional()
  @IsBoundedText(0, 500)
  reason?: string;
}

/** Тело `PATCH /auth/sessions/{id}` (OpenAPI `AuthSessionPatchRequest`). */
export class SessionPatchDto {
  @IsBoundedText(1, 60)
  deviceName!: string;
}
