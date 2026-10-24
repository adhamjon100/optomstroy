import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  /// Ошибка: всё `error` + shake, значение очищается.
  error,

  /// Успех: всё `success` (400 мс — длительность задаёт экран).
  success,

  /// Попытки исчерпаны / блокировка.
  disabled,
}

/// Ввод кода из SMS `OtpField` (03 §9.5): 6 ячеек 48×56 (44×52 при ширине < 328),
/// цифра `h2 24/600 tnum`, одно скрытое поле ввода; автопереход при 6-й цифре →
/// [onCompleted]; вставка 6 цифр; `autofillHints: oneTimeCode`. Код не логируется.
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
  });

  /// Подпись для screen reader («Код из SMS, 6 цифр»).
  final String semanticLabel;

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

  @override
  State<OtpField> createState() => _OtpFieldState();
}

class _OtpFieldState extends State<OtpField> with SingleTickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  FocusNode? _ownFocus;
  bool _focused = false;
  int _errors = 0;
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(OtpField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.status == CodeFieldStatus.error && oldWidget.status != CodeFieldStatus.error) {
      _errors++;
      _controller.clear();
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
    _ownFocus?.dispose();
    _controller.dispose();
    _pulse.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    setState(() {});
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

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool narrow = constraints.maxWidth < widget.length * 48 + (widget.length - 1) * 8;
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
                      child: Opacity(
                        opacity: 0,
                        child: ExcludeSemantics(
                          child: TextField(
                            controller: _controller,
                            focusNode: _focus,
                            enabled: inputEnabled,
                            autofocus: widget.autofocus,
                            showCursor: false,
                            enableInteractiveSelection: false,
                            keyboardType: TextInputType.number,
                            autofillHints: const <String>[AutofillHints.oneTimeCode],
                            inputFormatters: <TextInputFormatter>[
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(widget.length),
                            ],
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
              Semantics(
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
    final bool active = _focused && i == value.length && widget.status == CodeFieldStatus.idle;
    final (Color border, double width) = switch (widget.status) {
      CodeFieldStatus.error => (c.error, 2.0),
      CodeFieldStatus.success => (c.success, 2.0),
      CodeFieldStatus.disabled => (c.disabledText, 1.0),
      _ => active ? (c.primaryText, 2.0) : (c.borderStrong, 1.0),
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
