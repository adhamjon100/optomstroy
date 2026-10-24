// Содержимое SCR-44 (02 SCR-44.2–SCR-44.7): баннеры офлайна/устаревших данных, сегменты «Все · Непрочитанные (N)»
// (UI-44-001), фильтр видов (UI-44-006), список по дням (UI-44-007) с подгрузкой (UI-44-010), плашка новых
// уведомлений, пустое состояние (UI-44-008), ошибка, скелетон. Используется экраном и popover (expanded).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/app_section_header.dart';
import 'package:optomstroy/design_system/components/app_tabs.dart';
import 'package:optomstroy/design_system/components/category_chip.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/notifications/domain/entities/app_notification.dart';
import 'package:optomstroy/features/notifications/presentation/notification_targets.dart';
import 'package:optomstroy/features/notifications/presentation/notifiers/notifications_center_controller.dart';
import 'package:optomstroy/features/notifications/presentation/widgets/notification_kind_style.dart';
import 'package:optomstroy/features/notifications/presentation/widgets/notification_tile.dart';

/// Время магазина Asia/Bishkek (UTC+6, без перехода; 03 §16.4).
abstract final class NotificationTime {
  static const Duration bishkekOffset = Duration(hours: 6);

  static DateTime shop(DateTime t) => t.toUtc().add(bishkekOffset);

  /// «09:41».
  static String time(DateTime t) => DateFormat('HH:mm').format(shop(t));

  /// Заголовок дня: «Сегодня», «Вчера», «18 окт.».
  static String day(AppLocalizations l10n, String locale, DateTime t, DateTime nowUtc) {
    final DateTime d = shop(t);
    final DateTime n = shop(nowUtc);
    final DateTime day = DateTime.utc(d.year, d.month, d.day);
    final DateTime today = DateTime.utc(n.year, n.month, n.day);
    final int diff = today.difference(day).inDays;
    if (diff == 0) return l10n.notifications_day_today;
    if (diff == 1) return l10n.notifications_day_yesterday;
    return DateFormat(d.year == n.year ? 'd MMM' : 'd MMM y', locale).format(d);
  }

  static DateTime dayOf(DateTime t) {
    final DateTime d = shop(t);
    return DateTime.utc(d.year, d.month, d.day);
  }
}

/// Переход к цели уведомления: `go` с переключением ветки или `push` (navigation §2.2, §5.1).
typedef NotificationNavigator = void Function(BuildContext context, NotificationLink link);

/// Навигация по умолчанию — go_router приложения.
void goToNotificationTarget(BuildContext context, NotificationLink link) {
  final GoRouter? router = GoRouter.maybeOf(context);
  if (router == null) return;
  switch (link.navigation) {
    case NotificationNavigation.go:
      router.go(link.location);
    case NotificationNavigation.push:
      unawaited(router.push<void>(link.location));
  }
}

/// Кнопка «Прочитать все» (UI-44-001): disabled без непрочитанных, loading во время запроса.
class NotificationsReadAllButton extends ConsumerWidget {
  const NotificationsReadAllButton({super.key});

  static const Key buttonKey = ValueKey<String>('notifications-read-all');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ({int unread, bool readingAll}) s = ref.watch(
      notificationsCenterProvider.select((NotificationsCenterState s) => (unread: s.unread, readingAll: s.readingAll)),
    );
    return AppButton(
      key: buttonKey,
      label: l10n.notifications_read_all,
      variant: AppButtonVariant.text,
      size: AppButtonSize.s,
      loading: s.readingAll,
      onPressed: s.unread == 0 ? null : () => unawaited(ref.read(notificationsCenterProvider.notifier).markAllRead()),
    );
  }
}

/// Список уведомлений с фильтрами.
class NotificationsView extends ConsumerStatefulWidget {
  const NotificationsView({super.key, this.popover = false, this.navigate = goToNotificationTarget});

  /// Popover (expanded): строки 56, без фильтра видов, последние 20.
  final bool popover;

  /// Переход к цели (popover сначала закрывается).
  final NotificationNavigator navigate;

  static const Key listKey = ValueKey<String>('notifications-list');
  static const Key segmentsKey = ValueKey<String>('notifications-segments');

  /// Сегмент «Все» (`false`) / «Непрочитанные» (`true`).
  static Key segmentKey(bool unreadOnly) => ValueKey<String>('notifications-segment-${unreadOnly ? 'unread' : 'all'}');
  static const Key newAboveKey = ValueKey<String>('notifications-new-above');
  static const Key staleKey = ValueKey<String>('notifications-stale');
  static Key kindChipKey(NotificationKindGroup g) => ValueKey<String>('notifications-kind-${g.name}');

