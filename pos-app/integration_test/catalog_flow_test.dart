// RM-E-012 п. 2 (13 §3.5), RM-E-009 п. 1, RM-E-017: сквозной путь этапа E на Windows против локального стека
// `pos-api/scripts/local-stack.mjs serve --auth-fixtures --catalog-fixtures` (FakeOnecGateway: фикстуры
// contracts/onec/fixtures + 500 синтетических SKU и фото; на фикстурах, не реальная интеграция).
//
// Сценарии (02 ч. B SCR-10…SCR-14, ч. E SCR-50; 10 CUST-021/022; 12 T-CAT, T-SYNC, T-INV):
//   1. клиент: Splash → SCR-01 → SCR-02 → SCR-03 → SCR-04 → `/home` (SCR-50) → каталог без чисел остатков
//      (`customer_stock_display=status`: в `StockBadge` и в кэше устройства чисел нет) → карточка SCR-14;
//   2. сотрудник (приглашённый продавец): SCR-01 → SCR-02 → SCR-04 (PIN) → SCR-10 → первичная загрузка кэша
//      каталога (`GET /catalog/sync/{entity}` → drift, 07 §11.4) → поиск «F4252» (SCR-11) → карточка SCR-14 →
//      товар с характеристиками: вариант → количество «+» → «В корзину» → строка черновика корзины
//      (`cart_items_draft`) с выбранным вариантом и количеством;
//   3. офлайн (продолжение сценария 2): стек остановлен → каталог SCR-10 из кэша с `OfflineBanner`
//      «Показаны данные от HH:MM» (возраст данных) → карточка SCR-14 из кэша.
//
// Стеком управляет сам тест (нужно остановить его посреди сценария): `setUpAll` запускает
// `node scripts/local-stack.mjs serve --auth-fixtures --catalog-fixtures --exit-on-stdin-end`, офлайн-шаг и
// `tearDownAll` закрывают stdin (штатная остановка API, прокси и PostgreSQL). Требуется `npm run build` в pos-api.
//
//   cd pos-api && npm run build
//   cd pos-app && flutter test integration_test/catalog_flow_test.dart -d windows --dart-define-from-file=env/dev_proxy.json --dart-define-from-file=env/local.json
//
// `env/dev_proxy.json` — API через мини-прокси :8080 (фото `/images/{sha}/{size}`); с `env/dev.json` (:3000) фото
// отдают 404 и показывается заглушка. Номера и код — `AUTH_FIXTURES` стека (+99677700090N, синтетические);
// телефоны и код в лог не выводятся (11 SEC-062). Каталог стека `E2E_API_DIR` (по умолчанию ищется `pos-api`
// рядом с pos-app).
@Timeout(Duration(minutes: 20))
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:optomstroy/app/bootstrap.dart';
import 'package:optomstroy/app/router/shells/app_shell.dart';
import 'package:optomstroy/core/config/app_data_directory.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/design_system/components/stock_badge.dart';
import 'package:optomstroy/features/auth/presentation/screens/no_session_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/otp_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/phone_screen.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/catalog/presentation/screens/customer_home_view.dart';
import 'package:optomstroy/features/registration/presentation/screens/registration_form_screen.dart';
import 'package:optomstroy/features/registration/presentation/screens/registration_security_screen.dart';
import 'package:optomstroy/features/splash/presentation/screens/splash_screen.dart';

/// Тестовый код OTP контура (`AUTH_FIXTURES.otpCode`).
const String _otpCode = String.fromEnvironment('E2E_OTP_CODE', defaultValue: '246810');

/// Национальные номера (9 цифр) из `AUTH_FIXTURES`: приглашённый продавец и клиент (`customerSmoke`).
const String _staffPhone = String.fromEnvironment('E2E_STAFF_PHONE', defaultValue: '777000902');
const String _customerPhone = String.fromEnvironment('E2E_CUSTOMER_PHONE', defaultValue: '777000905');

