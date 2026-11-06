// Сессия планшета магазина (13 TAB-2-10; P-002 §8.2 п. 5–8, §15; 09 §8.9; ADR-115 п. 12; navigation.md §4.3, §7.2):
// признак планшета вне ключей сессии, холодный старт по признаку без SCR-08 и без сети, «Планшет нужно подключить
// заново» после `401 SESSION_REVOKED` (закрепление остаётся), `401 KIOSK_REVOKED` — «Планшет отключён
// администратором» → закрепление снято, признак и токены удалены → SCR-01; блокировка, idle и `Ctrl+L` к планшету не
// применяются; паритет — сотрудник как прежде.
// Трассировка: 12 T-KIOSK-003, T-KIOSK-049; 10 KIOSK-004, KIOSK-031; 02 AC-UI-51-011, AC-UI-51-012, AC-UI-90-020.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations_ru.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/interceptors/auth_interceptor.dart';
import 'package:optomstroy/core/session/kiosk_marker.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_overlay.dart';
import 'package:optomstroy/core/session/session_policy.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_shell_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_state_view.dart';
import 'package:optomstroy/features/session_ui/presentation/session_gate.dart';

import '../../features/kiosk/kiosk_lifecycle_support.dart';
import '../../features/session_ui/session_ui_support.dart' show gatedApp;

final AppLocalizationsRu _l10n = AppLocalizationsRu();

/// Сервер: `/auth/refresh` → новая пара планшета; остальные запросы — [other] (по умолчанию 200).
FakeHandler _server({ResponseBody Function(RequestOptions o)? other, ResponseBody Function()? refresh}) =>
    (RequestOptions o) async {
      if (o.path.endsWith('/auth/refresh')) return refresh?.call() ?? json(200, tokenPair(kioskJwt(tag: 'r'), 'rk2'));
      return other?.call(o) ?? json(200, <String, Object?>{'ok': true});
    };

