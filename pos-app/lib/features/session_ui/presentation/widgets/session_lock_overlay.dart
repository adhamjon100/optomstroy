// SCR-08 «Разблокировать» в режиме overlay (02 SCR-08.2 «все классы, idle», UI-08-006…017; 09 §8.8, §9.3):
// поверх рабочего экрана (состояние под слоем сохраняется) — заголовок «Экран заблокирован», PIN приложения
// (проверка только на сервере, `POST /auth/unlock`), «Забыли PIN?», «Войти по номеру телефона», «Сменить аккаунт».
// `PIN_INVALID` → «Осталось попыток: {attemptsLeft}» (из ответа; `/auth/refresh` не вызывается);
// `PIN_LOCKED` → нампад недоступен, «Войти по SMS»; сеть — «Нет подключения. Для входа нужна сеть».
// Биометрия (Android/iOS, криптопривязка) — экран SCR-08 фичи auth (RM-D-007/008) через
// `SessionGate.lockScreenBuilder`; этот слой — PIN-вариант по умолчанию.
// compact — полноэкранный лист; medium/expanded — диалог 480 по центру.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/secure_content.dart';
import 'package:optomstroy/core/session/session_api.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/otp_field.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/session_ui/presentation/session_texts.dart';

enum _Confirm { none, resetPin, switchAccount }

class SessionLockOverlay extends StatefulWidget {
  const SessionLockOverlay({
    super.key,
    required this.reason,
    required this.onUnlockWithPin,
    required this.onLeaveToPhoneLogin,
    required this.onSwitchAccount,
    this.pinLength = 6,
    this.idleDuration = const Duration(minutes: 30),
  });

  static const Key overlayKey = Key('scr-08-overlay');
  static const Key phoneLoginKey = Key('scr-08-phone-login');
  static const Key forgotPinKey = Key('scr-08-forgot-pin');
  static const Key switchAccountKey = Key('scr-08-switch-account');
  static const Key smsLoginKey = Key('scr-08-sms-login');
  static const Key confirmKey = Key('scr-08-confirm');

  final SessionLockReason reason;
  final int pinLength;
  final Duration idleDuration;
  final Future<UnlockOutcome> Function(String pin) onUnlockWithPin;
  final void Function(SessionEndReason reason) onLeaveToPhoneLogin;
  final Future<void> Function() onSwitchAccount;

  @override
  State<SessionLockOverlay> createState() => _SessionLockOverlayState();
}

class _SessionLockOverlayState extends State<SessionLockOverlay> {
  CodeFieldStatus _status = CodeFieldStatus.idle;
  String? _error;
  bool _pinLocked = false;
  bool _busy = false;
  _Confirm _confirm = _Confirm.none;

