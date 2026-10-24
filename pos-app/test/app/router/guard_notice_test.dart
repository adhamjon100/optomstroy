// Guards роутера (navigation.md §4.1): снекбары G-7 «Раздел недоступен для вашей роли» / «Приём оплаты
// выполняет кассир» (03 §16.7; FIX-EF-05, E-flutter-ui-5), G-11 — `/scan` без камеры остаётся на исходном
// экране со снекбаром (EQ-SCAN-10), выход без `returnTo` (EQ-DREST-17).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/app_router.dart';
import 'package:optomstroy/app/router/guards/auth_guard.dart';
import 'package:optomstroy/app/router/guards/role_guard.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/core/enums.dart' show RoleCode;
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';

GuardInputs _inputs({
  AppMode mode = AppMode.seller,
  RoleCode? role = RoleCode.seller,
  bool camera = true,
  SessionStatus status = SessionStatus.authenticated,
  bool selfService = true,
}) => (
  status: status,
  mode: mode,
  customerSelfService: selfService,
  role: role,
  endReason: null,
  cameraSupported: camera,
);

Widget _page(String name) => Scaffold(
  body: Center(child: Text(name, key: ValueKey<String>('page-$name'))),
);

void main() {
  group('roleRedirectNotice (G-7)', () {
    RoleGuardNotice? notice(AppMode mode, RoleCode? role, String path, {bool selfService = true}) => appRedirectNotice(
      status: SessionStatus.authenticated,
      uri: Uri.parse(path),
      mode: mode,
      customerSelfService: selfService,
      role: role,
    );

    test('сотрудник на ветке, закрытой роли, — «Раздел недоступен»; /payments/new — «кассир»', () {
      expect(notice(AppMode.seller, RoleCode.seller, '/admin/users'), RoleGuardNotice.roleForbidden);
      expect(notice(AppMode.seller, RoleCode.seller, '/payments/new'), RoleGuardNotice.paymentCashierOnly);
      expect(notice(AppMode.admin, RoleCode.admin, '/payments/new?orderId=o1'), RoleGuardNotice.paymentCashierOnly);
      expect(notice(AppMode.seller, RoleCode.owner, '/checkout'), RoleGuardNotice.roleForbidden);
      expect(notice(AppMode.cashier, RoleCode.cashier, '/payments/new'), isNull, reason: 'разрешено');
      expect(notice(AppMode.seller, RoleCode.seller, '/catalog'), isNull);
    });

    test('customer на пути сотрудника — снекбар; G-8 и сотрудник на /home — без снекбара', () {
      expect(notice(AppMode.customer, RoleCode.customer, '/cashier'), RoleGuardNotice.roleForbidden);
      expect(notice(AppMode.customer, RoleCode.customer, '/payments/new'), RoleGuardNotice.paymentCashierOnly);
      expect(notice(AppMode.customer, RoleCode.customer, '/catalog', selfService: false), isNull, reason: 'G-8');
      expect(notice(AppMode.seller, RoleCode.seller, '/home'), isNull, reason: 'свой главный экран');
      expect(notice(AppMode.seller, null, '/admin/users'), isNull, reason: 'роль ещё не загружена');
    });

    test('без сессии и на гостевых путях снекбара нет (решает authGuard)', () {
      expect(
        appRedirectNotice(
          status: SessionStatus.unauthenticated,
          uri: Uri.parse('/admin/users'),
          mode: AppMode.seller,
          customerSelfService: true,
          role: RoleCode.seller,
        ),
        isNull,
      );
      expect(notice(AppMode.seller, RoleCode.seller, '/auth/phone'), isNull);
    });
  });

  test('G-11: blocksScanWithoutCamera — только переход с другого экрана при отсутствии камеры', () {
    bool blocks(String from, {bool camera = false, bool auth = true}) => blocksScanWithoutCamera(
      current: Uri.parse(from),
      next: Uri.parse('/scan?mode=search'),
      cameraSupported: camera,
      authenticated: auth,
    );
    expect(blocks('/catalog'), isTrue);
    expect(blocks('/catalog', camera: true), isFalse);
    expect(blocks('/scan'), isFalse, reason: 'deep link / обновление без исходного экрана');
    expect(blocks('/catalog', auth: false), isFalse);
  });

  test('EQ-DREST-17: после «Выйти» вход без returnTo прежнего пользователя; отзыв сессии — с returnTo', () {
    final Uri settings = Uri.parse('/settings?section=sessions');
    expect(
      authRedirect(
        status: SessionStatus.unauthenticated,
        uri: settings,
        homeLocation: '/catalog',
        endReason: SessionEndReason.logout,
      ),
      '/auth/phone',
    );
    expect(
      authRedirect(
        status: SessionStatus.unauthenticated,
        uri: settings,
        homeLocation: '/catalog',
        endReason: SessionEndReason.logoutAll,
      ),
      '/auth/phone',
    );
    expect(
      authRedirect(
        status: SessionStatus.unauthenticated,
        uri: settings,
        homeLocation: '/catalog',
        endReason: SessionEndReason.revoked,
      ),
      startsWith('/auth/phone?returnTo='),
    );
  });

  group('снекбары guards в роутере', () {
    Future<GoRouter> pump(WidgetTester tester, GuardInputs g) async {
      final GoRouter router = GoRouter(
        initialLocation: '/catalog',
        routes: <RouteBase>[
          for (final String path in <String>['/catalog', '/cashier', '/admin/users', '/payments/new', '/scan', '/home'])
            GoRoute(path: path, builder: (BuildContext context, GoRouterState state) => _page(path)),
        ],
        onEnter: (BuildContext context, GoRouterState current, GoRouterState next, GoRouter router) =>
            guardOnEnter(context, current, next, g),
        redirect: (BuildContext context, GoRouterState state) => guardRedirect(context, state, g),
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          theme: AppTheme.light(),
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      );
      await tester.pumpAndSettle();
      return router;
    }

    String path(GoRouter router) => router.routerDelegate.currentConfiguration.uri.path;

    testWidgets('G-7: seller → /admin/users — главный экран роли + «Раздел недоступен для вашей роли»', (
      WidgetTester tester,
    ) async {
      final GoRouter router = await pump(tester, _inputs());
      router.go('/admin/users');
      await tester.pumpAndSettle();
      expect(path(router), '/catalog');
      expect(find.text('Раздел недоступен для вашей роли'), findsOneWidget);
    });

    testWidgets('G-7: seller → /payments/new — «Приём оплаты выполняет кассир»', (WidgetTester tester) async {
      final GoRouter router = await pump(tester, _inputs());
      unawaited(router.push<void>('/payments/new'));
      await tester.pumpAndSettle();
      expect(path(router), '/catalog');
      expect(find.byKey(const ValueKey<String>('page-/payments/new')), findsNothing);
      expect(find.text('Приём оплаты выполняет кассир'), findsOneWidget);
    });

    testWidgets('разрешённый переход — без снекбара', (WidgetTester tester) async {
      final GoRouter router = await pump(tester, _inputs(mode: AppMode.cashier, role: RoleCode.cashier));
      router.go('/payments/new');
      await tester.pumpAndSettle();
      expect(path(router), '/payments/new');
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('G-11: /scan без камеры — остаёмся на исходном экране + подсказка HID-сканера', (
      WidgetTester tester,
    ) async {
      final GoRouter router = await pump(tester, _inputs(camera: false));
      unawaited(router.push<void>('/scan?mode=search'));
      await tester.pumpAndSettle();
      expect(path(router), '/catalog');
      expect(router.canPop(), isFalse, reason: 'переход заблокирован — стек не изменился');
      expect(find.byKey(const ValueKey<String>('page-/scan')), findsNothing);
      expect(find.text('Используйте сканер: наведите на штрихкод и нажмите курок'), findsOneWidget);
    });

    testWidgets('G-11: с камерой /scan открывается', (WidgetTester tester) async {
      final GoRouter router = await pump(tester, _inputs());
      unawaited(router.push<void>('/scan?mode=search'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('page-/scan')), findsOneWidget);
      expect(router.canPop(), isTrue);
      expect(find.byType(SnackBar), findsNothing);
    });
  });
}
