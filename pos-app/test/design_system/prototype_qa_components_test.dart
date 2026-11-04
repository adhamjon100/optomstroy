// Компоненты экрана выбора товаров и drawer корзины после QA прототипа 2026-10-29 (ADR-112): подпись карточки ленты
// без уменьшения кегля и без переноса внутри слова, нейтральная контурная кнопка и текстовая кнопка сброса, степпер-группа
// drawer, сумма строки корзины одним кеглем, значок успеха тоста; раунд 2 — блок подписи ленты у низа карточки,
// название строки drawer 13/600, глиф «Список»; «точь-в-точь» 2026-10-31 (ADR-114): степпер-группа 102 × 34, сумма
// строки 15/800, глифы прототипа вида и тоста. Данные синтетические.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/cart_line.dart';
import 'package:optomstroy/design_system/components/category_tile.dart';
import 'package:optomstroy/design_system/components/ds_glyph.dart';
import 'package:optomstroy/design_system/components/ds_hairline.dart';
import 'package:optomstroy/design_system/components/quantity_stepper.dart';
import 'package:optomstroy/design_system/components/view_mode_segmented.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

import 'ds_test_support.dart';

const DsColors _c = DsColors.lightB;

void main() {
  testWidgets('CategoryTile.ribbon: длинное слово — одна строка с многоточием, кегль 13 не уменьшается', (
    tester,
  ) async {
    await pumpDs(
      tester,
      SizedBox.fromSize(
        size: CategoryTile.ribbonSize,
        child: CategoryTile(variant: CategoryTileVariant.ribbon, label: 'Электроинструмент', onTap: () {}),
      ),
    );
    expect(tester.takeException(), isNull);
    final Text label = tester.widget<Text>(find.byKey(const ValueKey<String>('category-tile-label')));
    expect(label.data, 'Электроинструмент');
    expect(label.maxLines, 1, reason: 'слово не переносится посередине');
    expect(label.softWrap, isFalse);
    expect(label.overflow, TextOverflow.ellipsis);
    expect(label.style?.fontSize, 13);
    expect(label.textScaler?.scale(13) ?? 13, 13, reason: 'кегль ленты не уменьшается');
  });

  testWidgets('CategoryTile.ribbon: слова помещаются — обычный перенос в 2 строки', (tester) async {
    await pumpDs(
      tester,
      SizedBox.fromSize(
        size: CategoryTile.ribbonSize,
        child: CategoryTile(variant: CategoryTileVariant.ribbon, label: 'Для кухни', onTap: () {}),
      ),
    );
    final Text label = tester.widget<Text>(find.byKey(const ValueKey<String>('category-tile-label')));
    expect(label.data, 'Для кухни');
    expect(label.maxLines, 2);
  });

  testWidgets('AppButton.neutral — surface и textPrimary 600; сброс фильтров — AppButton.text primaryText', (
    tester,
  ) async {
    await pumpDs(
      tester,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AppButton(
            label: 'Отложить · F8',
            onPressed: () {},
            variant: AppButtonVariant.neutral,
            size: AppButtonSize.cta,
          ),
          AppButton(label: 'Сбросить фильтры', onPressed: () {}, variant: AppButtonVariant.text, size: AppButtonSize.s),
        ],
      ),
    );
    final Text park = tester.widget<Text>(find.text('Отложить · F8'));
    expect(park.style?.color, _c.textPrimary, reason: 'оранжевой остаётся только основная кнопка');
    expect(park.style?.fontWeight, FontWeight.w600);
    final Text reset = tester.widget<Text>(find.text('Сбросить фильтры'));
    // Ссылки — `primaryText` (ядро §24.1, DS-098); синий `info` — статусный цвет и цвет фокуса, не ссылки.
    expect(reset.style?.color, _c.primaryText, reason: 'сброс — текстовая кнопка primaryText');
    expect(reset.style?.color, isNot(_c.info));
    final Iterable<BoxDecoration> boxes = tester
        .widgetList<AnimatedContainer>(
          find.ancestor(of: find.text('Отложить · F8'), matching: find.byType(AnimatedContainer)),
        )
        .map((AnimatedContainer a) => a.decoration)
        .whereType<BoxDecoration>();
    final BoxDecoration box = boxes.firstWhere((BoxDecoration d) => d.border != null);
    expect(box.color, _c.surface);
    expect((box.border! as Border).top.color, AppButton.neutralBorder(_c));
    expect((box.border! as Border).top.width, 1);
  });

  testWidgets('QuantityStepper.group — визуально 102 × 34 (ADR-114), цели касания 44 × 44, число 14/600', (
    tester,
  ) async {
    await pumpDs(
      tester,
      Center(
        child: QuantityStepper(
          value: '2',
          increaseLabel: '+',
          decreaseLabel: '−',
          size: QuantityStepperSize.group,
          onIncrement: () {},
          onDecrement: () {},
        ),
      ),
    );
    // Занимаемое место — цели касания: 15 + 1 + 34 − 6 | 6 + 32 + 6 | 34 + 1 + 15 − 6 по ширине, 44 по высоте
    // (03 §7.4, §9.20) — 132 × 44 без изменения вида.
    final Size size = tester.getSize(find.byType(QuantityStepper));
    expect(size.width, 44 * 3);
    expect(size.height, QuantityStepperSize.groupTarget);
    // Видимая группа — обводка 1 радиус 9 вокруг 34 + 32 + 34 (прототип: 102 × 34).
    final Finder outline = find.descendant(
      of: find.byType(QuantityStepper),
      matching: find.byWidgetPredicate(
        (Widget w) =>
            w is DecoratedBox && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).border != null,
      ),
    );
    expect(tester.getSize(outline), const Size(102, 34));
    final BoxDecoration box = tester.widget<DecoratedBox>(outline).decoration as BoxDecoration;
    expect(box.borderRadius, const BorderRadius.all(Radius.circular(9)));
    expect((box.border! as Border).top.color, _c.border);
    expect(
      tester.getTopLeft(outline).dx - tester.getTopLeft(find.byType(QuantityStepper)).dx,
      QuantityStepper.groupOuterInset,
    );
    final Text value = tester.widget<Text>(find.text('2'));
    expect(value.style?.fontSize, 14);
    expect(value.style?.fontWeight, FontWeight.w600);
    // Знаки «−» (U+2212) и «+» — текстом 18/400, как в прототипе.
    for (final String sign in <String>['−', '+']) {
      final Text t = tester.widget<Text>(find.text(sign));
      expect((t.style?.fontSize, t.style?.fontWeight), (18, FontWeight.w400), reason: sign);
    }
  });

  testWidgets('CartLine.emphasized — суммы строк одним кеглем 15/800 без масштабирования (ADR-114)', (tester) async {
    Widget line(String key, int tyiyn) => CartLine(
      key: ValueKey<String>(key),
      title: 'Смеситель',
      quantity: const SizedBox(width: 102, height: 34),
      removeLabel: 'Удалить',
      lineTotal: Money(tyiyn),
      emphasized: true,
      onRemove: () {},
    );
    await pumpDs(
      tester,
      SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[line('a', 246800), line('b', 3218050)]),
      ),
    );
    expect(tester.takeException(), isNull);
    for (final String key in <String>['a', 'b']) {
      final Finder fitted = find.descendant(of: find.byKey(ValueKey<String>(key)), matching: find.byType(FittedBox));
      final Finder text = find.descendant(of: fitted, matching: find.byType(RichText));
      expect(tester.getSize(fitted).width, tester.getSize(text).width, reason: '$key: сумма не сжата');
    }
    final Text a = tester.widget<Text>(
      find.descendant(of: find.byKey(const ValueKey<String>('a')), matching: find.textContaining('сом')),
    );
    expect(a.style?.fontSize, 15, reason: 'прототип: lineSum 15/800');
    expect(a.style?.fontWeight, FontWeight.w800);
    // QA, раунд 2: название строки drawer — 13/600, до 2 строк; цвет — `catalogName` прототипа (ADR-114).
    final Text title = tester.widget<Text>(
      find.descendant(of: find.byKey(const ValueKey<String>('a')), matching: find.text('Смеситель')),
    );
    expect(title.style?.fontSize, 13);
    expect(title.style?.fontWeight, FontWeight.w600);
    expect(title.style?.color, _c.catalogName, reason: 'ADR-114: название — catalogName #16206A');
    expect(title.maxLines, 2);
  });

  testWidgets('CategoryTile.ribbon: блок подписи в 2 строки у низа (поле 10); одна строка — у верха блока', (
    tester,
  ) async {
    Widget tile(String key, String label) => SizedBox.fromSize(
      key: ValueKey<String>(key),
      size: CategoryTile.ribbonSize,
      child: CategoryTile(variant: CategoryTileVariant.ribbon, label: label, onTap: () {}),
    );
    await pumpDs(
      tester,
      Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[tile('one', 'Поддоны'), tile('two', 'Смесители для кухни')],
      ),
    );
    expect(tester.takeException(), isNull);
    double labelTop(String key) {
      final Finder card = find.byKey(ValueKey<String>(key));
      final Finder label = find.descendant(
        of: card,
        matching: find.byKey(const ValueKey<String>('category-tile-label')),
      );
      return tester.getTopLeft(label).dy - tester.getTopLeft(card).dy;
    }

    // Прототип: обводка 1,5 (при DPR 1 — 1, DsHairline) + поле 8 + картинка 92 + (внутренняя высота − 92 − блок
    // подписи): блок max(31, строки) прижат к низу, поле 10 — подпись в одну строку у верха блока, на линии первой
    // строки двухстрочной. Flutter округляет строку до целого (ADR-114: 16 против 15,6 у Inter), поэтому блок двух
    // строк 32 > 31 и первая строка двух — на 1 выше (в прототипе — на 0,2); высота строки — из раскладки.
    final double line = tester
        .getSize(
          find.descendant(
            of: find.byKey(const ValueKey<String>('one')),
            matching: find.byKey(const ValueKey<String>('category-tile-label')),
          ),
        )
        .height;
    final double border = DsHairline.widthFor(1.5, 1);
    final double inner = 148 - 2 * border - 8 - 10;
    double expected(int lines) =>
        border + 8 + 92 + (inner - 92 - math.max(CategoryTile.ribbonLabelMinHeight, lines * line));
    expect(labelTop('one'), moreOrLessEquals(expected(1), epsilon: 0.01), reason: 'одна строка — у верха блока');
    expect(labelTop('two'), moreOrLessEquals(expected(2), epsilon: 0.01), reason: 'блок двух строк — у низа');
    expect((labelTop('one') - labelTop('two')).abs(), lessThanOrEqualTo(1), reason: 'на линии первой строки двух ±1');
    // «Смесители для кухни» — две строки (не одна с многоточием): нижняя строка — на высоте второй строки блока.
    final Finder two = find.byKey(const ValueKey<String>('two'));
    final Finder first = find.descendant(of: two, matching: find.byKey(const ValueKey<String>('category-tile-label')));
    final double span =
        tester.getBottomLeft(find.descendant(of: two, matching: find.byType(Text)).last).dy -
        tester.getTopLeft(first).dy;
    expect(span, greaterThan(13 * 1.2 * 1.5), reason: 'две строки');
  });

  testWidgets('ViewModeSegmented.toolbar: «Список» — контурный маркированный список DsGlyph.bulletList 16', (
    tester,
  ) async {
    await pumpDs(
      tester,
      ViewModeSegmented(
        value: ProductViewMode.grid,
        onChanged: (_) {},
        labels: const <ProductViewMode, String>{
          ProductViewMode.grid: 'Сетка',
          ProductViewMode.list: 'Список',
          ProductViewMode.compact: 'Компакт',
        },
        style: ViewModeSegmentedStyle.toolbar,
      ),
    );
    final Finder glyph = find.byWidgetPredicate((Widget w) => w is DsGlyph && w.kind == DsGlyphKind.bulletList);
    expect(glyph, findsOneWidget);
    expect(tester.widget<DsGlyph>(glyph).size, 16);
    expect(find.byIcon(Icons.view_list_rounded), findsNothing);
    // ADR-114: все три сегмента — глифы прототипа (залитая «сетка» 2×2, список, строки «Компакта»).
    for (final DsGlyphKind kind in <DsGlyphKind>[DsGlyphKind.gridFilled, DsGlyphKind.compactLines]) {
      expect(find.byWidgetPredicate((Widget w) => w is DsGlyph && w.kind == kind), findsOneWidget, reason: '$kind');
    }
    expect(find.byIcon(Icons.grid_view_rounded), findsNothing);
  });

  testWidgets('AppSnackbar.success — зелёный круг 18 с белой галочкой', (tester) async {
    await pumpDs(tester, const AppSnackbar(message: 'Добавлено: Смеситель', variant: AppSnackbarVariant.success));
    final Finder icon = find.byKey(AppSnackbar.successIconKey);
    expect(tester.getSize(icon), const Size(18, 18));
    // ADR-114: глиф прототипа — круг `toastCheck` #2FB36A с галочкой `onSuccess`.
    final DsGlyph circle = tester.widget<DsGlyph>(icon);
    expect(circle.kind, DsGlyphKind.checkCircle);
    expect(circle.color, AppSnackbar.successCircle(_c));
    expect(AppSnackbar.successCircle(_c), _c.toastCheck);
    expect(circle.markColor, _c.onSuccess);
  });
}
