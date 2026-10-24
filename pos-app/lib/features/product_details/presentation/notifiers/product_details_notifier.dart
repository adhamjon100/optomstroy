// Состояние SCR-14 «Карточка товара» (02 SCR-14.4, SCR-14.7): открытие из кэша drift
// (NFR-PERF-003, ≤ 200 мс), затем `GET /catalog/products/{id}` без перерисовки экрана; выбор варианта,
// единицы/упаковки и количества (10 §4.1, INV-001…INV-010, INV-042); «В корзину» — в локальную
// корзину-черновик (этап E; отправка на сервер — этап F). Права проверяет сервер (D-15);
// клиент не вычисляет `available`, цену и итог по складам (D-22, D-23).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_repository.dart';
import 'package:optomstroy/features/product_details/domain/entities/qty_rules.dart';
import 'package:optomstroy/features/product_details/domain/entities/variant_axes.dart';
import 'package:optomstroy/features/product_details/product_details_providers.dart';

/// Аргументы карточки: параметры маршрута `/catalog/p/{productId}?variantId=&qty=`.
typedef ProductDetailsArgs = ({String productId, String? variantId, String? qty});

/// Этап загрузки карточки.
enum ProductLoadStatus {
  /// Нет кэша, ждём сеть — скелетоны.
  loading,

  /// Данные есть (кэш или сеть).
  ready,

  /// `404` — «Товар не найден или снят с продажи».
  notFound,

  /// Ошибка без кэша — `ErrorState.fullScreen` + «Повторить».
  error,
}

/// Состояние кнопки «В корзину» (UI-14-011/020, SCR-14.7).
enum ProductCta {
  /// «В корзину · {сумма}».
  add,

  /// «Добавить ещё» (пара вариант+упаковка уже в корзине).
  addMore,

  /// «Нет в наличии» (INV-023).
  outOfStock,

  /// «Добавление недоступно»: остаток неизвестен (INV-052), снят с продажи, нет цены (INV-013).
  unavailable,

  /// Количество нарушает правила (кнопка недоступна, текст правила — у степпера).
  invalidQuantity,

  /// Роль без `cart.manage.own` (`owner`) — панель скрыта.
  hidden,
}

/// Ключ строки корзины-черновика (`variantId`, `packagingId`).
String cartLineKey(String variantId, String? packagingId) => '$variantId|${packagingId ?? ''}';

/// Состояние SCR-14.
final class ProductDetailsState {
  const ProductDetailsState({
    this.status = ProductLoadStatus.loading,
    this.product,
    this.source,
    this.failure,
    this.refreshing = false,
    this.selectedVariantId,
    this.packagingId,
    this.quantity,
    this.inCart = const <String, Qty>{},
    this.adding = false,
    this.addedCount = 0,
    this.lastAdded,
    this.addFailure,
    this.unitHint,
    this.cacheOpenTime,
    this.role,
    this.stockDisplay = CustomerStockDisplay.status,
    this.cartWarehouseId,
  });

  final ProductLoadStatus status;
  final Product? product;
  final DataSource? source;

  /// Последняя ошибка обновления (с кэшем — `ErrorState.inline` над данными).
  final Failure? failure;

  /// Идёт запрос к серверу при показанном кэше.
  final bool refreshing;
  final String? selectedVariantId;

  /// Упаковка; `null` — базовая единица.
  final String? packagingId;

  /// Количество в базовой единице; `null` — начальное по правилам.
  final Qty? quantity;

  /// Количество в черновике корзины по [cartLineKey] (единицы строки).
  final Map<String, Qty> inCart;

  /// «В корзину» в состоянии loading (≥ 300 мс — защита от двойного клика, AC-UI-14-012).
  final bool adding;

  /// Счётчик успешных добавлений (снекбар «Добавлено …» на compact).
  final int addedCount;

  /// Последнее добавленное количество (единицы строки) и подпись единицы.
  final ({Qty quantity, String unitLabel})? lastAdded;

  /// Ошибка последнего добавления.
  final Failure? addFailure;

