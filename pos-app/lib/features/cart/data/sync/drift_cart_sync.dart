// Синхронизация черновика корзины с сервером (D-32; 07 §11.2 «Контракт записей cart.sync», §11.4; 02 SCR-20.4.1,
// SCR-20.11; ядро §19.4, §22.6) — реализация порта `CartSync` и обработчик записей outbox `cart.sync`.
//
// - Копия: `cart_draft`/`cart_items_draft` владельца сессии (`CartDraftDao`, 07 §11.1 п.2). Изменение количества —
//   целевое значение строки сразу (`pending`); удаление — строка с количеством 0 до ответа сервера (метка удаления
//   переживает перезапуск, повторная отправка идемпотентна).
// - Очередь: `set_item`/`delete_item` (`mode=set`, без `increment`); новая запись той же пары заменяет прежнюю
//   неотправленную (`CartSyncPayload.coalesceKey`); запись с тем же содержимым не дублируется (в том числе пока
//   прежняя `sending`).
// - Цепочка `rowVersion`: запись уходит с базой черновика `base_row_version`, ответ (`Cart`) становится новой базой —
//   следующая запись использует версию из ответа предыдущей. Отправка и прямые операции сериализованы.
// - `409 VERSION_CONFLICT`: строка — `dead`, очередь корзины не отправляется (`retry` без попытки) до решения
//   пользователя (`resolveConflict`, диалог UI-20-027); изменения не теряются молча (AC-UI-20-015): сверка
//   `GET /cart` (`refresh`, `direct`) сохраняет `dead`-строки, а признак конфликта хранится в `app_meta`
//   ([conflictMetaKey]) — после перезапуска `refresh` восстанавливает конфликт и диалог показывается снова
//   (ядро §22.6: «диалог с выбором пользователя, а не молчаливая победа сервера»).
// - Отказ по правилам количества (`QTY_NOT_MULTIPLE`, `QTY_BELOW_MIN`, `VARIANT_UNAVAILABLE`, `VALIDATION_FAILED`):
//   строка возвращается к значению сервера (02 SCR-20.7 «значение возвращено») и публикуется [CartSyncRejected].
// - Смена варианта (10 CART-005): прямая операция `direct(settle: {старая, новая})` снимает неотправленные изменения
//   обеих строк (их состояние записала сама операция); журнал замены в `app_meta` ([replaceMetaKey]) переживает
//   обрыв между `PUT` новой строки и удалением старой — сверка `refresh` после перезапуска завершает замену.
// - Отказ сервера по строке, добавленной на устройстве (201-я строка — `max_items`, 10 CART-024): строка убирается из
//   копии; `addStep` возвращает отказ (каталог не показывает «Добавлено»).
// - Подписи строк офлайн (название, артикул, единица, шаг) и единица `Quantity.unitId` для `set_item` — из кэша
//   каталога устройства (07 §11.3: `products`, `product_variants`, `packagings`, `units`).
// Деньги — тыйыны, количества — milli-units (D-19); цены клиент не считает (D-23).
import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/app_meta_dao.dart';
import 'package:optomstroy/core/database/daos/cart_draft_dao.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/sync/outbox_payloads.dart';
import 'package:optomstroy/core/sync/outbox_queue.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:uuid/uuid.dart';

/// Подписи и правила строки из кэша каталога.
final class _CatalogInfo {
  const _CatalogInfo({
    this.productId,
    this.productName,
    this.variantName,
    this.sku,
    this.unitId,
    this.unitLabel,
    this.packagingName,
    this.factor,
    this.step,
    this.minQuantity,
    this.qtyPrecision,
  });

  final String? productId;
  final String? productName;
  final String? variantName;
  final String? sku;
  final String? unitId;
  final String? unitLabel;
  final String? packagingName;
  final Qty? factor;
  final Qty? step;
  final Qty? minQuantity;
  final int? qtyPrecision;
}

/// `CartSync` на drift + outbox `cart.sync` + `CartRepository`; одновременно — обработчик записей `cart.sync`.
final class DriftCartSync implements CartSync, OutboxActionHandler {
  DriftCartSync({
    required AppDatabase? Function() database,
    required String? Function() owner,
    required Clock clock,
    required CartRepository repository,
    required OutboxQueue? Function() queue,
    required bool Function() offline,
    String Function()? newId,
  }) : _database = database,
       _owner = owner,
       _clock = clock,
       _repo = repository,
       _queue = queue,
       _offline = offline,
       _newId = newId ?? const Uuid().v4;

  final AppDatabase? Function() _database;
  final String? Function() _owner;
  final Clock _clock;
  final CartRepository _repo;
  final OutboxQueue? Function() _queue;
  final bool Function() _offline;
  final String Function() _newId;

  final StreamController<CartSyncEvent> _events = StreamController<CartSyncEvent>.broadcast();
  Future<void> _tail = Future<void>.value();
  CartVersionConflict? _conflict;
  String? _conflictOwner;

  /// Отказы сервера по строкам при отправке очереди (для результата [addStep]).
  final Map<CartLineKey, Failure> _rejected = <CartLineKey, Failure>{};

  /// Сколько раз подряд [sync] повторяет проход очереди, если записи корзины появились во время прохода.
  static const int _maxFlushPasses = 3;

  /// Ключ `app_meta` неразрешённого `409 VERSION_CONFLICT` (значение — `cart_draft.local_id`): конфликт переживает
  /// перезапуск. Ключа нет в перечне 07 §11.2 — F_spec_questions, раздел FIX.
  static const String conflictMetaKey = 'cart_version_conflict';

  /// Ключ `app_meta` незавершённой смены варианта ([beginReplace]; значение — JSON: `localCartId`, старая и новая
  /// пары, `quantityMilli` новой строки). Ключа нет в перечне 07 §11.2 — как и [conflictMetaKey].
  static const String replaceMetaKey = 'cart_variant_replace';

  /// Освободить поток событий.
  Future<void> dispose() => _events.close();

  // ---------------------------------------------------------------------------
  // CartSync
  // ---------------------------------------------------------------------------

  @override
  Stream<CartSyncEvent> get events => _events.stream;

  @override
  CartVersionConflict? get conflict => _conflictOwner == _owner() ? _conflict : null;

