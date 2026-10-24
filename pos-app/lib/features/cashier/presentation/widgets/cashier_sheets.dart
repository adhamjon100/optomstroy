// Листы SCR-30: «Найти заказ или клиента» (UI-30-016; режимы «оплата» и «возврат»), «Все просрочки» (UI-30-017;
// `GET /receivables/overdue` с курсором и сортировкой — сервер пишет `receivables.overdue_viewed`), «Правила скидок»
// (UI-30-009; `GET /discounts/rules`). Финансовые данные — только память листа (CASH-015).
import 'dart:async';

import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_list_tile.dart';
import 'package:optomstroy/design_system/components/app_tabs.dart';
import 'package:optomstroy/design_system/components/customer_card.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/order_status_chip.dart';
import 'package:optomstroy/design_system/components/search_bar.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/sort_menu.dart';
import 'package:optomstroy/design_system/components/transaction_row.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/cashier/presentation/cashier_format.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_terms.dart';
import 'package:optomstroy/features/customers/domain/entities/receivable.dart';
import 'package:optomstroy/features/customers/domain/repositories/customers_repository.dart';
import 'package:optomstroy/features/customers/domain/repositories/receivables_repository.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/orders_providers.dart';

/// Режим листа поиска: приём оплаты или заявка на возврат (RET-002).
enum CashierLookupMode { payment, returnRequest }

/// Выбор в листе поиска.
sealed class CashierLookupResult {
  const CashierLookupResult();
}

/// Выбран заказ.
final class LookupOrder extends CashierLookupResult {
  const LookupOrder(this.orderId);

  final String orderId;
}

/// Выбран клиент (оплата долга, RM-G-013).
final class LookupCustomer extends CashierLookupResult {
  const LookupCustomer(this.customerId);

  final String customerId;
}

/// Статусы заказов к оплате (ядро §22.5) и к возврату (RET-002).
const Set<OrderStatus> kLookupPayableStatuses = <OrderStatus>{
  OrderStatus.submitting,
  OrderStatus.pendingApproval,
  OrderStatus.awaitingPayment,
  OrderStatus.approved,
};

/// Статусы заказов, по которым оформляется возврат.
const Set<OrderStatus> kLookupReturnStatuses = <OrderStatus>{OrderStatus.shipped, OrderStatus.partiallyReturned};

/// Показать лист «Найти заказ или клиента» (compact — лист 92 %, medium+ — диалог 560).
Future<CashierLookupResult?> showCashierLookup(
  BuildContext context, {
  CashierLookupMode mode = CashierLookupMode.payment,
  String? initialQuery,
  bool debtTab = false,
}) {
  final AppLocalizations l10n = AppLocalizations.of(context);
  final Widget body = CashierLookupSheet(mode: mode, initialQuery: initialQuery, debtTab: debtTab);
  if (context.windowClass == WindowClass.compact) {
    return AppBottomSheet.show<CashierLookupResult>(
      context,
      title: l10n.cashier_lookup_title,
      body: body,
      variant: AppBottomSheetVariant.fullHeight,
    );
  }
  return showDialog<CashierLookupResult>(
    context: context,
    barrierColor: context.colors.overlay,
    builder: (BuildContext ctx) => Dialog(
      backgroundColor: ctx.colors.surface,
      surfaceTintColor: ctx.colors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(ctx.radii.lg)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: MediaQuery.sizeOf(ctx).height * 0.8),
        child: Padding(
          padding: EdgeInsets.all(ctx.space.s6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(l10n.cashier_lookup_title, style: ctx.text.h3.copyWith(color: ctx.colors.textPrimary)),
              SizedBox(height: ctx.space.s4),
              Flexible(child: body),
            ],
          ),
        ),
      ),
    ),
  );
}

enum _LookupTab { order, customer }

/// Содержимое листа поиска (вкладка «Клиент (долг)» — только при `features.debtPaymentsFromPos`, RM-G-013).
class CashierLookupSheet extends ConsumerStatefulWidget {
  /// Создаёт лист.
  const CashierLookupSheet({super.key, this.mode = CashierLookupMode.payment, this.initialQuery, this.debtTab = false});

  final CashierLookupMode mode;
  final String? initialQuery;

  /// Показать вкладку «Клиент (долг)».
  final bool debtTab;

  @override
  ConsumerState<CashierLookupSheet> createState() => _CashierLookupSheetState();
}

