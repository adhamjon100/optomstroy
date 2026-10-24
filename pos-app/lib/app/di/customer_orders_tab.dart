// SCR-32 UI-32-007 «Заказы и операции» (02 SCR-32; 10 CUST-007, TXN-011): сегменты «Заказы» · «Операции» над
// `GET /orders?customerId=` (фича orders) и `GET /transactions?customerId=` (фича transactions). Фича customers не
// импортирует orders/transactions сверх DAG 06 §6.1, поэтому содержимое вкладки собирает композиционный корень
// (порт `customerOrdersTabBuilderProvider`). Первая страница (20 строк) — здесь; «Показать всю историю» ведёт в
// SCR-25 / SCR-36 с фильтром клиента (там — подгрузка по курсору). `seller` видит только свои — фильтрует сервер.
// Финансовые данные — только память виджета (CASH-015).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/routes.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' show TransactionSource;
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/core/models/journal_period.dart';
import 'package:optomstroy/core/models/transaction.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_tabs.dart';
import 'package:optomstroy/design_system/components/date_range_picker.dart' show DsBishkekTime;
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/transaction_row.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/orders_providers.dart';
import 'package:optomstroy/features/orders/presentation/widgets/orders_list_rows.dart';
import 'package:optomstroy/features/transactions/domain/entities/transactions_query.dart';
import 'package:optomstroy/features/transactions/presentation/transactions_format.dart';
import 'package:optomstroy/features/transactions/transactions_providers.dart';

/// Сегмент вкладки.
enum CustomerOrdersSegment { orders, operations }

/// Ключи (тесты, integration_test).
abstract final class CustomerOrdersTabKeys {
  static const Key root = ValueKey<String>('customer-orders-tab');
  static const Key showAllOrders = ValueKey<String>('customer-orders-show-all');
  static const Key showAllOperations = ValueKey<String>('customer-operations-show-all');
  static Key order(String id) => ValueKey<String>('customer-order-$id');
  static Key operation(String id) => ValueKey<String>('customer-operation-$id');
}

/// Строк первой страницы.
const int customerOrdersTabPageSize = 20;

/// Построитель вкладки для порта `customerOrdersTabBuilderProvider`.
Widget customerOrdersTab(BuildContext context, String customerId) =>
    CustomerOrdersTab(key: ValueKey<String>('customer-orders-tab-$customerId'), customerId: customerId);

/// Вкладка «Заказы и операции» карточки клиента.
class CustomerOrdersTab extends ConsumerStatefulWidget {
  const CustomerOrdersTab({required this.customerId, super.key});

  final String customerId;

  @override
  ConsumerState<CustomerOrdersTab> createState() => _CustomerOrdersTabState();
}

sealed class _Load<T> {
  const _Load();
}

final class _Loading<T> extends _Load<T> {
  const _Loading();
}

final class _Loaded<T> extends _Load<T> {
  const _Loaded(this.items, {required this.hasMore});

  final List<T> items;
  final bool hasMore;
}

final class _Failed<T> extends _Load<T> {
  const _Failed(this.failure);

  final Failure failure;
}

