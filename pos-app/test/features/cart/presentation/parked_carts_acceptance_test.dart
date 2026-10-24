// T-UI-023 (12 §3.9) — недостающие кейсы приёмочного набора SCR-23 «Отложенные заказы» (02 SCR-23.13): AC-UI-23-002,
// 004, 005, 006, 009, 012, 013. Остальные — parked_carts_screen_test.dart. Данные синтетические.
//
// Ограничения (записаны в ТЗ): `owner` в SCR-23 сейчас закрыт guard G-7 (Q-005, FQ-FND-04; 02 SCR-23 «Уточнение»),
// поэтому AC-UI-23-006/012 проверяются на уровне экрана (переход из SCR-48 — после ответа Q-005); аудит
// `cart.resumed_foreign` (AC-UI-23-002) пишет сервер — e2e pos-api.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/presentation/screens/parked_carts_screen.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_panel_view.dart';

import '../../../support/f_fakes.dart';
import '../support/cart_test_support.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

CartParkedSummary parked(
  String id, {
  String owner = 'user-1',
  String ownerName = 'Айгуль Продавец',
  String? name,
  Duration expiresIn = const Duration(days: 5),
}) => CartParkedSummary(
  id: id,
  status: CartStatus.parked,
  rowVersion: 3,
  name: name ?? 'Бригада Асанова',
  ownerId: owner,
  owner: UserRef(id: owner, displayName: ownerName),
  itemsCount: 5,
  total: const Money(1600750),
  parkedAt: cartNow.subtract(const Duration(hours: 2)),
  expiresAt: cartNow.add(expiresIn),
);

List<FakeCall> callsOf(FakeCartRepository repo, String m) => repo.calls.where((FakeCall c) => c.method == m).toList();

