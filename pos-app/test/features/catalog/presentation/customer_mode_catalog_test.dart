// Каталог в режиме клиента (RM-E-017; 02 ч. B вариант `customer`, SCR-50.2; 10 CUST-021, CUST-022):
// SCR-11/SCR-12 для `customer` — без часов, «бургера», сканера и постоянной корзины CP; остатки по
// `customer_stock_display`; корень каталога клиента — SCR-50 `/home`. Синтетические данные (на фейках).
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/enums.dart' show CustomerStockDisplay, RoleCode;
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/product_card.dart';
import 'package:optomstroy/design_system/components/stock_badge.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/providers/customer_mode_ports.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_search_screen.dart';
import 'package:optomstroy/features/catalog/presentation/screens/category_screen.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_card_mapper.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_header.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_logo.dart';

import 'support/catalog_fakes.dart';

GoRouter _router(String initial) => GoRouter(
  initialLocation: initial,
  routes: <RouteBase>[
    GoRoute(
      path: '/home',
      builder: (BuildContext c, GoRouterState s) => const Scaffold(body: Text('route:/home')),
    ),
    GoRoute(
      path: '/catalog/c/:categoryId',
      builder: (BuildContext c, GoRouterState s) => CategoryScreen(categoryId: s.pathParameters['categoryId']!),
    ),
    GoRoute(
      path: '/catalog/search',
      builder: (BuildContext c, GoRouterState s) => CatalogSearchScreen(q: s.uri.queryParameters['q']),
    ),
  ],
);

Future<void> _pump(
  WidgetTester tester,
  CatalogHarness h, {
  required String initial,
  Size size = kExpanded,
  CustomerStockDisplay display = CustomerStockDisplay.status,
}) async {
  setWindow(tester, size);
  final GoRouter router = _router(initial);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[...h.overrides, catalogCustomerStockDisplayProvider.overrideWithValue(display)],
      child: MaterialApp.router(
        theme: AppTheme.light(),
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true, size: size),
          child: child!,
        ),
      ),
    ),
  );
  await settle(tester, frames: 10);
}

void main() {
  testWidgets('SCR-12 customer (E): без часов, «бургера», сканера и CP; логотип → /home', (tester) async {
    await _pump(tester, CatalogHarness(role: RoleCode.customer), initial: '/catalog/c/c-mix');
    expect(find.byType(CatalogHeaderClock), findsNothing);
    expect(find.byIcon(Icons.menu_rounded), findsNothing);
    expect(find.byTooltip('Сканировать штрихкод'), findsNothing);
    expect(find.byKey(const ValueKey<String>('catalog-cart-panel')), findsNothing);
    expect(find.byType(ProductCardGrid), findsWidgets);

    await tester.tap(find.byType(CatalogLogo));
    await settle(tester);
    expect(find.text('route:/home'), findsOneWidget);
  });

  testWidgets('seller (E) — часы, «бургер» и CP на месте (регрессия staff)', (tester) async {
    await _pump(tester, CatalogHarness(), initial: '/catalog/c/c-mix');
    expect(find.byType(CatalogHeaderClock), findsOneWidget);
    expect(find.byIcon(Icons.menu_rounded), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('catalog-cart-panel')), findsOneWidget);
  });

  testWidgets('SCR-11 customer: status — «В наличии» без чисел; quantity — «В наличии · N шт», без «Резерв»', (
    tester,
  ) async {
    await _pump(
      tester,
      CatalogHarness(role: RoleCode.customer),
      initial: '/catalog/search?q=F4252',
      size: kCompact,
    );
    StockBadge first() => tester.widget<StockBadge>(
      find.descendant(of: find.byKey(const ValueKey<String>('product-p1')), matching: find.byType(StockBadge)),
    );
    expect(first().label, 'В наличии', reason: 'текстовый статус наличия (AC-UI-50-004, 03 §9.17)');
    expect(find.textContaining('24 шт'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await _pump(
      tester,
      CatalogHarness(role: RoleCode.customer),
      initial: '/catalog/search?q=F4252',
      size: kCompact,
      display: CustomerStockDisplay.quantity,
    );
    expect(first().label, 'В наличии · 24 шт');
    expect(find.textContaining('Резерв'), findsNothing);
  });

  testWidgets('запрос категории клиента — без priceListId (вид цены выбирает сервер)', (tester) async {
    final CatalogHarness h = CatalogHarness(role: RoleCode.customer);
    await _pump(tester, h, initial: '/catalog/c/c-mix');
    expect(h.catalog.productCalls, isNotEmpty);
    for (final CatalogQuery q in h.catalog.productCalls) {
      expect(q.filter.priceListId, isNull);
    }
  });

  test('CatalogCardContext: числа остатка — staff всегда, customer — только при quantity', () async {
    final AppLocalizations l10n = await AppLocalizations.delegate.load(const Locale('ru'));
    final ProductSummary p = product(1, available: 24);
    String label(RoleCode role, CustomerStockDisplay d) =>
        CatalogCardMapper.stock(CatalogCardContext(l10n: l10n, now: kNow, role: role, customerStockDisplay: d), p).$2;
    expect(label(RoleCode.seller, CustomerStockDisplay.status), 'В наличии · 24 шт');
    expect(label(RoleCode.customer, CustomerStockDisplay.status), 'В наличии');
    expect(label(RoleCode.customer, CustomerStockDisplay.quantity), 'В наличии · 24 шт');
    expect(
      CatalogCardMapper.stock(
        CatalogCardContext(
          l10n: l10n,
          now: kNow,
          role: RoleCode.customer,
          customerStockDisplay: CustomerStockDisplay.quantity,
        ),
        product(2, level: StockLevel.out),
      ).$2,
      'Нет в наличии',
    );
  });
}