  @override
  Stream<CartLocalSnapshot?> watchLocal() async* {
    final AppDatabase? db = _database();
    final String? owner = _owner();
    if (db == null || owner == null) {
      yield null;
      return;
    }
    yield await _load(db, owner);
    await for (final Set<TableUpdate> _ in db.tableUpdates(
      TableUpdateQuery.onAllTables(<ResultSetImplementation<dynamic, dynamic>>[db.cartDraft, db.cartItemsDraft]),
    )) {
      yield await _load(db, owner);
    }
  }

  @override
  Future<Result<CartLocalSnapshot?>> loadLocal() => _run(_load);

  @override
  Stream<CartSyncStatus> watchStatus() {
    final AppDatabase? db = _database();
    final String? owner = _owner();
    if (db == null || owner == null) return Stream<CartSyncStatus>.value(CartSyncStatus.idle);
    return db
        .customSelect(
          'SELECT status, COUNT(*) AS n FROM outbox_actions WHERE owner_user_id = ? AND type = ? GROUP BY status',
          variables: <Variable<Object>>[Variable.withString(owner), Variable.withString(OutboxTypes.cartSync)],
          readsFrom: <ResultSetImplementation<dynamic, dynamic>>{db.outboxActions},
        )
        .watch()
        .map((List<QueryRow> rows) {
          var queued = 0;
          var dead = 0;
          for (final QueryRow r in rows) {
            final String status = r.read<String>('status');
            final int n = r.read<int>('n');
            if (status == 'dead') {
              dead += n;
            } else if (status != 'done') {
              queued += n;
            }
          }
          return CartSyncStatus(queued: queued, dead: dead);
        });
  }

  @override
  Future<Result<void>> setQuantity(CartLineKey key, Qty quantity) => _run((AppDatabase db, String owner) async {
    if (quantity.milli < 0) throw ArgumentError.value(quantity.milli, 'quantity', '>= 0');
    await db.transaction(() async {
      final CartDraftRow cart = await _ensureActiveCart(db, owner);
      final CartItemDraftRow? row = await _findItem(db, owner, cart.localId, key);
      if (row == null) {
        if (quantity.isZero) return;
        final Expression<int> maxLine = db.cartItemsDraft.lineNo.max();
        final int? last =
            await (db.selectOnly(db.cartItemsDraft)
                  ..addColumns(<Expression<Object>>[maxLine])
                  ..where(db.cartItemsDraft.localCartId.equals(cart.localId)))
                .map((TypedResult r) => r.read(maxLine))
                .getSingleOrNull();
        await db
            .into(db.cartItemsDraft)
            .insert(
              CartItemsDraftCompanion.insert(
                localItemId: _newId(),
                localCartId: cart.localId,
                variantId: key.variantId,
                packagingId: Value<String?>(key.packagingId),
                quantityMilli: quantity.milli,
                lineNo: (last ?? 0) + 1,
                ownerUserId: owner,
                syncState: const Value<String>('pending'),
              ),
            );
      } else {
        if (row.quantityMilli == quantity.milli && row.syncState == 'pending') return;
        await (db.update(db.cartItemsDraft)..where((t) => t.localItemId.equals(row.localItemId))).write(
          CartItemsDraftCompanion(quantityMilli: Value<int>(quantity.milli), syncState: const Value<String>('pending')),
        );
      }
      await (db.update(db.cartDraft)..where((t) => t.localId.equals(cart.localId))).write(
        CartDraftCompanion(dirty: const Value<bool>(true), updatedAt: Value<int>(_nowMs())),
      );
    });
  });

  @override
  Future<Result<Qty>> addStep(CartLineKey key, {Money? priceSnapshot}) async {
    final Result<Qty> r = await _run((AppDatabase db, String owner) async {
      final CartDraftRow cart = await _ensureActiveCart(db, owner);
      final CartItemDraftRow? row = await _findItem(db, owner, cart.localId, key);
      final CartItemDraftRow probe =
          row ??
          CartItemDraftRow(
            localItemId: '',
            localCartId: cart.localId,
            variantId: key.variantId,
            packagingId: key.packagingId,
            quantityMilli: 0,
            priceChanged: false,
            stockInsufficient: false,
            lineNo: 0,
            ownerUserId: owner,
            syncState: 'pending',
          );
      final _CatalogInfo? info = (await _catalog(db, <CartItemDraftRow>[probe]))[key];
      final Qty step = info?.step ?? Qty.units(1);
      final int current = row?.quantityMilli ?? 0;
      int next = current + step.milli;
      final Qty? min = info?.minQuantity;
      if (current == 0 && min != null && min.milli > next) next = min.milli;
      return Qty(next);
    });
    if (r case Success<Qty>(:final Qty value)) {
      final Result<void> set = await setQuantity(key, value);
      if (set case FailureResult<void>(:final Failure failure)) return FailureResult<Qty>(failure);
      if (priceSnapshot != null) {
        await _run((AppDatabase db, String owner) async {
          final CartDraftRow? cart = await _activeCart(db, owner);
          if (cart == null) return;
          final CartItemDraftRow? row = await _findItem(db, owner, cart.localId, key);
          if (row == null || _fromServer(row)) return;
          await (db.update(db.cartItemsDraft)..where((t) => t.localItemId.equals(row.localItemId))).write(
            CartItemsDraftCompanion(priceSnapshotTyiyn: Value<int?>(priceSnapshot.tyiyn)),
          );
        });
      }
      _rejected.remove(key);
      await sync();
      // Сервер отклонил это изменение при отправке (201-я строка — `max_items`, 10 CART-024; вариант не продаётся):
      // копия уже возвращена к серверной корзине, вызывающий показывает отказ вместо «Добавлено».
      final Failure? rejected = _rejected.remove(key);
      if (rejected != null) return FailureResult<Qty>(rejected);
    }
    return r;
  }

  @override
  Future<Result<void>> sync() async {
    final Result<void> queued = await _locked(() => _run(_enqueuePending));
    if (queued is FailureResult<void>) return queued;
    await _flush();
    return const Success<void>(null);
  }

