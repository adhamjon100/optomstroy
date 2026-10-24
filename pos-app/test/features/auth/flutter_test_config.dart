// Конфигурация тестов test/features/auth/** (RM-D-007): та же, что у test/golden
// (RM-C-003) — Inter из локальных assets/fonts/Inter, alchemist: CI-эталоны (`goldens/ci/`,
// текст блоками) на любой ОС, платформенные (`goldens/windows/`) — только на Windows.
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

import '../../design_system/ds_test_support.dart';

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
