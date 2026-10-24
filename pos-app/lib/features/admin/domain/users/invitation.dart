// Приглашение сотрудника (D-07; 08 §4.18.4; OpenAPI `Invitation`, `AdminInvitationsCreateRequest`).
// Сотрудники сами не регистрируются: приглашение — единственный путь создать учётную запись
// сотрудника (ядро v1.9 §24.2, 09 REG-022). Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';

/// Строка вкладки «Приглашения» (UI-45-010).
final class Invitation {
  const Invitation({
    required this.id,
    required this.phoneMasked,
    required this.roles,
    required this.status,
    this.createdByName,
    this.createdAt,
    this.expiresAt,
    this.acceptedAt,
    this.appliedToUserId,
  });

  final String id;

  /// Маска `+996 7** *** *01` (ядро §19.2).
  final String phoneMasked;
  final List<String> roles;

  /// `invitation_status` как пришёл.
  final String status;

  /// `createdBy.displayName`.
  final String? createdByName;
  final DateTime? createdAt;
  final DateTime? expiresAt;
  final DateTime? acceptedAt;

  /// Приглашение сразу применено к существующему аккаунту `pending_activation`/`customer` (09 §7.6).
  final String? appliedToUserId;

  InvitationStatus? get invitationStatus => InvitationStatus.tryParse(status);
  List<RoleCode> get roleCodes => [for (final r in roles) ?RoleCode.tryParse(r)];
  bool get isPending => invitationStatus == InvitationStatus.pending;

  /// «Пригласить снова» — для `expired`/`revoked` (UI-45-010).
  bool get canBeRenewed => invitationStatus == InvitationStatus.expired || invitationStatus == InvitationStatus.revoked;

  Invitation withStatus(String value) => Invitation(
    id: id,
    phoneMasked: phoneMasked,
    roles: roles,
    status: value,
    createdByName: createdByName,
    createdAt: createdAt,
    expiresAt: expiresAt,
    acceptedAt: acceptedAt,
    appliedToUserId: appliedToUserId,
  );

  @override
  String toString() => 'Invitation($id, $status, $roles)';
}

/// Роли, которые выдаются приглашением (11 SEC-136 п.2; backend `INVITABLE_ROLES`):
/// без `owner`, `admin`, `customer`, `integration` (AC-UI-45-020).
const List<RoleCode> invitableRoles = [RoleCode.seller, RoleCode.cashier, RoleCode.seniorSeller];

/// Черновик формы приглашения (UI-45-009).
final class InvitationDraft {
  const InvitationDraft({required this.phoneE164, required this.role, this.fullName, this.expiresAt});

  final String phoneE164;
  final RoleCode role;
  final String? fullName;
  final DateTime? expiresAt;

  @override
  String toString() => 'InvitationDraft(${role.value})';
}

/// Ошибки формы приглашения (02 SCR-45.8).
enum InvitationDraftError { phone, role, fullName, expiry }

/// Правила формы приглашения (02 SCR-45.4, SCR-45.8; Q-141 — срок 1…90 дней, по умолчанию 30).
abstract final class InvitationRules {
  static const int defaultTtlDays = 30;
  static const int minTtlDays = 1;
  static const int maxTtlDays = 90;
  static const int fullNameMin = 2;
  static const int fullNameMax = 150;

  /// Срок по умолчанию (+30 дней от сегодня, `INVITATION_TTL_DAYS`).
  static DateTime defaultExpiry(DateTime today) => _dateOnly(today).add(const Duration(days: defaultTtlDays));

  static DateTime firstExpiry(DateTime today) => _dateOnly(today).add(const Duration(days: minTtlDays));
  static DateTime lastExpiry(DateTime today) => _dateOnly(today).add(const Duration(days: maxTtlDays));

  /// Проверка полей; пустое множество — форму можно отправлять.
  static Set<InvitationDraftError> validate({
    required String? phoneE164,
    required RoleCode? role,
    required String fullName,
    required DateTime? expiresAt,
    required DateTime today,
  }) {
    final errors = <InvitationDraftError>{};
    if (phoneE164 == null || !RegExp(r'^\+996\d{9}$').hasMatch(phoneE164)) errors.add(InvitationDraftError.phone);
    if (role == null || !invitableRoles.contains(role)) errors.add(InvitationDraftError.role);
    final name = fullName.trim();
    if (name.isNotEmpty && (name.length < fullNameMin || name.length > fullNameMax)) {
      errors.add(InvitationDraftError.fullName);
    }
    if (expiresAt != null) {
      final day = _dateOnly(expiresAt);
      if (day.isBefore(firstExpiry(today)) || day.isAfter(lastExpiry(today))) errors.add(InvitationDraftError.expiry);
    }
    return errors;
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
}
