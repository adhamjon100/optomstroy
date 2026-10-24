// StepUpDialog / StepUpFlow (03 §9.46; T-BIO-015, DS-086; 09 §8.8, §9.6; 08 §4.1.7):
// PIN и «Код из SMS», без биометрии в R1; compact — нижний лист, иначе диалог 400;
// остаток попыток — только из `attemptsLeft`; PIN_LOCKED → переход на SMS; отмена → null.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_api.dart';
import 'package:optomstroy/core/session/step_up_token_cache.dart';
import 'package:optomstroy/features/session_ui/presentation/widgets/step_up_dialog.dart';
import 'package:optomstroy/features/session_ui/presentation/widgets/step_up_flow.dart';

import 'session_ui_support.dart';

final class _FakeActions implements StepUpActions {
  final List<StepUpResponse> pinResponses = <StepUpResponse>[];
  final List<StepUpResponse> otpRequestResponses = <StepUpResponse>[];
  final List<StepUpResponse> otpResponses = <StepUpResponse>[];
  final List<String> pins = <String>[];
  final List<(String, String)> codes = <(String, String)>[];
  int otpRequests = 0;

  @override
  Future<StepUpResponse> submitPin(String pin) async {
    pins.add(pin);
    return pinResponses.removeAt(0);
  }

  @override
  Future<StepUpResponse> requestOtp() async {
    otpRequests++;
    return otpRequestResponses.removeAt(0);
  }

  @override
  Future<StepUpResponse> submitOtp(String challengeId, String code) async {
    codes.add((challengeId, code));
    return otpResponses.removeAt(0);
  }
}

StepUpGrant _grant(String method) => StepUpGrant(
  token: 'su-1',
  operation: 'payment.void',
  expiresAt: DateTime.utc(2026, 10, 22, 10),
  method: method,
  scope: const <String>['payment.void'],
);

