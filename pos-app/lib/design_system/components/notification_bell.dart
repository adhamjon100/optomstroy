import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/ds_glyph.dart';
import 'package:optomstroy/design_system/components/top_app_bar_pos.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Вариант `NotificationBell` (03 §9.51).
enum NotificationBellVariant {
  /// Шапка medium+ (прототип, ADR-114): кнопка 44×44 с радиусом `control` 10, колокол 22, бейдж 17 с числом.
  header,

  /// Шапка compact: только точка 8.
  dot,
}

/// Вход в центр уведомлений `NotificationBell` (03 §9.51; D-41).
///
/// `header` — [TopAppBarIconButton] 44×44 (радиус `control` 10, колокол прототипа 22 `textPrimary` линией 1,8, цель
/// 48) + бейдж прототипа (ADR-114 п. 6): высота и минимальная ширина 17, радиус `badge` 9, `error` #D21B1F, число
/// `bellBadge` 10/700 `onError` без `tnum` и без обводки, в точке `top 6 / right 6` квадрата (две цифры и «99+» —
/// с полями 3); 10 lp — отступление от A11Y-008, записано в ADR-114 п. 6. `dot` — `AppIconButton` с точкой 8. Без
/// непрочитанных — без бейджа (не «0»); при ошибке синхронизации — `notifications_active` (Material). Тап → SCR-44
/// (у вызывающего).
class NotificationBell extends StatelessWidget {
  /// Создаёт колокольчик.
  const NotificationBell({
    super.key,
    required this.unreadCount,
    required this.onPressed,
    required this.semanticLabel,
    this.variant = NotificationBellVariant.header,
    this.syncError = false,
    this.active = false,
  });

  /// Число непрочитанных.
  final int unreadCount;

  /// Открыть уведомления.
  final VoidCallback? onPressed;

  /// «Уведомления, 3 непрочитанных».
  final String semanticLabel;

  /// Вариант.
  final NotificationBellVariant variant;

  /// Есть непрочитанная `sync_error`.
  final bool syncError;

  /// SCR-44 открыт — иконка filled `primaryText`.
  final bool active;

  /// Текст бейджа: «7», «42», «99+».
  static String badgeText(int count) => count > 99 ? '99+' : '$count';

  /// Высота и минимальная ширина бейджа `header` (прототип: `min-width: 17px; height: 17px`).
  static const double badgeSize = 17;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final IconData icon = syncError
        ? Icons.notifications_active_rounded
        : (active ? Icons.notifications_rounded : Icons.notifications_none_rounded);
    Widget? badge;
    if (unreadCount > 0) {
      if (variant == NotificationBellVariant.dot) {
        badge = Container(
          key: const ValueKey<String>('notification-bell-dot'),
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: c.error, shape: BoxShape.circle),
        );
      } else {
        final String text = badgeText(unreadCount);
        badge = Container(
          key: const ValueKey<String>('notification-bell-badge'),
          height: badgeSize,
          constraints: const BoxConstraints(minWidth: badgeSize),
          padding: EdgeInsets.symmetric(horizontal: text.length == 1 ? 0 : 3),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: c.error, borderRadius: BorderRadius.all(context.radii.badge)),
          child: Text(
            text,
            maxLines: 1,
            textScaler: TextScaler.noScaling,
            style: context.text.bellBadge.copyWith(color: c.onError),
          ),
        );
      }
    }
    // Бейдж (02 SCR-44.5): появление 0→N — scale 0→1 за `base` (200 мс), «Прочитать все» N→0 — fade-out за `fast`
    // (150 мс); reduce-motion — мгновенно. Первый кадр без анимации (AnimatedSwitcher не анимирует начальный child).
    final Duration appear = context.motion.of(context.motion.base);
    final Duration vanish = context.motion.of(context.motion.fast);
    final Widget animatedBadge = AnimatedSwitcher(
      duration: appear,
      reverseDuration: vanish,
      transitionBuilder: (Widget child, Animation<double> a) => a.status == AnimationStatus.reverse
          ? FadeTransition(opacity: a, child: child)
          : ScaleTransition(scale: a, child: child),
      child: badge ?? const SizedBox.shrink(key: ValueKey<String>('notification-bell-no-badge')),
    );
    if (variant == NotificationBellVariant.header) {
      return TopAppBarIconButton(
        icon: icon,
        // Колокол прототипа; при ошибке синхронизации — Material `notifications_active` (признак не только цветом).
        glyph: syncError ? null : DsGlyphKind.bell,
        semanticLabel: semanticLabel,
        onPressed: onPressed,
        selected: active,
        badge: animatedBadge,
      );
    }
    return AppIconButton(
      icon: icon,
      semanticLabel: semanticLabel,
      tooltip: semanticLabel,
      onPressed: onPressed,
      selected: active,
      badge: animatedBadge,
    );
  }
}
