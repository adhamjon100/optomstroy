// Политика действий SCR-45 (02 SCR-45.10; 11 §4.4, SEC-040, SEC-043, SEC-131; ядро §21 п.3).
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/features/admin/domain/users/admin_user.dart';
import 'package:optomstroy/features/admin/domain/users/admin_users_policy.dart';
import 'package:optomstroy/features/admin/domain/users/admin_viewer.dart';

import '../support/fake_admin_repository.dart';

void main() {
  const admin = AdminUsersPolicy(adminViewer);
  const owner = AdminUsersPolicy(ownerViewer);
  final cashier = staff(cashierId);
  final ownerUser = staff(ownerId, role: RoleCode.owner);
  final otherAdmin = staff(otherAdminId, role: RoleCode.admin);
  final self = staff(adminId, role: RoleCode.admin);

  Set<RoleCode> enabled(AdminUsersPolicy p, AdminUser target) =>
      p.roleOptions(target).where((o) => o.enabled).map((o) => o.role).toSet();

  group('режим', () {
    test('admin → полный, owner → ограниченный, прочие → нет доступа', () {
      expect(admin.mode, AdminUsersMode.admin);
      expect(owner.mode, AdminUsersMode.owner);
      expect(const AdminUsersPolicy(AdminViewer(userId: 'x', roles: [RoleCode.cashier])).mode, AdminUsersMode.none);
    });

    test('permissions от сервера: без users.read режим none', () {
      const p = AdminUsersPolicy(AdminViewer(userId: 'x', roles: [RoleCode.admin], permissions: {'catalog.read'}));
      expect(p.mode, AdminUsersMode.none);
    });
  });

  group('admin', () {
    test('роли цели-кассира: все, кроме owner (SEC-040)', () {
      expect(enabled(admin, cashier), {RoleCode.seller, RoleCode.cashier, RoleCode.seniorSeller, RoleCode.admin});
      final ownerOption = admin.roleOptions(cashier).firstWhere((o) => o.role == RoleCode.owner);
      expect(ownerOption.block, RoleOptionBlock.ownerReserved);
    });

    test('цель owner и своя учётная запись: блок ролей недоступен', () {
      expect(admin.canEditRoles(ownerUser), isFalse);
      expect(admin.rolesBlockReason(ownerUser), RoleOptionBlock.ownerReserved);
      expect(admin.canEditRoles(self), isFalse);
      expect(admin.rolesBlockReason(self), RoleOptionBlock.self);
    });

    test('pending_activation: роли не меняются, доступна активация', () {
      final pending = staff(pendingId, status: 'pending_activation', kind: 'customer');
      expect(admin.canEditRoles(pending), isFalse);
      expect(admin.canActivate(pending), isTrue);
      expect(owner.canActivate(pending), isFalse);
    });

    test('блокировка и сброс PIN: не себя, не owner, сброс PIN — не customer (AC-UI-45-008, -019)', () {
      expect(admin.canBlock(cashier), isTrue);
      expect(admin.canBlock(self), isFalse);
      expect(admin.canBlock(ownerUser), isFalse);
      expect(admin.canResetPin(cashier), isTrue);
      expect(admin.canResetPin(self), isFalse);
      expect(admin.canResetPin(ownerUser), isFalse);
      expect(admin.canResetPin(staff('c2', kind: 'customer', role: RoleCode.customer)), isFalse);
    });

    test('logout-all: любые цели, кроме owner и себя (SEC-043)', () {
      expect(admin.canLogoutAll(cashier), isTrue);
      expect(admin.canLogoutAll(otherAdmin), isTrue);
      expect(admin.canLogoutAll(ownerUser), isFalse);
      expect(admin.canLogoutAll(self), isFalse);
    });

    test('аварийный код: только активный staff, не себе, не admin/owner (SEC-131, AC-UI-45-019)', () {
      expect(admin.showsEmergencyCode(cashier), isTrue);
      expect(admin.showsEmergencyCode(self), isFalse);
      expect(admin.showsEmergencyCode(otherAdmin), isFalse);
      expect(admin.showsEmergencyCode(ownerUser), isFalse);
      expect(admin.showsEmergencyCode(staff('b', status: 'blocked')), isFalse);
      expect(admin.showsEmergencyCode(staff('p', status: 'pending_activation')), isFalse);
      expect(admin.showsEmergencyCode(staff('k', kind: 'customer', role: RoleCode.customer)), isFalse);
    });

    test('приглашения и привязки — только admin', () {
      expect(admin.canManageInvitations, isTrue);
      expect(admin.canSeeLinks(customerSelfService: true, hasCases: false), isTrue);
      expect(admin.canSeeLinks(customerSelfService: false, hasCases: false), isFalse);
      expect(admin.canSeeLinks(customerSelfService: false, hasCases: true), isTrue);
      expect(admin.canResolveLinks, isTrue);
    });
  });

  group('owner (ядро §21 п.3)', () {
    test('роли: только admin/owner; seller/cashier/senior_seller недоступны (T-SEC-043)', () {
      expect(enabled(owner, cashier), {RoleCode.admin, RoleCode.owner});
      expect(owner.roleOptions(cashier).where((o) => !o.enabled).map((o) => o.block).toSet(), {
        RoleOptionBlock.ownerScope,
      });
    });

    test('logout-all — только учётные записи admin/owner', () {
      expect(owner.canLogoutAll(otherAdmin), isTrue);
      expect(owner.showsLogoutAll(otherAdmin), isTrue);
      expect(owner.canLogoutAll(cashier), isFalse);
      expect(owner.showsLogoutAll(cashier), isFalse);
      expect(owner.canLogoutAll(staff(ownerId, role: RoleCode.owner)), isFalse);
    });

    test('нет приглашений, блокировки, сброса PIN, аварийного кода и привязок', () {
      expect(owner.canManageInvitations, isFalse);
      expect(owner.canSeeInvitations, isTrue);
      expect(owner.showsBlock, isFalse);
      expect(owner.showsResetPin, isFalse);
      expect(owner.showsEmergencyCode(cashier), isFalse);
      expect(owner.canSeeLinks(customerSelfService: true, hasCases: true), isFalse);
      expect(owner.seesFullPhone, isFalse);
    });
  });
}
