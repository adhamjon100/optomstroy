// Разбор DTO SCR-45 вручную (ADR-085): contracts/openapi/pos-api.v1.yaml — `AdminUser`, `Invitation`,
// `AdminEmergencyLoginCode`, `CustomersListItem` (+ `CustomersLinkWithUser`), `CustomerLink`,
// `AuthStepUpToken`, `AuthOtpChallengeIssued`, `Page`. Поля сверяет
// test/features/admin/data/admin_users_dto_test.dart. Неизвестные enum-значения — строками (08 §2.11).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/features/admin/domain/users/admin_user.dart';
import 'package:optomstroy/features/admin/domain/users/admin_viewer.dart';
import 'package:optomstroy/features/admin/domain/users/customer_link_case.dart';
import 'package:optomstroy/features/admin/domain/users/emergency_login_code.dart';
import 'package:optomstroy/features/admin/domain/users/invitation.dart';
import 'package:optomstroy/features/admin/domain/users/step_up.dart';

/// Ответ не соответствует контракту (обязательное поле отсутствует или другого типа).
final class AdminDtoException implements Exception {
  const AdminDtoException(this.field);

  final String field;

  @override
  String toString() => 'AdminDtoException($field)';
}

abstract final class AdminUsersDto {
  static Map<String, dynamic> _map(Object? json, String field) {
    if (json is Map<String, dynamic>) return json;
    throw AdminDtoException(field);
  }

  static String _str(Map<String, dynamic> j, String key) {
    final v = j[key];
    if (v is String) return v;
    throw AdminDtoException(key);
  }

  static String? _optStr(Map<String, dynamic> j, String key) {
    final v = j[key];
    return v is String ? v : null;
  }

  static int _int(Map<String, dynamic> j, String key, [int fallback = 0]) {
    final v = j[key];
    return v is int ? v : fallback;
  }

  static DateTime? _date(Map<String, dynamic> j, String key) {
    final v = j[key];
    return v is String ? DateTime.tryParse(v) : null;
  }

  static List<String> _strings(Map<String, dynamic> j, String key, {bool required = false}) {
    final v = j[key];
    if (v is List) return v.whereType<String>().toList();
    if (required) throw AdminDtoException(key);
    return const [];
  }

  /// `Page<T>`.
  static AdminPage<T> page<T>(Object? json, T Function(Map<String, dynamic> item) item) {
    final j = _map(json, 'page');
    final raw = j['items'];
    if (raw is! List) throw const AdminDtoException('items');
    return AdminPage<T>(
      items: [for (final e in raw) item(_map(e, 'items[]'))],
      nextCursor: _optStr(j, 'nextCursor'),
      hasMore: j['hasMore'] == true,
      totalEstimate: j['totalEstimate'] is int ? j['totalEstimate'] as int : null,
    );
  }

  /// `AdminUser`.
  static AdminUser user(Object? json) {
    final j = _map(json, 'AdminUser');
    final inv = j['invitation'];
    return AdminUser(
      id: _str(j, 'id'),
      kind: _str(j, 'kind'),
      status: _str(j, 'status'),
      roles: _strings(j, 'roles', required: true),
      phone: _optStr(j, 'phoneMasked'),
      fullName: _optStr(j, 'fullName'),
      permissionsVersion: _int(j, 'permissionsVersion'),
      lastLoginAt: _date(j, 'lastLoginAt'),
      devicesCount: _int(j, 'devicesCount'),
      createdAt: _date(j, 'createdAt'),
      invitation: inv is Map<String, dynamic> && inv['status'] is String
          ? AdminUserInvitation(status: inv['status'] as String, createdAt: _date(inv, 'createdAt'))
          : null,
      rowVersion: _int(j, 'rowVersion'),
    );
  }

  /// `Invitation`.
  static Invitation invitation(Object? json) {
    final j = _map(json, 'Invitation');
    final by = j['createdBy'];
    return Invitation(
      id: _str(j, 'id'),
      phoneMasked: _str(j, 'phoneMasked'),
      roles: _strings(j, 'roles', required: true),
      status: _str(j, 'status'),
      createdByName: by is Map<String, dynamic> ? _optStr(by, 'displayName') : null,
      createdAt: _date(j, 'createdAt'),
      expiresAt: _date(j, 'expiresAt'),
      acceptedAt: _date(j, 'acceptedAt'),
      appliedToUserId: _optStr(j, 'appliedToUserId'),
    );
  }