void main() {
  late FakeCartRepository repo;
  late FakeCartSync sync;

  setUp(() {
    repo = FakeCartRepository();
    sync = FakeCartSync(repo);
    serveCart(repo, canonCart(items: const <CartLine>[]));
  });

  Future<void> pump(WidgetTester tester, {RoleCode role = RoleCode.seller, Size size = const Size(390, 860)}) async {
    tester.view.physicalSize = size;
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

  testWidgets('AC-UI-23-002: senior_seller, «Все» — автор виден; «Продолжить» чужой — корзина становится активной у '
      'него, снекбар «…автора … продолжен вами»', (tester) async {
    repo.onListParked = (ParkedScope scope, String? cursor) async => Success<PageResult<CartParkedSummary>>(
      PageResult<CartParkedSummary>(
        items: <CartParkedSummary>[
          if (scope == ParkedScope.all) parked('pc-9', owner: 'user-9', ownerName: 'Иван Петров'),
        ],
      ),
    );
    repo.onResumeParked = (String id, bool replace) async => Success<Cart>(canonCart());
    await pump(tester, role: RoleCode.seniorSeller);
    await tester.tap(find.byKey(const ValueKey<String>('parked-tab-all')));
    await tester.pumpAndSettle();
    expect(find.text('Иван Петров'), findsOneWidget);
    await tester.tap(find.byKey(ParkedKeys.resume('pc-9')));
    await tester.pump();
    expect(find.text(l10n.parked_resumed_foreign_snackbar('Бригада Асанова', 'Иван Петров')), findsWidgets);
    await tester.pumpAndSettle();
    expect(callsOf(repo, 'resumeParked').single.args.first, 'pc-9');
    expect(find.byType(CartPanelView), findsOneWidget, reason: 'активная корзина у старшего (SCR-20)');
  });

  testWidgets('AC-UI-23-004: возобновлённая корзина показывает изменения цен и остатков за время хранения', (
    tester,
  ) async {
    final Cart resumed = canonCart(
      items: <CartLine>[
        canonLine(
          'f4252',
          'Смеситель для кухни Frap F4252',
          'F4252',
          2,
          2410,
          priceSnapshot: Money.som(2350),
          warnings: const <CartItemWarning>[CartItemWarning.priceChanged],
        ),
        canonLine(
          'f2283',
          'Смеситель для ванны Frap F2283',
          'F2283',
          3,
          3450,
          available: Qty.units(1),
          warnings: const <CartItemWarning>[CartItemWarning.stockInsufficient],
        ),
      ],
    );
    repo.onListParked = (ParkedScope scope, String? cursor) async => Success<PageResult<CartParkedSummary>>(
      PageResult<CartParkedSummary>(items: <CartParkedSummary>[parked('pc-1')]),
    );
    repo.onResumeParked = (String id, bool replace) async {
      repo.onFetch = () async => Success<Cart>(resumed);
      return Success<Cart>(resumed);
    };
    await pump(tester, size: const Size(800, 1400));
    await tester.tap(find.byKey(ParkedKeys.resume('pc-1')));
    await tester.pumpAndSettle();
    expect(find.byType(CartPanelView), findsOneWidget);
    expect(find.text(l10n.cart_banner_prices_changed(1)), findsOneWidget);
    expect(
      find.text(
        l10n.cart_line_price_changed(PriceText.format(Money.som(2410)), PriceText.formatAmount(Money.som(2350))),
      ),
      findsOneWidget,
    );
    expect(find.textContaining(l10n.cart_line_stock_available('1', '').trim()), findsOneWidget);
  });

  testWidgets('AC-UI-23-005: срок хранения на карточке; за сутки до истечения «Удалится завтра» — цвет warning', (
    tester,
  ) async {
    repo.onListParked = (ParkedScope scope, String? cursor) async => Success<PageResult<CartParkedSummary>>(
      PageResult<CartParkedSummary>(
        items: <CartParkedSummary>[
          parked('pc-1'),
          parked('pc-2', name: 'Завтра', expiresIn: const Duration(hours: 20)),
        ],
      ),
    );
    await pump(tester);
    expect(find.textContaining(l10n.parked_card_expires('5'), findRichText: true), findsOneWidget);
    final Finder tomorrow = find.descendant(
      of: find.byKey(ParkedKeys.card('pc-2')),
      matching: find.textContaining(l10n.parked_card_expires_tomorrow, findRichText: true),
    );
    expect(tomorrow, findsOneWidget);
    final RichText rich = tester.widget<RichText>(find.descendant(of: tomorrow, matching: find.byType(RichText)).first);
    final BuildContext ctx = tester.element(tomorrow);
    expect(rich.text.style?.color, ctx.colors.warning);
  });

  testWidgets('AC-UI-23-006, AC-UI-23-012: owner — все отложенные (scope=all) в режиме чтения: пометка UI-23-012, без '
      '«Мои / Все», «Продолжить» и «Удалить»', (tester) async {
    repo.onListParked = (ParkedScope scope, String? cursor) async => Success<PageResult<CartParkedSummary>>(
      PageResult<CartParkedSummary>(
        items: <CartParkedSummary>[parked('pc-9', owner: 'user-9', ownerName: 'Иван Петров')],
      ),
    );
    await pump(tester, role: RoleCode.owner);
    expect(callsOf(repo, 'listParked').single.args.first, ParkedScope.all);
    expect(find.byKey(ParkedKeys.ownerNote), findsOneWidget);
    expect(find.text(l10n.parked_owner_readonly), findsOneWidget);
    expect(find.byKey(ParkedKeys.tabs), findsNothing);
    expect(find.text('Иван Петров'), findsOneWidget);
    expect(find.byKey(ParkedKeys.resume('pc-9')), findsNothing);
    expect(find.byKey(ParkedKeys.delete('pc-9')), findsNothing);
  });

  testWidgets(
    'AC-UI-23-009: «Удалить» — у своих карточек (seller, cashier); у чужих — только с cart.parked.resume.any; '
    'подтверждение → DELETE /cart/parked/{id}',
    (tester) async {
      repo.onListParked = (ParkedScope scope, String? cursor) async => Success<PageResult<CartParkedSummary>>(
        PageResult<CartParkedSummary>(
          items: <CartParkedSummary>[
            parked('pc-1'),
            if (scope == ParkedScope.all) parked('pc-9', owner: 'user-9', ownerName: 'Иван Петров'),
          ],
        ),
      );
      repo.onDeleteParked = (String id) async => const Success<void>(null);
      for (final RoleCode role in <RoleCode>[RoleCode.seller, RoleCode.cashier]) {
        await pump(tester, role: role);
        expect(find.byKey(ParkedKeys.delete('pc-1')), findsOneWidget, reason: '$role: своя');
        expect(find.byKey(ParkedKeys.delete('pc-9')), findsNothing, reason: '$role: чужих не видит');
        await tester.pumpWidget(const SizedBox());
      }
      await pump(tester, role: RoleCode.seniorSeller);
      await tester.tap(find.byKey(const ValueKey<String>('parked-tab-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(ParkedKeys.delete('pc-9')), findsOneWidget, reason: 'resume.any — чужая');
      await tester.tap(find.byKey(ParkedKeys.delete('pc-9')));
      await tester.pumpAndSettle();
      expect(find.textContaining(l10n.parked_delete_dialog_author('Иван Петров')), findsOneWidget);
      await tester.tap(find.text(l10n.parked_delete_dialog_confirm));
      await tester.pumpAndSettle();
      expect(callsOf(repo, 'deleteParked').single.args, <Object?>['pc-9']);
    },
  );

  testWidgets('AC-UI-23-013: «Мои / Все» — вкладки 48 lp; смена — GET /cart/parked?scope= с первой страницы, прокрутка '
      'сначала', (tester) async {
    repo.onListParked = (ParkedScope scope, String? cursor) async => Success<PageResult<CartParkedSummary>>(
      PageResult<CartParkedSummary>(
        items: <CartParkedSummary>[for (int i = 0; i < 20; i++) parked('${scope.value}-$i', name: '${scope.value} $i')],
      ),
    );
    await pump(tester, role: RoleCode.seniorSeller);
    expect(tester.getSize(find.byKey(const ValueKey<String>('parked-tab-all'))).height, 48);
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(find.text('own 0'), findsNothing, reason: 'прокручено вниз');
    await tester.tap(find.byKey(const ValueKey<String>('parked-tab-all')));
    await tester.pumpAndSettle();
    final FakeCall last = callsOf(repo, 'listParked').last;
    expect((last.args[0], last.args[1]), (ParkedScope.all, null), reason: 'первая страница (без cursor)');
    expect(find.text('all 0'), findsOneWidget, reason: 'прокрутка сброшена');
  });
}
