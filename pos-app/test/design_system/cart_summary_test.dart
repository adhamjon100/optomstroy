// T-UI-117 (правила; ревью own-server:FIX-app): сумма «Итого» `CartSummary` с меткой «предварительно» (изменения не
// подтверждены сервером или нет сети, UI-20-030) — целиком, без уменьшения `FittedBox`. Раньше в строке «Итого» метка
// была `Flexible`, сумма — `Expanded`: `Row` делил свободное место между ними поровну, и сумма уменьшалась (×0,63…0,84
// на ширинах 328…380). Проверяются обе раскладки — сумма в строке с «Итого» и сумма строкой ниже — на внутренних
// ширинах телефона 328 (окно 360), 358 (390), 380 (412), в drawer 420 и в drawer во всю ширину окна 360 (планшет
// магазина), при масштабе текста 1, 1,3 и 1,5. Шрифт — настоящий Inter (ширины — как в приложении).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/cart_summary.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

import '../golden/cart_summary_golden_test.dart'
    show CartSummaryGoldenScene, cartSummaryGoldenBlock, cartSummaryGoldenScenes;
import 'ds_test_support.dart';

const String _preliminary = 'предварительно';

/// Вариант блока: имя, ширина окна, drawer (поля 20 по бокам, как в `CartPanelView`) или обычный (поля 16), итог
/// `display` ([large] — панель expanded и шире: масштаб текста не больше 1,3, `maxTextScaleFor`).
typedef _Box = ({String name, double width, bool drawer, bool large});

const List<_Box> _boxes = <_Box>[
  (name: 'экран 360 (328)', width: 360, drawer: false, large: false),
  (name: 'экран 390 (358)', width: 390, drawer: false, large: false),
  (name: 'экран 412 (380)', width: 412, drawer: false, large: false),
  (name: 'панель 480 (448), display', width: 480, drawer: false, large: true),
  (name: 'drawer 420', width: 420, drawer: true, large: false),
  (name: 'drawer 360', width: 360, drawer: true, large: false),
];

const List<Money> _totals = <Money>[Money(85000), Money(1235000), Money(12345600)];

const List<double> _scales = <double>[1, 1.3, 1.5];

Future<void> _pump(
  WidgetTester tester,
  _Box b, {
  required Money? total,
  String? preliminary = _preliminary,
  bool loading = false,
}) async {
  await pumpDs(
    tester,
    Align(
      alignment: AlignmentDirectional.topStart,
      child: SizedBox(
        width: b.width,
        child: CartSummary(
          rows: <CartSummaryRow>[CartSummaryRow(label: 'Товаров (5)', amount: total)],
          totalLabel: 'Итого',
          total: total,
          loading: loading,
          large: b.large,
          preliminaryLabel: preliminary,
          drawer: b.drawer,
          note: 'Итог пересчитывает сервер по ценам 1С при оформлении',
          padding: b.drawer ? const EdgeInsets.fromLTRB(20, 16, 20, 0) : null,
        ),
      ),
    ),
    size: Size(b.width, 800),
    scroll: false,
  );
}

/// Масштаб `FittedBox` суммы «Итого»: ширина поля / естественная ширина текста (1 — не уменьшена).
double _fit(WidgetTester tester) {
  final Finder total = find.byKey(CartSummary.totalKey);
  final RenderBox box = tester.renderObject<RenderBox>(find.ancestor(of: total, matching: find.byType(FittedBox)));
  final RenderBox text = tester.renderObject<RenderBox>(total);
  return box.size.width / text.size.width;
}

/// Сумма строкой ниже «Итого» (ветка «не помещается»).
bool _stacked(WidgetTester tester) =>
    tester.getTopLeft(find.byKey(CartSummary.totalKey)).dy >= tester.getBottomLeft(find.text('Итого')).dy - 0.5;

