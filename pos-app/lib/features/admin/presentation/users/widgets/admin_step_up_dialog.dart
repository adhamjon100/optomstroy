// Резервный StepUpDialog фичи admin (02 §0.5; 03 §9.46; 09 §8.8; RM-D-014 п.5) — используется,
// пока core/session не переопределил порт `adminStepUpPrompterProvider`.
// PIN (6 цифр, `PIN_MIN_LENGTH_STAFF`) проверяет только сервер: попытки — из `attemptsLeft`,
// локального счётчика нет (ядро §19.3); при `PIN_LOCKED` и `pin_not_set` — переход к коду из SMS.
// Кнопки биометрии нет (R1). На compact — нижний лист. PIN, код и токен не логируются.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/secure_content.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/otp_field.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/admin/domain/users/step_up.dart';

/// Длина PIN сотрудника (`PIN_MIN_LENGTH_STAFF=6`, 09 BIO-018).
const int staffPinLength = 6;

enum _Mode { pin, otpOffer, otpCode }

class AdminStepUpDialog extends ConsumerStatefulWidget {
  const AdminStepUpDialog({super.key, required this.challenge});

  final StepUpChallenge challenge;

  /// Показать диалог; `null` — отмена.
  static Future<StepUpGrant?> show(BuildContext context, StepUpChallenge challenge) {
    final l10n = AppLocalizations.of(context);
    if (DsBreakpoints.of(context) == WindowClass.compact) {
      return AppBottomSheet.show<StepUpGrant>(
        context,
        title: l10n.ds_step_up_title,
        body: AdminStepUpDialog(challenge: challenge),
      );
    }
    return showDialog<StepUpGrant>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.ds_step_up_title, style: ctx.text.h3.copyWith(color: ctx.colors.textPrimary)),
                const SizedBox(height: 16),
                AdminStepUpDialog(challenge: challenge),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  ConsumerState<AdminStepUpDialog> createState() => _AdminStepUpDialogState();
}

class _AdminStepUpDialogState extends ConsumerState<AdminStepUpDialog> {
  late _Mode _mode = widget.challenge.allowedMethods.contains(StepUpMethod.pin) ? _Mode.pin : _Mode.otpOffer;
  CodeFieldStatus _status = CodeFieldStatus.idle;
  String? _error;
  String? _notice;
  bool _busy = false;
  String? _challengeId;

  bool get _otpAllowed => widget.challenge.allowedMethods.contains(StepUpMethod.otp);

  StepUpGateway get _gateway => ref.read(adminStepUpGatewayProvider);

  void _done(StepUpGrant grant) {
    if (mounted) Navigator.of(context).pop(grant);
  }

