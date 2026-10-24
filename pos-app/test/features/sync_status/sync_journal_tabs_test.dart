// SCR-43 полный режим (02 SCR-43 зона D, UI-43-006/007/008/013/015; 13 RM-G-008; 04 FLOW-033.S6; ревью G-trace-1):
// вкладки «Ошибки» (`sync.runs.read`) и «Outbox» (`sync.outbox.manage`: admin, senior_seller), повтор элемента outbox
// `POST /sync/outbox/{id}/retry` с `Idempotency-Key` (тот же ключ после сбоя сети), `409 already_delivered`,
// ошибки прогона `GET /sync/runs/{id}/errors`. Порты — фейки (не реальная интеграция).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/sync/sync_journal.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/sync/sync_ports.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/sync_status/presentation/notifiers/sync_status_controller.dart';
import 'package:optomstroy/features/sync_status/presentation/screens/sync_status_screen.dart';
import 'package:optomstroy/features/sync_status/presentation/widgets/sync_journal_tabs.dart';

final DateTime _now = DateTime.utc(2026, 10, 19, 9, 42);

final class _StatusPort implements SyncStatusPort {
  List<SyncRunInfo> runsList = <SyncRunInfo>[
    SyncRunInfo(
      id: 'r-ok',
      entityValue: 'stock',
      modeValue: 'incremental',
      statusValue: 'success',
      startedAt: _now.subtract(const Duration(minutes: 3)),
    ),
    SyncRunInfo(
      id: 'r-err',
      entityValue: 'customers',
      modeValue: 'incremental',
      statusValue: 'partial',
      startedAt: _now.subtract(const Duration(minutes: 30)),
      errors: 2,
    ),
  ];

  @override
  Future<Result<SyncServerStatus>> status() async => Success<SyncServerStatus>(
    SyncServerStatus(
      onecReachable: true,
      checkedAt: _now,
      overall: 'degraded',
      entities: <SyncServerEntity>[SyncServerEntity(entityValue: 'stock', lastSuccessAt: _now)],
      outbox: const SyncServerOutbox(pending: 0, failed: 1, dead: 1),
    ),
  );

  @override
  Future<Result<SyncRunsPage>> runs({SyncEntity? entity, int limit = 50, String? cursor}) async =>
      Success<SyncRunsPage>(SyncRunsPage(items: runsList));

  @override
  Future<Result<SyncRunInfo>> run(String runId) async => Success<SyncRunInfo>(
    SyncRunInfo(id: runId, entityValue: 'stock', modeValue: 'incremental', statusValue: 'success'),
  );

  @override
  Future<Result<SyncRunInfo>> startRun({
    required SyncEntity entity,
    required SyncMode mode,
    required String idempotencyKey,
    String? stepUpToken,
  }) async => const FailureResult<SyncRunInfo>(UnknownFailure());
}

final class _Journal implements SyncJournalPort {
  final List<String> errorRuns = <String>[];
  int outboxCalls = 0;
  final List<({String id, String key})> retries = <({String id, String key})>[];
  final List<Result<SyncOutboxItem>> retryResults = <Result<SyncOutboxItem>>[];

  static SyncOutboxItem item(String id, String status, {String number = 'POS-2026-000123'}) => SyncOutboxItem(
    id: id,
    aggregateTypeValue: 'order',
    aggregateId: 'o-$id',
    statusValue: status,
    operationValue: 'create',
    publicNumber: number,
    attempts: 8,
    lastErrorCode: 'ONEC_UNAVAILABLE',
    lastError: '1С не ответила',
    createdAt: _now.subtract(const Duration(hours: 2)),
  );

