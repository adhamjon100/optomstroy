import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayMinSize,
  ArrayUnique,
  IsArray,
  IsIn,
  IsInt,
  IsISO8601,
  IsOptional,
  IsString,
  Length,
  Max,
  MaxLength,
  Min,
} from 'class-validator';
import { INVITATION_ROLE_CODES } from '../users/admin-users.dto.js';
import { maskPhone } from '../users/shared/phone.js';
import { IsPhoneE164, NoControlChars, NormalizePhone, Trim } from '../users/shared/validators.js';
import type { InvitationRecord } from './admin-invitations.repository.js';

/** Query `GET /admin/invitations` (08 §4.18.4: `limit`, `cursor`). */
export class AdminInvitationsListQuery {
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

/**
 * Тело `POST /admin/invitations` (схема `AdminInvitationsCreateRequest`). `roles` по схеме — до 5 элементов, но
 * приглашение хранит одну роль (07 §5.3) и активная роль одна (07 §5.7): > 1 → 422 (сервис). `fullName` в схеме
 * nullable, а `user_invitations.full_name NOT NULL` и ядро §24.2 требуют ФИО → отсутствие — 422 (сервис;
 * docs/stages/D_spec_questions.md, раздел «admin»).
 */
export class AdminInvitationsCreateDto {
  @NormalizePhone()
  @IsPhoneE164()
  phone!: string;

  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(5)
  @ArrayUnique()
  @IsIn(INVITATION_ROLE_CODES, { each: true })
  roles!: (typeof INVITATION_ROLE_CODES)[number][];

  @IsOptional()
  @Trim()
  @IsString()
  @Length(2, 150)
  @NoControlChars()
  fullName?: string | null;

  @IsOptional()
  @IsISO8601({ strict: true })
  expiresAt?: string | null;
}

/** `UserRef` (08 §3.5): без телефона. */
export interface UserRefDto {
  readonly id: string;
  readonly displayName: string;
  readonly role?: string;
}

/** `Invitation` (08 §4.18.4). */
export interface InvitationDto {
  readonly id: string;
  readonly phoneMasked: string;
  readonly roles: string[];
  readonly status: 'pending' | 'accepted' | 'revoked' | 'expired';
  readonly createdBy: UserRefDto;
  readonly createdAt: string;
  readonly expiresAt: string | null;
  readonly acceptedAt: string | null;
  readonly appliedToUserId: string | null;
}

/** Эффективный статус: `pending` с истёкшим `expires_at` показывается как `expired` (Q-141). */
export function effectiveInvitationStatus(r: Pick<InvitationRecord, 'status' | 'expiresAt'>, now: Date) {
  return r.status === 'pending' && r.expiresAt.getTime() <= now.getTime() ? 'expired' : r.status;
}

export function toInvitationDto(r: InvitationRecord, now: Date): InvitationDto {
  return {
    id: r.id,
    phoneMasked: maskPhone(r.phoneE164),
    roles: [r.role],
    status: effectiveInvitationStatus(r, now),
    createdBy: {
      id: r.invitedByUserId,
      displayName: r.inviterDisplayName ?? 'Администратор',
      ...(r.inviterRole ? { role: r.inviterRole } : {}),
    },
    createdAt: r.createdAt.toISOString(),
    expiresAt: r.expiresAt.toISOString(),
    acceptedAt: r.acceptedAt ? r.acceptedAt.toISOString() : null,
    appliedToUserId: r.acceptedUserId,
  };
}
