// T-CAT-001, T-CAT-009, T-CAT-016, T-CAT-018, T-CAT-020, T-CAT-021 (widget): SCR-10 «Каталог» (RM-E-007).
// Состояния 02 SCR-10.7 (скелетон, пусто, ошибка, ошибка над кэшем, офлайн с возрастом данных, нет данных
// офлайн), переключение вида без сетевых запросов и сохранение выбора, сортировка, подгрузка по курсору,
// фильтры (FilterPanel expanded / маршрут-лист compact), роли owner/customer, избранное, «Очистить».
// Данные синтетические, репозитории — фейки (не реальная интеграция).
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/enums.dart' show RoleCode;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/product_card.dart';
import 'package:optomstroy/design_system/components/stock_badge.dart';
import 'package:optomstroy/design_system/components/view_mode_segmented.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_screen.dart';
import 'package:optomstroy/features/catalog/presentation/state/catalog_prefs.dart';

import 'support/catalog_fakes.dart';

Future<CatalogHarness> _pump(
  WidgetTester tester,
  CatalogHarness h, {
  Size size = kExpanded,
  Widget screen = const CatalogScreen(),
}) async {
  setWindow(tester, size);
  await tester.pumpWidget(catalogApp(h, home: screen));
  await settle(tester);
  return h;
}

