// RM-F-005 п. 2–3, RM-F-013 п. 2 (unit синхронизации черновика): `DriftCartSync` на drift в памяти + реальная
// очередь `OutboxQueue` + фейковый `CartRepository`.
// - серия изменений количества → одна запись `cart.sync` → один `PUT /cart/items/{variantId}` `mode=set` с итоговым
//   количеством; цепочка `rowVersion` — следующая запись идёт с версией из ответа предыдущей;
// - офлайн: изменение ставится в outbox по 07 §11.2 (`set_item`, без `increment`) и после появления сети
//   применяется ровно один раз;
// - «перезапуск» (новый объект над той же БД) восстанавливает черновик и отправляет его с базой из копии (D-32);
// - удаление (метка 0), `409 VERSION_CONFLICT` (остановка очереди, «Применить мои» / «Оставить как на сервере»),
//   отказ по кратности (значение возвращается), единица строки из кэша каталога.
// Синтетические данные.
import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/app_meta_dao.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/sync/outbox_queue.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/cart/data/draft/cart_draft_local_repository.dart';
import 'package:optomstroy/features/cart/data/sync/drift_cart_sync.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';

import '../../../core/database/test_database.dart';
import '../../../support/f_fakes.dart';

const String owner = '00000000-0000-4000-8000-00000000000a';
const CartLineKey frap = CartLineKey('v-frap');

CartLine line(String variantId, int units, {String unitId = 'u-pc', String? packagingId, int price = 235000}) =>
    CartLine(
      variantId: variantId,
      productName: 'Смеситель $variantId',
      quantity: LineQuantity(value: Qty.units(units), unitId: unitId, packagingId: packagingId),
      unitPrice: Money(price),
      lineTotal: Money(price * units),
    );

Cart serverCart(int rowVersion, List<CartLine> items) =>
    Cart(id: 'srv-cart', status: CartStatus.active, items: items, rowVersion: rowVersion);

