// Подключённые виджеты центра уведомлений для других экранов (RM-F-008; композиция — app/di или оболочка):
// - [ConnectedNotificationBell] — `NotificationBell` с бейджем непрочитанных (UI-44-005): compact/medium — `go`
//   на SCR-44 (ветка `profile`), expanded — [NotificationsPopover];
// - [NotificationsPopover] — popover 400×560 под колокольчиком (02 SCR-44.2 «Expanded», UI-44-003/004);
// - [NotificationBannerSlot] — баннер `cart_price_changed` / `cart_stock_changed` / `credit_blocked` в экране
//   (SCR-20/CartPanel, SCR-21, SCR-24): «Закрыть» отмечает уведомление прочитанным.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/notification_banner.dart';
import 'package:optomstroy/design_system/components/notification_bell.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/notifications/domain/entities/app_notification.dart';
import 'package:optomstroy/features/notifications/presentation/notification_targets.dart';
import 'package:optomstroy/features/notifications/presentation/notifiers/notifications_center_controller.dart';
import 'package:optomstroy/features/notifications/presentation/widgets/notification_kind_style.dart';
import 'package:optomstroy/features/notifications/presentation/widgets/notifications_view.dart';

/// Ход анимации popover.
typedef _Progress = Animation<double>; // money-double: allow — анимация, не деньги

/// Путь SCR-44.
const String notificationsLocation = '/notifications';

/// Колокольчик с бейджем непрочитанных (`notificationsBadgeProvider`).
class ConnectedNotificationBell extends ConsumerWidget {
  const ConnectedNotificationBell({super.key, this.variant, this.active = false, this.onPressed});

  /// Вариант; по умолчанию — `dot` на compact, иначе `header`.
  final NotificationBellVariant? variant;

  /// SCR-44 открыт.
  final bool active;

  /// Своё действие (иначе: expanded — popover, compact/medium — `go('/notifications')`).
  final VoidCallback? onPressed;

  static const Key bellKey = ValueKey<String>('connected-notification-bell');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ({int unread, bool syncError}) badge = ref.watch(notificationsBadgeProvider);
    final WindowClass wc = context.windowClass;
    final bool wide = wc == WindowClass.expanded || wc == WindowClass.large;
    return NotificationBell(
      key: bellKey,
      unreadCount: badge.unread,
      syncError: badge.syncError,
      active: active,
      variant: variant ?? (wc == WindowClass.compact ? NotificationBellVariant.dot : NotificationBellVariant.header),
      semanticLabel: badge.unread > 0 ? l10n.notifications_bell_a11y(badge.unread) : l10n.notifications_title,
      onPressed:
          onPressed ??
          () {
            if (wide) {
              unawaited(NotificationsPopover.show(context));
            } else {
              GoRouter.maybeOf(context)?.go(notificationsLocation);
            }
          },
    );
  }
}

/// Popover центра уведомлений (expanded): заголовок + «Прочитать все», сегменты, последние 20, «Все уведомления».
class NotificationsPopover extends StatelessWidget {
  const NotificationsPopover({super.key, required this.onNavigate, required this.onViewAll});

  /// Переход к цели (popover уже закрыт вызывающим).
  final NotificationNavigator onNavigate;

  /// «Все уведомления».
  final VoidCallback onViewAll;

  static const Size size = Size(400, 560);
  static const Key popoverKey = ValueKey<String>('notifications-popover');
  static const Key viewAllKey = ValueKey<String>('notifications-view-all');

