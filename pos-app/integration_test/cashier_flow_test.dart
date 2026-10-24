// RM-G-009 (Flutter-часть), RM-G-010: сквозной путь этапа G на Windows против локального стека
// `pos-api/scripts/local-stack.mjs serve --auth-fixtures --catalog-fixtures=N --pos-fixtures --cashier-fixtures`
// (pos-api + pos-worker + управляемый фейк HTTP-сервиса расширения 1С в режиме кассира `SyntheticCashier`: клиенты с
// долгами/просрочкой/лимитом, реализации, правила скидок; мир кассира загружен синхронизацией pos-worker).
// **На фикстурах, не реальная интеграция.**
//
// Сценарии (02 ч. D SCR-30…SCR-39, ч. E SCR-41…SCR-48; 10 CUST-, DEBT-, CASH-, TXN-, RET-; 12 T-CUST, T-DEBT, T-CASH,
// T-TXN, T-RET, T-ADMIN, T-SEC-016/017/042):
//   1. кассир: SCR-30 → SCR-31 (поиск по 4 цифрам телефона) → SCR-32 клиента с просрочкой (сводка долга) → «В заказ»
//      (POST /cart/customer) → товар из каталога → SCR-21: «В долг» → отказ fail-closed `CREDIT_BLOCKED overdue`
//      (причина и «Как получить разрешение старшего», без step-up у кассира) → наличные → заказ → SCR-38 приём
//      наличных → оплачено → SCR-36 транзакция по клиенту; новый клиент из оформления (SCR-21 «+ Новый клиент» →
//      SCR-26 → клиент выбран в заказе); возврат: заказ «отгружен» (управляющий вызов стенда) → SCR-24 «Заявка на
//      возврат» → SCR-39 (позиция, причина) → сохранить → отправить (step-up PIN) → `submitted`;
//   2. старший продавец: корзина → SCR-21 CustomerPicker (реальный поиск `GET /customers`) → клиент с просрочкой →
//      «В долг» → «Разрешить продажу в долг» (причина + step-up PIN, `credit.sale.approve`) → заказ в долг; решение по
//      заявке кассира: SCR-39 «Согласовать» (step-up PIN) → `accepted`;
//   3. администратор: SCR-47 — запись аудита `credit.sale_approved` по заказу в долг видна;
//   4. руководитель (owner): главный экран — SCR-48 «Отчёты» с данными за сегодня;
//   5. клиент-покупатель (регистрация, карточка «долг в лимите»): привязка `proposed` — свой долг SCR-34 закрыт (без
//      запросов), SCR-06 «Это я» → `confirmed` — свой долг виден.
// Ревью G-trace-8/9 (исправитель Flutter): у кассира — SCR-34 клиента, избранные клиенты (FLOW-042: звезда на SCR-32 →
// `PUT /favorites/customers/{id}` → блок Z3 SCR-30), офлайн SCR-31/SCR-34 без финансов из кэша (T-CUST-013,
// T-DEBT-013: сигнал сети ОС «нет сети» подменяется тестом), продажа в долг в пределах лимита (FLOW-023: клиент «долг
// в лимите» → «В долг» → заказ `credit`) и проверка «финансов клиента нет ни в drift, ни в secure storage» (T-DEBT-013,
// CASH-015: файлы APP_DATA_DIR и значения SecureKey без ключей снимка долга и полного телефона клиента).
// Ревью G-trace-8, раунд 2 (сценарии кассира 01 GEN-005, 04 FLOW-020…031): FLOW-025 — 1С недоступна (фейк
// `POST /__fake/down`), неполный снимок: SCR-34 «Обновить» → «1С недоступна…», SCR-21 «В долг» — `RECEIVABLES_STALE`
// без эскалации, заказ за наличные; FLOW-029 — SCR-21 «+ Новый клиент» с телефоном карточки 1С → «Использовать
// существующего»; FLOW-029.A2 — SCR-31 → «Всё равно создать» с причиной; FLOW-022 — SCR-38: QR → «Подтвердить
// вручную» (референс выписки) → step-up → `received`/`manual`, одна транзакция `manual_qr_confirm`; FLOW-031.A4 —
// старший «Отклонить» вторую заявку кассира (причина + step-up) → `rejected`.
// G-trace-8 / R2-N-01 (RM-G-010 п. 1): FLOW-026 «Отмена заказа» — SCR-24 «Отменить заказ» у отгруженного заказа нет
// (AC-FLOW-026-06); свой заказ без полученных денег → диалог отмены (причина) → `POST /orders/{id}/cancel` без step-up →
// «Запрос отмены отправлен в 1С» (или немедленно «Заказ отменён», если документа 1С ещё нет) → «Отменён»; ветка S4 —
// оплаченный заказ: «Запросить отмену» → причина + «Деньги: вернуть» → step-up PIN → `cancelRequested` → ответ 1С
// (фейк: «Закрыт») → «Отменён», платёж `received` не меняется; администратор видит аудит `order.cancel_requested`.
//
// Данные приложения — в `APP_DATA_DIR` из `env/local.json` (D:, не %APPDATA% на C:; lib/core/config/app_data_directory.dart).
// Стеком управляет тест (`setUpAll` — `serve … --exit-on-stdin-end`, `tearDownAll` — закрытие stdin: штатная остановка
// API, воркера, фейка, прокси и PostgreSQL). Требуется `npm run build` в pos-api.
//
//   cd pos-api && npm run build
//   cd pos-app && flutter test integration_test/cashier_flow_test.dart -d windows --dart-define-from-file=env/dev_proxy.json --dart-define-from-file=env/local.json
//
// Уже запущенный стек (итерации разработки): `--dart-define=E2E_EXTERNAL_STACK=true` — тест не запускает и не
// останавливает стек (`serve --cashier-fixtures` с тем же набором данных; свежий стек на каждый прогон).
//
// Номера и код — `AUTH_FIXTURES` стека (+99677700090N, синтетические); телефоны, код и PIN в лог не выводятся
// (11 SEC-062).
@Timeout(Duration(minutes: 30))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
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
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' show OrderStatus;
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_checkbox.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/order_status_chip.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/features/auth/presentation/screens/no_session_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/otp_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/phone_screen.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_controller.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_panel_view.dart' show CartKeys;
import 'package:optomstroy/features/catalog/presentation/screens/customer_home_view.dart';
import 'package:optomstroy/features/checkout/presentation/controllers/checkout_controller.dart';
import 'package:optomstroy/features/customers/presentation/state/customers_search_controller.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/presentation/providers/orders_ports.dart';
import 'package:optomstroy/features/orders/presentation/widgets/order_dialogs.dart' show OrderCancelDialog;
import 'package:optomstroy/features/registration/presentation/screens/customer_link_screen.dart';
import 'package:optomstroy/features/registration/presentation/screens/registration_form_screen.dart';
import 'package:optomstroy/features/registration/presentation/screens/registration_security_screen.dart';
import 'package:optomstroy/features/session_ui/presentation/widgets/step_up_dialog.dart';
import 'package:optomstroy/features/splash/presentation/screens/splash_screen.dart';

/// Тестовый код OTP контура (`AUTH_FIXTURES.otpCode`).
const String _otpCode = String.fromEnvironment('E2E_OTP_CODE', defaultValue: '246810');

/// Национальные номера (9 цифр) из `AUTH_FIXTURES` стека.
const String _cashierPhone = '777000906';
const String _seniorPhone = '777000907';
const String _adminPhone = '777000901';
const String _ownerPhone = '777000909';

/// Покупатель = карточка 1С «долг в лимите» (`AUTH_FIXTURES.cashierCustomerLinked` = `debtWithinLimit` синтетики
/// кассира; не телефон фикстуры `customers-search.200` — тот у `customerLinked`, см. support/fixture_phones.dart).
const String _buyerPhone = '700123456';

/// Клиент с просрочкой 8 000,00 (`CASHIER_SCENARIOS.overdue`, +996700223344): поиск по 4 последним цифрам.
const String _overdueQuery = '3344';

/// PIN (тестовые, только этот стек).
const String _cashierPin = '715382';
const String _seniorPin = '826493';
const String _adminPin = '604817';
const String _ownerPin = '461937';
const String _buyerPin = '7391';

/// Каталог pos-api (local-stack.mjs); пусто — поиск `pos-api` вверх от рабочего каталога и exe.
const String _apiDirDefine = String.fromEnvironment('E2E_API_DIR');

/// Синтетических SKU стека.
const String _catalogSku = String.fromEnvironment('E2E_CATALOG_SKU', defaultValue: '200');

/// Стек уже запущен (итерации разработки).
const bool _externalStack = bool.fromEnvironment('E2E_EXTERNAL_STACK');

/// Управляющий HTTP стенда кассира (`LOCAL_STACK_CONTROL_PORT`, dev-only).
const String _control = String.fromEnvironment('E2E_STACK_CONTROL', defaultValue: 'http://127.0.0.1:8092');

/// Управляющие вызовы фейка HTTP-сервиса 1С (`LOCAL_STACK_ONEC_PORT`, dev-only; `POST /__fake/down`).
const String _fakeOnec = String.fromEnvironment('E2E_FAKE_ONEC', defaultValue: 'http://127.0.0.1:8091');

/// Сценарные клиенты синтетики кассира (`CASHIER_SCENARIO_PHONES`, pos-api synthetic-cashier.ts; тестовые данные):
/// «долга нет, отсрочка разрешена» — кандидат-дубль FLOW-029; «неполный снимок» (просрочка неизвестна) — FLOW-025.
const String _noDebtPhone = '+996555000103';
const String _incompletePhone = '+996555000107';

