// Зоны SCR-21 (02 SCR-21.3): B «Клиент», C «Получение товара», D «Оплата», E «Состав заказа» и итоги,
// F «Печать после создания заказа». Секции — без собственного состояния: значения — из `CheckoutState`,
// изменения — в `CheckoutController`, тексты — ARB.
import 'dart:async';

import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/services.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_checkbox.dart';
import 'package:optomstroy/design_system/components/app_dropdown.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/components/app_section_header.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/customer_card.dart';
import 'package:optomstroy/design_system/components/customer_picker.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/option_tile.dart';
import 'package:optomstroy/design_system/components/payment_method_card.dart';
import 'package:optomstroy/design_system/components/phone_field.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout.dart';
import 'package:optomstroy/features/checkout/presentation/checkout_formats.dart';
import 'package:optomstroy/features/checkout/presentation/controllers/checkout_controller.dart';
import 'package:optomstroy/features/checkout/presentation/providers/checkout_ports.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';

/// Поля ввода формы (живут в состоянии экрана: ПДн — только память).
final class CheckoutFormControllers {
  final TextEditingController search = TextEditingController();
  final TextEditingController receiverName = TextEditingController();
  final TextEditingController receiverPhone = TextEditingController();
  final TextEditingController address = TextEditingController();
  final TextEditingController courierPhone = TextEditingController();
  final TextEditingController comment = TextEditingController();
  final FocusNode searchFocus = FocusNode(debugLabel: 'checkout-search');
  final FocusNode receiverNameFocus = FocusNode(debugLabel: 'checkout-receiver-name');
  final FocusNode courierPhoneFocus = FocusNode(debugLabel: 'checkout-courier-phone');

  void dispose() {
    search.dispose();
    receiverName.dispose();
    receiverPhone.dispose();
    address.dispose();
    courierPhone.dispose();
    comment.dispose();
    searchFocus.dispose();
    receiverNameFocus.dispose();
    courierPhoneFocus.dispose();
  }
}

/// Всё, что нужно секциям.
final class CheckoutView {
  const CheckoutView({
    required this.state,
    required this.ctl,
    required this.form,
    required this.online,
    required this.qr,
    required this.slots,
    required this.onNewCustomer,
    required this.onCreditHelp,
    required this.onCreditApprove,
    required this.onBackToCart,
    required this.onPickDate,
    this.viewerName,
  });

  final CheckoutState state;
  final CheckoutController ctl;
  final CheckoutFormControllers form;
  final bool online;
  final CheckoutQrMode qr;
  final List<CheckoutSlot> slots;
  final VoidCallback onNewCustomer;
  final VoidCallback onCreditHelp;
  final VoidCallback onCreditApprove;
  final VoidCallback onBackToCart;
  final VoidCallback onPickDate;

  /// ФИО пользователя сессии — «Разрешено: {name}» после разрешения долга старшим (UI-21-028).
  final String? viewerName;

  RoleCode? get role => state.role;

  /// Видны ли суммы долга (`customer.receivables.read.summary`: `cashier`, `senior_seller`, `admin`).
  bool get seesDebtSums => role == RoleCode.cashier || role == RoleCode.seniorSeller || role == RoleCode.admin;

  /// Текст ошибки поля (локальная валидация после попытки или `400 VALIDATION_FAILED`).
  String? error(AppLocalizations l10n, CheckoutField field) {
    if (!state.showErrors) return null;
    final CheckoutFieldError? e = ctl.errorsFor()[field];
    if (e != null) return fieldErrorText(l10n, e);
    if (state.serverFieldErrors.contains(field)) {
      return switch (field) {
        CheckoutField.address => l10n.checkout_address_required,
        CheckoutField.slot => l10n.checkout_slot_required,
        CheckoutField.receiverName => l10n.checkout_receiver_name_required,
        _ => l10n.checkout_phone_invalid,
      };
    }
    return null;
  }

  /// Текст ошибки по коду.
  static String fieldErrorText(AppLocalizations l10n, CheckoutFieldError e) => switch (e) {
    CheckoutFieldError.receiverNameRequired => l10n.checkout_receiver_name_required,
    CheckoutFieldError.phoneInvalid => l10n.checkout_phone_invalid,
    CheckoutFieldError.deliveryMethodRequired => l10n.checkout_delivery_method_required,
    CheckoutFieldError.addressRequired => l10n.checkout_address_required,
    CheckoutFieldError.addressTooLong => l10n.checkout_address_too_long,
    CheckoutFieldError.slotRequired => l10n.checkout_slot_required,
    CheckoutFieldError.slotPast => l10n.checkout_slot_past,
    CheckoutFieldError.paymentRequired => l10n.checkout_payment_required,
  };
}

