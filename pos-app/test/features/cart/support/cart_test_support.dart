// Поддержка widget-/golden-тестов SCR-20/SCR-23 (RM-F-005): фейковый `CartSync` поверх `FakeCartRepository`
// (test/support/f_fakes.dart), корзина канонического примера 02 ч. C §3.2 (16 850,00; скидка 5 % = 842,50;
// итого 16 007,50), обёртка приложения с go_router и подменой провайдеров. Данные синтетические.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/cart/presentation/screens/cart_screen.dart';
import 'package:optomstroy/features/cart/presentation/screens/parked_carts_screen.dart';

import '../../../support/f_fakes.dart';

final DateTime cartNow = DateTime.utc(2026, 10, 22, 9, 41);

/// Строка канонического примера: [units] шт по цене [price] сом.
CartLine canonLine(
  String id,
  String name,
  String sku,
  int units,
  int price, {
  List<CartItemWarning> warnings = const <CartItemWarning>[],
  Qty? available,
  Qty? remaining,
  Money? priceSnapshot,
}) => CartLine(
  variantId: 'v-$id',
  productId: 'p-$id',
  productName: name,
  sku: sku,
  quantity: LineQuantity(value: Qty.units(units), unitId: 'u-pc'),
  unitPrice: Money.som(price),
  priceSnapshot: priceSnapshot,
  lineTotal: Money.som(price * units),
  available: available ?? Qty.units(24),
  remainingAvailable: remaining ?? Qty.units(20),
  warnings: warnings,
);

/// Корзина макета каталога (02 ч. C §3.2): 5 позиций · 6 шт, 16 850,00 − 842,50 = 16 007,50.
Cart canonCart({
  int rowVersion = 17,
  List<CartLine>? items,
  List<CartConflict> warnings = const <CartConflict>[],
  String? restoredFromOrderId,
  String? name,
}) {
  final List<CartLine> lines =
      items ??
      <CartLine>[
        canonLine('f4252', 'Смеситель для кухни Frap F4252', 'F4252', 2, 2350),
        canonLine('f2283', 'Смеситель для ванны Frap F2283', 'F2283', 1, 3450),
        canonLine('g1007', 'Смеситель для раковины Gappo G1007', 'G1007', 1, 1650),
        canonLine('l74103', 'Смеситель для кухни Ledeme L74103', 'L74103', 1, 2850),
        canonLine('sus011', 'Смеситель для кухни Mixxus SUS-011', 'SUS-011', 1, 4200),
      ];
  return Cart(
    id: 'cart-1',
    status: CartStatus.active,
    items: lines,
    rowVersion: rowVersion,
    name: name,
    warehouseId: 'wh-main',
    priceListId: 'pl-retail',
    itemsCount: lines.length,
    subtotal: const Money(1685000),
    requestedDiscountPercent: const Percent(500),
    appliedDiscountPercent: const Percent(500),
    discountTotal: const Money(84250),
    total: const Money(1600750),
    discountLimitPercent: const Percent(500),
    warnings: warnings,
    restoredFromOrderId: restoredFromOrderId,
  );
}

/// Фейковый `CartSync`: копия в памяти; [sync] отправляет `pending`-строки через [repo] (`PUT mode=set`), ответ
/// публикуется событием `CartServerUpdated` — как обработчик очереди `cart.sync`.
class FakeCartSync implements CartSync {
  FakeCartSync(this.repo, {this.offline = false});

  final FakeCartRepository repo;
  bool offline;

  final StreamController<CartLocalSnapshot?> _local = StreamController<CartLocalSnapshot?>.broadcast();
  final StreamController<CartSyncEvent> _events = StreamController<CartSyncEvent>.broadcast();
  final StreamController<CartSyncStatus> _status = StreamController<CartSyncStatus>.broadcast(); // ignore: close_sinks

  CartLocalSnapshot? snapshot;
  Cart? server;
  CartVersionConflict? pendingConflict;
  final List<(CartLineKey, Qty)> setQuantityCalls = <(CartLineKey, Qty)>[];
  int syncCalls = 0;
  final List<bool> resolveCalls = <bool>[];

  /// Аргументы `settle` прямых операций.
  final List<Set<CartLineKey>> settleCalls = <Set<CartLineKey>>[];

  /// Журнал смены варианта (`beginReplace`) и число `endReplace`.
  final List<CartLineReplace> replaceJournal = <CartLineReplace>[];
  int replaceEnded = 0;
  List<CartWarehouseOption> warehouseOptions = const <CartWarehouseOption>[
    CartWarehouseOption(id: 'wh-main', name: 'Основной', isDefault: true),
    CartWarehouseOption(id: 'wh-2', name: 'Склад №2'),
  ];

  void emitLocal(CartLocalSnapshot? s) {
    snapshot = s;
    _local.add(s);
  }

  void emitServer(Cart cart) {
    server = cart;
    _events.add(CartServerUpdated(cart));
  }

