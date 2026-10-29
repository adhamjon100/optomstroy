import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/top_app_bar_pos.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Вариант `NotificationBell` (03 §9.51).
enum NotificationBellVariant {
  /// Шапка medium+ (прототип 2026-10-29): кнопка 44×44 с радиусом `md`, иконка 22, бейдж с числом.
  header,

  /// Шапка compact: только точка 8.
  dot,
}

/// Вход в центр уведомлений `NotificationBell` (03 §9.51; D-41).
///
/// `header` — [TopAppBarIconButton] 44×44 (радиус `md`, иконка 22 `textPrimary`, цель 48) + бейдж `error` высотой
/// 18 с числом `micro 700 onError tnum` (1 цифра — круг 18, 2 — пилюля 24, «99+» — 30) в точке `top 6 / right 6`
/// квадрата, обводка `surface` 1,5; `dot` — `AppIconButton` с точкой 8. Без непрочитанных — без бейджа (не «0»);
/// при ошибке синхронизации — `notifications_active`. Тап → SCR-44 (у вызывающего).
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
          height: 18,
          constraints: BoxConstraints(minWidth: text.length == 1 ? 18 : (text.length == 2 ? 24 : 30)),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.error,
            borderRadius: BorderRadius.all(context.radii.full),
            border: Border.all(color: c.surface, width: 1.5),
          ),
          child: Text(
            text,
            maxLines: 1,
            textScaler: TextScaler.noScaling,
            style: context.text.micro.copyWith(
              color: c.onError,
              fontWeight: FontWeight.w700,
              fontFeatures: DsTypography.numeric,
              height: 1,
            ),
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