void main() {
  configureSqliteForTests();
  late AppDatabase db;
  late FakeCartRepository repo;
  late OutboxQueue queue;
  late DriftCartSync sync;
  late bool offline;
  late List<CartItemPut> puts;
  late List<int> putVersions;
  late Cart server;

  DriftCartSync build() {
    final DriftCartSync s = DriftCartSync(
      database: () => db,
      owner: () => owner,
      clock: FixedClock(DateTime.utc(2026, 10, 22, 9)),
      repository: repo,
      queue: () => queue,
      offline: () => offline,
    );
    queue = OutboxQueue(
      database: () => db,
      owner: () => owner,
      clock: FixedClock(DateTime.utc(2026, 10, 22, 9)),
      handlers: <OutboxActionHandler>[s],
    );
    return s;
  }

  /// Сервер: `PUT mode=set` устанавливает количество строки и увеличивает `rowVersion`.
  void serverAccepts() {
    repo.onPutItem = (String variantId, CartItemPut put, String? key) async {
      puts.add(put);
      putVersions.add(put.rowVersion);
      if (put.rowVersion != server.rowVersion) {
        return const FailureResult<Cart>(ConflictFailure(ConflictKind.versionConflict));
      }
      final List<CartLine> items = <CartLine>[
        for (final CartLine l in server.items)
          if (!(l.variantId == variantId && l.packagingId == put.quantity.packagingId)) l,
        if (!put.quantity.value.isZero) line(variantId, put.quantity.value.milli ~/ 1000),
      ];
      server = serverCart(server.rowVersion + 1, items);
      return Success<Cart>(server);
    };
    repo.onFetch = () async => Success<Cart>(server);
  }

  Future<List<OutboxActionRow>> outbox() => db.select(db.outboxActions).get();

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = FakeCartRepository();
    offline = false;
    puts = <CartItemPut>[];
    putVersions = <int>[];
    server = serverCart(17, <CartLine>[line('v-frap', 2)]);
    serverAccepts();
    sync = build();
    // Копия = ответ сервера (rowVersion 17, строка v-frap × 2).
    expect((await sync.refresh()).isSuccess, isTrue);
  });
  tearDown(() async {
    await sync.dispose();
    await db.close();
  });

  test('серия изменений → один PUT mode=set с итоговым количеством; цепочка rowVersion из ответа', () async {
    for (final int n in <int>[3, 4, 5]) {
      await sync.setQuantity(frap, Qty.units(n));
    }
    final CartLocalSnapshot pending = (await sync.loadLocal()).valueOrNull!;
    expect(pending.line(frap)!.quantity, Qty.units(5));
    expect(pending.line(frap)!.syncState, CartDraftSyncState.pending);
    expect(puts, isEmpty, reason: 'до sync() (debounce контроллера) запросов нет');

    await sync.sync();
    expect(puts, hasLength(1));
    expect(puts.single.mode, CartPutMode.set);
    expect(puts.single.quantity.value, Qty.units(5));
    expect(puts.single.quantity.unitId, 'u-pc');
    expect(putVersions.single, 17);
    final CartLocalSnapshot after = (await sync.loadLocal()).valueOrNull!;
    expect(after.baseRowVersion, 18);
    expect(after.line(frap)!.syncState, CartDraftSyncState.synced);

    await sync.setQuantity(frap, Qty.units(6));
    await sync.sync();
    expect(putVersions, <int>[17, 18], reason: 'вторая запись — с версией из ответа первой');
    expect((await outbox()).where((OutboxActionRow r) => r.status != 'done'), isEmpty);
  });

  test('офлайн: запись cart.sync set_item (07 §11.2) → после сети отправляется один раз', () async {
    offline = true;
    await sync.setQuantity(frap, Qty.units(4));
    await sync.sync();
    expect(puts, isEmpty);
    final List<OutboxActionRow> rows = await outbox();
    expect(rows, hasLength(1));
    expect(rows.single.type, OutboxTypes.cartSync);
    expect(rows.single.status, 'pending');
    final Map<String, Object?> payload = (jsonDecode(rows.single.payloadJson) as Map).cast<String, Object?>();
    expect(payload['op'], 'set_item');
    expect(payload['quantityMilli'], 4000);
    expect(payload['unitId'], 'u-pc');
    expect(payload.containsKey('mode'), isFalse, reason: 'increment в очереди нет');
    expect(await sync.watchStatus().first, const CartSyncStatus(queued: 1));

    // Повторная постановка того же изменения не дублирует запись.
    await sync.sync();
    expect(await outbox(), hasLength(1));

    offline = false;
    await queue.flush();
    await queue.flush();
    expect(puts, hasLength(1), reason: 'применяется один раз');
    expect(puts.single.quantity.value, Qty.units(4));
    expect(server.items.single.quantity.value, Qty.units(4));
    expect((await sync.loadLocal()).valueOrNull!.line(frap)!.syncState, CartDraftSyncState.synced);
  });

  test('новое изменение той же строки заменяет неотправленную запись (сжатие по паре)', () async {
    offline = true;
    await sync.setQuantity(frap, Qty.units(3));
    await sync.sync();
    await sync.setQuantity(frap, Qty.units(7));
    await sync.sync();
    final List<OutboxActionRow> rows = await outbox();
    expect(rows, hasLength(1));
    expect((jsonDecode(rows.single.payloadJson) as Map)['quantityMilli'], 7000);
  });

  test('перезапуск: новый объект над той же БД восстанавливает черновик и отправляет его (D-32)', () async {
    offline = true;
    await sync.setQuantity(frap, Qty.units(9));
    await sync.setQuantity(const CartLineKey('v-new'), Qty.units(1));
    await sync.dispose();

    // «Перезапуск»: прежний объект и очередь заменены.
    sync = build();
    final CartLocalSnapshot restored = (await sync.loadLocal()).valueOrNull!;
    expect(restored.baseRowVersion, 17);
    expect(restored.visibleLines.map((CartLocalLine l) => (l.key.variantId, l.quantity.milli)), <(String, int)>[
      ('v-frap', 9000),
      ('v-new', 1000),
    ]);
    expect(restored.hasUnsent, isTrue);

    offline = false;
    await sync.sync();
    expect(puts.map((CartItemPut p) => p.quantity.value.milli), <int>[
      9000,
    ], reason: 'у v-new нет единицы в кэше каталога — ждёт кэша');
    expect(putVersions.single, 17);
  });

  test('единица новой строки — из кэша каталога; цена из каталога уходит priceSnapshot', () async {
    await db.into(db.localUnits).insert(UnitsCompanionX.unit(code: 'pc', id: 'u-pc', name: 'Штука', shortName: 'шт'));
    await db
        .into(db.localProducts)
        .insert(
          LocalProductsCompanion.insert(
            id: 'p-new',
            sku: 'NEW-1',
            skuNorm: 'new1',
            name: 'Новый смеситель',
            nameNorm: 'новый смеситель',
            baseUnitCode: 'pc',
            qtyPrecision: 0,
            serverUpdatedAt: 1,
            baseUnitId: const Value<String?>('u-pc'),
          ),
        );
    await db
        .into(db.localProductVariants)
        .insert(
          LocalProductVariantsCompanion.insert(id: 'v-new', productId: 'p-new', name: 'Хром', serverUpdatedAt: 1),
        );
    final CartDraftLocalRepository draft = CartDraftLocalRepository(
      database: () => db,
      ownerUserId: () => owner,
      clock: FixedClock(DateTime.utc(2026, 10, 22, 9)),
    );
    await draft.add(CartDraftAdd(variantId: 'v-new', quantity: Qty.units(2), priceSnapshot: Money.som(1650)));
    final CartLocalLine local = (await sync.loadLocal()).valueOrNull!.line(const CartLineKey('v-new'))!;
    expect((local.productName, local.sku, local.unitLabel, local.unitId), ('Новый смеситель', 'NEW-1', 'шт', 'u-pc'));

    await sync.sync();
    final CartItemPut put = puts.single;
    expect((put.quantity.unitId, put.quantity.value, put.priceSnapshot), ('u-pc', Qty.units(2), Money.som(1650)));
  });

  test('удаление: метка 0 скрыта, PUT set 0 (без упаковки), после ответа строки нет', () async {
    await sync.setQuantity(frap, Qty.zero);
    final CartLocalSnapshot marked = (await sync.loadLocal()).valueOrNull!;
    expect(marked.visibleLines, isEmpty);
    expect(marked.line(frap)!.isDeletion, isTrue);
    await sync.sync();
    expect(puts.single.quantity.value, Qty.zero);
    expect(server.items, isEmpty);
    expect((await sync.loadLocal()).valueOrNull!.lines, isEmpty);
  });

  test('удаление строки упаковки — DELETE ?packagingId=', () async {
    server = serverCart(17, <CartLine>[line('v-frap', 2, packagingId: 'pk-box')]);
    await sync.refresh();
    String? deleted;
    repo.onDeleteItem = (String variantId, String? packagingId) async {
      deleted = '$variantId|$packagingId';
      server = serverCart(18, const <CartLine>[]);
      return Success<Cart>(server);
    };
    await sync.setQuantity(const CartLineKey('v-frap', 'pk-box'), Qty.zero);
    await sync.sync();
    expect(deleted, 'v-frap|pk-box');
    expect(puts, isEmpty);
  });

  group('409 VERSION_CONFLICT', () {
    setUp(() {
      // На другом устройстве корзину изменили: версия 19, v-frap × 10.
      server = serverCart(19, <CartLine>[line('v-frap', 10)]);
      repo.onConflictCurrent = (Failure f) => server;
    });

    test('очередь останавливается, строка dead, событие конфликта; «Применить мои» — PUT с версией 19', () async {
      final List<CartSyncEvent> events = <CartSyncEvent>[];
      final StreamSubscription<CartSyncEvent> sub = sync.events.listen(events.add);
      await sync.setQuantity(frap, Qty.units(5));
      await sync.sync();
      await Future<void>.delayed(Duration.zero);
      expect(putVersions, <int>[17]);
      expect(sync.conflict, isNotNull);
      expect(sync.conflict!.current!.rowVersion, 19);
      expect(sync.conflict!.unsent.single.quantity, Qty.units(5));
      expect(events.whereType<CartConflictDetected>(), hasLength(1));
      expect((await sync.loadLocal()).valueOrNull!.line(frap)!.syncState, CartDraftSyncState.dead);

      await sync.resolveConflict(applyMine: true);
      expect(putVersions, <int>[17, 19]);
      expect(server.items.single.quantity.value, Qty.units(5));
      expect(sync.conflict, isNull);
      expect((await sync.loadLocal()).valueOrNull!.line(frap)!.syncState, CartDraftSyncState.synced);
      await sub.cancel();
    });

    test('F-flutter-data-1: сверка GET /cart до ответа в диалоге не стирает dead-строку; «Применить мои» — моё '
        'значение на сервере', () async {
      await sync.setQuantity(frap, Qty.units(5));
      await sync.sync();
      expect(sync.conflict, isNotNull);
      // Сверка (восстановление сети / открытие корзины) до решения пользователя.
      await sync.refresh();
      final CartLocalLine kept = (await sync.loadLocal()).valueOrNull!.line(frap)!;
      expect((kept.quantity, kept.syncState), (Qty.units(5), CartDraftSyncState.dead));
      expect(sync.conflict, isNotNull, reason: 'конфликт не решён молча');
      expect(sync.conflict!.unsent.single.quantity, Qty.units(5));

      await sync.resolveConflict(applyMine: true);
      expect(puts.last.quantity.value, Qty.units(5));
      expect(server.items.single.quantity.value, Qty.units(5));
      expect(sync.conflict, isNull);
    });

    test('F-flutter-data-1: перезапуск после 409 — refresh восстанавливает конфликт (диалог снова), значение '
        'сохранено', () async {
      await sync.setQuantity(frap, Qty.units(5));
      await sync.sync();
      expect(sync.conflict, isNotNull);
      await sync.dispose();

      // «Перезапуск»: новый объект над той же БД, конфликт в памяти потерян.
      sync = build();
      expect(sync.conflict, isNull);
      final Future<CartSyncEvent> detected = sync.events.firstWhere((CartSyncEvent e) => e is CartConflictDetected);
      await sync.refresh();
      final CartConflictDetected event = await detected as CartConflictDetected;
      expect(event.conflict.unsent.single.quantity, Qty.units(5));
      expect(event.conflict.current!.rowVersion, 19);
      expect(sync.conflict, isNotNull);
      final CartLocalLine kept = (await sync.loadLocal()).valueOrNull!.line(frap)!;
      expect((kept.quantity, kept.syncState), (Qty.units(5), CartDraftSyncState.dead));

      // Очередь корзины не отправляется до решения пользователя.
      await sync.sync();
      expect(putVersions, <int>[17]);

      await sync.resolveConflict(applyMine: true);
      expect(server.items.single.quantity.value, Qty.units(5));
      // Признак конфликта снят: следующий перезапуск диалога не показывает.
      await sync.dispose();
      sync = build();
      await sync.refresh();
      expect(sync.conflict, isNull);
    });

    test('«Оставить как на сервере» — копия = серверная корзина, очередь пуста', () async {
      await sync.setQuantity(frap, Qty.units(5));
      await sync.sync();
      await sync.resolveConflict(applyMine: false);
      final CartLocalSnapshot local = (await sync.loadLocal()).valueOrNull!;
      expect(local.line(frap)!.quantity, Qty.units(10));
      expect(local.baseRowVersion, 19);
      expect(local.hasUnsent, isFalse);
      expect((await outbox()).where((OutboxActionRow r) => r.status != 'done'), isEmpty);
    });
  });

  test('отказ QTY_NOT_MULTIPLE — значение возвращается к серверному, событие отказа', () async {
    repo.onPutItem = (String v, CartItemPut put, String? key) async =>
        const FailureResult<Cart>(ConflictFailure(ConflictKind.qtyNotMultiple));
    final Future<CartSyncEvent> rejected = sync.events.firstWhere((CartSyncEvent e) => e is CartSyncRejected);
    await sync.setQuantity(frap, Qty.units(5));
    await sync.sync();
    expect((await rejected as CartSyncRejected).key, frap);
    final CartLocalLine l = (await sync.loadLocal()).valueOrNull!.line(frap)!;
    expect((l.quantity, l.syncState), (Qty.units(2), CartDraftSyncState.synced));
  });

  test('F-flutter-data-1: строка «не отправлено» (dead после отказа) переживает сверку GET /cart', () async {
    repo.onPutItem = (String v, CartItemPut put, String? key) async => const FailureResult<Cart>(PermissionFailure());
    await sync.setQuantity(frap, Qty.units(5));
    await sync.sync();
    expect((await sync.loadLocal()).valueOrNull!.line(frap)!.syncState, CartDraftSyncState.dead);
    await sync.refresh();
    final CartLocalSnapshot local = (await sync.loadLocal()).valueOrNull!;
    expect((local.line(frap)!.quantity, local.line(frap)!.syncState), (Qty.units(5), CartDraftSyncState.dead));
    expect(local.dirty, isTrue);
  });

  group('смена варианта (10 CART-005)', () {
    const CartLineKey fresh = CartLineKey('v-new');

    Future<String?> journal() => AppMetaDao(db).read(DriftCartSync.replaceMetaKey);

    test('RC-1: direct(settle) — dead-строка старого варианта и её запись очереди снимаются ответом сервера', () async {
      repo.onPutItem = (String v, CartItemPut put, String? key) async => const FailureResult<Cart>(PermissionFailure());
      await sync.setQuantity(frap, Qty.units(5));
      await sync.sync();
      expect((await sync.loadLocal()).valueOrNull!.line(frap)!.syncState, CartDraftSyncState.dead);
      expect(await sync.watchStatus().first, const CartSyncStatus(dead: 1));
      serverAccepts();

      // Операция замены записала новую строку (5) и удалила старую.
      final Result<Cart> r = await sync.direct<Cart>(
        (int rv) async => Success<Cart>(server = serverCart(rv + 1, <CartLine>[line('v-new', 5)])),
        cartOf: (Cart c) => c,
        settle: <CartLineKey>{frap, fresh},
      );
      expect(r.isSuccess, isTrue);
      final CartLocalSnapshot local = (await sync.loadLocal()).valueOrNull!;
      expect(
        local.lines.map((CartLocalLine l) => (l.key.variantId, l.quantity.milli, l.syncState)),
        <Object>[('v-new', 5000, CartDraftSyncState.synced)],
        reason: 'одна строка с количеством сервера; «не отправлено» старой строки не осталось',
      );
      expect(local.hasUnsent, isFalse);
      expect(await sync.watchStatus().first, CartSyncStatus.idle, reason: '«Ошибка сохранения · Повторить» снята');
      await sync.retryFailed();
      expect(puts, isEmpty, reason: '«Повторить» не возвращает старую строку на сервер');
    });

    test('RC-2: обрыв после записанного PUT новой строки — сверка после перезапуска удаляет старую строку', () async {
      expect(
        (await sync.beginReplace(CartLineReplace(from: frap, to: fresh, quantity: Qty.units(2)))).isSuccess,
        isTrue,
      );
      expect(await journal(), isNotNull);
      // Сервер записал PUT новой строки, удаление старой не отправлено — приложение завершилось.
      server = serverCart(18, <CartLine>[line('v-frap', 2), line('v-new', 2)]);
      await sync.dispose();

      sync = build();
      await sync.refresh();
      expect(
        puts.map((CartItemPut p) => (p.quantity.value.milli, p.rowVersion)),
        <(int, int)>[(0, 18)],
        reason: 'старая строка удалена (PUT set 0) с базой из ответа',
      );
      expect(server.items.map((CartLine l) => (l.variantId, l.quantity.value.milli)), <(String, int)>[('v-new', 2000)]);
      final CartLocalSnapshot local = (await sync.loadLocal()).valueOrNull!;
      expect(local.line(frap), isNull);
      expect(local.hasUnsent, isFalse);
      expect(await journal(), isNull);
    });

    test('RC-2: PUT новой строки не дошёл — журнал снимается, старая строка остаётся', () async {
      await sync.beginReplace(CartLineReplace(from: frap, to: fresh, quantity: Qty.units(2)));
      await sync.dispose();
      sync = build();
      await sync.refresh();
      expect(puts, isEmpty);
      expect((await sync.loadLocal()).valueOrNull!.line(frap)!.quantity, Qty.units(2));
      expect(await journal(), isNull);
    });

    test('endReplace снимает журнал', () async {
      await sync.beginReplace(CartLineReplace(from: frap, to: fresh, quantity: Qty.units(2)));
      await sync.endReplace();
      expect(await journal(), isNull);
    });
  });

  group('T-CART-022 / CART-024: 201-я строка (400 VALIDATION_FAILED, rule max_items)', () {
    const CartLineKey fresh = CartLineKey('v-new');
    const ValidationFailure maxItems = ValidationFailure(
      errors: <FieldError>[FieldError(field: 'quantity', rule: 'max_items')],
    );

    setUp(() async {
      await db.into(db.localUnits).insert(UnitsCompanionX.unit(code: 'pc', id: 'u-pc', name: 'Штука'));
      await db
          .into(db.localProductVariants)
          .insert(
            LocalProductVariantsCompanion.insert(
              id: 'v-new',
              productId: 'p-new',
              name: 'Хром',
              serverUpdatedAt: 1,
              unitId: const Value<String?>('u-pc'),
            ),
          );
      repo.onPutItem = (String v, CartItemPut put, String? key) async {
        puts.add(put);
        return const FailureResult<Cart>(maxItems);
      };
    });

    test('addStep — отказ сервера; строки в копии нет (корзина не изменена), событие отказа', () async {
      final Future<CartSyncEvent> rejected = sync.events.firstWhere((CartSyncEvent e) => e is CartSyncRejected);
      final Result<Qty> r = await sync.addStep(fresh, priceSnapshot: Money.som(1650));
      expect(puts, hasLength(1), reason: 'изменение отправлено');
      expect(r.failureOrNull, maxItems, reason: 'каталог не показывает «Добавлено»');
      expect((await rejected as CartSyncRejected).key, fresh);
      final CartLocalSnapshot local = (await sync.loadLocal()).valueOrNull!;
      expect(local.line(fresh), isNull);
      expect(local.visibleLines.map((CartLocalLine l) => l.key), <CartLineKey>[frap]);
      expect(local.hasUnsent, isFalse);
    });

    test('сверка GET /cart после отказа не удалась — строки всё равно нет в копии', () async {
      repo.onFetch = () async => const FailureResult<Cart>(NetworkFailure(NetworkFailureKind.serverUnavailable));
      final Result<Qty> r = await sync.addStep(fresh);
      expect(r.isSuccess, isFalse);
      final CartLocalSnapshot local = (await sync.loadLocal()).valueOrNull!;
      expect(local.line(fresh), isNull);
      expect(local.line(frap)!.quantity, Qty.units(2));
    });

    test('офлайн — addStep успешен (запись в очереди), отказа нет', () async {
      offline = true;
      final Result<Qty> r = await sync.addStep(fresh);
      expect(r.valueOrNull, Qty.units(1));
      expect(puts, isEmpty);
    });
  });

  test('direct: сначала очередь, затем операция с актуальной версией; ответ — в копию', () async {
    await sync.setQuantity(frap, Qty.units(3));
    int? clearVersion;
    final Result<Cart> r = await sync.direct<Cart>(
      (int rowVersion) async {
        clearVersion = rowVersion;
        server = serverCart(rowVersion + 1, const <CartLine>[]);
        return Success<Cart>(server);
      },
      cartOf: (Cart c) => c,
      keepPending: false,
    );
    expect(r.isSuccess, isTrue);
    expect(puts, isEmpty, reason: 'изменение ещё не в очереди (sync не вызывался) — очистка его отбрасывает');
    expect(clearVersion, 17);
    expect((await sync.loadLocal()).valueOrNull!.lines, isEmpty);
  });
}

/// Вставка единицы в кэш каталога (столбцы `id`/`short_name` — схема v3).
extension UnitsCompanionX on LocalUnitsCompanion {
  static LocalUnitsCompanion unit({
    required String code,
    required String id,
    required String name,
    String? shortName,
  }) => LocalUnitsCompanion.insert(
    code: code,
    name: name,
    qtyPrecision: 0,
    id: Value<String?>(id),
    shortName: Value<String?>(shortName),
  );
}
