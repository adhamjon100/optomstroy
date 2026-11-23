// DTO авторизации — вручную по contracts/openapi/pos-api.v1.yaml (ADR-085):
// AuthOtpRequestRequest, AuthOtpRequestResponse, OtpVerifyRequest, AuthDeviceInfo,
// AuthAuthenticated | AuthPendingActivation | AuthRegistrationRequired, AuthOtpChallengeStatus,
// AuthUnlockRequest, AuthUnlockResponse, AuthUnlockChallengeRequest, AuthUnlockChallengeResponse (W2, OpenAPI 1.4.0).
// Состав ключей сверяет test/features/auth/data/auth_dto_contract_test.dart. toString — без телефона, кода, PIN,
// токенов, подписи и challenge.
import 'package:optomstroy/core/network/models/me.dart';

/// Ошибка формы ответа (обязательное поле отсутствует или не того типа).
final class DtoFormatException implements Exception {
  const DtoFormatException(this.field);

  final String field;

  @override
  String toString() => 'DtoFormatException($field)';
}

T _req<T>(Map<String, dynamic> json, String key) {
  final Object? v = json[key];
  if (v is T) {
    return v;
  }
  throw DtoFormatException(key);
}

T? _opt<T>(Map<String, dynamic> json, String key) {
  final Object? v = json[key];
  return v is T ? v : null;
}

DateTime? _date(Map<String, dynamic> json, String key) {
  final String? v = _opt<String>(json, key);
  return v == null ? null : DateTime.tryParse(v);
}

/// `AuthOtpRequestRequest` — тело `POST /auth/otp/request`.
final class OtpRequestRequestDto {
  const OtpRequestRequestDto({required this.phone, this.locale = 'ru'});

  /// Единственное значение на этом маршруте (ядро §18.2 п.7).
  static const String purposeLoginOrRegister = 'login_or_register';

  static const Set<String> jsonKeys = <String>{'phone', 'purpose', 'locale', 'attestation'};
  static const Set<String> requiredKeys = <String>{'phone', 'purpose'};

  /// E.164 `+996XXXXXXXXX`.
  final String phone;
  final String locale;

  /// `attestation` (R2) не передаётся — контракт допускает отсутствие.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'phone': phone,
    'purpose': purposeLoginOrRegister,
    'locale': locale,
  };

  @override
  String toString() => 'OtpRequestRequestDto(***)';
}

/// `AuthOtpRequestResponse` — `202`.
final class OtpRequestResponseDto {
  const OtpRequestResponseDto({
    required this.challengeId,
    required this.resendAfterSec,
    required this.otpTtlSec,
    this.codeLength,
    this.phoneMasked,
    this.deliveryHint,
    this.devCode,
  });

  factory OtpRequestResponseDto.fromJson(Map<String, dynamic> json) => OtpRequestResponseDto(
    challengeId: _req<String>(json, 'challengeId'),
    resendAfterSec: _req<int>(json, 'resendAfterSec'),
    otpTtlSec: _req<int>(json, 'otpTtlSec'),
    codeLength: _opt<int>(json, 'codeLength'),
    phoneMasked: _opt<String>(json, 'phoneMasked'),
    deliveryHint: _opt<String>(json, 'deliveryHint'),
    devCode: _opt<String>(json, devCodeKey),
  );

  /// Поле тестового режима OTP dev/staging (09 §5.8; 02 UI-02-017). В контракте 08/OpenAPI его нет
  /// (D_spec_questions AU-03), поэтому оно не входит в [jsonKeys]; читается, только если сервер его прислал.
  static const String devCodeKey = 'devCode';

  static const Set<String> jsonKeys = <String>{
    'challengeId',
    'resendAfterSec',
    'otpTtlSec',
    'codeLength',
    'phoneMasked',
    'deliveryHint',
  };
  static const Set<String> requiredKeys = <String>{'challengeId', 'resendAfterSec', 'otpTtlSec'};

