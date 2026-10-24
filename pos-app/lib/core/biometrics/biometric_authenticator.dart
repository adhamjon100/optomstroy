// Порт системной биометрии с криптопривязкой (D-13; ядро §21 п.2; 09 §9.2, §9.4; ADR-013 и уточнение этапа D).
//
// Путь криптопривязки выбран по результату RM-C-013: пакет `biometric_storage` несовместим с
// `flutter_secure_storage` 11 на Flutter 3.38.7 (docs/stages/C_biometric_prototype.md §2), поэтому
// используется собственный platform channel [BiometricCryptoChannel]:
// - Android (API 30+): ключ AES-256-GCM в AndroidKeyStore с `setUserAuthenticationRequired(true)`,
//   `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)` (без окна валидности),
//   `setInvalidatedByBiometricEnrollment(true)`; шифрование/расшифровка `biometric_refresh` — только внутри
//   `BiometricPrompt.authenticate(CryptoObject(cipher))` (BIOMETRIC_STRONG). Инвалидация ключа
//   (`KeyPermanentlyInvalidatedException`) → [BiometricError.invalidated].
// - iOS: элемент Keychain с `SecAccessControl(kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet)`.
// - Windows: Windows Hello (`local_auth`) — только UX-гейт перед PIN, секреты не хранит (D-13, D-48).
//
// Порт не принимает и не возвращает биометрические данные: приложение получает только результат ОС
// и (Android/iOS) расшифрованный `biometric_refresh`. Секрет не логируется; `toString` — без значений.

/// Платформенный вид биометрии устройства.
enum BiometricKind {
  /// Android, `BiometricManager.canAuthenticate(BIOMETRIC_STRONG)` (Class 3), API 30+.
  androidClass3,

  /// iOS: Face ID / Touch ID (`LAPolicy.deviceOwnerAuthenticationWithBiometrics`).
  ios,

  /// Windows Hello (`UserConsentVerifier`) — без криптопривязки.
  windowsHello,

  /// Биометрии нет или платформа вне R1.
  none;

  /// Значение `MeBiometricsRequest.biometricClass` (08 §4.3.6); `null` — поле не передаётся.
  String? get apiClass => switch (this) {
    BiometricKind.androidClass3 => 'class3',
    BiometricKind.ios => 'ios',
    BiometricKind.windowsHello => 'windows_hello',
    BiometricKind.none => null,
  };
}

/// Доступность биометрии на устройстве.
enum BiometricAvailability {
  /// Можно использовать.
  available,

  /// Датчик есть, но биометрия в ОС не настроена.
  notEnrolled,

  /// Временная/постоянная блокировка ОС после неудачных попыток.
  lockedOut,

  /// Нет датчика, API < 30, только слабая (Class 2) биометрия, нет кода устройства (iOS), платформа вне R1.
  unsupported,
}

/// Возможности биометрии устройства.
final class BiometricCapability {
  const BiometricCapability({required this.kind, required this.availability, required this.cryptoBinding, this.reason});

  /// Нет биометрии (тесты, неподдерживаемые платформы).
  static const BiometricCapability none = BiometricCapability(
    kind: BiometricKind.none,
    availability: BiometricAvailability.unsupported,
    cryptoBinding: false,
    reason: 'platform',
  );

  final BiometricKind kind;
  final BiometricAvailability availability;

  /// `true` — секрет хранится под ключом, который открывается только сильной биометрией (Android/iOS).
  final bool cryptoBinding;

  /// Машинная причина недоступности (`api_level`, `no_hardware`, `weak_only`, `no_passcode`, `platform`, …).
  final String? reason;

  bool get isAvailable => availability == BiometricAvailability.available;

  /// Можно включить вход по биометрии с `biometric_refresh` (09 §9.4: Android Class 3 API 30+, iOS).
  bool get supportsCryptoLogin => isAvailable && cryptoBinding;

  @override
  String toString() => 'BiometricCapability(${kind.name}, ${availability.name}, crypto: $cryptoBinding, $reason)';
}

/// Ошибки операций биометрии (09 §9.3: отказ, блокировка, инвалидация).
enum BiometricError {
  /// Пользователь отменил системный диалог (или нажал отрицательную кнопку).
  cancelled,

