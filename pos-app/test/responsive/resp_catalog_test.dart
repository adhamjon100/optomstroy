// T-UI-117: прогон адаптивности каталога — SCR-10 «Каталог» и SCR-12 «Категория» по данным прототипа (фото макета),
// SCR-11 «Поиск», SCR-13 «Фильтры», SCR-14 «Карточка товара», SCR-12 в режиме `customer`, SCR-50 «Главная клиента» —
// по окнам 360…2560 (портрет и ландшафт, окна масштаба страницы веб-демо) при масштабе текста 1 и 1,3: без
// переполнения и недоступных элементов (03 §8.8; указание владельца 2026-11-18, 15 §5.8 (3)). Колонки сеток товаров
// проверяет T-CAT-038 (catalog_grid_limits_test.dart); здесь — весь экран. Лист «Все категории» (`AllCategoriesGrid`,
// 02 SCR-12 UI-12-006) — с длинными названиями («Водоснабжение», «Электроинструменты», «Строительные материалы»):
// подпись плитки не переносится внутри слова (находка `midword` у `CategoryTile` блокирует), колонок меньше, если слово
// иначе не помещается, высота плитки растёт с масштабом текста (03 §9.10; указание владельца 2026-11-18).
import 'dart:io';

import 'package:alchemist/alchemist.dart' show precacheImages;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' show RoleCode;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/entities/search.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_filters_screen.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_screen.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_search_screen.dart';
import 'package:optomstroy/features/catalog/presentation/screens/category_screen.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/all_categories_sheet.dart';
import 'package:optomstroy/features/product_details/presentation/screens/product_details_screen.dart';

import '../features/home/support/home_fakes.dart';
import '../features/product_details/product_fixtures.dart' as pf;
import '../support/responsive_audit.dart';

final Map<String, MemoryImage> _photos = <String, MemoryImage>{};

String _photoUrl(String name) => 'http://design.test/photos/$name.png';

ImageProvider<Object> _designImage(String url) {
  final String name = Uri.parse(url).pathSegments.last.replaceAll('.png', '');
  return _photos.putIfAbsent(name, () => MemoryImage(File('../demo/catalog/photos/$name.png').readAsBytesSync()));
}

const List<(String, String, int, int, StockLevel, String)> _designProducts =
    <(String, String, int, int, StockLevel, String)>[
      ('SB200', 'Биде напольное Sanita', 10450, 7, StockLevel.inStock, 'p-bidet'),
      ('AL17070', 'Ванна акриловая AquaLine 170x70', 12950, 6, StockLevel.inStock, 'p-bath'),
      ('RV9090', 'Душевая кабина River 90x90', 18600, 4, StockLevel.inStock, 'p-shower'),
      ('GD112', 'Инсталляция для унитаза Geberit Duofix', 14320, 9, StockLevel.inStock, 'p-install'),
      ('SP300', 'Писсуар подвесной Sanita Pro', 6780, 3, StockLevel.low, 'p-urinal'),
      ('PD9090', 'Поддон акриловый 90x90', 4300, 11, StockLevel.inStock, 'p-tray'),
      ('PS5080', 'Полотенцесушитель водяной 50x80', 5600, 13, StockLevel.inStock, 'p-towel'),
      ('KVM021', 'Раковина накладная Kirovit KVM-021', 3120, 15, StockLevel.inStock, 'p-sink'),
      ('SF450', 'Сифон для раковины бутылочный хром', 1250, 58, StockLevel.inStock, 'p-siphon'),
      ('KT110', 'Тройник канализационный 110 мм', 180, 340, StockLevel.inStock, 'p-pipes'),
      ('TR600', 'Тумба с раковиной 60 см белая', 15900, 0, StockLevel.out, 'p-vanity'),
      ('SL1001', 'Унитаз-компакт Sanita Luxe Classic', 8450, 24, StockLevel.inStock, 'p-toilet'),
    ];

const List<String> _designSubPhotos = <String>[
  'sub-toilets',
  'sub-sinks',
  'sub-baths',
  'sub-showers',
  'sub-install',
  'sub-bidet',
  'sub-urinals',
  'sub-siphons',
  'sub-pipes',
];

CatalogHarness _designHarness({RoleCode role = RoleCode.seller}) {
  final List<ProductSummary> items = <ProductSummary>[
    for (final (String sku, String name, int som, int qty, StockLevel level, String photo) in _designProducts)
      ProductSummary(
        id: 'p-${sku.toLowerCase()}',
        name: name,
        sku: sku,
        categoryId: 'plumbing',
        defaultVariantId: 'v-${sku.toLowerCase()}',
        baseUnit: kPiece,
        primaryImage: ProductImageRef(sha256: photo, thumbUrl: _photoUrl(photo), cardUrl: _photoUrl(photo)),
        price: Price(priceListId: 'pl-retail', priceListName: 'Розничная', amount: Money.som(som)),
        stock: StockBalance(
          variantId: 'v-${sku.toLowerCase()}',
          warehouseId: 'w-main',
          stockLevel: level,
          available: Qty.units(qty),
          asOf: kNow.subtract(const Duration(minutes: 5)),
        ),
      ),
  ];
  final FakeCatalogRepository repo = FakeCatalogRepository(
    tree: designCategoryTree(
      imageUrl: (String id) => _photoUrl('cat-$id'),
      subImageUrl: (int i) => _photoUrl(_designSubPhotos[i]),
    ),
  );
  repo.networkPages.add(Success<CatalogPage<ProductSummary>>(page(items, total: items.length)));
  return CatalogHarness(
    catalog: repo,
    shelf: FakeShelfPort(favorites: <String>{'p-sl1001'}),
    unread: 2,
    role: role,
  );
}

