// Widget-тесты SCR-02 (02 SCR-02.13; RM-D-007 AC п.1): 6 ячеек, автоотправка, один запрос,
// OTP_INVALID/EXPIRED/LOCKED/RATE_LIMITED — канонические строки ARB, таймер 60 с, повтор,
// статус доставки, ветвление после верного кода.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' show UserKind;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/features/auth/auth_providers.dart';
import 'package:optomstroy/features/auth/domain/entities/otp_challenge.dart';
import 'package:optomstroy/features/auth/domain/entities/session_profile.dart';
import 'package:optomstroy/features/auth/domain/entities/verify_outcome.dart';
import 'package:optomstroy/features/auth/domain/repositories/auth_repository.dart';
import 'package:optomstroy/features/auth/presentation/navigation/auth_paths.dart';
import 'package:optomstroy/features/auth/presentation/notifiers/auth_flow_notifier.dart';
import 'package:optomstroy/features/auth/presentation/screens/otp_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/phone_screen.dart';

import '../support/fakes.dart';

Finder get _code => find.descendant(of: find.byKey(OtpScreen.screenKey), matching: find.byType(EditableText));

Future<void> _toOtp(WidgetTester tester, AuthHarness h, {Size size = kMedium, TargetPlatform? platform}) async {
  await h.pump(tester, size: size, platform: platform);
  await tester.enterText(
    find.descendant(of: find.byKey(PhoneScreen.fieldKey), matching: find.byType(EditableText)),
    kPhoneDigits,
  );
  await tester.pump();
  await tester.tap(find.byKey(PhoneScreen.submitKey));
  await tester.pumpAndSettle();
  expect(find.byKey(OtpScreen.screenKey), findsOneWidget);
}

Future<void> _enterCode(WidgetTester tester, String code) async {
  await tester.enterText(_code, code);
  await tester.pump();
}

/// Дождаться перехода после ANIM-005 (≤ 900 мс; при reduce-motion — 300 мс).
Future<void> _settleNav(WidgetTester tester) async {
  await tester.pump(OtpScreen.successHold);
  await tester.pumpAndSettle();
}

