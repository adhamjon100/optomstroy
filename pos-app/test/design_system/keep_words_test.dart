// T-UI-117 (правила; пакет own-server:GAP-APP): суммы и номера целиком — без разрыва внутри слова и без сжатия
// `FittedBox` при крупном тексте (масштаб 1,3–1,5) на телефоне и в узких колонках. Проверяются общие средства, которыми
// исправлены 20 сцен списка `kRespKnown` (список пуст, T-UI-117 блокирует такие находки): `dsLongestWordWidth`,
// `DsKeepWordsText` (начертание на ступень меньше), `TitleTrailingBar.minTitleWidth` (элементы строкой ниже, если рядом
// не помещается самое длинное слово), `ReportTable` (числовая колонка не уже своего значения), `PriceText.stepDownToFit`,
// `CartLine` (сумма строки строкой ниже степпера). Шрифт — настоящий Inter (ширины — как в приложении).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/cart_line.dart';
import 'package:optomstroy/design_system/components/keep_words_text.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/report_table.dart';
import 'package:optomstroy/design_system/layout/text_measure.dart';
import 'package:optomstroy/design_system/layout/title_trailing_bar.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

import 'ds_test_support.dart';

/// «16 007,50 сом»: разряды и «сом» — неразрывный пробел U+00A0 (формат `PriceText`).
final String _money = PriceText.format(const Money(1600750));