  @override
  Future<Result<PageResult<SyncRunErrorInfo>>> runErrors(String runId, {int limit = 50, String? cursor}) async {
    errorRuns.add(runId);
    return const Success<PageResult<SyncRunErrorInfo>>(
      PageResult<SyncRunErrorInfo>(
        items: <SyncRunErrorInfo>[
          SyncRunErrorInfo(
            id: 'e1',
            entityValue: 'customers',
            errorCodeValue: 'VALIDATION',
            message: 'Не заполнен ИНН',
            onecCode: '000123',
          ),
        ],
      ),
    );
  }

  @override
  Future<Result<PageResult<SyncOutboxItem>>> outbox({
    Set<OutboxStatus> statuses = const <OutboxStatus>{OutboxStatus.failed, OutboxStatus.dead},
    OutboxAggregate? aggregateType,
    int limit = 50,
    String? cursor,
  }) async {
    outboxCalls++;
    return Success<PageResult<SyncOutboxItem>>(PageResult<SyncOutboxItem>(items: <SyncOutboxItem>[item('x1', 'dead')]));
  }

  @override
  Future<Result<SyncOutboxItem>> retryOutbox(String id, {required String idempotencyKey}) async {
    retries.add((id: id, key: idempotencyKey));
    return retryResults.isEmpty ? Success<SyncOutboxItem>(item(id, 'pending')) : retryResults.removeAt(0);
  }
}

final class _Clock implements Clock {
  @override
  DateTime nowUtc() => _now;
}

