// `AppTabs` (03 §9.49; FQ-FEORD-04 — бэклог DS этапов E/F): варианты `fixed` / `scrollable` / `segmented`, тап и
// клавиши ←/→/Home/End, повторный выбор активной не сообщается, `disabled` (вкладка и вся полоса), тач-цель 48,
// семантика `tabBar` / `tab` с `selected` и подписью «Заказы, 12», индикатор `fixed` под активной вкладкой.
import 'dart:ui' show SemanticsAction, SemanticsRole, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsData, SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/components/app_tabs.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';

import 'ds_test_support.dart';

const List<AppTab<int>> _three = <AppTab<int>>[
  AppTab<int>(key: ValueKey<String>('t0'), value: 0, label: 'Описание'),
  AppTab<int>(key: ValueKey<String>('t1'), value: 1, label: 'Характеристики'),
  AppTab<int>(key: ValueKey<String>('t2'), value: 2, label: 'Склады'),
];

/// Полоса с состоянием: выбор меняет активную вкладку; [changes] — все сообщённые значения.
class _Host extends StatefulWidget {
  const _Host({required this.tabs, required this.changes, this.variant = AppTabsVariant.fixed, this.enabled = true});

  final List<AppTab<int>> tabs;
  final List<int> changes;
  final AppTabsVariant variant;
  final bool enabled;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int _value = 0;

  @override
  Widget build(BuildContext context) => AppTabs<int>(
    key: const ValueKey<String>('tabs'),
    tabs: widget.tabs,
    value: _value,
    variant: widget.variant,
    enabled: widget.enabled,
    onChanged: (int v) {
      widget.changes.add(v);
      setState(() => _value = v);
    },
  );
}

Future<List<int>> _pumpHost(
  WidgetTester tester, {
  List<AppTab<int>> tabs = _three,
  AppTabsVariant variant = AppTabsVariant.fixed,
  bool enabled = true,
  Size size = const Size(800, 400),
}) async {
  final List<int> changes = <int>[];
  await pumpDs(
    tester,
    _Host(tabs: tabs, changes: changes, variant: variant, enabled: enabled),
    size: size,
    scroll: false,
  );
  return changes;
}

