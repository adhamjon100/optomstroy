import 'package:flutter/widgets.dart';
import 'package:optomstroy/design_system/components/app_badge.dart';

/// Пункт навигации `BottomNavBar` / `NavigationRailApp` (03 §9.55, §9.56).
/// Состав пунктов по режиму — ядро §9 (передаёт `app/router/shells`).
@immutable
class NavDestination {
  /// Создаёт пункт.
  const NavDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.badgeCount,
    this.badgeDot = false,
    this.badgeTone = AppBadgeTone.alert,
    this.semanticLabel,
  });

  /// Иконка (outlined).
  final IconData icon;

  /// Иконка активного пункта (filled).
  final IconData selectedIcon;

  /// Подпись (всегда видна).
  final String label;

  /// Число в бейдже (корзина — позиции, `cart`-тон).
  final int? badgeCount;

  /// Бейдж-точка без числа (`sync_error`, уведомления).
  final bool badgeDot;

  /// Тон бейджа.
  final AppBadgeTone badgeTone;

  /// Подпись для screen reader («Корзина, 5 позиций»); по умолчанию [label].
  final String? semanticLabel;

  /// Бейдж пункта или `null`.
  Widget? badge() {
    if (badgeCount != null && badgeCount! > 0) {
      return AppBadge(count: badgeCount, tone: badgeTone);
    }
    if (badgeDot) {
      return AppBadge.dot(tone: badgeTone);
    }
    return null;
  }
}
