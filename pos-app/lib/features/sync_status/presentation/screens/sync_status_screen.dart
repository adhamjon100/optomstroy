// SCR-43 «Статус синхронизации» (`/sync?entity=&runId=&tab=`, staff; 02 ч. E SCR-43; RM-E-009).
//
// Зона A — сводка (`SyncIndicator` + `StatusChip` общего состояния и доступности 1С, последний успешный
// обмен, «Проверено HH:MM», счётчики очереди 1С для `senior_seller`/`admin`/`owner`).
// Зона B — сущности `sync_entity` в порядке важности: время успеха, интервал, следующий запуск, ошибки подряд,
// прогресс прогона; у `senior_seller` — «Обновить» для `stock`/`prices`/`order_status`, у `admin`/`owner` —
// «Запустить…» с предзаполнением.
// Зона C — действия по роли (правило R0 §17.2): `senior_seller` — три кнопки `incremental` без step-up,
// `admin`/`owner` — «Запустить…» (StepUpDialog для `sync.run.full`), `seller`/`cashier` — подсказка.
// Вкладка «Прогоны» — `sync.runs.read`. Офлайн — `OfflineBanner` и метки `sync_meta` устройства; запуск
// недоступен. Опрос `GET /sync/status` — 30 с (5 с во время прогона), пока экран виден и приложение активно.
// Этап G (RM-G-008, полный режим): фильтр прогонов по сущности (UI-43-010), деталь прогона (UI-43-011, `?runId=`),
// тап по строке сущности → «Прогоны» с фильтром (UI-43-002); вкладки «Ошибки» (UI-43-007, `sync.runs.read`) и «Outbox»
// с «Повторить» (UI-43-008/013/015, `sync.outbox.manage`: `admin`, `senior_seller`; FLOW-033.S6) — порт
// `SyncJournalPort` (`syncJournalPortProvider`, подставляет корень). Действий «Пометить решённой» и «Пауза» в R1 нет
// (Q-219).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/core/sync/sync_run_policy.dart';
import 'package:optomstroy/design_system/components/app_badge.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_dropdown.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/components/sync_indicator.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/sync_status/presentation/notifiers/sync_status_controller.dart';
import 'package:optomstroy/features/sync_status/presentation/widgets/sync_journal_tabs.dart';
import 'package:optomstroy/features/sync_status/presentation/widgets/sync_labels.dart';
import 'package:optomstroy/features/sync_status/presentation/widgets/sync_run_detail.dart';
import 'package:optomstroy/features/sync_status/presentation/widgets/sync_run_dialog.dart';

/// Вкладки SCR-43 (`?tab=`).
enum SyncStatusTab {
  entities('entities'),
  runs('runs'),
  errors('errors'),
  outbox('outbox');

  const SyncStatusTab(this.value);

  final String value;

  static SyncStatusTab parse(String? v) => values.where((t) => t.value == v).firstOrNull ?? entities;
}

/// SCR-43 — Статус синхронизации.
class SyncStatusScreen extends ConsumerStatefulWidget {
  const SyncStatusScreen({this.entity, this.runId, this.tab, this.sheet = false, this.onMore, super.key});

  /// ID экрана по 02 §4.1.
  static const String screenId = 'SCR-43';

  /// Сущность обмена (`SyncEntity.value`) — фильтр журнала.
  final String? entity;

  /// Прогон синхронизации.
  final String? runId;

  /// Вкладка экрана.
  final String? tab;

  /// Краткий вид в side sheet 480 (expanded, 02 SCR-43.2/43.6): зоны A, B, C без журнала, крестик и
  /// «Подробнее» ([onMore]) вместо «Назад»; URL не меняется.
  final bool sheet;

  /// «Подробнее» в side sheet → полный экран `/sync`.
  final VoidCallback? onMore;

