// Guard G-0a (`visual/navigation.md` §4.1, §4.2; P-002 §8.2 п. 8, §9; ADR-115; 13 TAB-2-10): признак планшета на
// устройстве без сессии (срок сессии планшета вышел — `401 SESSION_REVOKED`; SCR-51 «Планшет отключён» ещё на экране) →
// любой путь, в том числе гостевые `/auth/*`, `/register*`, `/pending-activation`, `/kiosk/checkout`, `/kiosk/done`,
// → `/kiosk`; проверка — после G-0 и до G-1 (экрана входа нет). После `KIOSK_REVOKED` и аварийного выхода признака
// нет — G-1 без `returnTo` (выход без связи — с подсказкой SCR-01). Режимы сотрудника и `customer` не меняются.
// G-15 (сессия планшета) — kiosk_guard_test.dart. Трассировка: 12 T-KIOSK-045; 10 KIOSK-031; 02 AC-UI-51-011,
// AC-UI-51-018, SCR-51.6.
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/app_router.dart';
import 'package:optomstroy/app/router/guards/auth_guard.dart';
import 'package:optomstroy/app/router/kiosk_routes.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations_ru.dart';
import 'package:optomstroy/core/session/session_overlay.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/features/auth/domain/entities/auth_entry_reason.dart';
import 'package:optomstroy/features/auth/presentation/auth_messages.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_state_view.dart';

import '../../features/kiosk/kiosk_lifecycle_support.dart';

/// Пути, на которые планшет без сессии пытается уйти (гостевые — в первую очередь: их G-1 не ловит).
const List<String> _escapes = <String>[
  '/auth/phone',
  '/auth/phone?returnTo=%2Fcatalog',
  '/auth/otp',
  '/auth/unlock?mode=cold',
  '/register',
  '/register/security?mode=staff_first_login',
  '/register/customer-link',
  '/pending-activation',
  '/kiosk/checkout',
  '/kiosk/checkout?step=code',
  '/kiosk/done',
  '/orders',
  '/admin/users',
  '/me',
  '/cart/parked',
  '/catalog',
  '/catalog/p/p1',
  '/home',
];

String? _redirect(
  String location, {
  SessionStatus status = SessionStatus.unauthenticated,
  bool hold = true,
  AppMode mode = AppMode.kiosk,
  SessionEndReason? endReason,
}) => appRedirect(
  status: status,
  uri: Uri.parse(location),
  mode: mode,
  customerSelfService: true,
  endReason: endReason,
  kioskHold: hold,
);

