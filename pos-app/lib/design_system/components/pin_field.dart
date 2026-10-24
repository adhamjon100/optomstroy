import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/otp_field.dart';
import 'package:optomstroy/design_system/motion/ds_animations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Ввод PIN приложения `PinField` (03 §9.6; D-13, D-48): ряд точек (диаметр 16, зазор 16;
/// заполненная — `primaryText`, пустая — обводка `borderStrong` 2 px), скрытое поле для
/// физической клавиатуры, экранный нампад 3×4 (клавиши 72×56, цифры `h2 24/500 tnum`).
/// Цифры не отображаются; попытки не считаются клиентом (только `attemptsLeft` сервера).
/// Режим `setup` (два прохода) реализует экран, вызывая поле дважды.
class PinField extends StatefulWidget {
  /// Создаёт поле PIN.
  const PinField({
    super.key,
    required this.length,
    required this.semanticLabel,
    required this.backspaceLabel,
    this.status = CodeFieldStatus.idle,
    this.errorText,
    this.biometricLabel,
    this.onBiometric,
    this.footer,
    this.onCompleted,
    this.showNumpad = true,
    this.autofocus = true,
  }) : assert(length >= 4 && length <= 6, 'PIN — 4…6 цифр (09 §9.6)');

  /// Длина PIN по политике роли (`staff` — 6, `customer` — 4).
  final int length;

  /// Подпись для screen reader: «PIN, введено {n} из {len}».
  final String Function(int entered, int length) semanticLabel;

  /// Подпись клавиши «Стереть».
  final String backspaceLabel;

  /// Состояние.
  final CodeFieldStatus status;

  /// «Неверный PIN. Осталось попыток: 2» (из ответа сервера).
  final String? errorText;

  /// Подпись клавиши «Биометрия» (только SCR-08; в `StepUpDialog` R1 — скрыта).
  final String? biometricLabel;

  /// Действие клавиши «Биометрия»; `null` — клавиша скрыта.
  final VoidCallback? onBiometric;

  /// Ссылка «Забыли PIN? Войти по SMS» и т. п.
  final Widget? footer;

  /// Введены все цифры (автопроверка).
  final ValueChanged<String>? onCompleted;

  /// Показывать экранный нампад.
  final bool showNumpad;

  /// Автофокус скрытого поля (ввод с физической клавиатуры).
  final bool autofocus;

  @override
  State<PinField> createState() => _PinFieldState();
}

