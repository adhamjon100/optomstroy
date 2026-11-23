// 12 T-BIO-033 (клиент): планшет магазина без биометрии (09 BIO-037; 11 SEC-145; 15 ADR-115, ADR-116; 04 FLOW-043,
// AC-FLOW-043-14; 02 SCR-51…SCR-53). (1) «Сделать это устройство планшетом магазина» (`becomeKiosk`) удаляет секрет
// уровня W, признаки Windows Hello (гейт W1 и ключ W2) и кэш профиля администратора и вызывает очистку порта
// биометрии; закрытые ключи W2 в хранилище ключей Windows удаляются `deleteHelloKey` для каждого пользователя из
// `auth.hello_key_users` до удаления списка, без диалога Windows Hello (сбой удаления подключение не срывает); (2) в сессии планшета и на холодном старте планшета порт биометрии core не вызывается ни разу (счётчик
// подменного порта — 0), кнопок биометрии нет: порт SCR-08 корня (`authBindings`) в режиме планшета отвечает «нет».
// Серверная часть T-BIO-033 — pos-api (`test/kiosk/access.spec.ts`, `test/kiosk/lifecycle-reconnect.spec.ts`).
// Данные тестовые: UUID-заглушки, без телефонов и имён людей.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/windows_hello_key.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/features/auth/auth_providers.dart';
import 'package:optomstroy/features/auth/data/auth_bindings.dart';
import 'package:optomstroy/features/auth/domain/ports/biometric_unlock.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_shell_screen.dart';

import '../../features/kiosk/kiosk_lifecycle_support.dart';

/// Порт биометрии core со счётчиком вызовов: устройство с уровнем W и сохранённым секретом (как
/// `AndroidBiometricAuthenticator` администратора, включившего вход по лицу).
final class _CountingBiometrics implements BiometricAuthenticator, BiometricSecretReplacer, BiometricWeakStore {
  final Map<String, int> calls = <String, int>{};

  int get total => calls.values.fold<int>(0, (int a, int b) => a + b);

  void _hit(String name) => calls[name] = (calls[name] ?? 0) + 1;

  @override
  Future<BiometricCapability> capability() async {
    _hit('capability');
    return const BiometricCapability(
      kind: BiometricKind.androidClass3,
      availability: BiometricAvailability.available,
      cryptoBinding: true,
      weakAvailability: BiometricAvailability.available,
      storedTier: BiometricTier.weak,
    );
  }

  @override
  Future<bool> hasStoredSecret() async {
    _hit('hasStoredSecret');
    return true;
  }

  @override
  Future<BiometricResult<String>> read(BiometricPromptText prompt) async {
    _hit('read');
    return const BiometricResult<String>.success('weak-secret'); // check-secrets: allow (тестовая метка)
  }

  @override
  Future<BiometricResult<void>> replace(String secret, BiometricPromptText prompt) async {
    _hit('replace');
    return const BiometricResult<void>.success(null);
  }

  @override
  Future<BiometricResult<void>> store(String secret, BiometricPromptText prompt) async {
    _hit('store');
    return const BiometricResult<void>.success(null);
  }

  @override
  Future<BiometricResult<void>> storeWeak(String secret, BiometricPromptText prompt) async {
    _hit('storeWeak');
    return const BiometricResult<void>.success(null);
  }

  @override
  Future<void> clear() async => _hit('clear');

  @override
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) async {
    _hit('confirmPresence');
    return const BiometricResult<void>.success(null);
  }
}

/// Порт Windows с ключом W2 (как `WindowsHelloKeyAuthenticator`): записывает `deleteHelloKey(userId)`; диалоговые
/// методы (`createHelloKey`, `signHelloChallenge`, `confirmPresence`) только считаются — в прогоне их быть не должно.
final class _HelloKeyBiometrics implements BiometricAuthenticator, BiometricHelloKey {
  _HelloKeyBiometrics({this.deleteResult = true, this.deleteThrows = false});

  final bool deleteResult;
  final bool deleteThrows;
  final List<String> deleted = <String>[];
  final Map<String, int> prompts = <String, int>{};

  void _prompt(String name) => prompts[name] = (prompts[name] ?? 0) + 1;

  @override
  Future<BiometricCapability> capability() async => const BiometricCapability(
    kind: BiometricKind.windowsHello,
    availability: BiometricAvailability.available,
    cryptoBinding: false,
  );

  @override
  Future<BiometricResult<void>> store(String secret, BiometricPromptText prompt) async =>
      const BiometricResult<void>.failure(BiometricError.notAvailable);

  @override
  Future<BiometricResult<String>> read(BiometricPromptText prompt) async =>
      const BiometricResult<String>.failure(BiometricError.notAvailable);

  @override
  Future<bool> hasStoredSecret() async => false;

  @override
  Future<void> clear() async {}

