// RM-F-005 (golden): SCR-20 «Корзина» на трёх классах окна (D-18, 03 §7.2; эталоны Windows) — compact (экран `/cart`),
// medium (side sheet `CartPanel.overlay` 320), expanded (постоянная `CartPanel.panel` 340 рядом с каталогом), корзина
// канонического примера 02 ч. C §3.2 (16 850,00 − 842,50 = 16 007,50); SCR-23 «Отложенные заказы» — compact (экран)
// и expanded (side sheet 400); CART-005: строка с «Вариант ›» (UI-20-007) и SCR-15 в режиме смены (UI-15-007).
// Палитра B «Оранжевый». Данные синтетические.
//
// Обновить эталоны: flutter test test/features/cart/golden --update-goldens
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/cart_panel.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/cart/presentation/screens/parked_carts_screen.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_panel_view.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_repository.dart';
import 'package:optomstroy/features/product_details/presentation/widgets/variant_replace_sheet.dart';

import '../../../support/f_fakes.dart';
import '../support/cart_test_support.dart';

CartLocalSnapshot _local(Cart cart) => CartLocalSnapshot(
  localCartId: 'local-1',
  dirty: false,
  baseRowVersion: cart.rowVersion,
  lines: <CartLocalLine>[
    for (final (int i, CartLine l) in cart.items.indexed)
      CartLocalLine(
        key: CartLineKey(l.variantId),
        quantity: l.quantity.value,
        syncState: CartDraftSyncState.synced,
        lineNo: i + 1,
        unitId: 'u-pc',
        unitLabel: 'шт',
        step: Qty.units(1),
      ),
  ],
);

final List<CartParkedSummary> _parked = <CartParkedSummary>[
  CartParkedSummary(
    id: 'pc-1',
    status: CartStatus.parked,
    rowVersion: 3,
    name: 'Бригада Асанова',
    ownerId: 'user-1',
    itemsCount: 5,
    total: const Money(1600750),
    parkedAt: cartNow.subtract(const Duration(hours: 2)),
    expiresAt: cartNow.add(const Duration(days: 5)),
  ),
  CartParkedSummary(
    id: 'pc-2',
    status: CartStatus.parked,
    rowVersion: 1,
    name: 'Восстановлена из заказа № 2026-000123',
    ownerId: 'user-1',
    itemsCount: 2,
    total: const Money(480000),
    restoredFromOrderId: 'o-123',
    parkedAt: cartNow.subtract(const Duration(days: 6)),
    expiresAt: cartNow.add(const Duration(hours: 20)),
  ),
];

Widget _scr20(String window, Size size) {
  final FakeCartRepository repo = FakeCartRepository();
  final FakeCartSync sync = FakeCartSync(repo);
  final Cart cart = canonCart();
  serveCart(repo, cart);
  sync.snapshot = _local(cart);
  repo.onListParked = (ParkedScope s, String? c) async =>
      Success<PageResult<CartParkedSummary>>(PageResult<CartParkedSummary>(items: _parked));
  return cartApp(
    size: size,
    overrides: cartOverrides(sync: sync, repo: repo, role: RoleCode.cashier),
    cartBuilder: switch (window) {
      'compact' => null,
      'medium' => (BuildContext context) => Scaffold(
        backgroundColor: context.colors.overlay,
        body: const Align(
          alignment: AlignmentDirectional.centerEnd,
          child: SizedBox(width: 320, child: CartPanelView(variant: CartPanelVariant.overlay)),
        ),
      ),
      _ => (BuildContext context) => Scaffold(
        backgroundColor: context.colors.background,
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Expanded(child: SizedBox.expand()),
            SizedBox(width: CartPanel.widthFor(size.width), child: const CartPanelView()),
          ],
        ),
      ),
    },
  );
}

Widget _scr23(String window, Size size) {
  final FakeCartRepository repo = FakeCartRepository();
  final FakeCartSync sync = FakeCartSync(repo);
  serveCart(repo, canonCart());
  repo.onListParked = (ParkedScope s, String? c) async =>
      Success<PageResult<CartParkedSummary>>(PageResult<CartParkedSummary>(items: _parked));
  return cartApp(
    size: size,
    initialLocation: window == 'compact' ? '/cart/parked' : '/cart',
    overrides: cartOverrides(sync: sync, repo: repo, role: RoleCode.seller),
    cartBuilder: window == 'compact'
        ? null
        : (BuildContext context) => Scaffold(
            backgroundColor: context.colors.overlay,
            body: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Container(width: 400, color: context.colors.surface, child: const ParkedCartsBody(asSheet: true)),
            ),
          ),
  );
}

