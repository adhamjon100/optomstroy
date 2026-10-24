// ADR-085: ручные DTO авторизации сверяются с contracts/openapi/pos-api.v1.yaml —
// набор ключей DTO == properties схемы, required-поля DTO == required схемы
// (как test/core/network/models/dto_schema_test.dart; YAML читает Python + PyYAML).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/features/auth/data/dto/auth_dtos.dart';

const String _script = r'''
import json, sys, yaml
spec = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
json.dump(spec["components"]["schemas"], sys.stdout, ensure_ascii=False, default=str)
''';

Map<String, Object?>? _loadSchemas() {
  for (final String python in <String>['python', 'python3', 'py']) {
    try {
      final ProcessResult r = Process.runSync(python, <String>[
        '-I',
        '-X',
        'utf8',
        '-c',
        _script,
        '../contracts/openapi/pos-api.v1.yaml',
      ], stdoutEncoding: utf8);
      if (r.exitCode == 0) {
        return jsonDecode(r.stdout as String) as Map<String, Object?>;
      }
    } on ProcessException {
      continue;
    }
  }
  return null;
}

void main() {
  final Map<String, Object?>? schemas = _loadSchemas();
  final String? skip = schemas == null ? 'нет python с PyYAML — сверка DTO невозможна' : null;

  void matches(String name, Set<String> keys, Set<String> required) {
    final Map<String, Object?> s = schemas![name]! as Map<String, Object?>;
    expect(keys, (s['properties']! as Map<String, Object?>).keys.toSet(), reason: '$name: ключи DTO ≠ properties');
    expect(required, ((s['required'] as List<Object?>?) ?? const <Object?>[]).cast<String>().toSet(), reason: name);
  }

  test('T-AUTH-039, T-AUTH-037: DTO авторизации == схемы OpenAPI', () {
    matches('AuthOtpRequestRequest', OtpRequestRequestDto.jsonKeys, OtpRequestRequestDto.requiredKeys);
    matches('AuthOtpRequestResponse', OtpRequestResponseDto.jsonKeys, OtpRequestResponseDto.requiredKeys);
    matches('AuthDeviceInfo', AuthDeviceInfoDto.jsonKeys, AuthDeviceInfoDto.requiredKeys);
    matches('OtpVerifyRequest', OtpVerifyRequestDto.jsonKeys, OtpVerifyRequestDto.requiredKeys);
    matches('AuthAuthenticated', AuthAuthenticatedDto.jsonKeys, AuthAuthenticatedDto.requiredKeys);
    matches('AuthPendingActivation', AuthPendingActivationDto.jsonKeys, AuthPendingActivationDto.requiredKeys);
    matches('AuthRegistrationRequired', AuthRegistrationRequiredDto.jsonKeys, AuthRegistrationRequiredDto.requiredKeys);
    matches('AuthOtpChallengeStatus', OtpChallengeStatusDto.jsonKeys, OtpChallengeStatusDto.requiredKeys);
    matches('AuthUnlockRequest', AuthUnlockRequestDto.jsonKeys, AuthUnlockRequestDto.requiredKeys);
    matches('AuthUnlockResponse', AuthUnlockResponseDto.jsonKeys, AuthUnlockResponseDto.requiredKeys);
  }, skip: skip);

  test('тела запросов — подмножество ключей схемы (additionalProperties: false)', () {
    const AuthDeviceInfoDto device = AuthDeviceInfoDto(
      name: 'Samsung SM-A525F',
      platform: 'android',
      appVersion: '1.4.2+87',
      osVersion: '14',
      biometricClass: 'class3',
    );
    expect(AuthDeviceInfoDto.jsonKeys.containsAll(device.toJson().keys), isTrue);
    const OtpVerifyRequestDto verify = OtpVerifyRequestDto(challengeId: 'c', code: '004512', device: device);
    expect(OtpVerifyRequestDto.jsonKeys.containsAll(verify.toJson().keys), isTrue);
    expect(verify.toJson()['code'], '004512');
    const OtpRequestRequestDto req = OtpRequestRequestDto(phone: '+996700123456');
    expect(req.toJson(), <String, Object?>{'phone': '+996700123456', 'purpose': 'login_or_register', 'locale': 'ru'});
    const AuthUnlockRequestDto unlock = AuthUnlockRequestDto(method: 'pin', refreshToken: 'r', pin: '482913');
    expect(unlock.toJson().keys.toSet(), <String>{'method', 'refreshToken', 'pin'});
  });

  test('ответ verify: ветвление по status (oneOf + discriminator)', () {
    expect(
      OtpVerifyResponseDto.fromJson(<String, dynamic>{
        'status': 'authenticated',
        'accessToken': 'a',
        'refreshToken': 'r',
        'roleSource': 'invitation',
        'nextStep': 'set_pin',
      }),
      isA<AuthAuthenticatedDto>().having((AuthAuthenticatedDto d) => d.nextStep, 'nextStep', 'set_pin'),
    );
    expect(
      OtpVerifyResponseDto.fromJson(<String, dynamic>{'status': 'registration_required', 'registrationToken': 't'}),
      isA<AuthRegistrationRequiredDto>(),
    );
    expect(
      OtpVerifyResponseDto.fromJson(<String, dynamic>{
        'status': 'pending_activation',
        'accessToken': 'a',
        'refreshToken': 'r',
      }),
      isA<AuthPendingActivationDto>(),
    );
    expect(() => OtpVerifyResponseDto.fromJson(<String, dynamic>{'status': 'x'}), throwsA(isA<DtoFormatException>()));
  });

  test('toString DTO без кода, PIN, телефона и токенов (NFR-LOG-001)', () {
    const AuthDeviceInfoDto device = AuthDeviceInfoDto(name: 'n', platform: 'android', appVersion: '1');
    final List<Object> dtos = <Object>[
      const OtpRequestRequestDto(phone: '+996700123456'),
      const OtpVerifyRequestDto(challengeId: 'c', code: '004512', device: device),
      const AuthUnlockRequestDto(
        method: 'pin',
        refreshToken: 'secret-refresh', // check-secrets: allow (имя поля / тестовое значение)
        pin: '482913',
      ), // check-secrets: allow (имя поля DTO / тестовое значение)
      const AuthAuthenticatedDto(
        accessToken: 'secret-access', // check-secrets: allow (имя поля / тестовое значение)
        refreshToken: 'secret-refresh', // check-secrets: allow (имя поля / тестовое значение)
      ), // check-secrets: allow (имя поля DTO / тестовое значение)
    ];
    for (final Object d in dtos) {
      final String s = d.toString();
      expect(s, isNot(contains('700123456')));
      expect(s, isNot(contains('004512')));
      expect(s, isNot(contains('482913')));
      expect(s, isNot(contains('secret')));
    }
  });
}
