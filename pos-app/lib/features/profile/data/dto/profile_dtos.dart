// DTO-кодеки профиля (contracts/openapi/pos-api.v1.yaml 1.2.0; ADR-085 — вручную): `Me` (поля SCR-41), `Profile`,
// `MeCustomerLink`, `MeProfilePatchRequest`, `MePhoneChangeRequest`, `MePhoneChangeConfirmRequest`,
// `MePhoneChangeResult`, `AuthOtpChallengeIssued`. Сверка ключей — test/features/profile/data/profile_dtos_contract_test.dart.
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/features/profile/domain/entities/user_profile.dart';

/// `Profile`.
abstract final class ProfileDataDto {
  static const Set<String> jsonKeys = {'fullName', 'phone', 'birthYear', 'activitySphere', 'avatarUrl', 'rowVersion'};
  static const Set<String> requiredKeys = <String>{};

  static ProfileData fromJson(JsonMap j) => ProfileData(
    fullName: jOpt<String>(j, 'fullName'),
    phoneE164: jOpt<String>(j, 'phone'),
    birthYear: jInt(j, 'birthYear'),
    activitySphere: jOpt<String>(j, 'activitySphere'),
    avatarUrl: jOpt<String>(j, 'avatarUrl'),
    rowVersion: jInt(j, 'rowVersion'),
  );
}

/// `MeCustomerLink`.
abstract final class ProfileCustomerLinkDto {
  static const Set<String> jsonKeys = {'linkId', 'status', 'displayNameMasked', 'customerId', 'displayName'};
  static const Set<String> requiredKeys = {'status'};

  static ProfileCustomerLink fromJson(JsonMap j) => ProfileCustomerLink(
    status: ProfileLinkStatus.tryParse(jReq<String>(j, 'status')),
    linkId: jOpt<String>(j, 'linkId'),
    displayNameMasked: jOpt<String>(j, 'displayNameMasked'),
    customerId: jOpt<String>(j, 'customerId'),
    displayName: jOpt<String>(j, 'displayName'),
  );
}

/// `Me` — поля SCR-41; `settings` (SCR-42), `consents`, `appVersion` переносит фича settings / core.
abstract final class UserProfileDto {
  static const Set<String> jsonKeys = {
    'id',
    'kind',
    'status',
    'roles',
    'permissions',
    'permissionsVersion',
    'discountLimitPercent',
    'profile',
    'customerLink',
    'security',
    'session',
    'apiVersion',
    'serverTime',
  };
  static const Set<String> ignoredKeys = {'settings', 'consents', 'appVersion'};
  static const Set<String> requiredKeys = {'id', 'kind', 'status', 'roles', 'permissions', 'permissionsVersion'};

  static UserProfile fromJson(JsonMap j) {
    final JsonMap? profile = jObject(j, 'profile');
    final JsonMap? link = jObject(j, 'customerLink');
    final JsonMap? security = jObject(j, 'security');
    final JsonMap? session = jObject(j, 'session');
    return UserProfile(
      id: jReq<String>(j, 'id'),
      kind: UserKind.tryParse(jReq<String>(j, 'kind')),
      status: UserStatus.tryParse(jReq<String>(j, 'status')),
      roles: <RoleCode>[for (final String r in jStrings(j, 'roles', required: true)) ?RoleCode.tryParse(r)],
      permissions: jStrings(j, 'permissions', required: true).toSet(),
      permissionsVersion: jReqInt(j, 'permissionsVersion'),
      discountLimitPercent: jPercent(j, 'discountLimitPercent'),
      profile: profile == null ? const ProfileData() : ProfileDataDto.fromJson(profile),
      customerLink: link == null ? null : ProfileCustomerLinkDto.fromJson(link),
      security: security == null
          ? null
          : ProfileSecurity(
              pinSet: jBool(security, 'pinSet'),
              biometricsEnabled: jBool(security, 'biometricsEnabled'),
              biometricsPlatform: jOpt<String>(security, 'biometricsPlatform'),
            ),
      session: session == null
          ? null
          : ProfileSession(
              sid: jOpt<String>(session, 'sid'),
              deviceId: jOpt<String>(session, 'deviceId'),
              deviceName: jOpt<String>(session, 'deviceName'),
              createdAt: jDate(session, 'createdAt'),
              amr: jStrings(session, 'amr'),
              expiresAt: jDate(session, 'expiresAt'),
            ),
      apiVersion: jOpt<String>(j, 'apiVersion'),
      serverTime: jDate(j, 'serverTime'),
    );
  }
}

/// `MeProfilePatchRequest`.
abstract final class ProfilePatchDto {
  static const Set<String> jsonKeys = {'fullName', 'birthYear', 'activitySphere', 'rowVersion'};
  static const Set<String> requiredKeys = {'rowVersion'};

  static JsonMap toJson(ProfilePatch p) => <String, dynamic>{
    'fullName': ?p.fullName,
    'birthYear': ?p.birthYear,
    if (p.activitySphere != null)
      'activitySphere': p.activitySphere
    else if (p.clearActivitySphere)
      'activitySphere': null,
    'rowVersion': p.rowVersion,
  };
}

/// `MePhoneChangeRequest`.
abstract final class PhoneChangeRequestDto {
  static const Set<String> jsonKeys = {'newPhone'};
  static const Set<String> requiredKeys = {'newPhone'};

  static JsonMap toJson(String newPhoneE164) => <String, dynamic>{'newPhone': newPhoneE164};
}

/// `MePhoneChangeConfirmRequest`.
abstract final class PhoneChangeConfirmDto {
  static const Set<String> jsonKeys = {'challengeId', 'code'};
  static const Set<String> requiredKeys = {'challengeId', 'code'};

  static JsonMap toJson({required String challengeId, required String code}) => <String, dynamic>{
    'challengeId': challengeId,
    'code': code,
  };
}

/// `AuthOtpChallengeIssued`.
abstract final class PhoneChangeChallengeDto {
  static const Set<String> jsonKeys = {'challengeId', 'resendAfterSec', 'otpTtlSec'};
  static const Set<String> requiredKeys = jsonKeys;

  static PhoneChangeChallenge fromJson(JsonMap j) => PhoneChangeChallenge(
    challengeId: jReq<String>(j, 'challengeId'),
    resendAfterSec: jReqInt(j, 'resendAfterSec'),
    otpTtlSec: jReqInt(j, 'otpTtlSec'),
  );
}

/// `MePhoneChangeResult`.
abstract final class PhoneChangeResultDto {
  static const Set<String> jsonKeys = {'phone', 'sessionsRevoked'};
  static const Set<String> requiredKeys = jsonKeys;

  static PhoneChangeResult fromJson(JsonMap j) =>
      PhoneChangeResult(phoneE164: jReq<String>(j, 'phone'), sessionsRevoked: jReq<bool>(j, 'sessionsRevoked'));
}
