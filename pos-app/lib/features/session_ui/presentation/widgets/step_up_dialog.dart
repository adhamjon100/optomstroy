// StepUpDialog — повторное подтверждение критической операции (03 §9.46; 02 SCR-90 зона B; 09 §8.8;
// ядро §19.3). Чистый виджет: получает способ, состояние и колбэки; запрос `POST /auth/step-up`,
// хранение stepUpToken и повтор операции — StepUpFlow / core/session.
// - способы R1: «PIN» (PinField, автопроверка) и «Код из SMS» (OtpField); кнопки биометрии нет;
// - остаток попыток PIN — только из `attemptsLeft` ответа сервера (клиент попытки не считает);
// - compact — нижний лист (ручка, на всю ширину); medium/expanded — диалог 400 по центру.
import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/secure_content.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/otp_field.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Способ подтверждения в R1.
enum StepUpMethod { pin, otp }

/// Состояние диалога (вычисляет StepUpFlow по ответам сервера).
@immutable
final class StepUpDialogData {
  const StepUpDialogData({
    required this.method,
    this.methods = const <StepUpMethod>{StepUpMethod.pin, StepUpMethod.otp},
    this.pinStatus = CodeFieldStatus.idle,
    this.pinError,
    this.pinNotice,
    this.otpSent = false,
    this.otpSending = false,
    this.otpStatus = CodeFieldStatus.idle,
    this.otpError,
    this.resendIn,
    this.message,
  });

  /// Активный способ.
  final StepUpMethod method;

  /// Доступные способы (`stepUp.allowedMethods`; без сети / при `PIN_LOCKED` PIN скрывается).
  final Set<StepUpMethod> methods;

  final CodeFieldStatus pinStatus;

  /// «Неверный PIN. Осталось попыток: {n}».
  final String? pinError;

  /// PIN недоступен: заблокирован / не задан (вместо поля PIN).
  final String? pinNotice;

  /// Код из SMS отправлен — показывается OtpField.
  final bool otpSent;

  /// Идёт `POST /auth/step-up {method: otp}` (шаг 1).
  final bool otpSending;
  final CodeFieldStatus otpStatus;
  final String? otpError;

  /// До повторной отправки кода; `null`/ноль — можно отправить снова.
  final Duration? resendIn;

  /// Общая ошибка (сеть, таймаут, лимит).
  final String? message;

  StepUpDialogData copyWith({
    StepUpMethod? method,
    Set<StepUpMethod>? methods,
    CodeFieldStatus? pinStatus,
    String? pinError,
    bool clearPinError = false,
    String? pinNotice,
    bool? otpSent,
    bool? otpSending,
    CodeFieldStatus? otpStatus,
    String? otpError,
    bool clearOtpError = false,
    Duration? resendIn,
    String? message,
    bool clearMessage = false,
  }) => StepUpDialogData(
    method: method ?? this.method,
    methods: methods ?? this.methods,
    pinStatus: pinStatus ?? this.pinStatus,
    pinError: clearPinError ? null : pinError ?? this.pinError,
    pinNotice: pinNotice ?? this.pinNotice,
    otpSent: otpSent ?? this.otpSent,
    otpSending: otpSending ?? this.otpSending,
    otpStatus: otpStatus ?? this.otpStatus,
    otpError: clearOtpError ? null : otpError ?? this.otpError,
    resendIn: resendIn ?? this.resendIn,
    message: clearMessage ? null : message ?? this.message,
  );
}

class StepUpDialog extends StatelessWidget {
  const StepUpDialog({
    super.key,
    required this.data,
    required this.pinLength,
    required this.onMethodChanged,
    required this.onSubmitPin,
    required this.onRequestOtp,
    required this.onSubmitOtp,
    required this.onCancel,
    this.description,
  });

  /// Ключи (тесты, integration_test).
  static const Key dialogKey = Key('step-up-dialog');
  static const Key sheetKey = Key('step-up-sheet');
  static const Key pinTabKey = Key('step-up-tab-pin');
  static const Key otpTabKey = Key('step-up-tab-otp');
  static const Key requestOtpKey = Key('step-up-request-otp');
  static const Key resendOtpKey = Key('step-up-resend-otp');
  static const Key cancelKey = Key('step-up-cancel');
  static const Key verifyingKey = Key('step-up-verifying');

  final StepUpDialogData data;

  /// Длина PIN по политике роли (staff — 6, customer — 4).
  final int pinLength;

  /// Описание операции («Скидка 12 % сверх лимита…»); по умолчанию — подсказка о 15 минутах.
  final String? description;

