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
// Уровни входа с `biometric_refresh` (15 ADR-116 п. 2; 09 §9.2, BIO-030…BIO-033; 11 RR-9):
// - уровень S ([BiometricTier.strong]) — криптопривязка выше (Android Class 3, iOS), без изменений;
// - уровень W ([BiometricTier.weak]) — только Android: «лицо или отпечаток» (Class 2) через `local_auth`
//   (`biometricOnly: true`, `sensitiveTransaction: false` → BiometricPrompt `BIOMETRIC_WEAK|BIOMETRIC_STRONG` без
//   `CryptoObject`), секрет — в `flutter_secure_storage` (`auth.biometric_refresh_weak`), ключ Keystore без привязки к
//   аутентификации. Читается только после успеха диалога; хук открывает его без лица — это принято RR-9
//   (компенсации — на сервере: PIN не реже раза в 24 ч, без step-up). Канал `kg.optomstroy/biometric_crypto`
//   (протокол v1) уровень W не знает; натив Android не меняется (12 T-BIO-027).
// Возможности уровня W описывают поля [BiometricCapability.weakAvailability] и [BiometricCapability.storedTier];
// запись секрета уровня W — необязательный интерфейс [BiometricWeakStore]. Реализации без уровня W (iOS, Windows,
// web, тесты) поля не задают: по умолчанию уровень W недоступен, поведение прежнее.
//
// Порт не принимает и не возвращает биометрические данные: приложение получает только результат ОС
// и (Android/iOS) расшифрованный `biometric_refresh`. Секрет не логируется; `toString` — без значений.

/// Платформенный вид биометрии устройства.
enum BiometricKind {
  /// Android, `BiometricManager.canAuthenticate(BIOMETRIC_STRONG)` (Class 3), API 30+.
  androidClass3,

  /// Android, уровень W (15 ADR-116, 09 BIO-030): «лицо или отпечаток» Class 2 по `local_auth`, API 30+, без
  /// криптопривязки. Вид устройства без датчика Class 3, на котором доступен только уровень W; он же — вид уровня W
  /// для `MeBiometricsRequest.biometricClass` ([BiometricCapability.kindFor]).
  androidClass2,

  /// iOS: Face ID / Touch ID (`LAPolicy.deviceOwnerAuthenticationWithBiometrics`).
  ios,

  /// Windows Hello (`UserConsentVerifier`) — без криптопривязки.
  windowsHello,

  /// Биометрии нет или платформа вне R1.
  none;

  /// Значение `MeBiometricsRequest.biometricClass` (08 §4.3.6); `null` — поле не передаётся.
  String? get apiClass => switch (this) {
    BiometricKind.androidClass3 => 'class3',
    BiometricKind.androidClass2 => 'class2',
    BiometricKind.ios => 'ios',
    BiometricKind.windowsHello => 'windows_hello',
    BiometricKind.none => null,
  };
}

/// Уровень входа по биометрии с `biometric_refresh` (15 ADR-116 п. 2; 09 §9.2; 11 RR-9). Ключ Windows Hello (W2,
/// 09 BIO-038, BIO-039) — не уровень `biometric_refresh`: токен на Windows не выдаётся, сервер проверяет подпись.
enum BiometricTier {
  /// Уровень S: секрет под ключом, который открывает только сильная биометрия ОС (Android Class 3, iOS; D-13).
  strong,

  /// Уровень W (только Android): секрет без криптопривязки, открывается после успеха диалога `local_auth`
  /// Class 2 (BIO-030; RR-9). Не для step-up (BIO-024), не на SCR-04 и не на планшете магазина (BIO-031, BIO-037).
  weak,
}

/// Доступность биометрии на устройстве.
enum BiometricAvailability {
  /// Можно использовать.
  available,

  /// Датчик есть, но биометрия в ОС не настроена.
  notEnrolled,

  /// Временная/постоянная блокировка ОС после неудачных попыток.
  lockedOut,

  /// Нет датчика, API < 30, только слабая (Class 2) биометрия для уровня S (уровень W — отдельно,
  /// [BiometricCapability.weakAvailability]), нет кода устройства (iOS), платформа вне R1.
  unsupported,
}

