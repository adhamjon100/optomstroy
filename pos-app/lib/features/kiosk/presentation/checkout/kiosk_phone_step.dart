// SCR-52 шаг «Телефон» (02 ч. F SCR-52.3, SCR-52.4; 03 §9.4, §9.74, DS-101, DS-102, A11Y-023; 13 TAB-2-04):
// поле номера UI-52-005 (`PhoneField` в `PrivateInputScope` — `readOnly`, системная клавиатура не открывается),
// экранная клавиатура UI-52-006 (`KioskKeypad`, 9 цифр), сообщение UI-52-014 и «Получить код» UI-52-007; текст
// информирования UI-52-003 и лист «Подробнее» UI-52-004 (`kiosk_order_notice` версии [kioskNoticeVersion], 11 PRIV-032;
// отметки «Я ознакомлен(а)» нет — P-002 §14.4).
//
// Значение номера хранит контроллер оформления (только память); поле показывает его маской `XXX XXX XXX`, диктор
// слышит число цифр, а не номер (A11Y-023). Номер не логируется.
import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/kiosk_keypad.dart';
import 'package:optomstroy/design_system/components/phone_field.dart';
import 'package:optomstroy/design_system/formats/ds_phone_format.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';

/// Правая колонка шага «Телефон».
class KioskPhoneStep extends StatefulWidget {
  const KioskPhoneStep({
    required this.digits,
    required this.onDigit,
    required this.onBackspace,
    required this.onCleared,
    required this.onGetCode,
    this.requesting = false,
    this.inputEnabled = true,
    this.message,
    super.key,
  });

  static const Key fieldKey = ValueKey<String>('kiosk-phone-field');
  static const Key getCodeKey = ValueKey<String>('kiosk-get-code');
  static const Key messageKey = ValueKey<String>('kiosk-phone-message');

  /// Цифры номера после «+996» (из памяти контроллера).
  final String digits;
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;

  /// «×» в поле — поле очищено.
  final VoidCallback onCleared;

  /// «Получить код»; `null` — недоступна (< 9 цифр, загрузка суммы, нет связи, состояние планшета, отправка).
  final VoidCallback? onGetCode;

  /// Идёт `POST /kiosk/order-otp` — кнопка в загрузке.
  final bool requesting;

  /// Поле и клавиатура принимают ввод.
  final bool inputEnabled;

  /// UI-52-014 над кнопкой (`kiosk_call_seller`, `kiosk_order_failed`); `null` — скрыто.
  final String? message;

  @override
  State<KioskPhoneStep> createState() => _KioskPhoneStepState();
}

class _KioskPhoneStepState extends State<KioskPhoneStep> {
  late final TextEditingController _phone = TextEditingController(text: _masked(widget.digits));

  static String _masked(String digits) => DsPhoneFormat.groupNational(digits);

  @override
  void didUpdateWidget(KioskPhoneStep oldWidget) {
    super.didUpdateWidget(oldWidget);
    final String text = _masked(widget.digits);
    if (_phone.text != text) {
      _phone.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String? message = widget.message;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        PhoneField(
          key: KioskPhoneStep.fieldKey,
          controller: _phone,
          semanticLabel: l10n.kiosk_phone_title,
          variant: PhoneFieldVariant.auth,
          autofocus: false,
          enabled: widget.inputEnabled,
          // В области приватного ввода значение меняет только экран; вызов приходит от «×» — поле очищено.
          onChanged: (String? _) {
            if (_phone.text.isEmpty) widget.onCleared();
          },
        ),
        SizedBox(height: context.space.s4),
        Center(
          child: KioskKeypad(
            length: KioskKeypad.phoneLength,
            entered: widget.digits.length,
            onDigit: widget.onDigit,
            onBackspace: widget.onBackspace,
            backspaceLabel: l10n.qty_key_backspace_a11y,
            enabled: widget.inputEnabled,
          ),
        ),
        SizedBox(height: context.space.s4),
        if (message != null) ...<Widget>[
          ErrorState.banner(key: KioskPhoneStep.messageKey, message: message, tone: ErrorStateTone.warning),
          SizedBox(height: context.space.s3),
        ],
        AppButton(
          key: KioskPhoneStep.getCodeKey,
          label: l10n.kiosk_get_code,
          size: AppButtonSize.l,
          expand: true,
          loading: widget.requesting,
          onPressed: widget.onGetCode,
        ),
      ],
    );
  }
}

/// Текст информирования UI-52-003: первый абзац раздела `kiosk_order_notice` (`kiosk_notice_short`) и «Подробнее».
class KioskNoticeBlock extends StatelessWidget {
  const KioskNoticeBlock({super.key});

  static const Key textKey = ValueKey<String>('kiosk-notice-short');
  static const Key moreKey = ValueKey<String>('kiosk-notice-more');

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          l10n.kiosk_notice_short,
          key: textKey,
          style: context.text.body.copyWith(color: context.colors.textSecondary),
        ),
        SizedBox(height: context.space.s1),
        AppButton(
          key: moreKey,
          label: l10n.kiosk_notice_more,
          variant: AppButtonVariant.text,
          // Покупатель на сенсорном экране: цель 48 (03 A11Y-003; размер S с целью 44 на планшете не применяется).
          size: AppButtonSize.m,
          onPressed: () => showKioskNoticeSheet(context),
        ),
      ],
    );
  }
}

/// Ключ текста листа «Подробнее» (тесты).
const Key kioskNoticeFullKey = ValueKey<String>('kiosk-notice-full');

/// Ключ «Закрыть» листа «Подробнее» (тесты).
const Key kioskNoticeCloseKey = ValueKey<String>('kiosk-notice-close');

/// Лист «Подробнее» UI-52-004: `side` 480 справа на expanded / large, `fullHeight` снизу на medium; заголовок
/// `kiosk_notice_full_title`, полный текст той же версии (`kiosk_notice_full`), «Закрыть»; закрытие — и Esc, «Назад»,
/// тап вне листа.
Future<void> showKioskNoticeSheet(BuildContext context) {
  final AppLocalizations l10n = AppLocalizations.of(context);
  final bool wide = switch (context.windowClass) {
    WindowClass.expanded || WindowClass.large => true,
    WindowClass.compact || WindowClass.medium => false,
  };
  final Widget body = Text(
    l10n.kiosk_notice_full,
    key: kioskNoticeFullKey,
    style: context.text.body.copyWith(color: context.colors.textPrimary),
  );
  Widget footer(BuildContext context) => AppButton(
    key: kioskNoticeCloseKey,
    label: l10n.ds_button_close,
    variant: AppButtonVariant.secondary,
    size: AppButtonSize.l,
    expand: true,
    onPressed: () => Navigator.of(context).maybePop(),
  );
  if (wide) {
    return AppBottomSheet.showSide<void>(
      context,
      title: l10n.kiosk_notice_full_title,
      width: AppBottomSheet.sideExpanded,
      body: body,
      footer: Builder(builder: footer),
    );
  }
  return AppBottomSheet.show<void>(
    context,
    title: l10n.kiosk_notice_full_title,
    variant: AppBottomSheetVariant.fullHeight,
    body: body,
    footer: Builder(builder: footer),
  );
}
