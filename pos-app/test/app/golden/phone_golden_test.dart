// T-UI-118, T-UI-119 (golden): телефон (compact < 600 lp) по 15 ADR-122 — шапка прототипа у всех ролей (логотип ·
// корзина с числом позиций · синхронизация · колокольчик со счётчиком · аватар с инициалами; поле поиска со сканером
// второй строкой, в ландшафте — в строке), каталог SCR-10 сеткой в 2 колонки (с 360 lp; уже — список), меню профиля
// нижним листом («История заказов», «Избранное», затем прежние пункты). Ширины 320, 360, 412, 480 (390 — эталоны
// `catalog_scr10_catalog_compact`, `home_scr50_compact`), ландшафт 568×320, масштаб текста 1,5 на 360; AC-ADR-122 (2).
// Палитра B, reduce-motion, синтетические данные. Эталоны kiosk и medium+ этим файлом не затрагиваются.
//
// Обновить эталоны: flutter test test/app/golden --update-goldens
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/app/router/shells/app_shell.dart';
import 'package:optomstroy/app/router/shells/shell_tab.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' show RoleCode;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_screen.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_phone_header.dart';
import 'package:optomstroy/features/profile/presentation/widgets/profile_menu_sheet.dart';
import 'package:optomstroy/features/profile/profile_providers.dart';
import 'package:optomstroy/features/sync_status/presentation/widgets/sync_connected_widgets.dart';

import '../../features/catalog/presentation/support/catalog_fakes.dart';
import '../../features/profile/presentation/profile_screen_test.dart' show FakeProfileRepository, TestSession, seedMe;

List<ProductSummary> _items() => <ProductSummary>[
  product(1, name: 'Смеситель для кухни Frap F4252 хром', sku: 'F4252-CR', priceSom: 2350, available: 24),
  product(2, name: 'Смеситель для ванной Grohe Eurosmart', sku: 'GR-33265', priceSom: 7850, available: 3),
  product(3, name: 'Унитаз-компакт Santek Бриз с сиденьем', sku: 'SN-1WH302', priceSom: 9400),
  product(4, name: 'Труба полипропиленовая PN20 20 мм', noSku: true, priceSom: 95, available: 860),
];

CatalogHarness _harness() {
  final FakeCatalogRepository repo = FakeCatalogRepository();
  repo.networkPages.add(Success<CatalogPage<ProductSummary>>(page(_items(), total: 124)));
  return CatalogHarness(
    catalog: repo,
    name: 'Айбек Асанов',
    unread: 3,
    extra: <Override>[
      catalogSyncIndicatorProvider.overrideWithValue((BuildContext context) => const ConnectedSyncIndicator()),
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

Future<void> Function(WidgetTester) _scaled(double scale) => (WidgetTester tester) async {
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await _prepare(tester);
};

Widget _stub(String path) => Scaffold(
  appBar: AppBar(title: Text(path == '/orders' ? 'Заказы' : path)),
  body: const SizedBox.expand(),
);

/// Оболочка кассира на `/orders` с простыми страницами (лист профиля открывается в [_openSheet]).
Widget _shell(Size size) {
  final GoRouter router = GoRouter(
    initialLocation: '/orders',
    routes: <RouteBase>[
      StatefulShellRoute.indexedStack(
        builder: (BuildContext context, GoRouterState state, StatefulNavigationShell shell) =>
            AppShell(navigationShell: shell),
        branches: <StatefulShellBranch>[
          for (final ShellBranch b in ShellBranch.values)
            StatefulShellBranch(
              routes: <RouteBase>[
                GoRoute(
                  path: switch (b) {
                    ShellBranch.admin => '/admin/users',
                    _ => '/${b.name}',
                  },
                  builder: (BuildContext context, GoRouterState state) => _stub(state.uri.path),
                ),
              ],
            ),
        ],
      ),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      // ignore: riverpod_lint/scoped_providers_should_specify_dependencies — корневой ProviderScope сцены эталона (alchemist строит его в builder, а не в pumpWidget)
      appModeProvider.overrideWithValue(AppMode.cashier),
      catalogViewerRoleProvider.overrideWithValue(RoleCode.cashier),
      catalogViewerNameProvider.overrideWithValue('Айбек Асанов'),
      catalogUnreadNotificationsProvider.overrideWithValue(3),
      catalogProfileSheetProvider.overrideWithValue(
        (BuildContext context, String name, String role) => showProfileMenuSheet(context, name: name, role: role),
      ),
      profileRepositoryProvider.overrideWithValue(
        FakeProfileRepository(profile: seedMe(roles: <RoleCode>[RoleCode.cashier])),
      ),
      clockProvider.overrideWithValue(FixedClock(DateTime.utc(2026, 11, 23, 9))),
      onlineStatusProvider.overrideWith((Ref ref) => Stream<OnlineStatus>.value(OnlineStatus.online)),
      sessionControllerProvider.overrideWith(TestSession.new),
    ],
    child: MaterialApp.router(
      routerConfig: router,
      theme: AppTheme.light(),
      locale: const Locale('ru'),
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true, size: size, padding: EdgeInsets.zero),
        child: child!,
      ),
    ),
  );
}

Future<void> _openSheet(WidgetTester tester) async {
  await _prepare(tester);
  await tester.tap(find.byKey(CatalogPhoneHeader.avatarKey));
  for (int i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(() => EditableText.debugDeterministicCursor = true);
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  // SCR-10 продавца: ширины телефона (390 — `catalog_scr10_catalog_compact`), ландшафт, масштаб текста 1,5.
  final Map<String, (Size, double)> windows = <String, (Size, double)>{
    '320': (const Size(320, 700), 1),
    '360': (const Size(360, 780), 1),
    '412': (const Size(412, 915), 1),
    '480': (const Size(480, 900), 1),
    'landscape_568x320': (const Size(568, 320), 1),
    '360_text150': (const Size(360, 780), 1.5),
  };
  for (final MapEntry<String, (Size, double)> w in windows.entries) {
    final Size size = w.value.$1;
    unawaited(
      goldenTest(
        'phone scr10 · ${w.key}',
        fileName: 'phone_scr10_${w.key}',
        constraints: BoxConstraints.tight(size),
        pumpBeforeTest: _scaled(w.value.$2),
        builder: () => SizedBox(
          width: size.width,
          height: size.height,
          child: catalogApp(_harness(), home: const CatalogScreen(), size: size),
        ),
      ),
    );
  }

  // Аватар → лист профиля (кассир): карточка, «История заказов», «Избранное», затем прежние пункты.
  const Size sheet = Size(390, 844);
  unawaited(
    goldenTest(
      'phone profile sheet · cashier 390',
      fileName: 'phone_profile_sheet_cashier_390',
      constraints: BoxConstraints.tight(sheet),
      pumpBeforeTest: _openSheet,
      builder: () => SizedBox(width: sheet.width, height: sheet.height, child: _shell(sheet)),
    ),
  );

  // Шапка оболочки над SCR-25 (кассир, 360): строка заголовка экрана — под шапкой телефона.
  const Size orders = Size(360, 780);
  unawaited(
    goldenTest(
      'phone shell header · cashier 360',
      fileName: 'phone_shell_orders_cashier_360',
      constraints: BoxConstraints.tight(orders),
      pumpBeforeTest: _prepare,
      builder: () => SizedBox(width: orders.width, height: orders.height, child: _shell(orders)),
    ),
  );
}
