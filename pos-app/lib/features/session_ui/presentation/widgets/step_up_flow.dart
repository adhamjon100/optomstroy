// Поток step-up поверх StepUpDialog (08 §2.12, §4.1.7; 09 §8.8, §9.6; 02 SCR-90 зона B):
// PIN → `POST /auth/step-up {method: pin}`; «Код из SMS» → шаг 1 (202, challengeId) → шаг 2 (200).
// `PIN_INVALID` → «Осталось попыток: {attemptsLeft}» (число только из ответа); `PIN_LOCKED` / `pin_not_set` →
// переход на «Код из SMS»; таймаут/сеть — сообщение, PIN не хранится (повтор — вводом заново).
// Результат — [StepUpGrant] или `null` («Отмена» возвращает операцию в исходное состояние).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_api.dart';
import 'package:optomstroy/core/session/step_up_token_cache.dart';
import 'package:optomstroy/design_system/components/otp_field.dart';
import 'package:optomstroy/features/session_ui/presentation/widgets/step_up_dialog.dart';

/// Вызовы `POST /auth/step-up` (SessionController).
abstract interface class StepUpActions {
  Future<StepUpResponse> submitPin(String pin);
  Future<StepUpResponse> requestOtp();
  Future<StepUpResponse> submitOtp(String challengeId, String code);
}

class StepUpFlow extends StatefulWidget {
  const StepUpFlow({
    super.key,
    required this.actions,
    required this.onDone,
    this.allowedMethods = const <String>['pin', 'otp'],
    this.pinLength = 6,
    this.description,
  });

  final StepUpActions actions;

  /// `stepUp.allowedMethods` (`pin`, `otp`; прочие значения в R1 игнорируются).
  final List<String> allowedMethods;
  final int pinLength;
  final String? description;

  /// Итог: токен или `null` (отмена).
  final ValueChanged<StepUpGrant?> onDone;

  @override
  State<StepUpFlow> createState() => _StepUpFlowState();
}

