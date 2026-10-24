// Содержимое SCR-32 «Карточка клиента» (02 SCR-32.2–SCR-32.10; §0.4 — матрица полей по ролям): Z1 шапка, Z2 метрики,
// Z3 действия, Z4 вкладки (compact — переход на SCR-33/34/35, «Заказы и операции» — внутри; expanded — содержимое
// вкладок внутри, URL `?tab=`), Z5 сводка долга (роли с правом на суммы; `seller` — пояснение без сумм, Q-017),
// Z6 контакты и адреса, Z7 привязки (admin, owner). Поля, не пришедшие в ответе, не рисуются (SEC-031).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_controller.dart' show stepUpCoordinatorProvider;
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_list_tile.dart';
import 'package:optomstroy/design_system/components/app_section_header.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/app_tabs.dart';
import 'package:optomstroy/design_system/components/customer_card.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/favorite_toggle.dart';
import 'package:optomstroy/design_system/components/receivable_badge.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_contact.dart';
import 'package:optomstroy/features/customers/presentation/customers_format.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/customers/presentation/state/customer_card_controller.dart';
import 'package:optomstroy/features/customers/presentation/state/customer_favorites_controller.dart';
import 'package:optomstroy/features/customers/presentation/state/customer_history_controller.dart';
import 'package:optomstroy/features/customers/presentation/state/debt_snapshot.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_discounts_view.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_history_view.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_states.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customers_nav.dart';
import 'package:optomstroy/features/customers/presentation/widgets/debt_refresh_feedback.dart';
import 'package:optomstroy/features/customers/presentation/widgets/debt_summary_panel.dart';
import 'package:optomstroy/features/customers/presentation/widgets/receivables_view.dart';

/// Вкладка карточки (`?tab=`).
enum CustomerCardTab {
  history('history'),
  receivables('receivables'),
  discounts('discounts'),
  orders('orders');

  const CustomerCardTab(this.value);

  final String value;

  static CustomerCardTab? tryParse(String? v) {
    for (final CustomerCardTab t in values) {
      if (t.value == v) return t;
    }
    return null;
  }
}

/// Ключи (тесты).
abstract final class CustomerCardKeys {
  static const Key header = ValueKey<String>('customer-card-header');
  static const Key metrics = ValueKey<String>('customer-card-metrics');
  static const Key sellerInfo = ValueKey<String>('customer-card-seller-info');
  static const Key favorite = ValueKey<String>('customer-card-favorite');
  static const Key toCart = ValueKey<String>('customer-card-to-cart');
  static const Key acceptDebt = ValueKey<String>('customer-card-accept-debt');
  static const Key contacts = ValueKey<String>('customer-card-contacts');
  static const Key links = ValueKey<String>('customer-card-links');
  static const Key retail = ValueKey<String>('customer-card-retail');
  static const Key refreshFailed = ValueKey<String>('customer-card-refresh-failed');
  static const Key tabs = ValueKey<String>('customer-card-tabs');
  static Key tab(CustomerCardTab t) => ValueKey<String>('customer-card-tab-${t.value}');
}

/// SCR-32 (тело).
class CustomerCardView extends ConsumerStatefulWidget {
  /// Создаёт тело карточки.
  const CustomerCardView({required this.customerId, this.tab, this.inMaster = false, super.key});

  final String customerId;

  /// `?tab=` (expanded).
  final String? tab;

  /// Деталь мастер-детали SCR-31 (expanded): вкладки — внутри, без своей нижней панели.
  final bool inMaster;

  @override
  ConsumerState<CustomerCardView> createState() => _CustomerCardViewState();
}

class _CustomerCardViewState extends ConsumerState<CustomerCardView> {
  CustomerCardTab? _tab;

  @override
  void initState() {
    super.initState();
    _tab = CustomerCardTab.tryParse(widget.tab);
  }

