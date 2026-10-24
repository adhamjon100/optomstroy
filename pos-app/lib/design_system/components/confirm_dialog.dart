import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/motion/ds_animations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Варианты `ConfirmDialog` (03 §9.45).
enum ConfirmDialogVariant {
  /// CTA `primary`.
  standard,

  /// CTA `danger`, иконка `error`; тап по overlay не закрывает.
  destructive,

  /// Обязательная причина (≥ [ConfirmDialog.minReasonLength] символов).
  withReason,
}

/// Подтверждение действия `ConfirmDialog` (03 §9.45): радиус `lg`, `elevation.3` + `overlay`,
/// ширина 360…480 (compact — экран − 32), паддинг 24; кнопки справа «Отмена» (`text`) + CTA;
/// фокус по умолчанию — «Отмена». Результат — `Future<bool>` через [show].
class ConfirmDialog extends StatefulWidget {
  /// Создаёт диалог (обычно — через [show]).
  const ConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.variant = ConfirmDialogVariant.standard,
    this.cancelLabel,
    this.reasonLabel,
    this.reasonMaxLength = 200,
    this.onConfirm,
    this.failureMessage,
    this.destructiveCta = false,
  });

  /// Заголовок `h3`.
  final String title;

  /// Конкретные последствия («Будут удалены 5 позиций»).
  final String message;

  /// Глагол CTA («Очистить», «Отменить заказ»).
  final String confirmLabel;

  /// Вариант.
  final ConfirmDialogVariant variant;

  /// «Отмена» (по умолчанию `ds_button_cancel`).
  final String? cancelLabel;

  /// Подпись поля причины (`withReason`).
  final String? reasonLabel;

  /// Лимит причины.
  final int reasonMaxLength;

  /// Выполнение действия: CTA в loading, «Отмена» disabled; ошибка — инлайн под текстом,
  /// диалог остаётся. Аргумент — причина (`withReason`) или `null`.
  final Future<void> Function(String? reason)? onConfirm;

  /// Текст ошибки выполнения (по умолчанию `error_internal`).
  final String? failureMessage;

  /// CTA `danger` у варианта `withReason` (отмена заказа).
  final bool destructiveCta;

  /// Минимальная длина причины [ТИПОВО] (03 §9.45).
  static const int minReasonLength = 5;

  /// Показывает диалог; `true` — подтверждено (после успешного [onConfirm]).
  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    ConfirmDialogVariant variant = ConfirmDialogVariant.standard,
    String? cancelLabel,
    String? reasonLabel,
    Future<void> Function(String? reason)? onConfirm,
    String? failureMessage,
    bool destructiveCta = false,
  }) async {
    final DsColors c = context.colors;
    final Duration d = context.motion.of(DsAnimations.dialog.duration);
    final bool? result = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: variant != ConfirmDialogVariant.destructive,
      barrierLabel: cancelLabel ?? AppLocalizations.of(context).ds_button_cancel,
      barrierColor: c.overlay,
      transitionDuration: d,
      pageBuilder: (BuildContext ctx, Animation<double> a, Animation<double> b) => ConfirmDialog(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        variant: variant,
        cancelLabel: cancelLabel,
        reasonLabel: reasonLabel,
        onConfirm: onConfirm,
        failureMessage: failureMessage,
        destructiveCta: destructiveCta,
      ),
      transitionBuilder: (BuildContext ctx, Animation<double> a, Animation<double> b, Widget child) {
        final CurvedAnimation curve = CurvedAnimation(parent: a, curve: DsAnimations.dialog.curve);
        return FadeTransition(
          opacity: curve,
          child: ScaleTransition(scale: Tween<double>(begin: 0.96, end: 1).animate(curve), child: child),
        );
      },
    );
    return result ?? false;
  }

  @override
  State<ConfirmDialog> createState() => _ConfirmDialogState();
}

class _ConfirmDialogState extends State<ConfirmDialog> {
  final TextEditingController _reason = TextEditingController();
  final FocusNode _cancelFocus = FocusNode(debugLabel: 'ConfirmDialog.cancel');
  bool _busy = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _reason.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _reason.dispose();
    _cancelFocus.dispose();
    super.dispose();
  }

  bool get _reasonOk =>
      widget.variant != ConfirmDialogVariant.withReason ||
      _reason.text.trim().characters.length >= ConfirmDialog.minReasonLength;

  Future<void> _confirm() async {
    if (_busy || !_reasonOk) {
      return;
    }
    final String? reason = widget.variant == ConfirmDialogVariant.withReason ? _reason.text.trim() : null;
    if (widget.onConfirm == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await widget.onConfirm!(reason);
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } on Object {
      if (mounted) {
        setState(() {
          _busy = false;
          _failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool compact = context.windowClass == WindowClass.compact;
    final double screen = MediaQuery.sizeOf(context).width;
    final double width = compact ? (screen - 32).clamp(280.0, 480.0) : 420;
    final bool destructive = widget.variant == ConfirmDialogVariant.destructive || widget.destructiveCta;

    final Widget cancel = AppButton(
      label: widget.cancelLabel ?? l10n.ds_button_cancel,
      variant: AppButtonVariant.text,
      focusNode: _cancelFocus,
      autofocus: true,
      onPressed: _busy ? null : () => Navigator.of(context).pop(false),
    );
    final Widget confirm = AppButton(
      label: widget.confirmLabel,
      variant: destructive ? AppButtonVariant.danger : AppButtonVariant.primary,
      loading: _busy,
      onPressed: _reasonOk ? () => unawaited(_confirm()) : null,
    );

    return Center(
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: widget.title,
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            width: width,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.all(context.radii.lg),
              boxShadow: context.elevation.e3,
            ),
            child: FocusScope(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (widget.variant != ConfirmDialogVariant.standard) ...<Widget>[
                    ExcludeSemantics(
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: destructive ? c.errorContainer : c.warningContainer,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          destructive ? Icons.error_rounded : Icons.warning_rounded,
                          size: 32,
                          color: destructive ? c.error : c.warning,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Text(widget.title, style: context.text.h3.copyWith(color: c.textPrimary)),
                  const SizedBox(height: 8),
                  Text(widget.message, style: context.text.body.copyWith(color: c.textSecondary)),
                  if (_failed) ...<Widget>[
                    const SizedBox(height: 8),
                    ErrorState.inline(
                      message: widget.failureMessage ?? l10n.error_internal,
                      onRetry: () => unawaited(_confirm()),
                    ),
                  ],
                  if (widget.variant == ConfirmDialogVariant.withReason) ...<Widget>[
                    const SizedBox(height: 16),
                    AppTextField(
                      controller: _reason,
                      label: widget.reasonLabel,
                      variant: AppTextFieldVariant.multiline,
                      maxLength: widget.reasonMaxLength,
                      enabled: !_busy,
                    ),
                  ],
                  const SizedBox(height: 24),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[cancel, confirm],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
