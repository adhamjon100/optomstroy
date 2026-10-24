// Widget: SCR-06 привязка к клиенту 1С (02 SCR-06, T-REG-018…020) и SCR-07 ожидание активации (T-REG-016),
// `RegistrationStepper` (03 §9.66, T-REG-002), `SuccessCheck` (03 §9.67).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';
import 'package:optomstroy/features/registration/presentation/screens/customer_link_screen.dart';
import 'package:optomstroy/features/registration/presentation/screens/pending_activation_screen.dart';
import 'package:optomstroy/features/registration/presentation/widgets/registration_stepper.dart';
import 'package:optomstroy/features/registration/presentation/widgets/success_check.dart';

import '../support/registration_fakes.dart';

const CustomerMatch _proposed = CustomerMatch(
  status: CustomerLinkStatus.proposed,
  nextStep: CustomerMatchNextStep.confirmOrReject,
  linkId: '3f0c2a8e-0000-4000-8000-000000000001',
  displayNameMasked: 'ОсОО «Стр***»',
);

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  group('SCR-06', () {
    testWidgets('proposed: маска, без финансов; «Да, это я» → confirmed → успех → главный экран', (tester) async {
      final h = RegistrationHarness()..repo.matchResult = const Success<CustomerMatch>(_proposed);
      await h.pump(tester, const CustomerLinkScreen());
      await tester.pump();
      expect(find.text('Шаг 3 из 4 · Привязка'), findsOneWidget);
      expect(find.text('Мы нашли вашу карточку клиента'), findsOneWidget);
      expect(find.text('ОсОО «Стр***»'), findsOneWidget);
      expect(find.text('Финансовые данные не показываются до подтверждения'), findsOneWidget);
      await tester.tap(find.byKey(CustomerLinkScreen.confirmKey));
      await tester.pump();
      expect(h.repo.resolveCalls.single.confirm, isTrue);
      expect(find.byKey(CustomerLinkScreen.successKey), findsOneWidget);
      expect(find.text('Карточка привязана'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      expect(h.navigator.events, <String>['home']);
      await _finish(tester);
    });

    testWidgets('«Нет, это не я» с подтверждением → rejected → как новый клиент', (tester) async {
      final h = RegistrationHarness()..repo.matchResult = const Success<CustomerMatch>(_proposed);
      await h.pump(tester, const CustomerLinkScreen());
      await tester.pump();
      await tester.tap(find.byKey(CustomerLinkScreen.rejectKey));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Это не ваша карточка?'), findsOneWidget);
      await tester.tap(find.text('Нет, это не я').last);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(h.repo.resolveCalls.single.confirm, isFalse);
      expect(h.navigator.events, <String>['home']);
      await _finish(tester);
    });

    testWidgets('conflict / wait_admin: кнопок решения нет; 409 CUSTOMER_LINK_CONFLICT → «Ожидает администратора»', (
      tester,
    ) async {
      final h = RegistrationHarness()
        ..repo.matchResult = const Success<CustomerMatch>(
          CustomerMatch(status: CustomerLinkStatus.conflict, nextStep: CustomerMatchNextStep.waitAdmin),
        );
      await h.pump(tester, const CustomerLinkScreen());
      await tester.pump();
      expect(find.text('Нужна помощь администратора'), findsOneWidget);
      expect(find.byKey(CustomerLinkScreen.confirmKey), findsNothing);
      expect(find.byKey(CustomerLinkScreen.continueKey), findsOneWidget);
      await _finish(tester);

      final h2 = RegistrationHarness()
        ..repo.matchResult = const Success<CustomerMatch>(_proposed)
        ..repo.resolveResult = failed(const ConflictFailure(ConflictKind.customerLinkConflict));
      await h2.pump(tester, const CustomerLinkScreen());
      await tester.pump();
      await tester.tap(find.byKey(CustomerLinkScreen.confirmKey));
      await tester.pump();
      expect(find.byKey(CustomerLinkScreen.waitAdminKey), findsOneWidget);
      expect(find.byKey(CustomerLinkScreen.confirmKey), findsNothing);
      await _finish(tester);
    });
  });

  group('SCR-07', () {
    testWidgets('ожидание → «Проверить статус» → active → снекбар и главный экран', (tester) async {
      final h = RegistrationHarness(selfService: false);
      h.repo.accountResults.addAll(<Result<AccountSnapshot>>[
        const Success<AccountSnapshot>(
          AccountSnapshot(
            status: 'pending_activation',
            roles: <String>[],
            fullName: 'Иванов Иван',
            phone: '+996555123456',
          ),
        ),
        const Success<AccountSnapshot>(AccountSnapshot(status: 'active', roles: <String>['seller'])),
      ]);
      await h.pump(tester, const PendingActivationScreen());
      await tester.pump();
      expect(find.text('Аккаунт ожидает активации'), findsOneWidget);
      expect(find.text('ожидает активации'), findsOneWidget);
      expect(find.text('+996 555 123 456'), findsOneWidget);
      await tester.tap(find.byKey(PendingActivationScreen.checkKey));
      await tester.pump();
      await tester.pump();
      expect(h.repo.accountCalls, 2);
      expect(find.text('Аккаунт активирован'), findsOneWidget);
      expect(h.navigator.events, <String>['home']);
      await _finish(tester);
    });

    testWidgets('blocked → «Аккаунт заблокирован», доступны только связь и выход', (tester) async {
      final h = RegistrationHarness(selfService: false);
      h.repo.accountResults.add(const Success<AccountSnapshot>(AccountSnapshot(status: 'blocked', roles: <String>[])));
      await h.pump(tester, const PendingActivationScreen());
      await tester.pump();
      expect(find.text('Аккаунт заблокирован'), findsOneWidget);
      expect(find.byKey(PendingActivationScreen.checkKey), findsNothing);
      await tester.tap(find.byKey(PendingActivationScreen.logoutKey));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Выйти из аккаунта').last);
      await tester.pump(const Duration(milliseconds: 300));
      expect(h.repo.logoutCalls, 1);
      expect(h.navigator.events, <String>['phone:logged_out']);
      await _finish(tester);
    });
  });

  group('RegistrationStepper', () {
    testWidgets('compact и horizontal; выполненные шаги кликабельны', (tester) async {
      final tapped = <RegistrationStep>[];
      await RegistrationHarness().pump(
        tester,
        Scaffold(
          body: Column(
            children: <Widget>[
              const RegistrationStepper(current: RegistrationStep.done, withCustomerLink: false, forceCompact: true),
              RegistrationStepper(
                current: RegistrationStep.security,
                withCustomerLink: true,
                forceCompact: false,
                onStepTap: tapped.add,
              ),
            ],
          ),
        ),
        size: const Size(1280, 800),
      );
      expect(find.text('Шаг 3 из 3 · Готово'), findsOneWidget);
      expect(find.text('Привязка'), findsOneWidget);
      await tester.tap(find.text('Данные'));
      await tester.pump();
      expect(tapped, <RegistrationStep>[RegistrationStep.data]);
      await tester.tap(find.text('Готово'));
      expect(tapped, hasLength(1), reason: 'предстоящие шаги не кликабельны');
      await _finish(tester);
    });

    testWidgets('SuccessCheck: reduce-motion — сразу финальный кадр и onCompleted', (tester) async {
      var completed = 0;
      await RegistrationHarness().pump(tester, Center(child: SuccessCheck(onCompleted: () => completed++)));
      await tester.pump();
      expect(completed, 1);
      await _finish(tester);
    });
  });
}
