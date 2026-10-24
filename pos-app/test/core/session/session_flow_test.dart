// RM-D-009: сессия клиента поверх настоящего DioClient (T-SESS-003, T-SESS-010, T-SESS-013, T-SESS-016,
// T-SESS-019, T-SESS-020, T-BIO-012; AC-UI-08-004; 09 §8.3, §8.8; 08 §2.12):
// очередь refresh, reuse → выход, step-up с повтором и переиспользованием токена области, UNLOCK_REQUIRED →
// разблокировка `POST /auth/unlock`, PIN_INVALID без refresh, 426, выход с очисткой секретов и черновиков.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/app_version/app_version_controller.dart';
import 'package:optomstroy/core/network/interceptors/auth_interceptor.dart';
import 'package:optomstroy/core/session/session_api.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_overlay.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/core/session/step_up_coordinator.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';

import '../database/test_database.dart';
import 'session_harness.dart';

void main() {
  setUpAll(configureSqliteForTests);

  group('восстановление и вход', () {
    test('холодный старт: refresh есть → authenticated + SCR-08 cold; нет → unauthenticated', () async {
      final withSession = SessionHarness((o) async => json(200, {}), refresh: 'r1');
      addTearDown(withSession.dispose);
      withSession.start();
      expect(await withSession.container.read(sessionStatusProvider.future), SessionStatus.authenticated);
      expect(withSession.state.lock, SessionLockReason.coldStart);
      expect(withSession.container.read(sessionOverlayProvider).kind, SessionOverlayKind.locked);

      final guest = SessionHarness((o) async => json(200, {}));
      addTearDown(guest.dispose);
      guest.start();
      expect(await guest.container.read(sessionStatusProvider.future), SessionStatus.unauthenticated);
      expect(guest.container.read(sessionOverlayProvider), SessionOverlay.none);
    });

    test('establish: access только в памяти, refresh — в secure storage; хуки подключены к AuthInterceptor', () async {
      final h = SessionHarness((o) async => json(200, {'ok': true}));
      addTearDown(h.dispose);
      final c = h.start();
      expect(AuthInterceptor.of(h.dio)!.hooks, same(c));
      final access = fakeJwt();
      await c.establish(accessToken: access, refreshToken: 'r1');
      expect(h.state.status, SessionStatus.authenticated);
      expect(h.state.userKind, UserKind.staff);
      expect(h.state.userId, staffUserId);
      expect(h.tokens.accessToken, access);
      // T-SESS-003: access-токена нет ни в одном ключе secure storage.
      expect(h.storage.values.values, isNot(contains(access)));
      expect(h.storage.values[SecureKey.refreshToken], 'r1');
      await h.dio.get<Object?>('/me');
      expect(h.adapter.requests.last.headers[ApiHeaders.authorization], 'Bearer $access');
    });
  });

  group('очередь refresh (T-SESS-010)', () {
    test('5 параллельных 401 TOKEN_STALE → ровно один /auth/refresh, все повторены с новым токеном', () async {
      final fresh = fakeJwt(tag: 'new');
      var refreshes = 0;
      final h = SessionHarness((o) async {
        if (o.path.endsWith('/auth/refresh')) {
          refreshes++;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return json(200, tokenPair(fresh, 'r2'));
        }
        return o.headers[ApiHeaders.authorization] == 'Bearer $fresh'
            ? json(200, {'ok': true})
            : json(401, problem('TOKEN_STALE', 401));
      });
      addTearDown(h.dispose);
      await h.start().establish(
        accessToken: fakeJwt(tag: 'old'),
        refreshToken: 'r1',
      );
      final results = await Future.wait([for (var i = 0; i < 5; i++) h.dio.get<Object?>('/catalog/$i')]);
      expect(results.map((r) => r.statusCode), everyElement(200));
      expect(refreshes, 1);
      expect(h.adapter.countPath('/auth/refresh'), 1);
      expect(h.storage.values[SecureKey.refreshToken], 'r2');
      expect(h.state.status, SessionStatus.authenticated);
    });

    test('access истекает через 30 с → refresh заранее, до запроса (09 §8.3)', () async {
      final h = SessionHarness((o) async {
        if (o.path.endsWith('/auth/refresh')) return json(200, tokenPair(fakeJwt(tag: 'new'), 'r2'));
        return json(200, {'ok': true});
      });
      addTearDown(h.dispose);
      await h.start().establish(
        accessToken: fakeJwt(exp: DateTime.now().toUtc().add(const Duration(seconds: 30))),
        refreshToken: 'r1',
      );
      await h.dio.get<Object?>('/me');
      expect(h.adapter.requests.map((r) => r.path), ['/auth/refresh', '/me']);
    });
  });

  group('завершение сессии сервером', () {
    test('refresh → 401 SESSION_REVOKED (reuse) → выход: токены удалены, deviceId сохранён, SCR-90 C', () async {
      final h = SessionHarness((o) async {
        if (o.path.endsWith('/auth/refresh')) {
          return json(401, problem('SESSION_REVOKED', 401, extra: {'reason': 'reuse_detected'}));
        }
        return json(401, problem('TOKEN_STALE', 401));
      });
      addTearDown(h.dispose);
      await h.start().establish(accessToken: fakeJwt(), refreshToken: 'r1');
      await h.storage.write(SecureKey.registrationFullName, 'черновик');
      final e = await fails(h.dio.get<Object?>('/orders'));
      expect(e.response?.statusCode, 401);
      await until(() => h.state.status == SessionStatus.unauthenticated);
      // D SS-03: причина отказа refresh (`reason: reuse_detected`) доходит до SCR-90 (раньше — «отозвана»).
      expect(h.state.endReason, SessionEndReason.reuseDetected);
      expect(h.state.showSessionEnded, isTrue);
      expect(h.storage.values.keys, [SecureKey.deviceId]);
      expect(h.tokens.accessToken, isNull);
      expect(await h.container.read(sessionStatusProvider.future), SessionStatus.unauthenticated);
      expect(h.container.read(sessionOverlayProvider).kind, SessionOverlayKind.sessionEnded);
      h.controller.acknowledgeEnded();
      expect(h.container.read(sessionOverlayProvider), SessionOverlay.none);
      expect(h.container.read(sessionEndReasonProvider), SessionEndReason.reuseDetected);
    });

    test('запрос → 401 SESSION_REVOKED {reason: reuse_detected} → причина «все сессии завершены»; '
        'параллельные отказы не дублируют выход', () async {
      final h = SessionHarness(
        (o) async => json(401, problem('SESSION_REVOKED', 401, extra: {'reason': 'reuse_detected'})),
      );
      addTearDown(h.dispose);
      await h.start().establish(accessToken: fakeJwt(), refreshToken: 'r1');
      await Future.wait([fails(h.dio.get<Object?>('/a')), fails(h.dio.get<Object?>('/b'))]);
      await until(() => h.state.endReason != null);
      await settle();
      expect(h.state.endReason, SessionEndReason.reuseDetected);
      expect(h.adapter.countPath('/auth/refresh'), 0);
      expect(h.events.where((e) => e == SessionEvent.ended), hasLength(2));
      expect(h.storage.values[SecureKey.refreshToken], isNull);
    });

    test('409 DEVICE_MISMATCH → выход с причиной deviceMismatch', () async {
      final h = SessionHarness((o) async => json(409, problem('DEVICE_MISMATCH', 409)));
      addTearDown(h.dispose);
      await h.start().establish(accessToken: fakeJwt(), refreshToken: 'r1');
      await fails(h.dio.get<Object?>('/me'));
      await until(() => h.state.endReason != null);
      expect(h.state.endReason, SessionEndReason.deviceMismatch);
      expect(SessionEndReason.fromServer('SESSION_REVOKED', 'admin'), SessionEndReason.admin);
      expect(SessionEndReason.fromServer('SESSION_REVOKED', 'session_limit'), SessionEndReason.otherDevice);
      expect(SessionEndReason.fromServer('SESSION_REVOKED', 'expired'), SessionEndReason.expired);
      expect(SessionEndReason.fromServer('SESSION_REVOKED', null), SessionEndReason.revoked);
    });
  });

  group('step-up (T-SESS-016, 08 §2.12)', () {
    const op = 'payment.qr.confirm_manual';

    test('403 STEP_UP_REQUIRED → StepUpDialog → повтор с X-Step-Up-Token и тем же Idempotency-Key; '
        'в пределах 15 мин токен области переиспользуется без диалога', () async {
      final h = SessionHarness((o) async {
        final token = o.headers[ApiHeaders.stepUpToken];
        return token == 'su-1' ? json(200, {'ok': true}) : json(403, stepUpRequired(op));
      });
      addTearDown(h.dispose);
      await h.start().establish(accessToken: fakeJwt(), refreshToken: 'r1');
      final challenges = <StepUpChallenge>[];
      h.container.read(stepUpCoordinatorProvider).attach((c) async {
        challenges.add(c);
        return StepUpGrant(
          token: 'su-1',
          operation: c.operation,
          expiresAt: h.clock.nowUtc().add(const Duration(minutes: 15)),
          method: 'pin',
          scope: [op],
        );
      });

      final first = await h.dio.post<Object?>(
        '/payments/p1/confirm-manual',
        options: apiOptions(idempotencyKey: 'idem-1'),
      );
      expect(first.statusCode, 200);
      expect(challenges.single.operation, op);
      expect(challenges.single.allowedMethods, ['pin', 'otp']);
      final sent = h.adapter.requests.where((r) => r.path == '/payments/p1/confirm-manual').toList();
      expect(sent, hasLength(2));
      expect(sent[1].headers[ApiHeaders.stepUpToken], 'su-1');
      expect(sent[0].headers[ApiHeaders.idempotencyKey], 'idem-1');
      expect(sent[1].headers[ApiHeaders.idempotencyKey], 'idem-1');

      // Вторая операция той же области через 10 мин: 403 → токен из кэша, диалога нет.
      h.clock.advance(const Duration(minutes: 10));
      await h.dio.post<Object?>('/payments/p2/confirm-manual', options: apiOptions(idempotencyKey: 'idem-2'));
      expect(challenges, hasLength(1));

      // Операция с известной заранее областью — токен подставляется в первый же запрос (без 403).
      final options = apiOptions(idempotencyKey: 'idem-3');
      options.extra![SessionRequestExtra.stepUpOperation] = op;
      final before = h.adapter.requests.length;
      await h.dio.post<Object?>('/payments/p3/confirm-manual', options: options);
      expect(h.adapter.requests.length - before, 1);
      expect(h.adapter.requests.last.headers[ApiHeaders.stepUpToken], 'su-1');

      // Через 16 мин токен истёк → снова диалог.
      h.clock.advance(const Duration(minutes: 6));
      await h.dio.post<Object?>('/payments/p4/confirm-manual', options: apiOptions(idempotencyKey: 'idem-4'));
      expect(challenges, hasLength(2));
    });

    test('параллельные запросы одной операции → один диалог', () async {
      final h = SessionHarness((o) async {
        return o.headers[ApiHeaders.stepUpToken] == 'su-1' ? json(200, {}) : json(403, stepUpRequired(op));
      });
      addTearDown(h.dispose);
      await h.start().establish(accessToken: fakeJwt(), refreshToken: 'r1');
      var shown = 0;
      final gate = Completer<void>();
      h.container.read(stepUpCoordinatorProvider).attach((c) async {
        shown++;
        await gate.future;
        return StepUpGrant(
          token: 'su-1',
          operation: op,
          expiresAt: h.clock.nowUtc().add(const Duration(minutes: 15)),
          method: 'otp',
        );
      });
      final calls = [
        for (var i = 0; i < 3; i++)
          h.dio.post<Object?>('/payments/x$i/void', options: apiOptions(idempotencyKey: 'k$i')),
      ];
      await settle();
      gate.complete();
      final results = await Future.wait(calls);
      expect(results.map((r) => r.statusCode), everyElement(200));
      expect(shown, 1);
    });

    test('«Отмена» в StepUpDialog → исходная ошибка 403, без повтора', () async {
      final h = SessionHarness((o) async => json(403, stepUpRequired('session.logout_all')));
      addTearDown(h.dispose);
      final c = h.start();
      await c.establish(accessToken: fakeJwt(), refreshToken: 'r1');
      h.container.read(stepUpCoordinatorProvider).attach((_) async => null);
      final error = await c.logoutAll();
      expect(error, isA<StepUpDeclinedError>());
      expect(h.adapter.countPath('/auth/logout-all'), 1);
      expect(h.state.status, SessionStatus.authenticated);
      expect(h.storage.values[SecureKey.refreshToken], 'r1');
    });

    test('сервер отверг токен из кэша → он удаляется, диалог один раз; цикла нет', () async {
      var dialogs = 0;
      final h = SessionHarness((o) async => json(403, stepUpRequired(op)));
      addTearDown(h.dispose);
      await h.start().establish(accessToken: fakeJwt(), refreshToken: 'r1');
      final coordinator = h.container.read(stepUpCoordinatorProvider);
      coordinator.cache.put(
        StepUpGrant(
          token: 'stale',
          operation: op,
          expiresAt: h.clock.nowUtc().add(const Duration(minutes: 5)),
          method: 'pin',
        ),
      );
      coordinator.attach((c) async {
        dialogs++;
        return StepUpGrant(
          token: 'su-$dialogs', // check-secrets: allow (тест)
          operation: op,
          expiresAt: h.clock.nowUtc().add(const Duration(minutes: 15)),
          method: 'pin',
        );
      });
      final options = apiOptions(idempotencyKey: 'k');
      options.extra![SessionRequestExtra.stepUpOperation] = op;
      final e = await fails(h.dio.post<Object?>('/payments/p1/void', options: options));
      expect(e.response?.statusCode, 403);
      expect(dialogs, 1);
      expect(h.adapter.countPath('/payments/p1/void'), 2); // stale → (диалог) su-1 → отказ, дальше не повторяем
      expect(coordinator.tokenFor(op), isNull);
    });

    test('logout-all: step-up и затем полный локальный выход', () async {
      final h = SessionHarness((o) async {
        if (o.headers[ApiHeaders.stepUpToken] == 'su-1') return json(204, null);
        return json(403, stepUpRequired('session.logout_all'));
      });
      addTearDown(h.dispose);
      final c = h.start();
      await c.establish(accessToken: fakeJwt(), refreshToken: 'r1');
      h.container
          .read(stepUpCoordinatorProvider)
          .attach(
            (ch) async => StepUpGrant(
              token: 'su-1',
              operation: ch.operation,
              expiresAt: h.clock.nowUtc().add(const Duration(minutes: 15)),
              method: 'pin',
            ),
          );
      expect(await c.logoutAll(), isNull);
      expect(h.state.endReason, SessionEndReason.logoutAll);
      expect(h.state.showSessionEnded, isFalse);
      expect(h.storage.values.keys, [SecureKey.deviceId]);
      expect(h.container.read(stepUpCoordinatorProvider).cache.length, 0);
    });
  });

  group('разблокировка (UNLOCK_REQUIRED, /auth/unlock — T-SESS-020, AC-UI-08-004)', () {
    test('401 UNLOCK_REQUIRED → SCR-08 overlay, запрос ждёт; PIN → /auth/unlock → повтор запроса', () async {
      final unlocked = fakeJwt(tag: 'unlocked');
      final h = SessionHarness((o) async {
        if (o.path.endsWith('/auth/unlock')) return json(200, tokenPair(unlocked, 'r2'));
        if (o.headers[ApiHeaders.authorization] == 'Bearer $unlocked') return json(200, {'ok': true});
        return json(401, problem('UNLOCK_REQUIRED', 401));
      });
      addTearDown(h.dispose);
      final c = h.start();
      await c.establish(accessToken: fakeJwt(), refreshToken: 'r1');
      final pending = h.dio.get<Object?>('/cart');
      await until(() => h.state.lock != null);
      expect(h.state.lock, SessionLockReason.unlockRequired);
      expect(h.tokens.accessToken, isNull);
      expect(h.container.read(sessionOverlayProvider).kind, SessionOverlayKind.locked);

      // Пока заблокировано, новые запросы не уходят в сеть.
      final queued = h.dio.get<Object?>('/catalog');
      await settle();
      expect(h.adapter.countPath('/catalog'), 0);

      final outcome = await c.unlockWithPin('482913');
      expect(outcome, isA<UnlockSucceeded>());
      expect((await pending).statusCode, 200);
      expect((await queued).statusCode, 200);
      final unlock = h.adapter.requests.singleWhere((r) => r.path == '/auth/unlock');
      expect(unlock.data, {'method': 'pin', 'refreshToken': 'r1', 'pin': '482913'});
      expect(unlock.headers.containsKey(ApiHeaders.authorization), isFalse);
      expect(unlock.headers[ApiHeaders.deviceId], testDeviceId);
      expect(h.adapter.countPath('/auth/refresh'), 0);
      expect(h.state.isLocked, isFalse);
      expect(h.storage.values[SecureKey.refreshToken], 'r2');
    });

    test('PIN_INVALID → attemptsLeft из ответа, /auth/refresh не вызывается; PIN_LOCKED → только SMS', () async {
      var attempt = 0;
      final h = SessionHarness((o) async {
        if (o.path.endsWith('/auth/unlock')) {
          attempt++;
          return attempt < 2
              ? json(401, problem('PIN_INVALID', 401, extra: {'attemptsLeft': 2}))
              : json(423, problem('PIN_LOCKED', 423));
        }
        return json(200, {});
      }, refresh: 'r1');
      addTearDown(h.dispose);
      final c = h.start();
      await c.restore();
      expect(h.state.lock, SessionLockReason.coldStart);
      final first = await c.unlockWithPin('111111');
      expect(first, isA<UnlockRejected>());
      expect(((first as UnlockRejected).error as PinInvalidError).attemptsLeft, 2);
      final second = await c.unlockWithPin('222222');
      expect((second as UnlockRejected).error, isA<PinLockedError>());
      expect(h.adapter.countPath('/auth/refresh'), 0);
      expect(h.state.isLocked, isTrue);
      expect(h.storage.values[SecureKey.refreshToken], 'r1');

      c.leaveToPhoneLogin(reason: SessionEndReason.pinLocked);
      expect(h.state.status, SessionStatus.unauthenticated);
      expect(h.state.endReason, SessionEndReason.pinLocked);
      expect(h.state.showSessionEnded, isFalse);
      // Токены остаются до успешного входа (09 §9.3).
      expect(h.storage.values[SecureKey.refreshToken], 'r1');
    });

    test('unlock → 401 SESSION_REVOKED → выход (SCR-90 C)', () async {
      final h = SessionHarness(
        (o) async => json(401, problem('SESSION_REVOKED', 401, extra: {'reason': 'admin'})),
        refresh: 'r1',
      );
      addTearDown(h.dispose);
      final c = h.start();
      await c.restore();
      final outcome = await c.unlockWithPin('482913');
      expect((outcome as UnlockRejected).error, isA<SessionRevokedError>());
      expect(h.state.endReason, SessionEndReason.admin);
      expect(h.storage.values.keys, [SecureKey.deviceId]);
    });

    test('refresh → 401 UNLOCK_REQUIRED (Windows, D-48) → блокировка → разблокировка → повтор', () async {
      final unlocked = fakeJwt(tag: 'u');
      final h = SessionHarness((o) async {
        if (o.path.endsWith('/auth/refresh')) return json(401, problem('UNLOCK_REQUIRED', 401));
        if (o.path.endsWith('/auth/unlock')) return json(200, tokenPair(unlocked, 'r2'));
        return o.headers[ApiHeaders.authorization] == 'Bearer $unlocked'
            ? json(200, {'ok': true})
            : json(401, problem('TOKEN_STALE', 401));
      });
      addTearDown(h.dispose);
      final c = h.start();
      await c.establish(accessToken: fakeJwt(), refreshToken: 'r1');
      final pending = h.dio.get<Object?>('/me');
      await until(() => h.state.lock != null);
      expect(h.state.lock, SessionLockReason.unlockRequired);
      await c.unlockWithPin('482913');
      expect((await pending).statusCode, 200);
      expect(h.adapter.countPath('/auth/refresh'), 1);
    });

    test('сеть при разблокировке → NetworkCallError, PIN не сохраняется, сессия заблокирована', () async {
      final h = SessionHarness((o) async => transportError(o, DioExceptionType.connectionError), refresh: 'r1');
      addTearDown(h.dispose);
      final c = h.start();
      await c.restore();
      final outcome = await c.unlockWithPin('482913');
      expect((outcome as UnlockRejected).error, isA<NetworkCallError>());
      expect(h.state.isLocked, isTrue);
      expect(h.storage.values.values, isNot(contains('482913')));
    });
  });

  group('426 APP_UPDATE_REQUIRED (SCR-90 C3)', () {
    test('426 → «Требуется обновление», refresh не вызывается, сессия не завершается', () async {
      final h = SessionHarness(
        (o) async => json(
          426,
          problem('APP_UPDATE_REQUIRED', 426, extra: {'minVersion': 'android=1.5.0'}),
          headers: {ApiHeaders.minAppVersion: 'android=1.5.0'},
        ),
      );
      addTearDown(h.dispose);
      await h.start().establish(accessToken: fakeJwt(), refreshToken: 'r1');
      final e = await fails(h.dio.get<Object?>('/catalog'));
      expect(e.response?.statusCode, 426);
      expect(h.appVersionController.value.status, AppVersionStatus.updateRequired);
      final overlay = h.container.read(sessionOverlayProvider);
      expect(overlay.kind, SessionOverlayKind.updateRequired);
      expect(overlay.minVersion, '1.5.0');
      expect(h.adapter.countPath('/auth/refresh'), 0);
      expect(h.state.status, SessionStatus.authenticated);
      expect(h.storage.values[SecureKey.refreshToken], 'r1');
    });
  });

  group('выход (T-SESS-013, 07 §11.4, 09 §8.6)', () {
    test('logout: POST /auth/logout, секреты удалены (кроме deviceId), черновики пользователя очищены, '
        'корзина и outbox владельца сохранены', () async {
      final h = SessionHarness((o) async => json(204, null), withDatabase: true);
      addTearDown(h.dispose);
      final c = h.start();
      await c.establish(accessToken: fakeJwt(), refreshToken: 'r1');
      await h.storage.write(SecureKey.biometricsEnabled, 'true');
      await h.storage.write(SecureKey.registrationBirthYear, '1990');
      final db = h.db!;
      await _seed(db);
      final pending = await c.pendingLocalChanges();
      expect(pending.cartItems, 1);
      expect(pending.outboxActions, 1);
      expect(pending.submittedCheckout, isTrue);

      await c.logout();
      expect(h.adapter.requests.single.path, '/auth/logout');
      expect(h.adapter.requests.single.headers[ApiHeaders.authorization], startsWith('Bearer '));
      expect(h.storage.values.keys, [SecureKey.deviceId]);
      expect(h.tokens.accessToken, isNull);
      expect(h.state.status, SessionStatus.unauthenticated);
      expect(h.state.endReason, SessionEndReason.logout);
      expect(h.state.showSessionEnded, isFalse);

      expect(await db.select(db.cartDraft).get(), hasLength(1));
      expect((await db.select(db.cartDraft).getSingle()).ownerUserId, staffUserId);
      expect(await db.select(db.cartItemsDraft).get(), hasLength(1));
      expect((await db.select(db.outboxActions).get()).map((r) => r.ownerUserId), [staffUserId]);
      expect(await db.select(db.notificationsCache).get(), isEmpty);
      expect(await db.select(db.checkoutDraft).get(), isEmpty);
      expect(await db.select(db.registrationDraft).get(), isEmpty);
      expect((await db.select(db.localSettings).get()).map((r) => r.scope), ['device']);
    });

    test('ревью D-MN-04 (T-BIO-012): logout, logout-all и SESSION_REVOKED удаляют biometric_refresh и ключ '
        '(BiometricAuthenticator.clear)', () async {
      Future<int> clearsAfter(FakeHandler handler, Future<void> Function(SessionHarness h) act) async {
        final bio = _RecordingBiometrics();
        final h = SessionHarness(handler, biometrics: bio);
        addTearDown(h.dispose);
        await h.start().establish(accessToken: fakeJwt(), refreshToken: 'r1');
        expect(bio.clears, 0);
        await act(h);
        await until(() => h.state.status == SessionStatus.unauthenticated);
        await settle();
        return bio.clears;
      }

      expect(await clearsAfter((o) async => json(204, null), (h) => h.controller.logout()), 1);
      expect(
        await clearsAfter(
          (o) async => json(401, problem('SESSION_REVOKED', 401, extra: {'reason': 'reuse_detected'})),
          (h) async => fails(h.dio.get<Object?>('/orders')),
        ),
        1,
      );
      expect(await clearsAfter((o) async => json(204, null), (h) async => h.controller.logoutAll()), 1);
    });

    test('вход другого сотрудника после «Войти по номеру телефона»: данные прежнего очищены до закрытия файла '
        '(07 §11.4), корзина и outbox прежнего владельца сохранены', () async {
      final h = SessionHarness((o) async => json(204, null), withDatabase: true);
      addTearDown(h.dispose);
      final c = h.start();
      await c.establish(accessToken: fakeJwt(), refreshToken: 'r1');
      final db = h.db!;
      await _seed(db);
      c.leaveToPhoneLogin();
      expect(h.state.userId, staffUserId, reason: 'файл прежнего пользователя ещё открыт');

      await c.establish(
        accessToken: fakeJwt(sub: otherUserId, tag: 'b'),
        refreshToken: 'r2',
      );

      expect(h.state.userId, otherUserId);
      expect(await db.select(db.notificationsCache).get(), isEmpty);
      expect(await db.select(db.checkoutDraft).get(), isEmpty);
      expect(await db.select(db.registrationDraft).get(), isEmpty);
      expect((await db.select(db.localSettings).get()).map((r) => r.scope), ['device']);
      expect(
        (await db.select(db.cartDraft).get()).map((r) => r.ownerUserId),
        [staffUserId],
        reason: 'черновик корзины прежнего владельца уйдёт при его следующем входе',
      );
      expect((await db.select(db.outboxActions).get()).map((r) => r.ownerUserId), [staffUserId]);
    });

    test('повторный вход того же пользователя: локальные данные не очищаются', () async {
      final h = SessionHarness((o) async => json(204, null), withDatabase: true);
      addTearDown(h.dispose);
      final c = h.start();
      await c.establish(accessToken: fakeJwt(), refreshToken: 'r1');
      final db = h.db!;
      await _seed(db);
      c.leaveToPhoneLogin();
      await c.establish(
        accessToken: fakeJwt(tag: 'b'),
        refreshToken: 'r2',
      );
      expect(await db.select(db.notificationsCache).get(), hasLength(1));
      expect(await db.select(db.checkoutDraft).get(), hasLength(1));
    });

    test('logout офлайн → локальный выход всё равно выполняется', () async {
      final h = SessionHarness((o) async => transportError(o, DioExceptionType.connectionError));
      addTearDown(h.dispose);
      final c = h.start();
      await c.establish(accessToken: fakeJwt(), refreshToken: 'r1');
      await c.logout();
      expect(h.state.status, SessionStatus.unauthenticated);
      // RC-1/SS-07: сессионных ключей нет; для отложенного отзыва — только запись `pending_logout`
      // (подробно — pending_logout_test.dart).
      expect(h.storage.values.keys, unorderedEquals([SecureKey.deviceId, SecureKey.pendingLogout]));
      expect(h.state.serverLogoutPending, isTrue);
    });

    test('«Сменить аккаунт» с экрана блокировки: logout не ждёт разблокировки', () async {
      final h = SessionHarness((o) async {
        if (o.path.endsWith('/auth/refresh')) return json(401, problem('UNLOCK_REQUIRED', 401));
        return json(401, problem('UNAUTHENTICATED', 401));
      }, refresh: 'r1');
      addTearDown(h.dispose);
      final c = h.start();
      await c.restore();
      expect(h.state.isLocked, isTrue);
      await c.logout().timeout(const Duration(seconds: 2));
      expect(h.state.status, SessionStatus.unauthenticated);
      expect(h.storage.values.keys, [SecureKey.deviceId]);
    });
  });
}

