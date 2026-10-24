// F-flutter-ui-8 / F-trace-6 — 13 RM-F-013 критерий 5: golden `AppBottomSheet.side` шириной 400 (medium) и 480
// (expanded); 03 §9.47, DS-089: панель справа, скругление `lg` слева, без ручки, шапка «заголовок + закрыть»,
// закреплённый футер. Палитра B, окна 800×640 и 1280×800 (D-18).
//
// Обновить эталоны: flutter test test/golden/app_bottom_sheet_side_golden_test.dart --update-goldens
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

import 'design_system_golden_test.dart' show GoldenWindow, goldenWindows;

/// Ширина `side` по классу окна (03 §9.47).
const Map<WindowClass, double> sideWidths = <WindowClass, double>{
  WindowClass.medium: AppBottomSheet.sideMedium,
  WindowClass.expanded: AppBottomSheet.sideExpanded,
};

/// Сцена: затемнённое окно и панель справа на всю высоту.
Widget sideScene(WindowClass wc) => Stack(
  children: <Widget>[
    Positioned.fill(child: ColoredBox(color: DsColors.lightB.overlay)),
    Align(
      alignment: AlignmentDirectional.centerEnd,
      child: AppBottomSheet(
        key: const ValueKey<String>('side-sheet'),
        variant: AppBottomSheetVariant.side,
        width: sideWidths[wc],
        title: 'Фильтры заказов',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final String row in <String>['Статус', 'Период', 'Клиент', 'Способ оплаты', 'Оплата'])
              SizedBox(height: 48, child: Align(alignment: Alignment.centerLeft, child: Text(row))),
          ],
        ),
        footer: AppButton(label: 'Применить', expand: true, onPressed: () {}),
      ),
    ),
  ],
);

void main() {
  for (final WindowClass wc in sideWidths.keys) {
    final Size size = goldenWindows[wc]!;
    unawaited(
      goldenTest(
        'AppBottomSheet.side ${sideWidths[wc]!.toInt()} · ${wc.name}',
        fileName: 'ds_bottom_sheet_side_${wc.name}',
        constraints: BoxConstraints.tight(size),
        builder: () => GoldenWindow(size: size, fixedHeight: true, child: sideScene(wc)),
      ),
    );

    testWidgets('AppBottomSheet.side · ${wc.name}: ширина ${sideWidths[wc]!.toInt()}, без ручки, справа', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('ru'),
          home: Scaffold(body: sideScene(wc)),
        ),
      );
      final Rect r = tester.getRect(find.byKey(const ValueKey<String>('side-sheet')));
      expect(r.width, sideWidths[wc]);
      expect(r.right, size.width);
      expect(r.height, size.height);
    });
  }
}