  final String challengeId;
  final int resendAfterSec;
  final int otpTtlSec;
  final int? codeLength;
  final String? phoneMasked;
  final String? deliveryHint;
  final String? devCode;

  @override
  String toString() => 'OtpRequestResponseDto($challengeId)';
}

/// `AuthDeviceInfo` (`additionalProperties: false`; поле `model` не передаётся — 02 SCR-02.9).
final class AuthDeviceInfoDto {
  const AuthDeviceInfoDto({
    required this.name,
    required this.platform,
    required this.appVersion,
    this.osVersion,
    this.biometricClass,
  });

  static const Set<String> jsonKeys = <String>{'name', 'platform', 'osVersion', 'appVersion', 'biometricClass'};
  static const Set<String> requiredKeys = <String>{'name', 'platform', 'appVersion'};

  /// `name` 1…100, `osVersion` ≤ 32, `appVersion` ≤ 32 (схема).
  final String name;

  /// `android | ios | windows`.
  final String platform;
  final String appVersion;
  final String? osVersion;

  /// `class3 | class2 | none | windows_hello`.
  final String? biometricClass;

  static String _cut(String v, int max) => v.length > max ? v.substring(0, max) : v;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': _cut(name.isEmpty ? platform : name, 100),
    'platform': platform,
    if (osVersion != null && osVersion!.isNotEmpty) 'osVersion': _cut(osVersion!, 32),
    'appVersion': _cut(appVersion, 32),
    'biometricClass': ?biometricClass,
  };

  @override
  String toString() => 'AuthDeviceInfoDto($platform)';
}

/// `OtpVerifyRequest` — тело `POST /auth/otp/verify`.
final class OtpVerifyRequestDto {
  const OtpVerifyRequestDto({required this.challengeId, required this.code, required this.device});

  static const Set<String> jsonKeys = <String>{'challengeId', 'code', 'device'};
  static const Set<String> requiredKeys = <String>{'challengeId', 'code', 'device'};

  final String challengeId;

  /// Код — не логируется.
  final String code;
  final AuthDeviceInfoDto device;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'challengeId': challengeId,
    'code': code,
    'device': device.toJson(),
  };

  @override
  String toString() => 'OtpVerifyRequestDto($challengeId, ***)';
}

/// Ответ `200 /auth/otp/verify`: `oneOf` по дискриминатору `status`.
sealed class OtpVerifyResponseDto {
  const OtpVerifyResponseDto();

  /// Разбор по `status`; неизвестный статус → [DtoFormatException].
  factory OtpVerifyResponseDto.fromJson(Map<String, dynamic> json) {
    final String status = _req<String>(json, 'status');
    return switch (status) {
      AuthAuthenticatedDto.statusValue => AuthAuthenticatedDto.fromJson(json),
      AuthPendingActivationDto.statusValue => AuthPendingActivationDto.fromJson(json),
      AuthRegistrationRequiredDto.statusValue => AuthRegistrationRequiredDto.fromJson(json),
      _ => throw const DtoFormatException('status'),
    };
  }
}

Me? _me(Map<String, dynamic> json) {
  final Object? user = json['user'];
  return user is Map<String, dynamic> ? Me.fromJson(user) : null;
}

/// `AuthAuthenticated`.
final class AuthAuthenticatedDto extends OtpVerifyResponseDto {
  const AuthAuthenticatedDto({
    required this.accessToken,
    required this.refreshToken,
    this.accessExpiresIn,
    this.refreshExpiresAt,
    this.tokenType,
    this.sid,
    this.user,
    this.biometricRefreshOffered,
    this.roleSource,
    this.nextStep,
  });

