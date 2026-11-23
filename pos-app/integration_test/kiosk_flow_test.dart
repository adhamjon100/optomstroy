// 13 TAB-2-08 (P-002 §20; ADR-115): сквозной путь «Планшет магазина» на Windows против локального стека
// `pos-api/scripts/local-stack.mjs serve --auth-fixtures --catalog-fixtures=N --cashier-fixtures` с
// `LOCAL_STACK_KIOSK_MODE=true` (pos-api + pos-worker + управляемый фейк HTTP-сервиса 1С в режиме кассира; мир кассира
// загружен синхронизацией pos-worker). **На фикстурах, не реальная интеграция.**
//
// Сценарии (02 ч. F SCR-51…SCR-54, ч. D SCR-24/25/30/38; 04 FLOW-043…FLOW-046; 10 KIOSK-; 12 T-KIOSK-027, T-KIOSK-035):
//   1. покупатель (T-KIOSK-035 (2), предусловие): регистрация с основным телефоном карточки 1С → SCR-06 «Это я» →
//      привязка `confirmed`;
//   2. администратор (T-KIOSK-001, FLOW-043): первый вход → карточка POS с номером без синхронизации 1С
//      (`POST /customers` — для итога `ambiguous`) → SCR-54 «Сделать это устройство планшетом магазина» → форма →
//      StepUpDialog (PIN, `kiosk.manage`) → аварийный код один раз → «Готово» → режим планшета: SCR-51 (`/kiosk`,
//      `GET /me` → `kind=kiosk`);
//   3. планшет (FLOW-044, FLOW-045): три заявки — товар «+ Добавить» → drawer корзины → «Оформить заявку» → SCR-52 номер
//      экранной клавиатурой → «Получить код» → код 246810 → «Отправить заявку» → SCR-53 «Заявка № … отправлена» →
//      «Готово» (сброс: новая пустая корзина); номера: карточки 1С (`single`), карточки POS (`ambiguous`), без карточки
//      (`none`); затем аварийный выход (долгое нажатие 5 с на логотип → код → `POST /kiosk/exit`) → SCR-01;
//   4. кассир (T-KIOSK-027, FLOW-046): первый вход → заявки с планшета в «Ожидают оплаты» SCR-30 с пометкой
//      «С планшета» → SCR-25: чип «С планшета» и поиск по номеру заявки → SCR-24: пометка, подсказка по
//      `kioskCustomerMatch` (single / ambiguous / none) и «Принять оплату» у каждой → SCR-38: наличные (`single`),
//      смена на QR и ручное подтверждение со step-up (`ambiguous`), отмена заявки со step-up
//      `order.cancel.request.any` (`none`);
//   5. покупатель (T-KIOSK-035 (2)): вход на телефоне → «Мои заказы» SCR-25 — заявка с планшета на его карточку.
//
// Данные приложения — в `APP_DATA_DIR` из `env/local.json` (D:, не %APPDATA% на C:). Стеком управляет тест
// (`setUpAll` — `serve … --exit-on-stdin-end` с `LOCAL_STACK_KIOSK_MODE=true`, `tearDownAll` — закрытие stdin:
// штатная остановка API, воркера, фейка, прокси и PostgreSQL). Требуется `npm run build` в pos-api.
//
//   cd pos-api && npm run build
//   cd pos-app && flutter test integration_test/kiosk_flow_test.dart -d windows --dart-define-from-file=env/dev_proxy.json --dart-define-from-file=env/local.json
//
// Уже запущенный стек: `--dart-define=E2E_EXTERNAL_STACK=true` (`LOCAL_STACK_KIOSK_MODE=true node
// scripts/local-stack.mjs serve --auth-fixtures --catalog-fixtures=200 --cashier-fixtures --qr-paid-after-polls 0`,
// свежий стек на каждый прогон). Номера — `AUTH_FIXTURES` стека (support/fixture_phones.dart, синтетические); номера,
// коды, PIN и аварийный код в лог не выводятся (11 SEC-062, SEC-141).
@Timeout(Duration(minutes: 30))
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:optomstroy/app/bootstrap.dart';
import 'package:optomstroy/app/di/overrides.dart' show appCheckoutPrinterProvider, appOrderDocumentPrinterProvider;
import 'package:optomstroy/app/router/kiosk_routes.dart' show KioskPaths;
import 'package:optomstroy/core/config/app_data_directory.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' show OrderStatus;
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/kiosk_keypad.dart';
import 'package:optomstroy/design_system/components/order_status_chip.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/features/admin/presentation/tablets/admin_tablets_screen.dart';
import 'package:optomstroy/features/admin/presentation/tablets/widgets/tablet_edit_dialog.dart';
import 'package:optomstroy/features/admin/presentation/tablets/widgets/tablet_exit_code_dialog.dart';
import 'package:optomstroy/features/auth/presentation/screens/no_session_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/otp_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/phone_screen.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_controller.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_header_button_view.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_panel_view.dart' show CartKeys;
import 'package:optomstroy/features/catalog/presentation/screens/customer_home_view.dart';
import 'package:optomstroy/features/catalog/presentation/screens/kiosk_catalog_view.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/kiosk_catalog_header.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/kiosk_product_sheet.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_checkout_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_code_step.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_phone_step.dart';
import 'package:optomstroy/features/kiosk/presentation/done/kiosk_done_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/emergency_exit_screen.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/presentation/providers/orders_ports.dart';
import 'package:optomstroy/features/orders/presentation/widgets/order_dialogs.dart' show OrderCancelDialog;
import 'package:optomstroy/features/registration/presentation/screens/customer_link_screen.dart';
import 'package:optomstroy/features/registration/presentation/screens/registration_form_screen.dart';
import 'package:optomstroy/features/registration/presentation/screens/registration_security_screen.dart';
import 'package:optomstroy/features/session_ui/presentation/widgets/step_up_dialog.dart';
import 'package:optomstroy/features/splash/presentation/screens/splash_screen.dart';

