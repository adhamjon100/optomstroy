// Корзина планшета магазина — только на сервере (ADR-115; 02 SCR-51 UI-51-010…UI-51-013; 04 FLOW-044.S2, FLOW-045;
// 07 §11.2, DATA-304; 10 KIOSK-009, KIOSK-020, KIOSK-025; 11 PRIV-033 (2); 13 TAB-2-12).
// - `KioskCartSync` на фейковом сервере и drift в памяти: каждое изменение — прямой
//   `PUT/DELETE /cart/items/{variantId}` (`mode=increment` с ключом для «В корзину», `mode=set` для степпера,
//   `DELETE ?packagingId=` для строки упаковки);
//   в drift нет строк корзины, оформления, недавних и записей очереди; без связи изменение отклоняется и никуда не
//   встаёт; сброс без сети — метка только с id корзины, старая корзина не показывается, после связи — новая пустая;
//   `409 VERSION_CONFLICT` — один повтор с версией сервера; запуск очищает строки покупателя до первого запроса.
// - Корень: роль `kiosk` → корзина планшета для `cartSyncProvider` и `cartDraftRepositoryProvider`, сотрудник — прежние
//   `DriftCartSync` и `CartDraftLocalRepository`; «Оформить заявку» → SCR-52; «В корзину» без связи — «Корзина не
//   сохранена».
// - Drawer планшета: без «Клиента», склада, скидки, «Отложить · F8», «Отложенных» и «Очистить»; `F4`/`F8`/`F9` не
//   действуют; «Договорные цены применит кассир» под итогом; «Оформить заявку» → SCR-52, «Назад» — открытый drawer;
//   без связи — только чтение.
// Тест-кейсы 12_TEST_PLAN: T-KIOSK-029 (корзина), T-KIOSK-042 (экран), T-KIOSK-061. Синтетические данные.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/di/catalog_cart_adapter.dart';
import 'package:optomstroy/app/di/overrides.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/app_meta_dao.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/session/session_overlay.dart' show KioskStatus, kioskStatusProvider;
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/cart_summary.dart';
import 'package:optomstroy/design_system/components/discount_input.dart';
import 'package:optomstroy/design_system/components/quantity_stepper.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/data/cart_bindings.dart';
import 'package:optomstroy/features/cart/data/draft/cart_draft_bindings.dart';
import 'package:optomstroy/features/cart/data/draft/cart_draft_local_repository.dart';
import 'package:optomstroy/features/cart/data/draft/kiosk_cart_draft_repository.dart';
import 'package:optomstroy/features/cart/data/sync/drift_cart_sync.dart';
import 'package:optomstroy/features/cart/data/sync/kiosk_cart_sync.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/cart/presentation/kiosk_cart_rejection.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_controller.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_drawer.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_header_button_view.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_panel_view.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart' as catalog;
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/customers/data/customers_bindings.dart';
import 'package:optomstroy/features/product_details/presentation/notifiers/product_details_notifier.dart';

import '../../core/database/test_database.dart';
import '../../support/f_fakes.dart';
import '../product_details/product_fixtures.dart' hide box;

/// Технический пользователь планшета (синтетический UUID).
const String tablet = '00000000-0000-4000-8000-0000000000c1';
const CartLineKey v1 = CartLineKey('v-1');
const CartLineKey v2 = CartLineKey('v-2');
const CartLineKey box = CartLineKey('v-1', 'pk-box');

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

CartLine line(String variantId, Qty quantity, {String unitId = 'u-pc', String? packagingId}) => CartLine(
  variantId: variantId,
  productId: 'p-$variantId',
  productName: 'Смеситель $variantId',
  quantity: LineQuantity(value: quantity, unitId: unitId, packagingId: packagingId),
  unitPrice: Money.som(1650),
  lineTotal: Money.som(1650),
);

/// Сервер корзины планшета: `GET /cart`, `PUT` `set`/`increment` с проверкой `rowVersion`, `DELETE` строки,
/// `POST /kiosk/reset` — новая пустая корзина с новым id.
final class _Server {
  _Server(this.repo) {
    repo.onFetch = () async {
      fetches++;
      return Success<Cart>(cart);
    };
    repo.onPutItem = (String variantId, CartItemPut put, String? key) async {
      puts.add(put);
      keys.add(key);
      if (put.rowVersion != cart.rowVersion) {
        return const FailureResult<Cart>(ConflictFailure(ConflictKind.versionConflict));
      }
      final String? packagingId = put.quantity.packagingId;
      final Qty before = _quantity(variantId, packagingId);
      final Qty next = put.mode == CartPutMode.increment ? before + put.quantity.value : put.quantity.value;
      _set(variantId, packagingId, next, put.quantity.unitId);
      return Success<Cart>(cart);
    };
    repo.onDeleteItem = (String variantId, String? packagingId) async {
      deletes.add('$variantId|$packagingId');
      _set(variantId, packagingId, Qty.zero, 'u-pc');
      return Success<Cart>(cart);
    };
    // problem+json `409 VERSION_CONFLICT` несёт `current: Cart` (08 §4.7.2).
    repo.onConflictCurrent = (Failure f) => f is ConflictFailure ? cart : null;
  }

  final FakeCartRepository repo;
  Cart cart = const Cart(id: 'cart-1', status: CartStatus.active, items: <CartLine>[], rowVersion: 5);
  int fetches = 0;
  final List<CartItemPut> puts = <CartItemPut>[];
  final List<String?> keys = <String?>[];
  final List<String> deletes = <String>[];
  final List<String?> resets = <String?>[];

  Qty _quantity(String variantId, String? packagingId) {
    for (final CartLine l in cart.items) {
      if (l.variantId == variantId && l.packagingId == packagingId) return l.quantity.value;
    }
    return Qty.zero;
  }

  void _set(String variantId, String? packagingId, Qty quantity, String unitId) {
    final bool exists = cart.items.any((CartLine l) => l.variantId == variantId && l.packagingId == packagingId);
    final List<CartLine> items = <CartLine>[
      for (final CartLine l in cart.items)
        if (!(l.variantId == variantId && l.packagingId == packagingId))
          l
        else if (!quantity.isZero)
          line(variantId, quantity, unitId: unitId, packagingId: packagingId),
      if (!exists && !quantity.isZero) line(variantId, quantity, unitId: unitId, packagingId: packagingId),
    ];
    cart = Cart(id: cart.id, status: CartStatus.active, items: items, rowVersion: cart.rowVersion + 1);
  }

  /// Корзину изменил сервер (пересчёт): версия снимка устарела.
  void bump() =>
      cart = Cart(id: cart.id, status: CartStatus.active, items: cart.items, rowVersion: cart.rowVersion + 1);

