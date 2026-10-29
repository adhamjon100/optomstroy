// Компоненты каталога RM-E-007 (03 §9.8–§9.13, §9.16, §9.17, §9.23–§9.26, §9.51): формат цены (U+202F,
// запятая, U+2212), StockBadge (цвет + иконка + текст), FavoriteToggle (только звезда, toggled),
// ViewModeSegmented (повторный выбор — без события, ←/→), SortMenu (тот же пункт — без события),
// CategorySidebarItem (selected — без действия, счётчик «0»), CategoryChip (check у выбранного),
// CategoryTile, NotificationBell («99+», точка), FoundCountText (скелетон), FilterSection, ProductCard*;
// прототип 2026-10-29 (ADR-112): ToolbarToggleButton, стили `toolbar` ViewModeSegmented/SortMenu, CategoryTile
// sidebar/ribbon 118×148, ProductCardActionKind.inCart, kProductCardGridExtent, таблица «Компакт» 120·flex·150·150·132.
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_badge.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/category_chip.dart';
import 'package:optomstroy/design_system/components/category_sidebar_item.dart';
import 'package:optomstroy/design_system/components/category_tile.dart';
import 'package:optomstroy/design_system/components/ds_glyph.dart';
import 'package:optomstroy/design_system/components/favorite_toggle.dart';
import 'package:optomstroy/design_system/components/filter_panel.dart';
import 'package:optomstroy/design_system/components/found_count_text.dart';
import 'package:optomstroy/design_system/components/notification_bell.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/product_card.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/sort_menu.dart';
import 'package:optomstroy/design_system/components/stock_badge.dart';
import 'package:optomstroy/design_system/components/toolbar_toggle_button.dart';
import 'package:optomstroy/design_system/components/view_mode_segmented.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

import 'ds_test_support.dart';

const ProductCardData _data = ProductCardData(
  id: 'p1',
  name: 'Смеситель для кухни Frap F4252 с длинным названием, которое не помещается в две строки карточки сетки',
  skuLabel: 'Арт. F4252-CR',
  price: Money(235000),
  priceUnit: '/ шт',
  unitLabel: 'шт',
  stockLevel: StockBadgeLevel.inStock,
  stockLabel: 'В наличии · 24 шт',
  favoriteLabel: 'Избранное',
  action: ProductCardActionKind.add,
  actionLabel: '+ Добавить',
);

/// Префикс цены диапазона вариантов («от …», ARB `catalog_price_from` в приложении).
String _fromPrefix(String formatted) => 'от $formatted';

