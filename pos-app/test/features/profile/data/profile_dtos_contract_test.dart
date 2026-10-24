// Этап G (основа), ADR-085: DTO профиля SCR-41 (`Me`, `Profile`, `MeCustomerLink`, смена телефона) ==
// contracts/openapi/pos-api.v1.yaml 1.2.0.
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/features/profile/data/dto/profile_dtos.dart';
import 'package:optomstroy/features/profile/domain/entities/user_profile.dart';

import '../../../support/openapi_schemas.dart';

const List<String> _schemas = <String>[
  'Me',
  'Profile',
  'MeCustomerLink',
  'MeProfilePatchRequest',
  'MePhoneChangeRequest',
  'MePhoneChangeConfirmRequest',
  'MePhoneChangeResult',
  'AuthOtpChallengeIssued',
];

void main() {
  final OpenApiSchemas? api = OpenApiSchemas.load(_schemas);
  final String? skip = api == null ? 'нет python с PyYAML — сверка DTO невозможна' : null;

  void matches(String name, Set<String> keys, Set<String> required, {Set<String> ignored = const <String>{}}) {
    expect(<String>{...keys, ...ignored}, api!.props(name), reason: '$name: ключи DTO ≠ properties');
    expect(required, api.required(name), reason: '$name: required DTO ≠ required схемы');
  }

  test('ключи и обязательные поля == схемы OpenAPI 1.2.0', () {
    matches('Me', UserProfileDto.jsonKeys, UserProfileDto.requiredKeys, ignored: UserProfileDto.ignoredKeys);
    matches('Profile', ProfileDataDto.jsonKeys, ProfileDataDto.requiredKeys);
    matches('MeCustomerLink', ProfileCustomerLinkDto.jsonKeys, ProfileCustomerLinkDto.requiredKeys);
    matches('MeProfilePatchRequest', ProfilePatchDto.jsonKeys, ProfilePatchDto.requiredKeys);
    matches('MePhoneChangeRequest', PhoneChangeRequestDto.jsonKeys, PhoneChangeRequestDto.requiredKeys);
    matches('MePhoneChangeConfirmRequest', PhoneChangeConfirmDto.jsonKeys, PhoneChangeConfirmDto.requiredKeys);
    matches('MePhoneChangeResult', PhoneChangeResultDto.jsonKeys, PhoneChangeResultDto.requiredKeys);
    matches('AuthOtpChallengeIssued', PhoneChangeChallengeDto.jsonKeys, PhoneChangeChallengeDto.requiredKeys);
  }, skip: skip);

  test('пример Me: роли, права, привязка; ПДн не попадают в toString', () {
    final UserProfile me = UserProfileDto.fromJson(jsonCopy(api!.example('Me')));
    expect(me.kind, UserKind.staff);
    expect(me.roles, isNotEmpty);
    expect(me.permissions, isNotEmpty);
    expect(me.customerLink!.status, ProfileLinkStatus.none);
    expect(me.customerLink!.isConfirmed, isFalse);
    expect(me.profile.toString(), isNot(contains(me.profile.fullName ?? '@@')));
  }, skip: skip);

  test('тело PATCH /me/profile: только изменённые поля + rowVersion', () {
    expect(ProfilePatchDto.toJson(const ProfilePatch(rowVersion: 2, fullName: 'Асанов Бек')), <String, dynamic>{
      'fullName': 'Асанов Бек',
      'rowVersion': 2,
    });
    expect(ProfilePatchDto.toJson(const ProfilePatch(rowVersion: 2, clearActivitySphere: true)), <String, dynamic>{
      'activitySphere': null,
      'rowVersion': 2,
    });
  });
}
