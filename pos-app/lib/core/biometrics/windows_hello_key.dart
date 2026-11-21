// Ключ Windows Hello — вход на Windows без PIN приложения (режим W2; ответ владельца на Q-355 «Лицо без PIN
// (Рекоменд.)»; 15 ADR-116 п. 3; 09 §9.2 «Вход по ключу Windows Hello», BIO-038…BIO-040; 11 SEC-146, RR-10;
// 06 §6.2, §16.1).
//
// Ключ RSA-2048 `optomstroy.hello.v1.<userId>` создаёт и каждую подпись подтверждает Windows Hello (`KeyCredentialManager`;
// лицо, отпечаток или PIN Windows — различить нельзя). Закрытый ключ не покидает хранилище ключей Windows (TPM, если
// он есть), на сервер уходит только открытый ключ (SPKI). Разблокировка: challenge сервера → подпись → `POST
// /auth/unlock {method: hello_key, signature}`. Ключ сам сессию не открывает (нужен живой refresh — вход по SMS), для
// step-up не используется (BIO-024), `biometric_refresh` на Windows не выдаётся.
//
// Порт — необязательный интерфейс [BiometricHelloKey] по образцу `BiometricSecretReplacer`: его реализуют
// `WindowsHelloKeyAuthenticator` (windows_hello_key_authenticator.dart) и в веб-демо — `WebPasskeyAuthenticator` браузера
// на Windows (app/demo; 09 BIO-041, ключ под PRF passkey — [BrowserHelloKey]); фичи проверяют `is BiometricHelloKey`,
// без него — режим гейта W1, как до ADR-116. Причины недоступности Windows Hello для SCR-42 UI-42-029 (бывший пакет
// плана LF-1-04, влит в канал W2) — [WindowsHelloAvailability].
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/enums.dart';

/// Префикс имени ключа Windows Hello (09 BIO-038); полное имя — [helloKeyName].
const String helloKeyPrefix = 'optomstroy.hello.v1.';

/// Префикс challenge входа `POST /auth/unlock/challenge` (08 §4.1.10): ключ подписывает только такие строки.
const String helloChallengePrefix = 'optomstroy-hello-unlock/v1:';

/// Имя ключа Windows Hello пользователя [userId]: ключи разных пользователей приложения в одной учётной записи Windows
/// не пересекаются (09 BIO-038). `userId` — строчными, как в признаках по пользователю.
String helloKeyName(String userId) => '$helloKeyPrefix${userId.trim().toLowerCase()}';

/// Доступность Windows Hello (`UserConsentVerifier::CheckAvailabilityAsync`; 02 SCR-42 UI-42-029).
enum WindowsHelloAvailability {
  available('available'),

  /// Нет устройства Windows Hello (`settings_hello_no_device`).
  deviceNotPresent('device_not_present'),

  /// Windows Hello не настроен для пользователя Windows (`settings_hello_not_configured`).
  notConfigured('not_configured'),

  /// Отключён политикой компьютера (`settings_hello_disabled_by_policy`).
  disabledByPolicy('disabled_by_policy'),

  /// Устройство занято (`settings_hello_busy`).
  deviceBusy('device_busy'),

  /// Канал не ответил (нет канала в сборке, сбой WinRT) или значение неизвестно этой сборке — решает гейт
  /// `local_auth`, как до канала.
  unknown('unknown');

  const WindowsHelloAvailability(this.value);

  /// Значение протокола канала `kg.optomstroy/windows_hello`.
  final String value;

  static WindowsHelloAvailability parse(Object? raw) =>
      values.firstWhere((WindowsHelloAvailability a) => a.value == raw && a != unknown, orElse: () => unknown);
}

/// Ответ `availability` канала: доступность Windows Hello и поддержка ключей (`KeyCredentialManager::IsSupportedAsync`).
final class WindowsHelloStatus {
  const WindowsHelloStatus({required this.availability, required this.keysSupported});

  /// Канал не ответил.
  static const WindowsHelloStatus unknown = WindowsHelloStatus(
    availability: WindowsHelloAvailability.unknown,
    keysSupported: false,
  );

  final WindowsHelloAvailability availability;

  /// Ключи Windows Hello поддерживаются (условие BIO-038); иначе — режим гейта W1.
  final bool keysSupported;

  bool get isAvailable => availability == WindowsHelloAvailability.available;

  /// Ключ можно включить со стороны устройства; разрешение сервера (`security.windowsHelloKeyAllowed`), PIN и выбор
  /// пользователя проверяют фичи.
  bool get supportsKey => isAvailable && keysSupported;