void main() {
  late _StatusPort status;
  late _Journal journal;
  late int keys;

  setUp(() {
    status = _StatusPort();
    journal = _Journal();
    keys = 0;
  });

  Future<AppLocalizations> pump(WidgetTester tester, RoleCode role, {String? tab, String? runId}) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(1280, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncStatusPortProvider.overrideWithValue(status),
          syncJournalPortProvider.overrideWithValue(journal),
          syncOutboxKeyFactoryProvider.overrideWithValue(() => 'okey-${++keys}'),
          syncViewerRoleProvider.overrideWithValue(role),
          onlineStatusProvider.overrideWith((ref) => Stream<OnlineStatus>.value(OnlineStatus.online)),
          catalogFreshnessProvider.overrideWithValue(DataFreshness(online: OnlineStatus.online, now: _now, asOf: _now)),
          localSyncStatesProvider.overrideWith((ref) => Stream<List<LocalEntitySync>>.value(const <LocalEntitySync>[])),
          syncNowProvider.overrideWith((ref) => Stream<DateTime>.value(_now)),
          clockProvider.overrideWithValue(_Clock()),
          syncStatusPollIntervalsProvider.overrideWithValue(null),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) =>
              MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
          home: SyncStatusScreen(tab: tab, runId: runId),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return AppLocalizations.of(tester.element(find.byType(SyncStatusScreen)));
  }

  Future<void> openTab(WidgetTester tester, String tab) async {
    await tester.tap(find.byKey(ValueKey<String>('sync-tab-$tab')));
    await tester.pumpAndSettle();
  }

  Future<void> retry(WidgetTester tester, AppLocalizations l10n) async {
    await tester.ensureVisible(find.byKey(SyncJournalKeys.outboxRetry('x1')));
    await tester.tap(find.byKey(SyncJournalKeys.outboxRetry('x1')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.sync_outbox_retry_confirm('POS-2026-000123')), findsOneWidget);
    await tester.tap(find.text(l10n.sync_outbox_retry).last);
    await tester.pumpAndSettle();
  }

  testWidgets('admin: вкладки «Ошибки» и «Outbox»; «Повторить» dead → ConfirmDialog → retry с ключом → «В очереди»', (
    tester,
  ) async {
    final AppLocalizations l10n = await pump(tester, RoleCode.admin);
    expect(find.text(l10n.sync_tab_errors), findsOneWidget);
    expect(find.text(l10n.sync_tab_outbox), findsOneWidget);
    await openTab(tester, 'outbox');
    expect(journal.outboxCalls, 1);
    expect(find.byKey(SyncJournalKeys.outboxRow('x1')), findsOneWidget);
    expect(find.textContaining('ONEC_UNAVAILABLE'), findsOneWidget);
    expect(find.byKey(SyncJournalKeys.outboxOpen('x1')), findsOneWidget); // UI-43-015 «Открыть заказ»
    await retry(tester, l10n);
    expect(journal.retries.single, (id: 'x1', key: 'okey-1'));
    expect(find.text(l10n.sync_outbox_retried), findsOneWidget);
    expect(find.text(l10n.payment_onec_pending), findsOneWidget);
    expect(find.byKey(SyncJournalKeys.outboxRetry('x1')), findsNothing, reason: 'pending — повтор недоступен');
  });

  testWidgets('outbox: сбой сети — повтор тем же Idempotency-Key; 409 already_delivered — «Документ уже отправлен»', (
    tester,
  ) async {
    journal.retryResults
      ..add(const FailureResult<SyncOutboxItem>(NetworkFailure(NetworkFailureKind.timeout, outcomeUnknown: true)))
      ..add(
        const FailureResult<SyncOutboxItem>(
          ConflictFailure(ConflictKind.orderStateInvalid, reason: 'already_delivered'),
        ),
      );
    final AppLocalizations l10n = await pump(tester, RoleCode.seniorSeller);
    await openTab(tester, 'outbox');
    await retry(tester, l10n);
    await retry(tester, l10n);
    expect(journal.retries.map((r) => r.key), <String>['okey-1', 'okey-1']);
    expect(find.text(l10n.sync_outbox_already_sent), findsOneWidget);
    expect(journal.outboxCalls, 2, reason: 'список перечитан');
  });

  testWidgets('«Ошибки»: последний прогон с ошибками → GET /sync/runs/{id}/errors; код, сообщение, код 1С', (
    tester,
  ) async {
    // AC-UI-43-012: owner не видит вкладку «Outbox» (счётчики очереди в зоне A — видит).
    final AppLocalizations l10n = await pump(tester, RoleCode.owner);
    await openTab(tester, 'errors');
    expect(journal.errorRuns, <String>['r-err']);
    expect(find.byKey(SyncJournalKeys.errorRow('e1')), findsOneWidget);
    expect(find.text('VALIDATION · 000123'), findsOneWidget);
    expect(find.text('Не заполнен ИНН'), findsOneWidget);
    expect(find.byKey(SyncJournalKeys.copyCode('e1')), findsOneWidget);
    expect(find.text(l10n.sync_tab_outbox), findsNothing, reason: 'owner — без outbox');
    expect(find.text(l10n.sync_outbox_counts('1', '1', '0')), findsOneWidget, reason: 'owner — счётчики видны');
  });

  testWidgets('?runId= — ошибки указанного прогона; ?tab=outbox у owner — «Сущности»', (tester) async {
    await pump(tester, RoleCode.admin, tab: 'errors', runId: 'r-ok');
    expect(journal.errorRuns, <String>['r-ok']);
    await pump(tester, RoleCode.owner, tab: 'outbox');
    expect(find.byKey(SyncJournalKeys.outboxList), findsNothing);
    expect(journal.outboxCalls, 0);
  });

  testWidgets('seller и cashier — вкладок журнала нет', (tester) async {
    for (final RoleCode r in <RoleCode>[RoleCode.seller, RoleCode.cashier]) {
      final AppLocalizations l10n = await pump(tester, r);
      expect(find.text(l10n.sync_tab_errors), findsNothing);
      expect(find.text(l10n.sync_tab_outbox), findsNothing);
    }
  });

  test('errorsRunOf: явный runId; иначе первый прогон с ошибками; иначе последний', () {
    final List<SyncRunInfo> runs = _StatusPort().runsList;
    expect(errorsRunOf('x', runs), 'x');
    expect(errorsRunOf(null, runs), 'r-err');
    expect(errorsRunOf(null, runs.take(1).toList()), 'r-ok');
    expect(errorsRunOf(null, null), isNull);
  });
}
