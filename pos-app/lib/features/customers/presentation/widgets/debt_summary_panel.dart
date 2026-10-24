// Сводка долга (SCR-32 Z5 UI-32-006; SCR-34 Z1–Z4 UI-34-001/002/003/007): сальдо, просрочка, лимит, «Доступно
// (прогноз)», дата снимка 1С и «Обновить» (P-STALE), статус продажи в долг. Все суммы — из ответа сервера (DEBT-001,
// AC-UI-34-001); полоса лимита — только визуальная доля двух серверных значений (AC-UI-32-015); нет снимка —
// «Нет данных из 1С», а не «0 сом» (DEBT-009).
import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/receivable_badge.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/customers/presentation/customers_format.dart';
import 'package:optomstroy/features/customers/presentation/state/debt_snapshot.dart';

/// Ключи (тесты).
abstract final class DebtSummaryKeys {
  static const Key panel = ValueKey<String>('debt-summary');
  static const Key balance = ValueKey<String>('debt-summary-balance');
  static const Key noData = ValueKey<String>('debt-summary-no-data');
  static const Key stale = ValueKey<String>('debt-summary-stale');
  static const Key refresh = ValueKey<String>('debt-summary-refresh');
  static const Key credit = ValueKey<String>('debt-summary-credit');
}

/// Сводка долга.
class DebtSummaryPanel extends StatelessWidget {
  /// Создаёт сводку.
  const DebtSummaryPanel({
    super.key,
    required this.snapshot,
    required this.nowUtc,
    this.large = false,
    this.showCreditStatus = false,
    this.showDetails = true,
    this.onRefresh,
    this.refreshing = false,
    this.refreshVisibleWhenFresh = false,
    this.offlineLabel,
    this.onTap,
  });

  /// Снимок.
  final DebtSnapshot snapshot;

  /// «Сейчас» (возраст снимка).
  final DateTime nowUtc;

  /// SCR-34: сумма `display 32/700` (иначе `h3`).
  final bool large;

  /// Z4 — статус продажи в долг (SCR-34).
  final bool showCreditStatus;

  /// Строки лимита и открытых заказов.
  final bool showDetails;

  /// «Обновить» (`null` — кнопки нет: роль без права или офлайн).
  final VoidCallback? onRefresh;
  final bool refreshing;

  /// Показывать «Обновить» и при свежем снимке (SCR-34 Z3); на SCR-32 — только при устаревании.
  final bool refreshVisibleWhenFresh;

  /// «данные от HH:MM, нет сети» — снимок из памяти сессии.
  final String? offlineLabel;