void main() {
  group('T-KIOSK-045 G-0a before G-1', () {
    test('T-KIOSK-045: признак без сессии → любой путь, в том числе гостевой, → /kiosk', () {
      for (final AppMode mode in <AppMode>[AppMode.kiosk, AppMode.seller]) {
        for (final String path in _escapes) {
          expect(_redirect(path, mode: mode), KioskPaths.showcase, reason: '${mode.name}: $path');
        }
      }
    });

    test('T-KIOSK-045: на /kiosk — остаться (G-1 и следующие не проверяются); /splash ведёт SCR-00', () {
      expect(_redirect('/kiosk'), isNull);
      expect(_redirect('/kiosk?c=cat-1'), isNull);
      expect(_redirect('/splash'), isNull, reason: 'SCR-00 строка 1а сама уводит на /kiosk');
    });

    test('T-KIOSK-045: G-0a — после G-0: сессия не проверена → /splash', () {
      expect(_redirect('/auth/phone', status: SessionStatus.unknown), '/splash');
      expect(_redirect('/kiosk', status: SessionStatus.unknown), '/splash');
    });

    test('T-KIOSK-045: G-0a — до G-1: без признака гость уходит на SCR-01, гостевые пути остаются (паритет)', () {
      expect(_redirect('/kiosk', hold: false, mode: AppMode.seller), '/auth/phone?returnTo=%2Fkiosk');
      expect(_redirect('/orders', hold: false, mode: AppMode.seller), '/auth/phone?returnTo=%2Forders');
      expect(_redirect('/auth/phone', hold: false, mode: AppMode.seller), isNull);
      expect(_redirect('/register', hold: false, mode: AppMode.seller), isNull);
      // Явный выход сотрудника — по-прежнему без returnTo.
      expect(
        _redirect('/orders', hold: false, mode: AppMode.seller, endReason: SessionEndReason.logout),
        '/auth/phone',
      );
    });

    test('T-KIOSK-045: G-0a только без сессии — сессия планшета идёт по G-15, сотрудник по своим guard-ам', () {
      expect(_redirect('/auth/phone', status: SessionStatus.authenticated), KioskPaths.showcase);
      expect(_redirect('/kiosk', status: SessionStatus.authenticated), isNull);
      expect(
        appRedirect(
          status: SessionStatus.authenticated,
          uri: Uri.parse('/catalog'),
          mode: AppMode.seller,
          customerSelfService: true,
          role: RoleCode.seller,
        ),
        isNull,
      );
    });

    test('после KIOSK_REVOKED и аварийного выхода — G-1 без returnTo; выход без связи — с подсказкой SCR-01', () {
      expect(
        _redirect('/kiosk', hold: false, mode: AppMode.seller, endReason: SessionEndReason.kioskRevoked),
        '/auth/phone',
      );
      expect(
        _redirect('/kiosk', hold: false, mode: AppMode.seller, endReason: SessionEndReason.kioskExited),
        '/auth/phone',
      );
      expect(
        _redirect('/kiosk/checkout', hold: false, mode: AppMode.seller, endReason: SessionEndReason.kioskExitedOffline),
        kioskOfflineExitLocation,
      );
      expect(Uri.parse(kioskOfflineExitLocation).queryParameters['reason'], AuthEntryReason.kioskExitOffline.value);
      expect(AuthEntryReason.tryParse('kiosk_exit_offline'), AuthEntryReason.kioskExitOffline);
      expect(AuthEntryReason.kioskExitOffline.isWarning, isFalse, reason: 'ErrorState.banner info');
      expect(
        AuthMessages.entryReason(AppLocalizationsRu(), AuthEntryReason.kioskExitOffline),
        AppLocalizationsRu().kiosk_exit_offline_hint,
      );
    });

    testWidgets(
      'T-KIOSK-045: холодный старт с признаком без токенов → /kiosk «Подключите заново»; /auth/phone → /kiosk',
      (WidgetTester tester) async {
        final FakeKioskLock lock = FakeKioskLock(locked: true);
        final SessionHarness h = kioskHarness((o) async => json(200, <String, Object?>{}), lock: lock, refresh: null);
        addTearDown(h.dispose);
        h.start();
        await tester.runAsync(() => h.container.read(sessionStatusProvider.future));
        final GoRouter router = kioskGuardRouter(h.container);
        addTearDown(router.dispose);
        await tester.pumpWidget(kioskTestApp(h.container, router));
        await tester.pumpAndSettle();
        // SCR-00: признак планшета → /kiosk (строка 1а); здесь — заглушка Splash, переход — программный.
        router.go('/kiosk');
        await tester.pumpAndSettle();
        expect(router.state.uri.path, KioskPaths.showcase);
        expect(find.text(AppLocalizationsRu().kiosk_reconnect_needed), findsOneWidget);
        expect(h.container.read(kioskRouteHoldProvider), isTrue);
        for (final String path in <String>['/auth/phone', '/auth/otp', '/register', '/kiosk/done', '/catalog']) {
          router.go(path);
          await tester.pumpAndSettle();
          expect(router.state.uri.path, KioskPaths.showcase, reason: path);
          expect(find.byKey(KioskStateView.fullScreenKey), findsOneWidget, reason: path);
          expect(find.byKey(pageKey('phone ')), findsNothing, reason: 'экрана входа нет: $path');
        }
        expect(lock.count('disable'), 0, reason: 'закрепление не снимается');
      },
    );
  });
}
