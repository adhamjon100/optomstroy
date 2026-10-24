// Синтетические данные и фейки для тестов SCR-14…SCR-16 (RM-E-008). Реальные данные клиентов
// не используются; всё — на фикстурах, не реальная интеграция с 1С.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' show CustomerStockDisplay, RoleCode;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_repository.dart';
import 'package:optomstroy/features/product_details/presentation/screens/product_details_screen.dart';
import 'package:optomstroy/features/product_details/product_details_providers.dart';

const Unit pcs = Unit(id: 'u-pcs', code: '796', name: 'штука', shortName: 'шт', qtyPrecision: 0);
const Unit box = Unit(id: 'u-box', code: 'box', name: 'коробка', shortName: 'кор', qtyPrecision: 0);

/// Фиксированный момент снимка остатков (свежий относительно `now` теста не проверяется).
DateTime freshAsOf() => DateTime.now().toUtc();

StockBalance stock(
  String variantId, {
  String wh = 'wh-main',
  String name = 'Основной склад',
  int? available = 24,
  int? reserved,
  int? quantity,
  StockLevel level = StockLevel.inStock,
  DateTime? at,
  bool noTime = false,
}) => StockBalance(
  variantId: variantId,
  warehouseId: wh,
  warehouseName: name,
  available: available == null ? null : Qty.units(available),
  reserved: reserved == null ? null : Qty.units(reserved),
  quantity: quantity == null ? null : Qty.units(quantity),
  stockLevel: level,
  asOf: noTime ? null : (at ?? freshAsOf()),
);

Price price(int som, {String list = 'pl-retail', String name = 'Розничная', String? packagingId}) =>
    Price(priceListId: list, priceListName: name, amount: Money.som(som), packagingId: packagingId);

Variant variant(
  String id, {
  bool isDefault = false,
  String? sku,
  Map<String, String> attributes = const <String, String>{},
  Price? price,
  StockBalance? stock,
  List<StockBalance>? byWarehouse,
  Qty? multiplicity,
  int sort = 0,
}) => Variant(
  id: id,
  productId: 'p-1',
  isDefault: isDefault,
  sku: sku,
  attributes: attributes,
  price: price,
  stock: stock,
  stockByWarehouse: byWarehouse ?? <StockBalance>[?stock],
  multiplicity: multiplicity,
  unitId: pcs.id,
  sortOrder: sort,
);

/// Товар с одним вариантом (смеситель), остаток 24 шт на складе корзины и 3 шт на втором.
Product singleVariantProduct({
  StockBalance? stockOverride,
  bool unknownStock = false,
  Qty? multiplicity,
  Qty? minQuantity,
  bool noPrice = false,
  List<Packaging> packagings = const <Packaging>[],
  List<Price> extraPrices = const <Price>[],
  String? description,
  Qty? availableTotal,
  bool deletionMark = false,
  String? categoryId,
}) {
  final StockBalance? st = unknownStock ? null : (stockOverride ?? stock('v-1', reserved: 2, quantity: 26));
  final Price? pr = noPrice ? null : price(2850);
  final Variant v = variant(
    'v-1',
    isDefault: true,
    sku: 'L74103-BK',
    price: pr,
    stock: st,
    byWarehouse: <StockBalance>[
      ?st,
      if (!unknownStock) stock('v-1', wh: 'wh-2', name: 'Склад №2', available: 3, reserved: 0, quantity: 3),
    ],
    multiplicity: multiplicity,
  );
  return Product(
    summary: ProductSummary(
      id: 'p-1',
      name: 'Смеситель для кухни Ledeme L74103',
      sku: 'L74103-BK',
      categoryId: categoryId,
      brand: 'Ledeme',
      defaultVariantId: 'v-1',
      baseUnit: pcs,
      price: pr,
      stock: st,
    ),
    description: description,
    attributes: const <String, String>{'Бренд': 'Ledeme', 'Материал': 'латунь', 'Цвет': 'чёрный матовый'},
    variants: <Variant>[v],
    packagings: packagings,
    units: const <Unit>[pcs, box],
    minQuantity: minQuantity,
    availableTotal: availableTotal,
    onecCode: '00-00012345',
    prices: <Price>[?pr, ...extraPrices],
    deletionMark: deletionMark,
  );
}

/// Товар с тремя вариантами по оси «Цвет».
Product multiVariantProduct() {
  final List<Variant> variants = <Variant>[
    variant(
      'v-cr',
      isDefault: true,
      sku: 'F4252-CR',
      attributes: const <String, String>{'Цвет': 'Хром', 'Материал': 'латунь'},
      price: price(2850),
      stock: stock('v-cr', available: 12),
    ),
    variant(
      'v-bk',
      sku: 'F4252-BK',
      attributes: const <String, String>{'Цвет': 'Чёрный матовый', 'Материал': 'латунь'},
      price: price(3100),
      stock: stock('v-bk', available: 0, level: StockLevel.out),
      sort: 1,
    ),
    variant(
      'v-wh',
      sku: 'F4252-WH',
      attributes: const <String, String>{'Цвет': 'Белый', 'Материал': 'латунь'},
      price: price(2950),
      stock: stock('v-wh', available: 3, level: StockLevel.low),
      sort: 2,
    ),
  ];
  return Product(
    summary: ProductSummary(
      id: 'p-1',
      name: 'Смеситель для ванны Frap F4252',
      sku: 'F4252-CR',
      hasVariants: true,
      defaultVariantId: 'v-cr',
      baseUnit: pcs,
      price: price(2850),
      stock: stock('v-cr', available: 12),
      variantCount: 3,
    ),
    attributes: const <String, String>{'Бренд': 'Frap'},
    variants: variants,
    units: const <Unit>[pcs],
  );
}

