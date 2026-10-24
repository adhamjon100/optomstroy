// RC-1 / SS-07 (перенос из этапа E): офлайн-выход с отложенным отзывом серверной сессии — запись secure storage
// `pending_logout` + outbox `auth.logout` без токенов (ядро §19.4; 02 SCR-41 UI-41-005 п. 1–5, AC-UI-41-007,
// AC-UI-41-014; 09 §8.6, SESS-020, AC-AUTH-058 (г); 08 §4.1.3, §4.1.4, §4.1.6).
// Проверяется: офлайн-выход → сеть → сервер получил `POST /auth/refresh` и `POST /auth/logout`; секрет удаляется
// во всех исходах; по сохранённому секрету войти нельзя; вход другого пользователя доставке не мешает.
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/session/pending_logout.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/core/sync/auth_logout_outbox.dart';
import 'package:optomstroy/core/sync/outbox_payloads.dart';
import 'package:optomstroy/core/sync/outbox_queue.dart';

import '../database/test_database.dart';
import 'session_harness.dart';

/// Фейковый сервер авторизации: сеть вкл/выкл, ответы refresh/logout/DELETE задаются тестом.
/// Ротированный refresh фейкового сервера (тестовое значение).
const String _rotated = 'r-rotated';

final class _AuthServer {
  bool online = true;
  ResponseBody Function(RequestOptions o)? onRefresh;
  ResponseBody Function(RequestOptions o)? onLogout;
  ResponseBody Function(RequestOptions o)? onDelete;

  /// `Authorization` каждого `POST /auth/logout`, дошедшего до сервера.
  final List<Object?> logoutBearers = <Object?>[];

  /// Тела `POST /auth/refresh`, дошедшие до сервера.
  final List<Object?> refreshBodies = <Object?>[];

  Future<ResponseBody> call(RequestOptions o) async {
    if (!online) transportError(o, DioExceptionType.connectionError);
    final path = o.uri.path.replaceFirst('/api/v1', '');
    if (path == '/auth/refresh') {
      refreshBodies.add(o.data);
      return onRefresh?.call(o) ?? json(200, tokenPair(fakeJwt(tag: 'delivery'), _rotated));
    }
    if (path == '/auth/logout') {
      logoutBearers.add(o.headers[ApiHeaders.authorization]);
      return onLogout?.call(o) ?? json(204, null);
    }
    if (o.method == 'DELETE' && path.startsWith('/auth/sessions/')) {
      return onDelete?.call(o) ?? json(204, null);
    }
    return json(200, <String, Object?>{'ok': true});
  }
}

List<Map<String, Object?>> _records(SessionHarness h) {
  final raw = h.storage.values[SecureKey.pendingLogout];
  if (raw == null) return const <Map<String, Object?>>[];
  return (jsonDecode(raw) as List<Object?>).cast<Map<String, Object?>>();
}

/// Офлайн-выход после входа: сервер недоступен на время `logout()`.
Future<SessionController> _offlineLogout(SessionHarness h, _AuthServer server) async {
  final c = h.start();
  server.online = true;
  await c.establish(accessToken: fakeJwt(), refreshToken: 'r1');
  server.online = false;
  await c.logout();
  return c;
}

