import type { AdminUserRecord } from './admin-users.repository.js';
import { phoneForViewer } from './shared/phone.js';

/** `AdminUser` (08 §4.18.1; contracts/openapi `#/components/schemas/AdminUser`). */
export interface AdminUserDto {
  readonly id: string;
  readonly kind: 'staff' | 'customer';
  readonly status: string;
  readonly phoneMasked?: string;
  readonly fullName?: string;
  readonly roles: string[];
  readonly permissionsVersion: number;
  readonly discountLimitPercent?: string;
  readonly lastLoginAt: string | null;
  readonly devicesCount: number;
  readonly createdAt: string;
  readonly invitation: { readonly status: 'pending' | 'accepted'; readonly createdAt: string } | null;
  readonly rowVersion: number;
}

/**
 * Проекция для ответа. Телефон полностью — только субъекту `admin` (08 §4.18.1), `owner` видит маску
 * `+996 7** *** *00` (ядро §19.2). `invitation` — только `pending|accepted` (схема AdminUser).
 */
export function toAdminUserDto(r: AdminUserRecord, viewerIsAdmin: boolean): AdminUserDto {
  const phone = phoneForViewer(r.phoneE164, viewerIsAdmin);
  const invStatus = r.invitationStatus === 'pending' || r.invitationStatus === 'accepted' ? r.invitationStatus : null;
  const inv: AdminUserDto['invitation'] =
    invStatus !== null && r.invitationCreatedAt
      ? { status: invStatus, createdAt: r.invitationCreatedAt.toISOString() }
      : null;
  return {
    id: r.id,
    kind: r.kind,
    status: r.status,
    ...(phone !== undefined ? { phoneMasked: phone } : {}),
    ...(r.fullName !== null ? { fullName: r.fullName } : {}),
    roles: r.role ? [r.role] : [],
    permissionsVersion: r.permissionsVersion,
    ...(r.discountMaxPercent !== null ? { discountLimitPercent: r.discountMaxPercent } : {}),
    lastLoginAt: r.lastLoginAt ? r.lastLoginAt.toISOString() : null,
    devicesCount: r.devicesCount,
    createdAt: r.createdAt.toISOString(),
    invitation: inv,
    rowVersion: r.rowVersion,
  };
}
