// Общая поддержка тестов SCR-44 (RM-F-008): фикстуры уведомлений, фейк очереди отметок, переопределения провайдеров.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/notifications/domain/entities/app_notification.dart';
import 'package:optomstroy/features/notifications/domain/repositories/notification_read_queue.dart';
import 'package:optomstroy/features/notifications/notifications_providers.dart';
import 'package:optomstroy/features/notifications/presentation/notifiers/notifications_center_controller.dart';

import '../../support/f_fakes.dart';

/// «Сейчас»: 22.10.2026 10:00 Asia/Bishkek.
final DateTime nowUtc = DateTime.utc(2026, 10, 22, 4);

/// Фикстуры: 3 непрочитанных (sync_error, order_status, cart_price_changed), 2 прочитанных (system, payment_status).
List<AppNotification> sampleNotifications() => <AppNotification>[
  AppNotification(
    id: 'n1',
    rawKind: 'sync_error',
    title: 'Ошибка обмена: Остатки',
    body: 'Повторная попытка через 5 минут',
    createdAt: DateTime.utc(2026, 10, 22, 3, 41),
    severity: NotificationSeverity.error,
    payload: const <String, Object?>{'entity': 'stock', 'runId': 'r1'},
  ),
  AppNotification(
    id: 'n2',
    rawKind: 'order_status',
    title: 'Заказ POS-2026-000123 согласован',
    body: 'Можно принимать оплату',
    orderId: 'o1',
    createdAt: DateTime.utc(2026, 10, 22, 3, 10),
    severity: NotificationSeverity.info,
    payload: const <String, Object?>{'orderId': 'o1', 'status': 'approved'},
  ),
  AppNotification(
    id: 'n3',
    rawKind: 'cart_price_changed',
    title: 'Цены в корзине изменились',
    body: '2 позиции подорожали',
    createdAt: DateTime.utc(2026, 10, 22, 2),
    severity: NotificationSeverity.warning,
    payload: const <String, Object?>{'cartId': 'c1'},
  ),
  AppNotification(
    id: 'n4',
    rawKind: 'system',
    title: 'Вход с нового устройства',
    body: 'Windows · Касса 2',
    target: NotificationTarget.sessions,
    createdAt: DateTime.utc(2026, 10, 21, 12, 5),
    readAt: DateTime.utc(2026, 10, 21, 13),
    severity: NotificationSeverity.info,
    payload: const <String, Object?>{'target': 'sessions'},
  ),
  AppNotification(
    id: 'n5',
    rawKind: 'payment_status',
    title: 'Оплата получена',
    orderId: 'o2',
    createdAt: DateTime.utc(2026, 10, 18, 8, 30),
    readAt: DateTime.utc(2026, 10, 18, 9),
    severity: NotificationSeverity.info,
    payload: const <String, Object?>{'orderId': 'o2', 'paymentId': 'p2'},
  ),
];

/// Фейк очереди офлайн-отметок.
final class FakeReadQueue implements NotificationReadQueue {
  final List<String> reads = <String>[];
  int readAll = 0;

  /// `before` последней записи «Прочитать все».
  DateTime? lastReadAllBefore;

  @override
  Future<bool> enqueueRead(String notificationId) async {
    reads.add(notificationId);
    return true;
  }

  @override
  Future<bool> enqueueReadAll({DateTime? before}) async {
    readAll++;
    lastReadAllBefore = before;
    return true;
  }
}

/// Стенд: фейк репозитория (онлайн-ответы по умолчанию — из [sampleNotifications]), очередь, сеть, часы.
final class NotifStand {
  NotifStand({OnlineStatus online = OnlineStatus.online}) {
    status.add(online);
    _current = online;
    repo.onList = (NotificationsQuery q) async {
      final List<AppNotification> items = <AppNotification>[
        for (final AppNotification n in serverItems)
          if ((!q.unreadOnly || !n.isRead) && (q.kinds.isEmpty || q.kinds.contains(n.kind)))
            if (q.since == null || n.createdAt.isAfter(q.since!)) n,
      ];
      return Success<NotificationsPage>(NotificationsPage(items: items, unreadCount: serverUnread));
    };
    repo.onMarkRead = (String id) async {
      serverUnread = serverUnread > 0 ? serverUnread - 1 : 0;
      return Success<int>(serverUnread);
    };
    repo.onMarkAllRead = () async {
      serverUnread = 0;
      return const Success<int>(0);
    };
  }

  final FakeNotificationsRepository repo = FakeNotificationsRepository();
  final FakeReadQueue queue = FakeReadQueue();
  final StreamController<OnlineStatus> status = StreamController<OnlineStatus>.broadcast();
  final FixedClock clock = FixedClock(nowUtc);
  List<AppNotification> serverItems = sampleNotifications();
  int serverUnread = 3;

  /// Период опроса (`null` — без таймера; AC-UI-44-006 — 60 с).
  Duration? pollInterval;
  late OnlineStatus _current;

  void setOnline(OnlineStatus s) {
    _current = s;
    status.add(s);
  }

  List<Override> get overrides => <Override>[
    notificationsRepositoryProvider.overrideWithValue(repo),
    notificationReadQueueProvider.overrideWithValue(queue),
    onlineStatusProvider.overrideWith((Ref ref) async* {
      yield _current;
      yield* status.stream;
    }),
    clockProvider.overrideWithValue(clock),
    notificationsPollIntervalProvider.overrideWithValue(pollInterval),
    outboxOwnerProvider.overrideWithValue('u1'),
  ];

  Iterable<FakeCall> callsOf(String method) => repo.calls.where((FakeCall c) => c.method == method);
}
