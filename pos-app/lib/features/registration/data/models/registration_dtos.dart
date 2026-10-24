// DTO регистрации — вручную по ADR-085 (источник истины — contracts/openapi/pos-api.v1.yaml:
// RegistrationCompleteRequest, RegistrationSecurity, RegistrationConsentGrant, AuthDeviceInfo,
// RegistrationCompleteAuthenticated, AuthPendingActivation, RegistrationCustomerMatch(Summary),
// MeBiometricsRequest/Response, AuthStepUpRequest/AuthStepUpToken, MePinSetRequest, MeConsentUpdateRequest).
// Тела запросов с PIN/токенами живут только в памяти и не логируются (LoggingInterceptor тела не пишет).
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';

abstract final class RegistrationDtos {
  /// `RegistrationCompleteRequest` (`additionalProperties: false` — только поля схемы; `device.model` нет).
  static Map<String, Object?> completeRequest(RegistrationRequest r, Map<String, Object?> device) => <String, Object?>{
    'registrationToken': r.registrationToken,
    'fullName': r.fullName,
    'birthYear': r.birthYear,
    if (r.activitySphere != null) 'activitySphere': r.activitySphere!.code,
    'security': <String, Object?>{'pin': ?r.pin, 'biometricsEnabled': r.biometricsEnabled},
    'consents': <Map<String, Object?>>[
      for (final c in r.consents) <String, Object?>{'kind': c.kind, 'version': c.version},
    ],
    'device': device,
  };

  /// Токены из `201` (`AuthAuthenticated` / `AuthPendingActivation`).
  static ({String access, String refresh})? tokens(Map<String, Object?> json) {
    final access = json['accessToken'];
    final refresh = json['refreshToken'];
    if (access is! String || refresh is! String || access.isEmpty || refresh.isEmpty) return null;
    return (access: access, refresh: refresh);
  }

  /// `201` → [RegistrationOutcome] (токены не входят в сущность).
  static RegistrationOutcome outcome(Map<String, Object?> json) {
    final user = json['user'] is Map ? Map<String, Object?>.from(json['user']! as Map) : const <String, Object?>{};
    final roles = <String>[
      for (final r in (user['roles'] is List ? user['roles']! as List : const <Object?>[]))
        if (r is String) r,
    ];
    final match = json['customerMatch'] is Map
        ? customerMatch(Map<String, Object?>.from(json['customerMatch']! as Map))
        : null;
    return RegistrationOutcome(
      accountStatus: json['status'] == 'pending_activation'
          ? RegistrationAccountStatus.pendingActivation
          : RegistrationAccountStatus.authenticated,
      userKind: user['kind'] as String?,
      roles: roles,
      customerMatch: match,
      biometricRefreshOffered: json['biometricRefreshOffered'] == true,
    );
  }

  /// `RegistrationCustomerMatch` / `RegistrationCustomerMatchSummary` / `Problem.nextStep`.
  static CustomerMatch customerMatch(Map<String, Object?> json) {
    final customer = json['customer'] is Map ? Map<String, Object?>.from(json['customer']! as Map) : null;
    return CustomerMatch(
      status: CustomerLinkStatus.parse(json['status']),
      nextStep: CustomerMatchNextStep.parse(json['nextStep']),
      linkId: json['linkId'] as String?,
      displayNameMasked: customer?['displayNameMasked'] as String?,
      displayName: customer?['displayName'] as String?,
    );
  }

  /// `MeBiometricsRequest` для включения (согласие текущей версии — 08 §4.3.6).
  static Map<String, Object?> enableBiometrics(String? biometricClass) => <String, Object?>{
    'enabled': true,
    'biometricClass': ?biometricClass,
    'consent': <String, Object?>{
      'kind': 'biometrics_device',
      'version': ConsentVersions.biometricsDevice,
      'granted': true,
    },
  };

  /// `MeBiometricsResponse` → `biometricRefreshToken` или `null` (Windows / выключено).
  static String? biometricRefreshToken(Map<String, Object?> json) {
    final token = json['biometricRefreshToken'];
    return json['enabled'] == true && token is String && token.isNotEmpty ? token : null;
  }

  /// `AuthStepUpRequest` (method=pin).
  static Map<String, Object?> stepUpPin(String pin, String operation) => <String, Object?>{
    'method': 'pin',
    'pin': pin,
    'operation': operation,
  };

  /// `AuthStepUpToken.stepUpToken`.
  static String? stepUpToken(Map<String, Object?> json) {
    final token = json['stepUpToken'];
    return token is String && token.isNotEmpty ? token : null;
  }

  /// `Me` → [AccountSnapshot] (ПДн — только в памяти).
  static AccountSnapshot account(Map<String, Object?> json) {
    final profile = json['profile'] is Map ? Map<String, Object?>.from(json['profile']! as Map) : null;
    final session = json['session'] is Map ? Map<String, Object?>.from(json['session']! as Map) : null;
    return AccountSnapshot(
      status: (json['status'] as String?) ?? 'pending_activation',
      roles: <String>[
        for (final r in (json['roles'] is List ? json['roles']! as List : const <Object?>[]))
          if (r is String) r,
      ],
      fullName: profile?['fullName'] as String?,
      phone: profile?['phone'] as String?,
      registeredAt: DateTime.tryParse('${session?['createdAt'] ?? ''}'),
    );
  }
}
