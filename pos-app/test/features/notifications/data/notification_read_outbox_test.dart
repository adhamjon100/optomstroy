// Офлайн-отметки «прочитано» (02 SCR-44.4; ядро §19.4; 07 §11.2): локально `notifications_cache.read_at` + запись
// `outbox_actions` типа `notification.read`; отправка при восстановлении сети с `Idempotency-Key` записи, в том числе
// после перезапуска (новый экземпляр очереди над той же БД).
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/notifications_cache_dao.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/sync/outbox_queue.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/notifications/data/offline/notification_read_outbox.dart';

import '../../../support/f_fakes.dart';

void main() {
  late AppDatabase db;
  final FixedClock clock = FixedClock(DateTime.utc(2026, 10, 22, 4));
  var keySeq = 0;

  OutboxQueue queueWith(FakeNotificationsRepository repo) => OutboxQueue(
    database: () => db,
    owner: () => 'u1',
    clock: clock,
    newKey: () => 'key-${++keySeq}',
    handlers: <OutboxActionHandler>[NotificationReadOutboxHandler(() => repo)],
  );

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    keySeq = 0;
    await NotificationsCacheDao(db).upsertFromServer(<NotificationCacheEntry>[
      for (final String id in <String>['n1', 'n2', 'n3'])
        NotificationCacheEntry(
          id: id,
          kind: 'order_status',
          severity: 'info',
          title: 't-$id',
          createdAtMs: DateTime.utc(2026, 10, 22, 3).millisecondsSinceEpoch,
        ),
    ]);
  });
  tearDown(() => db.close());

  Future<List<OutboxActionRow>> rows() => db.select(db.outboxActions).get();

  test('отметка офлайн: read_at в кэше, запись outbox {id}; повтор не дублирует', () async {
    final FakeNotificationsRepository repo = FakeNotificationsRepository();
    var enqueued = 0;
    final OutboxNotificationReadQueue q = OutboxNotificationReadQueue(
      database: () => db,
      outbox: queueWith(repo),
      clock: clock,
      onEnqueued: () => enqueued++,
    );
    expect(await q.enqueueRead('n2'), isTrue);
    expect(await q.enqueueRead('n2'), isTrue);
    expect(await NotificationsCacheDao(db).watchUnreadCount().first, 2);
    final List<OutboxActionRow> r = await rows();
    expect(r, hasLength(1));
    expect(r.single.type, OutboxTypes.notificationRead);
    expect(r.single.payloadJson, '{"id":"n2"}');
    expect(r.single.ownerUserId, 'u1');
    expect(enqueued, 2);
  });

  test('«Прочитать все» офлайн: все прочитаны, запись {readAll: true, before: момент действия} (08 §4.16.2)', () async {
    final OutboxNotificationReadQueue q = OutboxNotificationReadQueue(
      database: () => db,
      outbox: queueWith(FakeNotificationsRepository()),
      clock: clock,
    );
    expect(await q.enqueueReadAll(), isTrue);
    expect(await NotificationsCacheDao(db).watchUnreadCount().first, 0);
    expect((await rows()).single.payloadJson, '{"before":"2026-10-22T04:00:00.000Z","readAll":true}');
  });

  test('«Прочитать все» до момента: пришедшее позже уведомление остаётся непрочитанным', () async {
    await NotificationsCacheDao(db).upsertFromServer(<NotificationCacheEntry>[
      NotificationCacheEntry(
        id: 'late',
        kind: 'order_status',
        severity: 'info',
        title: 't',
        createdAtMs: DateTime.utc(2026, 10, 22, 5).millisecondsSinceEpoch,
      ),
    ]);
    final OutboxNotificationReadQueue q = OutboxNotificationReadQueue(
      database: () => db,
      outbox: queueWith(FakeNotificationsRepository()),
      clock: clock,
    );
    expect(await q.enqueueReadAll(), isTrue);
    expect(await NotificationsCacheDao(db).watchUnreadCount().first, 1, reason: 'late создано после действия');
  });

  test('БД не открыта — false, очередь не трогается', () async {
    final OutboxNotificationReadQueue q = OutboxNotificationReadQueue(
      database: () => null,
      outbox: queueWith(FakeNotificationsRepository()),
      clock: clock,
    );
    expect(await q.enqueueRead('n1'), isFalse);
    expect(await rows(), isEmpty);
  });

  test('после «перезапуска» записи отправляются с ключом записи; ответы сервера → done/deferred/dead', () async {
    final FakeNotificationsRepository offline = FakeNotificationsRepository()
      ..onMarkRead = (String id) async => const FailureResult<int>(NetworkFailure(NetworkFailureKind.offline));
    final OutboxNotificationReadQueue q = OutboxNotificationReadQueue(
      database: () => db,
      outbox: queueWith(offline),
      clock: clock,
    );
    await q.enqueueRead('n1');
    await q.enqueueReadAll();
    // Нет сети — проход остановлен, попытка не считается.
    final OutboxFlushReport r1 = await queueWith(offline).flush();
    expect(r1.deferred, isTrue);
    expect((await rows()).first.attempts, 0);

    // Новый экземпляр очереди (перезапуск) — сеть есть.
    final FakeNotificationsRepository online = FakeNotificationsRepository()
      ..onMarkRead = ((String id) async => const Success<int>(0))
      ..onMarkAllRead = (() async => const Success<int>(0));
    final OutboxFlushReport r2 = await queueWith(online).flush();
    expect(r2.sent, 2);
    expect(online.calls.map((FakeCall c) => c.method), <String>['markRead', 'markAllRead']);
    expect(online.calls.first.args, <Object?>['n1', 'key-1']);
    expect(online.calls.last.args, <Object?>['key-2']);
    expect(online.lastMarkAllReadBefore, clock.nowUtc(), reason: 'before из записи очереди → ?before=');
    expect((await rows()).map((OutboxActionRow r) => r.status), everyElement('done'));
  });

  test('обработчик: 404 — done (уведомление удалено), 5xx — failed, повреждённая запись — dead', () async {
    final FakeNotificationsRepository repo = FakeNotificationsRepository();
    final NotificationReadOutboxHandler h = NotificationReadOutboxHandler(() => repo);
    OutboxAction action(Map<String, Object?> p) => OutboxAction(
      id: 1,
      type: OutboxTypes.notificationRead,
      payload: p,
      idempotencyKey: 'k',
      attempts: 1,
      createdAt: clock.nowUtc(),
    );
    repo.onMarkRead = (String id) async => const FailureResult<int>(ServerFailure(code: 'NOT_FOUND', status: 404));
    expect(await h.handle(action(<String, Object?>{'id': 'gone'})), OutboxOutcome.done);
    repo.onMarkRead = (String id) async => const FailureResult<int>(ServerFailure(code: 'INTERNAL', status: 500));
    expect(await h.handle(action(<String, Object?>{'id': 'n1'})), OutboxOutcome.failed);
    expect(await h.handle(action(<String, Object?>{'foo': 1})), OutboxOutcome.dead);
    expect(NotificationReadPayload.tryParse(const <String, Object?>{'readAll': true})?.readAll, isTrue);
    expect(NotificationReadPayload.tryParse(const <String, Object?>{'readAll': true})?.before, isNull);
    expect(
      NotificationReadPayload.tryParse(const <String, Object?>{'readAll': true, 'before': 'x'})?.before,
      isNull,
      reason: 'неразбираемый before — как запись без него',
    );
  });
}
