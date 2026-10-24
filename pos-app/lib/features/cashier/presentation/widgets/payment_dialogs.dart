// Диалоги SCR-38: ручное подтверждение QR и аннулирование — компоненты `payment_action_dialogs.dart` (тело запроса
// собирается здесь), «Как получить разрешение старшего» (CASH-007: только в собственной сессии старшего;
// `StepUpDialog.supervisor` — R2).
import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/payment_action_dialogs.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

/// Ручное подтверждение оплаты по выписке → тело `POST /payments/{id}/confirm-manual` или `null`.
Future<ConfirmManualRequest?> showManualConfirm(
  BuildContext context, {
  required Money amount,
  required DateTime nowUtc,
}) async {
  final ManualConfirmInput? v = await PaymentManualConfirmDialog.show(context, amount: amount, nowUtc: nowUtc);
  if (v == null) return null;
  return ConfirmManualRequest(
    bankReference: v.reference,
    receivedAmount: v.amount,
    receivedAt: v.receivedAt,
    comment: v.comment,
  );
}

/// Аннулирование неполученного платежа → тело `POST /payments/{id}/void` или `null`.
Future<VoidPaymentRequest?> showVoidPayment(BuildContext context, {required String body}) async {
  final VoidInput? v = await PaymentVoidDialog.show(context, body: body);
  if (v == null) return null;
  final PaymentVoidReasonCode code = PaymentVoidReasonCode.values.firstWhere(
    (PaymentVoidReasonCode c) => c.value == v.reason.value,
    orElse: () => PaymentVoidReasonCode.other,
  );
  return VoidPaymentRequest(reason: v.text, reasonCode: code);
}

/// «Как получить разрешение старшего» (CASH-007): подтверждающий входит в своё приложение или открывает отложенную
/// операцию на своём устройстве; ввод его PIN/OTP в этой сессии запрещён.
Future<void> showSeniorApprovalHelp(BuildContext context) {
  final AppLocalizations l10n = AppLocalizations.of(context);
  return showDialog<void>(
    context: context,
    barrierColor: context.colors.overlay,
    builder: (BuildContext ctx) => Dialog(
      backgroundColor: ctx.colors.surface,
      surfaceTintColor: ctx.colors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(ctx.radii.lg)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: EdgeInsets.all(ctx.space.s6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                l10n.checkout_credit_how_to_approve,
                key: const ValueKey<String>('senior-help-title'),
                style: ctx.text.title.copyWith(color: ctx.colors.textPrimary),
              ),
              SizedBox(height: ctx.space.s3),
              Text(
                l10n.checkout_credit_approval_dialog_body,
                style: ctx.text.body.copyWith(color: ctx.colors.textPrimary),
              ),
              SizedBox(height: ctx.space.s6),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: AppButton(label: l10n.checkout_credit_help_ok, onPressed: () => Navigator.of(ctx).pop()),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
