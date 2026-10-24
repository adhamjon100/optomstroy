// Диалоги действий над неполученным платежом (02 SCR-37 UI-37-009, UI-37-010; SCR-38 UI-38-015): ручное
// подтверждение оплаты по выписке (референс 4–64, сумма, время зачисления, комментарий ≤ 200; при несовпадении
// суммы — предупреждение до отправки) и аннулирование (`ConfirmDialog.withReason`-вариант с выбором причины:
// «Ошибка кассира» · «Клиент отказался» · «Дубликат» · «Иное» — комментарий ≥ 5 символов). Способ подтверждения
// (PIN / код из SMS) — `StepUpDialog` core/session у вызывающего кода (P-STEPUP, P-STEPUP-PRE). Компонент возвращает
// значения формы; запрос формирует фича (orders/cashier/transactions).
import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/date_range_picker.dart' show DsBishkekTime;
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Значения формы ручного подтверждения.
typedef ManualConfirmInput = ({String reference, Money amount, DateTime receivedAt, String? comment});

/// Причина аннулирования (`PaymentsVoidReasonCode`, 08 §4.9.4).
enum PaymentVoidReason {
  cashierError('cashier_error'),
  customerRefused('customer_refused'),
  duplicate('duplicate'),
  other('other');

  const PaymentVoidReason(this.value);

  /// Значение API.
  final String value;
}

/// Значения формы аннулирования.
typedef VoidInput = ({PaymentVoidReason reason, String text});

Widget _paymentDialogFrame(BuildContext context, {required List<Widget> children, double maxWidth = 440}) {
  final DsColors c = context.colors;
  return Dialog(
    backgroundColor: c.surface,
    surfaceTintColor: c.surface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(context.radii.lg)),
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: SingleChildScrollView(
        padding: EdgeInsets.all(context.space.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    ),
  );
}

/// Ручное подтверждение оплаты по выписке; результат — тело запроса или `null` (отмена).
class PaymentManualConfirmDialog extends StatefulWidget {
  /// Создаёт диалог.
  const PaymentManualConfirmDialog({super.key, required this.amount, required this.nowUtc});

  /// Сумма платежа (предзаполнение «Получено»).
  final Money amount;

  /// «Сейчас» — время зачисления по умолчанию.
  final DateTime nowUtc;

  /// Показать диалог.
  static Future<ManualConfirmInput?> show(BuildContext context, {required Money amount, required DateTime nowUtc}) =>
      showDialog<ManualConfirmInput>(
        context: context,
        barrierColor: context.colors.overlay,
        builder: (BuildContext ctx) => PaymentManualConfirmDialog(amount: amount, nowUtc: nowUtc),
      );

  @override
  State<PaymentManualConfirmDialog> createState() => _PaymentManualConfirmDialogState();
}

class _PaymentManualConfirmDialogState extends State<PaymentManualConfirmDialog> {
  final TextEditingController _ref = TextEditingController();
  late final TextEditingController _amount = TextEditingController(
    text: widget.amount.toApiString().replaceAll('.', ','),
  );
  late final TextEditingController _time = TextEditingController(text: DsBishkekTime.time(widget.nowUtc));
  final TextEditingController _comment = TextEditingController();
  bool _tried = false;

  @override
  void dispose() {
    _ref.dispose();
    _amount.dispose();
    _time.dispose();
    _comment.dispose();
    super.dispose();
  }

  Money? get _parsedAmount {
    try {
      return Money.parseInput(_amount.text);
    } on Object {
      return null;
    }
  }

  bool get _refOk {
    final int n = _ref.text.trim().length;
    return n >= 4 && n <= 64;
  }

  DateTime _receivedAt() {
    final RegExpMatch? m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(_time.text.trim());
    if (m == null) return widget.nowUtc;
    final int h = int.parse(m.group(1)!);
    final int min = int.parse(m.group(2)!);
    if (h > 23 || min > 59) return widget.nowUtc;
    final DateTime day = DsBishkekTime.startOfDayUtc(widget.nowUtc);
    return day.add(Duration(hours: h, minutes: min));
  }

