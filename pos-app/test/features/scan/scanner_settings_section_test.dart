// Раздел «Сканер» для SCR-42: окончание скана и порог меняют настройки сервиса; тест HID-сканера
// в поле (найден / обрыв без окончания).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/hardware/hardware_providers.dart';
import 'package:optomstroy/core/hardware/scanner_settings_store.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/scan/domain/scan_lookup.dart';
import 'package:optomstroy/features/scan/presentation/scanner_settings_section.dart';
import 'package:optomstroy/features/scan/scan_providers.dart';

import 'support/scan_fakes.dart';

LogicalKeyboardKey _digit(String ch) => LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + int.parse(ch));

void main() {
  late Duration now;
  late MemoryScannerSettingsStore store;
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester) async {
    now = Duration.zero;
    store = MemoryScannerSettingsStore();
    final lookup = FakeScanLookup()..online[eanFound] = const Success<ScanLookupResult>(frap);
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(800, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          scannerSettingsStoreProvider.overrideWithValue(store),
          scannerWedgeServiceProvider.overrideWith((ref) {
            final s = ScannerWedgeService(config: ref.read(scannerConfigProvider), now: () => now);
            ref
              ..listen<ScannerWedgeConfig>(scannerConfigProvider, (_, next) => s.config = next)
              ..onDispose(s.dispose);
            return s;
          }),
          scanBarcodeLookupProvider.overrideWithValue(lookup),
          cameraScannerSupportedProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: SingleChildScrollView(padding: EdgeInsets.all(16), child: ScannerSettingsSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    container = ProviderScope.containerOf(tester.element(find.byType(ScannerSettingsSection)));
  }

  Future<void> typeFast(WidgetTester tester, String code) async {
    for (final ch in code.split('')) {
      now += const Duration(milliseconds: 8);
      await tester.sendKeyDownEvent(_digit(ch), character: ch);
      await tester.sendKeyUpEvent(_digit(ch));
    }
  }

  testWidgets('выбор окончания Tab сохраняется и применяется к сервису', (tester) async {
    await pump(tester);
    expect(find.text(ru.settings_section_scanner), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('scanner-suffix')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(ru.settings_scanner_suffix_tab).last);
    await tester.pumpAndSettle();

    expect(container.read(scannerConfigProvider).suffix, ScannerSuffix.tab);
    expect(container.read(scannerWedgeServiceProvider).config.suffix, ScannerSuffix.tab);
    expect((await store.load()).suffix, ScannerSuffix.tab);
  });

  testWidgets('порог 80 мс сохраняется', (tester) async {
    await pump(tester);
    await container.read(scannerConfigProvider.notifier).setInterKeyThresholdMs(80);
    await tester.pump();
    expect(container.read(scannerWedgeServiceProvider).config.interKeyThreshold, const Duration(milliseconds: 80));
    expect((await store.load()).interKeyThreshold, const Duration(milliseconds: 80));
  });

  testWidgets('тест сканера: скан в поле → «Найден: … · арт. …»', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey<String>('scanner-test-field')));
    await tester.pump();
    await typeFast(tester, eanFound);
    now += const Duration(milliseconds: 8);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text(ru.settings_scanner_test_found(frap.productName, 'F4252')), findsOneWidget);
  });

  testWidgets('тест сканера: окончание не пришло за 300 мс → подсказка «Сканер не отправил окончание»', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey<String>('scanner-test-field')));
    await tester.pump();
    await typeFast(tester, eanFound);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(find.text(ru.settings_scanner_no_suffix), findsOneWidget);
  });
}
