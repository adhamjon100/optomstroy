// Содержимое SCR-35 «Скидки и условия» (02 SCR-35.2–SCR-35.8): вид цены, скидка клиента 1С с примером расчёта
// (канонический пример 16 850,00 → 5 % = 842,50 → 16 007,50, только иллюстрация по MNY, на сервер не отправляется),
// условия оплаты (сумма лимита — только если пришла, Q-017), правила скидок (источник «1С»/«POS», статус иконкой и
// текстом), лимит ручной скидки роли и роли, подтверждающие сверх лимита (из `GET /discounts/rules`, AC-UI-35-006),
// подпись об автоматических скидках 1С. Изменяющих контролов нет (AC-UI-35-003).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_section_header.dart';
import 'package:optomstroy/design_system/components/discount_rule_row.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_terms.dart';
import 'package:optomstroy/features/customers/presentation/customers_format.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/customers/presentation/state/customer_discounts_controller.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_states.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customers_nav.dart';

/// Ключи (тесты).
abstract final class CustomerDiscountsKeys {
  static const Key example = ValueKey<String>('customer-discounts-example');
  static const Key creditLimit = ValueKey<String>('customer-discounts-credit-limit');
  static const Key roleLimit = ValueKey<String>('customer-discounts-role-limit');
  static const Key termsError = ValueKey<String>('customer-discounts-terms-error');
  static const Key rulesError = ValueKey<String>('customer-discounts-rules-error');
  static Key rule(String id) => ValueKey<String>('customer-discounts-rule-$id');
}

/// Сумма канонического примера (ядро §17.2): 16 850,00 сом.
const Money discountExampleSubtotal = Money(1685000);

/// SCR-35 (тело).
class CustomerDiscountsView extends ConsumerWidget {
  /// Создаёт тело SCR-35.
  const CustomerDiscountsView({required this.customerId, super.key});