void main() {
  group('AppTabs', () {
    testWidgets('тап — выбор; повторный тап по активной не сообщается', (WidgetTester tester) async {
      final List<int> changes = await _pumpHost(tester);
      await tester.tap(find.byKey(const ValueKey<String>('t1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('t1')));
      await tester.pump();
      expect(changes, <int>[1]);
    });

    testWidgets('клавиатура: ←/→ — соседняя, Home/End — первая/последняя; недоступная пропускается', (
      WidgetTester tester,
    ) async {
      final List<int> changes = await _pumpHost(
        tester,
        tabs: const <AppTab<int>>[
          AppTab<int>(key: ValueKey<String>('t0'), value: 0, label: 'Заказы'),
          AppTab<int>(key: ValueKey<String>('t1'), value: 1, label: 'Долг', enabled: false, disabledReason: 'Нет права'),
          AppTab<int>(key: ValueKey<String>('t2'), value: 2, label: 'Скидки'),
          AppTab<int>(key: ValueKey<String>('t3'), value: 3, label: 'Контакты'),
        ],
      );
      // Фокус на первой вкладке (Tab), далее — стрелки.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(changes, <int>[2, 3, 2, 0], reason: '«Долг» недоступна — стрелка переходит через неё');
    });

    testWidgets('disabled: вкладка без права не выбирается, тултип с причиной; вся полоса без сети — тоже', (
      WidgetTester tester,
    ) async {
      List<int> changes = await _pumpHost(
        tester,
        tabs: const <AppTab<int>>[
          AppTab<int>(key: ValueKey<String>('t0'), value: 0, label: 'Товары'),
          AppTab<int>(key: ValueKey<String>('t1'), value: 1, label: 'Долги', enabled: false, disabledReason: 'Нет права'),
        ],
      );
      await tester.tap(find.byKey(const ValueKey<String>('t1')));
      await tester.pump();
      expect(changes, isEmpty);
      expect(find.byTooltip('Нет права'), findsOneWidget);

      changes = await _pumpHost(tester, enabled: false, variant: AppTabsVariant.segmented);
      await tester.tap(find.byKey(const ValueKey<String>('t2')));
      await tester.pump();
      expect(changes, isEmpty);
    });

    for (final AppTabsVariant v in AppTabsVariant.values) {
      testWidgets('${v.name}: тач-цель каждой вкладки ≥ 48, полоса 48', (WidgetTester tester) async {
        await _pumpHost(tester, variant: v);
        expect(tester.getSize(find.byKey(const ValueKey<String>('tabs'))).height, AppTabs.height);
        final Finder targets = find.descendant(
          of: find.byKey(const ValueKey<String>('tabs')),
          matching: find.byType(DsInteractive),
        );
        expect(targets, findsNWidgets(3));
        for (final Element e in targets.evaluate()) {
          final Size s = tester.getSize(find.byWidget(e.widget));
          expect(s.height, greaterThanOrEqualTo(48));
          expect(s.width, greaterThanOrEqualTo(48));
        }
      });
    }

    testWidgets('семантика: tabBar → tab с selected; подпись со счётчиком «Заказы, 12»', (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpHost(
        tester,
        tabs: const <AppTab<int>>[
          AppTab<int>(key: ValueKey<String>('t0'), value: 0, label: 'Заказы', count: 12),
          AppTab<int>(key: ValueKey<String>('t1'), value: 1, label: 'Долг'),
        ],
      );
      final SemanticsNode first = tester.getSemantics(find.byKey(const ValueKey<String>('t0')));
      final SemanticsData d0 = first.getSemanticsData();
      expect(d0.role, SemanticsRole.tab);
      expect(d0.label, 'Заказы, 12');
      expect(d0.flagsCollection.isSelected, Tristate.isTrue);
      final SemanticsData d1 = tester.getSemantics(find.byKey(const ValueKey<String>('t1'))).getSemanticsData();
      expect(d1.flagsCollection.isSelected, Tristate.isFalse);
      expect(d1.hasAction(SemanticsAction.tap), isTrue);
      SemanticsNode? parent = first.parent;
      while (parent != null && parent.getSemanticsData().role != SemanticsRole.tabBar) {
        parent = parent.parent;
      }
      expect(parent, isNotNull, reason: 'вкладки — внутри группы tabBar');
      expect(tester.takeException(), isNull, reason: 'проверки ролей семантики Flutter пройдены');
      handle.dispose();
    });

    testWidgets('fixed: индикатор 2 px под активной вкладкой и переезжает к новой', (WidgetTester tester) async {
      await _pumpHost(tester);
      Rect indicator() => tester.getRect(find.byKey(const ValueKey<String>('app-tabs-indicator')));
      Rect tab(String k) => tester.getRect(find.byKey(ValueKey<String>(k)));
      expect(indicator().height, AppTabs.indicator);
      expect(indicator().left, tab('t0').left);
      expect(indicator().width, closeTo(tab('t0').width, 0.01));
      await tester.tap(find.byKey(const ValueKey<String>('t2')));
      await tester.pumpAndSettle();
      expect(indicator().left, closeTo(tab('t2').left, 0.01));
      expect(indicator().bottom, closeTo(tab('t2').bottom, 0.01));
    });

    testWidgets('scrollable: мин. ширина вкладки 96, выбранная подводится в видимую область', (
      WidgetTester tester,
    ) async {
      final List<AppTab<int>> many = <AppTab<int>>[
        for (int i = 0; i < 8; i++) AppTab<int>(key: ValueKey<String>('t$i'), value: i, label: 'Вкладка $i'),
      ];
      await _pumpHost(tester, tabs: many, variant: AppTabsVariant.scrollable, size: const Size(360, 400));
      expect(tester.getSize(find.byKey(const ValueKey<String>('t0'))).width, greaterThanOrEqualTo(96));
      expect(tester.getRect(find.byKey(const ValueKey<String>('t7'))).left, greaterThan(360));
      await tester.ensureVisible(find.byKey(const ValueKey<String>('t6')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('t6')));
      await tester.pumpAndSettle();
      final Rect r = tester.getRect(find.byKey(const ValueKey<String>('t6')));
      expect(r.left, greaterThanOrEqualTo(0));
      expect(r.right, lessThanOrEqualTo(360 + 0.01));
    });
  });
}