class _CustomerOrdersTabState extends ConsumerState<CustomerOrdersTab> {
  CustomerOrdersSegment _segment = CustomerOrdersSegment.orders;
  _Load<OrderSummary> _orders = const _Loading<OrderSummary>();
  _Load<Transaction>? _operations;
  int _ordersSeq = 0;
  int _opsSeq = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadOrders());
  }

  Future<void> _loadOrders() async {
    final int seq = ++_ordersSeq;
    setState(() => _orders = const _Loading<OrderSummary>());
    Result<OrdersPage> r;
    try {
      r = await ref
          .read(ordersRepositoryProvider)
          .list(OrdersQuery(customerId: widget.customerId, limit: customerOrdersTabPageSize));
    } on Object catch (e) {
      r = FailureResult<OrdersPage>(UnknownFailure(cause: e));
    }
    if (!mounted || seq != _ordersSeq) return;
    setState(() {
      _orders = switch (r) {
        Success<OrdersPage>(:final OrdersPage value) => _Loaded<OrderSummary>(
          value.page.items,
          hasMore: value.page.hasMore || value.page.nextCursor != null,
        ),
        FailureResult<OrdersPage>(:final Failure failure) => _Failed<OrderSummary>(failure),
      };
    });
  }

  Future<void> _loadOperations() async {
    final int seq = ++_opsSeq;
    setState(() => _operations = const _Loading<Transaction>());
    final DateTime now = ref.read(clockProvider).nowUtc();
    final JournalPeriod period = JournalPeriod.tryCreate(
      now.subtract(const Duration(days: JournalPeriod.maxDays)),
      now,
    )!;
    Result<TransactionsPage> r;
    try {
      r = await ref
          .read(transactionsRepositoryProvider)
          .list(TransactionsQuery(period: period, customerId: widget.customerId, limit: customerOrdersTabPageSize));
    } on Object catch (e) {
      r = FailureResult<TransactionsPage>(UnknownFailure(cause: e));
    }
    if (!mounted || seq != _opsSeq) return;
    setState(() {
      _operations = switch (r) {
        Success<TransactionsPage>(:final TransactionsPage value) => _Loaded<Transaction>(
          value.page.items,
          hasMore: value.page.hasMore || value.page.nextCursor != null,
        ),
        FailureResult<TransactionsPage>(:final Failure failure) => _Failed<Transaction>(failure),
      };
    });
  }

  void _select(CustomerOrdersSegment s) {
    if (s == _segment) return;
    setState(() => _segment = s);
    if (s == CustomerOrdersSegment.operations && _operations == null) unawaited(_loadOperations());
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Column(
      key: CustomerOrdersTabKeys.root,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s2),
          child: AppTabs<CustomerOrdersSegment>(
            variant: AppTabsVariant.segmented,
            value: _segment,
            onChanged: _select,
            tabs: <AppTab<CustomerOrdersSegment>>[
              AppTab<CustomerOrdersSegment>(
                value: CustomerOrdersSegment.orders,
                label: l10n.customer_card_segment_orders,
              ),
              AppTab<CustomerOrdersSegment>(
                value: CustomerOrdersSegment.operations,
                label: l10n.customer_card_segment_operations,
              ),
            ],
          ),
        ),
        switch (_segment) {
          CustomerOrdersSegment.orders => _ordersBody(context, l10n),
          CustomerOrdersSegment.operations => _operationsBody(context, l10n),
        },
      ],
    );
  }

  Widget _skeleton(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      for (int i = 0; i < 4; i++)
        Padding(
          padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s1),
          child: const SkeletonBox(height: 56),
        ),
    ],
  );

  Widget _error(BuildContext context, AppLocalizations l10n, Failure f, VoidCallback retry) => Padding(
    padding: EdgeInsets.all(context.space.s4),
    child: ErrorState.inline(message: ErrorTexts.message(l10n, UiErrorMapper.fromFailure(f)), onRetry: retry),
  );

  Widget _showAll(BuildContext context, {required Key key, required String location}) => Padding(
    padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s2),
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      child: AppButton(
        key: key,
        label: AppLocalizations.of(context).order_history_show_all,
        variant: AppButtonVariant.text,
        size: AppButtonSize.s,
        onPressed: () => GoRouter.of(context).go(location),
      ),
    ),
  );

  Widget _ordersBody(BuildContext context, AppLocalizations l10n) {
    final _Load<OrderSummary> s = _orders;
    switch (s) {
      case _Loading<OrderSummary>():
        return _skeleton(context);
      case _Failed<OrderSummary>(:final Failure failure):
        return _error(context, l10n, failure, () => unawaited(_loadOrders()));
      case _Loaded<OrderSummary>(:final List<OrderSummary> items, :final bool hasMore):
        if (items.isEmpty) {
          return EmptyState(variant: EmptyStateVariant.orders, title: l10n.orders_empty_no_orders_title);
        }
        final bool dense = context.windowClass != WindowClass.compact;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final OrderSummary o in items)
              OrdersListRow(
                key: CustomerOrdersTabKeys.order(o.id),
                order: o,
                dense: dense,
                onTap: () => GoRouter.of(context).push(OrderRoute(orderId: o.id).location),
              ),
            if (hasMore)
              _showAll(
                context,
                key: CustomerOrdersTabKeys.showAllOrders,
                location: OrdersRoute(customerId: widget.customerId).location,
              ),
          ],
        );
    }
  }

  Widget _operationsBody(BuildContext context, AppLocalizations l10n) {
    final _Load<Transaction>? s = _operations;
    switch (s) {
      case null || _Loading<Transaction>():
        return _skeleton(context);
      case _Failed<Transaction>(:final Failure failure):
        return _error(context, l10n, failure, () => unawaited(_loadOperations()));
      case _Loaded<Transaction>(:final List<Transaction> items, :final bool hasMore):
        if (items.isEmpty) {
          return EmptyState(variant: EmptyStateVariant.transactions, title: l10n.transactions_empty);
        }
        final bool compact = context.windowClass == WindowClass.compact;
        final String locale = Localizations.localeOf(context).toLanguageTag();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final Transaction t in items)
              TransactionRow(
                key: CustomerOrdersTabKeys.operation(t.id),
                kind: t.kind,
                title: TransactionsTexts.title(l10n, t),
                subtitle: <String>[
                  DsBishkekTime.dateTime(t.occurredAt),
                  if (t.source != TransactionSource.onec) ?t.actor?.displayName else l10n.transactions_source_onec,
                ].join(' · '),
                amountText: TransactionsTexts.money(t.amount),
                tone: TransactionsTexts.tone(t),
                status: TransactionsTexts.statusChip(l10n, t),
                compactWindow: compact,
                semanticLabel: TransactionsTexts.semantic(l10n, t, locale),
                onTap: () => GoRouter.of(context).push(TransactionRoute(transactionId: t.id).location),
              ),
            if (hasMore)
              _showAll(
                context,
                key: CustomerOrdersTabKeys.showAllOperations,
                location: TransactionsRoute(customerId: widget.customerId).location,
              ),
          ],
        );
    }
  }
}