/// Возможности биометрии устройства.
///
/// [availability], [cryptoBinding] и [reason] описывают уровень S (Android Class 3, iOS) или гейт Windows Hello — как
/// до ADR-116; [kind] — вид устройства (ниже). Уровень W описывают [weakAvailability] и [weakReason], уровень
/// сохранённого секрета — [storedTier]; у реализаций без уровня W они по умолчанию «недоступно» и «неизвестно».
///
/// Вид у композита Android (S — канал ADR-087, W — `local_auth`; 06 §6.2): [BiometricKind.androidClass3], если канал
/// сообщает датчик Class 3 (`availability` ≠ `unsupported`); иначе [BiometricKind.androidClass2], если уровень W не
/// `unsupported`; иначе — ответ канала как есть.
final class BiometricCapability {
  const BiometricCapability({
    required this.kind,
    required this.availability,
    required this.cryptoBinding,
    this.reason,
    this.weakAvailability = BiometricAvailability.unsupported,
    this.weakReason,
    this.storedTier,
  });

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

  /// Доступность уровня W (09 BIO-030, BIO-033): `available` — API ≥ 30, `local_auth` поддерживает устройство и видит
  /// биометрию (`weak` или `strong`), блокировка экрана защищена, в `ENV=prod` — физическое устройство и
  /// release-сборка (11 SEC-090). Разрешение сервера (`security.biometricWeakAllowed`), заданный PIN и выбор
  /// пользователя в SCR-42 проверяют фичи, не порт.
  final BiometricAvailability weakAvailability;

  /// Машинная причина недоступности уровня W (`api_level`, `no_biometrics`, `no_device_credential`, `emulator`,
  /// `debug_build`, `platform`, …); только для журналов и тестов, без данных пользователя.
  final String? weakReason;

  /// Уровень сохранённого секрета, если реализация знает его без системного диалога: [BiometricTier.weak] — есть
  /// секрет уровня W, [BiometricTier.strong] — есть секрет уровня S; `null` — секрета нет или реализация уровни не
  /// различает (канал v1, Windows, web) — тогда действует прежнее правило: уровень S и
  /// [BiometricAuthenticator.hasStoredSecret].
  final BiometricTier? storedTier;

  bool get isAvailable => availability == BiometricAvailability.available;

  /// Можно включить вход по биометрии с `biometric_refresh` (09 §9.4: Android Class 3 API 30+, iOS).
  bool get supportsCryptoLogin => isAvailable && cryptoBinding;

  /// Устройство допускает вход уровнем W (BIO-030; без проверок сервера, PIN и выбора пользователя).
  bool get supportsWeakLogin => weakAvailability == BiometricAvailability.available;

  /// Уровень, которым устройство может войти по `biometric_refresh` сейчас: S, если доступен (надёжнее; по умолчанию
  /// предлагается он — Q-354), иначе W; `null` — ни один уровень не доступен.
  BiometricTier? get preferredTier => supportsCryptoLogin
      ? BiometricTier.strong
      : supportsWeakLogin
      ? BiometricTier.weak
      : null;

  /// Вид для уровня [tier] — значение `MeBiometricsRequest.biometricClass` ([BiometricKind.apiClass]): уровень W —
  /// всегда [BiometricKind.androidClass2] (`class2`); уровень S — [kind], а на устройстве только с уровнем W
  /// ([kind] = [BiometricKind.androidClass2]) — [BiometricKind.none]: датчика Class 3 нет.
  BiometricKind kindFor(BiometricTier tier) => switch (tier) {
    BiometricTier.weak => BiometricKind.androidClass2,
    BiometricTier.strong => kind == BiometricKind.androidClass2 ? BiometricKind.none : kind,
  };

  @override
  String toString() =>
      'BiometricCapability(${kind.name}, ${availability.name}, crypto: $cryptoBinding, $reason, '
      'weak: ${weakAvailability.name}${weakReason == null ? '' : ' $weakReason'}, stored: ${storedTier?.name})';
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

