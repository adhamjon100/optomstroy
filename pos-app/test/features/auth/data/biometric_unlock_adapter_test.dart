// Адаптер SCR-08 → BiometricAuthenticator (core/biometrics, RM-D-008): отображение
// возможностей и ошибок ОС, гейт Windows Hello по признаку пользователя (`userId`, 09 BIO-034; 12 T-BIO-004,
// T-BIO-028), тексты диалога — ARB.
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/hello_gate_users.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/session/profile_cache.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/features/auth/data/biometric_unlock_adapter.dart';
import 'package:optomstroy/features/auth/domain/ports/biometric_unlock.dart';

import '../../../core/storage/in_memory_secure_storage.dart';

final class _FakeAuthenticator implements BiometricAuthenticator {
  _FakeAuthenticator(this.cap, {this.hasSecret = true});

  BiometricCapability cap;
  bool hasSecret;
  BiometricResult<String> readResult = const BiometricResult<String>.success('bio-secret');
  final List<String> prompts = <String>[];
  final List<String> stored = <String>[];

  @override
  Future<BiometricCapability> capability() async => cap;

  @override
  Future<bool> hasStoredSecret() async => hasSecret;

  @override
  Future<BiometricResult<String>> read(BiometricPromptText prompt) async {
    prompts.add(prompt.title);
    return readResult;
  }

  @override
  Future<BiometricResult<void>> store(String secret, BiometricPromptText prompt) async {
    stored.add(secret);
    return const BiometricResult<void>.success(null);
  }

  @override
  Future<void> clear() async => hasSecret = false;

  @override
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) async =>
      const BiometricResult<void>.success(null);
}

const BiometricCapability _class3 = BiometricCapability(
  kind: BiometricKind.androidClass3,
  availability: BiometricAvailability.available,
  cryptoBinding: true,
);

const BiometricCapability _hello = BiometricCapability(
  kind: BiometricKind.windowsHello,
  availability: BiometricAvailability.available,
  cryptoBinding: false,
);

const BiometricCapability _helloMissing = BiometricCapability(
  kind: BiometricKind.windowsHello,
  availability: BiometricAvailability.unsupported,
  cryptoBinding: false,
  reason: 'device_not_present',
);

const String _userA = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f01';
const String _userB = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f02';

