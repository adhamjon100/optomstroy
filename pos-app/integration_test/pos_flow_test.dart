// RM-F-009 (Flutter-часть), RM-F-011: сквозной путь этапа F на Windows против локального стека
// `pos-api/scripts/local-stack.mjs serve --pos-fixtures` (pos-api + pos-worker + управляемый фейк HTTP-сервиса
// расширения 1С `scripts/pos_fake_onec.ts`; каталог 500 SKU + фикстуры 1С). **На фикстурах, не реальная интеграция.**
//
// Сценарии (02 ч. C SCR-20…SCR-26; 10 CART-, ORD-, PAY-, PRINT-; 12 T-CART, T-ORD, T-PAY, T-PRINT, T-FAIL):
//   1. продавец (приглашение): вход → SCR-10 → кэш каталога → «+ Добавить» двух товаров (SCR-11) → SCR-20: две
//      позиции подтверждены сервером, ручная скидка в лимите роли (3 % ≤ 5 %) — итоги считает сервер (D-23) →
//      SCR-21: получатель — сам клиент, самовывоз, QR → POST /orders → SCR-22: QR из 1С (`QR_PROVIDER=onec`) →
//      оплата в фейке 1С (`POST /__fake/qr/{paymentId}/pay`) → опрос воркера → «Оплачено» → SCR-24 → товарный чек
//      PDF: файл получен (`%PDF`), предпросмотр без принтера (PdfPreview, без «Поделиться»);
//   2. клиент (регистрация): SCR-50 → «+ Добавить» → SCR-20 → SCR-21 режима клиента (самовывоз, наличные) →
//      «Отправить заявку» → SCR-22 → «Мои заказы» SCR-25: свой заказ в списке;
//   3. перезапуск стека с `--qr-provider none`: старший продавец → корзина → SCR-21 (QR) → SCR-22 «QR не из 1С,
//      подтверждается вручную» → «Подтвердить вручную» (реф. банка) → StepUpDialog (PIN) → оплачено → SCR-24;
//   4. офлайн при оформлении (продолжение 3): SCR-21 открыт → стек остановлен → «Создать заказ» → результат
//      неизвестен: SCR-21 закрывается, корзина SCR-20 заблокирована оверлеем UI-20-020 «Проверяем результат…»,
//      черновик `checkout_draft` (ключ — `cart_draft.local_id`) хранит ключ `POST /orders` и `submitted_at`
//      (ядро §22.6, 07 §11.2; 10 CART-022 (а));
//   5. (продолжение 1) перезапуск приложения над той же БД пользователя: черновик корзины (2 строки) на месте,
//      затем `GET /cart` (RM-F-005 п. 2); 1С недоступна (`/__fake/down`) → «Создать заказ» → SCR-22 «Ожидает
//      отправки в 1С» (`submitting`) → после восстановления 1С — уведомление `order_status` автору (RM-F-007 п. 2);
//   6. перезапуск стека (`QR_PROVIDER=onec`), старший продавец: ответы `POST /orders` теряются транспортом теста (запрос дошёл,
//      заказ создан — результат неизвестен, ядро §22.6) → RetryInterceptor и фоновые повторы UI-20-020 — с тем же
//      `Idempotency-Key` → ответ-повтор → SCR-22; на сервере по ключу ровно один заказ (10 CART-022 (а), ORD-028;
//      F-flutter-ui-1, F-flutter-data);
//   7. (продолжение 6) QR-заказ → SCR-22 ожидает оплату → перезапуск приложения → SCR-24 «Показать QR» → SCR-22
//      (только чтение, действие «Проверить») → оплата в фейке 1С → ожидание статуса возобновлено без нажатий →
//      «Оплачено» → SCR-24; после перезапуска ни одного `POST` заказов и платежей (RM-F-013 п. 4; 13 §3.6).
//
// Данные приложения — в `APP_DATA_DIR` из `env/local.json` (машина разработки, вне git; D:, не %APPDATA% на C:;
// lib/core/config/app_data_directory.dart).
//
// Выбор клиента в SCR-21 (поиск `GET /customers`) не проверяется: список клиентов — RM-G-001 (этап G), backend
// этапа F отвечает 404 — F_spec_questions FQ-INT-F-02.
//
// Стеком управляет тест: `setUpAll` — `serve --pos-fixtures --qr-paid-after-polls 0 --exit-on-stdin-end` (оплата QR —
// только управляющим вызовом теста), сценарий 3 перезапускает стек с `--qr-provider none`, `tearDownAll` закрывает
// stdin (штатная остановка API, воркера, фейка, прокси и PostgreSQL). Требуется `npm run build` в pos-api.
//
//   cd pos-api && npm run build
//   cd pos-app && flutter test integration_test/pos_flow_test.dart -d windows --dart-define-from-file=env/dev_proxy.json --dart-define-from-file=env/local.json
//
// Номера и код — `AUTH_FIXTURES` стека (+99677700090N, синтетические); телефоны, код и PIN в лог не выводятся
// (11 SEC-062).
@Timeout(Duration(minutes: 30))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart' show IOHttpClientAdapter;
import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:optomstroy/app/bootstrap.dart';
import 'package:optomstroy/app/di/overrides.dart' show appCheckoutPrinterProvider, appOrderDocumentPrinterProvider;
import 'package:optomstroy/core/config/app_data_directory.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/features/auth/presentation/screens/no_session_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/otp_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/phone_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/unlock_screen.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_controller.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_panel_view.dart' show CartKeys;
import 'package:optomstroy/features/catalog/presentation/screens/customer_home_view.dart';
import 'package:optomstroy/features/checkout/presentation/controllers/order_submission_recovery.dart';
import 'package:optomstroy/features/notifications/domain/entities/app_notification.dart';
import 'package:optomstroy/features/notifications/presentation/notifiers/notifications_center_controller.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/presentation/providers/orders_ports.dart';
import 'package:optomstroy/features/orders/presentation/providers/printing_document_printer.dart';
import 'package:optomstroy/features/registration/presentation/screens/registration_form_screen.dart';
import 'package:optomstroy/features/registration/presentation/screens/registration_security_screen.dart';
import 'package:optomstroy/features/session_ui/presentation/widgets/step_up_dialog.dart';
import 'package:optomstroy/features/splash/presentation/screens/splash_screen.dart';
import 'package:printing/printing.dart' show PdfPreview;