Future<void> _seed(AppDatabase db) async {
  const now = 1761123600000;
  for (final owner in [staffUserId, otherUserId]) {
    await db
        .into(db.cartDraft)
        .insert(
          CartDraftCompanion.insert(localId: 'cart-$owner', status: 'active', ownerUserId: owner, updatedAt: now),
        );
    await db
        .into(db.cartItemsDraft)
        .insert(
          CartItemsDraftCompanion.insert(
            localItemId: 'item-$owner',
            localCartId: 'cart-$owner',
            variantId: 'v1',
            quantityMilli: 1000,
            lineNo: 1,
            ownerUserId: owner,
          ),
        );
    await db
        .into(db.outboxActions)
        .insert(
          OutboxActionsCompanion.insert(
            type: 'cart.sync',
            payloadJson: '{}',
            idempotencyKey: 'idem-$owner',
            ownerUserId: owner,
            createdAt: now,
          ),
        );
  }
  await db
      .into(db.notificationsCache)
      .insert(
        NotificationsCacheCompanion.insert(id: 'n1', kind: 'system', severity: 'info', title: 't', createdAt: now),
      );
  await db
      .into(db.checkoutDraft)
      .insert(
        CheckoutDraftCompanion.insert(
          localCartId: 'cart-1',
          step: 'payment',
          updatedAt: now,
          submittedAt: const Value(now),
        ),
      );
  await db.into(db.registrationDraft).insert(RegistrationDraftCompanion.insert(key: 'step', valueJson: '"phone"'));
  await db
      .into(db.localSettings)
      .insert(LocalSettingsCompanion.insert(key: 'theme', valueJson: '"light"', scope: 'user', updatedAt: now));
  await db
      .into(db.localSettings)
      .insert(LocalSettingsCompanion.insert(key: 'printer', valueJson: '"p1"', scope: 'device', updatedAt: now));
}

/// Фейк порта биометрии: считает вызовы `clear` (удаление ключа и `biometric_refresh`).
final class _RecordingBiometrics implements BiometricAuthenticator {
  int clears = 0;

  @override
  Future<void> clear() async => clears++;

  @override
  Future<BiometricCapability> capability() async => BiometricCapability.none;

  @override
  Future<bool> hasStoredSecret() async => clears == 0;

  @override
  Future<BiometricResult<String>> read(BiometricPromptText prompt) async =>
      const BiometricResult<String>.failure(BiometricError.noCredential);

  @override
  Future<BiometricResult<void>> store(String secret, BiometricPromptText prompt) async =>
      const BiometricResult<void>.success(null);

  @override
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) async =>
      const BiometricResult<void>.failure(BiometricError.notAvailable);
}
