// Монитор бездействия планшета магазина и диалог «Вы ещё здесь?» (02 ч. F SCR-51.4, UI-51-016, AC-UI-51-014;
// 03 §9.45 `countdown`, DS-103, AC-DS-103, A11Y-023; 04 FLOW-045.S1–S3; 10 KIOSK-020; 13 TAB-2-05) в маршрутах режима
// (`kioskRoutes()`, каркас `KioskShellScreen`) на поддельном времени:
// - 120 с без касаний — диалог с отсчётом 15 с, число уменьшается раз в секунду, конец отсчёта — сброс;
// - касание любого места и клавиша перезапускают таймер; «Продолжить», Esc, «Назад» и тап по затемнению — таймер
//   заново, данные покупателя сохраняются; «Начать заново» в диалоге — сброс;
// - таймер не идёт на SCR-53, пока открыт аварийный выход, во время «Отправляем заявку…», в полноэкранных
//   состояниях и без режима планшета;
// - вход в `426` или полноэкранное состояние (кроме отзыва) — сброс данных покупателя (FLOW-044.E3): SCR-51, память
//   оформления, слои; без сессии и при `403` запроса сброса нет, метка ждёт снятия состояния — затем первым запросом
//   корзины `POST /kiosk/reset`;
// - диктор и фокус (A11Y-023); один монитор на приложение, уход со всех экранов режима снимает таймеры.
// Тест-кейсы 12_TEST_PLAN: T-KIOSK-028 (автосброс по бездействию; остальные ветви — kiosk_reset_test.dart), T-KIOSK-054
// (сброс при полноэкранном состоянии и `426`, прикладная часть).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations_ru.dart';
import 'package:optomstroy/core/session/session_overlay.dart';
import 'package:optomstroy/features/kiosk/domain/kiosk_checkout.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_checkout_controller.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_checkout_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/done/kiosk_done_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/emergency_exit_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_idle_dialog.dart';

import '../../core/storage/in_memory_secure_storage.dart';
import 'checkout/kiosk_checkout_support.dart';
import 'kiosk_reset_support.dart';

final AppLocalizationsRu l10n = AppLocalizationsRu();

Finder get _dialog => find.byType(KioskIdleDialog);

String _body(WidgetTester tester) => tester.widget<Text>(find.byKey(KioskIdleDialog.bodyKey)).data!;

Future<void> _searched(WidgetTester tester) async {
  await tester.tap(find.byKey(ShowcaseKeys.search));
  await tester.pump();
  expect(find.text('q:смеситель'), findsOneWidget);
}

/// 120 с без касаний — диалог.
Future<void> _toWarning(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 120));
  await tester.pump();
  expect(_dialog, findsOneWidget);
}