/// Каталог для SCR-15 (режим смены): три варианта, «Чёрный» без остатка.
final class _VariantsCatalog extends Fake implements CatalogRepository {
  static Variant _v(String id, String color, int price, int? available) => Variant(
    id: 'v-$id',
    productId: 'p-f4252',
    sku: 'F4252-$id',
    attributes: <String, String>{'Цвет': color},
    price: Price(priceListId: 'pl-retail', amount: Money.som(price)),
    stock: StockBalance(
      variantId: 'v-$id',
      warehouseId: 'wh-main',
      stockLevel: (available ?? 0) > 0 ? StockLevel.inStock : StockLevel.out,
      available: available == null ? null : Qty.units(available),
    ),
  );

  @override
  Future<Result<VariantList>> variants(
    String productId, {
    String? warehouseId,
    String? priceListId,
    bool? inStockOnly,
  }) async => Success<VariantList>(
    VariantList(
      items: <Variant>[_v('f4252', 'Хром', 2350, 24), _v('white', 'Белый', 2410, 6), _v('black', 'Чёрный', 2410, 0)],
    ),
  );
}

/// CART-005: строка с вариантом «Хром ›» (порт SCR-15 подключён) или лист SCR-15 в режиме смены.
Widget _variant(Size size, {required bool sheet}) {
  final FakeCartRepository repo = FakeCartRepository();
  final FakeCartSync sync = FakeCartSync(repo);
  final Cart base = canonCart();
  final CartLine first = base.items.first;
  final Cart cart = canonCart(
    items: <CartLine>[
      CartLine(
        variantId: first.variantId,
        productId: first.productId,
        productName: first.productName,
        variantName: 'Хром',
        sku: first.sku,
        quantity: first.quantity,
        unitPrice: first.unitPrice,
        lineTotal: first.lineTotal,
        available: first.available,
        remainingAvailable: first.remainingAvailable,
      ),
      ...base.items.skip(1),
    ],
  );
  serveCart(repo, cart);
  sync.snapshot = _local(cart);
  repo.onListParked = (ParkedScope s, String? c) async =>
      Success<PageResult<CartParkedSummary>>(PageResult<CartParkedSummary>(items: _parked));
  final List<Override> extra = <Override>[
    cartVariantPickerProvider.overrideWithValue(showVariantReplaceSheet),
    catalogRepositoryProvider.overrideWithValue(_VariantsCatalog()),
  ];
  return cartApp(
    size: size,
    overrides: <Override>[
      ...extra,
      ...cartOverrides(sync: sync, repo: repo, role: RoleCode.cashier),
    ],
    cartBuilder: sheet
        ? (BuildContext context) => Scaffold(
            backgroundColor: context.colors.surface,
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: VariantReplaceSheet(
                change: CartVariantChange(
                  productId: 'p-f4252',
                  currentVariantId: 'v-f4252',
                  quantity: Qty.units(2),
                  productName: 'Смеситель для кухни Frap F4252',
                  unitLabel: 'шт',
                  warehouseId: 'wh-main',
                ),
                onReplace: (CartVariantChoice c) async => false,
              ),
            ),
          )
        : null,
  );
}

void main() {
  setUpAll(() => EditableText.debugDeterministicCursor = true);
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  for (final MapEntry<String, Size> w in cartWindows.entries) {
    unawaited(
      goldenTest(
        'SCR-20 корзина · ${w.key}',
        fileName: 'cart_scr20_${w.key}',
        constraints: BoxConstraints.tight(w.value),
        builder: () => _scr20(w.key, w.value),
      ),
    );
  }
  for (final MapEntry<String, Size> w in <String, Size>{
    'compact': cartWindows['compact']!,
    'expanded': cartWindows['expanded']!,
  }.entries) {
    unawaited(
      goldenTest(
        'SCR-23 отложенные · ${w.key}',
        fileName: 'cart_scr23_${w.key}',
        constraints: BoxConstraints.tight(w.value),
        builder: () => _scr23(w.key, w.value),
      ),
    );
  }
  unawaited(
    goldenTest(
      'CART-005 строка «Вариант ›» · compact',
      fileName: 'cart_scr20_variant_compact',
      constraints: BoxConstraints.tight(cartWindows['compact']!),
      builder: () => _variant(cartWindows['compact']!, sheet: false),
    ),
  );
  unawaited(
    goldenTest(
      'CART-005 SCR-15 «Заменить вариант» · compact',
      fileName: 'cart_scr15_replace_compact',
      constraints: BoxConstraints.tight(cartWindows['compact']!),
      builder: () => _variant(cartWindows['compact']!, sheet: true),
    ),
  );
}
