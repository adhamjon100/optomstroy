// Шапка сотрудника medium+ сжимается по доступной ширине, а не по классу окна (ADR-112 «паритет функций, раунд 2»;
// 02 §3.1 п. 7, SCR-10.3 A2–A8; 03 §9.57 `TopAppBarFit`):
// - при непустой корзине (настоящий `CartHeaderButtonView` на фейковом `CartSync`), `SyncIndicator` (в норме — иконка,
//   без сети — иконка с текстом) и длинном имени строка шапки не переполняется, поле поиска не уже 240 lp, а пока у
//   аватара видны имя или роль — не уже 320 lp (QA паритета функций); время, итог корзины, колокольчик и аватар видны
//   всегда — на /orders (продавец), /cashier (кассир, полная дата) и SCR-10;
// - свёрнутое не пропадает: дата — в тултипе и `Semantics`, единицы корзины — в тултипе, имя и роль — в `Semantics`;
// - порядок сворачивания: строка «Корзина · N шт» → роль → имя → «Оптомстрой» → полная дата «Кассы» → короткая →
//   дата; затем узкие зазоры, затем поле поиска второй строкой;
// - на «Кассе» при medium дата видна второй строкой часов, пока хватает места (UI-30-013, AC-UI-30-020).
// Шрифт Inter загружается из assets/fonts (ширины текста — как в приложении). Синтетические данные, без сети.
// Тест-кейсы 12_TEST_PLAN: T-UI-115 (сжатие шапки по ширине), T-CART-037.
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/app/router/shells/app_shell.dart';
import 'package:optomstroy/app/router/shells/shell_tab.dart';
import 'package:optomstroy/app/router/shells/staff_shell_header.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart' show OnlineStatus;
import 'package:optomstroy/core/di/core_providers.dart' show clockProvider;
import 'package:optomstroy/core/enums.dart' show RoleCode;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/notification_bell.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/components/search_bar.dart';
import 'package:optomstroy/design_system/components/sync_indicator.dart';
import 'package:optomstroy/design_system/components/top_app_bar_pos.dart';
import 'package:optomstroy/design_system/layout/shell_scope.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_header_button_view.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart' show catalogViewerRoleProvider;
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_screen.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_header.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_logo.dart';

import '../design_system/ds_test_support.dart' show loadInterFont;
import '../features/cart/support/cart_test_support.dart';
import '../features/catalog/presentation/support/catalog_fakes.dart';
import '../support/f_fakes.dart';

/// 09:41 по Бишкеку, четверг 22 октября 2026.
final DateTime _now = DateTime.utc(2026, 10, 22, 3, 41);

const String _name = 'Абдулла Каримов';

/// Пути веток (как в routes.dart).
const Map<ShellBranch, List<String>> _branchPaths = <ShellBranch, List<String>>{
  ShellBranch.catalog: <String>['/catalog'],
  ShellBranch.home: <String>['/home'],
  ShellBranch.favorites: <String>['/favorites'],
  ShellBranch.cart: <String>['/cart'],
  ShellBranch.customers: <String>['/customers'],
  ShellBranch.cashier: <String>['/cashier'],
  ShellBranch.transactions: <String>['/transactions'],
  ShellBranch.orders: <String>['/orders'],
  ShellBranch.admin: <String>['/admin/users'],
  ShellBranch.profile: <String>['/profile'],
  ShellBranch.reports: <String>['/reports'],
};

GoRouter _router(String initial) => GoRouter(
  initialLocation: initial,
  routes: <RouteBase>[
    StatefulShellRoute.indexedStack(
      builder: (BuildContext context, GoRouterState state, StatefulNavigationShell shell) =>
          AppShell(navigationShell: shell),
      branches: <StatefulShellBranch>[
        for (final ShellBranch b in ShellBranch.values)
          StatefulShellBranch(
            routes: <RouteBase>[
              for (final String p in _branchPaths[b]!)
                GoRoute(
                  path: p,
                  builder: (BuildContext context, GoRouterState state) => Scaffold(body: Text('page:$p')),
                ),
            ],
          ),
      ],
    ),
  ],
);

/// Цель проверки: шапка оболочки на ветке или шапка экрана каталога.
enum _Target { orders, cashier, catalog }

