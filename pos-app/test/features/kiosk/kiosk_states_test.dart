// Состояния планшета магазина на SCR-51 (13 TAB-2-10; 02 SCR-51.7, UI-51-014, UI-51-015, AC-UI-51-009, AC-UI-51-010,
// AC-UI-51-013, AC-UI-90-020; navigation.md §4.3; ADR-115 п. 21, п. 28): «Сервис временно недоступен»
// (`features.storeTablet=false`, `403 KIOSK_DISABLED`), «Планшет не в сети магазина» (`403 KIOSK_NETWORK_DENIED`),
// «Планшет нужно обновить» (`426` — без SCR-90 C3, гейт версии приложение не заменяет), связь с сервером не реже раза
// в 5 мин (`GET /settings/public` вместо `GET /sync/status`). Баннер `426` рисует экран под своей шапкой (UI-51-014: на
// SCR-51 — настоящая витрина фичи catalog с портами корня); каталог из кэша без отметки времени для покупателя
// (SCR-51.7).
// Трассировка: 12 T-KIOSK-033, T-KIOSK-048, T-KIOSK-050, T-KIOSK-064; 10 KIOSK-026, KIOSK-028, KIOSK-032, KIOSK-033.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/di/overrides.dart' show catalogKioskUpdateNeeded, catalogViewerRole;
import 'package:optomstroy/app/global_states/app_version_gate.dart';
import 'package:optomstroy/app/router/shells/kiosk_mode_bindings.dart' show kioskCatalogBody;
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/app_localizations_ru.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/session/kiosk_marker.dart';
import 'package:optomstroy/core/session/session_overlay.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/screens/kiosk_catalog_view.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/kiosk_catalog_header.dart';
import 'package:optomstroy/features/kiosk/data/dio_kiosk_lifecycle_repository.dart';
import 'package:optomstroy/features/kiosk/kiosk_providers.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_heartbeat.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_state_view.dart';
import 'package:optomstroy/features/session_ui/presentation/session_gate.dart';
import 'package:optomstroy/features/session_ui/presentation/widgets/update_required_view.dart';

import '../catalog/presentation/support/catalog_fakes.dart' as cf;
import 'kiosk_lifecycle_support.dart';

final AppLocalizationsRu _l10n = AppLocalizationsRu();

/// Тело витрины SCR-51 теста (каталог подключает TAB-2-03).
const Key _bodyKey = ValueKey<String>('kiosk-body');

/// Сервер теста с изменяемыми ответами.
final class _Server {
  ResponseBody Function(RequestOptions o) settings = (RequestOptions o) => json(200, publicSettingsBody());
  ResponseBody Function(RequestOptions o) other = (RequestOptions o) => json(200, <String, Object?>{'ok': true});

  Future<ResponseBody> call(RequestOptions o) async {
    if (o.path.endsWith('/auth/refresh')) return json(200, tokenPair(kioskJwt(tag: 'r'), 'rk2'));
    if (o.path.endsWith('/settings/public')) return settings(o);
    return other(o);
  }
}

/// Приложение как `app/app.dart`: гейт версии и слой сессии над роутером с guard-ами режима планшета.
Widget _gatedKioskApp(ProviderContainer container, GoRouter router) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp.router(
    routerConfig: router,
    theme: AppTheme.light(),
    locale: const Locale('ru'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    debugShowCheckedModeBanner: false,
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: AppVersionGate(child: SessionGate(coverColdStart: false, child: child!)),
    ),
  ),
);

/// Планшет с сессией на `/kiosk` (тело витрины — заглушка; [extra] — переопределения сверх режима планшета).
Future<(SessionHarness, GoRouter)> _showcase(
  WidgetTester tester,
  _Server server, {
  FakeKioskLock? lock,
  KioskCatalogBodyBuilder? body,
  List<Override> extra = const <Override>[],
}) async {
  final SessionHarness h = kioskHarness(
    server.call,
    lock: lock ?? FakeKioskLock(locked: true),
    overrides: <Override>[
      kioskCatalogBodyProvider.overrideWithValue(
        body ?? (BuildContext context, KioskCatalogArgs args) => const Text('SCR-51', key: _bodyKey),
      ),
      ...extra,
    ],
  );
  addTearDown(h.dispose);
  h.start();
  await tester.runAsync(() => h.container.read(sessionStatusProvider.future));
  final GoRouter router = kioskGuardRouter(h.container, initialLocation: '/kiosk');
  addTearDown(router.dispose);
  await tester.pumpWidget(_gatedKioskApp(h.container, router));
  await tester.pumpAndSettle();
  return (h, router);
}