Future<void> _scaled(WidgetTester tester, double scale) async {
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// Текст [p] разложен в одну строку (без переноса внутри слова).
bool _oneLine(WidgetTester tester, Finder p) {
  final RenderParagraph r = tester.renderObject<RenderParagraph>(
    find.descendant(of: p, matching: find.byType(RichText)).first,
  );
  return r.getMaxIntrinsicWidth(double.infinity) <= r.size.width + 0.5;
}

void main() {
  setUpAll(loadInterFont);

  testWidgets('dsLongestWordWidth: сумма с NBSP и номер заказа — одно слово; обычные пробелы делят', (tester) async {
    await pumpDs(tester, const SizedBox());
    final BuildContext context = tester.element(find.byType(SizedBox).first);
    final TextStyle s = context.text.body;
    expect(dsLongestWordWidth(context, _money, s), closeTo(dsTextWidth(context, _money, s), 0.01));
    expect(
      dsLongestWordWidth(context, 'Заказ № POS-2026-000123', s),
      closeTo(dsTextWidth(context, 'POS-2026-000123', s), 0.01),
    );
    expect(dsLongestWordWidth(context, '', s), 0);
  });

  testWidgets('DsKeepWordsText: слово не помещается — начертание на ступень меньше; помещается — основное', (
    tester,
  ) async {
    await _scaled(tester, 1.5);
    Widget text(double width) => SizedBox(
      width: width,
      child: Builder(
        builder: (BuildContext context) => DsKeepWordsText(
          _money,
          textKey: const ValueKey<String>('kw'),
          style: context.text.display,
          fallback: <TextStyle>[context.text.h1, context.text.h2, context.text.h3],
        ),
      ),
    );
    await pumpDs(tester, text(600), size: const Size(700, 400));
    expect(tester.widget<Text>(find.byKey(const ValueKey<String>('kw'))).style!.fontSize, 32, reason: 'display');
    await pumpDs(tester, text(300), size: const Size(700, 400));
    final double size = tester.widget<Text>(find.byKey(const ValueKey<String>('kw'))).style!.fontSize!;
    expect(size, lessThan(32), reason: 'ступень меньше');
    expect(_oneLine(tester, find.byKey(const ValueKey<String>('kw'))), isTrue, reason: 'сумма целиком в строке');
  });

  testWidgets('TitleTrailingBar.minTitleWidth: номер помещается рядом с чипом — в строку, текст переносится по словам; '
      'не помещается — чип строкой ниже, номер целиком', (tester) async {
    await _scaled(tester, 1.3);
    const String title = 'Заказ № POS-2026-000123 · Азамат Б.';
    Widget bar(double width) => SizedBox(
      width: width,
      child: Builder(
        builder: (BuildContext context) => TitleTrailingBar(
          alignTop: true,
          spacing: 8,
          minTitleWidth: dsLongestWordWidth(context, title, context.text.body),
          title: Text(title, key: const ValueKey<String>('t'), style: context.text.body),
          trailing: const SizedBox(key: ValueKey<String>('chip'), width: 120, height: 28),
        ),
      ),
    );
    await pumpDs(tester, bar(360), size: const Size(500, 400));
    RenderTitleTrailingBar box() => tester.renderObject<RenderTitleTrailingBar>(find.byType(TitleTrailingBar));
    expect(box().overflowed, isFalse, reason: '360: номер помещается рядом с чипом');
    expect(_oneLine(tester, find.byKey(const ValueKey<String>('t'))), isFalse, reason: 'текст переносится рядом');
    expect(
      tester.getTopLeft(find.byKey(const ValueKey<String>('chip'))).dy,
      tester.getTopLeft(find.byKey(const ValueKey<String>('t'))).dy,
      reason: 'у верхнего края',
    );
    await pumpDs(tester, bar(260), size: const Size(500, 400));
    expect(box().overflowed, isTrue, reason: '260: чип строкой ниже');
    expect(
      tester.getTopLeft(find.byKey(const ValueKey<String>('chip'))).dy,
      greaterThan(tester.getBottomLeft(find.byKey(const ValueKey<String>('t'))).dy - 0.01),
    );
  });

  testWidgets(
    'ReportTable: числовая колонка не уже своей суммы при 1,5 — сумма в одну строку, таблица прокручивается',
    (tester) async {
      await _scaled(tester, 1.5);
      await pumpDs(
        tester,
        SizedBox(
          width: 328,
          child: ReportTable(
            columns: const <ReportColumn>[
              ReportColumn(label: 'Дата'),
              ReportColumn(label: 'Заказов', numeric: true),
              ReportColumn(label: 'Сумма', numeric: true),
            ],
            rows: <List<String>>[
              <String>['18.11', '12', _money],
            ],
            totals: <String>['Итого', '12', _money],
          ),
        ),
        size: const Size(360, 780),
      );
      for (final Element e in find.text(_money).evaluate()) {
        final RenderParagraph p = e.renderObject! as RenderParagraph;
        expect(p.getMaxIntrinsicWidth(double.infinity), lessThanOrEqualTo(p.size.width + 0.5), reason: 'одна строка');
      }
      expect(find.byType(SingleChildScrollView), findsWidgets, reason: 'узко — прокрутка таблицы');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('ReportTable: значения помещаются — прежняя раскладка по долям flex (без прокрутки)', (tester) async {
    await pumpDs(
      tester,
      const SizedBox(
        width: 900,
        child: ReportTable(
          columns: <ReportColumn>[
            ReportColumn(label: 'Дата', flex: 2),
            ReportColumn(label: 'Сумма', numeric: true),
          ],
          rows: <List<String>>[
            <String>['18.11', '350,00 сом'],
          ],
        ),
      ),
      size: const Size(1000, 600),
    );
    expect(find.byType(Expanded), findsWidgets, reason: 'доли flex, как до правки');
  });

  testWidgets(
    'PriceText(card, stepDownToFit): в узкой колонке — ступень меньше, целиком; без флага — прежнее затухание',
    (tester) async {
      await _scaled(tester, 1.5);
      Widget price({required bool step}) => SizedBox(
        width: 240,
        child: PriceText(amount: const Money(12500000), variant: PriceTextVariant.card, stepDownToFit: step),
      );
      await pumpDs(tester, price(step: true), size: const Size(400, 400));
      RenderParagraph p() => tester.renderObject<RenderParagraph>(
        find.descendant(of: find.byType(PriceText), matching: find.byType(RichText)),
      );
      expect(
        p().getMaxIntrinsicWidth(double.infinity),
        lessThanOrEqualTo(p().size.width + 0.5),
        reason: '«125 000,00 сом»',
      );
      await pumpDs(tester, price(step: false), size: const Size(400, 400));
      expect(p().getMaxIntrinsicWidth(double.infinity), greaterThan(p().size.width), reason: 'прежнее поведение');
    },
  );

  testWidgets('CartLine (drawer, 360 × 1,5): сумма строки — строкой ниже степпера, без уменьшения', (tester) async {
    await _scaled(tester, 1.5);
    await pumpDs(
      tester,
      const SizedBox(
        width: 360,
        child: CartLine(
          title: 'Смеситель для кухни',
          quantity: SizedBox(width: 140, height: 44),
          removeLabel: 'Удалить',
          lineTotal: Money(470000),
          emphasized: true,
        ),
      ),
      size: const Size(360, 780),
      scroll: false,
    );
    final Finder sum = find.text(PriceText.format(const Money(470000)));
    final FittedBox fit = tester.widget<FittedBox>(find.ancestor(of: sum, matching: find.byType(FittedBox)));
    expect(fit.fit, BoxFit.scaleDown);
    final RenderBox box = tester.renderObject<RenderBox>(find.ancestor(of: sum, matching: find.byType(FittedBox)));
    final RenderBox text = tester.renderObject<RenderBox>(sum);
    expect(box.size.width, greaterThanOrEqualTo(text.size.width - 0.5), reason: 'сумма не уменьшена');
    expect(tester.renderObject<RenderTitleTrailingBar>(find.byType(TitleTrailingBar)).overflowed, isTrue);
  });
}