  @override
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) async {
    _prompt('confirmPresence');
    return const BiometricResult<void>.success(null);
  }

  @override
  Future<WindowsHelloStatus> helloStatus() async =>
      const WindowsHelloStatus(availability: WindowsHelloAvailability.available, keysSupported: true);

  @override
  Future<BiometricResult<String>> createHelloKey(String userId) async {
    _prompt('createHelloKey');
    return const BiometricResult<String>.failure(BiometricError.failed);
  }

  @override
  Future<BiometricResult<String>> signHelloChallenge(String userId, String challenge) async {
    _prompt('signHelloChallenge');
    return const BiometricResult<String>.failure(BiometricError.failed);
  }

  @override
  Future<bool> deleteHelloKey(String userId) async {
    deleted.add(userId);
    if (deleteThrows) throw StateError('сбой хранилища ключей (тест)');
    return deleteResult;
  }
}

/// `becomeKiosk` администратора на порте [bio] с признаком W2 у [staffUserId] и [otherUserId].
Future<SessionHarness> _becomeKioskWithHelloKeys(BiometricAuthenticator bio) async {
  final SessionHarness h = SessionHarness(_server(), overrides: kioskOverrides(FakeKioskLock()), biometrics: bio);
  h.start();
  await h.controller.establish(
    accessToken: fakeJwt(sub: staffUserId, tag: 'admin'),
    refreshToken: 'ra1',
  );
  h.storage.values[SecureKey.helloKeyUsers] = '["$staffUserId","$otherUserId"]';
  h.controller.holdForKioskEnrollment();
  await h.controller.becomeKiosk(
    tabletId: kioskTabletId,
    tabletName: kioskTabletName,
    exitCode: kioskExitCode,
    accessToken: kioskJwt(tag: 'enrolled'),
    refreshToken: 'rk-enrolled', // check-secrets: allow (тест)
  );
  await settle();
  return h;
}

/// Сервер: `/auth/refresh` — новая пара планшета, `/settings/public` — режим планшета включён, прочее — 200.
FakeHandler _server() => (RequestOptions o) async {
  if (o.path.endsWith('/auth/refresh')) return json(200, tokenPair(kioskJwt(tag: 'r'), 'rk2'));
  if (o.path.endsWith('/settings/public')) return json(200, publicSettingsBody());
  return json(200, <String, Object?>{'ok': true});
};

/// Порт SCR-08 настоящего корня (`authBindings`: адаптер с признаком режима планшета) спрашивается во всех видах.
Future<void> _askPort(BiometricUnlock port) async {
  expect(await port.capability(), BiometricUnlockKind.none);
  expect(await port.kind(), BiometricUnlockKind.none);
  expect(await port.readSecret(), isA<BiometricSecretUnavailable>());
  expect(await port.confirmPresence(), isFalse);
}

