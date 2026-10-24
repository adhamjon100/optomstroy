// Публичный контракт фичи notifications (06 §6.1 L-3 (2), §6.14; FL-07).
//
// Этап F (основа): порт центра уведомлений (SCR-44, `NotificationBell`, баннеры; RM-F-008). Реализацию подключает
// `app/di/overrides.dart` списком `notificationsBindings` (data/notifications_bindings.dart, L-8).
// В widget-тестах — `notificationsRepositoryProvider.overrideWithValue(fake)`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/features/notifications/domain/repositories/notification_read_queue.dart';
import 'package:optomstroy/features/notifications/domain/repositories/notifications_repository.dart';

/// Уведомления: сеть + кэш `notifications_cache`.
final notificationsRepositoryProvider = Provider<NotificationsRepository>(
  (ref) => throw UnimplementedError(
    'notificationsRepositoryProvider: подключите notificationsBindings в app/di/overrides.dart',
  ),
);

/// Офлайн-отметки «прочитано» (кэш + outbox `notification.read`, ядро §19.4; RM-F-008). `null` — без локальной
/// БД/очереди: экран держит отметку в памяти до следующего успешного запроса.
final notificationReadQueueProvider = Provider<NotificationReadQueue?>((ref) => null);