  @override
  Future<Result<Cart>> refresh() async {
    await _flush();
    final Result<Cart> r = await _repo.fetch();
    if (r case Success<Cart>(:final Cart value)) {
      CartVersionConflict? restored;
      var resumed = false;
      await _locked(
        () => _run((AppDatabase db, String owner) async {
          // Неотправленные (`pending`/`dead`) строки сохраняются — сверка не решает конфликт за пользователя.
          await _adopt(db, owner, value, keepPending: true);
          restored = await _refreshConflict(db, owner, value);
          resumed = await _resumeReplace(db, owner, value);
        }),
      );
      _emit(CartServerUpdated(value));
      if (restored != null) _emit(CartConflictDetected(restored!));
      // Незавершённая смена варианта (обрыв после записанного PUT новой строки): удаление старой — через очередь.
      if (resumed) await sync();
    }
    return r;
  }

  @override
  Future<Result<void>> beginReplace(CartLineReplace replace) => _run((AppDatabase db, String owner) async {
    final CartDraftRow cart = await _ensureActiveCart(db, owner);
    await AppMetaDao(db).write(
      replaceMetaKey,
      jsonEncode(<String, Object?>{
        'localCartId': cart.localId,
        'fromVariantId': replace.from.variantId,
        'fromPackagingId': replace.from.packagingId,
        'toVariantId': replace.to.variantId,
        'toPackagingId': replace.to.packagingId,
        'quantityMilli': replace.quantity.milli,
      }),
    );
  });

  @override
  Future<void> endReplace() async {
    await _run((AppDatabase db, String owner) => AppMetaDao(db).remove(replaceMetaKey));
  }

  /// Журнал смены варианта после сверки с сервером [server]: новая строка уже записана сервером с количеством
  /// замены, а старая на сервере осталась — старая строка получает метку удаления (`pending` 0 → очередь
  /// `cart.sync`, идемпотентно). Иначе (PUT не дошёл, корзина сменилась, старой строки уже нет) журнал просто
  /// снимается: позиция не теряется. Возвращает `true`, если удаление поставлено.
  Future<bool> _resumeReplace(AppDatabase db, String owner, Cart server) async {
    final AppMetaDao meta = AppMetaDao(db);
    final String? raw = await meta.read(replaceMetaKey);
    if (raw == null) return false;
    await meta.remove(replaceMetaKey);
    final Map<String, Object?>? j = _decodeMap(raw);
    if (j == null || j['fromVariantId'] is! String || j['toVariantId'] is! String || j['quantityMilli'] is! int) {
      return false;
    }
    final CartDraftRow? cart = await _activeCart(db, owner);
    if (cart == null || cart.localId != j['localCartId']) return false;
    final CartLineKey from = CartLineKey(j['fromVariantId']! as String, j['fromPackagingId'] as String?);
    final CartLineKey to = CartLineKey(j['toVariantId']! as String, j['toPackagingId'] as String?);
    CartLine? lineOf(CartLineKey k) {
      for (final CartLine l in server.items) {
        if (l.variantId == k.variantId && l.packagingId == k.packagingId) return l;
      }
      return null;
    }

    final CartLine? written = lineOf(to);
    if (written == null || written.quantity.value.milli != j['quantityMilli'] || lineOf(from) == null) return false;
    // Количество новой строки уже записано сервером (в нём — и неотправленное количество обеих строк): их
    // локальные неотправленные изменения снимаются, как при успешной замене.
    await _settle(db, owner, <CartLineKey>{from, to});
    await _adopt(db, owner, server, keepPending: true);
    final CartItemDraftRow? row = await _findItem(db, owner, cart.localId, from);
    if (row == null) return false;
    await (db.update(db.cartItemsDraft)..where((t) => t.localItemId.equals(row.localItemId))).write(
      const CartItemsDraftCompanion(quantityMilli: Value<int>(0), syncState: Value<String>('pending')),
    );
    await (db.update(db.cartDraft)..where((t) => t.localId.equals(cart.localId))).write(
      CartDraftCompanion(dirty: const Value<bool>(true), updatedAt: Value<int>(_nowMs())),
    );
    return true;
  }

  static Map<String, Object?>? _decodeMap(String json) {
    try {
      final Object? v = jsonDecode(json);
      return v is Map ? v.cast<String, Object?>() : null;
    } on Object {
      return null;
    }
  }

  /// Конфликт после сверки: неразрешённый — с актуальной серверной корзиной [current]; после перезапуска —
  /// восстанавливается по признаку `app_meta` и `dead`-строкам копии. Возвращает конфликт для показа диалога.
  Future<CartVersionConflict?> _refreshConflict(AppDatabase db, String owner, Cart current) async {
    final AppMetaDao meta = AppMetaDao(db);
    final String? marked = await meta.read(conflictMetaKey);
    final CartVersionConflict? existing = conflict;
    final String? localCartId = existing?.localCartId ?? marked;
    if (localCartId == null) return null;
    final CartLocalSnapshot? local = await _load(db, owner);
    final List<CartLocalLine> unsent = <CartLocalLine>[
      for (final CartLocalLine l in local?.lines ?? const <CartLocalLine>[])
        if (l.isUnsent) l,
    ];
    if (local == null || local.localCartId != localCartId || unsent.isEmpty) {
      // Неотправленного не осталось (или корзина сменилась) — конфликта нет.
      await meta.remove(conflictMetaKey);
      if (existing != null) _clearConflict();
      return null;
    }
    final CartVersionConflict c = CartVersionConflict(localCartId: localCartId, current: current, unsent: unsent);
    _conflict = c;
    _conflictOwner = owner;
    return c;
  }

  void _clearConflict() {
    _conflict = null;
    _conflictOwner = null;
  }

