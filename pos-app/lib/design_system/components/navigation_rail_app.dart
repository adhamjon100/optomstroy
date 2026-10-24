import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/nav_destination.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Вариант `NavigationRailApp` (03 §9.56).
enum NavigationRailVariant {
  /// medium: 72, подписи видны.
  rail,

  /// expanded при свёрнутом сайдбаре: те же пункты + «бургер» для разворота.
  collapsedSidebar,

  /// medium-ландшафт ≥ 840: ширина 240, иконка + текст в строку 48.
  extended,
}

/// Вертикальная навигация `NavigationRailApp` (03 §9.56): колонка 72 (`surface`, правая граница
/// `border`) → [логотип] → пункты: иконка 24 в пилюле 56×32 (активная — `primaryContainer` +
/// filled `primaryText`) + подпись `caption 12/500` (всегда видна), высота пункта 72 → низ:
/// [trailing] (`NotificationBell.rail`, `AppAvatar.sm`, `SyncIndicator`).
class NavigationRailApp extends StatelessWidget {
  /// Создаёт навигацию.
  const NavigationRailApp({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    this.variant = NavigationRailVariant.rail,
    this.leading,
    this.trailing,
    this.semanticLabel,
  });

  /// Пункты по режиму.
  final List<NavDestination> destinations;

  /// Активный пункт.
  final int selectedIndex;

  /// Переключение ветки.
  final ValueChanged<int> onSelected;

  /// Вариант.
  final NavigationRailVariant variant;

  /// Логотип / «бургер» сверху.
  final Widget? leading;

  /// Элементы внизу.
  final List<Widget>? trailing;

  /// Подпись группы («Навигация»).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool extended = variant == NavigationRailVariant.extended;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: semanticLabel,
      child: Container(
        width: extended ? DsBreakpoints.sidebarNarrow : DsBreakpoints.rail,
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(right: BorderSide(color: c.border)),
        ),
        child: SafeArea(
          right: false,
          child: Column(
            children: <Widget>[
              if (leading != null) Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: leading),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: <Widget>[
                      for (int i = 0; i < destinations.length; i++) ...<Widget>[
                        if (i > 0) const SizedBox(height: 4),
                        _RailItem(
                          destination: destinations[i],
                          selected: i == selectedIndex,
                          extended: extended,
                          onTap: () => onSelected(i),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (trailing != null) ...<Widget>[
                for (final Widget w in trailing!) Padding(padding: const EdgeInsets.only(bottom: 8), child: w),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({required this.destination, required this.selected, required this.extended, required this.onTap});

  final NavDestination destination;
  final bool selected;
  final bool extended;
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
          final Color fg = selected ? c.primaryText : c.textSecondary;
          Widget icon = Icon(selected ? destination.selectedIcon : destination.icon, size: 24, color: fg);
          if (badge != null) {
            icon = Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                icon,
                Positioned(left: 14, top: -6, child: badge),
              ],
            );
          }
          final TextStyle label = context.text.captionMedium.copyWith(
            color: fg,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          );
          if (extended) {
            return DsFocusRing(
              visible: s.focused,
              borderRadius: BorderRadius.all(context.radii.full),
              child: AnimatedContainer(
                duration: fast,
                height: 48,
                margin: const EdgeInsets.symmetric(horizontal: 12),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(color: pill, borderRadius: BorderRadius.all(context.radii.full)),
                child: Row(
                  children: <Widget>[
                    icon,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        destination.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.body.copyWith(color: fg, fontWeight: label.fontWeight),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          return SizedBox(
            width: DsBreakpoints.rail,
            height: 72,
            child: DsFocusRing(
              visible: s.focused,
              borderRadius: BorderRadius.all(context.radii.md),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  AnimatedContainer(
                    duration: fast,
                    width: 56,
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
                      textAlign: TextAlign.center,
                      style: label,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
