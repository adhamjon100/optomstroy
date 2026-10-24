// Отмена устаревших запросов (06 §6.7 CancelToken, D-31; 02 SCR-31.11 «двойной запрос поиска исключён отменой
// предыдущего», SCR-33.11; ревью G-flutter-data-3): новый поиск/фильтр/период отменяет HTTP-запрос предыдущего, уход
// с экрана — текущий; отменённый ответ пользователю как ошибка не показывается.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_history.dart';
import 'package:optomstroy/features/customers/domain/repositories/customer_directory_repository.dart';
import 'package:optomstroy/features/customers/domain/repositories/customers_repository.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_history_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customers_search_screen.dart';
import 'package:optomstroy/features/customers/presentation/state/customer_history_controller.dart';
import 'package:optomstroy/features/customers/presentation/state/customers_search_controller.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_history_view.dart';

import '../support/customers_harness.dart';

void main() {
  testWidgets('SCR-31: новый ввод отменяет запрос предыдущего; уход с экрана — текущий; отмена — не ошибка', (
    WidgetTester tester,
  ) async {
    final CustomersHarness h = CustomersHarness();
    final List<Completer<Result<PageResult<Customer>>>> pending = <Completer<Result<PageResult<Customer>>>>[];
    h.search.onSearch = (CustomerSearchQuery q) {
      final Completer<Result<PageResult<Customer>>> c = Completer<Result<PageResult<Customer>>>();
      pending.add(c);
      return c.future;
    };
    await h.pump(tester, const CustomersSearchScreen());
    await tester.enterText(find.byType(EditableText), 'Азамат');
    await settle(tester, frames: 10);
    expect(h.search.calls, hasLength(1));
    await tester.enterText(find.byType(EditableText), 'Бакыт');
    await settle(tester, frames: 10);
    expect(h.search.calls, hasLength(2));
    expect(h.search.cancels[0]!.isCancelled, isTrue, reason: 'запрос «Азамат» отменён новым вводом');
    expect(h.search.cancels[1]!.isCancelled, isFalse);

    // Отменённый ответ (dio → UnknownFailure) отбрасывается: ошибки на экране нет.
    pending[0].complete(const FailureResult<PageResult<Customer>>(UnknownFailure(cause: 'cancel')));
    await settle(tester);
    expect(findText('Повторить'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(h.search.cancels[1]!.isCancelled, isTrue, reason: 'уход с экрана отменяет текущий запрос');
  });

  testWidgets('SCR-31: смена фильтра отменяет запрос списка предыдущего фильтра', (WidgetTester tester) async {
    final CustomersHarness h = CustomersHarness();
    h.directory.onList = (CustomersListQuery q) => Completer<Result<PageResult<Customer>>>().future;
    await h.pump(tester, const CustomersSearchScreen());
    // По умолчанию — «Избранные» (запрос списка висит); выбор «С долгом» отменяет его.
    expect(h.directory.listCalls, hasLength(1));
    await tapVisible(tester, find.byKey(CustomersSearchKeys.filter(CustomersFilter.debt)));
    await settle(tester);
    expect(h.directory.listCalls, hasLength(2));
    expect(h.directory.listCalls.last.hasDebt, isTrue);
    expect(h.directory.listCancels.first!.isCancelled, isTrue);
    expect(h.directory.listCancels.last!.isCancelled, isFalse);
  });

  testWidgets('SCR-33: смена периода отменяет запрос истории предыдущего периода; уход — текущий', (
    WidgetTester tester,
  ) async {
    final CustomersHarness h = CustomersHarness();
    h.directory.onHistory = (String id, CustomerHistoryQuery q) => Completer<Result<CustomerHistory>>().future;
    await h.pump(tester, const CustomerHistoryScreen(customerId: 'c1'));
    expect(h.directory.historyCalls, hasLength(1));
    await tapVisible(tester, find.byKey(CustomerHistoryKeys.preset(HistoryPreset.days30)));
    await settle(tester);
    expect(h.directory.historyCalls, hasLength(2));
    expect(h.directory.historyCancels[0]!.isCancelled, isTrue);
    expect(h.directory.historyCancels[1]!.isCancelled, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(h.directory.historyCancels[1]!.isCancelled, isTrue);
  });
}
