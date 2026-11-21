// Фейковый шлюз passkey веб-демо для VM-тестов (12 T-DEMO-016; 15 ADR-116 п. 1, п. 4). Повторяет протокол 1
// demo/web/site-src/demo-passkey.js: привязка, гейт и ключ входа браузера на Windows (пакет LF-3-06: `createKey`,
// `sign`, `deleteKey`, `hasKey`): ответы — простые словари, исключений нет; чужая запись не открывается без диалога;
// без PRF вариант привязки скрыт, ключ входа не создаётся — passkey остаётся ключом гейта (`reason: no_prf`, `gate`);
// после `read` ключ «в памяти» и `replace` идёт без диалога; `clear` удаляет только блоб привязки (ключи входа и гейт
// остаются). Диалоги WebAuthn (create/get) считаются в [FakeDemoPasskeyGateway.dialogs]; исход следующего диалога
// задаёт [dialogErrors]. Владелец хранится строчными (страница хранит отпечаток SHA-256 — это проверяет T-DEMO-015).
// Открытый ключ и подпись — синтетические метки, не криптография (её проверяет T-DEMO-015). Синтетические данные.
import 'dart:async';

import 'package:optomstroy/app/demo/demo_passkey_gateway.dart';

/// Вызов шлюза: метод и аргументы (копия).
typedef FakePasskeyCall = ({String method, Map<String, Object?> args});

final class FakeDemoPasskeyGateway implements DemoPasskeyGateway {
  FakeDemoPasskeyGateway({
    this.isAvailable = true,
    this.protocol = demoPasskeyProtocol,
    this.platformAuthenticator = true,
    this.clientPrf = 'yes',
    this.prfAtCreate = true,
    this.prfAtGet = true,
  });

  @override
  bool isAvailable;

  @override
  int? protocol;

  /// `isUserVerifyingPlatformAuthenticatorAvailable()`.
  bool platformAuthenticator;

  /// `getClientCapabilities()['extension:prf']`: `yes` | `no` | `unknown`.
  String clientPrf;

  /// Passkey создаётся с PRF (`prf.enabled === true`); иначе страница ставит маркер «без PRF».
  bool prfAtCreate;

  /// get() даёт выход PRF; иначе блоб удаляется (`invalidated`).
  bool prfAtGet;

  /// Маркер страницы `passkeyNoPrf`.
  bool noPrf = false;

  /// Блоб привязки (`passkeyBound`).
  ({String owner, String secret})? bound;

  /// Запись гейта (`passkeyGate`).
  bool gate = false;

  /// Ключ AES после `read` (не дольше 60 с): `replace` без диалога.
  bool keyInMemory = false;

  /// Ключи входа браузера на Windows (`passkeyHelloKey`): владелец (строчными) → номер ключа.
  final Map<String, int> helloKeys = <String, int>{};
  int _keySerial = 0;

  /// Синтетический открытый ключ номер [n] (метка, не SPKI).
  static String publicKeyOf(int n) => 'spki-test-$n';

  /// Синтетическая подпись ключом номер [n] над [challenge] (метка, не RSA).
  static String signatureOf(int n, String challenge) => 'sig-test-$n-${challenge.length}';

  /// Префикс challenge входа (08 §4.1.10) — как `CHALLENGE_PREFIX` страницы.
  static const String challengePrefix = 'optomstroy-hello-unlock/v1:';

  final List<FakePasskeyCall> calls = <FakePasskeyCall>[];

  /// Системные диалоги WebAuthn: `create` | `get`.
  final List<String> dialogs = <String>[];

  /// Коды исхода следующих диалогов (`cancelled`, `failed`, …) по очереди.
  final List<String> dialogErrors = <String>[];

  /// Свой ответ на вызов (вместо поведения страницы); `null` — поведение страницы.
  Map<String, Object?>? Function(String method, Map<String, Object?> args)? respond;

  /// Ответы ждут этого (зависшая страница).
  Completer<void>? hold;

