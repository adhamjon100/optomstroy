// Widget-тесты секции «Принтер» SCR-42 (RM-G-008; 02 UI-42-014, UI-42-020…UI-42-022): формат и автопечать
// сохраняются сразу (optimistic) и откатываются при ошибке (`settings_save_error`); адрес/порт сетевого ESC/POS
// проверяются (`settings_printer_address_error`, `settings_printer_port_error`); «Тестовая печать» — снекбар итога.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/settings/presentation/widgets/printer_section.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

final class FakePrinterPort implements PrinterSettingsPort {
  PrinterPrefs prefs = const PrinterPrefs(format: PrinterFormat.receipt80);
  bool saveOk = true;
  String? printError;
  final List<PrinterPrefs> saved = <PrinterPrefs>[];
  int prints = 0;

  @override
  Future<PrinterPrefs> load() async => prefs;

  @override
  Future<bool> save(PrinterPrefs p) async {
    saved.add(p);
    return saveOk;
  }

  @override
  Future<String?> testPrint(PrinterPrefs p) async {
    prints++;
    return printError;
  }
}

Future<void> pump(WidgetTester tester, FakePrinterPort port) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(child: PrinterSettingsSection(port: port)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('формат A4 сохраняется сразу; ошибка сохранения — откат и снекбар', (tester) async {
    final FakePrinterPort port = FakePrinterPort();
    await pump(tester, port);
    expect(
      tester.widget<AppRadio<PrinterFormat>>(find.byKey(PrinterSettingsSection.formatKey(PrinterFormat.a4))).groupValue,
      PrinterFormat.receipt80,
    );
    await tester.tap(find.byKey(PrinterSettingsSection.formatKey(PrinterFormat.a4)));
    await tester.pumpAndSettle();
    expect(port.saved.single.format, PrinterFormat.a4);

    port.saveOk = false;
    await tester.tap(find.byKey(PrinterSettingsSection.autoPrintKey));
    await tester.pumpAndSettle();
    expect(port.saved.last.autoPrint, isTrue);
    expect(find.text(l10n.settings_save_error), findsOneWidget);
  });

  testWidgets('адрес и порт принтера проверяются', (tester) async {
    final FakePrinterPort port = FakePrinterPort();
    await pump(tester, port);
    await tester.enterText(
      find.descendant(of: find.byKey(PrinterSettingsSection.addressKey), matching: find.byType(TextField)),
      '300.1.1.1',
    );
    await tester.enterText(
      find.descendant(of: find.byKey(PrinterSettingsSection.portKey), matching: find.byType(TextField)),
      '70000',
    );
    await tester.pump();
    expect(find.text(l10n.settings_printer_address_error), findsOneWidget);
    expect(find.text(l10n.settings_printer_port_error), findsOneWidget);
    expect(PrinterSettingsSection.validAddress('192.168.1.50'), isTrue);
    expect(PrinterSettingsSection.validPort('9100'), isTrue);
  });

  testWidgets('«Тестовая печать» — снекбар успеха или ошибки с причиной', (tester) async {
    final FakePrinterPort port = FakePrinterPort();
    await pump(tester, port);
    await tester.tap(find.byKey(PrinterSettingsSection.testKey));
    await tester.pumpAndSettle();
    expect(port.prints, 1);
    expect(find.text(l10n.settings_print_test_ok), findsOneWidget);
  });
}
