// SCR-44 «Центр уведомлений» (RM-F-008; 02 SCR-44; ядро §19.4): бейдж = непрочитанные, «Прочитать все»
// (идемпотентно), офлайн — отметки в outbox `notification.read`, переходы к объектам, фильтры, баннеры.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/notification_banner.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/notifications/domain/entities/app_notification.dart';
import 'package:optomstroy/features/notifications/presentation/notifiers/notifications_center_controller.dart';
import 'package:optomstroy/features/notifications/presentation/screens/notifications_screen.dart';
import 'package:optomstroy/features/notifications/presentation/widgets/notification_announcements.dart';
import 'package:optomstroy/features/notifications/presentation/widgets/notification_kind_style.dart';
import 'package:optomstroy/features/notifications/presentation/widgets/notification_tile.dart';
import 'package:optomstroy/features/notifications/presentation/widgets/notifications_connected.dart';
import 'package:optomstroy/features/notifications/presentation/widgets/notifications_view.dart';

import 'notifications_test_support.dart';

const Key _badge = ValueKey<String>('notification-bell-badge');

GoRouter _router(String initial) => GoRouter(
  initialLocation: initial,
  routes: <RouteBase>[
    GoRoute(
      path: '/home',
      builder: (_, _) => Scaffold(
        appBar: AppBar(actions: const <Widget>[ConnectedNotificationBell()]),
        body: const Column(
          children: <Widget>[
            NotificationBannerSlot(scope: NotificationBannerScope.cart, id: 'c1', showOpenAction: true),
          ],
        ),
      ),
    ),
    GoRoute(
      path: '/notifications',
      builder: (_, GoRouterState s) => NotificationsScreen(unreadOnly: s.uri.queryParameters['unread'] == '1'),
    ),
    GoRoute(path: '/orders/:id', builder: (_, GoRouterState s) => Text('order:${s.pathParameters['id']}')),
    GoRoute(path: '/sync', builder: (_, GoRouterState s) => Text('sync:${s.uri.query}')),
    GoRoute(path: '/cart', builder: (_, GoRouterState s) => Text('cart:${s.uri.query}')),
    GoRoute(path: '/cart/parked', builder: (_, _) => const Text('parked')),
    GoRoute(path: '/customers/:id', builder: (_, GoRouterState s) => Text('customer:${s.pathParameters['id']}')),
    GoRoute(path: '/settings', builder: (_, GoRouterState s) => Text('settings:${s.uri.query}')),
  ],
);

