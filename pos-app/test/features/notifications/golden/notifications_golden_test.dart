// Golden RM-F-008 (alchemist; D-18): SCR-44 «Центр уведомлений» на compact / medium / expanded (палитра B,
// reduce-motion), офлайн (compact), popover под колокольчиком (expanded) и баннеры уведомлений в экранах.
// Эталоны — Windows (`goldens/windows/`) и CI (`goldens/ci/`).
//
// Обновить эталоны: flutter test test/features/notifications/golden --update-goldens
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/notification_banner.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/notifications/domain/entities/app_notification.dart';
import 'package:optomstroy/features/notifications/presentation/notifiers/notifications_center_controller.dart';
import 'package:optomstroy/features/notifications/presentation/screens/notifications_screen.dart';
import 'package:optomstroy/features/notifications/presentation/widgets/notifications_connected.dart';

import '../notifications_test_support.dart';

const Map<String, Size> _windows = <String, Size>{
  'compact': Size(360, 760),
  'medium': Size(800, 900),
  'expanded': Size(1280, 800),
};

Widget _frame(Size size, NotifStand stand, Widget child) => SizedBox(
  width: size.width,
  height: size.height,
  child: ProviderScope(
    overrides: stand.overrides,
    child: MaterialApp(
      theme: AppTheme.light(),
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      debugShowCheckedModeBanner: false,
      builder: (BuildContext context, Widget? app) => MediaQuery(
        data: MediaQuery.of(context).copyWith(size: size, disableAnimations: true, padding: EdgeInsets.zero),
        child: app!,
      ),
      home: child,
    ),
  ),
);

NotifStand _offlineStand() {
  final NotifStand stand = NotifStand(online: OnlineStatus.offline);
  stand.repo
    ..cached = sampleNotifications()
    ..onList = (NotificationsQuery q) async =>
        const FailureResult<NotificationsPage>(NetworkFailure(NetworkFailureKind.offline));
  return stand;
}

Widget _popover(Size size) => _frame(
  size,
  NotifStand(),
  Material(
    color: DsColors.lightB.background,
    child: Stack(
      children: <Widget>[
        Positioned(
          top: 68,
          right: 24,
          child: NotificationsPopover(onNavigate: (BuildContext _, _) {}, onViewAll: () {}),
        ),
      ],
    ),
  ),
);

Widget _banners(Size size) => _frame(
  size,
  NotifStand(),
  Material(
    color: DsColors.lightB.background,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const NotificationBannerSlot(scope: NotificationBannerScope.cart, id: 'c1', showOpenAction: true),
          const SizedBox(height: 12),
          NotificationBanner(
            icon: Icons.inventory_2_rounded,
            title: 'Остаток в корзине изменился',
            message: 'Смеситель Grohe: доступно 2 шт.',
            onClose: () {},
            closeLabel: 'Закрыть',
          ),
          const SizedBox(height: 12),
          NotificationBanner(
            icon: Icons.block_rounded,
            tone: NotificationBannerTone.error,
            title: 'Продажа в долг заблокирована',
            message: 'Выберите другой способ оплаты',
            actionLabel: 'Открыть',
            onAction: () {},
            onClose: () {},
            closeLabel: 'Закрыть',
          ),
        ],
      ),
    ),
  ),
);

void main() {
  for (final MapEntry<String, Size> w in _windows.entries) {
    unawaited(
      goldenTest(
        'SCR-44 список · ${w.key}',
        fileName: 'scr44_list_${w.key}',
        constraints: BoxConstraints.tight(w.value),
        builder: () => _frame(w.value, NotifStand(), const NotificationsScreen()),
      ),
    );
  }
  unawaited(
    goldenTest(
      'SCR-44 офлайн (кэш) · compact',
      fileName: 'scr44_offline_compact',
      constraints: BoxConstraints.tight(_windows['compact']!),
      builder: () => _frame(_windows['compact']!, _offlineStand(), const NotificationsScreen()),
    ),
  );
  unawaited(
    goldenTest(
      'SCR-44 popover · expanded',
      fileName: 'scr44_popover_expanded',
      constraints: BoxConstraints.tight(_windows['expanded']!),
      builder: () => _popover(_windows['expanded']!),
    ),
  );
  unawaited(
    goldenTest(
      'Баннеры уведомлений · compact',
      fileName: 'notification_banners_compact',
      constraints: BoxConstraints.tight(const Size(360, 320)),
      builder: () => _banners(const Size(360, 320)),
    ),
  );
}
