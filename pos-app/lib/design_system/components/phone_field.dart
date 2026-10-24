import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/formats/ds_phone_format.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Сигнал нормализации ввода `PhoneField` (03 §9.4; 02 SCR-01.4 п.5, SCR-01.8; D_spec_questions AU-04):
/// маска молча отбрасывает лишнее, а экран по сигналу показывает причину.
enum PhoneInputSignal {
  /// Цифр больше 9 (набор сверх маски или вставка длинной строки) — лишние отброшены
  /// (SCR-01: `auth_phone_error_long`).
  tooLong,

  /// Вставлен номер в неподдерживаемом формате: «8 (…)», чужой код страны (SCR-01: `auth_phone_error_format`).
  unsupportedFormat,
}

/// Вариант `PhoneField` (03 §9.4): `auth` — L 56, автофокус, крупный текст `h3 20/500`
/// (SCR-01); `form` — M 48.
enum PhoneFieldVariant { auth, form }

/// Ввод телефона Кыргызстана `PhoneField` (03 §9.4): нередактируемый префикс «+996»,
/// 9 цифр с маской `XXX XXX XXX`, вставка «0…», «996…», «+996…» нормализуется.
/// [onChanged] получает E.164 `+996XXXXXXXXX` при 9 цифрах, иначе `null`.
class PhoneField extends StatelessWidget {
  /// Создаёт поле телефона.
  const PhoneField({
    super.key,
    required this.semanticLabel,
    this.controller,
    this.focusNode,
    this.label,
    this.helper,
    this.errorText,
    this.variant = PhoneFieldVariant.form,
    this.enabled = true,
    this.loading = false,
    this.onChanged,
    this.onSubmitted,
    this.onFocusChange,
    this.autofocus,
    this.onInputSignal,
  });

  /// Подпись для screen reader («Номер телефона»).
  final String semanticLabel;

  /// Контроллер (значение — отображаемая строка `XXX XXX XXX`).
  final TextEditingController? controller;

  /// Узел фокуса.
  final FocusNode? focusNode;

  /// Подпись над полем.
  final String? label;

  /// Подсказка («9 цифр после +996»).
  final String? helper;

  /// Ошибка («Введите 9 цифр»).
  final String? errorText;

  /// Вариант.
  final PhoneFieldVariant variant;

  /// Доступно ли поле (disabled во время `verifying` и cooldown).
  final bool enabled;

  /// Отправка OTP: спиннер 16 в суффиксе.
  final bool loading;

  /// E.164 или `null`, пока номер неполный.
  final ValueChanged<String?>? onChanged;

  /// Enter → отправка (Windows), E.164 или `null`.
  final ValueChanged<String?>? onSubmitted;

  /// Фокус (персонаж `typing`).
  final ValueChanged<bool>? onFocusChange;

  /// Автофокус (по умолчанию — у варианта `auth`).
  final bool? autofocus;

  /// Ввод нормализован с потерей: переполнение или неподдерживаемый формат вставки (AU-04).
  /// Вызывается после применения маски (вне фазы построения).
  final ValueChanged<PhoneInputSignal>? onInputSignal;

  /// Сигнал для правки `oldText` → `newText` до маски; `null` — ввод принят без потерь.
  ///
  /// Вставка (> 1 символа) полного номера «+996…», «996…» (12 цифр) или «0…» (10 цифр) нормализуется
  /// без сигнала; вставка «8…» или с «+» и другим кодом страны — [PhoneInputSignal.unsupportedFormat];
  /// иначе больше 9 цифр — [PhoneInputSignal.tooLong].
  static PhoneInputSignal? signalFor(String oldText, String newText) {
    final String digits = newText.replaceAll(RegExp(r'\D'), '');
    if (digits.length <= DsPhoneFormat.nationalLength) return null;
    final bool paste = newText.length - oldText.length > 1;
    if (!paste) return PhoneInputSignal.tooLong;
    const String cc = DsPhoneFormat.countryCode;
    if (digits.length == DsPhoneFormat.nationalLength + cc.length && digits.startsWith(cc)) return null;
    if (digits.length == DsPhoneFormat.nationalLength + 1 && digits.startsWith('0')) return null;
    final bool plus = newText.trimLeft().startsWith('+');
    if (digits.startsWith('8') || (plus && !digits.startsWith(cc))) return PhoneInputSignal.unsupportedFormat;
    return PhoneInputSignal.tooLong;
  }

  /// Плейсхолдер маски.
  static const String placeholder = 'XXX XXX XXX';

  @override
  Widget build(BuildContext context) {
    final bool auth = variant == PhoneFieldVariant.auth;
    final TextStyle base = (auth ? context.text.h3.copyWith(fontWeight: FontWeight.w500) : context.text.bodyLg)
        .copyWith(fontFeatures: DsTypography.numeric);
    return AppTextField(
      controller: controller,
      focusNode: focusNode,
      label: label,
      hint: placeholder,
      helper: helper,
      errorText: errorText,
      semanticLabel: semanticLabel,
      size: auth ? AppTextFieldSize.l : AppTextFieldSize.m,
      prefixText: '+${DsPhoneFormat.countryCode}',
      prefixStyle: base.copyWith(fontWeight: FontWeight.w500, color: context.colors.textSecondary),
      textStyle: base,
      withClear: true,
      loading: loading,
      enabled: enabled,
      autofocus: autofocus ?? auth,
      keyboardType: TextInputType.phone,
      textInputAction: TextInputAction.done,
      autofillHints: const <String>[AutofillHints.telephoneNumberNational],
      inputFormatters: <TextInputFormatter>[
        if (onInputSignal == null) const DsPhoneInputFormatter() else _SignalingPhoneFormatter(onInputSignal!),
      ],
      onFocusChange: onFocusChange,
      onChanged: onChanged == null ? null : (String v) => onChanged!(DsPhoneFormat.normalize(v)),
      onSubmitted: onSubmitted == null ? null : (String v) => onSubmitted!(DsPhoneFormat.normalize(v)),
    );
  }
}

/// Маска [DsPhoneInputFormatter] + сигнал [PhoneField.signalFor] (AU-04).
class _SignalingPhoneFormatter extends TextInputFormatter {
  _SignalingPhoneFormatter(this._onSignal);

  final ValueChanged<PhoneInputSignal> _onSignal;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final PhoneInputSignal? signal = PhoneField.signalFor(oldValue.text, newValue.text);
    if (signal != null) {
      // Форматтер вызывается во время обработки ввода: экран обновляется после неё.
      scheduleMicrotask(() => _onSignal(signal));
    }
    return const DsPhoneInputFormatter().formatEditUpdate(oldValue, newValue);
  }
}
