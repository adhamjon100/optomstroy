// SCR-52 шаг «Код» (02 ч. F SCR-52.3, SCR-52.4; 03 §9.5, §9.74, DS-099, DS-101, DS-102; 13 TAB-2-04): «Код
// отправлен на +996 7** *** *01» UI-52-008 (маску строит приложение — `DsPhoneFormat.masked`: ответ сервера номер не
// повторяет), поле кода UI-52-009 (`OtpField` в `PrivateInputScope` — без SMS Retriever, автозаполнения и вставки;
// автоперехода при 6-й цифре нет), таймер повторного кода UI-52-010, «Изменить номер» UI-52-011, `KioskKeypad`
// (6 цифр), сообщение UI-52-014 и «Отправить заявку» UI-52-012.
//
// Таймер считается от момента «можно повторить» (`resendAt` контроллера, а не от счётчика экрана): после возврата из
// drawer по отказу остатка отсчёт продолжается. Обновление раз в секунду; диктор объявляет только 10 с и 0 (03 §9.5).
//
// Нет действующего кода (02 SCR-52.4, версия 1.28: `429 OTP_RATE_LIMITED` на номер, код которого вытеснен запросом на
// другой номер или очищен «Назад»): вместо «Код отправлен на …» — нейтральный `kiosk_code_wait` «Новый код можно
// получить через {seconds} с», поле кода недоступно, ошибки нет; по концу таймера — «Получить код».
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/kiosk_keypad.dart';
import 'package:optomstroy/design_system/components/otp_field.dart';
import 'package:optomstroy/design_system/formats/ds_phone_format.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Правая колонка шага «Код».
class KioskCodeStep extends StatefulWidget {
  const KioskCodeStep({
    required this.phoneE164,
    required this.digits,
    required this.resendAt,
    required this.now,
    required this.onDigit,
    required this.onBackspace,
    required this.onSend,
    required this.onResend,
    required this.onChangePhone,
    this.inputEnabled = true,
    this.hasCode = true,
    this.locked = false,
    this.sending = false,
    this.resending = false,
    this.codeError,
    this.message,
    super.key,
  });

  static const Key sentToKey = ValueKey<String>('kiosk-code-sent-to');
  static const Key waitKey = ValueKey<String>('kiosk-code-wait');
  static const Key fieldKey = ValueKey<String>('kiosk-code-field');
  static const Key timerKey = ValueKey<String>('kiosk-resend-timer');
  static const Key resendKey = ValueKey<String>('kiosk-resend');
  static const Key changePhoneKey = ValueKey<String>('kiosk-change-phone');
  static const Key sendKey = ValueKey<String>('kiosk-send-order');
  static const Key messageKey = ValueKey<String>('kiosk-code-message');

  /// Номер, на который запрошен код (`+996XXXXXXXXX`, только память) — показывается маской.
  final String phoneE164;

  /// Цифры кода (из памяти контроллера).
  final String digits;

  /// Когда доступна «Получить код» повторно (UTC); `null` — сразу.
  final DateTime? resendAt;

  /// Текущее время (UTC) — `clockProvider`.
  final DateTime Function() now;
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;

  /// «Отправить заявку»; `null` — недоступна (< 6 цифр, нет кода, нет связи, отправка).
  final VoidCallback? onSend;

  /// «Получить код» повторно (после таймера); `null` — недоступна.
  final VoidCallback? onResend;

  /// «Изменить номер»; `null` — недоступна (отправка).
  final VoidCallback? onChangePhone;

  /// Поле и клавиатура принимают ввод.
  final bool inputEnabled;

  /// В памяти есть действующий код (`challengeId`); `false` — `kiosk_code_wait`, поле недоступно (UI-52-008).
  final bool hasCode;

  /// `423 OTP_LOCKED` — поле кода недоступно.
  final bool locked;

  /// «Отправляем заявку…» — «Отправить заявку» в загрузке.
  final bool sending;

  /// Идёт повторный запрос кода.
  final bool resending;

  /// Текст под ячейками (`kiosk_code_invalid`, `kiosk_code_expired`); `null` — нет.
  final String? codeError;

  /// UI-52-014 над кнопкой (`kiosk_call_seller`, `kiosk_order_failed`); `null` — скрыто.
  final String? message;

