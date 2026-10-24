// Клиентская очередь некритичных идемпотентных действий `outbox_actions` (D-32; 07 §11.2, DATA-254, DATA-255;
// 06 §6.12: `OutboxQueue.flush()` + реестр `OutboxActionHandler`).
//
// - Запись несёт `idempotency_key` (UUID v4) — он уходит в `Idempotency-Key`; повтор после восстановления сети
//   не создаёт дублей на сервере.
// - Отправка — по порядку `id`, только записи текущего пользователя (`owner_user_id`, 07 §11.1 п.2); владелец и
//   БД сверяются перед каждой записью: если сессия сменилась во время прохода, проход останавливается, а
//   оставшиеся записи ждут сессии своего владельца (DATA-253: очередь A не отправляется с токеном B).
// - Нет сети / сервер недоступен → проход останавливается, запись остаётся `pending` (порядок сохраняется).
// - Временная ошибка сервера (5xx, 429) → `failed` + `next_attempt_at` (экспоненциальная задержка);
//   после [OutboxQueue.maxAttempts] ответов сервера с ошибкой или при постоянном отказе (4xx) → `dead`.
// - `attempts` растёт только при ответе сервера (07 §11.2): сбой без ответа (исключение обработчика,
//   неизвестная ошибка) — повтор по расписанию без учёта попытки ([OutboxOutcome.retry]).
// - `sending` после аварийного завершения процесса → снова `pending` (действия идемпотентны).
// Заказы и платежи в очередь не ставятся (DATA-254) — типы ограничены CHECK `outbox_actions.type`.
import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/tables/local_tables.dart' show outboxActionTypes;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:uuid/uuid.dart';

/// Типы действий очереди, которыми управляет core/sync (07 §11.2).
abstract final class OutboxTypes {
  static const String favoriteAdd = 'favorite.add';
  static const String favoriteRemove = 'favorite.remove';
  static const String recentClear = 'recent.clear';

  /// Изменения корзины (07 §11.2 «Контракт записей cart.sync»; полезная нагрузка — `CartSyncPayload`,
  /// core/sync/outbox_payloads.dart; обработчик — фича cart, этап F).
  static const String cartSync = 'cart.sync';

  /// Отметка уведомления прочитанным офлайн (`POST /notifications/{id}/read`; обработчик — фича notifications).
  static const String notificationRead = 'notification.read';

  /// Отложенный выход, выполненный офлайн (ядро §19.4; перенос RM-E RC-1/SS-07: тип и полезная нагрузка —
  /// `AuthLogoutPayload`; обработчик — агент переносов).
  static const String authLogout = 'auth.logout';
}

/// Исход обработки записи.
enum OutboxOutcome {
  /// Сервер подтвердил (2xx или идемпотентный эквивалент) — запись `done`.
  done,

  /// Нет связи — повторить после восстановления сети; проход останавливается, попытка не считается.
  deferred,

  /// Временная ошибка сервера (ответ получен) — `failed`, попытка считается, повтор по расписанию.
  failed,

  /// Сбой без ответа сервера (исключение, неизвестная ошибка) — `failed` с задержкой, попытка не считается.
  retry,

  /// Постоянный отказ — `dead`, без повторов.
  dead,
}

/// Запись очереди для обработчика.
final class OutboxAction {
  const OutboxAction({
    required this.id,
    required this.type,
    required this.payload,
    required this.idempotencyKey,
    required this.attempts,
    required this.createdAt,
    this.database,
  });

  final int id;
  final String type;
  final Map<String, Object?> payload;
  final String idempotencyKey;

  /// Номер текущей попытки (с 1).
  final int attempts;
  final DateTime createdAt;

  /// БД владельца записи, открытая на старте прохода: локальные отметки пишутся в неё, а не в БД
  /// пользователя, вошедшего позже (07 §11.1 п.2).
  final AppDatabase? database;
}

/// Обработчик типов действий (06 §6.2 «реестр OutboxActionHandler»).
abstract interface class OutboxActionHandler {
  /// Обслуживаемые типы `outbox_actions.type`.
  Set<String> get types;

