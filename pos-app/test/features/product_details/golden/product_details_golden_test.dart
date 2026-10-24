// Golden SCR-14 «Карточка товара» на трёх классах окна compact / medium / expanded (D-18; 03 §7.2),
// палитра B. Данные синтетические (без фото — заглушка «Нет фото»; на фикстурах).
//
// Обновить эталоны: flutter test test/features/product_details/golden --update-goldens
// Проверить:        flutter test test/features/product_details/golden
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' show RoleCode;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/product_details/presentation/screens/product_details_screen.dart';

import '../product_fixtures.dart';

/// Окна golden SCR-14: ширина определяет класс окна.
const Map<String, Size> productGoldenWindows = <String, Size>{
  'compact': Size(390, 844),
  'medium': Size(800, 1000),
  'expanded': Size(1280, 900),
};

/// Карточка для эталона: 3 варианта по цвету, упаковка, описание, характеристики, 2 склада.
Product goldenProduct() {
  final Product base = multiVariantProduct();
  final List<Variant> variants = <Variant>[
    for (final Variant v in base.variants)
      Variant(
        id: v.id,
        productId: v.productId,
        isDefault: v.isDefault,
        sku: v.sku,
        attributes: v.attributes,
        price: v.price,
        stock: _timeless(v.stock),
        stockByWarehouse: <StockBalance>[
          ?_timeless(v.stock),
          stock(v.id, wh: 'wh-2', name: 'Склад №2', available: 5, reserved: 1, quantity: 6, noTime: true),
        ],
        unitId: v.unitId,
        sortOrder: v.sortOrder,
      ),
  ];
  return Product(
    summary: base.summary,
    description:
        'Однорычажный смеситель для ванны с коротким изливом. Керамический картридж 40 мм, '
        'аэратор с защитой от известкового налёта. В комплекте гибкая подводка и крепёж.',
    attributes: const <String, String>{
      'Бренд': 'Frap',
      'Страна': 'Китай',
      'Материал': 'латунь',
      'Монтаж': 'настенный',
      'Гарантия': '5 лет',
    },
    variants: variants,
    packagings: <Packaging>[Packaging(id: 'pk-box', unitId: box.id, name: 'кор', factor: Qty.units(6))],
    units: const <Unit>[pcs, box],
    onecCode: '00-00012345',
    prices: <Price>[
      price(2850),
      price(16500, packagingId: 'pk-box'),
    ],
  );
}

/// Остаток без метки времени: «обновлено HH:MM» зависит от часового пояса машины — в эталон не входит.
StockBalance? _timeless(StockBalance? s) => s == null
    ? null
    : StockBalance(
        variantId: s.variantId,
        warehouseId: s.warehouseId,
        warehouseName: s.warehouseName,
        quantity: s.quantity,
        reserved: s.reserved,
        available: s.available,
        stockLevel: s.stockLevel,
      );

/// Окружение: `MediaQuery` окна, reduce-motion, локаль `ru`, провайдеры с фейками.
class ProductGoldenWindow extends StatelessWidget {
  const ProductGoldenWindow({super.key, required this.size});

  final Size size;

  @override
  Widget build(BuildContext context) {
    final Product p = goldenProduct();
    return ProviderScope(
      overrides: productOverrides(
        catalog: FakeCatalogRepository(cached: p, network: Success<Product>(p)),
        role: RoleCode.seller,
      ),
      child: MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(size: size, disableAnimations: true, padding: EdgeInsets.zero, viewPadding: EdgeInsets.zero),
        child: Localizations(
          locale: const Locale('ru'),
          delegates: AppLocalizations.localizationsDelegates,
          child: Material(
            color: DsColors.lightB.background,
            child: SizedBox.fromSize(
              size: size,
              child: const ProductDetailsScreen(productId: 'p-1'),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  group('SCR-14 карточка товара', () {
    for (final MapEntry<String, Size> w in productGoldenWindows.entries) {
      unawaited(
        goldenTest(
          'SCR-14 · ${w.key} (${w.value.width.toInt()} lp)',
          fileName: 'scr14_product_${w.key}',
          constraints: BoxConstraints.tight(w.value),
          builder: () => ProductGoldenWindow(size: w.value),
        ),
      );
    }
  });
}
