// Независимая проверка экрана выбора товаров (SCR-10/11/12) на настоящем окне Windows против локального стека
// `pos-api/scripts/local-stack.mjs serve --auth-fixtures --catalog-fixtures --pos-fixtures` (фикстуры 1С + 500
// синтетических SKU и фото; на фикстурах, не реальная интеграция). Задание заказчика 2026-10-28; перенос дизайна по
// утверждённому прототипу 2026-10-29 (ADR-111 — палитра, ADR-112 — шапка, навигация, каталог, корзина-drawer).
//
// Снимки окна приложения: слой корня (`RenderView` — граница перерисовки корня) → `toImage` → PNG в
// `E2E_SHOTS_DIR` (по умолчанию D:/optomstroy/.tmp/catalog_shots). Стек поднимает сам тест (`setUpAll`) и
// останавливает в `tearDownAll`; порты стека — 3000 (API), 8080/8091/8092 (`LOCAL_STACK_*`).
//
// 1. QA-снимки по прототипу (`E2E_SIZES`, по умолчанию 1440x1180,1280x900,1024x800; пустая строка — пропустить):
//    DPR 1, окно ровно Ш×В, PNG ровно Ш×В; имена `app_<состояние>_<Ш>x<В>.png`. Состояние (a) `default` — на всех
//    размерах; остальные — на 1440x1180 (если его нет в списке — на первом):
//      (a) default      — корень с наибольшим числом подкатегорий с картинкой, «Сетка», корзина пуста ↔ proto_default
//                         (1280x900 ↔ proto_1280, 1024x800 ↔ proto_1024);
//      (b) list         — «Список» ↔ proto_list;           (c) compact — «Компакт» ↔ proto_compact;
//      (d) filters      — встроенная панель + «Только в наличии» ↔ proto_filters;
//      (e) heating      — корень, у подкатегорий которого нет картинок (плитки-заглушки) ↔ proto_heating;
//      (g) nav_drawer   — «бургер» → drawer навигации (в прототипе нет);
//      (h) toast        — сразу после «+ Добавить»: «Добавлено: <название>» (в прототипе нет);
//      (f) cart         — 3 товара (один дважды: «В корзине · 2 — ещё +1»), ответ сервера, drawer по кнопке шапки
//                         ↔ proto_cart; затем Esc — drawer закрыт;
//      (i) orders_header — `/orders`: шапка оболочки вне каталога (в прототипе нет);
//      (j) sidebar_collapsed — колонка категорий свёрнута до 72 (на всех размерах; паритет функций ADR-112), на
//                         основном окне — и `sidebar_collapsed_tooltip` (наведение на плитку); затем снова 132;
//      header_cart      — шапка с непустой корзиной и часами с датой на всех размерах (перед drawer из (f)).
//    Геометрия шапки (поле поиска ≥ 240, корзина, часы и дата UI-10-005/UI-10-032, колокольчик, аватар — без
//    наложений) — в отчёт для default, header_cart и orders_header.
//    Сверяются компоновка, размеры и цвета, не данные (данные — фикстуры стека). Склейка с прототипом и маска
//    различий — D:/optomstroy/.tmp/design_port/compare.py (вне репозитория).
// 2. Регрессия переноса: кадры смены категории/подкатегории/поиска (шапка, колонка категорий и кнопка корзины в
//    шапке на месте, экземпляр экрана тот же, фон не белеет), данные карточек против `GET /catalog/products` (цена,
//    артикул, остаток), сортировка, фильтр, виды, узкое окно, «+ Добавить» без дублей, строка в drawer корзины.
//
//   export TEMP=D:/optomstroy/.tmp TMP=D:/optomstroy/.tmp
//   cd pos-api && npm run build
//   cd pos-app && flutter test integration_test/catalog_screenshots_test.dart -d windows \
//     --dart-define-from-file=env/dev_proxy.json --dart-define-from-file=env/local.json \
//     --dart-define=E2E_SHOTS_DIR=D:/optomstroy/.tmp/catalog_shots --dart-define=E2E_SIZES=1440x1180,1280x900,1024x800
//   rm -rf .dart_tool/flutter_build   # место на диске (Windows-сборка)
@Timeout(Duration(minutes: 40))
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:optomstroy/app/bootstrap.dart';
import 'package:optomstroy/app/router/shells/app_shell.dart';
import 'package:optomstroy/app/router/shells/staff_shell_header.dart';
import 'package:optomstroy/core/config/app_data_directory.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/notification_bell.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/design_system/components/product_card.dart';
import 'package:optomstroy/design_system/components/search_bar.dart' as ds;
import 'package:optomstroy/design_system/components/stock_badge.dart';
import 'package:optomstroy/design_system/components/sync_indicator.dart';
import 'package:optomstroy/design_system/components/top_app_bar_cart_button.dart';
import 'package:optomstroy/design_system/components/top_app_bar_pos.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/auth/presentation/screens/no_session_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/otp_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/phone_screen.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_controller.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_drawer.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_header_button_view.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/presentation/providers/category_tree_provider.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_header.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_workspace.dart';
import 'package:optomstroy/features/registration/presentation/screens/registration_security_screen.dart';
import 'package:optomstroy/features/splash/presentation/screens/splash_screen.dart';

const String _otpCode = String.fromEnvironment('E2E_OTP_CODE', defaultValue: '246810');
const String _sellerPhone = String.fromEnvironment('E2E_STAFF_PHONE', defaultValue: '777000902');
const String _sellerPin = '582914';
const String _apiDirDefine = String.fromEnvironment('E2E_API_DIR');
const String _catalogSku = String.fromEnvironment('E2E_CATALOG_SKU', defaultValue: '500');
const String _shotsDir = String.fromEnvironment('E2E_SHOTS_DIR', defaultValue: 'D:/optomstroy/.tmp/catalog_shots');

/// Размеры окна QA-снимков (логические = физические пиксели, DPR 1): «ШxВ» через запятую; пусто — без QA-снимков.
const String _sizes = String.fromEnvironment('E2E_SIZES', defaultValue: '1440x1180,1280x900,1024x800');

/// Окно полного набора QA-состояний (прототип отрисован в 1440×1180).
const Size _qaFullSize = Size(1440, 1180);

/// Размер окна регрессии (логические пиксели): основной — типичный монитор кассы; узкий — меньше колонок.
const Size _mainSize = Size(1366, 768);
const Size _narrowSize = Size(1100, 768);
const Size _mediumSize = Size(820, 768);

const Key _catalogRoot = ValueKey<String>('stub-SCR-10');
const Key _categoryRoot = ValueKey<String>('stub-SCR-12');
const Key _searchRoot = ValueKey<String>('stub-SCR-11');
const Key _ordersRoot = ValueKey<String>('stub-SCR-25');
const Key _sidebar = ValueKey<String>('catalog-sidebar');
const Key _products = ValueKey<String>('catalog-products');
const Key _ribbon = ValueKey<String>('catalog-subcategory-ribbon');
const Key _skeleton = ValueKey<String>('catalog-skeleton');
const Key _productView = ValueKey<String>('catalog-product-view');
const Key _filtersButton = ValueKey<String>('catalog-filters-button');
const Key _filterPanel = ValueKey<String>('catalog-filter-panel');
const Key _inStock = ValueKey<String>('filter-in-stock');
const Key _menuButton = ValueKey<String>('top-app-bar-menu');
const Key _navDrawer = ValueKey<String>('shell-nav-drawer');
const Key _ribbonPlaceholder = ValueKey<String>('category-tile-placeholder');

final _LocalStack _stack = _LocalStack();

/// Итоги проверки (пишутся в report.txt и в лог); непустой [_problems] — тест падает в конце.
final List<String> _report = <String>[];
final List<String> _problems = <String>[];
final List<String> _console = <String>[];

/// QA-снимки: «app_….png ↔ proto_….png» (раздел в конце report.txt).
final List<String> _qaIndex = <String>[];

void _note(String s) {
  _report.add(s);
  debugPrint('SHOTS: $s');
}

void _problem(String s) {
  _problems.add(s);
  _note('ПРОБЛЕМА: $s');
}

// ---------------------------------------------------------------------------
// Локальный стек (как catalog_flow_test.dart)
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
    final File ready = File('${_tmp()}${sep}catalog_shots_ready_${DateTime.now().millisecondsSinceEpoch}.txt');
    final File logFile = File('${_tmp()}${sep}catalog_shots_stack.log');
    _log = logFile.openWrite();
    final Process p = await Process.start(
      'node',
      <String>[
        'scripts/local-stack.mjs',
        'serve',
        '--auth-fixtures',
        '--catalog-fixtures=$_catalogSku',
        '--pos-fixtures',
        '--ready-file',
        ready.path,
        '--exit-on-stdin-end',
      ],
      workingDirectory: api.path,
      environment: <String, String>{
        'LOCAL_STACK_MIN_APP_VERSION': 'android=0.1.0,windows=0.1.0',
        'LOCAL_STACK_LOG_DIR': '${_tmp()}${sep}catalog_shots_logs',
      },
    );
    _process = p;
    p.stdout.listen(_log!.add);
    p.stderr.listen(_log!.add);
    _exit = p.exitCode;
    final DateTime deadline = DateTime.now().add(const Duration(minutes: 10));
    bool exited = false;
    unawaited(_exit!.then((_) => exited = true));
    while (!ready.existsSync()) {
      if (exited) throw StateError('local-stack завершился до готовности; журнал: ${logFile.path}');
      if (DateTime.now().isAfter(deadline)) throw StateError('local-stack не поднялся за 10 мин; ${logFile.path}');
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    ready.deleteSync();
    debugPrint('catalog_screenshots_test: стек готов (журнал ${logFile.path})');
  }

  Future<void> stop() async {
    final Process? p = _process;
    if (p == null) return;
    _process = null;
    await p.stdin.close();
    final int code = await _exit!.timeout(
      const Duration(minutes: 2),
      onTimeout: () {
        Process.runSync('taskkill', <String>['/PID', '${p.pid}', '/T', '/F']);
        return -1;
      },
    );
    await _log?.flush();
    await _log?.close();
    _log = null;
    debugPrint('catalog_screenshots_test: стек остановлен (код $code)');
  }
}

// ---------------------------------------------------------------------------
// Общие шаги
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

/// Кадры по 100 мс, пока [condition] не выполнится; `false` — не дождались за [timeout] (без падения теста).
Future<bool> _until(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  bool ok() {
    try {
      return condition();
    } on StateError {
      // `first`/`single` на пустом наборе — дерево перестраивается: «ещё нет».
      return false;
    }
  }

  final DateTime deadline = DateTime.now().add(timeout);
  while (!ok()) {
    if (DateTime.now().isAfter(deadline)) return false;
    await tester.pump(const Duration(milliseconds: 100));
  }
  return true;
}

Future<void> _settle(WidgetTester tester, {int frames = 10}) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Реальное время с прокачкой кадров (загрузка фото, сеть).
Future<void> _wait(WidgetTester tester, Duration d) async {
  final DateTime until = DateTime.now().add(d);
  while (DateTime.now().isBefore(until)) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Конец анимаций: кадры по 50 мс, пока движок не перестанет планировать кадры (3 раза подряд), но не дольше
/// [max] (мигающий курсор, индикаторы загрузки). `false` — анимация не закончилась за [max].
Future<bool> _quiet(WidgetTester tester, {Duration max = const Duration(seconds: 3)}) async {
  final DateTime deadline = DateTime.now().add(max);
  int idle = 0;
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
    if (tester.binding.hasScheduledFrame) {
      idle = 0;
    } else if (++idle >= 3) {
      return true;
    }
  }
  return false;
}

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

