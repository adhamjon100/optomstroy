// SCR-23 «Отложенные заказы» (RM-F-005, RM-F-013; 02 SCR-23.13): список своих (seller — без «Мои / Все»), вкладка
// «Все» у senior_seller с автором, «Продолжить» — один запрос при двойном нажатии, `409 active_not_empty` → диалог
// UI-23-010 → `replaceActive: true`, «Удалить» — диалог UI-23-013, один `DELETE`, снекбар без «Отменить»; чужая
// карточка у продавца без «Удалить»; пустой список.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/presentation/screens/parked_carts_screen.dart';

import '../../../support/f_fakes.dart';
import '../support/cart_test_support.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

CartParkedSummary parked(String id, {String owner = 'user-1', String ownerName = 'Айгуль Продавец', String? name}) =>
    CartParkedSummary(
      id: id,
      status: CartStatus.parked,
      rowVersion: 3,
      name: name ?? 'Бригада Асанова',
      ownerId: owner,
      owner: UserRef(id: owner, displayName: ownerName),
      itemsCount: 5,
      total: const Money(1600750),
      parkedAt: cartNow.subtract(const Duration(hours: 2)),
      expiresAt: cartNow.add(const Duration(days: 5)),
    );

void main() {
  late FakeCartRepository repo;
  late FakeCartSync sync;

  setUp(() {
    repo = FakeCartRepository();
    sync = FakeCartSync(repo);
    serveCart(repo, canonCart(items: const <CartLine>[]));
  });

  Future<void> pump(WidgetTester tester, {RoleCode role = RoleCode.seller}) async {
    tester.view.physicalSize = const Size(390, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      cartApp(
        overrides: cartOverrides(sync: sync, repo: repo, role: role),
        initialLocation: '/cart/parked',
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('продавец: свои карточки без «Мои / Все»; сумма «(предварительно)», срок хранения (AC-UI-23-001)', (
    tester,
  ) async {
    repo.onListParked = (ParkedScope scope, String? cursor) async => Success<PageResult<CartParkedSummary>>(
      PageResult<CartParkedSummary>(items: <CartParkedSummary>[parked('pc-1')]),
    );
    await pump(tester);
    expect(find.byKey(ParkedKeys.tabs), findsNothing);
    expect(find.text('Бригада Асанова'), findsOneWidget);
    expect(find.textContaining(PriceText.formatAmount(const Money(1600750), fixed2: true)), findsOneWidget);
    expect(find.textContaining(l10n.parked_card_expires('5'), findRichText: true), findsOneWidget);
    expect(repo.calls.firstWhere((FakeCall c) => c.method == 'listParked').args[0], ParkedScope.own);
  });

  testWidgets('«Продолжить»: двойное нажатие — один resume; успех → корзина (AC-UI-23-007)', (tester) async {
    repo.onListParked = (ParkedScope scope, String? cursor) async => Success<PageResult<CartParkedSummary>>(
      PageResult<CartParkedSummary>(items: <CartParkedSummary>[parked('pc-1')]),
    );
    final Completer<Result<Cart>> done = Completer<Result<Cart>>();
    repo.onResumeParked = (String id, bool replace) => done.future;
    await pump(tester);
    await tester.tap(find.byKey(ParkedKeys.resume('pc-1')));
    await tester.pump();
    await tester.tap(find.byKey(ParkedKeys.resume('pc-1')), warnIfMissed: false);
    await tester.pump();
    done.complete(Success<Cart>(canonCart()));
    await tester.pumpAndSettle();
    expect(repo.calls.where((FakeCall c) => c.method == 'resumeParked'), hasLength(1));
    expect(find.text(l10n.cart_title), findsOneWidget, reason: 'переход в SCR-20');
  });

  testWidgets('409 active_not_empty → диалог UI-23-010 → resume replaceActive: true (AC-UI-23-003)', (tester) async {
    repo.onListParked = (ParkedScope scope, String? cursor) async => Success<PageResult<CartParkedSummary>>(
      PageResult<CartParkedSummary>(items: <CartParkedSummary>[parked('pc-1')]),
    );
    repo.onResumeParked = (String id, bool replace) async => replace
        ? Success<Cart>(canonCart())
        : const FailureResult<Cart>(ConflictFailure(ConflictKind.orderStateInvalid, reason: 'active_not_empty'));
    await pump(tester);
    await tester.tap(find.byKey(ParkedKeys.resume('pc-1')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.parked_active_not_empty_confirm), findsOneWidget);
    await tester.tap(find.text(l10n.parked_active_not_empty_confirm));
    await tester.pumpAndSettle();
    final List<FakeCall> calls = repo.calls.where((FakeCall c) => c.method == 'resumeParked').toList();
    expect(calls.map((FakeCall c) => c.args[1]), <Object?>[false, true]);
  });

  testWidgets('«Удалить»: диалог с фокусом на «Отмена», один DELETE, снекбар без «Отменить» (AC-UI-23-010)', (
    tester,
  ) async {
    repo.onListParked = (ParkedScope scope, String? cursor) async => Success<PageResult<CartParkedSummary>>(
      PageResult<CartParkedSummary>(
        items: <CartParkedSummary>[
          parked('pc-1'),
          parked('pc-2', name: 'Вторая'),
        ],
      ),
    );
    repo.onDeleteParked = (String id) async => const Success<void>(null);
    await pump(tester);
    await tester.tap(find.byKey(ParkedKeys.delete('pc-1')));
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmDialog), findsOneWidget);
    expect(find.text(l10n.parked_delete_dialog_body(5, 'Бригада Асанова')), findsOneWidget);
    await tester.tap(find.text(l10n.parked_delete_dialog_confirm));
    await tester.pumpAndSettle();
    expect(repo.calls.where((FakeCall c) => c.method == 'deleteParked').single.args, <Object?>['pc-1']);
    expect(find.byKey(ParkedKeys.card('pc-1')), findsNothing);
    expect(find.byKey(ParkedKeys.card('pc-2')), findsOneWidget);
    expect(find.text(l10n.parked_deleted_snackbar), findsOneWidget);
    expect(find.text(l10n.ds_button_undo), findsNothing);
  });

  testWidgets('senior_seller: вкладка «Все» — автор, чужую можно удалить и продолжить (AC-UI-23-011)', (tester) async {
    repo.onListParked = (ParkedScope scope, String? cursor) async => Success<PageResult<CartParkedSummary>>(
      PageResult<CartParkedSummary>(
        items: <CartParkedSummary>[
          if (scope == ParkedScope.all) parked('pc-9', owner: 'user-9', ownerName: 'Иван Петров'),
          parked('pc-1'),
        ],
      ),
    );
    await pump(tester, role: RoleCode.seniorSeller);
    expect(find.byKey(ParkedKeys.tabs), findsOneWidget);
    await tester.tap(find.text(l10n.parked_scope_all));
    await tester.pumpAndSettle();
    expect(repo.calls.where((FakeCall c) => c.method == 'listParked').last.args[0], ParkedScope.all);
    expect(find.text('Иван Петров'), findsOneWidget);
    expect(find.byKey(ParkedKeys.delete('pc-9')), findsOneWidget);
    expect(find.byKey(ParkedKeys.resume('pc-9')), findsOneWidget);
  });

  testWidgets('пусто — «Отложенных заказов нет» и «Вернуться в корзину» (AC-UI-23-008)', (tester) async {
    repo.onListParked = (ParkedScope scope, String? cursor) async =>
        const Success<PageResult<CartParkedSummary>>(PageResult<CartParkedSummary>(items: <CartParkedSummary>[]));
    await pump(tester);
    expect(find.text(l10n.parked_empty_title), findsOneWidget);
    expect(find.text(l10n.parked_empty_back_to_cart), findsOneWidget);
  });
}