void main() {
  group('восстановление по признаку планшета (холодный старт)', () {
    test(
      'признак + refresh → сессия kind=kiosk без блокировки холодного старта, пользователь из признака, без сети',
      () async {
        final FakeKioskLock lock = FakeKioskLock();
        final SessionHarness h = kioskHarness(_server(), lock: lock);
        addTearDown(h.dispose);
        h.start();
        expect(await h.container.read(sessionStatusProvider.future), SessionStatus.authenticated);
        expect(h.state.lock, isNull, reason: 'PIN у планшета нет: SCR-08 cold не применяется');
        expect(h.state.userKind, UserKind.kiosk);
        expect(h.state.userId, kioskUserId, reason: 'БД pos_<user>.db с кэшем каталога открывается и офлайн');
        expect(h.state.kioskTabletId, kioskTabletId);
        expect(h.state.isKioskSession, isTrue);
        expect(h.container.read(sessionOverlayProvider), SessionOverlay.none);
        expect(h.container.read(kioskModeProvider), isTrue);
        expect(h.container.read(kioskRouteHoldProvider), isFalse);
        // Восстановление не ходит в сеть (холодный старт без связи).
        expect(h.adapter.requests, isEmpty);
      },
    );

    test('признак без refresh → «Планшет нужно подключить заново» (G-0a), без диалога SCR-90 C', () async {
      final SessionHarness h = kioskHarness(_server(), lock: FakeKioskLock(), refresh: null);
      addTearDown(h.dispose);
      h.start();
      expect(await h.container.read(sessionStatusProvider.future), SessionStatus.unauthenticated);
      expect(h.state.kioskReconnectNeeded, isTrue);
      expect(h.state.holdsKioskRoute, isTrue);
      expect(h.state.showSessionEnded, isFalse);
      expect(h.state.userKind, UserKind.kiosk);
      expect(h.container.read(kioskStatusProvider), KioskStatus.reconnectNeeded);
      expect(h.container.read(sessionOverlayProvider), SessionOverlay.none);
    });

    test('без признака — прежнее поведение: refresh → SCR-08 cold (паритет)', () async {
      final SessionHarness h = kioskHarness(_server(), lock: FakeKioskLock(), marked: false);
      addTearDown(h.dispose);
      h.start();
      expect(await h.container.read(sessionStatusProvider.future), SessionStatus.authenticated);
      expect(h.state.lock, SessionLockReason.coldStart);
      expect(h.state.kioskTabletId, isNull);
      expect(h.container.read(kioskModeProvider), isFalse);
    });

    test('признак — ключи вне SecureKey.session; TokenStore.clearSession их не удаляет', () async {
      expect(SecureKey.kiosk.toSet().intersection(SecureKey.session.toSet()), isEmpty);
      expect(SecureKey.kiosk.map((SecureKey k) => k.storageKey), <String>[
        'kiosk.tablet_id',
        'kiosk.tablet_name',
        'kiosk.user_id',
        'kiosk.warehouse_id',
        'kiosk.exit_hash',
        'kiosk.exit_salt',
        'kiosk.exit_attempts',
        'kiosk.exit_locked_until',
      ]);
      final SessionHarness h = kioskHarness(_server(), lock: FakeKioskLock());
      addTearDown(h.dispose);
      await h.tokens.clearSession();
      expect(h.storage.values[SecureKey.refreshToken], isNull);
      expect(h.storage.values[SecureKey.kioskTabletId], kioskTabletId);
      expect(h.storage.values[SecureKey.kioskUserId], kioskUserId);
      expect(
        await h.container.read(kioskMarkerStoreProvider).read(),
        const KioskMarker(tabletId: kioskTabletId, tabletName: kioskTabletName, userId: kioskUserId),
      );
    });
  });

  group('склад планшета для кэша каталога (02 SCR-51.9; 10 KIOSK-007)', () {
    test('признак со складом — запись и чтение; без склада ключа нет; очистка удаляет склад', () async {
      final SessionHarness h = kioskHarness(_server(), lock: FakeKioskLock(), marked: false);
      addTearDown(h.dispose);
      final KioskMarkerStore store = h.container.read(kioskMarkerStoreProvider);
      const KioskMarker marker = KioskMarker(
        tabletId: kioskTabletId,
        tabletName: kioskTabletName,
        userId: kioskUserId,
        warehouseId: 'w-tablet',
      );
      await store.write(marker);
      expect(h.storage.values[SecureKey.kioskWarehouseId], 'w-tablet');
      expect(await store.read(), marker);
      expect(marker.withWarehouse('w-3').warehouseId, 'w-3');
      expect(marker.withWarehouse('w-3') == marker, isFalse);
      await store.write(marker.withWarehouse(null));
      expect(h.storage.values.containsKey(SecureKey.kioskWarehouseId), isFalse);
      await store.write(marker);
      await store.clear();
      expect(h.storage.values.containsKey(SecureKey.kioskWarehouseId), isFalse, reason: 'входит в SecureKey.kiosk');
    });

    test('холодный старт: склад — из признака без сети; первый успешный запрос по складу (каталог) — GET /me обновляет '
        'склад и признак; heartbeat GET /settings/public — нет; вне режима планшета склада нет', () async {
      final SessionHarness h = kioskHarness(
        _server(
          other: (RequestOptions o) => o.path.endsWith('/me')
              ? json(200, <String, Object?>{
                  'id': kioskUserId,
                  'kind': 'kiosk',
                  'tablet': <String, Object?>{'id': kioskTabletId, 'name': kioskTabletName, 'warehouseId': 'w-new'},
                })
              : json(200, <String, Object?>{'ok': true}),
        ),
        lock: FakeKioskLock(),
      );
      addTearDown(h.dispose);
      h.storage.values[SecureKey.kioskWarehouseId] = 'w-old';
      h.start();
      await h.container.read(sessionStatusProvider.future);
      expect(h.adapter.requests, isEmpty, reason: 'восстановление в сеть не ходит');
      expect(h.container.read(kioskLocalWarehouseIdProvider), 'w-old');

      await h.dio.get<Object?>('/settings/public');
      await settle();
      expect(h.adapter.countPath('/me'), 0, reason: 'heartbeat GET /me не вызывает');
      await h.dio.get<Object?>('/catalog/categories');
      await settle();
      expect(h.adapter.countPath('/me'), 1);
      expect(h.container.read(kioskLocalWarehouseIdProvider), 'w-new', reason: 'SCR-54 сменил склад планшета');
      expect(h.storage.values[SecureKey.kioskWarehouseId], 'w-new');
      await h.container.read(sessionControllerProvider.notifier).refreshKioskTablet();
      expect(h.adapter.countPath('/me'), 1, reason: 'склад подтверждён — второго запроса нет');

      final SessionHarness staff = SessionHarness(_server());
      addTearDown(staff.dispose);
      await staff.start().establish(accessToken: fakeJwt(), refreshToken: 'r1');
      expect(staff.container.read(kioskLocalWarehouseIdProvider), isNull, reason: 'сотрудник читает кэш как прежде');
    });

    test('подключение (establishKiosk): склад планшета из ответа подключения — в признак, GET /me не нужен', () async {
      final SessionHarness h = kioskHarness(_server(), lock: FakeKioskLock(), marked: false, refresh: null);
      addTearDown(h.dispose);
      final c = h.start();
      await c.establishKiosk(
        tabletId: kioskTabletId,
        tabletName: kioskTabletName,
        warehouseId: 'w-tablet',
        exitCode: kioskExitCode,
        accessToken: kioskJwt(),
        refreshToken: 'rk1',
      );
      expect(h.storage.values[SecureKey.kioskWarehouseId], 'w-tablet');
      expect(h.container.read(kioskLocalWarehouseIdProvider), 'w-tablet');
      await c.refreshKioskTablet();
      expect(h.adapter.countPath('/me'), 0);
    });
  });

  group('подключение на устройстве (establishKiosk)', () {
    test(
      'признак и хэш аварийного кода — в защищённое хранилище, кода в открытом виде нет; idle не запускается',
      () async {
        final FakeKioskLock lock = FakeKioskLock(locked: true);
        final SessionHarness h = kioskHarness(_server(), lock: lock, marked: false, refresh: null);
        addTearDown(h.dispose);
        final c = h.start();
        final String access = kioskJwt();
        await c.establishKiosk(
          tabletId: kioskTabletId,
          tabletName: kioskTabletName,
          exitCode: kioskExitCode,
          accessToken: access,
          refreshToken: 'rk1',
        );
        expect(h.state.isKioskSession, isTrue);
        expect(h.state.kioskTabletId, kioskTabletId);
        expect(h.state.userId, kioskUserId);
        expect(h.storage.values[SecureKey.kioskTabletId], kioskTabletId);
        expect(h.storage.values[SecureKey.kioskUserId], kioskUserId);
        expect(h.storage.values[SecureKey.kioskExitHash], startsWith('pbkdf2-sha256\$$testExitIterations\$'));
        expect(h.storage.values[SecureKey.kioskExitSalt], isNotNull);
        expect(h.storage.values.values.where((String v) => v.contains(kioskExitCode)), isEmpty);
        expect(h.storage.values.values, isNot(contains(access)), reason: 'access — только в памяти');
        await settle();
        // X-Kiosk-Lock — по снимку KioskLock.status после подключения.
        await h.dio.get<Object?>('/cart');
        expect(h.adapter.requests.last.headers[ApiHeaders.kioskLock], 'on');
      },
    );

    test('access не планшета → ArgumentError, ничего не пишется', () async {
      final SessionHarness h = kioskHarness(_server(), lock: FakeKioskLock(), marked: false, refresh: null);
      addTearDown(h.dispose);
      final c = h.start();
      await expectLater(
        c.establishKiosk(tabletId: kioskTabletId, exitCode: kioskExitCode, accessToken: fakeJwt(), refreshToken: 'r'),
        throwsArgumentError,
      );
      expect(h.storage.values[SecureKey.kioskTabletId], isNull);
      expect(h.storage.values[SecureKey.kioskExitHash], isNull);
    });
  });

  group('блокировки у планшета нет (PIN нет)', () {
    test('lock(), idle и UNLOCK_REQUIRED не блокируют планшет; сотрудник — как прежде', () async {
      const SessionPolicy fast = SessionPolicy(idleLock: Duration(milliseconds: 30));
      final SessionHarness h = SessionHarness(
        _server(),
        refresh: 'rk1',
        policy: fast,
        overrides: kioskOverrides(FakeKioskLock()),
      );
      writeKioskMarker(h.storage.values);
      addTearDown(h.dispose);
      final c = h.start();
      await h.container.read(sessionStatusProvider.future);
      await c.establishKiosk(
        tabletId: kioskTabletId,
        exitCode: kioskExitCode,
        accessToken: kioskJwt(),
        refreshToken: 'rk1',
      );
      for (final SessionLockReason reason in SessionLockReason.values) {
        c.lock(reason);
        expect(h.state.lock, isNull, reason: reason.name);
      }
      expect(await c.unlockRequired(), isTrue, reason: 'ожидания разблокировки нет');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(h.state.lock, isNull, reason: 'idle-блокировка не идёт');

      final SessionHarness staff = SessionHarness(_server(), policy: fast);
      addTearDown(staff.dispose);
      final s = staff.start();
      await s.establish(accessToken: fakeJwt(), refreshToken: 'r1');
      s.lock(SessionLockReason.manual);
      expect(staff.state.lock, SessionLockReason.manual, reason: 'паритет: сотрудник блокируется');
    });

    testWidgets('Ctrl+L на планшете не блокирует и клавишу не перехватывает', (WidgetTester tester) async {
      final SessionHarness h = kioskHarness(_server(), lock: FakeKioskLock());
      addTearDown(h.dispose);
      h.start();
      await tester.runAsync(() => h.container.read(sessionStatusProvider.future));
      await tester.pumpWidget(gatedApp(h.container, const Scaffold(body: Text('kiosk'))));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(h.state.lock, isNull);
      expect(find.byKey(SessionGate.scrimKey), findsNothing);
    });
  });

  group('T-KIOSK-049 «Подключите заново», lock stays', () {
    test(
      'T-KIOSK-049: 401 SESSION_REVOKED (срок вышел) → токены удалены, признак и закрепление остаются, G-0a',
      () async {
        final FakeKioskLock lock = FakeKioskLock(locked: true);
        final SessionHarness h = kioskHarness(
          _server(
            other: (RequestOptions o) =>
                json(401, problem('SESSION_REVOKED', 401, extra: <String, Object?>{'reason': 'expired'})),
          ),
          lock: lock,
        );
        addTearDown(h.dispose);
        final c = h.start();
        await h.container.read(sessionStatusProvider.future);
        await c.establishKiosk(
          tabletId: kioskTabletId,
          tabletName: kioskTabletName,
          exitCode: kioskExitCode,
          accessToken: kioskJwt(),
          refreshToken: 'rk1',
        );
        await fails(h.dio.get<Object?>('/cart'));
        await settle();
        expect(h.state.status, SessionStatus.unauthenticated);
        expect(h.state.kioskReconnectNeeded, isTrue);
        expect(h.state.endReason, SessionEndReason.expired);
        expect(h.state.showSessionEnded, isFalse, reason: 'диалога SCR-90 «Сессия завершена» у планшета нет');
        expect(h.container.read(sessionOverlayProvider), SessionOverlay.none);
        expect(h.container.read(kioskStatusProvider), KioskStatus.reconnectNeeded);
        expect(h.storage.values[SecureKey.refreshToken], isNull, reason: 'токены удалены');
        expect(h.storage.values[SecureKey.kioskTabletId], kioskTabletId, reason: 'признак остаётся');
        expect(h.storage.values[SecureKey.kioskExitHash], isNotNull, reason: 'аварийный код без связи остаётся');
        expect(lock.count('disable'), 0, reason: 'закрепление не снимается');
        expect(lock.locked, isTrue);

        // Перезапуск: то же состояние (G-0a), экрана входа нет.
        final SessionHarness restart = SessionHarness(_server(), overrides: kioskOverrides(lock));
        restart.storage.values
          ..clear()
          ..addAll(h.storage.values);
        addTearDown(restart.dispose);
        restart.start();
        expect(await restart.container.read(sessionStatusProvider.future), SessionStatus.unauthenticated);
        expect(restart.state.kioskReconnectNeeded, isTrue);
        expect(restart.container.read(kioskRouteHoldProvider), isTrue);
      },
    );

    testWidgets('T-KIOSK-049: SCR-51 «Планшет нужно подключить заново» — витрины нет, логотип с аварийным выходом', (
      WidgetTester tester,
    ) async {
      final SessionHarness h = kioskHarness(_server(), lock: FakeKioskLock(locked: true), refresh: null);
      addTearDown(h.dispose);
      h.start();
      await tester.runAsync(() => h.container.read(sessionStatusProvider.future));
      final GoRouter router = kioskGuardRouter(h.container, initialLocation: '/kiosk');
      addTearDown(router.dispose);
      await tester.pumpWidget(kioskTestApp(h.container, router));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/kiosk');
      expect(find.byKey(KioskStateView.fullScreenKey), findsOneWidget);
      expect(find.text(_l10n.kiosk_reconnect_needed), findsOneWidget);
      expect(find.byKey(KioskStateView.logoKey), findsOneWidget);
    });
  });

  group('T-KIOSK-003 revoked screen, lock off, marker removed, SCR-01', () {
    test('T-KIOSK-003: 401 KIOSK_REVOKED → без refresh; закрепление снято, признак, хэш и токены удалены', () async {
      final FakeKioskLock lock = FakeKioskLock(locked: true);
      final SessionHarness h = kioskHarness(
        _server(other: (RequestOptions o) => json(401, problem('KIOSK_REVOKED', 401))),
        lock: lock,
      );
      addTearDown(h.dispose);
      final c = h.start();
      await h.container.read(sessionStatusProvider.future);
      await c.establishKiosk(
        tabletId: kioskTabletId,
        exitCode: kioskExitCode,
        accessToken: kioskJwt(),
        refreshToken: 'rk1',
      );
      // Параллельные запросы — один конец режима.
      await Future.wait(<Future<Object?>>[
        fails(h.dio.get<Object?>('/cart')),
        fails(h.dio.get<Object?>('/catalog/products')),
      ]);
      await settle();
      expect(h.adapter.countPath('/auth/refresh'), 0, reason: 'refresh на KIOSK_REVOKED не вызывается');
      expect(lock.count('disable'), 1);
      expect(lock.locked, isFalse);
      for (final SecureKey key in <SecureKey>[...SecureKey.kiosk, SecureKey.refreshToken]) {
        expect(h.storage.values[key], isNull, reason: key.storageKey);
      }
      expect(h.storage.values[SecureKey.deviceId], testDeviceId, reason: 'deviceId сохраняется');
      expect(h.state.endReason, SessionEndReason.kioskRevoked);
      expect(h.state.kioskRevokedNotice, isTrue);
      expect(h.state.showSessionEnded, isFalse);
      expect(h.container.read(kioskStatusProvider), KioskStatus.revoked);
      expect(h.container.read(sessionOverlayProvider), SessionOverlay.none);
      // Ещё один поздний KIOSK_REVOKED, пока уведомление на экране, ничего не повторяет.
      c.sessionEnded(const SessionEndSignal(code: 'KIOSK_REVOKED'));
      await settle();
      expect(lock.count('disable'), 1);
      c.acknowledgeKioskRevoked();
      expect(h.state.holdsKioskRoute, isFalse);
      expect(h.state.userKind, isNull, reason: 'SCR-01 — не режим планшета');
      expect(h.container.read(kioskModeProvider), isFalse);
    });

    testWidgets('T-KIOSK-003: SCR-51 «Планшет отключён администратором» 5 с → SCR-01 без returnTo', (
      WidgetTester tester,
    ) async {
      final FakeKioskLock lock = FakeKioskLock(locked: true);
      final SessionHarness h = kioskHarness(
        _server(other: (RequestOptions o) => json(401, problem('KIOSK_REVOKED', 401))),
        lock: lock,
        access: kioskJwt(),
      );
      addTearDown(h.dispose);
      h.start();
      await tester.runAsync(() => h.container.read(sessionStatusProvider.future));
      final GoRouter router = kioskGuardRouter(h.container, initialLocation: '/kiosk');
      addTearDown(router.dispose);
      await tester.pumpWidget(kioskTestApp(h.container, router));
      await tester.pumpAndSettle();
      expect(find.byKey(KioskShellScreen.screenKey), findsOneWidget);
      expect(find.byKey(KioskStateView.fullScreenKey), findsNothing);

      await tester.runAsync(() async {
        await fails(h.dio.get<Object?>('/cart'));
        await settle();
      });
      await tester.pump();
      expect(router.state.uri.path, '/kiosk');
      expect(find.text(_l10n.kiosk_revoked), findsOneWidget);
      expect(lock.locked, isFalse);

      await tester.pump(const Duration(seconds: 4));
      expect(find.text(_l10n.kiosk_revoked), findsOneWidget, reason: 'ещё показывается');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/auth/phone');
      expect(router.state.uri.queryParameters.containsKey('returnTo'), isFalse);
      expect(find.byKey(pageKey('phone ')), findsOneWidget);
    });
  });

  group('паритет: сотрудник', () {
    test(
      'SESSION_REVOKED сотрудника — диалог SCR-90 C, как прежде; KIOSK_REVOKED не планшету — обычный выход',
      () async {
        final SessionHarness h = SessionHarness(
          (RequestOptions o) async =>
              json(401, problem('SESSION_REVOKED', 401, extra: <String, Object?>{'reason': 'admin'})),
          overrides: kioskOverrides(FakeKioskLock()),
        );
        addTearDown(h.dispose);
        final c = h.start();
        await c.establish(accessToken: fakeJwt(), refreshToken: 'r1');
        await fails(h.dio.get<Object?>('/me'));
        await settle();
        expect(h.state.showSessionEnded, isTrue);
        expect(h.state.endReason, SessionEndReason.admin);
        expect(h.container.read(kioskModeProvider), isFalse);

        final FakeKioskLock lock = FakeKioskLock();
        final SessionHarness other = SessionHarness(
          (RequestOptions o) async => json(401, problem('KIOSK_REVOKED', 401)),
          overrides: kioskOverrides(lock),
        );
        addTearDown(other.dispose);
        final s = other.start();
        await s.establish(accessToken: fakeJwt(), refreshToken: 'r1');
        await fails(other.dio.get<Object?>('/me'));
        await settle();
        expect(other.state.status, SessionStatus.unauthenticated);
        expect(other.state.endReason, SessionEndReason.revoked);
        expect(lock.count('disable'), 0);
      },
    );
  });
}