const Key _catalogRoot = ValueKey<String>('stub-SCR-10');
const Key _cashierRoot = ValueKey<String>('stub-SCR-30');
const Key _customersRoot = ValueKey<String>('stub-SCR-31');
const Key _customerCardRoot = ValueKey<String>('stub-SCR-32');
const Key _receivablesRoot = ValueKey<String>('stub-SCR-34');
const Key _transactionsRoot = ValueKey<String>('stub-SCR-36');
const Key _paymentRoot = ValueKey<String>('stub-SCR-38');
const Key _returnRoot = ValueKey<String>('stub-SCR-39');
const Key _cartRoot = ValueKey<String>('stub-SCR-20');
const Key _checkoutRoot = ValueKey<String>('checkout-screen');
const Key _createdRoot = ValueKey<String>('order-created-screen');
const Key _orderRoot = ValueKey<String>('stub-SCR-24');
const Key _newCustomerRoot = ValueKey<String>('customer-new-screen');
const Key _auditRoot = ValueKey<String>('scr-47');
const Key _reportsRoot = ValueKey<String>('scr-48');

final _LocalStack _stack = _LocalStack();
final _RecordingPrinter _printer = _RecordingPrinter();

/// Состояние между сценариями одного стека.
final class _World {
  String? overdueId;
  String? buyerCustomerId;
  String? cashOrderId;
  String? returnId;
  String? creditOrderId;

  /// Вторая заявка кассира (по заказу FLOW-023) — отклоняет старший (FLOW-031.A4 «Отклонить»).
  String? rejectReturnId;

  /// Оплаченный заказ, отмену которого кассир запросил со step-up (FLOW-026.S4) — аудит `order.cancel_requested`.
  String? cancelRequestedOrderId;
}

final _World _w = _World();

List<Override> _overrides() => <Override>[
  appOrderDocumentPrinterProvider.overrideWithValue(_printer),
  // Печать SCR-22 (счёт при появлении номера 1С, PRINT-009) — без системного диалога печати Windows.
  appCheckoutPrinterProvider.overrideWithValue(_printer.print),
  // Сигнал сети ОС — управляемый тестом (офлайн SCR-31/SCR-34, T-CUST-013, T-DEBT-013).
  connectivityWatcherProvider.overrideWith((Ref ref) {
    final ConnectivityWatcher watcher = ConnectivityWatcher(_net);
    unawaited(watcher.start());
    ref.onDispose(watcher.dispose);
    return watcher;
  }),
];

/// Сигнал «есть сеть» ОС, которым управляет тест (сама сеть стенда не отключается).
final class _SwitchableNetwork implements NetworkSignalSource {
  final StreamController<bool> _changes = StreamController<bool>.broadcast();
  bool _up = true;

  @override
  Future<bool> hasNetwork() async => _up;

  @override
  Stream<bool> get changes => _changes.stream;

  void set({required bool up}) {
    _up = up;
    _changes.add(up);
  }
}

final _SwitchableNetwork _net = _SwitchableNetwork();

// ---------------------------------------------------------------------------
// Локальный стек: запуск, ожидание готовности, штатная остановка, управляющие вызовы
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
      debugPrint('cashier_flow_test: внешний стек (E2E_EXTERNAL_STACK)');
      return;
    }
    final Directory api = _apiDir();
    final String sep = Platform.pathSeparator;
    final File ready = File('${_tmp()}${sep}cashier_flow_ready_${DateTime.now().millisecondsSinceEpoch}.txt');
    final File logFile = File('${_tmp()}${sep}cashier_flow_stack.log');
    _log = logFile.openWrite();
    final Process p = await Process.start(
      'node',
      <String>[
        'scripts/local-stack.mjs',
        'serve',
        '--auth-fixtures',
        '--catalog-fixtures=$_catalogSku',
        '--pos-fixtures',
        '--cashier-fixtures',
        '--qr-paid-after-polls',
        '0',
        '--ready-file',
        ready.path,
        '--exit-on-stdin-end',
      ],
      workingDirectory: api.path,
      environment: <String, String>{
        'LOCAL_STACK_MIN_APP_VERSION': 'android=0.1.0,windows=0.1.0',
        'LOCAL_STACK_LOG_DIR': '${_tmp()}${sep}cashier_flow_logs',
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
    debugPrint('cashier_flow_test: стек кассира готов (журнал ${logFile.path})');
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
    debugPrint('cashier_flow_test: стек остановлен (код $code)');
  }

  /// «Отгрузка» заказа для заявки на возврат (только стенд: `orders.status=shipped` + реализация 1С).
  Future<void> ship(String orderId) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest req = await client.postUrl(Uri.parse('$_control/__stack/ship/$orderId'));
      final HttpClientResponse res = await req.close();
      final String text = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) throw StateError('ship $orderId → ${res.statusCode} $text');
    } finally {
      client.close(force: true);
    }
  }

  /// «1С недоступна» (фейк: все методы `/pos/v1/*` → 503) — FLOW-025; [down] `false` — восстановление.
  Future<void> onecDown({required bool down}) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest req = await client.postUrl(Uri.parse('$_fakeOnec/__fake/down'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(<String, Object?>{'down': down}));
      final HttpClientResponse res = await req.close();
      final String text = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) throw StateError('__fake/down $down → ${res.statusCode} $text');
    } finally {
      client.close(force: true);
    }
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
// Общие шаги (как pos_flow_test.dart)
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
    if (!k.startsWith('product-')) keys.add(k);
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

AppLocalizations _l10n(WidgetTester tester) => AppLocalizations.of(tester.element(find.byType(Navigator).first));

Finder _input(Key key) => find.descendant(of: find.byKey(key), matching: find.byType(EditableText));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  // Снекбар (480 lp внизу окна) перекрывает кнопки нижней панели — касание ушло бы в него.
  for (final ScaffoldMessengerState m in tester.stateList<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))) {
    m.clearSnackBars();
  }
  await tester.ensureVisible(finder);
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

String _keySuffix(Finder f, String prefix) {
  final Widget w = f.evaluate().first.widget;
  return (w.key! as ValueKey<String>).value.substring(prefix.length);
}

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

/// StepUpDialog, если операция его запросила; иначе — дождаться [done] (токен операции этой сессии ещё действует).
Future<void> _stepUpUnlessDone(
  WidgetTester tester,
  String pin,
  Future<bool> Function() done, {
  required String what,
}) async {
  final Finder dialog = find.byWidgetPredicate(
    (Widget w) => w.key == StepUpDialog.dialogKey || w.key == StepUpDialog.sheetKey,
  );
  final String next = await pumpUntil<String>(tester, () async {
    if (dialog.evaluate().isNotEmpty) return 'step-up';
    return await done() ? 'done' : null;
  }, what: what);
  if (next == 'step-up') await _stepUp(tester, pin);
}

