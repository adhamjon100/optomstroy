import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:optomstroy/design_system/components/ds_glyph.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/layout/text_measure.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Вид списка товаров (CAT-010): значение query `view` — [value].
enum ProductViewMode {
  /// Сетка — `grid_view`.
  grid('grid', Icons.grid_view_rounded),

  /// Список — `view_list`.
  list('list', Icons.view_list_rounded),

  /// Компакт — `view_headline`.
  compact('compact', Icons.view_headline_rounded);

  const ProductViewMode(this.value, this.icon);

  /// Значение query `view`.
  final String value;

  /// Глиф сегмента.
  final IconData icon;

  /// Разбор query; `null` — неизвестно.
  static ProductViewMode? tryParse(String? value) {
    for (final ProductViewMode m in values) {
      if (m.value == value) {
        return m;
      }
    }
    return null;
  }
}

/// Стиль `ViewModeSegmented`.
enum ViewModeSegmentedStyle {
  /// Трек `surfaceVariant` 36, выбранный сегмент `surface` + тень (compact, SCR-50).
  standard,

  /// Строка управления каталога medium+ (прототип 2026-10-29): трек `surface` с обводкой `border`, радиус `md`,
  /// поле 4; сегменты 32, радиус `sm`, поля 0 12, иконка 16 (у «Списка» — `DsGlyph.bulletList`) + `body 600`;
  /// выбранный — `primaryContainer`, текст `onPrimaryContainer` 700 (вес — признак не только цветом), остальные —
  /// [ViewModeSegmented.toolbarIdle] (≈ #3D4761 прототипа).
  toolbar,
}

/// Переключатель вида «Сетка / Список / Компакт» `ViewModeSegmented` (03 §9.26): трек
/// `surfaceVariant` 36, выбранный сегмент `surface` + `elevation.1` + иконка `primaryText`;
/// сегмент ≥ 44; ←/→ — смена; смена вида не перезапрашивает данные (CAT-010) — это забота
/// вызывающего. `Semantics` — группа радиокнопок. Стиль строки управления каталога — [ViewModeSegmentedStyle.toolbar].
class ViewModeSegmented extends StatelessWidget {
  /// Создаёт переключатель.
  const ViewModeSegmented({
    super.key,
    required this.value,
    required this.onChanged,
    required this.labels,
    this.showText = false,
    this.style = ViewModeSegmentedStyle.standard,
  });

  /// Текущий вид.
  final ProductViewMode value;

  /// Выбор вида (повторный выбор текущего не сообщается).
  final ValueChanged<ProductViewMode> onChanged;

  /// Подписи («Сетка», «Список», «Компакт» — `catalog_view_*`).
  final Map<ProductViewMode, String> labels;

  /// Иконка + текст (expanded при ширине > 1280).
  final bool showText;

  /// Стиль.
  final ViewModeSegmentedStyle style;

  /// Текст невыбранного сегмента стиля `toolbar`: `textPrimary`, осветлённый на 60 % к `textSecondary`
  /// (≈ #3D4761 прототипа; контраст выше, чем у `textSecondary`).
  static Color toolbarIdle(DsColors c) => Color.lerp(c.textPrimary, c.textSecondary, .6)!;

  /// Оценка ширины переключателя (до раскладки): трек 2+2, сегменты не уже 44; с подписью — поле 8, иконка 20,
  /// зазор 4, подпись `label 500`, поле 8. Стиль `toolbar`: трек 4+4 и обводка, зазор 4, сегмент — поля 12,
  /// иконка 16, зазор 8, подпись `body 700` (ширина выбранного).
  static double estimateWidth(
    BuildContext context,
    Iterable<String> labels, {
    required bool showText,
    ViewModeSegmentedStyle style = ViewModeSegmentedStyle.standard,
  }) {
    if (style == ViewModeSegmentedStyle.toolbar) {
      final TextStyle bold = context.text.body.copyWith(fontWeight: FontWeight.w700);
      double width = context.space.s1 * 2 + 2;
      int i = 0;
      for (final String l in labels) {
        final double segment = showText
            ? context.space.s3 * 2 + 16 + context.space.s2 + dsTextWidth(context, l, bold)
            : 0;
        width += (segment < 44 ? 44 : segment) + (i > 0 ? context.space.s1 : 0);
        i++;
      }
      return width;
    }
    final TextStyle text = context.text.label.copyWith(fontWeight: FontWeight.w500);
    double width = 4;
    for (final String l in labels) {
      final double segment = showText
          ? context.space.s2 * 2 + 20 + context.space.s1 + dsTextWidth(context, l, text)
          : 0;
      width += segment < 44 ? 44 : segment;
    }
    return width;
  }

