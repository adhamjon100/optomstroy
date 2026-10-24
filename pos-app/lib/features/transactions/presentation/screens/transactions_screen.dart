// SCR-36 «Транзакции» (`/transactions?from=&to=&customerId=&status=&kind=&paymentMethod=&actorId=&q=&mine=`; роли
// `cashier`, `senior_seller`, `admin`, `owner` — все; `seller` — свои: `mine=1` принудительно). Владелец реализации —
// агент G-fe-cashier (RM-G-007, RM-G-012). Имя класса и параметры конструктора фиксированы маршрутом (routes.dart).
//
// Структура — 02 SCR-36.2: Z1 период (`DateRangePicker`, ≤ 366 дней) · Z2 поиск по номеру и чипы активных фильтров
// («Только мои» у `seller` — без ✕) · Z3 фильтры (compact/medium — `FilterSheet` с «Показать», expanded —
// постоянная `FilterPanel` 280 с применением сразу) · Z4 итог периода (`summary`, только `read.all`) · Z5 список
// `TransactionRow` с заголовками дней (compact/medium) или таблица 8 колонок (expanded) · курсорная подгрузка.
// Экспорт CSV в R1 нет (TXN-010, Q-217). Фильтры — в query маршрута (`go` без новой записи). Данные — только память.
import 'dart:async';

import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/core/models/transaction.dart';
import 'package:optomstroy/design_system/components/app_badge.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/category_chip.dart';
import 'package:optomstroy/design_system/components/date_range_picker.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/filter_panel.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart';
import 'package:optomstroy/design_system/components/search_bar.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/components/transaction_row.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/transactions/domain/entities/transactions_query.dart';
import 'package:optomstroy/features/transactions/presentation/providers/transactions_ports.dart';
import 'package:optomstroy/features/transactions/presentation/state/transactions_filters.dart';
import 'package:optomstroy/features/transactions/presentation/state/transactions_list_controller.dart';
import 'package:optomstroy/features/transactions/presentation/transactions_format.dart';
import 'package:optomstroy/features/transactions/presentation/widgets/transactions_filter_form.dart';

/// SCR-36. Транзакции `/transactions?from=&to=&customerId=&status=&kind=&paymentMethod=&actorId=&q=&mine=`.
class TransactionsScreen extends ConsumerStatefulWidget {
  /// Экран SCR-36.
  const TransactionsScreen({
    this.from,
    this.to,
    this.customerId,
    this.status,
    this.kind,
    this.paymentMethod,
    this.actorId,
    this.q,
    this.mine,
    super.key,
  });

  /// ID экрана (02 §4.1).
  static const String screenId = 'SCR-36';

  /// Ключ корня экрана (тесты маршрутов).
  static const ValueKey<String> rootKey = ValueKey<String>('stub-SCR-36');

  /// Начало периода (ISO-8601).
  final String? from;

  /// Конец периода (ISO-8601; период ≤ 366 дней).
  final String? to;

  /// Клиент.
  final String? customerId;

  /// Группы статусов через запятую (`TransactionStatusGroup`).
  final String? status;

  /// Виды через запятую (`TransactionKind`).
  final String? kind;

  /// Способ оплаты.
  final String? paymentMethod;

  /// Сотрудник (admin/owner).
  final String? actorId;

  /// Поиск.
  final String? q;

  /// `1` — только свои (seller — всегда).
  final String? mine;

