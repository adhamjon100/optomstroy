// SCR-47 «Аудит» (`/admin/audit?from=&to=&userId=&action=&entityType=&entityId=&result=`; admin — без финансовых
// before/after (маскирует сервер), owner — полно; 02 ч. E SCR-47; RM-G-008, RM-G-012; D-36, 11 §7).
//
// Период обязателен (по умолчанию «Сегодня», ≤ 366 дней — больший блокируется текстом `audit_period_error`), прочие
// фильтры — лист (compact) / боковая панель (medium) / панель 280 справа (expanded); активные фильтры — чипы с
// крестиком; все параметры — в URL (AC-UI-47-008). Список `AuditRow` с группировкой по дням, курсорная подгрузка
// (по 100), деталь — отдельный экран (compact) или боковой лист 400/480. `chainOk=false` — «Нарушена целостность» в
// строке, детали и баннером над списком (AC-UI-47-014). Записи только читаются; экспорта CSV в R1 нет (Q-217).
// Журнал не кэшируется (ядро §18.2 п. 1): офлайн — EmptyState offlineNoCache.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/core/models/audit_record.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/cancel_signal.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/audit_row.dart';
import 'package:optomstroy/design_system/components/category_chip.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/admin/domain/audit/audit_log.dart';
import 'package:optomstroy/features/admin/domain/users/admin_user.dart';
import 'package:optomstroy/features/admin/presentation/audit/audit_labels.dart';
import 'package:optomstroy/features/admin/presentation/audit/widgets/audit_detail.dart';
import 'package:optomstroy/features/admin/presentation/audit/widgets/audit_filters.dart';
import 'package:optomstroy/features/admin/presentation/common/admin_format.dart';
import 'package:optomstroy/features/admin/presentation/common/admin_nav_menu.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/admin_labels.dart';

/// SCR-47. Аудит `/admin/audit?from=&to=&userId=&action=&entityType=&entityId=&result=` (admin, owner).
class AuditScreen extends ConsumerStatefulWidget {
  /// Экран SCR-47.
  const AuditScreen({
    this.from,
    this.to,
    this.userId,
    this.action,
    this.entityType,
    this.entityId,
    this.result,
    super.key,
  });

  /// ID экрана (02 §4.1).
  static const String screenId = 'SCR-47';

  /// Начало периода (ISO-8601).
  final String? from;

  /// Конец периода (ISO-8601; ≤ 366 дней).
  final String? to;

  /// Сотрудник (`actorId` API).
  final String? userId;

  /// Префикс кода события.
  final String? action;

  /// Тип объекта.
  final String? entityType;

  /// ID объекта.
  final String? entityId;

  /// `ok|denied|error`.
  final String? result;

  /// Ключи для тестов.
  static const Key screenKey = ValueKey<String>('scr-47');
  static const Key filtersButtonKey = ValueKey<String>('audit-filters-button');
  static const Key periodErrorKey = ValueKey<String>('audit-period-error');
  static const Key integrityBannerKey = ValueKey<String>('audit-integrity-banner');
  static const Key loadMoreKey = ValueKey<String>('audit-load-more');
  static const Key refreshKey = ValueKey<String>('audit-refresh');
  static const Key panelKey = ValueKey<String>('audit-filter-panel');
  static Key presetKey(AuditPeriodPreset p) => ValueKey<String>('audit-period-${p.name}');
  static Key rowKey(String id) => ValueKey<String>('audit-row-$id');
  static Key activeChipKey(String name) => ValueKey<String>('audit-active-$name');

  /// Размер страницы (UI-47-010: по 100, ≤ 200).
  static const int pageSize = 100;