  /// Подсказка пересчёта упаковки «2 кор = 12 шт» (INV-003).
  final ({int packs, Qty base})? unitHint;

  /// Время открытия из кэша (NFR-PERF-003; диагностика и тест).
  final Duration? cacheOpenTime;

  /// Роль зрителя (`catalogViewerRoleProvider`).
  final RoleCode? role;

  /// Режим остатков клиента-покупателя.
  final CustomerStockDisplay stockDisplay;

  /// Склад корзины (`cart_draft.warehouse_id`); `null` — склад по умолчанию.
  final String? cartWarehouseId;

  bool get isCustomer => role == RoleCode.customer;

  /// Колонки «Резерв», «Остаток» и «Все виды цен» (`catalog.prices.read.all`, 11 §4.4).
  bool get isSeniorStaff =>
      role == RoleCode.cashier || role == RoleCode.seniorSeller || role == RoleCode.admin || role == RoleCode.owner;

  /// Видимые варианты по `sortOrder`.
  List<Variant> get variants {
    final Product? p = product;
    if (p == null) return const <Variant>[];
    if (p.variants.isNotEmpty) return VariantAxes.visible(p.variants);
    // Служебный вариант без явного списка: из полей `ProductSummary` (EQ-ONEC-07).
    final String? id = p.summary.defaultVariantId;
    if (id == null) return const <Variant>[];
    return <Variant>[
      Variant(
        id: id,
        productId: p.id,
        isDefault: true,
        sku: p.summary.sku,
        price: p.summary.price,
        stock: p.summary.stock,
        stockByWarehouse: p.stockByWarehouse,
        images: const <ProductImageRef>[],
      ),
    ];
  }

  /// Выбранный вариант: явный выбор / `variantId` маршрута, иначе `isDefault`, иначе первый по
  /// `sortOrder` с остатком на складе корзины, иначе первый (02 SCR-14.4 «Открытие»).
  Variant? get variant {
    final List<Variant> list = variants;
    if (list.isEmpty) return null;
    final String? id = selectedVariantId;
    if (id != null) {
      for (final Variant v in list) {
        if (v.id == id) return v;
      }
    }
    for (final Variant v in list) {
      if (v.isDefault) return v;
    }
    for (final Variant v in list) {
      final StockBalance? s = v.stock;
      if (s != null && s.allowsAddToCart && (s.available == null || s.available!.milli > 0)) return v;
    }
    return list.first;
  }

  /// Оси выбора (пусто — один вариант, селектор скрыт).
  List<String> get axes => VariantAxes.keys(variants);

  /// Единицы карточки по `id`.
  Unit? unitById(String? id) {
    if (id == null) return null;
    final Product? p = product;
    if (p == null) return null;
    for (final Unit u in p.units) {
      if (u.id == id || u.code == id) return u;
    }
    final Unit? base = p.summary.baseUnit;
    return base != null && (base.id == id || base.code == id) ? base : null;
  }

  /// Базовая единица выбранного варианта.
  Unit? get baseUnit => unitById(variant?.unitId) ?? product?.summary.baseUnit;

  /// Упаковки выбранного варианта (общие для товара — `variantId = null`).
  List<Packaging> get packagings {
    final Product? p = product;
    final Variant? v = variant;
    if (p == null) return const <Packaging>[];
    return <Packaging>[
      for (final Packaging pk in p.packagings)
        if ((pk.variantId == null || pk.variantId == v?.id) && pk.factor.milli > 0) pk,
    ];
  }

  /// Выбранная упаковка.
  Packaging? get packaging {
    final String? id = packagingId;
    if (id == null) return null;
    for (final Packaging pk in packagings) {
      if (pk.id == id) return pk;
    }
    return null;
  }

  /// Остаток выбранного варианта на складе корзины; `null` — снимка нет (неизвестен).
  StockBalance? get stock {
    final Variant? v = variant;
    if (v == null) return null;
    if (v.stock != null) return v.stock;
    final String? wh = cartWarehouseId;
    if (wh == null) return null;
    for (final StockBalance s in v.stockByWarehouse) {
      if (s.warehouseId == wh) return s;
    }
    return null;
  }

