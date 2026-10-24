// `cartProvider` SCR-20 (02 SCR-20.9: провайдер уровня приложения, CART-010): серверная корзина (`GET /cart` и ответы
// записей `cart.sync`) + локальная копия drift + оптимистичные изменения. Итоги — только из ответа сервера (D-23,
// MNY-001): локально сумма не вычисляется; пока изменение не подтверждено, строки и «Итого» помечаются
// «предварительно» (UI-20-030).
//
// Изменение количества: число меняется сразу (optimistic) и пишется в черновик; отправка — одна запись `cart.sync`
// после паузы 500 мс (debounce INV-043, ядро §19.4; любое изменение черновика — степпер, SCR-14, скан — перезапускает
// паузу). Удаление крестиком — «Отменить» 5 с, затем метка удаления (CART-004). Склад, скидка, очистка, «Отложить»,
// «Принять новые цены» — только онлайн через `CartSync.direct` (сначала очередь, затем запрос с актуальным
// `rowVersion`).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/debouncer.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/cart/presentation/cart_formats.dart';

/// Копия старше этого срока при открытии — баннер «Данные от {time} — обновляем…», CTA ждёт `GET /cart`
/// (CART-016, `cart_stale_minutes` 15 мин [НЕ ПОДТВЕРЖДЕНО, Q-020]).
const Duration cartStaleAfter = Duration(minutes: 15);

/// Повтор `GET /cart` при `503 catalog_not_loaded` без `Retry-After` (08 §4.7.1 «Уточнения» п. 2: `Retry-After: 60`).
const Duration cartCatalogRetryAfter = Duration(seconds: 60);

/// Окно «Отменить» после удаления строки крестиком (UI-20-028, 5 с [НЕ ПОДТВЕРЖДЕНО, Q-176]).
const Duration cartUndoWindow = Duration(seconds: 5);

/// Потолок скидки подтверждающих ролей: больше — «Скидка больше {max} % не допускается» (02 SCR-20.4 «Зона E»;
/// `admin` 15 % [НЕ ПОДТВЕРЖДЕНО, Q-015]).
const Percent cartDiscountCeiling = Percent(1500);

/// Лимит подтверждающего для override UI-20-033 (11 §4.3 №24): `senior_seller` — 10 %, `admin` — 15 %
/// [НЕ ПОДТВЕРЖДЕНО, Q-015]; прочие роли override не предлагают (`null`).
Percent? cartApproverLimit(RoleCode? role) => switch (role) {
  RoleCode.seniorSeller => const Percent(1000),
  RoleCode.admin => cartDiscountCeiling,
  _ => null,
};

/// Онлайн-операция корзины (кнопка в `loading`, повтор игнорируется).
enum CartOp { park, clear, warehouse, discount, acceptPrices, customer, resolve, resume, retry, checkout, variant }

/// Строка корзины для экрана: серверная строка + локальное изменение.
final class CartLineView {
  const CartLineView({
    required this.key,
    required this.title,
    required this.quantity,
    required this.step,
    this.productId,
    this.variantName,
    this.sku,
    this.imageUrl,
    this.serverQuantity,
    this.unitId,
    this.unitLabel,
    this.factor,
    this.unitPrice,
    this.lineTotal,
    this.pending = false,
    this.failed = false,
    this.priceChanged = false,
    this.oldPrice,
    this.newPrice,
    this.stockInsufficient = false,
    this.available,
    this.remainingAvailable,
    this.stockLevel,
    this.unavailable = false,
    this.minQuantity,
    this.precision = 0,
  });

  final CartLineKey key;
  final String? productId;
  final String title;
  final String? variantName;
  final String? sku;
  final String? imageUrl;

  /// Показываемое количество (единицы строки): оптимистичное → черновик → сервер.
  final Qty quantity;

  /// Количество в последнем ответе сервера; `null` — строки на сервере ещё нет.
  final Qty? serverQuantity;
  final String? unitId;
  final String? unitLabel;

  /// Базовых единиц в упаковке строки (`null` — базовая единица).
  final Qty? factor;

  /// Цена за единицу строки (сервер; офлайн — снимок).
  final Money? unitPrice;

  /// Сумма строки сервера — только если количество подтверждено сервером.
  final Money? lineTotal;

  /// Изменение ещё не подтверждено сервером.
  final bool pending;

  /// Сервер отклонил изменение (`dead`) — «не отправлено».
  final bool failed;
  final bool priceChanged;
  final Money? oldPrice;
  final Money? newPrice;
  final bool stockInsufficient;

  /// Доступно на складе корзины (базовая единица); `null` — скрыто/неизвестно.
  final Qty? available;

  /// Сколько ещё можно добавить (базовая единица); `null` — неизвестно.
  final Qty? remainingAvailable;
  final CartStockLevel? stockLevel;

  /// `VARIANT_UNAVAILABLE` — товар больше не продаётся.
  final bool unavailable;

  /// Шаг «+»/«−» (единицы строки).
  final Qty step;

  /// Минимальная партия (единицы строки); по умолчанию — шаг.
  final Qty? minQuantity;

  /// Знаков после запятой у количества строки (упаковки — 0).
  final int precision;

  /// Сумма строки не подтверждена сервером (метка «≈»).
  bool get preliminary => pending || serverQuantity == null || serverQuantity != quantity;

  /// Наименьшее количество строки: «−» ниже — удаление с подтверждением (CART-003/012).
  Qty get minimum {
    final Qty m = minQuantity ?? step;
    return m > step ? m : step;
  }