/// Нажатие после окончания перехода страницы (экраны входа — Zoom на Windows): ждём, пока элемент в точке нажатия
/// станет целью hit-test (как catalog_flow_test).
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await pumpUntilFound(tester, finder);
  await tester.ensureVisible(finder.first);
  await tester.pump();
  // `first`-поисковик бросает StateError на пустом наборе (список перестраивается) — считаем «ещё не готово».
  bool hittable() {
    try {
      return finder.hitTestable().evaluate().isNotEmpty;
    } on StateError {
      return false;
    }
  }

  final DateTime deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!hittable()) {
    if (DateTime.now().isAfter(deadline)) {
      // Что перекрывает элемент: слой сессии (SCR-08/SCR-90/step-up) или другой экран — тексты на экране.
      final List<String> texts = <String>[
        for (final Text t in tester.widgetList<Text>(find.byType(Text))) ?t.data,
      ].take(40).toList();
      fail(
        'элемент ${finder.describeMatch(Plurality.one)} не принимает нажатие 15 с; экран: ${_where(tester)}; '
        'слой сессии: ${find.byKey(const Key('session-gate-scrim')).evaluate().isNotEmpty}; тексты: $texts',
      );
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.tap(finder.hitTestable().first);
  await tester.pump();
}

/// Нажатие без прокрутки: `ensureVisible` выравнивает цель по верхнему краю и сдвигает список (заголовок и лента
/// уходят из кадра). Видимый элемент нажимается на месте; невидимый — как [_tap].
Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await pumpUntilFound(tester, finder);
  if (!await _until(tester, () => finder.hitTestable().evaluate().isNotEmpty, timeout: const Duration(seconds: 5))) {
    await _tap(tester, finder);
    return;
  }
  await tester.tap(finder.hitTestable().first);
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

AppDatabase _db(WidgetTester tester) {
  final AppDatabase? db = _container(tester).read(appDatabaseProvider);
  if (db == null) fail('БД пользователя не открыта после входа');
  return db;
}

Future<void> _staffLogin(WidgetTester tester) async {
  await FlutterSecureStorageAdapter().deleteAll(<SecureKey>[...SecureKey.session, ...SecureKey.registration]);
  await bootstrap();
  await tester.pump();
  await pumpUntilFound(tester, find.byKey(SplashScreen.screenKey));
  await pumpUntilFound(tester, find.byKey(NoSessionScreen.screenKey));
  await pumpUntilFound(tester, find.byKey(PhoneScreen.fieldKey));
  await tester.enterText(_input(PhoneScreen.fieldKey), _sellerPhone);
  await tester.pump();
  await _tap(tester, find.byKey(PhoneScreen.submitKey));
  await pumpUntilFound(tester, find.byKey(OtpScreen.screenKey));
  await tester.enterText(
    find.descendant(of: find.byKey(OtpScreen.screenKey), matching: find.byType(EditableText)),
    _otpCode,
  );
  await tester.pump();
  await pumpUntilFound(tester, find.byKey(RegistrationSecurityScreen.screenKey), timeout: const Duration(seconds: 60));
  await pumpUntilFound(tester, find.byType(PinField));
  await _settle(tester);
  await _enterPin(tester, _sellerPin);
  await _enterPin(tester, _sellerPin);
  if (find.byKey(RegistrationSecurityScreen.pdAckKey).evaluate().isNotEmpty) {
    await _tap(tester, find.byKey(RegistrationSecurityScreen.pdAckKey));
  }
  await pumpUntilFound(
    tester,
    find.byWidgetPredicate(
      (Widget w) => w is AppButton && w.key == RegistrationSecurityScreen.completeKey && w.onPressed != null,
    ),
    timeout: const Duration(seconds: 10),
  );
  await _tap(tester, find.byKey(RegistrationSecurityScreen.completeKey));
  await pumpUntilFound(tester, find.byKey(_catalogRoot), timeout: const Duration(seconds: 60));
  await pumpUntil<bool>(
    tester,
    () async => _container(tester).read(catalogFreshnessProvider).fullyLoaded ? true : null,
    what: 'первичная загрузка кэша каталога',
    timeout: const Duration(minutes: 5),
  );
}

Future<Map<String, Object?>> _api(WidgetTester tester, String path, [Map<String, Object?>? query]) async {
  final Dio dio = _container(tester).read(dioProvider);
  final Response<Object?>? r = await tester.runAsync(() => dio.get<Object?>(path, queryParameters: query));
  final Object? data = r?.data;
  if (data is! Map<String, Object?>) fail('GET $path: ответ не объект');
  return data;
}

Future<List<CartDraftLine>> _draftLines(WidgetTester tester) async {
  final List<CartDraftLine>? lines = await tester.runAsync(() async {
    final result = await _container(tester).read(cartDraftRepositoryProvider).lines();
    return result.fold((List<CartDraftLine> l) => l, (_) => const <CartDraftLine>[]);
  });
  return lines ?? const <CartDraftLine>[];
}

// ---------------------------------------------------------------------------
// Корзина: кнопка-итог в шапке и drawer 420 (ADR-112, D5)
// ---------------------------------------------------------------------------

Finder get _cartButton => find.byKey(CartHeaderButtonView.buttonKey);
Finder get _cartDrawer => find.byKey(CartDrawer.key);

/// Состояние кнопки корзины в шапке: бейдж и вторая строка (итог сервера / «N поз.»).
String _headerCartText(WidgetTester tester) {
  final Iterable<Element> e = _cartButton.evaluate();
  if (e.isEmpty) return 'нет кнопки';
  final TopAppBarCartButton b = e.last.widget as TopAppBarCartButton;
  return 'бейдж ${b.count}, «${b.totalText}»';
}

/// Ответ сервера получен и подтверждает все изменения (итог в кнопке шапки — без «≈»).
bool _cartConfirmed(WidgetTester tester, int lines) {
  final CartState s = _container(tester).read(cartControllerProvider);
  return s.server != null && !s.preliminary && s.lines.length >= lines;
}

/// Ключ строки корзины `cart-line-<variantId>-<packagingId>` (`CartKeys.line`), без служебных `cart-line-reduce-…`
/// и `cart-line-variant`.
bool _isCartLineKey(Key? key) =>
    key is ValueKey<String> &&
    key.value.startsWith('cart-line-') &&
    !key.value.startsWith('cart-line-reduce-') &&
    key.value != 'cart-line-variant';

/// Строки корзины в открытом drawer.
Set<String> _drawerLineKeys() => <String>{
  for (final Element e
      in find
          .descendant(of: _cartDrawer, matching: find.byWidgetPredicate((Widget w) => _isCartLineKey(w.key)))
          .evaluate())
    (e.widget.key! as ValueKey<String>).value,
};

/// Открыть drawer корзины кнопкой в шапке и дождаться конца анимации (ANIM-025, 250 мс).
Future<bool> _openCartDrawer(WidgetTester tester, String where) async {
  await _tapVisible(tester, _cartButton);
  final bool open = await _until(tester, () => _cartDrawer.evaluate().isNotEmpty);
  if (!open) {
    _problem('$where: кнопка корзины в шапке не открыла drawer');
    return false;
  }
  await _quiet(tester);
  final Rect r = tester.getRect(_cartDrawer.first);
  final Size win = tester.view.physicalSize / tester.view.devicePixelRatio;
  _note(
    '$where: drawer корзины ${r.width.round()}×${r.height.round()} у правого края (x ${r.left.round()}…${r.right.round()})',
  );
  if ((r.width - 420).abs() > 1 && win.width > 420) _problem('$where: ширина drawer ${r.width} ≠ 420');
  if ((r.right - win.width).abs() > 1) _problem('$where: drawer не у правого края (${r.right} ≠ ${win.width})');
  return true;
}

/// Закрыть drawer корзины клавишей Esc; запасной путь — тап по затемнению (с пометкой проблемы).
Future<void> _closeCartDrawer(WidgetTester tester, String where) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  final bool closed = await _until(tester, () => _cartDrawer.evaluate().isEmpty, timeout: const Duration(seconds: 5));
  _note('$where: Esc — drawer корзины закрыт: $closed (CartDrawer.isOpen=${CartDrawer.isOpen})');
  if (closed) {
    await _quiet(tester, max: const Duration(seconds: 1));
    return;
  }
  _problem('$where: Esc не закрыл drawer корзины');
  final Finder scrim = find.byKey(CartDrawer.scrimKey);
  if (scrim.evaluate().isNotEmpty) await tester.tap(scrim.first, warnIfMissed: false);
  if (!await _until(tester, () => _cartDrawer.evaluate().isEmpty, timeout: const Duration(seconds: 5))) {
    _problem('$where: drawer корзины не закрылся и по затемнению');
  }
}

// ---------------------------------------------------------------------------
// Снимки и анализ кадров
// ---------------------------------------------------------------------------

final class _Frame {
  _Frame(this.name, this.width, this.height, this.dpr, this.rgba, this.state);
  final String name;
  final int width;
  final int height;

  /// DPR тестового окна в момент снимка (`tester.view`): логические → физические пиксели кадра.
  final double dpr; // money-double: allow — DPR окна, не деньги
  final Uint8List rgba;
  final _UiState state;
}

/// Структура экрана в кадре.
final class _UiState {
  _UiState({
    required this.header,
    required this.sidebar,
    required this.cart,
    required this.workspaces,
    required this.workspaceState,
    required this.headerElement,
    required this.sidebarElement,
    required this.cartElement,
    required this.skeleton,
    required this.cards,
    required this.location,
    required this.headerRect,
    required this.sidebarRect,
    required this.contentRect,
  });
  final bool header;
  final bool sidebar;

  /// Кнопка-итог корзины в шапке (UI-10-041; постоянной панели корзины больше нет — ADR-112).
  final bool cart;
  final int workspaces;
  final State? workspaceState;
  final Element? headerElement;
  final Element? sidebarElement;
  final Element? cartElement;
  final bool skeleton;
  final int cards;
  final String location;
  final Rect? headerRect;
  final Rect? sidebarRect;
  final Rect? contentRect;

  @override
  String toString() =>
      'заглушек «Нет фото»=${find.byKey(const ValueKey<String>('product-image-placeholder')).evaluate().length}, '
      'шапка=$header, колонка=$sidebar, кнопка корзины=$cart, экранов=$workspaces, скелетон=$skeleton, '
      'карточек=$cards, адрес=$location';
}

Finder get _cardsFinder =>
    find.byWidgetPredicate((Widget w) => w is ProductCardGrid || w is ProductCardList || w is ProductCardCompact);

Rect? _rect(WidgetTester tester, Finder f) => f.evaluate().isEmpty ? null : tester.getRect(f.first);