  /// Набор биометрии в ОС изменился: ключ/элемент Keychain недействителен и удалён (`biometric_invalidated`).
  invalidated,

  /// Временная или постоянная блокировка биометрии ОС.
  lockout,

  /// Биометрия в ОС не настроена.
  notEnrolled,

  /// Возможность недоступна на устройстве/платформе.
  notAvailable,

  /// Сохранённого секрета нет.
  noCredential,

  /// Иная ошибка ОС / ключа (без подробностей в логах).
  failed,
}

/// Результат операции: значение или [BiometricError].
final class BiometricResult<T> {
  const BiometricResult.success(T this.value) : error = null;
  const BiometricResult.failure(BiometricError this.error) : value = null;

  final T? value;
  final BiometricError? error;

  bool get isSuccess => error == null;

  @override
  String toString() => isSuccess ? 'BiometricResult.success(***)' : 'BiometricResult.failure(${error!.name})';
}

/// Тексты системного диалога (локализуются экраном, ARB).
final class BiometricPromptText {
  const BiometricPromptText({required this.title, required this.cancel, this.subtitle});

  final String title;
  final String? subtitle;

  /// Отрицательная кнопка (Android BiometricPrompt требует её при BIOMETRIC_STRONG).
  final String cancel;
}

/// Порт биометрии устройства (core; реализации — [BiometricCryptoChannel] (Android/iOS), Windows Hello, нет).
abstract interface class BiometricAuthenticator {
  /// Доступность и вид биометрии (≤ 300 мс; без системного диалога).
  Future<BiometricCapability> capability();

  /// Создать новый ключ, подтвердить биометрией (системный диалог) и сохранить [secret] (`biometric_refresh`)
  /// под этим ключом. Прежний ключ и секрет удаляются. Только при [BiometricCapability.supportsCryptoLogin].
  Future<BiometricResult<void>> store(String secret, BiometricPromptText prompt);

  /// Системный диалог → расшифровать сохранённый секрет. [BiometricError.invalidated] — ключ инвалидирован ОС
  /// (секрет уже удалён), [BiometricError.noCredential] — секрета нет.
  Future<BiometricResult<String>> read(BiometricPromptText prompt);

  /// Есть ли сохранённый секрет (без диалога).
  Future<bool> hasStoredSecret();

  /// Удалить ключ и секрет (выключение биометрии, logout, инвалидация).
  Future<void> clear();

  /// Только UX-гейт (Windows Hello, `local_auth`): подтверждение присутствия без доступа к секретам.
  /// Результат **не** открывает сессию и не заменяет PIN (09 §9.2, MASWE-0020).
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt);
}

/// Замена сохранённого секрета **тем же** ключом (02 SCR-08.4 п. 3; 09 §9.2; D AU-07): новый `biometric_refresh`
/// после `/auth/unlock {method: biometric}` шифруется существующим ключом Keystore / пишется в тот же элемент
/// Keychain — без генерации нового ключа и без удаления прежнего. Ключ требует биометрию на каждую операцию
/// (D-13), поэтому системный диалог при замене остаётся. Необязательная возможность реализации: адаптер проверяет
/// `is BiometricSecretReplacer` и без неё выполняет [BiometricAuthenticator.store].
abstract interface class BiometricSecretReplacer {
  /// [BiometricError.noCredential] — ключа/секрета нет (нужен [BiometricAuthenticator.store]);
  /// [BiometricError.notAvailable] — платформа/канал без метода `replace`.
  Future<BiometricResult<void>> replace(String secret, BiometricPromptText prompt);
}

/// Реализация «биометрии нет» (платформы вне R1, тесты по умолчанию).
final class NoBiometricAuthenticator implements BiometricAuthenticator {
  const NoBiometricAuthenticator();

  @override
  Future<BiometricCapability> capability() async => BiometricCapability.none;

  @override
  Future<BiometricResult<void>> store(String secret, BiometricPromptText prompt) async =>
      const BiometricResult.failure(BiometricError.notAvailable);

  @override
  Future<BiometricResult<String>> read(BiometricPromptText prompt) async =>
      const BiometricResult.failure(BiometricError.notAvailable);

  @override
  Future<bool> hasStoredSecret() async => false;

  @override
  Future<void> clear() async {}

  @override
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) async =>
      const BiometricResult.failure(BiometricError.notAvailable);
}