  /// «−» на минимальном количестве ведёт к удалению.
  bool get atMinimum => !(quantity > minimum);

  /// «+» доступна: товар продаётся и прибавка помещается в `remainingAvailable` (INV-042).
  bool get canIncrement {
    if (unavailable) return false;
    final Qty? rem = remainingAvailable;
    if (rem == null) return true;
    final Qty base = serverQuantity ?? Qty.zero;
    final int deltaLine = quantity.milli + step.milli - base.milli;
    final int factorMilli = factor?.milli ?? 1000;
    final int deltaBase = deltaLine * factorMilli ~/ 1000;
    return deltaBase <= rem.milli;
  }

  /// Количество «Уменьшить до {available}» в единицах строки (вниз до кратного упаковки; INV-006).
  Qty? get reduceTarget {
    final Qty? a = available;
    if (a == null) return null;
    if (a.milli <= 0) return Qty.zero;
    final Qty? f = factor;
    if (f == null || f.milli <= 0) return a;
    return Qty.units(a.milli ~/ f.milli);
  }
}

/// `422 DISCOUNT_LIMIT_EXCEEDED`: корзина не изменилась (08 §4.7.5).
final class CartDiscountRejection {
  const CartDiscountRejection({required this.requested, this.limit, this.requiresRole});

  final Percent requested;

  /// `limitPercent` — лимит роли.
  final Percent? limit;

  /// `requiresRole` — роль, которая может подтвердить.
  final String? requiresRole;

  /// Больше потолка подтверждающих ролей — эскалации нет.
  bool get overCeiling => requested.hundredths > cartDiscountCeiling.hundredths;
}

/// Состояние SCR-20.
final class CartState {
  const CartState({
    this.server,
    this.local,
    this.restoring = true,
    this.loadFailure,
    this.refreshing = false,
    this.staleAtOpen = false,
    this.optimistic = const <CartLineKey, Qty>{},
    this.hidden = const <CartLineKey>{},
    this.syncStatus = CartSyncStatus.idle,
    this.conflict,
    this.busy = const <CartOp>{},
    this.discountRejection,
    this.serverAt,
  });

  /// Последний ответ сервера.
  final Cart? server;

  /// Локальная копия drift.
  final CartLocalSnapshot? local;

  /// Восстановление после старта: ни копии, ни ответа ещё нет.
  final bool restoring;

  /// `GET /cart` не удался и показать нечего.
  final Failure? loadFailure;

  /// Идёт сверка с сервером.
  final bool refreshing;

  /// Копия старше [cartStaleAfter] при открытии (до ответа сервера).
  final bool staleAtOpen;

  /// Оптимистичные количества до записи в черновик.
  final Map<CartLineKey, Qty> optimistic;

  /// Строки, удалённые крестиком, пока открыто «Отменить».
  final Set<CartLineKey> hidden;
  final CartSyncStatus syncStatus;
  final CartVersionConflict? conflict;
  final Set<CartOp> busy;
  final CartDiscountRejection? discountRejection;

  /// Когда получен [server] («Суммы рассчитаны сервером, {time}»).
  final DateTime? serverAt;

  CartState copyWith({
    Cart? server,
    CartLocalSnapshot? local,
    bool clearLocal = false,
    bool? restoring,
    Failure? loadFailure,
    bool clearLoadFailure = false,
    bool? refreshing,
    bool? staleAtOpen,
    Map<CartLineKey, Qty>? optimistic,
    Set<CartLineKey>? hidden,
    CartSyncStatus? syncStatus,
    CartVersionConflict? conflict,
    bool clearConflict = false,
    Set<CartOp>? busy,
    CartDiscountRejection? discountRejection,
    bool clearDiscountRejection = false,
    DateTime? serverAt,
  }) => CartState(
    server: server ?? this.server,
    local: clearLocal ? null : (local ?? this.local),
    restoring: restoring ?? this.restoring,
    loadFailure: clearLoadFailure ? null : (loadFailure ?? this.loadFailure),
    refreshing: refreshing ?? this.refreshing,
    staleAtOpen: staleAtOpen ?? this.staleAtOpen,
    optimistic: optimistic ?? this.optimistic,
    hidden: hidden ?? this.hidden,
    syncStatus: syncStatus ?? this.syncStatus,
    conflict: clearConflict ? null : (conflict ?? this.conflict),
    busy: busy ?? this.busy,
    discountRejection: clearDiscountRejection ? null : (discountRejection ?? this.discountRejection),
    serverAt: serverAt ?? this.serverAt,
  );

