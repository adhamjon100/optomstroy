// Профиль SCR-41 (08 §4.3 `GET /me` → `Me`, `Profile`, `MeCustomerLink`; `PATCH /me/profile`; смена телефона
// `POST /me/phone/change/request|confirm` со step-up). Для `customer` — статус привязки к клиенту 1С (RM-G-014;
// свой долг и история — только при `confirmed`, 10 CUST-025). ПДн (ФИО, телефон) — только в памяти, `toString` без
// значений (NFR-LOG-001). Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/utils/money.dart';

/// Данные профиля (`Profile`).
final class ProfileData {
  const ProfileData({
    this.fullName,
    this.phoneE164,
    this.birthYear,
    this.activitySphere,
    this.avatarUrl,
    this.rowVersion,
  });

  final String? fullName;
  final String? phoneE164;
  final int? birthYear;
  final String? activitySphere;
  final String? avatarUrl;
  final int? rowVersion;

  @override
  String toString() => 'ProfileData(***)';
}

/// Статус привязки клиента (`MeCustomerLink.status`, включая `none`).
enum ProfileLinkStatus {
  none('none'),
  proposed('proposed'),
  confirmed('confirmed'),
  rejected('rejected'),
  conflict('conflict');

  const ProfileLinkStatus(this.value);

  final String value;

  static ProfileLinkStatus? tryParse(String? value) {
    for (final ProfileLinkStatus s in values) {
      if (s.value == value) return s;
    }
    return null;
  }
}

/// Привязка к клиенту 1С (`MeCustomerLink`): до `confirmed` — только маскированное имя, без `customerId`.
final class ProfileCustomerLink {
  const ProfileCustomerLink({
    required this.status,
    this.linkId,
    this.displayNameMasked,
    this.customerId,
    this.displayName,
  });

  final ProfileLinkStatus? status;
  final String? linkId;
  final String? displayNameMasked;

  /// Только при `confirmed` (иначе свой долг/история — 404).
  final String? customerId;
  final String? displayName;

  bool get isConfirmed => status == ProfileLinkStatus.confirmed && customerId != null;

  @override
  String toString() => 'ProfileCustomerLink(${status?.value})';
}

/// Защита входа (`Me.security`).
final class ProfileSecurity {
  const ProfileSecurity({this.pinSet, this.biometricsEnabled, this.biometricsPlatform});

  final bool? pinSet;
  final bool? biometricsEnabled;

  /// `android_class3|ios|windows_hello_gate|none` — строкой контракта.
  final String? biometricsPlatform;
}

/// Текущая сессия (`Me.session`).
final class ProfileSession {
  const ProfileSession({
    this.sid,
    this.deviceId,
    this.deviceName,
    this.createdAt,
    this.amr = const <String>[],
    this.expiresAt,
  });

  final String? sid;
  final String? deviceId;
  final String? deviceName;
  final DateTime? createdAt;
  final List<String> amr;
  final DateTime? expiresAt;
}

/// Пользователь SCR-41 (`Me` без настроек SCR-42 и согласий).
final class UserProfile {
  const UserProfile({
    required this.id,
    required this.kind,
    required this.status,
    required this.roles,
    required this.permissions,
    required this.permissionsVersion,
    this.discountLimitPercent,
    this.profile = const ProfileData(),
    this.customerLink,
    this.security,
    this.session,
    this.apiVersion,
    this.serverTime,
  });

  final String id;
  final UserKind? kind;
  final UserStatus? status;
  final List<RoleCode> roles;

  /// Коды прав (`PermissionCode`) — для скрытия кнопок, не защита (SRC-C-133).
  final Set<String> permissions;
  final int permissionsVersion;
  final Percent? discountLimitPercent;
  final ProfileData profile;
  final ProfileCustomerLink? customerLink;
  final ProfileSecurity? security;
  final ProfileSession? session;
  final String? apiVersion;
  final DateTime? serverTime;

  bool can(String permission) => permissions.contains(permission);

  @override
  String toString() => 'UserProfile($id)';
}

/// Изменение профиля (`MeProfilePatchRequest`): `null` — поле не меняется.
final class ProfilePatch {
  const ProfilePatch({
    required this.rowVersion,
    this.fullName,
    this.birthYear,
    this.activitySphere,
    this.clearActivitySphere = false,
  });

  final int rowVersion;

  /// ≤ 150 символов.
  final String? fullName;

  /// ≥ 1920.
  final int? birthYear;

  /// ≤ 64 символов.
  final String? activitySphere;

  /// Явно передать `activitySphere: null`.
  final bool clearActivitySphere;

  static const int fullNameMax = 150;
  static const int activitySphereMax = 64;
  static const int birthYearMin = 1920;
}

/// Код отправлен на новый номер (`AuthOtpChallengeIssued`).
final class PhoneChangeChallenge {
  const PhoneChangeChallenge({required this.challengeId, required this.resendAfterSec, required this.otpTtlSec});

  final String challengeId;
  final int resendAfterSec;
  final int otpTtlSec;
}

/// Итог смены телефона (`MePhoneChangeResult`): прочие сессии отозваны — 09.
final class PhoneChangeResult {
  const PhoneChangeResult({required this.phoneE164, required this.sessionsRevoked});

  final String phoneE164;
  final bool sessionsRevoked;

  @override
  String toString() => 'PhoneChangeResult(***, $sessionsRevoked)';
}
