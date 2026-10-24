// Порт биометрии экрана SCR-08 (D-13; ядро §21 п.2; 09 §9.2–9.3).
//
// Реализация — адаптер к `BiometricAuthenticator` из core/hardware (platform channel:
// Android Keystore + BiometricPrompt.CryptoObject; iOS Keychain biometryCurrentSet;
// Windows Hello — только UX-гейт перед PIN). Адаптер подключает композиционный корень
// (app/di/overrides.dart). До подключения действует [NoBiometricUnlock]: биометрия скрыта,
// разблокировка — по PIN.

/// Что умеет устройство для SCR-08.
enum BiometricUnlockKind {
  /// Нет биометрии / не включена для пользователя / ключа нет — кнопка скрыта.
  none,

  /// Криптопривязанный `biometric_refresh` (Android class3 API ≥ 30, iOS).
  cryptoBound,

  /// Windows Hello — подтверждение присутствия перед обязательным PIN (D-13).
  windowsHelloGate,
}

/// Итог чтения `biometric_refresh` после системного промпта.
sealed class BiometricSecretResult {
  const BiometricSecretResult();
}

/// Пользователь подтвердил; [secret] — расшифрованный biometric refresh (не логируется).
final class BiometricSecretOk extends BiometricSecretResult {
  const BiometricSecretOk(this.secret);

  final String secret;

  @override
  String toString() => 'BiometricSecretOk(***)';
}

/// Отмена системного диалога (Cancel) — фокус на PIN (02 SCR-08.4 п.4).
final class BiometricSecretCancelled extends BiometricSecretResult {
  const BiometricSecretCancelled();
}

/// `temporaryLockout` / `biometricLockout` ОС — кнопка недоступна, PIN доступен (п.5).
final class BiometricSecretLockedOut extends BiometricSecretResult {
  const BiometricSecretLockedOut();
}

/// Ключ инвалидирован ОС (`KeyPermanentlyInvalidatedException` / `errSecItemNotFound`) — п.7.
final class BiometricSecretInvalidated extends BiometricSecretResult {
  const BiometricSecretInvalidated();
}

/// Биометрия недоступна (не настроена, нет оборудования, ошибка платформы) — п.6.
final class BiometricSecretUnavailable extends BiometricSecretResult {
  const BiometricSecretUnavailable();
}

abstract interface class BiometricUnlock {
  /// Возможности устройства независимо от пользователя (`AuthDeviceInfo.biometricClass`):
  /// `cryptoBound` — Android class3 / iOS, `windowsHelloGate` — Windows Hello настроен.
  Future<BiometricUnlockKind> capability();

  /// Доступный вид биометрии для текущего пользователя на этом устройстве
  /// (включена и ключ `biometric_refresh` на месте; для Windows — включён гейт Hello).
  Future<BiometricUnlockKind> kind();

  /// Системный промпт + расшифровка `biometric_refresh` (только [BiometricUnlockKind.cryptoBound]).
  Future<BiometricSecretResult> readSecret();

  /// Зашифровать новый biometric refresh тем же ключом (после `POST /auth/unlock`).
  Future<bool> storeSecret(String secret);

  /// Удалить `biometric_refresh` и ключ (инвалидирование, выход).
  Future<void> clear();

  /// Windows Hello: подтверждение присутствия; сессию само по себе не открывает (D-13).
  Future<bool> confirmPresence();
}

/// Биометрия не подключена/не поддерживается: только PIN.
final class NoBiometricUnlock implements BiometricUnlock {
  const NoBiometricUnlock();

  @override
  Future<BiometricUnlockKind> capability() async => BiometricUnlockKind.none;

  @override
  Future<BiometricUnlockKind> kind() async => BiometricUnlockKind.none;

  @override
  Future<BiometricSecretResult> readSecret() async => const BiometricSecretUnavailable();

  @override
  Future<bool> storeSecret(String secret) async => false;

  @override
  Future<void> clear() async {}

  @override
  Future<bool> confirmPresence() async => false;
}
