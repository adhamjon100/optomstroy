// Поведение компонентов дизайн-системы, добавленное при переносе прототипа «точь-в-точь» (ADR-114, ревью RC-09):
// толщина рамок по правилу Chrome (`DsHairline`), высота ячейки карточки сетки 340 / 360 и перенос «/ шт»
// (`kProductCardGridExtent(priceWraps:)`, `kProductCardGridPriceWraps` по цене карточки — ревью V-01), ширины
// карточек ленты и плиток колонки по
// самому длинному слову (`CategoryTile.ribbonWidthFor`, `sidebarMinWidthFor`), ширина карточки ленты по индексу и
// листание стрелкой на 3 карточки (`ScrollRibbon.itemWidthOf`, `stepItems`). Ширины текста — настоящий Inter.
// Тест-кейсы 12_TEST_PLAN: T-CAT-038 (высота ячейки 340 / 360), T-DS-104 (геометрия прототипа).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/components/category_tile.dart';
import 'package:optomstroy/design_system/components/ds_hairline.dart';
import 'package:optomstroy/design_system/components/product_card.dart';
import 'package:optomstroy/design_system/components/scroll_ribbon.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';

import 'ds_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DsHairline (рамки CSS-px как в Chrome)', () {
    test('widthFor: max(1, floor(css · dpr)) / dpr при DPR 1 / 1,25 / 1,5 / 2', () {
      // Рамка 1,5 прототипа (плитки, карточки ленты, «В корзине · N — ещё +1»).
      expect(DsHairline.widthFor(1.5, 1), 1);
      expect(DsHairline.widthFor(1.5, 1.25), 0.8);
      expect(DsHairline.widthFor(1.5, 1.5), closeTo(4 / 3, 1e-9));
      expect(DsHairline.widthFor(1.5, 2), 1.5, reason: '1,5 × 2 = 3 — без ошибки округления');
      // Рамка 1: всегда ровно один пиксель экрана.
      expect(DsHairline.widthFor(1, 1), 1);
      expect(DsHairline.widthFor(1, 1.25), 0.8);
      expect(DsHairline.widthFor(1, 1.5), closeTo(2 / 3, 1e-9));
      expect(DsHairline.widthFor(1, 2), 1, reason: '2 пикселя экрана = 1 lp');
      expect(DsHairline.widthFor(2, 1.25), 1.6);
      // Тоньше пикселя рамка не становится; DPR 0 (неизвестен) — как 1.
      expect(DsHairline.widthFor(0.5, 1), 1);
      expect(DsHairline.widthFor(1.5, 0), 1);
    });

    testWidgets('of / side / all берут DPR окна', (tester) async {
      late BuildContext ctx;
      await pumpDs(
        tester,
        Builder(
          builder: (BuildContext context) {
            ctx = context;
            return const SizedBox();
          },
        ),
      );
      expect(DsHairline.of(ctx), 1);
      expect(DsHairline.of(ctx, 1.5), 1);
      tester.view.devicePixelRatio = 1.25;
      await tester.pump();
      expect(DsHairline.of(ctx, 1.5), 0.8);
      expect(DsHairline.side(ctx, const Color(0xFF000000), 1.5).width, 0.8);
      expect(DsHairline.all(ctx, const Color(0xFF000000)).top.width, 0.8);
    });
  });

  group('kProductCardGridExtent (прототип: ячейка 340, при переносе «/ шт» — 360)', () {
    setUpAll(loadInterFont);

    // Цены демо-каталога по макету: самая длинная «10 450,00 сом», короткая «2 350,00 сом» (разряды и «сом» — NBSP).
    const String longPrice = '10\u00A0450,00\u00A0сом';
    const String shortPrice = '2\u00A0350,00\u00A0сом';
    const String unit = '/ шт';

    test('перенос «/ шт» — по цене карточки: 199 (1440) и 186,7 (1366 × 768) — одна строка, 181,3 (1920) — перенос '
        '(ревью V-01)', () {
      const TextScaler one = TextScaler.noScaling;
      expect(kProductCardGridExtent(one), 340, reason: 'без переноса');
      expect(kProductCardGridExtent(one, priceWraps: true), 360, reason: '«/ шт» второй строкой: + 4 + 16');
      // Ширина контента карточки = ширина − обводки 2 − поля 12 + 12: 173, 160,7 и 155,3.
      expect(kProductCardGridPriceWraps(one, 199, price: longPrice, unit: unit), isFalse);
      expect(
        kProductCardGridPriceWraps(one, 186.7, price: longPrice, unit: unit),
        isFalse,
        reason: '1366 × 768: «10 450,00 сом / шт» помещается — ячейка 340, как в прототипе (не образец «00 000,00»)',
      );
      expect(kProductCardGridPriceWraps(one, 181.3, price: longPrice, unit: unit), isTrue);
      expect(
        kProductCardGridPriceWraps(one, 181.3, price: shortPrice, unit: unit),
        isFalse,
        reason: 'короткая цена',
      );
      expect(kProductCardGridPriceWraps(one, 181.3, price: longPrice), isFalse, reason: 'без единицы — без переноса');
      // Строка «цена · 4 · / шт» — как в прототипе с opsz 14 (статическое начертание): 128,9 + 4 + «/ шт».
      expect(kProductCardGridPriceLineWidth(one, longPrice, unit), inInclusiveRange(155.3, 160.7));
      // 1280 (5 × 209,6) и 1024 (4 × 201,5) — без переноса.
      expect(kProductCardGridPriceWraps(one, 209.6, price: longPrice, unit: unit), isFalse);
      expect(kProductCardGridPriceWraps(one, 201.5, price: longPrice, unit: unit), isFalse);
      // Ширины колонок экрана — как в T-CAT-038: (W − 14·(n − 1)) / n. Токены 1.4.0 (пакет own-server:GAP-APP): предел
      // expanded — 5, large — 6, поэтому 1440 и 1366 — 5 колонок, 1920 — 6 (прототип давал 6 / 6 / 9).
      double card(double content, int cols) => (content - 14 * (cols - 1)) / cols;
      expect(DsBreakpoints.gridColumns(1264, 14, windowClass: WindowClass.expanded, minCardWidth: 176), 5);
      expect(kProductCardGridPriceWraps(one, card(1264, 5), price: longPrice, unit: unit), isFalse);
      expect(DsBreakpoints.gridColumns(1190, 14, windowClass: WindowClass.expanded, minCardWidth: 176), 5);
      expect(
        kProductCardGridPriceWraps(one, card(1190, 5), price: longPrice, unit: unit),
        isFalse,
        reason: '1366',
      );
      expect(DsBreakpoints.gridColumns(1744, 14, windowClass: WindowClass.large, minCardWidth: 176), 6);
      expect(
        kProductCardGridPriceWraps(one, card(1744, 6), price: longPrice, unit: unit),
        isFalse,
        reason: '1920: карточка ≈ 279 — «10 450,00 сом / шт» в одну строку (при 9 колонках по 181,3 был перенос)',
      );
    });

    test('масштаб текста 1.3: ячейка выше, перенос раньше; бейдж совпадения — +24', () {
      const TextScaler big = TextScaler.linear(1.3);
      expect(kProductCardGridExtent(big), greaterThan(340));
      expect(
        kProductCardGridPriceWraps(big, 199, price: longPrice, unit: unit),
        isTrue,
        reason: '«10 450,00 сом / шт» × 1,3 не помещается в 173',
      );
      expect(
        kProductCardGridExtent(big, priceWraps: true),
        greaterThan(kProductCardGridExtent(big)),
        reason: 'вторая строка «/ шт»',
      );
      expect(kProductCardGridExtent(TextScaler.noScaling, matchBadge: true), 340 + 24);
      expect(kProductCardGridPhotoHeight, 146);
      expect(kProductCardGridImageHeight, 150);
      expect(kProductCardGridNameMinHeight, 37);
    });
  });

  group('CategoryTile: ширина по самому длинному слову (min-content прототипа)', () {
    testWidgets('лента: «Канализационные трубы и фитинги» — 136, короткие — 118; выбранная — по весу 700', (
      tester,
    ) async {
      await tester.runAsync(loadInterFont);
      late BuildContext ctx;
      await pumpDs(
        tester,
        Builder(
          builder: (BuildContext context) {
            ctx = context;
            return const SizedBox();
          },
        ),
      );
      expect(CategoryTile.ribbonWidthFor(ctx, 'Канализационные трубы и фитинги'), 136, reason: 'макет: 135,6');
      expect(CategoryTile.ribbonWidthFor(ctx, 'Для кухни'), CategoryTile.ribbonSize.width);
      expect(CategoryTile.ribbonWidthFor(ctx, 'Все товары', selected: true), 118);
      final double plain = CategoryTile.ribbonWidthFor(ctx, 'Канализационные');
      final double bold = CategoryTile.ribbonWidthFor(ctx, 'Канализационные', selected: true);
      expect(bold, greaterThanOrEqualTo(plain), reason: 'выбранная — 700, как в браузере');
      expect(plain, plain.ceilToDouble(), reason: 'целые lp — чёткие рамки');
    });

    testWidgets('колонка: «Водоснабжение» ≈ 111 (макет 111,3), выбранная шире; короткое слово — только поля', (
      tester,
    ) async {
      await tester.runAsync(loadInterFont);
      late BuildContext ctx;
      await pumpDs(
        tester,
        Builder(
          builder: (BuildContext context) {
            ctx = context;
            return const SizedBox();
          },
        ),
      );
      final double water = CategoryTile.sidebarMinWidthFor(ctx, 'Водоснабжение');
      expect(water, closeTo(111.3, 2), reason: 'слово 12/600 + поля 6 + 6 + обводки');
      expect(CategoryTile.sidebarMinWidthFor(ctx, 'Водоснабжение', selected: true), greaterThan(water));
      // Многословное название — по самому длинному слову, не по всей строке.
      expect(
        CategoryTile.sidebarMinWidthFor(ctx, 'Крепёж и фурнитура'),
        CategoryTile.sidebarMinWidthFor(ctx, 'фурнитура'),
      );
      expect(CategoryTile.sidebarMinWidthFor(ctx, 'А'), lessThan(DsCatalogMetrics.tileArt.width));
    });
  });

  group('ScrollRibbon (лента подкатегорий)', () {
    Widget ribbon({required int count, double Function(int)? widthOf, int stepItems = 3, double width = 600}) =>
        SizedBox(
          width: width,
          child: ScrollRibbon(
            // Новый экземпляр (без сохранённой прокрутки) на каждый набор параметров.
            key: ValueKey<String>('ribbon-$count-$stepItems-$width'),
            itemCount: count,
            itemSize: CategoryTile.ribbonSize,
            itemWidthOf: widthOf,
            stepItems: stepItems,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            previousLabel: 'Назад',
            nextLabel: 'Вперёд',
            itemBuilder: (BuildContext context, int i) =>
                ColoredBox(key: ValueKey<String>('item-$i'), color: const Color(0xFFEEEEEE)),
          ),
        );

    double offset(WidgetTester tester) =>
        tester.widget<ListView>(find.byKey(const ValueKey<String>('scroll-ribbon-list'))).controller!.offset;

    testWidgets('itemWidthOf — ширина карточки по индексу; зазор 10, поле 2; высота 152', (tester) async {
      await pumpDs(tester, ribbon(count: 4, widthOf: (int i) => i == 1 ? 136 : 118));
      expect(tester.getSize(find.byKey(const ValueKey<String>('item-0'))), const Size(118, 148));
      expect(tester.getSize(find.byKey(const ValueKey<String>('item-1'))), const Size(136, 148));
      expect(
        tester.getTopLeft(find.byKey(const ValueKey<String>('item-2'))).dx -
            tester.getTopRight(find.byKey(const ValueKey<String>('item-1'))).dx,
        DsCatalogMetrics.ribbonGap,
      );
      expect(tester.getSize(find.byType(ScrollRibbon)).height, 148 + 2 * DsCatalogMetrics.ribbonPad);
    });

    testWidgets('стрелка листает на stepItems карточек (3 × 128 = 384), с выравниванием по началу; на краях стрелки '
        'скрыты; без переполнения стрелок нет', (tester) async {
      await pumpDs(tester, ribbon(count: 12), disableAnimations: true);
      expect(find.byKey(ScrollRibbon.previousKey), findsNothing);
      expect(find.byKey(ScrollRibbon.nextKey), findsOneWidget);
      await tester.tap(find.byKey(ScrollRibbon.nextKey));
      await tester.pumpAndSettle();
      expect(offset(tester), 3 * (118 + 10), reason: 'прототип: 3 карточки за нажатие');
      expect(find.byKey(ScrollRibbon.previousKey), findsOneWidget);
      await tester.tap(find.byKey(ScrollRibbon.nextKey));
      await tester.pumpAndSettle();
      expect(offset(tester), 6 * 128);
      // До конца: последнее нажатие упирается в maxScrollExtent, «›» исчезает.
      for (int i = 0; i < 5 && find.byKey(ScrollRibbon.nextKey).evaluate().isNotEmpty; i++) {
        await tester.tap(find.byKey(ScrollRibbon.nextKey));
        await tester.pumpAndSettle();
      }
      expect(find.byKey(ScrollRibbon.nextKey), findsNothing, reason: 'в конце — без «›»');
      final ScrollPosition p = tester
          .widget<ListView>(find.byKey(const ValueKey<String>('scroll-ribbon-list')))
          .controller!
          .position;
      expect(offset(tester), p.maxScrollExtent);
      await tester.tap(find.byKey(ScrollRibbon.previousKey));
      await tester.pumpAndSettle();
      expect(offset(tester), lessThan(p.maxScrollExtent));
      expect(offset(tester) % 128, 0, reason: 'назад — тоже по началу карточки');

      // Шаг 2 — на 2 карточки.
      await pumpDs(tester, ribbon(count: 12, stepItems: 2));
      await tester.tap(find.byKey(ScrollRibbon.nextKey));
      await tester.pumpAndSettle();
      expect(offset(tester), 2 * 128);

      // Всё помещается — стрелок нет (ADR-114: по настоящему переполнению, не по правилу n − 6).
      await pumpDs(tester, ribbon(count: 3, width: 900));
      expect(find.byKey(ScrollRibbon.nextKey), findsNothing);
      expect(find.byKey(ScrollRibbon.previousKey), findsNothing);
    });

    testWidgets('стрелки: круг 38 в цели 48; цель внутри ленты при поле < 17 (RC-10)', (tester) async {
      await pumpDs(tester, ribbon(count: 12));
      final Rect ribbonRect = tester.getRect(find.byType(ScrollRibbon));
      final Rect next = tester.getRect(find.byKey(ScrollRibbon.nextKey));
      expect(next.size, const Size(48, 48));
      expect(next.right, lessThanOrEqualTo(ribbonRect.right), reason: 'цель не выходит за ленту');
      expect(ScrollRibbon.arrowSize, 38);
      expect(ScrollRibbon.arrowTargetReach, 17);
    });
  });
}
