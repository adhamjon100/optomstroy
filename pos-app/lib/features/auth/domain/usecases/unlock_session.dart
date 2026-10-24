// Разблокировка SCR-08 (08 §4.1.8; D-48; 02 SCR-08.4): PIN проверяется только сервером,
// биометрия — расшифровка `biometric_refresh` после системного промпта (D-13).
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/auth/domain/entities/unlock.dart';
import 'package:optomstroy/features/auth/domain/ports/biometric_unlock.dart';
import 'package:optomstroy/features/auth/domain/repositories/auth_repository.dart';

/// PIN 4–6 цифр (09 §9.6; `AuthUnlockRequest.pin` pattern `^\d{4,6}$`).
final class UnlockWithPin {
  const UnlockWithPin(this._repository);

  final AuthRepository _repository;

  static bool isWellFormed(String pin) => RegExp(r'^\d{4,6}$').hasMatch(pin);

  Future<Result<UnlockSuccess>> call(String pin, {bool biometricInvalidated = false}) async {
    if (!isWellFormed(pin)) {
      return const FailureResult<UnlockSuccess>(
        ValidationFailure(
          errors: <FieldError>[FieldError(field: 'pin', rule: 'pin_format')],
        ),
      );
    }
    return _repository.unlockWithPin(pin: pin, biometricInvalidated: biometricInvalidated);
  }
}

/// Итог разблокировки биометрией.
sealed class BiometricUnlockOutcome {
  const BiometricUnlockOutcome();
}

final class BiometricUnlocked extends BiometricUnlockOutcome {
  const BiometricUnlocked(this.result);

  final UnlockSuccess result;
}

/// Отмена системного диалога — остаёмся на PIN.
final class BiometricUnlockCancelled extends BiometricUnlockOutcome {
  const BiometricUnlockCancelled();
}

/// Lockout ОС — кнопка недоступна, PIN доступен.
final class BiometricUnlockLockedOut extends BiometricUnlockOutcome {
  const BiometricUnlockLockedOut();
}

/// Ключ инвалидирован: `biometric_refresh` удалён, дальше — SCR-01 (`bio_invalidated`).
final class BiometricUnlockInvalidated extends BiometricUnlockOutcome {
  const BiometricUnlockInvalidated();
}

/// Биометрия недоступна — кнопка скрывается.
final class BiometricUnlockUnavailable extends BiometricUnlockOutcome {
  const BiometricUnlockUnavailable();
}

/// Ошибка сервера/сети при `POST /auth/unlock`.
final class BiometricUnlockFailed extends BiometricUnlockOutcome {
  const BiometricUnlockFailed(this.failure);

  final Failure failure;
}

final class UnlockWithBiometric {
  const UnlockWithBiometric(this._repository, this._biometrics);

  final AuthRepository _repository;
  final BiometricUnlock _biometrics;

  Future<BiometricUnlockOutcome> call() async {
    final BiometricSecretResult secret = await _biometrics.readSecret();
    switch (secret) {
      case BiometricSecretCancelled():
        return const BiometricUnlockCancelled();
      case BiometricSecretLockedOut():
        return const BiometricUnlockLockedOut();
      case BiometricSecretUnavailable():
        return const BiometricUnlockUnavailable();
      case BiometricSecretInvalidated():
        await _biometrics.clear();
        return const BiometricUnlockInvalidated();
      case BiometricSecretOk(secret: final String value):
        final Result<BiometricUnlockSuccess> result = await _repository.unlockWithBiometric(biometricRefresh: value);
        switch (result) {
          case Success<BiometricUnlockSuccess>(value: final BiometricUnlockSuccess ok):
            await _biometrics.storeSecret(ok.nextSecret);
            return BiometricUnlocked(ok.result);
          case FailureResult<BiometricUnlockSuccess>(:final Failure failure):
            if (failure is AuthFailure && failure.reason == AuthReason.sessionRevoked) {
              await _biometrics.clear();
            }
            return BiometricUnlockFailed(failure);
        }
    }
  }
}
