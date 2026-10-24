// `notifications_cache` — последние 100 уведомлений (07 §11.2; DATA-258; D-41, RM-F-008). Серверная истина;
// отметка «прочитано» офлайн — `read_at` локально + запись очереди `notification.read`. Для видов с финансовыми
// данными или ПДн клиентов (`credit_blocked`, `payment_status`, `return_status`) `body` не кэшируется (NULL), из
// `payload_json` сохраняются только идентификаторы (`target`, `orderId`, `paymentId`) — правило проверяется здесь,
// до записи, независимо от вызывающего.
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:optomstroy/core/database/app_database.dart';

/// Уведомление для кэша (ядро не знает сущностей фич — FL-04).
final class NotificationCacheEntry {
  const NotificationCacheEntry({
    required this.id,
    required this.kind,
    required this.severity,
    required this.title,
    required this.createdAtMs,
    this.body,
    this.payload = const <String, Object?>{},
    this.readAtMs,
  });

  final String id;

  /// Значение `notification_kind`.
  final String kind;

  /// `info|warning|error`.
  final String severity;
  final String title;
  final String? body;
  final Map<String, Object?> payload;
  final int createdAtMs;
  final int? readAtMs;
}

/// Доступ к `notifications_cache` БД текущего пользователя.
final class NotificationsCacheDao {
  NotificationsCacheDao(this._db);

  final AppDatabase _db;

  /// Предел кэша (07 §11.2).
  static const int limit = 100;

  /// Виды, у которых `body` не кэшируется (DATA-258).
  static const Set<String> sensitiveKinds = <String>{'credit_blocked', 'payment_status', 'return_status'};

  /// Ключи `payload`, которые сохраняются для чувствительных видов (только идентификаторы).
  static const Set<String> identifierKeys = <String>{'target', 'orderId', 'paymentId'};

  /// Вставить/обновить уведомления из ответа сервера и обрезать кэш до [limit] самых новых.
  /// Локальная отметка прочтения (`read_at`), ещё не подтверждённая сервером, не теряется.
  Future<void> upsertFromServer(List<NotificationCacheEntry> entries) => _db.transaction(() async {
    for (final NotificationCacheEntry e in entries) {
      final NotificationCacheRow? existing = await (_db.select(
        _db.notificationsCache,
      )..where((t) => t.id.equals(e.id))).getSingleOrNull();
      final bool sensitive = sensitiveKinds.contains(e.kind);
      final Map<String, Object?> payload = sensitive
          ? <String, Object?>{
              for (final MapEntry<String, Object?> p in e.payload.entries)
                if (identifierKeys.contains(p.key)) p.key: p.value,
            }
          : e.payload;
      await _db
          .into(_db.notificationsCache)
          .insertOnConflictUpdate(
            NotificationsCacheCompanion.insert(
              id: e.id,
              kind: e.kind,
              severity: e.severity,
              title: e.title,
              body: Value(sensitive ? null : e.body),
              payloadJson: Value(payload.isEmpty ? null : jsonEncode(payload)),
              createdAt: e.createdAtMs,
              readAt: Value(e.readAtMs ?? existing?.readAt),
            ),
          );
    }
    await _trim();
  });

  Future<void> _trim() async {
    final List<NotificationCacheRow> keep =
        await (_db.select(_db.notificationsCache)
              ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
              ..limit(limit))
            .get();
    final Set<String> ids = <String>{for (final NotificationCacheRow r in keep) r.id};
    await (_db.delete(_db.notificationsCache)..where((t) => t.id.isNotIn(ids))).go();
  }

  /// Уведомления по убыванию `created_at` (только непрочитанные при [unreadOnly]).
  Stream<List<NotificationCacheRow>> watchLatest({bool unreadOnly = false}) {
    final SimpleSelectStatement<$NotificationsCacheTable, NotificationCacheRow> q = _db.select(_db.notificationsCache)
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
      ..limit(limit);
    if (unreadOnly) q.where((t) => t.readAt.isNull());
    return q.watch();
  }

  /// Число непрочитанных в кэше (офлайн-бейдж; онлайн — `unreadCount` ответа сервера).
  Stream<int> watchUnreadCount() {
    final Expression<int> count = _db.notificationsCache.id.count();
    final JoinedSelectStatement<$NotificationsCacheTable, NotificationCacheRow> q =
        _db.selectOnly(_db.notificationsCache)
          ..addColumns([count])
          ..where(_db.notificationsCache.readAt.isNull());
    return q.watchSingle().map((TypedResult r) => r.read(count) ?? 0);
  }

  /// Отметить прочитанным локально (офлайн — вместе с записью очереди `notification.read`).
  Future<void> markRead(String id, {required int nowMs}) => (_db.update(
    _db.notificationsCache,
  )..where((t) => t.id.equals(id) & t.readAt.isNull())).write(NotificationsCacheCompanion(readAt: Value(nowMs)));

  /// Отметить все прочитанными локально.
  /// [beforeMs] — только созданные не позже этого момента (`POST /notifications/read-all?before=`, 08 §4.16.2).
  Future<void> markAllRead({required int nowMs, int? beforeMs}) =>
      (_db.update(_db.notificationsCache)..where(
            (t) =>
                beforeMs == null ? t.readAt.isNull() : t.readAt.isNull() & t.createdAt.isSmallerOrEqualValue(beforeMs),
          ))
          .write(NotificationsCacheCompanion(readAt: Value(nowMs)));

  /// Очистить кэш (выход/смена пользователя — 07 §11.4).
  Future<void> clear() => _db.delete(_db.notificationsCache).go();
}
