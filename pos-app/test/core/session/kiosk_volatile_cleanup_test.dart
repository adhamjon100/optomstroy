// Планшет магазина (ADR-115; 04 FLOW-045.A2; 07 §11.2, DATA-304; 10 KIOSK-020, KIOSK-021; 11 PRIV-033 (2);
// 13 TAB-2-12): `SessionLocalData.clearKioskVolatile` при запуске, до первого `POST /kiosk/reset`, удаляет из файла БД
// планшета всё, что могло остаться от покупателя (корзина, оформление, недавние, избранное, уведомления, очередь
// любого типа, история поиска, последний корень, вид и сортировка каталога), и оставляет кэш каталога, `sync_meta`,
// настройки устройства и метку сброса без сети `kiosk.pending_reset_cart_id`. Очистка при выходе сотрудника
// (`clearOnSessionEnd`) не меняется.
// Синтетические данные.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/app_meta_dao.dart';
import 'package:optomstroy/core/session/session_local_data.dart';
import 'package:optomstroy/features/cart/data/sync/drift_cart_sync.dart';
import 'package:optomstroy/features/cart/data/sync/kiosk_cart_sync.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_user_settings_store.dart';

import '../database/test_database.dart';

const String tablet = '00000000-0000-4000-8000-0000000000c1';
const String foreign = '00000000-0000-4000-8000-0000000000f1';