  /// Тело `POST /admin/invitations` (`AdminInvitationsCreateRequest`, additionalProperties: false).
  static Map<String, Object?> invitationRequest(InvitationDraft draft) {
    final name = draft.fullName?.trim() ?? '';
    return {
      'phone': draft.phoneE164,
      'roles': [draft.role.value],
      if (name.isNotEmpty) 'fullName': name,
      if (draft.expiresAt != null) 'expiresAt': _endOfDayUtc(draft.expiresAt!).toIso8601String(),
    };
  }

  /// «Действует до» — включительно до конца выбранного дня (локальное время устройства).
  static DateTime _endOfDayUtc(DateTime day) => DateTime(day.year, day.month, day.day, 23, 59, 59).toUtc();

  /// `AdminEmergencyLoginCode`.
  static EmergencyLoginCode emergencyCode(Object? json) {
    final j = _map(json, 'AdminEmergencyLoginCode');
    final expires = _date(j, 'expiresAt');
    if (expires == null) throw const AdminDtoException('expiresAt');
    return EmergencyLoginCode(code: _str(j, 'code'), expiresAt: expires, phoneMasked: _str(j, 'phoneMasked'));
  }

  /// `CustomersListItem` с `links[]` (`CustomersLinkWithUser`).
  static CustomerLinkCase linkCase(Object? json) {
    final j = _map(json, 'CustomersListItem');
    final id = _str(j, 'id');
    final rawLinks = j['links'];
    final phones = j['phones'];
    return CustomerLinkCase(
      customerId: id,
      name: _str(j, 'name'),
      displayName: _optStr(j, 'displayName'),
      inn: _optStr(j, 'inn'),
      onecCode: _optStr(j, 'onecCode'),
      // `CustomerPhone {value, verified}` (у `admin` — полные номера, 09 §7.9).
      phones: phones is List
          ? [
              for (final p in phones)
                if (p is Map<String, dynamic> && p['value'] is String) p['value'] as String,
            ]
          : const [],
      links: rawLinks is List ? [for (final l in rawLinks) link(l, customerId: id)] : const [],
    );
  }

  /// `CustomerLink` / `CustomersLinkWithUser`.
  static CustomerLinkCandidate link(Object? json, {String? customerId}) {
    final j = _map(json, 'CustomerLink');
    final user = j['user'];
    final u = user is Map<String, dynamic> ? user : const <String, dynamic>{};
    return CustomerLinkCandidate(
      id: _str(j, 'id'),
      customerId: _optStr(j, 'customerId') ?? customerId ?? (throw const AdminDtoException('customerId')),
      status: _str(j, 'status'),
      userId: _optStr(j, 'userId') ?? _optStr(u, 'id'),
      userDisplayName: _optStr(u, 'displayName'),
      userPhoneMasked: _optStr(u, 'phoneMasked'),
      matchedBy: _optStr(j, 'matchedBy'),
      createdAt: _date(j, 'createdAt'),
    );
  }

  /// `Me` → зритель SCR-45 (только id, roles, permissions; ПДн не читаются).
  static AdminViewer viewer(Object? json) {
    final j = _map(json, 'Me');
    return AdminViewer(
      userId: _str(j, 'id'),
      roles: [for (final r in _strings(j, 'roles', required: true)) ?RoleCode.tryParse(r)],
      permissions: _strings(j, 'permissions').toSet(),
    );
  }

  /// `AuthStepUpToken`.
  static StepUpGrant stepUpGrant(Object? json) {
    final j = _map(json, 'AuthStepUpToken');
    final expires = _date(j, 'expiresAt');
    if (expires == null) throw const AdminDtoException('expiresAt');
    final method = _optStr(j, 'method');
    return StepUpGrant(token: _str(j, 'stepUpToken'), expiresAt: expires, method: StepUpMethod.tryParse(method));
  }

  /// `AuthOtpChallengeIssued`.
  static StepUpOtpChallenge otpChallenge(Object? json) {
    final j = _map(json, 'AuthOtpChallengeIssued');
    return StepUpOtpChallenge(
      challengeId: _str(j, 'challengeId'),
      resendAfterSec: _int(j, 'resendAfterSec', 60),
      otpTtlSec: _int(j, 'otpTtlSec', 300),
    );
  }
}
