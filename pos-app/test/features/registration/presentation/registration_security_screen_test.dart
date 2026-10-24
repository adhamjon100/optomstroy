// Widget: SCR-04 «Защита входа» + шаг «Готово» (02 AC-UI-04-001…021, 022; 13 RM-D-008 критерии 2–3;
// T-REG-009, T-REG-010, T-BIO-015). Биометрия устройства — мок порта.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';
import 'package:optomstroy/features/registration/presentation/controllers/registration_flow_controller.dart';
import 'package:optomstroy/features/registration/presentation/screens/registration_security_screen.dart';
import 'package:optomstroy/features/registration/presentation/widgets/step_up_pin_dialog.dart';

import '../support/registration_fakes.dart';

bool _enabled(WidgetTester tester) =>
    tester.widget<AppButton>(find.byKey(RegistrationSecurityScreen.completeKey)).onPressed != null;

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 2));
}

/// Черновик шага «Данные» уже заполнен (SCR-03 пройден).
void _fillDraft(RegistrationHarness h) {
  h.container.read(registrationFlowProvider.notifier)
    ..setFullName('Иванов Иван')
    ..setBirthYear('1990')
    ..setPersonalDataAck(true);
}

Future<void> _pin(WidgetTester tester, String pin) => enterPin(tester, pin, within: find.byType(PinField).first);

Future<void> _tapComplete(WidgetTester tester) async {
  await tester.tap(find.byKey(RegistrationSecurityScreen.completeKey));
  await tester.pump();
  await tester.pump();
}