import 'support/clean_start.dart';
import 'support/fixture_phones.dart';

/// Тестовый код OTP и `kiosk_order` контура (`AUTH_FIXTURES.otpCode`).
const String _otpCode = String.fromEnvironment('E2E_OTP_CODE', defaultValue: '246810');

/// Национальные номера (9 цифр) сотрудников `AUTH_FIXTURES` стека.
const String _adminPhone = '777000901';
const String _cashierPhone = '777000906';

/// PIN (тестовые, только этот стек; как cashier_flow_test.dart).
const String _adminPin = '604817';
const String _cashierPin = '715382';
const String _buyerPin = '7391';

/// Имя планшета (02 SCR-54, UI-54-012) и тестовые ФИО.
const String _tabletName = 'Планшет у входа';
const String _buyerName = 'Тестов Покупатель';
const String _posCardName = 'Тестов Карточка POS';

/// Каталог pos-api (local-stack.mjs); пусто — поиск `pos-api` вверх от рабочего каталога и exe.
const String _apiDirDefine = String.fromEnvironment('E2E_API_DIR');

/// Синтетических SKU стека.
const String _catalogSku = String.fromEnvironment('E2E_CATALOG_SKU', defaultValue: '200');

/// Стек уже запущен (итерации разработки).
const bool _externalStack = bool.fromEnvironment('E2E_EXTERNAL_STACK');

const Key _catalogRoot = ValueKey<String>('stub-SCR-10');
const Key _cashierRoot = ValueKey<String>('stub-SCR-30');
const Key _ordersRoot = ValueKey<String>('stub-SCR-25');
const Key _orderRoot = ValueKey<String>('stub-SCR-24');
const Key _paymentRoot = ValueKey<String>('stub-SCR-38');

/// Номер заявки `POS-YYYY-NNNNNN` (07 §10.4).
final RegExp _publicNumber = RegExp(r'POS-\d{4}-\d{6}');

final _LocalStack _stack = _LocalStack();
final _RecordingPrinter _printer = _RecordingPrinter();

/// Заявка с планшета: номер с SCR-53 и итог сопоставления, который ожидается у кассира.
typedef _KioskOrder = ({String number, String match});

/// Состояние между сценариями одного стека.
final class _World {
  bool buyerConfirmed = false;
  bool enrolled = false;

  /// Заявки с планшета по порядку: `single`, `ambiguous`, `none`.
  final List<_KioskOrder> orders = <_KioskOrder>[];

  /// `orders.id` заявки на карточку покупателя (`single`).
  String? cardOrderId;
}

final _World _w = _World();

List<Override> _overrides() => <Override>[
  appOrderDocumentPrinterProvider.overrideWithValue(_printer),
  appCheckoutPrinterProvider.overrideWithValue(_printer.print),
];

// ---------------------------------------------------------------------------
// Локальный стек: запуск с LOCAL_STACK_KIOSK_MODE=true, ожидание готовности, штатная остановка
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
    if (_externalStack) {
      debugPrint('kiosk_flow_test: внешний стек (E2E_EXTERNAL_STACK)');
      return;
    }
    final Directory api = _apiDir();
    final String sep = Platform.pathSeparator;
    final File ready = File('${_tmp()}${sep}kiosk_flow_ready_${DateTime.now().millisecondsSinceEpoch}.txt');
    final File logFile = File('${_tmp()}${sep}kiosk_flow_stack.log');
    _log = logFile.openWrite();
    final Process p = await Process.start(
      'node',
      <String>[
        'scripts/local-stack.mjs',
        'serve',
        '--auth-fixtures',
        '--catalog-fixtures=$_catalogSku',
        '--cashier-fixtures',
        '--qr-paid-after-polls',
        '0',
        '--ready-file',
        ready.path,
        '--exit-on-stdin-end',
      ],
      workingDirectory: api.path,
      environment: <String, String>{
        // Режим «Планшет магазина» у pos-api и pos-worker (16 §4.3; без флага подключение — 403 KIOSK_DISABLED).
        'LOCAL_STACK_KIOSK_MODE': 'true',
        'LOCAL_STACK_MIN_APP_VERSION': 'android=0.1.0,windows=0.1.0',
        'LOCAL_STACK_LOG_DIR': '${_tmp()}${sep}kiosk_flow_logs',
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
    debugPrint('kiosk_flow_test: стек планшета готов, KIOSK_MODE=true (журнал ${logFile.path})');
  }

  /// Штатная остановка (`--exit-on-stdin-end`): API, воркер, фейк 1С, прокси, управляющий HTTP и PostgreSQL.
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
    debugPrint('kiosk_flow_test: стек остановлен (код $code)');
  }
}

/// Печать в тесте: файл запоминается, системный диалог не открывается (печать чека SCR-38 по умолчанию включена).
final class _RecordingPrinter implements OrderDocumentPrinter {
  final List<OrderDocumentFile> files = <OrderDocumentFile>[];

  @override
  Future<void> preview(BuildContext context, OrderDocumentFile file) async => files.add(file);

  @override
  Future<bool> print(OrderDocumentFile file) async {
    files.add(file);
    return false;
  }
}

