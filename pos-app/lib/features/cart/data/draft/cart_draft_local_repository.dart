// Черновик корзины поверх таблиц drift основы `cart_draft` / `cart_items_draft` (07 §11.2).
// Строки несут `owner_user_id` (защита при ошибке выбора файла БД, 07 §11.1 п.2): читаются и
// меняются только строки текущего пользователя. Изменения помечают корзину `dirty = 1`, строку —
// `sync_state = 'pending'`; отправку на сервер (`cart.sync`) выполняет `DriftCartSync` (этап F, RM-F-005).
// Этап F: установка количества 0 оставляет строку-метку удаления (`quantity_milli = 0`, `pending`) до ответа
// сервера — удаление переживает перезапуск и уходит в очередь `delete_item`; метки не видны в [lines]/[line]/
// [watchLines].
import 'package:drift/drift.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:uuid/uuid.dart';

/// Доступ к БД пользователя: `null` — ещё не открыта (до входа).
typedef CartDraftDatabaseAccess = AppDatabase? Function();

/// `CartDraftRepository` на drift.
final class CartDraftLocalRepository implements CartDraftRepository {
  CartDraftLocalRepository({
    required CartDraftDatabaseAccess database,
    required String? Function() ownerUserId,
    required Clock clock,
    String Function()? newId,
  }) : _db = database,
       _owner = ownerUserId,
       _clock = clock,
       _newId = newId ?? const Uuid().v4;

  final CartDraftDatabaseAccess _db;
  final String? Function() _owner;
  final Clock _clock;
  final String Function() _newId;

  Future<Result<T>> _run<T>(Future<T> Function(AppDatabase db, String owner) body) async {
    final AppDatabase? db = _db();
    final String? owner = _owner();
    if (db == null || owner == null) return const FailureResult(UnknownFailure(cause: CartDraftUnavailable()));
    try {
      return Success<T>(await body(db, owner));
    } on Object catch (e) {
      return FailureResult<T>(UnknownFailure(cause: e));
    }
  }

  Future<CartDraftRow?> _activeCart(AppDatabase db, String owner) =>
      (db.select(db.cartDraft)
            ..where((t) => t.status.equals('active') & t.ownerUserId.equals(owner))
            ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
            ..limit(1))
          .getSingleOrNull();

  Future<CartDraftRow> _ensureActiveCart(AppDatabase db, String owner) async {
    final CartDraftRow? existing = await _activeCart(db, owner);
    if (existing != null) return existing;
    final String id = _newId();
    await db
        .into(db.cartDraft)
        .insert(
          CartDraftCompanion.insert(
            localId: id,
            status: 'active',
            ownerUserId: owner,
            updatedAt: _clock.nowUtc().millisecondsSinceEpoch,
            dirty: const Value(true),
          ),
        );
    return (await _activeCart(db, owner))!;
  }

  SimpleSelectStatement<$CartItemsDraftTable, CartItemDraftRow> _itemQuery(
    AppDatabase db,
    String owner,
    String cartId,
  ) => db.select(db.cartItemsDraft)
    ..where((t) => t.localCartId.equals(cartId) & t.ownerUserId.equals(owner) & t.quantityMilli.isBiggerThanValue(0))
    ..orderBy([(t) => OrderingTerm.asc(t.lineNo)]);

  Future<CartItemDraftRow?> _findItem(
    AppDatabase db,
    String owner,
    String cartId,
    String variantId,
    String? packagingId,
  ) =>
      (db.select(db.cartItemsDraft)..where(
            (t) =>
                t.localCartId.equals(cartId) &
                t.ownerUserId.equals(owner) &
                t.variantId.equals(variantId) &
                (packagingId == null ? t.packagingId.isNull() : t.packagingId.equals(packagingId)),
          ))
          .getSingleOrNull();

  Future<void> _touch(AppDatabase db, String cartId) =>
      (db.update(db.cartDraft)..where((t) => t.localId.equals(cartId))).write(
        CartDraftCompanion(dirty: const Value(true), updatedAt: Value(_clock.nowUtc().millisecondsSinceEpoch)),
      );

  @override
  Future<Result<List<CartDraftLine>>> lines() => _run((db, owner) async {
    final CartDraftRow? cart = await _activeCart(db, owner);
    if (cart == null) return const <CartDraftLine>[];
    return [for (final r in await _itemQuery(db, owner, cart.localId).get()) _line(r)];
  });

  @override
  Stream<List<CartDraftLine>> watchLines() {
    final AppDatabase? db = _db();
    final String? owner = _owner();
    if (db == null || owner == null) return Stream<List<CartDraftLine>>.value(const <CartDraftLine>[]);
    final query =
        db.select(db.cartItemsDraft).join([
            innerJoin(db.cartDraft, db.cartDraft.localId.equalsExp(db.cartItemsDraft.localCartId)),
          ])
          ..where(
            db.cartDraft.status.equals('active') &
                db.cartDraft.ownerUserId.equals(owner) &
                db.cartItemsDraft.ownerUserId.equals(owner) &
                db.cartItemsDraft.quantityMilli.isBiggerThanValue(0),
          )
          ..orderBy([OrderingTerm.asc(db.cartItemsDraft.lineNo)]);
    return query.watch().map((rows) => [for (final r in rows) _line(r.readTable(db.cartItemsDraft))]);
  }