  factory AuthAuthenticatedDto.fromJson(Map<String, dynamic> json) => AuthAuthenticatedDto(
    accessToken: _req<String>(json, 'accessToken'), // check-secrets: allow (имя поля DTO / тестовое значение)
    refreshToken: _req<String>(json, 'refreshToken'), // check-secrets: allow (имя поля DTO / тестовое значение)
    accessExpiresIn: _opt<int>(json, 'accessExpiresIn'),
    refreshExpiresAt: _date(json, 'refreshExpiresAt'),
    tokenType: _opt<String>(json, 'tokenType'), // check-secrets: allow (имя поля DTO / тестовое значение)
    sid: _opt<String>(json, 'sid'),
    user: _me(json),
    biometricRefreshOffered: _opt<bool>(json, 'biometricRefreshOffered'),
    roleSource: _opt<String>(json, 'roleSource'),
    nextStep: _opt<String>(json, 'nextStep'),
  );

  static const String statusValue = 'authenticated';
  static const Set<String> jsonKeys = <String>{
    'status',
    'accessToken',
    'accessExpiresIn',
    'refreshToken',
    'refreshExpiresAt',
    'tokenType',
    'sid',
    'user',
    'biometricRefreshOffered',
    'roleSource',
    'nextStep',
  };
  static const Set<String> requiredKeys = <String>{'status', 'accessToken', 'refreshToken'};

  final String accessToken;
  final String refreshToken;
  final int? accessExpiresIn;
  final DateTime? refreshExpiresAt;
  final String? tokenType;
  final String? sid;
  final Me? user;
  final bool? biometricRefreshOffered;

  /// `invitation` — первый вход сотрудника по приглашению.
  final String? roleSource;

  /// `set_pin | none`.
  final String? nextStep;

  @override
  String toString() => 'AuthAuthenticatedDto(***)';
}

/// `AuthPendingActivation`.
final class AuthPendingActivationDto extends OtpVerifyResponseDto {
  const AuthPendingActivationDto({required this.accessToken, required this.refreshToken, this.user});

  factory AuthPendingActivationDto.fromJson(Map<String, dynamic> json) => AuthPendingActivationDto(
    accessToken: _req<String>(json, 'accessToken'), // check-secrets: allow (имя поля DTO / тестовое значение)
    refreshToken: _req<String>(json, 'refreshToken'), // check-secrets: allow (имя поля DTO / тестовое значение)
    user: _me(json),
  );

  static const String statusValue = 'pending_activation';
  static const Set<String> jsonKeys = <String>{'status', 'accessToken', 'refreshToken', 'user'};
  static const Set<String> requiredKeys = <String>{'status', 'accessToken', 'refreshToken'};

  final String accessToken;
  final String refreshToken;
  final Me? user;

  @override
  String toString() => 'AuthPendingActivationDto(***)';
}

/// `AuthRegistrationRequired`.
final class AuthRegistrationRequiredDto extends OtpVerifyResponseDto {
  const AuthRegistrationRequiredDto({required this.registrationToken, this.registrationExpiresIn, this.phoneMasked});

  factory AuthRegistrationRequiredDto.fromJson(Map<String, dynamic> json) => AuthRegistrationRequiredDto(
    registrationToken: _req<String>(json, _registrationTokenKey), // check-secrets: allow (поле DTO)
    registrationExpiresIn: _opt<int>(json, 'registrationExpiresIn'),
    phoneMasked: _opt<String>(json, 'phoneMasked'),
  );

  static const String statusValue = 'registration_required';
  static const String _registrationTokenKey = 'registrationToken'; // check-secrets: allow (имя поля DTO)
  static const Set<String> jsonKeys = <String>{'status', 'registrationToken', 'registrationExpiresIn', 'phoneMasked'};
  static const Set<String> requiredKeys = <String>{'status', 'registrationToken'};

  /// TTL регистрации по умолчанию (900 с, 08 §4.1.2), если сервер не прислал.
  static const int defaultExpiresIn = 900;

  final String registrationToken;
  final int? registrationExpiresIn;
  final String? phoneMasked;

  @override
  String toString() => 'AuthRegistrationRequiredDto(***)';
}