class _PinFieldState extends State<PinField> with SingleTickerProviderStateMixin {
  final FocusNode _focus = FocusNode(debugLabel: 'PinField');
  String _value = '';
  int _errors = 0;
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));

  bool get _inputEnabled => widget.status == CodeFieldStatus.idle || widget.status == CodeFieldStatus.error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(PinField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.status == CodeFieldStatus.error && oldWidget.status != CodeFieldStatus.error) {
      _errors++;
      _value = '';
    }
    if (widget.status != oldWidget.status) {
      _syncPulse();
    }
  }

  void _syncPulse() {
    if (widget.status == CodeFieldStatus.loading && !context.motion.reduceMotion) {
      if (!_pulse.isAnimating) {
        unawaited(_pulse.repeat(reverse: true));
      }
    } else {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _pulse.dispose();
    super.dispose();
  }

  void _add(String digit) {
    if (!_inputEnabled || _value.length >= widget.length) {
      return;
    }
    setState(() => _value += digit);
    if (_value.length == widget.length) {
      widget.onCompleted?.call(_value);
    }
  }

  void _backspace() {
    if (!_inputEnabled || _value.isEmpty) {
      return;
    }
    setState(() => _value = _value.substring(0, _value.length - 1));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final String? ch = event.character;
    if (ch != null && RegExp(r'^\d$').hasMatch(ch)) {
      _add(ch);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _backspace();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final List<Widget> dots = <Widget>[];
    for (int i = 0; i < widget.length; i++) {
      if (i > 0) {
        dots.add(const SizedBox(width: 16));
      }
      dots.add(_dot(c, i < _value.length));
    }
    Widget row = Row(mainAxisSize: MainAxisSize.min, children: dots);
    if (widget.status == CodeFieldStatus.loading && !context.motion.reduceMotion) {
      row = FadeTransition(opacity: Tween<double>(begin: 1, end: 0.6).animate(_pulse), child: row);
    }
    return Focus(
      focusNode: _focus,
      autofocus: widget.autofocus,
      onKeyEvent: _onKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Semantics(
            label: widget.semanticLabel(_value.length, widget.length),
            obscured: true,
            liveRegion: false,
            child: ExcludeSemantics(
              child: SizedBox(
                height: 24,
                child: Center(
                  widthFactor: 1,
                  child: DsShake(trigger: _errors, child: row),
                ),
              ),
            ),
          ),
          if (widget.errorText != null) ...<Widget>[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                widget.errorText!,
                textAlign: TextAlign.center,
                style: context.text.label.copyWith(color: c.error),
              ),
            ),
          ],
          if (widget.showNumpad) ...<Widget>[const SizedBox(height: 24), _numpad(c)],
          if (widget.footer != null) ...<Widget>[const SizedBox(height: 16), widget.footer!],
        ],
      ),
    );
  }

  Widget _dot(DsColors c, bool filled) {
    final Color color = switch (widget.status) {
      CodeFieldStatus.error => c.error,
      CodeFieldStatus.success => c.success,
      CodeFieldStatus.disabled => c.disabledText,
      _ => filled ? c.primaryText : c.borderStrong,
    };
    final bool solid = filled || widget.status == CodeFieldStatus.error || widget.status == CodeFieldStatus.success;
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: solid ? color : Colors.transparent,
        border: Border.all(color: color, width: 2),
      ),
    );
  }

  Widget _numpad(DsColors c) {
    Widget key(String digit) => _PadKey(
      label: digit,
      enabled: _inputEnabled,
      onTap: () => _add(digit),
      child: Text(
        digit,
        style: context.text.h2.copyWith(
          fontWeight: FontWeight.w500,
          fontFeatures: DsTypography.numeric,
          color: _inputEnabled ? c.textPrimary : c.disabledText,
        ),
      ),
    );
    Widget row(List<Widget> keys) => Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < keys.length; i++) ...<Widget>[if (i > 0) const SizedBox(width: 12), keys[i]],
      ],
    );
    final Widget bio = widget.onBiometric == null
        ? const SizedBox(width: 72, height: 56)
        : _PadKey(
            label: widget.biometricLabel ?? '',
            enabled: widget.status != CodeFieldStatus.loading,
            onTap: widget.onBiometric!,
            child: Icon(Icons.fingerprint_rounded, size: 28, color: c.primaryText),
          );
    final Widget back = _PadKey(
      label: widget.backspaceLabel,
      enabled: _inputEnabled && _value.isNotEmpty,
      onTap: _backspace,
      child: Icon(Icons.backspace_outlined, size: 24, color: c.textSecondary),
    );
    return SizedBox(
      width: 300,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          row(<Widget>[key('1'), key('2'), key('3')]),
          const SizedBox(height: 8),
          row(<Widget>[key('4'), key('5'), key('6')]),
          const SizedBox(height: 8),
          row(<Widget>[key('7'), key('8'), key('9')]),
          const SizedBox(height: 8),
          row(<Widget>[bio, key('0'), back]),
        ],
      ),
    );
  }
}

/// Клавиша нампада 72×56: hover `surfaceVariant`, pressed `surfacePressed` + scale .96 (ANIM-015).
class _PadKey extends StatelessWidget {
  const _PadKey({required this.label, required this.enabled, required this.onTap, required this.child});

  final String label;
  final bool enabled;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final Duration fast = context.motion.of(context.motion.fast);
    final BorderRadius radius = BorderRadius.all(context.radii.md);
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: DsInteractive(
        enabled: enabled,
        onTap: onTap,
        builder: (BuildContext context, DsInteractionState s) => DsFocusRing(
          visible: s.focused,
          borderRadius: radius,
          child: AnimatedScale(
            scale: s.pressed ? 0.96 : 1,
            duration: fast,
            child: AnimatedContainer(
              duration: fast,
              width: 72,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceVariant : Colors.transparent),
                borderRadius: radius,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
