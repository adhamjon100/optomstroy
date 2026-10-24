import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Строка условия правила скидки (иконка + значение, напр. `shopping_cart` + «16 850,00 сом»).
@immutable
final class DiscountRuleDetail {
  /// Создаёт строку условия.
  const DiscountRuleDetail({required this.icon, required this.text});

  /// Иконка условия.
  final IconData icon;

  /// Значение.
  final String text;
}

/// Строка правила скидки `DiscountRuleRow` (02 SCR-35 UI-35-004; 10 DISC-013, D-23): название `body 600`, значение
/// `caption tnum`, справа источник (`StatusChip.info` «1С» / `neutral` «POS») и статус (иконка + текст); тап / Enter /
/// Space раскрывает условия (`AnimatedSize` 200 мс, шеврон 0 → 180°; reduce-motion — мгновенно). Только чтение.
class DiscountRuleRow extends StatelessWidget {
  /// Создаёт строку правила.
  const DiscountRuleRow({
    super.key,
    required this.name,
    required this.sourceLabel,
    required this.fromOnec,
    this.valueLabel,
    this.statusLabel,
    this.statusVariant = StatusChipVariant.neutral,
    this.details = const <DiscountRuleDetail>[],
    this.expanded = false,
    this.onToggle,
  });

  /// Название правила.
  final String name;

  /// «1С» / «POS».
  final String sourceLabel;

  /// Источник — 1С (`info`), иначе POS (`neutral`).
  final bool fromOnec;

  /// Значение («5 %», «500,00 сом»).
  final String? valueLabel;

  /// «Действует» / «Итог в 1С» / «Не действует».
  final String? statusLabel;

  /// Вариант статуса.
  final StatusChipVariant statusVariant;

  /// Условия правила (раскрываемое тело).
  final List<DiscountRuleDetail> details;

  /// Условия раскрыты.
  final bool expanded;

  /// Раскрыть/свернуть; `null` — строка без условий.
  final VoidCallback? onToggle;

  /// Минимальная высота строки.
  static const double height = 56;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool expandable = details.isNotEmpty && onToggle != null;
    final bool reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final Duration d = reduceMotion ? Duration.zero : const Duration(milliseconds: 200);
    return Semantics(
      container: true,
      button: expandable,
      expanded: expandable ? expanded : null,
      label: <String>[name, ?valueLabel, sourceLabel, ?statusLabel].join(', '),
      excludeSemantics: true,
      child: DsInteractive(
        onTap: expandable ? onToggle : null,
        enabled: expandable,
        builder: (BuildContext context, DsInteractionState s) => Container(
          decoration: BoxDecoration(
            color: s.pressed ? c.surfacePressed : (s.hovered || s.focused ? c.surfaceHover : c.surface),
            border: Border(bottom: BorderSide(color: c.border)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: height - 16),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.body.copyWith(fontWeight: FontWeight.w600, color: c.textPrimary),
                          ),
                          if (valueLabel != null)
                            Text(
                              valueLabel!,
                              style: context.text.caption.copyWith(
                                color: c.textSecondary,
                                fontFeatures: DsTypography.numeric,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    StatusChip(
                      label: sourceLabel,
                      variant: fromOnec ? StatusChipVariant.info : StatusChipVariant.neutral,
                      dense: true,
                    ),
                    if (statusLabel != null) ...<Widget>[
                      const SizedBox(width: 4),
                      StatusChip(label: statusLabel!, variant: statusVariant, dense: true),
                    ],
                    if (expandable) ...<Widget>[
                      const SizedBox(width: 4),
                      AnimatedRotation(
                        turns: expanded ? .5 : 0,
                        duration: d,
                        child: Icon(Icons.expand_more_rounded, size: 20, color: c.textSecondary),
                      ),
                    ],
                  ],
                ),
              ),
              AnimatedSize(
                duration: d,
                alignment: Alignment.topCenter,
                child: !(expandable && expanded)
                    ? const SizedBox(width: double.infinity) // money-double: allow — геометрия UI (ширина строки)
                    : Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            for (final DiscountRuleDetail detail in details)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Row(
                                  children: <Widget>[
                                    Icon(detail.icon, size: 16, color: c.textSecondary),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        detail.text,
                                        style: context.text.caption.copyWith(
                                          color: c.textSecondary,
                                          fontFeatures: DsTypography.numeric,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
