// Корзина планшета магазина — только на сервере (ADR-115; 02 SCR-51 UI-51-010…UI-51-013; 04 FLOW-044.S2, FLOW-045;
// 07 §11.2, DATA-304; 10 KIOSK-009, KIOSK-020, KIOSK-025; 11 PRIV-033 (2); 13 TAB-2-12) — реализация порта `CartSync`
// и сброса корзины `KioskCartControl`.
//
// - Снимок — последний ответ сервера (`Cart`) в памяти процесса. В drift корзина не пишется: нет строк `cart_draft` /
//   `cart_items_draft`, записей `outbox_actions`, ключей `app_meta` конфликта версий и смены варианта. Из файла БД
//   планшета читается только кэш каталога (единица строки, шаг, минимальная партия, точность количества); пишется одна
//   метка сброса без сети `app_meta.kiosk.pending_reset_cart_id` — только id корзины (04 FLOW-045.A1).
// - Каждое изменение — отдельный прямой запрос (02 UI-51-010, UI-51-012): «В корзину» — `PUT /cart/items/{variantId}`
//   `mode=increment` с новым `Idempotency-Key`; степпер и нампад — `mode=set`; удаление строки упаковки —
//   `DELETE ?packagingId=`, строки базовой единицы — `PUT mode=set 0` (DELETE без `packagingId` удалил бы все строки
//   варианта, 08 §4.7.3 «Уточнения» п. 1). Запросы идут по одному с `rowVersion` последнего ответа; `409
//   VERSION_CONFLICT` той же корзины — один повтор с версией из ответа сервера.
// - Без связи изменение сразу отклоняется (`NetworkFailure`) и никуда не ставится (10 KIOSK-025; 12 T-KIOSK-061);
//   ошибка во время запроса — количество возвращается к серверному, для степпера — событие `CartSyncRejected`.
// - Пока ответа нет, строка показывается с целевым количеством «предварительно» (снимок в памяти со строкой
//   `pending`, как у черновика сотрудника, но без drift).
// - Сброс FLOW-045 ([reset]): метка сброса → пустая корзина на экране → `POST /kiosk/reset {cartId}` → новая корзина.
//   Пока метка есть, изменения и `GET /cart` не выполняются, корзина на экране пуста (02 SCR-51.7 «Сброс без сети»).
//   Метка и успешный сброс начинают новое поколение ([generation]): корень даёт новый объект порта ([port]), и
//   состояние экрана корзины строится заново — корзина прошлого покупателя не показывается никогда (P-002 §15).
// - Отметка «Товара стало меньше…» (02 UI-51-018; SCR-52 п. 6; FLOW-044.A3) — [markStockChanged] после возврата из
//   SCR-52 по отказу остатка или количества: id и версия корзины на экране, только память. Видна ([stockChanged]),
//   пока на экране та же корзина той же версии; изменение корзины (новая версия от сервера) и сброс её снимают. Строки
//   `conflicts[]` отказа, которых нет в `warnings[]` ответа `GET /cart` (например, вариант без цены в виде цены
//   карточки), добавляются к предупреждениям корзины на экране на то же время — отказанная строка отмечена всегда.
// - Подготовка ([prepare]) — один раз на файл БД, до первого запроса и первого сброса: очистка строк покупателя
//   (`SessionLocalData.clearKioskVolatile`, FLOW-045.A2) и чтение метки сброса без сети, оставшейся с прошлого
//   запуска.
// - Очереди, конфликта версий в очереди, «Отложить», клиента, склада и скидки у планшета нет (закрытый список
//   08 §4.25): [conflict] — всегда `null`, [warehouses] — пусто, [watchStatus] — без записей.
// Деньги — тыйыны, количества — milli-units (D-19); цены клиент не считает (D-23). Номеров, токенов и тел запросов
// здесь нет; ничего не логируется.
import 'dart:async';

import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/app_meta_dao.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/session/session_local_data.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:uuid/uuid.dart';

/// Единица строки неизвестна: варианта нет ни в корзине, ни в кэше каталога планшета — `Quantity.unitId` для
/// `PUT /cart/items/{variantId}` взять неоткуда.
final class KioskCartUnitUnknown implements Exception {
  const KioskCartUnitUnknown();

  @override
  String toString() => 'KioskCartUnitUnknown';
}

/// Правила и подписи строки из кэша каталога планшета.
final class _CatalogInfo {
  const _CatalogInfo({
    this.unitId,
    this.unitLabel,
    this.packagingName,
    this.factor,
    this.step,
    this.minQuantity,
    this.qtyPrecision,
    this.productId,
    this.productName,
    this.variantName,
    this.sku,
  });

  final String? unitId;
  final String? unitLabel;
  final String? packagingName;
  final Qty? factor;
  final Qty? step;
  final Qty? minQuantity;
  final int? qtyPrecision;
  final String? productId;
  final String? productName;
  final String? variantName;
  final String? sku;
}

