// `cart_draft` / `cart_items_draft` — черновик корзины и его синхронизация с сервером (07 §11.2, §11.4; D-32,
// DATA-253). Сервер — истина: ответ (`Cart`) перезаписывает черновик и `base_row_version` ([applyServer]); локальные
// изменения помечают корзину `dirty=1`, строку — `sync_state='pending'`; записи `cart.sync` отправляет обработчик
// очереди фичи cart. Все операции ограничены владельцем `owner_user_id` (07 §11.1 п.2: защита при ошибке выбора
// файла; очередь A не отправляется с токеном B). Деньги — тыйыны, количества — milli-units (D-19).
import 'package:drift/drift.dart';
import 'package:optomstroy/core/database/app_database.dart';

/// Строка серверной корзины для [CartDraftDao.applyServer] (ядро не знает сущностей фич — FL-04).
final class ServerCartLine {
  const ServerCartLine({
    required this.variantId,
    required this.quantityMilli,
    required this.unitId,
    this.packagingId,
    this.priceSnapshotTyiyn,
    this.stockSnapshotMilli,
    this.priceChanged = false,
    this.stockInsufficient = false,
  });

  final String variantId;
  final String? packagingId;

  /// В единицах строки (упаковки — целые, 07 §11.2 «Уточнения»).
  final int quantityMilli;
  final String unitId;

  /// Цена за единицу строки из ответа (`unitPrice`) — для показа «было/стало» офлайн.
  final int? priceSnapshotTyiyn;

  /// `available` строки (базовая единица).
  final int? stockSnapshotMilli;
  final bool priceChanged;
  final bool stockInsufficient;
}

/// Снимок серверной корзины для [CartDraftDao.applyServer].
final class ServerCartSnapshot {
  const ServerCartSnapshot({
    required this.serverId,
    required this.status,
    required this.rowVersion,
    required this.lines,
    this.name,
    this.customerId,
    this.warehouseId,
    this.priceListId,
    this.discountPercentHundredths = 0,
  });

  final String serverId;

  /// `active|parked|converted|cleared`.
  final String status;
  final int rowVersion;
  final List<ServerCartLine> lines;
  final String? name;
  final String? customerId;
  final String? warehouseId;
  final String? priceListId;

  /// Запрошенная ручная скидка (сотые процента, 0…10000).
  final int discountPercentHundredths;
}

/// Доступ к черновику корзины владельца [ownerUserId] в БД пользователя.
final class CartDraftDao {
  CartDraftDao(this._db, {required this.ownerUserId});

  final AppDatabase _db;

  /// `sub` access-токена текущей сессии.
  final String ownerUserId;

  /// Активная корзина владельца (последняя изменённая, если по ошибке их несколько).
  Future<CartDraftRow?> activeCart() =>
      (_db.select(_db.cartDraft)
            ..where((t) => t.status.equals('active') & t.ownerUserId.equals(ownerUserId))
            ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
            ..limit(1))
          .getSingleOrNull();

  /// Изменения активной корзины.
  Stream<CartDraftRow?> watchActiveCart() =>
      (_db.select(_db.cartDraft)
            ..where((t) => t.status.equals('active') & t.ownerUserId.equals(ownerUserId))
            ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
            ..limit(1))
          .watchSingleOrNull();

  /// Строки корзины [localCartId] по `line_no`.
  Future<List<CartItemDraftRow>> items(String localCartId) =>
      (_db.select(_db.cartItemsDraft)
            ..where((t) => t.localCartId.equals(localCartId) & t.ownerUserId.equals(ownerUserId))
            ..orderBy([(t) => OrderingTerm.asc(t.lineNo)]))
          .get();

  /// Строки с неотправленными изменениями (`pending`) или «не отправлено» (`dead`).
  Future<List<CartItemDraftRow>> unsentItems(String localCartId) =>
      (_db.select(_db.cartItemsDraft)..where(
            (t) =>
                t.localCartId.equals(localCartId) &
                t.ownerUserId.equals(ownerUserId) &
                t.syncState.isIn(const <String>['pending', 'dead']),
          ))
          .get();