/// Каталог pos-api (local-stack.mjs); пусто — поиск `pos-api` вверх от рабочего каталога и exe.
const String _apiDirDefine = String.fromEnvironment('E2E_API_DIR');

/// Синтетических SKU стека.
const String _catalogSku = String.fromEnvironment('E2E_CATALOG_SKU', defaultValue: '500');

const Key _catalogRoot = ValueKey<String>('stub-SCR-10');
const Key _searchField = ValueKey<String>('catalog-search-field');
const Key _productScreen = ValueKey<String>('scr-14');

final _LocalStack _stack = _LocalStack();

// ---------------------------------------------------------------------------
// Локальный стек: запуск, ожидание готовности, штатная остановка
// ---------------------------------------------------------------------------

final class _LocalStack {
  Process? _process;
  IOSink? _log;
  Future<int>? _exit;

  static Directory _apiDir() {
    if (_apiDirDefine.isNotEmpty) return Directory(_apiDirDefine);
    final List<Directory> starts = <Directory>[Directory.current, File(Platform.resolvedExecutable).parent];
    for (final Directory start in starts) {
      Directory d = start.absolute;
      for (int i = 0; i < 10; i++) {
        final Directory candidate = Directory('${d.path}${Platform.pathSeparator}pos-api');
        if (File(
          '${candidate.path}${Platform.pathSeparator}scripts${Platform.pathSeparator}local-stack.mjs',
        ).existsSync()) {
          return candidate;
        }
        if (d.parent.path == d.path) break;
        d = d.parent;
      }
    }
    throw StateError('pos-api не найден: задайте --dart-define=E2E_API_DIR=<путь к pos-api>');
  }

  static String _tmp() => Platform.environment['TEMP'] ?? Directory.systemTemp.path;