  /// Строки для показа (порядок сервера; добавленные офлайн — в конце).
  List<CartLineView> get lines {
    final List<CartLineView> out = <CartLineView>[];
    final Set<CartLineKey> seen = <CartLineKey>{};
    final Cart? s = server;
    if (s != null) {
      for (final CartLine l in s.items) {
        final CartLineKey key = CartLineKey(l.variantId, l.packagingId);
        seen.add(key);
        if (hidden.contains(key)) continue;
        final CartLocalLine? ll = local?.line(key);
        final Qty qty = optimistic[key] ?? (ll != null && ll.isUnsent ? ll.quantity : l.quantity.value);
        if (qty.isZero) continue;
        final List<CartConflict> conflicts = <CartConflict>[
          for (final CartConflict c in s.warnings)
            if (c.variantId == l.variantId) c,
        ];
        CartConflict? of(CartConflictKind k) {
          for (final CartConflict c in conflicts) {
            if (c.kind == k) return c;
          }
          return null;
        }

        final CartConflict? price = of(CartConflictKind.priceChanged);
        final CartConflict? stock = of(CartConflictKind.stockInsufficient);
        final bool priceChanged = price != null || l.warnings.contains(CartItemWarning.priceChanged);
        final bool stockShort = stock != null || l.warnings.contains(CartItemWarning.stockInsufficient);
        final bool unavailable =
            of(CartConflictKind.variantUnavailable) != null || l.warnings.contains(CartItemWarning.variantUnavailable);
        final bool fromPackaging = l.packagingId != null;
        out.add(
          CartLineView(
            key: key,
            productId: l.productId ?? ll?.productId,
            title: l.productName ?? ll?.productName ?? l.sku ?? l.variantId,
            variantName: l.variantName ?? ll?.variantName,
            sku: l.sku ?? ll?.sku,
            imageUrl: l.image?.thumbUrl ?? l.image?.cardUrl,
            quantity: qty,
            serverQuantity: l.quantity.value,
            unitId: l.quantity.unitId,
            unitLabel: l.packaging?.name ?? ll?.unitLabel,
            factor: l.packaging?.factor ?? ll?.factor,
            unitPrice: l.unitPrice,
            lineTotal: l.lineTotal,
            pending: optimistic.containsKey(key) || (ll?.syncState == CartDraftSyncState.pending),
            failed: ll?.syncState == CartDraftSyncState.dead,
            priceChanged: priceChanged,
            oldPrice: price?.oldPrice ?? l.priceSnapshot,
            newPrice: price?.newPrice ?? l.unitPrice,
            stockInsufficient: stockShort,
            available: stock?.available ?? l.available,
            remainingAvailable: l.remainingAvailable,
            stockLevel: stock?.stockLevel,
            unavailable: unavailable,
            step: fromPackaging ? Qty.units(1) : (ll?.step ?? Qty.units(1)),
            minQuantity: fromPackaging ? null : ll?.minQuantity,
            precision: fromPackaging || l.packaging?.allowFraction == false ? 0 : (ll?.qtyPrecision ?? 0),
          ),
        );
      }
    }
    for (final CartLocalLine ll in local?.lines ?? const <CartLocalLine>[]) {
      if (seen.contains(ll.key) || hidden.contains(ll.key)) continue;
      // Без ответа сервера строки, подтверждённые прежде (`synced`), показываются из копии; удалённые сервером
      // после ответа — нет.
      if (s != null && !ll.isUnsent) continue;
      final Qty qty = optimistic[ll.key] ?? ll.quantity;
      if (qty.isZero) continue;
      out.add(
        CartLineView(
          key: ll.key,
          productId: ll.productId,
          title: ll.productName ?? ll.sku ?? ll.key.variantId,
          variantName: ll.variantName,
          sku: ll.sku,
          quantity: qty,
          unitId: ll.unitId,
          unitLabel: ll.unitLabel,
          factor: ll.factor,
          unitPrice: ll.priceSnapshot,
          pending: ll.isUnsent || optimistic.containsKey(ll.key),
          failed: ll.syncState == CartDraftSyncState.dead,
          priceChanged: ll.priceChanged,
          stockInsufficient: ll.stockInsufficient,
          available: ll.stockSnapshot,
          step: ll.step ?? Qty.units(1),
          minQuantity: ll.minQuantity,
          precision: ll.qtyPrecision ?? 0,
        ),
      );
    }
    return out;
  }

  /// Изменения не подтверждены сервером: оптимистичные, неотправленные, ожидающие удаления.
  bool get hasUnconfirmed =>
      optimistic.isNotEmpty || hidden.isNotEmpty || (local?.hasUnsent ?? false) || syncStatus.queued > 0;

  /// «Итого» — предварительно (UI-20-030).
  bool get preliminary => server == null || hasUnconfirmed;

  bool isBusy(CartOp op) => busy.contains(op);
}

/// Одноразовое сообщение корзины для экрана.
final class CartNotice {
  /// «Корзина обновлена с сервера: изменено {count} позиций» (CART-009 п. 4).
  const CartNotice.updatedFromServer(this.count) : kind = CartNoticeKind.updatedFromServer;

  /// «Слишком много позиций (максимум {count}). Оформите часть заказа отдельно» (10 CART-024, 02 SCR-20.8
  /// «Лимит строк»): сервер отклонил новую строку — `400 VALIDATION_FAILED`, rule `max_items` (08 §4.7.2).
  const CartNotice.maxItems(this.count) : kind = CartNoticeKind.maxItems;

  final CartNoticeKind kind;

  /// Число изменённых позиций ([CartNoticeKind.updatedFromServer]) или предел строк ([CartNoticeKind.maxItems]).
  final int count;
}

/// Вид снекбара корзины.
enum CartNoticeKind { updatedFromServer, maxItems }

/// Правило `errors[].rule` превышения предела строк корзины (08 §4.7.2, API-003).
const String cartMaxItemsRule = 'max_items';

/// `cartProvider` (02 SCR-20.9) — провайдер уровня приложения.
final cartControllerProvider = NotifierProvider<CartController, CartState>(CartController.new);

final class CartController extends Notifier<CartState> {
  late CartSync _sync;
  final Debouncer _debounce = Debouncer(Debouncer.cart);
  final Map<CartLineKey, Timer> _removals = <CartLineKey, Timer>{};
  final Map<CartLineKey, Qty> _removed = <CartLineKey, Qty>{};
  final List<StreamSubscription<Object?>> _subs = <StreamSubscription<Object?>>[];
  final StreamController<CartNotice> _notices = StreamController<CartNotice>.broadcast();
  Timer? _catalogRetry;
  bool _disposed = false;