/// Заголовок секции (`title 18/600`).
class CheckoutSectionTitle extends StatelessWidget {
  const CheckoutSectionTitle(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: context.space.s3),
    child: Row(
      children: <Widget>[
        Expanded(
          child: Semantics(
            header: true,
            child: Text(title, style: context.text.title.copyWith(color: context.colors.textPrimary)),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

// =====================================================================================================================
// Зона B — «Клиент»
// =====================================================================================================================

/// Зона B (UI-21-003…UI-21-006, UI-21-023…UI-21-025).
class CheckoutCustomerSection extends StatelessWidget {
  const CheckoutCustomerSection({super.key, required this.view});

  final CheckoutView view;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CheckoutState s = view.state;
    final Customer? customer = s.customer != null && !s.customer!.isRetailDefault ? s.customer : null;
    return Column(
      key: const ValueKey<String>('checkout-section-customer'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        CheckoutSectionTitle(l10n.checkout_section_customer),
        if (customer != null || s.customerUpdating)
          CustomerCard.compact(
            key: const ValueKey<String>('checkout-customer-card'),
            loading: s.customerUpdating,
            name: customer?.title ?? '',
            phone: _phone(customer),
            meta: customer == null ? null : _meta(l10n, customer),
            pendingLabel: customer?.onecStatus == CustomerOnecStatus.pending
                ? l10n.checkout_customer_pending_onec
                : null,
            tooltip: customer?.onecCode,
            onRemove: () => unawaited(view.ctl.clearCustomer()),
            removeLabel: l10n.ds_button_close,
          )
        else
          CustomerPicker(
            placeholder: l10n.checkout_customer_search_hint,
            controller: view.form.search,
            focusNode: view.form.searchFocus,
            hint: view.role == RoleCode.seller ? l10n.customers_search_seller_hint : null,
            status: _pickerStatus(s),
            entries: <CustomerPickerEntry>[for (final Customer c in s.searchResults) _entry(l10n, c)],
            onChanged: view.ctl.searchChanged,
            onSubmitted: (_) {
              if (s.searchResults.isNotEmpty) unawaited(view.ctl.selectCustomer(s.searchResults.first.id));
            },
            onSelect: (String id) {
              view.form.search.clear();
              unawaited(view.ctl.selectCustomer(id));
            },
            retailLabel: l10n.checkout_customer_retail_chip,
            retailSelected: s.retailSelected,
            onRetail: () => unawaited(view.ctl.clearCustomer()),
            newCustomerLabel: l10n.checkout_customer_new,
            onNewCustomer: view.online ? view.onNewCustomer : null,
            emptyText: l10n.checkout_customer_not_found(s.searchQuery.trim()),
            errorText: l10n.customers_search_error,
            offlineText: l10n.customers_search_offline,
            onRetry: () => unawaited(view.ctl.retrySearch()),
          ),
        if (s.customerFailure != null)
          Padding(
            padding: EdgeInsets.only(top: context.space.s2),
            child: ErrorState.inline(message: l10n.error_internal, onRetry: null),
          ),
        const SizedBox(height: 16),
        Text(
          l10n.checkout_receiver_title,
          style: context.text.label.copyWith(fontWeight: FontWeight.w600, color: context.colors.textPrimary),
        ),
        const SizedBox(height: 4),
        AppRadio<ReceiverKind>(
          key: const ValueKey<String>('checkout-receiver-customer'),
          value: ReceiverKind.customer,
          groupValue: s.receiverKind,
          onChanged: view.ctl.setReceiverKind,
          label: l10n.checkout_receiver_customer,
          description: l10n.checkout_receiver_customer_hint,
        ),
        AppRadio<ReceiverKind>(
          key: const ValueKey<String>('checkout-receiver-other'),
          value: ReceiverKind.otherPerson,
          groupValue: s.receiverKind,
          onChanged: (ReceiverKind k) {
            view.ctl.setReceiverKind(k);
            view.form.receiverNameFocus.requestFocus();
          },
          label: l10n.checkout_receiver_other,
          description: l10n.checkout_receiver_other_hint,
        ),
        RevealSize(
          child: s.receiverKind == ReceiverKind.otherPerson
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const SizedBox(height: 8),
                    AppTextField(
                      key: const ValueKey<String>('checkout-receiver-name'),
                      controller: view.form.receiverName,
                      focusNode: view.form.receiverNameFocus,
                      label: l10n.checkout_receiver_name_label,
                      errorText: view.error(l10n, CheckoutField.receiverName),
                      maxLength: 150,
                      onChanged: view.ctl.setReceiverName,
                    ),
                    const SizedBox(height: 8),
                    PhoneField(
                      key: const ValueKey<String>('checkout-receiver-phone'),
                      controller: view.form.receiverPhone,
                      label: l10n.checkout_receiver_phone_label,
                      semanticLabel: l10n.checkout_receiver_phone_label,
                      errorText: view.error(l10n, CheckoutField.receiverPhone),
                      onChanged: (String? e164) {
                        view.ctl.setReceiverPhone(view.form.receiverPhone.text, e164);
                        if (!view.state.courierPhoneManual) {
                          view.form.courierPhone.text = view.form.receiverPhone.text;
                        }
                      },
                    ),
                  ],
                )
              : const SizedBox(width: double.infinity), // money-double: allow — геометрия UI (ширина окна), не деньги
        ),
        if (s.piiNotRestored)
          Padding(
            padding: EdgeInsets.only(top: context.space.s2),
            child: Text(
              l10n.checkout_pii_not_saved_hint,
              style: context.text.caption.copyWith(color: context.colors.textSecondary),
            ),
          ),
      ],
    );
  }

  static CustomerPickerStatus _pickerStatus(CheckoutState s) => switch (s.searchStatus) {
    CheckoutSearchStatus.idle => CustomerPickerStatus.idle,
    CheckoutSearchStatus.loading => CustomerPickerStatus.loading,
    CheckoutSearchStatus.results => CustomerPickerStatus.results,
    CheckoutSearchStatus.empty => CustomerPickerStatus.empty,
    CheckoutSearchStatus.error => CustomerPickerStatus.error,
  };

  CustomerPickerEntry _entry(AppLocalizations l10n, Customer c) => CustomerPickerEntry(
    id: c.id,
    title: c.title,
    phone: _phone(c),
    debtLabel: c.isOverdue == true
        ? l10n.ds_receivable_overdue
        : (c.hasDebt == true ? l10n.ds_receivable_has_debt : null),
    overdue: c.isOverdue == true,
    // Бейдж «Скидка: 5 %» строки результата (03 §9.35).
    discountLabel: c.discountPercent == null || c.discountPercent!.hundredths == 0
        ? null
        : l10n.customer_card_metric_discount('${CheckoutFormats.percent(c.discountPercent!)} %'),
    pendingLabel: c.onecStatus == CustomerOnecStatus.pending ? l10n.checkout_customer_pending_onec : null,
  );

  static String? _phone(Customer? c) {
    if (c == null) return null;
    if (c.phones.isNotEmpty) return CheckoutFormats.phone(c.phones.first.valueE164);
    return c.phoneMasked;
  }

  String _meta(AppLocalizations l10n, Customer c) {
    final String orders = c.ordersCount == null ? '—' : l10n.customer_orders_count(c.ordersCount!);
    final String debt;
    final Money? balance = c.receivable?.balance;
    if (view.seesDebtSums && balance != null) {
      debt = CheckoutFormats.money(balance);
    } else if (c.isOverdue == true) {
      debt = l10n.checkout_customer_debt_flag_overdue;
    } else if (c.hasDebt == true) {
      debt = l10n.checkout_customer_debt_flag_yes;
    } else {
      debt = l10n.checkout_customer_debt_flag_no;
    }
    final String discount = '${CheckoutFormats.percent(c.discountPercent ?? Percent.zero)} %';
    return l10n.checkout_customer_meta(debt, discount, orders);
  }
}

// =====================================================================================================================
// Зона C — «Получение товара»
// =====================================================================================================================

/// Зона C (UI-21-007…UI-21-011). «Выбрать на карте» в R1 нет в дереве виджетов (RM-F-006 п. 4, Q-178).
class CheckoutDeliverySection extends StatelessWidget {
  const CheckoutDeliverySection({super.key, required this.view, this.tilesInRow = true});

  final CheckoutView view;

  /// Плитки в ряд (compact — столбиком).
  final bool tilesInRow;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CheckoutState s = view.state;
    final String? methodError = view.error(l10n, CheckoutField.deliveryMethod);
    final Widget pickup = OptionTile(
      key: const ValueKey<String>('checkout-delivery-pickup'),
      title: l10n.checkout_pickup_title,
      subtitle: l10n.checkout_pickup_hint,
      icon: Icons.storefront_outlined,
      selected: s.deliveryMethod == DeliveryMethod.pickup,
      errorText: methodError,
      onTap: () => view.ctl.setDeliveryMethod(DeliveryMethod.pickup),
    );
    final Widget delivery = OptionTile(
      key: const ValueKey<String>('checkout-delivery-delivery'),
      title: l10n.checkout_delivery_title,
      subtitle: l10n.checkout_delivery_hint,
      icon: Icons.local_shipping_outlined,
      selected: s.deliveryMethod == DeliveryMethod.delivery,
      errorText: methodError == null ? null : '',
      onTap: () => view.ctl.setDeliveryMethod(DeliveryMethod.delivery),
    );
    return Column(
      key: const ValueKey<String>('checkout-section-delivery'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        CheckoutSectionTitle(l10n.checkout_section_delivery),
        if (tilesInRow)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: pickup),
              const SizedBox(width: 12),
              Expanded(child: delivery),
            ],
          )
        else ...<Widget>[pickup, const SizedBox(height: 12), delivery],
        RevealSize(
          child: s.deliveryMethod == DeliveryMethod.delivery
              ? _deliveryFields(context, l10n)
              : const SizedBox(width: double.infinity), // money-double: allow — геометрия UI (ширина окна), не деньги
        ),
      ],
    );
  }

  Widget _deliveryFields(BuildContext context, AppLocalizations l10n) {
    final CheckoutState s = view.state;
    final DsColors c = context.colors;
    final int count = s.comment.characters.length;
    final DateTime today = view.ctl.today();
    final DateTime tomorrow = today.add(const Duration(days: 1));
    final DateTime? date = s.desiredDate;
    final String dateLabel = date == null
        ? ''
        : date == today
        ? l10n.checkout_date_today
        : date == tomorrow
        ? l10n.checkout_date_tomorrow
        : CheckoutFormats.date(date);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 16),
        AppTextField(
          key: const ValueKey<String>('checkout-address'),
          controller: view.form.address,
          label: l10n.checkout_address_label,
          hint: l10n.checkout_address_hint,
          variant: AppTextFieldVariant.multiline,
          errorText: view.error(l10n, CheckoutField.address),
          maxLength: Delivery.addressMaxLength,
          inputFormatters: <TextInputFormatter>[LengthLimitingTextInputFormatter(Delivery.addressMaxLength)],
          onChanged: view.ctl.setAddress,
        ),
        const SizedBox(height: 12),
        PhoneField(
          key: const ValueKey<String>('checkout-courier-phone'),
          controller: view.form.courierPhone,
          focusNode: view.form.courierPhoneFocus,
          label: l10n.checkout_recipient_phone_label,
          semanticLabel: l10n.checkout_recipient_phone_label,
          helper: s.receiverKind == ReceiverKind.otherPerson ? l10n.checkout_courier_phone_hint : null,
          errorText: view.error(l10n, CheckoutField.courierPhone),
          onChanged: (String? e164) => view.ctl.setCourierPhone(view.form.courierPhone.text, e164),
        ),
        const SizedBox(height: 12),
        AppTextField(
          key: const ValueKey<String>('checkout-comment'),
          controller: view.form.comment,
          label: l10n.checkout_comment_label,
          hint: l10n.checkout_comment_hint,
          variant: AppTextFieldVariant.multiline,
          inputFormatters: <TextInputFormatter>[LengthLimitingTextInputFormatter(Delivery.commentMaxLength)],
          onChanged: view.ctl.setComment,
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            l10n.checkout_comment_counter(count),
            key: const ValueKey<String>('checkout-comment-counter'),
            style: context.text.caption.copyWith(
              color: count >= Delivery.commentMaxLength ? c.warning : c.textSecondary,
              fontFeatures: DsTypography.numeric,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(l10n.checkout_time_label, style: context.text.label.copyWith(color: c.textPrimary)),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: AppDropdown<int>(
                key: const ValueKey<String>('checkout-date'),
                value: date == null ? null : (date == today ? 0 : (date == tomorrow ? 1 : 2)),
                hint: dateLabel.isEmpty ? l10n.checkout_date_pick : dateLabel,
                items: <AppDropdownItem<int>>[
                  AppDropdownItem<int>(value: 0, label: l10n.checkout_date_today),
                  AppDropdownItem<int>(value: 1, label: l10n.checkout_date_tomorrow),
                  AppDropdownItem<int>(
                    value: 2,
                    label: date != null && date != today && date != tomorrow ? dateLabel : l10n.checkout_date_pick,
                  ),
                ],
                onChanged: (int v) {
                  if (v == 0) {
                    view.ctl.setDesiredDate(today);
                  } else if (v == 1) {
                    view.ctl.setDesiredDate(tomorrow);
                  } else {
                    view.onPickDate();
                  }
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: AppDropdown<CheckoutSlot>(
                key: const ValueKey<String>('checkout-slot'),
                value: s.slot,
                hint: l10n.checkout_time_label,
                errorText: view.error(l10n, CheckoutField.slot),
                items: <AppDropdownItem<CheckoutSlot>>[
                  for (final CheckoutSlot slot in view.slots)
                    AppDropdownItem<CheckoutSlot>(
                      value: slot,
                      label: l10n.checkout_slot_value(slot.from, slot.to),
                      enabled: !view.ctl.isSlotPast(slot, date),
                    ),
                ],
                onChanged: view.ctl.setSlot,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// =====================================================================================================================
// Зона D — «Оплата»
// =====================================================================================================================

/// Зона D (UI-21-012, UI-21-013, UI-21-022, UI-21-026…UI-21-028).
class CheckoutPaymentSection extends StatelessWidget {
  const CheckoutPaymentSection({super.key, required this.view, this.tilesInRow = true});

  final CheckoutView view;
  final bool tilesInRow;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CheckoutState s = view.state;
    final bool customerMode = s.customerMode;
    final List<PaymentMethod> allowed = s.allowedMethods;
    final CreditBlock? block = s.effectiveCreditBlock;
    final bool checkingCredit =
        s.paymentMethod == PaymentMethod.credit && s.previewing && s.preview?.paymentMethod != PaymentMethod.credit;
    // Режим клиента: плитки `cash` и QR (при `QR_PROVIDER ≠ none`), без долга (03 §9.34).
    final List<PaymentMethod> shown = customerMode
        ? <PaymentMethod>[PaymentMethod.cash, if (view.qr.provider != QrProviderMode.none) PaymentMethod.qrBakai]
        : PaymentMethod.values;
    final List<Widget> tiles = <Widget>[
      for (final PaymentMethod m in shown)
        PaymentMethodCard(
          method: m,
          title: _title(l10n, m, customerMode),
          subtitle: _subtitle(l10n, m, customerMode),
          selected: s.paymentMethod == m,
          blocked: m == PaymentMethod.credit && block != null,
          loading: m == PaymentMethod.credit && checkingCredit,
          loadingLabel: l10n.checkout_pay_checking_debt,
          disabledReason: _disabledReason(l10n, m, allowed, block),
          onTap: !allowed.contains(m) || (m == PaymentMethod.credit && block != null)
              ? null
              : () => view.ctl.setPaymentMethod(m),
        ),
    ];
    final String? info = _info(l10n, s);
    return Column(
      key: const ValueKey<String>('checkout-section-payment'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        CheckoutSectionTitle(l10n.checkout_section_payment),
        if (tilesInRow)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (int i = 0; i < tiles.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: 12),
                Expanded(child: tiles[i]),
              ],
            ],
          )
        else
          for (int i = 0; i < tiles.length; i++) ...<Widget>[if (i > 0) const SizedBox(height: 12), tiles[i]],
        if (view.error(l10n, CheckoutField.paymentMethod) case final String err)
          Padding(
            padding: EdgeInsets.only(top: context.space.s1),
            child: Text(err, style: context.text.caption.copyWith(color: context.colors.error)),
          ),
        if (customerMode && view.qr.provider == QrProviderMode.none)
          Padding(
            padding: EdgeInsets.only(top: context.space.s2),
            child: Text(
              l10n.checkout_customer_qr_unavailable,
              key: const ValueKey<String>('checkout-customer-qr-unavailable'),
              style: context.text.caption.copyWith(color: context.colors.textSecondary),
            ),
          ),
        if (!customerMode &&
            block != null &&
            (s.paymentMethod == PaymentMethod.credit || s.creditBlock != null)) ...<Widget>[
          const SizedBox(height: 12),
          ErrorState.inline(
            key: const ValueKey<String>('checkout-credit-reason'),
            message: creditReasonText(l10n, block, view.role),
          ),
          if (block.escalatable && (view.role == RoleCode.seller || view.role == RoleCode.cashier))
            Align(
              alignment: Alignment.centerLeft,
              child: AppButton(
                key: const ValueKey<String>('checkout-credit-help'),
                label: l10n.checkout_credit_how_to_approve,
                variant: AppButtonVariant.text,
                size: AppButtonSize.s,
                onPressed: view.onCreditHelp,
              ),
            ),
          if (block.escalatable && view.role == RoleCode.seniorSeller)
            Align(
              alignment: Alignment.centerLeft,
              child: AppButton(
                key: const ValueKey<String>('checkout-credit-approve'),
                label: l10n.checkout_credit_allow,
                variant: AppButtonVariant.tonal,
                size: AppButtonSize.s,
                onPressed: view.onCreditApprove,
              ),
            ),
        ],
        // UI-21-028 / AC-UI-21-013: долг разрешён старшим в своей сессии (причина + step-up) — «Разрешено: {name}».
        if (!customerMode &&
            s.paymentMethod == PaymentMethod.credit &&
            s.creditOverrideToken != null &&
            block == null &&
            view.viewerName != null)
          Padding(
            padding: EdgeInsets.only(top: context.space.s2),
            child: Text(
              l10n.checkout_credit_allowed_by(view.viewerName!),
              key: const ValueKey<String>('checkout-credit-allowed-by'),
              style: context.text.caption.copyWith(color: context.colors.success),
            ),
          ),
        if (s.paymentMethod == PaymentMethod.credit &&
            block == null &&
            view.seesDebtSums &&
            view.role != RoleCode.admin)
          ?_forecast(context, l10n, s),
        if (s.forbiddenPayment)
          Padding(
            padding: EdgeInsets.only(top: context.space.s2),
            child: ErrorState.inline(message: l10n.checkout_forbidden_payment),
          ),
        if (info != null) ...<Widget>[
          const SizedBox(height: 12),
          ErrorState.banner(
            key: const ValueKey<String>('checkout-payment-info'),
            message: info,
            tone: s.paymentMethod == PaymentMethod.qrBakai && view.qr.autoConfirm
                ? ErrorStateTone.success
                : ErrorStateTone.info,
          ),
        ],
      ],
    );
  }

  static String _title(AppLocalizations l10n, PaymentMethod m, bool customerMode) => switch (m) {
    PaymentMethod.cash => customerMode ? l10n.checkout_customer_pay_on_pickup : l10n.checkout_pay_cash_title,
    PaymentMethod.qrBakai => customerMode ? l10n.checkout_customer_pay_qr : l10n.checkout_pay_qr_title,
    PaymentMethod.credit => l10n.checkout_pay_credit_title,
  };

  static String? _subtitle(AppLocalizations l10n, PaymentMethod m, bool customerMode) => customerMode
      ? null
      : switch (m) {
          PaymentMethod.cash => l10n.checkout_pay_cash_hint,
          PaymentMethod.qrBakai => l10n.checkout_pay_qr_hint,
          PaymentMethod.credit => l10n.checkout_pay_credit_hint,
        };

  String? _disabledReason(AppLocalizations l10n, PaymentMethod m, List<PaymentMethod> allowed, CreditBlock? block) {
    if (m == PaymentMethod.credit && block != null) return creditReasonText(l10n, block, view.role);
    if (!allowed.contains(m)) {
      return m == PaymentMethod.credit ? l10n.checkout_credit_reason_no_permission : l10n.checkout_forbidden_payment;
    }
    return null;
  }

  String? _info(AppLocalizations l10n, CheckoutState s) {
    switch (s.paymentMethod) {
      case null:
        return null;
      case PaymentMethod.cash:
        if (s.customerMode) return null;
        return view.role == RoleCode.cashier || view.role == RoleCode.seniorSeller
            ? l10n.checkout_pay_info_cash_cashier
            : l10n.checkout_pay_info_cash_seller;
      case PaymentMethod.qrBakai:
        if (s.customerMode) return null;
        return view.qr.autoConfirm ? l10n.checkout_pay_info_qr_webhook : l10n.checkout_pay_info_qr_manual;
      case PaymentMethod.credit:
        if (s.effectiveCreditBlock != null) return null;
        return null;
    }
  }

  Widget? _forecast(BuildContext context, AppLocalizations l10n, CheckoutState s) {
    final PaymentChecks? pc = s.preview?.paymentChecks;
    final Money? balance = s.customer?.receivable?.balance;
    final Money? total = s.preview?.totalToPay ?? s.preview?.total;
    if (pc == null || balance == null || total == null) return null;
    return Padding(
      padding: EdgeInsets.only(top: context.space.s2),
      child: Text(
        l10n.checkout_debt_forecast(
          CheckoutFormats.money(balance + total),
          pc.limitRemaining == null ? '—' : CheckoutFormats.money(pc.limitRemaining!),
          pc.receivablesAsOf == null ? '—' : CheckoutFormats.time(pc.receivablesAsOf!),
        ),
        key: const ValueKey<String>('checkout-debt-forecast'),
        style: context.text.caption.copyWith(color: context.colors.textSecondary),
      ),
    );
  }

  /// Причина недоступности долга (02 UI-21-022; ядро §23 п.5): `seller` — без сумм.
  static String creditReasonText(AppLocalizations l10n, CreditBlock b, RoleCode? role) {
    if (b.notIdentified) return l10n.checkout_credit_reason_not_identified;
    switch (b.reason) {
      case CreditReason.forbiddenRole:
        return l10n.checkout_credit_reason_no_permission;
      case CreditReason.creditNotAllowed:
        return l10n.checkout_credit_reason_not_allowed;
      case CreditReason.staleSnapshot:
        return l10n.checkout_credit_reason_stale;
      case CreditReason.overdue:
        if (role == RoleCode.seller) return l10n.checkout_credit_reason_seller;
        return l10n.checkout_credit_reason_overdue(
          b.overdueAmount == null ? '' : CheckoutFormats.money(b.overdueAmount!),
        );
      case CreditReason.limitExceeded:
        if (role == RoleCode.seller) return l10n.checkout_credit_reason_seller;
        return l10n.checkout_credit_reason_limit(
          b.limitRemaining == null ? '' : CheckoutFormats.money(b.limitRemaining!),
        );
      case null:
        return l10n.checkout_credit_reason_no_data;
    }
  }
}

// =====================================================================================================================
// Зона E — «Состав заказа» и итоги
// =====================================================================================================================

/// Зона E (UI-21-014, UI-21-015, UI-21-021): состав и итоги — только из `checkout-preview`.
class CheckoutItemsSection extends StatelessWidget {
  const CheckoutItemsSection({super.key, required this.view, this.maxVisibleLines = 6});

  final CheckoutView view;
  final int maxVisibleLines;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CheckoutState s = view.state;
    final CheckoutPreview? p = s.preview;
    final DsColors c = context.colors;
    final List<OrderLine> items = p?.items ?? const <OrderLine>[];
    final Set<String> conflicted = <String>{
      for (final CartConflict x in p?.conflicts ?? const <CartConflict>[]) x.variantId,
    };
    return Column(
      key: const ValueKey<String>('checkout-section-items'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AppSectionHeader(
          title: '${l10n.checkout_section_items} ${l10n.checkout_items_count(items.length)}',
          actionLabel: l10n.checkout_items_edit,
          onAction: s.submitting ? null : view.onBackToCart,
          padding: EdgeInsets.zero,
        ),
        const SizedBox(height: 8),
        if (p != null && !p.ok && p.conflicts.isNotEmpty) ...<Widget>[
          _conflicts(context, l10n, p),
          const SizedBox(height: 12),
        ],
        if (s.discountLimit != null) ...<Widget>[
          ErrorState.banner(
            key: const ValueKey<String>('checkout-discount-limit'),
            message: l10n.checkout_conflict_discount(CheckoutFormats.percent(s.discountLimit!)),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              label: l10n.checkout_back_to_cart,
              variant: AppButtonVariant.outlined,
              onPressed: view.onBackToCart,
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (p == null && s.previewing)
          const Column(
            children: <Widget>[
              SkeletonBox(height: 48),
              SizedBox(height: 8),
              SkeletonBox(height: 48),
              SizedBox(height: 8),
              SkeletonBox(height: 48),
            ],
          )
        else
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: items.length > maxVisibleLines
                  ? 64.0 * maxVisibleLines
                  : double.infinity, // money-double: allow — геометрия UI (ширина окна), не деньги
            ),
            child: ListView(
              shrinkWrap: true,
              physics: items.length > maxVisibleLines ? null : const NeverScrollableScrollPhysics(),
              children: <Widget>[for (final OrderLine l in items) _line(context, l, conflicted.contains(l.variantId))],
            ),
          ),
        const SizedBox(height: 12),
        Divider(color: c.border, height: 1),
        const SizedBox(height: 12),
        CheckoutTotals(view: view),
      ],
    );
  }

  Widget _line(BuildContext context, OrderLine l, bool conflict) {
    final DsColors c = context.colors;
    final String name = <String>[?l.productName, ?l.variantName].join(' · ');
    final String qty = _qty(l.quantity.value);
    final String unit = l.unitPrice == null ? '' : ' × ${CheckoutFormats.money(l.unitPrice!)}';
    return Container(
      key: ValueKey<String>('checkout-line-${l.variantId}'),
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      decoration: BoxDecoration(
        color: conflict ? c.warningContainer : null,
        border: conflict ? Border(left: BorderSide(color: c.error, width: 3)) : null,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  name.isEmpty ? (l.sku ?? l.variantId) : name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.body.copyWith(color: c.textPrimary),
                ),
                Text(
                  '$qty$unit',
                  style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (l.lineTotal != null)
            Text(
              CheckoutFormats.money(l.lineTotal!),
              style: context.text.body.copyWith(
                fontWeight: FontWeight.w600,
                color: c.textPrimary,
                fontFeatures: DsTypography.numeric,
              ),
            ),
        ],
      ),
    );
  }

  static String _qty(Qty q) {
    final int whole = q.milli ~/ 1000;
    final int frac = q.milli.abs() % 1000;
    if (frac == 0) return '$whole';
    String f = frac.toString().padLeft(3, '0');
    while (f.endsWith('0')) {
      f = f.substring(0, f.length - 1);
    }
    return '$whole,$f';
  }

  Widget _conflicts(BuildContext context, AppLocalizations l10n, CheckoutPreview p) {
    String nameOf(String variantId) {
      for (final OrderLine l in p.items) {
        if (l.variantId == variantId) return l.productName ?? l.sku ?? variantId;
      }
      for (final CartLine l in view.state.cart?.items ?? const <CartLine>[]) {
        if (l.variantId == variantId) return l.productName ?? l.sku ?? variantId;
      }
      return variantId;
    }

    final List<String> lines = <String>[
      for (final CartConflict x in p.conflicts)
        switch (CartConflictKind.tryParse(x.rawKind)) {
          CartConflictKind.priceChanged => l10n.checkout_conflict_price(
            nameOf(x.variantId),
            x.newPrice == null ? '—' : CheckoutFormats.money(x.newPrice!),
            x.oldPrice == null ? '—' : CheckoutFormats.money(x.oldPrice!),
          ),
          CartConflictKind.stockInsufficient => l10n.checkout_conflict_stock(
            x.available == null ? '0' : _qty(x.available!),
            nameOf(x.variantId),
          ),
          _ => l10n.checkout_conflict_unavailable(nameOf(x.variantId)),
        },
    ];
    return Column(
      key: const ValueKey<String>('checkout-conflicts'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ErrorState.banner(message: '${l10n.checkout_conflicts_title}\n${lines.join('\n')}'),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: AppButton(
            key: const ValueKey<String>('checkout-back-to-cart'),
            label: l10n.checkout_back_to_cart,
            variant: AppButtonVariant.outlined,
            onPressed: view.onBackToCart,
          ),
        ),
      ],
    );
  }
}