  Iterable<String> get methods => calls.map((FakePasskeyCall c) => c.method);

  /// Прошло больше 60 с после `read`.
  void expireKey() => keyInMemory = false;

  @override
  Future<Map<String, Object?>> invoke(String method, [Map<String, Object?> args = const <String, Object?>{}]) async {
    calls.add((method: method, args: Map<String, Object?>.of(args)));
    final Completer<void>? wait = hold;
    if (wait != null) await wait.future;
    final Map<String, Object?>? scripted = respond?.call(method, args);
    if (scripted != null) return scripted;
    if (!isAvailable || !DemoPasskeyMethod.all.contains(method)) return demoPasskeyNotAvailable;
    final Object? owner = args['owner'];
    final Object? secret = args['secret'];
    return switch (method) {
      DemoPasskeyMethod.capability => _capability(args['mode']),
      DemoPasskeyMethod.store => _store(owner, secret),
      DemoPasskeyMethod.read => _read(owner),
      DemoPasskeyMethod.replace => _replace(owner, secret),
      DemoPasskeyMethod.has => <String, Object?>{'ok': true, 'value': bound != null && bound!.owner == owner},
      DemoPasskeyMethod.clear => _clear(),
      DemoPasskeyMethod.confirmPresence => _confirmPresence(),
      DemoPasskeyMethod.createKey => _createKey(owner),
      DemoPasskeyMethod.sign => _sign(owner, args['challenge']),
      DemoPasskeyMethod.deleteKey => _keyFlag(owner, remove: true),
      DemoPasskeyMethod.hasKey => _keyFlag(owner, remove: false),
      _ => demoPasskeyNotAvailable,
    };
  }

  static String? _tag(Object? owner) {
    if (owner is! String) return null;
    final String o = owner.trim().toLowerCase();
    return o.isEmpty ? null : o;
  }

  /// `createKey`: passkey гейта есть — get() тем же passkey; иначе create() (запись гейта). Без PRF — маркер,
  /// `not_available` + `reason: no_prf` + `gate`; признак уже стоит — без диалога.
  Map<String, Object?> _createKey(Object? owner) {
    final String? tag = _tag(owner);
    if (tag == null) return _fail('failed');
    if (noPrf) return <String, Object?>{..._fail('not_available', 'no_prf'), 'gate': gate};
    if (gate) {
      final String? error = _dialog('get');
      if (error != null) return _fail(error);
      if (!prfAtGet) return _noPrfKey();
    } else {
      final String? error = _dialog('create');
      if (error != null) return _fail(error);
      gate = true;
      if (!prfAtCreate) return _noPrfKey();
    }
    final int n = ++_keySerial;
    helloKeys[tag] = n;
    return <String, Object?>{'ok': true, 'value': publicKeyOf(n), 'algorithm': 'RS256', 'source': 'webauthn_prf'};
  }

  Map<String, Object?> _noPrfKey() {
    noPrf = true;
    return <String, Object?>{..._fail('not_available', 'no_prf'), 'gate': true};
  }

  /// `sign`: только challenge входа; ключа нет — `no_credential` без диалога; нет выхода PRF — ключ удалён,
  /// `no_credential`.
  Map<String, Object?> _sign(Object? owner, Object? challenge) {
    if (challenge is! String || !challenge.startsWith(challengePrefix) || challenge.length == challengePrefix.length) {
      return _fail('failed');
    }
    final String? tag = _tag(owner);
    if (tag == null) return _fail('no_credential');
    final int? n = helloKeys[tag];
    if (n == null) return _fail('no_credential');
    final String? error = _dialog('get');
    if (error != null) return _fail(error);
    if (!prfAtGet) {
      helloKeys.remove(tag);
      return _fail('no_credential');
    }
    return <String, Object?>{'ok': true, 'value': signatureOf(n, challenge)};
  }

