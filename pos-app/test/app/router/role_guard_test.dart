// Маршруты этапа E (02 §4.1): адреса с параметрами, экраны фич вместо RouteStubScreen,
// roleGuard (staff / customer; navigation.md G-7, G-8) и подмена репозиториев в widget-тесте.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/app_router.dart';
import 'package:optomstroy/app/router/guards/role_guard.dart';
import 'package:optomstroy/app/router/routes.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/core/enums.dart' show RoleCode;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_repository.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_screen.dart';
import 'package:optomstroy/features/home/presentation/screens/customer_home_screen.dart';
import 'package:optomstroy/features/product_details/presentation/screens/product_details_screen.dart';
import 'package:optomstroy/features/scan/presentation/screens/scan_screen.dart';
import 'package:optomstroy/features/settings/presentation/screens/settings_screen.dart';
import 'package:optomstroy/features/sync_status/presentation/screens/sync_status_screen.dart';

/// Фейк порта для widget-тестов: реализует только нужные методы.
final class _FakeCatalogRepository implements CatalogRepository {
  @override
  Future<Result<CategoryTree>> cachedCategories() async => const Success(CategoryTree(roots: <Category>[]));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  String? redirect(AppMode mode, String location, {bool selfService = true}) => appRedirect(
    status: SessionStatus.authenticated,
    uri: Uri.parse(location),
    mode: mode,
    customerSelfService: selfService,
  );

  test('адреса маршрутов этапа E по 02 §4.1 (только path/query)', () {
    expect(const CatalogRoute(preset: 'recent').location, '/catalog?preset=recent');
    expect(
      const CatalogSearchRoute(q: 'смес', sort: 'sku:asc').location,
      '/catalog/search?q=%D1%81%D0%BC%D0%B5%D1%81&sort=sku%3Aasc',
    );
    expect(const CategoryRoute(categoryId: 'c1', view: 'list').location, '/catalog/c/c1?view=list');
    expect(const CatalogFiltersRoute(f: 'x').location, '/catalog/filters?f=x');
    expect(
      const ProductRoute(productId: 'p1', variantId: 'v1', qty: '2.500').location,
      '/catalog/p/p1?variantId=v1&qty=2.500',
    );
    expect(const ScanRoute(mode: 'add').location, '/scan?mode=add');
    expect(const SettingsRoute(section: 'scanner').location, '/settings?section=scanner');
    expect(const SyncRoute(entity: 'stock', runId: 'r1', tab: 'runs').location, '/sync?entity=stock&runId=r1&tab=runs');
    expect(const HomeRoute(view: 'grid').location, '/home?view=grid');
  });