  /// Ключи для тестов.
  static const Key screenKey = ValueKey<String>('screen-$screenId');
  static const Key runDialogButtonKey = Key('sync-open-run-dialog');
  static const Key permissionHintKey = Key('sync-permission-hint');
  static const Key inboundModeHintKey = Key('sync-inbound-mode-hint');
  static const Key sheetCloseKey = Key('sync-sheet-close');
  static const Key sheetMoreKey = Key('sync-sheet-more');
  static Key quickButtonKey(SyncEntity e) => Key('sync-quick-${e.value}');
  static const Key runsEntityFilterKey = Key('sync-runs-entity');
  static Key runRowKey(String id) => Key('sync-run-$id');
  static Key entityRowKey(SyncEntity e) => Key('sync-entity-${e.value}');

  @override
  ConsumerState<SyncStatusScreen> createState() => _SyncStatusScreenState();
}

class _SyncStatusScreenState extends ConsumerState<SyncStatusScreen> with WidgetsBindingObserver {
  Timer? _poll;
  late SyncStatusTab _tab = SyncStatusTab.parse(widget.tab);
  late SyncEntity? _runsEntity = SyncEntity.tryParse(widget.entity);
  bool _foreground = true;

  SyncStatusController get _controller => ref.read(syncStatusControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_refresh());
      if (_tab == SyncStatusTab.runs || _tab == SyncStatusTab.errors) {
        unawaited(_controller.loadRuns(entity: _runsEntity));
      }
      final String? runId = widget.runId;
      if (runId != null && !widget.sheet) unawaited(_openRun(runId));
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Опрос приостанавливается в фоне (02 SCR-43.12), при возврате — сразу обновление.
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      unawaited(_refresh());
    } else {
      _poll?.cancel();
    }
  }

  Future<void> _refresh() async {
    _poll?.cancel();
    if (ref.read(onlineStatusProvider).value != OnlineStatus.offline) await _controller.refresh();
    _schedule();
  }

  void _schedule() {
    _poll?.cancel();
    final intervals = ref.read(syncStatusPollIntervalsProvider);
    if (!mounted || !_foreground || intervals == null) return;
    final fast = ref.read(syncStatusControllerProvider).anyRunning;
    _poll = Timer(fast ? intervals.$2 : intervals.$1, () => unawaited(_refresh()));
  }

  Future<void> _start(SyncEntity entity, SyncMode mode) async {
    await _controller.start(entity, mode);
  }

  Future<void> _openRunDialog({SyncEntity? entity, SyncMode mode = SyncMode.incremental}) async {
    final choice = await SyncRunDialog.show(context, entity: entity, mode: mode, fullEstimates: _fullEstimates());
    if (choice == null || !mounted) return;
    await _start(choice.entity, choice.mode);
  }

  Map<SyncEntity, int> _fullEstimates() {
    final out = <SyncEntity, int>{};
    for (final r in ref.read(syncStatusControllerProvider).runs?.items ?? const <SyncRunInfo>[]) {
      final e = r.entity;
      if (e == null || r.mode != SyncMode.full || r.startedAt == null || r.finishedAt == null) continue;
      out.putIfAbsent(e, () => (r.finishedAt!.difference(r.startedAt!).inSeconds / 60).ceil().clamp(1, 24 * 60));
    }
    return out;
  }

  void _onEvent(SyncStatusEvent? previous, SyncStatusEvent? next) {
    if (next == null || next.id == previous?.id || !mounted) return;
    final l10n = AppLocalizations.of(context);
    switch (next) {
      case SyncRunStartedEvent():
        AppSnackbar.show(context, message: l10n.sync_run_started);
      case SyncRunFinishedEvent(:final run):
        final (text, variant) = switch (run.status) {
          SyncRunStatus.success => (l10n.sync_run_done, AppSnackbarVariant.success),
          SyncRunStatus.partial => (l10n.sync_run_partial(run.errors ?? 0), AppSnackbarVariant.error),
          _ => (l10n.sync_run_failed, AppSnackbarVariant.error),
        };
        AppSnackbar.show(context, message: text, variant: variant);
      case SyncRunRejectedEvent(:final reason, :final retryAfter):
        final text = switch (reason) {
          SyncRunRejection.alreadyRunning => l10n.error_sync_already_running,
          SyncRunRejection.rateLimited => l10n.sync_rate_limited(retryAfter?.inSeconds ?? 60),
          SyncRunRejection.inboundMode => l10n.sync_manual_run_inbound_mode,
          SyncRunRejection.forbidden => l10n.error_forbidden,
          SyncRunRejection.network => l10n.auth_error_network,
          SyncRunRejection.other => l10n.error_internal,
        };
        AppSnackbar.show(context, message: text, variant: AppSnackbarVariant.error);
    }
  }

  void _selectTab(SyncStatusTab tab) {
    setState(() => _tab = tab);
    // «Ошибки» без `?runId=` показывают последний прогон с ошибками — нужен журнал прогонов.
    if ((tab == SyncStatusTab.runs || tab == SyncStatusTab.errors) &&
        ref.read(syncStatusControllerProvider).runs == null) {
      unawaited(_controller.loadRuns(entity: _runsEntity));
    }
  }

  /// Вкладки журнала по роли: «Ошибки» — при подключённом журнале, «Outbox» — ещё и `sync.outbox.manage`.
  List<SyncStatusTab> _tabsFor(RoleCode? role) {
    final bool journal = ref.watch(syncJournalPortProvider) != null;
    return <SyncStatusTab>[
      SyncStatusTab.entities,
      SyncStatusTab.runs,
      if (journal) SyncStatusTab.errors,
      if (journal && SyncRunPolicy.canManageOutbox(role)) SyncStatusTab.outbox,
    ];
  }

  Widget _journalTab(SyncStatusViewState view, SyncStatusTab tab) => switch (tab) {
    SyncStatusTab.errors => () {
      final List<SyncRunInfo>? runs = view.runs?.items;
      final String? runId = errorsRunOf(widget.runId, runs);
      SyncRunInfo? run;
      for (final SyncRunInfo r in runs ?? const <SyncRunInfo>[]) {
        if (r.id == runId) run = r;
      }
      return SyncErrorsTab(runId: runId, run: run);
    }(),
    _ => const SyncOutboxTab(),
  };

  /// Фильтр прогонов по сущности (UI-43-010).
  void _filterRuns(SyncEntity? entity) {
    setState(() {
      _tab = SyncStatusTab.runs;
      _runsEntity = entity;
    });
    unawaited(_controller.loadRuns(entity: entity));
  }

  /// Деталь прогона (UI-43-011): compact — экран, иначе — боковой лист.
  Future<void> _openRun(String runId, {SyncRunInfo? initial}) async {
    final l10n = AppLocalizations.of(context);
    final detail = SyncRunDetail(runId: runId, initial: initial);
    final windowClass = context.windowClass;
    if (windowClass == WindowClass.compact) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (ctx) => Scaffold(
            appBar: AppBar(title: Text(l10n.sync_tab_runs)),
            body: SingleChildScrollView(padding: EdgeInsets.all(ctx.space.s4), child: detail),
          ),
        ),
      );
    } else {
      await AppBottomSheet.showSide<void>(
        context,
        title: l10n.sync_tab_runs,
        width: windowClass == WindowClass.medium ? AppBottomSheet.sideMedium : AppBottomSheet.sideExpanded,
        body: detail,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SyncStatusEvent?>(syncStatusControllerProvider.select((s) => s.event), _onEvent);
    ref.listen<bool>(syncStatusControllerProvider.select((s) => s.anyRunning), (_, _) => _schedule());
    final l10n = AppLocalizations.of(context);
    final view = ref.watch(syncStatusControllerProvider);
    final role = ref.watch(syncViewerRoleProvider);
    final online = ref.watch(onlineStatusProvider).value ?? OnlineStatus.unknown;
    final freshness = ref.watch(catalogFreshnessProvider);
    final offline = online == OnlineStatus.offline;
    final journal = SyncRunPolicy.canViewJournal(role) && !offline && !widget.sheet;
    final tabs = _tabsFor(role);
    // `?tab=` недоступной роли вкладки — «Сущности».
    final tab = tabs.contains(_tab) ? _tab : SyncStatusTab.entities;
    final expanded =
        !widget.sheet && (context.windowClass == WindowClass.expanded || context.windowClass == WindowClass.large);
    // «Сейчас» для меток времени (тик 30 с; в тестах — `FixedClock` / переопределённый `syncNowProvider`).
    final DateTime now = ref.watch(syncNowProvider).value ?? ref.read(clockProvider).nowUtc();

    final body = <Widget>[
      if (offline)
        _LocalSummary(freshness: freshness, now: now)
      else if (view.status == null && view.failure == null)
        const _SummarySkeleton()
      else if (view.status == null)
        ErrorState.inline(message: l10n.error_internal, onRetry: () => unawaited(_refresh()), retrying: view.loading)
      else ...<Widget>[
        _SummaryCard(status: view.status!, role: role, failed: view.failure != null, now: now),
        ..._staleBanners(context, view.status!, role),
      ],
      if (journal) ...<Widget>[
        SizedBox(height: context.space.s4),
        _Tabs(tabs: tabs, selected: tab, onSelect: _selectTab),
      ],
      SizedBox(height: context.space.s2),
      if (!journal || tab == SyncStatusTab.entities)
        ..._entitiesZone(context, view, role, offline: offline, now: now)
      else if (tab == SyncStatusTab.errors || tab == SyncStatusTab.outbox)
        _journalTab(view, tab)
      else
        _RunsList(
          view: view,
          now: now,
          entity: _runsEntity,
          onEntity: _filterRuns,
          onOpen: (r) => unawaited(_openRun(r.id, initial: r)),
        ),
    ];

    return Scaffold(
      key: SyncStatusScreen.screenKey,
      appBar: AppBar(
        automaticallyImplyLeading: !widget.sheet,
        leading: widget.sheet
            ? AppIconButton(
                key: SyncStatusScreen.sheetCloseKey,
                icon: Icons.close_rounded,
                semanticLabel: l10n.ds_button_close,
                tooltip: l10n.ds_button_close,
                onPressed: () => unawaited(Navigator.of(context).maybePop()),
              )
            : null,
        title: Text(l10n.sync_title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          AppIconButton(
            icon: Icons.refresh_rounded,
            semanticLabel: l10n.ds_button_retry,
            tooltip: l10n.ds_button_retry,
            onPressed: offline ? null : () => unawaited(_refresh()),
          ),
          if (widget.sheet && widget.onMore != null)
            AppButton(
              key: SyncStatusScreen.sheetMoreKey,
              label: l10n.notifications_action_details,
              variant: AppButtonVariant.text,
              size: AppButtonSize.s,
              onPressed: widget.onMore,
            ),
          if (widget.sheet) SizedBox(width: context.space.s2),
        ],
      ),
      body: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.f5): () => unawaited(_refresh()),
          const SingleActivator(LogicalKeyboardKey.keyR, control: true): () {
            if (SyncRunPolicy.canOpenRunDialog(role) && !offline) unawaited(_openRunDialog());
          },
        },
        child: Focus(
          autofocus: true,
          child: Column(
            children: <Widget>[
              OfflineBanner(
                variant: offline
                    ? OfflineBannerVariant.offline
                    : (online == OnlineStatus.serverDown ? OfflineBannerVariant.serverDown : null),
                dataAsOf: freshness.asOf,
                now: now,
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView(
                    padding: EdgeInsets.symmetric(
                      horizontal: expanded ? context.space.s6 : context.space.s4,
                      vertical: context.space.s4,
                    ),
                    children: <Widget>[
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 960),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _Actions(
                role: role,
                offline: offline,
                busy: view.busy,
                onQuick: (e) => unawaited(_start(e, SyncMode.incremental)),
                onOpenDialog: () => unawaited(_openRunDialog()),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Зона B: офлайн — метки устройства; иначе — сущности сервера; до первого ответа — скелетон
  /// (при ошибке без данных скелетон не показывается — ошибка уже в зоне A).
  List<Widget> _entitiesZone(
    BuildContext context,
    SyncStatusViewState view,
    RoleCode? role, {
    required bool offline,
    required DateTime now,
  }) {
    if (offline) {
      return _localRows(context, ref.watch(localSyncStatesProvider).value ?? const <LocalEntitySync>[], now);
    }
    if (view.status != null) return _entityRows(context, view, role, now);
    if (view.failure != null) return const <Widget>[];
    return List<Widget>.generate(
      8,
      (_) => Padding(
        padding: EdgeInsets.symmetric(vertical: context.space.s1),
        child: const SkeletonBox(height: 56),
      ),
    );
  }

  List<Widget> _staleBanners(BuildContext context, SyncServerStatus status, RoleCode? role) {
    final l10n = AppLocalizations.of(context);
    return <Widget>[
      for (final e in const <SyncEntity>[SyncEntity.stock, SyncEntity.prices])
        if (status.entity(e) case final s? when s.isStale)
          Padding(
            padding: EdgeInsets.only(top: context.space.s2),
            child: ErrorState.banner(
              tone: ErrorStateTone.warning,
              message: l10n.sync_stale_banner(SyncLabels.entity(l10n, e), ((s.ageSec ?? 0) / 60).floor()),
              onRetry: SyncRunPolicy.canStart(role, e, SyncMode.incremental) && !ref.read(manualSyncBlockedProvider)
                  ? () => unawaited(_start(e, SyncMode.incremental))
                  : null,
            ),
          ),
    ];
  }

  List<Widget> _entityRows(BuildContext context, SyncStatusViewState view, RoleCode? role, DateTime now) {
    final status = view.status!;
    final known = {for (final e in status.entities) e.entityValue: e};
    final rows = <Widget>[];
    for (final e in SyncRunPolicy.displayOrder) {
      final s = known[e.value];
      if (s == null) continue;
      rows.add(
        _EntityRow(
          entity: e,
          status: s,
          role: role,
          busy: view.busy.contains(e),
          now: now,
          onMenu: () => unawaited(_openRunDialog(entity: e)),
          onTap: SyncRunPolicy.canViewJournal(role) && !widget.sheet ? () => _filterRuns(e) : null,
        ),
      );
    }
    return rows;
  }

  List<Widget> _localRows(BuildContext context, List<LocalEntitySync> local, DateTime now) {
    final l10n = AppLocalizations.of(context);
    final byEntity = {for (final l in local) l.entity: l};
    return <Widget>[
      for (final value in catalogCacheEntityOrder)
        if (SyncLabels.cacheEntity(value) case final e?)
          _Row(
            title: SyncLabels.entity(l10n, e),
            trailing: byEntity[value]?.asOf == null
                ? Text(l10n.sync_never, style: context.text.caption.copyWith(color: context.colors.textSecondary))
                : SyncIndicator.inline(time: byEntity[value]!.asOf!, stale: byEntity[value]!.isStale(now), now: now),
          ),
    ];
  }
}

// ---------------------------------------------------------------------------

class _SummarySkeleton extends StatelessWidget {
  const _SummarySkeleton();

  @override
  Widget build(BuildContext context) => const SkeletonBox(height: 120);
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: context.colors.surface,
      borderRadius: BorderRadius.all(context.radii.lg),
      border: Border.all(color: context.colors.border),
    ),
    child: Padding(
      padding: EdgeInsets.all(context.windowClass == WindowClass.compact ? context.space.s4 : context.space.s6),
      child: child,
    ),
  );
}

/// Зона A (UI-43-001, UI-43-017, UI-43-020).
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.status, required this.role, required this.failed, required this.now});

  final SyncServerStatus status;
  final RoleCode? role;
  final DateTime now;

  /// Последний опрос не удался — показан последний известный статус.
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final (overallText, overallVariant) = SyncLabels.overall(l10n, status.overall);
    final running = status.entities.any((e) => e.running);
    final staleStatus = now.difference(status.checkedAt) > const Duration(minutes: 2);
    final indicator = status.never
        ? SyncIndicatorVariant.never
        : running
        ? SyncIndicatorVariant.syncing
        : status.overall == 'failed' || !status.onecReachable
        ? SyncIndicatorVariant.error
        : status.entities.any((e) => e.isStale)
        ? SyncIndicatorVariant.stale
        : SyncIndicatorVariant.ok;
    final last = status.lastSuccessAt;
    final outbox = status.outbox;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: context.space.s2,
            runSpacing: context.space.s2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              SyncIndicator(variant: indicator, time: last, now: now),
              StatusChip(
                label: status.onecReachable ? l10n.sync_onec_reachable : l10n.sync_onec_unreachable,
                variant: status.onecReachable ? StatusChipVariant.success : StatusChipVariant.error,
              ),
              StatusChip(label: overallText, variant: overallVariant),
            ],
          ),
          SizedBox(height: context.space.s3),
          Text(
            last == null ? l10n.sync_never : l10n.sync_last_success(_time(context, last, now)),
            style: context.text.body.copyWith(color: context.colors.textPrimary),
          ),
          if (!status.onecReachable) ...<Widget>[
            SizedBox(height: context.space.s1),
            Text(l10n.ds_onec_down, style: context.text.caption.copyWith(color: context.colors.warning)),
          ],
          SizedBox(height: context.space.s1),
          Text(
            l10n.sync_checked_at(_time(context, status.checkedAt, now)),
            style: context.text.caption.copyWith(
              color: failed || staleStatus ? context.colors.warning : context.colors.textSecondary,
            ),
          ),
          if (outbox != null && SyncRunPolicy.seesOutboxCounts(role)) ...<Widget>[
            SizedBox(height: context.space.s2),
            Text(
              l10n.sync_outbox_counts('${outbox.dead}', '${outbox.failed}', '${outbox.pending}'),
              style: context.text.caption.copyWith(color: context.colors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

/// Офлайн: «Каталог на устройстве обновлён HH:MM» по `sync_meta`.
class _LocalSummary extends StatelessWidget {
  const _LocalSummary({required this.freshness, required this.now});

  final DataFreshness freshness;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final at = freshness.lastSuccessAt ?? freshness.asOf;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SyncIndicator(variant: SyncIndicatorVariant.offline, time: at, now: now),
          SizedBox(height: context.space.s2),
          Text(
            at == null ? l10n.sync_never : l10n.sync_local_updated_at(_time(context, at, now)),
            style: context.text.body.copyWith(color: context.colors.textPrimary),
          ),
        ],
      ),
    );
  }
}

