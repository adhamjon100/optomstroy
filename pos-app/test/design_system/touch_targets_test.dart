// RM-C-003 критерий 3: тач-цели компонентов ≥ 48 lp (03 §7.4, A11Y). Исключения 03 §7.4:
// `AppButton` S и `AppIconButton.small` — цель 44 (только expanded с мышью); проверяются отдельно.
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_checkbox.dart';
import 'package:optomstroy/design_system/components/app_dropdown.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_list_tile.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/app_switch.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/bottom_nav_bar.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/navigation_rail_app.dart';
import 'package:optomstroy/design_system/components/option_tile.dart';
import 'package:optomstroy/design_system/components/otp_field.dart';
import 'package:optomstroy/design_system/components/phone_field.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/design_system/components/search_bar.dart';
import 'package:optomstroy/design_system/components/top_app_bar_pos.dart';
import 'package:optomstroy/design_system/gallery/ds_showcase.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';

import 'ds_test_support.dart';

void _noop() {}

void _noopValue<T>(T _) {}

/// Минимальный размер всех `DsInteractive` под [finder].
Future<void> expectTargets(WidgetTester tester, Finder finder, {double min = 48}) async {
  final Finder targets = find.descendant(of: finder, matching: find.byType(DsInteractive), matchRoot: true);
  expect(targets, findsWidgets, reason: 'нет интерактивных областей');
  for (final Element e in targets.evaluate()) {
    final Size s = tester.getSize(find.byWidget(e.widget));
    expect(s.width, greaterThanOrEqualTo(min), reason: '${e.widget} ${e.toStringShort()} ширина $s');
    expect(s.height, greaterThanOrEqualTo(min), reason: '${e.widget} высота $s');
  }
}