  @override
  void didUpdateWidget(CustomerCardView old) {
    super.didUpdateWidget(old);
    if (old.tab != widget.tab || old.customerId != widget.customerId) _tab = CustomerCardTab.tryParse(widget.tab);
  }

  List<CustomerCardTab> _tabs(CustomersViewer v, Customer c) => <CustomerCardTab>[
    if (v.canReadHistory && !c.isRetailDefault) CustomerCardTab.history,
    if (v.canReadReceivables && !c.isRetailDefault) CustomerCardTab.receivables,
    CustomerCardTab.discounts,
    // `customer`: свои заказы — вкладка «Мои заказы» оболочки (SCR-25); журнал операций клиенту недоступен
    // (10 CUST-021), поэтому вкладки «Заказы и операции» в своей карточке нет (RM-G-014).
    if (!v.isCustomer) CustomerCardTab.orders,
  ];

  String _tabLabel(AppLocalizations l10n, CustomerCardTab t) => switch (t) {
    CustomerCardTab.history => l10n.customer_card_tab_history,
    CustomerCardTab.receivables => l10n.customer_card_tab_receivables,
    CustomerCardTab.discounts => l10n.customer_card_tab_discounts,
    CustomerCardTab.orders => l10n.customer_card_tab_orders,
  };

  void _openTab(CustomerCardTab t, {required bool wide}) {
    if (wide) {
      setState(() => _tab = t);
      if (!widget.inMaster) CustomersNav.selectTab(context, widget.customerId, t.value);
      return;
    }
    if (t == CustomerCardTab.orders) {
      setState(() => _tab = t);
      return;
    }
    CustomersNav.openSection(context, widget.customerId, t.value);
  }

