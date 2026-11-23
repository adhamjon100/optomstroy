// Порт биометрии веб-демо — вход по лицу или отпечатку через passkey (WebAuthn) страницы (15 ADR-116 п. 1, п. 4;
// 09 §9.2 «Веб-демо», BIO-035, BIO-041, AC-AUTH-094; 06 §6.10; 12 T-DEMO-016). Подключается четвёртым переопределением
// `demoOverrides` (`biometricAuthenticatorProvider`); `lib/main.dart` и продукт web не меняются —
// там `NoBiometricAuthenticator` (DM-01).
//
// Режим выбирает приложение по платформе устройства браузера (`browserDevicePlatform` — та же, что сервер видит в
// `AuthDeviceInfo.platform`); страница платформу сама не определяет:
// - браузер не на Windows → привязка ([DemoPasskeyMode.bound]): `biometric_refresh` под ключом AES-256-GCM из выхода PRF
//   passkey; для приложения — как Android Class 3 (вид `android_class3`, `cryptoBinding`), сервер видит `android` +
//   `class3` и не меняется. Один диалог на вход; новый токен перешифровывается без второго диалога (ключ держится в
//   памяти страницы не дольше 60 с). Без PRF или без платформенного аутентификатора с проверкой пользователя вариант
//   скрыт (вид `none`);
// - браузер на Windows → [DemoPasskeyMode.gate]: вид `windows_hello` без криптопривязки (как приложение Windows), два
//   режима SCR-42 по тем же правилам, что у приложения Windows (`LoginProtectionRepositoryImpl.windowsSupportOf`):
//   (а) ключ входа без PIN (09 BIO-041, пакет LF-3-06; как W2): порт [BiometricHelloKey] и [BrowserHelloKey] — пара
//       RSA-2048 WebCrypto, закрытый ключ PKCS#8 под ключом из выхода PRF passkey (блоб `optomstroy.demo.passkeyHelloKey`
//       по `owner`), открытый ключ — `POST /me/biometrics {helloKey.source: webauthn_prf}`, вход — один диалог get() и
//       подпись challenge → `POST /auth/unlock {method: hello_key}`. Предлагается при `security.windowsHelloKeyAllowed`
//       (в демо `AUTH_WINDOWS_HELLO_KEY=all`) и `keysSupported` страницы (PRF не исключён);
//   (б) гейт перед PIN (как W1): `confirmPresence` = get() с проверкой пользователя, PIN приложения обязателен; признак
//       гейта — по `userId` (`auth.hello_gate_users`, как на Windows). Без PRF у браузера или у Windows Hello ключ
//       входа не создаётся: passkey браузера остаётся ключом гейта ([BrowserHelloKeyCreation.noPrf], снекбар
//       `settings_hello_key_no_prf`), страница ставит признак «PRF нет» и дальше сообщает `keysSupported: false`.
//
// Запись привязки — одного пользователя: `owner` — `userId` кэша профиля (02 §0.4; пишет SessionController при каждом
// входе и разблокировке), страница хранит только его отпечаток. Чужая запись не открывается и не предлагается. Ключи
// входа — по `userId`, который передают фичи (SCR-42, SCR-08), как имя ключа Windows Hello.
// Очистка сессии ([clear]) удаляет только блоб привязки: passkey браузера (гейт) и ключи входа остаются до
// «Сбросить демо» (ключ переживает выход, BIO-040); ключ входа удаляют [deleteHelloKey] (выключение в SCR-42, отказ
// сервера, пропажа ключа, подключение планшета) и «Сбросить демо».
//
// Тексты `BiometricPromptText` в браузере не показываются: у диалога WebAuthn нет своего заголовка — это ограничение,
// не ошибка. Ошибки страницы — коды канала криптопривязки ([BiometricCryptoChannel.parseError]); `lockout` и
// `not_enrolled` браузер не сообщает. Секрет и ответы со значениями не журналируются.
//
// Планшет магазина биометрию не вызывает: это делает адаптер SCR-08 (`kioskMode`, 09 BIO-037) и экраны SCR-51…SCR-53;
// подключение планшета удаляет ключи входа пользователей этого браузера (`SessionController.becomeKiosk` →
// [deleteHelloKey], без диалога).
import 'dart:async';

import 'package:logging/logging.dart';
import 'package:optomstroy/app/demo/demo_passkey_gateway.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/biometric_crypto_channel.dart';
import 'package:optomstroy/core/biometrics/windows_hello_key.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/network/browser_device.dart';
import 'package:optomstroy/core/network/client_meta.dart';

