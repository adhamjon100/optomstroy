// Диалог «Аварийный код входа» (UI-45-024; RM-D-016; ядро §22.13 п.2, §23 п.8; 08 §4.18.10; 11 SEC-131).
// Шаг 1 — причина (+ комментарий 5…200, обязателен при `other`) → StepUpDialog (только PIN) → запрос
// без `Idempotency-Key`. Шаг 2 — код показывается ОДИН раз: без копирования, без снекбаров/логов/drift;
// закрытие — только через подтверждение; при сворачивании приложения код скрывается и диалог закрывается.
// После закрытия код не восстанавливается (живёт только в состоянии этого виджета).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/admin/domain/users/emergency_login_code.dart';
import 'package:optomstroy/features/admin/domain/users/step_up.dart';
import 'package:optomstroy/features/admin/presentation/common/admin_format.dart';
import 'package:optomstroy/features/admin/presentation/users/admin_failure_text.dart';

typedef EmergencyCodeIssue =
    Future<AdminActionResult<EmergencyLoginCode>> Function(EmergencyCodeReason reason, String? comment);

class EmergencyCodeDialog extends StatefulWidget {
  const EmergencyCodeDialog({super.key, required this.userName, required this.issue});

  final String userName;
  final EmergencyCodeIssue issue;

  /// Диалог 480 (compact — полноэкранный).
  static Future<void> show(BuildContext context, {required String userName, required EmergencyCodeIssue issue}) {
    final body = EmergencyCodeDialog(userName: userName, issue: issue);
    if (DsBreakpoints.of(context) == WindowClass.compact) {
      return Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (ctx) => Scaffold(body: SafeArea(child: body)),
        ),
      );
    }
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: body),
      ),
    );
  }

  @override
  State<EmergencyCodeDialog> createState() => _EmergencyCodeDialogState();
}

class _EmergencyCodeDialogState extends State<EmergencyCodeDialog> {
  final TextEditingController _comment = TextEditingController();
  late final AppLifecycleListener _lifecycle;
  EmergencyCodeReason? _reason;
  bool _busy = false;
  String? _error;

  /// Код — только здесь; обнуляется при закрытии, сворачивании и dispose.
  EmergencyLoginCode? _code;

  @override
  void initState() {
    super.initState();
    _comment.addListener(() => setState(() {}));
    _lifecycle = AppLifecycleListener(onHide: _hideOnBackground, onPause: _hideOnBackground);
  }

  @override
  void dispose() {
    _code = null;
    _lifecycle.dispose();
    _comment.dispose();
    super.dispose();
  }

  /// Сворачивание приложения / idle-блокировка: код больше не показывается (UI-45-024).
  void _hideOnBackground() {
    if (_code == null || !mounted) return;
    setState(() => _code = null);
    Navigator.of(context).pop();
  }

  bool get _valid => EmergencyCodeRules.isValid(_reason, _comment.text);

  Future<void> _issue() async {
    if (_busy || !_valid) return; // повторные нажатия во время запроса игнорируются
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    final comment = _comment.text.trim();
    final result = await widget.issue(_reason!, comment.isEmpty ? null : comment);
    if (!mounted) return;
    setState(() {
      _busy = false;
      switch (result) {
        case ActionDone(:final value):
          _code = value;
        case ActionFailed(:final failure):
          _error = AdminFailureText.of(l10n, failure, context: AdminFailureContext.emergencyCode);
        case ActionCancelled():
          break;
      }
    });
  }