/// Изменение строки, ещё не подтверждённое сервером (только память).
final class _Pending {
  const _Pending(this.token, this.target);

  final int token;

  /// Целевое количество строки (0 — удаление).
  final Qty target;
}

/// Вид изменения строки.
enum _Change { set, increment }

/// Изменение строки: вид, количество (`set`) или приращение (`increment`, `null` — шаг строки), цена карточки для
/// новой строки и единица строки от вызывающего.
typedef _Intent = ({_Change kind, Qty? value, Money? priceSnapshot, String? unitHint});

/// `CartSync` и `KioskCartControl` корзины планшета: снимок в памяти, прямые запросы `CartRepository`.
final class KioskCartSync implements CartSync, KioskCartControl {
  KioskCartSync({
    required AppDatabase? Function() database,
    required String? Function() owner,
    required CartRepository repository,
    required bool Function() offline,
    String Function()? newKey,
  }) : _database = database,
       _owner = owner,
       _repo = repository,
       _offline = offline,
       _newKey = newKey ?? const Uuid().v4;

  final AppDatabase? Function() _database;
  final String? Function() _owner;
  final CartRepository _repo;
  final bool Function() _offline;
  final String Function() _newKey;

  /// Ключ `app_meta` метки сброса без сети (07 §11.2, строка `app_meta`; 04 FLOW-045.A1): значение — только id
  /// корзины.
  static const String pendingResetMetaKey = AppMetaDao.kioskPendingResetCartIdKey;

  /// `localCartId` снимка, пока серверной корзины нет.
  static const String placeholderCartId = 'kiosk';

  final StreamController<CartSyncEvent> _events = StreamController<CartSyncEvent>.broadcast();
  final StreamController<CartLocalSnapshot> _local = StreamController<CartLocalSnapshot>.broadcast();
  final StreamController<int> _generations = StreamController<int>.broadcast();
  final StreamController<bool> _stockNotices = StreamController<bool>.broadcast();

  /// Отметка UI-51-018: корзина (id и версия), к которой покупатель вернулся из SCR-52 после отказа заявки по остатку
  /// или количеству; `null` — отметки нет.
  ({String id, int rowVersion})? _stockNotice;

  /// Строки отказа заявки, отмеченные вместе с [_stockNotice] (только память; снимаются вместе с ней).
  List<CartConflict> _stockMarks = const <CartConflict>[];

  /// Хвост очереди запросов ([_locked]); `null` — очередь пуста с самого начала.
  Future<void>? _tail;
  Future<void>? _prepared;

  /// Последний ответ сервера; `null` — корзина ещё не получена или идёт сброс.
  Cart? _cart;

  /// Метка сброса без сети: id корзины, закрытие которой сервер не подтвердил.
  String? _held;
  final Map<CartLineKey, _Pending> _pending = <CartLineKey, _Pending>{};
  final Map<CartLineKey, _CatalogInfo> _info = <CartLineKey, _CatalogInfo>{};
  int _seq = 0;
  int _generation = 0;

  /// Поколение корзины на экране: растёт при метке сброса и после успешного сброса.
  int get generation => _generation;

  /// Новые поколения ([generation]).
  Stream<int> get generations => _generations.stream;

  /// Новый объект порта текущего поколения: корень отдаёт его в `cartSyncProvider`, и смена объекта строит
  /// состояние экрана корзины заново (`cartControllerProvider` следит за портом). Все объекты работают с одним
  /// снимком и одной очередью запросов.
  CartSync port() => _KioskCartPort(this);

  /// Освободить потоки.
  Future<void> dispose() async {
    await _events.close();
    await _local.close();
    await _generations.close();
    await _stockNotices.close();
  }

  // ---------------------------------------------------------------------------
  // Отметка строк после отказа заявки (02 UI-51-018)
  // ---------------------------------------------------------------------------

  /// Над строками drawer — «Товара стало меньше…» (`kiosk_stock_changed`): на экране корзина, отмеченная
  /// [markStockChanged], и после отметки она не менялась.
  bool get stockChanged {
    final ({String id, int rowVersion})? notice = _stockNotice;
    final Cart? cart = _held == null ? _cart : null;
    return notice != null && cart != null && cart.id == notice.id && cart.rowVersion == notice.rowVersion;
  }

  /// Изменения [stockChanged].
  Stream<bool> get stockNotices => _stockNotices.stream;

