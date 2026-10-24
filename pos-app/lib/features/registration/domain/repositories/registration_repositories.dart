// Порты фичи registration (06 §6.14). Реализации — features/registration/data (подключаются
// `registration_bindings.dart` в app/di/overrides.dart, FL-06). Ошибки — `Result`/`Failure` (06 §6.8).
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';

/// Сетевые операции регистрации и защиты входа (08 §4.2, §4.3.5–§4.3.7, §4.1.7).
abstract interface class RegistrationRepository {
  /// `POST /registration/complete` с `Idempotency-Key` (D-37); при `201` токены сохраняются (access — память,
  /// refresh — secure storage), PIN из запроса нигде не сохраняется.
  Future<Result<RegistrationOutcome>> complete(RegistrationRequest request, {required String idempotencyKey});

  /// `GET /registration/customer-match`.
  Future<Result<CustomerMatch>> customerMatch();

  /// `POST /registration/customer-match/confirm {linkId}`.
  Future<Result<CustomerMatch>> confirmCustomerMatch(String linkId);

  /// `POST /registration/customer-match/reject {linkId}`.
  Future<Result<CustomerMatch>> rejectCustomerMatch(String linkId);

  /// `POST /me/biometrics {enabled: true, biometricClass, consent}`. Возвращает `biometricRefreshToken`
  /// или `null` (Windows: `enabled:false, reason: no_crypto_binding_on_platform`).
  Future<Result<String?>> enableBiometrics({required String? biometricClass, String? stepUpToken});

  /// `POST /me/biometrics {enabled: false}` — отзыв неиспользованной биометрической семьи.
  Future<Result<void>> disableBiometrics({String? stepUpToken});

  /// `POST /auth/step-up {method: pin, pin, operation}` → `stepUpToken` (только память).
  Future<Result<String>> stepUpWithPin({required String pin, required String operation});

  /// `POST /me/pin {newPin}` (первый PIN: step-up засчитан OTP-входом ≤ 15 мин).
  Future<Result<void>> setPin(String newPin, {String? stepUpToken});

  /// `POST /me/consents` — `personal_data` (первый вход сотрудника, 09 §7.6).
  Future<Result<void>> acknowledgePersonalData();

  /// `GET /me` для SCR-07 (статус активации).
  Future<Result<AccountSnapshot>> fetchAccount();

  /// `POST /auth/logout` и локальная очистка токенов (кроме `deviceId`); офлайн — только локально.
  Future<void> logout();
}

/// Черновик регистрации (09 §7.4; 02 §0.4): ФИО и год — secure storage, шаги — `registration_draft`.
abstract interface class RegistrationDraftRepository {
  /// Черновик моложе [ttl] или `null` (просроченный удаляется).
  Future<RegistrationDraft?> load();

  /// Сохранить; срок — [ttl] от этого изменения.
  Future<void> save(RegistrationDraft draft);

  /// Удалить (201, истечение, выход, вход другим номером).
  Future<void> clear();

  /// Срок жизни черновика (= TTL `registration_token`, 15 мин).
  Duration get ttl;
}

/// Биометрия устройства для регистрации (адаптер порта core/biometrics).
abstract interface class DeviceBiometrics {
  /// Что предложить на SCR-04 (≤ 300 мс, без системного диалога).
  Future<BiometricOption> option();

  /// Класс для `MeBiometricsRequest.biometricClass` (`class3` / `ios` / `windows_hello`).
  Future<String?> apiClass();

  /// Создать ключ, показать системный диалог, сохранить `biometric_refresh` под ключом.
  Future<BiometricEnrollmentResult> bind(String biometricRefreshToken, BiometricPromptCopy copy);

  /// Windows Hello — подтверждение присутствия (UX-гейт).
  Future<BiometricEnrollmentResult> confirmPresence(BiometricPromptCopy copy);

  /// Удалить ключ и секрет.
  Future<void> discard();
}

/// Тексты системного диалога (из ARB).
final class BiometricPromptCopy {
  const BiometricPromptCopy({required this.title, required this.cancel, this.subtitle});

  final String title;
  final String? subtitle;
  final String cancel;
}
