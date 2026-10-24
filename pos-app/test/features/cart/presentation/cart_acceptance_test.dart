// T-UI-020 (12 §3.9) — недостающие кейсы приёмочного набора SCR-20 «Корзина» (02 SCR-20.13): по исполняемому кейсу
// на AC-UI-20-001, 005 (нампад), 008, 012, 016, 017, 021, 022, 023, 026, 029. Остальные AC набора — в
// cart_screen_test.dart, cart_variant_change_test.dart (AC-UI-20-007), parked/wiring-тестах. Фейковый `CartSync` и
// сервер — test/features/cart/support; данные синтетические, без реальной 1С.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/di/overrides.dart' show cartUiOverrides;
import 'package:optomstroy/app/router/app_router.dart';
import 'package:optomstroy/app/router/guards/role_guard.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/cart_panel.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/discount_input.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/cart/cart_providers.dart' show cartViewerNameProvider;
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_controller.dart' show cartPermissionsFor;
import 'package:optomstroy/features/cart/presentation/providers/cart_step_up_port.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_fab_view.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_panel_view.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';

import '../../../support/f_fakes.dart';
import '../support/cart_test_support.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

const CartLineKey frap = CartLineKey('v-f4252');
const CartLineKey frapBath = CartLineKey('v-f2283');

String money(int tyiyn) => PriceText.format(Money(tyiyn), fixed2: true);

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

List<FakeCall> callsOf(FakeCartRepository repo, String method) =>
    repo.calls.where((FakeCall c) => c.method == method).toList();

/// Корзина с другой скидкой (итоги считает сервер).
Cart withDiscount(Cart base, {required int percent, required int discount, required int total, int? limit}) => Cart(
  id: base.id,
  status: base.status,
  items: base.items,
  rowVersion: base.rowVersion + 1,
  warehouseId: base.warehouseId,
  priceListId: base.priceListId,
  itemsCount: base.itemsCount,
  subtotal: base.subtotal,
  requestedDiscountPercent: Percent(percent),
  appliedDiscountPercent: Percent(percent),
  discountTotal: Money(discount),
  total: Money(total),
  discountLimitPercent: Percent(limit ?? 1000),
  createdById: 'user-1',
);

