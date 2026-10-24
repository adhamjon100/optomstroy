import { IsOptional } from 'class-validator';
import { IsOneOf, IsOtpCode, IsPinFormat, IsUuidRule } from '../common/validators.js';
import {
  STEP_UP_METHODS_R1,
  STEP_UP_OPERATIONS,
  type StepUpMethodR1,
  type StepUpOperation,
} from './step-up.operations.js';

/**
 * Тело `POST /auth/step-up` (OpenAPI `AuthStepUpRequest`; 08 §4.1.7): `method ∈ {pin, otp}` (биометрия — R2:
 * `bio+pin`/`bio+otp` → 400 rule `method`); `operation` — из `STEP_UP_REQUIRED.stepUp.operation` (иное → rule
 * `operation`).
 */
export class StepUpDto {
  @IsOneOf(STEP_UP_METHODS_R1, 'method')
  method!: StepUpMethodR1;

  @IsOneOf(STEP_UP_OPERATIONS, 'operation')
  operation!: StepUpOperation;

  @IsOptional()
  @IsPinFormat()
  pin?: string;

  @IsOptional()
  @IsUuidRule()
  challengeId?: string;

  @IsOptional()
  @IsOtpCode()
  code?: string;
}
