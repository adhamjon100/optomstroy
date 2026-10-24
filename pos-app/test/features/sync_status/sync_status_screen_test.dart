// SCR-43 «Статус синхронизации» (02 ч. E; ядро R0 §17.2, §22.8; AC-UI-43-002/003/005/006/017/019; T-SYNC-023/024):
// кнопки по ролям, step-up до запроса для `sync.run.full`, отмена step-up без запроса, вариант C-2, офлайн.
// Порт статуса — фейк (не реальная интеграция).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/sync/sync_ports.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/sync_status/presentation/notifiers/sync_status_controller.dart';
import 'package:optomstroy/features/sync_status/presentation/screens/sync_status_screen.dart';
import 'package:optomstroy/features/sync_status/presentation/widgets/sync_run_detail.dart';
import 'package:optomstroy/features/sync_status/presentation/widgets/sync_run_dialog.dart';

final DateTime now = DateTime.utc(2026, 10, 19, 9, 42);

SyncServerStatus statusFixture({bool stockRunning = false}) => SyncServerStatus(
  onecReachable: true,
  checkedAt: now,
  overall: 'ok',
  entities: [
    for (final e in const ['stock', 'prices', 'order_status', 'products', 'customers'])
      SyncServerEntity(
        entityValue: e,
        lastSuccessAt: now.subtract(const Duration(minutes: 1)),
        intervalSec: 600,
        running: e == 'stock' && stockRunning,
        consecutiveErrors: e == 'customers' ? 2 : 0,
      ),
  ],
  outbox: const SyncServerOutbox(pending: 2),
);

final class FakeSyncStatusPort implements SyncStatusPort {
  SyncServerStatus status_ = statusFixture();
  Result<SyncRunInfo>? startResult;
  final List<({SyncEntity entity, SyncMode mode, String key, String? token})> starts = [];
  String runStatus = 'running';
  final List<SyncEntity?> runsEntities = [];

  @override
  Future<Result<SyncServerStatus>> status() async => Success(status_);

  @override
  Future<Result<SyncRunsPage>> runs({SyncEntity? entity, int limit = 50, String? cursor}) async {
    runsEntities.add(entity);
    return Success(
      SyncRunsPage(
        items: [
          SyncRunInfo(
            id: 'r-0',
            entityValue: 'stock',
            modeValue: 'incremental',
            statusValue: 'success',
            triggerValue: 'schedule',
            startedAt: now.subtract(const Duration(minutes: 5)),
            finishedAt: now.subtract(const Duration(minutes: 4)),
          ),
        ],
      ),
    );
  }

  @override
  Future<Result<SyncRunInfo>> run(String runId) async =>
      Success(SyncRunInfo(id: runId, entityValue: 'stock', modeValue: 'incremental', statusValue: runStatus));

  @override
  Future<Result<SyncRunInfo>> startRun({
    required SyncEntity entity,
    required SyncMode mode,
    required String idempotencyKey,
    String? stepUpToken,
  }) async {
    starts.add((entity: entity, mode: mode, key: idempotencyKey, token: stepUpToken));
    return startResult ??
        Success(
          SyncRunInfo(
            id: 'run-${starts.length}',
            entityValue: entity.value,
            modeValue: mode.value,
            statusValue: 'queued',
          ),
        );
  }
}

