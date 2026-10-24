// Golden SCR-17 (RM-E-010, D-18): сканирование (видоискатель, подсказка, «Ввести вручную», «Серия»),
// нет разрешения камеры (UI-17-009) — compact/medium; Windows без камеры (HID-подсказка) — expanded;
// раздел «Сканер» для SCR-42 — expanded. Палитра B, reduce motion (статичная линия-подсказка).
//
// Обновить эталоны: flutter test test/features/scan/golden --update-goldens
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/hardware/hardware_providers.dart';
import 'package:optomstroy/core/hardware/scanner_settings_store.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/scan/presentation/scanner_settings_section.dart';
import 'package:optomstroy/features/scan/presentation/screens/scan_screen.dart';
import 'package:optomstroy/features/scan/scan_providers.dart';

import '../support/scan_fakes.dart';

const Map<String, Size> _windows = <String, Size>{
  'compact': Size(360, 760),
  'medium': Size(800, 900),
  'expanded': Size(1280, 800),
};

Widget _app(Size size, Widget screen, List<Override> overrides) => SizedBox(
  width: size.width,
  height: size.height,
  child: ProviderScope(
    overrides: <Override>[
      scanBarcodeLookupProvider.overrideWithValue(FakeScanLookup()),
      scannerSettingsStoreProvider.overrideWithValue(MemoryScannerSettingsStore()),
      ...overrides,
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      debugShowCheckedModeBanner: false,
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(size: size, disableAnimations: true, padding: EdgeInsets.zero),
        child: child!,
      ),
      home: screen,
    ),
  ),
);

List<Override> _camera(CameraStatus status) => <Override>[
  cameraScannerSupportedProvider.overrideWithValue(true),
  barcodeCameraFactoryProvider.overrideWithValue(
    ({required bool includeQr}) => FakeBarcodeCamera(initial: status, startStatus: status),
  ),
];

void main() {
  setUpAll(() => EditableText.debugDeterministicCursor = true);
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  final Map<String, (Widget, List<Override>, List<String>)> scenes = <String, (Widget, List<Override>, List<String>)>{
    'scr17_scanning': (const ScanScreen(mode: 'search'), _camera(CameraStatus.running), <String>['compact', 'medium']),
    'scr17_no_permission': (
      const ScanScreen(mode: 'search'),
      _camera(CameraStatus.permissionDenied),
      <String>['compact', 'medium'],
    ),
    'scr17_windows_hid': (
      const ScanScreen(mode: 'search'),
      <Override>[cameraScannerSupportedProvider.overrideWithValue(false)],
      <String>['expanded'],
    ),
    'scr42_scanner_section': (
      const Scaffold(
        body: SingleChildScrollView(
          padding: EdgeInsets.all(24),
          child: SizedBox(width: 560, child: ScannerSettingsSection()),
        ),
      ),
      <Override>[cameraScannerSupportedProvider.overrideWithValue(false)],
      <String>['expanded'],
    ),
  };

  for (final MapEntry<String, (Widget, List<Override>, List<String>)> scene in scenes.entries) {
    for (final String w in scene.value.$3) {
      final Size size = _windows[w]!;
      unawaited(
        goldenTest(
          '${scene.key} · $w',
          fileName: 'scan_${scene.key}_$w',
          constraints: BoxConstraints.tight(size),
          builder: () => _app(size, scene.value.$1, scene.value.$2),
        ),
      );
    }
  }
}