_UiState _uiState(WidgetTester tester) {
  final Finder ws = find.byType(CatalogWorkspace);
  final Finder header = find.byType(CatalogHeader);
  final Finder sidebar = find.byKey(_sidebar);
  return _UiState(
    header: header.evaluate().isNotEmpty,
    sidebar: sidebar.evaluate().isNotEmpty,
    cart: _cartButton.evaluate().isNotEmpty,
    workspaces: ws.evaluate().length,
    workspaceState: ws.evaluate().isEmpty ? null : tester.state(ws.last),
    headerElement: header.evaluate().isEmpty ? null : header.evaluate().last,
    sidebarElement: sidebar.evaluate().isEmpty ? null : sidebar.evaluate().last,
    cartElement: _cartButton.evaluate().isEmpty ? null : _cartButton.evaluate().last,
    skeleton: find.byKey(_skeleton).evaluate().isNotEmpty,
    cards: _cardsFinder.evaluate().length,
    location: _where(tester),
    headerRect: _rect(tester, header),
    sidebarRect: _rect(tester, sidebar),
    contentRect: _rect(tester, find.byKey(_productView)),
  );
}

/// Снимок окна: слой `RenderView` (корень дерева отрисовки, граница перерисовки) → `toImage` → PNG. Размер кадра —
/// физический размер тестового окна (`tester.view.physicalSize`; при DPR 1 — ровно логический).
Future<_Frame> _shot(WidgetTester tester, String name, {bool save = true}) async {
  final _UiState st = _uiState(tester);
  final RenderView rv = tester.binding.renderViews.first;
  final OffsetLayer layer = rv.debugLayer! as OffsetLayer;
  final Size phys = tester.view.physicalSize;
  final double dpr = tester.view.devicePixelRatio; // money-double: allow — DPR окна, не деньги
  final _Frame? f = await tester.runAsync(() async {
    final ui.Image img = await layer.toImage(Offset.zero & phys);
    final ByteData? raw = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (save) {
      final ByteData? png = await img.toByteData(format: ui.ImageByteFormat.png);
      final File file = File('$_shotsDir/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(png!.buffer.asUint8List());
    }
    final _Frame out = _Frame(name, img.width, img.height, dpr, raw!.buffer.asUint8List(), st);
    img.dispose();
    return out;
  });
  return f!;
}

/// Доля почти белых пикселей в области (логические координаты).
double _whiteFrac(_Frame f, Rect? logical) {
  final Rect r = _phys(f, logical);
  int white = 0;
  int total = 0;
  for (int y = r.top.toInt(); y < r.bottom.toInt(); y += 2) {
    for (int x = r.left.toInt(); x < r.right.toInt(); x += 2) {
      final int i = (y * f.width + x) * 4;
      total++;
      if (f.rgba[i] >= 250 && f.rgba[i + 1] >= 250 && f.rgba[i + 2] >= 250) white++;
    }
  }
  return total == 0 ? 0 : white / total;
}

/// Средняя поканальная разница двух кадров в области (0…255).
double _diff(_Frame a, _Frame b, Rect? logical) {
  final Rect r = _phys(a, logical);
  int sum = 0;
  int n = 0;
  for (int y = r.top.toInt(); y < r.bottom.toInt(); y += 2) {
    for (int x = r.left.toInt(); x < r.right.toInt(); x += 2) {
      final int i = (y * a.width + x) * 4;
      if (i + 2 >= b.rgba.length) continue;
      sum +=
          (a.rgba[i] - b.rgba[i]).abs() + (a.rgba[i + 1] - b.rgba[i + 1]).abs() + (a.rgba[i + 2] - b.rgba[i + 2]).abs();
      n += 3;
    }
  }
  return n == 0 ? 0 : sum / n;
}

/// Логический прямоугольник → физические пиксели кадра (DPR кадра).
Rect _phys(_Frame f, Rect? logical) {
  final double k = f.dpr; // money-double: allow — DPR окна, не деньги
  final Rect full = Rect.fromLTWH(0, 0, f.width.toDouble(), f.height.toDouble());
  if (logical == null) return full;
  return Rect.fromLTRB(logical.left * k, logical.top * k, logical.right * k, logical.bottom * k).intersect(full);
}

/// Цвет пикселя (логические координаты).
Color _pixel(_Frame f, Offset logical) {
  final int x = (logical.dx * f.dpr).round().clamp(0, f.width - 1);
  final int y = (logical.dy * f.dpr).round().clamp(0, f.height - 1);
  final int i = (y * f.width + x) * 4;
  return Color.fromARGB(255, f.rgba[i], f.rgba[i + 1], f.rgba[i + 2]);
}

String _hex(Color c) {
  String h(double v) => (v * 255).round().toRadixString(16).padLeft(2, '0');
  return '#${h(c.r)}${h(c.g)}${h(c.b)}'.toUpperCase();
}

/// Палитра ADR-111: заливка «+ Добавить» (`AppButton.primary`) = `DsColors.lightB.primary`, текст — `onPrimary`.
/// Кнопка «В корзине · N — ещё +1» — тоже `AppButton` (вариант `tint`), её не проверяем.
void _checkAddButtonColors(WidgetTester tester, _Frame frame, String where) {
  const DsColors palette = DsColors.lightB;
  final Size win = Size(frame.width / frame.dpr, frame.height / frame.dpr);
  final Finder addBtn = find.descendant(
    of: _cardsFinder,
    matching: find.byWidgetPredicate(
      (Widget w) => w is AppButton && w.variant == AppButtonVariant.primary && w.onPressed != null,
    ),
  );
  Element? visible;
  for (final Element e in addBtn.evaluate()) {
    final Rect r = tester.getRect(find.byElementPredicate((Element x) => x == e));
    if (r.left >= 0 && r.top >= 0 && r.right <= win.width && r.bottom <= win.height) {
      visible = e;
      break;
    }
  }
  if (visible == null) {
    _note('$where: видимой кнопки «+ Добавить» (AppButton primary) в кадре нет — цвет не проверен');
    return;
  }
  final Finder btn = find.byElementPredicate((Element x) => x == visible);
  final Rect b = tester.getRect(btn);
  final Color fill = _pixel(frame, Offset(b.left + 6, b.center.dy));
  final Color want = palette.primary;
  _note('$where: кнопка «+ Добавить» — заливка ${_hex(fill)} (ожидается primary ${_hex(want)})');
  if ((fill.r - want.r).abs() * 255 > 16 || (fill.g - want.g).abs() * 255 > 16 || (fill.b - want.b).abs() * 255 > 16) {
    _problem('$where: заливка кнопки «+ Добавить» ${_hex(fill)} — не primary ${_hex(want)}');
  }
  final List<Text> labels = tester.widgetList<Text>(find.descendant(of: btn, matching: find.byType(Text))).toList();
  final List<Text> wrongText = labels.where((Text t) => t.style?.color != palette.onPrimary).toList();
  if (labels.isEmpty || wrongText.isNotEmpty) {
    _problem(
      '$where: текст кнопки «+ Добавить» не onPrimary ${_hex(palette.onPrimary)}: '
      '${wrongText.map((Text t) => t.style?.color == null ? 'без цвета' : _hex(t.style!.color!)).join(', ')}',
    );
  } else {
    _note('$where: текст кнопки «${labels.map((Text t) => t.data).join()}» — onPrimary ${_hex(palette.onPrimary)}');
  }
}

/// Действие [act] (без прокачки) → [frames] кадров подряд по 16 мс; первые [saved] сохраняются как PNG.
/// Проверки каждого кадра: шапка, колонка и кнопка корзины в шапке на месте и не пересозданы, экземпляр экрана тот
/// же (или ровно один новый для `push`), скелетона нет, фон не белеет относительно кадра «до».
Future<void> _transition(
  WidgetTester tester,
  String prefix,
  Future<void> Function() act, {
  int frames = 6,
  int saved = 3,
  bool expectSameInstance = true,
}) async {
  final _Frame before = await _shot(tester, '${prefix}_f0_before', save: true);
  final double whiteBefore = _whiteFrac(before, null);
  await act();
  final List<String> rows = <String>[];
  for (int i = 1; i <= frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    final _Frame f = await _shot(tester, '${prefix}_f$i', save: i <= saved);
    final _UiState s = f.state;
    final double white = _whiteFrac(f, null);
    final double hd = _diff(before, f, s.headerRect ?? before.state.headerRect);
    final double sd = _diff(before, f, s.sidebarRect ?? before.state.sidebarRect);
    final bool same = identical(s.workspaceState, before.state.workspaceState);
    final bool sameHeader = identical(s.headerElement, before.state.headerElement);
    final bool sameSidebar = identical(s.sidebarElement, before.state.sidebarElement);
    final bool sameCart = identical(s.cartElement, before.state.cartElement);
    rows.add(
      'кадр $i: $s; белых ${(white * 100).toStringAsFixed(1)} % (до ${(whiteBefore * 100).toStringAsFixed(1)} %), '
      'Δшапки ${hd.toStringAsFixed(2)}, Δколонки ${sd.toStringAsFixed(2)}, тот же экран=$same, '
      'та же шапка=$sameHeader, та же колонка=$sameSidebar, та же кнопка корзины=$sameCart',
    );
    if (!s.header) _problem('$prefix кадр $i: шапка исчезла');
    if (!s.sidebar) _problem('$prefix кадр $i: колонка категорий исчезла');
    if (!s.cart) _problem('$prefix кадр $i: кнопка корзины в шапке исчезла');
    if (s.skeleton) _problem('$prefix кадр $i: скелетон всей сетки');
    if (s.cards == 0) _problem('$prefix кадр $i: нет карточек (пустая область)');
    if (white > whiteBefore + 0.15) {
      _problem(
        '$prefix кадр $i: фон побелел (${(white * 100).toStringAsFixed(1)} % против ${(whiteBefore * 100).toStringAsFixed(1)} %)',
      );
    }
    if (hd > 6) _problem('$prefix кадр $i: шапка изменилась (Δ ${hd.toStringAsFixed(2)})');
    if (sd > 25) _problem('$prefix кадр $i: колонка категорий перерисована целиком (Δ ${sd.toStringAsFixed(2)})');
    if (expectSameInstance && !same) _problem('$prefix кадр $i: экран CatalogWorkspace пересоздан');
    if (expectSameInstance && (!sameHeader || !sameSidebar || !sameCart)) {
      _problem('$prefix кадр $i: шапка/колонка/кнопка корзины пересозданы');
    }
  }
  for (final String r in rows) {
    _note('$prefix: $r');
  }
}

// ---------------------------------------------------------------------------
// Данные карточек против сервера
// ---------------------------------------------------------------------------

List<ProductCardData> _cards(WidgetTester tester) => <ProductCardData>[
  for (final Widget w in tester.widgetList(_cardsFinder))
    switch (w) {
      final ProductCardGrid g => g.data,
      final ProductCardList l => l.data,
      final ProductCardCompact c => c.data,
      _ => throw StateError('карточка'),
    },
];

ProductCardData? _card(WidgetTester tester, String id) =>
    _cards(tester).where((ProductCardData c) => c.id == id).firstOrNull;

/// Активная кнопка карточки (`+ Добавить` или «В корзине · N — ещё +1»).
Finder _cardButton(String productId) => find.descendant(
  of: find.byKey(ValueKey<String>('product-$productId')),
  matching: find.byWidgetPredicate((Widget w) => w is AppButton && w.onPressed != null),
);

String _digits(String s) => s.replaceAll(RegExp(r'[\s\u00A0\u202F]'), '');

/// Сверка видимых карточек с `GET /catalog/products?categoryId=` (или поиском): название, артикул, цена, остаток.
Future<void> _checkCardsAgainstServer(
  WidgetTester tester,
  String what,
  Map<String, Object?> query, {
  String path = '/catalog/products',
}) async {
  final Map<String, Object?> page = await _api(tester, path, <String, Object?>{...query, 'limit': 200});
  final Map<String, Map<String, Object?>> byId = <String, Map<String, Object?>>{
    for (final Object? it in (page['items'] as List<Object?>? ?? const <Object?>[]))
      if (it is Map<String, Object?>) it['id']! as String: it,
  };
  final List<ProductCardData> cards = _cards(tester);
  int checked = 0;
  final List<String> bad = <String>[];
  for (final ProductCardData c in cards) {
    final Map<String, Object?>? j = byId[c.id];
    if (j == null) {
      bad.add('${c.name}: нет в ответе сервера');
      continue;
    }
    checked++;
    if (j['name'] != c.name) bad.add('название «${c.name}» ≠ «${j['name']}»');
    final String? sku = j['sku'] as String?;
    if (sku != null && sku.trim().isNotEmpty && !c.skuLabel.contains(sku.trim())) {
      bad.add('${c.name}: артикул «${c.skuLabel}» ≠ $sku');
    }
    final Map<String, Object?>? price = j['price'] as Map<String, Object?>?;
    final Map<String, Object?>? range = j['priceRange'] as Map<String, Object?>?;
    final bool hasVariants = j['hasVariants'] == true;
    String? amt(Object? m) => m is Map ? m['amount'] as String? : m as String?;
    final String? expect = hasVariants && range != null && amt(range['min']) != amt(range['max'])
        ? amt(range['min'])
        : amt(price?['price']) ?? amt(range?['min']);
    final Money? exp = expect == null ? null : Money.fromString(expect);
    if (exp?.tyiyn != c.price?.tyiyn) bad.add('${c.name}: цена ${c.price?.toApiString()} ≠ сервер $expect');
    final Map<String, Object?>? stock = j['stock'] as Map<String, Object?>?;
    final Object? av = stock?['available'];
    final String? available = av is Map ? av['value'] as String? ?? av['amount'] as String? : av as String?;
    if (available != null && c.stockLevel != StockBadgeLevel.out) {
      final String intPart = available.split('.').first;
      if (!_digits(c.stockLabel).contains(intPart)) bad.add('${c.name}: остаток «${c.stockLabel}» ≠ сервер $available');
    }
  }
  final int withImage = cards.where((c) => c.imageUrl != null).length;
  final int serverImages = byId.values.where((j) => j['primaryImage'] != null).length;
  _note(
    '$what: фото у карточек $withImage из ${cards.length} (в ответе сервера ${byId.length}, с фото $serverImages); '
    'пример URL: ${cards.map((c) => c.imageUrl).whereType<String>().firstOrNull}',
  );
  final String? firstUrl = cards.map((c) => c.imageUrl).whereType<String>().firstOrNull;
  if (firstUrl != null) {
    // URL фото из ответа API: относительный ли он и отдаёт ли его прокси стека по абсолютному адресу.
    final Uri api = Uri.parse(const String.fromEnvironment('API_BASE_URL'));
    final Uri abs = api.resolve(firstUrl);
    final int? status = await tester.runAsync(() async {
      final HttpClient h = HttpClient();
      try {
        final HttpClientResponse r = await (await h.getUrl(abs)).close();
        await r.drain<void>();
        return r.statusCode;
      } finally {
        h.close(force: true);
      }
    });
    _note('$what: URL фото относительный=${!Uri.parse(firstUrl).hasScheme}; GET $abs → $status');
  }
  _note(
    '$what: карточек ${cards.length}, сверено с сервером $checked, расхождений ${bad.length}'
    '${cards.isEmpty ? '' : '; пример: «${cards.first.name}», ${cards.first.skuLabel}, '
              '${cards.first.price?.toApiString()} сом, ${cards.first.stockLabel}'}',
  );
  for (final String b in bad.take(10)) {
    _problem('$what: $b');
  }
}

