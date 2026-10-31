// SCR-04 «Регистрация, шаг 2 — Защита входа» и шаг 3 «Готово» (`/register/security`; 02 SCR-04; 09 §7.3, §9.5).
// Режим «первый вход сотрудника» (`audience: staffFirstLogin`): PIN 6 цифр обязателен, индикатор шагов скрыт,
// «Начать работу» → `POST /me/pin` → `POST /me/consents` → (по выбору) биометрия.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/secure_content.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_checkbox.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/app_switch.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/otp_field.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';
import 'package:optomstroy/features/registration/domain/repositories/registration_repositories.dart';
import 'package:optomstroy/features/registration/presentation/controllers/registration_flow_controller.dart';
import 'package:optomstroy/features/registration/presentation/widgets/registration_frame.dart';
import 'package:optomstroy/features/registration/presentation/widgets/registration_stepper.dart';
import 'package:optomstroy/features/registration/presentation/widgets/step_up_pin_dialog.dart';
import 'package:optomstroy/features/registration/presentation/widgets/success_check.dart';
import 'package:optomstroy/features/registration/registration_providers.dart';

class RegistrationSecurityScreen extends ConsumerStatefulWidget {
  const RegistrationSecurityScreen({
    super.key,
    this.audience = RegistrationAudience.customer,
    this.staffViaInvitation = false,
  });

  final RegistrationAudience audience;

  /// Режим «первый вход сотрудника» открыт после входа по приглашению (`roleSource: invitation`, 02 SCR-02.6):
  /// только тогда подзаголовок `reg_staff_first_subtitle` «Вы вошли по приглашению администратора…».
  /// Сотрудник без PIN по другой причине (сброс PIN; Q-323 — тот же экран вместо SCR-08 UI-08-014, где
  /// подзаголовка нет) видит экран без подзаголовка.
  final bool staffViaInvitation;

  static const Key screenKey = ValueKey<String>('scr04');
  static const Key pinFieldKey = ValueKey<String>('scr04.pin');
  static const Key pinSwitchKey = ValueKey<String>('scr04.pinSwitch');
  static const Key bioSwitchKey = ValueKey<String>('scr04.bioSwitch');
  static const Key bioConsentKey = ValueKey<String>('scr04.bioConsent');
  static const Key pdAckKey = ValueKey<String>('scr04.pdAck');
  static const Key completeKey = ValueKey<String>('scr04.complete');
  static const Key bioLaterKey = ValueKey<String>('scr04.bioLater');
  static const Key submitErrorKey = ValueKey<String>('scr04.submitError');
  static const Key protectionErrorKey = ValueKey<String>('scr04.protectionError');
  static const Key doneKey = ValueKey<String>('scr04.done');
  static const Key backKey = ValueKey<String>('scr04.back');

  @override
  ConsumerState<RegistrationSecurityScreen> createState() => _RegistrationSecurityScreenState();
}

class _RegistrationSecurityScreenState extends ConsumerState<RegistrationSecurityScreen> with WidgetsBindingObserver {
  RegistrationFlowController get _flow => ref.read(registrationFlowProvider.notifier);
  bool _navigated = false;
  Timer? _autoNext;

