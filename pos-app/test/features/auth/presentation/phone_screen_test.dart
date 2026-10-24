// Widget-тесты SCR-01 (02 SCR-01.13; RM-D-007 AC п.1): маска +996, E.164 в API,
// блокировка кнопки до 9 цифр, канонические строки ARB для ошибок, нейтральность, inFlight.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/features/auth/domain/repositories/auth_repository.dart';
import 'package:optomstroy/features/auth/presentation/mascot/mascot.dart';
import 'package:optomstroy/features/auth/presentation/navigation/auth_paths.dart';
import 'package:optomstroy/features/auth/presentation/screens/otp_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/phone_screen.dart';

import '../support/fakes.dart';

Finder get _input => find.descendant(of: find.byKey(PhoneScreen.fieldKey), matching: find.byType(EditableText));

AppButton _submit(WidgetTester tester) => tester.widget<AppButton>(find.byKey(PhoneScreen.submitKey));

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(_input, text);
  await tester.pump();
}

void main() {
  late AppLocalizations l10n;

  setUpAll(() async => l10n = await ru());

  testWidgets('T-AUTH-023: маска: «700123456» → «700 123 456» с префиксом +996; в API — E.164', (
    WidgetTester tester,
  ) async {
    final AuthHarness h = AuthHarness();
    await h.pump(tester);
    expect(find.byKey(PhoneScreen.screenKey), findsOneWidget);
    expect(find.text('+996'), findsWidgets);
    await _type(tester, kPhoneDigits);
    expect(tester.widget<EditableText>(_input).controller.text, '700 123 456');
    await tester.tap(find.byKey(PhoneScreen.submitKey));
    await tester.pumpAndSettle();
    expect(h.repository.requestedPhones, <String>[kPhoneE164]);
    expect(h.location, AuthPaths.otp);
    expect(find.byKey(OtpScreen.screenKey), findsOneWidget);
  });

  testWidgets('вставка «0700123456» и «+996 700 12 34 56» нормализуются', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness();
    await h.pump(tester);
    await _type(tester, '0700123456');
    expect(tester.widget<EditableText>(_input).controller.text, '700 123 456');
    await _type(tester, '+996 700 12 34 56');
    expect(tester.widget<EditableText>(_input).controller.text, '700 123 456');
  });

  testWidgets('T-AUTH-024: кнопка заблокирована до 9 цифр и для немобильного номера; подсказки ARB', (
    WidgetTester tester,
  ) async {
    final AuthHarness h = AuthHarness();
    await h.pump(tester);
    expect(_submit(tester).onPressed, isNull);
    expect(find.text(l10n.auth_phone_hint), findsOneWidget);
    await _type(tester, '70012345');
    expect(_submit(tester).onPressed, isNull);
    expect(find.text(l10n.auth_phone_hint_remaining(1)), findsOneWidget);
    await _type(tester, '312123456');
    expect(_submit(tester).onPressed, isNull, reason: 'isValid(mobile) = false');
    await _type(tester, kPhoneDigits);
    expect(_submit(tester).onPressed, isNotNull);
  });

  testWidgets('T-AUTH-024: blur с 5 цифрами → «Номер должен содержать 9 цифр после +996»', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness();
    await h.pump(tester);
    await _type(tester, '70012');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(find.text(l10n.auth_phone_error_short), findsOneWidget);
    await _type(tester, '700123');
    expect(find.text(l10n.auth_phone_error_short), findsNothing, reason: 'ошибка сбрасывается при изменении');
  });

  testWidgets('T-AUTH-032: двойной тап по «Получить код» → ровно один запрос (inFlight)', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness();
    final Completer<Result<OtpIssue>> gate = Completer<Result<OtpIssue>>();
    h.repository.requestGate = gate;
    await h.pump(tester);
    await _type(tester, kPhoneDigits);
    await tester.tap(find.byKey(PhoneScreen.submitKey));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(PhoneScreen.submitKey), warnIfMissed: false);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 1100));
    expect(find.text(l10n.auth_phone_sending), findsOneWidget, reason: '«Отправляем код…» через 1 с');
    gate.complete(Success<OtpIssue>(FakeAuthRepository.issue()));
    await tester.pumpAndSettle();
    expect(h.repository.requestedPhones, hasLength(1));
  });

  testWidgets('429 OTP_RATE_LIMITED retryAfter=842 → «через 14:02», поле редактируемо', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness();
    h.repository.requestResults.add(const FailureResult<OtpIssue>(otpRateLimited842));
    await h.pump(tester);
    await _type(tester, kPhoneDigits);
    await tester.tap(find.byKey(PhoneScreen.submitKey));
    await tester.pump();
    expect(_submit(tester).label, l10n.auth_phone_submit_wait('14:02'));
    expect(_submit(tester).onPressed, isNull);
    expect(find.text(l10n.auth_error_rate_limited_min(15)), findsOneWidget);
    // Другой номер — лимит относится к номеру: кнопка активна.
    await _type(tester, '555123456');
    expect(_submit(tester).onPressed, isNotNull);
    expect(_submit(tester).label, l10n.auth_phone_submit);
  });

  testWidgets('503 SMS_PROVIDER_ERROR → баннер «Не удалось отправить SMS…» и «Повторить»', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness();
    h.repository.requestResults.add(const FailureResult<OtpIssue>(smsProviderFailure));
    await h.pump(tester);
    await _type(tester, kPhoneDigits);
    await tester.tap(find.byKey(PhoneScreen.submitKey));
    await tester.pump();
    expect(find.text(l10n.auth_error_sms_provider), findsOneWidget);
    final Finder retry = find.descendant(
      of: find.byKey(PhoneScreen.requestBannerKey),
      matching: find.text(l10n.ds_button_retry),
    );
    expect(retry, findsOneWidget);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(h.repository.requestedPhones, hasLength(2));
    expect(h.location, AuthPaths.otp);
  });

  testWidgets('T-AUTH-008: обрыв сети → «Нужна сеть для входа», кнопка disabled, ввод разрешён', (
    WidgetTester tester,
  ) async {
    final AuthHarness h = AuthHarness();
    h.repository.requestResults.add(const FailureResult<OtpIssue>(offlineFailure));
    await h.pump(tester);
    await _type(tester, kPhoneDigits);
    await tester.tap(find.byKey(PhoneScreen.submitKey));
    await tester.pump();
    expect(find.byKey(PhoneScreen.offlineBannerKey), findsOneWidget);
    expect(_submit(tester).onPressed, isNull);
    await _type(tester, '555123456');
    expect(tester.widget<EditableText>(_input).controller.text, '555 123 456');
  });

  testWidgets('сигнал «нет сети» до запроса → баннер, кнопка disabled', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness(offline: true);
    await h.pump(tester);
    await _type(tester, kPhoneDigits);
    expect(find.byKey(PhoneScreen.offlineBannerKey), findsOneWidget);
    expect(_submit(tester).onPressed, isNull);
  });

  testWidgets('VALIDATION_FAILED → «Сервер не принял номер…»', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness();
    h.repository.requestResults.add(
      const FailureResult<OtpIssue>(
        ValidationFailure(
          errors: <FieldError>[FieldError(field: 'phone', rule: 'e164')],
        ),
      ),
    );
    await h.pump(tester);
    await _type(tester, kPhoneDigits);
    await tester.tap(find.byKey(PhoneScreen.submitKey));
    await tester.pump();
    expect(find.text(l10n.auth_phone_error_server_invalid), findsOneWidget);
  });

  testWidgets('причина session_revoked: баннер; закрывается вводом первой цифры', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness();
    await h.pump(tester, initial: '${AuthPaths.phone}?reason=session_revoked');
    await tester.pump();
    expect(find.text(l10n.auth_entry_session_revoked), findsOneWidget);
    await _type(tester, '7');
    expect(find.byKey(PhoneScreen.entryBannerKey), findsNothing);
  });

  testWidgets('возврат с SCR-02 тем же номером в пределах TTL — без нового SMS (AC-UI-01-013)', (
    WidgetTester tester,
  ) async {
    final AuthHarness h = AuthHarness();
    await h.pump(tester);
    await _type(tester, kPhoneDigits);
    await tester.tap(find.byKey(PhoneScreen.submitKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(OtpScreen.backKey));
    await tester.pumpAndSettle();
    expect(h.location, AuthPaths.phone);
    expect(tester.widget<EditableText>(_input).controller.text, '700 123 456');
    await tester.tap(find.byKey(PhoneScreen.submitKey));
    await tester.pumpAndSettle();
    expect(h.location, AuthPaths.otp);
    expect(h.repository.requestedPhones, hasLength(1));
  });

  testWidgets('T-AUTH-035: reduce-motion: персонаж — статичный кадр; тексты не раскрывают наличие аккаунта', (
    WidgetTester tester,
  ) async {
    final AuthHarness h = AuthHarness();
    await h.pump(tester);
    expect(find.byKey(PlaceholderMascotRenderer.staticFrameKey), findsOneWidget);
    for (final String s in <String>[l10n.auth_phone_title, l10n.auth_phone_subtitle, l10n.auth_phone_sms_notice]) {
      expect(s.toLowerCase(), isNot(contains('регистр')));
      expect(s.toLowerCase(), isNot(contains('аккаунт')));
    }
  });

  for (final (String name, Size size) in <(String, Size)>[
    ('compact', kCompact),
    ('medium', kMedium),
    ('expanded', kExpanded),
  ]) {
    testWidgets('брейкпоинт $name: экран собирается без переполнений', (WidgetTester tester) async {
      final AuthHarness h = AuthHarness();
      await h.pump(tester, size: size);
      expect(find.byKey(PhoneScreen.screenKey), findsOneWidget);
      expect(find.text(l10n.auth_phone_title), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
