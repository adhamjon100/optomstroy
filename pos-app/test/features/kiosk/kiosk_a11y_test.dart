// AC-A11Y-023 (03 A11Y-023, A11Y-003): правила Flutter `androidTapTargetGuideline` (тач-цели не меньше 48 × 48 lp) и
// `labeledTapTargetGuideline` (у каждой цели есть подпись) на экранах режима «Планшет магазина» — SCR-51 витрина с
// логотипом аварийного выхода (UI-51-002), полноэкранное состояние планшета UI-51-015 (`KioskStateView`, шапка —
// `KioskLogoHeader`), SCR-52 шаги «Телефон» и «Код» с экранной клавиатурой `KioskKeypad`, SCR-53 «Заявка отправлена» и
// открытый диалог аварийного выхода UI-51-017 — в окнах 1280 × 800 и 800 × 1280 при DPR 1, шрифт Inter.
//
// Долгое нажатие на логотип — служебный жест без подсказки (UI-51-002): в дереве доступности его нет, логотип для
// диктора — текст без действия, поэтому правило тач-цели к нему не применяется. Правило Flutter не проверяет узлы
// внутри прокручиваемой области (SCR-52) — высоту текстовых кнопок шагов проверяет kiosk_checkout_screens_test.dart.
// Стенд — `kiosk_screens_support.dart` (как golden T-KIOSK-010). Данные синтетические.
// Тест-кейс 12_TEST_PLAN: T-A11Y-023 (§3.9.5) — цели касания и метки; диалог автосброса того же кейса — группа
// «A11Y-023 …» kiosk_idle_monitor_test.dart.
import 'dart:async';

import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/router/kiosk_routes.dart';
import 'package:optomstroy/core/session/session_overlay.dart' show KioskStatus;
import 'package:optomstroy/design_system/components/kiosk_keypad.dart';
import 'package:optomstroy/features/catalog/presentation/screens/kiosk_catalog_view.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/kiosk_catalog_header.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_checkout_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_code_step.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_phone_step.dart';
import 'package:optomstroy/features/kiosk/presentation/done/kiosk_done_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/emergency_exit_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_state_view.dart';

import '../../design_system/ds_test_support.dart' show loadInterFont;
import 'checkout/kiosk_checkout_support.dart' as ks;
import 'kiosk_screens_support.dart';

