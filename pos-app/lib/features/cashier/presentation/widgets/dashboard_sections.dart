// Зоны SCR-30 (02 SCR-30.2, SCR-30.3): Z1 баннер ошибок синхронизации (UI-30-001) и незавершённой операции,
// Z2 поиск клиента и быстрые действия (UI-30-002, UI-30-003, UI-30-011), Z3 избранные клиенты (UI-30-005),
// Z4 очередь оплаты (UI-30-004, UI-30-012), Z5 сводка смены и недавние операции (UI-30-014, UI-30-006, UI-30-015),
// Z6 долги и просрочки (UI-30-007, UI-30-008), Z7 скидки и условия (UI-30-009), Z8 синхронизация (UI-30-010).
// Источник каждого блока — подпись «данные 1С от HH:MM» у данных 1С (CASH-011, AC-UI-30-002). Только отображение;
// переходы и действия — колбэки экрана.
import 'package:flutter/material.dart' hide SearchBar;
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/transaction.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_list_tile.dart';
import 'package:optomstroy/design_system/components/app_section_header.dart';
import 'package:optomstroy/design_system/components/awaiting_payment_list.dart';
import 'package:optomstroy/design_system/components/category_chip.dart';
import 'package:optomstroy/design_system/components/date_range_picker.dart' show DsBishkekTime;
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/order_status_chip.dart';
import 'package:optomstroy/design_system/components/search_bar.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/components/sync_indicator.dart';
import 'package:optomstroy/design_system/components/transaction_row.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/cashier/domain/entities/pos_dashboard.dart';
import 'package:optomstroy/features/cashier/presentation/cashier_format.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_terms.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

/// Карточка зоны (`surface`, граница `border`, `ds.radius.md`).
class DashboardCard extends StatelessWidget {
  /// Создаёт карточку.
  const DashboardCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Container(
      padding: EdgeInsets.all(context.space.s4),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.all(context.radii.md),
      ),
      child: child,
    );
  }
}

/// Подпись сущности обмена (`sync_entity_*`).
String syncEntityLabel(AppLocalizations l10n, SyncServerEntity e) => switch (e.entity) {
  SyncEntity.stock => l10n.sync_entity_stock,
  SyncEntity.prices => l10n.sync_entity_prices,
  SyncEntity.receivables => l10n.sync_entity_receivables,
  SyncEntity.customers => l10n.sync_entity_customers,
  SyncEntity.products => l10n.sync_entity_products,
  SyncEntity.variants => l10n.sync_entity_variants,
  SyncEntity.categories => l10n.sync_entity_categories,
  SyncEntity.discounts => l10n.sync_entity_discounts,
  SyncEntity.orderStatus => l10n.sync_entity_order_status,
  _ => e.entityValue,
};

/// Z1: баннер ошибок обмена с 1С (UI-30-001): не закрывается, пока ошибка активна; сущность — самая старая из
/// устаревших, время последнего успешного обмена, число ошибок (`consecutiveErrors`).
class DashboardSyncBanner extends StatelessWidget {
  /// Создаёт баннер.
  const DashboardSyncBanner({super.key, required this.overall, required this.status, required this.onOpen});

  /// `sync.overall` дашборда (`null` — неизвестное значение → degraded).
  final DashboardSyncOverall? overall;

  /// `GET /sync/status` (может отсутствовать).
  final SyncServerStatus? status;

  /// «Открыть» → SCR-43 `?entity=`.
  final ValueChanged<String?> onOpen;