  /// Отправить действие. Исключения — сбой без ответа сервера ([OutboxOutcome.retry]).
  Future<OutboxOutcome> handle(OutboxAction action);
}

/// Классификация `Failure` для очереди.
OutboxOutcome outboxOutcomeOf(Failure failure) => switch (failure) {
  NetworkFailure() => OutboxOutcome.deferred,
  // Сессия: обновление токена / разблокировка — дело AuthInterceptor; запись ждёт следующего прохода.
  AuthFailure() => OutboxOutcome.deferred,
  AppUpdateRequiredFailure() => OutboxOutcome.deferred,
  // `catalog_not_loaded` (08 §4.7.1 п. 2): каталог 1С ещё не загружен — состояние сервера, а не отказ записи;
  // повтор с задержкой без счёта попытки, чтобы изменения корзины не ушли в `dead` до первичной загрузки.
  OnecUnavailableFailure(catalogNotLoaded: true) => OutboxOutcome.retry,
  OnecUnavailableFailure() => OutboxOutcome.failed,
  ServerFailure(:final status) when status >= 500 || status == 429 || status == 408 => OutboxOutcome.failed,
  ConflictFailure(:final kind) when kind == ConflictKind.idempotencyInProgress => OutboxOutcome.failed,
  ServerFailure() || ValidationFailure() || PermissionFailure() || ConflictFailure() => OutboxOutcome.dead,
  // Ответа сервера нет или он не распознан — попытка не считается (07 §11.2).
  UnknownFailure() => OutboxOutcome.retry,
};

/// Итог прохода [OutboxQueue.flush].
final class OutboxFlushReport {
  const OutboxFlushReport({
    this.sent = 0,
    this.failed = 0,
    this.dead = 0,
    this.deferred = false,
    this.interrupted = false,
  });

  final int sent;
  final int failed;
  final int dead;

  /// Проход остановлен из-за отсутствия связи.
  final bool deferred;

  /// Проход остановлен: сменились пользователь сессии или БД (оставшиеся записи ждут владельца).
  final bool interrupted;

  @override
  String toString() =>
      'OutboxFlushReport(sent: $sent, failed: $failed, dead: $dead, deferred: $deferred, interrupted: $interrupted)';
}

final class OutboxQueue {
  OutboxQueue({
    required AppDatabase? Function() database,
    required String? Function() owner,
    required Clock clock,
    required List<OutboxActionHandler> handlers,
    String Function()? newKey,
  }) : _database = database,
       _owner = owner,
       _clock = clock,
       _newKey = newKey ?? const Uuid().v4,
       _handlers = {
         for (final h in handlers)
           for (final t in h.types) t: h,
       };

  final AppDatabase? Function() _database;
  final String? Function() _owner;
  final Clock _clock;
  final String Function() _newKey;
  final Map<String, OutboxActionHandler> _handlers;
  Future<OutboxFlushReport>? _inflight;

  /// Предел ответов сервера с ошибкой до `dead` (07 §11.2: «dead — после 10 ответов сервера с ошибкой»).
  static const int maxAttempts = 10;

  /// Срок хранения записей `done` (затем удаляются при следующем проходе).
  static const Duration keepDone = Duration(days: 1);

  /// Задержка перед повтором после [attempts] неудачных попыток: 5 с · 2^(n−1), не более 15 мин.
  static Duration backoff(int attempts) {
    final n = attempts < 1 ? 1 : (attempts > 12 ? 12 : attempts);
    final d = Duration(seconds: 5 * (1 << (n - 1)));
    const cap = Duration(minutes: 15);
    return d > cap ? cap : d;
  }

  /// JSON полезной нагрузки — канонический (ключи по алфавиту), чтобы находить записи той же цели.
  static String encodePayload(Map<String, Object?> payload) {
    final keys = payload.keys.toList()..sort();
    return jsonEncode({for (final k in keys) k: payload[k]});
  }

