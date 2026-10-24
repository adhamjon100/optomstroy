import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/nav_destination.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Нижняя навигация `BottomNavBar` (03 §9.55) — только compact: панель 80 (+ `SafeArea`),
/// `surface`, верхняя граница `border`, `elevation.1`; пункты равной ширины: иконка 24 (активная —
/// filled `primaryText` в пилюле `primaryContainer` 64×32) + подпись `caption 12/500` (активная —
/// `primaryText 600`), подпись видна всегда. Повторный тап по активному — [onReselect].
class BottomNavBar extends StatelessWidget {
  /// Создаёт панель.
  const BottomNavBar({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    this.onReselect,
  });

  /// Пункты (5 по режиму).
  final List<NavDestination> destinations;

  /// Активный пункт.
  final int selectedIndex;

  /// Переключение ветки.
  final ValueChanged<int> onSelected;

  /// Повторный тап по активному пункту (прокрутка вверх / сброс до корня ветки).
  final ValueChanged<int>? onReselect;

  /// Высота панели без `SafeArea` [ТИПОВО: M3 navigation bar].
  static const double height = 80;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(top: BorderSide(color: c.border)),
          boxShadow: context.elevation.e1,
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: height,
            child: Row(
              children: <Widget>[
                for (int i = 0; i < destinations.length; i++)
                  Expanded(
                    child: _Item(
                      destination: destinations[i],
                      selected: i == selectedIndex,
                      onTap: () => i == selectedIndex ? onReselect?.call(i) : onSelected(i),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({required this.destination, required this.selected, required this.onTap});

  final NavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final Duration fast = context.motion.of(context.motion.fast);
    final Widget? badge = destination.badge();
    return Semantics(
      button: true,
      selected: selected,
      label: destination.semanticLabel ?? destination.label,
      excludeSemantics: true,
      child: DsInteractive(
        onTap: onTap,
        builder: (BuildContext context, DsInteractionState s) {
          final Color pill = selected
              ? (s.pressed ? c.primaryContainerPressed : c.primaryContainer)
              : (s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : Colors.transparent));
          Widget icon = Icon(
            selected ? destination.selectedIcon : destination.icon,
            size: 24,
            color: selected ? c.primaryText : c.textSecondary,
          );
          if (badge != null) {
            icon = Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                icon,
                Positioned(left: 14, top: -6, child: badge),
              ],
            );
          }
          return DsFocusRing(
            visible: s.focused,
            borderRadius: BorderRadius.all(context.radii.md),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                AnimatedContainer(
                  duration: fast,
                  width: 64,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: pill, borderRadius: BorderRadius.all(context.radii.full)),
                  child: icon,
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    destination.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.captionMedium.copyWith(
                      color: selected ? c.primaryText : c.textSecondary,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
