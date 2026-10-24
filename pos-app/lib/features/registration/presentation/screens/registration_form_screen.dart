// SCR-03 «Регистрация, шаг 1 — Данные» (`/register`; 02 SCR-03; 09 §7.1, §7.4).
// Сетевых запросов нет: данные уходят одним `POST /registration/complete` с SCR-04.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/phone_number.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_checkbox.dart';
import 'package:optomstroy/design_system/components/app_dropdown.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';
import 'package:optomstroy/features/registration/domain/usecases/registration_validation.dart';
import 'package:optomstroy/features/registration/presentation/controllers/registration_flow_controller.dart';
import 'package:optomstroy/features/registration/presentation/widgets/registration_frame.dart';
import 'package:optomstroy/features/registration/presentation/widgets/registration_stepper.dart';
import 'package:optomstroy/features/registration/registration_providers.dart';

class RegistrationFormScreen extends ConsumerStatefulWidget {
  const RegistrationFormScreen({super.key});

  static const Key screenKey = ValueKey<String>('scr03');
  static const Key nameFieldKey = ValueKey<String>('scr03.fullName');
  static const Key phoneFieldKey = ValueKey<String>('scr03.phone');
  static const Key yearFieldKey = ValueKey<String>('scr03.birthYear');
  static const Key sphereKey = ValueKey<String>('scr03.sphere');
  static const Key otherFieldKey = ValueKey<String>('scr03.sphereOther');
  static const Key pdAckKey = ValueKey<String>('scr03.pdAck');
  static const Key sphereConsentKey = ValueKey<String>('scr03.sphereConsent');
  static const Key continueKey = ValueKey<String>('scr03.continue');
  static const Key backKey = ValueKey<String>('scr03.back');
  static const Key restoredBannerKey = ValueKey<String>('scr03.restored');
  static const Key timerKey = ValueKey<String>('scr03.timer');

  @override
  ConsumerState<RegistrationFormScreen> createState() => _RegistrationFormScreenState();
}