  /// Уровень S: создать новый ключ, подтвердить биометрией (системный диалог) и сохранить [secret]
  /// (`biometric_refresh`) под этим ключом. Прежний ключ и секрет удаляются (у композита Android — и секрет уровня W:
  /// одна семья биометрии на устройство, 08 §4.3.6). Только при [BiometricCapability.supportsCryptoLogin]; уровень W
  /// записывает [BiometricWeakStore.storeWeak].
  Future<BiometricResult<void>> store(String secret, BiometricPromptText prompt);

  /// Системный диалог → сохранённый секрет того уровня, которым он записан. [BiometricError.invalidated] — ключ
  /// инвалидирован ОС (секрет уже удалён), [BiometricError.noCredential] — секрета нет. Уровень W (BIO-030, BIO-033):
  /// перед диалогом — проверка, что `local_auth` видит биометрию и блокировка экрана защищена (иначе секрет удаляется,
  /// [BiometricError.invalidated]); затем диалог `local_auth` (`biometricOnly: true`, `sensitiveTransaction: false`);
  /// секрет читается только после его успеха, при отмене не трогается.
  Future<BiometricResult<String>> read(BiometricPromptText prompt);

  /// Есть ли сохранённый секрет любого уровня (без диалога).
  Future<bool> hasStoredSecret();

  /// Удалить ключи и секреты всех уровней (выключение биометрии, logout, инвалидация, подключение планшета).
  Future<void> clear();

  /// Только UX-гейт (Windows Hello, `local_auth`): подтверждение присутствия без доступа к секретам.
  /// Результат **не** открывает сессию и не заменяет PIN (09 §9.2, MASWE-0020).
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt);
}

/// Замена сохранённого секрета **тем же** ключом (02 SCR-08.4 п. 3; 09 §9.2; D AU-07): новый `biometric_refresh`
/// после `/auth/unlock {method: biometric}` шифруется существующим ключом Keystore / пишется в тот же элемент
/// Keychain — без генерации нового ключа и без удаления прежнего. Ключ уровня S требует биометрию на каждую операцию
/// (D-13), поэтому системный диалог при замене остаётся. Уровень W (BIO-030; 15 ADR-116 п. 2) — запись в то же место
/// **без** диалога: секрет уже открыт диалогом [BiometricAuthenticator.read] этой разблокировки, второго диалога нет.
/// Необязательная возможность реализации: адаптер проверяет `is BiometricSecretReplacer` и без неё выполняет
/// [BiometricAuthenticator.store].
abstract interface class BiometricSecretReplacer {
  /// [BiometricError.noCredential] — ключа/секрета нет (нужен [BiometricAuthenticator.store]);
  /// [BiometricError.notAvailable] — платформа/канал без метода `replace`.
  Future<BiometricResult<void>> replace(String secret, BiometricPromptText prompt);
}

/// Запись секрета уровня W (только Android; 09 BIO-030; 15 ADR-116 п. 2; 11 RR-9): системный диалог `local_auth`
/// (`biometricOnly: true`, `sensitiveTransaction: false` — BiometricPrompt `BIOMETRIC_WEAK|BIOMETRIC_STRONG` без
/// `CryptoObject`) → при успехе [secret] (`biometric_refresh` семьи с `weak_reauth_due_at`) пишется в
/// `flutter_secure_storage` (`auth.biometric_refresh_weak`), прежний секрет любого уровня удаляется; при неуспехе
/// ничего не записывается. Только при [BiometricCapability.supportsWeakLogin], иначе [BiometricError.notAvailable].
/// Чтение — [BiometricAuthenticator.read], замена без диалога — [BiometricSecretReplacer.replace], удаление —
/// [BiometricAuthenticator.clear]. Для step-up, SCR-04 и планшета магазина уровень W не используется (BIO-024,
/// BIO-031, BIO-037). Необязательная возможность реализации (по образцу [BiometricSecretReplacer], подписи порта и
/// подмен в тестах не меняются): фичи проверяют `is BiometricWeakStore`; без неё уровень W не предлагается.
abstract interface class BiometricWeakStore {
  /// Ошибки — как у [BiometricAuthenticator.store]: отмена, блокировка, биометрии нет, иная ошибка ОС.
  Future<BiometricResult<void>> storeWeak(String secret, BiometricPromptText prompt);
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