  void emitConflict(CartVersionConflict c) {
    pendingConflict = c;
    _events.add(CartConflictDetected(c));
  }

  /// Сервер окончательно отклонил запись очереди (`dead`) — как обработчик `cart.sync`.
  void emitRejected(Failure failure, {CartLineKey? key}) => _events.add(CartSyncRejected(failure, key: key));

  @override
  Stream<CartLocalSnapshot?> watchLocal() async* {
    yield snapshot;
    yield* _local.stream;
  }

  @override
  Future<Result<CartLocalSnapshot?>> loadLocal() async => Success<CartLocalSnapshot?>(snapshot);

  @override
  Stream<CartSyncEvent> get events => _events.stream;

  @override
  Stream<CartSyncStatus> watchStatus() async* {
    yield CartSyncStatus.idle;
    yield* _status.stream;
  }

  @override
  CartVersionConflict? get conflict => pendingConflict;

  @override
  Future<Result<Cart>> refresh() async {
    if (offline) return const FailureResult<Cart>(NetworkFailure(NetworkFailureKind.offline));
    final Result<Cart> r = await repo.fetch();
    if (r case Success<Cart>(:final Cart value)) emitServer(value);
    return r;
  }

  CartLocalSnapshot _ensure() =>
      snapshot ??
      CartLocalSnapshot(
        localCartId: 'local-1',
        lines: const <CartLocalLine>[],
        dirty: false,
        baseRowVersion: server?.rowVersion,
      );

  @override
  Future<Result<void>> setQuantity(CartLineKey key, Qty quantity) async {
    setQuantityCalls.add((key, quantity));
    final CartLocalSnapshot s = _ensure();
    final List<CartLocalLine> lines = <CartLocalLine>[
      for (final CartLocalLine l in s.lines)
        if (l.key != key) l,
      CartLocalLine(
        key: key,
        quantity: quantity,
        syncState: CartDraftSyncState.pending,
        lineNo: s.lines.length + 1,
        unitId: 'u-pc',
        unitLabel: 'шт',
      ),
    ];
    emitLocal(
      CartLocalSnapshot(
        localCartId: s.localCartId,
        lines: lines,
        dirty: true,
        baseRowVersion: s.baseRowVersion,
        serverSyncedAt: s.serverSyncedAt,
      ),
    );
    return const Success<void>(null);
  }

  @override
  Future<Result<Qty>> addStep(CartLineKey key, {Money? priceSnapshot}) async {
    final Qty current = snapshot?.line(key)?.quantity ?? Qty.zero;
    final Qty next = current + Qty.units(1);
    await setQuantity(key, next);
    await sync();
    return Success<Qty>(next);
  }

  @override
  Future<Result<void>> sync() async {
    syncCalls++;
    if (offline) return const Success<void>(null);
    final CartLocalSnapshot? s = snapshot;
    if (s == null) return const Success<void>(null);
    for (final CartLocalLine l in s.lines) {
      if (l.syncState != CartDraftSyncState.pending) continue;
      final Result<Cart> r = await repo.putItem(
        l.key.variantId,
        CartItemPut(
          quantity: LineQuantity(value: l.quantity, unitId: l.unitId ?? 'u-pc', packagingId: l.key.packagingId),
          rowVersion: server?.rowVersion ?? 0,
        ),
        idempotencyKey: 'k-${repo.calls.length}',
      );
      if (r case Success<Cart>(:final Cart value)) {
        emitServer(value);
        _markSynced(l.key);
      }
    }
    return const Success<void>(null);
  }

  void _markSynced(CartLineKey key) {
    final CartLocalSnapshot? s = snapshot;
    if (s == null) return;
    emitLocal(
      CartLocalSnapshot(
        localCartId: s.localCartId,
        dirty: false,
        baseRowVersion: server?.rowVersion,
        lines: <CartLocalLine>[
          for (final CartLocalLine l in s.lines)
            if (l.key != key)
              l
            else if (!l.isDeletion)
              CartLocalLine(
                key: l.key,
                quantity: l.quantity,
                syncState: CartDraftSyncState.synced,
                lineNo: l.lineNo,
                unitId: l.unitId,
                unitLabel: l.unitLabel,
              ),
        ],
      ),
    );
  }

  @override
  Future<Result<T>> direct<T>(
    Future<Result<T>> Function(int rowVersion) op, {
    required Cart? Function(T value) cartOf,
    bool keepPending = true,
    Set<CartLineKey> settle = const <CartLineKey>{},
  }) async {
    settleCalls.add(settle);
    final Result<T> r = await op(server?.rowVersion ?? 0);
    if (r case Success<T>(:final T value)) {
      final Cart? cart = cartOf(value);
      if (cart != null) {
        if (!keepPending) emitLocal(null);
        emitServer(cart);
      }
    }
    return r;
  }

  @override
  Future<Result<void>> beginReplace(CartLineReplace replace) async {
    replaceJournal.add(replace);
    return const Success<void>(null);
  }

