// SCR-36 «Транзакции» (02 SCR-36.13; 13 RM-G-007, RM-G-012): период по умолчанию «Сегодня» (AC-UI-36-001),
// фильтры по отдельности и вместе, чипы с ✕ (AC-UI-36-002), «Только мои» у `seller` без ✕ и без итога (AC-UI-36-005),
// операции 1С без автора (AC-UI-36-006), период > 366 дней (AC-UI-36-007), фильтры в URL (AC-UI-36-008), курсор без
// дублей и «Показаны все операции за период» (AC-UI-36-010), нет экспорта CSV (AC-UI-36-011), пусто (AC-UI-36-012),
// без сети (AC-UI-36-013), итог из `summary` (AC-UI-36-014), «Ошибка отправки в 1С» (AC-UI-36-016).
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/transaction.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/date_range_picker.dart';
import 'package:optomstroy/features/transactions/domain/entities/transactions_query.dart';
import 'package:optomstroy/features/transactions/presentation/screens/transactions_screen.dart';

import '../../cashier/support/cashier_harness.dart';

const Size _compact = Size(390, 844);

const TransactionsSummary _sum = TransactionsSummary(count: 3, sumIn: Money(3201500), sumOut: Money(235000));

CashierHarness _h({RoleCode role = RoleCode.cashier, bool online = true}) {
  final CashierHarness h = CashierHarness(role: role, online: online);
  h.transactions.onList = (TransactionsQuery q) async => Success<TransactionsPage>(
    txPage(<Transaction>[
      tx('t1', at: DateTime.utc(2026, 10, 22, 4, 10)),
      tx(
        't2',
        kind: TransactionKind.paymentVoided,
        sign: TransactionSign.minus,
        group: TransactionStatusGroup.voided,
        tyiyn: 235000,
        number: '1025',
        at: DateTime.utc(2026, 10, 22, 3),
      ),
      tx(
        't3',
        kind: TransactionKind.orderCreated,
        group: TransactionStatusGroup.onecError,
        number: '1023',
        source: TransactionSource.onec,
        at: DateTime.utc(2026, 10, 21, 9),
      ),
    ], summary: role == RoleCode.seller ? null : _sum),
  );
  return h;
}

Widget _screen(GoRouterState s) => TransactionsScreen(
  from: s.uri.queryParameters['from'],
  to: s.uri.queryParameters['to'],
  customerId: s.uri.queryParameters['customerId'],
  status: s.uri.queryParameters['status'],
  kind: s.uri.queryParameters['kind'],
  paymentMethod: s.uri.queryParameters['paymentMethod'],
  actorId: s.uri.queryParameters['actorId'],
  q: s.uri.queryParameters['q'],
  mine: s.uri.queryParameters['mine'],
);