CatalogHarness _searchHarness() {
  final FakeCatalogRepository repo = FakeCatalogRepository();
  final FakeSearchRepository search = FakeSearchRepository()
    ..results = (String q) => SearchResult(
      query: q,
      page: page(<ProductSummary>[
        product(1, name: 'Смеситель для кухни Frap F4252 хром', sku: 'F4252-CR', matchType: MatchType.sku),
        product(7, name: 'Смеситель Frap F4252-BK чёрный', sku: 'F4252-BK', priceSom: 2550, matchType: MatchType.sku),
        product(8, name: 'Картридж для смесителя F4252', sku: 'K-40', priceSom: 450, matchType: MatchType.fts),
      ]),
      matchTypes: const SearchMatchCounts(sku: 2, fts: 2),
    );
  return CatalogHarness(catalog: repo, search: search);
}

const CatalogFacets _facets = CatalogFacets(
  brands: <FacetValue>[
    FacetValue(value: 'Frap', count: 12),
    FacetValue(value: 'Grohe', count: 3),
  ],
  attrs: <String, List<FacetValue>>{
    'color': <FacetValue>[FacetValue(value: 'хром', count: 9)],
  },
);

CatalogHarness _filtersHarness() {
  final FakeCatalogRepository repo = FakeCatalogRepository();
  repo.networkPages.add(Success<CatalogPage<ProductSummary>>(page(products(1), total: 124, facets: _facets)));
  return CatalogHarness(catalog: repo);
}

Widget _product(Size size) {
  final Product p = pf.multiVariantProduct();
  return ProviderScope(
    overrides: pf.productOverrides(
      catalog: pf.FakeCatalogRepository(cached: p, network: Success<Product>(p)),
      role: RoleCode.seller,
    ),
    child: MaterialApp(
      theme: AppTheme.light(),
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      debugShowCheckedModeBanner: false,
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(size: size, disableAnimations: true, padding: EdgeInsets.zero),
        child: child!,
      ),
      home: Material(
        color: DsColors.lightB.background,
        child: const ProductDetailsScreen(productId: 'p-1'),
      ),
    ),
  );
}

/// Корни с длинными названиями (одно слово шире плитки 101 при 360 и тексте 1,3).
const List<String> _longRoots = <String>[
  'Водоснабжение',
  'Электроинструменты',
  'Строительные материалы',
  'Смесители',
  'Санфаянс',
  'Трубы и фитинги',
];

const Key _openSheetKey = ValueKey<String>('resp-open-all-categories');

Widget _allCategories(Size size) => catalogApp(
  CatalogHarness(
    catalog: FakeCatalogRepository(
      tree: CategoryTree.fromFlat(<Category>[
        for (int i = 0; i < _longRoots.length; i++)
          Category(id: 'long-$i', name: _longRoots[i], productCount: 10 + i, sortOrder: i),
      ]),
    ),
  ),
  home: Builder(
    builder: (BuildContext context) => Scaffold(
      body: Center(
        child: TextButton(
          key: _openSheetKey,
          onPressed: () => showAllCategoriesSheet(context),
          child: const Text('Все категории'),
        ),
      ),
    ),
  ),
  size: size,
);

Future<void> _openSheet(WidgetTester tester, Size size) async {
  await respFrames(tester);
  await tester.tap(find.byKey(_openSheetKey));
  await respFrames(tester);
}

Future<void> _withPhotos(WidgetTester tester, Size size) async {
  await respFrames(tester);
  await precacheImages(tester);
  for (int i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  setUpAll(() => EditableText.debugDeterministicCursor = true);
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  final Map<String, (RespBuild, RespSettle)> scenes = <String, (RespBuild, RespSettle)>{
    'scr10_catalog': (
      (Size s, double _) => catalogApp(
        _designHarness(),
        home: const ProductImageScope(providerFor: _designImage, child: CatalogScreen()),
        size: s,
      ),
      _withPhotos,
    ),
    'scr12_category': (
      (Size s, double _) => catalogApp(
        _designHarness(),
        home: const ProductImageScope(
          providerFor: _designImage,
          child: CategoryScreen(categoryId: 'plumbing'),
        ),
        size: s,
      ),
      _withPhotos,
    ),
    'scr12_customer': (
      (Size s, double _) => catalogApp(
        _designHarness(role: RoleCode.customer),
        home: const ProductImageScope(
          providerFor: _designImage,
          child: CategoryScreen(categoryId: 'plumbing'),
        ),
        size: s,
      ),
      _withPhotos,
    ),
    'scr11_search': (
      (Size s, double _) => catalogApp(
        _searchHarness(),
        home: const CatalogSearchScreen(q: 'F4252'),
        size: s,
      ),
      respFrames,
    ),
    'scr13_filters': (
      (Size s, double _) => catalogApp(_filtersHarness(), home: const CatalogFiltersScreen(), size: s),
      respFrames,
    ),
    'scr14_product': ((Size s, double _) => _product(s), respFrames),
    'scr50_home': ((Size s, double _) => homeApp(HomeHarness(cartCount: 2), size: s), _withPhotos),
    'scr12_all_categories': ((Size s, double _) => _allCategories(s), _openSheet),
  };

  for (final MapEntry<String, (RespBuild, RespSettle)> scene in scenes.entries) {
    testWidgets('T-UI-117 ${scene.key}: окна 360…2560 × текст 1 / 1,3', (WidgetTester tester) async {
      final RespAudit audit = RespAudit(scene.key);
      await audit.run(tester, scene.value.$1, settle: scene.value.$2);
      audit.expectNoBlocking();
    });
  }
}