/// Время магазина (Asia/Bishkek) относительно «сейчас» экрана — не часов и пояса машины.
String _time(BuildContext context, DateTime t, DateTime now) => dsTimeLabel(context, t, nowUtc: now);

class _Tabs extends StatelessWidget {
  const _Tabs({required this.tabs, required this.selected, required this.onSelect});

  final List<SyncStatusTab> tabs;
  final SyncStatusTab selected;
  final ValueChanged<SyncStatusTab> onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    String label(SyncStatusTab t) => switch (t) {
      SyncStatusTab.entities => l10n.sync_tab_entities,
      SyncStatusTab.runs => l10n.sync_tab_runs,
      SyncStatusTab.errors => l10n.sync_tab_errors,
      SyncStatusTab.outbox => l10n.sync_tab_outbox,
    };
    return SegmentedButton<SyncStatusTab>(
      segments: <ButtonSegment<SyncStatusTab>>[
        for (final SyncStatusTab t in tabs)
          ButtonSegment<SyncStatusTab>(
            value: t,
            label: Text(label(t), key: ValueKey<String>('sync-tab-${t.value}')),
          ),
      ],
      selected: <SyncStatusTab>{selected},
      showSelectedIcon: false,
      onSelectionChanged: (s) => onSelect(s.first),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.title, this.subtitle, this.trailing, this.below, this.onTap, super.key});

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? below;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => onTap == null
      ? _body(context)
      : Material(
          color: Colors.transparent,
          child: InkWell(onTap: onTap, hoverColor: context.colors.surfaceHover, child: _body(context)),
        );

  Widget _body(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 72),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: context.colors.border)),
    ),
    padding: EdgeInsets.symmetric(vertical: context.space.s2),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: context.text.body.copyWith(color: context.colors.textPrimary, fontWeight: FontWeight.w500),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: context.text.caption.copyWith(
                        color: context.colors.textSecondary,
                        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null) ...<Widget>[SizedBox(width: context.space.s2), trailing!],
          ],
        ),
        if (below != null) ...<Widget>[SizedBox(height: context.space.s2), below!],
      ],
    ),
  );
}

