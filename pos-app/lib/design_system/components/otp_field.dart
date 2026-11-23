import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:optomstroy/design_system/components/private_input_scope.dart';
import 'package:optomstroy/design_system/formats/ds_text_edit.dart';
import 'package:optomstroy/design_system/motion/ds_animations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Состояние `OtpField` / `PinField` (03 §9.5, §9.6).
enum CodeFieldStatus {
  /// Ввод.
  idle,

  /// Проверка: ячейки/точки пульсируют, ввод заблокирован.
  loading,

  /// Ошибка: всё `error` + shake, значение очищается. Красный — только момент ошибки (03 §9.5, §9.6 ред. 1.24): до первой
  /// новой цифры, у `PinField` — не дольше 300 мс; ввод доступен, текст ошибки виден.
  error,

  /// Успех: всё `success` (400 мс — длительность задаёт экран).
  success,

  /// Попытки исчерпаны / блокировка.
  disabled,
}

/// Ввод кода из SMS `OtpField` (03 §9.5): 6 ячеек 48×56 (44×52 при ширине < 328 и при [dense]),
/// цифра `h2 24/600 tnum`, одно скрытое поле ввода; автопереход при 6-й цифре →
/// [onCompleted]; `autofillHints: oneTimeCode`. Код не логируется. Ячейка — обводка 1 px `borderStrong`; активная
/// (поле в фокусе, следующая цифра) — 2 px нейтральная `textPrimary` (16,8 : 1 к `surface`; не фирменная
/// `primaryText` — её почти не отличить от `error`; Q-357, пакет wave2:APP-POLISH).
///
/// Вставка (02 SCR-02.4 п. 5; 09 §4.4): `Ctrl+V`, «Вставить» меню по правой кнопке, долгое нажатие → «Вставить»,
/// вставка браузера, подсказка клавиатуры и автозаполнение — [OtpInputFormatter]: во вставленном фрагменте не меньше
/// [length] цифр — код = первые [length] цифр фрагмента («481 903» → «481903», «Kod: 481903. Optomstroy» →
/// «481903»), даже если часть ячеек уже заполнена; меньше — цифры дописываются, как при наборе. Для вставки у
/// скрытого поля включено выделение, но его не видно: ручек нет, лупы нет, каретка всегда в конце — ячейки
/// заполняются без «дыр» (п. 4).
///
/// Ошибка ([CodeFieldStatus.error]; 03 §9.5 ред. 1.24): ячейки очищаются, все `error` + shake ANIM-012 — до первой новой
/// цифры; дальше ячейки обычные, даже если экран ещё держит статус `error` (новая цифра красной не бывает), текст
/// ошибки — как передал экран.
///
/// В области «общее устройство» `PrivateInputScope` (03 §9.5, §9.74, редакция 1.19; DS-099, DS-101): без
/// `autofillHints: oneTimeCode` (и SMS Retriever), подсказок и обучения клавиатуры, выделения, контекстного меню;
/// вставки нет (буфер обмена не читается); системная клавиатура не открывается (`readOnly` + `TextInputType.none`) —
/// цифры и стирание вводит `KioskKeypad` в [controller]; что делать после 6-й цифры, решает экран.
class OtpField extends StatefulWidget {
  /// Создаёт поле.
  const OtpField({
    super.key,
    required this.semanticLabel,
    this.length = 6,
    this.status = CodeFieldStatus.idle,
    this.errorText,
    this.footer,
    this.onCompleted,
    this.onChanged,
    this.onFocusChange,
    this.autofocus = true,
    this.focusNode,
    this.controller,
    this.dense = false,
  });

  /// Подпись для screen reader («Код из SMS, 6 цифр»).
  final String semanticLabel;

  /// Ячейки 44×52 при любой ширине — окно малой высоты (02 SCR-02.12: ландшафт, высота < 420).
  final bool dense;

  /// Длина кода (R1 — 6; 4 зарезервировано).
  final int length;

  /// Состояние.
  final CodeFieldStatus status;

  /// Текст ошибки под ячейками («Неверный код»), объявляется `liveRegion`.
  final String? errorText;

