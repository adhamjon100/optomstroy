// Сброс планшета магазина FLOW-045 — оркестратор и монитор в маршрутах режима (`kioskRoutes()`, каркас
// `KioskShellScreen`; 04 FLOW-045.S1–S6, A1, A2, E1; 02 ч. F UI-51-005, UI-51-016, SCR-51.7 «Сброс без сети», SCR-51.11,
// AC-UI-51-015, AC-UI-52-017, AC-UI-53-002…006; 08 §4.25.4; 10 KIOSK-020, KIOSK-021, KIOSK-025; 11 PRIV-033;
// 13 TAB-2-05) на поддельном времени:
// - автосброс на SCR-51 / SCR-52, сброс SCR-53 по «Готово» и через 60 с, гашение экрана и уход в фон — немедленно,
//   отзыв — только память; двойной сброс — один запрос; «Начать заново» (порт фичи catalog); `426` и полноэкранные
//   состояния UI-51-015 во время покупки (FLOW-044.E3) — сброс при входе в состояние, после снятия — по метке;
// - сброс без сети: метка только с id корзины, корзина прошлого покупателя не показывается, при связи и при запуске
//   первым запросом — `POST /kiosk/reset`; повторы 5, 15, 60 с, затем раз в минуту; `403`/`426` — метка остаётся;
//   `404` — закрыта текущая активная корзина;
// - после сброса данных покупателя нет: состояние, drift, защищённое хранилище, журналы, буфер обмена;
// - провод `DioKioskRepository.reset`.
// Тест-кейсы 12_TEST_PLAN: T-KIOSK-028, T-KIOSK-029, T-KIOSK-054 (приложение; сервер — pos-api/test/kiosk/reset.spec.ts).
// Синтетические данные: UUID-заглушки, номер — шаблон `+996 555 000 xxx`.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show QueryRow;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/app_meta_dao.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/session/session_overlay.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/cart/data/cart_bindings.dart';
import 'package:optomstroy/features/cart/data/sync/kiosk_cart_sync.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/kiosk/data/dio_kiosk_repository.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_checkout_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/done/kiosk_done_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_idle_dialog.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_reset_orchestrator.dart';

import '../../core/database/test_database.dart';
import '../../core/network/fake_adapter.dart';
import '../../core/storage/in_memory_secure_storage.dart';
import '../../support/f_fakes.dart' show FakeCall;
import 'checkout/kiosk_checkout_support.dart';
import 'kiosk_reset_support.dart';

/// Технический пользователь планшета (синтетический UUID).
const String _tablet = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4fa1';

/// Корзина прошлого покупателя на сервере: одна строка.
Cart _buyerCart(String id) => Cart(
  id: id,
  status: CartStatus.active,
  items: <CartLine>[
    CartLine(
      variantId: 'v-1',
      productId: 'p-1',
      productName: 'Смеситель',
      quantity: LineQuantity(value: Qty.units(2), unitId: 'u-pc'),
      unitPrice: Money.som(1650),
      lineTotal: Money.som(3300),
    ),
  ],
  rowVersion: 5,
);

/// Ключи `app_meta`, кроме служебного `schema_version`.
Future<List<(String, String)>> _meta(AppDatabase db) async => <(String, String)>[
  for (final AppMetaRow r in await db.select(db.appMeta).get())
    if (r.key != AppMetaDao.schemaVersionKey) (r.key, r.value),
];

/// Все значения всех таблиц drift (`таблица:значение`).
Future<List<String>> _driftValues(AppDatabase db) async {
  final List<String> out = <String>[];
  final List<QueryRow> tables = await db.customSelect("SELECT name FROM sqlite_master WHERE type = 'table'").get();
  for (final QueryRow t in tables) {
    final String name = t.read<String>('name');
    for (final QueryRow row in await db.customSelect('SELECT * FROM "$name"').get()) {
      for (final Object? v in row.data.values) {
        if (v != null) out.add('$name:$v');
      }
    }
  }
  return out;
}

Finder get _dialog => find.byType(KioskIdleDialog);

/// 120 с без касаний и 15 с отсчёта.
Future<void> _idleReset(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 120));
  await tester.pump();
  expect(_dialog, findsOneWidget);
  await tester.pump(const Duration(seconds: 15));
  await tester.pumpAndSettle();
  expect(_dialog, findsNothing);
}