/// Колонки сетки: число различных левых границ карточек в первом ряду.
int _gridColumns(WidgetTester tester) {
  final List<Rect> rects = <Rect>[
    for (final Element e in find.byType(ProductCardGrid).evaluate())
      tester.getRect(find.byElementPredicate((x) => x == e)),
  ];
  if (rects.isEmpty) return 0;
  final double top = rects.map((r) => r.top).reduce((a, b) => a < b ? a : b);
  return rects.where((r) => (r.top - top).abs() < 2).length;
}

/// Ждёт окончания загрузки списка (нет полосы обновления, есть карточки) и фото.
Future<void> _listReady(WidgetTester tester, {Duration photos = const Duration(seconds: 3)}) async {
  await pumpUntilFound(tester, _cardsFinder, timeout: const Duration(seconds: 30));
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 30));
  while (find.byKey(CatalogWorkspace.refreshBarKey).evaluate().isNotEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await _wait(tester, photos);
}

/// Плитка колонки категорий (ленивый список): прокрутка колонки до плитки.
Future<void> _showTile(WidgetTester tester, Finder tile) async {
  final Finder scroll = find.descendant(of: find.byKey(_sidebar), matching: find.byType(Scrollable)).first;
  if (tile.evaluate().isEmpty) {
    try {
      await tester.scrollUntilVisible(tile, 120, scrollable: scroll, maxScrolls: 40);
    } on Object {
      await tester.scrollUntilVisible(tile, -120, scrollable: scroll, maxScrolls: 40);
    }
  }
  await tester.ensureVisible(tile.first);
  await tester.pump();
}

// ---------------------------------------------------------------------------
// QA-снимки по прототипу (DPR 1; окна из E2E_SIZES)
// ---------------------------------------------------------------------------

/// Размеры из `E2E_SIZES` («1440x1180,1280x900»); пустая строка — без QA-снимков.
List<Size> _parseSizes(String spec) {
  final List<Size> out = <Size>[];
  for (final String part in spec.split(',')) {
    final String t = part.trim();
    if (t.isEmpty) continue;
    final RegExpMatch? m = RegExp(r'^(\d{3,5})[xX×](\d{3,5})$').firstMatch(t);
    if (m == null) fail('E2E_SIZES: «$t» — ожидается «ШxВ», например 1440x1180');
    final Size s = Size(int.parse(m[1]!).toDouble(), int.parse(m[2]!).toDouble());
    if (!out.contains(s)) out.add(s);
  }
  return out;
}

String _sizeTag(Size s) => '${s.width.round()}x${s.height.round()}';

/// Окно полного набора состояний: 1440×1180, если есть в списке, иначе первое.
Size _qaMain(List<Size> sizes) => sizes.contains(_qaFullSize) ? _qaFullSize : sizes.first;

/// Снимок прототипа для состояния (D:/optomstroy/.tmp/design_ref, headless Chrome по Main.dc.html).
String? _protoFor(String state, Size size) => switch ((state, _sizeTag(size))) {
  ('default', '1280x900') => 'proto_1280.png',
  ('default', '1024x800') => 'proto_1024.png',
  ('default', _) => 'proto_default.png',
  ('list', _) => 'proto_list.png',
  ('compact', _) => 'proto_compact.png',
  ('filters', _) => 'proto_filters.png',
  ('heating', _) => 'proto_heating.png',
  ('cart', _) => 'proto_cart.png',
  _ => null,
};

/// Колонки сетки по прототипу (auto-fill, min 176, без закреплённой корзины): 6 / 5 / 4.
int? _expectedColumns(Size size) => switch (_sizeTag(size)) {
  '1440x1180' => 6,
  '1280x900' => 5,
  '1024x800' => 4,
  _ => null,
};

/// Непустые подкатегории (лента показывает только `productCount > 0`, UI-12-003).
List<Category> _ribbonChildren(Category c) => c.children.where((Category ch) => ch.productCount > 0).toList();

/// Непустые подкатегории с картинкой из данных категории.
int _withImage(Category c) => _ribbonChildren(c).where((Category ch) => (ch.imageUrl ?? '').isNotEmpty).length;

/// (a): корень с наибольшим числом подкатегорий с `imageUrl`; если картинок нет ни у одного — первый корень с
/// непустыми подкатегориями (лента, как в proto_default), иначе первый корень.
(Category, String) _qaDefaultRoot(List<Category> roots) {
  Category? best;
  int bestN = 0;
  for (final Category r in roots) {
    final int n = _withImage(r);
    if (n > bestN) {
      best = r;
      bestN = n;
    }
  }
  if (best != null) {
    return (best, 'подкатегорий с картинкой $bestN из ${_ribbonChildren(best).length} (максимум среди корней)');
  }
  final Category? withSubs = roots.where((Category r) => _ribbonChildren(r).isNotEmpty).firstOrNull;
  if (withSubs != null) {
    return (
      withSubs,
      'картинок подкатегорий нет ни у одного корня (данные стека) — первый корень с подкатегориями '
          '(${_ribbonChildren(withSubs).length}), чтобы была лента, как в proto_default',
    );
  }
  return (roots.first, 'непустых подкатегорий нет ни у одного корня — первый корень');
}

/// (e): корень (не из (a)), у непустых подкатегорий которого нет `imageUrl` — плитки-заглушки ленты.
(Category, String) _qaHeatingRoot(List<Category> roots, Category def) {
  final List<Category> others = roots.where((Category r) => r.id != def.id).toList();
  final Category? exact = others.where((Category r) => _ribbonChildren(r).isNotEmpty && _withImage(r) == 0).firstOrNull;
  if (exact != null) {
    return (exact, 'подкатегорий ${_ribbonChildren(exact).length}, у всех нет imageUrl — плитки-заглушки');
  }
  final Category? noImages = others.where((Category r) => _withImage(r) == 0).firstOrNull;
  if (noImages != null) {
    return (
      noImages,
      'ОТМЕТКА: корня с подкатегориями без картинок нет; взят корень без картинок подкатегорий '
          '(непустых подкатегорий ${_ribbonChildren(noImages).length})',
    );
  }
  return (def, 'ОТМЕТКА: корня, у подкатегорий которого нет imageUrl, в данных стека нет — снят корень из (a)');
}

/// Окно QA: DPR 1 и физический размер = логическому (PNG ровно Ш×В).
Future<void> _qaSetSize(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  await _settle(tester, frames: 6);
}

/// Верх списка и колонки категорий (после `ensureVisible`/прокрутки) — кадр как в прототипе.
Future<void> _scrollToTop(WidgetTester tester) async {
  for (final Key key in <Key>[_products, _sidebar]) {
    for (final Element e in find.descendant(of: find.byKey(key), matching: find.byType(Scrollable)).evaluate()) {
      final ScrollableState s = (e as StatefulElement).state as ScrollableState;
      if (s.position.axis == Axis.vertical && s.position.hasPixels && s.position.pixels != 0) {
        s.position.jumpTo(0);
      }
    }
  }
  await tester.pump();
}

/// Адрес — категория [id] (`/catalog/c/<id>`, без учёта query).
bool _onCategory(WidgetTester tester, String id) => Uri.parse(_where(tester)).path == '/catalog/c/$id';

