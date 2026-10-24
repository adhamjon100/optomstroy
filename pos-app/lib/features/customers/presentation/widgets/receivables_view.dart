// Содержимое SCR-34 «Долги и взаиморасчёты» (02 SCR-34.2–SCR-34.8): отдельный экран (compact/medium) и вкладка
// «Долги» карточки SCR-32 на expanded ([embedded]). Z1–Z4 — [DebtSummaryPanel]; Z5 — заглушка с замком до step-up
// (документы до подтверждения не запрашиваются и не рисуются), затем чипы типов и строки/таблица; Z6 — «Принять оплату
// по долгу» (`cashier`/`senior_seller`, `features.debtPaymentsFromPos`).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_section_header.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/category_chip.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/receivable_document_row.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/customers/domain/entities/receivable.dart';
import 'package:optomstroy/features/customers/presentation/customers_format.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/customers/presentation/state/customer_receivables_controller.dart';
import 'package:optomstroy/features/customers/presentation/state/debt_snapshot.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_states.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customers_nav.dart';
import 'package:optomstroy/features/customers/presentation/widgets/debt_refresh_feedback.dart';
import 'package:optomstroy/features/customers/presentation/widgets/debt_summary_panel.dart';

/// Ключи (тесты).
abstract final class ReceivablesKeys {
  static const Key locked = ValueKey<String>('receivables-detail-locked');
  static const Key show = ValueKey<String>('receivables-detail-show');
  static const Key cancelled = ValueKey<String>('receivables-detail-cancelled');
  static const Key openUntil = ValueKey<String>('receivables-detail-open-until');
  static const Key documents = ValueKey<String>('receivables-documents');
  static const Key acceptPayment = ValueKey<String>('receivables-accept-payment');
  static Key filter(String name) => ValueKey<String>('receivables-filter-$name');
  static Key document(int i) => ValueKey<String>('receivables-doc-$i');
}

/// SCR-34 (тело).
class ReceivablesView extends ConsumerWidget {
  /// Создаёт тело SCR-34.
  const ReceivablesView({required this.customerId, this.embedded = false, super.key});

  final String customerId;

  /// Вкладка внутри SCR-32 (без собственной колонки сводки и нижней CTA).
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CustomersViewer viewer = ref.watch(customersViewerProvider);
    if (!viewer.canReadReceivables) return CustomerStates.forbidden(context);
    final CustomerReceivablesState s = ref.watch(customerReceivablesProvider(customerId));
    final CustomerReceivablesController ctl = ref.read(customerReceivablesProvider(customerId).notifier);
    switch (s.phase) {
      case ReceivablesPhase.loading:
        return const _Skeleton();
      case ReceivablesPhase.offline:
        return CustomerStates.offline(l10n.receivables_offline);
      case ReceivablesPhase.forbidden:
        return CustomerStates.forbidden(context);
      case ReceivablesPhase.notFound:
        return CustomerStates.notFound(context, () => CustomersNav.toList(context));
      case ReceivablesPhase.error:
        return CustomerStates.error(
          context,
          title: l10n.receivables_load_error,
          failure: s.failure,
          onRetry: () => unawaited(ctl.load()),
        );
      case ReceivablesPhase.ready:
        break;
    }
    final Receivable r = s.receivable!;
    final DateTime now = ref.watch(clockProvider).nowUtc();
    final bool online = ref.watch(customersOnlineProvider);
    final DebtSnapshot snapshot = DebtSnapshot.fromReceivable(r);
    final bool rateLimited = s.rateLimitedUntil != null && now.isBefore(s.rateLimitedUntil!);
    Future<void> refresh() async {
      final outcome = await ctl.refresh();
      if (context.mounted) showDebtRefreshOutcome(context, outcome, ref.read(clockProvider).nowUtc());
    }