// ---------------------------------------------------------------------------
// Общие шаги (как cashier_flow_test.dart)
// ---------------------------------------------------------------------------

Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail(
        'не дождались ${finder.describeMatch(Plurality.one)} за ${timeout.inSeconds} с; экран: ${_where(tester)}; '
        'ключи: ${_visibleKeys()}',
      );
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Строковые ключи виджетов на экране (диагностика падений; без ПДн — только идентификаторы ключей).
String _visibleKeys() {
  final Set<String> keys = <String>{};
  for (final Element e in find.byWidgetPredicate((Widget w) => w.key is ValueKey<String>).evaluate()) {
    final String k = (e.widget.key! as ValueKey<String>).value;
    if (!k.startsWith('product-') && !k.startsWith('kiosk-keypad-')) keys.add(k);
    if (keys.length >= 60) break;
  }
  return keys.join(', ');
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
      fail('не дождались: $what за ${timeout.inSeconds} с; экран: ${_where(tester)}; ключи: ${_visibleKeys()}');
    }
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> pumpUntilTrue(
  WidgetTester tester,
  bool Function() condition, {
  required String what,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('не дождались: $what за ${timeout.inSeconds} с; экран: ${_where(tester)}; ключи: ${_visibleKeys()}');
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
  // Снекбар внизу окна перекрывает кнопки — касание ушло бы в него.
  for (final ScaffoldMessengerState m in tester.stateList<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))) {
    m.clearSnackBars();
  }
  // По центру окна, а не по верхнему краю: `tester.ensureVisible` прижимает цель к верху списка, под закреплённую
  // панель инструментов витрины, и касание уходит в панель (сетка с пределом колонок 03 §7.3 прокручивается).
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

Finder _enabledButton(Key key) =>
    find.byWidgetPredicate((Widget w) => w is AppButton && w.key == key && w.onPressed != null);

