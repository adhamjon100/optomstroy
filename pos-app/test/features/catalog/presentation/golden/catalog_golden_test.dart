// T-CAT-018, T-CAT-021 (golden): SCR-10 «Каталог», SCR-11 «Результаты поиска» и SCR-12 «Категория» на трёх
// брейкпоинтах compact / medium / expanded (D-18). Раскладка medium+ — по прототипу «точь-в-точь» (ADR-112,
// ADR-114): шапка 69 «☰ · логотип · поиск до 680 · SyncIndicator · кнопка-итог «Корзина» · часы · колокольчик ·
// аватар», колонка «Каталог» (19/700) только с плитками корневых категорий (число — в подсказке), заголовок раздела
// 30/800, лента подкатегорий с «Все товары» (всегда; во «Все товары» — корни), одна строка управления «Новые ·
// Избранные · Недавние · Найдено: N | Сетка/Список/Компакт · сортировка · Фильтры», сетка без предела колонок с
// зазором 14 и ячейкой 340 / 360, деньги «2 350,00 сом»; постоянной CP нет — корзина открывается drawer 420 по
// кнопке-итогу (в эталонах закрыт). compact — без изменений, кроме формата денег.
// AC-UI-10-001/030. Палитра B по прототипу (ADR-111, ADR-114), reduce-motion, синтетические данные.
//
// Сцена прототипа `catalog_design_expanded_1440` (ADR-114, T-UI-116): окно 1440×900, дерево из 8 корней макета с
// картинками, «Сантехника» с 9 подкатегориями ленты и 12 товарами макета с фото и состояниями наличия, SL1001 — в
// избранном; картинки — тестовые данные демо `demo/catalog/photos` (копии `visual/prototype/assets`; сервер отдаёт
// их как данные — в приложение не встраиваются). Эталон для сверки с прототипом (design-compare, WP-QA).
//
// Обновить эталоны: flutter test test/features/catalog/presentation/golden --update-goldens
import 'dart:async';
import 'dart:io';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/components/top_app_bar_cart_button.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/entities/search.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_screen.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_search_screen.dart';
import 'package:optomstroy/features/catalog/presentation/screens/category_screen.dart';
import 'package:optomstroy/features/sync_status/presentation/widgets/sync_connected_widgets.dart';

import '../support/catalog_fakes.dart';

const Map<String, Size> _windows = <String, Size>{
  'compact': Size(390, 844),
  'medium': Size(820, 1000),
  'expanded': Size(1366, 900),
};

List<ProductSummary> _items() => <ProductSummary>[
  product(1, name: 'Смеситель для кухни Frap F4252 хром', sku: 'F4252-CR', priceSom: 2350, available: 24),
  product(
    2,
    name: 'Смеситель для ванной Grohe Eurosmart',
    sku: 'GR-33265',
    priceSom: 7850,
    level: StockLevel.low,
    available: 3,
  ),
  product(3, name: 'Унитаз-компакт Santek Бриз с сиденьем', sku: 'SN-1WH302', priceSom: 9400, level: StockLevel.out),
  product(
    4,
    name: 'Смеситель Ledeme L74103 для раковины',
    sku: 'L74103',
    priceSom: 1650,
    hasVariants: true,
    variantCount: 3,
  ),
  product(5, name: 'Труба полипропиленовая PN20 20 мм', noSku: true, priceSom: 95, available: 860),
  product(6, name: 'Сифон для раковины Ani Plast', sku: 'C1010', priceSom: 320, noStock: true),
];

CatalogHarness _harness() {
  final FakeCatalogRepository repo = FakeCatalogRepository();
  repo.networkPages.add(Success<CatalogPage<ProductSummary>>(page(_items(), total: 124)));
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
  final FakeShelfPort shelf = FakeShelfPort(
    favorites: <String>{'p1', 'p2'},
    recent: <RecentProduct>[
      RecentProduct(
        product: product(2, name: 'Смеситель для ванной Grohe Eurosmart'),
        viewedAt: kNow,
      ),
      RecentProduct(
        product: product(5, name: 'Труба полипропиленовая PN20 20 мм'),
        viewedAt: kNow,
      ),
    ],
  );
  return CatalogHarness(
    catalog: repo,
    search: search,
    shelf: shelf,
    // `SyncIndicator` шапки — как в корне приложения (AC-UI-10-001, AC-UI-10-030): compact — иконка,
    // medium/expanded — иконка и время.
    extra: <Override>[
      catalogSyncIndicatorProvider.overrideWithValue((BuildContext context) => const ConnectedSyncIndicator()),
      // «обновляем…» без метки времени: подпись «обновлено HH:MM» зависит от часового пояса и даты машины
      // (`dsTimeLabel` — локальное время устройства), эталон был бы нестабильным.
      syncIndicatorProvider.overrideWithValue(const SyncIndicatorInfo(status: SyncIndicatorStatus.syncing)),
    ],
  );
}