class _CashierLookupSheetState extends ConsumerState<CashierLookupSheet> {
  late final TextEditingController _q = TextEditingController(text: widget.initialQuery ?? '');
  _LookupTab _tab = _LookupTab.order;
  Timer? _debounce;
  bool _loading = false;
  Failure? _failure;
  List<OrderSummary>? _orders;
  List<Customer>? _customers;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    if ((widget.initialQuery ?? '').trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_search()));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => unawaited(_search()));
  }

  Future<void> _search() async {
    final String q = _q.text.trim();
    final int seq = ++_seq;
    if (q.length < 2) {
      setState(() {
        _orders = null;
        _customers = null;
        _failure = null;
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    if (_tab == _LookupTab.order) {
      final Result<OrdersPage> r = await ref
          .read(ordersRepositoryProvider)
          .list(
            OrdersQuery(
              q: q,
              statuses: widget.mode == CashierLookupMode.payment ? kLookupPayableStatuses : kLookupReturnStatuses,
              limit: 20,
            ),
          );
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _failure = r.failureOrNull;
        _orders = r.valueOrNull?.page.items;
      });
    } else {
      final Result<PageResult<Customer>> r = await ref
          .read(customersRepositoryProvider)
          .search(CustomerSearchQuery(q: q));
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _failure = r.failureOrNull;
        _customers = r.valueOrNull?.items;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool compact = context.windowClass == WindowClass.compact;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.debtTab && widget.mode == CashierLookupMode.payment) ...<Widget>[
          AppTabs<_LookupTab>(
            tabs: <AppTab<_LookupTab>>[
              AppTab<_LookupTab>(value: _LookupTab.order, label: l10n.cashier_lookup_tab_order),
              AppTab<_LookupTab>(value: _LookupTab.customer, label: l10n.cashier_lookup_tab_customer),
            ],
            value: _tab,
            onChanged: (_LookupTab t) {
              setState(() => _tab = t);
              unawaited(_search());
            },
          ),
          SizedBox(height: context.space.s3),
        ],
        SearchBar(
          key: const ValueKey<String>('cashier-lookup-field'),
          variant: SearchBarVariant.customers,
          controller: _q,
          autofocus: true,
          loading: _loading,
          placeholder: _tab == _LookupTab.order
              ? l10n.cashier_lookup_order_placeholder
              : l10n.cashier_search_placeholder,
          semanticLabel: l10n.cashier_lookup_title,
          onChanged: _onChanged,
          onSubmitted: (_) => unawaited(_search()),
        ),
        SizedBox(height: context.space.s3),
        Flexible(child: _results(context, l10n, compact)),
      ],
    );
  }

  Widget _results(BuildContext context, AppLocalizations l10n, bool compact) {
    if (_failure != null) {
      return ErrorState.inline(
        message: ErrorTexts.message(l10n, UiErrorMapper.fromFailure(_failure!)),
        onRetry: () => unawaited(_search()),
      );
    }
    if (_loading && _orders == null && _customers == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.only(bottom: context.space.s2),
              child: const SkeletonBox(height: 56),
            ),
        ],
      );
    }
    if (_tab == _LookupTab.customer) {
      final List<Customer>? list = _customers;
      if (list == null) return const SizedBox.shrink();
      return ListView(
        shrinkWrap: true,
        children: <Widget>[
          for (final Customer c in list)
            CustomerCard.row(
              key: ValueKey<String>('cashier-lookup-customer-${c.id}'),
              name: c.displayName ?? c.name,
              phone: c.phoneMasked,
              onTap: () => Navigator.of(context).pop(LookupCustomer(c.id)),
            ),
        ],
      );
    }
    final List<OrderSummary>? list = _orders;
    if (list == null) return const SizedBox.shrink();
    if (list.isEmpty) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: context.space.s6),
        child: Text(
          l10n.cashier_lookup_not_found(_q.text.trim()),
          key: const ValueKey<String>('cashier-lookup-empty'),
          textAlign: TextAlign.center,
          style: context.text.body.copyWith(color: context.colors.textSecondary),
        ),
      );
    }
    return ListView(
      shrinkWrap: true,
      children: <Widget>[for (final OrderSummary o in list) _orderRow(context, l10n, o, compact)],
    );
  }

  Widget _orderRow(BuildContext context, AppLocalizations l10n, OrderSummary o, bool compact) {
    final bool paid = o.isPaid;
    final bool disabled = widget.mode == CashierLookupMode.payment && paid;
    final Money total = o.totalToPay ?? o.total;
    final Money paidAmount = o.paidAmount ?? Money.zero;
    final String note = paid
        ? l10n.cashier_lookup_order_paid
        : (paidAmount.isZero
              ? ''
              : l10n.orders_paid_partial(CashierFormat.money(paidAmount), CashierFormat.money(total)));
    final String customer = o.customer?.displayName ?? o.customer?.name ?? '';
    return TransactionRow(
      key: ValueKey<String>('cashier-lookup-order-${o.id}'),
      kind: TransactionKind.orderCreated,
      title: <String>[o.publicNumber, if (customer.isNotEmpty) customer].join(' · '),
      subtitle: o.onec?.number,
      amountText: CashierFormat.money(total),
      status: OrderStatusChip(status: o.status, dense: true),
      note: note.isEmpty ? null : note,
      compactWindow: compact,
      enabled: !disabled,
      onTap: disabled ? null : () => Navigator.of(context).pop(LookupOrder(o.id)),
    );
  }
}

/// Лист «Все просрочки» (UI-30-017): `GET /receivables/overdue` с курсором и сортировкой; тап → SCR-34.
class OverdueSheet extends ConsumerStatefulWidget {
  /// Создаёт лист.
  const OverdueSheet({super.key, required this.onOpen});

  /// Открыть SCR-34 клиента.
  final ValueChanged<String> onOpen;

