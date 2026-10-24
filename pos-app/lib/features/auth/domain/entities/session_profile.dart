// Профиль сессии без телефона (09 §9.3; 02 §0.4): что знает клиент о вошедшем
// пользователе для маршрутизации и SCR-08. ФИО — ПДн: только память, toString без значений.
import 'package:optomstroy/core/enums.dart';

/// Сводка о пользователе сессии (из `Me` ответа `/auth/otp/verify` или кэша профиля).
final class SessionProfile {
  const SessionProfile({
    required this.kind,
    required this.roles,
    this.status,
    this.pinSet,
    this.biometricsEnabled,
    this.displayName,
    this.pinLength,
  });

  /// `staff` / `customer`; `null` — неизвестно (нет кэша).
  final UserKind? kind;
  final List<RoleCode> roles;
  final UserStatus? status;

  /// `Me.security.pinSet`.
  final bool? pinSet;

  /// `Me.security.biometricsEnabled`.
  final bool? biometricsEnabled;

  /// ФИО для SCR-08 (ПДн; в логи не попадает).
  final String? displayName;

  /// Длина PIN, если известна (`security.pinLength` — Q, см. D_spec_questions).
  final int? pinLength;

  /// Пустой профиль: пользователь неизвестен (холодный старт без кэша).
  static const SessionProfile unknown = SessionProfile(kind: null, roles: <RoleCode>[]);

  bool get isStaff => kind == UserKind.staff;
  bool get isCustomer => kind == UserKind.customer;

  /// Длина точек `PinField` на SCR-08: известная длина, иначе 6 для `staff` (02 UI-08-006),
  /// 4 — для `customer` (минимум политики 09 §9.6).
  int get effectivePinLength => pinLength ?? (isCustomer ? 4 : 6);

  /// Главная роль для выбора главного экрана (порядок старшинства 11 §4.2).
  RoleCode? get primaryRole {
    for (final RoleCode r in const <RoleCode>[
      RoleCode.admin,
      RoleCode.owner,
      RoleCode.seniorSeller,
      RoleCode.seller,
      RoleCode.cashier,
      RoleCode.customer,
    ]) {
      if (roles.contains(r)) {
        return r;
      }
    }
    return isCustomer ? RoleCode.customer : null;
  }

  @override
  String toString() => 'SessionProfile(${kind?.value}, ${roles.map((RoleCode r) => r.value).join(',')})';
}