  @override
  Future<Result<CartDraftLine?>> line(String variantId, {String? packagingId}) => _run((db, owner) async {
    final CartDraftRow? cart = await _activeCart(db, owner);
    if (cart == null) return null;
    final CartItemDraftRow? row = await _findItem(db, owner, cart.localId, variantId, packagingId);
    return row == null || row.quantityMilli == 0 ? null : _line(row);
  });

  @override
  Future<Result<CartDraftLine>> add(CartDraftAdd add) => _run((db, owner) async {
    if (add.quantity.milli <= 0) throw ArgumentError.value(add.quantity.milli, 'quantity', '> 0');
    return db.transaction(() async {
      final CartDraftRow cart = await _ensureActiveCart(db, owner);
      final CartItemDraftRow? existing = await _findItem(db, owner, cart.localId, add.variantId, add.packagingId);
      final String itemId;
      if (existing != null) {
        itemId = existing.localItemId;
        await (db.update(db.cartItemsDraft)..where((t) => t.localItemId.equals(itemId))).write(
          CartItemsDraftCompanion(
            quantityMilli: Value(existing.quantityMilli + add.quantity.milli),
            priceSnapshotTyiyn: add.priceSnapshot == null ? const Value.absent() : Value(add.priceSnapshot!.tyiyn),
            stockSnapshotMilli: add.stockSnapshot == null ? const Value.absent() : Value(add.stockSnapshot!.milli),
            syncState: const Value('pending'),
          ),
        );
      } else {
        itemId = _newId();
        final Expression<int> maxLine = db.cartItemsDraft.lineNo.max();
        final int? last =
            await (db.selectOnly(db.cartItemsDraft)
                  ..addColumns([maxLine])
                  ..where(db.cartItemsDraft.localCartId.equals(cart.localId)))
                .map((r) => r.read(maxLine))
                .getSingleOrNull();
        await db
            .into(db.cartItemsDraft)
            .insert(
              CartItemsDraftCompanion.insert(
                localItemId: itemId,
                localCartId: cart.localId,
                variantId: add.variantId,
                packagingId: Value(add.packagingId),
                quantityMilli: add.quantity.milli,
                priceSnapshotTyiyn: Value(add.priceSnapshot?.tyiyn),
                stockSnapshotMilli: Value(add.stockSnapshot?.milli),
                lineNo: (last ?? 0) + 1,
                ownerUserId: owner,
                syncState: const Value('pending'),
              ),
            );
      }
      await _touch(db, cart.localId);
      final CartItemDraftRow row = await (db.select(
        db.cartItemsDraft,
      )..where((t) => t.localItemId.equals(itemId))).getSingle();
      return _line(row);
    });
  });

  @override
  Future<Result<CartDraftLine?>> setQuantity(String variantId, {String? packagingId, required Qty quantity}) =>
      _run((db, owner) async {
        if (quantity.milli < 0) throw ArgumentError.value(quantity.milli, 'quantity', '>= 0');
        return db.transaction(() async {
          final CartDraftRow? cart = await _activeCart(db, owner);
          if (cart == null) return null;
          final CartItemDraftRow? row = await _findItem(db, owner, cart.localId, variantId, packagingId);
          if (row == null) return null;
          if (quantity.isZero) {
            // Метка удаления до ответа сервера (этап F, `delete_item`).
            await (db.update(db.cartItemsDraft)..where((t) => t.localItemId.equals(row.localItemId))).write(
              const CartItemsDraftCompanion(quantityMilli: Value(0), syncState: Value('pending')),
            );
            await _touch(db, cart.localId);
            return null;
          }
          await (db.update(db.cartItemsDraft)..where((t) => t.localItemId.equals(row.localItemId))).write(
            CartItemsDraftCompanion(quantityMilli: Value(quantity.milli), syncState: const Value('pending')),
          );
          await _touch(db, cart.localId);
          return _line(
            await (db.select(db.cartItemsDraft)..where((t) => t.localItemId.equals(row.localItemId))).getSingle(),
          );
        });
      });

  @override
  Future<Result<String?>> warehouseId() => _run((db, owner) async => (await _activeCart(db, owner))?.warehouseId);

  static CartDraftLine _line(CartItemDraftRow r) => CartDraftLine(
    localItemId: r.localItemId,
    cartId: r.localCartId,
    variantId: r.variantId,
    packagingId: r.packagingId,
    quantity: Qty(r.quantityMilli),
    priceSnapshot: r.priceSnapshotTyiyn == null ? null : Money(r.priceSnapshotTyiyn!),
    stockSnapshot: r.stockSnapshotMilli == null ? null : Qty(r.stockSnapshotMilli!),
    lineNo: r.lineNo,
    syncState: CartDraftSyncState.parse(r.syncState),
  );
}