  Map<String, Object?> _keyFlag(Object? owner, {required bool remove}) {
    final String? tag = _tag(owner);
    if (tag == null) return <String, Object?>{'ok': true, 'value': false};
    final bool had = remove ? helloKeys.remove(tag) != null : helloKeys.containsKey(tag);
    return <String, Object?>{'ok': true, 'value': had};
  }

  static Map<String, Object?> _fail(String error, [String? reason]) => <String, Object?>{
    'ok': false,
    'error': error,
    'reason': ?reason,
  };

  static Map<String, Object?> _unsupported(String reason) => <String, Object?>{
    'kind': 'none',
    'availability': 'unsupported',
    'cryptoBinding': false,
    'reason': reason,
    'keysSupported': false,
    'prf': 'no',
  };

  String? _dialog(String kind) {
    dialogs.add(kind);
    return dialogErrors.isEmpty ? null : dialogErrors.removeAt(0);
  }

  Map<String, Object?> _capability(Object? mode) {
    if (mode != 'bound' && mode != 'gate') return _unsupported('mode');
    if (!platformAuthenticator) return _unsupported('no_platform_authenticator');
    final String prf = noPrf ? 'no' : clientPrf;
    if (mode == 'bound') {
      if (prf == 'no') return _unsupported('no_prf');
      return <String, Object?>{
        'kind': 'android_class3',
        'availability': 'available',
        'cryptoBinding': true,
        'keysSupported': false,
        'prf': prf,
      };
    }
    return <String, Object?>{
      'kind': 'windows_hello',
      'availability': 'available',
      'cryptoBinding': false,
      'reason': 'no_crypto_binding_on_platform',
      'keysSupported': prf != 'no',
      'prf': prf,
    };
  }

  Map<String, Object?> _store(Object? owner, Object? secret) {
    if (secret is! String || secret.isEmpty) return _fail('failed');
    if (owner is! String || owner.isEmpty) return _fail('failed');
    if (noPrf) return _fail('not_available', 'no_prf');
    final String? error = _dialog('create');
    if (error != null) return _fail(error);
    // Новый passkey с тем же user.id заменил прежний: прежний блоб не открыть.
    bound = null;
    keyInMemory = false;
    if (!prfAtCreate) {
      noPrf = true;
      return _fail('not_available', 'no_prf');
    }
    bound = (owner: owner, secret: secret);
    return <String, Object?>{'ok': true};
  }

  Map<String, Object?> _read(Object? owner) {
    if (owner is! String || owner.isEmpty) return _fail('no_credential');
    final ({String owner, String secret})? blob = bound;
    if (blob == null) return _fail('no_credential');
    if (blob.owner != owner) return _fail('invalidated');
    final String? error = _dialog('get');
    if (error != null) return _fail(error);
    if (!prfAtGet) {
      bound = null;
      keyInMemory = false;
      return _fail('invalidated');
    }
    keyInMemory = true;
    return <String, Object?>{'ok': true, 'value': blob.secret};
  }

  Map<String, Object?> _replace(Object? owner, Object? secret) {
    if (secret is! String || secret.isEmpty) return _fail('failed');
    final ({String owner, String secret})? blob = bound;
    if (blob == null || blob.owner != owner) return _fail('no_credential');
    if (!keyInMemory) {
      final String? error = _dialog('get');
      if (error != null) return _fail(error);
      if (!prfAtGet) {
        bound = null;
        return _fail('invalidated');
      }
    }
    bound = (owner: blob.owner, secret: secret);
    return <String, Object?>{'ok': true};
  }

  Map<String, Object?> _clear() {
    bound = null;
    keyInMemory = false;
    return <String, Object?>{'ok': true};
  }

  Map<String, Object?> _confirmPresence() {
    if (gate) {
      final String? error = _dialog('get');
      return error == null ? <String, Object?>{'ok': true} : _fail(error);
    }
    final String? error = _dialog('create');
    if (error != null) return _fail(error);
    gate = true;
    noPrf = !prfAtCreate;
    return <String, Object?>{'ok': true};
  }
}
