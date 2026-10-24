// T-CART-004 (12 §3.4.1, P1) / AC-CART-005 / AC-UI-20-007 / AC-UI-15-007: смена варианта в строке корзины (10 CART-005;
// 02 UI-20-007 → SCR-15 в режиме смены, UI-15-007 «Заменить вариант»; 04 FLOW-012.A2). Лист SCR-15 — реальный
// `VariantReplaceSheet` фичи product_details, подключённый к порту корзины `cartVariantPickerProvider` (как в
// `app/di/overrides.dart`); сервер — фейк `CartRepository`. Данные синтетические.
//
// Проверяется:
// - новый вариант: `PUT /cart/items/{new}` (`mode=set`, то же количество и упаковка, rowVersion копии) → удаление
//   одной старой строки: строка с упаковкой — `DELETE /cart/items/{old}?packagingId=`, строка базовой единицы —
//   `PUT mode=set 0` (DELETE без `packagingId` удалил бы все строки варианта, 08 §4.7.3 Уточнения п. 1; RC-1);
//   строка показывает новый вариант, цена — из ответа сервера; строка упаковки старого варианта остаётся;
// - удаление старой строки не прошло после записанного PUT — оно уходит в очередь cart.sync, две строки не
//   остаются, количество не удваивается (RC-2);
// - вариант уже в корзине: `ConfirmDialog` «Вариант уже в корзине. Объединить количества?» с итоговым количеством;
//   «Отмена» — ни одного запроса, `rowVersion` прежний, лист открыт; подтверждение — одна строка с суммой;
// - текущий вариант — «Заменить вариант» disabled; вариант без остатка — disabled;
// - отказ сервера по новому варианту (422) — старая строка остаётся, DELETE не отправляется;
// - офлайн — «Вариант» недоступен (UI-20-007 disabled офлайн).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/di/overrides.dart' show cartUiOverrides;
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/enums.dart' show CartStatus;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_panel_view.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_repository.dart';
import 'package:optomstroy/features/product_details/presentation/widgets/variant_replace_sheet.dart';

import '../../../support/f_fakes.dart';
import '../support/cart_test_support.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

const CartLineKey chrome = CartLineKey('v-chrome');
const CartLineKey white = CartLineKey('v-white');

/// Строка «Смеситель, <вариант>» товара p-mix.
CartLine mixLine(String variant, String name, int units, {int price = 2350, String? packagingId}) => CartLine(
  variantId: 'v-$variant',
  productId: 'p-mix',
  productName: 'Смеситель Frap F4252',
  variantName: name,
  sku: 'F4252-$variant',
  quantity: LineQuantity(value: Qty.units(units), unitId: 'u-pc', packagingId: packagingId),
  packaging: packagingId == null
      ? null
      : CartPackaging(id: packagingId, unitId: 'u-pc', factor: Qty.units(10), name: 'Коробка'),
  unitPrice: Money.som(price),
  lineTotal: Money.som(price * units),
  available: Qty.units(24),
  remainingAvailable: Qty.units(20),
);

Cart mixCart(List<CartLine> items, {int rowVersion = 17}) => Cart(
  id: 'cart-1',
  status: CartStatus.active,
  items: items,
  rowVersion: rowVersion,
  warehouseId: 'wh-main',
  priceListId: 'pl-retail',
  itemsCount: items.length,
  subtotal: Money(items.fold<int>(0, (int a, CartLine l) => a + (l.lineTotal?.tyiyn ?? 0))),
  total: Money(items.fold<int>(0, (int a, CartLine l) => a + (l.lineTotal?.tyiyn ?? 0))),
);

Variant mixVariant(String id, String color, {int? available = 24, int price = 2350}) => Variant(
  id: 'v-$id',
  productId: 'p-mix',
  sku: 'F4252-$id',
  attributes: <String, String>{'Цвет': color},
  price: Price(priceListId: 'pl-retail', amount: Money.som(price)),
  stock: StockBalance(
    variantId: 'v-$id',
    warehouseId: 'wh-main',
    stockLevel: available == null || available <= 0 ? StockLevel.out : StockLevel.inStock,
    available: available == null ? null : Qty.units(available),
  ),
);