  @override
  Future<void> endReplace() async => replaceEnded++;

  @override
  Future<Result<void>> resolveConflict({required bool applyMine}) async {
    resolveCalls.add(applyMine);
    pendingConflict = null;
    return const Success<void>(null);
  }

  @override
  Future<Result<void>> retryFailed() async => const Success<void>(null);

  @override
  Future<Result<List<CartWarehouseOption>>> warehouses() async => Success<List<CartWarehouseOption>>(warehouseOptions);

  @override
  Future<CartPlaceLabels> placeLabels({String? warehouseId, String? priceListId}) async => (
    warehouse: warehouseId == 'wh-main' ? 'Основной' : (warehouseId == null ? null : 'Склад №2'),
    priceList: priceListId == null ? null : 'Розничная',
  );
}

/// Сервер-фейк: `PUT mode=set` меняет количество строки и `rowVersion`; итоги — из [totals] (сервер их считает).
void serveCart(FakeCartRepository repo, Cart initial, {Cart Function(Cart before, String variantId, Qty qty)? onPut}) {
  Cart current = initial;
  repo.onFetch = () async => Success<Cart>(current);
  repo.onPutItem = (String variantId, CartItemPut put, String? key) async {
    current =
        onPut?.call(current, variantId, put.quantity.value) ??
        Cart(
          id: current.id,
          status: current.status,
          rowVersion: current.rowVersion + 1,
          warehouseId: current.warehouseId,
          priceListId: current.priceListId,
          discountLimitPercent: current.discountLimitPercent,
          appliedDiscountPercent: current.appliedDiscountPercent,
          requestedDiscountPercent: current.requestedDiscountPercent,
          subtotal: current.subtotal,
          discountTotal: current.discountTotal,
          total: current.total,
          itemsCount: current.itemsCount,
          items: <CartLine>[
            for (final CartLine l in current.items)
              if (l.variantId == variantId)
                CartLine(
                  variantId: l.variantId,
                  productId: l.productId,
                  productName: l.productName,
                  sku: l.sku,
                  quantity: LineQuantity(value: put.quantity.value, unitId: l.quantity.unitId),
                  unitPrice: l.unitPrice,
                  lineTotal: l.lineTotal,
                  available: l.available,
                  remainingAvailable: l.remainingAvailable,
                )
              else
                l,
          ],
        );
    return Success<Cart>(current);
  };
}

/// Окна golden/widget-тестов (D-18).
const Map<String, Size> cartWindows = <String, Size>{
  'compact': Size(360, 760),
  'medium': Size(800, 900),
  'expanded': Size(1280, 800),
};

/// Набор подмен для экранов корзины.
List<Override> cartOverrides({
  required FakeCartSync sync,
  required FakeCartRepository repo,
  RoleCode role = RoleCode.seller,
  OnlineStatus online = OnlineStatus.online,
  String? userId = 'user-1',
}) => <Override>[
  cartSyncProvider.overrideWithValue(sync),
  cartRepositoryProvider.overrideWithValue(repo),
  cartViewerRoleProvider.overrideWithValue(role),
  cartViewerUserIdProvider.overrideWithValue(userId),
  cartOnlineStatusProvider.overrideWithValue(online),
  clockProvider.overrideWithValue(FixedClock(cartNow)),
];

/// Приложение с маршрутами корзины: `/cart`, `/cart/parked`, `/checkout`, `/catalog`, `/orders/:id`.
Widget cartApp({
  required List<Override> overrides,
  String initialLocation = '/cart',
  Size? size,
  Widget Function(BuildContext context)? cartBuilder,
}) {
  final GoRouter router = GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      GoRoute(
        path: '/cart',
        builder: (BuildContext context, GoRouterState state) => cartBuilder?.call(context) ?? const CartScreen(),
        routes: <RouteBase>[GoRoute(path: 'parked', builder: (_, _) => const ParkedCartsScreen())],
      ),
      GoRoute(
        path: '/checkout',
        builder: (_, GoRouterState state) => Scaffold(body: Text('checkout:${state.uri.query}')),
      ),
      GoRoute(
        path: '/catalog',
        builder: (_, _) => const Scaffold(body: Text('catalog')),
      ),
      GoRoute(
        path: '/catalog/p/:productId',
        builder: (_, GoRouterState state) => Scaffold(body: Text('product:${state.uri}')),
      ),
      GoRoute(
        path: '/orders/:id',
        builder: (_, GoRouterState state) => Scaffold(body: Text('order:${state.uri}')),
      ),
    ],
  );
  final Widget app = ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(
      routerConfig: router,
      theme: AppTheme.light(),
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      debugShowCheckedModeBanner: false,
      builder: size == null
          ? null
          : (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(size: size, disableAnimations: true, padding: EdgeInsets.zero),
              child: child!,
            ),
    ),
  );
  return size == null ? app : SizedBox(width: size.width, height: size.height, child: app);
}