  /// Есть ли у владельца неотправленные изменения корзины — предупреждение при выходе/входе другого сотрудника
  /// (FLOW-009.E1, 07 §11.1 п.2).
  Future<bool> hasUnsentChanges() async {
    final CartDraftRow? dirty =
        await (_db.select(_db.cartDraft)
              ..where((t) => t.ownerUserId.equals(ownerUserId) & t.dirty.equals(true))
              ..limit(1))
            .getSingleOrNull();
    if (dirty != null) return true;
    final CartItemDraftRow? pending =
        await (_db.select(_db.cartItemsDraft)
              ..where((t) => t.ownerUserId.equals(ownerUserId) & t.syncState.isIn(const <String>['pending', 'dead']))
              ..limit(1))
            .getSingleOrNull();
    return pending != null;
  }

  /// Перезаписать черновик [localCartId] ответом сервера (сервер — истина, 07 §11.4): поля корзины,
  /// `base_row_version`, `server_synced_at`; строки заменяются строками ответа (`sync_state='synced'`), кроме
  /// неотправленных ([keepPending] — `pending`-строки, чьи записи `cart.sync` ещё в очереди, и `dead`-строки
  /// «не отправлено» после `409 VERSION_CONFLICT` или отказа сервера: остаются как есть до решения пользователя —
  /// «Повторить» / диалог UI-20-027, 07 §11.2 п. (4)–(5); ядро §22.6 «не молчаливая победа сервера»; корзина
  /// остаётся `dirty`). Возвращает обновлённую строку корзины.
  Future<CartDraftRow> applyServer(
    String localCartId,
    ServerCartSnapshot server, {
    required int nowMs,
    bool keepPending = true,
  }) => _db.transaction(() async {
    final List<CartItemDraftRow> current = await items(localCartId);
    final Map<String, CartItemDraftRow> pending = <String, CartItemDraftRow>{
      if (keepPending)
        for (final CartItemDraftRow r in current)
          if (_unsent(r.syncState)) _key(r.variantId, r.packagingId): r,
    };
    await (_db.delete(_db.cartItemsDraft)..where(
          (t) =>
              t.localCartId.equals(localCartId) &
              t.ownerUserId.equals(ownerUserId) &
              (keepPending ? t.syncState.isNotIn(_unsentStates) : const Constant(true)),
        ))
        .go();
    var lineNo = 0;
    for (final ServerCartLine line in server.lines) {
      lineNo++;
      final String key = _key(line.variantId, line.packagingId);
      final CartItemDraftRow? local = pending.remove(key);
      if (local != null) {
        // Локальное целевое количество ещё не отправлено — сохраняем его, обновляя серверные снимки.
        await (_db.update(_db.cartItemsDraft)..where((t) => t.localItemId.equals(local.localItemId))).write(
          CartItemsDraftCompanion(
            lineNo: Value(lineNo),
            unitId: Value(line.unitId),
            priceSnapshotTyiyn: Value(line.priceSnapshotTyiyn),
            stockSnapshotMilli: Value(line.stockSnapshotMilli),
            priceChanged: Value(line.priceChanged),
            stockInsufficient: Value(line.stockInsufficient),
          ),
        );
        continue;
      }
      await _db
          .into(_db.cartItemsDraft)
          .insert(
            CartItemsDraftCompanion.insert(
              localItemId: '$localCartId:$key',
              localCartId: localCartId,
              variantId: line.variantId,
              packagingId: Value(line.packagingId),
              unitId: Value(line.unitId),
              quantityMilli: line.quantityMilli,
              priceSnapshotTyiyn: Value(line.priceSnapshotTyiyn),
              stockSnapshotMilli: Value(line.stockSnapshotMilli),
              priceChanged: Value(line.priceChanged),
              stockInsufficient: Value(line.stockInsufficient),
              lineNo: lineNo,
              ownerUserId: ownerUserId,
              syncState: const Value('synced'),
            ),
            mode: InsertMode.insertOrReplace,
          );
    }
    // Оставшиеся неотправленные строки (добавлены локально, на сервере их ещё нет) — в конец списка.
    for (final CartItemDraftRow local in pending.values) {
      lineNo++;
      await (_db.update(
        _db.cartItemsDraft,
      )..where((t) => t.localItemId.equals(local.localItemId))).write(CartItemsDraftCompanion(lineNo: Value(lineNo)));
    }
    await (_db.update(
      _db.cartDraft,
    )..where((t) => t.localId.equals(localCartId) & t.ownerUserId.equals(ownerUserId))).write(
      CartDraftCompanion(
        serverId: Value(server.serverId),
        status: Value(server.status),
        name: Value(server.name),
        customerId: Value(server.customerId),
        warehouseId: Value(server.warehouseId),
        priceListId: Value(server.priceListId),
        discountPercentHundredths: Value(server.discountPercentHundredths),
        baseRowVersion: Value(server.rowVersion),
        dirty: Value(keepPending && current.any((CartItemDraftRow r) => _unsent(r.syncState))),
        serverSyncedAt: Value(nowMs),
        updatedAt: Value(nowMs),
      ),
    );
    return (_db.select(_db.cartDraft)..where((t) => t.localId.equals(localCartId))).getSingle();
  });

