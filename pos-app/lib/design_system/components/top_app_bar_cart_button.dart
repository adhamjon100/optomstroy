import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/top_app_bar_pos.dart' show TopAppBarFit;
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Кнопка-итог корзины в шапке `TopAppBarPos.full` (03 §9.70; 02 UI-10-041; прототип 2026-10-29, ADR-112).
///
/// Только визуал (данные и открытие корзины — у фичи cart, через порт каталога): высота 44, радиус `md`,
/// фон `primaryContainer`, рамка 1 px `primaryContainerBorder` (декоративная), поля 12 слева / 16 справа,
/// зазор 12. Иконка `shopping_cart_outlined` 22 `primaryText` с бейджем числа позиций [count] (круг/пилюля 18,
/// `primary` + `onPrimary` `micro 700`, смещение −7 / −9; при 0 — бейджа нет). Две строки: [label]
/// («Корзина», `caption textSecondary`) и [totalText] (`body 700 textPrimary tnum`); [warning] — иконка
/// `warning_amber` `warning` перед итогом (цены изменились, нехватка остатка — 02 UI-20-019). Состояния: hover и
/// pressed — `primaryContainerPressed`, фокус — кольцо `focus` (синее); цель касания ≥ 48 по высоте.
/// [showLabel] = `false` — без строки «Корзина», итог одной строкой; в шапке `full` строка сворачивается и по ширине
/// ([TopAppBarFit.cartLabel]: место отдаётся поиску, итог сервера виден всегда — 02 UI-10-041, ADR-112), тогда её
/// сведения — в тултипе [countTooltip] («5 поз. · 6 шт»); [showText] = `false` — только иконка с бейджем (витрина,
/// узкие макеты). [warningText] — текст предупреждения: тултип кнопки (иконка + текст — ядро §24.1); в
/// [semanticLabel] его добавляет вызывающий. [tooltip] — свой тултип вместо этих; без него — [countTooltip] и
/// [warningText] при [warning] (состав тултипа не зависит от ступени шапки: при пробах ступеней кнопка не
/// пересоздаётся и не теряет фокус). Строка [label] не шире [labelMaxWidth] (многоточие): «Корзина · 6 шт, 12,5 м»
/// не раздувает кнопку.
class TopAppBarCartButton extends StatelessWidget {
  /// Создаёт кнопку.
  const TopAppBarCartButton({
    super.key,
    required this.label,
    required this.count,
    required this.totalText,
    required this.semanticLabel,
    required this.onTap,
    this.warning = false,
    this.warningText,
    this.showText = true,
    this.showLabel = true,
    this.focusNode,
    this.tooltip,
    this.countTooltip,
  });

  /// Первая строка («Корзина» или «Корзина · 6 шт»).
  final String label;

  /// Число позиций (бейдж; 0 — без бейджа).
  final int count;

  /// Вторая строка: итог («16 007,50 сом») или «N поз.», пока итога нет.
  final String totalText;

  /// Подпись для screen reader («Открыть корзину, 5 позиций, 16 007 сом 50 тыйын»).
  final String semanticLabel;

  /// Открыть корзину; `null` — недоступна.
  final VoidCallback? onTap;

  /// Есть предупреждение корзины — иконка `warning` перед итогом (не только цвет).
  final bool warning;

  /// Показывать итог (и подпись); `false` — только иконка с бейджем.
  final bool showText;

  /// Показывать строку «Корзина» над итогом; `false` — итог одной строкой.
  final bool showLabel;

  /// Текст предупреждения для тултипа (при [warning]).
  final String? warningText;

  /// Узел фокуса кнопки: после закрытия drawer корзины фокус возвращается сюда (A11Y-011).
  final FocusNode? focusNode;

  /// Тултип кнопки; `null` — [countTooltip] и [warningText] при [warning].
  final String? tooltip;

  /// Сведения корзины для тултипа («5 поз. · 6 шт»; при [showText]): когда строка [label] свёрнута по ширине шапки
  /// или [showLabel] = `false`, единицы видны здесь и в [semanticLabel]; `null` — без них.
  final String? countTooltip;

  /// Наибольшая ширина строки [label].
  static const double labelMaxWidth = 160;

  /// Высота кнопки.
  static const double height = 44;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool labelShown = showLabel && TopAppBarFit.of(context).cartLabel;
    final BorderRadius radius = BorderRadius.all(context.radii.md);
    final String badge = count > 99 ? '99+' : '$count';
    final Widget icon = Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Icon(Icons.shopping_cart_outlined, size: 22, color: c.primaryText),
        if (count > 0)
          Positioned(
            top: -7,
            right: -9,
            child: Container(
              key: const ValueKey<String>('top-app-bar-cart-badge'),
              height: 18,
              constraints: const BoxConstraints(minWidth: 18),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: c.primary, borderRadius: BorderRadius.all(context.radii.full)),
              child: Text(
                badge,
                maxLines: 1,
                textScaler: TextScaler.noScaling,
                style: context.text.micro.copyWith(
                  color: c.onPrimary,
                  fontWeight: FontWeight.w700,
                  fontFeatures: DsTypography.numeric,
                  height: 1,
                ),
              ),
            ),
          ),
      ],
    );
    final Widget button = Semantics(
      button: true,
      enabled: onTap != null,
      label: semanticLabel,
      excludeSemantics: true,
      // Действие «нажать» для TalkBack/Narrator: жест DsInteractive из семантики исключён.
      onTap: onTap,
      child: DsInteractive(
        enabled: onTap != null,
        onTap: onTap,
        focusNode: focusNode,
        builder: (BuildContext context, DsInteractionState s) => DsTapTarget(
          child: DsFocusRing(
            visible: s.focused,
            borderRadius: radius,
            child: AnimatedContainer(
              duration: context.motion.of(context.motion.fast),
              height: height,
              padding: EdgeInsetsDirectional.only(
                start: context.space.s3,
                end: showText ? context.space.s4 : context.space.s3,
              ),
              decoration: BoxDecoration(
                color: s.pressed || s.hovered ? c.primaryContainerPressed : c.primaryContainer,
                borderRadius: radius,
                border: Border.all(color: c.primaryContainerBorder),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  icon,
                  if (showText) ...<Widget>[
                    SizedBox(width: context.space.s3),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        if (labelShown)
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: labelMaxWidth),
                            child: Text(
                              label,
                              key: const ValueKey<String>('top-app-bar-cart-label'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.text.caption.copyWith(
                                color: c.textSecondary,
                                height: 1.1,
                                fontFeatures: DsTypography.numeric,
                              ),
                            ),
                          ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            if (warning) ...<Widget>[
                              Icon(Icons.warning_amber_rounded, size: 14, color: c.warning),
                              SizedBox(width: context.space.s1),
                            ],
                            Text(
                              totalText,
                              maxLines: 1,
                              style: context.text.body.copyWith(
                                color: c.textPrimary,
                                fontWeight: FontWeight.w700,
                                fontFeatures: DsTypography.numeric,
                                height: 1.2,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ] else if (warning) ...<Widget>[
                    SizedBox(width: context.space.s2),
                    Icon(Icons.warning_amber_rounded, size: 16, color: c.warning),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final String tip =
        tooltip ??
        <String?>[
          if (showText) countTooltip,
          if (warning) warningText,
        ].whereType<String>().where((String t) => t.isNotEmpty).join('\n');
    return tip.isEmpty ? button : AppTooltip(message: tip, child: button);
  }
}