  @override
  Widget build(BuildContext context) {
    if (overall == DashboardSyncOverall.ok) return const SizedBox.shrink();
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final bool failed = overall == DashboardSyncOverall.failed;
    SyncServerEntity? worst;
    for (final SyncServerEntity e in status?.entities ?? const <SyncServerEntity>[]) {
      if (!e.isStale && e.consecutiveErrors == 0) continue;
      if (worst == null ||
          (e.lastSuccessAt != null &&
              (worst.lastSuccessAt == null || e.lastSuccessAt!.isBefore(worst.lastSuccessAt!)))) {
        worst = e;
      }
    }
    final String text;
    if (worst == null) {
      text = l10n.ds_sync_error;
    } else {
      final String entity = syncEntityLabel(l10n, worst);
      final String time = worst.lastSuccessAt == null ? '—' : DsBishkekTime.dateTime(worst.lastSuccessAt!);
      text = worst.consecutiveErrors > 0
          ? l10n.cashier_sync_banner(worst.consecutiveErrors, entity, time)
          : l10n.cashier_sync_banner_no_count(entity, time);
    }
    return Container(
      key: const ValueKey<String>('cashier-sync-banner'),
      constraints: const BoxConstraints(minHeight: 48),
      padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s2),
      decoration: BoxDecoration(
        color: failed ? c.errorContainer : c.warningContainer,
        borderRadius: BorderRadius.all(context.radii.md),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            failed ? Icons.sync_problem_rounded : Icons.warning_amber_rounded,
            size: 20,
            color: failed ? c.error : c.warning,
          ),
          SizedBox(width: context.space.s2),
          Expanded(
            child: Text(
              text,
              style: context.text.body.copyWith(color: c.textPrimary, fontWeight: FontWeight.w500),
            ),
          ),
          AppButton(
            key: const ValueKey<String>('cashier-sync-banner-open'),
            label: l10n.ds_button_open,
            variant: AppButtonVariant.text,
            size: AppButtonSize.s,
            onPressed: () => onOpen(worst?.entityValue),
          ),
        ],
      ),
    );
  }
}

/// Баннер «Незавершённая операция: {описание} · Проверить» (SCR-30.11, P-IDEMP).
class DashboardUnfinishedBanner extends StatelessWidget {
  /// Создаёт баннер.
  const DashboardUnfinishedBanner({super.key, required this.description, required this.onCheck});

  final String description;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    return Container(
      key: const ValueKey<String>('cashier-unfinished'),
      padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s2),
      decoration: BoxDecoration(color: c.warningContainer, borderRadius: BorderRadius.all(context.radii.md)),
      child: Row(
        children: <Widget>[
          Icon(Icons.warning_amber_rounded, size: 20, color: c.warning),
          SizedBox(width: context.space.s2),
          Expanded(
            child: Text(
              l10n.cashier_unfinished_operation(description),
              style: context.text.body.copyWith(color: c.textPrimary, fontFeatures: DsTypography.numeric),
            ),
          ),
          AppButton(
            key: const ValueKey<String>('cashier-unfinished-check'),
            label: l10n.cashier_unfinished_check,
            variant: AppButtonVariant.outlined,
            size: AppButtonSize.s,
            onPressed: onCheck,
          ),
        ],
      ),
    );
  }
}

/// Z2: поиск клиента, «Принять оплату» и «Каталог», быстрые чипы.
class DashboardQuickActions extends StatelessWidget {
  /// Создаёт зону.
  const DashboardQuickActions({
    super.key,
    required this.searchController,
    required this.searchFocus,
    required this.onSearch,
    required this.onSearchChanged,
    required this.searchTooShort,
    required this.onAcceptPayment,
    required this.onCatalog,
    required this.online,
    this.onNewCustomer,
    this.onReturn,
    this.onParked,
  });

  final TextEditingController searchController;
  final FocusNode searchFocus;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onSearchChanged;

  /// «Введите не менее 2 символов».
  final bool searchTooShort;

