// «Готово» аварийного кода SCR-54 UI-54-014 с настоящим GoRouter (02 SCR-54.3, SCR-54.11; FLOW-043.S5–S6): переход в
// режим планшета снимает SCR-54 вместе с диалогом, и «Готово» не должно снимать страницу `/kiosk`, которую положил
// переход. Диалог закрывает только свой маршрут: `pop`, если он верхний, иначе `removeRoute`, а уже снятый не трогает
// (`TabletExitCodeDialog._done`; WP-A11 #388). Фейки `enroll_flow_test.dart` и `admin_tablets_screen_test.dart` маршрут
// не меняют, а `integration_test/kiosk_flow_test.dart` CI не запускает, поэтому случай закреплён здесь (ревью P-002
// spec-drift-15).
// Трассировка: 12 T-KIOSK-001; 10 KIOSK-002, KIOSK-003.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/admin/presentation/tablets/widgets/tablet_exit_code_dialog.dart';

const Key _openKey = ValueKey<String>('open-exit-code');

/// SCR-54 (кнопка открывает диалог кода), SCR-51 и посторонняя страница.
GoRouter _router(Future<void> Function(GoRouter router) onDone) {
  late final GoRouter router;
  router = GoRouter(
    initialLocation: '/admin/tablets',
    routes: <RouteBase>[
      GoRoute(
        path: '/admin/tablets',
        builder: (BuildContext context, GoRouterState state) => Scaffold(
          body: Builder(
            builder: (BuildContext ctx) => TextButton(
              key: _openKey,
              onPressed: () => TabletExitCodeDialog.show(ctx, code: '12345678', onDone: () => onDone(router)),
              child: const Text('SCR-54'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/kiosk',
        builder: (BuildContext context, GoRouterState state) => const Scaffold(body: Text('SCR-51')),
      ),
      GoRoute(
        path: '/other',
        builder: (BuildContext context, GoRouterState state) => const Scaffold(body: Text('OTHER')),
      ),
    ],
  );
  return router;
}

Future<GoRouter> _openDialog(WidgetTester tester, Future<void> Function(GoRouter router) onDone) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1440, 900);
  addTearDown(tester.view.reset);
  final GoRouter router = _router(onDone);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    MaterialApp.router(
      theme: AppTheme.light(),
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(_openKey));
  await tester.pumpAndSettle();
  expect(find.byType(TabletExitCodeDialog), findsOneWidget);
  return router;
}

void main() {
  group('T-KIOSK-001 UI-54-014 «Готово» с настоящим маршрутизатором', () {
    testWidgets('T-KIOSK-001: onDone уводит на /kiosk (кадр проходит до конца onDone) — /kiosk остаётся, диалога нет', (
      WidgetTester tester,
    ) async {
      final GoRouter router = await _openDialog(tester, (GoRouter r) async {
        r.go('/kiosk');
        await WidgetsBinding.instance.endOfFrame;
      });

      await tester.tap(find.byKey(TabletExitCodeDialog.doneKey));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('SCR-51'), findsOneWidget);
      expect(find.byType(TabletExitCodeDialog), findsNothing);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/kiosk');
    });

    testWidgets('T-KIOSK-001: onDone кладёт страницу над диалогом — диалог снят removeRoute, страница остаётся', (
      WidgetTester tester,
    ) async {
      await _openDialog(tester, (GoRouter r) async {
        unawaited(r.push<void>('/other'));
        await Future<void>.delayed(Duration.zero);
      });

      await tester.tap(find.byKey(TabletExitCodeDialog.doneKey));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(TabletExitCodeDialog), findsNothing);
      expect(find.text('OTHER'), findsOneWidget);
    });

    testWidgets('T-KIOSK-001: onDone без перехода — диалог закрыт pop, SCR-54 остаётся', (WidgetTester tester) async {
      final GoRouter router = await _openDialog(tester, (GoRouter r) async {});

      await tester.tap(find.byKey(TabletExitCodeDialog.doneKey));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(TabletExitCodeDialog), findsNothing);
      expect(find.text('SCR-54'), findsOneWidget);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/admin/tablets');
    });
  });
}
