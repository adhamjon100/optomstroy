// ADR-085: ручные DTO авторизации сверяются с contracts/openapi/pos-api.v1.yaml —
// набор ключей DTO == properties схемы, required-поля DTO == required схемы
// (как test/core/network/models/dto_schema_test.dart; YAML читает Python + PyYAML).
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/network/models/me.dart';
import 'package:optomstroy/core/network/models/problem.dart';
import 'package:optomstroy/features/auth/data/dto/auth_dtos.dart';
import 'package:optomstroy/features/auth/domain/entities/unlock.dart';

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
    // OpenAPI 1.4.0, W2 (вход по ключу Windows Hello без PIN; 08 §4.1.10, 15 ADR-116).
    matches(
      'AuthUnlockChallengeRequest',
      AuthUnlockChallengeRequestDto.jsonKeys,
      AuthUnlockChallengeRequestDto.requiredKeys,
    );
    matches(
      'AuthUnlockChallengeResponse',
      AuthUnlockChallengeResponseDto.jsonKeys,
      AuthUnlockChallengeResponseDto.requiredKeys,
    );
  }, skip: skip);

  group('T-BIO-025 (5): контракт приложения входа по лицу == OpenAPI 1.4.0 (15 ADR-116)', () {
    Map<String, Object?> props(String name, [List<String> path = const <String>[]]) {
      Map<String, Object?> node = schemas![name]! as Map<String, Object?>;
      for (final String p in path) {
        node = (node['properties']! as Map<String, Object?>)[p]! as Map<String, Object?>;
      }
      return node['properties']! as Map<String, Object?>;
    }

    Set<String> enumOf(Map<String, Object?> property) => (property['enum']! as List<Object?>).cast<String>().toSet();

    test('Me.security: biometricWeakAllowed и windowsHelloKeyAllowed — ключи схемы и разбор', () {
      final Set<String> keys = props('Me', <String>['security']).keys.toSet();
      expect(const MeSecurity().toJson().keys.toSet(), keys, reason: 'Me.security: ключи DTO ≠ properties');
      expect(keys, containsAll(<String>['biometricWeakAllowed', 'windowsHelloKeyAllowed']));
      final MeSecurity s = MeSecurity.fromJson(<String, dynamic>{
        'pinSet': true,
        'biometricsEnabled': true,
        'biometricsPlatform': 'android_class2',
        'biometricWeakAllowed': true,
        'windowsHelloKeyAllowed': false,
      });
      expect((s.biometricsPlatform, s.biometricWeakAllowed, s.windowsHelloKeyAllowed), ('android_class2', true, false));
      expect(
        enumOf(props('Me', <String>['security'])['biometricsPlatform']! as Map<String, Object?>),
        containsAll(<String>['android_class2', 'windows_hello_key']),
      );
      // Сервер прежней версии полей не присылает — «не разрешено» (null), разбор не ломается (08 §2.11).
      final MeSecurity old = MeSecurity.fromJson(<String, dynamic>{'pinSet': false, 'futureFlag': true});
      expect((old.biometricWeakAllowed, old.windowsHelloKeyAllowed), (null, null));
    }, skip: skip);

    test('причины UNLOCK_REQUIRED клиента == x-unlock-required-reasons', () {
      final Map<String, Object?> reason = props('Problem')['reason']! as Map<String, Object?>;
      final Set<String> contract = (reason['x-unlock-required-reasons']! as List<Object?>).cast<String>().toSet();
      final Set<String> client = <String>{
        for (final UnlockRequiredReason r in UnlockRequiredReason.values)
          if (r != UnlockRequiredReason.unknown) r.value,
      };
      expect(client, contract, reason: 'новая причина контракта без значения клиента (или наоборот)');
      expect(contract, containsAll(<String>['bio_weak_pin_due', 'bio_weak_disabled', 'hello_key_unavailable']));
      for (final UnlockRequiredReason r in UnlockRequiredReason.values) {
        if (r == UnlockRequiredReason.unknown) continue;
        expect(UnlockRequiredReason.parse(r.value), r);
      }
    }, skip: skip);

    // Причины входа по лицу приходят только в ответах POST /auth/unlock и POST /auth/unlock/challenge (08 §2.4,
    // §4.1.8, §4.1.10) — через ErrorMapper в AuthFailure.unlockReason, откуда их читает use case SCR-08 (09 §9.3).
    test('401 UNLOCK_REQUIRED /auth/unlock: причина входа по лицу → AuthFailure.unlockReason → перечень', () {
      AuthFailure map(String path, String reason) {
        final RequestOptions options = RequestOptions(path: path, method: 'POST');
        return ErrorMapper.fromDio(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: Response<Object?>(
                  requestOptions: options,
                  statusCode: 401,
                  data: <String, Object?>{
                    'type': 'https://api.optomstroy.kg/problems/unlock-required',
                    'title': 'Нужна разблокировка',
                    'status': 401,
                    'code': 'UNLOCK_REQUIRED',
                    'requestId': 'req-1',
                    'reason': reason,
                  },
                ),
              ),
            )
            as AuthFailure;
      }

      for (final (String path, UnlockRequiredReason expected) in <(String, UnlockRequiredReason)>[
        ('/auth/unlock', UnlockRequiredReason.bioWeakPinDue),
        ('/auth/unlock', UnlockRequiredReason.bioWeakDisabled),
        ('/auth/unlock', UnlockRequiredReason.helloKeyUnavailable),
        ('/auth/unlock', UnlockRequiredReason.helloKeyInvalid),
        ('/auth/unlock/challenge', UnlockRequiredReason.helloKeyUnavailable),
      ]) {
        final AuthFailure f = map(path, expected.value);
        expect((f.reason, f.unlockReason), (AuthReason.unlockRequired, expected.value), reason: '$path $expected');
        expect(UnlockRequiredReason.parse(f.unlockReason), expected);
      }
    });

    test('AuthUnlockRequest.method: pin | biometric | hello_key', () {
      final Set<String> contract = enumOf(props('AuthUnlockRequest')['method']! as Map<String, Object?>);
      expect(AuthUnlockRequestDto.methods, contract);
      // Зеркала строк контракта в domain (слой domain не видит core/network): метод тела и причины пути W2.
      expect(<String>{for (final UnlockMethod m in UnlockMethod.values) m.value}, contract);
      expect(
        (HelloKeyRefusal.unavailable, HelloKeyRefusal.invalid),
        (UnlockRequiredReason.helloKeyUnavailable.value, UnlockRequiredReason.helloKeyInvalid.value),
      );
      // Причины уровня W (LF-2-05; 09 BIO-031, BIO-032): use case SCR-08 сравнивает с этими строками.
      expect(
        (BiometricWeakRefusal.pinDue, BiometricWeakRefusal.disabled),
        (UnlockRequiredReason.bioWeakPinDue.value, UnlockRequiredReason.bioWeakDisabled.value),
      );
      expect(enumOf(props('AuthUnlockChallengeRequest')['method']! as Map<String, Object?>), <String>{
        AuthUnlockRequestDto.methodHelloKey,
      });
    }, skip: skip);

    test('AuthUnlockChallengeResponse.challenge: шаблон клиента == шаблон схемы', () {
      final Map<String, Object?> challenge = props('AuthUnlockChallengeResponse')['challenge']! as Map<String, Object?>;
      expect(AuthUnlockChallengeResponseDto.challengePattern.pattern, challenge['pattern']);
    }, skip: skip);
  });

  group('W2: тела и ответы разблокировки по ключу Windows Hello (08 §4.1.8, §4.1.10)', () {
    final String signature = 'A' * 342;
    final String challenge = 'optomstroy-hello-unlock/v1:${'b' * 43}';

    test('POST /auth/unlock/challenge и POST /auth/unlock {method: hello_key}', () {
      const AuthUnlockChallengeRequestDto ask = AuthUnlockChallengeRequestDto(refreshToken: 'r');
      expect(ask.toJson(), <String, Object?>{'method': 'hello_key', 'refreshToken': 'r'});
      final AuthUnlockRequestDto unlock = AuthUnlockRequestDto(
        method: AuthUnlockRequestDto.methodHelloKey,
        refreshToken: 'r',
        signature: signature,
      );
      expect(unlock.toJson(), <String, Object?>{'method': 'hello_key', 'refreshToken': 'r', 'signature': signature});
      expect(AuthUnlockRequestDto.jsonKeys.containsAll(unlock.toJson().keys), isTrue);
      // Ключ пропал на устройстве — PIN с helloKeyInvalidated (09 BIO-039; 02 unlock_hello_key_lost).
      const AuthUnlockRequestDto lost = AuthUnlockRequestDto(
        method: AuthUnlockRequestDto.methodPin,
        refreshToken: 'r',
        pin: '482913',
        helloKeyInvalidated: true,
      );
      expect(lost.toJson().keys.toSet(), <String>{'method', 'refreshToken', 'pin', 'helloKeyInvalidated'});
      expect(lost.toJson()['helloKeyInvalidated'], isTrue);
    });

    test('ответ challenge: строка входа и срок; чужая строка не подписывается', () {
      final AuthUnlockChallengeResponseDto ok = AuthUnlockChallengeResponseDto.fromJson(<String, dynamic>{
        'challenge': challenge,
        'expiresAt': '2026-11-08T09:02:00Z',
      });
      expect((ok.challenge, ok.expiresAt), (challenge, DateTime.utc(2026, 11, 8, 9, 2)));
      for (final Map<String, dynamic> bad in <Map<String, dynamic>>[
        <String, dynamic>{'challenge': 'любые данные для подписи', 'expiresAt': '2026-11-08T09:02:00Z'},
        <String, dynamic>{'challenge': 'optomstroy-hello-unlock/v2:${'b' * 43}', 'expiresAt': '2026-11-08T09:02:00Z'},
        <String, dynamic>{'challenge': '$challenge\n', 'expiresAt': '2026-11-08T09:02:00Z'},
        <String, dynamic>{'challenge': challenge},
        <String, dynamic>{'challenge': challenge, 'expiresAt': 'не дата'},
        <String, dynamic>{'expiresAt': '2026-11-08T09:02:00Z'},
      ]) {
        expect(() => AuthUnlockChallengeResponseDto.fromJson(bad), throwsA(isA<DtoFormatException>()), reason: '$bad');
      }
    });

    test('toString без refresh, подписи и challenge (NFR-LOG-001)', () {
      final List<Object> dtos = <Object>[
        AuthUnlockRequestDto(
          method: AuthUnlockRequestDto.methodHelloKey,
          refreshToken: 'secret-r', // check-secrets: allow (имя поля / тестовое значение)
          signature: signature,
        ),
        const AuthUnlockChallengeRequestDto(refreshToken: 'secret-r'), // check-secrets: allow (тестовое значение)
        AuthUnlockChallengeResponseDto(challenge: challenge, expiresAt: DateTime.utc(2026, 11, 8)),
      ];
      for (final Object d in dtos) {
        final String s = d.toString();
        expect(s, isNot(contains('secret')));
        expect(s, isNot(contains(signature.substring(0, 16))));
        expect(s, isNot(contains('optomstroy-hello-unlock')));
      }
    });
  });

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
    expect(AuthUnlockRequestDto.jsonKeys.containsAll(unlock.toJson().keys), isTrue);
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