void main() {
  test('Android class3 с сохранённым секретом → cryptoBound; без секрета — кнопки нет', () async {
    final _FakeAuthenticator a = _FakeAuthenticator(_class3);
    final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(authenticator: a, storage: InMemorySecureStorage());
    expect(await adapter.capability(), BiometricUnlockKind.cryptoBound);
    expect(await adapter.kind(), BiometricUnlockKind.cryptoBound);
    a.hasSecret = false;
    expect(await adapter.kind(), BiometricUnlockKind.none);
  });

  test(
    'T-BIO-004: Windows Hello — гейт перед PIN (W1) только у пользователя с признаком (RB-09; 09 BIO-034)',
    () async {
      final InMemorySecureStorage storage = InMemorySecureStorage();
      final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(
        authenticator: _FakeAuthenticator(_hello, hasSecret: false),
        storage: storage,
        currentUserId: () async => _userA,
      );
      expect(await adapter.capability(), BiometricUnlockKind.windowsHelloGate);
      expect(await adapter.kind(), BiometricUnlockKind.none);
      await HelloGateUsers(storage).add(_userA);
      expect(await adapter.kind(), BiometricUnlockKind.windowsHelloGate);
      expect(await adapter.confirmPresence(), isTrue);
      // Hello не настроен (нет устройства) — кнопки нет и с признаком.
      final BiometricUnlockAdapter noDevice = BiometricUnlockAdapter(
        authenticator: _FakeAuthenticator(_helloMissing, hasSecret: false),
        storage: storage,
        currentUserId: () async => _userA,
      );
      expect(await noDevice.capability(), BiometricUnlockKind.none);
      expect(await noDevice.kind(), BiometricUnlockKind.none);
    },
  );

  group('T-BIO-028: признак Windows Hello по userId', () {
    test('холодный старт: userId из кэша профиля → кнопка у A; у B на том же ПК — нет', () async {
      final InMemorySecureStorage storage = InMemorySecureStorage();
      await HelloGateUsers(storage).add(_userA);
      // Без currentUserId адаптер берёт пользователя из кэша профиля (02 §0.4).
      final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(
        authenticator: _FakeAuthenticator(_hello, hasSecret: false),
        storage: storage,
      );
      await ProfileCacheStore(storage).write(const CachedProfile(userId: _userA, kind: UserKind.staff));
      expect(await adapter.kind(), BiometricUnlockKind.windowsHelloGate);
      await ProfileCacheStore(storage).write(const CachedProfile(userId: _userB, kind: UserKind.staff));
      expect(await adapter.kind(), BiometricUnlockKind.none, reason: 'признак A не виден B');
    });

    test(
      'кэш прежней версии без userId — кнопки нет, хотя прежний признак windows_hello есть (до разблокировки)',
      () async {
        final InMemorySecureStorage storage = InMemorySecureStorage(<SecureKey, String>{
          SecureKey.biometricsEnabled: HelloGateUsers.legacyFlag,
          SecureKey.profileCache: '{"kind":"staff","status":"active","roles":["seller"]}',
        });
        final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(
          authenticator: _FakeAuthenticator(_hello, hasSecret: false),
          storage: storage,
        );
        expect(await adapter.kind(), BiometricUnlockKind.none);
        // После первой разблокировки PIN (SessionController) признак перенесён, userId записан.
        await HelloGateUsers(storage).adoptLegacy(_userA);
        await ProfileCacheStore(storage).rememberUser(_userA, unlock: true);
        expect(await adapter.kind(), BiometricUnlockKind.windowsHelloGate);
      },
    );

    test('userId сессии важнее кэша; сбой источника userId — только PIN', () async {
      final InMemorySecureStorage storage = InMemorySecureStorage();
      await HelloGateUsers(storage).add(_userB);
      await ProfileCacheStore(storage).write(const CachedProfile(userId: _userA));
      BiometricUnlockAdapter adapter(Future<String?> Function() user) => BiometricUnlockAdapter(
        authenticator: _FakeAuthenticator(_hello, hasSecret: false),
        storage: storage,
        currentUserId: user,
      );
      expect(await adapter(() async => _userB).kind(), BiometricUnlockKind.windowsHelloGate);
      expect(await adapter(() async => null).kind(), BiometricUnlockKind.none);
      expect(await adapter(() async => throw StateError('storage')).kind(), BiometricUnlockKind.none);
    });

    test('Android/iOS не зависят от признака Windows Hello', () async {
      final InMemorySecureStorage storage = InMemorySecureStorage();
      await HelloGateUsers(storage).add(_userA);
      final _FakeAuthenticator a = _FakeAuthenticator(_class3, hasSecret: false);
      final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(
        authenticator: a,
        storage: storage,
        currentUserId: () async => _userA,
      );
      expect(await adapter.kind(), BiometricUnlockKind.none);
      a.hasSecret = true;
      expect(await adapter.kind(), BiometricUnlockKind.cryptoBound);
    });
  });

  test('read: секрет, отмена, lockout, инвалидация, прочее; заголовок диалога из ARB', () async {
    final _FakeAuthenticator a = _FakeAuthenticator(_class3);
    final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(authenticator: a, storage: InMemorySecureStorage());
    expect(await adapter.readSecret(), isA<BiometricSecretOk>());
    expect(a.prompts.single, 'Войти по биометрии');
    final Map<BiometricError, Type> map = <BiometricError, Type>{
      BiometricError.cancelled: BiometricSecretCancelled,
      BiometricError.lockout: BiometricSecretLockedOut,
      BiometricError.invalidated: BiometricSecretInvalidated,
      BiometricError.notEnrolled: BiometricSecretUnavailable,
      BiometricError.noCredential: BiometricSecretUnavailable,
      BiometricError.failed: BiometricSecretUnavailable,
    };
    for (final MapEntry<BiometricError, Type> e in map.entries) {
      a.readResult = BiometricResult<String>.failure(e.key);
      expect((await adapter.readSecret()).runtimeType, e.value, reason: e.key.name);
    }
  });

  test('storeSecret передаёт новый biometric refresh в порт core', () async {
    final _FakeAuthenticator a = _FakeAuthenticator(_class3);
    final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(authenticator: a, storage: InMemorySecureStorage());
    expect(await adapter.storeSecret('next'), isTrue);
    expect(a.stored, <String>['next']);
    await adapter.clear();
    expect(a.hasSecret, isFalse);
  });

  group('T-BIO-020: уровень W Android (15 ADR-116 п. 2; 09 BIO-030, BIO-036; 02 SCR-08.4 п. 9, п. 10)', () {
    test(
      '(1) секрет уровня W и уровень W доступен → weakBound; на телефоне и с Class 3 — тоже weakBound, не S',
      () async {
        final _WeakAuthenticator a = _WeakAuthenticator(_weakOnly(stored: BiometricTier.weak));
        final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(
          authenticator: a,
          storage: InMemorySecureStorage(),
        );
        expect(await adapter.kind(), BiometricUnlockKind.weakBound);
        a.cap = _strongAndWeak(stored: BiometricTier.weak);
        expect(await adapter.kind(), BiometricUnlockKind.weakBound, reason: 'сохранён секрет W — кнопка лица');
        a.cap = _strongAndWeak(stored: BiometricTier.strong);
        expect(await adapter.kind(), BiometricUnlockKind.cryptoBound);
        expect(a.dialogs, 0, reason: 'вид — без системного диалога');
      },
    );

    test('секрет W есть, а уровень W сейчас недоступен (биометрию сняли, сбой local_auth) — кнопки нет', () async {
      for (final BiometricAvailability w in <BiometricAvailability>[
        BiometricAvailability.notEnrolled,
        BiometricAvailability.unsupported,
        BiometricAvailability.lockedOut,
      ]) {
        final _WeakAuthenticator a = _WeakAuthenticator(_weakOnly(stored: BiometricTier.weak, weak: w));
        final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(
          authenticator: a,
          storage: InMemorySecureStorage(),
        );
        expect(await adapter.kind(), BiometricUnlockKind.none, reason: w.name);
      }
      // Секрета нет — тоже нет кнопки.
      final _WeakAuthenticator empty = _WeakAuthenticator(_weakOnly(stored: null))..secret = null;
      expect(
        await BiometricUnlockAdapter(authenticator: empty, storage: InMemorySecureStorage()).kind(),
        BiometricUnlockKind.none,
      );
    });

    test(
      '(1) диалог W — заголовок auth_bio_prompt_face; (2) новый токен — replace без диалога, без store уровня S',
      () async {
        final _WeakAuthenticator a = _WeakAuthenticator(_weakOnly(stored: BiometricTier.weak));
        final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(
          authenticator: a,
          storage: InMemorySecureStorage(),
        );
        expect(await adapter.kind(), BiometricUnlockKind.weakBound);
        final BiometricSecretResult read = await adapter.readSecret();
        expect(read, isA<BiometricSecretOk>());
        expect(a.titles.single, 'Вход по лицу или отпечатку', reason: 'auth_bio_prompt_face (02 SCR-08.4 п. 9)');
        expect(a.dialogs, 1);
        expect(await adapter.storeSecret('next-weak'), isTrue);
        expect(a.replaced, <String>['next-weak']);
        expect(a.dialogs, 1, reason: 'второго диалога нет (BIO-030)');
        expect(a.storedStrong, isEmpty);
        // Запись не удалась — на уровень S (новый ключ, диалог) не переходим.
        a.replaceResult = const BiometricResult<void>.failure(BiometricError.noCredential);
        expect(await adapter.storeSecret('next-2'), isFalse);
        expect(a.storedStrong, isEmpty);
        expect(a.dialogs, 1);
      },
    );

    test('readSecret без предварительного kind — уровень берётся у порта (заголовок W)', () async {
      final _WeakAuthenticator a = _WeakAuthenticator(_weakOnly(stored: BiometricTier.weak));
      final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(authenticator: a, storage: InMemorySecureStorage());
      expect(await adapter.readSecret(), isA<BiometricSecretOk>());
      expect(a.titles.single, 'Вход по лицу или отпечатку');
    });

    test('уровень S на том же порте — прежний заголовок и запись тем же ключом', () async {
      final _WeakAuthenticator a = _WeakAuthenticator(_strongAndWeak(stored: BiometricTier.strong));
      final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(authenticator: a, storage: InMemorySecureStorage());
      expect(await adapter.kind(), BiometricUnlockKind.cryptoBound);
      await adapter.readSecret();
      expect(a.titles.single, 'Войти по биометрии');
      a.replaceResult = const BiometricResult<void>.failure(BiometricError.noCredential);
      expect(await adapter.storeSecret('next-s'), isTrue, reason: 'ключа нет — store уровня S, как прежде');
      expect(a.storedStrong, <String>['next-s']);
    });
  });

  group('T-BIO-033 (2): планшет магазина — порт биометрии не вызывается (09 BIO-037)', () {
    test(
      'режим планшета: вид none, чтение и подтверждение недоступны, подпись W2 — отказ; вызовов порта core 0',
      () async {
        final _WeakAuthenticator a = _WeakAuthenticator(_weakOnly(stored: BiometricTier.weak));
        final InMemorySecureStorage storage = InMemorySecureStorage();
        await HelloGateUsers(storage).add(_userA);
        final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(
          authenticator: a,
          storage: storage,
          currentUserId: () async => _userA,
          kioskMode: () => true,
        );
        expect(await adapter.capability(), BiometricUnlockKind.none);
        expect(await adapter.kind(), BiometricUnlockKind.none);
        expect(await adapter.readSecret(), isA<BiometricSecretUnavailable>());
        expect(await adapter.confirmPresence(), isFalse);
        expect(await adapter.signHelloChallenge('optomstroy-hello-unlock/v1:x'), isA<HelloKeySignFailed>());
        expect(a.calls, 0, reason: 'ни capability, ни диалога, ни чтения секрета');
      },
    );
  });
}

