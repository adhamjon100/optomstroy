// Очередь `outbox_actions` (D-32; 07 §11.2; DATA-254, DATA-255; T-FAV-004, T-FAV-008; RM-E-009 критерий 2):
// избранное и «очистить недавние» офлайн → после восстановления сети уходят ровно один раз с
// `Idempotency-Key` записи; повторный проход не дублирует; временные ошибки — повтор с задержкой, постоянные — dead.
// Фейковый транспорт Dio, drift в памяти; синтетические данные.
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/sync/offline_actions.dart';
import 'package:optomstroy/core/sync/outbox_handlers.dart';
import 'package:optomstroy/core/sync/outbox_queue.dart';
import 'package:optomstroy/core/utils/clock.dart';

import '../database/test_database.dart';
import '../network/fake_adapter.dart';

void main() {
  configureSqliteForTests();
  late AppDatabase db;
  late FakeAdapter adapter;
  late FixedClock clock;
  late OutboxQueue queue;
  late OfflineActions actions;
  late bool online;
  late ResponseBody Function(RequestOptions o) server;
  String? owner = 'user-1';
  var keySeq = 0;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    clock = FixedClock(DateTime.utc(2026, 10, 19, 10));
    online = false;
    owner = 'user-1';
    keySeq = 0;
    server = (o) => json(204, null);
    adapter = FakeAdapter((o) async {
      if (!online) transportError(o, DioExceptionType.connectionError);
      return server(o);
    });
    final dio = Dio(BaseOptions(baseUrl: 'https://pos.test/api/v1'))..httpClientAdapter = adapter;
    queue = OutboxQueue(
      database: () => db,
      owner: () => owner,
      clock: clock,
      newKey: () => 'key-${++keySeq}',
      handlers: [
        FavoriteOutboxHandler(dio: () => dio, database: () => db),
        RecentClearOutboxHandler(dio: () => dio),
      ],
    );
    actions = OfflineActions(database: () => db, outbox: queue, clock: clock);
  });
  tearDown(() => db.close());

  Future<List<OutboxActionRow>> rows() => db.select(db.outboxActions).get();
  List<String> sent() => [for (final r in adapter.requests) '${r.method} ${r.path}'];

  group('избранное офлайн → онлайн (T-FAV-008, RM-E-009 критерий 2)', () {
    test('«в избранное» без сети: локально сразу; после сети — ровно один PUT с Idempotency-Key записи', () async {
      expect((await actions.setFavorite('p-1', favorite: true)).isSuccess, isTrue);
      expect(await db.favoritesDao.favoriteProductIds(), {'p-1'}, reason: 'оптимистично, до сервера');

      final offlineReport = await queue.flush();
      expect(offlineReport.deferred, isTrue);
      expect((await rows()).single.status, 'pending');
      expect((await rows()).single.attempts, 0, reason: 'попытка без связи не считается');

      expect(adapter.requests, hasLength(1), reason: 'попытка без связи (соединение не установлено)');
      adapter.requests.clear();
      online = true;
      final report = await queue.flush();
      expect(report.sent, 1);
      final puts = adapter.requests.where((r) => r.method == 'PUT').toList();
      expect(puts, hasLength(1));
      expect(puts.single.path, '/favorites/products/p-1');
      expect(puts.single.headers['Idempotency-Key'], 'key-1');
      expect((await rows()).single.status, 'done');
      expect(await db.favoritesDao.pendingFavorites(), isEmpty, reason: 'pending_op снят');
      expect(await db.favoritesDao.favoriteProductIds(), {'p-1'});

      // Повторный проход и параллельные вызовы не отправляют действие ещё раз.
      await Future.wait([queue.flush(), queue.flush()]);
      expect(adapter.requests.where((r) => r.method == 'PUT'), hasLength(1));
    });

    test('параллельный flush — один проход (single-flight), один PUT', () async {
      online = true;
      final gate = Completer<void>();
      server = (o) => json(204, null);
      final slow = FakeAdapter((o) async {
        await gate.future;
        return json(204, null);
      });
      final dio = Dio(BaseOptions(baseUrl: 'https://pos.test/api/v1'))..httpClientAdapter = slow;
      final q = OutboxQueue(
        database: () => db,
        owner: () => owner,
        clock: clock,
        handlers: [FavoriteOutboxHandler(dio: () => dio, database: () => db)],
      );
      await OfflineActions(database: () => db, outbox: q, clock: clock).setFavorite('p-9', favorite: true);
      final a = q.flush();
      final b = q.flush();
      expect(identical(a, b), isTrue);
      gate.complete();
      await Future.wait([a, b]);
      expect(slow.requests, hasLength(1));
    });

    test('добавить и убрать до отправки: в очереди одна запись, на сервер — только DELETE', () async {
      await actions.setFavorite('p-2', favorite: true);
      await actions.setFavorite('p-2', favorite: false);
      expect(await rows(), hasLength(1));
      expect((await rows()).single.type, 'favorite.remove');
      expect(await db.favoritesDao.favoriteProductIds(), isEmpty);
      online = true;
      await queue.flush();
      expect(sent(), ['DELETE /favorites/products/p-2']);
      expect(await db.select(db.localFavoritesProducts).get(), isEmpty);
    });

    test('ответ на устаревшее действие не снимает новую отметку пользователя', () async {
      online = true;
      server = (o) => json(204, null);
      await actions.setFavorite('p-3', favorite: true);
      // Пока PUT «в пути», пользователь убрал товар: отметка стала remove.
      server = (o) {
        unawaited(db.favoritesDao.markFavoritePending('p-3', add: false, nowMs: 1));
        return json(204, null);
      };
      await queue.flush();
      await pumpEventQueue();
      final row = await (db.select(db.localFavoritesProducts)..where((t) => t.productId.equals('p-3'))).getSingle();
      expect(row.pendingOp, 'remove');
    });

    test('DELETE 404 — уже нет на сервере: выполнено; PUT 404 — dead и локальный откат', () async {
      online = true;
      server = (o) => json(404, problem('NOT_FOUND', 404));
      await actions.setFavorite('p-4', favorite: false);
      await actions.setFavorite('p-5', favorite: true);
      final report = await queue.flush();
      expect((report.sent, report.dead), (1, 1));
      final byType = {for (final r in await rows()) r.type: r.status};
      expect(byType, {'favorite.remove': 'done', 'favorite.add': 'dead'});
      expect(await db.favoritesDao.favoriteProductIds(), isEmpty, reason: 'добавление отменено');
    });

    test('5xx — failed с задержкой (backoff), после 10 ответов сервера (maxAttempts) — dead', () async {
      online = true;
      server = (o) => json(503, problem('INTERNAL', 503));
      await actions.setFavorite('p-6', favorite: true);
      await queue.flush();
      var row = (await rows()).single;
      expect((row.status, row.attempts), ('failed', 1));
      expect(row.nextAttemptAt, clock.nowUtc().add(OutboxQueue.backoff(1)).millisecondsSinceEpoch);
      // До срока повтора запись не отправляется.
      await queue.flush();
      expect(adapter.requests, hasLength(1));
      for (var i = 2; i <= OutboxQueue.maxAttempts; i++) {
        clock.advance(const Duration(hours: 1));
        await queue.flush();
      }
      row = (await rows()).single;
      expect((row.status, row.attempts), ('dead', OutboxQueue.maxAttempts));
      expect(OutboxQueue.maxAttempts, 10, reason: '07 §11.2: dead — после 10 ответов сервера с ошибкой');
      expect(OutboxQueue.backoff(1), const Duration(seconds: 5));
      expect(OutboxQueue.backoff(20), const Duration(minutes: 15));
    });

    test(
      'записи другого пользователя не отправляются (07 §11.1 п.2); без БД/пользователя — ошибка без записи',
      () async {
        await actions.setFavorite('p-7', favorite: true);
        owner = 'user-2';
        online = true;
        await queue.flush();
        expect(adapter.requests, isEmpty);
        owner = null;
        expect((await actions.setFavorite('p-8', favorite: true)).failureOrNull, isNotNull);
        expect(await rows(), hasLength(1));
      },
    );

    test('смена пользователя во время прохода: записи A не уходят с сессией B (DATA-253)', () async {
      online = true;
      final dbB = AppDatabase(NativeDatabase.memory());
      addTearDown(dbB.close);
      AppDatabase current = db;
      final sentBy = <String>[];
      server = (o) {
        sentBy.add('${o.path} owner=$owner');
        // После первой отправки вошёл другой пользователь: сессия и БД сменились.
        owner = 'user-2';
        current = dbB;
        return json(204, null);
      };
      final dio = Dio(BaseOptions(baseUrl: 'https://pos.test/api/v1'))..httpClientAdapter = adapter;
      final q = OutboxQueue(
        database: () => current,
        owner: () => owner,
        clock: clock,
        handlers: [FavoriteOutboxHandler(dio: () => dio, database: () => current)],
      );
      final a = OfflineActions(database: () => db, outbox: q, clock: clock);
      for (final id in <String>['p-1', 'p-2', 'p-3']) {
        await a.setFavorite(id, favorite: true);
      }

      final report = await q.flush();

      expect(sentBy, ['/favorites/products/p-1 owner=user-1']);
      expect((report.sent, report.interrupted), (1, true));
      final statuses = {
        for (final r in await rows()) (jsonDecode(r.payloadJson) as Map<String, Object?>)['productId']: r.status,
      };
      expect(statuses, {'p-1': 'done', 'p-2': 'pending', 'p-3': 'pending'});
      final aRow = await (db.select(db.localFavoritesProducts)..where((t) => t.productId.equals('p-1'))).getSingle();
      expect(aRow.pendingOp, isNull, reason: 'подтверждение записано в БД владельца A');
      expect(await dbB.select(dbB.localFavoritesProducts).get(), isEmpty, reason: 'в БД B ничего не попало');
    });

    test('сбой без ответа сервера (исключение обработчика) попыткой не считается и к dead не ведёт', () async {
      online = true;
      final q = OutboxQueue(database: () => db, owner: () => owner, clock: clock, handlers: [_ThrowingHandler()]);
      await q.enqueue('favorite.add', const {'productId': 'p-11'});
      for (var i = 0; i < OutboxQueue.maxAttempts + 2; i++) {
        clock.advance(const Duration(hours: 1));
        await q.flush();
      }
      final row = (await rows()).single;
      expect((row.status, row.attempts), ('failed', 0));
    });

    test('прерванная отправка (sending) после перезапуска повторяется тем же ключом', () async {
      await actions.setFavorite('p-10', favorite: true);
      await db.update(db.outboxActions).write(const OutboxActionsCompanion(status: Value('sending')));
      online = true;
      await queue.flush();
      expect(adapter.requests.single.headers['Idempotency-Key'], 'key-1');
      expect((await rows()).single.status, 'done');
    });
  });

  group('недавние: «Очистить» офлайн (T-FAV-004, DATA-254)', () {
    test('локально сразу; recent.clear один раз после сети; повторная очистка не дублирует запись', () async {
      await db.favoritesDao.touchRecent('p-1', nowMs: 1);
      await db.favoritesDao.touchRecent('p-2', nowMs: 2);
      await actions.clearRecent();
      await actions.clearRecent();
      expect(await db.favoritesDao.recentProducts(), isEmpty);
      expect(await rows(), hasLength(1));
      expect((await rows()).single.type, 'recent.clear');
      await queue.flush();
      expect(adapter.requests, hasLength(1), reason: 'попытка без сети');
      online = true;
      adapter.requests.clear();
      await queue.flush();
      await queue.flush();
      expect(sent(), ['DELETE /catalog/products/recent']);
      expect(await queue.pendingCount(), 0);
    });
  });

  test('тип вне CHECK outbox_actions.type не ставится (заказы и платежи — только онлайн, DATA-254)', () async {
    expect(() => queue.enqueue('order.create', const {}), throwsArgumentError);
  });
}

/// Обработчик, который падает до ответа сервера (ошибка разбора, сбой клиента).
final class _ThrowingHandler implements OutboxActionHandler {
  @override
  Set<String> get types => const {OutboxTypes.favoriteAdd};

  @override
  Future<OutboxOutcome> handle(OutboxAction action) async => throw StateError('без ответа сервера');
}
