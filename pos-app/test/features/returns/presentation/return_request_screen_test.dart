// SCR-39 «Заявка на возврат» (RM-G-007, RM-G-012; 02 SCR-39.13 AC-UI-39-001…018; 12 T-RET): валидация количеств и
// причины, step-up отправки, порог согласования, идемпотентность, права действий по ролям, флаги модуля, офлайн,
// удаление черновика, согласование/отклонение держателем `return.approve`.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_checkbox.dart';
import 'package:optomstroy/design_system/components/app_dropdown.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/components/return_status_chip.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/returns/domain/entities/return_request.dart';
import 'package:optomstroy/features/returns/presentation/providers/returns_ports.dart';
import 'package:optomstroy/features/returns/presentation/returns_format.dart';
import 'package:optomstroy/features/returns/presentation/screens/return_request_screen.dart';
import 'package:optomstroy/features/returns/presentation/state/return_request_controller.dart';
import 'package:optomstroy/features/returns/presentation/state/return_request_state.dart';
import 'package:optomstroy/features/returns/presentation/widgets/return_sections.dart';

import '../../../support/f_fakes.dart';
import '../support/returns_harness.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

/// Высокое окно compact: вся форма построена без прокрутки.
const Size kTall = Size(390, 2400);

const ReturnScreenArgs _newArgs = ReturnScreenArgs(orderId: 'o1');
const ReturnScreenArgs _savedArgs = ReturnScreenArgs(returnId: 'r1');

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

ReturnRequestController _ctrl(WidgetTester tester, ReturnScreenArgs args) => ProviderScope.containerOf(
  tester.element(find.byType(ReturnRequestScreen)),
).read(returnRequestProvider(args).notifier);

Finder _checkbox(int lineNo) =>
    find.descendant(of: find.byKey(ReturnItemsSection.rowKey(lineNo)), matching: find.byType(AppCheckbox));

bool _enabled(WidgetTester tester, Key key) => tester.widget<AppButton>(find.byKey(key)).onPressed != null;

Future<void> _selectLineAndReason(WidgetTester tester, {ReturnReason reason = ReturnReason.defect}) async {
  await tester.tap(_checkbox(1));
  await tester.pump();
  await tester.tap(find.byKey(ReturnReasonSection.reasonKey(reason)));
  await tester.pump();
}

/// Ответ `POST /returns`: черновик из ввода.
Future<Result<ReturnRequest>> _created(ReturnDraftInput input, String key) async => Success<ReturnRequest>(
  returnRequest(
    reason: input.reasonCode,
    comment: input.reasonComment,
    items: <ReturnRequestItem>[
      for (final ReturnItemInput i in input.items)
        ReturnRequestItem(
          orderLineNo: i.orderLineNo,
          variantId: 'v${i.orderLineNo}',
          quantity: i.quantity,
          maxReturnable: const Qty(2000),
          amount: const Money(235000),
        ),
    ],
  ),
);