/// Порт core с уровнями S и W (как `AndroidBiometricAuthenticator`): запись W, замена без диалога, счётчики.
final class _WeakAuthenticator implements BiometricAuthenticator, BiometricSecretReplacer, BiometricWeakStore {
  _WeakAuthenticator(this.cap);

  BiometricCapability cap;
  String? secret = 'weak-secret'; // check-secrets: allow (тестовая метка)
  BiometricResult<void> replaceResult = const BiometricResult<void>.success(null);
  int calls = 0;
  int dialogs = 0;
  final List<String> titles = <String>[];
  final List<String> replaced = <String>[];
  final List<String> storedStrong = <String>[];

  @override
  Future<BiometricCapability> capability() async {
    calls++;
    return cap;
  }

  @override
  Future<bool> hasStoredSecret() async {
    calls++;
    return secret != null;
  }

  @override
  Future<BiometricResult<String>> read(BiometricPromptText prompt) async {
    calls++;
    dialogs++;
    titles.add(prompt.title);
    final String? s = secret;
    return s == null
        ? const BiometricResult<String>.failure(BiometricError.noCredential)
        : BiometricResult<String>.success(s);
  }

  @override
  Future<BiometricResult<void>> replace(String secret, BiometricPromptText prompt) async {
    calls++;
    if (replaceResult.isSuccess) replaced.add(secret);
    return replaceResult;
  }

