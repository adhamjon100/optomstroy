import { IsOptional } from 'class-validator';
import { ForbiddenField, IsBase64UrlText, IsBool, IsBoundedText, IsOneOf, IsPinFormat } from '../common/validators.js';

/** Тело `POST /auth/refresh` (OpenAPI `AuthRefreshRequest`): `kind`, `amr` → rule `forbidden_field`. */
export class RefreshDto {
  @IsBoundedText(1, 256)
  refreshToken!: string;

  @ForbiddenField()
  kind?: unknown;

  @ForbiddenField()
  amr?: unknown;
}

/**
 * Тело `POST /auth/unlock` (OpenAPI `AuthUnlockRequest`; 08 §4.1.8). Без `method` — `pin`. `hello_key` и поля
 * `signature`, `helloKeyInvalidated` — с 1.4.0 (ADR-116); сочетания полей проверяет контроллер (решение A11 контракта).
 */
export class UnlockDto {
  @IsOptional()
  @IsOneOf(['pin', 'biometric', 'hello_key'], 'method')
  method?: 'pin' | 'biometric' | 'hello_key';

  @IsBoundedText(1, 256)
  refreshToken!: string;

  @IsOptional()
  @IsPinFormat()
  pin?: string;

  @IsOptional()
  @IsBool()
  biometricInvalidated?: boolean;

  @IsOptional()
  @IsBase64UrlText(342, 683)
  signature?: string;

  @IsOptional()
  @IsBool()
  helloKeyInvalidated?: boolean;
}

/** Тело `POST /auth/unlock/challenge` (OpenAPI `AuthUnlockChallengeRequest`; 08 §4.1.10; ADR-116). */
export class UnlockChallengeDto {
  @IsOneOf(['hello_key'], 'enum')
  method!: 'hello_key';

  @IsBoundedText(1, 256)
  refreshToken!: string;
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
