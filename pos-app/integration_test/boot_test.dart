// RM-C-014: интеграционная сборка этапа C (boot-тест).
//
// Приложение стартует настоящим bootstrap() → Splash (SCR-00) → заглушка «нет сессии» (SCR-01)
// → GET /health к pos-api тестового контура. Адрес — `--dart-define=API_BASE_URL=…/api/v1`.
//
// Локально (Windows, без Docker):
//   cd pos-api && npm run build && node scripts/local-stack.mjs serve        # PostgreSQL 17 + migrate + seed + API :3000
//   cd pos-app && flutter test integration_test/boot_test.dart -d windows \
//       --dart-define=API_BASE_URL=http://127.0.0.1:3000/api/v1 --dart-define=ENV=dev --dart-define-from-file=env/local.json
// В CI — против infra/compose.test.yml (pos-proxy, RM-C-012): API_BASE_URL=https://<контур>/api/v1.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:optomstroy/app/bootstrap.dart';
import 'package:optomstroy/core/config/app_data_directory.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/design_system/components/env_banner.dart';
import 'package:optomstroy/features/auth/presentation/screens/no_session_screen.dart';
import 'package:optomstroy/features/splash/presentation/screens/splash_screen.dart';

/// Ждёт появления [finder], прокачивая кадры; падает по таймауту.
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail('не дождались ${finder.describeMatch(Plurality.one)} за ${timeout.inSeconds} с');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Ждёт исчезновения [finder] (окончание перехода между экранами).
Future<void> pumpUntilGone(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (finder.evaluate().isNotEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail('${finder.describeMatch(Plurality.one)} не исчез за ${timeout.inSeconds} с');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Данные приложения — в APP_DATA_DIR из env/local.json (машина разработки, вне git; не %APPDATA% на C:), до
  // первого обращения к ним. Без APP_DATA_DIR — каталог ОС.
  AppDataDirectory.apply(AppConfig.fromEnvironment());

  testWidgets('boot: Splash → «нет сессии» → GET /health с тестового контура', (tester) async {
    // Восстановление сессии управляется тестом: так Splash гарантированно виден до перехода.
    final restore = Completer<SessionStatus>();
    await bootstrap(overrides: [sessionStatusProvider.overrideWith((ref) => restore.future)]);
    await tester.pump();

    // 1. Splash (SCR-00).
    await pumpUntilFound(tester, find.byKey(SplashScreen.screenKey));
    expect(find.byKey(NoSessionScreen.screenKey), findsNothing);

    // 2. Сессии нет → authGuard → заглушка «нет сессии» (SCR-01).
    restore.complete(SessionStatus.unauthenticated);
    await pumpUntilFound(tester, find.byKey(NoSessionScreen.screenKey));
    await pumpUntilGone(tester, find.byKey(SplashScreen.screenKey));

    // 3. GET /health к локальному/тестовому pos-api.
    await pumpUntilFound(
      tester,
      find.byWidgetPredicate((w) => w.key == NoSessionScreen.healthOkKey || w.key == NoSessionScreen.healthDownKey),
    );
    final container = ProviderScope.containerOf(tester.element(find.byKey(NoSessionScreen.screenKey)));
    final report = await container.read(backendHealthReportProvider.future);
    final config = container.read(appConfigProvider);
    debugPrint('boot_test: API_BASE_URL=${config.apiBaseUrl} → $report');

    expect(report.httpStatus, 200, reason: 'GET /health → 200 (pos-api запущен?)');
    expect(report.ok, isTrue, reason: 'тело {status: ok}');
    expect(report.requestId, isNotNull, reason: 'pos-api возвращает X-Request-Id (RM-C-010)');
    expect(find.byKey(NoSessionScreen.healthOkKey), findsOneWidget);
    expect(find.byKey(NoSessionScreen.healthDownKey), findsNothing);

    // 4. Вне prod над приложением — маркер тестовых данных EnvBanner (RM-C-008; ревью C-MJ-07).
    expect(find.byKey(EnvBanner.bannerKey), config.isProd ? findsNothing : findsOneWidget);
  });
}