  /// Остаток неизвестен (INV-052).
  bool get stockUnknown => stock == null || stock!.isUnknown;

  /// Нет на складе корзины (INV-023).
  bool get outOfStock {
    final StockBalance? s = stock;
    if (s == null || s.isUnknown) return false;
    if (s.stockLevel == StockLevel.out) return true;
    final Qty? a = s.available;
    return a != null && a.milli <= 0;
  }

  /// Цена выбранного варианта; нет цены варианта — цена товара (INV-013).
  Price? get price => variant?.price ?? product?.summary.price;

  /// Цена упаковки из 1С (`prices[].packagingId`), только для варианта по умолчанию — `Product.prices`
  /// относятся к нему (UI-14-021; клиент цену упаковки не вычисляет).
  Price? packPriceOf(Packaging pk) {
    final Product? p = product;
    final Price? base = price;
    if (p == null || base == null || variant?.id != p.defaultVariant?.id) return null;
    for (final Price pr in p.prices) {
      if (pr.packagingId == pk.id && pr.priceListId == base.priceListId) return pr;
    }
    return null;
  }

  /// Правила количества выбранного варианта.
  QtyRules get rules => QtyRules(
    precision: baseUnit?.qtyPrecision ?? 0,
    multiplicity: variant?.multiplicity,
    minQuantity: product?.minQuantity,
    available: stockUnknown ? null : stock?.available,
  );

  /// Текущее количество (база) — начальное, если не менялось.
  Qty get effectiveQuantity => quantity ?? rules.initialFor(packFactor: packaging?.factor);

  /// Нарушение правил текущего количества.
  QtyIssue? get quantityIssue => rules.validate(effectiveQuantity, packFactor: packaging?.factor);

  /// Количество в единицах строки (упаковки — целые, INV-006).
  Qty get lineQuantity {
    final Packaging? pk = packaging;
    if (pk == null) return effectiveQuantity;
    return Qty.units(QtyRules.toPacks(effectiveQuantity, pk.factor).packs);
  }

  /// Строка черновика выбранной пары уже есть.
  Qty? get inCartQuantity {
    final Variant? v = variant;
    return v == null ? null : inCart[cartLineKey(v.id, packagingId)];
  }

  /// Шаг степпера (база).
  Qty get step => rules.stepFor(packFactor: packaging?.factor);

  /// «+» доступна: известный остаток, следующий шаг не превышает доступного (INV-042).
  bool get canIncrement {
    if (stockUnknown || outOfStock) return false;
    final Qty next = effectiveQuantity + step;
    if (next.milli > QtyRules.maxInput.milli) return false;
    final Qty? avail = rules.available;
    return avail == null || next.milli <= avail.milli;
  }

  /// «−» доступна вне корзины до минимума (03 §9.20 disabled).
  bool get canDecrement => (effectiveQuantity - step).milli >= rules.initialFor(packFactor: packaging?.factor).milli;

  /// Сумма на CTA: цена упаковки 1С × упаковки или цена базовой единицы × количество (предварительно,
  /// истина — сервер, MNY-001).
  Money? get ctaSum {
    final Price? p = price;
    if (p == null) return null;
    final Packaging? pk = packaging;
    if (pk != null) {
      final Price? pp = packPriceOf(pk);
      if (pp != null) return pp.amount.times(QtyRules.toPacks(effectiveQuantity, pk.factor).packs);
    }
    return MoneyMath.lineTotal(p.amount, effectiveQuantity);
  }

  /// Состояние CTA.
  ProductCta get cta {
    if (role == RoleCode.owner || role == RoleCode.integration) return ProductCta.hidden;
    final Product? p = product;
    final Variant? v = variant;
    if (p == null || v == null) return ProductCta.unavailable;
    if (p.deletionMark || v.deletionMark) return ProductCta.unavailable;
    if (price == null) return ProductCta.unavailable;
    if (stockUnknown) return ProductCta.unavailable;
    if (outOfStock) return ProductCta.outOfStock;
    if (quantityIssue != null) return ProductCta.invalidQuantity;
    return inCartQuantity != null ? ProductCta.addMore : ProductCta.add;
  }