  group('roleGuard (G-7, G-8)', () {
    test('customer: staff-разделы → /home; каталог клиента (поиск, категория, карточка) доступен', () {
      for (final path in [
        '/catalog',
        '/scan',
        '/sync',
        '/cashier',
        '/customers',
        '/customers/new',
        '/transactions/t1',
        '/admin/users',
        '/reports',
      ]) {
        expect(redirect(AppMode.customer, path), '/home', reason: path);
      }
      for (final path in [
        '/home',
        '/catalog/search?q=a',
        '/catalog/c/c1',
        '/catalog/p/p1',
        '/catalog/filters',
        '/settings',
        '/favorites',
        '/customers/me',
      ]) {
        expect(redirect(AppMode.customer, path), isNull, reason: path);
      }
    });

    test('сотрудник на /home → главный экран режима; staff-разделы этапа E доступны', () {
      expect(redirect(AppMode.seller, '/home'), '/catalog');
      expect(redirect(AppMode.cashier, '/home?view=grid'), '/cashier');
      for (final path in ['/catalog', '/catalog/p/p1', '/scan?mode=search', '/sync', '/settings']) {
        expect(redirect(AppMode.seller, path), isNull, reason: path);
      }
    });

    test('G-7 для сотрудников: ветки и кассовые маршруты чужих ролей → главный экран режима', () {
      String? staff(AppMode mode, RoleCode role, String path) => appRedirect(
        status: SessionStatus.authenticated,
        uri: Uri.parse(path),
        mode: mode,
        customerSelfService: true,
        role: role,
      );
      // seller: админка, отчёты, касса, приём оплаты и возвраты закрыты.
      for (final path in ['/admin/users', '/admin/settings', '/reports', '/cashier', '/payments/new', '/returns/new']) {
        expect(staff(AppMode.seller, RoleCode.seller, path), '/catalog', reason: 'seller $path');
      }
      for (final path in ['/catalog', '/cart', '/checkout', '/customers', '/transactions', '/favorites', '/sync']) {
        expect(staff(AppMode.seller, RoleCode.seller, path), isNull, reason: 'seller $path');
      }
      // senior_seller: касса, приём оплаты и возвраты открыты; админка — нет.
      for (final path in ['/cashier', '/payments/new?orderId=o1', '/returns/new?orderId=o1']) {
        expect(staff(AppMode.seller, RoleCode.seniorSeller, path), isNull, reason: 'senior_seller $path');
      }
      expect(staff(AppMode.seller, RoleCode.seniorSeller, '/admin/users'), '/catalog');
      // cashier: касса и оплата; админка и отчёты — нет.
      expect(staff(AppMode.cashier, RoleCode.cashier, '/payments/new?orderId=o1'), isNull);
      expect(staff(AppMode.cashier, RoleCode.cashier, '/admin/users'), '/cashier');
      expect(staff(AppMode.cashier, RoleCode.cashier, '/reports'), '/cashier');
      // admin: без приёма оплаты (D-15); админка, отчёты, касса (просмотр), возвраты — да.
      expect(staff(AppMode.admin, RoleCode.admin, '/payments/new?orderId=o1'), '/catalog');
      for (final path in ['/admin/users', '/reports', '/cashier', '/returns/new?orderId=o1']) {
        expect(staff(AppMode.admin, RoleCode.admin, path), isNull, reason: 'admin $path');
      }
      // owner (§14.7): закрыты /checkout, /payments/new, /returns/new, /cart, /cart/parked; просмотр возврата — да.
      for (final path in ['/checkout', '/payments/new?orderId=o1', '/returns/new', '/cart', '/cart/parked']) {
        expect(staff(AppMode.seller, RoleCode.owner, path), '/catalog', reason: 'owner $path');
      }
      for (final path in ['/returns/r1', '/admin/audit', '/reports', '/cashier', '/transactions']) {
        expect(staff(AppMode.seller, RoleCode.owner, path), isNull, reason: 'owner $path');
      }
    });

    test('customer: кассовые маршруты root-уровня закрыты (G-7, RM-E-017)', () {
      for (final path in ['/payments/new?orderId=o1', '/returns/new?orderId=o1', '/returns/r1']) {
        expect(redirect(AppMode.customer, path), '/home', reason: path);
      }
    });

    test('CUSTOMER_SELF_SERVICE=false: режим клиента недостижим (RM-E-007 п. 4, RM-E-017 п. 4)', () {
      for (final path in ['/home', '/catalog/p/p1', '/favorites', '/cart', '/checkout', '/orders']) {
        expect(redirect(AppMode.customer, path, selfService: false), '/pending-activation', reason: path);
      }
      expect(redirect(AppMode.customer, '/pending-activation', selfService: false), isNull);
      expect(redirect(AppMode.seller, '/catalog', selfService: false), isNull);
    });

    test('без сессии решает authGuard; публичные пути roleGuard не трогает', () {
      expect(
        appRedirect(
          status: SessionStatus.unauthenticated,
          uri: Uri.parse('/sync'),
          mode: AppMode.customer,
          customerSelfService: true,
        ),
        '/auth/phone?returnTo=%2Fsync',
      );
      expect(redirect(AppMode.customer, '/register/customer-link'), isNull);
      expect(isStaffOnlyPath('/catalog/search'), isFalse);
    });
  });

  testWidgets('маршруты ведут на экраны фич с параметрами; репозиторий подменяется в ProviderScope', (tester) async {
    final router = GoRouter(routes: $appRoutes, initialLocation: '/catalog?preset=recent');
    addTearDown(router.dispose);
    final fake = _FakeCatalogRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogRepositoryProvider.overrideWithValue(fake),
          appModeProvider.overrideWithValue(AppMode.seller),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('stub-SCR-10')), findsOneWidget);
    expect(tester.widget<CatalogScreen>(find.byType(CatalogScreen)).preset, 'recent');
    final container = ProviderScope.containerOf(tester.element(find.byType(CatalogScreen)));
    expect((await container.read(catalogRepositoryProvider).cachedCategories()).isSuccess, isTrue);

    final screens = <String, Type>{
      '/catalog/p/p1?variantId=v1': ProductDetailsScreen,
      '/scan?mode=add': ScanScreen,
      '/settings?section=scanner': SettingsScreen,
      '/sync?entity=stock': SyncStatusScreen,
      '/home': CustomerHomeScreen,
    };
    for (final e in screens.entries) {
      router.go(e.key);
      await tester.pumpAndSettle();
      expect(find.byType(e.value), findsOneWidget, reason: e.key);
      if (e.value == SyncStatusScreen) {
        expect(tester.widget<SyncStatusScreen>(find.byType(SyncStatusScreen)).entity, 'stock');
      }
    }
  });
}