  /// Покупатель вернулся из SCR-52 по отказу остатка или количества (02 SCR-52 п. 6): корзина уже перечитана
  /// (`GET /cart`, строки отмечены по `warnings[]`). [conflicts] — строки `conflicts[]` отказа: те, что есть в корзине и
  /// не помечены сервером, отмечаются так же (`variant_unavailable`, `stock_insufficient`, …). Отметка снимается
  /// изменением корзины или сбросом; без корзины на экране (идёт сброс, метка) — без действия.
  void markStockChanged([List<KioskCartStockConflict> conflicts = const <KioskCartStockConflict>[]]) {
    final bool before = stockChanged;
    final Cart? cart = _held == null ? _cart : null;
    _stockNotice = cart == null ? null : (id: cart.id, rowVersion: cart.rowVersion);
    _stockMarks = cart == null ? const <CartConflict>[] : _marksFor(cart, conflicts);
    _settleStockNotice(before);
    if (cart != null && _stockMarks.isNotEmpty) _emit(CartServerUpdated(_marked(cart)));
  }

  /// Строки отказа [conflicts], которые есть в корзине [cart] и ещё не помечены сервером тем же видом.
  static List<CartConflict> _marksFor(Cart cart, List<KioskCartStockConflict> conflicts) {
    final Set<String> lines = <String>{for (final CartLine l in cart.items) l.variantId};
    final Set<String> known = <String>{for (final CartConflict w in cart.warnings) '${w.variantId}|${w.rawKind}'};
    final List<CartConflict> out = <CartConflict>[];
    for (final KioskCartStockConflict c in conflicts) {
      if (!lines.contains(c.variantId) || !known.add('${c.variantId}|${c.kind}')) continue;
      out.add(CartConflict(variantId: c.variantId, rawKind: c.kind, stockLevel: CartStockLevel.tryParse(c.stockLevel)));
    }
    return List<CartConflict>.unmodifiable(out);
  }

  /// Корзина [cart] для экрана: пока видна отметка UI-51-018 — с отмеченными строками отказа.
  Cart _marked(Cart cart) {
    if (_stockMarks.isEmpty || !stockChanged) return cart;
    return Cart(
      id: cart.id,
      status: cart.status,
      items: cart.items,
      rowVersion: cart.rowVersion,
      name: cart.name,
      ownerId: cart.ownerId,
      customer: cart.customer,
      receiver: cart.receiver,
      warehouseId: cart.warehouseId,
      priceListId: cart.priceListId,
      itemsCount: cart.itemsCount,
      unitsCount: cart.unitsCount,
      subtotal: cart.subtotal,
      requestedDiscountPercent: cart.requestedDiscountPercent,
      appliedDiscountPercent: cart.appliedDiscountPercent,
      discountTotal: cart.discountTotal,
      customerDiscountPercent: cart.customerDiscountPercent,
      total: cart.total,
      discountLimitPercent: cart.discountLimitPercent,
      warnings: <CartConflict>[...cart.warnings, ..._stockMarks],
      restoredFromOrderId: cart.restoredFromOrderId,
      restoredFromOrder: cart.restoredFromOrder,
      parkedAt: cart.parkedAt,
      expiresAt: cart.expiresAt,
      createdById: cart.createdById,
    );
  }

  /// После смены корзины на экране или отметки ([before] — [stockChanged] до неё): отметка другой корзины или другой
  /// версии снимается насовсем (вместе со строками отказа); изменение видимости — событие [stockNotices].
  void _settleStockNotice(bool before) {
    if (_stockNotice != null && !stockChanged) _stockNotice = null;
    if (_stockNotice == null) _stockMarks = const <CartConflict>[];
    final bool after = stockChanged;
    if (before != after && !_stockNotices.isClosed) _stockNotices.add(after);
  }

  // ---------------------------------------------------------------------------
  // KioskCartControl
  // ---------------------------------------------------------------------------

  @override
  String? get cartId => _held == null ? _cart?.id : null;

  @override
  String? get pendingResetCartId => _held;

  @override
  Future<void> prepare() {
    final Future<void>? started = _prepared;
    if (started != null) return started;
    final AppDatabase? db = _database();
    final String? owner = _owner();
    // БД планшета ещё не открыта — подготовка при следующем обращении.
    if (db == null || owner == null) return Future<void>.value();
    return _prepared = _prepare(db, owner);
  }

  Future<void> _prepare(AppDatabase db, String owner) async {
    try {
      await SessionLocalData(db).clearKioskVolatile(owner);
    } on Object {
      // Файл закрыт при смене пользователя: защита на случай ошибки повторится при следующем запуске.
    }
    try {
      final String? marked = await AppMetaDao(db).read(pendingResetMetaKey);
      if (marked != null && marked.isNotEmpty && _held == null) _hold(marked);
    } on Object {
      // Метку прочитать не удалось — сброс без сети прошлого запуска повторит следующий сброс.
    }
  }

