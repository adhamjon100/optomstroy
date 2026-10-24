// SecureStorage (07 §11.1 п.4; ядро §18.2 п.1–3): ключи, deviceId, очистка сессии.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/network/auth/token_store.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';

import 'in_memory_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('FlutterSecureStorageAdapter: write/read/delete по ключам перечня', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = FlutterSecureStorageAdapter();
    await storage.write(SecureKey.registrationFullName, 'Тестов Тест');
    expect(await storage.read(SecureKey.registrationFullName), 'Тестов Тест');
    await storage.deleteAll(SecureKey.registration);
    expect(await storage.read(SecureKey.registrationFullName), isNull);
    expect(SecureKey.registrationBirthYear.storageKey, 'registration.birth_year');
  });

  test('deviceId: UUID v4 создаётся один раз; некорректное значение заменяется', () async {
    final storage = InMemorySecureStorage();
    final first = await storage.readOrCreateDeviceId();
    expect(first, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    expect(await storage.readOrCreateDeviceId(), first);
    await storage.write(SecureKey.deviceId, 'garbage');
    expect(await storage.readOrCreateDeviceId(generate: () => 'fixed'), 'fixed');
  });

  test('TokenStore: access только в памяти; clearSession сохраняет deviceId', () async {
    final storage = InMemorySecureStorage({SecureKey.deviceId: 'dev'});
    final tokens = TokenStore(storage);
    await tokens.saveTokens(accessToken: 'a', refreshToken: 'r');
    expect(tokens.accessToken, 'a');
    expect(storage.values.values, isNot(contains('a')), reason: 'access не пишется на диск');
    expect(await tokens.readRefreshToken(), 'r');
    tokens.clearAccessToken();
    expect(tokens.accessToken, isNull);
    await storage.write(SecureKey.biometricsEnabled, 'true');
    await tokens.clearSession();
    expect(storage.values, {SecureKey.deviceId: 'dev'});
  });
}