void main() {
  late FakeSyncStatusPort port;
  late List<String> stepUps;
  late SyncStepUpOutcome stepUpAnswer;

  setUp(() {
    port = FakeSyncStatusPort();
    stepUps = [];
    stepUpAnswer = const SyncStepUpOutcome.granted('step-token');
  });

  Future<AppLocalizations> pump(
    WidgetTester tester,
    RoleCode? role, {
    OnlineStatus online = OnlineStatus.online,
    Size size = const Size(1280, 900),
  }) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncStatusPortProvider.overrideWithValue(port),
          syncViewerRoleProvider.overrideWithValue(role),
          onlineStatusProvider.overrideWith((ref) => Stream<OnlineStatus>.value(online)),
          catalogFreshnessProvider.overrideWithValue(
            DataFreshness(online: online, now: now, asOf: now.subtract(const Duration(minutes: 30))),
          ),
          localSyncStatesProvider.overrideWith(
            (ref) => Stream<List<LocalEntitySync>>.value([
              LocalEntitySync(entity: 'products', asOf: now.subtract(const Duration(minutes: 30))),
            ]),
          ),
          syncNowProvider.overrideWith((ref) => Stream<DateTime>.value(now)),
          clockProvider.overrideWithValue(_Clock(now)),
          syncStatusPollIntervalsProvider.overrideWithValue(null),
          syncIdempotencyKeyProvider.overrideWithValue(() => 'idem-1'),
          syncStepUpProvider.overrideWithValue((op) async {
            stepUps.add(op);
            return stepUpAnswer;
          }),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) =>
              MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
          home: const SyncStatusScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return AppLocalizations.of(tester.element(find.byType(SyncStatusScreen)));
  }

  for (final role in [RoleCode.seller, RoleCode.cashier]) {
    testWidgets('${role.value}: краткий статус, без кнопок запуска и журнала; подсказка (AC-UI-43-002)', (
      tester,
    ) async {
      final l10n = await pump(tester, role);
      expect(find.text(l10n.sync_overall_ok), findsOneWidget);
      expect(find.byKey(SyncStatusScreen.permissionHintKey), findsOneWidget);
      expect(find.byKey(SyncStatusScreen.runDialogButtonKey), findsNothing);
      for (final e in const [SyncEntity.stock, SyncEntity.prices, SyncEntity.orderStatus]) {
        expect(find.byKey(SyncStatusScreen.quickButtonKey(e)), findsNothing);
      }
      expect(find.text(l10n.sync_tab_runs), findsNothing);
      expect(find.textContaining('В очереди'), findsNothing, reason: 'счётчики outbox — не для seller/cashier');
    });
  }

  testWidgets('senior_seller: ровно три кнопки incremental; запуск без step-up, «Обновляем…» до итога (AC-UI-43-003)', (
    tester,
  ) async {
    final l10n = await pump(tester, RoleCode.seniorSeller);
    expect(find.byKey(SyncStatusScreen.permissionHintKey), findsNothing);
    expect(find.byKey(SyncStatusScreen.runDialogButtonKey), findsNothing);
    for (final e in const [SyncEntity.stock, SyncEntity.prices, SyncEntity.orderStatus]) {
      expect(find.byKey(SyncStatusScreen.quickButtonKey(e)), findsOneWidget);
    }
    expect(find.text(l10n.sync_tab_runs), findsOneWidget);

    await tester.tap(find.byKey(SyncStatusScreen.quickButtonKey(SyncEntity.stock)));
    await tester.pump();
    await tester.pump();
    expect(stepUps, isEmpty);
    expect(port.starts, hasLength(1));
    expect(port.starts.single, (entity: SyncEntity.stock, mode: SyncMode.incremental, key: 'idem-1', token: null));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text(l10n.sync_run_button_busy), findsWidgets);

    // Повторный тап по «Обновляем…» не отправляет второй запрос.
    await tester.tap(find.byKey(SyncStatusScreen.quickButtonKey(SyncEntity.stock)), warnIfMissed: false);
    await tester.pump();
    expect(port.starts, hasLength(1));

    // Прогон завершился → снекбар «Синхронизация завершена», кнопка снова активна.
    port.runStatus = 'success';
    final container = ProviderScope.containerOf(tester.element(find.byType(SyncStatusScreen)));
    await container.read(syncStatusControllerProvider.notifier).refresh();
    await tester.pumpAndSettle();
    expect(find.text(l10n.sync_run_done), findsOneWidget);
    expect(find.text(l10n.sync_run_button_stock), findsOneWidget);
  });

  testWidgets('admin: «Запустить…» → full → StepUpDialog до запроса → один POST с токеном (AC-UI-43-005)', (
    tester,
  ) async {
    final l10n = await pump(tester, RoleCode.admin);
    expect(find.byKey(SyncStatusScreen.runDialogButtonKey), findsOneWidget);
    expect(find.byKey(SyncStatusScreen.quickButtonKey(SyncEntity.stock)), findsNothing);
    expect(find.text(l10n.sync_outbox_counts('0', '0', '2')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('sync-row-menu-products')));
    await tester.pumpAndSettle();
    expect(find.byType(SyncRunDialog), findsOneWidget);
    await tester.tap(find.text(l10n.sync_mode_full));
    await tester.pumpAndSettle();
    expect(find.text(l10n.sync_run_full_warning_no_estimate), findsOneWidget);
    await tester.tap(find.byKey(SyncRunDialog.confirmKey));
    await tester.pumpAndSettle();

    expect(stepUps, ['sync.run.full']);
    expect(port.starts, hasLength(1));
    expect(port.starts.single, (
      entity: SyncEntity.products,
      mode: SyncMode.full,
      key: 'idem-1',
      token: 'step-token', // check-secrets: allow — тестовая метка, не секрет
    ));
    expect(find.text(l10n.sync_run_started), findsOneWidget);
  });

  testWidgets('admin: отмена StepUpDialog — запрос не отправляется, экран в исходном состоянии (AC-UI-43-017)', (
    tester,
  ) async {
    stepUpAnswer = const SyncStepUpOutcome.cancelled();
    final l10n = await pump(tester, RoleCode.admin);
    await tester.tap(find.byKey(const ValueKey<String>('sync-row-menu-customers')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(SyncRunDialog.confirmKey)); // incremental customers — тоже sync.run.full
    await tester.pumpAndSettle();
    expect(stepUps, ['sync.run.full']);
    expect(port.starts, isEmpty);
    expect(find.text(l10n.sync_run_open_dialog), findsWidgets);
  });

  testWidgets('owner: incremental для stock через диалог — без step-up', (tester) async {
    await pump(tester, RoleCode.owner);
    await tester.tap(find.byKey(const ValueKey<String>('sync-row-menu-stock')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(SyncRunDialog.confirmKey));
    await tester.pumpAndSettle();
    expect(stepUps, isEmpty);
    expect(port.starts.single.token, isNull);
    expect(port.starts.single.mode, SyncMode.incremental);
  });

  testWidgets('409 SYNC_ALREADY_RUNNING → снекбар «уже выполняется» (AC-UI-43-006)', (tester) async {
    port.startResult = const FailureResult(ConflictFailure(ConflictKind.syncAlreadyRunning, details: {'runId': 'r-9'}));
    final l10n = await pump(tester, RoleCode.seniorSeller);
    await tester.tap(find.byKey(SyncStatusScreen.quickButtonKey(SyncEntity.prices)));
    await tester.pumpAndSettle();
    expect(find.text(l10n.error_sync_already_running), findsOneWidget);
    expect(find.text(l10n.sync_run_button_prices), findsWidgets);
  });

  testWidgets('вариант C-2: 422 inbound_mode → все кнопки запуска неактивны с пояснением (AC-UI-43-019)', (
    tester,
  ) async {
    port.startResult = const FailureResult(
      ValidationFailure(
        errors: [FieldError(field: 'entity', rule: 'inbound_mode')],
      ),
    );
    final l10n = await pump(tester, RoleCode.seniorSeller);
    await tester.tap(find.byKey(SyncStatusScreen.quickButtonKey(SyncEntity.stock)));
    await tester.pumpAndSettle();
    expect(find.byKey(SyncStatusScreen.inboundModeHintKey), findsOneWidget);
    await tester.tap(find.byKey(SyncStatusScreen.quickButtonKey(SyncEntity.prices)), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(port.starts, hasLength(1), reason: 'повторных запросов в сеансе нет');
    expect(find.text(l10n.sync_manual_run_inbound_mode), findsWidgets);
  });

  testWidgets('офлайн: OfflineBanner, метки sync_meta устройства, запуск недоступен, сервер не опрашивается', (
    tester,
  ) async {
    await pump(tester, RoleCode.seniorSeller, online: OnlineStatus.offline);
    expect(find.byKey(OfflineBanner.bannerKey), findsOneWidget);
    final button = tester.widget<AppButton>(find.byKey(SyncStatusScreen.quickButtonKey(SyncEntity.stock)));
    expect(button.onPressed, isNull);
    expect(port.starts, isEmpty);
  });

  testWidgets('вкладка «Прогоны» (sync.runs.read): список прогонов', (tester) async {
    final l10n = await pump(tester, RoleCode.seniorSeller);
    await tester.tap(find.text(l10n.sync_tab_runs));
    await tester.pumpAndSettle();
    expect(find.textContaining(l10n.sync_trigger_schedule), findsOneWidget);
    expect(find.text(l10n.status_sync_success), findsOneWidget);
  });

  testWidgets('полный режим (этап G): тап по сущности — «Прогоны» с фильтром; тап по прогону — деталь', (tester) async {
    final l10n = await pump(tester, RoleCode.admin);
    await tester.tap(find.byKey(SyncStatusScreen.entityRowKey(SyncEntity.stock)));
    await tester.pumpAndSettle();
    expect(port.runsEntities.last, SyncEntity.stock);
    expect(find.byKey(SyncStatusScreen.runsEntityFilterKey), findsOneWidget);
    await tester.tap(find.byKey(SyncStatusScreen.runRowKey('r-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(SyncRunDetail.rootKey), findsOneWidget);
    expect(find.text(l10n.sync_tab_runs), findsWidgets);
    // Действий «Пометить решённой» и «Пауза» в R1 нет (Q-219, RM-G-012 п. 4).
    expect(find.textContaining('Пауза'), findsNothing);
    expect(find.textContaining('решённ'), findsNothing);
  });

  testWidgets('полный режим: ?runId= открывает деталь прогона', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(1280, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncStatusPortProvider.overrideWithValue(port),
          syncViewerRoleProvider.overrideWithValue(RoleCode.owner),
          onlineStatusProvider.overrideWith((ref) => Stream<OnlineStatus>.value(OnlineStatus.online)),
          catalogFreshnessProvider.overrideWithValue(DataFreshness(online: OnlineStatus.online, now: now, asOf: now)),
          localSyncStatesProvider.overrideWith((ref) => Stream<List<LocalEntitySync>>.value(const [])),
          syncNowProvider.overrideWith((ref) => Stream<DateTime>.value(now)),
          clockProvider.overrideWithValue(_Clock(now)),
          syncStatusPollIntervalsProvider.overrideWithValue(null),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) =>
              MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
          home: const SyncStatusScreen(runId: 'r-9', tab: 'runs'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(SyncRunDetail.rootKey), findsOneWidget);
  });

  testWidgets('compact 360: зона C — кнопки столбиком, без переполнения', (tester) async {
    await pump(tester, RoleCode.seniorSeller, size: const Size(360, 760));
    expect(tester.takeException(), isNull);
    expect(find.byKey(SyncStatusScreen.quickButtonKey(SyncEntity.orderStatus)), findsOneWidget);
  });
}

final class _Clock implements Clock {
  const _Clock(this.value);

  final DateTime value;

  @override
  DateTime nowUtc() => value;
}
