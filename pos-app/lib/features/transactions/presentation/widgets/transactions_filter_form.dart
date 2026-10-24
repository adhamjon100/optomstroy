// Секции фильтров SCR-36 (02 UI-36-006…UI-36-009, UI-36-012, UI-36-015, UI-36-016): клиент (поиск как SCR-31,
// debounce 300 мс, один клиент), статус (группы, multi), тип операции (multi, иконки `TransactionRow`), способ оплаты,
// сотрудник (`admin`/`owner`; список — порт [transactionsActorsProvider]), поиск по номеру (в листе compact).
// Изменения сообщаются через [onChanged]: на expanded экран применяет сразу (debounce), на compact — копит до
// «Показать».
import 'dart:async';

import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/models/transaction.dart';
import 'package:optomstroy/design_system/components/app_dropdown.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/category_chip.dart';
import 'package:optomstroy/design_system/components/customer_card.dart';
import 'package:optomstroy/design_system/components/filter_panel.dart';
import 'package:optomstroy/design_system/components/search_bar.dart';
import 'package:optomstroy/design_system/components/transaction_row.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/repositories/customers_repository.dart';
import 'package:optomstroy/features/transactions/presentation/providers/transactions_ports.dart';
import 'package:optomstroy/features/transactions/presentation/state/transactions_filters.dart';
import 'package:optomstroy/features/transactions/presentation/transactions_format.dart';

/// Виды операции в фильтре (+ `return_requested` — если сервер их присылает, could).
const List<TransactionKind> kFilterKinds = <TransactionKind>[
  TransactionKind.orderCreated,
  TransactionKind.orderCancelled,
  TransactionKind.paymentReceived,
  TransactionKind.paymentVoided,
  TransactionKind.refund,
  TransactionKind.discountOverride,
  TransactionKind.creditSaleApproved,
  TransactionKind.manualQrConfirm,
  TransactionKind.returnRequested,
];

/// Секции фильтров.
class TransactionsFilterSections extends ConsumerStatefulWidget {
  /// Создаёт секции.
  const TransactionsFilterSections({
    super.key,
    required this.filters,
    required this.onChanged,
    required this.showActor,
    this.showNumberSearch = false,
  });

  final TransactionsFilters filters;
  final ValueChanged<TransactionsFilters> onChanged;

  /// Фильтр «Сотрудник» (`transactions.read.all`: admin, owner).
  final bool showActor;

  /// Поле «Номер документа» (compact — в листе).
  final bool showNumberSearch;

  /// Секции как список виджетов (для `FilterPanel`/`FilterSheet`).
  @override
  ConsumerState<TransactionsFilterSections> createState() => _TransactionsFilterSectionsState();
}

class _TransactionsFilterSectionsState extends ConsumerState<TransactionsFilterSections> {
  final TextEditingController _customerQ = TextEditingController();
  late final TextEditingController _number = TextEditingController(text: widget.filters.q);
  Timer? _debounce;
  List<Customer>? _found;
  bool _searching = false;
  int _seq = 0;
  List<UserRef>? _actors;

  @override
  void initState() {
    super.initState();
    if (widget.showActor) unawaited(_loadActors());
  }

  Future<void> _loadActors() async {
    final TransactionsActorsSource? source = ref.read(transactionsActorsProvider);
    if (source == null) return;
    final Result<List<UserRef>> r = await source();
    if (mounted) setState(() => _actors = r.valueOrNull);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _customerQ.dispose();
    _number.dispose();
    super.dispose();
  }