  @override
  CartState build() {
    // Смена пользователя (другая БД) — новое состояние корзины (07 §11.1 п.2).
    ref.watch(appDatabaseProvider);
    _sync = ref.watch(cartSyncProvider);
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _debounce.dispose();
      _catalogRetry?.cancel();
      for (final Timer t in _removals.values) {
        t.cancel();
      }
      _removals.clear();
      for (final StreamSubscription<Object?> s in _subs) {
        unawaited(s.cancel());
      }
      _subs.clear();
      unawaited(_notices.close());
    });
    _subs
      ..add(_sync.watchLocal().listen(_onLocal, onError: (Object _) {}))
      ..add(_sync.events.listen(_onEvent, onError: (Object _) {}))
      ..add(_sync.watchStatus().listen(_onStatus, onError: (Object _) {}));
    ref.listen<OnlineStatus>(cartOnlineStatusProvider, (OnlineStatus? previous, OnlineStatus next) {
      final bool wasOffline = previous == OnlineStatus.offline || previous == OnlineStatus.serverDown;
      if (wasOffline && next == OnlineStatus.online) unawaited(refresh());
    });
    scheduleMicrotask(_restore);
    return CartState(conflict: _sync.conflict);
  }

  bool get _offline {
    final OnlineStatus s = ref.read(cartOnlineStatusProvider);
    return s == OnlineStatus.offline || s == OnlineStatus.serverDown;
  }

  Clock get _clock => ref.read(clockProvider);

  CartRepository get _repo => ref.read(cartRepositoryProvider);

  /// Изменение состояния от текущего: после `await` провайдер мог быть уничтожен (выход, смена пользователя,
  /// закрытие приложения) — тогда чтение `state` бросило бы UnmountedRefException, и обновление пропускается.
  void _update(CartState Function(CartState state) change) {
    if (!_disposed && ref.mounted) state = change(state);
  }

  Future<void> _restore() async {
    if (_disposed) return;
    final CartLocalSnapshot? local = (await _sync.loadLocal()).valueOrNull;
    if (_disposed) return;
    final DateTime? at = local?.serverSyncedAt;
    final bool stale = at != null && _clock.nowUtc().difference(at) > cartStaleAfter;
    _update(
      (CartState state) => state.copyWith(
        local: local,
        restoring: local == null && state.server == null,
        staleAtOpen: state.server == null && stale,
      ),
    );
    await refresh();
    // Провайдер мог быть уничтожен во время запроса (выход, смена пользователя, закрытие приложения) —
    // `state` после этого недоступен (UnmountedRefException; найдено integration_test/auth_flow_test.dart).
    if (_disposed || !ref.mounted) return;
    // CART-009 п. 4: после восстановления копия сверена с сервером — сколько подтверждённых строк отличается.
    final Cart? server = state.server;
    if (local == null || server == null || _disposed) return;
    final Map<CartLineKey, Qty> before = <CartLineKey, Qty>{
      for (final CartLocalLine l in local.lines)
        if (!l.isUnsent) l.key: l.quantity,
    };
    final Set<CartLineKey> unsent = <CartLineKey>{
      for (final CartLocalLine l in local.lines)
        if (l.isUnsent) l.key,
    };
    final Map<CartLineKey, Qty> after = <CartLineKey, Qty>{
      for (final CartLine l in server.items) CartLineKey(l.variantId, l.packagingId): l.quantity.value,
    };
    final int changed = <CartLineKey>{
      ...before.keys,
      ...after.keys,
    }.where((CartLineKey k) => !unsent.contains(k) && before[k] != after[k]).length;
    if (changed > 0 && !_notices.isClosed) _notices.add(CartNotice.updatedFromServer(changed));
  }

  /// Одноразовые сообщения экрану (снекбары).
  Stream<CartNotice> watchNotices() => _notices.stream;

  void _onLocal(CartLocalSnapshot? local) {
    if (_disposed) return;
    final Map<CartLineKey, Qty> optimistic = <CartLineKey, Qty>{
      for (final MapEntry<CartLineKey, Qty> e in state.optimistic.entries)
        if (local?.line(e.key)?.quantity != e.value) e.key: e.value,
    };
    _update(
      (CartState state) => state.copyWith(
        local: local,
        clearLocal: local == null,
        optimistic: optimistic,
        restoring: state.server == null && local == null && state.restoring,
      ),
    );
    if (local != null && local.lines.any((CartLocalLine l) => l.syncState == CartDraftSyncState.pending)) {
      _debounce(() => unawaited(_syncNow()));
    }
  }

  void _onEvent(CartSyncEvent e) {
    if (_disposed) return;
    switch (e) {
      case CartServerUpdated(:final Cart cart):
        _update(
          (CartState state) => state.copyWith(
            server: cart,
            serverAt: _clock.nowUtc(),
            restoring: false,
            clearLoadFailure: true,
            staleAtOpen: false,
            clearConflict: _sync.conflict == null,
          ),
        );
      case CartConflictDetected(:final CartVersionConflict conflict):
        _update((CartState state) => state.copyWith(conflict: conflict));
      case CartSyncRejected(:final Failure failure):
        // 201-я строка (10 CART-024): сервер отклонил запись очереди — строка помечена «не отправлено», снекбар с
        // пределом. Остальные отказы показывает сама строка (`failed`).
        if (failure is ValidationFailure &&
            failure.errors.any((FieldError e) => e.rule == cartMaxItemsRule) &&
            !_notices.isClosed) {
          _notices.add(const CartNotice.maxItems(Cart.maxItems));
        }
    }
  }

  void _onStatus(CartSyncStatus s) {
    if (!_disposed) _update((CartState state) => state.copyWith(syncStatus: s));
  }

  Future<void> _syncNow() async {
    if (_disposed) return;
    await _sync.sync();
  }

  /// Сверка с сервером: очередь → `GET /cart` (CART-009).
  Future<Failure?> refresh() async {
    if (_disposed) return null;
    if (_offline) {
      _update((CartState state) => state.copyWith(refreshing: false, restoring: false));
      return const NetworkFailure(NetworkFailureKind.offline);
    }
    _update((CartState state) => state.copyWith(refreshing: true));
    final Result<Cart> r = await _sync.refresh();
    if (_disposed) return null;
    final Failure? f = r.failureOrNull;
    final Cart? fresh = r.valueOrNull;
    // `503 ONEC_UNAVAILABLE reason=catalog_not_loaded` (08 §4.7.1 «Уточнения» п. 2, OpenAPI 1.2.0): каталог 1С ещё не
    // загружен — повтор `GET /cart` через `Retry-After` (60 с), пока провайдер жив; ручной «Повторить» доступен сразу.
    _catalogRetry?.cancel();
    if (f is OnecUnavailableFailure && f.catalogNotLoaded) {
      _catalogRetry = Timer(f.retryAfter ?? cartCatalogRetryAfter, () => unawaited(refresh()));
    }
    _update(
      (CartState state) => state.copyWith(
        server: fresh,
        serverAt: fresh == null ? null : _clock.nowUtc(),
        refreshing: false,
        restoring: false,
        loadFailure: f != null && state.server == null && state.local == null ? f : null,
        clearLoadFailure: f == null,
        staleAtOpen: f == null ? false : state.staleAtOpen,
      ),
    );
    return f;
  }

  /// Отправить изменения сейчас (перед «Создать заказ», F9): без ожидания паузы ввода.
  Future<void> flushNow() async {
    _debounce.cancel();
    await _sync.sync();
  }

  /// Абсолютное количество строки (степпер, нампад, «Уменьшить до»). 0 — удаление (после `ConfirmDialog`).
  Future<void> setQuantity(CartLineKey key, Qty quantity) async {
    _update((CartState state) => state.copyWith(optimistic: <CartLineKey, Qty>{...state.optimistic, key: quantity}));
    final Result<void> r = await _sync.setQuantity(key, quantity);
    if (r is FailureResult<void>) {
      _update((CartState state) => state.copyWith(optimistic: <CartLineKey, Qty>{...state.optimistic}..remove(key)));
    }
  }

  /// «+» на шаг.
  Future<void> increment(CartLineView line) => setQuantity(line.key, line.quantity + line.step);

  /// «−» на шаг; на минимальном количестве — `false` (нужно подтверждение удаления, CART-003/012).
  Future<bool> decrement(CartLineView line) async {
    if (line.atMinimum) return false;
    final Qty next = line.quantity - line.step;
    await setQuantity(line.key, next < line.minimum ? line.minimum : next);
    return true;
  }

  /// Крестик / свайп / `Delete`: строка скрывается, «Отменить» 5 с; затем — метка удаления (CART-004).
  void removeWithUndo(CartLineKey key, {Qty? previous}) {
    _removals.remove(key)?.cancel();
    if (previous != null) _removed[key] = previous;
    _update((CartState state) => state.copyWith(hidden: <CartLineKey>{...state.hidden, key}));
    _removals[key] = Timer(cartUndoWindow, () => unawaited(_commitRemoval(key)));
  }

  /// «Отменить» удаление (`Ctrl+Z`): в окне 5 с — строка возвращается без запроса; позже — прежнее количество
  /// ставится заново.
  void undoRemove(CartLineKey key) {
    final Timer? pending = _removals.remove(key);
    final Qty? previous = _removed.remove(key);
    if (pending != null) {
      pending.cancel();
      _update((CartState state) => state.copyWith(hidden: <CartLineKey>{...state.hidden}..remove(key)));
    } else if (previous != null) {
      unawaited(setQuantity(key, previous));
    }
  }

  /// Удаление выполняется сразу (снекбар закрыт или уход с экрана).
  Future<void> commitRemovals() async {
    for (final CartLineKey key in _removals.keys.toList()) {
      _removals.remove(key)?.cancel();
      await _commitRemoval(key);
    }
  }

  Future<void> _commitRemoval(CartLineKey key) async {
    _removals.remove(key);
    if (_disposed) return;
    await _sync.setQuantity(key, Qty.zero);
    _update((CartState state) => state.copyWith(hidden: <CartLineKey>{...state.hidden}..remove(key)));
  }

  Future<Failure?> _online<T>(
    CartOp op,
    Future<Result<T>> Function(int rowVersion) call, {
    required Cart? Function(T value) cartOf,
    bool keepPending = true,
    Set<CartLineKey> settle = const <CartLineKey>{},
  }) async {
    if (state.isBusy(op)) return null;
    _update((CartState state) => state.copyWith(busy: <CartOp>{...state.busy, op}));
    _debounce.cancel();
    final Result<T> r = await _sync.direct<T>(call, cartOf: cartOf, keepPending: keepPending, settle: settle);
    _update((CartState state) => state.copyWith(busy: <CartOp>{...state.busy}..remove(op)));
    return r.failureOrNull;
  }

  /// «Очистить корзину» (UI-20-003): `DELETE /cart?rowVersion=` → новая пустая `active` (CART-011).
  Future<Failure?> clear() async {
    for (final Timer t in _removals.values) {
      t.cancel();
    }
    _removals.clear();
    final Failure? f = await _online<Cart>(
      CartOp.clear,
      (int rv) => _repo.clear(rowVersion: rv),
      cartOf: (Cart c) => c,
      keepPending: false,
    );
    if (f == null) {
      _update(
        (CartState state) => state.copyWith(hidden: const <CartLineKey>{}, optimistic: const <CartLineKey, Qty>{}),
      );
    }
    return f;
  }

  /// «Отложить заказ» (UI-20-015/026): `POST /cart/park` с ключом [idempotencyKey] (создан при нажатии и
  /// переиспользуется при повторе) → новая пустая `active` (CART-030).
  Future<Failure?> park({String? name, required String idempotencyKey}) async {
    await commitRemovals();
    final Failure? f = await _online<CartParkResult>(
      CartOp.park,
      (int rv) => _repo.park(rowVersion: rv, name: name, idempotencyKey: idempotencyKey),
      cartOf: (CartParkResult p) => p.active,
      keepPending: false,
    );
    if (f == null) _update((CartState state) => state.copyWith(optimistic: const <CartLineKey, Qty>{}));
    return f;
  }

  /// Смена склада корзины (UI-20-005; `PATCH /cart`, ядро §19.2). Результат — новая корзина или ошибка.
  Future<Result<Cart>> setWarehouse(String warehouseId) async {
    Cart? updated;
    final Failure? f = await _online<Cart>(
      CartOp.warehouse,
      (int rv) => _repo.setWarehouse(warehouseId, rowVersion: rv),
      cartOf: (Cart c) => updated = c,
    );
    return f == null ? Success<Cart>(updated ?? state.server!) : FailureResult<Cart>(f);
  }

  /// Ручная скидка (UI-20-013/032): `POST /cart/discount {percent, rowVersion}`; `422 DISCOUNT_LIMIT_EXCEEDED` —
  /// корзина не изменилась, состояние [CartState.discountRejection] (без урезания до лимита, DISC-004).
  Future<Failure?> applyDiscount(Percent percent) async {
    _update((CartState state) => state.copyWith(clearDiscountRejection: true));
    final Failure? f = await _online<Cart>(
      CartOp.discount,
      (int rv) => _repo.applyDiscount(CartDiscountInput(percent: percent, rowVersion: rv)),
      cartOf: (Cart c) => c,
    );
    if (f is ServerFailure && f.code == 'DISCOUNT_LIMIT_EXCEEDED') {
      _update(
        (CartState state) => state.copyWith(
          discountRejection: CartDiscountRejection(
            requested: percent,
            limit: CartFormats.percentOf(f.details['limitPercent']) ?? state.server?.discountLimitPercent,
            requiresRole: f.details['requiresRole'] is String ? f.details['requiresRole']! as String : null,
          ),
        ),
      );
    }
    return f;
  }

  /// «Подтвердить скидку {p} %» (UI-20-033, DISC-010): override старшего с причиной и step-up —
  /// `POST /cart/discount {percent, override:{reason}, rowVersion}` + `X-Step-Up-Token`.
  Future<Failure?> approveDiscount(Percent percent, {required String reason, required String stepUpToken}) async {
    final Failure? f = await _online<Cart>(
      CartOp.discount,
      (int rv) => _repo.applyDiscount(
        CartDiscountInput(percent: percent, rowVersion: rv, overrideReason: reason),
        stepUpToken: stepUpToken,
      ),
      cartOf: (Cart c) => c,
    );
    if (f == null) _update((CartState state) => state.copyWith(clearDiscountRejection: true));
    return f;
  }

  /// Новое значение в поле скидки — отказ больше не актуален (кнопка «Применить {limit} %» скрывается).
  void clearDiscountRejection() => _update((CartState state) => state.copyWith(clearDiscountRejection: true));

  /// «Принять новые цены» (UI-20-024): строки с `price_changed` — `PUT mode=set` того же количества с текущей ценой
  /// в `priceSnapshot` (CART-013). Ошибка одного запроса — баннер остаётся.
  Future<Failure?> acceptPrices() async {
    final Cart? s = state.server;
    if (s == null) return null;
    final Set<String> changed = <String>{
      for (final CartConflict c in s.warnings)
        if (c.kind == CartConflictKind.priceChanged) c.variantId,
    };
    final List<CartLine> lines = <CartLine>[
      for (final CartLine l in s.items)
        if (changed.contains(l.variantId) || l.warnings.contains(CartItemWarning.priceChanged)) l,
    ];
    Failure? failure;
    for (final CartLine l in lines) {
      failure = await _online<Cart>(
        CartOp.acceptPrices,
        (int rv) =>
            _repo.putItem(l.variantId, CartItemPut(quantity: l.quantity, rowVersion: rv, priceSnapshot: l.unitPrice)),
        cartOf: (Cart c) => c,
      );
      if (failure != null) break;
    }
    return failure;
  }

  /// Строка того же варианта и упаковки, что [variantId] (кроме [except]) — цель объединения при смене варианта.
  CartLineView? lineFor(String variantId, String? packagingId) {
    for (final CartLineView l in state.lines) {
      if (l.key.variantId == variantId && l.key.packagingId == packagingId) return l;
    }
    return null;
  }

  /// Смена варианта строки (10 CART-005, 02 UI-15-007; только онлайн): новая строка с тем же количеством и
  /// упаковкой (`PUT /cart/items/{new}` `mode=set`), затем удаление одной старой строки ([_deleteLineDirect]).
  /// Если новый вариант с той же упаковкой уже в корзине — количества суммируются (подтверждение — у экрана).
  /// Порядок «сначала PUT»: отказ сервера по новому варианту (остаток, кратность, `VARIANT_UNAVAILABLE`) корзину
  /// не меняет — старая строка остаётся. Цена и остаток нового варианта — расчёт сервера (D-23).
  /// Удаление старой строки не прошло после записанного PUT — оно ставится в очередь cart.sync (идемпотентный
  /// повтор; постоянная ошибка — «Ошибка сохранения · Повторить», UI-20-023), и повторная замена не суммирует
  /// количество второй раз.
  /// Неотправленные изменения обеих строк (`pending`/«не отправлено») снимаются ответом сервера (`settle`): их
  /// количество уже вошло в замену (RC-1). Намерение замены записано до PUT ([CartSync.beginReplace]): при обрыве
  /// между PUT и удалением сверка после перезапуска удаляет старую строку (RC-2).
  Future<Failure?> replaceVariant(CartLineView line, String variantId, {Money? priceSnapshot}) async {
    if (variantId == line.key.variantId || state.isBusy(CartOp.variant)) return null;
    final String? unitId = line.unitId;
    if (unitId == null) return const NetworkFailure(NetworkFailureKind.offline);
    final String? packagingId = line.key.packagingId;
    final CartLineKey target = CartLineKey(variantId, packagingId);
    final CartLineView? existing = lineFor(variantId, packagingId);
    final Qty merged = existing == null ? line.quantity : existing.quantity + line.quantity;
    await _sync.beginReplace(CartLineReplace(from: line.key, to: target, quantity: merged));
    try {
      return await _replace(line, target, merged, unitId, priceSnapshot);
    } finally {
      await _sync.endReplace();
    }
  }

  Future<Failure?> _replace(
    CartLineView line,
    CartLineKey target,
    Qty merged,
    String unitId,
    Money? priceSnapshot,
  ) async {
    final String variantId = target.variantId;
    final String? packagingId = target.packagingId;
    Failure? deleteFailure;
    final Failure? f = await _online<Cart>(
      CartOp.variant,
      (int rv) async {
        final Result<Cart> put = await _repo.putItem(
          variantId,
          CartItemPut(
            quantity: LineQuantity(value: merged, unitId: unitId, packagingId: packagingId),
            rowVersion: rv,
            priceSnapshot: priceSnapshot,
          ),
        );
        if (put is! Success<Cart>) return put;
        final Result<Cart> del = await _deleteLineDirect(line.key, unitId, rowVersion: put.value.rowVersion);
        if (del is Success<Cart>) return del;
        // Новая строка уже записана сервером: копия получает её корзину, удаление старой — ниже через очередь.
        deleteFailure = del.failureOrNull;
        return put;
      },
      cartOf: (Cart c) => c,
      settle: <CartLineKey>{line.key, target},
    );
    if (f != null) return f;
    if (deleteFailure != null) {
      final Result<void> queued = await _sync.setQuantity(line.key, Qty.zero);
      if (queued.isSuccess) deleteFailure = null;
    }
    _update(
      (CartState state) => state.copyWith(
        optimistic: <CartLineKey, Qty>{...state.optimistic}
          ..remove(line.key)
          ..remove(target),
      ),
    );
    return deleteFailure;
  }

  /// Удаление одной строки напрямую: с упаковкой — `DELETE /cart/items/{id}?packagingId=`; строка базовой единицы —
  /// `PUT mode=set 0` с её единицей (DELETE без `packagingId` удалил бы и строки упаковок варианта, 08 §4.7.3
  /// Уточнения п. 1; тот же приём, что у удаления строки очередью cart.sync).
  Future<Result<Cart>> _deleteLineDirect(CartLineKey key, String unitId, {required int rowVersion}) {
    final String? packagingId = key.packagingId;
    if (packagingId != null) return _repo.deleteItem(key.variantId, packagingId: packagingId);
    return _repo.putItem(
      key.variantId,
      CartItemPut(
        quantity: LineQuantity(value: Qty.zero, unitId: unitId),
        rowVersion: rowVersion,
      ),
    );
  }

  /// Отвязать клиента (`DELETE /cart/customer`).
  Future<Failure?> clearCustomer() =>
      _online<Cart>(CartOp.customer, (int _) => _repo.clearCustomer(), cartOf: (Cart c) => c);

  /// Клиент корзины (UI-20-004): `POST /cart/customer {customerId, rowVersion}` — сервер пересчитывает цены по
  /// условиям клиента (CART-020); база `rowVersion` — копия устройства (`CartSync.direct`).
  Future<Failure?> setCustomer(String customerId) =>
      _online<Cart>(CartOp.customer, (int rv) => _repo.setCustomer(customerId, rowVersion: rv), cartOf: (Cart c) => c);

  /// Решение по `409 VERSION_CONFLICT` (UI-20-027).
  Future<Failure?> resolveConflict({required bool applyMine}) async {
    if (state.isBusy(CartOp.resolve)) return null;
    _update((CartState state) => state.copyWith(busy: <CartOp>{...state.busy, CartOp.resolve}));
    final Result<void> r = await _sync.resolveConflict(applyMine: applyMine);
    _update(
      (CartState state) => state.copyWith(
        busy: <CartOp>{...state.busy}..remove(CartOp.resolve),
        clearConflict: r.isSuccess,
        optimistic: const <CartLineKey, Qty>{},
      ),
    );
    return r.failureOrNull;
  }

  /// «Ошибка сохранения · Повторить» (UI-20-023).
  Future<Failure?> retryFailed() async {
    final Result<void> r = await _sync.retryFailed();
    return r.failureOrNull;
  }

  /// Ответ сервера после «Продолжить» отложенной корзины (SCR-23) — корзина становится активной.
  Future<Failure?> resume(String cartId, {bool replaceActive = false, required String idempotencyKey}) async {
    await commitRemovals();
    return _online<Cart>(
      CartOp.resume,
      (int _) => _repo.resumeParked(cartId, replaceActive: replaceActive, idempotencyKey: idempotencyKey),
      cartOf: (Cart c) => c,
      keepPending: false,
    );
  }

  /// Подготовка к оформлению (UI-20-016, F9): изменения отправлены, корзина сверена.
  Future<bool> prepareCheckout() async {
    if (state.isBusy(CartOp.checkout)) return false;
    _update((CartState state) => state.copyWith(busy: <CartOp>{...state.busy, CartOp.checkout}));
    try {
      await commitRemovals();
      await flushNow();
      return state.server != null && state.conflict == null;
    } finally {
      _update((CartState state) => state.copyWith(busy: <CartOp>{...state.busy}..remove(CartOp.checkout)));
    }
  }
}