  /// `null` — роль без кассовых действий (кнопка не рендерится).
  final VoidCallback? onAcceptPayment;
  final VoidCallback onCatalog;
  final bool online;
  final VoidCallback? onNewCustomer;
  final VoidCallback? onReturn;
  final VoidCallback? onParked;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final List<Widget> chips = <Widget>[
      if (onNewCustomer != null)
        CategoryChip(
          key: const ValueKey<String>('cashier-chip-new-customer'),
          label: l10n.customer_new_title,
          icon: Icons.person_add_alt_outlined,
          onTap: onNewCustomer,
        ),
      if (onReturn != null)
        CategoryChip(
          key: const ValueKey<String>('cashier-chip-return'),
          label: l10n.transaction_details_action_return,
          icon: Icons.assignment_return_outlined,
          onTap: onReturn,
          enabled: online,
        ),
      if (onParked != null)
        CategoryChip(
          key: const ValueKey<String>('cashier-chip-parked'),
          label: l10n.parked_title,
          icon: Icons.bookmark_outline_rounded,
          onTap: onParked,
        ),
    ];
    final Widget accept = AppButton(
      key: const ValueKey<String>('cashier-accept-payment'),
      label: l10n.cashier_action_accept_payment,
      icon: Icons.point_of_sale_outlined,
      size: AppButtonSize.l,
      expand: true,
      fitLabel: true,
      onPressed: online ? onAcceptPayment : null,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SearchBar(
          key: const ValueKey<String>('cashier-search'),
          variant: SearchBarVariant.customers,
          controller: searchController,
          focusNode: searchFocus,
          placeholder: l10n.cashier_search_placeholder,
          semanticLabel: l10n.cashier_search_placeholder,
          onChanged: onSearchChanged,
          onSubmitted: onSearch,
        ),
        if (searchTooShort)
          Padding(
            padding: EdgeInsets.only(top: context.space.s1),
            child: Text(
              l10n.cashier_search_too_short,
              key: const ValueKey<String>('cashier-search-too-short'),
              style: context.text.caption.copyWith(color: c.error),
            ),
          ),
        SizedBox(height: context.space.s3),
        Row(
          children: <Widget>[
            if (onAcceptPayment != null) ...<Widget>[
              Expanded(
                child: online ? accept : Tooltip(message: l10n.cashier_action_offline_hint, child: accept),
              ),
              SizedBox(width: context.space.s3),
            ],
            Expanded(
              child: AppButton(
                key: const ValueKey<String>('cashier-catalog'),
                label: l10n.cashier_action_catalog,
                icon: Icons.category_outlined,
                variant: AppButtonVariant.outlined,
                size: AppButtonSize.l,
                expand: true,
                fitLabel: true,
                onPressed: onCatalog,
              ),
            ),
          ],
        ),
        if (chips.isNotEmpty) ...<Widget>[
          SizedBox(height: context.space.s3),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                for (int i = 0; i < chips.length; i++) ...<Widget>[
                  if (i > 0) SizedBox(width: context.space.s2),
                  chips[i],
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Индикатор долга без суммы (`ReceivableBadge.compact`, 03 §9.37; ядро §22.13 п. 1).
Widget? debtIndicator(AppLocalizations l10n, Customer c) {
  if (c.isOverdue == true) {
    return StatusChip(label: l10n.ds_receivable_overdue, variant: StatusChipVariant.error, dense: true);
  }
  if (c.hasDebt == true) {
    return StatusChip(label: l10n.ds_receivable_has_debt, variant: StatusChipVariant.warning, dense: true);
  }
  return null;
}

/// Z3: избранные клиенты (до 12): compact — лента карточек 160×96, иначе — сетка.
class DashboardFavorites extends StatelessWidget {
  /// Создаёт зону.
  const DashboardFavorites({
    super.key,
    required this.customers,
    required this.loading,
    required this.horizontal,
    required this.onOpen,
    required this.onAll,
    required this.onMenu,
  });

  final List<Customer> customers;
  final bool loading;

  /// Лента (compact).
  final bool horizontal;
  final ValueChanged<Customer> onOpen;
  final VoidCallback onAll;

  /// Долгое нажатие / правый клик — контекстное меню (позиция — глобальная точка).
  final void Function(Customer customer, Offset? position) onMenu;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Widget body;
    if (loading) {
      body = SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: Row(
          children: <Widget>[
            for (int i = 0; i < 3; i++) ...<Widget>[
              if (i > 0) SizedBox(width: context.space.s2),
              const SkeletonBox(width: 160, height: 96),
            ],
          ],
        ),
      );
    } else if (customers.isEmpty) {
      body = Text(
        l10n.cashier_favorites_empty,
        key: const ValueKey<String>('cashier-favorites-empty'),
        style: context.text.body.copyWith(color: context.colors.textSecondary),
      );
    } else if (horizontal) {
      body = SizedBox(
        height: 96,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: customers.length,
          separatorBuilder: (_, _) => SizedBox(width: context.space.s2),
          itemBuilder: (BuildContext ctx, int i) => SizedBox(
            width: 160,
            child: _FavoriteCard(customer: customers[i], onOpen: onOpen, onMenu: onMenu),
          ),
        ),
      );
    } else {
      body = LayoutBuilder(
        builder: (BuildContext ctx, BoxConstraints box) {
          final double w = (box.maxWidth - context.space.s2) / 2; // money-double: allow — ширина карточки, lp
          return Wrap(
            spacing: context.space.s2,
            runSpacing: context.space.s2,
            children: <Widget>[
              for (final Customer c in customers)
                SizedBox(
                  width: w,
                  height: 96,
                  child: _FavoriteCard(customer: c, onOpen: onOpen, onMenu: onMenu),
                ),
            ],
          );
        },
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppSectionHeader(
          title: l10n.cashier_favorites_title,
          actionLabel: l10n.customers_search_filter_all,
          onAction: onAll,
          padding: EdgeInsets.zero,
        ),
        SizedBox(height: context.space.s2),
        body,
      ],
    );
  }
}

class _FavoriteCard extends StatelessWidget {
  const _FavoriteCard({required this.customer, required this.onOpen, required this.onMenu});

