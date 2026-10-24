// SCR-44 «Центр уведомлений» (`/notifications?unread=1`; все роли; 02 ч. E SCR-44; D-41, RM-F-008).
//
// Compact/medium — экран в ветке `profile` (шапка «Уведомления» + «Назад» + «Прочитать все»; navigation.md §2.2,
// 02 §8 п. 22 «испр.»); expanded — тот же экран «Все уведомления» с контентом ≤ 720 по центру (popover под
// колокольчиком — [NotificationsPopover]). Опрос — контроллер (60 с) + при открытии и возврате в foreground.
// Снекбар UI-44-011 — новые `severity=error` (не чаще 1 раза в 60 с).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/notifications/presentation/notification_targets.dart';
import 'package:optomstroy/features/notifications/presentation/notifiers/notifications_center_controller.dart';
import 'package:optomstroy/features/notifications/presentation/widgets/notifications_view.dart';

/// SCR-44.
class NotificationsScreen extends ConsumerStatefulWidget {
  /// Экран SCR-44.
  const NotificationsScreen({this.unreadOnly = false, super.key});

  /// Только непрочитанные (`unread=1`).
  final bool unreadOnly;

  /// Ключ экрана (сохранён от заглушки основы: тесты маршрутов): `stub-SCR-44`.
  static const ValueKey<String> stubKey = ValueKey<String>('stub-SCR-44');

  /// Ширина контента на expanded (02 SCR-44.2).
  static const double maxContentWidth = 720; // money-double: allow — ширина в lp

  @override
  ConsumerState<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> with WidgetsBindingObserver {
  NotificationsCenterController get _controller => ref.read(notificationsCenterProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final bool same = ref.read(notificationsCenterProvider).unreadOnly == widget.unreadOnly;
      unawaited(same ? _controller.load() : _controller.setUnreadOnly(widget.unreadOnly));
    });
  }

  @override
  void didUpdateWidget(NotificationsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.unreadOnly != widget.unreadOnly) unawaited(_controller.setUnreadOnly(widget.unreadOnly));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Возврат в foreground — опрос (08 §4.16.1).
    if (state == AppLifecycleState.resumed) unawaited(_controller.poll());
  }

  void _announce(NotificationAnnouncement? previous, NotificationAnnouncement? next) {
    if (next == null || next.seq == previous?.seq || !mounted) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final NotificationLink? link = NotificationTargets.of(
      next.notification,
      customer: ref.read(notificationsCustomerModeProvider),
    );
    AppSnackbar.show(
      context,
      message: next.notification.title,
      variant: AppSnackbarVariant.error,
      actionLabel: link == null ? null : l10n.ds_button_open,
      onAction: link == null
          ? null
          : () {
              goToNotificationTarget(context, link);
              unawaited(_controller.markRead(next.notification.id));
            },
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<NotificationAnnouncement?>(
      notificationsCenterProvider.select((NotificationsCenterState s) => s.announcement),
      _announce,
    );
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Scaffold(
      key: NotificationsScreen.stubKey,
      backgroundColor: context.colors.background,
      appBar: AppBar(
        title: Text(l10n.notifications_title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          const NotificationsReadAllButton(),
          SizedBox(width: context.space.s2),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: NotificationsScreen.maxContentWidth),
          child: const NotificationsView(),
        ),
      ),
    );
  }
}
