// Этап F (основа), 07 §11.2/§11.4: DAO черновика оформления (ключ `POST /orders` один на попытку и переживает
// перезапуск — DATA-263; без ПДн), черновика корзины (ответ сервера — истина, `pending`-строки не теряются, владелец
// `owner_user_id` — D-32, DATA-253), кэша уведомлений (≤ 100, DATA-258) и настроек (EQ-CAT-05); полезные нагрузки
// очереди `cart.sync` и `auth.logout` (без секретов). SQLite в памяти, синтетические данные.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/cart_draft_dao.dart';
import 'package:optomstroy/core/database/daos/checkout_draft_dao.dart';
import 'package:optomstroy/core/database/daos/notifications_cache_dao.dart';
import 'package:optomstroy/core/database/daos/settings_dao.dart';
import 'package:optomstroy/core/sync/outbox_payloads.dart';
import 'package:optomstroy/core/utils/qty.dart';

import 'test_database.dart';

const String userA = '00000000-0000-4000-8000-00000000000a';
const String userB = '00000000-0000-4000-8000-00000000000b';

void main() {
  configureSqliteForTests();
  late AppDatabase db;
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  group('CheckoutDraftDao', () {
    test('ensureOrderKey: один ключ на попытку (двойное нажатие CTA), выбор сохраняется отдельно', () async {
      final CheckoutDraftDao dao = CheckoutDraftDao(db);
      final String k1 = await dao.ensureOrderKey('cart-1', newKey: 'key-1', nowMs: 1);
      final String k2 = await dao.ensureOrderKey('cart-1', newKey: 'key-2', nowMs: 2);
      expect((k1, k2), ('key-1', 'key-1'));
      await dao.upsertSelection(localCartId: 'cart-1', step: 'payment', nowMs: 3, paymentMethod: 'qr_bakai');
      final CheckoutDraftRow row = (await dao.find('cart-1'))!;
      expect((row.step, row.paymentMethod, row.orderIdempotencyKey), ('payment', 'qr_bakai', 'key-1'));
      expect(await dao.submittedPending(), isEmpty);
      await dao.markSubmitted('cart-1', nowMs: 4);
      expect((await dao.submittedPending()).single.orderIdempotencyKey, 'key-1');
      await dao.delete('cart-1');
      expect(await dao.find('cart-1'), isNull);
    });

    test('схема checkout_draft не содержит столбцов ПДн получателя и платёжных данных', () async {
      final List<String> columns = <String>[
        for (final row in await db.customSelect('PRAGMA table_info(checkout_draft)').get()) row.read<String>('name'),
      ];
      for (final String forbidden in <String>['address', 'phone', 'receiver_name', 'amount', 'qr', 'qr_payload']) {
        expect(columns.any((String c) => c.contains(forbidden)), isFalse, reason: forbidden);
      }
    });
  });

  group('CartDraftDao', () {
    Future<void> seed() async {
      await db
          .into(db.cartDraft)
          .insert(
            CartDraftCompanion.insert(
              localId: 'cart-1',
              status: 'active',
              ownerUserId: userA,
              updatedAt: 1,
              dirty: const Value(true),
            ),
          );
      for (final (String id, String variant, String state) in <(String, String, String)>[
        ('i-1', 'v-1', 'synced'),
        ('i-2', 'v-2', 'pending'),
        ('i-3', 'v-3', 'pending'),
      ]) {
        await db
            .into(db.cartItemsDraft)
            .insert(
              CartItemsDraftCompanion.insert(
                localItemId: id,
                localCartId: 'cart-1',
                variantId: variant,
                quantityMilli: 1000,
                lineNo: int.parse(id.substring(2)),
                ownerUserId: userA,
                syncState: Value(state),
              ),
            );
      }
    }

    test(
      'applyServer: сервер — истина; pending-строки (запись cart.sync в очереди) сохраняют целевое количество',
      () async {
        await seed();
        final CartDraftDao dao = CartDraftDao(db, ownerUserId: userA);
        final CartDraftRow cart = await dao.applyServer(
          'cart-1',
          const ServerCartSnapshot(
            serverId: 'srv-1',
            status: 'active',
            rowVersion: 12,
            warehouseId: 'w-1',
            discountPercentHundredths: 500,
            lines: <ServerCartLine>[
              ServerCartLine(variantId: 'v-1', quantityMilli: 4000, unitId: 'u-1', priceSnapshotTyiyn: 285000),
              ServerCartLine(variantId: 'v-2', quantityMilli: 9000, unitId: 'u-1', priceChanged: true),
              ServerCartLine(variantId: 'v-9', packagingId: 'p-6', quantityMilli: 2000, unitId: 'u-6'),
            ],
          ),
          nowMs: 100,
        );
        expect((cart.serverId, cart.baseRowVersion, cart.serverSyncedAt, cart.dirty), ('srv-1', 12, 100, true));
        final Map<String, CartItemDraftRow> byVariant = <String, CartItemDraftRow>{
          for (final CartItemDraftRow r in await dao.items('cart-1')) r.variantId: r,
        };
        expect(byVariant.keys, unorderedEquals(<String>['v-1', 'v-2', 'v-3', 'v-9']));
        expect(
          (byVariant['v-1']!.quantityMilli, byVariant['v-1']!.syncState, byVariant['v-1']!.unitId),
          (4000, 'synced', 'u-1'),
        );
        // v-2: локальное целевое количество 1000 не перезаписано ответом (запись ещё не отправлена); снимки — сервера.
        expect(
          (byVariant['v-2']!.quantityMilli, byVariant['v-2']!.syncState, byVariant['v-2']!.priceChanged),
          (1000, 'pending', true),
        );
        expect(byVariant['v-3']!.lineNo, 4);
        expect((byVariant['v-9']!.packagingId, byVariant['v-9']!.syncState), ('p-6', 'synced'));
        expect(await dao.hasUnsentChanges(), isTrue);
      },
    );

    test('без keepPending ответ заменяет все строки; владелец B не видит и не меняет корзину A', () async {
      await seed();
      final CartDraftDao other = CartDraftDao(db, ownerUserId: userB);
      expect(await other.activeCart(), isNull);
      expect(await other.items('cart-1'), isEmpty);
      expect(await other.hasUnsentChanges(), isFalse);
      final CartDraftDao dao = CartDraftDao(db, ownerUserId: userA);
      await dao.applyServer(
        'cart-1',
        const ServerCartSnapshot(serverId: 'srv-1', status: 'active', rowVersion: 2, lines: <ServerCartLine>[]),
        nowMs: 5,
        keepPending: false,
      );
      expect(await dao.items('cart-1'), isEmpty);
      expect((await dao.activeCart())!.dirty, isFalse);
      await dao.setBaseRowVersion('cart-1', 3, nowMs: 6);
      expect((await dao.activeCart())!.baseRowVersion, 3);
      await dao.deleteCart('cart-1');
      expect(await dao.activeCart(), isNull);
    });

    test('setItemSyncState(dead) → строка «не отправлено»', () async {
      await seed();
      final CartDraftDao dao = CartDraftDao(db, ownerUserId: userA);
      await dao.setItemSyncState('cart-1', 'v-1', null, 'dead');
      expect(
        (await dao.unsentItems('cart-1')).map((CartItemDraftRow r) => r.variantId),
        unorderedEquals(<String>['v-1', 'v-2', 'v-3']),
      );
    });
  });

  group('NotificationsCacheDao', () {
    test('чувствительные виды без body; кэш ≤ 100; локальное прочтение не теряется', () async {
      final NotificationsCacheDao dao = NotificationsCacheDao(db);
      await dao.upsertFromServer(<NotificationCacheEntry>[
        for (int i = 0; i < 105; i++)
          NotificationCacheEntry(
            id: 'n-$i',
            kind: i == 104 ? 'credit_blocked' : 'order_status',
            severity: 'info',
            title: 't$i',
            body: 'b$i',
            payload: <String, Object?>{'orderId': 'o-$i', 'amount': '100.00'},
            createdAtMs: i,
          ),
      ]);
      final List<NotificationCacheRow> rows = await db.select(db.notificationsCache).get();
      expect(rows, hasLength(NotificationsCacheDao.limit));
      expect(rows.any((NotificationCacheRow r) => r.id == 'n-0'), isFalse);
      final NotificationCacheRow credit = rows.firstWhere((NotificationCacheRow r) => r.id == 'n-104');
      expect((credit.body, credit.payloadJson), (null, '{"orderId":"o-104"}'));
      await dao.markRead('n-104', nowMs: 999);
      await dao.upsertFromServer(<NotificationCacheEntry>[
        const NotificationCacheEntry(
          id: 'n-104',
          kind: 'credit_blocked',
          severity: 'warning',
          title: 't',
          createdAtMs: 104,
        ),
      ]);
      expect((await (db.select(db.notificationsCache)..where((t) => t.id.equals('n-104'))).getSingle()).readAt, 999);
      expect(await dao.watchUnreadCount().first, 99);
      await dao.markAllRead(nowMs: 1000);
      expect(await dao.watchUnreadCount().first, 0);
    });
  });

  test('SettingsDao: значение по ключу, область user очищается отдельно (EQ-CAT-05)', () async {
    final SettingsDao dao = SettingsDao(db);
    await dao.write(SettingsDao.catalogViewKey('expanded'), '"grid"', scope: SettingScope.user, nowMs: 1);
    await dao.write('scanner.wedge', '{"ms":35}', scope: SettingScope.device, nowMs: 1);
    expect(await dao.read('catalog.view.expanded'), '"grid"');
    await dao.clearUserScope();
    expect(await dao.read('catalog.view.expanded'), isNull);
    expect(await dao.read('scanner.wedge'), '{"ms":35}');
  });

  group('полезные нагрузки очереди', () {
    test('cart.sync: целевое количество, ключ сжатия пары, разбор', () {
      final CartSyncPayload set = CartSyncPayload.setItem(
        localCartId: 'c-1',
        variantId: 'v-1',
        unitId: 'u-1',
        quantity: Qty.units(6),
        packagingId: 'p-6',
      );
      final CartSyncPayload del = CartSyncPayload.deleteItem(localCartId: 'c-1', variantId: 'v-1', packagingId: 'p-6');
      expect(set.coalesceKey, del.coalesceKey);
      expect(set.toJson(), <String, Object?>{
        'op': 'set_item',
        'localCartId': 'c-1',
        'variantId': 'v-1',
        'packagingId': 'p-6',
        'unitId': 'u-1',
        'quantityMilli': 6000,
      });
      final CartSyncPayload parsed = CartSyncPayload.tryParse(set.toJson())!;
      expect((parsed.op, parsed.quantity, parsed.packagingId), (CartSyncOp.setItem, Qty.units(6), 'p-6'));
      expect(CartSyncPayload.tryParse(<String, Object?>{'op': 'increment', 'localCartId': 'c-1'}), isNull);
      expect(CartSyncPayload.tryParse(<String, Object?>{'op': 'set_item', 'localCartId': 'c-1'}), isNull);
      expect(
        CartSyncPayload.setDiscount(localCartId: 'c-1', discountPercentHundredths: 500).coalesceKey,
        'discount:c-1',
      );
    });

    test('auth.logout: только sid и время, без токенов', () {
      final AuthLogoutPayload p = AuthLogoutPayload(requestedAt: DateTime.utc(2026, 10, 22, 9), sessionId: 's-1');
      expect(p.toJson(), <String, Object?>{'requestedAt': '2026-10-22T09:00:00.000Z', 'sessionId': 's-1'});
      expect(AuthLogoutPayload.tryParse(p.toJson())!.sessionId, 's-1');
      expect(p.toJson().keys.any((String k) => k.toLowerCase().contains('token')), isFalse);
      expect(AuthLogoutPayload.tryParse(const <String, Object?>{}), isNull);
    });
  });
}