  /// Остаток на другом складе при «Нет на складе корзины» (INV-026, UI-14-032).
  StockBalance? get otherWarehouseStock {
    if (!outOfStock && !stockUnknown) return null;
    final Variant? v = variant;
    if (v == null) return null;
    final String? current = stock?.warehouseId ?? cartWarehouseId;
    StockBalance? best;
    for (final StockBalance s in v.stockByWarehouse) {
      final Qty? a = s.available;
      if (s.warehouseId == current || a == null || a.milli <= 0) continue;
      if (best == null || a.milli > best.available!.milli) best = s;
    }
    return best;
  }

  ProductDetailsState copyWith({
    ProductLoadStatus? status,
    Product? product,
    DataSource? source,
    Failure? failure,
    bool clearFailure = false,
    bool? refreshing,
    String? selectedVariantId,
    String? packagingId,
    bool clearPackaging = false,
    Qty? quantity,
    bool resetQuantity = false,
    Map<String, Qty>? inCart,
    bool? adding,
    int? addedCount,
    ({Qty quantity, String unitLabel})? lastAdded,
    Failure? addFailure,
    bool clearAddFailure = false,
    ({int packs, Qty base})? unitHint,
    bool clearUnitHint = false,
    Duration? cacheOpenTime,
    String? cartWarehouseId,
  }) => ProductDetailsState(
    status: status ?? this.status,
    product: product ?? this.product,
    source: source ?? this.source,
    failure: clearFailure ? null : (failure ?? this.failure),
    refreshing: refreshing ?? this.refreshing,
    selectedVariantId: selectedVariantId ?? this.selectedVariantId,
    packagingId: clearPackaging ? null : (packagingId ?? this.packagingId),
    quantity: resetQuantity ? null : (quantity ?? this.quantity),
    inCart: inCart ?? this.inCart,
    adding: adding ?? this.adding,
    addedCount: addedCount ?? this.addedCount,
    lastAdded: lastAdded ?? this.lastAdded,
    addFailure: clearAddFailure ? null : (addFailure ?? this.addFailure),
    unitHint: clearUnitHint ? null : (unitHint ?? this.unitHint),
    cacheOpenTime: cacheOpenTime ?? this.cacheOpenTime,
    role: role,
    stockDisplay: stockDisplay,
    cartWarehouseId: cartWarehouseId ?? this.cartWarehouseId,
  );
}

/// Карточка товара по параметрам маршрута.
final productDetailsProvider = NotifierProvider.autoDispose
    .family<ProductDetailsNotifier, ProductDetailsState, ProductDetailsArgs>(ProductDetailsNotifier.new);

/// Логика SCR-14.
final class ProductDetailsNotifier extends Notifier<ProductDetailsState> {
  ProductDetailsNotifier(this.args);

  final ProductDetailsArgs args;

  /// Минимальная длительность loading «В корзину» (защита от двойного клика, SCR-14.11).
  static const Duration addGuard = Duration(milliseconds: 300);

  CatalogRepository get _catalog => ref.read(catalogRepositoryProvider);

  @override
  ProductDetailsState build() {
    final ProductDetailsState initial = ProductDetailsState(
      selectedVariantId: args.variantId,
      quantity: _parseRouteQty(args.qty),
      role: ref.read(catalogViewerRoleProvider),
      stockDisplay: ref.read(customerStockDisplayProvider),
    );
    scheduleMicrotask(_load);
    return initial;
  }

  static Qty? _parseRouteQty(String? raw) {
    if (raw == null) return null;
    try {
      final Qty q = Qty.fromString(raw);
      return q.milli > 0 ? q : null;
    } on Object {
      return null;
    }
  }

  /// Повторить загрузку («Повторить» в `ErrorState`).
  Future<void> retry() => _load();

