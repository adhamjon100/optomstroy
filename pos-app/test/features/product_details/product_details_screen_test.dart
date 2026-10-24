// SCR-14 «Карточка товара» (RM-E-008; 02 SCR-14, SCR-15, SCR-16; 12 T-CAT, T-INV): селектор
// вариантов скрыт у товара с одним вариантом; валидация количества QTY_NOT_MULTIPLE / QTY_BELOW_MIN
// по кратности и `qty_precision`; неизвестный остаток → «Добавить» недоступна (INV-052); клиент-
// покупатель в режиме `customer_stock_display=status` не видит чисел остатков и таблицы складов;
// «В корзину» пишет строку в черновик. Синтетические данные (на фикстурах, не реальная интеграция).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' show CustomerStockDisplay, RoleCode;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/quantity_numpad_sheet.dart';
import 'package:optomstroy/design_system/components/stock_badge.dart';
import 'package:optomstroy/design_system/components/variant_selector.dart';
import 'package:optomstroy/design_system/components/warehouse_stock_table.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';

import 'product_fixtures.dart';

/// Высокое окно класса compact (все зоны карточки видны без прокрутки).
const Size tallCompact = Size(390, 1600);

FakeCatalogRepository catalogOf(Product p) => FakeCatalogRepository(cached: p, network: Success<Product>(p));

AppButton ctaButton(WidgetTester tester) => tester.widget<AppButton>(find.byKey(const ValueKey<String>('product-cta')));

Future<void> enterOnNumpad(WidgetTester tester, String digits) async {
  for (final String d in digits.split('')) {
    await tester.tap(find.byKey(ValueKey<String>('numpad-key-${d == ',' ? 'decimal' : d}')));
    await tester.pump();
  }
}

Future<void> openNumpad(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('quantity-stepper-value')).first);
  await tester.pumpAndSettle();
  expect(find.byType(QuantityNumpadSheet), findsOneWidget);
}

