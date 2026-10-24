// Кто открыл SCR-45 (`GET /me`: id, roles, permissions). Скрытие кнопок — не защита:
// все права дублирует сервер (D-15, SEC-028, SEC-043). Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';

final class AdminViewer {
  const AdminViewer({required this.userId, required this.roles, this.permissions = const {}});

  final String userId;
  final List<RoleCode> roles;

  /// Коды прав 11 §4.3 из `Me.permissions` (пусто — права выводятся из роли).
  final Set<String> permissions;

  bool get isAdmin => roles.contains(RoleCode.admin);

  /// `owner` без `admin` (backend `isOwnerActor`).
  bool get isOwner => roles.contains(RoleCode.owner) && !isAdmin;

  /// Право есть в `permissions` или (если сервер их не прислал) следует из роли.
  bool can(String permission, {required bool byRole}) =>
      permissions.isEmpty ? byRole : permissions.contains(permission);

  @override
  String toString() => 'AdminViewer(${roles.map((r) => r.value).toList()})';
}

/// Коды прав 11 §4.3, которые использует SCR-45.
abstract final class AdminPermissions {
  static const String usersRead = 'users.read';
  static const String usersManage = 'users.manage';
  static const String rolesAssign = 'users.roles.assign';
  static const String pinReset = 'users.pin.reset';
  static const String emergencyCode = 'users.emergency_code.issue';
  static const String sessionRevokeAny = 'session.revoke.any';
  static const String invitationsManage = 'invitations.manage';
  static const String linkConflictsRead = 'customer.link.conflicts.read';
  static const String linkResolve = 'customer.link.resolve';
}
