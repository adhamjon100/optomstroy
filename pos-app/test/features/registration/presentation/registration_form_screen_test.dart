// Widget: SCR-03 «Данные» (02 AC-UI-03-002…005, 007, 008, 011, 016; T-REG-002…007).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';
import 'package:optomstroy/features/registration/presentation/controllers/registration_flow_controller.dart';
import 'package:optomstroy/features/registration/presentation/screens/registration_form_screen.dart';

import '../support/registration_fakes.dart';

Finder _input(Key key) => find.descendant(of: find.byKey(key), matching: find.byType(EditableText));

bool _enabled(WidgetTester tester) =>
    tester.widget<AppButton>(find.byKey(RegistrationFormScreen.continueKey)).onPressed != null;

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('T-REG-023: индикатор «Шаг 1 из 4 · Данные» (R1) и «Шаг 1 из 3» без самообслуживания (AC-UI-03-002)', (
    tester,
  ) async {
    await RegistrationHarness().pump(tester, const RegistrationFormScreen());
    expect(find.text('Шаг 1 из 4 · Данные'), findsOneWidget);
    await _finish(tester);

    await RegistrationHarness(selfService: false).pump(tester, const RegistrationFormScreen());
    expect(find.text('Шаг 1 из 3 · Данные'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('T-REG-004: поля формы, телефон только для чтения с «подтверждён» (AC-UI-03-001, 007)', (tester) async {
    await RegistrationHarness().pump(tester, const RegistrationFormScreen());
    expect(find.text('ФИО *'), findsOneWidget);
    expect(find.text('Год рождения *'), findsOneWidget);
    expect(find.text('Сфера деятельности (необязательно)'), findsOneWidget);
    expect(find.text('+996 555 123 456'), findsOneWidget);
    expect(find.text('подтверждён'), findsOneWidget);
    final phone = tester.widget<EditableText>(_input(RegistrationFormScreen.phoneFieldKey));
    expect(phone.readOnly, isTrue);
    await _finish(tester);
  });

  testWidgets('«Продолжить» неактивна до ФИО + 4 цифр года + «Я ознакомлен(а)» (AC-UI-03-003)', (tester) async {
    final h = RegistrationHarness();
    await h.pump(tester, const RegistrationFormScreen());
    expect(_enabled(tester), isFalse);
    await tester.enterText(_input(RegistrationFormScreen.nameFieldKey), 'Каримов Абдулла');
    await tester.enterText(_input(RegistrationFormScreen.yearFieldKey), '1990');
    await tester.pump();
    expect(_enabled(tester), isFalse, reason: 'нет отметки ознакомления');
    await tester.tap(find.byKey(RegistrationFormScreen.pdAckKey));
    await tester.pump();
    expect(_enabled(tester), isTrue);
    await tester.tap(find.byKey(RegistrationFormScreen.continueKey));
    await tester.pump();
    expect(h.navigator.events, <String>['security']);
    expect(h.drafts.stored?.step, RegistrationStep.security);
    expect(h.drafts.stored?.fullName, 'Каримов Абдулла');
    await _finish(tester);
  });

  testWidgets('цифры в ФИО не вводятся; год вне диапазона — ошибка (AC-UI-03-004, 005)', (tester) async {
    final h = RegistrationHarness();
    await h.pump(tester, const RegistrationFormScreen());
    await tester.enterText(_input(RegistrationFormScreen.nameFieldKey), 'Каримов1 Абдулла2');
    await tester.pump();
    expect(h.container.read(registrationFlowProvider).draft.fullName, 'Каримов Абдулла');
    await tester.enterText(_input(RegistrationFormScreen.yearFieldKey), '2020');
    await tester.tap(find.byKey(RegistrationFormScreen.pdAckKey));
    await tester.pump();
    await tester.tap(find.byKey(RegistrationFormScreen.continueKey));
    await tester.pump();
    expect(find.text('Введите год от 1920 до 2012'), findsOneWidget);
    expect(h.navigator.events, isEmpty);
    await tester.enterText(_input(RegistrationFormScreen.yearFieldKey), '1919');
    await tester.pump();
    expect(find.text('Введите год от 1920 до 2012'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('сфера: необязательное согласие появляется только при выборе (AC-UI-03-008)', (tester) async {
    final h = RegistrationHarness();
    await h.pump(tester, const RegistrationFormScreen());
    expect(find.byKey(RegistrationFormScreen.sphereConsentKey), findsNothing);
    h.container.read(registrationFlowProvider.notifier).setActivitySphere(ActivitySphere.other);
    await tester.pump();
    expect(find.byKey(RegistrationFormScreen.sphereConsentKey), findsOneWidget);
    expect(find.byKey(RegistrationFormScreen.otherFieldKey), findsOneWidget, reason: 'AC-UI-03-009');
    expect(find.text('Без согласия сфера деятельности не будет сохранена'), findsOneWidget);
    h.container.read(registrationFlowProvider.notifier).setActivitySphere(null);
    await tester.pump();
    expect(find.byKey(RegistrationFormScreen.sphereConsentKey), findsNothing);
    await _finish(tester);
  });

  testWidgets('T-REG-013 (widget): черновик подставляется после нового OTP + баннер «восстановили» (AC-UI-03-011)', (
    tester,
  ) async {
    final h = RegistrationHarness(
      drafts: FakeDraftRepository(
        const RegistrationDraft(fullName: 'Иванов Иван', birthYear: '1990', personalDataAck: true),
      ),
    );
    await h.pump(tester, const RegistrationFormScreen());
    expect(find.byKey(RegistrationFormScreen.restoredBannerKey), findsOneWidget);
    expect(find.text('Иванов Иван'), findsOneWidget);
    expect(_enabled(tester), isTrue);
    await _finish(tester);
  });

  testWidgets('без registration_token → SCR-01 (guard G-2)', (tester) async {
    final h = RegistrationHarness();
    await h.pump(tester, const RegistrationFormScreen());
    await _finish(tester);
    final h2 = RegistrationHarness(withTicket: false);
    await h2.pump(tester, const RegistrationFormScreen());
    expect(h2.navigator.events, <String>['phone:registration_expired']);
    await _finish(tester);
  });

  testWidgets('таймер 15 мин; по нулю — диалог «Время регистрации истекло» → SCR-01 (AC-UI-03-010)', (tester) async {
    final h = RegistrationHarness(ticket: testTicket(ttl: const Duration(seconds: 2)));
    await h.pump(tester, const RegistrationFormScreen());
    expect(find.text('Время на регистрацию: ещё 00:02'), findsOneWidget);
    h.clock.advance(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(
      find.text('Время регистрации истекло. Подтвердите номер ещё раз — введённые данные сохранятся'),
      findsOneWidget,
    );
    await tester.tap(find.text('Подтвердить номер снова').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(h.navigator.events, contains('phone:registration_expired'));
    await _finish(tester);
  });
}