  /// Поставить действие в очередь. [supersedes] — типы записей той же цели (тот же `payload`), которые ещё не
  /// отправлены и теряют смысл после нового действия (например, `favorite.add` после `favorite.remove`).
  /// Возвращает `Idempotency-Key` записи; `null` — БД пользователя не открыта или пользователь неизвестен.
  Future<String?> enqueue(
    String type,
    Map<String, Object?> payload, {
    Set<String> supersedes = const <String>{},
    bool coalesce = false,
  }) async {
    if (!outboxActionTypes.contains(type)) throw ArgumentError.value(type, 'type', 'нет в outbox_actions.type');
    final db = _database();
    final owner = _owner();
    if (db == null || owner == null) return null;
    final json = encodePayload(payload);
    return db.transaction(() async {
      if (coalesce) {
        final same =
            await (db.select(db.outboxActions)..where(
                  (t) =>
                      t.ownerUserId.equals(owner) &
                      t.type.equals(type) &
                      t.payloadJson.equals(json) &
                      t.status.isIn(const ['pending', 'failed']),
                ))
                .getSingleOrNull();
        if (same != null) return same.idempotencyKey;
      }
      final drop = {...supersedes, type};
      await (db.delete(db.outboxActions)..where(
            (t) =>
                t.ownerUserId.equals(owner) &
                t.type.isIn(drop) &
                t.payloadJson.equals(json) &
                t.status.isIn(const ['pending', 'failed']),
          ))
          .go();
      final key = _newKey();
      await db
          .into(db.outboxActions)
          .insert(
            OutboxActionsCompanion.insert(
              type: type,
              payloadJson: json,
              idempotencyKey: key,
              ownerUserId: owner,
              createdAt: _clock.nowUtc().millisecondsSinceEpoch,
            ),
          );
      return key;
    });
  }

  /// Число записей, ожидающих отправки (`pending`, `sending`, `failed`) текущего пользователя.
  Future<int> pendingCount() async {
    final db = _database();
    final owner = _owner();
    if (db == null || owner == null) return 0;
    final count = db.outboxActions.id.count();
    final q = db.selectOnly(db.outboxActions)
      ..addColumns([count])
      ..where(
        db.outboxActions.ownerUserId.equals(owner) &
            db.outboxActions.status.isIn(const ['pending', 'sending', 'failed']),
      );
    return (await q.getSingle()).read(count) ?? 0;
  }

  /// Поток [pendingCount] (0, пока БД не открыта).
  Stream<int> watchPendingCount() {
    final db = _database();
    final owner = _owner();
    if (db == null || owner == null) return Stream<int>.value(0);
    final count = db.outboxActions.id.count();
    final q = db.selectOnly(db.outboxActions)
      ..addColumns([count])
      ..where(
        db.outboxActions.ownerUserId.equals(owner) &
            db.outboxActions.status.isIn(const ['pending', 'sending', 'failed']),
      );
    return q.watchSingle().map((r) => r.read(count) ?? 0);
  }

  /// Отправить готовые записи (single-flight: параллельный вызов получает тот же проход).
  Future<OutboxFlushReport> flush() => _inflight ??= _flush().whenComplete(() => _inflight = null);