void main() {
  group('PriceText', () {
    test('формат сом: разряды U+202F, тыйыны при ненулевой дроби, минус U+2212', () {
      expect(PriceText.formatAmount(const Money(235000)), '2 350');
      expect(PriceText.formatAmount(const Money(1600750)), '16 007,50');
      expect(PriceText.formatAmount(const Money(-84250)), '−842,50');
      expect(PriceText.formatAmount(const Money(100), fixed2: true), '1,00');
      expect(PriceText.formatAmount(const Money(123456789)), '1 234 567,89');
      expect(PriceText.format(const Money(235000)), '2 350 сом');
    });

    testWidgets('нет цены — подпись; «от» — префикс', (tester) async {
      await pumpDs(
        tester,
        Column(
          children: <Widget>[
            const PriceText(amount: null, missingLabel: 'Цена не указана'),
            PriceText(amount: const Money(235000), unit: '/ шт', prefix: (String p) => 'от $p'),
          ],
        ),
      );
      expect(find.text('Цена не указана'), findsOneWidget);
      expect(find.bySemanticsLabel('от 2350 сом / шт'), findsOneWidget);
    });
  });

  testWidgets('StockBadge: иконка уровня + текст + метка устаревания', (tester) async {
    await pumpDs(
      tester,
      const Column(
        children: <Widget>[
          StockBadge(level: StockBadgeLevel.inStock, label: 'В наличии · 24 шт', asOf: 'данные от 09:41'),
          StockBadge(level: StockBadgeLevel.out, label: 'Нет в наличии', variant: StockBadgeVariant.inline),
          StockBadge(level: StockBadgeLevel.unknown, label: 'Остаток неизвестен', variant: StockBadgeVariant.compact),
        ],
      ),
    );
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(find.byIcon(Icons.cancel_rounded), findsOneWidget);
    expect(find.byIcon(Icons.help_rounded), findsOneWidget);
    expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);
    expect(find.bySemanticsLabel('В наличии · 24 шт, данные от 09:41'), findsOneWidget);
  });

  testWidgets('FavoriteToggle: только звезда; тап сообщает новое значение; цель 48', (tester) async {
    final List<bool> values = <bool>[];
    await pumpDs(tester, FavoriteToggle(selected: false, onChanged: values.add, semanticLabel: 'Избранное'));
    expect(find.byIcon(Icons.star_border_rounded), findsOneWidget);
    expect(find.byIcon(Icons.favorite), findsNothing);
    expect(tester.getSize(find.byType(FavoriteToggle)), const Size(48, 48));
    await tester.tap(find.byType(FavoriteToggle));
    expect(values, <bool>[true]);
  });

  testWidgets('ViewModeSegmented: три сегмента ≥ 44, повторный выбор — без события, стрелки', (tester) async {
    final List<ProductViewMode> changes = <ProductViewMode>[];
    await pumpDs(
      tester,
      ViewModeSegmented(
        value: ProductViewMode.grid,
        onChanged: changes.add,
        labels: const <ProductViewMode, String>{
          ProductViewMode.grid: 'Сетка',
          ProductViewMode.list: 'Список',
          ProductViewMode.compact: 'Компакт',
        },
      ),
    );
    for (final ProductViewMode m in ProductViewMode.values) {
      expect(tester.getSize(find.byKey(ValueKey<String>('view-mode-${m.value}'))).width, greaterThanOrEqualTo(44));
    }
    await tester.tap(find.byKey(const ValueKey<String>('view-mode-grid')));
    expect(changes, isEmpty);
    await tester.tap(find.byKey(const ValueKey<String>('view-mode-compact')));
    expect(changes, <ProductViewMode>[ProductViewMode.compact]);
    expect(ProductViewMode.tryParse('list'), ProductViewMode.list);
    expect(ProductViewMode.tryParse('table'), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(changes.length, greaterThanOrEqualTo(1));
  });

  testWidgets('SortMenu: меню с check у текущего; тот же пункт — без события; другой — событие', (tester) async {
    final List<String> picked = <String>[];
    await pumpDs(
      tester,
      SortMenu<String>(
        options: const <SortMenuOption<String>>[
          SortMenuOption<String>(value: 'name:asc', label: 'По названию А–Я'),
          SortMenuOption<String>(value: 'sku:asc', label: 'По артикулу'),
        ],
        selected: 'name:asc',
        onSelected: picked.add,
        semanticLabel: 'Сортировка',
      ),
    );
    await tester.tap(find.byType(SortMenu<String>));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await tester.tap(find.text('По названию А–Я').last);
    await tester.pumpAndSettle();
    expect(picked, isEmpty);
    await tester.tap(find.byType(SortMenu<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('По артикулу'));
    await tester.pumpAndSettle();
    expect(picked, <String>['sku:asc']);
  });

  testWidgets('CategorySidebarItem: выбранный не реагирует; «0» серым; иконка по iconKey', (tester) async {
    int taps = 0;
    await pumpDs(
      tester,
      Column(
        children: <Widget>[
          CategorySidebarItem(label: 'Смесители', count: 124, iconKey: 'plumbing', selected: true, onTap: () => taps++),
          CategorySidebarItem(key: const ValueKey<String>('empty'), label: 'Трубы', count: 0, onTap: () => taps++),
        ],
      ),
    );
    await tester.tap(find.text('Смесители'));
    expect(taps, 0);
    await tester.tap(find.byKey(const ValueKey<String>('empty')));
    expect(taps, 1);
    expect(find.text('0'), findsOneWidget);
    expect(find.byIcon(Icons.plumbing_rounded), findsOneWidget);
    expect(find.byIcon(Icons.category_rounded), findsOneWidget);
    expect(CategoryIcons.of('нет такого'), Icons.category_rounded);
  });

  testWidgets('CategoryChip: выбранный — check; input — крестик; CategoryTile; NotificationBell', (tester) async {
    int removed = 0;
    await pumpDs(
      tester,
      Column(
        children: <Widget>[
          const CategoryChip(label: 'Все', selected: true, count: 124),
          CategoryChip(label: 'Хром', variant: CategoryChipVariant.input, onRemove: () => removed++),
          CategoryTile(label: 'Смесители', countLabel: '124', iconKey: 'plumbing', onTap: () {}),
          NotificationBell(unreadCount: 120, onPressed: () {}, semanticLabel: 'Уведомления, 120 непрочитанных'),
          NotificationBell(unreadCount: 0, onPressed: () {}, semanticLabel: 'Уведомления'),
          NotificationBell(unreadCount: 2, onPressed: () {}, semanticLabel: 'u', variant: NotificationBellVariant.dot),
        ],
      ),
    );
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_rounded));
    expect(removed, 1);
    expect(find.text('99+'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('notification-bell-badge')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('notification-bell-dot')), findsOneWidget);
    expect(NotificationBell.badgeText(7), '7');
  });

  testWidgets('FoundCountText: null — скелетон; FilterSection сворачивается', (tester) async {
    await pumpDs(
      tester,
      const Column(
        children: <Widget>[
          FoundCountText(text: null),
          FoundCountText(text: 'Найдено: 124 товара'),
          FilterSection(title: 'Бренд', child: Text('Frap')),
        ],
      ),
    );
    expect(find.byType(SkeletonBox), findsOneWidget);
    expect(find.text('Найдено: 124 товара'), findsOneWidget);
    expect(find.text('Frap'), findsOneWidget);
    await tester.tap(find.text('Бренд'));
    await tester.pumpAndSettle();
    expect(find.text('Frap'), findsNothing);
  });

  testWidgets('ProductCard*: название 2 строки с многоточием, артикул, цена, остаток, «+ Добавить»; колбэки', (
    tester,
  ) async {
    int opened = 0;
    int actions = 0;
    final ProductCardCallbacks cb = ProductCardCallbacks(onOpen: () => opened++, onAction: () => actions++);
    await pumpDs(
      tester,
      Column(
        children: <Widget>[
          SizedBox(
            width: 200,
            height: kProductCardGridExtent(TextScaler.noScaling),
            child: ProductCardGrid(data: _data, callbacks: cb),
          ),
          ProductCardList(data: _data, callbacks: cb),
          ProductCardCompact(data: _data, callbacks: cb),
          ProductCardCompact(data: _data, callbacks: cb, variant: ProductCardCompactVariant.row),
        ],
      ),
      size: const Size(1280, 1400),
    );
    final Text name = tester.widget<Text>(find.text(_data.name).first);
    expect(name.maxLines, 2);
    expect(name.overflow, TextOverflow.ellipsis);
    expect(find.text('Арт. F4252-CR'), findsNWidgets(2), reason: 'сетка и список medium+');
    expect(find.text('+ Добавить'), findsNWidgets(3), reason: 'сетка, список и таблица «Компакт» — полная подпись');
    await tester.tap(find.text('+ Добавить').first);
    expect(actions, 1);
    await tester.tap(find.text('Арт. F4252-CR').first);
    expect(opened, 1);
    expect(find.byType(ProductCardCompact), findsNWidgets(2));
    expect(find.text('F4252-CR'), findsNWidgets(2), reason: 'компакт — артикул без «Арт.»');
  });

  testWidgets(
    'ProductCardCompact: в колонке «Наличие» — статус с количеством; строка — число; «Нет в наличии» — целиком',
    (tester) async {
      const ProductCardData status = ProductCardData(
        id: 'p2',
        name: 'Сифон',
        skuLabel: 'Арт. C1010',
        price: Money(32000),
        stockLevel: StockBadgeLevel.low,
        stockLabel: 'Мало',
        favoriteLabel: 'Добавить в избранное',
        action: ProductCardActionKind.add,
        actionLabel: '+ Добавить',
      );
      const ProductCardData out = ProductCardData(
        id: 'p3',
        name: 'Унитаз',
        skuLabel: 'Арт. SN-1',
        price: Money(890000),
        stockLevel: StockBadgeLevel.out,
        stockLabel: 'Нет в наличии',
        favoriteLabel: 'Добавить в избранное',
        action: ProductCardActionKind.unavailable,
        actionLabel: 'Нет в наличии',
      );
      await pumpDs(
        tester,
        const Column(
          children: <Widget>[
            ProductCardCompact(data: _data),
            ProductCardCompact(data: status),
            ProductCardCompact(data: out, variant: ProductCardCompactVariant.row),
          ],
        ),
        size: const Size(1280, 600),
      );
      final List<String> labels = tester
          .widgetList<StockBadge>(find.byType(StockBadge))
          .map((StockBadge b) => b.label)
          .toList();
      // Таблица (колонка «Наличие» 150): статус с количеством; строка compact — число.
      expect(labels, <String>['В наличии · 24 шт', 'Мало', 'Нет в наличии']);
    },
  );

  testWidgets(
    'ProductCardCompact.table (прототип 2026-10-29): Артикул 120 · Наименование (миниатюра 40, звезда) · Наличие 150 · '
    'Цена 150 «/ шт» · кнопка 132; строка 50 + линия; уже 840 — без колонки «Артикул» (артикул под названием), наличие '
    'остаётся',
    (tester) async {
      // Настоящий шрифт приложения (Inter): ширины текста цены и статуса.
      await tester.runAsync(loadInterFont);
      const ProductCardData unknown = ProductCardData(
        id: 'p4',
        name: 'Карниз для ванны угловой алюминиевый 170×70 см',
        skuLabel: 'Арт. L3577',
        price: Money(1043464),
        pricePrefix: _fromPrefix,
        unitLabel: 'шт',
        priceUnit: '/ шт',
        variantsLabel: '3 вар.',
        stockLevel: StockBadgeLevel.unknown,
        stockLabel: 'Остаток неизвестен',
        favoriteLabel: 'Добавить в избранное',
        action: ProductCardActionKind.chooseVariant,
        actionLabel: 'Выбрать вариант',
      );
      bool? favorite;
      final ProductCardCallbacks callbacks = ProductCardCallbacks(onFavorite: (bool v) => favorite = v);
      const ProductCompactHeaderLabels labels = ProductCompactHeaderLabels(
        sku: 'Артикул',
        name: 'Наименование',
        stock: 'Наличие',
        price: 'Цена',
      );
      await pumpDs(
        tester,
        SizedBox(
          width: 900,
          child: Column(
            children: <Widget>[
              const ProductCardCompactHeader(labels: labels),
              ProductCardCompact(data: unknown, callbacks: callbacks),
            ],
          ),
        ),
        size: const Size(1366, 600),
      );
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(ProductCardCompact)).height, ProductCardCompact.tableRowHeight + 1);
      expect(find.text('L3577'), findsOneWidget, reason: 'артикул без «Арт.»');
      expect(find.text('3 вар.'), findsOneWidget, reason: 'число вариантов — рядом с названием');
      // Паритет функций ADR-112: миниатюра 40, звезда избранного в строке, единица «/ шт» у цены.
      expect(tester.getSize(find.byType(ProductImage)), const Size(40, 40));
      expect(find.byType(FavoriteToggle), findsOneWidget);
      await tester.tap(find.byType(FavoriteToggle));
      await tester.pump();
      expect(favorite, isTrue, reason: 'звезда переключает избранное, не выходя из таблицы');
      expect(tester.widget<PriceText>(find.byType(PriceText)).unit, '/ шт');
      expect(tester.widget<StockBadge>(find.byType(StockBadge)).label, 'Остаток неизвестен', reason: 'статус целиком');
      final RenderParagraph price = tester.renderObject<RenderParagraph>(
        find.descendant(of: find.byType(PriceText), matching: find.byType(RichText)),
      );
      expect(price.size.width, greaterThanOrEqualTo(price.getMaxIntrinsicWidth(double.infinity) - 0.5));
      for (final (String header, Finder cell) in <(String, Finder)>[
        ('Артикул', find.text('L3577')),
        ('Наименование', find.text(unknown.name)),
        ('Наличие', find.byType(StockBadge)),
      ]) {
        expect(
          tester.getTopLeft(find.text(header)).dx,
          closeTo(tester.getTopLeft(cell).dx, 0.5),
          reason: 'колонка «$header» заголовка и строки совпадают',
        );
      }
      final Finder button = find.byType(AppButton);
      expect(tester.getSize(button).width, ProductCompactLayout.actionWidth);
      expect(tester.widget<AppButton>(button).size, AppButtonSize.cardCompact);
      expect(AppButtonSize.cardCompact.height, 34);
      expect(AppButtonSize.cardCompact.target, greaterThanOrEqualTo(44));

      // Узкая строка (окно 840, колонка 132): без колонки «Артикул» — артикул под названием; «Наличие» остаётся;
      // без горизонтальной прокрутки.
      await pumpDs(
        tester,
        const SizedBox(
          width: 668,
          child: Column(
            children: <Widget>[
              ProductCardCompactHeader(labels: labels),
              ProductCardCompact(data: unknown),
            ],
          ),
        ),
        size: const Size(840, 600),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Артикул'), findsNothing);
      expect(find.text('Наличие'), findsOneWidget);
      expect(find.text('L3577'), findsNothing);
      expect(find.byKey(const ValueKey<String>('product-compact-sku-line')), findsOneWidget);
      expect(find.text('Арт. L3577'), findsOneWidget, reason: 'артикул — второй строкой под названием');
      expect(find.byType(StockBadge), findsOneWidget, reason: 'остаток в таблице виден всегда');
      expect(find.text('Наименование'), findsOneWidget);
      expect(find.byType(PriceText), findsOneWidget);
      expect(find.byType(FavoriteToggle), findsOneWidget);
    },
  );

  testWidgets('ProductCardCompact.strip (лента «Недавние» SCR-50, 280 lp): без переполнения, цена и статус', (
    tester,
  ) async {
    await pumpDs(
      tester,
      const SizedBox(
        width: 280,
        child: ProductCardCompact(data: _data, variant: ProductCardCompactVariant.strip),
      ),
      size: const Size(360, 400),
    );
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(ProductCardCompact)).height, 64);
    expect(tester.widget<Text>(find.text(_data.name)).maxLines, 2);
    expect(find.byType(PriceText), findsOneWidget);
    expect(tester.widget<StockBadge>(find.byType(StockBadge)).label, '24 шт');
  });

  testWidgets('ProductCardGrid 160 lp: «Выбрать вариант» без шеврона и без многоточия (FIX-EF-13)', (tester) async {
    const ProductCardData variants = ProductCardData(
      id: 'p4',
      name: 'Смеситель Ledeme L74103',
      skuLabel: 'Арт. L74103',
      price: Money(165000),
      stockLevel: StockBadgeLevel.inStock,
      stockLabel: 'В наличии',
      favoriteLabel: 'Добавить в избранное',
      action: ProductCardActionKind.chooseVariant,
      actionLabel: 'Выбрать вариант',
    );
    await pumpDs(
      tester,
      SizedBox(
        width: 160,
        height: kProductCardGridExtent(TextScaler.noScaling),
        child: const ProductCardGrid(data: variants),
      ),
      size: const Size(360, 700),
    );
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    final Finder label = find.text('Выбрать вариант');
    expect(label, findsOneWidget);
    expect(tester.widget<Text>(label).overflow, isNot(TextOverflow.ellipsis));
    expect(find.ancestor(of: label, matching: find.byType(FittedBox)), findsOneWidget);
  });

  group('прототип 2026-10-29 (ADR-112)', () {
    testWidgets('ToolbarToggleButton: 40 в цели 48, радиус md; выбранная — тинт, залитая иконка и вес 700; бейдж', (
      tester,
    ) async {
      int taps = 0;
      await pumpDs(
        tester,
        Column(
          children: <Widget>[
            ToolbarToggleButton(
              key: const ValueKey<String>('off'),
              label: 'Избранные',
              icon: Icons.star_outline_rounded,
              selectedIcon: Icons.star_rounded,
              onTap: () => taps++,
            ),
            ToolbarToggleButton(
              key: const ValueKey<String>('on'),
              label: 'Фильтры',
              icon: Icons.filter_alt_outlined,
              selectedIcon: Icons.filter_alt_rounded,
              selected: true,
              badgeCount: 2,
              onTap: () => taps++,
            ),
            const ToolbarToggleButton(
              key: ValueKey<String>('disabled'),
              label: 'Новые',
              icon: Icons.schedule_rounded,
              enabled: false,
              onTap: null,
            ),
          ],
        ),
      );
      const DsColors c = DsColors.lightB;
      expect(tester.getSize(find.byKey(const ValueKey<String>('off'))).height, ToolbarToggleButton.target);
      final Finder box = find.descendant(
        of: find.byKey(const ValueKey<String>('on')),
        matching: find.byType(AnimatedContainer),
      );
      expect(tester.getSize(box).height, ToolbarToggleButton.height);
      final BoxDecoration on = tester.widget<AnimatedContainer>(box).decoration! as BoxDecoration;
      expect(on.color, c.primaryContainer);
      expect((on.border! as Border).top.color, c.primaryContainerBorder);
      expect(on.borderRadius, const BorderRadius.all(Radius.circular(12)));
      expect(
        find.descendant(of: find.byKey(const ValueKey<String>('on')), matching: find.byIcon(Icons.filter_alt_rounded)),
        findsOneWidget,
      );
      final Text onLabel = tester.widget<Text>(find.text('Фильтры'));
      expect(onLabel.style?.fontWeight, FontWeight.w700);
      expect(onLabel.style?.color, c.onPrimaryContainer);
      expect(tester.widget<Text>(find.text('Избранные')).style?.fontWeight, FontWeight.w600);
      expect(find.byType(AppBadge), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('off')));
      await tester.tap(find.byKey(const ValueKey<String>('disabled')));
      expect(taps, 1, reason: 'недоступная не нажимается');
      final BuildContext ctx = tester.element(find.byKey(const ValueKey<String>('off')));
      expect(
        ToolbarToggleButton.estimateWidth(ctx, 'Избранные'),
        closeTo(tester.getSize(find.byKey(const ValueKey<String>('off'))).width, 24),
      );
    });

    testWidgets('ViewModeSegmented.toolbar и SortMenu.toolbar: трек surface с обводкой, сегмент 32; кнопка 40 в 48', (
      tester,
    ) async {
      await pumpDs(
        tester,
        Column(
          children: <Widget>[
            ViewModeSegmented(
              value: ProductViewMode.list,
              onChanged: (ProductViewMode _) {},
              showText: true,
              style: ViewModeSegmentedStyle.toolbar,
              labels: const <ProductViewMode, String>{
                ProductViewMode.grid: 'Сетка',
                ProductViewMode.list: 'Список',
                ProductViewMode.compact: 'Компакт',
              },
            ),
            SortMenu<String>(
              options: const <SortMenuOption<String>>[SortMenuOption<String>(value: 'a', label: 'По названию А–Я')],
              selected: 'a',
              onSelected: (String _) {},
              semanticLabel: 'Сортировка',
              style: SortMenuStyle.toolbar,
            ),
          ],
        ),
      );
      const DsColors c = DsColors.lightB;
      // Сегмент визуально 32, цель касания — 44 по высоте (03 §7.4, §9.26 редакции 1.13).
      expect(
        tester.getSize(find.byKey(const ValueKey<String>('view-mode-list'))).height,
        ViewModeSegmented.toolbarTarget,
      );
      final Finder segmentBox = find.descendant(
        of: find.byKey(const ValueKey<String>('view-mode-list')),
        matching: find.byType(AnimatedContainer),
      );
      expect(tester.getSize(segmentBox.first).height, 32);
      final Text selected = tester.widget<Text>(find.text('Список'));
      expect(selected.style?.color, c.onPrimaryContainer);
      expect(selected.style?.fontWeight, FontWeight.w700);
      expect(tester.widget<Text>(find.text('Сетка')).style?.color, ViewModeSegmented.toolbarIdle(c));
      expect(tester.getSize(find.byType(SortMenu<String>)).height, 48);
      expect(
        find.byWidgetPredicate((Widget w) => w is DsGlyph && w.kind == DsGlyphKind.sortArrows),
        findsOneWidget,
        reason: 'двойная стрелка прототипа',
      );
      expect(tester.widget<Text>(find.text('По названию А–Я')).style?.fontSize, 14);
    });

    testWidgets('CategoryTile.ribbon 118×148: без картинки — нейтральная заглушка; выбранная — тинт и 700', (
      tester,
    ) async {
      await pumpDs(
        tester,
        Row(
          children: <Widget>[
            SizedBox.fromSize(
              size: CategoryTile.ribbonSize,
              child: CategoryTile(
                key: const ValueKey<String>('all'),
                variant: CategoryTileVariant.ribbon,
                label: 'Все товары',
                selected: true,
                onTap: () {},
              ),
            ),
            SizedBox.fromSize(
              size: CategoryTile.ribbonSize,
              child: CategoryTile(
                variant: CategoryTileVariant.ribbon,
                label: 'Канализационные трубы и фитинги',
                onTap: () {},
              ),
            ),
          ],
        ),
      );
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byKey(const ValueKey<String>('all'))), const Size(118, 148));
      expect(find.byKey(const ValueKey<String>('category-tile-placeholder')), findsNWidgets(2));
      expect(
        find.byWidgetPredicate((Widget w) => w is DsGlyph && w.kind == DsGlyphKind.gridOutline),
        findsNWidgets(2),
        reason: 'контурная «сетка» прототипа',
      );
      final Text label = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('all')),
          matching: find.byKey(const ValueKey<String>('category-tile-label')),
        ),
      );
      expect(label.style?.fontWeight, FontWeight.w700);
      expect(label.style?.color, DsColors.lightB.primaryText);
      expect(label.maxLines, 2);
    });

    testWidgets('ProductCardGrid: «В корзине · N — ещё +1» — тинт; нет в наличии — серая недоступная; owner — место', (
      tester,
    ) async {
      int actions = 0;
      ProductCardData data(ProductCardActionKind kind, String? label) => ProductCardData(
        id: 'p-$kind',
        name: 'Смеситель',
        skuLabel: 'Арт. F1',
        price: const Money(235000),
        priceUnit: '/ шт',
        stockLevel: StockBadgeLevel.inStock,
        stockLabel: 'В наличии · 24 шт',
        favoriteLabel: 'Избранное',
        action: kind,
        actionLabel: label,
      );
      final double extent = kProductCardGridExtent(TextScaler.noScaling);
      await pumpDs(
        tester,
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final (ProductCardActionKind kind, String? label) in <(ProductCardActionKind, String?)>[
              (ProductCardActionKind.inCart, 'В корзине · 3 — ещё +1'),
              (ProductCardActionKind.unavailable, 'Нет в наличии'),
              (ProductCardActionKind.hidden, null),
            ])
              SizedBox(
                key: ValueKey<ProductCardActionKind>(kind),
                width: 176,
                height: extent,
                child: ProductCardGrid(
                  data: data(kind, label),
                  callbacks: ProductCardCallbacks(onAction: () => actions++),
                ),
              ),
          ],
        ),
        size: const Size(800, 700),
      );
      expect(tester.takeException(), isNull);
      expect(extent, closeTo(346, 8), reason: '≈ 340 при масштабе 1.0');
      final AppButton inCart = tester.widget<AppButton>(find.byType(AppButton));
      expect(inCart.variant, AppButtonVariant.tint);
      expect(inCart.label, 'В корзине · 3 — ещё +1');
      expect(inCart.fitLabel, isTrue, reason: 'одна строка с уменьшением');
      await tester.tap(find.byType(AppButton));
      expect(actions, 1);
      expect(find.byKey(const ValueKey<String>('product-card-unavailable')), findsOneWidget);
      final Text reason = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('product-card-unavailable')),
          matching: find.text('Нет в наличии'),
        ),
      );
      expect(reason.style?.color, DsColors.lightB.textTertiary);
      // Кнопки ряда на одной линии: у owner на месте кнопки — пустое место той же высоты.
      final double ownerPrice = tester
          .getTopLeft(
            find.descendant(
              of: find.byKey(const ValueKey<ProductCardActionKind>(ProductCardActionKind.hidden)),
              matching: find.byType(PriceText),
            ),
          )
          .dy;
      final double inCartPrice = tester
          .getTopLeft(
            find.descendant(
              of: find.byKey(const ValueKey<ProductCardActionKind>(ProductCardActionKind.inCart)),
              matching: find.byType(PriceText),
            ),
          )
          .dy;
      expect(ownerPrice, inCartPrice);
    });
  });
}
