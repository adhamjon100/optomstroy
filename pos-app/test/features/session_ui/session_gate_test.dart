// SessionGate (02 SCR-08 overlay, SCR-90 B/C/C3; 09 §8.8; T-SESS-015, T-BIO-009, AC-UI-08-006/007/014):
// блокировка поверх экрана с сохранением состояния, разблокировка PIN через `POST /auth/unlock`,
// «Назад» не снимает слой, Ctrl+L, idle 30 мин, step-up из интерсептора → StepUpDialog → повтор,
// «Сессия завершена» с причиной, 426 → «Требуется обновление».
import 'dart:async';

import 'package:dio/dio.dart' show DioExceptionType;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/session/secure_content.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/features/session_ui/presentation/session_gate.dart';
import 'package:optomstroy/features/session_ui/presentation/widgets/session_ended_dialog.dart';
import 'package:optomstroy/features/session_ui/presentation/widgets/session_lock_overlay.dart';
import 'package:optomstroy/features/session_ui/presentation/widgets/step_up_dialog.dart';
import 'package:optomstroy/features/session_ui/presentation/widgets/update_required_view.dart';

import '../../core/session/session_harness.dart';
import 'session_ui_support.dart';

/// Конец теста: снять дерево и контейнер до проверки «нет висящих таймеров» (idle-таймер 30 мин).
Future<void> _finish(WidgetTester tester, SessionHarness h) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await h.dispose();
}

Future<SessionHarness> _signedIn(WidgetTester tester, FakeHandler handler, {String kind = 'staff'}) async {
  final h = SessionHarness(handler);
  addTearDown(h.dispose);
  final established = h.start().establish(
    accessToken: fakeJwt(kind: kind),
    refreshToken: 'r1',
  );
  await tester.pump();
  await established;
  return h;
}

