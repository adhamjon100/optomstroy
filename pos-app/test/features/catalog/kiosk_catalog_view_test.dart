// SCR-51 «Планшет магазина: витрина и корзина» — тело витрины фичи catalog (02 ч. F SCR-51; P-002 §8.8; ADR-115 п. 8,
// 22, 23; 13 TAB-2-03): экран выбора товаров ADR-114 в варианте покупателя без элементов сотрудника и личных данных,
// состояние — только в памяти, стартовая категория — корень с наибольшим числом товаров, слой карточки товара без
// маршрута, без «Недавних» и избранного, наличие по `customer_stock_display`, без связи — баннер и недоступное
// «+ Добавить». Тесты 12: T-KIOSK-009 (UI), T-KIOSK-029 (поиск), T-KIOSK-032, T-KIOSK-050 (баннер `426` под шапкой,
// UI-51-014). Данные синтетические (фейки каталога).
import 'dart:async';

import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/shells/customer_mode_bindings.dart';
import 'package:optomstroy/app/router/shells/kiosk_mode_bindings.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' show CustomerStockDisplay, RoleCode;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/app_localizations_ru.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/notification_bell.dart';
import 'package:optomstroy/design_system/components/private_input_scope.dart';
import 'package:optomstroy/design_system/components/product_card.dart';
import 'package:optomstroy/design_system/components/quantity_stepper.dart';
import 'package:optomstroy/design_system/components/search_bar.dart';
import 'package:optomstroy/design_system/components/stock_badge.dart';
import 'package:optomstroy/design_system/components/top_app_bar_pos.dart';
import 'package:optomstroy/design_system/components/view_mode_segmented.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/data/local/catalog_offline_bindings.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/entities/search.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_user_settings_store.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/providers/customer_mode_ports.dart';
import 'package:optomstroy/features/catalog/presentation/screens/kiosk_catalog_view.dart';
import 'package:optomstroy/features/catalog/presentation/state/catalog_prefs.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_card_mapper.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_search_parts.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/kiosk_catalog_header.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/kiosk_product_sheet.dart';
import 'package:optomstroy/features/kiosk/presentation/emergency_exit_screen.dart';
import 'package:optomstroy/features/product_details/presentation/widgets/product_favorite_toggle.dart';
import 'package:optomstroy/features/product_details/product_details_providers.dart' as product_details;

import '../product_details/product_fixtures.dart' as pd;
import 'presentation/support/catalog_fakes.dart';

/// Корзина витрины: считает «+ Добавить».
final class _CountingCart implements CatalogCartPort {
  final List<String> added = <String>[];
  Result<void> result = const Success<void>(null);

  @override
  Future<Result<void>> add(ProductSummary product) async {
    added.add(product.id);
    return result;
  }

  @override
  String? rejectionText(Failure failure, AppLocalizations l10n) =>
      failure is NetworkFailure ? l10n.cart_header_save_failed : null;
}

/// Корзина слоя карточки, которая отказывает каждому «В корзину».
final class _FailingCart implements CartDraftRepository {
  _FailingCart(this.failure);

  final Failure failure;
  final pd.FakeCartDraftRepository _base = pd.FakeCartDraftRepository();
  int calls = 0;

  @override
  Future<Result<CartDraftLine>> add(CartDraftAdd add) async {
    calls++;
    return FailureResult<CartDraftLine>(failure);
  }

  @override
  Future<Result<CartDraftLine?>> line(String variantId, {String? packagingId}) =>
      _base.line(variantId, packagingId: packagingId);

  @override
  Future<Result<List<CartDraftLine>>> lines() => _base.lines();

  @override
  Future<Result<CartDraftLine?>> setQuantity(String variantId, {String? packagingId, required Qty quantity}) =>
      _base.setQuantity(variantId, packagingId: packagingId, quantity: quantity);

  @override
  Stream<List<CartDraftLine>> watchLines() => _base.watchLines();

  @override
  Future<Result<String?>> warehouseId() => _base.warehouseId();
}

/// Хранилище настроек каталога: любая запись — нарушение KIOSK-021 (история поиска, вид, сортировка, корень).
final class _RecordingSettingsStore implements CatalogUserSettingsStore {
  final List<String> writes = <String>[];

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value, {required CatalogSettingScope scope}) async => writes.add(key);

  @override
  Future<void> remove(String key) async => writes.add('remove:$key');
}

/// Сеть экрана, переключаемая тестом (T-KIOSK-032).
final class _Online extends Notifier<OnlineStatus> {
  _Online(this.initial);

  final OnlineStatus initial;

  @override
  OnlineStatus build() => initial;

  void set(OnlineStatus value) => state = value;
}

final class _Preset extends PublicSettingsController {
  _Preset(this.preset);

  final PublicSettingsSnapshot preset;

  @override
  PublicSettingsSnapshot build() => preset;
}

/// Ключ фейковой кнопки корзины шапки (порт `catalogCartButtonProvider`).
const Key _cartButtonKey = ValueKey<String>('fake-cart-button');

/// Ключ обёртки логотипа (порт аварийного выхода).
const Key _logoWrapperKey = ValueKey<String>('fake-emergency-exit');