/// Позиции корзины для счётчиков и `CartFab` (без провайдера экрана).
extension CartStateCounters on CartState {
  /// Число позиций (строк): сервер; при неподтверждённых изменениях — по показываемым строкам.
  int get positions => preliminary || server?.itemsCount == null ? lines.length : server!.itemsCount!;

  /// «6 шт, 12,5 м» — суммы показываемых количеств по единицам строк.
  String unitsText(String fallbackUnit) {
    final Map<String, int> byUnit = <String, int>{};
    for (final CartLineView l in lines) {
      final String u = l.unitLabel ?? fallbackUnit;
      byUnit[u] = (byUnit[u] ?? 0) + l.quantity.milli;
    }
    return <String>[
      for (final MapEntry<String, int> e in byUnit.entries) '${CartFormats.qty(Qty(e.value))} ${e.key}',
    ].join(', ');
  }

  /// Блокирующие предупреждения строк.
  bool get hasPriceChanges => lines.any((CartLineView l) => l.priceChanged);
  bool get hasStockShortage => lines.any((CartLineView l) => l.stockInsufficient && !l.unavailable);
  bool get hasUnavailable => lines.any((CartLineView l) => l.unavailable);
}

/// Число своих отложенных корзин для «Отложенные (n)» (UI-20-002); `null` — неизвестно.
final cartParkedCountProvider = FutureProvider.autoDispose<int?>((Ref ref) async {
  final CartPermissions can = cartPermissionsFor(ref.watch(cartViewerRoleProvider));
  if (!can.canPark) return null;
  final Result<PageResult<CartParkedSummary>> r = await ref.watch(cartRepositoryProvider).listParked(limit: 50);
  return r.valueOrNull?.items.length;
});

