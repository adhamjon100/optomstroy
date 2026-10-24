import type { RoleCode, UserKind, UserStatusValue } from '../../../users/users.types.js';

/**
 * Ограничения целей админских операций (object-level, 11 §4.1 п. 5): права проверяет RbacGuard по
 * permissions.yaml, а «кто над кем» — эти чистые функции (11 SEC-040, SEC-043, SEC-131, SEC-136; ядро §21 п. 3;
 * 08 §4.18.1–§4.18.3, §4.18.9, §4.18.10). Deny by default: всё, что не разрешено явно, — отказ.
 */
export interface PolicyActor {
  readonly userId: string;
  readonly roles: readonly string[];
}

export interface PolicyTarget {
  readonly id: string;
  readonly kind: UserKind;
  readonly status: UserStatusValue;
  readonly roles: readonly RoleCode[];
}

export type PolicyDecision =
  | { readonly ok: true }
  | { readonly ok: false; readonly code: 'FORBIDDEN'; readonly reason: PolicyDenyReason }
  | {
      readonly ok: false;
      readonly code: 'VALIDATION_FAILED';
      readonly rule: string;
      readonly field: string;
      readonly message: string;
    };

/** Машинные причины `403 FORBIDDEN` (поле `reason` Problem, 08 §3.3). */
export type PolicyDenyReason =
  /** `admin` над пользователем с ролью `owner` (SEC-043) или назначение/снятие `owner` ролью `admin` (SEC-040). */
  | 'owner_role_reserved'
  /** Действие над собой через `/admin/users/{self}/*` (кроме PATCH fullName; SEC-043). */
  | 'self_target'
  /** `owner` действует только над целями/ролями `admin`/`owner` (ядро §21 п. 3). */
  | 'owner_scope_limited'
  /** Сброс PIN `customer`-аккаунту (SEC-043). */
  | 'customer_target'
  /** Аварийный код для `admin`/`owner` (SEC-131). */
  | 'privileged_target'
  /** Роль не создаётся приглашением/`POST /admin/users` (SEC-136 п. 2: только seller/cashier/senior_seller). */
  | 'role_not_invitable';

const OK: PolicyDecision = { ok: true };
const PRIVILEGED: ReadonlySet<string> = new Set(['admin', 'owner']);
/** Роли, которые создаются приглашением / `POST /admin/users` (SEC-136 п. 2; ядро §24.2). */
export const INVITABLE_ROLES = ['seller', 'cashier', 'senior_seller'] as const;
export type InvitableRole = (typeof INVITABLE_ROLES)[number];
/** Роли, назначаемые `PUT /admin/users/{id}/roles` (без `customer` и `integration`). */
export const STAFF_ROLES = ['seller', 'cashier', 'senior_seller', 'admin', 'owner'] as const;

const forbid = (reason: PolicyDenyReason): PolicyDecision => ({ ok: false, code: 'FORBIDDEN', reason });
const invalid = (rule: string, field: string, message: string): PolicyDecision => ({
  ok: false,
  code: 'VALIDATION_FAILED',
  rule,
  field,
  message,
});

/** Субъект — администратор (в R1 одна роль; `admin` приоритетнее при гипотетических двух). */
export const isAdminActor = (a: PolicyActor): boolean => a.roles.includes('admin');
export const isOwnerActor = (a: PolicyActor): boolean => a.roles.includes('owner') && !a.roles.includes('admin');
const targetIsOwner = (t: PolicyTarget): boolean => t.roles.includes('owner');
const targetIsPrivileged = (t: PolicyTarget): boolean => t.roles.some((r) => PRIVILEGED.has(r));

/** `PATCH /admin/users/{id}` (users.manage): над собой — можно (только fullName); `admin` над `owner` — нет. */
export function canUpdateProfile(actor: PolicyActor, target: PolicyTarget): PolicyDecision {
  if (actor.userId === target.id) return OK;
  if (!isAdminActor(actor)) return forbid('owner_scope_limited');
  if (targetIsOwner(target)) return forbid('owner_role_reserved');
  return OK;
}

/** `POST /admin/users/{id}/block` (users.manage, только `admin`): не себя, не `owner`. */
export function canBlock(actor: PolicyActor, target: PolicyTarget): PolicyDecision {
  if (actor.userId === target.id) return forbid('self_target');
  if (!isAdminActor(actor)) return forbid('owner_scope_limited');
  if (targetIsOwner(target)) return forbid('owner_role_reserved');
  return OK;
}