  final Customer customer;
  final ValueChanged<Customer> onOpen;
  final void Function(Customer customer, Offset? position) onMenu;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final Widget? badge = debtIndicator(l10n, customer);
    return GestureDetector(
      onSecondaryTapDown: (TapDownDetails d) => onMenu(customer, d.globalPosition),
      child: DsInteractive(
        key: ValueKey<String>('cashier-favorite-${customer.id}'),
        onTap: () => onOpen(customer),
        onLongPress: () => onMenu(customer, null),
        builder: (BuildContext context, DsInteractionState s) => Container(
          padding: EdgeInsets.all(context.space.s3),
          decoration: BoxDecoration(
            color: s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : c.surface),
            border: Border.all(color: c.border),
            borderRadius: BorderRadius.all(context.radii.md),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Text(
                      customer.displayName ?? customer.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodyMedium.copyWith(color: c.textPrimary, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Icon(Icons.star_rounded, size: 16, color: c.favorite),
                ],
              ),
              const Spacer(),
              ?badge,
            ],
          ),
        ),
      ),
    );
  }
}

/// Строки «Ожидают оплаты» из дашборда: заказы с открытым платежом, таймер QR — по `qrPending`.
List<AwaitingPaymentEntry> awaitingEntries(
  AppLocalizations l10n,
  PosDashboard d,
  DateTime nowUtc, {
  required void Function(OrderSummary order)? onTap,
}) {
  final Map<String, Payment> qrByOrder = <String, Payment>{
    for (final Payment p in d.qrPending)
      if (p.orderId != null) p.orderId!: p,
  };
  return <AwaitingPaymentEntry>[
    for (final OrderSummary o in d.awaitingPayment)
      () {
        final Payment? qr = qrByOrder[o.id];
        final DateTime? until = qr?.status == PaymentStatus.qrShown ? qr?.qr?.expiresAt : null;
        final String customer = o.customer?.displayName ?? o.customer?.name ?? '';
        final Money due = (o.totalToPay ?? o.total) - (o.paidAmount ?? Money.zero);
        return AwaitingPaymentEntry(
          id: o.id,
          title: <String>[o.publicNumber, if (customer.isNotEmpty) customer].join(' · '),
          subtitle: o.createdAt == null ? null : DsBishkekTime.stamp(o.createdAt!, nowUtc),
          amountText: CashierFormat.money(due.isNegative ? Money.zero : due),
          status: OrderStatusChip(status: o.status, dense: true),
          note: until == null ? null : CashierFormat.countdown(until.difference(nowUtc)),
          onTap: onTap == null ? null : () => onTap(o),
        );
      }(),
  ];
}

/// Строки «Требуют разбора» (`manual_confirm`, PAY-024).
List<AwaitingPaymentEntry> reviewEntries(
  AppLocalizations l10n,
  PosDashboard d, {
  required void Function(Payment payment) onTap,
}) => <AwaitingPaymentEntry>[
  for (final Payment p in d.manualConfirm)
    AwaitingPaymentEntry(
      id: p.id,
      title: p.reviewReason == null
          ? l10n.payment_review_no_webhook
          : PaymentStatusChip.reviewLabelOf(l10n, p.reviewReason!),
      amountText: CashierFormat.money(p.amount),
      status: PaymentStatusChip(status: p.status, dense: true),
      onTap: () => onTap(p),
    ),
];

