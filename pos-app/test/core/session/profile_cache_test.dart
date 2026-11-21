// Кэш профиля холодного старта и `userId` (12 T-BIO-028; 02 §0.4, ред. 1.30; 09 BIO-034; 15 ADR-116 п. 3):
// разбор кэша прежней версии без `userId`, правило записи `userId` при входе и разблокировке.
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/network/auth/token_store.dart';
import 'package:optomstroy/core/session/profile_cache.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';

import '../storage/in_memory_secure_storage.dart';

const String _a = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f01';
const String _b = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f02';

const CachedProfile _seller = CachedProfile(
  userId: _a,
  kind: UserKind.staff,
  status: UserStatus.active,
  roles: <RoleCode>[RoleCode.seller],
  pinSet: true,
  displayName: 'Тестов Продавец',
);

void main() {
  group('T-BIO-028: userId в кэше профиля', () {
    test('userId кодируется в части без ПДн; кэш прежней версии без поля — userId = null', () async {
      final InMemorySecureStorage storage = InMemorySecureStorage();
      final ProfileCacheStore cache = ProfileCacheStore(storage);
      await cache.write(_seller);
      expect(storage.values[SecureKey.profileCache], contains('"userId":"$_a"'));
      expect(storage.values[SecureKey.profileCache], isNot(contains('Тестов')));
      expect(await cache.read(), _seller);

      final CachedProfile? legacy = CachedProfile.decode('{"kind":"staff","status":"active","roles":["seller"]}');
      expect(legacy!.userId, isNull);
      expect(legacy.kind, UserKind.staff);
      expect(CachedProfile.decode('{"userId":"","kind":"staff"}')!.userId, isNull);
      expect(CachedProfile.decode('{"userId":7,"kind":"staff"}')!.userId, isNull);
    });

    test('кэш только с userId — «пустой» профиль (SCR-08 без имени и роли, как без кэша)', () {
      const CachedProfile onlyId = CachedProfile(userId: _a);
      expect(onlyId.isEmpty, isTrue);
      expect(CachedProfile.decode(onlyId.encode()), onlyId);
      expect(_seller.withUserId(_b), isNot(_seller));
      expect(_seller.withUserId(_b).displayName, 'Тестов Продавец');
    });

    test('rememberUser: разблокировка дополняет кэш прежней версии; вход заменяет чужой или неизвестный', () async {
      final InMemorySecureStorage storage = InMemorySecureStorage();
      final ProfileCacheStore cache = ProfileCacheStore(storage);
      const CachedProfile legacy = CachedProfile(
        kind: UserKind.staff,
        roles: <RoleCode>[RoleCode.seller],
        displayName: 'Тестов Продавец',
      );

      // Нет кэша (регистрация) — только userId.
      await cache.rememberUser(_a, unlock: false);
      expect(await cache.read(), const CachedProfile(userId: _a));

      // Тот же userId — кэш не меняется.
      await cache.write(_seller);
      await cache.rememberUser(_a, unlock: false);
      expect(await cache.read(), _seller);

      // Первая разблокировка после обновления: профиль той же сессии получает userId, имя остаётся.
      await cache.write(legacy);
      await cache.rememberUser(_a, unlock: true);
      expect(await cache.read(), legacy.withUserId(_a));

      // Вход по SMS при кэше прежней версии: владелец неизвестен — профиль заменяется, ФИО удалено.
      await cache.write(legacy);
      await cache.rememberUser(_b, unlock: false);
      expect(await cache.read(), const CachedProfile(userId: _b));
      expect(storage.values.containsKey(SecureKey.profileDisplayName), isFalse);

      // Кэш другого userId — заменяется и при разблокировке.
      await cache.write(_seller);
      await cache.rememberUser(_b, unlock: true);
      expect(await cache.read(), const CachedProfile(userId: _b));

      // Ключи кэша — в группе сессии: выход удаляет и userId.
      await TokenStore(storage).clearSession();
      expect(await cache.read(), isNull);
    });
  });
}
