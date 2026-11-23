// SCR-50 «Главный экран клиента» (RM-E-017; 02 SCR-50; 10 CUST-021, CUST-022; 12 T-CAT, T-FAV): состав
// экрана по классам окна, остатки по `customer_stock_display` (status — `StockBadge` без чисел, quantity —
// «Доступно N» без «остатка»/«резерва»), цены без `priceListId`, избранное, «Мой кабинет», баннер привязки,
// поиск без сканера, `CartFab`, UI-50-015; сетка по ширине окна в пределах 03 §7.3 (T-CAT-038, уточнение ADR-114
// 2026-11-18). Синтетические данные (на фейках, не реальная интеграция).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' show CustomerLinkStatus, CustomerStockDisplay;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/design_system/components/app_badge.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/category_sidebar_item.dart';
import 'package:optomstroy/design_system/components/favorite_toggle.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/product_card.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/components/stock_badge.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/providers/customer_mode_ports.dart';
import 'package:optomstroy/features/catalog/presentation/screens/customer_home_view.dart';
import 'package:optomstroy/features/home/presentation/screens/customer_home_screen.dart';

import '../../design_system/ds_test_support.dart' show loadInterFont;
import '../catalog/presentation/support/demo_category_tree.dart';
import '../catalog/presentation/support/grid_sweep.dart';
import 'support/home_fakes.dart';

Future<void> pumpHome(WidgetTester tester, HomeHarness h, {Size size = kCompact, bool router = true}) async {
  setWindow(tester, size);
  addTearDown(() => disposeHome(h));
  await tester.pumpWidget(homeApp(h, router: router ? homeRouter() : null, size: size));
  await settle(tester, frames: 10);
}

/// Высокое окно compact: вся витрина без виртуализации.
const Size kTallCompact = Size(390, 2400);

String location(WidgetTester tester) =>
    (tester.widget<Text>(find.byKey(const ValueKey<String>('route-probe'))).data ?? '').replaceFirst('route:', '');

List<StockBadge> badges(WidgetTester tester) => tester
    .widgetList<StockBadge>(find.descendant(of: find.byType(ProductCardGrid), matching: find.byType(StockBadge)))
    .toList();

