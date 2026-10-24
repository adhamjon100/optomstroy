// Компоненты каталога RM-E-007 (03 §9.8–§9.13, §9.16, §9.17, §9.23–§9.26, §9.51): формат цены (U+202F,
// запятая, U+2212), StockBadge (цвет + иконка + текст), FavoriteToggle (только звезда, toggled),
// ViewModeSegmented (повторный выбор — без события, ←/→), SortMenu (тот же пункт — без события),
// CategorySidebarItem (selected — без действия, счётчик «0»), CategoryChip (check у выбранного),
// CategoryTile, NotificationBell («99+», точка), FoundCountText (скелетон), FilterSection, ProductCard*.
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/category_chip.dart';
import 'package:optomstroy/design_system/components/category_sidebar_item.dart';
import 'package:optomstroy/design_system/components/category_tile.dart';
import 'package:optomstroy/design_system/components/favorite_toggle.dart';
import 'package:optomstroy/design_system/components/filter_panel.dart';
import 'package:optomstroy/design_system/components/found_count_text.dart';
import 'package:optomstroy/design_system/components/notification_bell.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/product_card.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/sort_menu.dart';
import 'package:optomstroy/design_system/components/stock_badge.dart';
import 'package:optomstroy/design_system/components/view_mode_segmented.dart';

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
            height: 200 + kProductCardGridBodyHeight,
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
    expect(find.text('Арт. F4252-CR'), findsOneWidget);
    expect(find.text('+ Добавить'), findsOneWidget);
    await tester.tap(find.text('+ Добавить'));
    expect(actions, 1);
    await tester.tap(find.text('Арт. F4252-CR'));
    expect(opened, 1);
    expect(find.byType(ProductCardCompact), findsNWidgets(2));
    expect(find.text('F4252-CR'), findsNWidgets(2), reason: 'компакт — артикул без «Арт.»');
  });

  testWidgets('ProductCardCompact: в колонке остатка — число; статус без числа и «Нет в наличии» — целиком', (
    tester,
  ) async {
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
    expect(labels, <String>['24 шт', 'Мало', 'Нет в наличии']);
  });

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
      const SizedBox(
        width: 160,
        height: 160 + kProductCardGridBodyHeight,
        child: ProductCardGrid(data: variants),
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
}