void main() {
  testWidgets('блокировка: overlay поверх экрана, ввод под ним недоступен, состояние сохраняется; '
      'PIN → /auth/unlock → слой снят, черновик на месте', (tester) async {
    setWindow(tester, expandedSize);
    final h = await _signedIn(tester, (o) async {
      if (o.path.endsWith('/auth/unlock')) return json(200, tokenPair(fakeJwt(tag: 'u'), 'r2'));
      return json(200, {});
    });
    await tester.pumpWidget(gatedApp(h.container, const DraftScreen()));
    await tester.enterText(find.byKey(DraftScreen.fieldKey), 'корзина: 3 позиции');
    await tester.tap(find.byKey(DraftScreen.incrementKey));
    await tester.pump();
    final before = tester.state<DraftScreenState>(find.byType(DraftScreen));

    h.controller.lock(SessionLockReason.manual);
    await tester.pump();
    expect(find.byKey(SessionLockOverlay.overlayKey), findsOneWidget);
    expect(find.text('Экран заблокирован'), findsOneWidget);
    expect(find.text('Заблокировано вручную'), findsOneWidget);
    expect(h.tokens.accessToken, isNull);
    // AU-16 / SEC-097 (E-security-4): ввод PIN в оверлее защищён (FLAG_SECURE на Android, заливка в фоне).
    expect(find.byType(SecureContent), findsWidgets);
    expect(SecureContent.activeCount, greaterThan(0));

    // Тап по scrim и по кнопке под слоем ничего не делает; «Назад» поглощается.
    expect(find.byKey(SessionGate.scrimKey), findsOneWidget);
    await tester.tapAt(const Offset(4, 4));
    await tester.tap(find.byKey(DraftScreen.incrementKey), warnIfMissed: false);
    await tester.pump();
    expect(before.counter, 1);
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(SessionLockOverlay.overlayKey), findsOneWidget);

    await tapPin(tester, '482913');
    await frames(tester);
    expect(find.byKey(SessionLockOverlay.overlayKey), findsNothing);
    expect(h.state.isLocked, isFalse);
    expect(SecureContent.activeCount, 0, reason: 'защита снята вместе с оверлеем');
    final unlock = h.adapter.requests.singleWhere((r) => r.path == '/auth/unlock');
    expect(unlock.data, <String, Object?>{'method': 'pin', 'refreshToken': 'r1', 'pin': '482913'});
    // Тот же State: экран не пересоздавался, черновик и счётчик на месте.
    expect(tester.state<DraftScreenState>(find.byType(DraftScreen)), same(before));
    expect(before.controller.text, 'корзина: 3 позиции');
    expect(before.counter, 1);
    await _finish(tester, h);
  });

  testWidgets('PIN_INVALID на разблокировке → «Осталось попыток: 4», refresh не вызывается', (tester) async {
    setWindow(tester, compactSize);
    final h = await _signedIn(
      tester,
      (o) async => o.path.endsWith('/auth/unlock')
          ? json(401, problem('PIN_INVALID', 401, extra: {'attemptsLeft': 4}))
          : json(200, {}),
    );
    await tester.pumpWidget(gatedApp(h.container, const DraftScreen()));
    h.controller.lock(SessionLockReason.manual);
    await tester.pump();
    await tapPin(tester, '000001');
    await frames(tester);
    expect(find.text('Неверный PIN. Осталось попыток: 4'), findsOneWidget);
    expect(h.adapter.countPath('/auth/refresh'), 0);
    expect(find.byKey(SessionLockOverlay.overlayKey), findsOneWidget);
    await _finish(tester, h);
  });

  testWidgets('idle 30 мин → overlay «Через 30 мин бездействия»; Ctrl+L — ручная блокировка', (tester) async {
    setWindow(tester, expandedSize);
    final h = await _signedIn(tester, (o) async => json(200, {}));
    await tester.pumpWidget(gatedApp(h.container, const DraftScreen()));
    await tester.pump(const Duration(minutes: 20));
    await tester.tap(find.byKey(DraftScreen.incrementKey)); // касание — активность
    await tester.pump(const Duration(minutes: 29));
    expect(find.byKey(SessionLockOverlay.overlayKey), findsNothing);
    await tester.pump(const Duration(minutes: 1));
    expect(find.byKey(SessionLockOverlay.overlayKey), findsOneWidget);
    expect(find.text('Через 30 мин бездействия'), findsOneWidget);
    expect(h.state.lock, SessionLockReason.idle);
    await _finish(tester, h);
  });

  testWidgets('Ctrl+L → «Заблокировано вручную»', (tester) async {
    setWindow(tester, expandedSize);
    final h = await _signedIn(tester, (o) async => json(200, {}));
    await tester.pumpWidget(gatedApp(h.container, const DraftScreen()));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(h.state.lock, SessionLockReason.manual);
    expect(find.text('Заблокировано вручную'), findsOneWidget);
    await _finish(tester, h);
  });

  testWidgets('403 STEP_UP_REQUIRED → StepUpDialog (PIN) → POST /auth/step-up → повтор исходного запроса', (
    tester,
  ) async {
    setWindow(tester, expandedSize);
    const op = 'payment.qr.confirm_manual';
    final h = await _signedIn(tester, (o) async {
      if (o.path.endsWith('/auth/step-up')) {
        return json(200, stepUpToken('su-1', op, expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 15))));
      }
      return o.headers[ApiHeaders.stepUpToken] == 'su-1' ? json(200, {'ok': true}) : json(403, stepUpRequired(op));
    });
    await tester.pumpWidget(gatedApp(h.container, const DraftScreen()));
    int? status;
    unawaited(
      h.dio
          .post<Object?>('/payments/p1/confirm-manual', options: apiOptions(idempotencyKey: 'idem-1'))
          .then((r) => status = r.statusCode),
    );
    await frames(tester);
    expect(find.byKey(StepUpDialog.dialogKey), findsOneWidget);
    expect(find.byIcon(Icons.fingerprint), findsNothing);
    expect(
      find.descendant(of: find.byKey(StepUpDialog.dialogKey), matching: find.byType(SecureContent)),
      findsOneWidget,
      reason: 'ввод PIN в StepUpDialog защищён (E-security-4)',
    );
    await tapPin(tester, '482913');
    await frames(tester);
    expect(find.byKey(StepUpDialog.dialogKey), findsNothing);
    expect(status, 200);
    final stepUp = h.adapter.requests.singleWhere((r) => r.path == '/auth/step-up');
    expect(stepUp.data, <String, Object?>{'method': 'pin', 'pin': '482913', 'operation': op});
    final retried = h.adapter.requests.where((r) => r.path == '/payments/p1/confirm-manual').last;
    expect(retried.headers[ApiHeaders.stepUpToken], 'su-1');
    expect(retried.headers[ApiHeaders.idempotencyKey], 'idem-1');
    await _finish(tester, h);
  });

  testWidgets('SESSION_REVOKED (reuse) → «Сессия завершена» с причиной → «Войти снова»', (tester) async {
    setWindow(tester, compactSize);
    final h = await _signedIn(
      tester,
      (o) async => json(401, problem('SESSION_REVOKED', 401, extra: {'reason': 'reuse_detected'})),
    );
    await tester.pumpWidget(gatedApp(h.container, const DraftScreen()));
    unawaited(h.dio.get<Object?>('/me').then<void>((_) {}, onError: (Object _) {}));
    await frames(tester);
    expect(find.byKey(SessionEndedDialog.dialogKey), findsOneWidget);
    expect(find.text('Сессия завершена'), findsOneWidget);
    expect(find.text('Для безопасности мы завершили все сессии. Войдите снова'), findsOneWidget);
    await tester.tap(find.byKey(SessionEndedDialog.actionKey));
    await tester.pump();
    expect(find.byKey(SessionEndedDialog.dialogKey), findsNothing);
    expect(h.state.endReason, SessionEndReason.reuseDetected);
    await _finish(tester, h);
  });

  testWidgets('426 → SCR-90 «Требуется обновление», экран под слоем недоступен', (tester) async {
    setWindow(tester, compactSize);
    final h = await _signedIn(
      tester,
      (o) async => json(
        426,
        problem('APP_UPDATE_REQUIRED', 426),
        headers: <String, String>{ApiHeaders.minAppVersion: 'android=2.0.0'},
      ),
    );
    await tester.pumpWidget(gatedApp(h.container, const DraftScreen()));
    unawaited(h.dio.get<Object?>('/catalog').then<void>((_) {}, onError: (Object _) {}));
    await frames(tester);
    expect(find.byKey(UpdateRequiredView.viewKey), findsOneWidget);
    expect(find.text('Требуется обновление приложения'), findsOneWidget);
    expect(find.text('Установите версию 2.0.0 или новее, чтобы продолжить работу'), findsOneWidget);
    expect(await tester.binding.handlePopRoute(), isTrue);
    await _finish(tester, h);
  });

  testWidgets('lockScreenBuilder: SCR-08 фичи auth вместо PIN-слоя по умолчанию', (tester) async {
    setWindow(tester, expandedSize);
    final h = await _signedIn(tester, (o) async => json(200, {}));
    await tester.pumpWidget(
      gatedApp(
        h.container,
        const DraftScreen(),
        lockScreenBuilder: (context, reason) => Text('custom-lock:${reason.name}'),
      ),
    );
    h.controller.lock(SessionLockReason.manual);
    await tester.pump();
    expect(find.text('custom-lock:manual'), findsOneWidget);
    expect(find.byKey(SessionLockOverlay.overlayKey), findsNothing);
    await _finish(tester, h);
  });

  testWidgets('UI-41-014: выход без сети → снекбар «Вы вышли. Сессия на сервере будет завершена…» (FQ-TRN-05)', (
    tester,
  ) async {
    setWindow(tester, expandedSize);
    final h = await _signedIn(tester, (o) async => transportError(o, DioExceptionType.connectionError));
    await tester.pumpWidget(gatedApp(h.container, const Scaffold(body: SizedBox.shrink())));
    unawaited(h.controller.logout());
    await frames(tester, 20);
    expect(h.state.serverLogoutPending, isTrue);
    expect(find.text('Вы вышли. Сессия на сервере будет завершена при появлении сети'), findsOneWidget);
  });
}