  /// Popover: последние 20 (02 SCR-44.2).
  static const int popoverLimit = 20;

  @override
  ConsumerState<NotificationsView> createState() => _NotificationsViewState();
}

class _NotificationsViewState extends ConsumerState<NotificationsView> {
  final ScrollController _scroll = ScrollController();

  NotificationsCenterController get _controller => ref.read(notificationsCenterProvider.notifier);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final ScrollPosition p = _scroll.position;
    if (p.pixels <= 0) _controller.clearNewAbove();
    if (!widget.popover && p.pixels >= p.maxScrollExtent - 200) unawaited(_controller.loadMore());
  }

  /// Режим клиента (цели уведомлений — только разделы клиента; читается в `build`).
  bool _customer = false;

  void _open(AppNotification n) {
    final NotificationLink? link = NotificationTargets.of(n, customer: ref.read(notificationsCustomerModeProvider));
    // Сначала переход (мгновенно), затем отметка о прочтении (02 SCR-44.4).
    if (link != null) widget.navigate(context, link);
    unawaited(_controller.markRead(n.id));
  }

  NotificationTileAction? _action(AppLocalizations l10n, AppNotification n) => switch (n.kind) {
    NotificationKind.cartPriceChanged ||
    NotificationKind.cartStockChanged => NotificationTileAction(l10n.notifications_action_open_cart, () => _open(n)),
    NotificationKind.syncError => NotificationTileAction(l10n.notifications_action_details, () => _open(n)),
    NotificationKind.system when n.target == NotificationTarget.sessions => NotificationTileAction(
      l10n.notifications_action_not_me,
      () {
        widget.navigate(context, NotificationTargets.sessions);
        unawaited(_controller.markRead(n.id));
      },
    ),
    _ => null,
  };

  void _toTop() {
    _controller.clearNewAbove();
    if (_scroll.hasClients) {
      unawaited(_scroll.animateTo(0, duration: context.motion.of(context.motion.base), curve: Curves.easeOut));
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final NotificationsCenterState s = ref.watch(notificationsCenterProvider);
    final OnlineStatus online = ref.watch(onlineStatusProvider).value ?? OnlineStatus.unknown;
    _customer = ref.watch(notificationsCustomerModeProvider);
    final DateTime now = ref.read(clockProvider).nowUtc();
    final bool offline = online == OnlineStatus.offline || (s.fromCache && s.failure is NetworkFailure);
    final bool stale =
        !offline &&
        s.failure != null &&
        s.syncedAt != null &&
        now.difference(s.syncedAt!) > NotificationsCenterController.staleAfter;
    final bool compact = context.windowClass == WindowClass.compact;

    if (s.newAbove > 0 && (!_scroll.hasClients || _scroll.offset <= 0)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _controller.clearNewAbove();
      });
    }

    final List<Widget> header = <Widget>[
      if (offline)
        OfflineBanner(variant: OfflineBannerVariant.offline, dataAsOf: s.syncedAt, now: now)
      else if (online == OnlineStatus.serverDown)
        const OfflineBanner(variant: OfflineBannerVariant.serverDown)
      else if (stale)
        Padding(
          key: NotificationsView.staleKey,
          padding: EdgeInsets.fromLTRB(context.space.s4, context.space.s2, context.space.s4, 0),
          child: ErrorState.banner(
            message: l10n.notifications_stale_banner(NotificationTime.time(s.syncedAt!)),
            tone: ErrorStateTone.warning,
            onRetry: () => unawaited(_controller.load()),
          ),
        ),
      Padding(
        padding: EdgeInsets.fromLTRB(
          context.space.s4,
          context.space.s3,
          context.space.s4,
          widget.popover ? context.space.s2 : 0,
        ),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          // UI-44-001: «Все · Непрочитанные (N)» — `AppTabs` вариант `segmented` (03 §9.49).
          child: AppTabs<bool>(
            key: NotificationsView.segmentsKey,
            variant: AppTabsVariant.segmented,
            value: s.unreadOnly,
            tabs: <AppTab<bool>>[
              AppTab<bool>(
                key: NotificationsView.segmentKey(false),
                value: false,
                label: l10n.notifications_filter_all,
              ),
              AppTab<bool>(
                key: NotificationsView.segmentKey(true),
                value: true,
                label: l10n.notifications_filter_unread(s.unread),
              ),
            ],
            onChanged: (bool unreadOnly) => unawaited(_controller.setUnreadOnly(unreadOnly)),
          ),
        ),
      ),
      if (!widget.popover)
        SizedBox(
          height: 48 + context.space.s2,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s2),
            children: <Widget>[
              for (final NotificationKindGroup g in NotificationKindGroup.values) ...<Widget>[
                CategoryChip(
                  key: NotificationsView.kindChipKey(g),
                  label: g.label(l10n),
                  variant: CategoryChipVariant.filter,
                  selected: g.selectedIn(s.kinds),
                  onTap: () => unawaited(_controller.toggleKinds(g.kinds)),
                ),
                SizedBox(width: context.space.s2),
              ],
            ],
          ),
        ),
    ];

    final Widget body = switch (s.phase) {
      NotificationsPhase.loading => _Skeleton(dense: widget.popover),
      NotificationsPhase.error => Center(
        child: Padding(
          padding: EdgeInsets.all(context.space.s4),
          child: ErrorState.inline(message: l10n.error_internal, onRetry: () => unawaited(_controller.load())),
        ),
      ),
      NotificationsPhase.ready when s.visible.isEmpty => _empty(l10n, s),
      NotificationsPhase.ready => _list(l10n, s, now, compact: compact),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ...header,
        Expanded(
          child: Stack(
            children: <Widget>[
              Positioned.fill(child: body),
              if (s.newAbove > 0 && _scroll.hasClients && _scroll.offset > 0)
                Positioned(
                  top: context.space.s2,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: CategoryChip(
                      key: NotificationsView.newAboveKey,
                      label: l10n.notifications_new_above(s.newAbove),
                      icon: Icons.arrow_upward_rounded,
                      selected: true,
                      onTap: _toTop,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _empty(AppLocalizations l10n, NotificationsCenterState s) {
    final bool filtered = s.unreadOnly || s.kinds.isNotEmpty;
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(context.space.s4),
        child: EmptyState(
          variant: EmptyStateVariant.notifications,
          // SCR-44.7: «Уведомлений нет»; при фильтре — «Нет уведомлений выбранного вида» и «Сбросить фильтры».
          title: filtered ? l10n.notifications_empty_filtered : l10n.notifications_empty_title,
          actionLabel: filtered && !widget.popover ? l10n.notifications_reset_filters : null,
          onAction: filtered && !widget.popover ? () => unawaited(_controller.resetFilters()) : null,
        ),
      ),
    );
  }

  Widget _list(AppLocalizations l10n, NotificationsCenterState s, DateTime now, {required bool compact}) {
    final String locale = Localizations.localeOf(context).toLanguageTag();
    List<AppNotification> items = s.visible;
    if (widget.popover && items.length > NotificationsView.popoverLimit) {
      items = items.sublist(0, NotificationsView.popoverLimit);
    }
    final List<Object> rows = <Object>[];
    DateTime? day;
    for (final AppNotification n in items) {
      final DateTime d = NotificationTime.dayOf(n.createdAt);
      if (d != day) {
        day = d;
        rows.add(NotificationTime.day(l10n, locale, n.createdAt, now));
      }
      rows.add(n);
    }
    final bool more = !widget.popover && (s.hasMore || s.loadingMore);
    return RefreshIndicator(
      onRefresh: _controller.load,
      child: ListView.builder(
        key: NotificationsView.listKey,
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: rows.length + (more ? 1 : 0),
        itemBuilder: (BuildContext context, int i) {
          if (i >= rows.length) {
            return Padding(
              padding: EdgeInsets.all(context.space.s4),
              child: const Center(child: AppProgress.circular(size: 24)),
            );
          }
          final Object row = rows[i];
          if (row is String) {
            return SizedBox(
              height: 32,
              child: AppSectionHeader(
                title: row,
                padding: EdgeInsets.symmetric(horizontal: context.space.s4),
              ),
            );
          }
          final AppNotification n = row as AppNotification;
          final NotificationLink? link = NotificationTargets.of(n, customer: _customer);
          return NotificationTile(
            key: ValueKey<String>('notification-row-${n.id}'),
            notification: n,
            read: s.isRead(n),
            time: NotificationTime.time(n.createdAt),
            dense: widget.popover,
            swipeToRead: compact && !widget.popover,
            expandOnTap: link == null,
            action: widget.popover ? null : _action(l10n, n),
            onTap: () => _open(n),
            onMarkRead: () => unawaited(_controller.markRead(n.id)),
          );
        },
      ),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton({required this.dense});

  final bool dense;

  @override
  Widget build(BuildContext context) => ListView(
    physics: const NeverScrollableScrollPhysics(),
    padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s2),
    children: <Widget>[
      for (int i = 0; i < 6; i++)
        Padding(
          padding: EdgeInsets.symmetric(vertical: context.space.s1),
          child: SkeletonBox(height: dense ? 56 : 72),
        ),
    ],
  );
}