/// Подпись вида операции (`transactions_kind_*`).
String transactionKindLabel(AppLocalizations l10n, TransactionKind? k) => switch (k) {
  TransactionKind.orderCreated => l10n.transactions_kind_order_created,
  TransactionKind.orderCancelled => l10n.transactions_kind_order_cancelled,
  TransactionKind.paymentReceived => l10n.transactions_kind_payment_received,
  TransactionKind.paymentVoided => l10n.transactions_kind_payment_voided,
  TransactionKind.refund => l10n.transactions_kind_refund,
  TransactionKind.discountOverride => l10n.transactions_kind_discount_override,
  TransactionKind.creditSaleApproved => l10n.transactions_kind_credit_sale_approved,
  TransactionKind.manualQrConfirm => l10n.transactions_kind_manual_qr_confirm,
  TransactionKind.returnRequested => l10n.transactions_kind_return_requested,
  null => '',
};

/// Строка недавней операции (UI-30-006).
Widget recentRow(
  BuildContext context,
  AppLocalizations l10n,
  Transaction t, {
  required bool compactWindow,
  required VoidCallback onTap,
}) {
  final String title = <String>[
    '${transactionKindLabel(l10n, t.kind)} № ${t.number}',
    ?t.customer?.displayName,
  ].join(' · ');
  final String sub = <String>[DsBishkekTime.time(t.occurredAt), ?t.actor?.displayName].join(' · ');
  final TransactionRowAmountTone tone = TransactionRow.toneOf(
    t.kind,
    plus: t.sign == null ? null : t.sign == TransactionSign.plus,
  );
  return TransactionRow(
    key: ValueKey<String>('cashier-recent-${t.id}'),
    kind: t.kind,
    title: title,
    subtitle: sub,
    amountText: CashierFormat.money(t.amount),
    tone: tone,
    compactWindow: compactWindow,
    onTap: onTap,
  );
}

/// Z6: долги и просрочки (снимок 1С, P-STALE; AC-UI-30-002: подпись «Данные 1С на HH:MM», устаревший снимок —
/// предупреждение и «Обновить»).
class DashboardDebts extends StatelessWidget {
  /// Создаёт зону.
  const DashboardDebts({
    super.key,
    required this.overdue,
    required this.asOf,
    required this.nowUtc,
    required this.maxRows,
    required this.onOpen,
    required this.onAll,
    this.serverStale,
    this.onRefresh,
    this.refreshing = false,
    this.staleAfter = const Duration(minutes: 60),
  });

  /// Верхняя граница `overdue[]` в ответе `GET /pos/dashboard` (08 §4.10.1, `maxItems: 10`).
  static const int overdueLimit = 10;

  final List<PosDashboardOverdueItem> overdue;

  /// `sync.receivablesAsOf` — `null`: снимка нет.
  final DateTime? asOf;
  final DateTime nowUtc;
  final int maxRows;
  final ValueChanged<String> onOpen;
  final VoidCallback onAll;

  /// Устаревание снимка долгов по серверу (`GET /sync/status`, сущность `receivables`, `isStale` — порог
  /// `receivables.max_age_minutes`, SCR-46.1); `null` — статус не загружен: запасной порог [staleAfter].
  final bool? serverStale;

  /// «Обновить» при устаревшем снимке (перечитать `GET /pos/dashboard`); `null` — действия нет.
  final VoidCallback? onRefresh;

  /// Обновление выполняется.
  final bool refreshing;