  void _onCustomerQuery(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => unawaited(_searchCustomers(text.trim())));
  }

  Future<void> _searchCustomers(String q) async {
    final int seq = ++_seq;
    if (q.length < 2) {
      setState(() => _found = null);
      return;
    }
    setState(() => _searching = true);
    final Result<PageResult<Customer>> r = await ref
        .read(customersRepositoryProvider)
        .search(CustomerSearchQuery(q: q));
    if (!mounted || seq != _seq) return;
    setState(() {
      _searching = false;
      _found = r.valueOrNull?.items ?? const <Customer>[];
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final TransactionsFilters f = widget.filters;
    final List<Widget> sections = <Widget>[
      if (widget.showNumberSearch)
        FilterSection(
          title: l10n.transactions_search_number,
          child: AppTextField(
            key: const ValueKey<String>('tx-filter-number'),
            controller: _number,
            withClear: true,
            maxLength: 200,
            onChanged: (String v) => widget.onChanged(f.copyWith(q: v.trim())),
          ),
        ),
      FilterSection(
        title: l10n.transactions_filter_customer,
        child: f.customerId != null
            ? Align(
                alignment: AlignmentDirectional.centerStart,
                child: CategoryChip(
                  key: const ValueKey<String>('tx-filter-customer-selected'),
                  label: f.customerName ?? l10n.transactions_filter_customer,
                  variant: CategoryChipVariant.input,
                  selected: true,
                  removeLabel: l10n.ds_button_reset,
                  onRemove: () => widget.onChanged(f.copyWith(customerId: () => null, customerName: () => null)),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SearchBar(
                    key: const ValueKey<String>('tx-filter-customer'),
                    variant: SearchBarVariant.customers,
                    controller: _customerQ,
                    loading: _searching,
                    onChanged: _onCustomerQuery,
                    onSubmitted: (String v) => unawaited(_searchCustomers(v.trim())),
                  ),
                  for (final Customer c in (_found ?? const <Customer>[]).take(8))
                    CustomerCard.row(
                      key: ValueKey<String>('tx-filter-customer-${c.id}'),
                      name: c.displayName ?? c.name,
                      phone: c.phoneMasked,
                      rowHeight: 56,
                      onTap: () {
                        setState(() {
                          _found = null;
                          _customerQ.clear();
                        });
                        widget.onChanged(
                          f.copyWith(customerId: () => c.id, customerName: () => c.displayName ?? c.name),
                        );
                      },
                    ),
                ],
              ),
      ),
      FilterSection(
        title: l10n.transactions_filter_status,
        child: Wrap(
          spacing: context.space.s2,
          runSpacing: context.space.s2,
          children: <Widget>[
            for (final TransactionStatusGroup g in TransactionStatusGroup.values)
              _Chip(
                CategoryChip(
                  key: ValueKey<String>('tx-filter-status-${g.value}'),
                  label: TransactionsTexts.status(l10n, g),
                  variant: CategoryChipVariant.filter,
                  selected: f.statuses.contains(g),
                  onTap: () {
                    final Set<TransactionStatusGroup> next = <TransactionStatusGroup>{...f.statuses};
                    if (!next.remove(g)) next.add(g);
                    widget.onChanged(f.copyWith(statuses: next));
                  },
                ),
              ),
          ],
        ),
      ),
      FilterSection(
        title: l10n.transactions_filter_kind,
        child: Wrap(
          spacing: context.space.s2,
          runSpacing: context.space.s2,
          children: <Widget>[
            for (final TransactionKind k in kFilterKinds)
              _Chip(
                CategoryChip(
                  key: ValueKey<String>('tx-filter-kind-${k.value}'),
                  label: TransactionsTexts.kind(l10n, k),
                  icon: TransactionRow.iconOf(k),
                  variant: CategoryChipVariant.filter,
                  selected: f.kinds.contains(k),
                  onTap: () {
                    final Set<TransactionKind> next = <TransactionKind>{...f.kinds};
                    if (!next.remove(k)) next.add(k);
                    widget.onChanged(f.copyWith(kinds: next));
                  },
                ),
              ),
          ],
        ),
      ),
      FilterSection(
        title: l10n.transactions_filter_method,
        child: Wrap(
          spacing: context.space.s2,
          runSpacing: context.space.s2,
          children: <Widget>[
            for (final PaymentMethod m in PaymentMethod.values)
              _Chip(
                CategoryChip(
                  key: ValueKey<String>('tx-filter-method-${m.value}'),
                  label: TransactionsTexts.method(l10n, m),
                  variant: CategoryChipVariant.filter,
                  selected: f.paymentMethod == m,
                  onTap: () => widget.onChanged(f.copyWith(paymentMethod: () => f.paymentMethod == m ? null : m)),
                ),
              ),
          ],
        ),
      ),
      if (widget.showActor)
        FilterSection(
          title: l10n.transactions_filter_actor,
          child: _actors != null
              ? AppDropdown<String?>(
                  key: const ValueKey<String>('tx-filter-actor'),
                  items: <AppDropdownItem<String?>>[
                    AppDropdownItem<String?>(value: null, label: l10n.customers_search_filter_all),
                    for (final UserRef u in _actors!) AppDropdownItem<String?>(value: u.id, label: u.displayName),
                  ],
                  value: f.actorId,
                  onChanged: (String? v) => widget.onChanged(f.copyWith(actorId: () => v)),
                )
              : (f.actorId == null
                    ? const SizedBox.shrink()
                    : Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: CategoryChip(
                          key: const ValueKey<String>('tx-filter-actor-selected'),
                          label: l10n.transactions_filter_actor,
                          variant: CategoryChipVariant.input,
                          selected: true,
                          removeLabel: l10n.ds_button_reset,
                          onRemove: () => widget.onChanged(f.copyWith(actorId: () => null)),
                        ),
                      )),
        ),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: sections);
  }
}

/// `CategoryChip` в `Wrap` растягивается на всю ширину — сужаем до содержимого.
class _Chip extends StatelessWidget {
  const _Chip(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) => IntrinsicWidth(child: child);
}