  /// `POST /kiosk/reset {cartId}` → новая пустая корзина (08 §4.25.4).
  Future<Result<Cart>> reset(String? cartId) async {
    resets.add(cartId);
    cart = Cart(id: 'cart-${resets.length + 1}', status: CartStatus.active, items: const <CartLine>[], rowVersion: 1);
    return Success<Cart>(cart);
  }
}

Future<void> seedCatalog(AppDatabase db) async {
  await db
      .into(db.localUnits)
      .insert(
        LocalUnitsCompanion.insert(
          code: 'pc',
          name: 'Штука',
          qtyPrecision: 0,
          id: const Value<String?>('u-pc'),
          shortName: const Value<String?>('шт'),
        ),
      );
  await db
      .into(db.localUnits)
      .insert(
        LocalUnitsCompanion.insert(
          code: 'm',
          name: 'Метр',
          qtyPrecision: 1,
          id: const Value<String?>('u-m'),
          shortName: const Value<String?>('м'),
        ),
      );
  for (final (String id, String unit, int? multiplicity, int? min) in <(String, String, int?, int?)>[
    ('1', 'pc', null, null),
    ('2', 'm', 500, 3000),
  ]) {
    await db
        .into(db.localProducts)
        .insert(
          LocalProductsCompanion.insert(
            id: 'p-v-$id',
            sku: 'SKU-$id',
            skuNorm: 'sku$id',
            name: 'Смеситель v-$id',
            nameNorm: 'смеситель v-$id',
            baseUnitCode: unit,
            qtyPrecision: unit == 'm' ? 1 : 0,
            serverUpdatedAt: 1,
            baseUnitId: Value<String?>('u-$unit'),
            multiplicityMilli: Value<int?>(multiplicity),
            minQtyMilli: Value<int?>(min),
          ),
        );
    await db
        .into(db.localProductVariants)
        .insert(
          LocalProductVariantsCompanion.insert(id: 'v-$id', productId: 'p-v-$id', name: 'Хром', serverUpdatedAt: 1),
        );
  }
  await db
      .into(db.localPackagings)
      .insert(
        LocalPackagingsCompanion.insert(
          id: 'pk-box',
          productId: 'p-v-1',
          unitCode: 'box',
          name: 'кор',
          factorMilli: 6000,
          unitId: const Value<String?>('u-box'),
        ),
      );
}

/// Записи покупателя в drift (их не должно быть ни в какой момент).
Future<Map<String, int>> buyerRows(AppDatabase db) async => <String, int>{
  'cart_draft': (await db.select(db.cartDraft).get()).length,
  'cart_items_draft': (await db.select(db.cartItemsDraft).get()).length,
  'outbox_actions': (await db.select(db.outboxActions).get()).length,
  'recent_products': (await db.select(db.localRecentProducts).get()).length,
  'checkout_draft': (await db.select(db.checkoutDraft).get()).length,
};

/// Ключи `app_meta`, кроме служебного `schema_version` (пишет миграция drift).
Future<List<(String, String)>> metaRows(AppDatabase db) async => <(String, String)>[
  for (final AppMetaRow r in await db.select(db.appMeta).get())
    if (r.key != AppMetaDao.schemaVersionKey) (r.key, r.value),
];

const Map<String, int> noBuyerRows = <String, int>{
  'cart_draft': 0,
  'cart_items_draft': 0,
  'outbox_actions': 0,
  'recent_products': 0,
  'checkout_draft': 0,
};