/// Строка сущности (UI-43-002, UI-43-004).
class _EntityRow extends StatelessWidget {
  const _EntityRow({
    required this.entity,
    required this.status,
    required this.role,
    required this.busy,
    required this.now,
    required this.onMenu,
    this.onTap,
  });

  final SyncEntity entity;
  final SyncServerEntity status;
  final RoleCode? role;
  final bool busy;
  final DateTime now;
  final VoidCallback onMenu;

  /// Переход к «Прогонам» с фильтром сущности (UI-43-002).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final parts = <String>[
      status.lastSuccessAt == null ? l10n.sync_never : l10n.ds_updated_at(_time(context, status.lastSuccessAt!, now)),
      if (status.intervalSec != null) l10n.sync_interval((status.intervalSec! / 60).ceil()),
      if (status.nextRunAt != null) l10n.sync_next_run(_time(context, status.nextRunAt!, now)),
    ];
    final chips = <Widget>[
      if (status.running || busy)
        StatusChip(label: l10n.status_sync_running, variant: StatusChipVariant.info, dense: true)
      else if (status.isStale)
        StatusChip(
          label: status.lastSuccessAt == null
              ? l10n.sync_never
              : l10n.ds_data_as_of(_time(context, status.lastSuccessAt!, now)),
          variant: StatusChipVariant.warning,
          icon: Icons.schedule_rounded,
          dense: true,
        ),
      if (status.consecutiveErrors > 0)
        AppBadge(count: status.consecutiveErrors, semanticLabel: l10n.sync_errors_count(status.consecutiveErrors)),
    ];
    // У `senior_seller` запуск трёх сущностей — кнопками зоны C (дублирующая кнопка в строке не выводится:
    // на compact она повторяла бы зону C); у `admin`/`owner` — меню строки «Запустить…» с предзаполнением.
    Widget? action;
    if (SyncRunPolicy.canOpenRunDialog(role)) {
      action = AppIconButton(
        key: ValueKey<String>('sync-row-menu-${entity.value}'),
        icon: Icons.more_vert_rounded,
        semanticLabel: l10n.sync_run_open_dialog,
        tooltip: l10n.sync_run_open_dialog,
        onPressed: onMenu,
      );
    }
    final progress = status.progress;
    return _Row(
      key: SyncStatusScreen.entityRowKey(entity),
      onTap: onTap,
      title: SyncLabels.entity(l10n, entity),
      subtitle: parts.join(' · '),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final c in chips)
            Padding(
              padding: EdgeInsets.only(left: context.space.s1),
              child: c,
            ),
          if (action != null)
            Padding(
              padding: EdgeInsets.only(left: context.space.s2),
              child: action,
            ),
        ],
      ),
      below: status.running && progress != null ? AppProgress.linear(value: progress) : null,
    );
  }
}