/// Каталог: только `GET /catalog/products/{id}/variants`.
final class _VariantsCatalog extends Fake implements CatalogRepository {
  final List<({String productId, String? warehouseId})> calls = <({String productId, String? warehouseId})>[];

  @override
  Future<Result<VariantList>> variants(
    String productId, {
    String? warehouseId,
    String? priceListId,
    bool? inStockOnly,
  }) async {
    calls.add((productId: productId, warehouseId: warehouseId));
    return Success<VariantList>(
      VariantList(
        items: <Variant>[
          mixVariant('chrome', 'Хром'),
          mixVariant('white', 'Белый', price: 2410),
          mixVariant('black', 'Чёрный', available: 0),
        ],
      ),
    );
  }
}

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
        variantName: l.variantName,
        step: Qty.units(1),
      ),
  ],
);

Finder inLine(CartLineKey key, Finder matching) =>
    find.descendant(of: find.byKey(CartKeys.line(key)), matching: matching);

List<FakeCall> callsOf(FakeCartRepository repo, String method) =>
    repo.calls.where((FakeCall c) => c.method == method).toList();

void main() {
  late FakeCartRepository repo;
  late FakeCartSync sync;
  late _VariantsCatalog catalog;
  late Cart current;

  setUp(() {
    repo = FakeCartRepository();
    sync = FakeCartSync(repo);
    catalog = _VariantsCatalog();
  });

  /// Сервер-фейк по 08 §4.7.3: строка — пара (variantId, packagingId); PUT `mode=set` ставит количество строки
  /// (0 — удаляет её); DELETE с `packagingId` удаляет одну строку, без `packagingId` — все строки варианта.
  /// [removalFailure] — отказ первой операции удаления (PUT `set 0` или DELETE), затем удаление проходит (RC-2).
  void serve(Cart initial, {Result<Cart>? putFailure, Failure? removalFailure}) {
    current = initial;
    Failure? failRemoval = removalFailure;
    repo.onFetch = () async => Success<Cart>(current);
    repo.onPutItem = (String variantId, CartItemPut put, String? key) async {
      if (putFailure != null) return putFailure;
      final String? pk = put.quantity.packagingId;
      final Failure? removalFails = failRemoval;
      if (put.quantity.value.isZero && removalFails != null) {
        failRemoval = null;
        return FailureResult<Cart>(removalFails);
      }
      final List<CartLine> items = <CartLine>[...current.items];
      final int i = items.indexWhere((CartLine l) => l.variantId == variantId && l.packagingId == pk);
      final String name = variantId == 'v-white' ? 'Белый' : (variantId == 'v-chrome' ? 'Хром' : variantId);
      if (put.quantity.value.isZero) {
        if (i >= 0) items.removeAt(i);
      } else {
        final CartLine next = mixLine(
          variantId.substring(2),
          name,
          put.quantity.value.milli ~/ 1000,
          price: variantId == 'v-white' ? 2410 : 2350,
          packagingId: pk,
        );
        if (i < 0) {
          items.add(next);
        } else {
          items[i] = next;
        }
      }
      current = mixCart(items, rowVersion: current.rowVersion + 1);
      return Success<Cart>(current);
    };
    repo.onDeleteItem = (String variantId, String? packagingId) async {
      final Failure? removalFails = failRemoval;
      if (removalFails != null) {
        failRemoval = null;
        return FailureResult<Cart>(removalFails);
      }
      current = mixCart(<CartLine>[
        for (final CartLine l in current.items)
          if (l.variantId != variantId || (packagingId != null && l.packagingId != packagingId)) l,
      ], rowVersion: current.rowVersion + 1);
      return Success<Cart>(current);
    };
  }

  String serverItems() => <String>[
    for (final CartLine l in current.items) '${l.variantId}/${l.packagingId}:${l.quantity.value.milli ~/ 1000}',
  ].join(', ');

  Future<void> pump(WidgetTester tester, Cart cart, {OnlineStatus online = OnlineStatus.online}) async {
    if (repo.onFetch == null) serve(cart);
    sync.snapshot = localOf(cart);
    repo.onListParked = (ParkedScope scope, String? cursor) async =>
        const Success<PageResult<CartParkedSummary>>(PageResult<CartParkedSummary>(items: <CartParkedSummary>[]));
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      cartApp(
        overrides: <Override>[
          cartVariantPickerProvider.overrideWithValue(showVariantReplaceSheet),
          catalogRepositoryProvider.overrideWithValue(catalog),
          ...cartOverrides(sync: sync, repo: repo, online: online),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openSheet(WidgetTester tester, CartLineKey key) async {
    await tester.tap(inLine(key, find.byKey(const ValueKey<String>('cart-line-variant'))));
    await tester.pumpAndSettle();
    expect(find.byKey(VariantReplaceKeys.sheet), findsOneWidget);
  }

  Future<void> choose(WidgetTester tester, String variantId) async {
    await tester.tap(
      find.descendant(of: find.byKey(VariantReplaceKeys.row(variantId)), matching: find.byType(AppRadio<String>)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('T-CART-004 (1): «Хром» qty 3 → «Белый» — PUT нового с тем же количеством и упаковкой, затем DELETE '
      'старого; строка показывает новый вариант (AC-CART-005, AC-UI-20-007)', (tester) async {
    await pump(tester, mixCart(<CartLine>[mixLine('chrome', 'Хром', 3)]));
    expect(inLine(chrome, find.textContaining('Хром')), findsOneWidget);

    await openSheet(tester, chrome);
    expect(catalog.calls.single, (productId: 'p-mix', warehouseId: 'wh-main'), reason: 'варианты на складе корзины');
    final Finder cta = find.byKey(VariantReplaceKeys.replace);
    expect(
      tester.widget<AppButton>(cta).onPressed,
      isNull,
      reason: 'выбран текущий вариант — «Заменить вариант» disabled (UI-15-007)',
    );

    await choose(tester, 'v-white');
    await tester.tap(cta);
    await tester.pumpAndSettle();

    final List<FakeCall> puts = callsOf(repo, 'putItem');
    expect(puts, hasLength(2));
    final CartItemPut put = puts.first.args[1]! as CartItemPut;
    expect(puts.first.args[0], 'v-white', reason: 'сначала PUT нового варианта');
    expect(
      (put.mode, put.quantity.value, put.quantity.unitId, put.quantity.packagingId, put.rowVersion),
      (CartPutMode.set, Qty.units(3), 'u-pc', null, 17),
    );
    expect(put.priceSnapshot, Money.som(2410), reason: 'цена, которую видел пользователь, — только для предупреждения');
    // Старая строка базовой единицы — `PUT mode=set 0` (не DELETE без packagingId: тот удалил бы все строки варианта).
    final CartItemPut removal = puts.last.args[1]! as CartItemPut;
    expect(
      (puts.last.args[0], removal.mode, removal.quantity.value, removal.quantity.unitId, removal.quantity.packagingId),
      ('v-chrome', CartPutMode.set, Qty.zero, 'u-pc', null),
    );
    expect(removal.rowVersion, 18, reason: 'версия из ответа PUT нового варианта');
    expect(callsOf(repo, 'deleteItem'), isEmpty);
    // RC-1/RC-2: намерение замены записано до PUT и снято после; неотправленное обеих строк снимает ответ сервера.
    final CartLineReplace journal = sync.replaceJournal.single;
    expect((journal.from, journal.to, journal.quantity), (chrome, white, Qty.units(3)));
    expect(sync.replaceEnded, 1);
    expect(sync.settleCalls.last, <CartLineKey>{chrome, white});

    expect(find.byKey(VariantReplaceKeys.sheet), findsNothing, reason: 'лист закрыт после замены');
    expect(find.byKey(CartKeys.line(chrome)), findsNothing);
    expect(inLine(white, find.textContaining('Белый')), findsOneWidget);
    expect(inLine(white, find.text('3')), findsOneWidget);
  });

  testWidgets('T-CART-004 (2)/(3): вариант уже в корзине — диалог «Объединить количества?» с итогом; «Отмена» — '
      'состав и rowVersion не изменились; подтверждение — одна строка с суммой (AC-CART-005)', (tester) async {
    await pump(tester, mixCart(<CartLine>[mixLine('chrome', 'Хром', 3), mixLine('white', 'Белый', 2, price: 2410)]));
    await openSheet(tester, chrome);
    await choose(tester, 'v-white');
    await tester.tap(find.byKey(VariantReplaceKeys.replace));
    // CTA листа в loading, пока открыт диалог (повторное нажатие невозможно) — без pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(ConfirmDialog), findsOneWidget);
    expect(find.text(l10n.variant_merge_confirm), findsOneWidget);
    expect(find.text('2 + 3 = 5 шт'), findsOneWidget, reason: 'итоговое количество в диалоге');

    await tester.tap(find.text(l10n.ds_button_cancel).last);
    await tester.pumpAndSettle();
    expect(callsOf(repo, 'putItem'), isEmpty);
    expect(callsOf(repo, 'deleteItem'), isEmpty);
    expect(current.rowVersion, 17, reason: '«Отмена» — rowVersion корзины не изменился');
    expect(sync.replaceJournal, isEmpty, reason: '«Отмена» — журнал замены не пишется');
    expect(find.byKey(VariantReplaceKeys.sheet), findsOneWidget, reason: 'лист остаётся открытым');

    await tester.tap(find.byKey(VariantReplaceKeys.replace));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.descendant(of: find.byType(ConfirmDialog), matching: find.text(l10n.variant_replace_cta)));
    await tester.pumpAndSettle();

    final List<FakeCall> puts = callsOf(repo, 'putItem');
    expect(
      <Object?>[for (final FakeCall c in puts) (c.args[0], (c.args[1]! as CartItemPut).quantity.value)],
      <Object?>[('v-white', Qty.units(5)), ('v-chrome', Qty.zero)],
    );
    expect(serverItems(), 'v-white/null:5');
    expect(find.byKey(CartKeys.line(chrome)), findsNothing);
    expect(inLine(white, find.text('5')), findsOneWidget, reason: 'одна строка с суммой количеств');
  });

  testWidgets('T-CART-004: вариант без остатка — disabled; отказ сервера по новому варианту — старая строка остаётся, '
      'DELETE не отправляется', (tester) async {
    serve(
      mixCart(<CartLine>[mixLine('chrome', 'Хром', 3)]),
      putFailure: const FailureResult<Cart>(ServerFailure(status: 422, code: 'STOCK_INSUFFICIENT')),
    );
    await pump(tester, current);
    await openSheet(tester, chrome);

    final AppRadio<String> black = tester.widget<AppRadio<String>>(
      find.descendant(of: find.byKey(VariantReplaceKeys.row('v-black')), matching: find.byType(AppRadio<String>)),
    );
    expect(black.onChanged, isNull, reason: 'нет остатка на складе корзины — выбрать нельзя');

    await choose(tester, 'v-white');
    await tester.tap(find.byKey(VariantReplaceKeys.replace));
    await tester.pumpAndSettle();
    expect(callsOf(repo, 'putItem'), hasLength(1));
    expect(callsOf(repo, 'deleteItem'), isEmpty);
    expect(find.byKey(VariantReplaceKeys.sheet), findsOneWidget);
    expect(find.byKey(CartKeys.line(chrome)), findsOneWidget);
  });

  testWidgets('T-CART-004 / RC-1: замена строки базовой единицы не трогает строку упаковки того же варианта '
      '(08 §4.7.3 Уточнения п. 1, 10 CART-005)', (tester) async {
    const CartLineKey chromeBox = CartLineKey('v-chrome', 'pk-box');
    await pump(
      tester,
      mixCart(<CartLine>[mixLine('chrome', 'Хром', 3), mixLine('chrome', 'Хром', 2, packagingId: 'pk-box')]),
    );
    expect(find.byKey(CartKeys.line(chromeBox)), findsOneWidget);

    await openSheet(tester, chrome);
    await choose(tester, 'v-white');
    await tester.tap(find.byKey(VariantReplaceKeys.replace));
    await tester.pumpAndSettle();

    expect(
      callsOf(repo, 'deleteItem').where((FakeCall c) => c.args[1] == null),
      isEmpty,
      reason: 'DELETE без packagingId удалил бы все строки варианта',
    );
    expect(serverItems(), 'v-chrome/pk-box:2, v-white/null:3', reason: 'строка упаковки старого варианта осталась');
    expect(find.byKey(CartKeys.line(chromeBox)), findsOneWidget);
    expect(find.byKey(CartKeys.line(chrome)), findsNothing);
    expect(inLine(white, find.text('3')), findsOneWidget);
  });

  testWidgets('T-CART-004: замена строки упаковки — `DELETE ?packagingId=` только этой строки; строка базовой единицы '
      'того же варианта остаётся', (tester) async {
    const CartLineKey chromeBox = CartLineKey('v-chrome', 'pk-box');
    await pump(
      tester,
      mixCart(<CartLine>[mixLine('chrome', 'Хром', 3), mixLine('chrome', 'Хром', 2, packagingId: 'pk-box')]),
    );
    await openSheet(tester, chromeBox);
    await choose(tester, 'v-white');
    await tester.tap(find.byKey(VariantReplaceKeys.replace));
    await tester.pumpAndSettle();

    final CartItemPut put = callsOf(repo, 'putItem').single.args[1]! as CartItemPut;
    expect((put.quantity.value, put.quantity.packagingId), (Qty.units(2), 'pk-box'), reason: 'та же упаковка');
    expect(callsOf(repo, 'deleteItem').single.args.take(2), <Object?>['v-chrome', 'pk-box']);
    expect(serverItems(), 'v-chrome/null:3, v-white/pk-box:2');
    expect(find.byKey(CartKeys.line(chrome)), findsOneWidget);
    expect(find.byKey(CartKeys.line(chromeBox)), findsNothing);
  });

  testWidgets('T-CART-004 / RC-2: PUT нового варианта записан, удаление старой строки не прошло — удаление уходит в '
      'очередь cart.sync; две строки не остаются, сумма не удваивается', (tester) async {
    serve(
      mixCart(<CartLine>[mixLine('chrome', 'Хром', 3), mixLine('white', 'Белый', 2, price: 2410)]),
      removalFailure: const NetworkFailure(NetworkFailureKind.serverUnavailable),
    );
    await pump(tester, current);
    await openSheet(tester, chrome);
    await choose(tester, 'v-white');
    await tester.tap(find.byKey(VariantReplaceKeys.replace));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('2 + 3 = 5 шт'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(ConfirmDialog), matching: find.text(l10n.variant_replace_cta)));
    await tester.pumpAndSettle();

    expect(sync.setQuantityCalls, <(CartLineKey, Qty)>[
      (chrome, Qty.zero),
    ], reason: 'удаление старой строки — в очередь');
    expect(find.byKey(VariantReplaceKeys.sheet), findsNothing, reason: 'замена завершена, лист закрыт');
    expect(find.byKey(CartKeys.line(chrome)), findsNothing, reason: 'старая строка скрыта до отправки удаления');
    expect(inLine(white, find.text('5')), findsOneWidget);

    // Очередь отправляет удаление после паузы ввода (Debouncer.cart).
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(serverItems(), 'v-white/null:5', reason: 'на сервере одна строка с суммой — без удвоения');
    final List<int> whitePuts = <int>[
      for (final FakeCall c in callsOf(repo, 'putItem'))
        if (c.args[0] == 'v-white') (c.args[1]! as CartItemPut).quantity.value.milli,
    ];
    expect(whitePuts, <int>[5000]);
    expect(find.byKey(CartKeys.line(chrome)), findsNothing);
  });

  testWidgets('UI-20-007: офлайн — «Вариант» недоступен', (tester) async {
    await pump(tester, mixCart(<CartLine>[mixLine('chrome', 'Хром', 3)]), online: OnlineStatus.offline);
    await tester.tap(inLine(chrome, find.byKey(const ValueKey<String>('cart-line-variant'))), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byKey(VariantReplaceKeys.sheet), findsNothing);
    expect(catalog.calls, isEmpty);
  });

  test('композиционный корень: порт SCR-15 (режим смены) подключён — showVariantReplaceSheet', () {
    final ProviderContainer root = ProviderContainer(overrides: <Override>[...cartUiOverrides]);
    addTearDown(root.dispose);
    expect(root.read(cartVariantPickerProvider), same(showVariantReplaceSheet));
  });
}