class _StepUpFlowState extends State<StepUpFlow> {
  late StepUpDialogData _data;
  String? _challengeId;
  Timer? _resendTimer;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    final methods = <StepUpMethod>{
      if (widget.allowedMethods.contains('pin')) StepUpMethod.pin,
      if (widget.allowedMethods.contains('otp')) StepUpMethod.otp,
    };
    final effective = methods.isEmpty ? const <StepUpMethod>{StepUpMethod.pin, StepUpMethod.otp} : methods;
    _data = StepUpDialogData(
      method: effective.contains(StepUpMethod.pin) ? StepUpMethod.pin : StepUpMethod.otp,
      methods: effective,
    );
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    super.dispose();
  }

  void _set(StepUpDialogData data) {
    if (mounted) setState(() => _data = data);
  }

  void _finish(StepUpGrant? grant) {
    if (_done) return;
    _done = true;
    _resendTimer?.cancel();
    widget.onDone(grant);
  }

  Future<void> _submitPin(String pin) async {
    final l10n = AppLocalizations.of(context);
    _set(_data.copyWith(pinStatus: CodeFieldStatus.loading, clearPinError: true, clearMessage: true));
    final response = await widget.actions.submitPin(pin);
    if (!mounted) return;
    switch (response) {
      case StepUpGranted(:final grant):
        _set(_data.copyWith(pinStatus: CodeFieldStatus.success));
        _finish(grant);
      case StepUpFailed(error: PinInvalidError(:final attemptsLeft)):
        _set(
          _data.copyWith(
            pinStatus: CodeFieldStatus.error,
            pinError: attemptsLeft == null ? l10n.error_internal : l10n.auth_pin_error_invalid(attemptsLeft),
          ),
        );
      case StepUpFailed(error: PinLockedError()):
        _pinUnavailable(l10n.stepup_pin_locked);
      case StepUpFailed(error: PinNotSetError()):
        _pinUnavailable(l10n.stepup_pin_not_set);
      case StepUpFailed(:final error):
        _set(_data.copyWith(pinStatus: CodeFieldStatus.idle, message: _message(l10n, error)));
      case StepUpOtpSent():
        _set(_data.copyWith(pinStatus: CodeFieldStatus.idle, message: l10n.error_internal));
    }
  }

  /// PIN заблокирован / не задан → «Код из SMS» (03 §9.46: после `PIN_LOCKED` — fallback на SMS).
  void _pinUnavailable(String notice) {
    _set(
      _data.copyWith(
        methods: <StepUpMethod>{..._data.methods, StepUpMethod.otp},
        pinStatus: CodeFieldStatus.disabled,
        pinNotice: notice,
        method: StepUpMethod.otp,
        message: notice,
      ),
    );
  }

  Future<void> _requestOtp() async {
    final l10n = AppLocalizations.of(context);
    _set(_data.copyWith(otpSending: true, clearMessage: true, clearOtpError: true));
    final response = await widget.actions.requestOtp();
    if (!mounted) return;
    switch (response) {
      case StepUpOtpSent(:final challengeId, :final resendAfter):
        _challengeId = challengeId;
        _set(_data.copyWith(otpSent: true, otpSending: false, otpStatus: CodeFieldStatus.idle, resendIn: resendAfter));
        _startResendCountdown(resendAfter);
      case StepUpFailed(:final error):
        _set(_data.copyWith(otpSending: false, message: _message(l10n, error)));
      case StepUpGranted(:final grant):
        _finish(grant);
    }
  }

  void _startResendCountdown(Duration wait) {
    _resendTimer?.cancel();
    var left = wait;
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      left -= const Duration(seconds: 1);
      if (left <= Duration.zero) {
        timer.cancel();
        left = Duration.zero;
      }
      _set(_data.copyWith(resendIn: left));
    });
  }

  Future<void> _submitOtp(String code) async {
    final challengeId = _challengeId;
    if (challengeId == null) return;
    final l10n = AppLocalizations.of(context);
    _set(_data.copyWith(otpStatus: CodeFieldStatus.loading, clearOtpError: true, clearMessage: true));
    final response = await widget.actions.submitOtp(challengeId, code);
    if (!mounted) return;
    switch (response) {
      case StepUpGranted(:final grant):
        _set(_data.copyWith(otpStatus: CodeFieldStatus.success));
        _finish(grant);
      case StepUpFailed(error: OtpInvalidError(:final attemptsLeft)):
        _set(
          _data.copyWith(
            otpStatus: CodeFieldStatus.error,
            otpError: attemptsLeft == null ? l10n.error_internal : l10n.auth_error_otp_invalid(attemptsLeft),
          ),
        );
      case StepUpFailed(error: OtpExpiredError()):
        _set(_data.copyWith(otpStatus: CodeFieldStatus.error, otpError: l10n.auth_error_otp_expired));
      case StepUpFailed(:final error):
        _set(_data.copyWith(otpStatus: CodeFieldStatus.idle, message: _message(l10n, error)));
      case StepUpOtpSent():
        break;
    }
  }

  static String _message(AppLocalizations l10n, SessionCallError error) => switch (error) {
    NetworkCallError(timeout: true) => l10n.auth_error_timeout,
    NetworkCallError() => l10n.stepup_offline,
    ThrottledError(code: 'OTP_LOCKED', :final retryAfter) => l10n.auth_error_otp_locked(retryAfter?.inSeconds ?? 60),
    ThrottledError(:final retryAfter) => l10n.auth_error_rate_limited(retryAfter?.inSeconds ?? 60),
    PinLockedError() => l10n.stepup_pin_locked,
    PinNotSetError() => l10n.stepup_pin_not_set,
    _ => l10n.error_internal,
  };

  @override
  Widget build(BuildContext context) => StepUpDialog(
    data: _data,
    pinLength: widget.pinLength,
    description: widget.description,
    onMethodChanged: (m) => _set(_data.copyWith(method: m, clearMessage: true)),
    onSubmitPin: (pin) => unawaited(_submitPin(pin)),
    onRequestOtp: () => unawaited(_requestOtp()),
    onSubmitOtp: (code) => unawaited(_submitOtp(code)),
    onCancel: () => _finish(null),
  );
}
