// SCR-00 Splash (02 SCR-00.13): решение по таблице §6, переход в max(решение, 600 мс),
// при reduce-motion — сразу; индикатор только после 400 мс, подпись — после 2 с;
// сбой инициализации после автоповтора → «Не удалось запустить приложение».
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/splash/presentation/notifiers/splash_decision.dart';
import 'package:optomstroy/features/splash/presentation/screens/splash_screen.dart';
import 'package:optomstroy/features/splash/presentation/widgets/splash_logo.dart';

import '../support/fakes.dart';

final class _Splash {
  late GoRouter router;

  String get location => router.state.uri.toString();

  Future<void> pump(WidgetTester tester, List<Override> overrides, {bool reduceMotion = false}) async {
    router = GoRouter(
      initialLocation: '/splash',
      routes: <RouteBase>[
        GoRoute(path: '/splash', builder: (BuildContext c, GoRouterState s) => const SplashScreen()),
        for (final SplashDestination d in SplashDestination.values)
          GoRoute(
            path: Uri.parse(d.location).path,
            builder: (BuildContext c, GoRouterState s) => Scaffold(body: Text(d.name, key: destinationKey(d.name))),
          ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp.router(
          routerConfig: router,
          theme: AppTheme.light(),
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
            child: child!,
          ),
        ),
      ),
    );
  }
}

Override _snapshot(SplashSnapshot s) => splashSnapshotProvider.overrideWith((Ref ref) async => s);

void main() {
  late AppLocalizations l10n;

  setUpAll(() async => l10n = await ru());

  group('T-AUTH-031: decideSplash (02 SCR-00.6)', () {
    test('нет refresh → SCR-01', () => expect(decideSplash(SplashSnapshot.guest), SplashDestination.phone));
    test('pending_activation → SCR-07', () {
      expect(
        decideSplash(const SplashSnapshot(hasSession: true, kind: SplashUserKind.customer, pendingActivation: true)),
        SplashDestination.pendingActivation,
      );
    });
    test('staff → SCR-08 cold (D-48), даже без PIN в кэше', () {
      expect(
        decideSplash(const SplashSnapshot(hasSession: true, kind: SplashUserKind.staff)),
        SplashDestination.unlock,
      );
    });
    test('customer с PIN или биометрией → SCR-08; без них → SCR-50', () {
      expect(
        decideSplash(const SplashSnapshot(hasSession: true, kind: SplashUserKind.customer, pinSet: true)),
        SplashDestination.unlock,
      );
      expect(
        decideSplash(const SplashSnapshot(hasSession: true, kind: SplashUserKind.customer, biometricEnabled: true)),
        SplashDestination.unlock,
      );
      expect(
        decideSplash(const SplashSnapshot(hasSession: true, kind: SplashUserKind.customer)),
        SplashDestination.customerHome,
      );
    });
    test('сессия есть, кэша профиля нет → SCR-08 cold (безопасный вариант)', () {
      expect(decideSplash(const SplashSnapshot(hasSession: true)), SplashDestination.unlock);
    });
  });

  testWidgets('гость: логотип 600 мс, затем SCR-01; индикатора нет (решение ≤ 400 мс)', (WidgetTester tester) async {
    final _Splash s = _Splash();
    await s.pump(tester, <Override>[_snapshot(SplashSnapshot.guest)]);
    expect(find.byKey(SplashScreen.screenKey), findsOneWidget);
    expect(find.bySemanticsLabel(l10n.splash_logo_a11y), findsOneWidget);
    expect(find.byKey(SplashLogo.wordmarkKey), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    expect(s.location, '/splash');
    expect(find.byKey(SplashScreen.progressKey), findsNothing);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(s.location, SplashDestination.phone.location);
  });

  testWidgets('staff с сессией → SCR-08 cold', (WidgetTester tester) async {
    final _Splash s = _Splash();
    await s.pump(tester, <Override>[_snapshot(const SplashSnapshot(hasSession: true, kind: SplashUserKind.staff))]);
    await tester.pump(SplashScreen.logoDuration);
    await tester.pumpAndSettle();
    expect(s.location, SplashDestination.unlock.location);
  });

  testWidgets('customer без PIN → SCR-50 (каталог-заглушка)', (WidgetTester tester) async {
    final _Splash s = _Splash();
    await s.pump(tester, <Override>[_snapshot(const SplashSnapshot(hasSession: true, kind: SplashUserKind.customer))]);
    await tester.pump(SplashScreen.logoDuration);
    await tester.pumpAndSettle();
    expect(s.location, SplashDestination.customerHome.location);
  });

  testWidgets('reduce-motion: переход сразу после решения, без ожидания 600 мс', (WidgetTester tester) async {
    final _Splash s = _Splash();
    await s.pump(tester, <Override>[_snapshot(SplashSnapshot.guest)], reduceMotion: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(s.location, SplashDestination.phone.location);
  });

  testWidgets('долгая проверка: индикатор в 400 мс, «Проверяем сессию…» после 2 с', (WidgetTester tester) async {
    final Completer<SplashSnapshot> gate = Completer<SplashSnapshot>();
    final _Splash s = _Splash();
    await s.pump(tester, <Override>[splashSnapshotProvider.overrideWith((Ref ref) => gate.future)]);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(SplashScreen.progressKey), findsNothing);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(SplashScreen.progressKey), findsOneWidget);
    expect(find.text(l10n.splash_status_checking), findsNothing);
    await tester.pump(const Duration(milliseconds: 1600));
    expect(find.text(l10n.splash_status_checking), findsOneWidget);
    gate.complete(SplashSnapshot.guest);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(s.location, SplashDestination.phone.location);
  });

  testWidgets('сбой инициализации: автоповтор, затем ErrorState «Не удалось запустить приложение»', (
    WidgetTester tester,
  ) async {
    int calls = 0;
    final _Splash s = _Splash();
    await s.pump(tester, <Override>[
      splashSnapshotProvider.overrideWith((Ref ref) async {
        calls++;
        if (calls <= 2) {
          throw StateError('secure storage');
        }
        return SplashSnapshot.guest;
      }),
    ]);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(calls, 2, reason: 'один автоповтор');
    expect(find.byKey(SplashScreen.initErrorKey), findsOneWidget);
    expect(find.text(l10n.splash_init_error_title), findsOneWidget);
    await tester.tap(find.text(l10n.ds_button_retry));
    await tester.pump();
    await tester.pump(SplashScreen.logoDuration);
    await tester.pumpAndSettle();
    expect(calls, 3);
    expect(s.location, SplashDestination.phone.location);
  });
}