/// Виджет с ключом-строкой, начинающейся с [prefix].
Finder _keyPrefix(String prefix) => find.byWidgetPredicate(
  (Widget w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith(prefix),
);

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

/// StepUpDialog (PIN) — подтверждение операции своей сессией.
Future<void> _stepUp(WidgetTester tester, String pin) async {
  final Finder dialog = find.byWidgetPredicate(
    (Widget w) => w.key == StepUpDialog.dialogKey || w.key == StepUpDialog.sheetKey,
  );
  await pumpUntilFound(tester, dialog, timeout: const Duration(seconds: 30));
  await pumpUntilFound(tester, find.descendant(of: dialog, matching: find.byType(PinField)));
  await _settle(tester, frames: 3);
  await _enterPin(tester, pin, scope: dialog);
  await pumpUntilTrue(tester, () => dialog.evaluate().isEmpty, what: 'StepUpDialog закрыт');
}

/// ConfirmDialog: подтверждение — главная кнопка диалога.
Future<void> _confirm(WidgetTester tester) async {
  await pumpUntilFound(tester, find.byType(ConfirmDialog));
  await _settle(tester, frames: 3);
  final Finder primary = find.descendant(
    of: find.byType(ConfirmDialog),
    matching: find.byWidgetPredicate(
      (Widget w) => w is AppButton && w.variant != AppButtonVariant.text && w.onPressed != null,
    ),
  );
  await pumpUntilFound(tester, primary);
  await _tap(tester, primary.last);
  await _settle(tester);
}

/// Сессия, черновик регистрации и признак планшета прежнего прогона (идентификатор устройства остаётся) — общий
/// список чистого старта всех потоков integration_test (`support/clean_start.dart`).
const List<SecureKey> _cleanKeys = kCleanStartKeys;

Future<void> _cleanStart(WidgetTester tester) async {
  _printer.files.clear();
  // Признак планшета тоже: иначе после прерванного прогона холодный старт восстановил бы режим планшета (G-0a).
  await FlutterSecureStorageAdapter().deleteAll(_cleanKeys);
  await bootstrap(overrides: _overrides());
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

/// Первый вход сотрудника (учётная запись без PIN): OTP → SCR-04 (PIN) → главный экран режима [home].
Future<void> _staffFirstLogin(WidgetTester tester, String phone, String pin, {required Key home}) async {
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
  await pumpUntilFound(
    tester,
    _enabledButton(RegistrationSecurityScreen.completeKey),
    timeout: const Duration(seconds: 10),
  );
  await _tap(tester, find.byKey(RegistrationSecurityScreen.completeKey));
  await pumpUntilFound(tester, find.byKey(home), timeout: const Duration(seconds: 60));
}

/// Чтение API тем же клиентом приложения (токен текущей сессии).
Future<Object> _apiRaw(WidgetTester tester, String path, [Map<String, Object?>? query]) async {
  final Dio dio = _container(tester).read(dioProvider);
  final Response<Object?> r = await dio.get<Object?>(path, queryParameters: query);
  return r.data ?? const <String, Object?>{};
}

Future<Map<String, Object?>> _apiMap(WidgetTester tester, String path, [Map<String, Object?>? query]) async {
  final Object data = await _apiRaw(tester, path, query);
  return data is Map<String, Object?> ? data : const <String, Object?>{};
}

Future<Map<String, Object?>> _api(WidgetTester tester, String path, [Map<String, Object?>? query]) async {
  final Map<String, Object?>? data = await tester.runAsync(() => _apiMap(tester, path, query));
  if (data == null || data.isEmpty) fail('GET $path: ответ не объект');
  return data;
}

Cart? _serverCart(WidgetTester tester) => _container(tester).read(cartControllerProvider).server;

// ---------------------------------------------------------------------------
// Шаги планшета (SCR-51…SCR-53)
// ---------------------------------------------------------------------------

/// Цифры экранной клавиатурой `KioskKeypad` (номер, код из SMS, аварийный код).
Future<void> _keypad(WidgetTester tester, String digits) async {
  for (final String d in digits.split('')) {
    final Finder key = find.byKey(KioskKeypad.keyFor(d));
    await pumpUntilFound(tester, key);
    await tester.ensureVisible(key.last);
    await tester.pump();
    await tester.tap(key.last);
    await tester.pump(const Duration(milliseconds: 60));
  }
  await _settle(tester, frames: 3);
}

/// SCR-51: «+ Добавить» на первой доступной карточке витрины → строка подтверждена сервером.
Future<void> _addFirstProduct(WidgetTester tester) async {
  await pumpUntilFound(tester, find.byKey(KioskCatalogKeys.root), timeout: const Duration(seconds: 60));
  final Finder add = find.descendant(
    of: _keyPrefix('product-'),
    matching: find.byWidgetPredicate((Widget w) => w is AppButton && w.onPressed != null),
  );
  await pumpUntilFound(tester, add, timeout: const Duration(seconds: 60));
  await _settle(tester, frames: 3);
  final int before = _serverCart(tester)?.items.length ?? 0;
  final int candidates = add.evaluate().length;
  for (int i = 0; i < candidates; i++) {
    await _tap(tester, add.at(i));
    await _settle(tester, frames: 5);
    // Товар с характеристиками открывает слой карточки (UI-51-011) — закрываем и берём следующий.
    if (find.byKey(KioskProductSheet.closeKey).evaluate().isNotEmpty) {
      await _tap(tester, find.byKey(KioskProductSheet.closeKey));
      await _settle(tester, frames: 5);
      continue;
    }
    final bool added = await _waitCart(tester, (Cart c) => c.items.length > before, soft: true);
    if (added) return;
  }
  fail('на витрине нет товара, который добавляется в корзину; ключи: ${_visibleKeys()}');
}

/// Серверная корзина удовлетворяет [ok] и неподтверждённых изменений нет; [soft] — без падения по таймауту.
Future<bool> _waitCart(WidgetTester tester, bool Function(Cart c) ok, {bool soft = false}) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 30));
  while (true) {
    final Cart? c = _serverCart(tester);
    if (c != null && ok(c) && !_container(tester).read(cartControllerProvider).hasUnconfirmed) return true;
    if (DateTime.now().isAfter(deadline)) {
      if (soft) return false;
      fail('корзина планшета не подтверждена сервером; экран: ${_where(tester)}; ключи: ${_visibleKeys()}');
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// Заявка с планшета на номер [nationalPhone]: drawer → SCR-52 «Телефон» → «Код» → SCR-53 → «Готово» (сброс).
Future<String> _kioskOrder(WidgetTester tester, String nationalPhone) async {
  await _addFirstProduct(tester);
  // Drawer корзины 420 (UI-51-012): без клиента, склада, скидки и «Отложить»; «Оформить заявку».
  await _tap(tester, find.byKey(CartHeaderButtonView.buttonKey));
  final Finder checkout = _enabledButton(CartKeys.createOrder);
  await pumpUntilFound(tester, checkout, timeout: const Duration(seconds: 30));
  expect(find.byKey(CartKeys.park), findsNothing, reason: '«Отложить» у планшета нет');
  expect(find.byKey(CartKeys.customer), findsNothing, reason: 'выбора клиента у планшета нет');
  await _tap(tester, checkout);

  // SCR-52 шаг «Телефон»: предпросмотр корзины, номер — только экранной клавиатурой.
  await pumpUntilFound(tester, find.byKey(KioskCheckoutScreen.screenKey), timeout: const Duration(seconds: 30));
  await pumpUntilFound(tester, find.byKey(KioskPhoneStep.fieldKey));
  await pumpUntilFound(tester, find.byKey(KioskCheckoutScreen.summaryKey), timeout: const Duration(seconds: 30));
  expect(_where(tester), contains('step=phone'));
  await _keypad(tester, nationalPhone);
  expect(_where(tester), isNot(contains(nationalPhone)), reason: 'номер не попадает в адрес (AC-UI-52-015)');
  final Finder getCode = _enabledButton(KioskPhoneStep.getCodeKey);
  await pumpUntilFound(tester, getCode, timeout: const Duration(seconds: 30));
  await _tap(tester, getCode);

  // Шаг «Код» (`POST /kiosk/order-otp` → 202): маска номера, код из SMS тестового режима.
  await pumpUntilFound(tester, find.byKey(KioskCodeStep.fieldKey), timeout: const Duration(seconds: 30));
  expect(_where(tester), contains('step=code'));
  await _keypad(tester, _otpCode);
  final Finder send = _enabledButton(KioskCodeStep.sendKey);
  await pumpUntilFound(tester, send, timeout: const Duration(seconds: 10));
  await _tap(tester, send);

  // SCR-53: «Заявка № … отправлена» — номер только на экране (не в адресе).
  await pumpUntilFound(tester, find.byKey(KioskDoneScreen.screenKey), timeout: const Duration(seconds: 90));
  final String title = tester.widget<Text>(find.byKey(KioskDoneScreen.numberKey)).data ?? '';
  final String? number = _publicNumber.firstMatch(title)?.group(0);
  expect(number, isNotNull, reason: 'номер заявки на SCR-53');
  expect(_where(tester), KioskPaths.done);
  // SCR-52 заменён (`go('/kiosk/done')`), его страница уходит с анимацией.
  await pumpUntilTrue(
    tester,
    () => find.byKey(KioskCheckoutScreen.screenKey).evaluate().isEmpty,
    what: 'SCR-52 снят',
    timeout: const Duration(seconds: 10),
  );
  expect(
    find.descendant(of: find.byKey(KioskDoneScreen.screenKey), matching: find.textContaining('сом')),
    findsNothing,
    reason: 'сумм на SCR-53 нет',
  );

  // «Готово» — сброс FLOW-045 (`POST /kiosk/reset`): SCR-51 с новой пустой корзиной.
  final String? cartBefore = _serverCart(tester)?.id;
  await _tap(tester, find.byKey(KioskDoneScreen.doneKey));
  await pumpUntilFound(tester, find.byKey(KioskCatalogKeys.root), timeout: const Duration(seconds: 60));
  await _waitCart(tester, (Cart c) => c.items.isEmpty && c.id != cartBefore);
  return number!;
}

/// SCR-25: заявка [number] найдена поиском по номеру; строка с пометкой «С планшета».
Future<void> _findByNumber(WidgetTester tester, String number, String orderId) async {
  final Finder search = _input(const ValueKey<String>('orders-search'));
  await pumpUntilFound(tester, search);
  await tester.enterText(search, number);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pump();
  await pumpUntilFound(
    tester,
    find.byKey(ValueKey<String>('order-row-kiosk-$orderId')),
    timeout: const Duration(seconds: 30),
  );
  await pumpUntilTrue(
    tester,
    () => _keyPrefix('order-row-kiosk-').evaluate().length == 1,
    what: 'по номеру $number — одна заявка',
    timeout: const Duration(seconds: 30),
  );
}

/// SCR-24 заявки: пометка «С планшета», подсказка кассиру по `kioskCustomerMatch`, «Принять оплату» доступна.
Future<void> _openKioskOrder(WidgetTester tester, String orderId, String match) async {
  _router(tester)!.go('/orders/$orderId');
  await pumpUntilFound(tester, find.byKey(_orderRoot), timeout: const Duration(seconds: 60));
  await pumpUntilFound(tester, find.byKey(const ValueKey<String>('order-badge-kiosk')));
  await pumpUntilFound(tester, find.byKey(ValueKey<String>('order-kiosk-match-$match')));
  await pumpUntilFound(
    tester,
    _enabledButton(const ValueKey<String>('action-pay')),
    timeout: const Duration(seconds: 30),
  );
}

/// SCR-38 «Наличные» — быстрая сумма → «Принять» → подтверждение → оплачено.
Future<void> _payCash(WidgetTester tester, String orderId) async {
  _router(tester)!.go('/payments/new?orderId=$orderId&method=cash');
  await pumpUntilFound(tester, find.byKey(_paymentRoot), timeout: const Duration(seconds: 60));
  final Finder quick = _keyPrefix('payment-quick-');
  await pumpUntilFound(tester, quick, timeout: const Duration(seconds: 60));
  await _tap(tester, quick.first);
  await _settle(tester, frames: 3);
  await pumpUntilFound(tester, _enabledButton(const ValueKey<String>('payment-cta')));
  await _tap(tester, _enabledButton(const ValueKey<String>('payment-cta')));
  await _confirm(tester);
  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey<String>('payment-success')),
    timeout: const Duration(seconds: 60),
  );
}

