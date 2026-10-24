// Содержимое SCR-33 «История покупок» (02 SCR-33.2–SCR-33.8): фильтры (пресеты периода, «Период…», источник),
// сводка периода из `CustomerHistory.summary` (клиент итог не считает), метка глубины истории 1С, строки с иконкой
// вида и группировкой по месяцам, раскрытие строки («Открыть заказ» → SCR-24), подгрузка по курсору. Подпись «Долг —
// только по данным 1С» — всегда (DEBT-001, AC-UI-33-004).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/app_tabs.dart';
import 'package:optomstroy/design_system/components/category_chip.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/order_status_chip.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_history.dart';
import 'package:optomstroy/features/customers/presentation/customers_format.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/customers/presentation/state/customer_history_controller.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_states.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customers_nav.dart';

/// Ключи (тесты).
abstract final class CustomerHistoryKeys {
  static const Key list = ValueKey<String>('customer-history-list');
  static const Key debtNote = ValueKey<String>('customer-history-debt-note');
  static const Key empty = ValueKey<String>('customer-history-empty');
  static Key preset(HistoryPreset p) => ValueKey<String>('customer-history-preset-${p.name}');
  static Key entry(String key) => ValueKey<String>('customer-history-entry-$key');
}

/// SCR-33 (тело).
class CustomerHistoryView extends ConsumerStatefulWidget {
  /// Создаёт тело SCR-33.
  const CustomerHistoryView({required this.args, super.key});

  final CustomerHistoryArgs args;

  @override
  ConsumerState<CustomerHistoryView> createState() => _CustomerHistoryViewState();
}

