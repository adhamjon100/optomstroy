// Компоненты карточки товара RM-E-008 (03 §9.14, §9.15, §9.18…§9.22; ядро §17.5): ProductImage,
// ImageGallery, WarehouseStockTable, UnitSelector, QuantityStepper, QuantityNumpadSheet,
// VariantSelector. StockBadge — общий компонент каталога (тесты у владельца файла).
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/image_gallery.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/components/quantity_numpad_sheet.dart';
import 'package:optomstroy/design_system/components/quantity_stepper.dart';
import 'package:optomstroy/design_system/components/unit_selector.dart';
import 'package:optomstroy/design_system/components/variant_selector.dart';
import 'package:optomstroy/design_system/components/warehouse_stock_table.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

import 'ds_test_support.dart';

/// PNG 1×1 (прозрачный).
final Uint8List _png1x1 = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
  0x42, 0x60, 0x82,
]);

void main() {
  group('ProductImage', () {
    testWidgets('нет фото — заглушка «Нет фото» (INV-050)', (WidgetTester tester) async {
      await pumpDs(tester, const SizedBox(width: 200, child: ProductImage(url: null)));
      expect(find.byKey(const ValueKey<String>('product-image-placeholder')), findsOneWidget);
      expect(find.text('Нет фото'), findsOneWidget);
    });

    testWidgets('миниатюра < 64 — заглушка без подписи', (WidgetTester tester) async {
      await pumpDs(tester, const ProductImage(url: null, dimension: 48));
      expect(find.text('Нет фото'), findsNothing);
    });

    testWidgets('относительный путь сервера `/images/{sha}/card` загружается от адреса API (ProductImageBase)', (
      WidgetTester tester,
    ) async {
      final List<String> requested = <String>[];
      await pumpDs(
        tester,
        ProductImageBase(
          baseUri: Uri.parse('http://127.0.0.1:8080/api/v1'),
          child: ProductImageScope(
            providerFor: (String url) {
              requested.add(url);
              return MemoryImage(_png1x1);
            },
            child: const Column(
              children: <Widget>[
                ProductImage(url: '/images/5ae8/card', dimension: 120),
                ProductImage(url: 'https://cdn.example.test/images/ab/card', dimension: 120),
              ],
            ),
          ),
        ),
      );
      expect(requested, <String>['http://127.0.0.1:8080/images/5ae8/card', 'https://cdn.example.test/images/ab/card']);
      expect(
        ProductImageBase.resolveAgainst(null, '/images/x/card'),
        '/images/x/card',
        reason: 'без адреса — как есть',
      );
      expect(
        ProductImageBase.resolveAgainst(Uri.parse('http://h:3000/api/v1'), 'images/x/thumb'),
        'http://h:3000/images/x/thumb',
      );
    });

    test('путь файла по sha256 и размеру (RM-E-003)', () {
      expect(ProductImage.pathFor('ab12', ProductImageSize.thumb), '/images/ab12/thumb.webp');
      expect(ProductImage.pathFor('ab12', ProductImageSize.full), '/images/ab12/full.webp');
    });
  });

  group('ImageGallery', () {
    testWidgets('пустой список — одна заглушка, ленты нет', (WidgetTester tester) async {
      await pumpDs(tester, const SizedBox(width: 320, child: ImageGallery(images: <GalleryImage>[])));
      expect(find.byKey(const ValueKey<String>('product-image-placeholder')), findsOneWidget);
      expect(find.text('1 / 1'), findsNothing);
    });

    testWidgets('несколько фото — индикатор «2 / 3», тап по миниатюре', (WidgetTester tester) async {
      int? tapped;
      await pumpDs(
        tester,
        SizedBox(
          width: 320,
          child: ImageGallery(
            images: const <GalleryImage>[GalleryImage(url: null), GalleryImage(url: null), GalleryImage(url: null)],
            index: 1,
            onIndexChanged: (int i) => tapped = i,
          ),
        ),
      );
      expect(find.text('2 / 3'), findsOneWidget);
      expect(find.bySemanticsLabel('Фото 3 из 3'), findsWidgets);
      await tester.tap(find.bySemanticsLabel('Фото 3 из 3').last);
      await tester.pump();
      expect(tapped, 2);
    });
  });

  group('WarehouseStockTable', () {
    const List<WarehouseStockRow> rows = <WarehouseStockRow>[
      WarehouseStockRow(
        warehouseId: 'a',
        name: 'Склад А',
        available: '3',
        availableMilli: 3000,
        reserved: '1',
        quantity: '4',
      ),
      WarehouseStockRow(warehouseId: 'b', name: 'Склад Б', available: '20', availableMilli: 20000),
      WarehouseStockRow(
        warehouseId: 'c',
        name: 'Склад корзины',
        available: '0',
        availableMilli: 0,
        isCartWarehouse: true,
      ),
    ];

    testWidgets('seller: Склад · Доступно; склад корзины первым, затем по убыванию', (WidgetTester tester) async {
      await pumpDs(tester, const WarehouseStockTable(rows: rows, unit: 'шт', asOfTime: '09:41'));
      expect(find.text('Склад'), findsOneWidget);
      expect(find.text('Доступно'), findsOneWidget);
      expect(find.text('Резерв'), findsNothing);
      expect(WarehouseStockTable.sorted(rows).map((WarehouseStockRow r) => r.warehouseId), <String>['c', 'b', 'a']);
      expect(find.text('склад корзины'), findsOneWidget);
      expect(find.text('обновлено 09:41'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('warehouse-stock-total')), findsNothing);
      final Text zero = tester.widget<Text>(
        find.descendant(of: find.byKey(const ValueKey<String>('warehouse-stock-row-c')), matching: find.text('0')),
      );
      expect(zero.style!.color, DsColors.lightB.error);
    });

    testWidgets('cashier: + Остаток, Резерв; итог — только переданное значение сервера', (WidgetTester tester) async {
      await pumpDs(
        tester,
        const WarehouseStockTable(
          rows: rows,
          unit: 'шт',
          variant: WarehouseStockTableVariant.cashier,
          totalQuantity: '23',
        ),
      );
      expect(find.text('Остаток'), findsOneWidget);
      expect(find.text('Резерв'), findsOneWidget);
      expect(find.text('Доступно всего: 23 шт'), findsOneWidget);
    });

    testWidgets('пусто и ошибка с «Повторить»', (WidgetTester tester) async {
      int retries = 0;
      await pumpDs(
        tester,
        Column(
          children: <Widget>[
            const WarehouseStockTable(rows: <WarehouseStockRow>[]),
            WarehouseStockTable(rows: const <WarehouseStockRow>[], error: true, onRetry: () => retries++),
          ],
        ),
      );
      expect(find.text('Нет данных по складам'), findsOneWidget);
      expect(find.text('Не удалось получить остатки · Повторить'), findsOneWidget);
      await tester.tap(find.text('Повторить'));
      expect(retries, 1);
    });
  });

  group('UnitSelector', () {
    testWidgets('одна единица — readonly; ≤ 3 — сегменты; > 3 — список', (WidgetTester tester) async {
      String? picked;
      await pumpDs(
        tester,
        Column(
          children: <Widget>[
            const UnitSelector(
              options: <UnitOption>[UnitOption(id: '', label: 'шт')],
              selectedId: '',
            ),
            UnitSelector(
              options: const <UnitOption>[
                UnitOption(id: '', label: 'шт'),
                UnitOption(id: 'box', label: 'кор', detail: '6 шт'),
              ],
              selectedId: '',
              onChanged: (String id) => picked = id,
            ),
            UnitSelector(
              options: const <UnitOption>[
                UnitOption(id: '1', label: 'a'),
                UnitOption(id: '2', label: 'b'),
                UnitOption(id: '3', label: 'c'),
                UnitOption(id: '4', label: 'd'),
              ],
              selectedId: '1',
              onChanged: (_) {},
            ),
          ],
        ),
      );
      expect(find.byKey(const ValueKey<String>('unit-selector-readonly')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('unit-selector-segmented')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('unit-selector-dropdown')), findsOneWidget);
      expect(find.text('(6 шт)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('unit-option-box')));
      expect(picked, 'box');
    });
  });

  group('QuantityStepper', () {
    testWidgets('«+»/«−», недоступные кнопки, тап по числу; цели ≥ 48', (WidgetTester tester) async {
      int inc = 0;
      int taps = 0;
      await pumpDs(
        tester,
        QuantityStepper(
          value: '2',
          unit: 'шт',
          increaseLabel: '+',
          decreaseLabel: '−',
          onIncrement: () => inc++,
          onValueTap: () => taps++,
        ),
      );
      await tester.tap(find.byKey(const ValueKey<String>('quantity-stepper-increment')));
      await tester.tap(find.byKey(const ValueKey<String>('quantity-stepper-decrement')));
      await tester.tap(find.byKey(const ValueKey<String>('quantity-stepper-value')));
      expect((inc, taps), (1, 1));
      final Size plus = tester.getSize(find.byKey(const ValueKey<String>('quantity-stepper-increment')));
      expect(plus.width >= 48 && plus.height >= 48, isTrue);
    });

    testWidgets('удержание «−» — автоповтор каждые 150 мс после 500 мс (ANIM-007); удержание «+» — нампад', (
      WidgetTester tester,
    ) async {
      int dec = 0;
      int longPlus = 0;
      await pumpDs(
        tester,
        QuantityStepper(
          value: '10',
          increaseLabel: '+',
          decreaseLabel: '−',
          onIncrement: () {},
          onDecrement: () => dec++,
          onIncrementLongPress: () => longPlus++,
        ),
      );
      final TestGesture g = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey<String>('quantity-stepper-decrement'))),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 160));
      await tester.pump(const Duration(milliseconds: 160));
      await g.up();
      expect(dec, greaterThanOrEqualTo(2));
      await tester.longPress(find.byKey(const ValueKey<String>('quantity-stepper-increment')));
      expect(longPlus, 1);
    });
  });

  group('QuantityNumpadSheet', () {
    testWidgets('первая цифра заменяет значение; «,» недоступна при точности 0; «Готово»', (WidgetTester tester) async {
      QuantityNumpadResult? result;
      await pumpDs(
        tester,
        QuantityNumpadSheet(
          title: 'Количество · Смеситель',
          initialInput: '12',
          units: const <UnitOption>[UnitOption(id: '', label: 'шт')],
          selectedUnitId: '',
          decimalsFor: (_) => 0,
          validate: (String input, String unit) => const NumpadValidation(hint: 'Кратность: 1 шт'),
          onDone: (QuantityNumpadResult r) => result = r,
        ),
        size: const Size(400, 900),
      );
      await tester.tap(find.byKey(const ValueKey<String>('numpad-key-3')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('numpad-key-decimal')));
      await tester.tap(find.byKey(const ValueKey<String>('numpad-key-6')));
      await tester.pump();
      expect(find.text('36'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('numpad-key-backspace')));
      await tester.pump();
      expect(find.text('3'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey<String>('quantity-numpad-done')));
      expect(result!.input, '3');
    });

    testWidgets('дробная единица: «12,5»; ошибка блокирует «Готово» и предлагает округление', (
      WidgetTester tester,
    ) async {
      await pumpDs(
        tester,
        QuantityNumpadSheet(
          title: 'Количество · Труба',
          initialInput: '1',
          units: const <UnitOption>[UnitOption(id: '', label: 'м')],
          selectedUnitId: '',
          decimalsFor: (_) => 1,
          validate: (String input, String unit) => input == '12,5'
              ? const NumpadValidation(
                  error: 'Количество должно быть кратно 4 м',
                  roundUpLabel: 'Округлить до 16',
                  roundUpInput: '16',
                  canSubmit: false,
                )
              : const NumpadValidation(),
        ),
        size: const Size(400, 900),
      );
      for (final String k in <String>['1', '2', 'decimal', '5', '5']) {
        await tester.tap(find.byKey(ValueKey<String>('numpad-key-$k')));
        await tester.pump();
      }
      expect(find.text('12,5'), findsOneWidget, reason: 'не больше 1 знака после запятой');
      expect(find.text('Количество должно быть кратно 4 м'), findsOneWidget);
      expect(tester.widget<AppButton>(find.byKey(const ValueKey<String>('quantity-numpad-done'))).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey<String>('quantity-numpad-round-up')));
      await tester.pump();
      expect(find.text('16'), findsOneWidget);
    });
  });

  group('VariantSelector', () {
    testWidgets('чипы с выбранным значением; > 12 значений — список; ошибка', (WidgetTester tester) async {
      final List<(String, String)> picks = <(String, String)>[];
      await pumpDs(
        tester,
        VariantSelector(
          axes: <VariantAxis>[
            const VariantAxis(
              key: 'color',
              label: 'Цвет',
              selected: 'Хром',
              values: <VariantAxisValue>[
                VariantAxisValue(value: 'Хром'),
                VariantAxisValue(value: 'Чёрный', available: false),
                VariantAxisValue(value: 'Белый', combinationExists: false),
              ],
            ),
            VariantAxis(
              key: 'size',
              label: 'Размер',
              values: <VariantAxisValue>[for (int i = 0; i < 13; i++) VariantAxisValue(value: '$i')],
            ),
          ],
          titleFor: (VariantAxis a) => a.selected == null ? a.label : '${a.label}: ${a.selected}',
          onSelected: (String axis, String value) => picks.add((axis, value)),
          combinationMissingHint: 'Нет такого сочетания',
          errorText: 'Выберите Размер',
        ),
      );
      expect(find.text('Цвет: Хром'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('variant-option-size-0')),
        findsNothing,
        reason: '> 12 — выпадающий список',
      );
      expect(find.text('Выберите Размер'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('variant-option-color-Чёрный')));
      expect(picks, <(String, String)>[('color', 'Чёрный')], reason: 'без остатка — выбираемый (INV-012)');
    });
  });
}