void main() {
  group('T-BIO-033 (клиент): планшет магазина без биометрии (09 BIO-037)', () {
    test('(1) becomeKiosk: секрет уровня W, признаки Windows Hello (W1, W2) и кэш профиля администратора удалены, '
        'очистка порта биометрии вызвана', () async {
      final _CountingBiometrics bio = _CountingBiometrics();
      final FakeKioskLock lock = FakeKioskLock();
      final SessionHarness h = SessionHarness(_server(), overrides: kioskOverrides(lock), biometrics: bio);
      addTearDown(h.dispose);
      h.start();
      await h.controller.establish(
        accessToken: fakeJwt(sub: staffUserId, tag: 'admin'),
        refreshToken: 'ra1',
      );
      h.storage.values
        ..[SecureKey.biometricsEnabled] = 'true'
        ..[SecureKey.biometricRefreshWeak] =
            'weak-secret' // check-secrets: allow (тестовая метка)
        ..[SecureKey.helloGateUsers] = '["$staffUserId"]'
        ..[SecureKey.helloKeyUsers] = '["$staffUserId"]'
        ..[SecureKey.profileCache] = '{"userId":"$staffUserId","roles":["admin"]}';
      final int clearsBefore = bio.calls['clear'] ?? 0;
      h.controller.holdForKioskEnrollment();
      await h.controller.becomeKiosk(
        tabletId: kioskTabletId,
        tabletName: kioskTabletName,
        exitCode: kioskExitCode,
        accessToken: kioskJwt(tag: 'enrolled'),
        refreshToken: 'rk-enrolled', // check-secrets: allow (тест)
      );
      await settle();
      expect(h.state.isKioskSession, isTrue);
      for (final SecureKey k in <SecureKey>[
        SecureKey.biometricsEnabled,
        SecureKey.biometricRefreshWeak,
        SecureKey.helloGateUsers,
        SecureKey.helloKeyUsers,
        SecureKey.profileCache,
      ]) {
        expect(h.storage.values.containsKey(k), isFalse, reason: '${k.storageKey}: удалён (BIO-037, SEC-145)');
      }
      expect(bio.calls['clear'], clearsBefore + 1, reason: 'хук очистки сессии — clear() порта (оба уровня)');
      expect(bio.total - (bio.calls['clear'] ?? 0), 0, reason: 'кроме очистки, порт не вызывался');
    });

    test(
      '(1) becomeKiosk на Windows: закрытые ключи W2 всех пользователей списка удалены без диалога, затем список',
      () async {
        final _HelloKeyBiometrics bio = _HelloKeyBiometrics();
        final SessionHarness h = await _becomeKioskWithHelloKeys(bio);
        addTearDown(h.dispose);
        expect(h.state.isKioskSession, isTrue);
        expect(bio.deleted..sort(), <String>[staffUserId, otherUserId]..sort(), reason: 'по разу на userId (BIO-037)');
        expect(h.storage.values.containsKey(SecureKey.helloKeyUsers), isFalse, reason: 'auth.hello_key_users удалён');
        expect(bio.prompts, isEmpty, reason: 'createHelloKey/signHelloChallenge/confirmPresence — нет диалога Hello');
      },
    );

    for (final ({String name, _HelloKeyBiometrics bio}) c in <({String name, _HelloKeyBiometrics bio})>[
      (name: 'исключение', bio: _HelloKeyBiometrics(deleteThrows: true)),
      (name: 'false', bio: _HelloKeyBiometrics(deleteResult: false)),
    ]) {
      test('(1) becomeKiosk: deleteHelloKey — ${c.name} → планшет всё равно подключён, список удалён', () async {
        final SessionHarness h = await _becomeKioskWithHelloKeys(c.bio);
        addTearDown(h.dispose);
        expect(h.state.isKioskSession, isTrue);
        expect(c.bio.deleted, hasLength(2), reason: 'сбой одного ключа не останавливает остальные');
        expect(h.storage.values.containsKey(SecureKey.helloKeyUsers), isFalse);
        expect(c.bio.prompts, isEmpty);
      });
    }

    testWidgets('(2) сессия планшета, холодный старт → SCR-51: порт биометрии не вызывается, кнопок биометрии нет; '
        'маршрут SCR-08 ведёт на /kiosk', (WidgetTester tester) async {
      final _CountingBiometrics bio = _CountingBiometrics();
      final SessionHarness h = kioskHarness(
        _server(),
        lock: FakeKioskLock(locked: true),
        access: kioskJwt(),
        biometrics: bio,
        overrides: <Override>[...authBindings],
      );
      addTearDown(h.dispose);
      h.start();
      await tester.runAsync(() => h.container.read(sessionStatusProvider.future));
      expect(h.state.isKioskSession, isTrue);
      final GoRouter router = kioskGuardRouter(h.container);
      addTearDown(router.dispose);
      await tester.pumpWidget(kioskTestApp(h.container, router));
      await tester.pumpAndSettle();
      router.go('/kiosk');
      await tester.pumpAndSettle();
      expect(find.byKey(KioskShellScreen.screenKey), findsOneWidget);
      for (final String path in <String>['/auth/unlock', '/auth/unlock?mode=cold', '/settings', '/catalog']) {
        router.go(path);
        await tester.pumpAndSettle();
        expect(router.state.uri.path, '/kiosk', reason: path);
      }
      expect(find.byIcon(Icons.fingerprint_rounded), findsNothing);
      expect(find.byIcon(Icons.face_unlock_outlined), findsNothing);
      await tester.runAsync(() => _askPort(h.container.read(biometricUnlockProvider)));
      expect(bio.total, 0, reason: 'счётчик подменного порта — 0 (12 T-BIO-033 (2))');
    });

    test('(2) признак планшета без сессии («Подключите заново», G-0a): порт биометрии тоже не вызывается', () async {
      final _CountingBiometrics bio = _CountingBiometrics();
      final SessionHarness h = kioskHarness(
        _server(),
        lock: FakeKioskLock(locked: true),
        refresh: null,
        biometrics: bio,
        overrides: <Override>[...authBindings],
      );
      addTearDown(h.dispose);
      h.start();
      expect(await h.container.read(sessionStatusProvider.future), SessionStatus.unauthenticated);
      expect(h.state.kioskReconnectNeeded, isTrue);
      await _askPort(h.container.read(biometricUnlockProvider));
      expect(bio.total, 0);
    });

    test('обычный пользователь на том же порте корня — уровень W предлагается (паритет вне планшета)', () async {
      final _CountingBiometrics bio = _CountingBiometrics();
      final SessionHarness h = SessionHarness(_server(), biometrics: bio, overrides: <Override>[...authBindings]);
      addTearDown(h.dispose);
      h.start();
      await h.controller.establish(
        accessToken: fakeJwt(sub: staffUserId),
        refreshToken: 'ra1',
      );
      expect(await h.container.read(biometricUnlockProvider).kind(), BiometricUnlockKind.weakBound);
      expect(bio.total, greaterThan(0));
    });
  });
}