  void _submit() {
    setState(() => _tried = true);
    final Money? amount = _parsedAmount;
    if (!_refOk || amount == null || amount.isZero) return;
    final String comment = _comment.text.trim();
    Navigator.of(context).pop((
      reference: _ref.text.trim(),
      amount: amount,
      receivedAt: _receivedAt(),
      comment: comment.isEmpty ? null : comment,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final Money? amount = _parsedAmount;
    final bool mismatch = amount != null && amount != widget.amount;
    return _paymentDialogFrame(
      context,
      children: <Widget>[
        Text(l10n.payment_manual_title, style: context.text.title.copyWith(color: c.textPrimary)),
        SizedBox(height: context.space.s4),
        AppTextField(
          key: const ValueKey<String>('payment-manual-ref'),
          controller: _ref,
          autofocus: true,
          label: l10n.payment_manual_reference,
          maxLength: 64,
          errorText: _tried && !_refOk ? l10n.payment_manual_reference_error : null,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
        ),
        SizedBox(height: context.space.s3),
        AppTextField(
          key: const ValueKey<String>('payment-manual-amount'),
          controller: _amount,
          label: l10n.transaction_details_received,
          variant: AppTextFieldVariant.number,
          errorText: _tried && (amount == null || amount.isZero) ? l10n.payment_received_less : null,
          onChanged: (_) => setState(() {}),
        ),
        if (mismatch)
          Padding(
            padding: EdgeInsets.only(top: context.space.s2),
            child: ErrorState.banner(
              key: const ValueKey<String>('payment-manual-mismatch'),
              message: l10n.payment_manual_mismatch,
              tone: ErrorStateTone.warning,
            ),
          ),
        SizedBox(height: context.space.s3),
        AppTextField(
          key: const ValueKey<String>('payment-manual-time'),
          controller: _time,
          label: l10n.order_created_manual_time_label,
          keyboardType: TextInputType.datetime,
        ),
        SizedBox(height: context.space.s3),
        AppTextField(
          key: const ValueKey<String>('payment-manual-comment'),
          controller: _comment,
          label: l10n.order_created_manual_comment_label,
          variant: AppTextFieldVariant.multiline,
          maxLength: 200,
        ),
        SizedBox(height: context.space.s6),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: context.space.s2,
          runSpacing: context.space.s2,
          children: <Widget>[
            AppButton(
              label: l10n.ds_button_cancel,
              variant: AppButtonVariant.text,
              onPressed: () => Navigator.of(context).pop(),
            ),
            AppButton(
              key: const ValueKey<String>('payment-manual-submit'),
              label: l10n.transaction_details_action_confirm_manual,
              onPressed: _refOk ? _submit : null,
            ),
          ],
        ),
      ],
    );
  }
}

/// Аннулирование неполученного платежа: причина и комментарий; результат — тело запроса или `null`.
class PaymentVoidDialog extends StatefulWidget {
  /// Создаёт диалог.
  const PaymentVoidDialog({super.key, required this.body});

  /// «Платёж {amount} по заказу № {number} будет аннулирован…».
  final String body;

  /// Показать диалог.
  static Future<VoidInput?> show(BuildContext context, {required String body}) => showDialog<VoidInput>(
    context: context,
    barrierColor: context.colors.overlay,
    builder: (BuildContext ctx) => PaymentVoidDialog(body: body),
  );

  /// Минимальная длина комментария для «Иное» (UI-37-009).
  static const int minComment = 5;

  @override
  State<PaymentVoidDialog> createState() => _PaymentVoidDialogState();
}

class _PaymentVoidDialogState extends State<PaymentVoidDialog> {
  PaymentVoidReason? _code;
  final TextEditingController _comment = TextEditingController();

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  String _label(AppLocalizations l10n, PaymentVoidReason c) => switch (c) {
    PaymentVoidReason.cashierError => l10n.transaction_details_void_reason_cashier_error,
    PaymentVoidReason.customerRefused => l10n.transaction_details_void_reason_customer_refused,
    PaymentVoidReason.duplicate => l10n.transaction_details_void_reason_duplicate,
    PaymentVoidReason.other => l10n.transaction_details_void_reason_other,
  };

  bool get _valid {
    if (_code == null) return false;
    if (_code == PaymentVoidReason.other) return _comment.text.trim().length >= PaymentVoidDialog.minComment;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final bool needComment = _code == PaymentVoidReason.other;
    return _paymentDialogFrame(
      context,
      maxWidth: 400,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(Icons.warning_amber_rounded, color: c.error, size: 24),
            SizedBox(width: context.space.s2),
            Expanded(
              child: Text(
                l10n.transaction_details_void_title,
                style: context.text.title.copyWith(color: c.textPrimary),
              ),
            ),
          ],
        ),
        SizedBox(height: context.space.s3),
        Text(widget.body, style: context.text.body.copyWith(color: c.textPrimary)),
        SizedBox(height: context.space.s3),
        for (final PaymentVoidReason code in PaymentVoidReason.values)
          AppRadio<PaymentVoidReason>(
            key: ValueKey<String>('void-reason-${code.value}'),
            value: code,
            groupValue: _code,
            label: _label(l10n, code),
            onChanged: (PaymentVoidReason v) => setState(() => _code = v),
          ),
        SizedBox(height: context.space.s2),
        AppTextField(
          key: const ValueKey<String>('void-comment'),
          controller: _comment,
          variant: AppTextFieldVariant.multiline,
          maxLength: 200,
          label: l10n.order_created_manual_comment_label,
          errorText: needComment && _comment.text.trim().length < PaymentVoidDialog.minComment
              ? l10n.transaction_details_void_comment_required
              : null,
          onChanged: (_) => setState(() {}),
        ),
        SizedBox(height: context.space.s6),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: context.space.s2,
          runSpacing: context.space.s2,
          children: <Widget>[
            AppButton(
              label: l10n.ds_button_cancel,
              variant: AppButtonVariant.text,
              onPressed: () => Navigator.of(context).pop(),
            ),
            AppButton(
              key: const ValueKey<String>('void-submit'),
              label: l10n.transaction_details_action_void,
              variant: AppButtonVariant.danger,
              onPressed: !_valid
                  ? null
                  : () {
                      final String comment = _comment.text.trim();
                      Navigator.of(
                        context,
                      ).pop((reason: _code!, text: comment.isEmpty ? _label(l10n, _code!) : comment));
                    },
            ),
          ],
        ),
      ],
    );
  }
}
