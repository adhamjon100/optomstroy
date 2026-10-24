import { describe, expect, it } from 'vitest';
import {
  canAssignRole,
  canBlock,
  canInviteRole,
  canIssueEmergencyCode,
  canLogoutAll,
  canResetPin,
  canUpdateProfile,
  type PolicyActor,
  type PolicyTarget,
} from '../../src/admin/users/shared/target-policy.js';
import type { RoleCode } from '../../src/users/users.types.js';

const admin: PolicyActor = { userId: 'a', roles: ['admin'] };
const owner: PolicyActor = { userId: 'o', roles: ['owner'] };
const t = (role: RoleCode | null, over: Partial<PolicyTarget> = {}): PolicyTarget => ({
  id: 't',
  kind: role === 'customer' ? 'customer' : 'staff',
  status: 'active',
  roles: role ? [role] : [],
  ...over,
});
const reason = (d: ReturnType<typeof canBlock>) => (d.ok ? 'ok' : d.code === 'FORBIDDEN' ? d.reason : d.rule);

describe('target-policy: ограничения целей (11 SEC-040, SEC-043, SEC-131, SEC-136; ядро §21 п. 3)', () => {
  it('PUT roles: owner назначает cashier → owner_scope_limited (T-SEC-043); owner назначает admin/owner → ok', () => {
    expect(reason(canAssignRole(owner, t('seller'), 'cashier'))).toBe('owner_scope_limited');
    expect(reason(canAssignRole(owner, t('admin'), 'senior_seller'))).toBe('owner_scope_limited');
    expect(reason(canAssignRole(owner, t('seller'), 'admin'))).toBe('ok');
    expect(reason(canAssignRole(owner, t('admin'), 'owner'))).toBe('ok');
  });

  it('PUT roles: admin — любые роли, кроме owner; цель owner → owner_role_reserved; себе → self_target', () => {
    expect(reason(canAssignRole(admin, t('seller'), 'cashier'))).toBe('ok');
    expect(reason(canAssignRole(admin, t('seller'), 'admin'))).toBe('ok');
    expect(reason(canAssignRole(admin, t('seller'), 'owner'))).toBe('owner_role_reserved');
    expect(reason(canAssignRole(admin, t('owner'), 'admin'))).toBe('owner_role_reserved');
    expect(reason(canAssignRole(admin, { ...t('admin'), id: 'a' }, 'owner'))).toBe('owner_role_reserved');
    expect(reason(canAssignRole(admin, { ...t('admin'), id: 'a' }, 'seller'))).toBe('self_target');
    expect(reason(canAssignRole(admin, t('customer'), 'seller'))).toBe('ok'); // SEC-136 п. 4 — явным действием
  });

  it('PUT roles: integration → 422 integration_role, customer → role_not_assignable, pending_activation → user_pending_activation', () => {
    expect(reason(canAssignRole(admin, t('seller'), 'integration'))).toBe('integration_role');
    expect(reason(canAssignRole(admin, t('seller'), 'customer'))).toBe('role_not_assignable');
    expect(reason(canAssignRole(admin, t(null, { status: 'pending_activation' }), 'seller'))).toBe(
      'user_pending_activation',
    );
    expect(reason(canAssignRole(admin, t(null, { status: 'pending' }), 'seller'))).toBe('user_status');
    expect(reason(canAssignRole(admin, t('seller', { status: 'blocked' }), 'cashier'))).toBe('ok');
  });

  it('block / PATCH / PIN: себя, owner, customer', () => {
    expect(reason(canBlock(admin, { ...t('admin'), id: 'a' }))).toBe('self_target');
    expect(reason(canBlock(admin, t('owner')))).toBe('owner_role_reserved');
    expect(reason(canBlock(admin, t('cashier')))).toBe('ok');
    expect(reason(canBlock(owner, t('admin')))).toBe('owner_scope_limited');
    expect(reason(canUpdateProfile(admin, { ...t('admin'), id: 'a' }))).toBe('ok');
    expect(reason(canUpdateProfile(admin, t('owner')))).toBe('owner_role_reserved');
    expect(reason(canResetPin(admin, t('customer')))).toBe('customer_target');
    expect(reason(canResetPin(admin, t('owner')))).toBe('owner_role_reserved');
    expect(reason(canResetPin(admin, { ...t('admin'), id: 'a' }))).toBe('self_target');
    expect(reason(canResetPin(admin, t('admin')))).toBe('ok');
  });

  it('logout-all: admin — кроме owner; owner — только admin/owner; себя — нет', () => {
    expect(reason(canLogoutAll(admin, t('seller')))).toBe('ok');
    expect(reason(canLogoutAll(admin, t('owner')))).toBe('owner_role_reserved');
    expect(reason(canLogoutAll(owner, t('seller')))).toBe('owner_scope_limited');
    expect(reason(canLogoutAll(owner, t('admin')))).toBe('ok');
    expect(reason(canLogoutAll(owner, t('owner')))).toBe('ok');
    expect(reason(canLogoutAll(owner, { ...t('owner'), id: 'o' }))).toBe('self_target');
  });

  it('аварийный код (SEC-131): себе/admin/owner → 403; не staff или не active → 422; owner не выдаёт', () => {
    expect(reason(canIssueEmergencyCode(admin, t('cashier')))).toBe('ok');
    expect(reason(canIssueEmergencyCode(admin, { ...t('admin'), id: 'a' }))).toBe('self_target');
    expect(reason(canIssueEmergencyCode(admin, t('admin')))).toBe('privileged_target');
    expect(reason(canIssueEmergencyCode(admin, t('owner')))).toBe('privileged_target');
    expect(reason(canIssueEmergencyCode(admin, t('customer')))).toBe('target_not_active_staff');
    expect(reason(canIssueEmergencyCode(admin, t('seller', { status: 'blocked' })))).toBe('target_not_active_staff');
    expect(reason(canIssueEmergencyCode(owner, t('seller')))).toBe('owner_scope_limited');
  });

  it('роль приглашения (SEC-136 п. 2, SEC-040): seller/cashier/senior_seller; owner → owner_role_reserved; admin → role_not_invitable', () => {
    for (const r of ['seller', 'cashier', 'senior_seller']) expect(reason(canInviteRole(r))).toBe('ok');
    expect(reason(canInviteRole('owner'))).toBe('owner_role_reserved');
    expect(reason(canInviteRole('admin'))).toBe('role_not_invitable');
  });
});