  /// Открыть под колокольчиком: [anchor] — прямоугольник колокольчика в глобальных координатах (по умолчанию —
  /// правый верхний угол окна под шапкой 68 — `DsBreakpoints.topBarHeight`, ADR-112). Esc / клик вне — закрыть
  /// (фокус возвращается на колокольчик).
  static Future<void> show(BuildContext context, {Rect? anchor}) {
    final GoRouter? router = GoRouter.maybeOf(context);
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Size screen = MediaQuery.sizeOf(context);
    // Под колокольчиком; без якоря — правый верхний угол под шапкой medium+ (68, ADR-112).
    final EdgeInsets at = EdgeInsets.only(
      top: (anchor?.bottom ?? DsBreakpoints.topBarHeight) + 4,
      right: anchor == null ? 24 : (screen.width - anchor.right).clamp(8, screen.width),
    );
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: l10n.ds_button_close,
      barrierColor: const Color(0x00000000),
      transitionDuration: context.motion.reduceMotion ? context.motion.reducedCrossfade : context.motion.base,
      pageBuilder: (BuildContext dialogContext, _, _) {
        void close() => Navigator.of(dialogContext).pop();
        return Stack(
          children: <Widget>[
            Positioned(
              top: at.top,
              right: at.right,
              child: NotificationsPopover(
                onNavigate: (BuildContext _, NotificationLink link) {
                  close();
                  if (router == null) return;
                  switch (link.navigation) {
                    case NotificationNavigation.go:
                      router.go(link.location);
                    case NotificationNavigation.push:
                      unawaited(router.push<void>(link.location));
                  }
                },
                onViewAll: () {
                  close();
                  router?.go(notificationsLocation);
                },
              ),
            ),
          ],
        );
      },
      transitionBuilder: (BuildContext context, a, _, Widget child) => _transition(context, a, child),
    );
  }

  /// ANIM-023 без overlay: fade + scale .96→1 (reduce-motion — только fade 80 мс).
  static Widget _transition(BuildContext context, _Progress a, Widget child) {
    final CurvedAnimation curved = CurvedAnimation(parent: a, curve: Curves.easeOut);
    if (context.motion.reduceMotion) return FadeTransition(opacity: curved, child: child);
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        alignment: Alignment.topRight,
        scale: Tween<double>(begin: .96, end: 1).animate(curved), // money-double: allow — масштаб
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final Size screen = MediaQuery.sizeOf(context);
    return Material(
      key: popoverKey,
      type: MaterialType.transparency,
      child: Container(
        width: size.width,
        height: size.height.clamp(240, screen.height - 80),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.all(context.radii.lg),
          border: Border.all(color: c.border),
          boxShadow: context.elevation.e2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(context.space.s4, context.space.s3, context.space.s2, 0),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(l10n.notifications_title, style: context.text.title.copyWith(color: c.textPrimary)),
                    ),
                  ),
                  const NotificationsReadAllButton(),
                ],
              ),
            ),
            Expanded(child: NotificationsView(popover: true, navigate: onNavigate)),
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.border)),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: context.space.s1),
                child: Center(
                  child: AppButton(
                    key: viewAllKey,
                    label: l10n.notifications_view_all,
                    variant: AppButtonVariant.text,
                    size: AppButtonSize.s,
                    onPressed: onViewAll,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Баннер уведомления в экране. [id] — `cartId` (scope `cart`/`checkout`) или `orderId` (scope `order`).
class NotificationBannerSlot extends ConsumerWidget {
  const NotificationBannerSlot({super.key, required this.scope, this.id, this.showOpenAction = false, this.padding});

  final NotificationBannerScope scope;
  final String? id;

  /// Показать действие перехода к цели («Открыть корзину» для `cart_*`, иначе «Открыть»).
  final bool showOpenAction;
  final EdgeInsetsGeometry? padding;

  static const Key slotKey = ValueKey<String>('notification-banner-slot');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final AppNotification? n = ref.watch(notificationBannerProvider((scope, id)));
    final Widget child;
    if (n == null) {
      child = const SizedBox.shrink();
    } else {
      final NotificationLink? link = NotificationTargets.of(n, customer: ref.watch(notificationsCustomerModeProvider));
      final bool cartKind = n.kind == NotificationKind.cartPriceChanged || n.kind == NotificationKind.cartStockChanged;
      void markRead() => unawaited(ref.read(notificationsCenterProvider.notifier).markRead(n.id));
      child = Padding(
        key: ValueKey<String>('notification-banner-${n.id}'),
        padding: padding ?? EdgeInsets.zero,
        child: NotificationBanner(
          key: slotKey,
          icon: NotificationKindStyle.of(context, n).icon,
          tone: n.kind == NotificationKind.creditBlocked
              ? NotificationBannerTone.error
              : NotificationBannerTone.warning,
          title: n.title,
          message: n.body ?? NotificationLabels.kind(l10n, n.kind),
          actionLabel: showOpenAction && link != null
              ? (cartKind ? l10n.notifications_action_open_cart : l10n.ds_button_open)
              : null,
          onAction: showOpenAction && link != null
              ? () {
                  goToNotificationTarget(context, link);
                  markRead();
                }
              : null,
          closeLabel: l10n.ds_button_close,
          onClose: markRead,
        ),
      );
    }
    return AnimatedSwitcher(duration: context.motion.of(context.motion.fast), child: child);
  }
}
