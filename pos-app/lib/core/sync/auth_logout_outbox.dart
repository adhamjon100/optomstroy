// Тип outbox `auth.logout` (ядро §19.4; 07 §11.2; 02 SCR-41 UI-41-005 п. 2, 4; перенос RM-E RC-1 / SS-07).
//
// - [enqueueAuthLogout] — запись в `outbox_actions` БД пользователя при офлайн-выходе: `payload_json` =
//   `AuthLogoutPayload` (`requestedAt`, `sessionId?`) — **без токенов** (токен — только запись secure storage
//   `pending_logout`, core/session/pending_logout.dart).
// - [AuthLogoutOutboxHandler] — обработчик очереди владельца (выполняется только его сессией, 07 §11.1 п. 2):
//   запись `pending_logout` уже доставлена устройством (сигнал сети) → `done`; иначе refresh → logout, а при
//   недоступном refresh (`UNLOCK_REQUIRED`, исчерпаны попытки) — `DELETE /auth/sessions/{sid}` из новой сессии
//   (AC-UI-41-014). Доставка без сессии (после выхода, при входе другого пользователя) от очереди не зависит:
//   её выполняет `PendingLogoutService.deliver` по сигналу сети.
import 'package:dio/dio.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/session/pending_logout.dart';
import 'package:optomstroy/core/sync/outbox_payloads.dart';
import 'package:optomstroy/core/sync/outbox_queue.dart';
import 'package:optomstroy/core/utils/clock.dart';

/// Поставить `auth.logout` в очередь владельца [ownerUserId] файла [db]. Возвращает `Idempotency-Key` записи.
Future<String?> enqueueAuthLogout({
  required AppDatabase db,
  required String ownerUserId,
  required AuthLogoutPayload payload,
  required Clock clock,
}) => OutboxQueue(
  database: () => db,
  owner: () => ownerUserId,
  clock: clock,
  handlers: const <OutboxActionHandler>[],
).enqueue(OutboxTypes.authLogout, payload.toJson());

/// Обработчик `auth.logout`.
final class AuthLogoutOutboxHandler implements OutboxActionHandler {
  AuthLogoutOutboxHandler({required PendingLogoutService Function() service, required Dio Function() dio})
    : _service = service,
      _dio = dio;

  final PendingLogoutService Function() _service;

  /// Основной Dio (Bearer текущей сессии владельца) — для `DELETE /auth/sessions/{sid}`.
  final Dio Function() _dio;

  @override
  Set<String> get types => const <String>{OutboxTypes.authLogout};

  @override
  Future<OutboxOutcome> handle(OutboxAction action) async {
    final AuthLogoutPayload? payload = AuthLogoutPayload.tryParse(action.payload);
    if (payload == null) return OutboxOutcome.dead;
    final PendingLogoutResult result = await _service().settle(
      payload,
      revokeWithSession: (String sid) => PendingLogoutService.revokeOwnSession(_dio(), sid),
    );
    return switch (result) {
      PendingLogoutResult.delivered ||
      PendingLogoutResult.alreadyEnded ||
      PendingLogoutResult.notFound => OutboxOutcome.done,
      PendingLogoutResult.deferred => OutboxOutcome.deferred,
      PendingLogoutResult.failed || PendingLogoutResult.fallback => OutboxOutcome.failed,
    };
  }
}