/// Тестовый код OTP контура (`AUTH_FIXTURES.otpCode`).
const String _otpCode = String.fromEnvironment('E2E_OTP_CODE', defaultValue: '246810');

/// Национальные номера (9 цифр) из `AUTH_FIXTURES`: приглашённый продавец, клиент без карточки 1С, старший продавец.
const String _sellerPhone = String.fromEnvironment('E2E_STAFF_PHONE', defaultValue: '777000902');
const String _customerPhone = String.fromEnvironment('E2E_CUSTOMER_PHONE', defaultValue: '777000905');
const String _seniorPhone = String.fromEnvironment('E2E_SENIOR_PHONE', defaultValue: '777000907');

/// PIN (тестовые, только этот стек).
const String _sellerPin = '582914';
const String _seniorPin = '826493';
const String _customerPin = '5173';

/// Каталог pos-api (local-stack.mjs); пусто — поиск `pos-api` вверх от рабочего каталога и exe.
const String _apiDirDefine = String.fromEnvironment('E2E_API_DIR');

/// Синтетических SKU стека.
const String _catalogSku = String.fromEnvironment('E2E_CATALOG_SKU', defaultValue: '500');

/// Управляющие вызовы фейка 1С (`LOCAL_STACK_ONEC_PORT`, dev-only).
const String _fakeOnec = String.fromEnvironment('E2E_FAKE_ONEC', defaultValue: 'http://127.0.0.1:8091');

const Key _catalogRoot = ValueKey<String>('stub-SCR-10');
const Key _cartRoot = ValueKey<String>('stub-SCR-20');
const Key _checkoutRoot = ValueKey<String>('checkout-screen');
const Key _createdRoot = ValueKey<String>('order-created-screen');
const Key _orderRoot = ValueKey<String>('stub-SCR-24');
const Key _ordersRoot = ValueKey<String>('stub-SCR-25');

final _LocalStack _stack = _LocalStack();
final _RecordingPrinter _printer = _RecordingPrinter();
final _NetLog _net = _NetLog();

// ---------------------------------------------------------------------------
// Транспорт API теста: журнал запросов и «потеря ответа» `POST /orders` (запрос дошёл до сервера, ответ — нет)
// ---------------------------------------------------------------------------

/// Журнал транспорта (переживает перезапуск приложения: новый Dio — новый адаптер над тем же журналом).
final class _NetLog {
  /// `METHOD /api/v1/...` всех запросов API.
  final List<String> requests = <String>[];

  /// `Idempotency-Key` каждой попытки `POST /orders`.
  final List<String?> orderCreates = <String?>[];

  /// Пока `true`, ответ на `POST /orders` читается и отбрасывается, клиент получает `receiveTimeout`.
  bool dropOrderCreate = false;
}

final class _LossyAdapter implements HttpClientAdapter {
  _LossyAdapter(this._log);

  final _NetLog _log;
  IOHttpClientAdapter? _inner;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final String method = options.method.toUpperCase();
    final bool create = method == 'POST' && options.uri.path.endsWith('/orders');
    _log.requests.add('$method ${options.uri.path}');
    if (create) _log.orderCreates.add(options.headers[ApiHeaders.idempotencyKey] as String?);
    final ResponseBody body = await (_inner ??= IOHttpClientAdapter()).fetch(options, requestStream, cancelFuture);
    if (create && _log.dropOrderCreate) {
      await body.stream.drain<void>();
      throw DioException.receiveTimeout(timeout: ApiTimeouts.orderCreate, requestOptions: options);
    }
    return body;
  }

  @override
  void close({bool force = false}) {
    _inner?.close(force: force);
    _inner = null;
  }
}

/// Переопределения каждого запуска приложения в тесте.
List<Override> _overrides() => <Override>[
  appOrderDocumentPrinterProvider.overrideWithValue(_printer),
  // Печать SCR-22 (счёт при появлении номера 1С, PRINT-009) — без системного диалога печати Windows.
  appCheckoutPrinterProvider.overrideWithValue(_printer.print),
  httpClientAdapterProvider.overrideWith((Ref ref) => _LossyAdapter(_net)),
];

// ---------------------------------------------------------------------------
// Локальный стек: запуск, ожидание готовности, штатная остановка
// ---------------------------------------------------------------------------

final class _LocalStack {
  Process? _process;
  IOSink? _log;
  Future<int>? _exit;
  int _runs = 0;

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