/// Вкладка «Прогоны» (UI-43-009).
class _RunsList extends ConsumerWidget {
  const _RunsList({
    required this.view,
    required this.now,
    required this.entity,
    required this.onEntity,
    required this.onOpen,
  });

  final SyncStatusViewState view;
  final DateTime now;

  /// Фильтр сущности (`null` — все).
  final SyncEntity? entity;
  final ValueChanged<SyncEntity?> onEntity;
  final ValueChanged<SyncRunInfo> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: SizedBox(
            width: 280,
            child: AppDropdown<String>(
              key: SyncStatusScreen.runsEntityFilterKey,
              label: l10n.sync_run_dialog_entity,
              value: entity?.value ?? '',
              items: <AppDropdownItem<String>>[
                AppDropdownItem<String>(value: '', label: l10n.admin_users_filter_all),
                for (final e in SyncRunPolicy.displayOrder)
                  AppDropdownItem<String>(value: e.value, label: SyncLabels.entity(l10n, e)),
              ],
              onChanged: (v) => onEntity(SyncEntity.tryParse(v)),
            ),
          ),
        ),
        SizedBox(height: context.space.s2),
        _list(context, ref, l10n),
      ],
    );
  }

  Widget _list(BuildContext context, WidgetRef ref, AppLocalizations l10n) {
    if (view.runsLoading && view.runs == null) {
      return Column(
        children: List<Widget>.generate(
          5,
          (_) => Padding(
            padding: EdgeInsets.symmetric(vertical: context.space.s1),
            child: const SkeletonBox(height: 56),
          ),
        ),
      );
    }
    if (view.runsFailure != null && view.runs == null) {
      final forbidden = view.runsFailure is PermissionFailure;
      return ErrorState.inline(
        message: forbidden ? l10n.error_forbidden : l10n.error_internal,
        onRetry: forbidden
            ? null
            : () => unawaited(ref.read(syncStatusControllerProvider.notifier).loadRuns(entity: entity)),
      );
    }
    final items = view.runs?.items ?? const <SyncRunInfo>[];
    if (items.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(context.space.s6),
        child: Text(
          l10n.sync_empty_runs,
          textAlign: TextAlign.center,
          style: context.text.body.copyWith(color: context.colors.textSecondary),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final r in items)
          Builder(
            builder: (context) {
              final (text, variant) = SyncLabels.runStatus(l10n, r);
              final mode = r.mode;
              return _Row(
                key: SyncStatusScreen.runRowKey(r.id),
                onTap: () => onOpen(r),
                title: SyncLabels.entityValue(l10n, r.entityValue),
                subtitle: <String>[
                  if (mode != null) SyncLabels.mode(l10n, mode),
                  SyncLabels.trigger(l10n, r),
                  if (r.startedAt != null) _time(context, r.startedAt!, now),
                ].join(' · '),
                trailing: StatusChip(label: text, variant: variant, dense: true),
              );
            },
          ),
      ],
    );
  }
}

