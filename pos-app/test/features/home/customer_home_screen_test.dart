// SCR-50 «Главный экран клиента» (RM-E-017; 02 SCR-50; 10 CUST-021, CUST-022; 12 T-CAT, T-FAV): состав
// экрана по классам окна, остатки по `customer_stock_display` (status — `StockBadge` без чисел, quantity —
// «Доступно N» без «остатка»/«резерва»), цены без `priceListId`, избранное, «Мой кабинет», баннер привязки,
// поиск без сканера, `CartFab`, UI-50-015. Синтетические данные (на фейках, не реальная интеграция).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' show CustomerLinkStatus, CustomerStockDisplay;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/design_system/components/app_badge.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/favorite_toggle.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/product_card.dart';
import 'package:optomstroy/design_system/components/stock_badge.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/providers/customer_mode_ports.dart';
import 'package:optomstroy/features/catalog/presentation/screens/customer_home_view.dart';
import 'package:optomstroy/features/home/presentation/screens/customer_home_screen.dart';

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
      expect(find.byKey(CustomerHomeKeys.favorites), findsOneWidget);
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
      expect(find.textContaining('0,00'), findsNothing);
    });

    testWidgets('офлайн: «Мой долг» скрыт, баннер офлайна, каталог из кэша', (tester) async {
      final FakeCatalogRepository repo = FakeCatalogRepository()
        ..cached = Success<CatalogPage<ProductSummary>>(page(customerItems(), source: DataSource.cache))
        ..networkPages.add(const FailureResult<CatalogPage<ProductSummary>>(kOffline));
      await pumpHome(tester, HomeHarness(catalog: repo));
      expect(find.byKey(CustomerHomeKeys.offlineBanner), findsOneWidget);
      expect(find.byKey(CustomerHomeKeys.debt), findsNothing);
      expect(find.byType(ProductCardGrid), findsWidgets);
    });
  });

  group('действия', () {
    testWidgets('избранное: звезда карточки → порт избранного; карточка «Избранное» — число и переход', (tester) async {
      final HomeHarness h = HomeHarness();
      await pumpHome(tester, h, size: kTallCompact);
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
}