  /// Показать лист (compact — 92 %, medium+ — боковая панель 640).
  static Future<void> show(BuildContext context, {required ValueChanged<String> onOpen}) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Widget body = OverdueSheet(onOpen: onOpen);
    if (context.windowClass == WindowClass.compact) {
      return AppBottomSheet.show<void>(
        context,
        title: l10n.cashier_debts_all,
        body: body,
        variant: AppBottomSheetVariant.fullHeight,
      );
    }
    return AppBottomSheet.showSide<void>(context, title: l10n.cashier_debts_all, body: body, width: 640);
  }

  @override
  ConsumerState<OverdueSheet> createState() => _OverdueSheetState();
}

class _OverdueSheetState extends ConsumerState<OverdueSheet> {
  OverdueSort _sort = OverdueSort.overdueAmountDesc;
  final List<OverdueReceivable> _items = <OverdueReceivable>[];
  String? _cursor;
  bool _loading = false;
  bool _done = false;
  Failure? _failure;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load(reset: true)));
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading && !reset) return;
    final int seq = ++_seq;
    setState(() {
      _loading = true;
      _failure = null;
      if (reset) {
        _items.clear();
        _cursor = null;
        _done = false;
      }
    });
    final Result<OverdueReceivablesPage> r = await ref
        .read(receivablesRepositoryProvider)
        .overdue(OverdueReceivablesQuery(sort: _sort, cursor: _cursor, limit: 50));
    if (!mounted || seq != _seq) return;
    setState(() {
      _loading = false;
      switch (r) {
        case Success<OverdueReceivablesPage>(:final OverdueReceivablesPage value):
          final Set<String> known = <String>{for (final OverdueReceivable o in _items) o.customer.id};
          _items.addAll(value.page.items.where((OverdueReceivable o) => !known.contains(o.customer.id)));
          _cursor = value.page.nextCursor;
          _done = value.page.nextCursor == null;
        case FailureResult<OverdueReceivablesPage>(:final Failure failure):
          _failure = failure;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: SortMenu<OverdueSort>(
            options: <SortMenuOption<OverdueSort>>[
              SortMenuOption<OverdueSort>(value: OverdueSort.overdueAmountDesc, label: l10n.orders_sort_total),
              SortMenuOption<OverdueSort>(value: OverdueSort.customerNameAsc, label: l10n.catalog_sort_name_asc),
            ],
            selected: _sort,
            semanticLabel: l10n.orders_sort_total,
            onSelected: (OverdueSort s) {
              if (s == _sort) return;
              setState(() => _sort = s);
              unawaited(_load(reset: true));
            },
          ),
        ),
        if (_failure != null && _items.isEmpty)
          ErrorState.inline(
            message: ErrorTexts.message(l10n, UiErrorMapper.fromFailure(_failure!)),
            onRetry: () => unawaited(_load(reset: true)),
          )
        else if (!_loading && _items.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: context.space.s6),
            child: Text(
              l10n.cashier_debts_none,
              textAlign: TextAlign.center,
              style: context.text.body.copyWith(color: context.colors.textSecondary),
            ),
          )
        else
          Flexible(
            child: NotificationListener<ScrollNotification>(
              onNotification: (ScrollNotification n) {
                if (!_done && !_loading && n.metrics.extentAfter < 200) unawaited(_load());
                return false;
              },
              child: ListView(
                shrinkWrap: true,
                children: <Widget>[
                  for (final OverdueReceivable o in _items)
                    CustomerCard.row(
                      key: ValueKey<String>('overdue-${o.customer.id}'),
                      name: o.customer.displayName ?? o.customer.name,
                      meta: l10n.receivables_overdue(CashierFormat.money(o.overdueAmount), o.overdueDays),
                      onTap: () {
                        Navigator.of(context).pop();
                        widget.onOpen(o.customer.id);
                      },
                    ),
                  if (_loading)
                    Padding(padding: EdgeInsets.all(context.space.s4), child: const SkeletonBox(height: 56)),
                  if (_failure != null && _items.isNotEmpty)
                    ErrorState.inline(
                      message: ErrorTexts.message(l10n, UiErrorMapper.fromFailure(_failure!)),
                      onRetry: () => unawaited(_load()),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Лист правил скидок 1С (UI-30-009 «Подробнее» без контекста клиента).
Future<void> showDiscountRulesSheet(BuildContext context, DiscountRulesInfo info) {
  final AppLocalizations l10n = AppLocalizations.of(context);
  final Widget body = info.rules.isEmpty
      ? EmptyState(variant: EmptyStateVariant.search, title: l10n.customer_discounts_rules_empty)
      : Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final DiscountRule r in info.rules)
              AppListTile(
                title: r.name ?? r.id,
                subtitle: r.isActive == false ? l10n.customer_discounts_rule_inactive : null,
                trailing: r.value == null
                    ? null
                    : Text(
                        r.kind == DiscountKind.percent ? '${r.value} %' : r.value!,
                        style: context.text.bodyMedium.copyWith(color: context.colors.textPrimary),
                      ),
              ),
          ],
        );
  return AppBottomSheet.show<void>(context, title: l10n.customer_discounts_rules_title, body: body);
}
