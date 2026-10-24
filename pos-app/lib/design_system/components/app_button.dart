import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Варианты `AppButton` (03 §9.1). `secondary` = `tonal`.
enum AppButtonVariant { primary, secondary, tonal, outlined, text, danger, success }

/// Размеры `AppButton` (03 §7.4): S 36 / M 44 / L 52; тач-цель 44 / 48 / 52.
enum AppButtonSize {
  /// Инлайн-действия в таблицах.
  s(height: 36, target: 44, padding: 12, icon: 20, spinner: 16),

  /// Стандартная кнопка.
  m(height: 44, target: 48, padding: 16, icon: 20, spinner: 16),

  /// CTA.
  l(height: 52, target: 52, padding: 24, icon: 24, spinner: 20);

  const AppButtonSize({
    required this.height,
    required this.target,
    required this.padding,
    required this.icon,
    required this.spinner,
  });

  /// Визуальная высота.
  final double height;

  /// Высота тач-цели.
  final double target;

  /// Горизонтальный паддинг.
  final double padding;

  /// Размер иконки.
  final double icon;

  /// Размер спиннера в `loading`.
  final double spinner;
}

/// Кнопка `AppButton` (03 §9.1).
///
/// Палитра B (DS-098): `primary` — заливка #FF8700 с тёмным `onPrimary`; `outlined`/`text`/`tonal` —
/// текст `primaryText`; `danger`/`success` — белый текст на `error`/`success`.
class AppButton extends StatelessWidget {
  /// Создаёт кнопку.
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.size = AppButtonSize.m,
    this.icon,
    this.trailingIcon,
    this.loading = false,
    this.expand = false,
    this.focusNode,
    this.autofocus = false,
    this.semanticLabel,
    this.fitLabel = false,
  });

  /// Текст (глагол: «Создать заказ», «Получить код»).
  final String label;

  /// Действие; `null` — кнопка недоступна.
  final VoidCallback? onPressed;

  /// Вариант.
  final AppButtonVariant variant;

  /// Размер.
  final AppButtonSize size;

  /// Иконка слева.
  final IconData? icon;

  /// Иконка справа.
  final IconData? trailingIcon;

  /// Выполняется: содержимое → `AppProgress.circular`, ширина фиксирована, тапы игнорируются.
  final bool loading;

  /// На всю ширину (CTA корзины/оформления/входа на compact).
  final bool expand;

  /// Узел фокуса.
  final FocusNode? focusNode;

  /// Автофокус.
  final bool autofocus;

  /// Подпись для screen reader, если отличается от [label].
  final String? semanticLabel;

  /// Узкое место (карточка сетки 160 lp): подпись не обрезается многоточием, а уменьшается до ширины
  /// кнопки (`FittedBox.scaleDown`; AC-UI-10-005, FIX-EF-13).
  final bool fitLabel;

  bool get _enabled => onPressed != null;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final BorderRadius radius = BorderRadius.all(context.radii.sm);
    final TextStyle baseText = switch (size) {
      AppButtonSize.s => context.text.label,
      AppButtonSize.m => context.text.body,
      AppButtonSize.l => context.text.bodyLg,
    }.copyWith(fontWeight: FontWeight.w600);
    final Duration fast = context.motion.of(context.motion.fast);

    final Widget button = Semantics(
      button: true,
      enabled: _enabled,
      label: semanticLabel ?? label,
      excludeSemantics: true,
      child: DsInteractive(
        enabled: _enabled,
        onTap: loading ? null : onPressed,
        focusNode: focusNode,
        autofocus: autofocus,
        builder: (BuildContext context, DsInteractionState s) {
          final _ButtonColors bc = _colorsFor(c, s);
          final Widget content = _content(bc.foreground, baseText);
          final Widget visual = AnimatedScale(
            scale: s.pressed ? 0.98 : 1,
            duration: fast,
            child: AnimatedContainer(
              duration: fast,
              height: size.height,
              padding: EdgeInsets.symmetric(horizontal: size.padding),
              decoration: BoxDecoration(
                color: bc.background,
                borderRadius: radius,
                border: bc.border == null ? null : Border.all(color: bc.border!, width: 1.5),
              ),
              child: Center(widthFactor: expand ? null : 1, child: content),
            ),
          );
          return DsTapTarget(
            minHeight: size.target,
            child: DsFocusRing(visible: s.focused, borderRadius: radius, child: visual),
          );
        },
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }

  Widget _content(Color fg, TextStyle textStyle) {
    final Widget row = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (icon != null) ...<Widget>[Icon(icon, size: size.icon, color: fg), const SizedBox(width: 8)],
        Flexible(
          child: fitLabel
              ? FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    style: textStyle.copyWith(color: fg),
                  ),
                )
              : Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: textStyle.copyWith(color: fg),
                ),
        ),
        if (trailingIcon != null) ...<Widget>[const SizedBox(width: 8), Icon(trailingIcon, size: size.icon, color: fg)],
      ],
    );
    if (!loading) {
      return row;
    }
    // Ширина фиксируется по невидимому содержимому (03 §9.1, loading).
    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        Visibility(visible: false, maintainSize: true, maintainAnimation: true, maintainState: true, child: row),
        AppProgress.circular(size: size.spinner, color: fg),
      ],
    );
  }

  _ButtonColors _colorsFor(DsColors c, DsInteractionState s) {
    if (!s.enabled) {
      return switch (variant) {
        AppButtonVariant.text => _ButtonColors(Colors.transparent, c.disabledText),
        AppButtonVariant.outlined => _ButtonColors(Colors.transparent, c.disabledText, c.disabledText),
        _ => _ButtonColors(c.disabledBg, c.disabledText),
      };
    }
    Color filled(Color base, Color hover, Color pressed) => s.pressed ? pressed : (s.hovered ? hover : base);
    Color quiet(Color base) => s.pressed ? c.primaryContainerPressed : (s.hovered ? c.primaryContainer : base);
    Color darken(Color base, double t) => Color.lerp(base, c.textPrimary, t)!;
    return switch (variant) {
      AppButtonVariant.primary => _ButtonColors(filled(c.primary, c.primaryHover, c.primaryPressed), c.onPrimary),
      AppButtonVariant.secondary || AppButtonVariant.tonal => _ButtonColors(
        s.pressed ? c.primaryContainerPressed : c.primaryContainer,
        c.primaryText,
      ),
      AppButtonVariant.outlined => _ButtonColors(quiet(Colors.transparent), c.primaryText, c.primaryText),
      AppButtonVariant.text => _ButtonColors(quiet(Colors.transparent), c.primaryText),
      AppButtonVariant.danger => _ButtonColors(filled(c.error, darken(c.error, .08), darken(c.error, .16)), c.onError),
      AppButtonVariant.success => _ButtonColors(
        filled(c.success, darken(c.success, .08), darken(c.success, .16)),
        c.onSuccess,
      ),
    };
  }
}

@immutable
class _ButtonColors {
  const _ButtonColors(this.background, this.foreground, [this.border]);

  final Color background;
  final Color foreground;
  final Color? border;
}