  /// Только новая база цепочки `rowVersion` (ответ на запись `cart.sync`, если строки применяет вызывающий).
  Future<void> setBaseRowVersion(String localCartId, int rowVersion, {required int nowMs}) =>
      (_db.update(_db.cartDraft)..where((t) => t.localId.equals(localCartId) & t.ownerUserId.equals(ownerUserId)))
          .write(CartDraftCompanion(baseRowVersion: Value(rowVersion), serverSyncedAt: Value(nowMs)));

  /// Состояние отправки строки (`synced|pending|dead`); `dead` — «не отправлено» с кнопкой «Повторить».
  Future<void> setItemSyncState(String localCartId, String variantId, String? packagingId, String state) =>
      (_db.update(_db.cartItemsDraft)..where(
            (t) =>
                t.localCartId.equals(localCartId) &
                t.ownerUserId.equals(ownerUserId) &
                t.variantId.equals(variantId) &
                (packagingId == null ? t.packagingId.isNull() : t.packagingId.equals(packagingId)),
          ))
          .write(CartItemsDraftCompanion(syncState: Value(state)));

  /// Снять признак `dirty`, когда очередь корзины пуста (все записи подтверждены).
  Future<void> markClean(String localCartId) =>
      (_db.update(_db.cartDraft)..where((t) => t.localId.equals(localCartId) & t.ownerUserId.equals(ownerUserId)))
          .write(const CartDraftCompanion(dirty: Value(false)));

  /// Корзина конвертирована в заказ / очищена: строка и её позиции удаляются (07 §11.2 «после converted строка
  /// удаляется»).
  Future<void> deleteCart(String localCartId) => _db.transaction(() async {
    await (_db.delete(
      _db.cartItemsDraft,
    )..where((t) => t.localCartId.equals(localCartId) & t.ownerUserId.equals(ownerUserId))).go();
    await (_db.delete(
      _db.cartDraft,
    )..where((t) => t.localId.equals(localCartId) & t.ownerUserId.equals(ownerUserId))).go();
  });

  static String _key(String variantId, String? packagingId) => '$variantId|${packagingId ?? ''}';

  /// Состояния неотправленной строки: `pending` (в очереди) и `dead` («не отправлено»).
  static const List<String> _unsentStates = <String>['pending', 'dead'];

  static bool _unsent(String syncState) => _unsentStates.contains(syncState);
}
