// Секция «Защита входа» SCR-42 (02 SCR-42.2, SCR-42.4, SCR-42.8; UI-42-009/010/023/024/026; D-13, D-48).
//
// «Сменить PIN»: step-up `profile.pin.set` (текущим PIN или кодом из SMS — StepUpDialog core/session) →
// лист «Новый PIN» → «Повторите PIN» → `POST /me/pin` с токеном области. «Забыли PIN?» — тот же путь
// со step-up только кодом из SMS. Биометрия — согласие → системный диалог → токен под ключом устройства;
// Windows — Windows Hello только перед PIN. PIN в состоянии виджетов не хранится дольше листа.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/secure_content.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_checkbox.dart';
import 'package:optomstroy/design_system/components/app_dropdown.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/app_switch.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/otp_field.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';
import 'package:optomstroy/features/settings/domain/usecases/settings_pin_policy.dart';
import 'package:optomstroy/features/settings/presentation/notifiers/settings_controllers.dart';
import 'package:optomstroy/features/settings/presentation/settings_texts.dart';
import 'package:optomstroy/features/settings/settings_providers.dart';

/// Ключи для тестов.
abstract final class SecuritySectionKeys {
  static const Key loading = ValueKey<String>('settings-security-loading');
  static const Key error = ValueKey<String>('settings-security-error');
  static const Key stale = ValueKey<String>('settings-security-stale');
  static const Key pinStatus = ValueKey<String>('settings-pin-status');
  static const Key changePin = ValueKey<String>('settings-pin-change');
  static const Key forgotPin = ValueKey<String>('settings-pin-forgot');
  static const Key biometrics = ValueKey<String>('settings-bio-switch');
  static const Key requirePin = ValueKey<String>('settings-require-pin');
  static const Key idleLock = ValueKey<String>('settings-idle-lock');
  static const Key pinSheet = ValueKey<String>('settings-pin-sheet');
  static const Key consentCheck = ValueKey<String>('settings-bio-consent-check');
  static const Key consentEnable = ValueKey<String>('settings-bio-consent-enable');
  static const Key offlineHint = ValueKey<String>('settings-security-offline');
}

class SecuritySection extends ConsumerWidget {
  const SecuritySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final SecurityViewState s = ref.watch(securityControllerProvider);
    final bool online = ref.watch(settingsOnlineProvider);
    final SettingsViewer viewer = ref.watch(settingsViewerProvider);
    final SecurityController controller = ref.read(securityControllerProvider.notifier);
    final LoginProtectionState? data = s.data;

    if (data == null) {
      if (s.loading) {
        return Column(
          key: SecuritySectionKeys.loading,
          children: <Widget>[
            for (int i = 0; i < 3; i++)
              Padding(
                padding: EdgeInsets.symmetric(vertical: context.space.s1),
                child: const SkeletonBox(height: 56),
              ),
          ],
        );
      }
      return ErrorState.inline(
        key: SecuritySectionKeys.error,
        message: SettingsTexts.failure(l10n, s.failure ?? const UnknownFailure()),
        onRetry: () => unawaited(controller.refresh()),
      );
    }

    final bool staff = viewer.isStaff && data.isStaff;
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final TextStyle caption = context.text.caption.copyWith(color: context.colors.textSecondary);

    // Биометрия (UI-42-010): недоступна — disabled; customer без PIN не может выключить единственный способ.
    final bool bioAvailable =
        data.support == BiometricSupport.cryptoLogin || data.support == BiometricSupport.windowsHelloGate;
    final bool bioLastMethod = !staff && data.biometricsEnabled && !data.pinSet;
    final String? bioDescription = switch (data.support) {
      BiometricSupport.windowsHelloGate => l10n.settings_bio_windows_note,
      BiometricSupport.notEnrolled || BiometricSupport.unavailable => l10n.settings_bio_unavailable,
      BiometricSupport.cryptoLogin => bioLastMethod ? l10n.settings_protection_last_method : null,
    };