List<Override> _kioskOverrides(
  CatalogHarness h, {
  _CountingCart? cart,
  CustomerStockDisplay display = CustomerStockDisplay.status,
  NotifierProvider<_Online, OnlineStatus>? online,
  bool orderingBlocked = false,
  bool updateNeeded = false,
  Future<void> Function()? startOver,
  CatalogUserSettingsStore? store,
  CatalogKioskLogoWrapper? logoWrapper,
}) => <Override>[
  // Как `CatalogHarness.overrides`, но сеть экрана — из теста; порта избранного и недавних у планшета нет.
  catalogRepositoryProvider.overrideWithValue(h.catalog),
  searchRepositoryProvider.overrideWithValue(h.search),
  catalogViewerRoleProvider.overrideWithValue(RoleCode.kiosk),
  catalogShelfPortProvider.overrideWithValue(null),
  clockProvider.overrideWithValue(FixedClock(kNow)),
  if (online != null)
    catalogOnlineStatusProvider.overrideWith((Ref ref) => ref.watch(online))
  else
    catalogOnlineStatusProvider.overrideWithValue(OnlineStatus.online),
  catalogCustomerStockDisplayProvider.overrideWithValue(display),
  catalogCartPortProvider.overrideWithValue(cart),
  catalogCartButtonProvider.overrideWithValue(
    (BuildContext context) => const SizedBox(key: _cartButtonKey, width: 120, height: 44),
  ),
  catalogKioskLogoWrapperProvider.overrideWithValue(
    logoWrapper ?? (Widget logo) => KeyedSubtree(key: _logoWrapperKey, child: logo),
  ),
  catalogKioskProductDetailsProvider.overrideWithValue(
    (BuildContext context, CatalogKioskProductArgs args) =>
        Center(child: Text('product:${args.productId}:${args.variantId}')),
  ),
  catalogKioskStartOverProvider.overrideWithValue(startOver),
  cartOrderingBlockedProvider.overrideWithValue(orderingBlocked),
  catalogKioskUpdateNeededProvider.overrideWithValue(updateNeeded),
  catalogUserSettingsStoreProvider.overrideWithValue(store),
];

final AppLocalizationsRu _ru = AppLocalizationsRu();

/// Баннер UI-51-014 [banner] — под шапкой SCR-51 во всю ширину, над колонкой категорий и списком (зоны B–D).
void _expectUnderHeader(WidgetTester tester, Finder banner, {required double width}) {
  expect(banner, findsOneWidget);
  final double headerBottom = tester.getBottomLeft(find.byType(KioskCatalogHeader)).dy;
  expect(tester.getTopLeft(banner).dy, greaterThanOrEqualTo(headerBottom - 0.01), reason: 'под шапкой');
  expect(
    tester.getBottomLeft(banner).dy,
    lessThanOrEqualTo(tester.getTopLeft(find.byKey(KioskCatalogKeys.sidebar)).dy + 0.01),
    reason: 'над зонами B–D',
  );
  expect(tester.getSize(banner).width, closeTo(width, 0.01), reason: 'во всю ширину');
}

Widget _app(List<Override> overrides, {Widget? home, GoRouter? router, required Size size}) {
  Widget wrap(BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true, size: size, padding: EdgeInsets.zero),
    // Режим планшета: приватный ввод во всём приложении (03 §9.74; `app/app.dart`).
    child: PrivateInputScope(child: child!),
  );
  return ProviderScope(
    overrides: overrides,
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
            home: home,
          ),
  );
}

/// Витрина без маршрутизатора (адрес не пишется).
Future<void> _pump(WidgetTester tester, List<Override> overrides, {Size size = const Size(1280, 800)}) async {
  setWindow(tester, size);
  await tester.pumpWidget(
    _app(
      overrides,
      size: size,
      home: const Scaffold(body: KioskCatalogView()),
    ),
  );
  await settle(tester);
}

/// Маршрутизатор с `/kiosk?c=` (как `kiosk_routes.dart`: `c` → `KioskCatalogView.categoryId`).
GoRouter _router() => GoRouter(
  initialLocation: '/kiosk',
  routes: <RouteBase>[
    GoRoute(
      path: '/kiosk',
      builder: (BuildContext c, GoRouterState s) =>
          Scaffold(body: KioskCatalogView(categoryId: s.uri.queryParameters['c'])),
    ),
  ],
);

String _location(GoRouter r) => r.routeInformationProvider.value.uri.toString();

StockBadge _badge(WidgetTester tester, String productId) => tester.widget<StockBadge>(
  find.descendant(of: find.byKey(ValueKey<String>('product-$productId')), matching: find.byType(StockBadge)),
);

ProductCardData _card(WidgetTester tester, String productId) => tester
    .widget<ProductCardGrid>(
      find.descendant(of: find.byKey(ValueKey<String>('product-$productId')), matching: find.byType(ProductCardGrid)),
    )
    .data;

/// «+ Добавить» карточки: доступная — `AppButton`; недоступная — серая кнопка без действия (нажатие уходит карточке —
/// открывается слой карточки товара, его закрываем).
Future<void> _tapAdd(WidgetTester tester, String productId) async {
  final Finder card = find.byKey(ValueKey<String>('product-$productId'));
  final Finder button = find.descendant(of: card, matching: find.byType(AppButton));
  final Finder disabled = find.descendant(
    of: card,
    matching: find.byKey(const ValueKey<String>('product-card-unavailable')),
  );
  await tester.tap(button.evaluate().isNotEmpty ? button : disabled);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  if (find.byKey(KioskProductSheet.closeKey).evaluate().isNotEmpty) {
    await tester.tap(find.byKey(KioskProductSheet.closeKey));
    await settle(tester);
  }
}

