// Компоненты DS шапки, навигации и строки управления по прототипу 2026-10-29 (ADR-111, ADR-112): состояния и
// доступность.
// - TopAppBarCartButton (03 §9.70, 02 UI-10-041): тинт и рамка, две строки, бейдж (0 — нет, > 99 — «99+»),
//   предупреждение иконкой, «только иконка», hover/фокус, недоступная; Semantics — кнопка с полной подписью.
// - NavigationDrawerApp (03 §9.71): группы с заголовком, выбранный пункт не только цветом (полоса, залитая иконка,
//   вес), Semantics «Навигация» и selected у пунктов, Esc → onClose, ширина 320.
// - ToolbarToggleButton (03 §9.72): Semantics toggled/button/enabled, подпись с бейджем, действие «нажать» для
//   TalkBack/Narrator, «только иконка» — тултип.
// - ViewModeSegmented.toolbar: радиогруппа (inMutuallyExclusiveGroup + checked), выбранный — тинт и 700, ←/→.
// Данные синтетические.
// Тест-кейсы 12_TEST_PLAN: T-DS-099 (TopAppBarCartButton), T-DS-100 (NavigationDrawerApp), T-DS-101
//   (ToolbarToggleButton, ViewModeSegmented.toolbar), T-CART-037.
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsAction, SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/components/app_badge.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/navigation_drawer_app.dart';
import 'package:optomstroy/design_system/components/toolbar_toggle_button.dart';
import 'package:optomstroy/design_system/components/top_app_bar_cart_button.dart';
import 'package:optomstroy/design_system/components/top_app_bar_pos.dart';
import 'package:optomstroy/design_system/components/view_mode_segmented.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

import 'ds_test_support.dart';

const DsColors _c = DsColors.lightB;

BoxDecoration _decorationIn(WidgetTester tester, Finder of) =>
    tester
            .widget<AnimatedContainer>(find.descendant(of: of, matching: find.byType(AnimatedContainer)).first)
            .decoration!
        as BoxDecoration;

/// Включает клавиатурный режим подсветки (hover и кольцо фокуса), как на Windows с мышью и клавиатурой.
void _traditionalHighlight() {
  FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
  addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);
}

Future<void> _hover(WidgetTester tester, Finder target) async {
  final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(tester.getCenter(target));
  await tester.pumpAndSettle();
}

