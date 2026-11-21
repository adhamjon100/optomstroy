// DTO `POST /me/biometrics` (08 §4.3.6; OpenAPI MeBiometricsRequest, MeBiometricsHelloKey, MeBiometricsConsent,
// MeBiometricsResponse; 1.4.0 — уровень W `class2` и ключ Windows Hello W2, 15 ADR-116). Вручную (ADR-085): состав
// ключей и значения перечней сверяет test/core/network/models/dto_schema_test.dart. Общие для SCR-04 (registration)
// и SCR-42 (settings), поэтому в core. toString — без токена и открытого ключа (NFR-LOG-001).
import 'package:optomstroy/core/enums.dart';

/// `MeBiometricsRequest` (`additionalProperties: false`): включение (`enabled:true` + класс + согласие, для W2 —
/// [MeBiometricsHelloKeyDto]) или выключение (`enabled:false`).
abstract final class MeBiometricsRequestDto {
  static const Set<String> jsonKeys = <String>{'enabled', 'biometricClass', 'helloKey', 'consent'};
  static const Set<String> requiredKeys = <String>{'enabled'};

  /// `MeBiometricsRequest.biometricClass` — те же строки, что `BiometricKind.apiClass` (core/biometrics). `class2`
  /// — только `platform=android` (уровень W, 09 BIO-030); `helloKey` — только с `windows_hello` (W2, 09 BIO-038).
  static const Set<String> biometricClasses = <String>{'class3', 'ios', 'windows_hello', 'class2'};

  static Map<String, Object?> toJson({
    required bool enabled,
    String? biometricClass,
    MeBiometricsHelloKeyDto? helloKey,
    MeBiometricsConsentDto? consent,
  }) => <String, Object?>{
    'enabled': enabled,
    'biometricClass': ?biometricClass,
    'helloKey': ?helloKey?.toJson(),
    'consent': ?consent?.toJson(),
  };
}

/// `MeBiometricsHelloKey` — открытый ключ Windows Hello устройства (W2; 08 §4.3.6; 07 §5.66; 11 SEC-146): сервер
/// хранит только его, токен в ответ не выдаётся.
final class MeBiometricsHelloKeyDto {
  const MeBiometricsHelloKeyDto({
    required this.publicKey,
    required this.source,
    this.algorithm = HelloKeyAlgorithm.rs256,
  });

  static const Set<String> jsonKeys = <String>{'publicKey', 'algorithm', 'source'};
  static const Set<String> requiredKeys = <String>{'publicKey', 'algorithm', 'source'};

  /// X509 SubjectPublicKeyInfo (DER, base64url без `=`) ключа RSA 2048…4096 бит, экспонента 65537; иначе сервер
  /// отвечает `400 VALIDATION_FAILED rule=hello_key_format`.
  final String publicKey;
  final HelloKeyAlgorithm algorithm;

  /// `windows_hello` — ключ `KeyCredentialManager` приложения Windows; `webauthn_prf` — ключ браузера на Windows
  /// под ключом из PRF passkey (веб-демо, 09 BIO-041).
  final HelloKeySource source;

  Map<String, Object?> toJson() => <String, Object?>{
    'publicKey': publicKey,
    'algorithm': algorithm.value,
    'source': source.value,
  };

  @override
  String toString() => 'MeBiometricsHelloKeyDto(${algorithm.value}, ${source.value})';
}

/// `MeBiometricsConsent` — согласие `biometrics_device` текущей версии (08 §4.3.6; 11 шаблон 3).
final class MeBiometricsConsentDto {
  const MeBiometricsConsentDto({required this.version, this.granted = true});

  static const Set<String> jsonKeys = <String>{'kind', 'version', 'granted'};
  static const Set<String> requiredKeys = <String>{'kind', 'version', 'granted'};

  final String version;
  final bool granted;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': ConsentKind.biometricsDevice.value,
    'version': version,
    'granted': granted,
  };
}

/// `MeBiometricsResponse.reason` — почему сервер ответил `200 {enabled:false}` на включение.
enum MeBiometricsRefusal {
  /// Windows без `helloKey`: гейт W1 живёт только на устройстве, сервер ничего не хранит (08 §4.3.6).
  noCryptoBindingOnPlatform('no_crypto_binding_on_platform'),

  /// `AUTH_BIO_ALLOW_WEAK` не разрешает уровень W этому пользователю (09 BIO-030).
  weakBiometricsDisabled('weak_biometrics_disabled'),

  /// `AUTH_WINDOWS_HELLO_KEY=off` (09 BIO-038; 02 `settings_hello_key_disabled`).
  helloKeyDisabled('hello_key_disabled'),

  /// Правило `personal`: с этим устройством за 30 дней входил другой пользователь (09 BIO-040;
  /// 02 `settings_hello_key_shared_device`).
  helloKeySharedDevice('hello_key_shared_device'),

  /// Значение, неизвестное этой сборке (08 §2.11) — как отказ без особого текста.
  unknown('unknown');

  const MeBiometricsRefusal(this.value);

  final String value;

  /// `null` — причины нет.
  static MeBiometricsRefusal? parse(String? raw) => raw == null
      ? null
      : values.firstWhere((MeBiometricsRefusal r) => r.value == raw && r != unknown, orElse: () => unknown);
}

/// `MeBiometricsResponse`: Android/iOS — `biometricRefreshToken` (уровни S и W); Windows с ключом — `enabled:true`
/// без токена; отказ — `enabled:false` + [reason].
final class MeBiometricsResponseDto {
  const MeBiometricsResponseDto({required this.enabled, this.biometricRefreshToken, this.expiresAt, this.reason});

  /// Терпимый разбор (08 §2.11): `enabled` не `true` — выключено; неизвестная причина — [MeBiometricsRefusal.unknown].
  factory MeBiometricsResponseDto.fromJson(Map<String, Object?> json) {
    final Object? token = json['biometricRefreshToken'];
    final Object? expiresAt = json['expiresAt'];
    final Object? reason = json['reason'];
    return MeBiometricsResponseDto(
      enabled: json['enabled'] == true,
      biometricRefreshToken: token is String && token.isNotEmpty ? token : null,
      expiresAt: expiresAt is String ? DateTime.tryParse(expiresAt) : null,
      reason: MeBiometricsRefusal.parse(reason is String ? reason : null),
    );
  }

  static const Set<String> jsonKeys = <String>{'enabled', 'biometricRefreshToken', 'expiresAt', 'reason'};
  static const Set<String> requiredKeys = <String>{'enabled'};

  final bool enabled;

  /// Секрет — не логируется; на Windows не выдаётся.
  final String? biometricRefreshToken;
  final DateTime? expiresAt;
  final MeBiometricsRefusal? reason;

  @override
  String toString() => 'MeBiometricsResponseDto(enabled: $enabled, reason: ${reason?.value})';
}
