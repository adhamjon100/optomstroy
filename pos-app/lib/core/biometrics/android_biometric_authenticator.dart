// Android: композит порта биометрии из двух уровней входа (15 ADR-116 п. 2; 09 §9.2, BIO-030, BIO-033; 11 RR-9,
// SEC-090; 06 §6.2):
// - уровень S — канал `kg.optomstroy/biometric_crypto` ([BiometricCryptoChannel], протокол v1 без изменений; ADR-087,
//   D-13): ключ AndroidKeyStore, BiometricPrompt `BIOMETRIC_STRONG` с `CryptoObject`;
// - уровень W — `local_auth` ([LocalAuthGateway]: `biometricOnly: true`, `sensitiveTransaction: false` →
//   BiometricPrompt `BIOMETRIC_WEAK|BIOMETRIC_STRONG` без `CryptoObject`, `local_auth_android` 2.0.8) и
//   `flutter_secure_storage` ([SecureKey.biometricRefreshWeak], ключ Keystore без привязки к аутентификации). Секрет
//   отдаётся только после успеха диалога; хук открывает его без лица — это принято RR-9 (компенсации на сервере:
//   PIN не реже раза в 24 ч, без step-up, отзыв переменной `AUTH_BIO_ALLOW_WEAK`).
// Натив Android не меняется (12 T-BIO-027): уровень W целиком на Dart и подключённом плагине `local_auth`.
//
// Правила композита (документация [BiometricCapability] и [BiometricWeakStore]):
// - вид — `androidClass3`, если канал сообщает датчик Class 3 (`availability` ≠ `unsupported`); иначе `androidClass2`,
//   если уровень W не `unsupported`; иначе — ответ канала;
// - уровень W доступен при API ≥ 30, `getAvailableBiometrics` ∋ `weak`|`strong` и `isDeviceSupported`; в `ENV=prod` —
//   только на физическом устройстве в release-сборке (SEC-090, [AndroidEnvProbe]). Защищённая блокировка экрана
//   [ТИПОВО]: Android не даёт настроить биометрию без PIN, графического ключа или пароля устройства и удаляет её при
//   снятии блокировки, поэтому видимая `local_auth` биометрия означает и защищённую блокировку; на прошивках —
//   T-BIO-026;
// - одна семья биометрии на устройство (08 §4.3.6): запись секрета одного уровня удаляет секрет другого; `clear` —
//   оба;
// - перед чтением секрета W — проверка BIO-033: биометрии или блокировки экрана больше нет → секрет удаляется,
//   [BiometricError.invalidated]; новое лицо или отпечаток в ОС уровень W не замечает (09 §9.4, честный список).
// Порт не получает и не возвращает биометрические данные; секрет не логируется.
import 'package:local_auth/local_auth.dart';
import 'package:optomstroy/core/biometrics/android_env_probe.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/biometric_crypto_channel.dart';
import 'package:optomstroy/core/biometrics/windows_hello_gate.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';

/// Состояние уровня W устройства: доступность и машинная причина (без данных пользователя).
typedef _WeakState = ({BiometricAvailability availability, String? reason});