void main() {
  group('TopAppBarCartButton (кнопка-итог шапки)', () {
    testWidgets('тинт с рамкой, 44 визуально в цели ≥ 48; две строки и бейдж; Semantics — кнопка с подписью', (
      tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      int taps = 0;
      await pumpDs(
        tester,
        Align(
          alignment: Alignment.topLeft,
          child: TopAppBarCartButton(
            label: 'Корзина',
            count: 3,
            totalText: '16 007,50 сом',
            semanticLabel: 'Открыть корзину, 3 позиции, 16 007 сом 50 тыйын',
            onTap: () => taps++,
          ),
        ),
      );
      final Finder button = find.byType(TopAppBarCartButton);
      final BoxDecoration d = _decorationIn(tester, button);
      expect(d.color, _c.primaryContainer);
      expect((d.border! as Border).top.color, _c.primaryContainerBorder);
      expect(d.borderRadius, const BorderRadius.all(Radius.circular(12)));
      expect(
        tester.getSize(find.descendant(of: button, matching: find.byType(AnimatedContainer)).first).height,
        TopAppBarCartButton.height,
      );
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      expect(find.text('Корзина'), findsOneWidget);
      expect(find.text('16 007,50 сом'), findsOneWidget);
      expect(tester.widget<Text>(find.text('16 007,50 сом')).style?.fontWeight, FontWeight.w700);
      final Finder badge = find.byKey(const ValueKey<String>('top-app-bar-cart-badge'));
      expect(find.descendant(of: badge, matching: find.text('3')), findsOneWidget);
      expect(((tester.widget<Container>(badge).decoration!) as BoxDecoration).color, _c.primary);
      expect(tester.widget<Text>(find.text('3')).style?.color, _c.onPrimary);
      expect(
        tester.getSemantics(button),
        containsSemantics(
          label: 'Открыть корзину, 3 позиции, 16 007 сом 50 тыйын',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      await tester.tap(button);
      expect(taps, 1);
      final SemanticsNode node = tester.getSemantics(button);
      node.owner!.performAction(node.id, SemanticsAction.tap);
      await tester.pump();
      expect(taps, 2, reason: 'действие «нажать» экранного диктора');
      semantics.dispose();
    });

    testWidgets('бейдж: 0 — нет, 120 — «99+»; предупреждение — иконка, не только цвет; «только иконка»', (
      tester,
    ) async {
      await pumpDs(
        tester,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TopAppBarCartButton(
              key: const ValueKey<String>('empty'),
              label: 'Корзина',
              count: 0,
              totalText: '0 поз.',
              semanticLabel: 'Открыть корзину',
              onTap: () {},
            ),
            TopAppBarCartButton(
              key: const ValueKey<String>('many'),
              label: 'Корзина',
              count: 120,
              totalText: '≈ 1 200 сом',
              semanticLabel: 'Открыть корзину, 120 позиций',
              warning: true,
              onTap: () {},
            ),
            TopAppBarCartButton(
              key: const ValueKey<String>('icon'),
              label: 'Корзина',
              count: 5,
              totalText: '5 поз.',
              semanticLabel: 'Открыть корзину, 5 позиций',
              showText: false,
              onTap: () {},
            ),
          ],
        ),
      );
      Finder badgeOf(String k) => find.descendant(
        of: find.byKey(ValueKey<String>(k)),
        matching: find.byKey(const ValueKey<String>('top-app-bar-cart-badge')),
      );
      expect(badgeOf('empty'), findsNothing);
      expect(find.descendant(of: badgeOf('many'), matching: find.text('99+')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('many')),
          matching: find.byIcon(Icons.warning_amber_rounded),
        ),
        findsOneWidget,
      );
      final Finder iconOnly = find.byKey(const ValueKey<String>('icon'));
      expect(find.descendant(of: iconOnly, matching: find.text('Корзина')), findsNothing);
      expect(find.descendant(of: iconOnly, matching: find.text('5 поз.')), findsNothing);
      expect(badgeOf('icon'), findsOneWidget);
      expect(
        tester.getSize(iconOnly).width,
        lessThan(tester.getSize(find.byKey(const ValueKey<String>('empty'))).width),
      );
    });

    testWidgets('medium (showLabel: false) — итог одной строкой без «Корзина»; предупреждение — тултип с текстом', (
      tester,
    ) async {
      await pumpDs(
        tester,
        Center(
          child: TopAppBarCartButton(
            key: const ValueKey<String>('medium'),
            label: 'Корзина',
            count: 5,
            totalText: '16 007,50 сом',
            semanticLabel: 'Открыть корзину, 5 позиций, В корзине есть предупреждения',
            warning: true,
            warningText: 'В корзине есть предупреждения',
            showLabel: false,
            onTap: () {},
          ),
        ),
        size: const Size(800, 600),
      );
      final Finder button = find.byKey(const ValueKey<String>('medium'));
      expect(
        find.descendant(of: button, matching: find.text('16 007,50 сом')),
        findsOneWidget,
        reason: 'итог виден',
      );
      expect(find.descendant(of: button, matching: find.text('Корзина')), findsNothing);
      expect(find.descendant(of: button, matching: find.byIcon(Icons.warning_amber_rounded)), findsOneWidget);
      // Warning — иконка и текст (ядро §24.1): текст — в тултипе.
      expect(
        find.byWidgetPredicate((Widget w) => w is Tooltip && w.message == 'В корзине есть предупреждения'),
        findsOneWidget,
      );
    });

    testWidgets('hover — primaryContainerPressed; фокус с клавиатуры — кольцо; Enter открывает', (tester) async {
      _traditionalHighlight();
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      int taps = 0;
      await pumpDs(
        tester,
        Align(
          alignment: Alignment.topLeft,
          child: TopAppBarCartButton(
            label: 'Корзина',
            count: 1,
            totalText: '450 сом',
            semanticLabel: 'Открыть корзину',
            focusNode: node,
            onTap: () => taps++,
          ),
        ),
      );
      final Finder button = find.byType(TopAppBarCartButton);
      await _hover(tester, button);
      expect(_decorationIn(tester, button).color, _c.primaryContainerPressed);
      expect(find.byWidgetPredicate((Widget w) => w is DsFocusRing && w.visible), findsNothing);
      node.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(find.byWidgetPredicate((Widget w) => w is DsFocusRing && w.visible), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('без onTap — недоступна: Semantics enabled = false, нажатие ничего не делает', (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await pumpDs(
        tester,
        const Align(
          alignment: Alignment.topLeft,
          child: TopAppBarCartButton(
            label: 'Корзина',
            count: 2,
            totalText: '2 поз.',
            semanticLabel: 'Открыть корзину',
            onTap: null,
          ),
        ),
      );
      expect(
        tester.getSemantics(find.byType(TopAppBarCartButton)),
        containsSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
      );
      await tester.tap(find.byType(TopAppBarCartButton), warnIfMissed: false);
      await tester.pump();
      semantics.dispose();
    });
  });

  testWidgets(
    '«бургер» (как и колокольчик — TopAppBarIconButton) и аватар шапки — кнопки с действием «нажать» для экранного диктора',
    (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final List<String> taps = <String>[];
      await pumpDs(
        tester,
        Row(
          children: <Widget>[
            TopAppBarIconButton(
              key: const ValueKey<String>('menu'),
              icon: Icons.menu_rounded,
              semanticLabel: 'Меню разделов',
              onPressed: () => taps.add('menu'),
            ),
            TopAppBarUser(
              key: const ValueKey<String>('user'),
              name: 'Айгуль',
              role: 'Продавец',
              onTap: () => taps.add('user'),
            ),
          ],
        ),
      );
      for (final (String key, String label) in <(String, String)>[
        ('menu', 'Меню разделов'),
        ('user', 'Айгуль, Продавец'),
      ]) {
        final SemanticsNode node = tester.getSemantics(
          find.descendant(of: find.byKey(ValueKey<String>(key)), matching: find.byType(DsInteractive)),
        );
        expect(node, containsSemantics(label: label, isButton: true, hasTapAction: true), reason: key);
        node.owner!.performAction(node.id, SemanticsAction.tap);
        await tester.pump();
      }
      expect(taps, <String>['menu', 'user']);
      semantics.dispose();
    },
  );

  group('NavigationDrawerApp (drawer навигации)', () {
    List<String> taps = <String>[];

    Widget drawer({VoidCallback? onClose}) => Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        height: 640,
        child: NavigationDrawerApp(
          semanticLabel: 'Навигация',
          onClose: onClose,
          header: const Text('Оптомстрой'),
          groups: <NavigationDrawerGroup>[
            NavigationDrawerGroup(
              items: <NavigationDrawerItem>[
                NavigationDrawerItem(
                  key: const ValueKey<String>('nav-catalog'),
                  icon: Icons.grid_view_outlined,
                  selectedIcon: Icons.grid_view_rounded,
                  label: 'Каталог',
                  selected: true,
                  onTap: () => taps.add('catalog'),
                ),
                NavigationDrawerItem(
                  key: const ValueKey<String>('nav-customers'),
                  icon: Icons.people_outline_rounded,
                  selectedIcon: Icons.people_rounded,
                  label: 'Клиенты',
                  onTap: () => taps.add('customers'),
                ),
              ],
            ),
            const NavigationDrawerGroup(title: 'Пустая группа', items: <NavigationDrawerItem>[]),
            NavigationDrawerGroup(
              title: 'Другие разделы',
              items: <NavigationDrawerItem>[
                NavigationDrawerItem(
                  key: const ValueKey<String>('nav-orders'),
                  icon: Icons.receipt_long_outlined,
                  label: 'Заказы',
                  onTap: () => taps.add('orders'),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    setUp(() => taps = <String>[]);

    testWidgets('выбранный пункт — тинт, полоса primaryText, залитая иконка и вес 600; прочие — 500', (tester) async {
      await pumpDs(tester, drawer(), scroll: false);
      expect(tester.getSize(find.byType(NavigationDrawerApp)).width, DsBreakpoints.navDrawer);
      final Finder selected = find.byKey(const ValueKey<String>('nav-catalog'));
      expect(tester.getSize(selected).height, 48);
      final Container row = tester.widget<Container>(
        find.descendant(
          of: selected,
          matching: find.byWidgetPredicate((Widget w) => w is Container && w.constraints?.maxHeight == 48),
        ),
      );
      expect((row.decoration! as BoxDecoration).color, _c.primaryContainer);
      expect(
        find.descendant(
          of: selected,
          matching: find.byWidgetPredicate((Widget w) => w is Container && w.color == _c.primaryText),
        ),
        findsOneWidget,
        reason: 'полоса 3 px у выбранного (A11Y-004)',
      );
      expect(find.descendant(of: selected, matching: find.byIcon(Icons.grid_view_rounded)), findsOneWidget);
      final Text label = tester.widget<Text>(find.text('Каталог'));
      expect(label.style?.fontWeight, FontWeight.w600);
      expect(label.style?.color, _c.onPrimaryContainer);
      final Text other = tester.widget<Text>(find.text('Клиенты'));
      expect(other.style?.fontWeight, FontWeight.w500);
      expect(other.style?.color, _c.textPrimary);
      expect(find.byIcon(Icons.people_outline_rounded), findsOneWidget);
      expect(find.text('Другие разделы'), findsOneWidget);
      expect(find.text('Пустая группа'), findsNothing, reason: 'пустая группа не выводится');
      await tester.tap(find.byKey(const ValueKey<String>('nav-orders')));
      expect(taps, <String>['orders']);
    });

    testWidgets('Semantics: область «Навигация», пункты — кнопки с selected, заголовок группы — header', (
      tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await pumpDs(tester, drawer(), scroll: false);
      expect(find.bySemanticsLabel('Навигация'), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(const ValueKey<String>('nav-catalog'))),
        containsSemantics(
          label: 'Каталог',
          isButton: true,
          hasSelectedState: true,
          isSelected: true,
          hasTapAction: true,
        ),
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey<String>('nav-customers'))),
        containsSemantics(label: 'Клиенты', isButton: true, isSelected: false),
      );
      expect(tester.getSemantics(find.text('Другие разделы')), containsSemantics(isHeader: true));
      semantics.dispose();
    });

    testWidgets('Esc → onClose; hover невыбранного — surfaceHover', (tester) async {
      _traditionalHighlight();
      int closes = 0;
      await pumpDs(tester, drawer(onClose: () => closes++), scroll: false);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(closes, 1);
      final Finder customers = find.byKey(const ValueKey<String>('nav-customers'));
      await _hover(tester, customers);
      final Container row = tester.widget<Container>(
        find.descendant(
          of: customers,
          matching: find.byWidgetPredicate((Widget w) => w is Container && w.constraints?.maxHeight == 48),
        ),
      );
      expect((row.decoration! as BoxDecoration).color, _c.surfaceHover);
    });
  });

  group('ToolbarToggleButton — доступность', () {
    testWidgets('Semantics: button + toggled, подпись с числом бейджа; недоступная — enabled = false', (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      int taps = 0;
      await pumpDs(
        tester,
        Column(
          children: <Widget>[
            ToolbarToggleButton(
              key: const ValueKey<String>('fav'),
              label: 'Избранные',
              icon: Icons.star_outline_rounded,
              selectedIcon: Icons.star_rounded,
              onTap: () => taps++,
            ),
            ToolbarToggleButton(
              key: const ValueKey<String>('filters'),
              label: 'Фильтры',
              icon: Icons.filter_alt_outlined,
              selected: true,
              badgeCount: 2,
              onTap: () => taps++,
            ),
            const ToolbarToggleButton(
              key: ValueKey<String>('new'),
              label: 'Новые',
              icon: Icons.schedule_rounded,
              enabled: false,
              onTap: null,
            ),
          ],
        ),
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey<String>('fav'))),
        containsSemantics(
          label: 'Избранные',
          isButton: true,
          hasToggledState: true,
          isToggled: false,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey<String>('filters'))),
        containsSemantics(label: 'Фильтры, 2', isButton: true, hasToggledState: true, isToggled: true),
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey<String>('new'))),
        containsSemantics(label: 'Новые', isButton: true, hasEnabledState: true, isEnabled: false, hasTapAction: false),
      );
      // Действие «нажать» из семантики (TalkBack/Narrator).
      final SemanticsNode fav = tester.getSemantics(find.byKey(const ValueKey<String>('fav')));
      fav.owner!.performAction(fav.id, SemanticsAction.tap);
      await tester.pump();
      expect(taps, 1);
      semantics.dispose();
    });

    testWidgets('«только иконка» — подпись в тултипе и Semantics, ширина меньше', (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await pumpDs(
        tester,
        Column(
          children: <Widget>[
            ToolbarToggleButton(
              key: const ValueKey<String>('full'),
              label: 'Избранные',
              icon: Icons.star_outline_rounded,
              onTap: () {},
            ),
            ToolbarToggleButton(
              key: const ValueKey<String>('short'),
              label: 'Избранные',
              icon: Icons.star_outline_rounded,
              showLabel: false,
              onTap: () {},
            ),
          ],
        ),
      );
      final Finder short = find.byKey(const ValueKey<String>('short'));
      expect(find.descendant(of: short, matching: find.text('Избранные')), findsNothing);
      expect(find.descendant(of: short, matching: find.byType(Tooltip)), findsOneWidget);
      expect(
        tester.getSemantics(find.descendant(of: short, matching: find.byType(DsInteractive))),
        containsSemantics(label: 'Избранные', isButton: true, hasTapAction: true),
      );
      expect(tester.getSize(short).width, lessThan(tester.getSize(find.byKey(const ValueKey<String>('full'))).width));
      expect(tester.getSize(short).height, ToolbarToggleButton.target);
      expect(find.byType(AppBadge), findsNothing);
      semantics.dispose();
    });
  });

  group('ViewModeSegmented.toolbar — радиогруппа', () {
    testWidgets('сегменты — радиокнопки (inMutuallyExclusiveGroup, checked); выбранный — тинт и 700; ←/→', (
      tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final List<ProductViewMode> changes = <ProductViewMode>[];
      ProductViewMode value = ProductViewMode.grid;
      await pumpDs(
        tester,
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) => ViewModeSegmented(
            value: value,
            onChanged: (ProductViewMode m) {
              changes.add(m);
              setState(() => value = m);
            },
            showText: true,
            style: ViewModeSegmentedStyle.toolbar,
            labels: const <ProductViewMode, String>{
              ProductViewMode.grid: 'Сетка',
              ProductViewMode.list: 'Список',
              ProductViewMode.compact: 'Компакт',
            },
          ),
        ),
      );
      Finder seg(ProductViewMode m) => find.byKey(ValueKey<String>('view-mode-${m.value}'));
      expect(
        tester.getSemantics(seg(ProductViewMode.grid)),
        containsSemantics(
          label: 'Сетка',
          isButton: true,
          isInMutuallyExclusiveGroup: true,
          hasCheckedState: true,
          isChecked: true,
        ),
      );
      expect(
        tester.getSemantics(seg(ProductViewMode.list)),
        containsSemantics(label: 'Список', isInMutuallyExclusiveGroup: true, hasCheckedState: true, isChecked: false),
      );
      expect(tester.widget<Text>(find.text('Сетка')).style?.fontWeight, FontWeight.w700);
      expect(tester.widget<Text>(find.text('Сетка')).style?.color, _c.onPrimaryContainer);
      expect(tester.widget<Text>(find.text('Компакт')).style?.color, ViewModeSegmented.toolbarIdle(_c));

      await tester.tap(seg(ProductViewMode.list));
      await tester.pumpAndSettle();
      expect(changes, <ProductViewMode>[ProductViewMode.list]);
      expect(tester.getSemantics(seg(ProductViewMode.list)), containsSemantics(isChecked: true));
      expect(tester.getSemantics(seg(ProductViewMode.grid)), containsSemantics(isChecked: false));

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(changes.length, greaterThanOrEqualTo(2), reason: 'стрелки меняют вид');
      semantics.dispose();
    });
  });
}