/// SCR-38: смена способа на QR → «Подтвердить вручную» (референс выписки) → step-up PIN кассира → оплачено.
Future<void> _payQrManual(WidgetTester tester, String orderId) async {
  // Сразу с SCR-38 прежнего платежа: экран маршрута с другим `orderId` — новый (ключ по параметрам, `PaymentNewRoute`).
  _router(tester)!.go('/payments/new?orderId=$orderId&method=qr_bakai');
  await pumpUntilFound(tester, find.byKey(_paymentRoot), timeout: const Duration(seconds: 60));
  final Finder confirmManual = _enabledButton(const ValueKey<String>('payment-confirm-manual'));
  await pumpUntilFound(tester, confirmManual, timeout: const Duration(seconds: 90));
  await _tap(tester, confirmManual);
  final Finder manualRef = _input(const ValueKey<String>('payment-manual-ref'));
  await pumpUntilFound(tester, manualRef, timeout: const Duration(seconds: 30));
  await _settle(tester, frames: 3);
  await tester.enterText(manualRef, 'BK-77124');
  await tester.pump();
  final Finder manualSubmit = _enabledButton(const ValueKey<String>('payment-manual-submit'));
  await pumpUntilFound(tester, manualSubmit);
  await _tap(tester, manualSubmit);
  await _stepUp(tester, _cashierPin);
  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey<String>('payment-success')),
    timeout: const Duration(seconds: 60),
  );
}

