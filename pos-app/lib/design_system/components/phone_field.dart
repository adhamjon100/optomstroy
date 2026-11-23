import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/private_input_scope.dart';
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
/// 9 цифр с маской `XXX XXX XXX`, вставка «0…», «996…», «+996…», «00996…» нормализуется; вставленный номер целиком
/// заменяет поле и поверх выделения, и в непустом поле (`DsPhoneEdit`).
/// [onChanged] получает E.164 `+996XXXXXXXXX` при 9 цифрах, иначе `null`.
///
/// В области «общее устройство» `PrivateInputScope` (03 §9.4, §9.74, редакция 1.19; DS-099, DS-101): без
/// `autofillHints` (`telephoneNumberNational` не объявляется), подсказок, обучения клавиатуры, выделения,
/// контекстного меню и вставки; системная клавиатура не открывается (`readOnly` + `TextInputType.none`) — цифры
/// вводит `KioskKeypad` в [controller] (маска `XXX XXX XXX` — `DsPhoneFormat.groupNational`); диктор слышит число
/// введённых цифр, а не номер (A11Y-023). Вне области — как прежде.
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

  /// Сигнал для правки `oldText` (курсор в конце) → `newText` до маски; `null` — ввод принят без потерь.
  /// То же, что [signalForEdit] со значениями без выделения.
  static PhoneInputSignal? signalFor(String oldText, String newText) => signalForEdit(
    TextEditingValue(
      text: oldText,
      selection: TextSelection.collapsed(offset: oldText.length),
    ),
    TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
    ),
  );

  /// Сигнал для правки `oldValue` → `newValue` до маски (с выделением прежнего значения); `null` — ввод принят
  /// без потерь. Правило разбора — `DsPhoneEdit` (03 §9.4): вставленный номер целиком «+996…», «00996…», «996…»,
  /// «0…» нормализуется без сигнала (и поверх выделения, и в непустое поле); «8…» длиннее 9 цифр или «+» / «00» с
  /// другим кодом страны — [PhoneInputSignal.unsupportedFormat]; больше 9 цифр после нормализации или набора —
  /// [PhoneInputSignal.tooLong].
  static PhoneInputSignal? signalForEdit(TextEditingValue oldValue, TextEditingValue newValue) =>
      _signalOf(DsPhoneEdit.of(oldValue, newValue));

  static PhoneInputSignal? _signalOf(DsPhoneEdit edit) {
    if (edit.unsupportedFormat) return PhoneInputSignal.unsupportedFormat;
    if (edit.overflow) return PhoneInputSignal.tooLong;
    return null;
  }

  /// Плейсхолдер маски.
  static const String placeholder = 'XXX XXX XXX';

  /// Что объявляет диктор в `PrivateInputScope` вместо номера (A11Y-023): число введённых цифр «n / 9».
  static String digitCountLabel(String text) =>
      '${DsPhoneFormat.nationalDigits(text)?.length ?? 0} / ${DsPhoneFormat.nationalLength}';

  @override
  Widget build(BuildContext context) {
    final bool auth = variant == PhoneFieldVariant.auth;
    final bool private = PrivateInputScope.of(context);
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
      keypadInput: private,
      semanticValueOf: private ? digitCountLabel : null,
      inputFormatters: <TextInputFormatter>[
        if (onInputSignal == null) const DsPhoneInputFormatter() else _SignalingPhoneFormatter(onInputSignal!),
      ],
      onFocusChange: onFocusChange,
      onChanged: onChanged == null ? null : (String v) => onChanged!(DsPhoneFormat.normalize(v)),
      onSubmitted: onSubmitted == null ? null : (String v) => onSubmitted!(DsPhoneFormat.normalize(v)),
    );
  }
}

/// Маска [DsPhoneInputFormatter] + сигнал [PhoneField.signalForEdit] (AU-04) — по одному разбору правки.
class _SignalingPhoneFormatter extends TextInputFormatter {
  _SignalingPhoneFormatter(this._onSignal);

  final ValueChanged<PhoneInputSignal> _onSignal;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final DsPhoneEdit edit = DsPhoneEdit.of(oldValue, newValue);
    final PhoneInputSignal? signal = PhoneField._signalOf(edit);
    if (signal != null) {
      // Форматтер вызывается во время обработки ввода: экран обновляется после неё.
      scheduleMicrotask(() => _onSignal(signal));
    }
    return edit.value;
  }
}
