// Доступность действий SCR-45 по роли зрителя и цели (02 SCR-45.10; 11 §4.4, SEC-040, SEC-043,
// SEC-131, SEC-136; ядро §21 п.3). Повторяет серверную политику (`pos-api/src/admin/users/shared/
// target-policy.ts`) только для скрытия/блокировки кнопок — защита на сервере (D-15). Чистый Dart.
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/features/admin/domain/users/admin_user.dart';
import 'package:optomstroy/features/admin/domain/users/admin_viewer.dart';

/// Режим экрана.
enum AdminUsersMode {
  /// Полный режим.
  admin,

  /// Ограниченный режим `owner` (ядро §21 п.3).
  owner,

  /// Нет `users.read` — маршрут недоступен (G-7).
  none,
}

/// Почему вариант роли недоступен (подпись/тултип).
enum RoleOptionBlock {
  /// `admin` не назначает/снимает `owner` (SEC-040) — `admin_users_owner_hint`.
  ownerReserved,

  /// Своя учётная запись (`self_demotion` / `self_target`) — `admin_users_error_self_demotion`.
  self,

  /// `owner` назначает только `admin`/`owner` (ядро §21 п.3).
  ownerScope,

  /// Статус цели не допускает смены роли (`pending_activation` и др.).
  status,
}

/// Состояние варианта `AppRadio` роли (UI-45-005).
final class RoleOption {
  const RoleOption(this.role, [this.block]);

  final RoleCode role;
  final RoleOptionBlock? block;

  bool get enabled => block == null;
}

/// Роли блока «Роль» (UI-45-005): `seller`, `cashier`, `senior_seller`, `admin`, `owner`.
const List<RoleCode> staffRoles = [
  RoleCode.seller,
  RoleCode.cashier,
  RoleCode.seniorSeller,
  RoleCode.admin,
  RoleCode.owner,
];

final class AdminUsersPolicy {
  const AdminUsersPolicy(this.viewer);

  final AdminViewer viewer;

  bool get isAdmin => viewer.isAdmin;
  bool get isOwner => viewer.isOwner;

  AdminUsersMode get mode {
    if (isAdmin && viewer.can(AdminPermissions.usersRead, byRole: true)) return AdminUsersMode.admin;
    if (isOwner && viewer.can(AdminPermissions.usersRead, byRole: true)) return AdminUsersMode.owner;
    return AdminUsersMode.none;
  }

  bool _self(AdminUser t) => t.id == viewer.userId;
  bool _targetOwner(AdminUser t) => t.hasRole(RoleCode.owner);

  /// «+ Пригласить», «Отозвать», «Пригласить снова» — только `admin` (UI-45-008/010/011).
  bool get canManageInvitations => isAdmin && viewer.can(AdminPermissions.invitationsManage, byRole: true);

  /// Вкладка «Приглашения»: `admin` и `owner` (только чтение).
  bool get canSeeInvitations => mode != AdminUsersMode.none;

  /// Вкладка «Привязки клиентов» — только `admin` и только при `customerSelfService=true`
  /// или непустом списке конфликтов (UI-45-001; ядро §19.2).
  bool canSeeLinks({required bool customerSelfService, required bool hasCases}) =>
      isAdmin && viewer.can(AdminPermissions.linkConflictsRead, byRole: true) && (customerSelfService || hasCases);

  /// Подтверждение/отклонение привязки — только `admin` (S!).
  bool get canResolveLinks => isAdmin && viewer.can(AdminPermissions.linkResolve, byRole: true);

  /// Полный телефон в шапке карточки — только `admin` (UI-45-004).
  bool get seesFullPhone => isAdmin;

  /// Варианты ролей для цели [target].
  List<RoleOption> roleOptions(AdminUser target) => [for (final r in staffRoles) RoleOption(r, _roleBlock(target, r))];

  RoleOptionBlock? _roleBlock(AdminUser target, RoleCode role) {
    if (!(target.isActive || target.isBlocked)) return RoleOptionBlock.status;
    if (isAdmin) {
      if (role == RoleCode.owner) return RoleOptionBlock.ownerReserved;
      if (_self(target)) return RoleOptionBlock.self;
      if (_targetOwner(target)) return RoleOptionBlock.ownerReserved;
      return null;
    }
    if (isOwner) {
      if (_self(target)) return RoleOptionBlock.self;
      return role == RoleCode.admin || role == RoleCode.owner ? null : RoleOptionBlock.ownerScope;
    }
    return RoleOptionBlock.ownerScope;
  }

  /// Блок ролей показывается с кнопкой «Сохранить роль» (иначе — только чтение).
  bool canEditRoles(AdminUser target) =>
      viewer.can(AdminPermissions.rolesAssign, byRole: isAdmin || isOwner) && roleOptions(target).any((o) => o.enabled);

  /// Причина, по которой весь блок ролей заблокирован (подпись под блоком), или `null`.
  RoleOptionBlock? rolesBlockReason(AdminUser target) {
    if (canEditRoles(target)) return null;
    if (_self(target)) return RoleOptionBlock.self;
    if (isAdmin && _targetOwner(target)) return RoleOptionBlock.ownerReserved;
    if (!(target.isActive || target.isBlocked)) return RoleOptionBlock.status;
    return RoleOptionBlock.ownerScope;
  }

  /// «Активировать» для `pending_activation` — только `admin` (UI-45-012).
  bool canActivate(AdminUser target) => isAdmin && target.isPendingActivation && target.hasFullPhone;

  /// «Завершить все сессии» (UI-45-006): `admin` — кроме `owner`; `owner` — только `admin`/`owner`; не себя.
  bool canLogoutAll(AdminUser target) {
    if (_self(target)) return false;
    if (isAdmin) return !_targetOwner(target);
    if (isOwner) return target.isPrivileged;
    return false;
  }

  /// Кнопка «Завершить все сессии» видна (у `owner` — только для целей `admin`/`owner`, AC-UI-45-009).
  bool showsLogoutAll(AdminUser target) => isAdmin || (isOwner && target.isPrivileged);

  /// «Заблокировать»/«Разблокировать» видна только `admin` (AC-UI-45-009).
  bool get showsBlock => isAdmin;

  /// Доступна: не себя, не `owner` (SEC-043; AC-UI-45-008).
  bool canBlock(AdminUser target) => isAdmin && !_self(target) && !_targetOwner(target);

  /// «Сбросить PIN» видна только `admin`.
  bool get showsResetPin => isAdmin;

  /// Доступна: не себе, не `customer`, не `owner` (11 §4.4 №69, SEC-043).
  bool canResetPin(AdminUser target) =>
      isAdmin && !_self(target) && target.userKind != UserKind.customer && !_targetOwner(target);

  /// «Выдать аварийный код входа» (UI-45-023): только `admin`; цель — активный `staff`,
  /// не себя, без ролей `admin`/`owner` (SEC-131). Иначе элемента нет (AC-UI-45-019).
  bool showsEmergencyCode(AdminUser target) =>
      isAdmin &&
      viewer.can(AdminPermissions.emergencyCode, byRole: true) &&
      !_self(target) &&
      target.isStaff &&
      target.isActive &&
      !target.isPrivileged;
}
