// SCR-20 «Корзина» (RM-F-005, RM-F-013, RM-F-015; 02 ч. C SCR-20.13): widget-тесты на фейковом `CartSync`.
// - итоги только из ответа сервера: локальная сумма не показывается до ответа (метка «предварительно»);
// - степпер: число меняется сразу, серия изменений < 500 мс → один `PUT /cart/items/{variantId}` `mode=set`;
// - «−» на минимальном количестве — `ConfirmDialog`, «Отмена» сохраняет строку (CART-003/012);
// - крестик — «Позиция удалена · Отменить» 5 с (UI-20-028);
// - F9 «Создать заказ», F8 «Отложить заказ» (03 A11Y-009);
// - предупреждения цен/остатков (баннер, «Принять новые цены», «Уменьшить до N», CTA с причиной);
// - режим клиента (без «Отложить», скидки, клиента; «Отправить заявку»); офлайн; скидка сверх лимита (422);
//   конфликт версий (UI-20-027); склад (PATCH /cart); «восстановлена из заказа»; устаревшая копия; пустая корзина.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/discount_input.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/cart/presentation/cart_formats.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_step_up_port.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_submission_port.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_customer_picker.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_fab_view.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_panel_view.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/repositories/customers_repository.dart';

import '../../../support/f_fakes.dart';
import '../support/cart_test_support.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

const CartLineKey frap = CartLineKey('v-f4252');
const CartLineKey frapBath = CartLineKey('v-f2283');

String money(int tyiyn) => PriceText.format(Money(tyiyn), fixed2: true);

/// Синхронизированная копия корзины (единица «шт» — из кэша каталога).
CartLocalSnapshot localOf(Cart cart, {DateTime? syncedAt}) => CartLocalSnapshot(
  localCartId: 'local-1',
  dirty: false,
  baseRowVersion: cart.rowVersion,
  serverSyncedAt: syncedAt,
  lines: <CartLocalLine>[
    for (final (int i, CartLine l) in cart.items.indexed)
      CartLocalLine(
        key: CartLineKey(l.variantId, l.packagingId),
        quantity: l.quantity.value,
        syncState: CartDraftSyncState.synced,
        lineNo: i + 1,
        unitId: l.quantity.unitId,
        unitLabel: 'шт',
        productName: l.productName,
        step: Qty.units(1),
      ),
  ],
);

Finder inLine(CartLineKey key, Finder matching) =>
    find.descendant(of: find.byKey(CartKeys.line(key)), matching: matching);

Finder stepperPlus(CartLineKey key) => inLine(key, find.byKey(const ValueKey<String>('quantity-stepper-increment')));

Finder stepperMinus(CartLineKey key) => inLine(key, find.byKey(const ValueKey<String>('quantity-stepper-decrement')));

