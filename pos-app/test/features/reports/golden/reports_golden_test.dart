// RM-G-008 (golden): SCR-48 «Отчёты руководителя» на трёх брейкпоинтах compact / medium / expanded (03 §7.2; D-18 —
// эталоны Windows), палитра B: три карточки (продажи, долги со снимком 1С, QR-сверка) и таблица продаж по дням.
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

Widget _app(Size size) => SizedBox(
  width: size.width,
  height: size.height,
  child: ProviderScope(
    overrides: [
      reportsRepositoryProvider.overrideWithValue(FakeReportsRepository()),
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
      home: const ReportsScreen(report: 'sales'),
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
}
