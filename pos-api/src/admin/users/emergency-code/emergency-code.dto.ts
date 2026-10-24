import { IsIn, IsOptional, IsString, Length } from 'class-validator';
import { NoControlChars, Trim } from '../shared/validators.js';

export const EMERGENCY_REASONS = ['sms_unavailable', 'sim_lost', 'other'] as const;
export type EmergencyReason = (typeof EMERGENCY_REASONS)[number];

/** Тело `POST /admin/users/{id}/emergency-login-code` (схема `AdminUsersEmergencyLoginCodeRequest`, 08 §4.18.10). */
export class EmergencyLoginCodeRequestDto {
  @IsIn(EMERGENCY_REASONS)
  reason!: EmergencyReason;

  /** Обязателен при `reason=other` (проверка — сервис, rule `comment_required`). */
  @IsOptional()
  @Trim()
  @IsString()
  @Length(5, 200)
  @NoControlChars()
  comment?: string | null;
}

/** Ответ 201 (схема `AdminEmergencyLoginCode`): показывается один раз, нигде не сохраняется. */
export interface EmergencyLoginCodeDto {
  readonly code: string;
  readonly expiresAt: string;
  readonly phoneMasked: string;
}