/// Фейк каталога: кэш и сеть отдают заданные значения.
final class FakeCatalogRepository extends Fake implements CatalogRepository {
  FakeCatalogRepository({this.cached, Result<Product>? network, this.tree})
    : network = network ?? const FailureResult<Product>(NetworkFailure(NetworkFailureKind.offline));

  Product? cached;

  /// Дерево категорий кэша (шапка SCR-14: название категории, крошки); `null` — кэша нет.
  CategoryTree? tree;

  @override
  Future<Result<CategoryTree>> cachedCategories() async => Success<CategoryTree>(tree ?? const CategoryTree(roots: []));

  @override
  Future<Result<CategoryTree>> categories({
    String? parentId,
    int? depth,
    bool includeEmpty = false,
    bool inStockOnly = false,
  }) async => const FailureResult<CategoryTree>(NetworkFailure(NetworkFailureKind.offline));

  Result<Product> network;
  final List<({String id, String? warehouseId, String? priceListId})> productCalls =
      <({String id, String? warehouseId, String? priceListId})>[];

  @override
  Future<Result<Product?>> cachedProduct(String productId, {String? warehouseId, String? priceListId}) async =>
      Success<Product?>(cached);

  @override
  Future<Result<Product>> product(
    String productId, {
    String? warehouseId,
    String? priceListId,
    Set<ProductInclude> include = ProductInclude.all,
  }) async {
    productCalls.add((id: productId, warehouseId: warehouseId, priceListId: priceListId));
    return network;
  }
}

/// Фейк черновика корзины в памяти.
final class FakeCartDraftRepository implements CartDraftRepository {
  final List<CartDraftLine> items = <CartDraftLine>[];
  final List<CartDraftAdd> adds = <CartDraftAdd>[];
  final StreamController<List<CartDraftLine>> _changes = StreamController<List<CartDraftLine>>.broadcast();

  @override
  Future<Result<CartDraftLine>> add(CartDraftAdd add) async {
    adds.add(add);
    final int i = items.indexWhere(
      (CartDraftLine l) => l.variantId == add.variantId && l.packagingId == add.packagingId,
    );
    final CartDraftLine line = CartDraftLine(
      localItemId: 'li-${items.length}',
      cartId: 'cart-1',
      variantId: add.variantId,
      packagingId: add.packagingId,
      quantity: i < 0 ? add.quantity : items[i].quantity + add.quantity,
      lineNo: i < 0 ? items.length + 1 : items[i].lineNo,
    );
    if (i < 0) {
      items.add(line);
    } else {
      items[i] = line;
    }
    _changes.add(List<CartDraftLine>.of(items));
    return Success<CartDraftLine>(line);
  }

  @override
  Future<Result<CartDraftLine?>> line(String variantId, {String? packagingId}) async => Success<CartDraftLine?>(
    items.where((CartDraftLine l) => l.variantId == variantId && l.packagingId == packagingId).firstOrNull,
  );

  @override
  Future<Result<List<CartDraftLine>>> lines() async => Success<List<CartDraftLine>>(List<CartDraftLine>.of(items));

  @override
  Future<Result<CartDraftLine?>> setQuantity(String variantId, {String? packagingId, required Qty quantity}) async =>
      const Success<CartDraftLine?>(null);

  @override
  Stream<List<CartDraftLine>> watchLines() => _changes.stream;

  @override
  Future<Result<String?>> warehouseId() async => const Success<String?>('wh-main');
}

/// Переопределения провайдеров для SCR-14.
List<Override> productOverrides({
  required CatalogRepository catalog,
  CartDraftRepository? cart,
  RoleCode role = RoleCode.seller,
  CustomerStockDisplay display = CustomerStockDisplay.status,
}) => <Override>[
  catalogRepositoryProvider.overrideWithValue(catalog),
  cartDraftRepositoryProvider.overrideWithValue(cart ?? FakeCartDraftRepository()),
  catalogViewerRoleProvider.overrideWithValue(role),
  customerStockDisplayProvider.overrideWithValue(display),
  productImageBaseUriProvider.overrideWithValue(Uri.parse('https://pos.test/api/v1')),
];

/// Размеры окон по классам (D-18).
const Size compactWindow = Size(390, 844);
const Size mediumWindow = Size(800, 1000);
const Size expandedWindow = Size(1280, 900);

/// SCR-14 в окне [size] с переопределениями.
Future<void> pumpProduct(
  WidgetTester tester, {
  required List<Override> overrides,
  Size size = compactWindow,
  String productId = 'p-1',
  String? variantId,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        debugShowCheckedModeBanner: false,
        builder: (BuildContext context, Widget? child) =>
            MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
        home: ProductDetailsScreen(productId: productId, variantId: variantId),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}
