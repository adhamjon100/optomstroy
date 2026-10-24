import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
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

/// Переключатель вида «Сетка / Список / Компакт» `ViewModeSegmented` (03 §9.26): трек
/// `surfaceVariant` 36, выбранный сегмент `surface` + `elevation.1` + иконка `primaryText`;
/// сегмент ≥ 44; ←/→ — смена; смена вида не перезапрашивает данные (CAT-010) — это забота
/// вызывающего. `Semantics` — группа радиокнопок.
class ViewModeSegmented extends StatelessWidget {
  /// Создаёт переключатель.
  const ViewModeSegmented({
    super.key,
    required this.value,
    required this.onChanged,
    required this.labels,
    this.showText = false,
  });

  /// Текущий вид.
  final ProductViewMode value;

  /// Выбор вида (повторный выбор текущего не сообщается).
  final ValueChanged<ProductViewMode> onChanged;

  /// Подписи («Сетка», «Список», «Компакт» — `catalog_view_*`).
  final Map<ProductViewMode, String> labels;

  /// Иконка + текст (expanded при ширине > 1280).
  final bool showText;

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

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Focus(
      canRequestFocus: false,
      onKeyEvent: _onKey,
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        child: Container(
          height: 36,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(color: c.surfaceVariant, borderRadius: BorderRadius.all(context.radii.sm)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final ProductViewMode m in ProductViewMode.values)
                _Segment(
                  key: ValueKey<String>('view-mode-${m.value}'),
                  mode: m,
                  selected: m == value,
                  label: labels[m] ?? m.value,
                  showText: showText,
                  onTap: () => _select(m),
                ),
            ],
          ),
        ),
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
  });

  final ProductViewMode mode;
  final bool selected;
  final String label;
  final bool showText;
  final VoidCallback onTap;

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
}

class _MaybeTooltip extends StatelessWidget {
  const _MaybeTooltip({required this.message, required this.child});

  final String? message;
  final Widget child;

  @override
  Widget build(BuildContext context) => message == null ? child : Tooltip(message: message, child: child);
}