  Future<void> _toggleFavorite(Customer c, bool value) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CustomerFavoritesController fav = ref.read(customerFavoritesProvider.notifier);
    final FavoriteOutcome outcome = await fav.set(c.id, value, server: c.isFavorite);
    if (!mounted) return;
    switch (outcome) {
      case FavoriteSaved(value: final bool saved) when saved == value:
        AppSnackbar.show(
          context,
          message: saved ? l10n.customer_card_favorite_added : l10n.customer_card_favorite_removed,
          actionLabel: l10n.ds_button_undo,
          onAction: () => unawaited(fav.set(c.id, !saved, server: saved)),
        );
      case FavoriteSaved():
        break;
      case FavoriteFailed(:final failure):
        AppSnackbar.show(context, message: CustomerStates.message(l10n, failure), variant: AppSnackbarVariant.error);
    }
  }

  Future<void> _refreshDebt() async {
    final DebtRefreshOutcome outcome = await ref.read(customerCardProvider(widget.customerId).notifier).refreshDebt();
    if (mounted) showDebtRefreshOutcome(context, outcome, ref.read(clockProvider).nowUtc());
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CustomerCardState s = ref.watch(customerCardProvider(widget.customerId));
    final CustomerCardController ctl = ref.read(customerCardProvider(widget.customerId).notifier);
    switch (s.phase) {
      case CustomerCardPhase.loading:
        return const _CardSkeleton();
      case CustomerCardPhase.offline:
        return CustomerStates.offline(l10n.customer_card_offline);
      case CustomerCardPhase.forbidden:
        return CustomerStates.forbidden(context);
      case CustomerCardPhase.notFound:
        return CustomerStates.notFound(context, () => CustomersNav.toList(context));
      case CustomerCardPhase.error:
        return CustomerStates.error(
          context,
          title: l10n.error_internal,
          failure: s.failure,
          onRetry: () => unawaited(ctl.load()),
        );
      case CustomerCardPhase.ready:
        break;
    }
    final Customer c = s.customer!;
    final CustomersViewer viewer = ref.watch(customersViewerProvider);
    final bool online = ref.watch(customersOnlineProvider);
    final WindowClass wc = context.windowClass;
    final bool wide = widget.inMaster || wc == WindowClass.expanded || wc == WindowClass.large;
    final List<CustomerCardTab> tabs = _tabs(viewer, c);
    // compact: вкладки — переходы на SCR-33/34/35; выбранной вкладки нет, пока не открыты «Заказы и операции»
    // (иначе `AppTabs.scrollable` при первом кадре прокрутил бы всю карточку к полосе вкладок).
    final CustomerCardTab? active = _tab != null && tabs.contains(_tab) ? _tab : (wide ? tabs.first : null);
    final bool locked = ref.watch(stepUpCoordinatorProvider).tokenFor(receivablesDetailOperation) == null;
    final Widget tabBar = AppTabs<CustomerCardTab?>(
      key: CustomerCardKeys.tabs,
      variant: wide ? AppTabsVariant.fixed : AppTabsVariant.scrollable,
      value: active,
      onChanged: (CustomerCardTab? t) {
        if (t != null) _openTab(t, wide: wide);
      },
      tabs: <AppTab<CustomerCardTab?>>[
        for (final CustomerCardTab t in tabs)
          AppTab<CustomerCardTab?>(
            key: CustomerCardKeys.tab(t),
            value: t,
            label: _tabLabel(l10n, t),
            icon: t == CustomerCardTab.receivables && locked ? Icons.lock_outline_rounded : null,
          ),
      ],
    );
    final List<Widget> head = <Widget>[
      if (s.refreshFailed)
        Padding(
          padding: EdgeInsets.only(bottom: context.space.s3),
          child: ErrorState.banner(
            key: CustomerCardKeys.refreshFailed,
            message: CustomerStates.message(l10n, s.failure),
            tone: ErrorStateTone.warning,
            onRetry: () => unawaited(ctl.refresh()),
          ),
        ),
      _Header(customer: c, large: wide, favorite: wide ? null : _favorite(c, viewer, online)),
      SizedBox(height: context.space.s3),
      _Metrics(
        customer: c,
        viewer: viewer,
        debt: s.debt,
        onTab: (CustomerCardTab t) => _openTab(t, wide: wide),
      ),
    ];
    final List<Widget> side = <Widget>[
      if (c.isRetailDefault)
        AppListTile(
          key: CustomerCardKeys.retail,
          leadingIcon: Icons.info_outline_rounded,
          title: l10n.customer_card_retail_system,
        )
      else ...<Widget>[
        _debt(context, l10n, c, s, viewer, online),
        if (viewer.seesSums) _Contacts(customer: c),
        if (c.links.isNotEmpty) _Links(customer: c, viewer: viewer),
      ],
    ];
    final List<Widget> actions = _actions(context, l10n, c, s, viewer, online, vertical: wide);
    if (wide) {
      final Widget content = switch (active ?? tabs.first) {
        CustomerCardTab.history => CustomerHistoryView(args: CustomerHistoryArgs(c.id)),
        CustomerCardTab.receivables => ReceivablesView(customerId: c.id, embedded: true),
        CustomerCardTab.discounts => CustomerDiscountsView(customerId: c.id),
        CustomerCardTab.orders => _ordersTab(c.id),
      };
      return CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.f5): () => unawaited(ctl.refresh()),
          for (int i = 0; i < tabs.length && i < 4; i++)
            SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i), alt: true): () =>
                _openTab(tabs[i], wide: true),
        },
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      context.space.s6,
                      context.space.s6,
                      context.space.s6,
                      context.space.s3,
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: head),
                  ),
                  tabBar,
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: context.space.s2),
                      child: KeyedSubtree(key: ValueKey<CustomerCardTab?>(active), child: content),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              width: wc == WindowClass.large ? 320 : 300,
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: context.colors.border)),
              ),
              child: ListView(
                padding: EdgeInsets.all(context.space.s4),
                children: <Widget>[
                  ...actions,
                  if (actions.isNotEmpty) SizedBox(height: context.space.s4),
                  ...side,
                ],
              ),
            ),
          ],
        ),
      );
    }
    final Widget list = RefreshIndicator(
      onRefresh: ctl.refresh,
      child: ListView(
        padding: EdgeInsets.all(context.space.s4),
        children: <Widget>[
          ...head,
          SizedBox(height: context.space.s4),
          if (!c.isRetailDefault) ...<Widget>[
            _debt(context, l10n, c, s, viewer, online),
            SizedBox(height: context.space.s4),
          ],
          tabBar,
          if (active == CustomerCardTab.orders) SizedBox(height: 480, child: _ordersTab(c.id)),
          SizedBox(height: context.space.s4),
          if (c.isRetailDefault) side.first,
          if (!c.isRetailDefault && viewer.seesSums) _Contacts(customer: c),
          if (!c.isRetailDefault && c.links.isNotEmpty) _Links(customer: c, viewer: viewer),
        ],
      ),
    );
    if (actions.isEmpty) return list;
    return Column(
      children: <Widget>[
        Expanded(child: list),
        Container(
          padding: EdgeInsets.all(context.space.s4),
          decoration: BoxDecoration(
            color: context.colors.surface,
            border: Border(top: BorderSide(color: context.colors.border)),
          ),
          child: SafeArea(
            top: false,
            child: Row(
              children: <Widget>[
                for (int i = 0; i < actions.length; i++) ...<Widget>[
                  if (i > 0) SizedBox(width: context.space.s3),
                  Expanded(child: actions[i]),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _ordersTab(String customerId) {
    final CustomerOrdersTabBuilder? builder = ref.watch(customerOrdersTabBuilderProvider);
    return builder == null ? const SizedBox.shrink() : builder(context, customerId);
  }

  Widget? _favorite(Customer c, CustomersViewer viewer, bool online) {
    if (!viewer.canManageFavorites || c.isRetailDefault) return null;
    final bool on =
        ref.watch(customerFavoritesProvider.select((Map<String, bool> m) => m[c.id])) ?? c.isFavorite ?? false;
    final AppLocalizations l10n = AppLocalizations.of(context);
    return FavoriteToggle(
      key: CustomerCardKeys.favorite,
      selected: on,
      semanticLabel: on ? l10n.ds_favorite_on_a11y : l10n.ds_favorite_add_a11y,
      onChanged: online ? (bool v) => unawaited(_toggleFavorite(c, v)) : null,
    );
  }

  Widget _debt(
    BuildContext context,
    AppLocalizations l10n,
    Customer c,
    CustomerCardState s,
    CustomersViewer viewer,
    bool online,
  ) {
    if (!viewer.seesSums) {
      return AppListTile(
        key: CustomerCardKeys.sellerInfo,
        leadingIcon: Icons.info_outline_rounded,
        title: l10n.customer_card_seller_info,
      );
    }
    final DebtSnapshot snapshot =
        s.debt ?? DebtSnapshot(creditAllowed: c.creditAllowed, notInOnec: c.onecStatus == CustomerOnecStatus.pending);
    final DateTime now = ref.watch(clockProvider).nowUtc();
    final bool rateLimited = s.debtRateLimitedUntil != null && now.isBefore(s.debtRateLimitedUntil!);
    return DebtSummaryPanel(
      snapshot: snapshot,
      nowUtc: now,
      refreshing: s.debtRefreshing,
      onRefresh: viewer.canRefreshReceivables && online && !rateLimited ? () => unawaited(_refreshDebt()) : null,
      onTap: viewer.canReadReceivables
          ? () => _openTab(
              CustomerCardTab.receivables,
              wide: widget.inMaster || context.windowClass.index >= WindowClass.expanded.index,
            )
          : null,
    );
  }

  List<Widget> _actions(
    BuildContext context,
    AppLocalizations l10n,
    Customer c,
    CustomerCardState s,
    CustomersViewer viewer,
    bool online, {
    required bool vertical,
  }) {
    final CustomerToCartAction? toCart = ref.watch(customerToCartActionProvider);
    final bool debtPayments = ref.watch(customerDebtPaymentsEnabledProvider);
    final List<Widget> out = <Widget>[];
    final bool showAccept = viewer.canAcceptDebtPayment && debtPayments && !c.isRetailDefault;
    if (showAccept) {
      final Money? balance = s.debt?.balance;
      final bool enabled =
          online &&
          c.onecRef != null &&
          c.onecStatus != CustomerOnecStatus.pending &&
          balance != null &&
          balance > Money.zero;
      final String? reason = enabled
          ? null
          : (!online
                ? l10n.ds_sync_offline
                : (c.onecRef == null || c.onecStatus == CustomerOnecStatus.pending
                      ? l10n.customer_card_accept_disabled_no_onec
                      : l10n.customer_card_accept_disabled_no_debt));
      final Widget button = AppButton(
        key: CustomerCardKeys.acceptDebt,
        label: l10n.customer_card_action_accept_debt,
        icon: Icons.payments_outlined,
        size: AppButtonSize.l,
        expand: true,
        onPressed: enabled ? () => CustomersNav.acceptDebtPayment(context, c.id) : null,
      );
      out.add(reason == null ? button : Tooltip(message: reason, child: button));
    }
    if (toCart != null && viewer.canAddToCart) {
      out.add(
        AppButton(
          key: CustomerCardKeys.toCart,
          label: l10n.customer_card_action_to_cart,
          icon: Icons.add_shopping_cart_rounded,
          size: AppButtonSize.l,
          expand: true,
          variant: showAccept ? AppButtonVariant.outlined : AppButtonVariant.primary,
          onPressed: online ? () => unawaited(toCart(context, c.id)) : null,
        ),
      );
    }
    if (vertical) {
      final Widget? fav = _favorite(c, viewer, online);
      if (fav != null) {
        final bool on =
            ref.watch(customerFavoritesProvider.select((Map<String, bool> m) => m[c.id])) ?? c.isFavorite ?? false;
        out.add(
          AppListTile(
            title: on ? l10n.ds_favorite_on_a11y : l10n.ds_favorite_add_a11y,
            leading: fav,
            onTap: online ? () => unawaited(_toggleFavorite(c, !on)) : null,
          ),
        );
      }
      return <Widget>[
        for (int i = 0; i < out.length; i++) ...<Widget>[if (i > 0) const SizedBox(height: 8), out[i]],
      ];
    }
    return out;
  }
}

class _CardSkeleton extends StatelessWidget {
  const _CardSkeleton();

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.all(context.space.s4),
    children: const <Widget>[
      Row(
        children: <Widget>[
          SkeletonBox.avatar(size: 64),
          SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SkeletonBox.text(width: 220),
                SizedBox(height: 8),
                SkeletonBox.text(width: 160, height: 14),
                SizedBox(height: 8),
                SkeletonBox.text(width: 180, height: 14),
              ],
            ),
          ),
        ],
      ),
      SizedBox(height: 16),
      SkeletonBox(height: 32),
      SizedBox(height: 16),
      SkeletonBox(height: 96),
      SizedBox(height: 16),
      SkeletonBox(height: 48),
    ],
  );
}

/// Z1 — шапка клиента (UI-32-001, UI-32-016).
class _Header extends StatelessWidget {
  const _Header({required this.customer, required this.large, this.favorite});

  final Customer customer;
  final bool large;
  final Widget? favorite;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final Customer x = customer;
    final double avatar = large ? 64 : 48; // money-double: allow — размер аватара (lp)
    final TextStyle caption = context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric);
    final String? code = CustomersTexts.code(l10n, x);
    final String meta = <String>[
      ?code,
      if (x.customerType != null) CustomersTexts.type(l10n, x.customerType!),
    ].join(' · ');
    return Row(
      key: CustomerCardKeys.header,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: avatar,
          height: avatar,
          alignment: Alignment.center,
          decoration: BoxDecoration(shape: BoxShape.circle, color: c.primaryContainer),
          child: ExcludeSemantics(
            child: Text(
              CustomerCard.initials(x.title),
              style: (large ? context.text.h3 : context.text.title).copyWith(
                color: c.primaryText,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        SizedBox(width: context.space.s4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Text(x.title, style: context.text.h2.copyWith(color: c.textPrimary)),
                  if (CustomersTexts.pendingOnec(x))
                    StatusChip(
                      label: l10n.customer_card_pending_onec,
                      variant: StatusChipVariant.warning,
                      tooltip: l10n.customer_card_pending_onec_hint,
                      dense: true,
                    ),
                ],
              ),
              if (meta.isNotEmpty) Text(meta, style: caption),
              const SizedBox(height: 4),
              if (x.phones.isNotEmpty)
                for (final CustomerPhone p in x.phones) _Phone(phone: p)
              else if (x.phoneMasked != null)
                Text(
                  x.phoneMasked!,
                  style: context.text.body.copyWith(color: c.textPrimary, fontFeatures: DsTypography.numeric),
                ),
              if (x.inn != null && x.inn!.isNotEmpty) Text(l10n.customer_card_inn(x.inn!), style: caption),
            ],
          ),
        ),
        ?favorite,
      ],
    );
  }
}