/// Сдвинуть часы потока и дать тикеру экрана перерисоваться.
Future<void> _advance(WidgetTester tester, AuthHarness h, Duration d) async {
  h.clock.advance(d);
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  late AppLocalizations l10n;

  setUpAll(() async => l10n = await ru());

  testWidgets('6 цифр → ровно один POST /auth/otp/verify и переход на главный экран роли', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness();
    await _toOtp(tester, h);
    expect(find.text(l10n.auth_otp_title), findsOneWidget);
    expect(find.text(l10n.auth_otp_sent_to('+996 700 123 456')), findsOneWidget);
    await _enterCode(tester, '481903');
    expect(h.repository.verifiedCodes, <String>['481903']);
    expect(h.container.read(authSessionProvider).status, AuthSessionStatus.signedIn);
    await _settleNav(tester);
    expect(h.location, AuthPaths.catalog);
    // Память потока очищена (номер и challengeId на устройстве не остаются).
    expect(h.container.read(authFlowProvider).phoneDigits, isEmpty);
    expect(h.container.read(authFlowProvider).challenge, isNull);
  });

  testWidgets('T-AUTH-032: во время проверки повторная отправка того же кода невозможна (inFlight)', (
    WidgetTester tester,
  ) async {
    final AuthHarness h = AuthHarness();
    final Completer<Result<VerifyOutcome>> gate = Completer<Result<VerifyOutcome>>();
    h.repository.verifyGate = gate;
    await _toOtp(tester, h, platform: TargetPlatform.windows);
    await _enterCode(tester, '481903');
    final AppButton submit = tester.widget<AppButton>(find.byKey(OtpScreen.submitKey));
    expect(submit.loading, isTrue);
    expect(submit.onPressed, isNull);
    expect(find.text(l10n.auth_otp_checking), findsOneWidget);
    gate.complete(const Success<VerifyOutcome>(VerifyAuthenticated(profile: staffSeller)));
    await tester.pumpAndSettle();
    expect(h.repository.verifiedCodes, hasLength(1));
  });

  testWidgets('OTP_INVALID attemptsLeft=3 → «Неверный код. Осталось попыток: 3», кнопка появляется (Android)', (
    WidgetTester tester,
  ) async {
    final AuthHarness h = AuthHarness();
    h.repository.verifyResult = const FailureResult<VerifyOutcome>(otpInvalid3);
    await _toOtp(tester, h, platform: TargetPlatform.android);
    expect(find.byKey(OtpScreen.submitKey), findsNothing, reason: 'до первой ошибки кнопки нет (09 §4.4)');
    await _enterCode(tester, '000000');
    expect(find.text(l10n.auth_error_otp_invalid(3)), findsOneWidget);
    expect(find.byKey(OtpScreen.submitKey), findsOneWidget);
    expect(h.location, AuthPaths.otp);
  });

  testWidgets('Windows: «Подтвердить» видна сразу, disabled до 6 цифр', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness();
    await _toOtp(tester, h, platform: TargetPlatform.windows);
    expect(tester.widget<AppButton>(find.byKey(OtpScreen.submitKey)).onPressed, isNull);
  });

  testWidgets('OTP_EXPIRED → «Код устарел. Запросите новый», ссылка повторной отправки активна', (
    WidgetTester tester,
  ) async {
    final AuthHarness h = AuthHarness();
    h.repository.verifyResult = const FailureResult<VerifyOutcome>(otpExpiredFailure);
    await _toOtp(tester, h);
    await _enterCode(tester, '123456');
    expect(find.text(l10n.auth_error_otp_expired), findsOneWidget);
    expect(find.byKey(OtpScreen.resendKey), findsOneWidget, reason: 'независимо от cooldown');
  });

  testWidgets('OTP_LOCKED → баннер с обратным отсчётом, ввод заблокирован', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness();
    h.repository.verifyResult = const FailureResult<VerifyOutcome>(otpLockedFailure);
    await _toOtp(tester, h);
    await _enterCode(tester, '123456');
    expect(find.text(l10n.auth_error_otp_locked(900)), findsOneWidget);
    expect(find.byKey(OtpScreen.resendKey), findsNothing);
    await _advance(tester, h, const Duration(seconds: 901));
    expect(find.byKey(OtpScreen.resendKey), findsOneWidget, reason: 'по нулю активна только повторная отправка');
  });

  testWidgets('таймер 60 с: «через 1:00» → «0:59» → ссылка; повтор → новый challengeId, снекбар', (
    WidgetTester tester,
  ) async {
    final AuthHarness h = AuthHarness();
    h.repository.requestResults
      ..add(Success<OtpIssue>(FakeAuthRepository.issue()))
      ..add(Success<OtpIssue>(FakeAuthRepository.issue(kChallengeId2)));
    await _toOtp(tester, h);
    expect(find.text(l10n.auth_otp_resend_in('1:00')), findsOneWidget);
    await _advance(tester, h, const Duration(seconds: 1));
    expect(find.text(l10n.auth_otp_resend_in('0:59')), findsOneWidget);
    expect(find.text(l10n.auth_otp_ttl_timer('04:59')), findsOneWidget);
    await _advance(tester, h, const Duration(seconds: 59));
    expect(find.byKey(OtpScreen.resendKey), findsOneWidget);
    await tester.tap(find.byKey(OtpScreen.resendKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(h.repository.requestedPhones, <String>[kPhoneE164, kPhoneE164]);
    expect(h.container.read(authFlowProvider).challenge!.challengeId, kChallengeId2);
    expect(find.text(l10n.auth_otp_resent), findsOneWidget);
  });

  testWidgets('повторная отправка: OTP_RATE_LIMITED → «Слишком много запросов…»', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness();
    h.repository.requestResults
      ..add(Success<OtpIssue>(FakeAuthRepository.issue()))
      ..add(const FailureResult<OtpIssue>(otpRateLimited842));
    await _toOtp(tester, h);
    await _advance(tester, h, const Duration(seconds: 61));
    await tester.tap(find.byKey(OtpScreen.resendKey));
    await tester.pump();
    expect(find.text(l10n.auth_error_rate_limited_min(15)), findsOneWidget);
  });

  testWidgets('срок 5:00 истёк → ячейки disabled, «Код устарел», ссылка активна', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness();
    await _toOtp(tester, h);
    await _advance(tester, h, const Duration(minutes: 5));
    expect(find.text(l10n.auth_error_otp_expired), findsOneWidget);
    expect(find.byKey(OtpScreen.resendKey), findsOneWidget);
    expect(h.container.read(authFlowProvider).otpPhase, OtpPhase.expired);
  });

  testWidgets('T-AUTH-008: обрыв сети при verify → код сохранён, «Повторить» отправляет тот же код', (
    WidgetTester tester,
  ) async {
    final AuthHarness h = AuthHarness();
    h.repository.verifyResult = const FailureResult<VerifyOutcome>(offlineFailure);
    await _toOtp(tester, h, platform: TargetPlatform.android);
    await _enterCode(tester, '481903');
    expect(find.text(l10n.auth_error_network), findsOneWidget);
    final AppButton retry = tester.widget<AppButton>(find.byKey(OtpScreen.submitKey));
    expect(retry.label, l10n.ds_button_retry);
    h.repository.verifyResult = const Success<VerifyOutcome>(VerifyAuthenticated(profile: staffSeller));
    await tester.tap(find.byKey(OtpScreen.submitKey));
    await tester.pump();
    expect(h.repository.verifiedCodes, <String>['481903', '481903']);
    await _settleNav(tester);
    expect(h.location, AuthPaths.catalog);
  });

  testWidgets('статус доставки: опрос раз в 3 с → «SMS отправлено»', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness();
    h.repository.statusResult = const Success<OtpChallengeStatus>(
      OtpChallengeStatus(challengeId: kChallengeId, delivery: OtpDeliveryState.sent),
    );
    await _toOtp(tester, h);
    expect(h.repository.statusPolls, isEmpty);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(h.repository.statusPolls, <String>[kChallengeId]);
    expect(find.text(l10n.auth_otp_delivery_sent), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(h.repository.statusPolls, hasLength(1), reason: 'после sent опрос прекращается');
  });

  testWidgets('доставка failed → ссылка «Отправить код повторно» активна сразу', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness();
    h.repository.statusResult = const Success<OtpChallengeStatus>(
      OtpChallengeStatus(challengeId: kChallengeId, delivery: OtpDeliveryState.failed),
    );
    await _toOtp(tester, h);
    expect(find.byKey(OtpScreen.resendKey), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text(l10n.auth_otp_delivery_failed), findsOneWidget);
    expect(find.byKey(OtpScreen.resendKey), findsOneWidget);
  });

  testWidgets('registration_required → SCR-03 и билет регистрации в памяти', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness();
    h.repository.verifyResult = Success<VerifyOutcome>(
      VerifyRegistrationRequired(
        RegistrationTicket(token: 'reg', expiresAt: DateTime.utc(2026, 10, 22, 9, 15), phoneE164: ''),
      ),
    );
    await _toOtp(tester, h);
    await _enterCode(tester, '123456');
    await _settleNav(tester);
    expect(h.location, AuthPaths.register);
    expect(h.container.read(registrationTicketProvider)!.phoneE164, kPhoneE164);
  });

  testWidgets('приглашение (nextStep=set_pin) → SCR-04 «первый вход сотрудника»', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness();
    h.repository.verifyResult = const Success<VerifyOutcome>(
      VerifyAuthenticated(
        profile: SessionProfile(kind: UserKind.staff, roles: <Never>[]),
        nextStep: AuthNextStep.setPin,
        viaInvitation: true,
      ),
    );
    await _toOtp(tester, h);
    await _enterCode(tester, '123456');
    await _settleNav(tester);
    expect(h.location, AuthPaths.registerSecurity);
    expect(h.container.read(authSessionProvider).status, AuthSessionStatus.pinSetupRequired);
  });

  testWidgets('pending_activation → SCR-07', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness();
    h.repository.verifyResult = const Success<VerifyOutcome>(VerifyPendingActivation());
    await _toOtp(tester, h);
    await _enterCode(tester, '123456');
    await _settleNav(tester);
    expect(h.location, AuthPaths.pendingActivation);
  });

  testWidgets('DEVICE_MISMATCH → SCR-01 с баннером «Код запрошен с другого устройства…»', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness();
    h.repository.verifyResult = const FailureResult<VerifyOutcome>(deviceMismatchFailure);
    await _toOtp(tester, h);
    await _enterCode(tester, '123456');
    await tester.pumpAndSettle();
    expect(h.location, startsWith(AuthPaths.phone));
    expect(find.text(l10n.auth_entry_device_mismatch), findsOneWidget);
  });

  testWidgets('прямой переход на /auth/otp без потока → SCR-01 (guard)', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness();
    await h.pump(tester, initial: AuthPaths.otp);
    await tester.pumpAndSettle();
    expect(h.location, AuthPaths.phone);
  });

  for (final (String name, Size size) in <(String, Size)>[
    ('compact', kCompact),
    ('medium', kMedium),
    ('expanded', kExpanded),
  ]) {
    testWidgets('брейкпоинт $name: без переполнений', (WidgetTester tester) async {
      final AuthHarness h = AuthHarness();
      await _toOtp(tester, h, size: size);
      expect(tester.takeException(), isNull);
    });
  }
}