void main() {
  configureSqliteForTests();
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> seed() async {
    for (final String owner in <String>[tablet, foreign]) {
      await db
          .into(db.cartDraft)
          .insert(
            CartDraftCompanion.insert(localId: 'cart-$owner', status: 'active', ownerUserId: owner, updatedAt: 1),
          );
      await db
          .into(db.cartItemsDraft)
          .insert(
            CartItemsDraftCompanion.insert(
              localItemId: 'item-$owner',
              localCartId: 'cart-$owner',
              variantId: 'v-1',
              quantityMilli: 2000,
              lineNo: 1,
              ownerUserId: owner,
            ),
          );
    }
    for (final (int i, String type) in <(int, String)>[
      (1, 'cart.sync'),
      (2, 'recent.touch'),
      (3, 'favorite.add'),
      (4, 'notification.read'),
    ]) {
      await db
          .into(db.outboxActions)
          .insert(
            OutboxActionsCompanion.insert(
              type: type,
              payloadJson: '{}',
              idempotencyKey: 'key-$i',
              ownerUserId: i.isEven ? foreign : tablet,
              createdAt: i,
            ),
          );
    }
    await db
        .into(db.checkoutDraft)
        .insert(CheckoutDraftCompanion.insert(localCartId: 'cart-$tablet', step: 'customer', updatedAt: 1));
    await db
        .into(db.localRecentProducts)
        .insert(LocalRecentProductsCompanion.insert(productId: 'p-1', lastViewedAt: 1));
    await db
        .into(db.localFavoritesProducts)
        .insert(LocalFavoritesProductsCompanion.insert(productId: 'p-1', createdAt: 1));
    await db
        .into(db.localFavoritesCustomers)
        .insert(LocalFavoritesCustomersCompanion.insert(customerId: 'c-1', createdAt: 1));
    await db
        .into(db.notificationsCache)
        .insert(
          NotificationsCacheCompanion.insert(
            id: 'n-1',
            kind: 'order_status',
            severity: 'info',
            title: 'T',
            createdAt: 1,
          ),
        );
    for (final (String key, String scope) in <(String, String)>[
      ('search_history', 'user'),
      ('catalog_last_root', 'device'),
      ('catalog_view_mode.medium', 'device'),
      ('catalog_view_mode.expanded', 'device'),
      ('catalog_sort.catalog', 'device'),
      ('catalog_sort.search', 'device'),
      // Остаются: настройки устройства, не относящиеся к покупателю.
      ('sidebar_collapsed', 'device'),
      ('catalog_viewXmode', 'device'),
    ]) {
      await db
          .into(db.localSettings)
          .insert(LocalSettingsCompanion.insert(key: key, valueJson: '"x"', scope: scope, updatedAt: 1));
    }
    for (final String key in <String>[
      'kiosk.pending_reset_cart_id',
      'cart_version_conflict',
      'cart_variant_replace',
      'catalog_full_loaded_at',
    ]) {
      await db.into(db.appMeta).insert(AppMetaCompanion.insert(key: key, value: 'v'));
    }
    await db.into(db.localWarehouses).insert(LocalWarehousesCompanion.insert(id: 'wh-1', name: 'Склад планшета'));
  }

  test(
    'T-KIOSK-029 запуск планшета: строк покупателя в drift нет — корзина, очередь, недавние, оформление, история '
    'поиска, вид и сортировка удалены; кэш каталога, настройки устройства и метка сброса без сети остаются',
    () async {
      await seed();
      await SessionLocalData(db).clearKioskVolatile(tablet);

      expect(await db.select(db.cartDraft).get(), isEmpty);
      expect(await db.select(db.cartItemsDraft).get(), isEmpty);
      expect(await db.select(db.outboxActions).get(), isEmpty, reason: 'cart.sync, recent.touch и любые другие типы');
      expect(await db.select(db.checkoutDraft).get(), isEmpty);
      expect(await db.select(db.localRecentProducts).get(), isEmpty);
      expect(await db.select(db.localFavoritesProducts).get(), isEmpty);
      expect(await db.select(db.localFavoritesCustomers).get(), isEmpty);
      expect(await db.select(db.notificationsCache).get(), isEmpty);
      expect(
        (await db.select(db.localSettings).get()).map((SettingRow r) => r.key).toSet(),
        <String>{'sidebar_collapsed', 'catalog_viewXmode'},
        reason: '`_` и `.` префиксов — буквально (LIKE с экранированием)',
      );
      expect((await db.select(db.appMeta).get()).map((AppMetaRow r) => r.key).toSet(), <String>{
        'schema_version',
        'kiosk.pending_reset_cart_id',
        'catalog_full_loaded_at',
      });
      expect(await db.select(db.localWarehouses).get(), hasLength(1), reason: 'кэш каталога не трогается');
    },
  );

  test('повторный запуск на чистом файле — без ошибок, метка сброса без сети на месте', () async {
    await db.into(db.appMeta).insert(AppMetaCompanion.insert(key: 'kiosk.pending_reset_cart_id', value: 'cart-9'));
    await SessionLocalData(db).clearKioskVolatile(tablet);
    await SessionLocalData(db).clearKioskVolatile(tablet);
    expect(await AppMetaDao(db).read('kiosk.pending_reset_cart_id'), 'cart-9');
  });

  test('паритет: выход сотрудника по-прежнему сохраняет свою корзину и очередь, чужие строки удаляются', () async {
    await seed();
    await SessionLocalData(db).clearOnSessionEnd(tablet);
    expect((await db.select(db.cartDraft).get()).map((CartDraftRow r) => r.ownerUserId), <String>[tablet]);
    expect((await db.select(db.outboxActions).get()).map((OutboxActionRow r) => r.ownerUserId).toSet(), <String>{
      tablet,
    });
    expect(await db.select(db.localRecentProducts).get(), hasLength(1), reason: 'недавние сотрудника не трогаются');
    expect(
      (await db.select(db.localSettings).get()).map((SettingRow r) => r.key),
      isNot(contains('search_history')),
      reason: 'scope=user удаляется, как прежде',
    );
    expect(
      (await db.select(db.localSettings).get()).map((SettingRow r) => r.key),
      contains('catalog_view_mode.medium'),
      reason: 'вид каталога сотрудника (scope=device) остаётся',
    );
  });

  test('ключи очистки совпадают с ключами каталога и очереди корзины (core не импортирует фичи)', () {
    expect(SessionLocalData.kioskVolatileSettings, <String>[
      CatalogSettingKeys.searchHistory,
      CatalogSettingKeys.lastRoot,
    ]);
    for (final String key in <String>[
      CatalogSettingKeys.viewMode('medium'),
      CatalogSettingKeys.sort(search: true),
      CatalogSettingKeys.sort(search: false),
    ]) {
      expect(SessionLocalData.kioskVolatileSettingPrefixes.any(key.startsWith), isTrue, reason: key);
    }
    expect(SessionLocalData.kioskVolatileMeta, <String>[DriftCartSync.conflictMetaKey, DriftCartSync.replaceMetaKey]);
    expect(SessionLocalData.kioskVolatileMeta, isNot(contains(KioskCartSync.pendingResetMetaKey)));
  });
}
