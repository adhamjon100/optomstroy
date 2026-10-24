// Сущности SCR-45 «Пользователи» (02 SCR-45; 08 §4.18.1; OpenAPI `AdminUser`).
// Чистый Dart (FL-01). Содержит ПДн (ФИО, телефон) — только в памяти: данные пользователей
// не кэшируются в drift (AC-UI-45-015), `toString` значений не выводит (NFR-LOG-001).
import 'package:optomstroy/core/enums.dart';

/// Пользователь в админ-разделе (`AdminUser`).
final class AdminUser {
  const AdminUser({
    required this.id,
    required this.kind,
    required this.status,
    required this.roles,
    this.phone,
    this.fullName,
    this.permissionsVersion = 0,
    this.lastLoginAt,
    this.devicesCount = 0,
    this.createdAt,
    this.invitation,
    this.rowVersion = 0,
  });

  final String id;

  /// `user_kind` как пришёл (`staff` / `customer`); неизвестное значение не ломает разбор (08 §2.11).
  final String kind;

  /// `user_status` как пришёл.
  final String status;

  /// Роли (`RoleCode`) строками; в R1 — одна активная роль (07 §5.7).
  final List<String> roles;

  /// Поле `phoneMasked`: для `admin` — полный номер E.164, для `owner` — маска `+996 7** *** *01` (08 §4.18.1).
  final String? phone;
  final String? fullName;
  final int permissionsVersion;
  final DateTime? lastLoginAt;
  final int devicesCount;
  final DateTime? createdAt;

  /// Приглашение, по которому создан пользователь (`pending|accepted`); `null` — самостоятельная регистрация.
  final AdminUserInvitation? invitation;

  /// Версия строки для `PUT …/roles` (`VERSION_CONFLICT`).
  final int rowVersion;

  UserKind? get userKind => UserKind.tryParse(kind);
  UserStatus? get userStatus => UserStatus.tryParse(status);

  /// Известные роли; неизвестные значения отбрасываются.
  List<RoleCode> get roleCodes => [for (final r in roles) ?RoleCode.tryParse(r)];

  /// Роль для `AppRadio` (R1 — одна роль, 02 SCR-45.4 «Множественные роли»).
  RoleCode? get primaryRole {
    final codes = roleCodes;
    return codes.isEmpty ? null : codes.first;
  }

  bool hasRole(RoleCode role) => roles.contains(role.value);

  /// Есть роль `admin` или `owner` (SEC-131, ядро §21 п.3).
  bool get isPrivileged => hasRole(RoleCode.admin) || hasRole(RoleCode.owner);

  bool get isStaff => userKind == UserKind.staff;
  bool get isActive => userStatus == UserStatus.active;
  bool get isBlocked => userStatus == UserStatus.blocked;
  bool get isPendingActivation => userStatus == UserStatus.pendingActivation;

  /// Номер — полный E.164 (видит только `admin`), а не маска.
  bool get hasFullPhone => phone != null && RegExp(r'^\+996\d{9}$').hasMatch(phone!);

  AdminUser copyWith({String? status, List<String>? roles, int? devicesCount, int? rowVersion}) => AdminUser(
    id: id,
    kind: kind,
    status: status ?? this.status,
    roles: roles ?? this.roles,
    phone: phone,
    fullName: fullName,
    permissionsVersion: permissionsVersion,
    lastLoginAt: lastLoginAt,
    devicesCount: devicesCount ?? this.devicesCount,
    createdAt: createdAt,
    invitation: invitation,
    rowVersion: rowVersion ?? this.rowVersion,
  );

  @override
  bool operator ==(Object other) =>
      other is AdminUser &&
      other.id == id &&
      other.status == status &&
      other.rowVersion == rowVersion &&
      other.devicesCount == devicesCount &&
      _listEquals(other.roles, roles);

  @override
  int get hashCode => Object.hash(id, status, rowVersion, devicesCount, Object.hashAll(roles));

  @override
  String toString() => 'AdminUser($id, $kind, $status, $roles)';
}

/// `AdminUser.invitation`.
final class AdminUserInvitation {
  const AdminUserInvitation({required this.status, this.createdAt});

  /// `pending` / `accepted`.
  final String status;
  final DateTime? createdAt;
}

/// Фильтры списка `GET /admin/users` (UI-45-002; параметры — в URL `?q=&role=&status=`).
final class AdminUsersQuery {
  const AdminUsersQuery({this.q = '', this.role, this.status, this.cursor, this.limit = 50});

  final String q;
  final RoleCode? role;
  final UserStatus? status;
  final String? cursor;
  final int limit;

  /// Поиск отправляется при ≥ 2 буквах или ≥ 3 цифрах телефона (02 SCR-45.4).
  String? get effectiveQuery {
    final text = q.trim();
    if (text.isEmpty) return null;
    final digits = text.replaceAll(RegExp(r'\D'), '');
    final letters = text.replaceAll(RegExp(r'[\d\s+()-]'), '');
    if (letters.length >= 2 || digits.length >= 3) return text;
    return null;
  }

  AdminUsersQuery copyWith({
    String? q,
    RoleCode? role,
    UserStatus? status,
    String? cursor,
    bool clearRole = false,
    bool clearStatus = false,
    bool clearCursor = false,
  }) => AdminUsersQuery(
    q: q ?? this.q,
    role: clearRole ? null : (role ?? this.role),
    status: clearStatus ? null : (status ?? this.status),
    cursor: clearCursor ? null : (cursor ?? this.cursor),
    limit: limit,
  );

  @override
  bool operator ==(Object other) =>
      other is AdminUsersQuery &&
      other.q == q &&
      other.role == role &&
      other.status == status &&
      other.cursor == cursor &&
      other.limit == limit;

  @override
  int get hashCode => Object.hash(q, role, status, cursor, limit);

  @override
  String toString() => 'AdminUsersQuery(q: ${q.isEmpty ? '' : '***'}, role: ${role?.value}, status: ${status?.value})';
}

/// Страница курсорной пагинации (08 §2.5).
final class AdminPage<T> {
  const AdminPage({required this.items, this.nextCursor, this.hasMore = false, this.totalEstimate});

  final List<T> items;
  final String? nextCursor;
  final bool hasMore;
  final int? totalEstimate;

  /// Счётчик вкладки: `totalEstimate` или длина загруженного списка (UI-45-001).
  int get count => totalEstimate ?? items.length;
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