  @override
  Future<Result<Cart>> reset(Future<Result<Cart>> Function(String? cartId) request) => _locked(() async {
    await prepare();
    final String? cartId = _held ?? _cart?.id;
    if (cartId != null && _held != cartId) {
      _hold(cartId);
      await _writeMarker(cartId);
    }
    if (_offline()) return const FailureResult<Cart>(NetworkFailure(NetworkFailureKind.offline));
    final Result<Cart> r = await _guardCall(() => request(cartId));
    if (r case Success<Cart>(:final Cart value)) {
      _held = null;
      _pending.clear();
      await _removeMarker();
      await _adopt(value);
      _nextGeneration();
    }
    return r;
  });

  /// Метка сброса: корзина на экране пуста, изменения отклоняются до ответа `POST /kiosk/reset`.
  void _hold(String cartId) {
    final bool noticed = stockChanged;
    _held = cartId;
    _cart = null;
    _pending.clear();
    _info.clear();
    _settleStockNotice(noticed);
    _emitLocal();
    _nextGeneration();
  }

  void _nextGeneration() {
    _generation++;
    if (!_generations.isClosed) _generations.add(_generation);
  }

  Future<void> _writeMarker(String cartId) async {
    final AppDatabase? db = _database();
    if (db == null) return;
    try {
      await AppMetaDao(db).write(pendingResetMetaKey, cartId);
    } on Object {
      // Метка в памяти остаётся: до перезапуска корзина на экране пуста и изменения отклоняются.
    }
  }

  Future<void> _removeMarker() async {
    final AppDatabase? db = _database();
    if (db == null) return;
    try {
      await AppMetaDao(db).remove(pendingResetMetaKey);
    } on Object {
      // Повторный сброс по метке после перезапуска идемпотентен (`200` для закрытой корзины, 08 §4.25.4).
    }
  }

  // ---------------------------------------------------------------------------
  // CartSync
  // ---------------------------------------------------------------------------

  @override
  Stream<CartSyncEvent> get events => _events.stream;

  @override
  CartVersionConflict? get conflict => null;

  @override
  Stream<CartLocalSnapshot?> watchLocal() {
    late final StreamController<CartLocalSnapshot?> out;
    StreamSubscription<CartLocalSnapshot>? sub;
    out = StreamController<CartLocalSnapshot?>(
      onListen: () {
        sub = _local.stream.listen(out.add, onError: out.addError, onDone: out.close);
        out.add(_snapshot());
      },
      onCancel: () => sub?.cancel(),
    );
    return out.stream;
  }

  @override
  Future<Result<CartLocalSnapshot?>> loadLocal() async {
    await prepare();
    return Success<CartLocalSnapshot?>(_snapshot());
  }

  @override
  Stream<CartSyncStatus> watchStatus() => Stream<CartSyncStatus>.value(CartSyncStatus.idle);

  @override
  Future<Result<Cart>> refresh() => _locked(() async {
    await prepare();
    final Failure? refused = _refusal();
    if (refused != null) return FailureResult<Cart>(refused);
    final Result<Cart> r = await _guardCall(_repo.fetch);
    if (r case Success<Cart>(:final Cart value)) {
      // Метка появилась во время запроса — ответ со сброшенной корзиной не показывается.
      if (_held != null) return const FailureResult<Cart>(UnknownFailure(cause: KioskCartResetPending()));
      await _adopt(value);
    }
    return r;
  });

  @override
  Future<Result<void>> setQuantity(CartLineKey key, Qty quantity) async {
    if (quantity.milli < 0) throw ArgumentError.value(quantity.milli, 'quantity', '>= 0');
    final Result<Cart> r = await _change(key, _Change.set, value: quantity, reportRejection: true);
    return r.map((Cart _) {});
  }

  @override
  Future<Result<Qty>> addStep(CartLineKey key, {Money? priceSnapshot}) =>
      addStepWithUnit(key, priceSnapshot: priceSnapshot);

  @override
  Future<Result<Qty>> addStepWithUnit(CartLineKey key, {String? unitId, Money? priceSnapshot}) async {
    final Result<Cart> r = await _change(key, _Change.increment, unitHint: unitId, priceSnapshot: priceSnapshot);
    return switch (r) {
      Success<Cart>(:final Cart value) => Success<Qty>(_lineOf(value, key)?.quantity.value ?? Qty.zero),
      FailureResult<Cart>(:final Failure failure) => FailureResult<Qty>(failure),
    };
  }

  /// Прибавить [quantity] (единицы строки) — «В корзину» карточки товара и листа вариантов (`CartDraftRepository.add`).
  /// [unitId] — единица строки от карточки, если варианта нет ни в корзине, ни в кэше каталога.
  Future<Result<Cart>> addQuantity(CartLineKey key, Qty quantity, {Money? priceSnapshot, String? unitId}) {
    if (quantity.milli <= 0) throw ArgumentError.value(quantity.milli, 'quantity', '> 0');
    return _change(key, _Change.increment, value: quantity, priceSnapshot: priceSnapshot, unitHint: unitId);
  }