/// Зона C (UI-43-003, UI-43-004, UI-43-005).
class _Actions extends ConsumerWidget {
  const _Actions({
    required this.role,
    required this.offline,
    required this.busy,
    required this.onQuick,
    required this.onOpenDialog,
  });

  final RoleCode? role;
  final bool offline;
  final Set<SyncEntity> busy;
  final ValueChanged<SyncEntity> onQuick;
  final VoidCallback onOpenDialog;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final blocked = ref.watch(manualSyncBlockedProvider);
    final compact = context.windowClass == WindowClass.compact;
    final children = <Widget>[];
    if (!SyncRunPolicy.canStartAny(role)) {
      children.add(
        Text(
          l10n.sync_permission_hint,
          key: SyncStatusScreen.permissionHintKey,
          style: context.text.caption.copyWith(color: context.colors.textSecondary),
        ),
      );
    } else {
      final disabled = offline || blocked;
      final quick = SyncRunPolicy.quickButtonsFor(role);
      final buttons = <Widget>[
        for (final e in quick)
          AppButton(
            key: SyncStatusScreen.quickButtonKey(e),
            label: busy.contains(e) ? l10n.sync_run_button_busy : SyncLabels.quickButton(l10n, e),
            variant: AppButtonVariant.outlined,
            expand: compact,
            loading: busy.contains(e),
            onPressed: disabled || busy.contains(e) ? null : () => onQuick(e),
          ),
        if (SyncRunPolicy.canOpenRunDialog(role))
          AppButton(
            key: SyncStatusScreen.runDialogButtonKey,
            label: l10n.sync_run_open_dialog,
            size: AppButtonSize.l,
            expand: compact,
            onPressed: disabled ? null : onOpenDialog,
          ),
      ];
      if (compact) {
        for (final b in buttons) {
          children.add(
            Padding(
              padding: EdgeInsets.only(top: context.space.s2),
              child: b,
            ),
          );
        }
      } else {
        children.add(
          Wrap(
            alignment: WrapAlignment.end,
            spacing: context.space.s2,
            runSpacing: context.space.s2,
            children: buttons,
          ),
        );
      }
      if (blocked) {
        children.add(
          Padding(
            padding: EdgeInsets.only(top: context.space.s2),
            child: Text(
              l10n.sync_manual_run_inbound_mode,
              key: SyncStatusScreen.inboundModeHintKey,
              style: context.text.caption.copyWith(color: context.colors.textSecondary),
            ),
          ),
        );
      }
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.colors.surface,
        border: Border(top: BorderSide(color: context.colors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(context.space.s4, context.space.s2, context.space.s4, context.space.s3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      ),
    );
  }
}
