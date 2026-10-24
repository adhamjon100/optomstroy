// Порт вход/разблокировка (06 §6.14): реализация — data/repositories/auth_repository_impl.dart,
// подключение — data/auth_bindings.dart → app/di/overrides.dart (L-8, FL-06).
// Ошибки — Result/Failure (core/error), исключения наружу не выбрасываются.
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/auth/domain/entities/otp_challenge.dart';
import 'package:optomstroy/features/auth/domain/entities/session_profile.dart';
import 'package:optomstroy/features/auth/domain/entities/unlock.dart';
import 'package:optomstroy/features/auth/domain/entities/verify_outcome.dart';

/// Параметры кода из ответа `202` (`AuthOtpRequestResponse`).
final class OtpIssue {
  const OtpIssue({
    required this.challengeId,
    required this.resendAfterSec,
    required this.otpTtlSec,
    this.codeLength,
    this.phoneMasked,
    this.devCode,
  });

  final String challengeId;
  final int resendAfterSec;
  final int otpTtlSec;
  final int? codeLength;
  final String? phoneMasked;

  /// Код тестового режима OTP dev/staging (AU-03); вне контракта 08 — только отладочная подсказка.
  final String? devCode;

  @override
  String toString() => 'OtpIssue($challengeId)';
}

abstract interface class AuthRepository {
  /// `POST /auth/otp/request {phone, purpose: login_or_register, locale}` (08 §4.1.1).
  Future<Result<OtpIssue>> requestOtp({required String phoneE164});

  /// `GET /auth/otp/challenges/{challengeId}` (08 §4.1.9).
  Future<Result<OtpChallengeStatus>> challengeStatus(String challengeId);

  /// `POST /auth/otp/verify` (08 §4.1.2). При `authenticated`/`pending_activation`
  /// токены сохраняются **до** возврата результата (02 §0.3 И7).
  Future<Result<VerifyOutcome>> verifyOtp({required String challengeId, required String code});

  /// `POST /auth/unlock {method: pin, refreshToken, pin}` (08 §4.1.8). [biometricInvalidated] —
  /// ключ биометрии недоступен: сервер отзывает биометрическую семью.
  Future<Result<UnlockSuccess>> unlockWithPin({required String pin, bool biometricInvalidated = false});

  /// `POST /auth/unlock {method: biometric, refreshToken: <biometric_refresh>}`; в ответ —
  /// новый biometric refresh для повторного шифрования ([BiometricUnlockSuccess.nextSecret]).
  Future<Result<BiometricUnlockSuccess>> unlockWithBiometric({required String biometricRefresh});

  /// Есть ли сохранённая сессия (refresh в secure storage) — SCR-00/SCR-08.
  Future<bool> hasStoredSession();

  /// Кэш профиля последнего пользователя без телефона (02 §0.4); `unknown`, если нет.
  Future<SessionProfile> cachedProfile();

  /// Локальное завершение сессии: токены удаляются, `deviceId` сохраняется (07 §11.4).
  Future<void> clearLocalSession();
}

/// Успешная разблокировка биометрией.
final class BiometricUnlockSuccess {
  const BiometricUnlockSuccess({required this.result, required this.nextSecret});

  final UnlockSuccess result;

  /// Новый biometric refresh — сразу шифруется ключом Keystore/Keychain; не логируется.
  final String nextSecret;

  @override
  String toString() => 'BiometricUnlockSuccess(***)';
}