  final String customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CustomerDiscountsState s = ref.watch(customerDiscountsProvider(customerId));
    final CustomerDiscountsController ctl = ref.read(customerDiscountsProvider(customerId).notifier);
    if (s.offline) return CustomerStates.offline(l10n.customer_discounts_offline);
    if (s.notFound) return CustomerStates.notFound(context, () => CustomersNav.toList(context));
    if (s.forbidden) return CustomerStates.forbidden(context);
    final DateTime now = ref.watch(clockProvider).nowUtc();
    final List<Widget> left = _terms(
      context,
      l10n,
      s,
      ctl,
      now,
      customerMode: ref.watch(customersViewerProvider.select((CustomersViewer v) => v.isCustomer)),
    );
    final List<Widget> right = _rules(context, l10n, s, ctl);
    final WindowClass wc = context.windowClass;
    final Widget note = Padding(
      padding: EdgeInsets.only(top: context.space.s3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.info_outline_rounded, size: 16, color: context.colors.textSecondary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              l10n.customer_discounts_auto_note,
              style: context.text.caption.copyWith(color: context.colors.textSecondary),
            ),
          ),
        ],
      ),
    );
    if (wc == WindowClass.expanded || wc == WindowClass.large) {
      return RefreshIndicator(
        onRefresh: ctl.load,
        child: ListView(
          padding: EdgeInsets.all(context.space.s4),
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 380,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: left),
                ),
                SizedBox(width: context.space.s6),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: right),
                ),
              ],
            ),
            note,
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: ctl.load,
      child: ListView(
        padding: EdgeInsets.all(context.space.s4),
        children: <Widget>[
          ...left,
          SizedBox(height: context.space.s4),
          ...right,
          note,
        ],
      ),
    );
  }

  static Widget _card(BuildContext context, List<Widget> children, {Key? key}) => Container(
    key: key,
    margin: EdgeInsets.only(bottom: context.space.s3),
    padding: EdgeInsets.all(context.space.s4),
    decoration: BoxDecoration(
      color: context.colors.surface,
      borderRadius: BorderRadius.all(context.radii.md),
      border: Border.all(color: context.colors.border),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children),
  );

  List<Widget> _terms(
    BuildContext context,
    AppLocalizations l10n,
    CustomerDiscountsState s,
    CustomerDiscountsController ctl,
    DateTime now, {
    bool customerMode = false,
  }) {
    final DsColors c = context.colors;
    switch (s.terms) {
      case DiscountsBlockPhase.loading:
        return const <Widget>[
          SkeletonBox(height: 56),
          SizedBox(height: 12),
          SkeletonBox(height: 96),
          SizedBox(height: 12),
          SkeletonBox(height: 96),
        ];
      case DiscountsBlockPhase.error:
        return <Widget>[
          ErrorState.inline(
            key: CustomerDiscountsKeys.termsError,
            message: l10n.customer_discounts_block_error,
            onRetry: () => unawaited(ctl.retryTerms()),
          ),
        ];
      case DiscountsBlockPhase.ready:
        break;
    }
    final CustomerDiscounts d = s.discounts!;
    final TextStyle caption = context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric);
    final bool stale = CustomersFormat.isStale(asOf: d.asOf, flag: false, nowUtc: now);
    final String time = CustomersFormat.stamp(d.asOf, now);
    final Percent? p = d.customerDiscountPercent;
    final CustomerCreditTerms? t = d.creditTerms;
    return <Widget>[
      Align(
        alignment: Alignment.centerLeft,
        child: stale
            ? StatusChip(
                label: l10n.receivables_stale(time),
                variant: StatusChipVariant.warning,
                icon: Icons.schedule_rounded,
                dense: true,
              )
            : Text(l10n.receivables_as_of(time), style: caption),
      ),
      const SizedBox(height: 8),
      _card(context, <Widget>[
        Text(l10n.customer_discounts_price_list, style: context.text.label.copyWith(color: c.textSecondary)),
        const SizedBox(height: 4),
        if (d.priceList != null)
          Row(
            children: <Widget>[
              Flexible(
                child: Text(
                  d.priceList!.name,
                  style: context.text.body.copyWith(fontWeight: FontWeight.w600, color: c.textPrimary),
                ),
              ),
              const SizedBox(width: 8),
              StatusChip(label: l10n.customer_discounts_rule_source_onec, variant: StatusChipVariant.info, dense: true),
            ],
          )
        else
          Text(l10n.customer_discounts_price_list_default, style: context.text.body.copyWith(color: c.textSecondary)),
      ]),
      _card(context, <Widget>[
        if (p == null || p.hundredths == 0)
          Text(l10n.customer_discounts_client_none, style: context.text.body.copyWith(color: c.textSecondary))
        else ...<Widget>[
          Text(
            l10n.customer_discounts_client_discount(CustomersFormat.percent(p)),
            style: context.text.h3.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: DsTypography.numeric,
              color: c.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(_example(l10n, p), key: CustomerDiscountsKeys.example, style: caption),
        ],
      ]),
      _card(context, <Widget>[
        Text(l10n.customer_discounts_terms_title, style: context.text.label.copyWith(color: c.textSecondary)),
        const SizedBox(height: 4),
        if (t != null) ...<Widget>[
          Text(
            t.creditAllowed ? l10n.customer_discounts_credit_allowed : l10n.customer_discounts_credit_not_allowed,
            style: context.text.body.copyWith(color: c.textPrimary),
          ),
          if (t.paymentTermDays != null)
            Text(
              l10n.customer_discounts_term_days('${t.paymentTermDays!}'),
              style: context.text.body.copyWith(color: c.textPrimary),
            ),
          if (t.creditLimit != null)
            Text(
              l10n.customer_discounts_credit_limit(CustomersFormat.money(t.creditLimit!)),
              key: CustomerDiscountsKeys.creditLimit,
              style: context.text.body.copyWith(color: c.textPrimary, fontFeatures: DsTypography.numeric),
            ),
        ],
      ]),
      // Лимит ручной скидки роли — служебная информация, клиенту не показывается (10 CUST-021; RM-G-014).
      if (!customerMode && (d.manualDiscountLimitPercent != null || s.rulesInfo != null))
        _card(key: CustomerDiscountsKeys.roleLimit, context, <Widget>[
          Text(
            l10n.customer_discounts_role_limit(
              CustomersFormat.percent(d.manualDiscountLimitPercent ?? s.rulesInfo!.manualDiscountLimitPercent),
            ),
            style: context.text.title.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: DsTypography.numeric,
              color: c.textPrimary,
            ),
          ),
          if (s.rulesInfo != null && s.rulesInfo!.overrideRoles.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(l10n.customer_discounts_override_roles(_overrideRoles(l10n, s.rulesInfo!)), style: caption),
          ],
        ]),
    ];
  }

  /// «Заказ 16 850,00 сом → скидка 5 % = 842,50 сом → итог 16 007,50 сом» (MNY, HALF_UP до 0,01).
  static String _example(AppLocalizations l10n, Percent p) {
    final Money discount = MoneyMath.documentDiscount(discountExampleSubtotal, p);
    return l10n.customer_discounts_example(
      CustomersFormat.money(discount),
      CustomersFormat.percent(p),
      CustomersFormat.money(discountExampleSubtotal),
      CustomersFormat.money(discountExampleSubtotal - discount),
    );
  }

  /// «Старший продавец — 10 %, Администратор — 15 %» (значения — из ответа, не константы приложения).
  static String _overrideRoles(AppLocalizations l10n, DiscountRulesInfo info) => <String>[
    for (final RoleCode r in info.overrideRoles)
      switch (info.limitsByRole[r.value]) {
        final String v => '${CustomersTexts.role(l10n, r)} — ${_percentOf(v)}',
        null => CustomersTexts.role(l10n, r),
      },
  ].join(', ');

  static String _percentOf(String v) {
    try {
      return CustomersFormat.percent(Percent.fromString(v));
    } on Object {
      return v;
    }
  }

  List<Widget> _rules(
    BuildContext context,
    AppLocalizations l10n,
    CustomerDiscountsState s,
    CustomerDiscountsController ctl,
  ) {
    final List<Widget> head = <Widget>[
      AppSectionHeader(title: l10n.customer_discounts_rules_title, padding: EdgeInsets.zero),
      const SizedBox(height: 8),
    ];
    // Правила клиента — из `GET /customers/{id}/discounts`; если блок условий с ошибкой — из `GET /discounts/rules`.
    final List<DiscountRule>? rules = s.discounts?.rules ?? s.rulesInfo?.rules;
    if (rules == null) {
      if (s.loading) {
        return <Widget>[
          ...head,
          for (int i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.only(bottom: context.space.s2),
              child: const SkeletonBox(height: 56),
            ),
        ];
      }
      return <Widget>[
        ...head,
        ErrorState.inline(
          key: CustomerDiscountsKeys.rulesError,
          message: l10n.customer_discounts_block_error,
          onRetry: () => unawaited(ctl.retryRules()),
        ),
      ];
    }
    if (rules.isEmpty) {
      return <Widget>[
        ...head,
        EmptyState(variant: EmptyStateVariant.search, title: l10n.customer_discounts_rules_empty),
      ];
    }
    return <Widget>[
      ...head,
      if (s.rules == DiscountsBlockPhase.error)
        Padding(
          padding: EdgeInsets.only(bottom: context.space.s2),
          child: ErrorState.inline(
            key: CustomerDiscountsKeys.rulesError,
            message: l10n.customer_discounts_block_error,
            onRetry: () => unawaited(ctl.retryRules()),
          ),
        ),
      for (final DiscountRule r in rules) _rule(l10n, r, s.expanded.contains(r.id), () => ctl.toggle(r.id)),
    ];
  }

  static Widget _rule(AppLocalizations l10n, DiscountRule r, bool expanded, VoidCallback onToggle) {
    final bool onec = r.source == DiscountSource.onec;
    final bool active = r.isActive ?? true;
    final (String status, StatusChipVariant variant) = !active
        ? (l10n.customer_discounts_rule_inactive, StatusChipVariant.neutral)
        : (onec
              ? (l10n.customer_discounts_rule_onec_total, StatusChipVariant.neutral)
              : (l10n.customer_discounts_rule_active, StatusChipVariant.success));
    final DiscountRuleConditions? cond = r.conditions;
    final List<DiscountRuleDetail> details = <DiscountRuleDetail>[
      if (cond?.minTotal != null)
        DiscountRuleDetail(icon: Icons.shopping_cart_outlined, text: '≥ ${CustomersFormat.money(cond!.minTotal!)}'),
      if (cond != null && cond.categoryIds.isNotEmpty)
        DiscountRuleDetail(icon: Icons.category_outlined, text: '${cond.categoryIds.length}'),
    ];
    return DiscountRuleRow(
      key: CustomerDiscountsKeys.rule(r.id),
      name: r.name ?? _value(r) ?? r.id,
      valueLabel: _value(r),
      sourceLabel: onec ? l10n.customer_discounts_rule_source_onec : l10n.customer_discounts_rule_source_pos,
      fromOnec: onec,
      statusLabel: status,
      statusVariant: variant,
      details: details,
      expanded: expanded,
      onToggle: details.isEmpty ? null : onToggle,
    );
  }

  /// Значение правила: процент «5 %», сумма «500,00 сом», вид цены — как пришёл.
  static String? _value(DiscountRule r) {
    final String? v = r.value;
    if (v == null) return null;
    try {
      return switch (r.kind) {
        DiscountKind.percent => CustomersFormat.percent(Percent.fromString(v)),
        DiscountKind.fixedAmount => CustomersFormat.money(Money.fromString(v)),
        DiscountKind.priceList || null => v,
      };
    } on Object {
      return v;
    }
  }
}