/// SCR-24 «Отмена заявки» кассиром: причина → подтверждение → step-up `order.cancel.request.any` → «Отменён».
Future<void> _cancelKioskOrder(WidgetTester tester, String orderId) async {
  _router(tester)!.go('/orders/$orderId');
  await pumpUntilFound(tester, find.byKey(_orderRoot), timeout: const Duration(seconds: 60));
  final Finder cancelAction = _enabledButton(const ValueKey<String>('action-cancel'));
  await pumpUntilFound(tester, cancelAction, timeout: const Duration(seconds: 30));
  await _tap(tester, cancelAction);
  final Finder dialog = find.byType(OrderCancelDialog);
  await pumpUntilFound(tester, dialog, timeout: const Duration(seconds: 10));
  await _settle(tester, frames: 4);
  await _tap(tester, find.byKey(const ValueKey<String>('cancel-reason-customer_refused')));
  await tester.enterText(_input(const ValueKey<String>('cancel-reason-text')), 'Покупатель отказался от заявки');
  await tester.pump();
  expect(find.byKey(const ValueKey<String>('cancel-refund')), findsNothing, reason: 'денег не получено');
  final Finder confirm = _enabledButton(const ValueKey<String>('cancel-confirm'));
  await pumpUntilFound(tester, confirm);
  await _tap(tester, confirm);
  // Заявка не своя: `order.cancel.request.any` со step-up (03 §9.39; 10 KIOSK-019).
  await _stepUp(tester, _cashierPin);
  await pumpUntilTrue(tester, () => dialog.evaluate().isEmpty, what: 'диалог отмены закрыт');
  await pumpUntil<bool>(
    tester,
    () async => (await _apiMap(tester, '/orders/$orderId'))['status'] == 'cancelled' ? true : null,
    what: 'заявка $orderId отменена (GET /orders/{id})',
    timeout: const Duration(seconds: 120),
  );
  final Finder cancelledChip = find.byWidgetPredicate(
    (Widget w) =>
        w is OrderStatusChip && w.key == const ValueKey<String>('order-status') && w.status == OrderStatus.cancelled,
  );
  await pumpUntil<bool>(tester, () async {
    if (cancelledChip.evaluate().isNotEmpty) return true;
    _router(tester)!.go('/orders/$orderId?r=${DateTime.now().millisecondsSinceEpoch}');
    return null;
  }, what: 'SCR-24: статус «Отменён»');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // До первого обращения к secure storage: данные приложения — в APP_DATA_DIR, не на C:.
  AppDataDirectory.apply(AppConfig.fromEnvironment());

  setUpAll(_stack.start);
  tearDownAll(() async {
    // Прочие потоки integration_test признак планшета не удаляют: устройство не должно остаться планшетом.
    await FlutterSecureStorageAdapter().deleteAll(_cleanKeys);
    await _stack.stop();
  });

  testWidgets('T-KIOSK-035 (2) предусловие: покупатель регистрируется с основным телефоном карточки 1С → SCR-06 '
      '«Это я» → привязка confirmed', (tester) async {
    await _cleanStart(tester);
    await _phoneAndOtp(tester, kKioskCardPhoneDigits);
    await pumpUntilFound(tester, find.byKey(RegistrationFormScreen.screenKey), timeout: const Duration(seconds: 60));
    await _settle(tester);
    await tester.enterText(_input(RegistrationFormScreen.nameFieldKey), _buyerName);
    await tester.pump();
    await tester.enterText(_input(RegistrationFormScreen.yearFieldKey), '1988');
    await tester.pump();
    await _tap(tester, find.byKey(RegistrationFormScreen.pdAckKey));
    await _tap(tester, find.byKey(RegistrationFormScreen.continueKey));
    await pumpUntilFound(tester, find.byKey(RegistrationSecurityScreen.screenKey));
    await pumpUntilFound(tester, find.byType(PinField));
    await _settle(tester);
    await _enterPin(tester, _buyerPin);
    await _enterPin(tester, _buyerPin);
    await pumpUntilFound(tester, _enabledButton(RegistrationSecurityScreen.completeKey));
    await _tap(tester, find.byKey(RegistrationSecurityScreen.completeKey));
    final Finder confirm = _enabledButton(CustomerLinkScreen.confirmKey);
    await pumpUntilFound(tester, confirm, timeout: const Duration(seconds: 60));
    await _settle(tester);
    await _tap(tester, confirm);
    await pumpUntil<bool>(
      tester,
      () async => ((await _apiMap(tester, '/me'))['customerLink'] as Map<String, Object?>?)?['status'] == 'confirmed'
          ? true
          : null,
      what: 'привязка подтверждена (confirmed)',
    );
    _w.buyerConfirmed = true;
    debugPrint('kiosk_flow_test: покупатель — привязка к карточке 1С подтверждена');
  });

  testWidgets('T-KIOSK-001 / FLOW-043…045: администратор делает устройство планшетом (SCR-54, step-up, аварийный код) '
      '→ SCR-51; три заявки с планшета (номер карточки 1С, карточки POS, без карточки) → SCR-53 → «Готово» (сброс); '
      'аварийный выход → SCR-01', (tester) async {
    expect(_w.buyerConfirmed, isTrue, reason: 'покупатель с подтверждённой привязкой — сценарий 1');
    await _staffFirstLogin(tester, _adminPhone, _adminPin, home: _catalogRoot);
    debugPrint('kiosk_flow_test: администратор вошёл — ${_where(tester)}');

    // Карточка POS с номером без синхронизации 1С (итог `ambiguous` у заявки на этот номер; SEC-130, Р-23 (а)).
    final int created =
        await tester.runAsync<int>(() async {
          final Dio dio = _container(tester).read(dioProvider);
          final Response<Object?> r = await dio.post<Object?>(
            '/customers',
            data: <String, Object?>{
              'name': _posCardName,
              'customerType': 'individual',
              'phones': <String>['+996$kKioskPosCardPhoneDigits'],
            },
            options: Options(
              headers: <String, Object?>{'Idempotency-Key': 'a11a11a1-0000-4000-8000-${_stamp()}'},
              validateStatus: (int? s) => s != null && s < 500,
            ),
          );
          return r.statusCode ?? 0;
        }) ??
        0;
    expect(created, anyOf(200, 201), reason: 'POST /customers — карточка POS создана');

    // SCR-54: «Сделать это устройство планшетом магазина» → форма → step-up → код один раз → «Готово».
    _router(tester)!.go('/admin/tablets');
    await pumpUntilFound(tester, find.byKey(AdminTabletsScreen.screenKey), timeout: const Duration(seconds: 30));
    final Finder enroll = find.byKey(AdminTabletsScreen.enrollKey);
    await pumpUntilFound(tester, enroll, timeout: const Duration(seconds: 30));
    await _tap(tester, enroll.first);
    final Finder name = find.descendant(of: find.byKey(TabletFormDialog.nameKey), matching: find.byType(EditableText));
    await pumpUntilFound(tester, name, timeout: const Duration(seconds: 30));
    await _settle(tester, frames: 3);
    await tester.enterText(name, _tabletName);
    await tester.pump();
    final Finder submit = _enabledButton(TabletFormDialog.submitKey);
    await pumpUntilFound(tester, submit, timeout: const Duration(seconds: 30));
    await _tap(tester, submit);
    await _stepUp(tester, _adminPin);
    final Finder code = find.byKey(TabletExitCodeDialog.codeKey);
    await pumpUntilFound(tester, code, timeout: const Duration(seconds: 60));
    final String exitCode = (tester.widget<Text>(code).data ?? '').replaceAll(RegExp(r'\D'), '');
    expect(exitCode, matches(RegExp(r'^\d{8}$')), reason: 'аварийный код — 8 цифр (UI-54-014)');
    await _tap(tester, _enabledButton(TabletExitCodeDialog.doneKey));

    // Режим планшета: SCR-51 `/kiosk`, сессия `kind=kiosk` (сессия администратора на устройстве завершена).
    await pumpUntilFound(tester, find.byKey(KioskCatalogKeys.root), timeout: const Duration(seconds: 90));
    expect(_where(tester), startsWith(KioskPaths.showcase));
    final Map<String, Object?> me = await _api(tester, '/me');
    expect(me['kind'], 'kiosk', reason: 'GET /me токеном планшета');
    expect(me['phone'], isNull, reason: 'технический пользователь без телефона');
    _w.enrolled = true;
    debugPrint('kiosk_flow_test: устройство подключено как планшет — SCR-51');

    // G-15: пути вне режима возвращают на /kiosk.
    _router(tester)!.go('/orders');
    await pumpUntilTrue(tester, () => _where(tester).startsWith(KioskPaths.showcase), what: 'G-15 → /kiosk');

    // Три заявки (FLOW-044): номер карточки 1С, карточки POS, без карточки.
    for (final (String phone, String match) in <(String, String)>[
      (kKioskCardPhoneDigits, 'single'),
      (kKioskPosCardPhoneDigits, 'ambiguous'),
      (kKioskNoCardPhoneDigits, 'none'),
    ]) {
      final String number = await _kioskOrder(tester, phone);
      _w.orders.add((number: number, match: match));
      debugPrint('kiosk_flow_test: заявка с планшета отправлена ($match) — $number');
    }

    // Аварийный выход UI-51-017: долгое нажатие 5 с на логотип → код → `POST /kiosk/exit` → SCR-01.
    final Finder logo = find.byKey(KioskCatalogHeader.logoKey);
    await pumpUntilFound(tester, logo);
    final TestGesture hold = await tester.startGesture(tester.getCenter(logo));
    final DateTime until = DateTime.now().add(
      KioskEmergencyExitTrigger.holdDuration + const Duration(milliseconds: 700),
    );
    while (DateTime.now().isBefore(until)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await hold.up();
    await pumpUntilFound(tester, find.byKey(KioskEmergencyExitDialog.dialogKey), timeout: const Duration(seconds: 10));
    await _settle(tester, frames: 3);
    await _keypad(tester, exitCode);
    await _tap(tester, _enabledButton(KioskEmergencyExitDialog.submitKey));
    await pumpUntilFound(
      tester,
      find.byWidgetPredicate((Widget w) => w.key == PhoneScreen.fieldKey || w.key == NoSessionScreen.screenKey),
      timeout: const Duration(seconds: 60),
    );
    debugPrint('kiosk_flow_test: аварийный выход — SCR-01');
  });

  testWidgets(
    'T-KIOSK-027 кассир принимает заявки с планшета: «Ожидают оплаты» SCR-30, чип «С планшета» и поиск по '
    'номеру SCR-25, подсказка kioskCustomerMatch и «Принять оплату» SCR-24; наличные, смена на QR, отмена со step-up',
    (tester) async {
      expect(_w.orders, hasLength(3), reason: 'заявки с планшета — сценарий 2');
      await _staffFirstLogin(tester, _cashierPhone, _cashierPin, home: _cashierRoot);

      // Заявки с планшета: `createdVia=kiosk`, итог сопоставления — как ожидалось по номеру (10 KIOSK-014).
      final Map<String, Object?> page = await _api(tester, '/orders', <String, Object?>{
        'createdVia': 'kiosk',
        'limit': 50,
      });
      final List<Map<String, Object?>> items = (page['items'] as List<Object?>? ?? const <Object?>[])
          .whereType<Map<String, Object?>>()
          .toList();
      final Map<String, String> ids = <String, String>{};
      for (final _KioskOrder o in _w.orders) {
        final Map<String, Object?> row = items.firstWhere(
          (Map<String, Object?> i) => i['publicNumber'] == o.number,
          orElse: () => fail('заявка ${o.number} в GET /orders?createdVia=kiosk'),
        );
        expect(row['createdVia'], 'kiosk');
        expect(row['kioskCustomerMatch'], o.match, reason: 'kioskCustomerMatch заявки ${o.number}');
        ids[o.match] = row['id']! as String;
      }
      _w.cardOrderId = ids['single'];

      // SCR-30 «Ожидают оплаты»: заявки с пометкой «С планшета» (UI-30-020).
      for (final String id in ids.values) {
        await pumpUntilFound(
          tester,
          find.byKey(ValueKey<String>('awaiting-kiosk-$id')),
          timeout: const Duration(seconds: 60),
        );
      }
      debugPrint('kiosk_flow_test: SCR-30 — заявки с планшета в «Ожидают оплаты»');

      // SCR-25: чип «С планшета» (`createdVia=kiosk`) — все три; поиск по номеру — одна.
      _router(tester)!.go('/orders');
      await pumpUntilFound(tester, find.byKey(_ordersRoot), timeout: const Duration(seconds: 30));
      final Finder chip = find.byKey(const ValueKey<String>('orders-chip-kiosk'));
      await pumpUntilFound(tester, chip);
      await _tap(tester, chip);
      await pumpUntilTrue(tester, () => _where(tester).contains('createdVia=kiosk'), what: 'адрес с createdVia=kiosk');
      for (final String id in ids.values) {
        await pumpUntilFound(
          tester,
          find.byKey(ValueKey<String>('order-row-kiosk-$id')),
          timeout: const Duration(seconds: 30),
        );
      }
      await _findByNumber(tester, _w.orders.first.number, ids['single']!);
      debugPrint('kiosk_flow_test: SCR-25 — чип «С планшета» и поиск по номеру');

      // SCR-24: пометка и подсказка по каждому итогу; «Принять оплату» доступна всегда (AC-UI-24-019).
      for (final MapEntry<String, String> e in ids.entries) {
        await _openKioskOrder(tester, e.value, e.key);
      }

      // `single` — наличные; `ambiguous` — смена на QR и ручное подтверждение; `none` — отмена заявки со step-up.
      await _payCash(tester, ids['single']!);
      expect((await _api(tester, '/orders/${ids['single']}'))['isPaid'], isTrue, reason: 'наличные приняты');
      debugPrint('kiosk_flow_test: SCR-38 — наличные по заявке на карточку');
      await _payQrManual(tester, ids['ambiguous']!);
      final Map<String, Object?> qr = await _api(tester, '/orders/${ids['ambiguous']}');
      expect(qr['isPaid'], isTrue, reason: 'оплачено QR (ручное подтверждение)');
      expect(
        (qr['payments'] as List<Object?>? ?? const <Object?>[]).whereType<Map<String, Object?>>().any(
          (Map<String, Object?> p) => p['method'] == 'qr_bakai' && p['status'] == 'received',
        ),
        isTrue,
        reason: 'платёж QR received',
      );
      debugPrint('kiosk_flow_test: SCR-38 — смена на QR и ручное подтверждение');
      await _cancelKioskOrder(tester, ids['none']!);
      debugPrint('kiosk_flow_test: SCR-24 — заявка без карточки отменена (step-up)');
    },
  );

  testWidgets('T-KIOSK-035 (2) заявка с планшета на подтверждённую карточку видна в «Мои заказы» покупателя', (
    tester,
  ) async {
    final String? orderId = _w.cardOrderId;
    expect(orderId, isNotNull, reason: 'заявка на карточку покупателя — сценарии 2 и 3');
    await _cleanStart(tester);
    await _phoneAndOtp(tester, kKioskCardPhoneDigits);
    // Повторный вход покупателя: SCR-04 (PIN) — если сервер его требует; иначе сразу SCR-50.
    final Finder home = find.byKey(CustomerHomeKeys.root);
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 90));
    while (home.evaluate().isEmpty) {
      if (DateTime.now().isAfter(deadline)) fail('покупатель не вошёл; экран: ${_where(tester)}; ${_visibleKeys()}');
      if (find.byType(PinField).evaluate().isNotEmpty) {
        await _settle(tester, frames: 3);
        await _enterPin(tester, _buyerPin);
        if (find.byType(PinField).evaluate().isNotEmpty &&
            find.byKey(RegistrationSecurityScreen.screenKey).evaluate().isNotEmpty) {
          await _enterPin(tester, _buyerPin);
        }
        final Finder complete = _enabledButton(RegistrationSecurityScreen.completeKey);
        if (complete.evaluate().isNotEmpty) await _tap(tester, complete);
      }
      final Finder cont = _enabledButton(CustomerLinkScreen.continueKey);
      if (cont.evaluate().isNotEmpty) await _tap(tester, cont);
      await tester.pump(const Duration(milliseconds: 200));
    }
    _router(tester)!.go('/orders');
    await pumpUntilFound(tester, find.byKey(_ordersRoot), timeout: const Duration(seconds: 30));
    await pumpUntilFound(
      tester,
      find.byKey(ValueKey<String>('order-row-$orderId')),
      timeout: const Duration(seconds: 60),
    );
    expect(find.byKey(const ValueKey<String>('orders-chip-kiosk')), findsNothing, reason: 'чип — только сотрудникам');
    expect(
      find.byKey(ValueKey<String>('order-row-kiosk-$orderId')),
      findsNothing,
      reason: 'пометка — только сотрудникам',
    );
    debugPrint('kiosk_flow_test: покупатель видит заявку с планшета в «Мои заказы»');
  });
}

/// Хвост UUID ключа идемпотентности (12 цифр, уникален на прогон).
String _stamp() => (DateTime.now().millisecondsSinceEpoch % 1000000000000).toString().padLeft(12, '0');