  /// Установить количество строки (0 — удалить) без события об отказе (`CartDraftRepository.setQuantity`).
  Future<Result<Cart>> setLine(CartLineKey key, Qty quantity) {
    if (quantity.milli < 0) throw ArgumentError.value(quantity.milli, 'quantity', '>= 0');
    return _change(key, _Change.set, value: quantity);
  }

  /// Нечего отправлять: очереди у планшета нет, каждое изменение уже ушло прямым запросом.
  @override
  Future<Result<void>> sync() async => const Success<void>(null);

  @override
  Future<Result<T>> direct<T>(
    Future<Result<T>> Function(int rowVersion) op, {
    required Cart? Function(T value) cartOf,
    bool keepPending = true,
    Set<CartLineKey> settle = const <CartLineKey>{},
  }) => _locked(() async {
    await prepare();
    final Failure? refused = _refusal();
    if (refused != null) return FailureResult<T>(refused);
    final Result<Cart> base = await _base();
    if (base case FailureResult<Cart>(:final Failure failure)) return FailureResult<T>(failure);
    final Result<T> r = await _guardCall(() => op(base.valueOrNull!.rowVersion));
    switch (r) {
      case Success<T>(:final T value):
        final Cart? cart = cartOf(value);
        if (cart != null && _held == null) {
          if (!keepPending) _pending.clear();
          for (final CartLineKey k in settle) {
            _pending.remove(k);
          }
          await _adopt(cart);
        }
      case FailureResult<T>(:final Failure failure):
        final Cart? current = _repo.conflictCurrent(failure);
        if (current != null && _held == null) await _adopt(current);
    }
    return r;
  });

  /// Журнала смены варианта у планшета нет (в `app_meta` ничего не пишется).
  @override
  Future<Result<void>> beginReplace(CartLineReplace replace) async => const Success<void>(null);

  @override
  Future<void> endReplace() async {}

  /// Конфликтов очереди у планшета нет.
  @override
  Future<Result<void>> resolveConflict({required bool applyMine}) async => const Success<void>(null);

  /// Отклонённых записей очереди у планшета нет.
  @override
  Future<Result<void>> retryFailed() async => const Success<void>(null);

  /// Склад корзины планшета — склад планшета (SCR-54); смены склада нет (`PATCH /cart` — `403`).
  @override
  Future<Result<List<CartWarehouseOption>>> warehouses() async =>
      const Success<List<CartWarehouseOption>>(<CartWarehouseOption>[]);

  @override
  Future<CartPlaceLabels> placeLabels({String? warehouseId, String? priceListId}) async =>
      (warehouse: null, priceList: null);

  // ---------------------------------------------------------------------------
  // Изменение строки
  // ---------------------------------------------------------------------------

  /// Изменение строки [key] прямым запросом: [_Change.set] — количество [value] (0 — удалить); [_Change.increment] —
  /// прибавить [value], без него — шаг строки (первое добавление — не меньше минимальной партии, INV-004/005).
  /// [reportRejection] — отказ публикуется событием `CartSyncRejected` (степпер drawer: контроллер сам отказ не
  /// показывает).
  Future<Result<Cart>> _change(
    CartLineKey key,
    _Change kind, {
    Qty? value,
    Money? priceSnapshot,
    String? unitHint,
    bool reportRejection = false,
  }) async {
    final Failure? early = _refusal();
    if (early != null) return _reject(early, key, report: reportRejection);
    // Поколение — в момент нажатия: сброс, начатый раньше, чем изменение ушло, его отменяет (в корзину следующего
    // покупателя не попадает ничего из прежней).
    final int generation = _generation;
    await prepare();
    final _CatalogInfo? info = await _catalogFor(key);
    if (generation != _generation) {
      return _reject(const UnknownFailure(cause: KioskCartResetPending()), key, report: reportRejection);
    }
    // Строка на экране сразу получает целевое количество («предварительно»), пока сервер не ответил.
    final Qty current = _pending[key]?.target ?? _lineOf(_cart, key)?.quantity.value ?? Qty.zero;
    final Qty target = switch (kind) {
      _Change.set => value!,
      _Change.increment => current + (value ?? _stepFor(info, isNew: current.isZero)),
    };
    final int token = ++_seq;
    _pending[key] = _Pending(token, target);
    _emitLocal();
    final Result<Cart> r = await _locked(
      () => _send(key, (
        kind: kind,
        value: value,
        priceSnapshot: priceSnapshot,
        unitHint: unitHint,
      ), generation: generation),
    );
    if (_pending[key]?.token == token) _pending.remove(key);
    _emitLocal();
    if (r case FailureResult<Cart>(:final Failure failure)) return _reject(failure, key, report: reportRejection);
    return r;
  }