  Future<void> _close() async {
    if (_code == null) {
      if (!_busy) Navigator.of(context).pop();
      return;
    }
    final l10n = AppLocalizations.of(context);
    final ok = await ConfirmDialog.show(
      context,
      title: l10n.admin_users_emergency_close_confirm,
      message: l10n.admin_users_emergency_hint,
      confirmLabel: l10n.ds_button_close,
    );
    if (!ok || !mounted) return;
    setState(() => _code = null);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = context.colors;
    final code = _code;
    return PopScope(
      canPop: code == null && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          key: ValueKey<String>(code == null ? 'emergency-reason' : 'emergency-shown'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.admin_users_emergency_title(widget.userName),
              style: context.text.h3.copyWith(color: c.textPrimary),
            ),
            const SizedBox(height: 16),
            if (code == null) ..._reasonStep(context, l10n) else ..._shownStep(context, l10n, code),
          ],
        ),
      ),
    );
  }

  List<Widget> _reasonStep(BuildContext context, AppLocalizations l10n) {
    final c = context.colors;
    return [
      for (final (reason, label) in [
        (EmergencyCodeReason.smsUnavailable, l10n.admin_users_emergency_reason_sms),
        (EmergencyCodeReason.simLost, l10n.admin_users_emergency_reason_sim),
        (EmergencyCodeReason.other, l10n.admin_users_emergency_reason_other),
      ])
        AppRadio<EmergencyCodeReason>(
          key: ValueKey<String>('emergency-reason-${reason.value}'),
          value: reason,
          groupValue: _reason,
          label: label,
          onChanged: _busy ? null : (r) => setState(() => _reason = r),
        ),
      const SizedBox(height: 8),
      AppTextField(
        key: const ValueKey<String>('emergency-comment'),
        controller: _comment,
        label: l10n.customer_new_comment_label,
        variant: AppTextFieldVariant.multiline,
        maxLength: EmergencyCodeRules.commentMax,
        enabled: !_busy,
      ),
      const SizedBox(height: 8),
      _Hint(text: l10n.admin_users_emergency_hint),
      if (_error != null) ...[
        const SizedBox(height: 8),
        Text(
          _error!,
          key: const ValueKey<String>('emergency-error'),
          style: context.text.body.copyWith(color: c.error),
        ),
      ],
      const SizedBox(height: 24),
      Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 8,
        children: [
          AppButton(
            label: l10n.ds_button_cancel,
            variant: AppButtonVariant.text,
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
          ),
          AppButton(
            key: const ValueKey<String>('emergency-issue'),
            label: l10n.admin_users_emergency_issue,
            icon: Icons.key_rounded,
            loading: _busy,
            onPressed: _valid ? () => unawaited(_issue()) : null,
          ),
        ],
      ),
    ];
  }

  List<Widget> _shownStep(BuildContext context, AppLocalizations l10n, EmergencyLoginCode code) {
    final c = context.colors;
    final locale = Localizations.localeOf(context).toString();
    final until = DateFormat('HH:mm', locale).format(AdminFormat.wall(code.expiresAt));
    return [
      Semantics(
        liveRegion: true,
        child: Text(
          code.code,
          key: const ValueKey<String>('emergency-code-value'),
          textAlign: TextAlign.center,
          style: context.text.h1.copyWith(
            color: c.textPrimary,
            fontFeatures: const [FontFeature.tabularFigures()],
            letterSpacing: 6,
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text(
        code.phoneMasked,
        textAlign: TextAlign.center,
        style: context.text.body.copyWith(color: c.textSecondary),
      ),
      const SizedBox(height: 8),
      Text(l10n.admin_users_emergency_shown(code.code, until), style: context.text.body.copyWith(color: c.textPrimary)),
      const SizedBox(height: 8),
      _Hint(text: l10n.admin_users_emergency_hint),
      const SizedBox(height: 24),
      Align(
        alignment: AlignmentDirectional.centerEnd,
        child: AppButton(
          key: const ValueKey<String>('emergency-close'),
          label: l10n.ds_button_close,
          variant: AppButtonVariant.secondary,
          onPressed: () => unawaited(_close()),
        ),
      ),
    ];
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: c.warningContainer, borderRadius: BorderRadius.all(context.radii.md)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_rounded, size: 20, color: c.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: context.text.body.copyWith(color: c.textPrimary)),
          ),
        ],
      ),
    );
  }
}