/// Фото тестовых данных демо по имени (`demo/catalog/photos/{name}.png`; путь — от `pos-app`, где идёт `flutter test`).
final Map<String, MemoryImage> _photos = <String, MemoryImage>{};

/// Адрес картинки макета (как данные сервера).
String _photoUrl(String name) => 'http://design.test/photos/$name.png';

/// Провайдер картинки по адресу [_photoUrl].
ImageProvider<Object> _designImage(String url) {
  final String name = Uri.parse(url).pathSegments.last.replaceAll('.png', '');
  return _photos.putIfAbsent(name, () => MemoryImage(File('../demo/catalog/photos/$name.png').readAsBytesSync()));
}

/// 12 товаров «Сантехники» прототипа (`P`; по названию А–Я, как в макете): артикул, название, цена (сом), остаток,
/// уровень, фото.
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

/// Фото подкатегорий «Сантехники» (порядок — [kDesignPlumbingSubs]).
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

CatalogHarness _designHarness() {
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
    extra: <Override>[
      // Пустая корзина прототипа: «Корзина» · «0,00 сом».
      catalogCartButtonProvider.overrideWithValue(
        (BuildContext context) => TopAppBarCartButton(
          label: 'Корзина',
          count: 0,
          totalText: PriceText.format(Money.zero),
          semanticLabel: 'Открыть корзину, пусто',
          onTap: () {},
        ),
      ),
    ],
  );
}

/// Сцена прототипа: сначала данные (дерево и список приходят из фейков за несколько кадров), затем декодирование
/// настоящих картинок (`precacheImages` — вне fake async) и кадры после него.
Future<void> _prepareDesign(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  await precacheImages(tester);
  for (int i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _prepare(WidgetTester tester) async {
  await precacheImages(tester);
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  setUpAll(() => EditableText.debugDeterministicCursor = true);
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  final Map<String, Widget> scenes = <String, Widget>{
    'scr10_catalog': const CatalogScreen(),
    'scr11_search': const CatalogSearchScreen(q: 'F4252'),
    // Подкатегория «Для кухни» категории «Смесители»: лента «Все · Для кухни · Для ванной», выбрана текущая.
    'scr12_category': const CategoryScreen(categoryId: 'c-mix-kitchen'),
  };
  // Цены в эталонах — целые тыйыны (D-19).
  assert(Money.som(2350).tyiyn == 235000, 'деньги — int');

  // Прототип «точь-в-точь» (ADR-114, T-UI-116): «Сантехника» при 1440×900, как снимок 1440x900-01-initial.
  const Size design = Size(1440, 900);
  unawaited(
    goldenTest(
      'design · expanded 1440',
      fileName: 'catalog_design_expanded_1440',
      constraints: BoxConstraints.tight(design),
      pumpBeforeTest: _prepareDesign,
      builder: () => SizedBox(
        width: design.width,
        height: design.height,
        child: catalogApp(
          _designHarness(),
          home: const ProductImageScope(
            providerFor: _designImage,
            child: CategoryScreen(categoryId: 'plumbing'),
          ),
          size: design,
        ),
      ),
    ),
  );

  for (final MapEntry<String, Widget> scene in scenes.entries) {
    for (final MapEntry<String, Size> w in _windows.entries) {
      unawaited(
        goldenTest(
          '${scene.key} · ${w.key}',
          fileName: 'catalog_${scene.key}_${w.key}',
          constraints: BoxConstraints.tight(w.value),
          pumpBeforeTest: _prepare,
          builder: () => SizedBox(
            width: w.value.width,
            height: w.value.height,
            child: catalogApp(_harness(), home: scene.value, size: w.value),
          ),
        ),
      );
    }
  }
}