    final Widget summary = DebtSummaryPanel(
      snapshot: snapshot,
      nowUtc: now,
      large: !embedded,
      // Статус продажи в долг — для оформления сотрудником; клиент в долг не оформляет (10 CUST-024; RM-G-014).
      showCreditStatus: !viewer.isCustomer,
      refreshVisibleWhenFresh: true,
      refreshing: s.refreshing,
      offlineLabel: s.fromMemory && r.asOf != null
          ? '${l10n.ds_data_as_of(CustomersFormat.stamp(r.asOf!, now))} · ${l10n.ds_sync_offline}'
          : null,
      onRefresh: viewer.canRefreshReceivables && online && !rateLimited && !s.fromMemory
          ? () => unawaited(refresh())
          : null,
    );
    final bool debtPayments = ref.watch(customerDebtPaymentsEnabledProvider);
    final Widget? cta = viewer.canAcceptDebtPayment && debtPayments
        ? AppButton(
            key: ReceivablesKeys.acceptPayment,
            label: l10n.receivables_accept_payment,
            icon: Icons.payments_outlined,
            size: AppButtonSize.l,
            expand: true,
            onPressed: online && !snapshot.notInOnec && (snapshot.balance ?? Money.zero) > Money.zero
                ? () => CustomersNav.acceptDebtPayment(context, customerId)
                : null,
          )
        : null;
    final Widget detail = snapshot.noData
        ? const SizedBox.shrink()
        : _Detail(customerId: customerId, state: s, now: now);
    final WindowClass wc = context.windowClass;
    final bool wide = !embedded && (wc == WindowClass.expanded || wc == WindowClass.large);
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: ListView(padding: EdgeInsets.all(context.space.s6), children: <Widget>[detail]),
          ),
          SizedBox(
            width: 340,
            child: ListView(
              padding: EdgeInsets.fromLTRB(0, context.space.s6, context.space.s6, context.space.s6),
              children: <Widget>[
                summary,
                if (cta != null) ...<Widget>[SizedBox(height: context.space.s4), cta],
              ],
            ),
          ),
        ],
      );
    }
    final Widget list = RefreshIndicator(
      onRefresh: refresh,
      notificationPredicate: (_) => viewer.canRefreshReceivables && online,
      child: ListView(
        padding: EdgeInsets.all(embedded ? 0 : context.space.s4),
        children: <Widget>[
          summary,
          SizedBox(height: context.space.s4),
          detail,
          if (cta != null && embedded) ...<Widget>[SizedBox(height: context.space.s4), cta],
        ],
      ),
    );
    if (cta == null || embedded) return list;
    return Column(
      children: <Widget>[
        Expanded(child: list),
        Container(
          padding: EdgeInsets.all(context.space.s4),
          decoration: BoxDecoration(
            color: context.colors.surface,
            border: Border(top: BorderSide(color: context.colors.border)),
          ),
          child: SafeArea(top: false, child: cta),
        ),
      ],
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.all(context.space.s4),
    children: const <Widget>[
      SkeletonBox(height: 96),
      SizedBox(height: 12),
      SkeletonBox(height: 8),
      SizedBox(height: 16),
      SkeletonBox(height: 56),
      SizedBox(height: 8),
      SkeletonBox(height: 56),
      SizedBox(height: 8),
      SkeletonBox(height: 56),
    ],
  );
}

/// Z5 — детализация.
class _Detail extends ConsumerWidget {
  const _Detail({required this.customerId, required this.state, required this.now});

  final String customerId;
  final CustomerReceivablesState state;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final CustomerReceivablesController ctl = ref.read(customerReceivablesProvider(customerId).notifier);
    final bool reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final Widget child;
    if (state.detail != ReceivablesDetailPhase.ready) {
      final bool loading = state.detail == ReceivablesDetailPhase.loading;
      child = Container(
        key: ReceivablesKeys.locked,
        constraints: const BoxConstraints(minHeight: 200),
        padding: EdgeInsets.all(context.space.s6),
        decoration: BoxDecoration(color: c.surfaceVariant, borderRadius: BorderRadius.all(context.radii.md)),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(Icons.lock_outline_rounded, size: 32, color: c.textSecondary),
            const SizedBox(height: 12),
            Text(
              l10n.receivables_detail_locked_title,
              textAlign: TextAlign.center,
              style: context.text.title.copyWith(color: c.textPrimary),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.receivables_detail_locked_body,
              textAlign: TextAlign.center,
              style: context.text.body.copyWith(color: c.textSecondary),
            ),
            const SizedBox(height: 16),
            AppButton(
              key: ReceivablesKeys.show,
              label: l10n.receivables_detail_show,
              icon: Icons.lock_open_rounded,
              loading: loading,
              onPressed: loading || state.fromMemory ? null : () => unawaited(ctl.showDetail()),
            ),
            if (state.detail == ReceivablesDetailPhase.cancelled)
              Padding(
                padding: EdgeInsets.only(top: context.space.s2),
                child: Text(
                  l10n.receivables_detail_cancelled,
                  key: ReceivablesKeys.cancelled,
                  style: context.text.caption.copyWith(color: c.textSecondary),
                ),
              ),
            if (state.detail == ReceivablesDetailPhase.error)
              Padding(
                padding: EdgeInsets.only(top: context.space.s2),
                child: ErrorState.inline(
                  message: CustomerStates.message(l10n, state.detailFailure),
                  onRetry: () => unawaited(ctl.showDetail()),
                ),
              ),
          ],
        ),
      );
    } else {
      child = _Documents(customerId: customerId, state: state, now: now);
    }
    return AnimatedSwitcher(
      duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 200),
      child: KeyedSubtree(key: ValueKey<bool>(state.detail == ReceivablesDetailPhase.ready), child: child),
    );
  }
}

