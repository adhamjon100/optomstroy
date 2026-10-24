import { Type } from 'class-transformer';
import {
  IsBoolean,
  IsDateString,
  IsIn,
  IsNotEmpty,
  IsOptional,
  IsString,
  Matches,
  MaxLength,
  MinLength,
  ValidateNested,
} from 'class-validator';
import { MONEY_AMOUNT_RE } from '../../common/money/money.js';

/** `Money` (08 §3.1; OpenAPI `Money`, `additionalProperties: false`). */
export class MoneyInput {
  @IsString()
  @Matches(MONEY_AMOUNT_RE, { message: 'amount — строка с двумя знаками после точки' })
  amount!: string;

  @IsIn(['KGS'])
  currency!: 'KGS';
}

/** `OrdersPaymentCreateRequest` (08 §4.8.6): сумму платежа клиент не передаёт. */
export class OrdersPaymentCreateRequest {
  @IsIn(['cash', 'qr_bakai', 'credit'])
  method!: 'cash' | 'qr_bakai' | 'credit';

  @IsOptional()
  @ValidateNested()
  @Type(() => MoneyInput)
  receivedAmount?: MoneyInput;

  @IsOptional()
  @IsString()
  @MaxLength(200)
  comment?: string;

  @IsOptional()
  @IsBoolean()
  reissueQr?: boolean;

  @IsOptional()
  @IsBoolean()
  manualOnly?: boolean;
}

/** `PaymentsConfirmManualRequest` (08 §4.9.3): `acceptMismatch`/`reason` — лишние поля → 400. */
export class PaymentsConfirmManualRequest {
  @IsString()
  @IsNotEmpty()
  @MinLength(1)
  @MaxLength(64)
  bankReference!: string;

  @ValidateNested()
  @Type(() => MoneyInput)
  receivedAmount!: MoneyInput;

  @IsOptional()
  @IsDateString()
  receivedAt?: string;

  @IsOptional()
  @IsString()
  @MaxLength(200)
  comment?: string;
}

export const VOID_REASON_CODES = ['cashier_error', 'customer_refused', 'duplicate', 'other'] as const;

/** `PaymentsVoidRequest` (08 §4.9.4). */
export class PaymentsVoidRequest {
  @IsString()
  @MinLength(1)
  @MaxLength(500)
  reason!: string;

  @IsIn(VOID_REASON_CODES)
  reasonCode!: (typeof VOID_REASON_CODES)[number];
}
