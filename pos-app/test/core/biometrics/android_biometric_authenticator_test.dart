// T-BIO-019 (12 §3.24; 09 BIO-026, BIO-030, BIO-033, AC-AUTH-090; 11 SEC-090; 15 ADR-116 п. 2): композит Android
// `AndroidBiometricAuthenticator` — уровень S через подменный канал `kg.optomstroy/biometric_crypto` (протокол v1, как
// Kotlin `BiometricCryptoChannel.kt`), уровень W через подменные шлюз `LocalAuthGateway`, `SecureStorage` и
// `AndroidEnvProbe`. Натив Android не меняется (T-BIO-027 — test/build/android_build_config_test.dart).
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:optomstroy/core/biometrics/android_biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/android_env_probe.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/biometric_crypto_channel.dart';
import 'package:optomstroy/core/biometrics/biometric_providers.dart';
import 'package:optomstroy/core/biometrics/windows_hello_gate.dart';
import 'package:optomstroy/core/biometrics/windows_hello_key.dart';
import 'package:optomstroy/core/biometrics/windows_hello_key_authenticator.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';

import '../storage/in_memory_secure_storage.dart';

/// Журнал событий подмен (порядок: хранилище, шлюз, канал).
final List<String> _events = <String>[];

/// Подмена Kotlin-стороны канала v1: ключ «есть/нет», секрет, ответ `capability`.
final class _NativeChannel {
  Map<String, Object?> capability = <String, Object?>{
    'kind': 'android_class3',
    'availability': 'available',
    'cryptoBinding': true,
  };
  String? sealed;
  String storeError = '';
  final List<MethodCall> calls = <MethodCall>[];

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    _events.add('channel.${call.method}');
    final Map<Object?, Object?> args = (call.arguments as Map<Object?, Object?>?) ?? const <Object?, Object?>{};
    switch (call.method) {
      case 'capability':
        return capability;
      case 'store':
        sealed = null; // Kotlin: clearAll() до диалога.
        if (storeError.isNotEmpty) return <String, Object?>{'ok': false, 'error': storeError};
        sealed = args['secret'] as String?;
        return <String, Object?>{'ok': true};
      case 'replace':
        if (sealed == null) return <String, Object?>{'ok': false, 'error': 'no_credential'};
        sealed = args['secret'] as String?;
        return <String, Object?>{'ok': true};
      case 'read':
        final String? value = sealed;
        return value == null
            ? <String, Object?>{'ok': false, 'error': 'no_credential'}
            : <String, Object?>{'ok': true, 'value': value};
      case 'has':
        return sealed != null;
      case 'clear':
        sealed = null;
        return null;
    }
    return null;
  }

  List<String> get methods => <String>[for (final MethodCall c in calls) c.method];
}

/// Подменный шлюз `local_auth`.
final class _Gateway implements LocalAuthGateway {
  List<BiometricType> enrolled = <BiometricType>[BiometricType.weak, BiometricType.strong];
  bool hardware = true;
  bool deviceSupported = true;
  bool result = true;
  LocalAuthException? error;
  Exception? availabilityError;
  final List<({String reason, bool biometricOnly, bool sensitiveTransaction, BiometricPromptText? texts})> dialogs =
      <({String reason, bool biometricOnly, bool sensitiveTransaction, BiometricPromptText? texts})>[];

  @override
  Future<List<BiometricType>> availableBiometrics() async {
    _events.add('local_auth.availableBiometrics');
    if (availabilityError != null) throw availabilityError!;
    return enrolled;
  }

  @override
  Future<bool> canCheckBiometrics() async => hardware;

  @override
  Future<bool> isDeviceSupported() async => deviceSupported;

  @override
  Future<bool> authenticate(
    String reason, {
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    BiometricPromptText? texts,
  }) async {
    _events.add('local_auth.authenticate');
    dialogs.add((
      reason: reason,
      biometricOnly: biometricOnly,
      sensitiveTransaction: sensitiveTransaction,
      texts: texts,
    ));
    if (error != null) throw error!;
    return result;
  }
}

/// Подменный порт окружения.
final class _Env implements AndroidEnvProbe {
  AndroidEnv env = const AndroidEnv(sdkInt: 34, isPhysicalDevice: true, isReleaseBuild: true);
  Exception? error;

  @override
  Future<AndroidEnv> read() async {
    if (error != null) throw error!;
    return env;
  }
}

