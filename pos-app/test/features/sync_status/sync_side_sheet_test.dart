// SCR-43 на expanded (02 SCR-43.2 «Expanded», SCR-43.6; FIX-EF-08): `SyncIndicator` в шапке у seller / cashier /
// senior_seller открывает side sheet 480 поверх текущего экрана без смены URL (зоны A, B, C, без журнала);
// крестик закрывает, «Подробнее» → полный экран `/sync`. `admin` и узкие окна — полный экран (push).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/components/sync_indicator.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/sync_status/presentation/notifiers/sync_status_controller.dart';
import 'package:optomstroy/features/sync_status/presentation/screens/sync_status_screen.dart';
import 'package:optomstroy/features/sync_status/presentation/widgets/sync_connected_widgets.dart';
import 'package:optomstroy/features/sync_status/presentation/widgets/sync_side_sheet.dart';

import 'sync_status_screen_test.dart' show FakeSyncStatusPort;

final DateTime _now = DateTime.utc(2026, 10, 19, 9, 42);

Future<GoRouter> _pump(WidgetTester tester, RoleCode role, {Size size = const Size(1366, 768)}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size;
  addTearDown(tester.view.reset);
  final GoRouter router = GoRouter(
    initialLocation: '/catalog',
    routes: <RouteBase>[
      GoRoute(
        path: '/catalog',
        builder: (BuildContext context, GoRouterState state) => const Scaffold(
          key: Key('scr-10'),
          body: Align(alignment: Alignment.topRight, child: ConnectedSyncIndicator()),
        ),
      ),
      GoRoute(
        path: '/sync',
        builder: (BuildContext context, GoRouterState state) => const SyncStatusScreen(key: Key('scr-43-page')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        syncIndicatorProvider.overrideWithValue(SyncIndicatorInfo(status: SyncIndicatorStatus.ok, time: _now)),
        syncStatusPortProvider.overrideWithValue(FakeSyncStatusPort()),
        syncViewerRoleProvider.overrideWithValue(role),
        onlineStatusProvider.overrideWith((ref) => Stream<OnlineStatus>.value(OnlineStatus.online)),
        catalogFreshnessProvider.overrideWithValue(
          DataFreshness(online: OnlineStatus.online, now: _now, asOf: _now.subtract(const Duration(minutes: 30))),
        ),
        localSyncStatesProvider.overrideWith((ref) => Stream<List<LocalEntitySync>>.value(const <LocalEntitySync>[])),
        syncNowProvider.overrideWith((ref) => Stream<DateTime>.value(_now)),
        clockProvider.overrideWithValue(FixedClock(_now)),
        syncStatusPollIntervalsProvider.overrideWithValue(null),
      ],
      child: MaterialApp.router(
        theme: AppTheme.light(),
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
        builder: (BuildContext context, Widget? child) =>
            MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  String path(GoRouter r) => r.routerDelegate.currentConfiguration.uri.path;

  test('applies: только expanded/large и seller / cashier / senior_seller', () {
    expect(SyncStatusSideSheet.applies(WindowClass.expanded, RoleCode.seller), isTrue);
    expect(SyncStatusSideSheet.applies(WindowClass.large, RoleCode.cashier), isTrue);
    expect(SyncStatusSideSheet.applies(WindowClass.expanded, RoleCode.seniorSeller), isTrue);
    expect(SyncStatusSideSheet.applies(WindowClass.expanded, RoleCode.admin), isFalse);
    expect(SyncStatusSideSheet.applies(WindowClass.expanded, RoleCode.owner), isFalse);
    expect(SyncStatusSideSheet.applies(WindowClass.medium, RoleCode.seller), isFalse);
    expect(SyncStatusSideSheet.applies(WindowClass.expanded, null), isFalse);
  });

  testWidgets('senior_seller, expanded: side sheet 480 поверх, URL не меняется; крестик закрывает', (
    WidgetTester tester,
  ) async {
    final GoRouter router = await _pump(tester, RoleCode.seniorSeller);
    await tester.tap(find.byType(SyncIndicator));
    await tester.pumpAndSettle();

    final Finder sheet = find.byKey(SyncStatusSideSheet.sheetKey);
    expect(sheet, findsOneWidget);
    expect(tester.getSize(sheet).width, SyncStatusSideSheet.width);
    expect(tester.getRect(sheet).right, 1366, reason: 'справа');
    expect(find.byKey(const Key('scr-10')), findsOneWidget, reason: 'исходный экран под панелью');
    expect(path(router), '/catalog');
    final SyncStatusScreen screen = tester.widget<SyncStatusScreen>(find.byType(SyncStatusScreen));
    expect(screen.sheet, isTrue);
    expect(find.text('Прогоны'), findsNothing, reason: 'краткий вид без журнала');

    await tester.tap(find.byKey(SyncStatusScreen.sheetCloseKey));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(path(router), '/catalog');
  });

  testWidgets('«Подробнее» → полный экран /sync, «Назад» → исходный экран', (WidgetTester tester) async {
    final GoRouter router = await _pump(tester, RoleCode.seller);
    await tester.tap(find.byType(SyncIndicator));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(SyncStatusScreen.sheetMoreKey));
    await tester.pumpAndSettle();
    expect(find.byKey(SyncStatusSideSheet.sheetKey), findsNothing);
    expect(find.byKey(const Key('scr-43-page')), findsOneWidget);
    expect(router.canPop(), isTrue, reason: 'push поверх исходного экрана');
  });

  testWidgets('admin, expanded: полный экран (push)', (WidgetTester tester) async {
    final GoRouter router = await _pump(tester, RoleCode.admin);
    await tester.tap(find.byType(SyncIndicator));
    await tester.pumpAndSettle();
    expect(find.byKey(SyncStatusSideSheet.sheetKey), findsNothing);
    expect(find.byKey(const Key('scr-43-page')), findsOneWidget);
    expect(router.canPop(), isTrue);
  });
}
