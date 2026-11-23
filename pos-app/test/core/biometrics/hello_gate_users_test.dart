// Признак «Windows Hello перед PIN» по `userId` вне ключей сессии (12 T-BIO-028; 09 BIO-034, §8.5; 11 SEC-145;
// 07 DATA-307; 15 ADR-116 п. 3): список пользователей, перенос и удаление прежнего значения `windows_hello`.
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/biometrics/hello_gate_users.dart';
import 'package:optomstroy/core/network/auth/token_store.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';

import '../storage/in_memory_secure_storage.dart';

const String _a = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f01';
const String _b = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f02';

/// Хранилище, которое отказывает на каждой операции (сбой Keystore / Credential Manager).
final class _BrokenStorage implements SecureStorage {
  @override
  Future<String?> read(SecureKey key) async => throw StateError('storage');

  @override
  Future<void> write(SecureKey key, String value) async => throw StateError('storage');

  @override
  Future<void> delete(SecureKey key) async => throw StateError('storage');
}

/// Чтение отказывает, запись и удаление проходят в [_inner].
final class _ReadFailsStorage implements SecureStorage {
  _ReadFailsStorage(this._inner);

  final SecureStorage _inner;

  @override
  Future<String?> read(SecureKey key) async => throw StateError('storage');

  @override
  Future<void> write(SecureKey key, String value) => _inner.write(key, value);

  @override
  Future<void> delete(SecureKey key) => _inner.delete(key);
}

void main() {
  group('T-BIO-028: признак Windows Hello по userId (W1)', () {
    test('ключ auth.hello_gate_users — вне SecureKey.session: выход и SESSION_REVOKED его не удаляют', () async {
      expect(SecureKey.helloGateUsers.storageKey, 'auth.hello_gate_users');
      expect(SecureKey.session, isNot(contains(SecureKey.helloGateUsers)));
      expect(SecureKey.kiosk, isNot(contains(SecureKey.helloGateUsers)));
      final InMemorySecureStorage storage = InMemorySecureStorage(<SecureKey, String>{SecureKey.refreshToken: 'r'});
      final HelloGateUsers gate = HelloGateUsers(storage);
      expect(await gate.add(_a), isTrue);
      await TokenStore(storage).clearSession();
      expect(storage.values[SecureKey.refreshToken], isNull);
      expect(await gate.contains(_a), isTrue, reason: 'признак пережил очистку сессии (SEC-145)');
    });

    test('A и B на одном устройстве: признак виден только своему; выключение снимает только свой', () async {
      final InMemorySecureStorage storage = InMemorySecureStorage();
      final HelloGateUsers gate = HelloGateUsers(storage);
      expect(await gate.contains(_a), isFalse);
      expect(await gate.add(_a), isTrue);
      expect(await gate.add(_a), isTrue, reason: 'повтор — без дубля');
      expect(await gate.contains(_a), isTrue);
      expect(await gate.contains(_b), isFalse);
      expect(await gate.add(_b), isTrue);
      expect(await gate.read(), <String>{_a, _b});
      expect(await gate.remove(_a), isTrue);
      expect(await gate.contains(_a), isFalse);
      expect(await gate.contains(_b), isTrue, reason: 'признак B не тронут');
      expect(await gate.remove(_b), isTrue);
      expect(storage.values.containsKey(SecureKey.helloGateUsers), isFalse, reason: 'пустой список — ключ удалён');
    });

    test('неизвестный пользователь (кэш без userId) — признака нет; регистр UUID не важен', () async {
      final HelloGateUsers gate = HelloGateUsers(InMemorySecureStorage());
      await gate.add(_a.toUpperCase());
      expect(await gate.contains(null), isFalse);
      expect(await gate.contains(''), isFalse);
      expect(await gate.contains(_a), isTrue);
      expect(await gate.add('  '), isFalse);
    });

    test('повреждённое значение — пустой список; сбой хранилища — «признака нет», без исключений', () async {
      final InMemorySecureStorage storage = InMemorySecureStorage(<SecureKey, String>{
        SecureKey.helloGateUsers: '{broken',
      });
      expect(await HelloGateUsers(storage).read(), isEmpty);
      storage.values[SecureKey.helloGateUsers] = '{"a":1}';
      expect(await HelloGateUsers(storage).contains(_a), isFalse);
      storage.values[SecureKey.helloGateUsers] = '["$_a", 7, null, ""]';
      expect(await HelloGateUsers(storage).read(), <String>{_a});

      final HelloGateUsers broken = HelloGateUsers(_BrokenStorage());
      expect(await broken.contains(_a), isFalse);
      expect(await broken.add(_a), isFalse);
      expect(await broken.remove(_a), isFalse);
      expect(await broken.adoptLegacy(_a), isFalse);
      await broken.dropLegacy();

      // Чтение отказало, запись работает (кратковременный сбой): список не перезаписывается — признак B не теряется.
      final InMemorySecureStorage kept = InMemorySecureStorage(<SecureKey, String>{
        SecureKey.helloGateUsers: '["$_b"]',
      });
      final HelloGateUsers flaky = HelloGateUsers(_ReadFailsStorage(kept));
      expect(await flaky.add(_a), isFalse);
      expect(await flaky.remove(_b), isFalse);
      expect(await HelloGateUsers(kept).read(), <String>{_b});
    });

    test('прежний признак windows_hello: разблокировка переносит на userId, вход — удаляет; true не трогается', () async {
      final InMemorySecureStorage storage = InMemorySecureStorage(<SecureKey, String>{
        SecureKey.biometricsEnabled: HelloGateUsers.legacyFlag,
      });
      final HelloGateUsers gate = HelloGateUsers(storage);
      expect(await gate.adoptLegacy(_a), isTrue);
      expect(await gate.contains(_a), isTrue);
      expect(storage.values.containsKey(SecureKey.biometricsEnabled), isFalse);
      expect(await gate.adoptLegacy(_a), isFalse, reason: 'переносить больше нечего');

      storage.values[SecureKey.biometricsEnabled] = HelloGateUsers.legacyFlag;
      await gate.dropLegacy();
      expect(storage.values.containsKey(SecureKey.biometricsEnabled), isFalse);
      expect(await gate.contains(_b), isFalse, reason: 'чужой гейт новому пользователю не достаётся');

      storage.values[SecureKey.biometricsEnabled] = 'true';
      await gate.dropLegacy();
      expect(await gate.adoptLegacy(_b), isFalse);
      expect(storage.values[SecureKey.biometricsEnabled], 'true', reason: 'признак криптопривязки (Android/iOS)');
      expect(await gate.read(), <String>{_a});
    });
  });
}