  FailureResult<Cart> _reject(Failure failure, CartLineKey key, {required bool report}) {
    if (report) _emit(CartSyncRejected(failure, key: key));
    return FailureResult<Cart>(failure);
  }

  /// Изменения невозможны: метка сброса без сети или нет связи.
  Failure? _refusal() {
    if (_held != null) return const UnknownFailure(cause: KioskCartResetPending());
    if (_offline()) return const NetworkFailure(NetworkFailureKind.offline);
    return null;
  }

  /// Изменение поколения [generation]: если до его очереди дошёл сброс (новое поколение), оно не выполняется — в
  /// корзину следующего покупателя не попадает ничего из прежней.
  Future<Result<Cart>> _send(CartLineKey key, _Intent intent, {required int generation}) async {
    if (generation != _generation) return const FailureResult<Cart>(UnknownFailure(cause: KioskCartResetPending()));
    final Failure? refused = _refusal();
    if (refused != null) return FailureResult<Cart>(refused);
    final Result<Cart> base = await _base();
    if (base case FailureResult<Cart>(:final Failure failure)) return FailureResult<Cart>(failure);
    final Cart first = base.valueOrNull!;
    Result<Cart> r = await _request(first, key, intent);
    if (r case FailureResult<Cart>(
      :final Failure failure,
    ) when failure is ConflictFailure && failure.kind == ConflictKind.versionConflict) {
      // Версия корзины на сервере новее снимка: снимок = серверная корзина; та же корзина — один повтор с её версией
      // (новый ключ: тело другое). Корзина сменилась (сброс на сервере) — изменение не переносится в новую.
      final Cart? current = _repo.conflictCurrent(failure) ?? (await _guardCall(_repo.fetch)).valueOrNull;
      if (current != null && _held == null) {
        await _adopt(current);
        if (current.id == first.id) r = await _request(current, key, intent);
      }
    }
    if (r case Success<Cart>(:final Cart value) when _held == null) await _adopt(value);
    return r;
  }

  /// Запрос изменения строки [key] по серверной корзине [base]. Единица строки — из корзины, кэша каталога или от
  /// вызывающего ([_Intent.unitHint]).
  Future<Result<Cart>> _request(Cart base, CartLineKey key, _Intent intent) async {
    final (:_Change kind, :Qty? value, :Money? priceSnapshot, :String? unitHint) = intent;
    final CartLine? line = _lineOf(base, key);
    final _CatalogInfo? info = await _catalogFor(key);
    final String? packagingId = key.packagingId;
    final String? unitId = line?.quantity.unitId ?? info?.unitId ?? unitHint;
    switch (kind) {
      case _Change.set:
        final Qty quantity = value!;
        if (quantity.isZero) {
          // Строки на сервере нет — удалять нечего.
          if (line == null) return Success<Cart>(base);
          if (packagingId != null) {
            return _guardCall(
              () => _repo.deleteItem(key.variantId, packagingId: packagingId, idempotencyKey: _newKey()),
            );
          }
        }
        if (unitId == null) return const FailureResult<Cart>(UnknownFailure(cause: KioskCartUnitUnknown()));
        return _guardCall(
          () => _repo.putItem(
            key.variantId,
            CartItemPut(
              quantity: LineQuantity(value: quantity, unitId: unitId, packagingId: packagingId),
              rowVersion: base.rowVersion,
              // Цена, которую видел покупатель, — только для новой строки (предупреждение `price_changed`, D-23).
              priceSnapshot: line == null ? priceSnapshot : null,
            ),
            idempotencyKey: _newKey(),
          ),
        );
      case _Change.increment:
        if (unitId == null) return const FailureResult<Cart>(UnknownFailure(cause: KioskCartUnitUnknown()));
        final Qty delta = value ?? _stepFor(info, isNew: line == null);
        return _guardCall(
          () => _repo.putItem(
            key.variantId,
            CartItemPut(
              quantity: LineQuantity(value: delta, unitId: unitId, packagingId: packagingId),
              rowVersion: base.rowVersion,
              mode: CartPutMode.increment,
              priceSnapshot: line == null ? priceSnapshot : null,
            ),
            // `mode=increment` без ключа — `400 idempotency_key_required` (08 §4.7.2); повтор сетевого слоя — тот же
            // ключ, количество увеличится один раз.
            idempotencyKey: _newKey(),
          ),
        );
    }
  }

  /// Шаг «В корзину»: кратность варианта (упаковка — 1); первое добавление — не меньше минимальной партии.
  static Qty _stepFor(_CatalogInfo? info, {required bool isNew}) {
    final Qty step = info?.step ?? Qty.units(1);
    final Qty? min = info?.minQuantity;
    if (isNew && min != null && min > step) return min;
    return step;
  }