Future<GoRouter> _pump(
  WidgetTester tester,
  NotifStand stand, {
  String initial = '/notifications',
  Size size = const Size(400, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final GoRouter router = _router(initial);
  await tester.pumpWidget(
    ProviderScope(
      overrides: stand.overrides,
      child: MaterialApp.router(
        theme: AppTheme.light(),
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  group('бейдж колокольчика', () {
    testWidgets('AC-UI-44-001, AC-UI-44-004: бейдж = числу непрочитанных; «Прочитать все» убирает бейдж', (
      WidgetTester tester,
    ) async {
      final NotifStand stand = NotifStand();
      await _pump(tester, stand, initial: '/home', size: const Size(800, 900));
      expect(find.descendant(of: find.byKey(_badge), matching: find.text('3')), findsOneWidget);
      expect(find.bySemanticsLabel('Уведомления, 3 непрочитанных'), findsWidgets);

      // Сервер сообщил о новом непрочитанном — опрос обновляет бейдж.
      stand
        ..serverItems = <AppNotification>[
          AppNotification(
            id: 'n0',
            rawKind: 'order_status',
            title: 'Заказ отгружен',
            orderId: 'o9',
            createdAt: DateTime.utc(2026, 10, 22, 3, 59),
            severity: NotificationSeverity.info,
          ),
          ...stand.serverItems,
        ]
        ..serverUnread = 4;
      final ProviderContainer c = ProviderScope.containerOf(tester.element(find.byType(ConnectedNotificationBell)));
      await c.read(notificationsCenterProvider.notifier).poll();
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byKey(_badge), matching: find.text('4')), findsOneWidget);

      await c.read(notificationsCenterProvider.notifier).markAllRead();
      await tester.pumpAndSettle();
      expect(find.byKey(_badge), findsNothing);
    });

    testWidgets('бейдж: compact — точка, «99+» при > 99', (WidgetTester tester) async {
      final NotifStand stand = NotifStand()..serverUnread = 120;
      await _pump(tester, stand, initial: '/home', size: const Size(800, 900));
      expect(find.text('99+'), findsOneWidget);
    });
  });

  group('SCR-44', () {
    testWidgets('список по дням, сегменты, иконки и подписи видов', (WidgetTester tester) async {
      final NotifStand stand = NotifStand();
      await _pump(tester, stand);
      expect(find.text('Уведомления'), findsOneWidget);
      expect(find.text('Непрочитанные (3)'), findsOneWidget);
      expect(find.text('Сегодня'), findsOneWidget);
      expect(find.text('Вчера'), findsOneWidget);
      expect(find.text('09:41'), findsOneWidget);
      expect(find.byKey(NotificationTile.unreadDotKey('n1')), findsOneWidget);
      expect(find.byKey(NotificationTile.unreadDotKey('n4')), findsNothing);
      expect(find.byIcon(Icons.sync_problem_rounded), findsOneWidget);
      // Статус заказа — StatusChip; действия строк UI-44-009.
      expect(find.text('Согласован'), findsWidgets);
      expect(find.text('Открыть корзину'), findsOneWidget);
      expect(find.text('Подробнее'), findsOneWidget);
      expect(find.text('Это не я'), findsOneWidget);
      // Чувствительный вид без текста (кэш/сервер) — подпись вида из ARB.
      await tester.drag(find.byKey(NotificationsView.listKey), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(find.text('Оплата'), findsWidgets);
    });

    testWidgets(
      'AC-UI-44-004: «Прочитать все»: один запрос с Idempotency-Key, бейдж 0, кнопка неактивна; повтор идемпотентен',
      (WidgetTester tester) async {
        final NotifStand stand = NotifStand();
        await _pump(tester, stand);
        await tester.tap(find.byKey(NotificationsReadAllButton.buttonKey));
        await tester.pumpAndSettle();
        expect(stand.callsOf('markAllRead'), hasLength(1));
        expect(stand.callsOf('markAllRead').single.args.single, isA<String>());
        expect(
          stand.repo.lastMarkAllReadBefore,
          isNull,
          reason: 'онлайн — без ?before=: сервер отмечает на момент обработки (08 §4.16.2 «Уточнения», RC-6)',
        );
        expect(find.text('Непрочитанные (0)'), findsOneWidget);
        expect(find.byKey(NotificationTile.unreadDotKey('n1')), findsNothing);
        await tester.tap(find.byKey(NotificationsReadAllButton.buttonKey));
        await tester.pumpAndSettle();
        expect(stand.callsOf('markAllRead'), hasLength(1), reason: 'без непрочитанных кнопка неактивна');

        // Повтор операции (например, после переподключения) — снова 200 {unreadCount: 0}, состояние то же.
        final ProviderContainer c = ProviderScope.containerOf(tester.element(find.byType(NotificationsScreen)));
        await c.read(notificationsCenterProvider.notifier).markAllRead();
        await tester.pumpAndSettle();
        expect(stand.callsOf('markAllRead'), hasLength(2));
        expect(c.read(notificationsCenterProvider).unread, 0);
        expect(stand.queue.readAll, 0, reason: 'онлайн — без outbox');
      },
    );

    testWidgets('AC-UI-44-009: сегмент «Непрочитанные» и фильтр видов передаются в запрос', (
      WidgetTester tester,
    ) async {
      final NotifStand stand = NotifStand();
      await _pump(tester, stand);
      await tester.tap(find.text('Непрочитанные (3)'));
      await tester.pumpAndSettle();
      final NotificationsQuery q = stand.callsOf('list').last.args.single! as NotificationsQuery;
      expect(q.unreadOnly, isTrue);
      expect(find.byKey(NotificationTile.keyOf('n4')), findsNothing);

      await tester.tap(find.byKey(NotificationsView.kindChipKey(NotificationKindGroup.cart)));
      await tester.pumpAndSettle();
      final NotificationsQuery q2 = stand.callsOf('list').last.args.single! as NotificationsQuery;
      expect(q2.kinds, <NotificationKind>{NotificationKind.cartPriceChanged, NotificationKind.cartStockChanged});
      expect(find.byKey(NotificationTile.keyOf('n3')), findsOneWidget);
      expect(find.byKey(NotificationTile.keyOf('n1')), findsNothing);

      // Пустой результат при фильтре — «Нет уведомлений выбранного вида» + «Сбросить фильтры».
      await tester.tap(find.byKey(NotificationsView.kindChipKey(NotificationKindGroup.cart)));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(NotificationsView.kindChipKey(NotificationKindGroup.returns)),
        120,
        scrollable: find
            .ancestor(
              of: find.byKey(NotificationsView.kindChipKey(NotificationKindGroup.cart)),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(NotificationsView.kindChipKey(NotificationKindGroup.returns)));
      await tester.pumpAndSettle();
      expect(find.text('Нет уведомлений выбранного вида'), findsOneWidget);
      await tester.tap(find.text('Сбросить фильтры'));
      await tester.pumpAndSettle();
      expect(find.byKey(NotificationTile.keyOf('n4')), findsOneWidget);
    });

    testWidgets('маршрут ?unread=1 открывает сегмент «Непрочитанные»', (WidgetTester tester) async {
      final NotifStand stand = NotifStand();
      await _pump(tester, stand, initial: '/notifications?unread=1');
      expect((stand.callsOf('list').last.args.single! as NotificationsQuery).unreadOnly, isTrue);
      expect(find.byKey(NotificationTile.keyOf('n5')), findsNothing);
    });
  });

  group('переходы к объекту', () {
    testWidgets('AC-UI-44-002: order_status → /orders/{id} (go) и отметка прочитанным', (WidgetTester tester) async {
      final NotifStand stand = NotifStand();
      await _pump(tester, stand);
      await tester.tap(find.byKey(NotificationTile.keyOf('n2')));
      await tester.pumpAndSettle();
      expect(find.text('order:o1'), findsOneWidget);
      expect(stand.callsOf('markRead').single.args.first, 'n2');
    });

    testWidgets('AC-UI-44-003: sync_error → /sync?entity=&runId= (push, «Назад» — SCR-44)', (
      WidgetTester tester,
    ) async {
      final NotifStand stand = NotifStand();
      final GoRouter router = await _pump(tester, stand);
      await tester.tap(find.byKey(NotificationTile.actionKey('n1')));
      await tester.pumpAndSettle();
      expect(find.text('sync:entity=stock&runId=r1'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.byType(NotificationsScreen), findsOneWidget);
      expect(find.byKey(NotificationTile.unreadDotKey('n1')), findsNothing);
    });

    testWidgets('AC-UI-44-011: cart_price_changed → /cart?cartId=; «Это не я» → настройки «Сеансы»', (
      WidgetTester tester,
    ) async {
      final NotifStand stand = NotifStand();
      final GoRouter router = await _pump(tester, stand);
      await tester.tap(find.byKey(NotificationTile.actionKey('n3')));
      await tester.pumpAndSettle();
      expect(find.text('cart:cartId=c1'), findsOneWidget);
      router.go('/notifications');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(NotificationTile.actionKey('n4')));
      await tester.pumpAndSettle();
      expect(find.text('settings:section=sessions'), findsOneWidget);
    });
  });

  group('popover (expanded)', () {
    testWidgets(
      'AC-UI-44-008: колокольчик открывает popover; строка → цель, popover закрыт; «Все уведомления» → SCR-44',
      (WidgetTester tester) async {
        final NotifStand stand = NotifStand();
        await _pump(tester, stand, initial: '/home', size: const Size(1280, 800));
        await tester.tap(find.byKey(ConnectedNotificationBell.bellKey));
        await tester.pumpAndSettle();
        expect(find.byKey(NotificationsPopover.popoverKey), findsOneWidget);
        await tester.tap(find.byKey(NotificationTile.keyOf('n2')));
        await tester.pumpAndSettle();
        expect(find.byKey(NotificationsPopover.popoverKey), findsNothing);
        expect(find.text('order:o1'), findsOneWidget);
        expect(stand.callsOf('markRead').single.args.first, 'n2');
      },
    );

    testWidgets('AC-UI-44-008: «Все уведомления»; Esc закрывает', (WidgetTester tester) async {
      final NotifStand stand = NotifStand();
      await _pump(tester, stand, initial: '/home', size: const Size(1280, 800));
      await tester.tap(find.byKey(ConnectedNotificationBell.bellKey));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(NotificationsPopover.popoverKey), findsNothing);
      await tester.tap(find.byKey(ConnectedNotificationBell.bellKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(NotificationsPopover.viewAllKey));
      await tester.pumpAndSettle();
      expect(find.byType(NotificationsScreen), findsOneWidget);
    });
  });

  group('объявление severity=error (UI-44-011)', () {
    testWidgets('новое sync_error при опросе — снекбар «Открыть»', (WidgetTester tester) async {
      final NotifStand stand = NotifStand();
      await _pump(tester, stand);
      stand.serverItems = <AppNotification>[
        AppNotification(
          id: 'n9',
          rawKind: 'credit_blocked',
          title: 'Продажа в долг заблокирована',
          orderId: 'o7',
          createdAt: DateTime.utc(2026, 10, 22, 3, 58),
          severity: NotificationSeverity.error,
        ),
        ...stand.serverItems,
      ];
      final ProviderContainer c = ProviderScope.containerOf(tester.element(find.byType(NotificationsScreen)));
      await c.read(notificationsCenterProvider.notifier).poll();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.widgetWithText(SnackBar, 'Продажа в долг заблокирована'), findsOneWidget);
      expect((stand.callsOf('list').last.args.single! as NotificationsQuery).since, DateTime.utc(2026, 10, 22, 3, 41));
    });
  });

  group('офлайн — outbox notification.read', () {
    testWidgets(
      'AC-UI-44-007: нет сети: список из кэша + OfflineBanner; отметки — локально и в очередь, бейдж уменьшается',
      (WidgetTester tester) async {
        final NotifStand stand = NotifStand(online: OnlineStatus.offline);
        stand.repo
          ..cached = sampleNotifications()
          ..onList = (NotificationsQuery q) async =>
              const FailureResult<NotificationsPage>(NetworkFailure(NetworkFailureKind.offline));
        await _pump(tester, stand);
        expect(find.byType(OfflineBanner), findsOneWidget);
        expect(find.text('Непрочитанные (3)'), findsOneWidget);

        // Свайп влево — «Прочитано».
        await tester.drag(find.byKey(NotificationTile.keyOf('n3')), const Offset(-300, 0));
        await tester.pumpAndSettle();
        expect(stand.queue.reads, <String>['n3']);
        expect(stand.callsOf('markRead'), isEmpty, reason: 'офлайн — без сетевого запроса');
        expect(find.text('Непрочитанные (2)'), findsOneWidget);

        await tester.tap(find.byKey(NotificationsReadAllButton.buttonKey));
        await tester.pumpAndSettle();
        expect(stand.queue.readAll, 1);
        expect(stand.callsOf('markAllRead'), isEmpty);
        expect(find.text('Непрочитанные (0)'), findsOneWidget);
      },
    );

    testWidgets(
      'RC-6: часы устройства отстают от сервера — «Прочитать все» отмечает показанные; граница офлайн — createdAt '
      'самого нового уведомления кэша, а не часы устройства',
      (WidgetTester tester) async {
        // Уведомление сервера «из будущего» относительно часов устройства (nowUtc = 04:00).
        final AppNotification ahead = AppNotification(
          id: 'n0',
          rawKind: 'order_status',
          title: 'Заказ отгружен',
          orderId: 'o9',
          createdAt: DateTime.utc(2026, 10, 22, 4, 30),
          severity: NotificationSeverity.info,
        );
        final NotifStand stand = NotifStand(online: OnlineStatus.offline);
        stand.repo
          ..cached = <AppNotification>[ahead, ...sampleNotifications()]
          ..onList = (NotificationsQuery q) async =>
              const FailureResult<NotificationsPage>(NetworkFailure(NetworkFailureKind.offline));
        await _pump(tester, stand);
        expect(find.byKey(NotificationTile.unreadDotKey('n0')), findsOneWidget);

        await tester.tap(find.byKey(NotificationsReadAllButton.buttonKey));
        await tester.pumpAndSettle();
        expect(stand.queue.lastReadAllBefore, ahead.createdAt, reason: 'граница — время сервера (createdAt)');
        expect(find.byKey(NotificationTile.unreadDotKey('n0')), findsNothing, reason: 'показанное — прочитано');
        expect(find.text('Непрочитанные (0)'), findsOneWidget);
      },
    );

    testWidgets('RC-6: онлайн, часы устройства отстают — показанное уведомление новее часов тоже прочитано', (
      WidgetTester tester,
    ) async {
      final NotifStand stand = NotifStand();
      stand
        ..serverItems = <AppNotification>[
          AppNotification(
            id: 'n0',
            rawKind: 'order_status',
            title: 'Заказ отгружен',
            orderId: 'o9',
            createdAt: DateTime.utc(2026, 10, 22, 4, 30),
            severity: NotificationSeverity.info,
          ),
          ...stand.serverItems,
        ]
        ..serverUnread = 4;
      await _pump(tester, stand);
      expect(find.byKey(NotificationTile.unreadDotKey('n0')), findsOneWidget);
      await tester.tap(find.byKey(NotificationsReadAllButton.buttonKey));
      await tester.pumpAndSettle();
      expect(stand.repo.lastMarkAllReadBefore, isNull);
      expect(find.byKey(NotificationTile.unreadDotKey('n0')), findsNothing);
      expect(find.byKey(NotificationTile.unreadDotKey('n1')), findsNothing);
    });

    testWidgets('запрос отметки не дошёл до сервера — запись в очередь, отметка не откатывается', (
      WidgetTester tester,
    ) async {
      final NotifStand stand = NotifStand();
      stand.repo.onMarkRead = (String id) async => const FailureResult<int>(NetworkFailure(NetworkFailureKind.timeout));
      await _pump(tester, stand);
      await tester.tap(find.byKey(NotificationTile.keyOf('n2')));
      await tester.pumpAndSettle();
      expect(stand.callsOf('markRead'), hasLength(1));
      expect(stand.queue.reads, <String>['n2']);
    });

    testWidgets('сеть восстановлена — список кэша сменяется ответом сервера', (WidgetTester tester) async {
      final NotifStand stand = NotifStand(online: OnlineStatus.offline);
      var offline = true;
      final Future<Result<NotificationsPage>> Function(NotificationsQuery) server = stand.repo.onList!;
      stand.repo
        ..cached = sampleNotifications().take(2).toList()
        ..onList = (NotificationsQuery q) async =>
            offline ? const FailureResult<NotificationsPage>(NetworkFailure(NetworkFailureKind.offline)) : server(q);
      await _pump(tester, stand);
      expect(find.byKey(NotificationTile.keyOf('n3')), findsNothing);
      offline = false;
      stand.setOnline(OnlineStatus.online);
      await tester.pumpAndSettle();
      expect(find.byKey(NotificationTile.keyOf('n3')), findsOneWidget);
      expect(find.byType(OfflineBanner), findsNothing);
    });
  });

  group('баннеры экранов', () {
    testWidgets('cart_price_changed в корзине: «Открыть корзину», «Закрыть» отмечает прочитанным', (
      WidgetTester tester,
    ) async {
      final NotifStand stand = NotifStand();
      await _pump(tester, stand, initial: '/home', size: const Size(800, 900));
      expect(find.byType(NotificationBanner), findsOneWidget);
      expect(find.text('Цены в корзине изменились'), findsOneWidget);
      await tester.tap(find.byKey(NotificationBanner.closeKey));
      await tester.pumpAndSettle();
      expect(stand.callsOf('markRead').single.args.first, 'n3');
      expect(find.byType(NotificationBanner), findsNothing);
    });

    test('провайдер баннера: scope и объект', () async {
      final NotifStand stand = NotifStand();
      final ProviderContainer c = ProviderContainer(overrides: stand.overrides);
      addTearDown(c.dispose);
      c.read(notificationsCenterProvider);
      await c.read(notificationsCenterProvider.notifier).load();
      expect(c.read(notificationBannerProvider((NotificationBannerScope.cart, 'c1')))?.id, 'n3');
      expect(c.read(notificationBannerProvider((NotificationBannerScope.cart, 'c2'))), isNull);
      expect(c.read(notificationBannerProvider((NotificationBannerScope.order, 'o1'))), isNull);
    });
  });

  group('F-flutter-ui-13: UI-44-011 в оболочке', () {
    Future<ProviderContainer> pumpShell(WidgetTester tester, NotifStand stand, String initial) async {
      final GoRouter router = GoRouter(
        initialLocation: initial,
        routes: <RouteBase>[
          for (final String path in <String>['/home', '/checkout'])
            GoRoute(
              path: path,
              builder: (_, _) => NotificationAnnouncements(child: Scaffold(body: Text('page:$path'))),
            ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[...stand.overrides, notificationAnnouncementsEnabledProvider.overrideWithValue(true)],
          child: MaterialApp.router(
            theme: AppTheme.light(),
            locale: const Locale('ru'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return ProviderScope.containerOf(tester.element(find.byType(NotificationAnnouncements)));
    }

    AppNotification error() => AppNotification(
      id: 'n9',
      rawKind: 'credit_blocked',
      title: 'Продажа в долг заблокирована',
      orderId: 'o7',
      createdAt: DateTime.utc(2026, 10, 22, 3, 58),
      severity: NotificationSeverity.error,
    );

    for (final (String path, bool shown) in <(String, bool)>[('/home', true), ('/checkout', false)]) {
      testWidgets('новое severity=error на $path — снекбар ${shown ? 'показан' : 'не показан (оформление)'}', (
        WidgetTester tester,
      ) async {
        final NotifStand stand = NotifStand();
        final ProviderContainer c = await pumpShell(tester, stand, path);
        stand.serverItems = <AppNotification>[error(), ...stand.serverItems];
        await c.read(notificationsCenterProvider.notifier).poll();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.widgetWithText(SnackBar, 'Продажа в долг заблокирована'), shown ? findsOneWidget : findsNothing);
      });
    }
  });
  group('T-UI-044: недостающие AC SCR-44', () {
    testWidgets('AC-UI-44-005: непрочитанные — полоса слева, точка и полужирный текст (не только цвет)', (
      WidgetTester tester,
    ) async {
      await _pump(tester, NotifStand());
      Border? stripeOf(String id) {
        final Iterable<Container> boxes = tester.widgetList<Container>(
          find.descendant(of: find.byKey(NotificationTile.keyOf(id)), matching: find.byType(Container)),
        );
        for (final Container c in boxes) {
          final Decoration? d = c.decoration;
          if (d is BoxDecoration && d.border is Border) return d.border! as Border;
        }
        return null;
      }

      expect(stripeOf('n1')?.left.width, 3);
      expect(stripeOf('n1')?.left.color, isNot(stripeOf('n4')?.left.color));
      expect(find.byKey(NotificationTile.unreadDotKey('n1')), findsOneWidget);
      expect(find.byKey(NotificationTile.unreadDotKey('n4')), findsNothing);
      FontWeight? weightOf(String title) => DefaultTextStyle.of(tester.element(find.text(title))).style.fontWeight;
      expect(weightOf('Ошибка обмена: Остатки'), FontWeight.w600);
      expect(weightOf('Вход с нового устройства'), FontWeight.w400);
    });

    testWidgets('AC-UI-44-006: новое уведомление появляется не позже 60 с (опрос раз в 60 с при открытом приложении)', (
      WidgetTester tester,
    ) async {
      final NotifStand stand = NotifStand()..pollInterval = const Duration(seconds: 60);
      await _pump(tester, stand);
      stand.serverItems = <AppNotification>[
        AppNotification(
          id: 'n10',
          rawKind: 'order_status',
          title: 'Заказ POS-2026-000200 согласован',
          orderId: 'o10',
          createdAt: DateTime.utc(2026, 10, 22, 3, 59),
          severity: NotificationSeverity.info,
        ),
        ...stand.serverItems,
      ];
      await tester.pump(const Duration(seconds: 59));
      expect(find.text('Заказ POS-2026-000200 согласован'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Заказ POS-2026-000200 согласован'), findsOneWidget);
    });

    testWidgets('AC-UI-44-010: credit_blocked у продавца — без сумм долга (выводятся только заголовок и текст сервера, '
        'суммы из payload не показываются)', (WidgetTester tester) async {
      final NotifStand stand = NotifStand();
      stand.serverItems = <AppNotification>[
        AppNotification(
          id: 'n11',
          rawKind: 'credit_blocked',
          title: 'Продажа в долг недоступна',
          body: 'Обратитесь к старшему продавцу',
          orderId: 'o11',
          createdAt: DateTime.utc(2026, 10, 22, 3, 50),
          severity: NotificationSeverity.warning,
          payload: const <String, Object?>{'orderId': 'o11', 'overdueAmount': '15400.00', 'limitRemaining': '0.00'},
        ),
      ];
      await _pump(tester, stand);
      expect(find.text('Продажа в долг недоступна'), findsOneWidget);
      expect(find.textContaining('15400'), findsNothing);
      expect(find.textContaining('15 400'), findsNothing);
    });

    testWidgets('AC-UI-44-012: неудачные опросы дольше 5 мин — «Уведомления обновлены в {time}» с «Обновить»', (
      WidgetTester tester,
    ) async {
      final NotifStand stand = NotifStand();
      await _pump(tester, stand);
      final ProviderContainer c = ProviderScope.containerOf(tester.element(find.byType(NotificationsScreen)));
      stand.repo.onList = (NotificationsQuery q) async =>
          const FailureResult<NotificationsPage>(ServerFailure(code: 'INTERNAL', status: 500));
      stand.clock.advance(const Duration(minutes: 3));
      await c.read(notificationsCenterProvider.notifier).poll();
      await tester.pumpAndSettle();
      expect(find.byKey(NotificationsView.staleKey), findsNothing, reason: 'меньше 5 мин');
      stand.clock.advance(const Duration(minutes: 3));
      await c.read(notificationsCenterProvider.notifier).poll();
      await tester.pumpAndSettle();
      expect(find.byKey(NotificationsView.staleKey), findsOneWidget);
      expect(find.text('Уведомления обновлены в 10:00'), findsOneWidget);
      final int before = stand.callsOf('list').length;
      await tester.tap(find.descendant(of: find.byKey(NotificationsView.staleKey), matching: find.byType(AppButton)));
      await tester.pumpAndSettle();
      expect(stand.callsOf('list').length, before + 1, reason: '«Обновить» — новый запрос');
    });

    testWidgets('AC-UI-44-013: system customer_link (приходит только admin — фильтр сервера) → карточка клиента', (
      WidgetTester tester,
    ) async {
      final NotifStand stand = NotifStand();
      stand.serverItems = <AppNotification>[
        AppNotification(
          id: 'n12',
          rawKind: 'system',
          title: 'Конфликт привязки клиента',
          target: NotificationTarget.customerLink,
          createdAt: DateTime.utc(2026, 10, 22, 3, 55),
          severity: NotificationSeverity.warning,
          payload: const <String, Object?>{'target': 'customer_link', 'customerId': 'cust-5'},
        ),
      ];
      await _pump(tester, stand);
      await tester.tap(find.byKey(NotificationTile.keyOf('n12')));
      await tester.pumpAndSettle();
      expect(find.text('customer:cust-5'), findsOneWidget);
    });

    testWidgets('FQ-NOTIF-07: system с payload.target = cart_parked → SCR-23 «Отложенные заказы»', (
      WidgetTester tester,
    ) async {
      final NotifStand stand = NotifStand();
      stand.serverItems = <AppNotification>[
        AppNotification(
          id: 'n13',
          rawKind: 'system',
          title: 'Отложенный заказ скоро удалится',
          createdAt: DateTime.utc(2026, 10, 22, 3, 56),
          severity: NotificationSeverity.info,
          payload: const <String, Object?>{'target': 'cart_parked', 'cartId': 'pc-1'},
        ),
      ];
      await _pump(tester, stand);
      await tester.tap(find.byKey(NotificationTile.keyOf('n13')));
      await tester.pumpAndSettle();
      expect(find.text('parked'), findsOneWidget);
    });

    testWidgets('RS-1: цвет payment_status — по severity, а не по payload.status (статус платежа сервер не передаёт)', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(400, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      AppNotification payment(NotificationSeverity severity, Map<String, Object?> payload) => AppNotification(
        id: 'p-${severity.value}',
        rawKind: 'payment_status',
        title: 'Оплата',
        createdAt: DateTime.utc(2026, 10, 22, 3),
        severity: severity,
        payload: payload,
      );
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (BuildContext c) {
              ctx = c;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      final DsColors c = DsTheme.colorsOf(ctx);
      Color colorOf(AppNotification n) => NotificationKindStyle.of(ctx, n).color;
      // «Оплата по QR получена»: severity=info, payload без `status` (08 §3.13).
      expect(colorOf(payment(NotificationSeverity.info, const <String, Object?>{'paymentId': 'p1'})), c.success);
      expect(colorOf(payment(NotificationSeverity.warning, const <String, Object?>{'paymentId': 'p1'})), c.warning);
      expect(colorOf(payment(NotificationSeverity.error, const <String, Object?>{'paymentId': 'p1'})), c.error);
      // `status` у payment_status — статус заказа при `task: refund_or_advance`; на цвет не влияет.
      expect(
        colorOf(
          payment(NotificationSeverity.warning, const <String, Object?>{
            'paymentId': 'p1',
            'status': 'cancelled',
            'task': 'refund_or_advance',
          }),
        ),
        c.warning,
      );
    });
  });
}
