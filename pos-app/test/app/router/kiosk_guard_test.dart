// Режим «Планшет магазина» (P-002 §9, ADR-115; 13 TAB-2-01): `AppMode.kiosk`, маршруты `/kiosk`, `/kiosk/checkout`,
// `/kiosk/done` вне оболочки `AppShell`, guard G-15 (`visual/navigation.md` §4.1) и строка 1а SCR-00.6.
// G-15: сессия `kind=kiosk` — только пути режима, в том числе вместо гостевых (`/auth/*`, `/register*`,
// `/pending-activation`, `/splash`), до G-5 и без снекбара; сотрудник и `customer` на `/kiosk*` — главный экран
// своего режима; гость — по G-1. G-0a (признак планшета без сессии) — `kiosk_g0a_test.dart` (TAB-2-10).
// Трассировка: 12 T-KIOSK-045; 10 KIOSK-005, KIOSK-031; 06 AC-MOD-030 п. 3; 02 ч. F правило 3 (адрес `/kiosk?c=`
// без строки поиска; PRIV-033).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/app_router.dart';
import 'package:optomstroy/app/router/guards/role_guard.dart';
import 'package:optomstroy/app/router/kiosk_routes.dart';
import 'package:optomstroy/app/router/routes.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/app/router/shells/app_shell.dart';
import 'package:optomstroy/app/router/shells/staff_nav_drawer.dart';
import 'package:optomstroy/core/enums.dart' show RoleCode, UserKind;
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/design_system/components/bottom_nav_bar.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/kiosk/kiosk_providers.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_shell_screen.dart';
import 'package:optomstroy/features/orders/presentation/providers/orders_ports.dart';
import 'package:optomstroy/features/splash/presentation/notifiers/splash_decision.dart';

/// Пути, на которые планшет пытается уйти (12 T-KIOSK-045 + гостевые и root-маршруты сотрудника).
const List<String> _escapes = <String>[
  '/orders',
  '/orders/o1',
  '/admin/users',
  '/admin/tablets',
  '/auth/phone',
  '/auth/phone?returnTo=%2Fcatalog',
  '/auth/otp',
  '/auth/unlock?mode=cold',
  '/me',
  '/cart',
  '/cart/parked',
  '/checkout',
  '/register',
  '/register/security?mode=staff_first_login',
  '/register/customer-link',
  '/pending-activation',
  '/splash',
  '/home',
  '/catalog',
  '/catalog/p/p1',
  '/favorites',
  '/profile',
  '/settings',
  '/sync',
  '/notifications',
  '/cashier',
  '/customers/c1',
  '/scan',
  '/kiosk/unknown',
];

/// Пути режима планшета (с query экранов SCR-51 и SCR-52).
const List<String> _kioskPaths = <String>[
  '/kiosk',
  '/kiosk?c=cat-1&q=%D1%81%D0%BC%D0%B5%D1%81%D1%8C',
  '/kiosk/checkout',
  '/kiosk/checkout?step=code',
  '/kiosk/done',
];

String? _redirect(
  AppMode mode,
  String location, {
  RoleCode? role,
  SessionStatus status = SessionStatus.authenticated,
  SessionLockReason? lock,
  bool selfService = true,
}) => appRedirect(
  status: status,
  uri: Uri.parse(location),
  mode: mode,
  customerSelfService: selfService,
  role: role,
  lock: lock,
);

RoleGuardNotice? _notice(AppMode mode, String location, {RoleCode? role}) => appRedirectNotice(
  status: SessionStatus.authenticated,
  uri: Uri.parse(location),
  mode: mode,
  customerSelfService: true,
  role: role,
);

GuardInputs _inputs(AppMode mode, RoleCode? role, {bool camera = true}) => (
  status: SessionStatus.authenticated,
  mode: mode,
  customerSelfService: true,
  role: role,
  endReason: null,
  lock: null,
  cameraSupported: camera,
);

Widget _page(String name) => Scaffold(
  body: Center(child: Text(name, key: ValueKey<String>('page-$name'))),
);

