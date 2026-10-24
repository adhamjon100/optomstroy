// Golden SCR-50 «Главный экран клиента» на трёх брейкпоинтах compact / medium / expanded (D-18; RM-E-017
// критерий 3): шапка `customer` (без часов, `SyncIndicator`, «бургера» и сканера), «Мой кабинет» (заказы,
// долг при `confirmed`, избранное), «Ваш вид цены», категории (C — плитки, M/E — SB 240), недавние,
// сетка товаров (2 / 3 / 5 колонок) с `StockBadge` без чисел (`customer_stock_display=status`),
// `CartFab` (C/M) / кнопка корзины в шапке (E). Палитра B, reduce-motion, синтетические данные.
//
// Обновить эталоны: flutter test test/features/home/golden --update-goldens
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/home_fakes.dart';

const Map<String, Size> _windows = <String, Size>{
  'compact': Size(390, 844),
  'medium': Size(820, 1000),
  'expanded': Size(1366, 900),
};

Future<void> _prepare(WidgetTester tester) async {
  await precacheImages(tester);
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  setUpAll(() => EditableText.debugDeterministicCursor = true);
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  for (final MapEntry<String, Size> w in _windows.entries) {
    unawaited(
      goldenTest(
        'scr50_home · ${w.key}',
        fileName: 'home_scr50_${w.key}',
        constraints: BoxConstraints.tight(w.value),
        pumpBeforeTest: _prepare,
        builder: () => SizedBox(
          width: w.value.width,
          height: w.value.height,
          child: homeApp(HomeHarness(cartCount: 2), size: w.value),
        ),
      ),
    );
  }
}