/// `AuthOtpChallengeStatus`.
final class OtpChallengeStatusDto {
  const OtpChallengeStatusDto({
    required this.challengeId,
    required this.delivery,
    this.resendAfterSec,
    this.expiresAt,
    this.channel,
  });

  factory OtpChallengeStatusDto.fromJson(Map<String, dynamic> json) => OtpChallengeStatusDto(
    challengeId: _req<String>(json, 'challengeId'),
    delivery: _req<String>(json, 'delivery'),
    resendAfterSec: _opt<int>(json, 'resendAfterSec'),
    expiresAt: _date(json, 'expiresAt'),
    channel: _opt<String>(json, 'channel'),
  );

  static const Set<String> jsonKeys = <String>{'challengeId', 'delivery', 'resendAfterSec', 'expiresAt', 'channel'};
  static const Set<String> requiredKeys = <String>{'challengeId', 'delivery'};

  final String challengeId;

  /// `queued | sent | failed`.
  final String delivery;
  final int? resendAfterSec;
  final DateTime? expiresAt;
  final String? channel;

  @override
  String toString() => 'OtpChallengeStatusDto($challengeId, $delivery)';
}

/// `AuthUnlockRequest` — тело `POST /auth/unlock` (08 §4.1.8; OpenAPI 1.4.0 — метод `hello_key`, 15 ADR-116).
final class AuthUnlockRequestDto {
  const AuthUnlockRequestDto({
    required this.method,
    required this.refreshToken,
    this.pin,
    this.biometricInvalidated,
    this.signature,
    this.helloKeyInvalidated,
  });

  static const String methodPin = 'pin';
  static const String methodBiometric = 'biometric';

  /// Вход по ключу Windows Hello без PIN приложения (W2; 09 BIO-039): `refreshToken` + [signature] над challenge
  /// `POST /auth/unlock/challenge` ([AuthUnlockChallengeResponseDto]).
  static const String methodHelloKey = 'hello_key';

  /// `AuthUnlockRequest.method` (enum контракта).
  static const Set<String> methods = <String>{methodPin, methodBiometric, methodHelloKey};

  static const Set<String> jsonKeys = <String>{
    'method',
    'refreshToken',
    'pin',
    'biometricInvalidated',
    'signature',
    'helloKeyInvalidated',
  };
  static const Set<String> requiredKeys = <String>{'refreshToken'};

  /// [methods]: `pin | biometric | hello_key`.
  final String method;

  /// Refresh (или расшифрованный biometric refresh) — не логируется.
  final String refreshToken;

  /// PIN — не логируется, не хранится.
  final String? pin;
  final bool? biometricInvalidated;

  /// Только с [methodHelloKey]: RSASSA-PKCS1-v1_5 / SHA-256 над UTF-8 строки challenge, base64url без `=`
  /// (342…683 знака; 08 §4.1.8). Не логируется.
  final String? signature;

  /// Только с [methodPin]: ключ Windows Hello пропал на устройстве — после верного PIN сервер отзывает ключ
  /// (`invalidated`; 09 BIO-039, BIO-040; 02 `unlock_hello_key_lost`).
  final bool? helloKeyInvalidated;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'method': method,
    'refreshToken': refreshToken,
    'pin': ?pin,
    'biometricInvalidated': ?biometricInvalidated,
    'signature': ?signature,
    'helloKeyInvalidated': ?helloKeyInvalidated,
  };

  @override
  String toString() => 'AuthUnlockRequestDto($method, ***)';
}

/// `AuthUnlockChallengeRequest` — тело `POST /auth/unlock/challenge` (W2; 08 §4.1.10; 09 BIO-039). Публичный путь:
/// сервер принимает только текущий refresh живой `standard`-сессии этого `X-Device-Id`; refresh не ротируется,
/// любой отказ — `401 UNLOCK_REQUIRED {reason: hello_key_unavailable}`.
final class AuthUnlockChallengeRequestDto {
  const AuthUnlockChallengeRequestDto({required this.refreshToken});

