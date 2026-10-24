// Обвязка тестов SCR-50 «Главный экран клиента» (RM-E-017). Данные синтетические (на фейках, не реальная
// интеграция): товары «Смеситель …», вид цены «Оптовая», цены — целые тыйыны (D-19).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/shells/customer_mode_bindings.dart';
import 'package:optomstroy/core/enums.dart' show CustomerLinkStatus, CustomerStockDisplay, RoleCode;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/providers/customer_mode_ports.dart';
import 'package:optomstroy/features/home/home_providers.dart';
import 'package:optomstroy/features/home/presentation/screens/customer_home_screen.dart';

import '../../catalog/presentation/support/catalog_fakes.dart';

export '../../catalog/presentation/support/catalog_fakes.dart';

/// Товар каталога клиента. По умолчанию — как отвечает сервер при `customer_stock_display=status`:
/// `available` нет (08 API-180), вид цены клиента «Оптовая».
ProductSummary customerProduct(
  int i, {
  String? name,
  String? sku,
  int priceSom = 2100,
  StockLevel level = StockLevel.inStock,
  int? available,
  bool hasVariants = false,
  int? variantCount,
  bool noStock = false,
}) => ProductSummary(
  id: 'p$i',
  name: name ?? 'Смеситель для кухни Frap F42${i.toString().padLeft(2, '0')}',
  sku: sku ?? 'F42${i.toString().padLeft(2, '0')}-CR',
  categoryId: 'c-mix',
  brand: i.isEven ? 'Frap' : 'Grohe',
  hasVariants: hasVariants,
  variantCount: variantCount,
  defaultVariantId: 'v$i',
  baseUnit: kPiece,
  price: Price(priceListId: 'pl-wholesale', priceListName: 'Оптовая', amount: Money.som(priceSom)),
  priceRange: hasVariants ? MoneyRange(min: Money.som(priceSom), max: Money.som(priceSom + 400)) : null,
  stock: noStock
      ? null
      : StockBalance(
          variantId: 'v$i',
          warehouseId: 'w-main',
          stockLevel: level,
          available: available == null ? null : Qty.units(available),
          asOf: kNow.subtract(const Duration(minutes: 5)),
        ),
);

/// Витрина SCR-50 (golden и виджет-тесты).
List<ProductSummary> customerItems() => <ProductSummary>[
  customerProduct(1, name: 'Смеситель для кухни Frap F4252 хром', sku: 'F4252-CR', priceSom: 2100),
  customerProduct(
    2,
    name: 'Смеситель для ванной Grohe Eurosmart',
    sku: 'GR-33265',
    priceSom: 7300,
    level: StockLevel.low,
  ),
  customerProduct(3, name: 'Унитаз-компакт Santek Бриз', sku: 'SN-1WH302', priceSom: 8900, level: StockLevel.out),
  customerProduct(
    4,
    name: 'Смеситель Ledeme L74103',
    sku: 'L74103',
    priceSom: 1550,
    hasVariants: true,
    variantCount: 3,
  ),
  customerProduct(5, name: 'Труба полипропиленовая PN20 20 мм', sku: 'PPR-20', priceSom: 85),
  customerProduct(6, name: 'Сифон для раковины Ani Plast', sku: 'C1010', priceSom: 300),
];

/// Фейк сводки «Мой кабинет».
final class FakeCustomerHomePort implements CustomerHomePort {
  FakeCustomerHomePort([this.value = const CustomerHomeSummary()]);

  CustomerHomeSummary value;
  int calls = 0;

  @override
  Future<Result<CustomerHomeSummary>> summary() async {
    calls++;
    return Success<CustomerHomeSummary>(value);
  }
}

/// Привязка клиента подтверждена: 2 заказа в работе, долг 7 900 сом.
const CustomerHomeSummary kLinkedSummary = CustomerHomeSummary(
  linkStatus: CustomerLinkStatus.confirmed,
  customerId: 'cust-1',
  activeOrders: 2,
  debt: Money(790000),
);

