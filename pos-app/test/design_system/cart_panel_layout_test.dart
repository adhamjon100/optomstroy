// CartPanel (03 §9.27) в низком окне: найдено integration_test/catalog_flow_test.dart на Windows 1280×720 — зона E
// каталога с офлайн-баннером оставляла под шапкой ~316 lp, закреплённые итоги и кнопки переполняли Column
// (RenderFlex overflow). Ниже [CartPanel.compactHeight] строки, итоги и кнопки прокручиваются вместе.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/components/cart_panel.dart';

import 'ds_test_support.dart';

Widget _panel() => CartPanel(
  title: 'Корзина',
  count: 2,
  banner: const SizedBox(height: 48, child: Text('Нет сети')),
  top: const SizedBox(height: 56, child: Text('Клиент · Склад')),
  body: ListView(children: const <Widget>[SizedBox(height: 72), SizedBox(height: 72)]),
  bottom: const SizedBox(height: 180, child: Text('Скидка · Итоги')),
  footer: const SizedBox(height: 96, child: Text('Создать заказ')),
);

void main() {
  testWidgets('низкое окно: без переполнения, область прокручивается, кнопки достижимы', (WidgetTester tester) async {
    await pumpDs(tester, SizedBox(width: 320, height: 420, child: _panel()), size: const Size(320, 420), scroll: false);
    expect(tester.takeException(), isNull);
    expect(find.byKey(CartPanel.scrollKey), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Создать заказ'),
      100,
      scrollable: find.descendant(of: find.byKey(CartPanel.scrollKey), matching: find.byType(Scrollable)).first,
    );
    expect(find.text('Создать заказ'), findsOneWidget);
  });

  testWidgets('обычная высота: итоги и кнопки закреплены снизу, список — в остатке', (WidgetTester tester) async {
    await pumpDs(tester, SizedBox(width: 320, height: 900, child: _panel()), size: const Size(320, 900), scroll: false);
    expect(tester.takeException(), isNull);
    expect(find.byKey(CartPanel.scrollKey), findsNothing);
    expect(tester.getBottomLeft(find.text('Создать заказ')).dy, greaterThan(700));
  });
}
