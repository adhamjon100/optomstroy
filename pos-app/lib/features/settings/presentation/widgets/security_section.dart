// Секция «Защита входа» SCR-42 (02 SCR-42.2, SCR-42.4, SCR-42.8; UI-42-009/010/023/024/026; D-13, D-48).
//
// «Сменить PIN»: step-up `profile.pin.set` (текущим PIN или кодом из SMS — StepUpDialog core/session) →
// лист «Новый PIN» → «Повторите PIN» → `POST /me/pin` с токеном области. «Забыли PIN?» — тот же путь
// со step-up только кодом из SMS. Биометрия — согласие → системный диалог → токен под ключом устройства;
// Windows — ключ Windows Hello (W2, вход без PIN: согласие → диалог Windows Hello → сервер; 15 ADR-116 п. 3) или
// Windows Hello только перед PIN (W1); причина недоступности Windows Hello — UI-42-029 цветом `warning`. PIN в
// состоянии виджетов не хранится дольше листа.
// Android, уровень W «лицо или отпечаток» (15 ADR-116 п. 2; 02 SCR-42.4 «UI-42-010 Android, уровень W»): при обоих
// уровнях до включения — «Способ входа» UI-42-027 (по умолчанию «Только отпечаток (надёжнее)», Q-354; вариант W без PIN
// неактивен); пояснение UI-42-028 (уровень W, без PIN, подсказка перехода на S); при живом уровне W PIN не удаляется
// (UI-42-024 `settings_pin_delete_weak_active`).
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
import 'package:optomstroy/design_system/components/option_tile.dart';
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

  /// Причина недоступности Windows Hello (UI-42-029).
  static const Key helloIssue = ValueKey<String>('settings-hello-issue');

  /// «Способ входа» UI-42-027 (Android): группа и варианты.
  static const Key bioMode = ValueKey<String>('settings-bio-mode');
  static const Key bioModeStrong = ValueKey<String>('settings-bio-mode-strong');
  static const Key bioModeWeak = ValueKey<String>('settings-bio-mode-weak');

  /// Пояснение уровня W UI-42-028 (`settings_bio_weak_note` / `_weak_needs_pin` / `_upgrade_hint`).
  static const Key bioWeakNote = ValueKey<String>('settings-bio-weak-note');
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
    // Ключ Windows Hello (W2) включается только при заданном PIN (09 BIO-038; UI-42-029 keyNeedsPin).
    final bool helloKeyMode = data.support == BiometricSupport.windowsHelloKey;
    final bool keyNeedsPin = helloKeyMode && !data.pinSet && !data.biometricsEnabled;
    // Уровень W (Android; 09 BIO-030): включается только при заданном PIN — без PIN вариант W неактивен (UI-42-027) или,
    // если других уровней нет, тумблер неактивен с пояснением `settings_bio_weak_needs_pin` (UI-42-028).
    final bool weakOnly = data.support == BiometricSupport.weakLogin;
    final bool bothTiers = data.support == BiometricSupport.strongOrWeak;
    final bool weakNeedsPin = !data.pinSet && !data.biometricsEnabled;
    final BiometricLoginTier tier = s.tierToEnable;
    final bool bioAvailable =
        data.support == BiometricSupport.cryptoLogin ||
        data.support == BiometricSupport.windowsHelloGate ||
        (helloKeyMode && !keyNeedsPin) ||
        (weakOnly && !weakNeedsPin) ||
        (bothTiers && !(tier == BiometricLoginTier.weak && weakNeedsPin)) ||
        // Включённый уровень W выключается всегда, даже если сервер или устройство его больше не допускают.
        data.weakEnabled;
    final bool bioLastMethod = !staff && data.biometricsEnabled && !data.pinSet;
    final WindowsHelloIssue? helloIssue = data.helloIssue;
    final String? bioDescription = switch (data.support) {
      BiometricSupport.windowsHelloKey =>
        keyNeedsPin ? l10n.settings_bio_windows_key_needs_pin : l10n.settings_bio_windows_key_note,
      BiometricSupport.windowsHelloGate => l10n.settings_bio_windows_note,
      // Причина Windows Hello — отдельной строкой `warning` под тумблером (UI-42-029).
      BiometricSupport.notEnrolled ||
      BiometricSupport.unavailable => helloIssue == null && !data.weakEnabled ? l10n.settings_bio_unavailable : null,
      // Пояснение уровня W — отдельной строкой UI-42-028 под выбором или тумблером.
      BiometricSupport.cryptoLogin ||
      BiometricSupport.weakLogin ||
      BiometricSupport.strongOrWeak => bioLastMethod ? l10n.settings_protection_last_method : null,
    };
    // UI-42-028: включён W и устройство теперь даёт S — подсказка перехода; иначе для уровня W (включённого, выбранного
    // или единственного) — пояснение или «сначала задайте PIN».
    final String? weakNote = data.weakEnabled
        ? (data.upgradeAvailable ? l10n.settings_bio_upgrade_hint : l10n.settings_bio_weak_note)
        : (weakOnly || (bothTiers && tier == BiometricLoginTier.weak))
        ? (weakNeedsPin ? l10n.settings_bio_weak_needs_pin : l10n.settings_bio_weak_note)
        : null;

    // «Требовать PIN при запуске» (UI-42-024): staff — всегда вкл. и неактивен (D-48);
    // customer — выключить можно только при включённой биометрии (09 REG-038); при живом ключе Windows Hello или уровне
    // W — нельзя (без PIN они не работают; `400 hello_key_active` / `weak_biometrics_active`, 09 BIO-040, BIO-031).
    final bool pinLastMethod = !staff && data.pinSet && !data.biometricsEnabled;
    final bool helloKeyHoldsPin = !staff && data.pinSet && helloKeyMode && data.biometricsEnabled;
    final bool weakHoldsPin = !staff && data.pinSet && data.weakEnabled;

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
          label: SettingsTexts.biometricSwitchLabel(l10n, data),
          description: bioDescription,
          loading: s.bioBusy,
          onChanged: !online || !bioAvailable || (data.biometricsEnabled && bioLastMethod)
              ? null
              : (bool on) => unawaited(_toggleBiometrics(context, ref, data, on)),
        ),
        if (helloIssue != null)
          Text(
            SettingsTexts.helloIssue(l10n, helloIssue),
            key: SecuritySectionKeys.helloIssue,
            style: context.text.caption.copyWith(color: context.colors.warning),
          ),
        // UI-42-027 «Способ входа»: оба уровня, биометрия выключена (смена способа — выключением и новым включением).
        if (bothTiers && !data.biometricsEnabled)
          _BioModeGroup(
            key: SecuritySectionKeys.bioMode,
            selected: s.chosenTier,
            weakEnabled: data.pinSet,
            onChanged: online && !s.bioBusy ? controller.chooseTier : null,
          ),
        if (weakNote != null) _BioWeakNote(key: SecuritySectionKeys.bioWeakNote, text: weakNote),
        SizedBox(height: context.space.s2),
        AppSwitch(
          key: SecuritySectionKeys.requirePin,
          value: staff || data.pinSet,
          label: l10n.settings_require_pin_label,
          description: staff
              ? l10n.settings_pin_required_staff
              : (pinLastMethod
                    ? l10n.settings_protection_last_method
                    : (helloKeyHoldsPin
                          ? l10n.settings_pin_delete_hello_key_active
                          : (weakHoldsPin ? l10n.settings_pin_delete_weak_active : null))),
          onChanged: staff || !online || pinLastMethod || helloKeyHoldsPin || weakHoldsPin
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
    // Согласие `biometrics_device` — для уровней S и W и ключа Windows Hello (на сервере хранится открытый ключ); гейту
    // W1 не нужно (09 §9.5 п. 2).
    final bool consentNeeded = switch (data.support) {
      BiometricSupport.cryptoLogin ||
      BiometricSupport.weakLogin ||
      BiometricSupport.strongOrWeak ||
      BiometricSupport.windowsHelloKey => true,
      BiometricSupport.windowsHelloGate || BiometricSupport.notEnrolled || BiometricSupport.unavailable => false,
    };
    if (on && consentNeeded) {
      if (!await _consent(context) || !context.mounted) return;
    }
    final SecurityController controller = ref.read(securityControllerProvider.notifier);
    // Уровень W: заголовок диалога `local_auth` — «Вход по лицу или отпечатку» (`auth_bio_prompt_face`; 02 SCR-42.4).
    final bool weak = on && ref.read(securityControllerProvider).tierToEnable == BiometricLoginTier.weak;
    if (!on) {
      final bool ok = await ConfirmDialog.show(
        context,
        title: SettingsTexts.biometricSwitchLabel(l10n, data),
        message: l10n.settings_bio_disable_confirm,
        confirmLabel: l10n.ds_button_ok,
        cancelLabel: l10n.ds_button_cancel,
      );
      if (!ok || !context.mounted) return;
    }
    final BiometricPromptCopy prompt = BiometricPromptCopy(
      title: weak ? l10n.auth_bio_prompt_face : SettingsTexts.biometricSwitchLabel(l10n, data),
      cancel: l10n.ds_button_cancel,
    );
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
      case BiometricToggleOutcome.helloKeyDisabled || BiometricToggleOutcome.helloKeySharedDevice:
        // Сервер ключ не разрешил: созданный ключ удалён; `GET /me` — секция в режиме гейта (AC-UI-42-022).
        AppSnackbar.show(
          context,
          message: outcome == BiometricToggleOutcome.helloKeyDisabled
              ? l10n.settings_hello_key_disabled
              : l10n.settings_hello_key_shared_device,
          variant: AppSnackbarVariant.info,
        );
        unawaited(controller.refresh());
      case BiometricToggleOutcome.helloKeyNoPrf:
        // Веб-демо, браузер на Windows без PRF (BIO-041): включён гейт перед PIN; секция — в режиме гейта.
        AppSnackbar.show(context, message: l10n.settings_hello_key_no_prf, variant: AppSnackbarVariant.info);
        unawaited(controller.refresh());
      case BiometricToggleOutcome.weakDisabled:
        // Сервер не разрешает уровень W: тумблер «выкл», `GET /me` перечитывается — выбор UI-42-027 скрывается.
        unawaited(controller.refresh());
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

/// «Способ входа» UI-42-027 (02 SCR-42.3; 03 §9.33 `OptionTile` с радио): «Только отпечаток (надёжнее)» — уровень S,
/// «Лицо или отпечаток (проще, защита ниже)» — уровень W; без PIN вариант W неактивен с причиной
/// `settings_bio_weak_needs_pin`.
class _BioModeGroup extends StatelessWidget {
  const _BioModeGroup({super.key, required this.selected, required this.weakEnabled, required this.onChanged});

  final BiometricLoginTier selected;

  /// Вариант W доступен (PIN задан).
  final bool weakEnabled;

  /// `null` — нет сети или идёт включение.
  final ValueChanged<BiometricLoginTier>? onChanged;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ValueChanged<BiometricLoginTier>? choose = onChanged;
    return Padding(
      padding: EdgeInsets.only(top: context.space.s3),
      child: Semantics(
        container: true,
        label: l10n.settings_bio_mode_title,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(l10n.settings_bio_mode_title, style: context.text.label.copyWith(color: context.colors.textPrimary)),
            SizedBox(height: context.space.s2),
            OptionTile(
              key: SecuritySectionKeys.bioModeStrong,
              title: l10n.settings_bio_mode_strong,
              icon: Icons.fingerprint_rounded,
              selected: selected == BiometricLoginTier.strong,
              onTap: choose == null ? null : () => choose(BiometricLoginTier.strong),
            ),
            SizedBox(height: context.space.s2),
            OptionTile(
              key: SecuritySectionKeys.bioModeWeak,
              title: l10n.settings_bio_mode_weak,
              icon: Icons.face_unlock_outlined,
              selected: selected == BiometricLoginTier.weak,
              disabledReason: weakEnabled ? null : l10n.settings_bio_weak_needs_pin,
              onTap: choose == null || !weakEnabled ? null : () => choose(BiometricLoginTier.weak),
            ),
          ],
        ),
      ),
    );
  }
}

/// Пояснение уровня W UI-42-028: `caption textSecondary` + иконка `info` 16.
class _BioWeakNote extends StatelessWidget {
  const _BioWeakNote({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final Color color = context.colors.textSecondary;
    return Padding(
      padding: EdgeInsets.only(top: context.space.s2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ExcludeSemantics(child: Icon(Icons.info_outline_rounded, size: 16, color: color)),
          SizedBox(width: context.space.s1),
          Expanded(
            child: Text(text, style: context.text.caption.copyWith(color: color)),
          ),
        ],
      ),
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