/// Память оформления пуста.
void _checkoutCleared(KioskResetStand s) {
  expect(
    (s.checkout.phoneDigits, s.checkout.codeDigits, s.checkout.challengeId, s.checkout.publicNumber),
    ('', '', null, null),
    reason: 'номер, код, challengeId и номер заявки — очищены',
  );
}

/// Лист без страницы на SCR-51 и SCR-52 поверх (как drawer корзины под SCR-52).
Future<void> _sheetThenCheckout(KioskResetStand s) async {
  await s.tester.tap(find.byKey(ShowcaseKeys.sheet));
  await s.tester.pumpAndSettle();
  unawaited(s.router.push<void>('/kiosk/checkout?step=phone'));
  await s.tester.pumpAndSettle();
  expect(find.byKey(KioskCheckoutScreen.screenKey), findsOneWidget);
  await s.enterPhoneAndCode();
  await s.tester.pump();
  expect(s.checkout.phoneDigits, kPhoneA, reason: 'предусловие: номер и код в памяти');
  expect(s.checkout.challengeId, kChallengeA);
}

void main() {
  configureSqliteForTests();

  group('T-KIOSK-028 автосброс', () {
    testWidgets('T-KIOSK-028 idle: на SCR-52 — номер, код и ключ очищены, слои закрыты (и drawer под SCR-52), '
        '/kiosk стартовой категории, новая корзина (AC-UI-52-017)', (WidgetTester tester) async {
      final KioskResetStand s = KioskResetStand(tester);
      await s.pump();
      await _sheetThenCheckout(s);
      await _idleReset(tester);

      expect(find.byKey(KioskCheckoutScreen.screenKey), findsNothing);
      expect(find.byKey(ShowcaseKeys.sheetBody), findsNothing, reason: 'слой под SCR-52 закрыт после смены страниц');
      expect(s.location, '/kiosk');
      _checkoutCleared(s);
      expect(s.f.repo.resetCalls, <String>[kCartId]);
      expect((s.cart.cart, s.cart.held), (newCartId(1), null));
      expect(s.clipboard.sets, <String?>['']);
    });

    testWidgets(
      'T-KIOSK-028 done: SCR-53 — через kiosk_done_seconds (60 с) сброс и SCR-51; касания таймер не продлевают '
      '(AC-UI-53-003)',
      (WidgetTester tester) async {
        final KioskResetStand s = KioskResetStand(tester);
        await s.pump();
        await s.submitOrder();
        s.router.go(KioskCheckoutLocations.done);
        await tester.pumpAndSettle();
        expect(find.byKey(KioskDoneScreen.numberKey), findsOneWidget);
        await tester.pump(const Duration(seconds: 30));
        await tester.tapAt(const Offset(40, 400));
        await tester.pump(const Duration(seconds: 29));
        expect(s.f.repo.resetCalls, isEmpty);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();

        expect(s.f.repo.resetCalls, <String>[kCartId]);
        expect(find.byKey(KioskDoneScreen.numberKey), findsNothing);
        expect(s.location, '/kiosk');
        _checkoutCleared(s);
        expect(s.clipboard.sets, <String?>['']);
      },
    );

    testWidgets('T-KIOSK-028 done: «Готово» — сразу сброс и SCR-51 (AC-UI-53-002)', (WidgetTester tester) async {
      final KioskResetStand s = KioskResetStand(tester);
      await s.pump();
      await s.submitOrder();
      s.router.go(KioskCheckoutLocations.done);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(KioskDoneScreen.doneKey));
      await tester.pumpAndSettle();
      expect(s.f.repo.resetCalls, <String>[kCartId]);
      expect(s.location, '/kiosk');
      expect(find.byKey(ShowcaseKeys.root), findsOneWidget);
      _checkoutCleared(s);
    });

    testWidgets('T-KIOSK-028 screen off: SCR-52 — гашение экрана (hidden) даёт немедленный сброс без диалога', (
      WidgetTester tester,
    ) async {
      final KioskResetStand s = KioskResetStand(tester);
      await s.pump();
      await _sheetThenCheckout(s);
      await s.lifecycle(const <AppLifecycleState>[AppLifecycleState.inactive, AppLifecycleState.hidden]);
      expect(_dialog, findsNothing);
      _checkoutCleared(s);
      expect(s.f.repo.resetCalls, <String>[kCartId], reason: 'сразу, без 120 с и диалога');
      await s.lifecycle(const <AppLifecycleState>[AppLifecycleState.paused]);
      expect(s.f.repo.resetCalls, hasLength(1), reason: 'hidden → paused — один сброс');
      await s.toForeground();
      await tester.pumpAndSettle();
      expect(s.location, '/kiosk');
      expect(find.byKey(ShowcaseKeys.sheetBody), findsNothing);
      expect(s.f.repo.resetCalls, hasLength(1), reason: 'метки нет — при возврате запроса нет');
      expect(s.clipboard.sets, <String?>['']);
    });

    testWidgets('T-KIOSK-028 background: SCR-53 — уход в фон даёт немедленный сброс (AC-UI-53-005)', (
      WidgetTester tester,
    ) async {
      final KioskResetStand s = KioskResetStand(tester);
      await s.pump();
      await s.submitOrder();
      s.router.go(KioskCheckoutLocations.done);
      await tester.pumpAndSettle();
      await s.toBackground();
      expect(s.f.repo.resetCalls, <String>[kCartId]);
      _checkoutCleared(s);
      await s.toForeground();
      await tester.pumpAndSettle();
      expect(find.byKey(KioskDoneScreen.numberKey), findsNothing, reason: 'номер заявки после возврата не виден');
      expect(s.location, '/kiosk');
    });

    testWidgets(
      'T-KIOSK-028 background: открытый «Вы ещё здесь?» закрывается сбросом — один запрос, без второго сброса',
      (WidgetTester tester) async {
        final KioskResetStand s = KioskResetStand(tester);
        await s.pump();
        await tester.pump(const Duration(seconds: 120));
        await tester.pump();
        expect(_dialog, findsOneWidget);
        await s.toBackground();
        await s.toForeground();
        await tester.pumpAndSettle();
        expect(_dialog, findsNothing);
        expect(s.f.repo.resetCalls, <String>[kCartId]);
        await tester.pump(const Duration(seconds: 30));
        expect(s.f.repo.resetCalls, hasLength(1), reason: 'отсчёт снятого диалога не сбрасывает второй раз');
        expect(s.idle.isRunning, isTrue);
      },
    );

    testWidgets('T-KIOSK-028 offline reset: без сети запроса нет, метка только с id, корзина на экране пуста; связь '
        'вернулась — первым запросом POST /kiosk/reset (AC-UI-51-015)', (WidgetTester tester) async {
      final KioskResetStand s = KioskResetStand(tester);
      await s.pump();
      s.cart.offline = true;
      s.online(OnlineStatus.offline);
      await tester.pump();
      await _idleReset(tester);
      expect((s.cart.held, s.cart.cartId), (kCartId, null), reason: 'метка — id сброшенной корзины');
      expect(s.cart.requested, isEmpty);
      expect(s.f.repo.resetCalls, isEmpty);
      expect(s.orchestrator.retryScheduled, isTrue);
      _checkoutCleared(s);

      s.cart.offline = false;
      s.online(OnlineStatus.online);
      await tester.pumpAndSettle();
      expect(s.f.repo.resetCalls, <String>[kCartId]);
      expect(s.cart.journal.where((String e) => e.startsWith('request:')).first, 'request:$kCartId');
      expect((s.cart.held, s.cart.cart), (null, newCartId(1)));
      expect(s.orchestrator.retryScheduled, isFalse);
      expect(s.carts.calls, isEmpty, reason: 'GET /cart до сброса не выполнялся');
    });

    testWidgets('T-KIOSK-028 отзыв (401 KIOSK_REVOKED): память очищена и слои закрыты без запроса к серверу '
        '(FLOW-045.S6)', (WidgetTester tester) async {
      final KioskResetStand s = KioskResetStand(tester);
      await s.pump();
      await tester.tap(find.byKey(ShowcaseKeys.sheet));
      await tester.pumpAndSettle();
      await s.enterPhoneAndCode();
      s.status(KioskStatus.revoked);
      await tester.pumpAndSettle();
      expect(find.byKey(ShowcaseKeys.sheetBody), findsNothing);
      _checkoutCleared(s);
      expect(s.cart.requested, isEmpty);
      expect(s.f.repo.resetCalls, isEmpty);
      expect(s.clipboard.sets, <String?>['']);
      expect(s.orchestrator.retryScheduled, isFalse);
      // Уведомление об отзыве (5 с, затем SCR-01) — задача WP-A04; стенд возвращает состояние раньше.
      s.status(KioskStatus.ready);
      await tester.pumpAndSettle();
    });

    testWidgets('SCR-51.11: двойной сброс («Начать заново» и уход в фон одновременно) — один запрос', (
      WidgetTester tester,
    ) async {
      final KioskResetStand s = KioskResetStand(tester);
      await s.pump();
      final Completer<Result<Cart>> answer = Completer<Result<Cart>>();
      s.f.repo.onReset = (String _) => answer.future;
      await tester.tap(find.byKey(ShowcaseKeys.startOver));
      await tester.pump();
      await s.toBackground();
      expect(s.f.repo.resetCalls, <String>[kCartId]);
      answer.complete(Success<Cart>(newEmptyCart(newCartId(1))));
      await s.toForeground();
      await tester.pumpAndSettle();
      expect(s.f.repo.resetCalls, hasLength(1));
      expect(s.cart.cart, newCartId(1));
    });

    testWidgets('«Начать заново» (порт фичи catalog): сброс без подтверждения — корзина, память оформления, буфер; '
        'витрину приводит в начальное состояние сам экран (UI-51-005)', (WidgetTester tester) async {
      final KioskResetStand s = KioskResetStand(tester);
      await s.pump();
      await s.enterPhoneAndCode();
      await tester.tap(find.byKey(ShowcaseKeys.search));
      await tester.pump();
      await tester.tap(find.byKey(ShowcaseKeys.startOver));
      await tester.pumpAndSettle();
      expect(s.f.repo.resetCalls, <String>[kCartId]);
      _checkoutCleared(s);
      expect(s.clipboard.sets, <String?>['']);
      expect(s.container.read(kioskResetGenerationProvider), 0, reason: 'экран-инициатор сбрасывает себя сам');
      expect(find.text('q:смеситель'), findsOneWidget);
      expect(s.location, '/kiosk');
    });
  });

  group('T-KIOSK-054 FLOW-044.E3 состояние планшета во время покупки', () {
    for (final KioskStatus status in <KioskStatus>[
      KioskStatus.networkDenied,
      KioskStatus.unavailable,
      KioskStatus.updateNeeded,
    ]) {
      testWidgets('T-KIOSK-054 ${status.name} на SCR-52 (номер и код в памяти, слой под экраном) → 30 мин → снято: '
          '/kiosk, SCR-52 нет, номер и challengeId очищены, слои закрыты; первым запросом — POST /kiosk/reset '
          'помеченной корзины', (WidgetTester tester) async {
        final KioskResetStand s = KioskResetStand(tester);
        await s.pump();
        await _sheetThenCheckout(s);
        // `426`: сервер отказывает и сбросу — метка остаётся до снятия состояния.
        if (status == KioskStatus.updateNeeded) {
          s.f.repo.onReset = (String id) async => const FailureResult<Cart>(AppUpdateRequiredFailure());
        }

        s.status(status);
        await tester.pumpAndSettle();
        expect(s.location, '/kiosk');
        expect(find.byKey(KioskCheckoutScreen.screenKey), findsNothing);
        expect(find.byKey(ShowcaseKeys.sheetBody), findsNothing, reason: 'слой поверх полноэкранного состояния закрыт');
        _checkoutCleared(s);
        expect(s.cart.held, kCartId, reason: 'метка сброса — при входе в состояние');
        expect(s.clipboard.sets, <String?>['']);
        final int beforeRecovery = s.f.repo.resetCalls.length;
        if (status != KioskStatus.updateNeeded) {
          expect(beforeRecovery, 0, reason: '403 — запрос сброса не уходит');
        }

        await tester.pump(const Duration(minutes: 30));
        if (status != KioskStatus.updateNeeded) {
          expect(s.f.repo.resetCalls, isEmpty, reason: '403 раз в минуту не повторяется');
        }
        s.f.repo.onReset = null;
        final int journal = s.cart.journal.length;
        s.status(KioskStatus.ready);
        await tester.pumpAndSettle();

        expect(s.cart.journal.sublist(journal).take(3), <String>['prepare', 'reset:$kCartId', 'request:$kCartId']);
        expect(s.f.repo.resetCalls.last, kCartId, reason: 'POST /kiosk/reset помеченной корзины');
        expect(s.cart.held, isNull);
        expect(s.location, '/kiosk');
        expect(find.byKey(KioskCheckoutScreen.screenKey), findsNothing, reason: 'SCR-52 не открывается снова');
        expect(find.byKey(ShowcaseKeys.sheetBody), findsNothing);
        expect(find.text(kPhoneA), findsNothing);
        expect((s.checkout.phoneDigits, s.checkout.challengeId), ('', null));
      });
    }
  });

  group('T-KIOSK-054 сброс без сети и повторы', () {
    testWidgets(
      'T-KIOSK-054 offline marker id only, first request on reconnect: в drift только id корзины, GET /cart и '
      'изменения не выполняются; связь — первым запросом POST /kiosk/reset, метка снята',
      (WidgetTester tester) async {
        final AppDatabase db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        bool offline = false;
        final KioskResetStand s = KioskResetStand(tester);
        final KioskCartSync sync = KioskCartSync(
          database: () => db,
          owner: () => _tablet,
          repository: s.carts,
          offline: () => offline,
        );
        addTearDown(sync.dispose);
        s.carts.onFetch = () async => Success<Cart>(_buyerCart(kCartId));
        await s.pump(
          control: sync,
          timings: const KioskTimings(idle: Duration(minutes: 30)),
        );
        expect((await sync.refresh()).valueOrNull?.items, hasLength(1), reason: 'корзина покупателя на экране');
        final int fetches = s.carts.calls.length;

        offline = true;
        s.online(OnlineStatus.offline);
        await tester.tap(find.byKey(ShowcaseKeys.startOver));
        await tester.pumpAndSettle();
        expect(await _meta(db), <(String, String)>[(AppMetaDao.kioskPendingResetCartIdKey, kCartId)]);
        expect(sync.pendingResetCartId, kCartId);
        expect(sync.cartId, isNull, reason: 'старый cartId не показывается');
        expect((await sync.loadLocal()).valueOrNull?.lines, isEmpty, reason: 'корзина на экране пуста');
        expect(s.f.repo.resetCalls, isEmpty, reason: 'без сети запроса нет');
        await tester.pump(const Duration(seconds: 80));
        expect(s.f.repo.resetCalls, isEmpty, reason: 'повторы без сети — без запроса');
        expect(s.carts.calls.length, fetches, reason: 'ни GET /cart, ни PUT/DELETE');

        offline = false;
        s.online(OnlineStatus.online);
        await tester.pumpAndSettle();
        expect(s.f.repo.resetCalls, <String>[kCartId], reason: 'первым запросом — POST /kiosk/reset с id метки');
        expect(s.carts.calls.length, fetches);
        expect(await _meta(db), isEmpty, reason: 'метка снята после 200');
        expect(sync.cartId, newCartId(1));
        expect(s.orchestrator.retryScheduled, isFalse);
      },
    );

    testWidgets('T-KIOSK-054 при запуске с меткой прошлого запуска первым запросом идёт POST /kiosk/reset; до ответа '
        'корзина пуста (FLOW-045.A1, SCR-51.11)', (WidgetTester tester) async {
      final AppDatabase db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await AppMetaDao(db).write(AppMetaDao.kioskPendingResetCartIdKey, kCartId);
      final KioskResetStand s = KioskResetStand(tester);
      final KioskCartSync sync = KioskCartSync(
        database: () => db,
        owner: () => _tablet,
        repository: s.carts,
        offline: () => false,
      );
      addTearDown(sync.dispose);
      s.carts.onFetch = () async => Success<Cart>(_buyerCart(kCartId));
      final Completer<Result<Cart>> answer = Completer<Result<Cart>>();
      s.f.repo.onReset = (String _) => answer.future;
      await s.pump(
        control: sync,
        timings: const KioskTimings(idle: Duration(minutes: 30)),
      );
      expect(s.f.repo.resetCalls, <String>[kCartId], reason: 'первый запрос корзины — сброс по метке');
      expect((sync.pendingResetCartId, sync.cartId), (kCartId, null), reason: 'до ответа корзина на экране пуста');
      expect(s.carts.calls, isEmpty, reason: 'GET /cart до сброса не выполняется');
      answer.complete(Success<Cart>(newEmptyCart(newCartId(1))));
      await tester.pumpAndSettle();
      expect(await _meta(db), isEmpty);
      expect(sync.cartId, newCartId(1));
    });

    testWidgets('T-KIOSK-054 повторы: через 5, 15, 60 с, затем раз в минуту; 403 и 426 — метка остаётся; 200 — метка '
        'снята, повторов нет (FLOW-045.E1)', (WidgetTester tester) async {
      final KioskResetStand s = KioskResetStand(tester);
      await s.pump(timings: const KioskTimings(idle: Duration(minutes: 30)));
      s.f.repo.onReset = (String _) async =>
          const FailureResult<Cart>(ServerFailure(code: 'KIOSK_NETWORK_DENIED', status: 403));
      await tester.tap(find.byKey(ShowcaseKeys.startOver));
      await tester.pump();
      expect(s.f.repo.resetCalls, hasLength(1));
      expect(s.cart.held, kCartId);
      Future<void> at(int seconds, int calls) async {
        await tester.pump(Duration(seconds: seconds - 1));
        expect(s.f.repo.resetCalls, hasLength(calls - 1), reason: 'раньше $seconds с — без повтора');
        await tester.pump(const Duration(seconds: 1));
        expect(s.f.repo.resetCalls, hasLength(calls), reason: 'повтор через $seconds с');
      }

      expect(KioskResetRetry.delays, const <Duration>[
        Duration(seconds: 5),
        Duration(seconds: 15),
        Duration(seconds: 60),
      ]);
      await at(5, 2);
      await at(15, 3);
      await at(60, 4);
      await at(60, 5);
      s.f.repo.onReset = (String _) async =>
          const FailureResult<Cart>(ServerFailure(code: 'APP_UPDATE_REQUIRED', status: 426));
      await at(60, 6);
      expect(s.cart.held, kCartId, reason: '426 — метка остаётся, корзина прошлого покупателя не показывается');
      s.f.repo.onReset = null;
      await at(60, 7);
      expect((s.cart.held, s.cart.cart), (null, newCartId(7)));
      expect(s.orchestrator.retryScheduled, isFalse);
      await tester.pump(const Duration(minutes: 5));
      expect(s.f.repo.resetCalls, hasLength(7));
      expect(s.f.repo.resetCalls.toSet(), <String>{kCartId}, reason: 'все повторы — с id метки');
    });

    testWidgets('404 (корзина не этого планшета или исчезла): закрыта текущая активная корзина — GET /cart и '
        'POST /kiosk/reset, её содержимое не показано', (WidgetTester tester) async {
      final KioskResetStand s = KioskResetStand(tester);
      await s.pump(timings: const KioskTimings(idle: Duration(minutes: 30)));
      const String other = '0192f3a1-6c3e-7a1b-9f00-000000000777';
      s.carts.onFetch = () async => Success<Cart>(_buyerCart(other));
      s.f.repo.onReset = (String id) async => id == kCartId
          ? const FailureResult<Cart>(ServerFailure(code: 'NOT_FOUND', status: 404))
          : Success<Cart>(newEmptyCart(newCartId(9)));
      await tester.tap(find.byKey(ShowcaseKeys.startOver));
      await tester.pumpAndSettle();
      expect(s.f.repo.resetCalls, <String>[kCartId, other]);
      expect(s.carts.calls.map((FakeCall c) => c.method), <String>['fetch']);
      expect((s.cart.held, s.cart.cart), (null, newCartId(9)));
      expect(s.orchestrator.retryScheduled, isFalse);
    });

    test('ключ метки — один: AppMetaDao.kioskPendingResetCartIdKey = KioskCartSync.pendingResetMetaKey', () {
      expect(AppMetaDao.kioskPendingResetCartIdKey, 'kiosk.pending_reset_cart_id');
      expect(KioskCartSync.pendingResetMetaKey, AppMetaDao.kioskPendingResetCartIdKey);
    });
  });

  group('T-KIOSK-029 данные покупателя после сброса', () {
    testWidgets(
      'T-KIOSK-029 no phone in state/drift/secure storage/logs, clipboard empty after reset (Clipboard.setData '
      'cleared)',
      (WidgetTester tester) async {
        final AppDatabase db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final KioskResetStand s = KioskResetStand(tester);
        final KioskCartSync sync = KioskCartSync(
          database: () => db,
          owner: () => _tablet,
          repository: s.carts,
          offline: () => false,
        );
        addTearDown(sync.dispose);
        s.carts.onFetch = () async => Success<Cart>(_buyerCart(kCartId));
        final InMemorySecureStorage storage = InMemorySecureStorage(<SecureKey, String>{
          SecureKey.kioskTabletId: '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4fb1',
          SecureKey.kioskTabletName: 'Планшет у входа',
          SecureKey.kioskUserId: _tablet,
        });
        final List<String> logs = <String>[];
        final Level level = Logger.root.level;
        Logger.root.level = Level.ALL;
        final StreamSubscription<LogRecord> records = Logger.root.onRecord.listen(
          (LogRecord r) => logs.add('${r.loggerName} ${r.message} ${r.error ?? ''}'),
        );
        final DebugPrintCallback print = debugPrint;
        debugPrint = (String? message, {int? wrapWidth}) => logs.add(message ?? '');
        try {
          await s.pump(control: sync, extra: [secureStorageProvider.overrideWithValue(storage)]);
          s.clipboard.text = '+996$kPhoneA';
          await sync.refresh();
          await _sheetThenCheckout(s);
          expect(s.checkout.codeDigits, kCode);

          await _idleReset(tester);

          _checkoutCleared(s);
          expect(s.checkout.toString(), allOf(isNot(contains(kPhoneA)), isNot(contains(kCode))));
          expect(s.f.repo.resetCalls, <String>[kCartId]);
          expect(sync.cartId, newCartId(1));
          final List<String> drift = await _driftValues(db);
          expect(drift.where((String v) => v.contains(kPhoneA) || v.contains(kCode)), isEmpty, reason: 'drift');
          expect(await _meta(db), isEmpty, reason: 'метка снята, других ключей нет');
          expect(
            storage.values.values.where((String v) => v.contains(kPhoneA) || v.contains(kCode)),
            isEmpty,
            reason: 'защищённое хранилище',
          );
          expect(logs.where((String l) => l.contains(kPhoneA) || l.contains(kCode)), isEmpty, reason: 'журналы');
          expect(s.clipboard.text, '', reason: 'буфер обмена пуст');
          expect(s.clipboard.sets, <String?>['']);
          expect(find.textContaining(kPhoneA.substring(6)), findsNothing, reason: 'номер не виден на экране');
        } finally {
          debugPrint = print;
          Logger.root.level = level;
          // Без `await`: отмена подписки корня журналов завершается вне поддельного времени теста.
          unawaited(records.cancel());
        }
      },
    );
  });

  group('провод DioKioskRepository.reset', () {
    test('POST /kiosk/reset {cartId}: тело — ключи контракта, без Idempotency-Key и автоповтора, ответ — Cart; 404 — '
        'NOT_FOUND; без кодека корзины — отказ без запроса', () async {
      final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
        final Map<String, Object?> body = o.data as Map<String, Object?>;
        if (o.method == 'POST' && o.uri.path == '/api/v1/kiosk/reset' && body['cartId'] == kCartId) {
          return json(200, <String, Object?>{
            'id': newCartId(1),
            'status': 'active',
            'items': <Object?>[],
            'rowVersion': 1,
          });
        }
        return json(404, problem('NOT_FOUND', 404));
      });
      final List<RequestOptions> sent = <RequestOptions>[];
      final Dio dio = Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))
        ..httpClientAdapter = adapter
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (RequestOptions o, RequestInterceptorHandler h) {
              sent.add(o);
              h.next(o);
            },
          ),
        );
      final DioKioskRepository repo = DioKioskRepository(dio, cart: const CartDtoDecoder());

      final Cart cart = (await repo.reset(kCartId)).valueOrNull!;
      expect((cart.id, cart.items.length, cart.rowVersion), (newCartId(1), 0, 1));
      expect((adapter.requests.single.method, adapter.requests.single.path), ('POST', '/kiosk/reset'));
      final Map<String, Object?> body = adapter.requests.single.data! as Map<String, Object?>;
      expect(body.keys.toSet(), DioKioskRepository.resetKeys);
      expect(body, <String, Object?>{'cartId': kCartId});
      expect(sent.single.idempotencyKey, isNull);
      expect(sent.single.retryProfile, RetryProfile.none);
      expect(sent.single.uri.query, isEmpty);

      final Failure missing = (await repo.reset('0192f3a1-6c3e-7a1b-9f00-000000000999')).failureOrNull!;
      expect((missing as ServerFailure).problemCode, ProblemCode.notFound);
      expect((await DioKioskRepository(dio).reset(kCartId)).failureOrNull, isA<UnknownFailure>());
      expect(adapter.requests, hasLength(2), reason: 'без кодека запрос не уходит');
    });
  });
}