final Logger _log = Logger('demo.passkey');

/// Режим passkey веб-демо (15 ADR-116 п. 1, п. 4).
enum DemoPasskeyMode {
  /// Браузер не на Windows: `biometric_refresh` под ключом из PRF.
  bound('bound'),

  /// Браузер на Windows: ключ входа без PIN при PRF (BIO-041), иначе гейт перед PIN приложения.
  gate('gate');

  const DemoPasskeyMode(this.wire);

  /// Значение `mode` протокола страницы.
  final String wire;
}

/// Режим по ОС браузера [browserOs] (`ClientMeta.platform`): на Windows — ключ входа или гейт ([DemoPasskeyMode.gate]),
/// иначе — привязка; правило то же, что у платформы устройства для сервера ([browserDevicePlatform]).
DemoPasskeyMode demoPasskeyModeFor(ClientPlatform? browserOs) =>
    browserDevicePlatform(browserOs) == ClientPlatform.windows ? DemoPasskeyMode.gate : DemoPasskeyMode.bound;

/// Порт биометрии веб-демо поверх шлюза страницы [DemoPasskeyGateway]. Ключ входа ([BiometricHelloKey],
/// [BrowserHelloKey]) — только в режиме [DemoPasskeyMode.gate]; в режиме привязки его методы отвечают «недоступно» без
/// вызова страницы.
final class WebPasskeyAuthenticator
    implements BiometricAuthenticator, BiometricSecretReplacer, BiometricHelloKey, BrowserHelloKey {
  /// [owner] — `userId` пользователя записи (кэш профиля); [quickTimeout] — предел вызовов без диалога
  /// (`capability`, `has`, `clear`): зависшая страница не задерживает вход по SMS и SCR-08.
  WebPasskeyAuthenticator({
    required DemoPasskeyGateway gateway,
    required this.mode,
    required Future<String?> Function() owner,
    Duration quickTimeout = const Duration(seconds: 3),
  }) : _gateway = gateway,
       _owner = owner,
       _quickTimeout = quickTimeout;

  final DemoPasskeyGateway _gateway;
  final Future<String?> Function() _owner;
  final Duration _quickTimeout;

  final DemoPasskeyMode mode;

  bool _mismatchLogged = false;

  bool get _bound => mode == DemoPasskeyMode.bound;

  /// Шлюз есть и говорит протоколом [demoPasskeyProtocol]; иначе биометрии нет, страница не вызывается.
  bool get _ready {
    if (!_gateway.isAvailable) return false;
    final int? protocol = _gateway.protocol;
    if (protocol == demoPasskeyProtocol) return true;
    if (!_mismatchLogged) {
      _mismatchLogged = true;
      _log.warning(demoPasskeyProtocolMismatch(protocol));
    }
    return false;
  }

  static const BiometricResult<void> _notAvailable = BiometricResult<void>.failure(BiometricError.notAvailable);

  @override
  Future<BiometricCapability> capability() async {
    if (!_gateway.isAvailable) return _unsupported('no_gateway');
    if (!_ready) return _unsupported('protocol');
    final Map<String, Object?> raw = await _quick(DemoPasskeyMethod.capability, <String, Object?>{'mode': mode.wire});
    final Object? reason = raw['reason'];
    final BiometricKind kind = switch (raw['kind']) {
      'android_class3' when _bound => BiometricKind.androidClass3,
      'windows_hello' when !_bound => BiometricKind.windowsHello,
      _ => BiometricKind.none,
    };
    if (kind == BiometricKind.none) return _unsupported(reason is String ? reason : 'platform');
    return BiometricCapability(
      kind: kind,
      availability: switch (raw['availability']) {
        'available' => BiometricAvailability.available,
        'not_enrolled' => BiometricAvailability.notEnrolled,
        'locked_out' => BiometricAvailability.lockedOut,
        _ => BiometricAvailability.unsupported,
      },
      // Гейт ничего не открывает (как Windows Hello W1), что бы ни ответила страница.
      cryptoBinding: _bound && raw['cryptoBinding'] == true,
      reason: reason is String ? reason : null,
    );
  }

  /// Привязка: create() с PRF и запись [secret] под ключом из PRF (включение в SCR-42 и SCR-04). Пользователь
  /// неизвестен — `failed` без диалога; без PRF — `not_available` (вариант скрывается).
  @override
  Future<BiometricResult<void>> store(String secret, BiometricPromptText prompt) async {
    if (!_bound || !_ready) return _notAvailable;
    final String? owner = await _ownerId();
    if (owner == null) return const BiometricResult<void>.failure(BiometricError.failed);
    return _voidResult(
      await _gateway.invoke(DemoPasskeyMethod.store, <String, Object?>{'secret': secret, 'owner': owner}),
    );
  }

  /// Привязка: тот же ключ — без диалога не позже 60 с после [read], иначе get() (02 SCR-08.4 п. 3).
  @override
  Future<BiometricResult<void>> replace(String secret, BiometricPromptText prompt) async {
    if (!_bound || !_ready) return _notAvailable;
    final String? owner = await _ownerId();
    if (owner == null) return const BiometricResult<void>.failure(BiometricError.noCredential);
    return _voidResult(
      await _gateway.invoke(DemoPasskeyMethod.replace, <String, Object?>{'secret': secret, 'owner': owner}),
    );
  }

  /// Привязка: один диалог get() → секрет этого пользователя. Чужая запись — `invalidated` без диалога (страница её не
  /// удаляет); нет выхода PRF или блоб не открывается — запись удалена, `invalidated`.
  @override
  Future<BiometricResult<String>> read(BiometricPromptText prompt) async {
    if (!_bound || !_ready) return const BiometricResult<String>.failure(BiometricError.notAvailable);
    final String? owner = await _ownerId();
    if (owner == null) return const BiometricResult<String>.failure(BiometricError.noCredential);
    final Map<String, Object?> raw = await _gateway.invoke(DemoPasskeyMethod.read, <String, Object?>{'owner': owner});
    final Object? value = raw['value'];
    if (raw['ok'] == true && value is String && value.isNotEmpty) return BiometricResult<String>.success(value);
    return BiometricResult<String>.failure(
      raw['ok'] == true ? BiometricError.failed : BiometricCryptoChannel.parseError(raw['error']),
    );
  }

  /// Привязка: есть запись этого пользователя (без диалога).
  @override
  Future<bool> hasStoredSecret() async {
    if (!_bound || !_ready) return false;
    final String? owner = await _ownerId();
    if (owner == null) return false;
    final Map<String, Object?> raw = await _quick(DemoPasskeyMethod.has, <String, Object?>{'owner': owner});
    return raw['ok'] == true && raw['value'] == true;
  }

  /// Хук очистки сессии и выключения (logout, `SESSION_REVOKED`, подключение планшета): страница удаляет только блоб
  /// привязки и ключ в памяти; passkey браузера и запись гейта остаются (ADR-116 п. 1).
  @override
  Future<void> clear() async {
    if (!_ready) return;
    await _quick(DemoPasskeyMethod.clear, <String, Object?>{'mode': mode.wire});
  }

  /// Гейт: get() с проверкой пользователя (первый раз — create()). Результат не открывает сессию и не заменяет PIN
  /// (09 §9.2). В режиме привязки гейта нет — как у канала криптопривязки.
  @override
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) async {
    if (_bound || !_ready) return _notAvailable;
    return _voidResult(await _gateway.invoke(DemoPasskeyMethod.confirmPresence));
  }

  static const BiometricResult<String> _keyNotAvailable = BiometricResult<String>.failure(BiometricError.notAvailable);
  static const BiometricResult<String> _keyFailed = BiometricResult<String>.failure(BiometricError.failed);

  /// Ключ входа (09 BIO-041): источник ключа для `POST /me/biometrics` — `webauthn_prf`.
  @override
  HelloKeySource get helloKeySource => HelloKeySource.webauthnPrf;

  /// Ключ входа: доступность и поддержка ключа — `capability({mode: 'gate'})` без диалога (`availability`,
  /// `keysSupported`: PRF не исключён клиентом браузера и признаком «PRF нет»). Режим привязки, шлюза нет, вида нет или
  /// страница не ответила — [WindowsHelloStatus.unknown]: SCR-42 решает по [capability], режим гейта.
  @override
  Future<WindowsHelloStatus> helloStatus() async {
    if (_bound || !_ready) return WindowsHelloStatus.unknown;
    final Map<String, Object?> raw = await _quick(DemoPasskeyMethod.capability, <String, Object?>{'mode': mode.wire});
    if (raw['kind'] != 'windows_hello' || raw['availability'] != 'available') return WindowsHelloStatus.unknown;
    return WindowsHelloStatus(
      availability: WindowsHelloAvailability.available,
      keysSupported: raw['keysSupported'] == true,
    );
  }

  /// Ключ входа: `createKey({owner})` — один диалог WebAuthn (первый раз create(), иначе get() тем же passkey); успех —
  /// SPKI (base64url без `=`) и `RS256`. `reason: no_prf` — [BrowserHelloKeyCreation.noPrf] (`gate` страницы — passkey
  /// остался ключом гейта). Пользователь неизвестен — `failed` без вызова страницы.
  @override
  Future<BrowserHelloKeyCreation> createBrowserHelloKey(String userId) async {
    if (_bound || !_ready) return const BrowserHelloKeyCreation(_keyNotAvailable);
    final String? owner = _keyOwner(userId);
    if (owner == null) return const BrowserHelloKeyCreation(_keyFailed);
    final Map<String, Object?> raw = await _gateway.invoke(DemoPasskeyMethod.createKey, <String, Object?>{
      'owner': owner,
    });
    final Object? value = raw['value'];
    if (raw['ok'] == true) {
      return value is String && value.isNotEmpty && raw['algorithm'] == 'RS256'
          ? BrowserHelloKeyCreation(BiometricResult<String>.success(value))
          : const BrowserHelloKeyCreation(_keyFailed);
    }
    if (raw['reason'] == 'no_prf') {
      return BrowserHelloKeyCreation(_keyNotAvailable, noPrf: true, gate: raw['gate'] == true);
    }
    return BrowserHelloKeyCreation(BiometricResult<String>.failure(BiometricCryptoChannel.parseError(raw['error'])));
  }

  @override
  Future<BiometricResult<String>> createHelloKey(String userId) async => (await createBrowserHelloKey(userId)).key;

  /// Ключ входа: `sign({owner, challenge})` — один диалог get(), подпись RSASSA-PKCS1-v1_5 / SHA-256 (base64url без `=`)
  /// для `POST /auth/unlock {method: hello_key}`. Ключа нет или он не открывается (нет выхода PRF) — `no_credential`
  /// («ключ пропал», PIN с `helloKeyInvalidated`); удалённый в ОС passkey — `cancelled` (09 §9.4). Строка не challenge
  /// входа или пользователь неизвестен — `failed` без вызова страницы.
  @override
  Future<BiometricResult<String>> signHelloChallenge(String userId, String challenge) async {
    if (_bound || !_ready) return _keyNotAvailable;
    final String? owner = _keyOwner(userId);
    if (owner == null || !challenge.startsWith(helloChallengePrefix)) return _keyFailed;
    final Map<String, Object?> raw = await _gateway.invoke(DemoPasskeyMethod.sign, <String, Object?>{
      'owner': owner,
      'challenge': challenge,
    });
    final Object? value = raw['value'];
    if (raw['ok'] == true && value is String && value.isNotEmpty) return BiometricResult<String>.success(value);
    return raw['ok'] == true
        ? _keyFailed
        : BiometricResult<String>.failure(BiometricCryptoChannel.parseError(raw['error']));
  }

  /// Ключ входа: `deleteKey({owner})` без диалога; `false` — ключа не было или страница не ответила.
  @override
  Future<bool> deleteHelloKey(String userId) async {
    if (_bound || !_ready) return false;
    final String? owner = _keyOwner(userId);
    if (owner == null) return false;
    final Map<String, Object?> raw = await _quick(DemoPasskeyMethod.deleteKey, <String, Object?>{'owner': owner});
    return raw['ok'] == true && raw['value'] == true;
  }

  static String? _keyOwner(String userId) {
    final String id = userId.trim();
    return id.isEmpty ? null : id;
  }

  Future<String?> _ownerId() async {
    try {
      final String? id = (await _owner())?.trim();
      return id == null || id.isEmpty ? null : id;
    } on Object {
      return null;
    }
  }

  /// Вызов без диалога с пределом [_quickTimeout]; не дождались — `failed`.
  Future<Map<String, Object?>> _quick(String method, Map<String, Object?> args) =>
      _gateway.invoke(method, args).timeout(_quickTimeout, onTimeout: () => demoPasskeyFailed);

  static BiometricResult<void> _voidResult(Map<String, Object?> raw) => raw['ok'] == true
      ? const BiometricResult<void>.success(null)
      : BiometricResult<void>.failure(BiometricCryptoChannel.parseError(raw['error']));

  static BiometricCapability _unsupported(String reason) => BiometricCapability(
    kind: BiometricKind.none,
    availability: BiometricAvailability.unsupported,
    cryptoBinding: false,
    reason: reason,
  );

  @override
  String toString() => 'WebPasskeyAuthenticator(${mode.name})';
}