  bool get _staff => widget.audience == RegistrationAudience.staffFirstLogin;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_flow.openSecurity(widget.audience)));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Пользователь мог настроить отпечаток в системе (02 SCR-04.4 «Переключатель» п. 1).
    if (state == AppLifecycleState.resumed) unawaited(_flow.refreshBiometrics());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoNext?.cancel();
    super.dispose();
  }

  BiometricPromptCopy _prompt(AppLocalizations l10n) {
    final option = ref.read(registrationFlowProvider).bioOption;
    return BiometricPromptCopy(
      title: option == BiometricOption.windowsHelloGate ? l10n.unlock_hello_button : l10n.auth_bio_offer_title,
      subtitle: l10n.reg_security_subtitle,
      cancel: l10n.ds_button_cancel,
    );
  }

  void _onEffect(RegistrationEffect? effect) {
    if (effect == null || !mounted) return;
    _flow.consumeEffect();
    final l10n = AppLocalizations.of(context);
    final nav = ref.read(registrationNavigatorProvider);
    switch (effect) {
      case ExpiredEffect():
        unawaited(() async {
          await ConfirmDialog.show(
            context,
            title: l10n.reg_expired_action,
            message: l10n.reg_error_token_expired,
            confirmLabel: l10n.reg_expired_action,
          );
          if (mounted) nav.toPhone(context, RegistrationExitReason.registrationExpired);
        }());
      case ToPhoneEffect(:final reason):
        nav.toPhone(context, reason);
      case ToFormEffect():
        _flow.leaveSecurity();
        nav.backToForm(context);
      case BioNotEnabledEffect():
        AppSnackbar.show(context, message: l10n.reg_bio_not_enabled);
    }
  }

  void _onPhase(SecurityPhase? prev, SecurityPhase next) {
    if (next == SecurityPhase.stepUp) unawaited(StepUpPinDialog.show(context));
    if (next == SecurityPhase.done && prev != SecurityPhase.done) {
      final reduce = context.motion.reduceMotion;
      // Галочка 450 мс + автопереход через 600 мс (≤ 900 мс от ответа); reduce-motion — 300 мс.
      _autoNext = Timer(Duration(milliseconds: reduce ? 300 : 1050), _goNext);
    }
  }

  void _goNext() {
    if (_navigated || !mounted) return;
    _navigated = true;
    _autoNext?.cancel();
    final s = ref.read(registrationFlowProvider);
    final nav = ref.read(registrationNavigatorProvider);
    final outcome = s.outcome;
    if (!_staff && outcome?.accountStatus == RegistrationAccountStatus.pendingActivation) {
      nav.toPendingActivation(context);
      return;
    }
    // Сессия установлена (SessionController.establish): Splash определяет главный экран роли (06 §6.4).
    if (!_staff && ref.read(customerSelfServiceProvider) && (outcome?.customerMatch?.needsScreen ?? false)) {
      nav.toCustomerLink(context);
    } else {
      nav.toHome(context);
    }
  }

  Future<void> _back() async {
    final s = ref.read(registrationFlowProvider);
    if (s.busy || s.phase == SecurityPhase.done) return;
    if (_staff || s.phase == SecurityPhase.needPin) {
      final l10n = AppLocalizations.of(context);
      final ok = await ConfirmDialog.show(
        context,
        title: l10n.pending_logout_title,
        message: l10n.pending_logout_body,
        confirmLabel: l10n.pending_logout,
      );
      if (!ok || !mounted) return;
      await ref.read(registrationRepositoryProvider).logout();
      if (mounted) ref.read(registrationNavigatorProvider).toPhone(context, RegistrationExitReason.loggedOut);
      return;
    }
    _flow.leaveSecurity();
    ref.read(registrationNavigatorProvider).backToForm(context);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(registrationFlowProvider.select((s) => s.effect), (_, next) => _onEffect(next));
    ref.listen(registrationFlowProvider.select((s) => s.phase), _onPhase);
    final l10n = AppLocalizations.of(context);
    final s = ref.watch(registrationFlowProvider);
    final selfService = ref.watch(customerSelfServiceProvider);
    final compact = context.windowClass == WindowClass.compact;
    final online = ref.watch(onlineStatusProvider).value != OnlineStatus.offline;

    if (s.phase == SecurityPhase.done) return _done(context, l10n, s, selfService);

    final header = RegistrationHeader(
      title: l10n.reg_header,
      backKey: RegistrationSecurityScreen.backKey,
      backLabel: l10n.reg_step_data,
      onBack: s.busy ? null : () => unawaited(_back()),
    );
    final complete = AppButton(
      key: RegistrationSecurityScreen.completeKey,
      label: _staff ? l10n.reg_staff_first_complete : l10n.reg_complete,
      size: AppButtonSize.l,
      expand: compact,
      loading: s.busy,
      onPressed: _flow.canSubmit && online ? () => unawaited(_flow.submit(prompt: _prompt(l10n))) : null,
    );
    final later = s.bioSelectable && s.phase == SecurityPhase.editing
        ? AppButton(
            key: RegistrationSecurityScreen.bioLaterKey,
            label: s.bioOption == BiometricOption.windowsHelloGate ? l10n.reg_bio_later_windows : l10n.reg_bio_later,
            variant: AppButtonVariant.text,
            onPressed: s.busy ? null : _flow.bioLater,
          )
        : null;

    final String? subtitle = s.phase == SecurityPhase.needPin
        ? l10n.reg_bio_failed_set_pin
        : !_staff
        ? l10n.reg_security_subtitle
        : (widget.staffViaInvitation ? l10n.reg_staff_first_subtitle : null);
    final pinBlock = _pinBlock(context, l10n, s);
    final bioBlock = s.phase == SecurityPhase.needPin ? null : _bioBlock(context, l10n, s);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: RegistrationFrame(
        screenKey: RegistrationSecurityScreen.screenKey,
        header: header,
        bottom: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (s.submitError != null) ...<Widget>[
              ErrorState.banner(
                key: RegistrationSecurityScreen.submitErrorKey,
                message: switch (s.submitError!) {
                  SubmitErrorKind.network => l10n.reg_error_network,
                  SubmitErrorKind.readOnly => l10n.error_app_read_only,
                  SubmitErrorKind.server => l10n.reg_error_network,
                },
                onRetry: s.submitError == SubmitErrorKind.readOnly
                    ? null
                    : () => unawaited(_flow.retry(prompt: _prompt(l10n))),
              ),
              SizedBox(height: context.space.s3),
            ],
            if (!online) ...<Widget>[
              Text(
                l10n.reg_complete_offline,
                style: context.text.caption.copyWith(color: context.colors.textSecondary),
              ),
              SizedBox(height: context.space.s2),
            ],
            if (compact) ...<Widget>[complete, ?later] else
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  ?later,
                  SizedBox(width: context.space.s3),
                  SizedBox(width: 260, child: complete),
                ],
              ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (!_staff) ...<Widget>[
              RegistrationStepper(
                current: RegistrationStep.security,
                withCustomerLink: selfService,
                onStepTap: (_) => unawaited(_back()),
              ),
              SizedBox(height: context.space.s6),
            ],
            Text(
              _staff ? l10n.reg_staff_first_title : l10n.reg_security_title,
              style: compact ? context.text.h2 : context.text.h1,
            ),
            if (subtitle != null) ...<Widget>[
              SizedBox(height: context.space.s2),
              Text(subtitle, style: context.text.body.copyWith(color: context.colors.textSecondary)),
            ],
            SizedBox(height: context.space.s6),
            if (compact || bioBlock == null) ...<Widget>[
              pinBlock,
              if (bioBlock != null) ...<Widget>[SizedBox(height: context.space.s6), bioBlock],
            ] else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(child: pinBlock),
                  SizedBox(width: context.space.s4),
                  Expanded(child: bioBlock),
                ],
              ),
            if (_staff) ...<Widget>[
              SizedBox(height: context.space.s6),
              Text(
                l10n.register_consent_pd_text,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: context.text.body.copyWith(color: context.colors.textSecondary),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: AppButton(
                  label: l10n.reg_pd_more,
                  variant: AppButtonVariant.text,
                  size: AppButtonSize.s,
                  onPressed: () => unawaited(
                    AppBottomSheet.show<void>(
                      context,
                      title: l10n.reg_pd_more,
                      body: Text(l10n.register_consent_pd_text, style: context.text.body),
                    ),
                  ),
                ),
              ),
              AppCheckbox(
                key: RegistrationSecurityScreen.pdAckKey,
                value: s.draft.personalDataAck,
                label: l10n.reg_pd_ack_label,
                onChanged: s.busy ? null : (v) => _flow.setPersonalDataAck(v ?? false),
              ),
            ],
            if (s.protectionError) ...<Widget>[
              SizedBox(height: context.space.s4),
              Text(
                l10n.reg_protection_required,
                key: RegistrationSecurityScreen.protectionErrorKey,
                style: context.text.label.copyWith(color: context.colors.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tile(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? trailing,
  }) {
    final c = context.colors;
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s2),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.all(context.radii.md),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 24, color: c.primaryText),
          SizedBox(width: context.space.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(title, style: context.text.title),
                if (subtitle != null) Text(subtitle, style: context.text.caption.copyWith(color: c.textSecondary)),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }

  Widget _pinBlock(BuildContext context, AppLocalizations l10n, RegistrationFlowState s) {
    final length = s.pinPolicy.length;
    final required = s.pinRequired;
    final tile = _tile(
      context,
      icon: Icons.lock_outline_rounded,
      title: l10n.reg_pin_tile_title,
      subtitle: _staff ? l10n.reg_pin_tile_required : (required ? null : l10n.reg_pin_tile_optional),
      trailing: required
          ? null
          : SizedBox(
              width: 56,
              child: AppSwitch(
                key: RegistrationSecurityScreen.pinSwitchKey,
                value: s.pinEnabled,
                semanticLabel: l10n.reg_pin_tile_title,
                onChanged: s.busy ? null : _flow.setPinEnabled,
              ),
            ),
    );
    if (!s.pinActive) return tile;
    final stageLabel = switch (s.pinStage) {
      PinStage.create => l10n.reg_pin_create,
      PinStage.confirm => l10n.reg_pin_repeat,
      PinStage.done => l10n.reg_pin_repeat,
    };
    final errorText = switch (s.pinError) {
      PinErrorKind.weak => l10n.reg_error_pin_weak,
      PinErrorKind.mismatch => l10n.reg_error_pin_mismatch,
      null => null,
    };
    final status = switch (s) {
      RegistrationFlowState(pinStage: PinStage.done) => CodeFieldStatus.success,
      RegistrationFlowState(busy: true) => CodeFieldStatus.loading,
      RegistrationFlowState(pinError: != null) => CodeFieldStatus.error,
      _ => CodeFieldStatus.idle,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        tile,
        SizedBox(height: context.space.s4),
        Text(stageLabel, textAlign: TextAlign.center, style: context.text.label),
        SizedBox(height: context.space.s3),
        Center(
          child: GestureDetector(
            onTap: s.pinStage == PinStage.done && !s.busy ? _flow.restartPin : null,
            child: SecureContent(
              child: PinField(
                key: ValueKey<String>(
                  '${RegistrationSecurityScreen.pinFieldKey}.${s.pinStage.name}.${s.pinResetCounter}',
                ),
                length: length,
                semanticLabel: (n, len) => l10n.reg_pin_a11y('$len', n),
                backspaceLabel: l10n.qty_key_backspace_a11y,
                status: status,
                errorText: errorText,
                showNumpad: s.pinStage != PinStage.done,
                onCompleted: _flow.onPinEntered,
              ),
            ),
          ),
        ),
        SizedBox(height: context.space.s2),
        Text(
          l10n.reg_pin_rules_hint('$length'),
          textAlign: TextAlign.center,
          style: context.text.caption.copyWith(color: context.colors.textSecondary),
        ),
      ],
    );
  }

  Widget _bioBlock(BuildContext context, AppLocalizations l10n, RegistrationFlowState s) {
    final option = s.bioOption;
    final hello = option == BiometricOption.windowsHelloGate;
    final chip = switch (option) {
      null => const StatusChip(label: '…', variant: StatusChipVariant.neutral, dense: true),
      BiometricOption.cryptoLogin || BiometricOption.windowsHelloGate => StatusChip(
        label: l10n.reg_bio_available,
        variant: StatusChipVariant.success,
        dense: true,
      ),
      BiometricOption.notEnrolled => StatusChip(
        label: l10n.reg_bio_not_enrolled,
        variant: StatusChipVariant.warning,
        dense: true,
      ),
      BiometricOption.unsupported => StatusChip(
        label: l10n.reg_bio_unsupported,
        variant: StatusChipVariant.neutral,
        dense: true,
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _tile(
          context,
          icon: hello ? Icons.key_rounded : Icons.fingerprint_rounded,
          title: hello ? l10n.unlock_hello_button : l10n.reg_bio_tile_title,
          subtitle: hello ? l10n.reg_bio_windows_hello : null,
          trailing: s.bioSelectable
              ? SizedBox(
                  width: 56,
                  child: AppSwitch(
                    key: RegistrationSecurityScreen.bioSwitchKey,
                    value: s.bioEnabled,
                    semanticLabel: l10n.reg_bio_tile_title,
                    onChanged: s.busy ? null : _flow.setBioEnabled,
                  ),
                )
              : null,
        ),
        SizedBox(height: context.space.s2),
        Align(alignment: Alignment.centerLeft, child: chip),
        RevealSize(
          child: s.bioEnabled
              ? Padding(
                  padding: EdgeInsets.only(top: context.space.s3),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      AppCheckbox(
                        key: RegistrationSecurityScreen.bioConsentKey,
                        value: s.bioConsent,
                        label: l10n.reg_bio_consent_label,
                        onChanged: s.busy ? null : (v) => _flow.setBioConsent(v ?? false),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: AppButton(
                          label: l10n.reg_pd_more,
                          variant: AppButtonVariant.text,
                          size: AppButtonSize.s,
                          onPressed: () => unawaited(
                            AppBottomSheet.show<void>(
                              context,
                              title: l10n.reg_bio_tile_title,
                              body: Text(l10n.register_security_consent_text, style: context.text.body),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _done(BuildContext context, AppLocalizations l10n, RegistrationFlowState s, bool selfService) {
    final name = s.draft.fullName.trim().split(' ').length > 1
        ? s.draft.fullName.trim().split(' ')[1]
        : s.draft.fullName.trim();
    final bio = s.bioResult == BiometricEnrollmentResult.enabled || s.bioResult == BiometricEnrollmentResult.gateOnly;
    final pending = s.outcome?.accountStatus == RegistrationAccountStatus.pendingActivation;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _goNext,
      child: RegistrationFrame(
        screenKey: RegistrationSecurityScreen.doneKey,
        child: Column(
          children: <Widget>[
            if (!_staff)
              RegistrationStepper(
                current: (s.outcome?.customerMatch?.needsScreen ?? false) && selfService
                    ? RegistrationStep.security
                    : RegistrationStep.done,
                withCustomerLink: selfService,
              ),
            SizedBox(height: context.space.s8),
            const SuccessCheck(size: 72),
            SizedBox(height: context.space.s6),
            Semantics(
              liveRegion: true,
              child: Text(
                name.isEmpty ? l10n.reg_step_done : l10n.reg_success_title(name),
                textAlign: TextAlign.center,
                style: context.text.h2,
              ),
            ),
            SizedBox(height: context.space.s2),
            Text(
              bio ? l10n.reg_success_security_pin_bio : l10n.reg_success_security_pin,
              textAlign: TextAlign.center,
              style: context.text.body.copyWith(color: context.colors.textSecondary),
            ),
            if (pending) ...<Widget>[
              SizedBox(height: context.space.s2),
              Text(l10n.reg_success_pending, textAlign: TextAlign.center, style: context.text.body),
            ],
          ],
        ),
      ),
    );
  }
}