/// Android: уровень S (канал ADR-087) и уровень W (`local_auth` + защищённое хранилище) за одним портом.
final class AndroidBiometricAuthenticator
    implements BiometricAuthenticator, BiometricSecretReplacer, BiometricWeakStore {
  AndroidBiometricAuthenticator({
    required SecureStorage storage,
    required bool requireReleaseDevice,
    BiometricCryptoChannel? strong,
    LocalAuthGateway? localAuth,
    AndroidEnvProbe? env,
  }) : _storage = storage,
       _requireReleaseDevice = requireReleaseDevice,
       _strong = strong ?? BiometricCryptoChannel(),
       _localAuth = localAuth ?? LocalAuthPackageGateway(),
       _env = env ?? DeviceInfoAndroidEnvProbe();

  /// Минимальный API уровня W (09 BIO-030; как у уровня S — `Build.VERSION_CODES.R`).
  static const int minWeakSdk = 30;

  /// Причины недоступности уровня W из-за сбоя платформы, а не устройства: секрет не удаляется.
  static const Set<String> transientWeakReasons = <String>{'platform', 'local_auth'};

  final SecureStorage _storage;

  /// `ENV=prod`: уровень W — только на физическом устройстве в release-сборке (11 SEC-090).
  final bool _requireReleaseDevice;
  final BiometricCryptoChannel _strong;
  final LocalAuthGateway _localAuth;
  final AndroidEnvProbe _env;

  @override
  Future<BiometricCapability> capability() async {
    // Параллельно: уровень W и наличие его секрета не бросают; ошибки канала — как у канала v1.
    final Future<_WeakState> weak = _weakState();
    final Future<bool> hasWeak = _hasWeak();
    final BiometricCapability s = await _strong.capability();
    final _WeakState w = await weak;
    final BiometricTier? stored = await hasWeak
        ? BiometricTier.weak
        : s.availability != BiometricAvailability.unsupported && await _strong.hasStoredSecret()
        ? BiometricTier.strong
        : null;
    return BiometricCapability(
      kind: kindOf(s, w.availability),
      availability: s.availability,
      cryptoBinding: s.cryptoBinding,
      reason: s.reason,
      weakAvailability: w.availability,
      weakReason: w.reason,
      storedTier: stored,
    );
  }

  /// Вид устройства по ответу канала [strong] и доступности уровня W [weak] (правило [BiometricCapability]).
  static BiometricKind kindOf(BiometricCapability strong, BiometricAvailability weak) {
    if (strong.kind == BiometricKind.androidClass3 && strong.availability != BiometricAvailability.unsupported) {
      return BiometricKind.androidClass3;
    }
    if (weak != BiometricAvailability.unsupported) return BiometricKind.androidClass2;
    return strong.kind;
  }

  /// Уровень S: секрет уровня W удаляется до диалога (канал сам удаляет прежний ключ до диалога — `clearAll()`).
  @override
  Future<BiometricResult<void>> store(String secret, BiometricPromptText prompt) async {
    await _deleteWeak();
    return _strong.store(secret, prompt);
  }

  @override
  Future<BiometricResult<void>> storeWeak(String secret, BiometricPromptText prompt) async {
    if ((await _weakState()).availability != BiometricAvailability.available) {
      return const BiometricResult.failure(BiometricError.notAvailable);
    }
    final BiometricResult<void> dialog = await _dialog(prompt);
    if (!dialog.isSuccess) return dialog;
    await _strong.clear();
    try {
      await _storage.write(SecureKey.biometricRefreshWeak, secret);
    } on Object {
      return const BiometricResult.failure(BiometricError.failed);
    }
    return const BiometricResult<void>.success(null);
  }

  @override
  Future<BiometricResult<String>> read(BiometricPromptText prompt) async {
    if (!await _hasWeak()) return _strong.read(prompt);
    // BIO-033: до диалога — биометрия и блокировка экрана на месте.
    final _WeakState w = await _weakState();
    if (w.availability != BiometricAvailability.available) {
      if (transientWeakReasons.contains(w.reason)) return const BiometricResult.failure(BiometricError.failed);
      await _deleteWeak();
      return const BiometricResult.failure(BiometricError.invalidated);
    }
    final BiometricResult<void> dialog = await _dialog(prompt);
    if (!dialog.isSuccess) {
      if (dialog.error == BiometricError.notEnrolled) {
        // Биометрию или блокировку экрана сняли между проверкой и диалогом — то же правило BIO-033.
        await _deleteWeak();
        return const BiometricResult.failure(BiometricError.invalidated);
      }
      return BiometricResult.failure(dialog.error!);
    }
    final String? secret = await _readWeak();
    return secret == null
        ? const BiometricResult.failure(BiometricError.noCredential)
        : BiometricResult.success(secret);
  }

  /// Уровень W — запись в то же место без диалога (секрет открыт диалогом [read] этой разблокировки); уровень S —
  /// канал (`replace` тем же ключом, с диалогом).
  @override
  Future<BiometricResult<void>> replace(String secret, BiometricPromptText prompt) async {
    if (!await _hasWeak()) return _strong.replace(secret, prompt);
    try {
      await _storage.write(SecureKey.biometricRefreshWeak, secret);
      return const BiometricResult<void>.success(null);
    } on Object {
      return const BiometricResult.failure(BiometricError.failed);
    }
  }

  @override
  Future<bool> hasStoredSecret() async => await _hasWeak() || await _strong.hasStoredSecret();

  @override
  Future<void> clear() async {
    await _strong.clear();
    await _deleteWeak();
  }

  /// На Android гейт без криптопривязки не используется: вход — только через [read] (09 §9.7).
  @override
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) async =>
      const BiometricResult.failure(BiometricError.notAvailable);

  Future<_WeakState> _weakState() async {
    try {
      final AndroidEnv env = await _env.read();
      if (env.sdkInt < minWeakSdk) return (availability: BiometricAvailability.unsupported, reason: 'api_level');
      if (_requireReleaseDevice && !env.isPhysicalDevice) {
        return (availability: BiometricAvailability.unsupported, reason: 'emulator');
      }
      if (_requireReleaseDevice && !env.isReleaseBuild) {
        return (availability: BiometricAvailability.unsupported, reason: 'debug_build');
      }
    } on Object {
      return (availability: BiometricAvailability.unsupported, reason: 'platform');
    }
    try {
      final List<BiometricType> enrolled = await _localAuth.availableBiometrics();
      if (!enrolled.contains(BiometricType.weak) && !enrolled.contains(BiometricType.strong)) {
        return await _localAuth.canCheckBiometrics()
            ? (availability: BiometricAvailability.notEnrolled, reason: 'no_biometrics')
            : (availability: BiometricAvailability.unsupported, reason: 'no_hardware');
      }
      if (!await _localAuth.isDeviceSupported()) {
        return (availability: BiometricAvailability.unsupported, reason: 'no_device_credential');
      }
      return (availability: BiometricAvailability.available, reason: null);
    } on Object {
      return (availability: BiometricAvailability.unsupported, reason: 'local_auth');
    }
  }

  /// Диалог уровня W: заголовок — [BiometricPromptText.title], текст — подзаголовок (или заголовок: у `local_auth`
  /// текст обязателен), строка подсказки пустая, отрицательная кнопка — [BiometricPromptText.cancel].
  Future<BiometricResult<void>> _dialog(BiometricPromptText prompt) async {
    try {
      final bool ok = await _localAuth.authenticate(
        prompt.subtitle ?? prompt.title,
        biometricOnly: true,
        sensitiveTransaction: false,
        texts: BiometricPromptText(title: prompt.title, cancel: prompt.cancel),
      );
      return ok ? const BiometricResult<void>.success(null) : const BiometricResult.failure(BiometricError.cancelled);
    } on LocalAuthException catch (e) {
      return BiometricResult.failure(WindowsHelloGate.mapLocalAuthCode(e.code));
    } on Object {
      return const BiometricResult.failure(BiometricError.failed);
    }
  }

  Future<String?> _readWeak() async {
    try {
      final String? value = await _storage.read(SecureKey.biometricRefreshWeak);
      return value == null || value.isEmpty ? null : value;
    } on Object {
      return null;
    }
  }

  /// Есть ли запись уровня W (значение не отдаётся и не сохраняется).
  Future<bool> _hasWeak() async => await _readWeak() != null;

  Future<void> _deleteWeak() async {
    try {
      await _storage.delete(SecureKey.biometricRefreshWeak);
    } on Object {
      // Хранилище недоступно — состояние «нет секрета» равнозначно (как `clear` канала).
    }
  }
}