  @override
  ConsumerState<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends ConsumerState<TransactionsScreen> {
  late TransactionsFilters _filters;
  late final TextEditingController _number;
  final FocusNode _numberFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  Timer? _debounce;
  bool _opening = false;

  DateTime get _now => ref.read(clockProvider).nowUtc();

  bool get _seller => ref.read(transactionsViewerRoleProvider) == RoleCode.seller;

  TransactionsListController get _ctl => ref.read(transactionsListControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    _filters = _fromRoute();
    _number = TextEditingController(text: _filters.q);
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_ctl.apply(_filters, force: true));
    });
  }

  TransactionsFilters _fromRoute() => TransactionsFilters.fromRoute(
    nowUtc: _now,
    forceMine: _seller,
    from: widget.from,
    to: widget.to,
    customerId: widget.customerId,
    status: widget.status,
    kind: widget.kind,
    paymentMethod: widget.paymentMethod,
    actorId: widget.actorId,
    q: widget.q,
    mine: widget.mine,
  );

  @override
  void didUpdateWidget(covariant TransactionsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final TransactionsFilters route = _fromRoute();
    if (route != _filters) {
      _filters = route.copyWith(
        customerName: () => route.customerId == _filters.customerId ? _filters.customerName : null,
      );
      final TransactionsFilters next = _filters;
      // Провайдер меняется после кадра (Riverpod запрещает изменения во время сборки дерева).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_ctl.apply(next));
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _number.dispose();
    _numberFocus.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 400) unawaited(_ctl.loadMore());
  }

  /// Применить фильтры: query маршрута (`go`, без новой записи истории) + запрос первой страницы.
  void _apply(TransactionsFilters f, {bool debounce = false}) {
    final TransactionsFilters next = _seller ? f.copyWith(mine: true) : f;
    setState(() => _filters = next);
    void run() {
      if (!mounted) return;
      unawaited(_ctl.apply(next));
      context.txGo(TransactionsLocations.list(next.toRoute()));
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }

    _debounce?.cancel();
    if (debounce) {
      _debounce = Timer(const Duration(milliseconds: 300), run);
    } else {
      run();
    }
  }

  void _reset() {
    final TransactionsFilters d = TransactionsFilters.defaults(_now, mine: _seller);
    _number.clear();
    _apply(d);
  }

  Future<void> _open(Transaction t) async {
    if (_opening) return;
    _opening = true;
    try {
      await context.txPush(TransactionsLocations.details(t.id));
    } finally {
      _opening = false;
    }
  }

  Future<void> _openSheet(bool showActor) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    TransactionsFilters draft = _filters;
    final TransactionsFilters? applied = await showModalBottomSheet<TransactionsFilters>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: context.colors.overlay,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.92, maxWidth: 640),
      builder: (BuildContext ctx) => ClipRRect(
        borderRadius: ctx.radii.sheetTop,
        child: StatefulBuilder(
          builder: (BuildContext ctx, StateSetter set) => FilterSheet(
            title: l10n.catalog_filters_button,
            activeCount: draft.activeCount,
            resetLabel: l10n.transactions_reset_all,
            closeLabel: l10n.ds_button_close,
            applyLabel: l10n.ds_button_apply,
            onClose: () => Navigator.of(ctx).pop(),
            onReset: () => set(() => draft = TransactionsFilters.defaults(_now, mine: _seller)),
            onApply: () => Navigator.of(ctx).pop(draft),
            sections: <Widget>[
              TransactionsFilterSections(
                filters: draft,
                showActor: showActor,
                showNumberSearch: true,
                onChanged: (TransactionsFilters f) => set(() => draft = f),
              ),
            ],
          ),
        ),
      ),
    );
    if (applied != null && mounted) {
      _number.text = applied.q;
      _apply(applied);
    }
  }

  Future<void> _copyNumber(Transaction t) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    await Clipboard.setData(ClipboardData(text: t.number));
    if (mounted) AppSnackbar.show(context, message: l10n.ds_copied);
  }

  // ---------------------------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final TransactionsListState s = ref.watch(transactionsListControllerProvider);
    final RoleCode? role = ref.watch(transactionsViewerRoleProvider);
    final WindowClass wc = context.windowClass;
    final bool expanded = wc == WindowClass.expanded || wc == WindowClass.large;
    final bool showActor = role == RoleCode.admin || role == RoleCode.owner;
    final DsColors c = context.colors;
    final Widget main = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (s.offline && s.items.isNotEmpty && s.loadedAt != null)
          OfflineBanner(
            variant: OfflineBannerVariant.offline,
            message: l10n.transactions_offline_stale(DsBishkekTime.stamp(s.loadedAt!, _now)),
          ),
        _toolbar(context, l10n, s, role, expanded, showActor),
        if (_filters.periodRejected)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: context.space.s4),
            child: ErrorState.banner(
              key: const ValueKey<String>('tx-period-rejected'),
              message: l10n.transactions_period_too_long('${DateRangePicker.journalMaxDays}'),
              tone: ErrorStateTone.warning,
            ),
          ),
        if (s.filterFailed)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: context.space.s4),
            child: ErrorState.banner(
              key: const ValueKey<String>('tx-filter-failed'),
              message: l10n.transactions_filter_failed,
              onRetry: () => unawaited(_ctl.refresh()),
            ),
          ),
        if (s.filtering) const AppProgress.linear(),
        if (s.summary != null && role != RoleCode.seller) _summary(context, l10n, s.summary!),
        Expanded(
          child: AnimatedOpacity(
            opacity: s.filtering && !context.motion.reduceMotion ? 0.5 : 1,
            duration: context.motion.of(context.motion.fast),
            child: _content(context, l10n, s, expanded),
          ),
        ),
      ],
    );
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.f5): () => unawaited(_ctl.refresh()),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
          if (expanded) {
            _numberFocus.requestFocus();
          } else {
            unawaited(_openSheet(showActor));
          }
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: TransactionsScreen.rootKey,
          backgroundColor: c.background,
          appBar: AppBar(title: Text(l10n.transactions_title)),
          body: expanded
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(child: main),
                    FilterPanel(
                      key: const ValueKey<String>('tx-filter-panel'),
                      width: 320,
                      title: l10n.catalog_filters_button,
                      activeCount: _filters.activeCount,
                      resetLabel: l10n.ds_button_reset,
                      closeLabel: l10n.ds_button_close,
                      onReset: _filters.activeCount == 0 ? null : _reset,
                      sections: <Widget>[
                        TransactionsFilterSections(
                          filters: _filters,
                          showActor: showActor,
                          onChanged: (TransactionsFilters f) => _apply(f, debounce: true),
                        ),
                      ],
                    ),
                  ],
                )
              : main,
        ),
      ),
    );
  }

  Widget _toolbar(
    BuildContext context,
    AppLocalizations l10n,
    TransactionsListState s,
    RoleCode? role,
    bool expanded,
    bool showActor,
  ) {
    final TransactionsFilters f = _filters;
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final List<Widget> chips = <Widget>[
      if (role == RoleCode.seller)
        CategoryChip(
          key: const ValueKey<String>('tx-chip-mine-fixed'),
          label: l10n.transactions_only_mine,
          variant: CategoryChipVariant.choice,
          selected: true,
        )
      else if (f.mine)
        CategoryChip(
          key: const ValueKey<String>('tx-chip-mine'),
          label: l10n.transactions_only_mine,
          variant: CategoryChipVariant.input,
          selected: true,
          removeLabel: l10n.ds_button_reset,
          onRemove: () => _apply(f.copyWith(mine: false)),
        ),
      if (f.customerId != null)
        CategoryChip(
          key: const ValueKey<String>('tx-chip-customer'),
          label: f.customerName ?? l10n.transactions_filter_customer,
          variant: CategoryChipVariant.input,
          selected: true,
          removeLabel: l10n.ds_button_reset,
          onRemove: () => _apply(f.copyWith(customerId: () => null, customerName: () => null)),
        ),
      for (final TransactionStatusGroup g in f.statuses)
        CategoryChip(
          key: ValueKey<String>('tx-chip-status-${g.value}'),
          label: TransactionsTexts.status(l10n, g),
          variant: CategoryChipVariant.input,
          selected: true,
          removeLabel: l10n.ds_button_reset,
          onRemove: () => _apply(f.copyWith(statuses: <TransactionStatusGroup>{...f.statuses}..remove(g))),
        ),
      for (final TransactionKind k in f.kinds)
        CategoryChip(
          key: ValueKey<String>('tx-chip-kind-${k.value}'),
          label: TransactionsTexts.kind(l10n, k),
          variant: CategoryChipVariant.input,
          selected: true,
          removeLabel: l10n.ds_button_reset,
          onRemove: () => _apply(f.copyWith(kinds: <TransactionKind>{...f.kinds}..remove(k))),
        ),
      if (f.paymentMethod != null)
        CategoryChip(
          key: const ValueKey<String>('tx-chip-method'),
          label: TransactionsTexts.method(l10n, f.paymentMethod!),
          variant: CategoryChipVariant.input,
          selected: true,
          removeLabel: l10n.ds_button_reset,
          onRemove: () => _apply(f.copyWith(paymentMethod: () => null)),
        ),
      if (f.actorId != null)
        CategoryChip(
          key: const ValueKey<String>('tx-chip-actor'),
          label: l10n.transactions_filter_actor,
          variant: CategoryChipVariant.input,
          selected: true,
          removeLabel: l10n.ds_button_reset,
          onRemove: () => _apply(f.copyWith(actorId: () => null)),
        ),
      if (f.q.isNotEmpty && !expanded)
        CategoryChip(
          key: const ValueKey<String>('tx-chip-q'),
          label: f.q,
          variant: CategoryChipVariant.input,
          selected: true,
          removeLabel: l10n.ds_button_reset,
          onRemove: () {
            _number.clear();
            _apply(f.copyWith(q: ''));
          },
        ),
    ];
    final bool canReset = f.activeCount > 0 || f.q.isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(context.space.s4, context.space.s3, context.space.s4, context.space.s2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              DateRangePicker(
                value: f.period,
                nowUtc: _now,
                semanticLabel: DsBishkekTime.rangeText(f.period.fromUtc, f.period.toUtc, locale),
                onChanged: (DateRangeValue v) => _apply(f.copyWith(period: v)),
              ),
              SizedBox(width: context.space.s3),
              if (expanded)
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: SearchBar(
                      key: const ValueKey<String>('tx-search-number'),
                      variant: SearchBarVariant.customers,
                      controller: _number,
                      focusNode: _numberFocus,
                      placeholder: l10n.transactions_search_number,
                      semanticLabel: l10n.transactions_search_number,
                      onChanged: (String v) => _apply(f.copyWith(q: v.trim()), debounce: true),
                      onSubmitted: (String v) => _apply(f.copyWith(q: v.trim())),
                    ),
                  ),
                )
              else ...<Widget>[
                const Spacer(),
                AppButton(
                  key: const ValueKey<String>('tx-filters-button'),
                  label: l10n.transactions_filters(f.activeCount),
                  icon: Icons.tune_rounded,
                  variant: AppButtonVariant.outlined,
                  size: AppButtonSize.s,
                  onPressed: () => unawaited(_openSheet(showActor)),
                ),
              ],
            ],
          ),
          if (chips.isNotEmpty) ...<Widget>[
            SizedBox(height: context.space.s2),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  for (int i = 0; i < chips.length; i++) ...<Widget>[
                    if (i > 0) SizedBox(width: context.space.s2),
                    chips[i],
                  ],
                  if (canReset) ...<Widget>[
                    SizedBox(width: context.space.s2),
                    AppButton(
                      key: const ValueKey<String>('tx-reset-all'),
                      label: l10n.transactions_reset_all,
                      variant: AppButtonVariant.text,
                      size: AppButtonSize.s,
                      onPressed: _reset,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _summary(BuildContext context, AppLocalizations l10n, TransactionsSummary sum) {
    final DsColors c = context.colors;
    final TextStyle v = context.text.bodyLg.copyWith(fontWeight: FontWeight.w700, fontFeatures: DsTypography.numeric);
    return Container(
      key: const ValueKey<String>('tx-summary'),
      padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s2),
      child: Wrap(
        spacing: context.space.s4,
        runSpacing: context.space.s1,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Text.rich(
            TextSpan(
              children: <InlineSpan>[
                TextSpan(
                  text: '${l10n.transactions_sum_in}: ',
                  style: context.text.body.copyWith(color: c.textSecondary),
                ),
                TextSpan(
                  text: '+${TransactionsTexts.money(sum.sumIn)}',
                  style: v.copyWith(color: c.success),
                ),
              ],
            ),
          ),
          Text.rich(
            TextSpan(
              children: <InlineSpan>[
                TextSpan(
                  text: '${l10n.transactions_sum_out}: ',
                  style: context.text.body.copyWith(color: c.textSecondary),
                ),
                TextSpan(
                  text: '−${TransactionsTexts.money(sum.sumOut)}',
                  style: v.copyWith(color: c.textPrimary),
                ),
              ],
            ),
          ),
          Text(
            l10n.transactions_sum_count(sum.count),
            style: context.text.body.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context, AppLocalizations l10n, TransactionsListState s, bool expanded) {
    switch (s.phase) {
      case TransactionsPhase.loading:
        return ListView(
          children: <Widget>[
            for (int i = 0; i < 8; i++)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s1),
                child: const SkeletonBox(height: 56),
              ),
          ],
        );
      case TransactionsPhase.error:
        final UiError e = UiErrorMapper.fromFailure(s.failure ?? const UnknownFailure());
        return ErrorState.fullScreen(
          title: l10n.transactions_title,
          message: ErrorTexts.message(l10n, e),
          requestId: e.requestId,
          onRetry: () => unawaited(_ctl.refresh()),
        );
      case TransactionsPhase.offline:
        return EmptyState(
          key: const ValueKey<String>('tx-offline'),
          variant: EmptyStateVariant.offlineNoCache,
          title: l10n.transactions_offline,
          actionLabel: l10n.ds_button_retry,
          onAction: () => unawaited(_ctl.refresh()),
        );
      case TransactionsPhase.empty:
        final bool hasFilters = _filters.differsFrom(TransactionsFilters.defaults(_now, mine: _filters.mine));
        return EmptyState(
          key: const ValueKey<String>('tx-empty'),
          variant: EmptyStateVariant.transactions,
          title: l10n.transactions_empty,
          actionLabel: l10n.transactions_period_custom,
          onAction: () async {
            final DateRangeValue? v = await DateRangePicker.pick(context, value: _filters.period, nowUtc: _now);
            if (v != null && mounted) _apply(_filters.copyWith(period: v));
          },
          secondaryActionLabel: hasFilters ? l10n.transactions_reset_all : null,
          onSecondaryAction: hasFilters ? _reset : null,
        );
      case TransactionsPhase.list:
        return RefreshIndicator(
          onRefresh: _ctl.refresh,
          child: expanded ? _table(context, l10n, s) : _list(context, l10n, s),
        );
    }
  }

  Widget _footer(BuildContext context, AppLocalizations l10n, TransactionsListState s) {
    if (s.loadingMore) {
      return Padding(padding: EdgeInsets.all(context.space.s4), child: const SkeletonBox(height: 48));
    }
    if (s.loadMoreFailure != null) {
      return Padding(
        padding: EdgeInsets.all(context.space.s4),
        child: ErrorState.inline(
          message: ErrorTexts.message(l10n, UiErrorMapper.fromFailure(s.loadMoreFailure!)),
          onRetry: () => unawaited(_ctl.loadMore()),
        ),
      );
    }
    if (!s.hasMore) {
      return Padding(
        padding: EdgeInsets.all(context.space.s4),
        child: Text(
          l10n.transactions_end,
          key: const ValueKey<String>('tx-end'),
          textAlign: TextAlign.center,
          style: context.text.caption.copyWith(color: context.colors.textSecondary),
        ),
      );
    }
    return SizedBox(height: context.space.s8);
  }

  Widget _list(BuildContext context, AppLocalizations l10n, TransactionsListState s) {
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final DateTime now = _now;
    final bool compact = context.windowClass == WindowClass.compact;
    final List<Widget> rows = <Widget>[];
    DateTime? day;
    for (final Transaction t in s.items) {
      final DateTime d = DsBishkekTime.startOfDayUtc(t.occurredAt);
      if (d != day) {
        day = d;
        rows.add(TransactionDayHeader(label: TransactionsTexts.dayHeader(l10n, t.occurredAt, now, locale)));
      }
      final bool fromOnec = t.source == TransactionSource.onec;
      rows.add(
        TransactionRow(
          key: ValueKey<String>('tx-row-${t.id}'),
          kind: t.kind,
          title: <String>[TransactionsTexts.title(l10n, t), ?t.customer?.displayName].join(' · '),
          subtitle: <String>[
            DsBishkekTime.time(t.occurredAt),
            if (!fromOnec) ?t.actor?.displayName else l10n.transactions_source_onec,
          ].join(' · '),
          amountText: TransactionsTexts.money(t.amount),
          tone: TransactionsTexts.tone(t),
          status: TransactionsTexts.statusChip(l10n, t),
          compactWindow: compact,
          semanticLabel: TransactionsTexts.semantic(l10n, t, locale),
          onTap: () => unawaited(_open(t)),
          onLongPress: () => unawaited(_copyNumber(t)),
        ),
      );
    }
    return ListView(
      key: const ValueKey<String>('tx-list'),
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      children: <Widget>[...rows, _footer(context, l10n, s)],
    );
  }

  static const List<int> _flex = <int>[3, 2, 3, 3, 3, 3, 2];

  Widget _table(BuildContext context, AppLocalizations l10n, TransactionsListState s) {
    final DsColors c = context.colors;
    final TextStyle head = context.text.label.copyWith(color: c.textSecondary, fontWeight: FontWeight.w600);
    final List<String> cols = <String>[
      l10n.transactions_filter_kind,
      l10n.orders_col_number,
      l10n.orders_col_date,
      l10n.orders_col_customer,
      l10n.orders_col_total,
      l10n.orders_col_status,
      l10n.transaction_details_related,
    ];
    Widget cell(int i, Widget child, {bool end = false}) => Expanded(
      flex: _flex[i],
      child: Padding(
        padding: EdgeInsetsDirectional.only(end: context.space.s2),
        child: Align(alignment: end ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart, child: child),
      ),
    );
    Widget headCell(int i) {
      final bool sortable = i == 2 || i == 4;
      final TransactionsSort? sort = i == 2
          ? TransactionsSort.occurredAtDesc
          : (i == 4 ? TransactionsSort.amountDesc : null);
      final Widget text = Text(cols[i], maxLines: 1, overflow: TextOverflow.ellipsis, style: head);
      return cell(
        i,
        sortable
            ? InkWell(
                key: ValueKey<String>('tx-sort-${sort!.name}'),
                onTap: () => unawaited(_ctl.setSort(sort)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Flexible(child: text),
                    if (s.sort == sort) Icon(Icons.arrow_downward_rounded, size: 16, color: c.textSecondary),
                  ],
                ),
              )
            : text,
        end: i == 4,
      );
    }

    final TextStyle body = context.text.body.copyWith(color: c.textPrimary, fontFeatures: DsTypography.numeric);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          height: 40,
          padding: EdgeInsets.symmetric(horizontal: context.space.s4),
          decoration: BoxDecoration(
            color: c.surfaceVariant,
            border: Border(bottom: BorderSide(color: c.border)),
          ),
          child: Row(children: <Widget>[for (int i = 0; i < cols.length; i++) headCell(i)]),
        ),
        Expanded(
          child: ListView(
            key: const ValueKey<String>('tx-table'),
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            children: <Widget>[
              for (final Transaction t in s.items)
                Semantics(
                  button: true,
                  label: TransactionsTexts.semantic(l10n, t, Localizations.localeOf(context).toLanguageTag()),
                  excludeSemantics: true,
                  child: GestureDetector(
                    onSecondaryTap: () => unawaited(_copyNumber(t)),
                    child: DsInteractive(
                      key: ValueKey<String>('tx-row-${t.id}'),
                      onTap: () => unawaited(_open(t)),
                      onLongPress: () => unawaited(_copyNumber(t)),
                      builder: (BuildContext ctx, DsInteractionState st) {
                        final TransactionRowAmountTone tone = TransactionsTexts.tone(t);
                        final StatusChip? status = TransactionsTexts.statusChip(l10n, t);
                        final bool fromOnec = t.source == TransactionSource.onec;
                        return Container(
                          height: 48,
                          padding: EdgeInsets.symmetric(horizontal: context.space.s4),
                          decoration: BoxDecoration(
                            color: st.pressed
                                ? c.surfacePressed
                                : (st.hovered || st.focused ? c.surfaceHover : c.surface),
                            border: Border(bottom: BorderSide(color: c.border)),
                          ),
                          child: Row(
                            children: <Widget>[
                              cell(
                                0,
                                Row(
                                  children: <Widget>[
                                    Icon(TransactionRow.iconOf(t.kind), size: 20, color: c.textSecondary),
                                    SizedBox(width: context.space.s2),
                                    Flexible(
                                      child: Text(
                                        TransactionsTexts.kind(l10n, t.kind),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: body,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              cell(
                                1,
                                Row(
                                  children: <Widget>[
                                    Flexible(
                                      child: Text(t.number, maxLines: 1, overflow: TextOverflow.ellipsis, style: body),
                                    ),
                                    if (fromOnec) ...<Widget>[
                                      SizedBox(width: context.space.s1),
                                      StatusChip(
                                        label: l10n.transactions_source_onec,
                                        variant: StatusChipVariant.neutral,
                                        dense: true,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              cell(2, Text(DsBishkekTime.dateTime(t.occurredAt), maxLines: 1, style: body)),
                              cell(
                                3,
                                Text(
                                  t.customer?.displayName ?? '—',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: body,
                                ),
                              ),
                              cell(
                                4,
                                Text(
                                  TransactionRow.signed(TransactionsTexts.money(t.amount), tone),
                                  maxLines: 1,
                                  style: body.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: tone == TransactionRowAmountTone.incoming ? c.success : c.textPrimary,
                                  ),
                                ),
                                end: true,
                              ),
                              cell(5, status ?? const SizedBox.shrink()),
                              cell(
                                6,
                                t.related.isEmpty
                                    ? const SizedBox.shrink()
                                    : AppBadge(
                                        count: t.related.length,
                                        tone: AppBadgeTone.cart,
                                        semanticLabel: l10n.transaction_details_related,
                                      ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              _footer(context, l10n, s),
            ],
          ),
        ),
      ],
    );
  }
}