    // «Требовать PIN при запуске» (UI-42-024): staff — всегда вкл. и неактивен (D-48);
    // customer — выключить можно только при включённой биометрии (09 REG-038).
    final bool pinLastMethod = !staff && data.pinSet && !data.biometricsEnabled;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (data.settingsAsOf != null)
          Padding(
            padding: EdgeInsets.only(bottom: context.space.s3),
            child: Text(
              l10n.settings_stale_caption(SettingsTexts.dateTime(data.settingsAsOf!, locale)),
              key: SecuritySectionKeys.stale,
              style: context.text.caption.copyWith(color: context.colors.warning),
            ),
          ),
        if (data.pinSet)
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  l10n.settings_pin_status_set,
                  key: SecuritySectionKeys.pinStatus,
                  style: context.text.body.copyWith(color: context.colors.textPrimary),
                ),
              ),
              AppButton(
                key: SecuritySectionKeys.changePin,
                label: l10n.settings_pin_change,
                size: AppButtonSize.s,
                variant: AppButtonVariant.outlined,
                onPressed: online ? () => unawaited(_changePin(context, ref, data, otpOnly: false)) : null,
              ),
            ],
          ),
        SizedBox(height: context.space.s4),
        AppSwitch(
          key: SecuritySectionKeys.biometrics,
          value: data.biometricsEnabled,
          label: SettingsTexts.biometricLabel(l10n, data.platformLabel),
          description: bioDescription,
          loading: s.bioBusy,
          onChanged: !online || !bioAvailable || (data.biometricsEnabled && bioLastMethod)
              ? null
              : (bool on) => unawaited(_toggleBiometrics(context, ref, data, on)),
        ),
        SizedBox(height: context.space.s2),
        AppSwitch(
          key: SecuritySectionKeys.requirePin,
          value: staff || data.pinSet,
          label: l10n.settings_require_pin_label,
          description: staff
              ? l10n.settings_pin_required_staff
              : (pinLastMethod ? l10n.settings_protection_last_method : null),
          onChanged: staff || !online || pinLastMethod
              ? null
              : (bool on) => unawaited(on ? _changePin(context, ref, data, otpOnly: false) : _removePin(context, ref)),
        ),
        if (staff) ...<Widget>[
          SizedBox(height: context.space.s4),
          SizedBox(
            width: 320,
            child: AppDropdown<int>(
              key: SecuritySectionKeys.idleLock,
              label: l10n.settings_autolock_label,
              items: <AppDropdownItem<int>>[
                for (final int m in IdleLockOptions.minutes)
                  AppDropdownItem<int>(value: m, label: l10n.settings_autolock_value(m)),
              ],
              value: data.idleLockMinutes ?? IdleLockOptions.defaultMinutes,
              onChanged: online && !s.idleBusy ? (int m) => unawaited(_setIdle(context, ref, m)) : null,
            ),
          ),
        ],
        SizedBox(height: context.space.s3),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: AppButton(
            key: SecuritySectionKeys.forgotPin,
            label: l10n.settings_pin_forgot,
            variant: AppButtonVariant.text,
            size: AppButtonSize.s,
            onPressed: online ? () => unawaited(_changePin(context, ref, data, otpOnly: true)) : null,
          ),
        ),
        if (!online) Text(l10n.settings_offline_disabled, key: SecuritySectionKeys.offlineHint, style: caption),
      ],
    );
  }

  Future<void> _changePin(
    BuildContext context,
    WidgetRef ref,
    LoginProtectionState data, {
    required bool otpOnly,
  }) async {
    final SecurityController controller = ref.read(securityControllerProvider.notifier);
    if (!await controller.stepUpForPin(otpOnly: otpOnly) || !context.mounted) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool? changed = await AppBottomSheet.show<bool>(
      context,
      title: l10n.settings_pin_new_title,
      body: PinChangeSheet(
        key: SecuritySectionKeys.pinSheet,
        length: data.pinLength,
        birthYear: data.birthYear,
        onSubmit: controller.changePin,
      ),
    );
    if (changed == true && context.mounted) {
      AppSnackbar.show(context, message: l10n.settings_pin_changed, variant: AppSnackbarVariant.success);
    }
  }

  Future<void> _removePin(BuildContext context, WidgetRef ref) async {
    final Result<void> res = await ref.read(securityControllerProvider.notifier).removePin();
    if (!context.mounted) return;
    if (res case FailureResult<void>(:final failure)) _showFailure(context, failure);
  }

  Future<void> _setIdle(BuildContext context, WidgetRef ref, int minutes) async {
    final Failure? failure = await ref.read(securityControllerProvider.notifier).setIdleLock(minutes);
    if (failure != null && context.mounted) _showFailure(context, failure);
  }

  Future<void> _toggleBiometrics(BuildContext context, WidgetRef ref, LoginProtectionState data, bool on) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    if (on && data.support == BiometricSupport.cryptoLogin) {
      if (!await _consent(context) || !context.mounted) return;
    }
    if (!on) {
      final bool ok = await ConfirmDialog.show(
        context,
        title: SettingsTexts.biometricLabel(l10n, data.platformLabel),
        message: l10n.settings_bio_disable_confirm,
        confirmLabel: l10n.ds_button_ok,
        cancelLabel: l10n.ds_button_cancel,
      );
      if (!ok || !context.mounted) return;
    }
    final BiometricPromptCopy prompt = BiometricPromptCopy(
      title: SettingsTexts.biometricLabel(l10n, data.platformLabel),
      cancel: l10n.ds_button_cancel,
    );
    final SecurityController controller = ref.read(securityControllerProvider.notifier);
    BiometricToggleOutcome? outcome = await controller.setBiometrics(on, prompt);
    if (outcome == BiometricToggleOutcome.consentRequired && context.mounted && await _consent(context)) {
      outcome = await controller.setBiometrics(on, prompt);
    }
    if (!context.mounted || outcome == null) return;
    switch (outcome) {
      case BiometricToggleOutcome.enabled:
        AppSnackbar.show(context, message: l10n.settings_bio_enabled, variant: AppSnackbarVariant.success);
      case BiometricToggleOutcome.cancelled:
        AppSnackbar.show(context, message: l10n.settings_bio_cancelled, variant: AppSnackbarVariant.info);
      case BiometricToggleOutcome.offline:
        AppSnackbar.show(context, message: l10n.settings_offline_disabled, variant: AppSnackbarVariant.info);
      case BiometricToggleOutcome.failed || BiometricToggleOutcome.consentRequired:
        AppSnackbar.show(context, message: l10n.settings_save_error, variant: AppSnackbarVariant.error);
      case BiometricToggleOutcome.disabled || BiometricToggleOutcome.stepUpCancelled:
        break;
    }
  }

  /// Лист согласия `biometrics_device` (текст согласия — Q-027).
  Future<bool> _consent(BuildContext context) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool? ok = await AppBottomSheet.show<bool>(
      context,
      title: l10n.settings_bio_consent_title,
      body: const _ConsentBody(),
    );
    return ok ?? false;
  }

  static void _showFailure(BuildContext context, Failure failure) {
    if (failure is AuthFailure && failure.reason == AuthReason.stepUpRequired) return;
    AppSnackbar.show(
      context,
      message: SettingsTexts.failure(AppLocalizations.of(context), failure),
      variant: AppSnackbarVariant.error,
    );
  }
}