void main() {
  setUpAll(configureSqliteForTests);

  group('офлайн-выход (02 UI-41-005, AC-UI-41-007)', () {
    test('локальный выход сразу; в secure storage — только deviceId и pending_logout; outbox auth.logout без токенов; '
        'сеть → POST /auth/refresh → POST /auth/logout, секрет удалён', () async {
      final server = _AuthServer();
      final h = SessionHarness(server.call, withDatabase: true);
      addTearDown(h.dispose);
      await _offlineLogout(h, server);

      expect(h.state.status, SessionStatus.unauthenticated);
      expect(h.state.serverLogoutPending, isTrue);
      expect(h.tokens.accessToken, isNull);
      expect(h.storage.values.keys, unorderedEquals(<SecureKey>[SecureKey.deviceId, SecureKey.pendingLogout]));
      final records = _records(h);
      expect(records, hasLength(1));
      expect(records.single['refreshToken'], 'r1');
      expect(records.single['sid'], 'sid-1');
      expect(records.single.keys, isNot(contains('accessToken')));

      final db = h.db!;
      final rows = await db.select(db.outboxActions).get();
      expect(rows.map((r) => r.type), <String>[OutboxTypes.authLogout]);
      expect(rows.single.ownerUserId, staffUserId);
      expect(rows.single.payloadJson, isNot(contains('r1')), reason: 'токен — только в secure storage');
      final payload = AuthLogoutPayload.tryParse(
        (jsonDecode(rows.single.payloadJson) as Map<String, Object?>).cast<String, Object?>(),
      );
      expect(payload?.sessionId, 'sid-1');
      expect(payload?.requestedAt, t0);

      // Пока сети нет — доставка откладывается, запись сохраняется.
      final offline = await h.pendingLogout.deliver();
      expect(offline.deferred, isTrue);
      expect(_records(h), hasLength(1));

      server.online = true;
      final report = await h.pendingLogout.deliver();
      expect(report.delivered, 1);
      expect(server.refreshBodies.last, <String, Object?>{'refreshToken': 'r1'});
      expect(server.logoutBearers.last, 'Bearer ${fakeJwt(tag: 'delivery')}');
      expect(h.adapter.requests.lastWhere((r) => r.path == '/auth/refresh').headers[ApiHeaders.authorization], isNull);
      expect(h.storage.values.keys, <SecureKey>[SecureKey.deviceId], reason: 'секрет и полученные токены удалены');
      expect(h.tokens.accessToken, isNull, reason: 'токены доставки не становятся сессией');
      expect(h.state.status, SessionStatus.unauthenticated);
    });

    test('сигнал «сеть появилась» запускает доставку', () async {
      final server = _AuthServer();
      final h = SessionHarness(server.call);
      addTearDown(h.dispose);
      await _offlineLogout(h, server);
      final restored = StreamController<void>.broadcast();
      addTearDown(restored.close);
      h.pendingLogout.watchNetwork(restored.stream);

      server.online = true;
      restored.add(null);
      await until(() => !h.storage.values.containsKey(SecureKey.pendingLogout));
      expect(server.logoutBearers, hasLength(1));
    });

    test('ответ сервера на logout (401 SESSION_REVOKED) — обычный выход без отложенной записи', () async {
      final server = _AuthServer()..onLogout = (o) => json(401, problem('SESSION_REVOKED', 401));
      final h = SessionHarness(server.call, withDatabase: true);
      addTearDown(h.dispose);
      final c = h.start();
      await c.establish(accessToken: fakeJwt(), refreshToken: 'r1');
      await c.logout();
      expect(h.state.serverLogoutPending, isFalse);
      expect(h.storage.values.keys, <SecureKey>[SecureKey.deviceId]);
      expect(await h.db!.select(h.db!.outboxActions).get(), isEmpty);
    });

    test('logout → 503 (сервер не ответил по существу) — отложенный выход', () async {
      final server = _AuthServer()..onLogout = (o) => json(503, problem('INTERNAL', 503));
      final h = SessionHarness(server.call);
      addTearDown(h.dispose);
      final c = h.start();
      await c.establish(accessToken: fakeJwt(), refreshToken: 'r1');
      await c.logout();
      expect(h.state.serverLogoutPending, isTrue);
      expect(_records(h), hasLength(1));
    });
  });

  group('войти по сохранённому секрету нельзя', () {
    test(
      'холодный старт после офлайн-выхода: SCR-01 (не SCR-08); запросы уходят без Bearer, refresh не вызывается',
      () async {
        final server = _AuthServer();
        final before = SessionHarness(server.call);
        addTearDown(before.dispose);
        await _offlineLogout(before, server);
        final refreshesBefore = server.refreshBodies.length;

        // «Перезапуск»: новый процесс (контейнер, Dio, память) над тем же secure storage, сети нет.
        final h = SessionHarness(server.call);
        addTearDown(h.dispose);
        h.storage.values
          ..clear()
          ..addAll(before.storage.values);
        await before.dispose();
        final c = h.start();
        expect(await c.restore(), SessionStatus.unauthenticated);
        expect(h.state.isLocked, isFalse, reason: 'SCR-08 «Быстрый вход» не предлагается');
        expect(await h.tokens.readRefreshToken(), isNull);
        // restore() запустил фоновую доставку — без сети она откладывается (тот же проход, single-flight).
        expect((await h.pendingLogout.deliver()).deferred, isTrue);

        server.online = true;
        expect(h.storage.values.containsKey(SecureKey.pendingLogout), isTrue);
        final probe = await h.dio.get<Object?>('/me');
        expect(probe.statusCode, 200);
        final me = h.adapter.requests.lastWhere((r) => r.path == '/me');
        expect(me.headers[ApiHeaders.authorization], isNull, reason: 'секрет pending_logout не даёт Bearer');
        expect(server.refreshBodies.length, refreshesBefore, reason: 'AuthInterceptor секрет не использует');
        // Единственный refresh после перезапуска — доставка отложенного выхода (а не вход): затем — logout.
        await h.pendingLogout.deliver();
        expect(h.storage.values.containsKey(SecureKey.pendingLogout), isFalse);
        expect(server.refreshBodies.length - refreshesBefore, 1);
        expect(server.logoutBearers, hasLength(1));
        expect(h.state.status, SessionStatus.unauthenticated);
      },
    );
  });

  group('секрет удаляется во всех исходах', () {
    Future<SessionHarness> pendingWith(_AuthServer server) async {
      final h = SessionHarness(server.call, withDatabase: true);
      addTearDown(h.dispose);
      await _offlineLogout(h, server);
      expect(_records(h), hasLength(1));
      server.online = true;
      return h;
    }

    test(
      'refresh → 401 SESSION_REVOKED (истекла / reuse / отозвана администратором) → запись удалена, logout не нужен',
      () async {
        for (final reason in <String>['reuse_detected', 'expired', 'admin']) {
          final server = _AuthServer()
            ..onRefresh = (o) => json(401, problem('SESSION_REVOKED', 401, extra: <String, Object?>{'reason': reason}));
          final h = await pendingWith(server);
          final r = await h.pendingLogout.deliver();
          expect(r.removed, 1, reason: reason);
          expect(h.storage.values.containsKey(SecureKey.pendingLogout), isFalse, reason: reason);
          expect(server.logoutBearers, isEmpty);
        }
      },
    );

    test('refresh → 409 DEVICE_MISMATCH → запись удалена', () async {
      final server = _AuthServer()..onRefresh = (o) => json(409, problem('DEVICE_MISMATCH', 409));
      final h = await pendingWith(server);
      await h.pendingLogout.deliver();
      expect(h.storage.values.containsKey(SecureKey.pendingLogout), isFalse);
    });

    test('logout → 401 SESSION_REVOKED → запись удалена', () async {
      final server = _AuthServer();
      final h = await pendingWith(server);
      server.onLogout = (o) => json(401, problem('SESSION_REVOKED', 401));
      final r = await h.pendingLogout.deliver();
      expect(r.removed, 1);
      expect(h.storage.values.containsKey(SecureKey.pendingLogout), isFalse);
    });

    test('сеть пропала между refresh и logout → в записи ротированный refresh; следующий проход — им', () async {
      final server = _AuthServer();
      final h = await pendingWith(server);
      server.onLogout = (o) => transportError(o, DioExceptionType.connectionTimeout);
      final first = await h.pendingLogout.deliver();
      expect(first.deferred, isTrue);
      expect(_records(h).single['refreshToken'], _rotated);

      server.onLogout = null;
      final second = await h.pendingLogout.deliver();
      expect(second.delivered, 1);
      expect(server.refreshBodies.last, <String, Object?>{'refreshToken': _rotated});
      expect(h.storage.values.containsKey(SecureKey.pendingLogout), isFalse);
    });

    test('ответы 5xx: попытки считаются, после 10 — ожидание входа владельца (fallback)', () async {
      final server = _AuthServer()..onRefresh = (o) => json(500, problem('INTERNAL', 500));
      final h = await pendingWith(server);
      for (var i = 0; i < PendingLogoutService.maxAttempts; i++) {
        await h.pendingLogout.deliver();
      }
      expect(_records(h).single['fallback'], isTrue);
      final refreshes = server.refreshBodies.length;
      await h.pendingLogout.deliver();
      expect(server.refreshBodies.length, refreshes, reason: 'fallback без входа владельца не повторяется');
    });

    test('запись старше 8 дней удаляется без запросов', () async {
      final server = _AuthServer();
      final h = await pendingWith(server);
      h.clock.advance(const Duration(days: 9));
      final r = await h.pendingLogout.deliver();
      expect(r.remaining, 0);
      expect(server.refreshBodies, isEmpty);
      expect(h.storage.values.containsKey(SecureKey.pendingLogout), isFalse);
    });

    test('повреждённая запись удаляется', () async {
      final h = SessionHarness((o) async => json(204, null));
      addTearDown(h.dispose);
      h.storage.values[SecureKey.pendingLogout] = '{not json';
      final r = await h.pendingLogout.deliver();
      expect(r.remaining, 0);
      await h.pendingLogout.remember(
        PendingLogoutEntry(refreshToken: 'rx', createdAt: t0), // check-secrets: allow — тестовое значение
      );
      expect(_records(h), hasLength(1));
    });

    test('UNLOCK_REQUIRED на refresh (Windows) → вход того же пользователя → outbox auth.logout → '
        'DELETE /auth/sessions/{sid} → запись удалена, действие done (AC-UI-41-014)', () async {
      final server = _AuthServer()..onRefresh = (o) => json(401, problem('UNLOCK_REQUIRED', 401));
      final h = await pendingWith(server);
      await h.pendingLogout.deliver();
      expect(_records(h).single['fallback'], isTrue);
      expect(server.logoutBearers, isEmpty);

      // Вход того же пользователя: новая сессия; очередь владельца отправляет auth.logout.
      server.onRefresh = null;
      final c = h.controller;
      final access = fakeJwt(tag: 'new');
      await c.establish(accessToken: access, refreshToken: 'r9');
      expect(h.state.serverLogoutPending, isFalse);
      final db = h.db!;
      final queue = OutboxQueue(
        database: () => db,
        owner: () => h.state.userId,
        clock: h.clock,
        handlers: <OutboxActionHandler>[AuthLogoutOutboxHandler(service: () => h.pendingLogout, dio: () => h.dio)],
      );
      final report = await queue.flush();
      expect(report.sent, 1);
      final delete = h.adapter.requests.singleWhere((r) => r.method == 'DELETE');
      expect(delete.path, '/auth/sessions/sid-1');
      expect(delete.headers[ApiHeaders.authorization], 'Bearer $access');
      expect(h.storage.values.containsKey(SecureKey.pendingLogout), isFalse);
      expect((await db.select(db.outboxActions).getSingle()).status, 'done');
      expect(await h.tokens.readRefreshToken(), 'r9', reason: 'текущая сессия не затронута');
    });

    test('outbox auth.logout после доставки устройством — done без запросов', () async {
      final server = _AuthServer();
      final h = await pendingWith(server);
      await h.pendingLogout.deliver();
      final requests = h.adapter.requests.length;
      await h.controller.establish(
        accessToken: fakeJwt(tag: 'new'),
        refreshToken: 'r9',
      );
      final db = h.db!;
      final queue = OutboxQueue(
        database: () => db,
        owner: () => h.state.userId,
        clock: h.clock,
        handlers: <OutboxActionHandler>[AuthLogoutOutboxHandler(service: () => h.pendingLogout, dio: () => h.dio)],
      );
      expect((await queue.flush()).sent, 1);
      expect(h.adapter.requests.length, requests);
    });
  });

  group('вход нового пользователя не мешает доставке (02 UI-41-005 п. 5)', () {
    test('вход другого пользователя: сначала refresh → logout прежней сессии, затем новая сессия', () async {
      final server = _AuthServer();
      final h = SessionHarness(server.call, withDatabase: true);
      addTearDown(h.dispose);
      final c = await _offlineLogout(h, server);
      server.online = true;

      await c.establish(
        accessToken: fakeJwt(sub: otherUserId, tag: 'b'),
        refreshToken: 'rb',
      );

      expect(server.refreshBodies.last, <String, Object?>{'refreshToken': 'r1'});
      expect(server.logoutBearers, hasLength(1));
      expect(h.storage.values.containsKey(SecureKey.pendingLogout), isFalse);
      expect(h.state.userId, otherUserId);
      expect(await h.tokens.readRefreshToken(), 'rb');
      expect(h.tokens.accessToken, fakeJwt(sub: otherUserId, tag: 'b'));
    });

    test('доставка не удалась при входе — вход выполняется, запись сохраняется и доставляется позже', () async {
      final server = _AuthServer();
      final h = SessionHarness(server.call, withDatabase: true);
      addTearDown(h.dispose);
      final c = await _offlineLogout(h, server);
      server.online = true;
      server.onRefresh = (o) => json(503, problem('INTERNAL', 503));

      await c.establish(
        accessToken: fakeJwt(sub: otherUserId, tag: 'b'),
        refreshToken: 'rb',
      );
      expect(h.state.status, SessionStatus.authenticated);
      expect(h.state.userId, otherUserId);
      expect(_records(h), hasLength(1));

      // Новый пользователь работает; его выход онлайн не трогает запись прежнего.
      server.onRefresh = null;
      await c.logout();
      expect(_records(h), hasLength(1), reason: 'очистка сессии не удаляет pending_logout');

      final r = await h.pendingLogout.deliver();
      expect(r.delivered, 1);
      expect(h.storage.values.containsKey(SecureKey.pendingLogout), isFalse);
    });
  });
}
