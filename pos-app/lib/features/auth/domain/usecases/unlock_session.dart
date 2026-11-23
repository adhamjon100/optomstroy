// Разблокировка SCR-08 (08 §4.1.8; D-48; 02 SCR-08.4): PIN проверяется только сервером,
// биометрия — расшифровка `biometric_refresh` после системного промпта (D-13), ключ Windows Hello (W2; 15 ADR-116
// п. 3; 09 BIO-039) — подпись challenge сервера, проверенная сервером.
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

  /// [helloKeyInvalidated] — ключ Windows Hello пропал в Windows: после верного PIN сервер отзывает ключ устройства
  /// (09 §9.2 W2 п. 4).
  Future<Result<UnlockSuccess>> call(
    String pin, {
    bool biometricInvalidated = false,
    bool helloKeyInvalidated = false,
  }) async {
    if (!isWellFormed(pin)) {
      return const FailureResult<UnlockSuccess>(
        ValidationFailure(
          errors: <FieldError>[FieldError(field: 'pin', rule: 'pin_format')],
        ),
      );
    }
    return _repository.unlockWithPin(
      pin: pin,
      biometricInvalidated: biometricInvalidated,
      helloKeyInvalidated: helloKeyInvalidated,
    );
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

/// Уровень W: `401 UNLOCK_REQUIRED {reason: bio_weak_pin_due}` (09 BIO-031) — раз в сутки нужен PIN. Секрет сохраняется
/// (после PIN тот же токен снова действует: сервер не ротирует и не отзывает); кнопка лица и автодиалог скрыты до
/// успешного PIN — без цикла автодиалога (02 SCR-08.4 п. 10).
final class BiometricUnlockPinDue extends BiometricUnlockOutcome {
  const BiometricUnlockPinDue();
}

/// Уровень W: `401 UNLOCK_REQUIRED {reason: bio_weak_disabled}` (09 BIO-032) — сервер отозвал семью; секрет удалён
/// ([BiometricUnlock.clear]), кнопки нет, поле PIN.
final class BiometricUnlockWeakDisabled extends BiometricUnlockOutcome {
  const BiometricUnlockWeakDisabled();
}

/// Ошибка сервера/сети при `POST /auth/unlock`.
final class BiometricUnlockFailed extends BiometricUnlockOutcome {
  const BiometricUnlockFailed(this.failure);

  final Failure failure;
}

/// Разблокировка по `biometric_refresh` (уровни S и W; 02 SCR-08.4 п. 3, п. 10): системный диалог → `POST /auth/unlock
/// {method: biometric}` → новый токен записывается портом (уровень W — без второго диалога, BIO-030). Отказы уровня W
/// приходят как `UNLOCK_REQUIRED` с причиной ([BiometricWeakRefusal]): `bio_weak_pin_due` — секрет не трогается,
/// `bio_weak_disabled` — секрет удаляется.
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
            if (failure is AuthFailure && failure.reason == AuthReason.unlockRequired) {
              switch (failure.unlockReason) {
                case BiometricWeakRefusal.pinDue:
                  return const BiometricUnlockPinDue();
                case BiometricWeakRefusal.disabled:
                  await _biometrics.clear();
                  return const BiometricUnlockWeakDisabled();
              }
            }
            return BiometricUnlockFailed(failure);
        }
    }
  }
}

/// Итог входа по ключу Windows Hello (W2; 02 SCR-08.4 «Windows Hello»; 09 §9.3).
sealed class HelloKeyUnlockOutcome {
  const HelloKeyUnlockOutcome();
}

/// `200 POST /auth/unlock {method: hello_key}` — вход без PIN.
final class HelloKeyUnlocked extends HelloKeyUnlockOutcome {
  const HelloKeyUnlocked(this.result);

  final UnlockSuccess result;
}

/// Отмена диалога Windows Hello, иная ошибка Windows Hello или `UNLOCK_REQUIRED hello_key_invalid` — ключ не
/// трогается; строка `unlock_hello_failed`, поле PIN.
final class HelloKeyUnlockRejected extends HelloKeyUnlockOutcome {
  const HelloKeyUnlockRejected();
}

/// `UNLOCK_REQUIRED hello_key_unavailable` (ключ отозван или запрещён) — признак и ключ удалены; строка
/// `unlock_hello_key_unavailable`, поле PIN (гейт W1, если включён, снова предлагается).
final class HelloKeyUnlockUnavailable extends HelloKeyUnlockOutcome {
  const HelloKeyUnlockUnavailable();
}

/// Ключ пропал в Windows — признак удалён; строка `unlock_hello_key_lost`, PIN с `helloKeyInvalidated: true`.
final class HelloKeyUnlockKeyLost extends HelloKeyUnlockOutcome {
  const HelloKeyUnlockKeyLost();
}

/// Ошибка сети или сессии (`SESSION_REVOKED`, нет сети, 5xx) — как у PIN.
final class HelloKeyUnlockFailed extends HelloKeyUnlockOutcome {
  const HelloKeyUnlockFailed(this.failure);

  final Failure failure;
}

/// Вход по ключу Windows Hello без PIN приложения (W2; 15 ADR-116 п. 3; 09 §9.2 «Вход по ключу Windows Hello» п. 2–4,
/// BIO-039): `POST /auth/unlock/challenge` → подпись ключом (диалог Windows Hello — только по нажатию кнопки) →
/// `POST /auth/unlock {method: hello_key, signature}`. Отказ challenge (`hello_key_unavailable`) приходит до диалога:
/// Windows Hello не спрашивается зря. Порт без [HelloKeyUnlock] (не Windows) — [HelloKeyUnlockUnavailable] без
/// запросов.
final class UnlockWithHelloKey {
  const UnlockWithHelloKey(this._repository, this._biometrics);

  final AuthRepository _repository;
  final BiometricUnlock _biometrics;

  Future<HelloKeyUnlockOutcome> call() async {
    final BiometricUnlock port = _biometrics;
    if (port is! HelloKeyUnlock) return const HelloKeyUnlockUnavailable();
    final HelloKeyUnlock key = port as HelloKeyUnlock;
    final String challenge;
    switch (await _repository.helloKeyChallenge()) {
      case Success<String>(:final String value):
        challenge = value;
      case FailureResult<String>(:final Failure failure):
        return _refused(failure, key);
    }
    switch (await key.signHelloChallenge(challenge)) {
      case HelloKeySignCancelled() || HelloKeySignFailed():
        return const HelloKeyUnlockRejected();
      case HelloKeyLost():
        await key.forgetHelloKey();
        return const HelloKeyUnlockKeyLost();
      case HelloKeySigned(:final String signature):
        switch (await _repository.unlockWithHelloKey(signature: signature)) {
          case Success<UnlockSuccess>(:final UnlockSuccess value):
            return HelloKeyUnlocked(value);
          case FailureResult<UnlockSuccess>(:final Failure failure):
            return _refused(failure, key);
        }
    }
  }

  Future<HelloKeyUnlockOutcome> _refused(Failure failure, HelloKeyUnlock key) async {
    if (failure is AuthFailure && failure.reason == AuthReason.unlockRequired) {
      switch (failure.unlockReason) {
        case HelloKeyRefusal.unavailable:
          await key.forgetHelloKey();
          return const HelloKeyUnlockUnavailable();
        case HelloKeyRefusal.invalid:
          return const HelloKeyUnlockRejected();
      }
    }
    return HelloKeyUnlockFailed(failure);
  }
}