void main() {
  testWidgets('compact: нижний лист; способы PIN и «Код из SMS»; кнопки биометрии нет', (tester) async {
    setWindow(tester, compactSize);
    await tester.pumpWidget(themed(StepUpFlow(actions: _FakeActions(), onDone: (_) {})));
    await tester.pump();
    expect(find.byKey(StepUpDialog.sheetKey), findsOneWidget);
    expect(find.byKey(StepUpDialog.dialogKey), findsNothing);
    expect(find.text('Подтвердите действие'), findsOneWidget);
    expect(find.byKey(StepUpDialog.pinTabKey), findsOneWidget);
    expect(find.byKey(StepUpDialog.otpTabKey), findsOneWidget);
    expect(find.byIcon(Icons.fingerprint), findsNothing);
    expect(find.byIcon(Icons.face), findsNothing);
    expect(find.textContaining('иометри'), findsNothing);
  });

  testWidgets('expanded: диалог шириной 400 по центру', (tester) async {
    setWindow(tester, expandedSize);
    await tester.pumpWidget(themed(StepUpFlow(actions: _FakeActions(), onDone: (_) {})));
    await tester.pump();
    expect(find.byKey(StepUpDialog.dialogKey), findsOneWidget);
    expect(tester.getSize(find.byKey(StepUpDialog.dialogKey)).width, 400);
  });

  testWidgets('PIN_INVALID → «Осталось попыток: n» из ответа; PIN_LOCKED → «Код из SMS»; OTP → токен', (tester) async {
    setWindow(tester, expandedSize);
    final actions = _FakeActions()
      ..pinResponses.addAll(<StepUpResponse>[
        const StepUpFailed(PinInvalidError(3)),
        const StepUpFailed(PinLockedError()),
      ])
      ..otpRequestResponses.add(
        const StepUpOtpSent(challengeId: 'ch-1', resendAfter: Duration(seconds: 60), otpTtl: Duration(minutes: 5)),
      )
      ..otpResponses.add(StepUpGranted(_grant('otp')));
    StepUpGrant? result;
    var done = false;
    await tester.pumpWidget(
      themed(
        StepUpFlow(
          actions: actions,
          pinLength: 6,
          onDone: (g) {
            done = true;
            result = g;
          },
        ),
      ),
    );
    await tester.pump();

    await tapPin(tester, '123456');
    await tester.pump(const Duration(milliseconds: 50));
    expect(actions.pins, <String>['123456']);
    expect(find.text('Неверный PIN. Осталось попыток: 3'), findsOneWidget);

    await tapPin(tester, '654320');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('PIN заблокирован. Подтвердите кодом из SMS'), findsWidgets);
    expect(find.byKey(StepUpDialog.requestOtpKey), findsOneWidget);

    await tester.tap(find.byKey(StepUpDialog.requestOtpKey));
    await tester.pump(const Duration(milliseconds: 50));
    expect(actions.otpRequests, 1);
    expect(find.text('Введите код из SMS'), findsOneWidget);
    expect(find.textContaining('Отправить повторно через 01:00'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Отправить повторно через 00:59'), findsOneWidget);

    await tester.enterText(find.byType(EditableText).last, '123456');
    await tester.pump(const Duration(milliseconds: 50));
    expect(actions.codes, <(String, String)>[('ch-1', '123456')]);
    expect(done, isTrue);
    expect(result?.token, 'su-1');
  });

  testWidgets('«Отмена» → null; ошибка сети — сообщение без закрытия', (tester) async {
    setWindow(tester, compactSize);
    final actions = _FakeActions()..pinResponses.add(const StepUpFailed(NetworkCallError(timeout: true)));
    var done = false;
    StepUpGrant? result = _grant('pin');
    await tester.pumpWidget(
      themed(
        StepUpFlow(
          actions: actions,
          onDone: (g) {
            done = true;
            result = g;
          },
        ),
      ),
    );
    await tester.pump();
    await tapPin(tester, '123456');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Сервер не ответил. Повторить'), findsOneWidget);
    expect(done, isFalse);
    await tester.tap(find.byKey(StepUpDialog.cancelKey));
    await tester.pump();
    expect(done, isTrue);
    expect(result, isNull);
  });

  testWidgets('D SS-02: вкладки «PIN» / «Код из SMS», «Отправить код», «Проверяем…» во время проверки PIN', (
    tester,
  ) async {
    final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));
    setWindow(tester, expandedSize);
    final Completer<StepUpResponse> pending = Completer<StepUpResponse>();
    final _SlowPin actions = _SlowPin(pending.future);
    await tester.pumpWidget(themed(StepUpFlow(actions: actions, pinLength: 6, onDone: (_) {})));
    await tester.pump();
    expect(
      find.descendant(of: find.byKey(StepUpDialog.pinTabKey), matching: find.text(l10n.stepup_tab_pin)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byKey(StepUpDialog.otpTabKey), matching: find.text(l10n.stepup_tab_sms)),
      findsOneWidget,
    );
    await tapPin(tester, '123456');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(StepUpDialog.verifyingKey), findsOneWidget);
    expect(find.text(l10n.stepup_verifying), findsOneWidget);
    pending.complete(StepUpGranted(_grant('pin')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(StepUpDialog.verifyingKey), findsNothing);
  });

  testWidgets('D SS-02: вкладка «Код из SMS» → кнопка «Отправить код»', (tester) async {
    final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));
    setWindow(tester, expandedSize);
    await tester.pumpWidget(themed(StepUpFlow(actions: _FakeActions(), onDone: (_) {})));
    await tester.pump();
    await tester.tap(find.byKey(StepUpDialog.otpTabKey));
    await tester.pump();
    expect(
      find.descendant(of: find.byKey(StepUpDialog.requestOtpKey), matching: find.text(l10n.stepup_send_code)),
      findsOneWidget,
    );
  });
}

final class _SlowPin extends _FakeActions {
  _SlowPin(this._result);

  final Future<StepUpResponse> _result;

  @override
  Future<StepUpResponse> submitPin(String pin) => _result;
}