void main() {
  group('T-KIOSK-045 G-15: из режима планшета не уйти', () {
    test('сессия kind=kiosk: любой путь вне /kiosk* → /kiosk, в том числе гостевые и /splash', () {
      for (final RoleCode? role in <RoleCode?>[null, RoleCode.kiosk]) {
        for (final String path in _escapes) {
          expect(_redirect(AppMode.kiosk, path, role: role), KioskPaths.showcase, reason: 'role $role: $path');
        }
      }
    });

    test('сессия kind=kiosk: /kiosk, /kiosk/checkout, /kiosk/done — остаться (query не мешает)', () {
      for (final String path in _kioskPaths) {
        expect(_redirect(AppMode.kiosk, path, role: RoleCode.kiosk), isNull, reason: path);
      }
    });

    test('G-15 — до G-5: блокировка холодного старта не ведёт планшет на SCR-08', () {
      expect(_redirect(AppMode.kiosk, '/orders', lock: SessionLockReason.coldStart), KioskPaths.showcase);
      expect(_redirect(AppMode.kiosk, '/auth/unlock?mode=cold', lock: SessionLockReason.coldStart), '/kiosk');
      expect(_redirect(AppMode.kiosk, '/kiosk', lock: SessionLockReason.coldStart), isNull);
      // Сотрудник с блокировкой холодного старта сначала проходит SCR-08 (G-5, from=/kiosk).
      expect(
        _redirect(AppMode.seller, '/kiosk', role: RoleCode.seller, lock: SessionLockReason.coldStart),
        '/auth/unlock?mode=cold&from=%2Fkiosk',
      );
    });

    test('планшет перенаправляется без снекбара G-7', () {
      for (final String path in <String>[..._escapes, ..._kioskPaths]) {
        expect(_notice(AppMode.kiosk, path, role: RoleCode.kiosk), isNull, reason: path);
        expect(_notice(AppMode.kiosk, path), isNull, reason: path);
      }
    });

    test('сотрудник и customer на /kiosk* → главный экран своего режима, без снекбара', () {
      const Map<AppMode, (RoleCode, String)> homes = <AppMode, (RoleCode, String)>{
        AppMode.seller: (RoleCode.seller, '/catalog'),
        AppMode.cashier: (RoleCode.cashier, '/cashier'),
        AppMode.admin: (RoleCode.admin, '/catalog'),
        AppMode.owner: (RoleCode.owner, '/reports'),
        AppMode.customer: (RoleCode.customer, '/home'),
      };
      for (final MapEntry<AppMode, (RoleCode, String)> e in homes.entries) {
        for (final String path in <String>[..._kioskPaths, '/kiosk/unknown']) {
          expect(_redirect(e.key, path, role: e.value.$1), e.value.$2, reason: '${e.key.name} $path');
          expect(_notice(e.key, path, role: e.value.$1), isNull, reason: '${e.key.name} $path');
        }
      }
      // Роль ещё не загружена — тот же главный экран режима.
      expect(_redirect(AppMode.seller, '/kiosk'), '/catalog');
      // customer без самообслуживания: /kiosk → /home → SCR-07 (G-8) на следующем шаге.
      expect(_redirect(AppMode.customer, '/kiosk', role: RoleCode.customer, selfService: false), '/home');
      // Пути с префиксом, но не режима планшета, — не трогаются.
      expect(isKioskPath('/kiosks'), isFalse);
      expect(isKioskPath('/kiosk'), isTrue);
      expect(isKioskPath('/kiosk/checkout'), isTrue);
    });

    test('гость на /kiosk* — по G-1; сессия не проверена — /splash (G-0)', () {
      expect(
        _redirect(AppMode.seller, '/kiosk', status: SessionStatus.unauthenticated),
        '/auth/phone?returnTo=%2Fkiosk',
      );
      expect(_redirect(AppMode.kiosk, '/kiosk', status: SessionStatus.unknown), '/splash');
      expect(_redirect(AppMode.kiosk, '/splash', status: SessionStatus.unknown), isNull);
    });

    testWidgets('в режиме планшета нет панели и rail; переходы на другие маршруты ведут на /kiosk (AC-MOD-030 п. 3)', (
      tester,
    ) async {
      // Платформа без камеры (Windows, веб-демо): G-11 `onEnter` подключён, но планшет на `/scan` уводит G-15.
      final GuardInputs g = _inputs(AppMode.kiosk, RoleCode.kiosk, camera: false);
      final GoRouter router = GoRouter(
        initialLocation: '/kiosk?c=cat-1',
        routes: <RouteBase>[...$appRoutes, ...kioskRoutes()],
        onEnter: (BuildContext context, GoRouterState current, GoRouterState next, GoRouter router) =>
            guardOnEnter(context, current, next, g),
        redirect: (BuildContext context, GoRouterState state) => guardRedirect(context, state, g),
      );
      addTearDown(router.dispose);
      KioskCatalogArgs? seen;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            kioskCatalogBodyProvider.overrideWithValue((BuildContext context, KioskCatalogArgs args) {
              seen = args;
              return const Text('SCR-51', key: ValueKey<String>('kiosk-body'));
            }),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            theme: AppTheme.light(),
            // Локализация — чтобы снекбар guard-а (G-7, G-11), если бы он был, действительно показался.
            locale: const Locale('ru'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(KioskShellScreen.screenKey), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('kiosk-body')), findsOneWidget);
      expect(seen, const KioskCatalogArgs(categoryId: 'cat-1'));
      expect(find.byType(AppShell), findsNothing);
      expect(find.byType(BottomNavBar), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byType(Drawer), findsNothing);

      for (final String path in <String>[
        '/orders',
        '/admin/users',
        '/auth/phone',
        '/me',
        '/cart/parked',
        '/splash',
        '/scan?mode=search',
      ]) {
        router.go(path);
        await tester.pumpAndSettle();
        expect(router.state.uri.path, KioskPaths.showcase, reason: path);
        expect(find.byKey(KioskShellScreen.screenKey), findsOneWidget, reason: path);
        expect(find.byType(AppShell), findsNothing, reason: path);
        expect(find.byType(SnackBar), findsNothing, reason: path);
      }
      for (final String path in <String>[KioskPaths.checkout, KioskPaths.done]) {
        router.go(path);
        await tester.pumpAndSettle();
        expect(router.state.uri.path, path);
        expect(find.byKey(KioskShellScreen.screenKey), findsOneWidget, reason: path);
      }

      // Системное «Назад» из режима не выводит (P-002 §8.10): каркас остаётся на экране.
      router.go(KioskPaths.showcase);
      await tester.pumpAndSettle();
      expect(await tester.binding.handlePopRoute(), isTrue, reason: '«Назад» обработан внутри приложения');
      await tester.pumpAndSettle();
      expect(router.state.uri.path, KioskPaths.showcase);
      expect(find.byKey(KioskShellScreen.screenKey), findsOneWidget);
    });

    testWidgets('/kiosk?c=cat-1&q=x: в параметры витрины попадает только c — строка поиска не из адреса (правило 3)', (
      tester,
    ) async {
      // 02 ч. F, правило 3; PRIV-033; 01 GEN-254: поисковый запрос планшета в адрес не пишется и из адреса не берётся.
      final GuardInputs g = _inputs(AppMode.kiosk, RoleCode.kiosk);
      final GoRouter router = GoRouter(
        initialLocation: '/kiosk?c=cat-1&q=x',
        routes: kioskRoutes(),
        redirect: (BuildContext context, GoRouterState state) => guardRedirect(context, state, g),
      );
      addTearDown(router.dispose);
      KioskCatalogArgs? seen;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            kioskCatalogBodyProvider.overrideWithValue((BuildContext context, KioskCatalogArgs args) {
              seen = args;
              return const Text('SCR-51', key: ValueKey<String>('kiosk-body'));
            }),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            theme: AppTheme.light(),
            locale: const Locale('ru'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('kiosk-body')), findsOneWidget);
      expect(seen, const KioskCatalogArgs(categoryId: 'cat-1'));
      expect(seen.toString(), 'KioskCatalogArgs(c: cat-1)');

      router.go('/kiosk?q=%D1%81%D0%BC%D0%B5%D1%81%D1%8C');
      await tester.pumpAndSettle();
      expect(seen, const KioskCatalogArgs());
    });

    testWidgets('сотрудник на /kiosk попадает на главный экран своего режима', (tester) async {
      final GoRouter router = GoRouter(
        initialLocation: '/cashier',
        routes: <RouteBase>[
          for (final String path in <String>['/catalog', '/cashier'])
            GoRoute(path: path, builder: (_, _) => _page(path)),
          ...kioskRoutes(),
        ],
        redirect: (BuildContext context, GoRouterState state) =>
            guardRedirect(context, state, _inputs(AppMode.cashier, RoleCode.cashier)),
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp.router(
            routerConfig: router,
            theme: AppTheme.light(),
            locale: const Locale('ru'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final String path in _kioskPaths) {
        router.go(path);
        await tester.pumpAndSettle();
        expect(router.state.uri.path, '/cashier', reason: path);
        expect(find.byKey(KioskShellScreen.screenKey), findsNothing, reason: path);
        expect(find.byType(SnackBar), findsNothing, reason: path);
      }
    });
  });

  group('AppMode.kiosk и маршруты режима (TAB-2-01)', () {
    test('appModeFor: kind=kiosk — первым, до правил ролей; режим продавца по умолчанию к планшету не применяется', () {
      expect(appModeFor(kind: UserKind.kiosk), AppMode.kiosk);
      expect(appModeFor(kind: UserKind.kiosk, role: RoleCode.seller), AppMode.kiosk);
      expect(appModeFor(role: RoleCode.kiosk), AppMode.kiosk);
      // Прежние режимы не меняются.
      expect(appModeFor(), AppMode.seller);
      expect(appModeFor(kind: UserKind.staff), AppMode.seller);
      expect(appModeFor(kind: UserKind.customer), AppMode.customer);
      expect(appModeFor(kind: UserKind.staff, role: RoleCode.cashier), AppMode.cashier);
      expect(homeLocationFor(AppMode.kiosk), KioskPaths.showcase);
    });

    test('маршруты /kiosk* — root-уровня, вне StatefulShellRoute и карты ядра (ShellBranch не меняется)', () {
      final Set<String> kiosk = kioskRoutes().whereType<GoRoute>().map((GoRoute r) => r.path).toSet();
      expect(kiosk, KioskPaths.all);
      expect(kiosk, <String>{'/kiosk', '/kiosk/checkout', '/kiosk/done'});
      final GoRouter router = GoRouter(routes: $appRoutes);
      addTearDown(router.dispose);
      for (final String path in kiosk) {
        expect(router.configuration.findMatch(Uri.parse(path)).isError, isTrue, reason: '$path не в \$appRoutes');
      }
    });

    test('оболочка: у планшета нет HID-сканера, drawer навигации и ссылок «Других разделов»', () {
      expect(isStaffMode(AppMode.kiosk), isFalse);
      expect(isStaffMode(AppMode.customer), isFalse);
      for (final AppMode m in <AppMode>[AppMode.seller, AppMode.cashier, AppMode.admin, AppMode.owner]) {
        expect(isStaffMode(m), isTrue, reason: m.name);
        expect(hidScannerEnabledFor(m), isTrue, reason: m.name);
      }
      expect(hidScannerEnabledFor(AppMode.kiosk), isFalse);
      expect(hidScannerEnabledFor(AppMode.customer), isFalse);
      for (final WindowClass wc in WindowClass.values) {
        expect(shellDrawerNavigationFor(AppMode.kiosk, wc), isFalse, reason: wc.name);
      }
      expect(shellLinksFor(AppMode.kiosk), isEmpty);
      expect(shellTabsFor(AppMode.kiosk), isNotEmpty, reason: 'кадр перехода не ломает AdaptiveScaffold');
      expect(isPathAllowedForRole(RoleCode.kiosk, '/kiosk/checkout'), isTrue);
      expect(isPathAllowedForRole(RoleCode.kiosk, '/catalog'), isFalse);
    });

    test('SCR-00.6 строка 1а: признак планшета → SCR-51 /kiosk без SCR-08, с сессией и без неё', () {
      expect(SplashDestination.kiosk.location, KioskPaths.showcase);
      expect(decideSplash(const SplashSnapshot(hasSession: true, kioskTablet: true)), SplashDestination.kiosk);
      expect(decideSplash(const SplashSnapshot(hasSession: false, kioskTablet: true)), SplashDestination.kiosk);
      expect(
        decideSplash(const SplashSnapshot(hasSession: true, kind: SplashUserKind.staff, kioskTablet: true)),
        SplashDestination.kiosk,
      );
      // Без признака — прежние строки 3–9.
      expect(decideSplash(SplashSnapshot.guest), SplashDestination.phone);
      expect(decideSplash(const SplashSnapshot(hasSession: true)), SplashDestination.unlock);
      expect(SplashSnapshot.guest.kioskTablet, isFalse);
    });

    test('зритель заказов: планшет — не сотрудник, без печати, QR, оплаты и «Повторить заказ» (KIOSK-005)', () {
      const OrdersViewer kiosk = OrdersViewer(role: RoleCode.kiosk);
      expect(kiosk.isStaff, isFalse);
      expect(kiosk.isCustomer, isFalse);
      expect(kiosk.canReadAll, isFalse);
      expect(kiosk.canPrint, isFalse);
      expect(kiosk.canAcceptPayment, isFalse);
      expect(kiosk.canShowQr, isFalse);
      expect(kiosk.canOnecLink, isFalse);
      expect(kiosk.canRepeat, isFalse);
      expect(kiosk.canCreateOrder, isFalse);
      expect(kiosk.canOpenCustomerCard, isFalse);
      // Прежние роли не меняются.
      expect(const OrdersViewer(role: RoleCode.seller).isStaff, isTrue);
      expect(const OrdersViewer(role: RoleCode.seller).canPrint, isTrue);
      expect(const OrdersViewer(role: RoleCode.customer).canPrint, isTrue);
      expect(const OrdersViewer(role: RoleCode.customer).isStaff, isFalse);
    });
  });
}