  @override
  State<KioskCodeStep> createState() => _KioskCodeStepState();
}

class _KioskCodeStepState extends State<KioskCodeStep> {
  late final TextEditingController _code = TextEditingController(text: widget.digits);
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(KioskCodeStep oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_code.text != widget.digits) {
      _code.value = TextEditingValue(
        text: widget.digits,
        selection: TextSelection.collapsed(offset: widget.digits.length),
      );
    }
    if (oldWidget.resendAt != widget.resendAt) _syncTimer();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _code.dispose();
    super.dispose();
  }

  /// Секунды до повторного запроса (0 — доступен).
  int get _remaining {
    final DateTime? at = widget.resendAt;
    if (at == null) return 0;
    final int ms = at.difference(widget.now()).inMilliseconds;
    return ms <= 0 ? 0 : (ms + 999) ~/ 1000;
  }

  void _syncTimer() {
    _tick?.cancel();
    _tick = null;
    if (_remaining == 0) return;
    _tick = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      if (!mounted) return t.cancel();
      setState(() {});
      if (_remaining == 0) t.cancel();
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final int remaining = _remaining;
    final String? message = widget.message;
    final CodeFieldStatus status = widget.locked || !widget.hasCode
        ? CodeFieldStatus.disabled
        : widget.codeError != null && widget.digits.isEmpty
        ? CodeFieldStatus.error
        : CodeFieldStatus.idle;
    final Widget resend = remaining > 0
        ? Semantics(
            // Диктор — только на 10 с и 0 (03 §9.5); обновление каждую секунду без объявления.
            liveRegion: remaining == 10,
            child: Text(
              l10n.kiosk_resend_in(remaining),
              key: KioskCodeStep.timerKey,
              style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
            ),
          )
        : Semantics(
            liveRegion: true,
            child: AppButton(
              key: KioskCodeStep.resendKey,
              label: l10n.kiosk_get_code,
              variant: AppButtonVariant.text,
              // Цель 48 на сенсорном экране покупателя (03 A11Y-003).
              size: AppButtonSize.m,
              loading: widget.resending,
              onPressed: widget.onResend,
            ),
          );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.hasCode)
          Text(
            l10n.kiosk_code_sent_to(DsPhoneFormat.masked(widget.phoneE164)),
            key: KioskCodeStep.sentToKey,
            style: context.text.body.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
          )
        else if (remaining > 0)
          Text(
            l10n.kiosk_code_wait(remaining),
            key: KioskCodeStep.waitKey,
            style: context.text.body.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
          ),
        SizedBox(height: context.space.s3),
        Center(
          child: OtpField(
            key: KioskCodeStep.fieldKey,
            controller: _code,
            semanticLabel: l10n.kiosk_code_title,
            length: KioskKeypad.smsCodeLength,
            status: status,
            errorText: widget.codeError,
            autofocus: false,
          ),
        ),
        SizedBox(height: context.space.s2),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: context.space.s3,
          runSpacing: context.space.s2,
          children: <Widget>[
            resend,
            AppButton(
              key: KioskCodeStep.changePhoneKey,
              label: l10n.kiosk_change_phone,
              variant: AppButtonVariant.text,
              // Цель 48 на сенсорном экране покупателя (03 A11Y-003).
              size: AppButtonSize.m,
              onPressed: widget.onChangePhone,
            ),
          ],
        ),
        SizedBox(height: context.space.s3),
        Center(
          child: KioskKeypad(
            length: KioskKeypad.smsCodeLength,
            entered: widget.digits.length,
            onDigit: widget.onDigit,
            onBackspace: widget.onBackspace,
            backspaceLabel: l10n.qty_key_backspace_a11y,
            enabled: widget.inputEnabled && widget.hasCode && !widget.locked,
          ),
        ),
        SizedBox(height: context.space.s4),
        if (message != null) ...<Widget>[
          ErrorState.banner(key: KioskCodeStep.messageKey, message: message, tone: ErrorStateTone.warning),
          SizedBox(height: context.space.s3),
        ],
        AppButton(
          key: KioskCodeStep.sendKey,
          label: l10n.kiosk_send_order,
          size: AppButtonSize.l,
          expand: true,
          loading: widget.sending,
          onPressed: widget.onSend,
        ),
      ],
    );
  }
}
