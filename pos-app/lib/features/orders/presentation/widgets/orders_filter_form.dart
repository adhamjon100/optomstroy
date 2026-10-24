// Панель фильтров SCR-25 (02 UI-25-012; 03 §9.25 `FilterPanel`/`FilterSheet`): клиент (`CustomerPicker` →
// `customerId`; у `customer` фильтра нет), способ оплаты (`paymentMethod`), «Оплачен» (`isPaid`); «Сбросить».
// Применение — сразу при выборе (новый запрос с первой страницы, 02 SCR-25.4).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_list_tile.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/components/category_chip.dart';
import 'package:optomstroy/design_system/components/search_bar.dart' as ds;
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/repositories/customers_repository.dart';
import 'package:optomstroy/features/orders/presentation/orders_format.dart';
import 'package:optomstroy/features/orders/presentation/state/orders_filters.dart';

/// Форма фильтров (содержимое `FilterSheet` / `FilterPanel`).
class OrdersFilterForm extends ConsumerStatefulWidget {
  /// Создаёт форму.
  const OrdersFilterForm({super.key, required this.filters, required this.onChanged, required this.showCustomer});

  final OrdersFilters filters;
  final ValueChanged<OrdersFilters> onChanged;

  /// Фильтр «Клиент» (staff).
  final bool showCustomer;

  @override
  ConsumerState<OrdersFilterForm> createState() => _OrdersFilterFormState();
}

class _OrdersFilterFormState extends ConsumerState<OrdersFilterForm> {
  late OrdersFilters _f = widget.filters;
  final TextEditingController _q = TextEditingController();
  Timer? _debounce;
  List<Customer> _found = const <Customer>[];
  bool _searching = false;
  int _gen = 0;

  @override
  void didUpdateWidget(covariant OrdersFilterForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filters != widget.filters) _f = widget.filters;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _set(OrdersFilters f) {
    setState(() => _f = f);
    widget.onChanged(f);
  }

  void _onQuery(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => unawaited(_search(text.trim())));
  }

  Future<void> _search(String q) async {
    final int gen = ++_gen;
    if (q.isEmpty) {
      setState(() => _found = const <Customer>[]);
      return;
    }
    setState(() => _searching = true);
    Result<PageResult<Customer>> r;
    try {
      r = await ref.read(customersRepositoryProvider).search(CustomerSearchQuery(q: q, limit: 10));
    } on Object {
      r = const Success<PageResult<Customer>>(PageResult<Customer>(items: <Customer>[]));
    }
    if (!mounted || gen != _gen) return;
    setState(() {
      _searching = false;
      _found = r.valueOrNull?.items ?? const <Customer>[];
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    Widget label(String text) => Padding(
      padding: EdgeInsets.only(top: context.space.s4, bottom: context.space.s2),
      child: Text(
        text,
        style: context.text.label.copyWith(color: c.textSecondary, fontWeight: FontWeight.w600),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (widget.showCustomer) ...<Widget>[
          label(OrdersTexts.filterCustomer(l10n)),
          if (_f.customerId != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: CategoryChip(
                key: const ValueKey<String>('filter-customer-selected'),
                label: _f.customerName ?? _f.customerId!,
                variant: CategoryChipVariant.input,
                removeLabel: l10n.ds_button_reset,
                onRemove: () => _set(_f.copyWith(customerId: () => null, customerName: () => null)),
              ),
            )
          else ...<Widget>[
            ds.SearchBar(
              key: const ValueKey<String>('filter-customer-search'),
              variant: ds.SearchBarVariant.customers,
              controller: _q,
              placeholder: l10n.ds_search_placeholder_customers,
              loading: _searching,
              onChanged: _onQuery,
            ),
            for (final Customer cu in _found)
              AppListTile(
                key: ValueKey<String>('filter-customer-${cu.id}'),
                title: cu.displayName ?? cu.name,
                subtitle: cu.phoneMasked,
                onTap: () {
                  _q.clear();
                  _found = const <Customer>[];
                  _set(_f.copyWith(customerId: () => cu.id, customerName: () => cu.displayName ?? cu.name));
                },
              ),
          ],
        ],
        label(OrdersTexts.filterPaymentMethod(l10n)),
        AppRadio<PaymentMethod?>(
          key: const ValueKey<String>('filter-method-any'),
          value: null,
          groupValue: _f.paymentMethod,
          label: l10n.orders_chip_all,
          onChanged: (_) => _set(_f.copyWith(paymentMethod: () => null)),
        ),
        for (final PaymentMethod m in PaymentMethod.values)
          AppRadio<PaymentMethod?>(
            key: ValueKey<String>('filter-method-${m.value}'),
            value: m,
            groupValue: _f.paymentMethod,
            label: OrdersTexts.paymentMethod(l10n, m),
            onChanged: (_) => _set(_f.copyWith(paymentMethod: () => m)),
          ),
        label(OrdersTexts.colPaid(l10n)),
        Wrap(
          spacing: context.space.s2,
          children: <Widget>[
            CategoryChip(
              key: const ValueKey<String>('filter-paid-any'),
              label: l10n.orders_chip_all,
              selected: _f.paid == OrdersPaidFilter.any,
              onTap: () => _set(_f.copyWith(paid: OrdersPaidFilter.any)),
            ),
            CategoryChip(
              key: const ValueKey<String>('filter-paid-yes'),
              label: l10n.orders_paid_full,
              selected: _f.paid == OrdersPaidFilter.paid,
              onTap: () => _set(_f.copyWith(paid: OrdersPaidFilter.paid)),
            ),
            // UI-25-012 «Не оплачен» (`isPaid=false`; ключ `orders_paid_unpaid`, 03 §16.8; SCR-25 «Уточнения» п. 3).
            CategoryChip(
              key: const ValueKey<String>('filter-paid-no'),
              label: l10n.orders_paid_unpaid,
              selected: _f.paid == OrdersPaidFilter.unpaid,
              onTap: () => _set(_f.copyWith(paid: OrdersPaidFilter.unpaid)),
            ),
          ],
        ),
        SizedBox(height: context.space.s6),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: AppButton(
            key: const ValueKey<String>('filter-reset'),
            label: l10n.orders_reset_filters,
            variant: AppButtonVariant.text,
            onPressed: _f.panelCount == 0
                ? null
                : () => _set(
                    _f.copyWith(
                      customerId: () => null,
                      customerName: () => null,
                      paymentMethod: () => null,
                      paid: OrdersPaidFilter.any,
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}
