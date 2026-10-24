// Общая поддержка тестов дизайн-системы (RM-C-003): локальная загрузка Inter и обёртки.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';

/// Файлы Inter, которые регистрирует семейство `Inter` (статические веса 400/500/600/700).
const List<String> interStaticFiles = <String>[
  'assets/fonts/Inter/Inter-Regular.ttf',
  'assets/fonts/Inter/Inter-Medium.ttf',
  'assets/fonts/Inter/Inter-SemiBold.ttf',
  'assets/fonts/Inter/Inter-Bold.ttf',
];

bool _interLoaded = false;

/// Загружает Inter из локальных файлов `assets/fonts/Inter` (без сети и без FontManifest:
/// секция `fonts:` в pubspec — запрос к владельцу FE, см. NOTES RM-C-003).
Future<void> loadInterFont() async {
  if (_interLoaded) {
    return;
  }
  final FontLoader loader = FontLoader('Inter');
  for (final String path in interStaticFiles) {
    final Uint8List bytes = File(path).readAsBytesSync();
    loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
  _interLoaded = true;
}

/// Минимальное приложение для widget-тестов: тема B, локаль `ru`, размер окна [size].
Future<void> pumpDs(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(1280, 800),
  bool disableAnimations = true,
  bool scroll = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      debugShowCheckedModeBanner: false,
      builder: (BuildContext context, Widget? app) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
        child: app!,
      ),
      home: Scaffold(
        body: scroll ? SingleChildScrollView(padding: const EdgeInsets.all(16), child: child) : child,
      ),
    ),
  );
  await tester.pump();
}