/**
 * `POST /admin/users/{id}/logout-all` (session.revoke.any): не себя (свои — `/auth/logout-all`); `admin` — любые
 * цели, кроме `owner`; `owner` — только цели с ролью `admin`/`owner` (ядро §21 п. 3).
 */
export function canLogoutAll(actor: PolicyActor, target: PolicyTarget): PolicyDecision {
  if (actor.userId === target.id) return forbid('self_target');
  if (isAdminActor(actor)) return targetIsOwner(target) ? forbid('owner_role_reserved') : OK;
  if (isOwnerActor(actor)) return targetIsPrivileged(target) ? OK : forbid('owner_scope_limited');
  return forbid('owner_scope_limited');
}

/** `DELETE /admin/users/{id}/pin` (users.pin.reset, только `admin`): не себя, не `customer`, не `owner`. */
export function canResetPin(actor: PolicyActor, target: PolicyTarget): PolicyDecision {
  if (actor.userId === target.id) return forbid('self_target');
  if (!isAdminActor(actor)) return forbid('owner_scope_limited');
  if (target.kind === 'customer') return forbid('customer_target');
  if (targetIsOwner(target)) return forbid('owner_role_reserved');
  return OK;
}

/**
 * `POST /admin/users/{id}/emergency-login-code` (users.emergency_code.issue, только `admin`; SEC-131, 08 §4.18.10):
 * себе и целям с ролью `admin`/`owner` → 403; цель не `kind=staff` или не `status=active` → 422.
 */
export function canIssueEmergencyCode(actor: PolicyActor, target: PolicyTarget): PolicyDecision {
  if (actor.userId === target.id) return forbid('self_target');
  if (!isAdminActor(actor)) return forbid('owner_scope_limited');
  if (targetIsPrivileged(target)) return forbid('privileged_target');
  if (target.kind !== 'staff' || target.status !== 'active') {
    return invalid('target_not_active_staff', 'id', 'Аварийный код выдаётся только активному сотруднику.');
  }
  return OK;
}

/**
 * `PUT /admin/users/{id}/roles` (users.roles.assign; 08 §4.18.2; SEC-040, SEC-043, SEC-136 п. 4; ядро §21 п. 3):
 * - `integration` → 422 `integration_role` (ядро §18.2 п. 4); `customer` → 422 `role_not_assignable`;
 * - цель `pending_activation` → 422 `user_pending_activation` (активация — `POST /admin/users`); иные статусы,
 *   кроме `active`/`blocked`, → 422 `user_status`;
 * - смена своей роли → 403 `self_target` (SEC-043; повтор той же роли — no-op сервиса, но только после политики);
 * - `admin`: назначение `owner` или цель с ролью `owner` → 403 `owner_role_reserved`;
 * - `owner`: только назначение ролей `admin`/`owner` → иначе 403 `owner_scope_limited` (12 T-SEC-043).
 */
export function canAssignRole(actor: PolicyActor, target: PolicyTarget, role: string): PolicyDecision {
  if (role === 'integration') {
    return invalid('integration_role', 'roles', 'Роль integration не назначается пользователю (технический токен).');
  }
  if (!(STAFF_ROLES as readonly string[]).includes(role)) {
    return invalid('role_not_assignable', 'roles', 'Эта роль не назначается через администрирование.');
  }
  if (target.status === 'pending_activation') {
    return invalid('user_pending_activation', 'id', 'Пользователь не активирован: используйте POST /admin/users.');
  }
  if (target.status !== 'active' && target.status !== 'blocked') {
    return invalid('user_status', 'id', 'Роль меняется только у активного или заблокированного пользователя.');
  }
  // самоповышение admin → owner — именно owner_role_reserved (AC-SEC-040), прочая смена своей роли — self_target
  if (isAdminActor(actor) && role === 'owner') return forbid('owner_role_reserved');
  if (actor.userId === target.id) return forbid('self_target');
  if (isAdminActor(actor)) return targetIsOwner(target) ? forbid('owner_role_reserved') : OK;
  if (isOwnerActor(actor)) return PRIVILEGED.has(role) ? OK : forbid('owner_scope_limited');
  return forbid('owner_scope_limited');
}

/**
 * Роль приглашения / `POST /admin/users` (SEC-136 п. 2, SEC-040): `owner` → 403 `owner_role_reserved`; прочие роли
 * вне seller/cashier/senior_seller → 403 `role_not_invitable`.
 */
export function canInviteRole(role: string): PolicyDecision {
  if (role === 'owner') return forbid('owner_role_reserved');
  if (!(INVITABLE_ROLES as readonly string[]).includes(role)) return forbid('role_not_invitable');
  return OK;
}