  Future<void> _load() async {
    if (!ref.mounted) return;
    final CartDraftRepository? cart = _cartOrNull();
    final String? warehouseId = cart == null ? null : (await _guard(cart.warehouseId)).valueOrNull;
    if (!ref.mounted) return;
    state = state.copyWith(cartWarehouseId: warehouseId);
    // 1) Кэш drift (≤ 200 мс, NFR-PERF-003).
    if (state.product == null) {
      final Stopwatch sw = Stopwatch()..start();
      final Result<Product?> cached = await _guard(
        () => _catalog.cachedProduct(args.productId, warehouseId: warehouseId),
      );
      sw.stop();
      if (!ref.mounted) return;
      final Product? p = cached.valueOrNull;
      if (p != null) {
        state = state.copyWith(
          status: ProductLoadStatus.ready,
          product: p,
          source: DataSource.cache,
          cacheOpenTime: sw.elapsed,
          refreshing: true,
        );
        unawaited(_refreshCart());
      }
    }
    // 2) Сервер: `GET /catalog/products/{id}?warehouseId=&include=…` (priceListId не передаётся —
    //    вид цены выбирает сервер, AC-UI-14-018).
    state = state.copyWith(refreshing: true, clearFailure: true);
    final Result<Product> fresh = await _guard(() => _catalog.product(args.productId, warehouseId: warehouseId));
    if (!ref.mounted) return;
    switch (fresh) {
      case Success<Product>(:final Product value):
        state = state.copyWith(
          status: ProductLoadStatus.ready,
          product: value,
          source: DataSource.network,
          refreshing: false,
          clearFailure: true,
        );
        unawaited(_refreshCart());
      case FailureResult<Product>(:final Failure failure):
        if (_isNotFound(failure)) {
          state = state.copyWith(status: ProductLoadStatus.notFound, refreshing: false, failure: failure);
        } else if (state.product != null) {
          state = state.copyWith(refreshing: false, failure: failure);
        } else {
          state = state.copyWith(status: ProductLoadStatus.error, refreshing: false, failure: failure);
        }
    }
  }

  static bool _isNotFound(Failure f) =>
      f is ServerFailure && (f.status == 404 || f.problemCode == ProblemCode.notFound);

  /// Черновик корзины; `null` — порт не подключён (тесты маршрутов, до входа).
  CartDraftRepository? _cartOrNull() {
    try {
      return ref.read(cartDraftRepositoryProvider);
    } on Object {
      return null;
    }
  }

  /// Вызов порта с защитой от исключений реализации (ошибка — `UnknownFailure`, экран не зависает).
  static Future<Result<T>> _guard<T>(Future<Result<T>> Function() call) async {
    try {
      return await call();
    } on Object catch (e) {
      return FailureResult<T>(UnknownFailure(cause: e));
    }
  }

  /// Перечитать строки черновика корзины (после SCR-15).
  Future<void> reloadCart() => _refreshCart();

  Future<void> _refreshCart() async {
    final CartDraftRepository? cart = _cartOrNull();
    if (cart == null) return;
    final List<CartDraftLine>? lines = (await _guard(cart.lines)).valueOrNull;
    if (lines == null || !ref.mounted) return;
    state = state.copyWith(
      inCart: <String, Qty>{for (final CartDraftLine l in lines) cartLineKey(l.variantId, l.packagingId): l.quantity},
    );
  }

  /// Выбор варианта (миниатюра варианта, SCR-15): количество и единица — к шагу (SCR-14.11).
  void selectVariant(String variantId) {
    if (state.variant?.id == variantId) return;
    state = state.copyWith(
      selectedVariantId: variantId,
      clearPackaging: true,
      resetQuantity: true,
      clearUnitHint: true,
    );
  }

  /// Выбор значения оси (UI-14-008).
  void selectAxisValue(String axis, String value) {
    final Variant? next = VariantAxes.resolve(state.variants, state.axes, state.variant, axis, value);
    if (next != null) selectVariant(next.id);
  }