  @override
  Future<BiometricResult<void>> store(String secret, BiometricPromptText prompt) async {
    calls++;
    dialogs++;
    storedStrong.add(secret);
    return const BiometricResult<void>.success(null);
  }

  @override
  Future<BiometricResult<void>> storeWeak(String secret, BiometricPromptText prompt) async {
    calls++;
    dialogs++;
    this.secret = secret;
    return const BiometricResult<void>.success(null);
  }

  @override
  Future<void> clear() async {
    calls++;
    secret = null;
  }

  @override
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) async {
    calls++;
    return const BiometricResult<void>.failure(BiometricError.notAvailable);
  }
}

/// Телефон только со слабым лицом (Class 2): уровень S недоступен, уровень W — [weak].
BiometricCapability _weakOnly({
  required BiometricTier? stored,
  BiometricAvailability weak = BiometricAvailability.available,
}) => BiometricCapability(
  kind: BiometricKind.androidClass2,
  availability: BiometricAvailability.unsupported,
  cryptoBinding: false,
  reason: 'weak_only',
  weakAvailability: weak,
  storedTier: stored,
);

/// Телефон с отпечатком Class 3 и слабым лицом: оба уровня доступны.
BiometricCapability _strongAndWeak({required BiometricTier? stored}) => BiometricCapability(
  kind: BiometricKind.androidClass3,
  availability: BiometricAvailability.available,
  cryptoBinding: true,
  weakAvailability: BiometricAvailability.available,
  storedTier: stored,
);
