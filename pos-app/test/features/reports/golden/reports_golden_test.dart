// RM-G-008 (golden): SCR-48 «Отчёты руководителя» на трёх брейкпоинтах compact / medium / expanded (03 §7.2; D-18 —
// эталоны Windows), палитра B: три карточки (продажи, долги со снимком 1С, QR-сверка) и таблица продаж по дням.
// QR-сверка с зачислениями по неизвестному референсу (UI-48-017, UI-48-018; 15 ADR-123) — compact и expanded.
//
// Обновить эталоны: flutter test test/features/reports/golden --update-goldens
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/reports/presentation/screens/reports_screen.dart';
import 'package:optomstroy/features/reports/reports_providers.dart';

import '../support/fake_reports_repository.dart';

const Map<String, Size> _windows = <String, Size>{
  'compact': Size(360, 760),
  'medium': Size(800, 900),
  'expanded': Size(1280, 800),
};

Widget _app(Size size, {String report = 'sales', bool unknownOperations = false}) => SizedBox(
  width: size.width,
  height: size.height,
  child: ProviderScope(
    overrides: [
      reportsRepositoryProvider.overrideWithValue(FakeReportsRepository(unknownOperations: unknownOperations)),
      clockProvider.overrideWithValue(FixedClock(r0)),
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
      home: ReportsScreen(report: report),
    ),
  ),
);

void main() {
  for (final MapEntry<String, Size> w in _windows.entries) {
    unawaited(
      goldenTest(
        'SCR-48 owner · ${w.key}',
        fileName: 'reports_scr48_${w.key}',
        constraints: BoxConstraints.tight(w.value),
        builder: () => _app(w.value),
      ),
    );
  }
  // Высокие окна: блок «Зачисления по неизвестному референсу» стоит под таблицей QR и должен попасть в снимок.
  const Map<String, Size> qrWindows = <String, Size>{'compact': Size(360, 1700), 'expanded': Size(1280, 1100)};
  for (final MapEntry<String, Size> e in qrWindows.entries) {
    final String w = e.key;
    final Size size = e.value;
    unawaited(
      goldenTest(
        'SCR-48 owner · QR · неизвестный референс · $w',
        fileName: 'reports_scr48_qr_unknown_$w',
        constraints: BoxConstraints.tight(size),
        builder: () => _app(size, report: 'qr', unknownOperations: true),
      ),
    );
  }
}