/// Обвязка SCR-50: фейки каталога (роль `customer`) + порты режима клиента.
final class HomeHarness {
  HomeHarness({
    FakeCatalogRepository? catalog,
    FakeShelfPort? shelf,
    bool noShelf = false,
    FakeCustomerHomePort? port,
    this.display = CustomerStockDisplay.status,
    this.selfService = true,
    this.cartCount = 0,
    this.bindBody = true,
  }) : catalog = catalog ?? FakeCatalogRepository(items: customerItems()),
       shelf = noShelf
           ? null
           : (shelf ??
                 FakeShelfPort(
                   favorites: <String>{'p1', 'p2'},
                   recent: <RecentProduct>[
                     RecentProduct(
                       product: customerProduct(2, name: 'Смеситель для ванной Grohe Eurosmart'),
                       viewedAt: kNow,
                     ),
                     RecentProduct(
                       product: customerProduct(5, name: 'Труба полипропиленовая PN20 20 мм'),
                       viewedAt: kNow,
                     ),
                   ],
                 )),
       port = port ?? FakeCustomerHomePort(kLinkedSummary);

  final FakeCatalogRepository catalog;
  final FakeShelfPort? shelf;
  final FakeCustomerHomePort port;
  final CustomerStockDisplay display;
  final bool selfService;
  final int cartCount;

  /// Привязать содержимое SCR-50 (как корень `customerModeOverrides`).
  final bool bindBody;

  late final CatalogHarness base = CatalogHarness(
    catalog: catalog,
    shelf: shelf,
    role: RoleCode.customer,
    name: null,
    unread: 0,
  );

  List<Override> get overrides => <Override>[
    ...base.overrides,
    if (bindBody) customerHomeBodyProvider.overrideWithValue(customerHomeBody),
    catalogCustomerStockDisplayProvider.overrideWithValue(display),
    catalogCustomerSelfServiceProvider.overrideWithValue(selfService),
    customerHomePortProvider.overrideWithValue(port),
    catalogCartDraftCountProvider.overrideWith((Ref ref) => Stream<int>.value(cartCount)),
  ];
}

/// Маршруты-приёмники переходов SCR-50 (каждый рисует свой адрес).
GoRouter homeRouter({String initial = '/home'}) {
  Widget probe(GoRouterState s) => Scaffold(body: Text('route:${s.uri}', key: const ValueKey<String>('route-probe')));
  GoRoute leaf(String path) => GoRoute(path: path, builder: (BuildContext c, GoRouterState s) => probe(s));
  return GoRouter(
    initialLocation: initial,
    routes: <RouteBase>[
      GoRoute(
        path: '/home',
        builder: (BuildContext c, GoRouterState s) =>
            CustomerHomeScreen(view: s.uri.queryParameters['view'], sort: s.uri.queryParameters['sort']),
      ),
      leaf('/catalog/search'),
      leaf('/catalog/c/:categoryId'),
      leaf('/catalog/p/:productId'),
      leaf('/favorites'),
      leaf('/cart'),
      leaf('/orders'),
      leaf('/customers/:customerId/receivables'),
      leaf('/register/customer-link'),
      leaf('/notifications'),
    ],
  );
}

/// Приложение SCR-50 с маршрутизатором [router] (или без него — экран в `home`).
Widget homeApp(HomeHarness h, {GoRouter? router, Size? size, List<Override> extra = const <Override>[]}) {
  Widget wrap(BuildContext context, Widget? child) {
    final MediaQueryData mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(disableAnimations: true, size: size ?? mq.size, padding: EdgeInsets.zero),
      child: ProductImageScope(providerFor: transparentImage, child: child!),
    );
  }

  return ProviderScope(
    overrides: <Override>[...h.overrides, ...extra],
    child: router != null
        ? MaterialApp.router(
            theme: AppTheme.light(),
            locale: const Locale('ru'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            debugShowCheckedModeBanner: false,
            routerConfig: router,
            builder: wrap,
          )
        : MaterialApp(
            theme: AppTheme.light(),
            locale: const Locale('ru'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            debugShowCheckedModeBanner: false,
            builder: wrap,
            home: const CustomerHomeScreen(),
          ),
  );
}

/// Закрыть фейки после теста.
void disposeHome(HomeHarness h) => unawaited(h.shelf?.dispose());