  Future<OutboxFlushReport> _flush() async {
    final db = _database();
    final owner = _owner();
    if (db == null || owner == null) return const OutboxFlushReport();
    final now = _clock.nowUtc().millisecondsSinceEpoch;
    // Запись `sending` — проход прервался (процесс завершён): действие идемпотентно, повторяем.
    await (db.update(db.outboxActions)..where((t) => t.ownerUserId.equals(owner) & t.status.equals('sending'))).write(
      const OutboxActionsCompanion(status: Value('pending')),
    );
    await (db.delete(db.outboxActions)..where(
          (t) =>
              t.ownerUserId.equals(owner) &
              t.status.equals('done') &
              t.createdAt.isSmallerThanValue(now - keepDone.inMilliseconds),
        ))
        .go();
    final ready =
        await (db.select(db.outboxActions)
              ..where(
                (t) =>
                    t.ownerUserId.equals(owner) &
                    t.status.isIn(const ['pending', 'failed']) &
                    (t.nextAttemptAt.isNull() | t.nextAttemptAt.isSmallerOrEqualValue(now)),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.id)]))
            .get();
    var sent = 0;
    var failed = 0;
    var dead = 0;
    OutboxFlushReport interrupted() => OutboxFlushReport(sent: sent, failed: failed, dead: dead, interrupted: true);
    for (final row in ready) {
      final handler = _handlers[row.type];
      if (handler == null) continue; // тип обслуживает другая фича (например, `cart.sync`) — не трогаем
      if (!_sameSession(db, owner)) return interrupted();
      final attempt = row.attempts + 1;
      await _write(db, row.id, const OutboxActionsCompanion(status: Value('sending')));
      // Проверка и вызов обработчика — в одном синхронном участке: запрос уходит с токеном владельца записи.
      if (!_sameSession(db, owner)) {
        await _restorePending(db, row.id);
        return interrupted();
      }
      OutboxOutcome outcome;
      String? error;
      try {
        outcome = await handler.handle(
          OutboxAction(
            id: row.id,
            type: row.type,
            payload: _decode(row.payloadJson),
            idempotencyKey: row.idempotencyKey,
            attempts: attempt,
            createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt, isUtc: true),
            database: db,
          ),
        );
      } on Object catch (e) {
        outcome = OutboxOutcome.retry;
        error = e.runtimeType.toString();
      }
      final at = _clock.nowUtc();
      switch (outcome) {
        case OutboxOutcome.done:
          sent++;
          await _write(
            db,
            row.id,
            const OutboxActionsCompanion(status: Value('done'), lastError: Value(null), nextAttemptAt: Value(null)),
          );
        case OutboxOutcome.deferred:
          // Попытка не считается: запись ждёт связи.
          await _write(db, row.id, const OutboxActionsCompanion(status: Value('pending')));
          return OutboxFlushReport(sent: sent, failed: failed, dead: dead, deferred: true);
        case OutboxOutcome.retry:
          // Ответа сервера нет — попытка не считается и к `dead` не ведёт (07 §11.2).
          failed++;
          await _write(
            db,
            row.id,
            OutboxActionsCompanion(
              status: const Value('failed'),
              lastError: Value(error ?? 'retry'),
              nextAttemptAt: Value(at.add(backoff(attempt)).millisecondsSinceEpoch),
            ),
          );
        case OutboxOutcome.failed when attempt >= maxAttempts:
        case OutboxOutcome.dead:
          dead++;
          await _write(
            db,
            row.id,
            OutboxActionsCompanion(
              status: const Value('dead'),
              attempts: Value(attempt),
              lastError: Value(error ?? outcome.name),
            ),
          );
        case OutboxOutcome.failed:
          failed++;
          await _write(
            db,
            row.id,
            OutboxActionsCompanion(
              status: const Value('failed'),
              attempts: Value(attempt),
              lastError: Value(error ?? 'failed'),
              nextAttemptAt: Value(at.add(backoff(attempt)).millisecondsSinceEpoch),
            ),
          );
      }
    }
    return OutboxFlushReport(sent: sent, failed: failed, dead: dead);
  }

  /// Сессия прохода всё ещё текущая: тот же владелец и та же открытая БД.
  bool _sameSession(AppDatabase db, String owner) => _owner() == owner && identical(_database(), db);

  /// Запись возвращается в `pending` (БД прежнего пользователя могла закрыться — тогда это сделает
  /// следующий проход его сессии: `sending` → `pending`).
  static Future<void> _restorePending(AppDatabase db, int id) async {
    try {
      await _write(db, id, const OutboxActionsCompanion(status: Value('pending')));
    } on Object {
      // БД закрыта при смене пользователя — восстановление выполнит следующий проход владельца.
    }
  }

  static Future<void> _write(AppDatabase db, int id, OutboxActionsCompanion values) =>
      (db.update(db.outboxActions)..where((t) => t.id.equals(id))).write(values);

  static Map<String, Object?> _decode(String json) {
    final v = jsonDecode(json);
    return v is Map ? v.cast<String, Object?>() : <String, Object?>{};
  }
}
