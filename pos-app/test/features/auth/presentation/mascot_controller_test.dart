// MascotController (02 §0.3; 03 §13.3–§13.5; D-40): 6 состояний, переходы по событиям,
// таймеры 1,5 с / 300 мс / 2 с / 15 с; reduce-motion → статичный кадр заглушки.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/auth/presentation/mascot/mascot.dart';
import 'package:optomstroy/features/auth/presentation/mascot/mascot_controller.dart';
import 'package:optomstroy/features/auth/presentation/mascot/success_check.dart';

void main() {
  testWidgets('T-AUTH-034: idle → typing (фокус) → verifying → success', (WidgetTester tester) async {
    final MascotController m = MascotController();
    addTearDown(m.dispose);
    expect(m.state, MascotState.idle);
    m.onFieldFocus(true);
    expect(m.state, MascotState.typing);
    expect(m.value.isTyping, isTrue);
    m.onRequestStarted();
    expect(m.state, MascotState.verifying);
    expect(m.value.isChecking, isTrue);
    final int before = m.value.successTrigger;
    m.onSuccess();
    expect(m.state, MascotState.success);
    expect(m.value.successTrigger, before + 1);
    expect(m.value.isChecking, isFalse);
  });

  testWidgets('неблокирующая ошибка: error → 1,5 с → retry → 300 мс → typing/idle', (WidgetTester tester) async {
    final MascotController m = MascotController();
    addTearDown(m.dispose);
    m
      ..onFieldFocus(true)
      ..onError(autoRetry: true);
    expect(m.state, MascotState.error);
    await tester.pump(const Duration(milliseconds: 1400));
    expect(m.state, MascotState.error);
    await tester.pump(const Duration(milliseconds: 200));
    expect(m.state, MascotState.retry);
    await tester.pump(const Duration(milliseconds: 300));
    expect(m.state, MascotState.typing);
  });

  testWidgets('блокирующая ошибка: без авто-retry, до действия пользователя', (WidgetTester tester) async {
    final MascotController m = MascotController();
    addTearDown(m.dispose);
    m.onError(autoRetry: false);
    await tester.pump(const Duration(seconds: 10));
    expect(m.state, MascotState.error);
    m.onUserRetry();
    expect(m.state, MascotState.retry);
    await tester.pump(const Duration(milliseconds: 300));
    expect(m.state, MascotState.idle);
  });

  testWidgets('ввод во время error → сразу typing (минуя retry)', (WidgetTester tester) async {
    final MascotController m = MascotController();
    addTearDown(m.dispose);
    m
      ..onFieldFocus(true)
      ..onError(autoRetry: true)
      ..onInput();
    expect(m.state, MascotState.typing);
    await tester.pump(const Duration(seconds: 2));
    expect(m.state, MascotState.typing, reason: 'отложенный retry отменён');
  });

  testWidgets('потеря фокуса > 2 с → idle; verifying ≤ 15 с → error', (WidgetTester tester) async {
    final MascotController m = MascotController();
    addTearDown(m.dispose);
    m
      ..onFieldFocus(true)
      ..onFieldFocus(false);
    await tester.pump(const Duration(milliseconds: 1900));
    expect(m.state, MascotState.typing);
    await tester.pump(const Duration(milliseconds: 200));
    expect(m.state, MascotState.idle);
    m.onRequestStarted();
    await tester.pump(MascotController.verifyingTimeout);
    expect(m.state, MascotState.error);
  });

  testWidgets('lookX/lookY ограничены −1…1; кивок не чаще 1/300 мс', (WidgetTester tester) async {
    final MascotController m = MascotController();
    addTearDown(m.dispose);
    m
      ..onFieldFocus(true)
      ..onCaret(3, -5);
    expect(m.value.lookX, 1);
    expect(m.value.lookY, -1);
    final DateTime t = DateTime.utc(2026);
    m.onInput(now: t);
    m.onInput(now: t.add(const Duration(milliseconds: 100)));
    m.onInput(now: t.add(const Duration(milliseconds: 400)));
    expect(m.value.nodTrigger, 2);
  });

  testWidgets('T-AUTH-035: reduce-motion: статичный кадр, без AnimatedSwitcher и scale галочки', (
    WidgetTester tester,
  ) async {
    final MascotController m = MascotController()..onSuccess();
    addTearDown(m.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Center(child: Mascot(controller: m)),
        ),
      ),
    );
    expect(find.byKey(PlaceholderMascotRenderer.staticFrameKey), findsOneWidget);
    expect(find.descendant(of: find.byKey(Mascot.rootKey), matching: find.byType(AnimatedSwitcher)), findsNothing);
    expect(find.byKey(SuccessCheck.rootKey), findsOneWidget);
    expect(
      find.ancestor(of: find.byKey(SuccessCheck.rootKey), matching: find.byType(Transform)),
      findsNothing,
      reason: 'галочка — crossfade без scale',
    );
    // Бесконечных анимаций нет: pumpAndSettle завершается (иначе — таймаут).
    expect(await tester.pumpAndSettle(), lessThan(5));
  });

  testWidgets('без reduce-motion: смена состояния через AnimatedSwitcher (250 мс)', (WidgetTester tester) async {
    final MascotController m = MascotController();
    addTearDown(m.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Center(child: Mascot(controller: m)),
      ),
    );
    expect(find.byKey(PlaceholderMascotRenderer.staticFrameKey), findsNothing);
    expect(find.byType(AnimatedSwitcher), findsOneWidget);
    m.onError(autoRetry: false);
    await tester.pumpAndSettle();
    expect(m.state, MascotState.error);
  });
}