  static const Set<String> jsonKeys = <String>{'method', 'refreshToken'};
  static const Set<String> requiredKeys = <String>{'method', 'refreshToken'};

  /// Refresh сессии — не логируется.
  final String refreshToken;

  /// `method` — единственное значение контракта `hello_key`.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'method': AuthUnlockRequestDto.methodHelloKey,
    'refreshToken': refreshToken,
  };

  @override
  String toString() => 'AuthUnlockChallengeRequestDto(***)';
}

/// `AuthUnlockChallengeResponse` — `200 POST /auth/unlock/challenge`: строка для подписи ключом Windows Hello и срок
/// (120 с, один challenge на ключ; 08 §4.1.10).
final class AuthUnlockChallengeResponseDto {
  const AuthUnlockChallengeResponseDto({required this.challenge, required this.expiresAt});

  /// Разбор ответа. Строка вне [challengePattern] → [DtoFormatException]: ключ подписывает только challenge входа
  /// (`optomstroy-hello-unlock/v1:` + 32 байта base64url), а не произвольную строку из ответа.
  factory AuthUnlockChallengeResponseDto.fromJson(Map<String, dynamic> json) {
    final String challenge = _req<String>(json, 'challenge');
    if (!challengePattern.hasMatch(challenge)) throw const DtoFormatException('challenge');
    final DateTime? expiresAt = _date(json, 'expiresAt');
    if (expiresAt == null) throw const DtoFormatException('expiresAt');
    return AuthUnlockChallengeResponseDto(challenge: challenge, expiresAt: expiresAt);
  }

  /// `AuthUnlockChallengeResponse.challenge.pattern` (OpenAPI 1.4.0).
  static final RegExp challengePattern = RegExp(r'^optomstroy-hello-unlock/v1:[A-Za-z0-9_-]{43}$');

  static const Set<String> jsonKeys = <String>{'challenge', 'expiresAt'};
  static const Set<String> requiredKeys = <String>{'challenge', 'expiresAt'};

  /// Подписывается как есть (UTF-8), не логируется.
  final String challenge;
  final DateTime expiresAt;

  @override
  String toString() => 'AuthUnlockChallengeResponseDto(***)';
}

/// `AuthUnlockResponse`.
final class AuthUnlockResponseDto {
  const AuthUnlockResponseDto({
    required this.accessToken,
    required this.accessExpiresIn,
    required this.refreshToken,
    required this.refreshExpiresAt,
    required this.sid,
    this.amr,
    this.permissionsVersion,
  });

  factory AuthUnlockResponseDto.fromJson(Map<String, dynamic> json) => AuthUnlockResponseDto(
    accessToken: _req<String>(json, 'accessToken'), // check-secrets: allow (имя поля DTO / тестовое значение)
    accessExpiresIn: _req<int>(json, 'accessExpiresIn'),
    refreshToken: _req<String>(json, 'refreshToken'), // check-secrets: allow (имя поля DTO / тестовое значение)
    refreshExpiresAt: DateTime.parse(_req<String>(json, 'refreshExpiresAt')),
    sid: _req<String>(json, 'sid'),
    amr: _opt<List<dynamic>>(json, 'amr')?.whereType<String>().toList(),
    permissionsVersion: _opt<int>(json, 'permissionsVersion'),
  );

  static const Set<String> jsonKeys = <String>{
    'accessToken',
    'accessExpiresIn',
    'refreshToken',
    'refreshExpiresAt',
    'sid',
    'amr',
    'permissionsVersion',
  };
  static const Set<String> requiredKeys = <String>{
    'accessToken',
    'accessExpiresIn',
    'refreshToken',
    'refreshExpiresAt',
    'sid',
  };

  final String accessToken;
  final int accessExpiresIn;
  final String refreshToken;
  final DateTime refreshExpiresAt;
  final String sid;
  final List<String>? amr;
  final int? permissionsVersion;

  @override
  String toString() => 'AuthUnlockResponseDto(***)';
}