  Future<void> start({String qrProvider = 'onec'}) async {
    final Directory api = _apiDir();
    final String sep = Platform.pathSeparator;
    _runs++;
    final File ready = File('${_tmp()}${sep}pos_flow_ready_${DateTime.now().millisecondsSinceEpoch}.txt');
    final File logFile = File('${_tmp()}${sep}pos_flow_stack_$_runs.log');
    _log = logFile.openWrite();
    final Process p = await Process.start(
      'node',
      <String>[
        'scripts/local-stack.mjs',
        'serve',
        '--pos-fixtures',
        '--catalog-fixtures=$_catalogSku',
        '--qr-provider',
        qrProvider,
        '--qr-paid-after-polls',
        '0',
        '--ready-file',
        ready.path,
        '--exit-on-stdin-end',
      ],
      workingDirectory: api.path,
      environment: <String, String>{
        'LOCAL_STACK_MIN_APP_VERSION': 'android=0.1.0,windows=0.1.0',
        // Журналы api/worker/фейка 1С сохраняются при остановке (разбор падений).
        'LOCAL_STACK_LOG_DIR': '${_tmp()}${sep}pos_flow_logs_$_runs',
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
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('local-stack не поднялся за 10 мин; журнал: ${logFile.path}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    ready.deleteSync();
    debugPrint('pos_flow_test: стек готов (QR_PROVIDER=$qrProvider; журнал ${logFile.path})');
  }

  /// Штатная остановка (`--exit-on-stdin-end`): API, воркер, фейк 1С, прокси и PostgreSQL.
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
    debugPrint('pos_flow_test: стек остановлен (код $code)');
  }
}

/// Управляющий вызов фейка 1С (dev-only; заголовки не нужны).
Future<Map<String, Object?>> _fake(String method, String path, [Map<String, Object?>? body]) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest req = await client.openUrl(method, Uri.parse('$_fakeOnec$path'));
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final HttpClientResponse res = await req.close();
    final String text = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 300) throw StateError('фейк 1С $method $path → ${res.statusCode}');
    final Object? json = text.isEmpty ? null : jsonDecode(text);
    return json is Map<String, Object?> ? json : <String, Object?>{'value': json};
  } finally {
    client.close(force: true);
  }
}

/// Печать документов в тесте: файл запоминается (проверка `%PDF`), предпросмотр — настоящий `PdfPreview` пакета
/// `printing` (без принтера); системный диалог печати не открывается.
final class _RecordingPrinter implements OrderDocumentPrinter {
  final List<OrderDocumentFile> files = <OrderDocumentFile>[];

  @override
  Future<void> preview(BuildContext context, OrderDocumentFile file) {
    files.add(file);
    return const PrintingOrderDocumentPrinter().preview(context, file);
  }

  @override
  Future<bool> print(OrderDocumentFile file) async {
    files.add(file);
    return false;
  }
}

// ---------------------------------------------------------------------------
// Общие шаги (как catalog_flow_test.dart)
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

/// Ждёт синхронного условия по состоянию виджетов/провайдеров, прокачивая кадры.
Future<void> pumpUntilTrue(
  WidgetTester tester,
  bool Function() condition, {
  required String what,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!condition()) {
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

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(Navigator).first), listen: false);

Finder _input(Key key) => find.descendant(of: find.byKey(key), matching: find.byType(EditableText));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

/// Кнопка [key], доступная для нажатия (AppButton с `onPressed`).
Finder _enabledButton(Key key) =>
    find.byWidgetPredicate((Widget w) => w is AppButton && w.key == key && w.onPressed != null);