  @override
  ConsumerState<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends ConsumerState<AuditScreen> {
  late AuditPeriod _period;
  bool _periodError = false;
  late AuditFilters _filters;

  List<AuditRecord> _items = const <AuditRecord>[];
  String? _cursor;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  Failure? _failure;
  int _req = 0;

  /// Быстрая смена фильтров отменяет предыдущий запрос (SCR-47.11, CancelToken — D-31); уход с экрана — тоже.
  final CancelSignalSeries _requests = CancelSignalSeries();
  String? _selectedId;
  List<AuditUserOption> _users = const <AuditUserOption>[];

  DateTime get _now => ref.read(clockProvider).nowUtc();
  AuditLogRepository get _repo => ref.read(auditLogRepositoryProvider);

  @override
  void initState() {
    super.initState();
    final AuditPeriod? fromUrl = AdminFormat.fromQuery(widget.from, widget.to, _now);
    _period = fromUrl ?? AdminFormat.preset(AuditPeriodPreset.today, _now);
    _periodError = fromUrl == null;
    _filters = AuditFilters.fromQuery(
      userId: widget.userId,
      action: widget.action,
      entityType: widget.entityType,
      entityId: widget.entityId,
      result: widget.result,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_reload());
      unawaited(_loadUsers());
    });
  }

  @override
  void dispose() {
    _requests.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------------ данные

  AuditQuery _query({String? cursor}) => AuditQuery(
    period: _period.period,
    actorId: _filters.actorId,
    action: _filters.action,
    entityType: _filters.entityType,
    entityId: _filters.entityId,
    result: _filters.result,
    limit: AuditScreen.pageSize,
    cursor: cursor,
  );

  Future<void> _reload() async {
    final int req = ++_req;
    final CancelSignal signal = _requests.next();
    setState(() {
      _loading = true;
      _failure = null;
    });
    final Result<PageResult<AuditRecord>> r = await _repo.list(_query(), cancel: signal);
    if (!mounted || req != _req) return;
    setState(() {
      _loading = false;
      switch (r) {
        case Success<PageResult<AuditRecord>>(:final value):
          _items = value.items;
          _cursor = value.nextCursor;
          _hasMore = value.hasMore && value.nextCursor != null;
          if (_selectedId != null && !_items.any((AuditRecord a) => a.id == _selectedId)) _selectedId = null;
        case FailureResult<PageResult<AuditRecord>>(:final failure):
          _failure = failure;
          _items = const <AuditRecord>[];
          _hasMore = false;
          if (failure is ValidationFailure) _periodError = true;
      }
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _cursor == null) return;
    final int req = _req;
    setState(() => _loadingMore = true);
    final Result<PageResult<AuditRecord>> r = await _repo.list(_query(cursor: _cursor));
    if (!mounted || req != _req) return;
    setState(() {
      _loadingMore = false;
      if (r case Success<PageResult<AuditRecord>>(:final value)) {
        _items = <AuditRecord>[..._items, ...value.items];
        _cursor = value.nextCursor;
        _hasMore = value.hasMore && value.nextCursor != null;
      }
    });
  }

  /// Список сотрудников для фильтра (UI-47-006, `GET /admin/users`); ошибка не мешает журналу.
  Future<void> _loadUsers() async {
    final Result<AdminPage<AdminUser>> r = await ref
        .read(adminUsersRepositoryProvider)
        .listUsers(const AdminUsersQuery());
    if (!mounted) return;
    if (r case Success<AdminPage<AdminUser>>(:final value)) {
      setState(
        () => _users = <AuditUserOption>[
          for (final AdminUser u in value.items) AuditUserOption(id: u.id, label: u.fullName ?? u.id),
        ],
      );
    }
  }

  // ------------------------------------------------------------------ действия

  void _syncUrl() {
    final GoRouter? router = GoRouter.maybeOf(context);
    if (router == null) return;
    router.go(
      Uri(
        path: '/admin/audit',
        queryParameters: <String, String>{
          'from': AdminFormat.iso(_period.period.from),
          'to': AdminFormat.iso(_period.period.to),
          'userId': ?_filters.actorId,
          'action': ?_filters.action,
          'entityType': ?_filters.entityType,
          'entityId': ?_filters.entityId,
          'result': ?_filters.result?.value,
        },
      ).toString(),
    );
  }

  Future<void> _choosePreset(AuditPeriodPreset p) async {
    AuditPeriod? next;
    if (p == AuditPeriodPreset.custom) {
      next = await _pickRange();
      if (next == null) return;
    } else {
      next = AdminFormat.preset(p, _now);
    }
    if (!mounted) return;
    setState(() {
      _period = next!;
      _periodError = false;
    });
    _syncUrl();
    unawaited(_reload());
  }

  Future<AuditPeriod?> _pickRange() async {
    final DateTime now = AdminFormat.wall(_now);
    final DateTime from = AdminFormat.wall(_period.period.from);
    final DateTime to = AdminFormat.wall(_period.period.to.subtract(const Duration(minutes: 1)));
    final DateTimeRange? range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: DateTimeRange(
        start: DateTime(from.year, from.month, from.day),
        end: DateTime(to.year, to.month, to.day),
      ),
    );
    if (range == null) return null;
    DateTime dayUtc(DateTime d) => DateTime.utc(d.year, d.month, d.day, 12).subtract(AdminFormat.bishkekOffset);
    final AuditPeriod? picked = AdminFormat.days(dayUtc(range.start), dayUtc(range.end));
    // Период > 366 дней не применяется (AC-UI-47-002).
    if (picked == null && mounted) setState(() => _periodError = true);
    return picked;
  }

  void _applyFilters(AuditFilters f, {bool closeSheet = false}) {
    if (closeSheet) unawaited(Navigator.of(context).maybePop());
    setState(() => _filters = f);
    _syncUrl();
    unawaited(_reload());
  }

  void _resetFilters({bool closeSheet = false}) {
    if (closeSheet) unawaited(Navigator.of(context).maybePop());
    setState(() {
      _filters = const AuditFilters();
      _period = AdminFormat.preset(AuditPeriodPreset.today, _now);
      _periodError = false;
    });
    _syncUrl();
    unawaited(_reload());
  }

  Future<void> _openFilters(WindowClass wc) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    Widget form() => AuditFiltersForm(
      initial: _filters,
      users: _users,
      onApply: (AuditFilters f) => _applyFilters(f, closeSheet: true),
      onReset: () => _resetFilters(closeSheet: true),
    );
    if (wc == WindowClass.compact) {
      await AppBottomSheet.show<void>(
        context,
        title: l10n.audit_filters_button(_filters.count),
        body: form(),
        variant: AppBottomSheetVariant.fullHeight,
      );
    } else {
      await AppBottomSheet.showSide<void>(
        context,
        title: l10n.audit_filters_button(_filters.count),
        width: AppBottomSheet.sideMedium,
        body: form(),
      );
    }
  }

  Future<void> _open(AuditRecord r, WindowClass wc) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Widget detail = AuditDetail(record: r, integrityLabel: _integrityLabel(l10n));
    setState(() => _selectedId = r.id);
    if (wc == WindowClass.compact) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext ctx) => Scaffold(
            appBar: AppBar(title: Text(AuditLabels.action(l10n, r.action))),
            body: SingleChildScrollView(padding: EdgeInsets.all(ctx.space.s4), child: detail),
          ),
        ),
      );
    } else {
      await AppBottomSheet.showSide<void>(
        context,
        title: l10n.audit_title,
        width: wc == WindowClass.medium ? AppBottomSheet.sideMedium : AppBottomSheet.sideExpanded,
        body: detail,
      );
    }
    if (mounted) setState(() => _selectedId = null);
  }

  /// Подпись нарушения целостности. Ключа «Нарушена целостность» (03 §9.62) в словаре 02 §7 нет — GQ-FEADM-01:
  /// временно общая подпись результата «Ошибка» с глифом `link_off`.
  static String _integrityLabel(AppLocalizations l10n) => l10n.audit_result_error;

  // ------------------------------------------------------------------ разметка

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final WindowClass wc = context.windowClass;
    final bool expanded = wc == WindowClass.expanded || wc == WindowClass.large;

    final Widget list = _list(context, l10n, wc);
    final Widget body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _toolbar(context, l10n, wc),
        Divider(height: 1, thickness: 1, color: context.colors.border),
        Expanded(
          child: expanded
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1200), child: list),
                      ),
                    ),
                    VerticalDivider(width: 1, thickness: 1, color: context.colors.border),
                    SizedBox(
                      width: 280,
                      child: SingleChildScrollView(
                        key: AuditScreen.panelKey,
                        padding: EdgeInsets.all(context.space.s4),
                        child: AuditFiltersForm(
                          key: ValueKey<AuditFilters>(_filters),
                          initial: _filters,
                          users: _users,
                          onApply: _applyFilters,
                          onReset: _resetFilters,
                        ),
                      ),
                    ),
                  ],
                )
              : list,
        ),
      ],
    );

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.f5): () => unawaited(_reload()),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: AuditScreen.screenKey,
          appBar: AppBar(
            title: Text(l10n.audit_title),
            actions: <Widget>[
              AppIconButton(
                key: AuditScreen.refreshKey,
                icon: Icons.refresh_rounded,
                semanticLabel: l10n.ds_button_retry,
                tooltip: l10n.ds_button_retry,
                loading: _loading,
                onPressed: _loading ? null : () => unawaited(_reload()),
              ),
              const AdminNavMenu(current: AdminSection.audit),
              SizedBox(width: context.space.s2),
            ],
          ),
          body: body,
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context, AppLocalizations l10n, WindowClass wc) {
    final bool expanded = wc == WindowClass.expanded || wc == WindowClass.large;
    final String? actorLabel = _filters.actorId == null
        ? null
        : (_users.where((AuditUserOption u) => u.id == _filters.actorId).firstOrNull?.label ?? _filters.actorId);
    final List<(String, String, AuditFilters)> active = <(String, String, AuditFilters)>[
      if (actorLabel != null)
        (
          'user',
          actorLabel,
          AuditFilters(
            action: _filters.action,
            entityType: _filters.entityType,
            entityId: _filters.entityId,
            result: _filters.result,
          ),
        ),
      if (_filters.action != null)
        (
          'action',
          _filters.action!,
          AuditFilters(
            actorId: _filters.actorId,
            entityType: _filters.entityType,
            entityId: _filters.entityId,
            result: _filters.result,
          ),
        ),
      if (_filters.entityType != null || _filters.entityId != null)
        (
          'object',
          <String?>[_filters.entityType, _filters.entityId].whereType<String>().join(' · '),
          AuditFilters(actorId: _filters.actorId, action: _filters.action, result: _filters.result),
        ),
      if (_filters.result != null)
        (
          'result',
          AuditLabels.result(l10n, _filters.result),
          AuditFilters(
            actorId: _filters.actorId,
            action: _filters.action,
            entityType: _filters.entityType,
            entityId: _filters.entityId,
          ),
        ),
    ];
    return Padding(
      padding: EdgeInsets.fromLTRB(context.space.s4, context.space.s3, context.space.s4, context.space.s2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Wrap(
                  spacing: context.space.s2,
                  runSpacing: context.space.s2,
                  children: <Widget>[
                    for (final AuditPeriodPreset p in AuditPeriodPreset.values)
                      IntrinsicWidth(
                        child: CategoryChip(
                          key: AuditScreen.presetKey(p),
                          label: p == AuditPeriodPreset.custom && _period.preset == AuditPeriodPreset.custom
                              ? AdminFormat.range(_period.period)
                              : AdminFormat.presetLabel(l10n, p),
                          selected: _period.preset == p,
                          onTap: () => unawaited(_choosePreset(p)),
                        ),
                      ),
                  ],
                ),
              ),
              if (!expanded) ...<Widget>[
                SizedBox(width: context.space.s2),
                AppButton(
                  key: AuditScreen.filtersButtonKey,
                  label: l10n.audit_filters_button(_filters.count),
                  variant: AppButtonVariant.outlined,
                  icon: Icons.filter_list_rounded,
                  onPressed: () => unawaited(_openFilters(wc)),
                ),
              ],
            ],
          ),
          if (_periodError) ...<Widget>[
            SizedBox(height: context.space.s2),
            Text(
              l10n.audit_period_error,
              key: AuditScreen.periodErrorKey,
              style: context.text.caption.copyWith(color: context.colors.error),
            ),
          ],
          if (active.isNotEmpty) ...<Widget>[
            SizedBox(height: context.space.s2),
            Wrap(
              spacing: context.space.s2,
              runSpacing: context.space.s2,
              children: <Widget>[
                for (final (String name, String label, AuditFilters without) in active)
                  IntrinsicWidth(
                    child: CategoryChip(
                      key: AuditScreen.activeChipKey(name),
                      label: label,
                      variant: CategoryChipVariant.input,
                      selected: true,
                      removeLabel: l10n.ds_button_reset,
                      onRemove: () => _applyFilters(without),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _list(BuildContext context, AppLocalizations l10n, WindowClass wc) {
    final bool compact = wc == WindowClass.compact;
    if (_loading && _items.isEmpty) {
      return ListView(children: <Widget>[for (int i = 0; i < 10; i++) AuditRow.skeleton(compact: compact)]);
    }
    final Failure? failure = _failure;
    if (failure != null) {
      if (failure is NetworkFailure) {
        return EmptyState(
          variant: EmptyStateVariant.offlineNoCache,
          title: l10n.ds_sync_offline,
          actionLabel: l10n.ds_button_retry,
          onAction: () => unawaited(_reload()),
        );
      }
      if (failure is PermissionFailure) {
        return EmptyState(variant: EmptyStateVariant.noPermission, title: l10n.error_forbidden);
      }
      if (failure is ValidationFailure) {
        return EmptyState(
          variant: EmptyStateVariant.search,
          title: l10n.audit_period_error,
          actionLabel: l10n.audit_empty_action,
          onAction: () => unawaited(_choosePreset(AuditPeriodPreset.custom)),
        );
      }
      return ErrorState.fullScreen(
        title: l10n.audit_title,
        message: ErrorTexts.message(l10n, UiErrorMapper.fromFailure(failure)),
        onRetry: () => unawaited(_reload()),
        requestId: failure.requestId,
      );
    }
    if (_items.isEmpty) {
      return EmptyState(
        variant: EmptyStateVariant.search,
        title: l10n.audit_empty_title,
        actionLabel: l10n.audit_empty_action,
        onAction: () => unawaited(_choosePreset(AuditPeriodPreset.custom)),
      );
    }
    final bool broken = _items.any((AuditRecord r) => !r.chainOk);
    final List<Widget> children = <Widget>[
      if (broken)
        Padding(
          key: AuditScreen.integrityBannerKey,
          padding: EdgeInsets.all(context.space.s3),
          child: ErrorState.banner(message: _integrityLabel(l10n)),
        ),
    ];
    String? day;
    for (final AuditRecord r in _items) {
      final String d = AdminFormat.date(r.occurredAt);
      if (d != day) {
        day = d;
        children.add(
          Padding(
            padding: EdgeInsets.fromLTRB(context.space.s4, context.space.s3, context.space.s4, context.space.s1),
            child: Text(d, style: context.text.caption.copyWith(color: context.colors.textSecondary)),
          ),
        );
      }
      children.add(
        AuditRow(
          key: AuditScreen.rowKey(r.id),
          compact: compact,
          icon: AuditRow.iconFor(r.action),
          actionLabel: AuditLabels.action(l10n, r.action),
          timeLabel: compact ? AdminFormat.dateTimeSeconds(r.occurredAt) : AdminFormat.timeSeconds(r.occurredAt),
          actorLabel: <String?>[
            r.actor?.displayName,
            if (r.actorRole != null) AdminLabels.role(l10n, r.actorRole!),
          ].whereType<String>().join(' · '),
          objectLabel: <String?>[r.entityType, r.entityId].whereType<String>().join(' · '),
          deviceLabel: r.deviceId,
          resultLabel: AuditLabels.result(l10n, r.result),
          resultVariant: AuditLabels.resultVariant(r.result),
          integrityBroken: !r.chainOk,
          integrityLabel: _integrityLabel(l10n),
          selected: r.id == _selectedId,
          onTap: () => unawaited(_open(r, wc)),
        ),
      );
      children.add(Divider(height: 1, thickness: 1, color: context.colors.border));
    }
    if (_hasMore) {
      children.add(
        Padding(
          padding: EdgeInsets.all(context.space.s4),
          child: Center(
            child: _loadingMore
                ? const AppProgress.circular()
                : AppButton(
                    key: AuditScreen.loadMoreKey,
                    label: l10n.ds_button_more,
                    variant: AppButtonVariant.text,
                    onPressed: () => unawaited(_loadMore()),
                  ),
          ),
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification n) {
        if (n.metrics.extentAfter < 200 && _hasMore && !_loadingMore) unawaited(_loadMore());
        return false;
      },
      child: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(physics: const AlwaysScrollableScrollPhysics(), children: children),
      ),
    );
  }
}