class _Phone extends StatelessWidget {
  const _Phone({required this.phone});

  final CustomerPhone phone;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    void copy() {
      unawaited(Clipboard.setData(ClipboardData(text: phone.valueE164)));
      AppSnackbar.show(context, message: l10n.ds_copied);
    }

    return GestureDetector(
      onLongPress: copy,
      onSecondaryTap: copy,
      child: Padding(
        padding: EdgeInsets.only(bottom: context.space.s1),
        child: Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Text(
              CustomersFormat.phone(phone.valueE164),
              style: context.text.body.copyWith(color: c.textPrimary, fontFeatures: DsTypography.numeric),
            ),
            StatusChip(
              label: phone.verified ? l10n.customer_card_phone_verified : l10n.customer_card_phone_not_verified,
              variant: phone.verified ? StatusChipVariant.success : StatusChipVariant.neutral,
              icon: phone.verified ? Icons.verified_rounded : null,
              dense: true,
            ),
          ],
        ),
      ),
    );
  }
}

/// Z2 — метрики «История · Долг · Скидка» (UI-32-002).
class _Metrics extends StatelessWidget {
  const _Metrics({required this.customer, required this.viewer, required this.debt, required this.onTab});

  final Customer customer;
  final CustomersViewer viewer;
  final DebtSnapshot? debt;
  final ValueChanged<CustomerCardTab> onTab;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Customer c = customer;
    final List<Widget> chips = <Widget>[];
    if (c.ordersCount != null) {
      chips.add(
        _tap(
          viewer.canReadHistory && !c.isRetailDefault ? () => onTab(CustomerCardTab.history) : null,
          StatusChip(label: l10n.customer_card_metric_history(c.ordersCount!), variant: StatusChipVariant.neutral),
        ),
      );
    }
    if (!c.isRetailDefault) {
      final Widget debtChip;
      if (viewer.seesSums && debt != null && debt!.balance != null) {
        final DebtSnapshot d = debt!;
        debtChip = ReceivableBadge(
          tone: d.overdue
              ? ReceivableBadgeTone.overdue
              : (d.balance! > Money.zero ? ReceivableBadgeTone.due : ReceivableBadgeTone.zero),
          label: l10n.customer_card_metric_debt(CustomersFormat.money(d.balance!)),
        );
      } else if (viewer.seesSums && debt != null) {
        debtChip = ReceivableBadge(tone: ReceivableBadgeTone.noData, label: l10n.customer_card_debt_no_data);
      } else if (c.isOverdue == true) {
        debtChip = ReceivableBadge.compact(overdue: true, label: l10n.customer_card_metric_overdue_flag);
      } else if (c.hasDebt == true) {
        debtChip = ReceivableBadge.compact(overdue: false, label: l10n.customer_card_metric_debt_flag_yes);
      } else {
        debtChip = StatusChip(label: l10n.customer_card_metric_debt_flag_no, variant: StatusChipVariant.neutral);
      }
      chips.add(_tap(viewer.canReadReceivables ? () => onTab(CustomerCardTab.receivables) : null, debtChip));
    }
    if (c.discountPercent != null) {
      chips.add(
        _tap(
          () => onTab(CustomerCardTab.discounts),
          StatusChip(
            label: l10n.customer_card_metric_discount(CustomersFormat.percent(c.discountPercent!)),
            variant: StatusChipVariant.neutral,
          ),
        ),
      );
    }
    if (c.priceList != null) chips.add(StatusChip(label: c.priceList!.name, variant: StatusChipVariant.priceList));
    return Wrap(key: CustomerCardKeys.metrics, spacing: 8, runSpacing: 8, children: chips);
  }

  static Widget _tap(VoidCallback? onTap, Widget child) => onTap == null
      ? child
      : MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(onTap: onTap, child: child),
        );
}

