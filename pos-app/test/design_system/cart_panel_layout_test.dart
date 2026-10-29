// CartPanel (03 §9.27) в низком окне: найдено integration_test/catalog_flow_test.dart на Windows 1280×720 — зона E
// каталога с офлайн-баннером оставляла под шапкой ~316 lp, закреплённые итоги и кнопки переполняли Column
// (RenderFlex overflow). Ниже [CartPanel.compactHeight] строки, итоги и кнопки прокручиваются вместе.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/components/app_badge.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/cart_panel.dart';
import 'package:optomstroy/design_system/tokens/ds_elevation.dart';

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

Widget _drawer({ValueNotifier<double>? bottom, double height = 800, bool full = false}) {
  final Widget panel = CartPanel(
    variant: CartPanelVariant.overlay,
    title: 'Корзина',
    titleSuffix: '· 5 поз.',
    count: 5,
    counter: '5 поз. · 6 шт',
    onClose: () {},
    closeLabel: 'Закрыть корзину',
    // Полный состав drawer по прототипу (02 SCR-20.3): баннер, клиент и склад, строки, скидка и итоги, кнопки.
    banner: full ? const SizedBox(height: 40, child: Text('Нет сети')) : null,
    top: full ? const SizedBox(height: 56, child: Text('Клиент: не выбран ›')) : null,
    body: ListView(children: <Widget>[for (int i = 0; i < (full ? 8 : 2); i++) const SizedBox(height: 72)]),
    bottom: SizedBox(height: full ? 200 : 120, child: const Text('Итоги')),
    footer: const SizedBox(height: 48, child: Text('Отложить · F8 | Создать заказ · F9')),
  );
  return SizedBox(
    width: 420,
    height: height,
    child: bottom == null ? panel : AppSnackbarRegion(endInset: 420, bottomInset: bottom, child: panel),
  );
}

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

  testWidgets('drawer (overlay, ADR-112): «Корзина · 5 поз.» без бейджа, крестик, без радиуса, тень e3; высота низа — '
      'в AppSnackbarRegion', (WidgetTester tester) async {
    final ValueNotifier<double> bottom = ValueNotifier<double>(0);
    addTearDown(bottom.dispose);
    await pumpDs(tester, _drawer(bottom: bottom), size: const Size(420, 800), scroll: false);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Корзина · 5 поз.', findRichText: true), findsOneWidget);
    expect(find.byType(AppBadge), findsNothing, reason: 'суффикс вместо бейджа');
    expect(find.byKey(CartPanel.closeKey), findsOneWidget);
    final DecoratedBox box = tester.widget<DecoratedBox>(
      find.descendant(of: find.byType(CartPanel), matching: find.byType(DecoratedBox)).first,
    );
    final BoxDecoration decoration = box.decoration as BoxDecoration;
    expect(decoration.borderRadius, isNull, reason: 'drawer без радиуса');
    expect(decoration.boxShadow, DsElevation.defaults.e3);
    expect(bottom.value, greaterThanOrEqualTo(168), reason: 'итоги 120 + кнопки 48 (+ поля)');
  });

  testWidgets('drawer в окне 1024×800 (expanded, прототип): полный состав без переполнения, итоги и кнопки закреплены '
      'внизу, строки прокручиваются отдельно', (WidgetTester tester) async {
    await pumpDs(
      tester,
      Align(alignment: Alignment.centerRight, child: _drawer(full: true)),
      size: const Size(1024, 800),
      scroll: false,
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(CartPanel.scrollKey), findsNothing, reason: '800 ≥ compactHeight — низ закреплён');
    expect(tester.getSize(find.byType(CartPanel)).width, 420);
    expect(tester.getBottomLeft(find.text('Отложить · F8 | Создать заказ · F9')).dy, greaterThan(800 - 80));
    expect(find.text('Клиент: не выбран ›'), findsOneWidget);
    expect(find.text('Итоги'), findsOneWidget);
  });

  testWidgets('drawer в низком окне 1024×460: строки, итоги и кнопки прокручиваются вместе, кнопки достижимы', (
    WidgetTester tester,
  ) async {
    await pumpDs(
      tester,
      Align(alignment: Alignment.centerRight, child: _drawer(full: true, height: 460)),
      size: const Size(1024, 460),
      scroll: false,
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(CartPanel.scrollKey), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Отложить · F8 | Создать заказ · F9'),
      100,
      scrollable: find.descendant(of: find.byKey(CartPanel.scrollKey), matching: find.byType(Scrollable)).first,
    );
    expect(find.text('Отложить · F8 | Создать заказ · F9').hitTestable(), findsOneWidget);
  });
}
