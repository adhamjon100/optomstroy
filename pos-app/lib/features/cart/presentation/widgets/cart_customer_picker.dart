// UI-20-004 «Клиент» SCR-20 (02 SCR-20.3, AC-UI-20-024; 10 CART-020): тап по строке клиента → поиск клиента
// (`CustomerPicker`: popover 360 на medium/expanded, `AppBottomSheet` 92 % на compact) → выбор → `POST /cart/customer`
// (цены по условиям клиента пересчитывает сервер); «Розничный покупатель» → `DELETE /cart/customer`; «+ Новый
// клиент» → SCR-26. Порог поиска по роли — ядро §19.4 (как SCR-21): `seller` — только полный номер или код клиента.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/customer_picker.dart';
import 'package:optomstroy/design_system/formats/ds_phone_format.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/cart/presentation/cart_formats.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/repositories/customers_repository.dart';

/// Выбор в поиске клиента корзины.
sealed class CartCustomerChoice {
  const CartCustomerChoice();
}

/// Клиент 1С (`POST /cart/customer`).
final class CartCustomerSelected extends CartCustomerChoice {
  const CartCustomerSelected(this.customerId);

  final String customerId;
}

/// «Розничный покупатель» (`DELETE /cart/customer`).
final class CartCustomerRetail extends CartCustomerChoice {
  const CartCustomerRetail();
}

/// «+ Новый клиент» (SCR-26).
final class CartCustomerCreateNew extends CartCustomerChoice {
  const CartCustomerCreateNew();
}

/// Ширина popover поиска клиента на medium/expanded (02 SCR-20.3 UI-20-004).
const double cartCustomerPopoverWidth = 360; // money-double: allow — геометрия UI (lp)

/// Ключи (тесты).
abstract final class CartCustomerPickerKeys {
  static const Key sheet = ValueKey<String>('cart-customer-picker');
}

/// Открыть поиск клиента; `null` — закрыт без выбора.
Future<CartCustomerChoice?> showCartCustomerPicker(
  BuildContext context, {
  required RoleCode? role,
  required bool online,
  required bool retailSelected,
}) {
  final AppLocalizations l10n = AppLocalizations.of(context);
  final Widget body = CartCustomerSearch(role: role, online: online, retailSelected: retailSelected);
  if (context.windowClass == WindowClass.compact) {
    return AppBottomSheet.show<CartCustomerChoice>(
      context,
      title: l10n.checkout_customer_search_hint,
      body: body,
      variant: AppBottomSheetVariant.fullHeight,
    );
  }
  return showDialog<CartCustomerChoice>(
    context: context,
    barrierColor: Colors.transparent,
    builder: (BuildContext ctx) => Dialog(
      alignment: AlignmentDirectional.topEnd,
      insetPadding: EdgeInsets.all(ctx.space.s4),
      backgroundColor: ctx.colors.surface,
      surfaceTintColor: ctx.colors.surface,
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(ctx.radii.lg)),
      child: SizedBox(
        width: cartCustomerPopoverWidth,
        child: Padding(padding: EdgeInsets.all(ctx.space.s4), child: body),
      ),
    ),
  );
}

/// Поиск клиента корзины (debounce 300 мс, ответы не по последнему запросу отбрасываются).
class CartCustomerSearch extends ConsumerStatefulWidget {
  const CartCustomerSearch({required this.role, required this.online, required this.retailSelected, super.key});

  final RoleCode? role;
  final bool online;
  final bool retailSelected;

  /// Debounce ввода.
  static const Duration debounce = Duration(milliseconds: 300);

  /// Порог поиска по роли (ядро §19.4).
  static bool searchable(String q, RoleCode? role) {
    final String t = q.trim();
    final int digits = t.replaceAll(RegExp(r'\D'), '').length;
    final bool letters = RegExp(r'[A-Za-zА-Яа-яЁёӨөҮүҢң]').hasMatch(t);
    if (role == RoleCode.seller) return !letters && (digits >= 9 || (t.contains('-') && digits >= 2));
    if (letters) return t.replaceAll(RegExp(r'\s'), '').length >= 2;
    return digits >= 4;
  }