  /// Смена единицы/упаковки с сохранением базового количества (INV-003): нецелое число упаковок —
  /// ближайшее большее + подсказка «2 кор = 12 шт».
  void selectPackaging(String? packagingId) {
    if (packagingId == state.packagingId) return;
    final Qty base = state.effectiveQuantity;
    Packaging? pk;
    for (final Packaging p in state.packagings) {
      if (p.id == packagingId) pk = p;
    }
    if (pk == null) {
      state = state.copyWith(clearPackaging: true, quantity: base, clearUnitHint: true);
      return;
    }
    final ({int packs, bool exact}) r = QtyRules.toPacks(base, pk.factor);
    final int packs = r.packs < 1 ? 1 : r.packs;
    final Qty newBase = Qty(packs * pk.factor.milli);
    state = state.copyWith(
      packagingId: pk.id,
      quantity: newBase,
      unitHint: r.exact && r.packs >= 1 ? null : (packs: packs, base: newBase),
      clearUnitHint: r.exact && r.packs >= 1,
    );
  }

  /// «+» на шаг.
  void increment() {
    if (!state.canIncrement) return;
    state = state.copyWith(quantity: state.effectiveQuantity + state.step, clearUnitHint: true, clearAddFailure: true);
  }

  /// «−» на шаг (не ниже начального).
  void decrement() {
    if (!state.canDecrement) return;
    state = state.copyWith(quantity: state.effectiveQuantity - state.step, clearUnitHint: true, clearAddFailure: true);
  }

  /// Значение из нампада (контекст `productCard`: только подставляется в степпер, SCR-16.4).
  void setQuantity(Qty base, {String? packagingId, bool keepPackaging = false}) {
    if (keepPackaging) {
      state = state.copyWith(quantity: base, clearUnitHint: true, clearAddFailure: true);
      return;
    }
    state = packagingId == null
        ? state.copyWith(quantity: base, clearPackaging: true, clearUnitHint: true, clearAddFailure: true)
        : state.copyWith(quantity: base, packagingId: packagingId, clearUnitHint: true, clearAddFailure: true);
  }

  /// «В корзину» / «Добавить ещё»: строка черновика создаётся или увеличивается (CART-002);
  /// повторный вызов во время loading игнорируется (AC-UI-14-012).
  Future<bool> add() async {
    final ProductDetailsState s = state;
    final ProductCta cta = s.cta;
    if (s.adding || (cta != ProductCta.add && cta != ProductCta.addMore)) return false;
    final Variant v = s.variant!;
    final CartDraftRepository? cart = _cartOrNull();
    if (cart == null) return false;
    state = s.copyWith(adding: true, clearAddFailure: true);
    final DateTime started = ref.read(clockProvider).nowUtc();
    final Packaging? pk = s.packaging;
    final Qty lineQty = s.lineQuantity;
    final Price? linePrice = pk == null ? s.price : (s.packPriceOf(pk) ?? s.price);
    final Result<CartDraftLine> r = await _guard(
      () => cart.add(
        CartDraftAdd(
          variantId: v.id,
          packagingId: pk?.id,
          quantity: lineQty,
          priceSnapshot: linePrice?.amount,
          stockSnapshot: s.stock?.available,
        ),
      ),
    );
    final Duration spent = ref.read(clockProvider).nowUtc().difference(started);
    if (spent < addGuard) await Future<void>.delayed(addGuard - spent);
    if (!ref.mounted) return false;
    switch (r) {
      case Success<CartDraftLine>(:final CartDraftLine value):
        final String label = pk == null ? (s.baseUnit?.label ?? '') : (pk.name ?? s.unitById(pk.unitId)?.label ?? '');
        state = state.copyWith(
          adding: false,
          inCart: <String, Qty>{...state.inCart, cartLineKey(value.variantId, value.packagingId): value.quantity},
          addedCount: state.addedCount + 1,
          lastAdded: (quantity: lineQty, unitLabel: label),
          resetQuantity: true,
          clearUnitHint: true,
        );
        return true;
      case FailureResult<CartDraftLine>(:final Failure failure):
        state = state.copyWith(adding: false, addFailure: failure);
        return false;
    }
  }
}