int putCount(FakeCartRepository repo) => repo.calls.where((FakeCall c) => c.method == 'putItem').length;

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
    OnlineStatus online = OnlineStatus.online,
    Size size = const Size(390, 900),
    bool withLocal = true,
    List<Override> extra = const <Override>[],
  }) async {
    final Cart c = cart ?? canonCart();
    if (repo.onFetch == null) serveCart(repo, c);
    if (withLocal) sync.snapshot = localOf(c);
    repo.onListParked ??= (ParkedScope scope, String? cursor) async =>
        const Success<PageResult<CartParkedSummary>>(PageResult<CartParkedSummary>(items: <CartParkedSummary>[]));
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      cartApp(
        overrides: <Override>[
          ...extra,
          ...cartOverrides(sync: sync, repo: repo, role: role, online: online),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('итоги — только с сервера: до ответа «предварительно» и прежний итог, после — итог ответа', (
    tester,
  ) async {
    serveCart(
      repo,
      canonCart(),
      onPut: (Cart before, String variantId, Qty qty) => Cart(
        id: before.id,
        status: before.status,
        rowVersion: before.rowVersion + 1,
        items: <CartLine>[
          canonLine('f4252', 'Смеситель для кухни Frap F4252', 'F4252', 3, 2350),
          ...before.items.skip(1),
        ],
        subtotal: const Money(1920000),
        appliedDiscountPercent: const Percent(500),
        requestedDiscountPercent: const Percent(500),
        discountTotal: const Money(96000),
        total: const Money(1824000),
        itemsCount: 5,
        discountLimitPercent: const Percent(500),
      ),
    );
    await pump(tester);
    expect(find.text(money(1600750)), findsOneWidget, reason: 'AC-UI-20-003');
    expect(find.text(money(-84250)), findsWidgets);
    expect(find.text(l10n.cart_summary_items(5)), findsOneWidget);
    expect(find.text(l10n.cart_summary_discount('5')), findsOneWidget);
    expect(find.text(l10n.cart_summary_preliminary), findsNothing);

    await tester.tap(stepperPlus(frap));
    await tester.pump(const Duration(milliseconds: 100));
    expect(inLine(frap, find.text('3')), findsOneWidget, reason: 'число меняется сразу (optimistic)');
    expect(find.text(money(1600750)), findsOneWidget, reason: 'клиент не пересчитывает итог');
    expect(find.text(l10n.cart_summary_preliminary), findsOneWidget);
    expect(putCount(repo), 0);

    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(putCount(repo), 1);
    expect(find.text(money(1824000)), findsOneWidget);
    expect(find.text(money(1600750)), findsNothing);
    expect(find.text(l10n.cart_summary_preliminary), findsNothing);
  });

  testWidgets('серия «+» с интервалом < 500 мс → один PUT mode=set с итоговым количеством (AC-UI-20-004)', (
    tester,
  ) async {
    await pump(tester);
    for (int i = 0; i < 3; i++) {
      await tester.tap(stepperPlus(frap));
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(inLine(frap, find.text('5')), findsOneWidget);
    expect(sync.setQuantityCalls.map(((CartLineKey, Qty) c) => c.$2.milli), <int>[3000, 4000, 5000]);
    expect(putCount(repo), 0);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    final List<FakeCall> puts = repo.calls.where((FakeCall c) => c.method == 'putItem').toList();
    expect(puts, hasLength(1));
    final CartItemPut put = puts.single.args[1]! as CartItemPut;
    expect((put.mode, put.quantity.value, puts.single.args[0]), (CartPutMode.set, Qty.units(5), 'v-f4252'));
    expect(sync.syncCalls, 1);
  });

  testWidgets('AC-UI-20-005: «−» на минимальном количестве — ConfirmDialog; «Отмена» сохраняет строку, «Удалить» — 0', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(stepperMinus(frapBath));
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmDialog), findsOneWidget);
    expect(find.text(l10n.cart_line_delete_dialog_title('Смеситель для ванны Frap F2283')), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(ConfirmDialog), matching: find.text(l10n.ds_button_cancel)));
    await tester.pumpAndSettle();
    expect(find.byKey(CartKeys.line(frapBath)), findsOneWidget);
    expect(sync.setQuantityCalls, isEmpty);

    await tester.tap(stepperMinus(frapBath));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(ConfirmDialog), matching: find.text(l10n.qty_delete)));
    await tester.pumpAndSettle();
    expect(sync.setQuantityCalls.single, (frapBath, Qty.zero));
    expect(find.byKey(CartKeys.line(frapBath)), findsNothing);
  });

  testWidgets('«−» выше минимума уменьшает на шаг без диалога', (tester) async {
    await pump(tester);
    await tester.tap(stepperMinus(frap));
    await tester.pump();
    expect(find.byType(ConfirmDialog), findsNothing);
    expect(sync.setQuantityCalls.single, (frap, Qty.units(1)));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('крестик: «Позиция удалена · Отменить» — строка возвращается без запроса; без отмены — удаление', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(inLine(frap, find.byIcon(Icons.close_rounded)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // появление снекбара (ANIM-027)
    expect(find.text(l10n.cart_line_deleted_snackbar), findsOneWidget);
    expect(find.byKey(CartKeys.line(frap)), findsNothing);
    await tester.tap(find.text(l10n.ds_button_undo));
    await tester.pumpAndSettle();
    expect(find.byKey(CartKeys.line(frap)), findsOneWidget);
    expect(sync.setQuantityCalls, isEmpty, reason: 'AC-UI-20-006: DELETE не отправляется');

    await tester.tap(inLine(frap, find.byIcon(Icons.close_rounded)));
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(sync.setQuantityCalls.single, (frap, Qty.zero));
  });

  testWidgets('F9 — «Создать заказ» (SCR-21 с cartId), F8 — диалог «Отложить заказ» (03 A11Y-009)', (tester) async {
    await pump(tester, size: const Size(1280, 800));
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('cart-park-name')), findsOneWidget);
    await tester.tap(find.text(l10n.ds_button_cancel));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.f9);
    await tester.pumpAndSettle();
    expect(find.text('checkout:cartId=cart-1'), findsOneWidget);
  });

  testWidgets('«Отложить заказ»: POST /cart/park с ключом; корзина пустеет, снекбар «Заказ отложен»', (tester) async {
    repo.onPark = (int rowVersion, String? name, String key) async => Success<CartParkResult>(
      CartParkResult(
        parked: canonCart(),
        active: const Cart(id: 'cart-2', status: CartStatus.active, items: <CartLine>[], rowVersion: 1),
      ),
    );
    await pump(tester);
    await tester.tap(find.byKey(CartKeys.park));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey<String>('cart-park-name')), 'Бригада');
    await tester.tap(find.byKey(const ValueKey<String>('cart-park-confirm')));
    await tester.pumpAndSettle();
    final FakeCall park = repo.calls.singleWhere((FakeCall c) => c.method == 'park');
    expect((park.args[0], park.args[1]), (17, 'Бригада'));
    expect(park.args[2], isA<String>());
    expect(find.text(l10n.cart_parked_snackbar), findsOneWidget);
    expect(find.text(l10n.cart_empty_title), findsOneWidget);
  });

  testWidgets('цена изменилась: баннер с «Принять новые цены», строка «было → стало», CTA недоступна (AC-UI-20-009)', (
    tester,
  ) async {
    final Cart cart = canonCart(
      items: <CartLine>[
        canonLine(
          'f4252',
          'Смеситель для кухни Frap F4252',
          'F4252',
          2,
          2410,
          warnings: const <CartItemWarning>[CartItemWarning.priceChanged],
          priceSnapshot: Money.som(2350),
        ),
        canonLine('f2283', 'Смеситель для ванны Frap F2283', 'F2283', 1, 3450),
      ],
      warnings: <CartConflict>[
        CartConflict(
          variantId: 'v-f4252',
          rawKind: 'price_changed',
          oldPrice: Money.som(2350),
          newPrice: Money.som(2410),
        ),
      ],
    );
    await pump(tester, cart: cart);
    expect(find.text(l10n.cart_banner_prices_changed(1)), findsOneWidget);
    expect(
      find.text(
        l10n.cart_line_price_changed(PriceText.format(Money.som(2410)), PriceText.formatAmount(Money.som(2350))),
      ),
      findsOneWidget,
    );
    expect(find.text(l10n.cart_cta_reason_accept_prices), findsOneWidget);
    expect(tester.widget<AppButton>(find.byKey(CartKeys.createOrder)).onPressed, isNull);

    await tester.tap(find.byKey(CartKeys.bannerAction));
    await tester.pumpAndSettle();
    final FakeCall put = repo.calls.singleWhere((FakeCall c) => c.method == 'putItem');
    final CartItemPut body = put.args[1]! as CartItemPut;
    expect(
      (body.mode, body.quantity.value, body.priceSnapshot, body.rowVersion),
      (CartPutMode.set, Qty.units(2), Money.som(2410), 17),
    );
  });

  testWidgets('нехватка остатка: «Доступно 1 шт», «Уменьшить до 1» (AC-UI-20-010)', (tester) async {
    final Cart cart = canonCart(
      items: <CartLine>[
        canonLine(
          'f4252',
          'Смеситель для кухни Frap F4252',
          'F4252',
          2,
          2350,
          warnings: const <CartItemWarning>[CartItemWarning.stockInsufficient],
          available: Qty.units(1),
          remaining: Qty.zero,
        ),
      ],
      warnings: <CartConflict>[
        CartConflict(variantId: 'v-f4252', rawKind: 'stock_insufficient', available: Qty.units(1)),
      ],
    );
    await pump(tester, cart: cart);
    expect(find.text(l10n.cart_banner_stock(1)), findsOneWidget);
    expect(find.text(l10n.cart_line_stock_available('1', 'шт')), findsOneWidget);
    expect(find.text(l10n.cart_cta_reason_reduce_qty), findsOneWidget);
    expect(tester.widget<AppButton>(find.byKey(CartKeys.createOrder)).onPressed, isNull);
    await tester.tap(find.byKey(CartKeys.reduce(frap)));
    await tester.pump();
    expect(sync.setQuantityCalls.single, (frap, Qty.units(1)));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('режим клиента: нет «Отложить», «Отложенные», скидки и клиента; CTA «Отправить заявку» (AC-UI-20-030)', (
    tester,
  ) async {
    await pump(tester, role: RoleCode.customer);
    expect(find.byKey(CartKeys.park), findsNothing);
    expect(find.byKey(CartKeys.parked), findsNothing);
    expect(find.byType(DiscountInput), findsNothing);
    expect(find.byKey(CartKeys.customer), findsNothing);
    expect(find.byKey(CartKeys.warehouse), findsNothing);
    expect(find.text(l10n.cart_customer_submit), findsOneWidget);
    expect(find.text(l10n.cart_cta_create_order), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('cart-park-name')), findsNothing, reason: 'F8 у клиента не работает');
  });

  testWidgets('офлайн: баннер, «Создать» и «Отложить» недоступны с причиной «Нужна сеть…» (AC-UI-20-014)', (
    tester,
  ) async {
    sync.offline = true;
    await pump(tester, online: OnlineStatus.offline);
    expect(find.text(l10n.cart_banner_offline), findsOneWidget);
    expect(find.text(l10n.cart_cta_reason_offline), findsOneWidget);
    expect(tester.widget<AppButton>(find.byKey(CartKeys.createOrder)).onPressed, isNull);
    expect(tester.widget<AppButton>(find.byKey(CartKeys.park)).onPressed, isNull);
    // Изменение количества офлайн сохраняется локально.
    await tester.tap(stepperPlus(frap));
    await tester.pump(const Duration(milliseconds: 600));
    expect(sync.setQuantityCalls.single, (frap, Qty.units(3)));
    expect(putCount(repo), 0);
    expect(find.text(l10n.cart_save_state_queued(1)), findsOneWidget);
  });

  testWidgets('скидка сверх лимита: 422 — итоги прежние, «Применить 5 %» шлёт ровно один запрос (AC-UI-20-011)', (
    tester,
  ) async {
    final Cart base = canonCart();
    final Cart threePercent = Cart(
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
    );
    repo.onApplyDiscount = (CartDiscountInput input, String? token) async {
      if (input.percent.hundredths > 500) {
        return const FailureResult<Cart>(
          ServerFailure(
            code: 'DISCOUNT_LIMIT_EXCEEDED',
            status: 422,
            details: <String, Object?>{'limitPercent': '5.00', 'requiresRole': 'senior_seller'},
          ),
        );
      }
      return Success<Cart>(base);
    };
    await pump(tester, cart: threePercent);
    await tester.enterText(find.byKey(DiscountInput.fieldKey), '7');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    final List<FakeCall> first = repo.calls.where((FakeCall c) => c.method == 'applyDiscount').toList();
    expect(first, hasLength(1));
    expect((first.single.args[0]! as CartDiscountInput).percent, const Percent(700));
    expect(find.text(l10n.cart_discount_over_limit('3', '5')), findsOneWidget);
    expect(find.text(money(1634450)), findsOneWidget, reason: 'итоги — прежняя скидка 3 %');
    expect(find.text(l10n.cart_discount_apply_limit('5')), findsOneWidget);
    expect(find.text(l10n.cart_discount_approval_how), findsOneWidget);

    await tester.tap(find.byKey(CartKeys.discountApplyLimit));
    await tester.pumpAndSettle();
    final List<FakeCall> all = repo.calls.where((FakeCall c) => c.method == 'applyDiscount').toList();
    expect(all, hasLength(2));
    expect((all.last.args[0]! as CartDiscountInput).percent.toApiString(), '5.00');
    expect(find.text(money(1600750)), findsOneWidget);
    expect(find.text(l10n.cart_discount_over_limit('3', '5')), findsNothing);
  });

  testWidgets('AC-UI-20-015: 409 VERSION_CONFLICT — диалог UI-20-027 со списком изменений; «Оставить как на сервере»', (
    tester,
  ) async {
    await pump(tester);
    sync.emitConflict(
      CartVersionConflict(
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
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(l10n.cart_version_conflict_title), findsOneWidget);
    expect(find.text('Смеситель для кухни Frap F4252 — 5 шт'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('cart-conflict-keep-server')));
    await tester.pumpAndSettle();
    expect(sync.resolveCalls, <bool>[false]);
  });

  testWidgets('смена склада: меню складов → один PATCH /cart, снекбар (AC-UI-20-027)', (tester) async {
    repo.onSetWarehouse = (String id, int rv) async => Success<Cart>(canonCart(rowVersion: rv + 1));
    await pump(tester);
    expect(find.text(l10n.cart_warehouse_label('Розничная', 'Основной')), findsOneWidget);
    await tester.tap(find.byKey(CartKeys.warehouse));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('cart-warehouse-wh-2')));
    await tester.pumpAndSettle();
    final FakeCall call = repo.calls.singleWhere((FakeCall c) => c.method == 'setWarehouse');
    expect((call.args[0], call.args[1]), ('wh-2', 17));
    expect(find.text(l10n.cart_warehouse_changed('Склад №2')), findsOneWidget);
  });

  testWidgets('корзина, восстановленная из заказа, `restoredFromOrder = null` (номер серверу неизвестен) — баннер с '
      'номером из названия корзины', (tester) async {
    await pump(
      tester,
      cart: canonCart(restoredFromOrderId: 'o-77', name: 'Восстановлена из заказа № 2026-000123'),
    );
    expect(find.textContaining('2026-000123'), findsOneWidget);
  });

  testWidgets('Cart.restoredFromOrder (OpenAPI 1.2.0): баннер с номером и причиной отказа 1С', (tester) async {
    final Cart base = canonCart(restoredFromOrderId: 'o-77', name: 'Автосохранение');
    await pump(
      tester,
      cart: Cart(
        id: base.id,
        status: base.status,
        items: base.items,
        rowVersion: base.rowVersion,
        warehouseId: base.warehouseId,
        priceListId: base.priceListId,
        itemsCount: base.itemsCount,
        subtotal: base.subtotal,
        total: base.total,
        restoredFromOrderId: 'o-77',
        restoredFromOrder: const CartRestoredFromOrder(number: 'POS-2026-000123', reason: 'Нет остатка в 1С'),
      ),
    );
    expect(find.text(l10n.cart_banner_restored_from_order('POS-2026-000123', 'Нет остатка в 1С')), findsOneWidget);
  });

  testWidgets(
    '503 catalog_not_loaded у GET /cart: «Не удалось загрузить каталог · Повторить»; повтор через Retry-After',
    (tester) async {
      int fetches = 0;
      repo.onFetch = () async {
        fetches++;
        if (fetches == 1) {
          return const FailureResult<Cart>(
            OnecUnavailableFailure(
              retryAfter: Duration(seconds: 60),
              reason: OnecUnavailableFailure.catalogNotLoadedReason,
            ),
          );
        }
        return Success<Cart>(canonCart());
      };
      await pump(tester, withLocal: false);
      expect(fetches, 1);
      expect(find.text(l10n.catalog_error_title), findsOneWidget);
      expect(find.byKey(CartKeys.line(frap)), findsNothing);
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(fetches, 2, reason: 'повтор через Retry-After');
      expect(find.byKey(CartKeys.line(frap)), findsOneWidget);
    },
  );

  testWidgets('устаревшая копия: «Данные от HH:MM — обновляем…», CTA ждёт GET /cart (AC-UI-20-018)', (tester) async {
    final Cart cart = canonCart();
    final DateTime syncedAt = cartNow.subtract(const Duration(minutes: 20));
    sync.snapshot = localOf(cart, syncedAt: syncedAt);
    repo.onFetch = () => Future<Result<Cart>>.delayed(const Duration(seconds: 2), () => Success<Cart>(cart));
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    repo.onListParked = (ParkedScope s, String? c) async =>
        const Success<PageResult<CartParkedSummary>>(PageResult<CartParkedSummary>(items: <CartParkedSummary>[]));
    await tester.pumpWidget(
      cartApp(
        overrides: cartOverrides(sync: sync, repo: repo),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text(l10n.cart_banner_stale(CartFormats.time(syncedAt))), findsOneWidget);
    expect(find.text(l10n.cart_cta_reason_refreshing), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text(l10n.cart_banner_stale(CartFormats.time(syncedAt))), findsNothing);
    expect(tester.widget<AppButton>(find.byKey(CartKeys.createOrder)).onPressed, isNotNull);
  });

  testWidgets('после восстановления: «Корзина обновлена с сервера: изменено N позиций» (CART-009)', (tester) async {
    final Cart server = canonCart();
    sync.snapshot = localOf(
      canonCart(
        items: <CartLine>[
          canonLine('f4252', 'Смеситель для кухни Frap F4252', 'F4252', 7, 2350),
          ...server.items.skip(1),
        ],
      ),
    );
    serveCart(repo, server);
    await pump(tester, cart: server, withLocal: false);
    expect(find.text(l10n.cart_updated_from_server(1)), findsOneWidget);
    expect(inLine(frap, find.text('2')), findsOneWidget, reason: 'сервер — истина (CART-009)');
  });

  testWidgets('пустая корзина — EmptyState, CTA скрыты', (tester) async {
    await pump(tester, cart: canonCart(items: const <CartLine>[]));
    expect(find.text(l10n.cart_empty_title), findsOneWidget);
    expect(find.byKey(CartKeys.createOrder), findsNothing);
  });

  testWidgets('клавиатура Windows: ↓ → «+» → Delete → Ctrl+Z → F9 без мыши (AC-UI-20-020)', (tester) async {
    await pump(tester, size: const Size(1280, 800));
    Focus.of(tester.element(find.byKey(CartKeys.line(frap)))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadAdd);
    await tester.pump();
    expect(sync.setQuantityCalls.single, (frap, Qty.units(3)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(find.byKey(CartKeys.line(frap)), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.byKey(CartKeys.line(frap)), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.f9);
    await tester.pumpAndSettle();
    expect(find.text('checkout:cartId=cart-1'), findsOneWidget);
  });

  testWidgets('F-flutter-ui-1: результат POST /orders неизвестен — оверлей UI-20-020, изменения, F9 и «Создать» '
      'недоступны (AC-UI-20-019)', (tester) async {
    await pump(
      tester,
      size: const Size(1280, 800),
      extra: <Override>[
        cartSubmissionLockedProvider.overrideWithValue(true),
        cartSubmissionOverlayProvider.overrideWithValue(
          (BuildContext context) => const ColoredBox(
            color: Color(0xE6FFFFFF),
            child: Center(child: Text('lock')),
          ),
        ),
      ],
    );
    expect(find.byKey(CartKeys.lockOverlay), findsOneWidget);
    await tester.tap(find.byKey(CartKeys.createOrder), warnIfMissed: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.f9);
    await tester.pumpAndSettle();
    expect(find.textContaining('checkout:'), findsNothing);
    await tester.tap(stepperPlus(frap), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 600));
    expect(sync.setQuantityCalls, isEmpty);
    await tester.tap(find.byKey(CartKeys.customer), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byKey(CartCustomerPickerKeys.sheet), findsNothing);
  });

  testWidgets('F-flutter-ui-7: UI-20-004 — тап по строке клиента → поиск → POST /cart/customer с rowVersion копии; '
      'цены по условиям клиента — с сервера (AC-UI-20-024)', (tester) async {
    final FakeCustomersRepository customers = FakeCustomersRepository()
      ..onSearch = (CustomerSearchQuery q) async => const Success<PageResult<Customer>>(
        PageResult<Customer>(
          items: <Customer>[
            Customer(
              id: 'cust-1',
              name: 'Азамат Бекович',
              phones: <CustomerPhone>[CustomerPhone(valueE164: '+996700123456', verified: true)],
            ),
          ],
        ),
      );
    final List<(String, int)> set = <(String, int)>[];
    repo.onSetCustomer = (String id, int rv, Receiver? r) async {
      set.add((id, rv));
      return Success<Cart>(
        Cart(
          id: 'cart-1',
          status: CartStatus.active,
          rowVersion: rv + 1,
          customer: const Customer(id: 'cust-1', name: 'Азамат Бекович'),
          items: canonCart().items,
          warehouseId: 'wh-main',
          priceListId: 'pl-retail',
          total: const Money(1550000),
        ),
      );
    };
    await pump(
      tester,
      size: const Size(1280, 800),
      role: RoleCode.cashier,
      extra: <Override>[customersRepositoryProvider.overrideWithValue(customers)],
    );
    await tester.tap(find.byKey(CartKeys.customer));
    await tester.pumpAndSettle();
    expect(find.byKey(CartCustomerPickerKeys.sheet), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey<String>('customer-picker-field')),
        matching: find.byType(EditableText),
      ),
      'Аза',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('customer-picker-row-cust-1')));
    await tester.pumpAndSettle();
    expect(set, <(String, int)>[('cust-1', 17)]);
    expect(find.text('Азамат Бекович'), findsOneWidget);
  });

  testWidgets('F-flutter-ui-9: F4 — фокус в панель корзины (expanded), затем ↓ выбирает строку', (tester) async {
    await pump(tester, size: const Size(1280, 800));
    await tester.sendKeyEvent(LogicalKeyboardKey.f4);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'cart-panel');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadAdd);
    await tester.pump();
    expect(sync.setQuantityCalls.single, (frap, Qty.units(3)));
  });

  testWidgets('F-flutter-ui-9/10: CartFab — F4 открывает корзину (medium); диктор: позиции, единицы, сумма словами '
      '(AC-UI-20-002)', (tester) async {
    serveCart(repo, canonCart());
    sync.snapshot = localOf(canonCart());
    repo.onListParked = (ParkedScope scope, String? cursor) async =>
        const Success<PageResult<CartParkedSummary>>(PageResult<CartParkedSummary>(items: <CartParkedSummary>[]));
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final SemanticsHandle semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      cartApp(
        overrides: cartOverrides(sync: sync, repo: repo),
        cartBuilder: (BuildContext context) => const Scaffold(
          body: Align(alignment: Alignment.bottomCenter, child: CartFabView()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.bySemanticsLabel(RegExp(r'^Открыть корзину, 5 позиций, 6\s?шт, 16\s007 сом 50 тыйын$')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.f4);
    await tester.pumpAndSettle();
    expect(find.byKey(CartKeys.panel), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('F-flutter-data-1: конфликт, найденный до открытия корзины (восстановлен после перезапуска), — диалог '
      'UI-20-027 при открытии', (tester) async {
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
    expect(find.text(l10n.cart_version_conflict_title), findsOneWidget);
  });

  testWidgets(
    'F-flutter-ui-7: UI-20-033 — старший в возобновлённой чужой корзине: «Подтвердить скидку 8 %» → причина → '
    'step-up → POST /cart/discount с override (AC-UI-20-025)',
    (tester) async {
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
      final List<(CartDiscountInput, String?)> calls = <(CartDiscountInput, String?)>[];
      repo.onApplyDiscount = (CartDiscountInput input, String? token) async {
        calls.add((input, token));
        if (input.percent.hundredths > 500 && input.overrideReason == null) {
          return const FailureResult<Cart>(
            ServerFailure(
              code: 'DISCOUNT_LIMIT_EXCEEDED',
              status: 422,
              details: <String, Object?>{'limitPercent': '5.00', 'requiresRole': 'senior_seller'},
            ),
          );
        }
        return Success<Cart>(foreign);
      };
      final List<String> stepUps = <String>[];
      await pump(
        tester,
        cart: foreign,
        role: RoleCode.seniorSeller,
        extra: <Override>[
          cartStepUpProvider.overrideWithValue((String op) async {
            stepUps.add(op);
            return 'step-up-token';
          }),
        ],
      );
      await tester.enterText(find.byKey(DiscountInput.fieldKey), '8');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.byKey(CartKeys.discountApprove), findsOneWidget);
      expect(find.text(l10n.cart_discount_approve_button('8')), findsOneWidget);
      await tester.tap(find.byKey(CartKeys.discountApprove));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(of: find.byType(ConfirmDialog), matching: find.byType(EditableText)),
        'Оптовый клиент',
      );
      await tester.pump();
      await tester.tap(
        find
            .descendant(of: find.byType(ConfirmDialog), matching: find.text(l10n.cart_discount_approve_button('8')))
            .last,
      );
      await tester.pumpAndSettle();
      expect(stepUps, <String>['discount.approve.over_limit']);
      expect(calls.last.$1.percent, const Percent(800));
      expect(calls.last.$1.overrideReason, 'Оптовый клиент');
      expect(calls.last.$2, 'step-up-token');
    },
  );

  testWidgets('F-flutter-ui-7: UI-20-033 — в своей корзине override не предлагается', (tester) async {
    repo.onApplyDiscount = (CartDiscountInput input, String? token) async => const FailureResult<Cart>(
      ServerFailure(code: 'DISCOUNT_LIMIT_EXCEEDED', status: 422, details: <String, Object?>{'limitPercent': '10.00'}),
    );
    await pump(tester, role: RoleCode.seniorSeller);
    await tester.enterText(find.byKey(DiscountInput.fieldKey), '8');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.byKey(CartKeys.discountApprove), findsNothing);
  });

  testWidgets('T-CART-022, AC-CART-024: 201-я строка отклонена сервером (400 max_items) — снекбар «Слишком много '
      'позиций (максимум 200)…», корзина не меняется', (tester) async {
    await pump(tester);
    final int puts = putCount(repo);
    sync.emitRejected(
      const ValidationFailure(
        errors: <FieldError>[FieldError(field: 'quantity', rule: 'max_items')],
      ),
      key: const CartLineKey('v-new-201'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(l10n.cart_max_items('${Cart.maxItems}')), findsOneWidget);
    expect(find.text(l10n.cart_max_items('200')), findsOneWidget, reason: 'предел — 200 строк (ядро §20.2 п. 9)');
    expect(putCount(repo), puts, reason: 'клиент не повторяет отклонённую запись');
    expect(find.byKey(CartKeys.line(frap)), findsOneWidget, reason: 'прежние строки на месте');
  });

  testWidgets('T-CART-022: другой отказ записи (forbidden_field) — снекбара о пределе нет', (tester) async {
    await pump(tester);
    sync.emitRejected(
      const ValidationFailure(
        errors: <FieldError>[FieldError(field: 'price', rule: 'forbidden_field')],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(l10n.cart_max_items('200')), findsNothing);
  });

  testWidgets('T-CART-012: поле «Скидка __ %» — только при праве: у продавца есть, у владельца (без права) нет', (
    tester,
  ) async {
    await pump(tester, role: RoleCode.seller);
    expect(find.byType(DiscountInput), findsOneWidget, reason: 'seller: cart.discount.apply (11 §4.3)');
    await tester.pumpWidget(const SizedBox.shrink());
    await pump(tester, role: RoleCode.owner);
    expect(find.byType(DiscountInput), findsNothing, reason: 'owner: права скидки нет — поле не показывается');
    expect(find.byKey(CartKeys.park), findsNothing);
  });
}