class _RegistrationFormScreenState extends ConsumerState<RegistrationFormScreen> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _year = TextEditingController();
  final TextEditingController _phone = TextEditingController();
  final FocusNode _nameFocus = FocusNode(debugLabel: 'scr03.name');
  final FocusNode _yearFocus = FocusNode(debugLabel: 'scr03.year');
  Timer? _ticker;
  bool _nameTouched = false;
  bool _yearTouched = false;
  bool _expiredShown = false;
  bool _navigating = false;

  RegistrationFlowController get _flow => ref.read(registrationFlowProvider.notifier);

  @override
  void initState() {
    super.initState();
    _nameFocus.addListener(() {
      if (!_nameFocus.hasFocus) {
        final normalized = RegistrationValidation.normalizeFullName(_name.text);
        if (normalized != _name.text) _name.text = normalized;
        _flow.setFullName(normalized);
        setState(() => _nameTouched = true);
      }
    });
    _yearFocus.addListener(() {
      if (!_yearFocus.hasFocus) setState(() => _yearTouched = _year.text.isNotEmpty);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_init()));
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  Future<void> _init() async {
    if (ref.read(registrationTicketProvider) == null) {
      // Guard G-2: без registration_token → SCR-01.
      ref.read(registrationNavigatorProvider).toPhone(context, RegistrationExitReason.registrationExpired);
      return;
    }
    await _flow.loadDraft();
    if (!mounted) return;
    final draft = ref.read(registrationFlowProvider).draft;
    _name.text = draft.fullName;
    _year.text = draft.birthYear;
    if (draft.fullName.isEmpty) _nameFocus.requestFocus();
    setState(() {});
  }

  void _tick() {
    if (!mounted) return;
    final ticket = ref.read(registrationTicketProvider);
    if (ticket != null && ticket.isExpired(ref.read(clockProvider).nowUtc())) {
      unawaited(_showExpired());
    }
    setState(() {});
  }

  Future<void> _showExpired() async {
    if (_expiredShown) return;
    _expiredShown = true;
    final l10n = AppLocalizations.of(context);
    _flow.cancelRegistration();
    await ConfirmDialog.show(
      context,
      title: l10n.reg_expired_action,
      message: l10n.reg_error_token_expired,
      confirmLabel: l10n.reg_expired_action,
    );
    if (mounted) ref.read(registrationNavigatorProvider).toPhone(context, RegistrationExitReason.registrationExpired);
  }

  Future<void> _cancel() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await ConfirmDialog.show(
      context,
      title: l10n.reg_cancel_title,
      message: l10n.reg_cancel_body,
      confirmLabel: l10n.reg_cancel_confirm,
      cancelLabel: l10n.reg_cancel_continue,
    );
    if (!confirmed || !mounted) return;
    _flow.cancelRegistration();
    ref.read(registrationNavigatorProvider).toPhone(context, RegistrationExitReason.registrationCancelled);
  }

  Future<void> _continue() async {
    if (_navigating) return;
    final ok = await _flow.submitForm();
    if (!mounted) return;
    setState(() {
      _nameTouched = true;
      _yearTouched = true;
    });
    if (!ok) {
      final flow = _flow;
      if (!flow.fullNameCheck.isValid) {
        _nameFocus.requestFocus();
      } else if (flow.birthYearError != null) {
        _yearFocus.requestFocus();
      }
      return;
    }
    _navigating = true;
    ref.read(registrationNavigatorProvider).toSecurity(context);
    // Повторный `push` подавляется до возврата на экран.
    Future<void>.delayed(const Duration(milliseconds: 500), () => _navigating = false);
  }

  Future<void> _showPdText() async {
    final l10n = AppLocalizations.of(context);
    await AppBottomSheet.show<void>(
      context,
      title: l10n.reg_pd_more,
      body: Text(l10n.register_consent_pd_text, style: context.text.body),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _name.dispose();
    _year.dispose();
    _phone.dispose();
    _nameFocus.dispose();
    _yearFocus.dispose();
    super.dispose();
  }

  String? _nameError(AppLocalizations l10n, RegistrationFlowState s) {
    if (s.serverFieldErrors.containsKey('fullName')) return l10n.reg_error_name_invalid;
    if (!(_nameTouched || s.formSubmitted)) return null;
    return switch (_flow.fullNameCheck.error) {
      FullNameError.required => l10n.reg_error_name_required,
      FullNameError.length => l10n.reg_error_name_length,
      FullNameError.invalid => l10n.reg_error_name_invalid,
      null => null,
    };
  }

  String? _yearError(AppLocalizations l10n, RegistrationFlowState s) {
    final range = l10n.reg_error_birth_year_range('${_flow.maxBirthYear}', '${RegistrationValidation.minBirthYear}');
    if (s.serverFieldErrors.containsKey('birthYear')) return range;
    if (!(_yearTouched || s.formSubmitted)) return null;
    return switch (_flow.birthYearError) {
      BirthYearError.required => l10n.reg_error_birth_year_required,
      BirthYearError.range => range,
      null => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final s = ref.watch(registrationFlowProvider);
    final ticket = ref.watch(registrationTicketProvider);
    final selfService = ref.watch(customerSelfServiceProvider);
    final compact = context.windowClass == WindowClass.compact;
    final c = context.colors;
    final now = ref.read(clockProvider).nowUtc();
    final remaining = ticket?.remaining(now) ?? Duration.zero;
    final mmss =
        '${remaining.inMinutes.toString().padLeft(2, '0')}:${(remaining.inSeconds % 60).toString().padLeft(2, '0')}';
    final phone = ticket == null ? '' : (PhoneNumber.tryParseE164(ticket.phoneE164)?.grouped ?? ticket.phoneE164);
    if (_phone.text != phone) _phone.text = phone;
    final nameCheck = _flow.fullNameCheck;
    final ready = _flow.formReady;

    final continueButton = AppButton(
      key: RegistrationFormScreen.continueKey,
      label: l10n.reg_continue,
      size: AppButtonSize.l,
      expand: compact,
      onPressed: ready ? () => unawaited(_continue()) : null,
    );
    final timer = Text(
      l10n.reg_timer(mmss),
      key: RegistrationFormScreen.timerKey,
      style: context.text.caption.copyWith(
        color: remaining.inSeconds <= 60 ? c.warning : c.textSecondary,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
    );

    final yearField = AppTextField(
      key: RegistrationFormScreen.yearFieldKey,
      controller: _year,
      focusNode: _yearFocus,
      label: l10n.reg_field_birth_year,
      hint: l10n.reg_birth_year_placeholder,
      errorText: _yearError(l10n, s),
      variant: AppTextFieldVariant.number,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.next,
      maxLength: 4,
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(4),
      ],
      onChanged: (v) {
        _flow.setBirthYear(v);
        if (v.length == 4) setState(() => _yearTouched = true);
      },
      expand: false,
    );
    final sphereItems = <AppDropdownItem<ActivitySphere?>>[
      AppDropdownItem<ActivitySphere?>(value: null, label: l10n.reg_activity_none),
      AppDropdownItem<ActivitySphere?>(value: ActivitySphere.plumber, label: l10n.reg_activity_plumber),
      AppDropdownItem<ActivitySphere?>(value: ActivitySphere.foreman, label: l10n.reg_activity_foreman),
      AppDropdownItem<ActivitySphere?>(value: ActivitySphere.reseller, label: l10n.reg_activity_reseller),
      AppDropdownItem<ActivitySphere?>(value: ActivitySphere.installer, label: l10n.reg_activity_installer),
      AppDropdownItem<ActivitySphere?>(value: ActivitySphere.privatePerson, label: l10n.reg_activity_private),
      AppDropdownItem<ActivitySphere?>(value: ActivitySphere.other, label: l10n.reg_activity_other),
    ];
    final sphereField = AppDropdown<ActivitySphere?>(
      key: RegistrationFormScreen.sphereKey,
      items: sphereItems,
      value: s.draft.activitySphere,
      label: l10n.reg_field_activity,
      hint: l10n.reg_activity_placeholder,
      onChanged: _flow.setActivitySphere,
    );

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{SingleActivator(LogicalKeyboardKey.escape): DismissIntent()},
      child: Actions(
        actions: <Type, Action<Intent>>{
          DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) => unawaited(_cancel())),
        },
        child: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) unawaited(_cancel());
          },
          child: RegistrationFrame(
            screenKey: RegistrationFormScreen.screenKey,
            header: RegistrationHeader(
              title: l10n.reg_header,
              backKey: RegistrationFormScreen.backKey,
              backLabel: l10n.reg_cancel_confirm,
              onBack: () => unawaited(_cancel()),
            ),
            bottom: compact
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      timer,
                      SizedBox(height: context.space.s2),
                      continueButton,
                    ],
                  )
                : Row(
                    children: <Widget>[
                      Expanded(child: timer),
                      SizedBox(width: 220, child: continueButton),
                    ],
                  ),
            child: !s.loaded
                ? const SizedBox(height: 120)
                : FocusTraversalGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        RegistrationStepper(current: RegistrationStep.data, withCustomerLink: selfService),
                        SizedBox(height: context.space.s6),
                        if (s.restored) ...<Widget>[
                          ErrorState.banner(
                            key: RegistrationFormScreen.restoredBannerKey,
                            message: l10n.reg_restored_banner,
                            tone: ErrorStateTone.info,
                            onClose: _flow.dismissRestored,
                          ),
                          SizedBox(height: context.space.s4),
                        ],
                        Text(l10n.reg_form_title, style: compact ? context.text.h2 : context.text.h1),
                        SizedBox(height: context.space.s2),
                        Text(l10n.reg_form_subtitle, style: context.text.body.copyWith(color: c.textSecondary)),
                        SizedBox(height: context.space.s6),
                        AppTextField(
                          key: RegistrationFormScreen.nameFieldKey,
                          controller: _name,
                          focusNode: _nameFocus,
                          label: l10n.reg_field_name,
                          helper: nameCheck.isValid && nameCheck.oneWordWarning && _nameTouched
                              ? l10n.reg_warning_name_one_word
                              : l10n.reg_field_name_hint,
                          errorText: _nameError(l10n, s),
                          size: compact ? AppTextFieldSize.l : AppTextFieldSize.m,
                          withClear: true,
                          keyboardType: TextInputType.name,
                          textInputAction: TextInputAction.next,
                          autofillHints: const <String>[AutofillHints.name],
                          maxLength: RegistrationValidation.fullNameMaxLength,
                          inputFormatters: <TextInputFormatter>[
                            FilteringTextInputFormatter.deny(RegistrationValidation.fullNameDisallowedChar),
                          ],
                          onChanged: _flow.setFullName,
                          onSubmitted: (_) => _yearFocus.requestFocus(),
                        ),
                        SizedBox(height: context.space.s4),
                        AppTextField(
                          key: RegistrationFormScreen.phoneFieldKey,
                          controller: _phone,
                          label: l10n.reg_field_phone,
                          variant: AppTextFieldVariant.readOnly,
                          enabled: false,
                          suffix: StatusChip(
                            label: l10n.reg_phone_verified,
                            variant: StatusChipVariant.success,
                            icon: Icons.check_rounded,
                            dense: true,
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: AppButton(
                            label: l10n.reg_phone_change,
                            variant: AppButtonVariant.text,
                            size: AppButtonSize.s,
                            onPressed: () => unawaited(_cancel()),
                          ),
                        ),
                        SizedBox(height: context.space.s2),
                        if (compact) ...<Widget>[
                          SizedBox(width: 160, child: yearField),
                          SizedBox(height: context.space.s4),
                          sphereField,
                        ] else
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              SizedBox(width: 160, child: yearField),
                              SizedBox(width: context.space.s4),
                              Expanded(child: sphereField),
                            ],
                          ),
                        RevealSize(
                          child: s.draft.activitySphere == ActivitySphere.other
                              ? Padding(
                                  padding: EdgeInsets.only(top: context.space.s4),
                                  child: AppTextField(
                                    key: RegistrationFormScreen.otherFieldKey,
                                    hint: l10n.reg_activity_other_hint,
                                    maxLength: RegistrationValidation.otherSphereMaxLength,
                                    onChanged: _flow.setOtherSphereText,
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                        SizedBox(height: context.space.s6),
                        Text(
                          l10n.register_consent_pd_text,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.body.copyWith(color: c.textSecondary),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: AppButton(
                            label: l10n.reg_pd_more,
                            variant: AppButtonVariant.text,
                            size: AppButtonSize.s,
                            onPressed: () => unawaited(_showPdText()),
                          ),
                        ),
                        AppCheckbox(
                          key: RegistrationFormScreen.pdAckKey,
                          value: s.draft.personalDataAck,
                          label: l10n.reg_pd_ack_label,
                          errorText: (s.formSubmitted && !s.draft.personalDataAck) || s.consentServerError
                              ? l10n.reg_error_consent_required
                              : null,
                          onChanged: (v) => _flow.setPersonalDataAck(v ?? false),
                        ),
                        RevealSize(
                          child: s.draft.activitySphere != null
                              ? Padding(
                                  padding: EdgeInsets.only(top: context.space.s2),
                                  child: AppCheckbox(
                                    key: RegistrationFormScreen.sphereConsentKey,
                                    value: s.draft.activitySphereConsent,
                                    label: l10n.reg_activity_consent_label,
                                    description: s.draft.activitySphereConsent ? null : l10n.reg_hint_activity_consent,
                                    onChanged: (v) => _flow.setActivitySphereConsent(v ?? false),
                                  ),
                                )
                              : const SizedBox.shrink(),
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