/// Z6 — контакты и адреса (только чтение, CUST-019).
class _Contacts extends StatelessWidget {
  const _Contacts({required this.customer});

  final Customer customer;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<Widget> rows = <Widget>[
      for (final String a in customer.addresses) AppListTile(leadingIcon: Icons.location_on_outlined, title: a),
      for (final CustomerContact k in customer.contacts)
        AppListTile(
          leadingIcon: switch (k.kind) {
            ContactKind.phone => Icons.call_outlined,
            ContactKind.address => Icons.location_on_outlined,
            ContactKind.email => Icons.mail_outline_rounded,
            _ => Icons.contact_page_outlined,
          },
          title: k.kind == ContactKind.phone ? CustomersFormat.phone(k.value) : k.value,
          subtitle: k.name,
        ),
    ];
    return Column(
      key: CustomerCardKeys.contacts,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(height: context.space.s4),
        AppSectionHeader(title: l10n.customer_card_contacts_title, padding: EdgeInsets.zero),
        if (rows.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: context.space.s2),
            child: Text(
              l10n.customer_card_contacts_empty,
              style: context.text.body.copyWith(color: context.colors.textSecondary),
            ),
          )
        else
          ...rows,
      ],
    );
  }
}

/// Z7 — привязки пользователей приложения (просмотр; `admin` — переход к разрешению на SCR-45).
class _Links extends StatelessWidget {
  const _Links({required this.customer, required this.viewer});

