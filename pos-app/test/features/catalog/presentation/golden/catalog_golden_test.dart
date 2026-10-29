// T-CAT-018, T-CAT-021 (golden): SCR-10 «Каталог», SCR-11 «Результаты поиска» и SCR-12 «Категория» на трёх
// брейкпоинтах compact / medium / expanded (D-18). Раскладка medium+ — по утверждённому прототипу 2026-10-29
// (ADR-112): шапка 68 «☰ · логотип · поиск до 680 · SyncIndicator · кнопка-итог корзины · колокольчик · аватар»
// без часов и даты, колонка «Каталог» 132 с плитками корневых категорий и «★ Избранное», заголовок раздела, лента
// подкатегорий 118×148 с «Все товары», одна строка управления «Новые · Избранные · Недавние · Найдено: N |
// Сетка/Список/Компакт · сортировка · Фильтры», сетка карточек от 176 с «+ Добавить» / «В корзине · N — ещё +1»;
// постоянной CP нет — корзина открывается drawer 420 по кнопке-итогу (в эталонах закрыт). compact — без изменений.
// AC-UI-10-001/030. Палитра B по прототипу (ADR-111), reduce-motion, синтетические данные.
//
// Обновить эталоны: flutter test test/features/catalog/presentation/golden --update-goldens
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
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