void main() {
  testWidgets('по умолчанию — «Сегодня» Бишкека, строки с заголовками дней, итог `summary` (AC-UI-36-001, -014)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h();
    await h.pump(t, const TransactionsScreen());
    expect(find.byKey(TransactionsScreen.rootKey), findsOneWidget);
    final TransactionsQuery q = h.transactions.queries.single;
    expect(q.period.from, DateTime.utc(2026, 10, 21, 18));
    expect(q.period.to, DateTime.utc(2026, 10, 22, 17, 59, 59, 999));
    expect(q.mine, isFalse);
    expect(q.sort, TransactionsSort.occurredAtDesc);
    expect(find.byKey(const ValueKey<String>('tx-table')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('tx-summary')), findsOneWidget);
    expect(find.textContaining('+${fmt(3201500)}', findRichText: true), findsOneWidget);
    expect(find.text('Операций: 3'), findsOneWidget);
    expect(find.text('Ошибка отправки в 1С'), findsWidgets);
    expect(find.textContaining('CSV'), findsNothing);
  });

  testWidgets('строки compact: знак суммы в тексте, операция 1С — «1С» без автора (AC-UI-36-003, -006)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h();
    await h.pump(t, const TransactionsScreen(), size: _compact);
    expect(find.text('Сегодня'), findsOneWidget);
    expect(find.text('Вчера'), findsOneWidget);
    expect(find.text('+${fmt(1600750)}'), findsWidgets);
    expect(find.text('−${fmt(235000)}'), findsOneWidget);
    expect(find.text('10:10 · Абдулла'), findsOneWidget);
    expect(find.text('15:00 · 1С'), findsOneWidget);
  });

  testWidgets('seller: «Только мои» без ✕, mine=true в запросе, итог не показывается (AC-UI-36-005)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h(role: RoleCode.seller);
    await h.pump(t, const TransactionsScreen(), size: _compact);
    expect(h.transactions.queries.single.mine, isTrue);
    expect(find.byKey(const ValueKey<String>('tx-chip-mine-fixed')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('tx-chip-mine')), findsNothing);
    expect(find.byKey(const ValueKey<String>('tx-summary')), findsNothing);
  });

  testWidgets('фильтры из URL — чипы; ✕ снимает фильтр и перезапрашивает; фильтры уходят в URL (AC-UI-36-002, -008)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h();
    await h.pumpRouter(t, '/transactions', _screen, size: _compact);
    await t.pump();
    final GoRouter router = GoRouter.of(t.element(find.byType(TransactionsScreen)));
    router.go('/transactions?status=received,pending&kind=refund&paymentMethod=cash');
    await CashierHarness.settle(t);
    final TransactionsQuery q = h.transactions.queries.last;
    expect(q.statuses, <TransactionStatusGroup>{TransactionStatusGroup.received, TransactionStatusGroup.pending});
    expect(q.kinds, <TransactionKind>{TransactionKind.refund});
    expect(q.paymentMethod, PaymentMethod.cash);
    expect(find.byKey(const ValueKey<String>('tx-chip-status-received')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('tx-chip-kind-refund')), findsOneWidget);
    expect(find.text('Фильтры · 4'), findsOneWidget);
    final Finder remove = find.descendant(
      of: find.byKey(const ValueKey<String>('tx-chip-kind-refund')),
      matching: find.byIcon(Icons.close_rounded),
    );
    await t.ensureVisible(remove.first);
    await t.pump();
    await t.tap(remove.first);
    await CashierHarness.settle(t);
    expect(h.transactions.queries.last.kinds, isEmpty);
    final Uri at = router.routeInformationProvider.value.uri;
    expect(at.queryParameters['status'], 'received,pending');
    expect(at.queryParameters.containsKey('kind'), isFalse);
    expect(at.queryParameters['from'], isNotNull);
  });

  testWidgets('период > 366 дней в URL — «Сегодня» и сообщение (AC-UI-36-007)', (WidgetTester t) async {
    final CashierHarness h = _h();
    await h.pump(
      t,
      TransactionsScreen(
        from: DateTime.utc(2025, 1, 1).toIso8601String(),
        to: DateTime.utc(2026, 10, 1).toIso8601String(),
      ),
    );
    expect(find.byKey(const ValueKey<String>('tx-period-rejected')), findsOneWidget);
    expect(find.text('Период больше 366 дней'), findsOneWidget);
    expect(h.transactions.queries.single.period.from, DateTime.utc(2026, 10, 21, 18));
  });

  testWidgets('курсор: подгрузка без дублей и «Показаны все операции за период» (AC-UI-36-010)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = CashierHarness();
    h.transactions.onList = (TransactionsQuery q) async => Success<TransactionsPage>(
      q.cursor == null
          ? txPage(<Transaction>[
              for (int i = 0; i < 12; i++) tx('a$i', number: '${2000 + i}', at: DateTime.utc(2026, 10, 22, 4, 20 - i)),
            ], next: 'c2')
          : txPage(<Transaction>[tx('a11', number: '2011'), tx('b1', number: '3001')]),
    );
    await h.pump(t, const TransactionsScreen(), size: _compact);
    await t.drag(find.byKey(const ValueKey<String>('tx-list')), const Offset(0, -2000));
    await CashierHarness.settle(t);
    expect(h.transactions.queries.last.cursor, 'c2');
    await t.drag(find.byKey(const ValueKey<String>('tx-list')), const Offset(0, -2000));
    await CashierHarness.settle(t);
    expect(find.byKey(const ValueKey<String>('tx-row-a11')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('tx-row-b1')), findsOneWidget);
    expect(find.text('Показаны все операции за период'), findsOneWidget);
  });

  testWidgets('пусто — «Операций за период нет» с «Период…» и «Сбросить всё» (AC-UI-36-012)', (WidgetTester t) async {
    final CashierHarness h = CashierHarness();
    h.transactions.onList = (TransactionsQuery q) async => Success<TransactionsPage>(txPage(const <Transaction>[]));
    await h.pump(t, const TransactionsScreen(kind: 'refund'));
    expect(find.byKey(const ValueKey<String>('tx-empty')), findsOneWidget);
    expect(find.text('Операций за период нет'), findsOneWidget);
    expect(find.text('Период…'), findsOneWidget);
    expect(find.text('Сбросить всё'), findsWidgets);
  });

  testWidgets('ошибка — ErrorState с «Повторить»; без сети и без данных — «Журнал операций недоступен без сети»', (
    WidgetTester t,
  ) async {
    final CashierHarness err = CashierHarness();
    err.transactions.onList = (TransactionsQuery q) async =>
        const FailureResult<TransactionsPage>(ServerFailure(code: 'INTERNAL', status: 500));
    await err.pump(t, const TransactionsScreen());
    expect(find.text('Повторить'), findsOneWidget);

    final CashierHarness off = CashierHarness(online: false);
    off.transactions.onList = (TransactionsQuery q) async =>
        const FailureResult<TransactionsPage>(NetworkFailure(NetworkFailureKind.offline));
    await off.pump(t, const TransactionsScreen());
    expect(find.byKey(const ValueKey<String>('tx-offline')), findsOneWidget);
    expect(find.text('Журнал операций недоступен без сети'), findsOneWidget);
  });

  testWidgets('без сети при загруженном списке — данные остаются с меткой времени (AC-UI-36-013)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h();
    await h.pump(t, const TransactionsScreen());
    h.transactions.onList = (TransactionsQuery q) async =>
        const FailureResult<TransactionsPage>(NetworkFailure(NetworkFailureKind.offline));
    await t.sendKeyEvent(LogicalKeyboardKey.f5);
    await CashierHarness.settle(t);
    expect(find.text('Нет сети. Показаны данные от 10:30'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('tx-row-t1')), findsOneWidget);
  });

  testWidgets('expanded: постоянная панель фильтров, применение сразу; сортировка по «Сумма»', (WidgetTester t) async {
    final CashierHarness h = _h();
    await h.pump(t, const TransactionsScreen());
    expect(find.byKey(const ValueKey<String>('tx-filter-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('tx-table')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey<String>('tx-filter-status-onec_error')));
    await t.pump(const Duration(milliseconds: 350));
    await CashierHarness.settle(t);
    expect(h.transactions.queries.last.statuses, <TransactionStatusGroup>{TransactionStatusGroup.onecError});
    await t.tap(find.byKey(const ValueKey<String>('tx-sort-amountDesc')));
    await CashierHarness.settle(t);
    expect(h.transactions.queries.last.sort, TransactionsSort.amountDesc);
  });

  testWidgets('AC-UI-36-015: поиск по номеру POS/1С (ввод или HID-скан с Enter) сочетается с фильтром статуса; q — в '
      'запросе и URL', (WidgetTester t) async {
    final CashierHarness h = _h();
    await h.pumpRouter(t, '/transactions', _screen);
    await t.pump();
    final GoRouter router = GoRouter.of(t.element(find.byType(TransactionsScreen)));
    router.go('/transactions?status=received');
    await CashierHarness.settle(t);
    final Finder field = find.descendant(
      of: find.byKey(const ValueKey<String>('tx-search-number')),
      matching: find.byType(EditableText),
    );
    await t.enterText(field, 'POS-2026-000123');
    await t.pump(const Duration(milliseconds: 350));
    await CashierHarness.settle(t);
    expect(h.transactions.queries.last.q, 'POS-2026-000123');
    expect(h.transactions.queries.last.statuses, <TransactionStatusGroup>{TransactionStatusGroup.received});
    expect(router.routeInformationProvider.value.uri.queryParameters['q'], 'POS-2026-000123');

    // HID-сканер вводит номер 1С и Enter — запрос сразу, без ожидания debounce.
    final int before = h.transactions.queries.length;
    await t.enterText(field, 'УТ-0001230');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await CashierHarness.settle(t);
    expect(h.transactions.queries.length, greaterThan(before));
    expect(h.transactions.queries.last.q, 'УТ-0001230');
    expect(h.transactions.queries.last.statuses, <TransactionStatusGroup>{TransactionStatusGroup.received});
  });

  testWidgets('compact: лист фильтров копит изменения до «Применить»', (WidgetTester t) async {
    final CashierHarness h = _h();
    await h.pump(t, const TransactionsScreen(), size: _compact);
    await t.tap(find.byKey(const ValueKey<String>('tx-filters-button')));
    await CashierHarness.settle(t);
    await t.ensureVisible(find.byKey(const ValueKey<String>('tx-filter-kind-payment_received')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey<String>('tx-filter-kind-payment_received')));
    await CashierHarness.settle(t);
    expect(h.transactions.queries, hasLength(1));
    await t.tap(find.text('Применить'));
    await CashierHarness.settle(t);
    expect(h.transactions.queries.last.kinds, <TransactionKind>{TransactionKind.paymentReceived});
  });

  testWidgets('фильтр «Сотрудник» — только admin/owner', (WidgetTester t) async {
    final CashierHarness admin = _h(role: RoleCode.admin);
    await admin.pump(t, const TransactionsScreen(actorId: 'u7'));
    expect(find.byKey(const ValueKey<String>('tx-filter-actor-selected')), findsOneWidget);
    expect(admin.transactions.queries.single.actorId, 'u7');

    final CashierHarness cashier = _h();
    await cashier.pump(t, const TransactionsScreen());
    expect(find.text('Сотрудник'), findsNothing);
  });

  testWidgets('тап по строке → SCR-37 (`/transactions/{id}`)', (WidgetTester t) async {
    final CashierHarness h = _h();
    await h.pumpRouter(t, '/transactions', _screen, size: _compact);
    await t.tap(find.byKey(const ValueKey<String>('tx-row-t2')));
    await CashierHarness.settle(t);
    expect(h.visited.last, '/transactions/t2');
  });

  testWidgets('DateRangePicker: 366 дней — «Применить» активна, 367 — недоступна с ошибкой (DS-092)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h();
    DateRangeValue? applied;
    Future<void> show(DateTime from, DateTime to) async {
      await t.pumpWidget(
        h.app(
          Scaffold(
            body: DateRangePickerPanel(
              key: ValueKey<DateTime>(from),
              initial: DateRangeValue(fromUtc: from, toUtc: to),
              nowUtc: kNow,
              labels: const DateRangePickerLabels(
                presets: <DateRangePreset, String>{DateRangePreset.today: 'Сегодня'},
                from: 'от',
                to: 'до',
                apply: 'Применить',
                cancel: 'Отмена',
                tooLong: 'Период больше 366 дней',
                invalid: 'Неверный период',
              ),
              onApply: (DateRangeValue v) => applied = v,
            ),
          ),
        ),
      );
      await t.pump();
    }

    final DateTime end = DsBishkekTime.endOfDayUtc(kNow);
    final DateTime start366 = DsBishkekTime.startOfDayUtc(kNow).subtract(const Duration(days: 365));
    await show(start366, end);
    expect(find.byKey(const ValueKey<String>('date-range-error')), findsNothing);
    await t.tap(find.byKey(const ValueKey<String>('date-range-apply')));
    expect(applied?.days, 366);

    applied = null;
    await show(start366.subtract(const Duration(days: 1)), end);
    expect(find.text('Период больше 366 дней'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey<String>('date-range-apply')));
    expect(applied, isNull);
  });
}