  final Customer customer;
  final CustomersViewer viewer;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Column(
      key: CustomerCardKeys.links,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(height: context.space.s4),
        AppSectionHeader(
          title: l10n.customer_card_links_title,
          padding: EdgeInsets.zero,
          actionLabel: viewer.canResolveLinks ? l10n.ds_button_open : null,
          onAction: viewer.canResolveLinks ? () => CustomersNav.resolveLinks(context) : null,
        ),
        for (final link in customer.links)
          AppListTile(
            leadingIcon: Icons.person_outline_rounded,
            title: link.user?.displayName ?? link.userId ?? link.id,
            subtitle: link.user?.phoneMasked,
            // Узкая боковая колонка expanded (Z7 справа): чип статуса уменьшается, а не переполняет строку.
            trailing: link.status == null
                ? null
                : Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: StatusChip(
                        label: CustomersTexts.linkStatus(l10n, link.status!),
                        variant: switch (link.status!) {
                          CustomerLinkStatus.confirmed => StatusChipVariant.success,
                          CustomerLinkStatus.proposed => StatusChipVariant.info,
                          CustomerLinkStatus.conflict => StatusChipVariant.warning,
                          CustomerLinkStatus.rejected => StatusChipVariant.neutral,
                        },
                        dense: true,
                      ),
                    ),
                  ),
          ),
      ],
    );
  }
}