void main() {
  configureSqliteForTests();

  group('KioskCartSync', () {
    late AppDatabase db;
    late FakeCartRepository repo;
    late _Server server;
    late bool offline;
    late int keySeq;

    KioskCartSync build() => KioskCartSync(
      database: () => db,
      owner: () => tablet,
      repository: repo,
      offline: () => offline,
      newKey: () => 'key-${++keySeq}',
    );

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      repo = FakeCartRepository();
      server = _Server(repo);
      offline = false;
      keySeq = 0;
      await seedCatalog(db);
    });
    tearDown(() => db.close());

    test('T-KIOSK-029 no cart_draft/cart_items_draft/recent_products/checkout_draft/outbox rows: «В корзину», степпер, '
        'карточка товара, удаление — прямые запросы, в drift ничего; запуск удаляет оставшиеся строки до первого '
        'запроса', () async {
      // Защита на случай ошибки (FLOW-045.A2): строки покупателя, оставшиеся в файле планшета.
      await db
          .into(db.cartDraft)
          .insert(CartDraftCompanion.insert(localId: 'old', status: 'active', ownerUserId: tablet, updatedAt: 1));
      await db
          .into(db.outboxActions)
          .insert(
            OutboxActionsCompanion.insert(
              type: 'cart.sync',
              payloadJson: '{}',
              idempotencyKey: 'old-key',
              ownerUserId: tablet,
              createdAt: 1,
            ),
          );
      await db
          .into(db.localRecentProducts)
          .insert(LocalRecentProductsCompanion.insert(productId: 'p-1', lastViewedAt: 1));
      final List<Map<String, int>> atFirstRequest = <Map<String, int>>[];
      repo.onFetch = () async {
        atFirstRequest.add(await buyerRows(db));
        server.fetches++;
        return Success<Cart>(server.cart);
      };
      final KioskCartSync sync = build();
      addTearDown(sync.dispose);

      expect((await sync.refresh()).isSuccess, isTrue);
      expect(atFirstRequest.single, noBuyerRows, reason: 'очистка — до первого запроса корзины');

      // «В корзину» каталога: `mode=increment` с ключом, шаг 1 шт, единица — из кэша каталога.
      final Result<Qty> added = await sync.addStep(v1, priceSnapshot: Money.som(1650));
      expect(added.valueOrNull, Qty.units(1));
      expect(
        (server.puts.last.mode, server.puts.last.quantity.value, server.puts.last.quantity.unitId),
        (CartPutMode.increment, Qty.units(1), 'u-pc'),
      );
      expect(server.puts.last.priceSnapshot, Money.som(1650), reason: 'цена карточки — только для новой строки');
      expect(server.keys.last, isNotNull, reason: '`mode=increment` без Idempotency-Key — 400');

      // Первое добавление метража — не меньше минимальной партии (INV-004/005): 3 м, затем шаг 0,5 м.
      expect((await sync.addStep(v2)).valueOrNull, Qty.units(3));
      expect((await sync.addStep(v2)).valueOrNull, Qty.fromString('3.5'));
      expect(server.puts.last.quantity.unitId, 'u-m');

      // Степпер drawer: `mode=set` с версией из ответа предыдущего запроса.
      final int version = server.cart.rowVersion;
      expect((await sync.setQuantity(v1, Qty.units(4))).isSuccess, isTrue);
      expect((server.puts.last.mode, server.puts.last.rowVersion), (CartPutMode.set, version));

      // Карточка товара SCR-14: порт черновика пишет прямым запросом, склада у планшета нет.
      final KioskCartDraftRepository draft = KioskCartDraftRepository(sync);
      expect((await draft.warehouseId()).valueOrNull, isNull);
      final Result<CartDraftLine> boxLine = await draft.add(
        CartDraftAdd(variantId: 'v-1', packagingId: 'pk-box', quantity: Qty.units(2)),
      );
      expect((boxLine.valueOrNull?.quantity, boxLine.valueOrNull?.packagingId), (Qty.units(2), 'pk-box'));
      expect((server.puts.last.mode, server.puts.last.quantity.unitId), (CartPutMode.increment, 'u-box'));
      expect((await draft.lines()).valueOrNull!.map((CartDraftLine l) => l.variantId), <String>['v-1', 'v-2', 'v-1']);

      // Удаление: строка упаковки — `DELETE ?packagingId=`, строка базовой единицы — `PUT set 0`.
      expect((await draft.setQuantity('v-1', packagingId: 'pk-box', quantity: Qty.zero)).isSuccess, isTrue);
      expect(server.deletes.single, 'v-1|pk-box');
      expect((await sync.setQuantity(v2, Qty.zero)).isSuccess, isTrue);
      expect((server.puts.last.mode, server.puts.last.quantity.value), (CartPutMode.set, Qty.zero));
      expect(server.cart.items.map((CartLine l) => l.variantId), <String>['v-1']);

      // Снимок — в памяти: подписи и правила строк из кэша каталога.
      final CartLocalSnapshot local = (await sync.loadLocal()).valueOrNull!;
      expect(local.serverId, 'cart-1');
      expect(local.warehouseId, isNull);
      expect((local.line(v1)!.quantity, local.line(v1)!.syncState), (Qty.units(4), CartDraftSyncState.synced));
      expect(local.line(v1)!.unitLabel, 'шт', reason: 'строка без упаковки: подпись единицы — из кэша каталога');
      expect((local.line(v1)!.step, local.line(v1)!.qtyPrecision), (null, 0), reason: 'кратности нет — шаг 1 у экрана');

      expect(await buyerRows(db), noBuyerRows);
      expect(await metaRows(db), isEmpty, reason: 'ни конфликта, ни журнала смены варианта, ни метки');
      expect((await sync.sync()).isSuccess, isTrue);
      expect(sync.conflict, isNull);
      expect(await sync.watchStatus().first, CartSyncStatus.idle);
      expect((await sync.warehouses()).valueOrNull, isEmpty);
    });

    test('T-KIOSK-061 offline add disabled, nothing queued, new cart empty after reset: без связи — отказ без запроса; '
        'сброс без сети — метка только с id корзины, корзина на экране пуста; после связи — POST /kiosk/reset и новая '
        'пустая корзина, товар прошлого покупателя не появился', () async {
      final KioskCartSync sync = build();
      addTearDown(sync.dispose);
      await sync.refresh();
      expect((await sync.addStep(v1)).isSuccess, isTrue);
      final int requests = server.puts.length + server.fetches;

      // Сеть пропала во время «В корзину».
      offline = true;
      final Result<Qty> refused = await sync.addStep(v1);
      expect(refused.failureOrNull, isA<NetworkFailure>());
      expect(server.puts.length + server.fetches, requests, reason: 'запроса нет');
      expect((await sync.refresh()).failureOrNull, isA<NetworkFailure>());
      expect(await buyerRows(db), noBuyerRows, reason: 'в очередь ничего не встало');

      // Автосброс без сети: метка — только id корзины, корзина на экране пуста, изменения недоступны.
      final int before = sync.generation;
      final Result<Cart> offlineReset = await sync.reset(server.reset);
      expect(offlineReset.failureOrNull, isA<NetworkFailure>());
      expect(server.resets, isEmpty);
      expect(sync.generation, greaterThan(before), reason: 'новое поколение — экран корзины строится заново');
      expect(sync.pendingResetCartId, 'cart-1');
      expect(sync.cartId, isNull);
      expect(await metaRows(db), <(String, String)>[(KioskCartSync.pendingResetMetaKey, 'cart-1')]);
      expect((await sync.loadLocal()).valueOrNull!.lines, isEmpty);

      // Связь вернулась: пока сервер не подтвердил сброс, старая корзина не загружается и не меняется.
      offline = false;
      final int fetches = server.fetches;
      final Result<Cart> held = await sync.refresh();
      expect((held.failureOrNull as UnknownFailure?)?.cause, isA<KioskCartResetPending>());
      expect(server.fetches, fetches, reason: 'первым запросом при связи идёт сброс, а не GET /cart');
      expect((await sync.addStep(v1)).failureOrNull, isA<UnknownFailure>());
      expect(server.puts.length, 1);

      // «Перезапуск» с меткой: новый объект над тем же файлом — корзина пуста до сброса.
      final KioskCartSync restarted = build();
      addTearDown(restarted.dispose);
      expect((await restarted.loadLocal()).valueOrNull!.lines, isEmpty);
      expect(restarted.pendingResetCartId, 'cart-1');
      expect((await restarted.refresh()).isSuccess, isFalse);
      expect(server.fetches, fetches);

      final Result<Cart> r = await restarted.reset(server.reset);
      expect(server.resets, <String?>['cart-1'], reason: 'POST /kiosk/reset с id сброшенной корзины');
      expect(r.valueOrNull?.id, 'cart-2');
      expect(restarted.pendingResetCartId, isNull);
      expect(await metaRows(db), isEmpty, reason: 'метка снята после 200');
      final CartLocalSnapshot fresh = (await restarted.loadLocal()).valueOrNull!;
      expect(fresh.serverId, 'cart-2');
      expect(fresh.lines, isEmpty);
      expect((await restarted.refresh()).valueOrNull?.items, isEmpty, reason: 'товар прошлого покупателя не появился');
      expect(await buyerRows(db), noBuyerRows, reason: 'запросов cart.sync и строк очереди нет');
    });

    test('сброс со связью: после идущего изменения, новая корзина, повтор с тем же cartId сервер принимает', () async {
      final KioskCartSync sync = build();
      addTearDown(sync.dispose);
      await sync.refresh();
      expect((await sync.addStep(v1)).isSuccess, isTrue);
      // Нажатие «+» и сброс одновременно: изменение, не успевшее уйти до сброса, в новую корзину не попадает.
      final Future<Result<Qty>> adding = sync.addStep(v1);
      final Future<Result<Cart>> reset = sync.reset(server.reset);
      expect(((await adding).failureOrNull as UnknownFailure?)?.cause, isA<KioskCartResetPending>());
      expect((await reset).valueOrNull?.items, isEmpty);
      expect(server.cart.items, isEmpty);
      expect(server.puts, hasLength(1), reason: 'в прежнюю корзину ушло только первое добавление');
      expect(server.resets, <String?>['cart-1']);
      expect(sync.cartId, 'cart-2');
      expect((await sync.loadLocal()).valueOrNull!.lines, isEmpty);
      expect(await metaRows(db), isEmpty);
    });

    test(
      '409 VERSION_CONFLICT той же корзины — один повтор с версией сервера; корзина сменилась — без переноса',
      () async {
        final KioskCartSync sync = build();
        addTearDown(sync.dispose);
        await sync.refresh();
        server.bump();
        expect((await sync.addStep(v1)).valueOrNull, Qty.units(1));
        expect(server.puts.map((CartItemPut p) => p.rowVersion), <int>[5, 6]);
        expect(server.keys.toSet(), hasLength(2), reason: 'тело другое — новый ключ');

        // Сервер закрыл корзину (сброс с другого шага): изменение в новую корзину не переносится.
        server.cart = const Cart(id: 'cart-9', status: CartStatus.active, items: <CartLine>[], rowVersion: 1);
        final Result<void> r = await sync.setQuantity(v1, Qty.units(3));
        expect(r.failureOrNull, isA<ConflictFailure>());
        expect(server.cart.items, isEmpty);
        expect((await sync.loadLocal()).valueOrNull!.serverId, 'cart-9');
      },
    );

    test(
      'пока ответа нет — строка «предварительно» с целевым количеством; ошибка — значение сервера и CartSyncRejected',
      () async {
        final KioskCartSync sync = build();
        addTearDown(sync.dispose);
        await sync.refresh();
        await sync.addStep(v1);
        final List<CartSyncEvent> events = <CartSyncEvent>[];
        final StreamSubscription<CartSyncEvent> sub = sync.events.listen(events.add);
        addTearDown(sub.cancel);
        final List<CartLocalSnapshot?> snapshots = <CartLocalSnapshot?>[];
        final StreamSubscription<CartLocalSnapshot?> localSub = sync.watchLocal().listen(snapshots.add);
        addTearDown(localSub.cancel);
        repo.onPutItem = (String variantId, CartItemPut put, String? key) async =>
            const FailureResult<Cart>(NetworkFailure(NetworkFailureKind.timeout));
        final Result<void> r = await sync.setQuantity(v1, Qty.units(5));
        expect(r.failureOrNull, isA<NetworkFailure>());
        await Future<void>.delayed(Duration.zero);
        expect(
          snapshots.map((CartLocalSnapshot? s) => (s?.line(v1)?.quantity, s?.line(v1)?.syncState)),
          containsAllInOrder(<Object?>[
            (Qty.units(5), CartDraftSyncState.pending),
            (Qty.units(1), CartDraftSyncState.synced),
          ]),
        );
        await Future<void>.delayed(Duration.zero);
        expect(events.whereType<CartSyncRejected>().single.key, v1);
        expect(await buyerRows(db), noBuyerRows);
      },
    );

    test('варианта нет ни в корзине, ни в кэше — отказ без запроса (единица строки неизвестна)', () async {
      final KioskCartSync sync = build();
      addTearDown(sync.dispose);
      await sync.refresh();
      final Result<Qty> r = await sync.addStep(const CartLineKey('v-unknown'));
      expect((r.failureOrNull as UnknownFailure?)?.cause, isA<KioskCartUnitUnknown>());
      expect(server.puts, isEmpty);
    });

    test('порт: новый объект на каждое поколение, один снимок', () async {
      final KioskCartSync sync = build();
      addTearDown(sync.dispose);
      final CartSync a = sync.port();
      final CartSync b = sync.port();
      expect(identical(a, b), isFalse);
      await a.refresh();
      await b.addStep(v1);
      expect((await a.loadLocal()).valueOrNull!.line(v1)?.quantity, Qty.units(1));
    });

    test('UI-51-018 отметка «Товара стало меньше…»: видна, пока корзина той же версии; GET /cart той же версии её не '
        'снимает, изменение и сброс снимают; без корзины на экране и при метке сброса — без действия', () async {
      final KioskCartSync sync = build();
      addTearDown(sync.dispose);
      final List<bool> notices = <bool>[];
      final StreamSubscription<bool> sub = sync.stockNotices.listen(notices.add);
      addTearDown(sub.cancel);
      sync.markStockChanged();
      expect(sync.stockChanged, isFalse, reason: 'корзины на экране ещё нет');

      await sync.refresh();
      await sync.addStep(v1);
      // Возврат из SCR-52 по отказу: корзина уже перечитана.
      sync.markStockChanged();
      expect(sync.stockChanged, isTrue);
      await sync.refresh();
      expect(sync.stockChanged, isTrue, reason: 'та же корзина той же версии');
      await sync.addStep(v1);
      expect(sync.stockChanged, isFalse, reason: 'изменение корзины — новая версия');
      await sync.refresh();
      expect(sync.stockChanged, isFalse, reason: 'снятая отметка не возвращается');

      sync.markStockChanged();
      expect(sync.stockChanged, isTrue);
      expect((await sync.reset(server.reset)).isSuccess, isTrue);
      expect(sync.stockChanged, isFalse, reason: 'сброс — новая корзина');

      sync.markStockChanged();
      offline = true;
      await sync.reset(server.reset);
      expect(sync.pendingResetCartId, 'cart-2');
      expect(sync.stockChanged, isFalse, reason: 'метка сброса без сети: корзина на экране пуста');
      sync.markStockChanged();
      expect(sync.stockChanged, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(notices, <bool>[true, false, true, false, true, false]);
      expect(await metaRows(db), <(String, String)>[(KioskCartSync.pendingResetMetaKey, 'cart-2')]);
    });
  });

  group('корень: корзина планшета по роли', () {
    late AppDatabase db;
    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      await seedCatalog(db);
    });
    tearDown(() => db.close());

    ProviderContainer container(RoleCode role, {OnlineStatus online = OnlineStatus.online}) {
      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[
          dioProvider.overrideWithValue(Dio()),
          appDatabaseProvider.overrideWithValue(db),
          outboxOwnerProvider.overrideWithValue(tablet),
          clockProvider.overrideWithValue(FixedClock(DateTime.utc(2026, 11, 4, 9))),
          cartViewerRoleProvider.overrideWithValue(role),
          cartOnlineStatusProvider.overrideWithValue(online),
          ...customersBindings,
          ...cartBindings,
          ...cartDraftBindings,
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('kiosk → корзина только на сервере и черновик без drift; сотрудник — прежние реализации', () async {
      final ProviderContainer k = container(RoleCode.kiosk);
      expect(k.read(cartSyncProvider), isNot(isA<DriftCartSync>()));
      expect(k.read(cartDraftRepositoryProvider), isA<KioskCartDraftRepository>());
      expect(k.read(kioskCartControlProvider), isA<KioskCartSync>());
      expect(k.read(kioskCartResetPendingProvider), isFalse);

      for (final RoleCode role in <RoleCode>[RoleCode.seller, RoleCode.cashier, RoleCode.customer]) {
        final ProviderContainer s = container(role);
        expect(s.read(cartSyncProvider), isA<DriftCartSync>(), reason: role.value);
        expect(s.read(cartDraftRepositoryProvider), isA<CartDraftLocalRepository>(), reason: role.value);
        expect(s.read(kioskCartControlProvider), isNull, reason: role.value);
        expect(s.read(kioskCartResetPendingProvider), isFalse, reason: role.value);
      }
    });

    test('UI-51-018 корень: отметка «Товара стало меньше…» — только у планшета (порт корзины планшета); сотрудник и '
        'покупатель — без порта и без баннера', () async {
      final ProviderContainer k = container(RoleCode.kiosk);
      final ProviderSubscription<bool> shown = k.listen(kioskCartStockChangedProvider, (_, _) {});
      addTearDown(shown.close);
      expect(k.read(kioskCartMarkStockChangedProvider), k.read(kioskCartSyncProvider).markStockChanged);
      k.read(kioskCartMarkStockChangedProvider)!();
      await Future<void>.delayed(Duration.zero);
      expect(shown.read(), isFalse, reason: 'корзины на экране нет — отмечать нечего');

      for (final RoleCode role in <RoleCode>[RoleCode.seller, RoleCode.cashier, RoleCode.customer]) {
        final ProviderContainer s = container(role);
        expect(s.read(kioskCartMarkStockChangedProvider), isNull, reason: role.value);
        expect(s.read(kioskCartStockChangedProvider), isFalse, reason: role.value);
      }
    });

    test('T-KIOSK-061 метка сброса без сети после перезапуска: новое поколение порта, «В корзину» и оформление '
        'недоступны, без связи POST /kiosk/reset не выполняется', () async {
      await AppMetaDao(db).write(KioskCartSync.pendingResetMetaKey, 'cart-1');
      final ProviderContainer k = container(RoleCode.kiosk, online: OnlineStatus.offline);
      final ProviderSubscription<CartSync> port = k.listen(cartSyncProvider, (_, _) {});
      addTearDown(port.close);
      final ProviderSubscription<bool> pending = k.listen(kioskCartResetPendingProvider, (_, _) {});
      addTearDown(pending.close);
      final CartSync first = port.read();
      final KioskCartControl control = k.read(kioskCartControlProvider)!;
      expect(identical(control, k.read(kioskCartSyncProvider)), isTrue);
      await control.prepare();
      await Future<void>.delayed(Duration.zero);
      expect(control.pendingResetCartId, 'cart-1');
      expect(pending.read(), isTrue);
      expect(identical(port.read(), first), isFalse, reason: 'экран корзины строится заново');
      expect((await port.read().loadLocal()).valueOrNull!.lines, isEmpty);
      expect((await k.read(cartDraftRepositoryProvider).lines()).valueOrNull, isEmpty);

      final List<String?> requested = <String?>[];
      final Result<Cart> r = await control.reset((String? id) async {
        requested.add(id);
        return Success<Cart>(emptyCart(id: 'cart-2'));
      });
      expect(r.failureOrNull, isA<NetworkFailure>());
      expect(requested, isEmpty);
      expect(await AppMetaDao(db).read(KioskCartSync.pendingResetMetaKey), 'cart-1');
      expect(await buyerRows(db), noBuyerRows);
    });

    test(
      'root: «Оформить заявку» → SCR-52 только у планшета; «В корзину» — прямой PUT с единицей карточки, без связи — '
      '«Корзина не сохранена»',
      () async {
        final FakeCartRepository repo = FakeCartRepository();
        final _Server server = _Server(repo);
        bool offline = false;
        final KioskCartSync kiosk = KioskCartSync(
          database: () => null,
          owner: () => null,
          repository: repo,
          offline: () => offline,
        );
        addTearDown(kiosk.dispose);
        for (final (RoleCode role, String? location) in <(RoleCode, String?)>[
          (RoleCode.kiosk, '/kiosk/checkout?step=phone'),
          (RoleCode.customer, null),
          (RoleCode.seller, null),
        ]) {
          final ProviderContainer c = ProviderContainer(
            overrides: <Override>[
              ...cartUiOverrides,
              cartSyncProvider.overrideWithValue(kiosk.port()),
              kioskCartControlProvider.overrideWithValue(role == RoleCode.kiosk ? kiosk : null),
              catalog.catalogViewerRoleProvider.overrideWithValue(role),
              kioskStatusProvider.overrideWithValue(KioskStatus.ready),
              kioskCartResetPendingProvider.overrideWithValue(false),
            ],
          );
          addTearDown(c.dispose);
          expect(c.read(cartCheckoutLocationProvider)?.call('cart-1'), location, reason: role.value);
          expect(c.read(cartOrderingBlockedProvider), isFalse, reason: role.value);
          final CatalogCartPort port = c.read(catalogCartPortProvider)!;
          expect(port is KioskCatalogCartPort, role == RoleCode.kiosk, reason: role.value);
        }

        // Каталог пришёл из сети раньше кэша: единица — из карточки (`ProductSummary.baseUnit`).
        final KioskCatalogCartPort port = KioskCatalogCartPort(kiosk, CartSyncCatalogCartPort(kiosk.port()));
        final ProductSummary card = ProductSummary(
          id: 'p-9',
          name: 'Кран шаровой',
          defaultVariantId: 'v-9',
          baseUnit: const Unit(id: 'u-pc', name: 'штука', qtyPrecision: 0, shortName: 'шт'),
          price: Price(priceListId: 'pl-retail', amount: Money.som(450)),
        );
        expect((await port.add(card)).isSuccess, isTrue);
        final CartItemPut put = server.puts.single;
        expect((put.mode, put.quantity.unitId, put.quantity.value), (CartPutMode.increment, 'u-pc', Qty.units(1)));
        expect(put.priceSnapshot, Money.som(450));
        expect(server.keys.single, isNotNull);

        offline = true;
        final Result<void> refused = await port.add(card);
        expect(server.puts, hasLength(1), reason: 'без связи — без запроса и без очереди');
        expect(port.rejectionText(refused.failureOrNull!, l10n), l10n.cart_header_save_failed);
        expect(
          port.rejectionText(const UnknownFailure(cause: KioskCartResetPending()), l10n),
          l10n.cart_header_save_failed,
        );
        const ValidationFailure maxItems = ValidationFailure(
          errors: <FieldError>[FieldError(field: 'quantity', rule: 'max_items')],
        );
        expect(port.rejectionText(maxItems, l10n), l10n.cart_max_items('200'));
        expect(port.rejectionText(const PermissionFailure(), l10n), isNull);

        // SEC-141 (3) / 08 §2.4 п. 3: в `conflicts[]` планшету — только `variantId`, `kind`, `stockLevel`; текст без
        // чисел сервера и никогда не «Минимальная партия — » с пустым числом.
        for (final (ConflictKind kind, String text) in <(ConflictKind, String)>[
          (ConflictKind.qtyBelowMin, l10n.cart_header_save_failed),
          (ConflictKind.qtyNotMultiple, l10n.cart_header_save_failed),
          (ConflictKind.stockInsufficient, l10n.cart_line_stock_short_customer),
          (ConflictKind.variantUnavailable, l10n.error_variant_unavailable),
        ]) {
          final ConflictFailure sanitized = ConflictFailure(
            kind,
            details: <String, Object?>{
              'conflicts': <Object?>[
                <String, Object?>{'variantId': 'v-9', 'kind': kind.name},
              ],
            },
          );
          final String? shown = port.rejectionText(sanitized, l10n);
          expect(shown, text, reason: kind.name);
          expect(shown, isNot(contains('— ')), reason: kind.name);
        }
        // Минимум и кратность из данных строки на устройстве — с числом.
        expect(
          kioskCartRejectionText(
            l10n,
            const ConflictFailure(ConflictKind.qtyBelowMin),
            minQuantity: Qty.units(3),
            unit: 'м',
          ),
          l10n.error_qty_below_min('3', 'м'),
        );
        expect(
          kioskCartRejectionText(l10n, const ConflictFailure(ConflictKind.qtyNotMultiple), multiple: const Qty(500)),
          l10n.error_qty_not_multiple('0,5', '').trim(),
        );
      },
    );

    test('карточка товара планшета: запросы без warehouseId, «В корзину» — прямой PUT с единицей карточки, вариант '
        'покупателя; сотрудник — склад корзины, как прежде', () async {
      final FakeCartRepository repo = FakeCartRepository();
      final _Server server = _Server(repo);
      final KioskCartSync kiosk = KioskCartSync(
        database: () => null,
        owner: () => null,
        repository: repo,
        offline: () => false,
      );
      addTearDown(kiosk.dispose);
      const ProductDetailsArgs args = (productId: 'p-1', variantId: null, qty: null);
      for (final (RoleCode role, CartDraftRepository draft, String? warehouseId)
          in <(RoleCode, CartDraftRepository, String?)>[
            (RoleCode.kiosk, KioskCartDraftRepository(kiosk), null),
            // Защита: даже если порт сообщил склад, карточка планшета его не передаёт (`warehouseId` → `403`).
            (RoleCode.kiosk, FakeCartDraftRepository(), null),
            (RoleCode.seller, FakeCartDraftRepository(), 'wh-main'),
          ]) {
        final FakeCatalogRepository catalogRepo = FakeCatalogRepository(
          network: Success<Product>(multiVariantProduct()),
        );
        final ProviderContainer c = ProviderContainer(
          overrides: productOverrides(catalog: catalogRepo, cart: draft, role: role),
        );
        addTearDown(c.dispose);
        final ProviderSubscription<ProductDetailsState> sub = c.listen(productDetailsProvider(args), (_, _) {});
        addTearDown(sub.close);
        await pumpEventQueue();
        expect(catalogRepo.productCalls.single.warehouseId, warehouseId, reason: '$role ${draft.runtimeType}');
        expect(c.read(productDetailsProvider(args)).isCustomer, role == RoleCode.kiosk);
        if (draft is KioskCartDraftRepository) {
          expect(await c.read(productDetailsProvider(args).notifier).add(), isTrue);
          final CartItemPut put = server.puts.single;
          expect((put.mode, put.quantity.unitId), (CartPutMode.increment, 'u-pcs'), reason: 'единица — из карточки');
          expect(c.read(productDetailsProvider(args)).inCartQuantity, Qty.units(1));
        }
      }
    });

    test('root: оформление планшета недоступно при 426 и метке сброса без сети; сотрудник — нет', () {
      for (final (RoleCode role, KioskStatus status, bool resetPending, bool blocked)
          in <(RoleCode, KioskStatus, bool, bool)>[
            (RoleCode.kiosk, KioskStatus.ready, false, false),
            (RoleCode.kiosk, KioskStatus.updateNeeded, false, true),
            (RoleCode.kiosk, KioskStatus.unavailable, false, true),
            (RoleCode.kiosk, KioskStatus.ready, true, true),
            (RoleCode.seller, KioskStatus.updateNeeded, true, false),
          ]) {
        final ProviderContainer c = ProviderContainer(
          overrides: <Override>[
            ...cartUiOverrides,
            catalog.catalogViewerRoleProvider.overrideWithValue(role),
            kioskStatusProvider.overrideWithValue(status),
            kioskCartResetPendingProvider.overrideWithValue(resetPending),
          ],
        );
        addTearDown(c.dispose);
        expect(c.read(cartOrderingBlockedProvider), blocked, reason: '$role $status $resetPending');
      }
    });
  });

  group('T-KIOSK-042 drawer планшета', () {
    late FakeCartRepository repo;
    late _Server server;
    late KioskCartSync sync;
    late bool offline;

    setUp(() {
      repo = FakeCartRepository();
      server = _Server(repo);
      server.cart = Cart(
        id: 'cart-1',
        status: CartStatus.active,
        items: <CartLine>[line('v-1', Qty.units(2)), line('v-2', Qty.units(1))],
        rowVersion: 17,
        subtotal: Money.som(4950),
        total: Money.som(4950),
        itemsCount: 2,
      );
      offline = false;
      sync = KioskCartSync(database: () => null, owner: () => null, repository: repo, offline: () => offline);
    });
    tearDown(() => sync.dispose());

    Future<GoRouter> pump(
      WidgetTester tester, {
      OnlineStatus online = OnlineStatus.online,
      List<Override> extra = const <Override>[],
    }) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final GoRouter router = GoRouter(
        initialLocation: '/kiosk',
        routes: <RouteBase>[
          GoRoute(
            path: '/kiosk',
            builder: (_, _) => const Scaffold(
              body: Column(
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(child: Text('kiosk-header')),
                      CartHeaderButtonView(),
                    ],
                  ),
                  Expanded(child: Center(child: Text('kiosk-catalog'))),
                ],
              ),
            ),
          ),
          GoRoute(
            path: '/kiosk/checkout',
            builder: (_, GoRouterState state) => Scaffold(body: Text('kiosk-checkout:${state.uri}')),
          ),
          GoRoute(
            path: '/checkout',
            builder: (_, _) => const Scaffold(body: Text('staff-checkout')),
          ),
          GoRoute(
            path: '/cart/parked',
            builder: (_, _) => const Scaffold(body: Text('parked')),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            cartSyncProvider.overrideWithValue(sync.port()),
            cartRepositoryProvider.overrideWithValue(repo),
            cartViewerRoleProvider.overrideWithValue(RoleCode.kiosk),
            cartOnlineStatusProvider.overrideWithValue(online),
            cartCheckoutLocationProvider.overrideWithValue(kioskCheckoutLocation),
            clockProvider.overrideWithValue(FixedClock(DateTime.utc(2026, 11, 4, 9))),
            ...extra,
          ],
          child: MaterialApp.router(
            routerConfig: router,
            theme: AppTheme.light(),
            locale: const Locale('ru'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            debugShowCheckedModeBanner: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return router;
    }

    final Finder drawer = find.byKey(CartDrawer.key);
    final Finder button = find.byKey(CartHeaderButtonView.buttonKey);

    testWidgets('T-KIOSK-042 drawer without client/discount/warehouse/Отложить, F8 no-op: «Оформить заявку» и '
        '«Договорные цены применит кассир»; F4/F8/F9 не действуют', (WidgetTester tester) async {
      await pump(tester);
      // F4 при закрытом drawer — не открывает его (клавиши сотрудника, navigation.md §9).
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.sendKeyEvent(LogicalKeyboardKey.f9);
      await tester.pumpAndSettle();
      expect(drawer, findsNothing);
      expect(find.textContaining('kiosk-checkout'), findsNothing);

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(drawer, findsOneWidget);
      for (final Key k in <Key>[
        CartKeys.customer,
        CartKeys.warehouse,
        CartKeys.park,
        CartKeys.parked,
        CartKeys.clear,
      ]) {
        expect(find.byKey(k), findsNothing, reason: '$k');
      }
      expect(find.byType(DiscountInput), findsNothing);
      expect(find.text(l10n.cart_cta_park_hotkey), findsNothing);
      expect(find.text(l10n.cart_cta_park), findsNothing);
      expect(
        find.descendant(of: find.byKey(CartKeys.createOrder), matching: find.text(l10n.kiosk_checkout_button)),
        findsOne,
      );
      expect(find.byKey(CartSummary.noteKey), findsOneWidget);
      expect(find.text(l10n.kiosk_price_note), findsOneWidget);

      // F8 и F9 при открытом drawer — ничего: ни диалога «Отложить», ни перехода.
      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      await tester.sendKeyEvent(LogicalKeyboardKey.f9);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.textContaining('kiosk-checkout'), findsNothing);
      expect(repo.calls.where((FakeCall c) => c.method == 'park' || c.method == 'listParked'), isEmpty);
      expect(drawer, findsOneWidget);
    });

    testWidgets('степпер — прямой PUT mode=set с rowVersion сервера; «Оформить заявку» → SCR-52 ?step=phone, «Назад» — '
        'drawer открыт', (WidgetTester tester) async {
      final GoRouter router = await pump(tester);
      await tester.tap(button);
      await tester.pumpAndSettle();
      final QuantityStepper stepper = tester.widget<QuantityStepper>(
        find.descendant(of: find.byKey(CartKeys.line(v1)), matching: find.byType(QuantityStepper)),
      );
      stepper.onIncrement!();
      await tester.pumpAndSettle();
      expect(
        (server.puts.single.mode, server.puts.single.quantity.value, server.puts.single.rowVersion),
        (CartPutMode.set, Qty.units(3), 17),
      );
      expect(repo.calls.where((FakeCall c) => c.method == 'putItem'), hasLength(1));

      await tester.tap(find.byKey(CartKeys.createOrder));
      await tester.pumpAndSettle();
      expect(find.text('kiosk-checkout:/kiosk/checkout?step=phone'), findsOneWidget);
      expect(find.text('staff-checkout'), findsNothing);

      router.pop();
      await tester.pumpAndSettle();
      expect(drawer, findsOneWidget, reason: '02 SCR-51.6: «Назад» — SCR-51 с открытым drawer');
    });

    testWidgets('без связи: баннер «Нет связи…», строки только для чтения, «Оформить заявку» недоступна', (
      tester,
    ) async {
      await sync.refresh();
      offline = true;
      await pump(tester, online: OnlineStatus.offline);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text(l10n.kiosk_offline), findsOneWidget);
      expect(find.text(l10n.cart_banner_offline), findsNothing);
      for (final QuantityStepper s in tester.widgetList<QuantityStepper>(find.byType(QuantityStepper))) {
        expect((s.onIncrement, s.onDecrement, s.onValueTap), (null, null, null));
      }
      expect(find.byType(Dismissible), findsNothing);
      expect(find.textContaining(l10n.cart_save_state_queued(1)), findsNothing, reason: 'очереди у планшета нет');
      expect(tester.widget<AppButton>(find.byKey(CartKeys.createOrder)).onPressed, isNull);
      await tester.tap(find.byKey(CartKeys.createOrder));
      await tester.pumpAndSettle();
      expect(find.textContaining('kiosk-checkout'), findsNothing);
      expect(repo.calls.where((FakeCall c) => c.method == 'putItem' || c.method == 'deleteItem'), isEmpty);
    });

    testWidgets('UI-51-018 возврат из SCR-52 по отказу остатка: «Товара стало меньше…» над строками drawer; GET /cart '
        'той же версии баннер не снимает, изменение корзины снимает', (WidgetTester tester) async {
      await sync.refresh();
      await pump(
        tester,
        extra: <Override>[
          kioskCartSyncProvider.overrideWithValue(sync),
          kioskCartStockChangedProvider.overrideWith((Ref ref) => ref.watch(kioskCartStockNoticeProvider)),
        ],
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      final Finder notice = find.descendant(
        of: find.byKey(CartKeys.banner),
        matching: find.text(l10n.kiosk_stock_changed),
      );
      expect(notice, findsNothing);

      // SCR-52: отказ по остатку → корзина перечитана → отметка (порт `kioskCartMarkStockChangedProvider`).
      server.cart = Cart(
        id: 'cart-1',
        status: CartStatus.active,
        items: <CartLine>[
          CartLine(
            variantId: 'v-1',
            productId: 'p-v-1',
            productName: 'Смеситель v-1',
            quantity: LineQuantity(value: Qty.units(2), unitId: 'u-pc'),
            unitPrice: Money.som(1650),
            lineTotal: Money.som(3300),
            // `customer_stock_display=status`: остаток без чисел (02 UI-51-012).
            warnings: const <CartItemWarning>[CartItemWarning.stockInsufficient],
          ),
          line('v-2', Qty.units(1)),
        ],
        rowVersion: 17,
      );
      await sync.refresh();
      sync.markStockChanged();
      await tester.pumpAndSettle();
      expect(notice, findsOneWidget);
      expect(find.text(l10n.cart_line_stock_short_customer), findsOneWidget, reason: 'строка отмечена без чисел');
      await sync.refresh();
      await tester.pumpAndSettle();
      expect(notice, findsOneWidget, reason: 'та же корзина той же версии');

      final QuantityStepper stepper = tester.widget<QuantityStepper>(
        find.descendant(of: find.byKey(CartKeys.line(v1)), matching: find.byType(QuantityStepper)),
      );
      stepper.onDecrement!();
      await tester.pumpAndSettle();
      expect(server.puts.single.quantity.value, Qty.units(1));
      expect(notice, findsNothing, reason: 'корзина изменилась — новая версия');
      expect(find.text(l10n.kiosk_stock_changed), findsNothing);
    });

    testWidgets('UI-51-018 FLOW-044.A3: строка из conflicts[] отказа заявки, которой нет в warnings[] GET /cart '
        '(VARIANT_UNAVAILABLE — нет цены в виде цены карточки), всё равно отмечена «Товар больше не продаётся»; '
        'отметки по warnings[] — как прежде, без повтора', (WidgetTester tester) async {
      server.cart = Cart(
        id: 'cart-1',
        status: CartStatus.active,
        items: <CartLine>[
          CartLine(
            variantId: 'v-1',
            productId: 'p-v-1',
            productName: 'Смеситель v-1',
            quantity: LineQuantity(value: Qty.units(2), unitId: 'u-pc'),
            unitPrice: Money.som(1650),
            lineTotal: Money.som(3300),
            warnings: const <CartItemWarning>[CartItemWarning.stockInsufficient],
          ),
          line('v-2', Qty.units(1)),
        ],
        rowVersion: 17,
        warnings: const <CartConflict>[CartConflict(variantId: 'v-1', rawKind: 'stock_insufficient')],
      );
      await sync.refresh();
      await pump(
        tester,
        extra: <Override>[
          kioskCartSyncProvider.overrideWithValue(sync),
          kioskCartStockChangedProvider.overrideWith((Ref ref) => ref.watch(kioskCartStockNoticeProvider)),
        ],
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text(l10n.cart_line_unavailable), findsNothing);

      // SCR-52: `422 VARIANT_UNAVAILABLE conflicts[{variantId: v-2}]` — `GET /cart` строку v-2 не пометил.
      sync.markStockChanged(const <KioskCartStockConflict>[
        (variantId: 'v-2', kind: 'variant_unavailable', stockLevel: null),
        (variantId: 'v-1', kind: 'stock_insufficient', stockLevel: 'low'),
        (variantId: 'v-gone', kind: 'variant_unavailable', stockLevel: null),
      ]);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: find.byKey(CartKeys.banner), matching: find.text(l10n.kiosk_stock_changed)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: find.byKey(CartKeys.line(v2)), matching: find.text(l10n.cart_line_unavailable)),
        findsOneWidget,
        reason: 'отказанная строка отмечена всегда',
      );
      expect(
        find.descendant(of: find.byKey(CartKeys.line(v1)), matching: find.text(l10n.cart_line_stock_short_customer)),
        findsOneWidget,
        reason: 'отметка по warnings[] — как прежде, одна',
      );

      await sync.refresh();
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: find.byKey(CartKeys.line(v2)), matching: find.text(l10n.cart_line_unavailable)),
        findsOneWidget,
        reason: 'GET /cart той же версии отметку не снимает',
      );
      server.bump();
      await sync.refresh();
      await tester.pumpAndSettle();
      expect(find.text(l10n.cart_line_unavailable), findsNothing, reason: 'новая версия корзины — отметка снята');
    });

    testWidgets('SEC-141 (3) / 08 §2.4: отказ степпера 422 QTY_BELOW_MIN без чисел в conflicts[] — подпись без числа, '
        'не «Минимальная партия — »; STOCK_INSUFFICIENT — без количества', (WidgetTester tester) async {
      server.cart = Cart(
        id: 'cart-1',
        status: CartStatus.active,
        items: <CartLine>[line('v-1', Qty.units(2)), line('v-2', Qty.units(1))],
        rowVersion: 17,
      );
      await sync.refresh();
      Failure refusal = const ConflictFailure(
        ConflictKind.qtyBelowMin,
        details: <String, Object?>{
          'conflicts': <Object?>[
            <String, Object?>{'variantId': 'v-1', 'kind': 'qty_below_min'},
          ],
        },
      );
      repo.onPutItem = (String variantId, CartItemPut put, String? key) async => FailureResult<Cart>(refusal);
      await pump(tester);
      await tester.tap(button);
      await tester.pumpAndSettle();
      QuantityStepper stepper() => tester.widget<QuantityStepper>(
        find.descendant(of: find.byKey(CartKeys.line(v1)), matching: find.byType(QuantityStepper)),
      );
      stepper().onIncrement!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text(l10n.cart_header_save_failed), findsOneWidget);
      expect(find.textContaining('Минимальная партия — '), findsNothing);
      await tester.pumpAndSettle(const Duration(seconds: 5));

      refusal = const ConflictFailure(
        ConflictKind.stockInsufficient,
        details: <String, Object?>{
          'conflicts': <Object?>[
            <String, Object?>{'variantId': 'v-1', 'kind': 'stock_insufficient', 'stockLevel': 'low'},
          ],
        },
      );
      stepper().onIncrement!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text(l10n.cart_line_stock_short_customer), findsWidgets);
      expect(find.textContaining('доступно'), findsNothing, reason: 'без количества');
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    testWidgets('метка сброса: корзина на экране пуста, «Оформить заявку» недоступна', (WidgetTester tester) async {
      await sync.refresh();
      offline = true;
      await sync.reset(server.reset);
      await pump(tester);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byKey(CartKeys.line(v1)), findsNothing);
      expect(find.text(l10n.cart_empty_title), findsWidgets);
      expect(tester.widget<AppButton>(find.byKey(CartKeys.createOrder)).onPressed, isNull);
      expect(server.resets, isEmpty);
      final ProviderContainer c = ProviderScope.containerOf(tester.element(drawer));
      expect(c.read(cartControllerProvider).lines, isEmpty);
      expect(
        c.read(cartControllerProvider).server,
        isNull,
        reason: 'ответ GET /cart со сброшенной корзиной не показан',
      );
    });
  });
}
