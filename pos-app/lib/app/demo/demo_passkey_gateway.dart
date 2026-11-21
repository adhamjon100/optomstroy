// Шлюз веб-демо ко входу по лицу или отпечатку через passkey (WebAuthn) — `globalThis.__posPasskey` страницы
// (demo/web/site-src/demo-passkey.js, протокол 1; 15 ADR-116 п. 1, п. 4; 09 §9.2 «Веб-демо», BIO-035, BIO-041; 06 §6.10).
// Только демо-сборка (ADR-113, DM-01): продукт web биометрии не имеет (`NoBiometricAuthenticator`).
//
// Протокол — словари, как у канала криптопривязки (core/biometrics/biometric_crypto_channel.dart): каждый метод страницы
// возвращает Promise простого объекта и не бросает исключений; ошибки — коды `cancelled | invalidated | not_available |
// no_credential | failed`. Шлюз только передаёт вызов и ответ, смысл ответа разбирает `WebPasskeyAuthenticator`
// (demo_passkey.dart).
//
// Реализация выбирается условным импортом: в браузере — `dart:js_interop` (demo_passkey_web.dart), на VM и в тестах —
// заглушка без страницы (demo_passkey_stub.dart). Здесь и в обеих реализациях нет Flutter: шлюз браузера можно
// проверить вне приложения (dart2js + страница в Node).
import 'package:optomstroy/app/demo/demo_passkey_stub.dart'
    if (dart.library.js_interop) 'package:optomstroy/app/demo/demo_passkey_web.dart'
    as platform;

/// Версия протокола `__posPasskey.protocol`, которую понимает приложение.
const int demoPasskeyProtocol = 1;

/// Метка протокола в собранном `main.dart.js`: по ней `check-site` сверяет номер протокола приложения со страницей
/// (12 T-DEMO-020). Строка попадает в сборку — её использует [demoPasskeyProtocolMismatch].
const String demoPasskeyProtocolTag =
    '__posPasskey.protocol=$demoPasskeyProtocol'; // check-secrets: allow — метка протокола

/// Текст журнала, если страница дала другой протокол (без значений пользователя).
String demoPasskeyProtocolMismatch(int? page) =>
    'вход по passkey выключен: приложение ждёт $demoPasskeyProtocolTag, '
    'страница даёт ${page ?? 'нет шлюза'}';

/// Методы протокола 1 (demo-passkey.js). Шлюз вызывает только их.
abstract final class DemoPasskeyMethod {
  /// `{mode}` → `{kind, availability, cryptoBinding, reason?, keysSupported, prf}`; без диалога.
  static const String capability = 'capability';

  /// Привязка: `{secret, owner}` → `{ok}`; диалог create() (иногда ещё get()).
  static const String store = 'store';

  /// Привязка: `{owner}` → `{ok, value}`; один диалог get().
  static const String read = 'read';

  /// Привязка: `{secret, owner}` → `{ok}`; не позже 60 с после [read] — без диалога.
  static const String replace = 'replace';

  /// Привязка: `{owner}` → `{ok: true, value: bool}`; без диалога.
  static const String has = 'has';

  /// Хук очистки сессии: `{mode}` → `{ok: true}`; удаляет только блоб привязки, без диалога.
  static const String clear = 'clear';

  /// Гейт: `{}` → `{ok}`; диалог get(), первый раз create().
  static const String confirmPresence = 'confirmPresence';

  /// Ключ входа браузера на Windows (пакет LF-3-06): `{owner}` → `{ok, value: SPKI, algorithm, source}`.
  static const String createKey = 'createKey';

  /// Ключ входа браузера на Windows (LF-3-06): `{owner, challenge}` → `{ok, value: подпись}`.
  static const String sign = 'sign';

  /// Ключ входа браузера на Windows (LF-3-06): `{owner}` → `{ok: true, value: bool}`; без диалога.
  static const String deleteKey = 'deleteKey';

  /// Ключ входа браузера на Windows (LF-3-06): `{owner}` → `{ok: true, value: bool}`; без диалога.
  static const String hasKey = 'hasKey';

  static const Set<String> all = <String>{
    capability,
    store,
    read,
    replace,
    has,
    clear,
    confirmPresence,
    createKey,
    sign,
    deleteKey,
    hasKey,
  };
}

/// Ответ «шлюза нет / метод неизвестен» (`not_available`).
const Map<String, Object?> demoPasskeyNotAvailable = <String, Object?>{'ok': false, 'error': 'not_available'};

/// Ответ «вызов не удался» (`failed`): страница бросила исключение, отклонила промис или вернула не объект.
const Map<String, Object?> demoPasskeyFailed = <String, Object?>{'ok': false, 'error': 'failed'};

/// Шлюз страницы `globalThis.__posPasskey`.
abstract interface class DemoPasskeyGateway {
  /// Есть `globalThis.__posPasskey`.
  bool get isAvailable;

  /// `__posPasskey.protocol`; `null` — шлюза нет или номер не число.
  int? get protocol;

  /// Вызвать метод [method] ([DemoPasskeyMethod]) с аргументами [args] — ответ страницы простым словарём. Исключений
  /// нет: шлюза или метода нет → [demoPasskeyNotAvailable]; сбой вызова → [demoPasskeyFailed]. Секреты в аргументах и
  /// ответе не журналируются.
  Future<Map<String, Object?>> invoke(String method, [Map<String, Object?> args = const <String, Object?>{}]);
}

/// Шлюз этой платформы: в браузере — `globalThis.__posPasskey`, на VM — заглушка без страницы.
DemoPasskeyGateway createDemoPasskeyGateway() => platform.createPlatformDemoPasskeyGateway();