Future<void> _frames(WidgetTester tester, {int count = 12}) async {
  for (int i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _keypad(WidgetTester tester, String digits) async {
  for (final String d in digits.split('')) {
    await tester.tap(find.byKey(KioskKeypad.keyFor(d)));
    await tester.pump();
  }
}

/// Открыть стенд в окне [size] при DPR 1.
Future<KioskScreensStand> _open(WidgetTester tester, Size size, {KioskStatus status = KioskStatus.ready}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final KioskScreensStand stand = KioskScreensStand(status: status);
  await tester.pumpWidget(stand.app(size));
  await _frames(tester);
  return stand;
}

Future<void> _toPhone(WidgetTester tester, KioskScreensStand stand) async {
  unawaited(stand.router.push<void>('${KioskPaths.checkout}?step=phone'));
  await _frames(tester);
  expect(find.byKey(KioskCheckoutScreen.screenKey), findsOneWidget);
  await _keypad(tester, ks.kPhoneA);
  await _frames(tester, count: 4);
}

Future<void> _toCode(WidgetTester tester, KioskScreensStand stand) async {
  await _toPhone(tester, stand);
  stand.checkout.repo.otpAnswers.add(ks.otpSent(ks.kChallengeA));
  await tester.tap(find.byKey(KioskPhoneStep.getCodeKey));
  await _frames(tester);
  expect(find.byKey(KioskCodeStep.fieldKey), findsOneWidget);
}

Future<void> _toDone(WidgetTester tester, KioskScreensStand stand) async {
  await _toCode(tester, stand);
  await _keypad(tester, ks.kCode);
  stand.checkout.repo.answerOrder(ks.orderAccepted());
  await tester.tap(find.byKey(KioskCodeStep.sendKey));
  await _frames(tester, count: 16);
  expect(find.byKey(KioskDoneScreen.screenKey), findsOneWidget);
}

/// Оба правила AC-A11Y-023 на текущем кадре.
Future<void> _guidelines(WidgetTester tester) async {
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
}

void main() {
  setUpAll(() async {
    EditableText.debugDeterministicCursor = true;
    await loadInterFont();
  });
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  for (final MapEntry<String, Size> w in kioskWindows.entries) {
    final String window = '${w.key} ${w.value.width.toInt()}×${w.value.height.toInt()}';

    testWidgets(
      'T-A11Y-023 · AC-A11Y-023 SCR-51 витрина ($window): логотип аварийного выхода, поиск, чип, «Начать заново», корзина, '
      'категории и карточки — цели ≥ 48 и с подписью',
      (tester) async {
        final SemanticsHandle semantics = tester.ensureSemantics();
        await _open(tester, w.value);
        expect(find.byKey(KioskCatalogKeys.root), findsOneWidget);
        expect(
          find.ancestor(of: find.byKey(KioskCatalogHeader.logoKey), matching: find.byType(KioskEmergencyExitTrigger)),
          findsOneWidget,
          reason: 'логотип — с аварийным выходом',
        );
        await _guidelines(tester);
        semantics.dispose();
      },
    );

    testWidgets(
      'T-A11Y-023 · AC-A11Y-023 UI-51-015 полноэкранное состояние ($window): шапка с логотипом аварийного выхода',
      (tester) async {
        final SemanticsHandle semantics = tester.ensureSemantics();
        await _open(tester, w.value, status: KioskStatus.networkDenied);
        expect(find.byKey(KioskStateView.fullScreenKey), findsOneWidget);
        expect(find.byType(KioskLogoHeader), findsOneWidget);
        expect(
          find.ancestor(of: find.byKey(KioskStateView.logoKey), matching: find.byType(KioskEmergencyExitTrigger)),
          findsOneWidget,
        );
        await _guidelines(tester);
        semantics.dispose();
      },
    );

    testWidgets('T-A11Y-023 · AC-A11Y-023 SCR-52 шаг «Телефон» ($window): экранная клавиатура и кнопки', (
      tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final KioskScreensStand stand = await _open(tester, w.value);
      await _toPhone(tester, stand);
      expect(find.byType(KioskKeypad), findsOneWidget);
      await _guidelines(tester);
      semantics.dispose();
    });

    testWidgets('T-A11Y-023 · AC-A11Y-023 SCR-52 шаг «Код» ($window): экранная клавиатура и кнопки', (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final KioskScreensStand stand = await _open(tester, w.value);
      await _toCode(tester, stand);
      expect(find.byType(KioskKeypad), findsOneWidget);
      await _guidelines(tester);
      semantics.dispose();
    });

    testWidgets('T-A11Y-023 · AC-A11Y-023 SCR-53 «Заявка отправлена» ($window): «Готово» и шапка с логотипом', (
      tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final KioskScreensStand stand = await _open(tester, w.value);
      await _toDone(tester, stand);
      expect(find.byType(KioskLogoHeader), findsOneWidget);
      await _guidelines(tester);
      semantics.dispose();
    });

    testWidgets('T-A11Y-023 · AC-A11Y-023 UI-51-017 диалог аварийного выхода ($window): клавиатура кода и кнопки', (
      tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await _open(tester, w.value);
      unawaited(showKioskEmergencyExit(tester.element(find.byKey(KioskCatalogKeys.root))));
      await _frames(tester);
      expect(find.byKey(KioskEmergencyExitDialog.dialogKey), findsOneWidget);
      await _guidelines(tester);
      // Закрыть диалог: следующий тест открывает его заново (повторное открытие при открытом игнорируется).
      await tester.tap(find.byKey(KioskEmergencyExitDialog.cancelKey));
      await _frames(tester);
      expect(find.byKey(KioskEmergencyExitDialog.dialogKey), findsNothing);
      semantics.dispose();
    });
  }
}