  @override
  Future<Result<T>> direct<T>(
    Future<Result<T>> Function(int rowVersion) op, {
    required Cart? Function(T value) cartOf,
    bool keepPending = true,
    Set<CartLineKey> settle = const <CartLineKey>{},
  }) async {
    await _flush();
    return _locked(() async {
      final AppDatabase? db = _database();
      final String? owner = _owner();
      if (db == null || owner == null) return FailureResult<T>(const UnknownFailure(cause: CartDraftUnavailable()));
      final Result<int> base = await _baseRowVersion(db, owner);
      if (base case FailureResult<int>(:final Failure failure)) return FailureResult<T>(failure);
      final Result<T> r = await op(base.valueOrNull!);
      switch (r) {
        case Success<T>(:final T value):
          final Cart? cart = cartOf(value);
          if (cart != null) {
            if (settle.isNotEmpty) await _guard(() => _settle(db, owner, settle));
            await _guard(() => _adopt(db, owner, cart, keepPending: keepPending));
            if (!keepPending) {
              // Копия = ответ сервера (очистка, «Отложить», «Продолжить»): неотправленного не осталось.
              await _guard(() => _dropQueue(db, owner));
              await _guard(() => AppMetaDao(db).remove(conflictMetaKey));
              _clearConflict();
            }
            _emit(CartServerUpdated(cart));
          }
        case FailureResult<T>(:final Failure failure):
          final Cart? current = _repo.conflictCurrent(failure);
          if (current != null) {
            await _guard(() => _adopt(db, owner, current, keepPending: true));
            _emit(CartServerUpdated(current));
          }
      }
      return r;
    });
  }

  @override
  Future<Result<void>> resolveConflict({required bool applyMine}) async {
    final Result<void> r = await _locked(
      () => _run((AppDatabase db, String owner) async {
        final CartVersionConflict? c = conflict;
        Cart? current = c?.current;
        if (current == null) {
          final Result<Cart> fetched = await _repo.fetch();
          if (fetched case FailureResult<Cart>(:final Failure failure)) throw _FailureException(failure);
          current = fetched.valueOrNull;
        }
        final CartDraftRow cart = await _ensureActiveCart(db, owner);
        if (applyMine) {
          await (db.update(db.cartItemsDraft)..where(
                (t) => t.localCartId.equals(cart.localId) & t.ownerUserId.equals(owner) & t.syncState.equals('dead'),
              ))
              .write(const CartItemsDraftCompanion(syncState: Value<String>('pending')));
          await _dropQueue(db, owner);
          await _adopt(db, owner, current!, keepPending: true);
          await _enqueuePending(db, owner);
        } else {
          await _dropQueue(db, owner);
          await _adopt(db, owner, current!, keepPending: false);
        }
        await AppMetaDao(db).remove(conflictMetaKey);
        _clearConflict();
        _emit(CartServerUpdated(current));
      }),
    );
    if (r.isSuccess && applyMine) await _flush();
    return r;
  }

  @override
  Future<Result<void>> retryFailed() async {
    final Result<void> r = await _locked(
      () => _run((AppDatabase db, String owner) async {
        await (db.update(db.cartItemsDraft)..where((t) => t.ownerUserId.equals(owner) & t.syncState.equals('dead')))
            .write(const CartItemsDraftCompanion(syncState: Value<String>('pending')));
        await (db.delete(db.outboxActions)..where(
              (t) => t.ownerUserId.equals(owner) & t.type.equals(OutboxTypes.cartSync) & t.status.equals('dead'),
            ))
            .go();
      }),
    );
    if (r is FailureResult<void>) return r;
    return sync();
  }

  @override
  Future<Result<List<CartWarehouseOption>>> warehouses() => _run((AppDatabase db, String owner) async {
    final List<WarehouseRow> rows =
        await (db.select(db.localWarehouses)
              ..where((t) => t.isActive.equals(true))
              ..orderBy(<OrderClauseGenerator<$LocalWarehousesTable>>[
                (t) => OrderingTerm.desc(t.isDefault),
                (t) => OrderingTerm.asc(t.name),
              ]))
            .get();
    return <CartWarehouseOption>[
      for (final WarehouseRow w in rows) CartWarehouseOption(id: w.id, name: w.name, isDefault: w.isDefault),
    ];
  });

  @override
  Future<CartPlaceLabels> placeLabels({String? warehouseId, String? priceListId}) async {
    final AppDatabase? db = _database();
    if (db == null) return (warehouse: null, priceList: null);
    try {
      final WarehouseRow? w = warehouseId == null
          ? null
          : await (db.select(db.localWarehouses)..where((t) => t.id.equals(warehouseId))).getSingleOrNull();
      final PriceListRow? p = priceListId == null
          ? null
          : await (db.select(db.localPriceLists)..where((t) => t.id.equals(priceListId))).getSingleOrNull();
      return (warehouse: w?.name, priceList: p?.name);
    } on Object {
      return (warehouse: null, priceList: null);
    }
  }

  // ---------------------------------------------------------------------------
  // OutboxActionHandler (`cart.sync`)
  // ---------------------------------------------------------------------------

  @override
  Set<String> get types => const <String>{OutboxTypes.cartSync};

  @override
  Future<OutboxOutcome> handle(OutboxAction action) => _locked(() => _handle(action));

  Future<OutboxOutcome> _handle(OutboxAction action) async {
    final CartSyncPayload? payload = CartSyncPayload.tryParse(action.payload);
    if (payload == null) return OutboxOutcome.dead;
    final AppDatabase? db = action.database ?? _database();
    final String? owner = _owner();
    if (db == null || owner == null) return OutboxOutcome.deferred;
    // Запись удалена, пока ждала очереди (очистка, «Отложить», решение конфликта) — отправлять нечего.
    final OutboxActionRow? still = await (db.select(
      db.outboxActions,
    )..where((t) => t.id.equals(action.id))).getSingleOrNull();
    if (still == null) return OutboxOutcome.done;
    final CartDraftRow? cart = await (db.select(
      db.cartDraft,
    )..where((t) => t.localId.equals(payload.localCartId) & t.ownerUserId.equals(owner))).getSingleOrNull();
    if (cart == null) return OutboxOutcome.done; // корзина конвертирована / удалена
    if (conflict?.localCartId == cart.localId) return OutboxOutcome.retry; // ждёт решения пользователя
    final Result<int> base = await _baseRowVersion(db, owner);
    if (base case FailureResult<int>(:final Failure failure)) return outboxOutcomeOf(failure);
    final int rowVersion = base.valueOrNull!;
    final CartLineKey? key = payload.variantId == null ? null : CartLineKey(payload.variantId!, payload.packagingId);
    final CartItemDraftRow? row = key == null ? null : await _findItem(db, owner, cart.localId, key);

    final Future<Result<Cart>> request = switch (payload.op) {
      CartSyncOp.setItem => _repo.putItem(
        key!.variantId,
        CartItemPut(
          quantity: LineQuantity(value: payload.quantity!, unitId: payload.unitId!, packagingId: key.packagingId),
          rowVersion: rowVersion,
          // Цена, которую видел пользователь, — только для новой строки (предупреждение `price_changed`, D-23).
          priceSnapshot: row != null && !_fromServer(row) && row.priceSnapshotTyiyn != null
              ? Money(row.priceSnapshotTyiyn!)
              : null,
        ),
        idempotencyKey: action.idempotencyKey,
      ),
      CartSyncOp.deleteItem => _deleteLine(db, key!, row, rowVersion, action.idempotencyKey),
      CartSyncOp.setWarehouse => _repo.setWarehouse(
        payload.fields['warehouseId']! as String,
        rowVersion: rowVersion,
        idempotencyKey: action.idempotencyKey,
      ),
      CartSyncOp.setCustomer => _repo.setCustomer(
        payload.fields['customerId']! as String,
        rowVersion: rowVersion,
        receiver: const Receiver.customer(),
        idempotencyKey: action.idempotencyKey,
      ),
      CartSyncOp.clearCustomer => _repo.clearCustomer(idempotencyKey: action.idempotencyKey),
      CartSyncOp.setDiscount => _repo.applyDiscount(
        CartDiscountInput(
          percent: Percent(payload.fields['discountPercentHundredths']! as int),
          rowVersion: rowVersion,
        ),
        idempotencyKey: action.idempotencyKey,
      ),
    };
    final Result<Cart> r = await request;
    return _outcome(db, owner, cart.localId, payload, key, r, action.id);
  }