  /// Тап по сводке (SCR-32 → вкладка «Долги»).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final DebtSnapshot s = snapshot;
    final bool stale = s.staleAt(nowUtc);
    final List<Widget> children = <Widget>[];
    if (s.noData) {
      children.add(
        ReceivableBadge(key: DebtSummaryKeys.noData, tone: ReceivableBadgeTone.noData, label: l10n.receivables_no_data),
      );
      if (s.notInOnec) {
        children.add(
          Padding(
            padding: EdgeInsets.only(top: context.space.s2),
            child: Text(
              l10n.customer_card_pending_onec_hint,
              style: context.text.caption.copyWith(color: c.textSecondary),
            ),
          ),
        );
      }
    } else {
      final Money balance = s.balance!;
      final bool overdue = s.overdue;
      final Color amountColor = overdue ? c.error : (balance > Money.zero ? c.warning : c.success);
      final String caption = balance.isNegative
          ? l10n.receivables_balance_advance
          : (balance.isZero ? l10n.receivables_balance_zero : l10n.receivables_balance_debt);
      children
        ..add(Text(caption, style: context.text.label.copyWith(color: c.textSecondary)))
        ..add(
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              CustomersFormat.money(balance),
              key: DebtSummaryKeys.balance,
              maxLines: 1,
              style: (large ? context.text.display : context.text.h3).copyWith(
                color: amountColor,
                fontWeight: FontWeight.w700,
                fontFeatures: DsTypography.numeric,
              ),
            ),
          ),
        )
        ..add(const SizedBox(height: 4))
        ..add(Align(alignment: Alignment.centerLeft, child: _badge(l10n, balance, overdue)))
        ..add(const SizedBox(height: 12));
      if (showDetails) children.addAll(_limit(context, l10n, c));
    }
    children.add(_asOf(context, l10n, c, stale));
    if (showCreditStatus) children.add(_credit(context, l10n, c));
    final Widget panel = Container(
      key: DebtSummaryKeys.panel,
      padding: EdgeInsets.all(large ? context.space.s6 : context.space.s4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.all(large ? context.radii.lg : context.radii.md),
        border: Border.all(color: c.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children),
    );
    if (onTap == null) return panel;
    return Semantics(
      button: true,
      child: InkWell(borderRadius: BorderRadius.all(context.radii.md), onTap: onTap, child: panel),
    );
  }

  Widget _badge(AppLocalizations l10n, Money balance, bool overdue) {
    final DebtSnapshot s = snapshot;
    if (overdue) {
      final Money amount = s.overdueAmount ?? Money.zero;
      final String label = s.overdueDays != null
          ? l10n.receivables_overdue(CustomersFormat.money(amount), s.overdueDays!)
          : '${l10n.customer_card_debt_overdue}: ${CustomersFormat.money(amount)}';
      return ReceivableBadge(tone: ReceivableBadgeTone.overdue, label: label);
    }
    if (balance > Money.zero) {
      return ReceivableBadge(tone: ReceivableBadgeTone.due, label: l10n.receivables_balance_debt);
    }
    return ReceivableBadge(
      tone: ReceivableBadgeTone.zero,
      label: balance.isNegative ? l10n.receivables_balance_advance : l10n.receivables_balance_zero,
    );
  }

  List<Widget> _limit(BuildContext context, AppLocalizations l10n, DsColors c) {
    final DebtSnapshot s = snapshot;
    final TextStyle label = context.text.body.copyWith(color: c.textSecondary);
    final TextStyle value = context.text.body.copyWith(
      color: c.textPrimary,
      fontWeight: FontWeight.w600,
      fontFeatures: DsTypography.numeric,
    );
    Widget row(String l, String v) => Padding(
      padding: EdgeInsets.symmetric(vertical: context.space.s1),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(l, style: label)),
          Text(v, style: value),
        ],
      ),
    );
    if (s.creditAllowed == false) {
      return <Widget>[
        Text(l10n.receivables_credit_not_allowed, style: label),
        if (s.paymentTermDays != null) row(l10n.receivables_term('${s.paymentTermDays!}'), ''),
        const SizedBox(height: 8),
      ];
    }
    final Money? limit = s.creditLimit;
    final Money? remaining = s.limitRemaining;
    final List<Widget> out = <Widget>[];
    if (limit == null || remaining == null) {
      out.add(Text(l10n.receivables_limit_none, style: label));
    } else {
      // Полоса — визуальная доля двух серверных значений `limitRemaining / creditLimit` (не деньги, AC-UI-32-015).
      out
        ..add(
          AppProgress.linear(
            value: ReceivableBadge.limitShare(remaining.tyiyn, limit.tyiyn),
            thin: true,
            semanticLabel: l10n.customer_card_debt_available,
          ),
        )
        ..add(const SizedBox(height: 6))
        ..add(
          Text(
            l10n.customer_card_debt_limit_available(CustomersFormat.money(remaining), CustomersFormat.money(limit)),
            style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
          ),
        );
      if (showDetails) {
        out
          ..add(const SizedBox(height: 4))
          ..add(row(l10n.receivables_limit, CustomersFormat.money(limit)));
        if (s.openOrdersAmount != null) {
          out.add(row(l10n.receivables_open_orders, CustomersFormat.money(s.openOrdersAmount!)));
        }
        out.add(row(l10n.receivables_available, CustomersFormat.money(remaining)));
      }
    }
    if (s.paymentTermDays != null) out.add(row(l10n.receivables_term('${s.paymentTermDays!}'), ''));
    out.add(const SizedBox(height: 8));
    return out;
  }

  Widget _asOf(BuildContext context, AppLocalizations l10n, DsColors c, bool stale) {
    final DateTime? asOf = snapshot.asOf;
    final String? time = asOf == null ? null : CustomersFormat.stamp(asOf, nowUtc);
    final Widget label;
    if (offlineLabel != null) {
      label = Text(offlineLabel!, style: context.text.caption.copyWith(color: c.textSecondary));
    } else if (time == null) {
      label = const SizedBox.shrink();
    } else if (stale) {
      label = StatusChip(
        key: DebtSummaryKeys.stale,
        label: l10n.receivables_stale(time),
        variant: StatusChipVariant.warning,
        icon: Icons.schedule_rounded,
        dense: true,
      );
    } else {
      label = Text(
        l10n.receivables_as_of(time),
        style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
      );
    }
    final bool showRefresh = onRefresh != null && (stale || refreshVisibleWhenFresh || snapshot.noData);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: <Widget>[
        label,
        if (showRefresh)
          AppButton(
            key: DebtSummaryKeys.refresh,
            label: l10n.receivables_refresh,
            icon: Icons.refresh_rounded,
            variant: AppButtonVariant.text,
            size: AppButtonSize.s,
            loading: refreshing,
            onPressed: refreshing ? null : onRefresh,
          ),
      ],
    );
  }

  Widget _credit(BuildContext context, AppLocalizations l10n, DsColors c) {
    final CreditStatus status = snapshot.creditStatus(nowUtc);
    final (String text, StatusChipVariant variant) = switch (status) {
      CreditStatus.allowed => (l10n.receivables_credit_allowed, StatusChipVariant.success),
      CreditStatus.blockedOverdue => (l10n.receivables_credit_blocked_overdue, StatusChipVariant.error),
      CreditStatus.blockedLimit => (l10n.receivables_credit_blocked_limit, StatusChipVariant.error),
      CreditStatus.blockedNoData => (l10n.receivables_credit_blocked_no_data, StatusChipVariant.error),
      CreditStatus.blockedStale => (l10n.receivables_credit_blocked_stale, StatusChipVariant.error),
      CreditStatus.notAllowed => (l10n.receivables_credit_not_allowed, StatusChipVariant.neutral),
    };
    return Padding(
      padding: EdgeInsets.only(top: context.space.s3),
      child: _CreditStatus(key: DebtSummaryKeys.credit, text: text, variant: variant),
    );
  }
}

/// Статус продажи в долг (UI-34-007): иконка + текст с переносом (цвет — не единственный носитель информации).
class _CreditStatus extends StatelessWidget {
  const _CreditStatus({required this.text, required this.variant, super.key});

  final String text;
  final StatusChipVariant variant;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg) = StatusChip.colorsOf(context.colors, variant);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: context.space.s3, vertical: context.space.s2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.all(context.radii.sm)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(StatusChip.iconOf(variant), size: 18, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: context.text.body.copyWith(color: fg, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}