void main() {
  late FakeCartRepository repo;
  late FakeCartSync sync;

  setUp(() {
    repo = FakeCartRepository();
    sync = FakeCartSync(repo);
  });

  Future<void> pump(
    WidgetTester tester, {
    Cart? cart,
    RoleCode role = RoleCode.seller,
    Size size = const Size(390, 900),
    List<Override> extra = const <Override>[],
  }) async {
    final Cart c = cart ?? canonCart();
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
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('AC-UI-20-001: expanded (1280×800) — постоянная панель 340 lp справа от каталога; compact (360×760) — '
      'CartFab над нижней навигацией', (tester) async {
    serveCart(repo, canonCart());
    sync.snapshot = localOf(canonCart());
    final ProviderContainer root = ProviderContainer(overrides: <Override>[...cartUiOverrides]);
    addTearDown(root.dispose);
    final CatalogCartPanelBuilder panel = root.read(catalogCartPanelProvider)!;
    final WidgetBuilder fab = root.read(catalogCartFabProvider)!;
    expect(CartPanel.widthFor(1280), DsBreakpoints.cartWide);
    expect(DsBreakpoints.cartWide, 340);

    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      cartApp(
        overrides: cartOverrides(sync: sync, repo: repo),
        cartBuilder: (BuildContext context) => Scaffold(
          body: Row(
            children: <Widget>[
              const Expanded(child: Center(child: Text('catalog-grid'))),
              SizedBox(width: CartPanel.widthFor(1280), child: panel(context)),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('catalog-grid'), findsOneWidget, reason: 'каталог виден одновременно с корзиной');
    expect(tester.getSize(find.byType(CartPanelView)).width, 340);
    expect(tester.getTopLeft(find.byType(CartPanelView)).dx, 1280 - 340, reason: 'панель справа');
    expect(find.byKey(CartKeys.line(frap)), findsOneWidget);

    tester.view.physicalSize = const Size(360, 760);
    await tester.pumpWidget(
      cartApp(
        overrides: cartOverrides(sync: sync, repo: repo),
        cartBuilder: (BuildContext context) => Scaffold(
          body: const Center(child: Text('catalog-grid')),
          floatingActionButton: fab(context),
          bottomNavigationBar: const SizedBox(height: 64, child: Text('bottom-nav')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CartFabView), findsOneWidget);
    expect(
      tester.getBottomLeft(find.byType(CartFabView)).dy <= tester.getTopLeft(find.text('bottom-nav')).dy,
      isTrue,
      reason: 'CartFab над нижней навигацией',
    );
  });

  testWidgets('AC-UI-20-005: нампад «0» — диалог «Удалить … из корзины?»; «Отмена» сохраняет прежнее количество', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(inLine(frap, find.byKey(const ValueKey<String>('quantity-stepper-value'))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('quantity-numpad')), findsOneWidget);
    for (int i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const ValueKey<String>('numpad-key-backspace')));
      await tester.pump();
    }
    await tester.tap(find.byKey(const ValueKey<String>('numpad-key-0')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('quantity-numpad-done')));
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmDialog), findsOneWidget);
    expect(find.text(l10n.cart_line_delete_dialog_title('Смеситель для кухни Frap F4252')), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(ConfirmDialog), matching: find.text(l10n.ds_button_cancel)));
    await tester.pumpAndSettle();
    expect(sync.setQuantityCalls, isEmpty);
    expect(inLine(frap, find.text('2')), findsOneWidget, reason: 'прежнее количество');
  });

  testWidgets('AC-UI-20-008: строка — миниатюра (заглушка), название, артикул, единица, цена за единицу и сумма строки '
      'с сервера', (tester) async {
    await pump(tester);
    expect(inLine(frap, find.byType(ProductImage)), findsOneWidget);
    expect(inLine(frap, find.text('Смеситель для кухни Frap F4252')), findsOneWidget);
    expect(inLine(frap, find.textContaining('F4252')), findsWidgets);
    expect(inLine(frap, find.textContaining(PriceText.format(Money.som(2350)))), findsWidgets);
    expect(inLine(frap, find.textContaining('шт')), findsWidgets);
    expect(inLine(frap, find.text(money(470000))), findsOneWidget, reason: 'сумма строки — из ответа сервера');
  });

  testWidgets('AC-UI-20-012, T-CART-014: «Очистить» — диалог «Очистить корзину? Будет удалено 5 позиций» (ICU plural); '
      'подтверждение → DELETE /cart, отложенные не меняются', (tester) async {
    repo.onClear = (int rv) async => Success<Cart>(canonCart(rowVersion: rv + 1, items: const <CartLine>[]));
    await pump(tester);
    await tester.tap(find.byKey(CartKeys.clear));
    await tester.pumpAndSettle();
    expect(find.text(l10n.cart_clear_dialog_body(5)), findsOneWidget);
    expect(find.text(l10n.cart_clear_dialog_title), findsOneWidget);
    expect(l10n.cart_clear_dialog_body(5), startsWith('Будет удалено 5 позиций'));
    // F-flutter-ui-19: ICU plural (02 §7) — «1 позиция», «3 позиции», «5 позиций», а не «1 позиций».
    expect(l10n.cart_clear_dialog_body(1), startsWith('Будет удалена 1 позиция'));
    expect(l10n.cart_clear_dialog_body(3), startsWith('Будет удалено 3 позиции'));
    expect(l10n.cart_clear_dialog_body(21), startsWith('Будет удалена 21 позиция'));
    await tester.tap(
      find.descendant(of: find.byType(ConfirmDialog), matching: find.text(l10n.cart_clear_dialog_confirm)),
    );
    await tester.pumpAndSettle();
    expect(callsOf(repo, 'clear').single.args.single, 17);
    expect(callsOf(repo, 'deleteParked'), isEmpty);
    expect(callsOf(repo, 'park'), isEmpty);
    expect(find.byKey(CartKeys.line(frap)), findsNothing);
  });

  testWidgets('AC-UI-20-016: двойное нажатие «Создать заказ →» — один переход в SCR-21 (одна предпроверка)', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(CartKeys.createOrder));
    await tester.tap(find.byKey(CartKeys.createOrder), warnIfMissed: false);
    await tester.pumpAndSettle();
    final GoRouter router = GoRouter.of(tester.element(find.textContaining('checkout:')));
    final int checkouts = router.routerDelegate.currentConfiguration.matches
        .where((RouteMatchBase m) => m.matchedLocation == '/checkout')
        .length;
    expect(checkouts, 1, reason: 'SCR-21 открыт один раз — POST /cart/checkout-preview выполняет один экран');
  });

  testWidgets(
    'AC-UI-20-017: каталог → корзина — состав, варианты, количества и скидка сохраняются (cartProvider уровня '
    'приложения)',
    (tester) async {
      await pump(tester);
      await tester.tap(inLine(frap, find.byKey(const ValueKey<String>('quantity-stepper-increment'))));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      final int puts = callsOf(repo, 'putItem').length;
      GoRouter.of(tester.element(find.byType(CartPanelView))).go('/catalog');
      await tester.pumpAndSettle();
      expect(find.text('catalog'), findsOneWidget);
      GoRouter.of(tester.element(find.text('catalog'))).go('/catalog/p/p-f4252');
      await tester.pumpAndSettle();
      GoRouter.of(tester.element(find.textContaining('product:'))).go('/cart');
      await tester.pumpAndSettle();
      expect(inLine(frap, find.text('3')), findsOneWidget);
      expect(find.byKey(CartKeys.line(frapBath)), findsOneWidget);
      expect(find.text(l10n.cart_summary_discount('5')), findsOneWidget);
      expect(callsOf(repo, 'putItem'), hasLength(puts), reason: 'переходы не меняют корзину');
    },
  );

  test('AC-UI-20-021: owner — /cart закрыт (G-7: «Раздел недоступен для вашей роли»)', () {
    for (final String path in <String>['/cart', '/cart/parked']) {
      expect(
        appRedirectNotice(
          status: SessionStatus.authenticated,
          uri: Uri.parse(path),
          mode: AppMode.seller,
          customerSelfService: true,
          role: RoleCode.owner,
        ),
        RoleGuardNotice.roleForbidden,
      );
    }
    expect(cartPermissionsFor(RoleCode.owner).canPark, isFalse);
    expect(cartPermissionsFor(RoleCode.owner).readOnlyParked, isTrue);
  });

  testWidgets('AC-UI-20-022: senior_seller, своя корзина, 8 % — POST /cart/discount без override и step-up; кнопки '
      '«Подтвердить скидку» нет; итог от сервера', (tester) async {
    final List<String> stepUps = <String>[];
    final List<(CartDiscountInput, String?)> calls = <(CartDiscountInput, String?)>[];
    final Cart base = canonCart();
    repo.onApplyDiscount = (CartDiscountInput input, String? token) async {
      calls.add((input, token));
      return Success<Cart>(withDiscount(base, percent: 800, discount: 134800, total: 1550200));
    };
    await pump(
      tester,
      role: RoleCode.seniorSeller,
      extra: <Override>[
        cartStepUpProvider.overrideWithValue((String op) async {
          stepUps.add(op);
          return 't';
        }),
      ],
    );
    await tester.enterText(find.byKey(DiscountInput.fieldKey), '8');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(calls, hasLength(1));
    expect(
      (calls.single.$1.percent, calls.single.$1.overrideReason, calls.single.$2),
      (const Percent(800), null, null),
    );
    expect(stepUps, isEmpty);
    expect(find.byKey(CartKeys.discountApprove), findsNothing);
    expect(find.text(money(1550200)), findsOneWidget, reason: 'итог пересчитан сервером');
  });

  testWidgets('AC-UI-20-023: senior_seller, своя корзина, 12 % — 422; «Применить 10 %» и «Как получить подтверждение», '
      'без «Подтвердить скидку»; 16 % — «Скидка больше 15 % не допускается» без эскалации', (tester) async {
    repo.onApplyDiscount = (CartDiscountInput input, String? token) async => const FailureResult<Cart>(
      ServerFailure(
        code: 'DISCOUNT_LIMIT_EXCEEDED',
        status: 422,
        details: <String, Object?>{'limitPercent': '10.00', 'requiresRole': 'admin'},
      ),
    );
    await pump(tester, role: RoleCode.seniorSeller);
    await tester.enterText(find.byKey(DiscountInput.fieldKey), '12');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text(money(1600750)), findsOneWidget, reason: 'итоги без изменений');
    expect(find.text(l10n.cart_discount_apply_limit('10')), findsOneWidget);
    expect(find.byKey(CartKeys.discountHow), findsOneWidget);
    expect(find.byKey(CartKeys.discountApprove), findsNothing);

    await tester.enterText(find.byKey(DiscountInput.fieldKey), '16');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.textContaining(l10n.cart_discount_over_max('15')), findsOneWidget);
    expect(find.byKey(CartKeys.discountHow), findsNothing, reason: 'без эскалации');
    expect(find.byKey(CartKeys.discountApprove), findsNothing);
  });

  testWidgets('AC-UI-20-026: количество больше доступного — предупреждение в строке, а не ошибка; корзина не трогает '
      'остатки (запросов к складу нет)', (tester) async {
    final Cart base = canonCart();
    serveCart(
      repo,
      base,
      onPut: (Cart before, String variantId, Qty qty) => Cart(
        id: before.id,
        status: before.status,
        rowVersion: before.rowVersion + 1,
        warehouseId: before.warehouseId,
        priceListId: before.priceListId,
        itemsCount: 5,
        subtotal: before.subtotal,
        total: before.total,
        items: <CartLine>[
          canonLine(
            'f4252',
            'Смеситель для кухни Frap F4252',
            'F4252',
            qty.milli ~/ 1000,
            2350,
            available: Qty.units(2),
            remaining: Qty.zero,
            warnings: const <CartItemWarning>[CartItemWarning.stockInsufficient],
          ),
          ...before.items.skip(1),
        ],
      ),
    );
    await pump(tester);
    await tester.tap(inLine(frap, find.byKey(const ValueKey<String>('quantity-stepper-increment'))));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(inLine(frap, find.text('3')), findsOneWidget, reason: 'количество принято сервером');
    expect(inLine(frap, find.text(l10n.cart_line_stock_available('2', 'шт'))), findsOneWidget);
    expect(find.text(l10n.cart_banner_stock(1)), findsOneWidget);
    expect(
      repo.calls.map((FakeCall c) => c.method).toSet().difference(<String>{'fetch', 'putItem', 'listParked'}),
      isEmpty,
      reason: 'корзина не вызывает ничего, кроме GET/PUT /cart (резерва при добавлении нет, D-22)',
    );
  });

  testWidgets('AC-UI-20-029: compact — «Отложить заказ» сверху, «Создать заказ →» снизу', (tester) async {
    await pump(tester, size: const Size(360, 760));
    final Rect park = tester.getRect(find.byKey(CartKeys.park));
    final Rect create = tester.getRect(find.byKey(CartKeys.createOrder));
    expect(park.bottom <= create.top, isTrue);
    expect((park.left - create.left).abs() < 1, isTrue, reason: 'столбиком');
  });

  testWidgets('UI-20-033 / FIX-FE-08: после override старшего — «Подтвердил: {name}» у поля скидки', (tester) async {
    final Cart base = canonCart();
    final Cart foreign = Cart(
      id: base.id,
      status: base.status,
      items: base.items,
      rowVersion: base.rowVersion,
      itemsCount: 5,
      subtotal: const Money(1685000),
      requestedDiscountPercent: const Percent(300),
      appliedDiscountPercent: const Percent(300),
      discountTotal: const Money(50550),
      total: const Money(1634450),
      discountLimitPercent: const Percent(500),
      warehouseId: 'wh-main',
      priceListId: 'pl-retail',
      createdById: 'user-author',
    );
    repo.onApplyDiscount = (CartDiscountInput input, String? token) async {
      if (input.overrideReason == null) {
        return const FailureResult<Cart>(
          ServerFailure(
            code: 'DISCOUNT_LIMIT_EXCEEDED',
            status: 422,
            details: <String, Object?>{'limitPercent': '5.00'},
          ),
        );
      }
      return Success<Cart>(
        Cart(
          id: foreign.id,
          status: foreign.status,
          items: foreign.items,
          rowVersion: foreign.rowVersion + 1,
          itemsCount: 5,
          subtotal: foreign.subtotal,
          requestedDiscountPercent: const Percent(800),
          appliedDiscountPercent: const Percent(800),
          discountTotal: const Money(134800),
          total: const Money(1550200),
          discountLimitPercent: const Percent(500),
          warehouseId: 'wh-main',
          priceListId: 'pl-retail',
          createdById: 'user-author',
        ),
      );
    };
    await pump(
      tester,
      cart: foreign,
      role: RoleCode.seniorSeller,
      extra: <Override>[
        cartStepUpProvider.overrideWithValue((String op) async => 'step-up-token'),
        cartViewerNameProvider.overrideWithValue('Айгуль Старшая'),
      ],
    );
    await tester.enterText(find.byKey(DiscountInput.fieldKey), '8');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(CartKeys.discountApprove));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(of: find.byType(ConfirmDialog), matching: find.byType(EditableText)),
      'Оптовый клиент',
    );
    await tester.pump();
    await tester.tap(
      find.descendant(of: find.byType(ConfirmDialog), matching: find.text(l10n.cart_discount_approve_button('8'))).last,
    );
    await tester.pumpAndSettle();
    expect(find.text(l10n.cart_discount_approved_by('Айгуль Старшая')), findsOneWidget);
    expect(find.text(money(1550200)), findsOneWidget);
  });
}
