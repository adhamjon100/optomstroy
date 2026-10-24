// Конфигурация golden-тестов (alchemist) для test/golden/** (RM-C-003).
//
// * CI-эталоны (`goldens/ci/`, текст — блоками) сравниваются на любой ОС — их проверяет CI.
// * Платформенные эталоны с настоящим Inter (`goldens/windows/`) — только на Windows
//   (рендер текста зависит от ОС); для Linux-раннера эталоны создаются отдельно (RM-C-011).
// Inter загружается из локальных assets/fonts/Inter (без сети).
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

import '../design_system/ds_test_support.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadInterFont();
  return AlchemistConfig.runWithConfig(
    config: AlchemistConfig(
      theme: AppTheme.light(),
      goldenTestTheme: GoldenTestTheme(
        backgroundColor: DsColors.lightB.background,
        borderColor: DsColors.lightB.border,
        nameTextStyle: const TextStyle(fontSize: 12, fontFamily: 'Inter'),
      ),
      platformGoldensConfig: PlatformGoldensConfig(platforms: <HostPlatform>{HostPlatform.windows}),
      ciGoldensConfig: const CiGoldensConfig(),
    ),
    run: testMain,
  );
}