  /// Запасной порог `RECEIVABLES_MAX_AGE_MIN` (60 мин) — только пока сервер не сообщил `isStale`.
  final Duration staleAfter;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final DateTime? when = asOf ?? (overdue.isEmpty ? null : overdue.first.asOf);
    final bool stale = when != null && (serverStale ?? nowUtc.difference(when) > staleAfter);
    final List<Widget> children = <Widget>[AppSectionHeader(title: l10n.cashier_debts_title, padding: EdgeInsets.zero)];
    if (when == null && overdue.isEmpty) {
      children.add(
        Text(
          l10n.cashier_debts_no_data,
          key: const ValueKey<String>('cashier-debts-no-data'),
          style: context.text.body.copyWith(color: c.textSecondary),
        ),
      );
    } else {
      if (overdue.isEmpty) {
        children.add(
          Row(
            children: <Widget>[
              StatusChip(label: l10n.cashier_debts_none, variant: StatusChipVariant.success, dense: true),
            ],
          ),
        );
      } else if (overdue.length >= overdueLimit) {
        // Ответ усечён до топ-10: сумма и число клиентов по этому списку занижены (DEBT-001, D-24 — итоги долга
        // только с сервера; GQ-FECASH-09) — вместо итога ссылка на полный список «Все просрочки».
        children.add(
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: AppButton(
              key: const ValueKey<String>('cashier-debts-summary-all'),
              label: l10n.cashier_debts_all,
              variant: AppButtonVariant.tonal,
              size: AppButtonSize.s,
              trailingIcon: Icons.chevron_right_rounded,
              onPressed: onAll,
            ),
          ),
        );
      } else {
        final Money sum = Money.sum(overdue.map((PosDashboardOverdueItem o) => o.overdueAmount));
        children.add(
          DsInteractive(
            key: const ValueKey<String>('cashier-debts-summary'),
            onTap: onAll,
            builder: (BuildContext ctx, DsInteractionState s) => Text(
              l10n.cashier_debts_summary(CashierFormat.money(sum), overdue.length),
              style: context.text.h3.copyWith(
                color: c.error,
                fontWeight: FontWeight.w700,
                fontFeatures: DsTypography.numeric,
              ),
            ),
          ),
        );
      }
      if (when != null) {
        children.add(
          Padding(
            padding: EdgeInsets.only(top: context.space.s1),
            child: SyncIndicator.inline(
              key: const ValueKey<String>('cashier-debts-as-of'),
              time: when,
              stale: stale,
              now: nowUtc,
              label: l10n.receivables_as_of(CashierFormat.stamp(when, nowUtc)),
            ),
          ),
        );
        if (stale) {
          children.add(
            Padding(
              padding: EdgeInsets.only(top: context.space.s2),
              child: Wrap(
                spacing: context.space.s2,
                runSpacing: context.space.s1,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  StatusChip(
                    key: const ValueKey<String>('cashier-debts-stale'),
                    label: l10n.receivables_stale(CashierFormat.stamp(when, nowUtc)),
                    variant: StatusChipVariant.warning,
                    dense: true,
                  ),
                  if (onRefresh != null)
                    AppButton(
                      key: const ValueKey<String>('cashier-debts-refresh'),
                      label: l10n.receivables_refresh,
                      icon: Icons.refresh_rounded,
                      variant: AppButtonVariant.outlined,
                      size: AppButtonSize.s,
                      loading: refreshing,
                      onPressed: refreshing ? null : onRefresh,
                    ),
                ],
              ),
            ),
          );
        }
      }
      for (final PosDashboardOverdueItem o in overdue.take(maxRows)) {
        children.add(
          AppListTile(
            key: ValueKey<String>('cashier-debt-${o.customer.id}'),
            leading: Icon(Icons.error_outline_rounded, size: 20, color: c.error),
            title: o.customer.displayName ?? o.customer.name,
            subtitle: l10n.receivables_overdue(CashierFormat.money(o.overdueAmount), o.overdueDays),
            showChevron: true,
            onTap: () => onOpen(o.customer.id),
          ),
        );
      }
      children.add(
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: AppButton(
            key: const ValueKey<String>('cashier-debts-all'),
            label: l10n.cashier_debts_all,
            variant: AppButtonVariant.text,
            size: AppButtonSize.s,
            trailingIcon: Icons.chevron_right_rounded,
            onPressed: onAll,
          ),
        ),
      );
    }
    return DashboardCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }
}

/// Z7: лимит ручной скидки роли, кто подтверждает сверх лимита, число правил 1С (`GET /discounts/rules`).
class DashboardDiscounts extends StatelessWidget {
  /// Создаёт зону.
  const DashboardDiscounts({super.key, required this.info, required this.failed, required this.onMore});