void main() {
  group('остатки и цены (CUST-021, CUST-022)', () {
    testWidgets('status: StockBadge без чисел, даже если сервер прислал available', (tester) async {
      final FakeCatalogRepository repo = FakeCatalogRepository(
        items: <ProductSummary>[
          customerProduct(1, available: 24),
          customerProduct(2, level: StockLevel.low, available: 3),
          customerProduct(3, level: StockLevel.out),
        ],
      );
      await pumpHome(tester, HomeHarness(catalog: repo), size: kTallCompact);
      final List<StockBadge> list = badges(tester);
      expect(list.map((StockBadge b) => b.level), <StockBadgeLevel>[
        StockBadgeLevel.inStock,
        StockBadgeLevel.low,
        StockBadgeLevel.out,
      ]);
      // Текстовый статус без числа (AC-UI-50-004, 03 §9.17): «Мало» отличается от «В наличии» не только цветом.
      expect(list[0].label, 'В наличии');
      expect(list[1].label, 'Мало');
      expect(list[2].label, 'Нет в наличии', reason: 'не «0 шт» (02 SCR-50.4)');
      expect(find.textContaining('24 шт'), findsNothing);
      expect(find.textContaining('3 шт'), findsNothing);
      expect(find.textContaining('Доступно'), findsNothing);
      expect(find.textContaining('Резерв'), findsNothing);
      expect(find.textContaining('Остаток'), findsNothing);
    });

    testWidgets('quantity: «В наличии · N шт» без «остатка» и «резерва»; без available — статус без числа', (
      tester,
    ) async {
      final FakeCatalogRepository repo = FakeCatalogRepository(
        items: <ProductSummary>[customerProduct(1, available: 24), customerProduct(2)],
      );
      await pumpHome(tester, HomeHarness(catalog: repo, display: CustomerStockDisplay.quantity));
      final List<StockBadge> list = badges(tester);
      expect(list[0].label, 'В наличии · 24 шт');
      expect(list[1].label, 'В наличии', reason: 'клиент не вычисляет количество');
      expect(find.textContaining('Резерв'), findsNothing);
      expect(find.textContaining('Остаток'), findsNothing);
    });

    testWidgets('запрос каталога без priceListId и склада; вид цены клиента из ответа сервера', (tester) async {
      final HomeHarness h = HomeHarness();
      await pumpHome(tester, h);
      expect(h.catalog.productCalls, isNotEmpty);
      for (final CatalogQuery q in h.catalog.productCalls) {
        expect(q.filter.priceListId, isNull);
        expect(q.filter.warehouseId, isNull);
      }
      expect(find.byKey(CustomerHomeKeys.priceList), findsOneWidget);
      expect(find.text('Ваш вид цены: Оптовая'), findsOneWidget);
      final PriceText price = tester.widget<PriceText>(
        find.descendant(of: find.byType(ProductCardGrid).first, matching: find.byType(PriceText)),
      );
      expect(price.amount?.tyiyn, 210000, reason: 'цена — как отдал сервер, целые тыйыны');
    });
  });

  group('состав SCR-50 (compact)', () {
    testWidgets('шапка без сканера, «Мой кабинет», категории 3 колонки, недавние, сетка 2 колонки', (tester) async {
      await pumpHome(tester, HomeHarness());
      expect(find.byKey(CustomerHomeScreen.screenKey), findsOneWidget);
      expect(find.byKey(CustomerHomeKeys.root), findsOneWidget);
      expect(find.byTooltip('Сканировать штрихкод'), findsNothing);
      expect(find.byIcon(Icons.qr_code_scanner_rounded), findsNothing);
      expect(find.byKey(CustomerHomeKeys.orders), findsOneWidget);
      expect(find.text('2 в работе'), findsOneWidget);
      expect(find.byKey(CustomerHomeKeys.debt), findsOneWidget);
      // «Мой долг» не уже своей суммы (пакет own-server:GAP-APP): в тестовом шрифте плитка шире 140, и «Избранное» —
      // за краем ленты (лента прокручивается).
      expect(find.byKey(CustomerHomeKeys.favorites, skipOffstage: false), findsOneWidget);
      expect(find.byKey(CustomerHomeKeys.categories), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('home-category-c-mix')), findsOneWidget);
      expect(find.byKey(CustomerHomeKeys.recent), findsOneWidget);
      expect(find.byKey(CustomerHomeKeys.sidebar), findsNothing);
      final Rect a = tester.getRect(find.byType(ProductCardGrid).at(0));
      final Rect b = tester.getRect(find.byType(ProductCardGrid).at(1));
      expect(a.top, b.top, reason: 'две карточки в ряду');
      expect(b.left, greaterThan(a.right));
      expect(find.byKey(CustomerHomeKeys.cartFab), findsNothing, reason: 'корзина пуста');
    });

    testWidgets('T-CAT-042: категории главной (дерево веб-демо без картинок) — иконка по названию у каждого корня', (
      tester,
    ) async {
      final CategoryTree tree = demoCategoryTree();
      await pumpHome(
        tester,
        HomeHarness(
          catalog: FakeCatalogRepository(items: customerItems(), tree: tree),
        ),
        size: kTallCompact,
      );
      for (final Category root in tree.roots) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey<String>('home-category-${root.id}')),
            matching: find.byIcon(CategoryIcons.resolve(name: root.name)),
          ),
          findsOneWidget,
          reason: root.name,
        );
      }
      expect(
        find.descendant(of: find.byKey(CustomerHomeKeys.categories), matching: find.byIcon(Icons.category_rounded)),
        findsNothing,
      );
    });

    testWidgets('T-CAT-042: список SB главной на expanded — корни по названию; раскрытый корень — подкатегории со '
        'своей иконкой или иконкой корня', (tester) async {
      final CategoryTree tree = demoCategoryTree();
      await pumpHome(
        tester,
        HomeHarness(
          catalog: FakeCatalogRepository(items: customerItems(), tree: tree),
        ),
        size: const Size(1366, 1400),
      );
      Icon itemIcon(String id) => tester.widget<Icon>(
        find.descendant(
          of: find.descendant(
            of: find.byKey(ValueKey<String>('sidebar-category-$id')),
            matching: find.byKey(const ValueKey<String>('category-image-icon')),
          ),
          matching: find.byType(Icon),
        ),
      );
      expect(find.byKey(CustomerHomeKeys.sidebar), findsOneWidget);
      expect(itemIcon('vent').icon, Icons.air_rounded);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey<String>('sidebar-category-vent')),
          matching: find.byIcon(Icons.expand_more_rounded),
        ),
      );
      await settle(tester);
      expect(itemIcon('fans').icon, Icons.air_rounded);
      expect(itemIcon('ducts').icon, Icons.hvac_rounded);
      expect(itemIcon('grilles').icon, Icons.air_rounded, reason: '«Решётки» — иконка корня «Вентиляция»');
      expect(
        find.descendant(of: find.byKey(CustomerHomeKeys.sidebar), matching: find.byIcon(Icons.category_rounded)),
        findsNothing,
      );
    });

    testWidgets('нет кассовых, отчётных и админ-элементов; нет таблицы складов и часов', (tester) async {
      await pumpHome(tester, HomeHarness(), size: kExpanded);
      for (final String text in <String>['Касса', 'Отчёты', 'Пользователи', 'Синхронизация', 'Резерв', 'Склад']) {
        expect(find.textContaining(text), findsNothing, reason: text);
      }
      expect(find.byKey(const ValueKey<String>('catalog-cart-panel')), findsNothing);
    });

    testWidgets('до подтверждения привязки: «Долг доступен после подтверждения организации», баннер proposed', (
      tester,
    ) async {
      final HomeHarness h = HomeHarness(
        port: FakeCustomerHomePort(
          const CustomerHomeSummary(linkStatus: CustomerLinkStatus.proposed, linkName: 'ОсОО «С***»'),
        ),
      );
      await pumpHome(tester, h);
      expect(find.text('Долг доступен после подтверждения организации'), findsOneWidget);
      expect(find.byKey(CustomerHomeKeys.linkBanner), findsOneWidget);
      expect(find.text('Мы нашли организацию ОсОО «С***». Это вы?'), findsOneWidget);
      await tester.tap(find.text('Проверить'));
      await settle(tester);
      expect(location(tester), '/register/customer-link');
    });

    testWidgets('confirmed: долг — сумма сервера, тап → SCR-34 своего клиента; без снимка — «Нет данных из 1С»', (
      tester,
    ) async {
      final FakeCustomerHomePort port = FakeCustomerHomePort(kLinkedSummary);
      await pumpHome(tester, HomeHarness(port: port));
      expect(find.byKey(CustomerHomeKeys.linkBanner), findsNothing);
      final PriceText debt = tester.widget<PriceText>(
        find.descendant(of: find.byKey(CustomerHomeKeys.debt), matching: find.byType(PriceText)),
      );
      expect(debt.amount?.tyiyn, 790000);
      await tester.tap(find.byKey(CustomerHomeKeys.debt));
      await settle(tester);
      expect(location(tester), '/customers/cust-1/receivables');

      await tester.pumpWidget(const SizedBox());
      await pumpHome(
        tester,
        HomeHarness(
          port: FakeCustomerHomePort(
            const CustomerHomeSummary(linkStatus: CustomerLinkStatus.confirmed, customerId: 'cust-1'),
          ),
        ),
      );
      expect(find.text('Нет данных из 1С'), findsOneWidget);
      // Без снимка долг не «0,00 сом» (цены каталога теперь всегда с «,00» — ADR-114, поэтому ищется сумма 0,00
      // целиком, а не подстрока).
      expect(find.descendant(of: find.byKey(CustomerHomeKeys.debt), matching: find.byType(PriceText)), findsNothing);
      expect(find.textContaining(RegExp(r'(?<!\d)0,00'), findRichText: true), findsNothing);
    });

    testWidgets('офлайн: «Мой долг» скрыт, баннер офлайна, каталог из кэша', (tester) async {
      final FakeCatalogRepository repo = FakeCatalogRepository()
        ..cached = Success<CatalogPage<ProductSummary>>(page(customerItems(), source: DataSource.cache))
        ..networkPages.add(const FailureResult<CatalogPage<ProductSummary>>(kOffline));
      await pumpHome(tester, HomeHarness(catalog: repo));
      expect(find.byKey(CustomerHomeKeys.offlineBanner), findsOneWidget);
      expect(find.byKey(CustomerHomeKeys.debt), findsNothing);
      // Плитки категорий с тестовым шрифтом шире (колонок меньше, CategoryTile.gridColumnsFor) — сетка товаров ниже.
      final Finder scroll = find
          .byWidgetPredicate((Widget w) => w is Scrollable && w.axisDirection == AxisDirection.down)
          .first;
      for (int i = 0; i < 10 && find.byType(ProductCardGrid).evaluate().isEmpty; i++) {
        await tester.drag(scroll, const Offset(0, -300));
        await tester.pump();
      }
      expect(find.byType(ProductCardGrid), findsWidgets);
    });
  });

  group('действия', () {
    testWidgets('«Компакт» 1280 lp (паритет функций ADR-112): в строке таблицы — миниатюра, звезда (переключает '
        'избранное, не выходя из таблицы) и цена с «/ шт»', (tester) async {
      final HomeHarness h = HomeHarness();
      setWindow(tester, const Size(1280, 900));
      addTearDown(() => disposeHome(h));
      await tester.pumpWidget(
        homeApp(
          h,
          router: homeRouter(initial: '/home?view=compact'),
          size: const Size(1280, 900),
        ),
      );
      await settle(tester, frames: 10);
      final Finder row = find.byKey(const ValueKey<String>('product-p3'));
      await tester.ensureVisible(row);
      await settle(tester);
      expect(
        tester.widget<ProductCardCompact>(find.descendant(of: row, matching: find.byType(ProductCardCompact))).variant,
        ProductCardCompactVariant.table,
      );
      expect(
        find.descendant(of: row, matching: find.byType(ProductImage)),
        findsOneWidget,
        reason: 'миниатюра 40',
      );
      final PriceText price = tester.widget<PriceText>(find.descendant(of: row, matching: find.byType(PriceText)));
      expect(price.unit, isNotNull, reason: 'единица у цены («/ шт»)');
      final Finder star = find.descendant(of: row, matching: find.byType(FavoriteToggle));
      expect(star, findsOneWidget);
      await tester.tap(star);
      await settle(tester);
      expect(h.shelf!.favoriteCalls, <(String, bool)>[('p3', true)]);
      expect(find.byKey(const ValueKey<String>('route-probe')), findsNothing, reason: 'звезда не открывает карточку');
    });

    testWidgets('избранное: звезда карточки → порт избранного; карточка «Избранное» — число и переход', (tester) async {
      final HomeHarness h = HomeHarness();
      await pumpHome(tester, h, size: kTallCompact);
      // Лента «Мой кабинет» прокручивается: «Мой долг» не уже своей суммы (пакет own-server:GAP-APP).
      await tester.ensureVisible(find.byKey(CustomerHomeKeys.favorites, skipOffstage: false));
      await tester.pump();
      final Finder favCount = find.descendant(of: find.byKey(CustomerHomeKeys.favorites), matching: find.text('2'));
      expect(favCount, findsOneWidget);
      final Finder star = find.descendant(
        of: find.byKey(const ValueKey<String>('product-p3')),
        matching: find.byType(FavoriteToggle),
      );
      await tester.ensureVisible(star);
      await tester.tap(star);
      await settle(tester);
      expect(h.shelf!.favoriteCalls, <(String, bool)>[('p3', true)]);
      expect(find.descendant(of: find.byKey(CustomerHomeKeys.favorites), matching: find.text('3')), findsOneWidget);
      // Лента «Мой кабинет» шире экрана 390: карточка «Избранное» видна частично — тап по видимой части.
      await tester.tapAt(tester.getTopLeft(find.byKey(CustomerHomeKeys.favorites)) + const Offset(12, 12));
      await settle(tester);
      expect(location(tester), '/favorites');
    });

    testWidgets('поиск: ввод ≥ 2 символов → SCR-11 (штрихкод цифрами — тем же поиском)', (tester) async {
      await pumpHome(tester, HomeHarness());
      await tester.enterText(find.byKey(const ValueKey<String>('catalog-search-field')).first, '4600123');
      await tester.pump(const Duration(milliseconds: 350));
      await settle(tester);
      expect(location(tester), '/catalog/search?q=4600123');
    });

    testWidgets('категория → SCR-12; товар → SCR-14', (tester) async {
      await pumpHome(tester, HomeHarness());
      await tester.tap(find.byKey(const ValueKey<String>('home-category-c-mix')));
      await settle(tester);
      expect(location(tester), '/catalog/c/c-mix');
    });

    testWidgets('EQ-HOME-04: «Заказов нет», тултип вида цены, a11y CartFab без суммы', (tester) async {
      await pumpHome(
        tester,
        HomeHarness(port: FakeCustomerHomePort(const CustomerHomeSummary(activeOrders: 0)), cartCount: 2),
      );
      expect(find.text('Заказов нет'), findsOneWidget, reason: 'UI-50-004');
      expect(
        find.ancestor(of: find.byKey(CustomerHomeKeys.priceList), matching: find.byType(AppTooltip)),
        findsOneWidget,
      );
      expect(
        tester
            .widget<AppTooltip>(
              find.ancestor(of: find.byKey(CustomerHomeKeys.priceList), matching: find.byType(AppTooltip)),
            )
            .message,
        'Цены показаны по вашему виду цены',
      );
      expect(find.byKey(CustomerHomeKeys.cartFab), findsOneWidget);
      final Semantics fab = tester.widget<Semantics>(
        find.ancestor(of: find.byKey(CustomerHomeKeys.cartFab), matching: find.byType(Semantics)).first,
      );
      // ICU plural (03 §16.3; ревью закрытия E, RS-7): 2 → few «позиции»
      expect(fab.properties.label, 'Открыть корзину, 2 позиции');
    });

    testWidgets('CartFab при непустой корзине (C) → /cart; expanded — кнопка в шапке, без FAB', (tester) async {
      await pumpHome(tester, HomeHarness(cartCount: 3));
      expect(find.byKey(CustomerHomeKeys.cartFab), findsOneWidget);
      // Счётчик на заливке `primary` — контрастный бейдж (не тон `cart` того же цвета; ревью E, ui-13).
      final AppBadge badge = tester.widget<AppBadge>(
        find.descendant(of: find.byKey(CustomerHomeKeys.cartFab), matching: find.byType(AppBadge)),
      );
      expect((badge.count, badge.tone), (3, AppBadgeTone.onPrimary));
      await tester.tap(find.byKey(CustomerHomeKeys.cartFab));
      await settle(tester);
      expect(location(tester), '/cart');

      await tester.pumpWidget(const SizedBox());
      await pumpHome(tester, HomeHarness(cartCount: 3), size: kExpanded);
      expect(find.byKey(CustomerHomeKeys.cartFab), findsNothing);
      expect(find.byKey(CustomerHomeKeys.cartButton), findsOneWidget);
      expect(find.byKey(CustomerHomeKeys.sidebar), findsOneWidget);
    });

    testWidgets('«Очистить» недавние → подтверждение → порт; лента скрывается', (tester) async {
      final HomeHarness h = HomeHarness();
      await pumpHome(tester, h);
      await tester.ensureVisible(find.text('Очистить').first);
      await tester.tap(find.text('Очистить').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Очистить').last);
      await settle(tester);
      expect(h.shelf!.clearCalls, 1);
      expect(find.byKey(CustomerHomeKeys.recent), findsNothing);
    });
  });

  group('UI-50-015 и порты', () {
    testWidgets('customerSelfService=false — «Сервис для покупателей временно недоступен»', (tester) async {
      await pumpHome(tester, HomeHarness(selfService: false));
      expect(find.byKey(CustomerHomeKeys.serviceUnavailable), findsOneWidget);
      expect(find.text('Сервис для покупателей временно недоступен'), findsOneWidget);
      expect(find.byType(ProductCardGrid), findsNothing);
    });

    testWidgets('403 FORBIDDEN на каталоге — то же состояние', (tester) async {
      final FakeCatalogRepository repo = FakeCatalogRepository()
        ..networkPages.add(const FailureResult<CatalogPage<ProductSummary>>(PermissionFailure()));
      await pumpHome(tester, HomeHarness(catalog: repo));
      expect(find.byKey(CustomerHomeKeys.serviceUnavailable), findsOneWidget);
    });

    testWidgets('без привязки корня экран не падает (пустой фон); без порта избранного — без звёзд и числа', (
      tester,
    ) async {
      await pumpHome(tester, HomeHarness(bindBody: false));
      expect(find.byKey(CustomerHomeScreen.screenKey), findsOneWidget);
      expect(find.byKey(CustomerHomeKeys.root), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await pumpHome(tester, HomeHarness(noShelf: true));
      expect(find.byType(FavoriteToggle), findsNothing);
      expect(find.byKey(CustomerHomeKeys.recent), findsNothing);
    });
  });

  // T-CAT-038 (ред. 1.20; 03 §7.3, 15 ADR-114, уточнение 2026-11-18 «…но поставь ограничения»): сетка SCR-50 — то же
  // правило с параметрами экрана: от 160, не больше 6 и предела класса окна, карточка ≤ 280; на large — контент
  // ≤ 1200 (03 §7.2). Окно меняется без пересоздания экрана; ширины 320…2560 (шаг 40, границы классов окна) и 3840, текст ×1 и ×1,3.
  group('сетка SCR-50 по ширине окна (T-CAT-038)', () {
    for (final double scale in <double>[1, 1.3]) {
      testWidgets('колонки от 2 до предела, карточка ≤ 280, текст ×$scale — без переполнения', (tester) async {
        await tester.runAsync(loadInterFont);
        if (scale != 1) {
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        }
        final HomeHarness h = HomeHarness(
          catalog: FakeCatalogRepository(
            items: <ProductSummary>[
              customerProduct(1, priceSom: 99999999),
              customerProduct(2, hasVariants: true, variantCount: 3, priceSom: 10450),
              for (int i = 3; i <= 12; i++) customerProduct(i),
            ],
          ),
        );
        addTearDown(() => disposeHome(h));
        final GridSweep sweep = GridSweep(
          label: 'SCR-50',
          minCardWidth: DsBreakpoints.cardMinWidth,
          maxColumns: DsBreakpoints.gridMaxColumns,
        );
        bool first = true;
        for (final double w in <double>[...kGridSweepWidths, 3840]) {
          setWindow(tester, Size(w, 2000));
          if (first) {
            await tester.pumpWidget(homeApp(h, router: homeRouter()));
            first = false;
          }
          await settle(tester, frames: 10);
          sweep.check(tester, w, note: scale == 1 ? null : 'текст ×$scale');
        }
        sweep.expectMonotonic(expectGridIn: WindowClass.values.toSet());
        // large: контент ≤ 1200 — 6 колонок при любой ширине.
        expect(
          sweep.rows.where((GridSweepRow r) => r.windowClass == WindowClass.large).map((GridSweepRow r) => r.columns),
          everyElement(6),
          reason: sweep.describe(),
        );
        // 3840 (последняя ширина прогона): лента ≤ 1200 по центру зоны справа от сайдбара — пустые полосы поровну
        // (ревью: прежде лента стояла у сайдбара, справа — одна пустая полоса; пакет own-server:GAP-APP).
        final Rect side = tester.getRect(find.byKey(CustomerHomeKeys.sidebar));
        final Rect feed = tester.getRect(find.byKey(const ValueKey<String>('catalog-products')));
        expect(feed.width, closeTo(DsBreakpoints.contentMaxLarge, 0.01));
        expect(feed.left - side.right, closeTo(3840 - feed.right, 0.5), reason: 'лента по центру зоны');
      });
    }
  });

  // 02 SCR-50.2 «Адаптивность» (ред. 1.32; 15 §5.8 (1)): «Все товары» — у левого края сетки в обоих режимах; вид и
  // сортировка — у правого края; не помещаются в строку — строкой ниже, а заголовок остаётся слева (прежде OverflowBar
  // уводил вправо и заголовок).
  group('строка «Все товары»: заголовок слева, вид и сортировка справа', () {
    Future<void> show(WidgetTester tester, Size size, double scale) async {
      await tester.runAsync(loadInterFont);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final HomeHarness h = HomeHarness(
        catalog: FakeCatalogRepository(items: <ProductSummary>[for (int i = 1; i <= 6; i++) customerProduct(i)]),
      );
      addTearDown(() => disposeHome(h));
      setWindow(tester, size);
      await tester.pumpWidget(homeApp(h, router: homeRouter()));
      await settle(tester, frames: 10);
    }

    List<Rect> firstRowCards(WidgetTester tester) {
      final Finder grid = find.byType(ProductCardGrid);
      final List<Rect> cards = <Rect>[for (int i = 0; i < grid.evaluate().length; i++) tester.getRect(grid.at(i))]
        ..sort((Rect a, Rect b) => a.top != b.top ? a.top.compareTo(b.top) : a.left.compareTo(b.left));
      return cards.where((Rect r) => (r.top - cards.first.top).abs() < 0.5).toList();
    }

    for (final double w in <double>[360, 600]) {
      testWidgets('$w × 1,3: заголовок у левого края сетки, элементы у правого, перенос — ниже заголовка', (
        tester,
      ) async {
        await show(tester, Size(w, 1600), 1.3);
        expect(tester.takeException(), isNull);
        final Rect title = tester.getRect(find.byKey(CustomerHomeKeys.allTitle));
        final Rect controls = tester.getRect(find.byKey(CustomerHomeKeys.allControls));
        final List<Rect> row = firstRowCards(tester);
        expect(row, isNotEmpty);
        expect(title.left, closeTo(row.first.left, 0.5), reason: 'заголовок — у левого края сетки');
        expect(title.left, lessThan(controls.left));
        expect(controls.right, closeTo(row.last.right, 0.5), reason: 'вид и сортировка — у правого края сетки');
        if (controls.top >= title.bottom - 0.5) {
          expect(controls.top, greaterThanOrEqualTo(title.bottom - 0.5), reason: 'перенос — строкой ниже');
        }
      });
    }

    testWidgets('1440 × 1: заголовок и элементы в одной строке (центры по вертикали совпадают)', (tester) async {
      await show(tester, const Size(1440, 1600), 1);
      final Rect title = tester.getRect(find.byKey(CustomerHomeKeys.allTitle));
      final Rect controls = tester.getRect(find.byKey(CustomerHomeKeys.allControls));
      expect(title.center.dy, closeTo(controls.center.dy, 1));
      expect(title.right, lessThan(controls.left));
    });
  });
}