void main() {
  group('Первый вход сотрудника (staff, D-48)', () {
    testWidgets('без PIN «Начать работу» недоступна; индикатора шагов нет (критерий 2, AC-UI-04-001, 022)', (
      tester,
    ) async {
      final h = RegistrationHarness(withTicket: false);
      await h.pump(tester, const RegistrationSecurityScreen(audience: RegistrationAudience.staffFirstLogin));
      expect(find.text('Задайте PIN-код для работы'), findsOneWidget);
      expect(find.textContaining('Шаг '), findsNothing);
      expect(find.byKey(RegistrationSecurityScreen.pinSwitchKey), findsNothing, reason: 'PIN нельзя выключить');
      expect(tester.widget<PinField>(find.byType(PinField)).length, 6);
      expect(_enabled(tester), isFalse);
      await _tapComplete(tester);
      expect(h.repo.setPinCalls, isEmpty);

      await _pin(tester, '483920');
      await _pin(tester, '483920');
      expect(_enabled(tester), isFalse, reason: 'нужна отметка ознакомления с обработкой ПДн');
      await tester.tap(find.byKey(RegistrationSecurityScreen.pdAckKey));
      await tester.pump();
      expect(_enabled(tester), isTrue);
      await _tapComplete(tester);
      expect(h.repo.setPinCalls, <String>['483920']);
      expect(h.repo.consentCalls, 1);
      expect(find.byKey(RegistrationSecurityScreen.doneKey), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.navigator.events, <String>['home']);
      await _finish(tester);
    });

    testWidgets('слабый PIN и несовпадение — локальные ошибки (AC-UI-04-002, 003)', (tester) async {
      final h = RegistrationHarness(withTicket: false);
      await h.pump(tester, const RegistrationSecurityScreen(audience: RegistrationAudience.staffFirstLogin));
      await _pin(tester, '123456');
      expect(find.text('Выберите PIN без повторяющихся или последовательных цифр'), findsOneWidget);
      await _pin(tester, '483920');
      expect(find.text('Повторите PIN-код'), findsOneWidget);
      await _pin(tester, '483921');
      expect(find.text('PIN-коды не совпадают'), findsOneWidget);
      expect(find.text('Придумайте PIN-код'), findsOneWidget, reason: 'очистка обоих, фокус в первое поле');
      await _finish(tester);
    });
  });

  group('Регистрация клиента', () {
    testWidgets(
      'нет биометрии → PIN обязателен (4 цифры); один запрос с Idempotency-Key; «Готово» (AC-UI-04-006, 008, 009)',
      (tester) async {
        final h = RegistrationHarness();
        await h.pump(tester, const RegistrationSecurityScreen());
        _fillDraft(h);
        await tester.pump();
        expect(find.text('Шаг 2 из 4 · Защита входа'), findsOneWidget);
        expect(find.text('Недоступно на этом устройстве'), findsOneWidget);
        expect(find.byKey(RegistrationSecurityScreen.pinSwitchKey), findsNothing, reason: 'PIN нельзя выключить');
        expect(tester.widget<PinField>(find.byType(PinField)).length, 4);
        expect(_enabled(tester), isFalse);
        await _pin(tester, '4839');
        await _pin(tester, '4839');
        expect(_enabled(tester), isTrue);
        await tester.tap(find.byKey(RegistrationSecurityScreen.completeKey));
        await tester.tap(find.byKey(RegistrationSecurityScreen.completeKey), warnIfMissed: false);
        await tester.pump();
        await tester.pump();
        expect(h.repo.completeCalls, hasLength(1), reason: 'двойное нажатие — один запрос');
        final call = h.repo.completeCalls.single;
        expect(call.key, 'key-1');
        expect(call.request.pin, '4839');
        expect(call.request.biometricsEnabled, isFalse);
        expect(h.drafts.clears, 1, reason: 'черновик удалён после 201');
        expect(find.text('Добро пожаловать, Иван!'), findsOneWidget);
        expect(find.text('Вход настроен: PIN-код'), findsOneWidget);
        expect(find.text('Войти'), findsNothing, reason: 'автоматический вход без кнопки «Войти»');
        await tester.pump(const Duration(milliseconds: 400));
        expect(h.navigator.events, <String>['home']);
        await _finish(tester);
      },
    );

    testWidgets('T-REG-013 (widget): сеть пропала → баннер и «Повторить» с тем же ключом (AC-UI-04-016, SRC-B-137)', (
      tester,
    ) async {
      final h = RegistrationHarness();
      h.repo.completeResults.add(failed(const NetworkFailure(NetworkFailureKind.timeout, outcomeUnknown: true)));
      await h.pump(tester, const RegistrationSecurityScreen());
      _fillDraft(h);
      await _pin(tester, '4839');
      await _pin(tester, '4839');
      await _tapComplete(tester);
      expect(find.text('Не удалось завершить регистрацию. Данные сохранены — повторите'), findsOneWidget);
      expect(_enabled(tester), isTrue, reason: 'PIN не очищен');
      await tester.tap(find.text('Повторить'));
      await tester.pump();
      await tester.pump();
      expect(h.repo.completeCalls.map((c) => c.key), <String>['key-1', 'key-1']);
      expect(find.byKey(RegistrationSecurityScreen.doneKey), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('REGISTRATION_TOKEN_INVALID → диалог «Время регистрации истекло» → SCR-01 (AC-UI-04-011)', (
      tester,
    ) async {
      final h = RegistrationHarness();
      h.repo.completeResults.add(failed(const AuthFailure(AuthReason.registrationTokenInvalid)));
      await h.pump(tester, const RegistrationSecurityScreen());
      _fillDraft(h);
      await _pin(tester, '4839');
      await _pin(tester, '4839');
      await _tapComplete(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text('Время регистрации истекло. Подтвердите номер ещё раз — введённые данные сохранятся'),
        findsOneWidget,
      );
      await tester.tap(find.text('Подтвердить номер снова').last);
      await tester.pump(const Duration(milliseconds: 300));
      expect(h.navigator.events, <String>['phone:registration_expired']);
      expect(h.drafts.clears, 0, reason: 'черновик сохраняется до нового OTP');
      await _finish(tester);
    });

    testWidgets('PHONE_ALREADY_REGISTERED → SCR-01 «номер уже зарегистрирован» (AC-UI-04-012)', (tester) async {
      final h = RegistrationHarness();
      h.repo.completeResults.add(failed(const ConflictFailure(ConflictKind.phoneAlreadyRegistered)));
      await h.pump(tester, const RegistrationSecurityScreen());
      _fillDraft(h);
      await _pin(tester, '4839');
      await _pin(tester, '4839');
      await _tapComplete(tester);
      expect(h.navigator.events, <String>['phone:phone_registered']);
      await _finish(tester);
    });

    testWidgets('без сети кнопка недоступна с подсказкой (AC-UI-04-016)', (tester) async {
      final h = RegistrationHarness(online: false);
      await h.pump(tester, const RegistrationSecurityScreen());
      _fillDraft(h);
      await _pin(tester, '4839');
      await _pin(tester, '4839');
      expect(find.text('Нужна сеть, чтобы завершить регистрацию'), findsOneWidget);
      expect(_enabled(tester), isFalse);
      await _finish(tester);
    });

    testWidgets(
      'T-BIO-001 (widget), T-REG-025 (б): биометрия: выкл. по умолчанию; с согласием → токен под ключом, «PIN-код · биометрия» (AC-UI-04-005)',
      (tester) async {
        final h = RegistrationHarness(biometrics: FakeDeviceBiometrics());
        await h.pump(tester, const RegistrationSecurityScreen());
        _fillDraft(h);
        await tester.pump();
        expect(find.byKey(RegistrationSecurityScreen.bioConsentKey), findsNothing);
        await tester.tap(find.byKey(RegistrationSecurityScreen.bioSwitchKey));
        await tester.pump();
        await tester.tap(find.byKey(RegistrationSecurityScreen.bioConsentKey));
        await tester.pump();
        await _pin(tester, '4839');
        await _pin(tester, '4839');
        await _tapComplete(tester);
        await tester.pump();
        final req = h.repo.completeCalls.single.request;
        expect(req.biometricsEnabled, isTrue);
        expect(req.consents.map((c) => c.kind), contains('biometrics_device'));
        expect(h.biometrics.bound, <String>['bio-refresh']);
        expect(find.text('Вход настроен: PIN-код · биометрия'), findsOneWidget);
        await _finish(tester);
      },
    );

    testWidgets('отмена системного диалога → снекбар «Биометрия не включена», вход по PIN (AC-UI-04-013)', (
      tester,
    ) async {
      final h = RegistrationHarness(biometrics: FakeDeviceBiometrics(bindResult: BiometricEnrollmentResult.cancelled));
      await h.pump(tester, const RegistrationSecurityScreen());
      _fillDraft(h);
      await tester.pump();
      await tester.tap(find.byKey(RegistrationSecurityScreen.bioSwitchKey));
      await tester.pump();
      await tester.tap(find.byKey(RegistrationSecurityScreen.bioConsentKey));
      await tester.pump();
      await _pin(tester, '4839');
      await _pin(tester, '4839');
      await _tapComplete(tester);
      await tester.pump();
      expect(find.text('Биометрия не включена. Вход — по PIN-коду. Включить можно в настройках'), findsOneWidget);
      expect(find.text('Вход настроен: PIN-код'), findsOneWidget);
      expect(h.repo.disableCalls, 1, reason: 'неиспользованная биометрическая семья отозвана');
      expect(h.biometrics.discards, 1);
      await _finish(tester);
    });

    testWidgets('только биометрия, не включилась → обязательный PIN, затем «Готово» (AC-UI-04-020, 021)', (
      tester,
    ) async {
      final h = RegistrationHarness(biometrics: FakeDeviceBiometrics(bindResult: BiometricEnrollmentResult.cancelled));
      await h.pump(tester, const RegistrationSecurityScreen());
      _fillDraft(h);
      await tester.pump();
      // PIN нельзя выключить, пока биометрия не включена с согласием.
      await tester.tap(find.byKey(RegistrationSecurityScreen.pinSwitchKey));
      await tester.pump();
      expect(find.text('Выберите способ защиты входа: PIN-код или биометрию'), findsOneWidget);
      await tester.tap(find.byKey(RegistrationSecurityScreen.bioSwitchKey));
      await tester.pump();
      await tester.tap(find.byKey(RegistrationSecurityScreen.bioConsentKey));
      await tester.pump();
      await tester.tap(find.byKey(RegistrationSecurityScreen.pinSwitchKey));
      await tester.pump();
      expect(find.byType(PinField), findsNothing);
      expect(_enabled(tester), isTrue);
      await _tapComplete(tester);
      await tester.pump();
      expect(h.repo.completeCalls.single.request.pin, isNull);
      expect(find.text('Биометрия не включена. Задайте PIN-код, чтобы входить в приложение'), findsOneWidget);
      expect(find.byKey(RegistrationSecurityScreen.doneKey), findsNothing);
      await _pin(tester, '4839');
      await _pin(tester, '4839');
      await _tapComplete(tester);
      expect(h.repo.setPinCalls, <String>['4839']);
      expect(find.byKey(RegistrationSecurityScreen.doneKey), findsOneWidget);
      await _finish(tester);
    });

    testWidgets(
      'STEP_UP_REQUIRED → диалог PIN; PIN_INVALID показывает attemptsLeft сервера (критерий 3, AC-UI-04-018)',
      (tester) async {
        final h = RegistrationHarness(biometrics: FakeDeviceBiometrics());
        h.repo.enableResults.add(
          failed(const AuthFailure(AuthReason.stepUpRequired, stepUpOperation: 'profile.biometrics.toggle')),
        );
        h.repo.stepUpResults.add(failed(const AuthFailure(AuthReason.pinInvalid, attemptsLeft: 2)));
        await h.pump(tester, const RegistrationSecurityScreen());
        _fillDraft(h);
        await tester.pump();
        await tester.tap(find.byKey(RegistrationSecurityScreen.bioSwitchKey));
        await tester.pump();
        await tester.tap(find.byKey(RegistrationSecurityScreen.bioConsentKey));
        await tester.pump();
        await _pin(tester, '4839');
        await _pin(tester, '4839');
        await _tapComplete(tester);
        await tester.pump();
        expect(find.byKey(StepUpPinDialog.dialogKey), findsOneWidget);
        expect(
          find.descendant(of: find.byKey(StepUpPinDialog.dialogKey), matching: find.byIcon(Icons.fingerprint_rounded)),
          findsNothing,
          reason: 'в step-up R1 нет кнопки биометрии',
        );
        await enterPin(tester, '4831', within: find.byKey(StepUpPinDialog.dialogKey));
        await tester.pump();
        expect(find.text('Неверный PIN. Осталось попыток: 2'), findsOneWidget);
        await enterPin(tester, '4839', within: find.byKey(StepUpPinDialog.dialogKey));
        await tester.pump();
        await tester.pump();
        expect(h.repo.stepUpCalls.map((c) => c.pin), <String>['4831', '4839']);
        expect(h.repo.enableCalls, <String?>[null, 'step-up-token']);
        expect(find.byKey(StepUpPinDialog.dialogKey), findsNothing);
        expect(find.text('Вход настроен: PIN-код · биометрия'), findsOneWidget);
        await _finish(tester);
      },
    );

    testWidgets('PIN_LOCKED при step-up → регистрация завершена без биометрии (критерий 3)', (tester) async {
      final h = RegistrationHarness(biometrics: FakeDeviceBiometrics());
      h.repo.enableResults.add(failed(const AuthFailure(AuthReason.stepUpRequired)));
      h.repo.stepUpResults.add(failed(const AuthFailure(AuthReason.pinLocked)));
      await h.pump(tester, const RegistrationSecurityScreen());
      _fillDraft(h);
      await tester.pump();
      await tester.tap(find.byKey(RegistrationSecurityScreen.bioSwitchKey));
      await tester.pump();
      await tester.tap(find.byKey(RegistrationSecurityScreen.bioConsentKey));
      await tester.pump();
      await _pin(tester, '4839');
      await _pin(tester, '4839');
      await _tapComplete(tester);
      await tester.pump();
      await enterPin(tester, '4831', within: find.byKey(StepUpPinDialog.dialogKey));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(StepUpPinDialog.dialogKey), findsNothing);
      expect(find.text('Биометрия не включена. Вход — по PIN-коду. Включить можно в настройках'), findsOneWidget);
      expect(find.text('Вход настроен: PIN-код'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('pending_activation → SCR-07; proposed → SCR-06 (AC-UI-04-010, 017)', (tester) async {
      final h = RegistrationHarness();
      h.repo.completeResults.add(
        const Success<RegistrationOutcome>(
          RegistrationOutcome(accountStatus: RegistrationAccountStatus.pendingActivation, userKind: 'staff', roles: []),
        ),
      );
      await h.pump(tester, const RegistrationSecurityScreen());
      _fillDraft(h);
      await _pin(tester, '4839');
      await _pin(tester, '4839');
      await _tapComplete(tester);
      expect(find.text('Аккаунт создан. Администратор магазина активирует его и назначит роль'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.navigator.events, <String>['pending']);
      await _finish(tester);

      final h2 = RegistrationHarness();
      h2.repo.completeResults.add(
        const Success<RegistrationOutcome>(
          RegistrationOutcome(
            accountStatus: RegistrationAccountStatus.authenticated,
            userKind: 'customer',
            roles: <String>['customer'],
            customerMatch: CustomerMatch(
              status: CustomerLinkStatus.proposed,
              nextStep: CustomerMatchNextStep.confirmOrReject,
              linkId: 'l1',
            ),
          ),
        ),
      );
      await h2.pump(tester, const RegistrationSecurityScreen());
      _fillDraft(h2);
      await _pin(tester, '4839');
      await _pin(tester, '4839');
      await _tapComplete(tester);
      await tester.tap(find.byKey(RegistrationSecurityScreen.doneKey));
      await tester.pump();
      expect(h2.navigator.events, <String>['customerLink'], reason: 'тап — немедленный переход');
      await _finish(tester);
    });
  });
}