void main() {
  testWidgets('скелетон первой загрузки, затем карточки с артикулом, остатком, ценой и «Найдено: N»', (tester) async {
    final FakeCatalogRepository repo = FakeCatalogRepository(items: products(6));
    repo.gate.hold();
    final CatalogHarness h = CatalogHarness(catalog: repo);
    setWindow(tester, kExpanded);
    await tester.pumpWidget(catalogApp(h, home: const CatalogScreen()));
    await settle(tester);
    expect(find.byKey(const ValueKey<String>('catalog-skeleton')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('stub-SCR-10')), findsOneWidget);

    repo.gate.release();
    await settle(tester);
    expect(find.byKey(const ValueKey<String>('catalog-skeleton')), findsNothing);
    expect(find.byType(ProductCardGrid), findsWidgets);
    expect(find.text('Все товары'), findsOneWidget);
    expect(find.text('Найдено: 6 товаров'), findsOneWidget);
    expect(find.text('Арт. F4200-CR'), findsOneWidget);
    expect(find.text(StockBadge.displayLabel('В наличии · 24 шт')), findsWidgets);
    expect(find.textContaining('2 350'), findsWidgets);
    // Кэш запрошен до сети (≤ 100 мс), затем ровно один сетевой запрос первой страницы.
    expect(repo.cachedCalls, hasLength(1));
    expect(repo.productCalls, hasLength(1));
    expect(repo.productCalls.single.sort, CatalogSort.nameAsc);
    expect(repo.productCalls.single.limit, 40);
  });

  testWidgets('шапка expanded: логотип, поиск, часы и дата, профиль, колокольчик; сайдбар категорий; CP', (
    tester,
  ) async {
    await _pump(tester, CatalogHarness(shelf: FakeShelfPort(favorites: <String>{'p1', 'p2'})));
    expect(find.byKey(const ValueKey<String>('catalog-search-field')), findsOneWidget);
    expect(find.text('09:41'), findsOneWidget);
    expect(find.text('Абдулла'), findsOneWidget);
    expect(find.text('Продавец'), findsOneWidget);
    expect(find.bySemanticsLabel('Уведомления, 3 непрочитанных'), findsOneWidget);
    expect(find.text('Категории товаров'), findsOneWidget);
    expect(find.text('Смесители'), findsWidgets);
    expect(find.byKey(const ValueKey<String>('sidebar-favorites')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('catalog-cart-panel')), findsOneWidget);
  });

  testWidgets('пустой результат: EmptyState «В этой категории пока нет товаров»', (tester) async {
    final FakeCatalogRepository repo = FakeCatalogRepository();
    repo.networkPages.add(Success<CatalogPage<ProductSummary>>(page(const <ProductSummary>[])));
    await _pump(tester, CatalogHarness(catalog: repo));
    expect(find.byKey(const ValueKey<String>('catalog-empty')), findsOneWidget);
    expect(find.text('В этой категории пока нет товаров'), findsOneWidget);
  });

  testWidgets('пусто с фильтрами: «Ничего не найдено» + «Сбросить» возвращает непустой результат', (tester) async {
    final FakeCatalogRepository repo = FakeCatalogRepository();
    repo.networkPages
      ..add(Success<CatalogPage<ProductSummary>>(page(products(3))))
      ..add(Success<CatalogPage<ProductSummary>>(page(const <ProductSummary>[])))
      ..add(Success<CatalogPage<ProductSummary>>(page(products(3))));
    await _pump(tester, CatalogHarness(catalog: repo));
    await tester.tap(find.byKey(const ValueKey<String>('catalog-filters-button')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey<String>('filter-in-stock')));
    await tester.pump(const Duration(milliseconds: 350));
    await settle(tester);
    expect(find.text('Ничего не найдено'), findsOneWidget);
    await tester.tap(
      find.descendant(of: find.byKey(const ValueKey<String>('catalog-empty')), matching: find.text('Сбросить')),
    );
    await settle(tester);
    expect(repo.productCalls.last.filter.inStock, isNull);
    expect(find.byType(ProductCardGrid), findsNWidgets(3));
  });

  testWidgets('ошибка без кэша — полноэкранная с «Повторить»; повтор перезапрашивает', (tester) async {
    final FakeCatalogRepository repo = FakeCatalogRepository();
    repo.networkPages
      ..add(
        const FailureResult<CatalogPage<ProductSummary>>(
          ServerFailure(code: 'INTERNAL', status: 500, requestId: 'req-1'),
        ),
      )
      ..add(Success<CatalogPage<ProductSummary>>(page(products(2))));
    await _pump(tester, CatalogHarness(catalog: repo));
    expect(find.byKey(const ValueKey<String>('catalog-error')), findsOneWidget);
    expect(find.text('Не удалось загрузить каталог'), findsOneWidget);
    expect(find.textContaining('req-1'), findsOneWidget);
    await tester.tap(find.text('Повторить'));
    await settle(tester);
    expect(repo.productCalls, hasLength(2));
    expect(find.byType(ProductCardGrid), findsNWidgets(2));
  });

  testWidgets('ошибка сервера при кэше — inline-ошибка над данными кэша', (tester) async {
    final FakeCatalogRepository repo = FakeCatalogRepository();
    repo.cached = Success<CatalogPage<ProductSummary>>(page(products(2), source: DataSource.cache));
    repo.networkPages.add(
      const FailureResult<CatalogPage<ProductSummary>>(ServerFailure(code: 'INTERNAL', status: 500)),
    );
    await _pump(tester, CatalogHarness(catalog: repo));
    expect(find.byKey(const ValueKey<String>('catalog-error-inline')), findsOneWidget);
    expect(find.byType(ProductCardGrid), findsNWidgets(2));
  });

  testWidgets('нет сети: кэш + OfflineBanner с временем данных и метки возраста на бейджах', (tester) async {
    final FakeCatalogRepository repo = FakeCatalogRepository();
    repo.cached = Success<CatalogPage<ProductSummary>>(page(products(2), source: DataSource.cache));
    repo.networkPages.add(const FailureResult<CatalogPage<ProductSummary>>(kOffline));
    await _pump(tester, CatalogHarness(catalog: repo));
    expect(find.byKey(const ValueKey<String>('catalog-offline-banner')), findsOneWidget);
    expect(find.textContaining('Нет сети. Показаны данные от'), findsOneWidget);
    expect(find.text('данные от 09:36'), findsWidgets);
  });

  testWidgets('офлайн по статусу сети (порт onlineStatus) — баннер даже при успешном кэше', (tester) async {
    await _pump(tester, CatalogHarness(online: OnlineStatus.offline));
    expect(find.byKey(const ValueKey<String>('catalog-offline-banner')), findsOneWidget);
  });

  testWidgets('нет сети и нет кэша — «Нет подключения к сети» с «Повторить»', (tester) async {
    final FakeCatalogRepository repo = FakeCatalogRepository();
    repo.networkPages.add(const FailureResult<CatalogPage<ProductSummary>>(kOffline));
    await _pump(tester, CatalogHarness(catalog: repo));
    expect(find.byKey(const ValueKey<String>('catalog-offline-no-cache')), findsOneWidget);
  });

  testWidgets('вид «Сетка/Список/Компакт» — без сетевых запросов; выбор сохраняется после перезапуска', (tester) async {
    final InMemoryCatalogPrefs prefs = InMemoryCatalogPrefs();
    final CatalogHarness h = CatalogHarness(prefs: prefs);
    await _pump(tester, h);
    expect(h.catalog.productCalls, hasLength(1));
    await tester.tap(find.byKey(const ValueKey<String>('view-mode-list')));
    await settle(tester);
    expect(find.byType(ProductCardList), findsWidgets);
    await tester.tap(find.byKey(const ValueKey<String>('view-mode-compact')));
    await settle(tester);
    expect(find.byType(ProductCardCompact), findsWidgets);
    expect(find.byType(ProductCardCompactHeader), findsOneWidget);
    expect(h.catalog.productCalls, hasLength(1), reason: 'смена вида не перезапрашивает данные (CAT-010)');

    // «Перезапуск»: новое дерево с теми же настройками устройства.
    await tester.pumpWidget(const SizedBox());
    final CatalogHarness again = CatalogHarness(prefs: prefs);
    await _pump(tester, again);
    expect(find.byType(ProductCardCompact), findsWidgets);
  });

  testWidgets('компакт на compact — однострочные строки 48 без заголовка таблицы', (tester) async {
    final InMemoryCatalogPrefs prefs = InMemoryCatalogPrefs();
    await prefs.setViewMode(WindowClass.compact, ProductViewMode.compact);
    await _pump(
      tester,
      CatalogHarness(
        prefs: prefs,
        catalog: FakeCatalogRepository(items: products(12)),
      ),
      size: kCompact,
    );
    final ProductCardCompact row = tester.widget<ProductCardCompact>(find.byType(ProductCardCompact).first);
    expect(row.variant, ProductCardCompactVariant.row);
    expect(find.byType(ProductCardCompactHeader), findsNothing);
    expect(find.byType(ProductCardCompact).evaluate().length, greaterThanOrEqualTo(10));
  });

  testWidgets('сортировка: «По артикулу» → новый запрос с sort=sku:asc с первой страницы; тот же пункт — без запроса', (
    tester,
  ) async {
    final CatalogHarness h = await _pump(tester, CatalogHarness());
    await tester.tap(find.byKey(const ValueKey<String>('catalog-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('По артикулу').last);
    await settle(tester);
    expect(h.catalog.productCalls.last.sort, CatalogSort.skuAsc);
    expect(h.catalog.productCalls.last.cursor, isNull);
    final int calls = h.catalog.productCalls.length;

    await tester.tap(find.byKey(const ValueKey<String>('catalog-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('По артикулу').last);
    await settle(tester);
    expect(h.catalog.productCalls, hasLength(calls));
  });

  testWidgets('меню сортировки содержит «Сначала в наличии» и «По артикулу» (AC-UI-10-031)', (tester) async {
    await _pump(tester, CatalogHarness());
    await tester.tap(find.byKey(const ValueKey<String>('catalog-sort')));
    await tester.pumpAndSettle();
    expect(find.text('Сначала в наличии'), findsOneWidget);
    expect(find.text('По артикулу'), findsOneWidget);
    expect(find.text('Сначала новые'), findsOneWidget);
  });

  testWidgets(
    'подгрузка: «Загружаем ещё товары…» → запрос с курсором; ошибка страницы → «Повторить» без потери списка',
    (tester) async {
      final FakeCatalogRepository repo = FakeCatalogRepository();
      repo.networkPages.add(Success<CatalogPage<ProductSummary>>(page(products(8), next: 'c2', total: 20)));
      repo.byCursor['c2'] = const FailureResult<CatalogPage<ProductSummary>>(
        ServerFailure(code: 'INTERNAL', status: 500),
      );
      final CatalogHarness h = CatalogHarness(catalog: repo, prefs: InMemoryCatalogPrefs());
      await h.prefs.setViewMode(WindowClass.expanded, ProductViewMode.list);
      await _pump(tester, h);
      expect(find.text('Найдено: 20 товаров'), findsOneWidget);
      await tester.drag(find.byKey(const ValueKey<String>('catalog-products')), const Offset(0, -3000));
      await settle(tester);
      expect(repo.productCalls.map((CatalogQuery q) => q.cursor), contains('c2'));
      expect(find.byKey(const ValueKey<String>('catalog-load-more-error')), findsOneWidget);
      expect(find.byType(ProductCardList), findsWidgets);

      repo.byCursor['c2'] = Success<CatalogPage<ProductSummary>>(page(products(4, from: 8)));
      await tester.tap(find.byKey(const ValueKey<String>('catalog-load-more-error')));
      await settle(tester);
      await tester.drag(find.byKey(const ValueKey<String>('catalog-products')), const Offset(0, -3000));
      await settle(tester);
      expect(find.byKey(const ValueKey<String>('product-p11')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('catalog-load-more-error')), findsNothing);
    },
  );

  testWidgets(
    'FilterPanel (expanded): «Только в наличии» применяется через 300 мс, чип активного фильтра снимает фильтр',
    (tester) async {
      final CatalogHarness h = await _pump(tester, CatalogHarness());
      await tester.tap(find.byKey(const ValueKey<String>('catalog-filters-button')));
      await settle(tester);
      expect(find.byKey(const ValueKey<String>('catalog-filter-panel')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('catalog-cart-panel')), findsOneWidget, reason: 'CP остаётся видимой');
      final int before = h.catalog.productCalls.length;
      await tester.tap(find.byKey(const ValueKey<String>('filter-in-stock')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(h.catalog.productCalls, hasLength(before), reason: 'до 300 мс фильтр не применён');
      await tester.pump(const Duration(milliseconds: 150));
      await settle(tester);
      expect(h.catalog.productCalls.last.filter.inStock, isTrue);
      expect(find.byKey(const ValueKey<String>('active-filter-stock')), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey<String>('active-filter-stock')),
          matching: find.byIcon(Icons.close_rounded),
        ),
      );
      await settle(tester);
      expect(h.catalog.productCalls.last.filter.inStock, isNull);
    },
  );

  testWidgets('compact: «Фильтры» открывает лист SCR-13; «Показать N» применяет, «Назад» — нет', (tester) async {
    final CatalogHarness h = await _pump(tester, CatalogHarness(), size: kCompact);
    await tester.tap(find.byKey(const ValueKey<String>('catalog-filters-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('stub-SCR-13')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('filter-favorites')));
    await tester.pump(const Duration(milliseconds: 350));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey<String>('filter-sheet-apply')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('stub-SCR-13')), findsNothing);
    CatalogQuery lastList() => h.catalog.productCalls.lastWhere((CatalogQuery q) => q.limit == 40);
    expect(lastList().filter.favorite, isTrue);

    // Повторно: изменить и закрыть крестиком — без применения.
    await tester.tap(find.byKey(const ValueKey<String>('catalog-filters-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('filter-with-photo')));
    await tester.pump(const Duration(milliseconds: 350));
    await settle(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('stub-SCR-13')),
        matching: find.byIcon(Icons.close_rounded),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('stub-SCR-13')), findsNothing);
    expect(lastList().filter.hasImage, isNot(isTrue));
    expect(lastList().filter.favorite, isTrue);
  });

  testWidgets('owner: без «+ Добавить» и CP; customer: статус наличия текстом, без числа', (tester) async {
    await _pump(tester, CatalogHarness(role: RoleCode.owner));
    final ProductCardGrid card = tester.widget<ProductCardGrid>(find.byType(ProductCardGrid).first);
    expect(card.data.action, ProductCardActionKind.hidden);
    expect(find.text('+ Добавить'), findsNothing);
    expect(find.byKey(const ValueKey<String>('catalog-cart-panel')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    final FakeCatalogRepository repo = FakeCatalogRepository(items: <ProductSummary>[product(1, hideQty: true)]);
    await _pump(tester, CatalogHarness(role: RoleCode.customer, catalog: repo));
    final StockBadge badge = tester.widget<StockBadge>(find.byType(StockBadge).first);
    expect(badge.level, StockBadgeLevel.inStock);
    expect(badge.label, 'В наличии', reason: 'AC-UI-50-004: текст статуса, не только иконка');
    expect(find.textContaining('24 шт'), findsNothing);
  });

  testWidgets('карточка: нет в наличии / нет цены / остаток неизвестен — добавление недоступно с причиной', (
    tester,
  ) async {
    final FakeCatalogRepository repo = FakeCatalogRepository(
      items: <ProductSummary>[
        product(1, level: StockLevel.out),
        product(2, noPrice: true),
        product(3, noStock: true),
        product(4, hasVariants: true, variantCount: 3),
        product(5, noSku: true),
      ],
    );
    await _pump(tester, CatalogHarness(catalog: repo));
    List<ProductCardData> data() =>
        tester.widgetList<ProductCardGrid>(find.byType(ProductCardGrid)).map((ProductCardGrid g) => g.data).toList();
    final Map<String, ProductCardData> byId = <String, ProductCardData>{
      for (final ProductCardData d in data()) d.id: d,
    };
    expect(byId['p1']!.action, ProductCardActionKind.unavailable);
    expect(byId['p1']!.actionLabel, 'Нет в наличии');
    expect(byId['p1']!.dimmed, isTrue);
    expect(byId['p2']!.actionLabel, 'Цена не указана');
    expect(byId['p3']!.actionLabel, 'Остаток неизвестен');
    expect(byId['p4']!.action, ProductCardActionKind.chooseVariant);
    expect(byId['p4']!.variantsLabel, '3 варианта');
    expect(byId['p5']!.skuLabel, 'Артикул не указан');
  });

  testWidgets('избранное: мгновенное переключение; ошибка сервера — откат и снекбар', (tester) async {
    final FakeShelfPort shelf = FakeShelfPort();
    addTearDown(shelf.dispose);
    await _pump(tester, CatalogHarness(shelf: shelf));
    bool fav() => tester
        .widget<ProductCardGrid>(
          find.descendant(of: find.byKey(const ValueKey<String>('product-p0')), matching: find.byType(ProductCardGrid)),
        )
        .data
        .isFavorite;
    expect(fav(), isFalse);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('product-p0')),
        matching: find.bySemanticsLabel('Добавить в избранное'),
      ),
    );
    await settle(tester);
    expect(shelf.favoriteCalls.single, ('p0', true));
    expect(fav(), isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Добавлено в избранное'), findsOneWidget);

    shelf.favoriteResult = const FailureResult<void>(ServerFailure(code: 'INTERNAL', status: 500));
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('product-p0')),
        matching: find.bySemanticsLabel('В избранном'),
      ),
    );
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(fav(), isTrue, reason: 'откат после ошибки');
    expect(find.text('Не удалось сохранить избранное'), findsOneWidget);
  });

  testWidgets('«Очистить» недавние: ConfirmDialog → порт clearRecent, блок скрывается', (tester) async {
    final FakeShelfPort shelf = FakeShelfPort(
      recent: <RecentProduct>[RecentProduct(product: product(7), viewedAt: kNow)],
    );
    addTearDown(shelf.dispose);
    await _pump(tester, CatalogHarness(shelf: shelf));
    expect(find.byKey(const ValueKey<String>('sidebar-recent')), findsOneWidget);
    await tester.tap(find.text('Очистить'));
    await tester.pumpAndSettle();
    expect(find.text('Очистить недавние товары?'), findsOneWidget);
    await tester.tap(find.text('Очистить').last);
    await tester.pumpAndSettle();
    expect(shelf.clearCalls, 1);
    expect(find.byKey(const ValueKey<String>('sidebar-recent')), findsNothing);
  });

  testWidgets('без привязки портов (UnimplementedError) экран показывает ошибку, а не падает', (tester) async {
    final FakeCatalogRepository repo = FakeCatalogRepository();
    repo.networkPages.add(const FailureResult<CatalogPage<ProductSummary>>(UnknownFailure()));
    await _pump(tester, CatalogHarness(catalog: repo, shelf: null));
    expect(find.byKey(const ValueKey<String>('catalog-error')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('sidebar-favorites')), findsNothing);
  });

  testWidgets('T-CART-022 / CART-024 (compact): корзина отклонила «+ Добавить» (предел строк) — снекбар порта '
      '«Слишком много позиций…», без «Добавлено»', (tester) async {
    final _RejectingCartPort port = _RejectingCartPort();
    await _pump(
      tester,
      CatalogHarness(extra: <Override>[catalogCartPortProvider.overrideWithValue(port)]),
      size: kCompact,
    );
    await tester.tap(find.byIcon(Icons.add_rounded).first);
    await settle(tester);
    expect(port.added, hasLength(1));
    expect(find.text(_RejectingCartPort.text), findsOneWidget);
    expect(find.textContaining('Добавлено'), findsNothing);
  });
}

/// Порт корзины, который отклоняет добавление (сервер: 201-я строка).
final class _RejectingCartPort implements CatalogCartPort {
  static const String text = 'Слишком много позиций (максимум 200). Оформите часть заказа отдельно';
  static const ValidationFailure failure = ValidationFailure(
    errors: <FieldError>[FieldError(field: 'quantity', rule: 'max_items')],
  );

  final List<ProductSummary> added = <ProductSummary>[];

  @override
  Future<Result<void>> add(ProductSummary product) async {
    added.add(product);
    return const FailureResult<void>(failure);
  }

  @override
  String? rejectionText(Failure f, AppLocalizations l10n) => identical(f, failure) ? text : null;
}