/// `SyncIndicator` шапки: в норме — только иконка (как `ConnectedSyncIndicator(adaptive: true)`), без сети — иконка
/// с текстом.
Widget _sync({required bool offline}) => offline
    ? SyncIndicator(variant: SyncIndicatorVariant.offline, onTap: () {})
    : SyncIndicator(variant: SyncIndicatorVariant.ok, compact: true, time: _now, now: _now, onTap: () {});

void _window(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Поднимает цель [t] в окне шириной [width] с непустой корзиной (5 поз. · 6 ед., 16 007,50 сом).
Future<void> _pump(WidgetTester tester, _Target t, double width, {bool offline = false, double height = 900}) async {
  _window(tester, Size(width, height));
  final FakeCartRepository repo = FakeCartRepository();
  final FakeCartSync sync = FakeCartSync(repo);
  repo.onListParked = (ParkedScope scope, String? cursor) async =>
      const Success<PageResult<CartParkedSummary>>(PageResult<CartParkedSummary>(items: <CartParkedSummary>[]));
  serveCart(repo, canonCart());
  final RoleCode role = t == _Target.cashier ? RoleCode.cashier : RoleCode.seller;
  // Как `cartOverrides`, но без часов: часы шапки — 09:41 по Бишкеку (у обвязки каталога — свои).
  final List<Override> header = <Override>[
    cartSyncProvider.overrideWithValue(sync),
    cartRepositoryProvider.overrideWithValue(repo),
    cartViewerRoleProvider.overrideWithValue(role),
    cartViewerUserIdProvider.overrideWithValue('user-1'),
    cartOnlineStatusProvider.overrideWithValue(OnlineStatus.online),
    catalogCartButtonProvider.overrideWithValue((BuildContext context) => const CartHeaderButtonView()),
    catalogSyncIndicatorProvider.overrideWithValue((BuildContext context) => _sync(offline: offline)),
  ];
  if (t == _Target.catalog) {
    // Часы обвязки каталога — `kNow`, те же 09:41 по Бишкеку.
    final CatalogHarness h = CatalogHarness(name: _name, extra: header);
    await tester.pumpWidget(
      catalogApp(
        h,
        home: DsShellScope(openNavigation: () {}, child: const CatalogScreen()),
      ),
    );
    await settle(tester, frames: 10);
    return;
  }
  final GoRouter router = _router(t == _Target.cashier ? '/cashier' : '/orders');
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appModeProvider.overrideWithValue(t == _Target.cashier ? AppMode.cashier : AppMode.seller),
        catalogViewerRoleProvider.overrideWithValue(role),
        clockProvider.overrideWithValue(FixedClock(_now)),
        catalogViewerNameProvider.overrideWithValue(_name),
        ...header,
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: AppTheme.light(),
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (BuildContext context, Widget? child) =>
            ProductImageScope(providerFor: transparentImage, child: child!),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get _header => find.byType(TopAppBarPos);

Finder _in(Finder f) => find.descendant(of: _header, matching: f);

Finder get _search => _in(find.byType(SearchBar));

Finder get _cart => find.byKey(CartHeaderButtonView.buttonKey);

final String _total = PriceText.format(const Money(1600750), fixed2: true);

/// Ступень шапки (для сообщений и проверок порядка).
TopAppBarFit _fit(WidgetTester tester) => TopAppBarFit.of(tester.element(_in(find.byType(CatalogHeaderClock))));

/// Общие проверки: нет переполнения, поле поиска ≥ 240 и не перекрывает правую группу, обязательное видно.
void _expectFits(WidgetTester tester, String why) {
  expect(tester.takeException(), isNull, reason: '$why: без переполнения строки');
  expect(_search, findsOneWidget, reason: why);
  final Rect search = tester.getRect(_search);
  expect(
    search.width,
    greaterThanOrEqualTo(TopAppBarPos.searchMinWidth),
    reason: '$why: поле поиска не уже минимума (${_fit(tester)})',
  );
  // Пока у аватара видны имя или роль, поле в строке не уже 320: имя сворачивается раньше, чем поле сжимается до
  // минимума (поиск — главный элемент шапки; QA паритета функций, ADR-112).
  final TopAppBarFit fit = _fit(tester);
  if (fit.user != TopAppBarUserFit.none && !fit.searchBelow) {
    expect(
      search.width,
      greaterThanOrEqualTo(TopAppBarPos.searchComfortWidth),
      reason: '$why: при видимом имени поле поиска не уже ${TopAppBarPos.searchComfortWidth} ($fit)',
    );
  }
  final double windowWidth = tester.view.physicalSize.width;
  final List<(String, Finder)> fixed = <(String, Finder)>[
    ('часы', _in(find.text('09:41'))),
    ('итог корзины', find.descendant(of: _cart, matching: find.text(_total))),
    ('колокольчик', _in(find.byType(NotificationBell))),
    ('аватар', _in(find.byType(TopAppBarUser))),
    ('синхронизация', _in(find.byType(SyncIndicator))),
    ('«бургер»', _in(find.byKey(const ValueKey<String>('top-app-bar-menu')))),
  ];
  for (final (String what, Finder f) in fixed) {
    expect(f, findsOneWidget, reason: '$why: $what виден всегда');
    final Rect r = tester.getRect(f);
    expect(r.right, lessThanOrEqualTo(windowWidth + 0.5), reason: '$why: $what в пределах окна');
    expect(r.overlaps(search), isFalse, reason: '$why: поле поиска не перекрывает элемент «$what»');
  }
}

void main() {
  setUpAll(loadInterFont);

  group('без переполнения и с полем поиска ≥ 240 при непустой корзине', () {
    for (final _Target t in _Target.values) {
      for (final bool offline in <bool>[false, true]) {
        for (final double w in const <double>[600, 650, 700, 760, 840, 900, 960, 1024, 1100, 1180, 1280, 1366, 1440]) {
          final String why = '${t.name} ${w.toInt()} lp${offline ? ', без сети' : ''}';
          testWidgets(why, (tester) async {
            await _pump(tester, t, w, offline: offline);
            _expectFits(tester, why);
          });
        }
      }
    }
  });

  testWidgets('1440 lp: ничего не свёрнуто — «Корзина · 6 шт», дата, имя и роль, «Оптомстрой», поле в строке', (
    tester,
  ) async {
    await _pump(tester, _Target.orders, 1440);
    expect(_fit(tester), TopAppBarFit.full);
    expect(find.descendant(of: _cart, matching: find.textContaining('Корзина · 6')), findsOneWidget);
    expect(_in(find.text('чт, 22 окт')), findsOneWidget);
    expect(_in(find.text(_name)), findsOneWidget);
    expect(_in(find.text('Продавец')), findsOneWidget);
    expect(_in(find.text(kCatalogBrandWordmark)), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('top-app-bar-search-row')), findsNothing);
    expect(tester.getSize(_header).height, 68);
  });

  testWidgets('«Касса» 1280 lp: полная дата «Чт, 22 октября 2026» видна рядом с корзиной (UI-30-013)', (tester) async {
    await _pump(tester, _Target.cashier, 1280);
    expect(_in(find.text('Чт, 22 октября 2026')), findsOneWidget);
    _expectFits(tester, 'cashier 1280');
  });

  for (final double w in const <double>[800, 840, 900]) {
    testWidgets('«Касса» medium ${w.toInt()} lp: дата видна второй строкой часов (UI-30-013, AC-UI-30-020)', (
      tester,
    ) async {
      await _pump(tester, _Target.cashier, w);
      expect(
        find.descendant(
          of: find.byType(CatalogHeaderClock),
          matching: find.byKey(const ValueKey<String>('top-app-bar-clock-date')),
        ),
        findsOneWidget,
        reason: 'дата видна (${_fit(tester)})',
      );
      expect(find.bySemanticsLabel('09:41, Чт, 22 октября 2026'), findsOneWidget, reason: 'полная дата — в Semantics');
      _expectFits(tester, 'cashier $w');
    });
  }

  testWidgets('свёрнутое не пропадает: дата — в тултипе и Semantics, единицы — в тултипе корзины, имя — в Semantics', (
    tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _pump(tester, _Target.orders, 700);
    final TopAppBarFit fit = _fit(tester);
    expect(fit.cartLabel, isFalse, reason: '700 lp с корзиной: строка «Корзина · 6 шт» свёрнута');
    expect(find.descendant(of: _cart, matching: find.textContaining('Корзина')), findsNothing);
    // Единицы корзины (`unitsText`, у строк фейка без подписи единицы — «6») — в тултипе кнопки-итога.
    expect(
      find.descendant(
        of: _cart,
        matching: find.byWidgetPredicate((Widget w) => w is Tooltip && (w.message ?? '').startsWith('5 поз. · 6')),
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(RegExp('^Профиль: $_name, Продавец')), findsOneWidget);
    expect(find.bySemanticsLabel('09:41, чт, 22 окт'), findsOneWidget);
    if (fit.date == TopAppBarDateFit.none) {
      expect(
        find.descendant(
          of: find.byType(CatalogHeaderClock),
          matching: find.byWidgetPredicate((Widget w) => w is Tooltip && w.message == 'чт, 22 окт'),
        ),
        findsOneWidget,
      );
    }
    semantics.dispose();
  });

  testWidgets('600 lp с корзиной: поле поиска второй строкой на всю ширину, шапка 124, состояние поля сохраняется', (
    tester,
  ) async {
    await _pump(tester, _Target.orders, 600);
    expect(_fit(tester).searchBelow, isTrue);
    expect(find.byKey(const ValueKey<String>('top-app-bar-search-row')), findsOneWidget);
    expect(tester.getSize(_header).height, 68 + TopAppBarPos.searchRowHeight);
    expect(tester.getTopLeft(_search).dy, greaterThanOrEqualTo(tester.getTopLeft(_header).dy + 66));
    // Ввод и фокус переживают смену ступени (поле переносится по ключу): окно шире — поле снова в строке.
    await tester.enterText(find.byKey(StaffShellHeader.searchFieldKey), 'смес');
    await tester.pump();
    _window(tester, const Size(1440, 900));
    await tester.pump();
    expect(_fit(tester).searchBelow, isFalse);
    expect(find.byKey(const ValueKey<String>('top-app-bar-search-row')), findsNothing);
    final EditableText field = tester.widget<EditableText>(
      find.descendant(of: _search, matching: find.byType(EditableText)),
    );
    expect(field.controller.text, 'смес');
    expect(field.focusNode.hasFocus, isTrue, reason: 'фокус остаётся в поле');
    expect(tester.takeException(), isNull);
  });

  test('порядок сворачивания: «Корзина · N шт» → роль → имя → «Оптомстрой» → полная дата → дата; затем зазоры и '
      'вторая строка поиска', () {
    final List<TopAppBarFit> l = TopAppBarFit.ladder;
    expect(l.first, TopAppBarFit.full);
    final List<TopAppBarFit> inline = l.where((TopAppBarFit f) => !f.searchBelow && !f.tight).toList();
    expect(inline.map((TopAppBarFit f) => (f.cartLabel, f.user, f.wordmark, f.date)), <Object>[
      (true, TopAppBarUserFit.full, true, TopAppBarDateFit.full),
      (false, TopAppBarUserFit.full, true, TopAppBarDateFit.full),
      (false, TopAppBarUserFit.short, true, TopAppBarDateFit.full),
      (false, TopAppBarUserFit.none, true, TopAppBarDateFit.full),
      (false, TopAppBarUserFit.none, false, TopAppBarDateFit.full),
      (false, TopAppBarUserFit.none, false, TopAppBarDateFit.short),
      (false, TopAppBarUserFit.none, false, TopAppBarDateFit.none),
    ]);
    // Каждая ступень сведений — сначала с обычными зазорами, затем с узкими; поле второй строкой — после всех.
    expect(l[1], const TopAppBarFit(tight: true));
    expect(l.indexWhere((TopAppBarFit f) => f.searchBelow), 14);
    expect(
      l.last,
      const TopAppBarFit(
        cartLabel: false,
        user: TopAppBarUserFit.none,
        wordmark: false,
        date: TopAppBarDateFit.none,
        tight: true,
        searchBelow: true,
        logo: false,
      ),
    );
    expect(TopAppBarFit.ladderNoSearch.any((TopAppBarFit f) => f.searchBelow), isFalse);
  });

  testWidgets('окно сужается — шапка сворачивает больше в том же кадре; расширяется — разворачивает обратно', (
    tester,
  ) async {
    await _pump(tester, _Target.catalog, 1280);
    final TopAppBarFit before = _fit(tester);
    _expectFits(tester, 'SCR-10 1280');
    // Окно уже на 120 lp: шапка сворачивает больше, без переполнения; обратно — как было.
    _window(tester, const Size(1160, 900));
    await tester.pump();
    expect(TopAppBarFit.ladder.indexOf(_fit(tester)), greaterThanOrEqualTo(TopAppBarFit.ladder.indexOf(before)));
    _expectFits(tester, 'SCR-10 1160');
    _window(tester, const Size(1280, 900));
    await tester.pump();
    expect(_fit(tester), before);
    _expectFits(tester, 'SCR-10 1280 снова');
    expect(_in(find.byType(CatalogLogo)), findsOneWidget);
  });
}
