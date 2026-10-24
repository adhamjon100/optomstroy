// Офлайн-путь отметок «прочитано» (02 SCR-44.4; ядро §19.4; 07 §11.2, тип `notification.read`):
// - [OutboxNotificationReadQueue] — `notifications_cache.read_at` локально + запись `outbox_actions`;
// - [NotificationReadOutboxHandler] — отправка записи (`POST /notifications/{id}/read` или `/read-all`) с
//   `Idempotency-Key` записи; обработчик подключается в реестр `outboxHandlersProvider` (core/sync) корнем.
// Полезная нагрузка — [NotificationReadPayload]: `{id}` или `{readAll: true, before}` (без ПДн и текстов; `before` —
// момент действия пользователя, `POST /notifications/read-all?before=`, OpenAPI 1.2.0, 08 §4.16.2).
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/notifications_cache_dao.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/sync/outbox_queue.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/notifications/domain/repositories/notification_read_queue.dart';
import 'package:optomstroy/features/notifications/domain/repositories/notifications_repository.dart';

/// Полезная нагрузка `notification.read` (07 §11.2; 02 SCR-44.4: «payload — `id` или флаг `readAll`»).
final class NotificationReadPayload {
  const NotificationReadPayload.one(String this.id) : readAll = false, before = null;

  const NotificationReadPayload.all({this.before}) : id = null, readAll = true;

  /// Уведомление (`readAll == false`).
  final String? id;

  /// «Прочитать все».
  final bool readAll;

  /// «Прочитать все» — только созданные не позже этого момента (UTC); `null` — запись прежнего формата (все).
  final DateTime? before;

  Map<String, Object?> toJson() => readAll
      ? <String, Object?>{'readAll': true, if (before != null) 'before': before!.toUtc().toIso8601String()}
      : <String, Object?>{'id': id};

  /// Разбор записи очереди; `null` — запись повреждена. Неразбираемый `before` — как запись без него.
  static NotificationReadPayload? tryParse(Map<String, Object?> json) {
    if (json['readAll'] == true) {
      final Object? before = json['before'];
      return NotificationReadPayload.all(before: before is String ? DateTime.tryParse(before)?.toUtc() : null);
    }
    final Object? id = json['id'];
    if (id is String && id.isNotEmpty) return NotificationReadPayload.one(id);
    return null;
  }
}

/// Локальная отметка + запись очереди `notification.read`.
final class OutboxNotificationReadQueue implements NotificationReadQueue {
  OutboxNotificationReadQueue({
    required AppDatabase? Function() database,
    required OutboxQueue outbox,
    required Clock clock,
    void Function()? onEnqueued,
  }) : _database = database,
       _outbox = outbox,
       _clock = clock,
       _onEnqueued = onEnqueued;

  final AppDatabase? Function() _database;
  final OutboxQueue _outbox;
  final Clock _clock;
  final void Function()? _onEnqueued;

  @override
  Future<bool> enqueueRead(String notificationId) => _enqueue(NotificationReadPayload.one(notificationId));

  @override
  Future<bool> enqueueReadAll({DateTime? before}) =>
      _enqueue(NotificationReadPayload.all(before: (before ?? _clock.nowUtc()).toUtc()));

  Future<bool> _enqueue(NotificationReadPayload payload) async {
    final AppDatabase? db = _database();
    if (db == null) return false;
    final NotificationsCacheDao dao = NotificationsCacheDao(db);
    final int nowMs = _clock.nowUtc().millisecondsSinceEpoch;
    try {
      if (payload.readAll) {
        await dao.markAllRead(nowMs: nowMs, beforeMs: payload.before?.millisecondsSinceEpoch);
      } else {
        await dao.markRead(payload.id!, nowMs: nowMs);
      }
      // Повтор той же отметки не плодит записей (coalesce); «прочитать все» делает отдельные отметки лишними.
      final String? key = await _outbox.enqueue(
        OutboxTypes.notificationRead,
        payload.toJson(),
        coalesce: !payload.readAll,
      );
      if (key == null) return false;
    } on Object {
      // БД закрылась при смене пользователя — отметка остаётся в памяти экрана.
      return false;
    }
    _onEnqueued?.call();
    return true;
  }
}

/// Обработчик записей `notification.read` (реестр `OutboxActionHandler`, 06 §6.12).
final class NotificationReadOutboxHandler implements OutboxActionHandler {
  NotificationReadOutboxHandler(this._repository);

  final NotificationsRepository Function() _repository;

  @override
  Set<String> get types => const <String>{OutboxTypes.notificationRead};

  @override
  Future<OutboxOutcome> handle(OutboxAction action) async {
    final NotificationReadPayload? payload = NotificationReadPayload.tryParse(action.payload);
    if (payload == null) return OutboxOutcome.dead;
    final NotificationsRepository repo = _repository();
    final Result<int> r = payload.readAll
        ? await repo.markAllRead(idempotencyKey: action.idempotencyKey, before: payload.before)
        : await repo.markRead(payload.id!, idempotencyKey: action.idempotencyKey);
    return switch (r) {
      Success<int>() => OutboxOutcome.done,
      // Уведомление удалено по сроку хранения (07: 30/90 дней) — отмечать нечего, запись выполнена.
      FailureResult<int>(failure: ServerFailure(status: 404)) => OutboxOutcome.done,
      FailureResult<int>(:final Failure failure) => outboxOutcomeOf(failure),
    };
  }
}