/// Хранилище с журналом операций.
final class _Storage implements SecureStorage {
  final Map<SecureKey, String> values = <SecureKey, String>{};

  @override
  Future<String?> read(SecureKey key) async {
    _events.add('storage.read ${key.storageKey}');
    return values[key];
  }

  @override
  Future<void> write(SecureKey key, String value) async {
    _events.add('storage.write ${key.storageKey}');
    values[key] = value;
  }

  @override
  Future<void> delete(SecureKey key) async {
    _events.add('storage.delete ${key.storageKey}');
    values.remove(key);
  }
}

const BiometricPromptText _prompt = BiometricPromptText(title: 'Вход по лицу или отпечатку', cancel: 'Отмена');
const String _weakKey = 'auth.biometric_refresh_weak';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel(BiometricCryptoChannel.channelName);
  final TestDefaultBinaryMessenger messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late _NativeChannel native;
  late _Gateway gateway;
  late _Env env;
  late _Storage storage;

  AndroidBiometricAuthenticator make({bool prod = false}) =>
      AndroidBiometricAuthenticator(storage: storage, requireReleaseDevice: prod, localAuth: gateway, env: env);

  setUp(() {
    _events.clear();
    native = _NativeChannel();
    gateway = _Gateway();
    env = _Env();
    storage = _Storage();
    messenger.setMockMethodCallHandler(channel, native.handle);
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('T-BIO-019 (1): возможности уровней S и W', () {
    test('S и W (отпечаток Class 3 и лицо Class 2): вид class3, предлагается S (Q-354), W доступен', () async {
      final BiometricCapability c = await make().capability();
      expect(c.kind, BiometricKind.androidClass3);
      expect(c.supportsCryptoLogin, isTrue);
      expect(c.supportsWeakLogin, isTrue);
      expect(c.weakReason, isNull);
      expect(c.preferredTier, BiometricTier.strong);
      expect(c.kindFor(BiometricTier.weak).apiClass, 'class2');
      expect(c.storedTier, isNull);
      expect(native.methods, <String>[
        'capability',
        'has',
      ], reason: 'протокол v1: прежние методы; has — уровень сохранённого секрета без диалога');
      expect(gateway.dialogs, isEmpty, reason: 'возможности — без системного диалога');
    });

    test('только W (лицо Class 2, датчика Class 3 нет): вид class2, S недоступен', () async {
      native.capability = <String, Object?>{
        'kind': 'android_class3',
        'availability': 'unsupported',
        'cryptoBinding': true,
        'reason': 'no_hardware_or_weak_only',
      };
      gateway.enrolled = <BiometricType>[BiometricType.weak];
      final BiometricCapability c = await make().capability();
      expect(c.kind, BiometricKind.androidClass2);
      expect(c.kind.apiClass, 'class2');
      expect(c.availability, BiometricAvailability.unsupported);
      expect(c.reason, 'no_hardware_or_weak_only', reason: 'ответ канала — как есть');
      expect(c.supportsCryptoLogin, isFalse);
      expect(c.supportsWeakLogin, isTrue);
      expect(c.preferredTier, BiometricTier.weak);
    });

    test('отпечаток Class 3 не настроен, лицо Class 2 есть: вид class3 (датчик есть), предлагается W', () async {
      native.capability = <String, Object?>{
        'kind': 'android_class3',
        'availability': 'not_enrolled',
        'cryptoBinding': true,
        'reason': 'not_enrolled',
      };
      gateway.enrolled = <BiometricType>[BiometricType.weak];
      final BiometricCapability c = await make().capability();
      expect(c.kind, BiometricKind.androidClass3);
      expect(c.availability, BiometricAvailability.notEnrolled);
      expect(c.preferredTier, BiometricTier.weak);
    });

    test('только S: local_auth недоступен (нет Activity) — W unsupported, уровень S по каналу без изменений', () async {
      gateway.availabilityError = const LocalAuthException(code: LocalAuthExceptionCode.uiUnavailable);
      final BiometricCapability c = await make().capability();
      expect(c.kind, BiometricKind.androidClass3);
      expect(c.supportsCryptoLogin, isTrue);
      expect(c.weakAvailability, BiometricAvailability.unsupported);
      expect(c.weakReason, 'local_auth');
      expect(c.preferredTier, BiometricTier.strong);
    });

    test('API 29: уровня W нет (api_level), local_auth не опрашивается; канал — api_level', () async {
      native.capability = <String, Object?>{
        'kind': 'none',
        'availability': 'unsupported',
        'cryptoBinding': false,
        'reason': 'api_level',
      };
      env.env = const AndroidEnv(sdkInt: 29, isPhysicalDevice: true, isReleaseBuild: true);
      final BiometricCapability c = await make().capability();
      expect(c.kind, BiometricKind.none);
      expect(c.weakAvailability, BiometricAvailability.unsupported);
      expect(c.weakReason, 'api_level');
      expect(c.preferredTier, isNull);
      expect(_events, isNot(contains('local_auth.availableBiometrics')));
    });

    test('биометрии нет: датчик есть — notEnrolled (no_biometrics); датчика нет — unsupported (no_hardware)', () async {
      native.capability = <String, Object?>{
        'kind': 'android_class3',
        'availability': 'unsupported',
        'cryptoBinding': true,
        'reason': 'no_hardware_or_weak_only',
      };
      gateway.enrolled = <BiometricType>[];
      final BiometricCapability notEnrolled = await make().capability();
      expect(notEnrolled.weakAvailability, BiometricAvailability.notEnrolled);
      expect(notEnrolled.weakReason, 'no_biometrics');
      expect(notEnrolled.kind, BiometricKind.androidClass2, reason: 'датчик Class 2 есть, биометрия не настроена');
      expect(notEnrolled.preferredTier, isNull);

      gateway.hardware = false;
      final BiometricCapability none = await make().capability();
      expect(none.weakAvailability, BiometricAvailability.unsupported);
      expect(none.weakReason, 'no_hardware');
      expect(none.kind, BiometricKind.androidClass3, reason: 'ответ канала как есть (availability unsupported)');
      expect(none.preferredTier, isNull);
    });

    test('блокировка экрана не защищена (isDeviceSupported = false) — W unsupported (no_device_credential)', () async {
      gateway.deviceSupported = false;
      final BiometricCapability c = await make().capability();
      expect(c.weakAvailability, BiometricAvailability.unsupported);
      expect(c.weakReason, 'no_device_credential');
    });

    test('сбой порта окружения — W unsupported (platform), S по каналу', () async {
      env.error = MissingPluginException();
      final BiometricCapability c = await make().capability();
      expect(c.weakAvailability, BiometricAvailability.unsupported);
      expect(c.weakReason, 'platform');
      expect(c.supportsCryptoLogin, isTrue);
    });

    test('уровень сохранённого секрета без диалога: W — weak; ключ канала — strong; нет — null', () async {
      expect((await make().capability()).storedTier, isNull);
      native.sealed = 'strong-1';
      expect((await make().capability()).storedTier, BiometricTier.strong);
      native.sealed = null;
      storage.values[SecureKey.biometricRefreshWeak] = 'weak-1';
      expect((await make().capability()).storedTier, BiometricTier.weak);
      expect(gateway.dialogs, isEmpty);
    });

    test('kindOf — правило вида композита (документация BiometricCapability)', () {
      BiometricCapability s(String kind, BiometricAvailability a) => BiometricCapability(
        kind: kind == 'class3' ? BiometricKind.androidClass3 : BiometricKind.none,
        availability: a,
        cryptoBinding: kind == 'class3',
      );
      const BiometricAvailability av = BiometricAvailability.available;
      const BiometricAvailability un = BiometricAvailability.unsupported;
      const BiometricAvailability ne = BiometricAvailability.notEnrolled;
      expect(AndroidBiometricAuthenticator.kindOf(s('class3', av), un), BiometricKind.androidClass3);
      expect(AndroidBiometricAuthenticator.kindOf(s('class3', ne), av), BiometricKind.androidClass3);
      expect(AndroidBiometricAuthenticator.kindOf(s('class3', un), av), BiometricKind.androidClass2);
      expect(AndroidBiometricAuthenticator.kindOf(s('class3', un), ne), BiometricKind.androidClass2);
      expect(AndroidBiometricAuthenticator.kindOf(s('class3', un), un), BiometricKind.androidClass3);
      expect(AndroidBiometricAuthenticator.kindOf(s('none', un), av), BiometricKind.androidClass2);
      expect(AndroidBiometricAuthenticator.kindOf(s('none', un), un), BiometricKind.none);
    });
  });

  group('T-BIO-019 (2): уровень W — store → read → replace', () {
    test(
      'storeWeak: диалог local_auth biometricOnly, без подтверждения; секрет — auth.biometric_refresh_weak',
      () async {
        native.sealed = 'old-strong';
        final AndroidBiometricAuthenticator auth = make();
        expect(auth, isA<BiometricWeakStore>());
        expect(auth, isA<BiometricSecretReplacer>());

        final BiometricResult<void> r = await auth.storeWeak('weak-1', _prompt);
        expect(r.isSuccess, isTrue);
        expect(gateway.dialogs, hasLength(1));
        final dialog = gateway.dialogs.single;
        expect(dialog.biometricOnly, isTrue);
        expect(dialog.sensitiveTransaction, isFalse);
        expect(dialog.texts?.title, _prompt.title);
        expect(dialog.texts?.cancel, _prompt.cancel);
        expect(dialog.reason, isNotEmpty);
        expect(storage.values[SecureKey.biometricRefreshWeak], 'weak-1');
        expect(SecureKey.biometricRefreshWeak.storageKey, _weakKey);
        expect(native.sealed, isNull, reason: 'одна семья на устройство: ключ уровня S удалён');
        expect(native.methods, isNot(contains('store')), reason: 'уровень W мимо канала v1');
        expect((await auth.capability()).storedTier, BiometricTier.weak);
        expect(await auth.hasStoredSecret(), isTrue);
      },
    );

    test('read: проверка BIO-033 → диалог → секрет; значение отдаётся только после успеха диалога', () async {
      storage.values[SecureKey.biometricRefreshWeak] = 'weak-1';
      final AndroidBiometricAuthenticator auth = make();
      _events.clear();
      final BiometricResult<String> r = await auth.read(_prompt);
      expect(r.value, 'weak-1');
      expect(gateway.dialogs.single.biometricOnly, isTrue);
      expect(gateway.dialogs.single.sensitiveTransaction, isFalse);
      final int check = _events.indexOf('local_auth.availableBiometrics');
      final int dialog = _events.indexOf('local_auth.authenticate');
      expect(check, greaterThanOrEqualTo(0));
      expect(check, lessThan(dialog), reason: 'предпроверка до диалога');
      expect(_events.last, 'storage.read $_weakKey', reason: 'секрет читается после успеха диалога');
      expect(native.methods, isNot(contains('read')), reason: 'канал v1 не участвует');
      expect(r.toString(), isNot(contains('weak-1')));
    });

    test('read: отмена — cancelled, секрет не тронут, значение не отдаётся', () async {
      storage.values[SecureKey.biometricRefreshWeak] = 'weak-1';
      gateway.result = false;
      final BiometricResult<String> r = await make().read(_prompt);
      expect(r.error, BiometricError.cancelled);
      expect(r.value, isNull);
      expect(storage.values[SecureKey.biometricRefreshWeak], 'weak-1');
    });

    test('replace уровня W — запись без диалога (вызовов шлюза 0), канал не вызывается', () async {
      storage.values[SecureKey.biometricRefreshWeak] = 'weak-1';
      final AndroidBiometricAuthenticator auth = make();
      expect((await auth.read(_prompt)).value, 'weak-1');
      final int dialogs = gateway.dialogs.length;
      _events.clear();
      final BiometricResult<void> r = await auth.replace('weak-2', _prompt);
      expect(r.isSuccess, isTrue);
      expect(gateway.dialogs.length, dialogs, reason: 'перешифровка уровня W — без второго диалога');
      expect(_events.where((String e) => e.startsWith('local_auth.')), isEmpty);
      expect(native.methods, isNot(contains('replace')));
      expect(storage.values[SecureKey.biometricRefreshWeak], 'weak-2');
    });

    test('уровень S без изменений: store/read/replace — канал v1; секрет W удаляется при store S', () async {
      storage.values[SecureKey.biometricRefreshWeak] = 'weak-1';
      final AndroidBiometricAuthenticator auth = make();
      expect((await auth.store('strong-1', _prompt)).isSuccess, isTrue);
      expect(storage.values.containsKey(SecureKey.biometricRefreshWeak), isFalse);
      expect(native.sealed, 'strong-1');
      expect((await auth.capability()).storedTier, BiometricTier.strong);

      expect((await auth.read(_prompt)).value, 'strong-1');
      expect((await auth.replace('strong-2', _prompt)).isSuccess, isTrue);
      expect(native.sealed, 'strong-2');
      final MethodCall store = native.calls.firstWhere((MethodCall c) => c.method == 'store');
      expect(store.arguments, <String, Object?>{
        'secret': 'strong-1', // check-secrets: allow — тестовое значение
        'title': _prompt.title,
        'subtitle': null,
        'cancel': _prompt.cancel,
      });
      expect(native.methods.where((String m) => m == 'read' || m == 'replace'), <String>['read', 'replace']);
      expect(gateway.dialogs, isEmpty, reason: 'уровень S — диалог канала, не local_auth');
    });

    test('без секретов: read — no_credential канала, диалога local_auth нет', () async {
      final BiometricResult<String> r = await make().read(_prompt);
      expect(r.error, BiometricError.noCredential);
      expect(gateway.dialogs, isEmpty);
    });
  });

  group('T-BIO-019 (3): clear', () {
    test('очищены и ключ канала, и секрет W', () async {
      native.sealed = 'strong-1';
      storage.values[SecureKey.biometricRefreshWeak] = 'weak-1';
      final AndroidBiometricAuthenticator auth = make();
      await auth.clear();
      expect(native.methods, contains('clear'));
      expect(native.sealed, isNull);
      expect(storage.values.containsKey(SecureKey.biometricRefreshWeak), isFalse);
      expect(await auth.hasStoredSecret(), isFalse);
    });

    test('ключ W — в SecureKey.session: выход и SESSION_REVOKED его удаляют', () {
      expect(SecureKey.session, contains(SecureKey.biometricRefreshWeak));
      expect(SecureKey.kiosk, isNot(contains(SecureKey.biometricRefreshWeak)));
    });
  });

  group('T-BIO-019 (4): ошибки LocalAuthException — исходы порта без исключений', () {
    Future<BiometricResult<String>> readWith(LocalAuthExceptionCode code) async {
      storage.values[SecureKey.biometricRefreshWeak] = 'weak-1';
      gateway.error = LocalAuthException(code: code);
      return make().read(_prompt);
    }

    test('отмена (userCanceled, systemCanceled, timeout) — cancelled, секрет не тронут', () async {
      for (final LocalAuthExceptionCode code in <LocalAuthExceptionCode>[
        LocalAuthExceptionCode.userCanceled,
        LocalAuthExceptionCode.systemCanceled,
        LocalAuthExceptionCode.timeout,
      ]) {
        expect((await readWith(code)).error, BiometricError.cancelled, reason: code.name);
        expect(storage.values[SecureKey.biometricRefreshWeak], 'weak-1', reason: code.name);
      }
    });

    test('lockout (temporaryLockout, biometricLockout) — lockout, секрет не тронут', () async {
      for (final LocalAuthExceptionCode code in <LocalAuthExceptionCode>[
        LocalAuthExceptionCode.temporaryLockout,
        LocalAuthExceptionCode.biometricLockout,
      ]) {
        expect((await readWith(code)).error, BiometricError.lockout, reason: code.name);
        expect(storage.values[SecureKey.biometricRefreshWeak], 'weak-1', reason: code.name);
      }
    });

    test('биометрии нет в диалоге (noBiometricsEnrolled, noCredentialsSet) — секрет W удалён, invalidated', () async {
      for (final LocalAuthExceptionCode code in <LocalAuthExceptionCode>[
        LocalAuthExceptionCode.noBiometricsEnrolled,
        LocalAuthExceptionCode.noCredentialsSet,
      ]) {
        expect((await readWith(code)).error, BiometricError.invalidated, reason: code.name);
        expect(storage.values.containsKey(SecureKey.biometricRefreshWeak), isFalse, reason: code.name);
      }
    });

    test('иные коды (authInProgress, uiUnavailable, deviceError) — failed; storeWeak ничего не записывает', () async {
      for (final LocalAuthExceptionCode code in <LocalAuthExceptionCode>[
        LocalAuthExceptionCode.authInProgress,
        LocalAuthExceptionCode.uiUnavailable,
        LocalAuthExceptionCode.deviceError,
      ]) {
        expect((await readWith(code)).error, BiometricError.failed, reason: code.name);
      }
      storage.values.clear();
      gateway.error = const LocalAuthException(code: LocalAuthExceptionCode.userCanceled);
      expect((await make().storeWeak('weak-2', _prompt)).error, BiometricError.cancelled);
      gateway.error = const LocalAuthException(code: LocalAuthExceptionCode.biometricLockout);
      expect((await make().storeWeak('weak-2', _prompt)).error, BiometricError.lockout);
      gateway.error = const LocalAuthException(code: LocalAuthExceptionCode.noBiometricsEnrolled);
      expect((await make().storeWeak('weak-2', _prompt)).error, BiometricError.notEnrolled);
      expect(storage.values, isEmpty);
    });

    test('не LocalAuthException (PlatformException) — failed, без исключения', () async {
      storage.values[SecureKey.biometricRefreshWeak] = 'weak-1';
      final _ThrowingGateway throwing = _ThrowingGateway(gateway);
      final BiometricResult<String> r = await AndroidBiometricAuthenticator(
        storage: storage,
        requireReleaseDevice: false,
        localAuth: throwing,
        env: env,
      ).read(_prompt);
      expect(r.error, BiometricError.failed);
      expect(storage.values[SecureKey.biometricRefreshWeak], 'weak-1');
    });
  });

  group('T-BIO-019 (5): ENV=prod — эмулятор и debug-сборка (11 SEC-090, 09 BIO-026)', () {
    test('эмулятор — W unsupported (emulator); storeWeak — notAvailable без диалога; S по каналу', () async {
      env.env = const AndroidEnv(sdkInt: 34, isPhysicalDevice: false, isReleaseBuild: true);
      final AndroidBiometricAuthenticator auth = make(prod: true);
      final BiometricCapability c = await auth.capability();
      expect(c.weakAvailability, BiometricAvailability.unsupported);
      expect(c.weakReason, 'emulator');
      expect(c.supportsCryptoLogin, isTrue, reason: 'уровень S проверкой SEC-090 пока не ограничен (11 SEC-090)');
      expect((await auth.storeWeak('weak-1', _prompt)).error, BiometricError.notAvailable);
      expect(gateway.dialogs, isEmpty);
      expect(storage.values, isEmpty);
    });

    test('debug-сборка — W unsupported (debug_build)', () async {
      env.env = const AndroidEnv(sdkInt: 34, isPhysicalDevice: true, isReleaseBuild: false);
      final BiometricCapability c = await make(prod: true).capability();
      expect(c.weakAvailability, BiometricAvailability.unsupported);
      expect(c.weakReason, 'debug_build');
    });

    test('вне prod (dev, test) эмулятор и debug-сборка уровень W не закрывают', () async {
      env.env = const AndroidEnv(sdkInt: 34, isPhysicalDevice: false, isReleaseBuild: false);
      expect((await make().capability()).supportsWeakLogin, isTrue);
    });
  });

  group('T-BIO-019 (6): перед чтением W биометрии или блокировки экрана нет (BIO-033)', () {
    test('шлюз не видит биометрии — секрет W удалён, invalidated, диалога нет', () async {
      storage.values[SecureKey.biometricRefreshWeak] = 'weak-1';
      gateway.enrolled = <BiometricType>[];
      final BiometricResult<String> r = await make().read(_prompt);
      expect(r.error, BiometricError.invalidated);
      expect(storage.values.containsKey(SecureKey.biometricRefreshWeak), isFalse);
      expect(gateway.dialogs, isEmpty);
    });

    test('блокировка экрана не защищена — секрет W удалён, invalidated, диалога нет', () async {
      storage.values[SecureKey.biometricRefreshWeak] = 'weak-1';
      gateway.deviceSupported = false;
      final BiometricResult<String> r = await make().read(_prompt);
      expect(r.error, BiometricError.invalidated);
      expect(storage.values.containsKey(SecureKey.biometricRefreshWeak), isFalse);
      expect(gateway.dialogs, isEmpty);
    });

    test('сбой local_auth при проверке — failed, секрет сохранён (не путать с удалением биометрии)', () async {
      storage.values[SecureKey.biometricRefreshWeak] = 'weak-1';
      gateway.availabilityError = PlatformException(code: 'channel-error');
      final BiometricResult<String> r = await make().read(_prompt);
      expect(r.error, BiometricError.failed);
      expect(storage.values[SecureKey.biometricRefreshWeak], 'weak-1');
      expect(gateway.dialogs, isEmpty);
    });
  });

  group('T-BIO-019: провайдер и шлюз local_auth', () {
    test(
      'Android — композит с уровнем W; iOS — канал v1; Windows — гейт и ключ Windows Hello; web — без биометрии',
      () {
        final InMemorySecureStorage s = InMemorySecureStorage();
        final BiometricAuthenticator android = biometricAuthenticatorFor(
          TargetPlatform.android,
          storage: s,
          isProd: true,
          isWeb: false,
        );
        expect(android, isA<AndroidBiometricAuthenticator>());
        expect(android, isA<BiometricWeakStore>());
        expect(android, isA<BiometricSecretReplacer>());
        final BiometricAuthenticator ios = biometricAuthenticatorFor(
          TargetPlatform.iOS,
          storage: s,
          isProd: true,
          isWeb: false,
        );
        expect(ios, isA<BiometricCryptoChannel>());
        expect(ios, isNot(isA<BiometricWeakStore>()));
        final BiometricAuthenticator windows = biometricAuthenticatorFor(
          TargetPlatform.windows,
          storage: s,
          isProd: true,
          isWeb: false,
        );
        expect(windows, isA<WindowsHelloKeyAuthenticator>());
        expect(windows, isA<BiometricHelloKey>(), reason: 'ключ Windows Hello (W2, 15 ADR-116 п. 3)');
        expect(windows, isNot(isA<BiometricWeakStore>()));
        expect(
          biometricAuthenticatorFor(TargetPlatform.android, storage: s, isProd: true, isWeb: true),
          isA<NoBiometricAuthenticator>(),
        );
      },
    );

    test(
      'biometricAuthenticatorProvider на Android берёт secureStorageProvider; без плагинов — биометрии нет',
      () async {
        messenger.setMockMethodCallHandler(channel, null);
        final InMemorySecureStorage s = InMemorySecureStorage();
        final ProviderContainer container = ProviderContainer(overrides: [secureStorageProvider.overrideWithValue(s)]);
        addTearDown(container.dispose);
        final BiometricAuthenticator port = container.read(biometricAuthenticatorProvider);
        expect(port, isA<AndroidBiometricAuthenticator>(), reason: 'flutter test — defaultTargetPlatform android');
        final BiometricCapability c = await port.capability();
        expect(c.kind, BiometricKind.none, reason: 'как BiometricCryptoChannel без канала: поведение тестов прежнее');
        expect(c.supportsCryptoLogin, isFalse);
        expect(c.supportsWeakLogin, isFalse);
        expect(await port.hasStoredSecret(), isFalse);
      },
    );

    test('LocalAuthPackageGateway: уровень W — biometricOnly, без подтверждения, тексты Android', () async {
      const MethodChannel localAuth = MethodChannel('plugins.flutter.io/local_auth');
      final List<MethodCall> calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(localAuth, (MethodCall call) async {
        calls.add(call);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(localAuth, null));
      final LocalAuthPackageGateway g = LocalAuthPackageGateway();

      expect(
        await g.authenticate(
          'Вход по лицу или отпечатку',
          biometricOnly: true,
          sensitiveTransaction: false,
          texts: _prompt,
        ),
        isTrue,
      );
      final Map<Object?, Object?> weak = calls.single.arguments as Map<Object?, Object?>;
      expect(weak['biometricOnly'], isTrue);
      expect(weak['sensitiveTransaction'], isFalse);
      expect(weak['signInTitle'], _prompt.title);
      expect(weak['cancelButton'], _prompt.cancel);

      calls.clear();
      expect(await g.authenticate('Windows Hello'), isTrue);
      final Map<Object?, Object?> hello = calls.single.arguments as Map<Object?, Object?>;
      expect(hello['biometricOnly'], isFalse, reason: 'гейт Windows Hello — прежний вызов');
      expect(hello['sensitiveTransaction'], isTrue);
      expect(hello['localizedReason'], 'Windows Hello');
    });
  });
}

/// Шлюз, который бросает не `LocalAuthException` на диалоге.
final class _ThrowingGateway implements LocalAuthGateway {
  _ThrowingGateway(this._inner);

  final _Gateway _inner;

  @override
  Future<List<BiometricType>> availableBiometrics() => _inner.availableBiometrics();

  @override
  Future<bool> canCheckBiometrics() => _inner.canCheckBiometrics();

  @override
  Future<bool> isDeviceSupported() => _inner.isDeviceSupported();

  @override
  Future<bool> authenticate(
    String reason, {
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    BiometricPromptText? texts,
  }) async => throw PlatformException(code: 'boom');
}