class _Documents extends ConsumerWidget {
  const _Documents({required this.customerId, required this.state, required this.now});

  final String customerId;
  final CustomerReceivablesState state;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final CustomerReceivablesController ctl = ref.read(customerReceivablesProvider(customerId).notifier);
    final List<ReceivableDocument>? docs = state.receivable?.documents;
    final List<Widget> out = <Widget>[
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AppSectionHeader(title: l10n.receivables_detail_locked_title, padding: EdgeInsets.zero),
          if (state.detailUntil != null)
            Row(
              key: ReceivablesKeys.openUntil,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.lock_open_rounded, size: 16, color: c.textSecondary),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    l10n.receivables_detail_open_until(CustomersFormat.time(state.detailUntil!)),
                    style: context.text.caption.copyWith(color: c.textSecondary),
                  ),
                ),
              ],
            ),
        ],
      ),
      const SizedBox(height: 8),
    ];
    if (docs == null) {
      out.add(EmptyState(variant: EmptyStateVariant.transactions, title: l10n.receivables_detail_not_kept));
      return Column(key: ReceivablesKeys.documents, crossAxisAlignment: CrossAxisAlignment.stretch, children: out);
    }
    if (docs.isEmpty) {
      out.add(EmptyState(variant: EmptyStateVariant.transactions, title: l10n.receivables_detail_empty));
      return Column(key: ReceivablesKeys.documents, crossAxisAlignment: CrossAxisAlignment.stretch, children: out);
    }
    int count(ReceivablesDocFilter f) => docs.where((ReceivableDocument d) => receivableDocMatches(d, f)).length;
    final bool hasDiscounts = count(ReceivablesDocFilter.discounts) > 0;
    final List<(ReceivablesDocFilter, String)> chips = <(ReceivablesDocFilter, String)>[
      (ReceivablesDocFilter.shipments, l10n.receivables_filter_shipments),
      (ReceivablesDocFilter.payments, l10n.receivables_filter_payments),
      (ReceivablesDocFilter.returns, l10n.receivables_filter_returns),
      (ReceivablesDocFilter.overdue, l10n.receivables_filter_overdue),
      if (hasDiscounts) (ReceivablesDocFilter.discounts, l10n.receivables_filter_discounts),
    ];
    final List<ReceivableDocument> shown = state.filters.isEmpty
        ? docs
        : <ReceivableDocument>[
            for (final ReceivableDocument d in docs)
              if (state.filters.any((ReceivablesDocFilter f) => receivableDocMatches(d, f))) d,
          ];
    out.add(
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            CategoryChip(
              key: ReceivablesKeys.filter('all'),
              label: l10n.receivables_filter_all,
              count: docs.length,
              variant: CategoryChipVariant.filter,
              selected: state.filters.isEmpty,
              onTap: () => ctl.toggleFilter(null),
            ),
            for (final (ReceivablesDocFilter f, String label) in chips) ...<Widget>[
              const SizedBox(width: 8),
              CategoryChip(
                key: ReceivablesKeys.filter(f.name),
                label: label,
                count: count(f),
                variant: CategoryChipVariant.filter,
                selected: state.filters.contains(f),
                onTap: () => ctl.toggleFilter(f),
              ),
            ],
          ],
        ),
      ),
    );
    out.add(const SizedBox(height: 8));
    final WindowClass wc = context.windowClass;
    final bool table = wc == WindowClass.expanded || wc == WindowClass.large;
    final List<Widget> rows = <Widget>[for (int i = 0; i < shown.length; i++) _row(context, l10n, shown[i], i, table)];
    if (table) {
      out.add(
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints bc) {
            final double width = bc.maxWidth < 900 ? 900 : bc.maxWidth; // money-double: allow — ширина таблицы (lp)
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: width,
                child: Column(
                  children: <Widget>[
                    ReceivableDocumentRow.header(context, <String>[
                      l10n.receivables_col_date,
                      l10n.receivables_col_document,
                      l10n.receivables_col_status,
                      l10n.receivables_col_amount,
                      l10n.receivables_col_paid,
                      l10n.receivables_col_remaining,
                      l10n.receivables_col_due,
                      l10n.receivables_col_overdue_days,
                    ]),
                    ...rows,
                  ],
                ),
              ),
            );
          },
        ),
      );
    } else {
      out.addAll(rows);
    }
    return Column(key: ReceivablesKeys.documents, crossAxisAlignment: CrossAxisAlignment.stretch, children: out);
  }

  Widget _row(BuildContext context, AppLocalizations l10n, ReceivableDocument d, int i, bool table) {
    final bool negative = d.kind == ReceivableDocumentKind.payment || d.kind == ReceivableDocumentKind.returnValue;
    String money(Money m) =>
        negative && !m.isNegative && !m.isZero ? CustomersFormat.money(-m) : CustomersFormat.money(m);
    final Money? remaining = d.remaining;
    final int overdueDays = d.overdueDays ?? 0;
    final (String? status, StatusChipVariant variant) = remaining != null && remaining.isZero
        ? (l10n.receivables_doc_paid, StatusChipVariant.success)
        : (d.dueDate != null && overdueDays <= 0
              ? (l10n.receivables_doc_due_until(CustomersFormat.plainDate(d.dueDate!)), StatusChipVariant.warning)
              : (null, StatusChipVariant.neutral));
    final String title = d.number ?? CustomersTexts.documentKind(l10n, d.kind);
    return ReceivableDocumentRow(
      key: ReceivablesKeys.document(i),
      icon: CustomersTexts.documentIcon(d.kind),
      title: title,
      date: d.date == null ? null : CustomersFormat.plainDate(d.date!),
      amount: money(d.amount),
      paid: d.paid == null ? null : CustomersFormat.money(d.paid!),
      remaining: remaining == null ? null : CustomersFormat.money(remaining),
      due: d.dueDate == null ? null : CustomersFormat.plainDate(d.dueDate!),
      statusLabel: status,
      statusVariant: variant,
      overdueLabel: overdueDays > 0 ? l10n.receivables_doc_overdue_n('$overdueDays') : null,
      negative: negative,
      layout: table ? ReceivableDocumentRowLayout.table : ReceivableDocumentRowLayout.list,
      semanticLabel: <String>[CustomersTexts.documentKind(l10n, d.kind), title].join(', '),
      onTap: () => unawaited(_showDocument(context, l10n, d, title, money)),
      onLongPress: d.number == null
          ? null
          : () {
              unawaited(Clipboard.setData(ClipboardData(text: d.number!)));
              AppSnackbar.show(context, message: l10n.ds_copied);
            },
    );
  }

  /// Лист «Документ 1С» (read-only поля строки; переход в SCR-37 по `onecRef` — нет поиска транзакции по ссылке
  /// документа 1С, GQ-FECUST-04).
  Future<void> _showDocument(
    BuildContext context,
    AppLocalizations l10n,
    ReceivableDocument d,
    String title,
    String Function(Money) money,
  ) {
    final List<(String, String)> fields = <(String, String)>[
      (l10n.receivables_col_document, '${CustomersTexts.documentKind(l10n, d.kind)} · $title'),
      if (d.date != null) (l10n.receivables_col_date, CustomersFormat.plainDate(d.date!)),
      (l10n.receivables_col_amount, money(d.amount)),
      if (d.paid != null) (l10n.receivables_col_paid, CustomersFormat.money(d.paid!)),
      if (d.remaining != null) (l10n.receivables_col_remaining, CustomersFormat.money(d.remaining!)),
      if (d.dueDate != null) (l10n.receivables_col_due, CustomersFormat.plainDate(d.dueDate!)),
      if ((d.overdueDays ?? 0) > 0)
        (l10n.receivables_col_overdue_days, l10n.receivables_doc_overdue_n('${d.overdueDays!}')),
    ];
    return AppBottomSheet.show<void>(
      context,
      title: l10n.receivables_col_document,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final (String k, String v) in fields)
            Padding(
              padding: EdgeInsets.symmetric(vertical: context.space.s1),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(k, style: context.text.body.copyWith(color: context.colors.textSecondary)),
                  ),
                  Text(v, style: context.text.body.copyWith(color: context.colors.textPrimary)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