  @override
  bool operator ==(Object other) =>
      other is WindowsHelloStatus && other.availability == availability && other.keysSupported == keysSupported;

  @override
  int get hashCode => Object.hash(availability, keysSupported);

  @override
  String toString() => 'WindowsHelloStatus(${availability.value}, keys: $keysSupported)';
}

/// Ключ Windows Hello (W2): создание, подпись challenge, удаление. Необязательная возможность порта
/// `BiometricAuthenticator` (реализация — Windows). Методы не бросают исключений; ключи и подписи не журналируются.
abstract interface class BiometricHelloKey {
  /// Доступность Windows Hello и поддержка ключей — без диалога.
  Future<WindowsHelloStatus> helloStatus();

  /// Создать ключ пользователя [userId] (диалог Windows Hello); ключ с тем же именем заменяется (повторное включение
  /// заменяет ключ устройства, BIO-038). Успех — открытый ключ X.509 SubjectPublicKeyInfo (DER, base64url без `=`) для
  /// `MeBiometricsHelloKey.publicKey`. Ошибки: отмена — [BiometricError.cancelled]; Windows Hello не настроен —
  /// [BiometricError.notEnrolled]; блокировка устройства — [BiometricError.lockout]; канала нет —
  /// [BiometricError.notAvailable]; иное — [BiometricError.failed].
  Future<BiometricResult<String>> createHelloKey(String userId);

  /// Подписать challenge входа [challenge] ключом [userId] (диалог Windows Hello): RSASSA-PKCS1-v1_5 / SHA-256 над
  /// UTF-8 строки, base64url без `=` — `AuthUnlockRequest.signature`. Ключа нет в Windows (сброс PIN Windows, удаление
  /// Windows Hello) — [BiometricError.noCredential] (09 §9.2 W2 п. 4); строка не challenge входа —
  /// [BiometricError.failed] без диалога; прочие ошибки — как у [createHelloKey].
  Future<BiometricResult<String>> signHelloChallenge(String userId, String challenge);

  /// Удалить ключ [userId] без диалога. `false` — ключа не было или удалить не удалось (только для журнала).
  Future<bool> deleteHelloKey(String userId);
}

/// Ключ входа браузера на Windows (веб-демо; 15 ADR-116 п. 4; 09 BIO-041, §9.4; 02 SCR-42.4 «UI-42-010 веб-демо») —
/// необязательная возможность порта с ключом [BiometricHelloKey] по образцу `BiometricSecretReplacer`. Ключ RSA-2048
/// создаёт WebCrypto страницы, закрытый ключ хранится под ключом из выхода PRF passkey; без PRF у браузера или у
/// Windows Hello ключ входа не создаётся, passkey браузера остаётся ключом гейта перед PIN (снекбар
/// `settings_hello_key_no_prf`). Реализация — `WebPasskeyAuthenticator` (app/demo); на Windows её нет — источник
/// [helloKeySourceOf] `windows_hello`.
abstract interface class BrowserHelloKey {
  /// Источник ключа для `MeBiometricsHelloKey.source` (`webauthn_prf`).
  HelloKeySource get helloKeySource;

  /// Как [BiometricHelloKey.createHelloKey], но отказ «нет PRF» отличим от прочих ([BrowserHelloKeyCreation.noPrf]).
  Future<BrowserHelloKeyCreation> createBrowserHelloKey(String userId);
}

/// Итог [BrowserHelloKey.createBrowserHelloKey].
final class BrowserHelloKeyCreation {
  const BrowserHelloKeyCreation(this.key, {this.noPrf = false, this.gate = false});

  /// Открытый ключ (SPKI, base64url без `=`) или ошибка — как у [BiometricHelloKey.createHelloKey]; без PRF —
  /// [BiometricError.notAvailable].
  final BiometricResult<String> key;

  /// Браузер или Windows Hello не дали PRF (`prf.enabled !== true` при создании passkey или нет выхода PRF): ключ входа
  /// не создан, вход без PIN в этом браузере больше не предлагается (до «Сбросить демо»).
  final bool noPrf;

  /// При [noPrf]: passkey браузера есть и остался ключом гейта (страница: `gate: true`) — гейт перед PIN включается
  /// без второго диалога; `false` — passkey нет, гейт включается обычным подтверждением присутствия.
  final bool gate;
}

/// Источник ключа порта [key]: браузер (веб-демо) — свой ([BrowserHelloKey.helloKeySource]), иначе Windows Hello.
HelloKeySource helloKeySourceOf(BiometricHelloKey key) =>
    key is BrowserHelloKey ? (key as BrowserHelloKey).helloKeySource : HelloKeySource.windowsHello;