/// Выбрать корень в колонке категорий и дождаться списка.
Future<void> _qaOpenRoot(WidgetTester tester, Category root) async {
  if (_onCategory(tester, root.id)) return;
  final Finder tile = find.byKey(ValueKey<String>('sidebar-category-${root.id}'));
  await _showTile(tester, tile);
  await _tapVisible(tester, tile);
  if (!await _until(tester, () => _onCategory(tester, root.id), timeout: const Duration(seconds: 20))) {
    _problem('QA: плитка «${root.name}» не открыла /catalog/c/${root.id} (адрес ${_where(tester)})');
  }
  await _listReady(tester);
}

/// Вид списка: `grid` / `list` / `compact`.
Future<void> _qaView(WidgetTester tester, String mode) async {
  await _tapVisible(tester, find.byKey(ValueKey<String>('view-mode-$mode')));
  final Finder cards = switch (mode) {
    'list' => find.byType(ProductCardList),
    'compact' => find.byType(ProductCardCompact),
    _ => find.byType(ProductCardGrid),
  };
  await pumpUntilFound(tester, cards, timeout: const Duration(seconds: 20));
  await _listReady(tester, photos: const Duration(seconds: 2));
}

/// QA-снимок `app_<state>_<Ш>x<В>.png`: верх списка, конец анимаций, проверка размера PNG (= окно при DPR 1).
Future<_Frame> _qaShot(
  WidgetTester tester,
  String state,
  Size size, {
  Duration quiet = const Duration(seconds: 3),
  bool toTop = true,
}) async {
  if (toTop) await _scrollToTop(tester);
  final bool settled = await _quiet(tester, max: quiet);
  final String name = 'app_${state}_${_sizeTag(size)}';
  final _Frame f = await _shot(tester, name);
  final int w = (size.width * f.dpr).round();
  final int h = (size.height * f.dpr).round();
  if (f.dpr != 1.0) _problem('$name: DPR тестового окна ${f.dpr}, ожидается 1');
  if (f.width != w || f.height != h || f.width != size.width.round() || f.height != size.height.round()) {
    _problem('$name.png: ${f.width}×${f.height} px, ожидается ${_sizeTag(size)}');
  }
  final String? proto = _protoFor(state, size);
  _qaIndex.add('$name.png ↔ ${proto ?? '— (в прототипе нет; шапка и палитра — proto_default.png)'}');
  _note(
    'QA $name.png: ${f.width}×${f.height} px, DPR ${f.dpr}, анимации закончились=$settled; ${f.state}; '
    'кнопка корзины: ${_headerCartText(tester)}',
  );
  return f;
}

/// Шапка `full` (паритет функций, ADR-112): поле поиска, кнопка корзины, часы с датой (UI-10-005, UI-10-032),
/// колокольчик и аватар — в одну строку без наложений и внутри окна, поле поиска не уже 240; в отчёт — ступень
/// сжатия (`TopAppBarFit`), видимые тексты часов и подписи у аватара.
void _qaHeaderGeometry(WidgetTester tester, String what) {
  final Finder bar = find.byType(TopAppBarPos);
  if (bar.evaluate().isEmpty) {
    _problem('$what: нет шапки TopAppBarPos');
    return;
  }
  Finder inBar(Finder f) => find.descendant(of: bar.first, matching: f);
  final Finder clock = inBar(find.byKey(CatalogHeaderClock.clockKey));
  final Map<String, Rect?> parts = <String, Rect?>{
    'поиск': _rect(tester, inBar(find.byType(ds.SearchBar))),
    'синхр.': _rect(tester, inBar(find.byType(SyncIndicator))),
    'корзина': _rect(tester, inBar(_cartButton)),
    'часы': _rect(tester, clock),
    'колокольчик': _rect(tester, inBar(find.byType(NotificationBell))),
    'аватар': _rect(tester, inBar(find.byType(TopAppBarUser))),
  };
  final Rect barRect = tester.getRect(bar.first);
  String fmt(Rect? r) => r == null ? '—' : '${r.left.round()}…${r.right.round()} (${r.width.round()})';
  final String fit = clock.evaluate().isEmpty ? '—' : TopAppBarFit.of(clock.evaluate().first).toString();
  final List<String> clockTexts = <String>[
    for (final Text t in tester.widgetList<Text>(find.descendant(of: clock, matching: find.byType(Text)))) ?t.data,
  ];
  final List<String> userTexts = <String>[
    for (final Text t in tester.widgetList<Text>(
      inBar(find.descendant(of: find.byType(TopAppBarUser), matching: find.byType(Text))),
    ))
      ?t.data,
  ];
  _note(
    '$what: шапка ${barRect.width.round()}×${barRect.height.round()}; '
    '${parts.entries.map((MapEntry<String, Rect?> e) => '${e.key} ${fmt(e.value)}').join(', ')}; '
    'часы «${clockTexts.join(' / ')}», у аватара «${userTexts.join(' / ')}»; $fit',
  );
  final Rect? search = parts['поиск'];
  if (search == null) {
    _problem('$what: в шапке нет поля поиска');
  } else if (search.width < TopAppBarPos.searchMinWidth - 0.5) {
    _problem('$what: поле поиска ${search.width.round()} < ${TopAppBarPos.searchMinWidth.round()}');
  }
  if (parts['часы'] == null) _problem('$what: в шапке нет часов (UI-10-005)');
  if (clockTexts.length < 2) _note('$what: ОТМЕТКА — дата часов свёрнута (в тултипе): «${clockTexts.join()}»');
  // Строка шапки: элементы одной высоты строки слева направо без наложений (поле второй строкой — вне сравнения).
  final List<MapEntry<String, Rect>> row = <MapEntry<String, Rect>>[
    for (final MapEntry<String, Rect?> e in parts.entries)
      if (e.value != null && e.value!.top < barRect.top + 68) MapEntry<String, Rect>(e.key, e.value!),
  ]..sort((MapEntry<String, Rect> a, MapEntry<String, Rect> b) => a.value.left.compareTo(b.value.left));
  for (int i = 1; i < row.length; i++) {
    if (row[i].value.left < row[i - 1].value.right - 0.5) {
      _problem(
        '$what: «${row[i - 1].key}» налезает на «${row[i].key}» (${fmt(row[i - 1].value)} / ${fmt(row[i].value)})',
      );
    }
  }
  for (final MapEntry<String, Rect> e in row) {
    if (e.value.left < barRect.left - 0.5 || e.value.right > barRect.right + 0.5) {
      _problem('$what: «${e.key}» выходит за шапку (${fmt(e.value)})');
    }
  }
}

/// (j) Колонка категорий свёрнута и снова развёрнута (паритет функций ADR-112): кнопка внизу колонки → 72 lp,
/// плитки-иконки с тултипами, «Каталог» и «Недавние» скрыты; снимки на [sizes] (основное окно — и с тултипом
/// наведения на плитку [root]); затем снова 132. Настройка `sidebarCollapsed` возвращается в исходное значение.
Future<void> _qaSidebarCollapsed(WidgetTester tester, Size main, List<Size> sizes, Category root) async {
  const Key toggleKey = ValueKey<String>('catalog-sidebar-toggle');
  const Key columnKey = ValueKey<String>('catalog-sidebar-column');
  final Finder toggle = find.byKey(toggleKey);
  final Finder column = find.byKey(columnKey);
  if (toggle.evaluate().isEmpty || column.evaluate().isEmpty) {
    _problem('QA (j): нет кнопки «Свернуть» или колонки категорий');
    return;
  }
  final double before = tester.getSize(column.first).width; // money-double: allow — геометрия UI (lp)
  await _tapVisible(tester, toggle);
  final bool collapsed = await _until(tester, () => tester.getSize(column.first).width < before - 1);
  await _quiet(tester, max: const Duration(seconds: 2));
  final double width = tester.getSize(column.first).width; // money-double: allow — геометрия UI (lp)
  final bool title = find.byKey(const ValueKey<String>('sidebar-title')).evaluate().isNotEmpty;
  final Finder tile = find.byKey(ValueKey<String>('sidebar-category-${root.id}'));
  final Rect? tileRect = _rect(tester, tile);
  _note(
    'QA (j): колонка ${before.round()} → ${width.round()} (свернулась=$collapsed), «Каталог» виден=$title, '
    'плитка «${root.name}» ${tileRect == null ? '—' : '${tileRect.width.round()}×${tileRect.height.round()}'}',
  );
  if (!collapsed || (width - 72).abs() > 0.5) _problem('QA (j): ширина свёрнутой колонки ${width.round()} ≠ 72');
  if (title) _problem('QA (j): в свёрнутой колонке виден заголовок «Каталог»');
  for (final Size s in <Size>[main, ...sizes.where((Size x) => x != main)]) {
    await _qaSetSize(tester, s);
    await _listReady(tester, photos: const Duration(seconds: 1));
    await _qaShot(tester, 'sidebar_collapsed', s);
  }
  await _qaSetSize(tester, main);
  await _listReady(tester, photos: const Duration(seconds: 1));
  if (tile.evaluate().isNotEmpty) {
    final TestGesture mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset(main.width - 4, main.height - 4));
    await tester.pump();
    await mouse.moveTo(tester.getCenter(tile.first));
    final bool tip = await _until(
      tester,
      () => find.byType(Tooltip).evaluate().isNotEmpty && find.text(root.name).hitTestable().evaluate().isNotEmpty,
      timeout: const Duration(seconds: 4),
    );
    await _wait(tester, const Duration(milliseconds: 300));
    _note('QA (j): тултип плитки «${root.name}» при наведении: $tip');
    if (!tip) _note('QA (j): ОТМЕТКА — тултип с названием не найден (проверить снимок)');
    await _qaShot(tester, 'sidebar_collapsed_tooltip', main, toTop: false, quiet: const Duration(milliseconds: 300));
    await mouse.moveTo(Offset(main.width - 4, main.height - 4));
    await tester.pump();
    await mouse.removePointer();
    await _wait(tester, const Duration(milliseconds: 400));
  }
  await _tapVisible(tester, toggle);
  final bool expanded = await _until(tester, () => (tester.getSize(column.first).width - before).abs() < 0.5);
  await _quiet(tester, max: const Duration(seconds: 2));
  _note('QA (j): снова развёрнута=$expanded, колонка ${tester.getSize(column.first).width.round()}');
  if (!expanded) _problem('QA (j): колонка не развернулась обратно до ${before.round()}');
}