  void _select(ProductViewMode mode) {
    if (mode != value) {
      onChanged(mode);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final int i = ProductViewMode.values.indexOf(value);
    if (event.logicalKey == LogicalKeyboardKey.arrowRight && i < ProductViewMode.values.length - 1) {
      _select(ProductViewMode.values[i + 1]);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft && i > 0) {
      _select(ProductViewMode.values[i - 1]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Высота цели касания сегмента стиля `toolbar` (03 §7.4): визуально сегмент 32, трек 42.
  static const double toolbarTarget = 44;

  /// Трек `standard`: 36, поле 2, `surfaceVariant`.
  Widget _standardTrack(BuildContext context, DsColors c, Widget segments) => Container(
    height: 36,
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(color: c.surfaceVariant, borderRadius: BorderRadius.all(context.radii.sm)),
    child: segments,
  );

  /// Трек `toolbar`: обводка 42 (32 + поля 4 + 1) рисуется под строкой сегментов, цели касания которых — 44 по высоте
  /// (поле родителя область нажатия не расширяет).
  Widget _toolbarTrack(BuildContext context, DsColors c, Widget segments) {
    final double track = 32 + context.space.s1 * 2 + 2;
    final double inset = (toolbarTarget - track) / 2;
    return SizedBox(
      height: toolbarTarget,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            top: inset,
            bottom: inset,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.all(context.radii.md),
                  border: Border.all(color: c.border),
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: context.space.s1 + 1),
            child: segments,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool toolbar = style == ViewModeSegmentedStyle.toolbar;
    final Widget segments = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final ProductViewMode m in ProductViewMode.values) ...<Widget>[
          if (toolbar && m.index > 0) SizedBox(width: context.space.s1),
          _Segment(
            key: ValueKey<String>('view-mode-${m.value}'),
            mode: m,
            selected: m == value,
            label: labels[m] ?? m.value,
            showText: showText,
            toolbar: toolbar,
            onTap: () => _select(m),
          ),
        ],
      ],
    );
    return Focus(
      canRequestFocus: false,
      onKeyEvent: _onKey,
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        child: toolbar ? _toolbarTrack(context, c, segments) : _standardTrack(context, c, segments),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    super.key,
    required this.mode,
    required this.selected,
    required this.label,
    required this.showText,
    required this.onTap,
    this.toolbar = false,
  });

  final ProductViewMode mode;
  final bool selected;
  final String label;
  final bool showText;
  final VoidCallback onTap;
  final bool toolbar;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      label: label,
      excludeSemantics: true,
      child: _MaybeTooltip(
        message: showText ? null : label,
        child: DsInteractive(
          onTap: onTap,
          builder: (BuildContext context, DsInteractionState s) {
            if (toolbar) {
              return _toolbar(context, c, s);
            }
            final Color bg = selected
                ? c.surface
                : (s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : Colors.transparent));
            return DsFocusRing(
              visible: s.focused,
              borderRadius: BorderRadius.all(context.radii.xs),
              child: AnimatedContainer(
                duration: context.motion.of(context.motion.base),
                curve: context.motion.standard,
                constraints: const BoxConstraints(minWidth: 44),
                height: 32,
                padding: EdgeInsets.symmetric(horizontal: context.space.s2),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.all(context.radii.xs),
                  boxShadow: selected ? context.elevation.e1 : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(mode.icon, size: 20, color: selected ? c.primaryText : c.textSecondary),
                    if (showText) ...<Widget>[
                      SizedBox(width: context.space.s1),
                      Text(
                        label,
                        style: context.text.label.copyWith(
                          fontWeight: FontWeight.w500,
                          color: selected ? c.primaryText : c.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Сегмент стиля `toolbar`: 32, радиус `sm`, поля 0 12, иконка 16 + `body 600`; выбранный — `primaryContainer`
  /// и `onPrimaryContainer` 700.
  Widget _toolbar(BuildContext context, DsColors c, DsInteractionState s) {
    final Color fg = selected ? c.onPrimaryContainer : ViewModeSegmented.toolbarIdle(c);
    final Color bg = selected
        ? c.primaryContainer
        : (s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : Colors.transparent));
    final BorderRadius radius = BorderRadius.all(context.radii.sm);
    // Цель касания — 44 по высоте (визуально 32): невидимое поле 6 сверху и снизу (03 §7.4).
    return SizedBox(
      height: ViewModeSegmented.toolbarTarget,
      child: Center(
        widthFactor: 1,
        child: DsFocusRing(
          visible: s.focused,
          borderRadius: radius,
          child: AnimatedContainer(
            duration: context.motion.of(context.motion.base),
            curve: context.motion.standard,
            constraints: const BoxConstraints(minWidth: 44),
            height: 32,
            padding: EdgeInsets.symmetric(horizontal: context.space.s3),
            decoration: BoxDecoration(color: bg, borderRadius: radius),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                // «Список» — контурный маркированный список прототипа (`DsGlyph.bulletList`); в Material Icons такого нет.
                if (mode == ProductViewMode.list)
                  DsGlyph(kind: DsGlyphKind.bulletList, size: 16, color: fg)
                else
                  Icon(mode.icon, size: 16, color: fg),
                if (showText) ...<Widget>[
                  SizedBox(width: context.space.s2),
                  Text(
                    label,
                    maxLines: 1,
                    style: context.text.body.copyWith(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                      color: fg,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MaybeTooltip extends StatelessWidget {
  const _MaybeTooltip({required this.message, required this.child});

  final String? message;
  final Widget child;

  @override
  Widget build(BuildContext context) => message == null ? child : Tooltip(message: message, child: child);
}