void main() {
  group('шапка SCR-14 (02 SCR-14.2, UI-14-017)', () {
    final CategoryTree tree = CategoryTree.fromFlat(const <Category>[
      Category(id: 'c-mix', name: 'Смесители'),
      Category(id: 'c-kitchen', name: 'Для кухни', parentId: 'c-mix'),
    ]);

    testWidgets('compact: «Назад», название категории и кнопка поиска', (WidgetTester tester) async {
      final Product p = singleVariantProduct(categoryId: 'c-kitchen');
      await pumpProduct(
        tester,
        overrides: productOverrides(
          catalog: FakeCatalogRepository(cached: p, network: Success<Product>(p), tree: tree),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('product-back')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey<String>('product-header-category'))).data, 'Для кухни');
      expect(find.byKey(const ValueKey<String>('product-search')), findsOneWidget);
    });

    testWidgets('expanded: крошки «Каталог › Смесители › Для кухни»', (WidgetTester tester) async {
      final Product p = singleVariantProduct(categoryId: 'c-kitchen');
      await pumpProduct(
        tester,
        size: const Size(1366, 900),
        overrides: productOverrides(
          catalog: FakeCatalogRepository(cached: p, network: Success<Product>(p), tree: tree),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('product-breadcrumb-root')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('product-breadcrumb-c-mix')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('product-breadcrumb-c-kitchen')), findsOneWidget);
    });
  });

  group('варианты', () {
    testWidgets('товар с одним вариантом не показывает VariantSelector', (WidgetTester tester) async {
      await pumpProduct(tester, overrides: productOverrides(catalog: catalogOf(singleVariantProduct())));
      expect(find.text('Смеситель для кухни Ledeme L74103'), findsOneWidget);
      expect(find.byType(VariantSelector), findsNothing);
      expect(find.byKey(const ValueKey<String>('product-variants-list')), findsNothing);
      expect(find.text('Арт. варианта: L74103-BK'), findsOneWidget);
    });

    testWidgets('несколько вариантов: селектор, смена варианта обновляет артикул и цену без запроса', (
      WidgetTester tester,
    ) async {
      final FakeCatalogRepository catalog = catalogOf(multiVariantProduct());
      await pumpProduct(
        tester,
        size: tallCompact,
        overrides: productOverrides(catalog: catalog),
      );
      expect(find.byType(VariantSelector), findsOneWidget);
      expect(find.text('Цвет: Хром'), findsOneWidget);
      final int calls = catalog.productCalls.length;
      await tester.ensureVisible(find.byKey(const ValueKey<String>('variant-option-Цвет-Белый')));
      await tester.tap(find.byKey(const ValueKey<String>('variant-option-Цвет-Белый')));
      await tester.pump();
      expect(find.text('Арт. варианта: F4252-WH'), findsOneWidget);
      expect(find.textContaining('2 950'), findsWidgets);
      expect(catalog.productCalls.length, calls, reason: 'AC-UI-14-004: выбор варианта без сетевого запроса');
      // Вариант без остатка выбирается (INV-012), CTA — «Нет в наличии» (INV-023).
      await tester.ensureVisible(find.byKey(const ValueKey<String>('variant-option-Цвет-Чёрный матовый')));
      await tester.tap(find.byKey(const ValueKey<String>('variant-option-Цвет-Чёрный матовый')));
      await tester.pump();
      expect(ctaButton(tester).onPressed, isNull);
      expect(ctaButton(tester).label, 'Нет в наличии');
    });
  });

  group('количество (QTY_NOT_MULTIPLE / QTY_BELOW_MIN)', () {
    testWidgets('кратность 12: шаг степпера 12, ввод 30 → ошибка и «Округлить до 36»', (WidgetTester tester) async {
      await pumpProduct(
        tester,
        overrides: productOverrides(
          catalog: catalogOf(
            singleVariantProduct(multiplicity: Qty.units(12), stockOverride: stock('v-1', available: 240)),
          ),
        ),
      );
      expect(find.text('12'), findsWidgets, reason: 'начальное количество = шаг (кратность)');
      await tester.tap(find.byKey(const ValueKey<String>('quantity-stepper-increment')));
      await tester.pump();
      expect(find.text('24'), findsWidgets);

      await openNumpad(tester);
      await enterOnNumpad(tester, '30');
      expect(find.text('Количество должно быть кратно 12 шт'), findsOneWidget);
      final AppButton done = tester.widget<AppButton>(find.byKey(const ValueKey<String>('quantity-numpad-done')));
      expect(done.onPressed, isNull, reason: '«Готово» недоступна при нарушении правила');
      await tester.tap(find.byKey(const ValueKey<String>('quantity-numpad-round-up')));
      await tester.pump();
      expect(find.text('Количество должно быть кратно 12 шт'), findsNothing);
      await tester.tap(find.byKey(const ValueKey<String>('quantity-numpad-done')));
      await tester.pumpAndSettle();
      expect(find.byType(QuantityNumpadSheet), findsNothing);
      expect(find.text('36'), findsWidgets);
    });

    testWidgets('минимальная партия 5: начальное 5, ввод 3 → «Минимальная партия — 5 шт»', (WidgetTester tester) async {
      await pumpProduct(
        tester,
        overrides: productOverrides(catalog: catalogOf(singleVariantProduct(minQuantity: Qty.units(5)))),
      );
      expect(find.text('5'), findsWidgets);
      expect(
        tester.widget<AppButton>(find.byKey(const ValueKey<String>('product-cta'))).label,
        contains('14 250'),
        reason: 'сумма CTA = 5 × 2 850',
      );
      await openNumpad(tester);
      await enterOnNumpad(tester, '3');
      expect(find.text('Минимальная партия — 5 шт'), findsOneWidget);
      expect(tester.widget<AppButton>(find.byKey(const ValueKey<String>('quantity-numpad-done'))).onPressed, isNull);
    });

    testWidgets('qty_precision = 0: клавиша «,» недоступна; больше доступного — ошибка', (WidgetTester tester) async {
      await pumpProduct(tester, overrides: productOverrides(catalog: catalogOf(singleVariantProduct())));
      await openNumpad(tester);
      final Finder decimal = find.byKey(const ValueKey<String>('numpad-key-decimal'));
      await tester.tap(decimal);
      await tester.pump();
      expect(find.text('1'), findsWidgets);
      await enterOnNumpad(tester, '25');
      expect(find.textContaining('Доступно только 24 шт'), findsOneWidget);
    });

    testWidgets('упаковка «кор (6 шт)»: 10 шт → 2 кор с подсказкой «2 кор = 12 шт» (INV-003)', (
      WidgetTester tester,
    ) async {
      final Product p = singleVariantProduct(
        packagings: <Packaging>[Packaging(id: 'pk-box', unitId: box.id, name: 'кор', factor: Qty.units(6))],
      );
      await pumpProduct(
        tester,
        size: tallCompact,
        overrides: productOverrides(catalog: catalogOf(p)),
      );
      for (int i = 0; i < 9; i++) {
        await tester.tap(find.byKey(const ValueKey<String>('quantity-stepper-increment')));
        await tester.pump();
      }
      expect(find.text('10'), findsWidgets);
      await tester.ensureVisible(find.byKey(const ValueKey<String>('unit-option-pk-box')));
      await tester.tap(find.byKey(const ValueKey<String>('unit-option-pk-box')));
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('product-unit-hint')), findsOneWidget);
      expect(find.text('2 кор = 12 шт'), findsOneWidget);
    });
  });

  group('наличие', () {
    testWidgets('INV-052: неизвестный остаток → «Остаток неизвестен», «Добавление недоступно»', (
      WidgetTester tester,
    ) async {
      await pumpProduct(
        tester,
        overrides: productOverrides(catalog: catalogOf(singleVariantProduct(unknownStock: true))),
      );
      expect(find.text('Остаток неизвестен'), findsOneWidget);
      final AppButton cta = ctaButton(tester);
      expect(cta.onPressed, isNull);
      expect(cta.label, 'Добавление недоступно');
      expect(
        tester.widget<StockBadge>(find.byKey(const ValueKey<String>('product-stock-badge'))).level,
        StockBadgeLevel.unknown,
      );
    });

    testWidgets('нет цены (INV-013) — «Цена не указана», CTA недоступна', (WidgetTester tester) async {
      await pumpProduct(tester, overrides: productOverrides(catalog: catalogOf(singleVariantProduct(noPrice: true))));
      expect(find.text('Цена не указана'), findsOneWidget);
      expect(ctaButton(tester).onPressed, isNull);
    });

    testWidgets('снят с продажи (staff) — баннер и CTA недоступна (AC-UI-14-020)', (WidgetTester tester) async {
      await pumpProduct(
        tester,
        overrides: productOverrides(catalog: catalogOf(singleVariantProduct(deletionMark: true))),
      );
      expect(find.text('Товар больше не продаётся'), findsOneWidget);
      expect(ctaButton(tester).onPressed, isNull);
    });

    testWidgets('customer + status: без чисел остатков, без таблицы складов и кода 1С', (WidgetTester tester) async {
      final FakeCatalogRepository catalog = catalogOf(singleVariantProduct());
      await pumpProduct(
        tester,
        overrides: productOverrides(catalog: catalog, role: RoleCode.customer),
      );
      final StockBadge badge = tester.widget<StockBadge>(find.byKey(const ValueKey<String>('product-stock-badge')));
      expect(badge.level, StockBadgeLevel.inStock);
      expect(badge.label, isNot(contains('24')));
      expect(find.textContaining('24'), findsNothing);
      expect(find.byType(WarehouseStockTable), findsNothing);
      expect(find.byKey(const ValueKey<String>('product-tab-warehouses')), findsNothing);
      expect(find.textContaining('Код 1С'), findsNothing);
      expect(catalog.productCalls.single.priceListId, isNull, reason: 'AC-UI-14-018: запрос без priceListId');
    });

    testWidgets('customer + quantity: число доступного показывается', (WidgetTester tester) async {
      await pumpProduct(
        tester,
        overrides: productOverrides(
          catalog: catalogOf(singleVariantProduct()),
          role: RoleCode.customer,
          display: CustomerStockDisplay.quantity,
        ),
      );
      final StockBadge badge = tester.widget<StockBadge>(find.byKey(const ValueKey<String>('product-stock-badge')));
      expect(badge.label, 'В наличии · 24 шт');
      expect(find.byType(WarehouseStockTable), findsNothing);
    });

    testWidgets('seller на expanded: таблица складов без «Резерв»/«Остаток», итог только от сервера', (
      WidgetTester tester,
    ) async {
      await pumpProduct(
        tester,
        size: expandedWindow,
        overrides: productOverrides(catalog: catalogOf(singleVariantProduct())),
      );
      final WarehouseStockTable table = tester.widget<WarehouseStockTable>(find.byType(WarehouseStockTable));
      expect(table.variant, WarehouseStockTableVariant.seller);
      expect(table.totalQuantity, isNull, reason: 'AC-UI-14-006: без availableTotal строки итога нет');
      expect(find.text('Резерв'), findsNothing);
      expect(find.byKey(const ValueKey<String>('warehouse-stock-total')), findsNothing);
    });

    testWidgets('cashier: колонки «Остаток», «Резерв» и итог = availableTotal сервера', (WidgetTester tester) async {
      await pumpProduct(
        tester,
        size: expandedWindow,
        overrides: productOverrides(
          catalog: catalogOf(singleVariantProduct(availableTotal: Qty.units(27))),
          role: RoleCode.cashier,
        ),
      );
      expect(find.text('Резерв'), findsOneWidget);
      expect(find.text('Доступно всего: 27 шт'), findsOneWidget);
    });
  });

  group('«В корзину» → черновик корзины', () {
    testWidgets('добавление, «Добавить ещё», двойной клик в пределах 300 мс — одно добавление', (
      WidgetTester tester,
    ) async {
      final FakeCartDraftRepository cart = FakeCartDraftRepository();
      await pumpProduct(
        tester,
        overrides: productOverrides(catalog: catalogOf(singleVariantProduct()), cart: cart),
      );
      expect(ctaButton(tester).label, startsWith('В корзину · 2 850'));
      await tester.tap(find.byKey(const ValueKey<String>('product-cta')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const ValueKey<String>('product-cta')), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(cart.adds.length, 1, reason: 'AC-UI-14-012');
      expect(cart.adds.single.variantId, 'v-1');
      expect(cart.adds.single.quantity, Qty.units(1));
      expect(ctaButton(tester).label, 'Добавить ещё');
      expect(find.text('В корзине: 1 шт'), findsOneWidget);
      expect(find.text('Добавлено 1 шт · Открыть корзину'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('product-cta')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(cart.items.single.quantity, Qty.units(2), reason: 'CART-002: та же строка увеличена');
    });

    testWidgets('ошибка сети при кэше — данные остаются, inline-ошибка', (WidgetTester tester) async {
      await pumpProduct(
        tester,
        overrides: productOverrides(
          catalog: FakeCatalogRepository(
            cached: singleVariantProduct(),
            network: const FailureResult<Product>(NetworkFailure(NetworkFailureKind.offline)),
          ),
        ),
      );
      expect(find.text('Смеситель для кухни Ledeme L74103'), findsOneWidget);
      expect(find.text('Не удалось выполнить. Повторите'), findsOneWidget);
    });

    testWidgets('404 без кэша — «Товар не найден или снят с продажи»', (WidgetTester tester) async {
      await pumpProduct(
        tester,
        overrides: productOverrides(
          catalog: FakeCatalogRepository(
            network: const FailureResult<Product>(ServerFailure(code: 'NOT_FOUND', status: 404)),
          ),
        ),
      );
      expect(find.text('Товар не найден или снят с продажи'), findsOneWidget);
    });
  });
}