void main() {
  group('T-KIOSK-028 автосброс по бездействию (монитор)', () {
    testWidgets('T-KIOSK-028 idle: 120 с без касаний — «Вы ещё здесь?» с отсчётом 15 с раз в секунду; конец отсчёта — '
        'сброс: POST /kiosk/reset, SCR-51 заново, буфер обмена пуст (AC-DS-103, AC-UI-51-014)', (
      WidgetTester tester,
    ) async {
      final KioskResetStand s = KioskResetStand(tester);
      await s.pump();
      await _searched(tester);
      expect(s.idle.isRunning, isTrue);

      await tester.pump(const Duration(seconds: 119));
      expect(_dialog, findsNothing, reason: 'до 120 с диалога нет');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(_dialog, findsOneWidget);
      expect(find.text(l10n.kiosk_idle_title), findsOneWidget);
      expect(_body(tester), l10n.kiosk_idle_body(15));
      expect(find.text(l10n.kiosk_idle_continue), findsOneWidget);
      expect(find.text(l10n.kiosk_start_over), findsOneWidget);
      expect(s.idle.warningShown, isTrue);

      for (int left = 14; left >= 1; left--) {
        await tester.pump(const Duration(seconds: 1));
        expect(_body(tester), l10n.kiosk_idle_body(left), reason: 'отсчёт раз в секунду');
      }
      expect(s.f.repo.resetCalls, isEmpty, reason: 'до конца отсчёта сброса нет');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(_dialog, findsNothing);
      expect(s.f.repo.resetCalls, <String>[kCartId], reason: 'POST /kiosk/reset {cartId}');
      expect(s.cart.cart, newCartId(1));
      expect(find.text('q:'), findsOneWidget, reason: 'тело витрины построено заново: поиска прежнего покупателя нет');
      expect(s.location, '/kiosk');
      expect(s.clipboard.sets, <String?>['']);
      expect(s.idle.isRunning, isTrue, reason: 'таймер следующего покупателя');
    });

    testWidgets('касание любого места и клавиша перезапускают таймер', (WidgetTester tester) async {
      final KioskResetStand s = KioskResetStand(tester);
      await s.pump();
      await tester.pump(const Duration(seconds: 100));
      await tester.tapAt(const Offset(900, 700));
      await tester.pump(const Duration(seconds: 100));
      expect(_dialog, findsNothing, reason: 'касание — отсчёт 120 с заново');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump(const Duration(seconds: 119));
      expect(_dialog, findsNothing, reason: 'клавиша подключённой клавиатуры — тоже');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(_dialog, findsOneWidget);
      expect(s.f.repo.resetCalls, isEmpty);
    });

    testWidgets('касание над листом без страницы (drawer, слой карточки) — тоже активность', (
      WidgetTester tester,
    ) async {
      final KioskResetStand s = KioskResetStand(tester);
      await s.pump();
      await tester.tap(find.byKey(ShowcaseKeys.sheet));
      await tester.pumpAndSettle();
      expect(find.byKey(ShowcaseKeys.sheetBody), findsOneWidget);
      await tester.pump(const Duration(seconds: 110));
      await tester.dragFrom(const Offset(1100, 400), const Offset(0, -80));
      await tester.pump(const Duration(seconds: 110));
      expect(_dialog, findsNothing);
      expect(s.idle.isRunning, isTrue);
    });

    for (final (String name, Future<void> Function(WidgetTester t) act)
        in <(String, Future<void> Function(WidgetTester))>[
          ('«Продолжить»', (WidgetTester t) => t.tap(find.byKey(KioskIdleDialog.continueKey))),
          ('Esc', (WidgetTester t) => t.sendKeyEvent(LogicalKeyboardKey.escape)),
          ('системное «Назад»', (WidgetTester t) => t.binding.handlePopRoute()),
          ('тап по затемнению', (WidgetTester t) => t.tapAt(const Offset(20, 20))),
        ]) {
      testWidgets('$name — таймер заново, данные покупателя сохраняются (AC-DS-103)', (WidgetTester tester) async {
        final KioskResetStand s = KioskResetStand(tester);
        await s.pump();
        await _searched(tester);
        await _toWarning(tester);
        await tester.pump(const Duration(seconds: 5));
        await act(tester);
        await tester.pumpAndSettle();
        expect(_dialog, findsNothing);
        expect(s.f.repo.resetCalls, isEmpty);
        expect(find.text('q:смеситель'), findsOneWidget);
        expect(s.clipboard.sets, isEmpty);
        expect(s.idle.isRunning, isTrue);
        await tester.pump(const Duration(seconds: 30));
        expect(_dialog, findsNothing, reason: 'прежний отсчёт снят');
        expect(s.f.repo.resetCalls, isEmpty);
        await tester.pump(const Duration(seconds: 90));
        await tester.pump();
        expect(_dialog, findsOneWidget, reason: 'новые 120 с');
      });
    }

    testWidgets('«Начать заново» в диалоге — сброс сразу (AC-DS-103)', (WidgetTester tester) async {
      final KioskResetStand s = KioskResetStand(tester);
      await s.pump();
      await _searched(tester);
      await _toWarning(tester);
      await tester.tap(find.byKey(KioskIdleDialog.startOverKey));
      await tester.pumpAndSettle();
      expect(_dialog, findsNothing);
      expect(s.f.repo.resetCalls, <String>[kCartId]);
      expect(find.text('q:'), findsOneWidget);
      expect(s.clipboard.sets, <String?>['']);
    });

    testWidgets('тайминги — из GET /settings/public (kioskTimingsProvider)', (WidgetTester tester) async {
      final KioskResetStand s = KioskResetStand(tester);
      await s.pump(
        timings: const KioskTimings(idle: Duration(seconds: 30), idleWarning: Duration(seconds: 5)),
      );
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(_body(tester), l10n.kiosk_idle_body(5));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(s.f.repo.resetCalls, <String>[kCartId]);
    });
  });

  group('когда таймер не идёт', () {
    testWidgets('SCR-53: свой таймер kiosk_done_seconds, диалога «Вы ещё здесь?» нет (02 SCR-53.4)', (
      WidgetTester tester,
    ) async {
      final KioskResetStand s = KioskResetStand(tester);
      await s.pump(timings: const KioskTimings(done: Duration(seconds: 600)));
      await s.submitOrder();
      s.router.go(KioskCheckoutLocations.done);
      await tester.pumpAndSettle();
      expect(find.byKey(KioskDoneScreen.numberKey), findsOneWidget);
      expect(s.idle.isRunning, isFalse);
      await tester.pump(const Duration(seconds: 300));
      expect(_dialog, findsNothing);
      expect(s.f.repo.resetCalls, isEmpty);
    });

    testWidgets('аварийный выход открыт — таймер не идёт; закрыт — 120 с заново', (WidgetTester tester) async {
      final KioskResetStand s = KioskResetStand(tester);
      await s.pump(extra: [secureStorageProvider.overrideWithValue(InMemorySecureStorage())]);
      await tester.pump(const Duration(seconds: 100));
      final BuildContext context = tester.element(find.byKey(ShowcaseKeys.root));
      final Future<void> exit = showKioskEmergencyExit(context);
      await tester.pumpAndSettle();
      expect(kioskEmergencyExitShown.value, isTrue);
      expect(s.idle.isRunning, isFalse);
      await tester.pump(const Duration(seconds: 300));
      expect(_dialog, findsNothing);
      await tester.tap(find.byKey(KioskEmergencyExitDialog.cancelKey));
      await tester.pumpAndSettle();
      await exit;
      expect(kioskEmergencyExitShown.value, isFalse);
      expect(s.idle.isRunning, isTrue);
      await tester.pump(const Duration(seconds: 119));
      expect(_dialog, findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(_dialog, findsOneWidget);
    });

    testWidgets(
      'FLOW-044.E3 полноэкранное состояние UI-51-015 — таймера нет, открытый диалог закрывается; вход в '
      'состояние — сброс данных покупателя без запроса `403`; снято — сброс по метке первым запросом, таймер заново',
      (WidgetTester tester) async {
        final KioskResetStand s = KioskResetStand(tester);
        await s.pump();
        await _searched(tester);
        await _toWarning(tester);
        s.status(KioskStatus.networkDenied);
        await tester.pumpAndSettle();
        expect(_dialog, findsNothing);
        expect(s.idle.isRunning, isFalse);
        expect(s.cart.held, kCartId, reason: 'метка сброса — сразу при входе в состояние');
        expect(s.f.repo.resetCalls, isEmpty, reason: 'сервер отказывает 403 — запрос сброса не уходит');
        await tester.pump(const Duration(seconds: 600));
        expect(s.f.repo.resetCalls, isEmpty, reason: 'повторов 403 раз в минуту нет');
        s.status(KioskStatus.ready);
        await tester.pumpAndSettle();
        expect(s.idle.isRunning, isTrue);
        expect(s.f.repo.resetCalls, <String>[kCartId], reason: 'снято — сброс по метке');
        expect(s.cart.held, isNull);
        expect(find.text('q:'), findsOneWidget, reason: 'витрина построена заново');
      },
    );

    testWidgets('UI-52-013 «Отправляем заявку…»: таймер бездействия не идёт, диалога «Вы ещё здесь?» нет (ключ '
        'идемпотентности для восстановления не теряется); отправка закончилась — таймер заново', (
      WidgetTester tester,
    ) async {
      final KioskResetStand s = KioskResetStand(tester);
      await s.pump();
      await s.enterPhoneAndCode();
      final Completer<Result<KioskOrderAccepted>> answer = Completer<Result<KioskOrderAccepted>>();
      s.f.repo.orderAnswers.add(() => answer.future);
      final Future<KioskCheckoutNav> sent = s.checkoutController.submit();
      await tester.pump();
      expect(s.checkout.sending, isTrue);
      expect(s.idle.isRunning, isFalse);
      await tester.pump(const Duration(minutes: 3));
      expect(_dialog, findsNothing, reason: 'обрыв связи во время отправки — сброса нет');
      expect(s.idle.isRunning, isFalse);
      expect(s.f.repo.resetCalls, isEmpty);

      answer.complete(refused(const ServerFailure(code: 'ONEC_REJECTED', status: 422)));
      await sent;
      await tester.pump();
      expect(s.checkout.sending, isFalse);
      expect(s.idle.isRunning, isTrue);
      await tester.pump(const Duration(seconds: 119));
      expect(_dialog, findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(_dialog, findsOneWidget, reason: 'после отправки — обычный таймер');
    });

    testWidgets('без режима планшета (сотрудник, SCR-50) — ни таймера, ни сброса при уходе в фон', (
      WidgetTester tester,
    ) async {
      final KioskResetStand s = KioskResetStand(tester);
      await s.pump();
      s.status(KioskStatus.none);
      await tester.pumpAndSettle();
      expect(s.idle.isRunning, isFalse);
      await s.toBackground();
      await s.toForeground();
      await tester.pump(const Duration(seconds: 600));
      expect(_dialog, findsNothing);
      expect(s.f.repo.resetCalls, isEmpty);
      expect(s.clipboard.sets, isEmpty);
    });
  });

  group('A11Y-023 и устройство монитора', () {
    testWidgets('A11Y-023: заголовок — имя маршрута, отсчёт объявляется при открытии, на 5 с и 0; фокус на '
        '«Продолжить»; ширина 480', (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final KioskResetStand s = KioskResetStand(tester);
      await s.pump();
      await _toWarning(tester);
      Semantics announcement() => tester.widget<Semantics>(find.byKey(KioskIdleDialog.announcementKey));
      expect(announcement().properties.liveRegion, isTrue);
      expect(announcement().properties.label, l10n.kiosk_idle_body(15));
      expect(tester.widget<Semantics>(find.byKey(KioskIdleDialog.dialogKey)).properties.namesRoute, isTrue);
      expect(tester.widget<Semantics>(find.byKey(KioskIdleDialog.dialogKey)).properties.label, l10n.kiosk_idle_title);
      await tester.pump(const Duration(seconds: 9));
      expect(_body(tester), l10n.kiosk_idle_body(6));
      expect(announcement().properties.label, l10n.kiosk_idle_body(15), reason: 'промежуточные секунды — без диктора');
      await tester.pump(const Duration(seconds: 1));
      expect(announcement().properties.label, l10n.kiosk_idle_body(5));
      await tester.pump(const Duration(seconds: 2));
      expect(announcement().properties.label, l10n.kiosk_idle_body(5));

      final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
      bool onContinue = false;
      focused?.visitAncestorElements((Element e) {
        if (e.widget.key == KioskIdleDialog.continueKey) {
          onContinue = true;
          return false;
        }
        return true;
      });
      expect(onContinue, isTrue, reason: 'фокус по умолчанию — «Продолжить»');
      expect(tester.getSize(find.byKey(KioskIdleDialog.dialogKey)).width, KioskIdleDialog.width);
      expect(s.f.repo.resetCalls, isEmpty);
      semantics.dispose();
    });

    test('A11Y-023: какое число объявляет диктор', () {
      expect(
        <int>[
          for (final int left in <int>[15, 9, 6, 5, 3, 1, 0]) KioskIdleDialog.announced(15, left),
        ],
        <int>[15, 15, 15, 5, 5, 5, 0],
      );
      expect(KioskIdleDialog.announced(5, 5), 5);
      expect(KioskIdleDialog.announced(3, 2), 3);
    });

    testWidgets('один монитор на приложение: SCR-52 поверх SCR-51 — один таймер; экраны режима закрыты — таймеры, '
        'подписки и наблюдатели сняты', (WidgetTester tester) async {
      final KioskResetStand s = KioskResetStand(tester);
      await s.pump();
      await tester.tap(find.byKey(ShowcaseKeys.checkout));
      await tester.pumpAndSettle();
      expect(find.byKey(KioskCheckoutScreen.screenKey), findsOneWidget);
      await tester.pump(const Duration(seconds: 120));
      await tester.pump();
      expect(_dialog, findsOneWidget, reason: 'автосброс действует и на SCR-52');
      await tester.tap(find.byKey(KioskIdleDialog.continueKey));
      await tester.pumpAndSettle();
      expect(s.orchestrator.isActive, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(s.idle.isRunning, isFalse);
      expect(s.idle.warningShown, isFalse);
      expect(s.orchestrator.isActive, isFalse);
      await tester.pump(const Duration(seconds: 600));
      expect(s.f.repo.resetCalls, isEmpty);
    });
  });
}