  Future<void> _submit(String pin) async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _status = CodeFieldStatus.loading;
      _error = null;
    });
    final outcome = await widget.onUnlockWithPin(pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      switch (outcome) {
        case UnlockSucceeded():
          _status = CodeFieldStatus.success;
        case UnlockRejected(error: PinInvalidError(:final attemptsLeft)):
          _status = CodeFieldStatus.error;
          _error = attemptsLeft == null ? l10n.error_internal : l10n.auth_pin_error_invalid(attemptsLeft);
        case UnlockRejected(error: PinLockedError()):
          _status = CodeFieldStatus.disabled;
          _pinLocked = true;
          _error = l10n.auth_pin_locked;
        case UnlockRejected(error: NetworkCallError(:final timeout)):
          _status = CodeFieldStatus.error;
          _error = timeout ? l10n.auth_error_timeout : l10n.unlock_offline;
        case UnlockRejected(error: ThrottledError(:final retryAfter)):
          _status = CodeFieldStatus.error;
          _error = l10n.auth_error_rate_limited(retryAfter?.inSeconds ?? 60);
        case UnlockRejected(error: PinNotSetError()):
          // PIN сброшен администратором: без сессии установка невозможна → вход по SMS (SCR-08.4 п.7).
          widget.onLeaveToPhoneLogin(SessionEndReason.pinReset);
        case UnlockRejected():
          _status = CodeFieldStatus.error;
          _error = l10n.error_internal;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final compact = context.windowClass == WindowClass.compact;
    final c = context.colors;
    final body = _body(context);
    return PopScope(
      canPop: false,
      child: compact
          ? Material(
              key: SessionLockOverlay.overlayKey,
              color: c.surface,
              child: SafeArea(
                child: Center(
                  child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: body),
                ),
              ),
            )
          : Center(
              child: Material(
                key: SessionLockOverlay.overlayKey,
                type: MaterialType.transparency,
                child: Container(
                  width: 480,
                  constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height - 48),
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.all(context.radii.xl),
                    boxShadow: context.elevation.e3,
                  ),
                  child: SingleChildScrollView(padding: const EdgeInsets.all(32), child: body),
                ),
              ),
            ),
    );
  }

  Widget _body(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = context.colors;
    final caption = SessionTexts.lockCaption(l10n, widget.reason, idle: widget.idleDuration);
    return FocusScope(
      autofocus: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ExcludeSemantics(
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(color: c.primaryContainer, shape: BoxShape.circle),
              child: Icon(Icons.lock_rounded, size: 32, color: c.primaryText),
            ),
          ),
          const SizedBox(height: 16),
          Semantics(
            header: true,
            child: Text(
              l10n.unlock_locked_title,
              textAlign: TextAlign.center,
              style: context.text.h3.copyWith(color: c.textPrimary),
            ),
          ),
          if (caption != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              caption,
              textAlign: TextAlign.center,
              style: context.text.caption.copyWith(color: c.textSecondary),
            ),
          ],
          const SizedBox(height: 24),
          if (_confirm != _Confirm.none) _confirmBlock(context, l10n) else ..._pinBlock(context, l10n),
        ],
      ),
    );
  }

  List<Widget> _pinBlock(BuildContext context, AppLocalizations l10n) {
    final c = context.colors;
    if (_pinLocked) {
      return <Widget>[
        Semantics(
          liveRegion: true,
          child: Text(
            _error ?? l10n.auth_pin_locked,
            textAlign: TextAlign.center,
            style: context.text.body.copyWith(color: c.error),
          ),
        ),
        const SizedBox(height: 16),
        AppButton(
          key: SessionLockOverlay.smsLoginKey,
          label: l10n.unlock_sms_login,
          expand: true,
          onPressed: () => widget.onLeaveToPhoneLogin(SessionEndReason.pinLocked),
        ),
      ];
    }
    return <Widget>[
      Text(
        l10n.unlock_pin_hint,
        textAlign: TextAlign.center,
        style: context.text.body.copyWith(color: c.textSecondary),
      ),
      const SizedBox(height: 16),
      SecureContent(
        child: PinField(
          length: widget.pinLength,
          status: _status,
          errorText: _error,
          semanticLabel: (int entered, int length) => l10n.reg_pin_a11y('$length', entered),
          backspaceLabel: l10n.qty_key_backspace_a11y,
          onCompleted: (pin) => unawaited(_submit(pin)),
        ),
      ),
      const SizedBox(height: 16),
      AppButton(
        key: SessionLockOverlay.forgotPinKey,
        label: l10n.unlock_forgot_pin,
        variant: AppButtonVariant.text,
        size: AppButtonSize.s,
        onPressed: _busy ? null : () => setState(() => _confirm = _Confirm.resetPin),
      ),
      AppButton(
        key: SessionLockOverlay.phoneLoginKey,
        label: l10n.unlock_phone_login,
        variant: AppButtonVariant.text,
        size: AppButtonSize.s,
        onPressed: _busy ? null : () => widget.onLeaveToPhoneLogin(SessionEndReason.phoneLogin),
      ),
      AppButton(
        key: SessionLockOverlay.switchAccountKey,
        label: l10n.unlock_switch_account,
        variant: AppButtonVariant.text,
        size: AppButtonSize.s,
        onPressed: _busy ? null : () => setState(() => _confirm = _Confirm.switchAccount),
      ),
    ];
  }

  /// «Забыли PIN?» / «Сменить аккаунт» — подтверждение внутри слоя (слой выше навигатора, без отдельного маршрута).
  Widget _confirmBlock(BuildContext context, AppLocalizations l10n) {
    final c = context.colors;
    final reset = _confirm == _Confirm.resetPin;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          reset ? l10n.unlock_reset_title : l10n.unlock_switch_title,
          style: context.text.title.copyWith(color: c.textPrimary),
        ),
        const SizedBox(height: 8),
        Text(
          reset ? l10n.unlock_reset_body : l10n.unlock_switch_body,
          style: context.text.body.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: 24),
        AppButton(
          key: SessionLockOverlay.confirmKey,
          label: reset ? l10n.unlock_reset_confirm : l10n.unlock_switch_confirm,
          variant: reset ? AppButtonVariant.primary : AppButtonVariant.danger,
          loading: _busy,
          expand: true,
          onPressed: _busy
              ? null
              : () async {
                  if (reset) {
                    widget.onLeaveToPhoneLogin(SessionEndReason.pinReset);
                    return;
                  }
                  setState(() => _busy = true);
                  await widget.onSwitchAccount();
                  if (mounted) setState(() => _busy = false);
                },
        ),
        const SizedBox(height: 8),
        AppButton(
          label: l10n.ds_button_cancel,
          variant: AppButtonVariant.text,
          expand: true,
          onPressed: _busy ? null : () => setState(() => _confirm = _Confirm.none),
        ),
      ],
    );
  }
}