void main() {
  group('создание и валидация (AC-UI-39-001…003)', () {
    testWidgets('строки заказа: лимит, «возвращено полностью», нет данных о возвратах; кнопки неактивны без строк', (
      WidgetTester tester,
    ) async {
      final ReturnsHarness h = ReturnsHarness();
      await h.pump(tester, const ReturnRequestScreen(orderId: 'o1'), size: kTall);

      expect(find.byKey(ReturnRequestScreen.rootKey), findsOneWidget);
      expect(find.text(l10n.return_title_new), findsOneWidget);
      expect(find.text(l10n.return_item_max('2')), findsOneWidget);
      expect(find.text(l10n.return_item_fully_returned), findsOneWidget);
      expect(find.text(l10n.return_no_previous_data), findsOneWidget);
      expect(find.text(l10n.return_onec_note), findsOneWidget, reason: 'AC-UI-39-008: деньги и документ — в 1С');
      expect(tester.widget<AppCheckbox>(_checkbox(2)).onChanged, isNull, reason: 'строка возвращена полностью');

      expect(find.byKey(ReturnRequestScreen.hintKey), findsOneWidget);
      expect(find.text(l10n.return_items_required), findsOneWidget);
      expect(_enabled(tester, ReturnRequestScreen.saveKey), isFalse);
      expect(_enabled(tester, ReturnRequestScreen.submitKey), isFalse);

      await tester.tap(_checkbox(1));
      await tester.pump();
      expect(find.text(l10n.return_reason_required), findsOneWidget);
      expect(_enabled(tester, ReturnRequestScreen.submitKey), isFalse, reason: 'без причины');

      await tester.tap(find.byKey(ReturnReasonSection.reasonKey(ReturnReason.defect)));
      await tester.pump();
      expect(find.byKey(ReturnRequestScreen.hintKey), findsNothing);
      expect(_enabled(tester, ReturnRequestScreen.saveKey), isTrue);
      expect(_enabled(tester, ReturnRequestScreen.submitKey), isTrue);
      expect(find.text(l10n.return_amount(ReturnsFormat.money(Money.som(2350)))), findsOneWidget);
      expect(h.returns.calls, isEmpty);
    });

    testWidgets(
      'степпер не выходит за «отгружено − возвращено»; ввод больше — ошибка, кнопки неактивны (AC-UI-39-002)',
      (WidgetTester tester) async {
        final ReturnsHarness h = ReturnsHarness();
        await h.pump(tester, const ReturnRequestScreen(orderId: 'o1'), size: kTall);
        await _selectLineAndReason(tester);

        final Finder plus = find.descendant(
          of: find.byKey(const ValueKey<String>('return-qty-1')),
          matching: find.byIcon(Icons.add_rounded),
        );
        await tester.tap(plus);
        await tester.pump();
        final ReturnFormState s = ProviderScope.containerOf(
          tester.element(find.byType(ReturnRequestScreen)),
        ).read(returnRequestProvider(_newArgs));
        expect(s.lines.first.qty, const Qty(2000));
        await tester.tap(plus);
        await tester.pump();
        expect(
          ProviderScope.containerOf(
            tester.element(find.byType(ReturnRequestScreen)),
          ).read(returnRequestProvider(_newArgs)).lines.first.qty,
          const Qty(2000),
          reason: '«+» на максимуме недоступна',
        );

        _ctrl(tester, _newArgs).setQty(1, const Qty(3000));
        await tester.pump();
        expect(find.text(l10n.return_item_exceeds('2')), findsOneWidget);
        expect(_enabled(tester, ReturnRequestScreen.saveKey), isFalse);
        expect(_enabled(tester, ReturnRequestScreen.submitKey), isFalse);
        expect(h.returns.calls, isEmpty);
      },
    );

    test('ввод нампада: больше лимита — ошибка, иначе количество', () {
      expect(ReturnQtyInput.validate(l10n, '3', const Qty(2000)).error, l10n.return_item_exceeds('2'));
      expect(ReturnQtyInput.validate(l10n, '1,5', const Qty(2000)), (qty: const Qty(1500), error: null));
      expect(ReturnQtyInput.validate(l10n, 'x', const Qty(2000)).qty, isNull);
    });

    testWidgets('«Иное» требует комментарий ≥ 10 символов: запроса нет, ошибка у поля', (WidgetTester tester) async {
      final ReturnsHarness h = ReturnsHarness();
      await h.pump(tester, const ReturnRequestScreen(orderId: 'o1'), size: kTall);
      await _selectLineAndReason(tester, reason: ReturnReason.other);
      await tester.enterText(find.byKey(ReturnReasonSection.commentKey).hitTestable().first, 'коротко');
      await tester.pump();

      await tester.tap(find.byKey(ReturnRequestScreen.submitKey));
      await _settle(tester);
      expect(find.text(l10n.return_comment_required), findsOneWidget);
      expect(h.returns.calls, isEmpty);
      expect(h.stepUps, isEmpty);
    });

    testWidgets('«Выбрать всё» отмечает доступные строки с максимальным количеством', (WidgetTester tester) async {
      final ReturnsHarness h = ReturnsHarness();
      await h.pump(tester, const ReturnRequestScreen(orderId: 'o1'), size: kTall);
      await tester.tap(find.text(l10n.return_select_all));
      await tester.pump();
      final ReturnFormState s = ProviderScope.containerOf(
        tester.element(find.byType(ReturnRequestScreen)),
      ).read(returnRequestProvider(_newArgs));
      expect(
        <int, Qty>{for (final ReturnLine l in s.lines) l.orderLineNo: l.qty},
        <int, Qty>{1: const Qty(2000), 2: Qty.zero, 3: const Qty(25000)},
      );
    });

    testWidgets('заказ не отгружен — «Возврат недоступен» без формы (AC-UI-39-001)', (WidgetTester tester) async {
      final ReturnsHarness h = ReturnsHarness(order: sourceOrder(status: OrderStatus.awaitingPayment));
      await h.pump(tester, const ReturnRequestScreen(orderId: 'o1'), size: kTall);
      expect(find.text(l10n.return_not_returnable), findsOneWidget);
      expect(find.byKey(ReturnRequestScreen.submitKey), findsNothing);
    });
  });

  group('сохранение и отправка (AC-UI-39-004…006)', () {
    testWidgets('сохранение черновика отправляет одну заявку и показывает «Черновик сохранён»', (
      WidgetTester tester,
    ) async {
      final ReturnsHarness h = ReturnsHarness()..returns.onCreate = _created;
      await h.pump(tester, const ReturnRequestScreen(orderId: 'o1'), size: kTall);
      await _selectLineAndReason(tester);
      await tester.tap(find.byKey(ReturnRequestScreen.saveKey));
      await _settle(tester);

      expect(h.returns.of('create'), hasLength(1));
      final ReturnDraftInput input = h.returns.of('create').single.args[0]! as ReturnDraftInput;
      expect(input.orderId, 'o1');
      expect(input.reasonCode, ReturnReason.defect);
      expect(input.items.single.orderLineNo, 1);
      expect(input.items.single.quantity.value, const Qty(1000));
      expect(h.returns.of('create').single.args[1], 'key-1');
      expect(find.text(l10n.return_draft_saved), findsWidgets);
      expect(find.byKey(ReturnRequestScreen.deleteKey), findsOneWidget);
    });

    testWidgets('отправка: сохранение → step-up return.submit → submit с токеном → просмотр (AC-UI-39-004, 007)', (
      WidgetTester tester,
    ) async {
      final ReturnsHarness h = ReturnsHarness()
        ..returns.onCreate = _created
        ..returns.onSubmit = (String id, int rv, String key, String? token) async =>
            Success<ReturnRequest>(returnRequest(status: ReturnRequestStatus.submitted, rowVersion: rv + 1));
      await h.pump(tester, const ReturnRequestScreen(orderId: 'o1'), size: kTall);
      await _selectLineAndReason(tester);
      await tester.tap(find.byKey(ReturnRequestScreen.submitKey));
      await _settle(tester);

      expect(h.returns.calls.map((FakeCall c) => c.method), <String>['create', 'submit']);
      expect(h.stepUps, <String>[ReturnsStepUpOperations.submit]);
      expect(h.returns.of('submit').single.args, <Object?>['r1', 1, 'key-2', 'step-up-token']);
      expect(find.text(l10n.return_submitted), findsWidgets);
      expect(find.byType(ReturnStatusBlock), findsOneWidget);
      expect(find.byType(ReturnStatusChip), findsOneWidget);
      expect(find.byKey(ReturnRequestScreen.submitKey), findsNothing, reason: 'после отправки — режим просмотра');
    });

    testWidgets('отмена StepUpDialog — заявка остаётся черновиком, submit не отправляется', (
      WidgetTester tester,
    ) async {
      final ReturnsHarness h = ReturnsHarness(stepUpCancelled: true)..returns.onCreate = _created;
      await h.pump(tester, const ReturnRequestScreen(orderId: 'o1'), size: kTall);
      await _selectLineAndReason(tester);
      await tester.tap(find.byKey(ReturnRequestScreen.submitKey));
      await _settle(tester);

      expect(h.returns.of('create'), hasLength(1));
      expect(h.returns.of('submit'), isEmpty);
      expect(find.byKey(ReturnRequestScreen.submitKey), findsOneWidget);
      expect(find.byKey(ReturnRequestScreen.deleteKey), findsOneWidget, reason: 'черновик сохранён');
    });

    testWidgets('кассир сверх порога: 403 return_threshold_exceeded — баннер, черновик сохранён (AC-UI-39-006)', (
      WidgetTester tester,
    ) async {
      final ReturnsHarness h = ReturnsHarness()
        ..returns.onCreate = _created
        ..returns.onSubmit = (String id, int rv, String key, String? token) async =>
            const FailureResult<ReturnRequest>(PermissionFailure(serverReason: 'return_threshold_exceeded'));
      await h.pump(tester, const ReturnRequestScreen(orderId: 'o1'), size: kTall);
      await _selectLineAndReason(tester);
      await tester.tap(find.byKey(ReturnRequestScreen.submitKey));
      await _settle(tester);

      expect(find.text(l10n.return_threshold), findsOneWidget);
      expect(find.text(l10n.error_forbidden), findsNothing, reason: 'порог — не P-403');
      expect(find.byKey(ReturnRequestScreen.submitKey), findsOneWidget);
    });

    testWidgets('иной 403 — «Недостаточно прав»', (WidgetTester tester) async {
      final ReturnsHarness h = ReturnsHarness()
        ..returns.onCreate = _created
        ..returns.onSubmit = (String id, int rv, String key, String? token) async =>
            const FailureResult<ReturnRequest>(PermissionFailure());
      await h.pump(tester, const ReturnRequestScreen(orderId: 'o1'), size: kTall);
      await _selectLineAndReason(tester);
      await tester.tap(find.byKey(ReturnRequestScreen.submitKey));
      await _settle(tester);
      expect(find.text(l10n.error_forbidden), findsOneWidget);
      expect(find.text(l10n.return_threshold), findsNothing);
    });

    testWidgets('двойное нажатие «Отправить» — одна заявка и один submit (AC-UI-39-005)', (WidgetTester tester) async {
      final Completer<Result<ReturnRequest>> pending = Completer<Result<ReturnRequest>>();
      final ReturnsHarness h = ReturnsHarness()
        ..returns.onCreate = ((ReturnDraftInput i, String k) => pending.future)
        ..returns.onSubmit = (String id, int rv, String key, String? token) async =>
            Success<ReturnRequest>(returnRequest(status: ReturnRequestStatus.submitted, rowVersion: rv + 1));
      await h.pump(tester, const ReturnRequestScreen(orderId: 'o1'), size: kTall);
      await _selectLineAndReason(tester);
      await tester.tap(find.byKey(ReturnRequestScreen.submitKey));
      await tester.pump();
      await tester.tap(find.byKey(ReturnRequestScreen.submitKey), warnIfMissed: false);
      await tester.pump();
      unawaited(_ctrl(tester, _newArgs).submit());
      pending.complete(
        await _created(
          const ReturnDraftInput(
            orderId: 'o1',
            reasonCode: ReturnReason.defect,
            items: <ReturnItemInput>[
              ReturnItemInput(
                orderLineNo: 1,
                quantity: LineQuantity(value: Qty(1000), unitId: 'pcs'),
              ),
            ],
          ),
          'key-1',
        ),
      );
      await _settle(tester);
      expect(h.returns.of('create'), hasLength(1));
      expect(h.returns.of('submit'), hasLength(1));
    });

    testWidgets('потеря ответа submit — баннер «Связь прервалась», повтор тем же ключом (P-IDEMP)', (
      WidgetTester tester,
    ) async {
      int attempt = 0;
      final ReturnsHarness h = ReturnsHarness()
        ..returns.onCreate = _created
        ..returns.onSubmit = (String id, int rv, String key, String? token) async => ++attempt == 1
            ? const FailureResult<ReturnRequest>(NetworkFailure(NetworkFailureKind.timeout, outcomeUnknown: true))
            : Success<ReturnRequest>(returnRequest(status: ReturnRequestStatus.submitted, rowVersion: rv + 1));
      await h.pump(tester, const ReturnRequestScreen(orderId: 'o1'), size: kTall);
      await _selectLineAndReason(tester);
      await tester.tap(find.byKey(ReturnRequestScreen.submitKey));
      await _settle(tester);
      expect(find.text(l10n.return_unknown), findsOneWidget);

      await tester.tap(find.text(l10n.ds_button_retry));
      await _settle(tester);
      final List<FakeCall> submits = h.returns.of('submit');
      expect(submits, hasLength(2));
      expect(submits[0].args[2], submits[1].args[2], reason: 'тот же Idempotency-Key');
      expect(find.text(l10n.return_unknown), findsNothing);
      expect(find.byType(ReturnStatusBlock), findsOneWidget);
    });

    testWidgets('VERSION_CONFLICT при правке черновика — перечитывание и сообщение (AC-UI-39-011)', (
      WidgetTester tester,
    ) async {
      final ReturnsHarness h = ReturnsHarness()
        ..returns.onGet = ((String id) async => Success<ReturnRequest>(returnRequest(rowVersion: 3)))
        ..returns.onUpdate = (String id, ReturnDraftPatch p) async =>
            const FailureResult<ReturnRequest>(ConflictFailure(ConflictKind.versionConflict));
      await h.pump(tester, const ReturnRequestScreen(returnId: 'r1'), size: kTall);
      await _settle(tester);
      _ctrl(tester, _savedArgs).increment(1);
      await tester.pump();
      await tester.tap(find.byKey(ReturnRequestScreen.saveKey));
      await _settle(tester);

      expect(h.returns.of('update'), hasLength(1));
      expect(h.returns.of('get'), hasLength(2));
      expect(find.text(l10n.return_version_conflict), findsOneWidget);
      final ReturnFormState s = ProviderScope.containerOf(
        tester.element(find.byType(ReturnRequestScreen)),
      ).read(returnRequestProvider(_savedArgs));
      expect(s.dirty, isFalse);
      expect(s.request?.rowVersion, 3);
    });

    testWidgets('RETURN_QTY_EXCEEDED подсвечивает строку', (WidgetTester tester) async {
      final ReturnsHarness h = ReturnsHarness()
        ..returns.onCreate = (ReturnDraftInput i, String k) async => const FailureResult<ReturnRequest>(
          ServerFailure(
            code: 'RETURN_QTY_EXCEEDED',
            status: 422,
            errors: <FieldError>[FieldError(field: 'items[0].quantity', rule: 'max')],
            details: <String, Object?>{'max': 1},
          ),
        );
      await h.pump(tester, const ReturnRequestScreen(orderId: 'o1'), size: kTall);
      await _selectLineAndReason(tester);
      await tester.tap(find.byKey(ReturnRequestScreen.saveKey));
      await _settle(tester);
      expect(find.text(l10n.return_item_exceeds('2')), findsOneWidget);
    });
  });

  group('удаление черновика (AC-UI-39-015)', () {
    testWidgets('подтверждение отправляет один DELETE с rowVersion и сообщает об удалении', (
      WidgetTester tester,
    ) async {
      final ReturnsHarness h = ReturnsHarness()
        ..returns.onGet = ((String id) async => Success<ReturnRequest>(returnRequest(rowVersion: 4)))
        ..returns.onDelete = ((String id, int rv) async => const Success<void>(null));
      await h.pump(tester, const ReturnRequestScreen(returnId: 'r1'), size: kTall);
      await _settle(tester);
      await tester.tap(find.byKey(ReturnRequestScreen.deleteKey));
      await _settle(tester);
      expect(find.text(l10n.return_delete_title), findsOneWidget);
      await tester.tap(find.widgetWithText(AppButton, l10n.return_delete_draft).last);
      await _settle(tester);
      expect(h.returns.of('delete').single.args, <Object?>['r1', 4]);
      expect(find.text(l10n.return_deleted), findsOneWidget);
    });

    testWidgets('у owner и у заявок не в draft кнопки «Удалить черновик» нет', (WidgetTester tester) async {
      final ReturnsHarness owner = ReturnsHarness(role: RoleCode.owner)
        ..returns.onGet = ((String id) async => Success<ReturnRequest>(returnRequest()));
      await owner.pump(tester, const ReturnRequestScreen(returnId: 'r1'), size: kTall);
      await _settle(tester);
      expect(find.byKey(ReturnRequestScreen.deleteKey), findsNothing);
      expect(find.byKey(ReturnRequestScreen.saveKey), findsNothing);

      final ReturnsHarness cashier = ReturnsHarness()
        ..returns.onGet = ((String id) async =>
            Success<ReturnRequest>(returnRequest(status: ReturnRequestStatus.submitted)));
      await cashier.pump(tester, const ReturnRequestScreen(returnId: 'r1'), size: kTall);
      await _settle(tester);
      expect(find.byKey(ReturnRequestScreen.deleteKey), findsNothing);
    });
  });

  group('права действий (AC-UI-39-009, 016, 017, 018)', () {
    Future<ReturnsHarness> open(
      WidgetTester tester, {
      required RoleCode role,
      ReturnRequestStatus status = ReturnRequestStatus.submitted,
    }) async {
      final ReturnsHarness h = ReturnsHarness(role: role, userId: 'u9')
        ..returns.onGet = ((String id) async => Success<ReturnRequest>(returnRequest(status: status)));
      await h.pump(tester, const ReturnRequestScreen(returnId: 'r1'), size: kTall);
      await _settle(tester);
      return h;
    }

    testWidgets('owner — только просмотр, без кнопок', (WidgetTester tester) async {
      await open(tester, role: RoleCode.owner);
      expect(find.byKey(ReturnRequestScreen.acceptKey), findsNothing);
      expect(find.byKey(ReturnRequestScreen.rejectKey), findsNothing);
      expect(find.byType(ReturnStatusBlock), findsOneWidget);
    });

    testWidgets('cashier — нет «Согласовать»/«Отклонить»', (WidgetTester tester) async {
      await open(tester, role: RoleCode.cashier);
      expect(find.byKey(ReturnRequestScreen.acceptKey), findsNothing);
      expect(find.byKey(ReturnRequestScreen.rejectKey), findsNothing);
    });

    testWidgets('senior_seller: submitted — обе кнопки; accepted — только «Отклонить»; draft — нет', (
      WidgetTester tester,
    ) async {
      await open(tester, role: RoleCode.seniorSeller);
      expect(find.byKey(ReturnRequestScreen.acceptKey), findsOneWidget);
      expect(find.byKey(ReturnRequestScreen.rejectKey), findsOneWidget);

      await open(tester, role: RoleCode.admin, status: ReturnRequestStatus.accepted);
      expect(find.byKey(ReturnRequestScreen.acceptKey), findsNothing);
      expect(find.byKey(ReturnRequestScreen.rejectKey), findsOneWidget);

      await open(tester, role: RoleCode.seniorSeller, status: ReturnRequestStatus.draft);
      expect(find.byKey(ReturnRequestScreen.acceptKey), findsNothing);
      expect(find.byKey(ReturnRequestScreen.rejectKey), findsNothing);
      expect(find.text(l10n.return_foreign_draft('Айгуль')), findsOneWidget, reason: 'чужой черновик (CASH-007)');
    });

    testWidgets('«Согласовать»: подтверждение → step-up return.approve → один accept; повторное нажатие игнорируется', (
      WidgetTester tester,
    ) async {
      final ReturnsHarness h = await open(tester, role: RoleCode.seniorSeller);
      h.returns.onAccept = (String id, int rv, String key, String? token) async =>
          Success<ReturnRequest>(returnRequest(status: ReturnRequestStatus.accepted, rowVersion: rv + 1));
      await tester.tap(find.byKey(ReturnRequestScreen.acceptKey));
      await _settle(tester);
      expect(find.text(l10n.return_accept_title), findsOneWidget);
      await tester.tap(find.widgetWithText(AppButton, l10n.return_accept).last);
      await _settle(tester);
      expect(h.stepUps, <String>[ReturnsStepUpOperations.approve]);
      expect(h.returns.of('accept').single.args, <Object?>['r1', 1, 'key-1', 'step-up-token']);
      expect(find.text(l10n.return_accepted), findsWidgets);
      expect(find.byKey(ReturnRequestScreen.acceptKey), findsNothing);
      expect(find.byKey(ReturnRequestScreen.rejectKey), findsOneWidget);
    });

    testWidgets('409 already_in_onec — баннер, кнопки решения скрыты', (WidgetTester tester) async {
      final ReturnsHarness h = await open(tester, role: RoleCode.admin);
      h.returns.onAccept = (String id, int rv, String key, String? token) async => const FailureResult<ReturnRequest>(
        ConflictFailure(ConflictKind.orderStateInvalid, reason: 'already_in_onec'),
      );
      await tester.tap(find.byKey(ReturnRequestScreen.acceptKey));
      await _settle(tester);
      await tester.tap(find.widgetWithText(AppButton, l10n.return_accept).last);
      await _settle(tester);
      expect(find.text(l10n.return_already_in_onec), findsOneWidget);
      expect(find.byKey(ReturnRequestScreen.acceptKey), findsNothing);
      expect(find.byKey(ReturnRequestScreen.rejectKey), findsNothing);
    });

    testWidgets('«Отклонить»: причина < 5 — CTA неактивна; с причиной — один reject {reason}', (
      WidgetTester tester,
    ) async {
      final ReturnsHarness h = await open(tester, role: RoleCode.seniorSeller);
      h.returns.onReject = (String id, String reason, int rv, String key, String? token) async =>
          Success<ReturnRequest>(returnRequest(status: ReturnRequestStatus.rejected, rowVersion: rv + 1));
      await tester.tap(find.byKey(ReturnRequestScreen.rejectKey));
      await _settle(tester);
      expect(find.text(l10n.return_reject_title), findsOneWidget);
      final Finder field = find.descendant(of: find.byType(Dialog).hitTestable(), matching: find.byType(EditableText));
      final Finder anyField = field.evaluate().isEmpty ? find.byType(EditableText).last : field;
      await tester.enterText(anyField, 'брак');
      await tester.pump();
      await tester.tap(find.widgetWithText(AppButton, l10n.return_reject).last, warnIfMissed: false);
      await _settle(tester);
      expect(h.returns.of('reject'), isEmpty, reason: 'причина короче 5 символов');

      await tester.enterText(anyField, 'Товар не повреждён');
      await tester.pump();
      await tester.tap(find.widgetWithText(AppButton, l10n.return_reject).last);
      await _settle(tester);
      expect(h.stepUps, <String>[ReturnsStepUpOperations.approve]);
      expect(h.returns.of('reject').single.args, <Object?>['r1', 'Товар не повреждён', 1, 'key-1', 'step-up-token']);
      expect(find.text(l10n.return_rejected_done), findsWidgets);
      expect(find.text(l10n.return_rejected('Товар не повреждён')), findsOneWidget);
    });

    testWidgets('cashier, чужой черновик — 404 «Заявка не найдена», без PATCH/DELETE/submit', (
      WidgetTester tester,
    ) async {
      final ReturnsHarness h = ReturnsHarness()
        ..returns.onGet = ((String id) async =>
            const FailureResult<ReturnRequest>(ServerFailure(code: 'NOT_FOUND', status: 404)));
      await h.pump(tester, const ReturnRequestScreen(returnId: 'r1'), size: kTall);
      await _settle(tester);
      expect(find.text(l10n.return_not_found), findsOneWidget);
      expect(h.returns.calls.map((FakeCall c) => c.method), <String>['get']);
    });
  });

  group('флаги и сеть (AC-UI-39-010, 013, 014)', () {
    testWidgets('features.returnsFromPos=false — «Возвраты оформляются в 1С», запросов нет', (
      WidgetTester tester,
    ) async {
      final ReturnsHarness h = ReturnsHarness(returnsEnabled: false);
      await h.pump(tester, const ReturnRequestScreen(orderId: 'o1'), size: kTall);
      expect(find.text(l10n.return_disabled), findsOneWidget);
      expect(h.orders.calls, isEmpty);
      expect(h.returns.calls, isEmpty);
    });

    testWidgets('флаг ещё не получен от сервера — экран открывается (решает сервер, GQ-FEFND-09)', (
      WidgetTester tester,
    ) async {
      final ReturnsHarness h = ReturnsHarness(returnsEnabled: false, flagsFromServer: false);
      await h.pump(tester, const ReturnRequestScreen(orderId: 'o1'), size: kTall);
      expect(find.text(l10n.return_disabled), findsNothing);
      expect(find.byKey(ReturnRequestScreen.submitKey), findsOneWidget);
    });

    testWidgets('нет сети при правке — форма видна, кнопки disabled с подсказкой', (WidgetTester tester) async {
      final ReturnsHarness h = ReturnsHarness(online: false);
      await h.pump(tester, const ReturnRequestScreen(orderId: 'o1'), size: kTall);
      await _selectLineAndReason(tester);
      expect(find.text(l10n.return_offline_hint), findsWidgets);
      expect(_enabled(tester, ReturnRequestScreen.saveKey), isFalse);
      expect(_enabled(tester, ReturnRequestScreen.submitKey), isFalse);
    });

    testWidgets('нет сети при открытии — «Заявка недоступна без сети»', (WidgetTester tester) async {
      final ReturnsHarness h = ReturnsHarness(
        orders: FakeOrdersRepository()
          ..onGet = (String id, bool r) async =>
              const FailureResult<OrderDetails>(NetworkFailure(NetworkFailureKind.offline)),
      );
      await h.pump(tester, const ReturnRequestScreen(orderId: 'o1'), size: kTall);
      expect(find.text(l10n.return_offline_no_data), findsOneWidget);
    });

    testWidgets('medium — «диалог» 640 с крестиком, причина — AppDropdown', (WidgetTester tester) async {
      final ReturnsHarness h = ReturnsHarness();
      await h.pump(tester, const ReturnRequestScreen(orderId: 'o1'), size: const Size(820, 1000));
      expect(find.byKey(ReturnRequestScreen.closeKey), findsOneWidget);
      expect(find.byType(AppDropdown<ReturnReason>), findsOneWidget);
      expect(find.byType(AppRadio<ReturnReason>), findsNothing);
      expect(tester.getSize(find.byType(ReturnSourceCard)).width, lessThanOrEqualTo(640));
    });
  });

  test('права зрителя по ролям (11 §4.3: return.create / return.approve)', () {
    expect(const ReturnsViewer(role: RoleCode.cashier).canCreate, isTrue);
    expect(const ReturnsViewer(role: RoleCode.cashier).canApprove, isFalse);
    expect(const ReturnsViewer(role: RoleCode.seniorSeller).canApprove, isTrue);
    expect(const ReturnsViewer(role: RoleCode.admin).canApprove, isTrue);
    expect(const ReturnsViewer(role: RoleCode.owner).canCreate, isFalse);
    expect(const ReturnsViewer(role: RoleCode.seller).canCreate, isFalse);
    expect(const ReturnsViewer().canCreate, isFalse, reason: 'роль неизвестна — только просмотр (fail-closed)');
  });
}
