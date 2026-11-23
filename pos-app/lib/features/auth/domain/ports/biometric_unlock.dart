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

  /// Уровень W Android (15 ADR-116 п. 2; 09 BIO-030): `biometric_refresh` без криптопривязки, открывается после
  /// успеха диалога `local_auth` «лицо или отпечаток» (Class 2). `AuthDeviceInfo.biometricClass` — `class2`.
  weakBound,

  /// Windows Hello — подтверждение присутствия перед обязательным PIN (D-13).
  windowsHelloGate,

  /// Ключ Windows Hello (W2; 15 ADR-116 п. 3; 09 BIO-038, BIO-039): кнопка «Войти через Windows Hello» без автовызова,
  /// вход без PIN — challenge сервера, подпись ключом ([HelloKeyUnlock]), `POST /auth/unlock {method: hello_key}`.
  /// Только у пользователя, включившего ключ на этом устройстве (признак по `userId`); `AuthDeviceInfo.biometricClass`
  /// — `windows_hello`, как у гейта.
  windowsHelloKey,
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

/// Итог подписи challenge ключом Windows Hello (W2; 09 §9.2 «Вход по ключу Windows Hello» п. 3–4).
sealed class HelloKeySignResult {
  const HelloKeySignResult();
}

/// Windows Hello подтвердил; [signature] — `AuthUnlockRequest.signature` (не логируется).
final class HelloKeySigned extends HelloKeySignResult {
  const HelloKeySigned(this.signature);

  final String signature;

  @override
  String toString() => 'HelloKeySigned(***)';
}

/// Диалог Windows Hello отменён («предпочитаю пароль» — тоже) — `unlock_hello_failed`, поле PIN.
final class HelloKeySignCancelled extends HelloKeySignResult {
  const HelloKeySignCancelled();
}

/// Ключа нет в Windows (`KeyCredentialStatus.NotFound`: сброс PIN Windows, удаление Windows Hello) —
/// `unlock_hello_key_lost`, PIN с `helloKeyInvalidated: true` (09 §9.2 W2 п. 4).
final class HelloKeyLost extends HelloKeySignResult {
  const HelloKeyLost();
}

/// Иная ошибка Windows Hello (блокировка, сбой, канала нет, пользователь неизвестен) — `unlock_hello_failed`.
final class HelloKeySignFailed extends HelloKeySignResult {
  const HelloKeySignFailed();
}

/// Ключ Windows Hello на SCR-08 (W2) — необязательная возможность порта (реализует `BiometricUnlockAdapter` на
/// Windows; по образцу `BiometricSecretReplacer` core): use case проверяет `is HelloKeyUnlock`, без неё кнопки W2 нет.
abstract interface class HelloKeyUnlock {
  /// Диалог Windows Hello → подпись [challenge] ключом текущего пользователя.
  Future<HelloKeySignResult> signHelloChallenge(String challenge);

  /// Ключ больше не действует (сервер ответил `hello_key_unavailable` или ключ пропал в Windows): признак ключа
  /// текущего пользователя снимается, ключ в Windows удаляется (без диалога); признак гейта W1 не трогается — кнопка
  /// «Windows Hello» появится, если гейт включён (02 SCR-08.4).
  Future<void> forgetHelloKey();
}

abstract interface class BiometricUnlock {
  /// Возможности устройства независимо от пользователя (`AuthDeviceInfo.biometricClass`):
  /// `cryptoBound` — Android class3 / iOS, `weakBound` — Android только с уровнем W (Class 2, ADR-116; при Class 3
  /// и W — `cryptoBound`), `windowsHelloGate` — Windows Hello настроен.
  Future<BiometricUnlockKind> capability();

  /// Доступный вид биометрии для текущего пользователя на этом устройстве
  /// (включена и ключ `biometric_refresh` на месте; для Windows — включён гейт Hello). Уровень W (ADR-116) —
  /// [BiometricUnlockKind.weakBound]: сохранён секрет уровня W и устройство сейчас допускает уровень W (BIO-030).
  /// В сессии планшета магазина — всегда [BiometricUnlockKind.none] (09 BIO-037).
  Future<BiometricUnlockKind> kind();

  /// Системный промпт + расшифровка `biometric_refresh` ([BiometricUnlockKind.cryptoBound]) или чтение секрета уровня W
  /// после диалога «лицо или отпечаток» ([BiometricUnlockKind.weakBound]).
  Future<BiometricSecretResult> readSecret();

  /// Записать новый biometric refresh после `POST /auth/unlock`: уровень S — тем же ключом, уровень W — в то же место
  /// без второго диалога (BIO-030).
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