/// Права корзины по роли (11 §4.3; `/me.permissions` у фичи cart недоступен — роль из корня).
final class CartPermissions {
  const CartPermissions({
    required this.customer,
    required this.canPark,
    required this.canDiscount,
    required this.canChangeWarehouse,
    required this.canChooseCustomer,
    required this.canSeeAllParked,
    required this.canResumeAny,
    required this.readOnlyParked,
  });

  /// Режим клиента (ядро §24.2): своя корзина без «Отложить», скидки, клиента и склада.
  final bool customer;
  final bool canPark;
  final bool canDiscount;
  final bool canChangeWarehouse;
  final bool canChooseCustomer;

  /// `cart.parked.read.all` — вкладка «Все».
  final bool canSeeAllParked;

  /// `cart.parked.resume.any` — продолжить/удалить чужую.
  final bool canResumeAny;

  /// `owner` — только просмотр отложенных.
  final bool readOnlyParked;
}

/// Права корзины для роли [role] (`null` — как `seller`).
CartPermissions cartPermissionsFor(RoleCode? role) => switch (role) {
  RoleCode.customer => const CartPermissions(
    customer: true,
    canPark: false,
    canDiscount: false,
    canChangeWarehouse: false,
    canChooseCustomer: false,
    canSeeAllParked: false,
    canResumeAny: false,
    readOnlyParked: false,
  ),
  RoleCode.owner || RoleCode.integration => const CartPermissions(
    customer: false,
    canPark: false,
    canDiscount: false,
    canChangeWarehouse: false,
    canChooseCustomer: false,
    canSeeAllParked: true,
    canResumeAny: false,
    readOnlyParked: true,
  ),
  RoleCode.seniorSeller || RoleCode.admin => const CartPermissions(
    customer: false,
    canPark: true,
    canDiscount: true,
    canChangeWarehouse: true,
    canChooseCustomer: true,
    canSeeAllParked: true,
    canResumeAny: true,
    readOnlyParked: false,
  ),
  RoleCode.seller || RoleCode.cashier || null => const CartPermissions(
    customer: false,
    canPark: true,
    canDiscount: true,
    canChangeWarehouse: true,
    canChooseCustomer: true,
    canSeeAllParked: false,
    canResumeAny: false,
    readOnlyParked: false,
  ),
};
