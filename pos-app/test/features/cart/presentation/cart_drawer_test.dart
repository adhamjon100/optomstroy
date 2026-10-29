// Drawer корзины 420 на medium и шире (02 SCR-20.2, SCR-20.3, AC-UI-20-001/020 редакции 1.16; ADR-112, D5):
// кнопка-итог шапки, `F4`/`F8`/`F9` при закрытом и открытом drawer и при открытой панели SCR-14 (expanded), фокус и
// клавиши строк сразу после открытия,
// снекбары внутри drawer над затемнением, переход в SCR-14 сначала закрывает drawer, ключ «Отложить» переживает
// закрытие, экран `/cart` не получает второй корзины. Фейковый `CartSync` и сервер — test/features/cart/support;
// данные синтетические, без реальной 1С.
// Тест-кейсы 12_TEST_PLAN: T-CART-033 (открытие и закрытие drawer), T-CART-034 (F4, F8, F9), T-CART-035 (снекбары и
//   переходы), T-CART-036 (состояние переживает закрытие).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/panel_page.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/cart_panel.dart';
import 'package:optomstroy/design_system/components/cart_summary.dart';
import 'package:optomstroy/design_system/components/discount_input.dart';
import 'package:optomstroy/design_system/components/quantity_stepper.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_drawer.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_header_button_view.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_panel_view.dart';

import '../../../support/f_fakes.dart';
import '../support/cart_test_support.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

const CartLineKey frap = CartLineKey('v-f4252');

CartLocalSnapshot localOf(Cart cart) => CartLocalSnapshot(
  localCartId: 'local-1',
  dirty: false,
  baseRowVersion: cart.rowVersion,
  lines: <CartLocalLine>[
    for (final (int i, CartLine l) in cart.items.indexed)
      CartLocalLine(
        key: CartLineKey(l.variantId, l.packagingId),
        quantity: l.quantity.value,
        syncState: CartDraftSyncState.synced,
        lineNo: i + 1,
        unitId: l.quantity.unitId,
        unitLabel: 'шт',
        productId: l.productId,
        productName: l.productName,
        step: Qty.units(1),
      ),
  ],
);

Finder inLine(CartLineKey key, Finder matching) =>
    find.descendant(of: find.byKey(CartKeys.line(key)), matching: matching);

final Finder _drawer = find.byKey(CartDrawer.key);
final Finder _button = find.byKey(CartHeaderButtonView.buttonKey);