  final ValueChanged<StepUpMethod> onMethodChanged;
  final ValueChanged<String> onSubmitPin;
  final VoidCallback onRequestOtp;
  final ValueChanged<String> onSubmitOtp;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final compact = context.windowClass == WindowClass.compact;
    final content = _content(context, compact);
    final DsColors c = context.colors;
    if (compact) {
      return Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          key: sheetKey,
          color: c.surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.only(topLeft: context.radii.lg, topRight: context.radii.lg),
          ),
          child: SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height - 48),
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(context.space.s4, 8, context.space.s4, context.space.s4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    ExcludeSemantics(
                      child: Container(
                        width: 32,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: c.borderStrong,
                          borderRadius: const BorderRadius.all(Radius.circular(2)),
                        ),
                      ),
                    ),
                    content,
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Center(
      child: Material(
        key: dialogKey,
        color: c.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(context.radii.lg)),
        child: Container(
          width: 400,
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height - 48),
          decoration: BoxDecoration(borderRadius: BorderRadius.all(context.radii.lg), boxShadow: context.elevation.e3),
          child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: content),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, bool compact) {
    final l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final showTabs = data.methods.length > 1;
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: l10n.ds_step_up_title,
      child: FocusScope(
        autofocus: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ExcludeSemantics(
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(color: c.primaryContainer, shape: BoxShape.circle),
                child: Icon(Icons.lock_rounded, size: 32, color: c.primaryText),
              ),
            ),
            SizedBox(height: context.space.s3),
            Semantics(
              header: true,
              child: Text(
                l10n.ds_step_up_title,
                textAlign: TextAlign.center,
                style: context.text.h3.copyWith(color: c.textPrimary),
              ),
            ),
            SizedBox(height: context.space.s2),
            Text(
              description ?? l10n.stepup_reuse_hint,
              textAlign: TextAlign.center,
              style: context.text.body.copyWith(color: c.textSecondary),
            ),
            if (showTabs) ...<Widget>[SizedBox(height: context.space.s4), _tabs(context, l10n)],
            SizedBox(height: context.space.s4),
            if (data.method == StepUpMethod.pin) _pin(context, l10n) else _otp(context, l10n),
            if (data.message != null) ...<Widget>[
              SizedBox(height: context.space.s3),
              Semantics(
                liveRegion: true,
                child: Text(
                  data.message!,
                  textAlign: TextAlign.center,
                  style: context.text.caption.copyWith(color: c.error),
                ),
              ),
            ],
            SizedBox(height: context.space.s4),
            AppButton(
              key: cancelKey,
              label: l10n.ds_button_cancel,
              variant: AppButtonVariant.text,
              expand: compact,
              onPressed: onCancel,
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabs(BuildContext context, AppLocalizations l10n) {
    Widget tab(Key key, StepUpMethod method, String label) {
      final selected = data.method == method;
      final DsColors c = context.colors;
      return Expanded(
        child: Semantics(
          selected: selected,
          button: true,
          child: InkWell(
            key: key,
            onTap: selected ? null : () => onMethodChanged(method),
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: selected ? c.primaryText : c.border, width: selected ? 2 : 1),
                ),
              ),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: context.text.label.copyWith(color: selected ? c.primaryText : c.textSecondary),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: <Widget>[
        // Вкладки «PIN» / «Код из SMS» (03 §9.46; ключи `stepup_tab_*` — 03 §16.7, D SS-02).
        if (data.methods.contains(StepUpMethod.pin)) tab(pinTabKey, StepUpMethod.pin, l10n.stepup_tab_pin),
        if (data.methods.contains(StepUpMethod.otp)) tab(otpTabKey, StepUpMethod.otp, l10n.stepup_tab_sms),
      ],
    );
  }

  Widget _pin(BuildContext context, AppLocalizations l10n) {
    final notice = data.pinNotice;
    if (notice != null) {
      return Text(
        notice,
        textAlign: TextAlign.center,
        style: context.text.body.copyWith(color: context.colors.error),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SecureContent(
          child: PinField(
            length: pinLength,
            status: data.pinStatus,
            errorText: data.pinError,
            semanticLabel: (int entered, int length) => l10n.reg_pin_a11y('$length', entered),
            backspaceLabel: l10n.qty_key_backspace_a11y,
            onCompleted: onSubmitPin,
          ),
        ),
        if (data.pinStatus == CodeFieldStatus.loading) _verifying(context, l10n),
      ],
    );
  }

  Widget _otp(BuildContext context, AppLocalizations l10n) {
    if (!data.otpSent) {
      return AppButton(
        key: requestOtpKey,
        label: l10n.stepup_send_code,
        variant: AppButtonVariant.secondary,
        expand: true,
        loading: data.otpSending,
        onPressed: data.otpSending ? null : onRequestOtp,
      );
    }
    final wait = data.resendIn;
    final canResend = wait == null || wait <= Duration.zero;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(l10n.auth_otp_title, style: context.text.label.copyWith(color: context.colors.textPrimary)),
        SizedBox(height: context.space.s2),
        SecureContent(
          child: OtpField(
            semanticLabel: l10n.auth_otp_code_a11y,
            status: data.otpStatus,
            errorText: data.otpError,
            onCompleted: onSubmitOtp,
          ),
        ),
        if (data.otpStatus == CodeFieldStatus.loading) _verifying(context, l10n),
        SizedBox(height: context.space.s2),
        AppButton(
          key: resendOtpKey,
          label: canResend ? l10n.auth_otp_resend : l10n.auth_otp_resend_in(_mmss(wait)),
          variant: AppButtonVariant.text,
          size: AppButtonSize.s,
          onPressed: canResend && !data.otpSending ? onRequestOtp : null,
        ),
      ],
    );
  }

  /// «Проверяем…» (03 §9.46) — пока сервер проверяет PIN или код.
  static Widget _verifying(BuildContext context, AppLocalizations l10n) => Padding(
    padding: EdgeInsets.only(top: context.space.s2),
    child: Semantics(
      liveRegion: true,
      child: Text(
        l10n.stepup_verifying,
        key: verifyingKey,
        style: context.text.caption.copyWith(color: context.colors.textSecondary),
      ),
    ),
  );

  static String _mmss(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