void main() {
  final Map<String, Widget> standard = <String, Widget>{
    'AppButton M': const AppButton(label: 'Далее', onPressed: _noop),
    'AppButton L': const AppButton(label: 'Получить код', onPressed: _noop, size: AppButtonSize.l),
    'AppButton disabled': const AppButton(label: 'Далее', onPressed: null),
    'AppButton loading': const AppButton(label: 'Далее', onPressed: _noop, loading: true),
    'AppIconButton': const AppIconButton(icon: Icons.close, semanticLabel: 'Закрыть', onPressed: _noop),
    'AppIconButton filled': const AppIconButton(
      icon: Icons.add,
      semanticLabel: 'Добавить',
      onPressed: _noop,
      variant: AppIconButtonVariant.filled,
    ),
    'AppCheckbox': const AppCheckbox(value: true, onChanged: _noopValue<bool?>, semanticLabel: 'Выбор'),
    'AppCheckbox + подпись': const AppCheckbox(value: false, onChanged: _noopValue<bool?>, label: 'Печать'),
    'AppRadio': const AppRadio<int>(value: 1, groupValue: 1, onChanged: _noopValue<int>, semanticLabel: 'Клиент'),
    'AppSwitch': const AppSwitch(value: true, onChanged: _noopValue<bool>, semanticLabel: 'Биометрия'),
    'OptionTile': const SizedBox(
      width: 320,
      child: OptionTile(title: 'Самовывоз', selected: true, onTap: _noop),
    ),
    'AppListTile': const SizedBox(
      width: 320,
      child: AppListTile(title: 'Настройки', onTap: _noop),
    ),
    'ErrorState.fullScreen (код запроса)': const ErrorState.fullScreen(
      title: 'Ошибка',
      message: 'Не удалось',
      onRetry: _noop,
      requestId: 'req-1',
    ),
    'TopAppBarUser': const TopAppBarUser(name: 'Абдулла', role: 'Продавец', onTap: _noop),
  };

  for (final MapEntry<String, Widget> e in standard.entries) {
    testWidgets('${e.key}: тач-цель ≥ 48', (WidgetTester tester) async {
      await pumpDs(tester, Center(child: e.value));
      await expectTargets(tester, find.byWidget(e.value));
    });
  }

  testWidgets('PinField: клавиши нампада 72×56 ≥ 48', (WidgetTester tester) async {
    await pumpDs(
      tester,
      PinField(
        length: 6,
        autofocus: false,
        semanticLabel: (int n, int l) => 'PIN $n/$l',
        backspaceLabel: 'Стереть',
        onBiometric: _noop,
        biometricLabel: 'Биометрия',
      ),
    );
    await expectTargets(tester, find.byType(PinField));
  });

  testWidgets('BottomNavBar: пункты ≥ 48, высота 80', (WidgetTester tester) async {
    await pumpDs(
      tester,
      const BottomNavBar(destinations: dsShowcaseDestinations, selectedIndex: 0, onSelected: _noopValue<int>),
      size: const Size(360, 720),
    );
    await expectTargets(tester, find.byType(BottomNavBar));
    expect(tester.getSize(find.byType(BottomNavBar)).height, greaterThanOrEqualTo(BottomNavBar.height));
  });

  testWidgets('NavigationRailApp: пункты ≥ 48', (WidgetTester tester) async {
    await pumpDs(
      tester,
      const SizedBox(
        height: 600,
        child: NavigationRailApp(destinations: dsShowcaseDestinations, selectedIndex: 0, onSelected: _noopValue<int>),
      ),
      size: const Size(800, 800),
    );
    await expectTargets(tester, find.byType(NavigationRailApp));
  });

  testWidgets('поля ввода: высота ≥ 48 (M/L), OTP-ячейки, поиск', (WidgetTester tester) async {
    await pumpDs(
      tester,
      const Column(
        children: <Widget>[
          SizedBox(
            width: 320,
            child: AppTextField(key: Key('m'), hint: 'M'),
          ),
          SizedBox(
            width: 320,
            child: AppTextField(key: Key('l'), hint: 'L', size: AppTextFieldSize.l),
          ),
          SizedBox(
            width: 360,
            child: PhoneField(key: Key('phone'), semanticLabel: 'Телефон', variant: PhoneFieldVariant.auth),
          ),
          SizedBox(
            width: 400,
            child: SearchBar(key: Key('search'), onScan: _noop, scannerLabel: 'Сканер'),
          ),
          OtpField(key: Key('otp'), semanticLabel: 'Код', autofocus: false),
        ],
      ),
      size: const Size(800, 900),
    );
    for (final String k in <String>['m', 'l', 'phone']) {
      final Finder tf = find.descendant(of: find.byKey(Key(k)), matching: find.byType(TextField));
      expect(tester.getSize(tf).height, greaterThanOrEqualTo(48), reason: k);
    }
    // SearchBar: 48 на medium/expanded, кнопка сканера — 48.
    final Finder sb = find.byKey(const Key('search'));
    expect(tester.getSize(sb).height, greaterThanOrEqualTo(48));
    await expectTargets(tester, sb);
    // OTP: вся строка ячеек — одна цель (скрытое поле), высота 56.
    expect(tester.getSize(find.byKey(const Key('otp'))).height, greaterThanOrEqualTo(48));
  });

  testWidgets('AppDropdown, AppSnackbar (действие и крестик), AppBottomSheet (крестик)', (WidgetTester tester) async {
    await pumpDs(
      tester,
      const Column(
        children: <Widget>[
          SizedBox(
            width: 320,
            child: AppDropdown<int>(
              key: Key('dd'),
              value: 1,
              onChanged: _noopValue<int>,
              items: <AppDropdownItem<int>>[AppDropdownItem<int>(value: 1, label: 'шт')],
            ),
          ),
          SizedBox(
            width: 360,
            child: AppSnackbar(
              key: Key('sb'),
              message: 'Ошибка',
              variant: AppSnackbarVariant.error,
              actionLabel: 'Повторить',
              onAction: _noop,
              onClose: _noop,
            ),
          ),
          SizedBox(
            width: 400,
            child: AppBottomSheet(key: Key('sheet'), title: 'Сортировка', body: Text('…')),
          ),
        ],
      ),
    );
    await expectTargets(tester, find.byKey(const Key('dd')));
    // Действие снекбара — S 36 визуально, цель 44 (03 §7.4, S), крестик — 48.
    await expectTargets(tester, find.byKey(const Key('sb')), min: 44);
    await expectTargets(tester, find.byKey(const Key('sheet')));
  });

  testWidgets('исключения 03 §7.4: AppButton S и AppIconButton.small — цель ≥ 44', (WidgetTester tester) async {
    await pumpDs(
      tester,
      const Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AppButton(key: Key('s'), label: 'Очистить', onPressed: _noop, size: AppButtonSize.s),
          AppIconButton(key: Key('small'), icon: Icons.more_vert, semanticLabel: 'Ещё', onPressed: _noop, small: true),
        ],
      ),
    );
    await expectTargets(tester, find.byKey(const Key('s')), min: 44);
    await expectTargets(tester, find.byKey(const Key('small')), min: 44);
  });

  // Сквозная проверка правилом Flutter (Android, 48×48) на витрине стандартных размеров.
  for (final WindowClass wc in <WindowClass>[WindowClass.compact, WindowClass.expanded]) {
    testWidgets('androidTapTargetGuideline: разделы «selection», «navigation» и «tabs» (${wc.name})', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final Size size = wc == WindowClass.compact ? const Size(360, 3000) : const Size(1280, 3000);
      for (final String id in <String>['selection', 'navigation', 'tabs']) {
        final DsShowcaseSection s = DsShowcase.sections.firstWhere((DsShowcaseSection x) => x.id == id);
        await pumpDs(tester, Builder(builder: s.builder), size: size);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline), reason: id);
      }
      handle.dispose();
    });
  }
}
