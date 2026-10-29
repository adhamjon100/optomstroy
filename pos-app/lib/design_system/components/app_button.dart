import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/layout/text_measure.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Варианты `AppButton` (03 §9.1). `secondary` = `tonal`.
///
/// `tint` — тинт с декоративной рамкой (прототип 2026-10-29, ADR-112): заливка `primaryContainer`, обводка
/// `primaryContainerBorder` 1,5, текст `onPrimaryContainer` (6.19:1) — «В корзине · N — ещё +1» карточки каталога.
///
/// `neutral` — нейтральная контурная (прототип 2026-10-29): фон `surface`, обводка 1 — `border`, затемнённый на 12 %
/// к `borderStrong` (≈ #D5DEEA прототипа, декоративная), текст `textPrimary` 600; hover — `surfaceHover`. Второстепенное
/// действие рядом с основной кнопкой: «Отложить · F8» drawer корзины — оранжевой остаётся только «Создать заказ · F9».
///
/// Ссылки («Сбросить фильтры», «Сбросить все» каталога) — вариант `text` (`primaryText`, ядро §24.1, DS-098): синий
/// `info` закреплён за фокусом и информационными статусами и для ссылок не используется (ревью переноса прототипа
/// 2026-10-29, ADR-112).
enum AppButtonVariant { primary, secondary, tonal, outlined, text, danger, success, tint, neutral }

/// Размеры `AppButton` (03 §7.4): S 36 / M 44 / L 52; тач-цель 44 / 48 / 52.
///
/// `card` / `cardCompact` — кнопки карточек каталога по прототипу 2026-10-29 (03 §9.11, §9.13; ADR-112): 40 / 34
/// визуально (цель 48 / 44), радиус `md`, подпись `body` / `label` вес 700.
enum AppButtonSize {
  /// Инлайн-действия в таблицах.
  s(height: 36, target: 44, padding: 12, icon: 20, spinner: 16),

  /// Стандартная кнопка.
  m(height: 44, target: 48, padding: 16, icon: 20, spinner: 16),

  /// CTA.
  l(height: 52, target: 52, padding: 24, icon: 24, spinner: 20),

  /// Кнопка карточки сетки и строки списка каталога: 40 (цель 48), радиус `md`, `body 700`.
  card(height: 40, target: 48, padding: 12, icon: 18, spinner: 16),

  /// Кнопка строки «Компакт» каталога: 34 (цель 44), радиус `md`, `label 700`.
  cardCompact(height: 34, target: 44, padding: 8, icon: 16, spinner: 14),

  /// Кнопки зоны G drawer корзины в одну строку («Отложить · F8», «Создать заказ · F9»; прототип 2026-10-29,
  /// ADR-112): 48 (цель 48), радиус `md`, `body 700`.
  cta(height: 48, target: 48, padding: 12, icon: 20, spinner: 18);

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

  /// Кнопки карточек каталога (радиус `md`, вес 700).
  bool get isCard => this == card || this == cardCompact;

  /// Радиус `md` (кнопки карточек и зоны G drawer корзины); остальные размеры — `sm`.
  bool get roundedMd => isCard || this == cta;
}

/// Кнопка `AppButton` (03 §9.1).
///
/// Палитра B (DS-098): `primary` — заливка primary #D9380F + белый `onPrimary`, 4.64:1 (ADR-111);
/// `outlined`/`text`/`tonal` — текст `primaryText`; `danger`/`success` — белый текст на `error`/`success`;
/// `neutral` — `textPrimary` на `surface`.
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

  /// Оценка ширины кнопки (до раскладки): поля размера, [hasIcon] — иконка с зазором 8, подпись `600` размера.
  static double estimateWidth(
    BuildContext context,
    String label, {
    AppButtonSize size = AppButtonSize.m,
    bool hasIcon = false,
    AppButtonVariant variant = AppButtonVariant.primary,
  }) {
    final TextStyle text = _textStyle(context, size, variant);
    return size.padding * 2 + (hasIcon ? size.icon + 8 : 0) + dsTextWidth(context, label, text) + 2;
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final BorderRadius radius = BorderRadius.all(size.roundedMd ? context.radii.md : context.radii.sm);
    final TextStyle baseText = _textStyle(context, size, variant);
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
                border: bc.border == null ? null : Border.all(color: bc.border!, width: bc.borderWidth),
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

  static TextStyle _textStyle(
    BuildContext context,
    AppButtonSize size, [
    AppButtonVariant variant = AppButtonVariant.primary,
  ]) {
    final TextStyle base = switch (size) {
      AppButtonSize.s => context.text.label.copyWith(fontWeight: FontWeight.w600),
      AppButtonSize.m => context.text.body.copyWith(fontWeight: FontWeight.w600),
      AppButtonSize.l => context.text.bodyLg.copyWith(fontWeight: FontWeight.w600),
      AppButtonSize.card => context.text.body.copyWith(fontWeight: FontWeight.w700),
      AppButtonSize.cardCompact => context.text.label.copyWith(fontWeight: FontWeight.w700),
      AppButtonSize.cta => context.text.body.copyWith(fontWeight: FontWeight.w700),
    };
    return switch (variant) {
      // Прототип: «Отложить · F8» — 14/600.
      AppButtonVariant.neutral => base.copyWith(fontWeight: FontWeight.w600),
      _ => base,
    };
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
        AppButtonVariant.neutral => _ButtonColors(c.surface, c.disabledText, c.disabledBg),
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
      AppButtonVariant.tint => _ButtonColors(
        s.pressed || s.hovered ? c.primaryContainerPressed : c.primaryContainer,
        c.onPrimaryContainer,
        c.primaryContainerBorder,
      ),
      AppButtonVariant.neutral => _ButtonColors(
        s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : c.surface),
        c.textPrimary,
        neutralBorder(c),
        1,
      ),
    };
  }

  /// Обводка варианта `neutral`: `border`, затемнённый на 12 % к `borderStrong` (≈ #D5DEEA прототипа).
  static Color neutralBorder(DsColors c) => Color.lerp(c.border, c.borderStrong, .12)!;
}

@immutable
class _ButtonColors {
  const _ButtonColors(this.background, this.foreground, [this.border, this.borderWidth = 1.5]);

  final Color background;
  final Color foreground;
  final Color? border;
  final double borderWidth; // money-double: allow — толщина обводки (lp)
}
