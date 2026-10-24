// Диалоги SCR-39: «Выйти без сохранения?» (02 SCR-39.6: «Сохранить черновик» / «Выйти»), удаление черновика
// (UI-39-014, `ConfirmDialog.destructive`), согласование (UI-39-015, `ConfirmDialog`), отклонение с обязательной
// причиной 5…500 (UI-39-016, `ConfirmDialog.withReason` + CTA `danger`), ввод количества нампадом (UI-39-003).
import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/quantity_numpad_sheet.dart';
import 'package:optomstroy/design_system/components/unit_selector.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/returns/presentation/returns_format.dart';
import 'package:optomstroy/features/returns/presentation/state/return_request_state.dart';
import 'package:optomstroy/features/returns/presentation/widgets/return_sections.dart';

/// Выбор в диалоге выхода с несохранёнными изменениями.
enum ReturnLeaveChoice { stay, save, leave }

/// Диалоги SCR-39.
abstract final class ReturnDialogs {
  /// Ключи кнопок диалога выхода (тесты).
  static const ValueKey<String> leaveSaveKey = ValueKey<String>('return-leave-save');
  static const ValueKey<String> leaveExitKey = ValueKey<String>('return-leave-exit');

  /// «Выйти без сохранения? Выбранные позиции не сохранятся» — «Отмена» · «Сохранить черновик» · «Выйти».
  /// «Выйти» — ключ `profile_logout` (того же текста; своего ключа SCR-39 нет — GQ-FERET-02).
  static Future<ReturnLeaveChoice> leave(BuildContext context, {required bool canSave}) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final ReturnLeaveChoice? r = await showGeneralDialog<ReturnLeaveChoice>(
      context: context,
      barrierDismissible: true,
      barrierLabel: l10n.ds_button_cancel,
      barrierColor: c.overlay,
      transitionDuration: context.motion.of(const Duration(milliseconds: 200)),
      pageBuilder: (BuildContext ctx, _, _) => Center(
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            width: 420,
            margin: EdgeInsets.all(ctx.space.s4),
            padding: EdgeInsets.all(ctx.space.s6),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.all(ctx.radii.lg),
              boxShadow: ctx.elevation.e3,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(l10n.return_leave_title, style: ctx.text.h3.copyWith(color: c.textPrimary)),
                SizedBox(height: ctx.space.s2),
                Text(l10n.return_leave_body, style: ctx.text.body.copyWith(color: c.textSecondary)),
                SizedBox(height: ctx.space.s6),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: ctx.space.s2,
                  runSpacing: ctx.space.s2,
                  children: <Widget>[
                    AppButton(
                      label: l10n.ds_button_cancel,
                      variant: AppButtonVariant.text,
                      autofocus: true,
                      onPressed: () => Navigator.of(ctx).pop(ReturnLeaveChoice.stay),
                    ),
                    if (canSave)
                      AppButton(
                        key: leaveSaveKey,
                        label: l10n.return_save_draft,
                        variant: AppButtonVariant.outlined,
                        onPressed: () => Navigator.of(ctx).pop(ReturnLeaveChoice.save),
                      ),
                    AppButton(
                      key: leaveExitKey,
                      label: l10n.profile_logout,
                      variant: AppButtonVariant.danger,
                      onPressed: () => Navigator.of(ctx).pop(ReturnLeaveChoice.leave),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return r ?? ReturnLeaveChoice.stay;
  }

  /// «Удалить черновик заявки?» (фокус на «Отмена»).
  static Future<bool> delete(BuildContext context, {required String orderNumber}) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return ConfirmDialog.show(
      context,
      title: l10n.return_delete_title,
      message: l10n.return_delete_body(orderNumber),
      confirmLabel: l10n.return_delete_draft,
      variant: ConfirmDialogVariant.destructive,
    );
  }

  /// «Согласовать заявку на возврат?» (комментарий необязателен — в R1 не запрашивается, GQ-FERET-05).
  static Future<bool> accept(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return ConfirmDialog.show(
      context,
      title: l10n.return_accept_title,
      message: l10n.return_accept_body,
      confirmLabel: l10n.return_accept,
    );
  }

  /// «Отклонить заявку на возврат?» с обязательной причиной 5…500; `null` — отмена.
  static Future<String?> reject(BuildContext context) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    String? reason;
    final bool? ok = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierLabel: l10n.ds_button_cancel,
      barrierColor: c.overlay,
      transitionDuration: context.motion.of(const Duration(milliseconds: 200)),
      pageBuilder: (BuildContext ctx, _, _) => ConfirmDialog(
        title: l10n.return_reject_title,
        message: l10n.return_reject_reason_error,
        confirmLabel: l10n.return_reject,
        variant: ConfirmDialogVariant.withReason,
        destructiveCta: true,
        reasonLabel: l10n.return_reject_reason_label,
        reasonMaxLength: 500,
        onConfirm: (String? r) async => reason = r,
      ),
    );
    if (ok != true) return null;
    final String text = reason?.trim() ?? '';
    return text.length < ReturnFormState.rejectReasonMin ? null : text;
  }

  /// Ввод количества строки нампадом; `null` — отмена.
  static Future<Qty?> quantity(BuildContext context, ReturnLine line) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final QuantityNumpadResult? r = await QuantityNumpadSheet.show(
      context,
      title: line.title ?? line.variantId,
      subtitle: l10n.return_item_max(ReturnsFormat.qty(line.limit)),
      initialInput: ReturnsFormat.qty(line.qty),
      units: <UnitOption>[UnitOption(id: line.unitId, label: '')],
      selectedUnitId: line.unitId,
      decimalsFor: (String _) => line.limit.isWhole && line.sold.isWhole ? 0 : Qty.maxPrecision,
      validate: (String input, String _) {
        final ({Qty? qty, String? error}) v = ReturnQtyInput.validate(l10n, input, line.limit);
        return NumpadValidation(error: v.error, canSubmit: v.qty != null && v.error == null);
      },
    );
    if (r == null) return null;
    return ReturnsFormat.parseQty(r.input);
  }
}
