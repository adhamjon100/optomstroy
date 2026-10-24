import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_dropdown.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Единица или упаковка в `UnitSelector`.
@immutable
class UnitOption {
  /// Создаёт вариант.
  const UnitOption({
    required this.id,
    required this.label,
    this.detail,
    this.enabled = true,
    this.disabledHint,
    this.semanticLabel,
  });

  /// `null`-подобный ключ базовой единицы задаёт вызывающий (например, `''`), упаковки — `packagingId`.
  final String id;

  /// «шт», «кор».
  final String label;

  /// Коэффициент «6 шт» (`caption`).
  final String? detail;

  /// Доступна для выбора.
  final bool enabled;

  /// Тултип недоступной упаковки.
  final String? disabledHint;

  /// «Коробка, 6 штук».
  final String? semanticLabel;
}

/// Выбор единицы/упаковки `UnitSelector` (03 §9.19; INV-002, INV-003): `segmented` (≤ 3),
/// `dropdown` (> 3), `readonly` (одна единица — текстом). Трек `surfaceVariant`, выбранный сегмент —
/// `surface` + `elevation.1` + текст `primaryText`; высота 36, сегмент ≥ 64, тач-цель 44.
/// Пересчёт количества (с сохранением базового) выполняет вызывающий в [onChanged].
class UnitSelector extends StatelessWidget {
  /// Создаёт селектор.
  const UnitSelector({super.key, required this.options, required this.selectedId, this.onChanged, this.semanticLabel});

  /// Базовая единица и упаковки.
  final List<UnitOption> options;

  /// Выбранный [UnitOption.id].
  final String selectedId;

  /// Выбор; `null` — только чтение.
  final ValueChanged<String>? onChanged;

  /// Подпись группы («Единица»).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    if (options.length <= 1 || onChanged == null) {
      final UnitOption? only = options.where((UnitOption o) => o.id == selectedId).firstOrNull ?? options.firstOrNull;
      return Semantics(
        label: semanticLabel,
        value: only?.semanticLabel ?? only?.label,
        child: Text(
          only == null ? '' : (only.detail == null ? only.label : '${only.label} (${only.detail})'),
          key: const ValueKey<String>('unit-selector-readonly'),
          style: context.text.label.copyWith(color: c.textPrimary),
        ),
      );
    }
    if (options.length > 3) {
      return AppDropdown<String>(
        key: const ValueKey<String>('unit-selector-dropdown'),
        semanticLabel: semanticLabel,
        value: selectedId,
        onChanged: onChanged,
        items: <AppDropdownItem<String>>[
          for (final UnitOption o in options)
            AppDropdownItem<String>(
              value: o.id,
              label: o.detail == null ? o.label : '${o.label} (${o.detail})',
              enabled: o.enabled,
            ),
        ],
      );
    }
    return Semantics(
      label: semanticLabel,
      container: true,
      explicitChildNodes: true,
      child: Container(
        key: const ValueKey<String>('unit-selector-segmented'),
        height: 44,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: c.surfaceVariant, borderRadius: BorderRadius.all(context.radii.sm)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[for (final UnitOption o in options) _segment(context, o)],
        ),
      ),
    );
  }

  Widget _segment(BuildContext context, UnitOption o) {
    final DsColors c = context.colors;
    final bool selected = o.id == selectedId;
    final Widget seg = Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      enabled: o.enabled,
      label: o.semanticLabel ?? (o.detail == null ? o.label : '${o.label} ${o.detail}'),
      excludeSemantics: true,
      child: DsInteractive(
        key: ValueKey<String>('unit-option-${o.id}'),
        enabled: o.enabled,
        onTap: selected ? null : () => onChanged?.call(o.id),
        builder: (BuildContext context, DsInteractionState s) => DsFocusRing(
          visible: s.focused,
          borderRadius: BorderRadius.all(context.radii.xs),
          child: AnimatedContainer(
            duration: context.motion.of(const Duration(milliseconds: 200)),
            constraints: const BoxConstraints(minWidth: 64, minHeight: 36),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? c.surface : (s.hovered ? c.surfaceHover : Colors.transparent),
              borderRadius: BorderRadius.all(context.radii.xs),
              boxShadow: selected ? context.elevation.e1 : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  o.label,
                  style: context.text.label.copyWith(
                    color: !o.enabled ? c.disabledText : (selected ? c.primaryText : c.textPrimary),
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
                if (o.detail != null) ...<Widget>[
                  const SizedBox(width: 4),
                  Text(
                    '(${o.detail})',
                    style: context.text.caption.copyWith(
                      color: o.enabled ? c.textSecondary : c.disabledText,
                      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (!o.enabled && o.disabledHint != null) return AppTooltip(message: o.disabledHint!, child: seg);
    return seg;
  }
}
