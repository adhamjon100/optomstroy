// Порт центра уведомлений (08 §4.16; D-41, RM-F-008). Офлайн: список — из кэша `notifications_cache` (≤ 100),
// «прочитано» — локально + outbox `notification.read` (07 §11.2). Чистый Dart (FL-01).
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/notifications/domain/entities/app_notification.dart';

abstract interface class NotificationsRepository {
  /// Список (`GET /notifications`); успешный ответ обновляет локальный кэш.
  Future<Result<NotificationsPage>> list(NotificationsQuery query);

  /// Отметить прочитанным (`POST /notifications/{id}/read`) → текущее число непрочитанных.
  Future<Result<int>> markRead(String notificationId, {String? idempotencyKey});

  /// Отметить все прочитанными (`POST /notifications/read-all`, идемпотентно) → число непрочитанных.
  /// [before] — только созданные не позже этого момента (`?before=`, OpenAPI 1.2.0, 08 §4.16.2): «до момента»
  /// офлайн-действия пользователя. Сервер этапа F параметр игнорирует (отмечает все).
  Future<Result<int>> markAllRead({String? idempotencyKey, DateTime? before});

  /// Кэш уведомлений (офлайн и до первого ответа), по убыванию времени.
  Stream<List<AppNotification>> watchCached({bool unreadOnly = false});

  /// Число непрочитанных в кэше (офлайн-бейдж).
  Stream<int> watchCachedUnreadCount();
}