  final DiscountRulesInfo? info;
  final bool failed;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final DiscountRulesInfo? i = info;
    final List<Widget> rows;
    if (i == null) {
      rows = <Widget>[
        if (failed)
          Text(l10n.customer_discounts_rules_empty, style: context.text.body.copyWith(color: c.textSecondary))
        else
          const SkeletonBox.text(width: 200),
      ];
    } else {
      final int onec = i.rules.where((DiscountRule r) => r.source == null || r.source == DiscountSource.onec).length;
      Widget line(String text) => Padding(
        padding: EdgeInsets.symmetric(vertical: context.space.s2),
        child: Text(
          text,
          style: context.text.body.copyWith(color: c.textPrimary, fontFeatures: DsTypography.numeric),
        ),
      );
      rows = <Widget>[
        line(l10n.cashier_discounts_limit(CashierFormat.percent(i.manualDiscountLimitPercent))),
        if (i.overrideRoles.isNotEmpty)
          line(
            l10n.cashier_discounts_override(
              i.overrideRoles.map((RoleCode r) => CashierFormat.role(l10n, r)).join(', '),
            ),
          ),
        AppListTile(
          title: l10n.cashier_discounts_rules_count(onec),
          trailing: StatusChip(
            label: l10n.customer_discounts_rule_source_onec,
            variant: StatusChipVariant.info,
            dense: true,
          ),
        ),
      ];
    }
    return DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AppSectionHeader(
            title: l10n.cashier_discounts_title,
            actionLabel: onMore == null ? null : l10n.notifications_action_details,
            onAction: onMore,
            padding: EdgeInsets.zero,
          ),
          ...rows,
        ],
      ),
    );
  }
}

/// Z8: время обмена по сущностям (`GET /sync/status`), «Открыть статус» → SCR-43. Запуска синхронизации нет.
class DashboardSyncCard extends StatelessWidget {
  /// Создаёт зону.
  const DashboardSyncCard({
    super.key,
    required this.overall,
    required this.status,
    required this.onOpen,
    this.stockAsOf,
    this.receivablesAsOf,
  });

  final DashboardSyncOverall? overall;
  final SyncServerStatus? status;
  final VoidCallback onOpen;

  /// `PosDashboard.sync.stockAsOf`.
  final DateTime? stockAsOf;

  /// `PosDashboard.sync.receivablesAsOf`.
  final DateTime? receivablesAsOf;

  Widget _fallback(BuildContext context, String title, DateTime at, String key) => AppListTile(
    key: ValueKey<String>('cashier-sync-$key'),
    leading: Icon(Icons.schedule_rounded, size: 20, color: context.colors.textSecondary),
    title: title,
    trailing: Text(
      DsBishkekTime.time(at),
      style: context.text.body.copyWith(color: context.colors.textPrimary, fontFeatures: DsTypography.numeric),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final List<SyncEntity> shown = <SyncEntity>[SyncEntity.stock, SyncEntity.prices, SyncEntity.receivables];
    return DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: AppSectionHeader(title: l10n.cashier_sync_title, padding: EdgeInsets.zero),
              ),
              SyncIndicator(
                variant: switch (overall) {
                  DashboardSyncOverall.ok => SyncIndicatorVariant.ok,
                  DashboardSyncOverall.failed => SyncIndicatorVariant.error,
                  _ => SyncIndicatorVariant.stale,
                },
                compact: true,
              ),
            ],
          ),
          if (status == null) ...<Widget>[
            // `GET /sync/status` не получен — время снимков из дашборда (`sync.stockAsOf`, `sync.receivablesAsOf`).
            if (stockAsOf != null) _fallback(context, l10n.sync_entity_stock, stockAsOf!, 'stock'),
            if (receivablesAsOf != null)
              _fallback(context, l10n.sync_entity_receivables, receivablesAsOf!, 'receivables'),
          ],
          for (final SyncEntity e in shown)
            if (status?.entity(e) case final SyncServerEntity s?)
              AppListTile(
                key: ValueKey<String>('cashier-sync-${e.value}'),
                leading: Icon(
                  s.running
                      ? Icons.sync_rounded
                      : (s.consecutiveErrors > 0
                            ? Icons.sync_problem_rounded
                            : (s.isStale ? Icons.warning_amber_rounded : Icons.check_circle_outline_rounded)),
                  size: 20,
                  color: s.consecutiveErrors > 0 ? c.error : (s.isStale ? c.warning : c.success),
                ),
                title: syncEntityLabel(l10n, s),
                trailing: Text(
                  s.lastSuccessAt == null ? '—' : DsBishkekTime.time(s.lastSuccessAt!),
                  style: context.text.body.copyWith(color: c.textPrimary, fontFeatures: DsTypography.numeric),
                ),
              ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: AppButton(
              key: const ValueKey<String>('cashier-sync-open'),
              label: l10n.cashier_sync_open,
              variant: AppButtonVariant.text,
              size: AppButtonSize.s,
              onPressed: onOpen,
            ),
          ),
        ],
      ),
    );
  }
}
