// Корзина-черновик поверх drift `cart_draft`/`cart_items_draft` (07 §11.2, DATA-253; RM-E-008):
// создание активной корзины при первом добавлении, увеличение строки той же пары (вариант, упаковка),
// отдельная строка для упаковки, установка/удаление количества, изоляция по `owner_user_id`,
// недоступность без БД/пользователя. SQLite в памяти, синтетические данные.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/cart/data/draft/cart_draft_local_repository.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';

import '../../../core/database/test_database.dart';

const String userA = '00000000-0000-4000-8000-00000000000a';
const String userB = '00000000-0000-4000-8000-00000000000b';

void main() {
  configureSqliteForTests();
  late AppDatabase db;
  late String? owner;
  late CartDraftLocalRepository repo;
  int ids = 0;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    owner = userA;
    ids = 0;
    repo = CartDraftLocalRepository(
      database: () => db,
      ownerUserId: () => owner,
      clock: FixedClock(DateTime.utc(2026, 10, 22, 9)),
      newId: () => 'id-${++ids}',
    );
  });
  tearDown(() => db.close());

  test('первое добавление создаёт активную корзину и строку (dirty, pending)', () async {
    final CartDraftLine line = (await repo.add(
      CartDraftAdd(
        variantId: 'v-1',
        quantity: Qty.units(2),
        priceSnapshot: Money.som(2850),
        stockSnapshot: Qty.units(24),
      ),
    )).valueOrNull!;
    expect(line.quantity, Qty.units(2));
    expect(line.lineNo, 1);
    expect(line.syncState, CartDraftSyncState.pending);
    expect(line.priceSnapshot, Money.som(2850));
    final List<CartDraftRow> carts = await db.select(db.cartDraft).get();
    expect(carts.single.status, 'active');
    expect(carts.single.dirty, isTrue);
    expect(carts.single.ownerUserId, userA);
  });

  test('та же пара увеличивается (CART-002); упаковка — отдельная строка; порядок line_no', () async {
    await repo.add(CartDraftAdd(variantId: 'v-1', quantity: Qty.units(1)));
    await repo.add(CartDraftAdd(variantId: 'v-1', quantity: Qty.units(3)));
    await repo.add(CartDraftAdd(variantId: 'v-1', packagingId: 'pk-box', quantity: Qty.units(2)));
    await repo.add(CartDraftAdd(variantId: 'v-2', quantity: Qty.units(1)));
    final List<CartDraftLine> lines = (await repo.lines()).valueOrNull!;
    expect(
      lines.map((CartDraftLine l) => (l.variantId, l.packagingId, l.quantity.milli, l.lineNo)),
      <(String, String?, int, int)>[('v-1', null, 4000, 1), ('v-1', 'pk-box', 2000, 2), ('v-2', null, 1000, 3)],
    );
    expect((await repo.line('v-1', packagingId: 'pk-box')).valueOrNull!.quantity, Qty.units(2));
    expect(await db.select(db.cartDraft).get(), hasLength(1));
  });

  test('setQuantity: новое значение; 0 — удаление строки', () async {
    await repo.add(CartDraftAdd(variantId: 'v-1', quantity: Qty.units(1)));
    expect((await repo.setQuantity('v-1', quantity: const Qty(2500))).valueOrNull!.quantity, const Qty(2500));
    expect((await repo.setQuantity('v-1', quantity: Qty.zero)).valueOrNull, isNull);
    expect((await repo.lines()).valueOrNull, isEmpty);
    expect((await repo.setQuantity('нет', quantity: Qty.units(1))).valueOrNull, isNull);
  });

  test('строки другого пользователя не видны (owner_user_id, 07 §11.1 п.2)', () async {
    await repo.add(CartDraftAdd(variantId: 'v-1', quantity: Qty.units(1)));
    owner = userB;
    expect((await repo.lines()).valueOrNull, isEmpty);
    await repo.add(CartDraftAdd(variantId: 'v-1', quantity: Qty.units(5)));
    expect((await repo.lines()).valueOrNull!.single.quantity, Qty.units(5));
    owner = userA;
    expect((await repo.lines()).valueOrNull!.single.quantity, Qty.units(1));
    expect(await db.select(db.cartDraft).get(), hasLength(2));
  });

  test('watchLines отдаёт изменения активной корзины', () async {
    final Future<List<List<int>>> seen = repo
        .watchLines()
        .map((List<CartDraftLine> l) => <int>[for (final CartDraftLine x in l) x.quantity.milli])
        .take(3)
        .toList();
    await Future<void>.delayed(Duration.zero);
    await repo.add(CartDraftAdd(variantId: 'v-1', quantity: Qty.units(1)));
    await Future<void>.delayed(Duration.zero);
    await repo.add(CartDraftAdd(variantId: 'v-1', quantity: Qty.units(1)));
    expect(await seen, <List<int>>[
      <int>[],
      <int>[1000],
      <int>[2000],
    ]);
  });

  test('склад активной корзины (cart_draft.warehouse_id)', () async {
    expect((await repo.warehouseId()).valueOrNull, isNull);
    await repo.add(CartDraftAdd(variantId: 'v-1', quantity: Qty.units(1)));
    await db.update(db.cartDraft).write(const CartDraftCompanion(warehouseId: Value('wh-2')));
    expect((await repo.warehouseId()).valueOrNull, 'wh-2');
  });

  test('без БД или пользователя — CartDraftUnavailable', () async {
    owner = null;
    final Result<List<CartDraftLine>> r = await repo.lines();
    expect((r.failureOrNull! as UnknownFailure).cause, isA<CartDraftUnavailable>());
    final CartDraftLocalRepository noDb = CartDraftLocalRepository(
      database: () => null,
      ownerUserId: () => userA,
      clock: FixedClock(DateTime.utc(2026)),
    );
    expect((await noDb.add(CartDraftAdd(variantId: 'v', quantity: Qty.units(1)))).isSuccess, isFalse);
    expect(await noDb.watchLines().first, isEmpty);
  });
}
