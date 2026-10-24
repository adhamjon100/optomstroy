// Мастер смены номера SCR-41 (02 UI-41-004, UI-41-010, SCR-41.4; 09 §4.7): шаг 1 — новый номер (`+996 XXX XXX XXX`,
// не равен текущему — проверка до запроса), «Получить код» → `POST /me/phone/change/request` (S!: `403
// STEP_UP_REQUIRED` обрабатывает AuthInterceptor + StepUpDialog core/session; отмена — остаёмся на шаге 1);
// шаг 2 — код из SMS (6 цифр, автоотправка) → `/confirm`; `200` — мастер закрывается с результатом. Ошибки:
// `PHONE_ALREADY_REGISTERED` → `profile_phone_error_taken`, `OTP_INVALID`/`OTP_EXPIRED`/`OTP_LOCKED` — под кодом.
// «Назад» на шаге 2 → шаг 1 с сохранённым номером. `challengeId` не сохраняется на диск.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/otp_field.dart';
import 'package:optomstroy/design_system/components/phone_field.dart';
import 'package:optomstroy/design_system/formats/ds_phone_format.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/profile/domain/entities/user_profile.dart';
import 'package:optomstroy/features/profile/domain/repositories/profile_repository.dart';

/// Мастер смены телефона; закрывается с [PhoneChangeResult] после успешного подтверждения.
class PhoneChangeFlow extends StatefulWidget {
  const PhoneChangeFlow({required this.repository, required this.currentPhoneE164, super.key});

  /// Ключи для тестов.
  static const Key phoneKey = ValueKey<String>('profile-phone-new');
  static const Key requestKey = ValueKey<String>('profile-phone-request');
  static const Key codeKey = ValueKey<String>('profile-phone-code');
  static const Key backKey = ValueKey<String>('profile-phone-back');

  final ProfileRepository repository;
  final String? currentPhoneE164;

  @override
  State<PhoneChangeFlow> createState() => _PhoneChangeFlowState();
}

class _PhoneChangeFlowState extends State<PhoneChangeFlow> {
  final TextEditingController _phone = TextEditingController();
  PhoneChangeChallenge? _challenge;
  String? _newPhone;
  String? _phoneError;
  String? _codeError;
  bool _busy = false;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _request() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    if (_busy) return;
    final String? e164 = DsPhoneFormat.normalize(_phone.text);
    if (e164 == null) {
      setState(() => _phoneError = l10n.profile_phone_error_format);
      return;
    }
    if (e164 == widget.currentPhoneE164) {
      setState(() => _phoneError = l10n.profile_phone_error_same);
      return;
    }
    setState(() {
      _busy = true;
      _phoneError = null;
    });
    final Result<PhoneChangeChallenge> r = await widget.repository.requestPhoneChange(e164);
    if (!mounted) return;
    setState(() {
      _busy = false;
      switch (r) {
        case Success<PhoneChangeChallenge>(:final value):
          _challenge = value;
          _newPhone = e164;
          _codeError = null;
        case FailureResult<PhoneChangeChallenge>(:final failure):
          _phoneError = switch (failure) {
            ConflictFailure(kind: ConflictKind.phoneAlreadyRegistered) => l10n.profile_phone_error_taken,
            ValidationFailure() => l10n.profile_phone_error_format,
            AuthFailure(reason: AuthReason.stepUpRequired) => null,
            _ => ErrorTexts.message(l10n, UiErrorMapper.fromFailure(failure)),
          };
      }
    });
  }

  Future<void> _confirm(String code) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final PhoneChangeChallenge? ch = _challenge;
    if (_busy || ch == null) return;
    setState(() {
      _busy = true;
      _codeError = null;
    });
    final Result<PhoneChangeResult> r = await widget.repository.confirmPhoneChange(
      challengeId: ch.challengeId,
      code: code,
    );
    if (!mounted) return;
    switch (r) {
      case Success<PhoneChangeResult>(:final value):
        Navigator.of(context).pop(value);
      case FailureResult<PhoneChangeResult>(:final failure):
        setState(() {
          _busy = false;
          _codeError = switch (failure) {
            AuthFailure(reason: AuthReason.otpInvalid, :final attemptsLeft) => l10n.auth_error_otp_invalid(
              attemptsLeft ?? 0,
            ),
            _ => ErrorTexts.message(l10n, UiErrorMapper.fromFailure(failure)),
          };
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final PhoneChangeChallenge? ch = _challenge;
    if (ch == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          PhoneField(
            key: PhoneChangeFlow.phoneKey,
            controller: _phone,
            label: l10n.profile_phone_new_label,
            semanticLabel: l10n.profile_phone_new_label,
            errorText: _phoneError,
            enabled: !_busy,
            autofocus: true,
            onSubmitted: (_) => unawaited(_request()),
          ),
          SizedBox(height: context.space.s4),
          AppButton(
            key: PhoneChangeFlow.requestKey,
            label: l10n.profile_phone_get_code,
            size: AppButtonSize.l,
            expand: true,
            loading: _busy,
            onPressed: _busy ? null : () => unawaited(_request()),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          l10n.profile_phone_code_sent(DsPhoneFormat.display(_newPhone ?? '')),
          style: context.text.body.copyWith(color: context.colors.textSecondary),
        ),
        SizedBox(height: context.space.s4),
        OtpField(
          key: PhoneChangeFlow.codeKey,
          semanticLabel: l10n.profile_phone_code_sent(DsPhoneFormat.display(_newPhone ?? '')),
          errorText: _codeError,
          onCompleted: (String code) => unawaited(_confirm(code)),
        ),
        SizedBox(height: context.space.s4),
        AppButton(
          key: PhoneChangeFlow.backKey,
          label: l10n.profile_phone_resend,
          variant: AppButtonVariant.text,
          onPressed: _busy ? null : () => setState(() => _challenge = null),
        ),
      ],
    );
  }
}