  /// Серверная корзина для изменения: снимок или `GET /cart` (первое изменение до ответа сервера).
  Future<Result<Cart>> _base() async {
    final Cart? cart = _cart;
    if (cart != null) return Success<Cart>(cart);
    final Result<Cart> r = await _guardCall(_repo.fetch);
    if (r case Success<Cart>(:final Cart value) when _held == null) await _adopt(value);
    return r;
  }

  /// Снимок = ответ сервера [cart]: подписи и правила строк из кэша каталога, события экрану. Новая версия или другая
  /// корзина снимает отметку UI-51-018.
  Future<void> _adopt(Cart cart) async {
    final bool noticed = stockChanged;
    _cart = cart;
    _settleStockNotice(noticed);
    final List<CartLineKey> missing = <CartLineKey>[
      for (final CartLine l in cart.items)
        if (!_info.containsKey(CartLineKey(l.variantId, l.packagingId))) CartLineKey(l.variantId, l.packagingId),
    ];
    if (missing.isNotEmpty) _info.addAll(await _lookup(missing));
    _emitLocal();
    _emit(CartServerUpdated(_marked(cart)));
  }

  static CartLine? _lineOf(Cart? cart, CartLineKey key) {
    for (final CartLine l in cart?.items ?? const <CartLine>[]) {
      if (l.variantId == key.variantId && l.packagingId == key.packagingId) return l;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Снимок в памяти
  // ---------------------------------------------------------------------------

  CartLocalSnapshot _snapshot() {
    final Cart? cart = _held == null ? _cart : null;
    final List<CartLocalLine> lines = <CartLocalLine>[];
    final Set<CartLineKey> seen = <CartLineKey>{};
    for (final CartLine l in cart?.items ?? const <CartLine>[]) {
      final CartLineKey key = CartLineKey(l.variantId, l.packagingId);
      seen.add(key);
      lines.add(_localLine(key, lines.length + 1, server: l, pending: _pending[key]));
    }
    if (_held == null) {
      for (final MapEntry<CartLineKey, _Pending> e in _pending.entries) {
        if (seen.contains(e.key) || e.value.target.isZero) continue;
        lines.add(_localLine(e.key, lines.length + 1, pending: e.value));
      }
    }
    return CartLocalSnapshot(
      localCartId: cart?.id ?? placeholderCartId,
      serverId: cart?.id,
      baseRowVersion: cart?.rowVersion,
      dirty: _pending.isNotEmpty,
      lines: lines,
    );
  }

  CartLocalLine _localLine(CartLineKey key, int lineNo, {CartLine? server, _Pending? pending}) {
    final _CatalogInfo? i = _info[key];
    return CartLocalLine(
      key: key,
      quantity: pending?.target ?? server?.quantity.value ?? Qty.zero,
      syncState: pending == null ? CartDraftSyncState.synced : CartDraftSyncState.pending,
      lineNo: lineNo,
      unitId: server?.quantity.unitId ?? i?.unitId,
      priceSnapshot: server?.unitPrice,
      stockSnapshot: server?.available,
      priceChanged: server?.warnings.contains(CartItemWarning.priceChanged) ?? false,
      stockInsufficient: server?.warnings.contains(CartItemWarning.stockInsufficient) ?? false,
      productId: server?.productId ?? i?.productId,
      productName: server?.productName ?? i?.productName,
      variantName: server?.variantName ?? i?.variantName,
      sku: server?.sku ?? i?.sku,
      unitLabel: server?.packaging?.name ?? i?.unitLabel,
      packagingName: server?.packaging?.name ?? i?.packagingName,
      factor: server?.packaging?.factor ?? i?.factor,
      step: i?.step,
      minQuantity: i?.minQuantity,
      qtyPrecision: i?.qtyPrecision,
    );
  }

  /// Строки корзины для порта черновика (`CartDraftRepository`): без меток удаления.
  List<CartDraftLine> draftLines() => draftLinesOf(_snapshot());

  /// Строки черновика из снимка [s].
  static List<CartDraftLine> draftLinesOf(CartLocalSnapshot s) => <CartDraftLine>[
    for (final CartLocalLine l in s.visibleLines)
      CartDraftLine(
        localItemId: '${s.localCartId}:${l.key.variantId}|${l.key.packagingId ?? ''}',
        cartId: s.localCartId,
        variantId: l.key.variantId,
        packagingId: l.key.packagingId,
        quantity: l.quantity,
        lineNo: l.lineNo,
        priceSnapshot: l.priceSnapshot,
        stockSnapshot: l.stockSnapshot,
        syncState: l.syncState,
      ),
  ];

  // ---------------------------------------------------------------------------
  // Кэш каталога (только чтение)
  // ---------------------------------------------------------------------------

  Future<_CatalogInfo?> _catalogFor(CartLineKey key) async {
    final _CatalogInfo? known = _info[key];
    if (known != null) return known;
    final _CatalogInfo? found = (await _lookup(<CartLineKey>[key]))[key];
    if (found != null) _info[key] = found;
    return found;
  }

  /// Подписи и правила строк из кэша каталога (пустая карта, если кэш не загружен или БД закрыта).
  Future<Map<CartLineKey, _CatalogInfo>> _lookup(List<CartLineKey> keys) async {
    final AppDatabase? db = _database();
    if (db == null || keys.isEmpty) return const <CartLineKey, _CatalogInfo>{};
    try {
      final Set<String> variantIds = <String>{for (final CartLineKey k in keys) k.variantId};
      final Set<String> packagingIds = <String>{
        for (final CartLineKey k in keys)
          if (k.packagingId != null) k.packagingId!,
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
      for (final CartLineKey k in keys) {
        final ProductVariantRow? v = variants[k.variantId];
        if (v == null) continue;
        final ProductRow? p = products[v.productId];
        final PackagingRow? pk = k.packagingId == null ? null : packagings[k.packagingId];
        final UnitRow? baseUnit =
            unitById[v.unitId ?? p?.baseUnitId ?? ''] ?? (p == null ? null : unitByCode[p.baseUnitCode]);
        final String? unitId = pk != null
            ? (pk.unitId ?? unitByCode[pk.unitCode]?.id)
            : (v.unitId ?? p?.baseUnitId ?? baseUnit?.id);
        final int? multiplicity = v.multiplicityMilli ?? p?.multiplicityMilli;
        out[k] = _CatalogInfo(
          productId: p?.id ?? v.productId,
          productName: p?.name,
          variantName: (p?.hasVariants ?? false) ? v.name : null,
          sku: v.sku ?? p?.sku,
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

  // ---------------------------------------------------------------------------
  // Внутреннее
  // ---------------------------------------------------------------------------

  void _emit(CartSyncEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  void _emitLocal() {
    if (!_local.isClosed) _local.add(_snapshot());
  }

  /// Последовательное выполнение: запросы корзины и сброс не пересекаются (цепочка `rowVersion`; изменение,
  /// начатое до сброса, не попадёт в корзину следующего покупателя).
  Future<T> _locked<T>(Future<T> Function() body) async {
    final Future<void>? previous = _tail;
    final Completer<void> done = Completer<void>();
    _tail = done.future;
    try {
      if (previous != null) await previous;
      return await body();
    } finally {
      done.complete();
    }
  }

  static Future<Result<T>> _guardCall<T>(Future<Result<T>> Function() call) async {
    try {
      return await call();
    } on Object catch (e) {
      return FailureResult<T>(UnknownFailure(cause: e));
    }
  }
}

/// Объект порта одного поколения корзины планшета ([KioskCartSync.port]); всё выполняет [KioskCartSync].
final class _KioskCartPort implements CartSync {
  _KioskCartPort(this._core);

  final KioskCartSync _core;

  @override
  Stream<CartLocalSnapshot?> watchLocal() => _core.watchLocal();

  @override
  Future<Result<CartLocalSnapshot?>> loadLocal() => _core.loadLocal();

  @override
  Stream<CartSyncEvent> get events => _core.events;

  @override
  Stream<CartSyncStatus> watchStatus() => _core.watchStatus();

  @override
  CartVersionConflict? get conflict => _core.conflict;

  @override
  Future<Result<Cart>> refresh() => _core.refresh();

  @override
  Future<Result<void>> setQuantity(CartLineKey key, Qty quantity) => _core.setQuantity(key, quantity);

  @override
  Future<Result<Qty>> addStep(CartLineKey key, {Money? priceSnapshot}) =>
      _core.addStep(key, priceSnapshot: priceSnapshot);

  @override
  Future<Result<void>> sync() => _core.sync();

  @override
  Future<Result<T>> direct<T>(
    Future<Result<T>> Function(int rowVersion) op, {
    required Cart? Function(T value) cartOf,
    bool keepPending = true,
    Set<CartLineKey> settle = const <CartLineKey>{},
  }) => _core.direct<T>(op, cartOf: cartOf, keepPending: keepPending, settle: settle);

  @override
  Future<Result<void>> beginReplace(CartLineReplace replace) => _core.beginReplace(replace);

  @override
  Future<void> endReplace() => _core.endReplace();

  @override
  Future<Result<void>> resolveConflict({required bool applyMine}) => _core.resolveConflict(applyMine: applyMine);

  @override
  Future<Result<void>> retryFailed() => _core.retryFailed();

  @override
  Future<Result<List<CartWarehouseOption>>> warehouses() => _core.warehouses();

  @override
  Future<CartPlaceLabels> placeLabels({String? warehouseId, String? priceListId}) =>
      _core.placeLabels(warehouseId: warehouseId, priceListId: priceListId);
}
