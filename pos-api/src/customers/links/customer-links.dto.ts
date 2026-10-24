import { IsBoolean, IsOptional, IsString, IsUUID, MaxLength } from 'class-validator';

/** Тело `POST /registration/customer-match/confirm|reject` (08 §4.2.4, `RegistrationCustomerMatchResolveRequest`). */
export class CustomerMatchResolveRequest {
  @IsUUID('all')
  linkId!: string;
}

/** Тело `POST /customers/{id}/links/{linkId}/confirm` (08 §4.11.7, `CustomersLinkConfirmRequest`). */
export class CustomersLinkConfirmRequest {
  @IsOptional()
  @IsString()
  @MaxLength(200)
  comment?: string;

  @IsOptional()
  @IsBoolean()
  force?: boolean;
}

/** Тело `POST /customers/{id}/links/{linkId}/reject` (08 §4.11.7, `CustomersLinkRejectRequest`). */
export class CustomersLinkRejectRequest {
  @IsOptional()
  @IsString()
  @MaxLength(200)
  comment?: string;
}