/// Итоги `CartSummary.checkout` (UI-21-015).
class CheckoutTotals extends StatelessWidget {
  const CheckoutTotals({super.key, required this.view, this.compact = false});

  final CheckoutView view;

  /// Только строка «Итого к оплате» (compact, над кнопкой).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CheckoutState s = view.state;
    final CheckoutPreview? p = s.preview;
    final DsColors c = context.colors;
    final Money? total = p?.totalToPay ?? p?.total;
    final Widget totalText = s.previewing && p == null
        ? const SkeletonBox(width: 120, height: 32)
        : Text(
            total == null ? '—' : CheckoutFormats.money(total),
            key: const ValueKey<String>('checkout-total'),
            style: (compact ? context.text.h3 : context.text.h2).copyWith(
              color: c.primaryText,
              fontWeight: FontWeight.w700,
              fontFeatures: DsTypography.numeric,
            ),
          );
    if (compact) {
      return Row(
        children: <Widget>[
          Expanded(
            child: Text(l10n.checkout_summary_total, style: context.text.body.copyWith(color: c.textPrimary)),
          ),
          Flexible(
            child: FittedBox(fit: BoxFit.scaleDown, child: totalText),
          ),
        ],
      );
    }
    final TextStyle row = context.text.body.copyWith(color: c.textPrimary, fontFeatures: DsTypography.numeric);
    Widget line(String label, String value, {Key? key}) => Padding(
      padding: EdgeInsets.symmetric(vertical: context.space.s1),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(label, style: row.copyWith(color: c.textSecondary)),
          ),
          Text(value, key: key, style: row),
        ],
      ),
    );
    final OnecCheck? check = p?.onecCheck;
    final String? checked = check?.at == null
        ? null
        : (s.onecUnavailable
              ? l10n.checkout_checked_snapshot(CheckoutFormats.time(check!.at!))
              : (check!.performed == true ? l10n.checkout_checked_onec(CheckoutFormats.time(check.at!)) : null));
    return Column(
      key: const ValueKey<String>('checkout-totals'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (p?.subtotal != null) line(l10n.checkout_summary_subtotal, CheckoutFormats.money(p!.subtotal!)),
        if (p?.discountTotal != null && !p!.discountTotal!.isZero)
          line(
            l10n.checkout_summary_discount(CheckoutFormats.percent(p.discountPercent ?? Percent.zero)),
            '−${CheckoutFormats.money(p.discountTotal!)}',
          ),
        if (p?.customerDiscountTotal != null && !p!.customerDiscountTotal!.isZero)
          line(l10n.checkout_summary_customer_discount, '−${CheckoutFormats.money(p.customerDiscountTotal!)}'),
        const SizedBox(height: 8),
        Text(l10n.checkout_summary_total, style: context.text.title.copyWith(color: c.textPrimary)),
        Align(
          alignment: Alignment.centerRight,
          child: FittedBox(fit: BoxFit.scaleDown, child: totalText),
        ),
        if (checked != null)
          Padding(
            padding: EdgeInsets.only(top: context.space.s1),
            child: Row(
              children: <Widget>[
                Icon(Icons.schedule_rounded, size: 16, color: c.textSecondary),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(checked, style: context.text.caption.copyWith(color: c.textSecondary)),
                ),
              ],
            ),
          ),
        if (s.previewFailure != null)
          Padding(
            padding: EdgeInsets.only(top: context.space.s2),
            child: ErrorState.inline(
              key: const ValueKey<String>('checkout-preview-error'),
              message: l10n.error_internal,
              onRetry: () => unawaited(view.ctl.retryPreview()),
            ),
          ),
      ],
    );
  }
}