/// Настоящая витрина SCR-51 (фича catalog) на фейках каталога: роль и «Планшет нужно обновить» — функции корня
/// `app/di/overrides.dart` по сессии планшета.
List<Override> _catalogBody(cf.FakeCatalogRepository catalog, {OnlineStatus online = OnlineStatus.online}) =>
    <Override>[
      catalogRepositoryProvider.overrideWithValue(catalog),
      searchRepositoryProvider.overrideWithValue(cf.FakeSearchRepository()),
      catalogViewerRoleProvider.overrideWith(catalogViewerRole),
      catalogKioskUpdateNeededProvider.overrideWith(catalogKioskUpdateNeeded),
      catalogOnlineStatusProvider.overrideWithValue(online),
      catalogShelfPortProvider.overrideWithValue(null),
    ];

/// Выполнить [action] в реальном времени (цепочка интерсепторов Dio) и перерисовать.
Future<void> _real(WidgetTester tester, Future<void> Function() action) async {
  await tester.runAsync(() async {
    await action();
    await settle();
  });
  await tester.pump();
}

Future<void> _get(SessionHarness h, String path) async {
  try {
    await h.dio.get<Object?>(path);
  } on DioException {
    // Ответ-ошибка — часть сценария.
  }
}

void main() {
  group('T-KIOSK-033 «Сервис временно недоступен»', () {
    testWidgets('T-KIOSK-033: 403 KIOSK_DISABLED → «Сервис временно недоступен» без кнопок; сессия не отозвана', (
      WidgetTester tester,
    ) async {
      final _Server server = _Server();
      final (SessionHarness h, GoRouter router) = await _showcase(tester, server);
      expect(find.byKey(_bodyKey), findsOneWidget);
      expect(h.container.read(kioskStatusProvider), KioskStatus.ready);

      server.other = (RequestOptions o) => json(403, problem('KIOSK_DISABLED', 403));
      await _real(tester, () => _get(h, '/kiosk/orders'));
      await tester.pumpAndSettle();
      expect(find.text(_l10n.kiosk_unavailable), findsOneWidget);
      expect(find.byKey(_bodyKey), findsNothing, reason: 'витрины нет');
      expect(find.byType(AppButton), findsNothing, reason: 'без «Выйти» и «Связаться с магазином»');
      expect(find.byKey(KioskStateView.logoKey), findsOneWidget, reason: 'аварийный выход доступен');
      expect(h.state.isKioskSession, isTrue);
      expect(router.state.uri.path, '/kiosk', reason: 'маршрут не меняется (G-8)');

      // Флаг снова включён: успешный ответ — витрина без перезапуска.
      server.other = (RequestOptions o) => json(200, <String, Object?>{'ok': true});
      await _real(tester, () => _get(h, '/cart'));
      await tester.pumpAndSettle();
      expect(find.byKey(_bodyKey), findsOneWidget);
    });

    testWidgets(
      'T-KIOSK-033: features.storeTablet=false → «Сервис временно недоступен»; CUSTOMER_SELF_SERVICE не влияет',
      (WidgetTester tester) async {
        final _Server server = _Server()
          ..settings = (RequestOptions o) => json(200, publicSettingsBody(storeTablet: false));
        final (SessionHarness h, GoRouter _) = await _showcase(tester, server);
        // До ответа сервера витрина не закрывается (fail-closed флаг, но запросы отвечает сервер сам).
        expect(h.container.read(kioskStatusProvider), KioskStatus.ready);
        await _real(tester, () => h.container.read(publicSettingsProvider.notifier).refresh());
        await tester.pumpAndSettle();
        expect(h.container.read(kioskStatusProvider), KioskStatus.unavailable);
        expect(find.text(_l10n.kiosk_unavailable), findsOneWidget);

        server.settings = (RequestOptions o) => json(200, publicSettingsBody(customerSelfService: false));
        await _real(tester, () => h.container.read(publicSettingsProvider.notifier).refresh());
        await tester.pumpAndSettle();
        expect(h.container.read(kioskStatusProvider), KioskStatus.ready);
        expect(find.byKey(_bodyKey), findsOneWidget);
      },
    );
  });

  group('T-KIOSK-048 «Планшет не в сети магазина»', () {
    testWidgets(
      'T-KIOSK-048: 403 KIOSK_NETWORK_DENIED → «Планшет не в сети магазина»; первый успешный ответ — витрина',
      (WidgetTester tester) async {
        final _Server server = _Server()..other = (RequestOptions o) => json(403, problem('KIOSK_NETWORK_DENIED', 403));
        final (SessionHarness h, GoRouter _) = await _showcase(tester, server);
        await _real(tester, () => _get(h, '/catalog/products'));
        await tester.pumpAndSettle();
        expect(find.text(_l10n.kiosk_network_denied), findsOneWidget);
        expect(find.byKey(_bodyKey), findsNothing);
        expect(h.state.isKioskSession, isTrue, reason: 'сессия не отзывается');
        expect(h.storage.values.containsKey(SecureKey.refreshToken), isTrue);

        // Heartbeat: `GET /settings/public` из сети магазина успешен — витрина без перезапуска (AC-UI-51-010).
        await _real(tester, () => h.container.read(kioskHeartbeatProvider).beat());
        await tester.pumpAndSettle();
        expect(h.container.read(kioskAccessProvider), KioskAccess.allowed);
        expect(find.byKey(_bodyKey), findsOneWidget);
      },
    );
  });

  group('T-KIOSK-050 426 → «Планшет нужно обновить», no SCR-90', () {
    testWidgets('T-KIOSK-050: 426 → баннер «Планшет нужно обновить», витрина остаётся, SCR-90 C3 нет', (
      WidgetTester tester,
    ) async {
      final _Server server = _Server()..other = (RequestOptions o) => json(426, problem('APP_UPDATE_REQUIRED', 426));
      final (SessionHarness h, GoRouter router) = await _showcase(tester, server);
      await _real(tester, () => _get(h, '/cart'));
      await tester.pumpAndSettle();
      expect(h.container.read(kioskStatusProvider), KioskStatus.updateNeeded);
      expect(h.container.read(kioskStatusProvider).blocksOrdering, isTrue, reason: '«В корзину» и заявка недоступны');
      // Баннер рисует экран под своей шапкой (UI-51-014); состояние планшета над экраном ничего не добавляет.
      expect(find.text(_l10n.kiosk_update_needed), findsNothing, reason: 'не над шапкой экрана');
      expect(find.byKey(KioskStateView.fullScreenKey), findsNothing);
      expect(find.byKey(_bodyKey), findsOneWidget, reason: 'витрина из кэша');
      expect(find.byKey(UpdateRequiredScreen.screenKey), findsNothing, reason: 'гейт версии приложение не заменяет');
      expect(find.byKey(UpdateRequiredView.viewKey), findsNothing, reason: 'диалога SCR-90 C3 нет');
      expect(find.byKey(UpdateRequiredScreen.updateButtonKey), findsNothing, reason: 'ссылки на загрузку нет');
      expect(h.container.read(sessionOverlayProvider), SessionOverlay.none);
      expect(router.state.uri.path, '/kiosk');
    });

    testWidgets('T-KIOSK-050 UI-51-014: на витрине SCR-51 баннер «Планшет нужно обновить» с иконкой system_update — '
        'под шапкой во всю ширину, над колонкой категорий; один баннер и без связи', (WidgetTester tester) async {
      final _Server server = _Server();
      final (SessionHarness h, GoRouter _) = await _showcase(
        tester,
        server,
        body: kioskCatalogBody,
        extra: _catalogBody(cf.FakeCatalogRepository(items: cf.products(4)), online: OnlineStatus.offline),
      );
      expect(find.byKey(KioskCatalogKeys.root), findsOneWidget);
      expect(find.byKey(KioskCatalogKeys.offlineBanner), findsOneWidget, reason: 'без связи — «Нет связи…»');
      expect(find.byKey(KioskCatalogKeys.updateBanner), findsNothing);

      server.other = (RequestOptions o) => json(426, problem('APP_UPDATE_REQUIRED', 426));
      await _real(tester, () => _get(h, '/cart'));
      await tester.pumpAndSettle();
      expect(h.container.read(kioskStatusProvider), KioskStatus.updateNeeded);
      final Finder banner = find.byKey(KioskCatalogKeys.updateBanner);
      expect(banner, findsOneWidget);
      expect(find.descendant(of: banner, matching: find.text(_l10n.kiosk_update_needed)), findsOneWidget);
      expect(find.descendant(of: banner, matching: find.byIcon(Icons.system_update_rounded)), findsOneWidget);
      expect(
        tester.getTopLeft(banner).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(find.byType(KioskCatalogHeader)).dy - 0.01),
        reason: 'под шапкой SCR-51',
      );
      expect(
        tester.getBottomLeft(banner).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.byKey(KioskCatalogKeys.sidebar)).dy + 0.01),
      );
      expect(tester.getSize(banner).width, tester.getSize(find.byKey(KioskCatalogKeys.root)).width);
      expect(find.byKey(KioskCatalogKeys.offlineBanner), findsNothing, reason: '426 и без связи — один баннер');
      expect(find.byType(ErrorState), findsOneWidget);
    });

    testWidgets('паритет: у сотрудника 426 по-прежнему заменяет приложение SCR-90', (WidgetTester tester) async {
      final SessionHarness h = SessionHarness((RequestOptions o) async => json(200, <String, Object?>{}));
      addTearDown(h.dispose);
      await tester.runAsync(() => h.start().establish(accessToken: fakeJwt(), refreshToken: 'r1'));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(
            theme: AppTheme.light(),
            locale: const Locale('ru'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const AppVersionGate(child: Text('staff')),
          ),
        ),
      );
      await tester.runAsync(
        () => h.container.read(appVersionControllerProvider).onUpdateRequired(minHeader: 'android=9.0.0'),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(UpdateRequiredScreen.screenKey), findsOneWidget);
      expect(find.text('staff'), findsNothing);
    });
  });

  group('SCR-51.7 без отметки времени для покупателя', () {
    testWidgets('«Нет связи»: каталог из кэша с остатками 2 ч назад — ни «данные от …» на карточках, ни «Фильтры по '
        'сохранённым данным от …» в открытой панели фильтров; баннер «Нет связи…» с иконкой wifi_off', (
      WidgetTester tester,
    ) async {
      final DateTime old = cf.kNow.subtract(const Duration(hours: 2));
      final cf.FakeCatalogRepository catalog = cf.FakeCatalogRepository()
        ..cached = Success<CatalogPage<ProductSummary>>(
          cf.page(<ProductSummary>[for (int i = 0; i < 4; i++) cf.product(i, asOf: old)], source: DataSource.cache),
        )
        ..networkPages.add(const FailureResult<CatalogPage<ProductSummary>>(cf.kOffline));
      await _showcase(tester, _Server(), body: kioskCatalogBody, extra: _catalogBody(catalog));
      expect(find.byKey(const ValueKey<String>('product-p0')), findsOneWidget, reason: 'каталог из кэша');
      final Finder banner = find.byKey(KioskCatalogKeys.offlineBanner);
      expect(banner, findsOneWidget);
      expect(find.descendant(of: banner, matching: find.byIcon(Icons.wifi_off_rounded)), findsOneWidget);
      await tester.tap(find.text('Фильтры'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('filter-in-stock')), findsOneWidget, reason: 'панель фильтров открыта');
      expect(find.textContaining('данные от'), findsNothing);
      expect(find.textContaining('Фильтры по сохранённым данным'), findsNothing);
    });
  });

  group('T-KIOSK-064 heartbeat ≤ 5 min', () {
    test('T-KIOSK-064: период ≤ 5 мин; запрос — GET /settings/public (не /sync/status) и снимок закрепления', () async {
      expect(KioskHeartbeat.period, lessThanOrEqualTo(const Duration(minutes: 5)));
      final FakeKioskLock lock = FakeKioskLock(locked: true);
      final _Server server = _Server();
      final SessionHarness h = kioskHarness(server.call, lock: lock);
      addTearDown(h.dispose);
      h.start();
      await h.container.read(sessionStatusProvider.future);
      await settle();
      final int statusCalls = lock.count('status');
      await h.container.read(kioskHeartbeatProvider).beat();
      expect(h.adapter.countPath('/settings/public'), 1);
      expect(h.adapter.countPath('/sync/status'), 0);
      expect(h.adapter.requests.last.headers[ApiHeaders.authorization], startsWith('Bearer '), reason: 'last_seen_at');
      expect(h.adapter.requests.last.headers[ApiHeaders.kioskLock], 'on');
      expect(lock.count('status'), statusCalls + 1);
    });

    test(
      'T-KIOSK-064 SCR-51.7: «склад планшета недоступен» — heartbeat шлёт один лёгкий запрос по складу '
      '(GET /catalog/categories?depth=1, не /me), его 2xx возвращает витрину; в прочих состояниях пробы нет',
      () async {
        final _Server server = _Server();
        final SessionHarness h = kioskHarness(
          server.call,
          lock: FakeKioskLock(locked: true),
          overrides: <Override>[
            kioskLifecycleRepositoryProvider.overrideWith((ref) => DioKioskLifecycleRepository(ref.watch(dioProvider))),
          ],
        );
        addTearDown(h.dispose);
        h.start();
        await h.container.read(sessionStatusProvider.future);
        await settle();
        final KioskHeartbeat heartbeat = h.container.read(kioskHeartbeatProvider);
        KioskAccess access() => h.container.read(kioskAccessProvider);
        int probes() => h.adapter.countPath(DioKioskLifecycleRepository.warehouseProbePath);

        await heartbeat.beat();
        expect(probes(), 0, reason: 'обычная работа — пробы нет');

        h.container.read(kioskAccessProvider.notifier).denied(KioskAccess.networkDenied);
        await heartbeat.beat();
        expect(probes(), 0, reason: '«Не в сети магазина» снимает сам ответ /settings/public');
        expect(access(), KioskAccess.allowed);

        final List<RequestOptions> probeCalls = <RequestOptions>[];
        server.other = (RequestOptions o) {
          if (o.path != DioKioskLifecycleRepository.warehouseProbePath) return json(200, <String, Object?>{'ok': true});
          probeCalls.add(o);
          return json(
            403,
            problem('FORBIDDEN', 403, extra: <String, Object?>{'reason': 'kiosk_warehouse_unavailable'}),
          );
        };
        h.container.read(kioskAccessProvider.notifier).denied(KioskAccess.warehouseUnavailable);
        final int me = h.adapter.countPath('/me');
        await heartbeat.beat();
        expect(probes(), 1, reason: 'одна проба за период');
        expect(access(), KioskAccess.warehouseUnavailable, reason: 'склад ещё недоступен — состояние держится');
        expect(probeCalls.single.method, 'GET');
        expect(probeCalls.single.queryParameters, <String, Object?>{'depth': 1});

        server.other = (RequestOptions o) => json(200, <String, Object?>{'ok': true});
        await heartbeat.beat();
        expect(probes(), 2);
        expect(access(), KioskAccess.allowed, reason: 'склад снова доступен — витрина');
        expect(h.adapter.countPath('/me'), me, reason: 'проба — не GET /me');

        await heartbeat.beat();
        expect(probes(), 2, reason: 'витрина — пробы нет');
      },
    );

    test('T-KIOSK-064: без сессии планшета запроса нет; таймер держат экраны режима', () async {
      final SessionHarness h = kioskHarness(_Server().call, lock: FakeKioskLock(), refresh: null);
      addTearDown(h.dispose);
      h.start();
      await h.container.read(sessionStatusProvider.future);
      final KioskHeartbeat heartbeat = h.container.read(kioskHeartbeatProvider);
      await heartbeat.beat();
      expect(h.adapter.countPath('/settings/public'), 0);
      expect(heartbeat.isRunning, isFalse);
      heartbeat
        ..hold()
        ..hold();
      expect(heartbeat.isRunning, isTrue);
      heartbeat.release();
      expect(heartbeat.isRunning, isTrue, reason: 'экран под SCR-52 ещё открыт');
      heartbeat.release();
      expect(heartbeat.isRunning, isFalse);
    });

    testWidgets('T-KIOSK-064: на экране режима запрос уходит каждые 4 мин, после ухода с экрана — нет', (
      WidgetTester tester,
    ) async {
      final _Server server = _Server();
      final (SessionHarness h, GoRouter _) = await _showcase(tester, server);
      final KioskHeartbeat heartbeat = h.container.read(kioskHeartbeatProvider);
      expect(heartbeat.isRunning, isTrue);
      final int before = h.adapter.countPath('/settings/public');
      for (var i = 1; i <= 2; i++) {
        await tester.pump(KioskHeartbeat.period);
        for (var j = 0; j < 20; j++) {
          await tester.pump();
        }
        await tester.runAsync(settle);
        expect(h.adapter.countPath('/settings/public'), greaterThanOrEqualTo(before + i), reason: 'тик $i');
      }
      await tester.pumpWidget(const SizedBox());
      expect(heartbeat.isRunning, isFalse);
    });
  });
}
