import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/app.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/features/auth/presentation/screens/no_session_screen.dart';
import 'package:optomstroy/features/splash/presentation/screens/splash_screen.dart';

import '../support/fake_backend_health.dart';

void main() {
  // Smoke-тест RM-C-002: приложение запускается и показывает Splash (SCR-00).
  testWidgets('приложение запускается до Splash', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [backendHealthProbeProvider.overrideWithValue(FakeBackendHealthProbe())],
        child: const App(),
      ),
    );

    expect(find.byKey(SplashScreen.screenKey), findsOneWidget);
    expect(find.bySemanticsLabel('Логотип Оптомстрой'), findsOneWidget);
  });

  // Пока сессия восстанавливается, остаёмся на Splash.
  testWidgets('Splash держится, пока сессия не восстановлена', (tester) async {
    final probe = FakeBackendHealthProbe();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionStatusProvider.overrideWith((ref) => Completer<SessionStatus>().future),
          backendHealthProbeProvider.overrideWithValue(probe),
        ],
        child: const App(),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(SplashScreen.screenKey), findsOneWidget);
    expect(find.byKey(NoSessionScreen.screenKey), findsNothing);
    expect(probe.calls, 0, reason: 'GET /health выполняет экран «нет сессии», не Splash');
  });

  // Нет сессии → заглушка «нет сессии» на маршруте SCR-01 → GET /health (основа RM-C-014).
  testWidgets('без сессии Splash ведёт на заглушку «нет сессии», сервер доступен', (tester) async {
    final probe = FakeBackendHealthProbe();
    await tester.pumpWidget(
      ProviderScope(overrides: [backendHealthProbeProvider.overrideWithValue(probe)], child: const App()),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(SplashScreen.screenKey), findsNothing);
    expect(find.byKey(NoSessionScreen.screenKey), findsOneWidget);
    expect(find.text('Вход по номеру телефона'), findsOneWidget);
    expect(probe.calls, 1);
    expect(find.byKey(NoSessionScreen.healthOkKey), findsOneWidget);
    expect(find.text('Сервер недоступен'), findsNothing);
  });

  testWidgets('«нет сессии»: GET /health не 200 → строка «Сервер недоступен»', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [backendHealthProbeProvider.overrideWithValue(FakeBackendHealthProbe(ok: false))],
        child: const App(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(NoSessionScreen.screenKey), findsOneWidget);
    expect(find.byKey(NoSessionScreen.healthDownKey), findsOneWidget);
    expect(find.text('Сервер недоступен'), findsOneWidget);
  });
}