  Future<OutboxOutcome> _outcome(
    AppDatabase db,
    String owner,
    String localCartId,
    CartSyncPayload payload,
    CartLineKey? key,
    Result<Cart> r,
    int actionId,
  ) async {
    final CartDraftDao dao = CartDraftDao(db, ownerUserId: owner);
    switch (r) {
      case Success<Cart>(:final Cart value):
        await db.transaction(() async {
          if (key != null) {
            final CartItemDraftRow? now = await _findItem(db, owner, localCartId, key);
            final int sent = payload.op == CartSyncOp.deleteItem ? 0 : payload.quantity!.milli;
            if (now != null &&
                now.syncState == 'pending' &&
                now.quantityMilli == sent &&
                !await _hasOtherEntries(db, owner, payload.coalesceKey, actionId)) {
              await dao.setItemSyncState(localCartId, key.variantId, key.packagingId, 'synced');
            }
          }
          await dao.applyServer(localCartId, _snapshot(value), nowMs: _nowMs());
        });
        _emit(CartServerUpdated(value));
        return OutboxOutcome.done;
      case FailureResult<Cart>(:final Failure failure):
        if (failure is ConflictFailure && failure.kind == ConflictKind.versionConflict) {
          Cart? current = _repo.conflictCurrent(failure);
          current ??= (await _repo.fetch()).valueOrNull;
          if (key != null) await dao.setItemSyncState(localCartId, key.variantId, key.packagingId, 'dead');
          final CartLocalSnapshot? local = await _load(db, owner);
          final CartVersionConflict c = CartVersionConflict(
            localCartId: localCartId,
            current: current,
            unsent: <CartLocalLine>[
              for (final CartLocalLine l in local?.lines ?? const <CartLocalLine>[])
                if (l.isUnsent) l,
            ],
          );
          _conflict = c;
          _conflictOwner = owner;
          await AppMetaDao(db).write(conflictMetaKey, localCartId);
          _emit(CartConflictDetected(c));
          return OutboxOutcome.dead;
        }
        if (payload.op == CartSyncOp.deleteItem && key != null && _isNotFound(failure)) {
          // Строки на сервере уже нет — удаление выполнено.
          final String? packagingId = key.packagingId;
          await (db.delete(db.cartItemsDraft)..where(
                (t) =>
                    t.localCartId.equals(localCartId) &
                    t.ownerUserId.equals(owner) &
                    t.variantId.equals(key.variantId) &
                    (packagingId == null ? t.packagingId.isNull() : t.packagingId.equals(packagingId)) &
                    t.quantityMilli.equals(0),
              ))
              .go();
          return OutboxOutcome.done;
        }
        final OutboxOutcome outcome = outboxOutcomeOf(failure);
        if (outcome != OutboxOutcome.dead) return outcome;
        if (key != null) _rejected[key] = failure;
        if (key != null && _revertsToServer(failure)) {
          // Значение возвращается к серверному (02 SCR-20.7): строка — `synced`, копия = ответ `GET /cart`.
          final CartItemDraftRow? now = await _findItem(db, owner, localCartId, key);
          if (now != null && !_fromServer(now)) {
            // Строку добавили на устройстве, сервер её не принял (201-я строка — `max_items`, 10 CART-024): на
            // сервере её нет — копия без неё («корзина не изменена»), даже если сверка ниже не удастся.
            await (db.delete(db.cartItemsDraft)..where((t) => t.localItemId.equals(now.localItemId))).go();
          }
          await dao.setItemSyncState(localCartId, key.variantId, key.packagingId, 'synced');
          final Result<Cart> fresh = await _repo.fetch();
          if (fresh case Success<Cart>(:final Cart value)) {
            await dao.applyServer(localCartId, _snapshot(value), nowMs: _nowMs());
            _emit(CartServerUpdated(value));
          }
        } else if (key != null) {
          await dao.setItemSyncState(localCartId, key.variantId, key.packagingId, 'dead');
        }
        _emit(CartSyncRejected(failure, key: key));
        return OutboxOutcome.dead;
    }
  }

  /// Удаление строки: с упаковкой — `DELETE ?packagingId=`; без упаковки — `PUT mode=set 0` (DELETE без
  /// `packagingId` удалил бы все строки варианта, 08 §4.7.3), если единица строки известна.
  Future<Result<Cart>> _deleteLine(
    AppDatabase db,
    CartLineKey key,
    CartItemDraftRow? row,
    int rowVersion,
    String idempotencyKey,
  ) async {
    if (key.packagingId == null) {
      final String? unitId = row?.unitId ?? (await _catalog(db, <CartItemDraftRow>[?row]))[key]?.unitId;
      if (unitId != null) {
        return _repo.putItem(
          key.variantId,
          CartItemPut(
            quantity: LineQuantity(value: Qty.zero, unitId: unitId),
            rowVersion: rowVersion,
          ),
          idempotencyKey: idempotencyKey,
        );
      }
    }
    return _repo.deleteItem(key.variantId, packagingId: key.packagingId, idempotencyKey: idempotencyKey);
  }