Future<void> _enterPin(WidgetTester tester, String pin, {Finder? scope}) async {
  final Finder field = scope == null
      ? find.byType(PinField).first
      : find.descendant(of: scope, matching: find.byType(PinField)).first;
  for (final String d in pin.split('')) {
    final Finder label = find.descendant(of: field, matching: find.text(d));
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
  _enabledButton(RegistrationSecurityScreen.completeKey),
  timeout: const Duration(seconds: 10),
);

Future<void> _cleanStart(WidgetTester tester) async {
  _printer.files.clear();
  await FlutterSecureStorageAdapter().deleteAll(<SecureKey>[...SecureKey.session, ...SecureKey.registration]);
  await bootstrap(overrides: _overrides());
  await tester.pump();
  await pumpUntilFound(tester, find.byKey(SplashScreen.screenKey));
  await pumpUntilFound(tester, find.byKey(NoSessionScreen.screenKey));
}

/// Перезапуск приложения (новый корень и контейнер провайдеров над той же БД пользователя `pos_<userId>.db`):
/// холодный старт → SCR-08 «Разблокировка» (PIN) → SCR-10.
Future<void> _restartApp(WidgetTester tester, String pin) async {
  // Прежний корень закрывается (контейнер, БД пользователя), затем — новый запуск.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
  await bootstrap(overrides: _overrides());
  await tester.pump();
  await pumpUntilFound(tester, find.byKey(UnlockScreen.screenKey), timeout: const Duration(seconds: 60));
  await pumpUntilFound(tester, find.byType(PinField));
  await _settle(tester);
  await _enterPin(tester, pin);
  await pumpUntilFound(tester, find.byKey(_catalogRoot), timeout: const Duration(seconds: 60));
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

/// Первый вход сотрудника (приглашение или учётная запись без PIN): SCR-04 → PIN → SCR-10.
Future<void> _staffFirstLogin(WidgetTester tester, String phone, String pin) async {
  await _cleanStart(tester);
  await _phoneAndOtp(tester, phone);
  await pumpUntilFound(tester, find.byKey(RegistrationSecurityScreen.screenKey), timeout: const Duration(seconds: 60));
  await pumpUntilFound(tester, find.byType(PinField));
  await _settle(tester);
  await _enterPin(tester, pin);
  await _enterPin(tester, pin);
  if (find.byKey(RegistrationSecurityScreen.pdAckKey).evaluate().isNotEmpty) {
    await _tap(tester, find.byKey(RegistrationSecurityScreen.pdAckKey));
  }
  await _expectCompleteEnabled(tester);
  await _tap(tester, find.byKey(RegistrationSecurityScreen.completeKey));
  await pumpUntilFound(tester, find.byKey(_catalogRoot), timeout: const Duration(seconds: 60));
  await _waitCatalogCache(tester);
}

/// Чтение API тем же клиентом приложения (токен текущей сессии): JSON-объект ответа.
Future<Map<String, Object?>> _api(WidgetTester tester, String path, [Map<String, Object?>? query]) async {
  final Dio dio = _container(tester).read(dioProvider);
  final Response<Object?>? r = await tester.runAsync(() => dio.get<Object?>(path, queryParameters: query));
  final Object? data = r?.data;
  if (data is! Map<String, Object?>) fail('GET $path: ответ не объект');
  return data;
}

AppDatabase _db(WidgetTester tester) {
  final AppDatabase? db = _container(tester).read(appDatabaseProvider);
  if (db == null) fail('БД пользователя не открыта после входа');
  return db;
}

Future<void> _waitCatalogCache(WidgetTester tester) async {
  await pumpUntil<bool>(
    tester,
    () async => _container(tester).read(catalogFreshnessProvider).fullyLoaded ? true : null,
    what: 'первичная загрузка кэша каталога',
    timeout: const Duration(minutes: 5),
  );
}

typedef _Sku = ({String productId, String sku, String variantId});

/// [n] продаваемых товаров без характеристик в наличии на складе по умолчанию, с ценой, целые количества.
/// [customer] — у клиента в кэше нет чисел остатков: только `stock_level` (10 CUST-022).
Future<List<_Sku>> _sellable(WidgetTester tester, int n, {bool customer = false, int skip = 0}) async {
  final AppDatabase db = _db(tester);
  final List<_Sku> rows =
      await tester.runAsync(() async {
        final String? warehouse = await db.catalogDao.defaultWarehouseId();
        final String stock = customer ? "s.stock_level = 'in_stock'" : 's.available_milli >= 20000';
        final List<QueryRow> res = await db
            .customSelect(
              'SELECT p.id AS pid, p.sku AS sku, v.id AS vid FROM products p '
              'JOIN product_variants v ON v.product_id = p.id AND v.deletion_mark = 0 AND v.is_default = 1 '
              'JOIN stock_balances s ON s.variant_id = v.id AND s.warehouse_id = ? AND $stock '
              'WHERE p.deletion_mark = 0 AND p.has_variants = 0 AND p.is_sellable = 1 AND p.qty_precision = 0 '
              'AND p.sku IS NOT NULL AND length(p.sku) >= 4 '
              'AND EXISTS (SELECT 1 FROM prices pr WHERE pr.variant_id = v.id AND pr.packaging_id IS NULL '
              'AND pr.price_tyiyn > 0) '
              'AND (SELECT COUNT(*) FROM products p2 WHERE p2.sku = p.sku) = 1 '
              'ORDER BY p.sku LIMIT ? OFFSET ?',
              variables: <Variable<Object>>[Variable<String>(warehouse ?? ''), Variable<int>(n), Variable<int>(skip)],
            )
            .get();
        return <_Sku>[
          for (final QueryRow r in res)
            (productId: r.read<String>('pid'), sku: r.read<String>('sku'), variantId: r.read<String>('vid')),
        ];
      }) ??
      const <_Sku>[];
  expect(rows, hasLength(n), reason: 'в кэше каталога есть $n продаваемых товаров без характеристик');
  return rows;
}

/// SCR-11 по артикулу → «+ Добавить» на карточке (порт `CatalogCartPort` → `CartSync.addStep` → `cart.sync`).
Future<void> _addFromCatalog(WidgetTester tester, _Sku item) async {
  _router(tester)!.go('/catalog/search?q=${Uri.encodeQueryComponent(item.sku)}');
  final Finder card = find.byKey(ValueKey<String>('product-${item.productId}'));
  await pumpUntilFound(tester, card, timeout: const Duration(seconds: 30));
  await _settle(tester, frames: 3);
  final Finder add = find.descendant(
    of: card.first,
    matching: find.byWidgetPredicate(
      (Widget w) =>
          (w is AppButton && w.onPressed != null) ||
          (w is AppIconButton && w.icon == Icons.add_rounded && w.onPressed != null),
    ),
  );
  await pumpUntilFound(tester, add);
  await _tap(tester, add.first);
  await _settle(tester, frames: 5);
}

/// Серверная корзина (последний ответ `CartSync`).
Cart? _serverCart(WidgetTester tester) => _container(tester).read(cartControllerProvider).server;

/// SCR-20: строки [items] подтверждены сервером (цены/итоги — только из ответа, D-23).
Future<Cart> _openCartWith(WidgetTester tester, List<_Sku> items) async {
  _router(tester)!.go('/cart');
  await pumpUntilFound(tester, find.byKey(_cartRoot));
  for (final _Sku i in items) {
    await pumpUntilFound(tester, find.byKey(ValueKey<String>('cart-line-${i.variantId}-')));
  }
  await pumpUntilTrue(tester, () {
    final Cart? c = _serverCart(tester);
    return c != null &&
        items.every((i) => c.items.any((CartLine l) => l.variantId == i.variantId)) &&
        !_container(tester).read(cartControllerProvider).hasUnconfirmed;
  }, what: 'корзина подтверждена сервером (${items.length} позиции)');
  return _serverCart(tester)!;
}

/// SCR-20 «Создать заказ» → SCR-21.
Future<void> _toCheckout(WidgetTester tester) async {
  await pumpUntilFound(tester, _enabledButton(CartKeys.createOrder));
  await _tap(tester, _enabledButton(CartKeys.createOrder));
  await pumpUntilFound(tester, find.byKey(_checkoutRoot));
  await _settle(tester);
}

/// SCR-21: самовывоз + способ оплаты [method] → кнопка создания доступна (предпроверка выполнена).
Future<void> _fillCheckout(WidgetTester tester, String method) async {
  final Finder pickup = find.byKey(const ValueKey<String>('checkout-delivery-pickup'));
  await pumpUntilFound(tester, pickup);
  await _tap(tester, pickup);
  await _settle(tester, frames: 3);
  final Finder pay = find.byKey(ValueKey<String>('payment-method-$method'));
  await pumpUntilFound(tester, pay, timeout: const Duration(seconds: 30));
  await _tap(tester, pay.first);
  await _settle(tester, frames: 3);
  await _openCheckoutReview(tester);
  await pumpUntilFound(
    tester,
    _enabledButton(const ValueKey<String>('checkout-cta')),
    timeout: const Duration(seconds: 30),
  );
}

/// compact/medium — пошаговый SCR-21 («Далее» до последнего шага); expanded — всё на одном экране.
Future<void> _openCheckoutReview(WidgetTester tester) async {
  for (int i = 0; i < 4; i++) {
    final Finder next = _enabledButton(const ValueKey<String>('checkout-next'));
    if (next.evaluate().isEmpty) return;
    await _tap(tester, next.first);
    await _settle(tester, frames: 5);
  }
}

/// SCR-22 после `POST /orders`: `orderId` и `paymentId` из адреса `/orders/{id}/created?paymentId=`.
Future<({String orderId, String? paymentId})> _createdOrder(WidgetTester tester) async {
  await pumpUntilFound(tester, find.byKey(_createdRoot), timeout: const Duration(seconds: 60));
  final Uri uri = Uri.parse(_where(tester));
  final List<String> seg = uri.pathSegments;
  expect(seg.length >= 3 && seg[0] == 'orders' && seg[2] == 'created', isTrue, reason: 'SCR-22: $uri');
  return (orderId: seg[1], paymentId: uri.queryParameters['paymentId']);
}

Finder _qrPanel() => find.byWidgetPredicate(
  (Widget w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('order-created-qr-'),
);

/// SCR-24 → «Товарный чек» → «Просмотр»: PDF с backend получен, `PdfPreview` без принтера; закрытие.
Future<void> _previewReceipt(WidgetTester tester, String orderId) async {
  await pumpUntilFound(tester, find.byKey(_orderRoot), timeout: const Duration(seconds: 60));
  expect(_where(tester), contains('/orders/$orderId'));
  final Finder preview = _enabledButton(const ValueKey<String>('doc-receipt-preview'));
  await pumpUntilFound(tester, preview, timeout: const Duration(seconds: 60));
  final int before = _printer.files.length;
  await _tap(tester, preview.first);
  await pumpUntilTrue(tester, () => _printer.files.length > before, what: 'PDF товарного чека получен');
  final OrderDocumentFile file = _printer.files.last;
  expect(String.fromCharCodes(file.bytes.take(4)), '%PDF', reason: 'товарный чек — PDF от backend (D-27)');
  expect(file.fileName, endsWith('.pdf'));
  await pumpUntilFound(tester, find.byType(PdfPreview), timeout: const Duration(seconds: 30));
  await _settle(tester, frames: 20);
  debugPrint('pos_flow_test: товарный чек ${file.bytes.length} байт, предпросмотр открыт');
  Navigator.of(tester.element(find.byType(PdfPreview).first)).pop();
  await _settle(tester);
  expect(find.byType(PdfPreview), findsNothing);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // До первого обращения к secure storage (`_cleanStart`): данные приложения — в APP_DATA_DIR, не на C:.
  AppDataDirectory.apply(AppConfig.fromEnvironment());

  setUpAll(_stack.start);
  tearDownAll(_stack.stop);

  testWidgets(
    'RM-F-011: продавец — каталог → корзина (2 позиции, скидка в лимите) → SCR-21 (самовывоз, QR) → SCR-22 QR '
    'из 1С → оплачено (фейк 1С) → SCR-24 → товарный чек PDF (предпросмотр без принтера)',
    (tester) async {
      await _staffFirstLogin(tester, _sellerPhone, _sellerPin);

      // Две позиции через «+ Добавить» SCR-11 (CatalogCartPort → CartSync → outbox `cart.sync` → PUT /cart/items).
      final List<_Sku> items = await _sellable(tester, 2);
      for (final _Sku i in items) {
        await _addFromCatalog(tester, i);
      }
      final Cart before = await _openCartWith(tester, items);
      expect(before.items, hasLength(2));
      final String? subtotal = before.subtotal?.toString();

      // Ручная скидка 3 % (лимит seller — 5 %): итоги пересчитывает сервер.
      final Finder discount = find.descendant(
        of: find.byKey(const ValueKey<String>('discount-input-field')),
        matching: find.byType(EditableText),
      );
      await pumpUntilFound(tester, discount);
      await tester.tap(discount.first);
      await tester.pump();
      await tester.enterText(discount.first, '3');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await pumpUntilTrue(
        tester,
        () => _serverCart(tester)?.appliedDiscountPercent?.hundredths == 300,
        what: 'скидка 3 % применена сервером',
      );
      final Cart discounted = _serverCart(tester)!;
      expect(discounted.discountTotal, isNotNull);
      debugPrint('pos_flow_test: корзина — 2 позиции, подытог $subtotal, скидка 3 % = ${discounted.discountTotal}');

      // SCR-21: получатель — сам клиент (по умолчанию), самовывоз, QR → «Создать заказ».
      await _toCheckout(tester);
      await _fillCheckout(tester, 'qr_bakai');
      await _tap(tester, _enabledButton(const ValueKey<String>('checkout-cta')).first);

      // SCR-22: QR из 1С → оплата в фейке → опрос воркера → «Оплачено» → SCR-24.
      final ({String orderId, String? paymentId}) created = await _createdOrder(tester);
      await pumpUntilFound(tester, _qrPanel(), timeout: const Duration(seconds: 60));
      String? paymentId = created.paymentId;
      if (paymentId == null) {
        final Map<String, Object?> st = await tester.runAsync(() => _fake('GET', '/__fake/state')) ?? const {};
        final List<Object?> qr = (st['qr'] as List<Object?>?) ?? const <Object?>[];
        paymentId = qr.isEmpty ? null : (qr.last! as Map<String, Object?>)['externalId'] as String?;
      }
      expect(paymentId, isNotNull, reason: 'платёж QR создан');
      await tester.runAsync(() => _fake('POST', '/__fake/qr/$paymentId/pay', <String, Object?>{}));
      debugPrint('pos_flow_test: заказ создан, QR показан, оплата отмечена в фейке 1С');
      await _previewReceipt(tester, created.orderId);

      // RM-F-005 п. 2: корзина из двух строк → перезапуск приложения → черновик drift на месте → GET /cart.
      final List<_Sku> more = await _sellable(tester, 2, skip: 2);
      for (final _Sku i in more) {
        await _addFromCatalog(tester, i);
      }
      await _openCartWith(tester, more);
      await _restartApp(tester, _sellerPin);
      final Set<String> restored =
          await tester.runAsync(() async {
            final List<QueryRow> rows = await _db(
              tester,
            ).customSelect('SELECT variant_id AS v FROM cart_items_draft WHERE quantity_milli > 0').get();
            return <String>{for (final QueryRow r in rows) r.read<String>('v')};
          }) ??
          const <String>{};
      expect(restored, containsAll(more.map((_Sku i) => i.variantId)), reason: 'черновик корзины пережил перезапуск');
      final Cart again = await _openCartWith(tester, more);
      expect(again.items.map((CartLine l) => l.variantId), containsAll(more.map((_Sku i) => i.variantId)));
      debugPrint('pos_flow_test: перезапуск — черновик корзины восстановлен и сверен с сервером');

      // RM-F-007 п. 2: 1С недоступна → заказ создан в `submitting` (202) → SCR-22 «Ожидает отправки в 1С» → после
      // восстановления 1С воркер отправляет заказ → уведомление `order_status` автору.
      await tester.runAsync(() => _fake('POST', '/__fake/down', <String, Object?>{'down': true}));
      await _toCheckout(tester);
      await _fillCheckout(tester, 'cash');
      await _tap(tester, _enabledButton(const ValueKey<String>('checkout-cta')).first);
      final ({String orderId, String? paymentId}) pending = await _createdOrder(tester);
      await pumpUntilFound(tester, find.byKey(const ValueKey<String>('order-created-onec-pending')));
      await tester.runAsync(() => _fake('POST', '/__fake/down', <String, Object?>{'down': false}));
      final ProviderContainer container = _container(tester);
      await pumpUntil<bool>(
        tester,
        () async {
          await container.read(notificationsCenterProvider.notifier).poll();
          final List<AppNotification> items = container.read(notificationsCenterProvider).items;
          return items.any((AppNotification n) => n.orderId == pending.orderId) ? true : null;
        },
        what: 'уведомление о заказе ${pending.orderId} после восстановления 1С',
        timeout: const Duration(minutes: 5),
      );
      debugPrint('pos_flow_test: 1С недоступна — заказ submitting, после восстановления — уведомление автору');
    },
  );

  testWidgets('RM-F-015: клиент — корзина → SCR-21 режима клиента (наличные) → заявка-заказ → «Мои заказы»', (
    tester,
  ) async {
    await _cleanStart(tester);
    await _phoneAndOtp(tester, _customerPhone);
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
    await _enterPin(tester, _customerPin);
    await _enterPin(tester, _customerPin);
    await _expectCompleteEnabled(tester);
    await _tap(tester, find.byKey(RegistrationSecurityScreen.completeKey));
    await pumpUntilFound(tester, find.byKey(CustomerHomeKeys.root), timeout: const Duration(seconds: 60));
    await _waitCatalogCache(tester);

    final List<_Sku> items = await _sellable(tester, 1, customer: true, skip: 5);
    await _addFromCatalog(tester, items.single);
    await _openCartWith(tester, items);
    // Режим клиента: скидки нет (02 SCR-20, ядро §24.2).
    expect(find.byKey(const ValueKey<String>('discount-input-field')), findsNothing);
    await _toCheckout(tester);
    await _fillCheckout(tester, 'cash');
    await _tap(tester, _enabledButton(const ValueKey<String>('checkout-cta')).first);
    final ({String orderId, String? paymentId}) created = await _createdOrder(tester);
    debugPrint('pos_flow_test: клиент — заявка-заказ создана');

    _router(tester)!.go('/orders');
    await pumpUntilFound(tester, find.byKey(_ordersRoot));
    await pumpUntilFound(
      tester,
      find.byKey(ValueKey<String>('order-row-${created.orderId}')),
      timeout: const Duration(seconds: 60),
    );
  });

  testWidgets('RM-F-016: QR_PROVIDER=none — старший продавец: QR → ручное подтверждение со step-up (PIN) → SCR-24; '
      'офлайн при оформлении → результат неизвестен: SCR-21 закрыт, корзина заблокирована (UI-20-020), черновик с '
      'ключом сохранён', (tester) async {
    await tester.runAsync(() async {
      await _stack.stop();
      await _stack.start(qrProvider: 'none');
    });
    await _staffFirstLogin(tester, _seniorPhone, _seniorPin);

    final List<_Sku> items = await _sellable(tester, 1, skip: 10);
    await _addFromCatalog(tester, items.single);
    await _openCartWith(tester, items);
    await _toCheckout(tester);
    await _fillCheckout(tester, 'qr_bakai');
    await _tap(tester, _enabledButton(const ValueKey<String>('checkout-cta')).first);
    final ({String orderId, String? paymentId}) created = await _createdOrder(tester);

    // QR не из 1С (autoConfirm=false) → «Подтвердить вручную» → реф. банка → StepUpDialog (PIN).
    final Finder confirm = _enabledButton(const ValueKey<String>('order-created-confirm-manual'));
    await pumpUntilFound(tester, confirm, timeout: const Duration(seconds: 60));
    await _tap(tester, confirm.first);
    await pumpUntilFound(tester, find.byKey(const ValueKey<String>('manual-ref')));
    await tester.enterText(_input(const ValueKey<String>('manual-ref')), 'BK-E2E-1');
    await tester.pump();
    await _tap(tester, find.byKey(const ValueKey<String>('manual-submit')));
    await pumpUntilFound(
      tester,
      find.byWidgetPredicate((Widget w) => w.key == StepUpDialog.dialogKey || w.key == StepUpDialog.sheetKey),
    );
    await pumpUntilFound(tester, find.byType(PinField));
    await _settle(tester, frames: 3);
    await _enterPin(tester, _seniorPin);
    debugPrint('pos_flow_test: ручное подтверждение QR со step-up отправлено');
    await _previewReceipt(tester, created.orderId);

    // Офлайн при оформлении: SCR-21 открыт, стек остановлен → «Создать заказ» → результат неизвестен (сеть):
    // окно закрывается, SCR-20 — оверлей UI-20-020, сохранённый запрос повторяется тем же ключом (CART-022 (а)).
    final List<_Sku> next = await _sellable(tester, 1, skip: 11);
    await _addFromCatalog(tester, next.single);
    await _openCartWith(tester, next);
    await _toCheckout(tester);
    await _fillCheckout(tester, 'cash');
    await tester.runAsync(_stack.stop);
    await _tap(tester, _enabledButton(const ValueKey<String>('checkout-cta')).first);
    await pumpUntilFound(tester, find.byKey(CartKeys.lockOverlay), timeout: const Duration(seconds: 60));
    await pumpUntilTrue(tester, () => find.byKey(_checkoutRoot).evaluate().isEmpty, what: 'SCR-21 закрыт');
    expect(find.byKey(_createdRoot), findsNothing);
    expect(_container(tester).read(orderSubmissionRecoveryProvider).locked, isTrue);
    final String key = await pumpUntil<String>(
      tester,
      () async {
        final List<QueryRow> rows = await _db(
          tester,
        ).customSelect('SELECT order_idempotency_key AS k FROM checkout_draft WHERE submitted_at IS NOT NULL').get();
        return rows.isEmpty ? null : rows.single.read<String?>('k');
      },
      what: 'черновик checkout_draft с ключом POST /orders и submitted_at',
      timeout: const Duration(seconds: 30),
    );
    expect(key, isNotNull);
    // Первый фоновый повтор (2 с) завершился сетевой ошибкой; дальше — по графику, приложение закрывается до него.
    await pumpUntilTrue(
      tester,
      () {
        final OrderSubmissionState st = _container(tester).read(orderSubmissionRecoveryProvider);
        return st.failedAttempts >= 1 && !st.inFlight;
      },
      what: 'фоновый повтор POST /orders тем же ключом',
      timeout: const Duration(seconds: 60),
    );
    debugPrint('pos_flow_test: офлайн — SCR-21 закрыт, корзина заблокирована, черновик и ключ заказа сохранены');
    // Корень закрывается: таймеры повторов отменяются вместе с контейнером (FQ-INT-F-13).
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
  });

  testWidgets('RM-F-013 п. 4, CART-022 (а): ответ POST /orders потерян → повтор тем же ключом, один заказ; перезапуск '
      'во время ожидания QR → SCR-24 «Показать QR» → ожидание возобновлено → оплата отражена без повторных POST', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await _stack.stop();
      await _stack.start();
    });
    // Старший продавец: на SCR-22 ему доступно действие «Проверить» (кассир / senior_seller, 13 §3.6).
    await _staffFirstLogin(tester, _seniorPhone, _seniorPin);

    // 6. Неизвестный результат: сервер создал заказ, ответ потерян (receiveTimeout) — RetryInterceptor повторяет тем же
    //    ключом, затем оверлей UI-20-020 и фоновые повторы; когда ответы снова доходят — ответ-повтор → SCR-22.
    final List<_Sku> first = await _sellable(tester, 1, skip: 20);
    await _addFromCatalog(tester, first.single);
    await _openCartWith(tester, first);
    await _toCheckout(tester);
    await _fillCheckout(tester, 'cash');
    final int mark = _net.orderCreates.length;
    _net.dropOrderCreate = true;
    await _tap(tester, _enabledButton(const ValueKey<String>('checkout-cta')).first);
    await pumpUntilFound(tester, find.byKey(CartKeys.lockOverlay), timeout: const Duration(seconds: 90));
    expect(_container(tester).read(orderSubmissionRecoveryProvider).locked, isTrue);
    expect(find.byKey(_createdRoot), findsNothing);
    _net.dropOrderCreate = false;
    final ({String orderId, String? paymentId}) recovered = await _createdOrder(tester);
    final List<String?> keys = _net.orderCreates.sublist(mark);
    expect(keys.length, greaterThanOrEqualTo(2), reason: 'ответ потерян — запрос повторён');
    expect(keys.toSet(), hasLength(1), reason: 'все попытки POST /orders — с одним Idempotency-Key');
    expect(keys.first, isNotNull);
    final Map<String, Object?> byKey = await _api(tester, '/orders', <String, Object?>{'idempotencyKey': keys.first});
    final List<Object?> found = byKey['items']! as List<Object?>;
    expect(found, hasLength(1), reason: 'по ключу на сервере ровно один заказ');
    expect((found.single! as Map<String, Object?>)['id'], recovered.orderId);
    final Map<String, Object?> mine = await _api(tester, '/orders', <String, Object?>{'limit': 50});
    expect(mine['items']! as List<Object?>, hasLength(1), reason: 'дубля нет: у пользователя (новый стек) один заказ');
    debugPrint('pos_flow_test: ответ POST /orders потерян — ${keys.length} попыток с одним ключом, один заказ');

    // 7. QR-заказ → SCR-22 ожидает оплату → перезапуск приложения во время ожидания.
    final List<_Sku> second = await _sellable(tester, 1, skip: 21);
    await _addFromCatalog(tester, second.single);
    await _openCartWith(tester, second);
    await _toCheckout(tester);
    await _fillCheckout(tester, 'qr_bakai');
    await _tap(tester, _enabledButton(const ValueKey<String>('checkout-cta')).first);
    final ({String orderId, String? paymentId}) qr = await _createdOrder(tester);
    await pumpUntilFound(tester, _qrPanel(), timeout: const Duration(seconds: 60));
    String? paymentId = qr.paymentId;
    if (paymentId == null) {
      final Map<String, Object?> st = await tester.runAsync(() => _fake('GET', '/__fake/state')) ?? const {};
      final List<Object?> list = (st['qr'] as List<Object?>?) ?? const <Object?>[];
      paymentId = list.isEmpty ? null : (list.last! as Map<String, Object?>)['externalId'] as String?;
    }
    expect(paymentId, isNotNull, reason: 'платёж QR создан');
    final int since = _net.requests.length;
    await _restartApp(tester, _seniorPin);

    // После старта: SCR-24 → «Показать QR» → SCR-22 только чтение (13 §3.6: «Проверить», без повторного POST).
    _router(tester)!.go('/orders/${qr.orderId}');
    await pumpUntilFound(tester, find.byKey(_orderRoot), timeout: const Duration(seconds: 60));
    final Finder showQr = _enabledButton(const ValueKey<String>('action-show-qr'));
    await pumpUntilFound(tester, showQr, timeout: const Duration(seconds: 60));
    await _tap(tester, showQr.first);
    await pumpUntilFound(tester, find.byKey(_createdRoot), timeout: const Duration(seconds: 60));
    await pumpUntilFound(tester, _qrPanel(), timeout: const Duration(seconds: 60));
    await pumpUntilFound(tester, find.byKey(const ValueKey<String>('order-created-check-payment')));
    await tester.runAsync(() => _fake('POST', '/__fake/qr/$paymentId/pay', <String, Object?>{}));
    // Ожидание статуса возобновлено: «Оплачено» приходит без нажатия «Проверить» → переход на SCR-24.
    await pumpUntilTrue(
      tester,
      () => find.byKey(_createdRoot).evaluate().isEmpty,
      what: 'оплата отражена (received) и SCR-22 сменился на SCR-24',
      timeout: const Duration(minutes: 3),
    );
    final Map<String, Object?> order = await _api(tester, '/orders/${qr.orderId}');
    expect(order['isPaid'], isTrue, reason: 'заказ оплачен');
    expect(order['payments']! as List<Object?>, hasLength(1), reason: 'платёж не создавался повторно');
    final List<String> writes = <String>[
      for (final String r in _net.requests.sublist(since))
        if (r.startsWith('POST ') && (r.contains('/orders') || r.contains('/payments'))) r,
    ];
    expect(writes, isEmpty, reason: 'после перезапуска — только чтение статуса заказа и платежа');
    debugPrint('pos_flow_test: перезапуск во время ожидания QR — ожидание возобновлено, оплата отражена, POST нет');
  });
}