void main() {
  setUpAll(loadInterFont);
  tearDown(() => TestWidgetsFlutterBinding.instance.platformDispatcher.clearTextScaleFactorTestValue());

  testWidgets('с меткой «предварительно» сумма «Итого» не уменьшается — в строке и строкой ниже', (tester) async {
    int row = 0;
    int stacked = 0;
    for (final double scale in _scales) {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      for (final _Box b in _boxes) {
        if (b.large && scale > 1.3) continue;
        for (final Money total in _totals) {
          await _pump(tester, b, total: total);
          final String where = '${b.name} × $scale, «${PriceText.format(total, fixed2: true)}»';
          expect(tester.takeException(), isNull, reason: where);
          expect(find.text(_preliminary), findsOneWidget, reason: where);
          expect(_fit(tester), greaterThanOrEqualTo(0.999), reason: '$where: сумма уменьшена');
          if (_stacked(tester)) {
            stacked++;
          } else {
            row++;
            // В строке — метка между «Итого» и суммой, не наезжает на сумму.
            expect(
              tester.getTopRight(find.text(_preliminary)).dx,
              lessThanOrEqualTo(tester.getTopLeft(find.byKey(CartSummary.totalKey)).dx + 0.5),
              reason: where,
            );
          }
        }
      }
    }
    expect(row, greaterThan(0), reason: 'ветка «сумма в строке» проверена');
    expect(stacked, greaterThan(0), reason: 'ветка «сумма строкой ниже» проверена');
  });

  testWidgets('метка «предварительно» в строке получает остаток места: целиком, если помещается', (tester) async {
    await _pump(tester, (name: 'панель 600', width: 600, drawer: false, large: false), total: const Money(1600750));
    final RenderBox label = tester.renderObject<RenderBox>(
      find.descendant(of: find.text(_preliminary), matching: find.byType(RichText)),
    );
    expect(label.getMaxIntrinsicWidth(double.infinity), lessThanOrEqualTo(label.size.width + 0.5), reason: 'без «…»');
    expect(_stacked(tester), isFalse);
    expect(_fit(tester), greaterThanOrEqualTo(0.999));
  });

  // Пакет wave2:APP-POLISH: метке «предварительно» в строке «Итого» — только остаток места. Сумма получает свою полную
  // ширину (прижата к концу), метка — то, что осталось после «Итого», значка, зазоров и суммы: не помещается целиком —
  // многоточие, и тогда метка кончается ровно за зазор `s2` до суммы. Ширины 300…596 шаг 4, итоги 12 350,00 и
  // 124 450,00, масштаб текста 1 и 1,3, экран и drawer.
  testWidgets('метка «предварительно» в строке получает только остаток места; сумме — её полная ширина', (
    tester,
  ) async {
    int full = 0;
    int truncated = 0;
    for (final double scale in <double>[1, 1.3]) {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      for (final bool drawer in <bool>[false, true]) {
        for (final Money total in const <Money>[Money(1235000), Money(12445000)]) {
          for (double w = 300; w < 600; w += 4) {
            await _pump(tester, (name: 'w$w', width: w, drawer: drawer, large: false), total: total);
            final String where =
                '${drawer ? 'drawer' : 'экран'} $w × $scale, «${PriceText.format(total, fixed2: true)}»';
            expect(tester.takeException(), isNull, reason: where);
            expect(_fit(tester), greaterThanOrEqualTo(0.999), reason: '$where: сумма уменьшена');
            if (_stacked(tester)) continue;
            final double gap = tester.element(find.byType(CartSummary)).space.s2;
            final Finder sum = find.byKey(CartSummary.totalKey);
            final RenderBox label = tester.renderObject<RenderBox>(
              find.descendant(of: find.text(_preliminary), matching: find.byType(RichText)),
            );
            final double labelEnd = tester.getTopRight(find.text(_preliminary)).dx;
            final double sumStart = tester.getTopLeft(sum).dx;
            final double contentEnd = w - (drawer ? 20 : 16);
            expect(
              tester.getTopRight(sum).dx,
              moreOrLessEquals(contentEnd, epsilon: 0.5),
              reason: '$where: сумма у конца',
            );
            expect(labelEnd + gap, lessThanOrEqualTo(sumStart + 0.5), reason: '$where: метка наезжает на сумму');
            if (label.getMaxIntrinsicWidth(double.infinity) > label.size.width + 0.5) {
              truncated++;
              expect(labelEnd + gap, moreOrLessEquals(sumStart, epsilon: 0.5), reason: '$where: метке — весь остаток');
            } else {
              full++;
            }
          }
        }
      }
    }
    expect(truncated, greaterThan(0), reason: 'встречается метка с многоточием (только остаток)');
    expect(full, greaterThan(0), reason: 'встречается метка целиком');
  });

  // Эталон `test/golden/cart_summary_golden_test.dart` (`ds_cart_summary_preliminary_compact`): каждая сцена — в своей
  // ветви, сумма целиком. Без этой проверки эталон мог бы молча перестать показывать ветвь «строкой ниже».
  testWidgets('сцены эталона ds_cart_summary_preliminary_compact — в своих ветвях', (tester) async {
    final List<({bool stacked, bool labelFull})> want = <({bool stacked, bool labelFull})>[
      (stacked: false, labelFull: true),
      (stacked: false, labelFull: false),
      (stacked: true, labelFull: true),
      (stacked: true, labelFull: true),
    ];
    expect(cartSummaryGoldenScenes, hasLength(want.length));
    for (int i = 0; i < want.length; i++) {
      final CartSummaryGoldenScene s = cartSummaryGoldenScenes[i];
      tester.platformDispatcher.textScaleFactorTestValue = s.scale;
      await pumpDs(
        tester,
        Align(
          alignment: AlignmentDirectional.topStart,
          child: SizedBox(width: 360, child: cartSummaryGoldenBlock(s)),
        ),
        size: const Size(360, 800),
        scroll: false,
      );
      expect(tester.takeException(), isNull, reason: s.label);
      expect(_stacked(tester), want[i].stacked, reason: s.label);
      expect(_fit(tester), greaterThanOrEqualTo(0.999), reason: s.label);
      final RenderBox label = tester.renderObject<RenderBox>(
        find.descendant(of: find.text(_preliminary), matching: find.byType(RichText)),
      );
      expect(
        label.getMaxIntrinsicWidth(double.infinity) <= label.size.width + 0.5,
        want[i].labelFull,
        reason: '${s.label}: метка целиком',
      );
    }
  });

  testWidgets('без метки — прежняя раскладка: сумма целиком', (tester) async {
    for (final _Box b in _boxes) {
      await _pump(tester, b, total: const Money(12345600), preliminary: null);
      expect(tester.takeException(), isNull, reason: b.name);
      expect(_fit(tester), greaterThanOrEqualTo(0.999), reason: b.name);
    }
  });

  testWidgets('итог неизвестен («—») и загрузка (скелетон) с меткой — без переполнения в узком блоке', (tester) async {
    for (final double width in <double>[240, 360]) {
      for (final bool drawer in <bool>[false, true]) {
        final _Box b = (name: 'w$width', width: width, drawer: drawer, large: false);
        await _pump(tester, b, total: null);
        expect(tester.takeException(), isNull, reason: '«—» $width drawer=$drawer');
        expect(find.byKey(CartSummary.totalKey), findsOneWidget);
        await _pump(tester, b, total: null, loading: true);
        expect(tester.takeException(), isNull, reason: 'скелетон $width drawer=$drawer');
      }
    }
  });
}
