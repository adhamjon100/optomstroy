// `NotificationsRepository`: сеть (08 §4.16) + кэш `notifications_cache` (07 §11.2). Успешный `GET /notifications`
// обновляет кэш (≤ 100; DATA-258 — без `body` у чувствительных видов, правило в DAO); «прочитано» онлайн —
// `POST /notifications/{id}/read` и локальная отметка; офлайн-путь (outbox `notification.read`) добавляет агент
// F-fe-notif поверх этого порта. БД закрыта — кэш пуст, сетевые методы работают.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/notifications_cache_dao.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/notifications/data/dto/notification_dtos.dart';
import 'package:optomstroy/features/notifications/domain/entities/app_notification.dart';
import 'package:optomstroy/features/notifications/domain/repositories/notifications_repository.dart';

/// Пути API уведомлений (08 §4.16).
abstract final class NotificationsApiPaths {
  static const String list = '/notifications';
  static const String readAll = '/notifications/read-all';
  static String read(String id) => '/notifications/${Uri.encodeComponent(id)}/read';
}

final class NotificationsRepositoryImpl implements NotificationsRepository {
  NotificationsRepositoryImpl(this._dio, {required AppDatabase? Function() database, required Clock clock})
    : _database = database,
      _clock = clock;

  final Dio _dio;
  final AppDatabase? Function() _database;
  final Clock _clock;

  NotificationsCacheDao? get _cache {
    final AppDatabase? db = _database();
    return db == null ? null : NotificationsCacheDao(db);
  }

  Future<void> _quietly(Future<void> Function(NotificationsCacheDao dao) write) async {
    final NotificationsCacheDao? dao = _cache;
    if (dao == null) return;
    try {
      await write(dao);
    } on Object {
      // Кэш — вспомогательный: ошибка записи не ломает ответ сервера (БД могла закрыться при смене пользователя).
    }
  }

  @override
  Future<Result<NotificationsPage>> list(NotificationsQuery query) async {
    final Result<NotificationsPage> r = await ErrorMapper.guard(() async {
      final Response<Object?> resp = await _dio.get<Object?>(
        NotificationsApiPaths.list,
        queryParameters: <String, Object?>{
          if (query.unreadOnly) 'unread': true,
          if (query.kinds.isNotEmpty) 'kind': query.kinds.map((NotificationKind k) => k.value).join(','),
          if (query.since != null) 'since': query.since!.toUtc().toIso8601String(),
          'limit': query.limit.clamp(1, 100),
          'cursor': ?query.cursor,
        },
        options: apiOptions(retry: RetryProfile.background),
      );
      return NotificationsPageDto.fromJson(jsonObject(resp.data));
    });
    if (r case Success<NotificationsPage>(:final NotificationsPage value)) {
      await _quietly(
        (NotificationsCacheDao dao) => dao.upsertFromServer(<NotificationCacheEntry>[
          for (final AppNotification n in value.items) NotificationDto.toCache(n),
        ]),
      );
    }
    return r;
  }

  @override
  Future<Result<int>> markRead(String notificationId, {String? idempotencyKey}) async {
    final Result<int> r = await ErrorMapper.guard(() async {
      final Response<Object?> resp = await _dio.post<Object?>(
        NotificationsApiPaths.read(notificationId),
        options: apiOptions(idempotencyKey: idempotencyKey),
      );
      return UnreadCountDto.fromJson(jsonObject(resp.data));
    });
    if (r.isSuccess) {
      await _quietly(
        (NotificationsCacheDao dao) => dao.markRead(notificationId, nowMs: _clock.nowUtc().millisecondsSinceEpoch),
      );
    }
    return r;
  }

  @override
  Future<Result<int>> markAllRead({String? idempotencyKey, DateTime? before}) async {
    final Result<int> r = await ErrorMapper.guard(() async {
      final Response<Object?> resp = await _dio.post<Object?>(
        NotificationsApiPaths.readAll,
        queryParameters: before == null ? null : <String, Object?>{'before': before.toUtc().toIso8601String()},
        options: apiOptions(idempotencyKey: idempotencyKey),
      );
      return UnreadCountDto.fromJson(jsonObject(resp.data));
    });
    if (r.isSuccess) {
      await _quietly(
        (NotificationsCacheDao dao) => dao.markAllRead(
          nowMs: _clock.nowUtc().millisecondsSinceEpoch,
          beforeMs: before?.toUtc().millisecondsSinceEpoch,
        ),
      );
    }
    return r;
  }

  @override
  Stream<List<AppNotification>> watchCached({bool unreadOnly = false}) {
    final NotificationsCacheDao? dao = _cache;
    if (dao == null) return Stream<List<AppNotification>>.value(const <AppNotification>[]);
    return dao
        .watchLatest(unreadOnly: unreadOnly)
        .map(
          (List<NotificationCacheRow> rows) => <AppNotification>[
            for (final NotificationCacheRow r in rows) NotificationDto.fromCache(r),
          ],
        );
  }

  @override
  Stream<int> watchCachedUnreadCount() => _cache?.watchUnreadCount() ?? Stream<int>.value(0);
}