  Future<void> _submitPin(String pin) async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _status = CodeFieldStatus.loading;
      _error = null;
    });
    final result = await _gateway.withPin(widget.challenge.operation, pin);
    if (!mounted) return;
    switch (result) {
      case Success(:final value):
        _done(value);
      case FailureResult(:final failure):
        setState(() {
          switch (failure) {
            case AuthFailure(reason: AuthReason.pinInvalid, :final attemptsLeft):
              _status = CodeFieldStatus.error;
              _error = l10n.auth_pin_error_invalid(attemptsLeft ?? 0);
            case AuthFailure(reason: AuthReason.pinLocked):
              _status = CodeFieldStatus.disabled;
              _notice = l10n.stepup_pin_locked;
              if (_otpAllowed) _mode = _Mode.otpOffer;
            case PermissionFailure(serverReason: 'pin_not_set'):
              _status = CodeFieldStatus.disabled;
              _notice = l10n.stepup_pin_not_set;
              if (_otpAllowed) _mode = _Mode.otpOffer;
            case NetworkFailure(kind: NetworkFailureKind.offline):
              _status = CodeFieldStatus.error;
              _error = l10n.stepup_offline;
            default:
              _status = CodeFieldStatus.error;
              _error = l10n.error_internal;
          }
        });
    }
  }

  Future<void> _requestOtp() async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await _gateway.requestOtp(widget.challenge.operation);
    if (!mounted) return;
    setState(() {
      _busy = false;
      switch (result) {
        case Success(:final value):
          _challengeId = value.challengeId;
          _mode = _Mode.otpCode;
          _status = CodeFieldStatus.idle;
        case FailureResult(:final failure):
          _error = _otpError(l10n, failure);
      }
    });
  }

  Future<void> _submitOtp(String code) async {
    final l10n = AppLocalizations.of(context);
    final challengeId = _challengeId;
    if (challengeId == null) return;
    setState(() {
      _status = CodeFieldStatus.loading;
      _error = null;
    });
    final result = await _gateway.withOtp(widget.challenge.operation, challengeId: challengeId, code: code);
    if (!mounted) return;
    switch (result) {
      case Success(:final value):
        _done(value);
      case FailureResult(:final failure):
        setState(() {
          _status = CodeFieldStatus.error;
          _error = _otpError(l10n, failure);
        });
    }
  }

  String _otpError(AppLocalizations l10n, Failure failure) => switch (failure) {
    AuthFailure(reason: AuthReason.otpInvalid, :final attemptsLeft) => l10n.auth_error_otp_invalid(attemptsLeft ?? 0),
    AuthFailure(reason: AuthReason.otpExpired) => l10n.auth_error_otp_expired,
    AuthFailure(reason: AuthReason.otpLocked, :final retryAfter) => l10n.auth_error_otp_locked(
      retryAfter?.inSeconds ?? 60,
    ),
    AuthFailure(reason: AuthReason.otpRateLimited, :final retryAfter) => l10n.auth_error_rate_limited(
      retryAfter?.inSeconds ?? 60,
    ),
    NetworkFailure() => l10n.auth_error_network,
    _ => l10n.error_internal,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = context.colors;
    final caption = context.text.caption.copyWith(color: c.textSecondary);
    return Column(
      key: const ValueKey<String>('admin-step-up'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_notice != null) ...[
          Text(_notice!, style: context.text.body.copyWith(color: c.warning)),
          const SizedBox(height: 12),
        ],
        switch (_mode) {
          _Mode.pin => SecureContent(
            child: PinField(
              length: staffPinLength,
              semanticLabel: (n, len) => l10n.reg_pin_a11y('$len', n),
              backspaceLabel: l10n.qty_key_backspace_a11y,
              status: _status,
              errorText: _error,
              onCompleted: (pin) => unawaited(_submitPin(pin)),
              footer: _otpAllowed
                  ? AppButton(
                      label: l10n.stepup_tab_sms,
                      variant: AppButtonVariant.text,
                      onPressed: () => setState(() => _mode = _Mode.otpOffer),
                    )
                  : null,
            ),
          ),
          _Mode.otpOffer => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) Text(_error!, style: context.text.body.copyWith(color: c.error)),
              const SizedBox(height: 8),
              AppButton(
                key: const ValueKey<String>('admin-step-up-sms'),
                label: l10n.stepup_send_code,
                loading: _busy,
                onPressed: _otpAllowed ? () => unawaited(_requestOtp()) : null,
              ),
            ],
          ),
          _Mode.otpCode => SecureContent(
            child: OtpField(
              semanticLabel: l10n.auth_otp_code_a11y,
              status: _status,
              errorText: _error,
              onCompleted: (code) => unawaited(_submitOtp(code)),
            ),
          ),
        },
        // «Проверяем…» (03 §9.46, D SS-02) — пока сервер проверяет PIN или код.
        if (_status == CodeFieldStatus.loading && _mode != _Mode.otpOffer) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(l10n.stepup_verifying, key: const ValueKey<String>('admin-step-up-verifying'), style: caption),
          ),
        ],
        const SizedBox(height: 12),
        Text(l10n.stepup_reuse_hint, style: caption),
        const SizedBox(height: 16),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: AppButton(
            label: l10n.ds_button_cancel,
            variant: AppButtonVariant.text,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
      ],
    );
  }
}
