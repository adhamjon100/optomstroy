// Подключённые виджеты core/sync (RM-E-009): `ConnectedOfflineBanner` (офлайн с возрастом данных → «Сеть
// восстановлена…» 3 с), `ConnectedSyncIndicator` (вариант по свежести кэша), `CatalogInitialLoadBanner`
// (NFR-PERF-006: «Загружаем каталог… N %»); семантика компонентов design_system.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart';
import 'package:optomstroy/design_system/components/sync_indicator.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/sync_status/presentation/widgets/sync_connected_widgets.dart';

final DateTime _now = DateTime.utc(2026, 10, 19, 10);

Future<AppLocalizations> _pump(WidgetTester tester, Widget child, List<Override> overrides) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, app) =>
            MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: app!),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
  return AppLocalizations.of(tester.element(find.byType(Scaffold)));
}

void main() {
  testWidgets('ConnectedOfflineBanner: офлайн с меткой данных → онлайн: «Сеть восстановлена…» 3 с → скрыт', (
    tester,
  ) async {
    final status = StreamController<OnlineStatus>.broadcast();
    addTearDown(status.close);
    var online = OnlineStatus.offline;
    final l10n = await _pump(tester, const ConnectedOfflineBanner(), [
      onlineStatusProvider.overrideWith((ref) => status.stream),
      catalogFreshnessProvider.overrideWith(
        (ref) => DataFreshness(
          online: ref.watch(onlineStatusProvider).value ?? online,
          now: _now,
          asOf: _now.subtract(const Duration(minutes: 20)),
        ),
      ),
    ]);
    status.add(OnlineStatus.offline);
    await tester.pump();
    expect(find.byKey(OfflineBanner.bannerKey), findsOneWidget);
    expect(find.textContaining('Нет сети'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);

    online = OnlineStatus.online;
    status.add(OnlineStatus.online);
    await tester.pump();
    expect(find.text(l10n.ds_back_online), findsOneWidget);
    await tester.pump(ConnectedOfflineBanner.backOnlineFor + const Duration(milliseconds: 10));
    expect(find.byKey(OfflineBanner.bannerKey), findsNothing);
  });

  testWidgets('ConnectedSyncIndicator: устаревшие цены → stale; тап — обработчик', (tester) async {
    var taps = 0;
    await _pump(tester, ConnectedSyncIndicator(onTap: () => taps++), [
      syncIndicatorProvider.overrideWithValue(SyncIndicatorInfo(status: SyncIndicatorStatus.stale, time: _now)),
    ]);
    final indicator = tester.widget<SyncIndicator>(find.byType(SyncIndicator));
    expect(indicator.variant, SyncIndicatorVariant.stale);
    await tester.tap(find.byType(SyncIndicator));
    expect(taps, 1);
    expect(
      tester.getSize(find.byKey(SyncIndicator.tapTargetKey)).height,
      greaterThanOrEqualTo(44),
      reason: 'touch target',
    );
  });

  testWidgets('ConnectedSyncIndicator(adaptive): в норме — только иконка с тултипом, при проблеме — с текстом', (
    tester,
  ) async {
    for (final (SyncIndicatorStatus status, bool iconOnly) in <(SyncIndicatorStatus, bool)>[
      (SyncIndicatorStatus.ok, true),
      (SyncIndicatorStatus.syncing, true),
      (SyncIndicatorStatus.never, true),
      (SyncIndicatorStatus.stale, false),
      (SyncIndicatorStatus.error, false),
      (SyncIndicatorStatus.offline, false),
    ]) {
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, ConnectedSyncIndicator(adaptive: true, onTap: () {}), [
        syncIndicatorProvider.overrideWithValue(SyncIndicatorInfo(status: status, time: _now)),
      ]);
      final indicator = tester.widget<SyncIndicator>(find.byType(SyncIndicator));
      expect(indicator.compact, iconOnly, reason: status.name);
      expect(indicator.tooltip != null, iconOnly, reason: '${status.name}: подпись — в тултипе');
    }
  });

  testWidgets('SyncIndicator syncing только иконкой при «Уменьшить анимации»: цвет не primaryText (A11Y-004, §24.1)', (
    tester,
  ) async {
    // `_pump` включает disableAnimations: вращения нет — состояние передают тултип и Semantics, а не оранжевый цвет.
    await _pump(tester, ConnectedSyncIndicator(adaptive: true, onTap: () {}), [
      syncIndicatorProvider.overrideWithValue(SyncIndicatorInfo(status: SyncIndicatorStatus.syncing, time: _now)),
    ]);
    final indicator = find.byType(SyncIndicator);
    expect(tester.widget<SyncIndicator>(indicator).compact, isTrue);
    expect(find.descendant(of: indicator, matching: find.byType(RotationTransition)), findsNothing);
    final colors = tester.element(indicator).colors;
    final icon = tester.widget<Icon>(find.descendant(of: indicator, matching: find.byType(Icon)));
    expect(icon.color, isNot(colors.primaryText));
    expect(icon.color, colors.textSecondary);
    expect(
      SyncIndicator.colorOf(colors, SyncIndicatorVariant.syncing),
      colors.primaryText,
      reason: 'с подписью оранжевый — украшение',
    );
  });

  testWidgets('ConnectedSyncIndicator в шапке ветки /catalog: тап → SCR-43 поверх, «Назад» → каталог (AC-UI-43-015)', (
    tester,
  ) async {
    // Топология графа приложения: ветка `/catalog` в StatefulShellRoute, `/sync` — корневой маршрут вне оболочки.
    final router = GoRouter(
      initialLocation: '/catalog',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => Scaffold(body: shell),
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/catalog',
                  builder: (context, state) => const Scaffold(
                    key: Key('scr-10'),
                    body: Center(child: ConnectedSyncIndicator()),
                  ),
                ),
              ],
            ),
          ],
        ),
        GoRoute(
          path: '/sync',
          builder: (context, state) => Scaffold(
            key: const Key('scr-43'),
            appBar: AppBar(title: const Text('SCR-43')),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncIndicatorProvider.overrideWithValue(SyncIndicatorInfo(status: SyncIndicatorStatus.ok, time: _now)),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light(),
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(SyncIndicator));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('scr-43')), findsOneWidget);
    expect(router.canPop(), isTrue, reason: 'SCR-43 открыт поверх каталога, а не вместо стека');
    expect(find.byType(BackButton), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('scr-10')), findsOneWidget);
    expect(router.routerDelegate.currentConfiguration.uri.path, '/catalog');
  });

  testWidgets('ConnectedSyncIndicator: compact — только иконка, expanded — иконка и время (02 SCR-10.3 A6)', (
    tester,
  ) async {
    final overrides = [
      syncIndicatorProvider.overrideWithValue(SyncIndicatorInfo(status: SyncIndicatorStatus.ok, time: _now)),
    ];
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pump(tester, const ConnectedSyncIndicator(), overrides);
    expect(tester.widget<SyncIndicator>(find.byType(SyncIndicator)).compact, isTrue);

    tester.view.physicalSize = const Size(1366, 768);
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, const ConnectedSyncIndicator(), overrides);
    expect(tester.widget<SyncIndicator>(find.byType(SyncIndicator)).compact, isFalse);
  });

  testWidgets('CatalogInitialLoadBanner: процент первичной загрузки; скрыт вне загрузки', (tester) async {
    final load = StreamController<CatalogLoadState>.broadcast();
    addTearDown(load.close);
    final l10n = await _pump(tester, const CatalogInitialLoadBanner(), [
      catalogLoadStateProvider.overrideWith((ref) => load.stream),
    ]);
    expect(find.byKey(CatalogInitialLoadBanner.bannerKey), findsNothing);
    load.add(
      const CatalogLoadState(
        phase: CatalogLoadPhase.initialLoading,
        totalEntities: 11,
        completedEntities: {'units', 'categories', 'warehouses', 'price_lists', 'products'},
      ),
    );
    await tester.pump();
    await tester.pump();
    final percent = const CatalogLoadState(
      phase: CatalogLoadPhase.initialLoading,
      totalEntities: 11,
      completedEntities: {'units', 'categories', 'warehouses', 'price_lists', 'products'},
    ).percent;
    expect(find.text(l10n.catalog_initial_loading('$percent')), findsWidgets);
    load.add(const CatalogLoadState(phase: CatalogLoadPhase.ready, fullyLoaded: true));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(CatalogInitialLoadBanner.bannerKey), findsNothing);
  });

  testWidgets('SyncIndicator: семантика и compact-точка; inline — «данные от»', (tester) async {
    final l10n = await _pump(
      tester,
      Column(
        children: <Widget>[
          const SyncIndicator(variant: SyncIndicatorVariant.error),
          const SyncIndicator(variant: SyncIndicatorVariant.offline, compact: true),
          SyncIndicator.inline(time: _now, stale: true, now: _now),
        ],
      ),
      const [],
    );
    expect(find.bySemanticsLabel(l10n.ds_sync_error), findsOneWidget);
    expect(find.bySemanticsLabel(l10n.ds_sync_offline), findsOneWidget);
    expect(find.textContaining(l10n.ds_data_as_of('').trim()), findsOneWidget);
    expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);
  });
}