// =====================================================================================================================
// Зона F — «Печать после создания заказа»
// =====================================================================================================================

/// Зона F (UI-21-016): ровно три документа; состояние — в настройках устройства.
class CheckoutPrintSection extends StatelessWidget {
  const CheckoutPrintSection({super.key, required this.view});

  final CheckoutView view;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CheckoutState s = view.state;
    final DsColors c = context.colors;
    return Container(
      key: const ValueKey<String>('checkout-section-print'),
      padding: EdgeInsets.all(context.space.s4),
      decoration: BoxDecoration(color: c.surfaceVariant, borderRadius: BorderRadius.all(context.radii.md)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(l10n.checkout_print_title, style: context.text.label.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          AppCheckbox(
            key: const ValueKey<String>('checkout-print-invoice'),
            value: s.printInvoice,
            label: l10n.checkout_print_invoice,
            description: l10n.checkout_print_invoice_hint,
            onChanged: (bool? v) => view.ctl.setPrint(invoice: v ?? false),
          ),
          AppCheckbox(
            key: const ValueKey<String>('checkout-print-waybill'),
            value: s.printWaybill,
            label: l10n.checkout_print_waybill,
            description: l10n.checkout_print_waybill_hint,
            onChanged: (bool? v) => view.ctl.setPrint(waybill: v ?? false),
          ),
          AppCheckbox(
            key: const ValueKey<String>('checkout-print-receipt'),
            value: s.printReceipt,
            label: l10n.checkout_print_receipt,
            description: l10n.checkout_print_receipt_hint,
            onChanged: (bool? v) => view.ctl.setPrint(receipt: v ?? false),
          ),
        ],
      ),
    );
  }
}

/// Раскрытие полей (ANIM-020): `AnimatedSize` 200 мс; при reduce-motion — мгновенно (без `AnimatedSize`: нулевая
/// длительность перестраивает его во время layout).
class RevealSize extends StatelessWidget {
  const RevealSize({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Duration d = context.motion.of(context.motion.base);
    if (d == Duration.zero) return child;
    return AnimatedSize(duration: d, alignment: Alignment.topCenter, curve: context.motion.standard, child: child);
  }
}