class _ConsentBody extends StatefulWidget {
  const _ConsentBody();

  @override
  State<_ConsentBody> createState() => _ConsentBodyState();
}

class _ConsentBodyState extends State<_ConsentBody> {
  bool _agreed = false;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppCheckbox(
          key: SecuritySectionKeys.consentCheck,
          value: _agreed,
          label: l10n.settings_bio_consent_check,
          onChanged: (bool? v) => setState(() => _agreed = v ?? false),
        ),
        SizedBox(height: context.space.s4),
        AppButton(
          key: SecuritySectionKeys.consentEnable,
          label: l10n.settings_bio_enable,
          expand: true,
          onPressed: _agreed ? () => Navigator.of(context).pop(true) : null,
        ),
      ],
    );
  }
}

/// Лист «Новый PIN» → «Повторите PIN» (UI-42-009). [onSubmit] — `POST /me/pin`; успех закрывает лист с `true`.
class PinChangeSheet extends StatefulWidget {
  const PinChangeSheet({super.key, required this.length, required this.onSubmit, this.birthYear});

  final int length;
  final int? birthYear;
  final Future<Result<void>> Function(String newPin) onSubmit;

  @override
  State<PinChangeSheet> createState() => _PinChangeSheetState();
}

class _PinChangeSheetState extends State<PinChangeSheet> {
  String? _first;
  String? _error;
  bool _busy = false;

  /// Поле пересоздаётся на каждом шаге (новый ввод).
  int _attempt = 0;

  Future<void> _onCompleted(String pin) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String? first = _first;
    if (first == null) {
      final NewPinIssue? issue = SettingsPinPolicy.check(pin, length: widget.length, birthYear: widget.birthYear);
      setState(() {
        _attempt++;
        if (issue == null) {
          _first = pin;
          _error = null;
        } else {
          _error = l10n.settings_pin_error_weak;
        }
      });
      return;
    }
    if (SettingsPinPolicy.confirm(first, pin) != null) {
      setState(() {
        _attempt++;
        _error = l10n.settings_pin_error_mismatch;
      });
      return;
    }
    setState(() => _busy = true);
    final Result<void> res = await widget.onSubmit(pin);
    if (!mounted) return;
    switch (res) {
      case Success<void>():
        Navigator.of(context).pop(true);
      case FailureResult<void>(:final failure):
        setState(() {
          _busy = false;
          _attempt++;
          _first = null;
          _error = failure is ValidationFailure ? l10n.settings_pin_error_weak : SettingsTexts.failure(l10n, failure);
        });
    }
  }

  Future<void> _onPop(bool didPop, Object? result) async {
    if (didPop) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool abort = await ConfirmDialog.show(
      context,
      title: l10n.settings_pin_abort_confirm,
      message: l10n.settings_pin_abort_confirm,
      confirmLabel: l10n.ds_button_ok,
      cancelLabel: l10n.ds_button_cancel,
    );
    if (abort && mounted) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool repeat = _first != null;
    return PopScope<Object?>(
      canPop: _first == null && !_busy,
      onPopInvokedWithResult: (bool didPop, Object? result) => unawaited(_onPop(didPop, result)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            repeat ? l10n.settings_pin_repeat_title : l10n.settings_pin_new_title,
            textAlign: TextAlign.center,
            style: context.text.h3.copyWith(color: context.colors.textPrimary),
          ),
          SizedBox(height: context.space.s4),
          SecureContent(
            child: PinField(
              key: ValueKey<String>('settings-pin-field-$_attempt'),
              length: widget.length,
              semanticLabel: (int n, int len) => l10n.reg_pin_a11y('$len', n),
              backspaceLabel: l10n.qty_key_backspace_a11y,
              status: _busy ? CodeFieldStatus.loading : (_error != null ? CodeFieldStatus.error : CodeFieldStatus.idle),
              errorText: _error,
              onCompleted: (String pin) => unawaited(_onCompleted(pin)),
            ),
          ),
        ],
      ),
    );
  }
}