class _CustomerHistoryViewState extends ConsumerState<CustomerHistoryView> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final ScrollPosition p = _scroll.position;
    if (p.pixels >= p.maxScrollExtent * .8) {
      unawaited(ref.read(customerHistoryProvider(widget.args).notifier).loadMore());
    }
  }

  Future<void> _pickRange(CustomerHistoryState s) async {
    final DateTime now = ref.read(clockProvider).nowUtc();
    final DateTimeRange? range = await showDateRangePicker(
      context: context,
      firstDate: DateTime.utc(now.year - 5),
      lastDate: CustomersFormat.wall(now),
      initialDateRange: DateTimeRange(start: CustomersFormat.wall(s.from), end: CustomersFormat.wall(s.to)),
    );
    if (range == null || !mounted) return;
    final DateTime from = DateTime.utc(
      range.start.year,
      range.start.month,
      range.start.day,
    ).subtract(CustomersFormat.bishkekOffset);
    final DateTime to = DateTime.utc(
      range.end.year,
      range.end.month,
      range.end.day,
      23,
      59,
      59,
    ).subtract(CustomersFormat.bishkekOffset);
    if (!CustomerHistoryController.validRange(from, to)) {
      AppSnackbar.show(
        context,
        message: AppLocalizations.of(context).customer_history_range_invalid,
        variant: AppSnackbarVariant.error,
      );
      return;
    }
    await ref.read(customerHistoryProvider(widget.args).notifier).setRange(from, to);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CustomersViewer viewer = ref.watch(customersViewerProvider);
    if (!viewer.canReadHistory) return CustomerStates.forbidden(context);
    final CustomerHistoryState s = ref.watch(customerHistoryProvider(widget.args));
    final CustomerHistoryController ctl = ref.read(customerHistoryProvider(widget.args).notifier);
    final DsColors c = context.colors;
    final DateTime now = ref.watch(clockProvider).nowUtc();
    final Widget filters = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        spacing: 8,
        children: <Widget>[
          for (final (HistoryPreset p, String label) in <(HistoryPreset, String)>[
            (HistoryPreset.days30, l10n.customer_history_preset_30),
            (HistoryPreset.days90, l10n.customer_history_preset_90),
            (HistoryPreset.year, l10n.customer_history_preset_year),
          ])
            CategoryChip(
              key: CustomerHistoryKeys.preset(p),
              label: label,
              selected: s.preset == p,
              onTap: () => unawaited(ctl.setPreset(p)),
            ),
          CategoryChip(
            key: CustomerHistoryKeys.preset(HistoryPreset.custom),
            label: s.preset == HistoryPreset.custom
                ? '${CustomersFormat.date(s.from)} – ${CustomersFormat.date(s.to)}'
                : l10n.customer_history_preset_custom,
            icon: Icons.calendar_month_rounded,
            selected: s.preset == HistoryPreset.custom,
            onTap: () => unawaited(_pickRange(s)),
          ),
        ],
      ),
    );
    final Widget source = SizedBox(
      width: 420,
      child: AppTabs<CustomerHistorySource>(
        variant: AppTabsVariant.segmented,
        value: s.source,
        onChanged: (CustomerHistorySource v) => unawaited(ctl.setSource(v)),
        tabs: <AppTab<CustomerHistorySource>>[
          AppTab<CustomerHistorySource>(value: CustomerHistorySource.all, label: l10n.customer_history_source_all),
          AppTab<CustomerHistorySource>(value: CustomerHistorySource.pos, label: l10n.customer_history_source_pos),
          AppTab<CustomerHistorySource>(value: CustomerHistorySource.onec, label: l10n.customer_history_source_onec),
        ],
      ),
    );
    final List<Widget> header = <Widget>[
      filters,
      SizedBox(height: context.space.s3),
      Align(alignment: Alignment.centerLeft, child: source),
      SizedBox(height: context.space.s4),
      if (s.summary != null) _Summary(summary: s.summary!),
      Padding(
        padding: EdgeInsets.only(top: context.space.s2),
        child: Row(
          key: CustomerHistoryKeys.debtNote,
          children: <Widget>[
            Icon(Icons.info_outline_rounded, size: 16, color: c.textSecondary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l10n.customer_history_debt_note,
                style: context.text.caption.copyWith(color: c.textSecondary),
              ),
            ),
          ],
        ),
      ),
      Padding(
        padding: EdgeInsets.only(top: context.space.s1),
        child: Text(
          s.historyFrom != null
              ? l10n.customer_history_depth(CustomersFormat.plainDate(s.historyFrom!))
              : l10n.customer_history_depth_unknown,
          style: context.text.caption.copyWith(color: c.textSecondary),
        ),
      ),
      if (s.asOf != null)
        Padding(
          padding: EdgeInsets.only(top: context.space.s1),
          child: Text(
            l10n.customer_history_onec_as_of(CustomersFormat.stamp(s.asOf!, now)),
            style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
          ),
        ),
      SizedBox(height: context.space.s3),
    ];
    final List<Widget> body;
    switch (s.phase) {
      case CustomerHistoryPhase.loading:
        body = <Widget>[
          for (int i = 0; i < 5; i++)
            Padding(
              padding: EdgeInsets.only(bottom: context.space.s2),
              child: const SkeletonBox(height: 64),
            ),
        ];
      case CustomerHistoryPhase.offline:
        return CustomerStates.offline(l10n.customer_history_offline);
      case CustomerHistoryPhase.forbidden:
        return CustomerStates.forbidden(context);
      case CustomerHistoryPhase.notFound:
        return CustomerStates.notFound(context, () => CustomersNav.toList(context));
      case CustomerHistoryPhase.error:
        body = <Widget>[
          ErrorState.inline(message: CustomerStates.message(l10n, s.failure), onRetry: () => unawaited(ctl.load())),
        ];
      case CustomerHistoryPhase.empty:
        body = <Widget>[
          EmptyState(
            key: CustomerHistoryKeys.empty,
            variant: EmptyStateVariant.orders,
            title: l10n.customer_history_empty,
            actionLabel: l10n.customer_history_change_period,
            onAction: () => unawaited(_pickRange(s)),
          ),
        ];
      case CustomerHistoryPhase.list:
        body = <Widget>[..._rows(context, l10n, s, ctl)];
    }
    return ListView(
      key: CustomerHistoryKeys.list,
      controller: _scroll,
      padding: EdgeInsets.all(context.space.s4),
      children: <Widget>[...header, ...body],
    );
  }

  List<Widget> _rows(
    BuildContext context,
    AppLocalizations l10n,
    CustomerHistoryState s,
    CustomerHistoryController ctl,
  ) {
    final DsColors c = context.colors;
    final List<Widget> out = <Widget>[];
    String? month;
    final MaterialLocalizations ml = MaterialLocalizations.of(context);
    for (final CustomerHistoryEntry e in s.entries) {
      final DateTime w = CustomersFormat.wall(e.date);
      final String m = ml.formatMonthYear(DateTime(w.year, w.month));
      if (m != month) {
        month = m;
        out.add(
          Container(
            height: 32,
            alignment: Alignment.centerLeft,
            padding: EdgeInsets.symmetric(horizontal: context.space.s3),
            color: c.surfaceVariant,
            child: Text(
              m,
              style: context.text.label.copyWith(fontWeight: FontWeight.w600, color: c.textPrimary),
            ),
          ),
        );
      }
      out.add(_EntryRow(entry: e, expanded: s.expanded.contains(entryKey(e)), onToggle: () => ctl.toggle(e)));
    }
    if (s.loadingMore) {
      out.add(
        Padding(
          padding: EdgeInsets.only(top: context.space.s2),
          child: const SkeletonBox(height: 64),
        ),
      );
    } else if (s.loadMoreFailed) {
      out.add(ErrorState.inline(message: l10n.error_internal, onRetry: () => unawaited(ctl.loadMore())));
    } else if (!s.hasMore) {
      out.add(
        Padding(
          padding: EdgeInsets.symmetric(vertical: context.space.s3),
          child: Text(
            l10n.customer_history_end,
            textAlign: TextAlign.center,
            style: context.text.caption.copyWith(color: c.textSecondary),
          ),
        ),
      );
    }
    return out;
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.summary});

  final CustomerHistorySummary summary;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    Widget tile(String text) => Expanded(
      child: Container(
        padding: EdgeInsets.all(context.space.s3),
        decoration: BoxDecoration(color: c.surfaceVariant, borderRadius: BorderRadius.all(context.radii.md)),
        child: Text(
          text,
          style: context.text.title.copyWith(
            fontWeight: FontWeight.w700,
            fontFeatures: DsTypography.numeric,
            color: c.textPrimary,
          ),
        ),
      ),
    );
    return Row(
      children: <Widget>[
        tile(l10n.customer_history_total(CustomersFormat.money(summary.total))),
        SizedBox(width: context.space.s3),
        tile(l10n.customer_history_count(summary.count)),
      ],
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry, required this.expanded, required this.onToggle});

  final CustomerHistoryEntry entry;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final bool reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final OrderStatus? orderStatus = entry.kind == CustomerHistoryKind.order
        ? OrderStatus.tryParse(entry.status)
        : null;
    final bool canOpen = entry.kind == CustomerHistoryKind.order && entry.id != null;
    return Semantics(
      container: true,
      button: true,
      expanded: expanded,
      child: DsInteractive(
        key: CustomerHistoryKeys.entry(entryKey(entry)),
        onTap: onToggle,
        onLongPress: () {
          unawaited(Clipboard.setData(ClipboardData(text: entry.number)));
          AppSnackbar.show(context, message: l10n.ds_copied);
        },
        builder: (BuildContext context, DsInteractionState st) => Container(
          decoration: BoxDecoration(
            color: st.pressed ? c.surfacePressed : (st.hovered || st.focused ? c.surfaceHover : c.surface),
            border: Border(bottom: BorderSide(color: c.border)),
          ),
          padding: EdgeInsets.symmetric(horizontal: context.space.s3, vertical: context.space.s2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(CustomersTexts.historyIcon(entry.kind), size: 20, color: c.textSecondary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          entry.number,
                          style: context.text.body.copyWith(fontWeight: FontWeight.w500, color: c.textPrimary),
                        ),
                        Text(
                          CustomersFormat.date(entry.date),
                          style: context.text.caption.copyWith(
                            color: c.textSecondary,
                            fontFeatures: DsTypography.numeric,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Text(
                        CustomersFormat.money(entry.total),
                        style: context.text.bodyLg.copyWith(
                          fontWeight: FontWeight.w700,
                          fontFeatures: DsTypography.numeric,
                          color: c.textPrimary,
                        ),
                      ),
                      if (orderStatus != null)
                        OrderStatusChip(status: orderStatus, dense: true)
                      else
                        StatusChip(label: entry.status, variant: StatusChipVariant.neutral, dense: true),
                    ],
                  ),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: expanded ? .5 : 0,
                    duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 200),
                    child: Icon(Icons.expand_more_rounded, color: c.textSecondary),
                  ),
                ],
              ),
              AnimatedSize(
                duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 200),
                alignment: Alignment.topCenter,
                child: !expanded
                    ? const SizedBox(width: double.infinity) // money-double: allow — геометрия UI (ширина строки)
                    : Padding(
                        padding: EdgeInsets.only(left: context.space.s7, top: context.space.s2),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: canOpen
                              ? AppButton(
                                  label: l10n.customer_history_open_order,
                                  variant: AppButtonVariant.text,
                                  size: AppButtonSize.s,
                                  trailingIcon: Icons.chevron_right_rounded,
                                  onPressed: () => CustomersNav.openOrder(context, entry.id!),
                                )
                              : Text(entry.number, style: context.text.caption.copyWith(color: c.textSecondary)),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