  Future<void> start() async {
    final Directory api = _apiDir();
    final String sep = Platform.pathSeparator;
    final File ready = File('${_tmp()}${sep}catalog_flow_ready_${DateTime.now().millisecondsSinceEpoch}.txt');
    final File logFile = File('${_tmp()}${sep}catalog_flow_stack.log');
    _log = logFile.openWrite();
    final Process p = await Process.start(
      'node',
      <String>[
        'scripts/local-stack.mjs',
        'serve',
        '--auth-fixtures',
        '--catalog-fixtures=$_catalogSku',
        '--ready-file',
        ready.path,
        '--exit-on-stdin-end',
      ],
      workingDirectory: api.path,
      environment: <String, String>{'LOCAL_STACK_MIN_APP_VERSION': 'android=0.1.0,windows=0.1.0'},
    );
    _process = p;
    p.stdout.listen(_log!.add);
    p.stderr.listen(_log!.add);
    _exit = p.exitCode;
    final DateTime deadline = DateTime.now().add(const Duration(minutes: 8));
    bool exited = false;
    unawaited(_exit!.then((_) => exited = true));
    while (!ready.existsSync()) {
      if (exited) throw StateError('local-stack завершился до готовности; журнал: ${logFile.path}');
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('local-stack не поднялся за 8 мин; журнал: ${logFile.path}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    ready.deleteSync();
    debugPrint('catalog_flow_test: локальный стек готов (журнал ${logFile.path})');
  }

  /// Штатная остановка (`--exit-on-stdin-end`): API, прокси и PostgreSQL; затем порт API закрыт.
  Future<void> stop() async {
    final Process? p = _process;
    if (p == null) return;
    _process = null;
    await p.stdin.close();
    final int code = await _exit!.timeout(
      const Duration(minutes: 2),
      onTimeout: () {
        // Аварийно: дерево процессов (node → pos-api, postgres).
        Process.runSync('taskkill', <String>['/PID', '${p.pid}', '/T', '/F']);
        return -1;
      },
    );
    await _log?.flush();
    await _log?.close();
    _log = null;
    debugPrint('catalog_flow_test: локальный стек остановлен (код $code)');
  }
}

// ---------------------------------------------------------------------------
// Общие шаги (как auth_flow_test.dart)
// ---------------------------------------------------------------------------

Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail('не дождались ${finder.describeMatch(Plurality.one)} за ${timeout.inSeconds} с; экран: ${_where(tester)}');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Ждёт выполнения [condition] (асинхронная проверка, например запрос к drift), прокачивая кадры.
Future<T> pumpUntil<T>(
  WidgetTester tester,
  Future<T?> Function() condition, {
  required String what,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (true) {
    final T? value = await tester.runAsync<T?>(condition);
    if (value != null && value != false) return value;
    if (DateTime.now().isAfter(deadline)) {
      fail('не дождались: $what за ${timeout.inSeconds} с; экран: ${_where(tester)}');
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _settle(WidgetTester tester, {int frames = 10}) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Текущий адрес с учётом `push` (SCR-14 открывается поверх списка): адрес последнего императивного маршрута.
String _where(WidgetTester tester) {
  final GoRouter? router = _router(tester);
  if (router == null) return '—';
  final RouteMatchList cfg = router.routerDelegate.currentConfiguration;
  final RouteMatch? last = cfg.lastOrNull;
  return last is ImperativeRouteMatch ? last.matches.uri.toString() : cfg.uri.toString();
}

GoRouter? _router(WidgetTester tester) {
  final Iterable<Element> nav = find.byType(Navigator).evaluate();
  return nav.isEmpty ? null : GoRouter.maybeOf(nav.first);
}

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(AppShell)));

Finder _input(Key key) => find.descendant(of: find.byKey(key), matching: find.byType(EditableText));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _enterPin(WidgetTester tester, String pin) async {
  for (final String d in pin.split('')) {
    final Finder label = find.descendant(of: find.byType(PinField).first, matching: find.text(d));
    final Finder key = find.ancestor(of: label.last, matching: find.byType(AnimatedContainer)).first;
    await Scrollable.ensureVisible(tester.element(key), alignment: 0.5);
    await tester.pump();
    await tester.tap(key);
    await tester.pump(const Duration(milliseconds: 80));
  }
  await _settle(tester);
}

Future<void> _expectCompleteEnabled(WidgetTester tester) => pumpUntilFound(
  tester,
  find.byWidgetPredicate(
    (Widget w) => w is AppButton && w.key == RegistrationSecurityScreen.completeKey && w.onPressed != null,
  ),
  timeout: const Duration(seconds: 10),
);

Future<void> _cleanStart(WidgetTester tester) async {
  await FlutterSecureStorageAdapter().deleteAll(<SecureKey>[...SecureKey.session, ...SecureKey.registration]);
  await bootstrap();
  await tester.pump();
  await pumpUntilFound(tester, find.byKey(SplashScreen.screenKey));
  await pumpUntilFound(tester, find.byKey(NoSessionScreen.screenKey));
}

Future<void> _phoneAndOtp(WidgetTester tester, String nationalPhone) async {
  await pumpUntilFound(tester, find.byKey(PhoneScreen.fieldKey));
  await tester.enterText(_input(PhoneScreen.fieldKey), nationalPhone);
  await tester.pump();
  await _tap(tester, find.byKey(PhoneScreen.submitKey));
  await pumpUntilFound(tester, find.byKey(OtpScreen.screenKey));
  await tester.enterText(
    find.descendant(of: find.byKey(OtpScreen.screenKey), matching: find.byType(EditableText)),
    _otpCode,
  );
  await tester.pump();
}

/// БД пользователя (открыта корнем после входа).
AppDatabase _db(WidgetTester tester) {
  final AppDatabase? db = _container(tester).read(appDatabaseProvider);
  if (db == null) fail('БД пользователя не открыта после входа');
  return db;
}

/// Первичная загрузка кэша каталога завершена (07 §11.4; `catalog_full_loaded_at` / все сущности).
Future<void> _waitCatalogCache(WidgetTester tester) async {
  final Stopwatch sw = Stopwatch()..start();
  await pumpUntil<bool>(
    tester,
    () async => _container(tester).read(catalogFreshnessProvider).fullyLoaded ? true : null,
    what: 'первичная загрузка кэша каталога',
    timeout: const Duration(minutes: 5),
  );
  final int products = await tester.runAsync(() => _db(tester).catalogDao.productCount()) ?? 0;
  debugPrint('catalog_flow_test: кэш каталога загружен за ${sw.elapsedMilliseconds} мс, товаров: $products');
  // Генератор стека выдаёт N SKU вместе с фикстурами 1С (часть позиций — папки/служебные); ориентир — не меньше 90 %.
  expect(
    products,
    greaterThanOrEqualTo(int.parse(_catalogSku) * 9 ~/ 10),
    reason: 'синтетические SKU + фикстуры 1С в drift',
  );
}

Future<String> _productIdBySku(WidgetTester tester, String sku) async {
  final List<String> rows =
      await tester.runAsync(
        () async =>
            (await _db(tester)
                    .customSelect(
                      'SELECT id FROM products WHERE sku = ? AND deletion_mark = 0',
                      variables: [Variable<String>(sku)],
                    )
                    .get())
                .map((r) => r.read<String>('id'))
                .toList(),
      ) ??
      const <String>[];
  expect(rows, hasLength(1), reason: 'товар $sku в кэше');
  return rows.single;
}

/// Поиск из шапки SCR-10/SCR-11: ввод → Enter → результаты содержат карточку товара.
Future<void> _search(WidgetTester tester, String query, String productId) async {
  final Finder field = find.descendant(of: find.byKey(_searchField), matching: find.byType(EditableText));
  await pumpUntilFound(tester, field);
  await tester.tap(field.first);
  await tester.pump();
  await tester.enterText(field.first, query);
  await tester.pump();
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await _settle(tester, frames: 5);
  await pumpUntilFound(tester, find.byKey(ValueKey<String>('product-$productId')));
  expect(_where(tester), startsWith('/catalog/search'), reason: 'SCR-11 результаты поиска');
}

Future<void> _openProduct(WidgetTester tester, String productId) async {
  await _tap(tester, find.byKey(ValueKey<String>('product-$productId')).first);
  await pumpUntilFound(tester, find.byKey(_productScreen));
  await pumpUntilFound(tester, find.byKey(const ValueKey<String>('product-name')));
  expect(_where(tester), contains('/catalog/p/$productId'));
}

/// Товар с ≥ 2 вариантами в наличии на складе по умолчанию и с ценой; вариант — не по умолчанию.
Future<({String productId, String sku, String variantId, String variantName})> _variantProduct(
  WidgetTester tester,
) async {
  final AppDatabase db = _db(tester);
  final List<({String productId, String sku, String variantId, String variantName})> rows =
      await tester.runAsync(() async {
        final String? warehouse = await db.catalogDao.defaultWarehouseId();
        final List<QueryRow> res = await db
            .customSelect(
              'SELECT p.id AS pid, p.sku AS sku, v.id AS vid, v.name AS vname FROM products p '
              'JOIN product_variants v ON v.product_id = p.id AND v.deletion_mark = 0 AND v.is_default = 0 '
              'JOIN stock_balances s ON s.variant_id = v.id AND s.warehouse_id = ? AND s.available_milli >= 10000 '
              'WHERE p.deletion_mark = 0 AND p.has_variants = 1 AND p.is_sellable = 1 '
              'AND EXISTS (SELECT 1 FROM prices pr WHERE pr.variant_id = v.id) '
              'AND (SELECT COUNT(*) FROM product_variants v2 WHERE v2.product_id = p.id AND v2.deletion_mark = 0) >= 2 '
              'AND (SELECT COUNT(*) FROM products p2 WHERE p2.sku = p.sku) = 1 '
              'ORDER BY p.sku LIMIT 1',
              variables: [Variable<String>(warehouse ?? '')],
            )
            .get();
        return <({String productId, String sku, String variantId, String variantName})>[
          for (final QueryRow r in res)
            (
              productId: r.read<String>('pid'),
              sku: r.read<String>('sku'),
              variantId: r.read<String>('vid'),
              variantName: r.read<String>('vname'),
            ),
        ];
      }) ??
      const <({String productId, String sku, String variantId, String variantName})>[];
  expect(rows, isNotEmpty, reason: 'в синтетическом каталоге есть товар с характеристиками в наличии');
  return rows.first;
}

Future<List<CartDraftLine>> _draftLines(WidgetTester tester) async {
  final List<CartDraftLine>? lines = await tester.runAsync(() async {
    final result = await _container(tester).read(cartDraftRepositoryProvider).lines();
    return result.fold((List<CartDraftLine> l) => l, (_) => const <CartDraftLine>[]);
  });
  return lines ?? const <CartDraftLine>[];
}

/// Ожидание завершения сетевых повторов приложения (реальное время, кадры прокачиваются).
Future<void> _settleNetwork(WidgetTester tester, {Duration duration = const Duration(seconds: 16)}) async {
  final DateTime until = DateTime.now().add(duration);
  while (DateTime.now().isBefore(until)) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

final RegExp _digit = RegExp(r'\d');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Данные приложения — в APP_DATA_DIR из env/local.json (машина разработки, вне git; не %APPDATA% на C:), до
  // первого обращения к ним. Без APP_DATA_DIR — каталог ОС.
  AppDataDirectory.apply(AppConfig.fromEnvironment());

  setUpAll(_stack.start);
  tearDownAll(_stack.stop);

  testWidgets('RM-E-017: клиент — вход → /home → каталог без чисел остатков (status) → карточка', (tester) async {
    await _cleanStart(tester);
    await _phoneAndOtp(tester, _customerPhone);

    // Регистрация клиента (SCR-03 → SCR-04), как auth_flow_test.
    await pumpUntilFound(tester, find.byKey(RegistrationFormScreen.screenKey));
    await _settle(tester);
    await tester.enterText(_input(RegistrationFormScreen.nameFieldKey), 'Тестов Покупатель');
    await tester.pump();
    await tester.enterText(_input(RegistrationFormScreen.yearFieldKey), '1992');
    await tester.pump();
    await _tap(tester, find.byKey(RegistrationFormScreen.pdAckKey));
    await _tap(tester, find.byKey(RegistrationFormScreen.continueKey));
    await pumpUntilFound(tester, find.byKey(RegistrationSecurityScreen.screenKey));
    await pumpUntilFound(tester, find.byType(PinField));
    await _settle(tester);
    await _enterPin(tester, '5173');
    await _enterPin(tester, '5173');
    await _expectCompleteEnabled(tester);
    await _tap(tester, find.byKey(RegistrationSecurityScreen.completeKey));

    // SCR-50 — главный экран клиента с каталогом.
    await pumpUntilFound(tester, find.byKey(CustomerHomeKeys.root), timeout: const Duration(seconds: 60));
    expect(_where(tester), startsWith('/home'));
    await _waitCatalogCache(tester);

    final Finder cards = find.byWidgetPredicate(
      (Widget w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('product-'),
    );
    await pumpUntilFound(tester, cards, timeout: const Duration(seconds: 60));
    await pumpUntilFound(tester, find.byType(StockBadge));

    // customer_stock_display=status (по умолчанию): только статус наличия, без чисел (10 CUST-022, 08 API-180).
    final List<String> labels = tester.widgetList<StockBadge>(find.byType(StockBadge)).map((s) => s.label).toList();
    expect(labels, isNotEmpty);
    for (final String l in labels) {
      expect(_digit.hasMatch(l), isFalse, reason: 'StockBadge клиента без числа: «$l»');
    }
    // Сервер исключает количества и из выгрузки кэша (field-level): в drift только stock_level.
    final int withNumbers =
        await tester.runAsync(
          () async =>
              (await _db(tester)
                      .customSelect(
                        'SELECT COUNT(*) AS n FROM stock_balances '
                        'WHERE available_milli IS NOT NULL OR quantity_milli IS NOT NULL OR reserved_milli IS NOT NULL',
                      )
                      .getSingle())
                  .read<int>('n'),
        ) ??
        -1;
    expect(withNumbers, 0, reason: 'кэш остатков клиента без чисел');

    // Карточка SCR-14 клиента: бейдж наличия без числа.
    final String firstKey = (tester.widget(cards.first).key! as ValueKey<String>).value;
    final String productId = firstKey.substring('product-'.length);
    await _openProduct(tester, productId);
    final Finder badge = find.descendant(
      of: find.byKey(const ValueKey<String>('product-stock-badge')),
      matching: find.byType(StockBadge),
    );
    if (badge.evaluate().isNotEmpty) {
      expect(_digit.hasMatch(tester.widget<StockBadge>(badge.first).label), isFalse);
    }
  });

  testWidgets(
    'RM-E-012 п. 2, RM-E-009 п. 1: сотрудник — загрузка кэша → поиск → карточка → вариант → количество → черновик; '
    'офлайн — каталог и карточка из кэша с баннером и возрастом данных',
    (tester) async {
      await _cleanStart(tester);
      await _phoneAndOtp(tester, _staffPhone);

      // Первый вход сотрудника по приглашению: SCR-04 без формы SCR-03 (RM-D-017).
      await pumpUntilFound(tester, find.byKey(RegistrationSecurityScreen.screenKey));
      await pumpUntilFound(tester, find.byType(PinField));
      await _settle(tester);
      await _enterPin(tester, '582914');
      await _enterPin(tester, '582914');
      if (find.byKey(RegistrationSecurityScreen.pdAckKey).evaluate().isNotEmpty) {
        await _tap(tester, find.byKey(RegistrationSecurityScreen.pdAckKey));
      }
      await _expectCompleteEnabled(tester);
      await _tap(tester, find.byKey(RegistrationSecurityScreen.completeKey));

      // SCR-10 и первичная загрузка кэша (NFR-PERF-006: индикатор «Загружаем каталог… N %» в оболочке).
      await pumpUntilFound(tester, find.byKey(_catalogRoot), timeout: const Duration(seconds: 60));
      expect(_where(tester), startsWith('/catalog'));
      await _waitCatalogCache(tester);

      // Поиск по артикулу (SCR-11) → карточка (SCR-14) якорного товара.
      final String anchorId = await _productIdBySku(tester, 'F4252');
      await _search(tester, 'F4252', anchorId);
      final List<String> staffBadges = tester
          .widgetList<StockBadge>(find.byType(StockBadge))
          .map((s) => s.label)
          .toList();
      debugPrint('catalog_flow_test: бейджи наличия сотрудника: ${staffBadges.length}');
      await _openProduct(tester, anchorId);
      expect(find.textContaining('F4252'), findsWidgets);

      // Товар с характеристиками: поиск по артикулу → карточка → вариант (не по умолчанию).
      final ({String productId, String sku, String variantId, String variantName}) vp = await _variantProduct(tester);
      _router(tester)!.go('/catalog');
      await pumpUntilFound(tester, find.byKey(_catalogRoot));
      await _settle(tester);
      await _search(tester, vp.sku, vp.productId);
      await _openProduct(tester, vp.productId);
      final Finder option = find.byWidgetPredicate(
        (Widget w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('variant-option-') &&
            (w.key! as ValueKey<String>).value.endsWith('-${vp.variantName}'),
      );
      await pumpUntilFound(tester, option);
      await _tap(tester, option.first);
      await _settle(tester, frames: 5);
      await pumpUntilFound(
        tester,
        find.byWidgetPredicate(
          (Widget w) => w is AppButton && w.key == const ValueKey<String>('product-cta') && w.onPressed != null,
        ),
      );

      // Количество: «+» на шаг (QuantityStepper) → значение растёт.
      final Finder value = find.descendant(
        of: find.byKey(const ValueKey<String>('product-quantity-stepper')),
        matching: find.byKey(const ValueKey<String>('quantity-stepper-value')),
      );
      String valueText() => tester
          .widgetList<Text>(find.descendant(of: value.first, matching: find.byType(Text)))
          .map((t) => t.data ?? '')
          .join();
      final String before = valueText();
      await _tap(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey<String>('product-quantity-stepper')),
          matching: find.byKey(const ValueKey<String>('quantity-stepper-increment')),
        ),
      );
      await _settle(tester, frames: 3);
      final String after = valueText();
      expect(after, isNot(before), reason: '«+» увеличивает количество ($before → $after)');

      // «В корзину» → строка черновика с выбранным вариантом и количеством.
      await _tap(tester, find.byKey(const ValueKey<String>('product-cta')));
      await pumpUntilFound(tester, find.byKey(const ValueKey<String>('product-in-cart')));
      final List<CartDraftLine> lines = await _draftLines(tester);
      final CartDraftLine line = lines.firstWhere(
        (CartDraftLine l) => l.variantId == vp.variantId,
        orElse: () => fail('в черновике нет строки выбранного варианта; строк: ${lines.length}'),
      );
      expect(line.quantity.milli, greaterThan(0));
      debugPrint('catalog_flow_test: черновик — строк ${lines.length}, вариант выбран, количество «$after»');

      // Офлайн: стек остановлен. Первое же действие пользователя (поиск) не достаёт сервер → ответ из кэша
      // устройства с пометкой (SCR-11 `search-offline-note`), сеть помечается `offline`.
      await tester.runAsync(_stack.stop);
      _router(tester)!.go('/catalog');
      await pumpUntilFound(tester, find.byKey(_catalogRoot));
      await _settle(tester);
      final String offlineId = await _productIdBySku(tester, 'F3241');
      await _search(tester, 'F3241', offlineId);
      await pumpUntilFound(tester, find.byKey(const ValueKey<String>('search-offline-note')));
      // SCR-10 из кэша: `OfflineBanner` «Показаны данные от HH:MM» (возраст данных) → карточка из кэша.
      _router(tester)!.go('/catalog');
      await pumpUntilFound(tester, find.byKey(_catalogRoot));
      final Finder banner = find.descendant(
        of: find.byKey(const ValueKey<String>('catalog-offline-banner')),
        matching: find.byType(OfflineBanner),
      );
      await pumpUntilFound(tester, banner, timeout: const Duration(seconds: 60));
      final OfflineBanner b = tester.widget<OfflineBanner>(banner.first);
      expect(b.variant, OfflineBannerVariant.offline);
      expect(b.dataAsOf, isNotNull, reason: 'возраст данных «Показаны данные от HH:MM»');
      final Finder cached = find.byWidgetPredicate(
        (Widget w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('product-'),
      );
      await pumpUntilFound(tester, cached);
      debugPrint(
        'catalog_flow_test: офлайн — баннер с возрастом данных, карточек из кэша: ${cached.evaluate().length}',
      );
      final String cachedKey = (tester.widget(cached.first).key! as ValueKey<String>).value;
      await _openProduct(tester, cachedKey.substring('product-'.length));
      // Этап F: строка черновика уходит в `cart.sync` (PUT /cart/items), и при остановленном стеке клиент повторяет
      // запрос (RetryInterceptor 1/2/4 с). Тест ждёт окончания повторов: иначе закрытие приложения в конце теста
      // отменяет незавершённое соединение, и ошибка `Connection attempt cancelled` уходит в зону теста (RM-F-011).
      await _settleNetwork(tester);
    },
  );
}
