// Сценарии регистрации (09 §7.2–§7.3, §9.5; 02 SCR-04.4). Чистый Dart: только порты domain.
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';
import 'package:optomstroy/features/registration/domain/repositories/registration_repositories.dart';
import 'package:optomstroy/features/registration/domain/usecases/registration_validation.dart';

/// Выбор на SCR-04 (только память; PIN обнуляется после отправки).
final class LoginProtectionChoice {
  const LoginProtectionChoice({this.pin, this.biometricsEnabled = false, this.biometricsConsent = false});

  final String? pin;

  /// Переключатель «Биометрия устройства».
  final bool biometricsEnabled;

  /// Отметка отдельного согласия `biometrics_device` (UI-04-010).
  final bool biometricsConsent;

  /// Биометрия будет включена: переключатель + согласие (без согласия не включается, AC-UI-04-005).
  bool get biometricsGranted => biometricsEnabled && biometricsConsent;

  /// Хотя бы один способ защиты входа (ядро §24.2, 09 REG-038).
  bool satisfies(PinPolicy policy) {
    final hasPin = pin != null && pin!.isNotEmpty;
    return policy.mandatory ? hasPin : hasPin || biometricsGranted;
  }

  @override
  String toString() => 'LoginProtectionChoice(pin: ${pin == null ? 'no' : '***'}, bio: $biometricsGranted)';
}

/// Сборка тела `POST /registration/complete` (08 §4.2.1; 09 §7.3).
abstract final class RegistrationRequestBuilder {
  /// `consents[]`: `personal_data` — всегда; `activity_sphere` — только с согласием и выбранной сферой;
  /// `biometrics_device` — только при включённой биометрии с согласием; `sms` не передаётся (09 §7.3).
  static RegistrationRequest build({
    required RegistrationTicket ticket,
    required RegistrationDraft draft,
    required LoginProtectionChoice protection,
  }) {
    final sphere = draft.activitySphereConsent ? draft.activitySphere : null;
    return RegistrationRequest(
      registrationToken: ticket.registrationToken,
      fullName: RegistrationValidation.normalizeFullName(draft.fullName),
      birthYear: int.parse(draft.birthYear),
      activitySphere: sphere,
      pin: (protection.pin?.isEmpty ?? true) ? null : protection.pin,
      biometricsEnabled: protection.biometricsGranted,
      consents: <ConsentGrant>[
        const ConsentGrant('personal_data', ConsentVersions.personalData),
        if (sphere != null) const ConsentGrant('activity_sphere', ConsentVersions.activitySphere),
        if (protection.biometricsGranted) const ConsentGrant('biometrics_device', ConsentVersions.biometricsDevice),
      ],
    );
  }
}

/// Включение входа по биометрии после `201` / первого PIN (09 §9.5 п. 3; 02 SCR-04.4 «Системный диалог»).
///
/// Android/iOS: `POST /me/biometrics` → `biometricRefreshToken` → ключ Keystore/Keychain + системный диалог →
/// шифрование. Если диалог отменён или ОС отказала — неиспользованная семья отзывается
/// (`POST /me/biometrics {enabled:false}`), ключ удаляется. Windows: только подтверждение Windows Hello
/// (гейт перед PIN), сервер токен не выдаёт.
final class EnableBiometricLogin {
  const EnableBiometricLogin(this._repository, this._biometrics);

  final RegistrationRepository _repository;
  final DeviceBiometrics _biometrics;

  Future<BiometricEnrollment> call({required BiometricPromptCopy copy, String? stepUpToken}) async {
    final option = await _biometrics.option();
    switch (option) {
      case BiometricOption.windowsHelloGate:
        final gate = await _biometrics.confirmPresence(copy);
        return BiometricEnrollment(
          gate == BiometricEnrollmentResult.enabled ? BiometricEnrollmentResult.gateOnly : gate,
        );
      case BiometricOption.notEnrolled:
        return const BiometricEnrollment(BiometricEnrollmentResult.notEnrolled);
      case BiometricOption.unsupported:
        return const BiometricEnrollment(BiometricEnrollmentResult.failed);
      case BiometricOption.cryptoLogin:
        break;
    }
    final issued = await _repository.enableBiometrics(
      biometricClass: await _biometrics.apiClass(),
      stepUpToken: stepUpToken,
    );
    switch (issued) {
      case FailureResult<String?>(:final failure):
        if (failure is AuthFailure && failure.reason == AuthReason.stepUpRequired) {
          return BiometricEnrollment(
            BiometricEnrollmentResult.stepUpRequired,
            stepUpOperation: failure.stepUpOperation,
          );
        }
        return const BiometricEnrollment(BiometricEnrollmentResult.failed);
      case Success<String?>(:final value):
        if (value == null || value.isEmpty) return const BiometricEnrollment(BiometricEnrollmentResult.failed);
        final bound = await _biometrics.bind(value, copy);
        if (bound == BiometricEnrollmentResult.enabled) {
          return const BiometricEnrollment(BiometricEnrollmentResult.enabled);
        }
        await _biometrics.discard();
        await _repository.disableBiometrics(stepUpToken: stepUpToken);
        return BiometricEnrollment(bound);
    }
  }
}

/// `POST /auth/step-up {method: pin}` для `profile.biometrics.toggle` (02 SCR-04.4 п. 2).
final class StepUpWithPin {
  const StepUpWithPin(this._repository);

  /// Операция step-up включения биометрии (08 §2.12).
  static const String biometricsToggle = 'profile.biometrics.toggle';

  final RegistrationRepository _repository;

  /// Токен или результат ошибки PIN (`attemptsLeft` — только из ответа сервера).
  Future<({String? token, BiometricEnrollment? error})> call({required String pin, String? operation}) async {
    final res = await _repository.stepUpWithPin(pin: pin, operation: operation ?? biometricsToggle);
    return switch (res) {
      Success<String>(:final value) => (token: value, error: null),
      FailureResult<String>(:final failure) => (token: null, error: _map(failure)),
    };
  }

  static BiometricEnrollment _map(Failure failure) => switch (failure) {
    AuthFailure(reason: AuthReason.pinInvalid, :final attemptsLeft) => BiometricEnrollment(
      BiometricEnrollmentResult.pinInvalid,
      attemptsLeft: attemptsLeft,
    ),
    AuthFailure(reason: AuthReason.pinLocked) => const BiometricEnrollment(BiometricEnrollmentResult.pinLocked),
    _ => const BiometricEnrollment(BiometricEnrollmentResult.failed),
  };
}