/// QA-состояния (a)–(j) по прототипу; на выходе — корзина очищена, адрес `/catalog`, окно сброшено.
Future<void> _designQa(WidgetTester tester, List<Size> sizes) async {
  final Size main = _qaMain(sizes);
  _note('QA: окна ${sizes.map(_sizeTag).join(', ')} при DPR 1; полный набор состояний — на ${_sizeTag(main)}');
  final CategoryTree? tree = _container(tester).read(categoryTreeProvider).tree;
  expect(tree, isNotNull, reason: 'дерево категорий');
  final List<Category> roots = tree!.roots.where((Category c) => c.productCount > 0).toList();
  expect(roots, isNotEmpty, reason: 'корни каталога с товарами');
  final (Category def, String whyDef) = _qaDefaultRoot(roots);
  final (Category heat, String whyHeat) = _qaHeatingRoot(roots, def);
  _note(
    'QA: корни ${roots.map((Category c) => '${c.name} (подкатегорий ${_ribbonChildren(c).length}, '
        'с картинкой ${_withImage(c)})').join('; ')}',
  );
  _note('QA (a) корень «${def.name}»: $whyDef');
  _note('QA (e) корень «${heat.name}»: $whyHeat');

  // (a) default — на всех размерах: «Сетка», корзина пуста, фильтры закрыты.
  for (final Size s in <Size>[main, ...sizes.where((Size x) => x != main)]) {
    await _qaSetSize(tester, s);
    await _qaOpenRoot(tester, def);
    if (find.byKey(_filterPanel).evaluate().isNotEmpty) await _tapVisible(tester, find.byKey(_filtersButton));
    await _qaView(tester, 'grid');
    await _listReady(tester);
    final _Frame f = await _qaShot(tester, 'default', s);
    _qaHeaderGeometry(tester, 'QA шапка default ${_sizeTag(s)}');
    final int cols = _gridColumns(tester);
    final int? want = _expectedColumns(s);
    final int cards = find.byType(ProductCardGrid).evaluate().length;
    _note(
      'QA default ${_sizeTag(s)}: колонок сетки $cols (по прототипу ${want ?? '—'}), карточек $cards; '
      'лента: плиток-заглушек ${find.descendant(of: find.byKey(_ribbon), matching: find.byKey(_ribbonPlaceholder)).evaluate().length}',
    );
    if (want != null && cards >= want && cols != want) _problem('QA default ${_sizeTag(s)}: колонок $cols ≠ $want');
    _checkAddButtonColors(tester, f, 'app_default_${_sizeTag(s)}');
  }
  await _qaSetSize(tester, main);
  await _listReady(tester, photos: const Duration(seconds: 2));

  // (b) «Список», (c) «Компакт», затем снова «Сетка».
  await _qaView(tester, 'list');
  await _qaShot(tester, 'list', main);
  await _qaView(tester, 'compact');
  await _qaShot(tester, 'compact', main);
  await _qaView(tester, 'grid');

  // (d) встроенная панель фильтров + «Только в наличии»; затем снять флажок и закрыть панель.
  await _tapVisible(tester, find.byKey(_filtersButton));
  if (!await _until(tester, () => find.byKey(_filterPanel).evaluate().isNotEmpty)) {
    _problem('QA (d): «Фильтры» не открыли встроенную панель');
  } else {
    await _tapVisible(tester, find.byKey(_inStock));
    await _wait(tester, const Duration(milliseconds: 300));
    await _listReady(tester);
    final int out = _cards(tester).where((ProductCardData c) => c.stockLevel == StockBadgeLevel.out).length;
    _note('QA (d): «Только в наличии» — адрес ${_where(tester)}; карточек ${_cards(tester).length}, без остатка $out');
    if (out > 0) _problem('QA (d): «Только в наличии» — $out карточек без остатка');
    await _qaShot(tester, 'filters', main);
    await _tapVisible(tester, find.byKey(_inStock));
    await _wait(tester, const Duration(milliseconds: 300));
    await _listReady(tester, photos: const Duration(seconds: 1));
    await _tapVisible(tester, find.byKey(_filtersButton));
    if (!await _until(tester, () => find.byKey(_filterPanel).evaluate().isEmpty)) {
      _problem('QA (d): панель фильтров не закрылась');
    }
  }

  // (e) корень без картинок подкатегорий — плитки-заглушки ленты.
  await _qaOpenRoot(tester, heat);
  final int placeholders = find
      .descendant(of: find.byKey(_ribbon), matching: find.byKey(_ribbonPlaceholder))
      .evaluate()
      .length;
  _note('QA (e) «${heat.name}»: плиток-заглушек в ленте $placeholders (включая «Все товары»)');
  await _qaShot(tester, 'heating', main);

  // (j) колонка категорий свёрнута (на всех размерах) и снова развёрнута.
  await _qaOpenRoot(tester, def);
  await _qaSidebarCollapsed(tester, main, sizes, def);

  // (g) «бургер» → drawer навигации; Esc закрывает.
  await _tapVisible(tester, find.byKey(_menuButton));
  if (!await _until(tester, () => find.byKey(_navDrawer).evaluate().isNotEmpty)) {
    _problem('QA (g): «бургер» не открыл drawer навигации');
  } else {
    await _qaShot(tester, 'nav_drawer', main, toTop: false);
    final int items = find
        .descendant(
          of: find.byKey(_navDrawer),
          matching: find.byWidgetPredicate(
            (Widget w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('shell-nav-'),
          ),
        )
        .evaluate()
        .length;
    _note('QA (g): пунктов drawer навигации $items');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    if (!await _until(tester, () => find.byKey(_navDrawer).evaluate().isEmpty, timeout: const Duration(seconds: 5))) {
      _problem('QA (g): Esc не закрыл drawer навигации');
      await tester.tapAt(Offset(main.width - 40, main.height / 2));
      await _until(tester, () => find.byKey(_navDrawer).evaluate().isEmpty, timeout: const Duration(seconds: 5));
    }
    await _quiet(tester, max: const Duration(seconds: 1));
  }

  // (f) + (h): три товара (один дважды), тост, ответ сервера, drawer по кнопке шапки, Esc.
  await _qaOpenRoot(tester, def);
  final List<ProductCardData> addable = _cards(
    tester,
  ).where((ProductCardData c) => c.action == ProductCardActionKind.add).take(3).toList();
  _note('QA (f): товаров с «+ Добавить» для корзины ${addable.length}: ${addable.map((c) => c.name).join('; ')}');
  if (addable.length < 3) _problem('QA (f): в «${def.name}» меньше 3 карточек с «+ Добавить»');
  final Finder toast = find.textContaining('Добавлено: ');
  for (int i = 0; i < addable.length; i++) {
    final ProductCardData p = addable[i];
    await _tapVisible(tester, _cardButton(p.id));
    if (i == 0) {
      // (h) тост сразу после «+ Добавить»: появление (≈ 250 мс) — и снимок, пока тост на экране (≈ 2 с).
      if (!await _until(tester, () => toast.evaluate().isNotEmpty, timeout: const Duration(seconds: 15))) {
        _problem('QA (h): тост «Добавлено: …» не появился');
      } else {
        await _wait(tester, const Duration(milliseconds: 350));
        await _qaShot(tester, 'toast', main, quiet: const Duration(milliseconds: 300));
        final String text = tester.widgetList<Text>(toast).map((Text t) => t.data ?? '').join();
        _note('QA (h): тост «$text»');
        if (!text.contains(p.name)) _problem('QA (h): в тосте нет названия «${p.name}»');
      }
    }
    if (!await _until(
      tester,
      () => _card(tester, p.id)?.action == ProductCardActionKind.inCart,
      timeout: const Duration(seconds: 20),
    )) {
      _problem('QA (f): карточка «${p.name}» не перешла в «В корзине · N»');
    }
  }
  if (addable.isNotEmpty) {
    final ProductCardData first = addable.first;
    final String before = _card(tester, first.id)?.actionLabel ?? '';
    await _tapVisible(tester, _cardButton(first.id));
    await _until(tester, () => (_card(tester, first.id)?.actionLabel ?? before) != before);
    final String after = _card(tester, first.id)?.actionLabel ?? '';
    final AppButton? btn = _cardButton(first.id).evaluate().isEmpty
        ? null
        : _cardButton(first.id).evaluate().first.widget as AppButton;
    _note('QA (f): «${first.name}»: «$before» → «$after» (вариант кнопки ${btn?.variant.name})');
    if (!after.startsWith('В корзине')) _problem('QA (f): кнопка после повторного нажатия — «$after»');
    if (btn?.variant != AppButtonVariant.tint) _problem('QA (f): кнопка «В корзине» не tint (${btn?.variant.name})');
  }
  final bool confirmed = await _until(
    tester,
    () => _cartConfirmed(tester, addable.length),
    timeout: const Duration(seconds: 30),
  );
  _note('QA (f): ответ сервера получен=$confirmed; кнопка корзины: ${_headerCartText(tester)}');
  if (!confirmed) _problem('QA (f): нет подтверждённого ответа сервера по корзине за 30 с');
  // Тост к моменту снимка корзины уже скрыт (в прототипе его нет).
  await _until(tester, () => toast.evaluate().isEmpty, timeout: const Duration(seconds: 8));
  // Шапка с непустой корзиной (бейдж и итог) и часами с датой — на всех размерах; последним — основное окно.
  for (final Size s in <Size>[...sizes.where((Size x) => x != main), main]) {
    await _qaSetSize(tester, s);
    await _listReady(tester, photos: const Duration(seconds: 1));
    await _qaShot(tester, 'header_cart', s, quiet: const Duration(seconds: 1));
    _qaHeaderGeometry(tester, 'QA шапка с корзиной ${_sizeTag(s)}');
  }
  if (await _openCartDrawer(tester, 'QA (f)')) {
    await _wait(tester, const Duration(seconds: 1));
    final Set<String> lines = _drawerLineKeys();
    _note('QA (f): строк в drawer ${lines.length}');
    if (lines.length != addable.length) _problem('QA (f): строк в drawer ${lines.length} ≠ ${addable.length}');
    await _qaShot(tester, 'cart', main, toTop: false);
    await _closeCartDrawer(tester, 'QA (f)');
  }

  // (i) шапка оболочки вне каталога.
  _router(tester)!.go('/orders');
  if (!await _until(
    tester,
    () => find.byKey(_ordersRoot).evaluate().isNotEmpty,
    timeout: const Duration(seconds: 20),
  )) {
    _problem('QA (i): /orders не открылся (адрес ${_where(tester)})');
  }
  await _wait(tester, const Duration(seconds: 2));
  final bool shellHeader = find.byType(StaffShellHeader).evaluate().isNotEmpty;
  _note('QA (i): шапка оболочки StaffShellHeader=$shellHeader; кнопка корзины: ${_headerCartText(tester)}');
  if (!shellHeader) _problem('QA (i): на /orders нет шапки оболочки');
  if (_cartButton.evaluate().isEmpty) _problem('QA (i): на /orders нет кнопки корзины в шапке');
  await _qaShot(tester, 'orders_header', main, toTop: false);
  _qaHeaderGeometry(tester, 'QA шапка /orders');

  // Возврат к исходному состоянию для регрессии: пустая корзина, /catalog, окно по умолчанию.
  final CartController cart = _container(tester).read(cartControllerProvider.notifier);
  final Object? failure = await tester.runAsync<Object?>(cart.clear);
  final bool empty = await _until(
    tester,
    () => _container(tester).read(cartControllerProvider).lines.isEmpty,
    timeout: const Duration(seconds: 20),
  );
  _note('QA: корзина очищена=$empty${failure == null ? '' : ' (ответ: $failure)'}');
  _router(tester)!.go('/catalog');
  await pumpUntilFound(tester, find.byKey(_catalogRoot), timeout: const Duration(seconds: 20));
  tester.view.reset();
  await _settle(tester, frames: 6);
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  AppDataDirectory.apply(AppConfig.fromEnvironment());

  setUpAll(() async {
    final Directory d = Directory(_shotsDir);
    if (d.existsSync()) d.deleteSync(recursive: true);
    d.createSync(recursive: true);
    await _stack.start();
  });
  tearDownAll(() async {
    await _stack.stop();
    final List<String> qa = _qaIndex.isEmpty
        ? <String>['QA-снимки не снимались (E2E_SIZES пуст или сценарий прерван)']
        : <String>['QA-снимки (app ↔ прототип, D:/optomstroy/.tmp/design_ref):', ..._qaIndex];
    final List<String> tail = <String>[
      '',
      ...qa,
      '',
      'Итог: ${_problems.isEmpty ? 'проблем нет' : 'проблем ${_problems.length}'}',
      ..._problems.map((String p) => '  - $p'),
    ];
    File('$_shotsDir/report.txt').writeAsStringSync('${<String>[..._report, ...tail].join('\n')}\n');
    File('$_shotsDir/console.log').writeAsStringSync('${_console.join('\n')}\n');
  });

  testWidgets('SCR-10/11/12 на окне Windows: QA-снимки по прототипу, кадры смены категории, данные, корзина', (
    tester,
  ) async {
    // Консоль приложения: всё, что печатается, — в console.log (поиск ошибок).
    final origPrint = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) {
      if (m != null) _console.add(m);
      origPrint(m, wrapWidth: wrapWidth);
    };
    final origError = FlutterError.onError;
    final List<String> flutterErrors = <String>[];
    FlutterError.onError = (FlutterErrorDetails d) {
      flutterErrors.add(d.exceptionAsString());
      origError?.call(d);
    };
    addTearDown(() {
      debugPrint = origPrint;
      FlutterError.onError = origError;
    });

    final Size realLogical = tester.view.physicalSize / tester.view.devicePixelRatio;
    _note('окно: ${realLogical.width.round()}×${realLogical.height.round()} lp, DPR ${tester.view.devicePixelRatio}');
    addTearDown(tester.view.reset);

    // --- QA-снимки по прототипу (DPR 1), затем — регрессия на окне по умолчанию -----------------------------
    final List<Size> qaSizes = _parseSizes(_sizes);
    if (qaSizes.isNotEmpty) {
      await _qaSetSize(tester, _qaMain(qaSizes));
      await _staffLogin(tester);
      await _designQa(tester, qaSizes);
      _note('ошибок FlutterError за QA-снимки: ${flutterErrors.length}');
      tester.view.physicalSize = _mainSize * tester.view.devicePixelRatio;
      await _settle(tester);
    } else {
      _note('QA-снимки пропущены: E2E_SIZES пуст');
      tester.view.physicalSize = _mainSize * tester.view.devicePixelRatio;
      await _staffLogin(tester);
    }

    // --- SCR-10 (окно 1366×768 при DPR монитора) -----------------------------------------------------------
    await pumpUntilFound(tester, find.byKey(_catalogRoot), timeout: const Duration(seconds: 30));
    await _listReady(tester, photos: const Duration(seconds: 4));
    final _Frame shot1 = await _shot(tester, '01_catalog');
    _note('01_catalog: ${shot1.state}; колонок сетки ${_gridColumns(tester)}');
    await _checkCardsAgainstServer(tester, '01 каталог', <String, Object?>{});
    _checkAddButtonColors(tester, shot1, '01_catalog');

    final CategoryTree? tree = _container(tester).read(categoryTreeProvider).tree;
    expect(tree, isNotNull, reason: 'дерево категорий');
    final List<Category> roots = tree!.roots.where((Category c) => c.productCount > 0).toList();
    _note(
      'корневых категорий с товарами: ${roots.length}: ${roots.map((c) => '${c.name} (${c.productCount})').join(', ')}',
    );
    expect(roots.length, greaterThanOrEqualTo(2), reason: 'нужно ≥ 2 категорий');
    final Category catB = roots.firstWhere(
      (Category c) => c.children.any((Category ch) => ch.productCount > 0),
      orElse: () => roots[1],
    );
    final Category catA = roots.firstWhere((Category c) => c.id != catB.id);
    final Category? sub = catB.children.where((Category ch) => ch.productCount > 0).firstOrNull;

    // --- Категория А (из корня) ------------------------------------------------------------------------
    final Finder tileA = find.byKey(ValueKey<String>('sidebar-category-${catA.id}'));
    await _showTile(tester, tileA);
    await _settle(tester, frames: 3);
    final Stopwatch swA = Stopwatch()..start();
    await _transition(tester, 'switch_root_to_A', () => tester.tap(tileA.first));
    await pumpUntilFound(tester, find.byKey(_categoryRoot));
    await _listReady(tester);
    _note('категория А «${catA.name}»: готово за ~${swA.elapsedMilliseconds} мс (вкл. ожидание фото 3 с)');
    final _Frame shot2 = await _shot(tester, '02_category_A');
    _note('02_category_A: ${shot2.state}');
    if (!_where(tester).startsWith('/catalog/c/${catA.id}')) _problem('адрес после выбора А: ${_where(tester)}');
    await _checkCardsAgainstServer(tester, '02 категория А', <String, Object?>{'categoryId': catA.id});

    // --- Категория Б (А → Б): главная проверка мигания ---------------------------------------------------
    final Finder tileB = find.byKey(ValueKey<String>('sidebar-category-${catB.id}'));
    await _showTile(tester, tileB);
    await _settle(tester, frames: 3);
    await _transition(tester, 'switch_A_to_B', () => tester.tap(tileB.first));
    await pumpUntilFound(
      tester,
      find.byWidgetPredicate((Widget w) => _where(tester).startsWith('/catalog/c/${catB.id}')),
    );
    await _listReady(tester);
    final _Frame shot3 = await _shot(tester, '03_category_B');
    _note(
      '03_category_B «${catB.name}»: ${shot3.state}; лента подкатегорий: '
      '${find.byKey(_ribbon).evaluate().isNotEmpty}',
    );
    await _checkCardsAgainstServer(tester, '03 категория Б', <String, Object?>{'categoryId': catB.id});

    // Быстрая смена категорий подряд (Б → А → Б без ожидания): ни одного перехода страницы, итог — Б.
    final State wsBefore = tester.state(find.byType(CatalogWorkspace).last);
    await _showTile(tester, tileA);
    await tester.tap(tileA.first);
    await tester.pump(const Duration(milliseconds: 30));
    await _showTile(tester, tileB);
    await tester.tap(tileB.first);
    await _settle(tester, frames: 15);
    if (!identical(tester.state(find.byType(CatalogWorkspace).last), wsBefore)) {
      _problem('быстрая смена: экран пересоздан');
    }
    if (!_where(tester).startsWith('/catalog/c/${catB.id}')) {
      _problem('быстрая смена: итоговый адрес ${_where(tester)}');
    }
    await _listReady(tester, photos: const Duration(seconds: 1));
    final List<String> idsB = _cards(tester).map((c) => c.id).toList();
    _note('быстрая смена Б→А→Б: адрес ${_where(tester)}, карточек ${idsB.length}');

    // --- Подкатегория из ленты (без сброса шапки/колонки) ------------------------------------------------
    if (sub == null) {
      _problem('нет подкатегорий с товарами у «${catB.name}» — лента не проверена');
    } else {
      final Finder chip = find.byKey(ValueKey<String>('chip-sub-${sub.id}'));
      await pumpUntilFound(tester, chip);
      await tester.ensureVisible(chip.first);
      await _settle(tester, frames: 3);
      await _transition(tester, 'switch_B_to_sub', () => tester.tap(chip.first));
      await _settle(tester, frames: 5);
      if (!_where(tester).startsWith('/catalog/c/${sub.id}')) _problem('адрес подкатегории: ${_where(tester)}');
      await _listReady(tester);
      final _Frame shot4 = await _shot(tester, '04_subcategory');
      _note(
        '04_subcategory «${sub.name}»: ${shot4.state}; лента на месте: '
        '${find.byKey(_ribbon).evaluate().isNotEmpty}; выбрана в колонке корневая «${catB.name}»',
      );
      await _checkCardsAgainstServer(tester, '04 подкатегория', <String, Object?>{'categoryId': sub.id});
    }

    // --- Поиск в категории ------------------------------------------------------------------------------
    final Category searchCat = sub ?? catB;
    final List<ProductCardData> visible = _cards(tester);
    final String word = visible.isEmpty
        ? 'ab'
        : visible.first.name.split(RegExp(r'\s+')).firstWhere((String w) => w.length >= 3, orElse: () => 'ab');
    final Finder field = find.descendant(
      of: find.byKey(const ValueKey<String>('catalog-search-field')),
      matching: find.byType(EditableText),
    );
    await tester.tap(field.first);
    await tester.pump();
    await tester.enterText(field.first, word);
    await tester.pump();
    await _transition(
      tester,
      'search_in_category',
      () => tester.testTextInput.receiveAction(TextInputAction.search),
      expectSameInstance: false,
    );
    await pumpUntilFound(tester, find.byKey(_searchRoot));
    await _listReady(tester);
    final _Frame shot5 = await _shot(tester, '05_search_in_category');
    final String loc = _where(tester);
    _note('05_search_in_category «$word» в «${searchCat.name}»: ${shot5.state}');
    if (!loc.contains('categoryId=${searchCat.id}')) _problem('поиск в категории без categoryId: $loc');
    // Все найденные — из выбранной категории (или её потомков).
    final Set<String> subtree = <String>{};
    void collect(Category c) {
      subtree.add(c.id);
      c.children.forEach(collect);
    }

    collect(searchCat);
    final List<String> foundIds = _cards(tester).map((c) => c.id).toList();
    if (foundIds.isEmpty) _problem('поиск «$word» в категории: пусто');
    final List<QueryRow> cats =
        await tester.runAsync(
          () => _db(tester)
              .customSelect(
                'SELECT id, category_id FROM products WHERE id IN (${List<String>.filled(foundIds.length, '?').join(',')})',
                variables: <Variable<Object>>[for (final String id in foundIds) Variable<String>(id)],
              )
              .get(),
        ) ??
        const <QueryRow>[];
    final int outside = cats.where((QueryRow r) => !subtree.contains(r.readNullable<String>('category_id'))).length;
    _note('поиск в категории: найдено ${foundIds.length}, вне категории $outside');
    if (outside > 0) _problem('поиск в категории: $outside товаров вне «${searchCat.name}»');
    await _checkCardsAgainstServer(tester, '05 поиск в категории', <String, Object?>{
      'q': word,
      'categoryId': searchCat.id,
    }, path: '/search/products');
    // «Назад» — в ту же категорию.
    final State searchWs = tester.state(find.byType(CatalogWorkspace).last);
    _router(tester)!.pop();
    await _settle(tester, frames: 5);
    _note(
      'после «Назад» из поиска: ${_where(tester)}; экран поиска закрыт: '
      '${!identical(tester.state(find.byType(CatalogWorkspace).last), searchWs)}',
    );
    if (!_where(tester).startsWith('/catalog/c/${searchCat.id}')) _problem('«Назад» из поиска: ${_where(tester)}');
    await _listReady(tester, photos: const Duration(seconds: 1));

    // --- Сортировка (по возрастанию цены) ----------------------------------------------------------------
    await _tap(tester, find.byKey(const ValueKey<String>('catalog-sort')));
    await _settle(tester, frames: 5);
    final Finder priceAsc = find.text('По возрастанию цены');
    await pumpUntilFound(tester, priceAsc);
    await tester.tap(priceAsc.last);
    await _settle(tester, frames: 5);
    await _listReady(tester, photos: const Duration(seconds: 1));
    final List<int> prices = <int>[
      for (final ProductCardData c in _cards(tester))
        if (c.price != null) c.price!.tyiyn,
    ];
    bool sorted = true;
    for (int i = 1; i < prices.length; i++) {
      if (prices[i] < prices[i - 1]) sorted = false;
    }
    _note(
      'сортировка «По возрастанию цены»: адрес ${_where(tester)}; цен ${prices.length}, по возрастанию=$sorted; '
      'первые: ${prices.take(5).map((t) => Money(t).toApiString()).join(', ')}',
    );
    if (!sorted) _problem('сортировка по цене не по возрастанию');
    if (!_where(tester).contains('sort=price')) _problem('сортировка не в адресе: ${_where(tester)}');

    // --- Фильтр «В наличии»: «Фильтры» → встроенная панель → флажок «Только в наличии» -------------------
    await _tap(tester, find.byKey(_filtersButton));
    await _settle(tester, frames: 5);
    final bool panel = find.byKey(_filterPanel).evaluate().isNotEmpty;
    _note('панель фильтров открыта: $panel');
    if (!panel) _problem('панель фильтров не открылась');
    final Finder inStock = find.byKey(_inStock);
    if (inStock.evaluate().isNotEmpty) {
      await _tap(tester, inStock);
      await _wait(tester, const Duration(seconds: 2));
      await _listReady(tester, photos: const Duration(seconds: 1));
      final List<ProductCardData> fc = _cards(tester);
      final int outCount = fc.where((c) => c.stockLevel == StockBadgeLevel.out).length;
      await _shot(tester, '05b_filters_in_stock');
      _note('фильтр «В наличии»: адрес ${_where(tester)}; карточек ${fc.length}, без остатка $outCount');
      if (outCount > 0) _problem('фильтр «В наличии»: $outCount карточек без остатка');
      await _tap(tester, inStock);
      await _wait(tester, const Duration(seconds: 1));
    }
    await _tap(tester, find.byKey(_filtersButton));
    await _settle(tester, frames: 5);
    if (find.byKey(_filterPanel).evaluate().isNotEmpty) _problem('панель фильтров не закрылась');

    // --- Виды: список и компакт -----------------------------------------------------------------------
    await _tap(tester, find.byKey(const ValueKey<String>('view-mode-list')));
    await pumpUntilFound(tester, find.byType(ProductCardList));
    await _listReady(tester, photos: const Duration(seconds: 2));
    final _Frame shot6 = await _shot(tester, '06_list_view');
    _note('06_list_view: ${shot6.state}; ${_where(tester)}');
    await _tap(tester, find.byKey(const ValueKey<String>('view-mode-compact')));
    await pumpUntilFound(tester, find.byType(ProductCardCompact));
    await _listReady(tester, photos: const Duration(seconds: 2));
    final _Frame shot7 = await _shot(tester, '07_compact_view');
    _note('07_compact_view: ${shot7.state}; ${_where(tester)}');
    // Вид сохраняется при смене категории.
    await _showTile(tester, tileA);
    await tester.tap(tileA.first);
    await _settle(tester, frames: 10);
    await _listReady(tester, photos: const Duration(seconds: 1));
    final bool keepsCompact = find.byType(ProductCardCompact).evaluate().isNotEmpty;
    _note('вид «Компакт» после смены категории сохранён: $keepsCompact (${_where(tester)})');
    if (!keepsCompact) _problem('вид сбрасывается при смене категории');
    await _tap(tester, find.byKey(const ValueKey<String>('view-mode-grid')));
    await pumpUntilFound(tester, find.byType(ProductCardGrid));
    await _listReady(tester, photos: const Duration(seconds: 1));

    // --- Узкое окно: колонки ----------------------------------------------------------------------------
    final int colsMain = _gridColumns(tester);
    tester.view.physicalSize = _narrowSize * tester.view.devicePixelRatio;
    await _settle(tester, frames: 10);
    await _listReady(tester, photos: const Duration(seconds: 2));
    final _Frame shot8 = await _shot(tester, '08_narrow_window');
    final int colsNarrow = _gridColumns(tester);
    _note(
      '08_narrow_window ${_narrowSize.width.round()} lp: ${shot8.state}; колонок $colsNarrow (при ${_mainSize.width.round()} lp — $colsMain)',
    );
    tester.view.physicalSize = _mediumSize * tester.view.devicePixelRatio;
    await _settle(tester, frames: 10);
    await _listReady(tester, photos: const Duration(seconds: 2));
    final _Frame shot8b = await _shot(tester, '08b_medium_window');
    _note('08b_medium_window ${_mediumSize.width.round()} lp: ${shot8b.state}; колонок ${_gridColumns(tester)}');
    // Горизонтальное переполнение: ошибки раскладки попадают во flutterErrors.
    tester.view.physicalSize = _mainSize * tester.view.devicePixelRatio;
    await _settle(tester, frames: 10);
    await _listReady(tester, photos: const Duration(seconds: 1));

    // --- Добавление в корзину без дублей ---------------------------------------------------------------
    final List<ProductCardData> addable = _cards(tester).where((c) => c.action == ProductCardActionKind.add).toList();
    expect(addable, isNotEmpty, reason: 'в категории есть товар с «+ Добавить»');
    final ProductCardData target = addable.first;
    final List<QueryRow> vrows =
        await tester.runAsync(
          () => _db(tester)
              .customSelect(
                'SELECT id FROM product_variants WHERE product_id = ? AND is_default = 1 AND deletion_mark = 0',
                variables: <Variable<Object>>[Variable<String>(target.id)],
              )
              .get(),
        ) ??
        const <QueryRow>[];
    final String variantId = vrows.single.read<String>('id');
    final List<CartDraftLine> linesBefore = await _draftLines(tester);
    final Finder cardAdd = find.descendant(
      of: find.byKey(ValueKey<String>('product-${target.id}')),
      matching: find.byWidgetPredicate(
        (Widget w) =>
            (w is AppButton && w.onPressed != null) ||
            (w is AppIconButton && w.icon == Icons.add_rounded && w.onPressed != null),
      ),
    );
    await tester.ensureVisible(cardAdd.first);
    await tester.pump();
    final Stopwatch swAdd = Stopwatch()..start();
    // Двойное быстрое нажатие (как торопящийся продавец): одна строка, без дублей.
    await tester.tap(cardAdd.first);
    await tester.pump(const Duration(milliseconds: 40));
    if (cardAdd.evaluate().isNotEmpty) await tester.tap(cardAdd.first, warnIfMissed: false);
    final List<CartDraftLine> after1 = await pumpUntil<List<CartDraftLine>>(tester, () async {
      final List<CartDraftLine> l = await _container(tester)
          .read(cartDraftRepositoryProvider)
          .lines()
          .then((r) => r.fold((List<CartDraftLine> x) => x, (_) => const <CartDraftLine>[]));
      return l.any((x) => x.variantId == variantId) ? l : null;
    }, what: 'строка черновика после «+ Добавить»');
    _note('«+ Добавить» → строка черновика за ${swAdd.elapsedMilliseconds} мс');
    await _wait(tester, const Duration(seconds: 2));
    final List<CartDraftLine> after2 = await _draftLines(tester);
    final List<CartDraftLine> same = after2.where((x) => x.variantId == variantId).toList();
    _note(
      'добавление «${target.name}»: строк до ${linesBefore.length}, после ${after2.length}; строк этого товара '
      '${same.length}, количество ${same.map((x) => x.quantity.milli / 1000).join(', ')} (после 1-го ответа ${after1.length})',
    );
    if (same.length != 1) _problem('дубли строк корзины: ${same.length}');
    // Повторное нажатие после ответа («В корзине · N — ещё +1») — то же количество + шаг, одна строка.
    await _tap(tester, cardAdd.first);
    await _wait(tester, const Duration(seconds: 2));
    final List<CartDraftLine> after3 = (await _draftLines(tester)).where((x) => x.variantId == variantId).toList();
    _note(
      'повторное «+ Добавить»: строк товара ${after3.length}, количество ${after3.map((x) => x.quantity.milli / 1000).join(', ')}; '
      'кнопка «${_card(tester, target.id)?.actionLabel}»',
    );
    if (after3.length != 1) _problem('повторное добавление создало дубль');
    if (after3.isNotEmpty && same.isNotEmpty && after3.single.quantity.milli <= same.single.quantity.milli) {
      _problem('повторное добавление не увеличило количество');
    }
    // Строка — в drawer корзины (кнопка-итог в шапке, ADR-112).
    final Finder cartLine = find.descendant(
      of: _cartDrawer,
      matching: find.byKey(ValueKey<String>('cart-line-$variantId-')),
    );
    if (await _openCartDrawer(tester, '09_after_add')) {
      await pumpUntilFound(tester, cartLine, timeout: const Duration(seconds: 20));
      await _wait(tester, const Duration(seconds: 1));
      final _Frame shot9 = await _shot(tester, '09_after_add');
      _note(
        '09_after_add: ${shot9.state}; строка в drawer корзины: ${cartLine.evaluate().isNotEmpty}; '
        'кнопка корзины: ${_headerCartText(tester)}',
      );
      await _closeCartDrawer(tester, '09_after_add');
    }

    // Корзина сохраняется при смене категории: кнопка в шапке та же, строка в черновике и в drawer.
    final Element? cartBefore = _cartButton.evaluate().lastOrNull;
    await _showTile(tester, tileB);
    await tester.tap(tileB.first);
    await _settle(tester, frames: 10);
    await _listReady(tester, photos: const Duration(seconds: 1));
    final bool sameCartButton = identical(_cartButton.evaluate().lastOrNull, cartBefore);
    final int linesAfterSwitch = (await _draftLines(tester)).where((x) => x.variantId == variantId).length;
    bool stillInCart = false;
    if (await _openCartDrawer(tester, '10_cart_after_switch')) {
      stillInCart = await _until(tester, () => cartLine.evaluate().isNotEmpty);
      await _shot(tester, '10_cart_after_switch');
      await _closeCartDrawer(tester, '10_cart_after_switch');
    }
    _note(
      'после смены категории: строка в drawer $stillInCart, в черновике $linesAfterSwitch; '
      'та же кнопка корзины в шапке=$sameCartButton (${_headerCartText(tester)})',
    );
    if (!stillInCart || linesAfterSwitch != 1) _problem('корзина потеряна при смене категории');
    if (!sameCartButton) _problem('кнопка корзины в шапке пересоздана при смене категории');

    // Ошибки Flutter за сценарий.
    _note(
      'ошибок FlutterError: ${flutterErrors.length}${flutterErrors.isEmpty ? '' : ': ${flutterErrors.take(3).join(' | ')}'}',
    );
    for (final String e in flutterErrors.take(5)) {
      _problem('FlutterError: ${e.split('\n').first}');
    }
    // Сетевые повторы черновика (cart.sync) — дождаться, чтобы закрытие не обрывало соединения.
    await _wait(tester, const Duration(seconds: 4));
    binding.reportData = <String, Object?>{'problems': _problems, 'report': _report, 'qa': _qaIndex};
    expect(_problems, isEmpty, reason: _problems.join('\n'));
  });
}