void main() {
  group('SCR-51 витрина планшета (TAB-2-03)', () {
    testWidgets('AC-UI-51-001: шапка — логотип, поиск без сканера, «Обычные цены магазина», «Начать заново», корзина; '
        'нет «☰», колокольчика, блока пользователя, часов, «Избранного», «Недавних»; старт — корень с наибольшим числом '
        'товаров', (tester) async {
      final CatalogHarness h = CatalogHarness(role: RoleCode.kiosk);
      await _pump(tester, _kioskOverrides(h));

      expect(find.byKey(KioskCatalogKeys.root), findsOneWidget);
      final TopAppBarPos bar = tester.widget<TopAppBarPos>(find.byType(TopAppBarPos));
      expect(bar.bell, isNull, reason: 'колокольчика нет (UI-51-001)');
      expect(bar.user, isNull, reason: 'блока пользователя нет');
      expect(bar.onMenu, isNull, reason: '«☰» нет');
      expect(find.byType(NotificationBell), findsNothing);
      expect(find.byType(TopAppBarUser), findsNothing);
      expect(find.byType(TopAppBarClock), findsNothing);
      expect(find.byKey(_logoWrapperKey), findsOneWidget, reason: 'логотип — с аварийным выходом (UI-51-002)');
      expect(find.byKey(KioskCatalogHeader.priceChipKey), findsOneWidget);
      expect(find.text('Обычные цены магазина'), findsOneWidget);
      expect(find.text('Начать заново'), findsOneWidget);
      expect(find.byKey(_cartButtonKey), findsOneWidget);
      expect(find.byKey(KioskCatalogKeys.searchField), findsOneWidget);
      expect(tester.widget<SearchBar>(find.byKey(KioskCatalogKeys.searchField)).onScan, isNull, reason: 'Р-15 (а)');
      // Подборок строки управления и «Избранного» колонки нет.
      for (final String k in <String>['preset-newest', 'preset-favorites', 'preset-recent']) {
        expect(find.byKey(ValueKey<String>(k)), findsNothing, reason: k);
      }
      expect(find.text('Избранное'), findsNothing);
      expect(find.byIcon(Icons.star_outline_rounded), findsNothing, reason: 'звёзд на карточках нет');
      // Стартовая категория — «Смесители» (124 товара) с лентой подкатегорий.
      expect(h.catalog.productCalls.first.filter.categoryId, 'c-mix');
      expect(find.text('Для кухни'), findsOneWidget);
      expect(find.text('Для ванной'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('sidebar-category-c-mix')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('product-p0')), findsOneWidget);
    });

    testWidgets('T-KIOSK-009 no numbers at status: при customer_stock_display=status — «В наличии» без чисел, при '
        'quantity — доступное количество; запросы каталога и поиска без warehouseId и priceListId', (tester) async {
      final CatalogHarness h = CatalogHarness(role: RoleCode.kiosk);
      await _pump(tester, _kioskOverrides(h));
      expect(_badge(tester, 'p0').label, 'В наличии');
      expect(find.textContaining('24 шт'), findsNothing, reason: 'при status количеств на экране нет (KIOSK-007)');

      await tester.enterText(find.byKey(KioskCatalogKeys.searchField), 'F42');
      await tester.pump(const Duration(milliseconds: 350));
      await settle(tester);
      expect(h.search.calls, isNotEmpty);
      expect(_badge(tester, 'p1').label, 'В наличии');

      for (final CatalogQuery q in h.catalog.productCalls) {
        expect(q.filter.warehouseId, isNull);
        expect(q.filter.priceListId, isNull);
      }
      for (final SearchQuery q in h.search.calls) {
        expect(q.filter.warehouseId, isNull);
        expect(q.filter.priceListId, isNull);
      }

      await tester.pumpWidget(const SizedBox());
      final CatalogHarness h2 = CatalogHarness(role: RoleCode.kiosk);
      await _pump(tester, _kioskOverrides(h2, display: CustomerStockDisplay.quantity));
      expect(_badge(tester, 'p0').label, 'В наличии · 24 шт');
    });

    test('T-KIOSK-009 CatalogCardContext: роль kiosk — покупатель (числа только при quantity); «+ Добавить» '
        'недоступна при addDisabled', () async {
      final AppLocalizations l10n = await AppLocalizations.delegate.load(const Locale('ru'));
      final ProductSummary p = product(1, available: 24);
      String label(RoleCode role, CustomerStockDisplay d) =>
          CatalogCardMapper.stock(CatalogCardContext(l10n: l10n, now: kNow, role: role, customerStockDisplay: d), p).$2;
      expect(label(RoleCode.kiosk, CustomerStockDisplay.status), 'В наличии');
      expect(label(RoleCode.kiosk, CustomerStockDisplay.quantity), 'В наличии · 24 шт');
      expect(label(RoleCode.customer, CustomerStockDisplay.status), 'В наличии', reason: 'SCR-50 — как прежде');
      expect(label(RoleCode.seller, CustomerStockDisplay.status), 'В наличии · 24 шт', reason: 'staff — как прежде');
      final CatalogCardContext blocked = CatalogCardContext(
        l10n: l10n,
        now: kNow,
        role: RoleCode.kiosk,
        addDisabled: true,
      );
      expect(CatalogCardMapper.action(blocked, p).$1, ProductCardActionKind.unavailable);
      expect(
        CatalogCardMapper.action(CatalogCardContext(l10n: l10n, now: kNow, role: RoleCode.kiosk), p).$1,
        ProductCardActionKind.add,
      );
    });

    testWidgets('T-KIOSK-029 no search history: поиск — результаты в витрине, `search_history` и настройки не пишутся, '
        '«Недавних запросов» нет; поле без подсказок и выделения; «Начать заново» — стартовая категория, пустой поиск, '
        'фильтры и вид по умолчанию', (tester) async {
      final CatalogHarness h = CatalogHarness(role: RoleCode.kiosk);
      final _RecordingSettingsStore store = _RecordingSettingsStore();
      final Completer<void> reset = Completer<void>();
      int resets = 0;
      Future<void> startOver() {
        resets++;
        return reset.future;
      }

      await _pump(tester, _kioskOverrides(h, startOver: startOver, store: store));
      final ProviderContainer container = ProviderScope.containerOf(tester.element(find.byType(KioskCatalogView)));

      // Поле поиска — системная клавиатура без подсказок, автоисправления, обучения, автозаполнения и выделения.
      final TextField field = tester.widget<TextField>(
        find.descendant(of: find.byKey(KioskCatalogKeys.searchField), matching: find.byType(TextField)),
      );
      expect(field.enableSuggestions, isFalse);
      expect(field.autocorrect, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse);
      expect(field.autofillHints, isNull);
      expect(field.enableInteractiveSelection, isFalse);
      expect(field.readOnly, isFalse, reason: 'поиск — с системной клавиатурой');

      await tester.enterText(find.byKey(KioskCatalogKeys.searchField), 'кран');
      await tester.pump(const Duration(milliseconds: 350));
      await settle(tester);
      expect(h.search.queries, <String>['кран']);
      expect(find.text('Поиск: «кран»'), findsOneWidget);
      expect(find.byType(SearchTooShortPanel), findsNothing);

      // Короче минимума — снова категория, без блока «Недавние запросы».
      await tester.enterText(find.byKey(KioskCatalogKeys.searchField), 'к');
      await settle(tester);
      expect(find.byType(SearchTooShortPanel), findsNothing);
      expect(find.text('Поиск: «кран»'), findsNothing);
      expect(find.text('Смесители'), findsWidgets);

      // Вид «Список» и фильтр «В наличии» — только в памяти экрана.
      await tester.enterText(find.byKey(KioskCatalogKeys.searchField), 'кран');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settle(tester);
      expect(h.search.queries.last, 'кран', reason: 'тот же запрос снова выполняется после выхода из поиска');
      await tester.tap(find.text('Список'));
      await settle(tester);
      await tester.tap(find.text('Фильтры'));
      await settle(tester);
      expect(find.byKey(const ValueKey<String>('filter-favorites')), findsNothing, reason: 'избранного нет');
      expect(find.byKey(const ValueKey<String>('filter-section-warehouse')), findsNothing, reason: 'склада нет');
      await tester.tap(find.byKey(const ValueKey<String>('filter-in-stock')));
      await tester.pump(const Duration(milliseconds: 350));
      await settle(tester);
      expect(h.search.calls.last.filter.inStock, isTrue);

      expect(store.writes, isEmpty, reason: 'ни истории поиска, ни вида, ни сортировки (KIOSK-021)');
      expect(container.read(searchHistoryProvider), isEmpty);

      // «Начать заново»: сразу — витрина нового покупателя; повторное нажатие во время сброса игнорируется.
      await tester.tap(find.text('Начать заново'));
      await tester.pump();
      await tester.tap(find.byKey(KioskCatalogHeader.startOverKey), warnIfMissed: false);
      await settle(tester);
      expect(resets, 1);
      final TextField after = tester.widget<TextField>(
        find.descendant(of: find.byKey(KioskCatalogKeys.searchField), matching: find.byType(TextField)),
      );
      expect(after.controller!.text, isEmpty);
      expect(find.text('Поиск: «кран»'), findsNothing);
      expect(find.byKey(const ValueKey<String>('filter-in-stock')), findsNothing, reason: 'панель фильтров закрыта');
      expect(h.catalog.productCalls.last.filter.categoryId, 'c-mix');
      expect(h.catalog.productCalls.last.filter.inStock, isNull);
      expect(
        tester.widget<ViewModeSegmented>(find.byType(ViewModeSegmented)).value,
        ProductViewMode.grid,
        reason: 'вид по умолчанию',
      );
      reset.complete();
      await settle(tester);
      expect(store.writes, isEmpty);
      expect(container.read(searchHistoryProvider), isEmpty);
    });

    testWidgets('T-KIOSK-032 offline banner, cache, add and checkout disabled, recovery without restart: без связи — '
        'баннер, витрина из кэша, «+ Добавить» недоступна и в корзину не уходит; связь вернулась — список с сервера, '
        'баннера нет, добавление работает', (tester) async {
      final FakeCatalogRepository catalog = FakeCatalogRepository()
        ..cached = Success<CatalogPage<ProductSummary>>(page(products(4), source: DataSource.cache))
        ..networkPages.add(const FailureResult<CatalogPage<ProductSummary>>(kOffline));
      final CatalogHarness h = CatalogHarness(role: RoleCode.kiosk, catalog: catalog);
      final _CountingCart cart = _CountingCart();
      final NotifierProvider<_Online, OnlineStatus> online = NotifierProvider<_Online, OnlineStatus>(
        () => _Online(OnlineStatus.offline),
      );
      await _pump(tester, _kioskOverrides(h, cart: cart, online: online));

      expect(find.byKey(KioskCatalogKeys.offlineBanner), findsOneWidget);
      expect(
        find.text('Нет связи. Смотреть товары можно, отправить заявку — нет. Обратитесь к продавцу'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey<String>('product-p0')), findsOneWidget, reason: 'каталог из кэша (DATA-262)');
      expect(_card(tester, 'p0').action, ProductCardActionKind.unavailable);
      expect(
        find.descendant(of: find.byKey(const ValueKey<String>('product-p0')), matching: find.byType(AppButton)),
        findsNothing,
      );
      await _tapAdd(tester, 'p0');
      expect(cart.added, isEmpty, reason: 'без связи «В корзину» недоступно и в очередь не встаёт (KIOSK-025)');
      // «Оформить заявку» без связи недоступна в drawer корзины планшета (T-KIOSK-042/061, kiosk_cart_sync_test.dart).

      // Связь вернулась — без перезапуска.
      catalog.networkPages
        ..clear()
        ..add(Success<CatalogPage<ProductSummary>>(page(products(5))));
      final int calls = catalog.productCalls.length;
      ProviderScope.containerOf(
        tester.element(find.byType(KioskCatalogView)),
      ).read(online.notifier).set(OnlineStatus.online);
      await settle(tester);
      expect(catalog.productCalls.length, greaterThan(calls), reason: 'список перезапрошен');
      expect(find.byKey(KioskCatalogKeys.offlineBanner), findsNothing);
      expect(find.byKey(const ValueKey<String>('product-p4')), findsOneWidget);
      expect(_card(tester, 'p0').action, ProductCardActionKind.add);
      await _tapAdd(tester, 'p0');
      expect(cart.added, <String>['p0']);
      expect(find.text('Добавлено: Смеситель для кухни Frap F4200'), findsOneWidget);
    });

    testWidgets('T-KIOSK-032 serverDown (сеть есть, сервер не отвечает — таймауты, 502–504): как без связи — баннер '
        '«Нет связи…», «+ Добавить» недоступна и в корзину не уходит; сервер ответил — список заново, добавление '
        'работает (UI-51-014, FLOW-044.E1)', (tester) async {
      final FakeCatalogRepository catalog = FakeCatalogRepository(items: products(4));
      final CatalogHarness h = CatalogHarness(role: RoleCode.kiosk, catalog: catalog);
      final _CountingCart cart = _CountingCart();
      final NotifierProvider<_Online, OnlineStatus> online = NotifierProvider<_Online, OnlineStatus>(
        () => _Online(OnlineStatus.online),
      );
      await _pump(tester, _kioskOverrides(h, cart: cart, online: online));
      expect(find.byKey(KioskCatalogKeys.offlineBanner), findsNothing, reason: 'страница получена с сервера');
      expect(_card(tester, 'p0').action, ProductCardActionKind.add);

      final ProviderContainer container = ProviderScope.containerOf(tester.element(find.byType(KioskCatalogView)));
      container.read(online.notifier).set(OnlineStatus.serverDown);
      await settle(tester);
      expect(find.byKey(KioskCatalogKeys.offlineBanner), findsOneWidget);
      expect(_card(tester, 'p0').action, ProductCardActionKind.unavailable);
      await _tapAdd(tester, 'p0');
      expect(cart.added, isEmpty, reason: 'корзина планшета при serverDown изменения не принимает');

      final int calls = catalog.productCalls.length;
      container.read(online.notifier).set(OnlineStatus.online);
      await settle(tester);
      expect(find.byKey(KioskCatalogKeys.offlineBanner), findsNothing);
      expect(catalog.productCalls.length, greaterThan(calls), reason: 'список перезапрошен после serverDown');
      expect(_card(tester, 'p0').action, ProductCardActionKind.add);
      await _tapAdd(tester, 'p0');
      expect(cart.added, <String>['p0']);
    });

    testWidgets('T-KIOSK-032 426 и метка сброса без сети (cartOrderingBlockedProvider): «+ Добавить» недоступна и со '
        'связью', (tester) async {
      final _CountingCart cart = _CountingCart();
      await _pump(tester, _kioskOverrides(CatalogHarness(role: RoleCode.kiosk), cart: cart, orderingBlocked: true));
      expect(find.byKey(KioskCatalogKeys.offlineBanner), findsNothing);
      expect(_card(tester, 'p0').action, ProductCardActionKind.unavailable);
      await _tapAdd(tester, 'p0');
      expect(cart.added, isEmpty);
    });

    testWidgets(
      'T-KIOSK-050 UI-51-014: 426 — баннер «Планшет нужно обновить» с иконкой system_update под шапкой во всю '
      'ширину, над зонами B–D; без связи — «Нет связи…» с иконкой wifi_off там же; 426 и без связи вместе — один '
      'баннер (AC-UI-51-009)',
      (tester) async {
        await _pump(
          tester,
          _kioskOverrides(CatalogHarness(role: RoleCode.kiosk), updateNeeded: true, orderingBlocked: true),
        );
        final Finder update = find.byKey(KioskCatalogKeys.updateBanner);
        _expectUnderHeader(tester, update, width: 1280);
        expect(find.descendant(of: update, matching: find.text(_ru.kiosk_update_needed)), findsOneWidget);
        expect(find.descendant(of: update, matching: find.byIcon(Icons.system_update_rounded)), findsOneWidget);
        expect(find.byKey(KioskCatalogKeys.offlineBanner), findsNothing);
        expect(_card(tester, 'p0').action, ProductCardActionKind.unavailable, reason: '«+ Добавить» недоступна');

        // Без связи — «Нет связи…» на том же месте.
        await tester.pumpWidget(const SizedBox());
        final NotifierProvider<_Online, OnlineStatus> offline = NotifierProvider<_Online, OnlineStatus>(
          () => _Online(OnlineStatus.offline),
        );
        await _pump(tester, _kioskOverrides(CatalogHarness(role: RoleCode.kiosk), online: offline));
        final Finder noLink = find.byKey(KioskCatalogKeys.offlineBanner);
        _expectUnderHeader(tester, noLink, width: 1280);
        expect(find.descendant(of: noLink, matching: find.byIcon(Icons.wifi_off_rounded)), findsOneWidget);
        expect(find.byKey(KioskCatalogKeys.updateBanner), findsNothing);

        // 426 без связи — один баннер «Планшет нужно обновить» (вертикальное окно — то же место).
        await tester.pumpWidget(const SizedBox());
        final NotifierProvider<_Online, OnlineStatus> both = NotifierProvider<_Online, OnlineStatus>(
          () => _Online(OnlineStatus.offline),
        );
        await _pump(
          tester,
          _kioskOverrides(
            CatalogHarness(role: RoleCode.kiosk),
            online: both,
            updateNeeded: true,
            orderingBlocked: true,
          ),
          size: const Size(800, 1280),
        );
        _expectUnderHeader(tester, find.byKey(KioskCatalogKeys.updateBanner), width: 800);
        expect(find.byKey(KioskCatalogKeys.offlineBanner), findsNothing);
        expect(find.text(_ru.kiosk_offline), findsNothing);
        expect(
          find.descendant(of: find.byKey(KioskCatalogKeys.root), matching: find.byType(ErrorState)),
          findsOneWidget,
          reason: 'один баннер',
        );
        expect(tester.takeException(), isNull);
      },
    );

    test('SCR-51.7 без отметки времени для покупателя: kiosk без связи и с остатком 2 ч назад — stockAsOf нет (и в '
        'описании для диктора); customer и сотрудник — «данные от …», как прежде', () async {
      final AppLocalizations l10n = await AppLocalizations.delegate.load(const Locale('ru'));
      final ProductSummary p = product(1, asOf: kNow.subtract(const Duration(hours: 2)));
      CatalogCardContext ctx(RoleCode role) => CatalogCardContext(l10n: l10n, now: kNow, role: role, offline: true);
      expect(ctx(RoleCode.kiosk).showsDataAge, isFalse);
      final ProductCardData kiosk = CatalogCardMapper.map(ctx(RoleCode.kiosk), p);
      expect(kiosk.stockAsOf, isNull);
      expect(kiosk.semanticLabel, isNot(contains('данные от')));
      expect(CatalogCardMapper.map(ctx(RoleCode.customer), p).stockAsOf, startsWith('данные от '));
      expect(CatalogCardMapper.map(ctx(RoleCode.seller), p).stockAsOf, startsWith('данные от '));
    });

    testWidgets('UI-51-011: карточка товара — слой поверх /kiosk без смены адреса; крестик, Esc и затемнение '
        'закрывают; адрес — только категория (`c`), без строки поиска; голый /kiosk извне — стартовая категория', (
      tester,
    ) async {
      final CatalogHarness h = CatalogHarness(role: RoleCode.kiosk);
      setWindow(tester, const Size(1280, 800));
      final GoRouter router = _router();
      addTearDown(router.dispose);
      await tester.pumpWidget(_app(_kioskOverrides(h), router: router, size: const Size(1280, 800)));
      await settle(tester);
      expect(_location(router), '/kiosk?c=c-mix', reason: 'стартовая категория пишется в адрес заменой записи');

      await tester.tap(find.text('Для ванной'));
      await settle(tester);
      expect(_location(router), '/kiosk?c=c-mix-bath');

      final String p0 = _card(tester, 'p0').name;
      final SemanticsHandle semantics = tester.ensureSemantics();
      await tester.tap(find.byKey(const ValueKey<String>('product-p0')));
      await settle(tester);
      expect(find.byKey(KioskProductSheet.key), findsOneWidget);
      expect(find.text('product:p0:v0'), findsOneWidget);
      // A11Y-011: слой — свой маршрут для диктора с именем (название товара).
      expect(
        tester.getSemantics(find.bySemanticsLabel(p0)),
        containsSemantics(label: p0, scopesRoute: true, namesRoute: true),
      );
      semantics.dispose();
      expect(_location(router), '/kiosk?c=c-mix-bath', reason: 'слой — без маршрута (ADR-115 п. 22)');
      await tester.tap(find.byKey(KioskProductSheet.closeKey));
      await settle(tester);
      expect(find.byKey(KioskProductSheet.key), findsNothing);

      await tester.tap(find.byKey(const ValueKey<String>('product-p1')));
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.byKey(KioskProductSheet.key), findsNothing, reason: 'Esc закрывает слой');

      await tester.tap(find.byKey(const ValueKey<String>('product-p1')));
      await settle(tester);
      await tester.tapAt(const Offset(40, 400));
      await settle(tester);
      expect(find.byKey(KioskProductSheet.key), findsNothing, reason: 'тап по затемнению закрывает слой');
      expect(find.text('Для ванной'), findsOneWidget, reason: 'категория и лента витрины сохранились');

      await tester.enterText(find.byKey(KioskCatalogKeys.searchField), 'кран');
      await tester.pump(const Duration(milliseconds: 350));
      await settle(tester);
      expect(find.text('Поиск: «кран»'), findsOneWidget);
      expect(_location(router), isNot(contains('кран')), reason: 'строка поиска в адрес не пишется (ч. F, правило 3)');
      expect(_location(router), isNot(contains('q=')));

      // Сброс FLOW-045 (`go('/kiosk')` извне) — стартовая категория, пустой поиск.
      router.go('/kiosk');
      await settle(tester);
      expect(find.text('Поиск: «кран»'), findsNothing);
      expect(_location(router), '/kiosk?c=c-mix');
    });

    testWidgets('AC-UI-51-019: 1280 × 800 и 800 × 1280 — без переполнения; на 800 текст чипа свёрнут в иконку с '
        'тултипом, корзина и поиск на месте', (tester) async {
      await _pump(tester, _kioskOverrides(CatalogHarness(role: RoleCode.kiosk)));
      expect(tester.takeException(), isNull);
      expect(find.byKey(_cartButtonKey), findsOneWidget);
      // Чип «Обычные цены магазина» — текст целиком (без предела 160 и без многоточия), не иконка (UI-51-004).
      final Finder chipText = find.descendant(
        of: find.byKey(KioskCatalogHeader.priceChipKey),
        matching: find.text('Обычные цены магазина'),
      );
      expect(chipText, findsOneWidget);
      final RenderParagraph chip = tester.renderObject<RenderParagraph>(chipText);
      expect(chip.didExceedMaxLines, isFalse, reason: 'текст чипа не обрезан');
      expect(chip.getMaxIntrinsicWidth(double.infinity), lessThanOrEqualTo(chip.size.width + 0.5));
      expect(find.byKey(const ValueKey<String>('kiosk-price-chip-icon')), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await _pump(tester, _kioskOverrides(CatalogHarness(role: RoleCode.kiosk)), size: const Size(800, 1280));
      expect(tester.takeException(), isNull);
      expect(find.byKey(_cartButtonKey), findsOneWidget);
      expect(find.byKey(KioskCatalogKeys.searchField), findsOneWidget);
      expect(find.byKey(KioskCatalogHeader.priceChipKey), findsOneWidget);
      expect(find.byTooltip('Обычные цены магазина'), findsOneWidget);
      expect(find.byKey(KioskCatalogKeys.sidebar), findsOneWidget);
    });
  });

  group('корень: порты витрины планшета (TAB-2-03)', () {
    ProviderContainer container(RoleCode role, {List<Override> extra = const <Override>[]}) {
      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[
          ...customerModeOverrides,
          ...catalogOfflineFirstBindings,
          ...kioskModeOverrides,
          catalogViewerRoleProvider.overrideWithValue(role),
          ...extra,
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('kiosk: нет избранного и недавних (без GET /catalog/products/recent), нет `GET /sync/status` и drift-настроек '
        'каталога; customer — прежние порты', () {
      final ProviderContainer kiosk = container(RoleCode.kiosk);
      expect(kiosk.read(catalogShelfPortProvider), isNull);
      expect(kiosk.read(product_details.productFavoritePortProvider), isNull);
      expect(kiosk.read(syncStatusPortProvider), isNull);
      expect(kiosk.read(catalogUserSettingsStoreProvider), isNull);
      expect(kiosk.read(catalogKioskLogoWrapperProvider), isNotNull);
      expect(kiosk.read(catalogKioskProductDetailsProvider), isNotNull);

      final ProviderContainer customer = container(RoleCode.customer);
      expect(customer.read(catalogShelfPortProvider), isA<FavoritesCatalogShelf>());
      expect(customer.read(product_details.productFavoritePortProvider), isA<FavoritesCatalogShelf>());
    });

    testWidgets('UI-51-002: логотип витрины в корне — с аварийным выходом (долгое нажатие 5 с, фича kiosk)', (
      tester,
    ) async {
      final CatalogHarness h = CatalogHarness(role: RoleCode.kiosk);
      await _pump(tester, _kioskOverrides(h, logoWrapper: kioskEmergencyLogo));
      expect(
        find.ancestor(of: find.byKey(KioskCatalogHeader.logoKey), matching: find.byType(KioskEmergencyExitTrigger)),
        findsOneWidget,
      );
      expect(KioskEmergencyExitTrigger.holdDuration, const Duration(seconds: 5));
    });

    testWidgets('UI-51-011 содержимое слоя: SCR-14 в варианте покупателя — «Обычные цены магазина», без таблицы '
        'складов, крошек, поиска и звезды; запрос карточки без warehouseId', (tester) async {
      final pd.FakeCatalogRepository repo = pd.FakeCatalogRepository(
        network: Success<Product>(pd.singleVariantProduct()),
      );
      setWindow(tester, const Size(1280, 800));
      await tester.pumpWidget(
        _app(
          pd.productOverrides(catalog: repo, role: RoleCode.kiosk),
          size: const Size(1280, 800),
          home: Scaffold(
            body: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: SizedBox(
                width: KioskProductSheet.width,
                child: Builder(
                  builder: (BuildContext context) => kioskProductDetails(context, (productId: 'p-1', variantId: null)),
                ),
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      expect(find.byKey(KioskProductDetailsBody.bodyKey), findsOneWidget);
      expect(repo.productCalls, isNotEmpty);
      for (final ({String id, String? warehouseId, String? priceListId}) call in repo.productCalls) {
        expect(call.warehouseId, isNull, reason: '`warehouseId` планшета → 403 (KIOSK-007)');
        expect(call.priceListId, isNull);
      }
      expect(find.text('Обычные цены магазина'), findsOneWidget, reason: 'UI-51-004 вместо «Ваш вид цены»');
      expect(find.textContaining('Ваш вид цены'), findsNothing);
      expect(find.byType(ProductFavoriteToggle), findsNothing);
      expect(find.byKey(const ValueKey<String>('product-breadcrumb-root')), findsNothing);
      expect(find.byKey(const ValueKey<String>('product-search')), findsNothing);
      expect(find.textContaining('Резерв'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    Future<void> pumpLayer(WidgetTester tester, List<Override> overrides, {String productId = 'p-1'}) async {
      setWindow(tester, const Size(1280, 800));
      await tester.pumpWidget(
        _app(
          overrides,
          size: const Size(1280, 800),
          home: Scaffold(
            body: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: SizedBox(
                width: KioskProductSheet.width,
                child: Builder(
                  builder: (BuildContext context) =>
                      kioskProductDetails(context, (productId: productId, variantId: null)),
                ),
              ),
            ),
          ),
        ),
      );
      await settle(tester);
    }

    AppButton cta(WidgetTester tester) => tester.widget<AppButton>(find.byKey(const ValueKey<String>('product-cta')));

    for (final (String name, List<Override> Function() state) in <(String, List<Override> Function())>[
      (
        'без связи',
        () => <Override>[
          catalogOnlineStatusProvider.overrideWithValue(OnlineStatus.offline),
          cartOrderingBlockedProvider.overrideWithValue(false),
        ],
      ),
      (
        'сервер не отвечает (serverDown)',
        () => <Override>[
          catalogOnlineStatusProvider.overrideWithValue(OnlineStatus.serverDown),
          cartOrderingBlockedProvider.overrideWithValue(false),
        ],
      ),
      (
        '426 / метка сброса (cartOrderingBlockedProvider)',
        () => <Override>[
          catalogOnlineStatusProvider.overrideWithValue(OnlineStatus.online),
          cartOrderingBlockedProvider.overrideWithValue(true),
        ],
      ),
    ]) {
      testWidgets('AC-UI-51-006 / AC-UI-51-009 слой карточки, $name: «В корзину» недоступна с подписью «Добавление '
          'недоступно», степпер неактивен, в корзину ничего не уходит', (tester) async {
        final pd.FakeCartDraftRepository cart = pd.FakeCartDraftRepository();
        await pumpLayer(tester, <Override>[
          ...pd.productOverrides(
            catalog: pd.FakeCatalogRepository(network: Success<Product>(pd.singleVariantProduct())),
            cart: cart,
            role: RoleCode.kiosk,
          ),
          ...state(),
        ]);
        expect(cta(tester).onPressed, isNull);
        expect(cta(tester).label, 'Добавление недоступно');
        final QuantityStepper stepper = tester.widget<QuantityStepper>(
          find.byKey(const ValueKey<String>('product-quantity-stepper')),
        );
        expect((stepper.onIncrement, stepper.onValueTap), (null, null));
        await tester.tap(find.byKey(const ValueKey<String>('product-cta')), warnIfMissed: false);
        await settle(tester);
        expect(cart.adds, isEmpty);
      });
    }

    testWidgets('слой карточки со связью и без блокировки — «В корзину» доступна; лист вариантов без связи — CTA и '
        'степперы строк неактивны', (tester) async {
      final pd.FakeCartDraftRepository cart = pd.FakeCartDraftRepository();
      await pumpLayer(tester, <Override>[
        ...pd.productOverrides(
          catalog: pd.FakeCatalogRepository(network: Success<Product>(pd.singleVariantProduct())),
          cart: cart,
          role: RoleCode.kiosk,
        ),
        catalogOnlineStatusProvider.overrideWithValue(OnlineStatus.online),
        cartOrderingBlockedProvider.overrideWithValue(false),
      ]);
      expect(cta(tester).onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey<String>('product-cta')));
      // Защита от двойного нажатия «В корзину» — 300 мс (ProductDetailsNotifier.addGuard).
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      expect(cart.adds, hasLength(1));

      await tester.pumpWidget(const SizedBox());
      await pumpLayer(tester, <Override>[
        ...pd.productOverrides(
          catalog: pd.FakeCatalogRepository(network: Success<Product>(pd.multiVariantProduct())),
          cart: cart,
          role: RoleCode.kiosk,
        ),
        catalogOnlineStatusProvider.overrideWithValue(OnlineStatus.offline),
        cartOrderingBlockedProvider.overrideWithValue(false),
      ]);
      final Finder list = find.byKey(const ValueKey<String>('product-variant-list'));
      if (list.evaluate().isNotEmpty) {
        await tester.tap(list);
        await settle(tester);
        expect(tester.widget<AppButton>(find.byKey(const ValueKey<String>('variant-picker-add'))).onPressed, isNull);
        for (final QuantityStepper s in tester.widgetList<QuantityStepper>(
          find.descendant(
            of: find.byKey(const ValueKey<String>('variant-picker-sheet')),
            matching: find.byType(QuantityStepper),
          ),
        )) {
          expect(s.onIncrement, isNull);
        }
      }
      expect(cart.adds, hasLength(1), reason: 'без связи из листа вариантов ничего не уходит');
    });

    testWidgets('SEC-141 (3): отказ «В корзину» слоя 422 QTY_BELOW_MIN без чисел в conflicts[] — подпись без «— », '
        'минимум — из карточки', (tester) async {
      final _FailingCart cart = _FailingCart(
        const ConflictFailure(
          ConflictKind.qtyBelowMin,
          details: <String, Object?>{
            'conflicts': <Object?>[
              <String, Object?>{'variantId': 'v-1', 'kind': 'qty_below_min'},
            ],
          },
        ),
      );
      await pumpLayer(tester, <Override>[
        ...pd.productOverrides(
          catalog: pd.FakeCatalogRepository(network: Success<Product>(pd.singleVariantProduct())),
          cart: cart,
          role: RoleCode.kiosk,
        ),
        catalogOnlineStatusProvider.overrideWithValue(OnlineStatus.online),
        cartOrderingBlockedProvider.overrideWithValue(false),
      ]);
      await tester.tap(find.byKey(const ValueKey<String>('product-cta')));
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      expect(cart.calls, 1);
      expect(find.textContaining('Минимальная партия — '), findsNothing);
      expect(find.text('Корзина не сохранена'), findsOneWidget, reason: 'минимума у карточки нет — подпись без числа');
      await tester.pump(const Duration(seconds: 6));
      await settle(tester);
    });

    test('T-KIOSK-009 область остатков кэша: kiosk и customer — `customer:<display>`, сотрудник — без области', () {
      const PublicSettingsSnapshot snapshot = PublicSettingsSnapshot(
        settings: PublicSettings(customerStockDisplay: 'status'),
        source: PublicSettingsSource.network,
      );
      String? scope(RoleCode role) => container(
        role,
        extra: <Override>[publicSettingsProvider.overrideWith(() => _Preset(snapshot))],
      ).read(catalogStockScopeProvider);
      expect(scope(RoleCode.kiosk), 'customer:status');
      expect(scope(RoleCode.customer), 'customer:status');
      expect(scope(RoleCode.seller), isNull);
    });
  });
}
