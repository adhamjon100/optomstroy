// Unit: валидация SCR-03/SCR-04 (09 §7.1, §9.6; 02 AC-UI-03-003…005, AC-UI-04-002), сборка тела
// POST /registration/complete (08 §4.2.1; AC-UI-03-008, AC-UI-04-019), сценарий включения биометрии.
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';
import 'package:optomstroy/features/registration/domain/repositories/registration_repositories.dart';
import 'package:optomstroy/features/registration/domain/usecases/registration_usecases.dart';
import 'package:optomstroy/features/registration/domain/usecases/registration_validation.dart';

import '../support/registration_fakes.dart';

const BiometricPromptCopy _copy = BiometricPromptCopy(title: 't', cancel: 'c');

void main() {
  group('ФИО (T-REG-003)', () {
    test('обязательно, 2–120 символов, только буквы/пробел/дефис/апостроф', () {
      expect(RegistrationValidation.checkFullName('   ').error, FullNameError.required);
      expect(RegistrationValidation.checkFullName('А').error, FullNameError.length);
      expect(RegistrationValidation.checkFullName('А' * 121).error, FullNameError.length);
      expect(RegistrationValidation.checkFullName('Иванов 2').error, FullNameError.invalid);
      expect(RegistrationValidation.checkFullName('Абдуллаев Абдулла').isValid, isTrue);
      expect(RegistrationValidation.checkFullName("O'Neil-Smith John").isValid, isTrue);
      expect(RegistrationValidation.checkFullName('Үсөнов Ңурбек').isValid, isTrue, reason: 'кыргызские буквы');
    });

    test('одно слово — предупреждение, не ошибка (AC-UI-03-005)', () {
      final check = RegistrationValidation.checkFullName('Каримов');
      expect(check.isValid, isTrue);
      expect(check.oneWordWarning, isTrue);
      expect(RegistrationValidation.checkFullName('Каримов Абдулла').oneWordWarning, isFalse);
    });

    test('схлопывание пробелов и trim', () {
      expect(RegistrationValidation.normalizeFullName('  Каримов   Абдулла '), 'Каримов Абдулла');
    });
  });

  group('Год рождения (T-REG-005)', () {
    test('1920 ≤ год ≤ текущий − 14', () {
      expect(RegistrationValidation.checkBirthYear('', currentYear: 2026), BirthYearError.required);
      expect(RegistrationValidation.checkBirthYear('1919', currentYear: 2026), BirthYearError.range);
      expect(RegistrationValidation.checkBirthYear('1920', currentYear: 2026), isNull);
      expect(RegistrationValidation.checkBirthYear('2012', currentYear: 2026), isNull);
      expect(RegistrationValidation.checkBirthYear('2013', currentYear: 2026), BirthYearError.range);
      expect(RegistrationValidation.checkBirthYear('2020', currentYear: 2026), BirthYearError.range);
      expect(RegistrationValidation.maxBirthYear(2026), 2012);
    });
  });

  group('PIN (AC-UI-04-002, T-BIO-011)', () {
    PinWeakness? weak(String pin, {int length = 6, int? year}) =>
        RegistrationValidation.pinWeakness(pin, length: length, birthYear: year);

    test('одинаковые и последовательные цифры, год рождения — слабые', () {
      expect(weak('111111'), PinWeakness.repeated);
      expect(weak('000000'), PinWeakness.repeated);
      expect(weak('123456'), PinWeakness.sequence);
      expect(weak('654321'), PinWeakness.sequence);
      expect(weak('012345'), PinWeakness.sequence);
      expect(weak('199012', year: 1990), PinWeakness.birthYear);
      expect(weak('1234', length: 4), PinWeakness.sequence);
      expect(weak('0000', length: 4), PinWeakness.repeated);
      expect(weak('1990', length: 4, year: 1990), PinWeakness.birthYear);
    });

    test('допустимые PIN и неверная длина', () {
      expect(weak('483920'), isNull);
      expect(weak('4839', length: 4), isNull);
      expect(weak('48392'), PinWeakness.length);
      expect(weak('48a920'), PinWeakness.nonDigit);
    });
  });

  test('«Продолжить» активна: ФИО, 4 цифры года, «Я ознакомлен(а)» (AC-UI-03-003)', () {
    expect(RegistrationValidation.formReady(fullName: 'Иванов Иван', birthYear: '1990', personalDataAck: true), isTrue);
    expect(
      RegistrationValidation.formReady(fullName: 'Иванов Иван', birthYear: '1990', personalDataAck: false),
      isFalse,
    );
    expect(RegistrationValidation.formReady(fullName: '', birthYear: '1990', personalDataAck: true), isFalse);
    expect(RegistrationValidation.formReady(fullName: 'Иванов Иван', birthYear: '199', personalDataAck: true), isFalse);
  });

  group('Тело POST /registration/complete', () {
    final ticket = testTicket();
    const draft = RegistrationDraft(
      fullName: '  Иванов   Иван ',
      birthYear: '1990',
      activitySphere: ActivitySphere.plumber,
      personalDataAck: true,
    );

    test('сфера без отдельного согласия не передаётся (AC-UI-03-008); sms не передаётся', () {
      final r = RegistrationRequestBuilder.build(
        ticket: ticket,
        draft: draft,
        protection: const LoginProtectionChoice(pin: '4839'),
      );
      expect(r.activitySphere, isNull);
      expect(r.fullName, 'Иванов Иван');
      expect(r.birthYear, 1990);
      expect(r.consents, <ConsentGrant>[const ConsentGrant('personal_data', ConsentVersions.personalData)]);
      expect(r.consents.any((c) => c.kind == 'sms'), isFalse);
      expect(r.biometricsEnabled, isFalse);
      expect(r.toString(), isNot(contains('4839')), reason: 'PIN не попадает в toString');
    });

    test('сфера с согласием и биометрия с согласием', () {
      final r = RegistrationRequestBuilder.build(
        ticket: ticket,
        draft: draft.copyWith(activitySphereConsent: true),
        protection: const LoginProtectionChoice(biometricsEnabled: true, biometricsConsent: true),
      );
      expect(r.activitySphere, ActivitySphere.plumber);
      expect(r.pin, isNull);
      expect(r.biometricsEnabled, isTrue);
      expect(r.consents.map((c) => c.kind), <String>['personal_data', 'activity_sphere', 'biometrics_device']);
    });

    test('биометрия без согласия не включается', () {
      final r = RegistrationRequestBuilder.build(
        ticket: ticket,
        draft: draft,
        protection: const LoginProtectionChoice(pin: '4839', biometricsEnabled: true),
      );
      expect(r.biometricsEnabled, isFalse);
      expect(r.consents.any((c) => c.kind == 'biometrics_device'), isFalse);
    });
  });

  group('Хотя бы один способ защиты (ядро §24.2, REG-038)', () {
    test('клиент: PIN или биометрия с согласием; сотрудник: только PIN', () {
      expect(const LoginProtectionChoice().satisfies(PinPolicy.customer), isFalse);
      expect(const LoginProtectionChoice(pin: '4839').satisfies(PinPolicy.customer), isTrue);
      expect(
        const LoginProtectionChoice(biometricsEnabled: true, biometricsConsent: true).satisfies(PinPolicy.customer),
        isTrue,
      );
      expect(const LoginProtectionChoice(biometricsEnabled: true).satisfies(PinPolicy.customer), isFalse);
      expect(
        const LoginProtectionChoice(biometricsEnabled: true, biometricsConsent: true).satisfies(PinPolicy.staff),
        isFalse,
        reason: 'staff без PIN не завершает SCR-04 (D-48)',
      );
      expect(PinPolicy.staff.length, 6);
      expect(PinPolicy.customer.length, 4);
    });
  });

  group('EnableBiometricLogin (D-13)', () {
    test('Android/iOS: токен → bind; успех — без отзыва семьи', () async {
      final repo = FakeRegistrationRepository();
      final bio = FakeDeviceBiometrics();
      final res = await EnableBiometricLogin(repo, bio)(copy: _copy);
      expect(res.result, BiometricEnrollmentResult.enabled);
      expect(bio.bound, <String>['bio-refresh']);
      expect(repo.disableCalls, 0);
    });

    test('отмена системного диалога → ключ удалён, семья отозвана (02 SCR-04.4 п. 4)', () async {
      final repo = FakeRegistrationRepository();
      final bio = FakeDeviceBiometrics(bindResult: BiometricEnrollmentResult.cancelled);
      final res = await EnableBiometricLogin(repo, bio)(copy: _copy, stepUpToken: 'su');
      expect(res.result, BiometricEnrollmentResult.cancelled);
      expect(bio.discards, 1);
      expect(repo.disableCalls, 1);
    });

    test('403 STEP_UP_REQUIRED → stepUpRequired с operation', () async {
      final repo = FakeRegistrationRepository()
        ..enableResults.add(
          failed(const AuthFailure(AuthReason.stepUpRequired, stepUpOperation: 'profile.biometrics.toggle')),
        );
      final res = await EnableBiometricLogin(repo, FakeDeviceBiometrics())(copy: _copy);
      expect(res.result, BiometricEnrollmentResult.stepUpRequired);
      expect(res.stepUpOperation, 'profile.biometrics.toggle');
    });

    test('Windows Hello — только гейт: сервер не вызывается, токен не выдаётся', () async {
      final repo = FakeRegistrationRepository();
      final bio = FakeDeviceBiometrics(availableOption: BiometricOption.windowsHelloGate);
      final res = await EnableBiometricLogin(repo, bio)(copy: _copy);
      expect(res.result, BiometricEnrollmentResult.gateOnly);
      expect(repo.enableCalls, isEmpty);
      expect(bio.bound, isEmpty);
      expect(bio.presenceCalls, 1);
    });

    test('биометрия не настроена → notEnrolled, без запросов', () async {
      final repo = FakeRegistrationRepository();
      final res = await EnableBiometricLogin(repo, FakeDeviceBiometrics(availableOption: BiometricOption.notEnrolled))(
        copy: _copy,
      );
      expect(res.result, BiometricEnrollmentResult.notEnrolled);
      expect(repo.enableCalls, isEmpty);
    });
  });

  group('StepUpWithPin', () {
    test('PIN_INVALID → attemptsLeft из ответа сервера; PIN_LOCKED', () async {
      final repo = FakeRegistrationRepository()
        ..stepUpResults.addAll(<FailureResult<String>>[
          failed(const AuthFailure(AuthReason.pinInvalid, attemptsLeft: 3)),
          failed(const AuthFailure(AuthReason.pinLocked)),
        ]);
      final first = await StepUpWithPin(repo)(pin: '4839');
      expect(first.error!.result, BiometricEnrollmentResult.pinInvalid);
      expect(first.error!.attemptsLeft, 3);
      final second = await StepUpWithPin(repo)(pin: '4839');
      expect(second.error!.result, BiometricEnrollmentResult.pinLocked);
      expect(repo.stepUpCalls.first.operation, 'profile.biometrics.toggle');
    });
  });
}