/// ConfirmDialog: [reason] — поле причины (вариант `withReason`); подтверждение — главная кнопка диалога.
Future<void> _confirm(WidgetTester tester, {String? reason}) async {
  await pumpUntilFound(tester, find.byType(ConfirmDialog));
  await _settle(tester, frames: 3);
  if (reason != null) {
    final Finder field = find.descendant(of: find.byType(ConfirmDialog), matching: find.byType(EditableText));
    await tester.enterText(field.first, reason);
    await tester.pump();
  }
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

Future<void> _cleanStart(WidgetTester tester) async {
  _printer.files.clear();
  await FlutterSecureStorageAdapter().deleteAll(<SecureKey>[...SecureKey.session, ...SecureKey.registration]);
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
Future<Object?> _apiGet(WidgetTester tester, String path, [Map<String, Object?>? query]) =>
    tester.runAsync(() => _apiRaw(tester, path, query));

/// То же без `runAsync` — для условий [pumpUntil] (они уже выполняются в `runAsync`).
Future<Object> _apiRaw(WidgetTester tester, String path, [Map<String, Object?>? query]) async {
  final Dio dio = _container(tester).read(dioProvider);
  final Response<Object?> r = await dio.get<Object?>(path, queryParameters: query);
  return r.data ?? const <String, Object?>{};
}

Future<Map<String, Object?>> _apiMap(WidgetTester tester, String path) async {
  final Object data = await _apiRaw(tester, path);
  return data is Map<String, Object?> ? data : const <String, Object?>{};
}

Future<Map<String, Object?>> _api(WidgetTester tester, String path, [Map<String, Object?>? query]) async {
  final Object? data = await _apiGet(tester, path, query);
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

/// [n] продаваемых товаров без характеристик в наличии, с ценой, целые количества.
/// [maxPriceTyiyn] — цена строки не выше (заявка на возврат кассира — ниже порога согласования
/// `return_approval_threshold` 10 000,00 сом стенда, иначе отправка требует решения старшего, 10 RET-…).
Future<List<_Sku>> _sellable(WidgetTester tester, int n, {int skip = 0, int? maxPriceTyiyn}) async {
  final AppDatabase db = _db(tester);
  final List<_Sku> rows =
      await tester.runAsync(() async {
        final String? warehouse = await db.catalogDao.defaultWarehouseId();
        final List<QueryRow> res = await db
            .customSelect(
              'SELECT p.id AS pid, p.sku AS sku, v.id AS vid FROM products p '
              'JOIN product_variants v ON v.product_id = p.id AND v.deletion_mark = 0 AND v.is_default = 1 '
              'JOIN stock_balances s ON s.variant_id = v.id AND s.warehouse_id = ? AND s.available_milli >= 20000 '
              'WHERE p.deletion_mark = 0 AND p.has_variants = 0 AND p.is_sellable = 1 AND p.qty_precision = 0 '
              'AND p.sku IS NOT NULL AND length(p.sku) >= 4 '
              'AND EXISTS (SELECT 1 FROM prices pr WHERE pr.variant_id = v.id AND pr.packaging_id IS NULL '
              'AND pr.price_tyiyn > 0 AND pr.price_tyiyn <= ?) '
              'AND (SELECT COUNT(*) FROM products p2 WHERE p2.sku = p.sku) = 1 '
              'ORDER BY p.sku LIMIT ? OFFSET ?',
              variables: <Variable<Object>>[
                Variable<String>(warehouse ?? ''),
                Variable<int>(maxPriceTyiyn ?? 1 << 52),
                Variable<int>(n),
                Variable<int>(skip),
              ],
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

/// SCR-11 по артикулу → «+ Добавить» на карточке.
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

Cart? _serverCart(WidgetTester tester) => _container(tester).read(cartControllerProvider).server;

/// SCR-20: строки [items] подтверждены сервером.
Future<Cart> _openCartWith(WidgetTester tester, List<_Sku> items) async {
  _router(tester)!.go('/cart');
  await pumpUntilFound(tester, find.byKey(_cartRoot));
  await pumpUntilTrue(tester, () {
    final Cart? c = _serverCart(tester);
    return c != null &&
        items.every((i) => c.items.any((CartLine l) => l.variantId == i.variantId)) &&
        !_container(tester).read(cartControllerProvider).hasUnconfirmed;
  }, what: 'корзина подтверждена сервером (${items.length} позиции)');
  return _serverCart(tester)!;
}

Future<void> _toCheckout(WidgetTester tester) async {
  await pumpUntilFound(tester, _enabledButton(CartKeys.createOrder));
  await _tap(tester, _enabledButton(CartKeys.createOrder));
  await pumpUntilFound(tester, find.byKey(_checkoutRoot));
  await _settle(tester);
}

Future<void> _pickup(WidgetTester tester) async {
  final Finder pickup = find.byKey(const ValueKey<String>('checkout-delivery-pickup'));
  await pumpUntilFound(tester, pickup);
  await _tap(tester, pickup);
  await _settle(tester, frames: 3);
}

Future<void> _payment(WidgetTester tester, String method) async {
  final Finder pay = find.byKey(ValueKey<String>('payment-method-$method'));
  await pumpUntilFound(tester, pay, timeout: const Duration(seconds: 30));
  await _tap(tester, pay.first);
  await _settle(tester, frames: 3);
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

Future<String> _createOrder(WidgetTester tester) async {
  await _openCheckoutReview(tester);
  final Finder cta = _enabledButton(const ValueKey<String>('checkout-cta'));
  await pumpUntilFound(tester, cta, timeout: const Duration(seconds: 30));
  await _tap(tester, cta.first);
  await pumpUntilFound(tester, find.byKey(_createdRoot), timeout: const Duration(seconds: 60));
  final List<String> seg = Uri.parse(_where(tester)).pathSegments;
  expect(seg.length >= 3 && seg[0] == 'orders' && seg[2] == 'created', isTrue, reason: 'SCR-22: ${_where(tester)}');
  return seg[1];
}

/// SCR-31: поиск [q] → ID первого найденного клиента.
Future<String> _searchCustomer(WidgetTester tester, String q) async {
  _router(tester)!.go('/customers');
  await pumpUntilFound(tester, find.byKey(_customersRoot));
  await pumpUntilFound(tester, _input(const ValueKey<String>('customers-search-field')));
  await tester.enterText(_input(const ValueKey<String>('customers-search-field')), q);
  await tester.pump();
  await pumpUntilFound(tester, _keyPrefix('customer-row-'), timeout: const Duration(seconds: 30));
  final String id = _keySuffix(
    find.byWidgetPredicate((Widget w) {
      final Key? k = w.key;
      if (k is! ValueKey<String>) return false;
      return k.value.startsWith('customer-row-') &&
          !k.value.startsWith('customer-row-star-') &&
          !k.value.startsWith('customer-row-debt-');
    }),
    'customer-row-',
  );
  return id;
}

/// Заявка на возврат кассира (FLOW-031.S1…S5): заказ [orderId] «отгружен» (стенд) → SCR-24 «Заявка на возврат» →
/// SCR-39 (строка 1, причина «Брак») → сохранить (`draft`) → отправить (step-up PIN) → `submitted`; ID заявки.
Future<String> _submitReturn(WidgetTester tester, String orderId) async {
  await tester.runAsync(() => _stack.ship(orderId));
  _router(tester)!.go('/orders/$orderId');
  await pumpUntilFound(tester, find.byKey(_orderRoot), timeout: const Duration(seconds: 60));
  final Finder returnAction = _enabledButton(const ValueKey<String>('action-return'));
  await pumpUntil<bool>(
    tester,
    () async {
      if (returnAction.evaluate().isNotEmpty) return true;
      // Статус заказа на экране обновляется перечитыванием.
      _router(tester)!.go('/orders/$orderId?r=${DateTime.now().millisecondsSinceEpoch}');
      return null;
    },
    what: '«Заявка на возврат» на SCR-24 отгруженного заказа',
    timeout: const Duration(seconds: 60),
  );
  await _tap(tester, returnAction.first);
  await pumpUntilFound(tester, find.byKey(_returnRoot), timeout: const Duration(seconds: 30));
  final AppLocalizations l10n = _l10n(tester);
  // Позиция заказа (строка 1; отгружено — по реализации 1С) — отметка строки (UI-39-002).
  final Finder line = find.byKey(const ValueKey<String>('return-line-1'));
  await pumpUntilFound(tester, line, timeout: const Duration(seconds: 30));
  await _tap(tester, find.descendant(of: line, matching: find.byType(AppCheckbox)).first);
  await _settle(tester, frames: 3);
  final Finder reasonRadio = find.byKey(const ValueKey<String>('return-reason-defect'));
  if (reasonRadio.evaluate().isNotEmpty) {
    await _tap(tester, reasonRadio);
  } else {
    await _tap(tester, find.byKey(const ValueKey<String>('return-reason-dropdown')));
    await _settle(tester, frames: 5);
    final Finder item = find.ancestor(of: find.text(l10n.return_reason_defect), matching: find.byType(MenuItemButton));
    await pumpUntilFound(tester, item);
    await _tap(tester, item.first);
  }
  await _settle(tester, frames: 3);
  expect(
    tester.widget<AppCheckbox>(find.descendant(of: line, matching: find.byType(AppCheckbox)).first).value,
    isTrue,
    reason: 'позиция отмечена',
  );
  await _tap(tester, _enabledButton(const ValueKey<String>('return-save')));
  final String returnId = await pumpUntil<String>(tester, () async {
    final List<String> seg = Uri.parse(_where(tester)).pathSegments;
    return seg.length == 2 && seg[0] == 'returns' && seg[1] != 'new' ? seg[1] : null;
  }, what: 'заявка сохранена (POST /returns) → /returns/{id}');
  final Finder submit = _enabledButton(const ValueKey<String>('return-submit'));
  await pumpUntilFound(tester, submit, timeout: const Duration(seconds: 30));
  await _tap(tester, submit);
  if (find.byType(ConfirmDialog).evaluate().isNotEmpty) await _confirm(tester);
  // StepUpDialog — если токена операции `return.submit` этой сессии ещё нет (действует 15 мин, 09 §4.6): вторая
  // заявка подряд отправляется с тем же токеном без диалога.
  await _stepUpUnlessDone(
    tester,
    _cashierPin,
    () async => (await _apiMap(tester, '/returns/$returnId'))['status'] == 'submitted',
    what: 'StepUpDialog или заявка $returnId отправлена',
  );
  await pumpUntil<bool>(
    tester,
    () async => (await _apiMap(tester, '/returns/$returnId'))['status'] == 'submitted' ? true : null,
    what: 'заявка $returnId отправлена (submitted)',
  );
  return returnId;
}

/// FLOW-026 «Отмена заказа» на SCR-24 (04 FLOW-026.S1…S5; 10 ORD-050, ORD-051; 08 §4.8.4): «Отменить заказ» /
/// «Запросить отмену» → диалог отмены с причиной (`reasonCode` + текст; при полученных деньгах — `refundIntent`) →
/// `POST /orders/{id}/cancel`. [stepUp] — ветка S4 (после согласования / с полученной оплатой: `403 STEP_UP_REQUIRED`
/// → StepUpDialog → повтор с тем же `Idempotency-Key`); без него — S2 (свой заказ без полученных денег, step-up не
/// запрашивается). Итог на экране: снекбар «Заказ отменён» (S3, немедленная отмена) или «Запрос отмены отправлен в 1С»
/// (чип `order-cancel-requested`), затем — после ответа 1С (фейк: «Закрыт») — статус «Отменён», действий отмены нет.
/// Возвращает `true`, если отмена была немедленной.
Future<bool> _cancelOrder(WidgetTester tester, String orderId, {required bool stepUp}) async {
  final AppLocalizations l10n = _l10n(tester);
  _router(tester)!.go('/orders/$orderId');
  await pumpUntilFound(tester, find.byKey(_orderRoot), timeout: const Duration(seconds: 60));
  final Finder cancelAction = _enabledButton(const ValueKey<String>('action-cancel'));
  await pumpUntilFound(tester, cancelAction, timeout: const Duration(seconds: 30));
  expect(
    tester.widget<AppButton>(cancelAction).label,
    stepUp ? l10n.order_action_cancel_request : l10n.order_action_cancel,
    reason: stepUp ? 'с полученной оплатой — «Запросить отмену»' : 'свой заказ без оплаты — «Отменить заказ»',
  );
  await _tap(tester, cancelAction);
  final Finder dialog = find.byType(OrderCancelDialog);
  await pumpUntilFound(tester, dialog, timeout: const Duration(seconds: 10));
  await _settle(tester, frames: 4);
  final Finder confirm = find.byKey(const ValueKey<String>('cancel-confirm'));
  expect(tester.widget<AppButton>(confirm).onPressed, isNull, reason: 'без причины подтвердить нельзя');
  await _tap(tester, find.byKey(const ValueKey<String>('cancel-reason-customer_refused')));
  await tester.enterText(_input(const ValueKey<String>('cancel-reason-text')), 'Покупатель отказался от покупки');
  await tester.pump();
  final Finder refund = find.byKey(const ValueKey<String>('cancel-refund'));
  if (stepUp) {
    expect(refund, findsOneWidget, reason: 'деньги получены — выбор «вернуть / оставить авансом»');
    expect(tester.widget<AppButton>(confirm).onPressed, isNull, reason: 'нужен refundIntent');
    await _tap(tester, refund);
    await _settle(tester, frames: 3);
  } else {
    expect(refund, findsNothing, reason: 'полученных денег нет — refundIntent не спрашивается');
  }
  await pumpUntilFound(tester, _enabledButton(const ValueKey<String>('cancel-confirm')));
  await _tap(tester, _enabledButton(const ValueKey<String>('cancel-confirm')));
  final Finder stepUpDialog = find.byWidgetPredicate(
    (Widget w) => w.key == StepUpDialog.dialogKey || w.key == StepUpDialog.sheetKey,
  );
  if (stepUp) {
    // S4: без токена `order.cancel.request.any` сервер отвечает 403 STEP_UP_REQUIRED — PIN кассира.
    await _stepUp(tester, _cashierPin);
  }
  await pumpUntilTrue(
    tester,
    () => dialog.evaluate().isEmpty || (!stepUp && stepUpDialog.evaluate().isNotEmpty),
    what: 'диалог отмены закрыт (ответ POST /orders/$orderId/cancel)',
  );
  expect(stepUpDialog, findsNothing, reason: stepUp ? 'step-up пройден' : 'свой заказ без оплаты — без step-up');
  final Finder done = find.text(l10n.order_cancelled_snackbar);
  final Finder requested = find.text(l10n.order_cancel_requested_snackbar);
  await pumpUntilTrue(
    tester,
    () => done.evaluate().isNotEmpty || requested.evaluate().isNotEmpty,
    what: 'снекбар «Заказ отменён» / «Запрос отмены отправлен в 1С»',
    timeout: const Duration(seconds: 15),
  );
  final bool immediate = requested.evaluate().isEmpty;
  final Map<String, Object?> after = await _api(tester, '/orders/$orderId');
  if (immediate) {
    expect(stepUp, isFalse, reason: 'с полученной оплатой немедленная отмена недопустима (ORD-051)');
    expect(after['status'], 'cancelled', reason: 'немедленная отмена (FLOW-026.S3)');
  } else {
    // Запрос отмены в 1С (outbox `cancel`): статус меняет только 1С; до ответа — `cancelRequested` (или уже отменён).
    expect(after['cancelRequested'] == true || after['status'] == 'cancelled', isTrue, reason: 'запрос отмены записан');
  }
  // Ответ 1С (фейк: документ «Закрыт») → `cancelled`; экран перечитывается (автообновление SCR-24 — раз в 60 с).
  await pumpUntil<bool>(
    tester,
    () async => (await _apiMap(tester, '/orders/$orderId'))['status'] == 'cancelled' ? true : null,
    what: 'заказ $orderId отменён (GET /orders/{id})',
    timeout: const Duration(seconds: 120),
  );
  final Finder cancelledChip = find.byWidgetPredicate(
    (Widget w) =>
        w is OrderStatusChip && w.key == const ValueKey<String>('order-status') && w.status == OrderStatus.cancelled,
  );
  await pumpUntil<bool>(
    tester,
    () async {
      if (cancelledChip.evaluate().isNotEmpty) return true;
      _router(tester)!.go('/orders/$orderId?r=${DateTime.now().millisecondsSinceEpoch}');
      return null;
    },
    what: 'SCR-24: статус «${l10n.status_order_cancelled}»',
    timeout: const Duration(seconds: 60),
  );
  await _settle(tester, frames: 3);
  expect(find.byKey(const ValueKey<String>('action-cancel')), findsNothing, reason: 'у отменённого заказа отмены нет');
  return immediate;
}

/// ID клиента по полному номеру (`GET /customers?q=`; cashier ищет по телефону).
Future<String> _customerIdByPhone(WidgetTester tester, String e164) async {
  final Map<String, Object?> page = await _api(tester, '/customers', <String, Object?>{'q': e164});
  final List<Object?> items = page['items'] as List<Object?>? ?? const <Object?>[];
  expect(items, isNotEmpty, reason: 'сценарный клиент найден по телефону');
  return (items.first! as Map<String, Object?>)['id']! as String;
}

/// SCR-32 «В заказ» клиента [customerId] (замена клиента корзины — ConfirmDialog) → клиент назначен серверной корзине.
Future<void> _assignCustomerFromCard(WidgetTester tester, String customerId) async {
  _router(tester)!.go('/customers/$customerId');
  await pumpUntilFound(tester, find.byKey(_customerCardRoot));
  final Finder toCart = _enabledButton(const ValueKey<String>('customer-card-to-cart'));
  await pumpUntilFound(tester, toCart, timeout: const Duration(seconds: 30));
  await _tap(tester, toCart);
  await _settle(tester);
  if (find.byType(ConfirmDialog).evaluate().isNotEmpty) await _confirm(tester);
  await pumpUntilTrue(
    tester,
    () => _serverCart(tester)?.customer?.id == customerId,
    what: 'клиент $customerId назначен корзине',
  );
}

/// SCR-26: телефон и имя (поля пусты или предзаполнены из поиска SCR-31).
Future<void> _fillNewCustomer(WidgetTester tester, {required String national, required String name}) async {
  await pumpUntilFound(tester, find.byKey(_newCustomerRoot));
  await _settle(tester);
  await tester.enterText(_input(const ValueKey<String>('customer-new-phone')), national);
  await tester.pump();
  await tester.enterText(_input(const ValueKey<String>('customer-new-name')), name);
  await tester.pump();
}

/// Последние 366 дней (журналы этапа G — период обязателен).
Map<String, Object?> _period() {
  final DateTime now = DateTime.now().toUtc();
  return <String, Object?>{
    'from': now.subtract(const Duration(days: 30)).toIso8601String(),
    'to': now.add(const Duration(minutes: 5)).toIso8601String(),
  };
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // До первого обращения к secure storage: данные приложения — в APP_DATA_DIR, не на C:.
  AppDataDirectory.apply(AppConfig.fromEnvironment());

  setUpAll(_stack.start);
  tearDownAll(_stack.stop);

  testWidgets('RM-G-009 кассир (T-CASH-001, T-CASH-004, T-SEC-042, T-TXN-004, T-CUST-005, T-RET-005, AC-UI-32-005, '
      'AC-UI-38-001): SCR-30 → SCR-31 → SCR-32 долг (просрочка) → «В заказ» → SCR-21 «В долг» заблокировано '
      'fail-closed → наличные → SCR-38 оплата → SCR-36 транзакция; новый клиент из оформления (SCR-26); возврат: '
      'SCR-24 → SCR-39 → отправить (step-up) → submitted; FLOW-025 (1С недоступна), FLOW-029 (дубликат), FLOW-022 (SCR-38 '
      'ручное подтверждение QR), FLOW-026 (отмена заказа: без step-up и S4 со step-up)', (tester) async {
    await _staffFirstLogin(tester, _cashierPhone, _cashierPin, home: _cashierRoot);
    debugPrint('cashier_flow_test: кассир — SCR-30');
    await _waitCatalogCache(tester);

    // SCR-31 → SCR-32: клиент с просрочкой; сводка долга из снимка 1С (cashier видит суммы).
    final String overdueId = await _searchCustomer(tester, _overdueQuery);
    _w.overdueId = overdueId;
    _router(tester)!.go('/customers/$overdueId');
    await pumpUntilFound(tester, find.byKey(_customerCardRoot));
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('debt-summary-balance')),
      timeout: const Duration(seconds: 30),
    );
    // RM-G-013 (Q-152): оплата долга без заказа в R1 выключена — кнопки нет.
    expect(find.byKey(const ValueKey<String>('customer-card-accept-debt')), findsNothing);

    // FLOW-042: избранный клиент — звезда SCR-32 → `PUT /favorites/customers/{id}` → блок «Избранные клиенты» SCR-30.
    Future<bool> isFavorite() async {
      final Object page = await _apiRaw(tester, '/favorites/customers');
      final List<Object?> items = page is Map<String, Object?>
          ? (page['items'] as List<Object?>? ?? const [])
          : const [];
      return items.any((Object? c) => c is Map<String, Object?> && c['id'] == overdueId);
    }

    final Finder star = find.byKey(const ValueKey<String>('customer-card-favorite'));
    await pumpUntilFound(tester, star, timeout: const Duration(seconds: 30));
    if (await tester.runAsync(isFavorite) ?? false) {
      await _tap(tester, star);
      await pumpUntil<bool>(tester, () async => await isFavorite() ? null : true, what: 'клиент убран из избранного');
    }
    await _tap(tester, star);
    await pumpUntil<bool>(tester, () async => await isFavorite() ? true : null, what: 'клиент в избранном (PUT)');
    _router(tester)!.go('/cashier');
    await pumpUntilFound(tester, find.byKey(_cashierRoot));
    await pumpUntilFound(
      tester,
      find.byKey(ValueKey<String>('cashier-favorite-$overdueId')),
      timeout: const Duration(seconds: 60),
    );
    debugPrint('cashier_flow_test: FLOW-042 — клиент в избранном и на SCR-30');

    // SCR-34 клиента: сводка снимка 1С (cashier, только память сессии).
    _router(tester)!.go('/customers/$overdueId/receivables');
    await pumpUntilFound(tester, find.byKey(_receivablesRoot), timeout: const Duration(seconds: 30));
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('debt-summary-balance')),
      timeout: const Duration(seconds: 30),
    );

    // Офлайн (T-DEBT-013, T-CUST-013; ядро §18.2 п. 1): финансов клиента без сети нет — ни на SCR-34 клиента, долг
    // которого в этой сессии не открывался (локального кэша нет; память сессии — только просмотренные), ни в поиске SCR-31.
    final Map<String, Object?> unseen = await _api(tester, '/customers', <String, Object?>{'q': '+996$_buyerPhone'});
    final String unseenId = ((unseen['items']! as List<Object?>).first! as Map<String, Object?>)['id']! as String;
    _router(tester)!.go('/cashier');
    await pumpUntilFound(tester, find.byKey(_cashierRoot));
    final AppLocalizations off = _l10n(tester);
    _net.set(up: false);
    await pumpUntilTrue(
      tester,
      () => _container(tester).read(connectivityWatcherProvider).current == OnlineStatus.offline,
      what: 'приложение в офлайне',
    );
    _router(tester)!.go('/customers/$unseenId/receivables');
    await pumpUntilFound(tester, find.text(off.receivables_offline), timeout: const Duration(seconds: 30));
    expect(find.byKey(const ValueKey<String>('debt-summary-balance')), findsNothing);
    _router(tester)!.go('/customers');
    await pumpUntilFound(tester, find.byKey(_customersRoot));
    // Ветка «Клиенты» хранит прошлый результат поиска — новый запрос без сети не выполняется.
    // Ответ любого фонового запроса возвращает статус «онлайн» (сеть стенда не отключается) — сигнал «нет сети»
    // повторяется до появления офлайн-состояния поиска.
    final DateTime offlineDeadline = DateTime.now().add(const Duration(seconds: 60));
    int attempt = 0;
    while (find.text(off.customers_search_offline).evaluate().isEmpty) {
      if (DateTime.now().isAfter(offlineDeadline)) {
        final CustomersSearchState st = _container(tester).read(customersSearchProvider);
        fail(
          'SCR-31 без сети: нет «${off.customers_search_offline}»; фаза ${st.phase.name}, запрос «${st.query}», '
          'сеть ${_container(tester).read(connectivityWatcherProvider).current.name}; ключи: ${_visibleKeys()}',
        );
      }
      // Новый запрос поиска SCR-31 сразу (как Enter), пока статус «нет сети» не сменился ответом фонового запроса;
      // контроллер экрана — тот же, что у поля поиска.
      _net.set(up: false);
      await tester.pump();
      final CustomersSearchController search = _container(tester).read(customersSearchProvider.notifier);
      search.setQuery((attempt++).isEven ? 'Асанов' : 'Асанова');
      await search.submit();
      await _settle(tester, frames: 3);
    }
    _net.set(up: true);
    await pumpUntilTrue(
      tester,
      () => _container(tester).read(connectivityWatcherProvider).current != OnlineStatus.offline,
      what: 'сеть восстановлена',
    );
    debugPrint('cashier_flow_test: офлайн — SCR-34 и SCR-31 без финансовых данных');
    _router(tester)!.go('/customers/$overdueId');
    await pumpUntilFound(tester, find.byKey(_customerCardRoot));
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('debt-summary-balance')),
      timeout: const Duration(seconds: 60),
    );
    // ID карточки покупателя «долг в лимите» — для сценария клиента (поиск по полному номеру, кассир).
    final Map<String, Object?> buyer = await _api(tester, '/customers', <String, Object?>{'q': '+996$_buyerPhone'});
    _w.buyerCustomerId = ((buyer['items']! as List<Object?>).first! as Map<String, Object?>)['id'] as String?;
    expect(_w.buyerCustomerId, isNotNull);

    // «В заказ» (UI-32-011): клиент назначен корзине → корзина / каталог с панелью корзины.
    final Finder toCart = _enabledButton(const ValueKey<String>('customer-card-to-cart'));
    await pumpUntilFound(tester, toCart);
    await _tap(tester, toCart);
    await pumpUntilTrue(
      tester,
      () => _where(tester) == '/cart' || _where(tester).startsWith('/catalog'),
      what: 'переход в корзину после «В заказ»',
    );
    await pumpUntilTrue(
      tester,
      () => _serverCart(tester)?.customer?.id == overdueId,
      what: 'клиент назначен корзине (POST /cart/customer)',
    );
    debugPrint('cashier_flow_test: «В заказ» — клиент с просрочкой в корзине');

    final List<_Sku> items = await _sellable(tester, 1, maxPriceTyiyn: 300000);
    await _addFromCatalog(tester, items.single);
    final Cart cart = await _openCartWith(tester, items);
    expect(cart.customer?.id, overdueId);

    // SCR-21: «В долг» → отказ fail-closed (просрочка) с причиной; у кассира — только «Как получить разрешение».
    await _toCheckout(tester);
    await _pickup(tester);
    await _payment(tester, 'credit');
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('checkout-credit-reason')),
      timeout: const Duration(seconds: 60),
    );
    expect(find.byKey(const ValueKey<String>('checkout-credit-approve')), findsNothing);
    expect(find.byKey(const ValueKey<String>('checkout-credit-help')), findsOneWidget);
    debugPrint('cashier_flow_test: продажа в долг заблокирована (просрочка) — без step-up у кассира');

    // Наличные → заказ → SCR-38: приём наличных (сумма — с сервера) → оплачено.
    await _payment(tester, 'cash');
    final String orderId = await _createOrder(tester);
    _w.cashOrderId = orderId;
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
    final Map<String, Object?> paid = await _api(tester, '/orders/$orderId');
    expect(paid['isPaid'], isTrue, reason: 'заказ оплачен наличными (SCR-38)');
    debugPrint('cashier_flow_test: SCR-38 — наличные приняты, заказ оплачен');

    // SCR-36: операция по клиенту в журнале (API — тот же пользователь; строка — на экране).
    final String txId = await pumpUntil<String>(tester, () async {
      final Object page = await _apiRaw(tester, '/transactions', <String, Object?>{
        ..._period(),
        'customerId': overdueId,
      });
      final List<Object?> list = page is Map<String, Object?>
          ? (page['items'] as List<Object?>? ?? const [])
          : const [];
      for (final Object? t in list) {
        if (t is Map<String, Object?> && jsonEncode(t).contains(orderId)) return t['id'] as String?;
      }
      return null;
    }, what: 'транзакция оплаты заказа в GET /transactions');
    _router(tester)!.go('/transactions?customerId=$overdueId');
    await pumpUntilFound(tester, find.byKey(_transactionsRoot));
    await pumpUntilFound(tester, find.byKey(ValueKey<String>('tx-row-$txId')), timeout: const Duration(seconds: 30));
    debugPrint('cashier_flow_test: SCR-36 — транзакция оплаты в журнале');

    // FLOW-023: продажа в долг в пределах лимита — клиент «долг в лимите» → «В долг» разрешено → заказ `credit`.
    final String buyerId = _w.buyerCustomerId!;
    final List<_Sku> creditItems = await _sellable(tester, 1, maxPriceTyiyn: 300000);
    await _addFromCatalog(tester, creditItems.single);
    _router(tester)!.go('/customers/$buyerId');
    await pumpUntilFound(tester, find.byKey(_customerCardRoot));
    final Finder buyerToCart = _enabledButton(const ValueKey<String>('customer-card-to-cart'));
    await pumpUntilFound(tester, buyerToCart, timeout: const Duration(seconds: 30));
    await _tap(tester, buyerToCart);
    // Если в корзине уже другой клиент — ConfirmDialog «Заменить клиента в корзине?».
    await _settle(tester);
    if (find.byType(ConfirmDialog).evaluate().isNotEmpty) await _confirm(tester);
    await pumpUntilTrue(
      tester,
      () => _serverCart(tester)?.customer?.id == buyerId,
      what: 'клиент «долг в лимите» назначен корзине',
    );
    await _openCartWith(tester, creditItems);
    await _toCheckout(tester);
    await _pickup(tester);
    await _payment(tester, 'credit');
    await pumpUntilTrue(
      tester,
      () => !_container(
        tester,
      ).read(checkoutControllerProvider(Uri.parse(_where(tester)).queryParameters['cartId'])).previewing,
      what: 'предпроверка «В долг» завершена',
    );
    expect(find.byKey(const ValueKey<String>('checkout-credit-reason')), findsNothing, reason: 'долг в лимите');
    final String withinLimit = await _createOrder(tester);
    expect((await _api(tester, '/orders/$withinLimit'))['paymentMethod'], 'credit');
    debugPrint('cashier_flow_test: FLOW-023 — продажа в долг в пределах лимита');

    // FLOW-025 (AC-FLOW-025-05, AC-FLOW-025-06; 10 PAY-031 шаг 3, D-24 fail-closed): снимок долга клиента неполон
    // (просрочка неизвестна), 1С недоступна → SCR-34 «Обновить» — «1С недоступна, показаны данные от …»; SCR-21
    // «В долг» неактивна с причиной `checkout_credit_reason_stale` (без «Как получить разрешение» — старший её не
    // снимает, DEBT-010); наличные доступны, заказ по ним создаётся.
    final String incompleteId = await _customerIdByPhone(tester, _incompletePhone);
    final List<_Sku> staleItems = await _sellable(tester, 1, skip: 4);
    await _addFromCatalog(tester, staleItems.single);
    await tester.runAsync(() => _stack.onecDown(down: true));
    addTearDown(() => _stack.onecDown(down: false));
    _router(tester)!.go('/customers/$incompleteId/receivables');
    await pumpUntilFound(tester, find.byKey(_receivablesRoot), timeout: const Duration(seconds: 30));
    final AppLocalizations stale = _l10n(tester);
    final Finder onecDownText = find.textContaining(stale.receivables_refresh_onec_down('#').split('#').first);
    final Finder refresh = _enabledButton(const ValueKey<String>('debt-summary-refresh'));
    await pumpUntilFound(tester, refresh, timeout: const Duration(seconds: 30));
    // Снимок, записанный менее 30 с назад (прогон синхронизации), «обновляется» без обращения к 1С — повтор нажатия
    // через 8 с (лимит RL-RECV-REFRESH — 10 в минуту на пользователя).
    final DateTime refreshDeadline = DateTime.now().add(const Duration(seconds: 90));
    while (onecDownText.evaluate().isEmpty) {
      if (DateTime.now().isAfter(refreshDeadline)) {
        fail(
          'SCR-34 «Обновить» при недоступной 1С: нет «1С недоступна, показаны данные от …»; ключи: ${_visibleKeys()}',
        );
      }
      if (refresh.evaluate().isNotEmpty) await _tap(tester, refresh.first);
      for (int i = 0; i < 80 && onecDownText.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    await _assignCustomerFromCard(tester, incompleteId);
    await _openCartWith(tester, staleItems);
    await _toCheckout(tester);
    await _pickup(tester);
    await _payment(tester, 'credit');
    final Finder staleReason = find.byKey(const ValueKey<String>('checkout-credit-reason'));
    await pumpUntilFound(tester, staleReason, timeout: const Duration(seconds: 60));
    expect(
      find.descendant(of: staleReason, matching: find.text(stale.checkout_credit_reason_stale)),
      findsOneWidget,
      reason: 'RECEIVABLES_STALE: причина «данные о долге устарели, 1С недоступна»',
    );
    expect(find.byKey(const ValueKey<String>('checkout-credit-help')), findsNothing, reason: 'старший не снимает');
    expect(find.byKey(const ValueKey<String>('checkout-credit-approve')), findsNothing);
    await _payment(tester, 'cash');
    final String staleCashOrder = await _createOrder(tester);
    expect((await _api(tester, '/orders/$staleCashOrder'))['paymentMethod'], 'cash');
    await tester.runAsync(() => _stack.onecDown(down: false));
    debugPrint('cashier_flow_test: FLOW-025 — 1С недоступна: долг fail-closed, заказ за наличные создан');

    // FLOW-029 (S1–S4, AC-FLOW-029-01): SCR-21 «+ Новый клиент» → SCR-26 с телефоном существующей карточки 1С →
    // «Похоже, клиент уже есть» → «Использовать существующего» → клиент выбран в заказе, новая карточка не создана.
    final String noDebtId = await _customerIdByPhone(tester, _noDebtPhone);
    final List<_Sku> qrItems = await _sellable(tester, 1, skip: 3);
    await _addFromCatalog(tester, qrItems.single);
    await _openCartWith(tester, qrItems);
    await _toCheckout(tester);
    final Finder pickerNew = find.byKey(const ValueKey<String>('customer-picker-new'));
    if (pickerNew.evaluate().isEmpty) {
      // В корзине остался клиент — снять (крестик карточки клиента SCR-21).
      final Finder remove = find.descendant(
        of: find.byKey(const ValueKey<String>('checkout-customer-card')),
        matching: find.byWidgetPredicate((Widget w) => w is AppIconButton && w.icon == Icons.close_rounded),
      );
      if (remove.evaluate().isNotEmpty) await _tap(tester, remove.first);
    }
    await pumpUntilFound(tester, pickerNew, timeout: const Duration(seconds: 30));
    await _tap(tester, pickerNew);
    await _fillNewCustomer(tester, national: _noDebtPhone.substring(4), name: 'Дубликат Проверочный');
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('customer-new-duplicates')),
      timeout: const Duration(seconds: 30),
    );
    expect(find.byKey(const ValueKey<String>('customer-new-force')), findsOneWidget, reason: 'cashier — по праву');
    final Finder useExisting = _enabledButton(ValueKey<String>('customer-new-use-$noDebtId'));
    await pumpUntilFound(tester, useExisting, timeout: const Duration(seconds: 30));
    await _tap(tester, useExisting);
    await pumpUntilFound(tester, find.byKey(_checkoutRoot), timeout: const Duration(seconds: 30));
    await pumpUntilTrue(
      tester,
      () => _serverCart(tester)?.customer?.id == noDebtId,
      what: 'существующий клиент выбран в заказе (POST /cart/customer)',
    );
    final Map<String, Object?> sameNoDebt = await _api(tester, '/customers', <String, Object?>{'q': _noDebtPhone});
    expect(sameNoDebt['items']! as List<Object?>, hasLength(1), reason: 'дубль не создан');
    debugPrint('cashier_flow_test: FLOW-029 — дубликат найден, выбран существующий клиент');

    // FLOW-022 на SCR-38 (AC-FLOW-022-03, AC-FLOW-022-05): заказ → SCR-38 «QR» → «Подтвердить вручную» (референс
    // выписки, сумма) → step-up PIN кассира → оплата подтверждена вручную (`received`, `confirmationKind: manual`),
    // транзакция `manual_qr_confirm`. Стенд: QR через 1С не оплачивается сам (`--qr-paid-after-polls 0`).
    await _pickup(tester);
    await _payment(tester, 'cash');
    final String qrOrderId = await _createOrder(tester);
    _router(tester)!.go('/payments/new?orderId=$qrOrderId&method=qr_bakai');
    await pumpUntilFound(tester, find.byKey(_paymentRoot), timeout: const Duration(seconds: 60));
    final Finder confirmManual = _enabledButton(const ValueKey<String>('payment-confirm-manual'));
    await pumpUntilFound(tester, confirmManual, timeout: const Duration(seconds: 90));
    await _tap(tester, confirmManual);
    final Finder manualRef = _input(const ValueKey<String>('payment-manual-ref'));
    await pumpUntilFound(tester, manualRef, timeout: const Duration(seconds: 30));
    await _settle(tester, frames: 3);
    await tester.enterText(manualRef, 'BK-77123');
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('payment-manual-mismatch')), findsNothing, reason: 'сумма = к оплате');
    final Finder manualSubmit = _enabledButton(const ValueKey<String>('payment-manual-submit'));
    await pumpUntilFound(tester, manualSubmit);
    await _tap(tester, manualSubmit);
    await _stepUp(tester, _cashierPin);
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('payment-success')),
      timeout: const Duration(seconds: 60),
    );
    final Map<String, Object?> qrOrder = await _api(tester, '/orders/$qrOrderId');
    expect(qrOrder['isPaid'], isTrue, reason: 'заказ оплачен (ручное подтверждение QR)');
    final List<Object?> qrPayments = qrOrder['payments'] as List<Object?>? ?? const <Object?>[];
    final Map<String, Object?> manual = qrPayments.whereType<Map<String, Object?>>().firstWhere(
      (Map<String, Object?> p) => p['method'] == 'qr_bakai' && p['status'] == 'received',
      orElse: () => fail('платёж QR received в заказе: ${qrPayments.length} платежей'),
    );
    final Map<String, Object?> manualDetails = await _api(tester, '/payments/${manual['id']}');
    expect(manualDetails['status'], 'received');
    expect(manualDetails['confirmationKind'], 'manual', reason: 'ручное подтверждение кассиром (GET /payments/{id})');
    await pumpUntil<bool>(tester, () async {
      final Object page = await _apiRaw(tester, '/transactions', <String, Object?>{
        ..._period(),
        'customerId': noDebtId,
      });
      final List<Object?> list = page is Map<String, Object?>
          ? (page['items'] as List<Object?>? ?? const [])
          : const [];
      final int n = list
          .where((Object? t) => jsonEncode(t).contains('manual_qr_confirm') && jsonEncode(t).contains(qrOrderId))
          .length;
      return n == 1 ? true : null;
    }, what: 'одна транзакция manual_qr_confirm по заказу в GET /transactions');
    debugPrint('cashier_flow_test: FLOW-022 — SCR-38: QR подтверждён вручную со step-up');

    // FLOW-029.A2 (AC-FLOW-029-02 — причина обязательна): SCR-31 поиск по номеру → «+ Новый клиент» (номер из поиска)
    // → дубликат → «Всё равно создать» (кассир) → причина → «Создать клиента» → вторая карточка с тем же телефоном.
    await _searchCustomer(tester, _noDebtPhone.substring(4));
    await _tap(tester, find.byKey(const ValueKey<String>('customers-search-new')));
    await _fillNewCustomer(tester, national: _noDebtPhone.substring(4), name: 'Тестов Второй Контрагент');
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('customer-new-duplicates')),
      timeout: const Duration(seconds: 30),
    );
    expect(_enabledButton(const ValueKey<String>('customer-new-create')), findsNothing, reason: 'дубль — без причины');
    await _tap(tester, find.byKey(const ValueKey<String>('customer-new-force')));
    await pumpUntilFound(tester, _input(const ValueKey<String>('customer-new-force-reason')));
    await tester.enterText(
      _input(const ValueKey<String>('customer-new-force-reason')),
      'Другой контрагент, общий номер',
    );
    await tester.pump();
    final Finder forceCreate = _enabledButton(const ValueKey<String>('customer-new-create'));
    await pumpUntilFound(tester, forceCreate, timeout: const Duration(seconds: 30));
    await _tap(tester, forceCreate);
    await pumpUntilTrue(
      tester,
      () =>
          find.byKey(_newCustomerRoot).evaluate().isEmpty ||
          find.byKey(const ValueKey<String>('customer-new-stale')).evaluate().isNotEmpty,
      what: 'SCR-26: клиент создан',
      timeout: const Duration(seconds: 60),
    );
    // `201` с `STALE_DATA` (UI-26-016): экран остаётся с баннером — закрытие возвращает созданного клиента.
    if (find.byKey(const ValueKey<String>('customer-new-stale')).evaluate().isNotEmpty) {
      await _tap(tester, find.byKey(const ValueKey<String>('customer-new-close')));
      await pumpUntilTrue(tester, () => find.byKey(_newCustomerRoot).evaluate().isEmpty, what: 'SCR-26 закрыт');
    }
    final Map<String, Object?> both = await _api(tester, '/customers', <String, Object?>{'q': _noDebtPhone});
    expect(
      both['items']! as List<Object?>,
      hasLength(2),
      reason: '«Всё равно создать» — вторая карточка (forceReason)',
    );
    debugPrint('cashier_flow_test: FLOW-029.A2 — «Всё равно создать» с причиной');

    // Новый клиент из оформления: корзина → SCR-21 → «+ Новый клиент» → SCR-26 → клиент выбран в заказе.
    final List<_Sku> more = await _sellable(tester, 1, skip: 1);
    await _addFromCatalog(tester, more.single);
    await _openCartWith(tester, more);
    await _toCheckout(tester);
    final Finder newCustomer = find.byKey(const ValueKey<String>('customer-picker-new'));
    await pumpUntilFound(tester, newCustomer, timeout: const Duration(seconds: 30));
    await _tap(tester, newCustomer);
    await pumpUntilFound(tester, find.byKey(_newCustomerRoot));
    await _settle(tester);
    await tester.enterText(_input(const ValueKey<String>('customer-new-phone')), '555777002');
    await tester.pump();
    await tester.enterText(_input(const ValueKey<String>('customer-new-name')), 'Тестов Новый Клиент');
    await tester.pump();
    final Finder create = _enabledButton(const ValueKey<String>('customer-new-create'));
    await pumpUntilFound(tester, create, timeout: const Duration(seconds: 30));
    await _tap(tester, create);
    await pumpUntilFound(tester, find.byKey(_checkoutRoot), timeout: const Duration(seconds: 30));
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('checkout-customer-card')),
      timeout: const Duration(seconds: 30),
    );
    final Map<String, Object?> created = await _api(tester, '/customers', <String, Object?>{'q': '+996555777002'});
    expect(created['items']! as List<Object?>, isNotEmpty, reason: 'клиент создан (POST /customers)');
    debugPrint('cashier_flow_test: SCR-26 из оформления — клиент создан и выбран в заказе');

    // Возврат: заказ «отгружен» (стенд) → SCR-24 «Заявка на возврат» → SCR-39 → сохранить → отправить (step-up).
    _w.returnId = await _submitReturn(tester, orderId);
    debugPrint('cashier_flow_test: SCR-39 — заявка на возврат отправлена (step-up)');
    // Вторая заявка — по заказу в долг FLOW-023 (решение старшего — «Отклонить», FLOW-031.A4).
    _w.rejectReturnId = await _submitReturn(tester, withinLimit);
    debugPrint('cashier_flow_test: SCR-39 — вторая заявка отправлена (для отклонения старшим)');

    // T-DEBT-013 / CASH-015: финансовых данных клиента нет ни в drift (файлы APP_DATA_DIR), ни в secure storage.
    final Map<String, Object?> debt = await _api(tester, '/customers/$overdueId/receivables');
    expect(debt['balance'], isNotNull, reason: 'снимок долга есть на сервере');
    final Map<String, Object?> card = await _api(tester, '/customers/$overdueId');
    final List<String> forbidden = <String>[
      '"overdueAmount"',
      '"limitRemaining"',
      '"creditLimit"',
      '700223344',
      if (card['displayName'] ?? card['name'] case final String name when name.length > 3) name,
    ];
    final String? root = AppConfig.fromEnvironment().appDataDir;
    expect(root, isNotNull, reason: 'APP_DATA_DIR задан (env/local.json)');
    final List<String> leaks =
        await tester.runAsync(() async {
          final List<String> found = <String>[];
          await for (final FileSystemEntity e in Directory(root!).list(recursive: true)) {
            if (e is! File) continue;
            final String text = utf8.decode(await e.readAsBytes(), allowMalformed: true);
            for (final String f in forbidden) {
              if (text.contains(f)) found.add('${e.path}: ${f.startsWith('"') ? f : '<ПДн клиента>'}');
            }
          }
          final FlutterSecureStorageAdapter secure = FlutterSecureStorageAdapter();
          for (final SecureKey k in SecureKey.values) {
            final String? v = await secure.read(k);
            if (v == null) continue;
            for (final String f in forbidden) {
              if (v.contains(f)) found.add('secure:${k.storageKey}: ${f.startsWith('"') ? f : '<ПДн клиента>'}');
            }
          }
          return found;
        }) ??
        const <String>[];
    expect(leaks, isEmpty, reason: 'финансы и ПДн клиента не хранятся на устройстве (CASH-015, 07 §11.1 п. 5)');
    debugPrint('cashier_flow_test: финансов клиента нет ни в drift, ни в secure storage');

    // FLOW-026 «Отмена заказа» (01 GEN-005; AC-FLOW-026-01, -02, -06; G-trace-8, R2-N-01).
    // AC-FLOW-026-06: у отгруженного заказа (заявка на возврат выше) «Отменить заказ» нет.
    _router(tester)!.go('/orders/$orderId');
    await pumpUntilFound(tester, find.byKey(_orderRoot), timeout: const Duration(seconds: 60));
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('order-actions')),
      timeout: const Duration(seconds: 30),
    );
    expect(find.byKey(const ValueKey<String>('action-cancel')), findsNothing, reason: 'shipped — отмена скрыта');
    // S1–S3: свой заказ за наличные без полученных денег (FLOW-025: создан при недоступной 1С, платёж `cash_pending`)
    // — «Отменить заказ» без step-up. Документ 1С создаётся повтором outbox (пауза 1 мин после 503): если он уже есть —
    // запрос отмены в 1С («Запрос отмены отправлен в 1С» → «Отменён» по ответу 1С), если нет — немедленная отмена.
    final DateTime createdDeadline = DateTime.now().add(const Duration(seconds: 150));
    String staleStatus = (await _api(tester, '/orders/$staleCashOrder'))['status']! as String;
    while (staleStatus == 'submitting' && DateTime.now().isBefore(createdDeadline)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
      await tester.pump();
      staleStatus = (await _api(tester, '/orders/$staleCashOrder'))['status']! as String;
    }
    final bool immediate = await _cancelOrder(tester, staleCashOrder, stepUp: false);
    final Map<String, Object?> staleCancelled = await _api(tester, '/orders/$staleCashOrder');
    final List<Object?> stalePayments = staleCancelled['payments'] as List<Object?>? ?? const <Object?>[];
    expect(
      stalePayments.whereType<Map<String, Object?>>().where((Map<String, Object?> p) => p['status'] == 'received'),
      isEmpty,
      reason: 'неполученный платёж не стал полученным',
    );
    debugPrint(
      'cashier_flow_test: FLOW-026.S2/S3 — свой заказ ($staleStatus) отменён без step-up '
      '(${immediate ? 'немедленно' : 'запрос отмены в 1С → «Отменён»'})',
    );
    // S4–S5: заказ с полученной оплатой (FLOW-022, QR подтверждён вручную) — «Запросить отмену» → причина +
    // «Деньги: вернуть» → 403 STEP_UP_REQUIRED → StepUpDialog (PIN) → `cancelRequested` → ответ 1С → «Отменён»;
    // платёж `received` не меняется (ядро §22.2), аудит `order.cancel_requested` с причиной.
    expect(await _cancelOrder(tester, qrOrderId, stepUp: true), isFalse);
    _w.cancelRequestedOrderId = qrOrderId;
    final Map<String, Object?> qrCancelled = await _api(tester, '/orders/$qrOrderId');
    final List<Object?> qrCancelledPayments = qrCancelled['payments'] as List<Object?>? ?? const <Object?>[];
    expect(
      qrCancelledPayments.whereType<Map<String, Object?>>().any(
        (Map<String, Object?> p) => p['method'] == 'qr_bakai' && p['status'] == 'received',
      ),
      isTrue,
      reason: 'полученный платёж остаётся received (возврат денег — документом 1С)',
    );
    debugPrint('cashier_flow_test: FLOW-026.S4/S5 — оплаченный заказ: запрос отмены со step-up → «Отменён»');
  });

  testWidgets(
    'RM-G-009 старший продавец (T-CASH-010, T-CASH-012, T-RET-015, AC-UI-21-013): SCR-21 CustomerPicker (поиск) → '
    'клиент с просрочкой → «Разрешить продажу в долг» (причина + step-up) → заказ в долг; SCR-39 «Согласовать» '
    '(step-up) → accepted; FLOW-031.A4 «Отклонить» (причина + step-up) → rejected',
    (tester) async {
      expect(_w.overdueId, isNotNull, reason: 'сценарий кассира выполнен');
      await _staffFirstLogin(tester, _seniorPhone, _seniorPin, home: _catalogRoot);
      await _waitCatalogCache(tester);
      final List<_Sku> items = await _sellable(tester, 1, skip: 2);
      await _addFromCatalog(tester, items.single);
      await _openCartWith(tester, items);
      await _toCheckout(tester);

      // CustomerPicker SCR-21 — реальный поиск `GET /customers` (RM-G-001).
      final Finder picker = _input(const ValueKey<String>('customer-picker-field'));
      await pumpUntilFound(tester, picker, timeout: const Duration(seconds: 30));
      await tester.enterText(picker, _overdueQuery);
      await tester.pump();
      final Finder pick = find.byKey(ValueKey<String>('customer-picker-row-${_w.overdueId}'));
      await pumpUntilFound(tester, pick, timeout: const Duration(seconds: 30));
      await _tap(tester, pick);
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('checkout-customer-card')),
        timeout: const Duration(seconds: 30),
      );
      await _pickup(tester);
      await _payment(tester, 'credit');
      final Finder approve = _enabledButton(const ValueKey<String>('checkout-credit-approve'));
      await pumpUntilFound(tester, approve, timeout: const Duration(seconds: 60));
      // Предпроверка «В долг» завершена (решение по причине отказа — по её ответу).
      await pumpUntilTrue(
        tester,
        () => !_container(
          tester,
        ).read(checkoutControllerProvider(Uri.parse(_where(tester)).queryParameters['cartId'])).previewing,
        what: 'предпроверка SCR-21 завершена',
      );
      await _tap(tester, approve);
      await _confirm(tester, reason: 'Согласовано с руководителем');
      await _stepUp(tester, _seniorPin);
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('checkout-credit-allowed-by')),
        timeout: const Duration(seconds: 60),
      );
      final String creditOrder = await _createOrder(tester);
      _w.creditOrderId = creditOrder;
      final Map<String, Object?> order = await _api(tester, '/orders/$creditOrder');
      expect(order['paymentMethod'], 'credit', reason: 'заказ в долг по разрешению старшего');
      debugPrint('cashier_flow_test: разрешение старшего (step-up) — заказ в долг создан');

      // Решение по заявке кассира: «Согласовать» (step-up) → accepted.
      final String? returnId = _w.returnId;
      expect(returnId, isNotNull, reason: 'заявка кассира отправлена');
      _router(tester)!.go('/returns/$returnId');
      await pumpUntilFound(tester, find.byKey(_returnRoot), timeout: const Duration(seconds: 30));
      final Finder accept = _enabledButton(const ValueKey<String>('return-accept'));
      await pumpUntilFound(tester, accept, timeout: const Duration(seconds: 30));
      await _tap(tester, accept);
      if (find.byType(ConfirmDialog).evaluate().isNotEmpty) await _confirm(tester);
      await _stepUp(tester, _seniorPin);
      await pumpUntil<bool>(
        tester,
        () async => (await _apiMap(tester, '/returns/$returnId'))['status'] == 'accepted' ? true : null,
        what: 'заявка согласована (accepted)',
      );
      debugPrint('cashier_flow_test: SCR-39 — заявка согласована старшим (step-up)');

      // FLOW-031.A4 «Отклонить» (AC-FLOW-031-07): вторая заявка кассира → SCR-39 «Отклонить» (причина обязательна) →
      // step-up → `rejected`; статус заявки на экране — «Отклонена» с причиной.
      final String? rejectId = _w.rejectReturnId;
      expect(rejectId, isNotNull, reason: 'вторая заявка кассира отправлена');
      // Сначала уйти с SCR-39 согласованной заявки (у `accepted` тоже есть «Отклонить» — не перепутать экраны).
      _router(tester)!.go('/catalog');
      await pumpUntilTrue(tester, () => find.byKey(_returnRoot).evaluate().isEmpty, what: 'SCR-39 закрыт');
      await _settle(tester);
      _router(tester)!.go('/returns/$rejectId');
      await pumpUntilFound(tester, find.byKey(_returnRoot), timeout: const Duration(seconds: 30));
      final Finder reject = _enabledButton(const ValueKey<String>('return-reject'));
      await pumpUntilFound(tester, reject, timeout: const Duration(seconds: 30));
      await _tap(tester, reject);
      await _confirm(tester, reason: 'Товар без следов брака');
      await _stepUpUnlessDone(
        tester,
        _seniorPin,
        () async => (await _apiMap(tester, '/returns/$rejectId'))['status'] == 'rejected',
        what: 'StepUpDialog или заявка отклонена',
      );
      await pumpUntil<bool>(
        tester,
        () async => (await _apiMap(tester, '/returns/$rejectId'))['status'] == 'rejected' ? true : null,
        what: 'заявка отклонена (rejected)',
      );
      await pumpUntilTrue(
        tester,
        () => _enabledButton(const ValueKey<String>('return-reject')).evaluate().isEmpty,
        what: 'SCR-39: действий решения по отклонённой заявке нет',
      );
      debugPrint('cashier_flow_test: SCR-39 — заявка отклонена старшим (step-up)');
    },
  );

  testWidgets('RM-G-009 администратор (T-ADMIN-001, T-SEC-038, T-SEC-067, AC-UI-21-013, AC-UI-32-005): SCR-47 — аудит '
      'credit.sale_approved по заказу в долг, customer.debt_viewed по карточке, order.cancel_requested (FLOW-026.S4)', (
    tester,
  ) async {
    expect(_w.creditOrderId, isNotNull, reason: 'заказ в долг создан старшим');
    await _staffFirstLogin(tester, _adminPhone, _adminPin, home: _catalogRoot);
    _router(tester)!.go(
      Uri(
        path: '/admin/audit',
        queryParameters: <String, String>{
          'action': 'credit.sale_approved',
          'entityType': 'order',
          'entityId': _w.creditOrderId!,
        },
      ).toString(),
    );
    await pumpUntilFound(tester, find.byKey(_auditRoot), timeout: const Duration(seconds: 30));
    await pumpUntilFound(tester, _keyPrefix('audit-row-'), timeout: const Duration(seconds: 60));
    debugPrint('cashier_flow_test: SCR-47 — запись credit.sale_approved видна администратору');
    // AC-UI-32-005: открытие карточки с суммами (кассир, SCR-32) записано в аудит `customer.debt_viewed`.
    _router(tester)!.go(
      Uri(
        path: '/admin/audit',
        queryParameters: <String, String>{'action': 'customer.debt_viewed', 'entityId': _w.overdueId!},
      ).toString(),
    );
    await pumpUntilFound(tester, find.byKey(_auditRoot), timeout: const Duration(seconds: 30));
    await pumpUntilFound(tester, _keyPrefix('audit-row-'), timeout: const Duration(seconds: 60));
    debugPrint('cashier_flow_test: SCR-47 — customer.debt_viewed по карточке клиента виден');
    // AC-FLOW-026-02: запрос отмены оплаченного заказа кассиром (step-up) записан в аудит `order.cancel_requested`.
    expect(_w.cancelRequestedOrderId, isNotNull, reason: 'кассир запросил отмену оплаченного заказа (FLOW-026.S4)');
    _router(tester)!.go(
      Uri(
        path: '/admin/audit',
        queryParameters: <String, String>{
          'action': 'order.cancel_requested',
          'entityType': 'order',
          'entityId': _w.cancelRequestedOrderId!,
        },
      ).toString(),
    );
    await pumpUntilFound(tester, find.byKey(_auditRoot), timeout: const Duration(seconds: 30));
    await pumpUntilFound(tester, _keyPrefix('audit-row-'), timeout: const Duration(seconds: 60));
    debugPrint('cashier_flow_test: SCR-47 — order.cancel_requested по оплаченному заказу виден');
  });

  testWidgets('RM-G-012 руководитель (owner): главный экран SCR-48 — отчёт за сегодня с данными', (tester) async {
    await _staffFirstLogin(tester, _ownerPhone, _ownerPin, home: _reportsRoot);
    expect(_where(tester), startsWith('/reports'));
    await pumpUntilFound(tester, _keyPrefix('reports-card-'), timeout: const Duration(seconds: 60));
    // Кассовых действий у owner нет (D-15): касса только просмотр, корзины нет.
    _router(tester)!.go('/cart');
    await _settle(tester);
    expect(_where(tester), isNot('/cart'));
    debugPrint('cashier_flow_test: SCR-48 — отчёт руководителя открыт');
  });

  testWidgets(
    'RM-G-014 клиент (T-CUST-014, CUST-025): свой долг SCR-34 закрыт до `confirmed`; SCR-06 «Это я» → долг виден',
    (tester) async {
      final String? own = _w.buyerCustomerId;
      expect(own, isNotNull, reason: 'ID карточки покупателя получен кассиром');
      await _cleanStart(tester);
      await _phoneAndOtp(tester, _buyerPhone);
      await pumpUntilFound(tester, find.byKey(RegistrationFormScreen.screenKey), timeout: const Duration(seconds: 60));
      await _settle(tester);
      await tester.enterText(_input(RegistrationFormScreen.nameFieldKey), 'Асанов Бакыт');
      await tester.pump();
      await tester.enterText(_input(RegistrationFormScreen.yearFieldKey), '1985');
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

      // SCR-06: предложенная карточка (привязка `proposed`, решение — позже).
      await pumpUntilFound(
        tester,
        find.byWidgetPredicate(
          (Widget w) =>
              w.key == CustomerLinkScreen.confirmKey ||
              w.key == CustomerLinkScreen.continueKey ||
              w.key == CustomerHomeKeys.root,
        ),
        timeout: const Duration(seconds: 60),
      );
      final Map<String, Object?> me = await _api(tester, '/me');
      expect((me['customerLink'] as Map<String, Object?>?)?['status'], 'proposed');

      // До подтверждения свой долг закрыт: экран привязки, без запроса долга.
      _router(tester)!.go('/customers/$own/receivables');
      await pumpUntilFound(tester, find.byKey(_receivablesRoot), timeout: const Duration(seconds: 30));
      await pumpUntilFound(
        tester,
        find.byWidgetPredicate(
          (Widget w) =>
              w.key == const ValueKey<String>('customer-self-not-linked') ||
              w.key == const ValueKey<String>('customer-self-link-status'),
        ),
      );
      expect(find.byKey(const ValueKey<String>('debt-summary-balance')), findsNothing);

      // SCR-06 «Это я» → `confirmed` → свой долг виден (только память сессии).
      _router(tester)!.go('/register/customer-link');
      final Finder confirm = _enabledButton(CustomerLinkScreen.confirmKey);
      await pumpUntilFound(tester, confirm, timeout: const Duration(seconds: 30));
      // Переход со SCR-34 завершён (кнопка не перестраивается анимацией маршрута).
      await pumpUntilTrue(tester, () => find.byKey(_receivablesRoot).evaluate().isEmpty, what: 'SCR-34 закрыт');
      await _settle(tester);
      await pumpUntilFound(tester, confirm);
      await _tap(tester, confirm);
      await pumpUntil<bool>(
        tester,
        () async => ((await _apiMap(tester, '/me'))['customerLink'] as Map<String, Object?>?)?['status'] == 'confirmed'
            ? true
            : null,
        what: 'привязка подтверждена (confirmed)',
      );
      // Гейт SCR-32…35 перечитывает `GET /me` при входе на экран (привязка изменилась на SCR-06).
      _router(tester)!.go('/customers/$own/receivables');
      await pumpUntilFound(tester, find.byKey(_receivablesRoot), timeout: const Duration(seconds: 30));
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('debt-summary-balance')),
        timeout: const Duration(seconds: 60),
      );
      debugPrint('cashier_flow_test: клиент — свой долг виден только после подтверждения привязки');
    },
  );
}
