// T-CART-004 (12 §3.4.1) / 10 CART-005 на реальной синхронизации: `CartController.replaceVariant` поверх
// `DriftCartSync` (drift в памяти, очередь `OutboxQueue`, фейковый сервер `CartRepository`). Ревью F, RC-1: строки
// старого и целевого вариантов в состоянии «не отправлено» (`dead`) после замены не остаются в копии и не
// откатывают объединённое количество через «Повторить»; RC-2: журнал замены снимается после завершения. Данные
// синтетические.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/app_meta_dao.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' show CartStatus;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/sync/outbox_queue.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/data/sync/drift_cart_sync.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_controller.dart';

import '../../../core/database/test_database.dart';
import '../../../support/f_fakes.dart';

const String owner = '00000000-0000-4000-8000-00000000000a';
const CartLineKey chrome = CartLineKey('v-chrome');
const CartLineKey white = CartLineKey('v-white');

CartLine mixLine(String variantId, int units) => CartLine(
  variantId: variantId,
  productId: 'p-mix',
  productName: 'Смеситель Frap F4252',
  quantity: LineQuantity(value: Qty.units(units), unitId: 'u-pc'),
  unitPrice: Money.som(2350),
  lineTotal: Money.som(2350 * units),
);

Cart mixCart(int rowVersion, List<CartLine> items) =>
    Cart(id: 'cart-1', status: CartStatus.active, items: items, rowVersion: rowVersion);

void main() {
  configureSqliteForTests();
  late AppDatabase db;
  late FakeCartRepository repo;
  late OutboxQueue queue;
  late DriftCartSync sync;
  late ProviderContainer container;
  late Cart server;
  late List<(String, int)> puts;

  /// Сервер по 08 §4.7.3: `PUT mode=set` ставит количество строки (0 — удаляет), версия — строго по цепочке.
  void serverAccepts() {
    repo.onPutItem = (String variantId, CartItemPut put, String? key) async {
      puts.add((variantId, put.quantity.value.milli ~/ 1000));
      if (put.rowVersion != server.rowVersion) {
        return const FailureResult<Cart>(ConflictFailure(ConflictKind.versionConflict));
      }
      final List<CartLine> items = <CartLine>[
        for (final CartLine l in server.items)
          if (l.variantId != variantId) l,
      ];
      final int i = server.items.indexWhere((CartLine l) => l.variantId == variantId);
      if (!put.quantity.value.isZero) {
        items.insert(i < 0 ? items.length : i, mixLine(variantId, put.quantity.value.milli ~/ 1000));
      }
      server = mixCart(server.rowVersion + 1, items);
      return Success<Cart>(server);
    };
    repo.onFetch = () async => Success<Cart>(server);
  }

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue);
  }

  CartState state() => container.read(cartControllerProvider);

  /// Строка [key] получает «не отправлено» (`dead`): сервер отклонил изменение до [units].
  Future<void> markDead(CartLineKey key, int units) async {
    repo.onPutItem = (String v, CartItemPut put, String? k) async => const FailureResult<Cart>(PermissionFailure());
    await sync.setQuantity(key, Qty.units(units));
    await sync.sync();
    serverAccepts();
    await until(() => state().local?.line(key)?.syncState == CartDraftSyncState.dead);
  }

  Future<void> start(Cart initial) async {
    server = initial;
    serverAccepts();
    container = ProviderContainer(
      overrides: <Override>[
        cartSyncProvider.overrideWithValue(sync),
        cartRepositoryProvider.overrideWithValue(repo),
        cartOnlineStatusProvider.overrideWithValue(OnlineStatus.online),
        clockProvider.overrideWithValue(FixedClock(DateTime.utc(2026, 10, 23, 9))),
        appDatabaseProvider.overrideWithValue(db),
      ],
    );
    container.listen<CartState>(cartControllerProvider, (CartState? a, CartState b) {});
    await until(() => state().server != null && state().local != null);
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = FakeCartRepository();
    puts = <(String, int)>[];
    sync = DriftCartSync(
      database: () => db,
      owner: () => owner,
      clock: FixedClock(DateTime.utc(2026, 10, 23, 9)),
      repository: repo,
      queue: () => queue,
      offline: () => false,
    );
    queue = OutboxQueue(
      database: () => db,
      owner: () => owner,
      clock: FixedClock(DateTime.utc(2026, 10, 23, 9)),
      handlers: <OutboxActionHandler>[sync],
    );
  });

  tearDown(() async {
    container.dispose();
    await sync.dispose();
    await db.close();
  });

  Future<void> expectSingleSynced(CartLineKey key, int units) async {
    final CartLocalSnapshot local = (await sync.loadLocal()).valueOrNull!;
    expect(
      local.lines.map((CartLocalLine l) => (l.key.variantId, l.quantity.milli ~/ 1000, l.syncState)),
      <Object>[(key.variantId, units, CartDraftSyncState.synced)],
      reason: 'в копии одна строка с суммой, неотправленных изменений нет',
    );
    expect(local.hasUnsent, isFalse);
    expect(await sync.watchStatus().first, CartSyncStatus.idle, reason: 'нет «Ошибка сохранения · Повторить»');
    expect(await AppMetaDao(db).read(DriftCartSync.replaceMetaKey), isNull, reason: 'журнал замены снят');
    await until(() => state().lines.length == 1 && !state().hasUnconfirmed);
    final CartLineView only = state().lines.single;
    expect((only.key, only.quantity), (key, Qty.units(units)));
  }

  test('RC-1: старая строка «не отправлено» (dead) → замена варианта — одна строка нового варианта, на экране и в '
      'копии старой нет; «Повторить» её не возвращает', () async {
    await start(mixCart(17, <CartLine>[mixLine('v-chrome', 3)]));
    await markDead(chrome, 4);
    final CartLineView line = state().lines.single;
    expect((line.key, line.quantity, line.failed), (chrome, Qty.units(4), true));

    expect(await container.read(cartControllerProvider.notifier).replaceVariant(line, 'v-white'), isNull);
    expect(puts, <(String, int)>[('v-white', 4), ('v-chrome', 0)]);
    expect(server.items.map((CartLine l) => (l.variantId, l.quantity.value.milli ~/ 1000)), <(String, int)>[
      ('v-white', 4),
    ]);
    await expectSingleSynced(white, 4);

    await container.read(cartControllerProvider.notifier).retryFailed();
    expect(puts, hasLength(2), reason: '«Повторить» не отправляет старую строку');
    expect(server.items.single.variantId, 'v-white');
  });

  test('RC-1: объединение с целевой строкой «не отправлено» — сумма с сервера не перекрывается локальным '
      'количеством', () async {
    await start(mixCart(17, <CartLine>[mixLine('v-chrome', 3), mixLine('v-white', 2)]));
    await markDead(white, 5);
    final CartController cart = container.read(cartControllerProvider.notifier);
    final CartLineView old = state().lines.firstWhere((CartLineView l) => l.key == chrome);
    expect(cart.lineFor('v-white', null)!.quantity, Qty.units(5), reason: 'показано неотправленное количество');

    expect(await cart.replaceVariant(old, 'v-white'), isNull);
    expect(puts, <(String, int)>[('v-white', 8), ('v-chrome', 0)], reason: '5 + 3 = 8 (подтверждённая сумма)');
    await expectSingleSynced(white, 8);

    await cart.retryFailed();
    expect(puts, hasLength(2), reason: '«Повторить» не откатывает объединённое количество к 5');
    expect(server.items.single.quantity.value, Qty.units(8));
  });
}
