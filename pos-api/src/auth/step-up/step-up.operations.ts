import type { PermissionCode } from '../../common/rbac/permissions.generated.js';

/**
 * Значения `operation` step-up (08 §2.12; OpenAPI `StepUpOperation`): узкие `profile.*`/`session.*` и коды
 * 11 §4.3 с собственным step-up. Клиент берёт `operation` из `403 STEP_UP_REQUIRED.stepUp.operation`.
 */
export const STEP_UP_OPERATIONS = [
  'profile.phone.change',
  'profile.pin.set',
  'profile.biometrics.toggle',
  'profile.consent.revoke',
  'session.logout_all',
  'session.revoke.other',
  'order.cancel.request.any',
  'payment.qr.confirm_manual',
  'payment.void',
  'discount.approve.over_limit',
  'credit.sale.approve',
  'return.submit',
  'return.approve',
  'customer.receivables.read.detail',
  'customer.link.resolve',
  'order.onec_link',
  'sync.run.full',
  'users.manage',
  'users.roles.assign',
  'users.pin.reset',
  'users.emergency_code.issue',
  'session.revoke.any',
  'invitations.manage',
  'settings.app.update',
  'settings.discount_limits.update',
] as const;

export type StepUpOperation = (typeof STEP_UP_OPERATIONS)[number];

export function isStepUpOperation(v: unknown): v is StepUpOperation {
  return typeof v === 'string' && (STEP_UP_OPERATIONS as readonly string[]).includes(v);
}

/** Методы step-up R1 (ядро §19.3): `pin`, `otp`; биометрия — R2. */
export const STEP_UP_METHODS_R1 = ['pin', 'otp'] as const;
export type StepUpMethodR1 = (typeof STEP_UP_METHODS_R1)[number];

/**
 * Право 11 §4.3, которое должно быть у субъекта для `operation` (08 §2.12: «проверка права — по коду 11 §4.3»):
 * `profile.*` → `profile.manage.own`, `session.logout_all`/`session.revoke.other` → `session.manage.own`, иначе —
 * сам код.
 */
export function permissionForOperation(op: StepUpOperation): PermissionCode {
  if (op.startsWith('profile.')) return 'profile.manage.own';
  if (op === 'session.logout_all' || op === 'session.revoke.other') return 'session.manage.own';
  return op as PermissionCode;
}

/**
 * Можно ли выдать step-up на `operation` субъекту с правами `granted`. Детализация долга
 * (`customer.receivables.read.detail`) — step-up «для всех ролей без исключений, включая `customer`» (08 §4.11.5;
 * 11 §4.1 п. 7 — область `finance_view` = `customer.receivables.read.detail` + `customer.self.receivables.read`, §4.2,
 * SEC-033): клиенту — по праву на свой долг (ревью G-security-3).
 */
export function stepUpPermitted(op: StepUpOperation, granted: ReadonlySet<string>): boolean {
  if (granted.has(permissionForOperation(op))) return true;
  return op === 'customer.receivables.read.detail' && granted.has('customer.self.receivables.read');
}

/**
 * Область токена (claim `scope`): ровно `[operation]` — узкая область 08 §2.12 (один step-up не открывает на
 * 15 мин все профильные действия). В ответе `AuthStepUpToken.scope` — коды permissions (схема `PermissionCode`).
 */
export function tokenScope(op: StepUpOperation): readonly string[] {
  return [op];
}