  /// Таймер «Отправить код повторно через 0:59» / кнопка / счётчик попыток (передаёт экран).
  final Widget? footer;

  /// Введены все цифры.
  final ValueChanged<String>? onCompleted;

  /// Изменение значения.
  final ValueChanged<String>? onChanged;

  /// Фокус (персонаж `typing`).
  final ValueChanged<bool>? onFocusChange;

  /// Автофокус.
  final bool autofocus;

  /// Узел фокуса скрытого поля.
  final FocusNode? focusNode;

  /// Значение кода, которое задаёт экран (`KioskKeypad` в `PrivateInputScope`); ячейки обновляются при каждом его
  /// изменении, [onChanged] / [onCompleted] — только для ввода в само поле. Переход в [CodeFieldStatus.error] очищает
  /// и его. `null` — контроллер внутри поля, как прежде.
  final TextEditingController? controller;

  @override
  State<OtpField> createState() => _OtpFieldState();
}

class _OtpFieldState extends State<OtpField> with SingleTickerProviderStateMixin {
  /// Ручки выделения нулевого размера: меню поля (`contextMenuBuilder`) остаётся, ручек над ячейками нет.
  static final TextSelectionControls _hiddenHandles = _HiddenHandleControls();

  TextEditingController? _ownController;
  FocusNode? _ownFocus;
  bool _focused = false;
  bool _private = false;
  int _errors = 0;
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));

  /// Ячейки показывают ошибку (`error`): от перехода в [CodeFieldStatus.error] до первой новой цифры (03 §9.5 ред. 1.24;
  /// указание владельца 2026-11-18, 15 §5.8). Новый ввод после ошибки — обычные ячейки с активной, даже если экран ещё
  /// держит статус `error` (step-up по коду из SMS); текст ошибки — как передал экран.
  bool _errorShown = false;

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());
  TextEditingController get _controller => widget.controller ?? (_ownController ??= TextEditingController());

  @override
  void initState() {
    super.initState();
    _errorShown = widget.status == CodeFieldStatus.error;
    _focus.addListener(_onFocus);
    widget.controller?.addListener(_onExternalText);
    _controller.addListener(_keepCaretAtEnd);
  }

  /// Значение задал экран (`KioskKeypad`): перерисовать ячейки; первая новая цифра снимает красный цвет ошибки.
  void _onExternalText() {
    if (!mounted) return;
    setState(() {
      if (_controller.text.isNotEmpty) _errorShown = false;
    });
  }

  /// Вне `PrivateInputScope` выделение скрытого поля включено ради вставки, но ячейки показывают код без «дыр»
  /// (02 SCR-02.4 п. 4): тап, перетаскивание, `Ctrl+A`, стрелки и долгое нажатие не оставляют выделения —
  /// каретка возвращается в конец.
  void _keepCaretAtEnd() {
    if (_private) return;
    final TextEditingController c = _controller;
    final TextSelection sel = c.selection;
    final int end = c.text.length;
    if (!sel.isValid || (sel.isCollapsed && sel.baseOffset == end)) return;
    c.selection = TextSelection.collapsed(offset: end);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _private = PrivateInputScope.of(context);
    _syncPulse();
  }

  @override
  void didUpdateWidget(OtpField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? _ownController)?.removeListener(_keepCaretAtEnd);
      oldWidget.controller?.removeListener(_onExternalText);
      widget.controller?.addListener(_onExternalText);
      _controller.addListener(_keepCaretAtEnd);
    }
    if (widget.status == CodeFieldStatus.error && oldWidget.status != CodeFieldStatus.error) {
      _errors++;
      _errorShown = true;
      _controller.clear();
    } else if (widget.status != CodeFieldStatus.error) {
      _errorShown = false;
    }
    if (widget.status != oldWidget.status) {
      _syncPulse();
    }
  }

  void _syncPulse() {
    final bool reduce = context.motion.reduceMotion;
    if (widget.status == CodeFieldStatus.loading && !reduce) {
      if (_pulse.isAnimating) {
        return;
      }
      unawaited(_pulse.repeat(reverse: true));
    } else {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  void _onFocus() {
    setState(() => _focused = _focus.hasFocus);
    widget.onFocusChange?.call(_focus.hasFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    widget.controller?.removeListener(_onExternalText);
    (widget.controller ?? _ownController)?.removeListener(_keepCaretAtEnd);
    _ownFocus?.dispose();
    _ownController?.dispose();
    _pulse.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    setState(() {
      if (v.isNotEmpty) _errorShown = false;
    });
    widget.onChanged?.call(v);
    if (v.length == widget.length) {
      widget.onCompleted?.call(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool reduce = context.motion.reduceMotion;
    final bool inputEnabled = widget.status == CodeFieldStatus.idle || widget.status == CodeFieldStatus.error;
    final String value = _controller.text;
    // Область «общее устройство» (03 §9.74, DS-099): вне неё значения TextField — прежние.
    final bool private = PrivateInputScope.of(context);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool narrow = widget.dense || constraints.maxWidth < widget.length * 48 + (widget.length - 1) * 8;
        final double w = narrow ? 44 : 48;
        final double h = narrow ? 52 : 56;
        final List<Widget> cells = <Widget>[];
        for (int i = 0; i < widget.length; i++) {
          if (i > 0) {
            cells.add(const SizedBox(width: 8));
          }
          cells.add(_cell(c, i, value, w, h));
        }
        Widget row = Row(mainAxisSize: MainAxisSize.min, children: cells);
        if (widget.status == CodeFieldStatus.loading && !reduce) {
          row = FadeTransition(opacity: Tween<double>(begin: 1, end: 0.6).animate(_pulse), child: row);
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Semantics(
              label: widget.semanticLabel,
              value: '${value.length} / ${widget.length}',
              textField: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: inputEnabled ? _focus.requestFocus : null,
                child: Stack(
                  children: <Widget>[
                    DsShake(trigger: _errors, child: row),
                    Positioned.fill(
                      // Скрытое поле невидимо, но рисуется: меню поля («Вставить» по правой кнопке и долгому
                      // нажатию) привязано к слою поля (`CompositedTransformFollower`, `showWhenUnlinked: false`) и
                      // при `Opacity(0)` не показывалось и не нажималось. Фильтр заменяет каждый пиксель прозрачным.
                      child: ColorFiltered(
                        colorFilter: const ColorFilter.mode(Colors.transparent, BlendMode.src),
                        child: ExcludeSemantics(
                          child: TextField(
                            controller: _controller,
                            focusNode: _focus,
                            enabled: inputEnabled,
                            readOnly: private,
                            autofocus: widget.autofocus,
                            showCursor: false,
                            // Вне области выделение включено ради вставки (02 SCR-02.4 п. 5): без него движок web
                            // глушит событие `paste`, а `Ctrl+V` и «Вставить» Windows и Android не срабатывают.
                            // Выделения не видно: поле прозрачно, ручки нулевые, лупы нет, каретка — в конце.
                            enableInteractiveSelection: !private,
                            selectionControls: private ? null : _hiddenHandles,
                            magnifierConfiguration: private ? null : TextMagnifierConfiguration.disabled,
                            enableSuggestions: !private,
                            autocorrect: private ? false : null,
                            enableIMEPersonalizedLearning: !private,
                            contextMenuBuilder: PrivateInputScope.contextMenuBuilderFor(private: private),
                            keyboardType: private ? TextInputType.none : TextInputType.number,
                            autofillHints: private ? null : const <String>[AutofillHints.oneTimeCode],
                            inputFormatters: <TextInputFormatter>[OtpInputFormatter(widget.length)],
                            decoration: const InputDecoration(border: InputBorder.none, counterText: ''),
                            onChanged: _onChanged,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (widget.errorText != null) ...<Widget>[
              const SizedBox(height: 8),
              // Отдельный узел: текст ошибки не сливается с подписью и значением поля — диктор объявляет его один
              // раз, а не на каждой цифре (03 §9.5 ред. 1.24 «Доступность»).
              Semantics(
                container: true,
                liveRegion: true,
                child: Text(widget.errorText!, style: context.text.label.copyWith(color: c.error)),
              ),
            ],
            if (widget.footer != null) ...<Widget>[const SizedBox(height: 12), widget.footer!],
          ],
        );
      },
    );
  }

  Widget _cell(DsColors c, int i, String value, double w, double h) {
    final bool filled = i < value.length;
    // После ошибки и первой новой цифры статус `error` ячейки не красит — ввод выглядит как обычный (с активной ячейкой).
    final bool error = widget.status == CodeFieldStatus.error && _errorShown;
    final bool typing = widget.status == CodeFieldStatus.idle || (widget.status == CodeFieldStatus.error && !error);
    final bool active = _focused && i == value.length && typing;
    // Активная ячейка — нейтральная `textPrimary` 2 px, как заполненная точка `PinField` (Q-357): фирменная `primaryText`
    // #C9330C почти совпадала с ошибкой `error` #D21B1F (1,01 : 1), и после 300 мс ошибки следующая ячейка выглядела
    // «красной» (сообщение владельца 2026-11-18 о точках PIN — та же причина). Красный — только момент ошибки.
    final (Color border, double width) = switch (widget.status) {
      CodeFieldStatus.error when error => (c.error, 2.0),
      CodeFieldStatus.success => (c.success, 2.0),
      CodeFieldStatus.disabled => (c.disabledText, 1.0),
      _ => active ? (c.textPrimary, 2.0) : (c.borderStrong, 1.0),
    };
    final TextStyle digit = context.text.h2.copyWith(
      fontFeatures: DsTypography.numeric,
      color: widget.status == CodeFieldStatus.disabled ? c.disabledText : c.textPrimary,
    );
    return Container(
      width: w,
      height: h,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: widget.status == CodeFieldStatus.disabled ? c.disabledBg : c.surface,
        borderRadius: BorderRadius.all(context.radii.sm),
        border: Border.all(color: border, width: width),
      ),
      child: Text(
        filled ? value[i] : '•',
        textScaler: TextScaler.noScaling,
        style: filled ? digit : digit.copyWith(color: c.textTertiary, fontWeight: FontWeight.w400),
      ),
    );
  }
}

/// Маска скрытого поля `OtpField` (02 SCR-02.4 п. 3, п. 5; 09 §4.4): только цифры, не больше [length].
///
/// Вставленный фрагмент ([DsTextEdit]: `Ctrl+V`, «Вставить», вставка браузера, подсказка клавиатуры, автозаполнение)
/// с [length] цифрами и больше заменяет код первыми [length] цифрами фрагмента — и в пустом, и в частично заполненном
/// поле: «12» + «246810» → «246810», а не «122468» с автоотправкой неверного кода. Пробелы, дефисы и текст SMS
/// отбрасываются. Иначе (набор, вставка меньше [length] цифр, стирание) — как прежде: цифры дописываются, лишние
/// отбрасываются (`FilteringTextInputFormatter.digitsOnly` + `LengthLimitingTextInputFormatter`).
class OtpInputFormatter extends TextInputFormatter {
  /// Создаёт маску кода длины [length].
  OtpInputFormatter(this.length) : _limit = LengthLimitingTextInputFormatter(length);

  /// Длина кода.
  final int length;

  final LengthLimitingTextInputFormatter _limit;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final String pasted = DsTextEdit.digitsOf(DsTextEdit.of(oldValue, newValue).inserted);
    if (pasted.length >= length) {
      final String code = pasted.substring(0, length);
      return TextEditingValue(
        text: code,
        selection: TextSelection.collapsed(offset: code.length),
      );
    }
    return _limit.formatEditUpdate(
      oldValue,
      FilteringTextInputFormatter.digitsOnly.formatEditUpdate(oldValue, newValue),
    );
  }
}

/// Ручки выделения нулевого размера; меню поля строит `contextMenuBuilder` (`TextSelectionHandleControls`).
class _HiddenHandleControls extends EmptyTextSelectionControls with TextSelectionHandleControls {}