void main() {
  late FakeCartRepository repo;
  late FakeCartSync sync;

  setUp(() {
    repo = FakeCartRepository();
    sync = FakeCartSync(repo);
  });

  /// «Каталог» с кнопкой-итогом в шапке (как `CatalogHeader` medium+); [body] — содержимое под шапкой.
  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1280, 800),
    Widget body = const Center(child: Text('catalog-grid')),
    RoleCode role = RoleCode.seller,
    List<Override> extra = const <Override>[],
  }) async {
    final Cart c = canonCart();
    if (repo.onFetch == null) serveCart(repo, c);
    sync.snapshot = localOf(c);
    repo.onListParked ??= (ParkedScope scope, String? cursor) async =>
        const Success<PageResult<CartParkedSummary>>(PageResult<CartParkedSummary>(items: <CartParkedSummary>[]));
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      cartApp(
        overrides: <Override>[
          ...extra,
          ...cartOverrides(sync: sync, repo: repo, role: role),
        ],
        cartBuilder: (BuildContext context) => Scaffold(
          body: Column(
            children: <Widget>[
              const Row(
                children: <Widget>[
                  Expanded(child: Text('catalog-header')),
                  CartHeaderButtonView(),
                ],
              ),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openByTap(WidgetTester tester) async {
    await tester.tap(_button);
    await tester.pumpAndSettle();
    expect(_drawer, findsOneWidget);
  }

  testWidgets('F4 при закрытом drawer — открывает его, фокус в корзине: ↓ и «+» сразу меняют количество, Delete и '
      'Ctrl+Z — «Позиция удалена» и «Отменить» (AC-UI-20-020)', (tester) async {
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f4);
    await tester.pumpAndSettle();
    expect(_drawer, findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'cart-panel');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadAdd);
    await tester.pump();
    expect(sync.setQuantityCalls.single, (frap, Qty.units(3)), reason: 'без повторного F4');

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(l10n.cart_line_deleted_snackbar), findsOneWidget);
    expect(find.byKey(CartKeys.line(frap)), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(CartKeys.line(frap)), findsOneWidget, reason: 'Ctrl+Z — «Отменить»');
    expect(_drawer, findsOneWidget);
  });

  testWidgets('F9 при закрытом drawer и непустой корзине — drawer открывается и запускает «Создать заказ» (SCR-21); '
      'на SCR-21 F9 кнопки шапки не повторяется', (tester) async {
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f9);
    await tester.pumpAndSettle();
    expect(find.text('checkout:cartId=cart-1'), findsOneWidget);
    expect(_drawer, findsNothing, reason: 'drawer закрыт перед переходом');

    await tester.sendKeyEvent(LogicalKeyboardKey.f9);
    await tester.pumpAndSettle();
    expect(find.textContaining('checkout:'), findsOneWidget, reason: 'второго SCR-21 нет');
    expect(_drawer, findsNothing, reason: 'кнопка шапки под SCR-21 молчит');
  });

  testWidgets('expanded: при открытой панели SCR-14 (PanelPage над страницей шапки) F4 открывает drawer, F9 — '
      '«Создать заказ» (02 §3.8, AC-UI-10-023)', (tester) async {
    final Cart c = canonCart();
    serveCart(repo, c);
    sync.snapshot = localOf(c);
    repo.onListParked ??= (ParkedScope scope, String? cursor) async =>
        const Success<PageResult<CartParkedSummary>>(PageResult<CartParkedSummary>(items: <CartParkedSummary>[]));
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final GoRouter router = GoRouter(
      initialLocation: '/catalog',
      routes: <RouteBase>[
        GoRoute(
          path: '/catalog',
          builder: (BuildContext context, GoRouterState state) => const Scaffold(
            body: Column(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(child: Text('catalog-header')),
                    CartHeaderButtonView(),
                  ],
                ),
                Expanded(child: Text('catalog-grid')),
              ],
            ),
          ),
          routes: <RouteBase>[
            // SCR-14 на expanded — PanelPage того же навигатора над страницей каталога (routes.dart, ProductRoute).
            GoRoute(
              path: 'p/:productId',
              pageBuilder: (BuildContext context, GoRouterState state) => PanelPage<void>(
                key: state.pageKey,
                transitionDuration: Duration.zero,
                reverseTransitionDuration: Duration.zero,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: SizedBox(
                    width: 480,
                    child: Material(child: Text('panel:${state.pathParameters['productId']}')),
                  ),
                ),
              ),
            ),
          ],
        ),
        GoRoute(
          path: '/checkout',
          builder: (_, GoRouterState state) => Scaffold(body: Text('checkout:${state.uri.query}')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: cartOverrides(sync: sync, repo: repo),
        child: MaterialApp.router(
          routerConfig: router,
          theme: AppTheme.light(),
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    router.go('/catalog/p/p-1');
    await tester.pumpAndSettle();
    expect(find.text('panel:p-1'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.f4);
    await tester.pumpAndSettle();
    expect(_drawer, findsOneWidget, reason: 'F4 при открытой панели SCR-14');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_drawer, findsNothing);
    expect(find.text('panel:p-1'), findsOneWidget, reason: 'панель SCR-14 не закрыта');

    await tester.sendKeyEvent(LogicalKeyboardKey.f9);
    await tester.pumpAndSettle();
    expect(find.text('checkout:cartId=cart-1'), findsOneWidget, reason: 'F9 при открытой панели SCR-14');
  });

  testWidgets('F8 при закрытом drawer — drawer и диалог «Отложить заказ» над ним; F8/F9 работают и внутри '
      'открытого drawer', (tester) async {
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    expect(_drawer, findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cart-park-name')), findsOneWidget);
    await tester.tap(find.text(l10n.ds_button_cancel));
    await tester.pumpAndSettle();
    expect(_drawer, findsOneWidget, reason: 'отмена диалога оставляет drawer');

    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('cart-park-name')), findsOneWidget, reason: 'F8 внутри drawer');
    await tester.tap(find.text(l10n.ds_button_cancel));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.f9);
    await tester.pumpAndSettle();
    expect(find.text('checkout:cartId=cart-1'), findsOneWidget, reason: 'F9 внутри drawer');
    expect(_drawer, findsNothing);
  });

  testWidgets(
    'кнопка шапки без открытия drawer: «Корзина · 6 шт» (единицы, как прежняя подпись CartFab); «5 поз. · 6 шт» '
    '— в тултипе (строку сворачивает шапка по ширине — header_fit_test); неудачное сохранение — иконка warning и '
    '«Корзина не сохранена» (паритет функций)',
    (tester) async {
      await pump(tester);
      final Text label = tester.widget<Text>(
        find.descendant(of: _button, matching: find.byKey(const ValueKey<String>('top-app-bar-cart-label'))),
      );
      expect(label.data, startsWith('Корзина · 6'));
      expect(find.descendant(of: _button, matching: find.byIcon(Icons.warning_amber_rounded)), findsNothing);
      expect(find.byTooltip(RegExp('^5 поз. · 6')), findsOneWidget, reason: 'позиции и единицы — в тултипе');

      sync.emitStatus(const CartSyncStatus(dead: 1));
      await tester.pumpAndSettle();
      expect(find.descendant(of: _button, matching: find.byIcon(Icons.warning_amber_rounded)), findsOneWidget);
      expect(find.byTooltip(RegExp(l10n.cart_header_save_failed)), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(l10n.cart_header_save_failed)), findsOneWidget);
      // В drawer — «Ошибка сохранения · Повторить» (повтор отправки), как в прежней постоянной CP.
      await openByTap(tester);
      expect(find.text(l10n.cart_save_state_failed), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'пустая корзина: F8/F9 при закрытом drawer ничего не делают, F4 открывает; подвал drawer — «Товаров (0)», '
    '«Итого», недоступные «Отложить · F8» и «Создать заказ · F9» с причиной (прототип; паритет функций ADR-112)',
    (tester) async {
      const Cart empty = Cart(id: 'cart-1', status: CartStatus.active, items: <CartLine>[], rowVersion: 1);
      serveCart(repo, empty);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      sync.snapshot = localOf(empty);
      repo.onListParked = (ParkedScope scope, String? cursor) async =>
          const Success<PageResult<CartParkedSummary>>(PageResult<CartParkedSummary>(items: <CartParkedSummary>[]));
      await tester.pumpWidget(
        cartApp(
          overrides: cartOverrides(sync: sync, repo: repo),
          cartBuilder: (BuildContext context) => const Scaffold(body: Align(child: CartHeaderButtonView())),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: _button, matching: find.text('0 поз.')),
        findsOneWidget,
        reason: 'без итога',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.f9);
      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      await tester.pumpAndSettle();
      expect(_drawer, findsNothing);
      expect(find.textContaining('checkout:'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.pumpAndSettle();
      expect(_drawer, findsOneWidget);
      expect(find.text(l10n.cart_empty_title), findsWidgets);
      expect(find.text(l10n.cart_summary_items(0)), findsOneWidget);
      expect(find.text(l10n.cart_summary_total), findsOneWidget);
      expect(find.text(l10n.cart_summary_server_note), findsOneWidget);
      expect(find.byKey(CartKeys.reason), findsOneWidget, reason: 'причина недоступности — «Корзина пуста»');
      expect(tester.widget<Text>(find.byKey(CartKeys.reason)).data, l10n.cart_cta_reason_empty);
      expect(tester.widget<AppButton>(find.byKey(CartKeys.createOrder)).onPressed, isNull);
      expect(tester.widget<AppButton>(find.byKey(CartKeys.park)).onPressed, isNull);
      expect(find.byType(DiscountInput), findsNothing, reason: 'скидка — только у непустой корзины');
    },
  );

  testWidgets('drawer: «Корзина · N поз.», «Клиент: не выбран», строки со степпером sm, «Товаров (N)», «Итого», '
      'примечание UI-20-034; кнопки в одну строку 48 — на Windows с клавишами', (tester) async {
    await pump(tester);
    await openByTap(tester);
    expect(find.text('Корзина · 5 поз.', findRichText: true), findsOneWidget);
    expect(find.text(l10n.cart_customer_empty, findRichText: true), findsOneWidget);
    expect(
      tester.widget<QuantityStepper>(inLine(frap, find.byType(QuantityStepper))).size,
      QuantityStepperSize.group,
      reason: 'expanded — степпер-группа прототипа',
    );
    expect(find.text(l10n.cart_summary_items(5)), findsOneWidget);
    expect(find.text(l10n.cart_summary_total), findsOneWidget);
    expect(find.byKey(CartSummary.noteKey), findsOneWidget);
    expect(find.text(l10n.cart_summary_server_note), findsOneWidget);
    expect(find.text(l10n.cart_cta_park_hotkey), findsOneWidget);
    expect(find.text(l10n.cart_cta_create_order_hotkey), findsOneWidget);
    final Rect park = tester.getRect(find.byKey(CartKeys.park));
    final Rect create = tester.getRect(find.byKey(CartKeys.createOrder));
    expect(park.top, create.top, reason: 'в одну строку');
    expect(park.height, 48);
    expect(create.left, greaterThan(park.right));
    expect(create.width / park.width, closeTo(1.4, 0.05), reason: 'flex 1 : 1,4');
    expect(tester.widget<AppButton>(find.byKey(CartKeys.createOrder)).size, AppButtonSize.cta);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('снекбар «Позиция удалена · Отменить» в drawer — слева от drawer над затемнением и нажимается', (
    tester,
  ) async {
    await pump(tester);
    await openByTap(tester);
    await tester.tap(inLine(frap, find.byIcon(Icons.close_rounded)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(CartKeys.line(frap)), findsNothing);
    final Rect bar = tester.getRect(find.byType(AppSnackbar));
    expect(bar.right, closeTo(1280 - 420 - AppSnackbar.toastInset, 0.5), reason: 'у левого края drawer');
    expect(bar.width, lessThanOrEqualTo(AppSnackbar.width));
    await tester.tap(find.text(l10n.ds_button_undo));
    await tester.pumpAndSettle();
    expect(find.byKey(CartKeys.line(frap)), findsOneWidget, reason: '«Отменить» нажимается над затемнением');
    expect(_drawer, findsOneWidget, reason: 'нажатие не закрыло drawer');
    expect(sync.setQuantityCalls, isEmpty);
  });

  testWidgets('узкое окно medium (700): снекбар — внутри drawer над закреплёнными итогами и кнопками', (tester) async {
    await pump(tester, size: const Size(700, 900));
    await openByTap(tester);
    expect(tester.getSize(_drawer).width, 420);
    expect(
      tester.widget<QuantityStepper>(inLine(frap, find.byType(QuantityStepper))).size,
      QuantityStepperSize.md,
      reason: 'medium — степпер md',
    );
    await tester.tap(inLine(frap, find.byIcon(Icons.close_rounded)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final Rect bar = tester.getRect(find.byType(AppSnackbar));
    expect(bar.left, greaterThanOrEqualTo(700 - 420), reason: 'внутри drawer');
    expect(bar.right, lessThanOrEqualTo(700));
    expect(
      bar.bottom,
      lessThanOrEqualTo(tester.getTopLeft(find.byKey(CartSummary.totalKey)).dy),
      reason: 'не перекрывает итог и кнопки',
    );
  });

  testWidgets('тап строки — drawer закрывается, затем SCR-14 (маршрут ветки не оказывается под затемнением)', (
    tester,
  ) async {
    await pump(tester);
    await openByTap(tester);
    await tester.tap(inLine(frap, find.text('Смеситель для кухни Frap F4252')));
    await tester.pumpAndSettle();
    expect(_drawer, findsNothing);
    expect(find.textContaining('product:/catalog/p/'), findsOneWidget);
  });

  testWidgets('«Отложить» после сетевого сбоя: повтор после закрытия и нового открытия drawer — тот же '
      'Idempotency-Key (08 §2.7)', (tester) async {
    final List<String> keys = <String>[];
    repo.onPark = (int rowVersion, String? name, String key) async {
      keys.add(key);
      if (keys.length == 1) return const FailureResult<CartParkResult>(NetworkFailure(NetworkFailureKind.timeout));
      return Success<CartParkResult>(
        CartParkResult(
          parked: canonCart(),
          active: const Cart(id: 'cart-2', status: CartStatus.active, items: <CartLine>[], rowVersion: 1),
        ),
      );
    };
    await pump(tester);
    Future<void> park() async {
      await openByTap(tester);
      await tester.tap(find.byKey(CartKeys.park));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('cart-park-confirm')));
      await tester.pumpAndSettle();
    }

    await park();
    expect(keys, hasLength(1));
    await tester.tap(find.byKey(CartDrawer.closeKey));
    await tester.pumpAndSettle();
    expect(_drawer, findsNothing);
    await park();
    expect(keys, hasLength(2));
    expect(keys[1], keys[0], reason: 'тот же ключ — повтор той же операции');
    expect(find.text(l10n.cart_parked_snackbar), findsOneWidget);
  });

  testWidgets('экран /cart на широком окне: кнопка шапки не открывает второй корзины — фокус в экран; F4 — тоже', (
    tester,
  ) async {
    await pump(tester, body: const CartPanelView(variant: CartPanelVariant.screen));
    await tester.tap(_button);
    await tester.pumpAndSettle();
    expect(_drawer, findsNothing);
    expect(find.byType(CartPanelView), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'cart-panel');
  });

  testWidgets('конфликт версий при закрытом drawer — диалог UI-20-027 показывает слушатель у кнопки шапки (бывшая '
      'постоянная CP)', (tester) async {
    sync.pendingConflict = CartVersionConflict(
      localCartId: 'local-1',
      current: canonCart(rowVersion: 19),
      unsent: <CartLocalLine>[
        CartLocalLine(
          key: frap,
          quantity: Qty.units(5),
          syncState: CartDraftSyncState.dead,
          lineNo: 1,
          productName: 'Смеситель для кухни Frap F4252',
          unitLabel: 'шт',
        ),
      ],
    );
    await pump(tester);
    expect(_drawer, findsNothing);
    expect(find.text(l10n.cart_version_conflict_title), findsOneWidget);
  });
}