  static String _normalize(String q) {
    final String t = q.trim();
    final String digits = t.replaceAll(RegExp(r'\D'), '');
    final bool phoneLike = RegExp(r'^[+\d\s()-]+$').hasMatch(t) && !t.contains('-');
    if (phoneLike && digits.length == 9) return '+996$digits';
    if (phoneLike && digits.length == 12 && digits.startsWith('996')) return '+$digits';
    return t;
  }

  @override
  ConsumerState<CartCustomerSearch> createState() => _CartCustomerSearchState();
}

class _CartCustomerSearchState extends ConsumerState<CartCustomerSearch> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _focus = FocusNode(debugLabel: 'cart-customer-search');
  Timer? _debounce;
  int _seq = 0;
  CustomerPickerStatus _status = CustomerPickerStatus.idle;
  List<Customer> _results = const <Customer>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _changed(String q) {
    _debounce?.cancel();
    if (!CartCustomerSearch.searchable(q, widget.role)) {
      _seq++;
      setState(() {
        _status = CustomerPickerStatus.idle;
        _results = const <Customer>[];
      });
      return;
    }
    _debounce = Timer(CartCustomerSearch.debounce, () => unawaited(_search(q)));
  }

  Future<void> _search(String q) async {
    final int seq = ++_seq;
    setState(() => _status = CustomerPickerStatus.loading);
    final Result<PageResult<Customer>> r = await ref
        .read(customersRepositoryProvider)
        .search(CustomerSearchQuery(q: CartCustomerSearch._normalize(q)));
    if (!mounted || seq != _seq) return;
    setState(() {
      switch (r) {
        case Success<PageResult<Customer>>(:final PageResult<Customer> value):
          _results = value.items;
          _status = value.items.isEmpty ? CustomerPickerStatus.empty : CustomerPickerStatus.results;
        case FailureResult<PageResult<Customer>>():
          _results = const <Customer>[];
          _status = CustomerPickerStatus.error;
      }
    });
  }

  void _pick(CartCustomerChoice choice) => Navigator.of(context).pop(choice);

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return KeyedSubtree(
      key: CartCustomerPickerKeys.sheet,
      child: CustomerPicker(
        placeholder: l10n.checkout_customer_search_hint,
        controller: _query,
        focusNode: _focus,
        hint: widget.role == RoleCode.seller ? l10n.customers_search_seller_hint : null,
        status: widget.online ? _status : CustomerPickerStatus.offline,
        entries: <CustomerPickerEntry>[for (final Customer c in _results) _entry(l10n, c)],
        onChanged: _changed,
        onSubmitted: (_) {
          if (_results.isNotEmpty) _pick(CartCustomerSelected(_results.first.id));
        },
        onSelect: (String id) => _pick(CartCustomerSelected(id)),
        retailLabel: l10n.checkout_customer_retail_chip,
        retailSelected: widget.retailSelected,
        onRetail: () => _pick(const CartCustomerRetail()),
        newCustomerLabel: l10n.checkout_customer_new,
        onNewCustomer: widget.online ? () => _pick(const CartCustomerCreateNew()) : null,
        emptyText: l10n.checkout_customer_not_found(_query.text.trim()),
        errorText: l10n.customers_search_error,
        offlineText: l10n.customers_search_offline,
        onRetry: () => unawaited(_search(_query.text)),
      ),
    );
  }

  static CustomerPickerEntry _entry(AppLocalizations l10n, Customer c) => CustomerPickerEntry(
    id: c.id,
    title: c.title,
    // Телефон — `+996 XXX XXX XXX` (ядро §17.2); у `seller` — маска сервера как есть.
    phone: c.phones.isNotEmpty ? DsPhoneFormat.display(c.phones.first.valueE164) : c.phoneMasked,
    debtLabel: c.isOverdue == true
        ? l10n.ds_receivable_overdue
        : (c.hasDebt == true ? l10n.ds_receivable_has_debt : null),
    overdue: c.isOverdue == true,
    // Бейдж «Скидка: 5 %» строки результата (03 §9.35).
    discountLabel: c.discountPercent == null || c.discountPercent!.hundredths == 0
        ? null
        : l10n.customer_card_metric_discount('${CartFormats.percent(c.discountPercent!)} %'),
    pendingLabel: c.onecStatus == CustomerOnecStatus.pending ? l10n.checkout_customer_pending_onec : null,
  );
}