  // ---------------------------------------------------------------------------
  // Внутреннее
  // ---------------------------------------------------------------------------

  void _emit(CartSyncEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  int _nowMs() => _clock.nowUtc().millisecondsSinceEpoch;

  /// Последовательное выполнение: отправка записей очереди и прямые операции не пересекаются (цепочка версий).
  Future<T> _locked<T>(Future<T> Function() body) async {
    final Future<void> previous = _tail;
    final Completer<void> done = Completer<void>();
    _tail = done.future;
    try {
      await previous;
      return await body();
    } finally {
      done.complete();
    }
  }

  Future<Result<T>> _run<T>(Future<T> Function(AppDatabase db, String owner) body) async {
    final AppDatabase? db = _database();
    final String? owner = _owner();
    if (db == null || owner == null) return FailureResult<T>(const UnknownFailure(cause: CartDraftUnavailable()));
    try {
      return Success<T>(await body(db, owner));
    } on _FailureException catch (e) {
      return FailureResult<T>(e.failure);
    } on Object catch (e) {
      return FailureResult<T>(UnknownFailure(cause: e));
    }
  }

  static Future<void> _guard(Future<void> Function() body) async {
    try {
      await body();
    } on Object {
      // Копия обновится следующим ответом сервера; ошибка БД не меняет исход серверной операции.
    }
  }

  /// Отправить очередь, если есть сеть; повторить проход, если записи корзины появились во время прохода.
  Future<void> _flush() async {
    final OutboxQueue? q = _queue();
    if (q == null) return;
    for (var i = 0; i < _maxFlushPasses; i++) {
      if (_offline()) return;
      final OutboxFlushReport report;
      try {
        report = await q.flush();
      } on Object {
        return;
      }
      if (report.deferred || report.interrupted) return;
      if (!await _hasReadyEntries()) return;
    }
  }

  Future<bool> _hasReadyEntries() async {
    final AppDatabase? db = _database();
    final String? owner = _owner();
    if (db == null || owner == null) return false;
    try {
      final OutboxActionRow? row =
          await (db.select(db.outboxActions)
                ..where(
                  (t) =>
                      t.ownerUserId.equals(owner) &
                      t.type.equals(OutboxTypes.cartSync) &
                      t.status.equals('pending') &
                      t.nextAttemptAt.isNull(),
                )
                ..limit(1))
              .getSingleOrNull();
      return row != null;
    } on Object {
      return false;
    }
  }

  Future<CartDraftRow?> _activeCart(AppDatabase db, String owner) => CartDraftDao(db, ownerUserId: owner).activeCart();

  Future<CartDraftRow> _ensureActiveCart(AppDatabase db, String owner) async {
    final CartDraftRow? existing = await _activeCart(db, owner);
    if (existing != null) return existing;
    await db
        .into(db.cartDraft)
        .insert(
          CartDraftCompanion.insert(
            localId: _newId(),
            status: 'active',
            ownerUserId: owner,
            updatedAt: _nowMs(),
            dirty: const Value<bool>(true),
          ),
        );
    return (await _activeCart(db, owner))!;
  }

  Future<CartItemDraftRow?> _findItem(AppDatabase db, String owner, String cartId, CartLineKey key) =>
      (db.select(db.cartItemsDraft)
            ..where(
              (t) =>
                  t.localCartId.equals(cartId) &
                  t.ownerUserId.equals(owner) &
                  t.variantId.equals(key.variantId) &
                  (key.packagingId == null ? t.packagingId.isNull() : t.packagingId.equals(key.packagingId!)),
            )
            ..limit(1))
          .getSingleOrNull();

  /// Строка пришла из ответа сервера (`applyServer` задаёт `local_item_id = '<cart>:<пара>'`).
  static bool _fromServer(CartItemDraftRow row) => row.localItemId.startsWith('${row.localCartId}:');

  /// База `rowVersion`: из черновика; если сервер корзину ещё не видел — `GET /cart` (копия обновляется).
  Future<Result<int>> _baseRowVersion(AppDatabase db, String owner) async {
    final CartDraftRow cart = await _ensureActiveCart(db, owner);
    final int? base = cart.baseRowVersion;
    if (base != null) return Success<int>(base);
    final Result<Cart> r = await _repo.fetch();
    switch (r) {
      case Success<Cart>(:final Cart value):
        await _adopt(db, owner, value, keepPending: true);
        _emit(CartServerUpdated(value));
        return Success<int>(value.rowVersion);
      case FailureResult<Cart>(:final Failure failure):
        return FailureResult<int>(failure);
    }
  }

  Future<void> _adopt(AppDatabase db, String owner, Cart cart, {required bool keepPending}) async {
    final CartDraftRow local = await _ensureActiveCart(db, owner);
    await CartDraftDao(
      db,
      ownerUserId: owner,
    ).applyServer(local.localId, _snapshot(cart), nowMs: _nowMs(), keepPending: keepPending);
  }

  /// Строки [keys] принимают значение следующего ответа сервера: `synced` (неотправленное количество снято) и без
  /// записей `cart.sync` этой пары в очереди (в том числе `dead` — «Ошибка сохранения · Повторить»).
  Future<void> _settle(AppDatabase db, String owner, Set<CartLineKey> keys) async {
    final CartDraftRow? cart = await _activeCart(db, owner);
    if (cart == null) return;
    final CartDraftDao dao = CartDraftDao(db, ownerUserId: owner);
    final Set<String> pairs = <String>{};
    for (final CartLineKey k in keys) {
      await dao.setItemSyncState(cart.localId, k.variantId, k.packagingId, 'synced');
      pairs.add(
        CartSyncPayload.deleteItem(
          localCartId: cart.localId,
          variantId: k.variantId,
          packagingId: k.packagingId,
        ).coalesceKey,
      );
    }
    final List<OutboxActionRow> rows =
        await (db.select(db.outboxActions)..where(
              (t) => t.ownerUserId.equals(owner) & t.type.equals(OutboxTypes.cartSync) & t.status.isNotValue('done'),
            ))
            .get();
    final List<int> stale = <int>[
      for (final OutboxActionRow r in rows)
        if (_parse(r.payloadJson)?.coalesceKey case final String c when pairs.contains(c)) r.id,
    ];
    if (stale.isNotEmpty) await (db.delete(db.outboxActions)..where((t) => t.id.isIn(stale))).go();
  }

  /// Удалить неподтверждённые записи `cart.sync` владельца (корзина заменена ответом сервера).
  Future<void> _dropQueue(AppDatabase db, String owner) =>
      (db.delete(db.outboxActions)..where(
            (t) => t.ownerUserId.equals(owner) & t.type.equals(OutboxTypes.cartSync) & t.status.isNotValue('done'),
          ))
          .go();

  Future<bool> _hasOtherEntries(AppDatabase db, String owner, String coalesceKey, int exceptId) async {
    for (final _Entry e in await _entries(db, owner)) {
      if (e.id != exceptId && e.coalesceKey == coalesceKey && e.status != 'sending') return true;
    }
    return false;
  }

  Future<List<_Entry>> _entries(AppDatabase db, String owner) async {
    final List<OutboxActionRow> rows =
        await (db.select(db.outboxActions)..where(
              (t) =>
                  t.ownerUserId.equals(owner) &
                  t.type.equals(OutboxTypes.cartSync) &
                  t.status.isIn(const <String>['pending', 'sending', 'failed']),
            ))
            .get();
    return <_Entry>[
      for (final OutboxActionRow r in rows)
        if (_parse(r.payloadJson) case final CartSyncPayload p)
          _Entry(id: r.id, status: r.status, json: r.payloadJson, coalesceKey: p.coalesceKey),
    ];
  }

  static CartSyncPayload? _parse(String json) {
    try {
      final Object? v = jsonDecode(json);
      return v is Map ? CartSyncPayload.tryParse(v.cast<String, Object?>()) : null;
    } on Object {
      return null;
    }
  }

  /// `pending`-строки активной корзины → записи `cart.sync` (без дублей; прежняя неотправленная запись той же
  /// пары заменяется). Строка без известной единицы ждёт загрузки кэша каталога (`Quantity.unitId` обязателен).
  Future<void> _enqueuePending(AppDatabase db, String owner) async {
    final OutboxQueue? q = _queue();
    if (q == null) return;
    final CartDraftRow? cart = await _activeCart(db, owner);
    if (cart == null) return;
    final List<CartItemDraftRow> pending = <CartItemDraftRow>[
      for (final CartItemDraftRow r in await CartDraftDao(db, ownerUserId: owner).items(cart.localId))
        if (r.syncState == 'pending') r,
    ];
    if (pending.isEmpty) return;
    final Map<CartLineKey, _CatalogInfo> info = await _catalog(db, pending);
    final List<_Entry> existing = await _entries(db, owner);
    for (final CartItemDraftRow row in pending) {
      final CartLineKey key = CartLineKey(row.variantId, row.packagingId);
      final CartSyncPayload payload;
      if (row.quantityMilli == 0) {
        payload = CartSyncPayload.deleteItem(
          localCartId: cart.localId,
          variantId: row.variantId,
          packagingId: row.packagingId,
        );
      } else {
        final String? unitId = row.unitId ?? info[key]?.unitId;
        if (unitId == null) continue;
        if (row.unitId == null) {
          await (db.update(db.cartItemsDraft)..where((t) => t.localItemId.equals(row.localItemId))).write(
            CartItemsDraftCompanion(unitId: Value<String?>(unitId)),
          );
        }
        payload = CartSyncPayload.setItem(
          localCartId: cart.localId,
          variantId: row.variantId,
          packagingId: row.packagingId,
          unitId: unitId,
          quantity: Qty(row.quantityMilli),
        );
      }
      final Map<String, Object?> json = payload.toJson();
      final String encoded = OutboxQueue.encodePayload(json);
      final List<_Entry> same = <_Entry>[
        for (final _Entry e in existing)
          if (e.coalesceKey == payload.coalesceKey) e,
      ];
      if (same.any((_Entry e) => e.json == encoded)) continue;
      final List<int> stale = <int>[
        for (final _Entry e in same)
          if (e.status != 'sending') e.id,
      ];
      if (stale.isNotEmpty) await (db.delete(db.outboxActions)..where((t) => t.id.isIn(stale))).go();
      await q.enqueue(OutboxTypes.cartSync, json);
    }
  }

  Future<CartLocalSnapshot?> _load(AppDatabase db, String owner) async {
    final CartDraftDao dao = CartDraftDao(db, ownerUserId: owner);
    final CartDraftRow? cart = await dao.activeCart();
    if (cart == null) return null;
    final List<CartItemDraftRow> rows = await dao.items(cart.localId);
    final Map<CartLineKey, _CatalogInfo> info = await _catalog(db, rows);
    return CartLocalSnapshot(
      localCartId: cart.localId,
      serverId: cart.serverId,
      baseRowVersion: cart.baseRowVersion,
      serverSyncedAt: cart.serverSyncedAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(cart.serverSyncedAt!, isUtc: true),
      dirty: cart.dirty,
      warehouseId: cart.warehouseId,
      priceListId: cart.priceListId,
      customerId: cart.customerId,
      discount: Percent(cart.discountPercentHundredths),
      lines: <CartLocalLine>[
        for (final CartItemDraftRow r in rows) _line(r, info[CartLineKey(r.variantId, r.packagingId)]),
      ],
    );
  }

  static CartLocalLine _line(CartItemDraftRow r, _CatalogInfo? i) => CartLocalLine(
    key: CartLineKey(r.variantId, r.packagingId),
    quantity: Qty(r.quantityMilli),
    syncState: CartDraftSyncState.parse(r.syncState),
    lineNo: r.lineNo,
    unitId: r.unitId ?? i?.unitId,
    priceSnapshot: r.priceSnapshotTyiyn == null ? null : Money(r.priceSnapshotTyiyn!),
    stockSnapshot: r.stockSnapshotMilli == null ? null : Qty(r.stockSnapshotMilli!),
    priceChanged: r.priceChanged,
    stockInsufficient: r.stockInsufficient,
    productId: i?.productId,
    productName: i?.productName,
    variantName: i?.variantName,
    sku: i?.sku,
    unitLabel: i?.unitLabel,
    packagingName: i?.packagingName,
    factor: i?.factor,
    step: i?.step,
    minQuantity: i?.minQuantity,
    qtyPrecision: i?.qtyPrecision,
  );

  /// Подписи и правила строк из кэша каталога (пустая карта, если кэш не загружен).
  Future<Map<CartLineKey, _CatalogInfo>> _catalog(AppDatabase db, List<CartItemDraftRow> rows) async {
    if (rows.isEmpty) return const <CartLineKey, _CatalogInfo>{};
    try {
      final Set<String> variantIds = <String>{for (final CartItemDraftRow r in rows) r.variantId};
      final Set<String> packagingIds = <String>{
        for (final CartItemDraftRow r in rows)
          if (r.packagingId != null) r.packagingId!,
      };
      final Map<String, ProductVariantRow> variants = <String, ProductVariantRow>{
        for (final ProductVariantRow v in await (db.select(
          db.localProductVariants,
        )..where((t) => t.id.isIn(variantIds))).get())
          v.id: v,
      };
      final Set<String> productIds = <String>{for (final ProductVariantRow v in variants.values) v.productId};
      final Map<String, ProductRow> products = <String, ProductRow>{
        for (final ProductRow p in await (db.select(db.localProducts)..where((t) => t.id.isIn(productIds))).get())
          p.id: p,
      };
      final Map<String, PackagingRow> packagings = packagingIds.isEmpty
          ? const <String, PackagingRow>{}
          : <String, PackagingRow>{
              for (final PackagingRow p in await (db.select(
                db.localPackagings,
              )..where((t) => t.id.isIn(packagingIds))).get())
                p.id: p,
            };
      final List<UnitRow> units = await db.select(db.localUnits).get();
      final Map<String, UnitRow> unitById = <String, UnitRow>{
        for (final UnitRow u in units)
          if (u.id != null) u.id!: u,
      };
      final Map<String, UnitRow> unitByCode = <String, UnitRow>{for (final UnitRow u in units) u.code: u};
      final Map<CartLineKey, _CatalogInfo> out = <CartLineKey, _CatalogInfo>{};
      for (final CartItemDraftRow r in rows) {
        final ProductVariantRow? v = variants[r.variantId];
        final ProductRow? p = v == null ? null : products[v.productId];
        final PackagingRow? pk = r.packagingId == null ? null : packagings[r.packagingId];
        final UnitRow? baseUnit =
            unitById[v?.unitId ?? p?.baseUnitId ?? ''] ?? (p == null ? null : unitByCode[p.baseUnitCode]);
        final String? unitId = pk != null
            ? (pk.unitId ?? unitByCode[pk.unitCode]?.id)
            : (v?.unitId ?? p?.baseUnitId ?? baseUnit?.id);
        final int? multiplicity = v?.multiplicityMilli ?? p?.multiplicityMilli;
        out[CartLineKey(r.variantId, r.packagingId)] = _CatalogInfo(
          productId: p?.id ?? v?.productId,
          productName: p?.name,
          variantName: (p?.hasVariants ?? false) ? v?.name : null,
          sku: v?.sku ?? p?.sku,
          unitId: unitId,
          unitLabel: pk != null ? pk.name : (baseUnit?.shortName ?? baseUnit?.name),
          packagingName: pk?.name,
          factor: pk == null ? null : Qty(pk.factorMilli),
          step: pk != null ? Qty.units(1) : (multiplicity != null && multiplicity > 0 ? Qty(multiplicity) : null),
          minQuantity: pk == null && p?.minQtyMilli != null && p!.minQtyMilli! > 0 ? Qty(p.minQtyMilli!) : null,
          qtyPrecision: pk != null ? 0 : (baseUnit?.qtyPrecision ?? p?.qtyPrecision),
        );
      }
      return out;
    } on Object {
      return const <CartLineKey, _CatalogInfo>{};
    }
  }

  static ServerCartSnapshot _snapshot(Cart cart) => ServerCartSnapshot(
    serverId: cart.id,
    status: cart.status.value,
    rowVersion: cart.rowVersion,
    name: cart.name,
    customerId: cart.customer?.id,
    warehouseId: cart.warehouseId,
    priceListId: cart.priceListId,
    discountPercentHundredths: cart.requestedDiscountPercent?.hundredths ?? 0,
    lines: <ServerCartLine>[
      for (final CartLine l in cart.items)
        ServerCartLine(
          variantId: l.variantId,
          packagingId: l.packagingId,
          quantityMilli: l.quantity.value.milli,
          unitId: l.quantity.unitId,
          priceSnapshotTyiyn: l.unitPrice?.tyiyn,
          stockSnapshotMilli: l.available?.milli,
          priceChanged: l.warnings.contains(CartItemWarning.priceChanged),
          stockInsufficient: l.warnings.contains(CartItemWarning.stockInsufficient),
        ),
    ],
  );

  static bool _isNotFound(Failure f) =>
      f is ServerFailure && (f.status == 404 || f.code == 'NOT_FOUND' || f.code == 'CART_ITEM_NOT_FOUND');

  /// Отказ по правилам строки: значение возвращается к серверному.
  static bool _revertsToServer(Failure f) => switch (f) {
    ConflictFailure(:final ConflictKind kind) =>
      kind == ConflictKind.qtyNotMultiple ||
          kind == ConflictKind.qtyBelowMin ||
          kind == ConflictKind.variantUnavailable ||
          kind == ConflictKind.stockInsufficient ||
          kind == ConflictKind.priceChanged,
    ValidationFailure() => true,
    _ => false,
  };
}

/// Запись очереди `cart.sync` (для сжатия).
final class _Entry {
  const _Entry({required this.id, required this.status, required this.json, required this.coalesceKey});

  final int id;
  final String status;
  final String json;
  final String coalesceKey;
}

/// Ошибка сервера внутри [DriftCartSync._run].
final class _FailureException implements Exception {
  const _FailureException(this.failure);

  final Failure failure;
}
