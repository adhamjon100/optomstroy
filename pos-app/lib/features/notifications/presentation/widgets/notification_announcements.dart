// UI-44-011 (02 SCR-44.3, SCR-44.4; D-41): снекбар о новом уведомлении `severity=error` с «Открыть» — на любом
// экране оболочки, кроме оформления (`/checkout`) и приёма оплаты (`/payments/new`); на SCR-44 снекбар показывает сам
// экран. Не чаще 1 раза в 60 с (ограничивает контроллер центра). Оболочка приложения оборачивает ветки этим виджетом.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/features/notifications/presentation/notification_targets.dart';
import 'package:optomstroy/features/notifications/presentation/notifiers/notifications_center_controller.dart';
import 'package:optomstroy/features/notifications/presentation/widgets/notifications_view.dart'
    show goToNotificationTarget;

/// Слушатель включён (корень `app/di/overrides.dart` — `true`, когда подключены `notificationsBindings`): без
/// репозитория уведомлений центр не создаётся (тесты оболочки без фичи notifications).
final notificationAnnouncementsEnabledProvider = Provider<bool>((ref) => false);

/// Пути, где снекбар оболочки не показывается.
const List<String> notificationAnnouncementQuietPaths = <String>['/checkout', '/payments/new', '/notifications'];

/// Слушатель новых уведомлений `severity=error` для оболочки.
class NotificationAnnouncements extends ConsumerWidget {
  const NotificationAnnouncements({required this.child, super.key});

  final Widget child;

  /// Текущий путь go_router (`null` — вне роутера).
  static String? _path(BuildContext context) {
    try {
      return GoRouter.of(context).routerDelegate.currentConfiguration.uri.path;
    } on Object {
      return null;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(notificationAnnouncementsEnabledProvider)) return child;
    ref.listen<NotificationAnnouncement?>(
      notificationsCenterProvider.select((NotificationsCenterState s) => s.announcement),
      (NotificationAnnouncement? previous, NotificationAnnouncement? next) {
        if (next == null || next.seq == previous?.seq || !context.mounted) return;
        final String? path = _path(context);
        if (path != null && notificationAnnouncementQuietPaths.any(path.startsWith)) return;
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
                  unawaited(ref.read(notificationsCenterProvider.notifier).markRead(next.notification.id));
                },
        );
      },
    );
    return child;
  }
}
